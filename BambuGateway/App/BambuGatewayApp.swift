#if os(iOS)
import Combine
import SwiftUI

@main
struct BambuGatewayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    await viewModel.bootstrapPushServices()
                    await viewModel.refreshAll()
                    await viewModel.resumePersistedSliceJob()
                    drainPendingShare()
                }
                .onOpenURL { url in
                    if url.scheme == "bambugateway" {
                        // Newer share extension queues the URL in the App Group and
                        // opens `bambugateway://open`. Older links carried `?url=` directly.
                        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
                           let webURL = URL(string: urlString) {
                            viewModel.openMakerWorldBrowser(url: webURL)
                        } else {
                            drainPendingShare()
                        }
                    } else {
                        Task {
                            await viewModel.import3MF(from: url)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        drainPendingShare()
                        Task {
                            await viewModel.refreshAll()
                        }
                    }
                }
                .onReceive(refreshTimer) { _ in
                    guard scenePhase == .active else { return }
                    Task {
                        await viewModel.refreshPrinters()
                    }
                }
        }
    }

    /// Pick up any URL the share extension queued in the shared App Group and
    /// open it in the MakerWorld browser. Acts as the reliable hand-off path even
    /// if the extension couldn't launch the app directly.
    private func drainPendingShare() {
        guard let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let defaults = UserDefaults(suiteName: groupID),
              let urlString = defaults.string(forKey: "pendingShareURL"),
              let webURL = URL(string: urlString) else { return }
        defaults.removeObject(forKey: "pendingShareURL")
        viewModel.openMakerWorldBrowser(url: webURL)
    }
}
#endif
