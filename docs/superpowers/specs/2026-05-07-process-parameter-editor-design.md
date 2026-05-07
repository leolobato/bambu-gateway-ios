# Process Parameter Editor — Design

Status: design (v1)
Branch: `feat/process-parameter-editor`
Date: 2026-05-07
Companion API doc: `../../../../orcaslicer-cli/docs/process-parameter-editor-api.md`

## Goal

Let the user inspect and tweak OrcaSlicer process parameters before slicing a 3MF, directly from the iOS app. Two surfaces:

- A **Modified** card on the main print screen that shows what the project author customized away from the system process preset, with inline editing for keys in the server-side allowlist and read-only display for the rest.
- An **All** view (full-screen cover) that exposes the full server-curated process-parameter catalogue, organized into the same Quality / Strength / Speed / Support / Multimaterial / Others pages OrcaSlicer's GUI uses, for power-user tweaks.

Both views feed the same per-3MF override map, which is sent to the gateway's slice endpoints as `process_overrides: dict[str, str]`. The feature is process-domain only in v1; filament and machine editors are out of scope.

## Non-goals (v1)

- Persistence of overrides across files or app restarts. State is per-3MF and in-memory only.
- Mode filtering (`simple` / `advanced` / `develop`). Show every option the layout returns; the server-side allowlist is the gate.
- Cross-field validation or conditional hiding (e.g. `support_threshold_angle` hidden when `enable_support=false`, or `layer_height ≤ 0.75 × nozzle_diameter`). The slicer's slice-time validators are the backstop.
- Filament / machine editors.
- Undo/redo stack — per-row Revert plus "Reset all" are sufficient.
- Vector / point editors. Vector-typed options render read-only in v1; the v1 allowlist is scalar.
- Surfacing API `version` or `allowlist_revision` in the UI.
- Background prefetch of the option catalogue on app launch (lazy on first view).

## Architecture

Approach: long-lived option-metadata cache as a dedicated service, per-3MF override state on `AppViewModel` (preserving the existing single-hub pattern).

```
BambuGateway/
  Models/
    ProcessParameter.swift              ← NEW: ProcessOption, ProcessOptionType,
                                              ProcessOptionsCatalogue, ProcessLayout,
                                              ProcessPage, ProcessOptgroup,
                                              ProcessModifications, ProcessOverrideApplied
    GatewayModels.swift                 ← extend ThreeMFInfo with processModifications
  Networking/
    GatewayClient.swift                 ← +fetchProcessOptions()
                                          +fetchProcessLayout()
                                          +fetchProcessProfile(settingId:)
                                          +PrintSubmission.processOverrides
                                          +response models gain processOverridesApplied
  Data/
    ProcessOptionsStore.swift           ← NEW: @MainActor ObservableObject;
                                              owns catalogue + layout + profile cache;
                                              version / allowlist_revision invalidation;
                                              in-flight Task coalescing; 503 retry-once
  App/
    AppViewModel.swift                  ← +processOverrides: [String:String]
                                          +processBaseline: [String:String]
                                          +overrides + baseline cleared on file change
                                          +baseline re-resolved on process-profile swap
                                          +buildSubmission() includes overrides
                                          +slice-response surfacing of dropped overrides
  Views/
    PrintTab.swift                      ← embed ProcessParametersCard between
                                              slicingSettingsSection and filamentsSection
                                              (only when viewModel.needsSlicing)
    ProcessParameters/                  ← NEW folder
      ProcessParametersCard.swift       ← Modified-view card on PrintTab
      ProcessAllSettingsView.swift      ← full-screen cover, top-level page list + search
      ProcessPageDetailView.swift       ← drilled-in page (sectioned List of optgroups)
      ProcessOptionRow.swift            ← shared row renderer
      ProcessOptionEditor.swift         ← per-type editor sheet
```

`ProcessOptionsStore` lifetime is the app session. `processOverrides` and `processBaseline` lifetime is the currently-loaded 3MF.

## Data model

```swift
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
    let mode: String           // "simple" | "advanced" | "develop"
    let guiType: String        // "" | "color" | "slider" | "i_enum_open" | "f_enum_open" | "select_open" | "legend" | "one_string"
    let nullable: Bool
    let readonly: Bool
}

enum ProcessOptionType: String, Decodable {
    case bool = "coBool", float = "coFloat", floats = "coFloats",
         int = "coInt", ints = "coInts",
         string = "coString", strings = "coStrings",
         percent = "coPercent", percents = "coPercents",
         floatOrPercent = "coFloatOrPercent",
         floatsOrPercents = "coFloatsOrPercents",
         point = "coPoint", points = "coPoints", point3 = "coPoint3",
         bools = "coBools", `enum` = "coEnum", none = "coNone"
}

struct ProcessOptionsCatalogue: Decodable {
    let version: String
    let options: [String: ProcessOption]
}

struct ProcessLayout: Decodable {
    let version: String
    let allowlistRevision: String
    let pages: [ProcessPage]
}

struct ProcessPage: Decodable, Hashable {
    let label: String
    let optgroups: [ProcessOptgroup]
}

struct ProcessOptgroup: Decodable, Hashable {
    let label: String
    let options: [String]   // option keys; metadata via the catalogue
}

struct ProcessModifications: Decodable {
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

Existing types extended:

```swift
// GatewayModels.swift
struct ThreeMFInfo: Decodable {
    // ...existing fields...
    let processModifications: ProcessModifications?   // optional — older gateway returns nil
}

