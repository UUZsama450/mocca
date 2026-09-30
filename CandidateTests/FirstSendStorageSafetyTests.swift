import XCTest
@testable import Mocca

final class FirstSendStorageSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func snapshot(_ result: ConversationStore.LoadResult) throws -> ConversationSnapshot {
        switch result {
        case .loaded(let s), .recoveredFromBackup(let s, _): return s
        case .missing: throw NSError(domain: "missing synthetic store", code: 1)
        }
    }
    private func canonical(_ value: ConversationSnapshot) throws -> ConversationSnapshot {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ConversationSnapshot.self, from: e.encode(value))
    }
    func testColdNormalizationPreservesCompleteEmptyAndMissingWindows() throws {
        let dir = try directory()
        let complete = Conversation(title: "complete")
        let unfinished = Conversation(title: "unfinished")
        let missing = Conversation(title: "missing empty group")
        let completed = ChatMessage(conversationID: complete.id, role: .assistant, text: "saved history")
        let partial = ChatMessage(conversationID: unfinished.id, role: .assistant, text: "partial", status: .streaming)
        let empty = ChatMessage(conversationID: unfinished.id, role: .assistant, text: "", status: .streaming)
        let input = try canonical(ConversationSnapshot(conversations: [complete, unfinished, missing],
            messagesByConversation: [complete.id: [completed], unfinished.id: [partial, empty]]))
        try ConversationStore(directoryURL: dir).save(input)
        let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
        let loaded = try snapshot(db.load())
        XCTAssertEqual(loaded.messagesByConversation[complete.id], input.messagesByConversation[complete.id])
        XCTAssertEqual(loaded.messagesByConversation[unfinished.id]?.map(\.id), [partial.id])
        XCTAssertEqual(loaded.messagesByConversation[unfinished.id]?.first?.status, .interrupted)
        XCTAssertEqual(loaded.messagesByConversation[missing.id], [])
        try db.save(loaded, authorizedReduction: false)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, try canonical(loaded).messagesByConversation)
    }
    func testColdNormalizationRetainsEveryNonStreamingStateAndExistingEmptyGroup() throws {
        let dir = try directory()
        let chat = Conversation(title: "all stable states"), empty = Conversation(title: "empty")
        let states: [ChatMessage.Status] = [.complete, .cancelled, .interrupted, .failed]
        let rows = states.map { ChatMessage(conversationID: chat.id, role: .assistant, text: " \n", status: $0) }
        let original = try canonical(ConversationSnapshot(conversations: [chat, empty],
            messagesByConversation: [chat.id: rows, empty.id: []]))
        try ConversationStore(directoryURL: dir).save(original)
        let store = try ConversationStore(directoryURL: dir)
        let loaded = try snapshot(store.load())
        XCTAssertEqual(loaded.messagesByConversation, original.messagesByConversation)
        try store.save(loaded)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation,
                       original.messagesByConversation)
    }
    func testUnchangedMessageBuffersStillValidateTopologyAndSaveConversationMetadata() throws {
        let dir = try directory()
        let chat = Conversation(title: "original"), empty = Conversation(title: "empty")
        let original = try canonical(ConversationSnapshot(conversations: [chat, empty],
            messagesByConversation: [chat.id: [ChatMessage(conversationID: chat.id, role: .user, text: "retained")], empty.id: []]))
        try ConversationStore(directoryURL: dir).save(original)
        let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
        let loaded = try snapshot(db.load())
        // These malformed inputs preserve the existing message arrays. They
        // must fail even though row-content comparisons can take the fast path.
        let invalidEdits: [(inout ConversationSnapshot) -> Void] = [
            { $0.conversations.append(chat) },
            { $0.messagesByConversation[UUID()] = [] },
            { $0.schemaVersion = 999 },
            { $0.conversations[0].schemaVersion = 999 },
            { $0.conversations.removeLast(); $0.messagesByConversation.removeValue(forKey: empty.id) },
            { $0.messagesByConversation[empty.id] = $0.messagesByConversation[chat.id] }
        ]
        for edit in invalidEdits {
            var invalid = loaded
            edit(&invalid)
            XCTAssertThrowsError(try db.save(invalid, authorizedReduction: false))
            let disk = try snapshot(ConversationStore(directoryURL: dir).load())
            XCTAssertEqual(disk.conversations, original.conversations)
            XCTAssertEqual(disk.messagesByConversation, original.messagesByConversation)
        }
        var changed = loaded
        changed.conversations[0].title = "metadata changed without message edits"
        changed.conversations[0].isPinned = true
        try db.save(changed, authorizedReduction: false)
        XCTAssertEqual(db.lastChangedRecordCount, 1)
        let disk = try snapshot(ConversationStore(directoryURL: dir).load())
        XCTAssertEqual(disk.conversations, changed.conversations)
        XCTAssertEqual(disk.messagesByConversation, original.messagesByConversation)
    }
    func testSharedHistoryDoesNotHideOffscreenNestedEditsOrFailedSaveRetry() throws {
        let dir = try directory()
        let chats = (0..<24).map { Conversation(title: "window \($0)") }
        let messages = Dictionary(uniqueKeysWithValues: chats.map { c in
            (c.id, (0..<20).map { ChatMessage(conversationID: c.id, role: .assistant, text: "history \($0)") })
        })
        let initial = try canonical(ConversationSnapshot(conversations: chats, messagesByConversation: messages))
        try ConversationStore(directoryURL: dir).save(initial)
        let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
        var loaded = try snapshot(db.load())
        let active = chats[0].id, offscreen = chats[23].id
        loaded.messagesByConversation[active]!.append(ChatMessage(conversationID: active, role: .user, text: "new turn"))
        loaded.messagesByConversation[offscreen]![7].parts.append(MessagePart(kind: .reasoning, text: "changed nested value"))
        loaded.messagesByConversation[offscreen]![7].translation = "translation without changing ID or timestamp"
        db.failBeforeCommitForTesting = true
        XCTAssertThrowsError(try db.save(loaded, authorizedReduction: false))
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, initial.messagesByConversation)
        db.failBeforeCommitForTesting = false
        try db.save(loaded, authorizedReduction: false)
        XCTAssertEqual(db.lastChangedRecordCount, 3) // layout, new user, offscreen edit
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, try canonical(loaded).messagesByConversation)
        // A distinct but equal value array must remain a valid save input too.
        loaded.messagesByConversation[offscreen] = loaded.messagesByConversation[offscreen]!.map { $0 }
        try db.save(loaded, authorizedReduction: false)
        XCTAssertEqual(db.lastChangedRecordCount, 0)
        let kept = loaded.messagesByConversation[offscreen]!.removeLast()
        XCTAssertThrowsError(try db.save(loaded, authorizedReduction: false))
        loaded.messagesByConversation[offscreen]!.append(kept)
        loaded.messagesByConversation[active]![0].text = "later change survives retry"
        try db.save(loaded, authorizedReduction: false)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, try canonical(loaded).messagesByConversation)
    }
}
