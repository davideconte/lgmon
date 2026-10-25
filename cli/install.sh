#!/bin/bash
# Installs the lgmon command line tool (the menu bar app is a separate download).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

step() { printf "\n\033[1m%s\033[0m\n" "$1"; }

step "1/3  Python environment"
python3 -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install --quiet --upgrade pip
"$DIR/.venv/bin/pip" install --quiet -r "$DIR/requirements.txt"

step "2/3  lgmon command"
mkdir -p "$HOME/.local/bin"
ln -sf "$DIR/bin/lgmon" "$HOME/.local/bin/lgmon"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to your PATH to run 'lgmon' from anywhere." ;; esac

step "3/3  Pairing (accept the prompt on the monitor if it appears)"
"$DIR/bin/lgmon" discover
"$DIR/bin/lgmon"

echo; echo "Done. Try: lgmon brightness 40"
