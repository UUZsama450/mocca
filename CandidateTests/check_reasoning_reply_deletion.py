"""Exercise actual deletion/version projection and action visibility methods.

Uses small in-memory message fixtures; persistence, memory refresh, observable
cache invalidation and viewport operations are stubs. Does not read phone chats
or prove which stored version appeared in the user's screenshot.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
app = (root / 'Mocca/AppModel.swift').read_text()
view = (root / 'Mocca/RootView.swift').read_text()
store = (root / 'Mocca/ConversationStore.swift').read_text()
def section(s, start, end):
    a = s.index(start)
    return s[a:s.index(end, a)]
source = r"""import Foundation
struct ChatMessage {
    enum Role { case assistant, user, system, tool }
    enum Status { case complete, streaming, cancelled, interrupted, failed }
    let id = UUID()
    var conversationID: UUID
    var role: Role = .assistant
    var text = ""
    var createdAt = Date()
    var status: Status = .complete
    var versionGroupID: String?
    var version = 0
    var reasoningSegments: [String] = []
    var toolEvents: [String] = []
    var attachments: [String] = []
"""
source += section(store, '    var isStreaming: Bool {', '    init(')
source += r"""
}
struct Conversation {
    var id = UUID()
    var truncateIndex = -1
    var versionSelections: [String: Int] = [:]
}
struct Preferences {
    var assistantMessageActionOrder = ["regenerate", "more"]
    var hiddenAssistantMessageActions: [String] = []
}
"""
source += section(app, 'private struct MessageWindowState:', 'private struct ConversationComposerPacket')
source += section(app, 'private struct SelectedMessageProjection {', 'private enum ConversationPersistenceState')
source += r"""
private final class Fixture {
    var conversations = [Conversation()]
    var preferences = Preferences()
    var messagesByConversation: [UUID: [ChatMessage]] = [:]
    // Projection cache behavior is outside this fixture, so always recompute.
    var selectedMessageProjectionCache: SelectedMessageProjectionCache? {
        get { nil }
        set {}
    }
    var activeStreamingMessageIDsByConversation: [UUID: UUID] = [:]
    var destructiveSaves = 0
    var conversationID: UUID { conversations[0].id }
    var visible: [ChatMessage] { selectedMessages(for: conversationID) }
    var raw: [ChatMessage] {
        get { messagesByConversation[conversationID] ?? [] }
        set { messagesByConversation[conversationID] = newValue }
    }
    func hasMultipleVersions(for message: ChatMessage) -> Bool {
        raw.filter { $0.versionGroupKey == message.versionGroupKey }.count > 1
    }
    func messageLocation(for id: UUID) -> (conversationID: UUID, index: Int)? {
        for (conversationID, messages) in messagesByConversation {
            if let index = messages.firstIndex(where: { $0.id == id }) {
                return (conversationID, index)
            }
        }
        return nil
    }
    func stopStreaming(ifConversationID id: UUID) {
        if let activeID = activeStreamingMessageIDsByConversation.removeValue(forKey: id),
           let index = messagesByConversation[id]?.firstIndex(where: { $0.id == activeID }) {
            messagesByConversation[id]?[index].status = .cancelled
        }
    }
    func messageWindow(for id: UUID, messages: [ChatMessage]) -> MessageWindowState {
        MessageWindowState(startIndex: 0, count: messages.count)
    }
    func conversationSummaryInputSnapshot(conversationID: UUID, rawMessages: [ChatMessage]) -> Int { 0 }
    func preserveMessageWindowAfterDeletion(for id: UUID, previousMessages: [ChatMessage],
        previousWindow: MessageWindowState, deletedLogicalIndex: Int?) {}
    func invalidateConversationDerivedMemoryAfterTranscriptMutation(conversationID: UUID, previousInput: Int) -> [UUID] { [] }
    func touchConversation(_ id: UUID) {}
    func saveImmediately(allowDestructiveMessageReduction: Bool) -> Bool {
        if allowDestructiveMessageReduction { destructiveSaves += 1 }; return true
    }
    func requestTranscriptMutationRefreshes(_ ids: [UUID]) {}
"""
source += section(app, '    private func selectedMessages(', '    func deletionLandingUserMessageID(')
source += section(app, '    private func selectedMessageProjection(', '    private func removeLogicalGroups(')
source += section(app, '    func deleteMessage(', '    func toggleMessageBookmark(')
source += r"""
}
private struct ActionFixture {
    let model: Fixture
    let message: ChatMessage
"""
source += section(view, '    private var shouldShowInlineActions:', '    private var hasVisibleReaction:').replace('private var', 'var')
source += r"""
}
@main struct Tests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1; print("PASS \(label)")
        }
        let single = Fixture()
        let prompt = ChatMessage(conversationID: single.conversationID, role: .user, text: "prompt")
        let reply = ChatMessage(conversationID: single.conversationID, text: "answer", reasoningSegments: ["reason"])
        let next = ChatMessage(conversationID: single.conversationID, role: .user, text: "next")
        single.raw = [prompt, reply, next]
        single.deleteMessage(reply.id)
        check(single.raw.map(\.id) == [prompt.id, next.id], "single delete removes the whole assistant record")
        check(single.visible.flatMap(\.reasoningSegments).isEmpty, "single delete leaves no reasoning segment in projection")
        check(single.destructiveSaves == 1, "removal requests durable destructive save")
        single.deleteMessage(reply.id)
        check(single.destructiveSaves == 1, "duplicate delete is a no-op")

        let versions = Fixture()
        let old = ChatMessage(conversationID: versions.conversationID,
            versionGroupID: "response", version: 0, reasoningSegments: ["128s-old-reasoning"])
        let latest = ChatMessage(conversationID: versions.conversationID, text: "complete answer",
            versionGroupID: "response", version: 1, reasoningSegments: ["new-reasoning"])
        let neighbor = ChatMessage(conversationID: versions.conversationID, role: .user, text: "next user")
        versions.raw = [old, latest, neighbor]
        versions.conversations[0].versionSelections["response"] = 1
        check(versions.visible.first?.id == latest.id, "selected full reply shown before deletion")
        versions.deleteMessage(latest.id)
        check(versions.visible.map(\.id) == [old.id, neighbor.id], "current-version delete reveals the surviving old record")
        check(!versions.raw.contains { $0.id == latest.id }
            && versions.visible.first?.reasoningSegments == ["128s-old-reasoning"],
              "remaining thought is the old version, not fields retained from the deleted reply")
        check(ActionFixture(model: versions, message: versions.visible[0]).shouldShowInlineActions,
              "complete reasoning-only survivor still exposes configured delete and regenerate actions")
        versions.deleteMessage(old.id)
        check(versions.visible.map(\.id) == [neighbor.id], "reasoning-only record can itself be deleted")

        versions.raw = [old, latest, neighbor]
        versions.deleteAllMessageVersions(latest.id)
        check(versions.raw.map(\.id) == [neighbor.id], "delete-all removes every version and their reasoning only within the group")
        let middle = ChatMessage(conversationID: versions.conversationID, text: "third answer",
            versionGroupID: "response", version: 2)
        versions.raw = [old, latest, middle, neighbor]
        versions.conversations[0].versionSelections["response"] = 2
        versions.deleteMessage(middle.id)
        check(versions.visible.first?.id == latest.id, "three-version deletion keeps nearest previous selection")

        let streaming = Fixture()
        let partial = ChatMessage(conversationID: streaming.conversationID,
            status: .streaming, reasoningSegments: ["partial"])
        streaming.raw = [partial]
        streaming.activeStreamingMessageIDsByConversation[streaming.conversationID] = partial.id
        streaming.deleteMessage(partial.id)
        check(streaming.raw.isEmpty && streaming.activeStreamingMessageIDsByConversation.isEmpty,
              "deleting streaming reasoning stops generation and removes its record")

        let actions = Fixture()
        for content in ["reasoning", "tool", "image", "text"] {
            var message = ChatMessage(conversationID: actions.conversationID)
            switch content {
            case "reasoning": message.reasoningSegments = ["thought"]
            case "tool": message.toolEvents = ["tool result"]
            case "image": message.attachments = ["image"]
            default: message.text = "answer"
            }
            check(ActionFixture(model: actions, message: message).shouldShowInlineActions,
                  "\(content)-only complete reply is actionable")
            message.status = .streaming
            check(!ActionFixture(model: actions, message: message).shouldShowInlineActions,
                  "\(content)-only streaming reply keeps current action suppression")
        }
        var empty = ChatMessage(conversationID: actions.conversationID)
        check(!ActionFixture(model: actions, message: empty).shouldShowInlineActions,
              "truly empty complete row keeps existing behavior")
        empty.status = .cancelled
        check(ActionFixture(model: actions, message: empty).shouldShowInlineActions,
              "cancelled empty reply keeps its existing recovery actions")
        empty.status = .complete; empty.reasoningSegments = ["thought"]
        actions.preferences.hiddenAssistantMessageActions = actions.preferences.assistantMessageActionOrder
        check(!ActionFixture(model: actions, message: empty).shouldShowInlineActions,
              "user-hidden actions remain hidden")
        print("PASS \(count) checks; actual screenshot identity and device rendering remain unverified")
    }
}
"""
with tempfile.TemporaryDirectory(prefix='mocca-reasoning-deletion-') as tmp:
    path = Path(tmp) / 'check.swift'; path.write_text(source)
    binary = Path(tmp) / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
