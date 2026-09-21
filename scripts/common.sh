#!/bin/bash
# Sourced by entrypoints after changing to the repository root. Bash 3.2 compatible.
set -euo pipefail
sn_require_rust() {
  command -v cargo >/dev/null || { echo 'Rust/Cargo 1.85+ is required; install a stable Rust toolchain first.' >&2; return 1; }
  command -v rustc >/dev/null || { echo 'rustc is not on PATH.' >&2; return 1; }
}
sn_native_libraries() {
  # Both workspace crates use only Rust core/std and have no third-party native
  # dependencies. Ask this exact compiler/target for std's native linker flags.
  # A direct rustc probe avoids relying on Cargo replaying a cached diagnostic.
  local triple=${1:-} dir="build/link-probe/${1:-host}"
  mkdir -p "$dir"
  printf '%s\n' 'pub fn rheo_link_probe() {}' > "$dir/probe.rs"
  local args=(--edition 2024 --crate-type staticlib --crate-name rheo_link_probe -C panic=abort)
  [[ -z "$triple" ]] || args+=(--target "$triple")
  if ! rustc "${args[@]}" --print native-static-libs "$dir/probe.rs" -o "$dir/probe.a" 2> "$dir/native-libs.log"; then
    cat "$dir/native-libs.log" >&2; return 1
  fi
  local flags
  flags=$(sed -n 's/^note: native-static-libs: //p' "$dir/native-libs.log" | tail -n 1)
  [[ -n "$flags" ]] || { echo 'Could not obtain Rust native linker libraries; see build/link-probe.' >&2; return 1; }
  read -r -a SN_NATIVE_LIBS <<< "$flags"
}
sn_build_rust() {
  sn_require_rust
  local triple=${1:-}
  # An absolute target directory avoids confusing paths when called by CMake.
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"
  local args=(build --locked --offline --release -p rheo-ffi --lib)
  [[ -z "$triple" ]] || args+=(--target "$triple")
  cargo "${args[@]}"
  if [[ -n "$triple" ]]; then SN_RUST_LIB="$CARGO_TARGET_DIR/$triple/release/librheo_ffi.a"
  else SN_RUST_LIB="$CARGO_TARGET_DIR/release/librheo_ffi.a"; fi
  [[ -f "$SN_RUST_LIB" ]] || { echo "Missing Rust archive: $SN_RUST_LIB" >&2; return 1; }
  sn_native_libraries "$triple"
}
sn_reference_objects() {
  local cc=${CC:-clang} dir=${1:-build/reference}
  mkdir -p "$dir"
  local symbols=(sn_gesture_reset sn_gesture_step sn_gesture_feedback sn_topology_valid
    sn_prediction_reset sn_prediction_prepare sn_prediction_commit sn_fixed1616
    sn_payload_encode sn_batch_prepare sn_batch_post sn_batch_release)
  local defs=() name file obj
  for name in "${symbols[@]}"; do defs+=("-D$name=ref_$name"); done
  SN_REFERENCE_OBJECTS=()
  for file in tests/reference/c/*.c; do
    obj="$dir/$(basename "${file%.c}").o"
    "$cc" -std=c17 -O1 -g -fno-fast-math -Wall -Wextra -Wpedantic -Werror \
      ${SN_SAN_FLAGS[@]+"${SN_SAN_FLAGS[@]}"} "${defs[@]}" -c "$file" -o "$obj"
    SN_REFERENCE_OBJECTS+=("$obj")
  done
}
