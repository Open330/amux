# Homebrew cask for amux. Publish to Open330/homebrew-tap so users can
# `brew install --cask open330/tap/amux`.
#
# `version` + `sha256` identify the most recent immutable published release.
# Update both after the release workflow prints the new DMG checksum.
cask "amux" do
  version "0.1.0-alpha"
  sha256 "58a18448b0cd0c1a0ba5209474d556e6e99b01d8d45b74303327b1a2b127fc33"

  url "https://github.com/Open330/amux/releases/download/v#{version}/amux-macos.dmg"
  name "amux"
  desc "tmux-native, agent-first terminal for macOS"
  homepage "https://github.com/Open330/amux"

  # amux ships Sparkle; let it self-update once installed.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "amux.app"

  zap trash: [
    "~/Library/Application Support/com.open330.amux",
    "~/Library/Caches/com.open330.amux",
    "~/Library/Preferences/com.open330.amux.plist",
    "~/Library/LaunchAgents/com.open330.amux.muxad.plist",
  ]
end
