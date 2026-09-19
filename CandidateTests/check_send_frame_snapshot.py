"""Compare the actual 5041/5042 send predicates and count anchor reads."""
from pathlib import Path
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
base = subprocess.check_output(
    ["git", "show", "fcba0ef2f86db96a3ad7c269c7a5ef904575ad9f:Mocca/RootView.swift"],
    cwd=root, text=True,
)
source = (root / "Mocca/RootView.swift").read_text()


def block(text, marker):
    start = text.index(marker)
    brace = text.index("{", start)
    end, depth = brace + 1, 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end], text[brace:end]


def method(text, name):
    return block(text, "    private func " + name + "(")[0].replace(
        "private func", "func", 1
    )


assert method(base, "validConcreteMessageFrame") == method(source, "validConcreteMessageFrame")
methods = [method(source, "validConcreteMessageFrame"), method(source, "hasValidConcreteMessageFrames")]
for label, text in [("legacy", base), ("candidate", source)]:
    staged = block(text, "let measuredStagedAnchorID: ConversationBottomAnchorID? = {")[1]
    tail = block(text, "let hasMeasuredTailDestination = ownsStagedPresentation && {")[1]
    methods += [
        f"func {label}Staged() -> ConversationBottomAnchorID? " + staged,
        f"func {label}Tail(_ tailMessageID: UUID, anchorID landingAnchorID: ConversationBottomAnchorID) -> Bool " + tail,
    ]

