import XCTest
@testable import Mocca

/// Real production model in a disposable simulator, using generated data only.
@MainActor
final class InteractionPolishTests: XCTestCase {
    func testBranchesKeepVisibleRepliesAndReactionsWithoutDuplicatingBookmarks() {
        let model = AppModel()
        let source = Conversation(title: "Synthetic branch source", assistantID: model.currentAssistant.id.uuidString,
                                  versionSelections: ["reply": 1])
        let reactions = MessageReactions(assistantReaction: "❤️", userReaction: "👍",
                                        assistantReactionAuthorID: "synthetic-author", bookmarkedAt: Date(timeIntervalSince1970: 1234))
        let original = [
            ChatMessage(conversationID: source.id, role: .user, text: "question", reactions: reactions),
            ChatMessage(conversationID: source.id, role: .assistant, text: "selected answer", groupID: "synthetic-author",
                        versionGroupID: "reply", version: 1, translation: "translation", reactions: reactions),
            ChatMessage(conversationID: source.id, role: .assistant, text: "hidden answer", versionGroupID: "reply", version: 2),
            ChatMessage(conversationID: source.id, role: .user, text: "later question", reactions: reactions)
        ]
        model.conversations = [source]
        model.messagesByConversation = [source.id: original]
        model.selectedConversationID = source.id
        model.branchConversation(at: original[1].id)
        let branchID = model.selectedConversationID
        XCTAssertNotEqual(branchID, source.id)
        let copied = model.messagesByConversation[branchID] ?? []
        XCTAssertEqual(copied.map(\.text), ["question", "selected answer"])
        XCTAssertEqual(model.messagesByConversation[source.id], original)
        XCTAssertEqual(model.conversations.first { $0.id == source.id }, source)
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: original.map(\.id)))
        XCTAssertTrue(copied.allSatisfy { $0.reactions.bookmarkedAt == nil && $0.versionGroupID == nil && $0.version == 0 })
        for message in copied {
            XCTAssertEqual(message.reactions.assistantReaction, reactions.assistantReaction)
            XCTAssertEqual(message.reactions.userReaction, reactions.userReaction)
            XCTAssertEqual(message.reactions.assistantReactionAuthorID, reactions.assistantReactionAuthorID)
        }
        XCTAssertEqual(copied.last?.groupID, "synthetic-author")
        XCTAssertEqual(copied.last?.translation, "translation")
        guard let target = copied.last else { return XCTFail("Branch was not created") }
        model.branchConversation(at: target.id)
        XCTAssertNotEqual(model.selectedConversationID, branchID)
        XCTAssertTrue(model.messages.allSatisfy { $0.reactions.bookmarkedAt == nil })
        XCTAssertEqual(model.messagesByConversation[source.id], original)
        XCTAssertEqual(model.messagesByConversation[branchID], copied)
    }

    func testCreateConversationDistinguishesNoOpReuseAndNewDraft() {
        let model = AppModel()
        let source = Conversation(title: "existing", assistantID: model.currentAssistant.id.uuidString)
        model.conversations = [source]
        model.messagesByConversation = [source.id: [ChatMessage(conversationID: source.id, role: .user, text: "hello")]]
        model.selectedConversationID = source.id
        model.createConversation()
        let draft = model.selectedConversationID
        XCTAssertNotEqual(draft, source.id)
        XCTAssertEqual(model.conversations.count, 2)
        model.createConversation()
        XCTAssertEqual(model.selectedConversationID, draft)
        XCTAssertEqual(model.conversations.count, 2)
        model.selectedConversationID = source.id
        model.createConversation()
        XCTAssertEqual(model.selectedConversationID, draft)
        XCTAssertEqual(model.conversations.count, 2)
    }

    func testFreshDefaultsAndAllSavedHapticChoices() throws {
        let fresh = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UserPreferences())) as! [String: Any]
        let actualKeys = ["hapticsGlobalEnabled", "hapticsIosSwitch", "hapticsOnDrawer", "hapticsOnListItemTap", "hapticsOnCardTap", "hapticsOnGenerate"]
        XCTAssertEqual(actualKeys.compactMap { fresh[$0] as? Bool }, [true, true, true, false, true, true])
        for mask in 0..<64 {
            var saved = fresh
            for (index, key) in actualKeys.enumerated() { saved[key] = mask & (1 << index) != 0 }
            let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: saved))
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
            XCTAssertEqual(actualKeys.compactMap { encoded[$0] as? Bool }, actualKeys.compactMap { saved[$0] as? Bool }, "mask \(mask)")
        }
        var legacy = fresh
        legacy.removeValue(forKey: "hapticsOnListItemTap")
        legacy.removeValue(forKey: "hapticsOnGenerate")
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.hapticsOnListItemTap)
        XCTAssertFalse(decoded.hapticsOnGenerate)
    }
}
