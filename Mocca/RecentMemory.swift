import Foundation

enum RecentMemoryCadence: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case afterConversation
    case daily
    case threeDays
    case weekly
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .afterConversation: "每次聊天后"
        case .daily: "每天"
        case .threeDays: "每 3 天"
        case .weekly: "每周"
        case .manual: "仅手动"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .afterConversation, .manual: nil
        case .daily: 24 * 60 * 60
        case .threeDays: 3 * 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }

    func nextDate(
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let dayCount: Int
        switch self {
        case .afterConversation, .manual:
            return nil
        case .daily:
            dayCount = 1
        case .threeDays:
            dayCount = 3
        case .weekly:
            dayCount = 7
        }
        return calendar.date(byAdding: .day, value: dayCount, to: date)
            ?? interval.map { date.addingTimeInterval($0) }
    }
}

enum RecentMemoryBudgetPreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case light
    case balanced
    case deep
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "轻量"
        case .balanced: "均衡"
        case .deep: "深入"
        case .custom: "自定义"
        }
    }
}

enum RecentMemorySourceSelectionMode:
    String,
    Codable,
    CaseIterable,
    Identifiable,
    Hashable,
    Sendable
{
    case conversationCount
    case recentDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversationCount: "按聊天数量"
        case .recentDays: "按最近天数"
        }
    }
}

struct RecentMemorySettings: Codable, Hashable, Sendable {
    static let defaultCandidateConversationLimit = 30
    static let defaultCandidateRecentDayCount = 3
    static let defaultConversationSummaryTokenLimit = 400
    static let defaultMemoryTokenLimit = 1_200
    static let defaultOrganizerInputTokenLimit = 12_000
    static let defaultRetrievedHistoryTokenLimit = 1_500
    static let defaultTotalPromptTokenLimit = 4_000

    var isEnabled: Bool
    var isPaused: Bool
    var isAutomaticConversationSummaryEnabled: Bool
    var cadence: RecentMemoryCadence
    var sourceSelectionMode: RecentMemorySourceSelectionMode
    var candidateConversationLimit: Int
    var candidateRecentDayCount: Int
    var conversationSummaryTokenLimit: Int
    var memoryTokenLimit: Int
    var organizerInputTokenLimit: Int
    var retrievedHistoryTokenLimit: Int
    // Retained for decoding and re-encoding existing assistant profiles.
    // Since build 4591, chat injection budgets recent memory independently
    // through `memoryTokenLimit` and always includes long-term memory in full.
    var totalPromptTokenLimit: Int
    var budgetPreset: RecentMemoryBudgetPreset
    var organizerModel: ModelSelection?
    var excludedConversationIDs: Set<UUID>
    var customInstruction: String

    init(
        isEnabled: Bool = false,
        isPaused: Bool = false,
        isAutomaticConversationSummaryEnabled: Bool = false,
        cadence: RecentMemoryCadence = .threeDays,
        sourceSelectionMode: RecentMemorySourceSelectionMode = .conversationCount,
        candidateConversationLimit: Int = Self.defaultCandidateConversationLimit,
        candidateRecentDayCount: Int = Self.defaultCandidateRecentDayCount,
        conversationSummaryTokenLimit: Int = Self.defaultConversationSummaryTokenLimit,
        memoryTokenLimit: Int = Self.defaultMemoryTokenLimit,
        organizerInputTokenLimit: Int = Self.defaultOrganizerInputTokenLimit,
        retrievedHistoryTokenLimit: Int = Self.defaultRetrievedHistoryTokenLimit,
        totalPromptTokenLimit: Int = Self.defaultTotalPromptTokenLimit,
        budgetPreset: RecentMemoryBudgetPreset = .balanced,
        organizerModel: ModelSelection? = nil,
        excludedConversationIDs: Set<UUID> = [],
        customInstruction: String = ""
    ) {
        self.isEnabled = isEnabled
        self.isPaused = isPaused
        self.isAutomaticConversationSummaryEnabled =
            isAutomaticConversationSummaryEnabled
        self.cadence = cadence
        self.sourceSelectionMode = sourceSelectionMode
        self.candidateConversationLimit = Self.clampCandidateConversationLimit(
            candidateConversationLimit
        )
        self.candidateRecentDayCount = Self.clampCandidateRecentDayCount(
            candidateRecentDayCount
        )
        self.conversationSummaryTokenLimit = Self.clampConversationSummaryTokenLimit(
            conversationSummaryTokenLimit
        )
        self.memoryTokenLimit = Self.clampMemoryTokenLimit(memoryTokenLimit)
        self.organizerInputTokenLimit = Self.clampOrganizerInputTokenLimit(
            organizerInputTokenLimit
        )
        self.retrievedHistoryTokenLimit = Self.clampRetrievedHistoryTokenLimit(
            retrievedHistoryTokenLimit
        )
        self.totalPromptTokenLimit = Self.clampTotalPromptTokenLimit(
            totalPromptTokenLimit
        )
        self.budgetPreset = budgetPreset
        self.organizerModel = organizerModel
        self.excludedConversationIDs = excludedConversationIDs
        self.customInstruction = customInstruction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.decodeIfValid(Bool.self, forKey: .isEnabled) ?? false
        isPaused = container.decodeIfValid(Bool.self, forKey: .isPaused) ?? false
        isAutomaticConversationSummaryEnabled = container.decodeIfValid(
            Bool.self,
            forKey: .isAutomaticConversationSummaryEnabled
        ) ?? false
        cadence = container.decodeIfValid(RecentMemoryCadence.self, forKey: .cadence)
            ?? .threeDays
        sourceSelectionMode = container.decodeIfValid(
            RecentMemorySourceSelectionMode.self,
            forKey: .sourceSelectionMode
        ) ?? .conversationCount
        candidateConversationLimit = Self.clampCandidateConversationLimit(
            container.decodeIfValid(Int.self, forKey: .candidateConversationLimit)
                ?? Self.defaultCandidateConversationLimit
        )
        candidateRecentDayCount = Self.clampCandidateRecentDayCount(
            container.decodeIfValid(Int.self, forKey: .candidateRecentDayCount)
                ?? Self.defaultCandidateRecentDayCount
        )
        conversationSummaryTokenLimit = Self.clampConversationSummaryTokenLimit(
            container.decodeIfValid(Int.self, forKey: .conversationSummaryTokenLimit)
                ?? Self.defaultConversationSummaryTokenLimit
        )
        memoryTokenLimit = Self.clampMemoryTokenLimit(
            container.decodeIfValid(Int.self, forKey: .memoryTokenLimit)
                ?? Self.defaultMemoryTokenLimit
        )
        organizerInputTokenLimit = Self.clampOrganizerInputTokenLimit(
            container.decodeIfValid(Int.self, forKey: .organizerInputTokenLimit)
                ?? Self.defaultOrganizerInputTokenLimit
        )
        retrievedHistoryTokenLimit = Self.clampRetrievedHistoryTokenLimit(
            container.decodeIfValid(Int.self, forKey: .retrievedHistoryTokenLimit)
                ?? Self.defaultRetrievedHistoryTokenLimit
        )
        totalPromptTokenLimit = Self.clampTotalPromptTokenLimit(
            container.decodeIfValid(Int.self, forKey: .totalPromptTokenLimit)
                ?? Self.defaultTotalPromptTokenLimit
        )
        budgetPreset = container.decodeIfValid(
            RecentMemoryBudgetPreset.self,
            forKey: .budgetPreset
        ) ?? .balanced
        organizerModel = container.decodeIfValid(ModelSelection.self, forKey: .organizerModel)
        excludedConversationIDs = Set(
            container.decodeLossyArray(UUID.self, forKey: .excludedConversationIDs)
        )
        customInstruction = container.decodeIfValid(String.self, forKey: .customInstruction) ?? ""
    }

