import Foundation

enum OpenAIServiceTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case standard = "default"
    case flex
    case priority
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "跟随项目"
        case .standard: "标准"
        case .flex: "省钱 · Flex"
        case .priority: "加速 · Fast"
        }
    }
}

enum OpenAICacheRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case inMemory = "in_memory"
    case extended = "24h"
    case minimum30Minutes = "30m"
    case minimum12Hours = "12h"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "跟随官方默认"
        case .inMemory: "内存缓存"
        case .extended: "最长 24 小时"
        case .minimum30Minutes: "至少 30 分钟"
        case .minimum12Hours: "至少 12 小时"
        }
    }
}

enum AssistantImageGenerationSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case selectedModel
    case currentModel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .selectedModel: "指定生图模型"
        case .currentModel: "当前模型能力"
        }
    }
}

enum OpenAIReasoningPresentation {
    static func title(model: String, budget: Int?) -> String {
        if (budget ?? 0) < 0 { return "自动" }
        if (budget ?? 0) == 0 { return "关闭" }
        switch OpenAIRequestPolicy.effort(model: model, budget: budget) {
        case "low": return "低"
        case "medium": return "中"
        case "xhigh": return "极高"
        default: return "高"
        }
    }
}

/// Shared by both request builders and the existing reasoning controls.
/// Unknown and compatible-provider models keep their own protocol behavior.
enum OpenAIRequestPolicy {
    static func matches(_ model: String, _ family: String) -> Bool {
        model == family || model.hasPrefix(family + "-")
    }

