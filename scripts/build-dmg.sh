#!/bin/bash
# Builds a release app bundle and a read-only DMG.
# Notarization is not part of this script.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${TIDEPOOL_VERSION:-0.1.0}"
"${root}/scripts/assemble-app.sh"
mkdir -p "${root}/dist"
ditto -c -k --keepParent "${root}/dist/Tidepool.app" "${root}/dist/Tidepool-${version}.zip" >/dev/null
hdiutil create \
  -volname "Tidepool" \
  -srcfolder "${root}/dist/Tidepool.app" \
  -ov \
  -format UDZO \
  "${root}/dist/Tidepool-${version}.dmg"
echo "Wrote ${root}/dist/Tidepool-${version}.dmg"
