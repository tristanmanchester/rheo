#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
app="$HOME/Applications/Rheo.app"
mkdir -p "$HOME/Applications"
if [[ -e "$app" ]]; then
  echo "An installation already exists at $app. Quit it and move it aside before installing." >&2
  exit 1
fi
cp -R dist/Rheo.app "$app"
open "$app"
printf 'Installed: %s\nCLI: "%s/Contents/MacOS/rheo" status\n' "$app" "$app"
