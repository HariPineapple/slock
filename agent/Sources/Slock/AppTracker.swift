import AppKit
import ApplicationServices

/// Tracks the foreground app, window title and browser URL; writes spans into `activity`.
final class AppTracker {
    private var timer: Timer?
    private var currentRowId: Int64?
    private var currentKey: String?
    private var fetchingURL = false
    private var lastURLResult: (bundleId: String, result: BrowserURL.Result?)?

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        let state = State.shared
        updateIdleAndLock()

        guard !state.suspended, !state.idle,
              let app = NSWorkspace.shared.frontmostApplication else {
            closeCurrent()
            return
        }
        let bundleId = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundleId
        var title = windowTitle(pid: app.processIdentifier)

        var url: String?
        var isPrivate = false
        if BrowserURL.isBrowser(bundleId) {
            if let last = lastURLResult, last.bundleId == bundleId, let r = last.result {
                url = r.url
                isPrivate = r.isPrivate
                if title == nil || title?.isEmpty == true { title = r.title }
            }
            refreshURL(bundleId: bundleId)
        } else {
            lastURLResult = nil
        }

        state.frontBundleId = bundleId
        state.frontApp = name
        state.frontTitle = title
        state.frontURL = url
        state.frontPrivate = isPrivate

        let now = Date().timeIntervalSince1970
        // Don't store titles/URLs for excluded contexts, but still count the time.
        let excluded = state.frontExcluded
        let storedTitle = excluded ? nil : title
        let storedURL = excluded ? nil : url
        let key = "\(bundleId)|\(storedTitle ?? "")|\(storedURL ?? "")"

        if key == currentKey, let id = currentRowId {
            Database.shared.run("UPDATE activity SET end=? WHERE id=?", [now, id])
        } else {
            closeCurrent()
            currentRowId = Database.shared.run(
                "INSERT INTO activity(start, end, bundle_id, app, window_title, url, domain) VALUES(?,?,?,?,?,?,?)",
                [now, now, bundleId, name, storedTitle, storedURL, storedURL.flatMap { URL(string: $0)?.host }]
            )
            currentKey = key
        }
    }

    private func closeCurrent() {
        if let id = currentRowId {
            Database.shared.run("UPDATE activity SET end=? WHERE id=?", [Date().timeIntervalSince1970, id])
        }
        currentRowId = nil
        currentKey = nil
    }

    /// Fire an async AppleScript URL fetch; the next tick picks up the result.
    private func refreshURL(bundleId: String) {
        guard !fetchingURL else { return }
        fetchingURL = true
        BrowserURL.queue.async { [weak self] in
            let r = BrowserURL.fetch(bundleId: bundleId)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetchingURL = false
                let changed = self.lastURLResult?.result?.url != r?.url || self.lastURLResult?.bundleId != bundleId
                self.lastURLResult = (bundleId, r)
                if changed { self.tick() }
            }
        }
    }

    private func windowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    private func updateIdleAndLock() {
        let state = State.shared

        let anyEvent = CGEventType(rawValue: ~0)!
        let idleSecs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        let nowIdle = idleSecs >= state.config.idleThresholdSeconds
        if nowIdle != state.idle {
            state.idle = nowIdle
            Database.shared.event(nowIdle ? "idle_start" : "idle_end", ["idle_seconds": Int(idleSecs)])
        }

        // Belt-and-braces lock detection in addition to the distributed notifications.
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
            if locked != state.screenLocked {
                state.screenLocked = locked
                Database.shared.event(locked ? "screen_locked" : "screen_unlocked")
            }
        }
    }
}
