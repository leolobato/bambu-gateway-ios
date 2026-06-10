# GCodePreview v2 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app renders print previews with GCodePreview v2 (`Viewer` + Metal renderer) from `.preview.bin` fetched at `GET /api/slice-jobs/{job_id}/preview` — no more on-device G-code parsing or full-3MF downloads for previews.

**Architecture:** Swap the SPM dependency to the local v2 package, add one `GatewayClient` method, consolidate the three duplicated preview flows in `AppViewModel` into a single `presentPreview(jobId:)` helper that fetches bytes → `PreviewData` → `Viewer.load`, and rebind `GCodePreviewModal` to the viewer. The estimate moves from the 3MF download's `X-Print-Estimate` header to the job record (`fetchSliceJob`), which already carries it.

**Tech Stack:** SwiftUI (iOS 18), XcodeGen, GCodePreview v2 (`@Observable @MainActor Viewer`, `PreviewData`, pure-SwiftUI `GCodePreviewView(viewer:)`), XCTest (`BambuGatewayTests` on iPhone 16 / iOS 18.6 simulator).

**Spec:** `../GCodePreview/docs/superpowers/specs/2026-06-10-preview-bin-pipeline-rollout-design.md` (Stage 3).

**Note:** the app will not build between Tasks 1 and 4 (the v1 API disappears with the package swap). Tasks 1–4 land as separate commits in one uninterrupted sequence; the build gate is Task 4 Step 3.

---

### Task 0: Branch

- [ ] **Step 1:**

```bash
cd /Users/leolobato/Documents/Projetos/Personal/3d/bambu_workspace/bambu-gateway-ios
git checkout main
git checkout -b feat/gcode-preview-v2
```

---

### Task 1: Point the package at local v2

**Files:**
- Modify: `project.yml` (packages section, lines 15-18)

- [ ] **Step 1: Replace the GitHub pin with a local path**

```yaml
packages:
  GCodePreview:
    path: ../GCodePreview
  MobileVLCKit:
    url: https://github.com/MobileVLCKit-SPM/MobileVLCKit-SPM
    exactVersion: 3.7.3
```

(The `../GCodePreview` checkout must be on its `feat/refactor` branch — verify with `git -C ../GCodePreview branch --show-current`.)

- [ ] **Step 2: Regenerate the project**

```bash
xcodegen generate
```

Expected: succeeds; `Package.resolved` no longer pins GCodePreview 1.0.1 (FlatBuffers 24.12.23 appears as a transitive dependency).

- [ ] **Step 3: Commit**

```bash
git add project.yml Package.resolved
git commit -m "chore: use local GCodePreview v2 package during migration"
```

---

### Task 2: GatewayClient.fetchSliceJobPreview

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift` (next to `fetchSliceJobOutput`, ~line 327)

- [ ] **Step 1: Add the method, mirroring `fetchSliceJobOutput`'s request/guard pattern exactly**

```swift
/// Download the sliced job's `Metadata/preview.bin` (GCodePreview v2
/// FlatBuffers blob). 404 means the gateway/slicer doesn't embed
/// preview data yet.
func fetchSliceJobPreview(jobId: String) async throws -> Data {
    let (data, response) = try await request(
        path: "/api/slice-jobs/\(jobId)/preview",
        method: "GET",
        timeout: 60
    )
    guard response is HTTPURLResponse else {
        throw GatewayClientError.invalidResponse
    }
    return data
}
```

(If `request(path:method:timeout:)` does not already throw on non-2xx status codes — check how `fetchSliceJobOutput` surfaces server errors — add the same status handling that the surrounding methods use, no more.)

- [ ] **Step 2: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift
git commit -m "feat: fetch slice job preview.bin from gateway"
```

---

