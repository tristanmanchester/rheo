#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
sn_require_rust
cargo test --workspace --locked --offline
cargo test --workspace --locked --offline --release
sn_build_rust
cc=${CC:-clang}
mkdir -p build/tests
SN_SAN_FLAGS=()
if [[ ${SANITIZE:-1} == 1 ]]; then SN_SAN_FLAGS=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
flags=(-std=c17 -O1 -g -fno-fast-math -Wall -Wextra -Wpedantic -Werror -UNDEBUG -I src/core)
for test in abi_tests core_tests; do
  "$cc" "${flags[@]}" ${SN_SAN_FLAGS[@]+"${SN_SAN_FLAGS[@]}"} "tests/$test.c" "$SN_RUST_LIB" \
    "${SN_NATIVE_LIBS[@]}" -o "build/tests/$test"
  "build/tests/$test"
done
sn_reference_objects
"$cc" "${flags[@]}" ${SN_SAN_FLAGS[@]+"${SN_SAN_FLAGS[@]}"} tests/differential.c "${SN_REFERENCE_OBJECTS[@]}" \
  "$SN_RUST_LIB" "${SN_NATIVE_LIBS[@]}" -o build/tests/differential
build/tests/differential
if command -v swiftc >/dev/null; then python3 tests/reproduce_upstream.py; fi
if [[ $(uname -s) == Darwin ]]; then
  "$cc" -std=c17 -O1 -g -Wall -Wextra -Werror -UNDEBUG -I src/core -I src/macos \
    -fobjc-arc -fblocks ${SN_SAN_FLAGS[@]+"${SN_SAN_FLAGS[@]}"} src/macos/platform.m tests/platform_tests.m \
    "$SN_RUST_LIB" "${SN_NATIVE_LIBS[@]}" -framework Cocoa -framework ApplicationServices \
    -o build/tests/platform-tests
  build/tests/platform-tests
fi
printf '\nRust tests, C ABI/layout checks, 33 legacy groups and differential checks passed.\n'
printf 'ASan/UBSan instrument the C harness/reference/adapter, NOT the stable Rust archive.\n'
