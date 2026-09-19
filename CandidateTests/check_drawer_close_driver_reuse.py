#!/usr/bin/env python3
"""Compare 5015 and this checkout's real drawer state/settle declarations.

The real Spring and callbacks execute with a manually advanced display-link
double. Observation delivery and UIKit receivers are controlled doubles, so this
is a regression contract, not an iPhone interaction or performance measurement.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = "bf5865d390dfffba0a45fc13e9cbd3db8335a662"
OUT = ROOT / "work/verification/drawer-close-driver-reuse"


def extract(source, pattern):
    match = re.search(pattern, source, re.M)
    if not match:
        raise ValueError(pattern)
    start = match.start()
    opening = source.index("{", match.end())
    depth, i, state = 0, opening, "code"
    while i < len(source):
        pair, char = source[i:i + 2], source[i]
        if state == "line":
            if char == "\n":
                state = "code"
        elif state == "block":
            if pair == "*/":
                state = "code"
                i += 1
        elif state == "string":
            if char == "\\":
                i += 1
            elif char == '"':
                state = "code"
        elif pair == "//":
            state = "line"
            i += 1
        elif pair == "/*":
            state = "block"
            i += 1
        elif char == '"':
            state = "string"
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:i + 1], [source.count("\n", 0, start) + 1,
                                            source.count("\n", 0, i) + 1]
        i += 1
    raise ValueError("Unbalanced declaration")


def method(source, name):
    return extract(source, rf"^    (?:private )?func {name}\b")


def strip_viewport_freeze_hooks(source):
    """5019 phase calls have a separate viewport-freeze contract."""
    return re.sub(r"^ +DrawerViewportRefreshFreeze\.(?:reset|setSettling|setDragging)\([^\n]*\)\n", "", source, flags=re.M)


def replace_probe_regions(before, after):
    """Probe/box regions are covered by check_chat_scroll_probe_ownership.py."""
    pattern = r"^@MainActor\nprivate final class WeakChatScrollViewBox\b"
    before = before.replace(extract(before, pattern)[0], extract(after, pattern)[0], 1)
    start = "private struct ChatScrollViewProbe:"
    end = "/// Adds one exact status-bar request hook"
    a, b = before.index(start), before.index(end)
    c, d = after.index(start), after.index(end)
    return before[:a] + after[c:d] + before[b:]


COMMON = r'''
import Foundation
import SwiftUI
import Observation

@MainActor enum Clock { static var now: CFTimeInterval = 100 }
@MainActor func CACurrentMediaTime() -> CFTimeInterval { Clock.now }
struct CAFrameRateRange { let minimum: Float; let maximum: Float; let preferred: Float }
@MainActor final class UIScreen {
    static let main = UIScreen()
    let maximumFramesPerSecond = 120
}
@MainActor final class CADisplayLink: NSObject {
    static var links: [CADisplayLink] = []
    weak var target: NSObject?
    let selector: Selector
    var timestamp: CFTimeInterval = 0
    var targetTimestamp: CFTimeInterval = 0
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    var invalidated = false
    init(target: NSObject, selector: Selector) {
        self.target = target; self.selector = selector
        super.init(); Self.links.append(self)
    }
    func add(to: RunLoop, forMode: RunLoop.Mode) {}
    func invalidate() { invalidated = true }
    func fire(at time: CFTimeInterval) {
        guard !invalidated else { return }
        Clock.now = time; timestamp = time - 1.0 / 120; targetTimestamp = time
        _ = target?.perform(selector, with: self)
    }
}
@propertyWrapper struct Box<Value> {
    final class Storage { var value: Value; init(_ value: Value) { self.value = value } }
    let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }
}
@MainActor final class UIScrollView: NSObject {
    var writes: [String] = []
    var isScrollEnabled = true { didSet { writes.append("enabled=\(isScrollEnabled)") } }
    var scrollsToTop = true { didSet { writes.append("top=\(scrollsToTop)") } }
}
@MainActor enum VersionFlashTrace {
    static var events: [String] = []
    static func record(_ text: String) { events.append(text) }
    static func identifierToken(_ id: UUID) -> String { id.uuidString }
}
@MainActor enum DrawerTrackedContentLayerMotion {
    static var progress: CGFloat = 0
    static func update(_ value: CGFloat) { progress = value }
}
@MainActor enum DrawerFrameTrace { static func rootDidDisappear() {} }
@MainActor enum DrawerHighRefreshLease { static func stop() {} }
@MainActor enum DrawerInlineActionTapGate { static func reset() {} }
@MainActor final class ChatScrollViewRegistration {}
@MainActor final class Model {
    struct Preferences { var hapticsOnDrawer = false }
    enum Haptic { case soft }
    var preferences = Preferences()
    var isDrawerPresented = false {
        didSet { if isDrawerPresented != oldValue { changes.append(isDrawerPresented) } }
    }
    var changes: [Bool] = []
    var selectedConversationID: UUID? = UUID()
    var streamingSuspended = false
    func performHaptic(_ value: Haptic) {}
    func setDrawerStreamingTextDisplaySuspended(_ value: Bool) { streamingSuspended = value }
    /*MODEL*/
}
@MainActor final class DrawerListTopReturnCoordinator {
    var scrollView: UIScrollView?
    var immediatelyLockedScrollView: UIScrollView?
    var isDrawerGestureLockActive = false
    var isStatusBarScrollToTopEnabled = false
    func finishSoftTopReturnForDrawerOpening() {}
    func reset() { isDrawerGestureLockActive = false; releaseImmediateInteractionLock() }
    /*COORDINATOR*/
}
/*DECLARATIONS*/
@MainActor private struct Harness {
    let model = Model()
    let chat = UIScrollView()
    let registration = ChatScrollViewRegistration()
    let list = UIScrollView()
    let drawerListTopReturnCoordinator = DrawerListTopReturnCoordinator()
    let drawerSettleDriver = DrawerSettleDisplayLinkDriver()
    let drawerPresentationProgressTracker = DrawerPresentationProgressTracker()
    let detachedMainPanelProgress = DrawerDetachedMainPanelProgress()
    @Box var drawerDragProgress: CGFloat? = nil
    @Box var drawerSettleTask: Task<Void, Never>? = nil
    @Box var drawerSettleSequence: UInt64 = 0
    @Box var isDrawerGestureActive = false
    @Box var pendingDrawerCloseConversationID: UUID? = nil
    init(presented: Bool, registered: Bool, progress: CGFloat, gesture: Bool = false) {
        Clock.now = 100; CADisplayLink.links = []; VersionFlashTrace.events = []
        DrawerNativeScrollGate.reset()
        model.isDrawerPresented = presented; model.changes = []
        drawerPresentationProgressTracker.update(progress)
        drawerDragProgress = gesture ? progress : nil
        isDrawerGestureActive = gesture
        if registered { DrawerNativeScrollGate.register(chat, role: .chat, owner: registration) }
        drawerListTopReturnCoordinator.scrollView = list
        if gesture {
            list.isScrollEnabled = false
            drawerListTopReturnCoordinator.immediatelyLockedScrollView = list
        }
        syncDrawerNativeScrollGate()
        chat.writes = []; list.writes = []
    }
    func dismissComposerKeyboardForDrawerOpening() {}
    func deliverChanges() {
        let changes = model.changes; model.changes = []
        for value in changes { observe(value) }
    }
    /*METHODS*/
    /*OBSERVER*/
    /*DISAPPEAR*/
}
'''

RUNNER = r'''
struct Result: Codable {
    let scenario: String
    let registered: Bool
    let checks: [String: Bool]
    let events: [String]
    var pass: Bool { checks.values.allSatisfy { $0 } }
}
@main struct Runner {
    @MainActor static func main() async throws {
        var results: [Result] = []
        let scenarios = ["drag_close", "button_close", "conversation_ready_close",
            "cancel_open", "successful_open", "cancel_close", "external_close_during_open",
            "external_close_without_driver", "close_with_active_gesture", "close_with_pending_conversation",
            "reverse_before_semantic_close", "button_reverse_after_semantic_close", "root_disappear"]
        for registered in [true, false] {
            for scenario in scenarios {
                let closedInitially = ["cancel_open", "successful_open"].contains(scenario)
                let h = Harness(presented: !closedInitially, registered: registered,
                                progress: 0.65, gesture: scenario != "button_close")
                var checks: [String: Bool] = [:]
                if ["drag_close", "button_close", "conversation_ready_close"].contains(scenario) {
                    if scenario == "conversation_ready_close" {
                        let id = h.model.selectedConversationID!
                        h.requestDrawerCloseAfterConversationReady(id)
                        h.handleConversationContentReady(UUID())
                        checks["unrelated_ready_does_not_start"] = CADisplayLink.links.isEmpty
                        h.handleConversationContentReady(id)
                    } else if scenario == "button_close" { h.closeDrawerAnimated() }
                    else { h.settleDrawer(open: false) }
                    let original = CADisplayLink.links.last!
                    let sequence = h.drawerSettleSequence
                    checks["semantic_close_is_delayed"] = h.model.isDrawerPresented
                    original.fire(at: 100.016)
                    try await Task.sleep(for: .milliseconds(35))
                    h.deliverChanges()
                    checks["same_driver_and_sequence"] = CADisplayLink.links.count == 1 && !original.invalidated && h.drawerSettleSequence == sequence
                    checks["semantic_close_unlocks_chat"] = !h.model.isDrawerPresented && (!registered || h.chat.isScrollEnabled)
                    checks["streaming_suspended_until_completion"] = h.model.streamingSuspended
                    CADisplayLink.links.last!.fire(at: 100.040)
                    let expected = 0.65 + SwiftUI.Spring(response: 0.42, dampingRatio: 0.92)
                        .value(target: CGFloat(-0.65), initialVelocity: CGFloat.zero, time: 0.040)
                    checks["original_spring_phase_retained"] = abs(h.drawerPresentationProgressTracker.resolved(fallback: -1) - expected) < 0.000001
                    CADisplayLink.links.last!.fire(at: 100.561)
                    checks["completes_on_original_schedule"] = !h.detachedMainPanelProgress.isActive && !h.model.streamingSuspended && h.drawerSettleDriver.activeTargetProgress == nil
                    checks["one_completion"] = VersionFlashTrace.events.filter { $0.hasPrefix("DRAWER_SETTLE_COMPLETE") }.count == 1
                } else if ["cancel_open", "successful_open", "cancel_close"].contains(scenario) {
                    let open = scenario != "cancel_open"
                    h.settleDrawer(open: open)
                    h.setDrawerGestureActive(false) // The onEnded defer repeats release.
                    try await Task.sleep(for: .milliseconds(35))
                    h.deliverChanges()
                    checks["single_driver"] = CADisplayLink.links.count == 1
                    checks["semantic_endpoint"] = h.model.isDrawerPresented == open
                    checks["no_chat_unlock_during_open_handoff"] = !open || !h.chat.writes.contains("enabled=true")
                    checks["gate_endpoint"] = !registered || h.chat.isScrollEnabled == !open
                    CADisplayLink.links.last!.fire(at: 100.561)
                    checks["visual_endpoint"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == (open ? 1 : 0)
                    checks["completion_cleanup"] = !h.detachedMainPanelProgress.isActive && h.model.streamingSuspended == open
                } else if ["external_close_during_open", "external_close_without_driver", "close_with_active_gesture", "close_with_pending_conversation"].contains(scenario) {
                    h.setDrawerGestureActive(false)
                    let opening = scenario == "external_close_during_open"
                    if scenario == "external_close_without_driver" {
                        h.detachedMainPanelProgress.begin(at: 0.65, drivesDrawer: true)
                    } else {
                        h.startDrawerSettleProgress(from: 0.65, to: opening ? 1 : 0)
                        CADisplayLink.links.last!.fire(at: 100.016)
                    }
                    if scenario == "close_with_active_gesture" { h.setDrawerGestureActive(true) }
                    if scenario == "close_with_pending_conversation" { h.pendingDrawerCloseConversationID = UUID() }
                    let previous = CADisplayLink.links.last
                    let progress = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                    h.model.setDrawerPresented(false); h.deliverChanges()
                    checks["external_close_rejoined"] = h.drawerSettleDriver.activeTargetProgress == 0 && (previous == nil || previous!.invalidated)
                    checks["sampled_position_preserved"] = h.detachedMainPanelProgress.progress == progress
                    checks["ownership_released"] = !h.isDrawerGestureActive && h.pendingDrawerCloseConversationID == nil
                    previous?.fire(at: 100.700)
                    checks["invalidated_open_cannot_complete"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == progress
                    CADisplayLink.links.last!.fire(at: 100.800)
                    checks["external_close_endpoint"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == 0 && !h.model.streamingSuspended && !h.detachedMainPanelProgress.isActive
                } else if scenario == "reverse_before_semantic_close" {
                    h.settleDrawer(open: false)
                    let previous = CADisplayLink.links.last!
                    previous.fire(at: 100.004)
                    let progress = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                    // The same cancellation/adoption calls used by gesture takeover.
                    h.setDrawerGestureActive(true); h.cancelDrawerSettleWork()
                    h.adoptDrawerPresentationProgressForRoot(progress)
                    h.settleDrawer(open: true)
                    try await Task.sleep(for: .milliseconds(35))
                    h.deliverChanges()
                    checks["cancelled_task_cannot_close"] = h.model.isDrawerPresented && h.drawerSettleDriver.activeTargetProgress == 1
                    checks["no_transient_chat_unlock"] = !h.chat.writes.contains("enabled=true")
                    checks["reversal_starts_at_sample"] = h.detachedMainPanelProgress.progress == progress
                    previous.fire(at: 100.600)
                    CADisplayLink.links.last!.fire(at: 100.700)
                    checks["reversal_completes_open"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == 1 && h.model.streamingSuspended
                } else if scenario == "button_reverse_after_semantic_close" {
                    h.settleDrawer(open: false)
                    CADisplayLink.links.last!.fire(at: 100.016)
                    try await Task.sleep(for: .milliseconds(35))
                    h.deliverChanges()
                    CADisplayLink.links.last!.fire(at: 100.080)
                    let progress = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                    let previous = CADisplayLink.links.last!
                    h.openDrawerFromButton(); h.deliverChanges()
                    checks["button_reverses_from_sample"] = h.detachedMainPanelProgress.progress == progress && progress > 0 && progress < 0.65
                    checks["close_cancelled_open_owned"] = previous.invalidated && h.drawerSettleDriver.activeTargetProgress == 1 && h.model.isDrawerPresented
                    CADisplayLink.links.last!.fire(at: 100.800)
                    checks["button_reversal_endpoint"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == 1 && !h.detachedMainPanelProgress.isActive
                } else {
                    h.settleDrawer(open: false)
                    let previous = CADisplayLink.links.last!
                    h.disappear()
                    try await Task.sleep(for: .milliseconds(35))
                    previous.fire(at: 100.800)
                    checks["disappearance_cancels_work"] = previous.invalidated && h.drawerSettleDriver.activeTargetProgress == nil && h.drawerSettleTask == nil
                    checks["disappearance_restores_state"] = !h.model.streamingSuspended && !h.detachedMainPanelProgress.isActive && !h.isDrawerGestureActive
                    checks["cancelled_task_did_not_publish_close"] = h.model.isDrawerPresented
                    checks["gate_reset"] = h.chat.isScrollEnabled
                }
                results.append(Result(scenario: scenario, registered: registered, checks: checks, events: VersionFlashTrace.events))
                h.cancelDrawerSettleWork()
            }
        }
        print(String(decoding: try JSONEncoder().encode(results), as: UTF8.self))
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
    new = (ROOT / "Mocca/RootView.swift").read_text()
    model = (ROOT / "Mocca/AppModel.swift").read_text()
    model_old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/AppModel.swift"], cwd=ROOT, text=True)
    assert model == model_old, "AppModel drifted from the reviewed baseline"
    observer_pattern = r"^        \.onChange\(of: model.isDrawerPresented\)"
    old_observer, _ = extract(old, observer_pattern)
    new_observer, _ = extract(new, observer_pattern)
    gate_pattern = r"^@MainActor\nprivate enum DrawerNativeScrollGate\b"
    old_gate, _ = extract(old, gate_pattern)
    new_gate, _ = extract(new, gate_pattern)
    # Gate changes have a separate regression contract; keep the remaining
    # RootView source fixed while rerunning the close contract on this build.
    assert strip_viewport_freeze_hooks(replace_probe_regions(old, new).replace(old_observer, new_observer, 1).replace(old_gate, new_gate, 1)) == strip_viewport_freeze_hooks(new), "RootView changed outside the observer/gate/probe"
    version = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", (ROOT / "Mocca.xcodeproj/project.pbxproj").read_text()).group(1)
    cases, provenance = [], {}
    for label, root in (("5015", old), (version, new)):
        declarations, locations = [], {}
        for name in ("DrawerSettleDisplayLinkDriver", "DrawerNativeScrollGate", "DrawerPresentationProgressTracker", "DrawerDetachedMainPanelProgress"):
            value, lines = extract(root, rf"^@MainActor\n(?:@Observable\n)?private (?:final class|enum) {name}\b")
            declarations.append(value); locations[name] = lines
        methods = []
        for name in ("cancelDrawerSettleWork", "startDrawerSettleProgress", "adoptDrawerPresentationProgressForRoot", "setDrawerGestureActive", "syncDrawerNativeScrollGate", "openDrawerFromButton", "closeDrawerAnimated", "requestDrawerCloseAfterConversationReady", "handleConversationContentReady", "continueDrawerCloseAfterExternalSemanticChange", "settleDrawer"):
            value, lines = method(root, name)
            # Visibility/unused-result annotation only; the function body is verbatim.
            methods.append(value.replace("private func", "func", 1)); locations[name] = lines
        observer, locations["onChange"] = extract(root, observer_pattern)
        observer = "func observe(_ isPresented: Bool) {" + observer.split(" in\n", 1)[1]
        disappear, locations["onDisappear"] = extract(root, r"^        \.onDisappear\b")
        disappear = "func disappear() {" + disappear.split("{", 1)[1]
        coordinator = "\n".join(method(root, name)[0] for name in ("setDrawerGestureLockActive", "releaseImmediateInteractionLock", "setStatusBarScrollToTopEnabled"))
        swift = COMMON.replace("/*MODEL*/", method(model, "setDrawerPresented")[0]).replace("/*COORDINATOR*/", coordinator).replace("/*DECLARATIONS*/", "\n".join(declarations)).replace("/*METHODS*/", "\n".join(methods)).replace("/*OBSERVER*/", observer).replace("/*DISAPPEAR*/", disappear) + RUNNER
        if "owner: ChatScrollViewRegistration" not in root:
            swift = swift.replace(", owner: registration", "")
        swift = strip_viewport_freeze_hooks(swift)
        (OUT / f"contract-{label}.swift").write_text(swift)
        with tempfile.TemporaryDirectory(prefix="drawer-close-contract-") as temporary:
            binary = Path(temporary) / "contract"
            command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(Path(temporary) / "ModuleCache"), str(OUT / f"contract-{label}.swift"), "-o", str(binary)]
            build = subprocess.run(command, capture_output=True, text=True, timeout=180)
            (OUT / f"contract-{label}-build.log").write_text(build.stdout + build.stderr)
            if build.returncode:
                raise SystemExit(build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            (OUT / f"contract-{label}-run.log").write_text(run.stdout + run.stderr)
            run.check_returncode()
        for case in json.loads(run.stdout):
            case.update(version=label, passed=all(case["checks"].values()))
            cases.append(case)
        provenance[label] = {"root_sha256": hashlib.sha256(root.encode()).hexdigest(), "harness_sha256": hashlib.sha256(swift.encode()).hexdigest(), "extracted_lines": locations}
    failures = [(c["version"], c["scenario"], c["registered"]) for c in cases if not c["passed"]]
    expected = [("5015", scenario, registered) for registered in [True, False] for scenario in ["drag_close", "button_close", "conversation_ready_close"]]
    passed = failures == expected
    report = {"baseline": BASE, "sources": provenance, "cases": cases, "expected_baseline_failures_only": passed,
              "limits": ["The real extracted Spring formula, settle callbacks, 9 ms Task and cancellation/sequence checks execute.", "Display cadence/time, observation delivery, UIKit receivers and state storage are controlled doubles.", "Gesture takeover uses extracted cancellation/adoption methods, not real touch recognition.", "No rendered SwiftUI hierarchy, text selection, keyboard, actual scroll geometry, refresh rate or iPhone interaction is tested.", "Source/build proof does not establish on-device smoothness."]}
    (OUT / "state-contract.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"cases": len(cases), "failures": failures, "expected_baseline_failures_only": passed, "output": str(OUT)}, ensure_ascii=False))
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
