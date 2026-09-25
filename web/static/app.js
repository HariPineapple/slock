"use strict";

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

// ------------------------------------------------------------------ helpers

async function api(path, opts) {
  const res = await fetch(path, opts);
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// Server marks FTS highlights with \x02 … \x03 so we can escape first, then add <mark>.
function highlight(s) {
  return esc(s).replace(/\x02/g, "<mark>").replace(/\x03/g, "</mark>");
}

function markTerms(s, q) {
  const e = esc(s);
  const terms = (q.match(/\w+/g) || []).map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!terms.length) return e;
  return e.replace(new RegExp("(" + terms.join("|") + ")", "gi"), "<mark>$1</mark>");
}

function dur(sec) {
  sec = Math.round(sec || 0);
  if (sec < 60) return sec + "s";
  const m = Math.floor(sec / 60), h = Math.floor(m / 60);
  if (h === 0) return m + "m";
  return h + "h " + String(m % 60).padStart(2, "0") + "m";
}

function fmtTime(ts, secs) {
  return new Date(ts * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: secs ? "2-digit" : undefined });
}

function fmtDateTime(ts) {
  const d = new Date(ts * 1000);
  return d.toLocaleDateString([], { month: "short", day: "numeric", year: d.getFullYear() === new Date().getFullYear() ? undefined : "numeric" })
    + " " + fmtTime(ts);
}

function ymd(d) {
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
}

function tsToYmd(ts) { return ymd(new Date(ts * 1000)); }

function addDays(dateStr, n) {
  const [y, m, d] = dateStr.split("-").map(Number);
  return ymd(new Date(y, m - 1, d + n));
}

// Stable pleasant color per app name.
const colorCache = {};
function colorFor(name) {
  if (!name) return "#888";
  if (colorCache[name]) return colorCache[name];
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  const dark = matchMedia("(prefers-color-scheme: dark)").matches;
  return (colorCache[name] = `hsl(${h % 360} ${55 + (h >> 8) % 20}% ${dark ? 55 : 58}%)`);
}

