/* SPDX-License-Identifier: MIT
 * Same inputs, independent C reference state and Rust state, compared by fields
 * rather than padding bytes. tests/reference/c is NEVER linked into the app.
 */
#include "rheo_core.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

sn_action ref_sn_gesture_step(sn_gesture *,const sn_input *,const sn_policy *);
sn_action ref_sn_gesture_feedback(sn_gesture *,sn_outcome,bool,bool);
sn_plan_status ref_sn_prediction_prepare(sn_prediction *,const sn_topology *,uint64_t,sn_direction,sn_plan *);
bool ref_sn_prediction_commit(sn_prediction *,const sn_plan *,uint64_t);
int32_t ref_sn_fixed1616(double);
size_t ref_sn_payload_encode(const sn_payload_input *,uint8_t *,size_t);
bool ref_sn_batch_prepare(sn_batch *,bool,sn_direction,double,sn_create_fn,sn_event_fn,void *);
void ref_sn_batch_post(const sn_batch *,sn_event_fn,void *);
void ref_sn_batch_release(sn_batch *,sn_event_fn,void *);

static uint64_t state=UINT64_C(0x32893654aaf30129);
static uint64_t rnd(void) { state^=state<<13; state^=state>>7; state^=state<<17; return state; }
static double floating(void) {
    uint64_t bits=rnd(); double value; memcpy(&value,&bits,sizeof(value)); return value;
}
static void actions(sn_action a,sn_action b) {
    assert(a.flags==b.flags && a.direction==b.direction && a.terminal==b.terminal);
}
static void gestures(void) {
    sn_gesture rust={0},c={0};
    const sn_phase phases[]={SN_BEGAN,SN_CHANGED,SN_ENDED,SN_CANCELLED,SN_NONE,SN_MAY_BEGIN,(sn_phase)255};
    uint64_t now=1;
    for (unsigned i=0;i<1000000;++i) {
        /* Exercise lifecycle discontinuities as well as normal monotonic input. */
        now+=(rnd()%701==0 ? SN_GESTURE_TIMEOUT_NS+1 : 1);
        sn_input e={(sn_kind)(rnd()%3),phases[rnd()%7],rnd()%17==0,floating(),floating(),now};
        if (rnd()%701==0) e.now_ns=0;
        sn_policy p={rnd()%9!=0,rnd()%7!=0,rnd()%2!=0,rnd()%2 ? 0.0 : floating()};
        sn_action a=sn_gesture_step(&rust,&e,&p),b=ref_sn_gesture_step(&c,&e,&p);
        actions(a,b); assert(rust.owner==c.owner && rust.last_ns==c.last_ns);
        if (a.flags&SN_ATTEMPT) {
            sn_outcome o=(sn_outcome)(rnd()%3);
            actions(sn_gesture_feedback(&rust,o,a.terminal,p.modern),ref_sn_gesture_feedback(&c,o,b.terminal,p.modern));
            assert(rust.owner==c.owner && rust.last_ns==c.last_ns);
        }
    }
    puts("PASS: 1,000,000 differential gesture inputs plus feedback");
}
static void predictions_equal(const sn_prediction *a,const sn_prediction *b) {
    assert(a->display_id==b->display_id && a->count==b->count && a->pending_count==b->pending_count);
    assert(a->observed_id==b->observed_id && a->sample_ns==b->sample_ns && a->generation==b->generation);
    assert(!memcmp(a->spaces,b->spaces,sizeof(a->spaces)));
    /* Compare only active pending entries; unused slots carry no semantic state. */
    for (uint32_t i=0;i<a->pending_count;++i)
        assert(a->pending[i].target==b->pending[i].target && a->pending[i].posted_ns==b->pending[i].posted_ns);
}
static void predictions(void) {
    sn_prediction rust={0},c={0};
    sn_topology t={.display_id=1,.count=5,.current=0,.observed_ns=1};
    for (unsigned j=0;j<SN_MAX_SPACES;++j) t.spaces[j]=j+10;
    uint64_t now=2;
    for (unsigned i=0;i<200000;++i) {
        now+=rnd()%31==0 ? SN_PREDICTION_TIMEOUT_NS+1 : 1;
        if (rnd()%4==0) { t.current=(uint32_t)(rnd()%t.count); t.observed_ns=now; }
        if (rnd()%53==0) { uint64_t tmp=t.spaces[0]; t.spaces[0]=t.spaces[1]; t.spaces[1]=tmp; t.observed_ns=now; }
        if (rnd()%173==0) { t.display_id=(uint32_t)(rnd()%4)+1; t.observed_ns=now; }
        sn_direction d=rnd()%2 ? SN_RIGHT : SN_LEFT;
        sn_plan a={.target=123,.generation=456,.direction=SN_RIGHT},b=a;
        sn_plan_status sa=sn_prediction_prepare(&rust,&t,now,d,&a),sb=ref_sn_prediction_prepare(&c,&t,now,d,&b);
        assert(sa==sb); predictions_equal(&rust,&c);
        assert(a.target==b.target && a.generation==b.generation && a.direction==b.direction);
        if (sa==SN_PLAN_OK && rnd()%4!=0) {
            bool ca=sn_prediction_commit(&rust,&a,now),cb=ref_sn_prediction_commit(&c,&b,now);
            assert(ca==cb); predictions_equal(&rust,&c);
            if (rnd()%7==0) assert(sn_prediction_commit(&rust,&a,now)==ref_sn_prediction_commit(&c,&b,now));
        }
    }
    puts("PASS: 200,000 differential prediction steps with commits");
}
static void payloads(void) {
    const sn_phase phases[]={SN_BEGAN,SN_CHANGED,SN_ENDED,SN_CANCELLED,SN_NONE,SN_MAY_BEGIN,(sn_phase)255};
    for (unsigned i=0;i<100000;++i) {
        sn_payload_input in={.timestamp=rnd(),.phase=phases[rnd()%7],.progress=floating(),
            .position_x=floating(),.position_y=floating(),.velocity_x=rnd()%2 ? 0.0 : floating(),
            .velocity_y=rnd()%2 ? 0.0 : floating(),.swipe_mask=(uint32_t)rnd()};
        uint8_t rust[112],c[112]; memset(rust,0xa5,sizeof(rust)); memset(c,0xa5,sizeof(c));
        size_t cap=rnd()%113;
        assert(sn_payload_encode(&in,rust,cap)==ref_sn_payload_encode(&in,c,cap));
        assert(!memcmp(rust,c,sizeof(rust)));
        assert(sn_fixed1616(in.progress)==ref_sn_fixed1616(in.progress));
    }
    puts("PASS: 100,000 byte-exact payload/fixed-point comparisons");
}
typedef struct { int fail,calls,live,posts; sn_shape shapes[6]; } mock;
static void *create(void *context,const sn_shape *shape) {
    mock *m=context; int i=m->calls++;
    if (i==m->fail) return NULL;
    assert(i<6); m->shapes[i]=*shape; ++m->live; return &m->shapes[i];
}
static void release(void *context,void *event) { (void)event; --((mock *)context)->live; }
static void post(void *context,void *event) { (void)event; ++((mock *)context)->posts; }
static void batches(void) {
    unsigned checked=0;
    for (int modern=0;modern<2;++modern) for (int direction=-1;direction<=1;direction+=2)
        for (int fail=-1;fail<(modern ? 6 : 3);++fail) {
            mock a={.fail=fail},b={.fail=fail}; sn_batch ra={0},rb={0};
            bool ok=sn_batch_prepare(&ra,modern,(sn_direction)direction,2000,create,release,&a);
            assert(ok==ref_sn_batch_prepare(&rb,modern,(sn_direction)direction,2000,create,release,&b));
            assert(a.calls==b.calls && a.live==b.live && a.posts==b.posts && ra.count==rb.count);
            for (size_t j=0;j<ra.count;++j) {
                sn_shape x=a.shapes[j],y=b.shapes[j];
                assert(x.phase==y.phase && x.companion==y.companion && x.modern==y.modern);
                assert(x.progress==y.progress && x.velocity_x==y.velocity_x && x.velocity_y==y.velocity_y);
            }
            sn_batch_post(&ra,post,&a); ref_sn_batch_post(&rb,post,&b);
            assert(a.posts==b.posts);
            sn_batch_release(&ra,release,&a); ref_sn_batch_release(&rb,release,&b);
            assert(!a.live && !b.live && !ra.count && !rb.count); ++checked;
        }
    printf("PASS: %u differential batch success/failure/direction cases\n",checked);
}
int main(void) { gestures(); predictions(); payloads(); batches(); return 0; }
