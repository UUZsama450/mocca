// Appended only to GenerationFeatures.swift in the disposable XCTest host.
extension IOSBackgroundGenerationManager {
    static func completionTestManager() -> IOSBackgroundGenerationManager { IOSBackgroundGenerationManager() }
    func completionInstallRun(_ message: ChatMessage, writer: PendingGenerationCompletionJournal.Writer) {
        runs[message.id] = Run(assistantName: "Synthetic", conversationID: message.conversationID,
            detail: "Synthetic", activityID: nil, completionWriter: writer,
            journaledMessage: nil, committedMessage: nil, continuedProcessingIdentifier: nil,
            continuedGenerationLease: nil)
    }
    func completionJournaled(_ id: UUID) -> ChatMessage? { runs[id]?.journaledMessage }
    func completionCommitted(_ id: UUID) -> ChatMessage? { runs[id]?.committedMessage }
}
