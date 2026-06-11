# Print Upload Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the premature "print success" modal with one root-attached send-to-printer modal that shows live upload progress and works from both the Print tab and the Jobs tab.

**Architecture:** A `PrintFlowState` state machine on `AppViewModel` (uploading → success/failed), fed by the existing 500 ms upload polling. The modal presentation decision moves into `handlePrintResponse` (all three print paths already funnel through it). The sheet attaches in `ContentView` above the TabView.

**Tech Stack:** SwiftUI (iOS 18+), XcodeGen project. Unit tests in `BambuGatewayTests` (`test_<scenario>_<expectedResult>()` style), run on the iPhone 16 / iOS 18.6 simulator.

**Spec:** `docs/superpowers/specs/2026-06-11-print-upload-progress-design.md`
**Repo:** /Users/leolobato/Documents/Projetos/Personal/3d/bambu_workspace/bambu-gateway-ios, branch `feat/print-upload-progress`

**Known facts (verified):**
- All three `showPrintSuccessModal = true` sites (`AppViewModel.swift:451` submitPrint, `:855` consumeReadyJob, `:1326` printSliceJob) immediately follow a `handlePrintResponse(...)` call.
- `handlePrintResponse` (AppViewModel.swift:895) already calls `startUploadPolling(uploadId:)` when `response.uploadId != nil` (line ~922).
- The polling loop (`startUploadPolling`, AppViewModel.swift:1144-1180) handles statuses inline; `finishUploadPolling()` (line 1182) clears `uploadProgress`/`activeUploadId`.
- `dismissPrintSuccessModal()` is at AppViewModel.swift:607.
- The modal sheet is attached at PrintTab.swift:69-75; `currentSlicingPhase` computed at PrintTab.swift:674-679.
- SliceJobDetailSheet's Print button awaits `viewModel.printSliceJob(jobId:)` then `dismiss()`.
- The test suite has 11-14 PRE-EXISTING flaky failures (fixture drift + URLProtocolStub races) — run only the new test class, not the full suite.

---

### Task 1: AppViewModel state machine + unit tests

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift`
- Create: `BambuGatewayTests/PrintFlowTests.swift`

- [ ] **Step 1: Add the state enum and published property**

In `AppViewModel.swift`, replace the `showPrintSuccessModal` declaration (lines 121-124) with:

```swift
    /// Send-to-printer flow state driving the root-level PrintProgressModal.
    /// nil = no modal. Set by `handlePrintResponse` (all print paths funnel
    /// through it); advanced by `applyUploadPoll`; cleared by `dismissPrintFlow()`.
    @Published var printFlow: PrintFlowState?
```

Add the enum near the top of the file (outside the class, above `AppViewModel`, or next to other support types — match file style):

```swift
enum PrintFlowState: Equatable {
    /// Gateway accepted the print and is uploading to the printer.
    /// `progress` is nil until the first poll lands.
    case uploading(progress: Double?)
    case success
    case failed(String)
}
```

- [ ] **Step 2: Set the flow inside handlePrintResponse and delete the three call-site lines**

In `handlePrintResponse`, right after the existing `if let uploadId = response.uploadId { startUploadPolling(uploadId: uploadId) }` block, add:

```swift
        // LAN prints upload in the background — show honest progress.
        // Cloud prints come back already confirmed (`status: "printing"`).
        printFlow = response.uploadId != nil ? .uploading(progress: nil) : .success
```

Then delete the `showPrintSuccessModal = true` lines at the three call sites (submitPrint ~451, consumeReadyJob ~855, printSliceJob ~1326). Each immediately follows `handlePrintResponse`; the surrounding `lastPrintEstimate`/`lastPrintPrinterName` assignments stay.

- [ ] **Step 3: Rename the dismiss function**

Replace `dismissPrintSuccessModal()` (line 607) with:

```swift
    /// Closes the print progress/success modal. Does NOT cancel an in-flight
    /// upload — polling keeps feeding `uploadProgress` (Print-tab card), but
    /// the modal is not re-presented when the upload later completes.
    func dismissPrintFlow() {
        printFlow = nil
        lastPrintEstimate = nil
        lastPrintPrinterName = nil
    }
