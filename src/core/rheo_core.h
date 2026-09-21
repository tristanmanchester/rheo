/* SPDX-License-Identifier: MIT */
#ifndef RHEO_CORE_H
#define RHEO_CORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Rust implementation: crates/rheo-core + crates/rheo-ffi.
 * ABI tests target 64-bit macOS/Linux, using the default C enum representation.
 * Do NOT compile with -fshort-enums or packing flags.
 *
 * Initialize all state/batches with = {0} or the reset functions. A plan output
 * may be uninitialized; prepare only writes it on SN_PLAN_OK. Pointer arguments
 * must be valid/aligned, mutable state exclusive, and buffers disjoint. Nulls
 * are rejected; dangling pointers and data races cannot be detected here.
 * Callbacks must not unwind/longjmp, re-enter or mutate the active batch, or
 * retain the shape pointer. Never copy a nonempty batch: it owns its handles.
 */
#ifdef __cplusplus
extern "C" {
#endif

#define SN_MAX_SPACES 64u
#define SN_MAX_PENDING 8u
#define SN_SNAPSHOT_MAX_AGE_NS UINT64_C(350000000)
#define SN_PREDICTION_TIMEOUT_NS UINT64_C(700000000)
#define SN_GESTURE_TIMEOUT_NS UINT64_C(2000000000)
#define SN_EVENT_MARKER INT64_C(0x5248454f45565431) /* RHEOEVT1 */
#define SN_EVENT_MASK ((UINT64_C(1) << 29) | (UINT64_C(1) << 30))

typedef enum { SN_LEFT = -1, SN_RIGHT = 1 } sn_direction;
typedef enum { SN_OTHER, SN_COMPANION, SN_HORIZONTAL } sn_kind;
typedef enum { SN_NONE=0, SN_BEGAN=1, SN_CHANGED=2, SN_ENDED=4,
               SN_CANCELLED=8, SN_MAY_BEGIN=128 } sn_phase;
typedef enum { SN_IDLE, SN_NATIVE, SN_PENDING, SN_COMMITTED, SN_BLOCKED } sn_owner;
typedef struct {
    sn_kind kind;
    sn_phase phase;
    bool synthetic;
    double progress, velocity;
    uint64_t now_ns;
} sn_input;
typedef struct {
    bool enabled, ready, modern;
    double minimum_progress; /* 0 preserves first-nonzero triggering. */
} sn_policy;
typedef struct { sn_owner owner; uint64_t last_ns; } sn_gesture;
enum {
    SN_PASS=1u, SN_DROP=2u, SN_BUFFER=4u, SN_ATTEMPT=8u,
    SN_REPLAY=16u, SN_DISCARD=32u, SN_NEUTRAL=64u
};
typedef struct { unsigned flags; sn_direction direction; bool terminal; } sn_action;
typedef enum { SN_POSTED, SN_EDGE, SN_FAILED } sn_outcome;
/* Single-owner API. An ATTEMPT must be immediately followed by feedback. */
sn_action sn_gesture_step(sn_gesture *, const sn_input *, const sn_policy *);
sn_action sn_gesture_feedback(sn_gesture *, sn_outcome, bool terminal, bool modern);
void sn_gesture_reset(sn_gesture *);

typedef struct {
    uint32_t display_id, count, current;
    uint64_t observed_ns;
    uint64_t spaces[SN_MAX_SPACES];
} sn_topology;
typedef struct { uint64_t target, posted_ns; } sn_pending;
typedef struct {
    uint32_t display_id, count, pending_count;
    uint64_t spaces[SN_MAX_SPACES], observed_id, sample_ns, generation;
    sn_pending pending[SN_MAX_PENDING];
} sn_prediction;
typedef enum {
    SN_PLAN_OK, SN_PLAN_EDGE, SN_PLAN_UNKNOWN, SN_PLAN_BUSY,
    SN_PLAN_CHANGED, SN_PLAN_EXPIRED
} sn_plan_status;
typedef struct { uint64_t target, generation; sn_direction direction; } sn_plan;
bool sn_topology_valid(const sn_topology *);
sn_plan_status sn_prediction_prepare(sn_prediction *, const sn_topology *,
                                    uint64_t now_ns, sn_direction, sn_plan *);
bool sn_prediction_commit(sn_prediction *, const sn_plan *, uint64_t now_ns);
void sn_prediction_reset(sn_prediction *);

/* Byte-exact little-endian IOHID encoding, independent of host alignment. */
typedef struct {
    uint64_t timestamp;
    sn_phase phase;
    double progress, position_x, position_y, velocity_x, velocity_y;
    uint32_t swipe_mask;
} sn_payload_input;
int32_t sn_fixed1616(double);
size_t sn_payload_encode(const sn_payload_input *, uint8_t *out, size_t capacity);

typedef struct {
    sn_phase phase;
    bool companion, modern;
    double progress, velocity_x, velocity_y;
} sn_shape;
typedef void *(*sn_create_fn)(void *context, const sn_shape *);
typedef void (*sn_event_fn)(void *context, void *event);
typedef struct { void *events[6]; size_t count; } sn_batch;
/* Prepares EVERY event before any is posted. Failure releases the whole batch. */
bool sn_batch_prepare(sn_batch *, bool modern, sn_direction, double velocity,
                      sn_create_fn, sn_event_fn release, void *context);
void sn_batch_post(const sn_batch *, sn_event_fn post, void *context);
void sn_batch_release(sn_batch *, sn_event_fn release, void *context);
/* Test/diagnostic ABI fingerprint, not used in the event callback. */
uint32_t sn_abi_version(void);
size_t sn_abi_value(uint32_t type_id, uint32_t slot);
#ifdef __cplusplus
}
#endif
#endif
