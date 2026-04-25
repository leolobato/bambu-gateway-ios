import Foundation
import OSLog

/// Owns the single background `URLSession` for long-running gateway uploads.
/// Constructed exactly once per process, in `AppViewModel.init`. Constructing
/// a second instance would conflict on `sessionIdentifier`, since iOS allows
/// only one live session per identifier.
@MainActor
final class BackgroundTransferService: NSObject {
    static let sessionIdentifier = "com.bambugateway.transfer"
    nonisolated private static let log = Logger(subsystem: "com.bambugateway.ios", category: "BackgroundTransferService")

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
            Self.log.debug("upload start id=\(task.taskIdentifier, privacy: .public) url=\(request.url?.absoluteString ?? "?", privacy: .public)")
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
        let status = httpResponse?.statusCode ?? -1
        let castOk = httpResponse != nil
        // The session is configured with `delegateQueue: .main`, so all delegate
        // callbacks already run on the main thread. `assumeIsolated` lets us
        // mutate main-actor state synchronously, preserving the order the
        // system delivers callbacks in.
        MainActor.assumeIsolated {
            self.inFlight[identifier]?.response = httpResponse
        }
        Self.log.debug("didReceive response id=\(identifier, privacy: .public) status=\(status, privacy: .public) httpCast=\(castOk, privacy: .public)")
        completionHandler(.allow)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let identifier = dataTask.taskIdentifier
        let chunkSize = data.count
        MainActor.assumeIsolated {
            self.inFlight[identifier]?.body.append(data)
        }
        Self.log.debug("didReceive data id=\(identifier, privacy: .public) bytes=\(chunkSize, privacy: .public)")
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
            guard let entry = self.inFlight.removeValue(forKey: identifier) else {
                Self.log.debug("didComplete id=\(identifier, privacy: .public) — orphan, no continuation")
                return
            }
            if let error {
                Self.log.error("didComplete id=\(identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                entry.continuation.resume(throwing: error)
                return
            }
            // Background URLSession sometimes does not fire `didReceive response:`
            // for upload tasks even though `task.response` is populated by the
            // time we get here — fall back to it before giving up.
            let response: HTTPURLResponse? = entry.response ?? (task.response as? HTTPURLResponse)
            guard let response else {
                let bodyLen = entry.body.count
                Self.log.error("didComplete id=\(identifier, privacy: .public) NO RESPONSE on entry or task, body=\(bodyLen, privacy: .public) bytes, task.response type=\(String(describing: type(of: task.response)), privacy: .public)")
                entry.continuation.resume(throwing: GatewayClientError.invalidResponse)
                return
            }
            if entry.response == nil {
                Self.log.notice("didComplete id=\(identifier, privacy: .public) used task.response fallback status=\(response.statusCode, privacy: .public)")
            }
            Self.log.debug("didComplete id=\(identifier, privacy: .public) status=\(response.statusCode, privacy: .public) body=\(entry.body.count, privacy: .public) bytes")
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
