#!/bin/bash
# Wraps the SwiftPM release binaries in Tidepool.app.
# Signing and notarization are separate. See scripts/notarize.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${TIDEPOOL_VERSION:-0.1.0}"
build="${root}/.build/release"
app="${root}/dist/Tidepool.app"

swift build -c release --product Tidepool --product cmb-hook

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "${build}/Tidepool" "$app/Contents/MacOS/Tidepool"
cp "${build}/cmb-hook" "$app/Contents/MacOS/cmb-hook"
chmod 755 "$app/Contents/MacOS/Tidepool" "$app/Contents/MacOS/cmb-hook"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Tidepool</string>
  <key>CFBundleIdentifier</key>
  <string>com.jynxed.tidepool</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Tidepool</string>
  <key>CFBundleDisplayName</key>
  <string>Tidepool</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "Assembled $app"
