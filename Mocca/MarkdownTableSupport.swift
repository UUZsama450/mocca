import Foundation

enum MarkdownTableColumnAlignment: Hashable, Sendable {
    case leading
    case center
    case trailing
}

struct MarkdownTableContent: Hashable, Sendable {
    let header: [String]
    let alignments: [MarkdownTableColumnAlignment]
    let rows: [[String]]
}

struct MarkdownTableParseResult: Hashable, Sendable {
    let table: MarkdownTableContent
    let nextLineIndex: Int
}

enum MarkdownTableParser {
    static func parse(
        startingAt lineIndex: Int,
        in lines: [String]
    ) -> MarkdownTableParseResult? {
        guard lineIndex >= 0,
              lineIndex + 1 < lines.count,
              let header = splitRow(lines[lineIndex]),
              !header.isEmpty,
              let delimiterCells = splitRow(lines[lineIndex + 1]),
              delimiterCells.count == header.count else {
            return nil
        }

        let alignments = delimiterCells.compactMap(delimiterAlignment)
        guard alignments.count == header.count else { return nil }

        var rows: [[String]] = []
        var cursor = lineIndex + 2
        while cursor < lines.count {
            let line = lines[cursor]
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  var cells = splitRow(line) else {
                break
            }

            if cells.count < header.count {
                cells.append(contentsOf: repeatElement("", count: header.count - cells.count))
            } else if cells.count > header.count {
                cells = Array(cells.prefix(header.count))
            }
            rows.append(cells)
            cursor += 1
        }

        return MarkdownTableParseResult(
            table: MarkdownTableContent(
                header: header,
                alignments: alignments,
                rows: rows
            ),
            nextLineIndex: cursor
        )
    }

    private static func splitRow(_ source: String) -> [String]? {
        let row = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !row.isEmpty else { return nil }

        var cells: [String] = []
        var current = ""
        var activeBacktickRun = 0
        var didSplit = false
        var index = row.startIndex

        while index < row.endIndex {
            let character = row[index]

            if character == "\\" {
                current.append(character)
                let nextIndex = row.index(after: index)
                if nextIndex < row.endIndex {
                    current.append(row[nextIndex])
                    index = row.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }

            if character == "`" {
                var runLength = 0
                var runEnd = index
                while runEnd < row.endIndex, row[runEnd] == "`" {
                    runLength += 1
                    current.append("`")
                    runEnd = row.index(after: runEnd)
                }
                if activeBacktickRun == 0 {
                    activeBacktickRun = runLength
                } else if activeBacktickRun == runLength {
                    activeBacktickRun = 0
                }
                index = runEnd
                continue
            }

            if character == "|", activeBacktickRun == 0 {
                cells.append(cleanCell(current))
                current.removeAll(keepingCapacity: true)
                didSplit = true
            } else {
                current.append(character)
            }
            index = row.index(after: index)
        }

        guard didSplit else { return nil }
        cells.append(cleanCell(current))

        if cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells.isEmpty ? nil : cells
    }

    private static func cleanCell(_ cell: String) -> String {
        cell.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func delimiterAlignment(
        _ source: String
    ) -> MarkdownTableColumnAlignment? {
        var delimiter = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLeadingColon = delimiter.first == ":"
        let hasTrailingColon = delimiter.last == ":"

        if hasLeadingColon {
            delimiter.removeFirst()
        }
        if hasTrailingColon, !delimiter.isEmpty {
            delimiter.removeLast()
        }

        guard delimiter.count >= 3,
              delimiter.allSatisfy({ $0 == "-" }) else {
            return nil
        }

        if hasLeadingColon && hasTrailingColon {
            return .center
        }
        if hasTrailingColon {
            return .trailing
        }
        return .leading
    }
}
