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

    static func parse(_ raw: String, isStreaming: Bool = false) -> AIMessageReactionResult {
        guard raw.contains("<!--") else {
            return AIMessageReactionResult(content: raw, reaction: nil)
        }

        let fullRange = NSRange(raw.startIndex..., in: raw)
        // A stopped reply may end inside an inline example. Keep it literal too.
        let literals = MarkdownLiteralRanges(raw, isStreaming: true)
        let matches = completeMarkerRegex.matches(in: raw, range: fullRange)
        var reaction: String?
        var consumed: [NSRange] = []
        for match in matches {
            guard literals.allowsMarker(at: match.range.location),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            let candidate = raw[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if allowedReactions.contains(candidate) {
                reaction = candidate
                consumed.append(match.range)
            }
        }

        var content = MarkdownLiteralRanges.removing(consumed, from: raw)
        if isStreaming { content = stripTrailingPartialMarker(from: content) }
        if content != raw {
            content = MarkdownLiteralRanges.trimmingTrailingWhitespace(content)
        }
        return AIMessageReactionResult(content: content, reaction: reaction)
    }

    static func stripForDisplay(_ raw: String) -> String {
        parse(raw, isStreaming: true).content
    }

    private static func stripTrailingPartialMarker(from raw: String) -> String {
        guard let markerRange = raw.range(of: "<!--", options: .backwards) else {
            return raw
        }
        guard MarkdownLiteralRanges(raw, isStreaming: true).allowsMarker(at: markerRange.lowerBound.utf16Offset(in: raw)) else { return raw }
        let tail = raw[markerRange.lowerBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !tail.contains("-->"), markerPrefixes.contains(where: { $0.hasPrefix(tail) || tail.hasPrefix($0) }) else {
            return raw
        }
        return String(raw[..<markerRange.lowerBound])
    }

}
