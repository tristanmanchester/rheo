/* SPDX-License-Identifier: MIT */
#import "runtime.h"
#import <Carbon/Carbon.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>

static NSString *const domain=@"dev.rheo.app";
static const OSType hotkeySignature=0x5248454f; /* RHEO */
static CFStringRef port_name(void) {
    return CFStringCreateWithFormat(NULL,NULL,CFSTR("dev.rheo.control.%u"),(unsigned)geteuid());
}
static NSData *request(NSString *command) {
    CFStringRef name=port_name();
    CFMessagePortRef remote=CFMessagePortCreateRemote(NULL,name); CFRelease(name);
    if (!remote) return nil;
    NSData *data=[command dataUsingEncoding:NSUTF8StringEncoding]; CFDataRef response=NULL;
    SInt32 result=CFMessagePortSendRequest(remote,1,(__bridge CFDataRef)data,1.0,2.0,kCFRunLoopDefaultMode,&response);
    CFRelease(remote);
    if (result!=kCFMessagePortSuccess || !response || CFDataGetLength(response)>65536) {
        if (response) CFRelease(response); return nil;
    }
    return CFBridgingRelease(response);
}

@interface RheoAppDelegate : NSObject <NSApplicationDelegate,NSMenuDelegate>
- (NSDictionary *)command:(NSString *)command;
- (void)switchDirection:(sn_direction)direction;
@end
static CFDataRef receive(CFMessagePortRef port,SInt32 identifier,CFDataRef data,void *info) {
    (void)port;
    if (identifier!=1 || !data || CFDataGetLength(data)>64) return NULL;
    NSString *text=[[NSString alloc] initWithData:(__bridge NSData *)data encoding:NSUTF8StringEncoding];
    if (!text) return NULL;
    NSDictionary *result=[(__bridge RheoAppDelegate *)info command:text];
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
    return encoded ? (CFDataRef)CFBridgingRetain(encoded) : NULL;
}
static OSStatus hotkey_callback(EventHandlerCallRef call,EventRef event,void *info) {
    (void)call; EventHotKeyID key={0};
    if (GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key)!=noErr ||
        key.signature!=hotkeySignature || (key.id!=1 && key.id!=2)) return eventNotHandledErr;
    [(__bridge RheoAppDelegate *)info switchDirection:key.id==1 ? SN_LEFT : SN_RIGHT];
    return noErr;
}

