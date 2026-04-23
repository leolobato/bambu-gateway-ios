# Camera Tab — Design

**Status:** Approved
**Date:** 2026-04-23
**Author:** Leonardo Lobato (with Claude)

## Summary

Add a third tab to the iOS app showing live camera feeds and a chamber-light toggle for the currently-selected printer. The tab displays the printer's built-in camera feed and, when configured, an external RTSP camera feed stacked below it. Chamber light can be toggled from the same tab.

A new Swift streaming module is written from scratch in this repo, inspired by the implementation in the sibling `panda-be-free` project but restructured into smaller, testable components. No third-party video dependencies: transport and decode are built on `Network.framework` and `VideoToolbox`.

## Goals

- Watch the printer camera live, from inside the app, without round-tripping through Bambu cloud or the gateway as a stream proxy.
- Support both Bambu printer families in one tab:
  - **A1 / P1** — JPEG frames over TCP on port 6000.
  - **X1 / P2S** — H.264 over RTSPS on port 322.
- Let the user configure an external RTSP camera URL per printer, shown stacked below the printer feed when set.
- Toggle the chamber light from the same tab.

## Non-goals (v1)

- Snapshot / save-frame button.
- Audio (Bambu streams are video-only anyway).
- Picture-in-Picture (iOS system PiP).
- Recording.
- Work-light toggle (print-head LED). API is designed to allow it without a breaking change.
- Multiple external cameras per printer.
- RTSP codecs other than H.264 for the external feed.

## User experience

**Tab bar:** `Dashboard | Print | Camera` (new tab added at index 2, SF Symbol `video`).

**Camera tab layout** (vertical scroll):

1. Printer picker (reused from `PrinterTab`, only shown when >1 printer known).
2. Full-width chamber-light toggle button.
3. Printer camera feed tile (always shown; shows an error state if the gateway reports no camera for this printer).
4. External camera feed tile (only rendered when a per-printer external RTSP URL is set).

**Feed tile:** 16:9 rounded rectangle with a 28pt header row above it (status dot, label, fullscreen icon). Tap the tile to enter fullscreen.

**Fullscreen:** Immersive `fullScreenCover`. Landscape-preferred but rotates. Chrome (close button, label) auto-hides after 3s of no touch and returns on tap. No light toggle in fullscreen.

**Light toggle:** Full-width pill, 56pt tall. States: off / on / loading / unsupported (hidden). Optimistic UI with rollback on error.

**Empty/edge states:**
- No printers known → "Add a printer in Settings"; no feeds, no light button.
- Selected printer has no `camera` field from gateway → printer tile shows "Camera not available for this printer." External tile still renders if configured.
- Selected printer offline → printer tile shows "Printer offline."; don't attempt to connect. External feed still connects independently.
- Tab not visible → all feeds torn down (see Lifecycle).

## Architecture

### State ownership

- `AppViewModel` gains `chamberLightOn: Bool?` (per-selected-printer, sourced from `/api/printers`) and `setChamberLight(_ on: Bool)`, mirroring the existing `pause/resume/cancel/speed` flow (optimistic toggle + refresh).
- Camera feeds are **view-owned**. Each `CameraFeedView` holds a `@StateObject CameraFeedController` that starts on `onAppear`, stops on `onDisappear`. Keeps `AppViewModel` thin and prevents background streaming.
- Printer switch ⇒ view identity changes via `.id(printer.id)`, stopping the old feed and starting a new one.

### Threading

- `NWConnection` + RTP parsing on a background dispatch queue.
- `VTDecompressionSession` callback runs on its own queue and hands `CVPixelBuffer` off to a main-actor frame buffer.
- `CameraFeedController` is `@MainActor`, exposes `@Published var currentFrame: CGImage?` and `@Published var state: CameraFeedState`. Backpressure is latest-frame-wins.

### Lifecycle

- App background or tab switch → tear down feeds.
- Foreground + Camera tab visible → reconnect.
- Failure → auto-retry with exponential backoff (1s, 2s, 4s, cap 8s). Last frame stays on screen, dimmed.
- Manual "Retry" button cancels backoff and reconnects immediately.

## Gateway API contract

### `GET /api/printers` — extended

Add an optional `camera` object per printer:

```json
{
  "id": "...",
  "machineModel": "X1C",
  "online": true,
  "camera": {
    "ip": "192.168.1.42",
    "accessCode": "12345678",
    "transport": "rtsps",
    "chamberLight": {
      "supported": true,
      "on": false
    }
  }
}
```

- `camera` is **optional**. If the gateway can't obtain LAN IP / access code (e.g. cloud-only printer), it omits the field; iOS shows "Camera unavailable for this printer."
- `transport` is an explicit hint with values `"rtsps"` or `"tcp_jpeg"`. iOS treats it as opaque. Unknown values ⇒ "Camera not supported on this printer." This avoids iOS guessing from `machineModel` strings that drift over firmware versions.
- `chamberLight.on` may be `null` when the gateway hasn't yet observed the state.

### `POST /api/printers/{id}/light` — new

Request:
```json
{ "node": "chamber_light", "on": true }
```

