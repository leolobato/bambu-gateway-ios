import Foundation

/// Owns the single background `URLSession` for long-running gateway uploads.
/// Constructed exactly once per process, in `AppViewModel.init`. Constructing
/// a second instance would conflict on `sessionIdentifier`, since iOS allows
/// only one live session per identifier.
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
        // The session is configured with `delegateQueue: .main`, so all delegate
        // callbacks already run on the main thread. `assumeIsolated` lets us
        // mutate main-actor state synchronously, preserving the order the
        // system delivers callbacks in.
        MainActor.assumeIsolated {
            self.inFlight[identifier]?.response = httpResponse
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let identifier = dataTask.taskIdentifier
        MainActor.assumeIsolated {
            self.inFlight[identifier]?.body.append(data)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let identifier = task.taskIdentifier
        MainActor.assumeIsolated {
            // Orphan from a previous app launch — the system reattached the
            // task but no continuation exists. Per spec: discard silently.
            guard let entry = self.inFlight.removeValue(forKey: identifier) else { return }
            if let error {
                entry.continuation.resume(throwing: error)
                return
            }
            // Background URLSession does not always fire `didReceive response:`
            // for upload tasks (observed on iOS 18); `task.response` is reliably
            // populated by the time we get here, so fall back to it.
            guard let response = entry.response ?? (task.response as? HTTPURLResponse) else {
                entry.continuation.resume(throwing: GatewayClientError.invalidResponse)
                return
            }
            entry.continuation.resume(returning: (entry.body, response))
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            self.pendingCompletionHandler?()
            self.pendingCompletionHandler = nil
        }
    }
}
