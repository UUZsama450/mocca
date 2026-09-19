import Foundation

@main
enum StreamingScanCleanupEquivalenceTests {
    private enum BlockKind: CaseIterable {
        case text
        case heading
        case list
        case quote
        case horizontalRule
        case code
        case table
    }

    private enum Route: Equatable {
        case unified
        case mixed
        case legacy
    }

    private static var assertions = 0

    static func main() {
        fadeCharacterCountIsEquivalent()
        markdownRouteIsEquivalent()
        searchImageMarkerFastPathIsEquivalent()
        print("STREAMING_SCAN_CLEANUP_TESTS=PASS assertions=\(assertions)")
    }

    private static func expect<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ name: String
    ) {
        assertions += 1
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    private static func fadeCharacterCountIsEquivalent() {
        let samples = [
            "",
            "a",
            "ab",
            "abcdefg",
            "abcdefghijklmno",
            "abcdefghijklmnop",
            String(repeating: "x", count: 40_000),
            "宝",
            "示例示例示例示例示例示例示例示例示例",
            "👨‍👩‍👧‍👦👩🏽‍💻🇨🇳e\u{301}🙂✨🌙abcdefghi",
        ]

        for (index, sample) in samples.enumerated() where !sample.isEmpty {
            let old = min(8, max(1, sample.count / 2))
            let boundedCharacterCount = sample.prefix(16).count
            let new = min(8, max(1, boundedCharacterCount / 2))
            expect(new, old, "fade sample \(index)")
        }
    }

    private static func markdownRouteIsEquivalent() {
        let texts = ["", "   \n\t", "hello", " 示例 "]
        let blockSets: [[BlockKind]] = [
            [],
            [.text],
            [.heading, .list, .quote, .horizontalRule],
            [.code],
            [.table],
            [.text, .code, .text],
            [.table, .heading],
        ]

        for prefersUnified in [false, true] {
            for rendersMarkdown in [false, true] {
                for text in texts {
                    for blocks in blockSets {
                        expect(
                            newRoute(
                                text: text,
                                blocks: blocks,
                                prefersUnified: prefersUnified,
                                rendersMarkdown: rendersMarkdown
                            ),
                            oldRoute(
                                text: text,
                                blocks: blocks,
                                prefersUnified: prefersUnified,
                                rendersMarkdown: rendersMarkdown
                            ),
                            "route prefers=\(prefersUnified) markdown=\(rendersMarkdown) text=\(text.debugDescription) blocks=\(blocks)"
                        )
                    }
                }
            }
        }
    }

    private static func oldRoute(
        text: String,
        blocks: [BlockKind],
        prefersUnified: Bool,
        rendersMarkdown: Bool
    ) -> Route {
        let hasVisibleText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let usesUnified: Bool
        if !prefersUnified || !hasVisibleText {
            usesUnified = false
        } else if !rendersMarkdown {
            usesUnified = true
        } else {
            usesUnified = !blocks.isEmpty && blocks.allSatisfy(isProse)
        }
        if usesUnified { return .unified }

        let usesMixed = prefersUnified
            && rendersMarkdown
            && hasVisibleText
            && blocks.contains(where: { !isProse($0) })
        return usesMixed ? .mixed : .legacy
    }

    private static func newRoute(
        text: String,
        blocks: [BlockKind],
        prefersUnified: Bool,
        rendersMarkdown: Bool
    ) -> Route {
        guard prefersUnified,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .legacy
        }
        guard rendersMarkdown else { return .unified }
        guard !blocks.isEmpty else { return .legacy }
        return blocks.contains(where: { !isProse($0) }) ? .mixed : .unified
    }

    private static func isProse(_ block: BlockKind) -> Bool {
        switch block {
        case .text, .heading, .list, .quote, .horizontalRule:
            return true
        case .code, .table:
            return false
        }
    }

    private static func searchImageMarkerFastPathIsEquivalent() {
        let samples = [
            "ordinary response",
            "literal < text",
            "partial <ks-ima",
            "before <ks-image> unfinished",
            "before <KS-IMAGE> unfinished",
            "<ks-image>{\"id\":\"one\"}</ks-image> after",
            "<KS-IMAGE>{\"id\":\"one\"}</KS-IMAGE> after",
        ]

        for (index, sample) in samples.enumerated() {
            expect(
                newSearchImageDisplayText(sample),
                oldSearchImageDisplayText(sample),
                "search image sample \(index)"
            )
        }
    }

    private static let searchImageOpeningMarker = "<ks-image>"
    private static let searchImageRegex = try! NSRegularExpression(
        pattern: #"(?is)<ks-image>\s*(\{.*?\})\s*</ks-image>"#
    )

    private static func oldSearchImageDisplayText(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let parsed = searchImageRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        if let markerStart = parsed.range(
            of: searchImageOpeningMarker,
            options: [.caseInsensitive, .backwards]
        )?.lowerBound {
            return String(parsed[..<markerStart])
        }
        return parsed
    }

    private static func newSearchImageDisplayText(_ text: String) -> String {
        guard text.range(
            of: searchImageOpeningMarker,
            options: .caseInsensitive
        ) != nil else {
            return text
        }
        return oldSearchImageDisplayText(text)
    }
}
