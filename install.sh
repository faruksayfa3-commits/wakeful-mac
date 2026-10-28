#!/bin/zsh
# Builds Vigil, installs it to /Applications, adds the `vigil` command and a login item.
# Needs your password ONCE for a narrow sudoers rule that allows exactly these commands, nothing else:
#   pmset -a disablesleep 0|1     pmset -a lowpowermode 0|1
set -e
cd "${0:A:h}"
./build.sh
pkill -x Vigil 2>/dev/null || true
rm -rf /Applications/Vigil.app && cp -R build/Vigil.app /Applications/
mkdir -p ~/.local/bin && cp bin/vigil ~/.local/bin/vigil && chmod +x ~/.local/bin/vigil

RULE="$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"
TMP=$(mktemp)
echo "$RULE" > $TMP
if sudo visudo -cf $TMP >/dev/null; then
  sudo install -m 0440 -o root -g wheel $TMP /etc/sudoers.d/vigil
else
  echo "sudoers check failed — not installing the rule"; rm $TMP; exit 1
fi
rm $TMP

PLIST=~/Library/LaunchAgents/app.vigil.mac.plist
cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.vigil.mac</string>
<key>ProgramArguments</key><array><string>/Applications/Vigil.app/Contents/MacOS/Vigil</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PL
launchctl bootout gui/$(id -u) $PLIST 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $PLIST
echo "Vigil installed. Look for the eye in the menu bar. Try: vigil status   (add ~/.local/bin to PATH if needed)"
