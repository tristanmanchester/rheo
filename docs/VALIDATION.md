> These are the original Rust-port validation results, not new Rust execution

> Subsequent macOS validation: see [the local run](../results/local-macos-validation.txt) from 21 September 2026 for Rust tests, ABI/differential checks, native build, and Clippy results. The original delivery record follows.

> results from the Rheo rename. See [RENAME.md](RENAME.md) and
> `results/rename-checks.txt` for the checks run after renaming.

# Validation of the Rust source port — 21 September 2026

## Bottom line

**Rust compilation, Rust execution, Rust/C differential equivalence and macOS
integration are NOT verified in this delivery.** The environment is Linux x86-64
and has no Rust compiler or Cargo. Toolchain-download attempts failed. Native
macOS SDK/runtime is also absent. There are no Rust performance measurements.

The source includes complete Rust modules, FFI, tests and build/link scripts. This
is not a verified binary or a claim that the new tests passed.

## Actually executed for this delivery

| Check | Actual result | Scope |
| --- | --- | --- |
| Frozen C v0.1 suite, Clang ASan + UBSan | All 33 groups passed, including 1,000,000 adversarial events | C reference only |
| New differential harness self-check | Passed 1,000,000 gesture inputs, 200,000 prediction steps, 100,000 payload cases and 22 batch cases | Unprefixed C versus prefixed C; NOT Rust |
| C ABI test driver compilation | Syntax checks passed | C half only; no Rust layouts checked |
| C public header | C17 and C++17 syntax checks passed | Header syntax only |
| C test/benchmark/fuzzer drivers | Clang warning-as-error syntax checks passed | C compilation only |
| Shell entrypoints | `bash -n` passed | Shell syntax, not full execution |
| Python helpers | `py_compile` passed | Python syntax |
| Original Swift reproducers | Four specified original defects reproduced | Unchanged upstream fixtures/stubs |
| `./scripts/test.sh` | Stopped with Rust/Cargo-required message | No Rust test ran |
| `./scripts/build.sh` | Stopped with macOS-required message | No native build ran |

Current logs are under `results/`. `differential-harness-self-test.txt` is prominently
marked C-versus-C. Earlier C results are preserved under `results/history/c-version`
and are not reclassified as results for this port.

## Supplied but unexecuted Rust checks

`cargo test --workspace --locked --offline` runs 29 Rust tests, including a
one-million-event adversarial stream. `scripts/test.sh` runs debug/release Rust
suites, builds the static library, links the unchanged 33-group C test suite to
Rust, checks the full struct ABI, and links the differential driver to both Rust
and independently compiled/prefixed C reference objects. On a Mac, it also builds
and runs the no-input CoreGraphics preparation tests.

`./scripts/check.sh` formats the Rust files in place, then runs Clippy and the
complete test pipeline. Neither rustfmt nor Clippy was available here. Formatting
and lint errors may therefore still be found by the first real toolchain run.
CI jobs for stable Rust, declared MSRV 1.85.0, macOS universal builds and an optional
manual Miri run are supplied but have NOT run from this delivery.

The benchmark entrypoint runs the same C caller against both implementations,
alternating order across four rounds. Results are generated only after execution;
there are no placeholder timing numbers or invented speedup ratios.

## Sanitizer limits

The standard test script instruments the C harness, C reference and optional
Objective-C test adapter. It does NOT add sanitizer instrumentation inside the
stable Rust archive. Likewise, the libFuzzer script instruments the C input harness,
not Rust's internal branches. Its successful execution would not be a fully
coverage-guided or fully ASan-instrumented Rust validation campaign.

Miri is a supplied, unexecuted additional check of Rust code and Rust-defined FFI
callbacks. It cannot verify Apple's CoreGraphics/Dock implementation or real input.

## First required runs

On a machine with stable Rust/Cargo, rustfmt, Clippy, a C compiler and Python:

```sh
./scripts/check.sh
./scripts/bench.sh
```

On macOS with Apple's Command Line Tools:

```sh
./scripts/test.sh
./scripts/build.sh
```

Only after no-input tests and native compilation pass, quit competing interceptors,
launch the bundle through `script/build_and_run.sh`, grant Accessibility, and test
physical gestures. Follow `docs/NATIVE-HANDOFF.md`.

## Native acceptance matrix (unchanged obligations)

Exercise supported legacy encoding and macOS 27 augmented encoding on actual target
systems, both directions, first/last Space, rapid repetition/reversal and zero-motion
cancellation. Verify Mission Control/App Exposé native pass-through, cancellation,
mid-gesture disable/re-enable, tap timeout/recovery, Accessibility loss/restoration,
sleep/wake, display changes, multiple displays, fullscreen Spaces, shared Spaces
and Dock restart.

Prioritize modern IOHID reconstruction, real terminal neutralization and suppressed
prefix replay. These are private-protocol integration questions; portable tests
cannot answer them. Test corrupted/unavailable/stale monitor snapshots without
blindly posting beyond bounds. Verify CLI/status honesty and no concurrent event
posters. Replacing an ad-hoc signed app can require regranting Accessibility.

Measure real input-to-visible/interactive latency, failures, callback tails and
idle CPU/wakeups for the original C and Rust builds on the same hardware/settings.
The inherited 100 ms monitor polling may have an energy cost regardless of language.
Do not report microbenchmark nanoseconds as desktop switching latency.
