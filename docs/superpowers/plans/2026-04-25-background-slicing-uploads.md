# Background Slicing Uploads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the long-running `/api/print-preview` and `/api/print` POSTs onto a `URLSessionConfiguration.background` session so the upload+download survives app suspension.

**Architecture:** A new `BackgroundTransferService` owns one background `URLSession` and exposes an async `upload(request:fromFile:)` API by wrapping its delegate callbacks in `CheckedContinuation`s. `GatewayClient.fetchPrintPreview` and `submitPrint` build their multipart bodies, write them to temp files, and route through the service while keeping their public signatures stable. Other endpoints stay on `URLSession.shared`.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-04-25-background-slicing-uploads-design.md`

**Build & test commands** (per `CLAUDE.md`):
- Tests: `xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/<TestClass>`
- Compile-only: `xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- New Swift files under `BambuGateway/` are auto-included via XcodeGen globs — but `xcodegen generate` must be run after creating them.

---

## File map

| File | Action | Purpose |
|---|---|---|
| `BambuGateway/Networking/MultipartFormData.swift` | Modify | Add `writeBody(toTemporaryFileNamed:)` extension |
| `BambuGatewayTests/MultipartFormDataTests.swift` | Create | Tests for the file-writing extension |
| `BambuGateway/Networking/BackgroundTransferService.swift` | Create | The async-wrapping background URLSession service |
| `BambuGateway/App/AppDelegate.swift` | Modify | Add static `transferService` and `handleEventsForBackgroundURLSession` hook |
| `BambuGateway/App/AppViewModel.swift` | Modify | Construct the service, assign to AppDelegate, pass to `GatewayClient`, wire `cancelPreview` to `cancelAll()`, filter `URLError(.cancelled)` in catches |
| `BambuGateway/Networking/GatewayClient.swift` | Modify | Accept `transferService` at init; extract `resolveURL`/`mapHTTPError` helpers; rewrite `fetchPrintPreview` and `submitPrint` to use the service |

---

### Task 1: `MultipartFormData.writeBody` extension

**Files:**
- Modify: `BambuGateway/Networking/MultipartFormData.swift`
- Test: `BambuGatewayTests/MultipartFormDataTests.swift`

- [ ] **Step 1: Write the failing test**

Create `BambuGatewayTests/MultipartFormDataTests.swift`:

```swift
import XCTest
@testable import BambuGateway

final class MultipartFormDataTests: XCTestCase {
    func test_writeBodyToTemporaryFile_matchesInMemoryBody() throws {
        var form = MultipartFormData()
        form.addField(name: "alpha", value: "first")
        form.addFile(name: "file", fileName: "demo.bin", mimeType: "application/octet-stream", data: Data([0x01, 0x02, 0x03]))
        form.finalize()

        let url = try form.writeBody(toTemporaryFileNamed: "test-payload")

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "multipart")
        XCTAssertTrue(url.path.contains(FileManager.default.temporaryDirectory.path))

        let written = try Data(contentsOf: url)
        XCTAssertEqual(written, form.body)

        try FileManager.default.removeItem(at: url)
    }

    func test_writeBodyToTemporaryFile_returnsUniqueURLsAcrossCalls() throws {
        var form = MultipartFormData()
        form.addField(name: "k", value: "v")
        form.finalize()

        let urlA = try form.writeBody(toTemporaryFileNamed: "concurrent")
        let urlB = try form.writeBody(toTemporaryFileNamed: "concurrent")

        XCTAssertNotEqual(urlA, urlB)
        try FileManager.default.removeItem(at: urlA)
        try FileManager.default.removeItem(at: urlB)
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project so the new test file is included**

```
cd /Users/leolobato/Documents/Projetos/Personal/3d/bambu_workspace/bambu-gateway-ios
xcodegen generate
```

- [ ] **Step 3: Run tests to verify they fail**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/MultipartFormDataTests 2>&1 | tail -25
```

Expected: build failure with "value of type 'MultipartFormData' has no member 'writeBody'".

- [ ] **Step 4: Add the extension**

Append to `BambuGateway/Networking/MultipartFormData.swift`:

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

