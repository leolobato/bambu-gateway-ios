# Print Estimation Summary — Design Spec

**Date:** 2026-04-25
**Status:** Draft, awaiting user review

## Goal

Show the user the slicer's estimate of filament usage and print time before they commit a print, and again as a receipt after a direct print is sent.

## Scope

In scope:
- A reusable `PrintEstimationCard` SwiftUI view.
- Surfacing the card in the existing preview modal (`GCodePreviewModal`).
- A new `PrintSuccessModal` shown after the direct-print path submits successfully, containing the same card.
- Decoding new estimate fields from gateway responses.

Out of scope:
- Cost (intentionally omitted; the reference visual shows it but the user does not want it).
- Per-filament-tray breakdown.
- Live progress / remaining-time updates while printing (that is the live activity's job, not this card).
- Server-side gateway changes — flagged here, but implemented in the gateway repo separately.

## Information shown

The card shows up to five rows in two grouped sections:

**Filament**
- Total Filament — length (m) and weight (g)
- Model Filament — length (m) and weight (g)

**Time**
- Prepare time
- Model printing time
- Total time (visually emphasized)

All values are optional. Missing-value rules are described under "Missing data" below.

## Surfaces

### 1. Preview modal (`GCodePreviewModal`)

The card is pinned at the top of the modal, between the navigation toolbar and the 3D viewport. It does not scroll — it remains visible while the user orbits the model.

States, in order of arrival:
1. **Slicing in flight** (`viewModel.isPreviewLoading == true`): card renders in `.redacted(reason: .placeholder)` form so the row structure and icons remain visible without layout shift when values arrive.
2. **Slicing complete, estimate present**: card renders normally with values.
3. **Slicing complete, estimate absent** (gateway didn't include the header): card is hidden entirely; the 3D viewport expands to fill the space.

### 2. Print success modal (`PrintSuccessModal`, NEW)

Presented as a `.sheet` with `.medium` detent after `submitPrint` completes successfully on the direct-print path. Layout, top to bottom:

1. `checkmark.circle.fill`, large, `.green`
2. Title: "Print sent to {printer.name}"
3. `PrintEstimationCard` (reused 1:1)
4. "Done" button (`.borderedProminent`), bottom-anchored

No auto-dismiss. The sheet is dismissible via swipe-down or the Done button.

### 3. Behavior when no estimate data is available

If every estimate field is `nil`, the card does not render at all. In the success modal, this means the user sees only the success header and Done button — the modal is still useful as a confirmation receipt.

## Component design

### Visual treatment

- Container: `RoundedRectangle(cornerRadius: 16)` filled with `.regularMaterial`.
- Internal padding: 12 pt.
- Outer modal margin: 16 pt.
- Two sections separated by a `Divider()`.

### Row layout

Each row is an `HStack` with three logical columns:

```
[icon + label]                    [primary value]    [secondary value]
```

- Filament rows: primary = length (m), secondary = weight (g).
- Time rows: primary = formatted duration, secondary column empty (the duration spans both columns, right-aligned).
- Numeric columns use `.monospacedDigit()` and right-align so decimal points and units align across rows.

### Typography

| Element | Font | Color |
|---|---|---|
| Row label | `.subheadline` | `.secondary` |
| Row value | `.subheadline.monospacedDigit()` | `.primary` |
| "Total" row label and value | `.subheadline.weight(.semibold)` | `.primary` |
| Section spacing | 8 pt between rows, 12 pt between sections | — |

No explicit card title. The icons and labels are self-explanatory.

### Iconography (SF Symbols)

| Row | Symbol |
|---|---|
| Total Filament | `scribble.variable` |
| Model Filament | `cube` |
| Prepare time | `wrench.and.screwdriver` |
| Model printing time | `printer.fill` |
| Total time | `clock` |

All icons rendered at `.footnote` weight in `.secondary`, in a fixed 16 pt frame so labels align across rows.

### Value formatting

- Length: meters, two decimals, locale-aware decimal separator. Example: `9.28 m`.
- Weight: grams, two decimals, locale-aware. Example: `29.46 g`.
- Duration: short form, no leading zero units. Examples: `5m 56s`, `2h 30m`, `45s`.
- Locale-aware number formatting via `Measurement` + `MeasurementFormatter` for length and mass; `DateComponentsFormatter` (unitsStyle = `.abbreviated`, allowedUnits filtered to the largest two non-zero units) for duration.

### Missing data within a populated card

If the card renders at all (i.e. at least one field is non-nil):
- A nil value within a row renders as an em dash (`—`) in `.tertiary`.
- If all three time fields are nil, the entire time section (including the divider) is hidden.
- If both filament rows are entirely nil, the filament section is hidden.

## Data flow

### New model

```swift
struct PrintEstimate: Decodable, Equatable {
    let totalFilamentMillimeters: Double?
    let totalFilamentGrams: Double?
    let modelFilamentMillimeters: Double?
    let modelFilamentGrams: Double?
    let prepareSeconds: Int?
    let modelPrintSeconds: Int?
    let totalSeconds: Int?
}
```

`PrintEstimate` exposes a computed `isEmpty` for the "render nothing" case.

### Source of estimate data

The gateway is the source of truth. Two endpoints are involved:

**`/api/print` (direct print) — JSON response**

Add an optional `estimate` field to `PrintResponse`:

```swift
struct PrintResponse: Decodable {
    let status: String
    let fileName: String
    let printerId: String
    let wasSliced: Bool
    let settingsTransfer: SettingsTransferInfo?
    let uploadId: String?
    let estimate: PrintEstimate?   // NEW
}
```

**`/api/print-preview` — currently returns sliced 3MF binary plus `X-Preview-Id` header**

This endpoint cannot easily carry a JSON estimate body since the body is binary. Options, in order of preference:

1. **Header-based (recommended):** Gateway adds `X-Print-Estimate` HTTP header containing the `PrintEstimate` JSON, base64-encoded. iOS reads and decodes it. Smallest change; keeps the binary streaming intact.
2. **Multipart response:** Gateway returns `multipart/related` with one part for JSON metadata and one for the 3MF binary. Larger change to client and server.
3. **Client-side parsing:** iOS extracts estimate from the sliced 3MF's `Metadata/slice_info.config` or G-code header comments after receiving it. Requires no gateway change but duplicates parsing logic the gateway already has.

**Recommendation: option 1.** A new `PreviewResult.estimate: PrintEstimate?` field is populated from the header when present, else nil.

### View-model wiring

`AppViewModel` gains:
- `@Published var previewEstimate: PrintEstimate?` — set when preview result arrives, cleared by `cancelPreview()`.
- `@Published var lastPrintEstimate: PrintEstimate?` — set when direct `submitPrint` succeeds, cleared by the success modal's dismiss.
- `@Published var showPrintSuccessModal: Bool` — drives `.sheet` presentation on `PrintTab`.
- `@Published var lastPrintPrinterName: String?` — to render the "Print sent to {name}" title.

## File changes

| File | Change |
|---|---|
| `BambuGateway/Models/GatewayModels.swift` | Add `PrintEstimate`. Add `estimate` field to `PrintResponse`. |
| `BambuGateway/Networking/GatewayClient.swift` | In `fetchPrintPreview`, read `X-Print-Estimate` header, base64-decode, JSON-decode into `PrintEstimate?`. Add to `PreviewResult`. |
| `BambuGateway/Models/PreviewResult.swift` (or wherever it lives) | Add `estimate: PrintEstimate?` field. |
| `BambuGateway/App/AppViewModel.swift` | Add the four published properties above. Wire `submitPreview` to capture estimate. Wire `submitPrint` to capture estimate, set printer name, present success modal. |
| `BambuGateway/Views/PrintEstimationCard.swift` (NEW) | The reusable card component, plus formatting helpers. |
| `BambuGateway/Views/PrintSuccessModal.swift` (NEW) | Sheet wrapper with success icon, title, card, Done button. |
| `BambuGateway/Views/GCodePreviewModal.swift` | Insert `PrintEstimationCard` pinned above `GCodePreviewView`. Adjust layout so the 3D scene fills the remaining space. |
| `BambuGateway/Views/PrintTab.swift` | Present `PrintSuccessModal` as `.sheet` driven by `viewModel.showPrintSuccessModal`. |

## Testing

- Unit tests for `PrintEstimate` decoding from JSON (all-fields, all-nil, partial).
- Unit tests for the duration formatter: `45s` (under a minute), `5m 56s`, `2h 30m`, `0s` (returns `0s`, not nil).
- Unit tests for length and mass formatting with `en_US` and a comma-decimal locale (e.g. `pt_BR`).
- Snapshot or preview tests for `PrintEstimationCard` in: full data, partial data (one row missing), all-time-nil (time section hidden), light and dark mode, redacted/loading state.
- Manual test: direct-print path shows success modal with card; preview path shows card pinned above 3D scene; both behave correctly when gateway omits the estimate header / field.

## Accessibility

- Each row has an `accessibilityElement(children: .combine)` so VoiceOver reads "Total filament, 9.28 meters, 29.46 grams" as one element.
- Time rows: "Total time, 2 hours 36 minutes."
- Card supports Dynamic Type up to `.accessibility3` without truncation; values wrap to a second line below the label at the largest sizes.
- `prefers-reduced-motion`: the success modal uses the system sheet animation, which already respects the setting. No additional motion is added.
- Color is not the sole indicator anywhere — every row has a label and an icon.

## Open questions

None at the time of writing. Gateway-side header format (`X-Print-Estimate` as base64 JSON) needs confirmation with the gateway maintainer, but that is tracked separately from this iOS spec.

## Non-goals reiterated

- This spec does not change the live activity, the print queue UI, or the AMS tray UI.
- This spec does not introduce a confirmation dialog on the direct-print path. The success modal is a receipt, not a gate.
