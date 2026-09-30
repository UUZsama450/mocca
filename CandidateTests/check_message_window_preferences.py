"""Run the actual paging reducers against PreferenceKey's neutral-default contract.

Foundation/CoreGraphics host: no simulator, app launch, chat data, or UI emulation.
The unchanged baseline must fail the contract and the candidate must pass.
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/manual-history-preference/host"
OUT.mkdir(parents=True, exist_ok=True)
BASE = "f63b185"


def block(source, token):
    start = source.index(token)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


HOST = r'''
import Foundation
import CoreGraphics
private protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}
'''
TESTS = r'''
@main struct Checks {
    static func main() {
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }
        func exercise<K: PreferenceKey>(_ key: K.Type, _ name: String) where K.Value == EdgeValue {
            func fold(_ frames: [EdgeValue]) -> EdgeValue {
                var value = K.defaultValue
                for frame in frames { K.reduce(value: &value, nextValue: { frame }) }
                return value
            }
            let empty = K.defaultValue
            let positions: [CGFloat] = [-500, -161, -160, 0, 80, 96, 140, 800, 1600]
            check(fold([]) == empty, name + ": empty pass")
            check(fold([empty, empty]) == empty, name + ": all absent")
            for y in positions {
                let rect = CGRect(x: 18, y: y, width: 366, height: 1)
                let measured = sample(rect)
                let moved = sample(rect.offsetBy(dx: 0, dy: 17))
                check(fold([measured]) == measured, name + ": measurement \(y)")
                check(fold([measured, empty]) == measured, name + ": neutral default \(y)")
                check(fold([empty, measured, empty, empty]) == measured, name + ": absent siblings \(y)")
                check(fold([measured, moved]) == moved, name + ": latest measurement \(y)")
                check(fold([measured, empty, moved, empty]) == moved, name + ": latest with absent siblings \(y)")
                // A separate reduction starts empty; no geometry survives an absent next pass.
                _ = fold([measured])
                check(fold([empty]) == empty, name + ": no cross-pass retention \(y)")
            }
        }
        exercise(MessageWindowTopFramePreferenceKey.self, "earlier")
        exercise(MessageWindowBottomFramePreferenceKey.self, "later")
        let report: [String: Any] = ["checks": checks, "failed": failures.count, "failures": failures]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
'''

sources = {
    "baseline": subprocess.check_output(
        ["git", "show", BASE + ":Mocca/RootView.swift"], cwd=ROOT, text=True
    ),
    "candidate": (ROOT / "Mocca/RootView.swift").read_text(),
}
results = {}
with tempfile.TemporaryDirectory(prefix="mocca-paging-preferences-") as temp:
    folder = Path(temp)
    for label, source in sources.items():
        if "private struct MessageWindowEdgeFrame:" in source:
            payload = "\n".join(block(source, "private struct " + name + ":") for name in [
                "ConversationPositionRequestKey", "ConversationBottomAnchorID",
                "MessageWindowEdgeID", "MessageWindowEdgeFrame"
            ]) + '''
private typealias EdgeValue = MessageWindowEdgeFrame?
private func sample(_ frame: CGRect) -> EdgeValue {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    return MessageWindowEdgeFrame(windowID: .init(
        positionRequest: .init(conversationID: id, request: 1),
        firstMessageID: id, lastMessageID: id, messageCount: 1), frame: frame)
}
'''
        else:
            payload = "private typealias EdgeValue = CGRect\nprivate func sample(_ frame: CGRect) -> CGRect { frame }\n"
        extracted = "\n".join(block(source, "private struct " + name + ":") for name in [
            "MessageWindowTopFramePreferenceKey", "MessageWindowBottomFramePreferenceKey"
        ])
        swift = folder / (label + ".swift")
        executable = folder / label
        swift.write_text(HOST + payload + extracted + TESTS)
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            str(swift), "-o", str(executable)
        ], check=True)
        results[label] = json.loads(subprocess.check_output([str(executable)], text=True))

assert results["baseline"]["failed"] > 0, "Baseline must expose the neutral-default defect"
assert all("neutral default" in name or "absent siblings" in name
           for name in results["baseline"]["failures"])
assert results["candidate"]["failed"] == 0, results["candidate"]
(OUT / "results.json").write_text(json.dumps(results, indent=2))
print(json.dumps({label: {"checks": r["checks"], "failed": r["failed"]}
                  for label, r in results.items()}, indent=2))
