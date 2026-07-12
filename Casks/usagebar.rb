cask "usagebar" do
  version "1.5.2"
  sha256 "dea6f2884c8fcfae14949ed4aecddc3d0e7c21918862d4a7749c25065bc22821"

  url "https://github.com/betoxf/Usagebar/releases/download/v#{version}/Usagebar.zip"
  name "Usagebar"
  desc "Menu bar app showing Claude and Codex usage statistics"
  homepage "https://github.com/betoxf/Usagebar"

  depends_on macos: ">= :sonoma"

  app "Usagebar.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-c", "#{appdir}/Usagebar.app"]
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/Usagebar.app"]
  end

  zap trash: [
    "~/Library/Application Support/JustaUsageBar",
    "~/Library/Preferences/bullfigherstudios.JustaUsageBar.plist",
    "~/Library/Caches/bullfightertudios.JustaUsageBar",
  ]
end
