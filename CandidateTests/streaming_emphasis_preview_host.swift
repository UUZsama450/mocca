
private var assertions = 0
@MainActor private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    assertions += 1
    if !condition() { fatalError("FAIL: \(label)") }
}

private struct Span: Equatable {
    let text: String
    let intent: UInt
}

private func spans(_ value: AttributedString) -> [Span] {
    value.runs.map { Span(text: String(value[$0.range].characters), intent: $0.inlinePresentationIntent?.rawValue ?? 0) }
}

private func inlineSources(_ blocks: [MarkdownRenderBlock]) -> [String] {
    blocks.flatMap { block -> [String] in
        switch block.kind {
        case .text(let text), .quote(let text), .heading(_, let text): return [text]
        case .list(let entries): return entries.flatMap { [$0.content] + $0.nestedQuoteLines }
        case .table(let table): return table.header + table.rows.flatMap { $0 }
        case .code, .horizontalRule: return []
        }
    }
}

private func rendered(_ source: String, streaming: Bool = true) -> [Span] {
    inlineSources(MarkdownRenderParser.parse(source, previewsIncompleteEmphasis: streaming))
        .flatMap { spans(MarkdownRenderCache.makeAttributedText(for: $0)) }
}

private func plain(_ source: String, streaming: Bool = true) -> String {
    rendered(source, streaming: streaming).map(\.text).joined(separator: "")
}

private func baselineBlocks(_ source: String) -> [MarkdownRenderBlock] {
    BaselineMarkdownRenderParser.parse(source).map { block in
        let kind: MarkdownRenderBlock.Kind
        switch block.kind {
        case .text(let value): kind = .text(value)
        case .quote(let value): kind = .quote(value)
        case .heading(let level, let value): kind = .heading(level: level, text: value)
        case .code(let language, let code, let closed): kind = .code(language: language, code: code, isClosed: closed)
        case .table(let value): kind = .table(value)
        case .horizontalRule: kind = .horizontalRule
        case .list(let entries): kind = .list(entries.map {
            MarkdownListEntry(marker: $0.marker, content: $0.content, isOrdered: $0.isOrdered, nestedQuoteLines: $0.nestedQuoteLines)
        })
        }
        return MarkdownRenderBlock(id: block.id, kind: kind)
    }
}

// The screenshots: style is present from the first actual content character,
// remains present through a split closing delimiter, and matches final parsing.
let samples: [(String, String, InlinePresentationIntent)] = [
    ("*", "把自己揉吧揉吧揉成一坨脑花的形状", .emphasized),
    ("**", "谁在控制大脑", .stronglyEmphasized),
    ("*", "hello world 🧑🏽‍💻 é", .emphasized),
    ("**", "你好，世界！", .stronglyEmphasized)
]
for (marker, content, intent) in samples {
    for end in Array(content.indices.dropFirst()) + [content.endIndex] {
        let piece = String(content[..<end])
        let value = rendered(marker + piece)
        check(value.map(\.text).joined() == piece, "visible prefix: \(marker + piece)")
        check(value.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .allSatisfy { $0.intent & intent.rawValue != 0 }, "early style: \(marker + piece)")
    }
    for closingLength in 0...marker.count {
        let input = marker + content + String(marker.prefix(closingLength))
        check(plain(input) == content, "split closing delimiter: \(input)")
        check(rendered(input).allSatisfy { $0.intent & intent.rawValue != 0 }, "stable close style")
    }
    check(rendered(marker + content + marker) == rendered(marker + content + marker, streaming: false), "complete style parity")
}

let literals = [
    "2 * 3", "2*3", "a*b", "foo*bar", "*.swift", "src/*.swift", "https://example.com/*path",
    #"\*literal"#, #"\**literal"#, "(*´ω", "(*´ω｀*)", "(*hello", "（*ω", "（*ω*）",
    "`*code", "`**code**`", "``*code``", "[name](https://example.com/*path",
    "<tag value=\"*word", "$a*b", "_word *word", "***ambiguous", "**", "*",
    "**unfinished\n\n", "**unfinished\n \n", "**unfinished\n\nordinary text",
    "    *indented code", "\t**indented code", "**bold \\**literal", "*️⃣", "**bold *️⃣words"
]
for text in literals {
    check(MarkdownRenderParser.parse(text, previewsIncompleteEmphasis: true) == MarkdownRenderParser.parse(text), "literal/ambiguous unchanged: \(text)")
}

