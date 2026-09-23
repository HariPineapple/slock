import Foundation

/// Reads the active tab URL of the frontmost browser via AppleScript (needs Automation permission).
enum BrowserURL {
    struct Result { let url: String?; let title: String?; let isPrivate: Bool }

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]
    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let arc: Set<String> = ["company.thebrowser.Browser"]

    static func isBrowser(_ bundleId: String) -> Bool {
        chromium.contains(bundleId) || safari.contains(bundleId) || arc.contains(bundleId)
    }

    /// NSAppleScript is not thread-safe; run every script on this one queue.
    static let queue = DispatchQueue(label: "slock.applescript")
    private static var cache: [String: NSAppleScript] = [:]

    /// Must be called on `queue`.
    static func fetch(bundleId: String) -> Result? {
        let sep = "\u{1F}"
        let source: String
        if chromium.contains(bundleId) {
            source = """
            tell application id "\(bundleId)"
              if (count of windows) is 0 then return ""
              set w to front window
              return (URL of active tab of w) & "\(sep)" & (title of active tab of w) & "\(sep)" & (mode of w)
            end tell
            """
        } else if safari.contains(bundleId) {
            source = """
            tell application id "\(bundleId)"
              if (count of windows) is 0 then return ""
              set t to current tab of front window
              return (URL of t) & "\(sep)" & (name of t) & "\(sep)" & "normal"
            end tell
            """
        } else if arc.contains(bundleId) {
            source = """
            tell application id "\(bundleId)"
              if (count of windows) is 0 then return ""
              set t to active tab of front window
              return (URL of t) & "\(sep)" & (title of t) & "\(sep)" & "normal"
            end tell
            """
        } else {
            return nil
        }

        let script: NSAppleScript
        if let s = cache[bundleId] { script = s } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            cache[bundleId] = s
            script = s
        }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        if let error = error {
            // -1743 = user denied Automation permission; don't spam the log.
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code != -1743 && code != -1728 { log("applescript \(bundleId): \(error)") }
            return nil
        }
        guard let str = out.stringValue, !str.isEmpty else { return nil }
        let parts = str.components(separatedBy: sep)
        return Result(
            url: parts.first.flatMap { $0.isEmpty ? nil : $0 },
            title: parts.count > 1 ? parts[1] : nil,
            isPrivate: parts.count > 2 && parts[2] == "incognito"
        )
    }
}
