import Foundation
import MobileVLCKit
import UIKit

/// Plays the Bambu X1/X1C/P2S camera (RTSPS on port 322) via MobileVLCKit.
///
/// Not general-purpose: arbitrary external RTSP URLs are not supported from
/// iOS because VLC 3.x's LIVE555-backed RTSP stack fails to determine the
/// local interface IP under the iOS sandbox ("Unable to determine our source
/// address: invalid IP 0.0.0.0"). Bambu's camera tolerates that; many
/// consumer NVRs (Reolink and friends) do not — they accept the session,
/// send one keyframe, and then stall.
final class VLCCameraFeed: NSObject, CameraFeed {
    let state: AsyncStream<CameraFeedState>
    let displayView: UIView

    private let player: VLCMediaPlayer
    private let media: VLCMedia
    private var stateContinuation: AsyncStream<CameraFeedState>.Continuation!

    static func bambuRTSPS(ip: String, accessCode: String) -> VLCCameraFeed {
        // `bblp` + access code ride as URL credentials; VLC handles Digest.
        let escaped = accessCode.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? accessCode
        let url = URL(string: "rtsps://bblp:\(escaped)@\(ip):322/streaming/live/1")!
        return VLCCameraFeed(url: url)
    }

    private init(url: URL) {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        self.displayView = view

        // Options passed at the libvlc instance level so they're in place
        // before the RTSP demuxer loads (per-media `addOption` runs too
        // late on MobileVLCKit 3.7 — UDP gets picked first and LIVE555
        // throws "Unable to determine our source address" on iOS).
        //
        // - `--rtsp-tcp` — RTP-over-TCP interleaved frames; avoids the
        //   UDP bind failure entirely.
        // - `--network-caching=1000` — 1 s buffer. Consumer NVRs need
        //   it; lower values cause re-buffering storms.
        //
        // No TLS-verify option: VLC 3.7.x doesn't expose one, and its
        // LIVE555-based RTSPS path doesn't strictly verify certs anyway
        // — Bambu's self-signed cert on port 322 plays without any
        // extra flag.
        let vlcOptions = [
            "--rtsp-tcp",
            "--network-caching=1000",
        ]
        self.player = VLCMediaPlayer(options: vlcOptions)
        self.media = VLCMedia(url: url)

        var stateCont: AsyncStream<CameraFeedState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont

        super.init()

        player.delegate = self
        player.drawable = view
        player.media = media
    }

    // MARK: CameraFeed

    func start() {
        stateContinuation.yield(.connecting)
        player.play()
    }

    func stop() {
        player.stop()
        stateContinuation.yield(.stopped)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCCameraFeed: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ notification: Notification) {
        switch player.state {
        case .opening, .buffering:
            stateContinuation.yield(.connecting)
        case .playing:
            stateContinuation.yield(.streaming)
        case .error:
            stateContinuation.yield(.failed(.other("VLC playback error")))
        case .stopped, .ended:
            stateContinuation.yield(.stopped)
        default:
            break
        }
    }
}
