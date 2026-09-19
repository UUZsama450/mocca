"""Verify 5027 scope and run existing interruption/handoff contracts.

The rendered effect now reads the visual leaf instead of an imperative layer
stub. Only that observation is adapted; existing endpoint/cancellation/refresh
expectations and their actual production methods remain intact.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
from check_drawer_close_driver_reuse import extract, RUNNER
import check_drawer_transition_handoff as handoff

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/drawer-fade-ownership/contracts"
BASE = "3491e0f2d48cd90da5610dee5720634c50319001"
OUT.mkdir(parents=True, exist_ok=True)
root = (ROOT / "Mocca/RootView.swift").read_text()
old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
for path in ["Mocca/AppModel.swift", "Mocca/MessageMarkdownView.swift", "Mocca/ConversationStore.swift",
             "Mocca/ComposerView.swift", "Mocca/NativeMultilineTextEditor.swift"]:
    assert (ROOT / path).read_bytes() == subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT), path

write = r"^([ \t]*)DrawerTrackedContentLayerMotion\.update\(\n?[ \t]*[^\n]*\n?[ \t]*\)\n"
before_root = extract(old, r"^struct RootView: View")[0]
without_writes, count = re.subn(write, "", before_root, flags=re.M)
assert count == 9
assert without_writes == extract(root, r"^struct RootView: View")[0], "Gesture, spring, keyboard or lifecycle logic changed"
boundary = "/// Observes the semantic close"
assert old[old.index(boundary):] == root[root.index(boundary):], "Drawer list or later code changed"
for name in ["DrawerLiveMainPanelController", "DrawerFingerTrackingProgress", "DrawerDetachedMainPanelProgress",
             "DrawerSettleDisplayLinkDriver", "DrawerPresentationProgressTracker"]:
    pattern = rf"^(?:@MainActor\n)?(?:@Observable\n)?private final class {name}\b"
    assert extract(old, pattern)[0] == extract(root, pattern)[0], name
assert "postCommitApplyScheduled" not in root and "markerOpacity" not in root
modifier = extract(root, r"^private struct DrawerContentMotionModifier\b")[0]
assert ".visualEffect" in modifier and ".compositingGroup()" in modifier
assert ".opacity(0.35 + 0.65 * visualProgress)" in modifier
assert ".offset(x: -24 * (1 - visualProgress))" in modifier

# Read the exact production progress expressions; only bind their references
# to the controlled Harness fields used by the previous contracts.
leaf = extract(root, r"^private struct DrawerLeafProgressConversationDrawer\b")[0]
selection = leaf[leaf.index("        let leafProgress"):leaf.index("        ConversationDrawer(")]
visual = modifier[modifier.index("        let visualProgress"):modifier.index("        content\n")]
extension = """
extension Harness {
    var drawerFadeProgress: CGFloat {
        let fingerProgress = drawerFingerProgress
        let settleProgress = detachedMainPanelProgress
        let baseProgress = min(max(drawerFingerProgress.initialProgress ?? (model.isDrawerPresented ? 1 : 0), 0), 1)
""" + selection + visual + "\n        return visualProgress\n    }\n}\n"

handoff.OUT = OUT
common = handoff.harness(root, (ROOT / "Mocca/MessageMarkdownView.swift").read_text(),
                          (ROOT / "Mocca/AppModel.swift").read_text()) + extension
rows = handoff.run("handoff", common + handoff.COMPOSITE_RUNNER.replace("DrawerTrackedContentLayerMotion.progress", "h.drawerFadeProgress"))
existing = handoff.run("existing", common + RUNNER)
assert all(all(row["checks"].values()) for row in rows + existing), rows + existing

scene_path = ROOT / "CandidateTests/check_drawer_scene_interruption.py"
scene = scene_path.read_text()
scene = scene.replace('ROOT / "work/verification/drawer-scene-interruption/contracts"', 'ROOT / "work/verification/drawer-fade-ownership/contracts/lifecycle"')
assert scene.count("source += r'''") == 1
scene = scene.replace("source += r'''", "source += " + repr(extension) + "\nsource += r'''", 1)
scene = scene.replace("DrawerTrackedContentLayerMotion.progress", "h.drawerFadeProgress")
(OUT / "adapted-lifecycle-test.py").write_text(scene)
exec(compile(scene, str(scene_path), "exec"), {"__file__": str(scene_path)})
scene_result = json.loads((OUT / "lifecycle/result.json").read_text())
assert scene_result["passed_scenarios"] == 146

vertical = r'''
@main struct VerticalRunner {
    @MainActor static func main() {
        let h = Harness(presented: true, registered: true, progress: 1)
        for p: CGFloat in [0.2, 0.5, 0.8, 1] {
            h.detachedMainPanelProgress.begin(at: p, drivesDrawer: false)
            precondition(h.drawerFadeProgress == p, "Fade must finish the detached spring")
            h.detachedMainPanelProgress.clear()
            precondition(h.drawerFadeProgress == 1)
        }
        print("[]")
    }
}
'''
handoff.run("vertical-fade", common + vertical)
report = {"base": BASE, "root_sha256": hashlib.sha256(root.encode()).hexdigest(),
          "handoff_cases": len(rows), "existing_cases": len(existing), "lifecycle_cases": 146,
          "detached_fade_checks": 8, "scope_checks": "PASS", "limits": __doc__}
(OUT / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
