import AppKit
import WebKit

/// Native window hosting the dashboard. Shows a Dock icon while open, hides back to menu-bar-only when closed.
final class DashboardWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow?
    private var webView: WKWebView!
    private var retryCount = 0

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(State.shared.config.dashboardPort)/")! }

    func show() {
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        retryCount = 0
        webView?.load(URLRequest(url: webView.url ?? baseURL))
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Tell the page it's running inside the app window so CSS can adjust.
        let marker = WKUserScript(source: "document.documentElement.classList.add('in-app')",
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(marker)

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Slock"
        // Title bar blends into the page background (matches --bg in style.css).
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x10 / 255, alpha: 1)
                : NSColor(srgbRed: 0xf7 / 255, green: 0xf7 / 255, blue: 0xf5 / 255, alpha: 1)
        }
        w.minSize = NSSize(width: 720, height: 500)
        w.contentView = webView
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("SlockDashboard")
        if !w.setFrameUsingName("SlockDashboard") { w.center() }
        window = w

        webView.load(URLRequest(url: baseURL))
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar only; recording keeps going.
        NSApp.setActivationPolicy(.accessory)
    }

    // The server may still be starting up right after launch; retry for a few seconds.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard retryCount < 20 else {
            webView.loadHTMLString("""
            <body style="font:15px -apple-system;color:#888;display:flex;align-items:center;justify-content:center;height:90vh">
            Dashboard server isn't responding. Check ~/.slock/web.stderr.log, then press ⌘R.</body>
            """, baseURL: nil)
            return
        }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            webView.load(URLRequest(url: self.baseURL))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryCount = 0
    }

    // Anything that isn't the local dashboard opens in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, isExternal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        if scheme == "about" || scheme == "data" { return false }
        return !(url.host == "127.0.0.1" && url.port == State.shared.config.dashboardPort)
    }
}

/// Runs the Python dashboard server as a child process for as long as the app is running.
final class DashboardServer {
    private var process: Process?
    private var stopping = false
    private var failures = 0

    func start() {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("web/server.py"),
              FileManager.default.fileExists(atPath: script.path) else {
            log("dashboard server script missing from app bundle")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, String(State.shared.config.dashboardPort),
                       String(ProcessInfo.processInfo.processIdentifier)]
        let errLog = Paths.root.appendingPathComponent("web.stderr.log")
        if !FileManager.default.fileExists(atPath: errLog.path) {
            FileManager.default.createFile(atPath: errLog.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: errLog) {
            h.seekToEndOfFile()
            p.standardError = h
            p.standardOutput = h
        }
        p.terminationHandler = { [weak self] proc in
            guard let self = self, !self.stopping else { return }
            self.failures += 1
            // Back off (3s, 6s, … up to 60s) so a persistent failure such as a busy port doesn't spin.
            let delay = min(60.0, 3.0 * Double(self.failures))
            log("dashboard server exited (\(proc.terminationStatus)); restarting in \(Int(delay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.start() }
        }
        do {
            try p.run()
            process = p
        } catch {
            log("could not start dashboard server: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }
}
