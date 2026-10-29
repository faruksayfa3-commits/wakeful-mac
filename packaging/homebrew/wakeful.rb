# Homebrew cask for Wakeful. There is no tap yet: copy this file to <your-tap>/Casks/wakeful.rb.
# Every GitHub Release also attaches a copy with version and sha256 already filled in (wakeful.rb).
cask "wakeful" do
  version "1.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE" # contents of Wakeful-<version>.zip.sha256 on the release page

  url "https://github.com/faruksayfa3-commits/wakeful-mac/releases/download/v#{version}/Wakeful-#{version}.zip"
  name "Wakeful"
  desc "Keeps a Mac awake with the lid closed only while AI agents and long tasks run"
  homepage "https://github.com/faruksayfa3-commits/wakeful-mac"

  depends_on macos: ">= :monterey"

  app "Wakeful.app"
  binary "#{appdir}/Wakeful.app/Contents/Resources/wakeful"

  uninstall quit:      "app.wakeful.mac",
            launchctl: "app.wakeful.mac"

  zap trash: [
    "~/Library/Application Support/Wakeful",
    "~/Library/LaunchAgents/app.wakeful.mac.plist",
    "~/Library/Preferences/app.wakeful.mac.plist",
  ]

  caveats <<~EOS
    Wakeful needs a narrow sudoers rule to keep the Mac awake with the lid closed.
    It allows exactly `pmset -a disablesleep 0|1` and `pmset -a lowpowermode 0|1`, nothing else.
    Create it once (asks for your password):
      #{appdir}/Wakeful.app/Contents/Resources/setup-sudoers.sh
    Then check everything with:
      wakeful doctor

    Wakeful is ad-hoc signed, not notarized. If macOS refuses to open it:
      xattr -dr com.apple.quarantine #{appdir}/Wakeful.app

    Uninstalling leaves the sudoers rule in place. To remove it:
      sudo rm /etc/sudoers.d/wakeful
  EOS
end
