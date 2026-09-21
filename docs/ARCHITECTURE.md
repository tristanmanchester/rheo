# Rust-port architecture

The native event flow is retained from C v0.1:

    physical gesture → dedicated CGEventTap run loop → Rust Gesture::step
      → bounded prefix suppression/replay in the Objective-C adapter
      → cached environment snapshot and Rust Prediction::prepare
      → Rust descriptor/owning batch preparation → CoreGraphics event creation
      → prediction commit → entire prepared batch posted → gesture feedback

Only the four portable C implementation modules and their linkage are replaced.
The `.m` runtime still owns live CoreGraphics objects, the event tap, resident IPC,
shortcuts, main-thread menu UI, background monitoring and physical replay buffers.

## Ownership boundaries

The event-tap owner thread serializes live gesture state and pending predictions.
Rust functions do not introduce workers, asynchronous callbacks or locks. The C ABI
requires exclusive mutable state and disjoint valid pointers during each call.

The no_std core has no unsafe code. Rust-native callers use references, slices,
Result/Option and owning event values. The FFI static library maps those operations
to the retained C interface; no production C implementation is linked as fallback.

The monitor polls every 100 ms off the tap thread and exposes timestamped snapshots.
The retained adapter reads via a nonblocking mutex attempt. Monitoring changes,
private symbols, display mapping, stale-snapshot policy and terminal neutralization
are not newly validated or changed by this port.

## Bounded storage

64 Spaces per topology; eight pending target IDs; six events per synthetic batch;
32 buffered physical prefix events in the native adapter. Payloads are 68/96 bytes.
Rust checks externally mutable lengths before indexing; the fixed arrays themselves
remain inline. The C output buffer path has an additional 96-byte stack temporary.

## Failure boundaries

A prepared batch owns all foreign events until every creation succeeds. An early
failure releases prior events; complete success transfers ownership to the C batch.
Unknown/stale topology does not authorize blind switching. A failed preparation does
not commit a prediction. CoreGraphics event submission is not an acknowledged Dock
transaction; `posted` does not mean `completed`.

Rust's release panic policy aborts rather than unwinds. That is not error recovery:
any unexpected panic is an application failure, and foreign callbacks must never
unwind through these C entrypoints. Ordinary invalid parameters take explicit
conservative rejection paths.

## Build

Cargo creates `librheo_ffi.a` for each selected target. The shell build links the
existing Objective-C files to the matching archive and compiler-reported native
libraries, then optionally combines architecture binaries with lipo. CMake delegates
to those canonical build/test scripts. The public header has a separately testable
ABI fingerprint instead of a runtime header-generation dependency.

See PORTING.md for exact differences, safety contracts, tests and references. The
full prior C design is preserved in `docs/history/c-version/ARCHITECTURE.md` as
historical context, not as evidence that the Rust port or native adapter was run.