// GatewayClient.swift
struct PrintSubmission: Codable {
    // ...existing fields...
    var processOverrides: [String: String]?           // nil → form field omitted
}

// PreviewResult / PrintResponse / SliceJob — whichever surfaces settings_transfer
// gains: optional processOverridesApplied: [ProcessOverrideApplied]
```

All option values — defaults, min/max, current values, edits — round-trip as `String` end-to-end. Numeric parsing happens only inside the per-type editor (clamp, validate). This matches the API contract: every value in `project_settings.config` is libslic3r-stringified, including booleans (`"1"` / `"0"`), percents (`"50%"`), floats (`"0.16"`), and enums (`"aligned"`).

## UI surfaces (structural skeleton)

Visual treatment is delegated to the `ui-ux-pro-max` skill in a follow-up pass. Below is structure only.

### ProcessParametersCard (in `PrintTab`)

- Sits between `slicingSettingsSection` and `filamentsSection`. Rendered when `viewModel.needsSlicing`.
- Header row: title "Process settings", trailing badge ("3 modified" / "—"), "Show all" affordance.
- Body lists rows for each key in `processModifications.modifiedKeys`, in API order. Each row uses `ProcessOptionRow`:
  - Label (catalogue), unit suffix, current value.
  - Status indicator: 3MF-modified vs user-edited (visual TBD).
  - Lock indicator if the key is not allowlisted in the layout.
  - Tap → `ProcessOptionEditor` (read-only path if locked).
- Empty state: short copy "No customizations from default profile" plus the "Show all settings" entry.

### ProcessAllSettingsView (full-screen cover)

- `NavigationStack` root.
- Top level: list of pages from `ProcessLayout.pages`. Each row shows page label, total option count, and a "N edited" badge if any of its options have user overrides.
- Top-of-list search field filters across all options globally; results are flat rows that link straight to the editor.
- Toolbar: leading **Done** (dismiss); trailing **Reset all** (disabled when `processOverrides.isEmpty`).
- Tap a page → push `ProcessPageDetailView`.

### ProcessPageDetailView

- Sectioned `List`. One `Section` per optgroup; section header is the optgroup label.
- Rows are `ProcessOptionRow`. Order matches the layout exactly — no client-side sorting.

### ProcessOptionRow

- Label, sidetext, current effective value, edited/locked indicator. Tap → `ProcessOptionEditor`.

### ProcessOptionEditor (sheet, medium detent)

- Title = option label. Subtitle = tooltip (collapsible).
- Editor widget chosen by `(type, guiType)`:

| `type` | Widget |
|---|---|
| `coBool` | toggle (submits `"1"` / `"0"`) |
| `coInt`, `coInts` | numeric stepper, clamped to `min`/`max` |
| `coFloat`, `coFloats` | decimal field, clamped |
| `coPercent`, `coPercents` | numeric field with `%` suffix; submits `"50%"` |
| `coFloatOrPercent`, `coFloatsOrPercents` | mm/% segmented control + numeric field |
| `coString`, `coStrings` | text field |
| `coEnum` | dropdown built from `enumValues` × `enumLabels` |
| `coPoint`, `coPoints`, `coPoint3`, `coBools`, `coNone` | read-only display in v1 |
| `guiType=color` | colour picker |
| `guiType=slider` | slider, bounded by `min`/`max` |
| `guiType=one_string` | text field even when `type` is a vector |

- Footer: revert-target line ("Default 0.20 mm" or "From file 0.16 mm") plus a **Revert** button that removes the key from `processOverrides`.
- Save button validates + writes `processOverrides[key] = stringifiedValue` and dismisses.

The same row + editor components are shared between the Modified card and the All view.

## Data flow & lifecycle

### ProcessOptionsStore (long-lived)

`@MainActor final class ProcessOptionsStore: ObservableObject`, owned by `AppViewModel`, injected into views.

Published state:
- `catalogue: ProcessOptionsCatalogue?`
- `layout: ProcessLayout?`
- `profileBaselines: [String: [String:String]]` — keyed by `processSettingId`.
- `loadError: ProcessOptionsStoreError?`
- `isLoading: Bool` (derived from in-flight Task presence).

Loading rules:
- Lazy first fetch — kicked off when the Modified card or All view first observes the store.
- Single in-flight `Task` per endpoint; concurrent callers await the same Task.
- `503` with `code=options_not_loaded` / `options_layout_not_loaded` → retry once after a short delay; further failure surfaces via `loadError`.
- Successful response stores the new payload atomically. If `(version, allowlistRevision)` differ from the cached values, the cache is replaced wholesale.
- On any successful layout load, derive an `allowlistedKeys: Set<String>` for O(1) row-rendering checks.

Lifetime: app session. No on-disk persistence in v1.

### Per-3MF state (AppViewModel)

```swift
@Published var processOverrides: [String: String] = [:]
@Published var processBaseline: [String: String] = [:]
```

Lifecycle:
- On 3MF parse success → clear `processOverrides`; resolve `processBaseline` via `ProcessOptionsStore.fetchProfile(processModifications.processSettingId)`.
- On dropping the file or app restart → both cleared.
- On user changing the **process profile** in the slicing-settings picker → `processBaseline` re-resolved for the new profile id; `processOverrides` preserved (user intent stays sticky; redundant overrides are harmless server-side).
- On user tapping **Reset all** in the All view → `processOverrides` cleared.

### Effective value resolution

For any option key `k`:

```
processOverrides[k]                       if user edited it
else processModifications.values[k]       if the 3MF customised it
else processBaseline[k]                   otherwise (system default for the active profile)
else catalogue[k].default                 last resort (no profile resolved yet)
```

The **revert target** is the same chain *minus* `processOverrides`. Reverting a key just removes it from the override dict.

This is implemented as a pure function over `(catalogue, processModifications, processBaseline, processOverrides, key)` so it can be unit tested directly.

## Submit & response handling

### Building the submission

`AppViewModel.buildSubmission()` adds the overrides only when non-empty:

```swift
submission.processOverrides = processOverrides.isEmpty ? nil : processOverrides
```

`PrintSubmission` is currently encoded as multipart form data. Multipart cannot carry a nested dict, so the new field is serialized as a single JSON string field named `process_overrides`, matching the existing pattern for `filament_overrides`. The exact serialization happens in `buildSubmission()` (one focused addition).

### Reading the response

`/api/print-preview`, `/api/print`, and `/api/slice-jobs` all return a `settings_transfer` block. The corresponding response models (`PreviewResult`, `PrintResponse`, `SliceJob`) gain an optional `processOverridesApplied: [ProcessOverrideApplied]`.

User-facing surfacing:
- `applied.count == processOverrides.count` → silent success.
- `applied.count < processOverrides.count` → some overrides were dropped server-side. Compute `dropped = processOverrides.keys − applied.keys` and surface a non-blocking message via the existing `ToastCenter` / `viewModel.message` mechanism. Phrasing TBD by `ui-ux-pro-max`.
- `processOverrides.isEmpty` → don't inspect; nothing to surface.

We do not retry, alert, or block submission on dropped overrides — by API contract these are silent server-side filters (filament-domain, unknown, unparseable). Surfacing is informational only.

## Error states

- `ProcessOptionsStore` fetch failure (network, 5xx, decode) → `loadError` set; Modified card and All view show an inline retry affordance ("Couldn't load process settings — Retry"). The slice/print path keeps working — submitting with no overrides is unaffected.
- `processModifications` missing in the inspect response (older gateway) → Modified card shows the empty state; the "Show all settings" entry stays available as long as the catalogue + layout load.
- Read-only / non-allowlisted modified key → row shows a lock indicator; tapping opens a read-only detail (label, current value, tooltip) with no Save / Revert.

## Edge cases

- **Catalogue missing a key referenced by `modifiedKeys`** → row renders with the raw key as label, treated as read-only, value displayed as-is. Don't crash.
- **Layout references a key the catalogue doesn't have** → skip the row silently. The catalogue is authoritative for metadata.
- **Numeric input outside `min`/`max`** → editor clamps on Save and shows a one-line note. No alert.
- **Stale process profile after a profile swap mid-session** — see lifecycle above; baseline re-resolves, overrides stay.
- **Concurrent in-flight fetches** are coalesced inside the store.
- **App backgrounded mid-fetch** behaves like any other URLSession cancellation; resumed on next access.
- **3MF without `project_settings.config`** → `processModifications = (processSettingId: "", modifiedKeys: [], values: {})`. Modified card shows the empty state; baseline resolution skipped.
- **Allowlisted key with an unsupported v1 type** (vector / point / `coNone`) → render read-only and `os_log` debug a warning so we notice when the allowlist grows.

## Versioning & cache invalidation

- `version` (in catalogue + layout) keys the option metadata. Replaced wholesale on change.
- `allowlistRevision` (in layout only) keys the layout payload. Replaced wholesale on change.
- No persistence of either — in-memory only in v1. Catalogue (~150 KB, ~609 entries) is small enough to refetch on relaunch.

## Testing

Unit tests:
- `ProcessOptionsStore`: catalogue / layout / profile fetch + cache invalidation on `version` / `allowlistRevision` change; in-flight coalescing; 503 retry-once behaviour.
- Effective-value resolution function — table-driven over the four-rung fallback chain.
- `buildSubmission()` — empty dict → field omitted; non-empty → field included verbatim with correct JSON serialization.
- Decoder tests for `ProcessOption`, `ProcessLayout`, `ProcessModifications`, `ProcessOverrideApplied` against fixture JSON taken from the API doc.

UI tests deferred to a follow-up pass once `ui-ux-pro-max` lands the visual treatment.

## Open questions

None blocking the implementation plan. Visual treatment (colour, typography, status iconography, exact copy) is intentionally deferred to `ui-ux-pro-max`.
