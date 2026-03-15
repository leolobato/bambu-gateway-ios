import SwiftUI
import WebKit

struct MakerWorldBrowserView: View {
    let initialURL: URL
    let onFileDownloaded: (String, Data) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var browser = BrowserState()
    @State private var isShowingURLInput = false
    @State private var urlInput = ""

    var body: some View {
        NavigationStack {
            BrowserWebView(
                initialURL: initialURL,
                browser: browser,
                onFileDownloaded: { fileName, data in
                    onFileDownloaded(fileName, data)
                    dismiss()
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Button {
                        urlInput = ""
                        isShowingURLInput = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(browser.displayHost)
                                .font(.subheadline)
                                .lineLimit(1)
                            if browser.isLoading {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 240)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { browser.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!browser.canGoBack)

                    Button { browser.goForward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!browser.canGoForward)

                    Spacer()

                    Button { browser.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .alert("Go to URL", isPresented: $isShowingURLInput) {
            TextField("https://makerworld.com/...", text: $urlInput)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            Button("Go") {
                var trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.contains("://") {
                    trimmed = "https://\(trimmed)"
                }
                if let url = URL(string: trimmed) {
                    browser.navigate(to: url)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Browser State

@MainActor
private final class BrowserState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?
    @Published var isLoading = false

    var displayHost: String {
        currentURL?.host() ?? "makerworld.com"
    }

    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func navigate(to url: URL) { webView?.load(URLRequest(url: url)) }
}

// MARK: - Web View

private struct BrowserWebView: UIViewRepresentable {
    let initialURL: URL
    let browser: BrowserState
    let onFileDownloaded: (String, Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser, onFileDownloaded: onFileDownloaded)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.bind(webView)
        browser.webView = webView
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Coordinator

private final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    let browser: BrowserState
    let onFileDownloaded: (String, Data) -> Void
    private var destinationURL: URL?
    private var fileName = ""
    private var observations: [NSKeyValueObservation] = []

    init(browser: BrowserState, onFileDownloaded: @escaping (String, Data) -> Void) {
        self.browser = browser
        self.onFileDownloaded = onFileDownloaded
    }

    func bind(_ webView: WKWebView) {
        observations = [
            webView.observe(\.isLoading) { [weak self] wv, _ in
                Task { @MainActor in self?.browser.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                Task { @MainActor in self?.browser.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                Task { @MainActor in self?.browser.canGoForward = wv.canGoForward }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                Task { @MainActor in self?.browser.currentURL = wv.url }
            },
        ]
    }

    // MARK: - Navigation actions (catches <a download> links)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload {
            return (.download, preferences)
        }
        return (.allow, preferences)
    }

    // MARK: - Navigation responses (catches binary/attachment responses)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return .download
        }

        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let downloadMimes: Set<String> = [
            "application/octet-stream",
            "application/zip",
            "application/vnd.ms-package.3dmanufacturing-3dmodel+xml"
        ]
        if downloadMimes.contains(mime) {
            return .download
        }

        if let url = navigationResponse.response.url,
           url.pathExtension.lowercased() == "3mf" {
            return .download
        }

        return .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if suggestedFilename.lowercased().hasSuffix(".3mf") {
            fileName = suggestedFilename
        } else if suggestedFilename.isEmpty {
            fileName = "download.3mf"
        } else {
            fileName = suggestedFilename
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + fileName)
        destinationURL = dest
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinationURL,
              let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        destinationURL = nil

        let name = fileName
        Task { @MainActor in
            onFileDownloaded(name, data)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = destinationURL {
            try? FileManager.default.removeItem(at: url)
        }
        destinationURL = nil
    }
}
