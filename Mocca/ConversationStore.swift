import CryptoKit
import Foundation
import SQLite3

struct Conversation: Codable, Identifiable, Hashable {
    static let defaultTitle = "新聊天"
    static let currentSummaryCursorDomainVersion = 1

    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var assistantID: String?
    var groupAssistantIDs: [String]
    var truncateIndex: Int
    var versionSelections: [String: Int]
    var summary: String?
    var lastSummarizedMessageCount: Int
    var summaryCursorDomainVersion: Int?
    var chatSuggestions: [String]
    var providerID: String?
    var modelID: String?
    var schemaVersion: Int
    var migrationMetadata: MigrationMetadata?

    /// Missing ownership is not shared ownership. Legacy orphan chats stay
    /// stored, but must not follow the currently selected assistant.
    func belongsToSingleChatAssistant(_ id: String) -> Bool {
        groupAssistantIDs.count < 2 && assistantID == id
    }

    init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isPinned: Bool = false,
        assistantID: String? = nil,
        groupAssistantIDs: [String] = [],
        truncateIndex: Int = -1,
        versionSelections: [String: Int] = [:],
        summary: String? = nil,
        lastSummarizedMessageCount: Int = 0,
        summaryCursorDomainVersion: Int? =
            Conversation.currentSummaryCursorDomainVersion,
        chatSuggestions: [String] = [],
        providerID: String? = nil,
        modelID: String? = nil,
        schemaVersion: Int = ConversationStore.currentSchemaVersion,
        migrationMetadata: MigrationMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.assistantID = assistantID
        self.groupAssistantIDs = groupAssistantIDs
        self.truncateIndex = truncateIndex
        self.versionSelections = versionSelections
        self.summary = summary
        self.lastSummarizedMessageCount = lastSummarizedMessageCount
        self.summaryCursorDomainVersion = summaryCursorDomainVersion
        self.chatSuggestions = chatSuggestions
        self.providerID = providerID
        self.modelID = modelID
        self.schemaVersion = schemaVersion
        self.migrationMetadata = migrationMetadata
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable, Hashable {
        case user
        case assistant
        case system
        case tool
    }

    enum Status: String, Codable, Hashable {
        case complete
        case streaming
        case cancelled
        case interrupted
        case failed
    }

    let id: UUID
    let conversationID: UUID
    let role: Role
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var parts: [MessagePart]
    var reasoningSegments: [ReasoningSegment]
    var attachments: [MessageAttachment]
    /// When true, the user has collapsed this message's image group and those
    /// images are excluded from later historical-image uploads. `nil` keeps
    /// existing persisted messages backward compatible and means expanded.
    var historicalImagesCollapsed: Bool?
    var toolEvents: [ToolEvent]
    var tokenUsage: TokenUsage?
    var modelID: String?
    var providerID: String?
    var groupID: String?
    var versionGroupID: String?
    var version: Int
    var translation: String?
    var reactions: MessageReactions
    var schemaVersion: Int
    var migrationMetadata: MigrationMetadata?

    var isStreaming: Bool {
        get { status == .streaming }
        set { status = newValue ? .streaming : .complete }
    }

    /// `groupID` is the author assistant identifier in the native app. Keep the
    /// message-version grouping key separate so group-chat authors never collapse
    /// into one logical message.
    var versionGroupKey: String {
        versionGroupID ?? id.uuidString
    }

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: Role,
        text: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        status: Status = .complete,
        parts: [MessagePart]? = nil,
        reasoningSegments: [ReasoningSegment] = [],
        attachments: [MessageAttachment] = [],
        historicalImagesCollapsed: Bool? = nil,
        toolEvents: [ToolEvent] = [],
        tokenUsage: TokenUsage? = nil,
        modelID: String? = nil,
        providerID: String? = nil,
        groupID: String? = nil,
        versionGroupID: String? = nil,
        version: Int = 0,
        translation: String? = nil,
        reactions: MessageReactions = MessageReactions(),
        schemaVersion: Int = ConversationStore.currentSchemaVersion,
        migrationMetadata: MigrationMetadata? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.parts = parts ?? [MessagePart(kind: .text, text: text)]
        self.reasoningSegments = reasoningSegments
        self.attachments = attachments
        self.historicalImagesCollapsed = historicalImagesCollapsed
        self.toolEvents = toolEvents
        self.tokenUsage = tokenUsage
        self.modelID = modelID
        self.providerID = providerID
        self.groupID = groupID ?? id.uuidString
        self.versionGroupID = versionGroupID
        self.version = version
        self.translation = translation
        self.reactions = reactions
        self.schemaVersion = schemaVersion
        self.migrationMetadata = migrationMetadata
    }
}

struct MessagePart: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case text
        case reasoning
        case attachment
        case toolCall
        case toolResult
        case usage
    }

    var id: UUID
    var kind: Kind
    var text: String?
    var attachmentID: UUID?
    var toolEventID: UUID?
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String? = nil,
        attachmentID: UUID? = nil,
        toolEventID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.attachmentID = attachmentID
        self.toolEventID = toolEventID
        self.metadata = metadata
    }
}

struct ReasoningSegment: Codable, Identifiable, Hashable {
    let id: UUID
    var text: String
    var startedAt: Date?
    var finishedAt: Date?
    var expanded: Bool
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        text: String,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        expanded: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.text = text
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.expanded = expanded
        self.metadata = metadata
    }
}

struct MessageAttachment: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case image
        case file
        case audio
        case video
        case location
    }

    let id: UUID
    var kind: Kind
    var localURL: URL?
    var remoteURL: URL?
    var fileName: String?
    var mimeType: String?
    var byteCount: Int64?
    var metadata: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case localURL
        case remoteURL
        case fileName
        case mimeType
        case byteCount
        case metadata
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        localURL: URL? = nil,
        remoteURL: URL? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        byteCount: Int64? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.localURL = localURL
        self.remoteURL = remoteURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        remoteURL = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
        let persistedLocalReference = try container.decodeIfPresent(String.self, forKey: .localURL)
        localURL = AttachmentStore.resolvePersistedLocalURL(persistedLocalReference)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(
            AttachmentStore.persistedLocalReference(for: localURL),
            forKey: .localURL
        )
        try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encode(metadata, forKey: .metadata)
    }
}

struct ToolEvent: Codable, Identifiable, Hashable {
    enum Status: String, Codable, Hashable {
        case pending
        case running
        case complete
        case failed
    }

    let id: UUID
    var providerEventID: String?
    var name: String
    var argumentsJSON: String?
    var resultText: String?
    var status: Status
    var createdAt: Date
    var updatedAt: Date
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        providerEventID: String? = nil,
        name: String,
        argumentsJSON: String? = nil,
        resultText: String? = nil,
        status: Status = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.providerEventID = providerEventID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.resultText = resultText
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

struct TokenUsage: Codable, Hashable {
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
    var totalTokens: Int?
    var durationMilliseconds: Int?
}

struct MessageReactions: Codable, Hashable {
    var assistantReaction: String?
    var userReaction: String?
    var assistantReactionAuthorID: String?
    var bookmarkedAt: Date?
}

struct MigrationMetadata: Codable, Hashable {
    var source: String?
    var sourceID: String?
    var sourceSchemaVersion: Int?
    var importedAt: Date?
    var notes: [String: String]

    init(
        source: String? = nil,
        sourceID: String? = nil,
        sourceSchemaVersion: Int? = nil,
        importedAt: Date? = nil,
        notes: [String: String] = [:]
    ) {
        self.source = source
        self.sourceID = sourceID
        self.sourceSchemaVersion = sourceSchemaVersion
        self.importedAt = importedAt
        self.notes = notes
    }
}

struct ConversationSnapshot: Codable, Hashable {
    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date
    var conversations: [Conversation]
    var messagesByConversation: [UUID: [ChatMessage]]
    var destructiveReductionAuthorized: Bool?

    init(
        schemaVersion: Int = ConversationStore.currentSchemaVersion,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        conversations: [Conversation] = [],
        messagesByConversation: [UUID: [ChatMessage]] = [:],
        destructiveReductionAuthorized: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversations = conversations
        self.messagesByConversation = messagesByConversation
        self.destructiveReductionAuthorized = destructiveReductionAuthorized
    }
}

struct PendingGenerationCompletionRecord: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var runID: UUID
    var conversationID: UUID
    var createdAt: Date
    var completedAt: Date?
    var message: ChatMessage?

    init(
        runID: UUID,
        conversationID: UUID,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        message: ChatMessage? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.conversationID = conversationID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.message = message
    }
}

enum PendingGenerationCompletionJournal {
    static let directoryName = "PendingGenerationCompletions"
    static let maximumRecordByteCount = 16 * 1_024 * 1_024
    // Recovery can run on foreground/unlock while completion awaits a write.
    // Readers, writers and removal share a lane so recovery never consumes a
    // truncated/in-flight journal or unlinks one underneath its writer.
    private static let queue = DispatchQueue(
        label: "com.uuzsama450.mocca.completion-journal", qos: .utility
    )

