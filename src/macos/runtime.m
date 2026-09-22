/* SPDX-License-Identifier: MIT */
#import "runtime.h"
#import "shortcuts.h"
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

@interface RheoRuntime ()
- (void)run;
- (void)health;
- (sn_outcome)switchAtPointer:(sn_direction)direction;
- (CGEventRef)handle:(CGEventRef)event type:(CGEventType)type proxy:(CGEventTapProxy)proxy;
@end
static void *thread_entry(void *context) {
    @autoreleasepool { RheoRuntime *runtime=CFBridgingRelease(context); [runtime run]; }
    return NULL;
}
static CGEventRef tap_callback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *info) {
    return [(__bridge RheoRuntime *)info handle:event type:type proxy:proxy];
}
static void health_callback(CFRunLoopTimerRef timer,void *info) {
    (void)timer; [(__bridge RheoRuntime *)info health];
}

@implementation RheoRuntime {
    RheoMonitor *_monitor;
    pthread_t _thread;
    BOOL _started, _supported, _modern;
    dispatch_semaphore_t _ready;
    CFRunLoopRef _loop;
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    CFRunLoopTimerRef _healthTimer;
    CGEventSourceRef _eventSource;
    CGEventMask _tapMask;
    sn_shortcut _shortcuts[2];
    sn_shortcut_state _shortcutState;
    sn_gesture _gesture;
    sn_prediction _predictions[SN_MAX_DISPLAYS];
    CGEventRef _buffer[SN_REPLAY_CAPACITY];
    size_t _bufferCount;
    CGPoint _gesturePoint;
    uint32_t _physicalDisplay;
    uint64_t _environmentGeneration;
    atomic_bool _enabled, _tapRunning, _trusted, _commandPending;
    atomic_bool _desktopShortcuts;
    atomic_uint _shortcutCount;
    atomic_uint_fast64_t _posted, _edge, _failed, _replayed, _bufferFallbacks, _recoveries, _maximumCallbackNs;
}
- (instancetype)initWithEnabled:(BOOL)enabled {
    if ((self=[super init])) {
        _monitor=[RheoMonitor new]; _ready=dispatch_semaphore_create(0);
        NSInteger major=NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        _supported=major>=15 && major<=27; _modern=major==27;
        atomic_init(&_enabled,enabled); atomic_init(&_tapRunning,false);
        atomic_init(&_trusted,false); atomic_init(&_commandPending,false);
        atomic_init(&_desktopShortcuts,false); atomic_init(&_shortcutCount,0);
        atomic_init(&_posted,0); atomic_init(&_edge,0); atomic_init(&_failed,0);
        atomic_init(&_replayed,0); atomic_init(&_bufferFallbacks,0); atomic_init(&_recoveries,0);
        atomic_init(&_maximumCallbackNs,0);
    }
    return self;
}
- (BOOL)start {
    if (_started) return YES;
    [_monitor start];
    void *context=(__bridge_retained void *)self;
    if (pthread_create(&_thread,NULL,thread_entry,context)) {
        (void)CFBridgingRelease(context); [_monitor stop]; return NO;
    }
    /* The worker publishes the run loop before doing any AX/WindowServer work. */
    dispatch_semaphore_wait(_ready,DISPATCH_TIME_FOREVER);
    _started=YES; return YES;
}
- (void)discardBuffer {
    for (size_t i=0;i<_bufferCount;++i) CFRelease(_buffer[i]);
    _bufferCount=0;
}
- (void)replayBuffer:(CGEventTapProxy)proxy {
    if (_bufferCount) atomic_fetch_add(&_replayed,1);
    for (size_t i=0;i<_bufferCount;++i) {
        CGEventSetIntegerValueField(_buffer[i],kCGEventSourceUserData,SN_EVENT_MARKER);
        if (proxy) CGEventTapPostEvent(proxy,_buffer[i]);
        else CGEventPost(kCGSessionEventTap,_buffer[i]);
        CFRelease(_buffer[i]);
    }
    _bufferCount=0;
}
- (void)removeTap {
    if (_tap) { CGEventTapEnable(_tap,false); CFMachPortInvalidate(_tap); }
    if (_tapSource) { CFRunLoopRemoveSource(_loop,_tapSource,kCFRunLoopCommonModes); CFRelease(_tapSource); _tapSource=NULL; }
    if (_tap) { CFRelease(_tap); _tap=NULL; }
    atomic_store(&_tapRunning,false);
}
- (void)run {
    pthread_setname_np("Rheo event tap");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    _loop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    CFRunLoopTimerContext context={0,(__bridge void *)self,NULL,NULL,NULL};
    _healthTimer=CFRunLoopTimerCreate(NULL,CFAbsoluteTimeGetCurrent(),1.0,0,0,health_callback,&context);
    CFRunLoopAddTimer(_loop,_healthTimer,kCFRunLoopCommonModes);
    dispatch_semaphore_signal(_ready);
    _eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);
    CFRunLoopRun();
    /* Pending uncommitted events can still be handed back while exiting. */
    if (_gesture.owner==SN_PENDING) [self replayBuffer:NULL]; else [self discardBuffer];
    [self removeTap];
    if (_eventSource) { CFRelease(_eventSource); _eventSource=NULL; }
    CFRunLoopTimerInvalidate(_healthTimer); CFRelease(_healthTimer); _healthTimer=NULL;
    CFRelease(_loop); /* Main thread clears the published pointer after join. */
}
- (void)stop {
    if (!_started) return;
    CFRunLoopRef loop=_loop;
    CFRunLoopPerformBlock(loop,kCFRunLoopCommonModes,^{ CFRunLoopStop(loop); });
    CFRunLoopWakeUp(loop);
    pthread_join(_thread,NULL);
    _loop=NULL; _started=NO;
    [_monitor stop];
}
- (void)health {
    @autoreleasepool {
        BOOL trusted=AXIsProcessTrusted(); atomic_store(&_trusted,trusted);
        if (!_supported || !trusted) {
            [self removeTap]; [self discardBuffer]; sn_gesture_reset(&_gesture);
            memset(&_shortcutState,0,sizeof(_shortcutState));
            memset(_predictions,0,sizeof(_predictions)); return;
        }
        uint64_t now=sn_now_ns();
        if (_gesture.owner!=SN_IDLE && (now<_gesture.last_ns || now-_gesture.last_ns>SN_GESTURE_TIMEOUT_NS)) {
            [self discardBuffer]; sn_gesture_reset(&_gesture);
        }
        BOOL shortcuts=atomic_load(&_desktopShortcuts);
        if (shortcuts) {
            CFPreferencesAppSynchronize(CFSTR("com.apple.symbolichotkeys"));
            NSDictionary *prefs=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AppleSymbolicHotKeys"),
                CFSTR("com.apple.symbolichotkeys")));
            sn_read_shortcuts(prefs,_shortcuts);
            atomic_store(&_shortcutCount,(unsigned)_shortcuts[0].enabled+(unsigned)_shortcuts[1].enabled);
        }
        BOOL keys=shortcuts || sn_shortcuts_held(&_shortcutState);
        CGEventMask mask=SN_EVENT_MASK | (keys ? CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp) : 0);
        BOOL wanted=atomic_load(&_enabled) || _gesture.owner>=SN_PENDING || keys;
        if (!wanted) {
            if (_tap) CGEventTapEnable(_tap,false);
            atomic_store(&_tapRunning,false); return;
        }
        if (_tap && !CFMachPortIsValid(_tap)) [self removeTap];
        if (_tap && _tapMask!=mask && _gesture.owner==SN_IDLE) [self removeTap];
        if (!_tap) {
            _tap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,
                mask,tap_callback,(__bridge void *)self);
            _tapMask=mask;
            if (_tap) {
                _tapSource=CFMachPortCreateRunLoopSource(NULL,_tap,0);
                if (_tapSource) CFRunLoopAddSource(_loop,_tapSource,kCFRunLoopCommonModes);
                else [self removeTap];
            }
        }
        if (_tap && !CGEventTapIsEnabled(_tap)) CGEventTapEnable(_tap,true);
        atomic_store(&_tapRunning,_tap && CGEventTapIsEnabled(_tap));
    }
}
- (void)setEnabled:(BOOL)enabled {
    atomic_store(&_enabled,enabled);
    if (_started) {
        CFRunLoopPerformBlock(_loop,kCFRunLoopCommonModes,^{ [self health]; });
        CFRunLoopWakeUp(_loop);
    }
}
- (void)setDesktopShortcutsEnabled:(BOOL)enabled {
    atomic_store(&_desktopShortcuts,enabled);
    if (_started) {
        CFRunLoopPerformBlock(_loop,kCFRunLoopCommonModes,^{ [self health]; });
        CFRunLoopWakeUp(_loop);
    }
}
- (void)refreshEnvironment { [_monitor invalidate]; }
- (sn_prediction *)predictionFor:(uint32_t)display {
    for (unsigned i=0;i<SN_MAX_DISPLAYS;++i) if (_predictions[i].display_id==display) return &_predictions[i];
    for (unsigned i=0;i<SN_MAX_DISPLAYS;++i) if (!_predictions[i].display_id) return &_predictions[i];
    /* Bounded display churn: drop old ledgers rather than grow a dictionary. */
    memset(_predictions,0,sizeof(_predictions)); return &_predictions[0];
}
- (sn_outcome)postSwitch:(sn_direction)direction physical:(uint32_t)physical generation:(uint64_t)generation point:(CGPoint)point {
    sn_snapshot snapshot={0}; uint64_t now=sn_now_ns();
    if (!_supported || !atomic_load(&_trusted) || !_eventSource ||
        ![_monitor copySnapshot:&snapshot] || !sn_snapshot_fresh(&snapshot,now) ||
        snapshot.overlay!=SN_OVERLAY_CLEAR || snapshot.generation!=generation) {
        atomic_fetch_add(&_failed,1); return SN_FAILED;
    }
    const sn_display *display=sn_display_by_id(&snapshot,physical);
    if (!display) { atomic_fetch_add(&_failed,1); return SN_FAILED; }
    sn_prediction *prediction=[self predictionFor:display->topology.display_id];
    sn_plan plan;
    sn_plan_status status=sn_prediction_prepare(prediction,&display->topology,now,direction,&plan);
    if (status==SN_PLAN_EDGE) { atomic_fetch_add(&_edge,1); return SN_EDGE; }
    if (status!=SN_PLAN_OK) { atomic_fetch_add(&_failed,1); return SN_FAILED; }
    sn_batch batch={0};
    if (!sn_prepare_events(&batch,_modern,direction,point,_eventSource)) {
        atomic_fetch_add(&_failed,1); return SN_FAILED;
    }
    /* No other callback can interleave: prediction + whole batch are owned by this run loop. */
    if (!sn_prediction_commit(prediction,&plan,sn_now_ns())) {
        sn_batch_release(&batch,sn_release_event,NULL); atomic_fetch_add(&_failed,1); return SN_FAILED;
    }
    sn_batch_post(&batch,sn_post_event,NULL);
    sn_batch_release(&batch,sn_release_event,NULL);
    atomic_fetch_add(&_posted,1); /* Posted, not proof of delivered/interactive. */
    return SN_POSTED;
}
- (CGEventRef)process:(CGEventRef)event type:(CGEventType)type proxy:(CGEventTapProxy)proxy {
    if (type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
        [self discardBuffer]; sn_gesture_reset(&_gesture); memset(_predictions,0,sizeof(_predictions));
        memset(&_shortcutState,0,sizeof(_shortcutState));
        atomic_fetch_add(&_recoveries,1);
        if (_tap && (atomic_load(&_enabled) || atomic_load(&_desktopShortcuts))) CGEventTapEnable(_tap,true);
        atomic_store(&_tapRunning,_tap && CGEventTapIsEnabled(_tap));
        return event;
    }
    if (!event) return event;
    if (type==kCGEventKeyDown || type==kCGEventKeyUp) {
        return sn_route_shortcut(&_shortcutState,_shortcuts,atomic_load(&_desktopShortcuts),event,type,
            ^sn_outcome(sn_direction direction) {
                if (self->_gesture.owner!=SN_IDLE) return SN_FAILED;
                return [self switchAtPointer:direction];
            });
    }
    int64_t raw=CGEventGetIntegerValueField(event,(CGEventField)55);
    if ((raw!=29 && raw!=30) || CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)!=0 ||
        CGEventGetIntegerValueField(event,kCGEventSourceUserData)==SN_EVENT_MARKER) return event;
    sn_kind kind=raw==29 ? SN_COMPANION :
        CGEventGetIntegerValueField(event,(CGEventField)110)==23 &&
        CGEventGetIntegerValueField(event,(CGEventField)123)==1 ? SN_HORIZONTAL : SN_OTHER;
    if (kind==SN_OTHER) return event;
    int64_t phaseRaw=CGEventGetIntegerValueField(event,(CGEventField)132);
    sn_phase phase=SN_NONE;
    switch (phaseRaw) {
        case 1: phase=SN_BEGAN; break; case 2: phase=SN_CHANGED; break;
        case 4: phase=SN_ENDED; break; case 8: phase=SN_CANCELLED; break;
        case 128: phase=SN_MAY_BEGIN; break; default: break;
    }
    uint64_t now=sn_now_ns();
    sn_policy policy={atomic_load(&_enabled),false,_modern,0};
    if (kind==SN_HORIZONTAL && phase==SN_BEGAN) {
        sn_snapshot snapshot={0}; _gesturePoint=CGEventGetLocation(event);
        if (_supported && atomic_load(&_trusted) && _eventSource && [_monitor copySnapshot:&snapshot] &&
            sn_snapshot_fresh(&snapshot,now) && snapshot.overlay==SN_OVERLAY_CLEAR) {
            const sn_display *display=sn_display_at_point(&snapshot,_gesturePoint);
            if (display) {
                _physicalDisplay=display->physical_id; _environmentGeneration=snapshot.generation;
                policy.ready=true;
            }
        }
    }
    sn_input input={kind,phase,false,CGEventGetDoubleValueField(event,(CGEventField)124),
                    CGEventGetDoubleValueField(event,(CGEventField)129),now};
    sn_action action=sn_gesture_step(&_gesture,&input,&policy);
    if (action.flags&SN_DISCARD) [self discardBuffer];
    if (action.flags&SN_ATTEMPT) {
        sn_outcome outcome=[self postSwitch:action.direction physical:_physicalDisplay
            generation:_environmentGeneration point:_gesturePoint];
        action=sn_gesture_feedback(&_gesture,outcome,action.terminal,_modern);
        if (action.flags&SN_DISCARD) [self discardBuffer];
    }
    if (action.flags&SN_REPLAY) [self replayBuffer:proxy];
    if (action.flags&SN_BUFFER) {
        CGEventRef copy=_bufferCount<SN_REPLAY_CAPACITY ? CGEventCreateCopy(event) : NULL;
        if (copy) _buffer[_bufferCount++]=copy;
        else {
            atomic_fetch_add(&_bufferFallbacks,1);
            sn_gesture_feedback(&_gesture,SN_FAILED,false,_modern);
            [self replayBuffer:proxy]; return event;
        }
    }
    if (action.flags&SN_NEUTRAL) { sn_neutralize(event); return event; }
    return action.flags&SN_DROP ? NULL : event;
}
- (CGEventRef)handle:(CGEventRef)event type:(CGEventType)type proxy:(CGEventTapProxy)proxy {
    uint64_t before=sn_now_ns();
    CGEventRef result=[self process:event type:type proxy:proxy];
    uint64_t elapsed=sn_now_ns()-before;
    if (elapsed>atomic_load(&_maximumCallbackNs)) atomic_store(&_maximumCallbackNs,elapsed);
    return result;
}
- (sn_outcome)switchAtPointer:(sn_direction)direction {
    sn_snapshot snapshot={0};
    if (![_monitor copySnapshot:&snapshot]) return SN_FAILED;
    /* Injected keyboard events need not contain the current pointer location. */
    CGEventRef location=CGEventCreate(NULL);
    if (!location) return SN_FAILED;
    CGPoint point=CGEventGetLocation(location); CFRelease(location);
    const sn_display *display=sn_display_at_point(&snapshot,point);
    if (!display) return SN_FAILED;
    return [self postSwitch:direction physical:display->physical_id generation:snapshot.generation point:point];
}
- (NSString *)requestSwitch:(sn_direction)direction {
    if (!_started || !_supported) return @"unavailable";
    if (atomic_exchange(&_commandPending,true)) return @"busy";
    uint64_t deadline=sn_now_ns()+250000000;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSString *result=@"timeout";
    CFRunLoopPerformBlock(_loop,kCFRunLoopCommonModes,^{ @autoreleasepool {
        if (sn_now_ns()<=deadline) {
            if (self->_gesture.owner!=SN_IDLE) result=@"busy_real_gesture";
            else {
                sn_outcome outcome=[self switchAtPointer:direction];
                result=outcome==SN_POSTED ? @"posted" : outcome==SN_EDGE ? @"edge" : @"unavailable";
            }
        }
        atomic_store(&self->_commandPending,false);
        dispatch_semaphore_signal(done);
    }});
    CFRunLoopWakeUp(_loop);
    if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC))) return @"timeout";
    return result;
}
- (NSDictionary *)status {
    sn_snapshot snapshot={0}; BOOL copied=[_monitor copySnapshot:&snapshot]; uint64_t now=sn_now_ns();
    BOOL fresh=copied && sn_snapshot_fresh(&snapshot,now);
    BOOL tap=atomic_load(&_tapRunning),enabled=atomic_load(&_enabled),shortcuts=atomic_load(&_desktopShortcuts);
    NSString *state=!_supported ? @"unsupported_os" : !atomic_load(&_trusted) ? @"accessibility_required" :
        !enabled && !shortcuts ? @"paused" : !tap ? @"tap_unavailable" : !fresh ? @"waiting_for_fresh_snapshot" :
        snapshot.overlay==SN_OVERLAY_ACTIVE ? @"native_overlay" : snapshot.overlay!=SN_OVERLAY_CLEAR ? @"overlay_unknown" :
        !snapshot.display_count ? @"topology_unknown" : @"ready";
    return @{@"state":state,@"enabled":@(enabled),@"tap_running":@(tap),
        @"desktop_shortcuts":@(shortcuts),@"desktop_shortcuts_configured":@(atomic_load(&_shortcutCount)),
        @"accessibility":@(atomic_load(&_trusted)),@"os_supported":@(_supported),@"modern_payload":@(_modern),
        @"cgs_available":@(snapshot.cgs_available),@"snapshot_fresh":@(fresh),@"displays":@(snapshot.display_count),
        @"snapshot_age_ms":@(snapshot.observed_ns && now>=snapshot.observed_ns ? (now-snapshot.observed_ns)/1000000 : UINT64_MAX),
        @"posted":@(atomic_load(&_posted)),@"edge_blocks":@(atomic_load(&_edge)),
        @"failed_or_unsafe":@(atomic_load(&_failed)),@"native_replays":@(atomic_load(&_replayed)),
        @"buffer_fallbacks":@(atomic_load(&_bufferFallbacks)),@"tap_recoveries":@(atomic_load(&_recoveries)),
        @"maximum_callback_us":@(atomic_load(&_maximumCallbackNs)/1000)};
}
@end
