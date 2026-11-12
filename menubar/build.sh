#!/bin/sh
# Builds the menu bar / floating HUD app next to this script.
# Needs the Xcode command line tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o usage-hp-menubar
echo "built: $(pwd)/usage-hp-menubar"
