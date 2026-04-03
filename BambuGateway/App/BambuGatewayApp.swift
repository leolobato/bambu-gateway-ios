import Combine
import SwiftUI

@main
struct BambuGatewayApp: App {
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    await viewModel.refreshAll()
                }
                .onOpenURL { url in
                    if url.scheme == "bambugateway",
                       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let urlString = components.queryItems?.first(where: { $0.name == "url" })?.value,
                       let webURL = URL(string: urlString) {
                        viewModel.openMakerWorldBrowser(url: webURL)
                    } else {
                        Task {
                            await viewModel.import3MF(from: url)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
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
}
