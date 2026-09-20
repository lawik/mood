#!/usr/bin/env bash
# Builds build/Overlay.app with swiftc alone — no Xcode project, no xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Overlay.app"
ARCH="$(uname -m)"

# Rebuilding deletes the bundle out from under a running instance.
if pgrep -f "Overlay.app/Contents/MacOS/Overlay" >/dev/null 2>&1; then
  echo "build.sh: stopping the running overlay first"
  pkill -f "Overlay.app/Contents/MacOS/Overlay" || true
  sleep 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# A bundle (rather than a bare executable) is not optional here: WKWebView needs
# bundle identity to spin up its web content process, and LSUIElement is what
# keeps the app out of the Dock and the app switcher.
cat > "$APP/Contents/Info.plist" <<'PLIST'
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
  "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/Overlay"

# Ship a copy of the page so the .app runs standalone; ./run.sh points at the
# working copy in web/ instead, for live reload.
cp -R "$ROOT/web" "$APP/Contents/Resources/web"

# Ad-hoc signature. Locally built code is not quarantined, so this is enough.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "build.sh: ad-hoc codesign failed (usually harmless locally)"

echo "built $APP"
