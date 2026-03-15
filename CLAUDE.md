# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

Project uses XcodeGen — regenerate the Xcode project after editing `project.yml`:
```
xcodegen generate
```

Build the app (no signing, for CI/validation):
```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Build Share Extension only:
```
xcodebuild -project BambuGateway.xcodeproj -scheme ShareExtension -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

No test target exists yet. When adding one, name it `BambuGatewayTests` and use `test_<scenario>_<expectedResult>()` style.

## Architecture

SwiftUI app (iOS 18+, Swift 5) with no external dependencies (pure Foundation/SwiftUI/SceneKit).

### Core data flow

`AppViewModel` is the single `@MainActor` state hub — all views observe it, all async work flows through it. On launch it calls `refreshAll()` which fetches printers, then cascades to load machine/process profiles, filaments, and AMS tray info from the gateway server.

The app does NOT talk to Bambu printers directly. It communicates with a **gateway server** (`GatewayClient`) that proxies printer commands, handles slicing, and manages profiles. The gateway URL is user-configurable via `AppSettingsStore` (UserDefaults-backed).

### Print workflow

1. User imports a `.3mf` file (via Files picker, MakerWorld browser, or Share Extension deep link)
2. File is uploaded to gateway's `/api/parse-3mf` → returns project metadata and whether it's pre-sliced
3. User configures filament-to-AMS-tray mappings, machine/process profiles, plate type
4. Either "Preview" (sends to `/api/print-preview`, receives sliced G-code, renders 3D scene) or "Print" (sends to `/api/print`)

### GCodeKit pipeline

`ThreeMFReader` → `GCodeParser` → `PrintSceneBuilder` → `GCodePreviewView`

- **ThreeMFReader**: Raw ZIP parsing (no Foundation Archive API) to extract G-code from 3MF archives. Scores candidate files by path patterns to pick the best one. Handles deflate via zlib.
- **GCodeParser**: Converts G-code text into `PrintModel` (list of `Segment` structs). Handles G0/G1/G2/G3, arc linearization, absolute/relative modes, move-type classification from comments, layer detection, retraction tracking.
- **PrintSceneBuilder**: Converts `PrintModel` into `SCNScene` with ribbon geometry (5 quads per segment), build plate, isometric camera, and 3-point lighting. Uses pre-allocated arrays for performance.
- **GCodePreviewView**: UIKit/AppKit `SCNView` wrapper with orbit camera.

Heavy work (3MF reading, G-code parsing, scene building) uses `Task.detached` to stay off the main actor.

### Share Extension

Receives URLs from iOS Share Sheet, converts to `bambugateway://open?url=...` deep link, and opens the main app. No shared container or direct data passing.

### Gateway API endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/printers` | GET | List printers with status/temps/job |
| `/api/ams` | GET | AMS tray info and matched filaments |
| `/api/slicer/machines` | GET | Machine profiles |
| `/api/slicer/processes` | GET | Process profiles (optional `?machine=`) |
| `/api/slicer/filaments` | GET | Filament types (optional `?machine=`) |
| `/api/slicer/plate-types` | GET | Build plate options |
| `/api/parse-3mf` | POST | Upload 3MF, get metadata |
| `/api/filament-matches` | POST | Suggest AMS slot assignments |
| `/api/print-preview` | POST | Slice and return preview (600s timeout) |
| `/api/print` | POST | Submit print job |

## Coding Conventions

- 4-space indentation, no tabs.
- Types/protocols: `UpperCamelCase`; properties/functions: `lowerCamelCase`.
- One primary type per file, organized by feature folder.
- `async/await` throughout — no completion handlers.

## Configuration

- `project.yml` is the source of truth for Xcode project generation.
- `Configuration/Base.xcconfig` holds bundle IDs. Local signing overrides go in `LocalSigning.xcconfig` (not committed).

## Commit & PR Guidelines

- Short, imperative commit summaries. Keep commits scoped to one concern.
- PRs: describe what/why, validation steps, screenshots for UI changes.
- Do not commit `xcuserdata` or workspace UI state.
