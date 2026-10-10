// Compiled with the real inline parser, extracted by check_markdown_inline_repairs.py.
import Foundation

var failures: [String] = []
var checks = 0
@MainActor func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures.append(label) }
}
func native(_ source: String) -> AttributedString {
    try! AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
}
func codeText(_ text: AttributedString) -> String {
    text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        .map { String(text[$0.range].characters) }.joined()
}
@MainActor func expectNative(_ source: String, _ label: String) {
    let expected = native(source)
    let actual = CandidateMarkdown.makeAttributedText(for: source)
    check(actual == expected, "\(label): \(source.debugDescription) expected=\(expected) actual=\(actual)")
}

let nativeCases = [
    "\u{0600}`(*´ω｀*)`", "`(*´ω｀*)\u{0600}`", "`(*´ω｀*)`\u{FE0F}",
    "`\u{FE0F}(*´ω｀*)`", "`\u{0301}(*^_^*)`", "``\u{FE0F}(*´ω｀*)``",
    "`(*´ω｀*)`", "``(*^▽^*)``", "`first\nsecond`", "`first\r\n**second**`",
    "`` one ` tick (*´ω｀*) ``", "``*code`", "\\`(*abc*)`", "\\``(*´ω｀*)`",
    "`(*´ω｀*)\\` *后续*", "\\\\`(*´ω｀*)`", "```(*´ω｀*)``inside```",
    "`中文**“强调”**`", "**前面 `(*´ω｀*)` 后面**", "*前面 ``a ` (*´ω｀*)`` 后面*",
    "a ` unmatched **bold**", "(*ordinary*)", "(*plain text*)", "(*a) (*b)",
    "[**链接**](https://example.com/a)", "![alt](https://example.com/img.png)",
    "<https://example.com/a> <b>html</b>", "`&amp; <tag> [link](u) \\*literal`",
    "é *️⃣ 👨‍👩‍👧‍👦 **粗体**", "\u{F0000}\u{F0001}\u{F0002} `(*´ω｀*)`",
    "[链接](https://example.com/(*^_^*))", "[链接](https://example.com \"(*^_^*)\")"
]
for source in nativeCases { expectNative(source, "native boundary") }

// Stress exact-length code matching, escaped openers and literal backslashes in
// code. Every prefix models tokens arriving before a matching delimiter exists.
let payloads = ["\u{FE0F}(*´ω｀*)", "\u{0301}(*^_^*)", "(*´ω｀*)", "中文**“强调”**", "**「内容」**🙂", "x ` y (*^_^*)", "a\nb (*´ω｀*)", "a\r\nb (*^_^*)"]
for width in 1...6 {
    let ticks = String(repeating: "`", count: width)
    for payload in payloads {
        // Avoid payload delimiters that intentionally end a width-one span.
        if width == 1 && payload.contains("`") { continue }
        for suffix in ["", "\\", "\\\\"] {
            let source = ticks + payload + suffix + ticks
            expectNative(source, "code width \(width)")
            expectNative("\\" + ticks + "`" + payload + suffix + ticks, "escaped opener")
        }
    }
}
for source in ["``(*´ω｀*)``", "`` one ` tick ``", "`first\nsecond`", "`中文**“强调”**`"] {
    for end in source.indices {
        let input = String(source[..<end])
        let candidate = CandidateMarkdown.makeAttributedText(for: input)
        check(codeText(candidate) == codeText(native(input)), "prefix code text: \(input.debugDescription)")
        check(!candidate.characters.contains("\u{F0000}"), "prefix marker leak")
    }
}

let proseCases: [(String, String, String?)] = [
    ("(*´ω｀*)", "(*´ω｀*)", nil), ("(*^_^*) (*^▽^*)", "(*^_^*) (*^▽^*)", nil),
    ("中文**“强调”**", "中文“强调”", "“强调”"),
    ("中文**\"强调\"**", "中文\"强调\"", "\"强调\""),
    ("**中文。**下一段", "中文。下一段", "中文。"),
    ("**「测试」**随后", "「测试」随后", "「测试」"),
    ("**正文\n**后续", "正文\n后续", "正文\n"),
    ("(*未闭合 `(*´ω｀*)` (*^_^*)", "(*未闭合 (*´ω｀*) (*^_^*)", nil),
    ("(*未闭合\n(*^_^*)", "(*未闭合\n(*^_^*)", nil)
]
for (source, expected, bold) in proseCases {
    let result = CandidateMarkdown.makeAttributedText(for: source)
    check(String(result.characters) == expected, "prose characters: \(source.debugDescription)")
    if let bold {
        let actual = result.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(result[$0.range].characters) }.joined()
        check(actual == bold, "prose strong intent: \(source.debugDescription) -> \(actual.debugDescription)")
    }
    check(!result.characters.contains("\u{F0000}"), "no repair marker in copy text")
}
for marker in ["\u{F0000}", "\u{F0000}\u{F0001}", "\u{F0000}\u{F0001}\u{F0002}"] {
    let source = marker + " (*^_^*) 中文**“强调”**"
    let value = CandidateMarkdown.makeAttributedText(for: source)
    check(String(value.characters).hasPrefix(marker), "preserve user private-use characters")
    check(String(value.characters).contains("(*^_^*)"), "kaomoji even if marker space exhausted")
}

// Keep the old deterministic mixed-delimiter corpus as a code-preservation
// invariant. Native code content is authoritative even where prose deliberately
// uses Mocca's CJK/kaomoji compatibility rules.
let fragments = ["文字", "a", "*", "**", "`", "\\", "_", "\n", " ", "🙂", "&amp;", "[x](u)", "“", "”", "(", ")"]
var randomState: UInt64 = 0x5045
for sample in 0..<160 {
    var source = ""
    for _ in 0..<80 {
        randomState = randomState &* 6364136223846793005 &+ 1
        source += fragments[Int((randomState >> 32) % UInt64(fragments.count))]
    }
    let result = CandidateMarkdown.makeAttributedText(for: source)
    check(codeText(result) == codeText(native(source)), "mixed code payload \(sample)")
    check(!result.characters.contains("\u{F0000}"), "mixed marker leak \(sample)")
}
let linked = CandidateMarkdown.makeAttributedText(for: "[中文**“强调”**](https://example.com/a)")
check(String(linked.characters) == "中文“强调”", "repair link label")
check(linked.runs.allSatisfy { $0.link?.absoluteString == "https://example.com/a" }, "retain link attributes during marker removal")

var timings: [[String: Any]] = []
for count in [500, 1_000, 2_000, 4_000] {
    for (label, input) in [
        ("unmatched-kaomoji", String(repeating: "(*a", count: count)),
        ("unmatched-cjk-strong", String(repeating: "文**“ ", count: count)),
        ("repaired-cjk", String(repeating: "中文**“强调”** ", count: count))
    ] {
        var times: [Double] = []
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let output = CandidateMarkdown.makeAttributedText(for: input)
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            if label == "unmatched-kaomoji" { check(String(output.characters) == input, "unmatched literal text") }
            check(!output.characters.contains("\u{F0000}"), "long marker cleanup")
        }
        timings.append(["case": label, "characters": input.count, "medianMs": times.sorted()[1]])
    }
}
let report: [String: Any] = ["checks": checks, "failures": failures, "timings": timings,
    "scope": "Optimized macOS Foundation inline parser; not phone frame time or visual acceptance"]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
exit(failures.isEmpty ? 0 : 1)
