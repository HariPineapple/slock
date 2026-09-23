import AppKit
import ApplicationServices

/// Checks privacy permissions without prompting, and prompts at most once per install.
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Note: after granting Screen Recording, this only turns true once the app is relaunched.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    private static let promptedKey = "permissionsPrompted"

    /// Shows the system prompts only the first time; later launches just report status in the menu bar.
    static func promptIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)
        if !accessibility {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        if !screenRecording {
            CGRequestScreenCaptureAccess()
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
