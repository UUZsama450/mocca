import XCTest
@testable import Mocca

// The simulator omits NSFileProtectionKey. Inject only this attribute for
// branch tests; all contents, file types, timestamps and writes remain real.
private final class GuardAttributeFileManager: FileManager, @unchecked Sendable {
    var markerProtection: FileProtectionType? = .completeUnlessOpen
    var failMarkerAttributes = false
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        var result = try super.attributesOfItem(atPath: path)
        if URL(fileURLWithPath: path).lastPathComponent == "conversations_v1.json" {
            if failMarkerAttributes { throw NSError(domain: "synthetic attribute read failure", code: 1) }
            result[.protectionKey] = markerProtection
        }
        return result
    }
}

final class LegacyGuardReuseTests: XCTestCase {
    private let marker = Data("{\"schemaVersion\":2,\"storage\":\"conversations_records.sqlite\"}".utf8)
    private let fm = FileManager.default
    private let guardFM = GuardAttributeFileManager()
    private func directory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func snapshot(_ result: ConversationStore.LoadResult) throws -> ConversationSnapshot {
        switch result {
        case .loaded(let s), .recoveredFromBackup(let s, _): return s
        case .missing: throw NSError(domain: "missing synthetic store", code: 1)
        }
    }
    private func seed(_ dir: URL) throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let c = Conversation(title: "retained", createdAt: stamp, updatedAt: stamp)
        let s = ConversationSnapshot(conversations: [c], messagesByConversation: [c.id: [
            ChatMessage(conversationID: c.id, role: .user, text: "durable", createdAt: stamp, updatedAt: stamp)
        ]])
        let store = try ConversationStore(fileManager: guardFM, directoryURL: dir)
        try store.save(s)
        try store.save(s)
    }
    private func assertGuard(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = dir.appendingPathComponent("conversations_v1.json")
        XCTAssertEqual(try Data(contentsOf: url), marker, file: file, line: line)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular, file: file, line: line)
        if let protection = attrs[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen, file: file, line: line)
        }
        XCTAssertThrowsError(try LegacyConversationStore(directoryURL: dir).load(), file: file, line: line) { error in
            guard case ConversationStoreError.unsupportedSchemaVersion(2) = error else {
                return XCTFail("Old reader must refuse: \(error)", file: file, line: line)
            }
        }
    }
    func testExactProtectedMarkerSurvivesRepeatedColdSavesWithoutReplacement() throws {
        let dir = try directory(); try seed(dir)
        let url = dir.appendingPathComponent("conversations_v1.json")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let inode = try fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        for i in 0..<3 {
            let store = try ConversationStore(fileManager: guardFM, directoryURL: dir)
            var s = try snapshot(store.load()); s.conversations[0].title = "cold \(i)"
            try store.save(s)
            let attrs = try fm.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attrs[.modificationDate] as? Date, stamp)
            XCTAssertEqual(attrs[.systemFileNumber] as? NSNumber, inode)
            try assertGuard(dir)
            XCTAssertEqual(try snapshot(ConversationStore(fileManager: guardFM, directoryURL: dir).load()).conversations, s.conversations)
        }
    }
    func testMissingWrongTruncatedTrailingAndLargeMarkersAreRepaired() throws {
        let cases: [Data?] = [nil, Data(), Data(repeating: 120, count: marker.count),
                            Data(marker.dropLast()), marker + Data([32]), marker + Data(repeating: 32, count: 2_000_000)]
        for contents in cases {
            let dir = try directory(); try seed(dir)
            let store = try ConversationStore(fileManager: guardFM, directoryURL: dir)
            var s = try snapshot(store.load()); s.conversations[0].title = "repaired"
            let url = dir.appendingPathComponent("conversations_v1.json")
            try fm.removeItem(at: url)
            if let contents { try contents.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
            try store.save(s)
            try assertGuard(dir)
            XCTAssertEqual(try snapshot(ConversationStore(fileManager: guardFM, directoryURL: dir).load()).conversations, s.conversations)
        }
    }
    func testNonmatchingMissingOrUnreadableProtectionDoesNotReuseMarker() throws {
        let protections: [FileProtectionType?] = [FileProtectionType.none, .complete, .completeUntilFirstUserAuthentication, nil]
        for protection in protections {
            let dir = try directory(); try seed(dir)
            let store = try ConversationStore(fileManager: guardFM, directoryURL: dir)
            let s = try snapshot(store.load())
            let url = dir.appendingPathComponent("conversations_v1.json")
            let stamp = Date(timeIntervalSince1970: 1_600_000_000)
            try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
            guardFM.markerProtection = protection
            try store.save(s)
            XCTAssertNotEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, stamp)
            try assertGuard(dir)
        }
        let dir = try directory(); try seed(dir)
        let store = try ConversationStore(fileManager: guardFM, directoryURL: dir)
        let s = try snapshot(store.load())
        let url = dir.appendingPathComponent("conversations_v1.json")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        guardFM.failMarkerAttributes = true
        try store.save(s)
        XCTAssertNotEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, stamp)
        try assertGuard(dir)
    }
    func testNativeFileProtectionRepairWhenSupported() throws {
        let dir = try directory(); try seed(dir)
        let url = dir.appendingPathComponent("conversations_v1.json")
        guard let actual = try fm.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType else {
            throw XCTSkip("This filesystem does not expose iOS file protection; native device validation remains pending")
        }
        XCTAssertEqual(actual, .completeUnlessOpen)
        try fm.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
        let store = try ConversationStore(directoryURL: dir)
        try store.save(snapshot(store.load()))
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType, .completeUnlessOpen)
    }
    func testSymlinkIsReplacedWithoutChangingItsTarget() throws {
        let dir = try directory(); try seed(dir)
        let store = try ConversationStore(fileManager: guardFM, directoryURL: dir)
        let s = try snapshot(store.load())
        let url = dir.appendingPathComponent("conversations_v1.json"), target = dir.appendingPathComponent("synthetic-target")
        try marker.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: target.path)
        try fm.removeItem(at: url)
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
        try store.save(s)
        try assertGuard(dir)
        XCTAssertEqual(try Data(contentsOf: target), marker)
        XCTAssertEqual(try fm.attributesOfItem(atPath: target.path)[.modificationDate] as? Date, stamp)
    }
    func testGuardWriteFailurePreventsCommitAndCanRetry() throws {
        let dir = try directory(); try seed(dir)
        let db = try ConversationRecordDatabase(directory: dir, fileManager: guardFM)
        let original = try snapshot(db.load())
        var s = original; s.conversations[0].title = "only after repair"
        let url = dir.appendingPathComponent("conversations_v1.json")
        try fm.removeItem(at: url)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        try Data([1]).write(to: url.appendingPathComponent("block-replacement"))
        XCTAssertThrowsError(try db.save(s, authorizedReduction: false))
        XCTAssertEqual(try snapshot(ConversationStore(fileManager: guardFM, directoryURL: dir).load()).conversations, original.conversations)
        try fm.removeItem(at: url)
        try db.save(s, authorizedReduction: false)
        try assertGuard(dir)
        XCTAssertEqual(try snapshot(ConversationStore(fileManager: guardFM, directoryURL: dir).load()).conversations, s.conversations)
    }
    func testPrimaryFailureAfterReuseDoesNotAdvanceDataAndRetrySucceeds() throws {
        let dir = try directory(); try seed(dir)
        let db = try ConversationRecordDatabase(directory: dir, fileManager: guardFM)
        let original = try snapshot(db.load())
        var s = original; s.conversations[0].title = "retry"
        let url = dir.appendingPathComponent("conversations_v1.json")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        db.failBeforeCommitForTesting = true
        XCTAssertThrowsError(try db.save(s, authorizedReduction: false))
        XCTAssertEqual(try snapshot(ConversationStore(fileManager: guardFM, directoryURL: dir).load()).conversations, original.conversations)
        db.failBeforeCommitForTesting = false
        try db.save(s, authorizedReduction: false)
        XCTAssertEqual(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, stamp)
        try assertGuard(dir)
        XCTAssertEqual(try snapshot(ConversationStore(fileManager: guardFM, directoryURL: dir).load()).conversations, s.conversations)
    }
}
