#!/usr/bin/env bash
# Builds a release binary and wraps it in a minimal AgentHub.app bundle.
# The bundle gives the app a bundle identifier, which macOS notifications need.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AgentHub"

APP="build/AgentHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentHub"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Hub</string>
  <key>CFBundleDisplayName</key><string>Agent Hub</string>
  <key>CFBundleIdentifier</key><string>dev.agenthub.AgentHub</string>
  <key>CFBundleExecutable</key><string>AgentHub</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper and the Keychain treat it as one stable app locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; app is unsigned"
echo "Built $APP"
