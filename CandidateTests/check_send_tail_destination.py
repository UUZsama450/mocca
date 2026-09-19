"""Exercise the actual measured-tail predicate with valid and stale geometry."""
from pathlib import Path
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
source = (root / "Mocca/RootView.swift").read_text()


def method(name):
    start = source.index("    private func " + name + "(")
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func", 1)


harness = r'''
import Foundation
import CoreGraphics
struct ConversationBottomAnchorID: Equatable {
    var messageIDs: [UUID]
    var revision: Int = 1
}
struct Model { var hasLaterMessages = false }
struct Sentinel { var anchorID: ConversationBottomAnchorID; var frame: CGRect }
struct BottomState { var bottomOffsetY: CGFloat; var contentOffsetY: CGFloat }
struct Context {
    var model = Model()
    var currentConversationBottomAnchorID: ConversationBottomAnchorID
    var messageFramesAnchorID: ConversationBottomAnchorID?
    var messageFrames: [UUID: CGRect]
    var latestConversationBottomAnchorFrame: Sentinel?
    var scrollViewportHeight: CGFloat = 840
    var composerBottomClearance: CGFloat = 115
    var currentUIKitBottomState: BottomState? = .init(bottomOffsetY: 2428, contentOffsetY: 2219)
__METHODS__
}
func fixture(count: Int = 4) -> Context {
    let ids = (0..<count).map { _ in UUID() }
    let anchor = ConversationBottomAnchorID(messageIDs: ids)
    var frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
        ($0.element, CGRect(x: 18, y: $0.offset * 100, width: 300, height: 90))
    })
    frames[ids.last!] = CGRect(x: 18, y: 900, width: 300, height: 34)
    return Context(currentConversationBottomAnchorID: anchor,
        messageFramesAnchorID: anchor, messageFrames: frames,
        latestConversationBottomAnchorFrame: Sentinel(anchorID: anchor,
            frame: CGRect(x: 0, y: 934, width: 402, height: 115)))
}
var cases = [[String: Any]]()
func check(_ name: String, expected: Bool, count: Int = 4, _ modify: (inout Context) -> Void = { _ in }) {
    var context = fixture(count: count)
    let requested = context.currentConversationBottomAnchorID
    modify(&context)
    let actual = context.hasMeasuredSendTailDestination(requested.messageIDs.last!, anchorID: requested)
    cases.append(["name": name, "expected": expected, "actual": actual])
    precondition(actual == expected, name)
}
check("measured assistant below viewport includes composer clearance", expected: true)
check("still has later history", expected: false) { $0.model.hasLaterMessages = true }
check("old selected revision", expected: false) { $0.currentConversationBottomAnchorID.revision += 1 }
check("old message measurements", expected: false) { $0.messageFramesAnchorID?.revision += 1 }
check("old sentinel revision", expected: false) { $0.latestConversationBottomAnchorFrame?.anchorID.revision += 1 }
check("missing tail measurement", expected: false) { $0.messageFrames[$0.currentConversationBottomAnchorID.messageIDs.last!] = nil }
check("missing earlier row can still hide lazy estimates", expected: false) { $0.messageFrames[$0.currentConversationBottomAnchorID.messageIDs.first!] = nil }
check("tail and sentinel do not join", expected: false) { $0.latestConversationBottomAnchorFrame?.frame.origin.y += 20 }
check("old composer clearance", expected: false) { $0.composerBottomClearance = 204 }
check("native and SwiftUI destinations disagree", expected: false) { $0.currentUIKitBottomState?.bottomOffsetY += 40 }
check("native scroll view unavailable", expected: false) { $0.currentUIKitBottomState = nil }
check("zero viewport", expected: false) { $0.scrollViewportHeight = 0 }
check("nonfinite viewport", expected: false) { $0.scrollViewportHeight = .infinity }
check("nonfinite tail", expected: false) {
    $0.messageFrames[$0.currentConversationBottomAnchorID.messageIDs.last!]?.size.height = .infinity
}
check("nonfinite sentinel", expected: false) { $0.latestConversationBottomAnchorFrame?.frame.origin.y = .infinity }
check("long window remains on established path", expected: false, count: 25)
let data = try JSONSerialization.data(withJSONObject: ["passed": true, "cases": cases], options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''
start = source.index("let hasMeasuredTailDestination = ownsStagedPresentation && {")
brace = source.index("{", start)
end, depth = brace + 1, 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
predicate = "func hasMeasuredSendTailDestination(_ tailMessageID: UUID, anchorID landingAnchorID: ConversationBottomAnchorID) -> Bool " + source[brace:end]
harness = harness.replace(
    "__METHODS__",
    method("validConcreteMessageFrame") + "\n"
    + method("hasValidConcreteMessageFrames") + "\n" + predicate,
)
swift = out / "measured-tail-policy.swift"
swift.write_text(harness)
result = subprocess.run(["swift", str(swift)], text=True, capture_output=True)
(out / "measured-tail-policy.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.stderr)
parsed = json.loads(result.stdout)
(out / "measured-tail-policy-result.json").write_text(json.dumps(parsed, indent=2))
print(f"Measured-tail policy: {len(parsed['cases'])} cases passed")
