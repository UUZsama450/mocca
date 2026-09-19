import Foundation

/// Integration tests of the complete production actor, linked to the real pinned
/// HighlighterSwift engine. These assertions concern text/ranges and isolation,
/// not UIKit rendering or iPhone frame time.
@main
@MainActor
enum CodeSyntaxHighlighterHostTests {
    private static var assertions = 0
    private static var timings: [(String, Double)] = []

    private static func configuredLimit(_ name: String) -> Int {
        let prefix = "--\(name)="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
              let limit = Int(argument.dropFirst(prefix.count)), limit > 0 else {
            fatalError("Run through CodeSyntaxRunHostTests.py to read \(name) from production")
        }
        return limit
    }

    private struct Fixture: Sendable {
        let language: String
        let text: String
    }

    static func main() async {
        if CommandLine.arguments.contains("--benchmark-limits") {
            await benchmarkCandidateLimits()
            print("CODE_SYNTAX_BUDGET_BENCH=PASS")
            return
        }
        let coldText = "// cold engine\nlet greeting = \"你好 👩🏽‍💻\"\nprint(greeting)"
        let cold = await timed("cold_engine_and_swift") {
            await CodeSyntaxHighlighter.shared.highlight(
                text: coldText, language: "swift", theme: .light, isStreaming: false)
        }
        check(!cold.isEmpty, "real engine initializes and returns Swift colours")
        await commonLanguagesAndAliases()
        await unicodeAndRawSourceFidelity()
        await partialStreamsAndFoldExpansion()
        await themeAndConcurrentRequestIsolation()
        await lengthAndTokenBudgets()
        await cacheChurnAndBenchmarks()
        for (name, milliseconds) in timings {
            print("HOST_BENCH name=\(name) milliseconds=\(String(format: "%.3f", milliseconds))")
        }
        print("CODE_SYNTAX_HOST_TESTS=PASS assertions=\(assertions)")
        print("SCOPE=macOS production-backend semantics; no iOS layout, UI, or iPhone performance acceptance")
        print("CACHE_BOUND_LIMITATION=private cache capacity counters were not exposed; churn verifies result correctness, not measured resident bounds")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError("CODE_SYNTAX_HOST_TESTS=FAIL \(message)") }
    }

    private static func highlight(
        _ text: String, _ language: String = "swift",
        theme: CodeSyntaxTheme = .light, streaming: Bool = false
    ) async -> [CodeSyntaxColorRun] {
        let runs = await CodeSyntaxHighlighter.shared.highlight(
            text: text, language: language, theme: theme, isStreaming: streaming)
        validate(runs, text: text)
        return runs
    }

    private static func validate(_ runs: [CodeSyntaxColorRun], text: String) {
        let utf16 = Array(text.utf16)
        var previousEnd = 0
        for run in runs {
            check(run.range.location >= previousEnd, "colour runs are sorted and disjoint")
            check(run.range.length > 0, "no zero-length colour run")
            check(run.range.location <= utf16.count
                && run.range.length <= utf16.count - run.range.location,
                  "UTF16 range stays within exact input")
            check(run.rgb <= 0xFFFFFF, "colour is RGB only")
            // A UTF16 colour boundary may divide grapheme clusters but must never
            // split a surrogate pair, which would corrupt attributed-string use.
            for boundary in [run.range.location, NSMaxRange(run.range)]
                where boundary > 0 && boundary < utf16.count {
                check(!(0xD800...0xDBFF).contains(utf16[boundary - 1])
                    || !(0xDC00...0xDFFF).contains(utf16[boundary]),
                      "range boundary does not split an emoji surrogate pair")
            }
            previousEnd = NSMaxRange(run.range)
        }
    }

    private static func colour(
        of needle: String, in text: String, runs: [CodeSyntaxColorRun],
        options: NSString.CompareOptions = []
    ) -> UInt32? {
        let range = (text as NSString).range(of: needle, options: options)
        check(range.location != NSNotFound, "fixture contains expected token")
        return runs.first { NSLocationInRange(range.location, $0.range) }?.rgb
    }

    private static func commonLanguagesAndAliases() async {
        let fixtures = [
            Fixture(language: "swift", text: "let count = 42\nprint(\"hello\")"),
            Fixture(language: "python", text: "def greet(name):\n    return f\"hello {name}\" # 注释"),
            Fixture(language: "javascript", text: "const answer = 42; console.log(\"hello\");"),
            Fixture(language: "typescript", text: "interface Person { name: string }; const age: number = 42;"),
            Fixture(language: "json", text: "{\"message\": \"你好\", \"ok\": true, \"value\": 42}"),
            Fixture(language: "xml", text: "<div class=\"demo\">&lt;你好 😀&amp;</div>"),
            Fixture(language: "css", text: ".hello { color: #ff00cc; margin: 12px; }"),
            Fixture(language: "bash", text: "#!/bin/bash\necho \"$HOME\" # fixture only"),
            Fixture(language: "sql", text: "SELECT name FROM users WHERE id = 42;"),
            Fixture(language: "cpp", text: "#include <string>\nint main() { return 42; }"),
            Fixture(language: "java", text: "public class Hello { private int count = 42; }"),
            Fixture(language: "go", text: "package main\nfunc main() { println(\"hello\") }"),
            Fixture(language: "rust", text: "fn main() { let value: i32 = 42; println!(\"{}\", value); }"),
            Fixture(language: "yaml", text: "title: hello\nenabled: true\nitems:\n  - 42")
        ]
        for fixture in fixtures {
            let runs = await highlight(fixture.text, fixture.language)
            check(!runs.isEmpty, "common language \(fixture.language) is supported")
            check(Set(runs.map(\.rgb)).count > 1, "\(fixture.language) actually distinguishes token colours")
        }
        let aliases = [
            (" PY ", "python"), ("python3", "python"), ("js", "javascript"),
            ("jsx", "javascript"), ("tsx", "typescript"), ("sh", "bash"),
            ("c++", "cpp"), ("html", "xml"), ("yml", "yaml"),
            ("rs", "rust"), ("golang", "go"), ("swift linenos", "swift")
        ]
        for (alias, canonical) in aliases {
            check(CodeSyntaxHighlighter.normalizedLanguage(alias) == canonical,
                  "language alias normalizes: \(alias)")
            let fixture = fixtures.first { $0.language == canonical }!
            let aliased = await highlight(fixture.text, alias)
            let standard = await highlight(fixture.text, canonical)
            check(aliased == standard, "alias reaches the same real grammar: \(alias)")
        }
        for language in ["", " ", "text", "txt", "plain", "plaintext", "none", "not-a-real-language", String(repeating: "x", count: 65)] {
            let runs = await highlight("let n = 42 <tag> &amp; 😀", language)
            check(runs.isEmpty, "unknown/plain language falls back without changing source")
        }
        let empty = await highlight("")
        check(empty.isEmpty, "empty source has no colour runs")
    }

    private static func unicodeAndRawSourceFidelity() async {
        let variants = [
            "// 中文 👩🏽‍💻 e\u{301}\r\nlet café = \"😀 &lt; &amp; <tag>\"\r\nprint(café)",
            "// café\nlet answer = \"é\"\n",
            "// cafe\u{301}\nlet answer = \"e\u{301}\"\n",
            "// 𠮷 🇨🇳 🧑‍🚀\nlet value = \"<&> &#x1F600; &quot;\"\n",
            "let words = \"中文\"\r\nlet emoji = \"😀\"\r\n"
        ]
        for text in variants {
            let runs = await highlight(text)
            check(!runs.isEmpty, "Unicode and literal HTML entity source remains highlightable")
            let keyword = colour(of: "let", in: text, runs: runs)
            let quoted = colour(of: "\"", in: text, runs: runs)
            check(keyword != nil && quoted != nil && keyword != quoted,
                  "keyword and string positions remain correct after Unicode/CRLF")
            for literal in ["😀", "&lt;", "&amp;", "<tag>", "&#x1F600;"] where text.contains(literal) {
                // The first emoji may also occur in a comment; inspect the last
                // occurrence to exercise a literal *inside* the string.
                let literalColour = colour(of: literal, in: text, runs: runs, options: .backwards)
                check(literalColour == quoted, "literal entity/emoji remains part of the original string token")
            }
        }
        // Swift considers these Strings equal. Their UTF16 offsets differ, so a
        // normalized String cache key would incorrectly reuse the first ranges.
        let composed = "// é\nlet value = 1"
        let decomposed = "// e\u{301}\nlet value = 1"
        check(composed == decomposed && composed.utf16.count != decomposed.utf16.count,
              "fixture exercises canonical equivalence with different UTF16 length")
        let composedRuns = await highlight(composed)
        let decomposedRuns = await highlight(decomposed)
        check(!composedRuns.isEmpty && !decomposedRuns.isEmpty, "both canonical forms are supported")
        check(colour(of: "let", in: composed, runs: composedRuns)
            == colour(of: "let", in: decomposed, runs: decomposedRuns),
              "cache identity preserves raw source offsets across canonical equivalents")
        let finalComposedRuns = await highlight(composed)
        check(finalComposedRuns == composedRuns, "returning to original canonical form preserves cached ranges")
    }

    private static func partialStreamsAndFoldExpansion() async {
        let streams = [
            Fixture(language: "swift", text: "let greeting = \"你好 👩🏽‍💻\"\n/* unfinished until end */\nprint(greeting)"),
            Fixture(language: "javascript", text: "const text = `hello ${name}`;\n/* many lines\nand an ending */\nconsole.log(text);"),
            Fixture(language: "python", text: "message = \"\"\"中文 😀\nmore lines\"\"\"\n# tail\nprint(message)")
        ]
        for fixture in streams {
            let characters = Array(fixture.text)
            let start = ContinuousClock.now
            var checked = 0
            for end in stride(from: 1, through: characters.count, by: 3) {
                let prefix = String(characters.prefix(end))
                let streamed = await highlight(prefix, fixture.language, streaming: true)
                let settled = await highlight(prefix, fixture.language)
                check(streamed == settled, "partial syntax settles without changing colours for identical text")
                checked += 1
            }
            timings.append(("stream_prefixes_\(fixture.language)_\(checked)", elapsedMilliseconds(since: start)))
            let full = await highlight(fixture.text, fixture.language)
            let streamedFull = await highlight(fixture.text, fixture.language, streaming: true)
            check(full == streamedFull, "completed stream agrees with settled full source")
        }
        let expanded = (0..<60).map { "let item\($0) = \"value 😀 \($0)\" // row \($0)" }.joined(separator: "\n")
        let foldedPrefix = expanded.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
        let expandedRuns = await highlight(expanded)
        let prefixRuns = await highlight(foldedPrefix)
        check(!expandedRuns.isEmpty && !prefixRuns.isEmpty, "fold prefix and expanded source are independently highlightable")
        let expandedAgain = await highlight(expanded)
        let prefixAgain = await highlight(foldedPrefix)
        check(expandedAgain == expandedRuns && prefixAgain == prefixRuns,
              "fold/expand round trip does not reuse a wrong-length source result")
        // Observe the shared opening tokens, without assuming arbitrary truncation
        // preserves a grammar's colours near an unterminated string/comment.
        for token in ["let", "item0", "\"value"] {
            check(colour(of: token, in: expanded, runs: expandedRuns)
                == colour(of: token, in: foldedPrefix, runs: prefixRuns),
                  "unchanged opening tokens keep their colour across fold expansion")
        }
    }

    private static func themeAndConcurrentRequestIsolation() async {
        let fixtures = [
            Fixture(language: "swift", text: "// 甲😀\nlet a = \"one\""),
            Fixture(language: "python", text: "# 乙e\u{301}\ndef twice(n):\n    return n * 2"),
            Fixture(language: "javascript", text: "const html = \"&lt;<tag>😀\"; // tail"),
            Fixture(language: "swift", text: "// e\u{301}\nlet pending = \"unfinished")
        ]
        var expected: [[CodeSyntaxColorRun]] = []
        for fixture in fixtures {
            let light = await highlight(fixture.text, fixture.language, theme: .light)
            let dark = await highlight(fixture.text, fixture.language, theme: .dark)
            check(!light.isEmpty && !dark.isEmpty && light != dark, "light/dark themes have distinct real palettes")
            expected.append(light)
            expected.append(dark)
        }
        let outcomes = await withTaskGroup(of: (Int, Int, [CodeSyntaxColorRun]).self) { group in
            for job in 0..<96 {
                let fixtureIndex = (job / 2) % fixtures.count
                let themeIndex = job % 2
                let fixture = fixtures[fixtureIndex]
                group.addTask {
                    let runs = await CodeSyntaxHighlighter.shared.highlight(
                        text: fixture.text, language: fixture.language,
                        theme: themeIndex == 0 ? .light : .dark, isStreaming: job % 3 == 0)
                    return (fixtureIndex, themeIndex, runs)
                }
            }
            var results: [(Int, Int, [CodeSyntaxColorRun])] = []
            for await result in group { results.append(result) }
            return results
        }
        check(outcomes.count == 96, "all concurrent requests finish")
        for (fixtureIndex, themeIndex, runs) in outcomes {
            validate(runs, text: fixtures[fixtureIndex].text)
            check(runs == expected[fixtureIndex * 2 + themeIndex],
                  "concurrent requests cannot mix theme, source, or streaming state")
        }
    }

    private static func lengthAndTokenBudgets() async {
        let streamingLimit = configuredLimit("streamingUTF16Limit")
        let settledLimit = configuredLimit("settledUTF16Limit")
        let runLimit = configuredLimit("runLimit")
        for (limit, streaming) in [(streamingLimit, true), (settledLimit, false)] {
            let exact = "//" + String(repeating: "a", count: limit - 2)
            let exactRuns = await highlight(exact, streaming: streaming)
            check(!exactRuns.isEmpty, "exact UTF16 input limit still highlights")
            let over = await highlight(exact + "a", streaming: streaming)
            check(over.isEmpty, "over-limit input takes whole-source plaintext fallback")
            let emojiOver = "//" + String(repeating: "😀", count: limit / 2)
            let emojiRuns = await highlight(emojiOver, streaming: streaming)
            check(emojiRuns.isEmpty, "limit counts UTF16 units, not emoji Characters")
        }
        let betweenLimits = "//" + String(repeating: "x", count: (streamingLimit + settledLimit) / 2 - 2)
        let stream = await highlight(betweenLimits, streaming: true)
        let settled = await highlight(betweenLimits)
        check(stream.isEmpty && !settled.isEmpty, "large stream can gain highlighting after settling")
        let denseStatement = "let a = 1; "
        let repetitionCount = min(settledLimit / denseStatement.utf16.count, runLimit + 1)
        let manyTokens = String(repeating: denseStatement, count: repetitionCount)
        let start = ContinuousClock.now
        let capped = await highlight(manyTokens)
        timings.append(("many_tokens_budget_\(repetitionCount)", elapsedMilliseconds(since: start)))
        check(capped.isEmpty, "too many colour runs fail closed to full plaintext fallback")
        let manageable = await highlight(String(repeating: "let a = 1; ", count: 100))
        check(!manageable.isEmpty, "normal multi-token block remains highlighted")
    }

    private static func benchmarkCandidateLimits() async {
        // Warm engine startup separately. Streaming avoids settled-result cache
        // hits, allowing repeat measurements of identical work without changing
        // the production implementation or reaching into private cache state.
        _ = await CodeSyntaxHighlighter.shared.highlight(
            text: "let warm = 0", language: "swift", theme: .light, isStreaming: false)
        let activeStreamingLimit = configuredLimit("streamingUTF16Limit")
        let activeSettledLimit = configuredLimit("settledUTF16Limit")
        for size in [8 * 1_024, 16 * 1_024, 32 * 1_024] {
            for dense in [true, false] {
                var samples: [Double] = []
                var runCounts: [Int] = []
                for iteration in 0..<3 {
                    let prefix = dense ? "let a = 1; " : "// plain text "
                    var text = dense
                        ? String(repeating: prefix, count: size / prefix.utf16.count)
                        : "//" + String(repeating: "x", count: size - 2)
                    // Keep each settled sample's source distinct when the input
                    // exceeds the streaming limit, avoiding cache-hit timings.
                    if size > activeStreamingLimit {
                        text = String(text.dropLast()) + String(iteration)
                    }
                    let start = ContinuousClock.now
                    let runs = await CodeSyntaxHighlighter.shared.highlight(
                        text: text, language: "swift", theme: .light,
                        isStreaming: size <= activeStreamingLimit)
                    samples.append(elapsedMilliseconds(since: start))
                    runCounts.append(runs.count)
                }
                let formatted = samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
                print("HOST_BUDGET_BENCH bytes_approx=\(size) dense=\(dense) milliseconds=[\(formatted)] returned_runs=\(runCounts) streaming_limit=\(activeStreamingLimit) settled_limit=\(activeSettledLimit)")
            }
        }
        print("SCOPE=macOS x86_64 host under concurrent app Release build; timings are not iPhone performance acceptance")
    }

    private static func cacheChurnAndBenchmarks() async {
        let anchor = "let cacheAnchor = \"é 😀 <>&amp;\""
        let original = await highlight(anchor)
        // More distinct settled entries than the production cache capacity;
        // validate semantic reuse after eviction without exposing private state.
        for index in 0..<48 {
            let value = await highlight("let entry\(index) = \"cache \(index) 中文\"", theme: index.isMultiple(of: 2) ? .light : .dark)
            check(!value.isEmpty, "cache churn retains valid output")
        }
        let restored = await highlight(anchor)
        check(restored == original, "eviction/recomputation preserves exact result")
        let benchmark = (0..<100).map { "let bench\($0) = \"value \($0) 中文 😀\"" }.joined(separator: "\n")
        _ = await timed("settled_100_lines_first") {
            await CodeSyntaxHighlighter.shared.highlight(
                text: benchmark, language: "swift", theme: .light, isStreaming: false)
        }
        _ = await timed("settled_100_lines_warm_50_calls") {
            var last: [CodeSyntaxColorRun] = []
            for _ in 0..<50 {
                last = await CodeSyntaxHighlighter.shared.highlight(
                    text: benchmark, language: "swift", theme: .light, isStreaming: false)
            }
            return last
        }
        _ = await timed("streaming_100_lines_10_calls") {
            var last: [CodeSyntaxColorRun] = []
            for _ in 0..<10 {
                last = await CodeSyntaxHighlighter.shared.highlight(
                    text: benchmark, language: "swift", theme: .light, isStreaming: true)
            }
            return last
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    private static func timed<T>(
        _ name: String, operation: () async -> T
    ) async -> T {
        let start = ContinuousClock.now
        let result = await operation()
        timings.append((name, elapsedMilliseconds(since: start)))
        return result
    }
}