    mutating func applyPreset(_ preset: RecentMemoryBudgetPreset) {
        budgetPreset = preset
        switch preset {
        case .light:
            conversationSummaryTokenLimit = 250
            memoryTokenLimit = 700
            organizerInputTokenLimit = 6_000
            retrievedHistoryTokenLimit = 800
            totalPromptTokenLimit = 2_500
        case .balanced:
            conversationSummaryTokenLimit = Self.defaultConversationSummaryTokenLimit
            memoryTokenLimit = Self.defaultMemoryTokenLimit
            organizerInputTokenLimit = Self.defaultOrganizerInputTokenLimit
            retrievedHistoryTokenLimit = Self.defaultRetrievedHistoryTokenLimit
            totalPromptTokenLimit = Self.defaultTotalPromptTokenLimit
        case .deep:
            conversationSummaryTokenLimit = 700
            memoryTokenLimit = 2_200
            organizerInputTokenLimit = 24_000
            retrievedHistoryTokenLimit = 3_000
            totalPromptTokenLimit = 8_000
        case .custom:
            break
        }
    }

    private static func clampCandidateConversationLimit(_ value: Int) -> Int {
        min(max(value, 5), 100)
    }

    private static func clampCandidateRecentDayCount(_ value: Int) -> Int {
        min(max(value, 1), 30)
    }

    func includesCandidateConversation(
        updatedAt: Date,
        relativeTo now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard sourceSelectionMode == .recentDays else { return true }
        let fallbackCutoff = now.addingTimeInterval(
            -TimeInterval(candidateRecentDayCount) * 24 * 60 * 60
        )
        let cutoff = calendar.date(
            byAdding: .day,
            value: -candidateRecentDayCount,
            to: now
        ) ?? fallbackCutoff
        return updatedAt >= cutoff
    }

    private static func clampConversationSummaryTokenLimit(_ value: Int) -> Int {
        min(max(value, 100), 800)
    }

    private static func clampMemoryTokenLimit(_ value: Int) -> Int {
        min(max(value, 300), 6_000)
    }

    private static func clampOrganizerInputTokenLimit(_ value: Int) -> Int {
        min(max(value, 2_000), 96_000)
    }

    private static func clampRetrievedHistoryTokenLimit(_ value: Int) -> Int {
        min(max(value, 0), 8_000)
    }

    private static func clampTotalPromptTokenLimit(_ value: Int) -> Int {
        min(max(value, 1_000), 16_000)
    }
}

struct RecentMemorySettingsChangePlan: Equatable, Sendable {
    var hasChanges: Bool
    var shouldDeferOrganizerRefresh: Bool
    var shouldReconcileSourceScope: Bool
    var shouldRescheduleCadence: Bool
    var shouldCancelConversationSummaries: Bool

    static func make(
        previous: RecentMemorySettings?,
        current: RecentMemorySettings
    ) -> Self {
        guard let previous else {
            return Self(
                hasChanges: true,
                shouldDeferOrganizerRefresh: false,
                shouldReconcileSourceScope: false,
                shouldRescheduleCadence:
                    current.isEnabled && !current.isPaused,
                shouldCancelConversationSummaries:
                    !current.isEnabled
                        || current.isPaused
                        || !current.isAutomaticConversationSummaryEnabled
            )
        }

        let hasChanges = previous != current
        let sourceScopeChanged =
            previous.excludedConversationIDs != current.excludedConversationIDs
                || previous.sourceSelectionMode != current.sourceSelectionMode
                || previous.candidateConversationLimit
                    != current.candidateConversationLimit
                || previous.candidateRecentDayCount
                    != current.candidateRecentDayCount
        let sourceEvidenceChanged =
            previous.conversationSummaryTokenLimit
                != current.conversationSummaryTokenLimit
        let organizerBehaviorChanged =
            previous.memoryTokenLimit != current.memoryTokenLimit
                || previous.organizerInputTokenLimit
                    != current.organizerInputTokenLimit
                || previous.retrievedHistoryTokenLimit
                    != current.retrievedHistoryTokenLimit
                || previous.organizerModel != current.organizerModel
                || previous.customInstruction != current.customInstruction
        let becameActive =
            current.isEnabled && !current.isPaused
                && (!previous.isEnabled || previous.isPaused)

        return Self(
            hasChanges: hasChanges,
            shouldDeferOrganizerRefresh:
                current.isEnabled
                    && (sourceScopeChanged
                        || sourceEvidenceChanged
                        || organizerBehaviorChanged),
            shouldReconcileSourceScope:
                current.isEnabled && sourceScopeChanged,
            shouldRescheduleCadence:
                current.isEnabled && !current.isPaused
                    && (previous.cadence != current.cadence || becameActive),
            shouldCancelConversationSummaries:
                sourceEvidenceChanged
                    || previous.excludedConversationIDs
                        != current.excludedConversationIDs
                    || !current.isEnabled
                    || current.isPaused
                    || !current.isAutomaticConversationSummaryEnabled
        )
    }
}

enum RecentMemoryOrganizerContract {
    static let currentVersion = 5

    static func requiresFullRegeneration(_ state: RecentMemoryState) -> Bool {
        guard state.organizerContractVersion == currentVersion,
              !state.needsFullRegeneration else {
            return true
        }

        switch state.contentOrigin {
        case .legacyUnverified:
            return true
        case .userEdited:
            return !state.entries.isEmpty
                || !state.sources.isEmpty
                || !state.processedSourceRevisions.isEmpty
        case .organizerGrounded:
            break
        }

        let sourceIDs = Set(state.sources.map(\.conversationID))
        let processedSourcesAreValid =
            state.processedSourceRevisions.keys.allSatisfy { rawID in
                guard let sourceID = UUID(uuidString: rawID) else {
                    return false
                }
                return sourceIDs.contains(sourceID)
            }
        guard processedSourcesAreValid else { return true }

        let content = state.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if state.entries.isEmpty {
            // A successful grounded organizer run may persist an empty result,
            // but then its materialized content must be empty. A trusted
            // hand edit was handled by the explicit `.userEdited` branch
            // above. Never infer authorship from free-form model text.
            if !content.isEmpty {
                return true
            }
            return false
        }

        // Structured organizer output must have a locally materialized body
        // and remain fully grounded in its persisted source set.
        guard !content.isEmpty, !sourceIDs.isEmpty else { return true }
        guard state.entries.allSatisfy({ entry in
            !entry.sourceConversationIDs.isEmpty
                && entry.sourceConversationIDs.allSatisfy(sourceIDs.contains)
        }) else {
            return true
        }
        return false
    }

