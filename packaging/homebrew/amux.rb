# Homebrew cask for amux. Publish to a tap (e.g. open330/homebrew-amux) so
# users can `brew install --cask open330/amux/amux`.
#
# `version` + `sha256` are updated by the release pipeline on each tag (the
# release workflow can `brew bump-cask-pr` or sed these fields). Until the
# first signed release exists, sha256 is :no_check.
cask "amux" do
  version "0.1.0-alpha"
  sha256 "4e5de2764a69ce010e7a5b12b02f8b4ccb7394bd663eb195eb99eef0726d300d"

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
