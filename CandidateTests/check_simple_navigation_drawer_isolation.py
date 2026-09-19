"""Compare real extracted view construction using SwiftUI and Observation.

The host harness injects a small observable model instead of @Environment and
uses a button stand-in. It checks dependency ownership and visibility policy,
not a rendered iPhone hierarchy, animation pixels, touch delivery, or FPS.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = "e36e4378c5e30333d4c4cb8b34d847d34ece7ef8"
OUT = Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
new = (ROOT / "Mocca/RootView.swift").read_text()
old = subprocess.check_output(
    ["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True
)


def balanced(source, marker, opening="{", closing="}"):
    start = source.index(marker)
    begin = source.index(opening, start)
    depth = 0
    for end in range(begin, len(source)):
        depth += (source[end] == opening) - (source[end] == closing)
        if depth == 0:
            return source[start:end + 1]
    raise ValueError(marker)


unchanged = [
    "private func updateQuickReturnToBottomVisibility(",
    "private var shouldKeepNativeBottomPosition:",
    "private func requestQuickReturnToBottom()",
    "private struct QuickReturnToBottomButton:",
    "private final class DrawerSettleDisplayLinkDriver:",
    "private func settleDrawer(open:",
    "private func startDrawerSettleProgress(",
]
for marker in unchanged:
    assert balanced(old, marker) == balanced(new, marker), marker
markdown = ROOT / "Mocca/MessageMarkdownView.swift"
assert markdown.read_bytes() == subprocess.check_output(
    ["git", "show", f"{BASE}:Mocca/MessageMarkdownView.swift"], cwd=ROOT
)
old_overlay = balanced(old, ".overlay(alignment: .bottom) {\n            Group {\n                if shouldShowQuickReturnToBottom")
new_overlay = balanced(new, ".overlay(alignment: .bottom) {\n            DrawerAwareQuickReturnToBottom(")
old_policy = balanced(old, "private var shouldShowQuickReturnToBottom:")
new_policy = balanced(new, "private var shouldShowQuickReturnToBottomIgnoringDrawer:")
leaf = balanced(new, "private struct DrawerAwareQuickReturnToBottom:")
assert "isDrawerPresented" not in new_policy + new_overlay
assert "bottomPadding: composerBottomClearance + 8" in new_overlay
assert "onReturnToBottom: requestQuickReturnToBottom" in new_overlay
assert "QuickReturnToBottomButton(action: onReturnToBottom)" in leaf
assert "value: isVisible" in leaf
assert "value: shouldShowQuickReturnToBottom" not in new
for marker in (".transition(", ".snappy("):
    before = balanced(old_overlay, marker, "(", ")")
    after = balanced(leaf, marker, "(", ")")
    assert re.sub(r"\s+", "", before) == re.sub(r"\s+", "", after), marker

# Only model injection changes in the extracted leaf; its body stays intact.
leaf = leaf.replace("@Environment(AppModel.self) private var model", "let model: AppModel")
expression = re.search(r"let isVisible = ([^\n]+)", leaf).group(1)
leaf = leaf[:-1] + "var resolvedVisibilityForTest: Bool { " + expression + " }\n}"
new_overlay = new_overlay.replace("DrawerAwareQuickReturnToBottom(", "DrawerAwareQuickReturnToBottom(model: model,", 1)
prefix = r'''
import Foundation
import SwiftUI
import Observation
enum Mode: CaseIterable { case always, scroll, simple, never }
struct Preferences { var mobileMessageNavButtonsMode = Mode.simple }
@Observable final class AppModel {
    var preferences = Preferences()
    var messages = [1]
    var isDrawerPresented = false
    var hasLaterMessages = false
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); defer { lock.unlock() }; storage += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}
private struct QuickReturnToBottomButton: View {
    let action: () -> Void
    var body: some View { Button(action: action) { Color.clear.frame(width: 44, height: 44) } }
}
'''
fields = '''
    let model: AppModel
    var reactionPicker: Int? = nil
    var messageSheetPresentation: Int? = nil
    var isQuickReturnToBottomVisible = false
    let composerBottomClearance: CGFloat = 80
    let actions = Counter()
    func requestQuickReturnToBottom() { actions.increment() }
'''
swift = prefix + leaf + "\n"
for name, policy, overlay in (("Before", old_policy, old_overlay), ("After", new_policy, new_overlay)):
    swift += "private struct " + name + ": View {\n" + fields
    swift += policy.replace("private var", "var", 1) + "\n"
    swift += "var body: some View { Color.clear\n" + overlay + "\n}\n}\n"
swift += r'''
@main struct Runner {
    @MainActor static func main() throws {
        var combinations = 0
        for mode in Mode.allCases { for empty in [false, true] {
        for drawer in [false, true] { for picker in [false, true] {
        for sheet in [false, true] { for later in [false, true] {
        for requested in [false, true] {
            let model = AppModel()
            model.preferences.mobileMessageNavButtonsMode = mode
            model.messages = empty ? [] : [1]
            model.isDrawerPresented = drawer
            model.hasLaterMessages = later
            let before = Before(model: model, reactionPicker: picker ? 1 : nil,
                messageSheetPresentation: sheet ? 1 : nil, isQuickReturnToBottomVisible: requested)
            let after = After(model: model, reactionPicker: picker ? 1 : nil,
                messageSheetPresentation: sheet ? 1 : nil, isQuickReturnToBottomVisible: requested)
            let leaf = DrawerAwareQuickReturnToBottom(model: model,
                baseVisible: after.shouldShowQuickReturnToBottomIgnoringDrawer,
                bottomPadding: 88, onReturnToBottom: {})
            precondition(before.shouldShowQuickReturnToBottom == leaf.resolvedVisibilityForTest)
            combinations += 1
        }}}}}}}
        var rows: [[String: Any]] = []
        for initiallyOpen in [false, true] { for requested in [false, true] {
            let model = AppModel()
            model.isDrawerPresented = initiallyOpen
            let before = Before(model: model, isQuickReturnToBottomVisible: requested)
            let after = After(model: model, isQuickReturnToBottomVisible: requested)
            let leaf = DrawerAwareQuickReturnToBottom(model: model,
                baseVisible: after.shouldShowQuickReturnToBottomIgnoringDrawer,
                bottomPadding: 88, onReturnToBottom: after.requestQuickReturnToBottom)
            let oldParent = Counter(), newParent = Counter(), newLeaf = Counter()
            withObservationTracking { _ = before.body } onChange: { oldParent.increment() }
            withObservationTracking { _ = after.body } onChange: { newParent.increment() }
            withObservationTracking { _ = leaf.body } onChange: { newLeaf.increment() }
            model.isDrawerPresented.toggle()
            precondition(oldParent.value == 1)
            precondition(newParent.value == 0)
            precondition(newLeaf.value == (requested ? 1 : 0))
            leaf.onReturnToBottom()
            precondition(after.actions.value == 1)
            rows.append(["initially_open": initiallyOpen, "button_requested": requested,
                "baseline_parent_notifications": oldParent.value,
                "candidate_parent_notifications": newParent.value,
                "candidate_leaf_notifications": newLeaf.value])
        }}
        let report: [String: Any] = ["visibility_combinations": combinations, "observation": rows]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''
source = OUT / "isolation.swift"
source.write_text(swift)
binary = OUT / "isolation"
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(binary)], check=True)
result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
report = json.loads(result.stdout)
report.update(status="PASS", source_sha256=hashlib.sha256(new.encode()).hexdigest(),
              unchanged_functions=unchanged, markdown_unchanged=True,
              limits=__doc__.strip())
(OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False))
