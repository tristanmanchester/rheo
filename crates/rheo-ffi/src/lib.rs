// SPDX-License-Identifier: MIT
//! C ABI compatibility for `src/core/rheo_core.h`.
//!
//! # Foreign-caller contract
//! Non-null input/state pointers must be aligned, initialized and valid for their
//! declared types. Mutable regions are exclusive, and input/output/state regions
//! must not overlap. Calls on a given state are serialized. Callbacks must not
//! unwind/longjmp or re-enter/mutate the active batch. Event handles remain valid
//! until released exactly once with the matching context. Null pointers are
//! rejected; a dangling non-null pointer CANNOT be validated here.
//!
//! Reset functions and the successful plan output accept uninitialized storage:
//! they write through a raw pointer rather than creating a reference first.
#![deny(unsafe_op_in_unsafe_fn)]

use core::ffi::c_void;
use core::mem::{align_of, offset_of, size_of};
use core::ptr::{self, NonNull};
pub use rheo_core::*;

pub type CreateFn = unsafe extern "C" fn(*mut c_void, *const Shape) -> *mut c_void;
pub type EventFn = unsafe extern "C" fn(*mut c_void, *mut c_void);

#[repr(C)]
#[derive(Debug)]
pub struct Batch {
    pub events: [*mut c_void; MAX_BATCH],
    pub count: usize,
}
impl Default for Batch {
    fn default() -> Self { Self { events: [ptr::null_mut(); MAX_BATCH], count: 0 } }
}

/// # Safety
/// `gesture` must be null or valid, aligned, exclusively writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_gesture_reset(gesture: *mut Gesture) {
    if !gesture.is_null() {
        // SAFETY: caller provides writable storage; no old/uninitialized data read.
        unsafe { gesture.write(Gesture::default()); }
    }
}

/// # Safety
/// Pointers must obey the crate's foreign-caller contract; state must be initialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_gesture_step(gesture: *mut Gesture, input: *const Input, policy: *const Policy) -> Action {
    if gesture.is_null() || input.is_null() || policy.is_null() { return Action::new(flags::PASS); }
    // SAFETY: pointers are non-null; validity, exclusivity and disjointness are caller obligations.
    unsafe { (&mut *gesture).step(&*input, &*policy) }
}

/// # Safety
/// `gesture` must be null or an initialized, exclusively borrowed state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_gesture_feedback(gesture: *mut Gesture, outcome: Outcome, terminal: bool, modern: bool) -> Action {
    if gesture.is_null() { return Action::new(flags::PASS); }
    // SAFETY: caller provides an initialized, valid, exclusive state.
    unsafe { (&mut *gesture).feedback(outcome, terminal, modern) }
}

/// # Safety
/// `topology` must be null or a valid, aligned, initialized read-only topology.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_topology_valid(topology: *const Topology) -> bool {
    if topology.is_null() { return false; }
    // SAFETY: caller guarantees read access; all array lengths are validated in Rust.
    unsafe { (&*topology).is_valid() }
}

/// # Safety
/// `prediction` must be null or valid, aligned, exclusively writable storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_prediction_reset(prediction: *mut Prediction) {
    if !prediction.is_null() {
        // SAFETY: this initializes storage without reading its old representation.
        unsafe { prediction.write(Prediction::default()); }
    }
}

/// # Safety
/// Initialized state/topology and writable plan storage must be valid, aligned,
/// disjoint and accessible for the call. `out` need not be initialized and is
/// written ONLY on OK. All pointers may be null (returns UNKNOWN).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_prediction_prepare(prediction: *mut Prediction, topology: *const Topology,
    now: u64, direction: Direction, out: *mut Plan) -> PlanStatus
{
    if prediction.is_null() || topology.is_null() || out.is_null() { return PlanStatus::UNKNOWN; }
    // SAFETY: initialized disjoint state/topology guaranteed by foreign caller.
    let result = unsafe { (&mut *prediction).prepare(&*topology, now, direction) };
    match result {
        Ok(plan) => {
            // SAFETY: writable output storage; write does NOT borrow uninitialized data.
            unsafe { out.write(plan); }
            PlanStatus::OK
        }
        Err(status) => status,
    }
}

/// # Safety
/// Non-null state/plan must be initialized, aligned, valid and disjoint; state is exclusive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_prediction_commit(prediction: *mut Prediction, plan: *const Plan, now: u64) -> bool {
    if prediction.is_null() || plan.is_null() { return false; }
    // SAFETY: caller upholds validity and exclusive state access.
    unsafe { (&mut *prediction).commit(&*plan, now) }
}

#[unsafe(no_mangle)]
pub extern "C" fn sn_fixed1616(value: f64) -> i32 { fixed1616(value) }

/// # Safety
/// Input must be initialized/aligned/readable, and output exclusively writable
/// for at least min(capacity, 96) bytes, without overlapping input. A null pointer
/// is rejected. Output bytes need not be initialized: encoding writes via a
/// temporary initialized array and raw copy, never borrows uninitialized bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_payload_encode(input: *const PayloadInput, output: *mut u8, capacity: usize) -> usize {
    if input.is_null() || output.is_null() || capacity < 68 { return 0; }
    // SAFETY: foreign caller provides a valid initialized input.
    let input = unsafe { &*input };
    // A C caller commonly supplies an uninitialized uint8_t buffer. Creating
    // &mut [u8] over it would assert initialization that has not happened yet.
    // The bounded temporary costs at most 96 bytes and one output copy.
    let mut encoded = [0u8; 96];
    let length = encode_payload(input, &mut encoded[..capacity.min(96)]);
    if length != 0 {
        // SAFETY: length <= min(capacity,96); caller guarantees writable, disjoint output.
        unsafe { ptr::copy_nonoverlapping(encoded.as_ptr(), output, length); }
    }
    length
}