@implementation RheoAppDelegate {
    RheoRuntime *_runtime;
    NSUserDefaults *_preferences;
    NSStatusItem *_statusItem;
    NSMenuItem *_stateItem, *_enabledItem, *_hotkeysItem;
    BOOL _enabled, _hotkeysDesired, _hotkeysRegistered;
    NSString *_lastCommand;
    EventHotKeyRef _left, _right;
    EventHandlerRef _handler;
    CFMessagePortRef _port;
    CFRunLoopSourceRef _portSource;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    CFStringRef name=port_name();
    CFMessagePortContext context={0,(__bridge void *)self,NULL,NULL,NULL};
    _port=CFMessagePortCreateLocal(NULL,name,receive,&context,NULL); CFRelease(name);
    if (!_port) { request(@"show"); [NSApp terminate:nil]; return; }
    _portSource=CFMessagePortCreateRunLoopSource(NULL,_port,0);
    if (!_portSource) { [NSApp terminate:nil]; return; }
    CFRunLoopAddSource(CFRunLoopGetMain(),_portSource,kCFRunLoopCommonModes);
    _preferences=[[NSUserDefaults alloc] initWithSuiteName:domain];
    [_preferences registerDefaults:@{@"interceptSwipes":@YES,@"hotkeys":@YES}];
    _enabled=[_preferences boolForKey:@"interceptSwipes"];
    _hotkeysDesired=[_preferences boolForKey:@"hotkeys"];
    _runtime=[[RheoRuntime alloc] initWithEnabled:_enabled];
    if (![_runtime start]) { NSLog(@"Rheo: cannot start event thread"); [NSApp terminate:nil]; return; }
    [self applyHotkeys];
    _statusItem=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image=[NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right" accessibilityDescription:@"Rheo"];
    if (!_statusItem.button.image) _statusItem.button.title=@"↔";
    _statusItem.button.toolTip=@"Rheo";
    NSMenu *menu=[NSMenu new]; menu.delegate=self;
    _stateItem=[menu addItemWithTitle:@"Starting…" action:NULL keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    _enabledItem=[menu addItemWithTitle:@"Intercept swipes" action:@selector(toggleEnabled:) keyEquivalent:@""];
    _hotkeysItem=[menu addItemWithTitle:@"Control–Option–Arrow hotkeys" action:@selector(toggleHotkeys:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Accessibility settings…" action:@selector(openPermissions:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Copy diagnostics" action:@selector(copyDiagnostics:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Hide menu-bar icon" action:@selector(hide:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit Rheo" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *item in menu.itemArray) if (item.action) item.target=self;
    _statusItem.menu=menu; _statusItem.visible=YES;
    NSNotificationCenter *workspace=NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName event in @[NSWorkspaceActiveSpaceDidChangeNotification,
        NSWorkspaceDidWakeNotification,NSWorkspaceSessionDidBecomeActiveNotification,
        NSWorkspaceSessionDidResignActiveNotification,NSWorkspaceDidLaunchApplicationNotification,
        NSWorkspaceDidTerminateApplicationNotification]) {
        [workspace addObserver:self selector:@selector(environmentChanged:) name:event object:nil];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(environmentChanged:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    if (!AXIsProcessTrusted()) {
        NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    }
}
- (void)environmentChanged:(NSNotification *)notification {
    (void)notification; [_runtime refreshEnvironment];
}
- (void)removeHotkeys {
    if (_left) { UnregisterEventHotKey(_left); _left=NULL; }
    if (_right) { UnregisterEventHotKey(_right); _right=NULL; }
    if (_handler) { RemoveEventHandler(_handler); _handler=NULL; }
    _hotkeysRegistered=NO;
}
- (void)applyHotkeys {
    [self removeHotkeys];
    if (!_hotkeysDesired || ![[_runtime status][@"os_supported"] boolValue]) return;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    if (InstallEventHandler(GetApplicationEventTarget(),hotkey_callback,1,&type,(__bridge void *)self,&_handler)!=noErr)
        return;
    EventHotKeyID left={hotkeySignature,1},right={hotkeySignature,2};
    OSStatus a=RegisterEventHotKey(kVK_LeftArrow,controlKey|optionKey,left,GetApplicationEventTarget(),0,&_left);
    OSStatus b=a==noErr ? RegisterEventHotKey(kVK_RightArrow,controlKey|optionKey,right,GetApplicationEventTarget(),0,&_right) : a;
    if (a!=noErr || b!=noErr) { [self removeHotkeys]; return; }
    _hotkeysRegistered=YES;
}
- (NSDictionary *)diagnostics {
    NSMutableDictionary *status=[[_runtime status] mutableCopy] ?: [NSMutableDictionary new];
    status[@"version"]=@"0.2.0"; status[@"hotkeys_requested"]=@(_hotkeysDesired);
    status[@"hotkeys_registered"]=@(_hotkeysRegistered);
    status[@"last_command"]=_lastCommand ?: @"none";
    status[@"switch_completion_verified"]=@NO;
    return status;
}
- (NSDictionary *)command:(NSString *)command {
    if ([command isEqualToString:@"status"]) return [self diagnostics];
    if ([command isEqualToString:@"switch left"] || [command isEqualToString:@"switch right"]) {
        _lastCommand=[_runtime requestSwitch:[command hasSuffix:@"left"] ? SN_LEFT : SN_RIGHT];
        return @{@"result":_lastCommand,@"completion_verified":@NO};
    }
    if ([command isEqualToString:@"enabled on"] || [command isEqualToString:@"enabled off"]) {
        _enabled=[command hasSuffix:@"on"]; [_preferences setBool:_enabled forKey:@"interceptSwipes"];
        [_runtime setEnabled:_enabled]; return @{@"result":@"applied",@"enabled":@(_enabled)};
    }
    if ([command isEqualToString:@"hotkeys on"] || [command isEqualToString:@"hotkeys off"]) {
        _hotkeysDesired=[command hasSuffix:@"on"]; [_preferences setBool:_hotkeysDesired forKey:@"hotkeys"];
        [self applyHotkeys];
        return @{@"result":_hotkeysDesired && !_hotkeysRegistered ? @"hotkeys_unavailable" : @"applied",
                 @"registered":@(_hotkeysRegistered)};
    }
    if ([command isEqualToString:@"show"]) { _statusItem.visible=YES; return @{@"result":@"shown"}; }
    if ([command isEqualToString:@"quit"]) {
        dispatch_async(dispatch_get_main_queue(),^{ [NSApp terminate:nil]; });
        return @{@"result":@"quitting"};
    }
    return @{@"result":@"invalid_command"};
}
- (void)switchDirection:(sn_direction)direction { _lastCommand=[_runtime requestSwitch:direction]; }
- (void)menuNeedsUpdate:(NSMenu *)menu {
    (void)menu;
    NSDictionary *status=[self diagnostics];
    _stateItem.title=[NSString stringWithFormat:@"Rheo · %@",status[@"state"] ?: @"starting"];
    _enabledItem.state=_enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _hotkeysItem.state=_hotkeysRegistered ? NSControlStateValueOn : NSControlStateValueOff;
    _hotkeysItem.title=_hotkeysDesired && !_hotkeysRegistered ? @"Hotkeys unavailable — click to disable" : @"Control–Option–Arrow hotkeys";
}
- (void)toggleEnabled:(id)sender { (void)sender; [self command:_enabled ? @"enabled off" : @"enabled on"]; }
- (void)toggleHotkeys:(id)sender { (void)sender; [self command:_hotkeysDesired ? @"hotkeys off" : @"hotkeys on"]; }
- (void)openPermissions:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}
- (void)copyDiagnostics:(id)sender {
    (void)sender;
    NSData *data=[NSJSONSerialization dataWithJSONObject:[self diagnostics]
        options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}
- (void)hide:(id)sender { (void)sender; _statusItem.visible=NO; }
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)flag {
    (void)application; (void)flag; _statusItem.visible=YES; return NO;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removeHotkeys];
    if (_portSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(),_portSource,kCFRunLoopCommonModes); CFRelease(_portSource); _portSource=NULL; }
    if (_port) { CFMessagePortInvalidate(_port); CFRelease(_port); _port=NULL; }
    [_runtime stop];
}
@end

static int cli(int argc,const char *argv[]) {
    if (argc==2 && (!strcmp(argv[1],"--help") || !strcmp(argv[1],"help"))) {
        puts("Rheo 0.2.0 — instant macOS Space switching\n"
             "Run the app once, then use:\n"
             "  rheo status\n  rheo switch left|right\n"
             "  rheo enabled on|off\n  rheo hotkeys on|off\n"
             "  rheo show\n  rheo quit\n"
             "Switch result 'posted' does not prove completion. No animation presets.");
        return 0;
    }
    if (argc==2 && !strcmp(argv[1],"--version")) { puts("0.2.0"); return 0; }
    BOOL valid=argc==2 && (!strcmp(argv[1],"status") || !strcmp(argv[1],"show") || !strcmp(argv[1],"quit"));
    valid=valid || (argc==3 && ((!strcmp(argv[1],"switch") && (!strcmp(argv[2],"left") || !strcmp(argv[2],"right"))) ||
        ((!strcmp(argv[1],"enabled") || !strcmp(argv[1],"hotkeys")) && (!strcmp(argv[2],"on") || !strcmp(argv[2],"off")))));
    if (!valid) { fputs("Invalid arguments; use rheo --help\n",stderr); return 2; }
    NSString *command=argc==2 ? [NSString stringWithUTF8String:argv[1]] : [NSString stringWithFormat:@"%s %s",argv[1],argv[2]];
    NSData *response=request(command);
    if (!response) { fputs("Resident app unavailable or request timed out. Open Rheo.app first.\n",stderr); return 3; }
    fwrite(response.bytes,1,response.length,stdout); putchar('\n');
    id decoded=[NSJSONSerialization JSONObjectWithData:response options:0 error:NULL];
    if (![decoded isKindOfClass:NSDictionary.class]) { fputs("Invalid resident response\n",stderr); return 3; }
    NSDictionary *json=decoded;
    NSString *result=json[@"result"];
    if (result && ![result isKindOfClass:NSString.class]) return 3;
    return !result || [@[@"posted",@"edge",@"applied",@"shown",@"quitting"] containsObject:result] ? 0 : 1;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if (argc>1) return cli(argc,argv);
        NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) RheoAppDelegate *delegate=[RheoAppDelegate new];
        app.delegate=delegate; [app run];
        return 0;
    }
}
