import Foundation

/// Hourly cleanup of screenshots older than the configured retention window.
/// Text data (activity, OCR, shell, events) is kept forever.
final class Retention {
    private var timer: Timer?
    private let queue = DispatchQueue(label: "slock.retention", qos: .background)

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.queue.async { self?.sweep() }
        }
        queue.asyncAfter(deadline: .now() + 30) { self.sweep() }
    }

    private func sweep() {
        let days = State.shared.config.screenshotRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let fm = FileManager.default

        // Screenshots are stored in per-day folders, so delete whole folders past the cutoff.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let cutoffDay = f.string(from: cutoff)
        guard let dirs = try? fm.contentsOfDirectory(atPath: Paths.shots.path) else { return }
        var removed = 0
        for d in dirs where d.count == 10 && d < cutoffDay {
            try? fm.removeItem(at: Paths.shots.appendingPathComponent(d))
            removed += 1
        }
        // Keep the screenshot rows (with OCR text and context) but mark the file gone.
        Database.shared.run("UPDATE screenshots SET path='' WHERE ts < ? AND path != ''",
                            [f.date(from: cutoffDay)?.timeIntervalSince1970 ?? cutoff.timeIntervalSince1970])
        if removed > 0 { log("retention: removed \(removed) day folder(s) of screenshots before \(cutoffDay)") }
    }
}
