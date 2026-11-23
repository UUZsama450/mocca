import Foundation
import CryptoKit

struct ExternalImageGenerationRequest: Hashable, Sendable {
    let prompt: String
    /// nil is the legacy text-only format. With available images it is ambiguous
    /// and must fail instead of silently turning an edit into text-to-image.
    var referenceImageIDs: [String]? = nil
    var invalidReferenceSelection = false
}

struct ImageGenerationReference: Hashable, Sendable {
    let id: String
    let mimeType: String
    let base64Data: String

    init(mimeType: String, base64Data: String) {
        self.mimeType = Data(base64Encoded: String(base64Data.prefix(64))).flatMap(ImageGenerationProtocol.detectedMIME) ?? mimeType.lowercased()
        self.base64Data = base64Data
        let digest = SHA256.hash(data: Data((self.mimeType + ":" + base64Data).utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        id = "image_" + digest
    }
    var dataURL: String { "data:\(mimeType);base64,\(base64Data)" }
}

struct ImageReferenceScope: Sendable {
    var images: [ImageGenerationReference] = []

    func resolve(_ request: ExternalImageGenerationRequest) throws -> [ImageGenerationReference] {
        guard !request.invalidReferenceSelection else { throw ImageGenerationProtocolError.invalidReferences }
        guard let ids = request.referenceImageIDs else {
            guard images.isEmpty else { throw ImageGenerationProtocolError.missingReferenceSelection }
            return []
        }
        var result: [ImageGenerationReference] = []
        var seen = Set<String>()
        for id in ids {
            guard let image = images.first(where: { $0.id == id }) else {
                throw ImageGenerationProtocolError.invalidReferences
            }
            if seen.insert(id).inserted { result.append(image) }
        }
        return result
    }
}

enum ImageGenerationTransport: String, Sendable {
    case openAIJSON, openAIForm, openRouter, chatCompletions
    case geminiContent, geminiInteractions
}

enum ImageGenerationProtocolError: LocalizedError {
    case invalidReferences, missingReferenceSelection, invalidImage, oversizedImages
    case tooManyImages, unsupportedReferences, invalidEndpoint
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidReferences: key = "参考图不在本轮可用图片中，请重新添加图片后重试。"
        case .missingReferenceSelection: key = "模型没有明确选择参考图，本次已停止生图。请重试并说明要使用哪张图片。"
        case .invalidImage: key = "参考图片数据或格式无效，请重新添加图片后重试。"
        case .oversizedImages: key = "参考图片总大小过大，请减少图片或压缩后重试。"
        case .tooManyImages: key = "这个图像接口一次最多接收 16 张参考图，请减少图片后重试。"
        case .unsupportedReferences: key = "所选模型或接口不支持参考图编辑，请选择支持图片输入的生图模型。"
        case .invalidEndpoint: key = "图像生成地址无效"
        }
        return ErrorLocalization.lookup(key)
    }
}

/// Request encoding is shared with the local protocol tests. There are no retries
/// or model substitutions here: a reference request must remain a reference request.
enum ImageGenerationProtocol {
    struct Encoded: Sendable {
        let path: String
        let contentType: String
        let data: Data
    }