### Task 3: AppViewModel — one preview loader, three call sites

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift`

- [ ] **Step 1: Replace the scene state with viewer state**

At the state declarations (~lines 100–110), replace:

```swift
@Published var previewScene: SCNScene?
```

with:

```swift
@Published var previewData: PreviewData?
let previewViewer = Viewer()
```

(`Viewer` is `@Observable`; SwiftUI views read it directly, so it needs no `@Published`. `AppViewModel` is `@MainActor`, matching `Viewer`'s isolation.)

- [ ] **Step 2: Add the shared loader near `submitPreview`**

```swift
/// Fetch a ready job's preview blob + estimate, load it into the shared
/// viewer, and surface the preview modal.
private func presentPreview(jobId: String) async throws {
    let client = gatewayClient()
    let bytes = try await client.fetchSliceJobPreview(jobId: jobId)
    let preview = try await Task.detached { try PreviewData(data: bytes) }.value
    await previewViewer.load(preview)
    let job = try? await client.fetchSliceJob(jobId: jobId)
    previewData = preview
    previewEstimate = job?.estimate
    currentJobId = jobId
    isShowingPreview = true
}
```

- [ ] **Step 3: Rewrite `submitPreview` (lines ~456–501)**

```swift
func submitPreview() async {
    guard selectedFile != nil, parsedInfo != nil else {
        setMessage("Select a 3MF file first.", .error)
        return
    }

    isLoadingPreview = true
    defer { isLoadingPreview = false }

    do {
        guard let submission = buildSubmission() else { return }
        let jobId = try await runSliceJob(submission, kind: "preview")
        try await presentPreview(jobId: jobId)
        clearPendingSliceJob()
        setMessage("", .info)
    } catch let error as URLError where error.code == .cancelled {
        // user-initiated cancel — silent
    } catch {
        setMessage(error.localizedDescription, .error)
    }
}
```

(The `preferredPlateId` local and the `has_gcode` comment go away — the server slices the requested plate and the preview blob describes exactly that plate.)

- [ ] **Step 4: Rewrite the `"preview"` case of `consumeReadyJob` (lines ~829–852)**

```swift
case "preview":
    try await presentPreview(jobId: jobId)
    clearPendingSliceJob()
```

- [ ] **Step 5: Rewrite `previewSliceJob` (lines ~1348–1379)**

```swift
@discardableResult
func previewSliceJob(jobId: String) async -> Bool {
    guard !sliceJobMutationsInFlight.contains(jobId) else { return false }
    sliceJobMutationsInFlight.insert(jobId)
    defer { sliceJobMutationsInFlight.remove(jobId) }

    do {
        try await presentPreview(jobId: jobId)
        return true
    } catch {
        setMessage("Couldn't load preview: \(error.localizedDescription)", .error)
        return false
    }
}
```

(The `fallbackName` lookup is no longer needed.)

- [ ] **Step 6: Update `dismissPreview` (lines ~701–707)**

```swift
private func dismissPreview() {
    isShowingPreview = false
    previewData = nil
    previewViewer.clear()
    currentJobId = nil
    previewEstimate = nil
    clearPendingSliceJob()
}
```

- [ ] **Step 7: Sweep remaining `previewScene` references**

```bash
grep -rn "previewScene" BambuGateway BambuGatewayTests
```

Expected: only `GCodePreviewModal.swift` remains (fixed in Task 4). Fix any others by substituting `previewData`.

- [ ] **Step 8: Commit**

```bash
git add BambuGateway/App/AppViewModel.swift
git commit -m "feat: load print previews from preview.bin via Viewer"
```

---

### Task 4: GCodePreviewModal on the v2 view

**Files:**
- Modify: `BambuGateway/Views/GCodePreviewModal.swift`

- [ ] **Step 1: Rebind to the viewer**

Replace the `ZStack` content (lines ~18–26):

```swift
ZStack {
    Color(uiColor: .systemBackground)

    if viewModel.previewData != nil {
        GCodePreviewView(viewer: viewModel.previewViewer)
    } else {
        ProgressView("Preparing preview...")
    }
}
```

and the Print button's disabled condition (line ~51):

```swift
.disabled(viewModel.previewData == nil || viewModel.isSubmitting)
```

Everything else (estimate card, toolbar, titles) stays. v2's built-in control strip (layer slider, view modes, scrubber) renders inside `GCodePreviewView`; do not add `.gcodePreviewControlsHidden(_)`.

- [ ] **Step 2: Add `import GCodePreview` where the new types appear**

`AppViewModel.swift` already imports it (line 2); confirm `GCodePreviewModal.swift` still does (line 1).

- [ ] **Step 3: Build gate — the whole app must compile again**

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. Typical stragglers: leftover v1 symbols (`GCodeParser`, `PrintSceneBuilder`, `SCNScene` in preview contexts) — remove them; they have no v2 equivalent on-device.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/GCodePreviewModal.swift
git commit -m "feat: render preview modal with GCodePreview v2 viewer"
```

