import Foundation

@main
enum ExternalImageMarkerFastPathEquivalenceTests {
    private static let openingMarker = "<kg>"
    private static let fullRegex = try! NSRegularExpression(
        pattern: #"(?s)<kg>\s*(\{.*?\})\s*</kg>"#
    )
    private static var assertions = 0
    private static var fastPathRegexCalls = 0

    static func main() {
        let ordinarySamples = [
            "",
            "ordinary response",
            "  leading and trailing  ",
            "one\n\n\ntwo",
            "one\r\n\r\n\r\ntwo",
            "示例 👨‍👩‍👧‍👦 e\u{301}",
            "literal < character",
            "suffix <",
            "suffix <k",
            "suffix <kg",
            "suffix <KG",
            "uppercase <KG>{\"prompt\":\"cat\"}</KG>",
            String(repeating: "long prose ", count: 4_000),
        ]
        let markerSamples = [
            "before <kg>",
            "before <kg>{",
            "before <kg>{\"prompt\":\"cat\"}",
            "before <kg>{\"prompt\":\"cat\"}</kg>",
            "<kg>{\"prompt\":\"cat\"}</kg> after",
            "before\n\n<kg>  {\"prompt\":\"cat\"}  </kg>\n\nafter",
            "<kg>{not-json}</kg>",
            "<kg>{\"prompt\":\"one\"}</kg> middle <kg>{\"prompt\":\"two\"}</kg>",
            "text <kg-not-a-marker>",
        ]

        for (index, sample) in (ordinarySamples + markerSamples).enumerated() {
            expect(newStripForDisplay(sample), oldStripForDisplay(sample), "sample \(index)")
        }
        let expectedRegexCalls = (ordinarySamples + markerSamples).filter {
            $0.contains(openingMarker)
        }.count
        expect(fastPathRegexCalls, expectedRegexCalls, "regex only runs with exact opening marker")
        print("EXTERNAL_IMAGE_MARKER_FAST_PATH_TESTS=PASS assertions=\(assertions)")
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        assertions += 1
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    private static func oldStripForDisplay(_ text: String) -> String {
        finishDisplayFiltering(parsedDisplayText(text))
    }

    private static func newStripForDisplay(_ text: String) -> String {
        let parsed: String
        if text.contains(openingMarker) {
            fastPathRegexCalls += 1
            parsed = parsedDisplayText(text)
        } else {
            parsed = cleanedDisplayText(text)
        }
        return finishDisplayFiltering(parsed)
    }

    private static func parsedDisplayText(_ text: String) -> String {
        let nsText = text as NSString
        let stripped = fullRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: ""
        )
        return cleanedDisplayText(stripped)
    }

    private static func finishDisplayFiltering(_ parsed: String) -> String {
        if let markerStart = parsed.range(
            of: openingMarker,
            options: .backwards
        )?.lowerBound {
            return cleanedDisplayText(String(parsed[..<markerStart]))
        }

        guard let markerStart = parsed.range(of: "<", options: .backwards)?.lowerBound else {
            return parsed
        }
        let trailingCandidate = parsed[markerStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard openingMarker.hasPrefix(trailingCandidate) else { return parsed }
        return cleanedDisplayText(String(parsed[..<markerStart]))
    }

    private static func cleanedDisplayText(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var previousBlank = false
        for line in lines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, previousBlank { continue }
            result.append(line)
            previousBlank = blank
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
