import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin serial wrapper around a single SQLite connection. All writes go through `queue`.
final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "slock.db")

    private init() {
        let path = Paths.root.appendingPathComponent("slock.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("slock: cannot open database at \(path)")
        }
        sqlite3_busy_timeout(db, 5000)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        migrate()
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS activity(
            id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL,
            bundle_id TEXT, app TEXT, window_title TEXT, url TEXT, domain TEXT);
        CREATE INDEX IF NOT EXISTS activity_start ON activity(start);
        CREATE TABLE IF NOT EXISTS screenshots(
            id INTEGER PRIMARY KEY, ts REAL NOT NULL, path TEXT NOT NULL, display_id INTEGER,
            app TEXT, window_title TEXT, url TEXT, phash INTEGER);
        CREATE INDEX IF NOT EXISTS screenshots_ts ON screenshots(ts);
        CREATE VIRTUAL TABLE IF NOT EXISTS ocr USING fts5(text, screenshot_id UNINDEXED);
        CREATE TABLE IF NOT EXISTS shell(
            id INTEGER PRIMARY KEY, ts REAL NOT NULL, cwd TEXT, cmd TEXT NOT NULL,
            exit_code INTEGER, duration_ms INTEGER, UNIQUE(ts, cmd));
        CREATE INDEX IF NOT EXISTS shell_ts ON shell(ts);
        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL, detail_json TEXT);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """)
        // Added later: the front window's frame within each screenshot.
        if !query("PRAGMA table_info(screenshots)").contains(where: { ($0[1] as? String) == "win" }) {
            exec("ALTER TABLE screenshots ADD COLUMN win TEXT")
        }
    }

    /// Run one or more statements with no parameters.
    func exec(_ sql: String) {
        queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                log("sql error: \(err.map { String(cString: $0) } ?? "?") in \(sql.prefix(80))")
                sqlite3_free(err)
            }
        }
    }

    /// Run a single parameterised statement. Returns last insert rowid.
    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) -> Int64 {
        queue.sync {
            guard let stmt = prepare(sql, params) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) != SQLITE_DONE {
                log("sql step error: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))")
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Run a query and return rows as arrays of column values.
    func query(_ sql: String, _ params: [Any?] = []) -> [[Any?]] {
        queue.sync {
            guard let stmt = prepare(sql, params) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [[Any?]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [Any?] = []
                for i in 0..<sqlite3_column_count(stmt) {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, i)))
                    default: row.append(nil)
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func prepare(_ sql: String, _ params: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("sql prepare error: \(String(cString: sqlite3_errmsg(db))) in \(sql.prefix(80))")
            return nil
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as UInt32: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as UInt64: sqlite3_bind_int64(stmt, idx, Int64(bitPattern: v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, idx, "\(p!)", -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    // MARK: - Convenience

    func event(_ kind: String, _ detail: [String: Any] = [:]) {
        let json = (try? JSONSerialization.data(withJSONObject: detail)).flatMap { String(data: $0, encoding: .utf8) }
        run("INSERT INTO events(ts, kind, detail_json) VALUES(?,?,?)", [Date().timeIntervalSince1970, kind, json])
    }

    func meta(_ key: String) -> String? {
        query("SELECT value FROM meta WHERE key=?", [key]).first?.first as? String
    }

    func setMeta(_ key: String, _ value: String) {
        run("INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", [key, value])
    }
}
