cask "paluku" do
  version "1.4.2"
  sha256 "110696e2cea6cae9c30ced156d25595dec9ab93f4a21e11b9397fe1b0b87109d"

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
