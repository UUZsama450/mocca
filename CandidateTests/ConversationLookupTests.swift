import XCTest
import Observation
@testable import Mocca

/// Runs the complete production AppModel in a disposable simulator test host.
/// All inputs are generated; no phone data or production test hooks are used.
@MainActor
final class ConversationLookupTests: XCTestCase {
    private func fixture(count: Int = 200) -> AppModel {
        let model = AppModel()
        model.conversations = (0..<count).map { Conversation(title: "Synthetic \($0)") }
        model.messagesByConversation = Dictionary(uniqueKeysWithValues: model.conversations.map { c in
            (c.id, [ChatMessage(conversationID: c.id, role: .assistant, text: c.title + " v1", versionGroupID: "reply", version: 1),
                    ChatMessage(conversationID: c.id, role: .assistant, text: c.title + " v2", versionGroupID: "reply", version: 2)])
        })
        model.selectedConversationID = model.conversations.last!.id
        _ = model.selectedConversation; _ = model.messages
        return model
    }

    private func assertSelected(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.selectedConversation, model.conversations.first { $0.id == model.selectedConversationID }, file: file, line: line)
        XCTAssertTrue(model.messages.allSatisfy { $0.conversationID == model.selectedConversationID }, file: file, line: line)
    }

    func testReorderingInsertionRemovalAndSameCountReplacement() {
        let m = fixture()
        let selected = m.selectedConversationID
        m.conversations.reverse(); assertSelected(m)
        m.conversations.insert(Conversation(title: "new first"), at: 0); assertSelected(m)
        m.conversations.removeFirst(); assertSelected(m)
        let index = m.conversations.firstIndex { $0.id == selected }!
        m.conversations[index] = Conversation(title: "replacement at old position")
        XCTAssertNil(m.selectedConversation)
        m.conversations.append(Conversation(id: selected, title: "returned"))
        XCTAssertEqual(m.selectedConversation?.title, "returned")
        assertSelected(m)
        m.conversations = []
        XCTAssertNil(m.selectedConversation)
    }

    func testCurrentTitleAndVersionSelectionAfterWarmReads() {
        let m = fixture()
        let id = m.selectedConversationID, index = m.conversations.count - 1
        XCTAssertEqual(m.messages.last?.version, 2)
        m.conversations[index].title = "renamed"
        m.conversations[index].versionSelections["reply"] = 1
        XCTAssertEqual(m.selectedConversation?.title, "renamed")
        XCTAssertEqual(m.messages.last?.version, 1)
        XCTAssertEqual(m.searchableMessages(for: id).last?.version, 1)
        m.messagesByConversation[id]![0].text = "streamed revision"
        XCTAssertEqual(m.messages.last?.text, "streamed revision")
    }

    func testCrossConversationSearchCannotChangeSelectedChatOrChosenVersions() {
        let m = fixture()
        let selected = m.selectedConversationID
        let expected = m.messages
        for index in m.conversations.indices {
            m.conversations[index].versionSelections["reply"] = index.isMultiple(of: 2) ? 1 : 2
        }
        for c in m.conversations.reversed() {
            let results = m.searchableMessages(for: c.id)
            XCTAssertEqual(results.count, 1)
            XCTAssertEqual(results.first?.conversationID, c.id)
            XCTAssertEqual(results.first?.version, c.versionSelections["reply"])
            XCTAssertEqual(m.selectedConversationID, selected)
            assertSelected(m)
        }
        XCTAssertEqual(m.messages, expected)
    }

    func testFavoriteAndSearchTargetNavigationAfterReorder() {
        let m = fixture()
        let originalIDs = m.conversations.map(\.id)
        for id in [originalIDs.last!, originalIDs[0], originalIDs[100], originalIDs.last!] {
            let target = m.messagesByConversation[id]![0]
            m.messagesByConversation[id]![0].reactions.bookmarkedAt = .now
            _ = m.searchableMessages(for: originalIDs[50])
            m.conversations.reverse()
            XCTAssertTrue(m.selectConversation(id, targeting: target.id, usesCoveredViewportTransition: true, closeDrawer: false))
            XCTAssertEqual(m.selectedConversationID, id)
            XCTAssertEqual(m.messages.first?.id, target.id)
            XCTAssertNotNil(m.messages.first?.reactions.bookmarkedAt)
            XCTAssertEqual(m.pendingMessageTargetNavigationRequest?.conversationID, id)
            XCTAssertEqual(m.pendingMessageTargetNavigationRequest?.messageID, target.id)
            assertSelected(m)
        }
        let id = originalIDs[0], target = m.messagesByConversation[id]![0].id
        m.conversations.removeAll { $0.id == id }
        XCTAssertFalse(m.selectConversation(id, targeting: target))
    }

    func testWarmObservationStillTracksCanonicalChanges() {
        let m = fixture()
        for mode in 0..<4 {
            _ = m.selectedConversation; _ = m.messages
            nonisolated(unsafe) var changed = false
            withObservationTracking {
                if mode == 0 { _ = m.selectedConversation } else { _ = m.messages }
            } onChange: { changed = true }
            switch mode {
            case 0: m.conversations[m.conversations.count - 1].title = "observed rename"
            case 1: m.conversations[m.conversations.count - 1].versionSelections["reply"] = 1
            case 2: m.messagesByConversation[m.selectedConversationID]![0].text = "observed stream"
            default: m.selectedConversationID = m.conversations[0].id
            }
            XCTAssertTrue(changed, "mode \(mode)")
        }
    }

    func testDuplicateIdentityStillUsesFirstCanonicalEntry() {
        let m = fixture(count: 3)
        let id = m.selectedConversationID
        m.conversations.insert(Conversation(id: id, title: "first duplicate", versionSelections: ["reply": 1]), at: 0)
        XCTAssertEqual(m.selectedConversation?.title, "first duplicate")
        XCTAssertEqual(m.messages.first?.version, 1)
    }
}
