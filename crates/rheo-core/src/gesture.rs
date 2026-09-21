// SPDX-License-Identifier: MIT
use crate::{Direction, GESTURE_TIMEOUT_NS, Phase};

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Kind(pub u32);
impl Kind {
    pub const OTHER: Self = Self(0);
    pub const COMPANION: Self = Self(1);
    pub const HORIZONTAL: Self = Self(2);
}
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Owner(pub u32);
impl Owner {
    pub const IDLE: Self = Self(0);
    pub const NATIVE: Self = Self(1);
    pub const PENDING: Self = Self(2);
    pub const COMMITTED: Self = Self(3);
    pub const BLOCKED: Self = Self(4);
    fn is_owned(self) -> bool {
        matches!(self, Self::PENDING | Self::COMMITTED | Self::BLOCKED)
    }
}
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Outcome(pub u32);
impl Outcome {
    pub const POSTED: Self = Self(0);
    pub const EDGE: Self = Self(1);
    pub const FAILED: Self = Self(2);
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Input {
    pub kind: Kind,
    pub phase: Phase,
    pub synthetic: bool,
    pub progress: f64,
    pub velocity: f64,
    pub now_ns: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Policy {
    pub enabled: bool,
    pub ready: bool,
    pub modern: bool,
    pub minimum_progress: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Gesture {
    pub owner: Owner,
    pub last_ns: u64,
}
pub mod flags {
    pub const PASS: u32 = 1;
    pub const DROP: u32 = 2;
    pub const BUFFER: u32 = 4;
    pub const ATTEMPT: u32 = 8;
    pub const REPLAY: u32 = 16;
    pub const DISCARD: u32 = 32;
    pub const NEUTRAL: u32 = 64;
}
use flags::*;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Action {
    pub flags: u32,
    pub direction: Direction,
    pub terminal: bool,
}
impl Action {
    pub const fn new(flags: u32) -> Self {
        Self { flags, direction: Direction::RIGHT, terminal: false }
    }
}

fn direction(value: f64, threshold: f64, modern: bool) -> Option<Direction> {
    if !value.is_finite() || value == 0.0 || value.abs() < threshold { return None; }
    Some(if (value > 0.0) != modern { Direction::RIGHT } else { Direction::LEFT })
}

impl Gesture {
    pub fn reset(&mut self) { *self = Self::default(); }

    /// Single-owner API. Any ATTEMPT must be followed immediately by feedback
    /// before processing another input. Synthetic/irrelevant input is untouched.
    pub fn step(&mut self, event: &Input, policy: &Policy) -> Action {
        if event.synthetic || !matches!(event.kind, Kind::HORIZONTAL | Kind::COMPANION) {
            return Action::new(PASS);
        }
        let mut prefix = 0;
        if self.owner.0 > Owner::BLOCKED.0 || (self.owner != Owner::IDLE &&
            (event.now_ns < self.last_ns || event.now_ns - self.last_ns > GESTURE_TIMEOUT_NS)) {
            self.reset();
            prefix = DISCARD;
        }
        self.last_ns = event.now_ns;
        if event.kind == Kind::HORIZONTAL && event.phase == Phase::BEGAN {
            self.owner = if policy.enabled && policy.ready { Owner::PENDING } else { Owner::NATIVE };
            return Action::new(prefix | DISCARD |
                if self.owner == Owner::PENDING { DROP | BUFFER } else { PASS });
        }
        if !policy.enabled && self.owner == Owner::PENDING {
            self.owner = Owner::NATIVE;
            prefix |= REPLAY;
        }
        if event.kind == Kind::COMPANION {
            return Action::new(prefix | if self.owner == Owner::PENDING { DROP | BUFFER }
                else if self.owner.is_owned() { DROP } else { PASS });
        }
        let terminal = matches!(event.phase, Phase::ENDED | Phase::CANCELLED);
        if !self.owner.is_owned() {
            if terminal { self.owner = Owner::IDLE; }
            return Action::new(prefix | PASS);
        }
        if event.phase == Phase::CANCELLED {
            let neutral = self.owner == Owner::COMMITTED && policy.modern;
            self.owner = Owner::IDLE;
            return Action::new(prefix | DISCARD | if neutral { NEUTRAL } else { DROP });
        }
        if self.owner == Owner::PENDING && matches!(event.phase, Phase::CHANGED | Phase::ENDED) {
            let value = if terminal { event.velocity } else { event.progress };
            let mut threshold = if terminal { 0.0 } else { policy.minimum_progress };
            if !threshold.is_finite() || threshold < 0.0 { threshold = 0.0; }
            if let Some(direction) = direction(value, threshold, policy.modern) {
                return Action { flags: prefix | DROP | ATTEMPT, direction, terminal };
            }
            if terminal {
                self.owner = Owner::IDLE;
                return Action::new(prefix | REPLAY | PASS);
            }
            return Action::new(prefix | DROP | BUFFER);
        }
        if terminal {
            let neutral = self.owner == Owner::COMMITTED && policy.modern;
            self.owner = Owner::IDLE;
            return Action::new(prefix | DISCARD | if neutral { NEUTRAL } else { DROP });
        }
        Action::new(prefix | DROP | if self.owner == Owner::PENDING { BUFFER } else { 0 })
    }

    /// Unknown outcomes fail to native replay instead of being treated as success.
    pub fn feedback(&mut self, outcome: Outcome, terminal: bool, modern: bool) -> Action {
        if !matches!(outcome, Outcome::POSTED | Outcome::EDGE) {
            self.owner = if terminal { Owner::IDLE } else { Owner::NATIVE };
            return Action::new(REPLAY | PASS);
        }
        if outcome == Outcome::EDGE {
            self.owner = if terminal { Owner::IDLE } else { Owner::BLOCKED };
            return Action::new(DISCARD | DROP);
        }
        self.owner = if terminal { Owner::IDLE } else { Owner::COMMITTED };
        Action::new(DISCARD | if terminal && modern { NEUTRAL } else { DROP })
    }
}
