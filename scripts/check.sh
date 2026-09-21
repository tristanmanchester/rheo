#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh
sn_require_rust
cargo fmt --all
cargo clippy --workspace --all-targets --locked --offline -- -D warnings
./scripts/test.sh
