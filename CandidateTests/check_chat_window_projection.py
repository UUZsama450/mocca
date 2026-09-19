"""Compare actual 5019/5020 getters and projection/window policies on macOS.

Foundation/Observation fixtures replace app storage and UI. They prove returned
values, dependencies and work counts, not phone entry latency or UIKit pixels.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = "b785c75c321754567fe9712c9239a5f263c1f51f"
OUT = ROOT / "work/verification/chat-window-projection/host"


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def baseline(path):
    return subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT, text=True)


old = baseline("Mocca/AppModel.swift")
new = (ROOT / "Mocca/AppModel.swift").read_text()
shared = [
    "private struct MessageWindowState", "private struct SelectedMessageProjection",
    "private struct SelectedMessageProjectionCache", "    private func selectedMessages(",
    "    private func selectedMessageProjection(", "    private func messageWindow(for",
    "    private static func initialMessageWindow(", "    private static func normalizedMessageWindow(",
    "    private static func messageRenderWeight(", "    private func transcriptMessagesForSendPresentation(",
    "    private func prepareConcreteConversationEntryWindow()",
    "    private static func boundedConcreteMessageWindow(",
    "    func selectConversation(_ id: UUID, closeDrawer:",
    "    var usesConcreteConversationEntryWindow:",
]
for marker in shared:
    assert block(old, marker) == block(new, marker), marker
for path in ["Mocca/RootView.swift", "Mocca/MessageMarkdownView.swift", "Mocca/ConversationStore.swift"]:
    assert baseline(path) == (ROOT / path).read_text(), path

swift = r'''import Foundation
import Observation
enum Role: Equatable { case user, assistant }
struct Segment: Equatable { var text: String }
struct Event: Equatable { var name: String; var argumentsJSON: String?; var resultText: String? }
struct ChatMessage: Equatable {
    var id: UUID; var text: String; var role: Role = .user
    var versionGroupID: String?; var version: Int = 0; var createdAt = Date(timeIntervalSince1970: 0)
    var reasoningSegments: [Segment] = []; var toolEvents: [Event] = []
    var attachments: [String] = []; var parts: [String] = []
    var versionGroupKey: String { versionGroupID ?? id.uuidString }
}
struct Conversation { var id: UUID; var versionSelections: [String: Int] = [:] }
struct Gate { var requestID: UUID; var conversationID: UUID; var userMessageID: UUID; var assistantMessageID: UUID }
struct Request { var id: UUID; var conversationID: UUID; var messageID: UUID }
enum Work { nonisolated(unsafe) static var projectedMessageReads = 0 }
struct SelectedMessageProjection {
    let groupKey: String; private let storedMessage: ChatMessage; let firstRawIndex: Int
    var message: ChatMessage { Work.projectedMessageReads += 1; return storedMessage }
    init(groupKey: String, message: ChatMessage, firstRawIndex: Int) {
        self.groupKey = groupKey; storedMessage = message; self.firstRawIndex = firstRawIndex
    }
}
'''
swift += block(new, "private struct MessageWindowState").replace("private ", "") + "\n"
swift += block(new, "private struct SelectedMessageProjectionCache").replace("private ", "") + "\n"
swift += r'''
struct Readback: Equatable {
    let messages: [ChatMessage]; let start: Int; let end: Int; let total: Int
}
'''
getters = ["    var messages:", "    var messageWindowStartIndex:",
           "    var messageWindowEndIndex:", "    var totalMessageCountForSelectedConversation:"]
methods = ["    private func selectedMessages(", "    private func selectedMessageProjection(",
           "    private func messageWindow(for", "    private static func initialMessageWindow(",
           "    private static func normalizedMessageWindow(", "    private static func messageRenderWeight(",
           "    private func transcriptMessagesForSendPresentation("]
for name, source in [("Before", old), ("After", new)]:
    swift += f"@Observable final class {name} {{\n" + r'''
    var selectedConversationID = UUID()
    var conversations: [Conversation] = [] { didSet { selectedMessageProjectionCache = nil } }
    var messagesByConversation: [UUID: [ChatMessage]] = [:] { didSet { selectedMessageProjectionCache = nil } }
    var messageWindowsByConversation: [UUID: MessageWindowState] = [:]
    @ObservationIgnored var selectedMessageProjectionCache: SelectedMessageProjectionCache?
    var sendPresentationGate: Gate?
    var pendingUserMessageSendPositionRequest: Request?
    func readback() -> Readback {
        Readback(messages: messages, start: messageWindowStartIndex,
                 end: messageWindowEndIndex, total: totalMessageCountForSelectedConversation)
    }
'''
    for constant in ["messageWindowInitialMin", "messageWindowInitialMax", "messageWindowLoadedMax", "messageWindowInitialTextBudget"]:
        swift += re.search(r"    private static let " + constant + r" = [\d_]+", source).group() + "\n"
    for marker in getters + methods:
        swift += block(source, marker).replace("private ", "") + "\n"
    if name == "After":
        swift += block(source, "    private func messageWindow(\n").replace("private ", "") + "\n"
    swift += "}\n"

swift += r'''
func uid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}
func transcript(_ n: Int) -> [ChatMessage] {
    (0..<n).map { i in
        ChatMessage(id: uid(i + 1), text: i % 17 == 0 ? String(repeating: "字🧑🏽‍💻", count: 1300) : "短消息 \(i)",
                    role: i % 2 == 0 ? .user : .assistant,
                    reasoningSegments: [Segment(text: "思考\(i)")],
                    toolEvents: [Event(name: "tool", argumentsJSON: "{}", resultText: "result\(i)")],
                    attachments: ["image-\(i)"], parts: ["part-\(i)"])
    }
}
@main struct Checks {
 static func main() throws {
    let a = Before(), b = After(), c1 = uid(100000), c2 = uid(200000)
    var checks = 0
    func same(_ label: String) {
        precondition(a.readback() == b.readback(), label)
        precondition(a.messagesByConversation == b.messagesByConversation, "canonical data: " + label)
        precondition(a.messageWindowsByConversation == b.messageWindowsByConversation, "window state: " + label)
        checks += 1
    }
    func records(_ rows: [ChatMessage]) {
        a.messagesByConversation[c1] = rows; b.messagesByConversation[c1] = rows
    }
    a.conversations = [Conversation(id: c1), Conversation(id: c2)]; b.conversations = a.conversations
    a.selectedConversationID = c1; b.selectedConversationID = c1
    for n in [0, 1, 2, 3, 12, 13, 25, 240, 361, 1024] {
        records(transcript(n))
        a.messageWindowsByConversation = [:]; b.messageWindowsByConversation = [:]
        same("missing window \(n)")
        for start in [-4, 0, 1, max(0,n-12), max(0,n-1), n, n+5] {
            for count in [-3, 0, 1, 2, 12, 24, 360, 900] {
                let window = MessageWindowState(startIndex: start, count: count)
                a.messageWindowsByConversation[c1] = window; b.messageWindowsByConversation[c1] = window
                same("normalized \(n) \(start) \(count)")
            }
        }
    }
    records([ChatMessage(id: uid(1), text: "v1", versionGroupID: "g", version: 1),
             ChatMessage(id: uid(2), text: "v2", versionGroupID: "g", version: 2),
             ChatMessage(id: uid(3), text: "tail", role: .assistant)])
    a.messageWindowsByConversation = [:]; b.messageWindowsByConversation = [:]
    same("default logical version")
    precondition(b.messages.map(\.id) == [uid(2),uid(3)])
    for version in [1,2,99] {
        a.conversations[0].versionSelections["g"] = version; b.conversations = a.conversations
        same("version selection invalidates warm projection \(version)")
    }
    a.messagesByConversation[c1]![2].text = "edited visible text"; b.messagesByConversation = a.messagesByConversation
    same("edited message invalidates warm projection")
    a.messagesByConversation[c1]!.removeLast(); b.messagesByConversation = a.messagesByConversation
    same("deleted tail normalizes same fallback")
    a.messagesByConversation[c2] = transcript(32); b.messagesByConversation = a.messagesByConversation
    for id in [c2,c1,c2,c1] {
        a.selectedConversationID = id; b.selectedConversationID = id
        same("A B A projection cache identity")
    }
    a.selectedConversationID = c1; b.selectedConversationID = c1
    records(transcript(2))
    a.messageWindowsByConversation = [:]; b.messageWindowsByConversation = [:]
    let requestID = uid(300000)
    let gate = Gate(requestID: requestID, conversationID: c1, userMessageID: uid(1), assistantMessageID: uid(2))
    a.sendPresentationGate = gate; b.sendPresentationGate = gate
    let request = Request(id: requestID, conversationID: c1, messageID: uid(1))
    a.pendingUserMessageSendPositionRequest = request; b.pendingUserMessageSendPositionRequest = request
    same("exact send pair hides only staged assistant")
    precondition(b.messages.count == 1 && b.totalMessageCountForSelectedConversation == 2)
    for mismatch in 0..<6 {
        var g = gate; var q = request
        switch mismatch {
        case 0: g.requestID = uid(999)
        case 1: g.conversationID = c2
        case 2: g.userMessageID = uid(999)
        case 3: g.assistantMessageID = uid(999)
        case 4: q.conversationID = c2
        default: q.messageID = uid(999)
        }
        a.sendPresentationGate = g; b.sendPresentationGate = g
        a.pendingUserMessageSendPositionRequest = q; b.pendingUserMessageSendPositionRequest = q
        same("mismatched send pair \(mismatch)")
        precondition(b.messages.count == 2)
    }
    a.sendPresentationGate = nil; b.sendPresentationGate = nil
    a.pendingUserMessageSendPositionRequest = nil; b.pendingUserMessageSendPositionRequest = nil
    same("send release exposes canonical assistant")
    var work: [[String: Int]] = []
    for n in [12,240,1000,10000] {
        records(transcript(n))
        let window = MessageWindowState(startIndex: n-12, count: 12)
        a.messageWindowsByConversation[c1] = window; b.messageWindowsByConversation[c1] = window
        same("warm work count \(n)")
        Work.projectedMessageReads = 0; let before = a.readback(); let oldReads = Work.projectedMessageReads
        Work.projectedMessageReads = 0; let after = b.readback(); let newReads = Work.projectedMessageReads
        precondition(before == after && oldReads == 4*n && newReads == 12)
        work.append(["logical_messages": n, "window_messages": 12, "before_projected_message_reads": oldReads,
                     "after_projected_message_reads": newReads])
    }
    // Cache hits must still subscribe to the same canonical inputs.
    final class Counter: @unchecked Sendable { var value = 0 }
    var observationChecks = 0
    for change in 0..<4 {
        let ca = Counter(), cb = Counter()
        _ = withObservationTracking { a.readback() } onChange: { ca.value += 1 }
        _ = withObservationTracking { b.readback() } onChange: { cb.value += 1 }
        switch change {
        case 0:
            a.messagesByConversation[c1]![0].text += "changed"; b.messagesByConversation = a.messagesByConversation
        case 1:
            a.conversations[0].versionSelections["g"] = 1; b.conversations = a.conversations
        case 2:
            a.messageWindowsByConversation[c1] = MessageWindowState(startIndex: 0, count: 2)
            b.messageWindowsByConversation = a.messageWindowsByConversation
        default:
            a.selectedConversationID = c2; b.selectedConversationID = c2
        }
        precondition(ca.value == 1 && cb.value == 1, "lost observable dependency \(change)")
        same("observed mutation \(change)"); observationChecks += 1
    }
    let report: [String: Any] = ["equivalence_checks": checks, "observation_checks": observationChecks,
                               "work_counts": work, "phone_performance": "NOT_MEASURED"]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
 }
}
'''
OUT.mkdir(parents=True, exist_ok=True)
source_path, exe = OUT / "WindowProjectionChecks.swift", OUT / "checks"
source_path.write_text(swift)
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", str(source_path), "-o", str(exe)], check=True)
run = subprocess.run([str(exe)], text=True, capture_output=True, check=True)
report = json.loads(run.stdout)
report.update({"baseline": BASE, "source_sha256": hashlib.sha256(new.encode()).hexdigest(),
               "shared_source_contracts_unchanged": len(shared), "result": "PASS"})
(OUT / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
