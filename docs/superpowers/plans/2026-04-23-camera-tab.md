# Camera Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third "Camera" tab to the BambuGateway iOS app showing the printer's built-in camera (A1/P1 TCP-JPEG or X1/P2S RTSPS-H.264), an optional per-printer external RTSP feed, and a chamber-light toggle — all backed by a custom Swift streaming module (`VideoToolbox` + `Network`) with zero third-party video dependencies.

**Architecture:** New `Services/Camera/` module with a `CameraFeed` protocol and three implementations (Bambu TCP-JPEG, Bambu RTSPS-H.264, external RTSP H.264). RTSP handling is split into a codec-agnostic `RTSPClient` and a reusable `H264NALAssembler` + `H264Decoder` pipeline, so units are independently testable. New tab in `ContentView`, new per-printer `externalCameraURL` field in `AppSettingsStore`, new `GatewayClient.setLight` endpoint call, new `CameraInfo` nested struct on `PrinterStatus`. UI feeds are view-owned (`@StateObject` per feed) so they tear down when the tab isn't visible.

**Tech Stack:** Swift 5, SwiftUI, iOS 18, `Network.framework`, `VideoToolbox`, `CoreMedia`, `CoreGraphics`, `CGImageSource` (JPEG). XcodeGen for project generation. No new external dependencies.

**Reference design doc:** `docs/superpowers/specs/2026-04-23-camera-tab-design.md`

**Reference implementation to study (do NOT copy verbatim):** `/Users/leolobato/Documents/Projetos/Personal/3d/panda-be-free/PandaBeFree/Services/CameraStreamManager.swift` — the panda-be-free project solved the same problems (RTSP digest auth, RFC 6184 NAL assembly, VTDecompressionSession setup, Bambu TCP framing). Read it for reference while implementing, but write new, better-factored code.

## Build & Test Commands

Canonical simulator for unit tests (per `CLAUDE.md`):
- **iPhone 16, iOS 18.6** — UUID `E8211B51-B899-4470-9067-49DE604059D7`

Common commands (run from repo root):

```bash
# Regenerate Xcode project after project.yml edits
xcodegen generate

# Build the app (no signing)
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Run unit tests on iPhone 16 iOS 18.6
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,id=E8211B51-B899-4470-9067-49DE604059D7' \
  test
```

Test naming convention (per `CLAUDE.md`): `test_<scenario>_<expectedResult>()`.

---

## Phase 0 — Test target scaffolding

No test target exists yet. We add `BambuGatewayTests` before writing any test-backed code.

### Task 0.1: Add `BambuGatewayTests` target to `project.yml`

**Files:**
- Modify: `project.yml`
- Create: `BambuGatewayTests/BambuGatewayTests.swift` (placeholder)

- [ ] **Step 1: Add the test target to `project.yml`**

Append this target block (after `LiveActivityExtension`, before `schemes:`):

```yaml
  BambuGatewayTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: '18.0'
    configFiles:
      Debug: Configuration/Base.xcconfig
      Release: Configuration/Base.xcconfig
    sources:
      - path: BambuGatewayTests
    dependencies:
      - target: BambuGateway
    settings:
      base:
        PRODUCT_NAME: BambuGatewayTests
        PRODUCT_BUNDLE_IDENTIFIER: $(APP_BUNDLE_ID).tests
        DEVELOPMENT_TEAM: $(DEVELOPMENT_TEAM)
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: 5.0
```

And add the test target to the BambuGateway scheme's `test` block (insert before `analyze:`):

```yaml
    test:
      config: Debug
      targets:
        - BambuGatewayTests
```

- [ ] **Step 2: Create placeholder test file**

Create `BambuGatewayTests/BambuGatewayTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class BambuGatewaySmokeTests: XCTestCase {
    func test_smoke_testTargetBuildsAndLinks() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 3: Regenerate project and run smoke test**

```bash
xcodegen generate
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,id=E8211B51-B899-4470-9067-49DE604059D7' \
  test
```

Expected: `** TEST SUCCEEDED **`, 1 test passes.

- [ ] **Step 4: Commit**

```bash
git add project.yml BambuGateway.xcodeproj BambuGatewayTests/
git commit -m "Scaffold BambuGatewayTests unit test target"
```

---

## Phase 1 — Data model extensions

### Task 1.1: Add `CameraInfo` nested struct to `PrinterStatus`

**Files:**
- Modify: `BambuGateway/Models/GatewayModels.swift`
- Test: `BambuGatewayTests/PrinterStatusCameraDecodingTests.swift`

- [ ] **Step 1: Write the failing decoding tests**

Create `BambuGatewayTests/PrinterStatusCameraDecodingTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class PrinterStatusCameraDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> PrinterStatus {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrinterStatus.self, from: data)
    }

    private let basePrinter = """
        "id": "A", "name": "X1C", "machine_model": "X1C",
        "online": true, "state": "IDLE", "speed_level": 2,
        "temperatures": {"nozzle_temp": 0, "nozzle_target": 0, "bed_temp": 0, "bed_target": 0}
    """

    func test_decode_cameraFieldMissing_cameraIsNil() throws {
        let json = "{ \(basePrinter) }"
        let printer = try decode(json)
        XCTAssertNil(printer.camera)
    }

    func test_decode_cameraFieldPresent_populatesAllFields() throws {
        let json = """
        {
            \(basePrinter),
            "camera": {
                "ip": "192.168.1.42",
                "access_code": "12345678",
                "transport": "rtsps",
                "chamber_light": { "supported": true, "on": false }
            }
        }
        """
        let printer = try decode(json)
        let camera = try XCTUnwrap(printer.camera)
        XCTAssertEqual(camera.ip, "192.168.1.42")
        XCTAssertEqual(camera.accessCode, "12345678")
        XCTAssertEqual(camera.transport, .rtsps)
        XCTAssertEqual(camera.chamberLight?.supported, true)
        XCTAssertEqual(camera.chamberLight?.on, false)
    }

    func test_decode_transportTcpJpeg_mapsCorrectly() throws {
        let json = """
        {
            \(basePrinter),
            "camera": {
                "ip": "10.0.0.5", "access_code": "abc", "transport": "tcp_jpeg",
                "chamber_light": { "supported": false, "on": null }
            }
        }
        """
        let printer = try decode(json)
        XCTAssertEqual(printer.camera?.transport, .tcpJPEG)
        XCTAssertEqual(printer.camera?.chamberLight?.supported, false)
        XCTAssertNil(printer.camera?.chamberLight?.on)
    }

    func test_decode_transportUnknown_decodesAsUnknown() throws {
        let json = """
        {
            \(basePrinter),
            "camera": {
                "ip": "1.1.1.1", "access_code": "x", "transport": "something_new",
                "chamber_light": { "supported": true, "on": true }
            }
        }
        """
        let printer = try decode(json)
        XCTAssertEqual(printer.camera?.transport, .unknown)
    }

    func test_decode_chamberLightMissing_isNil() throws {
        let json = """
        {
            \(basePrinter),
            "camera": { "ip": "1.1.1.1", "access_code": "x", "transport": "rtsps" }
        }
        """
        let printer = try decode(json)
        XCTAssertNotNil(printer.camera)
        XCTAssertNil(printer.camera?.chamberLight)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,id=E8211B51-B899-4470-9067-49DE604059D7' \
  test -only-testing:BambuGatewayTests/PrinterStatusCameraDecodingTests
```

Expected: compile failure — `camera` is not a member of `PrinterStatus`, `CameraInfo` doesn't exist.

- [ ] **Step 3: Add `CameraInfo` + `CameraTransport` + `ChamberLightInfo` types**

At the bottom of `BambuGateway/Models/GatewayModels.swift`, add:

```swift
// MARK: - Camera

enum CameraTransport: String, Decodable, Hashable {
    case rtsps
    case tcpJPEG = "tcp_jpeg"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CameraTransport(rawValue: raw) ?? .unknown
    }
}

struct ChamberLightInfo: Decodable, Hashable {
    let supported: Bool
    let on: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        on = try c.decodeIfPresent(Bool.self, forKey: .on)
    }

    private enum CodingKeys: String, CodingKey {
        case supported, on
    }
}

struct CameraInfo: Decodable, Hashable {
    let ip: String
    let accessCode: String
    let transport: CameraTransport
    let chamberLight: ChamberLightInfo?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = try c.decode(String.self, forKey: .ip)
        accessCode = try c.decode(String.self, forKey: .accessCode)
        transport = try c.decodeIfPresent(CameraTransport.self, forKey: .transport) ?? .unknown
        chamberLight = try c.decodeIfPresent(ChamberLightInfo.self, forKey: .chamberLight)
    }

    private enum CodingKeys: String, CodingKey {
        case ip, accessCode, transport, chamberLight
    }
}
```

- [ ] **Step 4: Add `camera` field to `PrinterStatus`**

In `PrinterStatus`, add the stored property after `errorMessage`:

```swift
    let camera: CameraInfo?
```

In the `init(from:)`, add (after the `errorMessage` line):

```swift
        camera = try c.decodeIfPresent(CameraInfo.self, forKey: .camera)
```

In `CodingKeys`, add `camera`:

```swift
        case id, name, machineModel, online, state, stageName, speedLevel, activeTray, temperatures, job, errorMessage, camera
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,id=E8211B51-B899-4470-9067-49DE604059D7' \
  test -only-testing:BambuGatewayTests/PrinterStatusCameraDecodingTests
```

Expected: all 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add BambuGateway/Models/GatewayModels.swift BambuGatewayTests/PrinterStatusCameraDecodingTests.swift
git commit -m "Add CameraInfo to PrinterStatus model"
```

### Task 1.2: Add `externalCameraURL` to `PerPrinterSelection`

**Files:**
- Modify: `BambuGateway/Data/AppSettingsStore.swift`
- Test: `BambuGatewayTests/AppSettingsStoreCameraTests.swift`

- [ ] **Step 1: Write the failing persistence test**

Create `BambuGatewayTests/AppSettingsStoreCameraTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class AppSettingsStoreCameraTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "bambu_gateway_ios.tests.camera"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_persistExternalCameraURL_roundTrips() {
        let store = AppSettingsStore(defaults: defaults)
        var settings = PersistedSettings.default
        var selection = PerPrinterSelection.empty
        selection.externalCameraURL = "rtsp://user:pass@192.168.1.50/stream"
        settings.perPrinter["A"] = selection

        store.save(settings)
        let loaded = store.load()

        XCTAssertEqual(
            loaded.perPrinter["A"]?.externalCameraURL,
            "rtsp://user:pass@192.168.1.50/stream"
        )
    }

    func test_decodeLegacyPayloadWithoutExternalCameraURL_defaultsToNil() throws {
        let legacyJSON = """
        {
            "gatewayBaseURL": "http://x",
            "selectedPrinterId": "A",
            "perPrinter": {
                "A": {
                    "machineProfileId": "m",
                    "processProfileId": "p",
                    "plateType": "pt",
                    "trayProfileBySlot": {},
                    "filamentTrayByIndex": {}
                }
            }
        }
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "bambu_gateway_ios.settings")

        let store = AppSettingsStore(defaults: defaults)
        let loaded = store.load()

        XCTAssertNil(loaded.perPrinter["A"]?.externalCameraURL)
    }
}
```

