#!/usr/bin/env python3
"""slock dashboard: a stdlib-only HTTP server over ~/.slock/slock.db. Binds to localhost only."""

import json
import mimetypes
import os
import re
import sqlite3
import sys
import time
from collections import defaultdict
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

ROOT = os.path.expanduser("~/.slock")
DB_PATH = os.path.join(ROOT, "slock.db")
SHOTS = os.path.join(ROOT, "shots")
PAUSE_FLAG = os.path.join(ROOT, "paused")
SUMMARIZE_REQUEST = os.path.join(ROOT, "summarize-request")
DETAILS_REQUEST = os.path.join(ROOT, "details-request")
STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
HIGHLIGHT_OPEN, HIGHLIGHT_CLOSE = "\x02", "\x03"


def load_port():
    try:
        with open(os.path.join(ROOT, "config.json")) as f:
            return int(json.load(f).get("dashboardPort", 8765))
    except (OSError, ValueError):
        return 8765


def connect():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def rows(conn, sql, params=()):
    return [dict(r) for r in conn.execute(sql, params).fetchall()]


def day_bounds(date_str):
    """Local-time [start, end) unix timestamps for YYYY-MM-DD (default today)."""
    d = datetime.strptime(date_str, "%Y-%m-%d") if date_str else datetime.now()
    start = datetime(d.year, d.month, d.day)
    return start.timestamp(), (start + timedelta(days=1)).timestamp()


def range_bounds(q):
    today = datetime.now().strftime("%Y-%m-%d")
    lo, _ = day_bounds(q.get("from", today))
    _, hi = day_bounds(q.get("to", today))
    return lo, hi


def fts_query(text):
    """Turn free text into a safe FTS5 query: every token quoted, prefix-match on each."""
    tokens = re.findall(r"\w+", text, flags=re.UNICODE)
    return " ".join('"%s"*' % t for t in tokens)


def is_paused():
    try:
        with open(PAUSE_FLAG) as f:
            s = f.read().strip()
    except OSError:
        return False
    if s:
        try:
            if time.time() > float(s):
                return False
        except ValueError:
            pass
    return True


def dir_size(path):
    total = 0
    for dirpath, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(dirpath, name))
            except OSError:
                pass
    return total


# --------------------------------------------------------------------------- API


def api_status(conn, q):
    counts = {}
    for table in ("activity", "screenshots", "shell", "events"):
        counts[table] = conn.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
    last = conn.execute("SELECT MAX(ts) FROM screenshots").fetchone()[0]
    last_activity = conn.execute("SELECT MAX(end) FROM activity").fetchone()[0]
    return {
        "paused": is_paused(),
        "counts": counts,
        "db_bytes": os.path.getsize(DB_PATH) if os.path.exists(DB_PATH) else 0,
        "shots_bytes": dir_size(SHOTS),
        "last_screenshot": last,
        "last_activity": last_activity,
    }


def api_days(conn, q):
    out = rows(conn, """
        SELECT date(start, 'unixepoch', 'localtime') AS day, SUM(end - start) AS seconds
        FROM activity GROUP BY day ORDER BY day DESC LIMIT 366""")
    return {"days": out}


def api_timeline(conn, q):
    lo, hi = day_bounds(q.get("date"))
    activity = rows(conn, """
        SELECT id, MAX(start, ?) AS start, MIN(end, ?) AS end, bundle_id, app, window_title, url, domain
        FROM activity WHERE end > ? AND start < ? ORDER BY start""", (lo, hi, lo, hi))
    shots = rows(conn, """
        SELECT id, ts, path, display_id, app, window_title, url
        FROM screenshots WHERE ts >= ? AND ts < ? AND path != '' ORDER BY ts""", (lo, hi))
    events = rows(conn, "SELECT ts, kind, detail_json FROM events WHERE ts >= ? AND ts < ? ORDER BY ts", (lo, hi))
    return {"start": lo, "end": hi, "activity": activity, "screenshots": shots, "events": events}


def api_screenshot(conn, q):
    sid = int(q.get("id", 0))
    shot = conn.execute("SELECT * FROM screenshots WHERE id = ?", (sid,)).fetchone()
    if not shot:
        return None
    text = conn.execute("SELECT text FROM ocr WHERE screenshot_id = ?", (sid,)).fetchone()
    out = dict(shot)
    out["ocr"] = text[0] if text else ""
    return out


