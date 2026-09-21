# Security and privacy — Rust core port

This app is a local Space-swipe interceptor with a retained native Objective-C
adapter. It needs Accessibility for the existing tap/overlay behavior. The port
adds no network client, telemetry service, updater or new permission request.
The Rust workspace has no third-party Cargo dependencies. Build scripts use offline
Cargo operations after an appropriate toolchain/target standard library is installed.
CI explicitly installs its own toolchain; it is not a runtime updater.

The safe decision/encoding crate is no_std and forbids unsafe code. The separate FFI
crate contains raw pointer/callback operations, with documented validity, aliasing,
ownership and unwinding preconditions. This boundary and the Objective-C adapter
remain unsafe native code. A valid Rust core cannot protect against arbitrary
foreign pointer corruption, premature handle release, C data races or an invalid
private OS protocol. No blanket application memory-safety claim is made.

Production Rust uses bounded inline arrays and no heap containers or added locks.
Lengths from externally mutable state are checked before indexing. Unknown kind/
outcome values remain valid integers instead of invalid Rust enum discriminants.
NaN/infinite movement cannot choose a direction. Output pointers are initialized
before they are read as Rust values. Temporary payload bytes are stack-local.

All event resources are prepared before any synthetic post. Owning batch values
release partial preparations on failure. Complete success transfers handles to the
C batch, whose owner must release them exactly once. Actual delivery to Dock is not
transactional or acknowledged. Raw callback pointers must remain valid and cannot
unwind/longjmp, re-enter or mutate active state.

The inherited adapter observes gesture/dock-control event types, cached Space/display
metadata and Dock Accessibility overlay identifiers; it does not add a general
keyboard monitor. Native event objects and prefix buffers remain transient and local.
Status describes observed state and `posted` is not a completed-switch guarantee.
See the historical security document for the retained native implementation details.

Private CGS/IOHID behavior is version-specific. The adapter's existing unsupported-
version policy remains. Do not disable SIP, bypass Accessibility, modify Dock or
run multiple interceptors together. App signing is ad hoc by default; notarization
and automatic updates are not part of this source package.

Validation is incomplete: Rust compilation, Rust tests, full ABI checks and native
macOS execution were not available in this delivery environment. See VALIDATION.md
before using it on a desktop. Report failures with OS/build version and minimal
reproduction, avoiding private window contents or input histories.
