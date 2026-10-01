import AVFoundation
import Combine
import Foundation
import Security

enum VoiceServiceKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case openAI = "openai"
    case gemini
    case miniMax = "minimax"
    case qwen
    case groq
    case xAI = "xai"
    case elevenLabs = "elevenlabs"
    case mimo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .miniMax: "MiniMax"
        case .qwen: "Qwen"
        case .groq: "Groq"
        case .xAI: "xAI"
        case .elevenLabs: "ElevenLabs"
        case .mimo: "MiMo"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .miniMax: "https://api.minimaxi.com/v1"
        case .qwen: "https://dashscope.aliyuncs.com/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .xAI: "https://api.x.ai/v1"
        case .elevenLabs: "https://api.elevenlabs.io"
        case .mimo: "https://api.xiaomimimo.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini-tts"
        case .gemini: "gemini-2.5-flash-preview-tts"
        case .miniMax: "speech-2.6-turbo"
        case .qwen: "qwen3-tts-flash"
        case .groq: "canopylabs/orpheus-v1-english"
        case .xAI: ""
        case .elevenLabs: "eleven_multilingual_v2"
        case .mimo: "mimo-v2-tts"
        }
    }

    var defaultVoice: String {
        switch self {
        case .openAI: "alloy"
        case .gemini: "Kore"
        case .miniMax: "female-shaonv"
        case .qwen: "Cherry"
        case .groq: "austin"
        case .xAI: "eve"
        case .elevenLabs: ""
        case .mimo: "mimo_default"
        }
    }
}

struct VoiceServiceConfiguration: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var kind: VoiceServiceKind
    var enabled: Bool
    var name: String
    var endpoint: String
    var apiKey: String
    var model: String
    var voice: String
    var emotion: String
    var speed: Double
    var language: String
    var outputFormat: String

    init(
        id: UUID = UUID(),
        kind: VoiceServiceKind,
        enabled: Bool = true,
        name: String = "",
        endpoint: String = "",
        apiKey: String = "",
        model: String = "",
        voice: String = "",
        emotion: String = "calm",
        speed: Double = 1.0,
        language: String = "",
        outputFormat: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.emotion = emotion
        self.speed = min(max(speed, 0.5), 2.0)
        self.language = language
        self.outputFormat = outputFormat
    }

    static func makeDefault(kind: VoiceServiceKind) -> VoiceServiceConfiguration {
        VoiceServiceConfiguration(
            kind: kind,
            name: "\(kind.title) TTS",
            endpoint: kind.defaultEndpoint,
            model: kind.defaultModel,
            voice: kind.defaultVoice,
            emotion: "calm",
            speed: 1.0,
            language: kind == .qwen ? "Auto" : (kind == .xAI ? "auto" : ""),
            outputFormat: kind == .elevenLabs ? "mp3_44100_128" : ""
        )
    }

    var resolvedName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "\(kind.title) TTS" : value
    }

    var resolvedEndpoint: String {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? kind.defaultEndpoint : value
    }

    var resolvedModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? kind.defaultModel : value
    }

    var resolvedVoice: String {
        let value = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? kind.defaultVoice : value
    }

    var validationMessage: String? {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ErrorLocalization.lookup("请填写 API Key")
        }
        if resolvedEndpoint.isEmpty {
            return ErrorLocalization.lookup("请填写服务地址")
        }
        if kind != .xAI && resolvedModel.isEmpty {
            return ErrorLocalization.lookup("请填写模型")
        }
        if resolvedVoice.isEmpty {
            return ErrorLocalization.lookup(kind == .elevenLabs ? "请填写 Voice ID" : "请填写语音")
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case enabled
        case name
        case endpoint
        case baseURL = "baseUrl"
        case apiKey
        case model
        case modelID = "modelId"
        case voice
        case voiceName
        case voiceID = "voiceId"
        case emotion
        case speed
        case language
        case languageType
        case outputFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(VoiceServiceKind.self, forKey: .kind) ?? .openAI
        let defaults = Self.makeDefault(kind: kind)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
            ?? container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? defaults.endpoint
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? container.decodeIfPresent(String.self, forKey: .modelID)
            ?? defaults.model
        voice = try container.decodeIfPresent(String.self, forKey: .voice)
            ?? container.decodeIfPresent(String.self, forKey: .voiceName)
            ?? container.decodeIfPresent(String.self, forKey: .voiceID)
            ?? defaults.voice
        emotion = try container.decodeIfPresent(String.self, forKey: .emotion) ?? defaults.emotion
        speed = min(max(try container.decodeIfPresent(Double.self, forKey: .speed) ?? defaults.speed, 0.5), 2.0)
        language = try container.decodeIfPresent(String.self, forKey: .language)
            ?? container.decodeIfPresent(String.self, forKey: .languageType)
            ?? defaults.language
        outputFormat = try container.decodeIfPresent(String.self, forKey: .outputFormat)
            ?? defaults.outputFormat
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(model, forKey: .model)
        try container.encode(voice, forKey: .voice)
        try container.encode(emotion, forKey: .emotion)
        try container.encode(speed, forKey: .speed)
        try container.encode(language, forKey: .language)
        try container.encode(outputFormat, forKey: .outputFormat)
    }

    static func fromLegacyDictionary(_ dictionary: [String: Any]) -> VoiceServiceConfiguration? {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let configuration = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        return configuration
    }
}

