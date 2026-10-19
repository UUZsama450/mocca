import Foundation

enum ProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case google
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .google: "Google"
        case .claude: "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .openAI: "sparkles"
        case .google: "diamond"
        case .claude: "sun.max"
        }
    }

    var brandIcon: ProviderBrandIcon {
        switch self {
        case .openAI: .openAI
        case .google: .gemini
        case .claude: .claude
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta"
        case .claude: "https://api.anthropic.com/v1"
        }
    }
}

enum ProviderImageGenerationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case disabled
    case openAICompatible
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动识别"
        case .disabled: "关闭"
        case .openAICompatible: "OpenAI 兼容"
        case .openRouter: "OpenRouter"
        }
    }
}

enum ProviderBrandIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case gemini
    case claude
    case deepSeek = "deepseek"
    case grok
    case openRouter = "openrouter"
    case zhipu
    case alibabaCloud = "aliyun"
    case byteDance = "bytedance"
    case siliconFlow = "siliconflow"
    case aiHubMix = "aihubmix"
    case mocca = "moccain"
    case tensdaq

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "kelivoin" {
            self = .mocca
        } else if let decoded = Self(rawValue: value) {
            self = decoded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown provider brand icon: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    /// Keep `.mocca` decodable for old backups, but do not present the retired
    /// Kelivo-era provider artwork as a selectable or inferred provider brand.
    static var selectableCases: [ProviderBrandIcon] {
        allCases.filter { $0 != .mocca }
    }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .claude: "Claude"
        case .deepSeek: "DeepSeek"
        case .grok: "Grok"
        case .openRouter: "OpenRouter"
        case .zhipu: "智谱 AI"
        case .alibabaCloud: "阿里云"
        case .byteDance: "字节跳动"
        case .siliconFlow: "SiliconFlow"
        case .aiHubMix: "AIhubmix"
        case .mocca: "Mocca"
        case .tensdaq: "Tensdaq"
        }
    }

    var assetName: String {
        switch self {
        case .openAI: "ProviderOpenAI"
        case .gemini: "ProviderGemini"
        case .claude: "ProviderClaude"
        case .deepSeek: "ProviderDeepSeek"
        case .grok: "ProviderGrok"
        case .openRouter: "ProviderOpenRouter"
        case .zhipu: "ProviderZhipu"
        case .alibabaCloud: "ProviderAlibabaCloud"
        case .byteDance: "ProviderByteDance"
        case .siliconFlow: "ProviderSiliconFlow"
        case .aiHubMix: "ProviderAIHubMix"
        case .mocca: "ProviderMocca"
        case .tensdaq: "ProviderTensdaq"
        }
    }

    var usesTemplateRendering: Bool {
        switch self {
        case .openAI, .grok, .openRouter: true
        default: false
        }
    }

    static func inferred(name: String, baseURL: String) -> ProviderBrandIcon? {
        let normalizedName = normalize(name)
        if let named = selectableCases.first(where: { $0.matchesName(normalizedName) }) {
            return named
        }

        let normalizedURL = normalize(baseURL)
        return selectableCases.first(where: { $0.matchesURL(normalizedURL) })
    }

    /// Model identity is independent of the provider's API format or branding.
    /// Match the model component first so a gateway namespace cannot win.
    static func inferredModel(id: String, catalogName: String?) -> ProviderBrandIcon? {
        func match(_ value: String) -> ProviderBrandIcon? {
            let normalized = normalize(value)
            let range = NSRange(normalized.startIndex..., in: normalized)
            return modelBrandRules.first {
                $0.pattern.firstMatch(in: normalized, range: range) != nil
            }?.icon
        }

        let modelID = id.split(separator: "/").last.map(String.init) ?? id
        if let icon = match(modelID) { return icon }
        return catalogName.flatMap(match)
    }

    private static let modelBrandRules: [(icon: ProviderBrandIcon, pattern: NSRegularExpression)] = [
        (.openAI, #"(^|[^a-z0-9])(gpt($|[-_ .]?([0-9]|oss\b))|chatgpt\b|o[1-9][0-9]*($|[^a-z0-9]))"#),
        (.claude, #"(^|[^a-z0-9])claude($|[^a-z])"#),
        (.gemini, #"(^|[^a-z0-9])gemini($|[^a-z])"#),
        (.deepSeek, #"(^|[^a-z0-9])deepseek($|[^a-z])"#),
        (.grok, #"(^|[^a-z0-9])grok($|[^a-z])"#),
        (.zhipu, #"(^|[^a-z0-9])(glm|zhipu)($|[^a-z])|智谱"#)
    ].compactMap { icon, pattern in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (icon, expression)
    }

    static func fromLegacyAvatar(type: String?, value: String?) -> ProviderBrandIcon? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        switch type?.lowercased() {
        case "icon":
            let fileName = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
            return inferred(name: fileName, baseURL: "")
        case "lobehub":
            return inferred(name: value, baseURL: "")
        default:
            return nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesName(_ value: String) -> Bool {
        nameTokens.contains { value.contains($0) }
    }

    private func matchesURL(_ value: String) -> Bool {
        urlTokens.contains { value.contains($0) }
    }

    private var nameTokens: [String] {
        switch self {
        case .openAI: ["openai", "chatgpt", "gpt"]
        case .gemini: ["gemini", "google"]
        case .claude: ["claude", "anthropic"]
        case .deepSeek: ["deepseek"]
        case .grok: ["grok", "x.ai", "xai"]
        case .openRouter: ["openrouter"]
        case .zhipu: ["zhipu", "智谱", "glm"]
        case .alibabaCloud: ["aliyun", "alibaba", "阿里云", "百炼"]
        case .byteDance: ["bytedance", "字节", "火山", "volcengine"]
        case .siliconFlow: ["siliconflow", "silicon flow", "硅基"]
        case .aiHubMix: ["aihubmix"]
        case .mocca: ["mocca", "kelivo"]
        case .tensdaq: ["tensdaq"]
        }
    }

    private var urlTokens: [String] {
        switch self {
        case .openAI: ["api.openai.com"]
        case .gemini: ["generativelanguage.googleapis.com"]
        case .claude: ["api.anthropic.com"]
        case .deepSeek: ["api.deepseek.com"]
        case .grok: ["api.x.ai"]
        case .openRouter: ["openrouter.ai"]
        case .zhipu: ["bigmodel.cn"]
        case .alibabaCloud: ["dashscope.aliyuncs.com"]
        case .byteDance: ["volces.com"]
        case .siliconFlow: ["siliconflow.cn"]
        case .aiHubMix: ["aihubmix.com"]
        case .mocca: ["pollinations.ai"]
        case .tensdaq: ["tensdaq-api"]
        }
    }
}

struct ProviderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let configurationID: UUID
    let title: String
    let aliases: [String]
    let type: ProviderType
    let enabled: Bool
    let baseURL: String
    let apiKey: String
    let chatPath: String
    let models: [ModelConfiguration]
    let systemImage: String

    var configuration: ProviderConfiguration {
        ProviderConfiguration(
            id: configurationID,
            enabled: enabled,
            name: title,
            type: type,
            apiKey: apiKey,
            baseURL: baseURL,
            chatPath: chatPath,
            models: models,
            brandIcon: ProviderBrandIcon(rawValue: id)
        )
    }

    func matches(_ provider: ProviderConfiguration) -> Bool {
        let normalizedName = Self.normalize(provider.name)
        let names = ([title] + aliases).map(Self.normalize)
        return names.contains(normalizedName)
            || Self.normalizeURL(provider.baseURL) == Self.normalizeURL(baseURL)
    }

    static func matching(_ provider: ProviderConfiguration) -> ProviderPreset? {
        all.first { $0.matches(provider) }
    }

    static func mergingMissing(into existing: [ProviderConfiguration]) -> [ProviderConfiguration] {
        var usedIndices = Set<Int>()
        var result: [ProviderConfiguration] = []

        for preset in all {
            if let match = existing.indices.first(where: { index in
                !usedIndices.contains(index) && preset.matches(existing[index])
            }) {
                usedIndices.insert(match)
                result.append(existing[match])
            } else {
                result.append(preset.configuration)
            }
        }

        result.append(contentsOf: existing.indices.compactMap { index in
            usedIndices.contains(index) ? nil : existing[index]
        })
        return result
    }

    static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "openai",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            title: "OpenAI",
            aliases: [],
            type: .openAI,
            enabled: true,
            baseURL: "https://api.openai.com/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "sparkles"
        ),
        ProviderPreset(
            id: "siliconflow",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            title: "硅基流动",
            aliases: ["SiliconFlow"],
            type: .openAI,
            enabled: true,
            baseURL: "https://api.siliconflow.cn/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "cloud"
        ),
        ProviderPreset(
            id: "gemini",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            title: "Gemini",
            aliases: ["Google"],
            type: .google,
            enabled: true,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "diamond"
        ),
        ProviderPreset(
            id: "openrouter",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
            title: "OpenRouter",
            aliases: [],
            type: .openAI,
            enabled: true,
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "arrow.triangle.branch"
        ),
        ProviderPreset(
            id: "tensdaq",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
            title: "Tensdaq",
            aliases: [],
            type: .openAI,
            enabled: true,
            baseURL: "https://tensdaq-api.x-aio.com/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "chart.line.uptrend.xyaxis"
        ),
        ProviderPreset(
            id: "deepseek",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!,
            title: "DeepSeek",
            aliases: [],
            type: .openAI,
            enabled: false,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "scope"
        ),
        ProviderPreset(
            id: "aihubmix",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000008")!,
            title: "AIhubmix",
            aliases: [],
            type: .openAI,
            enabled: false,
            baseURL: "https://aihubmix.com/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "square.stack.3d.up"
        ),
        ProviderPreset(
            id: "aliyun",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!,
            title: "阿里云",
            aliases: ["Aliyun", "Alibaba Cloud"],
            type: .openAI,
            enabled: false,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "cloud.sun"
        ),
        ProviderPreset(
            id: "zhipu",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
            title: "智谱 AI",
            aliases: ["Zhipu AI", "Zhipu"],
            type: .openAI,
            enabled: false,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "brain.head.profile"
        ),
        ProviderPreset(
            id: "claude",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!,
            title: "Claude",
            aliases: ["Anthropic"],
            type: .claude,
            enabled: false,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "sun.max"
        ),
        ProviderPreset(
            id: "grok",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
            title: "Grok",
            aliases: ["xAI", "x.ai"],
            type: .openAI,
            enabled: false,
            baseURL: "https://api.x.ai/v1",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "bolt.horizontal.circle"
        ),
        ProviderPreset(
            id: "bytedance",
            configurationID: UUID(uuidString: "00000000-0000-4000-8000-000000000013")!,
            title: "字节跳动",
            aliases: ["ByteDance", "火山方舟", "Volcengine"],
            type: .openAI,
            enabled: false,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            apiKey: "",
            chatPath: "/chat/completions",
            models: [],
            systemImage: "music.note"
        )
    ]

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeURL(_ value: String) -> String {
        normalize(value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum ModelKind: String, Codable, Hashable, Sendable {
    case chat
    case embedding

    var title: String {
        switch self {
        case .chat: "聊天"
        case .embedding: "嵌入"
        }
    }
}

enum ModelModality: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case text
    case image

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .image: "photo"
        }
    }

    static func < (lhs: ModelModality, rhs: ModelModality) -> Bool {
        lhs == .text && rhs == .image
    }
}

enum ModelAbility: String, Codable, Hashable, Sendable, CaseIterable {
    case tool
    case reasoning

    var systemImage: String {
        switch self {
        case .tool: "hammer"
        case .reasoning: "brain.head.profile"
        }
    }

    var title: String {
        switch self {
        case .tool: "工具调用"
        case .reasoning: "推理"
        }
    }
}

struct ModelCapabilities: Codable, Hashable, Sendable {
    var kind: ModelKind
    var input: [ModelModality]
    var output: [ModelModality]
    var abilities: [ModelAbility]

    init(
        kind: ModelKind = .chat,
        input: [ModelModality] = [.text],
        output: [ModelModality] = [.text],
        abilities: [ModelAbility] = []
    ) {
        self.kind = kind
        self.input = input
        self.output = output
        self.abilities = abilities
    }
}

/// 按模型 ID 推断能力，移植自旧 Kelivo 的 ModelRegistry（model_provider.dart）。
enum ModelCapabilityRegistry {
    private static let vision = regex(
        #"(gpt-4o|gpt-4\.1|gpt-5(?!-chat)|o\d|gemini|claude|qwen-?3([-.])5|kimi-k2([-.])(?:5|6|7)|doubao.+1([-.])(?:6|8)|grok-4|step-3|intern-s1|minimax-m3(?:$|[/_:@])|mimo-v2(?:-omni(?:$|[/_:@])|\.5(?:$|[/_:@]))|sensenova-6\.7-flash-lite)"#
    )
    private static let tool = regex(
        #"(gpt-4o|gpt-4\.1|gpt-oss|gpt-5(?!-chat)|o\d|gemini|claude|qwen-?3|doubao.+1([-.])(?:6|8)|grok-4|kimi-k2|step-3|intern-s1|glm-4([-.])(?:5|6|7)|glm-5|minimax-(?:m2|m3)|deepseek-(?:r1|v3|chat|v3\.1|v3\.2|v4)|deepseek-reasoner|mimo-v2|sensenova-6\.7-flash-lite)"#
    )
    private static let reasoning = regex(
        #"(gpt-oss|gpt-5(?!-chat)|o\d|gemini-(?:2\.5|3).*|gemini-(?:flash-latest|pro-latest)|gemini-3-pro-image-preview|gemma[-_]?4|claude|qwen-?3|doubao.+1([-.])(?:6|8)|grok-4|kimi-k2|step-3|intern-s1|glm-4([-.])(?:5|6|7)|glm-5|minimax-(?:m2|m3)|deepseek-(?:r1|v3\.1|v3\.2|v4)|deepseek-reasoner|mimo-v2)"#
    )
    private static let embedding = regex(#"(^|[-_/])embed(?:dings?)?([-.]|$)"#)
    private static let gemini35Flash = regex(#"(^|[/:_-])gemini-3\.5-flash([._:@/-]|$)"#)
    private static let deepSeekFlash = regex(#"(^|[/_:])deepseek-flash(?:$|[-_:@/])"#)

    static func isLikelyEmbeddingID(_ rawID: String) -> Bool {
        let id = rawID.lowercased()
        return id.contains("embedding") || matches(embedding, id)
    }

    static func infer(id rawID: String, base: ModelCapabilities? = nil) -> ModelCapabilities {
        let id = rawID.lowercased()
        var result = base ?? ModelCapabilities()

        if result.kind == .embedding || isLikelyEmbeddingID(id) {
            result.kind = .embedding
            if !result.input.contains(.text) { result.input.append(.text) }
            result.output = [.text]
            result.abilities = []
            return normalized(result)
        }

        if id.contains("image") {
            if !result.input.contains(.image) { result.input.append(.image) }
            if !result.output.contains(.image) { result.output.append(.image) }
            result.abilities.removeAll { $0 == .tool || $0 == .reasoning }
            return normalized(result)
        }

        if matches(gemini35Flash, id) {
            if !result.input.contains(.image) { result.input.append(.image) }
            result.output = [.text]
            if !result.abilities.contains(.tool) { result.abilities.append(.tool) }
            if !result.abilities.contains(.reasoning) { result.abilities.append(.reasoning) }
            return normalized(result)
        }

        if matches(vision, id) && !result.input.contains(.image) {
            result.input.append(.image)
        }
        if (matches(tool, id) || matches(deepSeekFlash, id)) && !result.abilities.contains(.tool) {
            result.abilities.append(.tool)
        }
        if (matches(reasoning, id) || matches(deepSeekFlash, id)) && !result.abilities.contains(.reasoning) {
            result.abilities.append(.reasoning)
        }
        return normalized(result)
    }

    private static func normalized(_ capabilities: ModelCapabilities) -> ModelCapabilities {
        var result = capabilities
        result.input = Array(Set(result.input)).sorted()
        result.output = Array(Set(result.output)).sorted()
        result.abilities = ModelAbility.allCases.filter { result.abilities.contains($0) }
        return result
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression?, _ value: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }
}

struct ModelConfiguration: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    /// Preserve a user-entered name verbatim in compact model controls.
    var isDisplayNameCustomized: Bool
    /// 手动覆盖的能力；nil 表示完全按 ID 推断。
    var capabilityOverride: ModelCapabilities?
    /// 仅覆盖该模型请求的 Header；同名项优先于服务商设置。
    var customHeaders: [KeyValueField]
    /// 仅覆盖该模型请求 body 的字段；value 可填写 JSON 片段。
    var customBody: [KeyValueField]
    /// OpenAI Responses API 官方内置工具。
    var builtInTools: [ModelBuiltInTool]

    init(
        id: String,
        displayName: String? = nil,
        isDisplayNameCustomized: Bool = false,
        capabilityOverride: ModelCapabilities? = nil,
        customHeaders: [KeyValueField] = [],
        customBody: [KeyValueField] = [],
        builtInTools: [ModelBuiltInTool] = []
    ) {
        self.id = id
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? id
        self.isDisplayNameCustomized = isDisplayNameCustomized
        self.capabilityOverride = capabilityOverride
        self.customHeaders = customHeaders
        self.customBody = customBody
        self.builtInTools = builtInTools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        isDisplayNameCustomized = try container.decodeIfPresent(Bool.self, forKey: .isDisplayNameCustomized) ?? false
        capabilityOverride = try container.decodeIfPresent(ModelCapabilities.self, forKey: .capabilityOverride)
        customHeaders = try container.decodeIfPresent([KeyValueField].self, forKey: .customHeaders) ?? []
        customBody = try container.decodeIfPresent([KeyValueField].self, forKey: .customBody) ?? []
        builtInTools = try container.decodeIfPresent([ModelBuiltInTool].self, forKey: .builtInTools) ?? []
    }

    var capabilities: ModelCapabilities {
        // Catalog metadata is already inferred on import. An explicit override
        // must also be able to remove an inferred ability in the model editor.
        capabilityOverride ?? ModelCapabilityRegistry.infer(id: id)
    }

    var supportsTools: Bool {
        capabilities.kind == .chat && capabilities.abilities.contains(.tool)
    }

    func mergingCatalogMetadata(from fetched: ModelConfiguration) -> ModelConfiguration {
        guard fetched.id == id else { return self }
        var result = self
        if displayName == id, fetched.displayName != fetched.id {
            result.displayName = fetched.displayName
        }
        // An automatic/manual entry can acquire newly advertised capabilities;
        // never overwrite an existing explicit on/off configuration.
        if capabilityOverride == nil { result.capabilityOverride = fetched.capabilityOverride }
        return result
    }

    var composerDisplayName: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return id }
        // A colon in an API ID (for example :free) is not a vendor prefix.
        guard !isDisplayNameCustomized, name != id,
              let separator = name.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return name
        }
        let suffix = name[name.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? name : suffix
    }

    var modelBrandIcon: ProviderBrandIcon? {
        ProviderBrandIcon.inferredModel(
            id: id,
            catalogName: isDisplayNameCustomized ? nil : displayName
        )
    }
}

/// 模型目录中的视觉分组。已知规则与旧 Kelivo 保持一致；未知家族再从
/// 模型 ID 动态提取稳定的家族名，让供应商日后新增模型时无需等待发版。
enum ProviderModelGrouping {
    static func group(for model: ModelConfiguration) -> String {
        let id = model.id.lowercased()

        if model.capabilities.kind == .embedding
            || ModelCapabilityRegistry.isLikelyEmbeddingID(id) {
            return "嵌入模型"
        }
        if id.contains("gpt")
            || id.range(of: #"(^|[^a-z])o[134]"#, options: .regularExpression) != nil {
            return "GPT"
        }
        if id.contains("gemini-3") { return "Gemini 3" }
        if id.contains("gemini-2.5") { return "Gemini 2.5" }
        if id.contains("gemini") { return "Gemini" }
        if id.contains("claude-4") { return "Claude 4" }
        if id.contains("claude-sonnet") { return "Claude Sonnet" }
        if id.contains("claude-opus") { return "Claude Opus" }
        if id.contains("claude-haiku") { return "Claude Haiku" }
        if id.contains("claude-3.5") { return "Claude 3.5" }
        if id.contains("claude-3") { return "Claude 3" }
        if id.contains("deepseek") { return "DeepSeek" }
        if id.contains("kimi") { return "Kimi" }
        if containsAny(id, ["qwen", "qwq", "qvq", "dashscope"]) { return "Qwen" }
        if containsAny(id, ["doubao", "ark", "volc"]) { return "Doubao" }
        if containsAny(id, ["glm", "zhipu"]) { return "GLM" }
        if id.contains("mistral") { return "Mistral" }
        if id.contains("minimax") { return "MiniMax" }
        if containsAny(id, ["grok", "xai"]) { return "Grok" }
        if id.contains("kat") { return "KAT" }

        return dynamicGroup(for: id)
    }

    private static func dynamicGroup(for id: String) -> String {
        let recognizableFamilies: [(tokens: [String], title: String)] = [
            (["stable-diffusion", "stable_diffusion"], "Stable Diffusion"),
            (["llama"], "Llama"),
            (["gemma"], "Gemma"),
            (["command-r", "command_"], "Command"),
            (["jamba"], "Jamba"),
            (["phi-"], "Phi"),
            (["nova-"], "Nova"),
            (["flux"], "FLUX"),
            (["bge-"], "BGE"),
            (["rerank"], "Rerank"),
            (["cohere"], "Cohere"),
            (["internlm"], "InternLM"),
            (["step-"], "Step"),
            (["yi-"], "Yi"),
            (["mimo"], "MiMo"),
            (["sensenova"], "SenseNova")
        ]
        if let family = recognizableFamilies.first(where: {
            containsAny(id, $0.tokens)
        }) {
            return family.title
        }

        let lastPathComponent = id
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "~")) ?? ""
        let ignoredTokens: Set<String> = [
            "api", "chat", "image", "latest", "model", "models",
            "preview", "text", "vision"
        ]
        let token = lastPathComponent
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .first {
                $0.rangeOfCharacter(from: .letters) != nil
                    && $0.count > 1
                    && !ignoredTokens.contains($0)
            }

        guard let token else { return "其他模型" }
        if token.count <= 4 {
            return token.uppercased()
        }
        return token.prefix(1).uppercased() + String(token.dropFirst())
    }

    private static func containsAny(_ value: String, _ tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }
}

enum ModelBuiltInTool: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case codeInterpreter = "code_interpreter"
    case imageGeneration = "image_generation"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codeInterpreter: "代码解释器"
        case .imageGeneration: "图像生成"
        }
    }

    var subtitle: String {
        switch self {
        case .codeInterpreter: "自动容器 · 4 GB 内存"
        case .imageGeneration: "在回复中生成并保存图片"
        }
    }

    var systemImage: String {
        switch self {
        case .codeInterpreter: "chevron.left.forwardslash.chevron.right"
        case .imageGeneration: "photo.badge.plus"
        }
    }
}

