#!/bin/bash
# lgmon installer. Usage: ./install.sh [--no-hotkeys]
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="io.github.lgmon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HOTKEYS=1
[[ "${1:-}" == "--no-hotkeys" ]] && HOTKEYS=0

step() { printf "\n\033[1m%s\033[0m\n" "$1"; }

step "1/4  Python environment"
python3 -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install --quiet --upgrade pip
"$DIR/.venv/bin/pip" install --quiet -r "$DIR/requirements.txt"

step "2/4  lgmon command"
mkdir -p "$HOME/.local/bin"
ln -sf "$DIR/bin/lgmon" "$HOME/.local/bin/lgmon"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to your PATH to run 'lgmon' from anywhere." ;; esac

step "3/4  Pairing (accept the prompt on the monitor if it appears)"
"$DIR/bin/lgmon" discover
"$DIR/bin/lgmon"

if [[ $HOTKEYS == 0 ]]; then
  echo; echo "Done. Try: lgmon brightness 40"; exit 0
fi

step "4/4  Keyboard shortcuts (daemon + Hammerspoon)"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/.venv/bin/python</string><string>$DIR/lgmond.py</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/lgmond.log</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

if [[ ! -d /Applications/Hammerspoon.app ]]; then
  echo "Hammerspoon not found. Install it (brew install --cask hammerspoon) and run ./install.sh again."
  exit 0
fi
mkdir -p "$HOME/.hammerspoon"
ln -sf "$DIR/hammerspoon/lgmon.lua" "$HOME/.hammerspoon/lgmon.lua"
INIT="$HOME/.hammerspoon/init.lua"
touch "$INIT"
grep -q 'require("lgmon")' "$INIT" || printf '\nlgmon = require("lgmon").start()\n' >> "$INIT"
# restart Hammerspoon so it loads the new config
osascript -e 'quit app "Hammerspoon"' 2>/dev/null || true
sleep 1
open -a Hammerspoon

echo
echo "Done. Brightness: ⌥ + volume keys, or ⌃⌥↑ / ⌃⌥↓. Volume keys drive the monitor"
echo "when your Mac sends audio to it. Hammerspoon needs Accessibility permission."
