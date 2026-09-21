/* SPDX-License-Identifier: MIT */
#include "strafe_core.h"
#include <math.h>

static sn_action action(unsigned flags) {
    return (sn_action){ .flags=flags, .direction=SN_RIGHT };
}
void sn_gesture_reset(sn_gesture *g) { *g=(sn_gesture){0}; }
static bool owned(const sn_gesture *g) { return g->owner>=SN_PENDING; }
static bool direction(double value, double threshold, bool modern, sn_direction *d) {
    if (!isfinite(value) || value==0 || fabs(value)<threshold) return false;
    *d=((value>0) != modern) ? SN_RIGHT : SN_LEFT;
    return true;
}
sn_action sn_gesture_step(sn_gesture *g, const sn_input *e, const sn_policy *p) {
    if (e->synthetic || e->kind==SN_OTHER) return action(SN_PASS);
    unsigned prefix=0;
    if (g->owner!=SN_IDLE && (e->now_ns<g->last_ns ||
        e->now_ns-g->last_ns>SN_GESTURE_TIMEOUT_NS)) {
        /* Never replay an incomplete gesture after a clock/lifecycle discontinuity. */
        sn_gesture_reset(g); prefix=SN_DISCARD;
    }
    g->last_ns=e->now_ns;
    if (e->kind==SN_HORIZONTAL && e->phase==SN_BEGAN) {
        g->owner=(p->enabled && p->ready) ? SN_PENDING : SN_NATIVE;
        return action(prefix|SN_DISCARD|(g->owner==SN_PENDING ? SN_DROP|SN_BUFFER : SN_PASS));
    }
    if (!p->enabled && g->owner==SN_PENDING) {
        g->owner=SN_NATIVE;
        prefix|=SN_REPLAY;
    }
    if (e->kind==SN_COMPANION) {
        return action(prefix|(g->owner==SN_PENDING ? SN_DROP|SN_BUFFER :
                              owned(g) ? SN_DROP : SN_PASS));
    }
    const bool end=e->phase==SN_ENDED || e->phase==SN_CANCELLED;
    if (!owned(g)) {
        if (end) g->owner=SN_IDLE;
        return action(prefix|SN_PASS);
    }
    if (e->phase==SN_CANCELLED) {
        bool neutral=g->owner==SN_COMMITTED && p->modern;
        g->owner=SN_IDLE;
        return action(prefix|SN_DISCARD|(neutral ? SN_NEUTRAL : SN_DROP));
    }
    if (g->owner==SN_PENDING && (e->phase==SN_CHANGED || e->phase==SN_ENDED)) {
        sn_direction d;
        double value=end ? e->velocity : e->progress;
        double threshold=end ? 0 : p->minimum_progress;
        if (!isfinite(threshold) || threshold<0) threshold=0;
        if (direction(value,threshold,p->modern,&d)) {
            return (sn_action){prefix|SN_DROP|SN_ATTEMPT,d,end};
        }
        if (end) {
            g->owner=SN_IDLE;
            return action(prefix|SN_REPLAY|SN_PASS);
        }
        return action(prefix|SN_DROP|SN_BUFFER);
    }
    if (end) {
        bool neutral=g->owner==SN_COMMITTED && p->modern;
        g->owner=SN_IDLE;
        return action(prefix|SN_DISCARD|(neutral ? SN_NEUTRAL : SN_DROP));
    }
    return action(prefix|SN_DROP|(g->owner==SN_PENDING ? SN_BUFFER : 0));
}
sn_action sn_gesture_feedback(sn_gesture *g, sn_outcome outcome, bool terminal, bool modern) {
    if (outcome==SN_FAILED) {
        g->owner=terminal ? SN_IDLE : SN_NATIVE;
        return action(SN_REPLAY|SN_PASS);
    }
    if (outcome==SN_EDGE) {
        g->owner=terminal ? SN_IDLE : SN_BLOCKED;
        return action(SN_DISCARD|SN_DROP);
    }
    g->owner=terminal ? SN_IDLE : SN_COMMITTED;
    return action(SN_DISCARD|((terminal && modern) ? SN_NEUTRAL : SN_DROP));
}
