// SPDX-License-Identifier: MIT
use crate::{Direction, MAX_PENDING, MAX_SPACES, PREDICTION_TIMEOUT_NS, SNAPSHOT_MAX_AGE_NS};

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Topology {
    pub display_id: u32,
    pub count: u32,
    pub current: u32,
    pub observed_ns: u64,
    pub spaces: [u64; MAX_SPACES],
}
impl Default for Topology {
    fn default() -> Self {
        Self { display_id: 0, count: 0, current: 0, observed_ns: 0, spaces: [0; MAX_SPACES] }
    }
}
impl Topology {
    pub fn is_valid(&self) -> bool {
        let count = self.count as usize;
        if self.display_id == 0 || count == 0 || count > MAX_SPACES || self.current >= self.count {
            return false;
        }
        for (index, &space) in self.spaces[..count].iter().enumerate() {
            if space == 0 || self.spaces[..index].contains(&space) { return false; }
        }
        true
    }
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Pending {
    pub target: u64,
    pub posted_ns: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Prediction {
    pub display_id: u32,
    pub count: u32,
    pub pending_count: u32,
    pub spaces: [u64; MAX_SPACES],
    pub observed_id: u64,
    pub sample_ns: u64,
    pub generation: u64,
    pub pending: [Pending; MAX_PENDING],
}
impl Default for Prediction {
    fn default() -> Self {
        Self { display_id: 0, count: 0, pending_count: 0, spaces: [0; MAX_SPACES],
            observed_id: 0, sample_ns: 0, generation: 0, pending: [Pending::default(); MAX_PENDING] }
    }
}
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlanStatus(pub u32);
impl PlanStatus {
    pub const OK: Self = Self(0);
    pub const EDGE: Self = Self(1);
    pub const UNKNOWN: Self = Self(2);
    pub const BUSY: Self = Self(3);
    pub const CHANGED: Self = Self(4);
    pub const EXPIRED: Self = Self(5);
}
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Plan {
    pub target: u64,
    pub generation: u64,
    pub direction: Direction,
}

impl Prediction {
    pub fn reset(&mut self) { *self = Self::default(); }

    fn adopt(&mut self, topology: &Topology) {
        // Only called after validating the complete topology.
        self.display_id = topology.display_id;
        self.count = topology.count;
        let count = topology.count as usize;
        self.spaces[..count].copy_from_slice(&topology.spaces[..count]);
        self.observed_id = topology.spaces[topology.current as usize];
        self.sample_ns = topology.observed_ns;
        self.pending_count = 0;
        self.generation = self.generation.wrapping_add(1);
    }

    /// Computes a target without reserving/posting it. A failed post must not commit.
    /// Retains the C version's intermediate-acknowledgement and timeout semantics.
    pub fn prepare(&mut self, topology: &Topology, now: u64, direction: Direction)
        -> Result<Plan, PlanStatus>
    {
        if !direction.is_valid() || !topology.is_valid() || now < topology.observed_ns ||
            now - topology.observed_ns > SNAPSHOT_MAX_AGE_NS {
            return Err(PlanStatus::UNKNOWN);
        }
        // Foreign callers can mutate these public ABI fields. Validate lengths
        // before ANY indexing, including when no valid state has been adopted.
        if self.count as usize > MAX_SPACES || self.pending_count as usize > MAX_PENDING ||
            (self.count == 0 && self.pending_count != 0) {
            self.adopt(topology);
            return Err(PlanStatus::UNKNOWN);
        }
        let count = topology.count as usize;
        if self.count == 0 {
            self.adopt(topology);
        } else if self.display_id != topology.display_id || self.count != topology.count ||
            self.spaces[..count] != topology.spaces[..count] {
            let was_pending = self.pending_count != 0;
            self.adopt(topology);
            if was_pending { return Err(PlanStatus::CHANGED); }
        }
        if topology.observed_ns < self.sample_ns { return Err(PlanStatus::UNKNOWN); }
        let actual = topology.spaces[topology.current as usize];
        if actual != self.observed_id {
            let mut acknowledged = 0;
            let mut uncertain = self.pending_count != 0 && topology.observed_ns < self.pending[0].posted_ns;
            for (index, pending) in self.pending[..self.pending_count as usize].iter().enumerate() {
                if pending.target == actual {
                    if topology.observed_ns >= pending.posted_ns { acknowledged = index + 1; }
                    else { uncertain = true; }
                }
            }
            if acknowledged != 0 {
                let previous_count = self.pending_count as usize;
                self.pending.copy_within(acknowledged..previous_count, 0);
                self.pending_count -= acknowledged as u32;
                self.observed_id = actual;
                self.generation = self.generation.wrapping_add(1);
            } else if !uncertain {
                self.pending_count = 0;
                self.observed_id = actual;
                self.generation = self.generation.wrapping_add(1);
            }
        }
        self.sample_ns = topology.observed_ns;
        if self.pending_count != 0 && (now < self.pending[0].posted_ns ||
            now - self.pending[0].posted_ns > PREDICTION_TIMEOUT_NS) {
            self.adopt(topology);
            return Err(PlanStatus::EXPIRED);
        }
        if self.pending_count as usize == MAX_PENDING { return Err(PlanStatus::BUSY); }
        let effective = if self.pending_count != 0 {
            self.pending[self.pending_count as usize - 1].target
        } else { actual };
        let index = self.spaces[..count].iter().position(|&id| id == effective)
            .ok_or(PlanStatus::UNKNOWN)?;
        let next = neighbour(index, count, direction).ok_or(PlanStatus::EDGE)?;
        Ok(Plan { target: self.spaces[next], generation: self.generation, direction })
    }

    /// Rejects stale/forged plans, invalid foreign lengths and backwards timestamps.
    pub fn commit(&mut self, plan: &Plan, now: u64) -> bool {
        let count = self.count as usize;
        let pending_count = self.pending_count as usize;
        if plan.target == 0 || self.generation != plan.generation || pending_count >= MAX_PENDING ||
            count == 0 || count > MAX_SPACES || !plan.direction.is_valid() { return false; }
        let origin = if pending_count != 0 { self.pending[pending_count - 1].target } else { self.observed_id };
        let Some(index) = self.spaces[..count].iter().position(|&id| id == origin) else { return false; };
        let Some(next) = neighbour(index, count, plan.direction) else { return false; };
        if self.spaces[next] != plan.target || now < self.sample_ns { return false; }
        self.pending[pending_count] = Pending { target: plan.target, posted_ns: now };
        self.pending_count += 1;
        self.generation = self.generation.wrapping_add(1);
        true
    }
}

fn neighbour(index: usize, count: usize, direction: Direction) -> Option<usize> {
    if direction == Direction::LEFT { index.checked_sub(1) }
    else if direction == Direction::RIGHT && index + 1 < count { Some(index + 1) }
    else { None }
}
