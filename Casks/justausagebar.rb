cask "justausagebar" do
  version "1.1.3"
  sha256 "b8d8f0e530b32f5a35c23ea50dca2b5546f9b875b80c3f05a9bae768a1f90628"

  url "https://github.com/betoxf/JustaUsageBar/releases/download/v#{version}/JustaUsageBar.zip"
  name "Just A Usage Bar"
  desc "Menu bar app showing Claude and Codex usage statistics"
  homepage "https://github.com/betoxf/JustaUsageBar"

  depends_on macos: ">= :sonoma"

  app "JustaUsageBar.app"

  postflight do
    # Remove quarantine flag so Gatekeeper doesn't block the unsigned app
    system_command "/usr/bin/xattr",
                   args: ["-c", "#{appdir}/JustaUsageBar.app"]
    # Launch the app immediately after install
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/JustaUsageBar.app"]
  end

  zap trash: [
    "~/Library/Application Support/JustaUsageBar",
    "~/Library/Preferences/bullfigherstudios.JustaUsageBar.plist",
    "~/Library/Caches/bullfightertudios.JustaUsageBar",
  ]
end
