"""Exercise actual list branches and page mutations in a hidden macOS host.

Lightweight NSView probes replace message contents. All current-window probes
fit the hidden viewport, separating tree replacement from lazy eviction. This
checks structural identity and boundary transitions, not iPhone physics/FPS.
"""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/history-stable-parent/identity"
OUT.mkdir(parents=True, exist_ok=True)
BASE = "d38b5aa2bc1d4363d5d4c635e8c6639f168830e6"


def block(source, token):
    start = source.index(token)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


template = r'''
import AppKit
import SwiftUI
import Observation
// TYPES
private typealias ConversationLazyWindowIdentity = Int
private enum L10n { static func lookup(_ value: String) -> String { value } }
private struct ContextClearedDivider: View { var body: some View { Color.clear.frame(height: 1) } }
private struct Message: Identifiable { let id: UUID }
private struct ConversationMessageHost: Identifiable {
    let message: Message
    var id: UUID { message.id }
}
private struct MessageWindowState { let startIndex: Int; let count: Int; var endIndex: Int { startIndex + count } }
@MainActor @Observable private final class Fixture {
    // CONSTANTS
    let allMessages: [Message]
    let selectedConversationID = UUID()
    var messageWindowsByConversation: [UUID: MessageWindowState] = [:]
    var isCompressingContext = false
    var favorite: UUID?
    var compact = false
    var replacement = false
    var truncateIndex = -1
    init(_ total: Int) {
        allMessages = (0..<total).map { _ in Message(id: UUID()) }
        let count = min(total, 12)
        messageWindowsByConversation[selectedConversationID] = .init(startIndex: total - count, count: count)
    }
    var window: MessageWindowState { messageWindowsByConversation[selectedConversationID]! }
    var messages: [Message] { Array(allMessages[window.startIndex..<window.endIndex]) }
    var messageWindowStartIndex: Int { window.startIndex }
    var messageWindowEndIndex: Int { window.endIndex }
    var totalMessageCountForSelectedConversation: Int { allMessages.count }
    var anchor: ConversationBottomAnchorID {
        .init(positionRequest: .init(conversationID: selectedConversationID, request: 1), messageIDs: messages.map(\.id))
    }
    func selectedMessages(for id: UUID) -> [Message] { allMessages }
    func messageWindow(for id: UUID, messages: [Message]) -> MessageWindowState { window }
    func releaseConcreteConversationEntryWindow() {}
    // PAGING
}
@MainActor private enum Metrics {
    static var births: [UUID: Int] = [:]
    static var rows: [UUID: Int] = [:]
    static var hasTopSentinel = false
    static var hasBottomSentinel = false
}
private struct RowIDs: PreferenceKey {
    static var defaultValue: [UUID: Int] { [:] }
    static func reduce(value: inout [UUID: Int], nextValue: () -> [UUID: Int]) {
        value.merge(nextValue(), uniquingKeysWith: +)
    }
}
@MainActor private struct Row: NSViewRepresentable {
    let messageID: UUID
    func makeNSView(context: Context) -> NSView {
        Metrics.births[messageID, default: 0] += 1
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
@MainActor private struct Host: View {
    let model: Fixture
    let conversationMessageSpacing: CGFloat = 1
    var concreteFavoriteTargetMessageID: UUID? { model.favorite }
    let isGroupConversation = false
    var visibleTruncateIndex: Int { model.truncateIndex }
    let conversationLazyWindowIdentity = 1
    let bottomNavigationTailClearance: CGFloat = 0
    var usesBottomNavigationCompactWindow: Bool { model.compact }
    var messageReplacementConcreteWindowSessionID: Int? { model.replacement ? 1 : nil }
    let currentChatViewportSessionID = 1
    let isBoundedConversationEntry = false
    let nativeConversationContentReadyAnchorID: ConversationBottomAnchorID? = nil
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                let visibleMessages = model.messages
                let renderedMessageHosts = visibleMessages.map { ConversationMessageHost(message: $0) }
                let bottomAnchorID = model.anchor
                // BRANCHES
            }
        }
        .coordinateSpace(name: "chat-scroll")
        .onPreferenceChange(RowIDs.self) { Metrics.rows = $0 }
        .onPreferenceChange(MessageWindowTopFramePreferenceKey.self) { Metrics.hasTopSentinel = $0 != nil }
        .onPreferenceChange(MessageWindowBottomFramePreferenceKey.self) { Metrics.hasBottomSentinel = $0 != nil }
    }
    private func conversationMessageHost(
        _ host: ConversationMessageHost, isGroupConversation: Bool,
        visibleTruncateIndex: Int, bottomAnchorID: ConversationBottomAnchorID,
        bottomNavigationTailClearance: CGFloat
    ) -> some View {
        Row(messageID: host.message.id).frame(height: 4).id(host.message.id)
            .preference(key: RowIDs.self, value: [host.message.id: 1])
    }
    // STACKS
}
@main private struct Check {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let candidate = // CANDIDATE
        var checks: [String: Bool] = [:]
        var transitions: [[String: Any]] = []
        for total in [1, 12, 60, 120, 500] {
            let fixture = Fixture(total)
            let host = NSHostingView(rootView: Host(model: fixture))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 2200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            func settle() {
                let deadline = Date().addingTimeInterval(0.08)
                repeat {
                    host.needsLayout = true; host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                } while Date() < deadline
            }
            func check(_ label: String, _ value: Bool) { checks["\(total): \(label)"] = value }
            func rows(_ label: String) {
                check(label + " exact IDs, once each", Set(Metrics.rows.keys) == Set(fixture.messages.map(\.id)) && Metrics.rows.values.allSatisfy { $0 == 1 })
                check(label + " top sentinel", Metrics.hasTopSentinel == fixture.hasEarlierMessages)
                check(label + " bottom sentinel", Metrics.hasBottomSentinel == fixture.hasLaterMessages)
                check(label + " bounded window", fixture.window.count <= 360)
            }
            settle(); rows("initial")
            for earlier in [true, false] {
                var page = 0
                while earlier ? fixture.hasEarlierMessages : fixture.hasLaterMessages {
                    let oldIDs = Set(fixture.messages.map(\.id))
                    let births = Metrics.births, oldHead = fixture.hasEarlierMessages
                    let oldFirst = fixture.messages.first!.id
                    let loaded = earlier ? fixture.loadEarlierMessages() : fixture.loadLaterMessages()
                    settle(); page += 1
                    let retained = oldIDs.intersection(fixture.messages.map(\.id))
                    let recreated = retained.filter { Metrics.births[$0, default: 0] > births[$0, default: 0] }.count
                    let switchesBranch = oldHead != fixture.hasEarlierMessages
                    let label = "\(earlier ? "earlier" : "later") page \(page)"
                    check(label + " load succeeds", loaded)
                    check(label + " retained row identity", recreated == ((!candidate && switchesBranch) ? retained.count : 0))
                    if earlier { check(label + " old first anchor survives", fixture.messages.contains { $0.id == oldFirst }) }
                    rows(label)
                    if switchesBranch {
                        transitions.append(["total":total,"direction":earlier ? "earlier":"later",
                                            "retained":retained.count,"recreated":recreated])
                    }
                    precondition(page < 40)
                }
                check("\(earlier) exhausted load is a no-op", !(earlier ? fixture.loadEarlierMessages() : fixture.loadLaterMessages()))
            }
            // Explicit favorites retain their concrete target plus the earlier sentinel.
            if fixture.hasEarlierMessages {
                let old = fixture.messages.map(\.id), before = Metrics.births
                fixture.favorite = old.first; settle(); rows("favorite concrete target")
                check("favorite keeps other lazy hosts", old.dropFirst().allSatisfy {
                    Metrics.births[$0, default: 0] == before[$0, default: 0] + (candidate ? 0 : 1)
                })
                fixture.favorite = nil; settle(); rows("favorite released")
            }
            // Intentional compact/replacement owners still render every row once.
            let tailCount = min(total, 12)
            fixture.messageWindowsByConversation[fixture.selectedConversationID] = .init(startIndex: total-tailCount, count: tailCount)
            fixture.compact = true; settle(); rows("compact navigation")
            fixture.compact = false; fixture.replacement = true; settle(); rows("replacement landing")
            fixture.replacement = false; fixture.truncateIndex = fixture.messages.count
            fixture.isCompressingContext = true; settle(); rows("trailing divider and compression")
            check("hidden host", !window.isVisible)
            check("full history retained", fixture.allMessages.count == total)
            window.contentView = nil
        }
        let output: [String: Any] = ["checks":checks,"transitions":transitions,
            "scope":"Extracted production branches/stacks/page mutations; lightweight rows in hidden macOS SwiftUI host, not phone scroll/FPS."]
        print(String(data:try JSONSerialization.data(withJSONObject: output, options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
        if !checks.values.allSatisfy({$0}) { exit(1) }
    }
}
'''

