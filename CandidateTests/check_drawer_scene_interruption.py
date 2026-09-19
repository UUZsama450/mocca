#!/usr/bin/env python3
"""Run the actual lifecycle finish, progress, spring and refresh ownership code.

UIKit receivers and display-link delivery are controlled test doubles. This
checks endpoints and cancellation, not scene delivery or physical frame rate.
"""
from pathlib import Path
import json
import subprocess
from check_drawer_close_driver_reuse import COMMON, extract, method

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/drawer-scene-interruption/contracts"
OUT.mkdir(parents=True, exist_ok=True)
root = (ROOT / "Mocca/RootView.swift").read_text()
markdown = (ROOT / "Mocca/MessageMarkdownView.swift").read_text()
model = (ROOT / "Mocca/AppModel.swift").read_text()
declarations = [extract(markdown, r"^@MainActor\nenum DrawerViewportRefreshFreeze\b")[0]]
declarations += [r"""
@MainActor final class GlyphSelectableTextView: NSObject {
    var resumes = 0
    var onResume: (() -> Void)?
    func resumeDrawerViewportDrawing() { resumes += 1; onResume?() }
}
"""]
declarations.append(extract(root, r"^@MainActor\nprivate protocol DrawerLivePanelMotionReceiver\b")[0])
for name in ["DrawerSettleDisplayLinkDriver", "DrawerNativeScrollGate", "DrawerPresentationProgressTracker", "DrawerDetachedMainPanelProgress", "DrawerFingerTrackingProgress", "DrawerInlineActionTapGate"]:
    declarations.append(extract(root, rf"^@MainActor\n(?:@Observable\n)?(?:private )?(?:final class|enum) {name}\b")[0])
