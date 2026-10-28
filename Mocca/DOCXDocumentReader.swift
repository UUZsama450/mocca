import Foundation
import ZIPFoundation

/// Reads only the parts needed for a chat request, never unpacks to disk.
enum DOCXDocumentReader {
    static func read(url: URL) throws -> [ReadDocument.Block] {
        let archive = try Archive(url: url, accessMode: .read)
        let body = try entry("word/document.xml", archive: archive)
        var relationships: [String: String] = [:]
        if archive["word/_rels/document.xml.rels"] != nil {
            let data = try entry("word/_rels/document.xml.rels", archive: archive)
            let delegate = Relationships()
            try parse(data, delegate: delegate)
            relationships = delegate.images
        }
        let delegate = Body(relationships: relationships)
        try parse(body, delegate: delegate)
        delegate.flush()
        var blocks = delegate.blocks
        if archive.contains(where: { $0.path.hasPrefix("word/header") || $0.path.hasPrefix("word/footer") || $0.path == "word/footnotes.xml" || $0.path == "word/endnotes.xml" }) {
            blocks.append(.text("[Reading scope: headers, footers, footnotes and endnotes are not included in this version.]"))
        }
        return blocks
    }

    static func image(path: String, url: URL) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        return try entry(path, archive: archive)
    }

    private static func entry(_ path: String, archive: Archive) throws -> Data {
        try Task.checkCancellation()
        guard let entry = archive[path], entry.type == .file else { throw DocumentReadError.unreadable }
        var data = Data()
        let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
            try Task.checkCancellation()
            guard UInt64(data.count) <= entry.uncompressedSize,
                  UInt64(chunk.count) <= entry.uncompressedSize - UInt64(data.count) else {
                throw DocumentReadError.unreadable
            }
            data.append(chunk)
        }
        guard UInt64(data.count) == entry.uncompressedSize, checksum == entry.checksum else { throw DocumentReadError.unreadable }
        return data
    }

    private static func parse(_ data: Data, delegate: XMLParserDelegate) throws {
        // DOCX parts don't need a DTD. Reject it instead of permitting entity expansion.
        guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
              !xml.contains("\0"), !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw DocumentReadError.unreadable }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            try Task.checkCancellation()
            throw DocumentReadError.unreadable
        }
    }

    private final class Relationships: NSObject, XMLParserDelegate {
        var images: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            guard elementName == "Relationship", attributes["TargetMode"] != "External",
                  attributes["Type"]?.hasSuffix("/image") == true,
                  let id = attributes["Id"], let target = attributes["Target"] else { return }
            // Internal package paths only. No network fetch or filesystem extraction.
            let parts = target.split(separator: "/", omittingEmptySubsequences: false)
            guard !target.contains("\\"), !target.contains(":"), !target.hasPrefix("/"),
                  !parts.contains(".."), !parts.contains("."), !parts.contains("") else { return }
            images[id] = "word/" + target
        }
    }

    private final class Body: NSObject, XMLParserDelegate {
        let relationships: [String: String]
        var blocks: [ReadDocument.Block] = []
        var buffer = ""
        var inText = false
        var deletedDepth = 0
        var fallbackDepth = 0
        var imageNumber = 0
        init(relationships: [String: String]) { self.relationships = relationships }

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            buffer = ""
        }
        func append(_ text: String, parser: XMLParser) {
            if Task.isCancelled { parser.abortParsing(); return }
            buffer += text
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            if Task.isCancelled { parser.abortParsing(); return }
            // AlternateContent includes a legacy fallback of the same drawing.
            if name == "Fallback" { fallbackDepth += 1 }
            if fallbackDepth > 0 { return }
            if name == "del" { deletedDepth += 1 }
            if deletedDepth > 0 { return }
            switch name {
            case "t": inText = true
            case "tab": append("\t", parser: parser)
            case "br", "cr": append("\n", parser: parser)
            case "blip", "imagedata":
                flush()
                imageNumber += 1
                let id = attributes.first { $0.key == "embed" || $0.key.hasSuffix(":embed") || (name == "imagedata" && $0.key.hasSuffix(":id")) }?.value
                if let id, let path = relationships[id], ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp"].contains((path as NSString).pathExtension.lowercased()) {
                    blocks.append(.visual(DocumentVisual(label: "Image \(imageNumber)", source: .docx(path))))
                } else {
                    blocks.append(.text("[Image \(imageNumber): unsupported or external image; visual content was not read.]"))
                }
            case "chart", "relIds", "object", "altChunk":
                append("\n[Unsupported embedded object: \(name); content not read.]\n", parser: parser)
            case "gridSpan", "vMerge":
                append("[merged cell] ", parser: parser)
            case "numPr": append("• ", parser: parser)
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText && deletedDepth == 0 { append(string, parser: parser) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if name == "Fallback" { fallbackDepth = max(0, fallbackDepth - 1); return }
            if fallbackDepth > 0 { return }
            if name == "del" { deletedDepth = max(0, deletedDepth - 1); return }
            if deletedDepth > 0 { return }
            switch name {
            case "t": inText = false
            case "p", "tr": append("\n", parser: parser)
            case "tc": append("\t|\t", parser: parser)
            default: break
            }
        }
    }
}
