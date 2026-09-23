#!/bin/bash
# Build the Swift agent and wrap it into build/Slock.app (ad-hoc signed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/agent"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Slock"

APP="$ROOT/build/Slock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Slock"
cp "$ROOT/agent/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/agent/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/web" "$APP/Contents/Resources/web"
find "$APP/Contents/Resources/web" -name __pycache__ -prune -exec rm -rf {} +

# Sign with the stable local "Slock" identity (see scripts/make-cert.sh) so macOS privacy
# permissions survive rebuilds. Ad-hoc signatures change every build and make macOS re-prompt.
KC="$HOME/Library/Keychains/slock-signing.keychain-db"
IDENTITY=""
if [ -f "$KC" ]; then
  security unlock-keychain -p slock-signing "$KC"
  IDENTITY="$(security find-identity -p codesigning "$KC" | awk '/"Slock"/ { print $2; exit }')"
fi
KC_ARGS=()
if [ -n "$IDENTITY" ]; then
  KC_ARGS=(--keychain "$KC")
else
  echo "warning: no \"Slock\" signing identity (run scripts/make-cert.sh); using ad-hoc signing," >&2
  echo "         so you'll have to re-grant permissions after every rebuild." >&2
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" ${KC_ARGS[@]+"${KC_ARGS[@]}"} --identifier dev.slock.agent "$APP"
echo "Built $APP (signed with: $IDENTITY)"