names = ["cancelDrawerSettleWork", "startDrawerSettleProgress", "adoptDrawerPresentationProgressForRoot", "setDrawerGestureActive", "syncDrawerNativeScrollGate", "continueDrawerCloseAfterExternalSemanticChange", "settleDrawer", "finishInterruptedDrawerInteraction"]
methods = "\n".join(method(root, name)[0].replace("private func", "func", 1) for name in names)
observer = extract(root, r"^        \.onChange\(of: model.isDrawerPresented\)")[0]
observer = "func observe(_ isPresented: Bool) {" + observer.split(" in\n", 1)[1]
coordinator = "\n".join(method(root, name)[0] for name in ["setDrawerGestureLockActive", "releaseImmediateInteractionLock", "setStatusBarScrollToTopEnabled"])
common = COMMON.replace("@MainActor enum DrawerInlineActionTapGate { static func reset() {} }", "")
common = common.replace("static func rootDidDisappear() {}", "static func rootDidDisappear() {}; static func sceneDidDeactivate() {}")
common = common.replace("func performHaptic(_ value: Haptic) {}", "var haptics = 0; func performHaptic(_ value: Haptic) { haptics += 1 }")
facade = extract(root, r"^    private var drawerDragProgress:")[0].replace("private var", "var", 1)
common = common.replace("    @Box var drawerDragProgress: CGFloat? = nil", "    let drawerFingerProgress = DrawerFingerTrackingProgress()\n" + facade + "\n    @Box var drawerGestureLocked: Bool? = nil\n    @Box var drawerDragStartProgress: CGFloat = 0\n    @Box var drawerDragActivationTranslationX: CGFloat = 0")
source = common.replace("/*MODEL*/", method(model, "setDrawerPresented")[0]).replace("/*COORDINATOR*/", coordinator).replace("/*DECLARATIONS*/", "\n".join(declarations)).replace("/*METHODS*/", methods).replace("/*OBSERVER*/", observer).replace("/*DISAPPEAR*/", "")
source += r'''
@MainActor final class Panel: DrawerLivePanelMotionReceiver {
    var samples: [CGFloat] = []
    func applyDrawerProgress(_ progress: CGFloat) { samples.append(progress) }
}
@main struct Runner {
    @MainActor static func main() async throws {
        var count = 0
        for registered in [false, true] {
            for wasOpen in [false, true] {
                for mode in ["finger", "opening", "closing", "detached"] {
                    for progress: CGFloat in [0, 0.01, 0.25, 0.49, 0.5, 0.51, 0.75, 0.99, 1] {
                        DrawerViewportRefreshFreeze.reset()
                        let h = Harness(presented: wasOpen, registered: registered, progress: progress, gesture: mode == "finger")
                        h.model.preferences.hapticsOnDrawer = true
                        h.drawerGestureLocked = true
                        h.drawerDragActivationTranslationX = 18
                        h.setDrawerGestureActive(mode == "finger")
                        if mode == "opening" || mode == "detached" {
                            h.startDrawerSettleProgress(from: progress, to: 1)
                            if mode == "detached" { h.detachedMainPanelProgress.begin(at: progress) }
                        } else if mode == "closing" {
                            h.settleDrawer(open: false)
                        }
                        let expectedOpen = progress == 0.5 ? h.model.isDrawerPresented : progress > 0.5
                        let endpoint: CGFloat = expectedOpen ? 1 : 0
                        let panel = Panel()
                        h.drawerPresentationProgressTracker.attach(panel)
                        DrawerInlineActionTapGate.beginDrawerDrag()
                        let pending = GlyphSelectableTextView()
                        var resumedAtEndpoint = false
                        pending.onResume = {
                            // Freeze release must follow both the actual tracker
                            // and its live-panel receiver reaching the endpoint.
                            resumedAtEndpoint = h.drawerPresentationProgressTracker.resolved(fallback: -1) == endpoint
                                && panel.samples.last == endpoint
                                && h.model.isDrawerPresented == expectedOpen
                        }
                        DrawerViewportRefreshFreeze.deferRefresh(pending)
                        h.pendingDrawerCloseConversationID = UUID()
                        let links = CADisplayLink.links
                        let generation = DrawerViewportRefreshFreeze.generation
                        let haptics = h.model.haptics
                        let sequence = h.drawerSettleSequence
                        h.finishInterruptedDrawerInteraction()
                        h.deliverChanges()
                        precondition(h.drawerSettleSequence == sequence + 1)
                        precondition(h.drawerSettleTask == nil && h.drawerSettleDriver.activeTargetProgress == nil)
                        precondition(links.allSatisfy { $0.invalidated })
                        precondition(CADisplayLink.links.count == links.count)
                        precondition(h.drawerDragProgress == nil && !h.detachedMainPanelProgress.isActive)
                        precondition(h.drawerGestureLocked == nil && h.drawerDragActivationTranslationX == 0)
                        precondition(h.drawerDragStartProgress == endpoint && !h.isDrawerGestureActive)
                        precondition(h.model.isDrawerPresented == expectedOpen && h.model.streamingSuspended == expectedOpen)
                        precondition(panel.samples.last == endpoint && h.drawerPresentationProgressTracker.resolved(fallback: -1) == endpoint)
                        precondition(!registered || h.chat.isScrollEnabled == !expectedOpen)
                        precondition(h.list.isScrollEnabled)
                        precondition(DrawerInlineActionTapGate.allowsAction)
                        precondition(!DrawerViewportRefreshFreeze.isActive)
                        precondition(DrawerViewportRefreshFreeze.generation == generation)
                        precondition(pending.resumes == 1 && resumedAtEndpoint)
                        precondition(h.model.haptics == haptics)
                        // Duplicate inactive/background delivery must not start
                        // another transition, redraw cycle, or display link.
                        let finishedSequence = h.drawerSettleSequence
                        h.finishInterruptedDrawerInteraction()
                        precondition(h.drawerSettleSequence == finishedSequence && pending.resumes == 1)
                        for link in links { link.fire(at: 101) }
                        try await Task.sleep(for: .milliseconds(15))
                        h.deliverChanges()
                        precondition(h.model.isDrawerPresented == expectedOpen)
                        precondition(h.drawerPresentationProgressTracker.resolved(fallback: -1) == endpoint)
                        precondition(!h.detachedMainPanelProgress.isActive && h.drawerDragProgress == nil)
                        // An existing pending content-ready close is cancelled.
                        precondition(h.pendingDrawerCloseConversationID == nil)
                        count += 1
                    }
                }
            }
        }
        for open in [false, true] {
            let endpoint: CGFloat = open ? 1 : 0
            let h = Harness(presented: open, registered: true, progress: endpoint)
            h.model.streamingSuspended = open
            h.drawerGestureLocked = false // A cancelled vertical touch owns no drawer.
            let sequence = h.drawerSettleSequence
            h.finishInterruptedDrawerInteraction()
            precondition(h.drawerSettleSequence == sequence && h.model.isDrawerPresented == open)
            precondition(h.drawerGestureLocked == nil && h.model.streamingSuspended == open)
            precondition(CADisplayLink.links.isEmpty)
            count += 1
        }
        print("{\"passed_scenarios\":\(count),\"limits\":\"Actual Root methods, progress and freeze; controlled display clock and UIKit receivers. No physical timing or scene delivery measurement.\"}")
    }
}
'''
path = OUT / "lifecycle.swift"
path.write_text(source)
with (OUT / "compile.log").open("w") as log:
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(path), "-o", str(OUT / "lifecycle")], stdout=log, stderr=log, check=True)
result = json.loads(subprocess.check_output([str(OUT / "lifecycle")], text=True))
(OUT / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
