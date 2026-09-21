/* SPDX-License-Identifier: MIT
 * IOHID layout derived from Strafe / joshuarli/iss. See THIRD_PARTY_NOTICES.md.
 */
#include "strafe_core.h"
#include <limits.h>
#include <math.h>
#include <string.h>

static void le16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void le32(uint8_t *p, uint32_t v) {
    for (unsigned i=0;i<4;++i) p[i]=(uint8_t)(v>>(8*i));
}
static void le64(uint8_t *p, uint64_t v) {
    for (unsigned i=0;i<8;++i) p[i]=(uint8_t)(v>>(8*i));
}
int32_t sn_fixed1616(double v) {
    if (!isfinite(v)) return 0;
    double scaled=v*65536.0;
    if (scaled>=INT32_MAX) return INT32_MAX;
    if (scaled<=INT32_MIN) return INT32_MIN;
    int32_t result=(int32_t)scaled;
    return result==0 && v!=0 ? (v>0 ? 1 : -1) : result;
}
size_t sn_payload_encode(const sn_payload_input *in, uint8_t *out, size_t capacity) {
    if (!in || !out || (in->phase!=SN_BEGAN && in->phase!=SN_CHANGED &&
        in->phase!=SN_ENDED && in->phase!=SN_CANCELLED) ||
        !isfinite(in->progress) || !isfinite(in->position_x) ||
        !isfinite(in->position_y) || !isfinite(in->velocity_x) || !isfinite(in->velocity_y)) return 0;
    bool velocity=in->phase==SN_ENDED || in->velocity_x!=0 || in->velocity_y!=0;
    size_t length=velocity ? 96 : 68;
    if (capacity<length) return 0;
    memset(out,0,length);
    le64(out,in->timestamp); le32(out+24,velocity ? 2 : 1);
    le32(out+28,40); le32(out+32,23); le32(out+36,(uint32_t)in->phase<<24);
    le32(out+44,(uint32_t)sn_fixed1616(in->position_x));
    le32(out+48,(uint32_t)sn_fixed1616(in->position_y));
    le32(out+56,in->swipe_mask); le16(out+60,1); le16(out+62,3);
    le32(out+64,(uint32_t)sn_fixed1616(in->progress));
    if (velocity) {
        le32(out+68,28); le32(out+72,9); out[80]=1;
        le32(out+84,(uint32_t)sn_fixed1616(in->velocity_x));
        le32(out+88,(uint32_t)sn_fixed1616(in->velocity_y));
    }
    return length;
}
