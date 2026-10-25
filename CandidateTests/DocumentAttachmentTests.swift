import XCTest
import PDFKit
import UIKit
import SwiftUI
import Darwin
import ZIPFoundation
@testable import Mocca

private actor OCRProbe {
    var calls = 0
    var active = 0
    var peak = 0
    func recognize(_ image: ChatRequestImage, fail: Bool = false, delay: UInt64 = 0) async throws -> String {
        calls += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw URLError(.cannotConnectToHost) }
        return "recognized-\(image.base64Data.prefix(12))"
    }
}

final class DocumentMockURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [[String: Any]] = []
        var failOCRCall = 0
        var ocrCount = 0
        func reset(fail: Int = 0) { lock.lock(); defer { lock.unlock() }; requests = []; ocrCount = 0; failOCRCall = fail }
        func accept(_ body: [String: Any]) -> (Bool, String) {
            lock.lock(); defer { lock.unlock() }
            requests.append(body)
            let ocr = (body["model"] as? String) == "fixture-ocr"
            if ocr { ocrCount += 1 }
            return (ocr && ocrCount == failOCRCall, ocr ? "Recognized document visual \(ocrCount)" : "Fixture answer")
        }
        func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return requests }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "document.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(buffer, count: n) }
        }
        let body = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
        let (fail, text) = Self.state.accept(body)
        let output: Data
        if fail { output = Data("{\"error\":{\"message\":\"Synthetic OCR failure\"}}".utf8) }
        else if body["stream"] as? Bool == true {
            let chunk: [String: Any] = ["choices": [["delta": ["content": text], "index": 0]]]
            output = Data("data: \(String(data: try! JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)!)\n\ndata: [DONE]\n\n".utf8)
        } else {
            output = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fail ? 503 : 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: output)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class DocumentAttachmentTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("documents-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func attachment(_ url: URL) -> MessageAttachment {
        MessageAttachment(kind: .file, localURL: url, fileName: url.lastPathComponent,
            mimeType: url.pathExtension == "pdf" ? "application/pdf" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    }
    private func pdf(pages: Int = 2, scan: Bool = false, rotated: Bool = false) throws -> MessageAttachment {
        let url = try folder().appendingPathComponent("sample.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500))
        try renderer.writePDF(to: url) { context in
            for page in 1...pages {
                context.beginPage()
                if scan {
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 500)).image { ctx in
                        UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
                        ("Scan \(page) 扫描" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
                    }
                    image.draw(in: CGRect(x: 0, y: 0, width: 300, height: 500))
                } else {
                    ("Page \(page) 正文 中文 123" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
                    UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 50, y: 150, width: 150, height: 60))
                }
            }
        }
        if rotated { let doc = PDFDocument(url: url)!; doc.page(at: 0)!.rotation = 90; XCTAssertTrue(doc.write(to: url)) }
        return attachment(url)
    }
    private func docx(body: String, relationships: String = "", image: Bool = false, extra: [String: Data] = [:], rawBody: Data? = nil) throws -> MessageAttachment {
        let url = try folder().appendingPathComponent("sample.docx")
        let archive = try Archive(url: url, accessMode: .create)
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><w:body>\(body)</w:body></w:document>"
        var files = extra
        files["word/document.xml"] = rawBody ?? Data(xml.utf8)
        if !relationships.isEmpty { files["word/_rels/document.xml.rels"] = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>".utf8) }
        if image {
            files["word/media/image.png"] = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 80, height: 40)) }.pngData()!
        }
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                data.subdata(in: Int(position)..<(Int(position) + count))
            }
        }
        return attachment(url)
    }
    private func text(_ document: ReadDocument) -> String { document.blocks.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined(separator: "\n") }
    private func provider() -> ProviderConfiguration {
        ProviderConfiguration(id: UUID(), enabled: true, name: "Synthetic", type: .openAI, apiKey: "test", baseURL: "http://document.test", chatPath: "/chat/completions", models: [ModelConfiguration(id: "fixture-ocr")])
    }

    func testPDFTextPageSelectionAndRotation() async throws {
        var file = try pdf(pages: 3, rotated: true)
        var options = DocumentOptions(); options.pages = "1,3"; file.metadata = options.applying(to: [:])
        let reader = DocumentAttachmentReader()
        let doc = try await reader.read(file)
        XCTAssertTrue(doc.hasText); XCTAssertTrue(text(doc).precomposedStringWithCompatibilityMapping.contains("正文"), text(doc)); XCTAssertTrue(text(doc).contains("Page 3"), text(doc)); XCTAssertFalse(text(doc).contains("Page 2"), text(doc))
        XCTAssertEqual(doc.visuals.count, 2)
        let image = try await reader.image(doc.visuals[0], in: doc)
        let decoded = UIImage(data: Data(base64Encoded: image.base64Data)!)!
        XCTAssertGreaterThan(decoded.size.width, decoded.size.height)
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 2048)
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("document-rendered-page.png")
        try decoded.pngData()!.write(to: output)
        print("DOCUMENT_RENDER_SNAPSHOT \(output.path)")
        let pixels = decoded.cgImage!.dataProvider!.data! as Data
        let pixelStride = max(3, decoded.cgImage!.bitsPerPixel / 8)
        XCTAssertTrue(stride(from: 0, to: pixels.count - pixelStride, by: pixelStride).contains {
            pixels[$0] < 180 && pixels[$0 + 1] < 180 && pixels[$0 + 2] < 180
        }, "Rendered page must contain ink, not a blank white bitmap")
        // The 150 x 60 point red chart rotates to 60 x 150 and is rendered
        // at 3 pixels/point. A valid-size but unscaled bitmap must fail.
        let cg = decoded.cgImage!
        let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let rgb = context.data!.assumingMemoryBound(to: UInt8.self)
        var redPixels = 0
        for i in stride(from: 0, to: cg.width * cg.height * 4, by: 4) {
            if rgb[i] > 180 && rgb[i + 1] < 80 && rgb[i + 2] < 80 { redPixels += 1 }
        }
        XCTAssertGreaterThan(redPixels, 70_000)
        XCTAssertLessThan(redPixels, 90_000)
    }

    func testScannedPDFRequiresVisionAndRendersWithoutText() async throws {
        let doc = try await DocumentAttachmentReader().read(pdf(scan: true))
        XCTAssertFalse(doc.hasText)
        var budget = AttachmentRequestBudget()
        do { _ = try await DocumentAttachmentPreparer.prepare(doc, visualIndices: [], requireReadable: true, ocr: nil, budget: &budget, progress: { _ in }); XCTFail("must reject empty text") }
        catch DocumentReadError.noText {}
        let prepared = try await DocumentAttachmentPreparer.prepare(doc, visualIndices: [0,1], requireReadable: true, ocr: nil, budget: &budget, progress: { _ in })
        XCTAssertEqual(prepared.images.count, 2)
    }

    func testTextOnlyPreservesOmissionAndNoImagePayload() async throws {
        let doc = try await DocumentAttachmentReader().read(pdf())
        var budget = AttachmentRequestBudget()
        let result = try await DocumentAttachmentPreparer.prepare(doc, visualIndices: [], requireReadable: true, ocr: nil, budget: &budget, progress: { _ in })
        XCTAssertEqual(result.images.count, 0); XCTAssertTrue(result.text.contains("not analyzed")); XCTAssertTrue(result.text.contains("正文"))
    }

    func testPageRangesRejectEmptyOutOfBoundsReversedAndOversized() throws {
        for input in ["0", "3-1", "1,", "-1", "101", "1-101", "1;2", "a", "1-2-3"] {
            var options = DocumentOptions(); options.pages = input
            XCTAssertThrowsError(try options.indices(total: 100), input)
        }
        var options = DocumentOptions(); options.pages = "3,1-2,2"
        XCTAssertEqual(try options.indices(total: 5), [0,1,2])
        XCTAssertThrowsError(try DocumentOptions().indices(total: 101))
    }

    func testLockedCorruptMissingAndOversizedFiles() async throws {
        let original = try pdf()
        let doc = PDFDocument(data: try Data(contentsOf: original.localURL!))!
        let lockedURL = try folder().appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: lockedURL, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        XCTAssertTrue(PDFDocument(url: lockedURL)?.isLocked == true)
        let file = attachment(lockedURL)
        do { _ = try await DocumentAttachmentReader().read(file); XCTFail() } catch DocumentReadError.locked {}
        let bad = try folder().appendingPathComponent("bad.pdf"); try Data("not pdf".utf8).write(to: bad)
        do { _ = try await DocumentAttachmentReader().read(attachment(bad)); XCTFail() } catch {}
        try FileManager.default.removeItem(at: bad)
        do { _ = try await DocumentAttachmentReader().read(attachment(bad)); XCTFail() } catch {}
        try Data(repeating: 0, count: DocumentLimits.fileBytes + 1).write(to: bad)
        do { _ = try await DocumentAttachmentReader().read(attachment(bad)); XCTFail() } catch DocumentReadError.limit {}
    }

    func testDOCXParagraphTablesImagesAndNoExternalFetch() async throws {
        let file = try docx(body: "<w:p><w:r><w:t>标题 中文</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell B</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><a:blip r:embed=\"r1\"/><a:blip r:embed=\"r1\"/><a:blip r:embed=\"external\"/></w:p>", relationships: "<Relationship Id=\"r1\" Type=\"x/image\" Target=\"media/image.png\"/><Relationship Id=\"external\" Type=\"x/image\" Target=\"https://example.test/x.png\" TargetMode=\"External\"/>", image: true)
        let reader = DocumentAttachmentReader(); let doc = try await reader.read(file)
        XCTAssertTrue(text(doc).contains("标题 中文")); XCTAssertTrue(text(doc).contains("Cell A")); XCTAssertTrue(text(doc).contains("Cell B")); XCTAssertTrue(text(doc).contains("external image"))
        XCTAssertEqual(doc.visuals.count, 2); XCTAssertEqual(doc.visuals[0].source, doc.visuals[1].source)
        let image = try await reader.image(doc.visuals[0], in: doc)
        XCTAssertNotNil(UIImage(data: Data(base64Encoded: image.base64Data)!))
    }

    func testDOCXReportsUnsupportedObjectsAndFootnotes() async throws {
        let file = try docx(body: "<w:p><w:r><w:t>Body</w:t></w:r><w:object/></w:p>", extra: ["word/footnotes.xml": Data("<notes/>".utf8)])
        let doc = try await DocumentAttachmentReader().read(file)
        XCTAssertTrue(text(doc).contains("Unsupported embedded object")); XCTAssertTrue(text(doc).contains("footnotes"))
    }

    func testDOCXRejectsDTDAndExpandedEntryLimit() async throws {
        let file = try docx(body: "<!DOCTYPE bad><w:p/>")
        do { _ = try await DocumentAttachmentReader().read(file); XCTFail() } catch {}
        let huge = try docx(body: String(repeating: " ", count: 16 * 1024 * 1024 + 1))
        do { _ = try await DocumentAttachmentReader().read(huge); XCTFail() } catch {}
    }

    func testFileReplacementInvalidatesDocumentCache() async throws {
        let file = try pdf(); let reader = DocumentAttachmentReader()
        let old = try await reader.read(file)
        let newer = try pdf(pages: 3)
        try Data(contentsOf: newer.localURL!).write(to: file.localURL!)
        let fresh = try await reader.read(file)
        XCTAssertNotEqual(old.fingerprint, fresh.fingerprint); XCTAssertEqual(fresh.visuals.count, 3)
        do { _ = try await reader.image(old.visuals[0], in: old); XCTFail() } catch DocumentReadError.changed {}
    }

    func testAggregateBudgetsAndMetadataRoundTrip() throws {
        var b = AttachmentRequestBudget(); try b.addVisuals(12); XCTAssertThrowsError(try b.addVisuals(9))
        b = AttachmentRequestBudget(); try b.addText(String(repeating: "a", count: 40000)); XCTAssertThrowsError(try b.addText(String(repeating: "b", count: 20001)))
        var options = DocumentOptions(); options.pages = "2-5"; options.textOnly = true
        let values = options.applying(to: ["content_sha256": "keep"])
        XCTAssertEqual(values["content_sha256"], "keep"); XCTAssertEqual(DocumentOptions(metadata: values), options)
    }

    func testOCRCacheConfigurationAndContentIsolation() async throws {
        let probe = OCRProbe(); let ocr = OCRService { image,_,_,_ in try await probe.recognize(image) }
        var p = provider(); let a = ChatRequestImage(mimeType: "image/png", base64Data: "AAAA")
        _ = try await ocr.text(image: a, provider: p, modelID: "fixture-ocr", prompt: "one")
        _ = try await ocr.text(image: a, provider: p, modelID: "fixture-ocr", prompt: "one")
        var count = await probe.calls; XCTAssertEqual(count, 1)
        _ = try await ocr.text(image: a, provider: p, modelID: "fixture-ocr", prompt: "two")
        p.baseURL += "/other"
        _ = try await ocr.text(image: a, provider: p, modelID: "fixture-ocr", prompt: "two")
        _ = try await ocr.text(image: a, provider: p, modelID: "other", prompt: "two")
        _ = try await ocr.text(image: ChatRequestImage(mimeType: "image/png", base64Data: "BBBB"), provider: p, modelID: "other", prompt: "two")
        count = await probe.calls; XCTAssertEqual(count, 5)
    }

    func testOCRQueueCancellationDoesNotCancelOtherConsumer() async throws {
        let probe = OCRProbe(); let ocr = OCRService { image,_,_,_ in try await probe.recognize(image, delay: 80_000_000) }
        let p = provider(); let image = ChatRequestImage(mimeType: "image/png", base64Data: "AAAA")
        let first = Task { try await ocr.text(image: image, provider: p, modelID: "m", prompt: "p") }
        try await Task.sleep(nanoseconds: 10_000_000)
        let cancelled = Task { try await ocr.text(image: image, provider: p, modelID: "m", prompt: "p2") }
        let duplicate = Task { try await ocr.text(image: image, provider: p, modelID: "m", prompt: "p") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail() } catch is CancellationError {}
        let one = try await first.value; let two = try await duplicate.value
        XCTAssertEqual(one, two)
        let count = await probe.calls, peak = await probe.peak
        XCTAssertEqual(count, 1); XCTAssertEqual(peak, 1)
    }

    func testOCRActiveCancellationAndEmptyOutputAreNotCached() async throws {
        let probe = OCRProbe(); let ocr = OCRService { image,_,_,_ in try await probe.recognize(image, delay: 50_000_000) }
        let p = provider(), image = ChatRequestImage(mimeType: "image/png", base64Data: "AAAA")
        let task = Task { try await ocr.text(image: image, provider: p, modelID: "m", prompt: "p") }
        for _ in 0..<200 {
            if await probe.calls > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        _ = try await ocr.text(image: image, provider: p, modelID: "m", prompt: "p")
        let count = await probe.calls; XCTAssertEqual(count, 2)
        let empty = OCRService { _,_,_,_ in " " }
        do { _ = try await empty.text(image: image, provider: p, modelID: "m", prompt: "p"); XCTFail() } catch {}
    }

    func testOCRCacheHitSkipsRendering() async throws {
        let probe = OCRProbe(); let ocr = OCRService { image,_,_,_ in try await probe.recognize(image) }; let p = provider()
        _ = try await ocr.text(source: "document-page-key", provider: p, modelID: "m", prompt: "p") { ChatRequestImage(mimeType: "image/jpeg", base64Data: "AA") }
        _ = try await ocr.text(source: "document-page-key", provider: p, modelID: "m", prompt: "p") { throw DocumentReadError.unreadable }
        let count = await probe.calls; XCTAssertEqual(count, 1)
    }

    private func model(ocr: Bool, vision: Bool) throws -> (AppModel, UUID) {
        URLProtocol.registerClass(DocumentMockURLProtocol.self)
        DocumentMockURLProtocol.state.reset()
        OCRService.shared.clearCache()
        let model = AppModel()
        let chat = Conversation(title: "Document fixture", assistantID: model.currentAssistantID.uuidString)
        try model.reviewInstallStore(ConversationSnapshot(conversations: [chat], messagesByConversation: [chat.id: []]), directory: folder())
        var p = provider()
        p.models = [ModelConfiguration(id: "fixture-main", capabilityOverride: ModelCapabilities(input: vision ? [.text,.image] : [.text])), ModelConfiguration(id: "fixture-ocr", capabilityOverride: ModelCapabilities(input: [.text,.image]))]
        model.providers = [p]; model.selectedModel = ModelSelection(providerID: p.id, modelID: "fixture-main")
        model.preferences.ocrEnabled = ocr; model.preferences.ocrProviderID = p.id.uuidString; model.preferences.ocrModelID = "fixture-ocr"
        model.preferences.resendHistoricalImages = false
        return (model, chat.id)
    }
    private func wait(_ model: AppModel, _ id: UUID) async throws {
        for _ in 0..<1000 { if !model.isConversationStreaming(id) { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        model.stopStreaming(); XCTFail("Timed out waiting for fixture")
    }
    private func mainBodies() -> [[String: Any]] { DocumentMockURLProtocol.state.snapshot().filter { $0["model"] as? String == "fixture-main" } }
    private func json(_ body: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)! }

    func testEndToEndPDFRouteMatrix() async throws {
        for ocr in [false,true] {
            for vision in [false,true] {
                let (m,id) = try model(ocr: ocr, vision: vision)
                m.setComposerDraftText("Read the file", for: id); m.setComposerPendingAttachments([try pdf()], for: id)
                XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
                let bodies = mainBodies(); XCTAssertEqual(bodies.count, 1, m.errorMessage)
                guard let body = bodies.first else { continue }
                let payload = json(body)
                XCTAssertTrue(payload.contains("正文")); XCTAssertEqual(payload.contains("image_url"), !ocr && vision)
                XCTAssertEqual(payload.contains("Recognized document visual"), ocr)
                let saved = try m.reviewReadStore(); XCTAssertEqual(saved.messagesByConversation[id]?.filter { $0.role == .user }.count, 1)
                XCTAssertTrue(m.documentReadingProgress.isEmpty)
            }
        }
    }

    func testEndToEndPartialOCRFailureThenRetryReusesSuccess() async throws {
        let (m,id) = try model(ocr: true, vision: false)
        DocumentMockURLProtocol.state.reset(fail: 2)
        m.setComposerDraftText("Read", for: id); m.setComposerPendingAttachments([try pdf()], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertEqual(mainBodies().count, 0); XCTAssertFalse(m.errorMessage.isEmpty)
        XCTAssertTrue(m.errorMessage.contains("Page 2"))
        let user = m.messages.first { $0.role == .user }!
        DocumentMockURLProtocol.state.reset()
        m.regenerateResponse(around: user.id); try await wait(m,id)
        let requests = DocumentMockURLProtocol.state.snapshot()
        XCTAssertEqual(requests.filter { $0["model"] as? String == "fixture-ocr" }.count, 1)
        XCTAssertEqual(mainBodies().count, 1)
    }

    func testEndToEndNoTextScanBlocksTextModelAndDocumentOptionsPersist() async throws {
        let (m,id) = try model(ocr: false, vision: false); let file = try pdf(scan: true)
        m.setComposerPendingAttachments([file], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertEqual(mainBodies().count, 0); XCTAssertFalse(m.errorMessage.isEmpty)
        let user = m.messages.first { $0.role == .user }!
        var options = DocumentOptions(); options.pages = "1"; options.textOnly = true
        XCTAssertTrue(m.updateDocumentOptions(options, attachmentID: file.id, messageID: user.id, conversationID: id))
        let saved = try m.reviewReadStore().messagesByConversation[id]!.first { $0.id == user.id }!
        XCTAssertEqual(saved.attachments.first?.metadata["document_pages"], "1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.localURL!.path))
    }

    func testEndToEndHistoricalDocumentVisualsRespectHistoryOff() async throws {
        let (m,id) = try model(ocr: false, vision: true)
        m.setComposerPendingAttachments([try pdf()], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        DocumentMockURLProtocol.state.reset()
        if let request = m.pendingUserMessageSendPositionRequest { m.consumeUserMessageSendPositionRequest(request.id) }
        m.setComposerDraftText("Follow-up", for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertEqual(mainBodies().count, 1)
        if let body = mainBodies().first { XCTAssertFalse(json(body).contains("image_url")); XCTAssertTrue(json(body).contains("not analyzed")) }
    }

    func testEndToEndStopBeforePreparationStartsMakesNoRequests() async throws {
        let (m,id) = try model(ocr: true, vision: false)
        m.setComposerPendingAttachments([try pdf(pages: 20)], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); m.stopStreaming()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(DocumentMockURLProtocol.state.snapshot().isEmpty)
        XCTAssertEqual(try m.reviewReadStore().messagesByConversation[id]!.filter { $0.role == .user }.count, 1)
    }

    func testBackgroundParsingHeartbeatAndWarmReadTiming() async throws {
        let file = try pdf(pages: 100); let reader = DocumentAttachmentReader()
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        let start = CFAbsoluteTimeGetCurrent(); _ = try await reader.read(file)
        let cold = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let warmStart = CFAbsoluteTimeGetCurrent(); _ = try await reader.read(file)
        let warm = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000
        heartbeat.cancel()
        print("DOCUMENT_PERF cold100pages_ms=\(cold) warm_ms=\(warm) main_actor_ticks=\(ticks)")
        XCTAssertGreaterThan(ticks, 0)
    }
    func testEndToEndOrdinaryImageRoutingAndUnsupportedModel() async throws {
        for ocr in [false, true] {
            for vision in [false, true] {
                let (m,id) = try model(ocr: ocr, vision: vision)
                let url = try folder().appendingPathComponent("photo.png")
                let data = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 100, height: 80)) }.pngData()!
                try data.write(to: url)
                let image = MessageAttachment(kind: .image, localURL: url, fileName: "photo.png", mimeType: "image/png")
                m.setComposerPendingAttachments([image], for: id)
                XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
                XCTAssertEqual(mainBodies().count, ocr || vision ? 1 : 0)
                if let body = mainBodies().first { XCTAssertEqual(json(body).contains("image_url"), !ocr && vision) }
            }
        }
    }

    func testEndToEndDOCXAndOversizedVisualCount() async throws {
        let (m,id) = try model(ocr: true, vision: false)
        let file = try docx(body: "<w:p><w:r><w:t>Word body</w:t></w:r><a:blip r:embed=\"r1\"/></w:p>", relationships: "<Relationship Id=\"r1\" Type=\"x/image\" Target=\"media/image.png\"/>", image: true)
        m.setComposerPendingAttachments([file], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertEqual(mainBodies().count, 1)
        if let body = mainBodies().first { XCTAssertTrue(json(body).contains("Word body")); XCTAssertTrue(json(body).contains("Recognized document visual")) }
        let (tooMany,chat) = try model(ocr: true, vision: true)
        tooMany.setComposerPendingAttachments([try pdf(pages: 21)], for: chat)
        XCTAssertTrue(tooMany.sendDraft(for: chat)); try await wait(tooMany,chat)
        XCTAssertTrue(DocumentMockURLProtocol.state.snapshot().isEmpty)
        XCTAssertFalse(tooMany.errorMessage.isEmpty)
    }

    func testEndToEndGroupSharesOCRCacheAndBothModelsReceiveText() async throws {
        let (m,id) = try model(ocr: true, vision: false)
        let first = m.currentAssistantID
        let second = AssistantProfile(name: "Second", chatModel: m.selectedModel)
        m.assistants.append(second)
        m.conversations[0].groupAssistantIDs = [first.uuidString, second.id.uuidString]
        m.setComposerDraftText("Read together", for: id)
        m.setComposerPendingAttachments([try pdf()], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertEqual(mainBodies().count, 2, m.errorMessage)
        XCTAssertEqual(DocumentMockURLProtocol.state.snapshot().filter { $0["model"] as? String == "fixture-ocr" }.count, 2)
        for body in mainBodies() { XCTAssertTrue(json(body).contains("Recognized document visual")); XCTAssertFalse(json(body).contains("image_url")) }
    }

    func testEndToEndHistoricalVisualLimitAppliesPerPage() async throws {
        let (m,id) = try model(ocr: false, vision: true)
        m.preferences.resendHistoricalImages = true; m.preferences.historicalImageResendLimit = 1
        m.setComposerPendingAttachments([try pdf(pages: 3)], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        DocumentMockURLProtocol.state.reset()
        if let request = m.pendingUserMessageSendPositionRequest { m.consumeUserMessageSendPositionRequest(request.id) }
        m.setComposerDraftText("Again", for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertEqual(mainBodies().count, 1)
        if let body = mainBodies().first {
            let messages = body["messages"] as? [[String: Any]] ?? []
            let count = messages.reduce(0) { sum, message in sum + ((message["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image_url" }.count ?? 0) }
            XCTAssertEqual(count, 1)
        }
    }

    func testUnsupportedWordAndOptionsFailedSaveRetainOriginal() async throws {
        let (m,id) = try model(ocr: false, vision: false)
        let url = try folder().appendingPathComponent("old.doc"); try Data([0,1,2,3]).write(to: url)
        var file = attachment(url); file.mimeType = "application/msword"
        m.setComposerPendingAttachments([file], for: id)
        XCTAssertTrue(m.sendDraft(for: id)); try await wait(m,id)
        XCTAssertTrue(DocumentMockURLProtocol.state.snapshot().isEmpty); XCTAssertFalse(m.errorMessage.isEmpty)
        let original = m.messages.first { $0.role == .user }!
        m.reviewFailCommits(true)
        var options = DocumentOptions(); options.textOnly = true
        XCTAssertFalse(m.updateDocumentOptions(options, attachmentID: file.id, messageID: original.id, conversationID: id))
        XCTAssertEqual(m.messages.first { $0.id == original.id }?.attachments, original.attachments)
        m.reviewFailCommits(false)
    }

    func testDOCXAlternateContentDoesNotDuplicateImage() async throws {
        let file = try docx(body: "<w:p><w:r><w:t>Body</w:t></w:r><mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Choice Requires=\"a\"><a:blip r:embed=\"r1\"/></mc:Choice><mc:Fallback><a:blip r:embed=\"r1\"/></mc:Fallback></mc:AlternateContent></w:p>", relationships: "<Relationship Id=\"r1\" Type=\"x/image\" Target=\"media/image.png\"/>", image: true)
        let doc = try await DocumentAttachmentReader().read(file)
        XCTAssertEqual(doc.visuals.count, 1)
    }

    func testPDFContentTypeWithoutExtension() async throws {
        let original = try pdf()
        let url = try folder().appendingPathComponent("download")
        try Data(contentsOf: original.localURL!).write(to: url)
        let file = MessageAttachment(kind: .file, localURL: url, fileName: "download", mimeType: "application/pdf")
        XCTAssertTrue(DocumentAttachmentReader.supports(file))
        let doc = try await DocumentAttachmentReader().read(file)
        XCTAssertTrue(doc.hasText)
    }

    func testDocumentOptionsLayoutSnapshots() async throws {
        let file = try pdf(pages: 12)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for width in [320,393] {
            let height: CGFloat = width == 320 ? 690 : 852
            let controller = UIHostingController(rootView:
                DocumentAttachmentOptionsView(attachment: file, report: "文字层：已读取 · 图片/页面 12/12", save: { _ in true })
                    .environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(.light)
            )
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let old = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: height)
            window.rootViewController = controller; window.makeKeyAndVisible()
            controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let path = directory.appendingPathComponent("document-options-\(width).png")
            try image.pngData()!.write(to: path)
            print("DOCUMENT_UI_SNAPSHOT \(path.path)")
            let attachment = XCTAttachment(image: image); attachment.name = "Document options \(width)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertGreaterThan(image.size.height, 600)
            window.isHidden = true; old?.makeKeyAndVisible()
        }
    }

    func testColdRecoveryRetainsDocumentAndInterruptedReply() throws {
        let directory = try folder()
        let c = Conversation(title: "Recovery")
        let file = try pdf()
        let user = ChatMessage(conversationID: c.id, role: .user, text: "Read file", attachments: [file])
        let assistant = ChatMessage(conversationID: c.id, role: .assistant, text: "", status: .streaming)
        try ConversationStore(directoryURL: directory).save(ConversationSnapshot(conversations: [c], messagesByConversation: [c.id: [user,assistant]]))
        switch try ConversationStore(directoryURL: directory).load() {
        case .loaded(let snapshot), .recoveredFromBackup(let snapshot, _):
            let rows = snapshot.messagesByConversation[c.id]!
            XCTAssertEqual(rows.map(\.id), [user.id,assistant.id]); XCTAssertEqual(rows[1].status, .interrupted)
            XCTAssertEqual(rows[0].attachments.first?.id, file.id)
        case .missing: XCTFail()
        }
    }

    func testDOCXEntityDeclarationsAreRejectedAcrossEncodings() async throws {
        let xml = "<!DOCTYPE w:document [<!ENTITY payload 'must not expand'>]><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>&payload;</w:t></w:r></w:p></w:body></w:document>"
        for bytes in [Data(xml.utf8), xml.data(using: .utf16)!, xml.data(using: .utf16LittleEndian)!] {
            let file = try docx(body: "", rawBody: bytes)
            do { _ = try await DocumentAttachmentReader().read(file); XCTFail("Entity declaration must not be processed") }
            catch DocumentReadError.unreadable {}
        }
    }

    func testDOCXTransparentImageKeepsWhitePaperBackground() async throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { c in
            UIColor.black.setFill(); c.fill(CGRect(x: 20, y: 10, width: 40, height: 20))
        }.pngData()!
        let file = try docx(body: "<w:p><a:blip r:embed=\"r1\"/></w:p>", relationships: "<Relationship Id=\"r1\" Type=\"x/image\" Target=\"media/image.png\"/>", extra: ["word/media/image.png":png])
        let reader = DocumentAttachmentReader(); let doc = try await reader.read(file)
        let payload = try await reader.image(doc.visuals[0], in: doc)
        let cg = UIImage(data: Data(base64Encoded: payload.base64Data)!)!.cgImage!
        let ctx = CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        let bytes = ctx.data!.assumingMemoryBound(to:UInt8.self)
        XCTAssertGreaterThan(bytes[0],240); XCTAssertGreaterThan(bytes[1],240); XCTAssertGreaterThan(bytes[2],240)
        let center = ((cg.height / 2) * cg.width + cg.width / 2) * 4
        XCTAssertLessThan(bytes[center],30)
    }

    func testTwentyPageRenderingMemoryAndCancellation() async throws {
        func residentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        }
        let file = try pdf(pages: 20, scan: true)
        let reader = DocumentAttachmentReader(); let document = try await reader.read(file)
        let before = residentBytes(); var peak = before; var outputs: [ChatRequestImage] = []
        let start = CFAbsoluteTimeGetCurrent()
        var budget = AttachmentRequestBudget()
        for visual in document.visuals {
            let image = try await reader.image(visual, in: document)
            try budget.addImage(image); outputs.append(image)
            peak = max(peak, residentBytes())
        }
        XCTAssertEqual(outputs.count, 20)
        print("DOCUMENT_RENDER_PERF pages=20 elapsed_ms=\((CFAbsoluteTimeGetCurrent()-start)*1000) resident_before=\(before) sampled_peak=\(peak) sampled_delta=\(peak-before) base64_bytes=\(budget.imageBytes)")
        var rendered = 0
        let operation = Task { @MainActor in
            for visual in document.visuals {
                _ = try await reader.image(visual, in: document); rendered += 1
            }
        }
        while rendered < 2 { await Task.yield() }
        operation.cancel()
        do { try await operation.value; XCTFail("Rendering must stop at a page boundary") }
        catch is CancellationError {}
        XCTAssertLessThan(rendered, 20)
    }

}

extension DocumentAttachmentTests {
    func testNewestBatchScanIsIncludedWhenHistoryImagesAreOff() async throws {
        let (m, id) = try model(ocr: false, vision: true)
        let document = try pdf(pages: 1, scan: true)
        let batch = UUID()
        let rows = [ChatMessage(conversationID: id, role: .user, text: "old", attachments: [document]),
                    ChatMessage(conversationID: id, role: .assistant, text: "old answer"),
                    ChatMessage(conversationID: id, role: .user, text: "new document", userSendBatchID: batch, attachments: [document]),
                    ChatMessage(conversationID: id, role: .user, text: "caption", userSendBatchID: batch)]
        for type: ProviderType in [.openAI, .claude, .google] {
            var p = m.providers[0]; p.type = type
            let wire = try await ChatRequestPreparation.messages(from: rows, assistant: m.currentAssistant, provider: p,
                preferences: m.preferences, conversation: m.conversations[0], assistants: m.assistants, ocrContext: nil, modelID: "fixture-main")
            XCTAssertTrue(wire[0].images.isEmpty)
            XCTAssertEqual(wire[2].images.count, 1)
            XCTAssertTrue(wire[3].images.isEmpty)
        }
    }

    func testPlainTextRetainsFullContentBeyondDocumentBudget() async throws {
        let (m, id) = try model(ocr: false, vision: false)
        let url = try folder().appendingPathComponent("large.md")
        let content = String(repeating: "Full text 原文\n", count: 10000) + "END OF ORIGINAL"
        try content.write(to: url, atomically: true, encoding: .utf8)
        let rows = [ChatMessage(conversationID: id, role: .user, text: "Read", attachments: [MessageAttachment(kind: .file, localURL: url, fileName: "large.md", mimeType: "text/markdown")])]
        var events = 0
        let wire = try await ChatRequestPreparation.messages(from: rows, assistant: m.currentAssistant, provider: m.providers[0],
            preferences: m.preferences, conversation: m.conversations[0], assistants: m.assistants, ocrContext: nil, modelID: "fixture-main",
            progress: { _ in events += 1 }, report: { _, _ in events += 1 })
        XCTAssertTrue(wire[0].content.contains(content)); XCTAssertEqual(events, 0)
    }

    func testNoAttachmentsKeepsTimeReasoningAndSkipsDocumentProgress() async throws {
        let (m, id) = try model(ocr: true, vision: false)
        var assistant = m.currentAssistant; assistant.messageTimeEnabled = true
        let row = ChatMessage(conversationID: id, role: .user, text: "hello", createdAt: Date(timeIntervalSince1970: 0), sentTimeZoneOffsetSeconds: 0)
        var events = 0
        let wire = try await ChatRequestPreparation.messages(from: [row], assistant: assistant, provider: m.providers[0],
            preferences: m.preferences, conversation: m.conversations[0], assistants: m.assistants, ocrContext: nil, modelID: "fixture-main",
            progress: { _ in events += 1 }, report: { _, _ in events += 1 })
        XCTAssertEqual(wire[0].content, "hello\n\n[1970-01-01 00:00]")
        XCTAssertEqual(events, 0); XCTAssertTrue(DocumentMockURLProtocol.state.snapshot().isEmpty)
    }
}