def api_search(conn, q):
    text = q.get("q", "").strip()
    kind = q.get("type", "all")
    limit = min(int(q.get("limit", 100)), 500)
    if not text:
        return {"results": []}
    like = "%" + text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    results = []

    if kind in ("all", "screen"):
        match = fts_query(text)
        if match:
            for r in rows(conn, """
                SELECT s.id, s.ts, s.path, s.app, s.window_title, s.url,
                       snippet(ocr, 0, ?, ?, '…', 16) AS snippet
                FROM ocr JOIN screenshots s ON s.id = ocr.screenshot_id
                WHERE ocr MATCH ? ORDER BY s.ts DESC LIMIT ?""",
                          (HIGHLIGHT_OPEN, HIGHLIGHT_CLOSE, match, limit)):
                r["type"] = "screen"
                results.append(r)

    if kind in ("all", "window", "url"):
        for r in rows(conn, """
            SELECT MIN(start) AS ts, MAX(end) AS last_seen, SUM(end - start) AS seconds,
                   app, window_title, url, COUNT(*) AS visits
            FROM activity
            WHERE window_title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\' OR app LIKE ? ESCAPE '\\'
            GROUP BY app, window_title, url ORDER BY last_seen DESC LIMIT ?""", (like, like, like, limit)):
            r["type"] = "url" if r["url"] else "window"
            results.append(r)

    if kind in ("all", "shell"):
        for r in rows(conn, """
            SELECT ts, cwd, cmd, exit_code, duration_ms FROM shell
            WHERE cmd LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?""", (like, limit)):
            r["type"] = "shell"
            results.append(r)

    if kind in ("all", "typed") and table_exists(conn, "keystrokes"):
        match = fts_query(text)
        if match:
            for r in rows(conn, """
                SELECT k.ts, k.app, k.window_title,
                       snippet(keystrokes_fts, 0, ?, ?, '…', 16) AS snippet
                FROM keystrokes_fts JOIN keystrokes k ON k.id = keystrokes_fts.rowid
                WHERE keystrokes_fts MATCH ? ORDER BY k.ts DESC LIMIT ?""",
                          (HIGHLIGHT_OPEN, HIGHLIGHT_CLOSE, match, limit)):
                r["type"] = "typed"
                results.append(r)

    results.sort(key=lambda r: r.get("last_seen") or r["ts"], reverse=True)
    return {"results": results[:limit], "highlight": [HIGHLIGHT_OPEN, HIGHLIGHT_CLOSE]}


def api_stats(conn, q):
    lo, hi = range_bounds(q)
    acts = conn.execute("""
        SELECT MAX(start, ?) AS s, MIN(end, ?) AS e, app, domain
        FROM activity WHERE end > ? AND start < ?""", (lo, hi, lo, hi)).fetchall()

    by_app = defaultdict(float)
    by_domain = defaultdict(float)
    by_day = defaultdict(float)
    heat = [[0.0] * 24 for _ in range(7)]  # [weekday][hour]
    total = 0.0
    for s, e, app, domain in acts:
        dur = e - s
        if dur <= 0:
            continue
        total += dur
        by_app[app or "?"] += dur
        if domain:
            by_domain[domain] += dur
        # Split across hour buckets for the heatmap and per-day totals.
        t = s
        while t < e:
            dt = datetime.fromtimestamp(t)
            next_hour = (dt.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)).timestamp()
            chunk = min(e, next_hour) - t
            heat[dt.weekday()][dt.hour] += chunk
            by_day[dt.strftime("%Y-%m-%d")] += chunk
            t += chunk

    def top(d, n=25):
        return [{"name": k, "seconds": v} for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:n]]

    shell_top = rows(conn, """
        SELECT substr(cmd, 1, instr(cmd || ' ', ' ') - 1) AS name, COUNT(*) AS count
        FROM shell WHERE ts >= ? AND ts < ? GROUP BY name ORDER BY count DESC LIMIT 15""", (lo, hi))
    return {
        "from": lo, "to": hi, "total_seconds": total,
        "apps": top(by_app), "domains": top(by_domain),
        "days": [{"day": k, "seconds": v} for k, v in sorted(by_day.items())],
        "heatmap": heat, "shell": shell_top,
    }


def api_log(conn, q):
    lo, hi = day_bounds(q.get("date"))
    items = []
    for r in rows(conn, "SELECT ts, kind, detail_json FROM events WHERE ts >= ? AND ts < ?", (lo, hi)):
        r["type"] = "event"
        items.append(r)
    for r in rows(conn, "SELECT ts, cwd, cmd, exit_code, duration_ms FROM shell WHERE ts >= ? AND ts < ?", (lo, hi)):
        r["type"] = "shell"
        items.append(r)
    for r in rows(conn, """
        SELECT start AS ts, end, app, window_title, url FROM activity
        WHERE start >= ? AND start < ? AND url IS NOT NULL""", (lo, hi)):
        r["type"] = "url"
        items.append(r)
    if table_exists(conn, "keystrokes"):
        for r in rows(conn, """
            SELECT ts, app, window_title, text FROM keystrokes WHERE ts >= ? AND ts < ?""", (lo, hi)):
            r["type"] = "typed"
            items.append(r)
    items.sort(key=lambda r: r["ts"], reverse=True)
    return {"items": items}


def table_exists(conn, name):
    return conn.execute("SELECT 1 FROM sqlite_master WHERE name = ?", (name,)).fetchone() is not None


