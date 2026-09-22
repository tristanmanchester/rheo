#!/bin/bash
# Exercise preferences through the real app bundle on a fresh CI runner.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ ${CI:-} == true ]] || { echo 'Run this lifecycle test on a fresh CI runner.' >&2; exit 1; }
binary="$PWD/dist/Rheo.app/Contents/MacOS/rheo"
if "$binary" status >/dev/null 2>&1 || defaults read dev.rheo.app >/dev/null 2>&1; then
  echo 'This test requires no existing Rheo resident or preferences.' >&2
  exit 1
fi
resident_pid=
cleanup() {
  if [[ -n "$resident_pid" ]]; then
    "$binary" quit >/dev/null 2>&1 || kill "$resident_pid" 2>/dev/null || true
    wait "$resident_pid" 2>/dev/null || true
  fi
  defaults delete dev.rheo.app >/dev/null 2>&1 || true
}
trap cleanup EXIT
start() {
  "$binary" >build/resident-test.log 2>&1 &
  resident_pid=$!
  for _ in {1..50}; do
    if "$binary" status >build/resident-status.json 2>/dev/null; then return; fi
    sleep 0.1
  done
  cat build/resident-test.log >&2
  return 1
}
stop() {
  "$binary" quit >/dev/null
  wait "$resident_pid"
  resident_pid=
}
check() {
  "$binary" status | python3 -c 'import json,sys; s=json.load(sys.stdin); expected=sys.argv[1]=="on"; assert s["enabled"] is expected and s["hotkeys_requested"] is expected and s["desktop_shortcuts"] is (sys.argv[2]=="on"), s' "$1" "$2"
}
start
check on off
"$binary" enabled off
"$binary" hotkeys off
"$binary" desktop-shortcuts on
stop
start
check off on
"$binary" enabled on
"$binary" hotkeys on
"$binary" desktop-shortcuts off
stop
start
check on off
stop
echo 'PASS: real app defaults and all three preference values survive relaunch.'
