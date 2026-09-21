# Architecture and invariants

## Ownership and scheduling

The AppKit main thread owns the status menu, defaults, hotkey registration and CFMessagePort server. It never mutates gesture/prediction state directly. A dedicated event-tap run loop owns the gesture machine, replay buffer, display prediction ledgers and every synthetic event batch. A serial monitor queue queries Dock Accessibility and CGS topology and publishes a fixed-size snapshot.

A physical swipe follows this path:

```text
session event tap
  -> reject unrelated / synthetic events
  -> identify gesture ownership (portable C)
  -> at begin, try-copy a fresh environment snapshot and capture display/point
  -> at direction, re-check snapshot generation and predict a neighboring ID
  -> prepare all 3 or 6 synthetic events
  -> commit prediction and post complete batch on this same run loop
  -> drain remaining real gesture events
```

No background query is awaited in the physical callback. A contended snapshot mutex returns unavailable. No window enumeration, CGS query, AX tree walk, logging, disk operation or sleeping animation occurs in that callback. CoreGraphics preparation and replay-copy allocation do occur there, and the Objective-C adapter has method calls and timing instrumentation. This is not a claim of a fully allocation-free or hard-real-time callback.

The separate monitor uses a 100 ms timer with 15 ms leeway; a one-second tap-thread health timer checks Accessibility/tap availability. Those timers impose idle work. Some OS calls in monitor/health code may still block. AppKit hotkey and CLI requests wait for a bounded result from the owner thread; this is not an entirely asynchronous UI architecture.

## Gesture policy

The owner state is one of:

| State | Meaning | Relevant behavior |
|---|---|---|
| `SN_IDLE` | No known current gesture | Pass unrelated/terminal input. |
| `SN_NATIVE` | macOS owns the sequence | Never swallow its cancellation or end. |
| `SN_PENDING` | Prefix suppressed; no switch posted | Buffer bounded prefix; attempt once direction is finite/nonzero. |
| `SN_COMMITTED` | Synthetic batch submitted | Do not switch again; drain the physical tail. |
| `SN_BLOCKED` | Known boundary prevented switching | Suppress the rest, including moving terminal events. |

Synthetic events and unrelated event kinds do not affect ownership. The session tap does not subscribe to ordinary keyboard events. All synthetic events also carry a source marker. First-nonzero triggering is preserved for responsiveness; an eventual physical cancellation cannot undo a switch already posted. The core has a minimum-progress option, but the app currently uses zero and does not expose a sensitivity control.

A pending zero-motion end or failed preparation requests prefix replay before passing the current event. A pending cancellation discards the hidden prefix, because nothing was yet handed to the Dock. A native cancellation always passes. Disabling while pending replays; disabling after commit drains. A timeout or clock discontinuity drops stale held copies rather than replaying a long-obsolete partial gesture.

The adapter holds no more than 32 copied events. If the next copy cannot be stored, it replays the existing prefix, passes the current event and transfers ownership to native handling. This bounds retained event count, not the undocumented byte size of each CGEvent. Multi-device interleaving and actual replay acceptance need native traces.

For modern committed terminal events, the adapter clears scalar progress/velocity and returns the real terminal as an upstream-inspired Dock workaround. It also does this for a committed cancellation. **The embedded real IOHID record is not rewritten.** This is a specific remaining compatibility risk, not a proven fix for all macOS 27 endings.

## Environment snapshots

A snapshot includes a timestamp, invalidation generation, trust/CGS status, overlay state and up to 16 display geometries/topologies. Each topology holds at most 64 unique, nonzero Space IDs and a validated active ID/index. Unknown current IDs, unavailable private symbols, display mismatch, empty/oversized lists and failed CF type checks do not create a valid topology.

Time is recorded at query start, conservatively including query duration in snapshot age. Snapshots older than 350 ms are rejected. Workspace/display notifications invalidate the shared snapshot generation. A swipe captures generation and physical display at begin, then must see the same environment generation before posting. It also pins its original event location rather than moving with the cursor mid-gesture.

The single private `Main` display entry is recognized explicitly as shared topology. It is not equivalent to a fallback onto the first arbitrary display dictionary. Mirroring and display arrangements still need hardware validation.