    static func requiresContractMigration(_ state: RecentMemoryState) -> Bool {
        state.organizerContractVersion != currentVersion
    }
}

enum RecentMemoryContentOrigin: String, Codable, Hashable, Sendable {
    case organizerGrounded
    case userEdited
    case legacyUnverified
}

enum RecentMemoryEntryCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case activeProject
    case openLoop
    case recentEvent
    case temporary
    case relationship
    case longTermCandidate
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeProject: "进行中的项目"
        case .openLoop: "待继续事项"
        case .recentEvent: "近期事件"
        case .temporary: "临时信息"
        case .relationship: "人物与关系"
        case .longTermCandidate: "长期记忆候选"
        case .other: "其他"
        }
    }
}

struct RecentMemoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var category: RecentMemoryEntryCategory
    var content: String
    var sourceConversationIDs: [UUID]
    var expiresAt: Date?
    var isLongTermCandidate: Bool

    init(
        id: UUID = UUID(),
        category: RecentMemoryEntryCategory = .other,
        content: String = "",
        sourceConversationIDs: [UUID] = [],
        expiresAt: Date? = nil,
        isLongTermCandidate: Bool = false
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.sourceConversationIDs = Self.unique(sourceConversationIDs)
        self.expiresAt = expiresAt
        self.isLongTermCandidate = isLongTermCandidate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeIfValid(UUID.self, forKey: .id) ?? UUID()
        category = container.decodeIfValid(
            RecentMemoryEntryCategory.self,
            forKey: .category
        ) ?? .other
        content = container.decodeIfValid(String.self, forKey: .content) ?? ""
        sourceConversationIDs = Self.unique(
            container.decodeLossyArray(UUID.self, forKey: .sourceConversationIDs)
        )
        expiresAt = container.decodeIfValid(Date.self, forKey: .expiresAt)
        isLongTermCandidate = container.decodeIfValid(
            Bool.self,
            forKey: .isLongTermCandidate
        ) ?? (category == .longTermCandidate)
    }

    private static func unique(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct RecentMemorySource: Codable, Identifiable, Hashable, Sendable {
    var conversationID: UUID
    var title: String
    var summaryFingerprint: String
    var lastSummarizedMessageCount: Int
    var updatedAt: Date

    var id: UUID { conversationID }

    init(
        conversationID: UUID = UUID(),
        title: String = "",
        summaryFingerprint: String = "",
        lastSummarizedMessageCount: Int = 0,
        updatedAt: Date = .distantPast
    ) {
        self.conversationID = conversationID
        self.title = title
        self.summaryFingerprint = summaryFingerprint
        self.lastSummarizedMessageCount = max(0, lastSummarizedMessageCount)
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = container.decodeIfValid(UUID.self, forKey: .conversationID) ?? UUID()
        title = container.decodeIfValid(String.self, forKey: .title) ?? ""
        summaryFingerprint = container.decodeIfValid(
            String.self,
            forKey: .summaryFingerprint
        ) ?? ""
        lastSummarizedMessageCount = max(
            0,
            container.decodeIfValid(Int.self, forKey: .lastSummarizedMessageCount) ?? 0
        )
        updatedAt = container.decodeIfValid(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

enum RecentMemoryLiveSourceRevisionGate {
    static func matches(
        storedSource: RecentMemorySource,
        processedRevision: String?,
        liveRevision: String?,
        liveMessageCount: Int?
    ) -> Bool {
        let storedRevision = storedSource.summaryFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storedRevision.isEmpty else { return false }
        return processedRevision == storedRevision
            && liveRevision == storedRevision
            && liveMessageCount == storedSource.lastSummarizedMessageCount
    }
}

struct RecentMemoryVersion: Codable, Hashable, Sendable {
    var content: String
    var contentOrigin: RecentMemoryContentOrigin
    var pendingLegacySnapshot: String?
    var entries: [RecentMemoryEntry]
    var sources: [RecentMemorySource]
    var processedSourceRevisions: [String: String]
    var changeLog: [String]
    var updatedAt: Date?
    var revision: Int
    var organizerContractVersion: Int
    var needsFullRegeneration: Bool
    var needsDeferredRegeneration: Bool
    var stableContextFingerprint: String?

    init(
        content: String = "",
        contentOrigin: RecentMemoryContentOrigin = .organizerGrounded,
        pendingLegacySnapshot: String? = nil,
        entries: [RecentMemoryEntry] = [],
        sources: [RecentMemorySource] = [],
        processedSourceRevisions: [String: String] = [:],
        changeLog: [String] = [],
        updatedAt: Date? = nil,
        revision: Int = 0,
        organizerContractVersion: Int = RecentMemoryOrganizerContract.currentVersion,
        needsFullRegeneration: Bool = false,
        needsDeferredRegeneration: Bool = false,
        stableContextFingerprint: String? = nil
    ) {
        self.content = content
        self.contentOrigin = contentOrigin
        self.pendingLegacySnapshot = Self.validPendingLegacySnapshot(
            pendingLegacySnapshot
        )
        self.entries = entries
        self.sources = Self.uniqueSources(sources)
        self.processedSourceRevisions = Self.validRevisions(processedSourceRevisions)
        self.changeLog = changeLog
        self.updatedAt = updatedAt
        self.revision = max(0, revision)
        self.organizerContractVersion = max(0, organizerContractVersion)
        self.needsFullRegeneration = needsFullRegeneration
        self.needsDeferredRegeneration = needsDeferredRegeneration
        self.stableContextFingerprint = Self.validFingerprint(
            stableContextFingerprint
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = container.decodeIfValid(String.self, forKey: .content) ?? ""
        // States written before contract v5 have no app-authored provenance
        // marker. They must remain untrusted until migrated or explicitly
        // confirmed by the user.
        contentOrigin = container.decodeIfValid(
            RecentMemoryContentOrigin.self,
            forKey: .contentOrigin
        ) ?? .legacyUnverified
        pendingLegacySnapshot = Self.validPendingLegacySnapshot(
            container.decodeIfValid(
                String.self,
                forKey: .pendingLegacySnapshot
            )
        )
        entries = container.decodeLossyArray(RecentMemoryEntry.self, forKey: .entries)
        sources = Self.uniqueSources(
            container.decodeLossyArray(RecentMemorySource.self, forKey: .sources)
        )
        processedSourceRevisions = Self.validRevisions(
            container.decodeIfValid(
                [String: String].self,
                forKey: .processedSourceRevisions
            ) ?? [:]
        )
        changeLog = container.decodeLossyArray(String.self, forKey: .changeLog)
        updatedAt = container.decodeIfValid(Date.self, forKey: .updatedAt)
        revision = max(0, container.decodeIfValid(Int.self, forKey: .revision) ?? 0)
        organizerContractVersion = max(
            0,
            container.decodeIfValid(Int.self, forKey: .organizerContractVersion) ?? 0
        )
        needsFullRegeneration =
            container.decodeIfValid(Bool.self, forKey: .needsFullRegeneration) ?? false
        needsDeferredRegeneration =
            container.decodeIfValid(
                Bool.self,
                forKey: .needsDeferredRegeneration
            ) ?? false
        stableContextFingerprint = Self.validFingerprint(
            container.decodeIfValid(String.self, forKey: .stableContextFingerprint)
        )
    }

    fileprivate static func validRevisions(_ revisions: [String: String]) -> [String: String] {
        revisions.reduce(into: [:]) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: key) != nil, !value.isEmpty else { return }
            result[key] = value
        }
    }

    fileprivate static func validFingerprint(_ value: String?) -> String? {
        guard let cleaned = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    fileprivate static func validPendingLegacySnapshot(
        _ value: String?
    ) -> String? {
        guard let value,
              !value.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return nil
        }
        return value
    }

    fileprivate static func uniqueSources(
        _ sources: [RecentMemorySource]
    ) -> [RecentMemorySource] {
        var result: [RecentMemorySource] = []
        var indexByConversationID: [UUID: Int] = [:]
        for source in sources {
            if let index = indexByConversationID[source.conversationID] {
                if source.updatedAt > result[index].updatedAt {
                    result[index] = source
                }
            } else {
                indexByConversationID[source.conversationID] = result.count
                result.append(source)
            }
        }
        return result
    }
}

struct RecentMemoryState: Codable, Hashable, Sendable {
    var content: String
    var contentOrigin: RecentMemoryContentOrigin
    var pendingLegacySnapshot: String?
    var entries: [RecentMemoryEntry]
    var sources: [RecentMemorySource]
    var processedSourceRevisions: [String: String]
    var changeLog: [String]
    var updatedAt: Date?
    var nextRefreshAt: Date?
    var lastAttemptAt: Date?
    var lastError: String?
    var previousVersion: RecentMemoryVersion?
    var revision: Int
    var organizerContractVersion: Int
    var needsFullRegeneration: Bool
    var needsDeferredRegeneration: Bool
    var deferredRegenerationAcknowledgedRevision: Int?
    var stableContextFingerprint: String?

    init(
        content: String = "",
        contentOrigin: RecentMemoryContentOrigin = .organizerGrounded,
        pendingLegacySnapshot: String? = nil,
        entries: [RecentMemoryEntry] = [],
        sources: [RecentMemorySource] = [],
        processedSourceRevisions: [String: String] = [:],
        changeLog: [String] = [],
        updatedAt: Date? = nil,
        nextRefreshAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        previousVersion: RecentMemoryVersion? = nil,
        revision: Int = 0,
        organizerContractVersion: Int = RecentMemoryOrganizerContract.currentVersion,
        needsFullRegeneration: Bool = false,
        needsDeferredRegeneration: Bool = false,
        deferredRegenerationAcknowledgedRevision: Int? = nil,
        stableContextFingerprint: String? = nil
    ) {
        self.content = content
        self.contentOrigin = contentOrigin
        self.pendingLegacySnapshot =
            RecentMemoryVersion.validPendingLegacySnapshot(
                pendingLegacySnapshot
            )
        self.entries = entries
        self.sources = RecentMemoryVersion.uniqueSources(sources)
        self.processedSourceRevisions = RecentMemoryVersion.validRevisions(
            processedSourceRevisions
        )
        self.changeLog = changeLog
        self.updatedAt = updatedAt
        self.nextRefreshAt = nextRefreshAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.previousVersion = previousVersion
        self.revision = max(0, revision)
        self.organizerContractVersion = max(0, organizerContractVersion)
        self.needsFullRegeneration = needsFullRegeneration
        self.needsDeferredRegeneration = needsDeferredRegeneration
        self.deferredRegenerationAcknowledgedRevision =
            deferredRegenerationAcknowledgedRevision.map { max(0, $0) }
        self.stableContextFingerprint = RecentMemoryVersion.validFingerprint(
            stableContextFingerprint
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = container.decodeIfValid(String.self, forKey: .content) ?? ""
        contentOrigin = container.decodeIfValid(
            RecentMemoryContentOrigin.self,
            forKey: .contentOrigin
        ) ?? .legacyUnverified
        pendingLegacySnapshot =
            RecentMemoryVersion.validPendingLegacySnapshot(
                container.decodeIfValid(
                    String.self,
                    forKey: .pendingLegacySnapshot
                )
            )
        entries = container.decodeLossyArray(RecentMemoryEntry.self, forKey: .entries)
        sources = RecentMemoryVersion.uniqueSources(
            container.decodeLossyArray(RecentMemorySource.self, forKey: .sources)
        )
        processedSourceRevisions = RecentMemoryVersion.validRevisions(
            container.decodeIfValid(
                [String: String].self,
                forKey: .processedSourceRevisions
            ) ?? [:]
        )
        changeLog = container.decodeLossyArray(String.self, forKey: .changeLog)
        updatedAt = container.decodeIfValid(Date.self, forKey: .updatedAt)
        nextRefreshAt = container.decodeIfValid(Date.self, forKey: .nextRefreshAt)
        lastAttemptAt = container.decodeIfValid(Date.self, forKey: .lastAttemptAt)
        lastError = container.decodeIfValid(String.self, forKey: .lastError)
        previousVersion = container.decodeIfValid(
            RecentMemoryVersion.self,
            forKey: .previousVersion
        )
        revision = max(0, container.decodeIfValid(Int.self, forKey: .revision) ?? 0)
        organizerContractVersion = max(
            0,
            container.decodeIfValid(Int.self, forKey: .organizerContractVersion) ?? 0
        )
        needsFullRegeneration =
            container.decodeIfValid(Bool.self, forKey: .needsFullRegeneration) ?? false
        needsDeferredRegeneration =
            container.decodeIfValid(
                Bool.self,
                forKey: .needsDeferredRegeneration
            ) ?? false
        deferredRegenerationAcknowledgedRevision =
            container.decodeIfValid(
                Int.self,
                forKey: .deferredRegenerationAcknowledgedRevision
            ).map { max(0, $0) }
        stableContextFingerprint = RecentMemoryVersion.validFingerprint(
            container.decodeIfValid(String.self, forKey: .stableContextFingerprint)
        )
    }

    var isDeferredRegenerationAcknowledged: Bool {
        needsDeferredRegeneration
            && deferredRegenerationAcknowledgedRevision == revision
    }

    func versionSnapshot() -> RecentMemoryVersion {
        RecentMemoryVersion(
            content: content,
            contentOrigin: contentOrigin,
            pendingLegacySnapshot: pendingLegacySnapshot,
            entries: entries,
            sources: sources,
            processedSourceRevisions: processedSourceRevisions,
            changeLog: changeLog,
            updatedAt: updatedAt,
            revision: revision,
            organizerContractVersion: organizerContractVersion,
            needsFullRegeneration: needsFullRegeneration,
            needsDeferredRegeneration: needsDeferredRegeneration,
            stableContextFingerprint: stableContextFingerprint
        )
    }
}

struct RecentMemorySourceScopeReconciliation: Equatable, Sendable {
    var state: RecentMemoryState
    var removedEntryCount: Int
    var removedSourceCount: Int
}

enum RecentMemorySourceScopeReconciler {
    static func reconcile(
        state original: RecentMemoryState,
        allowedSourceIDs: Set<UUID>,
        memoryTokenLimit: Int
    ) -> RecentMemorySourceScopeReconciliation {
        var state = original
        if let previous = state.previousVersion {
            let processedSourceIDs = previous.processedSourceRevisions.keys
                .compactMap(UUID.init(uuidString:))
            let previousSourceIDs = Set(
                previous.sources.map(\.conversationID)
                    + previous.entries.flatMap(\.sourceConversationIDs)
                    + processedSourceIDs
            )
            let hasInvalidProcessedSourceID =
                processedSourceIDs.count
                    != previous.processedSourceRevisions.count
            // Undo must not be able to reintroduce an excluded or out-of-window
            // automatic source. A rollback whose sources all remain allowed is
            // still safe and stays available.
            if hasInvalidProcessedSourceID
                || !previousSourceIDs.isSubset(of: allowedSourceIDs) {
                state.previousVersion = nil
            }
        }

        guard state.contentOrigin == .organizerGrounded else {
            return RecentMemorySourceScopeReconciliation(
                state: state,
                removedEntryCount: 0,
                removedSourceCount: 0
            )
        }

        let keptEntries = state.entries.filter { entry in
            !entry.sourceConversationIDs.isEmpty
                && entry.sourceConversationIDs.allSatisfy(
                    allowedSourceIDs.contains
                )
        }
        let removedEntryCount = state.entries.count - keptEntries.count
        state.entries = keptEntries
        state.content = RecentMemoryContentMaterializer.materialize(
            entries: keptEntries,
            maxTokens: memoryTokenLimit
        )

        let oldSourceCount = state.sources.count
        state.sources.removeAll {
            !allowedSourceIDs.contains($0.conversationID)
        }
        state.processedSourceRevisions = state.processedSourceRevisions.filter {
            guard let sourceID = UUID(uuidString: $0.key) else { return false }
            return allowedSourceIDs.contains(sourceID)
        }

        return RecentMemorySourceScopeReconciliation(
            state: state,
            removedEntryCount: removedEntryCount,
            removedSourceCount: oldSourceCount - state.sources.count
        )
    }
}

enum RecentMemoryTokenEstimator {
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var asciiCount = 0
        var otherCount = 0

        for scalar in text.unicodeScalars {
            if isCJK(scalar.value) {
                cjkCount += 1
            } else if scalar.isASCII {
                asciiCount += 1
            } else {
                otherCount += 1
            }
        }

        return cjkCount + otherCount + ((asciiCount + 3) / 4)
    }

    static func prefix(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        guard estimate(text) > maxTokens else { return text }

        let characters = Array(text)
        var lowerBound = 0
        var upperBound = characters.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound + 1) / 2
            let candidate = String(characters.prefix(midpoint))
            if estimate(candidate) <= maxTokens {
                lowerBound = midpoint
            } else {
                upperBound = midpoint - 1
            }
        }
        return String(characters.prefix(lowerBound))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E80...0x2FFF,
             0x3000...0x303F,
             0x3040...0x30FF,
             0x3100...0x312F,
             0x3130...0x318F,
             0x31A0...0x31BF,
             0x31C0...0x31EF,
             0x3200...0x32FF,
             0x3300...0x33FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xA960...0xA97F,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0xFE30...0xFE4F,
             0x20000...0x2FA1F:
            true
        default:
            false
        }
    }
}

