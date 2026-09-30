import Foundation
@main struct AssistantSearchChecks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        count += 1
        precondition(value(), label)
    }
    static func provider(_ type: ProviderType, _ base: String, router: Bool = false, responses: Bool = false) -> ProviderConfiguration {
        .init(id: UUID(), enabled: true, name: "Fixture", type: type, apiKey: "synthetic-only", baseURL: base, chatPath: "/chat/completions", models: [], brandIcon: router ? .openRouter : nil, useResponsesAPI: responses)
    }
    static func main() async throws {
        let base = "http://127.0.0.1:\(CommandLine.arguments[1])"
        let old = try JSONDecoder().decode(AssistantProfile.self, from: Data("{}".utf8))
        check(old.searchMode == .automatic, "legacy assistant retains automatic")
        let unknown = try JSONDecoder().decode(AssistantProfile.self, from: Data(#"{"searchMode":"future"}"#.utf8))
        check(unknown.searchMode == .automatic, "unknown mode safely defaults")
        var profiles = [old, AssistantProfile(name: "Second", searchEnabled: true)]
        profiles[0].searchMode = .modelBuiltIn
        let restored = try JSONDecoder().decode([AssistantProfile].self, from: JSONEncoder().encode(profiles))
        check(restored[0].searchMode == .modelBuiltIn && restored[1].searchMode == .automatic, "per-assistant roundtrip independent")
        for type in ProviderType.allCases {
            check(AssistantSearchMode.automatic.usesBuiltInSearch(providerType: type) == (type != .openAI), "old routing")
            check(AssistantSearchMode.modelBuiltIn.usesBuiltInSearch(providerType: type), "explicit native")
            check(!AssistantSearchMode.searchService.usesBuiltInSearch(providerType: type), "explicit client")
        }
        var custom: [String: Any] = ["tools": [["type": "function", "function": ["name": "calculate"]]]]
        let router = provider(.openAI, base, router: true)
        try AIChatService.applyBuiltInSearch(router, modelID: "router-chat", enabled: false, into: &custom)
        check((custom["tools"] as? [[String: Any]])?.count == 1, "off adds no search")
        try AIChatService.applyBuiltInSearch(router, modelID: "router-chat", enabled: true, into: &custom)
        try AIChatService.applyBuiltInSearch(router, modelID: "router-chat", enabled: true, into: &custom)
        check((custom["tools"] as? [[String: Any]])?.count == 2, "preserve local tool and deduplicate server tool")
        let official = provider(.openAI, "https://api.openai.com/v1")
        var officialBody: [String: Any] = [:]
        try AIChatService.applyBuiltInSearch(official, modelID: "gpt-5.1", enabled: true, into: &officialBody)
        check(((officialBody["tools"] as? [[String: Any]])?.first?["type"] as? String) == "web_search", "official API opts into Responses search")
        do {
            var body: [String: Any] = [:]
            try AIChatService.applyBuiltInSearch(provider(.openAI, base), modelID: "unsupported", enabled: true, into: &body)
            fatalError("unsupported proxy must not silently ignore search")
        } catch AIChatServiceError.unsupportedBuiltInSearch { count += 1 }
        let cases: [(String, ProviderConfiguration)] = [
            ("router-chat", router), ("router-responses", provider(.openAI, base, router: true, responses: true)),
            ("responses", provider(.openAI, base, responses: true)), ("claude", provider(.claude, base)), ("gemini", provider(.google, base))
        ]
        for (id, provider) in cases {
            for withTools in [false, true] {
                let options = ChatRequestOptions(builtInSearch: true, sessionID: "fixture-session")
                let messages = [ChatRequestMessage(role: "user", content: "synthetic search")]
                let stream = withTools ? AIChatService.streamReplyWithTools(provider: provider, modelID: id, messages: messages, options: options, toolHandler: { _,_,_ in fatalError("server tool must never run locally") }) : AIChatService.streamReply(provider: provider, modelID: id, messages: messages, options: options)
                var text = ""
                for try await e in stream { if case .text(let value) = e { text += value } }
                check(text.contains("answer"), "answer preserved \(id)")
                check(text.components(separatedBy: "https://example.org/source").count == 2, "citation once \(id)")
                check(text.contains("A \\[source\\]"), "citation title escaped")
            }
        }
        let mixed = AIChatService.streamReplyWithTools(provider: router, modelID: "mixed", messages: [.init(role: "user", content: "test")], options: .init(tools: [["type": "function", "function": ["name": "calculate", "parameters": ["type": "object"]]]], builtInSearch: true, sessionID: "fixture-session"), toolHandler: { name,_,_ in precondition(name == "calculate"); return "2" })
        var calls = 0, results = 0, answer = ""
        for try await e in mixed {
            switch e { case .toolCalls(let v): calls += v.count; case .toolResults(let v): results += v.count; case .text(let v): answer += v; default: break }
        }
        check(calls == 1 && results == 1 && answer.contains("answer"), "search plus client tool round")
        do {
            for try await _ in AIChatService.streamReply(provider: provider(.openAI, base, responses: true), modelID: "failed", messages: [], options: .init(builtInSearch: true)) {}
            fatalError("stream error must propagate")
        } catch AIChatServiceError.providerStreamError(let message) { check(message == "fixture search unavailable", "real provider error retained") }
        var citations = NativeSearchCitations()
        check(citations.annotations([["url": "javascript:alert(1)"], ["url": "file:///secret"]]) == nil, "reject unsafe citation schemes")
        for modelID in ["anthropic/claude-sonnet-5.5", "openai/gpt-5.1"] {
            for enabled in [false, true] {
                var configured = router
                configured.claudePromptCachingEnabled = enabled
                for try await _ in AIChatService.streamReply(provider: configured, modelID: modelID, messages: [.init(role: "user", content: "synthetic cache contract")]) {}
            }
        }
        print("PASS: \(count) search assertions")
    }
}
