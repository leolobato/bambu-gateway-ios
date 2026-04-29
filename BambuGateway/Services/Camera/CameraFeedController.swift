import Combine
import Foundation
import UIKit

@MainActor
final class CameraFeedController: ObservableObject {
    @Published private(set) var state: CameraFeedState = .idle

    /// The live-video surface provided by the feed. SwiftUI wraps this in a
    /// `UIViewRepresentable`.
    let displayView: UIView

    private let feed: CameraFeed
    private var stateTask: Task<Void, Never>?
    private var isStarted = false

    init(feed: CameraFeed) {
        self.feed = feed
        self.displayView = feed.displayView

        // Observe the feed's state stream once for the controller's lifetime.
        // Recreating the iterator across stop/start cycles loses values —
        // AsyncStream is single-consumer and a fresh iterator created after
        // cancelling the previous one doesn't reliably receive subsequent
        // yields, leaving the controller stuck on the last state set by stop.
        let stream = feed.state
        self.stateTask = Task { [weak self] in
            for await newState in stream {
                await MainActor.run { self?.state = newState }
            }
        }
    }

    deinit {
        stateTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        feed.start()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        feed.stop()
    }

    /// Manual retry — cancels any back-off and restarts.
    func retry() {
        stop()
        start()
    }
}
