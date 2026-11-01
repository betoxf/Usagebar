# frozen_string_literal: true

cask "usagebar" do
  version "1.13.0"
  sha256 "7e70d4e7c6cb7f7189d51eae2ef52831ad5055223b9a383ddfc24b4e12b07659"

  url "https://github.com/betoxf/Usagebar/releases/download/v#{version}/Usagebar.zip"
  name "Usagebar"
  desc "Menu bar app showing Claude, Codex, and Kimi Code usage statistics"
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
