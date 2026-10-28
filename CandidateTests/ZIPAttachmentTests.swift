import XCTest
import SwiftUI
import PDFKit
import ZIPFoundation
import CryptoKit
@testable import Mocca

@MainActor
final class ZIPAttachmentTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zip-qa-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func zip(_ files: [(String, Data)], compression: CompressionMethod = .deflate) throws -> URL {
        let url = try folder().appendingPathComponent("资料.zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, data) in files {
            try archive.addEntry(with: name, type: name.hasSuffix("/") ? .directory : .file,
                uncompressedSize: Int64(data.count), compressionMethod: compression) { start, size in
                    data.subdata(in: Int(start)..<(Int(start) + size))
                }
        }
        return url
    }
    private func attachment(_ url: URL) -> MessageAttachment {
        MessageAttachment(kind: .file, localURL: url, fileName: url.lastPathComponent, mimeType: "application/zip")
    }
    private func reader() throws -> ZIPAttachmentReader { ZIPAttachmentReader(root: try folder().appendingPathComponent("cache")) }
    private func read(_ url: URL, reader: ZIPAttachmentReader? = nil) async throws -> ZIPAttachmentWorkspace {
        let target = try reader ?? self.reader()
        return try await target.read(url, name: url.lastPathComponent, progress: { _ in })
    }
    private func patch(_ url: URL, _ change: (inout Data, [Int]) -> Void) throws {
        var bytes = try Data(contentsOf: url)
        let end = bytes.count - 22
        var position = Int(u32(bytes, end + 16)), offsets: [Int] = []
        while position < end {
            offsets.append(position)
            position += 46 + Int(u16(bytes, position + 28)) + Int(u16(bytes, position + 30)) + Int(u16(bytes, position + 32))
        }
        change(&bytes, offsets)
        try bytes.write(to: url)
    }
    private func u16(_ data: Data, _ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i + 1]) << 8 }
    private func u32(_ data: Data, _ i: Int) -> UInt32 { UInt32(u16(data, i)) | UInt32(u16(data, i + 2)) << 16 }
    private func put(_ data: inout Data, _ i: Int, _ value: UInt32, bytes: Int = 4) {
        for n in 0..<bytes { data[i + n] = UInt8(truncatingIfNeeded: value >> (8 * n)) }
    }
    private func assertRejected(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = try folder().appendingPathComponent("cache")
        let reader = ZIPAttachmentReader(root: root)
        do { _ = try await read(url, reader: reader); XCTFail("Unexpected success", file: file, line: line) }
        catch is CancellationError { XCTFail("Wrong failure", file: file, line: line) }
        catch {}
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(items.isEmpty, "Partial extraction was retained: \(items)", file: file, line: line)
    }

    func testUTF8CompleteTextPathsAndCacheReuse() async throws {
        let tail = String(repeating: "完整中文内容 qwq\n", count: 9_000) + "END_OF_WHOLE_FILE"
        let url = try zip([("代码/", Data()), ("代码/README", Data("Read me".utf8)), ("代码/main.swift", Data(tail.utf8)), (".hidden.txt", Data("hidden user file".utf8))])
        let original = try Data(contentsOf: url), reader = try reader()
        let first = try await read(url, reader: reader), warm = try await read(url, reader: reader)
        XCTAssertTrue(first === warm)
        XCTAssertEqual(first.files.map(\.path), ["代码/README", "代码/main.swift", ".hidden.txt"])
        XCTAssertEqual(try String(contentsOf: first.files[1].url, encoding: .utf8), tail)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // Independent producer: Python zipfile writing to a non-seekable stream,
    // with UTF-8 names, signed data descriptors, and an archive comment.
    func testStreamingZIPFromIndependentProducer() async throws {
        let bytes = Data(base64Encoded: "UEsDBBQACAgIAGCIXF0AAAAAAAAAAAAAAAAQAAAA55uu5b2VL1JFQURNRS5tZCsuKUpNzE1NUXiyY+2zae0KJanFJQBQSwcIqH89rxYAAAAUAAAAUEsDBBQACAAIAGCIXF0AAAAAAAAAAAAAAAAMAAAAc291cmNlLnN3aWZ0y0ktUShLzClNVbBVMDECAFBLBwiUZM2cEAAAAA4AAABQSwECFAMUAAgICABgiFxdqH89rxYAAAAUAAAAEAAAAAAAAAAAAAAAgAEAAAAA55uu5b2VL1JFQURNRS5tZFBLAQIUAxQACAAIAGCIXF2UZM2cEAAAAA4AAAAMAAAAAAAAAAAAAACAAVQAAABzb3VyY2Uuc3dpZnRQSwUGAAAAAAIAAgB4AAAAngAAAA4AWklQIFFBIGNvbW1lbnQ=")!
        let url = try folder().appendingPathComponent("streamed.zip")
        try bytes.write(to: url)
        let result = try await read(url)
        XCTAssertEqual(result.files.map(\.path), ["目录/README.md", "source.swift"])
        XCTAssertEqual(try String(contentsOf: result.files[0].url, encoding: .utf8), "streamed 中文 test")
        XCTAssertEqual(try String(contentsOf: result.files[1].url, encoding: .utf8), "let value = 42")
    }

    func testStoredZIPAndOSMetadataAccounting() async throws {
        let url = try zip([(".DS_Store", Data([0,1,2])), ("__MACOSX/._foo", Data([0,4])), ("folder/a.txt", Data("A".utf8)),
            ("__MACOSX/README.md", Data("USER_CONTENT".utf8)), ("project/__MACOSX/notes.txt", Data("NESTED_USER_CONTENT".utf8))], compression: .none)
        let file = attachment(url), message = ChatMessage(conversationID: UUID(), role: .user, text: "Read", attachments: [file])
        let result = try await ZIPAttachmentPreparation.expand([message], reader: reader(), progress: { _ in })
        XCTAssertEqual(result.messages[0].attachments.count, 3)
        XCTAssertEqual(result.messages[0].attachments[0].fileName, "资料.zip/folder/a.txt")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(result.messages[0].attachments[1].localURL), encoding: .utf8), "USER_CONTENT")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(result.messages[0].attachments[2].localURL), encoding: .utf8), "NESTED_USER_CONTENT")
        XCTAssertTrue(result.messages[0].text.contains("Ignored OS metadata files: 2"))
        XCTAssertEqual(message.attachments, [file])
    }

    func testUTF8ChunkBoundaryAndInvalidSequences() async throws {
        let content = String(repeating: "a", count: 65_535) + "🥳中文" + String(repeating: "b", count: 65_534) + "é"
        let result = try await read(zip([("README", Data(content.utf8))]))
        XCTAssertEqual(try String(contentsOf: result.files[0].url, encoding: .utf8), content)
        let invalid: [[UInt8]] = [[0xC0,0xAF], [0xED,0xA0,0x80], [0xF4,0x90,0x80,0x80], [0xE4,0xB8], [0xFF], [0x01]]
        for bytes in invalid {
            try await assertRejected(zip([("text.txt", Data(bytes))]))
        }
    }

    func testLargeDOCXDeclarationsStillRequireMatchingActualContent() async throws {
        let nested = try zip([("word/document.xml", Data("body".utf8))])
        try patch(nested) { data, offsets in
            let local = Int(u32(data, offsets[0] + 42)), declared: UInt32 = 48 * 1024 * 1024
            put(&data, offsets[0] + 24, declared); put(&data, local + 22, declared)
        }
        let data = try Data(contentsOf: nested)
        let url = try zip([("one.docx", data), ("two.docx", data), ("three.docx", data)])
        let result = try await read(url)
        XCTAssertEqual(result.files.count, 3)
        XCTAssertThrowsError(try DOCXDocumentReader.read(url: result.files[0].url))
    }

    func testRejectTraversalAbsoluteLinksAndDuplicatePaths() async throws {
        for path in ["../out.txt", "/out.txt", "C:/out.txt", "a\\b.txt", "a/../b.txt", "a//b.txt", "bad\nname.txt"] {
            try await assertRejected(zip([("good.txt", Data("good".utf8)), (path, Data("bad".utf8))]))
        }
        try await assertRejected(zip([("é.txt", Data("one".utf8)), ("e\u{301}.txt", Data("two".utf8))]))
        try await assertRejected(zip([("file", Data("one".utf8)), ("file/child.txt", Data("two".utf8))]))
        let link = try zip([("good.txt", Data("good".utf8)), ("link", Data("../../outside".utf8))])
        try patch(link) { data, offsets in
            put(&data, offsets[1] + 4, 0x0314, bytes: 2)
            put(&data, offsets[1] + 38, 0xA1FF0000)
        }
        try await assertRejected(link)
    }

    func testEncryptedOrBrokenSecondEntryNeverSendsReadablePrefix() async throws {
        let encrypted = try zip([("a.txt", Data("A".utf8)), ("b.txt", Data("B".utf8))])
        try patch(encrypted) { data, offsets in put(&data, offsets[1] + 8, UInt32(u16(data, offsets[1] + 8)) | 1, bytes: 2) }
        try await assertRejected(encrypted)
        let broken = try zip([("a.txt", Data("A".utf8)), ("b.txt", Data("B".utf8))])
        try patch(broken) { data, offsets in
            let local = Int(u32(data, offsets[1] + 42)); data[local] = 0
        }
        try await assertRejected(broken)
    }

    func testCRCAndActualExpandedSizeValidation() async throws {
        let crc = try zip([("a.txt", Data("unchanged payload".utf8))])
        try patch(crc) { data, offsets in
            let local = Int(u32(data, offsets[0] + 42))
            put(&data, offsets[0] + 16, 123); put(&data, local + 14, 123)
        }
        try await assertRejected(crc)
        let misleadingSize = try zip([("a.txt", Data(repeating: 65, count: 2 * 1024 * 1024))])
        try patch(misleadingSize) { data, offsets in
            let local = Int(u32(data, offsets[0] + 42))
            put(&data, offsets[0] + 24, 1); put(&data, local + 22, 1)
        }
        try await assertRejected(misleadingSize)
    }

    func testNestedUnknownBinaryEmptyAndUnsupportedCompression() async throws {
        for pair in [("nested.zip", Data("fake".utf8)), ("file.bin", Data([0,1,255])), ("photo.png", Data("bad image".utf8))] {
            try await assertRejected(zip([("good.txt", Data("A".utf8)), pair]))
        }
        try await assertRejected(zip([]))
        try await assertRejected(zip([("folder/", Data()), (".DS_Store", Data([0]))]))
        let method = try zip([("a.txt", Data("A".utf8))])
        try patch(method) { data, offsets in put(&data, offsets[0] + 10, 99, bytes: 2) }
        try await assertRejected(method)
    }

    func testMoreThanOldFileAndDirectoryCountsAreReadCompletely() async throws {
        let first = attachment(try zip((0..<1050).map { ("dir/\($0).txt", Data("complete".utf8)) }))
        let second = attachment(try zip((0..<260).map { ("other/\($0).txt", Data("tail".utf8)) }))
        let message = ChatMessage(conversationID: UUID(), role: .user, text: "Read", attachments: [first, second])
        let result = try await ZIPAttachmentPreparation.expand([message], reader: reader(), progress: { _ in })
        XCTAssertEqual(result.messages[0].attachments.count, 1310)
        XCTAssertTrue(result.messages[0].attachments.last!.fileName!.hasSuffix("other/259.txt"))
    }

    func testLargeArchivesAndMembersDoNotHitOldByteCaps() async throws {
        let url = try folder().appendingPathComponent("large.zip")
        let size = 80 * 1024 * 1024
        do {
            let archive = try Archive(url: url, accessMode: .create)
            try archive.addEntry(with: "whole.txt", type: .file, uncompressedSize: Int64(size), compressionMethod: .none) { start, count in
                var data = Data(repeating: 65, count: count)
                if Int(start) + count == size { data[data.count - 1] = 90 }
                return data
            }
        }
        let message = ChatMessage(conversationID: UUID(), role: .user, text: "", attachments: [attachment(url), attachment(url)])
        let result = try await ZIPAttachmentPreparation.expand([message], reader: reader(), progress: { _ in })
        XCTAssertEqual(result.messages[0].attachments.count, 2)
        XCTAssertEqual(result.workspaces.reduce(0) { $0 + $1.bytes }, 160 * 1024 * 1024)
        for file in result.messages[0].attachments {
            let handle = try FileHandle(forReadingFrom: XCTUnwrap(file.localURL))
            defer { try? handle.close() }
            XCTAssertEqual(try handle.seekToEnd(), UInt64(size))
            try handle.seek(toOffset: UInt64(size - 1))
            XCTAssertEqual(try handle.read(upToCount: 1), Data([90]))
        }
    }

    func testCacheRetentionNeverRejectsAFileAndDeepPathsUseGeneratedNames() async throws {
        let target = ZIPAttachmentReader(root: try folder().appendingPathComponent("cache"), retainedBytes: 32)
        let path = String(repeating: "folder/", count: 80) + "name." + String(repeating: "x", count: 300)
        let url = try zip([(path, Data(repeating: 65, count: 1000))])
        var first: ZIPAttachmentWorkspace? = try await read(url, reader: target)
        let directory = first!.directory
        var second: ZIPAttachmentWorkspace? = try await read(url, reader: target)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first!.files[0].path, path)
        XCTAssertEqual(first!.files[0].bytes, 1000)
        first = nil; second = nil
        let fresh = try await read(url, reader: target)
        XCTAssertNotEqual(fresh.directory, directory)
    }

    func testCacheInvalidationAndActiveLeaseSurvivesEviction() async throws {
        let reader = try reader(), url = try zip([("a.txt", Data("first".utf8))])
        var first: ZIPAttachmentWorkspace? = try await read(url, reader: reader)
        let firstPath = first!.directory
        let replacement = try zip([("a.txt", Data("other".utf8))])
        try Data(contentsOf: replacement).write(to: url, options: .atomic)
        let updated = try await read(url, reader: reader)
        XCTAssertNotEqual(first!.directory, updated.directory)
        XCTAssertEqual(try String(contentsOf: updated.files[0].url, encoding: .utf8), "other")
        _ = try await read(zip([("third.txt", Data("third".utf8))]), reader: reader)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath.path))
        first = nil
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: firstPath.path) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath.path))
    }

    func testLaunchCleanupRemovesOnlyAbandonedWorkAndNeverActiveFiles() async throws {
        let directory = try folder(), root = directory.appendingPathComponent("zip-cache")
        let original = directory.appendingPathComponent("keep-original.zip")
        try Data("original".utf8).write(to: original)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("unfinished".utf8).write(to: root.appendingPathComponent("partial"))
        let reader = ZIPAttachmentReader(root: root)
        let removed = await reader.discardAbandonedFiles()
        XCTAssertTrue(removed); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        let active = try await read(zip([("a.txt", Data("complete".utf8))]), reader: reader)
        let removedActive = await reader.discardAbandonedFiles()
        XCTAssertFalse(removedActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.files[0].url.path))
    }

    func testActiveCancellationCleansPartialFilesAndStopsProgress() async throws {
        let url = try zip([("large.txt", Data(repeating: 65, count: 32 * 1024 * 1024))])
        let root = try folder().appendingPathComponent("cache"), reader = ZIPAttachmentReader(root: root)
        let message = ChatMessage(conversationID: UUID(), role: .user, text: "", attachments: [attachment(url)])
        var updates = 0, extracting = false
        let task = Task { try await ZIPAttachmentPreparation.expand([message], reader: reader, progress: {
            updates += 1
            if $0.contains("解压") || $0.contains("Extracting") { extracting = true }
        }) }
        for _ in 0..<5_000 {
            if extracting { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(extracting)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let count = updates
        // A subsequent actor operation waits for the cancelled IO to unwind.
        let small = try await read(zip([("small.txt", Data("ok".utf8))]), reader: reader)
        XCTAssertEqual(updates, count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [small.directory.lastPathComponent])
    }

    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { c in
            c.beginPage()
            ("PDF_BODY_完整" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }
    private func docx() throws -> Data {
        try Data(contentsOf: zip([("word/document.xml", Data("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>DOCX_BODY_COMPLETE</w:t></w:r></w:p></w:body></w:document>".utf8))]))
    }
    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 24, height: 24)) }.pngData()!
    }
    private func model(ocr: Bool = false, vision: Bool = false) throws -> (AppModel, UUID) {
        URLProtocol.registerClass(DocumentMockURLProtocol.self)
        DocumentMockURLProtocol.state.reset(); OCRService.shared.clearCache()
        let model = AppModel()
        let chat = Conversation(title: "ZIP synthetic fixture", assistantID: model.currentAssistantID.uuidString)
        try model.reviewInstallStore(ConversationSnapshot(conversations: [chat], messagesByConversation: [chat.id: []]), directory: folder())
        let provider = ProviderConfiguration(id: UUID(), enabled: true, name: "ZIP fixture", type: .openAI, apiKey: "test", baseURL: "http://document.test", chatPath: "/chat/completions", models: [
            ModelConfiguration(id: "fixture-main", capabilityOverride: ModelCapabilities(input: vision ? [.text,.image] : [.text])),
            ModelConfiguration(id: "fixture-ocr", capabilityOverride: ModelCapabilities(input: [.text,.image]))])
        model.providers = [provider]; model.selectedModel = ModelSelection(providerID: provider.id, modelID: "fixture-main")
        model.preferences.ocrEnabled = ocr; model.preferences.ocrProviderID = provider.id.uuidString; model.preferences.ocrModelID = "fixture-ocr"
        model.preferences.resendHistoricalImages = false
        return (model, chat.id)
    }
    private func wait(_ model: AppModel, _ id: UUID) async throws {
        for _ in 0..<1000 { if !model.isConversationStreaming(id) { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        model.stopStreaming(); XCTFail("Timed out")
    }
    private func payloads() -> [String] {
        DocumentMockURLProtocol.state.snapshot().filter { $0["model"] as? String == "fixture-main" }.map {
            String(data: try! JSONSerialization.data(withJSONObject: $0, options: .withoutEscapingSlashes), encoding: .utf8)!
        }
    }
    private func requestText() -> String {
        DocumentMockURLProtocol.state.snapshot().filter { $0["model"] as? String == "fixture-main" }.flatMap {
            $0["messages"] as? [[String: Any]] ?? []
        }.map { row in
            if let text = row["content"] as? String { return text }
            return (row["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    func testWholeArchiveRequestAndOriginalPersistence() async throws {
        let (model, id) = try model(), url = try zip([("one.txt", Data("ONE_BODY".utf8)), ("src/two.py", Data("TWO_BODY".utf8))])
        let original = try XCTUnwrap(AttachmentStore.importFile(from: url))
        addTeardownBlock { AttachmentStore.delete(original) }
        model.setComposerDraftText("Read the entire archive", for: id); model.setComposerPendingAttachments([original], for: id)
        XCTAssertTrue(model.sendDraft(for: id)); try await wait(model, id)
        XCTAssertEqual(payloads().count, 1, model.errorMessage)
        let request = try XCTUnwrap(payloads().first)
        XCTAssertTrue(request.contains("ONE_BODY")); XCTAssertTrue(request.contains("TWO_BODY")); XCTAssertTrue(request.contains("src/two.py"))
        XCTAssertFalse(request.contains("MoccaZIPAttachments"))
        let saved = try model.reviewReadStore().messagesByConversation[id]!.first { $0.role == .user }!
        XCTAssertEqual(saved.attachments.count, 1); XCTAssertEqual(saved.attachments[0].id, original.id)
        XCTAssertEqual(saved.attachments[0].fileName, original.fileName)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.attachments[0].localURL)), try Data(contentsOf: url))
        XCTAssertTrue(model.documentReadingProgress.isEmpty)
    }

    func testZIPDocumentsImagesOCRAndHistoryUseExistingRoutes() async throws {
        for ocr in [false, true] {
            let (model, id) = try model(ocr: ocr, vision: !ocr)
            let pdfData = pdf(), referenceURL = try folder().appendingPathComponent("reference.pdf")
            try pdfData.write(to: referenceURL)
            let reference = try await DocumentAttachmentReader().read(MessageAttachment(kind: .file,
                localURL: referenceURL, fileName: "reference.pdf", mimeType: "application/pdf"))
            let expectedText = reference.blocks.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            let url = try zip([("report.pdf", pdfData), ("notes.docx", docx()), ("photo.png", png())])
            model.setComposerPendingAttachments([attachment(url)], for: id)
            XCTAssertTrue(model.sendDraft(for: id)); try await wait(model, id)
            XCTAssertEqual(payloads().count, 1, model.errorMessage)
            let request = try XCTUnwrap(payloads().first)
            XCTAssertFalse(expectedText.isEmpty)
            XCTAssertTrue(requestText().contains(expectedText), String(requestText().suffix(4_000)))
            XCTAssertTrue(request.contains("DOCX_BODY_COMPLETE"), String(requestText().suffix(4_000)))
            XCTAssertEqual(request.contains("image_url"), !ocr)
            XCTAssertEqual(request.contains("Recognized document visual"), ocr)
            DocumentMockURLProtocol.state.reset()
            if let pending = model.pendingUserMessageSendPositionRequest { model.consumeUserMessageSendPositionRequest(pending.id) }
            model.setComposerDraftText("Follow up", for: id)
            XCTAssertTrue(model.sendDraft(for: id)); try await wait(model, id)
            XCTAssertEqual(payloads().count, 1, model.errorMessage)
            XCTAssertFalse(try XCTUnwrap(payloads().first).contains("image_url"))
            XCTAssertEqual(DocumentMockURLProtocol.state.snapshot().filter { $0["model"] as? String == "fixture-ocr" }.count, 0)
        }
    }

    func testUnsupportedZIPStopsMainRequestAndPreservesOriginal() async throws {
        let (model, id) = try model(), original = attachment(try zip([("good.txt", Data("GOOD".utf8)), ("bad.bin", Data([0,255]))]))
        model.setComposerPendingAttachments([original], for: id)
        XCTAssertTrue(model.sendDraft(for: id)); try await wait(model, id)
        XCTAssertTrue(payloads().isEmpty); XCTAssertFalse(model.errorMessage.isEmpty)
        XCTAssertTrue(model.errorMessage.contains("bad.bin"), model.errorMessage)
        XCTAssertTrue(model.documentReadingProgress.isEmpty)
        XCTAssertEqual(model.messages.first { $0.role == .user }?.attachments, [original])
    }

    func testRegenerationReusesValidWorkspaceAndRetriesAfterFileRepair() async throws {
        let (model, id) = try model()
        let original = try XCTUnwrap(AttachmentStore.importFile(from: zip([("readme.txt", Data("WHOLE_REGENERATED_CONTENT".utf8))])))
        addTeardownBlock { AttachmentStore.delete(original) }
        model.setComposerPendingAttachments([original], for: id)
        XCTAssertTrue(model.sendDraft(for: id)); try await wait(model, id)
        let user = try XCTUnwrap(model.messages.first { $0.role == .user })
        let cached = try await ZIPAttachmentReader.shared.read(XCTUnwrap(original.localURL), name: "ZIP", progress: { _ in })
        if let pending = model.pendingUserMessageSendPositionRequest { model.consumeUserMessageSendPositionRequest(pending.id) }
        DocumentMockURLProtocol.state.reset()
        model.regenerateResponse(around: user.id); try await wait(model, id)
        XCTAssertEqual(payloads().count, 1, model.errorMessage)
        XCTAssertTrue(requestText().contains("WHOLE_REGENERATED_CONTENT"))
        let reused = try await ZIPAttachmentReader.shared.read(XCTUnwrap(original.localURL), name: "ZIP", progress: { _ in })
        XCTAssertTrue(cached === reused)

        let (retryModel, retryID) = try self.model()
        let brokenURL = try folder().appendingPathComponent("broken.zip")
        try Data("broken".utf8).write(to: brokenURL)
        let broken = try XCTUnwrap(AttachmentStore.importFile(from: brokenURL))
        addTeardownBlock { AttachmentStore.delete(broken) }
        retryModel.setComposerPendingAttachments([broken], for: retryID)
        XCTAssertTrue(retryModel.sendDraft(for: retryID)); try await wait(retryModel, retryID)
        XCTAssertTrue(payloads().isEmpty)
        let retryUser = try XCTUnwrap(retryModel.messages.first { $0.role == .user })
        let repaired = try zip([("fixed.txt", Data("REPAIRED_WHOLE_CONTENT".utf8))])
        try Data(contentsOf: repaired).write(to: XCTUnwrap(broken.localURL), options: .atomic)
        if let pending = retryModel.pendingUserMessageSendPositionRequest { retryModel.consumeUserMessageSendPositionRequest(pending.id) }
        DocumentMockURLProtocol.state.reset()
        retryModel.regenerateResponse(around: retryUser.id); try await wait(retryModel, retryID)
        XCTAssertEqual(payloads().count, 1, retryModel.errorMessage)
        XCTAssertTrue(requestText().contains("REPAIRED_WHOLE_CONTENT"))
    }

    func testStopBeforePreparationAndStableChildIDs() async throws {
        let url = try zip([("one.txt", Data("ONE".utf8))]), file = attachment(url)
        let message = ChatMessage(conversationID: UUID(), role: .user, text: "", attachments: [file])
        let first = try await ZIPAttachmentPreparation.expand([message], reader: reader(), progress: { _ in })
        let second = try await ZIPAttachmentPreparation.expand([message], reader: reader(), progress: { _ in })
        XCTAssertEqual(first.messages[0].attachments.map(\.id), second.messages[0].attachments.map(\.id))
        let (model, id) = try model(ocr: true)
        model.setComposerPendingAttachments([file], for: id)
        XCTAssertTrue(model.sendDraft(for: id)); model.stopStreaming()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(DocumentMockURLProtocol.state.snapshot().isEmpty)
    }

    func testStoppingDuringZIPPreparationMakesNoProviderRequest() async throws {
        let (model, id) = try model()
        let file = attachment(try zip([("large.txt", Data(repeating: 65, count: 32 * 1024 * 1024))]))
        model.setComposerPendingAttachments([file], for: id)
        XCTAssertTrue(model.sendDraft(for: id))
        var started = false
        for _ in 0..<2_000 {
            if model.documentReadingProgress.values.contains(where: { $0.contains("解压") || $0.contains("Extracting") }) { started = true; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(started)
        model.stopStreaming()
        for _ in 0..<2_000 {
            if model.documentReadingProgress.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(DocumentMockURLProtocol.state.snapshot().isEmpty)
        XCTAssertTrue(model.documentReadingProgress.isEmpty)
        XCTAssertEqual(model.messages.first { $0.role == .user }?.attachments, [file])
    }

    func testBackgroundHeartbeatWarmCacheAndOrdinaryFastPath() async throws {
        let url = try zip((0..<64).map { ("source/\($0).txt", Data(repeating: 65, count: 256 * 1024)) })
        let reader = try reader()
        var ticks = 0, longestGap = 0.0, previous = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                longestGap = max(longestGap, now - previous); previous = now; ticks += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let cold = try await read(url, reader: reader)
        let coldMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let warmStart = ProcessInfo.processInfo.systemUptime
        let warm = try await read(url, reader: reader)
        let warmMS = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
        heartbeat.cancel()
        XCTAssertTrue(cold === warm); XCTAssertGreaterThan(ticks, 5); XCTAssertLessThan(longestGap, 0.5)
        let root = try folder().appendingPathComponent("must-not-exist"), untouched = ZIPAttachmentReader(root: root)
        let ordinary = [ChatMessage(conversationID: UUID(), role: .user, text: "ordinary")]
        let fastStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 {
            let result = try await ZIPAttachmentPreparation.expand(ordinary, reader: untouched, progress: { _ in XCTFail() })
            XCTAssertTrue(result.workspaces.isEmpty)
        }
        let fastMS = (ProcessInfo.processInfo.systemUptime - fastStart) * 1000
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        print("ZIP_PERF cold16MiB_ms=\(coldMS) warm_ms=\(warmMS) heartbeat_ticks=\(ticks) max_main_gap_ms=\(longestGap * 1000) ordinary10000_ms=\(fastMS)")
    }

    func testMissingZIPImageCannotSilentlyDisappear() async throws {
        let message = ChatMessage(conversationID: UUID(), role: .user, text: "", attachments: [attachment(try zip([("photo.png", png())]))])
        let expanded = try await ZIPAttachmentPreparation.expand([message], reader: reader(), progress: { _ in })
        defer { withExtendedLifetime(expanded.workspaces) {} }
        let image = expanded.messages[0].attachments[0]
        try FileManager.default.removeItem(at: XCTUnwrap(image.localURL))
        do { _ = try await ChatRequestAttachments.prepare([image], imageIDs: [image.id]); XCTFail() }
        catch ZIPAttachmentError.unsupportedFile(let name) { XCTAssertTrue(name.contains("photo.png")) }
    }

    func testProgressUsesExistingDocumentLabel() async throws {
        let model = AppModel(), id = UUID()
        model.documentReadingProgress[id] = "正在解压 资料.zip · 3/12 个文件"
        let view = HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Color(uiColor: .secondaryLabel))
            DocumentReadingProgressLabel(messageID: id)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color(uiColor: .systemBackground)).environment(model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 100)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.rootViewController?.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let evidence = XCTAttachment(image: image); evidence.name = "ZIP progress — existing PDF style"; evidence.lifetime = .keepAlways
        add(evidence)
    }
}
