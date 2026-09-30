// Appended only to a disposable full-product XCTest host.
final class CompletionWorkProbe: @unchecked Sendable {
    static let shared = CompletionWorkProbe()
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func reset() { lock.withLock { values = [:] } }
    func record(_ key: String, _ amount: Double = 1) {
        lock.withLock { values[key, default: 0] += amount }
    }
    func sample() -> [String: Double] { lock.withLock { values } }
}

final class CompletionWorkGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func consumeEntry() -> Bool { entered.wait(timeout: .now()) == .success }
}

extension ConversationStoreSaveExecutor {
    func completionHoldQueue(_ gate: CompletionWorkGate) {
        queue.async { gate.entered.signal(); gate.release.wait() }
    }
    func completionFailCommits(_ value: Bool) {
        queue.sync { store.completionFailCommits(value) }
    }
}

extension AppModel {
    func completionInstall(_ snapshot: ConversationSnapshot, directory: URL) throws {
        let store = try ConversationStore(directoryURL: directory)
        try store.save(snapshot)
        conversationStore = store
        conversationStoreSaveExecutor = ConversationStoreSaveExecutor(store: store)
        conversations = snapshot.conversations
        messagesByConversation = snapshot.messagesByConversation
        selectedConversationID = snapshot.conversations[0].id
        unsavedDraftConversationIDs = []
        conversationPersistenceState = .ready
        conversationPersistenceEpoch &+= 1
        conversationSaveSequence = 0
        lastAppliedConversationSaveSequence = 0
        lastPersistedConversationCount = snapshot.conversations.count
        lastPersistedMessageCount = snapshot.messagesByConversation.values.reduce(0) { $0 + $1.count }
        lastPersistedConversationIDs = Set(snapshot.conversations.map(\.id))
        lastPersistedMessageIDs = Set(snapshot.messagesByConversation.values.joined().map(\.id))
        preferences.autoGenerateTitle = false
        preferences.ttsAutoPlayAssistantReplies = false
    }
    func completionReplace(_ snapshot: ConversationSnapshot) {
        conversations = snapshot.conversations
        messagesByConversation = snapshot.messagesByConversation
    }
    func completionSave(conversations: Bool = false, messages: Bool = false) async -> String {
        String(describing: await saveWithoutBlockingMain(
            allowDestructiveConversationReduction: conversations,
            allowDestructiveMessageReduction: messages))
    }
    func completionSaveSynchronously(conversations: Bool = false, messages: Bool = false) -> Bool {
        saveImmediately(allowDestructiveConversationReduction: conversations,
                        allowDestructiveMessageReduction: messages)
    }
    var completionPersistedIDs: Set<UUID> { lastPersistedMessageIDs }
    var completionReady: Bool { conversationPersistenceIsReady }
    func completionAdvanceEpoch() { conversationPersistenceEpoch &+= 1 }
    func completionHoldQueue(_ gate: CompletionWorkGate) { conversationStoreSaveExecutor!.completionHoldQueue(gate) }
    func completionFailCommits(_ value: Bool) { conversationStoreSaveExecutor!.completionFailCommits(value) }
    func completionMarkDraft(_ id: UUID) { unsavedDraftConversationIDs.insert(id) }
    func completionBegin(_ message: ChatMessage, raw: String) {
        conversationMessageStore[message.conversationID, default: []].append(message)
        streamingConversationIDs.insert(message.conversationID)
        activeStreamingMessageIDsByConversation[message.conversationID] = message.id
        rawStreamingTextByMessageID[message.id] = raw
    }
    func completionForcedStop(_ id: UUID) { stopStreaming(ifConversationID: id) }
    func completionFinish(_ id: UUID, messageID: UUID) async throws -> ChatMessage? {
        try await finishSuccessfulStreaming(conversationID: id, messageID: messageID, reactionContext: nil)
    }
}
