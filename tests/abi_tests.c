/* SPDX-License-Identifier: MIT -- this must be linked against the Rust library. */
#include "rheo_core.h"
#include <assert.h>
#include <stdio.h>

#define LAYOUT(type,id) do { \
    assert(sn_abi_value(id,0)==sizeof(type)); \
    assert(sn_abi_value(id,1)==_Alignof(type)); \
} while (0)
#define FIELD(type,id,field,slot) assert(sn_abi_value(id,slot)==offsetof(type,field))
int main(void) {
    assert(sn_abi_version()==1);
    LAYOUT(sn_input,0);
    FIELD(sn_input,0,kind,2); FIELD(sn_input,0,phase,3); FIELD(sn_input,0,synthetic,4);
    FIELD(sn_input,0,progress,5); FIELD(sn_input,0,velocity,6); FIELD(sn_input,0,now_ns,7);
    LAYOUT(sn_policy,1); FIELD(sn_policy,1,enabled,2); FIELD(sn_policy,1,ready,3);
    FIELD(sn_policy,1,modern,4); FIELD(sn_policy,1,minimum_progress,5);
    LAYOUT(sn_gesture,2); FIELD(sn_gesture,2,owner,2); FIELD(sn_gesture,2,last_ns,3);
    LAYOUT(sn_action,3); FIELD(sn_action,3,flags,2); FIELD(sn_action,3,direction,3); FIELD(sn_action,3,terminal,4);
    LAYOUT(sn_topology,4); FIELD(sn_topology,4,display_id,2); FIELD(sn_topology,4,count,3);
    FIELD(sn_topology,4,current,4); FIELD(sn_topology,4,observed_ns,5); FIELD(sn_topology,4,spaces,6);
    LAYOUT(sn_pending,5); FIELD(sn_pending,5,target,2); FIELD(sn_pending,5,posted_ns,3);
    LAYOUT(sn_prediction,6); FIELD(sn_prediction,6,display_id,2); FIELD(sn_prediction,6,count,3);
    FIELD(sn_prediction,6,pending_count,4); FIELD(sn_prediction,6,spaces,5); FIELD(sn_prediction,6,observed_id,6);
    FIELD(sn_prediction,6,sample_ns,7); FIELD(sn_prediction,6,generation,8); FIELD(sn_prediction,6,pending,9);
    LAYOUT(sn_plan,7); FIELD(sn_plan,7,target,2); FIELD(sn_plan,7,generation,3); FIELD(sn_plan,7,direction,4);
    LAYOUT(sn_payload_input,8); FIELD(sn_payload_input,8,timestamp,2); FIELD(sn_payload_input,8,phase,3);
    FIELD(sn_payload_input,8,progress,4); FIELD(sn_payload_input,8,position_x,5); FIELD(sn_payload_input,8,position_y,6);
    FIELD(sn_payload_input,8,velocity_x,7); FIELD(sn_payload_input,8,velocity_y,8); FIELD(sn_payload_input,8,swipe_mask,9);
    LAYOUT(sn_shape,9); FIELD(sn_shape,9,phase,2); FIELD(sn_shape,9,companion,3); FIELD(sn_shape,9,modern,4);
    FIELD(sn_shape,9,progress,5); FIELD(sn_shape,9,velocity_x,6); FIELD(sn_shape,9,velocity_y,7);
    LAYOUT(sn_batch,10); FIELD(sn_batch,10,events,2); FIELD(sn_batch,10,count,3);
    assert(sn_abi_value(11,0)==sizeof(sn_direction)); assert(sn_abi_value(11,1)==_Alignof(sn_direction));
    assert(sn_abi_value(11,2)==sizeof(sn_phase)); assert(sn_abi_value(11,3)==_Alignof(sn_phase));
    assert(sn_abi_value(11,4)==sizeof(sn_kind)); assert(sn_abi_value(11,5)==sizeof(sn_owner));
    assert(sn_abi_value(11,6)==sizeof(sn_outcome)); assert(sn_abi_value(11,7)==sizeof(sn_plan_status));
    assert(sn_abi_value(11,8)==SN_MAX_SPACES); assert(sn_abi_value(11,9)==SN_MAX_PENDING);
    assert(sn_abi_value(11,10)==6); assert(sn_abi_value(UINT32_MAX,0)==SIZE_MAX);
    assert(sn_abi_value(0,UINT32_MAX)==SIZE_MAX);
    puts("PASS: all C/Rust struct sizes, alignments, field offsets and enum widths match");
    return 0;
}
