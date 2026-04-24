import SwiftUI
import UIKit

struct FullscreenCameraView: View {
    @ObservedObject var controller: CameraFeedController
    let title: String
    @Binding var presented: Bool

    @State private var chromeVisible = true
    @State private var chromeTimer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraSurfaceView(view: controller.displayView)
                .ignoresSafeArea()
            if case .connecting = controller.state {
                ProgressView().tint(.white)
            } else if case .idle = controller.state {
                ProgressView().tint(.white)
            }
            if chromeVisible {
                chrome
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onTapGesture { toggleChrome() }
        .onAppear { scheduleHide() }
        .onDisappear { chromeTimer?.invalidate() }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { presented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityLabel("Close")
                }
                Spacer()
                Text(title)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding()
            Spacer()
        }
        .transition(.opacity)
    }

    private func toggleChrome() {
        withAnimation { chromeVisible.toggle() }
        if chromeVisible { scheduleHide() }
    }

    private func scheduleHide() {
        chromeTimer?.invalidate()
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            withAnimation { chromeVisible = false }
        }
    }
}
