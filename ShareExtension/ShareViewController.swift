import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    /// Key under which the shared URL is queued in the shared App Group, to be
    /// drained by the main app on launch/activation.
    static let pendingURLDefaultsKey = "pendingShareURL"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            done()
            return
        }

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                DispatchQueue.main.async {
                    if let url = data as? URL {
                        self?.deliver(url)
                    } else {
                        self?.done()
                    }
                }
            }
            return
        }

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] data, _ in
                DispatchQueue.main.async {
                    if let text = data as? String, let url = URL(string: text) {
                        self?.deliver(url)
                    } else {
                        self?.done()
                    }
                }
            }
            return
        }

        done()
    }

    /// Queue the shared URL in the App Group (the guaranteed hand-off channel),
    /// then bring the host app forward. Even if the launch is ever blocked, the
    /// app picks up the queued URL the next time it becomes active.
    private func deliver(_ sharedURL: URL) {
        queueForApp(sharedURL)
        launchApp()
    }

    private func queueForApp(_ sharedURL: URL) {
        guard let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let defaults = UserDefaults(suiteName: groupID) else { return }
        defaults.set(sharedURL.absoluteString, forKey: Self.pendingURLDefaultsKey)
    }

    private func launchApp() {
        var components = URLComponents()
        components.scheme = "bambugateway"
        components.host = "open"
        guard let appURL = components.url else {
            done()
            return
        }

        // Launching the containing app from an extension has no public API, but
        // `UIApplication.openURL:options:completionHandler:` works when invoked on
        // the shared application obtained via the runtime. (The legacy single-arg
        // `openURL:` and the responder-chain scene object are both ignored on
        // iOS 18; only the modern selector on UIApplication foregrounds the app.)
        if let app = sharedApplication() {
            let selector = NSSelectorFromString("openURL:options:completionHandler:")
            if app.responds(to: selector) {
                typealias OpenFn = @convention(c)
                    (NSObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let fn = unsafeBitCast(app.method(for: selector), to: OpenFn.self)
                fn(app, selector, appURL as NSURL, NSDictionary(), nil)
                completeAfterLaunch()
                return
            }
        }

        // Last-resort fallback; the URL is already queued in the App Group, so the
        // app will pick it up whenever it next becomes active.
        extensionContext?.open(appURL) { [weak self] _ in
            self?.completeAfterLaunch()
        }
    }

    /// `UIApplication.shared` is unavailable to app extensions at compile time,
    /// but the singleton exists at runtime — fetch it dynamically.
    private func sharedApplication() -> NSObject? {
        guard let appClass = NSClassFromString("UIApplication") as AnyObject as? NSObjectProtocol else { return nil }
        let selector = NSSelectorFromString("sharedApplication")
        guard appClass.responds(to: selector) else { return nil }
        return appClass.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// Give the system a moment to launch the host app before tearing down the
    /// extension; completing immediately can cancel the launch.
    private func completeAfterLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.done()
        }
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
