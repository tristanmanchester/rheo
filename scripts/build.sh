#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'The native app requires macOS + Apple Command Line Tools.' >&2; exit 1; }
command -v xcrun >/dev/null || { echo 'Install Apple Command Line Tools: xcode-select --install' >&2; exit 1; }
source scripts/common.sh
sn_require_rust
export MACOSX_DEPLOYMENT_TARGET=15.0
cc=$(xcrun --find clang)
sdk=$(xcrun --show-sdk-path)
binaries=()
for arch in ${ARCHS:-$(uname -m)}; do
  case "$arch" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
  # Install requested Rust targets explicitly before building; no network fetch here.
  sn_build_rust "$triple"
  mkdir -p "build/native/$arch"
  binary="build/native/$arch/rheo"
  "$cc" -isysroot "$sdk" -arch "$arch" -mmacosx-version-min=15.0 -std=c17 -O3 -DNDEBUG \
    -fno-fast-math -Wall -Wextra -Werror -I src/core -fobjc-arc -fblocks \
    src/macos/main.m src/macos/platform.m src/macos/runtime.m "$SN_RUST_LIB" \
    "${SN_NATIVE_LIBS[@]}" -framework Cocoa -framework ApplicationServices -framework Carbon \
    -Wl,-dead_strip -o "$binary"
  binaries+=("$binary")
done
[[ ${#binaries[@]} -gt 0 ]] || { echo 'ARCHS must contain at least one architecture.' >&2; exit 1; }
mkdir -p dist/Rheo.app/Contents/MacOS
if [[ ${#binaries[@]} == 1 ]]; then cp "${binaries[0]}" dist/Rheo.app/Contents/MacOS/rheo
else xcrun lipo -create "${binaries[@]}" -output dist/Rheo.app/Contents/MacOS/rheo; fi
cp src/macos/Info.plist dist/Rheo.app/Contents/Info.plist
mkdir -p dist/Rheo.app/Contents/Resources
cp LICENSE THIRD_PARTY_NOTICES.md dist/Rheo.app/Contents/Resources/
sign_flags=()
if [[ ${SIGN_IDENTITY:--} != - ]]; then
  sign_flags=(--options runtime --timestamp)
fi
codesign --force --sign "${SIGN_IDENTITY:--}" ${sign_flags[@]+"${sign_flags[@]}"} dist/Rheo.app
codesign --verify --strict --verbose=2 dist/Rheo.app
printf '\nBuilt %s/dist/Rheo.app (Rust core + native AppKit adapter)\n' "$PWD"
