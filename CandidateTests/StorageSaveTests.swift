import XCTest
import CryptoKit
@testable import Mocca

final class StorageSaveTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture(conversations count: Int = 2, messagesPerConversation: Int = 3,
                         repeats: Int = 2) -> ConversationSnapshot {
        var conversations: [Conversation] = []
        var messages: [UUID: [ChatMessage]] = [:]
        let text = String(repeating: "synthetic chat body 1234567890 ", count: repeats)
        for index in 0..<count {
            let c = Conversation(title: "Fixture \(index)", createdAt: stamp, updatedAt: stamp)
            conversations.append(c)
            messages[c.id] = (0..<messagesPerConversation).map { n in
                ChatMessage(conversationID: c.id, role: n.isMultiple(of: 2) ? .user : .assistant,
                            text: "\(index)-\(n) \(text)", createdAt: stamp, updatedAt: stamp)
            }
        }
        return ConversationSnapshot(createdAt: stamp, updatedAt: stamp,
                                    conversations: conversations, messagesByConversation: messages)
    }

    private func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decode(_ data: Data) throws -> ConversationSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConversationSnapshot.self, from: data)
    }

    private func assertEquivalent(_ snapshot: ConversationSnapshot,
                                  encoder: ConversationSnapshotEncoder,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let baseline = try decode(jsonEncoder().encode(snapshot))
        XCTAssertEqual(try decode(encoder.encode(snapshot)), baseline, file: file, line: line)
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func loaded(_ result: ConversationStore.LoadResult) throws -> ConversationSnapshot {
        guard case .loaded(let snapshot) = result else { throw NSError(domain: "ExpectedLoaded", code: 1) }
        return snapshot
    }

    func testEveryMessageFieldInvalidatesWithoutChangingIdentity() throws {
        var snapshot = fixture()
        let id = snapshot.conversations[0].id
        let encoder = ConversationSnapshotEncoder()
        try assertEquivalent(snapshot, encoder: encoder)
        let edits: [(inout ChatMessage) -> Void] = [
            { $0.text = "quote \" slash \\ newline\n \u{0000} Chinese \u{4f60}\u{597d} emoji \u{1F431}" },
            { $0.updatedAt = self.stamp.addingTimeInterval(100) },
            { $0.status = .failed },
            { $0.parts = [MessagePart(kind: .reasoning, text: "changed", metadata: ["key": "value"])] },
            { $0.reasoningSegments = [ReasoningSegment(text: "reason", startedAt: self.stamp, expanded: true)] },
            { $0.attachments = [MessageAttachment(kind: .image, localURL: URL(fileURLWithPath: "/tmp/image.jpg"), fileName: "image.jpg", mimeType: "image/jpeg", byteCount: 42)] },
            { $0.historicalImagesCollapsed = true },
            { $0.toolEvents = [ToolEvent(name: "test", argumentsJSON: "{}", resultText: "result", createdAt: self.stamp, updatedAt: self.stamp)] },
            { $0.tokenUsage = TokenUsage(promptTokens: 1, completionTokens: 2, cachedTokens: 3, totalTokens: 6, durationMilliseconds: 7) },
            { $0.modelID = "new-model" }, { $0.providerID = "new-provider" },
            { $0.groupID = "new-author" }, { $0.versionGroupID = "new-group" },
            { $0.version = 17 }, { $0.translation = "translated" },
            { $0.reactions = MessageReactions(assistantReaction: "a", userReaction: "b", assistantReactionAuthorID: "c", bookmarkedAt: self.stamp) },
            { $0.migrationMetadata = MigrationMetadata(source: "fixture", notes: ["note": "retained"]) },
            { $0.schemaVersion = 2 },
            { $0.translation = nil; $0.attachments = []; $0.toolEvents = []; $0.tokenUsage = nil }
        ]
        for edit in edits {
            edit(&snapshot.messagesByConversation[id]![0])
            try assertEquivalent(snapshot, encoder: encoder)
        }
        // A value with the same ID but different immutable fields must also miss.
        let oldID = snapshot.messagesByConversation[id]![0].id
        snapshot.messagesByConversation[id]![0] = ChatMessage(id: oldID, conversationID: id,
            role: .system, text: "replacement", createdAt: stamp.addingTimeInterval(9), updatedAt: stamp)
        try assertEquivalent(snapshot, encoder: encoder)
    }

    func testHeaderEditsReorderingDeletionAndReaddition() throws {
        var snapshot = fixture()
        let original = snapshot
        let encoder = ConversationSnapshotEncoder()
        try assertEquivalent(snapshot, encoder: encoder)
        snapshot.schemaVersion = 7
        snapshot.createdAt = stamp.addingTimeInterval(1)
        snapshot.updatedAt = stamp.addingTimeInterval(2)
        snapshot.destructiveReductionAuthorized = true
        snapshot.conversations[0].title = "renamed"
        snapshot.conversations[0].versionSelections = ["v": 2]
        snapshot.conversations[0].summary = "summary"
        snapshot.conversations.reverse()
        for id in snapshot.messagesByConversation.keys { snapshot.messagesByConversation[id]!.reverse() }
        try assertEquivalent(snapshot, encoder: encoder)
        snapshot.conversations.removeAll()
        snapshot.messagesByConversation.removeAll()
        try assertEquivalent(snapshot, encoder: encoder)
        XCTAssertEqual(encoder.cachedByteCount, 0)
        XCTAssertEqual(encoder.cachedMessageCount, 0)
        snapshot = original
        snapshot.messagesByConversation[original.conversations[0].id]![0].text = "re-added changed"
        try assertEquivalent(snapshot, encoder: encoder)
    }

    func testCacheBudgetAndDisabledCachePreserveContent() throws {
        let encoders = [ConversationSnapshotEncoder(maximumCachedBytes: 0),
                        ConversationSnapshotEncoder(maximumCachedBytes: 1600, maximumCachedMessages: 2)]
        for encoder in encoders {
            var snapshot = fixture()
            for run in 0..<5 {
                snapshot.messagesByConversation[snapshot.conversations[0].id]![0].text = String(repeating: "x", count: run * 2000)
                try assertEquivalent(snapshot, encoder: encoder)
                XCTAssertLessThanOrEqual(encoder.cachedByteCount, 1600)
                XCTAssertLessThanOrEqual(encoder.cachedMessageCount, 2)
            }
        }
    }

    func testWriteFailurePreservesCommittedPrimaryAndRetryUsesNewContent() throws {
        let folder = try directory()
        let store = try ConversationStore(directoryURL: folder)
        var snapshot = fixture()
        try store.save(snapshot)
        let primary = folder.appendingPathComponent("conversations_v1.json")
        let receipt = folder.appendingPathComponent("conversations_v1.trusted-generation.json")
        let before = try Data(contentsOf: primary)
        let receiptBefore = try Data(contentsOf: receipt)
        let blocker = folder.appendingPathComponent("conversations_v1.next")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        snapshot.messagesByConversation[snapshot.conversations[0].id]![0].text = "must not appear before commit"
        XCTAssertThrowsError(try store.save(snapshot))
        XCTAssertEqual(try Data(contentsOf: primary), before)
        XCTAssertEqual(try Data(contentsOf: receipt), receiptBefore)
        try? FileManager.default.removeItem(at: blocker)
        snapshot.messagesByConversation[snapshot.conversations[0].id]![0].text = "successful retry"
        try store.save(snapshot)
        XCTAssertEqual(try loaded(store.load()).messagesByConversation, snapshot.messagesByConversation)
    }

    func testInvalidSnapshotNeverOverwritesOldGeneration() throws {
        let folder = try directory()
        let store = try ConversationStore(directoryURL: folder)
        var snapshot = fixture()
        try store.save(snapshot)
        let primary = folder.appendingPathComponent("conversations_v1.json")
        let before = try Data(contentsOf: primary)
        let id = snapshot.conversations[0].id
        snapshot.messagesByConversation[id]!.append(snapshot.messagesByConversation[id]![0])
        XCTAssertThrowsError(try store.save(snapshot))
        XCTAssertEqual(try Data(contentsOf: primary), before)
    }

    func testOldStoreReadsNewFilesAndAuthorizedDeletion() throws {
        let folder = try directory()
        let current = try ConversationStore(directoryURL: folder)
        let old = try BaselineConversationStore(directoryURL: folder)
        var snapshot = fixture()
        try old.save(snapshot)
        snapshot.messagesByConversation[snapshot.conversations[0].id]![0].translation = "new translation"
        try current.save(snapshot)
        guard case .loaded(let oldRead) = try old.load() else { return XCTFail("Old reader rejected new file") }
        XCTAssertEqual(oldRead.messagesByConversation, snapshot.messagesByConversation)
        let removed = snapshot.conversations.removeLast()
        snapshot.messagesByConversation.removeValue(forKey: removed.id)
        try current.save(snapshot, authorizedDestructiveReduction: true)
        guard case .loaded(let reduced) = try old.load() else { return XCTFail("Old reader rejected deletion receipt") }
        XCTAssertEqual(reduced.conversations, snapshot.conversations)
        XCTAssertEqual(reduced.messagesByConversation, snapshot.messagesByConversation)
        XCTAssertEqual(reduced.destructiveReductionAuthorized, true)
        // Returning to the historical writer must remain possible too.
        try old.save(reduced)
        XCTAssertEqual(try loaded(current.load()).messagesByConversation, snapshot.messagesByConversation)
    }

    func testCorruptPrimaryRecoversPreviousAndNewerSchemaFailsClosed() throws {
        let folder = try directory()
        let store = try ConversationStore(directoryURL: folder)
        let original = fixture()
        try store.save(original)
        var changed = original
        changed.conversations[0].title = "second"
        try store.save(changed)
        let primary = folder.appendingPathComponent("conversations_v1.json")
        try Data("corrupted".utf8).write(to: primary)
        guard case .recoveredFromBackup(let recovered, _) = try store.load() else { return XCTFail("No recovery") }
        XCTAssertEqual(recovered.conversations, original.conversations)
        changed.schemaVersion = 999
        try jsonEncoder().encode(changed).write(to: primary)
        XCTAssertThrowsError(try store.load())
    }

    func testColdStartKeepsUserAndMarksPartialResponseInterrupted() throws {
        let folder = try directory()
        var snapshot = fixture(conversations: 1, messagesPerConversation: 1)
        let id = snapshot.conversations[0].id
        snapshot.messagesByConversation[id]!.append(ChatMessage(conversationID: id, role: .assistant,
            text: "", createdAt: stamp, updatedAt: stamp, status: .streaming))
        snapshot.messagesByConversation[id]!.append(ChatMessage(conversationID: id, role: .assistant,
            text: "partial", createdAt: stamp, updatedAt: stamp, status: .streaming))
        try ConversationStore(directoryURL: folder).save(snapshot)
        let recovered = try loaded(ConversationStore(directoryURL: folder).load())
        XCTAssertEqual(recovered.messagesByConversation[id]?.map(\.text), [snapshot.messagesByConversation[id]![0].text, "partial"])
        XCTAssertEqual(recovered.messagesByConversation[id]?.last?.status, .interrupted)
    }

    func testPostCommitReceiptFailureKeepsSuccessAndOldReaderProof() throws {
        let folder = try directory()
        let store = try ConversationStore(directoryURL: folder)
        var snapshot = fixture()
        try store.save(snapshot)
        for name in ["conversations_v1.trusted-generation.json", "conversations_v1.trusted-generation.next.json"] {
            let path = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let removed = snapshot.conversations.removeLast()
        snapshot.messagesByConversation.removeValue(forKey: removed.id)
        XCTAssertNoThrow(try store.save(snapshot, authorizedDestructiveReduction: true))
        guard case .loaded(let recovered) = try BaselineConversationStore(directoryURL: folder).load() else {
            return XCTFail("Preparing receipt did not authorize committed deletion")
        }
        XCTAssertEqual(recovered.conversations, snapshot.conversations)
        // A second save must preserve the currently committed proof until commit.
        snapshot.conversations[0].title = "next generation"
        try store.save(snapshot)
        guard case .loaded(let second) = try BaselineConversationStore(directoryURL: folder).load() else {
            return XCTFail("Second receipt-slot generation was lost")
        }
        XCTAssertEqual(second.conversations, snapshot.conversations)
    }

    func testSeparateStoresDoNotReuseOtherDirectoriesContent() throws {
        let a = try ConversationStore(directoryURL: directory())
        let b = try ConversationStore(directoryURL: directory())
        let original = fixture()
        var changed = original
        changed.messagesByConversation[changed.conversations[0].id]![0].text = "other directory"
        try a.save(original)
        try b.save(changed)
        XCTAssertEqual(try loaded(a.load()).messagesByConversation, original.messagesByConversation)
        XCTAssertEqual(try loaded(b.load()).messagesByConversation, changed.messagesByConversation)
    }

    func testRepeatedColdSaveComparison() throws {
        var report: [String: Any] = [:]
        for (name, count, perConversation) in [("large_many", 120, 40), ("large_single", 1, 4800)] {
            let snapshot = fixture(conversations: count, messagesPerConversation: perConversation, repeats: 145)
            var oldMS: [Double] = []
            var newMS: [Double] = []
            for run in 0..<6 {
                try autoreleasepool {
                    let oldFolder = try directory()
                    let newFolder = try directory()
                    defer {
                        try? FileManager.default.removeItem(at: oldFolder)
                        try? FileManager.default.removeItem(at: newFolder)
                    }
                    let baseline = try BaselineConversationStore(directoryURL: oldFolder)
                    let current = try ConversationStore(directoryURL: newFolder)
                    func oldSave() throws { let start = Date(); try baseline.save(snapshot); oldMS.append(Date().timeIntervalSince(start) * 1000) }
                    func newSave() throws { let start = Date(); try current.save(snapshot); newMS.append(Date().timeIntervalSince(start) * 1000) }
                    if run.isMultiple(of: 2) { try oldSave(); try newSave() } else { try newSave(); try oldSave() }
                }
            }
            report[name] = ["baseline_cold_save_ms": oldMS, "candidate_cold_save_ms": newMS]
        }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("storage-cold-benchmark.json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output)
    }

    func testPairedChangedMessageBenchmarks() throws {
        var report: [String: Any] = [:]
        for (name, count, perConversation, repeats) in [("small", 1, 4, 2), ("large_many", 120, 40, 145), ("large_single", 1, 4800, 145)] {
            var snapshot = fixture(conversations: count, messagesPerConversation: perConversation, repeats: repeats)
            let oldFolder = try directory()
            let newFolder = try directory()
            let baseline = try BaselineConversationStore(directoryURL: oldFolder)
            let current = try ConversationStore(directoryURL: newFolder)
            var oldMS: [Double] = []
            var newMS: [Double] = []
            for run in 0..<5 {
                let id = snapshot.conversations[0].id
                snapshot.messagesByConversation[id]![0].text += " edit \(run)"
                func oldSave() throws { let start = Date(); try baseline.save(snapshot); oldMS.append(Date().timeIntervalSince(start) * 1000) }
                func newSave() throws { let start = Date(); try current.save(snapshot); newMS.append(Date().timeIntervalSince(start) * 1000) }
                if run.isMultiple(of: 2) { try oldSave(); try newSave() } else { try newSave(); try oldSave() }
            }
            guard case .loaded(let oldLoaded) = try baseline.load() else { return XCTFail("Missing baseline") }
            let newLoaded = try loaded(current.load())
            XCTAssertEqual(newLoaded.messagesByConversation, oldLoaded.messagesByConversation)
            XCTAssertEqual(newLoaded.conversations, oldLoaded.conversations)
            let bytes = try Data(contentsOf: newFolder.appendingPathComponent("conversations_v1.json")).count
            report[name] = ["bytes": bytes, "baseline_save_ms": oldMS, "candidate_save_ms": newMS]
        }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("storage-benchmark.json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output)
        print("STORAGE_BENCHMARK \(report)")
    }
}