- [ ] **Step 5: Run tests to verify they pass**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -only-testing:BambuGatewayTests/MultipartFormDataTests 2>&1 | tail -15
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```
git add BambuGateway/Networking/MultipartFormData.swift BambuGatewayTests/MultipartFormDataTests.swift BambuGateway.xcodeproj
git commit -m "$(cat <<'EOF'
Persist multipart bodies to temporary files

- New `MultipartFormData.writeBody(toTemporaryFileNamed:)` writes the in-memory body to a uniquely-named file in `temporaryDirectory`
- Required by background `URLSession` upload tasks, which only accept a file URL as the body source
- Tests cover byte-for-byte equivalence and per-call URL uniqueness
EOF
)"
```

---

### Task 2: `BackgroundTransferService`

**Files:**
- Create: `BambuGateway/Networking/BackgroundTransferService.swift`

This task has no XCTest coverage. The state machine is small (~6 delegate callbacks, one in-flight dictionary, one continuation map) and the meaningful test is end-to-end on a real device — covered by Task 9. Unit-testing via `URLProtocol` is technically possible but background sessions are heavily managed by the system daemon and protocol-class injection behaves inconsistently; the false-confidence risk outweighs the marginal coverage gain.

- [ ] **Step 1: Create the file**

Create `BambuGateway/Networking/BackgroundTransferService.swift`:

```swift
import Foundation

@MainActor
final class BackgroundTransferService: NSObject {
    static let sessionIdentifier = "com.bambugateway.transfer"

    private struct InFlight {
        var response: HTTPURLResponse?
        var body: Data
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    }

    private var inFlight: [Int: InFlight] = [:]
    private var pendingCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    func upload(request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            inFlight[task.taskIdentifier] = InFlight(response: nil, body: Data(), continuation: continuation)
            task.resume()
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    func adoptCompletionHandler(_ handler: @escaping () -> Void) {
        pendingCompletionHandler = handler
        _ = session  // force lazy session init so the delegate is wired
    }
}

extension BackgroundTransferService: URLSessionDataDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let identifier = dataTask.taskIdentifier
        let httpResponse = response as? HTTPURLResponse
        Task { @MainActor in
            self.inFlight[identifier]?.response = httpResponse
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let identifier = dataTask.taskIdentifier
        Task { @MainActor in
            self.inFlight[identifier]?.body.append(data)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let identifier = task.taskIdentifier
        Task { @MainActor in
            guard let entry = self.inFlight.removeValue(forKey: identifier) else { return }
            if let error {
                entry.continuation.resume(throwing: error)
                return
            }
            guard let response = entry.response else {
                entry.continuation.resume(throwing: GatewayClientError.invalidResponse)
                return
            }
            entry.continuation.resume(returning: (entry.body, response))
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.pendingCompletionHandler?()
            self.pendingCompletionHandler = nil
        }
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project**

```
xcodegen generate
```

- [ ] **Step 3: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED. The service compiles standalone — no callers yet.

- [ ] **Step 4: Run the existing test suite to ensure no regression**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all existing tests pass (Task 1's tests included, no new tests in this task).

- [ ] **Step 5: Commit**

```
git add BambuGateway/Networking/BackgroundTransferService.swift BambuGateway.xcodeproj
git commit -m "$(cat <<'EOF'
Add `BackgroundTransferService`

- Wraps a single `URLSessionConfiguration.background` session in async/await via `CheckedContinuation`
- Per-task in-flight state captures response and accumulated body, fired back on completion
- Orphan tasks delivered after an app relaunch fall through silently because no in-flight entry exists
- `cancelAll` cancels every outstanding upload; `adoptCompletionHandler` stores the system-supplied handler for `urlSessionDidFinishEvents`
EOF
)"
```

---

### Task 3: AppDelegate hook

**Files:**
- Modify: `BambuGateway/App/AppDelegate.swift`

`AppDelegate` already follows a "static reference assigned by AppViewModel" pattern (`Self.pushService`, `Self.toastCenter`). The transfer service piggybacks on the same pattern.

- [ ] **Step 1: Add the static reference and the hook**

In `BambuGateway/App/AppDelegate.swift`, replace:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pushService: PushService?
    static var toastCenter: ToastCenter?
```