The AX monitor inspects root Dock child identifiers, with a 20 ms root timeout and 5 ms per child, capped at 32 children. Empty/truncated/failed observations become unknown; absent overlay names after a complete successful scan are interpreted as clear. These identifiers are not a stable public overlay API. Overlay changes between snapshots remain possible. This design favors availability of native input over guaranteed acceleration, but cannot guarantee a cached clear result remains true at dispatch.

## Prediction and preparation

A prediction ledger stores ordered stable IDs, the last observed ID, a sample time, a generation and up to eight pending target IDs with submission times. It is single-thread-owned. Plans are generation-checked and adjacent-target-checked before commitment.

A newer observed intermediate target acknowledges the corresponding pending prefix, preserving later targets. A genuinely external move adopts live state. A sample whose query began before a post cannot use that later move as a trustworthy acknowledgement. Reordering/changing topology invalidates pending work. An unacknowledged post older than 700 ms resynchronizes and rejects one new acceleration attempt. At capacity, the next attempt declines rather than queuing without bound.

A Space notification alone does not clear all ledgers. However, target IDs are not unique request acknowledgements: returning to the same Space or an external move onto an expected target is inherently ambiguous. The bounded model limits the consequences; it is not an exactly-once protocol.

`sn_batch_prepare` prepares the entire event stream with injected create/release functions, making failure behavior testable without Apple APIs. It owns at most six events. `sn_batch_post` emits them in order on the owner thread. All events are released after submission. The application cannot guarantee atomic or successful delivery across multiple `CGEventPost` calls.

The modern payload encoder writes byte offsets explicitly into caller-provided memory, checks capacity before writing, rejects non-finite values and emits 68 or 96 bytes. The macOS adapter verifies the serialized CGEvent header and applies a 64 KiB envelope limit before appending the private payload record. This cannot validate the undocumented format against future OS changes.

## Lifecycle and external commands

The resident is the only poster. A CFMessagePort server handles a whitelist of small commands. The CLI does not start a second engine or depend on a fixed sleep as confirmation. The `posted` result is explicitly not a delivery/completion claim.

Only one external switch command may be outstanding. The owner must admit it within 250 ms, and the caller waits at most 500 ms. A running real gesture returns busy. The deadline prevents stale queued work from starting; it cannot preempt an OS call already executing after admission. Late completion after an IPC/caller timeout is still possible.

Permission and tap health are sampled once a second, with extra recovery on disabled-tap callbacks. Revocation invalidates the tap and clears private state. Enabling after a missing grant can recover without relaunch. A disabled app still drains already owned physical input when callbacks remain available. Process crash, abrupt kill, missing callbacks and quitting mid-committed gesture are outside perfect-recovery guarantees.

Hotkeys register as a pair: partial registration is rolled back and actual registration state is exposed. Unsupported OS majors do not register acceleration hotkeys. Settings use a stable defaults suite and are applied to the resident immediately. IPC is a same-session convenience channel, not authenticated remote control; see `SECURITY.md`.

## Bounds and initial tuning parameters

| Quantity | Initial limit | Reason / caveat |
|---|---:|---|
| Copied physical prefix | 32 events | Bound retained copies; fail native at capacity. |
| Active displays | 16 | Explicit bounded storage; larger topologies are unsupported. |
| Spaces per topology | 64 | Validate before use, not implicit truncation. |
| Pending predicted switches | 8 | Backpressure instead of unlimited optimistic work. |
| Snapshot polling | 100 ms | Initial latency/idle-cost tradeoff, not benchmark-tuned. |
| Snapshot maximum age | 350 ms | Reject old observations; does not eliminate races. |
| Unacknowledged prediction | 700 ms | Recover ignored/dropped posts. |
| Lost physical terminal | 2 seconds | Avoid indefinite suppression after discontinuity. |
| External switch admission / wait | 250 / 500 ms | Bounded queue age/caller wait, not a hard OS-call deadline. |
| IPC request / accepted response | 64 bytes / 64 KiB | Restrict parser surface and accidental oversized replies. |

Changes to these values should be driven by native traces and success/energy measurements, not by the portable nanosecond benchmark alone.
