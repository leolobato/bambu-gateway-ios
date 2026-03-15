import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            PrinterTab(viewModel: viewModel)
                .tabItem {
                    Label("Dashboard", systemImage: "cube")
                }
                .tag(0)

            PrintTab(viewModel: viewModel)
                .tabItem {
                    Label("Print", systemImage: "doc.badge.gearshape")
                }
                .tag(1)
        }
        .fullScreenCover(isPresented: $viewModel.isShowingMakerWorldBrowser) {
            if let url = viewModel.makerWorldBrowserURL {
                MakerWorldBrowserView(initialURL: url) { fileName, data in
                    Task {
                        await viewModel.importDownloaded3MF(fileName: fileName, data: data)
                    }
                }
            }
        }
    }
}
