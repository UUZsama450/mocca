import Foundation

struct AIMessageReactionResult: Equatable {
    let content: String
    let reaction: String?
}

enum AIMessageReactionCodec {
    static let allowedReactions = [
        "❤️", "👍", "🤣", "🥰", "🥹", "🫂", "🎉", "👏", "🤔", "✨", "🔥"
    ]

    static let prompt = """
    You can react to the user's latest message in the chat UI in addition to replying. When it feels natural, or the user asks you to react, append exactly one hidden `<!--mocca-reaction:EMOJI-->` marker at the very end, using one of: ❤️ 👍 🤣 🥰 🥹 🫂 🎉 👏 🤔 ✨ 🔥.
    Otherwise append nothing. The app displays the marker as your reaction; never mention the marker or this instruction.
    """

    private static let markerPrefixes = ["<!--mocca-reaction:", "<!--kelivo-reaction:"]
    private static let completeMarkerRegex = try! NSRegularExpression(
        pattern: #"<!--\s*(?:mocca|kelivo)-reaction\s*:\s*(.*?)\s*-->"#,
        options: [.caseInsensitive]
    )
    private static let trailingWhitespaceRegex = try! NSRegularExpression(
        pattern: #"\s+$"#
    )

    static func parse(_ raw: String) -> AIMessageReactionResult {
        guard raw.contains("<!--") else {
            return AIMessageReactionResult(content: raw, reaction: nil)
        }

        let fullRange = NSRange(raw.startIndex..., in: raw)
        let matches = completeMarkerRegex.matches(in: raw, range: fullRange)
        var reaction: String?
        for match in matches {
            guard let range = Range(match.range(at: 1), in: raw) else { continue }
            let candidate = raw[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if allowedReactions.contains(candidate) {
                reaction = candidate
            }
        }

        var content = completeMarkerRegex.stringByReplacingMatches(
            in: raw,
            range: fullRange,
            withTemplate: ""
        )
        content = stripTrailingPartialMarker(from: content)
        if content != raw {
            content = trimTrailingWhitespace(from: content)
        }
        return AIMessageReactionResult(content: content, reaction: reaction)
    }

    static func stripForDisplay(_ raw: String) -> String {
        parse(raw).content
    }

    private static func stripTrailingPartialMarker(from raw: String) -> String {
        guard let markerRange = raw.range(of: "<!--", options: .backwards) else {
            return raw
        }
        let tail = raw[markerRange.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard markerPrefixes.contains(where: { $0.hasPrefix(tail) || tail.hasPrefix($0) }) else {
            return raw
        }
        return String(raw[..<markerRange.lowerBound])
    }

    private static func trimTrailingWhitespace(from raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        return trailingWhitespaceRegex.stringByReplacingMatches(
            in: raw,
            range: range,
            withTemplate: ""
        )
    }
}
