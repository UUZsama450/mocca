// Appended only to the disposable test host's AppModel.swift.
extension AppModel {
    func projectionTestInstall(_ value: ConversationSnapshot, selected: UUID, start: Int? = nil, count: Int? = nil) {
        conversations = value.conversations
        messagesByConversation = value.messagesByConversation
        selectedConversationID = selected
        messageWindowsByConversation = [:]
        if let start, let count {
            messageWindowsByConversation[selected] = MessageWindowState(startIndex: start, count: count)
        }
        pendingUserMessageSendPositionRequest = nil
        pendingUserBubbleSendAnimation = nil
        sendPresentationGate = nil
    }

    func projectionTestAppend(_ message: ChatMessage, baseline: Bool) {
        if baseline { _ = baselineAppendMessagePreservingLatestWindow(message, to: message.conversationID) }
        else { appendMessagePreservingLatestWindow(message, to: message.conversationID) }
    }

    func projectionTestContext(_ id: UUID) -> [ChatMessage] { selectedContextMessages(for: id) }

    func projectionTestRollbackPair(user: ChatMessage, assistant: ChatMessage, baseline: Bool) {
        let id = user.conversationID
        let priorConversations = conversations
        let priorMessages = messagesByConversation[id]
        let priorWindow = messageWindowsByConversation[id]
        projectionTestAppend(user, baseline: baseline)
        _ = selectedContextMessages(for: id)
        projectionTestAppend(assistant, baseline: baseline)
        // The same restoration statements as sendDraft's failed-save branch.
        conversations = priorConversations
        messagesByConversation[id] = priorMessages
        messageWindowsByConversation[id] = priorWindow
    }
}
