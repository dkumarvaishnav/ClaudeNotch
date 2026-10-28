#!/bin/bash
# Builds ClaudeNotch.app. Pass --install to copy it to ~/Applications and (re)start it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/ClaudeNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeNotch "$APP/Contents/MacOS/ClaudeNotch"
cp .build/release/claudenotch-hook "$APP/Contents/MacOS/claudenotch-hook" # copied to ~/.claude/hooks on launch
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/MacOS/claudenotch-hook" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClaudeNotch 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/ClaudeNotch.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/ClaudeNotch.app
  echo "Installed and started ~/Applications/ClaudeNotch.app"
fi