with:

```swift
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var pushService: PushService?
    static var toastCenter: ToastCenter?
    static var transferService: BackgroundTransferService?
```

Then, immediately after the existing `func application(_:didFailToRegisterForRemoteNotificationsWithError:)` method (and before `userNotificationCenter(_:willPresent:withCompletionHandler:)`), insert:

```swift
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            Self.transferService?.adoptCompletionHandler(completionHandler)
        }
    }
```

The `Task { @MainActor in ... }` matches the existing pattern in this file (used for `handleAPNsDeviceToken`). The service may not be assigned yet during very early launch — `?` makes this safe; iOS retries delivery if needed.

- [ ] **Step 2: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```
git add BambuGateway/App/AppDelegate.swift
git commit -m "$(cat <<'EOF'
Adopt background URL session events in `AppDelegate`

- New static `transferService` mirrors the existing `pushService` and `toastCenter` pattern
- `application(_:handleEventsForBackgroundURLSession:completionHandler:)` forwards the system handler to the service so iOS can release the relaunch without holding the app awake unnecessarily
EOF
)"
```

---

### Task 4: Construct and inject the service

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift` (init signature)
- Modify: `BambuGateway/App/AppViewModel.swift` (construct service, assign to AppDelegate, route through `gatewayClient()`)

Today, `GatewayClient` exposes:

```swift
init(baseURLString: String, session: URLSession = .shared)
```

The service is needed only by `fetchPrintPreview` and `submitPrint`. The init grows by one optional parameter so non-feature callsites (and tests) continue to compile unchanged.

- [ ] **Step 1: Add `transferService` to `GatewayClient`**

In `BambuGateway/Networking/GatewayClient.swift`, locate:

```swift
struct GatewayClient {
    let baseURLString: String
    let session: URLSession

    init(baseURLString: String, session: URLSession = .shared) {
        self.baseURLString = baseURLString
        self.session = session
    }
```

Replace with:

```swift
struct GatewayClient {
    let baseURLString: String
    let session: URLSession
    let transferService: BackgroundTransferService?

    init(
        baseURLString: String,
        session: URLSession = .shared,
        transferService: BackgroundTransferService? = nil
    ) {
        self.baseURLString = baseURLString
        self.session = session
        self.transferService = transferService
    }
```

The optional default keeps existing call sites (`PushService`, `LiveActivityService`) compiling without a nil literal at every callsite. They construct `GatewayClient(baseURLString:)` for short endpoints only and never use the background path, so a nil service is correct for them.

- [ ] **Step 2: Construct and assign the service in `AppViewModel.init`**

In `BambuGateway/App/AppViewModel.swift`, the existing `init` (around lines 109–125) currently ends with:

```swift
        self.toastCenter = toast
        AppDelegate.pushService = push
        AppDelegate.toastCenter = toast
    }
```

Add a new stored property and update the init. First, add the property declaration. Find the existing service declarations near line 73:

```swift
    let pushService: PushService
    let liveActivityService: LiveActivityService
    let notificationService: NotificationService
    let toastCenter: ToastCenter
```

Replace with:

```swift
    let pushService: PushService
    let liveActivityService: LiveActivityService
    let notificationService: NotificationService
    let toastCenter: ToastCenter
    let transferService: BackgroundTransferService
```

Then, in `init`, the block currently reads:

```swift
        let initialClient = GatewayClient(baseURLString: loaded.gatewayBaseURL)
        let push = PushService(client: initialClient)
        let toast = ToastCenter()
        self.pushService = push
        self.liveActivityService = LiveActivityService(client: initialClient, pushService: push)
        self.notificationService = NotificationService()
        self.toastCenter = toast
        AppDelegate.pushService = push
        AppDelegate.toastCenter = toast
    }
