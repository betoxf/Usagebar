cask "usagebar" do
  version "1.2.5"
  sha256 "0465c381baa12460144e46ee8e499366d9ba9331ae416f29f200adfcad67b336"

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
