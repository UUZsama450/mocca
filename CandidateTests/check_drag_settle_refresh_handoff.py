#!/usr/bin/env python3
"""Exercise the actual Root handoff and viewport lease together with fake views."""
from pathlib import Path
import json
import subprocess
import sys
from check_drawer_close_driver_reuse import extract, method, COMMON

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/drawer-finger-progress/handoff"
OUT.mkdir(parents=True, exist_ok=True)
current = (ROOT / "Mocca/RootView.swift").read_text()
baseline = subprocess.check_output(["git", "show", "57be55eba7b0ac98c21756be9cab5fc02c177de8:Mocca/RootView.swift"], cwd=ROOT, text=True)
markdown = (ROOT / "Mocca/MessageMarkdownView.swift").read_text()
lease = extract(markdown, r"^@MainActor\nenum DrawerViewportRefreshFreeze\b")[0]
model = (ROOT / "Mocca/AppModel.swift").read_text()
runner = r'''
@main struct Runner {
    @MainActor static func main() throws {
        var rows: [[String: Any]] = []
        for open in [false, true] {
            DrawerViewportRefreshFreeze.reset()
            let h = Harness(presented: !open, registered: true, progress: 0.6, gesture: true)
            h.setDrawerGestureActive(true)
            let view = GlyphSelectableTextView()
            DrawerViewportRefreshFreeze.deferRefresh(view)
            let generation = DrawerViewportRefreshFreeze.generation
            h.settleDrawer(open: open)
            let earlyResumes = view.resumes
            let continuousGeneration = DrawerViewportRefreshFreeze.generation == generation
            precondition(DrawerViewportRefreshFreeze.isActive)
            // A pending view is a set member; registering again must not turn
            // one final refresh into two in the continuous handoff.
            DrawerViewportRefreshFreeze.deferRefresh(view)
            CADisplayLink.links.last!.fire(at: 100.6)
            precondition(!DrawerViewportRefreshFreeze.isActive)
            precondition(view.resumes == earlyResumes + 1)
            rows.append(["open": open, "premature_resumes": earlyResumes,
                         "same_generation": continuousGeneration, "total_resumes": view.resumes])
        }
        print(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)
    }
}
'''
report = {}
for label, root in [("5022", baseline), ("candidate", current)]:
    declarations = [lease, "@MainActor final class GlyphSelectableTextView: NSObject { var resumes = 0; func resumeDrawerViewportDrawing() { resumes += 1 } }"]
    declarations.append(extract(root, r"^@MainActor\nprivate protocol DrawerLivePanelMotionReceiver\b")[0])
    for name in ["DrawerSettleDisplayLinkDriver", "DrawerNativeScrollGate", "DrawerPresentationProgressTracker", "DrawerDetachedMainPanelProgress"]:
        declarations.append(extract(root, rf"^@MainActor\n(?:@Observable\n)?private (?:final class|enum) {name}\b")[0])
    names = ["cancelDrawerSettleWork", "startDrawerSettleProgress", "adoptDrawerPresentationProgressForRoot", "setDrawerGestureActive", "syncDrawerNativeScrollGate", "continueDrawerCloseAfterExternalSemanticChange", "settleDrawer"]
    methods = "\n".join(method(root, name)[0].replace("private func", "func", 1) for name in names)
    observer = extract(root, r"^        \.onChange\(of: model.isDrawerPresented\)")[0]
    observer = "func observe(_ isPresented: Bool) {" + observer.split(" in\n", 1)[1]
    coordinator = "\n".join(method(root, name)[0] for name in ["setDrawerGestureLockActive", "releaseImmediateInteractionLock", "setStatusBarScrollToTopEnabled"])
    swift = COMMON.replace("/*MODEL*/", method(model, "setDrawerPresented")[0]).replace("/*COORDINATOR*/", coordinator).replace("/*DECLARATIONS*/", "\n".join(declarations)).replace("/*METHODS*/", methods).replace("/*OBSERVER*/", observer).replace("/*DISAPPEAR*/", "") + runner
    path = OUT / f"{label}.swift"
    path.write_text(swift)
    with (OUT / f"{label}-compile.log").open("w") as log:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(path), "-o", str(OUT / label)], stdout=log, stderr=log, check=True)
    report[label] = json.loads(subprocess.check_output([str(OUT / label)], text=True))
assert all(row["premature_resumes"] == 1 for row in report["5022"])
if "--expect-continuous" in sys.argv:
    assert all(row["premature_resumes"] == 0 and row["same_generation"] for row in report["candidate"])
report["limits"] = "Actual Root methods and viewport lease; fake pending views and display clock. Not measured phone cost."
(OUT / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report))
