# Slice Jobs List on Print Tab

## Goal

Show the user their slice-job history on the Print tab when no file is selected, so they can revisit, reprint, or clean up past prints without leaving the tab. Mirrors the web app's Jobs view, but with the live "is this slice still printing right now?" state stripped out — the iOS Dashboard already surfaces live printer state, and duplicating it here adds noise.

## Placement

Inside `PrintTab.fileArea`, in the "no file selected" branch only:

- When `viewModel.selectedFile == nil` AND `viewModel.isGatewayConfigured`: render `SliceJobsSection` directly below `importTilesRow`, separated by the existing 12pt `VStack` spacing.
- When the gateway-not-configured card is shown: section is hidden (no list to fetch).
- When a file is selected: section is hidden and polling stops.

## Status mapping

A `SliceJobDisplayStatus` derived from the raw `SliceJob.status`:

| Raw status | Display status | Badge label | Badge color |
|---|---|---|---|
| `queued` | `queued` | "Queued" | secondary/gray |
| `slicing` | `slicing` | "Slicing N%" | accent blue |
| `uploading` | `uploading` | "Uploading N%" | accent blue |
| `printing` | `ready` | "Ready" | green |
| `ready` | `ready` | "Ready" | green |
| `failed` | `failed` | "Failed" | red |
| `cancelled` | `cancelled` | "Cancelled" | secondary/gray, strikethrough |

Critically, the `printing` raw status is collapsed into `ready` — there is **no live cross-reference to `PrinterStatus`** to decide whether a print is still running. The slice-job row reflects only what the gateway returns.

## Section UI

A rounded card matching the existing `slicingSettingsSection` styling.

```
┌─ Slice jobs ─────── Clear failed (2)  Clear completed (5) ─┐
│                                                            │
│   [thumb] filename.3mf                       [Ready]       │
│           Printer A · 3m ago                               │
│                                                            │
│   [thumb] another.3mf                        [Slicing 42%] │
│           — · 12s ago                                      │
│           ████████░░░░░░░░░░░░░░░░░░░                       │
│                                                            │
│   [thumb] busted.3mf                         [Failed]      │
│           Printer B · 1h ago                               │
│           Slicer error: invalid filament profile           │
└────────────────────────────────────────────────────────────┘
```

- **Header row**: title "Slice jobs" on the leading edge, two trailing borderless buttons "Clear failed (n)" and "Clear completed (n)". Each button hides its `(n)` when zero and disables when its count is zero or its mutation is in flight.
- **Empty state**: small secondary-styled `Text("No slice jobs yet.")`. No illustration.
- **Loading**: cold-load only — show a centered `ProgressView` when `sliceJobs` is empty AND `isLoadingSliceJobs == true`. Subsequent refreshes don't show a spinner.
- **Row**: `Button` whose label is a `HStack` with thumbnail, title block, and trailing status pill. Tapping opens `SliceJobDetailSheet`.
  - **Thumbnail**: `AsyncImage` from `GET /api/slice-jobs/{id}/thumbnail`, 56×56pt, rounded 8pt corner. When `has_thumbnail == false`, render a placeholder `doc.fill` icon on `Color.cardBackground.opacity(0.5)`.
  - **Title block**: filename (subheadline, semibold, single line, middle-truncated) above a caption row "PrinterName · 3m ago". When the job has no `printer_id`, the printer segment is replaced with `—`. Below the caption, error string (if any) in red caption.
  - **Status pill**: capsule with label per the table above. Uses 11pt semibold. For in-flight states, the percent is appended.
  - **Progress bar**: only on `queued`/`slicing`/`uploading` rows, below the row content, 2pt tall, `Color.accentBlue` tint.

## Detail sheet (`SliceJobDetailSheet`)

Presented as a `.sheet` with `.medium` detent.

Layout, top to bottom:

1. **Hero**: thumbnail full-width with 4:3 aspect ratio, rounded 12pt; falls back to placeholder icon card when no thumbnail.
2. **Title**: filename (title3, semibold) + status pill underneath.
3. **Metadata block**:
   - Printer name (or "—") with `printer.fill` icon.
   - Created time, formatted as "3 minutes ago" (`RelativeDateTimeFormatter`).
   - Phase (when in-flight, non-empty).
   - Error string (when present), red foreground.
4. **`PrintEstimationCard`**: reused as-is when `job.estimate != nil`.
5. **Actions**, in order:
   - **Print** (filled primary, `Color.accentBlue`): visible when `display == .ready` AND `(output_size ?? 0) > 0`. Calls `viewModel.printSliceJob(jobId:)`. Always targets the dashboard's currently selected printer (`viewModel.selectedPrinterId`); button is **disabled** when `selectedPrinterId` is empty or the resolved `selectedPrinter` is nil.
   - **Cancel** (tonal destructive): visible only when raw status is `queued`/`slicing`/`uploading`. Calls `viewModel.cancelSliceJob(jobId:)`. No confirmation alert.
   - **Delete** (tonal destructive): always visible. Confirmation alert: "Delete this slice job? \<filename\> and its sliced 3MF will be permanently removed. This can't be undone." → "Cancel" / "Delete". On confirm, calls `viewModel.deleteSliceJob(jobId:)` and dismisses the sheet.

