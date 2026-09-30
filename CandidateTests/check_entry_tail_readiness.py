"""Exercise the real readiness predicate without SwiftUI or phone access.

The UI fault-injection test separately proves that the row-local geometry action
reaches this predicate and releases the existing drawer gate.
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/entry-tail-local-ack/host"
OUT.mkdir(parents=True, exist_ok=True)


def block(source, token):
    start = source.index(token)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


HARNESS = r'''
private struct Harness {
    var currentConversationBottomAnchorID: ConversationBottomAnchorID
    var messageFramesAnchorID: ConversationBottomAnchorID?
    var messageFrames: [UUID: CGRect] = [:]
    var concreteEntryTailAnchorID: ConversationBottomAnchorID?
    var isBoundedConversationEntry = true
    // METHODS
    func ready(_ anchor: ConversationBottomAnchorID) -> Bool {
        hasConcreteTailFrame(for: anchor)
    }
}
@main struct Checks {
    static func main() {
        let conversation = UUID(), tail = UUID()
        func anchor(_ request: Int = 1, _ messages: [UUID]? = nil,
                    _ id: UUID? = nil) -> ConversationBottomAnchorID {
            .init(positionRequest: .init(conversationID: id ?? conversation,
                                         request: request),
                  messageIDs: messages ?? [tail])
        }
        let current = anchor()
        var results: [String: Bool] = [:]
        func check(_ label: String, _ actual: Bool, _ expected: Bool) {
            results[label] = actual == expected
        }
        var h = Harness(currentConversationBottomAnchorID: current)
        check("no measured row", h.ready(current), false)
        h.concreteEntryTailAnchorID = current
        check("local layout survives missing aggregate", h.ready(current), true)
        h.concreteEntryTailAnchorID = anchor(1, nil, UUID())
        check("other conversation rejected", h.ready(current), false)
        h.concreteEntryTailAnchorID = anchor(0)
        check("old request rejected", h.ready(current), false)
        h.concreteEntryTailAnchorID = anchor(1, [UUID(), tail])
        check("old window rejected", h.ready(current), false)
        h.concreteEntryTailAnchorID = current
        h.isBoundedConversationEntry = false
        check("entry acknowledgement inactive after release", h.ready(current), false)
        h.isBoundedConversationEntry = true
        h.currentConversationBottomAnchorID = anchor(2)
        check("late old callback rejected", h.ready(current), false)
        let empty = anchor(1, [])
        h.currentConversationBottomAnchorID = empty
        h.concreteEntryTailAnchorID = empty
        check("empty window is not a measured tail", h.ready(empty), false)
        h = Harness(currentConversationBottomAnchorID: current)
        h.isBoundedConversationEntry = false
        h.messageFramesAnchorID = current
        h.messageFrames[tail] = CGRect(x: 18, y: -378, width: 366, height: 1115)
        check("ordinary aggregate measurement preserved", h.ready(current), true)
        h.messageFrames[tail] = .zero
        check("zero aggregate rejected", h.ready(current), false)
        h.messageFrames[tail] = CGRect(x: 18, y: CGFloat.nan, width: 366, height: 1115)
        check("nonfinite aggregate rejected", h.ready(current), false)
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
'''

sources = {
    "baseline": subprocess.check_output(
        ["git", "show", "2c8b6d2:Mocca/RootView.swift"], cwd=ROOT, text=True
    ),
    "candidate": (ROOT / "Mocca/RootView.swift").read_text(),
}
results = {}
with tempfile.TemporaryDirectory(prefix="mocca-entry-readiness-") as folder:
    folder = Path(folder)
    for label, source in sources.items():
        types = "\n".join(block(source, "private struct " + name + ":") for name in [
            "ConversationPositionRequestKey", "ConversationBottomAnchorID"
        ])
        methods = "\n".join(block(source, "private func " + name + "(") for name in [
            "hasConcreteTailFrame", "validConcreteMessageFrame"
        ])
        swift = folder / (label + ".swift")
        swift.write_text("import Foundation\nimport CoreGraphics\n" + types
                         + HARNESS.replace("// METHODS", methods))
        executable = folder / label
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                        str(swift), "-o", str(executable)], check=True)
        results[label] = json.loads(subprocess.check_output([str(executable)], text=True))

assert [name for name, passed in results["baseline"].items() if not passed] == [
    "local layout survives missing aggregate"
]
assert all(results["candidate"].values()), results["candidate"]
(OUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps({name: {"checks": len(checks), "failed": sum(not v for v in checks.values())}
                  for name, checks in results.items()}, indent=2))
