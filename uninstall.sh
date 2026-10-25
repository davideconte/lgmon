#!/bin/bash
# Removes the daemon, the command and the Hammerspoon link. Pairing data stays in ~/.config/lgmon.
LABEL="io.github.lgmon"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/lgmon" "$HOME/.hammerspoon/lgmon.lua"
sed -i '' '/require("lgmon")/d' "$HOME/.hammerspoon/init.lua" 2>/dev/null
echo "lgmon removed. Delete ~/.config/lgmon to forget the pairing too."
