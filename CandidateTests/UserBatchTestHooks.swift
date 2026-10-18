// Appended only to the disposable test host; production timing is unchanged.
extension AppModel {
    func batchQAAcknowledgeSend() {
        if let request = pendingUserMessageSendPositionRequest { consumeUserMessageSendPositionRequest(request.id) }
    }
    func batchQAExpire(_ chat: UUID, token: UUID) {
        guard userBatchSendTokens[chat] == token else { return }
        userBatchSendTasks.removeValue(forKey: chat)?.cancel()
        submitUserBatch(for: chat, token: token)
    }
    func batchQAEndRun(_ chat: UUID, status: ChatMessage.Status = .complete) {
        if let id = activeStreamingMessageIDsByConversation[chat] {
            mutateMessage(id) { $0.status = status; $0.text = "Synthetic completed reply" }
        }
        _ = saveImmediately()
        activeStreamingMessageIDsByConversation[chat] = nil
        clearStreamingRun(for: chat, completedNormally: status == .complete)
    }
    func batchQACapture(_ messages: [ChatMessage], placeholder: ChatMessage?, chat: UUID,
                        provider: ProviderConfiguration, selection: ModelSelection, assistant: AssistantProfile) {
        batchQARequests.append(messages)
        guard let placeholder else { return }
        streamingConversationIDs.insert(chat)
        streamingRunIDsByConversation[chat] = UUID()
        activateAssistantStreamMessage(placeholder, conversationID: chat, provider: provider, selection: selection, assistant: assistant)
    }
    func batchQAContext(_ chat: UUID) -> [ChatMessage] { selectedContextMessages(for: chat) }
    func batchQAUserEvidence(_ chat: UUID) -> String {
        provisionalRecentMemoryUserEvidence(conversationID: chat, tokenLimit: 1000).summary
    }
    var batchQATaskCount: Int { userBatchSendTasks.count }
    func batchQABeginUnstagedRun(_ chat: UUID) { streamingConversationIDs.insert(chat) }
}
