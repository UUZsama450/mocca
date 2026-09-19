// Appended only to the disposable QA host; never in the shipping target.
extension ConversationStoreSaveExecutor {
    func reviewFailCommits(_ enabled: Bool) {
        queue.sync { store.reviewFailCommits(enabled) }
    }
}
extension AppModel {
    var reviewReady: Bool { conversationPersistenceIsReady }
    func reviewInstallStore(_ snapshot: ConversationSnapshot, directory: URL) throws {
        let store = try ConversationStore(directoryURL: directory)
        try store.save(snapshot)
        conversationStore = store
        conversationStoreSaveExecutor = ConversationStoreSaveExecutor(store: store)
        conversations = snapshot.conversations
        messagesByConversation = snapshot.messagesByConversation
        selectedConversationID = snapshot.conversations[0].id
        blockConversationPersistence("synthetic initialization")
        retryConversationStoreLoadIfNeeded()
        preferences.autoGenerateTitle = false
        preferences.userBubbleSendAnimationEnabled = false
        let provider = ProviderConfiguration(id: UUID(), enabled: true, name: "Synthetic", type: .openAI,
            apiKey: "synthetic", baseURL: "http://127.0.0.1:1", chatPath: "/chat/completions",
            models: [ModelConfiguration(id: "gpt-4o")])
        providers = [provider]
        selectedModel = ModelSelection(providerID: provider.id, modelID: "gpt-4o")
    }
    func reviewFailCommits(_ enabled: Bool) { conversationStoreSaveExecutor!.reviewFailCommits(enabled) }
    func reviewSave() -> Bool { saveImmediately() }
    func reviewMarkUnsaved(_ id: UUID) { unsavedDraftConversationIDs.insert(id) }
    func reviewReadStore() throws -> ConversationSnapshot {
        switch try conversationStoreSaveExecutor!.loadSynchronously() {
        case .loaded(let value), .recoveredFromBackup(let value, _): return value
        case .missing: throw NSError(domain: "Missing test store", code: 1)
        }
    }
    func reviewContext(_ id: UUID) -> ToolInvocationContext {
        let message = ChatMessage(conversationID: id, role: .assistant, text: "", status: .streaming)
        messagesByConversation[id, default: []].append(message)
        let run = UUID()
        streamingConversationIDs.insert(id)
        streamingRunIDsByConversation[id] = run
        activeStreamingMessageIDsByConversation[id] = message.id
        return ToolInvocationContext(conversationID: id, runID: run, messageID: message.id, persistenceEpoch: conversationPersistenceEpoch)
    }
    func reviewStop(_ id: UUID) { stopStreaming(ifConversationID: id) }
}
