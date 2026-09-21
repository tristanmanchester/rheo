// SPDX-License-Identifier: MIT
use std::cell::Cell;
use rheo_core::{flags::*, *};

fn policy() -> Policy { Policy { enabled: true, ready: true, modern: false, minimum_progress: 0.0 } }
fn event(phase: Phase, progress: f64, velocity: f64, now_ns: u64) -> Input {
    Input { kind: Kind::HORIZONTAL, phase, progress, velocity, now_ns, synthetic: false }
}
fn topology() -> Topology {
    let mut t = Topology { display_id: 1, count: 5, current: 0, observed_ns: 100, ..Topology::default() };
    t.spaces[..5].copy_from_slice(&[10, 20, 30, 40, 50]);
    t
}
#[test]
fn native_cancel_passes_through() {
    let mut g = Gesture::default();
    let p = Policy { ready: false, ..policy() };
    assert_eq!(g.step(&event(Phase::BEGAN, 0.0, 0.0, 1), &p).flags, DISCARD | PASS);
    assert_eq!(g.step(&event(Phase::CANCELLED, 0.0, 0.0, 2), &p).flags, PASS);
    assert_eq!(g.owner, Owner::IDLE);
}
#[test]
fn one_switch_per_swipe_and_committed_disable_drains() {
    let mut g = Gesture::default();
    let mut p = policy();
    g.step(&event(Phase::BEGAN, 0.0, 0.0, 1), &p);
    assert_eq!(g.step(&event(Phase::CHANGED, 0.2, 0.0, 2), &p).flags, DROP | ATTEMPT);
    g.feedback(Outcome::POSTED, false, false);
    p.enabled = false;
    for now in 3..40 {
        assert_eq!(g.step(&event(Phase::CHANGED, -0.5, 0.0, now), &p).flags, DROP);
    }
    assert_eq!(g.step(&event(Phase::ENDED, 0.0, 1.0, 40), &p).flags, DISCARD | DROP);
    assert_eq!(g.owner, Owner::IDLE);
}
#[test]
fn uncommitted_disable_replays() {
    let mut g = Gesture::default();
    g.step(&event(Phase::BEGAN, 0.0, 0.0, 1), &policy());
    let p = Policy { enabled: false, ..policy() };
    assert_eq!(g.step(&event(Phase::CHANGED, 1.0, 0.0, 2), &p).flags, REPLAY | PASS);
    assert_eq!(g.owner, Owner::NATIVE);
}
#[test]
fn invalid_motion_and_zero_end_replay_the_prefix() {
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 0.0, -0.0] {
        let mut g = Gesture::default();
        g.step(&event(Phase::BEGAN, 0.0, 0.0, 1), &policy());
        assert_eq!(g.step(&event(Phase::CHANGED, value, 0.0, 2), &policy()).flags, DROP | BUFFER);
        assert_eq!(g.step(&event(Phase::ENDED, 0.0, value, 3), &policy()).flags, REPLAY | PASS);
    }
}
#[test]
fn modern_direction_and_terminal_feedback() {
    for modern in [false, true] {
        for sign in [-1.0, 1.0] {
            let p = Policy { modern, ..policy() };
            let mut g = Gesture::default();
            g.step(&event(Phase::BEGAN, 0.0, 0.0, 1), &p);
            let a = g.step(&event(Phase::ENDED, 0.0, sign, 2), &p);
            assert_eq!(a.flags, DROP | ATTEMPT);
            assert!(a.terminal);
            assert_eq!(a.direction, Direction(if modern { -sign as i32 } else { sign as i32 }));
            assert_eq!(g.feedback(Outcome::POSTED, true, modern).flags, DISCARD | if modern { NEUTRAL } else { DROP });
        }
    }
}
#[test]
fn invalid_threshold_and_smallest_movement_remain_defined() {
    for threshold in [f64::NAN, -1.0, f64::INFINITY, 0.0] {
        let mut g = Gesture::default();
        let p = Policy { minimum_progress: threshold, ..policy() };
        g.step(&event(Phase::BEGAN, 0.0, 0.0, 1), &p);
        assert_ne!(g.step(&event(Phase::CHANGED, f64::from_bits(1), 0.0, 2), &p).flags & ATTEMPT, 0);
    }
}
#[test]
fn unknown_foreign_values_are_not_rust_enum_undefined_behavior() {
    let mut g = Gesture { owner: Owner(u32::MAX), last_ns: 0 };
    let p = policy();
    assert_eq!(g.step(&event(Phase::ENDED, 1.0, 1.0, 1), &p).flags, DISCARD | PASS);
    let unknown = Input { kind: Kind(u32::MAX), ..Input::default() };
    assert_eq!(g.step(&unknown, &p).flags, PASS);
    g.owner = Owner::PENDING;
    assert_eq!(g.feedback(Outcome(u32::MAX), false, false).flags, REPLAY | PASS);
    assert_eq!(g.owner, Owner::NATIVE);
}
#[test]
fn backwards_clock_recovers_without_replaying_old_input() {
    let mut g = Gesture::default();
    g.step(&event(Phase::BEGAN, 0.0, 0.0, 100), &policy());
    let e = Input { kind: Kind::COMPANION, now_ns: 99, ..Input::default() };
    assert_eq!(g.step(&e, &policy()).flags, DISCARD | PASS);
}
#[test]
fn intermediate_ack_keeps_later_targets() {
    let mut p = Prediction::default();
    let mut t = topology();
    for now in 101..104 {
        let plan = p.prepare(&t, now, Direction::RIGHT).unwrap();
        assert!(p.commit(&plan, now));
    }
    t.current = 1; t.observed_ns = 110;
    let plan = p.prepare(&t, 110, Direction::RIGHT).unwrap();
    assert_eq!(p.pending_count, 2);
    assert_eq!(plan.target, 50);
}
#[test]
fn forged_and_duplicate_commits_are_rejected() {
    let mut p = Prediction::default();
    let plan = p.prepare(&topology(), 101, Direction::RIGHT).unwrap();
    assert!(!p.commit(&Plan { target: 50, ..plan }, 101));
    assert!(!p.commit(&plan, 99));
    assert!(p.commit(&plan, 101));
    assert!(!p.commit(&plan, 102));
}
#[test]
fn corrupted_foreign_lengths_cannot_index_out_of_bounds() {
    for count in [65, u32::MAX] {
        let mut p = Prediction { count, ..Prediction::default() };
        assert_eq!(p.prepare(&topology(), 101, Direction::RIGHT), Err(PlanStatus::UNKNOWN));
        assert_eq!(p.count, 5);
        assert_eq!(p.pending_count, 0);
    }
    for pending_count in [9, u32::MAX] {
        let mut p = Prediction { count: 5, pending_count, ..Prediction::default() };
        let plan = Plan { direction: Direction::RIGHT, target: 20, generation: 0 };
        assert!(!p.commit(&plan, 101));
        assert_eq!(p.prepare(&topology(), 101, Direction::RIGHT), Err(PlanStatus::UNKNOWN));
    }
}
#[test]
fn pending_capacity_and_timeout_are_bounded() {
    let mut p = Prediction::default();
    let mut t = topology();
    for i in 0..MAX_PENDING {
        let direction = if i % 2 == 0 { Direction::RIGHT } else { Direction::LEFT };
        let plan = p.prepare(&t, 101 + i as u64, direction).unwrap();
        assert!(p.commit(&plan, 101 + i as u64));
    }
    assert_eq!(p.prepare(&t, 120, Direction::RIGHT), Err(PlanStatus::BUSY));
    t.observed_ns = PREDICTION_TIMEOUT_NS + 102;
    assert_eq!(p.prepare(&t, t.observed_ns, Direction::RIGHT), Err(PlanStatus::EXPIRED));
    assert_eq!(p.pending_count, 0);
}
#[test]
fn generation_overflow_has_c_unsigned_wrap_semantics() {
    let mut p = Prediction { generation: u64::MAX, ..Prediction::default() };
    let plan = p.prepare(&topology(), 101, Direction::RIGHT).unwrap();
    assert_eq!(plan.generation, 0);
    assert!(p.commit(&plan, 101));
    assert_eq!(p.generation, 1);
}
#[test]
fn invalid_topology_is_rejected_without_mutating_state() {
    let mut p = Prediction::default();
    let original = p;
    let mut t = topology();
    t.spaces[2] = t.spaces[0];
    assert!(!t.is_valid());
    assert_eq!(p.prepare(&t, 101, Direction::RIGHT), Err(PlanStatus::UNKNOWN));
    assert_eq!(p, original);
    t.count = u32::MAX;
    assert!(!t.is_valid());
}
#[test]
fn payload_is_byte_exact_and_does_not_touch_tail() {
    let mut input = PayloadInput { timestamp: 0x1122_3344_5566_7788, phase: Phase::BEGAN,
        progress: -1e-4, position_x: 0.1, ..PayloadInput::default() };
    let mut out = [0xa5; 100];
    assert_eq!(encode_payload(&input, &mut out), 68);
    assert_eq!(&out[..8], &input.timestamp.to_le_bytes());
    assert_eq!(&out[64..68], &(-6i32).to_le_bytes());
    assert!(out[68..].iter().all(|&byte| byte == 0xa5));
    input.phase = Phase::ENDED; input.velocity_x = -2000.0;
    assert_eq!(encode_payload(&input, &mut out), 96);
    assert_eq!(&out[84..88], &(-131_072_000i32).to_le_bytes());
    assert!(out[96..].iter().all(|&byte| byte == 0xa5));
}
#[test]
fn payload_all_short_buffers_and_invalid_phases_leave_bytes_untouched() {
    let mut input = PayloadInput { phase: Phase::ENDED, ..PayloadInput::default() };
    for size in 0..96 {
        let mut output = [0xa5; 96];
        assert_eq!(encode_payload(&input, &mut output[..size]), 0);
        assert_eq!(output, [0xa5; 96]);
    }
    for phase in [Phase::NONE, Phase::MAY_BEGIN, Phase(3), Phase(u32::MAX)] {
        input.phase = phase;
        let mut output = [0xa5; 96];
        assert_eq!(encode_payload(&input, &mut output), 0);
        assert_eq!(output, [0xa5; 96]);
    }
}
#[test]
fn fixed_point_extremes_are_saturated_or_rejected() {
    assert_eq!(fixed1616(f64::NAN), 0);
    assert_eq!(fixed1616(f64::INFINITY), 0);
    assert_eq!(fixed1616(f64::MAX), i32::MAX);
    assert_eq!(fixed1616(-f64::MAX), i32::MIN);
    assert_eq!(fixed1616(f64::from_bits(1)), 1);
    assert_eq!(fixed1616(-f64::from_bits(1)), -1);
    assert_eq!(fixed1616(-0.0), 0);
}

