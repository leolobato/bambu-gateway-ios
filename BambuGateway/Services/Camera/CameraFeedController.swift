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

    init(feed: CameraFeed) {
        self.feed = feed
        self.displayView = feed.displayView
    }

    deinit {
        stateTask?.cancel()
    }

    func start() {
        guard stateTask == nil else { return }
        feed.start()

        stateTask = Task { [weak self, feed] in
            for await newState in feed.state {
                await MainActor.run {
                    self?.state = newState
                }
            }
        }
    }

    func stop() {
        feed.stop()
        stateTask?.cancel()
        stateTask = nil
        state = .stopped
    }

    /// Manual retry — cancels any back-off and restarts.
    func retry() {
        stop()
        start()
    }
}
