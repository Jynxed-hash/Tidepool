# TEMPLATE. Not published to Jynxed-hash/homebrew-tap.
# `brew install --cask` will fail until a signed, notarized DMG exists
# and this file is copied into the tap with a real sha256.
cask "tidepool" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Jynxed-hash/Tidepool/releases/download/v#{version}/Tidepool-#{version}.dmg"
  name "Tidepool"
  desc "Menu bar usage and sessions for Claude Code"
  homepage "https://github.com/Jynxed-hash/Tidepool"

  depends_on macos: ">= :tahoe"

  app "Tidepool.app"

  zap trash: [
    "~/Library/Application Support/Tidepool",
    "~/Library/Preferences/com.jynxed.tidepool.plist",
  ]
end
