cask "paluku" do
  version "1.0.0"
  sha256 "99e91519b2e7075f6bd101c3474a49c12574d31f09c9b0f485d75abf0c88815a"

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
