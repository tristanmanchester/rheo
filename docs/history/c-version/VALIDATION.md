# Validation record and macOS acceptance gates

**Recorded on 21 September 2026.** The central distinction is between executed portable tests and unexecuted native integration. Passing the first category does not establish the second.

## Executed here

Host: Linux x86_64, Intel Xeon Platinum 8370C @ 2.80 GHz. Clang 17.0.0, GCC 14.2.0, Swift 6.2.1. Full versions, original archive hash and core source hashes are in `results/environment.json`.

| Check | Actual result | Evidence |
|---|---|---|
| Clang ASan + UBSan | 33 test groups pass | `results/clang-asan-ubsan.txt` |
| GCC ASan + UBSan | 33 test groups pass | `results/gcc-asan-ubsan.txt` |
| Deterministic adversarial stream | 1,000,000 events per core-test run, pass | Last group in both sanitizer logs |
| Original Swift handler reproducers | 4/4 specified control-flow defects reproduced | `results/upstream-regressions.txt`; also both sanitizer logs |
| Clang libFuzzer + ASan + UBSan | 250,000 runs, no reported crash/sanitizer finding | `results/libfuzzer.txt` |
| CMake Release / CTest | Build succeeds; core suite passes | `results/cmake-release.txt` |
| Clang static analyzer on four core C files | No diagnostics | `results/clang-static-analysis.txt` is intentionally empty |
| Release core benchmark | Three operations, 31 measured batches each | Summary and raw CSVs below |

The test runner uses warnings-as-errors. One GCC signedness warning in a test comparison was corrected, then the GCC suite was rerun successfully. This is not a claim that every native source file passes either compiler: the portable code alone was compiled here.

The original reproducer extracts the original handler and fire methods unchanged from `tests/upstream/SwipeInterceptor.swift`, supplies mocked CoreGraphics accessors and executes with `swiftc -O`. It proves native-cancel suppression, disable/end stale state, NaN direction firing and a returned end after a suppressed zero-motion begin. No actual macOS event is created or posted. The original fixture SHA-256 is printed by the script.

The 33 core groups exercise ownership, enable/disable, phase order, synthetic passthrough, NaN/infinity, direction inversion, end-velocity fallback, failed preparation, edges, repeated gestures, timeout/clock reversal, stable-ID prediction, intermediate acknowledgements, reordered/missing topology, old samples, plan forgery/duplicate commits, bounded pending capacity, fixed-point limits, payload layout and short buffers. Batch failure injection covers each of three legacy and six modern event-creation positions. The million-event stream and libFuzzer target check invariants; they are not exhaustive proofs of all macOS behavior.

## Measured portable timings

Compiler flags: `-std=c17 -O3 -DNDEBUG -fno-fast-math`, no link-time optimization. One warm-up batch followed by 31 measured batches of 200,000 operations per case. Each reported sample is total batch wall-clock time divided by operation count. An operation in the gesture row contains began, changed, feedback and ended core calls.

| Portable operation | Median batch mean | p95 of batch means |
|---|---:|---:|
| Unrelated event rejection | 2.611 ns | 2.751 ns |
| Began → changed → posted feedback → ended | 22.452 ns | 23.537 ns |
| Encode 96-byte IOHID payload | 23.676 ns | 27.407 ns |

Evidence: `results/linux-core-benchmark.csv` and all 93 measured batch samples in `results/linux-core-raw-samples.csv`. p95 is the nearest-rank 30th sorted batch mean of 31, **not** a p95 individual-callback latency. No CPU affinity, isolated core, fixed-frequency control or bare-metal exclusivity was established. Reruns will vary. These values include ordinary call/loop overhead, not only arithmetic.

The benchmark excludes the macOS adapter, replay allocations, snapshot copies/locks, topology queries, CoreGraphics event allocation/serialization/posting, UI scheduling, Dock/WindowServer processing and real input acceptance. It is not a language-comparison benchmark and does not demonstrate that the replacement beats Strafe end to end. An earlier run gave approximately 22.5 ns for the gesture case too; the included raw-sample run is the authoritative report.

To reproduce without overwriting the checked-in results:

```sh
./scripts/test.sh
CC=gcc ./scripts/test.sh
mkdir -p build/bench
./scripts/bench.sh build/bench/my-samples.csv > build/bench/my-summary.csv
./scripts/fuzz.sh
cmake -S . -B build/release -DCMAKE_BUILD_TYPE=Release
cmake --build build/release
ctest --test-dir build/release --output-on-failure
```

`RUNS=1000000 ./scripts/fuzz.sh` runs a larger campaign. The included 250,000-run log records its seed and coverage. Longer fuzzing is recommended before expanding the native boundary; the current campaign is short, not prolonged soak testing.

## Not executed here

No Apple SDK or macOS runtime was available. Therefore the following remain **NOT RUN**: Objective-C/native compile or link, ad-hoc signing verification, app launch, menu/CLI IPC, Accessibility grant/revocation, real CGEvent serialization roundtrip, actual desktop switching, physical trackpad/mouse behavior, Dock overlay detection, multi-display tests, actual tap recovery, native latency profiling and idle CPU/energy.

The macOS CI job and `tests/platform_tests.m` are supplied but were not executed. A passing macOS-15 CI build would still not test macOS-27 private payload behavior. The platform smoke test skips modern roundtrip unless running on OS major 27, and deliberately aborts if it accidentally posts an event. It checks geometry and created-event metadata, not private payload delivery or desktop interactivity.

## Gate 1 — native compilation and no-input tests