    struct RecoveryReport {
        var recoveredMessageIDs: [UUID] = []
        var filesReadyForRemoval: [URL] = []
        var failures: [String] = []

        var requiresConversationSave: Bool {
            !recoveredMessageIDs.isEmpty
        }
    }

    // All mutable file/encoder state is confined to the shared journal lane.
    // Immutable ChatMessage value snapshots may be submitted from MainActor.
    final class Writer: @unchecked Sendable {
        let runID: UUID
        let conversationID: UUID
        let fileURL: URL

        private let fileManager: FileManager
        private var fileHandle: FileHandle?
        private let encoder: JSONEncoder
        private let queue = PendingGenerationCompletionJournal.queue
        private var lastCompletedMessage: ChatMessage?

        private final class CompletionRequest: @unchecked Sendable {
            let message: ChatMessage
            init(_ message: ChatMessage) { self.message = message }
        }

        fileprivate init(
            runID: UUID,
            conversationID: UUID,
            fileURL: URL,
            fileManager: FileManager,
            fileHandle: FileHandle
        ) throws {
            self.runID = runID
            self.conversationID = conversationID
            self.fileURL = fileURL
            self.fileManager = fileManager
            self.fileHandle = fileHandle
            encoder = PendingGenerationCompletionJournal.makeEncoder()
            try writeRecord(
                PendingGenerationCompletionRecord(
                    runID: runID,
                    conversationID: conversationID
                )
            )
        }

        deinit {
            try? fileHandle?.close()
        }

        func persistCompletedMessage(_ message: ChatMessage) throws {
            try queue.sync { try persistCompletedMessageOnQueue(message) }
        }

        func enqueueCompletedMessage(
            _ message: ChatMessage,
            completion: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            let request = CompletionRequest(message)
            queue.async { [self, request] in
                completion(Result { try persistCompletedMessageOnQueue(request.message) })
            }
        }

        private func persistCompletedMessageOnQueue(_ message: ChatMessage) throws {
            guard fileHandle != nil else { throw ConversationStoreError.persistenceBlocked }
            guard message.id == runID,
                  message.conversationID == conversationID,
                  message.role == .assistant,
                  message.status != .streaming else {
                throw ConversationStoreError.invalidSnapshotStructure(
                    "待提交回复身份或状态无效"
                )
            }
            // Image post-processing may submit the same already-durable text
            // completion again. Compare the whole value, including metadata.
            guard lastCompletedMessage != message else { return }
            // A failed replacement can leave an incomplete file. Its previous
            // value must no longer qualify for the durable-write fast path.
            lastCompletedMessage = nil
            try writeRecord(
                PendingGenerationCompletionRecord(
                    runID: runID,
                    conversationID: conversationID,
                    completedAt: .now,
                    message: message
                )
            )
            lastCompletedMessage = message
        }

        func closeKeepingFile() {
            queue.sync { closeFileOnQueue() }
        }

        private func closeFileOnQueue() {
            try? fileHandle?.close()
            fileHandle = nil
            lastCompletedMessage = nil
        }

        func closeAndRemoveFile() {
            queue.sync {
                closeFileOnQueue()
                try? fileManager.removeItem(at: fileURL)
            }
        }

        private func writeRecord(
            _ record: PendingGenerationCompletionRecord
        ) throws {
            guard let fileHandle else {
                throw ConversationStoreError.persistenceBlocked
            }
            let data = try encoder.encode(record)
            guard data.count <= PendingGenerationCompletionJournal.maximumRecordByteCount else {
                throw ConversationStoreError.invalidSnapshotStructure(
                    "待提交回复超过安全大小上限"
                )
            }

            try fileHandle.seek(toOffset: 0)
            try fileHandle.truncate(atOffset: 0)
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()

            try fileHandle.seek(toOffset: 0)
            let verifiedData = try fileHandle.read(upToCount: data.count + 1) ?? Data()
            guard verifiedData == data else {
                throw ConversationStoreError.stagedWriteMismatch
            }
            _ = try fileHandle.seekToEnd()
        }
    }

    static func makeWriter(
        runID: UUID,
        conversationID: UUID,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) throws -> Writer {
        try queue.sync {
            try makeWriterOnQueue(runID: runID, conversationID: conversationID,
                                  fileManager: fileManager, directoryURL: directoryURL)
        }
    }

