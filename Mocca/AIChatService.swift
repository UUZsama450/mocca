import Foundation
import CryptoKit

/// Retain data, not language-specific labels, so a visible balance can be
/// relabelled without repeating the network request or changing its identity.
enum ProviderBalanceResult: Equatable, Sendable {
    case value(String)
    case credits(remaining: String, total: String)

    @MainActor var localizedText: String {
        switch self {
        case .value(let value): return value
        case .credits(let remaining, let total):
            return L10n.format("剩余 %@ · 总额 %@", [remaining, total])
        }
    }
}

struct ChatRequestImage: Sendable {
    let mimeType: String
    let base64Data: String
}

struct ChatRequestMessage: @unchecked Sendable {
    let role: String
    let content: String
    let images: [ChatRequestImage]
    let toolCallsJSON: [[String: Any]]?
    let toolCallID: String?
    let reasoning: String?
    let reasoningDetailsJSON: [[String: Any]]?
    let contentBlocks: [[String: Any]]?
    let functionCalls: [(String, [String: Any])]?
    let functionResponses: [(String, String)]?

    init(
        role: String,
        content: String,
        images: [ChatRequestImage] = [],
        toolCallsJSON: [[String: Any]]? = nil,
        toolCallID: String? = nil,
        reasoning: String? = nil,
        reasoningDetailsJSON: [[String: Any]]? = nil,
        contentBlocks: [[String: Any]]? = nil,
        functionCalls: [(String, [String: Any])]? = nil,
        functionResponses: [(String, String)]? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
        self.toolCallsJSON = toolCallsJSON
        self.toolCallID = toolCallID
        self.reasoning = reasoning
        self.reasoningDetailsJSON = reasoningDetailsJSON
        self.contentBlocks = contentBlocks
        self.functionCalls = functionCalls
        self.functionResponses = functionResponses
    }
}

struct ChatRequestOptions: @unchecked Sendable {
    var systemPrompt: String?
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    /// nil/0 = 不显式开启思考；-1 = 自动；>0 = 自定义预算。
    var thinkingBudget: Int?
    /// Tool definitions (function calling). Each element is a tool spec dict.
    var tools: [[String: Any]]?
    /// Enable server-side web search for this assistant request.
    var builtInSearch: Bool
    /// Stable conversation identity for provider-side sticky routing and prompt caching.
    var sessionID: String?
    /// Local-only diagnostic correlation. Never serialized into a provider request.
    var diagnosticRunID: UUID?
    /// Local-only tool-loop round for correlating multiple wire requests to one reply.
    var diagnosticRound: Int

    init(
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        thinkingBudget: Int? = nil,
        tools: [[String: Any]]? = nil,
        builtInSearch: Bool = false,
        sessionID: String? = nil,
        diagnosticRunID: UUID? = nil,
        diagnosticRound: Int = 1
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.thinkingBudget = thinkingBudget
        self.tools = tools
        self.builtInSearch = builtInSearch
        self.sessionID = sessionID
        self.diagnosticRunID = diagnosticRunID
        self.diagnosticRound = diagnosticRound
    }
}

enum ChatStreamEvent: @unchecked Sendable {
    case text(String)
    case reasoning(String)
    case usage(StreamUsage)
    case toolCalls([ToolCallInfo])
    case toolResults([ToolResultInfo])
    case generatedImage(Data, mimeType: String)
    case imageGenerationProgress(String)

    var containsReplyContent: Bool {
        switch self {
        case .text(let value), .reasoning(let value):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .generatedImage(let data, _): return !data.isEmpty
        case .toolCalls(let calls): return !calls.isEmpty
        case .toolResults(let results): return !results.isEmpty
        case .usage, .imageGenerationProgress: return false
        }
    }

    var deliversImmediately: Bool {
        switch self {
        case .imageGenerationProgress, .generatedImage: return true
        default: return false
        }
    }
}

/// Chat Completions image outputs live beside content, including text-free replies.
/// Each stream owns its decoder; repeated final snapshots must not duplicate files.
struct ChatImageStreamDecoder {
    private var emittedDigests = Set<String>()

    mutating func events(from object: [String: Any]) throws -> [ChatStreamEvent] {
        if let error = object["error"] as? [String: Any] {
            throw AIChatServiceError.providerStreamError(error["message"] as? String ?? "服务商中断了回复")
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }
        let message = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
        guard let rawImages = message["images"], !(rawImages is NSNull) else { return [] }
        guard let images = rawImages as? [[String: Any]] else {
            throw AIChatServiceError.invalidGeneratedImage
        }
        var events: [ChatStreamEvent] = []
        for image in images {
            guard let imageURL = image["image_url"] as? [String: Any],
                  let value = imageURL["url"] as? String,
                  value.hasPrefix("data:image/"),
                  let comma = value.firstIndex(of: ",") else {
                throw AIChatServiceError.invalidGeneratedImage
            }
            let header = value[..<comma].dropFirst(5).split(separator: ";")
            guard header.count == 2, header[1] == "base64",
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  !data.isEmpty else { throw AIChatServiceError.invalidGeneratedImage }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard emittedDigests.insert(digest).inserted else { continue }
            events.append(.generatedImage(data, mimeType: String(header[0])))
        }
        return events
    }
}

struct StreamUsage: Sendable {
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int? = nil
    var totalTokens: Int?
}

private enum StreamWireRoute: String, Sendable {
    case openAIResponses = "openai_responses"
    case openAIChat = "openai_chat"
    case claudeMessages = "claude_messages"
    case googleGenerate = "google_generate"
    case openAIChatTools = "openai_chat_tools"
    case claudeMessagesTools = "claude_messages_tools"
    case googleGenerateTools = "google_generate_tools"
}

private struct StreamWireTraceContext: Sendable {
    let runID: UUID
    let round: Int
    let route: StreamWireRoute

    init?(options: ChatRequestOptions, route: StreamWireRoute) {
        guard StreamWireProbe.enabled, let runID = options.diagnosticRunID else { return nil }
        self.runID = runID
        self.round = max(options.diagnosticRound, 1)
        self.route = route
    }
}

/// A request-local, serially mutated probe. It stays on the URLSession stream task,
/// so its timestamps remain independent of MainActor delivery and rendering stalls.
private struct StreamWireProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-diagnoseStreaming")
    private static let sampleInterval: TimeInterval = 0.5
    private static let notableGap: TimeInterval = 0.75

    private let context: StreamWireTraceContext?
    private let startedAt: TimeInterval
    private var lastLineAt: TimeInterval?
    private var lastSampleAt: TimeInterval
    private var lineCount = 0
    private var eventCount = 0
    private var textEventCount = 0
    private var reasoningEventCount = 0
    private var otherEventCount = 0
    private var textUTF16 = 0
    private var reasoningUTF16 = 0
    private var payloadBytes = 0
    private var isFinished = false

    init(context: StreamWireTraceContext?) {
        let now = ProcessInfo.processInfo.systemUptime
        self.context = context
        self.startedAt = now
        self.lastSampleAt = now
    }

    mutating func begin() {
        guard context != nil else { return }
        log("BEGIN")
    }

    mutating func receivedHeaders(_ response: URLResponse) {
        guard context != nil else { return }
        let status = (response as? HTTPURLResponse)?.statusCode
        log(
            "HEADERS status=\(status.map { String($0) } ?? "nil")"
                + " ttfb=\(format(ProcessInfo.processInfo.systemUptime - startedAt))"
        )
    }

    mutating func receivedDataLine(payloadUTF8Count: Int) {
        guard context != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - (lastLineAt ?? startedAt)
        lineCount &+= 1
        payloadBytes &+= max(payloadUTF8Count, 0)
        lastLineAt = now

        let shouldLog = lineCount == 1
            || gap >= Self.notableGap
            || now - lastSampleAt >= Self.sampleInterval
        guard shouldLog else { return }
        lastSampleAt = now
        log(
            "LINE seq=\(lineCount) gap=\(format(gap))"
                + " payloadBytes=\(payloadUTF8Count) totalBytes=\(payloadBytes)"
                + " events=\(eventCount) textEvents=\(textEventCount)"
                + " reasoningEvents=\(reasoningEventCount)"
        )
    }

    mutating func emitted(_ event: ChatStreamEvent) {
        guard context != nil else { return }
        eventCount &+= 1
        switch event {
        case .text(let chunk):
            textEventCount &+= 1
            textUTF16 &+= chunk.utf16.count
        case .reasoning(let chunk):
            reasoningEventCount &+= 1
            reasoningUTF16 &+= chunk.utf16.count
        case .usage, .toolCalls, .toolResults, .generatedImage, .imageGenerationProgress:
            otherEventCount &+= 1
        }
    }

    mutating func finish(reason: String) {
        guard context != nil, !isFinished else { return }
        isFinished = true
        let now = ProcessInfo.processInfo.systemUptime
        let lastLineGap = lastLineAt.map { now - $0 }
        log(
            "END reason=\(reason) elapsed=\(format(now - startedAt))"
                + " lines=\(lineCount) events=\(eventCount)"
                + " textEvents=\(textEventCount) reasoningEvents=\(reasoningEventCount)"
                + " otherEvents=\(otherEventCount) textUTF16=\(textUTF16)"
                + " reasoningUTF16=\(reasoningUTF16) totalBytes=\(payloadBytes)"
                + " lastLineGap=\(lastLineGap.map { format($0) } ?? "nil")"
        )
    }

    mutating func finish(error: Error) {
        let label: String
        if let urlError = error as? URLError {
            label = "url_\(urlError.code.rawValue)"
        } else {
            label = String(describing: type(of: error))
                .replacingOccurrences(of: " ", with: "_")
        }
        finish(reason: "error_\(label)")
    }

    private func log(_ message: String) {
        guard let context else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        NSLog(
            "[stream-wire] %@",
            "t=\(format(uptime))"
                + " msg=\(String(context.runID.uuidString.prefix(5)))"
                + " round=\(context.round) route=\(context.route.rawValue) "
                + message
        )
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}

