import Foundation

/// One reply remains one stored/provider message. Only its presentation boundaries
/// are persisted, so later preference changes never regroup historical replies.
struct ReplySegmentation: Codable, Hashable {
    let maximumSegments: Int // 0 means unlimited.
    var startsUTF8: [Int] = []
    // A new unsegmented group reply must stay in one block instead of being
    // reflowed like historical group messages when the setting changes.
    // Missing means enabled for previously saved segmentation metadata.
    private var disabled: Bool?
    var isEnabled: Bool { disabled != true }

    init(maximumSegments: Int, isEnabled: Bool = true) {
        self.maximumSegments = max(0, maximumSegments)
        disabled = isEnabled ? nil : true
    }

    static let prompt = """
    For conversational prose, organize this reply into natural chat paragraphs separated by a blank line. Each paragraph may contain several sentences; do not split at every punctuation mark or pad the reply to reach a paragraph count. Keep code blocks, tables, lists, and other structured content intact. Follow the user's requested format when it conflicts with this presentation preference.
    """

    func segments(in text: String) -> [String] {
        guard isEnabled, !startsUTF8.isEmpty else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        var previousOffset = 0
        let bytes = text.utf8
        for offset in startsUTF8 {
            // Imported or externally edited metadata must never drop text or trap.
            guard offset > previousOffset, offset < bytes.count,
                  let index = String.Index(bytes.index(bytes.startIndex, offsetBy: offset), within: text),
                  index > start else { return [text] }
            result.append(Self.displayText(text[start..<index]))
            start = index
            previousOffset = offset
        }
        result.append(Self.displayText(text[start...]))
        return result.allSatisfy { !$0.isEmpty } ? result : [text]
    }

    private static func displayText(_ value: Substring) -> String {
        var value = value
        // Remove the separating blank lines, including spaces on blank lines,
        // without stripping leading indentation from Markdown/code content.
        while value.last?.isWhitespace == true { value = value.dropLast() }
        return String(value)
    }
}

/// Advances over new UTF-8 bytes on the existing display cadence. It owns no
/// transcript, timer, regex, view, or network request. Line state stays constant
/// size even for a very long paragraph or an unfinished fenced code block.
struct ReplySegmentScanner {
    private(set) var segmentation: ReplySegmentation
    private(set) var scannedUTF8Count = 0
    private var lineStart = 0
    private var indentation = 0
    private var firstByte: UInt8?
    private var fenceRun = 0
    private var fenceRunEnded = false
    private var fenceSuffixIsWhitespace = true
    private var openFence: (byte: UInt8, width: Int)?
    private var hasContent = false
    private var pendingBoundary = false
    private var structuredParagraph = false
    private var previousWasCR = false

    init(maximumSegments: Int) {
        segmentation = ReplySegmentation(maximumSegments: maximumSegments)
    }

    mutating func advance(through text: String) {
        let bytes = text.utf8
        guard scannedUTF8Count <= bytes.count else { return }
        if segmentation.maximumSegments > 0,
           segmentation.startsUTF8.count + 1 >= segmentation.maximumSegments {
            scannedUTF8Count = bytes.count
            return
        }
        let start = bytes.index(bytes.startIndex, offsetBy: scannedUTF8Count)
        for byte in bytes[start...] {
            scannedUTF8Count += 1
            if byte == 10 && previousWasCR {
                previousWasCR = false
                lineStart = scannedUTF8Count
                continue
            }
            previousWasCR = byte == 13
            if byte == 10 || byte == 13 {
                finishLine()
                lineStart = scannedUTF8Count
                continue
            }
            let isSpace = byte == 32 || byte == 9
            if firstByte == nil {
                if isSpace {
                    indentation += byte == 9 ? 4 : 1
                    continue
                }
                let continuesStructure = structuredParagraph
                    && (indentation >= 2 || Self.isStructurePrefix(byte))
                if pendingBoundary && !continuesStructure {
                    segmentation.startsUTF8.append(lineStart)
                    if segmentation.maximumSegments > 0,
                       segmentation.startsUTF8.count + 1 >= segmentation.maximumSegments {
                        scannedUTF8Count = bytes.count
                        return
                    }
                }
                pendingBoundary = false
                firstByte = byte
                hasContent = true
            }
            if let firstByte, firstByte == 96 || firstByte == 126 {
                if !fenceRunEnded && byte == firstByte {
                    fenceRun += 1
                } else {
                    fenceRunEnded = true
                    if !isSpace { fenceSuffixIsWhitespace = false }
                }
            }
        }
    }

    private mutating func finishLine() {
        if let firstByte {
            if indentation <= 3, fenceRun >= 3 {
                if let fence = openFence {
                    if fence.byte == firstByte, fenceRun >= fence.width,
                       fenceSuffixIsWhitespace { openFence = nil }
                } else {
                    openFence = (firstByte, fenceRun)
                }
            }
            if openFence == nil {
                structuredParagraph = Self.isStructurePrefix(firstByte)
                    || (structuredParagraph && indentation >= 2)
            }
        } else if openFence == nil && hasContent {
            pendingBoundary = true
        }
        firstByte = nil
        indentation = 0
        fenceRun = 0
        fenceRunEnded = false
        fenceSuffixIsWhitespace = true
    }

    private static func isStructurePrefix(_ byte: UInt8) -> Bool {
        // Conservatively keep blank-separated list items, block quotes, and
        // table rows together. Ordinary prose still starts a new paragraph.
        byte == 45 || byte == 43 || byte == 42 || byte == 62 || byte == 124
            || (48...57).contains(byte)
    }
}

/// Display already checks prefix growth; recovery and codec rewrites validate
/// the original bytes before reusing the incremental cursor.
struct ReplySegmentProgress {
    private var text = ""
    private var scanner: ReplySegmentScanner
    init(maximumSegments: Int) {
        scanner = ReplySegmentScanner(maximumSegments: maximumSegments)
    }
    mutating func update(_ text: String, appendOnly: Bool = false) -> ReplySegmentation {
        if !appendOnly && !text.utf8.starts(with: self.text.utf8) {
            scanner = ReplySegmentScanner(maximumSegments: scanner.segmentation.maximumSegments)
        }
        scanner.advance(through: text)
        self.text = text
        return scanner.segmentation
    }
}
