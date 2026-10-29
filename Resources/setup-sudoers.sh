#!/bin/zsh
# Creates /etc/sudoers.d/wakeful: a rule that allows exactly these commands without a password, nothing else:
#   pmset -a disablesleep 0|1     pmset -a lowpowermode 0|1
# Run by install.sh, or on its own (zip / Homebrew installs):  /Applications/Wakeful.app/Contents/Resources/setup-sudoers.sh
set -e
RULE="$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"
TMP=$(mktemp)
echo "$RULE" > $TMP
if sudo visudo -cf $TMP >/dev/null; then
  sudo install -m 0440 -o root -g wheel $TMP /etc/sudoers.d/wakeful
else
  echo "sudoers check failed — not installing the rule"; rm $TMP; exit 1
fi
rm $TMP
echo "Sudoers rule installed: /etc/sudoers.d/wakeful"