enum VoiceTextSelectionMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case fullText
    case quotedOnly
    case outsideParentheses
    case italicOnly
    case nonItalic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullText: "完整文本"
        case .quotedOnly: "只读引号内容"
        case .outsideParentheses: "跳过括号内容"
        case .italicOnly: "只读斜体"
        case .nonItalic: "跳过斜体"
        }
    }

    var description: String {
        switch self {
        case .fullText: "朗读整条助手消息。"
        case .quotedOnly: "只朗读中文或英文引号中的文字。"
        case .outsideParentheses: "忽略圆括号和全角括号中的内容。"
        case .italicOnly: "只朗读 Markdown 或 HTML 斜体内容。"
        case .nonItalic: "朗读斜体之外的内容。"
        }
    }
}

enum VoiceTextSelection {
    static func apply(
        _ input: String,
        mode: VoiceTextSelectionMode,
        fallbackToOriginal: Bool = true
    ) -> String {
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return "" }
        let selected: String
        switch mode {
        case .fullText:
            selected = original
        case .quotedOnly:
            selected = quotedText(original)
        case .outsideParentheses:
            selected = outsideParentheses(original)
        case .italicOnly:
            selected = italicMatches(in: original).map(\.text).joined(separator: "\n")
        case .nonItalic:
            selected = removing(ranges: italicMatches(in: original).map(\.range), from: original)
        }
        let normalized = normalizedText(selected)
        return normalized.isEmpty && fallbackToOriginal ? original : normalized
    }

    private static func quotedText(_ input: String) -> String {
        let patterns = [
            "“([^”]+)”", "‘([^’]+)’", "「([^」]+)」", "『([^』]+)』",
            "\"([^\"\\n]+)\"", "'([^'\\n]+)'"
        ]
        var matches: [(range: NSRange, text: String)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(input.startIndex..., in: input)
            for match in regex.matches(in: input, range: fullRange) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: input) else { continue }
                matches.append((match.range, String(input[range])))
            }
        }
        return matches.sorted { $0.range.location < $1.range.location }
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func outsideParentheses(_ input: String) -> String {
        var result = ""
        var depth = 0
        for character in input {
            if character == "(" || character == "（" {
                if !result.hasSuffix(" ") { result.append(" ") }
                depth += 1
            } else if (character == ")" || character == "）") && depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    private static func italicMatches(in input: String) -> [(range: NSRange, text: String)] {
        let patterns = [
            "(?is)<(?:em|i)\\b[^>]*>(.*?)</(?:em|i)>",
            "(?s)(?<!\\*)\\*(?!\\*)(\\S(?:.*?\\S)?)\\*(?!\\*)",
            "(?s)(?<!_)_(?!_)(\\S(?:.*?\\S)?)_(?!_)"
        ]
        var matches: [(range: NSRange, text: String)] = []
        let fullRange = NSRange(input.startIndex..., in: input)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: input, range: fullRange) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: input) else { continue }
                matches.append((match.range, String(input[range])))
            }
        }
        matches.sort { $0.range.location < $1.range.location }
        var result: [(range: NSRange, text: String)] = []
        var lastEnd = -1
        for match in matches where match.range.location >= lastEnd {
            result.append(match)
            lastEnd = NSMaxRange(match.range)
        }
        return result
    }

    private static func removing(ranges: [NSRange], from input: String) -> String {
        let mutable = NSMutableString(string: input)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard range.location != NSNotFound, NSMaxRange(range) <= mutable.length else { continue }
            mutable.replaceCharacters(in: range, with: " ")
        }
        return mutable as String
    }

    private static func normalizedText(_ input: String) -> String {
        input.components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum VoiceTextChunker {
    static func chunks(_ input: String, limit: Int) -> [String] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let safeLimit = max(limit, 40)
        var remaining = text[...]
        var result: [String] = []
        let preferredBreaks = CharacterSet(charactersIn: "。！？!?；;\n")

        while remaining.count > safeLimit {
            let provisionalEnd = remaining.index(remaining.startIndex, offsetBy: safeLimit)
            let prefix = remaining[..<provisionalEnd]
            var breakIndex: String.Index?
            var cursor = prefix.endIndex
            while cursor > prefix.startIndex {
                cursor = prefix.index(before: cursor)
                let character = prefix[cursor]
                if String(character).rangeOfCharacter(from: preferredBreaks) != nil {
                    breakIndex = prefix.index(after: cursor)
                    break
                }
            }
            if breakIndex == nil {
                cursor = prefix.endIndex
                while cursor > prefix.startIndex {
                    cursor = prefix.index(before: cursor)
                    if prefix[cursor].isWhitespace {
                        breakIndex = cursor
                        break
                    }
                }
            }
            let end = breakIndex ?? provisionalEnd
            let chunk = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remaining = remaining[end...].drop(while: \.isWhitespace)
        }
        let final = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty { result.append(final) }
        return result
    }
}

