// SPDX-License-Identifier: MIT
use core::{ffi::c_void, mem::MaybeUninit, ptr};
use rheo_ffi::*;

#[test]
fn null_arguments_are_rejected() {
    // SAFETY: null pointers are expressly accepted/rejected by every wrapper tested here.
    unsafe {
        sn_gesture_reset(ptr::null_mut());
        sn_prediction_reset(ptr::null_mut());
        assert_eq!(sn_gesture_step(ptr::null_mut(), ptr::null(), ptr::null()).flags, flags::PASS);
        assert_eq!(sn_gesture_feedback(ptr::null_mut(), Outcome::FAILED, false, false).flags, flags::PASS);
        assert!(!sn_topology_valid(ptr::null()));
        assert_eq!(sn_prediction_prepare(ptr::null_mut(), ptr::null(), 0, Direction::RIGHT, ptr::null_mut()), PlanStatus::UNKNOWN);
        assert!(!sn_prediction_commit(ptr::null_mut(), ptr::null(), 0));
        assert_eq!(sn_payload_encode(ptr::null(), ptr::null_mut(), usize::MAX), 0);
        assert!(!sn_batch_prepare(ptr::null_mut(), false, Direction::RIGHT, 2000.0, None, None, ptr::null_mut()));
        sn_batch_post(ptr::null(), None, ptr::null_mut());
        sn_batch_release(ptr::null_mut(), None, ptr::null_mut());
    }
}
#[test]
fn reset_and_plan_outputs_accept_uninitialized_storage() {
    let mut gesture = MaybeUninit::<Gesture>::uninit();
    let mut prediction = MaybeUninit::<Prediction>::uninit();
    let mut plan = MaybeUninit::<Plan>::uninit();
    let mut topology = Topology { display_id: 1, count: 2, observed_ns: 1, ..Topology::default() };
    topology.spaces[..2].copy_from_slice(&[10, 20]);
    // SAFETY: reset/output pointers address aligned writable storage, with no aliases.
    unsafe {
        sn_gesture_reset(gesture.as_mut_ptr());
        assert_eq!(gesture.assume_init(), Gesture::default());
        sn_prediction_reset(prediction.as_mut_ptr());
        let mut prediction = prediction.assume_init();
        assert_eq!(sn_prediction_prepare(&mut prediction, &topology, 2, Direction::RIGHT, plan.as_mut_ptr()), PlanStatus::OK);
        assert_eq!(plan.assume_init().target, 20);
    }
}
#[test]
fn rejected_plan_does_not_touch_output() {
    let mut prediction = Prediction::default();
    let topology = Topology::default();
    let sentinel = Plan { target: 555, generation: 888, direction: Direction(-7) };
    let mut output = sentinel;
    // SAFETY: all pointers reference initialized, aligned, non-overlapping values.
    unsafe { assert_eq!(sn_prediction_prepare(&mut prediction, &topology, 10, Direction::RIGHT, &mut output), PlanStatus::UNKNOWN); }
    assert_eq!(output, sentinel);
}
#[test]
fn encoder_accepts_uninitialized_output_and_caps_a_large_capacity() {
    let input = PayloadInput { phase: Phase::ENDED, velocity_x: 2000.0, ..PayloadInput::default() };
    let mut output = MaybeUninit::<[u8; 96]>::uninit();
    // SAFETY: output provides min(capacity,96) writable bytes and is disjoint from input.
    unsafe {
        assert_eq!(sn_payload_encode(&input, output.as_mut_ptr().cast::<u8>(), usize::MAX), 96);
        let output = output.assume_init();
        assert_eq!(&output[84..88], &131_072_000i32.to_le_bytes());
    }
}
#[test]
fn short_and_invalid_payloads_leave_output_unchanged() {
    let mut input = PayloadInput { phase: Phase::ENDED, ..PayloadInput::default() };
    for length in 0..96 {
        let mut output = [0xa5; 96];
        // SAFETY: initialized input and valid disjoint writable buffer.
        unsafe { assert_eq!(sn_payload_encode(&input, output.as_mut_ptr(), length), 0); }
        assert_eq!(output, [0xa5; 96]);
    }
    input.progress = f64::NAN;
    let mut output = [0xa5; 96];
    // SAFETY: same valid/disjoint storage; non-finite input is a supported rejection case.
    unsafe { assert_eq!(sn_payload_encode(&input, output.as_mut_ptr(), output.len()), 0); }
    assert_eq!(output, [0xa5; 96]);
}