- `node` is explicit so adding `"work_light"` later is non-breaking. v1 iOS only sends `"chamber_light"`.
- Response: `204 No Content` on success, `4xx/5xx` with `{ "error": "..." }` on failure.
- Gateway publishes the corresponding `system.ledctrl` MQTT payload and returns when the printer ACKs (or short timeout).

### iOS Swift side

- Extend `PrinterStatus` in `GatewayModels.swift` with `let camera: CameraInfo?`.
- Add `GatewayClient.setLight(printerId:node:on:)`.
- After a successful light toggle, call `refreshAll()` once to confirm.

## Camera streaming module

All new code under `BambuGateway/Services/Camera/`. No third-party dependencies; only `Network`, `VideoToolbox`, `CoreMedia`, `CoreVideo`, `CoreGraphics`.

### Core protocol

```swift
protocol CameraFeed: AnyObject {
    var frames: AsyncStream<CameraFrame> { get }
    var state: AsyncStream<CameraFeedState> { get }
    func start()
    func stop()
}

struct CameraFrame {
    let image: CGImage
    let timestamp: CFAbsoluteTime
}

enum CameraFeedState {
    case idle
    case connecting
    case streaming
    case failed(CameraFeedError)
    case stopped
}

enum CameraFeedError: Error {
    case unreachable
    case authFailed
    case unsupportedCodec
    case streamEnded
    case other(String)
}
```

### File layout

```
BambuGateway/Services/Camera/
  CameraFeed.swift                 // protocol + frame/state/error types
  CameraFeedController.swift       // @MainActor ObservableObject for SwiftUI
  BambuPrinterCameraFeed.swift     // dispatches to TCP or RTSPS by transport hint
  BambuTCPJPEGFeed.swift           // A1/P1 port 6000 JPEG loop
  BambuRTSPSFeed.swift             // X1/P2S port 322 RTSPS + RTP/H.264
  ExternalRTSPFeed.swift           // third-party RTSP URL, H.264 only
  RTSPClient.swift                 // DESCRIBE/SETUP/PLAY, digest auth, interleaved RTP
  H264NALAssembler.swift           // RFC 6184 FU-A / STAP-A depacketization
  H264Decoder.swift                // VTDecompressionSession wrapper
```

### Implementation notes

- **`BambuTCPJPEGFeed`** — ~250 lines. `NWConnection` with TLS, self-signed cert bypass via `sec_protocol_options_set_verify_block`, 80-byte `bblp:<accessCode>` auth packet, then a loop of `[16-byte header][JPEG]`. Decode with `CGImageSourceCreateWithData`.
- **`BambuRTSPSFeed`** — ~200 lines. Composes `RTSPClient` + `H264NALAssembler` + `H264Decoder`. Uses `bblp:<accessCode>` as Digest credentials.
- **`ExternalRTSPFeed`** — ~150 lines. Same composition, URL-provided credentials (Basic or Digest), H.264 only. Any other codec ⇒ `.failed(.unsupportedCodec)` with a human-readable message.
- **`RTSPClient`** — state machine for DESCRIBE → SETUP → PLAY → TEARDOWN. Handles Digest auth, session/CSeq tracking, RTP over TCP interleaved frames (`RTP/AVP/TCP`). Emits `AsyncStream<RTPPacket>`. Codec-agnostic.
- **`H264NALAssembler`** — RFC 6184 FU-A / STAP-A depacketization. Tracks SPS/PPS for `CMVideoFormatDescription` creation. Pure input/output; easy to unit test.
- **`H264Decoder`** — thin `VTDecompressionSession` wrapper. Rebuilds format description on SPS changes.
- **`CameraFeedController`** — bridges `AsyncStream` output to SwiftUI, applies latest-frame-wins backpressure, exposes retry/stop control.

### What's improved over `panda-be-free`

- Split responsibilities: transport (RTSP) / packet assembly (NAL) / decode (VideoToolbox) / presentation (controller) — instead of one 862-line `CameraStreamManager`.
- Protocol-oriented so each piece is independently testable and the two Bambu paths + external path reuse the same decoder/assembler.
- Explicit `transport` hint from the gateway replaces in-app model-family guessing.
- `CGImage` instead of `UIImage` on the decode path; `UIImage` wrapping only at the view boundary.
- Single `CameraFeedError` enum instead of ad-hoc throws / print statements.

## Settings

### `AppSettingsStore` — extend `PerPrinterSelection`

```swift
struct PerPrinterSelection: Codable {
    // ...existing fields...
    var externalCameraURL: String?   // nil or empty = not configured
}
```

Stored in the existing `perPrinter: [String: PerPrinterSelection]` dict. `Codable` default-decodes missing keys to `nil`; no migration.

### `SettingsView` — new "Cameras" section

Below the existing Gateway URL field:

- **Printer picker** defaulting to the selected printer, lets the user configure URLs for any known printer in one place.
- **External RTSP URL** text field: monospaced, autocapitalization off, keyboard `.URL`.
- **Test connection** button: spawns a short-lived `ExternalRTSPFeed`, waits up to 8s for `.streaming` or error, reports inline, tears down. Doesn't decode frames — just validates DESCRIBE/SETUP/PLAY.
- Validation: warn (not block) if scheme isn't `rtsp://` or `rtsps://`.