enum RecentMemorySourceIDRedactor {
    struct Prepared {
        private let expression: NSRegularExpression?

        init(sourceIDs: Set<UUID>) {
            let alternatives = sourceIDs
                .map(\.uuidString)
                .sorted()
                .map(NSRegularExpression.escapedPattern(for:))
            guard !alternatives.isEmpty else {
                expression = nil
                return
            }
            expression = try? NSRegularExpression(
                pattern: alternatives.joined(separator: "|"),
                options: [.caseInsensitive]
            )
        }

        func redact(_ text: String) -> String {
            guard !text.isEmpty, let expression else { return text }
            return expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: "[local-source]"
            )
        }
    }

    static func redact(_ text: String, sourceIDs: Set<UUID>) -> String {
        Prepared(sourceIDs: sourceIDs).redact(text)
    }
}

enum RecentMemoryOrganizerPromptPlanner {
    struct Source: Sendable {
        var conversationID: UUID
        var sourceRef: String
        var revision: String
        var summary: String
    }

    struct PreviousEntry: Codable, Sendable {
        var category: RecentMemoryEntryCategory
        var content: String
        var sourceRefs: [String]
        var expiresAt: Date?
        var longTermCandidate: Bool

        enum CodingKeys: String, CodingKey {
            case category
            case content
            case sourceRefs = "source_refs"
            case expiresAt = "expires_at"
            case longTermCandidate = "long_term_candidate"
        }
    }

