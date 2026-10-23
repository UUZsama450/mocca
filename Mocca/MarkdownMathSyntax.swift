import Foundation

/// Delimiter recognition only. It never evaluates TeX or changes stored messages.
enum MarkdownMathSyntax {
    struct Token {
        let marker: String
        let range: NSRange
        let source: String
        let latex: String
        let display: Bool
        let isClosed: Bool
    }
    struct Prepared {
        let markdown: String
        let tokens: [Token]
    }

    static func mayContainMath(_ source: String) -> Bool {
        source.utf8.contains(36) || (source.utf8.contains(92) && (source.contains(#"\("#) || source.contains(#"\["#)))
    }

    static func containsClosedMath(_ source: String) -> Bool {
        mayContainMath(source) && prepare(source).tokens.contains(where: \.isClosed)
    }

    static func prepare(_ source: String) -> Prepared {
        guard mayContainMath(source) else { return Prepared(markdown: source, tokens: []) }
        let units = Array(source.utf16)
        let original = source as NSString
        var prefix = "\u{F0000}math"
        while source.contains(prefix) { prefix += "m" }
        var tokens: [Token] = []
        var output = ""
        var copiedThrough = 0
        var index = 0
        // Index backtick runs once. Unmatched runs must not repeatedly scan the suffix.
        var runs: [Int: [Int]] = [:]
        var runLengths: [Int: Int] = [:]
        var scan = 0
        while scan < units.count {
            if units[scan] == 92 { scan += 2; continue }
            if units[scan] == 96 {
                let start = scan
                while scan < units.count, units[scan] == 96 { scan += 1 }
                runs[scan - start, default: []].append(start)
                runLengths[start] = scan - start
            } else { scan += 1 }
        }
        var nextRun: [Int: Int] = [:]
        for positions in runs.values {
            for (a, b) in zip(positions, positions.dropFirst()) { nextRun[a] = b }
        }
        while index < units.count {
            if (units[index] == 96 || units[index] == 126), let end = fenceEnd(at: index, in: units) {
                index = end
                continue
            }
            if let length = runLengths[index] {
                if let close = nextRun[index] {
                    let between = original.substring(with: NSRange(location: index, length: close - index))
                    if length >= 3 || between.range(of: #"\r?\n[ \t]*\r?\n"#, options: .regularExpression) == nil {
                        index = close + length
                        continue
                    }
                }
                index += length
                continue
            }
            // Link destinations / autolinks are URL data, not formula prose.
            if units[index] == 93, index + 1 < units.count, units[index + 1] == 40 {
                index += 2
                var depth = 1
                while index < units.count, depth > 0 {
                    if units[index] == 92 { index += 2; continue }
                    if units[index] == 40 { depth += 1 }
                    if units[index] == 41 { depth -= 1 }
                    index += 1
                }
                continue
            }
            if units[index] == 60 {
                if let close = units[index...].firstIndex(of: 62) { index = close + 1; continue }
            }
            var width = 0
            var display = false
            var closeFirst: UInt16 = 0
            var closeSecond: UInt16?
            if units[index] == 36 {
                display = index + 1 < units.count && units[index + 1] == 36
                width = display ? 2 : 1
                closeFirst = 36
                closeSecond = display ? 36 : nil
                // An opening dollar cannot be followed by whitespace.
                if !display, index + 1 == units.count || isSpace(units[index + 1]) {
                    index += width; continue
                }
            } else if units[index] == 92, index + 1 < units.count,
                      units[index + 1] == 40 || units[index + 1] == 91 {
                width = 2
                display = units[index + 1] == 91
                closeFirst = 92
                closeSecond = display ? 93 : 41
            } else {
                index += units[index] == 92 ? 2 : 1
                continue
            }
            let bodyStart = index + width
            var end = bodyStart
            var close: Int?
            // Consume one delimiter span at a time. Size limits belong to the
            // typesetter, so an oversized formula still falls back intact.
            let limit = units.count
            while end < limit {
                if !display, units[end] == 10 || units[end] == 13 || units[end] == 96 { break }
                if units[end] == closeFirst,
                   closeSecond == nil || (end + 1 < limit && units[end + 1] == closeSecond) {
                    let after = end + width
                    let validDollar = width != 1 || (end > bodyStart && !isSpace(units[end - 1])
                        && (after == units.count || !(48...57).contains(units[after]) && units[after] != 36))
                    if validDollar { close = end; break }
                    if width == 1 { break }
                }
                end += units[end] == 92 ? 2 : 1
            }
            if close == nil, width == 1 { index += 1; continue }
            // Unclosed explicit math stays literal; no speculative typesetting.
            let consumed = close.map { $0 + width } ?? min(end, units.count)
            guard consumed >= index + width else { index += width; continue }
            output += original.substring(with: NSRange(location: copiedThrough, length: index - copiedThrough))
            let marker = prefix + String(tokens.count) + "\u{F0001}"
            let raw = original.substring(with: NSRange(location: index, length: consumed - index))
            let latex = original.substring(with: NSRange(location: bodyStart, length: (close ?? consumed) - bodyStart))
            tokens.append(Token(marker: marker, range: NSRange(location: index, length: consumed - index), source: raw, latex: latex, display: display, isClosed: close != nil))
            if display, close != nil, index > 0, units[index - 1] != 10 { output += "\n" }
            output += marker
            if display, close != nil, consumed < units.count, units[consumed] != 10 { output += "\n" }
            index = consumed
            copiedThrough = consumed
        }
        guard !tokens.isEmpty else { return Prepared(markdown: source, tokens: []) }
        output += original.substring(from: copiedThrough)
        return Prepared(markdown: output, tokens: tokens)
    }

    static func displayOpeningLines(in source: String) -> Set<Int> {
        let tokens = prepare(source).tokens.filter(\.display)
        guard !tokens.isEmpty else { return [] }
        let units = Array(source.utf16)
        var cursor = 0
        var line = 0
        var onlyIndent = true
        var result: Set<Int> = []
        for token in tokens {
            while cursor < token.range.location {
                if units[cursor] == 10 { line += 1; onlyIndent = true }
                else if units[cursor] != 32 && units[cursor] != 9 { onlyIndent = false }
                cursor += 1
            }
            if onlyIndent { result.insert(line) }
        }
        return result
    }

    /// Keep multiline display math opaque to Markdown's heading/list/table rules.
    static func displayClosingDelimiter(for line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("$$"), !value.dropFirst(2).contains("$$") { return "$$" }
        if value.hasPrefix(#"\["#), !value.dropFirst(2).contains(#"\]"#) { return #"\]"# }
        return nil
    }

    private static func fenceEnd(at index: Int, in units: [UInt16]) -> Int? {
        var prefix = index
        while prefix > 0, units[prefix - 1] == 32 || units[prefix - 1] == 9 { prefix -= 1 }
        guard prefix == 0 || units[prefix - 1] == 10 else { return nil }
        let marker = units[index]
        var start = index
        while start < units.count, units[start] == marker { start += 1 }
        let length = start - index
        guard length >= 3 else { return nil }
        var cursor = start
        while cursor < units.count {
            if units[cursor] == 10 {
                var end = cursor + 1
                while end < units.count, units[end] == 32 || units[end] == 9 { end += 1 }
                let runStart = end
                while end < units.count, units[end] == marker { end += 1 }
                if end - runStart >= length {
                    var tail = end
                    while tail < units.count, units[tail] == 32 || units[tail] == 9 || units[tail] == 13 { tail += 1 }
                    if tail == units.count || units[tail] == 10 { return tail }
                }
            }
            cursor += 1
        }
        return units.count
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13
    }
}
