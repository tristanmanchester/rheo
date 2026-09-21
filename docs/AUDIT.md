> Historical audit of original Strafe and the preceding C v0.1 implementation.
> For the Rust source port and its unexecuted validation, read PORTING.md and VALIDATION.md.

# Strafe: audit and replacement design

**Date:** 21 September 2026  
**Baseline:** supplied `strafe-main.zip`, commit `37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7`  
**Replacement:** Strafe Next 0.1.0, C17 core + Objective-C/AppKit adapter

## Verdict

Strafe's central technique is already in native C: synthesize a high-velocity, near-zero-travel Dock swipe. The important improvement opportunities are **gesture ownership, failure handling, expensive work on the callback, queue behavior and stale state**, not a blanket assertion that Swift is slow.

I implemented a replacement, not just a proposed refactor. Its portable core is compiled and tested, including four reproductions against the original Swift handler. The Apple API adapter, menu app, local CLI, build scripts and native tests are written. **They have not been compiled or exercised on macOS in this Linux environment.** Consequently, “more defensible architecture and verified portable fixes” is supported; “faster, production-ready macOS replacement” is not yet supported.

The version deliberately implements instant switching only. Removing animated presets eliminates their queues and transition-shape races, but is a feature tradeoff, not a free feature-parity improvement.

## Evidence standards

**Reproduced:** original unmodified Swift `handle`/`fire` methods execute with mocked CoreGraphics accessors. This demonstrates control flow, not the prevalence of a physical-device symptom.

**Static:** a source path can be followed directly; no affected Mac or WindowServer behavior was observed here.

**Upstream-reported:** an existing issue/PR describes native behavior. It is credited to that author and not represented as independently reproduced.

**Unmeasured hypothesis:** likely performance or native-compatibility impact that requires measurements. Severity describes potential impact, not demonstrated frequency.

All original line numbers below refer to the pinned commit. Links are collected at the end.

## 1. Gesture ownership is not consistently preserved

### Native cancellation is swallowed — high correctness importance, reproduced

`Sources/strafe/SwipeInterceptor.swift:177–183` passes a began event through when Exposé is active, leaving `swipeTracking` false. But `:229–233` drops a cancelled event unconditionally. Thus a gesture that macOS owns can lose its terminal cancellation event.

The reproducer sends an overlay-owned began and then cancelled. The original returns the first event and suppresses the second. Strafe Next explicitly tracks native versus owned gestures; native cancellation passes unchanged.

### Disabling mid-gesture leaves stale suppression — high correctness importance, reproduced

At `SwipeInterceptor.swift:140–141`, disabling immediately returns every event before updating gesture state. If an end arrives while disabled, it does not clear tracking. After re-enabling, the next companion event can be dropped as though the old gesture were still active (`:160–162`).

The reproducer executes precisely that sequence. The replacement keeps processing ownership after a toggle: pending prefixes are replayed to native handling; committed gestures are drained through their terminal event. The native runtime keeps its tap available while a gesture is owned and has a lost-terminal watchdog.

This verifies the portable state policy. Timing of real toggle, tap removal, Dock acknowledgement and recovery still requires hardware testing.

### An orphan terminal event is returned — medium correctness importance, reproduced

At `SwipeInterceptor.swift:205–214`, a zero-motion end is returned on the premise that macOS owns the gesture. But the matching began was suppressed at `:183`. The returned end is not a complete native sequence.

The replacement buffers the uncommitted prefix, bounded at 32 events. On no direction, disabled-pending state, unsafe environment or event-preparation failure, it requests replay of the prefix and passes the current event. The native adapter uses `CGEventTapPostEvent` so the prefix is placed after this tap and before the returned current event. Apple's documented ordering supports that mechanism; native acceptance of replayed private gestures remains untested.

### Non-finite movement triggers a switch — defensive correctness defect, reproduced

`SwipeInterceptor.swift:188–192` and `:201–204` test only `value != 0.0`. NaN passes that test, then produces an arbitrary sign decision through ordinary comparisons. Infinity is likewise accepted.

