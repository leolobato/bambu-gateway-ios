import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
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
                        self?.openApp(with: url)
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
                        self?.openApp(with: url)
                    } else {
                        self?.done()
                    }
                }
            }
            return
        }

        done()
    }

    private func openApp(with sharedURL: URL) {
        var components = URLComponents()
        components.scheme = "bambugateway"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]

        guard let appURL = components.url else {
            done()
            return
        }

        extensionContext?.open(appURL) { [weak self] _ in
            self?.done()
        }
    }

    private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