enum AIChatServiceError: LocalizedError {
    case invalidURL
    case missingAPIKey
    case httpStatus(Int, String?)
    case invalidResponse
    case emptyResponse
    case invalidGeneratedImage
    case generatedImageSaveFailed
    case providerStreamError(String)
    case imageRequestTimedOut(Int)
    case unsupportedBuiltInSearch
    case searchServiceNotConfigured
    case clientSearchNotSupported

    var errorDescription: String? {
        switch self {
        case .searchServiceNotConfigured: ErrorLocalization.lookup("请先在设置中配置应用搜索服务，或在助手设置中选择模型内置搜索。")
        case .clientSearchNotSupported: ErrorLocalization.lookup("此模型未启用工具调用，无法使用应用搜索服务。请检查模型能力设置，或选择支持内置搜索的模型。")
        case .unsupportedBuiltInSearch: ErrorLocalization.lookup("当前接口暂无法使用模型内置搜索。请改用应用搜索服务，或切换到支持此功能的模型与接口。")
        case .invalidURL: ErrorLocalization.lookup("服务商地址无效")
        case .missingAPIKey: ErrorLocalization.lookup("请先填写 API Key")
        case let .httpStatus(code, detail):
            if let detail, !detail.isEmpty {
                ErrorLocalization.format("服务商返回 HTTP %@：%@", [String(describing: code), String(describing: detail)])
            } else {
                ErrorLocalization.format("服务商返回 HTTP %@", [String(describing: code)])
            }
        case .invalidResponse: ErrorLocalization.lookup("服务商返回了无法识别的数据")
        case .emptyResponse: ErrorLocalization.lookup("服务商没有返回内容")
        case .invalidGeneratedImage: ErrorLocalization.lookup("服务商返回了图片，但图片数据格式无法读取")
        case .generatedImageSaveFailed: ErrorLocalization.lookup("已收到图片，但无法读取或保存；请重试")
        case .providerStreamError(let message): message
        case .imageRequestTimedOut(let imageCount):
            ErrorLocalization.format("图片请求等待超时（本轮实际发送了 %@ 张图片）。可以重试，或关闭“持续发送历史图片”后再发送。", [String(describing: imageCount)])
        }
    }
}

/// Converts provider citation metadata into links the existing Markdown renderer can open.
/// Kept separate from client tool calls: server tools are already executed upstream.
struct NativeSearchCitations {
    private var seenURLs = Set<String>()

