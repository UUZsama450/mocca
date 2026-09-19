#!/usr/bin/python3
"""Run extracted context-confirmation decisions against synthetic conversations.

The real routing, capture, resolve and clear/restore functions run in a Foundation
host. Storage and the compression entry point are counting receivers: this test
never opens app data or sends a model request. The compression algorithm and clear
implementation are also checked byte-for-byte against the 5031 source baseline.
SwiftUI alert presentation and on-device appearance remain UI acceptance work.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "6a4c8efe4bc66593a13a7c1304b65f6d7af7d9bd"
app = (ROOT / "Mocca/AppModel.swift").read_text()
sheet = (ROOT / "Mocca/BottomToolsSheet.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


baseline = subprocess.check_output(
    ["git", "show", f"{BASELINE}:Mocca/AppModel.swift"], cwd=ROOT, text=True
)
for marker in ["    func compressCurrentContext()", "    func toggleClearContext()"]:
    assert declaration(app, marker) == declaration(baseline, marker), marker

assert ".onChange(of: appModel.selectedConversationID) {\n            appModel.cancelContextManagementConfirmation()" in sheet
assert "appModel.cancelContextManagementConfirmation()" in declaration(sheet, ".onDisappear")
assert "presenting: appModel.pendingContextManagementConfirmation" in sheet
assert "@State private var isContextManagementConfirmationPresented = false" in sheet
assert "isPresented: $isContextManagementConfirmationPresented" in sheet
assert ".onChange(of: appModel.pendingContextManagementConfirmation?.id, initial: true)" in sheet
assert 'Button("取消", role: .cancel)' in sheet
assert "resolveContextManagementConfirmation(confirmation, confirmed: false)" in sheet
assert "resolveContextManagementConfirmation(confirmation, confirmed: true)" in sheet
assert "总结对话并开始新聊天" not in sheet
assert "title: appModel.clearContextOperation.title" in sheet

swift = "import Foundation\n"
for marker in ["enum BottomToolAction:", "enum ContextManagementOperation:"]:
    swift += declaration(sheet, marker) + "\n"
for marker in ["struct ContextManagementConfirmation:", "fileprivate struct ContextManagementSourceState:"]:
    swift += declaration(app, marker) + "\n"

swift += r'''
struct ProviderConfiguration: Equatable {
    var id = UUID()
    var configuration = "fixture provider"
}
struct ModelConfiguration: Equatable {
    var id = "fixture-model"
    var configuration = "fixture model"
}
struct ResolvedChatModelContext {
    var provider = ProviderConfiguration()
    var model = ModelConfiguration()
}
struct Conversation: Equatable {
    var id = UUID()
    var title = "Synthetic chat"
    var truncateIndex = -1
    var summary: String?
    var assistantID: String? = "fixture-assistant"
    var groupAssistantIDs: [String] = []
}
struct ChatMessage: Equatable {
    var id = UUID()
    var text = "Synthetic message"
    var attachmentRevision = 0
}
@MainActor final class AppModel {
    var conversations = [Conversation(), Conversation()]
    var selectedConversationID: UUID
    var messagesByConversation: [UUID: [ChatMessage]]
    var selectedConversationIsStreaming = false
    var isCompressingContext = false
    var isBottomToolsPresented = true
    var pendingContextManagementConfirmation: ContextManagementConfirmation?
    var resolvedContext: ResolvedChatModelContext? = ResolvedChatModelContext()
    var contextMessageIDs: Set<UUID>?
    var assistants: [Assistant] = []
    struct Assistant { var id = UUID() }
    var saveCalls = 0
    var compressionCalls = 0
    var otherActionCalls = 0
    init() {
        selectedConversationID = conversations[0].id
        messagesByConversation = [
            conversations[0].id: [ChatMessage(text: "First"), ChatMessage(text: "Second")],
            conversations[1].id: [ChatMessage(text: "Other chat")]
        ]
    }
    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }
    func selectedContextMessages(for id: UUID) -> [ChatMessage] {
        let boundary = conversations.first { $0.id == id }?.truncateIndex ?? -1
        return (messagesByConversation[id] ?? []).enumerated().compactMap { index, message in
            guard index >= boundary, contextMessageIDs?.contains(message.id) ?? true else { return nil }
            return message
        }
    }
    func compressionModelContext(for conversation: Conversation) -> ResolvedChatModelContext? {
        resolvedContext
    }
    func saveImmediately() { saveCalls += 1 }
    func compressCurrentContext() { compressionCalls += 1 }
    func updateSelectedGroupConversation(assistantIDs: [String]) { otherActionCalls += 1 }
    func createGroupConversation(assistantIDs: [UUID]) { otherActionCalls += 1 }
'''
for marker in [
    "    var clearContextOperation:",
    "    private func requestContextManagementConfirmation(",
    "    func cancelContextManagementConfirmation()",
    "    func resolveContextManagementConfirmation(",
    "    private func contextManagementSourceState(",
    "    func toggleClearContext()",
    "    func routeBottomToolAction(",
]:
    swift += declaration(app, marker) + "\n"
swift += "}\n"

swift += r'''
@main struct ContextConfirmationHost {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        precondition(value(), label)
    }
    @MainActor static func request(_ model: AppModel, _ action: BottomToolAction) -> ContextManagementConfirmation {
        let conversations = model.conversations
        let messages = model.messagesByConversation
        model.routeBottomToolAction(action)
        check(model.conversations == conversations && model.messagesByConversation == messages, "Request is read-only")
        check(model.saveCalls == 0 && model.compressionCalls == 0 && model.isBottomToolsPresented, "Request neither saves nor compresses nor closes tools")
        guard let pending = model.pendingContextManagementConfirmation else {
            preconditionFailure("Expected confirmation")
        }
        return pending
    }
    @MainActor static func unchangedAfterResolution(
        _ model: AppModel, _ request: ContextManagementConfirmation, confirmed: Bool, label: String
    ) {
        let conversations = model.conversations
        let messages = model.messagesByConversation
        model.resolveContextManagementConfirmation(request, confirmed: confirmed)
        check(model.conversations == conversations && model.messagesByConversation == messages, "\(label): conversation content untouched")
        check(model.saveCalls == 0 && model.compressionCalls == 0, "\(label): zero persistence/network entry")
    }
    @MainActor static func main() {
        // The source alert binds only local @State. Simulate either framework
        // ordering without making presentation dismissal consume its request.
        for dismissFirst in [true, false] {
            for confirmed in [true, false] {
                for action in [BottomToolAction.clearContext, .compressContext] {
                    let model = AppModel()
                    let pending = request(model, action)
                    var isContextManagementConfirmationPresented = true
                    if dismissFirst { isContextManagementConfirmationPresented = false }
                    model.resolveContextManagementConfirmation(pending, confirmed: confirmed)
                    if !dismissFirst { isContextManagementConfirmationPresented = false }
                    check(!isContextManagementConfirmationPresented, "Alert dismissed in both callback orders")
                    check(model.pendingContextManagementConfirmation == nil, "Explicit decision consumes token in both orders")
                    check(model.saveCalls == (confirmed && action == .clearContext ? 1 : 0), "Save decision independent of presentation ordering")
                    check(model.compressionCalls == (confirmed && action == .compressContext ? 1 : 0), "Compression decision independent of presentation ordering")
                }
            }
        }
        for action in [BottomToolAction.clearContext, .compressContext] {
            let model = AppModel()
            let pending = request(model, action)
            unchangedAfterResolution(model, pending, confirmed: false, label: "Cancel")
            check(model.pendingContextManagementConfirmation == nil && model.isBottomToolsPresented, "Cancel only dismisses confirmation")

            let dismissed = request(model, action)
            model.cancelContextManagementConfirmation() // Sheet disappearance / conversation onChange.
            unchangedAfterResolution(model, dismissed, confirmed: true, label: "Dismissed request")

            let old = request(model, action)
            let fresh = request(model, action)
            unchangedAfterResolution(model, old, confirmed: true, label: "Replaced request")
            check(model.pendingContextManagementConfirmation?.id == fresh.id, "Old response preserves new request")
        }

        let clear = AppModel()
        let clearRequest = request(clear, .clearContext)
        check(clearRequest.operation == .clear && clear.clearContextOperation == .clear, "Clear label captures operation")
        clear.resolveContextManagementConfirmation(clearRequest, confirmed: true)
        check(clear.conversations[0].truncateIndex == 2 && clear.saveCalls == 1 && !clear.isBottomToolsPresented, "Confirmed clear sets current tail once")
        clear.resolveContextManagementConfirmation(clearRequest, confirmed: true)
        check(clear.saveCalls == 1 && clear.conversations[0].truncateIndex == 2, "Repeated confirmation cannot toggle back")
        clear.isBottomToolsPresented = true
        clear.saveCalls = 0
        let restore = request(clear, .clearContext)
        check(restore.operation == .restore && clear.clearContextOperation == .restore, "Tail boundary is explicitly restore")
        unchangedAfterResolution(clear, restore, confirmed: false, label: "Cancel restore")
        let confirmedRestore = request(clear, .clearContext)
        clear.resolveContextManagementConfirmation(confirmedRestore, confirmed: true)
        check(clear.conversations[0].truncateIndex == -1 && clear.saveCalls == 1, "Restore preserves original toggle")
        check(clear.messagesByConversation[clear.selectedConversationID]?.count == 2, "Clear and restore preserve messages")

        let compress = AppModel()
        let originalConversations = compress.conversations
        let compressRequest = request(compress, .compressContext)
        compress.resolveContextManagementConfirmation(compressRequest, confirmed: true)
        check(compress.compressionCalls == 1 && compress.saveCalls == 0 && !compress.isBottomToolsPresented, "Confirmed compression enters original action exactly once")
        check(compress.conversations == originalConversations, "Confirmation creates no conversation")
        compress.resolveContextManagementConfirmation(compressRequest, confirmed: true)
        check(compress.compressionCalls == 1, "Duplicate compression response rejected")

        let changes: [(String, (AppModel) -> Void)] = [
            ("Switched chat", { $0.selectedConversationID = $0.conversations[1].id }),
            ("New message", { $0.messagesByConversation[$0.selectedConversationID]?.append(ChatMessage()) }),
            ("Edited message", { $0.messagesByConversation[$0.selectedConversationID]?[0].text = "Edited" }),
            ("Whitespace edit", { $0.messagesByConversation[$0.selectedConversationID]?[1].text += "\n" }),
            ("Attachment change", { $0.messagesByConversation[$0.selectedConversationID]?[0].attachmentRevision += 1 }),
            ("Replaced message at same count", { $0.messagesByConversation[$0.selectedConversationID]?[0] = ChatMessage() }),
            ("Deleted message", { $0.messagesByConversation[$0.selectedConversationID]?.removeLast() }),
            ("Changed summary", { $0.conversations[0].summary = "New summary" }),
            ("Changed boundary", { $0.conversations[0].truncateIndex = 1 }),
            ("Changed selected version", { $0.contextMessageIDs = [$0.messagesByConversation[$0.selectedConversationID]![0].id] }),
            ("Changed assistant", { $0.conversations[0].assistantID = "another assistant" }),
            ("Changed group", { $0.conversations[0].groupAssistantIDs = ["one", "two"] }),
            ("Started stream", { $0.selectedConversationIsStreaming = true }),
            ("Started compression", { $0.isCompressingContext = true }),
            ("Tools closed", { $0.isBottomToolsPresented = false }),
            ("Conversation removed", { $0.conversations.removeFirst() })
        ]
        for action in [BottomToolAction.clearContext, .compressContext] {
            for (label, mutate) in changes {
                let model = AppModel()
                let pending = request(model, action)
                mutate(model)
                unchangedAfterResolution(model, pending, confirmed: true, label: label)
                check(model.pendingContextManagementConfirmation == nil, "\(label): invalid confirmation consumed")
            }
        }

        for change in [0, 1, 2] {
            let model = AppModel()
            let pending = request(model, .compressContext)
            if change == 0 { model.resolvedContext?.provider.configuration = "Changed provider" }
            if change == 1 { model.resolvedContext?.model.configuration = "Changed model" }
            if change == 2 { model.resolvedContext = nil }
            unchangedAfterResolution(model, pending, confirmed: true, label: "Compression destination changed")
        }
        for unavailable in [0, 1, 2, 3] {
            let model = AppModel()
            if unavailable == 0 { model.selectedConversationIsStreaming = true }
            if unavailable == 1 { model.isCompressingContext = true }
            if unavailable == 2 { model.resolvedContext = nil }
            if unavailable == 3 { model.conversations[0].truncateIndex = 2 }
            model.routeBottomToolAction(.compressContext)
            check(model.pendingContextManagementConfirmation == nil && model.compressionCalls == 0, "Original compression precondition retained")
        }
        for action in [BottomToolAction.clearContext, .compressContext] {
            let empty = AppModel()
            empty.messagesByConversation[empty.selectedConversationID] = []
            empty.routeBottomToolAction(action)
            check(empty.pendingContextManagementConfirmation == nil && empty.saveCalls == 0 && empty.compressionCalls == 0, "Empty chat no action")
        }

        let unrelated = AppModel()
        let valid = request(unrelated, .clearContext)
        unrelated.conversations[1].summary = "Other conversation changed"
        unrelated.conversations[0].title = "Renamed"
        unrelated.resolvedContext = nil
        unrelated.resolveContextManagementConfirmation(valid, confirmed: true)
        check(unrelated.saveCalls == 1, "Unrelated changes do not block clear")

        let resumed = AppModel()
        resumed.selectedConversationIsStreaming = true
        let duringStream = request(resumed, .clearContext)
        resumed.selectedConversationIsStreaming = false
        unchangedAfterResolution(resumed, duringStream, confirmed: true, label: "Clear streaming state changed")

        let restoredState = AppModel()
        let same = request(restoredState, .clearContext)
        restoredState.conversations[0].summary = "Transient"
        restoredState.conversations[0].summary = nil
        restoredState.resolveContextManagementConfirmation(same, confirmed: true)
        check(restoredState.saveCalls == 1, "Identical restored context remains a valid confirmation")
        print("CONTEXT_MANAGEMENT_CONFIRMATION=PASS assertions=\(checks)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="mocca-context-confirmation-") as directory:
    directory = Path(directory)
    source = directory / "ContextConfirmationHost.swift"
    binary = directory / "ContextConfirmationHost"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("CONTEXT_ALGORITHMS_UNCHANGED=PASS baseline=5031; ALERT_WIRING=PASS")