model = (ROOT / "Mocca/AppModel.swift").read_text()
constants = "\n".join(re.search(r"    private static let " + name + r" = \d+", model).group()
                      for name in ["messageWindowPageSize", "messageWindowLoadedMax"])
paging = "\n".join(block(model, token) for token in [
    "var hasEarlierMessages:", "var hasLaterMessages:",
    "func loadEarlierMessages()", "func loadLaterMessages()",
])
summary = {}
for label in ["baseline", "candidate"]:
    source = (subprocess.check_output(["git", "show", BASE + ":Mocca/RootView.swift"], cwd=ROOT, text=True)
              if label == "baseline" else (ROOT / "Mocca/RootView.swift").read_text())
    start = source.index("                                let concreteFavoriteTargetHost =")
    end = source.index("                                .padding(.horizontal, 18)", start)
    types = "\n".join(block(source, "private struct " + name + ":") for name in [
        "ConversationPositionRequestKey", "ConversationBottomAnchorID", "MessageWindowEdgeID",
        "MessageWindowEdgeFrame", "MessageWindowTopFramePreferenceKey", "MessageWindowBottomFramePreferenceKey",
    ])
    stacks = "\n".join(block(source, "private func " + name + "(") for name in [
        "conversationLazyMessageStack", "conversationCompactBottomMessageStack",
    ])
    swift = (template.replace("// TYPES", types).replace("// CONSTANTS", constants)
             .replace("// PAGING", paging).replace("// BRANCHES", source[start:end])
             .replace("// STACKS", stacks).replace("// CANDIDATE", "true" if label == "candidate" else "false"))
    path = OUT / (label + ".swift")
    path.write_text(swift)
    exe = OUT / label
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(path), "-o", str(exe)], check=True)
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=35)
    (OUT / (label + "-stderr.log")).write_text(run.stderr)
    result = json.loads(run.stdout)
    (OUT / (label + "-results.json")).write_text(json.dumps(result, indent=2) + "\n")
    failed = [k for k, v in result["checks"].items() if not v]
    summary[label] = {"checks":len(result["checks"]), "failed":failed, "transitions":result["transitions"]}
    assert run.returncode == 0 and not failed, summary[label]
(OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