harness = r'''
import Foundation
import CoreGraphics
struct ConversationBottomAnchorID: Equatable {
    var messageIDs: [UUID]
    var revision: Int = 1
}
struct Model { var hasLaterMessages = false }
struct Request { var messageID: UUID }
struct Sentinel { var anchorID: ConversationBottomAnchorID; var frame: CGRect }
struct BottomState { var bottomOffsetY: CGFloat; var contentOffsetY: CGFloat }
final class Context {
    var model = Model()
    var liveAnchor: ConversationBottomAnchorID
    var reads = 0
    var currentConversationBottomAnchorID: ConversationBottomAnchorID {
        reads += 1
        return liveAnchor
    }
    var messageFramesAnchorID: ConversationBottomAnchorID?
    var messageFrames: [UUID: CGRect]
    var latestConversationBottomAnchorFrame: Sentinel?
    var scrollViewportHeight: CGFloat = 840
    var composerBottomClearance: CGFloat = 115
    var currentUIKitBottomState: BottomState?
    var ownsStagedPresentation = true
    var stagedAssistantMessageID: UUID?
    var request: Request

    init(count: Int, staged: Bool) {
        let ids = (0..<count).map { _ in UUID() }
        let anchor = ConversationBottomAnchorID(messageIDs: ids)
        liveAnchor = anchor
        messageFramesAnchorID = anchor
        request = Request(messageID: ids.last ?? UUID())
        messageFrames = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            ($0.element, CGRect(x: 18, y: $0.offset * 100, width: 300, height: 90))
        })
        if let tail = ids.last {
            messageFrames[tail] = CGRect(x: 18, y: 900, width: 300, height: 34)
        }
        var bottom: CGFloat = 934
        if staged {
            let assistant = UUID()
            stagedAssistantMessageID = assistant
            messageFrames[assistant] = CGRect(x: 18, y: 944, width: 300, height: 34)
            bottom = 978
        }
        latestConversationBottomAnchorFrame = Sentinel(anchorID: anchor,
            frame: CGRect(x: 0, y: bottom, width: 402, height: 115))
        currentUIKitBottomState = BottomState(bottomOffsetY: 2219 + bottom + 115 - 840,
            contentOffsetY: 2219)
    }
__METHODS__
}

var cases = [[String: Any]]()
func check(_ name: String, count: Int = 24, staged: Bool,
           expected: Bool? = nil, _ modify: (Context) -> Void = { _ in }) {
    let c = Context(count: count, staged: staged)
    let requested = c.liveAnchor
    modify(c)
    c.reads = 0
    let old = staged ? c.legacyStaged() != nil
        : c.legacyTail(c.request.messageID, anchorID: requested)
    let oldReads = c.reads
    c.reads = 0
    let new = staged ? c.candidateStaged() != nil
        : c.candidateTail(c.request.messageID, anchorID: requested)
    let newReads = c.reads
    precondition(old == new, "5041/5042 disagreement: \(name), staged=\(staged), count=\(count)")
    if let expected { precondition(new == expected, "unexpected eligibility: \(name)") }
    if name == "valid", count == 24 {
        precondition(oldReads == (staged ? 26 : 25))
        precondition(newReads == (staged ? 3 : 2))
    }
    cases.append(["name": name, "count": count, "staged": staged,
                  "eligible": new, "legacyAnchorReads": oldReads, "candidateAnchorReads": newReads])
}

for staged in [false, true] {
    for count in [0, 1, 12, 23, 24, 25, 40] {
        check("valid", count: count, staged: staged, expected: count > 0 && count <= 24)
    }
    check("later history", staged: staged, expected: false) { $0.model.hasLaterMessages = true }
    check("old anchor", staged: staged, expected: false) { $0.liveAnchor.revision += 1 }
    check("old frame revision", staged: staged, expected: false) { $0.messageFramesAnchorID?.revision += 1 }
    check("missing frame revision", staged: staged, expected: false) { $0.messageFramesAnchorID = nil }
    check("old sentinel", staged: staged, expected: false) { $0.latestConversationBottomAnchorFrame?.anchorID.revision += 1 }
    check("missing sentinel", staged: staged, expected: false) { $0.latestConversationBottomAnchorFrame = nil }
    check("clearance changed", staged: staged, expected: false) { $0.composerBottomClearance += 15 }
    check("viewport changed", staged: staged, expected: false) { $0.scrollViewportHeight += 15 }
    check("no native sample", staged: staged, expected: false) { $0.currentUIKitBottomState = nil }
    check("native disagreement", staged: staged, expected: false) { $0.currentUIKitBottomState?.bottomOffsetY += 15 }
    for delta: CGFloat in [-2.01, -2, 0, 2, 2.01] {
        check("native tolerance \(delta)", staged: staged, expected: abs(delta) <= 2) {
            $0.currentUIKitBottomState?.bottomOffsetY += delta
        }
    }
    for value: CGFloat in [0, -1, .infinity, -.infinity, .nan] {
        check("invalid viewport \(value)", staged: staged, expected: false) { $0.scrollViewportHeight = value }
    }
    for row in 0..<24 {
        check("missing row \(row)", staged: staged, expected: false) {
            $0.messageFrames[$0.liveAnchor.messageIDs[row]] = nil
        }
        // Vary every measured component, including non-tail rows. Compare the
        // source predicates instead of assuming how CGRect normalizes values.
        for component in 0..<4 {
            for value: CGFloat in [0, -1, 1, 100, .infinity, -.infinity, .nan] {
                check("row \(row) component \(component) value \(value)", staged: staged) {
                    let id = $0.liveAnchor.messageIDs[row]
                    var f = $0.messageFrames[id]!
                    switch component {
                    case 0: f.origin.x = value
                    case 1: f.origin.y = value
                    case 2: f.size.width = value
                    default: f.size.height = value
                    }
                    $0.messageFrames[id] = f
                }
            }
        }
    }
}
check("gate released", staged: true, expected: false) { $0.ownsStagedPresentation = false }
check("missing reservation identity", staged: true, expected: false) { $0.stagedAssistantMessageID = nil }
check("missing reservation frame", staged: true, expected: false) {
    $0.messageFrames[$0.stagedAssistantMessageID!] = nil
}
check("reservation overlaps user", staged: true, expected: false) {
    $0.messageFrames[$0.stagedAssistantMessageID!]?.origin.y = 900
}
let data = try JSONSerialization.data(withJSONObject: ["passed": true, "cases": cases],
    options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''
harness = harness.replace("__METHODS__", "\n".join(methods))
swift = out / "send-frame-snapshot.swift"
swift.write_text(harness)
result = subprocess.run(["swift", str(swift)], text=True, capture_output=True)
(out / "send-frame-snapshot.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit(result.stderr)
parsed = json.loads(result.stdout)
(out / "send-frame-snapshot-result.json").write_text(json.dumps(parsed, indent=2) + "\n")
print(f"5041/5042 send predicates: {len(parsed['cases'])} equivalent cases passed")
for case in parsed["cases"]:
    if case["name"] == "valid" and case["count"] == 24:
        print(json.dumps(case))
