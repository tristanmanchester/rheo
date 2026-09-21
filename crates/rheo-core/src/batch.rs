// SPDX-License-Identifier: MIT
use crate::{Direction, MAX_BATCH, Phase};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Shape {
    pub phase: Phase,
    pub companion: bool,
    pub modern: bool,
    pub progress: f64,
    pub velocity_x: f64,
    pub velocity_y: f64,
}

/// Fully validated legacy/modern event descriptors, held inline.
#[derive(Clone, Debug)]
pub struct Shapes {
    items: [Shape; MAX_BATCH],
    len: usize,
}
impl Shapes {
    pub fn new(modern: bool, direction: Direction, velocity: f64) -> Option<Self> {
        if !direction.is_valid() || !velocity.is_finite() || velocity <= 0.0 || velocity > 32_767.0 {
            return None;
        }
        let mut result = Self { items: [Shape::default(); MAX_BATCH], len: 0 };
        let sign = direction.0 as f64 * if modern { -1.0 } else { 1.0 };
        for phase in [Phase::BEGAN, Phase::CHANGED, Phase::ENDED] {
            let v = if modern && phase != Phase::ENDED { 0.0 } else { sign * velocity };
            let shape = Shape {
                phase, companion: false, modern,
                // Smallest positive f32 subnormal, not f32::MIN_POSITIVE.
                progress: sign * if modern { 1e-4 } else { f32::from_bits(1) as f64 },
                velocity_x: v, velocity_y: if modern { 0.0 } else { v },
            };
            result.items[result.len] = shape;
            result.len += 1;
            if modern {
                result.items[result.len] = Shape { companion: true, ..shape };
                result.len += 1;
            }
        }
        Some(result)
    }
    pub fn as_slice(&self) -> &[Shape] { &self.items[..self.len] }
}

/// Fixed-capacity owning batch. E's destructor releases resources on every early
/// return. There is deliberately no post operation available until preparation
/// has succeeded and returned this value.
#[derive(Debug)]
pub struct PreparedBatch<E> {
    events: [Option<E>; MAX_BATCH],
    len: usize,
}
impl<E> PreparedBatch<E> {
    pub fn prepare(shapes: &Shapes, mut create: impl FnMut(&Shape) -> Option<E>) -> Option<Self> {
        let mut batch = Self { events: core::array::from_fn(|_| None), len: 0 };
        for shape in shapes.as_slice() {
            let event = create(shape)?;
            batch.events[batch.len] = Some(event);
            batch.len += 1;
        }
        Some(batch)
    }
    pub fn len(&self) -> usize { self.len }
    pub fn is_empty(&self) -> bool { self.len == 0 }
    pub fn post(&self, mut post: impl FnMut(&E)) {
        for event in self.events.iter().flatten() { post(event); }
    }
    /// Transfers ownership to the caller. Unconsumed array entries still drop.
    pub fn into_events(self) -> [Option<E>; MAX_BATCH] { self.events }
}
