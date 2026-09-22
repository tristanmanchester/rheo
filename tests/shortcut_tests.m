/* Native regression tests; no input is posted. */
#import "shortcuts.h"
#include <assert.h>
#include <stdio.h>

static NSDictionary *binding(BOOL enabled,int key,unsigned flags) {
    return @{@"enabled":@(enabled),@"value":@{@"type":@"standard",@"parameters":@[@65535,@(key),@(flags)]}};
}
static CGEventRef key(CGEventType type,int code,CGEventFlags flags,int pid,BOOL repeat) {
    CGEventRef event=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)code,type==kCGEventKeyDown);
    assert(event); CGEventSetFlags(event,flags);
    CGEventSetIntegerValueField(event,kCGEventSourceUnixProcessID,pid);
    CGEventSetIntegerValueField(event,kCGKeyboardEventAutorepeat,repeat);
    return event;
}
int main(void) {
    @autoreleasepool {
        sn_shortcut bindings[2]={0};
        sn_read_shortcuts(@{@"79":binding(YES,123,kCGEventFlagMaskControl),
                            @"81":binding(YES,124,kCGEventFlagMaskControl)},bindings);
        assert(bindings[0].enabled && bindings[1].enabled);
        sn_read_shortcuts(@{@"79":binding(YES,123,kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn),
                            @"81":binding(YES,124,kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn)},bindings);
        assert(bindings[0].enabled && bindings[1].enabled);
        assert(bindings[0].modifiers==kCGEventFlagMaskControl);
        sn_shortcut_state state={0};
        __block unsigned attempts=0;
        sn_outcome (^post)(sn_direction)=^sn_outcome(sn_direction direction) {
            assert(direction==SN_LEFT); ++attempts; return SN_POSTED;
        };
        /* Captured mouse utility sequence: Ctrl+Fn+Left down, Fn+Left up. */
        CGEventRef down=key(kCGEventKeyDown,123,kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn,42,NO);
        CGEventRef up=key(kCGEventKeyUp,123,kCGEventFlagMaskSecondaryFn,42,NO);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==NULL);
        assert(attempts==1 && sn_shortcuts_held(&state));
        CGEventSetIntegerValueField(down,kCGKeyboardEventAutorepeat,1);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==NULL && attempts==1);
        /* A different input source cannot release the owned press. */
        CGEventSetIntegerValueField(up,kCGEventSourceUnixProcessID,0);
        assert(sn_route_shortcut(&state,bindings,true,up,kCGEventKeyUp,post)==up);
        CGEventSetIntegerValueField(up,kCGEventSourceUnixProcessID,42);
        assert(sn_route_shortcut(&state,bindings,false,up,kCGEventKeyUp,post)==NULL);
        assert(!sn_shortcuts_held(&state));
        CGEventSetIntegerValueField(down,kCGKeyboardEventAutorepeat,0);
        assert(sn_route_shortcut(&state,bindings,false,down,kCGEventKeyDown,post)==down);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,^sn_outcome(sn_direction d){ (void)d; return SN_FAILED; })==down);
        assert(sn_route_shortcut(&state,bindings,true,up,kCGEventKeyUp,post)==up);
        assert(!sn_shortcuts_held(&state));
        CGEventSetFlags(down,kCGEventFlagMaskControl|kCGEventFlagMaskAlternate);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==down);
        CGEventSetFlags(down,kCGEventFlagMaskControl);
        CGEventSetIntegerValueField(down,kCGEventSourceUserData,SN_EVENT_MARKER);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==down);
        CFRelease(down);
        down=key(kCGEventKeyDown,123,kCGEventFlagMaskControl,0,NO);
        /* Physical keyboards and other utilities follow the same mapping. */
        CGEventSetIntegerValueField(down,kCGEventSourceUnixProcessID,0);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,^sn_outcome(sn_direction d){ (void)d; return SN_EDGE; })==NULL);
        CGEventSetIntegerValueField(up,kCGEventSourceUnixProcessID,0);
        assert(sn_route_shortcut(&state,bindings,true,up,kCGEventKeyUp,post)==NULL);
        /* Rightward routing and a full tracker must not post an unpaired press. */
        CGEventSetIntegerValueField(down,kCGKeyboardEventKeycode,124);
        sn_outcome (^right)(sn_direction)=^sn_outcome(sn_direction d){ assert(d==SN_RIGHT); return SN_POSTED; };
        for (unsigned i=0;i<SN_SHORTCUT_KEYS;++i) {
            CGEventSetIntegerValueField(down,kCGEventSourceUnixProcessID,100+i);
            assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,right)==NULL);
        }
        CGEventSetIntegerValueField(down,kCGEventSourceUnixProcessID,999);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,^sn_outcome(sn_direction d){
            (void)d; assert(!"full tracker must fall back before posting"); return SN_POSTED;
        })==down);
        memset(&state,0,sizeof(state));
        CGEventSetIntegerValueField(down,kCGKeyboardEventKeycode,123);
        /* Disabled, absent, malformed and ambiguous mappings pass through. */
        for (NSDictionary *prefs in @[@{},@{@"79":binding(NO,123,kCGEventFlagMaskControl)},
            @{@"79":@"invalid"},@{@"79":@{@"enabled":@YES,@"value":@{@"parameters":@[]}}},
            @{@"79":binding(YES,-1,kCGEventFlagMaskControl)},
            @{@"79":binding(YES,128,kCGEventFlagMaskControl)},
            @{@"79":binding(YES,12,kCGEventFlagMaskSecondaryFn)},
            @{@"79":binding(YES,123,kCGEventFlagMaskControl),@"81":binding(YES,123,kCGEventFlagMaskControl)}]) {
            sn_read_shortcuts(prefs,bindings);
            assert(!bindings[0].enabled && !bindings[1].enabled);
            assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==down);
        }
        sn_read_shortcuts(@{@"79":binding(YES,12,kCGEventFlagMaskCommand|kCGEventFlagMaskShift)},bindings);
        CGEventSetIntegerValueField(down,kCGKeyboardEventKeycode,12);
        CGEventSetFlags(down,kCGEventFlagMaskCommand|kCGEventFlagMaskShift);
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==NULL);
        /* A new non-repeat down recovers from a missing release. */
        assert(sn_route_shortcut(&state,bindings,true,down,kCGEventKeyDown,post)==NULL);
        CFRelease(down); CFRelease(up);
        puts("PASS: desktop shortcut matching, source pairing, repeats and native fallback");
    }
    return 0;
}
