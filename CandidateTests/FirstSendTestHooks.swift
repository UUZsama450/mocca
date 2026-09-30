// Only appended to a disposable simulator test host, never the product.
extension AppModel {
    func firstSendCloseSyntheticStore() {
        blockConversationPersistence("synthetic teardown")
        conversationStoreSaveExecutor = nil
        conversationStore = nil
    }
    func firstSendResetPresentation() {
        pendingUserMessageSendPositionRequest = nil
        pendingUserBubbleSendAnimation = nil
        sendPresentationGate = nil
    }
    func firstSendSaveStreaming(_ id: UUID, finish: Bool) -> Bool {
        guard var rows = conversationMessageStore[id], let index = rows.indices.last else { return false }
        rows[index].text += " synthetic chunk"
        rows[index].status = finish ? .complete : .streaming
        conversationMessageStore[id] = rows
        return saveImmediately()
    }
}