```

Replace with:

```swift
        let initialClient = GatewayClient(baseURLString: loaded.gatewayBaseURL)
        let push = PushService(client: initialClient)
        let toast = ToastCenter()
        let transfer = BackgroundTransferService()
        self.pushService = push
        self.liveActivityService = LiveActivityService(client: initialClient, pushService: push)
        self.notificationService = NotificationService()
        self.toastCenter = toast
        self.transferService = transfer
        AppDelegate.pushService = push
        AppDelegate.toastCenter = toast
        AppDelegate.transferService = transfer
    }
```

- [ ] **Step 3: Pass the service through `gatewayClient()`**

Locate the existing private helper around line 1269:

```swift
    private func gatewayClient() -> GatewayClient {
        GatewayClient(baseURLString: gatewayBaseURL)
    }
```

Replace with:

```swift
    private func gatewayClient() -> GatewayClient {
        GatewayClient(baseURLString: gatewayBaseURL, transferService: transferService)
    }
```

- [ ] **Step 4: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED. No callers of `GatewayClient(baseURLString:)` are broken because the new parameter has a default.

- [ ] **Step 5: Run all tests to ensure no regression**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```
git add BambuGateway/Networking/GatewayClient.swift BambuGateway/App/AppViewModel.swift
git commit -m "$(cat <<'EOF'
Inject `BackgroundTransferService` into `GatewayClient`

- `AppViewModel` constructs one service at startup and exposes it on `AppDelegate.transferService` for the background-URL-session relaunch hook
- `GatewayClient` accepts the service as an optional init parameter so non-feature callers (push, live activity) compile unchanged
- The service is routed through `gatewayClient()` so the upcoming preview and print rewrites can use it
EOF
)"
```

---

### Task 5: Extract `resolveURL` and `mapHTTPError` helpers

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift`

The existing `request(...)` builds a URL inline and decodes errors inline. Both pieces are needed by the upcoming background path, so extract them into private helpers shared by both paths.

- [ ] **Step 1: Add the helpers**

In `BambuGateway/Networking/GatewayClient.swift`, find the existing `request(...)` function around line 297. Insert two new private helpers immediately above it:

```swift
    private func resolveURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host,
              !host.isEmpty else {
            throw GatewayClientError.invalidURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw GatewayClientError.invalidURL
        }
        return url
    }

    private func mapHTTPError(_ response: HTTPURLResponse, data: Data) -> GatewayClientError {
        if let detail = try? JSONDecoder().decode(ErrorDetailResponse.self, from: data).detail {
            return .serverError(detail)
        }
        return .serverError("Request failed with HTTP \(response.statusCode).")
    }
```

- [ ] **Step 2: Refactor `request(...)` to use them**

Inside `request(...)`, replace the URL-building block:

```swift
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host,
              !host.isEmpty else {
            throw GatewayClientError.invalidURL
        }

        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw GatewayClientError.invalidURL
        }
```

with:

```swift
        let url = try resolveURL(path: path, queryItems: queryItems)
```

And replace the error-decoding block:

```swift
        guard (200 ... 299).contains(http.statusCode) else {
            if let detail = try? JSONDecoder().decode(ErrorDetailResponse.self, from: data).detail {
                throw GatewayClientError.serverError(detail)
            }
            throw GatewayClientError.serverError("Request failed with HTTP \(http.statusCode).")
        }
```

with:

```swift
        guard (200 ... 299).contains(http.statusCode) else {
            throw mapHTTPError(http, data: data)
        }
```

- [ ] **Step 3: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run all tests**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all tests pass — pure refactor, no behavior change.

- [ ] **Step 5: Commit**

```
git add BambuGateway/Networking/GatewayClient.swift
git commit -m "$(cat <<'EOF'
Extract URL and HTTP error helpers in `GatewayClient`

- `resolveURL(path:queryItems:)` and `mapHTTPError(_:data:)` are now private helpers shared by `request` today and the upcoming background-session callers
- Pure refactor; existing behaviour and tests unchanged
EOF
)"
```

---

