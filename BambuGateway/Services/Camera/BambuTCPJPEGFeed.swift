import CoreGraphics
import Foundation
import ImageIO
import Network
import Security
import UIKit

/// Bambu A1 / P1 camera: TCP with TLS on port 6000. Sends an 80-byte auth
/// packet, then receives [16-byte header][JPEG] frames in a loop. Draws
/// decoded frames into an internal `UIImageView` exposed as `displayView`.
final class BambuTCPJPEGFeed: CameraFeed {
    struct Configuration {
        let ip: String
        let accessCode: String
    }

    let state: AsyncStream<CameraFeedState>
    let displayView: UIView

    private let imageView: UIImageView
    private var stateContinuation: AsyncStream<CameraFeedState>.Continuation!

    private let config: Configuration
    private let queue = DispatchQueue(label: "bambu.tcp.jpeg")
    private var connection: NWConnection?
    private var buffer = Data()
    private var expectedJPEGLength: Int?
    private var hasReceivedFirstFrame = false

    init(configuration: Configuration) {
        self.config = configuration

        let image = UIImageView()
        image.contentMode = .scaleAspectFit
        image.backgroundColor = .black
        image.translatesAutoresizingMaskIntoConstraints = false
        self.imageView = image
        self.displayView = image

        var stateCont: AsyncStream<CameraFeedState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont
    }

    func start() {
        queue.async { [self] in openConnection() }
    }

    func stop() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
            stateContinuation.yield(.stopped)
        }
    }

    private func openConnection() {
        stateContinuation.yield(.connecting)
        hasReceivedFirstFrame = false

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            queue
        )
        let parameters = NWParameters(tls: tls)

        let conn = NWConnection(
            host: NWEndpoint.Host(config.ip),
            port: NWEndpoint.Port(rawValue: 6000)!,
            using: parameters
        )
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                sendAuth()
                startReceive()
            case .failed(let err):
                stateContinuation.yield(.failed(.unreachable(err.localizedDescription)))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendAuth() {
        // 80-byte auth packet for Bambu's LAN binary camera protocol.
        // Layout (reverse-engineered, verified against panda-be-free):
        //   [0..3]   = 0x40 0x00 0x00 0x00  (magic / packet type)
        //   [4..7]   = 0x00 0x30 0x00 0x00  (length marker, little-endian 0x3000)
        //   [8..15]  = zero
        //   [16..19] = "bblp" (username, ASCII)
        //   [20..47] = zero
        //   [48..79] = access code (UTF-8, up to 32 bytes, zero-padded)
        var packet = Data(count: 80)
        packet[0] = 0x40
        packet[5] = 0x30
        let username = Data("bblp".utf8)
        packet.replaceSubrange(16 ..< 16 + username.count, with: username)
        let code = Data(config.accessCode.utf8).prefix(32)
        packet.replaceSubrange(48 ..< 48 + code.count, with: code)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func startReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                handleIncoming(data)
            }
            if error == nil, !isComplete {
                startReceive()
            } else {
                stateContinuation.yield(.failed(.streamEnded))
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        buffer.append(data)
        while true {
            if expectedJPEGLength == nil {
                guard buffer.count >= 16 else { return }
                // Bambu frame header: bytes 0-3 = little-endian JPEG length.
                let len = Int(buffer[0]) |
                    (Int(buffer[1]) << 8) |
                    (Int(buffer[2]) << 16) |
                    (Int(buffer[3]) << 24)
                expectedJPEGLength = len
                buffer.removeSubrange(0..<16)
            }
            guard let expected = expectedJPEGLength, buffer.count >= expected else { return }

            let jpegData = Data(buffer.prefix(expected))
            buffer.removeSubrange(0..<expected)
            expectedJPEGLength = nil

            if let cg = decodeJPEG(jpegData) {
                let image = UIImage(cgImage: cg)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.imageView.image = image
                    if !self.hasReceivedFirstFrame {
                        self.hasReceivedFirstFrame = true
                        self.stateContinuation.yield(.streaming)
                    }
                }
            }
        }
    }

    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
