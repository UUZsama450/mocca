import XCTest
@testable import Mocca

@MainActor final class FavoriteAssistantOwnershipTests: XCTestCase {
    private struct Fixture {
        let model: AppModel
        let a: AssistantProfile
        let b: AssistantProfile
        let chatA: Conversation
        let chatB: Conversation
        let bookmark: ChatMessage
    }

    private func fixture() throws -> Fixture {
        let m = AppModel()
        let a = AssistantProfile(name: "Synthetic A")
        let b = AssistantProfile(name: "Synthetic B")
        m.assistants = [a, b]
        m.currentAssistantID = a.id
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let chatA = Conversation(title: "A history", createdAt: date, updatedAt: date, assistantID: a.id.uuidString)
        let chatB = Conversation(title: "B history", createdAt: date, updatedAt: date, assistantID: b.id.uuidString)
        var bookmark = ChatMessage(conversationID: chatB.id, role: .assistant, text: "B bookmark", createdAt: date, updatedAt: date, groupID: b.id.uuidString)
        bookmark.reactions.bookmarkedAt = date
        let value = ConversationSnapshot(conversations: [chatA, chatB], messagesByConversation: [chatA.id: [], chatB.id: [bookmark]])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try m.reviewInstallStore(value, directory: dir)
        // Distinct model bindings make using the wrong assistant observable.
        m.providers[0].models.append(ModelConfiguration(id: "owner-b-model"))
        m.assistants[1].chatModel = ModelSelection(providerID: m.providers[0].id, modelID: "owner-b-model")
        m.selectConversation(chatA.id, closeDrawer: false)
        addTeardownBlock { @MainActor in
            m.firstSendCloseSyntheticStore()
            try? FileManager.default.removeItem(at: dir)
        }
        return Fixture(model: m, a: a, b: b, chatA: chatA, chatB: chatB, bookmark: bookmark)
    }

    func testCrossAssistantFavoriteKeepsExactDestinationAndOwnerAcrossTwoSends() throws {
        let f = try fixture(), m = f.model
        m.preferences.newChatOnAssistantSwitch = true
        m.setComposerDraftText("A unsent draft", for: f.chatA.id)
        let before = try m.reviewReadStore()
        XCTAssertTrue(m.selectConversation(f.chatB.id, targeting: f.bookmark.id, usesCoveredViewportTransition: true, closeDrawer: false))
        XCTAssertEqual(m.selectedConversationID, f.chatB.id)
        XCTAssertEqual(m.currentAssistantID, f.b.id)
        XCTAssertEqual(m.pendingMessageTargetNavigationRequest?.messageID, f.bookmark.id)
        XCTAssertEqual(m.conversations.count, 2)
        XCTAssertEqual(try m.reviewReadStore().conversations, before.conversations)
        XCTAssertEqual(m.visibleConversations.map(\.id), [f.chatB.id])
        for turn in 0..<2 {
            m.firstSendResetPresentation()
            m.setComposerDraftText("B follow-up \(turn)", for: f.chatB.id)
            XCTAssertTrue(m.sendDraft(for: f.chatB.id))
            XCTAssertEqual(m.conversationMessageStore[f.chatB.id]?.last?.groupID, f.b.id.uuidString)
            XCTAssertEqual(m.conversationMessageStore[f.chatB.id]?.last?.modelID, "owner-b-model")
            XCTAssertTrue(m.firstSendSaveStreaming(f.chatB.id, finish: true))
        }
        let disk = try m.reviewReadStore()
        XCTAssertEqual(disk.conversations.first { $0.id == f.chatB.id }?.assistantID, f.b.id.uuidString)
        XCTAssertEqual(disk.conversations.first { $0.id == f.chatB.id }?.title, f.chatB.title)
        XCTAssertEqual(disk.messagesByConversation[f.chatB.id]?.first, f.bookmark)
        XCTAssertEqual(disk.messagesByConversation[f.chatB.id]?.filter { $0.role == .user }.count, 2)
        XCTAssertEqual(disk.messagesByConversation[f.chatA.id], [])
        XCTAssertEqual(m.composerDraftText(for: f.chatA.id), "A unsent draft")
    }