```

Grep for `dismissPrintSuccessModal` and `showPrintSuccessModal` across the repo — the PrintTab usages get removed in Task 2; any other references must be updated here.

- [ ] **Step 4: Extract poll handling into applyUploadPoll**

Replace the inline status handling inside `startUploadPolling`'s loop (lines 1157-1174) so the body becomes:

```swift
                do {
                    let state = try await gatewayClient().fetchUploadProgress(uploadId: uploadId)
                    if applyUploadPoll(state) { return }
                } catch {
                    // ignore transient network errors
                }
```

And add (internal, NOT private — tests drive it directly):

```swift
    /// Applies one upload-progress poll to published state. Returns true when
    /// the upload reached a terminal state (polling should stop). The
    /// `if case .uploading` guards keep a user-dismissed modal dismissed.
    @discardableResult
    func applyUploadPoll(_ state: UploadProgressResponse) -> Bool {
        uploadProgress = state.progress
        if case .uploading = printFlow {
            printFlow = .uploading(progress: state.progress)
        }
        switch state.status {
        case "completed":
            finishUploadPolling()
            if case .uploading = printFlow { printFlow = .success }
            return true
        case "cancelled":
            finishUploadPolling()
            startedPrintContext = nil
            if case .uploading = printFlow { printFlow = nil }
            setMessage("Upload cancelled.", .info)
            return true
        case "failed":
            finishUploadPolling()
            if case .uploading = printFlow {
                printFlow = .failed(state.error ?? "Upload failed.")
            }
            setMessage(state.error ?? "Upload failed.", .error)
            return true
        default:
            return false
        }
    }
```

Keep the existing `setMessage` side effects exactly as today (they're the fallback signal when the modal was dismissed). Also add a small internal hook so tests don't leak the polling task:

```swift
    /// Test hook: stops the background upload-polling task.
    func stopUploadPollingForTests() {
        uploadPollingTask?.cancel()
    }
```

- [ ] **Step 5: Write the unit tests**

Create `BambuGatewayTests/PrintFlowTests.swift`. Look at an existing AppViewModel test file first and construct the view model the same way the suite does (settings store / client stubbing conventions). Then implement these cases (names follow the repo's `test_<scenario>_<expectedResult>` style):

```swift
import XCTest
@testable import BambuGateway

@MainActor
final class PrintFlowTests: XCTestCase {
    private func makeUploadState(
        status: String, progress: Double = 0, error: String? = nil
    ) -> UploadProgressResponse {
        UploadProgressResponse(
            uploadId: "u1", status: status, progress: progress,
            bytesSent: Int(progress), totalBytes: 100, error: error
        )
    }

    func test_printResponseWithUploadId_entersUploadingState() { /* build PrintResponse with uploadId "u1", call handlePrintResponse, assert printFlow == .uploading(progress: nil), then viewModel.stopUploadPollingForTests() */ }

    func test_printResponseWithoutUploadId_entersSuccessState() { /* PrintResponse with uploadId nil → printFlow == .success */ }

    func test_pollProgress_updatesUploadingProgress() { /* printFlow = .uploading(progress: nil); applyUploadPoll(status "uploading", progress 42) returns false; printFlow == .uploading(progress: 42); uploadProgress == 42 */ }

    func test_pollCompleted_flipsToSuccess() { /* .uploading → applyUploadPoll(status "completed", progress 100) returns true; printFlow == .success */ }

    func test_pollFailed_flipsToFailedWithMessage() { /* .uploading → applyUploadPoll(status "failed", error "boom") returns true; printFlow == .failed("boom") */ }

    func test_pollCancelled_dismissesFlow() { /* .uploading → applyUploadPoll(status "cancelled") returns true; printFlow == nil */ }

    func test_pollCompletedAfterDismiss_staysDismissed() { /* printFlow = nil (user dismissed); applyUploadPoll(status "completed") returns true; printFlow == nil */ }

