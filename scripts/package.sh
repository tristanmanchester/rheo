#!/bin/bash
# Produce the signed, notarized universal ZIP consumed by the Homebrew cask.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ ${SIGN_IDENTITY:-} == "Developer ID Application:"* ]] || {
  echo 'Set SIGN_IDENTITY to your Developer ID Application identity.' >&2
  exit 1
}
command -v asc >/dev/null || { echo 'Install and authenticate asc before packaging.' >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' src/macos/Info.plist)
archive="dist/Rheo-$version-universal.zip"
[[ ! -e "$archive" ]] || { echo "Release archive already exists: $archive" >&2; exit 1; }

ARCHS="arm64 x86_64" ./scripts/build.sh
xcrun lipo dist/Rheo.app/Contents/MacOS/rheo -verify_arch arm64 x86_64
codesign --verify --deep --strict --verbose=2 dist/Rheo.app

submission=$(mktemp -d "${TMPDIR:-/tmp}/rheo-notarization.XXXXXX")
trap 'rm -rf "$submission"' EXIT
ditto -c -k --keepParent dist/Rheo.app "$submission/Rheo.zip"
asc notarization submit --file "$submission/Rheo.zip" --wait --timeout 30m \
  > "dist/notarization-$version.json"
xcrun stapler staple dist/Rheo.app
xcrun stapler validate dist/Rheo.app
spctl --assess --type execute --verbose=2 dist/Rheo.app

ditto -c -k --keepParent dist/Rheo.app "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > "Rheo-$version-SHA256SUMS.txt")
printf '\nRelease archive: %s\n' "$archive"
