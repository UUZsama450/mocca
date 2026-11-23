import Foundation

enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case last30 = "最近 30 天"
    case previousMonth = "上个月"
    case previousQuarter = "上个季度"
    case custom = "自定义"
    var id: String { rawValue }
}

struct ChatHeatmapDay: Identifiable, Sendable, Equatable {
    let date: Date
    let count: Int
    let isFuture: Bool
    var id: Date { date }
}

struct ChatHeatmapWeek: Identifiable, Sendable, Equatable {
    let startDate: Date
    let days: [ChatHeatmapDay]
    var id: Date { startDate }
}

struct UsageStatisticsQuery: Hashable, Sendable {
    let range: StatsRange
    let customStart: Date
    let customEnd: Date
    let today: Date
    let calendar: Calendar

    init(range: StatsRange, customStart: Date, customEnd: Date, today: Date, calendar: Calendar) {
        self.range = range
        // Unused picker defaults must not invalidate All/Month caches whenever
        // the page is reopened. Custom selections are day-based too.
        self.customStart = range == .custom ? calendar.startOfDay(for: customStart) : .distantPast
        self.customEnd = range == .custom ? calendar.startOfDay(for: customEnd) : .distantPast
        self.today = calendar.startOfDay(for: today)
        self.calendar = calendar
    }

    /// Half-open timestamp bounds preserve inclusive local dates across DST.
    /// They are resolved once per request, never once per message.
    var bounds: (start: Date?, end: Date?) {
        let today = calendar.startOfDay(for: today)
        switch range {
        case .all: return (nil, nil)
        case .last30:
            return (calendar.date(byAdding: .day, value: -29, to: today), calendar.date(byAdding: .day, value: 1, to: today))
        case .previousMonth:
            let end = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            return (calendar.date(byAdding: .month, value: -1, to: end), end)
        case .previousQuarter:
            let parts = calendar.dateComponents([.year, .month], from: today)
            let month = (((parts.month ?? 1) - 1) / 3) * 3 + 1
            let end = calendar.date(from: DateComponents(year: parts.year, month: month, day: 1)) ?? today
            return (calendar.date(byAdding: .month, value: -3, to: end), end)
        case .custom:
            return (calendar.startOfDay(for: customStart), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: customEnd)))
        }
    }
}

/// These immutable value snapshots share storage. Capturing them on MainActor
/// does not flatten, filter, or copy every ChatMessage.
struct UsageStatisticsSnapshot: Sendable {
    let conversations: [Conversation]
    let messagesByConversation: [UUID: [ChatMessage]]
    let assistantNames: [String: String]
    let defaultAssistantName: String
}

struct UsageStatisticsRanking: Sendable, Equatable {
    let name: String
    let count: Int
}

struct UsageStatisticsResult: Sendable, Equatable {
    var conversationCount = 0
    var messageCount = 0
    var promptTokens = 0
    var completionTokens = 0
    var cachedTokens = 0
    var cacheWriteTokens = 0
    var cacheWrite30mTokens = 0
    var cacheWrite12hTokens = 0
    var modelRanking: [UsageStatisticsRanking] = []
    var assistantRanking: [UsageStatisticsRanking] = []
    var topicRanking: [UsageStatisticsRanking] = []
    var heatmapWeeks: [ChatHeatmapWeek] = []
}