struct ForeignEvent {
    handle: NonNull<c_void>,
    release: EventFn,
    context: *mut c_void,
}
impl ForeignEvent {
    fn into_raw(self) -> *mut c_void {
        let handle = self.handle.as_ptr();
        // Ownership is transferred to the C batch, released by sn_batch_release.
        core::mem::forget(self);
        handle
    }
}
impl Drop for ForeignEvent {
    fn drop(&mut self) {
        // SAFETY: only constructed for a successfully created event; callback
        // contract keeps the context/handle alive and forbids reentry/unwinding.
        unsafe { (self.release)(self.context, self.handle.as_ptr()); }
    }
}

/// # Safety
/// Batch must be null or a fully initialized valid batch with count=0 and exclusive
/// access. Callbacks/context must satisfy the crate contract. A successful create
/// transfers one owned handle. Callbacks must not borrow the short-lived shape
/// beyond the call. Rejected parameters leave the batch untouched.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_batch_prepare(batch: *mut Batch, modern: bool, direction: Direction, velocity: f64,
    create: Option<CreateFn>, release: Option<EventFn>, context: *mut c_void) -> bool
{
    if batch.is_null() { return false; }
    let (Some(create), Some(release)) = (create, release) else { return false; };
    let Some(shapes) = Shapes::new(modern, direction, velocity) else { return false; };
    // SAFETY: caller provides a fully initialized exclusive batch.
    let batch = unsafe { &mut *batch };
    if batch.count != 0 { return false; }
    // Establish a deterministic empty state before the first callback.
    *batch = Batch::default();
    let Some(prepared) = PreparedBatch::prepare(&shapes, |shape| {
        // SAFETY: callbacks/context are guaranteed valid; shape lives for this call.
        let handle = NonNull::new(unsafe { create(context, shape) })?;
        Some(ForeignEvent { handle, release, context })
    }) else {
        // PreparedBatch dropped every successful prior event via ForeignEvent::drop.
        return false;
    };
    for event in prepared.into_events().into_iter().flatten() {
        batch.events[batch.count] = event.into_raw();
        batch.count += 1;
    }
    true
}

/// # Safety
/// Batch must be initialized, valid and immutable throughout the callback sequence.
/// Callback must accept each live handle with this context, and cannot unwind or
/// release the batch. Null/invalid-count/null-handle batches are not posted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_batch_post(batch: *const Batch, post: Option<EventFn>, context: *mut c_void) {
    if batch.is_null() { return; }
    let Some(post) = post else { return; };
    // SAFETY: initialized read-only batch guaranteed by caller.
    let batch = unsafe { &*batch };
    if batch.count > MAX_BATCH || batch.events[..batch.count].iter().any(|handle| handle.is_null()) { return; }
    for &event in &batch.events[..batch.count] {
        // SAFETY: caller owns all handles and provides the matching valid callback/context.
        unsafe { post(context, event); }
    }
}

/// # Safety
/// Batch is initialized and exclusively accessible. Every live handle requires the
/// matching release callback/context. Invalid counts are rejected without guessing
/// ownership. Do not copy a nonempty C batch: that would duplicate ownership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sn_batch_release(batch: *mut Batch, release: Option<EventFn>, context: *mut c_void) {
    if batch.is_null() { return; }
    let Some(release) = release else { return; };
    // SAFETY: caller supplies exclusive initialized state.
    let batch = unsafe { &mut *batch };
    if batch.count > MAX_BATCH { return; }
    let owned = core::mem::take(batch);
    for &event in &owned.events[..owned.count] {
        if !event.is_null() {
            // SAFETY: ownership transferred to us; this handle is released once.
            unsafe { release(context, event); }
        }
    }
}

/// ABI revision. The structs match the previous C core on supported 64-bit ABIs.
#[unsafe(no_mangle)]
pub extern "C" fn sn_abi_version() -> u32 { 1 }

/// Runtime layout verification. type_id 0..=10 follows the structs below;
/// slot 0=size, 1=alignment, 2+=field offsets. Unknown values return SIZE_MAX.
#[unsafe(no_mangle)]
pub extern "C" fn sn_abi_value(type_id: u32, slot: u32) -> usize {
    macro_rules! layout {
        ($ty:ty, $($field:ident),+ $(,)?) => {
            [size_of::<$ty>(), align_of::<$ty>(), $(offset_of!($ty, $field)),+]
                .get(slot as usize).copied().unwrap_or(usize::MAX)
        };
    }
    match type_id {
        0 => layout!(Input, kind, phase, synthetic, progress, velocity, now_ns),
        1 => layout!(Policy, enabled, ready, modern, minimum_progress),
        2 => layout!(Gesture, owner, last_ns),
        3 => layout!(Action, flags, direction, terminal),
        4 => layout!(Topology, display_id, count, current, observed_ns, spaces),
        5 => layout!(Pending, target, posted_ns),
        6 => layout!(Prediction, display_id, count, pending_count, spaces, observed_id, sample_ns, generation, pending),
        7 => layout!(Plan, target, generation, direction),
        8 => layout!(PayloadInput, timestamp, phase, progress, position_x, position_y, velocity_x, velocity_y, swipe_mask),
        9 => layout!(Shape, phase, companion, modern, progress, velocity_x, velocity_y),
        10 => layout!(Batch, events, count),
        11 => [size_of::<Direction>(), align_of::<Direction>(), size_of::<Phase>(),
            align_of::<Phase>(), size_of::<Kind>(), size_of::<Owner>(), size_of::<Outcome>(),
            size_of::<PlanStatus>(), MAX_SPACES, MAX_PENDING, MAX_BATCH].get(slot as usize).copied().unwrap_or(usize::MAX),
        _ => usize::MAX,
    }
}