### Task 6: Route `fetchPrintPreview` through the service

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift`

- [ ] **Step 1: Rewrite the function**

In `BambuGateway/Networking/GatewayClient.swift`, locate `fetchPrintPreview` around line 100. The current body builds the form and calls the in-process `request(...)`. Replace the entire function with:

```swift
    func fetchPrintPreview(_ submission: PrintSubmission) async throws -> PreviewResult {
        guard let transferService else {
            throw GatewayClientError.serverError("Background transfer service is not available.")
        }

        var form = MultipartFormData()
        form.addFile(name: "file", fileName: submission.file.fileName, mimeType: "application/octet-stream", data: submission.file.data)

        if !submission.printerId.isEmpty {
            form.addField(name: "printer_id", value: submission.printerId)
        }
        if !submission.machineProfile.isEmpty {
            form.addField(name: "machine_profile", value: submission.machineProfile)
        }
        if !submission.processProfile.isEmpty {
            form.addField(name: "process_profile", value: submission.processProfile)
        }
        if let plateId = submission.plateId {
            form.addField(name: "plate_id", value: String(plateId))
        }
        if !submission.plateType.isEmpty {
            form.addField(name: "plate_type", value: submission.plateType)
        }
        if !submission.filamentOverrides.isEmpty {
            try addFilamentProfilesField(to: &form, overrides: submission.filamentOverrides)
        }
        form.finalize()

        let bodyURL = try form.writeBody(toTemporaryFileNamed: "print-preview")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: try resolveURL(path: "/api/print-preview"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await transferService.upload(request: request, fromFile: bodyURL)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(httpResponse, data: data)
        }

        guard let previewId = httpResponse.value(forHTTPHeaderField: "X-Preview-Id"),
              !previewId.isEmpty else {
            throw GatewayClientError.serverError("Server did not return a preview ID.")
        }

        let fileName = parseContentDispositionFilename(httpResponse) ?? submission.file.fileName
        let estimateHeader = httpResponse.value(forHTTPHeaderField: "X-Print-Estimate")
        let estimate = PrintEstimate.decodeFromHeader(estimateHeader)

        return PreviewResult(threeMFData: data, previewId: previewId, fileName: fileName, estimate: estimate)
    }
```

Behavioural notes:
- The temp file is cleaned up by `defer` whether the upload throws, succeeds, or is cancelled.
- The header parsing logic for `X-Preview-Id`, `Content-Disposition`, and `X-Print-Estimate` is unchanged from the existing implementation — same headers, same handling.
- The early `guard let transferService` is paranoia. With the wiring in Task 4, the service is always non-nil for `AppViewModel`-constructed clients. The guard turns a nil service into a clean error rather than a crash if someone mistakenly uses the short-endpoint constructor for this method.

- [ ] **Step 2: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run all tests**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all tests pass. There are no tests covering the preview flow's HTTP layer directly, so this is a smoke check that nothing else regressed.

- [ ] **Step 4: Commit**

```
git add BambuGateway/Networking/GatewayClient.swift
git commit -m "$(cat <<'EOF'
Route preview slicing through the background session

- `fetchPrintPreview` now writes the multipart body to a temp file and uploads it via `BackgroundTransferService`, so the slice survives app suspension
- Header parsing (`X-Preview-Id`, `X-Print-Estimate`, `Content-Disposition`) is unchanged
- Temp file cleanup runs from `defer` whether the upload succeeds, throws, or is cancelled
EOF
)"
```

---

### Task 7: Route `submitPrint` through the service

**Files:**
- Modify: `BambuGateway/Networking/GatewayClient.swift`

- [ ] **Step 1: Rewrite `submitPrint`**

In `BambuGateway/Networking/GatewayClient.swift`, locate `submitPrint` around line 163. Replace the entire function with:

```swift
    func submitPrint(_ submission: PrintSubmission) async throws -> PrintResponse {
        guard let transferService else {
            throw GatewayClientError.serverError("Background transfer service is not available.")
        }

        var form = MultipartFormData()
        form.addFile(name: "file", fileName: submission.file.fileName, mimeType: "application/octet-stream", data: submission.file.data)

        if !submission.printerId.isEmpty {
            form.addField(name: "printer_id", value: submission.printerId)
        }
        if let plateId = submission.plateId {
            form.addField(name: "plate_id", value: String(plateId))
        }
        if !submission.plateType.isEmpty {
            form.addField(name: "plate_type", value: submission.plateType)
        }
        if !submission.machineProfile.isEmpty {
            form.addField(name: "machine_profile", value: submission.machineProfile)
        }
        if !submission.processProfile.isEmpty {
            form.addField(name: "process_profile", value: submission.processProfile)
        }
        if !submission.filamentOverrides.isEmpty {
            try addFilamentProfilesField(to: &form, overrides: submission.filamentOverrides)
        }
        form.finalize()

        let bodyURL = try form.writeBody(toTemporaryFileNamed: "print")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: try resolveURL(path: "/api/print"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await transferService.upload(request: request, fromFile: bodyURL)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw mapHTTPError(httpResponse, data: data)
        }

        return try decode(PrintResponse.self, from: data)
    }
