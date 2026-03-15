import SwiftUI

@main
struct BambuGatewayApp: App {
    @StateObject private var viewModel = AppViewModel()

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
        }
    }
}