    func testOldBookmarkedVersionStillBecomesConcreteTargetAcrossAssistants() throws {
        let f = try fixture(), m = f.model
        var old = f.bookmark
        old.versionGroupID = "favorite-versions"
        old.version = 0
        let newer = ChatMessage(conversationID: f.chatB.id, role: .assistant, text: "newer reply", createdAt: old.createdAt, groupID: f.b.id.uuidString, versionGroupID: "favorite-versions", version: 1)
        m.conversationMessageStore[f.chatB.id] = [old, newer]
        XCTAssertTrue(m.reviewSave())
        m.selectVersion(1, for: newer.id)
        XCTAssertEqual(m.searchableMessages(for: f.chatB.id).map(\.id), [newer.id])
        XCTAssertTrue(m.selectConversation(f.chatB.id, targeting: old.id, usesCoveredViewportTransition: true))
        XCTAssertEqual(m.currentAssistantID, f.b.id)
        XCTAssertEqual(m.pendingMessageTargetNavigationRequest?.messageID, old.id)
        XCTAssertEqual(m.searchableMessages(for: f.chatB.id).map(\.id), [old.id])
        XCTAssertEqual(m.conversationMessageStore[f.chatB.id]?.count, 2)
        XCTAssertEqual(m.conversationMessageStore[f.chatB.id]?.first?.reactions.bookmarkedAt, old.reactions.bookmarkedAt)
    }

    func testOrdinaryConversationEntrySynchronizesBothDirectionsWithoutNewChat() throws {
        let f = try fixture(), m = f.model
        m.preferences.newChatOnAssistantSwitch = true
        m.selectConversation(f.chatB.id)
        XCTAssertEqual(m.currentAssistantID, f.b.id)
        XCTAssertEqual(m.selectedConversationID, f.chatB.id)
        m.selectConversation(f.chatA.id)
        XCTAssertEqual(m.currentAssistantID, f.a.id)
        XCTAssertEqual(m.selectedConversationID, f.chatA.id)
        XCTAssertEqual(m.conversations.count, 2)
    }

    func testStaleUIAssistantCannotChooseReplyModelOrMoveOwnedChat() throws {
        let f = try fixture(), m = f.model
        // Simulate a legacy/direct selection path that did not synchronize UI.
        m.selectedConversationID = f.chatB.id
        XCTAssertEqual(m.currentAssistantID, f.a.id)
        m.setComposerDraftText("reply in B", for: f.chatB.id)
        XCTAssertTrue(m.sendDraft(for: f.chatB.id))
        XCTAssertEqual(m.conversationMessageStore[f.chatB.id]?.last?.groupID, f.b.id.uuidString)
        XCTAssertEqual(m.conversationMessageStore[f.chatB.id]?.last?.modelID, "owner-b-model")
        XCTAssertEqual(try m.reviewReadStore().conversations.first { $0.id == f.chatB.id }?.assistantID, f.b.id.uuidString)
    }

    func testFailedCrossAssistantSendPreservesDiskOwnershipBookmarkAndDraftForRetry() throws {
        let f = try fixture(), m = f.model
        XCTAssertTrue(m.selectConversation(f.chatB.id, targeting: f.bookmark.id))
        let before = try m.reviewReadStore()
        m.setComposerDraftText("  B retry draft  ", for: f.chatB.id)
        m.reviewFailCommits(true)
        XCTAssertFalse(m.sendDraft(for: f.chatB.id))
        XCTAssertEqual(m.composerDraftText(for: f.chatB.id), "  B retry draft  ")
        XCTAssertEqual(m.conversationMessageStore[f.chatB.id], before.messagesByConversation[f.chatB.id])
        let failed = try m.reviewReadStore()
        XCTAssertEqual(failed.conversations, before.conversations)
        XCTAssertEqual(failed.messagesByConversation, before.messagesByConversation)
        m.reviewFailCommits(false)
        m.retryConversationStoreLoadIfNeeded()
        XCTAssertEqual(m.selectedConversationID, f.chatB.id)
        XCTAssertTrue(m.sendDraft(for: f.chatB.id))
        XCTAssertEqual(try m.reviewReadStore().conversations.first { $0.id == f.chatB.id }?.assistantID, f.b.id.uuidString)
    }