    struct Request: Sendable {
        var organizerSystemPrompt: String
        var updateMode: String
        var now: Date
        var customInstruction: String
        var customInstructionTokenLimit: Int
        var payloadTokenLimit: Int
        var sourceIDsToRedact: Set<UUID>
        var allSourceReferences: [UUID: String]
        var candidates: [Source]
        var previousEntries: [PreviousEntry]
    }

    struct Plan: Sendable {
        var prompt: String
        var includedSourceIDs: [UUID]
        var includedPreviousEntryCount: Int
        var sourceReferenceMap: [String: UUID]
    }

    enum Failure: Error {
        case inputBudgetTooSmall
    }

    private struct SourceInput: Codable {
        var sourceRef: String
        var revision: String
        var summary: String

        enum CodingKeys: String, CodingKey {
            case sourceRef = "source_ref"
            case revision
            case summary
        }
    }

    private struct PreparedSource {
        var conversationID: UUID
        var input: SourceInput
    }

    static func makePlan(_ request: Request) throws -> Plan {
        let redactor = RecentMemorySourceIDRedactor.Prepared(
            sourceIDs: request.sourceIDsToRedact
        )
        var preparedSources: [PreparedSource] = []
        preparedSources.reserveCapacity(request.candidates.count)
        for source in request.candidates {
            try checkCancellation()
            preparedSources.append(PreparedSource(
                conversationID: source.conversationID,
                input: SourceInput(
                    sourceRef: source.sourceRef,
                    revision: source.revision,
                    summary: redactor.redact(source.summary)
                )
            ))
        }
        var preparedPreviousEntries: [PreviousEntry] = []
        preparedPreviousEntries.reserveCapacity(request.previousEntries.count)
        for entry in request.previousEntries {
            try checkCancellation()
            preparedPreviousEntries.append(PreviousEntry(
                category: entry.category,
                content: redactor.redact(entry.content),
                sourceRefs: entry.sourceRefs,
                expiresAt: entry.expiresAt,
                longTermCandidate: entry.longTermCandidate
            ))
        }
        var customInstruction = RecentMemoryTokenEstimator.prefix(
            redactor.redact(
                request.customInstruction.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ),
            maxTokens: request.customInstructionTokenLimit
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        var includedSources: [PreparedSource] = []
        includedSources.reserveCapacity(preparedSources.count)
        var includedPreviousEntryCount = 0

        func exposedSourceReferenceMap() -> [String: UUID] {
            let exposedReferences = Set(
                includedSources.map(\.input.sourceRef)
                    + preparedPreviousEntries
                        .prefix(includedPreviousEntryCount)
                        .flatMap(\.sourceRefs)
            )
            return Dictionary(
                uniqueKeysWithValues: request.allSourceReferences.compactMap {
                    id, reference in
                    exposedReferences.contains(reference)
                        ? (reference, id)
                        : nil
                }
            )
        }

        func makePrompt() -> String {
            let allowedSourceReferences =
                exposedSourceReferenceMap().keys.sorted {
                    let left = Int($0.dropFirst()) ?? .max
                    let right = Int($1.dropFirst()) ?? .max
                    return left == right ? $0 < $1 : left < right
                }
            return """
            Current local time: \(formatter.string(from: request.now))
            Update mode: \(request.updateMode)
            User's organizer preference: \(customInstruction.isEmpty ? "none" : customInstruction)

            <previous_entries_json>
            \(jsonString(Array(
                preparedPreviousEntries.prefix(
                    includedPreviousEntryCount
                )
            )))
            </previous_entries_json>

            <allowed_source_refs_json>
            \(jsonString(allowedSourceReferences))
            </allowed_source_refs_json>

            <changed_conversation_sources_json>
            \(jsonString(
                includedSources.map(\.input)
            ))
            </changed_conversation_sources_json>
            """
        }

        func estimatedInputTokens() -> Int {
            RecentMemoryTokenEstimator.estimate(
                request.organizerSystemPrompt
            )
                + RecentMemoryTokenEstimator.estimate(makePrompt())
        }

        while estimatedInputTokens() > request.payloadTokenLimit,
              !customInstruction.isEmpty {
            try checkCancellation()
            let currentTokens = RecentMemoryTokenEstimator.estimate(
                customInstruction
            )
            customInstruction = RecentMemoryTokenEstimator.prefix(
                customInstruction,
                maxTokens: max(0, currentTokens * 3 / 4)
            )
        }
        guard estimatedInputTokens() <= request.payloadTokenLimit else {
            throw Failure.inputBudgetTooSmall
        }

        for source in preparedSources {
            try checkCancellation()
            includedSources.append(source)
            if estimatedInputTokens() <= request.payloadTokenLimit {
                continue
            }
            includedSources.removeLast()
        }
        guard !includedSources.isEmpty else {
            throw Failure.inputBudgetTooSmall
        }

        for _ in preparedPreviousEntries {
            try checkCancellation()
            includedPreviousEntryCount += 1
            if estimatedInputTokens() > request.payloadTokenLimit {
                includedPreviousEntryCount -= 1
                break
            }
        }

        let prompt = makePrompt()
        guard RecentMemoryTokenEstimator.estimate(
            request.organizerSystemPrompt
        ) + RecentMemoryTokenEstimator.estimate(prompt)
            <= request.payloadTokenLimit else {
            throw Failure.inputBudgetTooSmall
        }
        return Plan(
            prompt: prompt,
            includedSourceIDs: includedSources.map(\.conversationID),
            includedPreviousEntryCount: includedPreviousEntryCount,
            sourceReferenceMap: exposedSourceReferenceMap()
        )
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    private static func checkCancellation() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }
}

enum RecentMemoryNoiseFilter {
    private static let trivialMessages: Set<String> = [
        "嗯", "嗯嗯", "哦", "哦哦", "噢", "好", "好的", "好呀", "好哒", "好吧",
        "可以", "行", "知道了", "收到", "明白", "明白了", "谢谢", "谢谢你", "不客气",
        "没事", "哈哈", "哈哈哈", "嘿嘿", "呵呵", "qwq", "www",
        "ok", "okay", "sure", "thanks", "thank you", "got it", "hi", "hello", "hey",
        "lol", "yes", "no", "yep", "nope"
    ]

