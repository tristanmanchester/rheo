/* SPDX-License-Identifier: MIT */
#import "shortcuts.h"
#include <string.h>
static const CGEventFlags modifiers=kCGEventFlagMaskShift|kCGEventFlagMaskControl|
    kCGEventFlagMaskAlternate|kCGEventFlagMaskCommand;
static CGEventFlags classification_flags(int64_t key) {
    /* macOS can store these implicit flags in arrow shortcut preferences too. */
    return key>=123 && key<=126 ? kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskNumericPad : 0;
}
void sn_read_shortcuts(NSDictionary *preferences,sn_shortcut out[2]) {
    memset(out,0,sizeof(sn_shortcut)*2);
    if (![preferences isKindOfClass:NSDictionary.class]) return;
    NSArray *ids=@[@"79",@"81"];
    for (unsigned i=0;i<2;++i) {
        id entry=preferences[ids[i]];
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"enabled"] isKindOfClass:NSNumber.class] ||
            ![entry[@"enabled"] boolValue]) continue;
        id value=entry[@"value"];
        if (![value isKindOfClass:NSDictionary.class] || ![value[@"type"] isEqual:@"standard"]) continue;
        id params=value[@"parameters"];
        if (![params isKindOfClass:NSArray.class] || [params count]!=3 ||
            ![params[1] isKindOfClass:NSNumber.class] || ![params[2] isKindOfClass:NSNumber.class]) continue;
        int64_t key=[params[1] longLongValue],flags=[params[2] longLongValue];
        if (key<0 || key>127 || flags<0) continue;
        flags&=~classification_flags(key);
        if ((uint64_t)flags & ~modifiers) continue;
        out[i]=(sn_shortcut){true,(CGKeyCode)key,(CGEventFlags)flags,i==0 ? SN_LEFT : SN_RIGHT};
    }
    if (out[0].enabled && out[1].enabled && out[0].key==out[1].key && out[0].modifiers==out[1].modifiers)
        out[0].enabled=out[1].enabled=false;
}
bool sn_shortcuts_held(const sn_shortcut_state *state) {
    for (unsigned i=0;i<SN_SHORTCUT_KEYS;++i) if (state->keys[i].down) return true;
    return false;
}
CGEventRef sn_route_shortcut(sn_shortcut_state *state,const sn_shortcut bindings[2],bool enabled,
    CGEventRef event,CGEventType type,sn_outcome (^attempt)(sn_direction)) {
    if (!event || (type!=kCGEventKeyDown && type!=kCGEventKeyUp) ||
        CGEventGetIntegerValueField(event,kCGEventSourceUserData)==SN_EVENT_MARKER) return event;
    CGKeyCode key=(CGKeyCode)CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
    int64_t pid=CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID);
    bool repeat=CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat)!=0;
    sn_shortcut_press *available=NULL;
    for (unsigned i=0;i<SN_SHORTCUT_KEYS;++i) {
        sn_shortcut_press *press=&state->keys[i];
        if (press->down && press->key==key && press->pid==pid) {
            if (type==kCGEventKeyUp) { press->down=false; return NULL; }
            if (repeat) return NULL; /* One switch per press, including at an edge. */
            press->down=false; /* A fresh press recovers a missed key-up. */
        }
        if (!press->down) available=press;
    }
    if (type!=kCGEventKeyDown || repeat || !enabled || !available) return event;
    /* Arrow events carry Fn/numeric-pad flags even without those modifiers held. */
    CGEventFlags flags=CGEventGetFlags(event)&(modifiers|kCGEventFlagMaskSecondaryFn);
    flags&=~classification_flags(key);
    for (unsigned i=0;i<2;++i) {
        const sn_shortcut *binding=&bindings[i];
        if (!binding->enabled || binding->key!=key || binding->modifiers!=flags) continue;
        sn_outcome outcome=attempt(binding->direction);
        if (outcome!=SN_POSTED && outcome!=SN_EDGE) return event;
        *available=(sn_shortcut_press){true,key,pid};
        return NULL;
    }
    return event;
}