    func testMissingFavoriteDestinationDoesNotSwitchAssistantOrSelection() throws {
        let f = try fixture(), m = f.model
        XCTAssertFalse(m.selectConversation(f.chatB.id, targeting: UUID()))
        XCTAssertFalse(m.selectConversation(UUID(), targeting: f.bookmark.id))
        m.selectConversation(UUID())
        XCTAssertEqual(m.currentAssistantID, f.a.id)
        XCTAssertEqual(m.selectedConversationID, f.chatA.id)
        XCTAssertNil(m.pendingMessageTargetNavigationRequest)
    }

    func testGroupFavoriteKeepsGroupRoutingAndOwner() throws {
        let f = try fixture(), m = f.model
        let group = Conversation(title: "Group", assistantID: f.b.id.uuidString, groupAssistantIDs: [f.a.id.uuidString, f.b.id.uuidString])
        let row = ChatMessage(conversationID: group.id, role: .assistant, text: "group bookmark", groupID: f.b.id.uuidString)
        m.conversations.append(group)
        m.conversationMessageStore[group.id] = [row]
        XCTAssertTrue(m.reviewSave())
        XCTAssertTrue(m.selectConversation(group.id, targeting: row.id))
        XCTAssertEqual(m.currentAssistantID, f.a.id)
        m.selectGroupReplyTarget(f.b.id.uuidString, conversationID: group.id)
        m.setComposerDraftText("B group reply", for: group.id)
        XCTAssertTrue(m.sendDraft(for: group.id))
        XCTAssertEqual(m.conversationMessageStore[group.id]?.last?.groupID, f.b.id.uuidString)
        let saved = try m.reviewReadStore().conversations.first { $0.id == group.id }
        XCTAssertEqual(saved?.groupAssistantIDs, group.groupAssistantIDs)
        XCTAssertEqual(saved?.assistantID, group.assistantID)
    }

    func testUnknownExplicitOwnerDoesNotFallBackToUnrelatedAssistant() throws {
        let f = try fixture(), m = f.model
        let index = try XCTUnwrap(m.conversations.firstIndex { $0.id == f.chatB.id })
        let missingOwner = UUID().uuidString
        m.conversations[index].assistantID = missingOwner
        m.selectedConversationID = f.chatB.id
        m.setComposerDraftText("keep unsent", for: f.chatB.id)
        XCTAssertFalse(m.sendDraft(for: f.chatB.id))
        XCTAssertEqual(m.composerDraftText(for: f.chatB.id), "keep unsent")
        XCTAssertEqual(m.conversations[index].assistantID, missingOwner)
        XCTAssertEqual(m.conversationMessageStore[f.chatB.id], [f.bookmark])
    }

    func testLegacyUnassignedConversationStillAcquiresCurrentAssistantOnSend() throws {
        let f = try fixture(), m = f.model
        let index = try XCTUnwrap(m.conversations.firstIndex { $0.id == f.chatA.id })
        m.conversations[index].assistantID = nil
        m.setComposerDraftText("legacy draft", for: f.chatA.id)
        XCTAssertTrue(m.sendDraft(for: f.chatA.id))
        XCTAssertEqual(try m.reviewReadStore().conversations.first { $0.id == f.chatA.id }?.assistantID, f.a.id.uuidString)
    }
}