Gateway URL field is unchanged (still global). External-camera URL is **per-printer**.

### Wiring

- `AppViewModel.externalCameraURL(for printerId:) -> String?` — accessor over the settings store.
- Camera tab reads reactively: when `selectedPrinter.id` changes, external feed re-renders with the new URL (or hides if empty).

## UI components

### `CameraTab`

```
NavigationStack
└── ScrollView
    ├── PrinterPickerRow (reused)
    ├── ChamberLightToggle
    ├── CameraFeedView(.printer)
    └── CameraFeedView(.external)   // conditional on URL
```

16pt vertical between sections, 16pt horizontal padding (matches `PrinterTab`).

### `CameraFeedView`

Header row (28pt): status dot (green/amber/red/gray), label, fullscreen icon (trailing). Tap tile → fullscreen.

Frame area: `Image(decorative: cgImage, scale: 1, orientation: .up)` inside a `GeometryReader` with `.aspectRatio(16/9, contentMode: .fit)`, 12pt rounded corners, black background.

State overlays (centered over frame area):
- `.connecting` → `ProgressView` + "Connecting…"
- `.failed(error)` → `exclamationmark.triangle` + message + "Retry" button.
- `.streaming` without first frame → same as connecting.
- `.streaming` with a frame older than 5s → dim frame to 40% + "Reconnecting…" pill.

### `ChamberLightToggle`

Full-width, 56pt tall. States: Off (`lightbulb`, secondary), On (`lightbulb.fill`, accent), Loading (spinner, disabled), Unsupported (hidden). Optimistic with rollback on error and a transient "Couldn't toggle light" toast.

Disabled when `selectedPrinter == nil` or offline.

### `FullscreenCameraView`

`.fullScreenCover`, black background, frame `.aspectRatio(.fit)`. Landscape-preferred, rotates to portrait. Status bar hidden. Close button top-leading, feed label top-trailing; chrome auto-hides after 3s, returns on tap. No light toggle here.

## Accessibility

- Feed tile: `.accessibilityLabel("Printer camera, streaming")` updated live with state.
- Light toggle: `.accessibilityLabel("Chamber light")` + `.accessibilityValue("On"/"Off")`.
- Fullscreen close: standard SF Symbol, labeled.

## Testing

No test target exists yet (per `CLAUDE.md`). This change introduces `BambuGatewayTests`:

- **Unit tests** for `RTSPClient` (dialog fixtures for DESCRIBE/SETUP/PLAY, Digest auth, 401-reauth) and `H264NALAssembler` (FU-A fragment reassembly, STAP-A splitting, SPS tracking, out-of-order sequence handling).
- **Integration tests** for the feed implementations: skipped in CI by default, runnable against a real printer on the developer's network.
- **Snapshot / UI tests** are out of scope for v1.

## Build / project changes

- New sources added to `project.yml` under existing targets.
- Regenerate `BambuGateway.xcodeproj` via `xcodegen generate` after editing `project.yml`.
- New `BambuGatewayTests` target wired into `project.yml`, following the test-name pattern `test_<scenario>_<expectedResult>()`.

## Open risks

- **Trust boundary.** `accessCode` on `/api/printers` is printer LAN auth — the gateway previously didn't expose it to clients. Any client reachable by the gateway now holds enough to stream the printer's camera independently. Acceptable for the current single-tenant deployment (gateway is on the local network and already fully trusted); if the gateway ever grows multi-user auth, `camera.accessCode` should become per-user-gated or replaced with a short-lived gateway-issued credential.
- RTSPS on port 322 uses a self-signed cert — we bypass cert validation for this connection only. Scope the `sec_protocol_options_set_verify_block` override to the RTSPS feed's `NWConnection`, never globally.
- H.264 decoder behavior varies by device; `VTDecompressionSession` error codes are opaque. Log them, surface as `.other(String)` to the user.
- External RTSP cameras vary wildly. H.264-only for v1 is a deliberate constraint; users with HEVC or MJPEG cameras will see `.unsupportedCodec` and can file an issue.
- Gateway-side changes (printer camera fields on `/api/printers`, light endpoint) must land before this iOS work is useful. iOS can still be built and reviewed against a mocked response.

## Milestones (for the implementation plan that follows)

1. Gateway API changes (out of scope for this repo's plan; tracked separately).
2. iOS: extend `PrinterStatus` + `GatewayClient`, settings storage for external URL.
3. iOS: streaming module scaffolding (protocol, controller, error types).
4. iOS: `RTSPClient` + `H264NALAssembler` + `H264Decoder` with unit tests.
5. iOS: `BambuRTSPSFeed`, `BambuTCPJPEGFeed`, `ExternalRTSPFeed`, `BambuPrinterCameraFeed` dispatcher.
6. iOS: `CameraTab`, `CameraFeedView`, `FullscreenCameraView`, `ChamberLightToggle`.
7. iOS: `SettingsView` "Cameras" section with Test button.
8. Manual validation on a real X1 and A1 printer, plus one external RTSP camera.