struct Counted<'a>(&'a Cell<usize>);
impl Drop for Counted<'_> {
    fn drop(&mut self) { self.0.set(self.0.get() - 1); }
}
#[test]
fn owning_batch_drops_every_prior_event_at_every_failure_position() {
    for modern in [false, true] {
        let shapes = Shapes::new(modern, Direction::RIGHT, 2000.0).unwrap();
        for fail in 0..shapes.as_slice().len() {
            let live = Cell::new(0);
            let mut calls = 0;
            let batch = PreparedBatch::prepare(&shapes, |_| {
                let i = calls; calls += 1;
                if i == fail { return None; }
                live.set(live.get() + 1);
                Some(Counted(&live))
            });
            assert!(batch.is_none());
            assert_eq!(live.get(), 0);
            assert_eq!(calls, fail + 1);
        }
    }
}
#[test]
fn successful_batch_owns_then_releases_all_events() {
    let live = Cell::new(0);
    let posts = Cell::new(0);
    let shapes = Shapes::new(true, Direction::RIGHT, 2000.0).unwrap();
    let batch = PreparedBatch::prepare(&shapes, |_| {
        live.set(live.get() + 1);
        Some(Counted(&live))
    }).unwrap_or_else(|| panic!("mock allocation unexpectedly failed"));
    assert_eq!(batch.len(), 6);
    assert_eq!(live.get(), 6);
    batch.post(|_| posts.set(posts.get() + 1));
    assert_eq!(posts.get(), 6);
    drop(batch);
    assert_eq!(live.get(), 0);
}
#[test]
fn batch_descriptor_shapes_and_legacy_subnormal_match() {
    for modern in [false, true] {
        for direction in [Direction::LEFT, Direction::RIGHT] {
            let shapes = Shapes::new(modern, direction, 2000.0).unwrap();
            let stride = if modern { 2 } else { 1 };
            assert_eq!(shapes.as_slice().len(), 3 * stride);
            for (i, phase) in [Phase::BEGAN, Phase::CHANGED, Phase::ENDED].iter().enumerate() {
                let s = shapes.as_slice()[i * stride];
                assert_eq!(s.phase, *phase);
                assert!(!s.companion);
                assert_eq!(s.progress.abs(), if modern { 1e-4 } else { f32::from_bits(1) as f64 });
                if modern { assert!(shapes.as_slice()[i * stride + 1].companion); }
            }
        }
    }
    for velocity in [f64::NAN, f64::INFINITY, -1.0, 0.0, 32768.0] {
        assert!(Shapes::new(false, Direction::RIGHT, velocity).is_none());
    }
    assert!(Shapes::new(false, Direction(0), 2000.0).is_none());
}

