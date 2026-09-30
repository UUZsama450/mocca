import Foundation

nonisolated(unsafe) var fullImageRegexPasses = 0
nonisolated(unsafe) var candidateIndexBuilds = 0

// PRODUCT_CODECS

@main enum CompletionCodecTests {
    static let candidates = (0..<6).map {
        SearchImageCandidate(id: "c\($0)", title: "Image \($0)",
            url: "https://example.invalid/\($0).png", sourceURL: nil)
    } + [SearchImageCandidate(id: "c0", title: "Duplicate", url: "duplicate", sourceURL: nil)]

    static func result(_ text: String) -> [String: Any] {
        // Compare both public parsers independently and the real finalization order.
        let directImage = ExternalImageGenerationCodec.parse(text)
        let directSearch = SearchImageSelectionCodec.parse(text, candidates: candidates)
        let reaction = AIMessageReactionCodec.parse(text)
        let image = ExternalImageGenerationCodec.parse(reaction.content)
        let search = SearchImageSelectionCodec.parse(image.displayText, candidates: candidates)
        return ["imageText": directImage.displayText,
                "imagePrompts": directImage.requests.map(\.prompt),
                "searchText": directSearch.displayText,
                "searchImages": directSearch.requests.map { [$0.candidate.id, $0.candidate.title, $0.candidate.url] },
                "finalText": search.displayText,
                "reaction": reaction.reaction ?? "",
                "finalPrompts": image.requests.map(\.prompt),
                "finalImages": search.requests.map { $0.candidate.id }]
    }

    static func main() throws {
        var fixtures = ["", " ", "\t \n\r\n", "plain 中文 🐈 e\u{301}",
            "a\r\nb\r\n\r\n\r\nc", "a\u{2028}\u{2029}b", "  a\n \t\n\n\nb  ",
            "literal <", "x <kg>", "<KG>{\"prompt\":\"upper\"}</KG>",
            "<kg>{\"prompt\":\" draw 中文 🐈 \"}</kg>",
            "<kg>{\"prompt\":\"a\\\"b\\nc\"}</kg>",
            "<kg>{\"prompt\":\"\"}</kg>", "<kg>{\"prompt\":3}</kg>",
            "<kg>{broken}</kg>", "<kg>{\"prompt\":\"a\"}</kg><kg>{\"prompt\":\"b\"}</kg>",
            "<ks-image>{\"id\":\"c0\"}</ks-image>", "<KS-IMAGE>{\"id\":\"c1\"}</KS-IMAGE>",
            "<kſ-image>{\"id\":\"c2\"}</kſ-image>", "<Ks-image>{\"id\":\"c3\"}</Ks-image>",
            "<ks-image>{\"id\":\"unknown\"}</ks-image>", "<ks-image>{broken}</ks-image>",
            "<ks-image>{\"id\":12}</ks-image>", "a <!--mocca-reaction:❤️-->",
            "a <!--KELIVO-REACTION:👍--> \n", "a <!--mocca-reaction:invalid-->",
            "a <kg>{\"prompt\":\"p\"}</kg> b <ks-image>{\"id\":\"c0\"}</ks-image> <!--mocca-reaction:🥰-->",
            (0..<6).map { "<ks-image>{\"id\":\"c\($0)\"}</ks-image>" }.joined(),
            String(repeating: "<ks-image>{\"id\":\"c0\"}</ks-image>", count: 5)]
        for complete in ["<kg>{\"prompt\":\"中文\"}</kg>",
                         "<ks-image>{\"id\":\"c0\"}</ks-image>",
                         "<!--mocca-reaction:❤️-->"] {
            for end in complete.indices { fixtures.append("prefix \n" + complete[..<end]) }
        }
        // Deterministic mixed prose/control fragments catch whitespace and case-fold edges.
        var seed: UInt64 = 20260930
        let pieces = ["中文", "🐈", "\n", "\r\n", " ", "<", ">", "<kg>", "</kg>",
            "{\"prompt\":\"x\"}", "<KS-IMAGE>", "</ks-image>", "{\"id\":\"c0\"}",
            "<!--mocca-reaction:❤️-->", "`code`", "\t", "<kg", "e\u{301}"]
        for _ in 0..<1000 {
            var value = ""
            for _ in 0..<25 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                value += pieces[Int(seed % UInt64(pieces.count))]
            }
            fixtures.append(value)
        }
        let plain = String(repeating: "ordinary 中文 🐈 reply\n", count: 12000)
        let code = String(repeating: "let values: Array<Int> = []\n", count: 16000)
        fixtures += [plain, "```swift\n" + code + "```", plain + fixtures[26]]
        let behavior = fixtures.map(result)
        var work: [String: Any] = [:]
        for (name, text) in [("ordinaryLongReply", plain), ("angleBracketCode", code),
                             ("imageControls", fixtures[26])] {
            fullImageRegexPasses = 0; candidateIndexBuilds = 0
            let reaction = AIMessageReactionCodec.parse(text)
            let image = ExternalImageGenerationCodec.parse(reaction.content)
            let search = SearchImageSelectionCodec.parse(image.displayText, candidates: candidates)
            work[name] = ["imageRegexPasses": fullImageRegexPasses,
                          "candidateIndexBuilds": candidateIndexBuilds,
                          "finalUTF8": search.displayText.utf8.count]
        }
        let output: [String: Any] = ["cases": fixtures.count, "behavior": behavior, "work": work]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
