#!/bin/bash
# Builds a shareable disk image: dist/ClaudeNotch-<version>.dmg, one app for Apple silicon and Intel Macs.
#
#   ./package.sh
#       Ad-hoc signed. Recipients approve it once in System Settings → Privacy & Security.
#
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./package.sh
#       Signed with your Developer ID (hardened runtime, secure timestamp).
#
#   CODESIGN_IDENTITY="…" NOTARY_PROFILE=claudenotch ./package.sh
#       …and notarized by Apple and stapled, so it opens without any warning. Create the profile once with:
#       xcrun notarytool store-credentials claudenotch --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
IDENTITY="${CODESIGN_IDENTITY:--}"
DIST=dist
DMG="$DIST/ClaudeNotch-$VERSION.dmg"
# Stage outside this folder: Finder and Desktop/iCloud sync attach attributes that break the signature.
STAGE=$(mktemp -d -t claudenotch)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ClaudeNotch.app"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" == "-" ]]; then
  echo "Notarizing needs CODESIGN_IDENTITY set to a Developer ID Application certificate." >&2
  exit 1
fi

echo "Building ClaudeNotch $VERSION for Apple silicon and Intel…"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

rm -rf "$DIST"
mkdir -p "$DIST" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeNotch" "$BIN/claudenotch-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
xattr -cr "$APP" # Finder / iCloud attributes make code signing fail

# The helper first, then the app around it.
if [[ "$IDENTITY" == "-" ]]; then
  SIGN=(--force --sign -)
else
  SIGN=(--force --options runtime --timestamp --sign "$IDENTITY")
fi
codesign "${SIGN[@]}" "$APP/Contents/MacOS/claudenotch-hook"
codesign "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"

# The disk image: the app, a shortcut to Applications, and a short read-me.
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<EOF
ClaudeNotch $VERSION — your Claude Code sessions in the notch

Install
1. Drag ClaudeNotch onto the Applications folder.
2. Open ClaudeNotch from Applications.
3. If macOS says it can't verify the app: open System Settings → Privacy & Security,
   scroll down, click "Open Anyway" next to ClaudeNotch, and confirm. Only needed once.

Use
- Hover over the notch (or the small pill at the top of a screen without one) to see your sessions.
- The first time, ClaudeNotch asks whether it may add hooks to ~/.claude/settings.json.
  Say yes to Allow/Deny requests and reply to Claude from the notch.
- Right-click the notch for settings, Launch at Login and Quit.

Needs macOS 14 or later and Claude Code (desktop app or CLI). Everything stays on your Mac.
EOF
xattr -cr "$APP"
hdiutil create -volname "ClaudeNotch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

# Check the app exactly as recipients will get it.
MOUNT=$(mktemp -d -t claudenotch-dmg)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
VERIFIED=1
codesign --verify --deep --strict "$MOUNT/ClaudeNotch.app" || VERIFIED=0
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT"
if [[ $VERIFIED == 0 ]]; then echo "The app inside the disk image fails signature checks." >&2; exit 1; fi
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing (this usually takes a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo
echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
echo "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
[[ "$IDENTITY" == "-" ]] && echo "Ad-hoc signed: recipients approve it once in Privacy & Security." || true
