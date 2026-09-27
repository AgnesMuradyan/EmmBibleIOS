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
        controller.add(context.coordinator, name: "savedQuotes")

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
        controller.addUserScript(WKUserScript(
            source: SavedQuotesScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "savedQuotes")
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
                  saveControls: document.querySelectorAll('.native-save-verse').length,
                  savedQuotesButton: !!document.querySelector('.native-saved-quotes'),
                  savedQuotesInHeader: !!document.querySelector('.header-actions .native-saved-quotes'),
                  savedQuotesInToolbar: !!document.querySelector('.toolbar-actions .native-saved-quotes'),
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
            guard let payload = message.body as? [String: Any] else { return }

            if message.name == "savedQuotes" {
                handleSavedQuotes(payload, in: message.webView)
                return
            }

            guard message.name == "nativeShare" else { return }

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

        private func handleSavedQuotes(_ payload: [String: Any], in webView: WKWebView?) {
            let action = payload["action"] as? String
            switch action {
            case "save":
                guard let quote = SavedQuote(payload: payload) else { return }
                var quotes = SavedQuoteStore.load()
                if let existingIndex = quotes.firstIndex(where: { $0.id == quote.id }) {
                    quotes[existingIndex] = quote
                } else {
                    quotes.insert(quote, at: 0)
                }
                SavedQuoteStore.save(quotes)
                sendSavedQuotes(quotes, to: webView)
            case "delete":
                guard let id = payload["id"] as? String else { return }
                let quotes = SavedQuoteStore.load().filter { $0.id != id }
                SavedQuoteStore.save(quotes)
                sendSavedQuotes(quotes, to: webView)
            default:
                sendSavedQuotes(SavedQuoteStore.load(), to: webView)
            }
        }

        private func sendSavedQuotes(_ quotes: [SavedQuote], to webView: WKWebView?) {
            guard let data = try? JSONEncoder().encode(quotes),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                webView?.evaluateJavaScript("window.__emmBibleSavedQuotes(\(json));")
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

private struct SavedQuote: Codable {
    let id: String
    let reference: String
    let text: String

    init?(payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let reference = payload["reference"] as? String,
              let text = payload["text"] as? String,
              !id.isEmpty, !reference.isEmpty, !text.isEmpty else { return nil }
        self.id = id
        self.reference = reference
        self.text = text
    }
}

private enum SavedQuoteStore {
    private static let key = "savedQuotes"

    static func load() -> [SavedQuote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let quotes = try? JSONDecoder().decode([SavedQuote].self, from: data) else { return [] }
        return quotes
    }

    static func save(_ quotes: [SavedQuote]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(quotes), forKey: key)
    }
}

private enum SavedQuotesScript {
    static let source = """
    (() => {
      let savedQuotes = [];
      const post = (message) => window.webkit.messageHandlers.savedQuotes.postMessage(message);
      const escape = (value) => value.replace(/[&<>\"]/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','\\"':'&quot;'}[character]));
      const showPanel = () => {
        let panel = document.querySelector('#saved-quotes-panel');
        if (!panel) {
          panel = document.createElement('section');
          panel.id = 'saved-quotes-panel';
          panel.innerHTML = '<header><strong>Պահված համարներ</strong><button type="button" aria-label="Փակել">×</button></header><div class="saved-quotes-list"></div>';
          panel.querySelector('header button').onclick = () => panel.classList.remove('visible');
          panel.querySelector('.saved-quotes-list').onclick = event => {
            const button = event.target.closest('[data-remove-quote]');
            if (button) post({ action: 'delete', id: button.dataset.removeQuote });
          };
          document.body.append(panel);
        }
        panel.classList.add('visible');
        render();
        post({ action: 'list' });
      };
      const render = () => {
        const list = document.querySelector('#saved-quotes-panel .saved-quotes-list');
        if (!list) return;
        list.innerHTML = savedQuotes.length
          ? savedQuotes.map(quote => `<article><button type="button" data-remove-quote="${escape(quote.id)}" aria-label="Ջնջել">×</button><strong>${escape(quote.reference)}</strong><p>${escape(quote.text)}</p></article>`).join('')
          : '<p class="saved-empty">Դեռ պահված համարներ չկան։</p>';
      };
      window.__emmBibleSavedQuotes = quotes => {
        savedQuotes.splice(0, savedQuotes.length, ...quotes);
        render();
        document.querySelectorAll('.native-save-verse').forEach(button => {
          button.classList.toggle('saved', savedQuotes.some(quote => quote.id === button.dataset.quoteId));
          button.title = button.classList.contains('saved') ? 'Պահված է' : 'Պահել համարը';
        });
      };
      const addControls = () => {
        document.querySelectorAll('.verse-row').forEach(row => {
          const actions = row.querySelector('.verse-actions');
          if (!actions) return;
          const book = document.querySelector('.chapter-header h1')?.textContent.trim() || '';
          const verse = row.dataset.verse || '';
          const verseBody = row.querySelector('.verse-body');
          const cleanBody = verseBody?.cloneNode(true);
          cleanBody?.querySelectorAll('.xref').forEach(reference => reference.remove());
          const text = cleanBody?.textContent.trim() || '';
          const verseReference = row.querySelector('.verse-number')?.title.match(/[0-9]+:[0-9]+/)?.[0] || `:${verse}`;
          const id = `${book}|${verseReference}`;
          const button = actions.querySelector('.native-save-verse') || document.createElement('button');
          if (!button.parentElement) {
            button.type = 'button'; button.className = 'native-save-verse'; button.textContent = '♡';
            actions.append(button);
          }
          button.dataset.quoteId = id;
          button.dataset.reference = `${book} ${verseReference}`;
          button.dataset.quoteText = text;
          button.classList.toggle('saved', savedQuotes.some(quote => quote.id === id));
          button.title = button.classList.contains('saved') ? 'Պահված է' : 'Պահել համարը';
          button.onclick = event => {
            event.stopPropagation();
            const isSaved = savedQuotes.some(quote => quote.id === button.dataset.quoteId);
            post(isSaved
              ? { action: 'delete', id: button.dataset.quoteId }
              : { action: 'save', id: button.dataset.quoteId, reference: button.dataset.reference, text: button.dataset.quoteText });
          };
        });
        document.querySelectorAll('.toolbar-actions .native-saved-quotes').forEach(button => button.remove());
        const headerActions = document.querySelector('.header-actions');
        if (headerActions && !headerActions.querySelector('.native-saved-quotes')) {
          const button = document.createElement('button');
          button.type = 'button'; button.className = 'icon-button native-saved-quotes'; button.title = 'Պահված համարներ'; button.setAttribute('aria-label', 'Պահված համարներ'); button.textContent = '♡';
          button.onclick = showPanel; headerActions.prepend(button);
        }
      };
      const style = document.createElement('style');
      style.textContent = `.native-save-verse{font:24px -apple-system;color:#a15f50}.native-save-verse.saved{color:#c54343}.native-saved-quotes{font:24px -apple-system;color:var(--accent-strong)}#saved-quotes-panel{position:fixed;z-index:9999;inset:10% 7%;display:none;overflow:auto;padding:20px;border:1px solid #b99362;border-radius:16px;background:#1c1a1a;color:#f4f1eb;box-shadow:0 15px 50px #0008}#saved-quotes-panel.visible{display:block}#saved-quotes-panel header{display:flex;justify-content:space-between;align-items:center;font-size:19px}#saved-quotes-panel header button,#saved-quotes-panel article button{border:0;background:transparent;color:inherit;font-size:25px}.saved-quotes-list article{position:relative;margin-top:16px;padding:14px 40px 14px 0;border-top:1px solid #ffffff22}.saved-quotes-list article button{position:absolute;right:0;top:10px;color:#d67b72}.saved-quotes-list article strong{display:block;margin-bottom:8px;color:#d8b782}.saved-quotes-list article p{margin:0;line-height:1.5}.saved-empty{color:#bdb7ad}`;
      document.head.append(style);
      new MutationObserver(addControls).observe(document.documentElement, { childList: true, subtree: true });
      addControls(); post({ action: 'list' });
    })();
    """
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
