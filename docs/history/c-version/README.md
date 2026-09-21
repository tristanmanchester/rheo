# Strafe Next

A performance-oriented reimplementation of Strafe's **instant** macOS Space switching: a C17 decision/encoding core, a dedicated event-tap thread, and a small Objective-C/AppKit menu app. No third-party runtime dependencies.

**Validation status, 21 September 2026:** the portable core has been compiled and tested on Linux with Clang and GCC, including sanitizers, failure injection, adversarial sequences and libFuzzer. The native macOS adapter is implemented, **but has not been compiled, launched or tested on macOS in this environment**. This is a source implementation awaiting native validation, not a verified release binary. No measured end-to-end speedup over Strafe is claimed.

## What changes

The event-tap callback no longer enumerates all windows or synchronously queries managed Spaces. A background monitor supplies bounded, timestamped snapshots. One dedicated run loop owns gesture state, pending Space predictions and complete synthetic batches. The C core has no heap allocation or locks; CoreGraphics and the native adapter still allocate, and snapshot reads use a nonblocking mutex attempt.

Gesture ownership is explicit: native, pending, committed or edge-blocked. Native cancellations pass through. Non-finite movement does not select a direction. Disabling interception drains a committed gesture or replays an uncommitted prefix, instead of leaving stale suppression state. A bounded replay buffer restores the suppressed beginning when preparation fails.

All three legacy events, or all six modern events including companions, are prepared before the first post. An allocation failure cannot post just the beginning. This is **preparation atomicity**, not an OS delivery guarantee.

Space prediction uses stable IDs, ordered pending targets, timestamp checks, topology invalidation and expiration. Unknown topology is not interpreted as the first Space. Tap recovery and the CLI report the resident process's observed state.

## Deliberate scope differences

This version is **instant-only**. It does not implement Strafe's Quick/Smooth animation presets, customizable shortcut recording, an automatic login item or an updater. The optional shortcuts are Control–Option–Left/Right. The CLI controls a running resident app; it does not create a second, independent event poster. Do not treat it as a feature-complete drop-in replacement.

The adapter targets the upstream-observed legacy format on OS major versions 15–26 and the IOHID format on 27. Those are implementation targets, **not a tested compatibility matrix**. Unknown later major versions disable interception/posting rather than assuming private format compatibility.

## Build and test

On Linux or macOS, with a C compiler and Python 3:

```sh
./scripts/test.sh
./scripts/bench.sh
```

`test.sh` uses Clang by default. `CC=gcc ./scripts/test.sh` exercises GCC where available. The original Swift control-flow reproducers additionally require `swiftc`; the script runs them when installed. On macOS the script also compiles CoreGraphics no-input tests. These tests deliberately do not post input.

On a Mac with Apple's Command Line Tools:

```sh
./scripts/test.sh
./scripts/build.sh
./script/build_and_run.sh --verify
```

The app is produced at `dist/StrafeNext.app`. The build script applies and verifies an ad-hoc signature by default. `SIGN_IDENTITY` selects another signing identity; notarization is not automated. A universal build is available with:

```sh
ARCHS="arm64 x86_64" ./scripts/build.sh
```

**Quit the original Strafe / InstantSpaceSwitcher and other competing Space-swipe interceptors before testing.** Grant Accessibility access to this app. For stable permission identity, build and then install at a stable location before granting access:

```sh
./scripts/install.sh
```

This installs to `~/Applications/StrafeNext.app` and refuses to overwrite an existing installation. Updating an ad-hoc signed binary can require removing/re-adding the Accessibility entry. No script changes SIP, modifies the Dock, removes quarantine attributes or downloads a binary.

For a development rebuild/relaunch, use `script/build_and_run.sh`; it asks the existing resident to quit, builds, and opens the app bundle. It does not install or silently start at login. `--verify` checks resident IPC availability, not correct gesture handling or granted permissions. The first native compile and runtime check are still outstanding.

## CLI

After launching the app:

```sh
APP="$HOME/Applications/StrafeNext.app/Contents/MacOS/StrafeNext"
"$APP" status
"$APP" switch right
"$APP" enabled off
"$APP" enabled on
"$APP" hotkeys off
"$APP" show
"$APP" quit
```

Use `dist/StrafeNext.app/Contents/MacOS/StrafeNext` instead for an uninstalled build. `enabled` controls physical swipe interception; hotkeys have a separate toggle.

A switch can return `posted`, `edge`, `busy`, `busy_real_gesture`, `timeout` or `unavailable`. **`posted` means the batch was submitted, not that the destination is visible or interactive.** Status includes snapshot freshness, Accessibility, observed tap state, overlay state, registration state, counts of posts/fallbacks/recoveries and the maximum observed callback duration. The CLI rejects extra/malformed arguments and talks only to the resident.

Exit codes: 0 for a successful command or an expected edge, 1 for a rejected switch/configuration request, 2 for invalid arguments, 3 for unavailable/invalid IPC response. Treat `status.state == "ready"` as a prerequisite for native tests, not an end-to-end correctness certificate.

## Review and evidence

- [Audit of the original and language/design decision](docs/AUDIT.md)
- [Architecture, invariants and remaining risks](docs/ARCHITECTURE.md)
- [Executed validation and native acceptance procedure](docs/VALIDATION.md)
- [Recorded environment and source hashes](results/environment.json)
- [Security and privacy](SECURITY.md)

The baseline is the supplied `strafe-main.zip`, upstream commit `37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7`. Upstream PRs #7 and #8 were also reviewed; the idea of checking Dock Accessibility overlay identifiers off the callback was already proposed in #8 and is credited, not presented as a new discovery.

## Layout

```text
src/core/       C17 gesture state machine, prediction, payload and batch preparation
src/macos/      AppKit shell, resident IPC, event-tap runtime and Apple API adapter
tests/          portable tests, original Swift reproducers and native no-input tests
bench/          portable microbenchmark; not a desktop-latency benchmark
scripts/        reproducible test, fuzz, build, benchmark and install entrypoints
results/        actual Linux logs, raw benchmark samples and provenance
```

The MIT license covers the new implementation. The original Strafe, InstantSpaceSwitcher and iss notices are preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Original upstream code exists only as a clearly identified test fixture and as the credited basis for private gesture encoding.
