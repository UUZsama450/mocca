#!/usr/bin/env python3
"""Run actual drawer gesture bodies against pending ready and settle ownership.

The complete production onChanged/onEnded bodies are wrapped as callable methods,
without changing their statements. Spring, ready, cancellation, phase freeze and
9 ms semantic-close work are real extracted code. Drag values, selection/scroll
hit-test gates, scene delivery, UIKit receivers and display cadence are controlled.
This does not exercise recognizer delivery, rendered content, or phone performance.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess

from check_drawer_transition_handoff import harness
from check_drawer_close_driver_reuse import extract, method

ROOT = Path(__file__).resolve().parents[1]
BASE = "c79ef3ab396fc121245204243f2fb1ccef200100"
OUT = ROOT / "work/verification/drawer-ready-gesture-5031"


def make_harness(root, markdown, model):
    source = harness(root, markdown, model)
    source = source.replace(
        "@MainActor enum DrawerFrameTrace { static func rootDidDisappear() {}; static func sceneDidDeactivate() {} }",
        "@MainActor enum DrawerFrameTrace { static func rootDidDisappear() {}; static func sceneDidDeactivate() {}; static func begin(startProgress: CGFloat, logicalStartProgress: CGFloat) {}; static func touchEnded(finalProgress: CGFloat?) {} }")
    source = source.replace(
        "@MainActor enum DrawerHighRefreshLease { static func stop() {} }",
        "@MainActor enum DrawerHighRefreshLease { static func stop() {}; static func begin() {}; static func releaseAfterSettle() {} }")
    source = source.replace("    var streamingSuspended = false", "    var streamingSuspended = false\n    var isComposerFocused = false")
    source = source.replace("    func finishSoftTopReturnForDrawerOpening() {}", "    func finishSoftTopReturnForDrawerOpening() {}\n    func beginSoftTopReturnIfNeeded() {}")
    source = source.replace("    @Box var pendingDrawerCloseConversationID: UUID? = nil", "    @Box var pendingDrawerCloseConversationID: UUID? = nil\n    @Box var scenePhase: ScenePhase = .active")
    source = source.replace("DrawerViewportRefreshFreeze.reset(); Clock.now = 100", "DrawerViewportRefreshFreeze.reset(); DrawerInlineActionTapGate.reset(); TouchGates.reset(); Clock.now = 100")
    constants = "\n".join(re.search(r"^    private let " + name + r": CGFloat = [\d.]+", root, re.M).group().replace("private ", "", 1)
                          for name in ["drawerGestureIntentDistance", "drawerGestureAxisRatio"])
    source = source.replace("    let model = Model()", constants + "\n    let model = Model()")
    gesture, location = method(root, "drawerDragGesture")
    wrappers, extracted_bodies = [], {}
    for event in ["onChanged", "onEnded"]:
        closure = extract(gesture, r"^            \." + event + r"\b")[0]
        body = closure.split("{ value in\n", 1)[1]
        # Only the closure signature changes. The complete body, including defer,
        # every guard, and its closing brace, remains byte-for-byte identical.
        wrapper = ("    func " + event + "(_ value: DragValue, drawerWidth: CGFloat = 300, baseProgress: CGFloat = 1, finishesOpeningSettleForVerticalIntent: Bool = false) {\n" + body)
        assert wrapper.split(" {\n", 1)[1] == body
        wrappers.append(wrapper)
        extracted_bodies[event] = hashlib.sha256(body.encode()).hexdigest()
    vertical = method(root, "finishDrawerOpeningSettleForVerticalIntentIfNeeded")[0].replace("private func", "func", 1)
    source += "\nextension Harness {\n" + "\n".join(wrappers + [vertical]) + "\n}\n"
    # Read-only observation: save the actual old Root closures so their sequence
    # guards can be called after cancellation. No production callback is replaced.
    source += """