    private static let exactErrorPlaceholders: Set<String> = [
        "error", "发生错误", "出错了", "请求失败", "生成失败", "网络错误",
        "回复失败", "已取消", "回复已中断", "暂无内容", "无内容"
    ]

    private static let toolLogPrefixes = [
        "[tool", "<tool", "tool call:", "tool result:", "function call:",
        "function result:", "[工具", "<工具", "工具调用：", "工具结果："
    ]

    static func isNoise(_ text: String) -> Bool {
        let compact = compactWhitespace(text)
        guard !compact.isEmpty else { return true }

        let lowercased = compact.lowercased()
        if toolLogPrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return true
        }

        let comparison = comparisonForm(compact)
        guard !comparison.isEmpty else { return true }
        if trivialMessages.contains(comparison) || exactErrorPlaceholders.contains(comparison) {
            return true
        }

        if comparison.count <= 200,
           comparison.hasPrefix("error:") || comparison.hasPrefix("错误：") {
            return true
        }

        return !compact.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }

    static func filter(_ texts: [String]) -> [String] {
        var result: [String] = []
        var previousComparison: String?

        for text in texts {
            let compact = compactWhitespace(text)
            guard !isNoise(compact) else { continue }
            let comparison = comparisonForm(compact)
            guard comparison != previousComparison else { continue }
            result.append(compact)
            previousComparison = comparison
        }
        return result
    }

    static func compactWhitespace(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func comparisonForm(_ text: String) -> String {
        let punctuationAndWhitespace = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return compactWhitespace(text)
            .lowercased()
            .trimmingCharacters(in: punctuationAndWhitespace)
    }
}

enum RecentMemoryContentMaterializer {
    static func materialize(
        entries: [RecentMemoryEntry],
        maxTokens: Int
    ) -> String {
        let tokenLimit = min(max(maxTokens, 0), 6_000)
        guard tokenLimit > 0 else { return "" }

        var result = ""
        for entry in entries {
            let content = RecentMemoryNoiseFilter.compactWhitespace(entry.content)
            guard !content.isEmpty else { continue }

            let prefix = "• \(entry.category.title)："
            let separator = result.isEmpty ? "" : "\n"
            let candidate = result + separator + prefix + content
            // Entries are atomic facts. Never persist or inject a prefix that
            // might drop a negation, correction, or status change at the end.
            guard RecentMemoryTokenEstimator.estimate(candidate) <= tokenLimit
            else { continue }
            result = candidate
        }
        return result
    }
}

enum RecentMemoryLongTermDeduplicator {
    struct Result: Equatable {
        var entries: [RecentMemoryEntry]
        var removedCount: Int
    }

