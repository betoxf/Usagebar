cask "justausagebar" do
  version "1.5.4"
  sha256 "66d1f3d25fa2edd066ba27c51cf08d16a1924c4d81f85e9760e72b7ba55a2963"

  url "https://github.com/betoxf/Usagebar/releases/download/v#{version}/Usagebar.zip"
  name "Usagebar"
  desc "Menu bar app showing Claude and Codex usage statistics"
  homepage "https://github.com/betoxf/Usagebar"

  depends_on macos: ">= :sonoma"

  app "Usagebar.app"

  postflight do
    # Remove quarantine flag so Gatekeeper doesn't block the unsigned app
    system_command "/usr/bin/xattr",
                   args: ["-c", "#{appdir}/Usagebar.app"]
    # Launch the app immediately after install
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/Usagebar.app"]
  end

  zap trash: [
    "~/Library/Application Support/JustaUsageBar",
    "~/Library/Preferences/bullfigherstudios.JustaUsageBar.plist",
    "~/Library/Caches/bullfightertudios.JustaUsageBar",
  ]
end
