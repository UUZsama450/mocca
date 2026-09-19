#!/usr/bin/env python3
"""Compare production 5017/current probe ownership with controlled UIKit doubles.

This is a lifecycle contract, not a UIKit timing, rendering or iPhone test.
"""
import hashlib
import json
import re
from pathlib import Path
import subprocess
import tempfile

from check_drawer_close_driver_reuse import extract, replace_probe_regions, strip_viewport_freeze_hooks

ROOT = Path(__file__).resolve().parents[1]
BASE = "2fead31c01b334f13a5a5f9bf549d69850dc176e"
OUT = ROOT / "work/verification/chat-scroll-probe-ownership"

COMMON = r'''
import Foundation
import CoreGraphics
struct Color { static let clear = Color() }
@MainActor class UIView: NSObject {
    weak var superview: UIView?
    var window: UIWindow? { (self as? UIWindow) ?? superview?.window }
    var isUserInteractionEnabled = true
    var backgroundColor: Color?
    init(frame: CGRect) { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func didMoveToSuperview() {}
    func didMoveToWindow() {}
}
@MainActor final class UIWindow: UIView {}
@MainActor @objc protocol UIScrollViewDelegate: NSObjectProtocol {
    @objc optional func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool
    @objc optional func customForwardedSelector()
}
@MainActor final class UIScrollView: UIView {
    weak var delegate: UIScrollViewDelegate?
    var writes: [String] = []
    var isScrollEnabled = true { didSet { writes.append("enabled=\(isScrollEnabled)") } }
    var scrollsToTop = true { didSet { writes.append("top=\(scrollsToTop)") } }
    struct Insets { var top: CGFloat = 0 }
    var adjustedContentInset = Insets()
    var contentOffset = CGPoint.zero
}
@MainActor final class OriginalDelegate: NSObject, UIScrollViewDelegate {
    func customForwardedSelector() {}
}
@MainActor final class Counter { var resolved = 0; var top = 0 }
@MainActor final class MainQueue {
    var pending: [() -> Void] = []
    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func drain() {
        var count = 0
        while !pending.isEmpty {
            pending.removeFirst()(); count += 1
            precondition(count < 100)
        }
    }
}
@MainActor enum DispatchQueue { static let main = MainQueue() }
@MainActor enum ChatBottomTrace { static func log(_ event: String) {} }
/*PRODUCT*/
@MainActor private struct Host {
    let window = UIWindow(frame: .zero)
    let scroll = UIScrollView(frame: .zero)
    let original = OriginalDelegate()
    init() { scroll.superview = window; scroll.delegate = original }
}
@MainActor private func configuration(_ box: WeakChatScrollViewBox, _ count: Counter) -> ChatScrollViewProbe {
    ChatScrollViewProbe(scrollViewBox: box,
        onStatusBarScrollToTop: { count.top += 1 }, onResolved: { count.resolved += 1 })
}
@MainActor private func make(_ host: Host, _ box: WeakChatScrollViewBox, _ count: Counter) -> ChatScrollViewProbeUIView {
    let probe = configuration(box, count).makeUIView(context: .init())
    probe.superview = host.scroll
    return probe
}
@MainActor private func resolve(_ probe: ChatScrollViewProbeUIView) {
    probe.didMoveToSuperview(); DispatchQueue.main.drain()
}
@MainActor private func dismantle(_ probe: ChatScrollViewProbeUIView) {
    ChatScrollViewProbe.dismantleUIView(probe, coordinator: ())
}
struct Result: Codable {
    let name: String
    let checks: [String: Bool]
    let counts: [String: Int]
}
@main struct Runner {
    @MainActor static func main() throws {
        var results: [Result] = []
        func begin() {
            DispatchQueue.main.drain(); DrawerNativeScrollGate.reset()
            DrawerNativeScrollGate.update(isDrawerPresented: true, isDrawerGestureActive: false)
        }
        func record(_ name: String, _ checks: [String: Bool], _ counts: [String: Int] = [:]) {
            results.append(Result(name: name, checks: checks, counts: counts))
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let p = make(h, box, count); resolve(p)
            let bridge = h.scroll.delegate as! ChatStatusBarScrollDelegateBridge
            let selector = #selector(UIScrollViewDelegate.customForwardedSelector)
            let forwarded = bridge.responds(to: selector) && bridge.forwardingTarget(for: selector) as? OriginalDelegate === h.original
            let bound = box.scrollView === h.scroll && !h.scroll.isScrollEnabled && !h.scroll.scrollsToTop
            _ = h.scroll.delegate?.scrollViewShouldScrollToTop?(h.scroll)
            dismantle(p); dismantle(p)
            record("single_probe_and_delegate", ["bound_and_locked": bound, "original_forwarding_kept": forwarded,
                "current_top_callback_delivered": count.top == 1,
                "cleanup_restores_host": h.scroll.isScrollEnabled && h.scroll.scrollsToTop && h.scroll.delegate === h.original,
                "cleanup_clears_box": box.scrollView == nil])
        }
        for sharedBox in [true, false] {
            begin()
            let h = Host(), oldBox = WeakChatScrollViewBox(), newBox = sharedBox ? oldBox : WeakChatScrollViewBox()
            let oldCount = Counter(), newCount = Counter()
            let old = make(h, oldBox, oldCount); resolve(old)
            let oldBridge = h.scroll.delegate as! ChatStatusBarScrollDelegateBridge
            h.scroll.writes = []
            let new = make(h, newBox, newCount); resolve(new)
            let newBridge = h.scroll.delegate
            dismantle(old)
            oldBridge.onRequest()
            record(sharedBox ? "same_host_shared_box" : "same_host_separate_boxes", [
                "new_binding_survives": newBox.scrollView === h.scroll,
                "no_unlock_roundtrip": !h.scroll.writes.contains("enabled=true") && !h.scroll.writes.contains("top=true"),
                "new_host_stays_locked": !h.scroll.isScrollEnabled && !h.scroll.scrollsToTop,
                "new_delegate_survives": h.scroll.delegate === newBridge,
                "stale_top_callback_ignored": oldCount.top == 0])
            dismantle(new)
        }
        do {
            begin()
            let a = Host(), b = Host(), box = WeakChatScrollViewBox(), ca = Counter(), cb = Counter()
            let old = make(a, box, ca); resolve(old)
            let new = make(b, box, cb); resolve(new); dismantle(old)
            record("different_hosts", ["new_binding_preserved": box.scrollView === b.scroll && !b.scroll.isScrollEnabled,
                "old_host_released": a.scroll.isScrollEnabled && a.scroll.delegate === a.original])
            dismantle(new)
        }
        do {
            begin()
            let a = Host(), b = Host(), box = WeakChatScrollViewBox(), ca = Counter(), cb = Counter()
            let old = make(a, box, ca); resolve(old)
            let new = make(b, box, cb); resolve(new)
            let before = ca.resolved
            old.scheduleResolution(); dismantle(old); DispatchQueue.main.drain()
            record("old_resolve_after_replacement", ["new_box_not_overwritten": box.scrollView === b.scroll,
                "old_callback_not_reissued": ca.resolved == before,
                "old_delegate_not_reinstalled": a.scroll.delegate === a.original,
                "old_host_not_reregistered": a.scroll.isScrollEnabled])
            dismantle(new)
        }
        for removeAncestor in [false, true] {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let p = make(h, box, count)
            p.scheduleResolution(); dismantle(p)
            if removeAncestor { p.superview = nil }
            DispatchQueue.main.drain()
            record(removeAncestor ? "teardown_without_ancestor" : "teardown_before_initial_resolve", [
                "no_binding_after_teardown": box.scrollView == nil && h.scroll.delegate === h.original,
                "no_post_teardown_callback": count.resolved == 0])
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let p = make(h, box, count); p.scheduleResolution()
            h.scroll.superview = nil; p.didMoveToWindow(); DispatchQueue.main.drain()
            let unbound = box.scrollView == nil && h.scroll.isScrollEnabled && count.resolved == 0
            h.scroll.superview = h.window; p.didMoveToWindow(); DispatchQueue.main.drain()
            record("temporary_window_leave_and_return", ["offwindow_work_ignored": unbound,
                "normal_return_binds": box.scrollView === h.scroll && !h.scroll.isScrollEnabled])
            dismantle(p)
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            var p: ChatScrollViewProbeUIView? = make(h, box, count)
            weak var observed = p
            p!.scheduleResolution(); p!.superview = nil; p = nil; DispatchQueue.main.drain()
            record("deallocation", ["queue_does_not_retain_probe": observed == nil,
                "no_callback_or_binding": count.resolved == 0 && box.scrollView == nil])
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), oldCount = Counter(), newCount = Counter()
            let old = make(h, box, oldCount); resolve(old)
            let new = make(h, box, newCount); resolve(new)
            let bridge = h.scroll.delegate
            configuration(box, oldCount).updateUIView(old, context: .init()); DispatchQueue.main.drain()
            _ = h.scroll.delegate?.scrollViewShouldScrollToTop?(h.scroll)
            record("late_old_update", ["new_delegate_keeps_ownership": h.scroll.delegate === bridge,
                "only_current_top_callback": oldCount.top == 0 && newCount.top == 1])
            dismantle(old); dismantle(new)
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let p = make(h, box, count)
            p.didMoveToSuperview(); p.didMoveToWindow(); configuration(box, count).updateUIView(p, context: .init())
            let pending = DispatchQueue.main.pending.count; DispatchQueue.main.drain()
            record("pending_resolution_coalesced", ["single_pending_resolve": pending == 1,
                "one_ready_callback": count.resolved == 1, "binding_ready": box.scrollView === h.scroll],
                ["pending": pending, "ready_calls": count.resolved])
            dismantle(p)
        }
        do {
            begin()
            let h = Host(), oldBox = WeakChatScrollViewBox(), newBox = WeakChatScrollViewBox(), oldCount = Counter(), newCount = Counter()
            let p = make(h, oldBox, oldCount); resolve(p); h.scroll.writes = []
            configuration(newBox, newCount).updateUIView(p, context: .init()); DispatchQueue.main.drain()
            let moved = oldBox.scrollView == nil && newBox.scrollView === h.scroll
            let continuous = !h.scroll.writes.contains("enabled=true") && !h.scroll.writes.contains("top=true")
            _ = h.scroll.delegate?.scrollViewShouldScrollToTop?(h.scroll)
            dismantle(p)
            record("box_change", ["box_owner_transferred": moved, "gate_not_unlocked": continuous,
                "new_callback_used": newCount.top == 1 && oldCount.top == 0,
                "both_boxes_released": oldBox.scrollView == nil && newBox.scrollView == nil])
        }
        for destinationIsScroll in [true, false] {
            begin()
            let a = Host(), b = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let container = UIView(frame: .zero); container.superview = a.scroll
            let p = make(a, box, count); p.superview = container; resolve(p)
            container.superview = destinationIsScroll ? b.scroll : b.window
            configuration(box, count).updateUIView(p, context: .init()); DispatchQueue.main.drain()
            record(destinationIsScroll ? "ancestor_host_change" : "ancestor_host_removed", [
                "old_host_released": a.scroll.isScrollEnabled && a.scroll.delegate === a.original,
                "binding_matches_current_ancestor": destinationIsScroll ? box.scrollView === b.scroll : box.scrollView == nil])
            dismantle(p)
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let p = make(h, box, count); resolve(p); let before = count.resolved; dismantle(p)
            h.scroll.superview = nil; p.didMoveToWindow()
            h.scroll.superview = h.window; p.didMoveToWindow()
            configuration(box, count).updateUIView(p, context: .init()); DispatchQueue.main.drain()
            record("dismantled_is_terminal", ["late_hooks_cannot_rebind": box.scrollView == nil && h.scroll.delegate === h.original,
                "late_hooks_cannot_signal_ready": count.resolved == before])
        }
        for sharedBox in [true, false] {
            begin()
            let h = Host(), oldBox = WeakChatScrollViewBox(), newBox = sharedBox ? oldBox : WeakChatScrollViewBox(), ca = Counter(), cb = Counter()
            let older = make(h, oldBox, ca) // Created earlier, resolves later.
            let newer = make(h, newBox, cb); resolve(newer)
            let bridge = h.scroll.delegate
            resolve(older)
            record(sharedBox ? "older_initial_resolve_shared_box" : "older_initial_resolve_separate_boxes", [
                "newer_live_binding_not_preempted": h.scroll.delegate === bridge && newBox.scrollView === h.scroll,
                "older_ready_not_delivered": ca.resolved == 0])
            dismantle(newer)
            // This probe was never dismantled: a fresh mount/update can bind
            // after the competing registration has actually gone away.
            configuration(oldBox, ca).updateUIView(older, context: .init()); DispatchQueue.main.drain()
            record(sharedBox ? "live_probe_can_bind_after_release_shared_box" : "live_probe_can_bind_after_release_separate_boxes", [
                "fresh_request_can_bind": oldBox.scrollView === h.scroll && !h.scroll.isScrollEnabled])
            dismantle(older)
        }
        do {
            begin()
            let h = Host(), box = WeakChatScrollViewBox(), count = Counter()
            let p = make(h, box, count); resolve(p)
            h.scroll.isScrollEnabled = true; h.scroll.scrollsToTop = true
            configuration(box, count).updateUIView(p, context: .init())
            let repaired = !h.scroll.isScrollEnabled && !h.scroll.scrollsToTop
            h.scroll.writes = []
            for _ in 0..<100 { configuration(box, count).updateUIView(p, context: .init()) }
            record("same_owner_refresh", ["external_state_drift_repaired": repaired,
                "repeat_does_not_write_native_state": h.scroll.writes.isEmpty,
                "repeat_does_not_queue_or_signal_ready": DispatchQueue.main.pending.isEmpty && count.resolved == 1])
            dismantle(p)
        }
        print(String(decoding: try JSONEncoder().encode(results), as: UTF8.self))
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
    new = (ROOT / "Mocca/RootView.swift").read_text()
    gate_pattern = r"^@MainActor\nprivate enum DrawerNativeScrollGate\b"
    old_gate, _ = extract(old, gate_pattern)
    new_gate, _ = extract(new, gate_pattern)
    assert strip_viewport_freeze_hooks(replace_probe_regions(old, new).replace(old_gate, new_gate, 1)) == strip_viewport_freeze_hooks(new), "Unrelated product source changed"
    bridge_pattern = r"^private final class ChatStatusBarScrollDelegateBridge\b"
    assert extract(old, bridge_pattern)[0] == extract(new, bridge_pattern)[0], "Original delegate bridge changed"
    version = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", (ROOT / "Mocca.xcodeproj/project.pbxproj").read_text()).group(1)
    cases, sources = [], {}
    for label, root in (("5017", old), (version, new)):
        parts, locations = [], {}
        patterns = [r"^@MainActor\nprivate final class WeakChatScrollViewBox\b", gate_pattern,
                    r"^private struct ChatScrollViewProbe\b",
                    r"^private final class ChatScrollViewProbeUIView\b", bridge_pattern]
        if label != "5017":
            patterns.append(r"^@MainActor\nprivate final class ChatScrollViewRegistration\b")
        for pattern in patterns:
            part, lines = extract(root, pattern)
            locations[pattern] = lines
            if ": UIViewRepresentable {" in part:
                part = "@MainActor\n" + part.replace(": UIViewRepresentable {", "{\n    struct Context {}", 1)
            parts.append(part)
        source = COMMON.replace("/*PRODUCT*/", "\n".join(parts))
        file = OUT / f"ownership-{label}.swift"; file.write_text(source)
        with tempfile.TemporaryDirectory(prefix="chat-scroll-owner-") as tmp:
            binary = Path(tmp) / "contract"
            build = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(Path(tmp) / "ModuleCache"), str(file), "-o", str(binary)], capture_output=True, text=True, timeout=180)
            (OUT / f"ownership-{label}-build.log").write_text(build.stdout + build.stderr)
            if build.returncode: raise SystemExit(build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            (OUT / f"ownership-{label}-run.log").write_text(run.stdout + run.stderr)
            run.check_returncode()
        for case in json.loads(run.stdout):
            case.update(version=label, passed=all(case["checks"].values()))
            cases.append(case)
        sources[label] = {"root_sha256": hashlib.sha256(root.encode()).hexdigest(), "harness_sha256": hashlib.sha256(source.encode()).hexdigest(), "extracted_lines": locations}
    expected_old_failures = {"same_host_shared_box", "same_host_separate_boxes", "old_resolve_after_replacement",
        "teardown_before_initial_resolve", "temporary_window_leave_and_return", "late_old_update", "pending_resolution_coalesced",
        "box_change", "ancestor_host_change", "ancestor_host_removed", "dismantled_is_terminal",
        "older_initial_resolve_shared_box", "older_initial_resolve_separate_boxes"}
    failures = [(c["version"], c["name"], [k for k, v in c["checks"].items() if not v]) for c in cases if not c["passed"]]
    current_cases = [c for c in cases if c["version"] == version]
    passed = len(current_cases) == 20 and all(c["passed"] for c in current_cases) and {c["name"] for c in cases if c["version"] == "5017" and not c["passed"]} == expected_old_failures
    report = {"baseline": BASE, "sources": sources, "cases": cases, "expected_baseline_failures_only": passed,
              "limits": ["Production lifecycle/registration/gate/box/delegate method bodies execute on UIKit doubles and an explicit FIFO queue.",
                         "The doubles expose property state and ownership; UIKit setter effects, SwiftUI lifecycle timing and actual gesture behavior are not measured.",
                         "onResolved and top callbacks count deliveries; real message mutation/navigation is not run.",
                         "Temporary-window and teardown event orders are controlled inputs, not measured occurrence rates on the phone.",
                         "No iPhone performance or interaction acceptance is claimed."]}
    (OUT / "ownership-contract.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"cases": len(cases), "failures": failures, "expected_baseline_failures_only": passed}, ensure_ascii=False))
    if not passed: raise SystemExit(1)


if __name__ == "__main__":
    main()
