cask "justausagebar" do
  version "1.1.4"
  sha256 "e36a8ed444bd1689d5fcc2040177e82b335935d00b4795fb5add8d73566b6a0b"

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
