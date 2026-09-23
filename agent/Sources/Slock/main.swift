import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuTimer: Timer?
    private let tracker = AppTracker()
    private let capture = ScreenCapture()
    private let system = SystemEvents()
    private let shell = ShellIngest()
    private let retention = Retention()
    private let summarizer = Summarizer()
    private let server = DashboardServer()
    private let dashboard = DashboardWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one recorder at a time: hand off to an already-running copy and quit.
        // The newer process yields, so two copies starting at once don't both quit.
        let me = NSRunningApplication.current
        let myLaunch = me.launchDate ?? Date()
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me.processIdentifier
                && (($0.launchDate ?? .distantPast) < myLaunch
                    || ($0.launchDate == myLaunch && $0.processIdentifier < me.processIdentifier)) }) {
            other.activate()
            exit(0)
        }

        _ = Database.shared
        server.start()
        NSApp.mainMenu = buildMainMenu()
        requestPermissions()

        Database.shared.event("agent_start", ["version": "0.1"])
        tracker.start()
        capture.start()
        system.start()
        shell.start()
        retention.start()
        summarizer.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.rebuildMenu() }
        log("slock agent started; data in \(Paths.root.path)")

        // Launched at login by launchd with --background: stay in the menu bar. Otherwise open the window.
        if !CommandLine.arguments.contains("--background") {
            dashboard.show()
        }
    }

    // Clicking the app in the Dock/Finder/Spotlight while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show()
        Permissions.promptIfNeeded()
        return true
    }

    // Closing the window keeps recording in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Slock", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Slock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Slock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, "Slock"))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, "File"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu, "Edit"))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item("Reload", #selector(reloadDashboard), "r"))
        main.addItem(submenu(viewMenu, "View"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(windowMenu, "Window"))
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    @objc private func reloadDashboard() { dashboard.reload() }

    func applicationWillTerminate(_ notification: Notification) {
        Database.shared.event("agent_stop")
        server.stop()
    }

    private func requestPermissions() {
        if !Permissions.accessibility { log("accessibility not granted; window titles disabled") }
        if !Permissions.screenRecording { log("screen recording not granted; screenshots disabled") }
        // Never nag from a silent login launch; prompt once when the user opens the app.
        if !CommandLine.arguments.contains("--background") { Permissions.promptIfNeeded() }
    }

    private func rebuildMenu() {
        let state = State.shared
        let paused = state.paused
        statusItem.button?.image = NSImage(systemSymbolName: paused ? "record.circle" : "record.circle.fill",
                                           accessibilityDescription: "Slock")
        statusItem.button?.appearsDisabled = paused

        let menu = NSMenu()
        let status: String
        if paused { status = "Paused" }
        else if state.screenLocked { status = "Screen locked" }
        else if state.idle { status = "Idle" }
        else { status = "Recording" }
        let header = NSMenuItem(title: "Slock — \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !Permissions.screenRecording {
            menu.addItem(item("⚠︎ Allow Screen Recording…", #selector(grantScreen), ""))
        }
        if !Permissions.accessibility {
            menu.addItem(item("⚠︎ Allow Accessibility…", #selector(grantAccessibility), ""))
        }
        if !Permissions.screenRecording || !Permissions.accessibility {
            menu.addItem(item("Restart Slock (after granting)", #selector(relaunch), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Slock", #selector(openDashboard), "o"))
        menu.addItem(.separator())
        if paused {
            menu.addItem(item("Resume Recording", #selector(resume), "r"))
        } else {
            menu.addItem(item("Pause Recording", #selector(pause), "p"))
            menu.addItem(item("Pause for 1 Hour", #selector(pauseHour), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Data Folder", #selector(openFolder), ""))
        menu.addItem(item("Quit Slock", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openDashboard() {
        dashboard.show()
        Permissions.promptIfNeeded()
    }
    @objc private func pause() { State.shared.setPaused(true); Database.shared.event("paused"); rebuildMenu() }
    @objc private func pauseHour() {
        State.shared.setPaused(true, until: Date().addingTimeInterval(3600))
        Database.shared.event("paused", ["minutes": 60])
        rebuildMenu()
    }
    @objc private func resume() { State.shared.setPaused(false); Database.shared.event("resumed"); rebuildMenu() }
    @objc private func openFolder() { NSWorkspace.shared.open(Paths.root) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func grantScreen() { Permissions.openScreenRecordingSettings() }
    @objc private func grantAccessibility() { Permissions.openAccessibilitySettings() }

    /// Screen Recording only takes effect after a relaunch. Start a fresh copy once this one has exited.
    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
