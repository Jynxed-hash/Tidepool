#!/bin/bash
# Wraps the SwiftPM release binaries in Tidepool.app.
# Signing and notarization are separate. See scripts/notarize.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="${TIDEPOOL_VERSION:-0.1.0}"
app="${root}/dist/Tidepool.app"

# SwiftPM applies only the last --product in one invocation, so a combined
# `swift build --product Tidepool --product cmb-hook` leaves Tidepool out.
swift build -c release --product Tidepool
swift build -c release --product cmb-hook

# Absolute path from SwiftPM. Xcode 27 uses .build/out/Products/Release,
# not .build/release. Do not prefix this with the repo root.
build="$(swift build -c release --show-bin-path)"
case "$build" in
  /*) ;;
  *)
    echo "assemble-app: swift build -c release --show-bin-path did not return an absolute path: ${build}" >&2
    exit 1
    ;;
esac

require_binary() {
  local name="$1"
  local path="${build}/${name}"
  if [[ ! -e "$path" ]]; then
    echo "assemble-app: missing release binary ${path}" >&2
    echo "assemble-app: swift build -c release --product ${name} did not produce it." >&2
    exit 1
  fi
  if [[ ! -x "$path" ]]; then
    echo "assemble-app: release binary is not executable: ${path}" >&2
    exit 1
  fi
}

require_binary Tidepool
require_binary cmb-hook

echo "Release binaries: ${build}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "${build}/Tidepool" "$app/Contents/MacOS/Tidepool"
cp "${build}/cmb-hook" "$app/Contents/MacOS/cmb-hook"
chmod 755 "$app/Contents/MacOS/Tidepool" "$app/Contents/MacOS/cmb-hook"

icon="${root}/Sources/Tidepool/Resources/AppIcon.icns"
if [[ ! -f "$icon" ]]; then
  echo "assemble-app: missing app icon ${icon}" >&2
  exit 1
fi
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
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
