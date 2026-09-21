/* SPDX-License-Identifier: MIT
 * Private gesture layout: Strafe / InstantSpaceSwitcher / iss; see notices.
 */
#import "platform.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

uint64_t sn_now_ns(void) {
    static mach_timebase_info_data_t base;
    static dispatch_once_t once;
    dispatch_once(&once,^{ mach_timebase_info(&base); });
    return (uint64_t)(((__uint128_t)mach_absolute_time()*base.numer)/base.denom);
}
bool sn_snapshot_fresh(const sn_snapshot *s,uint64_t now) {
    return s->observed_ns && now>=s->observed_ns && now-s->observed_ns<=SN_SNAPSHOT_MAX_AGE_NS;
}
const sn_display *sn_display_at_point(const sn_snapshot *s,CGPoint point) {
    for (uint32_t i=0;i<s->display_count;++i)
        if (CGRectContainsPoint(s->displays[i].bounds,point)) return &s->displays[i];
    return NULL;
}
const sn_display *sn_display_by_id(const sn_snapshot *s,uint32_t id) {
    for (uint32_t i=0;i<s->display_count;++i) if (s->displays[i].physical_id==id) return &s->displays[i];
    return NULL;
}
static bool is_type(CFTypeRef value,CFTypeID type) { return value && CFGetTypeID(value)==type; }
static bool number_u64(CFTypeRef value,uint64_t *out) {
    int64_t v=0;
    if (!is_type(value,CFNumberGetTypeID()) || !CFNumberGetValue(value,kCFNumberSInt64Type,&v) || v<=0)
        return false;
    *out=(uint64_t)v; return true;
}
static sn_overlay read_overlay(void) {
    NSRunningApplication *dock=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
    if (!dock) return SN_OVERLAY_UNKNOWN;
    AXUIElementRef app=AXUIElementCreateApplication(dock.processIdentifier);
    if (!app) return SN_OVERLAY_UNKNOWN;
    AXUIElementSetMessagingTimeout(app,0.02f);
    CFTypeRef value=NULL;
    AXError result=AXUIElementCopyAttributeValue(app,kAXChildrenAttribute,&value);
    CFRelease(app);
    if (result!=kAXErrorSuccess || !is_type(value,CFArrayGetTypeID())) {
        if (value) CFRelease(value);
        return SN_OVERLAY_UNKNOWN;
    }
    CFArrayRef children=(CFArrayRef)value;
    CFIndex n=CFArrayGetCount(children);
    /* Do not mistake a truncated or empty tree for proof that no overlay exists. */
    sn_overlay state=(n>0 && n<=32) ? SN_OVERLAY_CLEAR : SN_OVERLAY_UNKNOWN;
    for (CFIndex i=0;i<n && i<32;++i) {
        AXUIElementRef child=(AXUIElementRef)CFArrayGetValueAtIndex(children,i);
        if (!is_type(child,AXUIElementGetTypeID())) { state=SN_OVERLAY_UNKNOWN; break; }
        AXUIElementSetMessagingTimeout(child,0.005f);
        CFTypeRef identifier=NULL;
        result=AXUIElementCopyAttributeValue(child,kAXIdentifierAttribute,&identifier);
        if (result==kAXErrorSuccess && is_type(identifier,CFStringGetTypeID())) {
            if (CFEqual(identifier,CFSTR("mc")) || CFEqual(identifier,CFSTR("appexpose"))) {
                state=SN_OVERLAY_ACTIVE; CFRelease(identifier); break;
            }
        } else if (result!=kAXErrorAttributeUnsupported && result!=kAXErrorNoValue) {
            state=SN_OVERLAY_UNKNOWN;
        }
        if (identifier) CFRelease(identifier);
    }
    CFRelease(children);
    return state;
}
typedef int32_t (*connection_fn)(void);
typedef CFArrayRef (*spaces_fn)(int32_t,CFStringRef);
static void read_topology(sn_snapshot *snapshot) {
    static connection_fn connection;
    static spaces_fn spaces;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        connection=(connection_fn)dlsym(RTLD_DEFAULT,"CGSMainConnectionID");
        spaces=(spaces_fn)dlsym(RTLD_DEFAULT,"CGSCopyManagedDisplaySpaces");
    });
    snapshot->cgs_available=connection && spaces;
    if (!snapshot->cgs_available) return;
    CFArrayRef managed=spaces(connection(),NULL);
    if (!is_type(managed,CFArrayGetTypeID())) { if (managed) CFRelease(managed); return; }
    CGDirectDisplayID physical[SN_MAX_DISPLAYS]; uint32_t count=0,total=0;
    /* A filled fixed array reports only the number copied, not overflow. */
    if (CGGetActiveDisplayList(0,NULL,&total)!=kCGErrorSuccess || total>SN_MAX_DISPLAYS ||
        CGGetActiveDisplayList(SN_MAX_DISPLAYS,physical,&count)!=kCGErrorSuccess || count!=total) {
        CFRelease(managed); return;
    }
    for (uint32_t i=0;i<count;++i) {
        CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(physical[i]);
        CFStringRef identifier=uuid ? CFUUIDCreateString(NULL,uuid) : NULL;
        if (uuid) CFRelease(uuid);
        CFDictionaryRef match=NULL; bool shared=false;
        for (CFIndex j=0;j<CFArrayGetCount(managed);++j) {
            CFTypeRef candidate=CFArrayGetValueAtIndex(managed,j);
            if (!is_type(candidate,CFDictionaryGetTypeID())) continue;
            CFTypeRef display=CFDictionaryGetValue(candidate,CFSTR("Display Identifier"));
            if (!is_type(display,CFStringGetTypeID())) continue;
            if (identifier && CFEqual(identifier,display)) { match=candidate; break; }
            /* The documented-in-source private "Main" case, NOT arbitrary first-display fallback. */
            if (CFArrayGetCount(managed)==1 && CFEqual(display,CFSTR("Main"))) { match=candidate; shared=true; }
        }
        if (identifier) CFRelease(identifier);
        if (!match) continue;
        CFTypeRef list=CFDictionaryGetValue(match,CFSTR("Spaces"));
        CFTypeRef current=CFDictionaryGetValue(match,CFSTR("Current Space"));
        if (!is_type(list,CFArrayGetTypeID()) || !is_type(current,CFDictionaryGetTypeID())) continue;
        CFIndex n=CFArrayGetCount(list);
        if (n<=0 || n>SN_MAX_SPACES) continue;
        uint64_t active=0;
        if (!number_u64(CFDictionaryGetValue(current,CFSTR("id64")),&active)) continue;
        sn_display d={.physical_id=physical[i],.bounds=CGDisplayBounds(physical[i]),
            .topology={.display_id=shared ? UINT32_MAX : physical[i],.count=(uint32_t)n,
                       .current=UINT32_MAX,.observed_ns=snapshot->observed_ns}};
        bool valid=true;
        for (CFIndex j=0;j<n;++j) {
            CFTypeRef item=CFArrayGetValueAtIndex(list,j);
            if (!is_type(item,CFDictionaryGetTypeID()) ||
                !number_u64(CFDictionaryGetValue(item,CFSTR("id64")),&d.topology.spaces[j])) { valid=false; break; }
            if (d.topology.spaces[j]==active) d.topology.current=(uint32_t)j;
        }
        if (valid && sn_topology_valid(&d.topology)) snapshot->displays[snapshot->display_count++]=d;
    }
    CFRelease(managed);
}