A mock NaN changed event triggers the original engine. The replacement requires a finite, nonzero value. This is not evidence that trackpads commonly emit NaNs, nor a claim that this is the largest real-world defect. It is a concrete validation hole and an inexpensive fix.

## 2. Posting can leave an unfinished synthetic gesture

**High correctness importance; statically established allocation-failure path.**

`Sources/CStrafe/CStrafe.c:127–132` calls the began, changed and ended posters with short-circuit `&&`. Each phase allocates its own CoreGraphics objects in `:76–108`. If a later allocation or modern payload reconstruction fails after began has already posted, later phases are never posted. The function returns failure, but cannot retract the earlier begin.

The animated path in `Sources/strafe/SwitchEngine.swift:136–154` is weaker: it discards every phase-poster result and reports success when a closure is merely queued. Its prediction can advance before any phase is successfully created.

Strafe Next prepares all events into a batch first: three for the legacy encoding, six including companions for the modern encoding. A single failure releases everything without posting. Tests inject failure at each of the nine phase/companion creation positions across the two formats and require zero posts and zero retained mock events.

This is **all-or-nothing preparation**, not all-or-nothing delivery. `CGEventPost` does not return Dock acceptance or completion. A crash or failure after posting starts is still outside this guarantee. Prediction is updated only after successful preparation, immediately before the single-owner batch submission.

## 3. The callback does expensive system work

**Statically confirmed work; latency and energy improvement unmeasured.**

`SwipeInterceptor.swift:179` synchronously calls the overlay detector from the event-tap callback. The C implementation enumerates window metadata and identifies Dock windows by layers. A successful gesture then calls `spaceInfo()` in `SwitchEngine.swift:160`, which creates a location event, resolves display identifiers and queries managed display Spaces. The Swift layer also materializes a display-ID string and operates on a locked dictionary.

The tap runs on the main run loop, sharing scheduling with menu/UI work. These system queries and scheduling dependencies are more credible latency targets than comparing the cost of a Swift conditional with a C conditional.

The replacement puts the event tap on a dedicated run loop, with one owner for gesture state, prediction and posting. A background queue polls overlay/topology every 100 ms. The callback attempts a snapshot copy without waiting for a mutex; stale, unavailable or contended snapshots decline interception/acceleration. The input event's position chooses a cached display, avoiding a cursor query for the physical-swipe path.

Important limitations: this adds idle work and can read an out-of-date overlay state. The cache has a 350 ms freshness limit, not instantaneous truth. AX timeouts limit individual queries, not total real-time scheduling latency. No idle CPU, energy or callback-tail improvement has been measured on a Mac. The callback still allocates CoreGraphics events and bounded replay copies; only the pure core is heap-free and lock-free.

## 4. Overlay detection already has an upstream correction in progress

**Upstream-reported native bug, not a new discovery.**

The pinned C code's macOS 27 rule treats a Dock layer-20 window as sufficient evidence of an overlay (`CStrafe.c:368–371`). Upstream PR #8, opened 18 September 2026, reports that such a fullscreen window can persist after Mission Control closes. Its proposed correction inspects Dock Accessibility child identifiers `mc` and `appexpose` off the tap thread.

Strafe Next adopts that prior approach, with attribution. Its independently implemented monitor treats failed, empty or truncated observations as unknown rather than reusing the window-layer heuristic. Unknown information preserves native behavior instead of turning an uncertain observation into authorization to suppress input.

This can mean Strafe Next declines acceleration more often than upstream. Identifier availability on older systems, overlay entry between polls, App Exposé, Stage Manager and Dock relaunch all remain hardware test requirements. No polling-only method can guarantee that an overlay never appears between observation and action.

## 5. Bounds and prediction can silently become wrong

### Missing current Space is treated as index zero — high importance, static

`CStrafe.c:229–246` initializes `currentIndex` to zero, searches for the active Space, then reports success even if no entry matched. Unknown current state is therefore indistinguishable from the first Space. At `:188–207`, failure to find the selected display falls back to the first display's dictionary. Private dictionary value types and string conversion results are not thoroughly validated.

