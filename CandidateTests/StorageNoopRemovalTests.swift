import XCTest
import SQLite3
@testable import Mocca

final class StorageNoopRemovalTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture() -> ConversationSnapshot {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = Conversation(title: "synthetic", createdAt: date, updatedAt: date)
        let message = ChatMessage(conversationID: chat.id, role: .user, text: "saved",
                                  createdAt: date, updatedAt: date)
        return ConversationSnapshot(conversations: [chat], messagesByConversation: [chat.id: [message]])
    }

    private func openObserver(_ dir: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open(dir.appendingPathComponent("conversations_records.sqlite").path, &db)
        guard result == SQLITE_OK, let db else { throw NSError(domain: "sqlite", code: Int(result)) }
        return db
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int32 {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite.prepare", code: 1)
        }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw NSError(domain: "sqlite.row", code: 1) }
        return sqlite3_column_int(query, 0)
    }

    func testReopeningPrimaryAndBackupDoesNotCommitIdenticalSchemaVersion() throws {
        let dir = try directory(), input = fixture()
        do {
            let store = try ConversationStore(directoryURL: dir)
            try store.save(input)
            try store.save(input)
        }
        for path in [dir, dir.appendingPathComponent("previous-records")] {
            let observer = try openObserver(path)
            defer { sqlite3_close(observer) }
            let version = try scalar(observer, "PRAGMA data_version")
            let before = try Data(contentsOf: path.appendingPathComponent("conversations_records.sqlite"))
            for _ in 0..<3 {
                let store = try ConversationRecordDatabase(directory: path, fileManager: .default)
                guard case .loaded(let loaded) = try store.load() else { return XCTFail("Expected valid store") }
                XCTAssertEqual(loaded.messagesByConversation, input.messagesByConversation)
            }
            XCTAssertEqual(try scalar(observer, "PRAGMA data_version"), version,
                           "Opening a valid v1 database must not create a write transaction")
            XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("conversations_records.sqlite")), before)
        }
    }

    func testUnversionedStoreStillInitializesAndMissingIndexStillRepairs() throws {
        let dir = try directory(), input = fixture()
        do { try ConversationStore(directoryURL: dir).save(input) }
        let observer = try openObserver(dir)
        defer { sqlite3_close(observer) }
        XCTAssertEqual(sqlite3_exec(observer, "PRAGMA user_version=0; DROP INDEX records_prior;", nil, nil, nil), SQLITE_OK)
        do { _ = try ConversationStore(directoryURL: dir).load() }
        XCTAssertEqual(try scalar(observer, "PRAGMA user_version"), 1)
        XCTAssertEqual(try scalar(observer, "SELECT count(*) FROM sqlite_master WHERE name='records_prior'"), 1)
        XCTAssertEqual(sqlite3_exec(observer, "DROP INDEX records_deleted;", nil, nil, nil), SQLITE_OK)
        do { _ = try ConversationStore(directoryURL: dir).load() }
        XCTAssertEqual(try scalar(observer, "SELECT count(*) FROM sqlite_master WHERE name='records_deleted'"), 1)
    }

    func testNewSeedAndShorterCompletionRemainExactlyReadableAndRecoverable() throws {
        let dir = try directory(), input = fixture(), chat = input.conversations[0]
        let run = UUID()
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: run, conversationID: chat.id, directoryURL: dir)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seed = try decoder.decode(PendingGenerationCompletionRecord.self, from: Data(contentsOf: writer.fileURL))
        XCTAssertEqual(seed.runID, run)
        XCTAssertEqual(seed.conversationID, chat.id)
        XCTAssertNil(seed.message)
        var recovering = input
        XCTAssertFalse(PendingGenerationCompletionJournal.mergeRecoverableCompletions(into: &recovering, directoryURL: dir).requiresConversationSave)
        var message = ChatMessage(id: run, conversationID: chat.id, role: .assistant,
                                  text: String(repeating: "long reply ", count: 2000),
                                  createdAt: chat.createdAt, updatedAt: chat.updatedAt)
        try writer.persistCompletedMessage(message)
        let longCount = try Data(contentsOf: writer.fileURL).count
        message.text = "short"
        try writer.persistCompletedMessage(message)
        let shortBytes = try Data(contentsOf: writer.fileURL)
        XCTAssertLessThan(shortBytes.count, longCount)
        XCTAssertEqual(try decoder.decode(PendingGenerationCompletionRecord.self, from: shortBytes).message, message)
        writer.closeKeepingFile()
        let report = PendingGenerationCompletionJournal.mergeRecoverableCompletions(into: &recovering, directoryURL: dir)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.recoveredMessageIDs, [run])
        XCTAssertEqual(recovering.messagesByConversation[chat.id]?.last, message)
    }

    func testRejectedCompletionAndClosedWriterDoNotChangeSeed() throws {
        let dir = try directory(), chat = fixture().conversations[0], run = UUID()
        let writer = try PendingGenerationCompletionJournal.makeWriter(runID: run, conversationID: chat.id, directoryURL: dir)
        let seed = try Data(contentsOf: writer.fileURL)
        let wrong = ChatMessage(conversationID: chat.id, role: .assistant, text: "wrong identity")
        XCTAssertThrowsError(try writer.persistCompletedMessage(wrong))
        XCTAssertEqual(try Data(contentsOf: writer.fileURL), seed)
        writer.closeKeepingFile()
        let valid = ChatMessage(id: run, conversationID: chat.id, role: .assistant, text: "closed writer")
        XCTAssertThrowsError(try writer.persistCompletedMessage(valid))
        XCTAssertEqual(try Data(contentsOf: writer.fileURL), seed)
    }
}