#[derive(Default)]
struct Mock {
    calls: usize,
    live: usize,
    posts: usize,
    fail: Option<usize>,
    storage: [u8; 6],
}
unsafe extern "C" fn create(context: *mut c_void, _shape: *const Shape) -> *mut c_void {
    // SAFETY: test passes a live exclusive Mock and callbacks are serialized.
    let m = unsafe { &mut *context.cast::<Mock>() };
    let index = m.calls; m.calls += 1;
    if m.fail == Some(index) || index >= 6 { return ptr::null_mut(); }
    m.live += 1;
    ptr::addr_of_mut!(m.storage[index]).cast::<c_void>()
}
unsafe extern "C" fn release(context: *mut c_void, _event: *mut c_void) {
    // SAFETY: context remains live throughout preparation/explicit release.
    let m = unsafe { &mut *context.cast::<Mock>() };
    m.live -= 1;
}
unsafe extern "C" fn post(context: *mut c_void, _event: *mut c_void) {
    // SAFETY: test supplies its live exclusive Mock, without concurrent/reentrant calls.
    let m = unsafe { &mut *context.cast::<Mock>() };
    m.posts += 1;
}
#[test]
fn ffi_batch_failure_cleans_up_and_success_transfers_ownership() {
    for modern in [false, true] {
        let count = if modern { 6 } else { 3 };
        for failure in 0..=count {
            let mut mock = Mock { fail: if failure < count { Some(failure) } else { None }, ..Mock::default() };
            let context = ptr::addr_of_mut!(mock).cast::<c_void>();
            let mut batch = Batch::default();
            // SAFETY: mock/batch live through all callbacks, storage pointers are stable,
            // and each returned event is released exactly once using its matching context.
            unsafe {
                assert_eq!(sn_batch_prepare(&mut batch, modern, Direction::RIGHT, 2000.0,
                    Some(create), Some(release), context), failure == count);
                assert_eq!(mock.posts, 0);
                if failure == count {
                    assert_eq!(mock.live, count);
                    sn_batch_post(&batch, Some(post), context);
                    assert_eq!(mock.posts, count);
                    sn_batch_release(&mut batch, Some(release), context);
                    sn_batch_release(&mut batch, Some(release), context);
                }
            }
            assert_eq!(mock.live, 0);
            assert_eq!(batch.count, 0);
            assert!(batch.events.iter().all(|pointer| pointer.is_null()));
        }
    }
}
#[test]
fn corrupt_batch_count_and_missing_callbacks_are_rejected() {
    let mut mock = Mock::default();
    let context = ptr::addr_of_mut!(mock).cast::<c_void>();
    let mut batch = Batch { count: usize::MAX, ..Batch::default() };
    // SAFETY: initialized batch/context are valid; corrupt count is explicitly handled.
    unsafe {
        sn_batch_post(&batch, Some(post), context);
        sn_batch_release(&mut batch, Some(release), context);
        assert!(!sn_batch_prepare(&mut batch, false, Direction::RIGHT, 2000.0, Some(create), Some(release), context));
    }
    assert_eq!(mock.posts, 0);
    assert_eq!(mock.calls, 0);
    batch = Batch::default();
    // SAFETY: null callbacks are a supported parameter rejection.
    unsafe { assert!(!sn_batch_prepare(&mut batch, false, Direction::RIGHT, 2000.0, None, Some(release), context)); }
}
#[test]
fn layout_query_handles_unknown_ids_and_slots() {
    assert_eq!(sn_abi_version(), 1);
    assert_eq!(sn_abi_value(u32::MAX, 0), usize::MAX);
    assert_eq!(sn_abi_value(0, u32::MAX), usize::MAX);
    assert_eq!(sn_abi_value(11, 8), 64);
}