// Only link out to http(s) URLs; anything else (javascript:, file:) stays inert.
function safeHref(u) { return /^https?:\/\//i.test(u || "") ? u : "#"; }

function shotUrl(path) { return "/shots/" + path.split("/").map(encodeURIComponent).join("/"); }

// ------------------------------------------------------------------ routing

const state = {
  tab: "timeline",
  date: ymd(new Date()),
  timeline: null,
  shotIdx: 0,
  pendingShotTs: null,
  searchType: "all",
  chat: [],
  chatBusy: false,
  statsDays: 1,
  logFilter: "all",
  logItems: [],
};

function parseHash() {
  const [tab, qs] = location.hash.replace(/^#/, "").split("?");
  const params = new URLSearchParams(qs || "");
  return { tab: tab || "overview", params };
}

function route() {
  const { tab, params } = parseHash();
  state.tab = ["overview", "timeline", "search", "chat", "stats", "log"].includes(tab) ? tab : "overview";
  $$("nav a").forEach((a) => a.classList.toggle("active", a.dataset.tab === state.tab));
  $$(".tab").forEach((s) => (s.hidden = s.id !== "tab-" + state.tab));

  if (state.tab === "overview") {
    const date = params.get("date") || state.date;
    state.date = date;
    loadOverview();
  } else if (state.tab === "timeline") {
    const date = params.get("date") || state.date;
    const ts = params.get("t");
    if (ts) state.pendingShotTs = Number(ts);
    state.date = date;
    if (!state.timeline || state.timelineDate !== date) loadTimeline();
    else if (ts) jumpToTs(Number(ts));
  } else if (state.tab === "search") {
    const q = params.get("q");
    if (q !== null && q !== $("#search-input").value) { $("#search-input").value = q; runSearch(); }
    $("#search-input").focus();
  } else if (state.tab === "chat") {
    $("#chat-input").focus();
  } else if (state.tab === "stats") {
    loadStats();
  } else if (state.tab === "log") {
    if (!$("#log-date").value) $("#log-date").value = state.date;
    loadLog();
  }
}

// ------------------------------------------------------------------ status / pause

async function refreshStatus() {
  try {
    const s = await api("/api/status");
    const lastSeen = Math.max(s.last_activity || 0, s.last_screenshot || 0);
    const stale = Date.now() / 1000 - lastSeen > 120;
    $("#rec-dot").classList.toggle("live", !s.paused && !stale);
    $("#pause-btn").textContent = s.paused ? "Resume" : "Pause";
    $("#pause-btn").classList.toggle("danger", !s.paused);
    $("#pause-btn").dataset.paused = s.paused ? "1" : "";
    const gb = ((s.db_bytes + s.shots_bytes) / 1e9).toFixed(2);
    let label = s.paused ? "Paused" : stale ? "Agent idle / not running" : "Recording";
    $("#status-text").textContent = `${label} · ${s.counts.screenshots.toLocaleString()} shots · ${gb} GB`;
  } catch (e) {
    $("#status-text").textContent = e.message;
  }
}

$("#pause-btn").addEventListener("click", async () => {
  const paused = !!$("#pause-btn").dataset.paused;
  await api(paused ? "/api/resume" : "/api/pause", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
  });
  refreshStatus();
});

// ------------------------------------------------------------------ timeline

async function loadTimeline() {
  $("#day-input").value = state.date;
  try {
    state.timeline = await api("/api/timeline?date=" + state.date);
    state.timelineDate = state.date;
  } catch (e) {
    state.timeline = { start: 0, end: 86400, activity: [], screenshots: [], events: [] };
    $("#shot-empty").textContent = e.message;
  }
  renderTimeline();
}

function renderTimeline() {
  const tl = state.timeline;
  const span = tl.end - tl.start;
  const pct = (ts) => ((ts - tl.start) / span) * 100;

  // Activity blocks
  const strip = $("#strip");
  strip.innerHTML = tl.activity
    .filter((a) => a.end - a.start >= 1)
    .map((a) => `<div class="blk" style="left:${pct(a.start)}%;width:${pct(a.end) - pct(a.start)}%;background:${colorFor(a.app)}"></div>`)
    .join("");

  // Event ticks
  $("#strip-events").innerHTML = tl.events
    .filter((e) => !["idle_start", "idle_end", "app_launch", "app_quit"].includes(e.kind))
    .map((e) => `<div class="ev ${esc(e.kind)}" style="left:${pct(e.ts)}%" title="${esc(fmtTime(e.ts) + " " + e.kind)}"></div>`)
    .join("");

  // Axis
  $("#strip-axis").innerHTML = [0, 3, 6, 9, 12, 15, 18, 21, 24]
    .map((h) => `<span style="left:${(h / 24) * 100}%">${h === 24 ? "" : String(h).padStart(2, "0") + ":00"}</span>`)
    .join("");

  // Summary
  const total = tl.activity.reduce((s, a) => s + (a.end - a.start), 0);
  $("#day-summary").textContent = total ? `${dur(total)} active · ${tl.screenshots.length} screenshots` : "";

  // Scrubber
  const n = tl.screenshots.length;
  $("#scrubber").max = Math.max(0, n - 1);
  $("#shot-empty").style.display = n ? "none" : "";
  $("#shot-img").style.display = n ? "" : "none";
  if (!n) $("#shot-empty").textContent = "No screenshots for this day.";

  if (state.pendingShotTs) { jumpToTs(state.pendingShotTs); state.pendingShotTs = null; }
  else showShot(n - 1);

  renderSessions();
}

function nearestShotIdx(ts) {
  const shots = state.timeline.screenshots;
  if (!shots.length) return -1;
  let lo = 0, hi = shots.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (shots[mid].ts < ts) lo = mid + 1; else hi = mid;
  }
  if (lo > 0 && Math.abs(shots[lo - 1].ts - ts) < Math.abs(shots[lo].ts - ts)) lo--;
  return lo;
}

function jumpToTs(ts) {
  const i = nearestShotIdx(ts);
  if (i >= 0) showShot(i);
  else showCursorAt(ts);
}

function showCursorAt(ts) {
  const tl = state.timeline;
  const c = $("#strip-cursor");
  c.style.display = "block";
  c.style.left = `calc(${((ts - tl.start) / (tl.end - tl.start)) * 100}% - 1px)`;
}

function activityAt(ts) {
  return state.timeline.activity.find((a) => a.start <= ts && a.end >= ts);
}

