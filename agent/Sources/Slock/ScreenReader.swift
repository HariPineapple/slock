import Foundation
import ImageIO
import Vision

/// Re-reads a saved screenshot with text positions, which the stored OCR text doesn't keep. In chat apps that lay
/// out bubbles by side (yours on the right), each message is tagged "Me:" or "Them:" so we know who said what.
enum ScreenReader {
    struct Reading {
        var header: String?   // the chat's name, for tagged chat screens
        var lines: [String]
        var tagged: Bool
    }

    private static let chatApps: Set<String> = ["Messages", "WhatsApp", "Telegram", "Signal", "Messenger", "Instagram"]
    private static let chatSites = ["web.whatsapp.com", "messenger.com", "instagram.com/direct", "web.telegram.org"]

    static func isChat(app: String?, url: String?) -> Bool {
        if let a = app, chatApps.contains(a) { return true }
        guard let u = url else { return false }
        return chatSites.contains { u.contains($0) }
    }

    /// `win` is the front window as "x,y,w,h" in 0-1 fractions of the screenshot (top-left origin), when known.
    /// Returns nil when the file is gone (deleted by retention).
    static func read(path: String, win: String?, app: String?, url: String?) -> Reading? {
        let fileURL = Paths.shots.appendingPathComponent(path)
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let frame = win.flatMap(parseFrame)
        if let f = frame {
            let w = Double(image.width), h = Double(image.height)
            let rect = CGRect(x: f.minX * w, y: f.minY * h, width: f.width * w, height: f.height * h).integral
            if let cropped = image.cropping(to: rect) { image = cropped }
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return Reading(lines: [], tagged: false) }
        // Vision's boxes are 0-1 with a bottom-left origin; sort into reading order.
        let obs: [(box: CGRect, text: String)] = (request.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), t.count >= 2 else { return nil }
            return (o.boundingBox, t)
        }.sorted {
            abs($0.box.midY - $1.box.midY) > 0.008 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX
        }

        // Sides only mean something inside the chat window itself, so tagging needs the window frame.
        guard frame != nil, isChat(app: app, url: url) else { return Reading(lines: obs.map(\.text), tagged: false) }

        // Where the conversation pane starts (left of it is the chat list). Messages centers the chat's name over
        // the pane, which gives its left edge; other apps get a typical sidebar width.
        let title = obs.first { $0.box.midY > 0.85 && $0.box.midX > 0.4 }
        let paneLeft = app == "Messages" && title != nil ? max(0, 2 * title!.box.midX - 1) : 0.3
        let paneWidth = 1 - paneLeft

        // Group chats put the sender's name in smaller text above their bubbles.
        let inPane = obs.filter { $0.box.midY <= 0.85 && $0.box.midX >= paneLeft }
        let heights = inPane.map(\.box.height).sorted()
        let bodyHeight = heights.isEmpty ? 0 : heights[heights.count / 2]

        var lines: [String] = []
        var last: (tag: String, box: CGRect)?
        var sender: String?
        for o in inPane {
            let b = o.box
            let text = o.text.replacingOccurrences(of: #"\s*\d+ Repl(y|ies)\s*[›>]?"#, with: "", options: .regularExpression)
            if isNoise(text) { continue }
            let tag: String
            if b.maxX > paneLeft + 0.85 * paneWidth { tag = "Me" }
            else if b.minX < paneLeft + 0.2 * paneWidth { tag = "Them" }
            else { last = nil; continue }                                   // centered timestamps, "Read" receipts
            if tag == "Them" && b.height < bodyHeight * 0.85 && text.split(separator: " ").count <= 4 {
                sender = text; last = nil; continue
            }
            // Lines on the same side that sit right under each other are one bubble.
            if let l = last, l.tag == tag, l.box.minY - b.maxY < b.height * 0.9, let prev = lines.popLast() {
                lines.append(prev + " " + text)
            } else {
                lines.append("\(tag == "Them" ? sender ?? "Them" : "Me"): \(text)")
            }
            last = (tag, b)
            if tag == "Me" { sender = nil }
        }
        // Chat names come with a trailing "›" or similar that OCR reads differently from shot to shot.
        let header = title.map { $0.text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        return Reading(header: header, lines: lines, tagged: true)
    }

    /// Chat app chrome and reactions rather than messages.
    private static func isNoise(_ t: String) -> Bool {
        let t = t.trimmingCharacters(in: .whitespaces)
        if !t.contains(where: \.isLetter) || (t.count <= 2 && t == t.uppercased()) { return true }  // reactions, avatar initials
        return ["Reply", "iMessage", "Text Message", "Delivered", "Read", "Edited", "Message"].contains(t)
    }

    private static func parseFrame(_ s: String) -> CGRect? {
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4, p[2] > 0.1, p[3] > 0.1 else { return nil }
        return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
    }
}
