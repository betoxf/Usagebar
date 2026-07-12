cask "justausagebar" do
  version "1.6.1"
  sha256 "9e0d7780c1c059e9ebc356704acf9f67918a8b52671188e54c1f50ee0dd9b7fe"

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
