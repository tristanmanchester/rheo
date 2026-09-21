#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Graceful resident shutdown through the same IPC endpoint as the CLI.
if [[ -x dist/Rheo.app/Contents/MacOS/rheo ]]; then
  dist/Rheo.app/Contents/MacOS/rheo quit >/dev/null 2>&1 || true
fi
./scripts/build.sh
open -n "$PWD/dist/Rheo.app"
if [[ ${1:-} == --verify ]]; then
  for _ in {1..20}; do
    if dist/Rheo.app/Contents/MacOS/rheo status; then exit 0; fi
    sleep 0.1
  done
  exit 1
fi
