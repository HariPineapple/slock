import Foundation

enum Paths {
    static let root: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".slock")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let shots = root.appendingPathComponent("shots")
    static let config = root.appendingPathComponent("config.json")
    static let shellLog = root.appendingPathComponent("shell.log")
    /// Presence of this file means recording is paused. Contents: optional unix timestamp to auto-resume at.
    static let pauseFlag = root.appendingPathComponent("paused")
    static let logFile = root.appendingPathComponent("agent.log")
}

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: Paths.logFile) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: Paths.logFile, atomically: false, encoding: .utf8)
    }
}

struct Config: Codable {
    var screenshotIntervalSeconds: Double = 10
    var idleThresholdSeconds: Double = 60
    var screenshotRetentionDays: Double = 30
    var screenshotMaxWidth: Int = 1920
    var jpegQuality: Double = 0.6
    /// Screenshots whose dHash differs from the previous one by <= this many bits are skipped.
    var duplicateHashDistance: Int = 3
    var ocrEnabled: Bool = true
    var excludedBundleIds: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass",
    ]
    /// Substrings; if the active URL contains any of these, no screenshot is taken.
    var excludedUrlPatterns: [String] = []
    var dashboardPort: Int = 8765
    /// Record typed text (needs Accessibility + Input Monitoring). Passwords in secure fields are never captured.
    var keystrokeCaptureEnabled: Bool = true
    /// Close off a typed segment after this many seconds without a keystroke.
    var keystrokeIdleFlushSeconds: Double = 4

    static func load() -> Config {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Paths.config),
           let cfg = try? decoder.decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if !FileManager.default.fileExists(atPath: Paths.config.path), let data = try? enc.encode(cfg) {
            try? data.write(to: Paths.config)
        }
        return cfg
    }

    // Tolerate partial config files: missing keys fall back to defaults.
    init() {}
    init(from decoder: Decoder) throws {
        let d = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenshotIntervalSeconds = (try? c.decode(Double.self, forKey: .screenshotIntervalSeconds)) ?? d.screenshotIntervalSeconds
        idleThresholdSeconds = (try? c.decode(Double.self, forKey: .idleThresholdSeconds)) ?? d.idleThresholdSeconds
        screenshotRetentionDays = (try? c.decode(Double.self, forKey: .screenshotRetentionDays)) ?? d.screenshotRetentionDays
        screenshotMaxWidth = (try? c.decode(Int.self, forKey: .screenshotMaxWidth)) ?? d.screenshotMaxWidth
        jpegQuality = (try? c.decode(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality
        duplicateHashDistance = (try? c.decode(Int.self, forKey: .duplicateHashDistance)) ?? d.duplicateHashDistance
        ocrEnabled = (try? c.decode(Bool.self, forKey: .ocrEnabled)) ?? d.ocrEnabled
        excludedBundleIds = (try? c.decode([String].self, forKey: .excludedBundleIds)) ?? d.excludedBundleIds
        excludedUrlPatterns = (try? c.decode([String].self, forKey: .excludedUrlPatterns)) ?? d.excludedUrlPatterns
        dashboardPort = (try? c.decode(Int.self, forKey: .dashboardPort)) ?? d.dashboardPort
        keystrokeCaptureEnabled = (try? c.decode(Bool.self, forKey: .keystrokeCaptureEnabled)) ?? d.keystrokeCaptureEnabled
        keystrokeIdleFlushSeconds = (try? c.decode(Double.self, forKey: .keystrokeIdleFlushSeconds)) ?? d.keystrokeIdleFlushSeconds
    }
}

/// Shared runtime state that multiple recorders read.
final class State {
    static let shared = State()
    var config = Config.load()
    var screenLocked = false
    var asleep = false
    var idle = false
    /// Latest known foreground context, maintained by AppTracker.
    var frontBundleId: String?
    var frontApp: String?
    var frontTitle: String?
    var frontURL: String?
    var frontPrivate = false

    var paused: Bool {
        guard let s = try? String(contentsOf: Paths.pauseFlag, encoding: .utf8) else { return false }
        if let until = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), until > 0,
           Date().timeIntervalSince1970 > until {
            try? FileManager.default.removeItem(at: Paths.pauseFlag)
            return false
        }
        return true
    }

    func setPaused(_ paused: Bool, until: Date? = nil) {
        if paused {
            let s = until.map { String($0.timeIntervalSince1970) } ?? ""
            try? s.write(to: Paths.pauseFlag, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: Paths.pauseFlag)
        }
    }

    /// True when nothing should be recorded right now.
    var suspended: Bool { paused || screenLocked || asleep }

    var frontExcluded: Bool {
        if let b = frontBundleId, config.excludedBundleIds.contains(b) { return true }
        if frontPrivate { return true }
        if let u = frontURL, config.excludedUrlPatterns.contains(where: { u.contains($0) }) { return true }
        return false
    }
}
