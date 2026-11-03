#!/bin/zsh
# Builds "Lunettes.app" (the web interface in the menu bar) into ~/Applications.
set -e
cd "$(dirname "$0")"
swift build -c release --product visor-web
APP="$HOME/Applications/Lunettes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/visor-web "$APP/Contents/MacOS/Lunettes"
cp -R web "$APP/Contents/Resources/web"
# Icon from web/icon.svg, rendered by Quick Look.
TMP=$(mktemp -d)
qlmanage -t -s 1024 -o "$TMP" web/icon.svg >/dev/null 2>&1 || true
if [ -f "$TMP/icon.svg.png" ]; then
  mkdir -p "$TMP/Lunettes.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.svg.png" --out "$TMP/Lunettes.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.svg.png" --out "$TMP/Lunettes.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/Lunettes.iconset" -o "$APP/Contents/Resources/Lunettes.icns" || true
fi
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lunettes</string>
  <key>CFBundleDisplayName</key><string>Lunettes</string>
  <key>CFBundleIdentifier</key><string>io.github.rayban-meta-mac.lunettes</string>
  <key>CFBundleExecutable</key><string>Lunettes</string>
  <key>CFBundleIconFile</key><string>Lunettes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Lunettes se connecte à tes Ray-Ban Meta en Bluetooth pour lire leur galerie, leur état et leurs réglages.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Lunettes récupère les photos et vidéos par le Wi-Fi que créent les lunettes.</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "OK : $APP"