struct KeyValueField: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

enum ProviderPromptCacheTTL: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case fiveMinutes = "5m"
    case oneHour = "1h"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes: "5 分钟"
        case .oneHour: "1 小时"
        }
    }
}

struct ProviderAPIKey: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var key: String
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        key: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.key = key
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct ProviderProxySettings: Codable, Hashable, Sendable {
    var enabled: Bool
    var host: String
    var port: String

    init(enabled: Bool = false, host: String = "", port: String = "8080") {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(String.self, forKey: .port) ?? "8080"
    }

    var isUsable: Bool {
        enabled && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Int(port) != nil
    }
}

struct ProviderConfiguration: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var enabled: Bool
    var name: String
    var type: ProviderType
    var apiKey: String
    var baseURL: String
    var chatPath: String
    var models: [ModelConfiguration]
    /// 用户明确选择的品牌图标；nil 表示按名称和地址自动识别。
    var brandIcon: ProviderBrandIcon?
    /// `file:<name>` 指向 App Support/AssistantMedia 中的自定义供应商头像。
    var customAvatar: String?
    /// 附加到每个请求的自定义 Header。
    var customHeaders: [KeyValueField]
    /// 合并进聊天请求 body 的自定义字段；value 是 JSON 片段或字符串。
    var customBody: [KeyValueField]
    /// 仅用于供应商管理页分组，不参与请求。
    var group: String
    /// OpenAI 兼容供应商是否使用 /responses。
    var useResponsesAPI: Bool
    /// 独立图像生成接口；自动模式只启用已确认的 OpenRouter 与官方 OpenAI。
    var imageGenerationMode: ProviderImageGenerationMode
    /// 从多个已启用 Key 中按请求随机选择。
    var multiKeyEnabled: Bool
    var apiKeys: [ProviderAPIKey]
    /// OpenRouter / Claude 的自动 Prompt Caching。
    var claudePromptCachingEnabled: Bool
    var claudePromptCachingTTL: ProviderPromptCacheTTL
    /// 供应商余额查询配置。
    var balanceEnabled: Bool
    var balanceAPIPath: String
    var balanceResultPath: String
    /// 优先于全局网络代理的供应商级代理。
    var proxy: ProviderProxySettings

    init(
        id: UUID,
        enabled: Bool,
        name: String,
        type: ProviderType,
        apiKey: String,
        baseURL: String,
        chatPath: String,
        models: [ModelConfiguration],
        brandIcon: ProviderBrandIcon? = nil,
        customAvatar: String? = nil,
        customHeaders: [KeyValueField] = [],
        customBody: [KeyValueField] = [],
        group: String = "",
        useResponsesAPI: Bool = false,
        imageGenerationMode: ProviderImageGenerationMode = .automatic,
        multiKeyEnabled: Bool = false,
        apiKeys: [ProviderAPIKey] = [],
        claudePromptCachingEnabled: Bool = false,
        claudePromptCachingTTL: ProviderPromptCacheTTL = .fiveMinutes,
        balanceEnabled: Bool = false,
        balanceAPIPath: String = "/credits",
        balanceResultPath: String = "data.total_credits",
        proxy: ProviderProxySettings = ProviderProxySettings()
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.type = type
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.chatPath = chatPath
        self.models = models
        self.brandIcon = brandIcon
        self.customAvatar = customAvatar
        self.customHeaders = customHeaders
        self.customBody = customBody
        self.group = group
        self.useResponsesAPI = useResponsesAPI
        self.imageGenerationMode = imageGenerationMode
        self.multiKeyEnabled = multiKeyEnabled
        self.apiKeys = apiKeys
        self.claudePromptCachingEnabled = claudePromptCachingEnabled
        self.claudePromptCachingTTL = claudePromptCachingTTL
        self.balanceEnabled = balanceEnabled
        self.balanceAPIPath = balanceAPIPath
        self.balanceResultPath = balanceResultPath
        self.proxy = proxy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(ProviderType.self, forKey: .type) ?? .openAI
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        chatPath = try container.decodeIfPresent(String.self, forKey: .chatPath) ?? "/chat/completions"
        models = try container.decodeIfPresent([ModelConfiguration].self, forKey: .models) ?? []
        brandIcon = try? container.decode(ProviderBrandIcon.self, forKey: .brandIcon)
        customAvatar = try container.decodeIfPresent(String.self, forKey: .customAvatar)
        customHeaders = try container.decodeIfPresent([KeyValueField].self, forKey: .customHeaders) ?? []
        customBody = try container.decodeIfPresent([KeyValueField].self, forKey: .customBody) ?? []
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        useResponsesAPI = try container.decodeIfPresent(Bool.self, forKey: .useResponsesAPI) ?? false
        imageGenerationMode = try container.decodeIfPresent(
            ProviderImageGenerationMode.self,
            forKey: .imageGenerationMode
        ) ?? .automatic
        multiKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .multiKeyEnabled) ?? false
        apiKeys = try container.decodeIfPresent([ProviderAPIKey].self, forKey: .apiKeys) ?? []
        claudePromptCachingEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudePromptCachingEnabled) ?? false
        claudePromptCachingTTL = try container.decodeIfPresent(ProviderPromptCacheTTL.self, forKey: .claudePromptCachingTTL) ?? .fiveMinutes
        balanceEnabled = try container.decodeIfPresent(Bool.self, forKey: .balanceEnabled) ?? false
        balanceAPIPath = try container.decodeIfPresent(String.self, forKey: .balanceAPIPath) ?? "/credits"
        balanceResultPath = try container.decodeIfPresent(String.self, forKey: .balanceResultPath) ?? "data.total_credits"
        proxy = try container.decodeIfPresent(ProviderProxySettings.self, forKey: .proxy) ?? ProviderProxySettings()
    }

    static func new(type: ProviderType) -> ProviderConfiguration {
        ProviderConfiguration(
            id: UUID(),
            enabled: true,
            name: type.title,
            type: type,
            apiKey: "",
            baseURL: type.defaultBaseURL,
            chatPath: "/chat/completions",
            models: []
        )
    }

    var resolvedBrandIcon: ProviderBrandIcon? {
        brandIcon ?? ProviderBrandIcon.inferred(name: name, baseURL: baseURL)
    }

    var isOpenRouter: Bool {
        resolvedBrandIcon == .openRouter
            || URL(string: baseURL)?.host?.lowercased().contains("openrouter.ai") == true
    }

    var supportsClaudePromptCaching: Bool {
        type == .claude || isOpenRouter
    }

    var enabledAPIKeys: [ProviderAPIKey] {
        apiKeys.filter {
            $0.enabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasUsableAPIKey: Bool {
        if multiKeyEnabled {
            return !enabledAPIKeys.isEmpty
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ProxySettings: Codable, Hashable, Sendable {
    var enabled: Bool
    var host: String
    var port: String

    init(enabled: Bool = false, host: String = "", port: String = "") {
        self.enabled = enabled
        self.host = host
        self.port = port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(String.self, forKey: .port) ?? ""
    }

    var isUsable: Bool {
        enabled && !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
    }
}

struct ModelSelection: Codable, Hashable, Sendable {
    let providerID: UUID
    let modelID: String

    var storageKey: String { "\(providerID.uuidString)::\(modelID)" }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