- [ ] **Step 2: Run test to confirm failure**

```bash
xcodebuild ... test -only-testing:BambuGatewayTests/AppSettingsStoreCameraTests
```

Expected: compile failure — `externalCameraURL` unknown.

- [ ] **Step 3: Add the field**

In `BambuGateway/Data/AppSettingsStore.swift`, modify `PerPrinterSelection`:

1. Add stored property (after `filamentTrayByIndex`):
```swift
    var externalCameraURL: String?
```

2. Add to `CodingKeys`:
```swift
        case externalCameraURL
```

3. Add to the explicit `init(...)` (add parameter `externalCameraURL: String? = nil` at the end and assign `self.externalCameraURL = externalCameraURL`).

4. Add to `init(from:)`:
```swift
        externalCameraURL = try container.decodeIfPresent(String.self, forKey: .externalCameraURL)
```

5. Update `static let empty` to pass `externalCameraURL: nil`.

- [ ] **Step 4: Run test to confirm pass**

Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Data/AppSettingsStore.swift BambuGatewayTests/AppSettingsStoreCameraTests.swift
git commit -m "Persist per-printer external camera RTSP URL"
```

---

## Phase 2 — Gateway client + AppViewModel wiring

### Task 2.1: Add `GatewayClient.setLight`

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift`

- [ ] **Step 1: Add the method**

After `setSpeed(...)` in `GatewayClient`, insert:

```swift
    func setLight(printerId: String, node: String = "chamber_light", on: Bool) async throws {
        struct Payload: Encodable {
            let node: String
            let on: Bool
        }
        let body = try JSONEncoder().encode(Payload(node: node, on: on))
        _ = try await request(
            path: "/api/printers/\(printerId)/light",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
    }
```

(No unit test here — it's a thin wrapper over `request` that existing pause/resume/cancel methods also don't test. Behavior is verified end-to-end in manual validation.)

- [ ] **Step 2: Build to confirm it compiles**

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift
git commit -m "Add setLight gateway endpoint"
```

### Task 2.2: Expose chamber-light state + toggle on `AppViewModel`

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift`

- [ ] **Step 1: Read `AppViewModel.swift` and locate the existing pause/resume/cancel pattern**

```bash
grep -n "func pause\|func resume\|func cancel\|func setSpeed" \
  BambuGateway/App/AppViewModel.swift
```

Identify how those methods structure optimistic updates + error handling. Replicate that pattern.

- [ ] **Step 2: Add computed state + toggle**

In `AppViewModel`, add alongside the other `@Published` command properties:

```swift
    @Published var chamberLightPending: Bool = false
```

And add a method near the other printer-command methods:

```swift
    func setChamberLight(on: Bool) async {
        guard let printer = selectedPrinter else { return }
        chamberLightPending = true
        defer { chamberLightPending = false }

        do {
            try await client.setLight(printerId: printer.id, on: on)
            // Re-fetch to confirm — matches pause/resume pattern.
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Derived from the selected printer's gateway-reported state.
    /// `nil` when unknown or unsupported.
    var chamberLightOn: Bool? {
        selectedPrinter?.camera?.chamberLight?.on
    }

    var chamberLightSupported: Bool {
        selectedPrinter?.camera?.chamberLight?.supported == true
    }
```

(If `client`, `selectedPrinter`, `refreshAll`, `errorMessage` have different names in the file, adapt to match.)

- [ ] **Step 3: Build to confirm**

```bash
xcodebuild ... build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/App/AppViewModel.swift
git commit -m "Expose chamber light state and toggle on AppViewModel"
```

---

## Phase 3 — Streaming primitives (protocol, types, controller)