The replacement checks dictionary/value types, counts, nonzero/unique IDs and current-Space membership. It does not select an arbitrary other display. It supports the private single-`Main` shared-topology case explicitly; otherwise a display mismatch is unknown. Unknown topology never authorizes an unconditional synthetic post.

### Index-based predictions and blanket resets lose information — medium/high importance, static design weakness

`SwitchEngine.swift:166–187` tracks a numeric index per display. `:195–201` clears all predictions on an active-Space notification. If multiple switches are outstanding, acknowledgement of an earlier move can erase a later predicted target. Reordering Spaces also changes what an index means. A post that the Dock ignores can leave prediction wrong until another notification resets it.

Strafe Next stores stable Space IDs and an ordered, fixed-capacity list of pending targets. A matching intermediate observation removes the acknowledged prefix and keeps later targets. Topology changes invalidate old plans. A 700 ms unacknowledged-post timeout resets the model and rejects one acceleration attempt rather than piling another blind post onto an uncertain state. A query timestamped before a post cannot erase that pending work merely because its response arrived later.

Prediction remains inference, not delivery acknowledgement. Reversals that revisit the same ID and external moves to an expected target are ambiguous. Capacity and expiry bound those ambiguities; they do not eliminate them. The timeout values are initial engineering choices awaiting macOS tuning.

## 6. Scheduling and concurrency contracts are too loose

**Static; the concurrency race is conditional, not reproduced in ordinary current use.**

The ramp queue at `SwitchEngine.swift:136–154` is serial but not bounded. Inputs can build a backlog of transitions that occur after the initiating physical gestures. Returning to the instant preset routes a later call around the ramp queue (`:125–127`), potentially interleaving it with an existing ramp's began/changed/ended stream.

The prediction lock is also released between reading an origin and submitting/updating a target (`:166–187`). Two genuinely concurrent callers could read the same origin or interleave their posting streams. However, the current physical tap and normal hotkey handlers are main-thread driven; it would be misleading to claim this concurrency race was observed in normal usage. The problem is that the engine's advertised sharing contract is stronger than its transaction synchronization.

The new instant-only runtime submits whole batches on one thread. CLI and hotkeys use that same owner, not separate engines or processes. Only one external switch command can be pending; it has a bounded admission deadline. Commands do not interrupt a known physical gesture. Those limits prefer an explicit busy result over an unbounded backlog.

Removing animation is the simplest solution for the requested performance objective. A future animation feature would need a single shared scheduler, capacity/backpressure, cancellation semantics, per-phase failure recovery and tests for preset changes. Adding a sleep loop back would reintroduce the problem.

## 7. Lifecycle/status need to describe the resident

**Static plus upstream PR #7, opened 18 September 2026.**

The pinned CLI `Sources/strafe/main.swift:57–60` passes `tapRunning: false` from the command process; it is not asking the resident tap for its state. Its switch command sleeps 120 ms (`:50`), which is not proof of destination interactivity. Tap creation/retry and permission recovery are already addressed by an upstream proposal in PR #7.

Strafe Next has a single resident IPC endpoint. Settings commands update that process immediately. Status separates permission, tap, snapshot, overlay and hotkey-registration state and never claims completion from a successful post. A one-second health tick checks permission/tap availability and attempts recovery. Its status is still an observed state, potentially stale until the next health check; it is not a transactionally fresh WindowServer certificate.

## 8. Payload allocation can be simplified, but should not be oversold

**Static copy/allocation reduction; native timings unmeasured.**

`Sources/CStrafe/IOHIDPayload.c` allocates a 68/96-byte payload, allocates a concatenated buffer and copies into a new CFData before reconstructing the event. The new byte encoder writes into caller-owned storage. Its adapter uses a stack record and a CFMutableData assembly buffer, removing the two explicit temporary `malloc` buffers from each augmentation. CoreFoundation/CoreGraphics allocations remain.

The encoded fixed-point values saturate, preserve a nonzero sign for very small finite movement and reject malformed/non-finite payload inputs. Explicit little-endian writes avoid alignment-dependent packed-struct access. Unit tests check layout, sentinels, short buffers, extremes, both direction encodings and event order.

