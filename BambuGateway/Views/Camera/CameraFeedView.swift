import SwiftUI
import UIKit

struct CameraFeedView: View {
    let title: String
    @Binding var isExpanded: Bool
    @StateObject private var controller: CameraFeedController
    @State private var fullscreenPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Build a feed view. The `feedBuilder` is invoked once when the view is first created.
    /// To force a new feed (e.g. printer switch), give the parent view a new `.id(...)`.
    init(
        title: String,
        isExpanded: Binding<Bool>,
        feedBuilder: @escaping () -> CameraFeed
    ) {
        self.title = title
        self._isExpanded = isExpanded
        _controller = StateObject(wrappedValue: CameraFeedController(feed: feedBuilder()))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                frameArea
                    .onAppear { controller.start() }
                    .onDisappear { controller.stop() }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 8) {
                if isExpanded {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(title) camera")
        .accessibilityValue(isExpanded ? "Expanded, \(accessibilityStatus)" : "Collapsed")
        .accessibilityHint(isExpanded ? "Double-tap to collapse" : "Double-tap to expand")
    }

    private var frameArea: some View {
        ZStack {
            CameraSurfaceView(view: controller.displayView)
            overlay
            // Fullscreen affordance on the frame itself.
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(8)
                        .background(Circle().fill(.black.opacity(0.4)))
                        .padding(8)
                }
                Spacer()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { fullscreenPresented = true }
        .fullScreenCover(
            isPresented: $fullscreenPresented,
            onDismiss: {
                // Re-attach the displayView to the tile's host container —
                // the fullscreen cover's host kept it while presented.
                controller.displayView.removeFromSuperview()
            }
        ) {
            FullscreenCameraView(controller: controller, title: title, presented: $fullscreenPresented)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch controller.state {
        case .idle, .connecting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Connecting…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        case .failed(let err):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(errorText(err))
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") { controller.retry() }
                    .buttonStyle(.borderedProminent)
            }
        case .stopped, .streaming:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .streaming: return .green
        case .connecting, .idle: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var accessibilityStatus: String {
        switch controller.state {
        case .streaming: return "streaming"
        case .connecting, .idle: return "connecting"
        case .failed: return "disconnected"
        case .stopped: return "stopped"
        }
    }

    private func toggle() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                isExpanded.toggle()
            }
        }
    }

    private func errorText(_ err: CameraFeedError) -> String {
        switch err {
        case .unreachable(let m): return "Can't reach camera: \(m)"
        case .authFailed: return "Authentication failed. Check access code."
        case .unsupportedCodec(let m): return "Unsupported camera: \(m)"
        case .streamEnded: return "Stream ended. Retrying…"
        case .other(let m): return m
        }
    }
}

/// Hosts the feed's live-video `UIView` inside SwiftUI. The surface reparents
/// the shared `UIView` on each layout pass so the same VLC player can move
/// between tile and fullscreen without reconnecting.
struct CameraSurfaceView: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        install(view, in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if view.superview !== container {
            install(view, in: container)
        }
    }

    private func install(_ inner: UIView, in container: UIView) {
        inner.removeFromSuperview()
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