def api_overview(conn, q):
    lo, hi = day_bounds(q.get("date"))
    day, blocks = None, []
    if table_exists(conn, "summaries"):
        for r in rows(conn, """
            SELECT kind, start, end, title, summary, category, detail_json, model, partial, created
            FROM summaries WHERE start >= ? AND start < ? ORDER BY start""", (lo, hi)):
            r["detail"] = json.loads(r.pop("detail_json") or "{}")
            if r["kind"] == "day":
                day = r
            else:
                blocks.append(r)
    status = conn.execute("SELECT value FROM meta WHERE key = 'ai_status'").fetchone() if table_exists(conn, "meta") else None
    details_pending = None
    try:
        with open(DETAILS_REQUEST) as f:
            details_pending = float(f.read().strip())
    except (OSError, ValueError):
        d = conn.execute("SELECT value FROM meta WHERE key = 'details_status'").fetchone() if table_exists(conn, "meta") else None
        d = json.loads(d[0]) if d else {}
        if d.get("state") == "running":
            details_pending = d.get("start")
    active = conn.execute(
        "SELECT SUM(MIN(end, ?) - MAX(start, ?)) FROM activity WHERE end > ? AND start < ?", (hi, lo, lo, hi)
    ).fetchone()[0] or 0
    return {
        "start": lo, "end": hi, "day": day, "blocks": blocks, "active_seconds": active,
        "ai": json.loads(status[0]) if status else None,
        "requested": os.path.exists(SUMMARIZE_REQUEST),
        "details_pending": details_pending,
    }


GET_ROUTES = {
    "/api/overview": api_overview,
    "/api/status": api_status,
    "/api/days": api_days,
    "/api/timeline": api_timeline,
    "/api/screenshot": api_screenshot,
    "/api/search": api_search,
    "/api/stats": api_stats,
    "/api/log": api_log,
}


# --------------------------------------------------------------------------- HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "slock/0.1"

    def log_message(self, fmt, *args):
        if os.environ.get("SLOCK_DEBUG"):
            sys.stderr.write("%s\n" % (fmt % args))

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, cache=False):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return self.send_json({"error": "not found"}, 404)
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(path)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=86400, immutable" if cache else "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def host_ok(self):
        # Block DNS-rebinding: only accept requests addressed to localhost.
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost", "[::1]")

    def do_GET(self):
        if not self.host_ok():
            return self.send_json({"error": "forbidden"}, 403)
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}

        if url.path in GET_ROUTES:
            if not os.path.exists(DB_PATH):
                return self.send_json({"error": "no database yet — is Slock.app running?"}, 503)
            try:
                with connect() as conn:
                    out = GET_ROUTES[url.path](conn, q)
            except (sqlite3.Error, ValueError) as e:
                return self.send_json({"error": str(e)}, 400)
            return self.send_json(out) if out is not None else self.send_json({"error": "not found"}, 404)

        if url.path.startswith("/shots/"):
            rel = unquote(url.path[len("/shots/"):])
            full = os.path.realpath(os.path.join(SHOTS, rel))
            if not full.startswith(os.path.realpath(SHOTS) + os.sep):
                return self.send_json({"error": "forbidden"}, 403)
            return self.send_file(full, cache=True)

        name = "index.html" if url.path in ("/", "") else url.path.lstrip("/")
        full = os.path.realpath(os.path.join(STATIC, name))
        if not full.startswith(os.path.realpath(STATIC) + os.sep):
            return self.send_json({"error": "forbidden"}, 403)
        return self.send_file(full)

    def do_POST(self):
        if not self.host_ok():
            return self.send_json({"error": "forbidden"}, 403)
        # Require a JSON content type so cross-site form posts can't toggle recording.
        if "application/json" not in (self.headers.get("Content-Type") or ""):
            return self.send_json({"error": "json required"}, 415)
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        path = urlparse(self.path).path
        if path == "/api/pause":
            minutes = body.get("minutes")
            with open(PAUSE_FLAG, "w") as f:
                f.write(str(time.time() + float(minutes) * 60) if minutes else "")
            return self.send_json({"paused": True})
        if path == "/api/summarize":
            date = str(body.get("date") or datetime.now().strftime("%Y-%m-%d"))
            if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
                return self.send_json({"error": "bad date"}, 400)
            with open(SUMMARIZE_REQUEST, "w") as f:
                f.write(date)
            return self.send_json({"requested": date})
        if path == "/api/details":
            try:
                start = float(body.get("start"))
            except (TypeError, ValueError):
                return self.send_json({"error": "bad start"}, 400)
            with open(DETAILS_REQUEST, "w") as f:
                f.write(repr(start))
            return self.send_json({"requested": start})
        if path == "/api/resume":
            try:
                os.remove(PAUSE_FLAG)
            except OSError:
                pass
            return self.send_json({"paused": False})
        return self.send_json({"error": "not found"}, 404)


def exit_with_parent(parent_pid):
    """When launched by Slock.app, shut down if the app dies (even if it was killed without cleanup)."""
    import threading

    def watch():
        while True:
            try:
                os.kill(parent_pid, 0)
            except OSError:
                os._exit(0)
            time.sleep(2)

    threading.Thread(target=watch, daemon=True).start()


def main():
    os.makedirs(ROOT, exist_ok=True)
    port = int(sys.argv[1]) if len(sys.argv) > 1 else load_port()
    if len(sys.argv) > 2:
        exit_with_parent(int(sys.argv[2]))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("slock dashboard on http://127.0.0.1:%d" % port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
