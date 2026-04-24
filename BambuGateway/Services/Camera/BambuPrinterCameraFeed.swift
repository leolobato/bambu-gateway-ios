import Foundation
import UIKit

/// Dispatches to the correct transport based on the gateway's
/// `CameraInfo.transport` hint. Unknown transports get a static black
/// surface and a terminal `.unsupportedCodec` state — the UI shows
/// "Unsupported camera" without any network activity.
final class BambuPrinterCameraFeed: CameraFeed {
    let state: AsyncStream<CameraFeedState>
    let displayView: UIView

    private let underlying: CameraFeed?

    init(camera: CameraInfo) {
        switch camera.transport {
        case .rtsps:
            let feed = VLCCameraFeed.bambuRTSPS(ip: camera.ip, accessCode: camera.accessCode)
            self.underlying = feed
            self.state = feed.state
            self.displayView = feed.displayView
        case .tcpJPEG:
            let feed = BambuTCPJPEGFeed(configuration: .init(ip: camera.ip, accessCode: camera.accessCode))
            self.underlying = feed
            self.state = feed.state
            self.displayView = feed.displayView
        case .unknown:
            let view = UIView()
            view.backgroundColor = .black
            self.underlying = nil
            self.displayView = view
            self.state = AsyncStream { continuation in
                continuation.yield(.failed(.unsupportedCodec("Unknown camera transport")))
                continuation.finish()
            }
        }
    }

    func start() { underlying?.start() }
    func stop() { underlying?.stop() }
}