While any row-level mutation is in flight, all three buttons are disabled and the active one shows a `ProgressView` in place of its icon.

## Data flow

`AppViewModel` gains:

```swift
@Published private(set) var sliceJobs: [SliceJob] = []
@Published private(set) var isLoadingSliceJobs: Bool = false
@Published private(set) var sliceJobMutationsInFlight: Set<String> = []  // job ids
@Published private(set) var clearFailedInFlight: Bool = false
@Published private(set) var clearCompletedInFlight: Bool = false

func startSliceJobsPolling()
func stopSliceJobsPolling()
func refreshSliceJobs() async
func cancelSliceJob(jobId: String) async
func deleteSliceJob(jobId: String) async
func clearSliceJobs(failedOnly: Bool) async
func printSliceJob(jobId: String) async
```

- `startSliceJobsPolling()` is called from `SliceJobsSection`'s `.task` modifier.
- `stopSliceJobsPolling()` from `.onDisappear`. Polling also pauses when `selectedFile != nil` (the section unmounts in that case anyway).
- The poller is a single `Task` stored on `AppViewModel`; calling `start` while one is active is a no-op. It loops with adaptive delay:
  - **2s** when any job has a non-terminal raw status (`queued`/`slicing`/`uploading`).
  - **30s** when all jobs are terminal (or list is empty).
- Mutations call the corresponding `GatewayClient` method, then immediately trigger a `refreshSliceJobs()` so the UI updates without waiting for the next tick.
- `sliceJobMutationsInFlight` tracks per-row activity so the row UI can show spinners and disable its buttons.
- The sort order is `created_at` descending, matching web.

## Networking changes

`GatewayClient` gains:

```swift
func listSliceJobs() async throws -> [SliceJob]
func deleteSliceJob(jobId: String) async throws
func clearSliceJobs(statuses: [String]?) async throws -> [SliceJob]
func sliceJobThumbnailURL(jobId: String) -> URL?
```

- `listSliceJobs` hits `GET /api/slice-jobs`, decodes `SliceJobListResponse`.
- `deleteSliceJob` hits `DELETE /api/slice-jobs/{id}` (204 No Content).
- `clearSliceJobs(statuses:)` hits `POST /api/slice-jobs/clear` with JSON body `{"statuses": [...] | null}`. Returns the cleared jobs.
- `sliceJobThumbnailURL` resolves to `<gatewayURL>/api/slice-jobs/{id}/thumbnail` for use with `AsyncImage`. Returns `nil` if the gateway URL is not configured.
- `printFromJob(jobId:printerId:)` already exists; reused unchanged.

## Model changes

`SliceJobStatusResponse` is **renamed to `SliceJob`** and extended with the additional fields the list API returns. The existing `createSliceJob` and `fetchSliceJob` callers are updated to use the new name.

```swift
struct SliceJob: Codable, Identifiable {
    let jobId: String
    let status: String
    let progress: Int
    let phase: String?
    let filename: String
    let printerId: String?
    let autoPrint: Bool
    let error: String?
    let createdAt: String   // ISO-8601; parsed on display.
    let updatedAt: String   // ISO-8601; parsed on display.
    let outputSize: Int?
    let hasThumbnail: Bool
    let estimate: PrintEstimate?

    var id: String { jobId }
    var isTerminal: Bool { /* same as before */ }
}

struct SliceJobListResponse: Codable {
    let jobs: [SliceJob]
}
```

- All snake_case → camelCase mapping is handled by the existing `convertFromSnakeCase` decoder strategy (per the comment already on `SliceJobStatusResponse`).
- `createdAt` / `updatedAt` stay as `String` and are parsed at display time using `ISO8601DateFormatter` (or `Date.ISO8601FormatStyle`). The shared `GatewayClient` decoder does not currently set a date strategy, and adding one project-wide would need an audit of every existing `Date`-typed model — out of scope for this change.

## Files touched / added

**Modified**:
- `BambuGateway/Models/GatewayModels.swift` — rename `SliceJobStatusResponse` → `SliceJob`, add new fields, add `SliceJobListResponse`.
- `BambuGateway/Networking/GatewayClient.swift` — add `listSliceJobs`, `deleteSliceJob`, `clearSliceJobs`, `sliceJobThumbnailURL`. Update existing slice-job method signatures to return `SliceJob`.
- `BambuGateway/App/AppViewModel.swift` — add slice-jobs state, polling task, mutation methods.
- `BambuGateway/Views/PrintTab.swift` — wire `SliceJobsSection` into the no-file branch; present `SliceJobDetailSheet` via state on `PrintTab` (selected job id).

**Added**:
- `BambuGateway/Views/SliceJobsSection.swift` — section view (header + list + empty/loading states).
- `BambuGateway/Views/SliceJobDetailSheet.swift` — detail sheet with metadata, estimation, and actions.

XcodeGen will pick up new files automatically; no `project.yml` change.

## Out of scope

- File downloads / share-sheet for sliced or original 3MF.
- Loading the sliced 3MF into `GCodePreviewModal` from the detail sheet.
- Mirroring this change to the web `SliceJobsList` (tracked as a follow-up).
- Auto-refresh via push notifications. Polling only.
- Per-job printer override in the detail sheet — Print always targets `viewModel.selectedPrinterId`.
