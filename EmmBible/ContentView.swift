import SwiftUI
import WebKit

struct ContentView: View {
    var body: some View {
        BibleWebView()
            .background(Color(red: 0.09, green: 0.095, blue: 0.10))
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct BibleWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "nativeShare")

        let bridge = WKUserScript(
            source: """
            (() => {
              navigator.share = ({ title = '', text = '', url = '' } = {}) => {
                window.webkit.messageHandlers.nativeShare.postMessage({ title, text, url });
                return Promise.resolve();
              };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(bridge)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.setURLSchemeHandler(BundledWebsiteHandler(), forURLScheme: "emmbible")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.keyboardDismissMode = .interactive
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.09, green: 0.095, blue: 0.10, alpha: 1)

        context.coordinator.loadReader(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nativeShare")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        #if DEBUG
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard ProcessInfo.processInfo.arguments.contains("--verify-reader") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak webView] in
                webView?.evaluateJavaScript("""
                JSON.stringify({
                  readerLoaded: !!document.querySelector('.reader-card'),
                  textLength: document.querySelector('.reader-card')?.textContent.length || 0,
                  stylesLoaded: [...document.styleSheets].some(sheet => sheet.href?.includes('/assets/')),
                  error: document.querySelector('.error-card')?.textContent || null
                })
                """) { result, error in
                    NSLog("Reader verification: %@", error.map { String(describing: $0) } ?? String(describing: result))
                }
            }
        }
        #endif

        func loadReader(in webView: WKWebView) {
            guard Bundle.main.url(forResource: "Website", withExtension: "bundle") != nil else {
                webView.loadHTMLString(Self.missingContentPage, baseURL: nil)
                return
            }

            webView.load(URLRequest(url: URL(string: "emmbible://reader/index.html")!))
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "nativeShare",
                  let payload = message.body as? [String: Any] else { return }

            let title = payload["title"] as? String ?? ""
            let text = payload["text"] as? String ?? ""
            let url = payload["url"] as? String ?? ""
            let content = [title, text, url]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !content.isEmpty else { return }

            DispatchQueue.main.async {
                guard let presenter = Self.topViewController() else { return }
                let activity = UIActivityViewController(activityItems: [content], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.maxY - 20,
                        width: 1,
                        height: 1
                    )
                }
                presenter.present(activity, animated: true)
            }
        }

        private static func topViewController() -> UIViewController? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            var controller = scene?.keyWindow?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }

        private static let missingContentPage = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="margin:0;background:#171819;color:#f4f1eb;font:17px -apple-system;padding:48px 24px">
          <h1>Աստվածաշունչ</h1><p>Հավելվածի ընթերցման ֆայլերը չեն գտնվել։</p>
        </body>
        """
    }
}

// Serve the offline site through one origin so modules and fetch() can load
// bundled resources without file:// cross-origin restrictions.
private final class BundledWebsiteHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.host == "reader",
              let root = Bundle.main.url(forResource: "Website", withExtension: "bundle")?
                .resolvingSymlinksInPath() else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let file = root.appendingPathComponent(url.path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        do {
            let data = try Data(contentsOf: file)
            let mimeTypes = ["html": "text/html", "js": "text/javascript",
                             "css": "text/css", "svg": "image/svg+xml"]
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": (mimeTypes[file.pathExtension] ?? "application/octet-stream") + "; charset=utf-8"]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Requests complete synchronously; no outstanding work remains to cancel.
    }
}
