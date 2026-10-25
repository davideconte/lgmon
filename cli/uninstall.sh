#!/bin/bash
# Removes the lgmon command. Pairing data stays in ~/.config/lgmon.
rm -f "$HOME/.local/bin/lgmon"
echo "lgmon command removed. Delete ~/.config/lgmon to forget the pairing too."