    mutating func annotations(_ values: [[String: Any]]) -> String? {
        let links = values.compactMap { value -> String? in
            let citation = value["url_citation"] as? [String: Any] ?? value
            guard let raw = citation["url"] as? String,
                  let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  seenURLs.insert(url.absoluteString).inserted else { return nil }
            let title = (citation["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (title?.isEmpty == false ? title! : host)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let target = url.absoluteString.replacingOccurrences(of: ">", with: "%3E")
                .replacingOccurrences(of: "<", with: "%3C")
            return "[\(label)](<\(target)>)"
        }
        return links.isEmpty ? nil : " " + links.joined(separator: " · ") + " "
    }

    mutating func responsesEvent(_ event: [String: Any]) -> String? {
        var values: [[String: Any]] = []
        if let annotation = event["annotation"] as? [String: Any] { values.append(annotation) }
        var items: [[String: Any]] = []
        if let item = event["item"] as? [String: Any] { items.append(item) }
        if let response = event["response"] as? [String: Any] {
            items += response["output"] as? [[String: Any]] ?? []
        }
        for item in items {
            for part in item["content"] as? [[String: Any]] ?? [] {
                values += part["annotations"] as? [[String: Any]] ?? []
            }
        }
        return annotations(values)
    }

    mutating func grounding(_ metadata: [String: Any]) -> String? {
        let values = (metadata["groundingChunks"] as? [[String: Any]] ?? []).compactMap { chunk -> [String: Any]? in
            guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String else { return nil }
            return ["url": uri, "title": web["title"] as? String ?? ""]
        }
        return annotations(values)
    }
}

enum AIChatService {
    private static let openRouterMultiImageRequestTimeout: TimeInterval = 300

    private static func applyOpenRouterMultiImageRequestTimeout(
        provider: ProviderConfiguration,
        messages: [ChatRequestMessage],
        to request: inout URLRequest
    ) {
        let imageCount = messages.reduce(into: 0) { count, message in
            count += message.images.count
        }
        // Keep single-image OCR probes on the normal timeout. Otherwise OCR's
        // sequential per-image fallback could wait five minutes for every item.
        guard provider.isOpenRouter, imageCount > 1 else { return }
        request.timeoutInterval = max(
            request.timeoutInterval,
            openRouterMultiImageRequestTimeout
        )
    }

    private static func userFacingStreamError(
        _ error: Error,
        messages: [ChatRequestMessage]
    ) -> Error {
        let imageCount = messages.reduce(into: 0) { count, message in
            count += message.images.count
        }
        guard imageCount > 0,
              let urlError = error as? URLError,
              urlError.code == .timedOut else {
            return error
        }
        return AIChatServiceError.imageRequestTimedOut(imageCount)
    }

    static func streamReply(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions = ChatRequestOptions()
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !normalizedAPIKey(for: provider).isEmpty else {
                        throw AIChatServiceError.missingAPIKey
                    }

                    let stream: AsyncThrowingStream<ChatStreamEvent, Error>
                    switch provider.type {
                    case .openAI:
                        stream = usesOpenAIResponses(provider: provider, modelID: modelID, builtInSearch: options.builtInSearch)
                            ? openAIResponsesStream(provider: provider, modelID: modelID, messages: messages, options: options)
                            : (options.builtInSearch
                                ? openAIStreamWithTools(provider: provider, modelID: modelID, messages: messages, options: options)
                                : openAIStream(provider: provider, modelID: modelID, messages: messages, options: options))
                    case .claude:
                        stream = options.builtInSearch
                            ? claudeStreamWithTools(provider: provider, modelID: modelID, messages: messages, options: options)
                            : claudeStream(provider: provider, modelID: modelID, messages: messages, options: options)
                    case .google:
                        stream = options.builtInSearch
                            ? googleStreamWithTools(provider: provider, modelID: modelID, messages: messages, options: options)
                            : googleStream(provider: provider, modelID: modelID, messages: messages, options: options)
                    }

                    for try await chunk in stream {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: userFacingStreamError(error, messages: messages)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 非流式地取一段完整回复（用于标题生成等）。
    static func generateText(
        provider: ProviderConfiguration,
        modelID: String,
        prompt: String,
        options: ChatRequestOptions = ChatRequestOptions()
    ) async throws -> String {
        var result = ""
        for try await event in streamReply(
            provider: provider,
            modelID: modelID,
            messages: [ChatRequestMessage(role: "user", content: prompt)],
            options: options
        ) {
            if case .text(let chunk) = event {
                result += chunk
            }
        }
        return result
    }

    /// Stream with tool call loop. When the model calls tools, executes the handler
    /// and continues the conversation until a final text response is produced.
    /// Maximum 10 rounds to prevent infinite loops.
    static func streamReplyWithTools(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions,
        toolHandler: @escaping ToolCallHandler
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !normalizedAPIKey(for: provider).isEmpty else {
                        throw AIChatServiceError.missingAPIKey
                    }

                    var conversationMessages = messages
                    var roundCount = 0
                    let maxRounds = 10

                    while roundCount < maxRounds {
                        roundCount += 1
                        try Task.checkCancellation()
                        var roundOptions = options
                        roundOptions.diagnosticRound = roundCount

                        let stream: AsyncThrowingStream<ChatStreamEvent, Error>
                        switch provider.type {
                        case .openAI:
                            stream = usesOpenAIResponses(provider: provider, modelID: modelID, builtInSearch: options.builtInSearch)
                                ? openAIResponsesStream(provider: provider, modelID: modelID, messages: conversationMessages, options: roundOptions)
                                : openAIStreamWithTools(provider: provider, modelID: modelID, messages: conversationMessages, options: roundOptions)
                        case .claude:
                            stream = claudeStreamWithTools(provider: provider, modelID: modelID, messages: conversationMessages, options: roundOptions)
                        case .google:
                            stream = googleStreamWithTools(provider: provider, modelID: modelID, messages: conversationMessages, options: roundOptions)
                        }

                        var accumulatedText = ""
                        var accumulatedReasoning = ""
                        var pendingToolCalls: [ToolCallInfo] = []

                        for try await event in stream {
                            try Task.checkCancellation()
                            switch event {
                            case .text(let chunk):
                                accumulatedText += chunk
                                continuation.yield(.text(chunk))
                            case .reasoning(let chunk):
                                accumulatedReasoning += chunk
                                continuation.yield(.reasoning(chunk))
                            case .usage(let u):
                                continuation.yield(.usage(u))
                            case .toolCalls(let calls):
                                pendingToolCalls.append(contentsOf: calls)
                            case .toolResults:
                                break
                            case .generatedImage, .imageGenerationProgress:
                                continuation.yield(event)
                            }
                        }

                        if pendingToolCalls.isEmpty {
                            continuation.finish()
                            return
                        }

                        continuation.yield(.toolCalls(pendingToolCalls))

                        var toolResults: [ToolResultInfo] = []
                        for call in pendingToolCalls {
                            try Task.checkCancellation()
                            let result = await toolHandler(call.name, call.arguments, call.id)
                            toolResults.append(ToolResultInfo(
                                id: call.id,
                                name: call.name,
                                arguments: call.arguments,
                                content: result
                            ))
                        }
                        continuation.yield(.toolResults(toolResults))

                        switch provider.type {
                        case .openAI:
                            let reasoningDetails = pendingToolCalls.lazy.compactMap {
                                $0.metadata?["openrouter_reasoning_details"] as? [[String: Any]]
                            }.first
                            conversationMessages = appendOpenAIToolRound(
                                messages: conversationMessages,
                                assistantText: accumulatedText,
                                assistantReasoning: accumulatedReasoning,
                                assistantReasoningDetails: reasoningDetails,
                                toolCalls: pendingToolCalls,
                                toolResults: toolResults
                            )
                        case .claude:
                            conversationMessages = appendClaudeToolRound(
                                messages: conversationMessages,
                                assistantText: accumulatedText,
                                assistantReasoning: accumulatedReasoning,
                                toolCalls: pendingToolCalls,
                                toolResults: toolResults
                            )
                        case .google:
                            conversationMessages = appendGeminiToolRound(
                                messages: conversationMessages,
                                assistantText: accumulatedText,
                                toolCalls: pendingToolCalls,
                                toolResults: toolResults
                            )
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: userFacingStreamError(error, messages: messages)
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Tool Round Message Builders

    private static func appendOpenAIToolRound(
        messages: [ChatRequestMessage],
        assistantText: String,
        assistantReasoning: String,
        assistantReasoningDetails: [[String: Any]]?,
        toolCalls: [ToolCallInfo],
        toolResults: [ToolResultInfo]
    ) -> [ChatRequestMessage] {
        var result = messages
        let toolCallsJSON: [[String: Any]] = toolCalls.map { call in
            var args = "{}"
            if let data = try? JSONSerialization.data(
                withJSONObject: call.arguments,
                options: [.sortedKeys]
            ),
               let str = String(data: data, encoding: .utf8) {
                args = str
            }
            return [
                "id": call.id,
                "type": "function",
                "function": ["name": call.name, "arguments": args]
            ] as [String: Any]
        }
        let assistantMsg = ChatRequestMessage(
            role: "assistant",
            content: assistantText,
            toolCallsJSON: toolCallsJSON,
            reasoning: assistantReasoning.isEmpty ? nil : assistantReasoning,
            reasoningDetailsJSON: assistantReasoningDetails
        )
        result.append(assistantMsg)
        for tr in toolResults {
            result.append(ChatRequestMessage(
                role: "tool",
                content: tr.content,
                toolCallID: tr.id
            ))
        }
        return result
    }

    private static func appendClaudeToolRound(
        messages: [ChatRequestMessage],
        assistantText: String,
        assistantReasoning: String,
        toolCalls: [ToolCallInfo],
        toolResults: [ToolResultInfo]
    ) -> [ChatRequestMessage] {
        var result = messages
        var blocks: [[String: Any]] = []
        if !assistantReasoning.isEmpty {
            blocks.append(["type": "thinking", "thinking": assistantReasoning])
        }
        if !assistantText.isEmpty {
            blocks.append(["type": "text", "text": assistantText])
        }
        for call in toolCalls {
            blocks.append([
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": call.arguments
            ] as [String: Any])
        }
        result.append(ChatRequestMessage(role: "assistant", content: "", contentBlocks: blocks))
        var toolResultBlocks: [[String: Any]] = []
        for tr in toolResults {
            toolResultBlocks.append([
                "type": "tool_result",
                "tool_use_id": tr.id,
                "content": tr.content
            ] as [String: Any])
        }
        result.append(ChatRequestMessage(role: "user", content: "", contentBlocks: toolResultBlocks))
        return result
    }

    private static func appendGeminiToolRound(
        messages: [ChatRequestMessage],
        assistantText: String,
        toolCalls: [ToolCallInfo],
        toolResults: [ToolResultInfo]
    ) -> [ChatRequestMessage] {
        var result = messages
        result.append(ChatRequestMessage(
            role: "assistant",
            content: assistantText,
            functionCalls: toolCalls.map { ($0.name, $0.arguments) }
        ))
        result.append(ChatRequestMessage(
            role: "tool",
            content: "",
            functionResponses: toolResults.map { ($0.name, $0.content) }
        ))
        return result
    }

    static func fetchModels(for provider: ProviderConfiguration) async throws -> [ModelConfiguration] {
        let apiKey = normalizedAPIKey(for: provider)
        guard !apiKey.isEmpty else {
            throw AIChatServiceError.missingAPIKey
        }

        var request: URLRequest
        switch provider.type {
        case .openAI:
            guard let baseModelsURL = endpoint(baseURL: provider.baseURL, path: "/models") else {
                throw AIChatServiceError.invalidURL
            }
            let url: URL
            if provider.isOpenRouter,
               var components = URLComponents(url: baseModelsURL, resolvingAgainstBaseURL: false) {
                components.queryItems = [URLQueryItem(name: "output_modalities", value: "all")]
                guard let expandedURL = components.url else { throw AIChatServiceError.invalidURL }
                url = expandedURL
            } else {
                url = baseModelsURL
            }
            request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .claude:
            guard let url = endpoint(baseURL: provider.baseURL, path: "/models") else {
                throw AIChatServiceError.invalidURL
            }
            request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            guard var components = URLComponents(
                url: endpoint(baseURL: provider.baseURL, path: "/models") ?? URL(fileURLWithPath: "/"),
                resolvingAgainstBaseURL: false
            ) else {
                throw AIChatServiceError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let url = components.url else { throw AIChatServiceError.invalidURL }
            request = URLRequest(url: url)
        }

        applyCustomHeaders(provider, to: &request)
        let (data, response) = try await makeSession(for: provider).data(for: request)
        try validate(response, body: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIChatServiceError.invalidResponse
        }

        let models: [ModelConfiguration]
        switch provider.type {
        case .openAI:
            let entries = object["data"] as? [[String: Any]] ?? []
            models = entries.compactMap { entry in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                if provider.isOpenRouter {
                    return openRouterModelConfiguration(entry: entry, id: id)
                }
                return ModelConfiguration(id: id, displayName: entry["display_name"] as? String)
            }
        case .claude:
            let entries = object["data"] as? [[String: Any]] ?? []
            models = entries.compactMap { entry in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                return ModelConfiguration(id: id, displayName: entry["display_name"] as? String)
            }
        case .google:
            let entries = object["models"] as? [[String: Any]] ?? []
            models = entries.compactMap { entry in
                let methods = entry["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent"),
                      let rawName = entry["name"] as? String else { return nil }
                let id = rawName.replacingOccurrences(of: "models/", with: "")
                return ModelConfiguration(id: id, displayName: entry["displayName"] as? String)
            }
        }

        return models.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func fetchBalance(for provider: ProviderConfiguration) async throws -> ProviderBalanceResult {
        let apiKey = normalizedAPIKey(for: provider)
        guard !apiKey.isEmpty else {
            throw AIChatServiceError.missingAPIKey
        }
        let path = provider.balanceAPIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = endpoint(
            baseURL: provider.baseURL,
            path: path.isEmpty ? "/credits" : path
        ) else {
            throw AIChatServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        switch provider.type {
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw AIChatServiceError.invalidURL
            }
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "key" }
            items.append(URLQueryItem(name: "key", value: apiKey))
            components.queryItems = items
            guard let keyedURL = components.url else { throw AIChatServiceError.invalidURL }
            request.url = keyedURL
        }
        applyCustomHeaders(provider, to: &request)

        let (data, response) = try await makeSession(for: provider).data(for: request)
        try validate(response, body: data)
        let object = try JSONSerialization.jsonObject(with: data)

        if provider.isOpenRouter,
           let root = object as? [String: Any],
           let creditData = root["data"] as? [String: Any],
           let total = numericValue(creditData["total_credits"]),
           let used = numericValue(creditData["total_usage"]) {
            return .credits(remaining: formatDecimal(max(0, total - used)), total: formatDecimal(total))
        }

        let resultPath = provider.balanceResultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resultPath.isEmpty,
              let value = jsonValue(at: resultPath, in: object) else {
            throw AIChatServiceError.invalidResponse
        }
        if let number = numericValue(value) {
            return .value(formatDecimal(number))
        }
        if let string = value as? String, !string.isEmpty {
            return .value(string)
        }
        throw AIChatServiceError.invalidResponse
    }

    private static func openRouterModelConfiguration(
        entry: [String: Any],
        id: String
    ) -> ModelConfiguration {
        let architecture = entry["architecture"] as? [String: Any] ?? [:]
        let rawInput = architecture["input_modalities"] as? [String] ?? []
        let rawOutput = architecture["output_modalities"] as? [String] ?? []
        let parameters = Set(entry["supported_parameters"] as? [String] ?? [])

        let input = ModelModality.allCases.filter { rawInput.contains($0.rawValue) }
        let output = ModelModality.allCases.filter { rawOutput.contains($0.rawValue) }
        let kind: ModelKind = rawOutput.contains("embeddings")
            || ModelCapabilityRegistry.isLikelyEmbeddingID(id)
            ? .embedding
            : .chat

        var abilities: [ModelAbility] = []
        if parameters.contains("tools") || parameters.contains("tool_choice") {
            abilities.append(.tool)
        }
        if parameters.contains("reasoning")
            || parameters.contains("include_reasoning")
            || parameters.contains("reasoning_effort") {
            abilities.append(.reasoning)
        }

        let metadata = ModelCapabilities(
            kind: kind,
            input: input.isEmpty ? [.text] : input,
            output: output.isEmpty ? [.text] : output,
            abilities: abilities
        )
        return ModelConfiguration(
            id: id,
            displayName: (entry["name"] as? String) ?? (entry["display_name"] as? String),
            capabilityOverride: ModelCapabilityRegistry.infer(id: id, base: metadata)
        )
    }

    private static func usesOpenAIResponses(
        provider: ProviderConfiguration,
        modelID: String,
        builtInSearch: Bool = false
    ) -> Bool {
        guard provider.type == .openAI else { return false }
        if provider.useResponsesAPI { return true }
        if builtInSearch, !provider.isOpenRouter,
           URL(string: provider.baseURL)?.host?.lowercased() == "api.openai.com" { return true }
        guard
              let host = URL(string: provider.baseURL)?.host?.lowercased(),
              host == "api.openai.com",
              let model = provider.models.first(where: { $0.id == modelID }) else {
            return false
        }
        return !model.builtInTools.isEmpty
    }

    private static func openAIResponsesStream(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let traceContext = StreamWireTraceContext(options: options, route: .openAIResponses)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var wireProbe = StreamWireProbe(context: traceContext)
                wireProbe.begin()
                do {
                    let apiKey = normalizedAPIKey(for: provider)
                    guard let url = endpoint(baseURL: provider.baseURL, path: "/responses") else {
                        throw AIChatServiceError.invalidURL
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var body: [String: Any] = [
                        "model": modelID,
                        "input": openAIResponsesInput(messages),
                        "stream": true
                    ]
                    if let instructions = options.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !instructions.isEmpty {
                        body["instructions"] = instructions
                    }
                    if let maxTokens = options.maxTokens {
                        body["max_output_tokens"] = maxTokens
                    }

                    let builtIns = provider.models.first(where: { $0.id == modelID })?.builtInTools ?? []
                    let responseTools = openAIResponsesTools(builtIns: builtIns, functionTools: options.tools)
                    if !responseTools.isEmpty {
                        body["tools"] = responseTools
                    }

                    applyCustomHeaders(provider, modelID: modelID, to: &request)
                    applyClaudePromptCaching(provider, modelID: modelID, into: &body)
                    mergeCustomBody(provider, modelID: modelID, into: &body)
                    try applyBuiltInSearch(provider, modelID: modelID, enabled: options.builtInSearch, into: &body)
                    applyOpenRouterReasoning(
                        provider,
                        thinkingBudget: options.thinkingBudget,
                        usesResponsesAPI: true,
                        into: &body
                    )
                    applyOpenRouterSession(provider, sessionID: options.sessionID, into: &body)
                    applyOpenRouterMultiImageRequestTimeout(
                        provider: provider,
                        messages: messages,
                        to: &request
                    )
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: body,
                        options: [.sortedKeys]
                    )

                    let (bytes, response) = try await makeSession(for: provider).bytes(for: request)
                    wireProbe.receivedHeaders(response)
                    try await validateStreamingResponse(response, bytes: bytes)

                    var functionCalls: [String: (id: String, name: String, arguments: String)] = [:]
                    var emittedImageKeys = Set<String>()

                    func imageEvent(
                        from item: [String: Any],
                        emittedKeys: inout Set<String>
                    ) throws -> ChatStreamEvent? {
                        guard item["type"] as? String == "image_generation_call" else { return nil }
                        guard let encoded = item["result"] as? String,
                              let data = Data(base64Encoded: encoded), !data.isEmpty else {
                            throw AIChatServiceError.invalidGeneratedImage
                        }
                        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        guard emittedKeys.insert(key).inserted else { return nil }
                        let format = (item["output_format"] as? String) ?? "png"
                        return .generatedImage(data, mimeType: "image/\(format == "jpg" ? "jpeg" : format)")
                    }

                    var searchCitations = NativeSearchCitations()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        wireProbe.receivedDataLine(payloadUTF8Count: payload.utf8.count)
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = object["type"] as? String else {
                            continue
                        }

                        if let links = searchCitations.responsesEvent(object) {
                            continuation.yield(.text(links))
                        }
                        switch type {
                        case "error", "response.failed":
                            let response = object["response"] as? [String: Any] ?? object
                            let error = response["error"] as? [String: Any] ?? response
                            throw AIChatServiceError.providerStreamError(error["message"] as? String ?? ErrorLocalization.lookup("服务商中断了回复"))
                        case "response.output_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty {
                                let event = ChatStreamEvent.text(delta)
                                wireProbe.emitted(event)
                                continuation.yield(event)
                            }
                        case "response.reasoning.delta",
                             "response.reasoning_summary_text.delta",
                             "response.reasoning_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty {
                                let event = ChatStreamEvent.reasoning(delta)
                                wireProbe.emitted(event)
                                continuation.yield(event)
                            }
                        case "response.image_generation_call.in_progress", "response.image_generation_call.generating":
                            continuation.yield(.imageGenerationProgress("正在生成图片"))
                        case "response.output_item.added":
                            guard let item = object["item"] as? [String: Any] else { break }
                            if item["type"] as? String == "image_generation_call" {
                                continuation.yield(.imageGenerationProgress("正在生成图片"))
                                break
                            }
                            guard item["type"] as? String == "function_call" else { break }
                            let key = (item["id"] as? String)
                                ?? String(object["output_index"] as? Int ?? functionCalls.count)
                            functionCalls[key] = (
                                id: (item["call_id"] as? String) ?? key,
                                name: (item["name"] as? String) ?? "",
                                arguments: (item["arguments"] as? String) ?? ""
                            )
                        case "response.function_call_arguments.delta":
                            let key = (object["item_id"] as? String)
                                ?? String(object["output_index"] as? Int ?? 0)
                            let existing = functionCalls[key] ?? (
                                id: (object["call_id"] as? String) ?? key,
                                name: (object["name"] as? String) ?? "",
                                arguments: ""
                            )
                            functionCalls[key] = (
                                id: existing.id,
                                name: existing.name,
                                arguments: existing.arguments + ((object["delta"] as? String) ?? "")
                            )
                        case "response.output_item.done":
                            guard let item = object["item"] as? [String: Any] else { break }
                            let key = (item["id"] as? String)
                                ?? String(object["output_index"] as? Int ?? 0)
                            if item["type"] as? String == "function_call" {
                                let existing = functionCalls[key]
                                functionCalls[key] = (
                                    id: (item["call_id"] as? String) ?? existing?.id ?? key,
                                    name: (item["name"] as? String) ?? existing?.name ?? "",
                                    arguments: (item["arguments"] as? String) ?? existing?.arguments ?? ""
                                )
                            } else if let event = try imageEvent(
                                from: item,
                                emittedKeys: &emittedImageKeys
                            ) {
                                wireProbe.emitted(event)
                                continuation.yield(event)
                            }
                        case "response.completed":
                            if let responseObject = object["response"] as? [String: Any] {
                                if let usage = responseObject["usage"] as? [String: Any] {
                                    let event = ChatStreamEvent.usage(StreamUsage(
                                        promptTokens: integerValue(usage["input_tokens"]),
                                        completionTokens: integerValue(usage["output_tokens"]),
                                        cachedTokens: cachedPromptTokens(in: usage),
                                        totalTokens: integerValue(usage["total_tokens"])
                                    ))
                                    wireProbe.emitted(event)
                                    continuation.yield(event)
                                }
                                let output = responseObject["output"] as? [[String: Any]] ?? []
                                for (index, item) in output.enumerated() {
                                    if item["type"] as? String == "function_call" {
                                        let key = (item["id"] as? String) ?? String(index)
                                        let existing = functionCalls[key]
                                        functionCalls[key] = (
                                            id: (item["call_id"] as? String) ?? existing?.id ?? key,
                                            name: (item["name"] as? String) ?? existing?.name ?? "",
                                            arguments: (item["arguments"] as? String) ?? existing?.arguments ?? ""
                                        )
                                    } else if let event = try imageEvent(
                                        from: item,
                                        emittedKeys: &emittedImageKeys
                                    ) {
                                        wireProbe.emitted(event)
                                        continuation.yield(event)
                                    }
                                }
                            }
                        default:
                            break
                        }
                    }

                    let calls: [ToolCallInfo] = functionCalls.values.compactMap { call in
                        guard !call.name.isEmpty else { return nil }
                        let arguments: [String: Any]
                        if let data = call.arguments.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            arguments = object
                        } else {
                            arguments = [:]
                        }
                        return ToolCallInfo(id: call.id, name: call.name, arguments: arguments)
                    }
                    if !calls.isEmpty {
                        let event = ChatStreamEvent.toolCalls(calls)
                        wireProbe.emitted(event)
                        continuation.yield(event)
                    }
                    wireProbe.finish(reason: "eof")
                    continuation.finish()
                } catch is CancellationError {
                    wireProbe.finish(reason: "cancelled")
                    continuation.finish()
                } catch {
                    wireProbe.finish(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func openAIResponsesInput(_ messages: [ChatRequestMessage]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            if message.role == "tool", let callID = message.toolCallID {
                input.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": message.content
                ])
                continue
            }

            if message.role == "assistant", let calls = message.toolCallsJSON, !calls.isEmpty {
                if !message.content.isEmpty {
                    input.append(["role": "assistant", "content": message.content])
                }
                for call in calls {
                    let function = call["function"] as? [String: Any] ?? [:]
                    input.append([
                        "type": "function_call",
                        "call_id": (call["id"] as? String) ?? "call_\(UUID().uuidString)",
                        "name": (function["name"] as? String) ?? "",
                        "arguments": (function["arguments"] as? String) ?? "{}"
                    ])
                }
                continue
            }

            let role: String
            switch message.role {
            case "system": role = "developer"
            case "assistant": role = "assistant"
            default: role = "user"
            }
            guard !message.images.isEmpty else {
                input.append(["role": role, "content": message.content])
                continue
            }
            var content: [[String: Any]] = []
            if !message.content.isEmpty {
                content.append(["type": "input_text", "text": message.content])
            }
            for image in message.images {
                content.append([
                    "type": "input_image",
                    "image_url": "data:\(image.mimeType);base64,\(image.base64Data)"
                ])
            }
            input.append(["role": role, "content": content])
        }
        return input
    }

    private static func openAIResponsesTools(
        builtIns: [ModelBuiltInTool],
        functionTools: [[String: Any]]?
    ) -> [[String: Any]] {
        var result: [[String: Any]] = builtIns.map { tool in
            switch tool {
            case .codeInterpreter:
                return [
                    "type": "code_interpreter",
                    "container": ["type": "auto", "memory_limit": "4g"]
                ]
            case .imageGeneration:
                return ["type": "image_generation"]
            }
        }
        for tool in functionTools ?? [] {
            guard tool["type"] as? String == "function",
                  let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty else { continue }
            var converted: [String: Any] = ["type": "function", "name": name]
            if let description = function["description"] {
                converted["description"] = description
            }
            converted["parameters"] = function["parameters"] ?? ["type": "object", "properties": [:]]
            result.append(converted)
        }
        return result
    }

    private static func expectsOpenRouterImages(_ provider: ProviderConfiguration, modelID: String) -> Bool {
        provider.isOpenRouter && (provider.models.first(where: { $0.id == modelID })
            ?? ModelConfiguration(id: modelID)).capabilities.output.contains(.image)
    }

    private static func applyOpenRouterImageOutput(
        _ provider: ProviderConfiguration,
        modelID: String,
        body: inout [String: Any],
        request: inout URLRequest
    ) {
        guard expectsOpenRouterImages(provider, modelID: modelID) else { return }
        if body["modalities"] == nil {
            let capabilities = (provider.models.first(where: { $0.id == modelID })
                ?? ModelConfiguration(id: modelID)).capabilities
            body["modalities"] = capabilities.output.contains(.text) ? ["text", "image"] : ["image"]
        }
        request.timeoutInterval = max(request.timeoutInterval, 300)
    }

    private static func openAIStream(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        sseStream(
            provider: provider,
            traceContext: StreamWireTraceContext(options: options, route: .openAIChat),
            receivesChatImages: true,
            request: tryResult {
                let apiKey = normalizedAPIKey(for: provider)
                let path = provider.chatPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "/chat/completions"
                    : provider.chatPath
                guard let url = endpoint(baseURL: provider.baseURL, path: path) else {
                    throw AIChatServiceError.invalidURL
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                var wireMessages: [[String: Any]] = messages.map { message in
                    guard !message.images.isEmpty else {
                        return ["role": message.role, "content": message.content]
                    }
                    var parts: [[String: Any]] = []
                    if !message.content.isEmpty {
                        parts.append(["type": "text", "text": message.content])
                    }
                    for image in message.images {
                        parts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64Data)"]
                        ])
                    }
                    return ["role": message.role, "content": parts]
                }
                if let systemPrompt = options.systemPrompt {
                    wireMessages.insert(["role": "system", "content": systemPrompt], at: 0)
                }
                var body: [String: Any] = [
                    "model": modelID,
                    "messages": wireMessages,
                    "stream": true
                ]
                // OpenRouter 的部分上游不接受 stream_options；其余 OpenAI 兼容接口保留 usage 统计。
                if !provider.isOpenRouter {
                    body["stream_options"] = ["include_usage": true]
                }
                if let temperature = options.temperature {
                    body["temperature"] = temperature
                }
                if let topP = options.topP {
                    body["top_p"] = topP
                }
                if let maxTokens = options.maxTokens {
                    body["max_tokens"] = maxTokens
                }
                applyCustomHeaders(provider, modelID: modelID, to: &request)
                applyClaudePromptCaching(provider, modelID: modelID, into: &body)
                mergeCustomBody(provider, modelID: modelID, into: &body)
                applyOpenRouterImageOutput(provider, modelID: modelID, body: &body, request: &request)
                applyOpenRouterReasoning(
                    provider,
                    thinkingBudget: options.thinkingBudget,
                    usesResponsesAPI: false,
                    into: &body
                )
                applyOpenRouterSession(provider, sessionID: options.sessionID, into: &body)
                applyOpenRouterMultiImageRequestTimeout(
                    provider: provider,
                    messages: messages,
                    to: &request
                )
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: body,
                    options: [.sortedKeys]
                )
                return request
            },
            parse: { object in
                var events: [ChatStreamEvent] = []
                // usage 那一段的 choices 通常为空，先单独处理。
                if let usage = object["usage"] as? [String: Any] {
                    events.append(.usage(StreamUsage(
                        promptTokens: integerValue(usage["prompt_tokens"]),
                        completionTokens: integerValue(usage["completion_tokens"]),
                        cachedTokens: cachedPromptTokens(in: usage),
                        totalTokens: integerValue(usage["total_tokens"])
                    )))
                }
                let choices = object["choices"] as? [[String: Any]]
                if let delta = choices?.first?["delta"] as? [String: Any]
                    ?? choices?.first?["message"] as? [String: Any] {
                    for reasoning in visibleReasoningChunks(in: delta) {
                        events.append(.reasoning(reasoning))
                    }
                    if let content = delta["content"] as? String, !content.isEmpty {
                        events.append(.text(content))
                    }
                }
                return events
            }
        )
    }

    private static func claudeStream(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        sseStream(
            provider: provider,
            traceContext: StreamWireTraceContext(options: options, route: .claudeMessages),
            request: tryResult {
                let apiKey = normalizedAPIKey(for: provider)
                guard let url = endpoint(baseURL: provider.baseURL, path: "/messages") else {
                    throw AIChatServiceError.invalidURL
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                let thinkingBudget = options.thinkingBudget ?? 0
                let thinkingEnabled = thinkingBudget != 0
                // Claude 需要明确的 budget_tokens；“自动”(-1) 时用一个合理默认。
                let claudeBudget = thinkingBudget > 0 ? thinkingBudget : 4096
                var maxTokens = options.maxTokens ?? 4096
                if thinkingEnabled {
                    // max_tokens 必须大于思考预算。
                    maxTokens = max(maxTokens, claudeBudget + 1024)
                }
                var body: [String: Any] = [
                    "model": modelID,
                    "messages": messages.map { message -> [String: Any] in
                        let role = message.role == "assistant" ? "assistant" : "user"
                        guard !message.images.isEmpty else {
                            return ["role": role, "content": message.content]
                        }
                        var parts: [[String: Any]] = message.images.map { image in
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": image.mimeType,
                                    "data": image.base64Data
                                ]
                            ]
                        }
                        if !message.content.isEmpty {
                            parts.append(["type": "text", "text": message.content])
                        }
                        return ["role": role, "content": parts]
                    },
                    "max_tokens": maxTokens,
                    "stream": true
                ]
                if let systemPrompt = options.systemPrompt {
                    body["system"] = systemPrompt
                }
                if thinkingEnabled {
                    // 开启 thinking 时 Claude 不允许自定义 temperature/top_p。
                    body["thinking"] = ["type": "enabled", "budget_tokens": claudeBudget]
                } else {
                    if let temperature = options.temperature {
                        body["temperature"] = temperature
                    }
                    if let topP = options.topP {
                        body["top_p"] = topP
                    }
                }
                applyCustomHeaders(provider, modelID: modelID, to: &request)
                applyClaudePromptCaching(provider, modelID: modelID, into: &body)
                mergeCustomBody(provider, modelID: modelID, into: &body)
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: body,
                    options: [.sortedKeys]
                )
                return request
            },
            parse: { object in
                switch object["type"] as? String {
                case "message_start":
                    if let message = object["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        return [.usage(StreamUsage(
                            promptTokens: usage["input_tokens"] as? Int,
                            completionTokens: usage["output_tokens"] as? Int,
                            totalTokens: nil
                        ))]
                    }
                case "message_delta":
                    if let usage = object["usage"] as? [String: Any] {
                        return [.usage(StreamUsage(
                            promptTokens: nil,
                            completionTokens: usage["output_tokens"] as? Int,
                            totalTokens: nil
                        ))]
                    }
                case "content_block_delta":
                    guard let delta = object["delta"] as? [String: Any] else { return [] }
                    switch delta["type"] as? String {
                    case "text_delta":
                        if let text = delta["text"] as? String, !text.isEmpty {
                            return [.text(text)]
                        }
                    case "thinking_delta":
                        if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                            return [.reasoning(thinking)]
                        }
                    default:
                        break
                    }
                default:
                    break
                }
                return []
            }
        )
    }

    private static func googleStream(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        sseStream(
            provider: provider,
            traceContext: StreamWireTraceContext(options: options, route: .googleGenerate),
            request: tryResult {
                let apiKey = normalizedAPIKey(for: provider)
                let cleanedModelID = modelID.replacingOccurrences(of: "models/", with: "")
                let encodedModelID = cleanedModelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? cleanedModelID
                let path = "/models/\(encodedModelID):streamGenerateContent"
                guard let base = endpoint(baseURL: provider.baseURL, path: path),
                      var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                    throw AIChatServiceError.invalidURL
                }
                components.queryItems = [
                    URLQueryItem(name: "alt", value: "sse"),
                    URLQueryItem(name: "key", value: apiKey)
                ]
                guard let url = components.url else { throw AIChatServiceError.invalidURL }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                var body: [String: Any] = [
                    "contents": messages.map { message -> [String: Any] in
                        var parts: [[String: Any]] = []
                        if !message.content.isEmpty || message.images.isEmpty {
                            parts.append(["text": message.content])
                        }
                        for image in message.images {
                            parts.append([
                                "inline_data": [
                                    "mime_type": image.mimeType,
                                    "data": image.base64Data
                                ]
                            ])
                        }
                        return [
                            "role": message.role == "assistant" ? "model" : "user",
                            "parts": parts
                        ]
                    }
                ]
                if let systemPrompt = options.systemPrompt {
                    body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
                }
                var generationConfig: [String: Any] = [:]
                if let temperature = options.temperature {
                    generationConfig["temperature"] = temperature
                }
                if let topP = options.topP {
                    generationConfig["topP"] = topP
                }
                if let maxTokens = options.maxTokens {
                    generationConfig["maxOutputTokens"] = maxTokens
                }
                if let thinkingBudget = options.thinkingBudget, thinkingBudget != 0 {
                    // Gemini 的 thinkingBudget = -1 表示动态思考（模型自动决定）。
                    generationConfig["thinkingConfig"] = [
                        "thinkingBudget": thinkingBudget,
                        "includeThoughts": true
                    ]
                }
                if !generationConfig.isEmpty {
                    body["generationConfig"] = generationConfig
                }
                applyCustomHeaders(provider, modelID: modelID, to: &request)
                mergeCustomBody(provider, modelID: modelID, into: &body)
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: body,
                    options: [.sortedKeys]
                )
                return request
            },
            parse: { object in
                var events: [ChatStreamEvent] = []
                let candidates = object["candidates"] as? [[String: Any]]
                let content = candidates?.first?["content"] as? [String: Any]
                if let parts = content?["parts"] as? [[String: Any]] {
                    for part in parts {
                        guard let text = part["text"] as? String, !text.isEmpty else { continue }
                        events.append(part["thought"] as? Bool == true ? .reasoning(text) : .text(text))
                    }
                }
                if let usage = object["usageMetadata"] as? [String: Any] {
                    events.append(.usage(StreamUsage(
                        promptTokens: usage["promptTokenCount"] as? Int,
                        completionTokens: usage["candidatesTokenCount"] as? Int,
                        totalTokens: usage["totalTokenCount"] as? Int
                    )))
                }
                return events
            }
        )
    }

    // MARK: - Provider Streams With Tools

    private static func openAIStreamWithTools(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let traceContext = StreamWireTraceContext(options: options, route: .openAIChatTools)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var wireProbe = StreamWireProbe(context: traceContext)
                wireProbe.begin()
                do {
                    let apiKey = normalizedAPIKey(for: provider)
                    let path = provider.chatPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "/chat/completions"
                        : provider.chatPath
                    guard let url = endpoint(baseURL: provider.baseURL, path: path) else {
                        throw AIChatServiceError.invalidURL
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var wireMessages: [[String: Any]] = messages.map { message in
                        if message.role == "tool", let callID = message.toolCallID {
                            return ["role": "tool", "tool_call_id": callID, "content": message.content]
                        }
                        if message.role == "assistant", let calls = message.toolCallsJSON, !calls.isEmpty {
                            var msg: [String: Any] = ["role": "assistant", "tool_calls": calls]
                            if !message.content.isEmpty { msg["content"] = message.content }
                            if provider.isOpenRouter {
                                if let details = message.reasoningDetailsJSON, !details.isEmpty {
                                    msg["reasoning_details"] = details
                                } else if let reasoning = message.reasoning, !reasoning.isEmpty {
                                    msg["reasoning"] = reasoning
                                }
                            }
                            return msg
                        }
                        guard !message.images.isEmpty else {
                            return ["role": message.role, "content": message.content]
                        }
                        var parts: [[String: Any]] = []
                        if !message.content.isEmpty {
                            parts.append(["type": "text", "text": message.content])
                        }
                        for image in message.images {
                            parts.append([
                                "type": "image_url",
                                "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64Data)"]
                            ])
                        }
                        return ["role": message.role, "content": parts]
                    }
                    if let systemPrompt = options.systemPrompt {
                        wireMessages.insert(["role": "system", "content": systemPrompt], at: 0)
                    }
                    var body: [String: Any] = [
                        "model": modelID,
                        "messages": wireMessages,
                        "stream": true
                    ]
                    if !provider.isOpenRouter {
                        body["stream_options"] = ["include_usage": true]
                    }
                    if let temperature = options.temperature { body["temperature"] = temperature }
                    if let topP = options.topP { body["top_p"] = topP }
                    if let maxTokens = options.maxTokens { body["max_tokens"] = maxTokens }
                    if let tools = options.tools, !tools.isEmpty { body["tools"] = tools }
                    applyCustomHeaders(provider, modelID: modelID, to: &request)
                    applyClaudePromptCaching(provider, modelID: modelID, into: &body)
                    mergeCustomBody(provider, modelID: modelID, into: &body)
                    try applyBuiltInSearch(provider, modelID: modelID, enabled: options.builtInSearch, into: &body)
                    applyOpenRouterImageOutput(provider, modelID: modelID, body: &body, request: &request)
                    applyOpenRouterReasoning(
                        provider,
                        thinkingBudget: options.thinkingBudget,
                        usesResponsesAPI: false,
                        into: &body
                    )
                    applyOpenRouterSession(provider, sessionID: options.sessionID, into: &body)
                    applyOpenRouterMultiImageRequestTimeout(
                        provider: provider,
                        messages: messages,
                        to: &request
                    )
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: body,
                        options: [.sortedKeys]
                    )

                    var imageDecoder = ChatImageStreamDecoder()
                    let (bytes, response) = try await makeSession(for: provider).bytes(for: request)
                    wireProbe.receivedHeaders(response)
                    try await validateStreamingResponse(response, bytes: bytes)

                    var toolCallAccumulator: [String: (name: String, args: String)] = [:]
                    var openRouterReasoningDetails: [[String: Any]] = []

                    var searchCitations = NativeSearchCitations()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        wireProbe.receivedDataLine(payloadUTF8Count: payload.utf8.count)
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        for event in try imageDecoder.events(from: object) {
                            wireProbe.emitted(event)
                            continuation.yield(event)
                        }
                        if let usage = object["usage"] as? [String: Any] {
                            let event = ChatStreamEvent.usage(StreamUsage(
                                promptTokens: integerValue(usage["prompt_tokens"]),
                                completionTokens: integerValue(usage["completion_tokens"]),
                                cachedTokens: cachedPromptTokens(in: usage),
                                totalTokens: integerValue(usage["total_tokens"])
                            ))
                            wireProbe.emitted(event)
                            continuation.yield(event)
                        }
                        guard let choices = object["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }
                        let delta = choice["delta"] as? [String: Any]
                            ?? choice["message"] as? [String: Any] ?? [:]

                        if let links = searchCitations.annotations(delta["annotations"] as? [[String: Any]] ?? []) {
                            continuation.yield(.text(links))
                        }

                        if provider.isOpenRouter,
                           let details = delta["reasoning_details"] as? [[String: Any]],
                           !details.isEmpty {
                            openRouterReasoningDetails.append(contentsOf: details)
                        }
                        for reasoning in visibleReasoningChunks(in: delta) {
                            let event = ChatStreamEvent.reasoning(reasoning)
                            wireProbe.emitted(event)
                            continuation.yield(event)
                        }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            let event = ChatStreamEvent.text(content)
                            wireProbe.emitted(event)
                            continuation.yield(event)
                        }

                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                let idx = "\(tc["index"] ?? 0)"
                                let fn = tc["function"] as? [String: Any] ?? [:]
                                let id = tc["id"] as? String
                                let name = fn["name"] as? String
                                let argsDelta = fn["arguments"] as? String ?? ""

                                if let id, !id.isEmpty {
                                    toolCallAccumulator[idx] = (name: name ?? toolCallAccumulator[idx]?.name ?? "", args: argsDelta)
                                } else {
                                    let existing = toolCallAccumulator[idx]
                                    toolCallAccumulator[idx] = (
                                        name: name ?? existing?.name ?? "",
                                        args: (existing?.args ?? "") + argsDelta
                                    )
                                }
                                if let id, !id.isEmpty {
                                    toolCallAccumulator[idx] = (name: name ?? "", args: argsDelta)
                                }
                            }
                        }

                        let finishReason = choice["finish_reason"] as? String
                        if finishReason == "tool_calls" || finishReason == "stop" {
                            if !toolCallAccumulator.isEmpty && finishReason == "tool_calls" {
                                break
                            }
                        }
                    }

                    if !toolCallAccumulator.isEmpty {
                        var calls: [ToolCallInfo] = []
                        for (index, entry) in toolCallAccumulator
                            .sorted(by: { $0.key < $1.key })
                            .enumerated() {
                            let value = entry.value
                            let args: [String: Any]
                            if let data = value.args.data(using: .utf8),
                               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                args = parsed
                            } else {
                                args = [:]
                            }
                            let id = "call_\(UUID().uuidString.prefix(8))"
                            var metadata: [String: Any]?
                            if index == 0, !openRouterReasoningDetails.isEmpty {
                                metadata = [
                                    "openrouter_reasoning_details": openRouterReasoningDetails
                                ]
                            }
                            calls.append(
                                ToolCallInfo(
                                    id: id,
                                    name: value.name,
                                    arguments: args,
                                    metadata: metadata
                                )
                            )
                        }
                        let event = ChatStreamEvent.toolCalls(calls)
                        wireProbe.emitted(event)
                        continuation.yield(event)
                    }
                    wireProbe.finish(reason: "eof")
                    continuation.finish()
                } catch is CancellationError {
                    wireProbe.finish(reason: "cancelled")
                    continuation.finish()
                } catch {
                    wireProbe.finish(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func claudeStreamWithTools(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let traceContext = StreamWireTraceContext(options: options, route: .claudeMessagesTools)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var wireProbe = StreamWireProbe(context: traceContext)
                wireProbe.begin()
                do {
                    let apiKey = normalizedAPIKey(for: provider)
                    guard let url = endpoint(baseURL: provider.baseURL, path: "/messages") else {
                        throw AIChatServiceError.invalidURL
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let thinkingBudget = options.thinkingBudget ?? 0
                    let thinkingEnabled = thinkingBudget != 0
                    let claudeBudget = thinkingBudget > 0 ? thinkingBudget : 4096
                    var maxTokens = options.maxTokens ?? 4096
                    if thinkingEnabled { maxTokens = max(maxTokens, claudeBudget + 1024) }

                    let wireMessages: [[String: Any]] = messages.map { message in
                        let role = message.role == "assistant" ? "assistant" : "user"
                        if let blocks = message.contentBlocks, !blocks.isEmpty {
                            return ["role": role, "content": blocks]
                        }
                        guard !message.images.isEmpty else {
                            return ["role": role, "content": message.content]
                        }
                        var parts: [[String: Any]] = message.images.map { image in
                            ["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": image.base64Data]]
                        }
                        if !message.content.isEmpty {
                            parts.append(["type": "text", "text": message.content])
                        }
                        return ["role": role, "content": parts]
                    }

                    var body: [String: Any] = [
                        "model": modelID,
                        "messages": wireMessages,
                        "max_tokens": maxTokens,
                        "stream": true
                    ]
                    if let systemPrompt = options.systemPrompt { body["system"] = systemPrompt }
                    if thinkingEnabled {
                        body["thinking"] = ["type": "enabled", "budget_tokens": claudeBudget]
                    } else {
                        if let temperature = options.temperature { body["temperature"] = temperature }
                        if let topP = options.topP { body["top_p"] = topP }
                    }
                    var allClaudeTools: [[String: Any]] = []
                    if let tools = options.tools, !tools.isEmpty {
                        let claudeTools: [[String: Any]] = tools.compactMap { tool in
                            guard let fn = tool["function"] as? [String: Any] else { return nil }
                            var ct: [String: Any] = ["name": fn["name"] ?? ""]
                            if let desc = fn["description"] { ct["description"] = desc }
                            if let params = fn["parameters"] { ct["input_schema"] = params }
                            return ct
                        }
                        allClaudeTools.append(contentsOf: claudeTools)
                    }
                    if !allClaudeTools.isEmpty { body["tools"] = allClaudeTools }
                    applyCustomHeaders(provider, modelID: modelID, to: &request)
                    applyClaudePromptCaching(provider, modelID: modelID, into: &body)
                    mergeCustomBody(provider, modelID: modelID, into: &body)
                    try applyBuiltInSearch(provider, modelID: modelID, enabled: options.builtInSearch, into: &body)
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: body,
                        options: [.sortedKeys]
                    )

                    let (bytes, response) = try await makeSession(for: provider).bytes(for: request)
                    wireProbe.receivedHeaders(response)
                    try await validateStreamingResponse(response, bytes: bytes)

                    var currentBlockType: String?
                    var currentToolID = ""
                    var currentToolName = ""
                    var currentToolArgsBuffer = ""
                    var pendingToolCalls: [ToolCallInfo] = []

                    var searchCitations = NativeSearchCitations()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        wireProbe.receivedDataLine(payloadUTF8Count: payload.utf8.count)
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        let eventType = object["type"] as? String ?? ""

                        if let delta = object["delta"] as? [String: Any],
                           delta["type"] as? String == "citations_delta",
                           let citation = delta["citation"] as? [String: Any],
                           let links = searchCitations.annotations([citation]) {
                            continuation.yield(.text(links))
                        }
                        switch eventType {
                        case "error":
                            let error = object["error"] as? [String: Any] ?? [:]
                            throw AIChatServiceError.providerStreamError(error["message"] as? String ?? ErrorLocalization.lookup("服务商中断了回复"))
                        case "message_start":
                            if let message = object["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any] {
                                let event = ChatStreamEvent.usage(StreamUsage(
                                    promptTokens: usage["input_tokens"] as? Int,
                                    completionTokens: usage["output_tokens"] as? Int
                                ))
                                wireProbe.emitted(event)
                                continuation.yield(event)
                            }
                        case "message_delta":
                            if let usage = object["usage"] as? [String: Any] {
                                let event = ChatStreamEvent.usage(StreamUsage(
                                    promptTokens: nil,
                                    completionTokens: usage["output_tokens"] as? Int
                                ))
                                wireProbe.emitted(event)
                                continuation.yield(event)
                            }
                        case "content_block_start":
                            if let block = object["content_block"] as? [String: Any] {
                                let blockType = block["type"] as? String ?? ""
                                currentBlockType = blockType
                                if blockType == "tool_use" {
                                    currentToolID = block["id"] as? String ?? ""
                                    currentToolName = block["name"] as? String ?? ""
                                    currentToolArgsBuffer = ""
                                }
                            }
                        case "content_block_delta":
                            if let delta = object["delta"] as? [String: Any] {
                                let deltaType = delta["type"] as? String ?? ""
                                switch deltaType {
                                case "text_delta":
                                    if let text = delta["text"] as? String, !text.isEmpty {
                                        let event = ChatStreamEvent.text(text)
                                        wireProbe.emitted(event)
                                        continuation.yield(event)
                                    }
                                case "thinking_delta":
                                    if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                                        let event = ChatStreamEvent.reasoning(thinking)
                                        wireProbe.emitted(event)
                                        continuation.yield(event)
                                    }
                                case "input_json_delta":
                                    if let partial = delta["partial_json"] as? String {
                                        currentToolArgsBuffer += partial
                                    }
                                default:
                                    break
                                }
                            }
                        case "content_block_stop":
                            if currentBlockType == "tool_use" && !currentToolID.isEmpty {
                                let args: [String: Any]
                                if let data = currentToolArgsBuffer.data(using: .utf8),
                                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    args = parsed
                                } else {
                                    args = [:]
                                }
                                pendingToolCalls.append(ToolCallInfo(id: currentToolID, name: currentToolName, arguments: args))
                            }
                            currentBlockType = nil
                        default:
                            break
                        }
                    }

                    if !pendingToolCalls.isEmpty {
                        let event = ChatStreamEvent.toolCalls(pendingToolCalls)
                        wireProbe.emitted(event)
                        continuation.yield(event)
                    }
                    wireProbe.finish(reason: "eof")
                    continuation.finish()
                } catch is CancellationError {
                    wireProbe.finish(reason: "cancelled")
                    continuation.finish()
                } catch {
                    wireProbe.finish(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func googleStreamWithTools(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let traceContext = StreamWireTraceContext(options: options, route: .googleGenerateTools)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var wireProbe = StreamWireProbe(context: traceContext)
                wireProbe.begin()
                do {
                    let apiKey = normalizedAPIKey(for: provider)
                    let cleanedModelID = modelID.replacingOccurrences(of: "models/", with: "")
                    let encodedModelID = cleanedModelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanedModelID
                    let path = "/models/\(encodedModelID):streamGenerateContent"
                    guard let base = endpoint(baseURL: provider.baseURL, path: path),
                          var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
                        throw AIChatServiceError.invalidURL
                    }
                    components.queryItems = [
                        URLQueryItem(name: "alt", value: "sse"),
                        URLQueryItem(name: "key", value: apiKey)
                    ]
                    guard let url = components.url else { throw AIChatServiceError.invalidURL }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var body: [String: Any] = [
                        "contents": messages.map { message -> [String: Any] in
                            let role = message.role == "assistant" ? "model" : "user"
                            if let fcs = message.functionCalls, !fcs.isEmpty {
                                let parts: [[String: Any]] = fcs.map { name, args in
                                    ["functionCall": ["name": name, "args": args] as [String: Any]]
                                }
                                return ["role": "model", "parts": parts]
                            }
                            if let frs = message.functionResponses, !frs.isEmpty {
                                let parts: [[String: Any]] = frs.map { name, content in
                                    var responseDict: [String: Any] = ["name": name]
                                    if let data = content.data(using: .utf8),
                                       let parsed = try? JSONSerialization.jsonObject(with: data) {
                                        responseDict["response"] = parsed
                                    } else {
                                        responseDict["response"] = ["result": content]
                                    }
                                    return ["functionResponse": responseDict]
                                }
                                return ["role": "user", "parts": parts]
                            }
                            var parts: [[String: Any]] = []
                            if !message.content.isEmpty || message.images.isEmpty {
                                parts.append(["text": message.content])
                            }
                            for image in message.images {
                                parts.append(["inline_data": ["mime_type": image.mimeType, "data": image.base64Data]])
                            }
                            return ["role": role, "parts": parts]
                        }
                    ]
                    if let systemPrompt = options.systemPrompt {
                        body["systemInstruction"] = ["parts": [["text": systemPrompt]]]
                    }
                    var generationConfig: [String: Any] = [:]
                    if let temperature = options.temperature { generationConfig["temperature"] = temperature }
                    if let topP = options.topP { generationConfig["topP"] = topP }
                    if let maxTokens = options.maxTokens { generationConfig["maxOutputTokens"] = maxTokens }
                    if let thinkingBudget = options.thinkingBudget, thinkingBudget != 0 {
                        generationConfig["thinkingConfig"] = ["thinkingBudget": thinkingBudget, "includeThoughts": true]
                    }
                    if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }

                    var geminiToolsArray: [[String: Any]] = []
                    if let tools = options.tools, !tools.isEmpty {
                        let declarations: [[String: Any]] = tools.compactMap { tool in
                            guard let fn = tool["function"] as? [String: Any] else { return nil }
                            var decl: [String: Any] = ["name": fn["name"] ?? ""]
                            if let desc = fn["description"] { decl["description"] = desc }
                            if let params = fn["parameters"] { decl["parameters"] = params }
                            return decl
                        }
                        if !declarations.isEmpty {
                            geminiToolsArray.append(["functionDeclarations": declarations])
                        }
                    }
                    if !geminiToolsArray.isEmpty {
                        body["tools"] = geminiToolsArray
                    }
                    applyCustomHeaders(provider, modelID: modelID, to: &request)
                    mergeCustomBody(provider, modelID: modelID, into: &body)
                    try applyBuiltInSearch(provider, modelID: modelID, enabled: options.builtInSearch, into: &body)
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: body,
                        options: [.sortedKeys]
                    )

                    let (bytes, response) = try await makeSession(for: provider).bytes(for: request)
                    wireProbe.receivedHeaders(response)
                    try await validateStreamingResponse(response, bytes: bytes)

                    var pendingToolCalls: [ToolCallInfo] = []

                    var searchCitations = NativeSearchCitations()

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        wireProbe.receivedDataLine(payloadUTF8Count: payload.utf8.count)
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        let candidates = object["candidates"] as? [[String: Any]]
                        let content = candidates?.first?["content"] as? [String: Any]
                        if let parts = content?["parts"] as? [[String: Any]] {
                            for part in parts {
                                if let text = part["text"] as? String, !text.isEmpty {
                                    let event: ChatStreamEvent = part["thought"] as? Bool == true
                                        ? .reasoning(text)
                                        : .text(text)
                                    wireProbe.emitted(event)
                                    continuation.yield(event)
                                }
                                if let fc = part["functionCall"] as? [String: Any],
                                   let name = fc["name"] as? String {
                                    let args = fc["args"] as? [String: Any] ?? [:]
                                    let id = "gemini_\(UUID().uuidString.prefix(8))"
                                    pendingToolCalls.append(ToolCallInfo(id: id, name: name, arguments: args))
                                }
                            }
                        }
                        if let metadata = candidates?.first?["groundingMetadata"] as? [String: Any],
                           let links = searchCitations.grounding(metadata) {
                            continuation.yield(.text(links))
                        }
                        if let usage = object["usageMetadata"] as? [String: Any] {
                            let event = ChatStreamEvent.usage(StreamUsage(
                                promptTokens: usage["promptTokenCount"] as? Int,
                                completionTokens: usage["candidatesTokenCount"] as? Int,
                                totalTokens: usage["totalTokenCount"] as? Int
                            ))
                            wireProbe.emitted(event)
                            continuation.yield(event)
                        }
                    }

                    if !pendingToolCalls.isEmpty {
                        let event = ChatStreamEvent.toolCalls(pendingToolCalls)
                        wireProbe.emitted(event)
                        continuation.yield(event)
                    }
                    wireProbe.finish(reason: "eof")
                    continuation.finish()
                } catch is CancellationError {
                    wireProbe.finish(reason: "cancelled")
                    continuation.finish()
                } catch {
                    wireProbe.finish(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sseStream(
        provider: ProviderConfiguration,
        traceContext: StreamWireTraceContext?,
        receivesChatImages: Bool = false,
        request: Result<URLRequest, Error>,
        parse: @escaping @Sendable ([String: Any]) -> [ChatStreamEvent]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var wireProbe = StreamWireProbe(context: traceContext)
                wireProbe.begin()
                do {
                    let request = try request.get()
                    var imageDecoder = ChatImageStreamDecoder()
                    let (bytes, response) = try await makeSession(for: provider).bytes(for: request)
                    wireProbe.receivedHeaders(response)
                    try await validateStreamingResponse(response, bytes: bytes)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        wireProbe.receivedDataLine(payloadUTF8Count: payload.utf8.count)
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        let imageEvents = receivesChatImages ? try imageDecoder.events(from: object) : []
                        for event in parse(object) + imageEvents {
                            wireProbe.emitted(event)
                            continuation.yield(event)
                        }
                    }
                    wireProbe.finish(reason: "eof")
                    continuation.finish()
                } catch is CancellationError {
                    wireProbe.finish(reason: "cancelled")
                    continuation.finish()
                } catch {
                    wireProbe.finish(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 全局网络代理生效时走自定义 session。
    private static func makeSession(for provider: ProviderConfiguration) -> URLSession {
        let proxy = provider.proxy.isUsable
            ? ProxySettings(enabled: true, host: provider.proxy.host, port: provider.proxy.port)
            : AppPreferences.loadProxySettings()
        guard proxy.isUsable, let port = Int(proxy.port) else { return .shared }
        let host = proxy.host.trimmingCharacters(in: .whitespaces)
        let configuration = URLSessionConfiguration.default
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": true,
            "HTTPSProxy": host,
            "HTTPSPort": port
        ]
        return URLSession(configuration: configuration)
    }

    private static func normalizedAPIKey(for provider: ProviderConfiguration) -> String {
        if provider.multiKeyEnabled,
           let selected = provider.enabledAPIKeys.randomElement() {
            return selected.key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func applyBuiltInSearch(
        _ provider: ProviderConfiguration,
        modelID: String,
        enabled: Bool,
        into body: inout [String: Any]
    ) throws {
        guard enabled else { return }
        var tools = body["tools"] as? [[String: Any]] ?? []
        let searchTool: [String: Any]
        switch provider.type {
        case .claude:
            guard !tools.contains(where: { ($0["type"] as? String)?.hasPrefix("web_search_") == true }) else { return }
            searchTool = ["type": "web_search_20250305", "name": "web_search"]
        case .google:
            guard !tools.contains(where: { $0["google_search"] != nil || $0["googleSearch"] != nil }) else { return }
            searchTool = ["google_search": [String: Any]()]
        case .openAI:
            if provider.isOpenRouter {
                guard !tools.contains(where: { $0["type"] as? String == "openrouter:web_search" }) else { return }
                searchTool = ["type": "openrouter:web_search", "parameters": ["engine": "native"]]
            } else {
                guard usesOpenAIResponses(provider: provider, modelID: modelID, builtInSearch: true) else {
                    throw AIChatServiceError.unsupportedBuiltInSearch
                }
                guard !tools.contains(where: { ["web_search", "web_search_preview"].contains($0["type"] as? String ?? "") }) else { return }
                searchTool = ["type": "web_search"]
            }
        }
        tools.append(searchTool)
        body["tools"] = tools
    }

    private static func applyClaudePromptCaching(
        _ provider: ProviderConfiguration,
        modelID: String,
        into body: inout [String: Any]
    ) {
        guard provider.claudePromptCachingEnabled else { return }
        let normalizedModelID = modelID.lowercased()
        let isClaudeModel = normalizedModelID.contains("claude")
            || normalizedModelID.contains("anthropic/")
        guard provider.type == .claude || (provider.isOpenRouter && isClaudeModel) else { return }

        var cacheControl: [String: Any] = ["type": "ephemeral"]
        if provider.claudePromptCachingTTL == .oneHour {
            cacheControl["ttl"] = ProviderPromptCacheTTL.oneHour.rawValue
        }
        body["cache_control"] = cacheControl
    }

    private static func applyOpenRouterSession(
        _ provider: ProviderConfiguration,
        sessionID: String?,
        into body: inout [String: Any]
    ) {
        guard provider.isOpenRouter, body["session_id"] == nil else { return }
        let normalized = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return }
        body["session_id"] = String(normalized.prefix(256))
    }

    private static func applyOpenRouterReasoning(
        _ provider: ProviderConfiguration,
        thinkingBudget: Int?,
        usesResponsesAPI: Bool,
        into body: inout [String: Any]
    ) {
        guard provider.isOpenRouter,
              body["reasoning"] == nil,
              body["include_reasoning"] == nil,
              body["reasoning_effort"] == nil,
              let thinkingBudget,
              thinkingBudget != 0 else { return }

        if usesResponsesAPI {
            let effort: String
            switch thinkingBudget {
            case ..<0:
                effort = "medium"
            case ...1_024:
                effort = "minimal"
            case ...2_048:
                effort = "low"
            case ...8_192:
                effort = "medium"
            default:
                effort = "high"
            }
            body["reasoning"] = ["effort": effort]
        } else if thinkingBudget < 0 {
            body["reasoning"] = ["enabled": true, "exclude": false]
        } else {
            body["reasoning"] = ["max_tokens": thinkingBudget, "exclude": false]
        }
    }

    /// OpenRouter may stream plaintext via `reasoning`/`reasoning_content`, or
    /// normalized summary/text blocks via `reasoning_details`. Prefer the direct
    /// field when both are present so the same reasoning is not rendered twice.
    private static func visibleReasoningChunks(in delta: [String: Any]) -> [String] {
        if let direct = (delta["reasoning_content"] as? String)
            ?? (delta["reasoning"] as? String),
           !direct.isEmpty {
            return [direct]
        }

        guard let details = delta["reasoning_details"] as? [[String: Any]] else {
            return []
        }
        return details.compactMap { detail in
            switch detail["type"] as? String {
            case "reasoning.summary":
                return detail["summary"] as? String
            case "reasoning.text":
                return detail["text"] as? String
            default:
                return nil
            }
        }.filter { !$0.isEmpty }
    }

    private static func cachedPromptTokens(in usage: [String: Any]) -> Int? {
        let details = (usage["prompt_tokens_details"] as? [String: Any])
            ?? (usage["input_tokens_details"] as? [String: Any])
        return integerValue(details?["cached_tokens"])
            ?? integerValue(usage["cache_read_input_tokens"])
            ?? integerValue(usage["cachedContentTokenCount"])
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func jsonValue(at path: String, in root: Any) -> Any? {
        path.split(separator: ".").reduce(Optional(root)) { current, component in
            guard let current else { return nil }
            if let dictionary = current as? [String: Any] {
                return dictionary[String(component)]
            }
            if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                return array[index]
            }
            return nil
        }
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func formatDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }

    private static func applyCustomHeaders(
        _ provider: ProviderConfiguration,
        modelID: String? = nil,
        to request: inout URLRequest
    ) {
        let modelFields = modelID.flatMap { id in
            provider.models.first(where: { $0.id == id })?.customHeaders
        } ?? []
        for field in provider.customHeaders + modelFields {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func mergeCustomBody(
        _ provider: ProviderConfiguration,
        modelID: String? = nil,
        into body: inout [String: Any]
    ) {
        let modelFields = modelID.flatMap { id in
            provider.models.first(where: { $0.id == id })?.customBody
        } ?? []
        for field in provider.customBody + modelFields {
            let key = field.name.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let data = field.value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                body[key] = parsed
            } else {
                body[key] = field.value
            }
        }
    }

    private static func endpoint(baseURL: String, path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + suffix)
    }

    private static func validate(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIChatServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AIChatServiceError.httpStatus(http.statusCode, responseDetail(from: body))
        }
    }

    private static func validateStreamingResponse(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIChatServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                if !body.isEmpty { body += "\n" }
                body += line
                if body.count >= 2_000 { break }
            }
            throw AIChatServiceError.httpStatus(http.statusCode, responseDetail(from: body))
        }
    }

    private static func responseDetail(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        return responseDetail(from: String(data: data, encoding: .utf8))
    }

    private static func responseDetail(from text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(500))
    }

    private static func tryResult<T>(_ operation: () throws -> T) -> Result<T, Error> {
        Result { try operation() }
    }
}