@implementation RheoMonitor {
    pthread_mutex_t _lock;
    sn_snapshot _snapshot;
    uint64_t _generation;
    atomic_bool _stopped;
    atomic_bool _queued;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
}
- (instancetype)init {
    if ((self=[super init])) {
        pthread_mutex_init(&_lock,NULL);
        atomic_init(&_stopped,true); atomic_init(&_queued,false);
        _queue=dispatch_queue_create("dev.rheo.monitor",DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)refresh {
    if (atomic_load(&_stopped) || atomic_exchange(&_queued,true)) return;
    dispatch_async(_queue,^{ @autoreleasepool {
        pthread_mutex_lock(&self->_lock); uint64_t generation=self->_generation; pthread_mutex_unlock(&self->_lock);
        sn_snapshot next={.observed_ns=sn_now_ns(),.generation=generation};
        next.trusted=AXIsProcessTrusted();
        if (next.trusted) { read_topology(&next); next.overlay=read_overlay(); }
        pthread_mutex_lock(&self->_lock);
        if (!atomic_load(&self->_stopped) && generation==self->_generation) self->_snapshot=next;
        pthread_mutex_unlock(&self->_lock);
        atomic_store(&self->_queued,false);
    }});
}
- (void)start {
    if (!atomic_exchange(&_stopped,false)) return;
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    dispatch_source_set_timer(_timer,DISPATCH_TIME_NOW,100*NSEC_PER_MSEC,15*NSEC_PER_MSEC);
    __weak RheoMonitor *weakSelf=self;
    dispatch_source_set_event_handler(_timer,^{ [weakSelf refresh]; });
    dispatch_resume(_timer);
}
- (void)stop {
    atomic_store(&_stopped,true);
    if (_timer) { dispatch_source_cancel(_timer); _timer=nil; }
    [self invalidate];
}
- (void)invalidate {
    pthread_mutex_lock(&_lock); ++_generation; memset(&_snapshot,0,sizeof(_snapshot)); pthread_mutex_unlock(&_lock);
    [self refresh];
}
- (BOOL)copySnapshot:(sn_snapshot *)out {
    if (pthread_mutex_trylock(&_lock)) return NO; /* Never wait inside the tap. */
    *out=_snapshot;
    pthread_mutex_unlock(&_lock);
    return YES;
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    pthread_mutex_destroy(&_lock);
}
@end

/* No application-level heap buffers in the encoder. CoreGraphics still allocates. */
static CGEventRef augment(CGEventRef event,const sn_shape *shape) {
    CFDataRef original=CGEventCreateData(NULL,event);
    if (!original) return NULL;
    CFIndex n=CFDataGetLength(original);
    const UInt8 *bytes=CFDataGetBytePtr(original);
    if (n<4 || n>65536 || memcmp(bytes,"\0\0\0\2",4)) { CFRelease(original); return NULL; }
    sn_payload_input in={.timestamp=CGEventGetTimestamp(event),.phase=shape->phase,
        .progress=shape->progress,.position_x=0.1,.velocity_x=shape->velocity_x,.velocity_y=shape->velocity_y};
    uint8_t record[100]; size_t size=sn_payload_encode(&in,record+4,sizeof(record)-4);
    if (!size) { CFRelease(original); return NULL; }
    record[0]=(uint8_t)(size>>8); record[1]=(uint8_t)size; record[2]=0x10; record[3]=0x6d;
    CFMutableDataRef combined=CFDataCreateMutable(NULL,n+(CFIndex)size+4);
    if (!combined) { CFRelease(original); return NULL; }
    CFDataAppendBytes(combined,bytes,n); CFDataAppendBytes(combined,record,(CFIndex)size+4);
    CFRelease(original);
    CGEventRef result=CGEventCreateFromData(NULL,combined);
    CFRelease(combined); return result;
}
typedef struct { CGPoint point; CGEventSourceRef source; } create_context;
static void *create_event(void *context,const sn_shape *s) {
    create_context *c=context;
    CGEventRef event=CGEventCreate(c->source);
    if (!event) return NULL;
    CGEventSetTimestamp(event,sn_now_ns());
    CGEventSetLocation(event,c->point);
    CGEventSetIntegerValueField(event,kCGEventSourceUserData,SN_EVENT_MARKER);
    CGEventSetIntegerValueField(event,kCGEventSourceUnixProcessID,getpid());
    CGEventSetType(event,(CGEventType)(s->companion ? 29 : 30));
    CGEventSetIntegerValueField(event,(CGEventField)55,s->companion ? 29 : 30);
    if (s->companion) return event;
    CGEventSetIntegerValueField(event,(CGEventField)110,23);
    CGEventSetIntegerValueField(event,(CGEventField)123,1);
    CGEventSetIntegerValueField(event,(CGEventField)132,s->phase);
    CGEventSetDoubleValueField(event,(CGEventField)124,s->progress);
    CGEventSetDoubleValueField(event,(CGEventField)129,s->velocity_x);
    CGEventSetDoubleValueField(event,(CGEventField)130,s->velocity_y);
    if (s->modern) {
        CGEventSetIntegerValueField(event,(CGEventField)134,s->phase);
        CGEventSetDoubleValueField(event,(CGEventField)138,3.0);
        CGEventSetDoubleValueField(event,(CGEventField)125,0.1);
        CGEventRef replacement=augment(event,s); CFRelease(event); event=replacement;
    }
    return event;
}
void sn_release_event(void *context,void *event) { (void)context; CFRelease(event); }
void sn_post_event(void *context,void *event) { (void)context; CGEventPost(kCGSessionEventTap,event); }
bool sn_prepare_events(sn_batch *batch,bool modern,sn_direction direction,CGPoint point,CGEventSourceRef source) {
    create_context context={point,source};
    return sn_batch_prepare(batch,modern,direction,2000,create_event,sn_release_event,&context);
}
void sn_neutralize(CGEventRef event) {
    /* Same real-terminal workaround as upstream; private IOHID/native-Dock behavior needs hardware tests. */
    CGEventSetDoubleValueField(event,(CGEventField)124,0);
    CGEventSetDoubleValueField(event,(CGEventField)129,0);
    CGEventSetDoubleValueField(event,(CGEventField)130,0);
}
