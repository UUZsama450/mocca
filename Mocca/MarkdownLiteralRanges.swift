import Foundation

/// Ranges which must stay literal before Markdown rendering. Control codecs use
/// UTF-16 offsets, just like NSRegularExpression; no replacement is made here.
struct MarkdownLiteralRanges {
    private struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    private let units: [UInt16]
    private let lines: [Line]
    private(set) var ranges: [NSRange] = []

    init(_ source: String, isStreaming: Bool = false) {
        units = Array(source.utf16)
        var rows: [Line] = []
        var start = 0
        while start < units.count {
            var end = start
            while end < units.count, !Self.isNewline(units[end]) { end += 1 }
            let contentEnd = end
            if end < units.count {
                end += 1
                if units[end - 1] == 13, end < units.count, units[end] == 10 { end += 1 }
            }
            rows.append(Line(start: start, contentEnd: contentEnd, end: end))
            start = end
        }
        lines = rows

        var blocks: [NSRange] = []
        var fence: (start: Int, marker: UInt16, width: Int, quoteDepth: Int)?
        var indentedStart: Int?
        var indentedEnd = 0
        for line in lines {
            let prefix = Self.contentStart(line, units: units)
            let cursor = prefix.index
            if let open = fence, prefix.quoteDepth < open.quoteDepth {
                blocks.append(NSRange(location: open.start, length: line.start - open.start))
                fence = nil
            }
            if let open = fence {
                var end = cursor
                while end < line.contentEnd, units[end] == open.marker { end += 1 }
                if end - cursor >= open.width,
                   units[end..<line.contentEnd].allSatisfy(Self.isHorizontalSpace) {
                    blocks.append(NSRange(location: open.start, length: line.end - open.start))
                    fence = nil
                }
                continue
            }
            let blank = units[line.start..<line.contentEnd].allSatisfy(Self.isHorizontalSpace)
            // Blank lines between indented code lines are part of the example.
            if prefix.indentation >= 4 || (indentedStart != nil && blank) {
                if indentedStart == nil { indentedStart = line.start }
                indentedEnd = line.end
                continue
            }
            if let begin = indentedStart {
                blocks.append(NSRange(location: begin, length: indentedEnd - begin))
                indentedStart = nil
            }
            if cursor < line.contentEnd, units[cursor] == 96 || units[cursor] == 126 {
                let marker = units[cursor]
                var end = cursor
                while end < line.contentEnd, units[end] == marker { end += 1 }
                if end - cursor >= 3,
                   marker != 96 || !units[end..<line.contentEnd].contains(96) {
                    fence = (line.start, marker, end - cursor, prefix.quoteDepth)
                    continue
                }
            }
        }
        if let open = fence {
            blocks.append(NSRange(location: open.start, length: units.count - open.start))
        }
        if let begin = indentedStart {
            blocks.append(NSRange(location: begin, length: indentedEnd - begin))
        }
        ranges = blocks

        // Inline code pairs equal-length backtick runs, and cannot cross a block
        // boundary. Index runs once instead of rescanning every unmatched suffix.
        var blockIndex = 0
        var segmentStart: Int?
        var segmentEnd = 0
        for line in lines {
            while blockIndex < blocks.count, NSMaxRange(blocks[blockIndex]) <= line.start { blockIndex += 1 }
            let blocked = blockIndex < blocks.count && blocks[blockIndex].location < line.end
            let blank = units[line.start..<line.contentEnd].allSatisfy(Self.isHorizontalSpace)
            if blocked || blank {
                if let begin = segmentStart { scanInline(begin..<segmentEnd, isStreaming: isStreaming) }
                segmentStart = nil
            } else {
                if segmentStart == nil { segmentStart = line.start }
                segmentEnd = line.end
            }
        }
        if let begin = segmentStart { scanInline(begin..<segmentEnd, isStreaming: isStreaming) }
        ranges.sort { $0.location < $1.location }
    }

