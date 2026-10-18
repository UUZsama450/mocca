// Appended only to the isolated test host.
extension AppModel {
    func segmentQAStartMember(_ assistant: AssistantProfile, in conversationID: UUID) throws -> ChatMessage {
        try prepareAssistantStreamMessage(conversationID: conversationID, provider: providers[0],
            selection: selectedModel!, assistant: assistant)
    }
    func segmentQAPublish(_ text: String, for message: ChatMessage) {
        rawStreamingTextByMessageID[message.id] = text
        markStreamingProgressDirty(message.id)
        publishStreamingTextDisplay(conversationID: message.conversationID, messageID: message.id, displayText: text, publishedAt: .now)
    }
    func segmentQANewVersion(after message: ChatMessage) throws -> ChatMessage {
        try prepareAssistantStreamMessage(conversationID: message.conversationID,
            provider: providers[0], selection: selectedModel!, assistant: currentAssistant,
            versionGroupID: message.versionGroupKey, version: message.version + 1)
    }
    var segmentQACursorCount: Int { replyDisplayProgress.count + replyPersistenceProgress.count }
}
