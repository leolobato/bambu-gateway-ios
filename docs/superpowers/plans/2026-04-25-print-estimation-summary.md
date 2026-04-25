# Print Estimation Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a filament + print-time estimation card in the existing G-code preview modal, and in a new success modal after the direct-print path submits.

**Architecture:** A single reusable `PrintEstimationCard` SwiftUI view, fed by an optional `PrintEstimate` model decoded from gateway JSON (for `/api/print`) and a base64 JSON HTTP header (for `/api/print-preview`, whose body is binary). Two surfaces consume the card: `GCodePreviewModal` (pinned above the 3D scene) and a new `PrintSuccessModal` sheet shown after `submitPrint` completes.

**Tech Stack:** SwiftUI (iOS 18+), Foundation, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-04-25-print-estimation-summary-design.md`

**Build & test commands (from `CLAUDE.md`):**
- Tests run on iPhone 16 / iOS 18.6 simulator: `xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/<TestClass>/<test_method>`
- Compile-only check: `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

---

## File map

| File | Action | Purpose |
|---|---|---|
| `BambuGateway/Models/PrintEstimate.swift` | Create | The estimate model + `isEmpty` helper |
| `BambuGateway/Models/GatewayModels.swift` | Modify | Add `estimate` to `PrintResponse` and `PreviewResult` |
| `BambuGateway/Networking/GatewayClient.swift` | Modify | Read `X-Print-Estimate` base64 JSON header in `fetchPrintPreview` |
| `BambuGateway/App/AppViewModel.swift` | Modify | Publish `previewEstimate`, `lastPrintEstimate`, `lastPrintPrinterName`, `showPrintSuccessModal`; populate them in the print/preview flows |
| `BambuGateway/Views/PrintEstimationCard.swift` | Create | Reusable card with rows, formatters, redacted state |
| `BambuGateway/Views/PrintSuccessModal.swift` | Create | Sheet shown after direct-print success |
| `BambuGateway/Views/GCodePreviewModal.swift` | Modify | Pin estimation card above the 3D viewport |
| `BambuGateway/Views/PrintTab.swift` | Modify | Present `PrintSuccessModal` as `.sheet` |
| `BambuGatewayTests/PrintEstimateDecodingTests.swift` | Create | Decode tests for `PrintEstimate` and the header path |
| `BambuGatewayTests/PrintEstimationFormattingTests.swift` | Create | Tests for the duration / length / mass formatters |
| `project.yml` | No change | The two test files land under `BambuGatewayTests` which is already a glob-based source path |

The test target uses path globbing under `BambuGatewayTests`, so new test files are picked up automatically. `project.yml` does NOT need editing. After creating new source files under `BambuGateway/`, regenerate the Xcode project with `xcodegen generate`.

---

### Task 1: Add the `PrintEstimate` model

