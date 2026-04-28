# Slice Jobs List on Print Tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the user's slice-job history on the Print tab below the Files / MakerWorld import tiles when no file is selected, so they can revisit, reprint, cancel, or delete past jobs without leaving the tab.

**Architecture:** A new `SliceJobsSection` view is rendered inside `PrintTab`'s no-file branch. It owns a `.task` that drives polling against `AppViewModel`, which holds the slice-jobs state and exposes mutation methods. Tapping a row presents a `SliceJobDetailSheet` with metadata, an estimation card, and Print / Cancel / Delete actions. A `SliceJobDisplayStatus` enum collapses the gateway's `printing` raw status into `ready`, intentionally dropping any live cross-reference to printer state — that lives on the Dashboard tab.

**Tech Stack:** Swift 5, SwiftUI, iOS 18+, `URLSession`, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-04-28-slice-jobs-list-print-tab-design.md`

---

## File map

**Modified:**
- `BambuGateway/Models/GatewayModels.swift` — replace `SliceJobStatusResponse` with a richer `SliceJob` struct, add `SliceJobListResponse`, add `SliceJobDisplayStatus`.
- `BambuGateway/Networking/GatewayClient.swift` — `listSliceJobs`, `deleteSliceJob`, `clearSliceJobs`, `sliceJobThumbnailURL`. Update `createSliceJob` / `fetchSliceJob` return types to `SliceJob`.
- `BambuGateway/App/AppViewModel.swift` — slice-jobs state, polling, mutations. Update existing call sites that referenced `SliceJobStatusResponse`.
- `BambuGateway/Views/PrintTab.swift` — render `SliceJobsSection` in the no-file branch and present `SliceJobDetailSheet`.

**Added:**
- `BambuGateway/Views/SliceJobsSection.swift` — header + list + empty/loading states.
- `BambuGateway/Views/SliceJobDetailSheet.swift` — detail sheet with Print / Cancel / Delete.
- `BambuGatewayTests/SliceJobDecodingTests.swift` — JSON decoding tests.
- `BambuGatewayTests/SliceJobDisplayStatusTests.swift` — status mapping tests.

XcodeGen picks up new files automatically; no `project.yml` change required.

---

## Task 1: Add `SliceJob` model with new fields (decoding tests first)

**Files:**
- Test: `BambuGatewayTests/SliceJobDecodingTests.swift`
- Modify: `BambuGateway/Models/GatewayModels.swift:321-342`

This task replaces the existing `SliceJobStatusResponse` struct with a richer `SliceJob` struct. The existing struct has 8 fields; the new one adds `createdAt`, `updatedAt`, `outputSize`, `hasThumbnail`, `estimate`, all of which the gateway already returns from both `GET /api/slice-jobs` and `GET /api/slice-jobs/{id}`. Timestamps stay as `String` because the shared `JSONDecoder` in `GatewayClient.decode` does not configure a date decoding strategy and adding one project-wide would require auditing every other `Date`-typed model.

- [ ] **Step 1: Write the failing decoding test**

Create `BambuGatewayTests/SliceJobDecodingTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class SliceJobDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> SliceJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SliceJob.self, from: Data(json.utf8))
    }

    func test_decodesAllFields_fromListEntry() throws {
        let json = """
        {
          "job_id": "abc-123",
          "status": "ready",
          "progress": 100,
          "phase": null,
          "filename": "benchy.3mf",
          "printer_id": "P1S-001",
          "auto_print": false,
          "error": null,
          "created_at": "2026-04-28T15:30:00Z",
          "updated_at": "2026-04-28T15:31:12Z",
          "output_size": 482910,
          "has_thumbnail": true,
          "estimate": {
            "total_filament_grams": 12.5,
            "total_seconds": 1830
          },
          "settings_transfer": null
        }
        """
        let job = try decode(json)
        XCTAssertEqual(job.jobId, "abc-123")
        XCTAssertEqual(job.status, "ready")
        XCTAssertEqual(job.progress, 100)
        XCTAssertNil(job.phase)
        XCTAssertEqual(job.filename, "benchy.3mf")
        XCTAssertEqual(job.printerId, "P1S-001")
        XCTAssertFalse(job.autoPrint)
        XCTAssertNil(job.error)
        XCTAssertEqual(job.createdAt, "2026-04-28T15:30:00Z")
        XCTAssertEqual(job.updatedAt, "2026-04-28T15:31:12Z")
        XCTAssertEqual(job.outputSize, 482910)
        XCTAssertTrue(job.hasThumbnail)
        XCTAssertEqual(job.estimate?.totalSeconds, 1830)
        XCTAssertEqual(job.id, "abc-123")
    }

    func test_decodesInFlightJob_withNullOutputAndEstimate() throws {
        let json = """
        {
          "job_id": "queued-1",
          "status": "slicing",
          "progress": 42,
          "phase": "Optimizing toolpath",
          "filename": "calibration.3mf",
          "printer_id": null,
          "auto_print": false,
          "error": null,
          "created_at": "2026-04-28T15:30:00Z",
          "updated_at": "2026-04-28T15:30:08Z",
          "output_size": null,
          "has_thumbnail": false,
          "estimate": null
        }
        """
        let job = try decode(json)
        XCTAssertEqual(job.status, "slicing")
        XCTAssertEqual(job.progress, 42)
        XCTAssertEqual(job.phase, "Optimizing toolpath")
        XCTAssertNil(job.printerId)
        XCTAssertNil(job.outputSize)
        XCTAssertFalse(job.hasThumbnail)
        XCTAssertNil(job.estimate)
    }

    func test_decodesListResponse_withMultipleJobs() throws {
        let json = """
        {
          "jobs": [
            {
              "job_id": "a",
              "status": "ready",
              "progress": 100,
              "phase": null,
              "filename": "one.3mf",
              "printer_id": null,
              "auto_print": false,
              "error": null,
              "created_at": "2026-04-28T15:30:00Z",
              "updated_at": "2026-04-28T15:31:00Z",
              "output_size": 100,
              "has_thumbnail": true,
              "estimate": null
            },
            {
              "job_id": "b",
              "status": "failed",
              "progress": 50,
              "phase": null,
              "filename": "two.3mf",
              "printer_id": null,
              "auto_print": false,
              "error": "boom",
              "created_at": "2026-04-28T16:00:00Z",
              "updated_at": "2026-04-28T16:00:30Z",
              "output_size": null,
              "has_thumbnail": false,
              "estimate": null
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SliceJobListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.jobs.count, 2)
        XCTAssertEqual(response.jobs[0].jobId, "a")
        XCTAssertEqual(response.jobs[1].error, "boom")
    }

    func test_isTerminal_classifiesStatuses() {
        let terminalStatuses = ["ready", "printing", "failed", "cancelled"]
        let liveStatuses = ["queued", "slicing", "uploading"]
        for raw in terminalStatuses {
            XCTAssertTrue(makeJob(status: raw).isTerminal, "expected \(raw) to be terminal")
        }
        for raw in liveStatuses {
            XCTAssertFalse(makeJob(status: raw).isTerminal, "expected \(raw) to be non-terminal")
        }
    }

    private func makeJob(status: String) -> SliceJob {
        SliceJob(
            jobId: "id",
            status: status,
            progress: 0,
            phase: nil,
            filename: "f.3mf",
            printerId: nil,
            autoPrint: false,
            error: nil,
            createdAt: "2026-04-28T15:30:00Z",
            updatedAt: "2026-04-28T15:30:00Z",
            outputSize: nil,
            hasThumbnail: false,
            estimate: nil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```
xcodebuild test \
  -project BambuGateway.xcodeproj \
  -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -only-testing:BambuGatewayTests/SliceJobDecodingTests
```

Expected: FAIL — `SliceJob` and `SliceJobListResponse` are undefined; `SliceJobStatusResponse` still exists in the codebase under that name.

- [ ] **Step 3: Replace `SliceJobStatusResponse` with `SliceJob` and add list response**

In `BambuGateway/Models/GatewayModels.swift`, replace lines 321-342 (the entire `SliceJobStatusResponse` struct) with:

```swift
struct SliceJob: Codable, Identifiable, Equatable {
    // Decoded via GatewayClient's `convertFromSnakeCase` strategy — do not add
    // explicit `CodingKeys` here. An explicit mapping would shadow the global
    // strategy and fail to decode `job_id`, `printer_id`, `auto_print`,
    // `created_at`, `updated_at`, `output_size`, `has_thumbnail`.
    let jobId: String
    let status: String
    let progress: Int
    let phase: String?
    let filename: String
    let printerId: String?
    let autoPrint: Bool
    let error: String?
    let createdAt: String
    let updatedAt: String
    let outputSize: Int?
    let hasThumbnail: Bool
    let estimate: PrintEstimate?

    var id: String { jobId }

    var isTerminal: Bool {
        switch status {
        case "ready", "printing", "failed", "cancelled":
            return true
        default:
            return false
        }
    }
}

struct SliceJobListResponse: Codable {
    let jobs: [SliceJob]
}
```

- [ ] **Step 4: Run tests to verify they pass (model only — call-site updates next step)**

Run the same `xcodebuild test` command. Expected: the four new tests pass. The build will likely **fail** in `GatewayClient.swift` and `AppViewModel.swift` because `SliceJobStatusResponse` is still referenced. That is expected; the next step fixes those call sites.

- [ ] **Step 5: Update existing `SliceJobStatusResponse` call sites to `SliceJob`**

In `BambuGateway/Networking/GatewayClient.swift` line 222, change:
```swift
let response = try decode(SliceJobStatusResponse.self, from: data)
```
to:
```swift
let response = try decode(SliceJob.self, from: data)
```

On line 226, change the return type:
```swift
func fetchSliceJob(jobId: String) async throws -> SliceJob {
    try await get(path: "/api/slice-jobs/\(jobId)")
}
```

In `BambuGateway/App/AppViewModel.swift` around line 720, change:
```swift
let initial: SliceJobStatusResponse
```
to:
```swift
let initial: SliceJob
```

- [ ] **Step 6: Run tests + build to verify the rename is complete**

Run:
```
xcodebuild test \
  -project BambuGateway.xcodeproj \
  -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -only-testing:BambuGatewayTests/SliceJobDecodingTests
```
Expected: build succeeds, all four `SliceJobDecodingTests` tests pass.

Also confirm no stragglers:
```
grep -RIn "SliceJobStatusResponse" BambuGateway BambuGatewayTests
```
Expected: no matches.

- [ ] **Step 7: Commit**

```bash
git add BambuGateway/Models/GatewayModels.swift \
        BambuGateway/Networking/GatewayClient.swift \
        BambuGateway/App/AppViewModel.swift \
        BambuGatewayTests/SliceJobDecodingTests.swift
git commit -m "$(cat <<'EOF'
Expand slice job model with list-view fields

- replace `SliceJobStatusResponse` with a richer `SliceJob` struct and add `SliceJobListResponse`
- add `created_at`, `updated_at`, `output_size`, `has_thumbnail`, and `estimate` so the new jobs list can render history
- timestamps stay as ISO-8601 strings to avoid forcing a project-wide date decoding strategy
EOF
)"
```

---

## Task 2: Add `SliceJobDisplayStatus` enum (mapping tests first)

**Files:**
- Test: `BambuGatewayTests/SliceJobDisplayStatusTests.swift`
- Modify: `BambuGateway/Models/GatewayModels.swift` (append after `SliceJobListResponse`)

This task adds the display-side status enum. It collapses `printing` into `ready` so the row never shows a "Printing" badge — the iOS Dashboard tab is the source of truth for live print state.

- [ ] **Step 1: Write the failing mapping test**

Create `BambuGatewayTests/SliceJobDisplayStatusTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class SliceJobDisplayStatusTests: XCTestCase {
    func test_printing_mapsToReady() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "printing"), .ready)
    }

    func test_ready_staysReady() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "ready"), .ready)
    }

    func test_inFlightStatuses_passThrough() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "queued"), .queued)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "slicing"), .slicing)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "uploading"), .uploading)
    }

    func test_terminalErrorStatuses_passThrough() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "failed"), .failed)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "cancelled"), .cancelled)
    }

    func test_unknownStatus_fallsBackToQueued() {
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: "wat"), .queued)
        XCTAssertEqual(SliceJobDisplayStatus(rawStatus: ""), .queued)
    }

    func test_isInFlight_trueOnlyForQueuedSlicingUploading() {
        XCTAssertTrue(SliceJobDisplayStatus.queued.isInFlight)
        XCTAssertTrue(SliceJobDisplayStatus.slicing.isInFlight)
        XCTAssertTrue(SliceJobDisplayStatus.uploading.isInFlight)
        XCTAssertFalse(SliceJobDisplayStatus.ready.isInFlight)
        XCTAssertFalse(SliceJobDisplayStatus.failed.isInFlight)
        XCTAssertFalse(SliceJobDisplayStatus.cancelled.isInFlight)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```
xcodebuild test \
  -project BambuGateway.xcodeproj \
  -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -only-testing:BambuGatewayTests/SliceJobDisplayStatusTests
```

Expected: FAIL — `SliceJobDisplayStatus` is undefined.

- [ ] **Step 3: Add the enum**

Append to `BambuGateway/Models/GatewayModels.swift`, right after the `SliceJobListResponse` struct added in Task 1:

```swift
/// View-side projection of `SliceJob.status`. Collapses the `printing`
/// raw status into `.ready` so the Print tab's slice-jobs list never
/// duplicates live print state — the Dashboard tab owns that.
enum SliceJobDisplayStatus: Equatable {
    case queued
    case slicing
    case uploading
    case ready
    case failed
    case cancelled

    init(rawStatus: String) {
        switch rawStatus {
        case "queued": self = .queued
        case "slicing": self = .slicing
        case "uploading": self = .uploading
        case "printing", "ready": self = .ready
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .queued
        }
    }

    var isInFlight: Bool {
        switch self {
        case .queued, .slicing, .uploading: return true
        case .ready, .failed, .cancelled: return false
        }
    }
}

extension SliceJob {
    var displayStatus: SliceJobDisplayStatus {
        SliceJobDisplayStatus(rawStatus: status)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same `xcodebuild test` command. Expected: all six `SliceJobDisplayStatusTests` tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Models/GatewayModels.swift \
        BambuGatewayTests/SliceJobDisplayStatusTests.swift
git commit -m "$(cat <<'EOF'
Collapse `printing` slice status into Ready for display

- add `SliceJobDisplayStatus` so the new jobs list renders the same affordances for printing and ready jobs
- the dashboard remains the only place that mirrors live printer state, keeping the print-tab list noise-free
EOF
)"
```

---

## Task 3: Extend `GatewayClient` with list / delete / clear / thumbnail helpers

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift`

This task adds four endpoint helpers. There are no unit tests in this task: networking goes through `URLSession` directly, the client has no injectable mock layer, and the existing networking code is also untested here — adding a mock layer is out of scope.

- [ ] **Step 1: Add `listSliceJobs`, `deleteSliceJob`, `clearSliceJobs`, `sliceJobThumbnailURL`**

In `BambuGateway/Networking/GatewayClient.swift`, immediately after the existing `cancelSliceJob` function (around line 235), add:

```swift
    /// Fetch every slice job the gateway currently knows about, newest first.
    func listSliceJobs() async throws -> [SliceJob] {
        let response: SliceJobListResponse = try await get(path: "/api/slice-jobs")
        return response.jobs
    }

    /// Delete a single slice job and its sliced 3MF on disk. 204 No Content.
    func deleteSliceJob(jobId: String) async throws {
        _ = try await request(
            path: "/api/slice-jobs/\(jobId)",
            method: "DELETE"
        )
    }

    /// Clear slice jobs in bulk. Pass nil to clear every terminal job;
    /// pass a list of statuses (e.g. `["failed"]`) to clear only those.
    /// Returns the jobs that were removed.
    @discardableResult
    func clearSliceJobs(statuses: [String]?) async throws -> [SliceJob] {
        struct ClearRequest: Encodable {
            let statuses: [String]?
        }
        let body = try JSONEncoder().encode(ClearRequest(statuses: statuses))
        let (data, _) = try await request(
            path: "/api/slice-jobs/clear",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let response: SliceJobListResponse = try decode(SliceJobListResponse.self, from: data)
        return response.jobs
    }

    /// URL of the slice-job thumbnail PNG for use with `AsyncImage`.
    /// Returns nil when the gateway base URL is not yet configured or invalid.
    func sliceJobThumbnailURL(jobId: String) -> URL? {
        try? resolveURL(path: "/api/slice-jobs/\(jobId)/thumbnail")
    }
```

- [ ] **Step 2: Build to verify the additions compile**

Run:
```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift
git commit -m "$(cat <<'EOF'
Wire slice-jobs list, delete, clear, and thumbnail to gateway

- expose `GET /api/slice-jobs`, `DELETE /api/slice-jobs/{id}`, and `POST /api/slice-jobs/clear`
- expose a thumbnail URL helper so `AsyncImage` can render row previews directly
EOF
)"
```

---

## Task 4: `AppViewModel` slice-jobs state, polling, and mutations

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift`

This task adds the published state the view will observe, the long-running polling driver, and the mutation methods. The polling driver is shaped to match the existing `startUploadPolling` pattern (lines 1093-1129) but exposed as a single `runSliceJobsPolling()` async function so the consuming view can drive lifecycle via SwiftUI's `.task` modifier (which cancels the task on view disappearance automatically).

- [ ] **Step 1: Add published state**

In `BambuGateway/App/AppViewModel.swift`, immediately after the existing `@Published var lastPrintPrinterName: String?` (line 86) and **before** `@Published var showPrintSuccessModal`, add:

```swift
    @Published private(set) var sliceJobs: [SliceJob] = []
    @Published private(set) var isLoadingSliceJobs: Bool = false
    /// Job ids whose row-level mutation (cancel / delete / print) is in flight.
    @Published private(set) var sliceJobMutationsInFlight: Set<String> = []
    @Published private(set) var clearFailedInFlight: Bool = false
    @Published private(set) var clearCompletedInFlight: Bool = false
```

- [ ] **Step 2: Add the polling driver and mutation methods**

Find the `private func startUploadPolling` function (around line 1093). Immediately **after** the `finishUploadPolling` function that follows it (ends around line 1135), add a new `// MARK: - Slice jobs` section:

```swift
    // MARK: - Slice jobs

    /// Long-running polling loop driven by SwiftUI's `.task` modifier.
    /// Returns when the surrounding Task is cancelled (i.e. the section view
    /// disappears or the gateway is unconfigured).
    func runSliceJobsPolling() async {
        guard isGatewayConfigured else { return }
        await refreshSliceJobs(isInitialLoad: true)
        while !Task.isCancelled {
            let hasInFlight = sliceJobs.contains { !$0.isTerminal }
            let delaySeconds: UInt64 = hasInFlight ? 2 : 30
            do {
                try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await refreshSliceJobs(isInitialLoad: false)
        }
    }

    func refreshSliceJobs(isInitialLoad: Bool = false) async {
        guard isGatewayConfigured else {
            sliceJobs = []
            isLoadingSliceJobs = false
            return
        }
        if isInitialLoad && sliceJobs.isEmpty {
            isLoadingSliceJobs = true
        }
        defer { isLoadingSliceJobs = false }
        do {
            let jobs = try await gatewayClient().listSliceJobs()
            sliceJobs = jobs.sorted { $0.createdAt > $1.createdAt }
        } catch {
            // Transient errors are silent; the next tick retries. Surface
            // nothing through `message` — the section view is auxiliary.
        }
    }

    func cancelSliceJob(jobId: String) async {
        guard !sliceJobMutationsInFlight.contains(jobId) else { return }
        sliceJobMutationsInFlight.insert(jobId)
        defer { sliceJobMutationsInFlight.remove(jobId) }
        do {
            try await gatewayClient().cancelSliceJob(jobId: jobId)
            await refreshSliceJobs()
        } catch {
            setMessage("Couldn't cancel job: \(error.localizedDescription)", .error)
        }
    }

    func deleteSliceJob(jobId: String) async {
        guard !sliceJobMutationsInFlight.contains(jobId) else { return }
        sliceJobMutationsInFlight.insert(jobId)
        defer { sliceJobMutationsInFlight.remove(jobId) }
        do {
            try await gatewayClient().deleteSliceJob(jobId: jobId)
            sliceJobs.removeAll { $0.jobId == jobId }
        } catch {
            setMessage("Couldn't delete job: \(error.localizedDescription)", .error)
        }
    }

    func clearSliceJobs(failedOnly: Bool) async {
        if failedOnly {
            guard !clearFailedInFlight else { return }
            clearFailedInFlight = true
        } else {
            guard !clearCompletedInFlight else { return }
            clearCompletedInFlight = true
        }
        defer {
            if failedOnly {
                clearFailedInFlight = false
            } else {
                clearCompletedInFlight = false
            }
        }
        do {
            _ = try await gatewayClient().clearSliceJobs(
                statuses: failedOnly ? ["failed"] : nil
            )
            await refreshSliceJobs()
        } catch {
            setMessage("Couldn't clear jobs: \(error.localizedDescription)", .error)
        }
    }

    /// Submit a print for a slice job that already has output. Always
    /// targets the dashboard's currently selected printer; no-ops otherwise.
    func printSliceJob(jobId: String) async {
        guard !sliceJobMutationsInFlight.contains(jobId) else { return }
        let printerId = selectedPrinterId
        guard !printerId.isEmpty else {
            setMessage("Select a printer on the Dashboard before reprinting.", .warning)
            return
        }
        sliceJobMutationsInFlight.insert(jobId)
        defer { sliceJobMutationsInFlight.remove(jobId) }
        do {
            let response = try await gatewayClient().printFromJob(
                jobId: jobId,
                printerId: printerId
            )
            setMessage("Print started: \(response.fileName)", .success)
            await refreshSliceJobs()
        } catch {
            setMessage("Couldn't start print: \(error.localizedDescription)", .error)
        }
    }
```

Notes for the implementer:
- `setMessage(_:_:)` already exists — search the file for `private func setMessage` to confirm the signature; it takes `(String, MessageLevel)`.
- `gatewayClient()` returns a fresh `GatewayClient` configured with the current base URL (line 1647).
- `selectedPrinterId` is `@Published var` (line 46) and is the dashboard's selection.
- `printFromJob` already exists on `GatewayClient` (line 260) and returns `PrintResponse` with `.fileName`.

- [ ] **Step 3: Build to verify**

Run:
```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/App/AppViewModel.swift
git commit -m "$(cat <<'EOF'
Add slice-jobs state, polling, and mutations to view model

- expose `sliceJobs`, in-flight mutation flags, and a `runSliceJobsPolling()` driver suited to SwiftUI's `.task`
- adaptive cadence of 2s while a job is non-terminal, 30s once everything settles
- print action always targets the dashboard's currently selected printer; warns if no printer is selected
EOF
)"
```

---

## Task 5: `SliceJobsSection` view (header + list + states)

**Files:**
- Create: `BambuGateway/Views/SliceJobsSection.swift`

This is the section that appears on the Print tab's no-file branch. It owns the polling lifecycle via `.task`, renders the header with two clear buttons, and lists rows. Tapping a row sets a binding owned by `PrintTab` so the detail sheet (built in Task 6) is presented from the tab level.

- [ ] **Step 1: Create the file**

Create `BambuGateway/Views/SliceJobsSection.swift`:

```swift
import SwiftUI

struct SliceJobsSection: View {
    @ObservedObject var viewModel: AppViewModel
    /// Set by tapping a row; `PrintTab` observes this to present the detail sheet.
    @Binding var selectedJobId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            VStack(spacing: 0) {
                if viewModel.sliceJobs.isEmpty {
                    if viewModel.isLoadingSliceJobs {
                        loadingRow
                    } else {
                        emptyRow
                    }
                } else {
                    ForEach(Array(viewModel.sliceJobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 {
                            Divider().padding(.leading, 14)
                        }
                        SliceJobRow(job: job) {
                            selectedJobId = job.jobId
                        }
                    }
                }
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .task {
            await viewModel.runSliceJobsPolling()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Slice jobs")
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            clearFailedButton
            clearCompletedButton
        }
        .padding(.top, 4)
    }

    private var failedCount: Int {
        viewModel.sliceJobs.filter { $0.status == "failed" }.count
    }

    private var terminalCount: Int {
        viewModel.sliceJobs.filter { $0.isTerminal }.count
    }

    private var clearFailedButton: some View {
        Button {
            Task { await viewModel.clearSliceJobs(failedOnly: true) }
        } label: {
            HStack(spacing: 4) {
                if viewModel.clearFailedInFlight {
                    ProgressView().controlSize(.mini)
                }
                Text(failedCount > 0 ? "Clear failed (\(failedCount))" : "Clear failed")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(failedCount > 0 ? Color.red : Color.secondary)
        .disabled(failedCount == 0 || viewModel.clearFailedInFlight)
    }

    private var clearCompletedButton: some View {
        Button {
            Task { await viewModel.clearSliceJobs(failedOnly: false) }
        } label: {
            HStack(spacing: 4) {
                if viewModel.clearCompletedInFlight {
                    ProgressView().controlSize(.mini)
                }
                Text(terminalCount > 0 ? "Clear completed (\(terminalCount))" : "Clear completed")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(terminalCount > 0 ? Color.accentBlue : Color.secondary)
        .disabled(terminalCount == 0 || viewModel.clearCompletedInFlight)
    }

    // MARK: - Empty / loading rows

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Loading slice jobs…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var emptyRow: some View {
        HStack {
            Text("No slice jobs yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

// MARK: - Row

private struct SliceJobRow: View {
    let job: SliceJob
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    thumbnail
                    title
                    Spacer(minLength: 8)
                    statusPill
                }
                if job.displayStatus.isInFlight {
                    ProgressView(value: progressValue, total: 100)
                        .tint(Color.accentBlue)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var progressValue: Double {
        Double(max(0, min(100, job.progress)))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if job.hasThumbnail, let url = SliceJobThumbnail.url(for: job.jobId) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                default:
                    thumbnailPlaceholder
                }
            }
            .frame(width: 56, height: 56)
            .background(Color(uiColor: .systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            thumbnailPlaceholder
                .frame(width: 56, height: 56)
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var thumbnailPlaceholder: some View {
        Image(systemName: "doc.fill")
            .font(.system(size: 20))
            .foregroundStyle(.tertiary)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.filename)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(metadataLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let error = job.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .lineLimit(2)
            }
        }
    }

    private var metadataLine: String {
        let printer = job.printerId?.isEmpty == false ? job.printerId! : "—"
        let when = SliceJobRelativeTime.format(job.createdAt)
        return "\(printer) · \(when)"
    }

    private var statusPill: some View {
        let style = SliceJobBadgeStyle.style(for: job.displayStatus)
        let label = SliceJobBadgeStyle.label(for: job)
        return Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(style.background)
            .foregroundStyle(style.foreground)
            .clipShape(Capsule())
            .strikethrough(job.displayStatus == .cancelled)
    }
}

// MARK: - Helpers

enum SliceJobThumbnail {
    /// Resolves through `AppViewModel.gatewayBaseURL` indirectly: callers go
    /// through `GatewayClient.sliceJobThumbnailURL`. This helper is provided
    /// so the row view doesn't have to take a `GatewayClient` dependency —
    /// the row reads the gateway URL from the global default the app stores.
    static func url(for jobId: String) -> URL? {
        let store = AppSettingsStore.shared
        let base = store.gatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              var components = URLComponents(string: base),
              components.host?.isEmpty == false else {
            return nil
        }
        components.path = "/api/slice-jobs/\(jobId)/thumbnail"
        return components.url
    }
}

enum SliceJobRelativeTime {
    static func format(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

enum SliceJobBadgeStyle {
    struct Style {
        let background: Color
        let foreground: Color
    }

    static func style(for status: SliceJobDisplayStatus) -> Style {
        switch status {
        case .queued:
            return Style(background: Color.secondary.opacity(0.18), foreground: .secondary)
        case .slicing, .uploading:
            return Style(background: Color.accentBlue.opacity(0.18), foreground: .accentBlue)
        case .ready:
            return Style(background: Color.green.opacity(0.18), foreground: .green)
        case .failed:
            return Style(background: Color.red.opacity(0.18), foreground: .red)
        case .cancelled:
            return Style(background: Color.secondary.opacity(0.18), foreground: .secondary)
        }
    }

    static func label(for job: SliceJob) -> String {
        switch job.displayStatus {
        case .queued: return "Queued"
        case .slicing: return "Slicing \(job.progress)%"
        case .uploading: return "Uploading \(job.progress)%"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}
```

Notes for the implementer:
- `Color.cardBackground` and `Color.accentBlue` are already used throughout `PrintTab.swift` — they exist as `Color` extensions in the project (search for them to confirm).
- `AppSettingsStore.shared` is the UserDefaults-backed settings hub used elsewhere in the project (see `CLAUDE.md`). Confirm the actual API by `grep -RIn "AppSettingsStore" BambuGateway` — adjust the access expression if it's not `.shared.gatewayBaseURL`. If the type doesn't expose a singleton, fall back to taking the gateway URL through a `viewModel.sliceJobThumbnailURL(for:)` passthrough on `AppViewModel` instead.

- [ ] **Step 2: Verify `AppSettingsStore.shared.gatewayBaseURL` is the correct access path**

Run:
```
grep -RIn "AppSettingsStore" BambuGateway | head -20
```

Inspect the result. If `AppSettingsStore` is a singleton with a `gatewayBaseURL` property, the code in Step 1 stands. If not (e.g. it's an `@MainActor` class instantiated only in `BambuGatewayApp`), replace the `SliceJobThumbnail.url(for:)` body with a call routed through the view model:

In `BambuGateway/App/AppViewModel.swift`, add:
```swift
    func sliceJobThumbnailURL(for jobId: String) -> URL? {
        gatewayClient().sliceJobThumbnailURL(jobId: jobId)
    }
```

In `BambuGateway/Views/SliceJobsSection.swift`, drop the `SliceJobThumbnail` enum and change the row to take `viewModel: AppViewModel` so it can call `viewModel.sliceJobThumbnailURL(for: job.jobId)`. Update the `SliceJobsSection` `ForEach` to pass the view model into `SliceJobRow`.

- [ ] **Step 3: Build to verify**

Run:
```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/SliceJobsSection.swift \
        BambuGateway/App/AppViewModel.swift
git commit -m "$(cat <<'EOF'
Add slice-jobs section view for the Print tab

- header with Clear failed and Clear completed buttons
- one row per job with thumbnail, filename, printer, relative time, status pill, and inline progress bar for in-flight jobs
- polling lifecycle is driven by SwiftUI's `.task`, so the loop stops the moment the section unmounts
EOF
)"
```

---

## Task 6: `SliceJobDetailSheet` view

**Files:**
- Create: `BambuGateway/Views/SliceJobDetailSheet.swift`

The detail sheet is presented from `PrintTab` when a row is tapped. It shows the thumbnail, filename, status, metadata, the existing `PrintEstimationCard` if estimate is present, and three actions.

- [ ] **Step 1: Create the file**

Create `BambuGateway/Views/SliceJobDetailSheet.swift`:

```swift
import SwiftUI

struct SliceJobDetailSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let jobId: String
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    private var job: SliceJob? {
        viewModel.sliceJobs.first(where: { $0.jobId == jobId })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let job {
                    content(for: job)
                } else {
                    missingJob
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Job present

    @ViewBuilder
    private func content(for job: SliceJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero(for: job)
                titleBlock(for: job)
                metadataBlock(for: job)
                if let estimate = job.estimate {
                    PrintEstimationCard(estimate: estimate)
                }
                actions(for: job)
            }
            .padding(16)
        }
        .alert("Delete this slice job?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSliceJob(jobId: job.jobId)
                    dismiss()
                }
            }
        } message: {
            Text("\(job.filename) and its sliced 3MF will be permanently removed. This can't be undone.")
        }
    }

    @ViewBuilder
    private func hero(for job: SliceJob) -> some View {
        if job.hasThumbnail, let url = SliceJobThumbnail.url(for: job.jobId) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                default:
                    heroPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(uiColor: .systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            heroPlaceholder
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var heroPlaceholder: some View {
        Image(systemName: "doc.fill")
            .font(.system(size: 48))
            .foregroundStyle(.tertiary)
    }

    private func titleBlock(for job: SliceJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.filename)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(2)
                .truncationMode(.middle)

            let style = SliceJobBadgeStyle.style(for: job.displayStatus)
            Text(SliceJobBadgeStyle.label(for: job))
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(style.background)
                .foregroundStyle(style.foreground)
                .clipShape(Capsule())
                .strikethrough(job.displayStatus == .cancelled)
        }
    }

    private func metadataBlock(for job: SliceJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(job.printerId?.isEmpty == false ? job.printerId! : "—",
                  systemImage: "printer.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(SliceJobRelativeTime.format(job.createdAt),
                  systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if job.displayStatus.isInFlight,
               let phase = job.phase, !phase.isEmpty {
                Label(phase, systemImage: "scissors")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let error = job.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private func actions(for job: SliceJob) -> some View {
        let mutationInFlight = viewModel.sliceJobMutationsInFlight.contains(job.jobId)
        let canPrint = job.displayStatus == .ready && (job.outputSize ?? 0) > 0
        let canCancel = !job.isTerminal

        VStack(spacing: 8) {
            if canPrint {
                Button {
                    Task { await viewModel.printSliceJob(jobId: job.jobId) }
                } label: {
                    actionLabel(title: "Print",
                                systemImage: "printer.fill",
                                inFlight: mutationInFlight,
                                tintOnLight: true)
                }
                .disabled(mutationInFlight || viewModel.selectedPrinterId.isEmpty)
                .background(Color.accentBlue.opacity(viewModel.selectedPrinterId.isEmpty ? 0.4 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if canCancel {
                Button {
                    Task { await viewModel.cancelSliceJob(jobId: job.jobId) }
                } label: {
                    actionLabel(title: "Cancel slice",
                                systemImage: "xmark",
                                inFlight: mutationInFlight)
                }
                .disabled(mutationInFlight)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                showDeleteConfirm = true
            } label: {
                actionLabel(title: "Delete",
                            systemImage: "trash",
                            inFlight: false)
            }
            .disabled(mutationInFlight)
            .background(Color.red.opacity(0.15))
            .foregroundStyle(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func actionLabel(title: String,
                             systemImage: String,
                             inFlight: Bool,
                             tintOnLight: Bool = false) -> some View {
        HStack(spacing: 8) {
            if inFlight {
                ProgressView().tint(tintOnLight ? .white : Color.accentBlue)
            } else {
                Image(systemName: systemImage)
            }
            Text(title).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - Job missing

    private var missingJob: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("This slice job is no longer available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
```

Notes for the implementer:
- `PrintEstimationCard` is in `BambuGateway/Views/PrintEstimationCard.swift`. Confirm its initializer is `PrintEstimationCard(estimate: PrintEstimate)`; if it takes additional parameters (e.g. an optional title), pass nil/defaults for them.
- If Task 5 Step 2 routed thumbnail URL resolution through `viewModel.sliceJobThumbnailURL(for:)` instead of `SliceJobThumbnail.url(for:)`, mirror that change in this file's `hero(for:)`.

- [ ] **Step 2: Build to verify**

Run:
```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Views/SliceJobDetailSheet.swift
git commit -m "$(cat <<'EOF'
Add slice-job detail sheet with Print, Cancel, and Delete

- shows the thumbnail, filename, status, printer, and estimation summary
- Print is disabled until a dashboard printer is selected and is hidden when there is no sliced output yet
- Delete prompts a confirmation alert before removing the job and its sliced 3MF
EOF
)"
```

---

## Task 7: Wire `SliceJobsSection` and detail sheet into `PrintTab`

**Files:**
- Modify: `BambuGateway/Views/PrintTab.swift`

This task wires the new section into the existing no-file branch and presents the detail sheet from a `@State` jobId binding owned by the tab.

- [ ] **Step 1: Add the selected-job-id state**

In `BambuGateway/Views/PrintTab.swift`, in the `PrintTab` struct just below the existing `@State private var isShowingSettings = false` (line 8), add:

```swift
    @State private var selectedSliceJobId: String?
```

- [ ] **Step 2: Render the section in the no-file branch**

Find `private var fileArea: some View` (line 79). Replace the entire `fileArea` `@ViewBuilder` with:

```swift
    @ViewBuilder
    private var fileArea: some View {
        if viewModel.selectedFile == nil, !viewModel.isGatewayConfigured {
            gatewayEmptyStateCard
        } else if let file = viewModel.selectedFile {
            fileHeaderCard(file: file)
        } else {
            importTilesRow
            SliceJobsSection(
                viewModel: viewModel,
                selectedJobId: $selectedSliceJobId
            )
        }
    }
```

The `VStack(spacing: 12)` wrapping `fileArea` in `body` already provides the inter-section spacing.

- [ ] **Step 3: Present the detail sheet**

Find the existing `.sheet(isPresented: $viewModel.showPrintSuccessModal)` modifier (around line 67). Immediately **after** it, add:

```swift
        .sheet(item: Binding(
            get: { selectedSliceJobId.map { SliceJobIdentifier(id: $0) } },
            set: { selectedSliceJobId = $0?.id }
        )) { identifier in
            SliceJobDetailSheet(viewModel: viewModel, jobId: identifier.id)
        }
```

At the bottom of `PrintTab.swift`, before the trailing `extension UIColor` block (line 849), add:

```swift
private struct SliceJobIdentifier: Identifiable, Hashable {
    let id: String
}
```

- [ ] **Step 4: Build to verify**

Run:
```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Views/PrintTab.swift
git commit -m "$(cat <<'EOF'
Show slice-jobs list under the import tiles on Print tab

- only renders when no file is selected and the gateway is configured
- tapping a row opens the slice-job detail sheet from the tab
EOF
)"
```

---

## Task 8: Final verification

**Files:** none modified.

- [ ] **Step 1: Run all unit tests on iPhone 16 18.6**

Per `CLAUDE.md`: prefer iPhone 16 18.6 for unit tests. Reinstall the app before fixing tests if any fail.

```
xcodebuild test \
  -project BambuGateway.xcodeproj \
  -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'
```
Expected: all tests pass, including the new `SliceJobDecodingTests` and `SliceJobDisplayStatusTests` cases.

- [ ] **Step 2: Build for generic iOS to confirm no signing-only failures**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Smoke-test the feature on a different simulator (per CLAUDE.md)**

Boot iPhone 16 Pro 18.3 (or use the currently-booted simulator if it's not iPhone 16 18.6). Run the app, configure the gateway URL, and verify on the Print tab with no file selected:
- Slice jobs section appears below the Files / MakerWorld tiles.
- Empty state shows "No slice jobs yet." when the gateway returns no jobs.
- A submitted slice job appears in the list with progress and "Slicing N%" badge.
- A completed (`ready` or `printing` raw status) job shows the green "Ready" badge.
- Tapping a row opens the detail sheet with thumbnail, metadata, and Print / Delete actions.
- "Print" is disabled when no printer is selected on the Dashboard; selecting one enables it.
- "Delete" prompts a confirmation alert.
- "Clear failed" and "Clear completed" remove the corresponding rows.
- Selecting a 3MF file hides the section; clearing the file shows it again.

Document any deviations as TODOs in the commit message of a follow-up. Do not claim feature completion without running this smoke test in a simulator.

- [ ] **Step 4: Final status report**

Push? (User decides — do not push without an explicit ask.) Otherwise summarize what landed and link the commits.

---

## Self-Review

**Spec coverage:**
- Placement (no-file branch, hidden when gateway unconfigured) → Task 7 Step 2.
- Status mapping (printing → ready) → Task 2.
- Section UI (header, clear buttons, list, empty/loading states) → Task 5.
- Detail sheet (hero, metadata, estimation, Print/Cancel/Delete) → Task 6.
- Polling cadence (2s active / 30s idle) → Task 4 Step 2.
- Networking helpers (`listSliceJobs`, `deleteSliceJob`, `clearSliceJobs`, `sliceJobThumbnailURL`) → Task 3.
- Model extension (richer `SliceJob`, `SliceJobListResponse`) → Task 1.
- "Always print to dashboard's selected printer" → Task 4 Step 2 (`printSliceJob`) and Task 6 disabled-state handling.
- Out-of-scope items (downloads, GCodePreviewModal load, web mirror, push refresh) → not in any task.

**Type consistency:** `SliceJob`, `SliceJobListResponse`, `SliceJobDisplayStatus`, and the new `AppViewModel` methods (`runSliceJobsPolling`, `refreshSliceJobs`, `cancelSliceJob`, `deleteSliceJob`, `clearSliceJobs(failedOnly:)`, `printSliceJob`) are referenced consistently across Tasks 4-7. The `selectedJobId: Binding<String?>` interface between `SliceJobsSection` and `PrintTab` matches in both directions.

**Placeholder scan:** No "TBD"/"TODO"/"implement later" content. All conditional sections (e.g. Task 5 Step 2's fallback if `AppSettingsStore.shared` is wrong) include the alternative code inline.
