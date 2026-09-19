#!/usr/bin/env python3
"""Source/settle regression checks; real hierarchy is covered by LivePanelUITests."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from check_drawer_close_driver_reuse import extract, method, COMMON, RUNNER, strip_viewport_freeze_hooks

ROOT = Path(__file__).resolve().parents[1]
BASE = "29a666fabce1b611ead97639a8a2cfc93ab8da11"
OUT = ROOT / "work/verification/drawer-live-uikit-panel/contracts"
OUT.mkdir(parents=True, exist_ok=True)
old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
new = (ROOT / "Mocca/RootView.swift").read_text()
unchanged = []
for path in ["Mocca/AppModel.swift", "Mocca/MessageMarkdownView.swift", "Mocca/ConversationStore.swift", "Mocca/ComposerView.swift"]:
    assert (ROOT / path).read_bytes() == subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT), path
    unchanged.append(path)
names = ("cancelDrawerSettleWork", "startDrawerSettleProgress", "adoptDrawerPresentationProgressForRoot", "setDrawerGestureActive", "syncDrawerNativeScrollGate", "openDrawerFromButton", "closeDrawerAnimated", "requestDrawerCloseAfterConversationReady", "handleConversationContentReady", "continueDrawerCloseAfterExternalSemanticChange", "settleDrawer", "finishDrawerOpeningSettleForVerticalIntentIfNeeded", "drawerDragGesture")
for name in names:
    assert method(old, name)[0] == method(new, name)[0], name
    unchanged.append(name)
for name in ["MainChatContainer", "MainChatPanelChrome", "DrawerPanelShadowLayer", "DrawerPanelShadowBackingView", "DrawerSettleDisplayLinkDriver", "DrawerLeafProgressConversationDrawer", "DrawerDetachedMainPanelProgress", "DrawerNativeScrollGate"]:
    pattern = rf"^(?:@MainActor\n)?(?:@Observable\n)?private (?:final class|enum|struct) {name}\b"
    assert extract(old, pattern)[0] == extract(new, pattern)[0], name
    unchanged.append(name)
assert extract(old, r"^        \.onChange\(of: model.isDrawerPresented\)")[0] == extract(new, r"^        \.onChange\(of: model.isDrawerPresented\)")[0]
controller = extract(new, r"^@MainActor\nprivate final class DrawerLiveMainPanelController\b")[0]
content = extract(new, r"^private struct DrawerLiveMainPanelContent\b")[0]
assert "host.rootView =" not in controller and "host.view.frame =" not in controller
assert "configuration.progress" not in content
assert "snapshotView" not in controller and "drawHierarchy" not in controller

cases = []
# Exercise the actual new weak receiver contract, including host replacement.
tracker_source = "import Foundation\n" + extract(new, r"^@MainActor\nprivate protocol DrawerLivePanelMotionReceiver\b")[0] + "\n" + extract(new, r"^@MainActor\nprivate final class DrawerPresentationProgressTracker\b")[0] + r'''
@MainActor private final class Receiver: DrawerLivePanelMotionReceiver {
    var samples: [CGFloat] = []
    func applyDrawerProgress(_ value: CGFloat) { samples.append(value) }
}
@main struct Runner {
    @MainActor static func main() {
        let tracker = DrawerPresentationProgressTracker()
        precondition(tracker.resolved(fallback: 0.7) == 0.7)
        tracker.update(0.42)
        let first = Receiver(), second = Receiver()
        tracker.attach(first)
        precondition(first.samples == [0.42])
        tracker.attach(second)
        tracker.detach(first) // A disappearing old host cannot detach the new one.
        tracker.update(0.6)
        precondition(first.samples == [0.42] && second.samples == [0.42, 0.6])
        tracker.update(1.5); tracker.update(-0.1)
        precondition(second.samples.suffix(2) == [1, 0])
        tracker.detach(second); tracker.update(0.9)
        precondition(second.samples.count == 4)
        weak var released: Receiver?
        do {
            let temporary = Receiver(); released = temporary
            tracker.attach(temporary)
            precondition(temporary.samples == [0.9])
        }
        precondition(released == nil)
        tracker.update(0.2)
        precondition(tracker.resolved(fallback: 1) == 0.2)
        print("8 receiver lifetime and progress checks passed")
    }
}
'''
tracker_path = OUT / "receiver.swift"
tracker_path.write_text(tracker_source)
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(tracker_path), "-o", str(OUT / "receiver")], check=True)
subprocess.run([str(OUT / "receiver")], check=True)
for label, root in [("5020", old), ("5021", new)]:
    declarations = []
    if label == "5021":
        declarations.append(extract(root, r"^@MainActor\nprivate protocol DrawerLivePanelMotionReceiver\b")[0])
    for name in ("DrawerSettleDisplayLinkDriver", "DrawerNativeScrollGate", "DrawerPresentationProgressTracker", "DrawerDetachedMainPanelProgress"):
        declarations.append(extract(root, rf"^@MainActor\n(?:@Observable\n)?private (?:final class|enum) {name}\b")[0])
    methods = [method(root, n)[0].replace("private func", "func", 1) for n in names[:11]]
    observer = extract(root, r"^        \.onChange\(of: model.isDrawerPresented\)")[0]
    observer = "func observe(_ isPresented: Bool) {" + observer.split(" in\n", 1)[1]
    disappear = extract(root, r"^        \.onDisappear\b")[0]
    disappear = "func disappear() {" + disappear.split("{", 1)[1]
    coordinator = "\n".join(method(root, n)[0] for n in ("setDrawerGestureLockActive", "releaseImmediateInteractionLock", "setStatusBarScrollToTopEnabled"))
    model = (ROOT / "Mocca/AppModel.swift").read_text()
    swift = COMMON.replace("/*MODEL*/", method(model, "setDrawerPresented")[0]).replace("/*COORDINATOR*/", coordinator).replace("/*DECLARATIONS*/", "\n".join(declarations)).replace("/*METHODS*/", "\n".join(methods)).replace("/*OBSERVER*/", observer).replace("/*DISAPPEAR*/", disappear) + RUNNER
    swift = strip_viewport_freeze_hooks(swift)
    source = OUT / f"settle-{label}.swift"
    source.write_text(swift)
    binary = OUT / f"settle-{label}"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
    for case in json.loads(result.stdout):
        case["build"] = label
        assert all(case["checks"].values()), case
        cases.append(case)
report = {"status": "PASS", "root_sha256": hashlib.sha256(new.encode()).hexdigest(), "unchanged_contracts": unchanged, "settle_cases": cases, "limits": "Controlled display-link/observation/state doubles; no phone performance or actual gesture recognizer evidence."}
(OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"status": "PASS", "unchanged_contracts": len(unchanged), "settle_cases": len(cases)}))