let ocrReq = 0;
async function showShot(i) {
  const shots = state.timeline.screenshots;
  if (!shots.length) {
    $("#meta-time").textContent = "—";
    $("#meta-app").innerHTML = $("#meta-title").textContent = $("#meta-url").textContent = "";
    $("#shot-count").textContent = "";
    $("#meta-ocr").textContent = "";
    return;
  }
  i = Math.max(0, Math.min(shots.length - 1, i));
  state.shotIdx = i;
  const s = shots[i];
  $("#scrubber").value = i;
  $("#shot-img").src = shotUrl(s.path);
  $("#shot-count").textContent = `${i + 1} / ${shots.length}`;
  $("#meta-time").textContent = fmtTime(s.ts, true);
  $("#meta-app").innerHTML = `<span class="swatch" style="background:${colorFor(s.app)}"></span>${esc(s.app || "")}`;
  $("#meta-title").textContent = s.window_title || "";
  $("#meta-url").textContent = s.url || "";
  $("#meta-url").href = safeHref(s.url);
  showCursorAt(s.ts);

  // Prefetch neighbours for smooth scrubbing.
  [i - 1, i + 1].forEach((j) => { if (shots[j]) new Image().src = shotUrl(shots[j].path); });

  const req = ++ocrReq;
  $("#meta-ocr").textContent = "…";
  try {
    const d = await api("/api/screenshot?id=" + s.id);
    if (req === ocrReq) $("#meta-ocr").textContent = d.ocr || "(no text recognised yet)";
  } catch { if (req === ocrReq) $("#meta-ocr").textContent = ""; }
}

function renderSessions() {
  // Merge consecutive rows with the same app so the list stays readable.
  const merged = [];
  for (const a of state.timeline.activity) {
    const last = merged[merged.length - 1];
    if (last && last.app === a.app && a.start - last.end < 30) {
      last.end = a.end;
      last.titles.add(a.window_title || a.domain || "");
    } else {
      merged.push({ ...a, titles: new Set([a.window_title || a.domain || ""]) });
    }
  }
  const list = merged.filter((m) => m.end - m.start >= 20).reverse();
  $("#sessions").innerHTML = list.length
    ? list.map((m) => {
        const titles = [...m.titles].filter(Boolean);
        const title = titles.slice(0, 3).join(" · ") + (titles.length > 3 ? ` +${titles.length - 3}` : "");
        return `<div class="session" data-ts="${m.start}">
          <span class="t mono">${fmtTime(m.start)}</span>
          <span class="swatch" style="background:${colorFor(m.app)}"></span>
          <span class="a">${esc(m.app)}</span>
          <span class="w">${esc(title)}</span>
          <span class="d mono">${dur(m.end - m.start)}</span></div>`;
      }).join("")
    : `<div class="muted">Nothing recorded yet.</div>`;
}

$("#sessions").addEventListener("click", (e) => {
  const row = e.target.closest(".session");
  if (row) { jumpToTs(Number(row.dataset.ts) + 1); window.scrollTo({ top: 0, behavior: "smooth" }); }
});

function stripTs(e) {
  const r = $("#strip").getBoundingClientRect();
  const x = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
  return { ts: state.timeline.start + x * (state.timeline.end - state.timeline.start), x: e.clientX - r.left };
}

let dragging = false;
$("#strip").addEventListener("mousedown", (e) => { dragging = true; jumpToTs(stripTs(e).ts); });
window.addEventListener("mouseup", () => (dragging = false));
$("#strip").addEventListener("mousemove", (e) => {
  const { ts, x } = stripTs(e);
  if (dragging) jumpToTs(ts);
  const a = activityAt(ts);
  const tip = $("#strip-tip");
  tip.style.display = "block";
  tip.style.left = x + "px";
  tip.textContent = fmtTime(ts) + (a ? ` · ${a.app}${a.window_title ? " — " + a.window_title : ""}` : "");
});
$("#strip").addEventListener("mouseleave", () => ($("#strip-tip").style.display = "none"));

$("#scrubber").addEventListener("input", (e) => showShot(Number(e.target.value)));
$("#shot-prev").addEventListener("click", () => showShot(state.shotIdx - 1));
$("#shot-next").addEventListener("click", () => showShot(state.shotIdx + 1));
$("#shot-img").addEventListener("click", () => $("#shot-frame").classList.toggle("zoom"));