enum UsageStatisticsCalculator {
    static func compute(_ snapshot: UsageStatisticsSnapshot, query: UsageStatisticsQuery) async throws -> UsageStatisticsResult {
        let worker = Task.detached(priority: .userInitiated) {
            try calculate(snapshot, query: query)
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }

    static func calculate(_ snapshot: UsageStatisticsSnapshot, query: UsageStatisticsQuery) throws -> UsageStatisticsResult {
        try Task.checkCancellation()
        let bounds = query.bounds
        func contains(_ date: Date) -> Bool {
            (bounds.start == nil || date >= bounds.start!) && (bounds.end == nil || date < bounds.end!)
        }
        var calendar = query.calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: query.today)
        let weekday = (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
        let currentWeek = calendar.date(byAdding: .day, value: -weekday, to: today) ?? today
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -11, to: currentWeek) ?? today
        let endWeek = calendar.date(byAdding: .day, value: 7, to: currentWeek) ?? today

        var result = UsageStatisticsResult()
        var models: [String: Int] = [:]
        var assistants: [String: Int] = [:]
        var topics: [UUID: Int] = [:]
        var days: [Date: Int] = [:]
        var visited = 0
        // Retain the existing statistics contract: include stored versions and
        // all roles; token counts are the provider-reported values, not estimates.
        for (conversationID, messages) in snapshot.messagesByConversation {
            try Task.checkCancellation()
            var count = 0
            for message in messages {
                visited += 1
                if visited % 256 == 0 { try Task.checkCancellation() }
                guard contains(message.createdAt) else { continue }
                count += 1
                result.messageCount += 1
                if let usage = message.tokenUsage {
                    result.promptTokens += usage.promptTokens ?? 0
                    result.completionTokens += usage.completionTokens ?? 0
                    result.cachedTokens += usage.cachedTokens ?? 0
                    result.cacheWriteTokens += usage.cacheWriteTokens ?? 0
                    result.cacheWrite30mTokens += usage.cacheWrite30mTokens ?? 0
                    result.cacheWrite12hTokens += usage.cacheWrite12hTokens ?? 0
                }
                if message.role == .assistant {
                    if let id = message.modelID { models[id, default: 0] += 1 }
                    if let id = message.groupID { assistants[id, default: 0] += 1 }
                }
                // Old messages do not need a calendar conversion for an
                // 84-day heatmap, even when the selected statistics range is All.
                if message.createdAt >= firstWeek, message.createdAt < endWeek {
                    days[calendar.startOfDay(for: message.createdAt), default: 0] += 1
                }
            }
            topics[conversationID] = count
        }
        var topicRows: [UsageStatisticsRanking] = []
        for conversation in snapshot.conversations where contains(conversation.createdAt) {
            result.conversationCount += 1
            if let count = topics[conversation.id], count > 0 {
                topicRows.append(UsageStatisticsRanking(name: conversation.title, count: count))
            }
        }
        result.modelRanking = ranked(models.map { UsageStatisticsRanking(name: $0.key, count: $0.value) })
        // Rank by assistant identity before mapping names, matching the existing
        // behavior when different assistants share a display name.
        result.assistantRanking = ranked(assistants.map { UsageStatisticsRanking(name: $0.key, count: $0.value) }).map {
            UsageStatisticsRanking(name: snapshot.assistantNames[$0.name] ?? snapshot.defaultAssistantName, count: $0.count)
        }
        result.topicRanking = ranked(topicRows)
        result.heatmapWeeks = (0..<12).compactMap { weekOffset in
            guard let week = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: firstWeek) else { return nil }
            let entries = (0..<7).compactMap { offset -> ChatHeatmapDay? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: week) else { return nil }
                return ChatHeatmapDay(date: date, count: days[date, default: 0], isFuture: date > today)
            }
            return ChatHeatmapWeek(startDate: week, days: entries)
        }
        try Task.checkCancellation()
        return result
    }

    private static func ranked(_ values: [UsageStatisticsRanking]) -> [UsageStatisticsRanking] {
        Array(values.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }.prefix(10))
    }
}

struct UsageStatisticsRevision: Hashable {
    let messages: UInt64
    let metadata: UInt64
}

/// App-lifetime cache, bounded to a few date selections. It holds aggregates,
/// never conversation snapshots or message text.
@MainActor
final class UsageStatisticsCache {
    struct Entry {
        let query: UsageStatisticsQuery
        let revision: UsageStatisticsRevision
        let result: UsageStatisticsResult
    }
    private var entries: [Entry] = []

    func latest(for query: UsageStatisticsQuery) -> Entry? {
        entries.last { $0.query == query }
    }

    func store(_ result: UsageStatisticsResult, query: UsageStatisticsQuery, revision: UsageStatisticsRevision) {
        entries.removeAll { $0.query == query }
        entries.append(Entry(query: query, revision: revision, result: result))
        if entries.count > 8 { entries.removeFirst(entries.count - 8) }
    }
}
