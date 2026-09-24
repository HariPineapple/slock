import AppKit
import Carbon.HIToolbox

/// Records typed text into the `keystrokes` table so it's searchable alongside OCR.
///
/// Privacy boundaries, matching the rest of Slock:
/// - macOS never delivers events from secure text fields (password boxes) to an event tap, and we also bail whenever
///   secure input is active, so passwords typed into any Mac app never reach the buffer.
/// - Nothing is recorded while paused, idle, asleep, the screen is locked, or the front app/URL is excluded
///   (password managers, private-browsing windows, `excludedBundleIds`/`excludedUrlPatterns`).
/// - Only whole typed segments are stored, tagged with the app and window, never individual timed keystrokes.
final class KeystrokeCapture {
    private var tap: CFMachPort?
    private var buffer = ""
    private var segmentApp: String?
    private var segmentWindow: String?
    private var segmentStart: Double = 0
    private var lastKey: Double = 0
    private var flushTimer: Timer?

    func start() {
        guard State.shared.config.keystrokeCaptureEnabled else { return }
        guard installTap() else {
            log("keystroke capture off: grant Accessibility and Input Monitoring, then restart Slock")
            return
        }
        // Flush a paused-mid-sentence buffer so a segment lands even if you stop typing without switching apps.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.buffer.isEmpty, Date().timeIntervalSince1970 - self.lastKey > State.shared.config.keystrokeIdleFlushSeconds {
                self.flush()
            }
        }
    }

    private func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, ctx in
            let me = Unmanaged<KeystrokeCapture>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .keyDown { me.handle(event) }
            else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
                    let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // A listen-only session tap: we observe keystrokes, never modify or block them.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ event: CGEvent) {
        let state = State.shared
        // Secure input means a password field is focused somewhere; don't record anything while it is.
        guard !state.suspended, !state.idle, !state.frontExcluded, !IsSecureEventInputEnabled() else {
            if !buffer.isEmpty { flush() }
            return
        }
        // A new app or window is a new segment.
        if state.frontApp != segmentApp || state.frontTitle != segmentWindow {
            if !buffer.isEmpty { flush() }
            segmentApp = state.frontApp
            segmentWindow = state.frontTitle
        }
        if buffer.isEmpty { segmentStart = Date().timeIntervalSince1970 }
        lastKey = Date().timeIntervalSince1970

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Delete, kVK_ForwardDelete:
            if !buffer.isEmpty { buffer.removeLast() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Enter usually sends a message or runs a line: end the segment there.
            flush()
        case kVK_Escape:
            buffer = ""
        default:
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            let s = String(utf16CodeUnits: chars, count: length)
            // Keep printable text only; control characters and lone modifiers add nothing to a transcript.
            if !s.isEmpty && s.allSatisfy({ !$0.isNewline && ($0 == " " || !$0.unicodeScalars.contains { $0.value < 0x20 }) }) {
                buffer += s
            }
        }
        if buffer.count >= 2000 { flush() }
    }

    private func flush() {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        // A couple of stray keys aren't worth a row.
        guard text.count >= 3 else { return }
        Database.shared.run(
            "INSERT INTO keystrokes(ts, app, window_title, text) VALUES(?,?,?,?)",
            [segmentStart, segmentApp, segmentWindow, text])
    }
}
