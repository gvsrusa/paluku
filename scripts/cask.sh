#!/bin/zsh
# Render the Homebrew cask for a released DMG. Called by release.yml after packaging.
# Usage: scripts/cask.sh X.Y.Z <sha256>  → writes Casks/paluku.rb
# Install: brew tap gvsrusa/paluku https://github.com/gvsrusa/paluku && brew install --cask paluku
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: scripts/cask.sh X.Y.Z sha256}
SHA=${2:?usage: scripts/cask.sh X.Y.Z sha256}
[[ $V =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
[[ $SHA =~ ^[0-9a-f]{64}$ ]] || { echo "sha256 must be 64 hex chars"; exit 1; }
cat > Casks/paluku.rb <<RB
cask "paluku" do
  version "$V"
  sha256 "$SHA"

  url "https://github.com/gvsrusa/paluku/releases/download/v#{version}/Paluku-#{version}.dmg"
  name "Paluku"
  desc "Local voice assistant: dictation, edit and agent modes with open-source models"
  homepage "https://github.com/gvsrusa/paluku"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Paluku.app"

  zap trash: [
    "~/Library/Application Support/Paluku",
    "~/Library/Preferences/com.gvsrusa.Paluku.plist",
  ]
end
RB
echo "✓ Casks/paluku.rb ($V)"
