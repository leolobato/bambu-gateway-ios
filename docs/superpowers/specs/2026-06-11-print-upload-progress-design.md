# Print Upload Progress Design

**Date:** 2026-06-11
**Status:** Approved
**Repo:** bambu-gateway-ios, branch `feat/print-upload-progress` (stacked on `feat/gcode-preview-v2`)

## Problem

`POST /api/print` returns immediately with `status: "uploading"` and an
`uploadId`; the actual FTP upload to the printer runs in the background
on the gateway and can take minutes for large 3MFs. The app already
polls `GET /api/uploads/{id}` every 500 ms into
`AppViewModel.uploadProgress`, but the UI misrepresents the state:

- **Print tab:** `PrintSuccessModal` (green checkmark, "print started")
  is presented the moment the POST returns — while the upload has only
  just begun. The inline "Uploading to printer" card renders behind the
  modal where it can't be seen.
- **Jobs tab:** `printSliceJob()` sets `showPrintSuccessModal = true`,
  but the modal's `.sheet` is attached only inside `PrintTab`
  (`PrintTab.swift:69`). Printing from the slice-job detail sheet
  dismisses the sheet and shows nothing at all while the upload runs.

## Design

One dedicated send-to-printer modal, shared by both entry points,
honest about the upload phase.

### State machine (AppViewModel)

Replace the `showPrintSuccessModal: Bool` with:

```swift
enum PrintFlowState: Equatable {
    case uploading(progress: Double?)  // nil until the first poll lands
    case success
    case failed(String)
}
@Published var printFlow: PrintFlowState?
```

Transitions:

- `handlePrintResponse` with `uploadId` → `.uploading(progress: nil)`
  (LAN path; polling starts as today).
- `handlePrintResponse` without `uploadId` → `.success` (cloud path —
  the gateway already confirmed `status: "printing"`).
- Each poll tick → `.uploading(progress: state.progress)`.
- Poll reports `completed` → `.success`.
- Poll reports `failed` → `.failed(message)`.
- Poll reports `cancelled` → `printFlow = nil` (modal closes; the
  existing "Upload cancelled." info message remains).
- If the user dismissed the modal mid-upload (`printFlow == nil`),
  polling keeps updating `uploadProgress` (the Print-tab card stays
  live) but does NOT re-present the modal on completion. Existing
  success/failure `setMessage` behavior is the fallback signal.

`dismissPrintFlow()` replaces `dismissPrintSuccessModal()` — clears
`printFlow`, `lastPrintEstimate`, `lastPrintPrinterName`. Dismissing
during upload does not cancel the upload.

### View

`PrintSuccessModal` becomes `PrintProgressModal`, switching on the
state:

- **uploading:** printer-with-arrow icon, "Sending to {printer}…",
  determinate `ProgressView` + percent (indeterminate while progress is
  nil), the existing destructive "Cancel upload" action
  (`viewModel.cancelUpload()`), and a "Done" button that just dismisses
  (upload continues in background).
- **success:** the current green-check content (title, estimate card,
  Done) unchanged.
- **failed:** red icon, the error message, Done.

The sheet attaches at the root (`ContentView`, above the TabView), so
the modal appears regardless of which tab initiated the print. The
`PrintTab` attachment is removed.

### Jobs tab ordering fix

`SliceJobDetailSheet`'s Print button currently awaits the POST and only
then dismisses — which would collide with the root sheet presenting.
Flip it: dismiss the detail sheet immediately, fire the print request
in a `Task`. Failures surface via the modal's `.failed` state (and the
existing message banner). The `sliceJobMutationsInFlight` guard already
prevents double-submission.

### Print button subtitle (Print tab)

The subtitle slot under the buttons (driven by `currentSlicingPhase`)
also shows "Preparing…" whenever a submission is busy but no slicing
phase is reported yet — covering the short gaps before slicing starts
and between "slicing done" and the print response.

### Kept as-is

- The Print tab's inline upload card (useful after dismissing the modal
  mid-upload).
- The 500 ms polling loop, cancel flow, Live Activity start.
- Jobs-row inline progress: deferred (modal covers both flows).

## Testing

State transitions are exercised directly (no network stubs): extract
the poll-tick handling into an internal `applyUploadPoll(state:)` and
call `handlePrintResponse` with crafted `PrintResponse` values from
`BambuGatewayTests`. Cases: uploadId → uploading; no uploadId →
success; poll progress update; completed → success; failed → failed;
cancelled → nil; dismissed-mid-upload stays nil on completion.

Manual: print from Print tab (LAN printer) and from Jobs tab; verify
progress counts up, modal flips to success, cancel works from modal.
