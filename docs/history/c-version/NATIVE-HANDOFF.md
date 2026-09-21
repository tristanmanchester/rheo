# Handoff for a Mac-based coding agent

Work in this repository. Read `README.md`, `docs/AUDIT.md`, `docs/ARCHITECTURE.md` and `docs/VALIDATION.md` first. The portable C core has passed the supplied Linux validation; **the Objective-C/macOS implementation has not been compiled or run**. Do not treat the source as production-validated or report a speedup without native measurements.

First run `./scripts/test.sh` and `./scripts/build.sh` on the Mac. Fix compiler/linker/runtime issues with minimal changes, preserving the single-owner event stream, bounded prefix replay, all-events-before-posting preparation and conservative unknown-state behavior. Use `script/build_and_run.sh` for rebuilding/launching the app bundle. Do not bypass Accessibility, disable SIP, silently modify system configuration or run beside another Space interceptor.

Run the no-input native smoke tests before permissioned physical-input testing. Ask the operator to perform the physical gestures in the native matrix; do not equate synthetic input with physical HID acceptance. Prioritize macOS 27 private payload roundtrip, terminal neutralization, overlay detection, multi-display selection, permission recovery and replay ordering. Add regression tests for each actual native bug found, and keep portable tests passing under Clang/GCC sanitizers.

Measure original Instant versus replacement under the same hardware/settings with raw results, failures and idle CPU/wakeups. The existing nanosecond core benchmark is not an end-to-end baseline. Investigate whether 100 ms AX/CGS polling costs more energy than it saves in callback latency. Do not grow feature scope or add animation presets before correctness/performance gates pass.

Report separately: files changed; portable tests executed; native compile/link results; actual hardware cases executed; unexecuted cases; raw latency/energy evidence; and a clear daily-use/no-daily-use recommendation. Never turn `posted` into `completed` without an independent observation.