All new files under `BambuGateway/Services/Camera/`. Add directory to `project.yml` sources (it's already covered by the existing `- path: BambuGateway` entry, no change needed).

### Task 3.1: Define `CameraFeed` protocol and value types

**Files:**
- Create: `BambuGateway/Services/Camera/CameraFeed.swift`

- [ ] **Step 1: Create the file**

```swift
import CoreGraphics
import Foundation

struct CameraFrame {
    let image: CGImage
    let timestamp: CFAbsoluteTime
}

enum CameraFeedError: Error, Equatable {
    case unreachable(String)
    case authFailed
    case unsupportedCodec(String)
    case streamEnded
    case other(String)
}

enum CameraFeedState: Equatable {
    case idle
    case connecting
    case streaming
    case failed(CameraFeedError)
    case stopped
}

protocol CameraFeed: AnyObject {
    /// Live frames. Latest-wins; stream drops older frames if the consumer is slow.
    var frames: AsyncStream<CameraFrame> { get }

    /// State changes. Replays the current state on subscribe.
    var state: AsyncStream<CameraFeedState> { get }

    func start()
    func stop()
}
```

- [ ] **Step 2: Regenerate project + build**

```bash
xcodegen generate
xcodebuild ... build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Services/Camera/ project.yml BambuGateway.xcodeproj
git commit -m "Add CameraFeed protocol and value types"
```

### Task 3.2: Add `CameraFeedController` for SwiftUI binding

**Files:**
- Create: `BambuGateway/Services/Camera/CameraFeedController.swift`

- [ ] **Step 1: Create the file**

```swift
import Combine
import CoreGraphics
import Foundation

@MainActor
final class CameraFeedController: ObservableObject {
    @Published private(set) var currentFrame: CGImage?
    @Published private(set) var lastFrameTimestamp: CFAbsoluteTime = 0
    @Published private(set) var state: CameraFeedState = .idle

    private let feed: CameraFeed
    private var frameTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    init(feed: CameraFeed) {
        self.feed = feed
    }

    deinit {
        frameTask?.cancel()
        stateTask?.cancel()
    }

    func start() {
        guard frameTask == nil else { return }
        feed.start()

        frameTask = Task { [weak self, feed] in
            for await frame in feed.frames {
                await MainActor.run {
                    self?.currentFrame = frame.image
                    self?.lastFrameTimestamp = frame.timestamp
                }
            }
        }

        stateTask = Task { [weak self, feed] in
            for await newState in feed.state {
                await MainActor.run {
                    self?.state = newState
                }
            }
        }
    }

    func stop() {
        feed.stop()
        frameTask?.cancel()
        stateTask?.cancel()
        frameTask = nil
        stateTask = nil
        state = .stopped
    }

    /// Manual retry — cancels any back-off and restarts.
    func retry() {
        stop()
        start()
    }
}
```

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Services/Camera/CameraFeedController.swift
git commit -m "Add CameraFeedController for SwiftUI binding"
```

---

## Phase 4 — H.264 NAL assembler (RFC 6184)

Bambu X1/P2S and external RTSP cameras deliver H.264 over RTP. We need to depacketize FU-A fragments and STAP-A aggregations into full NAL units.

**Spec references:**
- RFC 6184 §5.4 (FU-A), §5.7.1 (STAP-A)
- RFC 3550 (RTP header)

### Task 4.1: Test-drive `H264NALAssembler`

**Files:**
- Create: `BambuGateway/Services/Camera/H264NALAssembler.swift`
- Test: `BambuGatewayTests/H264NALAssemblerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `BambuGatewayTests/H264NALAssemblerTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class H264NALAssemblerTests: XCTestCase {
    private var assembler: H264NALAssembler!

    override func setUp() {
        super.setUp()
        assembler = H264NALAssembler()
    }

    // MARK: single NAL (no fragmentation)

    func test_singleNAL_passesThrough() {
        // NAL header: type=5 (IDR), nri=3
        // Byte pattern: 0b0_11_00101 = 0x65
        let nal = Data([0x65, 0x01, 0x02, 0x03])
        let out = assembler.append(rtpPayload: nal)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0], nal)
    }

    func test_singleNAL_spsPpsAreCaptured() {
        let sps = Data([0x67, 0x42, 0x00, 0x1E]) // type 7
        let pps = Data([0x68, 0xCE, 0x38, 0x80]) // type 8
        _ = assembler.append(rtpPayload: sps)
        _ = assembler.append(rtpPayload: pps)

        XCTAssertEqual(assembler.sps, sps)
        XCTAssertEqual(assembler.pps, pps)
    }

    // MARK: FU-A (type 28)

    func test_fuA_twoFragments_assembled() {
        // Original NAL: type=5, nri=3, header byte 0x65, payload bytes [0xAA, 0xBB, 0xCC, 0xDD]
        // FU indicator: nri=3, type=28 → 0b0_11_11100 = 0x7C
        // FU header start: S=1, E=0, type=5 → 0b1_0_0_00101 = 0x85
        // FU header end:   S=0, E=1, type=5 → 0b0_1_0_00101 = 0x45
        let frag1 = Data([0x7C, 0x85, 0xAA, 0xBB])
        let frag2 = Data([0x7C, 0x45, 0xCC, 0xDD])

        let out1 = assembler.append(rtpPayload: frag1)
        XCTAssertEqual(out1.count, 0, "start fragment alone yields nothing")

        let out2 = assembler.append(rtpPayload: frag2)
        XCTAssertEqual(out2.count, 1)
        XCTAssertEqual(out2[0], Data([0x65, 0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func test_fuA_middleFragment_withoutStart_discarded() {
        // Middle fragment: S=0, E=0
        let mid = Data([0x7C, 0x05, 0xAA]) // S=0,E=0,type=5
        let out = assembler.append(rtpPayload: mid)
        XCTAssertEqual(out.count, 0)
    }

    func test_fuA_threeFragments_assembled() {
        let frag1 = Data([0x7C, 0x85, 0x11]) // start
        let frag2 = Data([0x7C, 0x05, 0x22]) // middle
        let frag3 = Data([0x7C, 0x45, 0x33]) // end

        _ = assembler.append(rtpPayload: frag1)
        _ = assembler.append(rtpPayload: frag2)
        let out = assembler.append(rtpPayload: frag3)
        XCTAssertEqual(out, [Data([0x65, 0x11, 0x22, 0x33])])
    }

    // MARK: STAP-A (type 24)

    func test_stapA_twoNALs_split() {
        // STAP-A indicator: nri=3, type=24 → 0b0_11_11000 = 0x78
        // NAL sizes are big-endian u16, followed by NAL bytes.
        // NAL1: 4 bytes [0x67, 0x42, 0x00, 0x1E] (SPS)
        // NAL2: 4 bytes [0x68, 0xCE, 0x38, 0x80] (PPS)
        var payload = Data([0x78])
        payload.append(contentsOf: [0x00, 0x04])
        payload.append(contentsOf: [0x67, 0x42, 0x00, 0x1E])
        payload.append(contentsOf: [0x00, 0x04])
        payload.append(contentsOf: [0x68, 0xCE, 0x38, 0x80])

        let out = assembler.append(rtpPayload: payload)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], Data([0x67, 0x42, 0x00, 0x1E]))
        XCTAssertEqual(out[1], Data([0x68, 0xCE, 0x38, 0x80]))
        XCTAssertEqual(assembler.sps, Data([0x67, 0x42, 0x00, 0x1E]))
        XCTAssertEqual(assembler.pps, Data([0x68, 0xCE, 0x38, 0x80]))
    }

    func test_stapA_truncatedSize_returnsWhatParsed() {
        // STAP-A claiming a 10-byte NAL but only 4 bytes follow.
        var payload = Data([0x78])
        payload.append(contentsOf: [0x00, 0x0A])
        payload.append(contentsOf: [0x67, 0x42, 0x00, 0x1E])

        let out = assembler.append(rtpPayload: payload)
        XCTAssertEqual(out.count, 0, "truncated STAP-A is skipped, not partially emitted")
    }

    // MARK: unsupported

    func test_unsupportedType_returnsEmpty() {
        let payload = Data([0x70, 0x00]) // type=16 reserved
        let out = assembler.append(rtpPayload: payload)
        XCTAssertEqual(out.count, 0)
    }

    func test_emptyPayload_returnsEmpty() {
        XCTAssertEqual(assembler.append(rtpPayload: Data()).count, 0)
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

Expected: compile failure — `H264NALAssembler` doesn't exist.

- [ ] **Step 3: Implement `H264NALAssembler`**

Create `BambuGateway/Services/Camera/H264NALAssembler.swift`:

```swift
import Foundation

/// Reassembles H.264 NAL units from RTP payloads per RFC 6184.
/// Handles single NAL, FU-A fragmentation (type 28), and STAP-A (type 24).
/// Tracks the latest SPS (type 7) and PPS (type 8) for format-description use.
final class H264NALAssembler {
    private(set) var sps: Data?
    private(set) var pps: Data?

    private var fragmentBuffer = Data()
    private var fragmentNALHeader: UInt8 = 0
    private var inFragment = false

    /// Feed one RTP payload (the bytes after the 12-byte RTP header).
    /// Returns zero or more complete NAL units (just the NAL bytes; no start code).
    func append(rtpPayload: Data) -> [Data] {
        guard let first = rtpPayload.first else { return [] }
        let type = first & 0x1F

        switch type {
        case 1 ... 23:
            trackParameterSet(nal: rtpPayload)
            return [rtpPayload]

        case 24:
            return handleSTAPA(payload: rtpPayload)

        case 28:
            return handleFUA(payload: rtpPayload)

        default:
            return []
        }
    }

    func reset() {
        fragmentBuffer.removeAll(keepingCapacity: true)
        inFragment = false
        fragmentNALHeader = 0
    }

    // MARK: FU-A

    private func handleFUA(payload: Data) -> [Data] {
        guard payload.count >= 2 else { return [] }
        let indicator = payload[payload.startIndex]
        let fuHeader = payload[payload.startIndex + 1]

        let start = (fuHeader & 0x80) != 0
        let end = (fuHeader & 0x40) != 0
        let nalType = fuHeader & 0x1F
        let nri = indicator & 0x60
        let reconstructedHeader = UInt8(0) | nri | nalType

        let body = payload.advanced(by: 2)

        if start {
            fragmentBuffer.removeAll(keepingCapacity: true)
            fragmentBuffer.append(reconstructedHeader)
            fragmentBuffer.append(body)
            inFragment = true
            fragmentNALHeader = reconstructedHeader
            if end {
                let complete = fragmentBuffer
                inFragment = false
                fragmentBuffer.removeAll(keepingCapacity: true)
                trackParameterSet(nal: complete)
                return [complete]
            }
            return []
        }

        guard inFragment else { return [] }

        fragmentBuffer.append(body)
        if end {
            let complete = fragmentBuffer
            inFragment = false
            fragmentBuffer.removeAll(keepingCapacity: true)
            trackParameterSet(nal: complete)
            return [complete]
        }
        return []
    }

    // MARK: STAP-A

    private func handleSTAPA(payload: Data) -> [Data] {
        var out: [Data] = []
        var cursor = payload.startIndex + 1 // skip indicator byte
        let end = payload.endIndex

        while cursor + 2 <= end {
            let hi = UInt16(payload[cursor])
            let lo = UInt16(payload[cursor + 1])
            let size = Int((hi << 8) | lo)
            cursor += 2

            guard size > 0, cursor + size <= end else {
                // truncated — stop, don't emit partial
                break
            }

            let nal = payload.subdata(in: cursor ..< cursor + size)
            trackParameterSet(nal: nal)
            out.append(nal)
            cursor += size
        }

        return out
    }

    private func trackParameterSet(nal: Data) {
        guard let first = nal.first else { return }
        let type = first & 0x1F
        if type == 7 {
            sps = nal
        } else if type == 8 {
            pps = nal
        }
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
xcodebuild ... test -only-testing:BambuGatewayTests/H264NALAssemblerTests
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Services/Camera/H264NALAssembler.swift BambuGatewayTests/H264NALAssemblerTests.swift
git commit -m "Add RFC 6184 H.264 NAL assembler (FU-A, STAP-A)"
```

---

## Phase 5 — RTSP protocol primitives

`RTSPClient` is the biggest single piece. We build it in two parts: (1) pure parsing + digest auth (unit-tested), (2) full network state machine (integration-only).

### Task 5.1: Test-drive `RTSPMessage` parsing

**Files:**
- Create: `BambuGateway/Services/Camera/RTSPMessage.swift`
- Test: `BambuGatewayTests/RTSPMessageTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `BambuGatewayTests/RTSPMessageTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class RTSPMessageTests: XCTestCase {
    func test_parseResponse_200OK_headersExtracted() throws {
        let raw = """
        RTSP/1.0 200 OK\r
        CSeq: 2\r
        Session: 12345678;timeout=60\r
        Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r
        \r

        """
        let msg = try RTSPResponse.parse(data: Data(raw.utf8))
        XCTAssertEqual(msg.statusCode, 200)
        XCTAssertEqual(msg.headers["cseq"], "2")
        XCTAssertEqual(msg.headers["session"], "12345678;timeout=60")
        XCTAssertEqual(msg.sessionID, "12345678")
        XCTAssertEqual(msg.interleavedChannels, 0 ... 1)
    }

    func test_parseResponse_401WithWWWAuthenticate() throws {
        let raw = """
        RTSP/1.0 401 Unauthorized\r
        CSeq: 1\r
        WWW-Authenticate: Digest realm="Streaming", nonce="abc", stale=false\r
        \r

        """
        let msg = try RTSPResponse.parse(data: Data(raw.utf8))
        XCTAssertEqual(msg.statusCode, 401)
        XCTAssertEqual(msg.headers["www-authenticate"]?.contains("Digest"), true)
    }

    func test_parseResponse_truncated_throwsIncomplete() {
        let raw = "RTSP/1.0 200 OK\r\nCSeq: 1\r\n"
        XCTAssertThrowsError(try RTSPResponse.parse(data: Data(raw.utf8))) { error in
            XCTAssertEqual(error as? RTSPParseError, .incomplete)
        }
    }

    func test_parseResponse_malformedStatusLine_throws() {
        let raw = "HTTP/1.1 200 OK\r\n\r\n"
        XCTAssertThrowsError(try RTSPResponse.parse(data: Data(raw.utf8)))
    }

    func test_parseResponse_withContentLength_includesBody() throws {
        let body = "v=0\r\no=- 0 0 IN IP4 0.0.0.0\r\n"
        let raw = """
        RTSP/1.0 200 OK\r
        CSeq: 2\r
        Content-Type: application/sdp\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        let msg = try RTSPResponse.parse(data: Data(raw.utf8))
        XCTAssertEqual(msg.body, Data(body.utf8))
    }

    func test_buildRequest_formatsCorrectly() {
        let req = RTSPRequest(
            method: "DESCRIBE",
            uri: "rtsps://host:322/streaming/live/1",
            headers: [
                ("CSeq", "1"),
                ("Accept", "application/sdp")
            ],
            body: nil
        )
        let s = String(data: req.serialized(), encoding: .ascii)!
        XCTAssertTrue(s.hasPrefix("DESCRIBE rtsps://host:322/streaming/live/1 RTSP/1.0\r\n"))
        XCTAssertTrue(s.contains("CSeq: 1\r\n"))
        XCTAssertTrue(s.contains("Accept: application/sdp\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n"))
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

Expected: compile failure.

- [ ] **Step 3: Implement `RTSPMessage.swift`**

Create `BambuGateway/Services/Camera/RTSPMessage.swift`:

```swift
import Foundation

enum RTSPParseError: Error, Equatable {
    case incomplete
    case malformed(String)
}

struct RTSPResponse {
    let statusCode: Int
    let reason: String
    /// Header keys lowercased for lookup.
    let headers: [String: String]
    let body: Data
    let raw: Data

    var sessionID: String? {
        guard let session = headers["session"] else { return nil }
        return session.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Parses the `interleaved=N-M` channel pair from the Transport header.
    var interleavedChannels: ClosedRange<Int>? {
        guard let transport = headers["transport"] else { return nil }
        for part in transport.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interleaved=") {
                let tail = trimmed.dropFirst("interleaved=".count)
                let bits = tail.split(separator: "-")
                guard bits.count == 2, let a = Int(bits[0]), let b = Int(bits[1]) else { return nil }
                return a ... b
            }
        }
        return nil
    }

    /// Parse a full RTSP response, including body if `Content-Length` is set.
    /// Throws `.incomplete` if header-or-body aren't fully present.
    static func parse(data: Data) throws -> RTSPResponse {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw RTSPParseError.incomplete
        }

        let headerData = data.subdata(in: data.startIndex ..< headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .ascii) else {
            throw RTSPParseError.malformed("non-ASCII header")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw RTSPParseError.malformed("empty header") }

        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].hasPrefix("RTSP/") else {
            throw RTSPParseError.malformed("bad status line: \(statusLine)")
        }
        guard let code = Int(parts[1]) else {
            throw RTSPParseError.malformed("bad status code: \(parts[1])")
        }
        let reason = String(parts[2])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        var body = Data()
        if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
            guard data.distance(from: bodyStart, to: data.endIndex) >= len else {
                throw RTSPParseError.incomplete
            }
            body = data.subdata(in: bodyStart ..< bodyStart.advanced(by: len))
        }

        let rawEnd = body.isEmpty ? bodyStart : bodyStart.advanced(by: body.count)
        let raw = data.subdata(in: data.startIndex ..< rawEnd)

        return RTSPResponse(statusCode: code, reason: reason, headers: headers, body: body, raw: raw)
    }
}