    static func filter(
        entries: [RecentMemoryEntry],
        longTermMemories: [String]
    ) -> Result {
        let existing = Set(
            longTermMemories.flatMap(normalizedLines)
                .filter { !$0.isEmpty }
        )
        guard !existing.isEmpty else {
            return Result(entries: entries, removedCount: 0)
        }

        var kept: [RecentMemoryEntry] = []
        var removedCount = 0
        for entry in entries {
            let normalized = normalizedForm(entry.content)
            if !normalized.isEmpty, existing.contains(normalized) {
                removedCount += 1
            } else {
                kept.append(entry)
            }
        }
        return Result(entries: kept, removedCount: removedCount)
    }

    static func normalizedForm(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedLines(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        return lines.flatMap { line -> [String] in
            var candidates = [normalizedForm(line)]
            if let content = materializedEntryContent(from: line) {
                candidates.append(normalizedForm(content))
            }
            return candidates
        } + [normalizedForm(text)]
    }

    private static func materializedEntryContent(from line: String) -> String? {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for category in RecentMemoryEntryCategory.allCases {
            for bullet in ["• ", "- ", "* "] {
                for separator in ["：", ":"] {
                    let prefix = bullet + category.title + separator
                    guard cleaned.hasPrefix(prefix) else { continue }
                    let content = cleaned.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return content.isEmpty ? nil : content
                }
            }
        }
        return nil
    }
}

enum RecentMemorySemanticDedupeParser {
    enum ParserError: LocalizedError, Equatable {
        case emptyOutput
        case invalidFence
        case invalidJSON
        case invalidSchema
        case malformedReference(String)
        case unknownReference(String)

        var errorDescription: String? {
            switch self {
            case .emptyOutput:
                ErrorLocalization.lookup("稳定背景去重模型没有返回内容")
            case .invalidFence:
                ErrorLocalization.lookup("稳定背景去重结果的 JSON 代码块不完整")
            case .invalidJSON:
                ErrorLocalization.lookup("稳定背景去重模型没有返回有效的 JSON")
            case .invalidSchema:
                ErrorLocalization.lookup("稳定背景去重结果不符合只读删除清单格式")
            case .malformedReference:
                ErrorLocalization.lookup("稳定背景去重结果包含格式错误的条目短编号")
            case .unknownReference:
                ErrorLocalization.lookup("稳定背景去重结果引用了未提供的条目短编号")
            }
        }
    }

    static func parse(
        _ output: String,
        allowedEntryReferences: Set<String>
    ) throws -> Set<String> {
        let payload = try extractJSON(from: output)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        } catch {
            throw ParserError.invalidJSON
        }
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["drop_entry_refs"],
              let rawReferences = dictionary["drop_entry_refs"] as? [Any]
        else {
            throw ParserError.invalidSchema
        }

        var result = Set<String>()
        for rawReference in rawReferences {
            guard let reference = rawReference as? String else {
                throw ParserError.invalidSchema
            }
            guard isValidEntryReference(reference) else {
                throw ParserError.malformedReference(reference)
            }
            guard allowedEntryReferences.contains(reference) else {
                throw ParserError.unknownReference(reference)
            }
            result.insert(reference)
        }
        return result
    }

    private static func isValidEntryReference(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 2, scalars[0].value == 0x65 else { return false }
        guard (0x31...0x39).contains(scalars[1].value) else { return false }
        return scalars.dropFirst(2).allSatisfy {
            (0x30...0x39).contains($0.value)
        }
    }

    private static func extractJSON(from output: String) throws -> String {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ParserError.emptyOutput }
        guard cleaned.hasPrefix("```") else {
            guard cleaned.hasPrefix("{"), cleaned.hasSuffix("}") else {
                throw ParserError.invalidJSON
            }
            return cleaned
        }
        guard let firstNewline = cleaned.firstIndex(of: "\n") else {
            throw ParserError.invalidFence
        }
        let header = cleaned[..<firstNewline]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard header == "```" || header == "```json" else {
            throw ParserError.invalidFence
        }
        let bodyStart = cleaned.index(after: firstNewline)
        guard let closingFence = cleaned.range(
            of: "```",
            options: .backwards,
            range: bodyStart..<cleaned.endIndex
        ) else {
            throw ParserError.invalidFence
        }
        let trailing = cleaned[closingFence.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty else { throw ParserError.invalidFence }
        let body = cleaned[bodyStart..<closingFence.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("{"), body.hasSuffix("}") else {
            throw ParserError.invalidJSON
        }
        return body
    }
}

struct RecentMemoryOrganizerResult: Hashable, Sendable {
    let memory: String
    let entries: [RecentMemoryEntry]
    let changeLog: [String]
}

enum RecentMemoryOrganizerParser {
    typealias SourceReferenceMap = [String: UUID]

    enum SourceReferenceIssue: Equatable, Sendable {
        case missing
        case malformed(String)
        case unknown(String)
        case legacyField(String)
    }

    enum ParserError: LocalizedError, Equatable {
        case emptyOutput
        case invalidFence
        case invalidJSON
        case emptyMemory
        case invalidEntryCategory(String)
        case modelSuppliedEntryID
        case repairableSourceReference(SourceReferenceIssue)
        case invalidExpirationDate(String)

        var errorDescription: String? {
            switch self {
            case .emptyOutput:
                ErrorLocalization.lookup("整理模型没有返回内容")
            case .invalidFence:
                ErrorLocalization.lookup("整理结果的 JSON 代码块不完整")
            case .invalidJSON:
                ErrorLocalization.lookup("整理模型没有返回有效的 JSON")
            case .emptyMemory:
                ErrorLocalization.lookup("整理结果没有可保存的近期记忆")
            case .invalidEntryCategory(let value):
                ErrorLocalization.format("整理结果包含未知分类：%@", [String(describing: value)])
            case .modelSuppliedEntryID:
                ErrorLocalization.lookup("整理结果不应自行提供记忆条目 ID")
            case .repairableSourceReference(.missing):
                ErrorLocalization.lookup("整理结果包含没有近期聊天来源的条目（可重试）")
            case .repairableSourceReference(.malformed(let value)):
                ErrorLocalization.format("整理结果包含格式错误的来源短编号（可重试）：%@", [String(describing: value)])
            case .repairableSourceReference(.unknown(let value)):
                ErrorLocalization.format("整理结果引用了未提供的来源短编号（可重试）：%@", [String(describing: value)])
            case .repairableSourceReference(.legacyField(let value)):
                ErrorLocalization.format("整理结果使用了旧来源字段（可重试）：%@", [String(describing: value)])
            case .invalidExpirationDate(let value):
                ErrorLocalization.format("整理结果包含无效到期时间：%@", [String(describing: value)])
            }
        }
    }

