import Foundation

/// Tails ~/.slock/shell.log (written by shell/slock.zsh) into the `shell` table.
/// Line format: ts \t cwd \t exit_code \t duration_ms \t cmd   (newlines in cmd escaped as \n)
final class ShellIngest {
    private var timer: Timer?
    private let queue = DispatchQueue(label: "slock.shell", qos: .utility)

    func start() {
        queue.async { self.backfillZshHistory() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.queue.async { self?.ingest() }
        }
    }

    private func ingest() {
        guard let handle = try? FileHandle(forReadingFrom: Paths.shellLog) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        var offset = UInt64(Database.shared.meta("shell_log_offset") ?? "0") ?? 0
        if offset > size { offset = 0 } // file was truncated/rotated
        guard size > offset else { return }
        handle.seek(toFileOffset: offset)
        let data = handle.readData(ofLength: Int(size - offset))
        // Only consume complete lines.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let chunk = data[data.startIndex...lastNewline]
        let text = String(decoding: chunk, as: UTF8.self)

        Database.shared.exec("BEGIN")
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard f.count == 5, let ts = Double(f[0]) else { continue }
            let cmd = f[4].replacingOccurrences(of: "\\n", with: "\n")
            Database.shared.run(
                "INSERT OR IGNORE INTO shell(ts, cwd, cmd, exit_code, duration_ms) VALUES(?,?,?,?,?)",
                [ts, String(f[1]), cmd, Int(f[2]), Int(f[3])]
            )
        }
        Database.shared.exec("COMMIT")
        Database.shared.setMeta("shell_log_offset", String(offset + UInt64(chunk.count)))
    }

    /// One-time import of existing zsh history (only entries with EXTENDED_HISTORY timestamps).
    private func backfillZshHistory() {
        guard Database.shared.meta("zsh_history_imported") == nil else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zsh_history")
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)

        var count = 0
        var pendingTs: Double?
        var pendingCmd = ""
        func flush() {
            if let ts = pendingTs, !pendingCmd.isEmpty {
                Database.shared.run("INSERT OR IGNORE INTO shell(ts, cmd) VALUES(?,?)", [ts, pendingCmd])
                count += 1
            }
            pendingTs = nil
            pendingCmd = ""
        }

        Database.shared.exec("BEGIN")
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix(": "), let semi = raw.firstIndex(of: ";") {
                flush()
                // ": <start>:<elapsed>;<command>"
                let meta = raw[raw.index(raw.startIndex, offsetBy: 2)..<semi].split(separator: ":")
                pendingTs = meta.first.flatMap { Double($0) }
                pendingCmd = String(raw[raw.index(after: semi)...])
            } else if pendingTs != nil {
                pendingCmd += "\n" + raw
            }
            if pendingCmd.hasSuffix("\\") { pendingCmd.removeLast() } else if pendingTs != nil { flush() }
        }
        flush()
        Database.shared.exec("COMMIT")
        Database.shared.setMeta("zsh_history_imported", "1")
        log("imported \(count) commands from ~/.zsh_history")
    }
}
