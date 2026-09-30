import Foundation

// PRODUCT_CODECS
// PRODUCT_LEDGER

// Model DTOs and external endpoints are controlled fixtures. Actual product
// methods below own all decisions about raw text, display, and finalization.
enum Role { case user, assistant }
enum Status: String { case streaming, complete, cancelled, running }
struct ReasoningSegment { var text: String; var startedAt: Date; var finishedAt: Date? }
struct TokenUsage {
    var promptTokens: Int?; var completionTokens: Int?; var cachedTokens: Int?; var totalTokens: Int?
}
struct ToolEvent {
    var providerEventID: String; var name: String; var argumentsJSON: String?
    var status: Status; var resultText: String?; var updatedAt = Date.now
}
struct Attachment { var metadata: [String: String] = [:] }
struct Reactions { var assistantReaction: String?; var assistantReactionAuthorID: UUID? }
struct ChatMessage {
    var id = UUID(); var text = ""; var role: Role = .assistant; var updatedAt = Date.now
    var status: Status = .streaming; var reasoningSegments: [ReasoningSegment] = []
    var tokenUsage: TokenUsage?; var toolEvents: [ToolEvent] = []; var attachments: [Attachment] = []
    var parts: [String] = []; var versionGroupKey = "fixture"; var reactions = Reactions()
}
struct AssistantReactionContext { var targetMessageID: UUID; var assistantAuthorID: UUID }
struct Call { var id: String; var name: String; var arguments: [String: String] }
struct Result { var id: String; var content: String }
enum ChatStreamEvent {
    case text(String), reasoning(String), usage(TokenUsage), toolCalls([Call]), toolResults([Result])
    case imageGenerationProgress(String), generatedImage(Data, String)
}
enum AIChatServiceError: Error { case generatedImageSaveFailed }
enum AttachmentStore {
    static func saveGeneratedImage(data: Data, mimeType: String) -> Attachment? { Attachment() }
}
enum NativeImageReplyPresentation {
    static let source = "fixture"
    static func update(_ message: inout ChatMessage, stage: String, completed: Bool = false) {}
    static func finish(_ message: inout ChatMessage, failureDescription: String?) {}
}
@MainActor final class IOSBackgroundGenerationManager {
    static let shared = IOSBackgroundGenerationManager()
    func recordProgress(runID: UUID) {}
    func stageCompletedMessage(runID: UUID, message: ChatMessage) {}
}
enum StreamDeliveryTrace {
    static let isEnabled = false
    static func recordDisplayFilter(messageID: UUID, inputUTF16: Int, outputUTF16: Int) {}
    static func recordTextPipeline(messageID: UUID, detailBuild: TimeInterval) {}
    static func published(messageID: UUID, shownUTF16: Int, codecDuration: TimeInterval, rebuildDuration: TimeInterval) {}
    static func finish(messageID: UUID, rawUTF16: Int, shownUTF16: Int, reason: String) {}
}

@MainActor final class Model {
    var selectedConversationID = UUID()
    var activeStreamingMessageIDsByConversation: [UUID: UUID] = [:]
    var rawStreamingTextByMessageID: [UUID: String] = [:]
    var streamDisplayTasksByMessageID: [UUID: Task<Void, Never>] = [:]
    var streamDisplayBatchCharactersByMessageID: [UUID: Int] = [:]
    var streamDisplaySuspensionLedgersByMessageID: [UUID: StreamingTextDisplaySuspensionLedger] = [:]
    var streamDidPublishFirstVisibleTextMessageIDs = Set<UUID>()
    var searchImageCandidatesByMessageID: [UUID: [SearchImageCandidate]] = [:]
    var pendingImageRequestsByMessageID: [UUID: [ExternalImageGenerationRequest]] = [:]
    var pendingSearchImageRequestsByMessageID: [UUID: [SearchImageRequest]] = [:]
    var conversationMessageStore: [UUID: [ChatMessage]] = [:]
    var persistenceTask: Task<Void, Never>?
    var saved: [UUID: [ChatMessage]] = [:]
    var filterCalls = 0
    var persistenceSchedules = 0
    var immediateSaves = 0
    static func rebuiltParts(for message: ChatMessage) -> [String] { [message.text] }
    static func isEmptyAssistantResponse(_ message: ChatMessage) -> Bool {
        message.text.isEmpty && message.reasoningSegments.isEmpty && message.attachments.isEmpty
    }
    func scheduleStreamPersistence() { persistenceSchedules += 1 }
    func releaseSendPresentationGate(conversationID: UUID, assistantMessageID: UUID?) {}
    func reconcileVersionSelection(conversationID: UUID, groupKey: String, rawMessages: [ChatMessage]) {}
    func touchConversation(_ id: UUID) {}
    func saveImmediately(allowDestructiveMessageReduction: Bool) -> Bool {
        saved = conversationMessageStore; immediateSaves += 1; return true
    }
    func completeFinishedStreamingPersistence(didSave: Bool, cancelled: Bool, messageID: UUID,
                                             completedMessage: ChatMessage?, conversationID: UUID) {}