    static func parse(
        _ output: String,
        sourceReferenceMap: SourceReferenceMap,
        memoryTokenLimit: Int
    ) throws -> RecentMemoryOrganizerResult {
        let payload = try JSONFence.extract(from: output)
        let wireResult: WireResult
        do {
            wireResult = try JSONDecoder().decode(WireResult.self, from: Data(payload.utf8))
        } catch {
            throw ParserError.invalidJSON
        }

        let tokenLimit = min(max(memoryTokenLimit, 1), 6_000)

        var entries: [RecentMemoryEntry] = []
        var entryIndexByKey: [String: Int] = [:]
        var remainingEntryTokens = tokenLimit
        for wireEntry in wireResult.entries.prefix(64) {
            if wireEntry.id != nil {
                throw ParserError.modelSuppliedEntryID
            }
            guard let category = RecentMemoryEntryCategory(rawValue: wireEntry.category) else {
                throw ParserError.invalidEntryCategory(wireEntry.category)
            }
            let normalizedContent = wireEntry.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedContent.isEmpty, remainingEntryTokens > 0 else { continue }

            if wireEntry.usesLegacySourceIDs {
                throw ParserError.repairableSourceReference(
                    .legacyField("source_ids")
                )
            }
            guard !wireEntry.sourceRefs.isEmpty else {
                throw ParserError.repairableSourceReference(.missing)
            }
            let sourceIDs = try resolvedSourceIDs(
                wireEntry.sourceRefs,
                sourceReferenceMap: sourceReferenceMap
            )
            let expiresAt = try parsedISO8601Date(wireEntry.expiresAt)
            let duplicateKey = category.rawValue + "\u{0}"
                + RecentMemoryLongTermDeduplicator.normalizedForm(normalizedContent)
            if let existingIndex = entryIndexByKey[duplicateKey] {
                let combinedSourceIDs = entries[existingIndex].sourceConversationIDs + sourceIDs
                entries[existingIndex].sourceConversationIDs = Array(
                    Set(combinedSourceIDs)
                ).sorted { $0.uuidString < $1.uuidString }
                entries[existingIndex].isLongTermCandidate =
                    entries[existingIndex].isLongTermCandidate
                    || wireEntry.longTermCandidate
                    || category == .longTermCandidate
                continue
            }
            let materializedLine =
                (entries.isEmpty ? "" : "\n")
                + "• \(category.title)：\(normalizedContent)"
            let entryTokens =
                RecentMemoryTokenEstimator.estimate(materializedLine)
            guard entryTokens <= remainingEntryTokens else { continue }
            remainingEntryTokens -= entryTokens
            entries.append(
                RecentMemoryEntry(
                    id: UUID(),
                    category: category,
                    content: normalizedContent,
                    sourceConversationIDs: sourceIDs,
                    expiresAt: expiresAt,
                    isLongTermCandidate:
                        wireEntry.longTermCandidate || category == .longTermCandidate
                )
            )
            entryIndexByKey[duplicateKey] = entries.count - 1
        }

        let changeLog = RecentMemoryNoiseFilter.filter(
            Array(wireResult.changeLog.prefix(32))
        ).map {
            RecentMemoryTokenEstimator.prefix($0, maxTokens: min(tokenLimit, 240))
        }.filter { !$0.isEmpty }

        return RecentMemoryOrganizerResult(
            memory: RecentMemoryContentMaterializer.materialize(
                entries: entries,
                maxTokens: tokenLimit
            ),
            entries: entries,
            changeLog: changeLog
        )
    }

    private static func resolvedSourceIDs(
        _ rawReferences: [String],
        sourceReferenceMap: SourceReferenceMap
    ) throws -> [UUID] {
        var result: [UUID] = []
        var seen = Set<UUID>()
        for reference in rawReferences {
            guard isValidSourceReference(reference) else {
                throw ParserError.repairableSourceReference(
                    .malformed(reference)
                )
            }
            guard let id = sourceReferenceMap[reference] else {
                throw ParserError.repairableSourceReference(
                    .unknown(reference)
                )
            }
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    private static func isValidSourceReference(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 2, scalars[0].value == 0x73 else { return false }
        guard (0x31...0x39).contains(scalars[1].value) else { return false }
        return scalars.dropFirst(2).allSatisfy {
            (0x30...0x39).contains($0.value)
        }
    }

    private static func parsedISO8601Date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: cleaned) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: cleaned) else {
            throw ParserError.invalidExpirationDate(value)
        }
        return date
    }

    private struct WireResult: Decodable {
        let entries: [WireEntry]
        let changeLog: [String]

        private enum CodingKeys: String, CodingKey {
            case entries
            case changeLog = "change_log"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decodeIfPresent([WireEntry].self, forKey: .entries) ?? []
            changeLog = try container.decodeIfPresent([String].self, forKey: .changeLog) ?? []
        }
    }

    private struct WireEntry: Decodable {
        let id: String?
        let category: String
        let content: String
        let sourceRefs: [String]
        let usesLegacySourceIDs: Bool
        let expiresAt: String?
        let longTermCandidate: Bool

        private enum CodingKeys: String, CodingKey {
            case id
            case category
            case content
            case sourceRefs = "source_refs"
            case legacySourceIDs = "source_ids"
            case expiresAt = "expires_at"
            case longTermCandidate = "long_term_candidate"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            category = try container.decode(String.self, forKey: .category)
            content = try container.decode(String.self, forKey: .content)
            usesLegacySourceIDs = container.contains(.legacySourceIDs)
            if usesLegacySourceIDs {
                sourceRefs = try container.decodeIfPresent(
                    [String].self,
                    forKey: .legacySourceIDs
                ) ?? []
            } else {
                sourceRefs = try container.decodeIfPresent(
                    [String].self,
                    forKey: .sourceRefs
                ) ?? []
            }
            expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
            longTermCandidate = try container.decodeIfPresent(
                Bool.self,
                forKey: .longTermCandidate
            ) ?? false
        }
    }

    private enum JSONFence {
        static func extract(from output: String) throws -> String {
            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw ParserError.emptyOutput }
            guard cleaned.hasPrefix("```") else { return cleaned }
            guard let firstNewline = cleaned.firstIndex(of: "\n") else {
                throw ParserError.invalidFence
            }

            let header = cleaned[..<firstNewline]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard header == "```" || header == "```json" else {
                throw ParserError.invalidFence
            }

            let bodyStart = cleaned.index(after: firstNewline)
            guard let closingFence = cleaned.range(
                of: "```",
                options: .backwards,
                range: bodyStart..<cleaned.endIndex
            ) else {
                throw ParserError.invalidFence
            }
            let trailing = cleaned[closingFence.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard trailing.isEmpty else { throw ParserError.invalidFence }
            return cleaned[bodyStart..<closingFence.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

enum RecentMemoryFingerprint {
    static func summary(_ text: String) -> String {
        fnv1a64Hex(normalizedSummary(text))
    }

    static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private static func normalizedSummary(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

private extension KeyedDecodingContainer {
    func decodeIfValid<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            return nil
        }
    }

    func decodeLossyArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key
    ) -> [Element] {
        guard var container = try? nestedUnkeyedContainer(forKey: key) else {
            return []
        }
        var result: [Element] = []
        while !container.isAtEnd {
            guard let decoder = try? container.superDecoder() else { break }
            if let value = try? Element(from: decoder) {
                result.append(value)
            }
        }
        return result
    }
}
