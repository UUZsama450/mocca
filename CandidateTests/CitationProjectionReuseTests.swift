import XCTest
@testable import Mocca

@MainActor
final class CitationProjectionReuseTests: XCTestCase {
    private func tool(_ title: String = "source", url: String = "https://example.test/source") -> ToolEvent {
        let data = try! JSONSerialization.data(withJSONObject: ["items": [
            ["index": 1, "id": "search", "title": title, "url": url]
        ]], options: [.sortedKeys, .withoutEscapingSlashes])
        return ToolEvent(name: "web_search", resultText: String(data: data, encoding: .utf8), status: .complete)
    }

    func testCitationReuseWithActualStreamingMessagePayloads() {
        let id = UUID(), cache = MessageCitationPreparationCache()
        var messages = [ChatMessage(conversationID: id, role: .user, text: "question"),
                        ChatMessage(conversationID: id, role: .assistant, text: "answer", status: .streaming,
                                    toolEvents: [tool()])]
        let initial = cache.sourcesByMessageID(conversationID: id, from: messages, retentionTurns: 3)
        for i in 0..<120 {
            messages[1].text += "内容\(i)"
            messages[1].reasoningSegments = [ReasoningSegment(text: "思考\(i)", startedAt: .now)]
            messages[1].status = i == 119 ? .complete : .streaming
            messages[1].updatedAt = .now
            XCTAssertEqual(cache.sourcesByMessageID(conversationID: id, from: messages, retentionTurns: 3), initial)
        }
        messages[1].toolEvents = [tool("updated", url: "https://example.test/new")]
        let updated = cache.sourcesByMessageID(conversationID: id, from: messages, retentionTurns: 3)
        XCTAssertEqual(updated[messages[1].id]?.first?.title, "updated")
        XCTAssertEqual(updated[messages[1].id]?.first?.url.absoluteString, "https://example.test/new")
    }

    func testCitationWindowRetentionVersionAndConversationChanges() {
        let a = UUID(), b = UUID(), cache = MessageCitationPreparationCache()
        var messages = [ChatMessage(conversationID: a, role: .assistant, text: "source", toolEvents: [tool()]),
                        ChatMessage(conversationID: a, role: .user, text: "next"),
                        ChatMessage(conversationID: a, role: .assistant, text: "answer")]
        for retention in [-1, 0, 1, 3] {
            XCTAssertEqual(cache.sourcesByMessageID(conversationID: a, from: messages, retentionTurns: retention),
                           MessageCitationSource.sourcesByMessageID(from: messages, retentionTurns: retention))
        }
        messages[0] = ChatMessage(conversationID: a, role: .assistant, text: "different selected version")
        XCTAssertTrue(cache.sourcesByMessageID(conversationID: a, from: messages, retentionTurns: 3).isEmpty)
        messages[0].toolEvents = [tool()]
        XCTAssertFalse(cache.sourcesByMessageID(conversationID: a, from: messages, retentionTurns: 3).isEmpty)
        XCTAssertTrue(cache.sourcesByMessageID(conversationID: b, from: Array(messages.suffix(2)), retentionTurns: 3).isEmpty)
        XCTAssertFalse(cache.sourcesByMessageID(conversationID: a, from: messages, retentionTurns: 3).isEmpty)
        messages[0].toolEvents = [tool("caf\u{00e9}", url: "https://example.test/caf\u{00e9}")]
        _ = cache.sourcesByMessageID(conversationID: a, from: messages, retentionTurns: 3)
        messages[0].toolEvents = [tool("cafe\u{0301}", url: "https://example.test/cafe\u{0301}")]
        let result = cache.sourcesByMessageID(conversationID: a, from: messages, retentionTurns: 3)
        let expected = MessageCitationSource.sourcesByMessageID(from: messages, retentionTurns: 3)
        XCTAssertEqual(result, expected)
        XCTAssertEqual(Array(result[messages[0].id]![0].title.utf8), Array(expected[messages[0].id]![0].title.utf8))
    }

    func testProjectionPublishesEveryNestedPayloadWithoutRegrouping() {
        let model = AppModel(), conversation = Conversation(title: "Synthetic reuse test")
        let id = conversation.id
        model.conversations = [conversation]
        model.messagesByConversation = [id: [
            ChatMessage(conversationID: id, role: .user, text: "question"),
            ChatMessage(conversationID: id, role: .assistant, text: "v1", versionGroupID: "reply", version: 1),
            ChatMessage(conversationID: id, role: .assistant, text: "v2", versionGroupID: "reply", version: 2)
        ]]
        model.selectedConversationID = id
        _ = model.messages
        let grouped = model.observationTestProjectionBuilds
        for i in 0..<30 {
            var canonical = model.conversationMessageStore[id]!
            canonical[2].text = "answer\(i)"
            canonical[2].parts = [MessagePart(kind: .text, text: "answer\(i)")]
            canonical[2].translation = "translation\(i)"
            canonical[2].reasoningSegments = [ReasoningSegment(text: "reason\(i)", startedAt: .now)]
            canonical[2].toolEvents = [tool("result\(i)")]
            canonical[2].reactions.userReaction = "❤️"
            canonical[2].status = i == 29 ? .complete : .streaming
            model.conversationMessageStore[id] = canonical
            XCTAssertEqual(model.messages.last, canonical[2])
            XCTAssertEqual(model.searchableMessages(for: id).last, canonical[2])
        }
        XCTAssertEqual(model.observationTestProjectionBuilds, grouped)
        model.conversationMessageStore[id]![1].text = "edited hidden version"
        XCTAssertEqual(model.messages.last?.text, "answer29")
        model.conversations[0].versionSelections["reply"] = 1
        XCTAssertEqual(model.messages.last?.text, "edited hidden version")
        XCTAssertEqual(model.observationTestProjectionBuilds, grouped + 1)
        let snapshot = model.messagesByConversation
        model.conversationMessageStore[id] = nil
        XCTAssertTrue(model.messages.isEmpty)
        model.messagesByConversation = snapshot
        XCTAssertEqual(model.messages.last?.text, "edited hidden version")
    }
}
