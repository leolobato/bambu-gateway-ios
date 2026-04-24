import Foundation
import UIKit

enum CameraFeedError: Error, Equatable {
    case unreachable(String)
    case authFailed
    case unsupportedCodec(String)
    case streamEnded
    case other(String)
}

enum CameraFeedState: Equatable {
    case idle
    case connecting
    case streaming
    case failed(CameraFeedError)
    case stopped
}

/// A video source that draws into a UIView.
/// VLCKit-backed feeds paint into their drawable; the TCP-JPEG feed draws into
/// a `UIImageView`. Consumers embed `displayView` in SwiftUI via
/// `UIViewRepresentable` and observe `state` for connection progress.
protocol CameraFeed: AnyObject {
    /// State changes. Emits synchronously on `start()` / `stop()` transitions
    /// and asynchronously as the underlying player reports progress.
    var state: AsyncStream<CameraFeedState> { get }

    /// The view that displays the live video. Same instance for the feed's
    /// lifetime — safe to re-parent between tile and fullscreen containers.
    var displayView: UIView { get }

    func start()
    func stop()
}