    private static func makeWriterOnQueue(
        runID: UUID,
        conversationID: UUID,
        fileManager: FileManager,
        directoryURL: URL?
    ) throws -> Writer {
        let directory = try resolvedDirectory(
            fileManager: fileManager,
            directoryURL: directoryURL
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(
            "\(runID.uuidString.lowercased()).json"
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUnlessOpen
        #endif
        guard fileManager.createFile(
            atPath: fileURL.path,
            contents: Data(),
            attributes: attributes
        ) else {
            throw ConversationStoreError.persistenceBlocked
        }

        do {
            let handle = try FileHandle(forUpdating: fileURL)
            return try Writer(
                runID: runID,
                conversationID: conversationID,
                fileURL: fileURL,
                fileManager: fileManager,
                fileHandle: handle
            )
        } catch {
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }

    static func mergeRecoverableCompletions(
        into snapshot: inout ConversationSnapshot,
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) -> RecoveryReport {
        queue.sync {
            mergeRecoverableCompletionsOnQueue(into: &snapshot,
                                               fileManager: fileManager, directoryURL: directoryURL)
        }
    }

    private static func mergeRecoverableCompletionsOnQueue(
        into snapshot: inout ConversationSnapshot,
        fileManager: FileManager,
        directoryURL: URL?
    ) -> RecoveryReport {
        var report = RecoveryReport()
        let directory: URL
        do {
            directory = try resolvedDirectory(
                fileManager: fileManager,
                directoryURL: directoryURL
            )
        } catch {
            report.failures.append(error.localizedDescription)
            return report
        }
        guard fileManager.fileExists(atPath: directory.path) else {
            return report
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            report.failures.append(error.localizedDescription)
            return report
        }

        let decoder = makeDecoder()
        for fileURL in files {
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                let byteCount = values.fileSize ?? 0
                guard byteCount > 0,
                      byteCount <= maximumRecordByteCount else {
                    continue
                }
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(
                    PendingGenerationCompletionRecord.self,
                    from: data
                )
                guard record.schemaVersion
                        <= PendingGenerationCompletionRecord.currentSchemaVersion,
                      let conversationIndex = snapshot.conversations.firstIndex(
                        where: { $0.id == record.conversationID }
                      ) else {
                    report.failures.append(
                        "\(fileURL.lastPathComponent)：待提交回复结构无效"
                    )
                    continue
                }
                // A run that was cancelled or killed before completion leaves
                // only the pre-opened manifest. It contains no reply to merge
                // and must not be treated as a corrupt completion.
                guard let message = record.message else {
                    continue
                }
                guard record.runID == message.id,
                      record.conversationID == message.conversationID,
                      message.role == .assistant,
                      message.status != .streaming else {
                    report.failures.append(
                        "\(fileURL.lastPathComponent)：待提交回复身份或状态无效"
                    )
                    continue
                }

                var messages =
                    snapshot.messagesByConversation[record.conversationID] ?? []
                if let messageIndex = messages.firstIndex(
                    where: { $0.id == message.id }
                ) {
                    let current = messages[messageIndex]
                    if current == message {
                        report.filesReadyForRemoval.append(fileURL)
                        continue
                    }
                    guard current.role == .assistant,
                          current.status == .streaming
                            || current.status == .interrupted
                            || current.status == .cancelled
                            || current.text.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty else {
                        report.failures.append(
                            "\(fileURL.lastPathComponent)：已有不同的完整消息，未覆盖"
                        )
                        continue
                    }
                    messages[messageIndex] = message
                } else {
                    // ISO-8601 persistence can collapse the user row and its
                    // assistant placeholder onto the same whole second. Never
                    // use random UUIDs to break that tie: doing so reshuffles
                    // every existing equal-time turn when one durable reply is
                    // recovered. Insert only the missing reply before the first
                    // strictly later row, preserving all existing order and
                    // placing the recovered assistant after equal-time rows.
                    let insertionIndex = messages.firstIndex {
                        $0.createdAt > message.createdAt
                    } ?? messages.endIndex
                    messages.insert(message, at: insertionIndex)
                }

                snapshot.messagesByConversation[record.conversationID] = messages
                if snapshot.conversations[conversationIndex].updatedAt
                    < message.updatedAt {
                    snapshot.conversations[conversationIndex].updatedAt =
                        message.updatedAt
                }
                report.recoveredMessageIDs.append(message.id)
                report.filesReadyForRemoval.append(fileURL)
            } catch {
                report.failures.append(
                    "\(fileURL.lastPathComponent)：\(error.localizedDescription)"
                )
            }
        }
        return report
    }

    static func removeFiles(
        _ fileURLs: [URL],
        fileManager: FileManager = .default
    ) {
        queue.sync {
            for fileURL in Set(fileURLs) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static func resolvedDirectory(
        fileManager: FileManager,
        directoryURL: URL?
    ) throws -> URL {
        if let directoryURL {
            return directoryURL
        }
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ConversationStoreError.missingApplicationSupport
        }
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum ConversationStoreError: LocalizedError {
    case missingApplicationSupport
    case missingAfterFailedLoad
    case unsupportedSchemaVersion(Int)
    case persistenceBlocked
    case stagedWriteMismatch
    case invalidSnapshotStructure(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport: ErrorLocalization.lookup("无法打开本地聊天记录目录")
        case .missingAfterFailedLoad: ErrorLocalization.lookup("先前读取失败后找不到聊天记录文件，已停止创建空存档")
        case let .unsupportedSchemaVersion(version):
            ErrorLocalization.format("聊天记录来自更高版本（schema %@），已停止用当前版本覆盖", [String(describing: version)])
        case .persistenceBlocked:
            ErrorLocalization.lookup("聊天记录未能安全写入，恢复操作没有完成")
        case .stagedWriteMismatch:
            ErrorLocalization.lookup("聊天记录临时文件校验失败，已停止替换原存档")
        case let .invalidSnapshotStructure(reason):
            ErrorLocalization.format("聊天记录结构无效（%@），已停止覆盖原存档", [String(describing: reason)])
        }
    }
}

enum ConversationPersistencePolicy {
    static func permitsConversationCountChange(
        from committedCount: Int,
        to candidateCount: Int,
        allowDestructiveReduction: Bool
    ) -> Bool {
        allowDestructiveReduction
            || committedCount == 0
            || candidateCount >= committedCount
    }

    static func permitsMessageCountChange(
        from committedCount: Int,
        to candidateCount: Int,
        allowDestructiveReduction: Bool
    ) -> Bool {
        allowDestructiveReduction
            || committedCount == 0
            || candidateCount >= committedCount
    }

    static func permitsRetainedIDs<ID: Hashable>(
        from committedIDs: Set<ID>,
        to candidateIDs: Set<ID>,
        allowDestructiveReduction: Bool
    ) -> Bool {
        allowDestructiveReduction
            || committedIDs.isSubset(of: candidateIDs)
    }
}

/// Reuses only byte encodings, never persisted state. Access stays on the store's
/// existing serial save executor, just like its JSONEncoder/JSONDecoder.
/// The schema remains v1: UUID-keyed dictionaries encode as alternating arrays.
final class ConversationSnapshotEncoder {
    private struct Header: Encodable {
        let schemaVersion: Int
        let createdAt: Date
        let updatedAt: Date
        let conversations: [Conversation]
        let destructiveReductionAuthorized: Bool?
    }

    private struct Entry {
        let message: ChatMessage
        let data: Data
    }

    private let encoder: JSONEncoder
    private let maximumCachedBytes: Int
    private let maximumCachedMessages: Int
    private var cache: [UUID: Entry] = [:]
    private(set) var cachedByteCount = 0
    var cachedMessageCount: Int { cache.count }

    init(maximumCachedBytes: Int = 64 * 1024 * 1024,
         maximumCachedMessages: Int = 16_384) {
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.maximumCachedMessages = max(0, maximumCachedMessages)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    func encode(_ snapshot: ConversationSnapshot) throws -> Data {
        let retainedIDs = Set(snapshot.messagesByConversation.values.joined().lazy.map(\.id))
        for id in cache.keys where !retainedIDs.contains(id) {
            if let removed = cache.removeValue(forKey: id) {
                cachedByteCount -= removed.data.count
            }
        }

        var data = try encoder.encode(Header(
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            conversations: snapshot.conversations,
            destructiveReductionAuthorized: snapshot.destructiveReductionAuthorized
        ))
        // Header is a synthesized JSON object. All keys, values and message
        // strings below are still escaped/encoded by Foundation's JSONEncoder.
        data.removeLast()
        data.append(contentsOf: #","messagesByConversation":["#.utf8)
        var firstConversation = true
        for (conversationID, messages) in snapshot.messagesByConversation {
            if !firstConversation { data.append(44) }
            firstConversation = false
            data.append(try encoder.encode(conversationID))
            data.append(contentsOf: ",[".utf8)
            for (index, message) in messages.enumerated() {
                if index > 0 { data.append(44) }
                if let entry = cache[message.id], entry.message == message {
                    data.append(entry.data)
                    continue
                }
                if let removed = cache.removeValue(forKey: message.id) {
                    cachedByteCount -= removed.data.count
                }
                let encoded = try encoder.encode(message)
                data.append(encoded)
                if cache.count < maximumCachedMessages,
                   encoded.count <= maximumCachedBytes - cachedByteCount {
                    cache[message.id] = Entry(message: message, data: encoded)
                    cachedByteCount += encoded.count
                }
            }
            data.append(93)
        }
        data.append(contentsOf: "]}".utf8)
        return data
    }
}

struct LegacyConversationStore {
    static let currentSchemaVersion = 1

    private struct SchemaVersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct ReceiptSchemaEnvelope: Decodable {
        var schemaVersion: Int
    }

    private struct LegacyTrustedGenerationReceipt: Codable {
        var schemaVersion: Int
        var retainedConversationIDs: [UUID]
        var retainedMessageIDs: [UUID]
    }

    private struct TrustedGenerationReceipt: Codable {
        static let currentSchemaVersion = 2

        var schemaVersion: Int
        var snapshotSchemaVersion: Int
        var primaryDataSHA256: String
        var conversationCount: Int
        var messageCount: Int
        var conversationIDsSHA256: String
        var messageIDsSHA256: String
    }

    private enum DecodedTrustedGenerationReceipt {
        case legacy(LegacyTrustedGenerationReceipt)
        case digest(TrustedGenerationReceipt)
    }

    private struct TrustedGenerationReceiptMatch {
        var committedReceipts: [DecodedTrustedGenerationReceipt]
        var exactPrimaryDataReceipts: [
            DecodedTrustedGenerationReceipt
        ]
    }

    enum LoadResult {
        case missing
        case loaded(ConversationSnapshot)
        case recoveredFromBackup(
            ConversationSnapshot,
            primaryFailureDescription: String
        )
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let backupURL: URL
    private let trustedReceiptURL: URL
    private let stagingURL: URL
    private let receiptStagingURL: URL
    private let receiptPreparingURL: URL
    private let receiptAlternatePreparingURL: URL
    private let rejectedFirstURL: URL
    private let rejectedLatestURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let snapshotEncoder = ConversationSnapshotEncoder()

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) throws {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            guard let root = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ConversationStoreError.missingApplicationSupport
            }
            directory = root.appendingPathComponent("ConversationStore", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileManager = fileManager
        fileURL = directory.appendingPathComponent("conversations_v1.json")
        backupURL = directory.appendingPathComponent("conversations_v1.previous.json")
        trustedReceiptURL = directory.appendingPathComponent(
            "conversations_v1.trusted-generation.json"
        )
        stagingURL = directory.appendingPathComponent(
            "conversations_v1.next"
        )
        receiptStagingURL = directory.appendingPathComponent(
            "conversations_v1.trusted-generation.next.json"
        )
        receiptPreparingURL = directory.appendingPathComponent(
            "conversations_v1.trusted-generation.preparing.json"
        )
        receiptAlternatePreparingURL = directory.appendingPathComponent(
            "conversations_v1.trusted-generation.preparing-alternate.json"
        )
        rejectedFirstURL = directory.appendingPathComponent(
            "conversations_v1.rejected-first.json"
        )
        rejectedLatestURL = directory.appendingPathComponent(
            "conversations_v1.rejected-latest.json"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> LoadResult {
        let primaryData: Data
        do {
            primaryData = try Data(contentsOf: fileURL)
        } catch {
            guard Self.isFileNotFound(error) else {
                // A protection/permission/I/O failure is temporary or unknown.
                // Do not substitute an older backup and grant write access.
                throw error
            }
            return try loadBackup(
                primaryFailureDescription: "主存档缺失",
                primaryValidationError: nil
            )
        }

        do {
            let primaryDataSHA256 = Self.sha256Hex(primaryData)
            let receiptMatch = decodedTrustedGenerationReceipt(
                primaryDataSHA256: primaryDataSHA256
            )
            var snapshot = try validatedPrimarySnapshot(
                from: primaryData,
                receiptMatch: receiptMatch
            )
            let exactReceiptAuthorizesPrimary =
                receiptMatch.exactPrimaryDataReceipts.contains {
                    Self.trustedGenerationReceipt(
                        $0,
                        authorizes: snapshot
                    )
                }
            let receiptAuthorizesPrimary =
                exactReceiptAuthorizesPrimary
                || (
                    !receiptMatch.committedReceipts.isEmpty
                    && receiptMatch.committedReceipts.allSatisfy {
                        Self.trustedGenerationReceipt(
                            $0,
                            authorizes: snapshot
                        )
                    }
                )
            _ = normalizeAfterColdStart(&snapshot)
            if exactReceiptAuthorizesPrimary {
                return .loaded(snapshot)
            }
            if var previousSnapshot = try validatedBackupForComparison() {
                _ = normalizeAfterColdStart(&previousSnapshot)
                if Self.isReduced(snapshot, comparedWith: previousSnapshot) {
                    if receiptAuthorizesPrimary {
                        return .loaded(snapshot)
                    }
                    return .recoveredFromBackup(
                        previousSnapshot,
                        primaryFailureDescription: """
                        主存档比上一版异常减少（\(snapshot.conversations.count) 段 / \
                        \(Self.messageCount(in: snapshot)) 条）
                        """
                    )
                }
            }
            return .loaded(snapshot)
        } catch let error as ConversationStoreError {
            if case .unsupportedSchemaVersion = error {
                // An older app must never replace a readable newer-format
                // primary with an older backup.
                throw error
            }
            return try loadBackup(
                primaryFailureDescription: error.localizedDescription,
                primaryValidationError: error
            )
        } catch {
            // The primary bytes were readable but structurally invalid. A
            // validated previous generation is safe to display and can be
            // promoted without rotating the invalid primary over it.
            return try loadBackup(
                primaryFailureDescription: error.localizedDescription,
                primaryValidationError: error
            )
        }
    }

    func save(
        _ snapshot: ConversationSnapshot,
        preserveExistingBackup: Bool = false,
        authorizedDestructiveReduction: Bool = false
    ) throws {
        var snapshot = snapshot
        snapshot.schemaVersion = Self.currentSchemaVersion
        snapshot.updatedAt = .now
        snapshot.destructiveReductionAuthorized =
            authorizedDestructiveReduction ? true : nil
        try Self.validateSnapshotStructure(snapshot)
        let data = try snapshotEncoder.encode(snapshot)
        let dataSHA256 = Self.sha256Hex(data)
        let receiptData = try trustedGenerationReceiptData(
            for: snapshot,
            primaryDataSHA256: dataSHA256
        )
        let selectedReceiptPreparingURL =
            try receiptPreparingURLForNewSave()

        var primaryCommitted = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if !primaryCommitted {
                try? fileManager.removeItem(
                    at: selectedReceiptPreparingURL
                )
            }
        }

        try receiptData.write(
            to: selectedReceiptPreparingURL,
            options: [.completeFileProtectionUnlessOpen]
        )
        let stagedReceiptData = try Data(
            contentsOf: selectedReceiptPreparingURL,
            options: [.mappedIfSafe]
        )
        guard stagedReceiptData == receiptData else {
            throw ConversationStoreError.stagedWriteMismatch
        }

        try data.write(
            to: stagingURL,
            options: [.completeFileProtectionUnlessOpen]
        )
        let stagedData = try Data(
            contentsOf: stagingURL,
            options: [.mappedIfSafe]
        )
        guard stagedData.count == data.count,
              Self.sha256Hex(stagedData) == dataSHA256 else {
            throw ConversationStoreError.stagedWriteMismatch
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            if preserveExistingBackup {
                try preserveRejectedPrimary()
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: stagingURL
                )
            } else {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: stagingURL,
                    backupItemName: backupURL.lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
            }
        } else {
            try fileManager.moveItem(at: stagingURL, to: fileURL)
        }
        primaryCommitted = true

        // From here on the primary is committed, so failure must not be
        // reported as a failed save: callers could otherwise retry and append
        // the same user message twice. The old pending receipt was not touched
        // before commit; the selected preparing slot now exactly identifies
        // the new primary until a fixed pending/canonical slot is verified.
        var pendingReceiptInstalled = false
        do {
            try receiptData.write(
                to: receiptStagingURL,
                options: [.completeFileProtectionUnlessOpen]
            )
            let installedPendingReceiptData = try Data(
                contentsOf: receiptStagingURL,
                options: [.mappedIfSafe]
            )
            pendingReceiptInstalled =
                installedPendingReceiptData == receiptData
        } catch {
            // The preparing receipt remains an exact-hash fallback.
        }

        var canonicalReceiptInstalled = false
        do {
            try receiptData.write(
                to: trustedReceiptURL,
                options: [.completeFileProtectionUnlessOpen]
            )
            let installedReceiptData = try Data(
                contentsOf: trustedReceiptURL,
                options: [.mappedIfSafe]
            )
            canonicalReceiptInstalled = installedReceiptData == receiptData
        } catch {
            // Keep a verified pending/preparing receipt. `load()` accepts a
            // fast path only after both the full primary hash and identity
            // digests match the decoded primary.
        }
        if canonicalReceiptInstalled {
            try? fileManager.removeItem(at: receiptStagingURL)
            for url in receiptPreparingURLs {
                try? fileManager.removeItem(at: url)
            }
        } else if pendingReceiptInstalled {
            for url in receiptPreparingURLs {
                try? fileManager.removeItem(at: url)
            }
        } else {
            // The selected slot is the only exact proof needed for the newly
            // committed primary. Remove an obsolete sibling when possible;
            // if cleanup itself fails, the two fixed names still bound growth.
            for url in receiptPreparingURLs
                where url != selectedReceiptPreparingURL {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static func decodeValidatedSnapshot(
        from data: Data
    ) throws -> ConversationSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try validatedSnapshot(from: data, decoder: decoder)
    }

    private func validatedSnapshot(from data: Data) throws -> ConversationSnapshot {
        try Self.validatedSnapshot(from: data, decoder: decoder)
    }

    private func validatedPrimarySnapshot(
        from data: Data,
        receiptMatch: TrustedGenerationReceiptMatch
    ) throws -> ConversationSnapshot {
        let trustedSchemaVersions = Set<Int>(
            receiptMatch.exactPrimaryDataReceipts.compactMap {
                guard case let .digest(receipt) = $0,
                      receipt.snapshotSchemaVersion
                        <= Self.currentSchemaVersion else {
                    return nil
                }
                return receipt.snapshotSchemaVersion
            }
        )
        if !trustedSchemaVersions.isEmpty {
            let snapshot = try decoder.decode(
                ConversationSnapshot.self,
                from: data
            )
            try Self.validateSnapshotStructure(snapshot)
            if trustedSchemaVersions.contains(snapshot.schemaVersion) {
                return snapshot
            }
        }
        return try validatedSnapshot(from: data)
    }

    private static func validatedSnapshot(
        from data: Data,
        decoder: JSONDecoder
    ) throws -> ConversationSnapshot {
        let envelope = try decoder.decode(
            SchemaVersionEnvelope.self,
            from: data
        )
        guard envelope.schemaVersion <= Self.currentSchemaVersion else {
            throw ConversationStoreError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }
        let snapshot = try decoder.decode(ConversationSnapshot.self, from: data)
        try validateSnapshotStructure(snapshot)
        return snapshot
    }

    fileprivate static func validateSnapshotStructure(
        _ snapshot: ConversationSnapshot
    ) throws {
        let conversationIDs = snapshot.conversations.map(\.id)
        let uniqueConversationIDs = Set(conversationIDs)
        guard uniqueConversationIDs.count == conversationIDs.count else {
            throw ConversationStoreError.invalidSnapshotStructure(
                "存在重复会话 ID"
            )
        }

        let messageConversationIDs = Set(
            snapshot.messagesByConversation.keys
        )
        guard messageConversationIDs.isSubset(
            of: uniqueConversationIDs
        ) else {
            throw ConversationStoreError.invalidSnapshotStructure(
                "存在不属于任何会话的消息分组"
            )
        }

        var uniqueMessageIDs = Set<UUID>()
        for (conversationID, messages) in
            snapshot.messagesByConversation {
            for message in messages {
                guard message.conversationID == conversationID else {
                    throw ConversationStoreError.invalidSnapshotStructure(
                        "消息所属会话与分组不一致"
                    )
                }
                guard uniqueMessageIDs.insert(message.id).inserted else {
                    throw ConversationStoreError.invalidSnapshotStructure(
                        "存在重复消息 ID"
                    )
                }
            }
        }
        let highestNestedSchemaVersion = max(
            snapshot.conversations.map(\.schemaVersion).max() ?? 0,
            snapshot.messagesByConversation.values
                .joined().lazy
                .map(\.schemaVersion)
                .max() ?? 0
        )
        let highestSchemaVersion = max(
            snapshot.schemaVersion,
            highestNestedSchemaVersion
        )
        guard highestSchemaVersion <= Self.currentSchemaVersion else {
            throw ConversationStoreError.unsupportedSchemaVersion(
                highestSchemaVersion
            )
        }
    }

    private func validatedBackupForComparison() throws -> ConversationSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: backupURL)
        } catch {
            if Self.isFileNotFound(error) {
                return nil
            }
            throw error
        }

        do {
            return try validatedSnapshot(from: data)
        } catch let error as ConversationStoreError {
            if case .unsupportedSchemaVersion = error {
                throw error
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func isReduced(
        _ candidate: ConversationSnapshot,
        comparedWith previous: ConversationSnapshot
    ) -> Bool {
        let candidateConversationIDs = Set(candidate.conversations.map(\.id))
        let previousConversationIDs = Set(previous.conversations.map(\.id))
        let candidateMessageIDs = messageIDs(in: candidate)
        let previousMessageIDs = messageIDs(in: previous)
        return candidate.conversations.count < previous.conversations.count
            || messageCount(in: candidate) < messageCount(in: previous)
            || !previousConversationIDs.isSubset(of: candidateConversationIDs)
            || !previousMessageIDs.isSubset(of: candidateMessageIDs)
    }

    private static func messageCount(in snapshot: ConversationSnapshot) -> Int {
        snapshot.messagesByConversation.values.reduce(0) {
            $0 + $1.count
        }
    }

    private static func messageIDs(
        in snapshot: ConversationSnapshot
    ) -> Set<UUID> {
        Set(
            snapshot.messagesByConversation.values
                .joined().lazy
                .map(\.id)
        )
    }

    private func decodedTrustedGenerationReceipt(
        primaryDataSHA256: String
    ) -> TrustedGenerationReceiptMatch {
        let preparingReceipts = receiptPreparingURLs.compactMap {
            decodeTrustedGenerationReceipt(at: $0)
        }
        let committedReceipts = [
            receiptStagingURL,
            trustedReceiptURL
        ].compactMap {
            decodeTrustedGenerationReceipt(at: $0)
        }
        let exactCandidates = preparingReceipts + committedReceipts
        return TrustedGenerationReceiptMatch(
            committedReceipts: committedReceipts,
            exactPrimaryDataReceipts: exactCandidates.filter {
                guard case let .digest(receipt) = $0 else {
                    return false
                }
                return receipt.primaryDataSHA256 == primaryDataSHA256
            }
        )
    }

    private var receiptPreparingURLs: [URL] {
        [
            receiptPreparingURL,
            receiptAlternatePreparingURL
        ]
    }

    private func receiptPreparingURLForNewSave() throws -> URL {
        // A pre-commit failure must never overwrite the only exact receipt for
        // the currently committed primary. In the common steady state neither
        // fixed preparing slot exists, so this adds no primary reread/hash.
        if let unusedURL = receiptPreparingURLs.first(where: {
            !fileManager.fileExists(atPath: $0.path)
        }) {
            return unusedURL
        }

        // Both slots can coexist only around a crash or failed cleanup. Keep a
        // slot whose full hash and identity match the current primary and reuse
        // a sibling.
        let currentPrimaryData: Data
        do {
            currentPrimaryData = try Data(
                contentsOf: fileURL,
                options: [.mappedIfSafe]
            )
        } catch {
            guard Self.isFileNotFound(error) else {
                throw error
            }
            // Repeated first-save crashes can fill both fixed preparing slots
            // while no committed primary exists. There is no receipt to
            // preserve in that state, so either slot is safe to reuse.
            return receiptPreparingURL
        }
        let currentPrimaryDataSHA256 = Self.sha256Hex(currentPrimaryData)
        let currentSnapshot = try validatedSnapshot(from: currentPrimaryData)
        let exactCurrentURLs = receiptPreparingURLs.filter { url in
            guard case let .digest(receipt)? =
                    decodeTrustedGenerationReceipt(at: url) else {
                return false
            }
            return receipt.primaryDataSHA256 == currentPrimaryDataSHA256
                && Self.trustedGenerationReceipt(
                    .digest(receipt),
                    authorizes: currentSnapshot
                )
        }
        if let reusableURL = receiptPreparingURLs.first(where: {
            !exactCurrentURLs.contains($0)
        }) {
            return reusableURL
        }

        // If both fixed slots prove the same current primary, replacing either
        // one still leaves an exact receipt untouched until commit.
        return receiptPreparingURL
    }

    private func decodeTrustedGenerationReceipt(
        at url: URL
    ) -> DecodedTrustedGenerationReceipt? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return nil
        }

        let envelope: ReceiptSchemaEnvelope
        do {
            envelope = try decoder.decode(
                ReceiptSchemaEnvelope.self,
                from: data
            )
        } catch {
            return nil
        }
        guard envelope.schemaVersion
                <= TrustedGenerationReceipt.currentSchemaVersion else {
            // Receipts are derived metadata. Unknown or unreadable metadata is
            // untrusted, but it must not make an otherwise valid primary fail.
            return nil
        }

        do {
            switch envelope.schemaVersion {
            case 1:
                return .legacy(
                    try decoder.decode(
                        LegacyTrustedGenerationReceipt.self,
                        from: data
                    )
                )
            case TrustedGenerationReceipt.currentSchemaVersion:
                return .digest(
                    try decoder.decode(
                        TrustedGenerationReceipt.self,
                        from: data
                    )
                )
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private static func trustedGenerationReceipt(
        _ receipt: DecodedTrustedGenerationReceipt?,
        authorizes snapshot: ConversationSnapshot
    ) -> Bool {
        switch receipt {
        case let .legacy(legacyReceipt):
            return Set(legacyReceipt.retainedConversationIDs)
                    == Set(snapshot.conversations.map(\.id))
                && Set(legacyReceipt.retainedMessageIDs)
                    == messageIDs(in: snapshot)
        case let .digest(digestReceipt):
            let messageIDs = snapshot.messagesByConversation.values
                .joined()
                .map(\.id)
            return digestReceipt.snapshotSchemaVersion
                    == snapshot.schemaVersion
                && digestReceipt.conversationCount
                    == snapshot.conversations.count
                && digestReceipt.messageCount == messageIDs.count
                && digestReceipt.conversationIDsSHA256
                    == stableUUIDSetDigest(
                        snapshot.conversations.map(\.id),
                        domain: "conversation-ids-v1"
                    )
                && digestReceipt.messageIDsSHA256
                    == stableUUIDSetDigest(
                        messageIDs,
                        domain: "message-ids-v1"
                    )
        case nil:
            return false
        }
    }

    private func trustedGenerationReceiptData(
        for snapshot: ConversationSnapshot,
        primaryDataSHA256: String
    ) throws -> Data {
        let messageIDs = snapshot.messagesByConversation.values
            .joined()
            .map(\.id)
        let receipt = TrustedGenerationReceipt(
            schemaVersion: TrustedGenerationReceipt.currentSchemaVersion,
            snapshotSchemaVersion: snapshot.schemaVersion,
            primaryDataSHA256: primaryDataSHA256,
            conversationCount: snapshot.conversations.count,
            messageCount: messageIDs.count,
            conversationIDsSHA256: Self.stableUUIDSetDigest(
                snapshot.conversations.map(\.id),
                domain: "conversation-ids-v1"
            ),
            messageIDsSHA256: Self.stableUUIDSetDigest(
                messageIDs,
                domain: "message-ids-v1"
            )
        )
        return try encoder.encode(receipt)
    }

    private static func stableUUIDSetDigest(
        _ ids: [UUID],
        domain: String
    ) -> String {
        var hasher = SHA256()
        let separator = Data([0])
        hasher.update(data: Data(domain.utf8))
        hasher.update(data: separator)
        for value in Set(ids)
            .map(\.uuidString)
            .sorted() {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: separator)
        }
        return hexString(hasher.finalize())
    }

    private static func sha256Hex(_ data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    private static func hexString<Bytes: Sequence>(
        _ bytes: Bytes
    ) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func preserveRejectedPrimary() throws {
        let rejectedData = try Data(contentsOf: fileURL)
        let destination = fileManager.fileExists(
            atPath: rejectedFirstURL.path
        ) ? rejectedLatestURL : rejectedFirstURL
        try rejectedData.write(
            to: destination,
            options: [.completeFileProtectionUnlessOpen]
        )
        let preservedData = try Data(
            contentsOf: destination,
            options: [.mappedIfSafe]
        )
        guard preservedData == rejectedData else {
            throw ConversationStoreError.stagedWriteMismatch
        }
    }

    private func loadBackup(
        primaryFailureDescription: String,
        primaryValidationError: Error?
    ) throws -> LoadResult {
        do {
            let backupData = try Data(contentsOf: backupURL)
            var snapshot = try validatedSnapshot(from: backupData)
            _ = normalizeAfterColdStart(&snapshot)
            return .recoveredFromBackup(
                snapshot,
                primaryFailureDescription: primaryFailureDescription
            )
        } catch {
            if Self.isFileNotFound(error) {
                if let primaryValidationError {
                    throw primaryValidationError
                }
                return .missing
            }
            throw error
        }
    }

    private static func isFileNotFound(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
    }

    fileprivate func normalizeAfterColdStart(_ snapshot: inout ConversationSnapshot) -> Bool {
        var changed = false
        for conversation in snapshot.conversations {
            // Most histories contain no unfinished reply. Avoid mutating their
            // arrays merely to discover that there is nothing to normalize:
            // keeping value storage shared also avoids a cold first-save diff.
            if let existing = snapshot.messagesByConversation[conversation.id],
               !existing.contains(where: { $0.status == .streaming }) {
                continue
            }
            var messages = snapshot.messagesByConversation[conversation.id] ?? []
            let originalCount = messages.count
            messages.removeAll { message in
                message.status == .streaming && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            for index in messages.indices where messages[index].status == .streaming {
                messages[index].status = .interrupted
                messages[index].updatedAt = .now
                changed = true
            }
            if messages.count != originalCount {
                changed = true
            }
            snapshot.messagesByConversation[conversation.id] = messages
        }
        return changed
    }
}

/// One instance belongs to ConversationStoreSaveExecutor's serial queue.
/// The legacy JSON reader remains the import/export and schema authority.
struct ConversationStore {
    static let currentSchemaVersion = LegacyConversationStore.currentSchemaVersion
    typealias LoadResult = LegacyConversationStore.LoadResult
    private let records: ConversationRecordDatabase

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) throws {
        guard let directory = directoryURL ?? fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("ConversationStore", isDirectory: true) else {
            throw ConversationStoreError.missingApplicationSupport
        }
        records = try ConversationRecordDatabase(directory: directory, fileManager: fileManager)
    }

    func load() throws -> LoadResult { try records.load() }
    func save(_ snapshot: ConversationSnapshot, preserveExistingBackup: Bool = false,
              authorizedDestructiveReduction: Bool = false) throws {
        try records.save(snapshot, authorizedReduction: authorizedDestructiveReduction)
    }
    static func decodeValidatedSnapshot(from data: Data) throws -> ConversationSnapshot {
        try LegacyConversationStore.decodeValidatedSnapshot(from: data)
    }
}

/// A committed generation contains small generation metadata and independently
/// encoded values. An independent database retains the preceding snapshot,
/// also through record updates rather than full-file copies.
final class ConversationRecordDatabase {
    private struct Layout: Codable, Equatable {
        var schemaVersion: Int
        var conversations: [UUID]
        var messages: [UUID: [UUID]]
        init(_ snapshot: ConversationSnapshot) {
            schemaVersion = snapshot.schemaVersion
            conversations = snapshot.conversations.map(\.id)
            messages = snapshot.messagesByConversation.mapValues { $0.map(\.id) }
        }
    }
    private struct Generation: Codable {
        var id: Int64
        var createdAt: Date
        var updatedAt: Date
        var destructiveReductionAuthorized: Bool?
        // Optional for reading 4978. A restored/recreated primary gets a new
        // lineage, so equal generation numbers cannot identify unrelated data.
        var lineage: UUID?
    }
    private let directory: URL
    private let isReplica: Bool
    private var replica: ConversationRecordDatabase?
    private var replacementRequired = false
    private var missingHead = false
    private var lineage = UUID()
    private let fileManager: FileManager
    private let legacy: LegacyConversationStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var connection: OpaquePointer?
    private var committed: ConversationSnapshot?
    private var generation: Int64 = 0
    private var didLoad = false
    private var coldStartRemovals: Set<UUID> = []
    private(set) var lastChangedRecordCount = 0
    private(set) var lastEncodedByteCount = 0
    #if DEBUG
    /// Fault injection is instance-local and has no production caller.
    var failBeforeCommitForTesting = false
    private(set) var lastStageTimings: [String: Double] = [:]
    private(set) var lastReplicaStageTimings: [String: Double] = [:]
    private(set) var lastReplicaRecordCount = 0
    private(set) var decodedSnapshotCount = 0
    var replicaDecodedSnapshotCount: Int { replica?.decodedSnapshotCount ?? 0 }
    #endif

    init(directory: URL, fileManager: FileManager, isReplica: Bool = false) throws {
        self.directory = directory
        self.isReplica = isReplica
        self.fileManager = fileManager
        legacy = try LegacyConversationStore(fileManager: fileManager, directoryURL: directory)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    deinit { if let connection { sqlite3_close(connection) } }
    private func failure(_ detail: String) -> Error {
        ConversationStoreError.invalidSnapshotStructure("记录存储：\(detail)")
    }
    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW else {
            let description = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if code & 0xff == SQLITE_CORRUPT || code & 0xff == SQLITE_NOTADB {
                throw failure(description)
            }
            // Busy, protection, permission and I/O failures are not evidence
            // that older data should replace the primary.
            throw NSError(domain: "Mocca.RecordSQLite", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: description])
        }
    }
    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil))
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &result, nil))
        guard let result else { throw failure("无法准备事务") }
        return result
    }
    private func bind(_ data: Data?, to statement: OpaquePointer, at index: Int32) throws {
        guard let data else { try check(sqlite3_bind_null(statement, index)); return }
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count),
                                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
    }
    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) throws {
        try check(sqlite3_bind_text(statement, index, text, -1,
                                   unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
    }
    private func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    private func digest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }

    private func open() throws {
        guard connection == nil else { return }
        let url = directory.appendingPathComponent("conversations_records.sqlite")
        // Directory protection is inherited by SQLite's journal and database.
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                      ofItemAtPath: directory.path)
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        connection = db
        var ready = false
        defer {
            if !ready, let connection {
                sqlite3_close(connection)
                self.connection = nil
            }
        }
        try check(code)
        // A single application-owned writer: lock contention fails promptly;
        // never add a busy-retry loop to the synchronous send path.
        sqlite3_busy_timeout(connection, 0)
        try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON;")
        let version = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(version) }
        try check(sqlite3_step(version))
        let schemaVersion = sqlite3_column_int(version, 0)
        guard schemaVersion <= 1 else { throw ConversationStoreError.unsupportedSchemaVersion(Int(schemaVersion) + 1000) }
        try execute("""
            CREATE TABLE IF NOT EXISTS generations(slot INTEGER PRIMARY KEY, payload BLOB NOT NULL, hash BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS records(key TEXT PRIMARY KEY, value BLOB, hash BLOB,
                prior BLOB, prior_hash BLOB, generation INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS records_generation ON records(generation);
            CREATE INDEX IF NOT EXISTS records_prior ON records(generation) WHERE prior IS NOT NULL;
            CREATE INDEX IF NOT EXISTS records_deleted ON records(generation) WHERE value IS NULL;
            """)
        // Reopening an initialized primary or backup must not dirty its header
        // merely to write the same version again. Keep schema repair above and
        // initialize an unversioned database only after that work succeeds.
        if schemaVersion != 1 {
            try execute("PRAGMA user_version=1;")
        }
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                      ofItemAtPath: url.path)
        ready = true
    }

    private func readGeneration(_ slot: Int) throws -> Generation? {
        let query = try statement("SELECT payload, hash FROM generations WHERE slot=\(slot)")
        defer { sqlite3_finalize(query) }
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        try check(result)
        guard let payload = data(query, 0), digest(payload) == data(query, 1) else {
            throw failure("提交记录校验失败")
        }
        return try decoder.decode(Generation.self, from: payload)
    }
    private func putGeneration(_ info: Generation, slot: Int) throws {
        let bytes = try encoder.encode(info)
        let query = try statement("INSERT OR REPLACE INTO generations(slot,payload,hash) VALUES(\(slot),?,?)")
        defer { sqlite3_finalize(query) }
        try bind(bytes, to: query, at: 1)
        try bind(digest(bytes), to: query, at: 2)
        try check(sqlite3_step(query))
    }
    private func decodeSnapshot(_ info: Generation) throws -> ConversationSnapshot {
        #if DEBUG
        decodedSnapshotCount += 1
        #endif
        // Read and hash records only at load/recovery, never on a warm save.
        // Recovery uses the independent database, not mixed per-record history.
        let query = try statement("SELECT key,value,hash,generation FROM records")
        defer { sqlite3_finalize(query) }
        var values: [String: Data] = [:]
        while true {
            let result = sqlite3_step(query)
            if result == SQLITE_DONE { break }
            try check(result)
            guard let keyBytes = sqlite3_column_text(query, 0) else { throw failure("记录缺少身份") }
            let key = String(cString: keyBytes)
            guard sqlite3_column_int64(query, 3) <= info.id else { throw failure("记录超出已提交代次") }
            guard let bytes = data(query, 1) else { continue }
            guard digest(bytes) == data(query, 2) else { throw failure("记录校验失败") }
            values[key] = bytes
        }
        guard let layoutBytes = values.removeValue(forKey: "layout") else { throw failure("缺少会话索引") }
        let layout = try decoder.decode(Layout.self, from: layoutBytes)
        var snapshot = ConversationSnapshot(schemaVersion: layout.schemaVersion,
                                            createdAt: info.createdAt, updatedAt: info.updatedAt,
                                            destructiveReductionAuthorized: info.destructiveReductionAuthorized)
        for id in layout.conversations {
            guard let bytes = values.removeValue(forKey: "c:\(id)") else { throw failure("会话缺失") }
            let conversation = try decoder.decode(Conversation.self, from: bytes)
            guard conversation.id == id else { throw failure("会话身份不匹配") }
            snapshot.conversations.append(conversation)
        }
        for (id, messageIDs) in layout.messages {
            snapshot.messagesByConversation[id] = try messageIDs.map { messageID in
                guard let bytes = values.removeValue(forKey: "m:\(messageID)") else { throw failure("消息缺失") }
                let message = try decoder.decode(ChatMessage.self, from: bytes)
                guard message.id == messageID else { throw failure("消息身份不匹配") }
                return message
            }
        }
        guard values.isEmpty else { throw failure("存在未被索引的记录") }
        try LegacyConversationStore.validateSnapshotStructure(snapshot)
        return snapshot
    }

    func load() throws -> ConversationStore.LoadResult {
        missingHead = false
        do { return try loadLocal() }
        catch {
            if isReplica { throw error }
            let missingMigratedPrimary: Bool
            if case ConversationStoreError.unsupportedSchemaVersion(2) = error {
                missingMigratedPrimary = missingHead
            } else { missingMigratedPrimary = false }
            guard mayRecover(error) || missingMigratedPrimary else { throw error }
            let backupURL = directory.appendingPathComponent("previous-records/conversations_records.sqlite")
            guard fileManager.fileExists(atPath: backupURL.path) else { throw error }
            let backup = try previousStore()
            // Read the independent backup's own authoritative generation. Do
            // not silently cascade to an even older backup of the backup.
            let result = try backup.loadLocal()
            guard case .loaded(let value) = result else { throw error }
            committed = value
            replacementRequired = true
            didLoad = true
            var normalized = value
            normalizeLoaded(&normalized)
            return .recoveredFromBackup(normalized, primaryFailureDescription: error.localizedDescription)
        }
    }

    private func previousStore() throws -> ConversationRecordDatabase {
        if let replica { return replica }
        let result = try ConversationRecordDatabase(directory: directory.appendingPathComponent("previous-records"),
                                                   fileManager: fileManager, isReplica: true)
        replica = result
        return result
    }

    private func loadLocal() throws -> ConversationStore.LoadResult {
        try open()
        guard let head = try readGeneration(0) else {
            missingHead = true
            // An interrupted initial transaction contains no authoritative new
            // generation. The old reader decides whether retrying is safe.
            let legacyResult = try legacy.load()
            switch legacyResult {
            case .missing:
                try write(ConversationSnapshot(), authorizedReduction: true, importing: true)
                return .missing
            case .loaded(let snapshot), .recoveredFromBackup(let snapshot, _):
                try write(snapshot, authorizedReduction: true, importing: true)
                guard let imported = try readGeneration(0) else { throw failure("导入提交丢失") }
                let verified = try decodeSnapshot(imported)
                let canonical = try decoder.decode(ConversationSnapshot.self, from: encoder.encode(snapshot))
                guard verified.conversations == canonical.conversations,
                      verified.messagesByConversation == canonical.messagesByConversation else {
                    throw failure("旧存档导入核对失败")
                }
                committed = verified; generation = imported.id; didLoad = true
                if !isReplica { try prepareInitialBackup(from: imported) }
                return legacyResult
            }
        }
        var snapshot = try decodeSnapshot(head)
        committed = snapshot; generation = head.id; lineage = head.lineage ?? UUID(); didLoad = true
        if !isReplica, head.lineage == nil { try prepareInitialBackup(from: head) }
        normalizeLoaded(&snapshot)
        return .loaded(snapshot)
    }

    // One-time legacy/4978 upgrade work belongs to store initialization. Normal
    // restarts do not open or decode the backup until a small record update.
    private func prepareInitialBackup(from head: Generation) throws {
        try execute("BEGIN IMMEDIATE")
        var didCommit = false
        defer { if !didCommit { try? execute("ROLLBACK") } }
        guard let current = try readGeneration(0), current.id == head.id,
              current.lineage == head.lineage else { throw failure("初始化期间存档已被更新") }
        try updateIndependentBackup(from: current)
        var aligned = current
        aligned.lineage = lineage
        try putGeneration(aligned, slot: 0)
        try execute("COMMIT")
        didCommit = true
    }

    private func normalizeLoaded(_ snapshot: inout ConversationSnapshot) {
        if isReplica { coldStartRemovals = []; return }
        let before = Set(snapshot.messagesByConversation.values.joined().map(\.id))
        _ = legacy.normalizeAfterColdStart(&snapshot)
        coldStartRemovals = before.subtracting(snapshot.messagesByConversation.values.joined().map(\.id))
    }

    private func mayRecover(_ error: Error) -> Bool {
        if case ConversationStoreError.invalidSnapshotStructure = error { return true }
        return error is DecodingError
    }

    func save(_ snapshot: ConversationSnapshot, authorizedReduction: Bool) throws {
        if !didLoad { _ = try load() }
        if replacementRequired, let recovered = committed {
            if let connection { sqlite3_close(connection); self.connection = nil }
            let source = directory.appendingPathComponent("conversations_records.sqlite")
            let rejected = directory.appendingPathComponent("conversations_records.rejected.sqlite")
            if fileManager.fileExists(atPath: source.path) {
                if fileManager.fileExists(atPath: rejected.path) { try fileManager.removeItem(at: rejected) }
                try fileManager.moveItem(at: source, to: rejected)
            }
            // SQLite is closed; any remaining rollback journal belongs to the
            // rejected database, never to the new file.
            let journal = directory.appendingPathComponent("conversations_records.sqlite-journal")
            if fileManager.fileExists(atPath: journal.path) {
                let rejectedJournal = directory.appendingPathComponent("conversations_records.rejected.sqlite-journal")
                if fileManager.fileExists(atPath: rejectedJournal.path) { try fileManager.removeItem(at: rejectedJournal) }
                try fileManager.moveItem(at: journal, to: rejectedJournal)
            }
            committed = nil; generation = 0; lineage = UUID()
            try write(recovered, authorizedReduction: true, importing: true)
            replacementRequired = false
            var normalized = recovered
            normalizeLoaded(&normalized)
        }
        try write(snapshot, authorizedReduction: authorizedReduction, importing: false)
    }

    private func write(_ input: ConversationSnapshot, authorizedReduction: Bool, importing: Bool) throws {
        #if DEBUG
        let stageStart = CFAbsoluteTimeGetCurrent()
        #endif
        try open()
        var snapshot = input
        if !isReplica { snapshot.updatedAt = .now }
        snapshot.destructiveReductionAuthorized = authorizedReduction ? true : nil
        if committed == nil || importing {
            try LegacyConversationStore.validateSnapshotStructure(snapshot)
        }
        #if DEBUG
        let validationEnd = CFAbsoluteTimeGetCurrent()
        #endif
        var changes: [(String, Data?)]
        do {
            let oldConversations = Dictionary(uniqueKeysWithValues: (committed?.conversations ?? []).map { ($0.id, $0) })
            let newLayout = Layout(snapshot)
            let oldLayout = committed.map(Layout.init)
            let oldConversationIDs = Set(oldConversations.keys)
            let newConversationIDs = Set(newLayout.conversations)
            let oldMessageIDs = Set(oldLayout?.messages.values.joined().map { $0 } ?? [])
            let newMessageIDs = Set(newLayout.messages.values.joined())
            // Validate topology while deriving the same identities needed by
            // the diff. Unchanged values came from a fully validated commit;
            // changed values are checked below before encoding.
            guard newConversationIDs.count == snapshot.conversations.count,
                  Set(newLayout.messages.keys).isSubset(of: newConversationIDs),
                  newMessageIDs.count == newLayout.messages.values.reduce(0, { $0 + $1.count }) else {
                throw failure("重复身份或不属于任何会话的消息分组")
            }
            let schema = max(snapshot.schemaVersion, snapshot.conversations.map(\.schemaVersion).max() ?? 0)
            guard schema <= ConversationStore.currentSchemaVersion else {
                throw ConversationStoreError.unsupportedSchemaVersion(schema)
            }
            if !authorizedReduction,
               (!oldConversationIDs.isSubset(of: newConversationIDs)
                || !oldMessageIDs.subtracting(coldStartRemovals).isSubset(of: newMessageIDs)) {
                throw failure("拒绝未授权的聊天或消息减少")
            }
            changes = []
            if oldLayout != newLayout {
                changes.append(("layout", try encoder.encode(newLayout)))
            }
            for conversation in snapshot.conversations where oldConversations[conversation.id] != conversation {
                changes.append(("c:\(conversation.id)", try encoder.encode(conversation)))
            }
            for (conversationID, messages) in snapshot.messagesByConversation {
                let prior = committed?.messagesByConversation[conversationID] ?? []
                // Identical live buffers prove these value-type rows are still
                // the committed rows. A mutation detaches Swift Array storage;
                // distinct buffers still take the full comparison below. Keep
                // this after the global identity/deletion checks, and never
                // retain pointers or compare entire arrays as a preflight.
                if messages.count == prior.count,
                   messages.withUnsafeBufferPointer({ current in
                       prior.withUnsafeBufferPointer { previous in
                           current.baseAddress == previous.baseAddress
                       }
                   }) {
                    continue
                }
                if oldLayout?.messages[conversationID] == newLayout.messages[conversationID] {
                    // Stable order is the common streaming/edit path. Compare
                    // the actual values directly instead of constructing two
                    // global dictionaries containing every large ChatMessage.
                    for index in messages.indices where prior[index] != messages[index] {
                        let message = messages[index]
                        changes.append(("m:\(message.id)", try encodeChangedMessage(message, conversationID: conversationID)))
                    }
                } else {
                    // Insert/delete/reorder needs only a lightweight ID->index
                    // map for this conversation, not copies of all messages.
                    let positions = Dictionary(uniqueKeysWithValues: prior.enumerated().map { ($0.element.id, $0.offset) })
                    for message in messages {
                        if let index = positions[message.id], prior[index] == message { continue }
                        changes.append(("m:\(message.id)", try encodeChangedMessage(message, conversationID: conversationID)))
                    }
                }
            }
            for id in oldConversationIDs.subtracting(newConversationIDs) { changes.append(("c:\(id)", nil)) }
            for id in oldMessageIDs.subtracting(newMessageIDs) { changes.append(("m:\(id)", nil)) }
        }
        lastChangedRecordCount = changes.count
        lastEncodedByteCount = changes.reduce(0) { $0 + ($1.1?.count ?? 0) }

        #if DEBUG
        let diffEnd = CFAbsoluteTimeGetCurrent()
        #endif
        // Seed is durably verified before the first new-format mutation. A v1
        // reader sees schema 2 and refuses downgrade instead of loading stale
        // migration data and overwriting newer chats.
        if !importing, !isReplica { try installLegacyGuard() }
        try execute("BEGIN IMMEDIATE")
        var committedTransaction = false
        defer { if !committedTransaction { try? execute("ROLLBACK") } }
        let currentHead = try readGeneration(0)
        guard (currentHead?.id ?? 0) == generation,
              currentHead?.lineage == nil || currentHead?.lineage == lineage else {
            throw failure("存档已被另一实例更新，请重新载入")
        }
        #if DEBUG
        let replicaStart = CFAbsoluteTimeGetCurrent()
        #endif
        if !importing, !isReplica, let currentHead {
            // The primary lock and generation check precede backup changes.
            // Read only records changed since the backup's durable generation.
            try updateIndependentBackup(from: currentHead)
        }
        #if DEBUG
        let replicaEnd = CFAbsoluteTimeGetCurrent()
        #endif
        let nextGeneration = generation + 1
        // Retire 4978's redundant in-file history only after the independent
        // backup is durable. Keep its nullable columns for 4978 compatibility.
        try execute("DELETE FROM records WHERE value IS NULL; UPDATE records SET prior=NULL,prior_hash=NULL WHERE prior IS NOT NULL;")
        try execute("DELETE FROM generations WHERE slot=1;")
        try put(changes, generation: nextGeneration)
        try putGeneration(Generation(id: nextGeneration, createdAt: snapshot.createdAt,
                                     updatedAt: snapshot.updatedAt,
                                     destructiveReductionAuthorized: snapshot.destructiveReductionAuthorized,
                                     lineage: lineage), slot: 0)
        #if DEBUG
        if failBeforeCommitForTesting { throw failure("模拟提交前失败") }
        #endif
        try execute("COMMIT")
        committedTransaction = true
        committed = snapshot; generation = nextGeneration; didLoad = true
        coldStartRemovals = []
        #if DEBUG
        lastStageTimings = ["validation": (validationEnd - stageStart) * 1000,
                            "diff": (diffEnd - validationEnd) * 1000,
                            "prepare": (replicaStart - diffEnd) * 1000,
                            "replica": (replicaEnd - replicaStart) * 1000,
                            "commit": (CFAbsoluteTimeGetCurrent() - replicaEnd) * 1000]
        #endif
    }

    private func updateIndependentBackup(from head: Generation) throws {
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        lastReplicaRecordCount = 0
        lastReplicaStageTimings = [:]
        #endif
        let backup = try previousStore()
        try backup.open()
        try backup.execute("BEGIN IMMEDIATE")
        var didCommit = false
        defer { if !didCommit { try? backup.execute("ROLLBACK") } }
        let previous = try backup.readGeneration(0)
        let sameLineage = head.lineage != nil && previous?.lineage == head.lineage
        if sameLineage, let previous, previous.id > head.id {
            throw failure("备份比主存档更新，拒绝覆盖")
        }
        if sameLineage, previous?.id == head.id {
            // A preceding attempt may have committed the backup, then failed
            // before committing the primary. Its backup is already correct.
            try backup.execute("COMMIT")
            didCommit = true
            return
        }
        let incremental = sameLineage && previous?.id == head.id - 1
        if !incremental {
            // First migration, a missing backup, or a rebuilt primary needs one
            // full seed. Copy encoded rows directly; do not decode chat bodies.
            try backup.execute("DELETE FROM records; DELETE FROM generations;")
        }
        let query = try statement(incremental
            ? "SELECT key,value,hash,generation FROM records WHERE generation>\(previous!.id)"
            : "SELECT key,value,hash,generation FROM records WHERE value IS NOT NULL")
        defer { sqlite3_finalize(query) }
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            try check(code)
            guard let rawKey = sqlite3_column_text(query, 0),
                  sqlite3_column_int64(query, 3) <= head.id else {
                throw failure("备份来源记录无效")
            }
            let bytes = data(query, 1)
            guard bytes.map(digest) == data(query, 2) else { throw failure("备份来源记录校验失败") }
            try backup.put([(String(cString: rawKey), bytes)], generation: head.id)
            #if DEBUG
            lastReplicaRecordCount += 1
            #endif
        }
        var aligned = head
        aligned.lineage = lineage
        try backup.putGeneration(aligned, slot: 0)
        try backup.execute("COMMIT")
        didCommit = true
        #if DEBUG
        lastReplicaStageTimings = ["total": (CFAbsoluteTimeGetCurrent() - started) * 1000]
        #endif
    }

    private func encodeChangedMessage(_ message: ChatMessage, conversationID: UUID) throws -> Data {
        guard message.conversationID == conversationID else { throw failure("消息所属会话与分组不一致") }
        guard message.schemaVersion <= ConversationStore.currentSchemaVersion else {
            throw ConversationStoreError.unsupportedSchemaVersion(message.schemaVersion)
        }
        return try encoder.encode(message)
    }

    private func put(_ changes: [(String, Data?)], generation: Int64) throws {
        let query = try statement("""
            INSERT INTO records(key,value,hash,generation) VALUES(?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value,hash=excluded.hash,generation=excluded.generation
            """)
        let deletion = try statement("DELETE FROM records WHERE key=?")
        defer { sqlite3_finalize(query); sqlite3_finalize(deletion) }
        for (key, bytes) in changes {
            if bytes == nil && isReplica {
                sqlite3_reset(deletion); sqlite3_clear_bindings(deletion)
                try bind(key, to: deletion, at: 1)
                try check(sqlite3_step(deletion))
                continue
            }
            sqlite3_reset(query); sqlite3_clear_bindings(query)
            try bind(key, to: query, at: 1)
            try bind(bytes, to: query, at: 2)
            try bind(bytes.map(digest), to: query, at: 3)
            try check(sqlite3_bind_int64(query, 4, generation))
            try check(sqlite3_step(query))
        }
    }
    private func installLegacyGuard() throws {
        let url = directory.appendingPathComponent("conversations_v1.json")
        let marker = Data("{\"schemaVersion\":2,\"storage\":\"conversations_records.sqlite\"}".utf8)
        // After initial installation do not read, hash or rewrite the legacy
        // file on every save. Ownership is checked by the database generation.
        if legacyGuardInstalled { return }
        if !hasReusableLegacyGuard(at: url, marker: marker) {
            try marker.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            guard try Data(contentsOf: url) == marker else { throw failure("旧版本保护写入失败") }
        }
        legacyGuardInstalled = true
    }
    private func hasReusableLegacyGuard(at url: URL, marker: Data) -> Bool {
        // Reuse only the exact, protected regular file. Bound the read even if
        // this path still contains a large legacy archive or changes size.
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.size] as? NSNumber == NSNumber(value: marker.count),
                  attributes[.protectionKey] as? FileProtectionType == .completeUnlessOpen else { return false }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            return try file.read(upToCount: marker.count + 1) == marker
        } catch {
            // A failed check must still take the original authoritative write
            // path; its error prevents the primary transaction from advancing.
            return false
        }
    }
    private var legacyGuardInstalled = false
}
