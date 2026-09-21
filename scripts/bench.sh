#!/bin/bash
# Identical non-LTO C caller for both implementations; measures the real C ABI.
# Comparisons are microbenchmarks, not Dock/UI/input-to-display measurements.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
sn_build_rust
mkdir -p build/bench
cc=${CC:-clang}
{
  uname -a
  rustc -vV
  cargo --version
  "$cc" --version
  printf '%s\n' 'C: -std=c17 -O3 -DNDEBUG -fno-fast-math; no cross-language LTO'
  printf '%s\n' 'Rust: workspace release profile; C caller invokes the C ABI'
} > build/bench/environment.txt
flags=(-std=c17 -O3 -DNDEBUG -fno-fast-math -Wall -Wextra -Werror -I src/core)
"$cc" "${flags[@]}" tests/reference/c/*.c bench/core_bench.c -lm -o build/bench/c-reference
"$cc" "${flags[@]}" bench/core_bench.c "$SN_RUST_LIB" "${SN_NATIVE_LIBS[@]}" -o build/bench/rust-ffi
for round in 1 2 3 4; do
  if (( round % 2 == 1 )); then order=(c-reference rust-ffi); else order=(rust-ffi c-reference); fi
  for impl in "${order[@]}"; do
    echo "=== $impl round $round ==="
    "build/bench/$impl" "build/bench/$impl-$round-raw.csv" | tee "build/bench/$impl-$round-summary.csv"
  done
done
python3 scripts/summarize_bench.py build/bench
