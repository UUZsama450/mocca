// Appended to the exact extracted baseline and single-guard candidate.
let unit = "春天的风吹过山坡，河水绕过村庄。我们沿着小路慢慢走，观察光线、树叶和远处的云。今天把看到的事情认真记下来，明天再接着读。"
var samples: [(String, String)] = [
    ("empty", ""), ("plain", "你好。今天看看窗外，明天还想再来。"),
    ("ascii", "A plain sentence with numbers 123 and punctuation?!"),
    ("unicode", "é 👨‍👩‍👧‍👦 🙂 العربية עברית 中文 \u{200D}\u{FE0F}"),
    ("spaces", "a  b\t c\r\nd\n\n e\n"),
    ("entities", "&amp; &#123; &#x4e00; &lt;hello&gt;"),
    ("link", "[链接](https://example.com/你好?a=1&b=2)"),
    ("html", "<https://example.com> <b>文本</b> <hello@example.com>"),
    ("underscore", "_italic_ __bold__ a_b word__word"),
    ("strike", "~~划线~~ ~波浪~"),
    ("escape", "\\[括号\\] \\_文本\\_ \\\\ 末尾\\"),
    ("stars", "普通 **粗体** *斜体* ***叠加*** 和\\*转义"),
    ("cjkquotes", "中文**“强调”**正文，**\"强调\"**尾部。"),
    ("cjkclose", "**中文。**下一段 **「测试」**随后"),
    ("kaomoji", "示例(´▽`) (*´▽｀*) (≧▽≦) (*^_^*)"),
    ("code", "`inline` ``x ` y`` ```z```"),
    ("unmatched", "a ` b **c d * e `` f"),
    ("combined-markers", "*\u{0301} `\u{FE0F} a **\u{200D} b"),
    ("private-markers", "\u{F0000}\u{F0001}\u{F0002} 没有特殊语法"),
    ("private-cjk", "\u{F0000}\u{F0001}\u{F0002} 中文**“强调”**"),
    ("blocklike", "# 标题\n> 引用\n1. 列表\n---\n| a | b |\n|---|---|"),
    ("rtl", "العربية _نص_ עברית 123 中文"),
]
for length in [16_384, 65_536, 131_072] {
    let plain = (0..<(length / unit.utf16.count + 1)).map { "第\($0)段。" + unit }.joined(separator: "\n\n")
    samples += [("plain-\(length)", plain), ("single-\(length)", plain.replacingOccurrences(of: "\n", with: "")),
                ("tail-star-\(length)", plain + " **尾部加粗**"), ("tail-code-\(length)", plain + " `code`"),
                ("link-\(length)", plain + " [链接](https://example.com)")]
}
// Deterministic mixed delimiter cases exercise the unchanged fallback too.
let fragments = ["文字", "a", "*", "**", "`", "\\", "_", "\n", " ", "🙂", "&amp;", "[x](u)", "“", "”", "(", ")"]
var state: UInt64 = 0x5045
for index in 0..<160 {
    var value = ""
    for _ in 0..<80 {
        state = state &* 6364136223846793005 &+ 1
        value += fragments[Int((state >> 32) % UInt64(fragments.count))]
    }
    samples.append(("mixed-\(index)", value))
}
var checks: [[String: Any]] = []
for (name, text) in samples {
    let baseline = BaselineMarkdown.makeAttributedText(for: text)
    let candidate = CandidateMarkdown.makeAttributedText(for: text)
    checks.append(["name": name, "utf16": text.utf16.count, "attributedEqual": baseline == candidate,
                   "charactersEqual": baseline.characters.elementsEqual(candidate.characters)])
}
var times: [[String: Any]] = []
for (name, text) in samples where name.hasPrefix("plain-") || name.hasPrefix("tail-star-") {
    for repetition in 0..<7 {
        for mode in (repetition.isMultiple(of: 2) ? ["baseline", "candidate"] : ["candidate", "baseline"]) {
            let start = ProcessInfo.processInfo.systemUptime
            let value = mode == "baseline" ? BaselineMarkdown.makeAttributedText(for: text) : CandidateMarkdown.makeAttributedText(for: text)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            times.append(["name":name,"mode":mode,"repetition":repetition,"ms":ms,"characters":value.characters.count])
        }
    }
}
let failures = checks.filter { !($0["attributedEqual"] as! Bool) || !($0["charactersEqual"] as! Bool) }
let result: [String: Any] = ["checks": checks, "failures": failures.count, "times": times,
                           "scope":"Optimized macOS Foundation parser comparison; not iPhone or full app latency"]
let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
FileHandle.standardOutput.write(data)
exit(failures.isEmpty ? 0 : 1)