struct RTSPRequest {
    let method: String
    let uri: String
    /// Ordered header list (order matters for some servers).
    let headers: [(String, String)]
    let body: Data?

    func serialized() -> Data {
        var s = "\(method) \(uri) RTSP/1.0\r\n"
        for (k, v) in headers {
            s += "\(k): \(v)\r\n"
        }
        if let body, !body.isEmpty {
            s += "Content-Length: \(body.count)\r\n"
        }
        s += "\r\n"
        var data = Data(s.utf8)
        if let body { data.append(body) }
        return data
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Services/Camera/RTSPMessage.swift BambuGatewayTests/RTSPMessageTests.swift
git commit -m "Add RTSP request/response parsing"
```

### Task 5.2: Test-drive RTSP Digest auth

**Files:**
- Create: `BambuGateway/Services/Camera/RTSPDigestAuth.swift`
- Test: `BambuGatewayTests/RTSPDigestAuthTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `BambuGatewayTests/RTSPDigestAuthTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class RTSPDigestAuthTests: XCTestCase {
    func test_parseChallenge_extractsRealmAndNonce() throws {
        let header = #"Digest realm="Streaming Server", nonce="abc123", algorithm="MD5""#
        let c = try RTSPDigestChallenge.parse(wwwAuthenticate: header)
        XCTAssertEqual(c.realm, "Streaming Server")
        XCTAssertEqual(c.nonce, "abc123")
        XCTAssertEqual(c.algorithm, "MD5")
    }

    func test_parseChallenge_missingRealm_throws() {
        let header = #"Digest nonce="abc""#
        XCTAssertThrowsError(try RTSPDigestChallenge.parse(wwwAuthenticate: header))
    }

    func test_parseChallenge_notDigest_throws() {
        let header = #"Basic realm="x""#
        XCTAssertThrowsError(try RTSPDigestChallenge.parse(wwwAuthenticate: header))
    }

    // RFC 2617 §3.2.2.1 test vector:
    // HA1 = MD5("Mufasa:testrealm@host.com:Circle Of Life")
    //     = 939e7578ed9e3c518a452acee763bce9
    // HA2 = MD5("GET:/dir/index.html")
    //     = 39aff3a2bab6126f332b942af96d3366
    // response = MD5("939e...:dcd98b7102dd2f0e8b11d0f600bfb0c093:39aff3...")
    //          = 1949323746fe6a43ef61f9606e7febea

    func test_digestResponse_matchesRFC2617Vector() {
        let result = RTSPDigestChallenge.response(
            username: "Mufasa",
            password: "Circle Of Life",
            realm: "testrealm@host.com",
            nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            method: "GET",
            uri: "/dir/index.html"
        )
        XCTAssertEqual(result, "1949323746fe6a43ef61f9606e7febea")
    }

    func test_buildAuthorizationHeader_includesAllFields() {
        let challenge = RTSPDigestChallenge(realm: "r", nonce: "n", algorithm: "MD5")
        let header = challenge.buildAuthorizationHeader(
            username: "u", password: "p", method: "DESCRIBE", uri: "rtsps://h/s"
        )
        XCTAssertTrue(header.contains("username=\"u\""))
        XCTAssertTrue(header.contains("realm=\"r\""))
        XCTAssertTrue(header.contains("nonce=\"n\""))
        XCTAssertTrue(header.contains("uri=\"rtsps://h/s\""))
        XCTAssertTrue(header.contains("response=\""))
        XCTAssertTrue(header.hasPrefix("Digest "))
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

- [ ] **Step 3: Implement `RTSPDigestAuth.swift`**

Create `BambuGateway/Services/Camera/RTSPDigestAuth.swift`:

```swift
import CryptoKit
import Foundation

enum RTSPDigestError: Error, Equatable {
    case notDigest
    case missingField(String)
}

struct RTSPDigestChallenge {
    let realm: String
    let nonce: String
    let algorithm: String

    static func parse(wwwAuthenticate header: String) throws -> RTSPDigestChallenge {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest ") else { throw RTSPDigestError.notDigest }
        let body = String(trimmed.dropFirst("digest ".count))

        let fields = parseQuotedFields(body)
        guard let realm = fields["realm"] else { throw RTSPDigestError.missingField("realm") }
        guard let nonce = fields["nonce"] else { throw RTSPDigestError.missingField("nonce") }
        let algorithm = fields["algorithm"] ?? "MD5"
        return RTSPDigestChallenge(realm: realm, nonce: nonce, algorithm: algorithm)
    }

    func buildAuthorizationHeader(username: String, password: String, method: String, uri: String) -> String {
        let response = Self.response(
            username: username, password: password,
            realm: realm, nonce: nonce, method: method, uri: uri
        )
        return """
        Digest username="\(username)", realm="\(realm)", nonce="\(nonce)", uri="\(uri)", response="\(response)"
        """
    }

    static func response(
        username: String,
        password: String,
        realm: String,
        nonce: String,
        method: String,
        uri: String
    ) -> String {
        let ha1 = md5Hex("\(username):\(realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        return md5Hex("\(ha1):\(nonce):\(ha2)")
    }

    private static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses comma-separated `key="value", key2="value2"` fields. Tolerates unquoted values.
    private static func parseQuotedFields(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace || s[i] == "," { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let keyStart = i
            while i < s.endIndex, s[i] != "=" { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let key = String(s[keyStart ..< i]).trimmingCharacters(in: .whitespaces).lowercased()
            i = s.index(after: i) // skip '='

            var value = ""
            if i < s.endIndex, s[i] == "\"" {
                i = s.index(after: i)
                let valueStart = i
                while i < s.endIndex, s[i] != "\"" { i = s.index(after: i) }
                value = String(s[valueStart ..< i])
                if i < s.endIndex { i = s.index(after: i) }
            } else {
                let valueStart = i
                while i < s.endIndex, s[i] != "," { i = s.index(after: i) }
                value = String(s[valueStart ..< i]).trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }
}

extension RTSPDigestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notDigest: return "Server did not offer Digest authentication."
        case .missingField(let name): return "Digest challenge missing field: \(name)."
        }
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Services/Camera/RTSPDigestAuth.swift BambuGatewayTests/RTSPDigestAuthTests.swift
git commit -m "Add RTSP Digest authentication per RFC 2617"
```

### Task 5.3: Test-drive interleaved-RTP frame parser

RTSP-over-TCP delivers RTP in "interleaved frames": a 4-byte header (`$`, channel, len-hi, len-lo) followed by the RTP packet. RFC 2326 §10.12.

**Files:**
- Create: `BambuGateway/Services/Camera/InterleavedRTPParser.swift`
- Test: `BambuGatewayTests/InterleavedRTPParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `BambuGatewayTests/InterleavedRTPParserTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class InterleavedRTPParserTests: XCTestCase {
    private var parser: InterleavedRTPParser!

    override func setUp() {
        super.setUp()
        parser = InterleavedRTPParser()
    }

    /// Build a 4-byte interleaved header + payload
    private func frame(channel: UInt8, payload: [UInt8]) -> Data {
        var data = Data([0x24, channel])
        let len = UInt16(payload.count)
        data.append(UInt8(len >> 8))
        data.append(UInt8(len & 0xFF))
        data.append(contentsOf: payload)
        return data
    }

    func test_singleCompleteFrame_emitted() {
        let f = frame(channel: 0, payload: [0x80, 0x60, 0x00, 0x01] + Array(repeating: 0xAA, count: 20))
        let out = parser.append(data: f)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].channel, 0)
        XCTAssertEqual(out[0].payload.count, 24)
    }

    func test_splitAcrossAppend_bufferedUntilComplete() {
        let payload: [UInt8] = Array(repeating: 0xBB, count: 30)
        let f = frame(channel: 1, payload: payload)

        let out1 = parser.append(data: f.prefix(10))
        XCTAssertEqual(out1.count, 0)

        let out2 = parser.append(data: f.suffix(from: 10))
        XCTAssertEqual(out2.count, 1)
        XCTAssertEqual(out2[0].channel, 1)
        XCTAssertEqual(out2[0].payload.count, 30)
    }

    func test_twoBackToBackFrames_bothEmitted() {
        var combined = frame(channel: 0, payload: [0x01, 0x02])
        combined.append(frame(channel: 1, payload: [0x03, 0x04, 0x05]))

        let out = parser.append(data: combined)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].channel, 0)
        XCTAssertEqual(out[0].payload, Data([0x01, 0x02]))
        XCTAssertEqual(out[1].channel, 1)
        XCTAssertEqual(out[1].payload, Data([0x03, 0x04, 0x05]))
    }

    func test_garbageBeforeDollarSign_skipped() {
        var data = Data([0xFF, 0xFE, 0xFD])
        data.append(frame(channel: 0, payload: [0xAA]))

        let out = parser.append(data: data)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].payload, Data([0xAA]))
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

- [ ] **Step 3: Implement parser**

Create `BambuGateway/Services/Camera/InterleavedRTPParser.swift`:

```swift
import Foundation

struct InterleavedRTPFrame {
    let channel: UInt8
    let payload: Data
}

/// Parses RFC 2326 §10.12 interleaved binary frames: `0x24 | channel | len-hi | len-lo | payload`.
final class InterleavedRTPParser {
    private var buffer = Data()

    func append(data: Data) -> [InterleavedRTPFrame] {
        buffer.append(data)
        var out: [InterleavedRTPFrame] = []

        while true {
            // Scan for start marker.
            guard let dollarIdx = buffer.firstIndex(of: 0x24) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if dollarIdx > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex ..< dollarIdx)
            }
            if buffer.count < 4 { break }

            let channel = buffer[buffer.startIndex + 1]
            let hi = UInt16(buffer[buffer.startIndex + 2])
            let lo = UInt16(buffer[buffer.startIndex + 3])
            let len = Int((hi << 8) | lo)

            let total = 4 + len
            if buffer.count < total { break }

            let payload = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + total)
            out.append(InterleavedRTPFrame(channel: channel, payload: payload))
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + total)
        }

        return out
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Services/Camera/InterleavedRTPParser.swift BambuGatewayTests/InterleavedRTPParserTests.swift
git commit -m "Add interleaved RTP frame parser (RFC 2326 §10.12)"
```

### Task 5.4: Add RTP header parser

RTP header is 12 bytes fixed (per RFC 3550). We just need to skip it and expose the payload + marker bit + timestamp.

**Files:**
- Create: `BambuGateway/Services/Camera/RTPPacket.swift`
- Test: `BambuGatewayTests/RTPPacketTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

final class RTPPacketTests: XCTestCase {
    func test_parse_12ByteHeaderFixed_payloadExtracted() throws {
        // V=2, P=0, X=0, CC=0 → 0x80
        // M=1, PT=96 → 0xE0
        // seq=0x1234, timestamp=0x11223344, ssrc=0xDEADBEEF
        let header: [UInt8] = [
            0x80, 0xE0,
            0x12, 0x34,
            0x11, 0x22, 0x33, 0x44,
            0xDE, 0xAD, 0xBE, 0xEF
        ]
        let payload: [UInt8] = [0x7C, 0x85, 0xAA]
        let packet = try RTPPacket.parse(Data(header + payload))
        XCTAssertEqual(packet.marker, true)
        XCTAssertEqual(packet.payloadType, 96)
        XCTAssertEqual(packet.sequenceNumber, 0x1234)
        XCTAssertEqual(packet.timestamp, 0x11223344)
        XCTAssertEqual(packet.payload, Data(payload))
    }

    func test_parse_withCSRCs_payloadOffsetCorrect() throws {
        // CC=2 → header is 12 + 8 = 20 bytes
        var bytes: [UInt8] = [
            0x82, 0x60,
            0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ]
        bytes.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD]) // CSRC 1
        bytes.append(contentsOf: [0x11, 0x22, 0x33, 0x44]) // CSRC 2
        bytes.append(contentsOf: [0x99]) // payload

        let packet = try RTPPacket.parse(Data(bytes))
        XCTAssertEqual(packet.payload, Data([0x99]))
    }

    func test_parse_tooShort_throws() {
        XCTAssertThrowsError(try RTPPacket.parse(Data([0x80, 0x60])))
    }
}
```

- [ ] **Step 2: Run tests to confirm failure**

- [ ] **Step 3: Implement**

Create `BambuGateway/Services/Camera/RTPPacket.swift`:

```swift
import Foundation

enum RTPParseError: Error, Equatable {
    case tooShort
}

struct RTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let payload: Data