function setDate(d) { location.hash = "#timeline?date=" + d; }
$("#day-input").addEventListener("change", (e) => e.target.value && setDate(e.target.value));
$("#day-prev").addEventListener("click", () => setDate(addDays(state.date, -1)));
$("#day-next").addEventListener("click", () => setDate(addDays(state.date, 1)));
$("#day-today").addEventListener("click", () => setDate(ymd(new Date())));

document.addEventListener("keydown", (e) => {
  if (e.target.matches("input[type=search], input[type=date]")) return;
  if (e.key === "Escape") $("#shot-frame").classList.remove("zoom");
  if (state.tab !== "timeline") return;
  if (e.key === "ArrowLeft") { showShot(state.shotIdx - (e.shiftKey ? 10 : 1)); e.preventDefault(); }
  if (e.key === "ArrowRight") { showShot(state.shotIdx + (e.shiftKey ? 10 : 1)); e.preventDefault(); }
  if (e.key === "/") { location.hash = "#search"; e.preventDefault(); }
});

// ------------------------------------------------------------------ search

let searchTimer;
$("#search-input").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(runSearch, 250); });
$("#search-form").addEventListener("submit", (e) => { e.preventDefault(); runSearch(); });
$("#search-types").addEventListener("click", (e) => {
  const b = e.target.closest(".chip");
  if (!b) return;
  state.searchType = b.dataset.type;
  $$("#search-types .chip").forEach((c) => c.classList.toggle("active", c === b));
  runSearch();
});

let searchReq = 0;
async function runSearch() {
  const q = $("#search-input").value.trim();
  history.replaceState(null, "", "#search" + (q ? "?q=" + encodeURIComponent(q) : ""));
  if (!q) { $("#search-results").innerHTML = ""; $("#search-summary").textContent = ""; return; }
  const req = ++searchReq;
  const t0 = performance.now();
  let data;
  try {
    data = await api(`/api/search?q=${encodeURIComponent(q)}&type=${state.searchType}`);
  } catch (e) { $("#search-summary").textContent = e.message; return; }
  if (req !== searchReq) return;
  const ms = Math.round(performance.now() - t0);
  $("#search-summary").textContent = `${data.results.length} result${data.results.length === 1 ? "" : "s"} · ${ms} ms`;
  $("#search-results").innerHTML = data.results.map((r) => renderResult(r, q)).join("") ||
    `<div class="muted">No matches.</div>`;
}

function renderResult(r, q) {
  const when = `<span class="muted mono">${fmtDateTime(r.ts)}</span>`;
  const jump = `data-ts="${r.ts}"`;
  if (r.type === "screen") {
    return `<div class="result" ${jump}>
      ${r.path ? `<img loading="lazy" src="${shotUrl(r.path)}" alt="">` : `<div></div>`}
      <div><div class="head"><span class="kind">screen</span><b>${esc(r.app || "")}</b>${when}</div>
      <div class="muted">${esc(r.window_title || "")}</div>
      <div class="snip">${highlight(r.snippet)}</div></div></div>`;
  }
  if (r.type === "shell") {
    return `<div class="result noimg" ${jump}>
      <div><div class="head"><span class="kind">shell</span>${when}<span class="muted">${esc(r.cwd || "")}</span></div>
      <code>${markTerms(r.cmd, q)}</code></div></div>`;
  }
  if (r.type === "typed") {
    return `<div class="result noimg" ${jump}>
      <div><div class="head"><span class="kind">typed</span><b>${esc(r.app || "")}</b>${when}
        <span class="muted">${esc(r.window_title || "")}</span></div>
      <div class="snip">${highlight(r.snippet)}</div></div></div>`;
  }
  return `<div class="result noimg" ${jump}>
    <div><div class="head"><span class="kind">${r.type}</span><b>${markTerms(r.app || "", q)}</b>${when}
      <span class="muted">${dur(r.seconds)} total · ${r.visits}×</span></div>
    <div>${markTerms(r.window_title || "", q)}</div>
    ${r.url ? `<div class="snip">${markTerms(r.url, q)}</div>` : ""}</div></div>`;
}

