import Foundation
import Vision

/// Serial on-device OCR of screenshots into the `ocr` FTS table.
final class OCR {
    static let shared = OCR()
    private let queue = DispatchQueue(label: "slock.ocr", qos: .background)
    private let lock = NSLock()
    private var pending = 0
    private let maxPending = 4

    func enqueue(image: CGImage, screenshotId: Int64) {
        lock.lock()
        // If OCR falls behind, drop frames rather than growing memory unbounded.
        guard pending < maxPending else { lock.unlock(); return }
        pending += 1
        lock.unlock()

        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            let text = self.recognize(image)
            guard !text.isEmpty else { return }
            Database.shared.run("INSERT INTO ocr(text, screenshot_id) VALUES(?,?)", [text, screenshotId])
        }
    }

    private func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log("ocr failed: \(error)")
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