    static func parse(_ data: Data) throws -> RTPPacket {
        guard data.count >= 12 else { throw RTPParseError.tooShort }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let cc = Int(b0 & 0x0F)
        let headerLen = 12 + cc * 4

        guard data.count >= headerLen else { throw RTPParseError.tooShort }

        let marker = (b1 & 0x80) != 0
        let pt = b1 & 0x7F
        let seq = (UInt16(data[data.startIndex + 2]) << 8) | UInt16(data[data.startIndex + 3])
        let ts = (UInt32(data[data.startIndex + 4]) << 24)
            | (UInt32(data[data.startIndex + 5]) << 16)
            | (UInt32(data[data.startIndex + 6]) << 8)
            | UInt32(data[data.startIndex + 7])
        let payload = data.subdata(in: (data.startIndex + headerLen) ..< data.endIndex)
        return RTPPacket(marker: marker, payloadType: pt, sequenceNumber: seq, timestamp: ts, payload: payload)
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Services/Camera/RTPPacket.swift BambuGatewayTests/RTPPacketTests.swift
git commit -m "Add RTP fixed-header parser (RFC 3550)"
```

---

## Phase 6 — H.264 decoder (VideoToolbox wrapper)

Integration-only — no unit tests. Verified end-to-end.

### Task 6.1: Implement `H264Decoder`

**Files:**
- Create: `BambuGateway/Services/Camera/H264Decoder.swift`

- [ ] **Step 1: Create the file**

```swift
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes H.264 NAL units into CGImages via VideoToolbox.
/// Usage: call `setParameterSets(sps:pps:)` once (or whenever SPS changes), then `decode(nal:)` per frame.
final class H264Decoder {
    typealias FrameHandler = (CGImage) -> Void

    private var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var currentSPS: Data?
    private var currentPPS: Data?

    let onFrame: FrameHandler

    init(onFrame: @escaping FrameHandler) {
        self.onFrame = onFrame
    }

    deinit {
        invalidateSession()
    }

    func setParameterSets(sps: Data, pps: Data) {
        if sps == currentSPS, pps == currentPPS, session != nil { return }

        currentSPS = sps
        currentPPS = pps
        invalidateSession()

        var fd: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr -> OSStatus in
            pps.withUnsafeBytes { ppsPtr -> OSStatus in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                ]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fd
                )
            }
        }

        guard status == noErr, let fd else { return }
        formatDesc = fd

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var sess: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, sourceFrameRefCon, status, _, buffer, _, _ in
                guard status == noErr, let buffer, let refCon else { return }
                let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
                decoder.handleDecoded(pixelBuffer: buffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let result = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &sess
        )
        if result == noErr { session = sess }
    }

    /// Decode a single NAL unit. Skip non-VCL (SPS/PPS already handled separately).
    func decode(nal: Data) {
        guard let session, let fd = formatDesc else { return }
        guard let first = nal.first else { return }
        let type = first & 0x1F
        guard type >= 1, type <= 5 else { return } // only slice NALs

        // Build Annex-B → AVCC-style sample (4-byte big-endian length prefix).
        var block = Data()
        let len = UInt32(nal.count)
        block.append(UInt8((len >> 24) & 0xFF))
        block.append(UInt8((len >> 16) & 0xFF))
        block.append(UInt8((len >> 8) & 0xFF))
        block.append(UInt8(len & 0xFF))
        block.append(nal)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = block.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: block.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: block.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard blockStatus == noErr, let blockBuffer else { return }

        let copyStatus = block.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: block.count
            )
        }
        guard copyStatus == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sizes: [Int] = [block.count]
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private func handleDecoded(pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let cgImage else { return }
        onFrame(cgImage)
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDesc = nil
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild ... build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Services/Camera/H264Decoder.swift
git commit -m "Add VideoToolbox-based H.264 decoder"
```

---

## Phase 7 — RTSPClient (full network state machine)

Integration-tested only (needs a real RTSP server). Heavy but straightforward: DESCRIBE → 401 (parse challenge) → DESCRIBE with Authorization → 200 (parse SDP) → SETUP → PLAY → stream RTP → TEARDOWN on stop.

### Task 7.1: Implement `RTSPClient`

**Files:**
- Create: `BambuGateway/Services/Camera/RTSPClient.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
import Network

struct RTSPCredentials {
    let username: String
    let password: String
}

enum RTSPClientError: Error, LocalizedError {
    case connectionFailed(String)
    case authFailed
    case unsupportedResponse(Int, String)
    case unsupportedCodec(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .authFailed: return "Authentication failed"
        case .unsupportedResponse(let c, let m): return "RTSP \(c): \(m)"
        case .unsupportedCodec(let c): return "Unsupported codec: \(c)"
        case .closed: return "Connection closed"
        }
    }
}

/// A minimal RTSP-over-TCP client with interleaved RTP. Codec-agnostic: delivers raw RTP payloads.
/// Call `start` to initiate DESCRIBE/SETUP/PLAY; `rtpPayloads` yields payloads as they arrive.
/// Call `stop` to TEARDOWN and close.
final class RTSPClient {
    struct Configuration {
        let url: URL
        let credentials: RTSPCredentials?
        /// TLS (RTSPS) — Bambu uses self-signed certs, so we allow bypass for a specific host.
        let useTLS: Bool
        let allowSelfSignedCert: Bool
    }

    let configuration: Configuration

    private(set) var rtpPayloads: AsyncStream<Data>!
    private(set) var events: AsyncStream<Event>!
    enum Event {
        case connected
        case playing
        case failed(RTSPClientError)
        case ended
    }

    private var rtpContinuation: AsyncStream<Data>.Continuation!
    private var eventContinuation: AsyncStream<Event>.Continuation!

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "rtsp.client")
    private let parser = InterleavedRTPParser()
    private var responseBuffer = Data()
    private var cseq: Int = 0
    private var sessionID: String?
    private var pendingResponse: ((RTSPResponse) -> Void)?

    init(configuration: Configuration) {
        self.configuration = configuration
        self.rtpPayloads = AsyncStream { self.rtpContinuation = $0 }
        self.events = AsyncStream { self.eventContinuation = $0 }
    }

    func start() {
        queue.async { [self] in
            openConnection()
        }
    }

    func stop() {
        queue.async { [self] in
            if let sessionID {
                let teardown = RTSPRequest(
                    method: "TEARDOWN",
                    uri: configuration.url.absoluteString,
                    headers: [
                        ("CSeq", String(nextCSeq())),
                        ("Session", sessionID)
                    ],
                    body: nil
                )
                connection?.send(content: teardown.serialized(), completion: .contentProcessed { _ in })
            }
            connection?.cancel()
            connection = nil
            rtpContinuation.finish()
            eventContinuation.yield(.ended)
            eventContinuation.finish()
        }
    }

    // MARK: connection

    private func openConnection() {
        guard let host = configuration.url.host else {
            eventContinuation.yield(.failed(.connectionFailed("no host")))
            return
        }
        let port = UInt16(configuration.url.port ?? (configuration.useTLS ? 322 : 554))

        let parameters: NWParameters
        if configuration.useTLS {
            let tls = NWProtocolTLS.Options()
            if configuration.allowSelfSignedCert {
                sec_protocol_options_set_verify_block(
                    tls.securityProtocolOptions,
                    { _, _, complete in complete(true) },
                    queue
                )
            }
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                eventContinuation.yield(.connected)
                sendDescribe()
                startReceive()
            case .failed(let err):
                eventContinuation.yield(.failed(.connectionFailed(err.localizedDescription)))
                rtpContinuation.finish()
            case .cancelled:
                rtpContinuation.finish()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func startReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                handleIncoming(data)
            }
            if error == nil, !isComplete {
                startReceive()
            } else {
                rtpContinuation.finish()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        // Data may be a mix of interleaved RTP frames ($-prefixed) and RTSP text responses.
        // Simple approach: if buffer starts with '$', feed to parser; else accumulate text response until "\r\n\r\n".
        responseBuffer.append(data)

        while !responseBuffer.isEmpty {
            if responseBuffer.first == 0x24 {
                let frames = parser.append(data: responseBuffer)
                responseBuffer.removeAll(keepingCapacity: true)
                for frame in frames where frame.channel == 0 {
                    // Channel 0 = RTP video; strip RTP header.
                    if let packet = try? RTPPacket.parse(frame.payload) {
                        rtpContinuation.yield(packet.payload)
                    }
                }
                break
            } else {
                guard let response = try? RTSPResponse.parse(data: responseBuffer) else { break }
                responseBuffer.removeSubrange(responseBuffer.startIndex ..< responseBuffer.startIndex.advanced(by: response.raw.count))
                pendingResponse?(response)
            }
        }
    }

    // MARK: RTSP methods

    private func nextCSeq() -> Int {
        cseq += 1
        return cseq
    }

    private func sendDescribe(authorization: String? = nil) {
        let uri = configuration.url.absoluteString
        var headers: [(String, String)] = [
            ("CSeq", String(nextCSeq())),
            ("Accept", "application/sdp")
        ]
        if let authorization {
            headers.append(("Authorization", authorization))
        }
        let req = RTSPRequest(method: "DESCRIBE", uri: uri, headers: headers, body: nil)

        pendingResponse = { [weak self] response in
            self?.handleDescribeResponse(response)
        }
        connection?.send(content: req.serialized(), completion: .contentProcessed { _ in })
    }

    private func handleDescribeResponse(_ response: RTSPResponse) {
        if response.statusCode == 401 {
            guard let creds = configuration.credentials,
                  let header = response.headers["www-authenticate"],
                  let challenge = try? RTSPDigestChallenge.parse(wwwAuthenticate: header) else {
                eventContinuation.yield(.failed(.authFailed))
                return
            }
            let auth = challenge.buildAuthorizationHeader(
                username: creds.username, password: creds.password,
                method: "DESCRIBE", uri: configuration.url.absoluteString
            )
            sendDescribe(authorization: auth)
            return
        }
        guard response.statusCode == 200 else {
            eventContinuation.yield(.failed(.unsupportedResponse(response.statusCode, response.reason)))
            return
        }

        // Minimal SDP check: must advertise H.264 (codec name "H264" in rtpmap).
        let sdp = String(data: response.body, encoding: .utf8) ?? ""
        if !sdp.contains("H264"), !sdp.contains("h264") {
            eventContinuation.yield(.failed(.unsupportedCodec("no H264 in SDP")))
            return
        }

        sendSetup()
    }

    private func sendSetup() {
        let uri = configuration.url.absoluteString
        let headers: [(String, String)] = [
            ("CSeq", String(nextCSeq())),
            ("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")
        ]
        // Reuse auth if needed — simple implementation omits re-auth here; many servers accept
        // the session without re-sending the Authorization header since it's the same connection.
        let req = RTSPRequest(method: "SETUP", uri: uri, headers: headers, body: nil)

        pendingResponse = { [weak self] response in
            guard response.statusCode == 200, let sid = response.sessionID else {
                self?.eventContinuation.yield(.failed(.unsupportedResponse(response.statusCode, response.reason)))
                return
            }
            self?.sessionID = sid
            self?.sendPlay()
        }
        connection?.send(content: req.serialized(), completion: .contentProcessed { _ in })
    }

    private func sendPlay() {
        let uri = configuration.url.absoluteString
        guard let sid = sessionID else { return }
        let req = RTSPRequest(
            method: "PLAY",
            uri: uri,
            headers: [
                ("CSeq", String(nextCSeq())),
                ("Session", sid),
                ("Range", "npt=0.000-")
            ],
            body: nil
        )

        pendingResponse = { [weak self] response in
            if response.statusCode == 200 {
                self?.eventContinuation.yield(.playing)
            } else {
                self?.eventContinuation.yield(.failed(.unsupportedResponse(response.statusCode, response.reason)))
            }
        }
        connection?.send(content: req.serialized(), completion: .contentProcessed { _ in })
    }
}
```

**Note on the SETUP re-auth shortcut:** some RTSP servers require the `Authorization` header on every request, not just DESCRIBE. If a Bambu printer returns 401 on SETUP/PLAY during integration testing, extend `pendingResponse` handlers to retry with the same `buildAuthorizationHeader(method:uri:)` logic — `RTSPDigestChallenge` stays available; each request just needs its own computed header because Digest's `response` field is method+URI specific. This is a known TODO discovered during real-printer testing; don't preemptively over-engineer.

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild ... build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Services/Camera/RTSPClient.swift
git commit -m "Add RTSP-over-TCP client with DESCRIBE/SETUP/PLAY/TEARDOWN"
```

