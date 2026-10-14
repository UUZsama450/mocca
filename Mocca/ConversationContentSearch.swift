import Foundation

/// Value snapshots share their existing storage until a writer changes it.
/// Capturing one does not walk or prepare the entire history on the main actor.
struct ConversationContentSearchSnapshot: Sendable {
    let conversations: [Conversation]
    let messagesByConversation: [UUID: [ChatMessage]]
}

struct ConversationContentSearchMatch: Sendable {
    let conversation: Conversation
    let message: ChatMessage
    let snippetSegments: [ConversationContentSearchSnippetSegment]
}

struct ConversationContentSearchSnippetSegment: Sendable {
    let text: String
    let isMatch: Bool
}

enum ConversationContentSearch {
    /// Only the request's immutable values cross the actor boundary. In
    /// particular, the worker never reads AppModel or its projection cache.
    static func search(
        _ snapshot: ConversationContentSearchSnapshot,
        query: String,
        groupChatMode: Bool
    ) async throws -> [ConversationContentSearchMatch] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try matches(in: snapshot, query: query, groupChatMode: groupChatMode)
        }
        return try await withTaskCancellationHandler {
            let matches = try await worker.value
            // Cancellation can arrive after the worker finishes, before the
            // waiting UI task resumes. Never publish that obsolete result.
            try Task.checkCancellation()
            return matches
        } onCancel: {
            worker.cancel()
        }
    }

    private static func matches(
        in snapshot: ConversationContentSearchSnapshot,
        query: String,
        groupChatMode: Bool
    ) throws -> [ConversationContentSearchMatch] {
        try Task.checkCancellation()
        guard !query.isEmpty else { return [] }
        let conversations = snapshot.conversations.filter {
            groupChatMode ? $0.groupAssistantIDs.count >= 2 : $0.groupAssistantIDs.count < 2
        }.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.createdAt > rhs.createdAt }
            return lhs.updatedAt > rhs.updatedAt
        }
        var results: [ConversationContentSearchMatch] = []
        results.reserveCapacity(min(conversations.count, 32))
        for conversation in conversations {
            try Task.checkCancellation()
            if let message = try firstMatch(
                in: snapshot.messagesByConversation[conversation.id] ?? [],
                selections: conversation.versionSelections,
                query: query
            ) {
                let snippet = contentSearchSnippet(for: message.text, query: query)
                try Task.checkCancellation()
                results.append(ConversationContentSearchMatch(
                    conversation: conversation,
                    message: message,
                    snippetSegments: contentSearchSnippetSegments(for: snippet, query: query)
                ))
            }
        }
        try Task.checkCancellation()
        return results
    }

    private static func firstMatch(
        in messages: [ChatMessage],
        selections: [String: Int],
        query: String
    ) throws -> ChatMessage? {
        // Match AppModel.selectedMessageProjection's logical order, explicit
        // versions and date/ID tie breaks. Keep parity tests against that code;
        // searching must not change the transcript's main-actor cache or make
        // hidden regenerated replies searchable.
        func precedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var order: [String] = []
        var selectedIndices: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            try Task.checkCancellation()
            let key = message.versionGroupKey
            guard let previous = selectedIndices[key] else {
                order.append(key)
                selectedIndices[key] = index
                continue
            }
            let selected = messages[previous]
            let requestedVersion = selections[key]
            let shouldReplace: Bool
            if message.version == requestedVersion {
                shouldReplace = selected.version != requestedVersion || precedes(message, selected)
            } else {
                shouldReplace = selected.version != requestedVersion && !precedes(message, selected)
            }
            if shouldReplace { selectedIndices[key] = index }
        }
        for key in order {
            try Task.checkCancellation()
            let message = messages[selectedIndices[key]!]
            guard message.role == .user || message.role == .assistant else { continue }
            if message.text.localizedCaseInsensitiveContains(query) { return message }
        }
        return nil
    }

    private static func contentSearchSnippet(for text: String, query: String) -> String {
        let compactText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let matchRange = compactText.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return String(compactText.prefix(120))
        }

        let start = compactText.index(
            matchRange.lowerBound,
            offsetBy: -36,
            limitedBy: compactText.startIndex
        ) ?? compactText.startIndex
        let end = compactText.index(
            matchRange.upperBound,
            offsetBy: 96,
            limitedBy: compactText.endIndex
        ) ?? compactText.endIndex
        let prefix = start > compactText.startIndex ? "…" : ""
        let suffix = end < compactText.endIndex ? "…" : ""
        return prefix + String(compactText[start..<end]) + suffix
    }

    private static func contentSearchSnippetSegments(
        for snippet: String,
        query: String
    ) -> [ConversationContentSearchSnippetSegment] {
        guard !query.isEmpty else {
            return [ConversationContentSearchSnippetSegment(text: snippet, isMatch: false)]
        }

        var segments: [ConversationContentSearchSnippetSegment] = []
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex,
              let match = snippet.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<snippet.endIndex
              ) {
            if cursor < match.lowerBound {
                segments.append(ConversationContentSearchSnippetSegment(
                    text: String(snippet[cursor..<match.lowerBound]), isMatch: false
                ))
            }
            segments.append(ConversationContentSearchSnippetSegment(text: String(snippet[match]), isMatch: true))
            cursor = match.upperBound
        }
        if cursor < snippet.endIndex {
            segments.append(ConversationContentSearchSnippetSegment(text: String(snippet[cursor..<snippet.endIndex]), isMatch: false))
        }
        return segments.isEmpty
            ? [ConversationContentSearchSnippetSegment(text: snippet, isMatch: false)]
            : segments
    }
}