enum VoiceSecretStore {
    private static let service = "com.uuzsama450.mocca.voice"

    static func hydrate(_ configuration: VoiceServiceConfiguration) -> VoiceServiceConfiguration {
        var result = configuration
        let stored = value(for: configuration.id.uuidString)
        if !stored.isEmpty { result.apiKey = stored }
        return result
    }

    static func hydrate(_ configurations: [VoiceServiceConfiguration]) -> [VoiceServiceConfiguration] {
        configurations.map(hydrate)
    }

    @discardableResult
    static func persist(_ configurations: [VoiceServiceConfiguration]) -> Bool {
        configurations.map(persist).allSatisfy { $0 }
    }

    @discardableResult
    static func persist(_ configuration: VoiceServiceConfiguration) -> Bool {
        set(configuration.apiKey, for: configuration.id.uuidString)
    }

    static func remove(_ configuration: VoiceServiceConfiguration) {
        remove(for: configuration.id)
    }

    static func remove(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func value(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func set(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

struct VoiceNetworkResult: Sendable {
    let data: Data
    let mimeType: String
}

enum VoiceServiceError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidURL
    case invalidResponse
    case requestFailed(provider: String, status: Int, detail: String)
    case missingAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .invalidURL: ErrorLocalization.lookup("语音服务地址无效")
        case .invalidResponse: ErrorLocalization.lookup("语音服务返回了无法识别的响应")
        case .requestFailed(let provider, let status, let detail):
            ErrorLocalization.format("%@ 请求失败（%@）%@", [String(describing: provider), String(describing: status), String(describing: detail.isEmpty ? "" : "：\(detail)")])
        case .missingAudio(let provider): ErrorLocalization.format("%@ 没有返回音频", [String(describing: provider)])
        }
    }
}

enum VoiceNetworkSynthesis {
    static func synthesize(
        configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        if let message = configuration.validationMessage {
            throw VoiceServiceError.invalidConfiguration(message)
        }
        switch configuration.kind {
        case .openAI:
            return try await openAISpeech(configuration, text: text)
        case .gemini:
            return try await geminiSpeech(configuration, text: text)
        case .miniMax:
            return try await miniMaxSpeech(configuration, text: text)
        case .qwen:
            return try await qwenSpeech(configuration, text: text)
        case .groq:
            return try await groqSpeech(configuration, text: text)
        case .xAI:
            return try await xAISpeech(configuration, text: text)
        case .elevenLabs:
            return try await elevenLabsSpeech(configuration, text: text)
        case .mimo:
            return try await mimoSpeech(configuration, text: text)
        }
    }

