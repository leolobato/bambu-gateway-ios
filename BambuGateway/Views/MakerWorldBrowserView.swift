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
        .onChange(of: initialURL) { _, newURL in
            browser.navigate(to: newURL)
        }
        .alert("Download unavailable", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "")
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
    @Published var errorMessage: String?

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

        let userScript = WKUserScript(
            source: Coordinator.downloadInterceptorJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "bg")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        context.coordinator.bind(webView)
        browser.webView = webView
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Coordinator

private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    let browser: BrowserState
    let onFileDownloaded: (String, Data) -> Void
    private var destinationURL: URL?
    private var fileName = ""
    private var observations: [NSKeyValueObservation] = []
    private var pendingBlobChunks: [String: (filename: String, parts: [String], total: Int)] = [:]

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
        let url = navigationAction.request.url?.absoluteString ?? "nil"
        let newWindow = navigationAction.targetFrame == nil
        NSLog("[MW][navAction] url=%@ shouldDownload=%d newWindow=%d navType=%ld", url, navigationAction.shouldPerformDownload, newWindow, navigationAction.navigationType.rawValue)
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
        let url = navigationResponse.response.url?.absoluteString ?? "nil"
        let mimeLog = navigationResponse.response.mimeType ?? "nil"
        let dispositionLog = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "nil"
        NSLog("[MW][navResponse] url=%@ mime=%@ disposition=%@", url, mimeLog, dispositionLog)

        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return .download
        }

        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        let downloadMimes: Set<String> = [
            "application/octet-stream",
            "binary/octet-stream",
            "application/zip",
            "application/x-zip",
            "application/x-zip-compressed",
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
        NSLog("[MW][didBecomeDownload-response]")
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        NSLog("[MW][didBecomeDownload-action]")
        download.delegate = self
    }

    // MARK: - WKUIDelegate

    // MakerWorld's download button opens in a new window (target="_blank" or window.open()).
    // Without this, WKWebView silently drops the request and nothing happens.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url?.absoluteString ?? "nil"
        NSLog("[MW][createWebView] url=%@ shouldDownload=%d", url, navigationAction.shouldPerformDownload)
        if navigationAction.targetFrame == nil, let reqURL = navigationAction.request.url {
            webView.load(URLRequest(url: reqURL))
        }
        return nil
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

    // MARK: - WKScriptMessageHandler (JS download interception)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bg", let body = message.body as? [String: Any] else { return }
        let type = body["type"] as? String ?? ""

        switch type {
        case "anchor-download":
            let href = body["href"] as? String ?? ""
            let fname = body["filename"] as? String ?? ""
            NSLog("[MW][js][anchor-download] filename=%@ href=%@", fname, href)

        case "http-download":
            let href = body["href"] as? String ?? ""
            let fname = body["filename"] as? String ?? "download.3mf"
            NSLog("[MW][js][http-download] filename=%@ href=%@", fname, href)
            guard let url = URL(string: href) else {
                Task { @MainActor in self.browser.errorMessage = "Invalid download URL." }
                return
            }
            Task.detached { [weak self] in
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        await MainActor.run {
                            self?.browser.errorMessage = "Download failed (HTTP \(http.statusCode))."
                        }
                        return
                    }
                    NSLog("[MW][http-download] success bytes=%d filename=%@", data.count, fname)
                    await MainActor.run {
                        self?.onFileDownloaded(fname, data)
                    }
                } catch {
                    NSLog("[MW][http-download] failed: %@", String(describing: error))
                    await MainActor.run {
                        self?.browser.errorMessage = "Download failed: \(error.localizedDescription)"
                    }
                }
            }

        case "fetch":
            let url = body["url"] as? String ?? ""
            NSLog("[MW][js][fetch] url=%@", url)

        case "fetch-download":
            let url = body["url"] as? String ?? ""
            let fname = body["filename"] as? String ?? ""
            let size = body["size"] as? Int ?? -1
            NSLog("[MW][js][fetch-download] url=%@ filename=%@ size=%d", url, fname, size)

        case "fetch-download-skipped":
            let url = body["url"] as? String ?? ""
            let ct = body["contentType"] as? String ?? ""
            NSLog("[MW][js][fetch-download-skipped] url=%@ ct=%@", url, ct)

        case "download-http-error":
            let status = body["status"] as? Int ?? 0
            let url = body["url"] as? String ?? ""
            NSLog("[MW][js][download-http-error] status=%d url=%@", status, url)
            let msg: String
            switch status {
            case 401, 403:
                msg = "MakerWorld requires you to be logged in to download this model. Tap “Log In” in the page and try again."
            case 404:
                msg = "The download isn't available for this model."
            default:
                msg = "MakerWorld download failed (HTTP \(status))."
            }
            Task { @MainActor in
                self.browser.errorMessage = msg
            }

        case "blob-start":
            let id = body["id"] as? String ?? ""
            let fname = body["filename"] as? String ?? "download.3mf"
            let total = body["total"] as? Int ?? 0
            NSLog("[MW][js][blob-start] id=%@ filename=%@ total=%d", id, fname, total)
            pendingBlobChunks[id] = (filename: fname, parts: Array(repeating: "", count: total), total: total)

        case "blob-chunk":
            let id = body["id"] as? String ?? ""
            let index = body["index"] as? Int ?? -1
            let chunk = body["data"] as? String ?? ""
            guard var entry = pendingBlobChunks[id], index >= 0, index < entry.total else { return }
            entry.parts[index] = chunk
            pendingBlobChunks[id] = entry

        case "blob-end":
            let id = body["id"] as? String ?? ""
            guard let entry = pendingBlobChunks.removeValue(forKey: id) else { return }
            let base64 = entry.parts.joined()
            guard let data = Data(base64Encoded: base64) else {
                NSLog("[MW][js][blob-end] id=%@ FAILED base64 decode", id)
                return
            }
            NSLog("[MW][js][blob-end] id=%@ filename=%@ bytes=%d", id, entry.filename, data.count)
            let name = entry.filename
            Task { @MainActor in
                self.onFileDownloaded(name, data)
            }

        case "error":
            NSLog("[MW][js][error] %@", (body["msg"] as? String) ?? "")

        default:
            NSLog("[MW][js][unknown] %@", type)
        }
    }

    // MARK: - JS source

    static let downloadInterceptorJS: String = """
    (function() {
        if (window.__bgDownloadInterceptorInstalled) { return; }
        window.__bgDownloadInterceptorInstalled = true;

        const post = (obj) => {
            try { window.webkit.messageHandlers.bg.postMessage(obj); } catch(e) {}
        };

        const CHUNK = 512 * 1024; // 512KB base64 chars per chunk

        const sendBlob = (blob, filename) => {
            const id = 'b' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
            const reader = new FileReader();
            reader.onerror = () => post({type:'error', msg:'FileReader failed for ' + filename});
            reader.onload = () => {
                const dataURL = reader.result;
                const comma = dataURL.indexOf(',');
                const base64 = dataURL.substring(comma + 1);
                const total = Math.ceil(base64.length / CHUNK);
                post({type:'blob-start', id:id, filename:filename, total:total});
                for (let i = 0; i < total; i++) {
                    post({type:'blob-chunk', id:id, index:i, data: base64.substring(i*CHUNK, (i+1)*CHUNK)});
                }
                post({type:'blob-end', id:id});
            };
            reader.readAsDataURL(blob);
        };

        const handleDownloadURL = (href, filename) => {
            post({type:'anchor-download', href: href || '', filename: filename || ''});
            if (!href) return;
            if (href.startsWith('blob:') || href.startsWith('data:')) {
                fetch(href).then(r => r.blob()).then(b => sendBlob(b, filename || 'download.3mf'))
                    .catch(err => post({type:'error', msg:'blob fetch failed: ' + err}));
                return;
            }
            // Hand the (already-signed) URL to native so URLSession can fetch cross-origin
            // without the CORS block that blob() via JS fetch hits.
            post({type:'http-download', href: href, filename: filename || 'download.3mf'});
        };

        // Monkey-patch HTMLAnchorElement.click
        const origAnchorClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function() {
            try {
                if (this.hasAttribute('download')) {
                    const href = this.href;
                    const fname = this.getAttribute('download') || '';
                    handleDownloadURL(href, fname);
                    return;
                }
            } catch(e) { post({type:'error', msg:'anchor click hook: '+e}); }
            return origAnchorClick.apply(this, arguments);
        };

        // Also intercept dispatchEvent for synthetic clicks on download anchors
        const origDispatch = EventTarget.prototype.dispatchEvent;
        EventTarget.prototype.dispatchEvent = function(ev) {
            try {
                if (ev && ev.type === 'click' && this instanceof HTMLAnchorElement && this.hasAttribute('download')) {
                    const href = this.href;
                    const fname = this.getAttribute('download') || '';
                    handleDownloadURL(href, fname);
                    return true;
                }
            } catch(e) {}
            return origDispatch.apply(this, arguments);
        };

        // MakerWorld downloads: fetch returns the 3MF file (or a signed URL).
        // Intercept the response and ship bytes directly to native.
        const isDownloadURL = (url) => {
            if (!url) return false;
            return /\\/design-service\\/instance\\/[^/]+\\/[^?]+\\?.*type=download/.test(url)
                || /\\.3mf(\\?|$)/i.test(url);
        };

        const origFetch = window.fetch;
        window.fetch = function() {
            const a = arguments[0];
            const url = (typeof a === 'string') ? a : (a && a.url);
            try { if (url) post({type:'fetch', url: url}); } catch(e) {}

            const p = origFetch.apply(this, arguments);
            if (!isDownloadURL(url)) return p;

            return p.then(async (response) => {
                try {
                    if (!response.ok) {
                        post({type:'download-http-error', status: response.status, url: url});
                        return response;
                    }
                    // MakerWorld's /f3mf endpoint returns JSON wrapping a signed URL, not the file.
                    // Skip JSON; the subsequent anchor.click() with the signed URL is handled elsewhere.
                    const ct = (response.headers.get('content-type') || '').toLowerCase();
                    if (ct.includes('application/json') || ct.includes('text/')) {
                        post({type:'fetch-download-skipped', url: url, contentType: ct});
                        return response;
                    }
                    const clone = response.clone();
                    const disposition = clone.headers.get('content-disposition') || '';
                    let filename = 'download.3mf';
                    const m = disposition.match(/filename\\*?=(?:UTF-8'')?["']?([^"';]+)/i);
                    if (m && m[1]) {
                        try { filename = decodeURIComponent(m[1]); } catch(_) { filename = m[1]; }
                    } else {
                        try {
                            const u = new URL(url, location.href);
                            const last = u.pathname.split('/').filter(Boolean).pop() || '';
                            if (/\\.3mf$/i.test(last)) filename = last;
                        } catch(_) {}
                    }
                    const blob = await clone.blob();
                    post({type:'fetch-download', url: url, filename: filename, size: blob.size});
                    sendBlob(blob, filename);
                } catch(err) {
                    post({type:'error', msg:'fetch intercept failed: '+err});
                }
                return response;
            });
        };
    })();
    """
}