    func contains(_ offset: Int) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= offset { low = middle + 1 } else { high = middle }
        }
        return low < ranges.count && ranges[low].location <= offset
    }

    func allowsMarker(at offset: Int) -> Bool {
        !contains(offset) && !isEscaped(offset)
    }

    private func isEscaped(_ offset: Int) -> Bool {
        var cursor = offset
        while cursor > 0, units[cursor - 1] == 92 { cursor -= 1 }
        return (offset - cursor) % 2 == 1
    }

    private mutating func scanInline(_ segment: Range<Int>, isStreaming: Bool) {
        var runs: [(start: Int, width: Int)] = []
        var cursor = segment.lowerBound
        while cursor < segment.upperBound {
            if units[cursor] != 96 { cursor += 1; continue }
            let start = cursor
            while cursor < segment.upperBound, units[cursor] == 96 { cursor += 1 }
            runs.append((start, cursor - start))
        }
        var following: [Int: Int] = [:]
        var next = Array<Int?>(repeating: nil, count: runs.count)
        for index in runs.indices.reversed() {
            next[index] = following[runs[index].width]
            following[runs[index].width] = index
        }
        var index = 0
        while index < runs.count {
            let run = runs[index]
            if isEscaped(run.start) { index += 1; continue }
            if let close = next[index] {
                ranges.append(NSRange(location: run.start, length: runs[close].start + run.width - run.start))
                index = close + 1
            } else if isStreaming {
                ranges.append(NSRange(location: run.start, length: segment.upperBound - run.start))
                break
            } else { index += 1 }
        }
    }

    private static func contentStart(_ line: Line, units: [UInt16]) -> (index: Int, indentation: Int, quoteDepth: Int) {
        var cursor = line.start
        var indentation = 0
        var quotes = 0
        while cursor < line.contentEnd {
            if units[cursor] == 32 { indentation += 1; cursor += 1 }
            else if units[cursor] == 9 { indentation += 4; cursor += 1 }
            else if units[cursor] == 62 {
                quotes += 1; cursor += 1; indentation = 0
                if cursor < line.contentEnd, units[cursor] == 32 { cursor += 1 }
            } else { break }
        }
        // A fence may start on the first line of a list item.
        var afterList = cursor
        if afterList < line.contentEnd, [42, 43, 45].contains(units[afterList]) { afterList += 1 }
        else {
            while afterList < line.contentEnd, (48...57).contains(units[afterList]) { afterList += 1 }
            if afterList > cursor, afterList < line.contentEnd, [41, 46].contains(units[afterList]) { afterList += 1 }
            else { afterList = cursor }
        }
        if afterList > cursor, afterList < line.contentEnd, isHorizontalSpace(units[afterList]) {
            cursor = afterList + 1
            while cursor < line.contentEnd, isHorizontalSpace(units[cursor]) { cursor += 1 }
        }
        return (cursor, indentation, quotes)
    }

    private static func isHorizontalSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }
    private static func isNewline(_ unit: UInt16) -> Bool { [10, 13, 11, 12, 0x85, 0x2028, 0x2029].contains(unit) }

    static func removing(_ ranges: [NSRange], from source: String) -> String {
        guard !ranges.isEmpty else { return source }
        let text = source as NSString
        var output = ""
        var cursor = 0
        for range in ranges {
            output += text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            cursor = NSMaxRange(range)
        }
        return output + text.substring(from: cursor)
    }

    static func hidingTrailingPrefix(in source: String, prefixes: [String]) -> String {
        guard let start = source.lastIndex(of: "<") else { return source }
        let maximum = prefixes.map(\.count).max() ?? 0
        let tail = source[start...].prefix(maximum + 1)
        guard tail.count <= maximum, prefixes.contains(where: { $0.hasPrefix(tail.lowercased()) }),
              MarkdownLiteralRanges(source, isStreaming: true).allowsMarker(at: start.utf16Offset(in: source)) else { return source }
        return String(source[..<start])
    }

    static func hidingIncompleteMarker(in source: String, opening: String, closing: String,
                                       caseInsensitive: Bool = false) -> String {
        let options: String.CompareOptions = caseInsensitive ? [.backwards, .caseInsensitive] : [.backwards]
        if let start = source.range(of: opening, options: options)?.lowerBound,
           MarkdownLiteralRanges(source, isStreaming: true).allowsMarker(at: start.utf16Offset(in: source)),
           source[start...].range(of: closing, options: caseInsensitive ? [.caseInsensitive] : []) == nil {
            return String(source[..<start])
        }
        return hidingTrailingPrefix(in: source, prefixes: [opening])
    }

    static func trimmingTrailingWhitespace(_ source: String) -> String {
        trim(source, literals: MarkdownLiteralRanges(source, isStreaming: true), leading: false)
    }

    private static func trim(_ source: String, literals: MarkdownLiteralRanges, leading: Bool) -> String {
        var start = source.startIndex
        var end = source.endIndex
        var startOffset = 0
        var endOffset = source.utf16.count
        let firstLiteral = literals.ranges.first?.location ?? endOffset
        let lastLiteral = literals.ranges.last.map(NSMaxRange) ?? 0
        if leading {
            while start < end, startOffset < firstLiteral, source[start].isWhitespace {
                startOffset += source[start].utf16.count
                start = source.index(after: start)
            }
        }
        while end > start, endOffset > lastLiteral {
            let previous = source.index(before: end)
            guard source[previous].isWhitespace else { break }
            endOffset -= source[previous].utf16.count
            end = previous
        }
        return String(source[start..<end])
    }

    /// Preserve code indentation, blank lines and line endings byte-for-byte.
    /// Keep the established prose whitespace cleanup outside literal regions.
    static func cleaningDisplayWhitespace(_ source: String) -> String {
        let literals = MarkdownLiteralRanges(source, isStreaming: true)
        let original = source as NSString
        var output = ""
        var previousBlank = false
        var rangeIndex = 0
        for line in literals.lines {
            while rangeIndex < literals.ranges.count, NSMaxRange(literals.ranges[rangeIndex]) <= line.start { rangeIndex += 1 }
            let literal = rangeIndex < literals.ranges.count && literals.ranges[rangeIndex].location < line.end
            if literal {
                output += original.substring(with: NSRange(location: line.start, length: line.end - line.start))
                previousBlank = false
            } else {
                let body = original.substring(with: NSRange(location: line.start, length: line.contentEnd - line.start))
                let blank = body.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank || !previousBlank { output += body + (line.end > line.contentEnd ? "\n" : "") }
                previousBlank = blank
            }
        }
        guard !literals.ranges.isEmpty else { return output.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trim(output, literals: MarkdownLiteralRanges(output, isStreaming: true), leading: true)
    }
}