@MainActor
final class OCRService {
    static let shared = OCRService()

    private let maxCacheEntries = 48
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []

    func text(
        for attachments: [MessageAttachment],
        provider: ProviderConfiguration,
        modelID: String,
        prompt: String
    ) async -> String? {
        let images = attachments.filter { $0.kind == .image && $0.localURL != nil }
        guard !images.isEmpty else { return nil }

        var collected: [String] = []
        for attachment in images {
            guard let url = attachment.localURL else { continue }
            let key = url.path
            if let cached = cachedText(for: key) {
                collected.append(cached)
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            let image = ChatRequestImage(
                mimeType: attachment.mimeType ?? "image/jpeg",
                base64Data: data.base64EncodedString()
            )
            guard let recognized = await recognize(
                image: image,
                provider: provider,
                modelID: modelID,
                prompt: prompt
            ) else { continue }
            cacheText(recognized, for: key)
            collected.append(recognized)
        }

        let combined = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func recognize(
        image: ChatRequestImage,
        provider: ProviderConfiguration,
        modelID: String,
        prompt: String
    ) async -> String? {
        var result = ""
        do {
            for try await event in AIChatService.streamReply(
                provider: provider,
                modelID: modelID,
                messages: [
                    ChatRequestMessage(
                        role: "user",
                        content: "Process the attached image using the recognition instructions. Return the result without introductory remarks.",
                        images: [image]
                    )
                ],
                options: ChatRequestOptions(systemPrompt: prompt, temperature: 0)
            ) {
                if case .text(let chunk) = event {
                    result += chunk
                }
            }
        } catch {
            return nil
        }
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cachedText(for key: String) -> String? {
        guard let value = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return value
    }

    private func cacheText(_ text: String, for key: String) {
        cache[key] = text
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
