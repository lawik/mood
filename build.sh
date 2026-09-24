#!/usr/bin/env bash
# Builds build/Overlay.app with swiftc alone — no Xcode project, no xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Overlay.app"
ARCH="$(uname -m)"

# Build into a staging bundle and swap it in at the end. A running instance
# keeps the inode of the executable it already opened, so rebuilding never
# yanks the overlay off the screen mid-session.
STAGE="$ROOT/build/.stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

# A bundle (rather than a bare executable) is not optional here: WKWebView needs
# bundle identity to spin up its web content process, and LSUIElement is what
# keeps the app out of the Dock and the app switcher.
cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Overlay</string>
  <key>CFBundleDisplayName</key>       <string>Overlay</string>
  <key>CFBundleExecutable</key>        <string>Overlay</string>
  <key>CFBundleIdentifier</key>        <string>se.underjord.goatmire.overlay</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <!-- Accessory app: no Dock icon, never becomes the active app. -->
  <key>LSUIElement</key>               <true/>
  <!-- So --url http://localhost:PORT is not blocked by App Transport Security. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

swiftc \
  -swift-version 5 \
  -O \
  -target "${ARCH}-apple-macos14.0" \
  -framework AppKit -framework WebKit \
  "$ROOT"/Sources/*.swift \
  -o "$STAGE/Contents/MacOS/Overlay"

# Ship a copy of the page so the .app runs standalone; ./run.sh points at the
# working copy in web/ instead, for live reload.
cp -R "$ROOT/web" "$STAGE/Contents/Resources/web"

# Sign with a real identity when one exists. This matters for --capture-keys:
# macOS records an Accessibility grant against the app's designated requirement,
# and an ad-hoc signature has no stable identity, so its requirement pins the
# cdhash. That changes on every build, and the permission has to be granted
# again each time. A certificate makes the requirement stable across rebuilds.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Select by SHA-1 hash, not by name: several certificates can share one common
  # name (expired ones linger in the keychain), and `codesign -s <name>` fails as
  # ambiguous if more than one of them is valid. -v lists valid identities only.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/^ *[0-9]+\)/ { print $2; exit }')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  if codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGE" >/dev/null 2>&1; then
    echo "build.sh: signed as $SIGN_IDENTITY"
  else
    echo "build.sh: signing as '$SIGN_IDENTITY' failed, falling back to ad-hoc" >&2
    codesign --force --sign - --timestamp=none "$STAGE" >/dev/null 2>&1 || true
  fi
else
  codesign --force --sign - --timestamp=none "$STAGE" >/dev/null 2>&1 \
    || echo "build.sh: ad-hoc codesign failed (usually harmless locally)"
  echo "build.sh: no signing identity found; Accessibility permission will reset on every build"
fi

# Swap the staged bundle in. The rm only unlinks the path; anything already
# running carries on from the inode it holds.
rm -rf "$APP"
mv "$STAGE" "$APP"

echo "built $APP"
if pgrep -f "Overlay.app/Contents/MacOS/Overlay" >/dev/null 2>&1; then
  echo "build.sh: an overlay is still running on the previous build; restart it to pick this up"
fi
