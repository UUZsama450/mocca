import Foundation

@main
enum ControlMarkerPrefixBoundEquivalenceTests {
    private static let markerPrefixes = [
        "<!--mocca-reaction:",
        "<!--kelivo-reaction:",
        "<kg>",
        "<ks-image>",
    ]
    private static let maximumPrefixCharacterCount = markerPrefixes.map(\.count).max() ?? 0
    private static var assertions = 0

    static func main() {
        let samples = [
            "",
            "ordinary response",
            "literal < text",
            "suffix <",
            "suffix <!",
            "suffix <!--",
            "suffix <!--mocca-reaction:",
            "suffix <!--MOCCA-REACTION:",
            "suffix <!--kelivo-reaction:",
            "suffix <k",
            "suffix <K",
            "suffix <kg",
            "suffix <kg>",
            "suffix <ks-image",
            "suffix <KS-IMAGE>",
            "suffix <not-a-control-marker",
            "suffix <" + String(repeating: "ordinary prose ", count: 4_000),
            "earlier <kg then visible text",
            "earlier <kg then another <k",
            "unicode <示例👨‍👩‍👧‍👦e\u{301}" + String(repeating: "长文本", count: 2_000),
        ]

        for (index, sample) in samples.enumerated() {
            expect(newFiltered(sample), oldFiltered(sample), "sample \(index)")
        }

        for prefix in markerPrefixes {
            for length in 1...prefix.count {
                let partial = String(prefix.prefix(length))
                expect(
                    newFiltered("visible \(partial)"),
                    oldFiltered("visible \(partial)"),
                    "partial \(prefix) length \(length)"
                )
                expect(
                    newFiltered("visible \(partial.uppercased())"),
                    oldFiltered("visible \(partial.uppercased())"),
                    "uppercase partial \(prefix) length \(length)"
                )
            }
        }

        let longTail = "<" + String(repeating: "x", count: 50_000)
        expect(newNormalizedCharacterCount(longTail), 0, "long impossible tail is not normalized")
        expect(
            newNormalizedCharacterCount("<KS-IMAGE"),
            "<KS-IMAGE".count,
            "bounded possible tail is normalized"
        )

        print("CONTROL_MARKER_PREFIX_BOUND_TESTS=PASS assertions=\(assertions)")
    }

    private static func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        assertions += 1
        guard actual == expected else {
            fatalError("\(name): expected \(expected), got \(actual)")
        }
    }

    private static func oldFiltered(_ raw: String) -> String {
        guard let markerStart = raw.lastIndex(of: "<") else { return raw }
        let candidate = raw[markerStart...].lowercased()
        guard markerPrefixes.contains(where: { $0.hasPrefix(candidate) }) else {
            return raw
        }
        return String(raw[..<markerStart])
    }

    private static func newFiltered(_ raw: String) -> String {
        guard let markerStart = raw.lastIndex(of: "<") else { return raw }
        let candidate = raw[markerStart...]
        let bounded = candidate.prefix(maximumPrefixCharacterCount + 1)
        guard bounded.count <= maximumPrefixCharacterCount else { return raw }
        let normalized = bounded.lowercased()
        guard markerPrefixes.contains(where: { $0.hasPrefix(normalized) }) else {
            return raw
        }
        return String(raw[..<markerStart])
    }

    private static func newNormalizedCharacterCount(_ raw: String) -> Int {
        guard let markerStart = raw.lastIndex(of: "<") else { return 0 }
        let bounded = raw[markerStart...].prefix(maximumPrefixCharacterCount + 1)
        guard bounded.count <= maximumPrefixCharacterCount else { return 0 }
        return bounded.lowercased().count
    }
}