let supported = [
    ("那**谁在控制", "那谁在控制"), ("**粗体 *斜体", "粗体 斜体"),
    ("*斜体 **粗体", "斜体 粗体"), ("**粗体 `*code*` 继续", "粗体 *code* 继续"),
    ("**粗体 (a*b) 继续", "粗体 (a*b) 继续"), ("**粗体\\*星号", "粗体*星号"),
    ("**中文 \n继续", "中文 \n继续"), ("普通段落\n\n*新段落", "普通段落\n\n新段落"),
    ("# **标题", "标题"), ("> *引用", "引用"), ("- **列表", "列表"),
    ("*已结束* 后面 **新强调", "已结束 后面 新强调"),
    ("*old\n\n*new", "*old\n\nnew")
]
for (text, expected) in supported { check(plain(text) == expected, "supported: \(text) -> \(plain(text))") }

let codeAndTables = [
    "```swift\n**unfinished", "```\n*literal\n```", "~~~\n**literal\n~~~",
    "| 列 |\n| --- |\n| **literal |", "---", "***", "- item\n  > *nested quote"
]
for text in codeAndTables {
    check(MarkdownRenderParser.parse(text, previewsIncompleteEmphasis: true) == MarkdownRenderParser.parse(text), "structured unchanged: \(text)")
}

// Compare the real unchanged final parser with the frozen baseline, including
// every prefix. A failed or cancelled reply must restore the exact raw Markdown.
let corpus = literals + supported.map(\.0) + codeAndTables + samples.map { $0.0 + $0.1 + $0.0 } + [
    "中文**“强调”**后续", "中文**\"强调\"**后续", "**  正文。 **", "(*^▽^*)",
    "**列表\n\n后续**", "1. **列表\n正文 **", "é👨‍👩‍👧‍👦 **组合字符**", "*old\n\n*new"
]
for text in corpus {
    for end in [text.startIndex] + Array(text.indices.dropFirst()) + [text.endIndex] {
        let input = String(text[..<end])
        let current = MarkdownRenderParser.parse(input)
        check(current == baselineBlocks(input), "final block parity: \(input)")
        for source in inlineSources(current) {
            check(spans(MarkdownRenderCache.makeAttributedText(for: source)) == spans(BaselineMarkdownRenderCache.makeAttributedText(for: source)), "final inline parity")
        }
    }
}
print("SEMANTICS_PASS assertions=\(assertions)")

private func baselineRender(_ source: String) -> Int {
    let blocks = BaselineMarkdownRenderParser.parse(source)
    var result = 0
    for block in blocks {
        let values: [String]
        switch block.kind {
        case .text(let text), .quote(let text), .heading(_, let text): values = [text]
        case .list(let entries): values = entries.flatMap { [$0.content] + $0.nestedQuoteLines }
        case .table(let table): values = table.header + table.rows.flatMap { $0 }
        case .code, .horizontalRule: values = []
        }
        for value in values { result += BaselineMarkdownRenderCache.makeAttributedText(for: value).characters.count }
    }
    return result
}
private func candidateRender(_ source: String) -> Int {
    inlineSources(MarkdownRenderParser.parse(source, previewsIncompleteEmphasis: true))
        .reduce(0) { $0 + MarkdownRenderCache.makeAttributedText(for: $1).characters.count }
}
private func milliseconds(_ body: () -> Int) -> (Double, Int) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = body()
    return ((ProcessInfo.processInfo.systemUptime - start) * 1000, value)
}
private func percentile(_ values: [Double], _ p: Double) -> Double {
    values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * p))]
}
var checksum = 0
for length in [10_000, 40_000] {
    let prose = String(repeating: "中文 streaming prose é 🐈 ", count: length / 25)
    for (label, input) in [("plain", prose), ("active-emphasis", "**" + prose), ("history-tail", prose + "\n\n**末尾强调") ] {
        _ = baselineRender(input)
        _ = candidateRender(input)
        var before: [Double] = [], after: [Double] = []
        for iteration in 0..<16 {
            let value = input + "\(iteration)"
            let first = iteration.isMultiple(of: 2)
            let a = milliseconds { first ? baselineRender(value) : candidateRender(value) }
            let b = milliseconds { first ? candidateRender(value) : baselineRender(value) }
            before.append(first ? a.0 : b.0)
            after.append(first ? b.0 : a.0)
            checksum += a.1 + b.1
        }
        let scan = milliseconds { StreamingEmphasisPreview.completing(input)?.utf8.count ?? 0 }
        print(String(format: "PERF %@ bytes=%d baseline_p50=%.3f candidate_p50=%.3f ratio=%.3f baseline_p95=%.3f candidate_p95=%.3f preview_only=%.3f ms", label, input.utf8.count, percentile(before, 0.5), percentile(after, 0.5), percentile(after, 0.5) / percentile(before, 0.5), percentile(before, 0.95), percentile(after, 0.95), scan.0))
    }
}
print("CHECKSUM \(checksum)")
