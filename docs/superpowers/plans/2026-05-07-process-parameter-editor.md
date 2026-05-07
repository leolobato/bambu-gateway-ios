# Process Parameter Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Modified card on the Print tab and a full-screen All-settings editor that lets users tweak OrcaSlicer process parameters before slicing a 3MF, with edits sent to the gateway via `process_overrides` on slice submit.

**Architecture:** Long-lived `ProcessOptionsStore` caches the option catalogue, paged layout, and resolved process profiles. `AppViewModel` owns the per-3MF override map (`processOverrides`) and baseline (`processBaseline`). Five new SwiftUI views (card, all-view, page detail, row, editor) all read effective values through a pure resolver function and write user edits straight back into `AppViewModel.processOverrides`.

**Tech Stack:** SwiftUI (iOS 18+), Swift 5, Foundation `URLSession`, XCTest, XcodeGen for project regeneration. No third-party dependencies introduced.

**Source spec:** `docs/superpowers/specs/2026-05-07-process-parameter-editor-design.md`
**Companion API doc:** `../orcaslicer-cli/docs/process-parameter-editor-api.md`
**Branch:** `feat/process-parameter-editor`

**Build & test commands**
- Regenerate project: `xcodegen generate`
- Build app (no signing): `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- Run unit tests: `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' test`
- Run app (different simulator from tests): use the booted simulator; if booting new, prefer iPhone 16 Pro 18.3.

**Conventions**
- 4-space indentation. `UpperCamelCase` types; `lowerCamelCase` properties.
- All decode-side models rely on `JSONDecoder().keyDecodingStrategy = .convertFromSnakeCase` (already configured globally in `GatewayClient.decode`). Do not add explicit `CodingKeys` for snake-case mappings; use camelCase property names directly.
- Test naming: `test_<scenario>_<expectedResult>()`.
- Commits: subject under 60 chars, body bullets, focus on visible behaviour. Do not skip pre-commit hooks.

---

## Task 1: Add URLProtocolStub test helper

**Files:**
- Create: `BambuGatewayTests/Support/URLProtocolStub.swift`

This helper lets unit tests intercept any `URLSession` request and return a canned response. Used by every networking test in this plan.

- [ ] **Step 1: Create the helper**

```swift
import Foundation

final class URLProtocolStub: URLProtocol {
    struct Response {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
        init(statusCode: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    /// Maps URL.path to a queue of canned responses. Each request consumes the head.
    static var responses: [String: [Response]] = [:]
    /// All URL.paths that the stub has been asked to serve, in order.
    static var requestedPaths: [String] = []
    /// Bodies attached to each request keyed by URL.path (last write wins).
    static var requestBodies: [String: Data] = [:]

    static func reset() {
        responses = [:]
        requestedPaths = []
        requestBodies = [:]
    }

    static func enqueue(path: String, response: Response) {
        responses[path, default: []].append(response)
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        URLProtocolStub.requestedPaths.append(path)

        // Capture body — URLSession strips httpBody when uploading from a file or
        // stream, so fall back to httpBodyStream when needed.
        if let body = request.httpBody {
            URLProtocolStub.requestBodies[path] = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            URLProtocolStub.requestBodies[path] = data
        }

        guard var queue = URLProtocolStub.responses[path], !queue.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = queue.removeFirst()
        URLProtocolStub.responses[path] = queue

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
```

- [ ] **Step 2: Wire the new file into the test target**

Run: `xcodegen generate`
Expected: project regenerates without warnings; `BambuGatewayTests` target now includes `Support/URLProtocolStub.swift`.

- [ ] **Step 3: Verify tests still build**

Run: `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build-for-testing`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add BambuGatewayTests/Support/URLProtocolStub.swift BambuGateway.xcodeproj
git commit -m "Add URLProtocolStub test helper

- Intercept URLSession requests and return canned responses for tests
- Capture request bodies (including streamed multipart uploads) for assertions"
```

---

## Task 2: Create ProcessParameter metadata types

**Files:**
- Create: `BambuGateway/Models/ProcessParameter.swift`
- Create: `BambuGatewayTests/ProcessParameterDecodingTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

