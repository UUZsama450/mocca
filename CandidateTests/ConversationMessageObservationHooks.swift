// Appended only to a disposable simulator test host, never the product.
extension AppModel {
    func observationTestRollback() -> () -> Void { makeBackupRestoreModelRollback() }
    func observationTestProjection(_ id: UUID, raw: [ChatMessage]) -> [ChatMessage] {
        selectedMessageProjection(for:id,rawMessages:raw).map(\.message)
    }
    func observationTestStartStream(in id: UUID) -> UUID {
        let message=ChatMessage(conversationID:id,role:.assistant,text:"",status:.streaming)
        appendMessagePreservingLatestWindow(message,to:id)
        streamingConversationIDs.insert(id)
        activeStreamingMessageIDsByConversation[id]=message.id
        return message.id
    }
    func observationTestPublish(in id: UUID, message: UUID, text: String) {
        rawStreamingTextByMessageID[message]=text
        publishStreamingTextDisplay(conversationID:id,messageID:message,displayText:text,publishedAt:.now,codecDuration:0)
    }
    func observationTestAppend(_ event: ChatStreamEvent, in id: UUID, message: UUID) throws {
        try appendStreamingEvent(event,conversationID:id,messageID:message)
    }
    func observationTestFinish(in id: UUID, raw: String, cancelled: Bool) -> ChatMessage? {
        if let message=activeStreamingMessageIDsByConversation[id] { rawStreamingTextByMessageID[message]=raw }
        return finishStreaming(conversationID:id,removeIfEmpty:true,cancelled:cancelled,defersPersistence:true)
    }
}
