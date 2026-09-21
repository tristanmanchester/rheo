/* SPDX-License-Identifier: MIT */
#include "strafe_core.h"
#include <float.h>
#include <math.h>
#include <string.h>

void sn_batch_release(sn_batch *b, sn_event_fn release, void *context) {
    for (size_t i=0; i<b->count; ++i) release(context,b->events[i]);
    memset(b,0,sizeof(*b));
}
bool sn_batch_prepare(sn_batch *b, bool modern, sn_direction d, double velocity,
                      sn_create_fn create, sn_event_fn release, void *context) {
    if (!b || !create || !release || (d!=SN_LEFT && d!=SN_RIGHT) ||
        !isfinite(velocity) || velocity<=0 || velocity>32767) return false;
    /* Caller supplies an empty batch. Never silently leak an existing one. */
    if (b->count) return false;
    const sn_phase phases[]={SN_BEGAN,SN_CHANGED,SN_ENDED};
    const double sign=(double)d*(modern ? -1.0 : 1.0);
    for (size_t i=0; i<3; ++i) {
        double v=modern && i!=2 ? 0 : sign*velocity;
        sn_shape shape={phases[i],false,modern,sign*(modern ? 1e-4 : (double)FLT_TRUE_MIN),
                        v,modern ? 0 : v};
        void *event=create(context,&shape);
        if (!event) { sn_batch_release(b,release,context); return false; }
        b->events[b->count++]=event;
        if (modern) {
            shape.companion=true;
            event=create(context,&shape);
            if (!event) { sn_batch_release(b,release,context); return false; }
            b->events[b->count++]=event;
        }
    }
    return true;
}
void sn_batch_post(const sn_batch *b, sn_event_fn post, void *context) {
    for (size_t i=0; i<b->count; ++i) post(context,b->events[i]);
}