extension DrawerSettleDisplayLinkDriver {
    func callbacksForTest() -> (((CGFloat) -> Void)?, (() -> Void)?) { (onProgress, onCompletion) }
}
struct DragValue {
    let translation: CGSize
    let predictedEndTranslation: CGSize
    init(_ x: CGFloat, _ y: CGFloat = 0, predicted: CGFloat? = nil) {
        translation = CGSize(width: x, height: y)
        predictedEndTranslation = CGSize(width: predicted ?? x, height: y)
    }
}
@MainActor enum ComposerTextSelectionInteractionGate { static var ownsCurrentTouch = false }
@MainActor enum DrawerTextSelectionInteractionGate { static var ownsCurrentTouch = false }
@MainActor enum DrawerHorizontalScrollGate { static var ownsCurrentTouch = false }
@MainActor enum TouchGates {
    static func reset() {
        ComposerTextSelectionInteractionGate.ownsCurrentTouch = false
        DrawerTextSelectionInteractionGate.ownsCurrentTouch = false
        DrawerHorizontalScrollGate.ownsCurrentTouch = false
    }
}
"""
    return source, {"gesture_lines": location, "body_sha256": extracted_bodies}


RUNNER = r'''
struct Row: Codable {
    let scenario: String
    let registered: Bool
    let checks: [String: Bool]
    let events: [String]
}
@main struct Runner {
    @MainActor static func main() async throws {
        var rows: [Row] = []
        func record(_ name: String, _ registered: Bool, _ checks: [String: Bool]) {
            rows.append(Row(scenario: name, registered: registered, checks: checks, events: VersionFlashTrace.events))
        }
        func near(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) < 0.000001 } ?? false }
        for registered in [false, true] {
            for open in [false, true] {
                let h = Harness(presented: true, registered: registered, progress: 1)
                let selected = h.model.selectedConversationID!
                h.requestDrawerCloseAfterConversationReady(selected)
                h.onChanged(DragValue(-20))
                var checks = [
                    "horizontal_recognition_takes_ownership": h.drawerGestureLocked == true && h.isDrawerGestureActive && near(h.drawerDragProgress, 1),
                    "pending_cancelled_at_recognition": h.pendingDrawerCloseConversationID == nil,
                    "selection_retained": h.model.selectedConversationID == selected
                ]
                h.onChanged(DragValue(-80))
                let heldProgress = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                let heldSequence = h.drawerSettleSequence
                let view = GlyphSelectableTextView()
                DrawerViewportRefreshFreeze.deferRefresh(view)
                h.handleConversationContentReady(UUID())
                h.handleConversationContentReady(selected)
                h.handleConversationContentReady(selected)
                checks["held_ready_never_starts_driver"] = CADisplayLink.links.isEmpty && h.drawerSettleDriver.activeTargetProgress == nil && h.drawerSettleSequence == heldSequence
                // Native list drawing applies SwiftUI's scrollDisabled later;
                // this host observes its real ownership/status-bar gate here.
                checks["held_ready_keeps_finger_and_scroll_lock"] = h.isDrawerGestureActive && h.drawerGestureLocked == true && near(h.drawerDragProgress, heldProgress) && h.drawerListTopReturnCoordinator.isDrawerGestureLockActive && !h.drawerListTopReturnCoordinator.isStatusBarScrollToTopEnabled && (!registered || !h.chat.isScrollEnabled)
                checks["held_ready_keeps_refresh_frozen"] = DrawerViewportRefreshFreeze.isActive && view.resumes == 0
                h.onChanged(DragValue(-110))
                checks["continued_move_has_only_finger_owner"] = near(h.drawerDragProgress, 0.7) && h.isDrawerGestureActive && h.drawerSettleDriver.activeTargetProgress == nil
                try await Task.sleep(for: .milliseconds(35))
                h.deliverChanges()
                checks["held_ready_has_no_delayed_semantic_close"] = h.model.isDrawerPresented
                let value = open ? DragValue(-110, predicted: -20) : DragValue(-240, predicted: -330)
                h.onChanged(value)
                h.onEnded(value)
                checks["end_uses_requested_direction"] = h.drawerSettleDriver.activeTargetProgress == (open ? 1 : 0)
                checks["end_clears_finger_once"] = h.drawerGestureLocked == nil && !h.isDrawerGestureActive && h.drawerDragActivationTranslationX == 0
                try await Task.sleep(for: .milliseconds(35))
                h.deliverChanges()
                CADisplayLink.links.last?.fire(at: 100.8)
                checks["endpoint_and_freeze_cleanup"] = near(h.drawerPresentationProgressTracker.resolved(fallback: -1), open ? 1 : 0) && h.model.isDrawerPresented == open && !DrawerViewportRefreshFreeze.isActive && view.resumes == 1 && h.drawerSettleDriver.activeTargetProgress == nil
                record("pending-horizontal-held-ready-end-\(open ? "open" : "close")", registered, checks)
                h.disappear()
            }

            for rejected in ["under-threshold", "undecided-diagonal", "vertical", "selected-text", "horizontal-scroll", "composer-selection", "inactive-scene"] {
                let h = Harness(presented: true, registered: registered, progress: 1)
                let selected = h.model.selectedConversationID!
                h.requestDrawerCloseAfterConversationReady(selected)
                var value = DragValue(-24)
                switch rejected {
                case "under-threshold": value = DragValue(-10)
                case "undecided-diagonal": value = DragValue(-20, 15)
                case "vertical": value = DragValue(-3, 25)
                case "selected-text": DrawerTextSelectionInteractionGate.ownsCurrentTouch = true
                case "horizontal-scroll": DrawerHorizontalScrollGate.ownsCurrentTouch = true
                case "composer-selection": h.model.isComposerFocused = true; ComposerTextSelectionInteractionGate.ownsCurrentTouch = true
                default: h.scenePhase = .inactive
                }
                h.onChanged(value)
                var checks = [
                    "rejected_touch_does_not_cancel_pending": h.pendingDrawerCloseConversationID == selected,
                    "rejected_touch_does_not_own_drawer": h.drawerGestureLocked != true && !h.isDrawerGestureActive && CADisplayLink.links.isEmpty
                ]
                h.onEnded(value)
                checks["rejected_end_keeps_pending"] = h.pendingDrawerCloseConversationID == selected && h.drawerGestureLocked == nil
                h.scenePhase = .active
                h.handleConversationContentReady(selected)
                checks["retained_ready_closes_normally"] = CADisplayLink.links.count == 1 && h.drawerSettleDriver.activeTargetProgress == 0
                try await Task.sleep(for: .milliseconds(35)); h.deliverChanges()
                CADisplayLink.links.last?.fire(at: 100.8)
                checks["normal_close_endpoint"] = !h.model.isDrawerPresented && near(h.drawerPresentationProgressTracker.resolved(fallback: -1), 0)
                record("rejection-\(rejected)", registered, checks)
                h.disappear()
            }

            for phase in ["before-semantic-close", "after-semantic-close", "after-close-completion"] {
                let h = Harness(presented: true, registered: registered, progress: 1)
                let selected = h.model.selectedConversationID!
                h.requestDrawerCloseAfterConversationReady(selected)
                h.handleConversationContentReady(selected)
                let oldLink = CADisplayLink.links.last!
                let callbacks = h.drawerSettleDriver.callbacksForTest()
                oldLink.fire(at: 100.004)
                var checks = ["ready_without_gesture_starts_close": h.drawerSettleDriver.activeTargetProgress == 0 && h.pendingDrawerCloseConversationID == nil]
                if phase != "before-semantic-close" {
                    try await Task.sleep(for: .milliseconds(35)); h.deliverChanges()
                    oldLink.fire(at: phase == "after-close-completion" ? 100.8 : 100.08)
                }
                checks["requested_semantic_phase_was_exercised"] = h.model.isDrawerPresented == (phase == "before-semantic-close")
                let sample = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                let base: CGFloat = h.model.isDrawerPresented ? 1 : 0
                h.onChanged(DragValue(20), baseProgress: base)
                checks["regrab_adopts_actual_sample"] = near(h.drawerDragProgress, sample) && h.isDrawerGestureActive && h.drawerGestureLocked == true && oldLink.invalidated && h.drawerSettleDriver.activeTargetProgress == nil
                callbacks.0?(0); callbacks.1?(); oldLink.fire(at: 102)
                h.handleConversationContentReady(selected)
                try await Task.sleep(for: .milliseconds(35)); h.deliverChanges()
                checks["old_callbacks_and_9ms_task_cannot_reclaim"] = near(h.drawerDragProgress, sample) && h.isDrawerGestureActive && h.drawerSettleDriver.activeTargetProgress == nil && h.model.isDrawerPresented == (phase == "before-semantic-close")
                h.onChanged(DragValue(280), baseProgress: base)
                h.onEnded(DragValue(280, predicted: 330), baseProgress: base)
                let newLink = CADisplayLink.links.last!
                let replacementSample = h.drawerPresentationProgressTracker.resolved(fallback: -1)
                callbacks.0?(0); callbacks.1?()
                checks["old_root_callbacks_cannot_finish_replacement"] = h.drawerSettleDriver.activeTargetProgress == 1 && !newLink.invalidated && near(h.drawerPresentationProgressTracker.resolved(fallback: -1), replacementSample)
                newLink.fire(at: Clock.now + 0.8)
                checks["regrab_finishes_open"] = h.model.isDrawerPresented && near(h.drawerPresentationProgressTracker.resolved(fallback: -1), 1) && !DrawerViewportRefreshFreeze.isActive && h.drawerGestureLocked == nil
                record("ready-then-regrab-\(phase)", registered, checks)
                h.disappear()
            }

            for ownsFinger in [false, true] {
                let h = Harness(presented: true, registered: registered, progress: 1)
                let oldID = h.model.selectedConversationID!
                h.requestDrawerCloseAfterConversationReady(oldID)
                if ownsFinger { h.onChanged(DragValue(-20)); h.onChanged(DragValue(-65)) }
                h.scenePhase = .inactive
                h.finishInterruptedDrawerInteraction()
                h.finishInterruptedDrawerInteraction()
                let sequence = h.drawerSettleSequence
                h.handleConversationContentReady(oldID)
                h.onChanged(DragValue(-120))
                var checks = [
                    "background_cancels_pending_and_ownership": h.pendingDrawerCloseConversationID == nil && h.drawerGestureLocked == nil && !h.isDrawerGestureActive && h.drawerSettleDriver.activeTargetProgress == nil,
                    "inactive_events_cannot_restart": h.drawerSettleSequence == sequence && CADisplayLink.links.isEmpty,
                    "background_keeps_selection": h.model.selectedConversationID == oldID
                ]
                h.scenePhase = .active
                let newID = UUID(); h.model.selectedConversationID = newID
                h.requestDrawerCloseAfterConversationReady(newID)
                h.handleConversationContentReady(oldID)
                checks["old_ready_cannot_consume_new_selection"] = h.pendingDrawerCloseConversationID == newID && CADisplayLink.links.isEmpty
                h.handleConversationContentReady(newID); h.handleConversationContentReady(newID)
                checks["new_selection_closes_once"] = CADisplayLink.links.count == 1 && h.pendingDrawerCloseConversationID == nil
                try await Task.sleep(for: .milliseconds(35)); h.deliverChanges()
                CADisplayLink.links.last?.fire(at: 100.8)
                checks["new_selection_endpoint"] = !h.model.isDrawerPresented && h.model.selectedConversationID == newID && near(h.drawerPresentationProgressTracker.resolved(fallback: -1), 0) && !DrawerViewportRefreshFreeze.isActive
                record("background-new-selection-finger=\(ownsFinger)", registered, checks)
                h.disappear()
            }
        }
        print(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {"baseline": BASE, "limits": __doc__, "results": {}}
    for label in ["5030", "candidate"]:
        def read(path):
            return subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT, text=True) if label == "5030" else (ROOT / path).read_text()
        inputs = {name: read(f"Mocca/{name}.swift") for name in ["RootView", "MessageMarkdownView", "AppModel"]}
        source, provenance = make_harness(inputs["RootView"], inputs["MessageMarkdownView"], inputs["AppModel"])
        provenance["input_sha256"] = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in inputs.items()}
        swift = source + RUNNER
        source_path, binary = OUT / f"{label}.swift", OUT / label
        source_path.write_text(swift)
        provenance["harness_sha256"] = hashlib.sha256(swift.encode()).hexdigest()
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(source_path), "-o", str(binary)]
        (OUT / f"{label}-command.json").write_text(json.dumps(command, indent=2) + "\n")
        with (OUT / f"{label}-compile.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=log, check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)
        (OUT / f"{label}-run.log").write_text(result.stdout + result.stderr)
        result.check_returncode()
        rows = json.loads(result.stdout)
        failures = [{"scenario": row["scenario"], "registered": row["registered"], "checks": [key for key, value in row["checks"].items() if not value]} for row in rows if not all(row["checks"].values())]
        report["results"][label] = {"provenance": provenance, "cases": len(rows), "assertions": sum(len(row["checks"]) for row in rows), "failures": failures, "rows": rows}
        (OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        expected = {(f"pending-horizontal-held-ready-end-{direction}", registered) for direction in ["open", "close"] for registered in [False, True]} if label == "5030" else set()
        assert {(failure["scenario"], failure["registered"]) for failure in failures} == expected, failures
        if label == "5030":
            essential = {"pending_cancelled_at_recognition", "held_ready_never_starts_driver", "held_ready_keeps_finger_and_scroll_lock", "continued_move_has_only_finger_owner", "held_ready_has_no_delayed_semantic_close"}
            assert all(essential == set(failure["checks"]) for failure in failures), failures
        print(json.dumps({"source": label, "cases": len(rows), "assertions": report["results"][label]["assertions"], "expected_failure_cases": len(failures), "matched_expectation": True}), flush=True)
    report["passed"] = True
    (OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