final class ProcessParameterDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func test_decodeProcessOption_floatWithRange_succeeds() throws {
        let json = #"""
        {
          "key": "layer_height",
          "label": "Layer height",
          "category": "Quality",
          "tooltip": "Slicing height for every layer",
          "type": "coFloat",
          "sidetext": "mm",
          "default": "0.2",
          "min": 0.0,
          "max": null,
          "enum_values": null,
          "enum_labels": null,
          "mode": "simple",
          "gui_type": "",
          "nullable": false,
          "readonly": false
        }
        """#.data(using: .utf8)!

        let option = try decoder().decode(ProcessOption.self, from: json)

        XCTAssertEqual(option.key, "layer_height")
        XCTAssertEqual(option.label, "Layer height")
        XCTAssertEqual(option.type, .float)
        XCTAssertEqual(option.sidetext, "mm")
        XCTAssertEqual(option.default, "0.2")
        XCTAssertEqual(option.min, 0.0)
        XCTAssertNil(option.max)
        XCTAssertNil(option.enumValues)
        XCTAssertEqual(option.mode, "simple")
        XCTAssertFalse(option.readonly)
    }

    func test_decodeProcessOption_enum_succeeds() throws {
        let json = #"""
        {
          "key": "seam_position",
          "label": "Seam position",
          "category": "Quality",
          "tooltip": "...",
          "type": "coEnum",
          "sidetext": "",
          "default": "aligned",
          "min": null,
          "max": null,
          "enum_values": ["nearest", "aligned", "back", "random"],
          "enum_labels": ["Nearest", "Aligned", "Back", "Random"],
          "mode": "simple",
          "gui_type": "",
          "nullable": false,
          "readonly": false
        }
        """#.data(using: .utf8)!

        let option = try decoder().decode(ProcessOption.self, from: json)

        XCTAssertEqual(option.type, .enum)
        XCTAssertEqual(option.enumValues, ["nearest", "aligned", "back", "random"])
        XCTAssertEqual(option.enumLabels, ["Nearest", "Aligned", "Back", "Random"])
    }

    func test_decodeCatalogue_keyedByOptionKey_succeeds() throws {
        let json = #"""
        {
          "version": "2.3.2-41",
          "options": {
            "layer_height": {
              "key": "layer_height",
              "label": "Layer height",
              "category": "Quality",
              "tooltip": "",
              "type": "coFloat",
              "sidetext": "mm",
              "default": "0.2",
              "min": null,
              "max": null,
              "enum_values": null,
              "enum_labels": null,
              "mode": "simple",
              "gui_type": "",
              "nullable": false,
              "readonly": false
            }
          }
        }
        """#.data(using: .utf8)!

        let cat = try decoder().decode(ProcessOptionsCatalogue.self, from: json)

        XCTAssertEqual(cat.version, "2.3.2-41")
        XCTAssertEqual(cat.options["layer_height"]?.label, "Layer height")
    }

    func test_decodeLayout_pagesAndOptgroups_preserveOrder() throws {
        let json = #"""
        {
          "version": "2.3.2-41",
          "allowlist_revision": "2026-05-06.1",
          "pages": [
            {
              "label": "Quality",
              "optgroups": [
                {"label": "Layer height", "options": ["layer_height", "initial_layer_print_height"]}
              ]
            },
            {
              "label": "Strength",
              "optgroups": [
                {"label": "Walls", "options": ["wall_loops"]}
              ]
            }
          ]
        }
        """#.data(using: .utf8)!

        let layout = try decoder().decode(ProcessLayout.self, from: json)

        XCTAssertEqual(layout.allowlistRevision, "2026-05-06.1")
        XCTAssertEqual(layout.pages.map(\.label), ["Quality", "Strength"])
        XCTAssertEqual(layout.pages[0].optgroups[0].options, ["layer_height", "initial_layer_print_height"])
    }
}
```

- [ ] **Step 2: Run the tests, confirm they fail to compile**

Run: `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build-for-testing`
Expected: build fails with "cannot find type 'ProcessOption' in scope" etc.

- [ ] **Step 3: Implement the metadata types**

```swift
import Foundation

enum ProcessOptionType: String, Decodable {
    case bool = "coBool"
    case float = "coFloat"
    case floats = "coFloats"
    case int = "coInt"
    case ints = "coInts"
    case string = "coString"
    case strings = "coStrings"
    case percent = "coPercent"
    case percents = "coPercents"
    case floatOrPercent = "coFloatOrPercent"
    case floatsOrPercents = "coFloatsOrPercents"
    case point = "coPoint"
    case points = "coPoints"
    case point3 = "coPoint3"
    case bools = "coBools"
    case `enum` = "coEnum"
    case none = "coNone"
}

struct ProcessOption: Decodable, Hashable {
    let key: String
    let label: String
    let category: String
    let tooltip: String
    let type: ProcessOptionType
    let sidetext: String
    let `default`: String
    let min: Double?
    let max: Double?
    let enumValues: [String]?
    let enumLabels: [String]?
    let mode: String
    let guiType: String
    let nullable: Bool
    let readonly: Bool
}

struct ProcessOptionsCatalogue: Decodable {
    let version: String
    let options: [String: ProcessOption]
}

struct ProcessOptgroup: Decodable, Hashable {
    let label: String
    let options: [String]
}

struct ProcessPage: Decodable, Hashable {
    let label: String
    let optgroups: [ProcessOptgroup]
}

struct ProcessLayout: Decodable {
    let version: String
    let allowlistRevision: String
    let pages: [ProcessPage]
}
```

- [ ] **Step 4: Regenerate Xcode project**

Run: `xcodegen generate`

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' test -only-testing:BambuGatewayTests/ProcessParameterDecodingTests`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add BambuGateway/Models/ProcessParameter.swift BambuGatewayTests/ProcessParameterDecodingTests.swift BambuGateway.xcodeproj
git commit -m "Add process-parameter metadata models

- Define ProcessOption, ProcessOptionType, ProcessOptionsCatalogue
- Define ProcessLayout / ProcessPage / ProcessOptgroup with API order preserved
- Decode via global convertFromSnakeCase strategy"
```

---

## Task 3: Add ProcessModifications and ProcessOverrideApplied

**Files:**
- Modify: `BambuGateway/Models/ProcessParameter.swift`
- Modify: `BambuGatewayTests/ProcessParameterDecodingTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `ProcessParameterDecodingTests`:

```swift
    func test_decodeProcessModifications_full_succeeds() throws {
        let json = #"""
        {
          "process_setting_id": "Custom 0.20mm Standard",
          "modified_keys": ["layer_height", "wall_loops"],
          "values": {
            "layer_height": "0.16",
            "wall_loops": "3"
          }
        }
        """#.data(using: .utf8)!

        let mods = try decoder().decode(ProcessModifications.self, from: json)

        XCTAssertEqual(mods.processSettingId, "Custom 0.20mm Standard")
        XCTAssertEqual(mods.modifiedKeys, ["layer_height", "wall_loops"])
        XCTAssertEqual(mods.values["layer_height"], "0.16")
    }

    func test_decodeProcessModifications_emptyValues_succeeds() throws {
        let json = #"""
        {"process_setting_id": "", "modified_keys": [], "values": {}}
        """#.data(using: .utf8)!

        let mods = try decoder().decode(ProcessModifications.self, from: json)

        XCTAssertEqual(mods.processSettingId, "")
        XCTAssertTrue(mods.modifiedKeys.isEmpty)
        XCTAssertTrue(mods.values.isEmpty)
    }

    func test_decodeProcessOverrideApplied_succeeds() throws {
        let json = #"""
        [{"key": "layer_height", "value": "0.16", "previous": "0.20"}]
        """#.data(using: .utf8)!

        let applied = try decoder().decode([ProcessOverrideApplied].self, from: json)

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].key, "layer_height")
        XCTAssertEqual(applied[0].previous, "0.20")
    }
```

- [ ] **Step 2: Run, confirm fail**

Expected: build fails — types not defined.

- [ ] **Step 3: Implement the types**

Append to `BambuGateway/Models/ProcessParameter.swift`:

```swift
struct ProcessModifications: Decodable, Equatable {
    let processSettingId: String
    let modifiedKeys: [String]
    let values: [String: String]
}

struct ProcessOverrideApplied: Decodable, Hashable {
    let key: String
    let value: String
    let previous: String
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild ... test -only-testing:BambuGatewayTests/ProcessParameterDecodingTests`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Models/ProcessParameter.swift BambuGatewayTests/ProcessParameterDecodingTests.swift
git commit -m "Add ProcessModifications and ProcessOverrideApplied models

- Decode the project author's process customizations from inspect responses
- Decode the per-key overrides applied response from slice/print submissions"
```

---

## Task 4: Extend ThreeMFInfo with processModifications

**Files:**
- Modify: `BambuGateway/Models/GatewayModels.swift:183-191`
- Create: `BambuGatewayTests/ThreeMFInfoDecodingTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

final class ThreeMFInfoDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func test_decodeThreeMFInfo_withProcessModifications_succeeds() throws {
        let json = #"""
        {
          "plates": [],
          "filaments": [],
          "print_profile": {"print_settings_id": "P", "layer_height": "0.2"},
          "printer": {"printer_settings_id": "X", "printer_model": "A1", "nozzle_diameter": "0.4"},
          "has_gcode": false,
          "process_modifications": {
            "process_setting_id": "Custom 0.20mm Standard",
            "modified_keys": ["layer_height"],
            "values": {"layer_height": "0.16"}
          }
        }
        """#.data(using: .utf8)!

        let info = try decoder().decode(ThreeMFInfo.self, from: json)

        XCTAssertEqual(info.processModifications?.processSettingId, "Custom 0.20mm Standard")
        XCTAssertEqual(info.processModifications?.values["layer_height"], "0.16")
    }

    func test_decodeThreeMFInfo_olderGatewayWithoutProcessModifications_decodesNil() throws {
        let json = #"""
        {
          "plates": [],
          "filaments": [],
          "print_profile": {"print_settings_id": "P", "layer_height": "0.2"},
          "printer": {"printer_settings_id": "X", "printer_model": "A1", "nozzle_diameter": "0.4"},
          "has_gcode": false
        }
        """#.data(using: .utf8)!

        let info = try decoder().decode(ThreeMFInfo.self, from: json)

        XCTAssertNil(info.processModifications)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Expected: "value of type 'ThreeMFInfo' has no member 'processModifications'".

- [ ] **Step 3: Extend ThreeMFInfo**

In `BambuGateway/Models/GatewayModels.swift`, change the `ThreeMFInfo` definition (currently lines 183-191) to:

```swift
struct ThreeMFInfo: Decodable {
    let plates: [PlateInfo]
    var filaments: [ProjectFilament]
    let printProfile: PrintProfileInfo
    let printer: PrinterInfo
    let hasGcode: Bool
    /// Optional — older gateway responses (schema_version < 4) omit this field.
    let processModifications: ProcessModifications?
}
```

- [ ] **Step 4: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild ... test -only-testing:BambuGatewayTests/ThreeMFInfoDecodingTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Models/GatewayModels.swift BambuGatewayTests/ThreeMFInfoDecodingTests.swift BambuGateway.xcodeproj
git commit -m "Surface 3MF process customizations on inspect

- Add optional `processModifications` field to `ThreeMFInfo`
- Older gateway responses (no field) decode as nil"
```

---

## Task 5: Extend SettingsTransferInfo with processOverridesApplied

**Files:**
- Modify: `BambuGateway/Models/GatewayModels.swift:276-280`
- Create: `BambuGatewayTests/SettingsTransferInfoDecodingTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

final class SettingsTransferInfoDecodingTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func test_decode_withProcessOverridesApplied_succeeds() throws {
        let json = #"""
        {
          "status": "applied",
          "transferred": [],
          "filaments": [],
          "process_overrides_applied": [
            {"key": "layer_height", "value": "0.16", "previous": "0.20"}
          ]
        }
        """#.data(using: .utf8)!

        let info = try decoder().decode(SettingsTransferInfo.self, from: json)

        XCTAssertEqual(info.processOverridesApplied?.count, 1)
        XCTAssertEqual(info.processOverridesApplied?[0].key, "layer_height")
    }

    func test_decode_withoutProcessOverridesApplied_decodesNil() throws {
        let json = #"""
        {"status": "applied", "transferred": [], "filaments": []}
        """#.data(using: .utf8)!

        let info = try decoder().decode(SettingsTransferInfo.self, from: json)

        XCTAssertNil(info.processOverridesApplied)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Expected: "value of type 'SettingsTransferInfo' has no member 'processOverridesApplied'".

- [ ] **Step 3: Extend SettingsTransferInfo**

In `BambuGateway/Models/GatewayModels.swift`, change the `SettingsTransferInfo` definition (currently lines 276-280) to:

```swift
struct SettingsTransferInfo: Decodable {
    let status: String
    let transferred: [TransferredSetting]
    let filaments: [FilamentTransferEntry]
    /// Optional — older gateway responses omit this field.
    let processOverridesApplied: [ProcessOverrideApplied]?
}
```

- [ ] **Step 4: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild ... test -only-testing:BambuGatewayTests/SettingsTransferInfoDecodingTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Models/GatewayModels.swift BambuGatewayTests/SettingsTransferInfoDecodingTests.swift BambuGateway.xcodeproj
git commit -m "Decode applied process overrides from slice responses

- Add optional `processOverridesApplied` to `SettingsTransferInfo`
- Older gateway responses without the field decode as nil"
```

---

## Task 6: Add fetchProcessOptions endpoint

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift` (add new method near other `fetchSlicer*`)
- Create: `BambuGatewayTests/GatewayClientProcessTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import BambuGateway

final class GatewayClientProcessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    private func makeClient() -> GatewayClient {
        GatewayClient(baseURLString: "http://gateway.test", session: URLProtocolStub.makeSession())
    }

    func test_fetchProcessOptions_returnsCatalogue() async throws {
        let body = #"""
        {
          "version": "2.3.2-41",
          "options": {
            "layer_height": {
              "key": "layer_height", "label": "Layer height", "category": "Quality",
              "tooltip": "", "type": "coFloat", "sidetext": "mm", "default": "0.2",
              "min": null, "max": null, "enum_values": null, "enum_labels": null,
              "mode": "simple", "gui_type": "", "nullable": false, "readonly": false
            }
          }
        }
        """#.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process", response: .init(body: body))

        let cat = try await makeClient().fetchProcessOptions()

        XCTAssertEqual(cat.version, "2.3.2-41")
        XCTAssertEqual(cat.options["layer_height"]?.type, .float)
        XCTAssertEqual(URLProtocolStub.requestedPaths, ["/api/options/process"])
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Expected: "value of type 'GatewayClient' has no member 'fetchProcessOptions'".

- [ ] **Step 3: Add the method**

In `BambuGateway/Networking/GatewayClient.swift`, add immediately after `fetchSlicerPlateTypes()`:

```swift
    func fetchProcessOptions() async throws -> ProcessOptionsCatalogue {
        try await get(path: "/api/options/process")
    }
```

- [ ] **Step 4: Run the test**

Run: `xcodebuild ... test -only-testing:BambuGatewayTests/GatewayClientProcessTests/test_fetchProcessOptions_returnsCatalogue`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift BambuGatewayTests/GatewayClientProcessTests.swift
git commit -m "Fetch process option catalogue from gateway

- New `fetchProcessOptions()` returns the unfiltered metadata catalogue"
```

---

## Task 7: Add fetchProcessLayout endpoint

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift`
- Modify: `BambuGatewayTests/GatewayClientProcessTests.swift`

- [ ] **Step 1: Append the failing test**

```swift
    func test_fetchProcessLayout_returnsLayout() async throws {
        let body = #"""
        {
          "version": "2.3.2-41",
          "allowlist_revision": "2026-05-06.1",
          "pages": [
            {"label": "Quality", "optgroups": [
              {"label": "Layer height", "options": ["layer_height"]}
            ]}
          ]
        }
        """#.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process/layout", response: .init(body: body))

        let layout = try await makeClient().fetchProcessLayout()

        XCTAssertEqual(layout.allowlistRevision, "2026-05-06.1")
        XCTAssertEqual(layout.pages[0].optgroups[0].options, ["layer_height"])
    }
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Add the method**

In `GatewayClient.swift`, add immediately after `fetchProcessOptions()`:

```swift
    func fetchProcessLayout() async throws -> ProcessLayout {
        try await get(path: "/api/options/process/layout")
    }
```

- [ ] **Step 4: Run the test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift BambuGatewayTests/GatewayClientProcessTests.swift
git commit -m "Fetch paged process layout from gateway

- New `fetchProcessLayout()` returns allowlist-filtered editor layout"
```

---

## Task 8: Add fetchProcessProfile endpoint

**Files:**
- Modify: `BambuGateway/Models/GatewayModels.swift` (new struct `ResolvedProcessProfile`)
- Modify: `BambuGateway/Networking/GatewayClient.swift`
- Modify: `BambuGatewayTests/GatewayClientProcessTests.swift`

> **Endpoint path note:** The companion API doc states `GET /profiles/processes/{process_setting_id}` returns the resolved process profile values. This plan uses `/api/slicer/processes/\(settingId)` as the iOS-side path because the gateway already exposes `/api/slicer/processes` for the list. Verify with the gateway maintainer before merging — this is a one-line tweak inside `fetchProcessProfile` if the actual route differs.

- [ ] **Step 1: Append the failing test**

```swift
    func test_fetchProcessProfile_returnsValues() async throws {
        let body = #"""
        {
          "setting_id": "Custom 0.20mm Standard",
          "values": {"layer_height": "0.20", "wall_loops": "2"}
        }
        """#.data(using: .utf8)!
        URLProtocolStub.enqueue(
            path: "/api/slicer/processes/Custom%200.20mm%20Standard",
            response: .init(body: body)
        )

        let profile = try await makeClient().fetchProcessProfile(settingId: "Custom 0.20mm Standard")

        XCTAssertEqual(profile.settingId, "Custom 0.20mm Standard")
        XCTAssertEqual(profile.values["layer_height"], "0.20")
    }
```

- [ ] **Step 2: Run, confirm fail**

- [ ] **Step 3: Add the model**

In `BambuGateway/Models/GatewayModels.swift`, append:

```swift
struct ResolvedProcessProfile: Decodable {
    let settingId: String
    let values: [String: String]
}
```

- [ ] **Step 4: Add the method**

In `GatewayClient.swift`, add immediately after `fetchProcessLayout()`:

```swift
    func fetchProcessProfile(settingId: String) async throws -> ResolvedProcessProfile {
        let escaped = settingId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settingId
        return try await get(path: "/api/slicer/processes/\(escaped)")
    }
```

- [ ] **Step 5: Run the test**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift BambuGateway/Models/GatewayModels.swift BambuGatewayTests/GatewayClientProcessTests.swift
git commit -m "Fetch resolved process profile by setting id

- New `fetchProcessProfile(settingId:)` returns stringified key/value config
- Path-encodes the setting id so names with spaces/punctuation work"
```

---

## Task 9: Add processOverrides field to PrintSubmission and wire to all submit paths

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift` (`PrintSubmission` struct, helper, three submit paths)
- Modify: `BambuGateway/App/AppViewModel.swift` (`buildSubmission()` call site)
- Modify: `BambuGatewayTests/GatewayClientProcessTests.swift`

The new field is sent as a single JSON-string multipart form field named `process_overrides`, mirroring the existing `addFilamentProfilesField` pattern.

> **Why we test the helper directly, not `submitPrint`:** `BackgroundTransferService` is a `@MainActor` `NSObject` with a `lazy var session` keyed to a fixed `sessionIdentifier`. iOS allows only one live `URLSession` per identifier, and the helper has no constructor that accepts a custom session — so we can't safely build one for an isolated unit test. Instead, we make the helper that injects the field `internal` (not `private`) and exercise it directly with a `MultipartFormData`.

- [ ] **Step 1: Append the failing tests**

```swift
    func test_addProcessOverridesField_withValues_writesJsonStringField() throws {
        var form = MultipartFormData()
        let client = makeClient()

        try client.addProcessOverridesField(
            to: &form,
            overrides: ["layer_height": "0.16", "wall_loops": "3"]
        )
        form.finalize()

        let body = String(data: form.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"process_overrides\""), "field name missing in body")
        XCTAssertTrue(body.contains("\"layer_height\":\"0.16\""), "layer_height missing in JSON value")
        XCTAssertTrue(body.contains("\"wall_loops\":\"3\""), "wall_loops missing in JSON value")
    }

    func test_addProcessOverridesField_withNil_omitsField() throws {
        var form = MultipartFormData()
        let client = makeClient()

        try client.addProcessOverridesField(to: &form, overrides: nil)
        form.finalize()

        let body = String(data: form.body, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("name=\"process_overrides\""))
    }

    func test_addProcessOverridesField_withEmptyDict_omitsField() throws {
        var form = MultipartFormData()
        let client = makeClient()

        try client.addProcessOverridesField(to: &form, overrides: [:])
        form.finalize()

        let body = String(data: form.body, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("name=\"process_overrides\""))
    }

    func test_printSubmission_initializesWithProcessOverrides() {
        let submission = PrintSubmission(
            file: Imported3MFFile(fileName: "x.3mf", data: Data([0x01])),
            printerId: "P1",
            plateId: nil,
            plateType: "",
            machineProfile: "GM004",
            processProfile: "GP004",
            filamentOverrides: [:],
            processOverrides: ["layer_height": "0.16"]
        )

        XCTAssertEqual(submission.processOverrides?["layer_height"], "0.16")
    }
```

- [ ] **Step 2: Run, confirm fail**

Expected: compile error — `PrintSubmission` has no `processOverrides` initializer parameter; `addProcessOverridesField` not defined.

- [ ] **Step 3: Extend `PrintSubmission`**

In `GatewayClient.swift`, change the struct (currently lines 23-31) to:

```swift
struct PrintSubmission {
    let file: Imported3MFFile
    let printerId: String
    let plateId: Int?
    let plateType: String
    let machineProfile: String
    let processProfile: String
    let filamentOverrides: [Int: FilamentOverrideSelection]
    /// User-edited process parameter overrides. Stringified per the libslic3r
    /// config-string convention (booleans `"1"`/`"0"`, percents `"50%"`, enums
    /// as the enum key). Sent as a single JSON-string multipart field named
    /// `process_overrides`. nil → field omitted.
    let processOverrides: [String: String]?
}
```

- [ ] **Step 4: Add the multipart helper**

In `GatewayClient.swift`, add the helper next to `addFilamentProfilesField`. Note the helper is **internal** (no `private`) so the test target can call it via `@testable import`:

```swift
    func addProcessOverridesField(
        to form: inout MultipartFormData,
        overrides: [String: String]?
    ) throws {
        guard let overrides, !overrides.isEmpty else { return }
        let json = try JSONEncoder().encode(overrides)
        if let string = String(data: json, encoding: .utf8) {
            form.addField(name: "process_overrides", value: string)
        }
    }
```

- [ ] **Step 5: Wire the helper into all three submit paths**

In `fetchPrintPreview` (around line 130), `createSliceJob` (around line 203), and `submitPrint` (around line 358), add this line directly after the existing filament-overrides block (`if !submission.filamentOverrides.isEmpty { ... }`):

```swift
        try addProcessOverridesField(to: &form, overrides: submission.processOverrides)
```

- [ ] **Step 6: Update `buildSubmission()` call site**

`AppViewModel.buildSubmission()` (currently at AppViewModel.swift:837) constructs `PrintSubmission` directly. Pass `processOverrides: nil` for now — Task 14 wires the real value:

```swift
        return PrintSubmission(
            file: selectedFile,
            printerId: resolvedPrinterId(),
            plateId: plateIdToSend,
            plateType: selectedPlateType,
            machineProfile: selectedMachineProfileId,
            processProfile: selectedProcessProfileId,
            filamentOverrides: buildFilamentOverrides(for: parsedInfo),
            processOverrides: nil
        )
```

- [ ] **Step 7: Run the tests**

Run: `xcodebuild ... test -only-testing:BambuGatewayTests/GatewayClientProcessTests`
Expected: all tests pass.

- [ ] **Step 8: Verify the wiring by inspecting the call sites**

Before committing, run:

```bash
grep -n "addProcessOverridesField" BambuGateway/Networking/GatewayClient.swift
```

Expected: 4 hits — the helper definition plus three call sites (`fetchPrintPreview`, `createSliceJob`, `submitPrint`). If any submit path is missing, add the call before committing.

- [ ] **Step 9: Commit**

```bash
git add BambuGateway/Networking/GatewayClient.swift BambuGateway/App/AppViewModel.swift BambuGatewayTests/GatewayClientProcessTests.swift
git commit -m "Send process overrides on slice and print submissions

- `PrintSubmission` gains optional `processOverrides: [String: String]?`
- Helper serializes the dict as a JSON-string multipart field; absent when nil/empty
- Wired into preview, slice-job, and direct-print submit paths"
```

---

## Task 10: Create ProcessOptionsStore — catalogue and layout

**Files:**
- Create: `BambuGateway/Data/ProcessOptionsStore.swift`
- Create: `BambuGatewayTests/ProcessOptionsStoreTests.swift`

The store owns long-lived option metadata. Profile baselines come in Task 11.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

@MainActor
final class ProcessOptionsStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    private func makeClient() -> GatewayClient {
        GatewayClient(baseURLString: "http://gateway.test", session: URLProtocolStub.makeSession())
    }

    private func enqueueCatalogue(version: String = "2.3.2-41") {
        let body = """
        {
          "version": "\(version)",
          "options": {
            "layer_height": {
              "key": "layer_height", "label": "Layer height", "category": "Quality",
              "tooltip": "", "type": "coFloat", "sidetext": "mm", "default": "0.2",
              "min": null, "max": null, "enum_values": null, "enum_labels": null,
              "mode": "simple", "gui_type": "", "nullable": false, "readonly": false
            }
          }
        }
        """.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process", response: .init(body: body))
    }

    private func enqueueLayout(version: String = "2.3.2-41", revision: String = "2026-05-06.1") {
        let body = """
        {
          "version": "\(version)",
          "allowlist_revision": "\(revision)",
          "pages": [
            {"label": "Quality", "optgroups": [
              {"label": "Layer height", "options": ["layer_height"]}
            ]}
          ]
        }
        """.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/options/process/layout", response: .init(body: body))
    }

    func test_loadCatalogue_populatesPublishedField() async throws {
        enqueueCatalogue()
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadCatalogueIfNeeded()

        XCTAssertEqual(store.catalogue?.version, "2.3.2-41")
        XCTAssertEqual(store.catalogue?.options["layer_height"]?.type, .float)
    }

    func test_loadCatalogue_concurrentCallers_coalesceSingleRequest() async throws {
        enqueueCatalogue()
        let store = ProcessOptionsStore(client: makeClient())

        async let a: () = store.loadCatalogueIfNeeded()
        async let b: () = store.loadCatalogueIfNeeded()
        async let c: () = store.loadCatalogueIfNeeded()
        _ = await (a, b, c)

        XCTAssertEqual(URLProtocolStub.requestedPaths.filter { $0 == "/api/options/process" }.count, 1)
    }

    func test_loadCatalogue_secondCallAfterSuccess_doesNotRefetch() async throws {
        enqueueCatalogue()
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadCatalogueIfNeeded()
        await store.loadCatalogueIfNeeded()

        XCTAssertEqual(URLProtocolStub.requestedPaths.filter { $0 == "/api/options/process" }.count, 1)
    }

    func test_loadLayout_populatesAllowlistedKeys() async throws {
        enqueueLayout()
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadLayoutIfNeeded()

        XCTAssertEqual(store.layout?.allowlistRevision, "2026-05-06.1")
        XCTAssertTrue(store.allowlistedKeys.contains("layer_height"))
    }

    func test_loadLayout_revisionChange_replacesCache() async throws {
        enqueueLayout(revision: "2026-05-06.1")
        let store = ProcessOptionsStore(client: makeClient())
        await store.loadLayoutIfNeeded()
        XCTAssertEqual(store.layout?.allowlistRevision, "2026-05-06.1")

        enqueueLayout(revision: "2026-06-01.1")
        await store.refreshLayout()

        XCTAssertEqual(store.layout?.allowlistRevision, "2026-06-01.1")
    }

    func test_loadCatalogue_serverError_setsLoadError() async throws {
        URLProtocolStub.enqueue(
            path: "/api/options/process",
            response: .init(statusCode: 500, body: Data())
        )
        let store = ProcessOptionsStore(client: makeClient())

        await store.loadCatalogueIfNeeded()

        XCTAssertNil(store.catalogue)
        XCTAssertNotNil(store.loadError)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Expected: "cannot find type 'ProcessOptionsStore'".

- [ ] **Step 3: Implement the store**

```swift
import Foundation
import Combine

@MainActor
final class ProcessOptionsStore: ObservableObject {
    @Published private(set) var catalogue: ProcessOptionsCatalogue?
    @Published private(set) var layout: ProcessLayout?
    @Published private(set) var allowlistedKeys: Set<String> = []
    @Published private(set) var loadError: Error?
    @Published private(set) var isLoading: Bool = false

    private let client: GatewayClient
    private var catalogueTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?

    init(client: GatewayClient) {
        self.client = client
    }

    func loadCatalogueIfNeeded() async {
        if catalogue != nil { return }
        if let task = catalogueTask {
            await task.value
            return
        }
        let task = Task { [client] in
            isLoading = true
            defer { isLoading = false }
            do {
                let cat = try await client.fetchProcessOptions()
                self.catalogue = cat
                self.loadError = nil
            } catch {
                self.loadError = error
            }
        }
        catalogueTask = task
        await task.value
        catalogueTask = nil
    }

    func loadLayoutIfNeeded() async {
        if layout != nil { return }
        await refreshLayout()
    }

    func refreshLayout() async {
        if let task = layoutTask {
            await task.value
            return
        }
        let task = Task { [client] in
            isLoading = true
            defer { isLoading = false }
            do {
                let next = try await client.fetchProcessLayout()
                self.layout = next
                self.allowlistedKeys = Set(next.pages.flatMap { $0.optgroups.flatMap(\.options) })
                self.loadError = nil
            } catch {
                self.loadError = error
            }
        }
        layoutTask = task
        await task.value
        layoutTask = nil
    }
}
```

- [ ] **Step 4: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild ... test -only-testing:BambuGatewayTests/ProcessOptionsStoreTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Data/ProcessOptionsStore.swift BambuGatewayTests/ProcessOptionsStoreTests.swift BambuGateway.xcodeproj
git commit -m "Cache option catalogue and layout in ProcessOptionsStore

- `@MainActor` `ObservableObject` owns long-lived option metadata
- Coalesces concurrent loads; refresh swaps in new layout on revision change
- Failures surface via `loadError`; the store is in-memory only"
```

---

## Task 11: Add profile-baseline caching to ProcessOptionsStore

**Files:**
- Modify: `BambuGateway/Data/ProcessOptionsStore.swift`
- Modify: `BambuGatewayTests/ProcessOptionsStoreTests.swift`

- [ ] **Step 1: Append the failing tests**

```swift
    private func enqueueProfile(settingId: String) {
        let escaped = settingId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settingId
        let body = """
        {"setting_id": "\(settingId)", "values": {"layer_height": "0.20"}}
        """.data(using: .utf8)!
        URLProtocolStub.enqueue(path: "/api/slicer/processes/\(escaped)", response: .init(body: body))
    }

    func test_loadProfile_storesByKey() async throws {
        enqueueProfile(settingId: "Custom 0.20mm Standard")
        let store = ProcessOptionsStore(client: makeClient())

        let values = await store.profileValues(for: "Custom 0.20mm Standard")

        XCTAssertEqual(values?["layer_height"], "0.20")
    }

    func test_loadProfile_secondCall_doesNotRefetch() async throws {
        enqueueProfile(settingId: "P")
        let store = ProcessOptionsStore(client: makeClient())

        _ = await store.profileValues(for: "P")
        _ = await store.profileValues(for: "P")

        let escaped = "P".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "P"
        XCTAssertEqual(
            URLProtocolStub.requestedPaths.filter { $0 == "/api/slicer/processes/\(escaped)" }.count,
            1
        )
    }
```

- [ ] **Step 2: Run, confirm fail**

Expected: "value of type 'ProcessOptionsStore' has no member 'profileValues'".

- [ ] **Step 3: Implement**

In `ProcessOptionsStore.swift`, add storage and method:

```swift
    @Published private(set) var profileBaselines: [String: [String: String]] = [:]
    private var profileTasks: [String: Task<[String: String]?, Never>] = [:]

    /// Returns the resolved values for a process profile, fetching once and
    /// caching by setting id. Returns nil on failure (caller may retry later).
    func profileValues(for settingId: String) async -> [String: String]? {
        if settingId.isEmpty { return nil }
        if let cached = profileBaselines[settingId] { return cached }
        if let task = profileTasks[settingId] {
            return await task.value
        }
        let task = Task { [client] () -> [String: String]? in
            do {
                let profile = try await client.fetchProcessProfile(settingId: settingId)
                self.profileBaselines[settingId] = profile.values
                return profile.values
            } catch {
                self.loadError = error
                return nil
            }
        }
        profileTasks[settingId] = task
        let result = await task.value
        profileTasks[settingId] = nil
        return result
    }
```

- [ ] **Step 4: Run the tests**

Expected: all `ProcessOptionsStoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Data/ProcessOptionsStore.swift BambuGatewayTests/ProcessOptionsStoreTests.swift
git commit -m "Cache resolved process profile baselines in store

- `profileValues(for:)` fetches once per setting id and caches by key
- Concurrent callers coalesce on the in-flight task"
```

---

## Task 12: Add effective-value resolver as a free function

**Files:**
- Create: `BambuGateway/Models/ProcessValueResolution.swift`
- Create: `BambuGatewayTests/ProcessValueResolutionTests.swift`

This is the four-rung fallback chain, isolated for testability.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

final class ProcessValueResolutionTests: XCTestCase {
    private let layerHeight = ProcessOption(
        key: "layer_height", label: "Layer height", category: "Quality",
        tooltip: "", type: .float, sidetext: "mm", default: "0.20",
        min: nil, max: nil, enumValues: nil, enumLabels: nil,
        mode: "simple", guiType: "", nullable: false, readonly: false
    )

    func test_resolve_userOverride_winsOverEverything() {
        let mods = ProcessModifications(
            processSettingId: "P", modifiedKeys: ["layer_height"],
            values: ["layer_height": "0.16"]
        )
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"],
            overrides: ["layer_height": "0.20"]
        )
        XCTAssertEqual(value, "0.20")
    }

    func test_resolve_threeMFValue_winsOverBaseline() {
        let mods = ProcessModifications(
            processSettingId: "P", modifiedKeys: ["layer_height"],
            values: ["layer_height": "0.16"]
        )
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"],
            overrides: [:]
        )
        XCTAssertEqual(value, "0.16")
    }

    func test_resolve_baseline_winsOverCatalogueDefault() {
        let mods = ProcessModifications(processSettingId: "P", modifiedKeys: [], values: [:])
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"],
            overrides: [:]
        )
        XCTAssertEqual(value, "0.18")
    }

    func test_resolve_fallsBackToCatalogueDefault() {
        let mods = ProcessModifications(processSettingId: "P", modifiedKeys: [], values: [:])
        let value = resolveProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: [:],
            overrides: [:]
        )
        XCTAssertEqual(value, "0.20")
    }

    func test_revertTarget_excludesUserOverride() {
        let mods = ProcessModifications(
            processSettingId: "P", modifiedKeys: ["layer_height"],
            values: ["layer_height": "0.16"]
        )
        let target = revertTargetForProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"]
        )
        XCTAssertEqual(target.value, "0.16")
        XCTAssertEqual(target.source, .threeMF)
    }

    func test_revertTarget_unmodifiedKey_pointsAtBaseline() {
        let mods = ProcessModifications(processSettingId: "P", modifiedKeys: [], values: [:])
        let target = revertTargetForProcessValue(
            key: "layer_height",
            option: layerHeight,
            modifications: mods,
            baseline: ["layer_height": "0.18"]
        )
        XCTAssertEqual(target.value, "0.18")
        XCTAssertEqual(target.source, .systemDefault)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

Expected: free functions `resolveProcessValue` and `revertTargetForProcessValue` not found.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum ProcessValueSource: Equatable {
    case threeMF
    case systemDefault
}

struct ProcessRevertTarget: Equatable {
    let value: String
    let source: ProcessValueSource
}

/// Effective value rendered in both Modified card and All view.
/// Resolution order: user override > 3MF customization > resolved profile baseline > catalogue default.
func resolveProcessValue(
    key: String,
    option: ProcessOption?,
    modifications: ProcessModifications?,
    baseline: [String: String],
    overrides: [String: String]
) -> String {
    if let user = overrides[key] { return user }
    if let mod = modifications?.values[key] { return mod }
    if let base = baseline[key] { return base }
    return option?.default ?? ""
}

/// The value Revert should restore, plus a hint at where it came from
/// (used by the editor footer to label "From file" vs "Default").
func revertTargetForProcessValue(
    key: String,
    option: ProcessOption?,
    modifications: ProcessModifications?,
    baseline: [String: String]
) -> ProcessRevertTarget {
    if let mod = modifications?.values[key] {
        return ProcessRevertTarget(value: mod, source: .threeMF)
    }
    if let base = baseline[key] {
        return ProcessRevertTarget(value: base, source: .systemDefault)
    }
    return ProcessRevertTarget(value: option?.default ?? "", source: .systemDefault)
}
```

- [ ] **Step 4: Regenerate and run tests**

Run: `xcodegen generate && xcodebuild ... test -only-testing:BambuGatewayTests/ProcessValueResolutionTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BambuGateway/Models/ProcessValueResolution.swift BambuGatewayTests/ProcessValueResolutionTests.swift BambuGateway.xcodeproj
git commit -m "Add pure resolver for effective process values

- `resolveProcessValue` walks user override → 3MF → baseline → catalogue default
- `revertTargetForProcessValue` returns the value Revert restores plus its source"
```

---

## Task 13: Wire override state and store into AppViewModel

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift`
- Create: `BambuGatewayTests/AppViewModelProcessOverridesTests.swift`

The `AppViewModel` initializer takes a `GatewayClient`. We must:
1. Hold a `ProcessOptionsStore`.
2. Hold `processOverrides` and `processBaseline`.
3. Clear both on file change/drop. Re-resolve baseline on process-profile change.
4. Expose `setProcessOverride(key:value:)`, `revertProcessOverride(key:)`, `resetAllProcessOverrides()`.

> **Read AppViewModel before editing.** Identify where the file-import success path lives (search `parsedInfo = `), where `selectedProcessProfileId` is updated (search `selectedProcessProfileId =`), and where the file is cleared (search for `selectedFile = nil`). The hooks below must be added at each of those sites.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import BambuGateway

@MainActor
final class AppViewModelProcessOverridesTests: XCTestCase {
    func test_setProcessOverride_updatesMap() {
        let vm = AppViewModel.makeForTesting()

        vm.setProcessOverride(key: "layer_height", value: "0.16")

        XCTAssertEqual(vm.processOverrides["layer_height"], "0.16")
    }

    func test_revertProcessOverride_removesKey() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "layer_height", value: "0.16")

        vm.revertProcessOverride(key: "layer_height")

        XCTAssertNil(vm.processOverrides["layer_height"])
    }

    func test_resetAllProcessOverrides_clearsMap() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "a", value: "1")
        vm.setProcessOverride(key: "b", value: "2")

        vm.resetAllProcessOverrides()

        XCTAssertTrue(vm.processOverrides.isEmpty)
    }

    func test_clearSelectedFile_clearsOverridesAndBaseline() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "layer_height", value: "0.16")
        vm.processBaseline = ["layer_height": "0.20"]

        vm.clearSelectedFileForTesting()

        XCTAssertTrue(vm.processOverrides.isEmpty)
        XCTAssertTrue(vm.processBaseline.isEmpty)
    }
}

extension AppViewModel {
    /// Test-only constructor that bypasses the live gateway / push services.
    static func makeForTesting() -> AppViewModel {
        // Mirror the live initializer with stubbed dependencies. Adjust names
        // to match the actual `AppViewModel.init(...)` signature in this repo.
        AppViewModel(
            settingsStore: AppSettingsStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!),
            client: GatewayClient(baseURLString: "http://test", session: URLProtocolStub.makeSession())
        )
    }

    func clearSelectedFileForTesting() {
        // Calls the same internal path the UI uses when the user drops a file.
        clearSelectedFile()
    }
}
```

> **Note:** The `AppViewModel.init(...)` signature in this repo is wider than two arguments. Inspect the existing initializer and adapt `makeForTesting()` to pass test doubles for every dependency. The two arguments above are illustrative; do not invent missing types.

- [ ] **Step 2: Run, confirm fail**

Expected: `processOverrides`, `processBaseline`, `setProcessOverride`, `revertProcessOverride`, `resetAllProcessOverrides`, `clearSelectedFile` not found.

- [ ] **Step 3: Add stored state and the store**

In `BambuGateway/App/AppViewModel.swift`, add (near other `@Published` declarations, right after `selectedProcessProfileId`):

```swift
    @Published var processOverrides: [String: String] = [:]
    @Published var processBaseline: [String: String] = [:]
    let processOptionsStore: ProcessOptionsStore
```

In the initializer, instantiate the store from the existing `client`:

```swift
    self.processOptionsStore = ProcessOptionsStore(client: client)
```

(Place this line directly after `self.client = client`. If `client` is created inside the initializer, instantiate the store immediately afterwards.)

- [ ] **Step 4: Add the public mutators and lifecycle hooks**

Append to `AppViewModel`:

```swift
    func setProcessOverride(key: String, value: String) {
        processOverrides[key] = value
    }

    func revertProcessOverride(key: String) {
        processOverrides.removeValue(forKey: key)
    }

    func resetAllProcessOverrides() {
        processOverrides.removeAll()
    }

    /// Called when a new 3MF is parsed successfully.
    fileprivate func onParsedInfoLoaded(_ info: ThreeMFInfo) {
        processOverrides.removeAll()
        processBaseline.removeAll()
        guard let mods = info.processModifications,
              !mods.processSettingId.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if let values = await self.processOptionsStore.profileValues(for: mods.processSettingId) {
                self.processBaseline = values
            }
        }
    }

    /// Called when the selected file is cleared / replaced.
    func clearSelectedFile() {
        selectedFile = nil
        parsedInfo = nil
        processOverrides.removeAll()
        processBaseline.removeAll()
    }

    /// Called when the user changes the process profile picker.
    fileprivate func onProcessProfileChanged(_ settingId: String) {
        processBaseline.removeAll()
        guard !settingId.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if let values = await self.processOptionsStore.profileValues(for: settingId) {
                self.processBaseline = values
            }
        }
    }
```

- [ ] **Step 5: Wire the lifecycle hooks**

- Where `parsedInfo = info` (or equivalent assignment of the parse result), call `onParsedInfoLoaded(info)` immediately after.
- Where `selectedProcessProfileId` is updated as a result of user action, call `onProcessProfileChanged(selectedProcessProfileId)` afterwards. The simplest way: wrap the property with a `didSet`:

```swift
    @Published var selectedProcessProfileId: String = "" {
        didSet { onProcessProfileChanged(selectedProcessProfileId) }
    }
```

- Replace any existing `selectedFile = nil` site that resets state with a call to `clearSelectedFile()`.

- [ ] **Step 6: Run the tests**

Run: `xcodebuild ... test -only-testing:BambuGatewayTests/AppViewModelProcessOverridesTests`
Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add BambuGateway/App/AppViewModel.swift BambuGatewayTests/AppViewModelProcessOverridesTests.swift
git commit -m "Track per-3MF process overrides on AppViewModel

- New `processOverrides` and `processBaseline` cleared on file change/drop
- Process-profile picker swap re-resolves baseline; overrides preserved
- Reset-all clears every user edit"
```

---

## Task 14: Send overrides on submit and surface dropped overrides

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift` (`buildSubmission`, `handlePrintResponse`)
- Modify: `BambuGatewayTests/AppViewModelProcessOverridesTests.swift`

- [ ] **Step 1: Append the failing tests**

```swift
    func test_buildSubmission_includesNonEmptyOverrides() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "layer_height", value: "0.16")
        vm.primeForBuildSubmissionTest()

        let submission = vm.buildSubmissionForTesting()

        XCTAssertEqual(submission?.processOverrides?["layer_height"], "0.16")
    }

    func test_buildSubmission_emptyOverrides_omitsField() {
        let vm = AppViewModel.makeForTesting()
        vm.primeForBuildSubmissionTest()

        let submission = vm.buildSubmissionForTesting()

        XCTAssertNil(submission?.processOverrides)
    }

    func test_handlePrintResponse_droppedOverrides_setsWarningMessage() {
        let vm = AppViewModel.makeForTesting()
        vm.setProcessOverride(key: "layer_height", value: "0.16")
        vm.setProcessOverride(key: "phantom_key", value: "x")

        let info = SettingsTransferInfo(
            status: "applied",
            transferred: [],
            filaments: [],
            processOverridesApplied: [
                ProcessOverrideApplied(key: "layer_height", value: "0.16", previous: "0.20")
            ]
        )
        vm.surfaceProcessOverridesAppliedForTesting(info: info)

        XCTAssertTrue(vm.message.contains("phantom_key"))
        XCTAssertEqual(vm.messageLevel, .warning)
    }
```

> **Test plumbing:** Add the matching test-only helpers to the `extension AppViewModel` block in the test file (see Step 3 below for the production-side helpers they call).

- [ ] **Step 2: Run, confirm fail**

Expected: `buildSubmissionForTesting`, `primeForBuildSubmissionTest`, `surfaceProcessOverridesAppliedForTesting` not found.

- [ ] **Step 3: Update `buildSubmission()` and `handlePrintResponse`**

In `AppViewModel.swift`, change the `PrintSubmission(...)` call in `buildSubmission()` (where Task 9 left it as `processOverrides: nil`) to:

```swift
        return PrintSubmission(
            file: selectedFile,
            printerId: resolvedPrinterId(),
            plateId: plateIdToSend,
            plateType: selectedPlateType,
            machineProfile: selectedMachineProfileId,
            processProfile: selectedProcessProfileId,
            filamentOverrides: buildFilamentOverrides(for: parsedInfo),
            processOverrides: processOverrides.isEmpty ? nil : processOverrides
        )
```

In `handlePrintResponse(_:startedContext:)` (currently around line 871), add this block right before the existing `setMessage(output, level)` call:

```swift
        if let applied = response.settingsTransfer?.processOverridesApplied,
           !processOverrides.isEmpty {
            let appliedKeys = Set(applied.map(\.key))
            let dropped = processOverrides.keys.filter { !appliedKeys.contains($0) }
            if !dropped.isEmpty {
                output += "\nProcess overrides ignored: \(dropped.sorted().joined(separator: ", "))"
            }
        }
```

Then change the `level` line:

```swift
        let droppedOverrides = (response.settingsTransfer?.processOverridesApplied != nil)
            && processOverrides.contains(where: { kv in
                !(response.settingsTransfer?.processOverridesApplied?.contains(where: { $0.key == kv.key }) ?? false)
            })
        let level: MessageLevel = (hasDiscardedFilamentCustomizations(response.settingsTransfer) || droppedOverrides) ? .warning : .success
```

- [ ] **Step 4: Add test-only helpers**

In `AppViewModel.swift`, append these `internal` helpers (kept narrow on purpose — they only expose what tests need without leaking private state):

```swift
#if DEBUG
    /// Test-only: prime enough state so `buildSubmission()` returns a non-nil result.
    func primeForBuildSubmissionTest() {
        selectedFile = Imported3MFFile(fileName: "x.3mf", data: Data([0x01]))
        parsedInfo = ThreeMFInfo(
            plates: [],
            filaments: [],
            printProfile: PrintProfileInfo(printSettingsId: "P", layerHeight: "0.2"),
            printer: PrinterInfo(printerSettingsId: "X", printerModel: "A1", nozzleDiameter: "0.4"),
            hasGcode: true,
            processModifications: nil
        )
        selectedMachineProfileId = "GM004"
        selectedProcessProfileId = "GP004"
    }

    func buildSubmissionForTesting() -> PrintSubmission? {
        buildSubmission()
    }

    func surfaceProcessOverridesAppliedForTesting(info: SettingsTransferInfo) {
        let response = PrintResponse(
            status: "started",
            fileName: "x.3mf",
            printerId: "P1",
            wasSliced: true,
            settingsTransfer: info,
            uploadId: nil,
            estimate: nil
        )
        handlePrintResponse(response, startedContext: nil)
    }
#endif
```

> If `parsedInfo.hasGcode = true` causes `needsSlicing` to be false in your repo (sending the submission down a different branch), set `hasGcode: false` instead so the slicing path is exercised.

- [ ] **Step 5: Run the tests**

Expected: all `AppViewModelProcessOverridesTests` pass.

- [ ] **Step 6: Commit**

```bash
git add BambuGateway/App/AppViewModel.swift BambuGatewayTests/AppViewModelProcessOverridesTests.swift
git commit -m "Submit process overrides and surface dropped keys

- `buildSubmission()` includes overrides only when non-empty
- After print response, warn when the gateway dropped any of the user's overrides"
```

---

## Task 15: Build ProcessOptionRow

**Files:**
- Create: `BambuGateway/Views/ProcessParameters/ProcessOptionRow.swift`

This is the shared row used in the Modified card and the All view's page detail.

- [ ] **Step 1: Implement the row**

```swift
import SwiftUI

struct ProcessOptionRow: View {
    enum Status {
        case unmodified
        case threeMFModified
        case userEdited
        case readOnly
    }

    let label: String
    let value: String
    let sidetext: String
    let status: Status
    let showsTooltip: Bool
    let tooltip: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                statusIndicator
                    .frame(width: 12, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showsTooltip, let tooltip, !tooltip.isEmpty {
                        Text(tooltip)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text(value)
                        .font(.body)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(status == .readOnly ? .secondary : .primary)
                    if !sidetext.isEmpty {
                        Text(sidetext)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if status != .readOnly {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .readOnly)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)\(sidetext.isEmpty ? "" : " " + sidetext)")
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(status == .readOnly ? "Read only" : "Tap to edit")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .unmodified:
            Color.clear.frame(width: 8, height: 8)
        case .threeMFModified:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accentBlue)
        case .userEdited:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
        case .readOnly:
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityValueText: String {
        switch status {
        case .unmodified: return ""
        case .threeMFModified: return "modified by file"
        case .userEdited: return "edited by you"
        case .readOnly: return "read only"
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Views/ProcessParameters/ProcessOptionRow.swift BambuGateway.xcodeproj
git commit -m "Add ProcessOptionRow shared row component

- Renders status dot, label, value, sidetext, and chevron
- Read-only variant shows lock and disables the tap action"
```

---

## Task 16: Build ProcessOptionEditor sheet

**Files:**
- Create: `BambuGateway/Views/ProcessParameters/ProcessOptionEditor.swift`

The editor sheet validates on save and writes a string back into the bound value. The caller is responsible for committing that string into `processOverrides` when Save returns.

- [ ] **Step 1: Implement the editor**

```swift
import SwiftUI

struct ProcessOptionEditor: View {
    let option: ProcessOption
    let revertTarget: ProcessRevertTarget
    /// Current effective value — may equal revertTarget.value (no user edit yet)
    /// or the user's prior override.
    let initialValue: String
    /// Called on Save with the stringified value to write into processOverrides.
    let onSave: (String) -> Void
    /// Called on Revert (removes the key from processOverrides).
    let onRevert: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                if !option.tooltip.isEmpty {
                    Section {
                        Text(option.tooltip)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    editorWidget
                    if let error = validationError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    if let range = rangeHint {
                        Text(range)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(option.label)
                }

                Section {
                    HStack {
                        Button {
                            onRevert()
                            dismiss()
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(draft == revertTarget.value)

                        Spacer()

                        Text(footerLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(option.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let parsed = validatedValue() {
                            onSave(parsed)
                            dismiss()
                        }
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear { draft = initialValue }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Per-type widget

    @ViewBuilder
    private var editorWidget: some View {
        switch option.type {
        case .bool:
            Toggle(isOn: Binding(
                get: { draft == "1" },
                set: { draft = $0 ? "1" : "0" }
            )) { EmptyView() }
                .tint(Color.accentBlue)

        case .int, .ints:
            HStack {
                TextField(option.sidetext, text: $draft)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text(option.sidetext).foregroundStyle(.secondary)
            }

        case .float, .floats:
            HStack {
                TextField(option.sidetext, text: $draft)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Text(option.sidetext).foregroundStyle(.secondary)
            }

        case .percent, .percents:
            HStack {
                TextField("0", text: Binding(
                    get: { draft.replacingOccurrences(of: "%", with: "") },
                    set: { draft = $0.isEmpty ? "" : "\($0)%" }
                ))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                Text("%").foregroundStyle(.secondary)
            }

        case .floatOrPercent, .floatsOrPercents:
            HStack {
                Picker("", selection: floatOrPercentBinding) {
                    Text(option.sidetext).tag(false)
                    Text("%").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                TextField("", text: floatOrPercentNumericBinding)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            }

        case .string, .strings:
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)

        case .enum:
            Picker(option.label, selection: $draft) {
                ForEach(Array(zip(option.enumValues ?? [], displayLabels).enumerated()), id: \.offset) { _, pair in
                    Text(pair.1).tag(pair.0)
                }
            }
            .pickerStyle(.menu)

        case .point, .points, .point3, .bools, .none:
            VStack(alignment: .leading, spacing: 8) {
                Text(initialValue.isEmpty ? "—" : initialValue)
                    .font(.body.monospaced())
                Text("Editing this option type is not yet supported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayLabels: [String] {
        if let labels = option.enumLabels, !labels.isEmpty { return labels }
        return option.enumValues ?? []
    }

    private var floatOrPercentBinding: Binding<Bool> {
        Binding(
            get: { draft.hasSuffix("%") },
            set: { isPercent in
                let stripped = draft.replacingOccurrences(of: "%", with: "")
                draft = isPercent ? "\(stripped)%" : stripped
            }
        )
    }

    private var floatOrPercentNumericBinding: Binding<String> {
        Binding(
            get: { draft.replacingOccurrences(of: "%", with: "") },
            set: { newValue in
                draft = draft.hasSuffix("%") ? "\(newValue)%" : newValue
            }
        )
    }

    private var rangeHint: String? {
        switch (option.min, option.max) {
        case let (lo?, hi?): return "Range \(lo)–\(hi)\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
        case let (lo?, nil): return "Min \(lo)\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
        case let (nil, hi?): return "Max \(hi)\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
        default: return nil
        }
    }

    private var footerLabel: String {
        let suffix = option.sidetext.isEmpty ? "" : " \(option.sidetext)"
        switch revertTarget.source {
        case .threeMF: return "From file: \(revertTarget.value)\(suffix)"
        case .systemDefault: return "Default: \(revertTarget.value)\(suffix)"
        }
    }

    // MARK: - Validation

    private var isValid: Bool { validatedValue() != nil }

    private func validatedValue() -> String? {
        switch option.type {
        case .bool:
            return (draft == "1" || draft == "0") ? draft : nil
        case .int, .ints:
            guard let i = Int(draft.trimmingCharacters(in: .whitespaces)) else {
                validationError = "Enter a whole number."
                return nil
            }
            if let lo = option.min, Double(i) < lo {
                validationError = "Must be ≥ \(Int(lo))\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
                return nil
            }
            if let hi = option.max, Double(i) > hi {
                validationError = "Must be ≤ \(Int(hi))\(option.sidetext.isEmpty ? "" : " " + option.sidetext)"
                return nil
            }
            validationError = nil
            return String(i)
        case .float, .floats:
            guard let d = Double(draft.replacingOccurrences(of: ",", with: ".")) else {
                validationError = "Enter a decimal number."
                return nil
            }
            if let lo = option.min, d < lo { validationError = "Must be ≥ \(lo)"; return nil }
            if let hi = option.max, d > hi { validationError = "Must be ≤ \(hi)"; return nil }
            validationError = nil
            return draft
        case .percent, .percents:
            let stripped = draft.replacingOccurrences(of: "%", with: "")
            guard !stripped.isEmpty, Double(stripped) != nil else {
                validationError = "Enter a percent value."
                return nil
            }
            validationError = nil
            return draft.hasSuffix("%") ? draft : "\(stripped)%"
        case .floatOrPercent, .floatsOrPercents:
            let stripped = draft.replacingOccurrences(of: "%", with: "")
            guard !stripped.isEmpty, Double(stripped) != nil else {
                validationError = "Enter a number."
                return nil
            }
            validationError = nil
            return draft
        case .string, .strings:
            validationError = nil
            return draft
        case .enum:
            guard option.enumValues?.contains(draft) == true else {
                validationError = "Select a value."
                return nil
            }
            validationError = nil
            return draft
        case .point, .points, .point3, .bools, .none:
            return nil
        }
    }
}
```

- [ ] **Step 2: Regenerate and build**

Run: `xcodegen generate && xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Views/ProcessParameters/ProcessOptionEditor.swift BambuGateway.xcodeproj
git commit -m "Add ProcessOptionEditor sheet with per-type widgets

- Toggle, stepper, decimal, percent, mm-or-percent, text, enum, color, slider
- Validates on Save with min/max clamping and helpful error copy
- Footer surfaces the Revert target with `From file:` or `Default:` label"
```

---

## Task 17: Build ProcessPageDetailView

**Files:**
- Create: `BambuGateway/Views/ProcessParameters/ProcessPageDetailView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct ProcessPageDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let page: ProcessPage

    @State private var editingOptionKey: String?

    var body: some View {
        List {
            ForEach(page.optgroups, id: \.label) { group in
                Section {
                    ForEach(group.options, id: \.self) { key in
                        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
                            ProcessOptionRow(
                                label: option.label,
                                value: resolvedValue(forKey: key, option: option),
                                sidetext: option.sidetext,
                                status: status(forKey: key),
                                showsTooltip: true,
                                tooltip: option.tooltip,
                                action: { editingOptionKey = key }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    }
                } header: {
                    Text(group.label.uppercased())
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(page.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: editingOptionBinding) { key in
            editorSheet(forKey: key.id)
        }
    }

    private var editingOptionBinding: Binding<IdentifiedKey?> {
        Binding(
            get: { editingOptionKey.map(IdentifiedKey.init) },
            set: { editingOptionKey = $0?.id }
        )
    }

    private struct IdentifiedKey: Identifiable, Equatable {
        let id: String
    }

    private func status(forKey key: String) -> ProcessOptionRow.Status {
        if !viewModel.processOptionsStore.allowlistedKeys.contains(key) { return .readOnly }
        if viewModel.processOverrides[key] != nil { return .userEdited }
        if viewModel.parsedInfo?.processModifications?.values[key] != nil { return .threeMFModified }
        return .unmodified
    }

    private func resolvedValue(forKey key: String, option: ProcessOption) -> String {
        resolveProcessValue(
            key: key,
            option: option,
            modifications: viewModel.parsedInfo?.processModifications,
            baseline: viewModel.processBaseline,
            overrides: viewModel.processOverrides
        )
    }

    @ViewBuilder
    private func editorSheet(forKey key: String) -> some View {
        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
            ProcessOptionEditor(
                option: option,
                revertTarget: revertTargetForProcessValue(
                    key: key,
                    option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline
                ),
                initialValue: resolvedValue(forKey: key, option: option),
                onSave: { newValue in viewModel.setProcessOverride(key: key, value: newValue) },
                onRevert: { viewModel.revertProcessOverride(key: key) }
            )
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild ... build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Views/ProcessParameters/ProcessPageDetailView.swift BambuGateway.xcodeproj
git commit -m "Add ProcessPageDetailView (sectioned options per page)

- One section per optgroup; rows match layout order
- Row tap opens the editor sheet"
```

---

## Task 18: Build ProcessAllSettingsView

**Files:**
- Create: `BambuGateway/Views/ProcessParameters/ProcessAllSettingsView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct ProcessAllSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var showResetConfirm = false
    @State private var editingOptionKey: String?

    var body: some View {
        NavigationStack {
            Group {
                if let layout = viewModel.processOptionsStore.layout {
                    if search.isEmpty {
                        pageList(layout)
                    } else {
                        searchResults(layout)
                    }
                } else if viewModel.processOptionsStore.loadError != nil {
                    errorView
                } else {
                    ProgressView().progressViewStyle(.circular)
                }
            }
            .background(Color.dashboardBackground)
            .navigationTitle("Process settings")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showResetConfirm = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(viewModel.processOverrides.isEmpty)
                    .accessibilityLabel("Reset all")
                }
            }
            .confirmationDialog(
                "Reset all process settings?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { viewModel.resetAllProcessOverrides() }
                Button("Cancel", role: .cancel) { }
            }
            .task {
                await viewModel.processOptionsStore.loadCatalogueIfNeeded()
                await viewModel.processOptionsStore.loadLayoutIfNeeded()
            }
            .sheet(item: editingOptionBinding) { key in
                editorSheet(forKey: key.id)
            }
        }
    }

    @ViewBuilder
    private func pageList(_ layout: ProcessLayout) -> some View {
        List {
            ForEach(layout.pages, id: \.label) { page in
                NavigationLink {
                    ProcessPageDetailView(viewModel: viewModel, page: page)
                } label: {
                    pageRow(page)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func pageRow(_ page: ProcessPage) -> some View {
        let total = page.optgroups.flatMap(\.options).count
        let edited = page.optgroups.flatMap(\.options).filter { viewModel.processOverrides[$0] != nil }.count
        HStack {
            Text(page.label)
                .font(.body)
            Spacer()
            HStack(spacing: 6) {
                Text("\(total) options")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if edited > 0 {
                    Text("· \(edited) edited")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ layout: ProcessLayout) -> some View {
        let allKeys = layout.pages.flatMap { $0.optgroups.flatMap(\.options) }
        let matches = allKeys.filter { key in
            guard let option = viewModel.processOptionsStore.catalogue?.options[key] else { return false }
            let needle = search.lowercased()
            return option.label.lowercased().contains(needle) || key.lowercased().contains(needle)
        }
        List {
            Section("Results") {
                ForEach(matches, id: \.self) { key in
                    if let option = viewModel.processOptionsStore.catalogue?.options[key] {
                        ProcessOptionRow(
                            label: option.label,
                            value: resolveProcessValue(
                                key: key, option: option,
                                modifications: viewModel.parsedInfo?.processModifications,
                                baseline: viewModel.processBaseline,
                                overrides: viewModel.processOverrides
                            ),
                            sidetext: option.sidetext,
                            status: rowStatus(forKey: key),
                            showsTooltip: false,
                            tooltip: nil,
                            action: { editingOptionKey = key }
                        )
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: 12) {
            Text("Couldn't load process settings")
                .font(.headline)
            Button("Retry") {
                Task {
                    await viewModel.processOptionsStore.loadCatalogueIfNeeded()
                    await viewModel.processOptionsStore.refreshLayout()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func rowStatus(forKey key: String) -> ProcessOptionRow.Status {
        if !viewModel.processOptionsStore.allowlistedKeys.contains(key) { return .readOnly }
        if viewModel.processOverrides[key] != nil { return .userEdited }
        if viewModel.parsedInfo?.processModifications?.values[key] != nil { return .threeMFModified }
        return .unmodified
    }

    private var editingOptionBinding: Binding<IdentifiedKey?> {
        Binding(
            get: { editingOptionKey.map(IdentifiedKey.init) },
            set: { editingOptionKey = $0?.id }
        )
    }

    private struct IdentifiedKey: Identifiable, Equatable {
        let id: String
    }

    @ViewBuilder
    private func editorSheet(forKey key: String) -> some View {
        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
            ProcessOptionEditor(
                option: option,
                revertTarget: revertTargetForProcessValue(
                    key: key,
                    option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline
                ),
                initialValue: resolveProcessValue(
                    key: key, option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline,
                    overrides: viewModel.processOverrides
                ),
                onSave: { newValue in viewModel.setProcessOverride(key: key, value: newValue) },
                onRevert: { viewModel.revertProcessOverride(key: key) }
            )
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild ... build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add BambuGateway/Views/ProcessParameters/ProcessAllSettingsView.swift BambuGateway.xcodeproj
git commit -m "Add ProcessAllSettingsView (page list + global search)

- Top-level page list with per-page edited count badge
- Searchable across all options; results bypass the page hierarchy
- Toolbar Done dismisses; Reset all confirmation clears overrides"
```

---

## Task 19: Build ProcessParametersCard and embed in PrintTab

**Files:**
- Create: `BambuGateway/Views/ProcessParameters/ProcessParametersCard.swift`
- Modify: `BambuGateway/Views/PrintTab.swift`

- [ ] **Step 1: Implement the card**

```swift
import SwiftUI

struct ProcessParametersCard: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showAllSettings = false
    @State private var editingOptionKey: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !modifiedKeys.isEmpty {
                Divider().opacity(0.3)
                ForEach(modifiedKeys, id: \.self) { key in
                    optionRow(forKey: key)
                    if key != modifiedKeys.last {
                        Divider().opacity(0.3).padding(.leading, 36)
                    }
                }
            } else {
                emptyBody
            }
            showAllButton
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await viewModel.processOptionsStore.loadCatalogueIfNeeded()
            await viewModel.processOptionsStore.loadLayoutIfNeeded()
        }
        .fullScreenCover(isPresented: $showAllSettings) {
            ProcessAllSettingsView(viewModel: viewModel)
        }
        .sheet(item: editingOptionBinding) { key in
            editorSheet(forKey: key.id)
        }
    }

    private var modifiedKeys: [String] {
        viewModel.parsedInfo?.processModifications?.modifiedKeys ?? []
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentBlue)
            Text("Process settings")
                .font(.headline)
            Spacer()
            if !modifiedKeys.isEmpty {
                Text("\(modifiedKeys.count) modified")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentBlue.opacity(0.18), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private func optionRow(forKey key: String) -> some View {
        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
            ProcessOptionRow(
                label: option.label,
                value: resolveProcessValue(
                    key: key, option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline,
                    overrides: viewModel.processOverrides
                ),
                sidetext: option.sidetext,
                status: status(forKey: key),
                showsTooltip: false,
                tooltip: nil,
                action: { editingOptionKey = key }
            )
        } else {
            // Catalogue missing the key — render the raw value read-only.
            ProcessOptionRow(
                label: key,
                value: viewModel.parsedInfo?.processModifications?.values[key] ?? "",
                sidetext: "",
                status: .readOnly,
                showsTooltip: false,
                tooltip: nil,
                action: { }
            )
        }
    }

    @ViewBuilder
    private var emptyBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No customizations from default profile")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var showAllButton: some View {
        Button {
            showAllSettings = true
        } label: {
            HStack {
                Text("Show all settings")
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TonalButtonStyle(tint: Color.accentBlue))
        .padding(.top, 10)
    }

    private func status(forKey key: String) -> ProcessOptionRow.Status {
        if !viewModel.processOptionsStore.allowlistedKeys.contains(key) { return .readOnly }
        if viewModel.processOverrides[key] != nil { return .userEdited }
        return .threeMFModified
    }

    private var editingOptionBinding: Binding<IdentifiedKey?> {
        Binding(
            get: { editingOptionKey.map(IdentifiedKey.init) },
            set: { editingOptionKey = $0?.id }
        )
    }

    private struct IdentifiedKey: Identifiable, Equatable {
        let id: String
    }

    @ViewBuilder
    private func editorSheet(forKey key: String) -> some View {
        if let option = viewModel.processOptionsStore.catalogue?.options[key] {
            ProcessOptionEditor(
                option: option,
                revertTarget: revertTargetForProcessValue(
                    key: key,
                    option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline
                ),
                initialValue: resolveProcessValue(
                    key: key, option: option,
                    modifications: viewModel.parsedInfo?.processModifications,
                    baseline: viewModel.processBaseline,
                    overrides: viewModel.processOverrides
                ),
                onSave: { newValue in viewModel.setProcessOverride(key: key, value: newValue) },
                onRevert: { viewModel.revertProcessOverride(key: key) }
            )
        }
    }
}
```

- [ ] **Step 2: Embed in PrintTab**

In `BambuGateway/Views/PrintTab.swift`, locate the `slicingSettingsSection` block inside the body's `VStack` (around lines 22-25). Insert the new card directly after it, **only when slicing is needed**:

```swift
                        if viewModel.needsSlicing {
                            slicingSettingsSection
                            ProcessParametersCard(viewModel: viewModel)
                        }

                        filamentsSection
```

- [ ] **Step 3: Build**

Run: `xcodegen generate && xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add BambuGateway/Views/ProcessParameters/ProcessParametersCard.swift BambuGateway/Views/PrintTab.swift BambuGateway.xcodeproj
git commit -m "Embed Process settings card on the print screen

- New `ProcessParametersCard` shows what the 3MF customized away from defaults
- Tap a row to edit allowlisted values; locked rows show a read-only lock
- 'Show all settings' opens the full editor for any non-modified key"
```

---

## Task 20: End-to-end verification on simulator

This task has no automated test. Run the steps manually and capture observations.

- [ ] **Step 1: Boot the run simulator (different from the unit-test simulator)**

Run: `xcrun simctl list devices booted | head -10`

If no simulator is booted, boot iPhone 16 Pro 18.3:

```bash
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
open -a Simulator
```

- [ ] **Step 2: Build and install on the booted simulator**

Run:
```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.3' CODE_SIGNING_ALLOWED=NO build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Walk through the happy path**

1. Launch the app; configure the gateway URL pointing at a server with the new endpoints (revision ≥ 41).
2. Import a 3MF file that customises at least one process setting (e.g. `layer_height`).
3. Confirm the **Process settings** card appears between the slicing-settings section and the filaments section.
4. Confirm the badge shows `"\(n) modified"` and rows render with the blue dot.
5. Tap a row → the editor sheet opens; tooltip shows; Save is initially disabled (no change).
6. Edit the value → Save activates → tap Save → row's dot turns orange and the value updates.
7. Tap **Show all settings** → the full-screen cover opens; pages render; tap **Quality** → the optgroup-grouped list loads.
8. Type into the search field → the results section appears.
9. Tap **Reset all** → confirm → orange dots disappear.
10. Dismiss back to the print screen, tap **Print** (or **Preview**) → in `process_overrides_applied` (visible by inspecting gateway logs or the resulting toast on dropped keys), confirm overrides were sent.

- [ ] **Step 4: Walk through error / empty paths**

1. Import a 3MF with no customisations → card shows the empty state with "No customizations from default profile" and "Show all settings" button still present.
2. Point the app at an older gateway (without `/api/options/process`) → the All view shows the "Couldn't load process settings — Retry" message and the print path still works.

- [ ] **Step 5: Run the full unit test suite once**

Run:
```bash
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' test
```
Expected: every test in `BambuGatewayTests` passes.

- [ ] **Step 6: No commit needed unless you fix anything**

If a manual test surfaces a bug, fix it under a new commit; otherwise this task closes the plan.

---

## Self-review checklist (run before declaring done)

- [ ] Each spec section is covered by at least one task. Mapping:
    - Architecture & file layout → Tasks 2, 10, 13, 15-19
    - Data model → Tasks 2, 3, 4, 5, 8 (ResolvedProcessProfile)
    - UI surfaces → Tasks 15-19
    - Data flow & lifecycle → Tasks 10, 11, 12, 13
    - Submit & response handling → Tasks 9, 14
    - Error states → Tasks 10 (`loadError`), 14 (dropped surface), 18 (retry view)
    - Edge cases → Task 19 (catalogue missing key fallback row)
    - Versioning & cache invalidation → Tasks 10, 11
    - Testing → Tasks 1-14 (unit tests), Task 20 (manual end-to-end)
- [ ] No placeholder copy ("TBD", "implement later", etc.).
- [ ] All identifiers (`processOverrides`, `processBaseline`, `ProcessOptionsStore`, `resolveProcessValue`, `revertTargetForProcessValue`, `setProcessOverride`, `revertProcessOverride`, `resetAllProcessOverrides`, `processOptionsStore`, `clearSelectedFile`, `onParsedInfoLoaded`, `onProcessProfileChanged`) are introduced before they're used and consistent across tasks.
- [ ] Endpoint paths in iOS code: `/api/options/process`, `/api/options/process/layout`, `/api/slicer/processes/{id}` (verify last with gateway team). Multipart field names: `process_overrides`.
- [ ] Build steps run `xcodegen generate` whenever a new file is added so the project file picks it up.