    func test_dismissPrintFlow_clearsEstimateAndPrinterName() { /* set printFlow/.success + lastPrintEstimate/lastPrintPrinterName, dismissPrintFlow(), all nil */ }
}
```

Fill in the bodies for real — construct `PrintResponse` with its memberwise/decoded init the same way other tests in the suite build models (if `PrintResponse` lacks a usable initializer from tests, decode it from inline JSON `Data`, which is the established pattern for Decodable models).

- [ ] **Step 6: Build & run ONLY the new test class on the iPhone 16 / iOS 18.6 simulator**

```bash
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -only-testing:BambuGatewayTests/PrintFlowTests 2>&1 | tail -20
```
Expected: all PrintFlowTests pass. (Full-suite failures are pre-existing; do not chase them.)

Note: the app target won't compile yet if anything still references `showPrintSuccessModal` — PrintTab does (line 69). For THIS task, update PrintTab minimally by deleting the sheet attachment (lines 69-75) so the target builds; Task 2 adds the replacement UI. Mention this in the commit body.

- [ ] **Step 7: Commit**

```bash
git add BambuGateway/App/AppViewModel.swift BambuGateway/Views/PrintTab.swift BambuGatewayTests/PrintFlowTests.swift
git commit -m "feat: PrintFlowState machine for send-to-printer progress"
```
(Body bullets: state machine replaces showPrintSuccessModal; modal decision moved into handlePrintResponse; poll transitions extracted + tested. End with the Co-Authored-By trailer.)

---

### Task 2: PrintProgressModal + root attachment + subtitle

**Files:**
- Rename: `BambuGateway/Views/PrintSuccessModal.swift` → `BambuGateway/Views/PrintProgressModal.swift`
- Modify: `BambuGateway/Views/ContentView.swift`
- Modify: `BambuGateway/Views/PrintTab.swift` (subtitle only; sheet already removed in Task 1)

- [ ] **Step 1: Rewrite the modal**

`git mv BambuGateway/Views/PrintSuccessModal.swift BambuGateway/Views/PrintProgressModal.swift`, then replace its contents. Keep the existing success-state content (green check, `titleText`, `PrintEstimationCard`, Done button styling) — read the old file fully first and carry its pieces over. Shape:

```swift
import SwiftUI

/// Root-attached modal for the send-to-printer flow: live upload progress
/// while the gateway streams the file to the printer, flipping to the
/// success summary when the upload completes (or an error state on failure).
struct PrintProgressModal: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch viewModel.printFlow {
                    case .uploading(let progress):
                        uploadingContent(progress: progress)
                    case .failed(let message):
                        failedContent(message: message)
                    case .success, .none:
                        successContent   // existing green-check content
                    }
                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { doneButton }  // existing style
        }
        .interactiveDismissDisabled(false)
        .animation(.easeInOut(duration: 0.2), value: viewModel.printFlow)
    }
}
```

`uploadingContent(progress:)`:
- `Image(systemName: "arrow.up.doc.fill")` (or similar printer/up icon), accent tint, same 56pt sizing as the checkmark.
- Title: `"Sending to \(viewModel.lastPrintPrinterName ?? "printer")…"` (font/title3 semibold, matching success title).
- `ProgressView(value: progress, total: 100)` when progress != nil, else indeterminate `ProgressView()`; percent text (`monospacedDigit`, secondary) when progress != nil.
- Destructive bordered "Cancel upload" button calling `Task { await viewModel.cancelUpload() }`, disabled while `viewModel.isCancellingUpload` (mirror the PrintTab uploadCard's button at PrintTab.swift:597-605).
- The estimate card may also be shown here if `lastPrintEstimate` exists (nice context while waiting) — include it.

`failedContent(message:)`: `xmark.octagon.fill` in red, "Couldn't start print" title, the message as secondary multiline text.

Done button: existing prominent style, action `viewModel.dismissPrintFlow()`.

Update the `#Preview` blocks at the bottom of the old file to construct states meaningfully or drop them if they can't be built without a full AppViewModel (check how other views' previews handle it — follow suit).