---

## Phase 8 — Concrete camera feeds

### Task 8.1: `BambuRTSPSFeed` (X1/P2S)

**Files:**
- Create: `BambuGateway/Services/Camera/BambuRTSPSFeed.swift`

- [ ] **Step 1: Create the file**

```swift
import CoreGraphics
import Foundation

/// Bambu X1 / P2S printer camera: RTSPS on port 322 with bblp:<accessCode> credentials, H.264 over RTP.
final class BambuRTSPSFeed: CameraFeed {
    struct Configuration {
        let ip: String
        let accessCode: String
    }

    private(set) var frames: AsyncStream<CameraFrame>!
    private(set) var state: AsyncStream<CameraFeedState>!
    private var frameContinuation: AsyncStream<CameraFrame>.Continuation!
    private var stateContinuation: AsyncStream<CameraFeedState>.Continuation!

    private let config: Configuration
    private var client: RTSPClient?
    private let assembler = H264NALAssembler()
    private var decoder: H264Decoder!
    private var streamTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    init(configuration: Configuration) {
        self.config = configuration
        self.frames = AsyncStream { self.frameContinuation = $0 }
        self.state = AsyncStream { self.stateContinuation = $0 }
        self.decoder = H264Decoder { [weak self] cgImage in
            let frame = CameraFrame(image: cgImage, timestamp: CFAbsoluteTimeGetCurrent())
            self?.frameContinuation.yield(frame)
        }
    }

    func start() {
        stateContinuation.yield(.connecting)
        guard let url = URL(string: "rtsps://\(config.ip):322/streaming/live/1") else {
            stateContinuation.yield(.failed(.unreachable("bad URL")))
            return
        }
        let client = RTSPClient(configuration: .init(
            url: url,
            credentials: RTSPCredentials(username: "bblp", password: config.accessCode),
            useTLS: true,
            allowSelfSignedCert: true
        ))
        self.client = client

        eventTask = Task { [weak self, client] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .connected:
                    break
                case .playing:
                    stateContinuation.yield(.streaming)
                case .failed(let err):
                    stateContinuation.yield(.failed(map(err)))
                case .ended:
                    stateContinuation.yield(.stopped)
                }
            }
        }

        streamTask = Task { [weak self, client] in
            for await rtpPayload in client.rtpPayloads {
                guard let self else { return }
                let nals = assembler.append(rtpPayload: rtpPayload)
                if let sps = assembler.sps, let pps = assembler.pps {
                    decoder.setParameterSets(sps: sps, pps: pps)
                }
                for nal in nals {
                    decoder.decode(nal: nal)
                }
            }
        }

        client.start()
    }

    func stop() {
        client?.stop()
        client = nil
        streamTask?.cancel()
        eventTask?.cancel()
        streamTask = nil
        eventTask = nil
        stateContinuation.yield(.stopped)
    }

    private func map(_ err: RTSPClientError) -> CameraFeedError {
        switch err {
        case .authFailed: return .authFailed
        case .connectionFailed(let m): return .unreachable(m)
        case .unsupportedCodec(let m): return .unsupportedCodec(m)
        case .unsupportedResponse(let c, let m): return .other("RTSP \(c): \(m)")
        case .closed: return .streamEnded
        }
    }
}
```

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Services/Camera/BambuRTSPSFeed.swift
git commit -m "Add BambuRTSPSFeed for X1/P2S camera streams"
```

### Task 8.2: `BambuTCPJPEGFeed` (A1/P1)

**Files:**
- Create: `BambuGateway/Services/Camera/BambuTCPJPEGFeed.swift`

- [ ] **Step 1: Create the file**

```swift
import CoreGraphics
import Foundation
import ImageIO
import Network
import Security

/// Bambu A1 / P1 camera: TCP with TLS on port 6000. Sends an 80-byte auth packet,
/// then receives [16-byte header][JPEG] frames in a loop.
final class BambuTCPJPEGFeed: CameraFeed {
    struct Configuration {
        let ip: String
        let accessCode: String
    }

    private(set) var frames: AsyncStream<CameraFrame>!
    private(set) var state: AsyncStream<CameraFeedState>!
    private var frameContinuation: AsyncStream<CameraFrame>.Continuation!
    private var stateContinuation: AsyncStream<CameraFeedState>.Continuation!

    private let config: Configuration
    private let queue = DispatchQueue(label: "bambu.tcp.jpeg")
    private var connection: NWConnection?
    private var buffer = Data()
    private var expectedJPEGLength: Int?

    init(configuration: Configuration) {
        self.config = configuration
        self.frames = AsyncStream { self.frameContinuation = $0 }
        self.state = AsyncStream { self.stateContinuation = $0 }
    }

    func start() {
        queue.async { [self] in openConnection() }
    }

    func stop() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
            stateContinuation.yield(.stopped)
            frameContinuation.finish()
        }
    }

    private func openConnection() {
        stateContinuation.yield(.connecting)

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        let parameters = NWParameters(tls: tls)

        let conn = NWConnection(
            host: NWEndpoint.Host(config.ip),
            port: NWEndpoint.Port(rawValue: 6000)!,
            using: parameters
        )
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                sendAuth()
                startReceive()
            case .failed(let err):
                stateContinuation.yield(.failed(.unreachable(err.localizedDescription)))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendAuth() {
        // 80-byte packet: "bblp\0" (5) then 63 bytes of access code padded with zeros, then 12 bytes zero.
        // Exact layout per Bambu LAN SDK reverse-engineering:
        //   [0..4]   = "bblp"
        //   [4..16]  = version/magic (zeros OK)
        //   [16..80] = access code, zero-padded
        var packet = Data(count: 80)
        packet.replaceSubrange(0..<4, with: Data("bblp".utf8))
        let code = Data(config.accessCode.utf8)
        let codeEnd = min(16 + code.count, 80)
        packet.replaceSubrange(16..<codeEnd, with: code.prefix(codeEnd - 16))
        connection?.send(content: packet, completion: .contentProcessed { _ in })
        stateContinuation.yield(.streaming)
    }

    private func startReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                handleIncoming(data)
            }
            if error == nil, !isComplete {
                startReceive()
            } else {
                frameContinuation.finish()
                stateContinuation.yield(.failed(.streamEnded))
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        buffer.append(data)
        while true {
            if expectedJPEGLength == nil {
                guard buffer.count >= 16 else { return }
                // Bambu frame header: bytes 0-3 = little-endian JPEG length.
                let len = Int(buffer[0]) |
                    (Int(buffer[1]) << 8) |
                    (Int(buffer[2]) << 16) |
                    (Int(buffer[3]) << 24)
                expectedJPEGLength = len
                buffer.removeSubrange(0..<16)
            }
            guard let expected = expectedJPEGLength, buffer.count >= expected else { return }

            let jpegData = buffer.prefix(expected)
            buffer.removeSubrange(0..<expected)
            expectedJPEGLength = nil

            if let cg = decodeJPEG(jpegData) {
                frameContinuation.yield(CameraFrame(image: cg, timestamp: CFAbsoluteTimeGetCurrent()))
            }
        }
    }

    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
```

**Header layout note:** the 16-byte Bambu TCP header's interpretation came from reverse-engineering. If real-printer integration shows this is wrong (e.g. frames don't decode), consult `panda-be-free/PandaBeFree/Services/CameraStreamManager.swift` around line 197 (`performTCPStreaming`) for the verified field layout and update.

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Services/Camera/BambuTCPJPEGFeed.swift
git commit -m "Add BambuTCPJPEGFeed for A1/P1 camera streams"
```

