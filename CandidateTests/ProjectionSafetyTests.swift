import XCTest
@testable import Mocca

@MainActor
final class ProjectionSafetyTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture(count: Int = 8, chats: Int = 2) -> ConversationSnapshot {
        let cs = (0..<chats).map { Conversation(title: "Synthetic \($0)", createdAt: stamp, updatedAt: stamp) }
        let messages = Dictionary(uniqueKeysWithValues: cs.map { c in
            (c.id, (0..<count).map { ChatMessage(conversationID: c.id, role: $0.isMultiple(of: 2) ? .user : .assistant,
                text: "message \($0)", createdAt: stamp, updatedAt: stamp) })
        })
        return ConversationSnapshot(conversations: cs, messagesByConversation: messages)
    }
    private func pair(_ fixture: ConversationSnapshot, start: Int? = nil, count: Int? = nil) -> (AppModel, AppModel) {
        let baseline = AppModel(), candidate = AppModel()
        for model in [baseline, candidate] {
            model.projectionTestInstall(fixture, selected: fixture.conversations[0].id, start: start, count: count)
        }
        return (baseline, candidate)
    }
    private func assertEqual(_ a: AppModel, _ b: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.conversations, b.conversations, file: file, line: line)
        XCTAssertEqual(a.messagesByConversation, b.messagesByConversation, file: file, line: line)
        XCTAssertEqual(a.messages, b.messages, file: file, line: line)
        XCTAssertEqual(a.messageWindowStartIndex, b.messageWindowStartIndex, file: file, line: line)
        XCTAssertEqual(a.messageWindowEndIndex, b.messageWindowEndIndex, file: file, line: line)
        XCTAssertEqual(a.totalMessageCountForSelectedConversation, b.totalMessageCountForSelectedConversation, file: file, line: line)
        XCTAssertEqual(a.selectedLogicalTruncateIndex, b.selectedLogicalTruncateIndex, file: file, line: line)
        for c in a.conversations {
            XCTAssertEqual(a.projectionTestContext(c.id), b.projectionTestContext(c.id), file: file, line: line)
            XCTAssertEqual(a.searchableMessages(for: c.id), b.searchableMessages(for: c.id), file: file, line: line)
        }
    }
    private func append(_ message: ChatMessage, to pair: (AppModel, AppModel)) {
        pair.0.projectionTestAppend(message, baseline: true)
        pair.1.projectionTestAppend(message, baseline: false)
        assertEqual(pair.0, pair.1)
    }

    func testEmptyAndSmallConversationSendPairsMatchBaseline() {
        for count in [0, 4] {
            let f = fixture(count: count), id = f.conversations[0].id
            let models = pair(f)
            for i in 0..<5 {
                append(ChatMessage(conversationID: id, role: .user, text: "send \(i)", createdAt: stamp, updatedAt: stamp), to: models)
                append(ChatMessage(conversationID: id, role: .assistant, text: "", createdAt: stamp, updatedAt: stamp, status: .streaming), to: models)
            }
        }
    }

    func testLongLatestAndHistoricalWindowsMatchBaseline() {
        let f = fixture(count: 1200), id = f.conversations[0].id
        for window in [(0, 40), (1180, 20), (2000, 0)] {
            let models = pair(f, start: window.0, count: window.1)
            _ = models.0.messages; _ = models.1.messages
            append(ChatMessage(conversationID: id, role: .user, text: "new tail", createdAt: stamp, updatedAt: stamp), to: models)
            append(ChatMessage(conversationID: id, role: .assistant, text: "", createdAt: stamp, updatedAt: stamp, status: .streaming), to: models)
        }
    }

    func testRegeneratedVersionRetainsHistoricalWindowAndChosenVersion() {
        var f = fixture(count: 500)
        let id = f.conversations[0].id
        f.messagesByConversation[id]![450].versionGroupID = "reply"
        f.messagesByConversation[id]![450].version = 1
        f.conversations[0].versionSelections = ["reply": 1]
        let models = pair(f, start: 40, count: 20)
        append(ChatMessage(conversationID: id, role: .assistant, text: "new version", createdAt: stamp, updatedAt: stamp,
                           versionGroupID: "reply", version: 2), to: models)
        XCTAssertEqual(models.1.messageWindowStartIndex, 40)
        XCTAssertEqual(models.1.totalMessageCountForSelectedConversation, 500)
        for m in [models.0, models.1] { m.conversations[0].versionSelections["reply"] = 2 }
        assertEqual(models.0, models.1)
        XCTAssertEqual(models.1.projectionTestContext(id).first(where: { $0.versionGroupID == "reply" })?.text, "new version")
    }

    func testGroupAuthorsWithSameGroupIDRemainIndependent() {
        let f = fixture(), id = f.conversations[0].id, models = pair(f)
        append(ChatMessage(conversationID: id, role: .assistant, text: "author one", createdAt: stamp, updatedAt: stamp, groupID: "same-assistant"), to: models)
        append(ChatMessage(conversationID: id, role: .assistant, text: "author two", createdAt: stamp, updatedAt: stamp, groupID: "same-assistant"), to: models)
        XCTAssertEqual(models.1.totalMessageCountForSelectedConversation, 10)
    }

    func testRawSnapshotQueriesCannotPoisonCanonicalCache() {
        let f = fixture(), id = f.conversations[0].id, models = pair(f)
        _ = models.0.projectionTestContext(id); _ = models.1.projectionTestContext(id)
        // The baseline append itself uses explicit before/after raw snapshots.
        append(ChatMessage(conversationID: id, role: .user, text: "canonical next", createdAt: stamp, updatedAt: stamp), to: models)
        let changedParts = [MessagePart(kind: .reasoning, text: "new nested field")]
        for m in [models.0, models.1] {
            m.messagesByConversation[id]![0].text = "same identity changed"
            m.messagesByConversation[id]![0].parts = changedParts
        }
        append(ChatMessage(conversationID: id, role: .assistant, text: "next", createdAt: stamp, updatedAt: stamp), to: models)
        XCTAssertEqual(models.1.projectionTestContext(id)[0].text, "same identity changed")
    }

    func testAlternatingConversationsAndReplacementInvalidateCache() {
        let f = fixture(), models = pair(f)
        for step in 0..<24 {
            let id = f.conversations[step % 2].id
            for m in [models.0, models.1] {
                m.selectedConversationID = id
                _ = m.messages
                if step % 3 == 0 { m.messagesByConversation[id]!.reverse() }
                if step % 5 == 0 { m.messagesByConversation[id]!.removeLast() }
            }
            append(ChatMessage(conversationID: id, role: .user, text: "step \(step)", createdAt: stamp, updatedAt: stamp), to: models)
        }
    }

    func testTruncationAndTiedVersionsMatchBaseline() {
        var f = fixture(), id = f.conversations[0].id
        f.messagesByConversation[id]![2].versionGroupID = "tie"
        f.messagesByConversation[id]![3].versionGroupID = "tie"
        f.conversations[0].truncateIndex = 3
        f.conversations[0].versionSelections = ["tie": 99]
        let models = pair(f)
        append(ChatMessage(conversationID: id, role: .assistant, text: "tied third", createdAt: stamp, updatedAt: stamp,
                           versionGroupID: "tie", version: 0), to: models)
        XCTAssertFalse(models.1.projectionTestContext(id).contains(where: { $0.versionGroupID == "tie" }))
    }

    func testFailedSendRestorationDoesNotLeaveStagedRowsInCache() {
        let f = fixture(count: 500), id = f.conversations[0].id, models = pair(f, start: 20, count: 30)
        let user = ChatMessage(conversationID: id, role: .user, text: "failed user", createdAt: stamp, updatedAt: stamp)
        let assistant = ChatMessage(conversationID: id, role: .assistant, text: "", createdAt: stamp, updatedAt: stamp, status: .streaming)
        models.0.projectionTestRollbackPair(user: user, assistant: assistant, baseline: true)
        models.1.projectionTestRollbackPair(user: user, assistant: assistant, baseline: false)
        assertEqual(models.0, models.1)
        XCTAssertEqual(models.1.messagesByConversation, f.messagesByConversation)
        XCTAssertEqual(models.1.messageWindowStartIndex, 20)
        XCTAssertFalse(models.1.projectionTestContext(id).contains(where: { $0.id == user.id || $0.id == assistant.id }))
        append(user, to: models)
        append(assistant, to: models)
    }
}