The serialized event magic/header and private payload field are undocumented. Successful byte-layout tests do not prove macOS 27 accepts the reconstructed event. The inherited scalar-only real-terminal neutralization does not rewrite an already embedded raw IOHID payload; its Dock behavior must be verified on hardware, including cancelled gestures.

## 9. The existing benchmark is useful but not a full application benchmark

`bench/Sources/bench/StrafeSwitch.swift` calls the C poster directly. Its own comment explicitly excludes the engine's bounds/prediction bookkeeping. It also does not exercise the physical swipe interceptor. Therefore it cannot measure the callback system-query work removed in this rewrite.

The original benchmark documents its approximately 4 ms sampling cadence and the possibility that synthetic clicks bypass the physical HID hold. It would be unfair to characterize it as unaware of those limits. Its README's numbers are upstream measurements, not a baseline rerun here.

This package's Linux microbenchmark is even narrower: it measures portable core operations, with no CoreGraphics, event tap, Dock or physical input. It demonstrates that the decision core is small, not that the desktop switches in nanoseconds. It is not a C-versus-Swift experiment. The native benchmark protocol in `VALIDATION.md` specifies the missing end-to-end comparison and requires reporting failures, tails and idle cost, not just median successful transitions.

## Language decision

I chose **C17 for the bounded core and Objective-C for native macOS integration**. This puts gesture ownership, prediction, payload encoding and preparation into small explicit data structures, uses the C-shaped Apple APIs directly, and permits portable sanitizers/fuzzing without an Apple SDK. AppKit remains native; no webview, JavaScript runtime or garbage-collected event loop is introduced.

Swift already compiles through LLVM into native machine code. The original synthesizer is already C. Rewriting Swift to C alone is not evidence of a faster application, and most of the architectural improvements could also be implemented while retaining Swift. C trades compile-time memory safety for direct control, so the checked capacities, tests, sanitizer coverage and narrow native boundary matter.

Rust would also be a reasonable implementation language, particularly for memory safety; the Apple/private-API boundary would still require careful FFI handling. C++/Objective-C++ could offer RAII. No benchmark here establishes a universal winner among optimized native languages. The choice is about a small dependency-free C API workload and predictable ownership, not language marketing.

## Recommended adoption decision

Use the portable fixes and this source implementation as a concrete basis for development. Do **not** label it a production replacement until native compilation, actual event preparation, permission recovery, multi-display behavior, replay and physical input tests pass. A migration decision should then depend on measured callback tails, complete switching latency, success rate and idle CPU/energy against the same upstream commit and settings.

The strongest proven improvement today is the tested handling of the four original control-flow defects and all-or-nothing batch preparation. The largest expected performance benefit is removing synchronous system queries and UI-thread dependence from gesture decisions. The largest remaining risk is private macOS gesture behavior, especially the modern payload and terminal-event workaround.

## Sources

Original source paths/line numbers above are from the supplied archive. Pinned source links:

- [SwipeInterceptor.swift](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/strafe/SwipeInterceptor.swift)
- [SwitchEngine.swift](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/strafe/SwitchEngine.swift)
- [CStrafe.c](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/CStrafe/CStrafe.c)
- [IOHIDPayload.c](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/CStrafe/IOHIDPayload.c)
- [CLI main.swift](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/strafe/main.swift)
- [Original benchmark boundary](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/bench/Sources/bench/StrafeSwitch.swift)
- [Original benchmark methodology](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/bench/README.md)
- [Upstream PR #7: recovery/status](https://github.com/rileycx/strafe/pull/7), reviewed 21 September 2026
- [Upstream PR #8: overlay detection](https://github.com/rileycx/strafe/pull/8), reviewed 21 September 2026
- [Apple: tap creation and callback run-loop ownership](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple: posting from a tap, insertion ordering](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent(_:))
- [Apple: AX messaging timeouts](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
- [Swift compiler architecture](https://www.swift.org/documentation/swift-compiler/)

External documentation was checked on 21 September 2026. The original fixture, logs and source hashes are included so the reproduced findings do not depend on the default branch staying unchanged.