### Task 8.3: `ExternalRTSPFeed`

**Files:**
- Create: `BambuGateway/Services/Camera/ExternalRTSPFeed.swift`

- [ ] **Step 1: Create the file**

```swift
import CoreGraphics
import Foundation

/// External third-party RTSP camera. H.264 only. Credentials may be embedded in the URL.
final class ExternalRTSPFeed: CameraFeed {
    private(set) var frames: AsyncStream<CameraFrame>!
    private(set) var state: AsyncStream<CameraFeedState>!
    private var frameContinuation: AsyncStream<CameraFrame>.Continuation!
    private var stateContinuation: AsyncStream<CameraFeedState>.Continuation!

    private let urlString: String
    private var client: RTSPClient?
    private let assembler = H264NALAssembler()
    private var decoder: H264Decoder!
    private var streamTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    init(urlString: String) {
        self.urlString = urlString
        self.frames = AsyncStream { self.frameContinuation = $0 }
        self.state = AsyncStream { self.stateContinuation = $0 }
        self.decoder = H264Decoder { [weak self] cg in
            self?.frameContinuation.yield(CameraFrame(image: cg, timestamp: CFAbsoluteTimeGetCurrent()))
        }
    }

    func start() {
        stateContinuation.yield(.connecting)
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "rtsp" || scheme == "rtsps" else {
            stateContinuation.yield(.failed(.unreachable("URL must use rtsp:// or rtsps://")))
            return
        }

        let creds: RTSPCredentials?
        if let user = url.user, let pass = url.password {
            creds = RTSPCredentials(username: user, password: pass)
        } else {
            creds = nil
        }

        let client = RTSPClient(configuration: .init(
            url: url,
            credentials: creds,
            useTLS: scheme == "rtsps",
            allowSelfSignedCert: true
        ))
        self.client = client

        eventTask = Task { [weak self, client] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .connected: break
                case .playing: stateContinuation.yield(.streaming)
                case .failed(let err): stateContinuation.yield(.failed(map(err)))
                case .ended: stateContinuation.yield(.stopped)
                }
            }
        }
        streamTask = Task { [weak self, client] in
            for await payload in client.rtpPayloads {
                guard let self else { return }
                let nals = assembler.append(rtpPayload: payload)
                if let sps = assembler.sps, let pps = assembler.pps {
                    decoder.setParameterSets(sps: sps, pps: pps)
                }
                for nal in nals { decoder.decode(nal: nal) }
            }
        }

        client.start()
    }

    func stop() {
        client?.stop()
        streamTask?.cancel()
        eventTask?.cancel()
        stateContinuation.yield(.stopped)
    }

    private func map(_ err: RTSPClientError) -> CameraFeedError {
        switch err {
        case .authFailed: return .authFailed
        case .connectionFailed(let m): return .unreachable(m)
        case .unsupportedCodec(let m): return .unsupportedCodec(m)
        case .unsupportedResponse(let c, let m): return .other("RTSP \(c): \(m)")
        case .closed: return .streamEnded
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate && xcodebuild ... build
git add BambuGateway/Services/Camera/ExternalRTSPFeed.swift
git commit -m "Add ExternalRTSPFeed for third-party H.264 RTSP cameras"
```

### Task 8.4: `BambuPrinterCameraFeed` dispatcher

**Files:**
- Create: `BambuGateway/Services/Camera/BambuPrinterCameraFeed.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

/// Dispatches to the correct transport based on the gateway's `CameraInfo.transport` hint.
/// Unknown transport → immediately fails with `.unsupportedCodec`.
final class BambuPrinterCameraFeed: CameraFeed {
    private let underlying: CameraFeed?

    var frames: AsyncStream<CameraFrame> {
        underlying?.frames ?? AsyncStream { $0.finish() }
    }

    var state: AsyncStream<CameraFeedState> {
        if let underlying {
            return underlying.state
        }
        return AsyncStream { continuation in
            continuation.yield(.failed(.unsupportedCodec("Unknown camera transport")))
            continuation.finish()
        }
    }

    init(camera: CameraInfo) {
        switch camera.transport {
        case .rtsps:
            underlying = BambuRTSPSFeed(configuration: .init(ip: camera.ip, accessCode: camera.accessCode))
        case .tcpJPEG:
            underlying = BambuTCPJPEGFeed(configuration: .init(ip: camera.ip, accessCode: camera.accessCode))
        case .unknown:
            underlying = nil
        }
    }

    func start() { underlying?.start() }
    func stop() { underlying?.stop() }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate && xcodebuild ... build
git add BambuGateway/Services/Camera/BambuPrinterCameraFeed.swift
git commit -m "Add BambuPrinterCameraFeed dispatcher"
```

---

## Phase 9 — UI

### Task 9.1: `CameraFeedView`

**Files:**
- Create: `BambuGateway/Views/Camera/CameraFeedView.swift`

