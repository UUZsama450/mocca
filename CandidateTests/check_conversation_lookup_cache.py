"""Execute extracted 5025/current lookup and projection code with Observation.

Synthetic macOS inputs measure lookup work, not iPhone scrolling performance.
Use --baseline before editing AppModel to retain a pre-change measurement.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys
from check_drawer_close_driver_reuse import extract

ROOT = Path(__file__).resolve().parents[1]
BASE = "6de779aa2ae86874ebc85387ef92a8caee29ebf6"
OUT = ROOT / "work/verification/conversation-lookup-cache"
old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/AppModel.swift"], cwd=ROOT, text=True)
new = (ROOT / "Mocca/AppModel.swift").read_text()
baseline_only = "--baseline" in sys.argv
if baseline_only:
    assert old == new, "Capture the baseline before editing product code"

swift = r'''import Foundation
import Observation
enum Work { nonisolated(unsafe) static var ids = 0 }
struct Conversation: Equatable {
    let identity: UUID
    var id: UUID {
        #if COUNT_LOOKUPS
        Work.ids += 1
        #endif
        return identity
    }
    var title = "chat"
    var versionSelections: [String: Int] = [:]
}
struct ChatMessage: Equatable {
    var id = UUID()
    var text = "reply"
    var version = 0
    var createdAt = Date(timeIntervalSince1970: 0)
    var versionGroupKey = "reply"
}
'''
for name in ["SelectedMessageProjection", "SelectedMessageProjectionCache"]:
    swift += extract(new, rf"^private struct {name}\b")[0].replace("private ", "") + "\n"
for name, source in [("Before", old), ("After", new)]:
    swift += f"@MainActor @Observable final class {name} {{\n"
    swift += "var selectedConversationID = UUID()\n"
    for field, typ, default in [("conversations", "[Conversation]", "[]"),
                                ("messagesByConversation", "[UUID: [ChatMessage]]", "[:]")]:
        declaration = extract(source, rf"^    var {field}:")[0]
        swift += declaration.replace(f"{field}: {typ} {{", f"{field}: {typ} = {default} {{") + "\n"
    swift += "@ObservationIgnored private var selectedMessageProjectionCache: SelectedMessageProjectionCache?\n"
    if "private var conversationLookupCache:" in source:
        swift += re.search(r"^    @ObservationIgnored private var conversationLookupCache:.*", source, re.M)[0] + "\n"
        swift += extract(source, r"^    private func conversation\(for")[0] + "\n"
    swift += extract(source, r"^    var selectedConversation:")[0] + "\n"
    swift += extract(source, r"^    private func selectedMessageProjection\(")[0] + "\n"
    swift += '''func projection(_ id: UUID, snapshot: [ChatMessage]? = nil) -> [ChatMessage] {
        selectedMessageProjection(for: id, rawMessages: snapshot).map(\.message)
    }
    @inline(never) func repeatedRead() -> Int {
        let title = selectedConversation?.title.count ?? 0
        return title + selectedMessageProjection(for: selectedConversationID).count
    }
}\n'''

swift += r'''
let before = Before(), after = After()
var checks = 0
@MainActor func equal(_ label: String) {
    precondition(before.selectedConversation == after.selectedConversation, label)
    precondition(before.projection(before.selectedConversationID) == after.projection(after.selectedConversationID), label)
    precondition(before.conversations == after.conversations, label)
    precondition(before.messagesByConversation == after.messagesByConversation, label)
    checks += 1
}
let ids = (0..<48).map { _ in UUID() }, missing = UUID()
let fixture = ids.map { Conversation(identity: $0) }
let messages = Dictionary(uniqueKeysWithValues: ids.map { ($0, [ChatMessage(version: 1), ChatMessage(version: 2)]) })
before.conversations = fixture; after.conversations = fixture
before.messagesByConversation = messages; after.messagesByConversation = messages
for step in 0..<480 {
    let id = step % 13 == 0 ? missing : ids[(step * 17) % ids.count]
    before.selectedConversationID = id; after.selectedConversationID = id
    equal("selected \(step)"); equal("warm \(step)")
    var cs = before.conversations
    switch step % 8 {
    case 0: cs.reverse()
    case 1: if !cs.isEmpty { cs.removeFirst() }
    case 2: cs.insert(fixture[step % fixture.count], at: 0) // Also covers duplicate identities.
    case 3: if !cs.isEmpty { cs[cs.count - 1] = Conversation(identity: UUID(), title: "replacement") }
    case 4: if !cs.isEmpty { cs[0].title = "renamed \(step)" }
    case 5: if let index = cs.firstIndex(where: { $0.id == id }) { cs[index].versionSelections["reply"] = 1 }
    case 6: cs = fixture
    default: cs = []
    }
    before.conversations = cs; after.conversations = cs
    equal("mutation \(step)")
    for query in [ids[0], id, ids.last!] {
        precondition(before.projection(query) == after.projection(query), "search version selection")
        let raw = [ChatMessage(text: "explicit snapshot")]
        precondition(before.projection(query, snapshot: raw) == after.projection(query, snapshot: raw), "snapshot")
        checks += 2
    }
    before.messagesByConversation[id] = [ChatMessage(text: "stream revision \(step)")]
    after.messagesByConversation = before.messagesByConversation
    equal("message edit \(step)")
}
// Warm-cache reads must still subscribe to the canonical observable properties.
let model = After()
model.conversations = fixture; model.selectedConversationID = ids.last!
model.messagesByConversation = messages
for mode in 0..<5 {
    _ = model.repeatedRead()
    nonisolated(unsafe) var changed = false
    withObservationTracking {
        if mode == 0 || mode == 3 { _ = model.selectedConversation }
        else { _ = model.projection(model.selectedConversationID) }
    } onChange: { changed = true }
    switch mode {
    case 0: model.conversations[47].title = "rename"
    case 1: model.conversations[47].versionSelections["reply"] = 1
    case 2: model.messagesByConversation[ids.last!]![0].text = "stream"
    default: model.selectedConversationID = ids[mode]
    }
    precondition(changed, "Observation dependency \(mode)")
    checks += 1
}
var timings: [[String: Any]] = []
for count in [20, 200, 1000, 3000] {
    let cs = (0..<count).map { _ in Conversation(identity: UUID()) }
    for position in [0, count / 2, count - 1] {
        let id = cs[position].id
        before.conversations = cs; after.conversations = cs
        before.messagesByConversation = [id: [ChatMessage()]]; after.messagesByConversation = before.messagesByConversation
        before.selectedConversationID = id; after.selectedConversationID = id
        _ = before.repeatedRead(); _ = after.repeatedRead()
        #if COUNT_LOOKUPS
        Work.ids = 0
        for _ in 0..<100 { _ = before.repeatedRead() }
        let oldCount = Work.ids
        Work.ids = 0
        for _ in 0..<100 { _ = after.repeatedRead() }
        timings.append(["conversations": count, "position": position, "reads": 100,
                        "before_id_reads": oldCount, "after_id_reads": Work.ids])
        #else
        var oldTimes: [Double] = [], newTimes: [Double] = []
        let iterations = 2000
        for round in 0..<5 {
            for which in (round % 2 == 0 ? [0, 1] : [1, 0]) {
                let start = DispatchTime.now().uptimeNanoseconds
                var sum = 0
                if which == 0 { for _ in 0..<iterations { sum += before.repeatedRead() } }
                else { for _ in 0..<iterations { sum += after.repeatedRead() } }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                precondition(sum == iterations * 5)
                if which == 0 { oldTimes.append(elapsed) } else { newTimes.append(elapsed) }
            }
        }
        timings.append(["conversations": count, "position": position, "reads": iterations,
                        "before_ms": oldTimes.sorted()[2], "after_ms": newTimes.sorted()[2]])
        #endif
    }
}
let result: [String: Any] = ["semantic_and_observation_checks": checks, "measurements": timings]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
'''
OUT.mkdir(parents=True, exist_ok=True)
source_path = OUT / ("baseline.swift" if baseline_only else "comparison.swift")
source_path.write_text(swift)
results = {"baseline_commit": BASE, "appmodel_sha256": hashlib.sha256(new.encode()).hexdigest()}
for kind, flags in [("work", ["-DCOUNT_LOOKUPS"]), ("timing", [])]:
    binary = OUT / (source_path.stem + "-" + kind)
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", *flags, str(source_path), "-o", str(binary)], check=True)
    results[kind] = json.loads(subprocess.check_output([str(binary)], text=True))
    if kind == "work":
        for row in results[kind]["measurements"]:
            assert row["before_id_reads"] == 2 * row["reads"] * (row["position"] + 1)
            expected = row["before_id_reads"] if baseline_only else 2 * row["reads"]
            assert row["after_id_reads"] == expected, row
path = OUT / ("baseline-result.json" if baseline_only else "comparison-result.json")
path.write_text(json.dumps(results, indent=2) + "\n")
print(path)
print(json.dumps(results, indent=2))