$("#search-results").addEventListener("click", (e) => {
  const r = e.target.closest(".result");
  if (r) location.hash = `#timeline?date=${tsToYmd(Number(r.dataset.ts))}&t=${r.dataset.ts}`;
});

// ------------------------------------------------------------------ stats

$("#stats-range").addEventListener("click", (e) => {
  const b = e.target.closest(".chip");
  if (!b) return;
  state.statsDays = Number(b.dataset.days);
  $$("#stats-range .chip").forEach((c) => c.classList.toggle("active", c === b));
  loadStats();
});

function bars(items, valueFmt, colorFn) {
  if (!items.length) return `<div class="muted">No data.</div>`;
  const max = Math.max(...items.map((i) => i.value));
  return items.map((i) => `<div class="bar" title="${esc(i.name)}">
      <span class="n">${esc(i.name)}</span>
      <span class="track"><span class="fill" style="display:block;width:${(i.value / max) * 100}%;background:${colorFn(i.name)}"></span></span>
      <span class="v">${valueFmt(i.value)}</span></div>`).join("");
}

async function loadStats() {
  const to = ymd(new Date());
  const from = addDays(to, -(state.statsDays - 1));
  let s;
  try { s = await api(`/api/stats?from=${from}&to=${to}`); } catch (e) { $("#stats-total").textContent = e.message; return; }
  $("#stats-total").textContent = dur(s.total_seconds) + " active";
  const accent = () => "var(--accent)";
  $("#stats-apps").innerHTML = bars(s.apps.map((a) => ({ name: a.name, value: a.seconds })), dur, colorFor);
  $("#stats-domains").innerHTML = bars(s.domains.map((a) => ({ name: a.name, value: a.seconds })), dur, colorFor);
  $("#stats-shell").innerHTML = bars(s.shell.map((a) => ({ name: a.name, value: a.count })), (v) => v + "×", accent);

  // Heatmap: rows Mon..Sun, cols 0..23
  const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const max = Math.max(1, ...s.heatmap.flat());
  let html = `<span></span>` + Array.from({ length: 24 }, (_, h) => `<span class="hl">${h % 3 === 0 ? h : ""}</span>`).join("");
  s.heatmap.forEach((row, d) => {
    html += `<span class="lbl">${days[d]}</span>` + row.map((v, h) =>
      `<span class="cell" title="${days[d]} ${h}:00 — ${dur(v)}" style="${v ? `background:color-mix(in srgb, var(--accent) ${Math.round(15 + (v / max) * 85)}%, var(--panel-2))` : ""}"></span>`
    ).join("");
  });
  $("#stats-heat").innerHTML = html;

  const dmax = Math.max(1, ...s.days.map((d) => d.seconds));
  $("#stats-days").innerHTML = s.days.length
    ? s.days.map((d) => `<div class="col" title="${d.day}: ${dur(d.seconds)}" style="height:${(d.seconds / dmax) * 100}%"></div>`).join("")
    : `<div class="muted">No data.</div>`;
}

$("#stats-days").addEventListener("click", (e) => {
  const c = e.target.closest(".col");
  if (c) setDate(c.title.split(":")[0]);
});

// ------------------------------------------------------------------ log

$("#log-date").addEventListener("change", loadLog);
$("#log-filter").addEventListener("click", (e) => {
  const b = e.target.closest(".chip");
  if (!b) return;
  state.logFilter = b.dataset.f;
  $$("#log-filter .chip").forEach((c) => c.classList.toggle("active", c === b));
  renderLog();
});

async function loadLog() {
  try { state.logItems = (await api("/api/log?date=" + $("#log-date").value)).items; }
  catch { state.logItems = []; }
  renderLog();
}

function describeEvent(r) {
  let d = {};
  try { d = JSON.parse(r.detail_json || "{}"); } catch {}
  switch (r.kind) {
    case "app_launch": return `Launched <b>${esc(d.app)}</b>`;
    case "app_quit": return `Quit <b>${esc(d.app)}</b>`;
    case "download": return `Downloaded <b>${esc(d.name)}</b> <span class="muted">${(d.bytes / 1e6).toFixed(1)} MB</span>`;
    case "volume_mount": return `Mounted <b>${esc(d.name)}</b> <span class="muted">${esc(d.path)}</span>`;
    case "volume_unmount": return `Unmounted <b>${esc(d.name)}</b>`;
    case "network_change": return `Network ${esc(d.status)} <span class="muted">${esc((d.interfaces || []).join(", "))}</span>`;
    case "idle_start": return `<span class="muted">Went idle</span>`;
    case "idle_end": return `<span class="muted">Back after ${dur(d.idle_seconds)}</span>`;
    default: return esc(r.kind.replace(/_/g, " ")) + (Object.keys(d).length ? ` <span class="muted">${esc(JSON.stringify(d))}</span>` : "");
  }
}

