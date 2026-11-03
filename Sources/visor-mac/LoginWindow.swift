import AppKit
import VisorKit
import WebKit

/// Meta's own login page in a window this client owns, as Visor does it in a WebView. The person types their
/// credentials into Meta's page; the window catches the redirect to the app's URI and cancels it, so the page
/// that would spend the code is never loaded, and the code is exchanged at once.
final class LoginWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let request: MetaLogin.AuthorizeRequest
    private let onRedirect: (String) -> Void
    private var window: NSWindow!
    private var webView: WKWebView!
    private var caught = false

    /// Chrome on Android, the way Visor presents its WebView to Meta.
    static let userAgent = "Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    init(request: MetaLogin.AuthorizeRequest, onRedirect: @escaping (String) -> Void) {
        self.request = request
        self.onRedirect = onRedirect
    }

    func show() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 820), configuration: config)
        webView.customUserAgent = LoginWindow.userAgent
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Connexion Meta (visor-mac)"
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: URL(string: request.url)!))
    }

    private func isRedirect(_ url: URL?) -> Bool {
        url?.absoluteString.hasPrefix(MetaLogin.redirectUri + "?") == true
    }

    private func take(_ url: URL) {
        guard !caught else { return }
        caught = true
        window.orderOut(nil)
        onRedirect(url.absoluteString)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if isRedirect(navigationAction.request.url), let url = navigationAction.request.url {
            decisionHandler(.cancel)
            take(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if isRedirect(webView.url), let url = webView.url {
            webView.stopLoading()
            take(url)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A cancelled navigation to the redirect lands here too; anything else is worth a line.
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled, !caught { say("login page: \(error.localizedDescription)") }
    }

    func windowWillClose(_ notification: Notification) {
        if !caught { fail("the login window was closed before the login finished") }
    }
}

/// `visor-mac login --window`: never returns.
func runLoginWindow() -> Never {
    guard let tokens = store.tokens() else {
        fail("the Meta app tokens are missing. Set VISOR_META_HW_TOKEN and VISOR_META_AR_TOKEN, or write tokens.json in \(store.directory.path)")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let request = MetaLogin.authorizeRequest()
    let login = LoginWindow(request: request) { redirect in
        Task {
            do {
                let code = try MetaLogin.codeFromRedirect(redirect, expectedState: request.state)
                say("Caught the redirect before it loaded, exchanging the code")
                let frla = try await MetaLogin.exchangeCode(code)
                try store.saveFrla(frla)
                say("Checking it with Meta's AR login")
                _ = try await MetaLogin.exchangeFrla(frla, tokens: tokens)
                say("Logged in. The token is kept in \(store.directory.path)")
                exit(0)
            } catch {
                fail("\(error)")
            }
        }
    }
    say("A login window opens: log in to Meta there. It closes by itself once the login is done.")
    login.show()
    withExtendedLifetime(login) { app.run() }
    exit(0)
}
