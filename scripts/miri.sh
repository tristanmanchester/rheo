#!/bin/bash
# Optional: requires an installed nightly toolchain with miri + rust-src components.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo +nightly miri test -p rheo-core --locked --offline -- --skip million_event_adversarial_stream
cargo +nightly miri test -p rheo-ffi --locked --offline