function renderLog() {
  const items = state.logItems.filter((r) => state.logFilter === "all" || r.type === state.logFilter);
  $("#log-list").innerHTML = items.slice(0, 3000).map((r) => {
    let body;
    if (r.type === "shell") {
      body = `<code class="${r.exit_code ? "fail" : ""}">${esc(r.cmd)}</code> <span class="muted">${esc(r.cwd || "")}${r.duration_ms > 1000 ? " · " + dur(r.duration_ms / 1000) : ""}</span>`;
    } else if (r.type === "url") {
      body = `<b>${esc(r.window_title || r.url)}</b> <a class="muted" href="${esc(safeHref(r.url))}" target="_blank" rel="noopener noreferrer">${esc(r.url)}</a>`;
    } else if (r.type === "typed") {
      body = `<span class="typed-text">${esc(r.text)}</span> <span class="muted">${esc(r.app || "")}${r.window_title ? " · " + esc(r.window_title) : ""}</span>`;
    } else {
      body = describeEvent(r);
    }
    const kind = r.type === "event" ? "system" : r.type === "url" ? "web" : r.type;
    return `<div class="log-item"><span class="mono muted">${fmtTime(r.ts, true)}</span><span class="k">${kind}</span><span class="body">${body}</span></div>`;
  }).join("") || `<div class="muted">Nothing logged.</div>`;
}

// ------------------------------------------------------------------ overview (AI summaries)

const CATEGORY_COLORS = {
  coding: "#6e79f0", writing: "#e0a526", communication: "#3fb27f", research: "#3aa3d6", browsing: "#9a7cf0",
  entertainment: "#ef6aa0", meetings: "#f08a4b", admin: "#8f9a8a", other: "#a3a39c",
};
const catColor = (c) => CATEGORY_COLORS[c] || CATEGORY_COLORS.other;

let ovPoll = null;
let ovWaitingSince = 0;
const ovOpen = new Set();  // starts of the entries expanded to show details

async function loadOverview() {
  $("#ov-date").value = state.date;
  let d;
  try { d = await api("/api/overview?date=" + state.date); }
  catch (e) { $("#ov-headline").textContent = e.message; return; }
  renderOverview(d);

  // Keep polling while a summary run is pending or in progress.
  const busy = d.requested || (d.ai && d.ai.state === "running") || d.details_pending != null;
  clearTimeout(ovPoll);
  if (state.tab === "overview" && (busy || (ovWaitingSince && Date.now() - ovWaitingSince < 90000))) {
    ovPoll = setTimeout(loadOverview, 2500);
  }
  if (!busy && ovWaitingSince && d.day && d.day.created * 1000 > ovWaitingSince) ovWaitingSince = 0;
}