---

### Task 5: Remove the dead on-device parsing path

**Files:**
- Delete (conditional): `BambuGateway/ThreeMF/ThreeMFReader.swift`
- Modify (conditional): `BambuGateway/Networking/GatewayClient.swift`, `BambuGateway/Models/GatewayModels.swift`

- [ ] **Step 1: Check for remaining users of the local 3MF reader**

```bash
grep -rn "ThreeMFReader\|extractGCode" BambuGateway BambuGatewayTests ShareExtension LiveActivityExtension
```

If the only hits are the file itself: delete `BambuGateway/ThreeMF/ThreeMFReader.swift` (and the `ThreeMF/` folder if empty). If another flow uses it, leave it and note why in the commit message.

- [ ] **Step 2: Check `fetchSliceJobOutput` / `fetchPrintPreview` / `PreviewResult` usage**

```bash
grep -rn "fetchSliceJobOutput\|fetchPrintPreview\|PreviewResult" BambuGateway BambuGatewayTests
```

Remove whichever of these no longer have callers (`fetchSliceJobOutput` likely; `fetchPrintPreview` only if uncalled). Keep anything still referenced.

- [ ] **Step 3: Build again**

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add -A BambuGateway
git commit -m "chore: drop on-device gcode parsing path"
```

---

### Task 6: Fixture decoding test

**Files:**
- Create: `BambuGatewayTests/PreviewDataFixtureTests.swift`
- Create: `BambuGatewayTests/Resources/coaster.preview.bin` (copied from the workspace fixture)

- [ ] **Step 1: Copy the fixture**

```bash
mkdir -p BambuGatewayTests/Resources
cp ../coaster.preview.bin BambuGatewayTests/Resources/coaster.preview.bin
xcodegen generate
```

- [ ] **Step 2: Write the test**

```swift
import XCTest
import GCodePreview
@testable import BambuGateway

final class PreviewDataFixtureTests: XCTestCase {
    func test_decodeCoasterFixture_producesVertices() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "coaster.preview", withExtension: "bin"
        ))
        let preview = try PreviewData(contentsOf: url)
        XCTAssertEqual(preview.formatVersion, 1)
        XCTAssertGreaterThan(preview.vertexCount, 0)
        XCTAssertGreaterThan(preview.layerCount, 0)
    }
}
```

(If the bundle lookup misses because xcodegen folder-references name it differently, check `Bundle(for:)` resource listing in the failure message and adjust `forResource`/`withExtension` accordingly — the demo app in `../GCodePreview/Demo` plays the same name games; see its `loadFixture()` candidates.)

- [ ] **Step 3: Run the unit tests on the iPhone 16 / iOS 18.6 simulator** (per user convention: unit tests on iPhone 16 18.6)

```bash
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all tests pass, including `PreviewDataFixtureTests`.

- [ ] **Step 4: Commit**

```bash
git add BambuGatewayTests project.yml
git commit -m "test: decode preview.bin fixture through GCodePreview v2"
```

---

### Task 7: Manual verification (fixture-independent app smoke)

- [ ] **Step 1: Run the app on a booted simulator** (not the unit-test one; prefer iPhone 16 Pro / iOS 18.3 if booting fresh) and confirm the app launches and non-preview flows (printer list, settings) behave.

- [ ] **Step 2: End-to-end preview** — requires Stages 1+2 running locally (orcaslicer-headless with embed + gateway with the endpoint). Point the app's gateway URL at the local gateway, import a 3MF, tap Preview. Expected: the Metal preview renders with the control strip; estimate card populates; Print stays enabled. Until the server stages are up, the preview flow surfaces the gateway's 404 detail — expected and correct.

---

### Done criteria (Stage 3 of the rollout spec)

- App builds and unit tests pass with the local v2 package; fixture decodes.
- No `ThreeMFReader`/`GCodeParser`/`PrintSceneBuilder` in the preview path; preview downloads only `.preview.bin`.
- End-to-end render verified against the local stack (after Stages 1–2).
- Before merging: user pushes/tags GCodePreview `2.0.0`, then `project.yml` re-pins `url` + `exactVersion: 2.0.0` and `xcodegen generate` runs again (follow-up commit on this branch).