fn random(state: &mut u64) -> u64 {
    *state ^= *state << 13; *state ^= *state >> 7; *state ^= *state << 17; *state
}
#[test]
fn million_event_adversarial_stream() {
    let mut rng = 0x5389_ae21_922a_56c1;
    let mut g = Gesture::default();
    let mut committed = 0;
    let phases = [Phase::BEGAN, Phase::CHANGED, Phase::ENDED, Phase::CANCELLED, Phase::NONE, Phase::MAY_BEGIN, Phase(255)];
    let values = [0.0, 1.0, -1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e-300, -1e-300];
    for now in 1..=1_000_000 {
        let input = Input { kind: Kind((random(&mut rng) % 3) as u32),
            phase: phases[(random(&mut rng) % 7) as usize], synthetic: random(&mut rng) % 17 == 0,
            progress: values[(random(&mut rng) % 8) as usize], velocity: values[(random(&mut rng) % 8) as usize], now_ns: now };
        let p = Policy { enabled: random(&mut rng) % 9 != 0, ready: random(&mut rng) % 7 != 0,
            modern: random(&mut rng) % 2 != 0, minimum_progress: 0.0 };
        if input.kind == Kind::HORIZONTAL && input.phase == Phase::BEGAN && !input.synthetic { committed = 0; }
        let action = g.step(&input, &p);
        assert_eq!((action.flags & (PASS | DROP | NEUTRAL)).count_ones(), 1);
        if action.flags & ATTEMPT != 0 {
            assert_eq!(g.owner, Owner::PENDING);
            assert!(!input.synthetic);
            assert!((if action.terminal { input.velocity } else { input.progress }).is_finite());
            let outcome = Outcome((random(&mut rng) % 3) as u32);
            if outcome == Outcome::POSTED { committed += 1; assert_eq!(committed, 1); }
            g.feedback(outcome, action.terminal, p.modern);
        }
    }
}
