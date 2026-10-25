import XCTest
import SQLite3
import CryptoKit
@testable import Mocca

final class RecordStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(count: Int = 3, repeats: Int = 3) -> ConversationSnapshot {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let c = Conversation(title: "测试 \"汉字\" 🐈", createdAt: stamp, updatedAt: stamp)
        let messages = (0..<count).map { i in
            ChatMessage(conversationID: c.id, role: i.isMultiple(of: 2) ? .user : .assistant,
                        text: "\(i) " + String(repeating: "synthetic chat body 1234567890 ", count: repeats), createdAt: stamp, updatedAt: stamp)
        }
        return ConversationSnapshot(conversations: [c], messagesByConversation: [c.id: messages])
    }
    private func snapshot(_ result: ConversationStore.LoadResult) throws -> ConversationSnapshot {
        switch result {
        case .loaded(let value), .recoveredFromBackup(let value, _): return value
        case .missing: throw NSError(domain: "missing", code: 1)
        }
    }
    private func edit(_ source: ConversationSnapshot, text: String) -> ConversationSnapshot {
        var result = source
        result.messagesByConversation[result.conversations[0].id]![0].text = text
        return result
    }
    private func sql(_ directory: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("conversations_records.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(code, SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    func testLegacyMigrationAndOldReaderProtection() throws {
        let dir = try directory(), value = fixture()
        let legacy = try LegacyConversationStore(directoryURL: dir)
        try legacy.save(value)
        let store = try ConversationStore(directoryURL: dir)
        XCTAssertEqual(try snapshot(store.load()).messagesByConversation, value.messagesByConversation)
        let changed = edit(value, text: "new durable message")
        try store.save(changed)
        XCTAssertThrowsError(try legacy.load()) { error in
            guard case ConversationStoreError.unsupportedSchemaVersion(2) = error else {
                return XCTFail("Older reader must refuse, got \(error)")
            }
        }
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation,
                       changed.messagesByConversation)
    }
    func testFreshStoreFailedFirstMutationRetainsReadableSeed() throws {
        let dir = try directory(), value = fixture()
        let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
        _ = try db.load()
        db.failBeforeCommitForTesting = true
        XCTAssertThrowsError(try db.save(value, authorizedReduction: false))
        XCTAssertTrue(try snapshot(ConversationStore(directoryURL: dir).load()).conversations.isEmpty)
        db.failBeforeCommitForTesting = false
        try db.save(value, authorizedReduction: false)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, value.messagesByConversation)
    }
    func testChangedRecordsAndFailureRollback() throws {
        let dir = try directory(), initial = fixture()
        let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
        try db.save(initial, authorizedReduction: false)
        let changed = edit(initial, text: "changed without new ID or timestamp")
        db.failBeforeCommitForTesting = true
        XCTAssertThrowsError(try db.save(changed, authorizedReduction: false))
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, initial.messagesByConversation)
        db.failBeforeCommitForTesting = false
        try db.save(changed, authorizedReduction: false)
        XCTAssertEqual(db.lastChangedRecordCount, 1)
        XCTAssertLessThan(db.lastEncodedByteCount, 3000)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, changed.messagesByConversation)
    }
    func testDeletionReadditionReorderingAndMetadata() throws {
        let dir = try directory(), initial = fixture()
        let store = try ConversationStore(directoryURL: dir)
        try store.save(initial)
        var reduced = initial
        let id = initial.conversations[0].id
        let deleted = reduced.messagesByConversation[id]!.removeLast()
        XCTAssertThrowsError(try store.save(reduced))
        try store.save(reduced, authorizedDestructiveReduction: true)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, reduced.messagesByConversation)
        reduced.messagesByConversation[id]!.insert(deleted, at: 0)
        reduced.conversations[0].title = "renamed"
        try store.save(reduced)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).conversations, reduced.conversations)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, reduced.messagesByConversation)
        try sql(dir, "UPDATE generations SET payload=x'00'")
        let recovered = try snapshot(ConversationStore(directoryURL: dir).load())
        XCTAssertEqual(recovered.messagesByConversation[id]?.count, 2)
    }
    func testCoherentPriorRecoveryAndPromotion() throws {
        let dir = try directory(), first = fixture()
        let store = try ConversationStore(directoryURL: dir)
        try store.save(first)
        let second = edit(first, text: "second"), third = edit(first, text: "third")
        try store.save(second); try store.save(third)
        let messageID = first.messagesByConversation[first.conversations[0].id]![0].id
        try sql(dir, "UPDATE records SET value=x'00' WHERE key='m:\(messageID)'")
        let reopened = try ConversationStore(directoryURL: dir)
        guard case .recoveredFromBackup(let recovered, _) = try reopened.load() else {
            return XCTFail("Expected full previous generation")
        }
        XCTAssertEqual(recovered.messagesByConversation, second.messagesByConversation)
        try reopened.save(recovered, preserveExistingBackup: true)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, second.messagesByConversation)
    }
    func testMissingCurrentIndexAndDoubleCorruptionFailClosed() throws {
        let dir = try directory(), first = fixture()
        let store = try ConversationStore(directoryURL: dir)
        try store.save(first); try store.save(edit(first, text: "second"))
        try sql(dir, "UPDATE generations SET payload=x'00' WHERE slot=0")
        guard case .recoveredFromBackup = try ConversationStore(directoryURL: dir).load() else {
            return XCTFail("Expected prior generation")
        }
        try sql(dir, "UPDATE generations SET payload=x'00' WHERE slot=1")
        try Data("not sqlite".utf8).write(to: dir.appendingPathComponent("previous-records/conversations_records.sqlite"))
        XCTAssertThrowsError(try ConversationStore(directoryURL: dir).load())
    }
    func testColdStreamNormalizationCanCommitWithoutGeneralDeletionPermission() throws {
        let dir = try directory()
        var value = fixture()
        let id = value.conversations[0].id
        value.messagesByConversation[id]![0].status = .streaming
        value.messagesByConversation[id]![1].status = .streaming
        value.messagesByConversation[id]![1].text = ""
        try ConversationStore(directoryURL: dir).save(value)
        let store = try ConversationStore(directoryURL: dir)
        let normalized = try snapshot(store.load())
        // Shipping recovery preserves even empty replies as journal ownership anchors.
        XCTAssertEqual(normalized.messagesByConversation[id]!.map(\.id), value.messagesByConversation[id]!.map(\.id))
        XCTAssertEqual(normalized.messagesByConversation[id]![0].status, .interrupted)
        XCTAssertEqual(normalized.messagesByConversation[id]![1].status, .interrupted)
        XCTAssertEqual(normalized.messagesByConversation[id]![1].text, "")
        try store.save(normalized)
        let reloaded = try snapshot(ConversationStore(directoryURL: dir).load())
        XCTAssertEqual(reloaded.messagesByConversation[id]!.map(\.status), normalized.messagesByConversation[id]!.map(\.status))
        XCTAssertEqual(reloaded.messagesByConversation[id]!.map(\.text), normalized.messagesByConversation[id]!.map(\.text))
    }
    func testFutureSchemaAndInvalidOwnershipRefused() throws {
        let dir = try directory(), value = fixture()
        let store = try ConversationStore(directoryURL: dir)
        try store.save(value)
        var invalid = value
        invalid.schemaVersion = 999
        XCTAssertThrowsError(try store.save(invalid))
        invalid = value
        invalid.messagesByConversation[value.conversations[0].id]![0].schemaVersion = 2
        XCTAssertThrowsError(try store.save(invalid))
        invalid = value
        invalid.messagesByConversation[value.conversations[0].id]![0] = ChatMessage(conversationID: UUID(), role: .user, text: "wrong owner")
        XCTAssertThrowsError(try store.save(invalid))
        invalid = value
        let duplicate = invalid.messagesByConversation[value.conversations[0].id]![0]
        invalid.messagesByConversation[value.conversations[0].id]!.append(duplicate)
        XCTAssertThrowsError(try store.save(invalid))
        try sql(dir, "PRAGMA user_version=999")
        XCTAssertThrowsError(try ConversationStore(directoryURL: dir).load())
    }
    func testIndependentWriterCannotOverwriteNewerCommit() throws {
        let dir = try directory(), value = fixture()
        let first = try ConversationStore(directoryURL: dir)
        try first.save(value)
        let second = try ConversationStore(directoryURL: dir)
        _ = try second.load()
        let changed = edit(value, text: "newer")
        try first.save(changed)
        XCTAssertThrowsError(try second.save(value))
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, changed.messagesByConversation)
    }
    func testIndependentBackupRecoversUnchangedRecordAndBrokenDatabase() throws {
        for breakDatabase in [false, true] {
            let dir = try directory(), value = fixture()
            do {
                let store = try ConversationStore(directoryURL: dir)
                try store.save(value)
                try store.save(edit(value, text: "changed latest"))
            }
            if breakDatabase {
                try Data("not sqlite".utf8).write(to: dir.appendingPathComponent("conversations_records.sqlite"))
            } else {
                let unchangedID = value.messagesByConversation[value.conversations[0].id]![2].id
                try sql(dir, "UPDATE records SET value=x'00' WHERE key='m:\(unchangedID)'")
            }
            let recovered = try ConversationStore(directoryURL: dir)
            guard case .recoveredFromBackup(let prior, _) = try recovered.load() else {
                return XCTFail("Expected independent backup recovery")
            }
            XCTAssertEqual(prior.messagesByConversation, value.messagesByConversation)
            try recovered.save(prior, preserveExistingBackup: true)
            XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, value.messagesByConversation)
        }
    }
    func testBackupWriteFailureCannotAdvancePrimary() throws {
        let dir = try directory(), value = fixture()
        let store = try ConversationStore(directoryURL: dir)
        try store.save(value)
        // Force the replica connection to encounter an I/O error after reopen.
        try Data("not sqlite".utf8).write(to: dir.appendingPathComponent("previous-records/conversations_records.sqlite"))
        let reopened = try ConversationStore(directoryURL: dir)
        _ = try reopened.load()
        XCTAssertThrowsError(try reopened.save(edit(value, text: "must not commit")))
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, value.messagesByConversation)
    }

    func testNestedFieldsAndLegacyExportRoundTrip() throws {
        let dir = try directory(), stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var value = fixture()
        let id = value.conversations[0].id
        let store = try ConversationStore(directoryURL: dir)
        try store.save(value)
        let edits: [(inout ChatMessage) -> Void] = [
            { $0.parts = [MessagePart(kind: .reasoning, text: "changed", metadata: ["key": "value"])] },
            { $0.reasoningSegments = [ReasoningSegment(text: "reason", startedAt: stamp, expanded: true)] },
            { $0.attachments = [MessageAttachment(kind: .image, localURL: URL(fileURLWithPath: "/tmp/image.jpg"), fileName: "image.jpg", mimeType: "image/jpeg", byteCount: 42)] },
            { $0.toolEvents = [ToolEvent(name: "test", argumentsJSON: "{}", resultText: "result", createdAt: stamp, updatedAt: stamp)] },
            { $0.tokenUsage = TokenUsage(promptTokens: 1, completionTokens: 2, cachedTokens: 3, totalTokens: 6, durationMilliseconds: 7) },
            { $0.versionGroupID = "new-group"; $0.version = 17; $0.translation = "translated" },
            { $0.reactions = MessageReactions(assistantReaction: "a", userReaction: "b", assistantReactionAuthorID: "c", bookmarkedAt: stamp) },
            { $0.migrationMetadata = MigrationMetadata(source: "fixture", notes: ["note": "retained"]) },
            { $0.translation = nil; $0.attachments = []; $0.toolEvents = []; $0.tokenUsage = nil }
        ]
        for change in edits {
            change(&value.messagesByConversation[id]![0])
            try store.save(value)
            let canonicalEncoder = JSONEncoder(); canonicalEncoder.dateEncodingStrategy = .iso8601
            let canonical = try ConversationStore.decodeValidatedSnapshot(from: canonicalEncoder.encode(value))
            XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, canonical.messagesByConversation)
        }
        let current = try snapshot(ConversationStore(directoryURL: dir).load())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let exported = try ConversationStore.decodeValidatedSnapshot(from: encoder.encode(current))
        let legacy = try LegacyConversationStore(directoryURL: directory())
        try legacy.save(exported)
        XCTAssertEqual(try snapshot(legacy.load()).messagesByConversation, value.messagesByConversation)
    }
    func testBusyPrimaryDoesNotFallBackToOlderBackup() throws {
        let dir = try directory(), value = fixture()
        try ConversationStore(directoryURL: dir).save(value)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("conversations_records.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try ConversationStore(directoryURL: dir).load()) { error in
            XCTAssertEqual((error as NSError).domain, "Mocca.RecordSQLite")
            XCTAssertEqual((error as NSError).code & 0xff, Int(SQLITE_BUSY))
        }
    }

    func testColdReopenUpdatesBackupWithoutDecodingIt() throws {
        let dir = try directory(), initial = fixture(count: 400, repeats: 50)
        var expected = initial
        do {
            let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
            try db.save(initial, authorizedReduction: false)
            expected = edit(initial, text: "first durable edit")
            try db.save(expected, authorizedReduction: false)
        }
        for i in 0..<3 {
            let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
            let loaded = try snapshot(db.load())
            XCTAssertEqual(loaded.messagesByConversation, expected.messagesByConversation)
            expected = edit(loaded, text: "reopened edit \(i)")
            try db.save(expected, authorizedReduction: false)
            XCTAssertEqual(db.decodedSnapshotCount, 1)
            XCTAssertEqual(db.replicaDecodedSnapshotCount, 0)
            XCTAssertEqual(db.lastReplicaRecordCount, 1)
        }
        let backup = try ConversationRecordDatabase(directory: dir.appendingPathComponent("previous-records"), fileManager: .default, isReplica: true)
        let recovered = try snapshot(backup.load())
        XCTAssertEqual(recovered.messagesByConversation[initial.conversations[0].id]![0].text, "reopened edit 1")
    }

    func testColdReopenReplicatesDeletedAndReaddedRecords() throws {
        let dir = try directory(), original = fixture()
        let id = original.conversations[0].id
        var reduced = original
        let removed = reduced.messagesByConversation[id]!.removeLast()
        do {
            let db = try ConversationStore(directoryURL: dir)
            try db.save(original)
            try db.save(reduced, authorizedDestructiveReduction: true)
        }
        var restored = reduced
        restored.messagesByConversation[id]!.insert(removed, at: 0)
        do {
            let db = try ConversationStore(directoryURL: dir)
            _ = try db.load()
            try db.save(restored)
        }
        let backupDir = dir.appendingPathComponent("previous-records")
        XCTAssertEqual(try snapshot(ConversationRecordDatabase(directory: backupDir, fileManager: .default, isReplica: true).load()).messagesByConversation, reduced.messagesByConversation)
        do {
            let db = try ConversationStore(directoryURL: dir)
            _ = try db.load()
            try db.save(edit(restored, text: "next"))
        }
        XCTAssertEqual(try snapshot(ConversationRecordDatabase(directory: backupDir, fileManager: .default, isReplica: true).load()).messagesByConversation, restored.messagesByConversation)
    }

    func testStreamingCompletionThenNextSendPersistsOnlyChanges() throws {
        let dir = try directory()
        var value = fixture(count: 1000, repeats: 20)
        let id = value.conversations[0].id
        value.messagesByConversation[id]![0].status = .streaming
        let db = try ConversationRecordDatabase(directory: dir, fileManager: .default)
        try db.save(value, authorizedReduction: false)
        value.messagesByConversation[id]![0].text += " next stream chunk"
        try db.save(value, authorizedReduction: false)
        value.messagesByConversation[id]![0].status = .complete
        try db.save(value, authorizedReduction: false)
        XCTAssertEqual(db.lastChangedRecordCount, 1)
        XCTAssertEqual(db.lastReplicaRecordCount, 1)
        XCTAssertEqual(db.replicaDecodedSnapshotCount, 0)
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, value.messagesByConversation)
        value.messagesByConversation[id]!.append(ChatMessage(conversationID: id, role: .user, text: "next send"))
        try db.save(value, authorizedReduction: false)
        XCTAssertEqual(db.lastChangedRecordCount, 2) // New user message and ordering index.
        XCTAssertEqual(db.lastReplicaRecordCount, 1) // The preceding finalization.
    }

    func testNewerBackupCannotBeOverwrittenByOlderPrimary() throws {
        let dir = try directory(), value = fixture()
        do {
            let store = try ConversationStore(directoryURL: dir)
            try store.save(value)
            try store.save(edit(value, text: "second"))
        }
        let backupDir = dir.appendingPathComponent("previous-records")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(backupDir.appendingPathComponent("conversations_records.sqlite").path, &connection), SQLITE_OK)
        var query: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT payload FROM generations WHERE slot=0", -1, &query, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        let bytes = Data(bytes: sqlite3_column_blob(query, 0)!, count: Int(sqlite3_column_bytes(query, 0)))
        sqlite3_finalize(query); sqlite3_close(connection)
        var payload = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        payload["id"] = 999
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let hex = encoded.map { String(format: "%02x", $0) }.joined()
        let hash = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        try sql(backupDir, "UPDATE generations SET payload=x'\(hex)',hash=x'\(hash)' WHERE slot=0")
        let reopened = try ConversationStore(directoryURL: dir)
        let current = try snapshot(reopened.load())
        XCTAssertThrowsError(try reopened.save(edit(current, text: "must refuse")))
        XCTAssertEqual(try snapshot(ConversationStore(directoryURL: dir).load()).messagesByConversation, current.messagesByConversation)
    }

    func testRecordReuseBenchmark() throws {
        var metrics: [String: Any] = [:]
        for (label, count, repeats) in [("small", 4, 2), ("large", 4800, 145)] {
            let oldDir = try directory(), newDir = try directory()
            var value = fixture(count: count, repeats: repeats)
            let old = try LegacyConversationStore(directoryURL: oldDir)
            let new = try ConversationRecordDatabase(directory: newDir, fileManager: .default)
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for i in 0..<6 {
                value = edit(value, text: "\(i) " + String(repeating: "synthetic chat body 1234567890 ", count: repeats))
                let start = CFAbsoluteTimeGetCurrent()
                try old.save(value)
                oldTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let next = CFAbsoluteTimeGetCurrent()
                try new.save(value, authorizedReduction: false)
                newTimes.append((CFAbsoluteTimeGetCurrent() - next) * 1000)
                if i > 0 { XCTAssertEqual(new.lastChangedRecordCount, 1) }
            }
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            metrics[label] = ["baseline_ms": oldTimes, "records_ms": newTimes,
                              "snapshot_bytes": try e.encode(value).count,
                              "last_changed_records": new.lastChangedRecordCount,
                              "last_encoded_bytes": new.lastEncodedByteCount,
                              "stage_ms": new.lastStageTimings, "replica_stage_ms": new.lastReplicaStageTimings]
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("record-storage-benchmark.json")
        try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys, .prettyPrinted]).write(to: url)
        print("RECORD_STORAGE_BENCHMARK \(metrics)")
    }
}
