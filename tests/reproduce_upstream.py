#!/usr/bin/env python3
"""Execute upstream's unmodified handle/fire methods against fake CGEvent accessors.
This checks Swift control flow, NOT CoreGraphics or Dock behavior. No events post.
"""
from pathlib import Path
import hashlib, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'tests/upstream/SwipeInterceptor.swift').read_text()
methods=source[source.index('    func handle(type:'):]
shim=r'''
import Foundation
enum CGEventType { case ordinary, tapDisabledByTimeout, tapDisabledByUserInput }
final class CGEvent {
    var cgs: Int64 = 30, pid: Int64 = 0, phase: Int64
    var progress: Double, velocity: Double
    init(_ phase: Int64, _ progress: Double=0, _ velocity: Double=0) {
        self.phase=phase; self.progress=progress; self.velocity=velocity
    }
    static func tapEnable(tap: Int, enable: Bool) {}
}
protocol SwitchEngine { func switchSpace(_ direction: SwitchDirection) throws }
enum SwitchDirection { case left, right }
enum SwitchEngineError: Error { case atEdge, failed }
final class Engine: SwitchEngine {
    var attempts=0
    func switchSpace(_ direction: SwitchDirection) throws { attempts += 1 }
}
func strafe_event_cgs_type(_ e: CGEvent)->Int64 { e.cgs }
func strafe_cgs_event_dock_control()->Int64 { 30 }
func strafe_cgs_event_gesture()->Int64 { 29 }
func strafe_event_source_pid(_ e: CGEvent)->Int64 { e.pid }
func strafe_event_hid_type(_ e: CGEvent)->Int64 { 23 }
func strafe_iohid_event_dock_swipe()->Int64 { 23 }
func strafe_event_swipe_motion(_ e: CGEvent)->Int64 { 1 }
func strafe_gesture_motion_horizontal()->Int64 { 1 }
func strafe_event_gesture_phase(_ e: CGEvent)->Int64 { e.phase }
func strafe_gesture_phase_began()->Int64 { 1 }
func strafe_gesture_phase_changed()->Int64 { 2 }
func strafe_gesture_phase_ended()->Int64 { 4 }
func strafe_gesture_phase_cancelled()->Int64 { 8 }
func strafe_event_swipe_progress(_ e: CGEvent)->Double { e.progress }
func strafe_event_swipe_velocity_x(_ e: CGEvent)->Double { e.velocity }
func strafe_event_moves_right(_ v: Double)->Bool { v>0 }
func strafe_uses_iohid_payload()->Bool { false }
func strafe_clear_swipe_motion(_ e: CGEvent) { e.progress=0; e.velocity=0 }
final class SwipeInterceptor {
    let engine: SwitchEngine
    let isExposeActive: ()->Bool
    var eventTap: Int? = nil
    var overrideEnabled=true
    var swipeTracking=false, swipeFired=false, swipePosted=false
    init(_ e: SwitchEngine, overlay: @escaping ()->Bool = { false }) {
        engine=e; isExposeActive=overlay
    }
'''
cases=r'''
var reproduced=0
func result(_ name: String, _ bad: Bool) {
    print("\(bad ? "REPRODUCED" : "NOT REPRODUCED"): \(name)")
    if bad { reproduced += 1 }
}
do {
    let e=Engine(), i=SwipeInterceptor(Engine(),overlay:{true})
    _=e
    let b=i.handle(type:.ordinary,event:CGEvent(1))
    let c=i.handle(type:.ordinary,event:CGEvent(8))
    result("native overlay began passes but cancelled is swallowed",b != nil && c == nil)
}
do {
    let e=Engine(), i=SwipeInterceptor(Engine())
    _=e
    _=i.handle(type:.ordinary,event:CGEvent(1))
    i.overrideEnabled=false
    _=i.handle(type:.ordinary,event:CGEvent(4))
    i.overrideEnabled=true
    let companion=CGEvent(0); companion.cgs=29
    result("disable during swipe leaves tracking set after ended",i.handle(type:.ordinary,event:companion)==nil)
}
do {
    let e=Engine(); let i=SwipeInterceptor(e)
    _=i.handle(type:.ordinary,event:CGEvent(1))
    _=i.handle(type:.ordinary,event:CGEvent(2,Double.nan))
    result("NaN progress triggers a switch",e.attempts==1)
}
do {
    let e=Engine(); let i=SwipeInterceptor(e)
    let b=i.handle(type:.ordinary,event:CGEvent(1))
    let end=i.handle(type:.ordinary,event:CGEvent(4))
    result("zero-motion began suppressed but orphan ended passed",b==nil && end != nil && e.attempts==0)
}
print("\(reproduced)/4 upstream control-flow defects reproduced with platform stubs.")
if reproduced != 4 { exit(1) }
'''
print('upstream_source_sha256='+hashlib.sha256(source.encode()).hexdigest(), flush=True)
with tempfile.TemporaryDirectory() as d:
    generated=Path(d)/'main.swift'; generated.write_text(shim+methods+cases)
    exe=Path(d)/'upstream-regressions'
    subprocess.run(['swiftc','-O',str(generated),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