**Files:**
- Create: `BambuGateway/Models/PrintEstimate.swift`
- Test: `BambuGatewayTests/PrintEstimateDecodingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `BambuGatewayTests/PrintEstimateDecodingTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class PrintEstimateDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> PrintEstimate {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrintEstimate.self, from: Data(json.utf8))
    }

    func test_decodesAllFields() throws {
        let json = """
        {
          "total_filament_millimeters": 9280.0,
          "total_filament_grams": 29.46,
          "model_filament_millimeters": 9120.0,
          "model_filament_grams": 28.96,
          "prepare_seconds": 356,
          "model_print_seconds": 9000,
          "total_seconds": 9356
        }
        """
        let estimate = try decode(json)
        XCTAssertEqual(estimate.totalFilamentMillimeters, 9280.0)
        XCTAssertEqual(estimate.totalFilamentGrams, 29.46)
        XCTAssertEqual(estimate.modelFilamentMillimeters, 9120.0)
        XCTAssertEqual(estimate.modelFilamentGrams, 28.96)
        XCTAssertEqual(estimate.prepareSeconds, 356)
        XCTAssertEqual(estimate.modelPrintSeconds, 9000)
        XCTAssertEqual(estimate.totalSeconds, 9356)
        XCTAssertFalse(estimate.isEmpty)
    }

    func test_decodesEmptyObjectAsAllNil() throws {
        let estimate = try decode("{}")
        XCTAssertNil(estimate.totalFilamentMillimeters)
        XCTAssertNil(estimate.totalSeconds)
        XCTAssertTrue(estimate.isEmpty)
    }

    func test_decodesPartialFields() throws {
        let json = """
        { "total_seconds": 600, "total_filament_grams": 5.0 }
        """
        let estimate = try decode(json)
        XCTAssertEqual(estimate.totalSeconds, 600)
        XCTAssertEqual(estimate.totalFilamentGrams, 5.0)
        XCTAssertNil(estimate.modelPrintSeconds)
        XCTAssertFalse(estimate.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimateDecodingTests
```

Expected: build failure with "cannot find 'PrintEstimate' in scope".

- [ ] **Step 3: Create the model file**

Create `BambuGateway/Models/PrintEstimate.swift`:

```swift
import Foundation

struct PrintEstimate: Decodable, Equatable {
    let totalFilamentMillimeters: Double?
    let totalFilamentGrams: Double?
    let modelFilamentMillimeters: Double?
    let modelFilamentGrams: Double?
    let prepareSeconds: Int?
    let modelPrintSeconds: Int?
    let totalSeconds: Int?

    var isEmpty: Bool {
        totalFilamentMillimeters == nil
            && totalFilamentGrams == nil
            && modelFilamentMillimeters == nil
            && modelFilamentGrams == nil
            && prepareSeconds == nil
            && modelPrintSeconds == nil
            && totalSeconds == nil
    }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

```
xcodegen generate
```

Expected: "Loaded project ..." with no errors.

- [ ] **Step 5: Run tests to verify they pass**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimateDecodingTests
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```
git add BambuGateway/Models/PrintEstimate.swift BambuGatewayTests/PrintEstimateDecodingTests.swift BambuGateway.xcodeproj
git commit -m "Add PrintEstimate model"
```

---

### Task 2: Add `estimate` to `PrintResponse`

**Files:**
- Modify: `BambuGateway/Models/GatewayModels.swift:245-252`
- Test: `BambuGatewayTests/PrintEstimateDecodingTests.swift`

- [ ] **Step 1: Add a failing test for `PrintResponse` decoding with estimate**

Append to `BambuGatewayTests/PrintEstimateDecodingTests.swift`:

```swift
final class PrintResponseEstimateTests: XCTestCase {
    private func decode(_ json: String) throws -> PrintResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PrintResponse.self, from: Data(json.utf8))
    }

    func test_decodesPrintResponseWithEstimate() throws {
        let json = """
        {
          "status": "ok",
          "file_name": "demo.3mf",
          "printer_id": "P01",
          "was_sliced": true,
          "estimate": { "total_seconds": 9356, "total_filament_grams": 29.46 }
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.estimate?.totalSeconds, 9356)
        XCTAssertEqual(response.estimate?.totalFilamentGrams, 29.46)
    }

    func test_decodesPrintResponseWithoutEstimate() throws {
        let json = """
        {
          "status": "ok",
          "file_name": "demo.3mf",
          "printer_id": "P01",
          "was_sliced": false
        }
        """
        let response = try decode(json)
        XCTAssertNil(response.estimate)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintResponseEstimateTests
```

Expected: build failure ("value of type 'PrintResponse' has no member 'estimate'") OR test fails to find the member.

- [ ] **Step 3: Add the field to `PrintResponse`**

In `BambuGateway/Models/GatewayModels.swift`, replace the `PrintResponse` struct (around line 245):

```swift
struct PrintResponse: Decodable {
    let status: String
    let fileName: String
    let printerId: String
    let wasSliced: Bool
    let settingsTransfer: SettingsTransferInfo?
    let uploadId: String?
    let estimate: PrintEstimate?
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintResponseEstimateTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```
git add BambuGateway/Models/GatewayModels.swift BambuGatewayTests/PrintEstimateDecodingTests.swift
git commit -m "Add optional estimate field to PrintResponse"
```

---

### Task 3: Read `X-Print-Estimate` header in `fetchPrintPreview`

**Files:**
- Modify: `BambuGateway/Models/GatewayModels.swift:313-317` (extend `PreviewResult`)
- Modify: `BambuGateway/Networking/GatewayClient.swift:100-142` (read header)
- Test: `BambuGatewayTests/PrintEstimateDecodingTests.swift`

- [ ] **Step 1: Add a failing test that decodes the header format**

Append to `BambuGatewayTests/PrintEstimateDecodingTests.swift`:

```swift
final class PrintEstimateHeaderDecodingTests: XCTestCase {
    func test_decodesBase64JSONHeader() throws {
        let json = """
        {"total_seconds": 120, "model_filament_grams": 1.5}
        """
        let base64 = Data(json.utf8).base64EncodedString()
        let estimate = try XCTUnwrap(PrintEstimate.decodeFromHeader(base64))
        XCTAssertEqual(estimate.totalSeconds, 120)
        XCTAssertEqual(estimate.modelFilamentGrams, 1.5)
    }

    func test_returnsNilForInvalidBase64() {
        XCTAssertNil(PrintEstimate.decodeFromHeader("not-base64!@#"))
    }

    func test_returnsNilForInvalidJSON() {
        let base64 = Data("not json".utf8).base64EncodedString()
        XCTAssertNil(PrintEstimate.decodeFromHeader(base64))
    }

    func test_returnsNilForEmptyHeader() {
        XCTAssertNil(PrintEstimate.decodeFromHeader(nil))
        XCTAssertNil(PrintEstimate.decodeFromHeader(""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimateHeaderDecodingTests
```

Expected: build failure ("type 'PrintEstimate' has no member 'decodeFromHeader'").

- [ ] **Step 3: Add `decodeFromHeader` static helper**

In `BambuGateway/Models/PrintEstimate.swift`, append:

```swift
extension PrintEstimate {
    /// Decode a `PrintEstimate` from a base64-encoded JSON HTTP header value.
    /// Returns `nil` if the header is missing, not valid base64, or doesn't decode as a `PrintEstimate`.
    static func decodeFromHeader(_ value: String?) -> PrintEstimate? {
        guard let value, !value.isEmpty else { return nil }
        guard let data = Data(base64Encoded: value) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(PrintEstimate.self, from: data)
    }
}
```

- [ ] **Step 4: Run header tests to verify they pass**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimateHeaderDecodingTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Extend `PreviewResult`**

In `BambuGateway/Models/GatewayModels.swift`, replace the `PreviewResult` struct (around line 313):

```swift
struct PreviewResult {
    let threeMFData: Data
    let previewId: String
    let fileName: String
    let estimate: PrintEstimate?
}
```

- [ ] **Step 6: Read the header in `fetchPrintPreview`**

In `BambuGateway/Networking/GatewayClient.swift`, replace the tail of `fetchPrintPreview` (the part starting at the `guard let httpResponse` block, around line 133–141):

```swift
        guard let httpResponse = response as? HTTPURLResponse,
              let previewId = httpResponse.value(forHTTPHeaderField: "X-Preview-Id"),
              !previewId.isEmpty else {
            throw GatewayClientError.serverError("Server did not return a preview ID.")
        }

        let fileName = parseContentDispositionFilename(httpResponse) ?? submission.file.fileName
        let estimateHeader = httpResponse.value(forHTTPHeaderField: "X-Print-Estimate")
        let estimate = PrintEstimate.decodeFromHeader(estimateHeader)

        return PreviewResult(threeMFData: data, previewId: previewId, fileName: fileName, estimate: estimate)
```

- [ ] **Step 7: Compile-check the whole module**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: "BUILD SUCCEEDED".

- [ ] **Step 8: Run the full new-test suite to verify everything still passes**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimateDecodingTests -only-testing:BambuGatewayTests/PrintResponseEstimateTests -only-testing:BambuGatewayTests/PrintEstimateHeaderDecodingTests
```

Expected: 9 tests pass.

- [ ] **Step 9: Commit**

```
git add BambuGateway/Models/PrintEstimate.swift BambuGateway/Models/GatewayModels.swift BambuGateway/Networking/GatewayClient.swift BambuGatewayTests/PrintEstimateDecodingTests.swift
git commit -m "Decode print estimate from preview header"
```

---

### Task 4: Build value formatters with tests

**Files:**
- Create: `BambuGateway/Views/PrintEstimateFormatters.swift`
- Test: `BambuGatewayTests/PrintEstimationFormattingTests.swift`

The formatters live alongside the card view because they are presentation-only concerns.

- [ ] **Step 1: Write the failing tests**

Create `BambuGatewayTests/PrintEstimationFormattingTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class PrintEstimationFormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")

    func test_formatsLengthInMeters() {
        XCTAssertEqual(PrintEstimateFormatters.formatLength(millimeters: 9280, locale: enUS), "9.28 m")
        XCTAssertEqual(PrintEstimateFormatters.formatLength(millimeters: 0, locale: enUS), "0.00 m")
    }

    func test_formatsLengthWithLocalizedDecimal() {
        let ptBR = Locale(identifier: "pt_BR")
        // pt_BR uses comma as decimal separator
        XCTAssertEqual(PrintEstimateFormatters.formatLength(millimeters: 9280, locale: ptBR), "9,28 m")
    }

    func test_formatsLengthReturnsNilForNil() {
        XCTAssertNil(PrintEstimateFormatters.formatLength(millimeters: nil, locale: enUS))
    }

    func test_formatsMass() {
        XCTAssertEqual(PrintEstimateFormatters.formatMass(grams: 29.46, locale: enUS), "29.46 g")
    }

    func test_formatsMassReturnsNilForNil() {
        XCTAssertNil(PrintEstimateFormatters.formatMass(grams: nil, locale: enUS))
    }

    func test_formatsDurationUnderOneMinute() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 45), "45s")
    }

    func test_formatsDurationMinutesAndSeconds() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 356), "5m 56s")
    }

    func test_formatsDurationHoursAndMinutes() {
        // 2h 30m = 9000s — should drop the "0s"
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 9000), "2h 30m")
    }

    func test_formatsDurationZero() {
        XCTAssertEqual(PrintEstimateFormatters.formatDuration(seconds: 0), "0s")
    }

    func test_formatsDurationReturnsNilForNil() {
        XCTAssertNil(PrintEstimateFormatters.formatDuration(seconds: nil))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimationFormattingTests
```

Expected: build failure ("cannot find 'PrintEstimateFormatters' in scope").

- [ ] **Step 3: Implement the formatters**

Create `BambuGateway/Views/PrintEstimateFormatters.swift`:

```swift
import Foundation

enum PrintEstimateFormatters {
    static func formatLength(millimeters: Double?, locale: Locale = .current) -> String? {
        guard let millimeters else { return nil }
        let measurement = Measurement(value: millimeters, unit: UnitLength.millimeters)
            .converted(to: .meters)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let number = formatter.string(from: NSNumber(value: measurement.value)) else { return nil }
        return "\(number) m"
    }

    static func formatMass(grams: Double?, locale: Locale = .current) -> String? {
        guard let grams else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let number = formatter.string(from: NSNumber(value: grams)) else { return nil }
        return "\(number) g"
    }

    static func formatDuration(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        if seconds == 0 { return "0s" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            // Hours present: show "Xh Ym", drop minutes only if zero
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        return "\(secs)s"
    }
}
```

- [ ] **Step 4: Regenerate the Xcode project**

```
xcodegen generate
```

- [ ] **Step 5: Run tests to verify they pass**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/PrintEstimationFormattingTests
```

Expected: 10 tests pass.

- [ ] **Step 6: Commit**

```
git add BambuGateway/Views/PrintEstimateFormatters.swift BambuGatewayTests/PrintEstimationFormattingTests.swift BambuGateway.xcodeproj
git commit -m "Add print estimate value formatters"
```

---

### Task 5: Build the `PrintEstimationCard` view

**Files:**
- Create: `BambuGateway/Views/PrintEstimationCard.swift`

This task has no XCTest coverage — SwiftUI views are validated visually via `#Preview` in Xcode and via the manual verification step in Task 8. The formatters and model are already test-covered.

- [ ] **Step 1: Create the card view file**

Create `BambuGateway/Views/PrintEstimationCard.swift`:

```swift
import SwiftUI

struct PrintEstimationCard: View {
    let estimate: PrintEstimate?
    /// When `true`, renders the card in a redacted placeholder state regardless of `estimate`.
    let isLoading: Bool

    init(estimate: PrintEstimate?, isLoading: Bool = false) {
        self.estimate = estimate
        self.isLoading = isLoading
    }

    var body: some View {
        if isLoading {
            cardBody(estimate: PrintEstimate.placeholder)
                .redacted(reason: .placeholder)
        } else if let estimate, !estimate.isEmpty {
            cardBody(estimate: estimate)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func cardBody(estimate: PrintEstimate) -> some View {
        let showFilament = estimate.totalFilamentMillimeters != nil
            || estimate.totalFilamentGrams != nil
            || estimate.modelFilamentMillimeters != nil
            || estimate.modelFilamentGrams != nil
        let showTime = estimate.prepareSeconds != nil
            || estimate.modelPrintSeconds != nil
            || estimate.totalSeconds != nil

        VStack(alignment: .leading, spacing: 12) {
            if showFilament {
                VStack(spacing: 8) {
                    FilamentRow(
                        icon: "scribble.variable",
                        label: "Total Filament",
                        millimeters: estimate.totalFilamentMillimeters,
                        grams: estimate.totalFilamentGrams
                    )
                    FilamentRow(
                        icon: "cube",
                        label: "Model Filament",
                        millimeters: estimate.modelFilamentMillimeters,
                        grams: estimate.modelFilamentGrams
                    )
                }
            }
            if showFilament && showTime {
                Divider()
            }
            if showTime {
                VStack(spacing: 8) {
                    TimeRow(
                        icon: "wrench.and.screwdriver",
                        label: "Prepare",
                        seconds: estimate.prepareSeconds,
                        emphasized: false
                    )
                    TimeRow(
                        icon: "printer.fill",
                        label: "Printing",
                        seconds: estimate.modelPrintSeconds,
                        emphasized: false
                    )
                    TimeRow(
                        icon: "clock",
                        label: "Total",
                        seconds: estimate.totalSeconds,
                        emphasized: true
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FilamentRow: View {
    let icon: String
    let label: String
    let millimeters: Double?
    let grams: Double?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(PrintEstimateFormatters.formatLength(millimeters: millimeters) ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(millimeters == nil ? .tertiary : .primary)
                .frame(minWidth: 80, alignment: .trailing)
            Text(PrintEstimateFormatters.formatMass(grams: grams) ?? "—")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(grams == nil ? .tertiary : .primary)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TimeRow: View {
    let icon: String
    let label: String
    let seconds: Int?
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasized ? .primary : .secondary)
            Spacer(minLength: 8)
            Text(PrintEstimateFormatters.formatDuration(seconds: seconds) ?? "—")
                .font(emphasized
                      ? .subheadline.weight(.semibold).monospacedDigit()
                      : .subheadline.monospacedDigit())
                .foregroundStyle(seconds == nil ? .tertiary : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension PrintEstimate {
    /// Static placeholder used by `.redacted` so all rows render with realistic-width values.
    static let placeholder = PrintEstimate(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: 29.46,
        modelFilamentMillimeters: 9120,
        modelFilamentGrams: 28.96,
        prepareSeconds: 356,
        modelPrintSeconds: 9000,
        totalSeconds: 9356
    )
}

#Preview("Full data") {
    PrintEstimationCard(estimate: .init(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: 29.46,
        modelFilamentMillimeters: 9120,
        modelFilamentGrams: 28.96,
        prepareSeconds: 356,
        modelPrintSeconds: 9000,
        totalSeconds: 9356
    ))
    .padding()
}

#Preview("Partial data") {
    PrintEstimationCard(estimate: .init(
        totalFilamentMillimeters: 9280,
        totalFilamentGrams: nil,
        modelFilamentMillimeters: nil,
        modelFilamentGrams: nil,
        prepareSeconds: nil,
        modelPrintSeconds: nil,
        totalSeconds: 9356
    ))
    .padding()
}

#Preview("Loading") {
    PrintEstimationCard(estimate: nil, isLoading: true)
        .padding()
}

#Preview("Empty (renders nothing)") {
    PrintEstimationCard(estimate: nil)
        .padding()
        .background(Color.red.opacity(0.1)) // visible only if EmptyView leaks padding
}
```

- [ ] **Step 2: Regenerate the Xcode project**

```
xcodegen generate
```

- [ ] **Step 3: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: "BUILD SUCCEEDED".

- [ ] **Step 4: Commit**

```
git add BambuGateway/Views/PrintEstimationCard.swift BambuGateway.xcodeproj
git commit -m "Add reusable PrintEstimationCard view"
```

---

### Task 6: Wire `AppViewModel` to capture and expose estimates

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift` (multiple regions)

- [ ] **Step 1: Add the four published properties**

In `BambuGateway/App/AppViewModel.swift`, after line 60 (`@Published var currentPreviewId: String?`), add:

```swift
    @Published var previewEstimate: PrintEstimate?
    @Published var lastPrintEstimate: PrintEstimate?
    @Published var lastPrintPrinterName: String?
    @Published var showPrintSuccessModal: Bool = false
```

- [ ] **Step 2: Capture preview estimate in `submitPreview`**

In `submitPreview()` (around line 349–403), there are two branches: pre-sliced and slicing-via-API. Update the API-slicing branch to also set `previewEstimate`. Replace lines 380–399 (the `else` branch starting with `// Needs slicing`) with:

```swift
            } else {
                // Needs slicing — call the preview API
                guard let submission = buildSubmission() else { return }
                let previewResult = try await gatewayClient().fetchPrintPreview(submission)

                let threeMFData = previewResult.threeMFData
                let scene = try await Task.detached {
                    let reader = ThreeMFReader()
                    let extracted = try reader.extractGCode(
                        from: threeMFData,
                        preferredPlateId: preferredPlateId
                    )
                    let parser = GCodeParser()
                    let model = try parser.parse(extracted.content)
                    return PrintSceneBuilder().buildScene(from: model)
                }.value

                previewScene = scene
                currentPreviewId = previewResult.previewId
                previewEstimate = previewResult.estimate
                isShowingPreview = true
                setMessage("", .info)
            }
```

(Only one line is added: `previewEstimate = previewResult.estimate`. The pre-sliced branch leaves `previewEstimate` as `nil`, which causes the card to hide — that's the intended behavior since we have no estimate for locally-extracted G-code.)

- [ ] **Step 3: Clear preview estimate on dismiss**

Replace `dismissPreview()` (around line 511–515):

```swift
    private func dismissPreview() {
        isShowingPreview = false
        previewScene = nil
        currentPreviewId = nil
        previewEstimate = nil
    }
```

- [ ] **Step 4: Capture direct-print estimate and present success modal**

In `submitPrint()` (around line 334–347), replace the body with:

```swift
    func submitPrint() async {
        guard let submission = buildSubmission() else { return }
        let printContext = printContext(for: submission)

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let response = try await gatewayClient().submitPrint(submission)
            lastPrintEstimate = response.estimate
            lastPrintPrinterName = printerName(for: response.printerId.isEmpty ? printContext.printerId : response.printerId)
            showPrintSuccessModal = true
            handlePrintResponse(response, startedContext: printContext)
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }
```

(The success modal is shown for the direct-print path only. `confirmPreviewPrint` already dismisses the preview modal and shows the inline success message — per the spec, that path doesn't get the success sheet, since the user already saw the estimate in the preview modal.)

- [ ] **Step 5: Add a function to dismiss the success modal**

After `cancelPreview()` (around line 433), add:

```swift
    func dismissPrintSuccessModal() {
        showPrintSuccessModal = false
        lastPrintEstimate = nil
        lastPrintPrinterName = nil
    }
```

- [ ] **Step 6: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: "BUILD SUCCEEDED".

- [ ] **Step 7: Run all existing tests to verify nothing regressed**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'
```

Expected: all existing + new tests pass.

- [ ] **Step 8: Commit**

```
git add BambuGateway/App/AppViewModel.swift
git commit -m "Capture print estimates in AppViewModel"
```

---

### Task 7: Pin the card in `GCodePreviewModal`

**Files:**
- Modify: `BambuGateway/Views/GCodePreviewModal.swift`

- [ ] **Step 1: Replace the body**

Replace the entire contents of `BambuGateway/Views/GCodePreviewModal.swift`:

```swift
import GCodePreview
import SwiftUI

struct GCodePreviewModal: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PrintEstimationCard(
                    estimate: viewModel.previewEstimate,
                    isLoading: viewModel.isLoadingPreview && viewModel.previewEstimate == nil
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ZStack {
                    Color(uiColor: .systemBackground)

                    if let scene = viewModel.previewScene {
                        GCodePreviewView(scene: scene)
                    } else {
                        ProgressView("Preparing preview...")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("G-code Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelPreview()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.confirmPreviewPrint()
                        }
                    } label: {
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("Print")
                        }
                    }
                    .disabled(viewModel.previewScene == nil || viewModel.isSubmitting)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: "BUILD SUCCEEDED".

- [ ] **Step 3: Commit**

```
git add BambuGateway/Views/GCodePreviewModal.swift
git commit -m "Show estimation card in G-code preview modal"
```

---

### Task 8: Build `PrintSuccessModal` and present it from `PrintTab`

**Files:**
- Create: `BambuGateway/Views/PrintSuccessModal.swift`
- Modify: `BambuGateway/Views/PrintTab.swift`

- [ ] **Step 1: Create the success modal**

Create `BambuGateway/Views/PrintSuccessModal.swift`:

```swift
import SwiftUI

struct PrintSuccessModal: View {
    let printerName: String?
    let estimate: PrintEstimate?
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(.green)
                        .padding(.top, 24)

                    Text(titleText)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    if let estimate, !estimate.isEmpty {
                        PrintEstimationCard(estimate: estimate)
                            .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onDone) {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var titleText: String {
        if let printerName, !printerName.isEmpty {
            return "Print sent to \(printerName)"
        }
        return "Print sent"
    }
}

#Preview("With estimate") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PrintSuccessModal(
            printerName: "P1S",
            estimate: .init(
                totalFilamentMillimeters: 9280,
                totalFilamentGrams: 29.46,
                modelFilamentMillimeters: 9120,
                modelFilamentGrams: 28.96,
                prepareSeconds: 356,
                modelPrintSeconds: 9000,
                totalSeconds: 9356
            ),
            onDone: {}
        )
    }
}

#Preview("Without estimate") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PrintSuccessModal(printerName: "P1S", estimate: nil, onDone: {})
    }
}
```

- [ ] **Step 2: Present from `PrintTab`**

In `BambuGateway/Views/PrintTab.swift`, locate the top-level body of the view (search for the outermost `.sheet(` modifiers or the closing of the main `VStack`/`Form`). Add a new sheet modifier alongside any existing ones — find an existing top-level modifier such as `.sheet(isPresented: $viewModel.isShowingPreview)` and append, in the same modifier chain:

```swift
.sheet(isPresented: $viewModel.showPrintSuccessModal) {
    PrintSuccessModal(
        printerName: viewModel.lastPrintPrinterName,
        estimate: viewModel.lastPrintEstimate,
        onDone: { viewModel.dismissPrintSuccessModal() }
    )
}
```

If you can't immediately find the right insertion point, search for `isShowingPreview` in `PrintTab.swift` — the new sheet modifier sits adjacent to that one in the modifier chain.

- [ ] **Step 3: Regenerate the Xcode project**

```
xcodegen generate
```

- [ ] **Step 4: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: "BUILD SUCCEEDED".

- [ ] **Step 5: Run full test suite**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```
git add BambuGateway/Views/PrintSuccessModal.swift BambuGateway/Views/PrintTab.swift BambuGateway.xcodeproj
git commit -m "Show print success modal with estimation card"
```

---

### Task 9: Manual verification on simulator

This task has no automated tests. The user runs the app and confirms behavior end-to-end. Per `CLAUDE.md`, run the app on a different simulator than the one used for unit tests.

- [ ] **Step 1: Boot the run simulator**

```
xcrun simctl boot "iPhone 16 Pro" || true
```

(If a different simulator is already booted, use that one — `CLAUDE.md` says "use the booted simulator for running, except iPhone 16 18.6".)

- [ ] **Step 2: Build and install**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -derivedDataPath build install
```

(Or use the project's `ios-deploy` skill / Xcode UI if more convenient.)

- [ ] **Step 3: Verify the preview path**

1. Import a 3MF that requires slicing.
2. Tap **Preview**.
3. Expected: while slicing, the card area shows a redacted skeleton above the 3D scene.
4. When slicing completes: card shows real values; rotating the model does not move the card.
5. If the gateway does NOT yet emit `X-Print-Estimate`: the card disappears and the 3D scene fills the space (no broken layout, no crash).

- [ ] **Step 4: Verify the direct-print path**

1. Tap **Print** (no preview).
2. Expected: after submission completes, a sheet rises from the bottom (medium detent) with a green checkmark, "Print sent to {name}", the estimation card, and a Done button.
3. Tap Done — sheet dismisses, no residual state.
4. If the gateway response has no `estimate`: sheet still appears with checkmark + title + Done, no card.

- [ ] **Step 5: Verify dark mode and Dynamic Type**

1. Toggle the simulator into Dark Mode (Cmd-Shift-A in iOS Simulator menu, or settings → Dark Appearance).
2. Open both modals. Confirm: card material adapts, text remains readable, no hardcoded colors leak.
3. Set Dynamic Type to the largest accessibility size in Simulator Settings → Accessibility → Display & Text Size → Larger Text. Open the modals. Confirm rows wrap rather than truncate.

- [ ] **Step 6: Final commit (if any tweaks were needed during manual verification)**

If nothing needed changing, skip. Otherwise:

```
git add -A
git commit -m "Polish print estimation card based on manual review"
```

---

## Self-review notes

Spec coverage check (each spec section → task that implements it):

| Spec section | Task |
|---|---|
| `PrintEstimate` model | Task 1 |
| `PrintResponse.estimate` field | Task 2 |
| `PreviewResult.estimate` + `X-Print-Estimate` header | Task 3 |
| Value formatters (length, mass, duration) | Task 4 |
| `PrintEstimationCard` (visual treatment, redacted state, missing-data hiding) | Task 5 |
| AppViewModel published properties + flow wiring | Task 6 |
| Card pinned in `GCodePreviewModal` | Task 7 |
| `PrintSuccessModal` + `PrintTab` `.sheet` presentation | Task 8 |
| Accessibility (combined VoiceOver, Dynamic Type) | Task 5 (in component) + Task 9 (manual verification) |
| Dark mode | Task 5 (uses `.regularMaterial` and semantic colors throughout) + Task 9 |
| Empty-state behavior on both surfaces | Task 5 (card hides when empty) + Task 8 (modal still works without card) |

No placeholders. No "TBD". Type names (`PrintEstimate`, `PrintEstimateFormatters`, `PrintEstimationCard`, `PrintSuccessModal`) are consistent across tasks.
