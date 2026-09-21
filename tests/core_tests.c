/* SPDX-License-Identifier: MIT */
#include "rheo_core.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned tests;
#define TEST(fn) do { fn(); ++tests; printf("ok %u - %s\n",tests,#fn); } while (0)
static sn_policy policy={true,true,false,0};
static uint64_t tick=1000;
static sn_action send(sn_gesture *g, sn_kind kind, sn_phase phase, double p, double v) {
    sn_input e={kind,phase,false,p,v,++tick};
    return sn_gesture_step(g,&e,&policy);
}
static void begins(sn_gesture *g) {
    assert(send(g,SN_HORIZONTAL,SN_BEGAN,0,0).flags==(SN_DISCARD|SN_DROP|SN_BUFFER));
}
static void test_one_switch_per_gesture(void) {
    policy=(sn_policy){true,true,false,0};
    sn_gesture g={0}; begins(&g);
    sn_action a=send(&g,SN_HORIZONTAL,SN_CHANGED,0.1,0);
    assert(a.flags&SN_ATTEMPT); assert(a.direction==SN_RIGHT);
    sn_gesture_feedback(&g,SN_POSTED,false,false);
    for (int i=0;i<30;++i) assert(send(&g,SN_HORIZONTAL,SN_CHANGED,-0.2,0).flags==SN_DROP);
    assert(send(&g,SN_HORIZONTAL,SN_ENDED,0,1).flags==(SN_DISCARD|SN_DROP));
    assert(g.owner==SN_IDLE);
}
static void test_native_cancellation_is_not_swallowed(void) {
    sn_gesture g={0}; policy.ready=false;
    assert(send(&g,SN_HORIZONTAL,SN_BEGAN,0,0).flags&SN_PASS);
    assert(send(&g,SN_HORIZONTAL,SN_CANCELLED,0,0).flags==SN_PASS);
    assert(send(&g,SN_HORIZONTAL,SN_CANCELLED,0,0).flags==SN_PASS);
    policy.ready=true;
}
static void test_disable_drains_committed_gesture(void) {
    sn_gesture g={0}; begins(&g);
    sn_gesture_feedback(&g,SN_POSTED,false,false);
    policy.enabled=false;
    assert(send(&g,SN_COMPANION,SN_NONE,0,0).flags==SN_DROP);
    assert(send(&g,SN_HORIZONTAL,SN_ENDED,0,1).flags==(SN_DISCARD|SN_DROP));
    policy.enabled=true;
    assert(send(&g,SN_COMPANION,SN_NONE,0,0).flags==SN_PASS);
}
static void test_disable_replays_pending_gesture(void) {
    sn_gesture g={0}; begins(&g); policy.enabled=false;
    assert(send(&g,SN_HORIZONTAL,SN_CHANGED,0.1,0).flags==(SN_REPLAY|SN_PASS));
    assert(send(&g,SN_HORIZONTAL,SN_ENDED,0,1).flags==SN_PASS);
    policy.enabled=true;
}
static void test_nan_and_infinity_never_choose_direction(void) {
    const double invalid[]={NAN,INFINITY,-INFINITY,0,-0.0};
    for (size_t i=0;i<sizeof(invalid)/sizeof(invalid[0]);++i) {
        sn_gesture g={0}; begins(&g);
        assert(!(send(&g,SN_HORIZONTAL,SN_CHANGED,invalid[i],0).flags&SN_ATTEMPT));
        assert(send(&g,SN_HORIZONTAL,SN_ENDED,0,invalid[i]).flags==(SN_REPLAY|SN_PASS));
    }
}
static void test_minimum_progress_is_optional(void) {
    sn_gesture g={0}; policy.minimum_progress=0.01; begins(&g);
    assert(!(send(&g,SN_HORIZONTAL,SN_CHANGED,0.009,0).flags&SN_ATTEMPT));
    assert(send(&g,SN_HORIZONTAL,SN_CHANGED,0.01,0).flags&SN_ATTEMPT);
    sn_gesture_reset(&g); policy.minimum_progress=0;
    begins(&g); assert(send(&g,SN_HORIZONTAL,SN_CHANGED,DBL_TRUE_MIN,0).flags&SN_ATTEMPT);
}
static void test_direction_inversion_and_terminal_fallback(void) {
    for (int modern=0;modern<2;++modern) for (int sign=-1;sign<=1;sign+=2) {
        policy.modern=modern; sn_gesture g={0}; begins(&g);
        sn_action a=send(&g,SN_HORIZONTAL,SN_ENDED,0,sign);
        assert(a.flags&SN_ATTEMPT); assert(a.terminal);
        assert(a.direction==(modern ? -sign : sign));
        a=sn_gesture_feedback(&g,SN_POSTED,true,modern);
        assert(a.flags==(unsigned)(SN_DISCARD|(modern ? SN_NEUTRAL : SN_DROP)));
        assert(g.owner==SN_IDLE);
    }
    policy.modern=false;
}
static void test_uncommitted_failure_replays_native(void) {
    sn_gesture g={0}; begins(&g);
    assert(send(&g,SN_HORIZONTAL,SN_CHANGED,1,0).flags&SN_ATTEMPT);
    assert(sn_gesture_feedback(&g,SN_FAILED,false,false).flags==(SN_REPLAY|SN_PASS));
    assert(send(&g,SN_HORIZONTAL,SN_CHANGED,1,0).flags==SN_PASS);
    assert(send(&g,SN_HORIZONTAL,SN_ENDED,0,1).flags==SN_PASS);
}
static void test_edges_never_release_moving_terminal(void) {
    sn_gesture g={0}; begins(&g);
    sn_gesture_feedback(&g,SN_EDGE,false,true);
    assert(send(&g,SN_HORIZONTAL,SN_CHANGED,1,0).flags==SN_DROP);
    assert(send(&g,SN_HORIZONTAL,SN_ENDED,1,1).flags==(SN_DISCARD|SN_DROP));
}
static void test_zero_motion_replays_begin_not_just_end(void) {
    sn_gesture g={0}; begins(&g);
    assert(send(&g,SN_HORIZONTAL,SN_CHANGED,0,0).flags==(SN_BUFFER|SN_DROP));
    assert(send(&g,SN_HORIZONTAL,SN_ENDED,0,0).flags==(SN_REPLAY|SN_PASS));
}
static void test_foreign_events_do_not_change_ownership(void) {
    sn_gesture g={0}; begins(&g); sn_gesture before=g;
    sn_input e={SN_HORIZONTAL,SN_ENDED,true,1,1,++tick};
    assert(sn_gesture_step(&g,&e,&policy).flags==SN_PASS);
    assert(!memcmp(&g,&before,sizeof(g)));
    e.synthetic=false; e.kind=SN_OTHER;
    assert(sn_gesture_step(&g,&e,&policy).flags==SN_PASS);
    assert(!memcmp(&g,&before,sizeof(g)));
}
static void test_lost_end_and_clock_regression_recover(void) {
    sn_gesture g={0}; begins(&g);
    sn_input e={SN_COMPANION,SN_NONE,false,0,0,g.last_ns+SN_GESTURE_TIMEOUT_NS+1};
    assert(sn_gesture_step(&g,&e,&policy).flags==(SN_DISCARD|SN_PASS));
    begins(&g); e.now_ns=0;
    assert(sn_gesture_step(&g,&e,&policy).flags==(SN_DISCARD|SN_PASS));
}
static void test_duplicate_begin_is_new_ownership_boundary(void) {
    sn_gesture g={0}; begins(&g); sn_gesture_feedback(&g,SN_POSTED,false,false);
    begins(&g); assert(g.owner==SN_PENDING);
}
static void test_cancelled_owned_gesture_is_closed(void) {
    sn_gesture g={0}; begins(&g);
    assert(send(&g,SN_HORIZONTAL,SN_CANCELLED,0,0).flags==(SN_DISCARD|SN_DROP));
    assert(g.owner==SN_IDLE);
    policy.modern=true; begins(&g); sn_gesture_feedback(&g,SN_POSTED,false,true);
    assert(send(&g,SN_HORIZONTAL,SN_CANCELLED,1,1).flags==(SN_DISCARD|SN_NEUTRAL));
    policy.modern=false;
}
static sn_topology topo(void) {
    return (sn_topology){.display_id=1,.count=5,.current=0,.observed_ns=100,
                         .spaces={10,20,30,40,50}};
}
static void test_topology_rejects_missing_duplicate_or_overflow(void) {
    sn_topology t=topo(); assert(sn_topology_valid(&t));
    t.current=5; assert(!sn_topology_valid(&t));
    t=topo(); t.spaces[2]=0; assert(!sn_topology_valid(&t));
    t=topo(); t.spaces[2]=20; assert(!sn_topology_valid(&t));
    t=topo(); t.count=65; assert(!sn_topology_valid(&t));
    t=topo(); t.count=0; assert(!sn_topology_valid(&t));
}
static void test_predictions_block_both_edges(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan plan;
    assert(sn_prediction_prepare(&p,&t,100,SN_LEFT,&plan)==SN_PLAN_EDGE);
    t.current=4;
    assert(sn_prediction_prepare(&p,&t,100,SN_RIGHT,&plan)==SN_PLAN_EDGE);
}
static void test_pending_targets_survive_intermediate_ack(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan plan;
    for (int i=0;i<3;++i) {
        assert(sn_prediction_prepare(&p,&t,101+i,SN_RIGHT,&plan)==SN_PLAN_OK);
        assert(sn_prediction_commit(&p,&plan,101+i));
    }
    assert(p.pending_count==3);
    t.current=1; t.observed_ns=110;
    assert(sn_prediction_prepare(&p,&t,110,SN_RIGHT,&plan)==SN_PLAN_OK);
    assert(p.pending_count==2); assert(plan.target==50);
    assert(sn_prediction_commit(&p,&plan,111));
    assert(sn_prediction_prepare(&p,&t,112,SN_RIGHT,&plan)==SN_PLAN_EDGE);
}
static void test_post_failure_does_not_advance_prediction(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a,b;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&a)==SN_PLAN_OK);
    assert(sn_prediction_prepare(&p,&t,102,SN_RIGHT,&b)==SN_PLAN_OK);
    assert(a.target==b.target); assert(p.pending_count==0);
}
static void test_duplicate_commit_is_rejected(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&a)==SN_PLAN_OK);
    assert(sn_prediction_commit(&p,&a,101));
    assert(!sn_prediction_commit(&p,&a,102));
}
static void test_topology_reorder_invalidates_pending(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&a)==SN_PLAN_OK);
    assert(sn_prediction_commit(&p,&a,101));
    t.spaces[1]=30; t.spaces[2]=20; t.observed_ns=102;
    assert(sn_prediction_prepare(&p,&t,102,SN_RIGHT,&a)==SN_PLAN_CHANGED);
    assert(!p.pending_count);
    assert(sn_prediction_prepare(&p,&t,103,SN_RIGHT,&a)==SN_PLAN_OK);
    assert(a.target==30);
}
static void test_external_switch_adopts_live_state(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&a)==SN_PLAN_OK);
    assert(sn_prediction_commit(&p,&a,101));
    t.current=3; t.observed_ns=110;
    assert(sn_prediction_prepare(&p,&t,110,SN_LEFT,&a)==SN_PLAN_OK);
    assert(!p.pending_count && a.target==30);
}
static void test_stale_snapshot_is_not_used(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a;
    assert(sn_prediction_prepare(&p,&t,100+SN_SNAPSHOT_MAX_AGE_NS+1,SN_RIGHT,&a)==SN_PLAN_UNKNOWN);
    assert(sn_prediction_prepare(&p,&t,99,SN_RIGHT,&a)==SN_PLAN_UNKNOWN);
}
static void test_expired_unacknowledged_post_is_not_retried_blindly(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&a)==SN_PLAN_OK);
    assert(sn_prediction_commit(&p,&a,101));
    t.observed_ns=102+SN_PREDICTION_TIMEOUT_NS;
    assert(sn_prediction_prepare(&p,&t,t.observed_ns,SN_RIGHT,&a)==SN_PLAN_EXPIRED);
    assert(!p.pending_count);
}
static void test_pending_capacity_is_bounded(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan a;
    for (unsigned i=0;i<SN_MAX_PENDING;++i) {
        sn_direction d=i%2 ? SN_LEFT : SN_RIGHT;
        assert(sn_prediction_prepare(&p,&t,101+i,d,&a)==SN_PLAN_OK);
        assert(sn_prediction_commit(&p,&a,101+i));
    }
    assert(sn_prediction_prepare(&p,&t,120,SN_RIGHT,&a)==SN_PLAN_BUSY);
}
static void test_query_started_before_post_does_not_erase_pending(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan plan;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&plan)==SN_PLAN_OK);
    assert(sn_prediction_commit(&p,&plan,101));
    assert(sn_prediction_prepare(&p,&t,102,SN_RIGHT,&plan)==SN_PLAN_OK);
    assert(sn_prediction_commit(&p,&plan,102));
    t.current=1; /* The query STARTED at 100 but observed a subsequent move. */
    assert(sn_prediction_prepare(&p,&t,110,SN_RIGHT,&plan)==SN_PLAN_OK);
    assert(p.pending_count==2 && plan.target==40);
    t.observed_ns=111;
    assert(sn_prediction_prepare(&p,&t,111,SN_RIGHT,&plan)==SN_PLAN_OK);
    assert(p.pending_count==1 && plan.target==40);
}
static void test_forged_plan_cannot_commit(void) {
    sn_prediction p={0}; sn_topology t=topo(); sn_plan plan;
    assert(sn_prediction_prepare(&p,&t,101,SN_RIGHT,&plan)==SN_PLAN_OK);
    plan.target=50; assert(!sn_prediction_commit(&p,&plan,101));
    plan.target=20; assert(!sn_prediction_commit(&p,&plan,99));
    assert(!p.pending_count);
}
static uint32_t read32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static void test_fixed1616_is_defined_at_extremes(void) {
    assert(sn_fixed1616(NAN)==0 && sn_fixed1616(INFINITY)==0);
    assert(sn_fixed1616(DBL_MAX)==INT32_MAX && sn_fixed1616(-DBL_MAX)==INT32_MIN);
    assert(sn_fixed1616(DBL_TRUE_MIN)==1 && sn_fixed1616(-DBL_TRUE_MIN)==-1);
    assert(sn_fixed1616(1e-4)==6 && sn_fixed1616(-2000)==-131072000);
}
static void test_payload_byte_layout_and_size(void) {
    sn_payload_input p={.timestamp=UINT64_C(0x1122334455667788),.phase=SN_BEGAN,
                        .progress=-1e-4,.position_x=0.1};
    uint8_t bytes[97]; memset(bytes,0xa5,sizeof(bytes));
    assert(sn_payload_encode(&p,bytes,96)==68);
    assert(bytes[0]==0x88 && bytes[7]==0x11);
    assert(read32(bytes+24)==1 && read32(bytes+28)==40 && read32(bytes+32)==23);
    assert(read32(bytes+36)==(1u<<24)); assert((int32_t)read32(bytes+64)==-6);
    assert(bytes[60]==1 && bytes[62]==3 && bytes[68]==0xa5);
    p.phase=SN_ENDED; p.velocity_x=-2000;
    assert(sn_payload_encode(&p,bytes,96)==96);
    assert(read32(bytes+24)==2 && read32(bytes+68)==28 && read32(bytes+72)==9);
    assert(bytes[80]==1 && (int32_t)read32(bytes+84)==-131072000 && bytes[96]==0xa5);
}
static void test_payload_rejects_short_buffers_without_writes(void) {
    sn_payload_input p={.phase=SN_ENDED}; uint8_t bytes[96];
    for (size_t cap=0;cap<96;++cap) {
        memset(bytes,0xa5,sizeof(bytes)); assert(!sn_payload_encode(&p,bytes,cap));
        for (size_t i=0;i<96;++i) assert(bytes[i]==0xa5);
    }
    p.progress=NAN; assert(!sn_payload_encode(&p,bytes,sizeof(bytes)));
    p.progress=0; p.phase=SN_MAY_BEGIN; assert(!sn_payload_encode(&p,bytes,sizeof(bytes)));
}
typedef struct { int calls,live,posts,fail; sn_shape shapes[6]; } mock;
static void *create(void *context,const sn_shape *shape) {
    mock *m=context; int index=m->calls++;
    if (index==m->fail) return NULL;
    m->shapes[index]=*shape; ++m->live;
    return &m->shapes[index];
}
static void release(void *context,void *event) { (void)event; --((mock *)context)->live; }
static void post(void *context,void *event) { (void)event; ++((mock *)context)->posts; }
static void test_prepare_failure_never_posts_partial_gesture(void) {
    for (int modern=0;modern<2;++modern) {
        int n=modern ? 6 : 3;
        for (int fail=0;fail<n;++fail) {
            mock m={.fail=fail}; sn_batch b={0};
            assert(!sn_batch_prepare(&b,modern,SN_RIGHT,2000,create,release,&m));
            assert(m.live==0 && m.posts==0 && b.count==0);
        }
    }
}
static void test_batch_direction_phase_order_and_cleanup(void) {
    for (int modern=0;modern<2;++modern) for (int d=-1;d<=1;d+=2) {
        mock m={.fail=-1}; sn_batch b={0};
        assert(sn_batch_prepare(&b,modern,(sn_direction)d,2000,create,release,&m));
        assert(b.count==(size_t)(modern ? 6 : 3)); assert(m.posts==0);
        for (int i=0;i<3;++i) {
            sn_shape s=m.shapes[i*(modern ? 2 : 1)];
            assert(s.phase==(sn_phase)(1u<<i)); assert(!s.companion);
            assert(s.progress*d*(modern ? -1 : 1)>0);
            assert(s.velocity_x==(modern && i!=2 ? 0 : d*2000*(modern ? -1 : 1)));
            if (modern) assert(m.shapes[i*2+1].companion);
        }
        sn_batch_post(&b,post,&m); assert(m.posts==(int)b.count);
        sn_batch_release(&b,release,&m); assert(!m.live && !b.count);
    }
}
static void test_invalid_batch_parameters_allocate_nothing(void) {
    mock m={.fail=-1}; sn_batch b={0};
    assert(!sn_batch_prepare(&b,false,(sn_direction)0,2000,create,release,&m));
    assert(!sn_batch_prepare(&b,false,SN_RIGHT,NAN,create,release,&m));
    assert(!sn_batch_prepare(&b,false,SN_RIGHT,0,create,release,&m));
    assert(!m.calls);
}
static uint64_t rng=UINT64_C(0x5389ae21922a56c1);
static uint32_t random32(void) {
    rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return (uint32_t)rng;
}
static void test_one_million_adversarial_events(void) {
    sn_gesture g={0}; unsigned commits=0;
    const sn_phase phases[]={SN_BEGAN,SN_CHANGED,SN_ENDED,SN_CANCELLED,SN_NONE,SN_MAY_BEGIN};
    const double values[]={0,1,-1,NAN,INFINITY,-INFINITY,1e-300,-1e-300};
    uint64_t now=1;
    for (unsigned i=0;i<1000000;++i) {
        sn_input e={(sn_kind)(random32()%3),phases[random32()%6],random32()%17==0,
                    values[random32()%8],values[random32()%8],++now};
        sn_policy p={random32()%9!=0,random32()%7!=0,random32()%2!=0,0};
        if (e.kind==SN_HORIZONTAL && e.phase==SN_BEGAN && !e.synthetic) commits=0;
        sn_action a=sn_gesture_step(&g,&e,&p);
        assert(!!(a.flags&SN_PASS)+!!(a.flags&SN_DROP)+!!(a.flags&SN_NEUTRAL)==1);
        if (a.flags&SN_ATTEMPT) {
            assert(g.owner==SN_PENDING && !e.synthetic && e.kind==SN_HORIZONTAL);
            assert(isfinite(a.terminal ? e.velocity : e.progress));
            sn_outcome outcome=(sn_outcome)(random32()%3);
            if (outcome==SN_POSTED) { ++commits; assert(commits==1); }
            sn_gesture_feedback(&g,outcome,a.terminal,p.modern);
        }
    }
}
int main(void) {
    TEST(test_one_switch_per_gesture);
    TEST(test_native_cancellation_is_not_swallowed);
    TEST(test_disable_drains_committed_gesture);
    TEST(test_disable_replays_pending_gesture);
    TEST(test_nan_and_infinity_never_choose_direction);
    TEST(test_minimum_progress_is_optional);
    TEST(test_direction_inversion_and_terminal_fallback);
    TEST(test_uncommitted_failure_replays_native);
    TEST(test_edges_never_release_moving_terminal);
    TEST(test_zero_motion_replays_begin_not_just_end);
    TEST(test_foreign_events_do_not_change_ownership);
    TEST(test_lost_end_and_clock_regression_recover);
    TEST(test_duplicate_begin_is_new_ownership_boundary);
    TEST(test_cancelled_owned_gesture_is_closed);
    TEST(test_topology_rejects_missing_duplicate_or_overflow);
    TEST(test_predictions_block_both_edges);
    TEST(test_pending_targets_survive_intermediate_ack);
    TEST(test_post_failure_does_not_advance_prediction);
    TEST(test_duplicate_commit_is_rejected);
    TEST(test_topology_reorder_invalidates_pending);
    TEST(test_external_switch_adopts_live_state);
    TEST(test_stale_snapshot_is_not_used);
    TEST(test_expired_unacknowledged_post_is_not_retried_blindly);
    TEST(test_pending_capacity_is_bounded);
    TEST(test_query_started_before_post_does_not_erase_pending);
    TEST(test_forged_plan_cannot_commit);
    TEST(test_fixed1616_is_defined_at_extremes);
    TEST(test_payload_byte_layout_and_size);
    TEST(test_payload_rejects_short_buffers_without_writes);
    TEST(test_prepare_failure_never_posts_partial_gesture);
    TEST(test_batch_direction_phase_order_and_cleanup);
    TEST(test_invalid_batch_parameters_allocate_nothing);
    TEST(test_one_million_adversarial_events);
    printf("PASS: %u test groups, including 1,000,000 adversarial events.\n",tests);
    return 0;
}
