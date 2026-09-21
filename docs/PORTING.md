# C → Rust port

## Scope and provenance

Input: the supplied `strafe-next.zip` containing C v0.1 and the macOS adapter.
Output: v0.2 source, a two-crate Rust workspace, the same native adapter, new build
entrypoints, ABI/differential tests and same-caller comparison benchmarks.

The four production `.c` core files are replaced, not wrapped as an implementation
dependency. Their exact originals and original header are retained under
`tests/reference/c` for testing only. `tests/core_tests.c` is unchanged. The native
`.m` code is unchanged; only its build/link inputs and app version metadata change.

## Core / foreign boundary

`rheo-core` is `no_std`, forbids unsafe code, and uses fixed-capacity state:
64 Space IDs, eight pending targets and six prepared events. Native prefix replay
remains in the retained adapter, capped there at 32 events. There is no `Vec`,
`Box`, runtime executor, dependency crate or new lock in production Rust.

`rheo-ffi` is a standard-library static library. This is Rust's intended artifact
for linking Rust into a non-Rust executable [1]. It exposes the C header and keeps
raw pointers and callback invocation out of the core. The static library may include
Rust standard-library support code; absence of external Cargo dependencies is not
a claim that it is a freestanding binary. Darwin linking requests dead stripping.

The C header retains layout-compatible structs. Rust uses `repr(C)` for aggregates
and transparent integer newtypes for foreign enum values. A C enum can legally hold
values outside its named variants; constructing a Rust enum with an invalid
discriminant is undefined behavior. Integer wrappers keep unknown values valid and
allow explicit rejection instead [2]. Shared C booleans still require valid C `_Bool`
representations, and C state must be initialized.

`sn_abi_value` exports field-layout diagnostics. The C test checks all eleven shared
structs' sizes, alignments and offsets, as well as enum widths and capacity constants.
Supported native targets are 64-bit Apple ARM/x86 and Linux x86-64 for portable tests.
Do not build C with short-enum or packing flags.

## Resource ownership and failure behavior

Safe Rust's `PreparedBatch<E>` owns up to six `Option<E>` slots. If creation N fails,
all already-created E values drop. The FFI wraps each foreign handle in an owning
`ForeignEvent` with its release callback/context; only after complete preparation
are handles transferred into the C `sn_batch`. This retains all-events-before-posting
semantics without hand-written cleanup at every early return.

The transferred C batch must still be released exactly once with the matching
callback/context. Copying it duplicates raw ownership and is prohibited. Passing a
dangling pointer, freeing handles early, data races or foreign callback unwinding
can still invalidate the application. This is NOT an entirely memory-safe native app.

`sn_prediction_prepare` writes successful plans through `ptr::write`: the C adapter
passes an uninitialized `sn_plan` output. Forming a mutable reference to that storage
before initializing it would assert an invalid invariant [3]. Reset functions follow
the same pattern. Error returns do not overwrite plan outputs.

The payload wrapper likewise accommodates uninitialized C output arrays: it encodes
into an initialized 96-byte stack buffer, then copies only the successful 68/96-byte
result. It never creates a Rust byte slice over uninitialized output. Large reported
capacities do not become huge Rust slices. The safe encoder itself accepts ordinary
initialized mutable slices and does not perform this additional boundary copy.

All pointer wrappers reject null, but cannot authenticate arbitrary non-null pointers.
Input/output/state memory must be valid, aligned, disjoint and appropriately exclusive.
Foreign callbacks cannot unwind/longjmp, retain descriptor addresses or re-enter/mutate
the active batch. Safety preconditions are documented on every unsafe entrypoint.

## Intended equivalence and deliberate hardening

Valid-input semantics match C v0.1 by construction and are exercised by a supplied
differential harness. **The Rust half has not run, so equivalence is not established.**
The comparisons deliberately ignore struct padding and unused pending slots.

