#!/bin/zsh
# Builds "Glasses.app" (the web interface in the menu bar) into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release --product visor-web
APP="$HOME/Applications/Glasses.app"
# Earlier builds were called Lunettes.app: quit and remove that one, only if this project built it.
OLD="$HOME/Applications/Lunettes.app"
if [ -d "$OLD" ] && [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$OLD/Contents/Info.plist" 2>/dev/null)" = "io.github.rayban-meta-mac.lunettes" ]; then
  pkill -x Lunettes 2>/dev/null && sleep 1
  rm -rf "$OLD"
  echo "Removed the previous build, $OLD"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/visor-web "$APP/Contents/MacOS/Glasses"
cp -R web "$APP/Contents/Resources/web"
# Icon from web/icon.svg, rendered by Quick Look.
TMP=$(mktemp -d)
qlmanage -t -s 1024 -o "$TMP" web/icon.svg >/dev/null 2>&1 || true
if [ -f "$TMP/icon.svg.png" ]; then
  mkdir -p "$TMP/Glasses.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.svg.png" --out "$TMP/Glasses.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.svg.png" --out "$TMP/Glasses.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/Glasses.iconset" -o "$APP/Contents/Resources/Glasses.icns" || true
fi
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glasses</string>
  <key>CFBundleDisplayName</key><string>Glasses</string>
  <key>CFBundleIdentifier</key><string>io.github.rayban-meta-mac.glasses</string>
  <key>CFBundleExecutable</key><string>Glasses</string>
  <key>CFBundleIconFile</key><string>Glasses</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Glasses connects to your Ray-Ban Meta glasses over Bluetooth to read their gallery, status and settings.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Glasses brings the photos and videos over the Wi-Fi network the glasses create.</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
