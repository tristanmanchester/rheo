/* SPDX-License-Identifier: MIT */
#include "strafe_core.h"
#include <string.h>

bool sn_topology_valid(const sn_topology *t) {
    if (!t || !t->display_id || !t->count || t->count>SN_MAX_SPACES || t->current>=t->count)
        return false;
    for (uint32_t i=0; i<t->count; ++i) {
        if (!t->spaces[i]) return false;
        for (uint32_t j=0; j<i; ++j) if (t->spaces[i]==t->spaces[j]) return false;
    }
    return true;
}
void sn_prediction_reset(sn_prediction *p) { memset(p,0,sizeof(*p)); }
static void adopt(sn_prediction *p, const sn_topology *t) {
    p->display_id=t->display_id;
    p->count=t->count;
    memcpy(p->spaces,t->spaces,t->count*sizeof(t->spaces[0]));
    p->observed_id=t->spaces[t->current];
    p->sample_ns=t->observed_ns;
    p->pending_count=0;
    ++p->generation;
}
sn_plan_status sn_prediction_prepare(sn_prediction *p, const sn_topology *t,
                                    uint64_t now, sn_direction d, sn_plan *out) {
    if (!p || !out || (d!=SN_LEFT && d!=SN_RIGHT) || !sn_topology_valid(t) ||
        now<t->observed_ns || now-t->observed_ns>SN_SNAPSHOT_MAX_AGE_NS)
        return SN_PLAN_UNKNOWN;
    if (!p->count) adopt(p,t);
    else if (p->display_id!=t->display_id || p->count!=t->count ||
             memcmp(p->spaces,t->spaces,t->count*sizeof(t->spaces[0]))) {
        bool pending=p->pending_count>0;
        adopt(p,t);
        if (pending) return SN_PLAN_CHANGED;
    }
    if (t->observed_ns<p->sample_ns) return SN_PLAN_UNKNOWN;
    uint64_t actual=t->spaces[t->current];
    if (actual!=p->observed_id) {
        uint32_t acknowledged=0;
        bool uncertain=p->pending_count && t->observed_ns<p->pending[0].posted_ns;
        for (uint32_t i=0; i<p->pending_count; ++i) {
            if (p->pending[i].target==actual) {
                if (t->observed_ns>=p->pending[i].posted_ns) acknowledged=i+1;
                else uncertain=true;
            }
        }
        if (acknowledged) {
            p->pending_count-=acknowledged;
            memmove(p->pending,p->pending+acknowledged,p->pending_count*sizeof(p->pending[0]));
            p->observed_id=actual;
            ++p->generation;
        } else if (!uncertain) {
            p->pending_count=0; /* A genuinely external move; adopt live state. */
            p->observed_id=actual;
            ++p->generation;
        }
        /* A query started before a post can finish after it. Do not misclassify
           that mixed-time sample as an external move and erase pending work. */
    }
    p->sample_ns=t->observed_ns;
    if (p->pending_count && (now<p->pending[0].posted_ns ||
        now-p->pending[0].posted_ns>SN_PREDICTION_TIMEOUT_NS)) {
        adopt(p,t);
        return SN_PLAN_EXPIRED; /* One conservative rejection, not another blind post. */
    }
    if (p->pending_count==SN_MAX_PENDING) return SN_PLAN_BUSY;
    uint64_t effective=p->pending_count ? p->pending[p->pending_count-1].target : actual;
    uint32_t index=0;
    while (index<p->count && p->spaces[index]!=effective) ++index;
    if (index==p->count) return SN_PLAN_UNKNOWN;
    if ((d==SN_LEFT && index==0) || (d==SN_RIGHT && index+1>=p->count))
        return SN_PLAN_EDGE;
    uint32_t target=d==SN_LEFT ? index-1 : index+1;
    *out=(sn_plan){p->spaces[target],p->generation,d};
    return SN_PLAN_OK;
}
bool sn_prediction_commit(sn_prediction *p, const sn_plan *plan, uint64_t now) {
    if (!p || !plan || !plan->target || p->generation!=plan->generation ||
        p->pending_count>=SN_MAX_PENDING) return false;
    if (!p->count || p->count>SN_MAX_SPACES || (plan->direction!=SN_LEFT && plan->direction!=SN_RIGHT))
        return false;
    uint64_t origin=p->pending_count ? p->pending[p->pending_count-1].target : p->observed_id;
    uint32_t index=0;
    while (index<p->count && p->spaces[index]!=origin) ++index;
    if (index==p->count || (plan->direction==SN_LEFT && index==0) ||
        (plan->direction==SN_RIGHT && index+1>=p->count)) return false;
    uint32_t next=plan->direction==SN_LEFT ? index-1 : index+1;
    if (p->spaces[next]!=plan->target || now<p->sample_ns) return false;
    p->pending[p->pending_count++]=(sn_pending){plan->target,now};
    ++p->generation;
    return true;
}