function renderOverview(d) {
  const date = new Date(d.start * 1000);
  $("#ov-dayname").textContent = date.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" }) +
    (d.active_seconds ? ` · ${dur(d.active_seconds)} active` : "");

  const ai = d.ai || {};
  const busy = d.requested || ai.state === "running";
  $("#ov-refresh").disabled = busy;
  $("#ov-refresh").textContent = busy ? "Summarizing…" : "Summarize now";
  if (ai.state === "unavailable") {
    $("#ov-status").textContent = ai.message || "Apple Intelligence is unavailable";
  } else if (d.day) {
    $("#ov-status").textContent = "Updated " + fmtTime(d.day.created);
  } else {
    $("#ov-status").textContent = "";
  }

  // Hero
  const day = d.day;
  if (day) {
    $("#ov-headline").textContent = day.title;
    $("#ov-summary").textContent = day.summary;
    $("#ov-highlights").innerHTML = (day.detail.highlights || []).map((h) => `<li>${esc(h)}</li>`).join("");
  } else if (d.blocks.length) {
    $("#ov-headline").textContent = busy ? "Writing your day's overview…" : "No overview yet";
    $("#ov-summary").textContent = busy ? "" : "Click “Summarize now” to write one from the half-hour summaries below.";
    $("#ov-highlights").innerHTML = "";
  } else {
    $("#ov-headline").textContent = d.active_seconds ? (busy ? "Summarizing…" : "Nothing summarized yet") : "Nothing recorded this day";
    $("#ov-summary").textContent = d.active_seconds && !busy
      ? "Summaries are written automatically every 30 minutes. Click “Summarize now” to summarize up to this minute."
      : "";
    $("#ov-highlights").innerHTML = "";
  }

  // Category mix
  const mix = {};
  for (const b of d.blocks) mix[b.category] = (mix[b.category] || 0) + (b.detail.active_seconds || b.end - b.start);
  const total = Object.values(mix).reduce((a, b) => a + b, 0);
  const entries = Object.entries(mix).sort((a, b) => b[1] - a[1]);
  $("#ov-mix").style.display = total ? "" : "none";
  $("#ov-mix").innerHTML = entries.map(([c, v]) =>
    `<span style="width:${(v / total) * 100}%;background:${catColor(c)}" title="${esc(c)} ${dur(v)}"></span>`).join("");
  $("#ov-legend").innerHTML = entries.map(([c, v]) =>
    `<span><i class="swatch" style="background:${catColor(c)}"></i>${esc(c)} ${dur(v)}</span>`).join("");

  // Half-hour blocks (plus the partial ones from "Summarize now"), newest first
  const blocks = [...d.blocks].reverse();
  $("#ov-blocks").innerHTML = blocks.length ? blocks.map((b) => {
    const apps = (b.detail.apps || []).slice(0, 4).map((a) => `${esc(a.name)} ${dur(a.seconds)}`).join(" · ");
    const open = ovOpen.has(b.start);
    return `<li class="ov-block${b.partial ? " partial" : ""}${open ? " open" : ""}" data-ts="${b.start}">
      <span class="when mono">${fmtTime(b.start)}<br>–${fmtTime(b.end)}</span>
      <span class="node" style="background:${catColor(b.category)}"></span>
      <div class="body">
        <div class="t">${esc(b.title)} <span class="cat" style="color:${catColor(b.category)}">${esc(b.category)}</span></div>
        <div class="s">${esc(b.summary)}</div>
        ${apps ? `<div class="apps">${apps}</div>` : ""}
        ${open ? renderDetails(b, d.details_pending === b.start) : ""}
      </div></li>`;
  }).join("") : `<li class="ov-empty">No half-hour summaries yet.</li>`;
}

function renderDetails(b, pending) {
  const det = b.detail.details;
  const actions = `<div class="ov-det-actions">
      <a href="#timeline?date=${state.date}&t=${b.start + 60}">Open in Timeline →</a>
      ${det && !pending ? `<button class="linkbtn" data-redo="${b.start}">Re-read</button>` : ""}
    </div>`;
  if (pending || !det) {
    return `<div class="ov-details"><p class="muted">Reading what was on your screen… this takes a few seconds.</p>${actions}</div>`;
  }
  const points = (det.points || []).map((p) => `<li>${esc(p)}</li>`).join("");
  const convs = (det.conversations || []).map((c) => `
    <div class="ov-conv">
      <div class="with">${esc(c.with)}</div>
      ${c.about ? `<div class="about">${esc(c.about)}</div>` : ""}
      <ul class="msgs">${(c.messages || []).map((m) => {
        const i = m.indexOf(":");
        const who = i > 0 && i < 40 ? m.slice(0, i) : "";
        const me = /^(you|me)$/i.test(who.trim());
        return `<li class="${me ? "me" : ""}">${who ? `<b>${esc(who)}</b>${esc(m.slice(i))}` : esc(m)}</li>`;
      }).join("")}</ul>
    </div>`).join("");
  return `<div class="ov-details">
      ${det.error ? `<p class="muted">${esc(det.error)}</p>` : ""}
      ${points ? `<ul class="points">${points}</ul>` : ""}
      ${convs}
      <p class="muted small">Read from your screenshots by the on-device model. Names and quotes can be off.</p>
      ${actions}
    </div>`;
}

