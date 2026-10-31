# frozen_string_literal: true

cask "usagebar" do
  version "1.12.1"
  sha256 "3063289262b30358b8a50494f5c9630430895192c949bc71df856bb15c6eb97a"

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
