import XCTest
@testable import Mocca

@MainActor final class UserBatchTests: XCTestCase {
    private func fixture() throws -> (AppModel, UUID) {
        precondition(Bundle.main.bundleIdentifier == "com.mocca.lab.replysegments")
        let model = AppModel()
        let chat = Conversation(assistantID: model.currentAssistantID.uuidString)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try model.reviewInstallStore(.init(conversations: [chat], messagesByConversation: [chat.id: []]), directory: directory)
        model.preferences.batchUserMessages = true
        model.preferences.chatSegmentedReply = true
        model.preferences.ttsAutoPlayAssistantReplies = false
        model.batchQACapturesRequests = true
        addTeardownBlock { @MainActor in
            model.pauseAllUserBatches()
            model.batchQAEndRun(chat.id)
            try? FileManager.default.removeItem(at: directory)
        }
        return (model, chat.id)
    }
    private func enqueue(_ text: String, _ model: AppModel, _ chat: UUID) {
        model.setComposerDraftText(text, for: chat)
        XCTAssertTrue(model.sendDraft(for: chat))
        model.batchQAAcknowledgeSend()
    }

    func testBatchDelayPreferencesMigrateClampAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.batchUserMessageDelaySeconds, 7)
        for (input, expected) in [(-100, 3), (3, 3), (7, 7), (15, 15), (100, 15)] {
            let preferences = UserPreferences(batchUserMessageDelaySeconds: input)
            XCTAssertEqual(preferences.batchUserMessageDelaySeconds, expected)
            let restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.batchUserMessageDelaySeconds, expected)
            let imported = try JSONDecoder().decode(UserPreferences.self,
                from: JSONSerialization.data(withJSONObject: ["batchUserMessageDelaySeconds": input]))
            XCTAssertEqual(imported.batchUserMessageDelaySeconds, expected)
        }
        let (model, _) = try fixture()
        model.updatePreferences { $0.batchUserMessageDelaySeconds = 15 }
        model.updatePreferences { $0.batchUserMessages = false }
        XCTAssertEqual(model.preferences.batchUserMessageDelaySeconds, 15)
    }

    func testThreeSecondDelayRestartsAfterLastSend() async throws {
        let (model, chat) = try fixture()
        model.preferences.batchUserMessageDelaySeconds = 3
        enqueue("first", model, chat)
        try await Task.sleep(for: .milliseconds(1800))
        enqueue("second", model, chat)
        let lastSend = ContinuousClock.now
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(model.batchQARequests.isEmpty, "The cancelled first deadline must not submit.")
        while model.batchQARequests.isEmpty && lastSend.duration(to: .now) < .seconds(8) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(lastSend.duration(to: .now), .seconds(3))
        XCTAssertEqual(model.batchQARequests.map { $0.map(\.text) }, [["first", "second"]])
    }

    func testFifteenSecondDelayIsCapturedPerSendAndPauseCancels() async throws {
        let (model, chat) = try fixture()
        model.preferences.batchUserMessageDelaySeconds = 15
        enqueue("long wait", model, chat)
        let sent = ContinuousClock.now
        model.updatePreferences { $0.batchUserMessageDelaySeconds = 3 }
        try await Task.sleep(for: .seconds(8))
        XCTAssertTrue(model.batchQARequests.isEmpty, "Neither the old fixed 7 seconds nor a later preference edit may submit early.")
        while model.batchQARequests.isEmpty && sent.duration(to: .now) < .seconds(22) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(sent.duration(to: .now), .seconds(15))
        XCTAssertEqual(model.batchQARequests.count, 1)
        model.batchQAEndRun(chat)
        enqueue("paused next batch", model, chat)
        model.pauseAllUserBatches()
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertEqual(model.batchQARequests.count, 1)
        XCTAssertEqual(model.pendingUserBatch(for: chat).map(\.text), ["paused next batch"])
        XCTAssertEqual(model.batchQATaskCount, 0)
    }

    func testResetDeadlineAndStaleWakeupCannotCommit() throws {
        let (model, chat) = try fixture()
        enqueue("first", model, chat)
        let old = try XCTUnwrap(model.userBatchSendTokens[chat])
        enqueue("second", model, chat)
        let current = try XCTUnwrap(model.userBatchSendTokens[chat])
        XCTAssertNotEqual(old, current)
        model.batchQAExpire(chat, token: old)
        XCTAssertTrue(model.batchQARequests.isEmpty)
        XCTAssertEqual(model.pendingUserBatch(for: chat).count, 2)
        XCTAssertTrue(model.batchQAContext(chat).isEmpty)
        XCTAssertTrue(model.batchQAUserEvidence(chat).isEmpty)
        XCTAssertEqual(try model.reviewReadStore().messagesByConversation[chat]?.count, 2)
        model.batchQAExpire(chat, token: current)
        XCTAssertEqual(model.batchQARequests.map { $0.map(\.text) }, [["first", "second"]])
        XCTAssertEqual(model.messagesByConversation[chat]?.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(model.pendingUserBatch(for: chat).isEmpty)
        model.batchQAExpire(chat, token: current)
        model.sendUserBatchNow(for: chat)
        XCTAssertEqual(model.batchQARequests.count, 1)
    }

    func testBoundarySendAfterCommitIsNextBatchAndCannotLeak() async throws {
        let (model, chat) = try fixture()
        enqueue("first request", model, chat)
        model.sendUserBatchNow(for: chat)
        enqueue("next request", model, chat)
        XCTAssertEqual(model.batchQARequests[0].map(\.text), ["first request"])
        XCTAssertEqual(model.batchQAContext(chat).filter { $0.role == .user }.map(\.text), ["first request"])
        let token = try XCTUnwrap(model.userBatchSendTokens[chat])
        model.batchQAExpire(chat, token: token)
        XCTAssertEqual(model.batchQARequests.count, 1)
        model.batchQAEndRun(chat)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.batchQARequests.count, 2)
        XCTAssertEqual(model.batchQARequests[1].filter { $0.role == .user }.map(\.text), ["first request", "next request"])
        XCTAssertTrue(model.pendingUserBatch(for: chat).isEmpty)
    }

    func testFailedQueueSaveKeepsDraftAndNoTimerOrRequest() throws {
        let (model, chat) = try fixture()
        model.reviewFailCommits(true)
        model.setComposerDraftText("keep draft", for: chat)
        XCTAssertFalse(model.sendDraft(for: chat))
        XCTAssertEqual(model.composerDraftText(for: chat), "keep draft")
        XCTAssertTrue(model.pendingUserBatch(for: chat).isEmpty)
        XCTAssertTrue(model.batchQARequests.isEmpty)
        XCTAssertNil(model.userBatchSendTokens[chat])
        model.reviewFailCommits(false)
    }

    func testUnstagedRegenerationKeepsDraftUntilPlaceholderExists() throws {
        let (model, chat) = try fixture()
        model.batchQABeginUnstagedRun(chat)
        model.setComposerDraftText("keep while preparing", for: chat)
        XCTAssertFalse(model.sendDraft(for: chat))
        XCTAssertEqual(model.composerDraftText(for: chat), "keep while preparing")
        XCTAssertTrue(model.pendingUserBatch(for: chat).isEmpty)
        XCTAssertTrue(model.batchQARequests.isEmpty)
    }

    func testFailedCommitRestoresQueueAndRetryDoesNotDuplicate() throws {
        let (model, chat) = try fixture()
        enqueue("durable", model, chat)
        let id = try XCTUnwrap(model.pendingUserBatch(for: chat).first?.id)
        model.reviewFailCommits(true)
        model.sendUserBatchNow(for: chat)
        XCTAssertTrue(model.batchQARequests.isEmpty)
        XCTAssertEqual(model.pendingUserBatch(for: chat).map(\.id), [id])
        XCTAssertEqual(model.messagesByConversation[chat]?.count, 1)
        model.reviewFailCommits(false)
        model.retryConversationStoreLoadIfNeeded()
        model.sendUserBatchNow(for: chat)
        XCTAssertEqual(model.batchQARequests.count, 1)
        XCTAssertEqual(model.batchQARequests.first?.map(\.id), [id])
    }

    func testPauseSwitchDisableAndFailureRetainPendingRows() async throws {
        let (model, chat) = try fixture()
        enqueue("paused", model, chat)
        let expired = try XCTUnwrap(model.userBatchSendTokens[chat])
        model.pauseAllUserBatches()
        model.batchQAExpire(chat, token: expired)
        XCTAssertEqual(model.pendingUserBatch(for: chat).count, 1)
        XCTAssertEqual(model.batchQATaskCount, 0)
        enqueue("second", model, chat)
        model.selectedConversationID = UUID()
        XCTAssertNil(model.userBatchSendTokens[chat])
        model.selectedConversationID = chat
        enqueue("third", model, chat)
        model.updatePreferences { $0.batchUserMessages = false }
        XCTAssertNil(model.userBatchSendTokens[chat])
        model.sendUserBatchNow(for: chat)
        model.preferences.batchUserMessages = true
        enqueue("after failure", model, chat)
        model.batchQAExpire(chat, token: try XCTUnwrap(model.userBatchSendTokens[chat]))
        model.batchQAEndRun(chat, status: .failed)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.batchQARequests.count, 1)
        XCTAssertNil(model.userBatchSendTokens[chat])
        XCTAssertEqual(model.pendingUserBatch(for: chat).map(\.text), ["after failure"])
    }

    func testReloadAndAvatarGroupingSurviveSettingsAndDeletion() throws {
        let (model, chat) = try fixture()
        enqueue("one", model, chat); enqueue("two", model, chat)
        let rows = model.pendingUserBatch(for: chat)
        XCTAssertFalse(rows[0].continuesUserBatch(after: nil))
        XCTAssertTrue(rows[1].continuesUserBatch(after: model.messagesByConversation[chat]?.first(where: { $0.id == rows[0].id })))
        let saved = try model.reviewReadStore()
        let reloaded = AppModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try reloaded.reviewInstallStore(saved, directory: dir)
        XCTAssertEqual(reloaded.pendingUserBatch(for: chat).map(\.id), rows.map(\.id))
        XCTAssertNil(reloaded.userBatchSendTokens[chat])
        XCTAssertTrue(rows[1].continuesUserBatch(after: reloaded.messagesByConversation[chat]?.first))
        model.deleteMessage(rows[0].id)
        XCTAssertFalse(rows[1].continuesUserBatch(after: model.messagesByConversation[chat]?.first(where: { $0.id == rows[0].id })))
        XCTAssertNil(model.userBatchSendTokens[chat])
        model.sendUserBatchNow(for: chat)
        XCTAssertEqual(model.batchQARequests.first?.map(\.text), ["two"])
    }

    func testLegacyPreferencesOffAndImmediateSendUnchanged() throws {
        let legacy = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.batchUserMessages)
        XCTAssertFalse(legacy.customChatBubbleSpacingEnabled)
        XCTAssertEqual(legacy.chatBubbleSpacing, 12)
        let (model, chat) = try fixture()
        model.preferences.batchUserMessages = false
        enqueue("immediate", model, chat)
        XCTAssertEqual(model.batchQARequests.count, 1)
        XCTAssertNil(model.batchQARequests[0][0].userSendBatchID)
        XCTAssertNil(model.userBatchSendTokens[chat])
        XCTAssertTrue(model.pendingUserBatch(for: chat).isEmpty)
    }

    func testCustomSpacingRequiresExplicitOptInAndPreservesValue() throws {
        // A saved value from 5223 must not silently opt a user into custom spacing.
        var preferences = try JSONDecoder().decode(UserPreferences.self, from: Data(
            #"{"chatBubbleSpacing":32,"singleChatSegmentedReply":true,"batchUserMessages":true}"#.utf8
        ))
        XCTAssertFalse(preferences.customChatBubbleSpacingEnabled)
        XCTAssertEqual(preferences.chatBubbleSpacing, 32)
        XCTAssertEqual(preferences.effectiveChatBubbleSpacing, 12)
        preferences.customChatBubbleSpacingEnabled = true
        var restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored.customChatBubbleSpacingEnabled)
        XCTAssertEqual(restored.effectiveChatBubbleSpacing, 32)
        restored.chatSegmentedReply = false
        restored.batchUserMessages = false
        XCTAssertEqual(restored.effectiveChatBubbleSpacing, 32)
        restored.customChatBubbleSpacingEnabled = false
        restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(restored.effectiveChatBubbleSpacing, 12)
        XCTAssertEqual(restored.chatBubbleSpacing, 32)
        restored.customChatBubbleSpacingEnabled = true
        XCTAssertEqual(restored.effectiveChatBubbleSpacing, 32)
    }

    func testSendingAfterDisablingImmediatelyIncludesExistingQueue() throws {
        let (model, chat) = try fixture()
        enqueue("queued", model, chat)
        model.updatePreferences { $0.batchUserMessages = false }
        enqueue("send now", model, chat)
        XCTAssertEqual(model.batchQARequests.first?.map(\.text), ["queued", "send now"])
        XCTAssertTrue(model.pendingUserBatch(for: chat).isEmpty)
        XCTAssertNil(model.userBatchSendTokens[chat])
    }

    func testClearingContextDoesNotOmitPendingBatchAndGroupStaysImmediate() throws {
        let (model, chat) = try fixture()
        enqueue("one", model, chat); enqueue("two", model, chat)
        model.conversations[0].truncateIndex = 2
        model.sendUserBatchNow(for: chat)
        XCTAssertEqual(model.batchQARequests.first?.map(\.text), ["one", "two"])
        model.batchQAEndRun(chat)
        model.conversations[0].groupAssistantIDs = [model.currentAssistantID.uuidString, UUID().uuidString]
        XCTAssertFalse(model.canQueueUserMessages(for: chat))
    }

    func testPendingRowsExcludedEvenFromDirectWirePreparation() async throws {
        let (model, chat) = try fixture()
        enqueue("not yet submitted", model, chat)
        let wire = try await ChatRequestPreparation.messages(from: model.messagesByConversation[chat]!, assistant: model.currentAssistant,
            provider: model.providers[0], preferences: model.preferences, conversation: model.conversations[0],
            assistants: model.assistants, ocrContext: nil, modelID: model.selectedModel?.modelID ?? "")
        XCTAssertTrue(wire.isEmpty)
    }

    func testEveryImageInNewestBatchIsTransmittedWithHistoryDisabled() async throws {
        let (model, chat) = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = MessageAttachment(kind: .image, localURL: url, mimeType: "image/png")
        let batch = UUID()
        let rows = [ChatMessage(conversationID: chat, role: .user, text: "old image", attachments: [image]),
                    ChatMessage(conversationID: chat, role: .assistant, text: "old reply"),
                    ChatMessage(conversationID: chat, role: .user, text: "new image", userSendBatchID: batch, attachments: [image]),
                    ChatMessage(conversationID: chat, role: .user, text: "caption", userSendBatchID: batch)]
        model.preferences.resendHistoricalImages = false
        for type: ProviderType in [.openAI, .claude, .google] {
            var provider = model.providers[0]; provider.type = type
            provider.models = [ModelConfiguration(id: "batch-vision", capabilityOverride: ModelCapabilities(input: [.text, .image]))]
            let wire = try await ChatRequestPreparation.messages(from: rows, assistant: model.currentAssistant,
                provider: provider, preferences: model.preferences, conversation: model.conversations[0],
                assistants: model.assistants, ocrContext: nil, modelID: "batch-vision")
            XCTAssertTrue(wire[0].images.isEmpty)
            XCTAssertEqual(wire[2].images.first?.base64Data, bytes.base64EncodedString())
            XCTAssertTrue(wire[3].images.isEmpty)
        }
    }

    func testNativeBackupRestoreAndBranchKeepPendingBatch() async throws {
        let (model, chat) = try fixture()
        enqueue("backup one", model, chat); enqueue("backup two", model, chat)
        model.pauseAllUserBatches()
        let original = model.pendingUserBatch(for: chat)
        model.preferences.customChatBubbleSpacingEnabled = true
        model.preferences.chatBubbleSpacing = 24
        let backup = try await BackupService.createBackup(options: BackupOptions(includeChats: true, includeFiles: false), model: model)
        defer { try? FileManager.default.removeItem(at: backup.url.deletingLastPathComponent()) }
        let (restored, _) = try fixture()
        _ = try await BackupService.restoreBackup(from: backup.url, mode: .overwrite, model: restored)
        XCTAssertEqual(restored.pendingUserBatch(for: chat).map(\.id), original.map(\.id))
        XCTAssertEqual(restored.pendingUserBatch(for: chat).map(\.userSendBatchID), original.map(\.userSendBatchID))
        XCTAssertTrue(restored.userBatchSendTokens.isEmpty)
        XCTAssertTrue(restored.preferences.batchUserMessages)
        XCTAssertTrue(restored.preferences.customChatBubbleSpacingEnabled)
        XCTAssertEqual(restored.preferences.chatBubbleSpacing, 24)
        XCTAssertEqual(restored.preferences.effectiveChatBubbleSpacing, 24)
        model.branchConversation(at: original[1].id)
        let branched = model.pendingUserBatch(for: model.selectedConversationID)
        XCTAssertEqual(branched.map(\.text), original.map(\.text))
        XCTAssertEqual(branched.map(\.userSendBatchID), original.map(\.userSendBatchID))
        XCTAssertTrue(branched[1].continuesUserBatch(after: branched[0]))
    }
}