    static func supportsReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        guard !m.contains("chat-latest"), !m.contains("search"),
              !m.contains("image"), !m.contains("audio"), !m.contains("realtime"),
              !m.contains("preview") else { return false }
        return ["gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.5", "gpt-5.6",
                "gpt-6", "gpt-6.1", "o1", "o3", "o4-mini"].contains { matches(m, $0) }
    }

    static func supportsNoReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        guard !m.contains("codex"), !m.contains("-pro"), supportsReasoning(m) else { return false }
        return ["gpt-5.1", "gpt-5.2", "gpt-5.4", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra",
                "gpt-5.6-luna", "gpt-6-sol", "gpt-6-luna", "gpt-6.1-terra"].contains { matches(m, $0) }
            || m == "gpt-5.6"
    }

    static func supportsExtraHigh(_ model: String) -> Bool {
        let m = model.lowercased()
        return supportsReasoning(m) && ["gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.5", "gpt-5.6", "gpt-6", "gpt-6.1"].contains { matches(m, $0) }
    }

    static func effort(model: String, budget: Int?) -> String? {
        guard supportsReasoning(model) else { return nil }
        let value = budget ?? 0
        if value < 0 { return nil } // Automatic means the model's default, not an API value "auto".
        if value == 0 { return supportsNoReasoning(model) ? "none" : nil }
        if matches(model.lowercased(), "gpt-5-pro") { return "high" }
        if model.lowercased().contains("-pro"), value <= 4_096 { return "medium" }
        if value <= 2_048 { return "low" }
        if value <= 4_096 { return "medium" }
        if value >= 16_384, supportsExtraHigh(model) { return "xhigh" }
        return "high"
    }

    static func normalizedBudget(model: String, budget: Int?) -> Int {
        guard let budget, budget != 0 else { return 0 }
        if budget < 0 { return -1 }
        switch effort(model: model, budget: budget) {
        case "low": return 1_024
        case "medium": return 4_096
        case "xhigh": return 16_384
        default: return 8_192
        }
    }

    static func supportsImageTool(_ model: String) -> Bool {
        let m = model.lowercased()
        guard !m.contains("codex"), !m.contains("chat-latest"),
              !m.contains("audio"), !m.contains("realtime"), !m.contains("nano"),
              !matches(m, "gpt-5-pro") else { return false }
        return ["gpt-4.1", "gpt-4o", "gpt-5", "gpt-5.1", "gpt-5.2", "gpt-5.4",
                "gpt-5.5", "gpt-5.6", "gpt-6", "gpt-6.1"].contains { matches(m, $0) }
    }

    static func requiresResponses(_ model: String) -> Bool {
        model.lowercased().contains("codex") || ["gpt-5-pro", "gpt-5.2-pro", "gpt-5.4-pro", "gpt-5.5-pro", "o3-pro"].contains {
            matches(model.lowercased(), $0)
        }
    }

    static func prefersResponsesForTools(_ model: String) -> Bool {
        matches(model.lowercased(), "gpt-6") || matches(model.lowercased(), "gpt-6.1")
    }

    static func supportsMemoryCache(_ model: String) -> Bool {
        let m = model.lowercased()
        return supportsExtendedCache(m) && !matches(m, "gpt-5.5")
            || ["gpt-4o", "gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-5-mini", "gpt-5-nano", "o3", "o4-mini"].contains {
                m == $0 || m.hasPrefix($0 + "-20")
            }
    }

    static func supportsExtendedCache(_ model: String) -> Bool {
        let m = model.lowercased()
        // Newer models use prompt_cache_options.ttl with different billing semantics.
        // Never translate "up to 24h" into a paid minimum-lifetime cache write.
        return ["gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.2", "gpt-5.1",
                "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini",
                "gpt-5.1-chat-latest", "gpt-5", "gpt-5-codex", "gpt-4.1"].contains {
            m == $0 || m.hasPrefix($0 + "-20")
        }
    }

    static func supportsMinimumCacheLifetime(_ model: String) -> Bool {
        ["gpt-5.6", "gpt-6", "gpt-6.1"].contains { matches(model.lowercased(), $0) }
    }

    static func cacheChoices(model: String) -> [OpenAICacheRetention] {
        if supportsMinimumCacheLifetime(model) { return [.automatic, .minimum30Minutes, .minimum12Hours] }
        var choices: [OpenAICacheRetention] = [.automatic]
        if supportsMemoryCache(model) { choices.append(.inMemory) }
        if supportsExtendedCache(model) { choices.append(.extended) }
        return choices
    }

    struct ConfigurationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Only these failures can offer a cache-specific correction. Other request
    /// failures must never trigger a settings change or a retry.
    struct CacheConfigurationError: LocalizedError, Sendable {
        let modelID: String?
        let message: String
        var errorDescription: String? { message }
    }

    static func cacheRejection(status: Int, data: Data?) -> CacheConfigurationError? {
        guard status == 400, let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let parameter = error["param"] as? String,
              ["prompt_cache_retention", "prompt_cache_options", "prompt_cache_options.ttl"].contains(parameter),
              let code = error["code"] as? String,
              ["unsupported_parameter", "unsupported_value"].contains(code) else { return nil }
        return CacheConfigurationError(modelID: nil, message: error["message"] as? String
            ?? NSLocalizedString("服务端不支持当前缓存参数。", comment: ""))
    }

    /// Called after custom Body merging. Explicit advanced parameters win;
    /// incompatible sampling fields are then removed using the actual effort.
    static func apply(
        body: inout [String: Any], model: String, responses: Bool,
        budget: Int?, tier: OpenAIServiceTier, retention: OpenAICacheRetention,
        cacheKey: String?
    ) throws {
        let effectiveModel = (body["model"] as? String ?? model).lowercased()
        if body["service_tier"] == nil, tier != .automatic {
            body["service_tier"] = tier.rawValue
        }
        if body["prompt_cache_retention"] == nil,
           body["prompt_cache_options"] == nil, retention != .automatic {
            if retention == .minimum30Minutes || retention == .minimum12Hours {
                guard supportsMinimumCacheLifetime(effectiveModel) else {
                    throw CacheConfigurationError(modelID: effectiveModel, message: NSLocalizedString("这个模型不支持最低缓存有效期，请选择它支持的缓存策略或跟随官方默认。", comment: ""))
                }
                guard retention != .minimum12Hours || responses else {
                    throw CacheConfigurationError(modelID: effectiveModel, message: NSLocalizedString("12 小时最低缓存有效期需要 Responses API，请先在服务商设置中开启。", comment: ""))
                }
                body["prompt_cache_options"] = ["ttl": retention.rawValue]
            } else {
            guard retention == .inMemory ? supportsMemoryCache(effectiveModel) : supportsExtendedCache(effectiveModel) else {
                throw CacheConfigurationError(modelID: effectiveModel, message: NSLocalizedString("这个模型不支持所选缓存策略，请在服务商设置中选择“跟随官方默认”。", comment: ""))
            }
            body["prompt_cache_retention"] = retention.rawValue
            }
        }
        if body["prompt_cache_key"] == nil, let cacheKey {
            body["prompt_cache_key"] = cacheKey
        }

        guard supportsReasoning(effectiveModel) else { return }
        var reasoning = body["reasoning"] as? [String: Any] ?? [:]
        if responses {
            if reasoning["effort"] == nil {
                reasoning["effort"] = body["reasoning_effort"] ?? effort(model: effectiveModel, budget: budget)
            }
            body.removeValue(forKey: "reasoning_effort")
            if reasoning["summary"] == nil { reasoning["summary"] = "auto" }
            body["reasoning"] = reasoning
            var include = body["include"] as? [String] ?? []
            if !include.contains("reasoning.encrypted_content") { include.append("reasoning.encrypted_content") }
            body["include"] = include
            if body["max_output_tokens"] == nil {
                body["max_output_tokens"] = body["max_completion_tokens"] ?? body["max_tokens"]
            }
            body.removeValue(forKey: "max_tokens")
            body.removeValue(forKey: "max_completion_tokens")
        } else {
            if body["reasoning_effort"] == nil {
                body["reasoning_effort"] = reasoning["effort"] ?? effort(model: effectiveModel, budget: budget)
            }
            body.removeValue(forKey: "reasoning")
            if body["max_completion_tokens"] == nil {
                body["max_completion_tokens"] = body["max_tokens"] ?? body["max_output_tokens"]
            }
            body.removeValue(forKey: "max_tokens")
            body.removeValue(forKey: "max_output_tokens")
        }
        let sentEffort = responses ? reasoning["effort"] as? String : body["reasoning_effort"] as? String
        let defaultIsNone = ["gpt-5.1", "gpt-5.2", "gpt-5.4"].contains { matches(effectiveModel, $0) }
        let samplingAllowed = supportsNoReasoning(effectiveModel)
            && (sentEffort == "none" || (sentEffort == nil && defaultIsNone))
        if !samplingAllowed {
            body.removeValue(forKey: "temperature")
            body.removeValue(forKey: "top_p")
            body.removeValue(forKey: "logprobs")
            body.removeValue(forKey: "top_logprobs")
        }
    }

    /// Assistant-level image selection is authoritative even after custom Body merging.
    static func configureImageTool(body: inout [String: Any], enabled: Bool, official: Bool) {
        var tools = body["tools"] as? [[String: Any]] ?? []
        let hadImageTool = tools.contains { $0["type"] as? String == "image_generation" }
        if !enabled {
            tools.removeAll { $0["type"] as? String == "image_generation" }
            if let choice = body["tool_choice"] as? [String: Any], choice["type"] as? String == "image_generation" {
                body.removeValue(forKey: "tool_choice")
            }
        } else if official, !hadImageTool {
            tools.append(["type": "image_generation"])
        }
        if !tools.isEmpty || body["tools"] != nil { body["tools"] = tools }
        if tools.isEmpty, body["tool_choice"] as? String == "required" {
            body.removeValue(forKey: "tool_choice")
        }
    }
}