async function requestDetails(start) {
  await api("/api/details", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ start }),
  });
  loadOverview();
}

$("#ov-blocks").addEventListener("click", async (e) => {
  if (e.target.closest("a")) return;
  const redo = e.target.closest("[data-redo]");
  if (redo) return requestDetails(Number(redo.dataset.redo));
  if (e.target.closest(".ov-details")) return;  // let people select text in the details
  const b = e.target.closest(".ov-block");
  if (!b) return;
  const start = Number(b.dataset.ts);
  if (ovOpen.has(start)) { ovOpen.delete(start); return loadOverview(); }
  ovOpen.add(start);
  const d = await api("/api/overview?date=" + state.date);
  const block = d.blocks.find((x) => x.start === start);
  if (block && !block.detail.details) return requestDetails(start);
  renderOverview(d);
});

$("#ov-refresh").addEventListener("click", async () => {
  ovWaitingSince = Date.now();
  await api("/api/summarize", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ date: state.date }),
  });
  loadOverview();
});

function setOvDate(d) { location.hash = "#overview?date=" + d; }
$("#ov-date").addEventListener("change", (e) => e.target.value && setOvDate(e.target.value));
$("#ov-prev").addEventListener("click", () => setOvDate(addDays(state.date, -1)));
$("#ov-next").addEventListener("click", () => setOvDate(addDays(state.date, 1)));
$("#ov-today").addEventListener("click", () => setOvDate(ymd(new Date())));

// ------------------------------------------------------------------ boot

// ------------------------------------------------------------------ chat

function renderChat() {
  const box = $("#chat-messages");
  const empty = $("#chat-empty");
  if (empty) empty.style.display = state.chat.length ? "none" : "";
  box.querySelectorAll(".chat-msg").forEach((el) => el.remove());
  for (const m of state.chat) {
    const el = document.createElement("div");
    el.className = "chat-msg " + m.role;
    el.textContent = m.content || (m.role === "assistant" ? "…" : "");
    box.appendChild(el);
  }
  box.scrollTop = box.scrollHeight;
}

async function sendChat() {
  const input = $("#chat-input");
  const text = input.value.trim();
  if (!text || state.chatBusy) return;
  state.chatBusy = true;
  $("#chat-send").disabled = true;
  input.value = "";
  input.style.height = "auto";
  state.chat.push({ role: "user", content: text });
  const assistant = { role: "assistant", content: "" };
  state.chat.push(assistant);
  renderChat();

  try {
    const res = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: state.chat.slice(0, -1) }),
    });
    if (!res.ok) {
      let msg = res.statusText;
      try { msg = (await res.json()).error || msg; } catch (e) { /* not json */ }
      assistant.content = "⚠︎ " + msg;
      renderChat();
      return;
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      assistant.content += decoder.decode(value, { stream: true });
      renderChat();
    }
    if (!assistant.content) assistant.content = "(no response)";
    renderChat();
  } catch (e) {
    assistant.content = "⚠︎ " + e.message;
    renderChat();
  } finally {
    state.chatBusy = false;
    $("#chat-send").disabled = false;
    $("#chat-input").focus();
  }
}

$("#chat-form").addEventListener("submit", (e) => { e.preventDefault(); sendChat(); });
$("#chat-clear").addEventListener("click", () => { state.chat = []; renderChat(); $("#chat-input").focus(); });
$("#chat-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendChat(); }
});
$("#chat-input").addEventListener("input", (e) => {
  e.target.style.height = "auto";
  e.target.style.height = Math.min(e.target.scrollHeight, 160) + "px";
});

// ------------------------------------------------------------------ boot

window.addEventListener("hashchange", route);
route();
refreshStatus();
setInterval(refreshStatus, 10000);
// Keep today's timeline live.
setInterval(() => {
  if (state.tab === "timeline" && state.date === ymd(new Date()) && state.timeline) {
    const atEnd = state.shotIdx >= state.timeline.screenshots.length - 1;
    api("/api/timeline?date=" + state.date).then((tl) => {
      state.timeline = tl;
      const idx = state.shotIdx;
      renderTimeline();
      if (!atEnd) showShot(idx);
    }).catch(() => {});
  }
}, 30000);