    // PRODUCT_MEMBERS

    func begin(conversation: UUID? = nil) -> (UUID, UUID) {
        let conversation = conversation ?? selectedConversationID
        let message = ChatMessage()
        conversationMessageStore[conversation] = [message]
        activeStreamingMessageIDsByConversation[conversation] = message.id
        rawStreamingTextByMessageID[message.id] = ""
        return (conversation, message.id)
    }
    func append(_ text: String, _ ids: (UUID, UUID)) throws {
        try appendStreamingEvent(.text(text), conversationID: ids.0, messageID: ids.1)
    }
    func suspend(_ ids: (UUID, UUID), _ owner: StreamingTextDisplaySuspensionOwner, _ value: Bool) {
        setStreamingTextDisplaySuspended(conversationID: ids.0, messageID: ids.1, owner: owner, suspended: value)
    }
    func shown(_ ids: (UUID, UUID)) -> String { conversationMessageStore[ids.0]!.last!.text }
    func finish(_ ids: (UUID, UUID), cancelled: Bool = false, failure: String? = nil) -> ChatMessage? {
        finishStreaming(conversationID: ids.0, removeIfEmpty: true, cancelled: cancelled, failureDescription: failure)
    }
    func drain(_ ids: (UUID, UUID)) {
        // Deterministic display steps call the unmodified production publisher.
        // Real timer delivery is covered separately below.
        streamDisplayTasksByMessageID[ids.1]?.cancel()
        streamDisplayTasksByMessageID.removeValue(forKey: ids.1)
        for _ in 0..<8 {
            if publishNextStreamingTextDisplayStep(conversationID: ids.0, messageID: ids.1) { return }
        }
        fatalError("catch-up failed to terminate")
    }
}

