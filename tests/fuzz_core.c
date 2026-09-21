/* libFuzzer entry point: ./scripts/fuzz.sh */
#include "rheo_core.h"
#include <assert.h>
#include <math.h>
#include <string.h>
int LLVMFuzzerTestOneInput(const uint8_t *data,size_t size) {
    if (size<20) return 0;
    sn_gesture gesture={0}; sn_policy policy={data[0]&1,data[0]&2,data[0]&4,0};
    uint64_t now=1;
    for (size_t offset=1;offset+19<=size;offset+=19) {
        double progress,velocity; memcpy(&progress,data+offset+3,8); memcpy(&velocity,data+offset+11,8);
        sn_input input={(sn_kind)(data[offset]%3),(sn_phase)data[offset+1],data[offset+2]&1,progress,velocity,++now};
        sn_action a=sn_gesture_step(&gesture,&input,&policy);
        assert(!!(a.flags&SN_PASS)+!!(a.flags&SN_DROP)+!!(a.flags&SN_NEUTRAL)==1);
        if (a.flags&SN_ATTEMPT) {
            assert(isfinite(a.terminal ? velocity : progress));
            sn_gesture_feedback(&gesture,(sn_outcome)(data[offset+2]%3),a.terminal,policy.modern);
        }
        sn_payload_input payload={.phase=input.phase,.progress=progress,.velocity_x=velocity};
        uint8_t output[97]; memset(output,0xa5,sizeof(output));
        size_t n=sn_payload_encode(&payload,output,data[offset]%97);
        assert(n==0 || n==68 || n==96); assert(output[96]==0xa5);
    }
    sn_topology topology={.display_id=1,.count=data[1],.current=data[2],.observed_ns=1};
    for (unsigned i=0;i<SN_MAX_SPACES;++i) topology.spaces[i]=i+1;
    sn_prediction prediction={0}; sn_plan plan;
    sn_plan_status result=sn_prediction_prepare(&prediction,&topology,2,data[0]&1 ? SN_LEFT : SN_RIGHT,&plan);
    if (result==SN_PLAN_OK) assert(sn_prediction_commit(&prediction,&plan,2));
    return 0;
}
