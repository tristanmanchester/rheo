/* SPDX-License-Identifier: MIT */
#ifndef RHEO_SHORTCUTS_H
#define RHEO_SHORTCUTS_H
#import "platform.h"
#define SN_SHORTCUT_KEYS 8u

typedef struct { bool enabled; CGKeyCode key; CGEventFlags modifiers; sn_direction direction; } sn_shortcut;
typedef struct { bool down; CGKeyCode key; int64_t pid; } sn_shortcut_press;
typedef struct { sn_shortcut_press keys[SN_SHORTCUT_KEYS]; } sn_shortcut_state;
/* Only explicitly configured, enabled desktop shortcuts are eligible. */
void sn_read_shortcuts(NSDictionary *preferences,sn_shortcut out[2]);
bool sn_shortcuts_held(const sn_shortcut_state *);
/* Called on the event thread. Failure passes the untouched native event through. */
CGEventRef sn_route_shortcut(sn_shortcut_state *,const sn_shortcut bindings[2],bool enabled,
    CGEventRef,CGEventType,sn_outcome (^attempt)(sn_direction));
#endif