@main @MainActor enum StreamDisplayWorkTests {
    static var checks = 0
    static var behavior: [String: String] = [:]
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }
    static func emptyState(_ model: Model, _ ids: (UUID, UUID)) {
        expect(model.rawStreamingTextByMessageID[ids.1] == nil, "raw state leaked")
        expect(model.streamDisplayTasksByMessageID[ids.1] == nil, "display task leaked")
        expect(model.streamDisplayBatchCharactersByMessageID[ids.1] == nil, "batch leaked")
        expect(model.streamDisplaySuspensionLedgersByMessageID[ids.1] == nil, "lease leaked")
        expect(!model.streamDidPublishFirstVisibleTextMessageIDs.contains(ids.1), "first text flag leaked")
        expect(model.activeStreamingMessageIDsByConversation[ids.0] == nil, "active stream leaked")
    }
    static func main() async throws {
        let model = Model(), ids = model.begin()
        let chunk = "示例👩🏽‍💻e\u{301}——正文和换行\n\n下一行🙂\n"
        model.suspend(ids, .drawer, true)
        for _ in 0..<128 { try model.append(chunk, ids) }
        let suspendedCalls = model.filterCalls
        expect(model.rawStreamingTextByMessageID[ids.1] == String(repeating: chunk, count: 128), "lost raw chunks")
        expect(model.shown(ids).isEmpty && model.persistenceSchedules == 0, "hidden text published")
        expect(model.streamDisplayTasksByMessageID.isEmpty, "hidden stream started display timer")
        model.suspend(ids, .drawer, false)
        expect(model.shown(ids).count == 8, "first prefix changed")
        expect(model.filterCalls == suspendedCalls + 1, "first resume did not filter exactly once")
        model.drain(ids)
        let expected = String(repeating: chunk, count: 128).trimmingCharacters(in: .whitespacesAndNewlines)
        expect(model.shown(ids) == expected, "catch-up text mismatch")
        let completed = model.finish(ids)!
        expect(completed.text == expected && model.saved[ids.0]!.last!.text == expected, "final/save lost text")
        emptyState(model, ids)
        behavior["first-prefix-and-long-catch-up"] = completed.text

        let resume = Model(), rid = resume.begin()
        try resume.append("已经显示的正文", rid)
        let initialCalls = resume.filterCalls
        var raw = "已经显示的正文"
        for i in 0..<20 {
            resume.suspend(rid, .drawer, true)
            let shown = resume.shown(rid)
            let next = "第\(i)段🙂"; raw += next
            try resume.append(next, rid)
            resume.suspend(rid, .drawer, false)
            expect(resume.shown(rid) == shown, "resume flushed synchronously")
            expect(resume.streamDisplayTasksByMessageID.count == 1, "missing or duplicate timer")
        }
        let resumeCalls = resume.filterCalls - initialCalls
        resume.drain(rid)
        expect(resume.shown(rid) == raw, "rapid reversal lost backlog")
        behavior["rapid-reversal"] = resume.finish(rid)!.text
        emptyState(resume, rid)

        // Independent owners must all release, regardless of order.
        let owners: [StreamingTextDisplaySuspensionOwner] = [.drawer, .detachedTail, .codeDisclosure(UUID())]
        let orders = [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]]
        for visible in [false, true] {
            for order in orders {
                let m = Model(), id = m.begin()
                if visible { try m.append("原文", id) }
                for owner in owners { m.suspend(id, owner, true) }
                let shown = m.shown(id)
                try m.append("追加的完整正文🙂", id)
                for index in order.prefix(2) {
                    m.suspend(id, owners[index], false)
                    expect(m.shown(id) == shown && m.streamDisplayTasksByMessageID.isEmpty, "early resume with another owner")
                }
                m.suspend(id, owners[order.last!], false)
                m.drain(id)
                let expected = (visible ? "原文" : "") + "追加的完整正文🙂"
                expect(m.shown(id) == expected, "last owner failed to resume")
                expect(m.finish(id)!.text == expected, "owner combination final mismatch")
                emptyState(m, id)
            }
        }
        behavior["owner-release-orders"] = "12 passed"

        // Completion/cancellation/failure while hidden must use raw, never the
        // displayed prefix. Literal trailing '<' is only suppressed for display.
        for visible in [false, true] {
            for mode in ["complete", "cancel", "failure"] {
                let m = Model(), id = m.begin()
                if visible { try m.append("开头", id) }
                m.suspend(id, .drawer, true)
                for text in ["隐藏正文", "👨‍👩‍👧‍👦", "<"] { try m.append(text, id) }
                let final = m.finish(id, cancelled: mode == "cancel", failure: mode == "failure" ? "fixture" : nil)!
                let expected = (visible ? "开头" : "") + "隐藏正文👨‍👩‍👧‍👦<"
                expect(final.text == expected, "hidden final truncated")
                expect(final.status == (mode == "cancel" ? .cancelled : .complete), "final status changed")
                expect(m.saved[id.0]!.last!.text == expected && m.immediateSaves == 1, "final save did not receive raw result")
                emptyState(m, id)
                let calls = m.filterCalls
                m.suspend(id, .drawer, false)
                try m.append("过期片段", id)
                expect(m.filterCalls == calls && m.shown(id) == expected, "stale callback changed completed reply")
                behavior["hidden-\(visible)-\(mode)"] = final.text + final.status.rawValue
            }
        }

        // Split every kind of control block one Character at a time and resume
        // mid-marker; hidden protocol content must never become visible.
        let controls = ["<!--mocca-reaction:❤️-->", "<!--kelivo-reaction:👍-->",
                        "<kg>{\"prompt\":\"一只猫\"}</kg>", "<ks-image>{\"id\":\"cat\"}</ks-image>"]
        for (index, control) in controls.enumerated() {
            let m = Model(), id = m.begin()
            let candidate = SearchImageCandidate(id: "cat", title: "cat", url: "https://example.invalid/cat", sourceURL: nil)
            m.searchImageCandidatesByMessageID[id.1] = [candidate]
            m.suspend(id, .drawer, true)
            let chars = Array(control)
            for char in chars.prefix(3) { try m.append(String(char), id) }
            m.suspend(id, .drawer, false)
            expect(m.shown(id).isEmpty, "partial marker leaked on first resume")
            for char in chars.dropFirst(3) {
                try m.append(String(char), id)
                expect(m.shown(id).isEmpty, "control block leaked while arriving")
            }
            try m.append("可见正文", id)
            expect(m.shown(id) == "可见正文", "first visible text after marker delayed/lost")
            let final = m.finish(id)!
            expect(final.text == "可见正文", "control final mismatch")
            expect((m.pendingImageRequestsByMessageID[id.1]?.count ?? 0) == (index == 2 ? 1 : 0), "image request changed")
            expect(m.pendingSearchImageRequestsByMessageID[id.1]?.count == 1, "search image request lost")
            emptyState(m, id)
            behavior["split-marker-\(index)"] = final.text
        }

        // Switching selected streams releases only the old drawer owner.
        let switcher = Model(), old = switcher.begin(), new = switcher.begin(conversation: UUID())
        switcher.setDrawerStreamingTextDisplaySuspended(true)
        switcher.suspend(old, .detachedTail, true)
        try switcher.append("旧聊天全文", old)
        switcher.selectedConversationID = new.0
        switcher.setDrawerStreamingTextDisplaySuspended(true)
        try switcher.append("新聊天全文", new)
        switcher.setDrawerStreamingTextDisplaySuspended(false)
        expect(switcher.shown(old).isEmpty, "switch resumed old detached stream")
        expect(switcher.shown(new) == "新聊天全文", "switch failed to resume selected stream")
        switcher.suspend(old, .detachedTail, false)
        expect(switcher.shown(old) == "旧聊天全文", "old stream could not resume")
        behavior["switch-old"] = switcher.finish(old)!.text
        behavior["switch-new"] = switcher.finish(new)!.text
        emptyState(switcher, old); emptyState(switcher, new)

        // Non-text events still use their existing routes while text is hidden.
        let events = Model(), eid = events.begin()
        events.suspend(eid, .drawer, true)
        try events.appendStreamingEvent(.reasoning("思考片段"), conversationID: eid.0, messageID: eid.1)
        try events.appendStreamingEvent(.usage(TokenUsage(promptTokens: 2, completionTokens: 3)), conversationID: eid.0, messageID: eid.1)
        try events.appendStreamingEvent(.toolCalls([Call(id: "tool", name: "search", arguments: [:])]), conversationID: eid.0, messageID: eid.1)
        try events.appendStreamingEvent(.toolResults([Result(id: "tool", content: "result")]), conversationID: eid.0, messageID: eid.1)
        try events.append("正文", eid)
        expect(events.conversationMessageStore[eid.0]!.last!.reasoningSegments.last!.finishedAt == nil, "hidden text finished reasoning early")
        events.suspend(eid, .drawer, false)
        let eventMessage = events.finish(eid)!
        expect(eventMessage.reasoningSegments.last!.text == "思考片段" && eventMessage.reasoningSegments.last!.finishedAt != nil, "reasoning mismatch")
        expect(eventMessage.tokenUsage!.totalTokens == 5 && eventMessage.toolEvents.last!.resultText == "result", "non-text event lost")
        behavior["reasoning-tools-usage"] = eventMessage.text
        emptyState(events, eid)

        // A real production Task/sleep loop must catch up, cancel, and restart.
        let clocked = Model(), cid = clocked.begin()
        try clocked.append("最初正文", cid)
        clocked.suspend(cid, .drawer, true)
        try clocked.append(String(repeating: "🙂正文", count: 30), cid)
        clocked.suspend(cid, .drawer, false)
        clocked.suspend(cid, .drawer, true)
        let frozen = clocked.shown(cid), calls = clocked.filterCalls
        try await Task.sleep(for: .milliseconds(180))
        expect(clocked.shown(cid) == frozen && clocked.filterCalls == calls, "cancelled cadence published")
        clocked.suspend(cid, .drawer, false)
        for _ in 0..<50 {
            if clocked.streamDisplayTasksByMessageID[cid.1] == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(clocked.shown(cid) == clocked.rawStreamingTextByMessageID[cid.1], "real cadence failed to catch up")
        expect(clocked.streamDisplayTasksByMessageID.isEmpty, "caught-up task remained")
        behavior["real-cadence"] = clocked.finish(cid)!.text
        emptyState(clocked, cid)

        let output: [String: Any] = ["checks": checks, "behavior": behavior,
                                    "suspendedFilterCalls": suspendedCalls, "resumeFilterCalls": resumeCalls]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
