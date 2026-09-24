# slock

Flock, but for your computer. Slock quietly records what happens on your Mac so you can scroll back through your day, search anything you've seen, and see where your time went. Everything stays local.

**What it records**
- **App & window activity**: the frontmost app and window title, stored as time spans
- **Screenshots**: every 10s per display. Duplicates are skipped, and text is OCR'd on-device with Apple Vision, so it's searchable
- **Browser URLs**: from Safari, Chrome, Arc, Brave, Edge and Vivaldi. Incognito windows are skipped
- **Shell commands**: with cwd, exit code and duration. Your existing `~/.zsh_history` is imported once
- **Typed text**: what you type, per app and window, searchable like screen text (`keystrokeCaptureEnabled`, on by default). macOS never hands keystrokes from secure password fields to Slock, so those aren't captured; typing in excluded/password-manager/private windows is skipped too. Needs Accessibility and **Input Monitoring**
- **System events**: sleep/wake, lock/unlock, idle, app launch/quit, network changes, USB/volume mounts, new downloads

**What it doesn't record**: audio, passwords typed into secure fields (macOS withholds these), and anything while the app is paused, the screen is locked or the Mac is idle. It also skips the windows of password managers (1Password, Bitwarden, Keychain Access, Passwords, LastPass). Set `keystrokeCaptureEnabled` to `false` to turn off typed-text capture entirely.

## Install

```sh
make install      # builds Slock.app → ~/Applications, starts it at login (menu bar only)
make shell-hook   # optional: adds one line to ~/.zshrc to log terminal commands
```

Slock is a normal Mac app. Open it from Spotlight, Launchpad, the Dock or the menu-bar icon (→ Open Slock) to get its window. Closing the window doesn't stop recording, which carries on from the menu bar. Choose Quit Slock (⌘Q) to stop it completely. The dashboard is also available in a browser at http://127.0.0.1:8765 while Slock is running.

Then grant the permissions in **System Settings → Privacy & Security**:

| Permission | For |
|---|---|
| Screen Recording | Screenshots. Restart Slock after granting (`make restart`) |
| Accessibility | Window titles |
| Input Monitoring | Typed text (only if `keystrokeCaptureEnabled`). Restart Slock after granting |
| Automation → each browser | Tab URLs. You'll be prompted the first time |
| Files & Folders → Downloads | Download log. You'll be prompted |

> `make build` creates a local self-signed code-signing certificate named `Slock` in your login keychain (`scripts/make-cert.sh`) and signs the app with it. macOS then recognizes the app as the same one across rebuilds and keeps its permissions. On the first build, macOS asks whether `codesign` may use the key. Click **Always Allow**. If permissions ever get stuck (the toggle is on but Slock keeps asking), run `make reset-permissions`, re-grant them, and choose **Restart Slock** from the menu bar.

## The app window

- **Overview** (the default tab): an AI-written summary of your day. You get a headline, a short narrative, highlights and your time broken down by category, plus a title and summary for every half hour. Apple's **on-device** model (Apple Intelligence, macOS 26+) writes them, so nothing leaves your Mac. Half-hour summaries appear automatically as each block finishes, and the day overview refreshes hourly. Click **Summarize now** to add a summary of everything since the last one, up to that minute (the automatic half-hour summaries still carry on), or click an entry to see specifics: what you read and wrote, and for chats who you talked to, what about and who said what (it re-reads that stretch's screenshots; in Messages, WhatsApp and other bubble-style chats your messages are told apart by being on the right).
- **Timeline**: a colored 24h strip of apps. Drag across it or use ←/→ to scrub through screenshots. Click a screenshot to view it full size. The side panel shows the window, URL and OCR text at that moment.
- **Search** (`/`): full-text search over everything that was on screen, plus window titles, URLs and shell commands. Click a result to jump to that moment.
- **Stats**: time per app and per website, an hour × weekday heatmap, daily totals and top shell commands.
- **Log**: a raw feed of system events, pages visited and commands run.

## Data & config

Everything lives in `~/.slock/`:

```
slock.db        SQLite (WAL): activity, screenshots, ocr (FTS5), shell, events, keystrokes (FTS5)
shots/DATE/     JPEG screenshots (deleted after 30 days; text is kept forever)
config.json     settings (created with defaults on first run)
paused          present = recording paused (menu bar / dashboard toggle)
agent.log       agent log
```

`config.json` keys: `screenshotIntervalSeconds`, `idleThresholdSeconds`, `screenshotRetentionDays`, `screenshotMaxWidth`, `jpegQuality`, `duplicateHashDistance`, `ocrEnabled`, `excludedBundleIds`, `excludedUrlPatterns`, `dashboardPort`, `keystrokeCaptureEnabled`, `keystrokeIdleFlushSeconds`. Run `make restart` after editing it.

Screenshots take roughly 1–3 GB a day of active use at the defaults. To use less, lower `jpegQuality` or `screenshotMaxWidth`, or raise the interval.

## Development

```sh
make build     # SwiftPM release build → build/Slock.app
make run       # run the agent in the foreground
make dev-web   # run the dashboard server from the repo (for editing web/ without rebuilding)
make icon      # regenerate agent/AppIcon.icns
make logs      # tail the agent log
make uninstall # removes the app and launch agents; keeps ~/.slock
```

Layout: `agent/` (the Swift app: recorders, menu bar and a WKWebView window), `web/` (stdlib Python server + vanilla JS UI, bundled into the app and run as a child process), `shell/slock.zsh` (zsh hook), `launchd/` (login item).