The generation counter uses `wrapping_add`, matching unsigned C overflow even in Rust
debug builds. The legacy progress constant is `f32::from_bits(1) as f64`, NOT Rust's
smallest positive normal float. Payload fields use explicit little-endian writes.

Some previously unsupported inputs receive defined conservative handling:

* Unknown kind values pass through without changing state; unknown owner state is reset.
* Unknown posting outcomes replay to native handling, rather than masquerading as success.
* Out-of-range prediction lengths are rejected before slicing; fresh valid topology is
  adopted with an UNKNOWN response. Commit rejects oversized counts without indexing.
* Oversized foreign batch counts are rejected. A batch containing a null handle is not
  partially posted. Corrupt ownership is not guessed or "repaired" by freeing arbitrary memory.

These changes are explicit: the differential input domain uses valid kinds/outcomes and
state produced by the public APIs. Separate Rust tests cover the hardened invalid inputs.
No gesture-threshold, timeout, monitoring interval, animation or native protocol changes
are hidden in the port.

## Performance policy

Release settings are `opt-level=3`, ThinLTO, one codegen unit and `panic=abort` [4].
They are a starting configuration, not proof of optimal performance. No global
`target-cpu=native` is forced into distributed binaries; ARM and x86 targets are built
separately for universal apps. No fast-math flags invalidate NaN/finite checks.

The safe core does not allocate or lock. The existing adapter and CoreGraphics still
do. The FFI payload temporary adds at most 96 bytes of stack storage and a bounded copy;
whether optimization removes some of that work must be measured, not assumed.

`scripts/bench.sh` compiles the unchanged C caller against the C reference and against
Rust. It alternates execution order across four rounds and records 31 raw batch means
per operation per round. The comparison includes FFI and wrapper costs, has the same
call boundary, and does not use cross-language LTO. Rust uses its configured ThinLTO;
the C reference uses its existing `-O3` configuration. This is a comparison of these
builds/toolchains, not a controlled proof about programming languages in general.

It measures unrelated-event rejection, a gesture lifecycle and payload encoding. It
excludes WindowServer, Dock, CoreGraphics posting, physical gestures, CPU wakeups and
input-to-interactive latency. No Rust benchmark numbers are available in this delivery.

## Test inventory

29 Rust tests: 21 safe-core tests and eight boundary tests. The suite includes a
one-million-event adversarial stream, resource-drop failure injection, invalid floating
point values, topology capacity/generation checks, uninitialized outputs and null pointers.

The retained 33-group C regression suite runs against Rust in `scripts/test.sh`, followed
by C/Rust field layout checks and differential comparisons: one million gesture inputs,
200,000 prediction steps, 100,000 payload/fixed-point cases and 22 batch cases.

Stable-Rust `test.sh` instruments the C harness/reference and native test adapter with
ASan/UBSan. It does NOT instrument the Rust static library. The optional libFuzzer script
mutates inputs through the C ABI, but Rust internals are not coverage-instrumented; do
not describe that as a Rust coverage-guided campaign. Optional Miri scripts interpret
the safe core and Rust-defined FFI tests with an installed nightly interpreter.
All of these Rust-dependent checks remain unexecuted here.

## Primary references (consulted 21 September 2026)

1. Rust Reference, static libraries / foreign linking:
   https://doc.rust-lang.org/reference/linkage.html
2. Rust Reference, C representation and fieldless-enum validity:
   https://doc.rust-lang.org/stable/reference/type-layout.html
3. Rust standard/core library, MaybeUninit and output-pointer initialization:
   https://doc.rust-lang.org/core/mem/union.MaybeUninit.html
4. Cargo Book, optimization, LTO and panic profiles:
   https://doc.rust-lang.org/cargo/reference/profiles.html
5. Rust Edition Guide, edition 2024 introduced with 1.85.0:
   https://doc.rust-lang.org/edition-guide/rust-2024/index.html
