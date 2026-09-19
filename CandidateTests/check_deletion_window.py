"""Exercise the production window selector and history paging without disk I/O."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
text = (root / "Mocca/AppModel.swift").read_text()

def section(start, end):
    pos = text.index(start)
    return text[pos:text.index(end, pos)]

source = """import Foundation
struct Segment { var text: String }
struct Event { var name: String; var argumentsJSON: String?; var resultText: String? }
struct ChatMessage {
    let id = UUID()
    var text: String
    var reasoningSegments: [Segment] = []
    var toolEvents: [Event] = []
}
"""
source += section("private struct MessageWindowState", "private struct ConversationComposerPacket")
source += """
private final class Fixture {
    let selectedConversationID = UUID()
    var messages: [ChatMessage]
    func releaseConcreteConversationEntryWindow() {}
    var messageWindowsByConversation: [UUID: MessageWindowState] = [:]
    init(_ weights: [Int]) { messages = weights.map { ChatMessage(text: String(repeating: "a", count: $0)) } }
    func selectedMessages(for id: UUID) -> [ChatMessage] { messages }
    func messageWindow(for id: UUID, messages: [ChatMessage]) -> MessageWindowState {
        messageWindowsByConversation[id] ?? MessageWindowState(startIndex: 0, count: messages.count)
    }
    var window: MessageWindowState { messageWindow(for: selectedConversationID, messages: messages) }
    var ids: [UUID] { messages.map(\.id) }
}
"""
source = source.rsplit("}\n", 1)[0]
for constant in ["messageWindowConcreteMax", "messageWindowInitialTextBudget", "messageWindowPageSize", "messageWindowLoadedMax"]:
    source += re.search(r"    private static let " + constant + r" = [\d_]+", text).group() + "\n"
source += section("    @discardableResult\n    func limitMessageWindowForConcreteLayout", "    private func prepareConcreteConversationEntryWindow")
source += section("    private static func messageRenderWeight", "    #if DEBUG")
source += section("    @discardableResult\n    func loadEarlierMessages", "    @discardableResult\n    func loadStartMessageWindow")
source += "}\n"
source += r"""
@main struct Tests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); count += 1; print("PASS \(name)")
        }
        let long = Fixture(Array(repeating: 100, count: 100))
        let before = long.ids
        let other = UUID(), otherWindow = MessageWindowState(startIndex: 4, count: 20)
        long.messageWindowsByConversation[other] = otherWindow
        check(long.limitMessageWindowForConcreteLayout(around: before[50]), "middle target admitted")
        check(long.window.count == 12 && (long.window.startIndex..<long.window.endIndex).contains(50), "middle window bounded around target")
        check(long.ids == before && long.messageWindowsByConversation[other] == otherWindow, "canonical messages and another conversation window unchanged")
        while long.loadEarlierMessages() {}
        check(long.window.startIndex == 0, "earlier history remains reachable")
        while long.loadLaterMessages() {}
        check(long.window.endIndex == before.count && long.ids == before, "later history remains reachable without changing messages")
        let weighted = Fixture(Array(repeating: 6000, count: 30))
        check(weighted.limitMessageWindowForConcreteLayout(around: weighted.ids[15]) && weighted.window.count == 3, "text budget constrains count below twelve")
        let giant = Fixture([100, 30000, 100])
        check(giant.limitMessageWindowForConcreteLayout(around: giant.ids[1]) && giant.window == MessageWindowState(startIndex: 1, count: 1), "oversized target admitted alone")
        let reasoning = Fixture([100, 100, 100])
        reasoning.messages[1].reasoningSegments = [Segment(text: String(repeating: "r", count: 21000))]
        check(reasoning.limitMessageWindowForConcreteLayout(around: reasoning.ids[1]) && reasoning.window.count == 1, "reasoning contributes to layout budget")
        let tools = Fixture([100, 100, 100])
        tools.messages[1].toolEvents = [Event(name: "tool", argumentsJSON: nil, resultText: String(repeating: "t", count: 21000))]
        check(tools.limitMessageWindowForConcreteLayout(around: tools.ids[1]) && tools.window.count == 1, "tool results contribute to layout budget")
        let restricted = Fixture(Array(repeating: 100, count: 50))
        restricted.messageWindowsByConversation[restricted.selectedConversationID] = MessageWindowState(startIndex: 10, count: 20)
        let old = restricted.window
        check(!restricted.limitMessageWindowForConcreteLayout(around: restricted.ids[0]) && restricted.window == old, "outside-window target does not mutate window")
        check(restricted.limitMessageWindowForConcreteLayout(around: restricted.ids[10]) && restricted.window.startIndex == 10, "does not pull new earlier rows into the deletion window")
        check(!restricted.limitMessageWindowForConcreteLayout(around: UUID()), "unknown target rejected")
        let empty = Fixture([])
        check(!empty.limitMessageWindowForConcreteLayout(around: UUID()), "empty transcript has no deletion window")
        var cases = 0
        for size in 1...60 {
            for target in 0..<size {
                let f = Fixture((0..<size).map { $0 % 7 == 0 ? 15000 : 400 })
                let original = f.ids
                precondition(f.limitMessageWindowForConcreteLayout(around: original[target]))
                let w = f.window
                precondition(w.count <= 12 && w.startIndex >= 0 && w.endIndex <= size)
                precondition((w.startIndex..<w.endIndex).contains(target) && f.ids == original)
                let weight = f.messages[w.startIndex..<w.endIndex].reduce(0) { $0 + $1.text.utf16.count }
                precondition(weight <= 20000 || w.count == 1)
                cases += 1
            }
        }
        print("PASS \(cases) target/window combinations; \(count) focused checks")
    }
}
"""
with tempfile.TemporaryDirectory(prefix="mocca-deletion-window-") as folder:
    swift = Path(folder) / "Checks.swift"
    exe = Path(folder) / "checks"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(swift), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
