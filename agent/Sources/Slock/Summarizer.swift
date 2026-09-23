import Foundation
import FoundationModels

/// Writes AI summaries of your activity with Apple's on-device model (nothing leaves the Mac).
/// - Every 30-minute block with activity gets a title, one-two sentence summary and category.
///   "Summarize now" adds an entry for the time since the last one up to that minute; the rest follows when the half-hour ends.
/// - Each day gets an overview (headline, paragraph, highlights) built from its blocks.
/// Results go into the `summaries` table; the dashboard can request a refresh via ~/.slock/summarize-request.
final class Summarizer {
    static let blockSeconds: Double = 1800
    static let categories = ["coding", "writing", "communication", "research", "browsing",
                             "entertainment", "meetings", "admin", "other"]
    private static let minActiveSeconds: Double = 180
    private static let dayRefreshSeconds: Double = 3600
    private static let backfillDays = 7

    private var timer: Timer?
    private var running = false
    private let requestFile = Paths.root.appendingPathComponent("summarize-request")
    /// Written by the dashboard when you open an entry: the entry's start timestamp.
    private let detailsRequestFile = Paths.root.appendingPathComponent("details-request")
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let instructions = """
    You summarize a person's computer activity log for their private journal. Write in second person ("You ..."). \
    Be concrete: name the projects, websites, documents, people and tools that appear in the log. \
    Use the text that was on screen to say what they were actually reading, writing or talking about: who they \
    messaged and about what, what the page or document was about, what the code or error was. \
    Never invent details that are not in the log. Keep it neutral and factual.
    """

