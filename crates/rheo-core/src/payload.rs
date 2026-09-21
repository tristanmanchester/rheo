// SPDX-License-Identifier: MIT
// IOHID layout derived from Strafe / joshuarli/iss. See THIRD_PARTY_NOTICES.md.
use crate::Phase;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PayloadInput {
    pub timestamp: u64,
    pub phase: Phase,
    pub progress: f64,
    pub position_x: f64,
    pub position_y: f64,
    pub velocity_x: f64,
    pub velocity_y: f64,
    pub swipe_mask: u32,
}

/// Saturating, truncating conversion with a one-unit floor for nonzero motion.
/// NaN/infinity map to zero; multiplication overflow saturates rather than panics.
pub fn fixed1616(value: f64) -> i32 {
    if !value.is_finite() { return 0; }
    let scaled = value * 65_536.0;
    if scaled >= i32::MAX as f64 { return i32::MAX; }
    if scaled <= i32::MIN as f64 { return i32::MIN; }
    let result = scaled as i32;
    if result == 0 && value != 0.0 { if value > 0.0 { 1 } else { -1 } } else { result }
}

/// Returns 68/96 bytes, or zero with the ENTIRE output untouched on invalid input.
/// Uses slices and explicit little-endian writes; no pointer casts or heap buffers.
pub fn encode_payload(input: &PayloadInput, output: &mut [u8]) -> usize {
    if !input.phase.is_payload_phase() || !input.progress.is_finite() ||
        !input.position_x.is_finite() || !input.position_y.is_finite() ||
        !input.velocity_x.is_finite() || !input.velocity_y.is_finite() { return 0; }
    let velocity = input.phase == Phase::ENDED || input.velocity_x != 0.0 || input.velocity_y != 0.0;
    let length = if velocity { 96 } else { 68 };
    let Some(out) = output.get_mut(..length) else { return 0; };
    out.fill(0);
    out[..8].copy_from_slice(&input.timestamp.to_le_bytes());
    put32(out, 24, if velocity { 2 } else { 1 });
    put32(out, 28, 40);
    put32(out, 32, 23);
    put32(out, 36, input.phase.0 << 24);
    put32(out, 44, fixed1616(input.position_x) as u32);
    put32(out, 48, fixed1616(input.position_y) as u32);
    put32(out, 56, input.swipe_mask);
    out[60..62].copy_from_slice(&1u16.to_le_bytes());
    out[62..64].copy_from_slice(&3u16.to_le_bytes());
    put32(out, 64, fixed1616(input.progress) as u32);
    if velocity {
        put32(out, 68, 28);
        put32(out, 72, 9);
        out[80] = 1;
        put32(out, 84, fixed1616(input.velocity_x) as u32);
        put32(out, 88, fixed1616(input.velocity_y) as u32);
    }
    length
}
fn put32(out: &mut [u8], offset: usize, value: u32) {
    out[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}