On a disposable development setup or with work saved, first quit the original Strafe and competing interceptors. Use Apple's Command Line Tools and run:

```sh
./scripts/test.sh
ARCHS="arm64 x86_64" ./scripts/build.sh
./script/build_and_run.sh --verify
```

Treat any compiler/linker/API issue as a blocker to fix, not as an expected pass. Inspect the app's ad-hoc signature with the build script's verification. The universal binary should compile and link for both architectures; only the available host architecture can actually execute. `--verify` checks IPC response, not permission or gestures.

Install at a stable location, grant Accessibility, then query `status`. Record OS build, architecture, displays, display arrangement, refresh rates, trackpad/mouse model, Mission Control settings and other input tools. Confirm the status transitions from `accessibility_required` through recovery to `ready`. Status must not claim completion from a successful post.

## Gate 2 — native behavior and regression matrix

Use at least one legacy-target OS and macOS 27. Do not generalize from a build-only runner. Run the following on real hardware, recording exact reproduction steps and any failed sequence:

| Scenario | Required observation |
|---|---|
| Ordinary left/right swipe | Exactly one neighboring Space selected; no double-switch or residual slide. |
| Leftmost/rightmost edge | No blank screen, rebound or unintended switch. |
| Very small/jitter/zero-progress movement | No stuck suppression; ordinary native behavior when no switch commits. |
| Physical cancellation before/after commit | No orphan native state; document that committed instant movement cannot be undone. |
| Mission Control and App Exposé | Native gestures remain functional, including cancel/end and rapid overlay entry. |
| Dock layer-20 window after closing overlay | Acceleration recovers; no persistent false overlay state. |
| Pause while pending and while committed | Prefix replay or owned-tail drain; later native gestures remain intact. |
| Re-enable after a gesture ended while paused | No stale companion suppression. |
| Prepare/copy failure and buffer saturation | No partial synthetic stream; native replay is accepted and ordered. |
| Rapid same-direction swipes and reversals | No overshoot from intermediate acknowledgements; explicit bounded refusals are acceptable. |
| Space reorder/add/delete and external Space switch | Old topology never silently becomes a wrong first-Space decision. |
| Multiple displays, negative coordinates, mirroring, shared/separate Spaces | Selected display matches the event's original point; no arbitrary first-display fallback. |
| Permission grant/revoke, disabled/invalid tap, Dock relaunch, sleep/wake/session changes | Observable status/recovery; no permanent suppression or busy-spin. |
| CLI/hotkeys during real swipe | Explicit busy or serialized result; no interleaved streams. |
| Hotkey conflict | No half-registration; diagnostic says unavailable. |
| Quit/rebuild/relaunch and kill during a gesture | Recovery characterized; no claim of perfect recovery after abrupt termination. |

A few items require a native fault-injection/debug build or controlled OS event manipulation; portable tests alone do not satisfy them. Keep diagnostic logs local. Do not expand collection to keystrokes or unrelated application contents merely to test this utility.

The macOS 27 terminal-event workaround is a special release blocker: verify both ended and cancelled with real IOHID-bearing physical events. The current scalar neutralization intentionally leaves the underlying record unchanged. Change it only based on captured, understood native behavior; blindly rewriting unknown byte offsets would create a new correctness hazard.

## Gate 3 — fair end-to-end performance comparison

Compare native macOS behavior with Strafe at the pinned baseline commit, Strafe at any newer candidate you intend to replace, and Strafe Next. Record commit hashes and settings separately. Never run two interceptors simultaneously. Compare Strafe's Instant preset with this instant-only build; an intentionally animated preset is not a fair speed target.

Use randomized/interleaved blocks under the same power mode, display refresh, Spaces, app windows and input device. Separate the physical-trackpad route, hotkey route and CLI route because they have different initiation costs. Include warm-up, both directions, edges, rapid reversals and bursts. A sensible initial target is at least 100 trials per ordinary mode/direction, plus dedicated edge/recovery sequences; it is a measurement plan, not a claim those trials were run.

Record these separately:

1. First relevant physical input to first posted synthetic event, including tap scheduling and state checks.
2. Allocation/preparation and whole-batch post duration, plus callback-duration distribution.
3. Input to first visible destination frame and to destination acceptance of **real physical input**.
4. Failure, native-fallback, busy, timeout, double-switch and wrong-display counts, including trials without a successful destination observation.
5. Idle CPU, wakeups and energy over comparable idle intervals with original, replacement and no utility.

The resident currently exposes a cumulative maximum callback duration and aggregate counters, **not** a full latency histogram or destination probe. Add opt-in, bounded instrumentation for those distributions and use an external visual/physical-input measurement method for destination interaction. Timestamp generation, clock domain, synchronization and frame-rate quantization must be documented. Synthetic probe-click delivery is not automatically equivalent to physical HID unlocking.

Save raw trial rows including mode, direction, OS/build, trial ID, result, each available time and timeout threshold. Do not silently drop failed trials before reporting median/p95/p99. Report success rate alongside successful-trial latency, use a declared timeout for missing observations, and include dispersion/confidence intervals. An approximately 4 ms sampling scheme cannot support claims about sub-millisecond gains. Linux nanoseconds cannot be subtracted from upstream macOS milliseconds.

Adopt the rewrite only after native correctness gates pass and either latency tails or responsiveness demonstrably improve without an unacceptable regression in input reliability or idle energy. If the polling cost outweighs its benefit, replace it with a measured notification/observer strategy plus a conservative watchdog; do not assume more frequent polling is always better.