    private static func openAISpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(configuration.resolvedEndpoint, "audio/speech"),
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: [
                "model": configuration.resolvedModel,
                "input": text,
                "voice": configuration.resolvedVoice,
                "response_format": "mp3"
            ]
        )
        return VoiceNetworkResult(data: data, mimeType: "audio/mpeg")
    }

    private static func geminiSpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(
                configuration.resolvedEndpoint,
                "models/\(configuration.resolvedModel):generateContent"
            ),
            headers: ["x-goog-api-key": configuration.apiKey],
            body: [
                "contents": [[
                    "role": "user",
                    "parts": [["text": text]]
                ]],
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": configuration.resolvedVoice]
                        ]
                    ]
                ],
                "model": configuration.resolvedModel
            ]
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let inline = parts.first?["inlineData"] as? [String: Any],
              let base64 = inline["data"] as? String,
              let pcm = Data(base64Encoded: base64),
              !pcm.isEmpty else {
            throw VoiceServiceError.missingAudio(configuration.kind.title)
        }
        return VoiceNetworkResult(data: pcmToWAV(pcm, sampleRate: 24_000), mimeType: "audio/wav")
    }

    private static func miniMaxSpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(configuration.resolvedEndpoint, "t2a_v2"),
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Accept": "text/event-stream"
            ],
            body: [
                "model": configuration.resolvedModel,
                "text": text,
                "stream": true,
                "output_format": "hex",
                "stream_options": ["exclude_aggregated_audio": true],
                "voice_setting": [
                    "voice_id": configuration.resolvedVoice,
                    "emotion": configuration.emotion,
                    "speed": configuration.speed
                ]
            ]
        )
        var audio = Data()
        for payload in ssePayloads(data) where payload != "[DONE]" {
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let body = object["data"] as? [String: Any],
                  let hex = body["audio"] as? String else { continue }
            audio.append(hexData(hex))
        }
        guard !audio.isEmpty else { throw VoiceServiceError.missingAudio(configuration.kind.title) }
        return VoiceNetworkResult(data: audio, mimeType: "audio/mpeg")
    }

    private static func qwenSpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(
                configuration.resolvedEndpoint,
                "services/aigc/multimodal-generation/generation"
            ),
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "X-DashScope-SSE": "enable"
            ],
            body: [
                "model": configuration.resolvedModel,
                "input": [
                    "text": text,
                    "voice": configuration.resolvedVoice,
                    "language_type": configuration.language.isEmpty ? "Auto" : configuration.language
                ]
            ]
        )
        var pcm = Data()
        for payload in ssePayloads(data) where payload != "[DONE]" {
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let output = object["output"] as? [String: Any],
                  let audio = output["audio"] as? [String: Any],
                  let base64 = audio["data"] as? String,
                  let chunk = Data(base64Encoded: base64) else { continue }
            pcm.append(chunk)
        }
        guard !pcm.isEmpty else { throw VoiceServiceError.missingAudio(configuration.kind.title) }
        return VoiceNetworkResult(data: pcmToWAV(pcm, sampleRate: 24_000), mimeType: "audio/wav")
    }

    private static func groqSpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(configuration.resolvedEndpoint, "audio/speech"),
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: [
                "model": configuration.resolvedModel,
                "input": text,
                "voice": configuration.resolvedVoice,
                "response_format": "wav"
            ]
        )
        return VoiceNetworkResult(data: data, mimeType: "audio/wav")
    }

    private static func xAISpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(configuration.resolvedEndpoint, "tts"),
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: [
                "text": text,
                "voice_id": configuration.resolvedVoice,
                "language": configuration.language.isEmpty ? "auto" : configuration.language
            ]
        )
        return VoiceNetworkResult(data: data, mimeType: "audio/mpeg")
    }

    private static func elevenLabsSpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        var base = configuration.resolvedEndpoint
        while base.hasSuffix("/") { base.removeLast() }
        if !base.lowercased().hasSuffix("/v1") { base += "/v1" }
        let voice = configuration.resolvedVoice.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? configuration.resolvedVoice
        let format = configuration.outputFormat.isEmpty
            ? "mp3_44100_128"
            : configuration.outputFormat
        let escapedFormat = format.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? format
        guard let url = URL(string: "\(base)/text-to-speech/\(voice)?output_format=\(escapedFormat)") else {
            throw VoiceServiceError.invalidURL
        }
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: url,
            headers: ["xi-api-key": configuration.apiKey],
            body: ["text": text, "model_id": configuration.resolvedModel]
        )
        if format.lowercased().hasPrefix("pcm_") {
            let rate = Int(format.split(separator: "_").dropFirst().first ?? "") ?? 24_000
            return VoiceNetworkResult(data: pcmToWAV(data, sampleRate: rate), mimeType: "audio/wav")
        }
        if format.lowercased().hasPrefix("opus_") {
            return VoiceNetworkResult(data: data, mimeType: "audio/ogg")
        }
        return VoiceNetworkResult(data: data, mimeType: "audio/mpeg")
    }

    private static func mimoSpeech(
        _ configuration: VoiceServiceConfiguration,
        text: String
    ) async throws -> VoiceNetworkResult {
        let data = try await performJSONRequest(
            provider: configuration.kind.title,
            url: joinedURL(configuration.resolvedEndpoint, "chat/completions"),
            headers: ["api-key": configuration.apiKey],
            body: [
                "model": configuration.resolvedModel,
                "messages": [["role": "assistant", "content": text]],
                "audio": ["format": "pcm16", "voice": configuration.resolvedVoice],
                "stream": true
            ]
        )
        var pcm = Data()
        for payload in ssePayloads(data) where payload != "[DONE]" {
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let audio = delta["audio"] as? [String: Any],
                  let base64 = audio["data"] as? String,
                  let chunk = Data(base64Encoded: base64) else { continue }
            pcm.append(chunk)
        }
        guard !pcm.isEmpty else { throw VoiceServiceError.missingAudio(configuration.kind.title) }
        return VoiceNetworkResult(data: pcmToWAV(pcm, sampleRate: 24_000), mimeType: "audio/wav")
    }

    private static func performJSONRequest(
        provider: String,
        url: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> Data {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw VoiceServiceError.invalidConfiguration("请求参数无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await makeSession().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(800), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw VoiceServiceError.requestFailed(
                provider: provider,
                status: http.statusCode,
                detail: detail
            )
        }
        return data
    }

    private static func joinedURL(_ base: String, _ path: String) throws -> URL {
        var value = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: "\(value)/\(suffix)") else {
            throw VoiceServiceError.invalidURL
        }
        return url
    }

    private static func makeSession() -> URLSession {
        let proxy = AppPreferences.loadProxySettings()
        guard proxy.isUsable, let port = Int(proxy.port) else { return .shared }
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true,
            "HTTPProxy": proxy.host.trimmingCharacters(in: .whitespacesAndNewlines),
            "HTTPPort": port,
            "HTTPSEnable": true,
            "HTTPSProxy": proxy.host.trimmingCharacters(in: .whitespacesAndNewlines),
            "HTTPSPort": port
        ]
        return URLSession(configuration: configuration)
    }

    private static func ssePayloads(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var payloads: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.isEmpty {
                if !current.isEmpty {
                    payloads.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
            } else if line.hasPrefix("data:") {
                current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { payloads.append(current.joined(separator: "\n")) }
        return payloads
    }

    private static func hexData(_ value: String) -> Data {
        let clean = value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard clean.count.isMultiple(of: 2) else { return Data() }
        var result = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return Data() }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func pcmToWAV(
        _ pcm: Data,
        sampleRate: Int,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        var result = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        func appendASCII(_ value: String) {
            result.append(contentsOf: value.utf8)
        }
        func appendUInt32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendUInt32(36 + pcm.count)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(channels)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(pcm.count)
        result.append(pcm)
        return result
    }
}

extension Notification.Name {
    static let deviceTTSPlaybackDidChange = Notification.Name("DeviceTTSPlaybackDidChange")
}

@MainActor
final class VoicePlaybackController: NSObject, ObservableObject,
    @preconcurrency AVSpeechSynthesizerDelegate,
    @preconcurrency AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed
    }

    static let shared = VoicePlaybackController()

    @Published private(set) var state: State = .idle
    @Published private(set) var activeMessageID: UUID?
    @Published private(set) var serviceTitle = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var progress: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var speechQueue: [String] = []
    private var audioQueue: [Data] = []
    private var audioQueueIndex = 0
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var networkTask: Task<Void, Never>?
    private var sessionToken = UUID()
    private var originalPreferences = UserPreferences()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var isActive: Bool {
        state == .loading || state == .playing || state == .paused
    }

    var isPaused: Bool { state == .paused }
    var canSeek: Bool { audioPlayer != nil && duration > 0 }

    func play(
        text: String,
        messageID: UUID?,
        preferences: UserPreferences
    ) {
        let selectedText = VoiceTextSelection.apply(
            text,
            mode: preferences.ttsTextSelectionMode
        )
        guard !selectedText.isEmpty else { return }
        stop()
        configureAudioSession()
        let token = UUID()
        sessionToken = token
        activeMessageID = messageID
        originalPreferences = preferences
        errorMessage = nil

        if let selectedID = preferences.selectedVoiceServiceID,
           let service = preferences.voiceServices.first(where: {
               $0.id == selectedID && $0.enabled
           }) {
            startNetwork(
                text: selectedText,
                service: service,
                token: token
            )
        } else {
            startSystem(
                text: selectedText,
                preferences: preferences,
                token: token
            )
        }
    }

    func toggle(
        text: String,
        messageID: UUID,
        preferences: UserPreferences
    ) {
        if isActive {
            stop()
        } else {
            play(text: text, messageID: messageID, preferences: preferences)
        }
    }

    func pauseOrResume() {
        switch state {
        case .playing:
            if let audioPlayer {
                audioPlayer.pause()
            } else {
                synthesizer.pauseSpeaking(at: .word)
            }
            state = .paused
            publishChange()
        case .paused:
            if let audioPlayer {
                audioPlayer.play()
            } else {
                synthesizer.continueSpeaking()
            }
            state = .playing
            publishChange()
        default:
            break
        }
    }

    func seek(by seconds: TimeInterval) {
        guard let audioPlayer else { return }
        let target = min(max(audioPlayer.currentTime + seconds, 0), audioPlayer.duration)
        audioPlayer.currentTime = target
        progress = target
    }

    func seek(to seconds: TimeInterval) {
        guard let audioPlayer else { return }
        let target = min(max(seconds, 0), audioPlayer.duration)
        audioPlayer.currentTime = target
        progress = target
    }

    func cyclePlaybackRate() {
        let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]
        let currentIndex = rates.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) ?? 1
        playbackRate = rates[(currentIndex + 1) % rates.count]
        audioPlayer?.rate = playbackRate
    }

    func stop() {
        sessionToken = UUID()
        networkTask?.cancel()
        networkTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
        activeUtterance = nil
        speechQueue.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        audioQueue.removeAll()
        audioQueueIndex = 0
        progress = 0
        duration = 0
        activeMessageID = nil
        serviceTitle = ""
        errorMessage = nil
        state = .idle
        publishChange()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finishSystemUtterance(utterance)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioQueueIndex += 1
        if audioQueue.indices.contains(audioQueueIndex) {
            beginAudio(data: audioQueue[audioQueueIndex])
        } else {
            completePlayback()
        }
    }

    private func startSystem(
        text: String,
        preferences: UserPreferences,
        token: UUID
    ) {
        serviceTitle = L10n.lookup("系统语音")
        speechQueue = VoiceTextChunker.chunks(text, limit: 360)
        guard !speechQueue.isEmpty else { return }
        state = .playing
        publishChange()
        speakNextSystemChunk(preferences: preferences, token: token)
    }

    private func speakNextSystemChunk(
        preferences: UserPreferences,
        token: UUID
    ) {
        guard token == sessionToken else { return }
        guard !speechQueue.isEmpty else {
            completePlayback()
            return
        }
        let chunk = speechQueue.removeFirst()
        let utterance = AVSpeechUtterance(string: chunk)
        if let identifier = preferences.ttsVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else if let language = preferences.ttsLanguage, !language.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = Float(min(max(preferences.ttsSpeechRate, 0.1), 1.0))
        utterance.pitchMultiplier = Float(min(max(preferences.ttsPitch, 0.5), 2.0))
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func finishSystemUtterance(_ utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
        guard !speechQueue.isEmpty else {
            completePlayback()
            return
        }
        speakNextSystemChunk(
            preferences: originalPreferences,
            token: sessionToken
        )
    }

    private func startNetwork(
        text: String,
        service: VoiceServiceConfiguration,
        token: UUID
    ) {
        serviceTitle = service.resolvedName
        state = .loading
        publishChange()
        let chunks = VoiceTextChunker.chunks(text, limit: 220)
        networkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await Self.synthesize(
                    chunks: chunks,
                    service: service,
                    prefetchLimit: 3
                )
                try Task.checkCancellation()
                guard token == self.sessionToken else { return }
                self.audioQueue = results.map(\.data)
                self.audioQueueIndex = 0
                guard let first = self.audioQueue.first else {
                    throw VoiceServiceError.missingAudio(service.kind.title)
                }
                self.beginAudio(data: first)
            } catch is CancellationError {
                return
            } catch {
                guard token == self.sessionToken else { return }
                self.fail(error)
            }
        }
    }

    private static func synthesize(
        chunks: [String],
        service: VoiceServiceConfiguration,
        prefetchLimit: Int
    ) async throws -> [VoiceNetworkResult] {
        guard !chunks.isEmpty else { return [] }
        return try await withThrowingTaskGroup(
            of: (Int, VoiceNetworkResult).self
        ) { group in
            var results = Array<VoiceNetworkResult?>(repeating: nil, count: chunks.count)
            var nextIndex = 0
            let initialCount = min(max(prefetchLimit, 1), chunks.count)
            for _ in 0..<initialCount {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    (
                        index,
                        try await VoiceNetworkSynthesis.synthesize(
                            configuration: service,
                            text: chunks[index]
                        )
                    )
                }
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if nextIndex < chunks.count {
                    let pendingIndex = nextIndex
                    nextIndex += 1
                    group.addTask {
                        (
                            pendingIndex,
                            try await VoiceNetworkSynthesis.synthesize(
                                configuration: service,
                                text: chunks[pendingIndex]
                            )
                        )
                    }
                }
            }
            return results.compactMap { $0 }
        }
    }

    private func beginAudio(data: Data) {
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            audioPlayer = player
            progress = 0
            duration = player.duration
            state = .playing
            player.play()
            startProgressTimer()
            publishChange()
        } catch {
            fail(error)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.audioPlayer else { return }
                self.progress = player.currentTime
                self.duration = player.duration
            }
        }
    }

    private func completePlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        activeUtterance = nil
        audioPlayer = nil
        audioQueue.removeAll()
        speechQueue.removeAll()
        activeMessageID = nil
        progress = 0
        duration = 0
        state = .idle
        publishChange()
    }

    private func fail(_ error: Error) {
        progressTimer?.invalidate()
        progressTimer = nil
        audioPlayer = nil
        audioQueue.removeAll()
        speechQueue.removeAll()
        activeUtterance = nil
        activeMessageID = nil
        progress = 0
        duration = 0
        errorMessage = error.localizedDescription
        state = .failed
        publishChange()
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func publishChange() {
        NotificationCenter.default.post(name: .deviceTTSPlaybackDidChange, object: nil)
    }
}

@MainActor
enum DeviceTTSService {
    static func speak(text: String) {
        VoicePlaybackController.shared.play(
            text: text,
            messageID: nil,
            preferences: AppPreferences.loadPreferences()
        )
    }

    static func speak(
        text: String,
        messageID: UUID?,
        preferences: UserPreferences
    ) {
        VoicePlaybackController.shared.play(
            text: text,
            messageID: messageID,
            preferences: preferences
        )
    }

    static func toggle(text: String, messageID: UUID) {
        VoicePlaybackController.shared.toggle(
            text: text,
            messageID: messageID,
            preferences: AppPreferences.loadPreferences()
        )
    }

    static func isSpeaking(messageID: UUID) -> Bool {
        VoicePlaybackController.shared.isActive
            && VoicePlaybackController.shared.activeMessageID == messageID
    }

    static func stop() {
        VoicePlaybackController.shared.stop()
    }
}