```

Notes:
- `printFromPreview` is **not** changed. It does not upload a file — it just submits a `preview_id` reference via a small multipart body — so it has no long-running phase. Leaving it on the foreground path keeps the change scoped.
- The field-ordering inside the form matches the existing implementation byte-for-byte to avoid any accidental gateway-side parsing regressions.

- [ ] **Step 2: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run all tests**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```
git add BambuGateway/Networking/GatewayClient.swift
git commit -m "$(cat <<'EOF'
Route direct print submissions through the background session

- `submitPrint` now writes the multipart body to a temp file and uploads via `BackgroundTransferService`, so a slice-and-submit job survives app suspension
- `printFromPreview` stays on the foreground path because it forwards a `preview_id` and is not long-running
- JSON decode and error mapping unchanged
EOF
)"
```

---

### Task 8: Cancellation wiring + `URLError(.cancelled)` filter

**Files:**
- Modify: `BambuGateway/App/AppViewModel.swift`

Today, `cancelPreview()` only flips UI state; an in-flight transfer keeps running on the background session. And `submitPreview` / `submitPrint` show every error (including the user's own cancel) via `setMessage`. Both gaps close together.

- [ ] **Step 1: Cancel in-flight transfers when the user cancels the preview**

In `BambuGateway/App/AppViewModel.swift`, find `cancelPreview()` around line 431:

```swift
    func cancelPreview() {
        dismissPreview()
    }
```

Replace with:

```swift
    func cancelPreview() {
        transferService.cancelAll()
        dismissPreview()
    }
```

- [ ] **Step 2: Filter `URLError(.cancelled)` from the preview catch**

Find `submitPreview()` around line 349. Its current `catch` block reads:

```swift
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }
```

Replace with:

```swift
        } catch let error as URLError where error.code == .cancelled {
            // user-initiated cancel — silent
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }
```

- [ ] **Step 3: Filter `URLError(.cancelled)` from the direct-print catch**

In the same file, find `submitPrint()` around line 334. Its current `catch` block reads:

```swift
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }
```

Replace with:

```swift
        } catch let error as URLError where error.code == .cancelled {
            // user-initiated cancel — silent
        } catch {
            setMessage(error.localizedDescription, .error)
        }
    }
```

- [ ] **Step 4: Compile-check**

```
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -8
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run all tests**

```
xcodebuild test -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```
git add BambuGateway/App/AppViewModel.swift
git commit -m "$(cat <<'EOF'
Cancel in-flight slicing uploads when the user cancels

