# frozen_string_literal: true

cask "usagebar" do
  version "1.9.0"
  sha256 "9ac44d1d394a68b00dee3d3b20f87b671b01603b1e0b36076ae2a961f1bd2ffe"

  url "https://github.com/betoxf/Usagebar/releases/download/v#{version}/Usagebar.zip"
  name "Usagebar"
  desc "Menu bar app showing Claude, Codex, and KimiCode usage statistics"
  homepage "https://github.com/betoxf/Usagebar"

  depends_on macos: :sonoma

  app "Usagebar.app"

  # Keep the installer compatible with Homebrew versions predating structured install steps.
  postflight do # rubocop:disable Cask/InstallSteps
    system_command "/usr/bin/xattr",
                   args: ["-c", "#{appdir}/Usagebar.app"]
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/Usagebar.app"]
  end

  uninstall quit: "bullfigherstudios.JustaUsageBar"

  zap trash: [
    "~/Library/Application Support/JustaUsageBar",
    "~/Library/Caches/bullfigherstudios.JustaUsageBar",
    "~/Library/Preferences/bullfigherstudios.JustaUsageBar.plist",
  ]
end
