# First Rust/macOS validation handoff

Rheo is the renamed C-to-Rust source port of Strafe Next. Read RENAME.md for the
identity changes, then README.md, PORTING.md and VALIDATION.md. **Neither the Rust source nor the macOS adapter was compiled
or run in the delivery environment.** Only C reference/harness checks ran. Do not
reuse the historical C pass counts or timings as evidence for Rust.

Use installed stable Rust >=1.85, rustfmt, Clippy, Python and Apple Command Line Tools.
First run `./scripts/check.sh`. It formats Rust, runs Clippy, tests debug/release,
checks C/Rust ABI layouts and executes both the original C suite against Rust and
the C/Rust differential harness. Fix actual compiler, lint and behavioral failures
with the narrowest patch. Preserve safe-core `forbid(unsafe_code)` and documented
FFI ownership contracts. Check Rust 1.85 separately before certifying the declared MSRV.

Run `./scripts/bench.sh` to compare the same C caller against the original C and Rust
archives. Preserve raw samples and compiler versions; do not assume Rust is faster.
The FFI payload copy and release compiler settings are explicit measurement targets.

Build with `./scripts/build.sh`. For universal builds first install Rust target libs
for aarch64-apple-darwin and x86_64-apple-darwin, then use ARCHS="arm64 x86_64".
Verify symbols/layouts/link libraries and signing before launch. The native tests
must not post events. Use `./script/build_and_run.sh --verify` for the app bundle;
this verifies resident IPC, not the gesture protocol.

Do not run alongside another Space interceptor. Do not disable SIP, modify the Dock,
bypass Accessibility or silently change system settings. Obtain the operator's
physical-input checks only after no-input tests pass. Follow VALIDATION.md's matrix,
prioritizing modern payloads/terminal handling, prefix replay, overlay transitions,
multiple displays and permission/tap recovery.

Report Rust compile/lint/test results, actual C/Rust parity and ABI results, native
compile/link/signature results, actual physical cases exercised, unexecuted cases
and raw performance/energy data separately. `posted` is not `completed`. Do not
expand feature scope or port AppKit to Rust before these gates are satisfied.
