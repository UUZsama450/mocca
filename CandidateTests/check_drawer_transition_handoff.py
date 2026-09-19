#!/usr/bin/env python3
"""Compose actual Root methods, Spring driver and refresh lease across handoffs.

The 5024 baseline must expose both reviewed gaps. UIKit receivers, display-link
delivery, Observation delivery and state storage are controlled doubles. This
does not measure rendered frames, scene delivery or physical-device performance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from check_drawer_close_driver_reuse import COMMON, RUNNER, extract, method

ROOT = Path(__file__).resolve().parents[1]
BASE = "61f64602f8fa7675041fb7810c718195b442b780"
OUT = ROOT / "work/verification/drawer-transition-handoff/contracts"


def harness(root, markdown, model):
    declarations = [extract(markdown, r"^@MainActor\nenum DrawerViewportRefreshFreeze\b")[0]]
    declarations.append("""
@MainActor final class GlyphSelectableTextView: NSObject {
    var resumes = 0
    var onResume: (() -> Void)?
    func resumeDrawerViewportDrawing() { resumes += 1; onResume?() }
}
""")
    declarations.append(extract(root, r"^@MainActor\nprivate protocol DrawerLivePanelMotionReceiver\b")[0])
    for name in ["DrawerSettleDisplayLinkDriver", "DrawerNativeScrollGate", "DrawerPresentationProgressTracker", "DrawerDetachedMainPanelProgress", "DrawerFingerTrackingProgress", "DrawerInlineActionTapGate"]:
        declarations.append(extract(root, rf"^@MainActor\n(?:@Observable\n)?(?:private )?(?:final class|enum) {name}\b")[0])
    names = ["cancelDrawerSettleWork", "startDrawerSettleProgress", "adoptDrawerPresentationProgressForRoot", "setDrawerGestureActive", "syncDrawerNativeScrollGate", "openDrawerFromButton", "closeDrawerAnimated", "requestDrawerCloseAfterConversationReady", "handleConversationContentReady", "continueDrawerCloseAfterExternalSemanticChange", "settleDrawer", "finishInterruptedDrawerInteraction"]
    methods = "\n".join(method(root, name)[0].replace("private func", "func", 1) for name in names)
    observer = extract(root, r"^        \.onChange\(of: model.isDrawerPresented\)")[0]
    observer = "func observe(_ isPresented: Bool) {" + observer.split(" in\n", 1)[1]
    disappear = extract(root, r"^        \.onDisappear\b")[0]
    disappear = "func disappear() {" + disappear.split("{", 1)[1]
    coordinator = "\n".join(method(root, name)[0] for name in ["setDrawerGestureLockActive", "releaseImmediateInteractionLock", "setStatusBarScrollToTopEnabled"])
    common = COMMON.replace("@MainActor enum DrawerInlineActionTapGate { static func reset() {} }", "")
    common = common.replace("static func rootDidDisappear() {}", "static func rootDidDisappear() {}; static func sceneDidDeactivate() {}")
    common = common.replace("func performHaptic(_ value: Haptic) {}", "var haptics = 0; func performHaptic(_ value: Haptic) { haptics += 1 }")
    common = common.replace("Clock.now = 100; CADisplayLink.links = []", "DrawerViewportRefreshFreeze.reset(); Clock.now = 100; CADisplayLink.links = []")
    facade = extract(root, r"^    private var drawerDragProgress:")[0].replace("private var", "var", 1)
    common = common.replace("    @Box var drawerDragProgress: CGFloat? = nil", "    let drawerFingerProgress = DrawerFingerTrackingProgress()\n" + facade + "\n    @Box var drawerGestureLocked: Bool? = nil\n    @Box var drawerDragStartProgress: CGFloat = 0\n    @Box var drawerDragActivationTranslationX: CGFloat = 0")
    return common.replace("/*MODEL*/", method(model, "setDrawerPresented")[0]).replace("/*COORDINATOR*/", coordinator).replace("/*DECLARATIONS*/", "\n".join(declarations)).replace("/*METHODS*/", methods).replace("/*OBSERVER*/", observer).replace("/*DISAPPEAR*/", disappear)


COMPOSITE_RUNNER = r'''
// Observe the receiver that the actual presentation tracker still drives.
// The removed imperative drawer-fade sink is no longer a product endpoint.
@MainActor final class HandoffMotionReceiver: DrawerLivePanelMotionReceiver {
    var lastProgress: CGFloat?
    func applyDrawerProgress(_ progress: CGFloat) { lastProgress = progress }
}
struct Row: Codable {
    let group: String
    let name: String
    let checks: [String: Bool]
}
@main struct Runner {
    @MainActor static func main() async throws {
        var rows: [Row] = []
        for registered in [false, true] {
            for route in ["button_reverse", "external_rejoin", "retarget_open", "retarget_close"] {
                for progress: CGFloat in [0.2, 0.6, 0.9] {
                    let h = Harness(presented: true, registered: registered, progress: progress)
                    let panel = HandoffMotionReceiver()
                    h.drawerPresentationProgressTracker.attach(panel)
                    if route == "external_rejoin" { h.startDrawerSettleProgress(from: progress, to: 1) }
                    else { h.settleDrawer(open: false) }
                    let oldLink = CADisplayLink.links.last!
                    oldLink.fire(at: 100.004)
                    if route == "button_reverse" {
                        try await Task.sleep(for: .milliseconds(35))
                        h.deliverChanges()
                        precondition(!h.model.isDrawerPresented)
                    }
                    let sample = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                    let pending = GlyphSelectableTextView()
                    var resumePositions: [CGFloat] = []
                    pending.onResume = { resumePositions.append(h.drawerPresentationProgressTracker.resolved(fallback: -1)) }
                    DrawerViewportRefreshFreeze.deferRefresh(pending)
                    DrawerViewportRefreshFreeze.deferRefresh(pending)
                    let generation = DrawerViewportRefreshFreeze.generation
                    let opens = route == "button_reverse" || route == "retarget_open"
                    let endpoint: CGFloat = opens ? 1 : 0
                    switch route {
                    case "button_reverse": h.openDrawerFromButton()
                    case "external_rejoin": h.model.setDrawerPresented(false); h.deliverChanges()
                    default: h.settleDrawer(open: opens)
                    }
                    var checks = [
                        "no_premature_refresh": pending.resumes == 0,
                        "continuous_generation": DrawerViewportRefreshFreeze.generation == generation,
                        "new_driver_owns_freeze": DrawerViewportRefreshFreeze.isActive && h.drawerSettleDriver.activeTargetProgress == endpoint,
                        "sample_preserved": h.detachedMainPanelProgress.progress == sample,
                        "one_replacement": oldLink.invalidated && CADisplayLink.links.count == 2
                    ]
                    oldLink.fire(at: 101)
                    checks["stale_link_cannot_move"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == sample
                    let sequence = h.drawerSettleSequence
                    try await Task.sleep(for: .milliseconds(35))
                    h.deliverChanges()
                    checks["semantic_task_and_observer_keep_new_owner"] = h.model.isDrawerPresented == opens && h.drawerSettleSequence == sequence && CADisplayLink.links.count == 2
                    DrawerViewportRefreshFreeze.deferRefresh(pending)
                    let currentLink = CADisplayLink.links.last!
                    currentLink.fire(at: 100.050)
                    let expected = sample + SwiftUI.Spring(response: 0.42, dampingRatio: 0.92)
                        .value(target: endpoint - sample, initialVelocity: CGFloat.zero, time: 0.046)
                    checks["same_spring_formula"] = abs(h.drawerPresentationProgressTracker.resolved(fallback: -1) - expected) < 0.000001
                    currentLink.fire(at: 100.800)
                    checks["one_refresh_at_endpoint"] = pending.resumes == 1 && resumePositions == [endpoint]
                    checks["settle_cleanup"] = !DrawerViewportRefreshFreeze.isActive && h.drawerSettleDriver.activeTargetProgress == nil && !h.detachedMainPanelProgress.isActive
                    checks["endpoint_and_scroll_gate"] = h.drawerPresentationProgressTracker.resolved(fallback: -1) == endpoint && panel.lastProgress == endpoint && h.model.streamingSuspended == opens && (!registered || h.chat.isScrollEnabled == !opens) && h.list.isScrollEnabled
                    rows.append(Row(group: "handoff", name: "\(route)-\(progress)-registered=\(registered)", checks: checks))
                    h.disappear()
                }
            }
            for readyAfterDuplicateInterruption in [false, true] {
                let h = Harness(presented: true, registered: registered, progress: 1)
                h.model.streamingSuspended = true
                h.model.preferences.hapticsOnDrawer = true
                let selected = h.model.selectedConversationID!
                h.requestDrawerCloseAfterConversationReady(selected)
                precondition(h.pendingDrawerCloseConversationID == selected)
                let sequence = h.drawerSettleSequence
                h.finishInterruptedDrawerInteraction()
                if readyAfterDuplicateInterruption { h.finishInterruptedDrawerInteraction() }
                var checks = ["pending_cancelled": h.pendingDrawerCloseConversationID == nil]
                h.handleConversationContentReady(selected)
                try await Task.sleep(for: .milliseconds(35))
                h.deliverChanges()
                checks["late_ready_cannot_start_close"] = CADisplayLink.links.isEmpty && h.drawerSettleDriver.activeTargetProgress == nil && h.drawerSettleSequence == sequence
                checks["stable_state_retained"] = h.model.isDrawerPresented && h.model.streamingSuspended && h.drawerPresentationProgressTracker.resolved(fallback: -1) == 1 && h.model.haptics == 0
                checks["selection_retained"] = h.model.selectedConversationID == selected
                rows.append(Row(group: "pending", name: "pending-only-duplicate=\(readyAfterDuplicateInterruption)-registered=\(registered)", checks: checks))
                h.disappear()
            }
            // A fresh user selection after interruption must still close once
            // its own content is ready; an unrelated/duplicate ready cannot.
            let h = Harness(presented: true, registered: registered, progress: 1)
            let oldID = h.model.selectedConversationID!
            h.requestDrawerCloseAfterConversationReady(oldID)
            h.finishInterruptedDrawerInteraction()
            let newID = UUID()
            h.model.selectedConversationID = newID
            h.requestDrawerCloseAfterConversationReady(newID)
            h.handleConversationContentReady(oldID)
            var checks = ["unrelated_ready_ignored": CADisplayLink.links.isEmpty && h.pendingDrawerCloseConversationID == newID]
            h.handleConversationContentReady(newID)
            h.handleConversationContentReady(newID)
            checks["fresh_request_closes_once"] = CADisplayLink.links.count == 1 && h.pendingDrawerCloseConversationID == nil
            try await Task.sleep(for: .milliseconds(35))
            h.deliverChanges()
            CADisplayLink.links.last!.fire(at: 100.800)
            checks["new_selection_and_endpoint"] = h.model.selectedConversationID == newID && !h.model.isDrawerPresented && h.drawerPresentationProgressTracker.resolved(fallback: -1) == 0 && !DrawerViewportRefreshFreeze.isActive
            rows.append(Row(group: "control", name: "fresh-selection-registered=\(registered)", checks: checks))
            h.disappear()
            for open in [false, true] {
                for ending in ["complete", "interrupt", "disappear"] {
                    let h = Harness(presented: !open, registered: registered, progress: open ? 0 : 1)
                    let generation = DrawerViewportRefreshFreeze.generation
                    if open { h.openDrawerFromButton() } else { h.closeDrawerAnimated() }
                    let view = GlyphSelectableTextView()
                    DrawerViewportRefreshFreeze.deferRefresh(view)
                    var checks = ["cold_start_acquires_freeze": DrawerViewportRefreshFreeze.generation == generation + 1 && DrawerViewportRefreshFreeze.isActive]
                    if ending == "complete" { CADisplayLink.links.last!.fire(at: 100.800) }
                    else if ending == "interrupt" { h.finishInterruptedDrawerInteraction() }
                    else { h.disappear() }
                    checks["ending_releases_once"] = !DrawerViewportRefreshFreeze.isActive && view.resumes == 1 && h.drawerSettleDriver.activeTargetProgress == nil
                    rows.append(Row(group: "control", name: "cold-\(open)-\(ending)-registered=\(registered)", checks: checks))
                    h.disappear()
                }
            }
        }
        print(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))
    }
}
'''


def run(label, source):
    path = OUT / f"{label}.swift"
    path.write_text(source)
    with (OUT / f"{label}-compile.log").open("w") as log:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(path), "-o", str(OUT / label)], stdout=log, stderr=log, check=True)
    result = subprocess.run([str(OUT / label)], capture_output=True, text=True, timeout=40)
    (OUT / f"{label}-run.log").write_text(result.stdout + result.stderr)
    result.check_returncode()
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=["baseline", "handoff", "all"], default="all")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    report = {"baseline": BASE, "stage": args.stage, "sources": {}, "limits": __doc__}
    for label in ["5024", args.stage]:
        def read(path):
            return subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT, text=True) if label == "5024" else (ROOT / path).read_text()
        root, markdown, model = [read(path) for path in ["Mocca/RootView.swift", "Mocca/MessageMarkdownView.swift", "Mocca/AppModel.swift"]]
        common = harness(root, markdown, model)
        rows = run(label, common + COMPOSITE_RUNNER)
        regression = run(label + "-existing", common + RUNNER)
        failures = [{"name": row["name"], "group": row["group"], "checks": [key for key, value in row["checks"].items() if not value]} for row in rows if not all(row["checks"].values())]
        expected_groups = {"handoff", "pending"} if label in ["5024", "baseline"] else {"pending"} if label == "handoff" else set()
        expected_names = {row["name"] for row in rows if row["group"] in expected_groups}
        report[ label ] = {"cases": rows, "existing_regression": regression, "failures": failures}
        report["sources"][label] = {"root_sha256": hashlib.sha256(root.encode()).hexdigest(), "harness_sha256": hashlib.sha256((common + COMPOSITE_RUNNER).encode()).hexdigest()}
        (OUT / f"result-{args.stage}.json").write_text(json.dumps(report, indent=2) + "\n")
        assert {row["name"] for row in failures} == expected_names, failures
        for row in failures:
            expected = {"no_premature_refresh", "continuous_generation", "one_refresh_at_endpoint"} if row["group"] == "handoff" else {"pending_cancelled", "late_ready_cannot_start_close", "stable_state_retained"}
            assert set(row["checks"]) == expected, row
        assert all(all(row["checks"].values()) for row in regression), regression
        print(json.dumps({"source": label, "composite_cases": len(rows), "existing_cases": len(regression), "expected_failures": len(failures), "matched_expectation": True}), flush=True)


if __name__ == "__main__":
    main()
