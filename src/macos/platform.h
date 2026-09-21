/* SPDX-License-Identifier: MIT */
#ifndef SN_PLATFORM_H
#define SN_PLATFORM_H
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include "rheo_core.h"
#define SN_MAX_DISPLAYS 16u
#define SN_REPLAY_CAPACITY 32u

typedef enum { SN_OVERLAY_UNKNOWN, SN_OVERLAY_CLEAR, SN_OVERLAY_ACTIVE } sn_overlay;
typedef struct { uint32_t physical_id; CGRect bounds; sn_topology topology; } sn_display;
typedef struct {
    uint64_t observed_ns, generation;
    sn_overlay overlay;
    bool trusted, cgs_available;
    uint32_t display_count;
    sn_display displays[SN_MAX_DISPLAYS];
} sn_snapshot;
uint64_t sn_now_ns(void);
bool sn_snapshot_fresh(const sn_snapshot *, uint64_t now);
const sn_display *sn_display_at_point(const sn_snapshot *, CGPoint);
const sn_display *sn_display_by_id(const sn_snapshot *, uint32_t physical_id);

@interface RheoMonitor : NSObject
- (void)start;
- (void)stop;
- (void)invalidate;
- (BOOL)copySnapshot:(sn_snapshot *)out;
@end

bool sn_prepare_events(sn_batch *, bool modern, sn_direction, CGPoint, CGEventSourceRef);
void sn_release_event(void *context, void *event);
void sn_post_event(void *context, void *event);
void sn_neutralize(CGEventRef);
#endif
