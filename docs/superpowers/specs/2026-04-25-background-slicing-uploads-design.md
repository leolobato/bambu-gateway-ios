# Background Slicing Uploads — Design Spec

**Date:** 2026-04-25
**Status:** Draft, awaiting user review

## Problem

`/api/print-preview` and `/api/print` are long POSTs (gateway timeout: 600s) because the gateway slices the 3MF before responding. They run on `URLSession.shared`, which iOS suspends when the app backgrounds. Result: if the user sends the app to the background mid-slice, the connection dies and the user has to retry.

## Goal

Move the upload/download for these two endpoints to a `URLSessionConfiguration.background` session so the transfer survives app suspension. Keep the public surface of `GatewayClient` unchanged.

## Out of scope

- Real slicing-progress UI (bytes-on-the-wire progress isn't useful — the gateway is computing, not streaming bytes back).
- Surviving full app *termination* with a notification or restored modal. If iOS kills the app and later relaunches it to deliver completion events, we discard the result silently. Re-investing if/when this becomes a real complaint.
- Backgrounding any other endpoint. The remaining gateway calls are short and stay on `URLSession.shared`.
- Multiple concurrent uploads. UI gates to one at a time. The service tolerates concurrent tasks but no UX is added.
- Push notifications or live-activity hooks for slicing.

## Architecture

```
AppDelegate
    │ owns
    ▼
BackgroundTransferService (NEW)                          AppViewModel
    │                                                        │
    ├── one URLSession (background config)                   │
    │   identifier "com.bambugateway.transfer"               │
    │                                                        │
    └── public API:                                          │
        upload(request:fromFile:) async throws               │
            -> (Data, HTTPURLResponse)                       │
        cancelAll()                                          │
        adoptCompletionHandler(_:)                           │
                                                             │
GatewayClient (modified)                                     │
    fetchPrintPreview, submitPrint                           │
    build multipart → write to temp file                     │
    → transferService.upload(...)                            │
    → parse headers, return PreviewResult / PrintResponse    │
    → cleanup temp file                                      │
                                                             │
All other GatewayClient methods unchanged on URLSession.shared
```

The shared `URLSession` for short endpoints (printers, AMS, slicer profiles, parse-3mf, control commands) is **untouched**. Only the two long uploads route through the new service.

## Components

### `BackgroundTransferService`

`@MainActor final class : NSObject, URLSessionDataDelegate, URLSessionTaskDelegate`. Constructed once and owned by `AppDelegate`.

State:

```swift
private struct InFlight {
    var response: HTTPURLResponse?
    var body: Data
    let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
}
private var inFlight: [Int: InFlight] = [:]   // keyed by task.taskIdentifier
private var pendingCompletionHandler: (() -> Void)?
```

Session config:

```swift
let config = URLSessionConfiguration.background(withIdentifier: "com.bambugateway.transfer")
config.isDiscretionary = false
config.sessionSendsLaunchEvents = true
config.timeoutIntervalForRequest = 600   // per-byte stuck-connection cap
config.timeoutIntervalForResource = 60 * 60   // hard ceiling for the whole transfer
URLSession(configuration: config, delegate: self, delegateQueue: .main)
```

The `.main` delegate queue keeps state mutation single-threaded. Delegate methods are `nonisolated` and dispatch to `@MainActor` via `Task { @MainActor in ... }`.

Public API:

```swift
func upload(request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
func cancelAll()
func adoptCompletionHandler(_ handler: @escaping () -> Void)
```

Delegate behavior:

| Callback | Action |
|---|---|
| `urlSession(_:dataTask:didReceive response:)` | Capture `HTTPURLResponse` into `inFlight[id].response`. Allow disposition. |
| `urlSession(_:dataTask:didReceive data:)` | Append to `inFlight[id].body`. |
| `urlSession(_:task:didCompleteWithError:)` | Resume the continuation: throw on error, return `(body, response)` on success. Drop the entry. If no entry exists (relaunched-app orphan), ignore silently. |
| `urlSessionDidFinishEvents(forBackgroundURLSession:)` | Call and clear `pendingCompletionHandler`. |

### `MultipartFormData` extension

Background uploads require a file URL, not in-memory data. Add:

```swift
extension MultipartFormData {
    func writeBody(toTemporaryFileNamed name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString)
            .appendingPathExtension("multipart")
        try body.write(to: url, options: .atomic)
        return url
    }
}
```

The unique-suffix ensures concurrent transfers cannot collide on the same path. Cleanup is the caller's responsibility (`defer { try? FileManager.default.removeItem(at: url) }`).

### `GatewayClient` changes

Add a stored `transferService: BackgroundTransferService` property and accept it on init. `fetchPrintPreview` and `submitPrint` change shape from "build form, call `request(...)`" to:

```swift
form.finalize()
let bodyURL = try form.writeBody(toTemporaryFileNamed: "print-preview")
defer { try? FileManager.default.removeItem(at: bodyURL) }

var request = URLRequest(url: try resolvedURL(path: "/api/print-preview"))
request.httpMethod = "POST"
request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

let (data, response) = try await transferService.upload(request: request, fromFile: bodyURL)
guard response.statusCode == 200 else { throw mapHTTPError(response, data: data) }
// existing X-Preview-Id / X-Print-Estimate / Content-Disposition parsing unchanged
```

A small `mapHTTPError(_:data:)` helper is extracted alongside the existing `request(...)` so foreground and background paths share error mapping. Replaces a duplicated branch.

The existing `request(...)` helper is unchanged. All non-preview/non-print callers continue using it.

### App wiring

`AppDelegate` already exists and conforms to `UIApplicationDelegate`. Two additions:

```swift
let transferService = BackgroundTransferService()

func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    transferService.adoptCompletionHandler(completionHandler)
}
```

`AppViewModel.gatewayClient()` (currently constructs a fresh `GatewayClient` per call) reads the service from `AppDelegate` at construction time. Concretely: `AppViewModel` gains a stored `transferService: BackgroundTransferService` property, set during `init`, and `gatewayClient()` becomes:

```swift
GatewayClient(baseURLString: gatewayBaseURL, transferService: transferService)
```

`AppViewModel.cancelPreview()` calls `transferService.cancelAll()` before resetting UI state. The existing `submitPreview` `catch` block already swallows the resulting `URLError(.cancelled)` cleanly.

## Data flow

### Happy path — preview while app is foreground

1. User taps Preview. `AppViewModel.submitPreview()` runs, sets `isLoadingPreview = true`.
2. `GatewayClient.fetchPrintPreview` builds the multipart form, writes it to a temp file.
3. `BackgroundTransferService.upload(request:fromFile:)` creates an `uploadTask` on the background session, registers an `InFlight` entry, awaits the continuation.
4. Bytes upload. Gateway slices. Gateway streams response back. Delegate accumulates body into `inFlight[id].body`.
5. `didCompleteWithError(nil)` fires. Continuation resumes with `(body, response)`.
6. `fetchPrintPreview` reads the `X-Preview-Id` and `X-Print-Estimate` headers, deletes the temp file, returns `PreviewResult`.
7. `AppViewModel` proceeds as today (3MF parse, scene build, modal present).

### Backgrounded mid-slice

1. Steps 1–3 as above.
2. User backgrounds the app while the slice is computing.
3. iOS keeps the background session alive in the system daemon. The app process may be suspended.
4. Gateway finishes, response streams in. The system delivers chunks to the daemon.
5. iOS resumes the app process (or wakes it briefly) to deliver the delegate callbacks. The `inFlight` entry is intact in memory.
6. `didCompleteWithError(nil)` fires, continuation resumes, `submitPreview` continues.
7. The user, now foregrounded, sees the preview modal appear when they next open the app — or it's already up if the app was foregrounded again before completion.

### Killed app, then iOS relaunches for completion

1. Steps 1–3 as above.
2. App backgrounded, iOS terminates the process for memory pressure.
3. Background session continues in the system daemon. Gateway completes.
4. iOS relaunches the app and calls `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
5. `AppDelegate` stores the completion handler via `transferService.adoptCompletionHandler(_:)`. Forces lazy session init so the delegate is wired.
6. URLSession reattaches the outstanding task and fires delegate callbacks. `inFlight` is empty (fresh process). Body data accumulates against a missing entry — guarded against; the calls are no-ops.
7. `didCompleteWithError` fires. Entry lookup fails. No continuation to resume. Silent drop.
8. `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires. The pending completion handler is invoked, telling iOS we're done.
9. The user, on next launch, sees the dashboard. The slice is forgotten.

This is the documented "discard" semantics. No state restoration, no notification.

### Cancellation

1. User taps Cancel during an active preview.
2. `AppViewModel.cancelPreview()` calls `transferService.cancelAll()`.
3. The session cancels every outstanding task. `didCompleteWithError(URLError(.cancelled))` fires for each.
4. The continuation throws. `submitPreview`'s `catch` block must distinguish cancellation from a real failure:

```swift
} catch let error as URLError where error.code == .cancelled {
    // user-initiated cancel — silent
} catch {
    setMessage(error.localizedDescription, .error)
}
```

This filter is added as part of this work because, today, the catch shows every error including the user's own cancel. The same filter is added to `submitPrint`'s catch.

5. Temp file is cleaned up by the `defer` in `fetchPrintPreview`.

## Error handling

Mapped to existing `GatewayClientError`:

| Source | Mapped to |
|---|---|
| `URLError(.cancelled)` | Propagated as-is, swallowed by existing catch |
| Other `URLError` | `.serverError(error.localizedDescription)` |
| Non-200 status | `.serverError(decoded detail or generic)` |
| Continuation completed with no response captured | `.invalidResponse` |
| Body decode failure (downstream) | Existing `.decodeError` |

## Memory

The sliced 3MF is held in RAM (`Data` buffer) during the transfer. Typical sliced 3MFs are 1–20 MB, well within budget. If files ever grew to hundreds of MB we'd switch to a download-task-to-file shape, but that's a different design and not warranted now.

## Testing

- `MultipartFormData.writeBody(toTemporaryFileNamed:)` — XCTest verifying the temp file matches the in-memory body byte-for-byte and the URL points inside `temporaryDirectory`.
- `BackgroundTransferService.upload(...)` — optional `URLProtocol`-based unit tests for the success and cancellation paths. Worth doing to lock the delegate state machine, but not strictly required since the real validation is end-to-end.
- End-to-end manual test plan (also part of the implementation plan):
  - Foreground-only preview still works.
  - Foreground-only direct print still works.
  - Send app to background mid-slice, return after a minute → preview modal appears with the result.
  - Send app to background mid-slice, force-quit and reopen → app is on dashboard, no crash, no orphan state.
  - Cancel mid-upload → modal closes, no crash, temp file cleaned up.
  - Concurrent: import a second file before the first preview returns (UI gating means this shouldn't be possible, but worth a smoke test).

## File map

| File | Action | Purpose |
|---|---|---|
| `BambuGateway/Networking/BackgroundTransferService.swift` | Create | The service described above |
| `BambuGateway/Networking/MultipartFormData.swift` | Modify | Add `writeBody(toTemporaryFileNamed:)` extension |
| `BambuGateway/Networking/GatewayClient.swift` | Modify | Add `transferService` init parameter; rewrite `fetchPrintPreview` and `submitPrint` to route through it; extract `mapHTTPError` |
| `BambuGateway/App/AppDelegate.swift` | Modify | Add `transferService` property; implement `handleEventsForBackgroundURLSession` |
| `BambuGateway/App/AppViewModel.swift` | Modify | Accept `transferService` at init; use it in `gatewayClient()`; call `cancelAll()` from `cancelPreview` |
| `BambuGateway/App/BambuGatewayApp.swift` | Modify | Pass the AppDelegate's service into `AppViewModel`'s init |
| `BambuGatewayTests/MultipartFormDataTests.swift` | Create | Tests for the file-writing extension |

## Open questions

None at the time of writing. The relaunch-discard semantic, scope (preview + print), and architecture (background URLSession; no gateway change) are all resolved decisions.