    func start() {
        Database.shared.exec("""
        CREATE TABLE IF NOT EXISTS summaries(
            id INTEGER PRIMARY KEY, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
            title TEXT, summary TEXT, category TEXT, detail_json TEXT, model TEXT, partial INTEGER DEFAULT 0,
            created REAL NOT NULL, UNIQUE(kind, start));
        CREATE INDEX IF NOT EXISTS summaries_start ON summaries(start);
        UPDATE summaries SET partial = 0 WHERE partial = 1;
        """)
        // Poll often for dashboard requests; the backlog itself only needs a pass every few minutes.
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            ticks += 1
            if !self.running, let s = try? String(contentsOf: self.detailsRequestFile, encoding: .utf8),
               let start = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try? FileManager.default.removeItem(at: self.detailsRequestFile)
                self.runDetails(start: start)
            } else if let date = self.takeRequest() {
                self.run(forceDate: date)
            } else if ticks % 100 == 1 {  // ~every 5 minutes, and once shortly after launch
                self.run(forceDate: nil)
            }
        }
    }

    // MARK: - Scheduling

    private func takeRequest() -> String? {
        guard let s = try? String(contentsOf: requestFile, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: requestFile)
        let d = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? dayFormatter.string(from: Date()) : d
    }

    private func run(forceDate: String?) {
        guard !running else {
            // Busy: re-queue the request so it isn't lost.
            if let d = forceDate { try? d.write(to: requestFile, atomically: true, encoding: .utf8) }
            return
        }
        guard !State.shared.paused else { return }
        guard case .available = SystemLanguageModel.default.availability else {
            if case .unavailable(let reason) = SystemLanguageModel.default.availability {
                setStatus("unavailable", "Apple Intelligence isn't available: \(reason)")
            }
            return
        }
        running = true
        Task.detached(priority: .utility) {
            await self.work(forceDate: forceDate)
            await MainActor.run { self.running = false }
        }
    }

    private func runDetails(start: Double) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        running = true
        Task.detached(priority: .userInitiated) {
            await self.writeDetails(start: start)
            await MainActor.run { self.running = false }
        }
    }

    private func work(forceDate: String?) async {
        setStatus("running", nil)
        let now = Date().timeIntervalSince1970
        var touchedDays = Set<Double>()

        // 1) Blocks: backfill unsummarized time in completed half-hours; on request also summarize the one in progress.
        let earliest = dayStart(now) - Double(Self.backfillDays) * 86400
        var candidates: [Double] = []
        let rows = Database.shared.query("""
            SELECT DISTINCT CAST(start / ? AS INTEGER) * ? FROM activity WHERE end > ? ORDER BY 1
            """, [Self.blockSeconds, Self.blockSeconds, earliest])
        for r in rows {
            guard let s = (r[0] as? Int64).map(Double.init) ?? (r[0] as? Double) else { continue }
            candidates.append(s)
        }
        if let d = forceDate, let day = dayFormatter.date(from: d)?.timeIntervalSince1970 {
            // Blocks can straddle an activity row that started in the previous block; include every block of the day.
            var t = day
            while t < min(day + 86400, now) { candidates.append(floor(t / Self.blockSeconds) * Self.blockSeconds); t += Self.blockSeconds }
        }

        // A half-hour can be split into several entries: each "Summarize now" adds one covering the time since the
        // previous entry up to that minute, and when the half-hour ends the rest of it gets its own entry.
        for block in Set(candidates).sorted() {
            let blockEnd = block + Self.blockSeconds
            let complete = blockEnd <= now
            let inForcedDay = forceDate.map { dayFormatter.string(from: Date(timeIntervalSince1970: block)) == $0 } ?? false
            guard complete || inForcedDay else { continue }

            // Entries merged across the half-hour mark can start in an earlier block.
            let covered = max(block, Database.shared.query(
                "SELECT MAX(end) FROM summaries WHERE kind='block' AND start < ? AND end > ?", [blockEnd, block]
            ).first?[0] as? Double ?? block)
            let end = min(blockEnd, now)
            guard end - covered >= 60 else { continue }

            // Same screen as the entry right before: rewrite that entry to cover both instead of adding a new one.
            var start = covered
            if let prev = Database.shared.query(
                "SELECT start FROM summaries WHERE kind='block' AND end BETWEEN ? AND ? ORDER BY start DESC LIMIT 1",
                [covered - 1, covered + 1]).first?[0] as? Double,
               sameScreen(prev, covered, covered, end) {
                start = prev
            }

            if await summarizeBlock(start: start, end: end, manual: !complete) {
                touchedDays.insert(dayStart(block))
            }
        }

        // 2) Day overviews.
        var days = touchedDays
        if let d = forceDate, let day = dayFormatter.date(from: d)?.timeIntervalSince1970 { days.insert(day) }
        // Also refresh today hourly and finalize yesterday once it's over.
        days.insert(dayStart(now))
        days.insert(dayStart(now) - 86400)
        for day in days.sorted() {
            let existing = Database.shared.query("SELECT created FROM summaries WHERE kind='day' AND start=?", [day]).first
            let created = existing?[0] as? Double ?? 0
            let newestBlock = Database.shared.query(
                "SELECT MAX(created) FROM summaries WHERE kind='block' AND start >= ? AND start < ?", [day, day + 86400]
            ).first?[0] as? Double ?? 0
            guard newestBlock > 0 else { continue }
            let forced = forceDate.flatMap { dayFormatter.date(from: $0)?.timeIntervalSince1970 } == day
            let isToday = day == dayStart(now)
            let stale = newestBlock > created && (!isToday || now - created > Self.dayRefreshSeconds || created < day)
            let unfinalized = !isToday && created < day + 86400
            if forced || stale || unfinalized {
                await summarizeDay(day)
            }
        }
        setStatus("idle", nil)
    }

    // MARK: - Blocks

    /// Returns true when a summary row was written.
    /// `manual` entries come from "Summarize now" and cover the time up to that minute.
    private func summarizeBlock(start: Double, end: Double, manual: Bool) async -> Bool {
        let acts = Database.shared.query("""
            SELECT app, window_title, url, domain, MAX(start, ?) AS s, MIN(end, ?) AS e
            FROM activity WHERE end > ? AND start < ?
            """, [start, end, start, end])
        var byApp: [String: Double] = [:]
        var byWindow: [String: Double] = [:]
        var active: Double = 0
        for r in acts {
            let app = r[0] as? String ?? "?"
            let dur = (r[5] as? Double ?? 0) - (r[4] as? Double ?? 0)
            guard dur > 0 else { continue }
            active += dur
            byApp[app, default: 0] += dur
            let title = (r[1] as? String).map { String($0.prefix(90)) } ?? ""
            let host = (r[3] as? String) ?? ""
            if !title.isEmpty || !host.isEmpty {
                byWindow["[\(app)] \(title)\(host.isEmpty ? "" : " — \(host)")", default: 0] += dur
            }
        }
        guard active >= Self.minActiveSeconds || manual else { return false }
        guard active > 0 else { return false }

        let shell = Database.shared.query("SELECT cmd FROM shell WHERE ts >= ? AND ts < ? ORDER BY ts LIMIT 15", [start, end])
            .compactMap { ($0[0] as? String).map { String($0.split(separator: "\n").first ?? "").prefix(80) } }
        let screens = screenText(start: start, end: end)

        let topApps = byApp.sorted { $0.value > $1.value }.prefix(8)
        var lines = ["Time: \(clock(start))–\(clock(end)) (\(Int(active / 60)) active minutes)", "Apps used:"]
        lines += topApps.map { "- \($0.key): \(minutes($0.value))" }
        let windows = byWindow.sorted { $0.value > $1.value }.prefix(20)
        if !windows.isEmpty {
            lines.append("Windows and pages (by time spent):")
            lines += windows.map { "- \($0.key) (\(minutes($0.value)))" }
        }
        if !shell.isEmpty {
            lines.append("Terminal commands:")
            lines += shell.map { "- \($0)" }
        }

        let detail: [String: Any] = [
            "active_seconds": active,
            "apps": topApps.map { ["name": $0.key, "seconds": $0.value] },
        ]

        var title: String
        var summary: String
        var category: String
        var model = "apple-on-device"
        do {
            let c = try await generateFitting(base: "Activity log:\n" + lines.joined(separator: "\n"), screens: screens,
                                              schema: Self.blockSchema)
            title = try c.value(String.self, forProperty: "title")
            summary = try c.value(String.self, forProperty: "summary")
            category = try c.value(String.self, forProperty: "category")
        } catch {
            // Guardrail refusals, context overflow etc.: store a plain factual fallback so we don't retry forever.
            log("summary for block \(clock(start)) fell back: \(error)")
            let names = topApps.prefix(3).map { "\($0.key) (\(minutes($0.value)))" }
            title = "Mostly \(topApps.first?.key ?? "idle")"
            summary = "You used " + names.joined(separator: ", ") + "."
            category = "other"
            model = "fallback"
        }
        if !Self.categories.contains(category) { category = "other" }

        Database.shared.run("""
            INSERT OR REPLACE INTO summaries(kind, start, end, title, summary, category, detail_json, model, partial, created)
            VALUES('block', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [start, end, title, summary, category, json(detail), model, 0, Date().timeIntervalSince1970])
        return true
    }

    // MARK: - Details

    /// The expanded view of one entry: specific points plus each conversation (who, about what, who said what),
    /// read from that entry's screenshots with text positions. Stored under "details" in the entry's detail_json;
    /// rewriting the entry (e.g. merging) drops it, so it's regenerated on the next open.
    private func writeDetails(start: Double) async {
        guard let row = Database.shared.query(
            "SELECT end, detail_json FROM summaries WHERE kind='block' AND start=?", [start]).first,
              let end = row[0] as? Double else { return }
        Database.shared.setMeta("details_status", json(["start": start, "state": "running"]) ?? "{}")
        defer { Database.shared.setMeta("details_status", json(["start": start, "state": "idle"]) ?? "{}") }

        let (screens, chats) = detailScreens(start: start, end: end)
        var points: [String] = [], conversations: [[String: Any]] = []
        var failed = 0

        // Chats with known sides: the transcript comes straight from the screen; the model only says what it's about.
        for chat in chats.prefix(4) {
            var about = ""
            if let c = try? await generate(prompt: "Chat \"\(chat.name)\". Lines are \"Sender: message\"; \"Me\" is the person, "
                                            + "\"Them\" is someone else in the chat:\n"
                                            + chat.messages.suffix(30).joined(separator: "\n"), schema: Self.chatSchema) {
                about = (try? c.value(String.self, forProperty: "about")) ?? ""
            }
            conversations.append(["with": chat.name, "about": about, "sided": true,
                                  "messages": chat.messages.suffix(30).map {
                                      $0.hasPrefix("Me: ") ? "You: " + $0.dropFirst(4) : $0 }])
        }

        // Everything else: ask the model for specifics (and for chats we couldn't place, its best reading of them).
        for chunk in chunked(screens, maxChars: 6000).prefix(3) {
            do {
                let c = try await generateDetails(chunk)
                points += try c.value([String].self, forProperty: "points")
                for conv in try c.value([GeneratedContent].self, forProperty: "conversations") {
                    let with = try conv.value(String.self, forProperty: "with")
                    let msgs = try conv.value([String].self, forProperty: "messages")
                    // The same chat often spans chunks; keep one entry per person, messages in order.
                    if let i = conversations.firstIndex(where: { ($0["with"] as? String)?.lowercased() == with.lowercased() }) {
                        if conversations[i]["sided"] == nil {
                            conversations[i]["messages"] = (conversations[i]["messages"] as? [String] ?? []) + msgs
                        }
                    } else {
                        conversations.append(["with": with, "about": try conv.value(String.self, forProperty: "about"),
                                              "messages": msgs])
                    }
                }
            } catch {
                log("details for \(clock(start)) failed: \(error)")
                failed += 1
            }
        }

        // The small model tends to repeat itself and trail off; keep distinct, complete-looking lines.
        points = distinct(points).filter { $0.split(separator: " ").count >= 3 }
        conversations = conversations.compactMap { c in
            var c = c
            c["messages"] = distinct(c["messages"] as? [String] ?? []).filter { m in
                m.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces).count >= 2 } ?? false
            }
            c.removeValue(forKey: "sided")
            return (c["messages"] as? [String])?.isEmpty == false ? c : nil
        }

        var detail = (row[1] as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var d: [String: Any] = ["points": points, "conversations": conversations, "created": Date().timeIntervalSince1970]
        if screens.isEmpty && chats.isEmpty { d["error"] = "No screen text was recorded for this stretch." }
        else if points.isEmpty && conversations.isEmpty && failed > 0 { d["error"] = "The on-device model couldn't read this one." }
        detail["details"] = d
        Database.shared.run("UPDATE summaries SET detail_json=? WHERE kind='block' AND start=?", [json(detail), start])
    }

    private func distinct(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Re-reads each screen in the range that shows something new (evenly sampled, max 20). Chat screens where we
    /// know which side each message is on come back as per-chat transcripts; the rest as text for the model.
    private func detailScreens(start: Double, end: Double) -> (screens: [String], chats: [(name: String, messages: [String])]) {
        let rows = Database.shared.query("""
            SELECT s.ts, s.app, s.window_title, s.url, s.path, s.win, o.text
            FROM screenshots s LEFT JOIN ocr o ON o.screenshot_id = s.id WHERE s.ts >= ? AND s.ts < ? ORDER BY s.ts
            """, [start, end])
        // Pick screenshots whose stored text adds something, so a static screen is read once.
        var seen = Set<String>()
        let fresh = rows.filter { r in ocrLines(r[6] as? String).filter { seen.insert($0.lowercased()).inserted }.count >= 2 }
        let n = min(fresh.count, 20)
        let picked = (0..<n).map { fresh[$0 * fresh.count / n] }

        var shown = Set<String>()
        var screens: [String] = []
        var chats: [(name: String, messages: [String])] = []
        for r in picked {
            let app = r[1] as? String
            let reading = ScreenReader.read(path: r[4] as? String ?? "", win: r[5] as? String, app: app, url: r[3] as? String)
                ?? ScreenReader.Reading(lines: ocrLines(r[6] as? String), tagged: false)
            if reading.tagged {
                guard !reading.lines.isEmpty else { continue }
                let name = reading.header ?? (r[2] as? String) ?? app ?? "Chat"
                if let i = chats.firstIndex(where: { $0.name == name }) {
                    // Scrolling shows the same bubbles again; add only the ones not seen yet in this chat.
                    let have = Set(chats[i].messages.map { $0.lowercased() })
                    chats[i].messages += reading.lines.filter { !have.contains($0.lowercased()) }
                } else {
                    chats.append((name, reading.lines))
                }
                continue
            }
            // Once a chat app has been read with sides, its unplaced screens would only invite the model to guess.
            if ScreenReader.isChat(app: app, url: r[3] as? String), picked.contains(where: { ($0[1] as? String) == app && $0[5] != nil }) {
                continue
            }
            let keep = reading.lines.filter { shown.insert($0.lowercased()).inserted }
            guard !keep.isEmpty else { continue }
            let header = "[\(clock(r[0] as? Double ?? start)) \(app ?? "?")" + ((r[2] as? String).map { " — " + String($0.prefix(80)) } ?? "") + "]"
            screens.append(header + "\n" + keep.joined(separator: "\n"))
        }
        return (screens, chats)
    }

    private func chunked(_ screens: [String], maxChars: Int) -> [[String]] {
        var chunks: [[String]] = [[]]
        var size = 0
        for s in screens {
            let s = String(s.prefix(maxChars))
            if size + s.count > maxChars && !chunks[chunks.count - 1].isEmpty { chunks.append([]); size = 0 }
            chunks[chunks.count - 1].append(s)
            size += s.count
        }
        // With more than three chunks, keep the first, middle and last so the whole stretch is represented.
        if chunks.count > 3 { chunks = [chunks[0], chunks[chunks.count / 2], chunks[chunks.count - 1]] }
        return chunks.filter { !$0.isEmpty }
    }

    private func generateDetails(_ screens: [String]) async throws -> GeneratedContent {
        let note = """
        Below is the text that was on the person's screen, screen by screen in time order. \
        In chat apps, lines starting with "Me:" are messages the person sent and "Them:" are messages they received; \
        the chat's name or contact is usually in the first lines of that screen.
        """
        var screens = screens
        func prompt() -> String { note + "\n\n" + screens.joined(separator: "\n\n") }
        if #available(macOS 26.4, *) {
            let limit = SystemLanguageModel.default.contextSize - 1100
            while let n = try? await SystemLanguageModel.default.tokenCount(for: prompt()), n > limit, let last = screens.last {
                if screens.count > 1 { screens.removeLast() } else { screens = [String(last.prefix(last.count * 3 / 4))] }
            }
        }
        do {
            return try await generate(prompt: prompt(), schema: Self.detailsSchema)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            screens = [String(prompt().prefix(3000))]
            return try await generate(prompt: screens[0], schema: Self.detailsSchema)
        }
    }

    // MARK: - Screen text

    /// OCR'd text from the screenshots in a range, one entry per screen in time order. Lines already seen earlier in
    /// the range are dropped, so a screen that stayed put (or a chat you scrolled) only contributes what was new.
    private func screenText(start: Double, end: Double) -> [String] {
        let rows = Database.shared.query("""
            SELECT s.ts, s.app, s.window_title, o.text FROM screenshots s JOIN ocr o ON o.screenshot_id = s.id
            WHERE s.ts >= ? AND s.ts < ? ORDER BY s.ts
            """, [start, end])
        var seen = Set<String>()
        var screens: [(header: String, lines: [String])] = []
        for r in rows {
            let fresh = ocrLines(r[3] as? String).filter { seen.insert($0.lowercased()).inserted }
            guard !fresh.isEmpty else { continue }
            let header = "\(clock(r[0] as? Double ?? start)) \(r[1] as? String ?? "?")" +
                ((r[2] as? String).map { " — " + String($0.prefix(80)) } ?? "")
            if let last = screens.last, last.header.dropFirst(6) == header.dropFirst(6) {
                screens[screens.count - 1].lines += fresh
            } else {
                screens.append((header, fresh))
            }
        }
        return screens.map { "[\($0.header)] " + $0.lines.joined(separator: " / ") }
    }

    private func ocrLines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }
    }

    /// Whether range b shows the same thing as range a: the same main window, and hardly any text on screen that
    /// wasn't already visible in a (no new screenshots at all counts as the same screen).
    private func sameScreen(_ aStart: Double, _ aEnd: Double, _ bStart: Double, _ bEnd: Double) -> Bool {
        guard let wa = topWindow(aStart, aEnd), wa == topWindow(bStart, bEnd) else { return false }
        func lines(_ s: Double, _ e: Double) -> Set<String> {
            Set(Database.shared.query("""
                SELECT o.text FROM screenshots s JOIN ocr o ON o.screenshot_id = s.id WHERE s.ts >= ? AND s.ts < ?
                """, [s, e]).flatMap { ocrLines($0[0] as? String).map { $0.lowercased() } })
        }
        let b = lines(bStart, bEnd)
        guard !b.isEmpty else { return true }
        return Double(b.intersection(lines(aStart, aEnd)).count) / Double(b.count) >= 0.8
    }

    private func topWindow(_ start: Double, _ end: Double) -> String? {
        Database.shared.query("""
            SELECT app || '|' || COALESCE(window_title, '') FROM activity WHERE end > ? AND start < ?
            GROUP BY 1 ORDER BY SUM(MIN(end, ?) - MAX(start, ?)) DESC LIMIT 1
            """, [start, end, end, start]).first?[0] as? String
    }

    // MARK: - Days

    private func summarizeDay(_ day: Double) async {
        let blocks = Database.shared.query("""
            SELECT start, end, title, summary, category, detail_json FROM summaries
            WHERE kind='block' AND start >= ? AND start < ? ORDER BY start
            """, [day, day + 86400])
        guard !blocks.isEmpty else { return }

        var byCategory: [String: Double] = [:]
        var total: Double = 0
        var lines: [String] = []
        for b in blocks {
            let s = b[0] as? Double ?? 0, e = b[1] as? Double ?? 0
            let cat = b[4] as? String ?? "other"
            var active = e - s
            if let d = (b[5] as? String)?.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let a = obj["active_seconds"] as? Double { active = a }
            byCategory[cat, default: 0] += active
            total += active
            lines.append("\(clock(s))–\(clock(e)) [\(cat)] \(b[2] as? String ?? ""): \(b[3] as? String ?? "")")
        }
        let when = DateFormatter.localizedString(from: Date(timeIntervalSince1970: day), dateStyle: .full, timeStyle: .none)
        func makePrompt() -> String {
            """
            Day: \(when). Total active time: \(minutes(total)).
            Summaries of the day, in order:
            \(lines.joined(separator: "\n"))
            """
        }
        // Stay inside the on-device model's context window (with room for the instructions, schema and reply) by
        // dropping entries from the middle of the day.
        while makePrompt().count > 7000, lines.count > 4 { lines.remove(at: lines.count / 2) }
        if #available(macOS 26.4, *) {
            let limit = SystemLanguageModel.default.contextSize - 900
            while lines.count > 4, let n = try? await SystemLanguageModel.default.tokenCount(for: makePrompt()), n > limit {
                lines.remove(at: lines.count / 2)
            }
        }
        let prompt = makePrompt()
        let detailBase: [String: Any] = [
            "active_seconds": total,
            "categories": byCategory.sorted { $0.value > $1.value }.map { ["name": $0.key, "seconds": $0.value] },
        ]
        var detail = detailBase
        var title = "", summary = "", model = "apple-on-device"
        do {
            let c = try await generate(prompt: prompt, schema: Self.daySchema)
            title = try c.value(String.self, forProperty: "headline")
            summary = try c.value(String.self, forProperty: "overview")
            detail["highlights"] = try c.value([String].self, forProperty: "highlights")
        } catch {
            log("day overview fell back: \(error)")
            let top = byCategory.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) (\(minutes($0.value)))" }
            title = "\(minutes(total)) active"
            summary = "Your time went mostly to " + top.joined(separator: ", ") + "."
            model = "fallback"
        }
        let topCategory = byCategory.max { $0.value < $1.value }?.key ?? "other"
        Database.shared.run("""
            INSERT OR REPLACE INTO summaries(kind, start, end, title, summary, category, detail_json, model, partial, created)
            VALUES('day', ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """, [day, day + 86400, title, summary, topCategory, json(detail), model, Date().timeIntervalSince1970])
    }

    // MARK: - Model

    private func generate(prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        // Fresh session per request so earlier summaries don't eat the context window.
        let session = LanguageModelSession(instructions: Self.instructions)
        return try await session.respond(to: prompt, schema: schema).content
    }

    /// Adds as much screen text to `base` as fits in the model's context window, sampling screens evenly across the
    /// range when there are too many, then generates.
    private func generateFitting(base: String, screens: [String], schema: GenerationSchema) async throws -> GeneratedContent {
        func prompt(_ chars: Int) -> String {
            guard !screens.isEmpty, chars > 0 else { return base }
            let per = max(250, chars / screens.count)
            let n = min(screens.count, max(1, chars / per))
            let picked = (0..<n).map { screens[$0 * screens.count / n] }
            var text = picked.map { String($0.prefix(per)) }.joined(separator: "\n")
            if text.count > chars { text = String(text.prefix(chars)) }
            return base + "\nText that was on screen (OCR, in time order):\n" + text
        }
        let model = SystemLanguageModel.default
        // Room for the instructions, schema and the reply.
        let limit = model.contextSize - 700
        var chars = 9000
        if #available(macOS 26.4, *) {
            while chars > 500, let n = try? await model.tokenCount(for: prompt(chars)), n > limit { chars = chars * 3 / 4 }
        } else {
            chars = 4000
        }
        do {
            return try await generate(prompt: prompt(chars), schema: schema)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            return try await generate(prompt: prompt(chars / 3), schema: schema)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            // Screen text sometimes trips the safety filter; the app and window list alone usually doesn't.
            return try await generate(prompt: base, schema: schema)
        }
    }

    // The Command Line Tools lack the @Generable macro plugin, so schemas are built at runtime.
    private static let blockSchema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "BlockSummary", properties: [
            .init(name: "title", description: "A short title (3-7 words) for what they were doing, e.g. 'Debugging the Slock build'",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "summary", description: "Two or three sentences on what they did, specific about projects, sites, people, conversations and tools",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "category", description: "The main kind of activity",
                  schema: DynamicGenerationSchema(name: "Category", anyOf: categories)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    private static let detailsSchema: GenerationSchema = {
        let conversation = DynamicGenerationSchema(name: "Conversation", properties: [
            .init(name: "with", description: "Who the chat was with: the person's or group's name as shown on screen",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "about", description: "What the conversation was about, in one sentence",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "messages", description: "The key messages in order, each as 'Name: what they said'. Use 'You' for the person's own (Me:) messages",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self),
                                                  minimumElements: 1, maximumElements: 8)),
        ])
        let root = DynamicGenerationSchema(name: "Details", properties: [
            .init(name: "points", description: "2-5 different specific things they did, read or wrote, each a full sentence with names, titles, numbers and topics from the screen text",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self),
                                                  minimumElements: 1, maximumElements: 5)),
            .init(name: "conversations", description: "Each distinct chat or message thread visible on screen, once each. Empty if there were none",
                  schema: DynamicGenerationSchema(arrayOf: conversation, minimumElements: 0, maximumElements: 3)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    private static let chatSchema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "Chat", properties: [
            .init(name: "about", description: "One or two sentences on what the conversation was about and anything decided or asked",
                  schema: DynamicGenerationSchema(type: String.self)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    private static let daySchema: GenerationSchema = {
        let root = DynamicGenerationSchema(name: "DayOverview", properties: [
            .init(name: "headline", description: "A short headline (4-9 words) about what they mainly did, e.g. 'Shipping the Slock dashboard'. No dates or day names.",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "overview", description: "A 3-5 sentence narrative of the day in order: what they focused on, when, and what else came up",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "highlights", description: "3-5 short bullet points of the most notable things they did",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self),
                                                  minimumElements: 2, maximumElements: 5)),
        ])
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    // MARK: - Helpers

    private func setStatus(_ state: String, _ message: String?) {
        var o: [String: Any] = ["state": state, "ts": Date().timeIntervalSince1970]
        if let m = message { o["message"] = m }
        Database.shared.setMeta("ai_status", json(o) ?? "{}")
    }

    private func dayStart(_ ts: Double) -> Double {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: ts)).timeIntervalSince1970
    }

    private func clock(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private func minutes(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    private func json(_ o: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
