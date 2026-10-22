#!/bin/bash
# Submits an already-built DMG to Apple notarytool and staples the ticket.
# Requires a keychain profile created ahead of time:
#   xcrun notarytool store-credentials "$NOTARY_KEYCHAIN_PROFILE" \
#     --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD"
# The DMG must already be signed (Developer ID). This repo does not ship a
# certificate. Exit is non-zero when the profile or the DMG is missing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${TIDEPOOL_VERSION:-0.1.0}"
dmg="${1:-${root}/dist/Tidepool-${version}.dmg}"
profile="${NOTARY_KEYCHAIN_PROFILE:-}"

if [[ ! -f "$dmg" ]]; then
  echo "DMG not found: $dmg" >&2
  echo "Run scripts/build-dmg.sh on macOS first." >&2
  exit 1
fi
if [[ -z "$profile" ]]; then
  echo "Set NOTARY_KEYCHAIN_PROFILE to a notarytool keychain profile." >&2
  exit 1
fi

xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
echo "Stapled $dmg"