    static func detectedMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if bytes.starts(with: [255, 216, 255]) { return "image/jpeg" }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF", String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        return nil
    }

    static func encode(
        transport: ImageGenerationTransport, model: String, prompt: String,
        references: [ImageGenerationReference], extras: [String: Any] = [:],
        chatPath: String = "/chat/completions"
    ) throws -> Encoded {
        try Task.checkCancellation()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImageGenerationProtocolError.invalidEndpoint
        }
        let encodedSize = references.reduce(0) { $0 + $1.base64Data.utf8.count }
        guard encodedSize <= 70 * 1024 * 1024 else { throw ImageGenerationProtocolError.oversizedImages }
        for reference in references {
            try Task.checkCancellation()
            guard ["image/png", "image/jpeg", "image/webp", "image/gif", "image/heic", "image/heif"].contains(reference.mimeType),
                  let decoded = Data(base64Encoded: reference.base64Data), !decoded.isEmpty else {
                throw ImageGenerationProtocolError.invalidImage
            }
        }
        let isOpenAI = transport == .openAIJSON || transport == .openAIForm
        if isOpenAI {
            guard references.count <= 16 else { throw ImageGenerationProtocolError.tooManyImages }
            guard references.allSatisfy({ ["image/png", "image/jpeg", "image/webp"].contains($0.mimeType) }) else {
                throw ImageGenerationProtocolError.invalidImage
            }
        }
        func json(_ path: String, _ body: [String: Any]) throws -> Encoded {
            Encoded(path: path, contentType: "application/json", data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }
        let imageKeys: Set<String> = ["n", "size", "quality", "output_format", "output_compression", "background", "moderation", "input_fidelity", "response_format", "user"]
        var imageBody = extras.filter { imageKeys.contains($0.key) }
        // A chat response_format object is not an Images API response_format.
        if imageBody["response_format"] != nil && !(imageBody["response_format"] is String) {
            imageBody.removeValue(forKey: "response_format")
        }
        imageBody["model"] = model
        imageBody["prompt"] = prompt
        switch transport {
        case .openAIJSON:
            if references.isEmpty { return try json("images/generations", imageBody) }
            imageBody["images"] = references.map { ["image_url": $0.dataURL] }
            return try json("images/edits", imageBody)
        case .openAIForm:
            if references.isEmpty { return try json("images/generations", imageBody) }
            let boundary = "MoccaImage-" + UUID().uuidString
            var data = Data()
            func append(_ value: String) { data.append(Data(value.utf8)) }
            for key in imageBody.keys.sorted() {
                let value = imageBody[key]!
                let string: String
                if let raw = value as? String { string = raw }
                else { string = String(data: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), encoding: .utf8)! }
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(string)\r\n")
            }
            for (index, reference) in references.enumerated() {
                let ext = reference.mimeType == "image/jpeg" ? "jpg" : (reference.mimeType == "image/webp" ? "webp" : "png")
                let field = references.count == 1 ? "image" : "image[]"
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"reference-\(index + 1).\(ext)\"\r\nContent-Type: \(reference.mimeType)\r\n\r\n")
                data.append(Data(base64Encoded: reference.base64Data)!)
                append("\r\n")
            }
            append("--\(boundary)--\r\n")
            return Encoded(path: "images/edits", contentType: "multipart/form-data; boundary=\(boundary)", data: data)
        case .openRouter:
            let routerKeys: Set<String> = ["resolution", "aspect_ratio", "seed", "provider", "provider_tag", "user"]
            imageBody.merge(extras.filter { routerKeys.contains($0.key) }) { _, value in value }
            if !references.isEmpty {
                imageBody["input_references"] = references.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] as [String: Any] }
            }
            imageBody["stream"] = false
            return try json("images", imageBody)
        case .chatCompletions:
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            content += references.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
            var body = extras.filter { ["provider", "image_config", "temperature", "top_p", "max_tokens", "seed"].contains($0.key) }
            body["model"] = model
            body["messages"] = [["role": "user", "content": content]]
            body["modalities"] = ["text", "image"]
            body["stream"] = false
            return try json(chatPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")), body)
        case .geminiContent:
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else { throw ImageGenerationProtocolError.invalidEndpoint }
            var parts: [[String: Any]] = [["text": prompt]]
            parts += references.map { ["inlineData": ["mimeType": $0.mimeType, "data": $0.base64Data]] }
            var config = extras["generationConfig"] as? [String: Any] ?? [:]
            config["responseModalities"] = ["TEXT", "IMAGE"]
            var body: [String: Any] = ["contents": [["role": "user", "parts": parts]], "generationConfig": config]
            if let safety = extras["safetySettings"] { body["safetySettings"] = safety }
            return try json("models/\(encoded):generateContent", body)
        case .geminiInteractions:
            var input: [[String: Any]] = [["type": "text", "text": prompt]]
            input += references.map { ["type": "image", "mime_type": $0.mimeType, "data": $0.base64Data] }
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            let suppliedFormat = extras["response_format"] as? [String: Any] ?? [:]
            var imageFormat = suppliedFormat.filter { ["mime_type", "aspect_ratio", "image_size"].contains($0.key) }
            imageFormat["type"] = "image"
            return try json("interactions", ["model": name, "input": input, "response_format": imageFormat])

        }
    }
}

enum ExternalImageGenerationCodec {
    struct Parsed: Sendable {
        let displayText: String
        let requests: [ExternalImageGenerationRequest]
    }

    private static let openingMarker = "<kg>"
    private static let fullPattern = #"(?s)<kg>\s*(\{.*?\})\s*</kg>"#
    private static let fullRegex = try! NSRegularExpression(pattern: fullPattern)

    static func parse(_ text: String) -> Parsed {
        // Finalization uses this parser too. Ordinary replies still receive
        // the same whitespace cleanup without two full regular-expression scans.
        guard text.contains(openingMarker) else {
            return Parsed(displayText: cleanedDisplayText(text), requests: [])
        }
        let nsText = text as NSString
        let literals = MarkdownLiteralRanges(text, isStreaming: true)
        let matches = fullRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var consumed: [NSRange] = []
        let requests = matches.compactMap { match -> ExternalImageGenerationRequest? in
            guard literals.allowsMarker(at: match.range.location), match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { return nil }
            let json = nsText.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawPrompt = object["prompt"] as? String else { return nil }
            let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return nil }
            let rawReferences = object["reference_images"]
            let references = (rawReferences as? [String])?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            consumed.append(match.range)
            return ExternalImageGenerationRequest(prompt: prompt, referenceImageIDs: references,
                invalidReferenceSelection: rawReferences != nil && references == nil)
        }
        let stripped = MarkdownLiteralRanges.removing(consumed, from: text)
        return Parsed(displayText: cleanedDisplayText(stripped), requests: requests)
    }

    /// Hide executable blocks and unfinished controls outside literal examples.
    /// Complete malformed blocks remain visible instead of losing their text.
    static func stripForDisplay(_ text: String) -> String {
        // Every complete or partial marker contains ASCII '<'. Whitespace
        // cleanup cannot introduce it, so ordinary prose needs no marker scans.
        guard text.utf8.contains(0x3C) else {
            return cleanedDisplayText(text)
        }
        // A complete control block cannot match without its exact opening
        // marker. Ordinary streaming text still goes through the established
        // whitespace cleanup and partial-marker handling, but avoids the full
        // regular expression and JSON request scan.
        let parsed = text.contains(openingMarker)
            ? parse(text).displayText
            : cleanedDisplayText(text)
        return cleanedDisplayText(MarkdownLiteralRanges.hidingIncompleteMarker(
            in: parsed, opening: openingMarker, closing: "</kg>"
        ))
    }

    static func cleanedDisplayText(_ text: String) -> String {
        MarkdownLiteralRanges.cleaningDisplayWhitespace(text)
    }
}

