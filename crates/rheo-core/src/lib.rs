// SPDX-License-Identifier: MIT
//! Portable, allocation-free decision/encoding core. Foreign pointers and callbacks
//! are deliberately confined to the separate `rheo-ffi` crate.
#![no_std]
#![forbid(unsafe_code)]

pub mod batch;
pub mod gesture;
pub mod payload;
pub mod prediction;

pub use batch::{PreparedBatch, Shape, Shapes};
pub use gesture::{Action, Gesture, Input, Kind, Outcome, Owner, Policy, flags};
pub use payload::{PayloadInput, encode_payload, fixed1616};
pub use prediction::{Pending, Plan, PlanStatus, Prediction, Topology};

pub const MAX_SPACES: usize = 64;
pub const MAX_PENDING: usize = 8;
pub const MAX_BATCH: usize = 6;
pub const SNAPSHOT_MAX_AGE_NS: u64 = 350_000_000;
pub const PREDICTION_TIMEOUT_NS: u64 = 700_000_000;
pub const GESTURE_TIMEOUT_NS: u64 = 2_000_000_000;
pub const EVENT_MARKER: i64 = 0x5248_454f_4556_5431; // RHEOEVT1
pub const EVENT_MASK: u64 = (1 << 29) | (1 << 30);

/// An open integer newtype, NOT a Rust enum: foreign integers may be unknown.
/// This matches the signed C enum on the supported 64-bit Darwin/Linux ABIs.
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Direction(pub i32);
impl Direction {
    pub const LEFT: Self = Self(-1);
    pub const RIGHT: Self = Self(1);
    pub fn is_valid(self) -> bool { self == Self::LEFT || self == Self::RIGHT }
}

/// Unknown phases remain representable; the gesture machine preserves the C policy.
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Phase(pub u32);
impl Phase {
    pub const NONE: Self = Self(0);
    pub const BEGAN: Self = Self(1);
    pub const CHANGED: Self = Self(2);
    pub const ENDED: Self = Self(4);
    pub const CANCELLED: Self = Self(8);
    pub const MAY_BEGIN: Self = Self(128);
    pub fn is_payload_phase(self) -> bool {
        matches!(self, Self::BEGAN | Self::CHANGED | Self::ENDED | Self::CANCELLED)
    }
}