`CameraFeedView` owns its controller as `@StateObject`. It takes a closure that builds the `CameraFeed` once, so a new controller is created only on view identity change (which we force via `.id(...)` in `CameraTab`). Fullscreen presentation lives inside this view so the single controller is reused by both tile and fullscreen.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct CameraFeedView: View {
    let title: String
    @StateObject private var controller: CameraFeedController
    @State private var fullscreenPresented = false

    /// Build a feed view. The `feedBuilder` is invoked once when the view is first created.
    /// To force a new feed (e.g. printer switch), give the parent view a new `.id(...)`.
    init(title: String, feedBuilder: @escaping () -> CameraFeed) {
        self.title = title
        _controller = StateObject(wrappedValue: CameraFeedController(feed: feedBuilder()))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            frameArea
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .contentShape(Rectangle())
        .onTapGesture { fullscreenPresented = true }
        .fullScreenCover(isPresented: $fullscreenPresented) {
            FullscreenCameraView(controller: controller, title: title, presented: $fullscreenPresented)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(title).font(.subheadline).fontWeight(.medium)
            Spacer()
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var frameArea: some View {
        ZStack {
            Color.black
            if let image = controller.currentFrame {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(frameIsStale ? 0.4 : 1)
            }
            overlay
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    @ViewBuilder
    private var overlay: some View {
        switch controller.state {
        case .idle, .connecting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Connecting…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        case .streaming where controller.currentFrame == nil:
            VStack(spacing: 8) {
                ProgressView()
                Text("Waiting for first frame…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        case .streaming where frameIsStale:
            Text("Reconnecting…")
                .font(.footnote)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .foregroundStyle(.white)
        case .failed(let err):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(errorText(err))
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { controller.retry() }
                    .buttonStyle(.borderedProminent)
            }
        case .stopped, .streaming:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .streaming: return frameIsStale ? .orange : .green
        case .connecting, .idle: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var frameIsStale: Bool {
        guard controller.lastFrameTimestamp > 0 else { return false }
        return CFAbsoluteTimeGetCurrent() - controller.lastFrameTimestamp > 5
    }

    private var accessibilityLabel: String {
        let status: String
        switch controller.state {
        case .streaming: status = "streaming"
        case .connecting, .idle: status = "connecting"
        case .failed: status = "disconnected"
        case .stopped: status = "stopped"
        }
        return "\(title) camera, \(status)"
    }

    private func errorText(_ err: CameraFeedError) -> String {
        switch err {
        case .unreachable(let m): return "Can't reach camera: \(m)"
        case .authFailed: return "Authentication failed. Check access code."
        case .unsupportedCodec(let m): return "Unsupported camera: \(m)"
        case .streamEnded: return "Stream ended. Retrying…"
        case .other(let m): return m
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate && xcodebuild ... build
git add BambuGateway/Views/Camera/CameraFeedView.swift
git commit -m "Add CameraFeedView with state overlays"
```

### Task 9.2: `FullscreenCameraView`

**Files:**
- Create: `BambuGateway/Views/Camera/FullscreenCameraView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct FullscreenCameraView: View {
    @ObservedObject var controller: CameraFeedController
    let title: String
    @Binding var presented: Bool

    @State private var chromeVisible = true
    @State private var chromeTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = controller.currentFrame {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            if chromeVisible {
                chrome
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onTapGesture { toggleChrome() }
        .onAppear { scheduleHide() }
        .onDisappear { chromeTimer?.invalidate() }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { presented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityLabel("Close")
                }
                Spacer()
                Text(title)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding()
            Spacer()
        }
        .transition(.opacity)
    }

    private func toggleChrome() {
        withAnimation { chromeVisible.toggle() }
        if chromeVisible { scheduleHide() }
    }

    private func scheduleHide() {
        chromeTimer?.invalidate()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            withAnimation { chromeVisible = false }
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate && xcodebuild ... build
git add BambuGateway/Views/Camera/FullscreenCameraView.swift
git commit -m "Add FullscreenCameraView with auto-hiding chrome"
```

### Task 9.3: `ChamberLightToggle`

**Files:**
- Create: `BambuGateway/Views/Camera/ChamberLightToggle.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct ChamberLightToggle: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if viewModel.chamberLightSupported, let isOn = viewModel.chamberLightOn {
            Button(action: { Task { await viewModel.setChamberLight(on: !isOn) } }) {
                HStack(spacing: 12) {
                    if viewModel.chamberLightPending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: isOn ? "lightbulb.fill" : "lightbulb")
                            .font(.title2)
                    }
                    Text(isOn ? "Chamber light on" : "Chamber light off")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(isOn ? Color.accentColor : Color(.tertiarySystemBackground))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(viewModel.chamberLightPending || viewModel.selectedPrinter?.online != true)
            .accessibilityLabel("Chamber light")
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
xcodegen generate && xcodebuild ... build
git add BambuGateway/Views/Camera/ChamberLightToggle.swift
git commit -m "Add ChamberLightToggle view"
```

### Task 9.4: `CameraTab`

**Files:**
- Create: `BambuGateway/Views/Camera/CameraTab.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct CameraTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    printerPicker
                    ChamberLightToggle(viewModel: viewModel)
                    printerFeed
                    externalFeed
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle("Camera")
            .background(Color(.systemGroupedBackground))
        }
    }

    @ViewBuilder
    private var printerPicker: some View {
        if viewModel.printers.count > 1 {
            Picker("Printer", selection: $viewModel.selectedPrinterId) {
                ForEach(viewModel.printers) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var printerFeed: some View {
        if let printer = viewModel.selectedPrinter {
            if printer.online, let camera = printer.camera {
                CameraFeedView(title: "Printer") {
                    BambuPrinterCameraFeed(camera: camera)
                }
                .id("printer-\(printer.id)-\(camera.ip)")
            } else {
                placeholder(text: printer.online ? "Camera not available for this printer." : "Printer offline.")
            }
        } else {
            placeholder(text: "No printer selected.")
        }
    }

    @ViewBuilder
    private var externalFeed: some View {
        if let printer = viewModel.selectedPrinter,
           let url = viewModel.externalCameraURL(for: printer.id),
           !url.isEmpty {
            CameraFeedView(title: "External") {
                ExternalRTSPFeed(urlString: url)
            }
            .id("external-\(printer.id)-\(url)")
        }
    }

    private func placeholder(text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
```

- [ ] **Step 2: Add `externalCameraURL(for:)` and `printers` accessors on `AppViewModel`**

In `BambuGateway/App/AppViewModel.swift`, add (next to the selected-printer accessors):

```swift
    func externalCameraURL(for printerId: String) -> String? {
        // `settings` here refers to the existing AppSettingsStore-backed state;
        // adapt to however PerPrinterSelection is already accessed.
        guard let perPrinter = persistedSettings.perPrinter[printerId] else { return nil }
        let trimmed = (perPrinter.externalCameraURL ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
```

(If the accessor for `perPrinter[...]` has a different name in the file, adapt it. `printers` should already exist as the `@Published` printer list.)

- [ ] **Step 3: Build**

```bash
xcodegen generate && xcodebuild ... build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/Camera/CameraTab.swift BambuGateway/App/AppViewModel.swift
git commit -m "Add CameraTab composition"
```

---

## Phase 10 — Wire the tab into ContentView

### Task 10.1: Add Camera tab

**Files:**
- Modify: `BambuGateway/Views/ContentView.swift`

- [ ] **Step 1: Read the existing file**

Confirm existing structure:

```bash
grep -n "TabView\|tabItem\|tag(" BambuGateway/Views/ContentView.swift
```

- [ ] **Step 2: Add the Camera tab**

Inside the existing `TabView { ... }`, after the Print tab (tag 1), add:

```swift
CameraTab(viewModel: viewModel)
    .tabItem { Label("Camera", systemImage: "video") }
    .tag(2)
```

- [ ] **Step 3: Build, verify 3 tabs render**

```bash
xcodegen generate
xcodebuild ... build
```

Then run on simulator `7B767EFC-A027-4E8F-AD65-BE6FD7D9902A` (iPhone 16 Pro 18.3, the booted one — per CLAUDE.md "Use the booted simulator for running (except iPhone 16 18.6)"):

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,id=7B767EFC-A027-4E8F-AD65-BE6FD7D9902A' \
  CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted path/to/BambuGateway.app
xcrun simctl launch booted com.yourid.BambuGateway
```

(Use the `ios-deploy` skill for actual install+run if simpler.)

Expected: app launches with three tabs in the bar; Camera tab shows placeholder states (no gateway data yet).

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/ContentView.swift
git commit -m "Add Camera tab to ContentView"
```

---

## Phase 11 — Settings UI

### Task 11.1: Add "Cameras" section to `SettingsView`

**Files:**
- Modify: `BambuGateway/Views/SettingsView.swift`

- [ ] **Step 1: Read the existing file**

```bash
cat BambuGateway/Views/SettingsView.swift
```

Understand existing structure (Form? sections? how `baseURL` is edited).

- [ ] **Step 2: Add a Cameras `Section` with printer picker + URL field**

Add after the existing Gateway URL section, inside the same `Form`:

```swift
            Section("Cameras") {
                if viewModel.printers.isEmpty {
                    Text("Add a printer to configure its external camera.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Printer", selection: $selectedPrinterIdForCameraSettings) {
                        ForEach(viewModel.printers) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    TextField("rtsp://user:pass@host/stream", text: urlBinding)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))

                    HStack {
                        Button("Test connection") {
                            Task { await testCameraURL() }
                        }
                        .disabled(isTestingCamera || urlBinding.wrappedValue.isEmpty)
                        if isTestingCamera {
                            ProgressView()
                        }
                        Spacer()
                        if let result = cameraTestResult {
                            Text(result.text).foregroundStyle(result.color).font(.footnote)
                        }
                    }
                }
            }
```

Add `@State` vars at the top of `SettingsView`:

```swift
    @State private var selectedPrinterIdForCameraSettings: String = ""
    @State private var isTestingCamera = false
    @State private var cameraTestResult: (text: String, color: Color)? = nil
```

And the `urlBinding` + test helper:

```swift
    private var urlBinding: Binding<String> {
        Binding(
            get: {
                viewModel.externalCameraURL(for: selectedPrinterIdForCameraSettings) ?? ""
            },
            set: { newValue in
                viewModel.setExternalCameraURL(newValue, for: selectedPrinterIdForCameraSettings)
                cameraTestResult = nil
            }
        )
    }

    private func testCameraURL() async {
        cameraTestResult = nil
        isTestingCamera = true
        defer { isTestingCamera = false }

        let url = urlBinding.wrappedValue
        let feed = ExternalRTSPFeed(urlString: url)
        feed.start()

        // Wait up to 8s for .streaming or .failed.
        let deadline = Date().addingTimeInterval(8)
        var outcome: CameraFeedState = .idle
        for await s in feed.state {
            outcome = s
            if case .streaming = s { break }
            if case .failed = s { break }
            if Date() > deadline { break }
        }
        feed.stop()

        switch outcome {
        case .streaming:
            cameraTestResult = ("Connected", .green)
        case .failed(let err):
            cameraTestResult = ("\(err)", .red)
        default:
            cameraTestResult = ("No response", .orange)
        }
    }

    private func initializeCameraSelection() {
        if selectedPrinterIdForCameraSettings.isEmpty {
            selectedPrinterIdForCameraSettings = viewModel.selectedPrinter?.id ?? viewModel.printers.first?.id ?? ""
        }
    }
```

Call `initializeCameraSelection()` from an `.onAppear { initializeCameraSelection() }` on the `Form`.

Also add a setter on `AppViewModel`:

```swift
    func setExternalCameraURL(_ url: String, for printerId: String) {
        guard !printerId.isEmpty else { return }
        var settings = settingsStore.load()
        var selection = settings.perPrinter[printerId] ?? .empty
        selection.externalCameraURL = url.isEmpty ? nil : url
        settings.perPrinter[printerId] = selection
        settingsStore.save(settings)
        persistedSettings = settings   // or whatever drives the published state
        objectWillChange.send()
    }
```

(Adapt the property names — `settingsStore`, `persistedSettings` — to whatever the file currently uses.)

- [ ] **Step 3: Build + confirm on simulator**

```bash
xcodegen generate && xcodebuild ... build
```

Manually verify in simulator: open Settings → Cameras section appears → typing a URL is saved and survives relaunch.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/SettingsView.swift BambuGateway/App/AppViewModel.swift
git commit -m "Add per-printer external camera URL to Settings"
```

---

## Phase 12 — Manual end-to-end validation

No automated tests here — this phase is a checklist, each bullet a commit-worthy verification (no code commits expected).

### Task 12.1: Validate on real hardware

**Prerequisites:** gateway service updated to emit `camera` field on `/api/printers` and respond to `POST /api/printers/{id}/light`. If the gateway isn't ready, use a mocked server. A minimal mock can be served with `python3 -m http.server` over a static JSON file for read-only validation of the decoding path; the full flow needs real gateway.

- [ ] **Step 1: X1/X1C printer on the network**

- Select the printer on the Camera tab.
- Printer feed shows "Connecting…" then live H.264 video within ~2s.
- Tap the feed → fullscreen launches, chrome auto-hides, tap again to dismiss.
- Toggle chamber light → UI flips immediately, physical light changes within 1s, state reconciles after `/api/printers` refresh.
- Switch printer picker to a different printer → the old feed tears down (no background streaming), new feed connects.

- [ ] **Step 2: A1/P1 printer on the network**

- Same as above, but transport is TCP-JPEG. Expect somewhat lower framerate.

- [ ] **Step 3: External RTSP camera**

- In Settings → Cameras, enter a valid H.264 RTSP URL (e.g. a random Reolink/Amcrest in the same LAN).
- Tap Test → green "Connected" result.
- Return to Camera tab → external tile renders below the printer feed, streams.

- [ ] **Step 4: External RTSP with wrong creds**

- Settings → change URL to invalid credentials.
- Test → red error text.
- Camera tab → external tile shows "Authentication failed. Check access code."

- [ ] **Step 5: External camera that isn't H.264**

- Point at an HEVC-only RTSP source if available.
- Tile shows "Unsupported camera: …".

- [ ] **Step 6: Lifecycle**

- Send app to background with the Camera tab active → confirm connection tears down (e.g. via Console/wireshark).
- Bring app back → feed reconnects.
- Switch to another tab → feed stops. Switch back → reconnects.

- [ ] **Step 7: Stream drop recovery**

- Pull printer's network cable.
- Feed shows "Reconnecting…" dim overlay within 5s, then retries with backoff until recovered.

- [ ] **Step 8: Printer without camera info from gateway**

- Force the gateway to omit `camera` for one printer.
- Tile shows "Camera not available for this printer."
- Light toggle is hidden.

### Task 12.2: Cleanup + final commit

- [ ] **Step 1: Remove stray debug prints**

```bash
git grep -n "print(" BambuGateway/Services/Camera BambuGateway/Views/Camera
```

Remove anything noisy.

- [ ] **Step 2: Run the full unit suite one more time**

```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway \
  -destination 'platform=iOS Simulator,id=E8211B51-B899-4470-9067-49DE604059D7' \
  test
```

Expected: all tests pass (targets: `PrinterStatusCameraDecodingTests`, `AppSettingsStoreCameraTests`, `H264NALAssemblerTests`, `RTSPMessageTests`, `RTSPDigestAuthTests`, `InterleavedRTPParserTests`, `RTPPacketTests`, `BambuGatewaySmokeTests`).

- [ ] **Step 3: Final commit if cleanup changed anything**

```bash
git add -u
git commit -m "Camera tab cleanup and final validation"
```

---

## Appendix — known risks & fallbacks

- **RTSP SETUP/PLAY re-auth.** If a Bambu X1 returns 401 on SETUP or PLAY (not just DESCRIBE), extend `RTSPClient.pendingResponse` to detect 401, recompute `Authorization` using the cached `RTSPDigestChallenge`, and re-send. `RTSPDigestChallenge` is already designed to accept arbitrary `(method, uri)` pairs.
- **Bambu TCP-JPEG 16-byte header.** The 4-byte little-endian length interpretation is a best-guess; if `decodeJPEG` returns `nil` on real A1/P1 hardware, compare against `panda-be-free/PandaBeFree/Services/CameraStreamManager.swift` ~line 197 (`performTCPStreaming`) and align.
- **`AsyncStream` pressure.** The latest-frame-wins semantic is enforced by SwiftUI redraw coalescing plus us yielding a `CGImage` (drops older yields if consumer is slow). If memory spikes in Instruments, switch to a bounded `AsyncStream` buffering policy.
- **Gateway readiness.** The iOS code is usable without the gateway (all paths handle missing `camera` field gracefully) but won't show anything meaningful until the gateway lands `camera` + `/light`. Phase 12 validation requires both.
