/* Native no-input smoke tests. These require Apple's SDK/CoreGraphics, not AX permission. */
#import "platform.h"
#include <assert.h>
#include <stdio.h>
/* Accidental real posting makes the test fail instead of touching the desktop. */
void CGEventPost(CGEventTapLocation location,CGEventRef event) {
    (void)location; (void)event; assert(!"platform tests must never post input");
}
int main(void) {
    @autoreleasepool {
        sn_snapshot s={.observed_ns=100,.display_count=1,
            .displays={{.physical_id=9,.bounds={{0,0},{200,200}}}}};
        assert(sn_snapshot_fresh(&s,101));
        assert(!sn_snapshot_fresh(&s,99));
        assert(sn_display_at_point(&s,CGPointMake(10,10))->physical_id==9);
        assert(!sn_display_at_point(&s,CGPointMake(-1,10)));
        assert(sn_display_by_id(&s,9) && !sn_display_by_id(&s,10));
        CGEventSourceRef source=CGEventSourceCreate(kCGEventSourceStatePrivate); assert(source);
        NSInteger major=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        for (int modern=0;modern<2;++modern) {
            if (modern && major!=27) { puts("SKIP: native macOS 27 payload roundtrip requires macOS 27"); continue; }
            for (int direction=-1;direction<=1;direction+=2) {
                sn_batch batch={0};
                assert(sn_prepare_events(&batch,modern,(sn_direction)direction,CGPointMake(10,10),source));
                assert(batch.count==(size_t)(modern ? 6 : 3));
                for (size_t i=0;i<batch.count;++i) {
                    CGEventRef event=batch.events[i];
                    assert(CGEventGetIntegerValueField(event,kCGEventSourceUserData)==SN_EVENT_MARKER);
                    assert(CGEventGetType(event)==(CGEventType)(modern && i%2 ? 29 : 30));
                    assert(CGEventGetLocation(event).x==10);
                }
                sn_batch_release(&batch,sn_release_event,NULL);
            }
        }
        CFRelease(source); puts("PASS: native geometry and prepared-event smoke tests (no events posted)");
    }
    return 0;
}