- [ ] **Step 2: Attach at root**

In `ContentView.swift` (body chain, after the `.fullScreenCover` at line 26-34), add:

```swift
        .sheet(isPresented: Binding(
            get: { viewModel.printFlow != nil },
            set: { if !$0 { viewModel.dismissPrintFlow() } }
        )) {
            PrintProgressModal(viewModel: viewModel)
        }
```

- [ ] **Step 3: Subtitle in PrintTab**

Replace `currentSlicingPhase` (PrintTab.swift:674-679) with:

```swift
    /// Subtitle under the submit buttons: the gateway's slicing phase while a
    /// slice job is in flight, or a generic "Preparing…" in the busy gaps
    /// before slicing starts and between slice-ready and the print response.
    private var currentSlicingPhase: String? {
        guard viewModel.isLoadingPreview || viewModel.isSubmitting else { return nil }
        guard let phase = viewModel.slicingPhase, !phase.isEmpty else { return "Preparing…" }
        return phase
    }
```

- [ ] **Step 4: Regenerate the Xcode project and build**

```bash
xcodegen generate
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add -A BambuGateway/Views/PrintProgressModal.swift BambuGateway/Views/PrintSuccessModal.swift BambuGateway/Views/ContentView.swift BambuGateway/Views/PrintTab.swift BambuGateway.xcodeproj
git commit -m "feat: send-to-printer progress modal at root level"
```
(Body: modal shows live upload progress and flips to success; attached above the TabView so Jobs-tab prints surface it too; Preparing… subtitle. Co-Authored-By trailer.)

---

### Task 3: Jobs-tab ordering + preview-modal path + verification

**Files:**
- Modify: `BambuGateway/Views/SliceJobDetailSheet.swift` (Print button, ~lines 198-220)
- Possibly modify: `BambuGateway/Views/GCodePreviewModal.swift` (verify first)

- [ ] **Step 1: Dismiss-first print action in SliceJobDetailSheet**

Change the Print button action from await-then-dismiss to dismiss-then-fire:

```swift
Button {
    let jobId = job.jobId
    dismiss()
    Task { await viewModel.printSliceJob(jobId: jobId) }
} label: { ... unchanged ... }
```

Remove the now-dead `activeAction = .print` bookkeeping for this button if nothing else depends on it (check `activeAction`'s other uses in the file — the Preview button likely still uses it; only remove what's exclusively print-path).

- [ ] **Step 2: Verify the preview-modal print path presents cleanly**

`GCodePreviewModal` is a `fullScreenCover` (PrintTab.swift:66-68). Find its Print action: if it triggers a print (via `printSliceJob`/`consumeReadyJob` path) while the cover stays presented, the root `.sheet` cannot present over it. Verify the action dismisses the cover (`viewModel.isShowingPreview = false` or `dismiss()`) before/when the print fires; if it doesn't, make it dismiss first, same pattern as Step 1. Report what you found either way.

- [ ] **Step 3: Re-run the new tests + build**

```bash
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -only-testing:BambuGatewayTests/PrintFlowTests 2>&1 | tail -5
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```
Expected: tests pass, BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/SliceJobDetailSheet.swift BambuGateway/Views/GCodePreviewModal.swift
git commit -m "fix: dismiss sheets before the print progress modal presents"
```

---

### Task 4: Manual verification (user checkpoint)

- [ ] Deploy to the iPhone 16 Pro (`/ios-deploy`).
- [ ] Print tab: slice + print a file to a LAN printer — subtitle shows phases then "Preparing…", modal appears showing "Sending to {printer}…" with a counting percent, flips to the green-check summary when the upload completes.
- [ ] Jobs tab: print a ready job — detail sheet closes immediately, progress modal appears, same lifecycle.
- [ ] Cancel mid-upload from the modal — modal closes, "Upload cancelled." message shows.
- [ ] Dismiss the modal mid-upload — Print tab's inline card still shows progress; modal does NOT re-appear on completion.
