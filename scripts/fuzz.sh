#!/bin/bash
# Byte-mutated C harness exercises Rust through the ABI. Stable Rust is NOT
# sanitizer/coverage instrumented: this is not a Rust coverage-guided campaign.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
sn_build_rust
mkdir -p build/fuzz/corpus
clang -std=c17 -g -O1 -UNDEBUG -fsanitize=fuzzer,address,undefined -I src/core \
  tests/fuzz_core.c "$SN_RUST_LIB" "${SN_NATIVE_LIBS[@]}" -o build/fuzz/fuzz-core
build/fuzz/fuzz-core build/fuzz/corpus -runs="${RUNS:-250000}" -max_len=512 -timeout=2