- `AppViewModel.cancelPreview` now stops the background transfer instead of letting it keep running invisibly after the modal closes
- `submitPreview` and `submitPrint` swallow `URLError(.cancelled)` so a user-initiated cancel no longer surfaces as an inline error
EOF
)"
```

---

### Task 9: Manual verification on simulator

This task has no automated coverage. The real validation is end-to-end with a live gateway. Per `CLAUDE.md`, run the app on a different simulator than the unit-test one (i.e. not iPhone 16 / iOS 18.6).

- [ ] **Step 1: Build and install on iPhone 16 Pro 18.3**

```
xcrun simctl boot 7B767EFC-A027-4E8F-AD65-BE6FD7D9902A 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID 7B767EFC-A027-4E8F-AD65-BE6FD7D9902A
xcodebuild -project BambuGateway.xcodeproj -scheme BambuGateway -destination 'platform=iOS Simulator,id=7B767EFC-A027-4E8F-AD65-BE6FD7D9902A' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
xcrun simctl uninstall 7B767EFC-A027-4E8F-AD65-BE6FD7D9902A org.lobato.bambu-gateway-ios 2>/dev/null || true
xcrun simctl install 7B767EFC-A027-4E8F-AD65-BE6FD7D9902A build/Build/Products/Debug-iphonesimulator/BambuGateway.app
xcrun simctl launch 7B767EFC-A027-4E8F-AD65-BE6FD7D9902A org.lobato.bambu-gateway-ios
```

If a different simulator is already booted and preferred, use that one instead.

- [ ] **Step 2: Foreground happy path — preview**

1. Import a 3MF that needs slicing.
2. Tap **Preview**.
3. Wait for the slice to complete with the app foregrounded.
4. **Expected:** preview modal appears with the 3D scene as before.
5. **Failure mode to watch for:** "Server did not return a preview ID" (means the response headers weren't surfaced through the new path).

- [ ] **Step 3: Foreground happy path — direct print**

1. Import a 3MF that needs slicing.
2. Tap **Print** (not Preview).
3. **Expected:** direct print succeeds; the inline success banner shows; the success modal sheet rises (from the previous feature) if/when the gateway returns an estimate.

- [ ] **Step 4: Background mid-slice**

1. Tap **Preview** on a 3MF.
2. Within a second of tapping, send the app to the background (swipe up to the home screen).
3. Wait at least 30 seconds (or longer for a complex model).
4. Reopen the app.
5. **Expected:** preview modal appears with the 3D scene; no error message. The slice continued while backgrounded.
6. **Failure mode:** previous behaviour was the connection dropping and the user seeing nothing or an error on return — that's the bug this feature fixes.

- [ ] **Step 5: Cancel mid-upload**

1. Tap **Preview**.
2. Within the loading window, tap **Cancel** in the modal.
3. **Expected:** modal closes silently. No "cancelled" error message in the inline banner. Temp file cleaned up (no growth in `~/Library/Developer/CoreSimulator/Devices/<id>/data/Containers/Data/Application/<id>/tmp` after cancel — optional check).

- [ ] **Step 6: Killed-app discard path**

1. Tap **Preview** on a long slice.
2. Send the app to the background.
3. Force-quit (swipe up in app switcher and flick the BambuGateway card up).
4. Wait long enough for the slice to complete server-side.
5. Reopen the app.
6. **Expected:** dashboard renders normally. No crash. No phantom modal. The slice result is silently discarded — this is the documented behaviour from the spec.

- [ ] **Step 7: Final commit if anything was tweaked during verification**

If steps 2–6 all pass without code changes, skip. Otherwise:

```
git add -A
git status
git commit -m "Address simulator-verification findings"
```

---

## Self-review notes

Spec coverage:

| Spec section | Task |
|---|---|
| `BackgroundTransferService` (state, public API, delegate behaviour) | Task 2 |
| `MultipartFormData.writeBody` extension | Task 1 |
| `GatewayClient` change (init, fetchPrintPreview, submitPrint, mapHTTPError) | Tasks 4, 5, 6, 7 |
| `AppDelegate` `transferService` + `handleEventsForBackgroundURLSession` | Task 3 |
| `AppViewModel` integration (construct, assign, inject, cancel) | Tasks 4, 8 |
| `URLError(.cancelled)` filter on cancel path | Task 8 |
| Memory note (in-RAM body), foreground/background/relaunch flows | Validated indirectly via Task 9 manual scenarios |
| Out-of-scope items (no progress UI, no relaunch restoration, no other endpoints) | No tasks (intentional) |

No placeholders. Type names (`BackgroundTransferService`, `transferService`, `mapHTTPError`, `resolveURL`, `writeBody(toTemporaryFileNamed:)`) are consistent across tasks. The `printFromPreview` non-change is explicit in Task 7.
