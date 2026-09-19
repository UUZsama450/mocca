import Foundation

@main struct NativeImageReplyChecks {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(label)") }
    }

    static func main() async throws {
        let base = "http://127.0.0.1:\(CommandLine.arguments[1])"
        let scenarios = ["image", "text", "mixed", "large", "duplicate", "multiple", "usage", "corrupt", "malformed", "remote", "error"]
        for withTools in [false, true] {
            for streamOutput in [false, true] {
                for scenario in scenarios {
                    try await run(scenario, base: base, withTools: withTools, streamOutput: streamOutput)
                }
                try await run("responses", base: base, withTools: withTools, streamOutput: streamOutput)
                try await run("image", base: base, withTools: withTools, streamOutput: streamOutput, failSave: true)
            }
        }
        try await run("tool", base: base, withTools: true, streamOutput: true)

        // Capability alone must not create image progress. Real provider
        // progress must still arrive before the resulting image.
        for withTools in [false, true] {
            for scenario in ["text", "image", "responses"] {
                let modelID = "fixture-image/\(scenario)"
                let provider = makeProvider(modelID, base: base, responses: scenario == "responses")
                let messages = [ChatRequestMessage(role: "user", content: "hello")]
                let options = ChatRequestOptions(tools: withTools ? [["type": "function", "function": ["name": "fixture", "parameters": ["type": "object"]]]] : nil)
                let stream = withTools
                    ? AIChatService.streamReplyWithTools(provider: provider, modelID: modelID, messages: messages, options: options, toolHandler: { _, _, _ in "fixture result" })
                    : AIChatService.streamReply(provider: provider, modelID: modelID, messages: messages, options: options)
                var stages: [String] = []
                var receivedText = false
                var receivedImage = false
                for try await event in stream {
                    switch event {
                    case .imageGenerationProgress(let stage):
                        check(!receivedImage, "progress precedes image")
                        stages.append(stage)
                    case .generatedImage: receivedImage = true
                    case .text(let text): receivedText = receivedText || !text.isEmpty
                    default: break
                    }
                }
                check(receivedImage == (scenario != "text"), "image delivery retained")
                if scenario == "text" { check(receivedText, "image-capable model can answer with text") }
                if scenario == "responses" {
                    check(!stages.isEmpty && stages.allSatisfy { $0 == "正在生成图片" }, "explicit image progress retained")
                } else {
                    check(stages.isEmpty, "image capability must not imply image generation")
                }
            }
        }

        // Real production routing must not add image waiting to text-only models.
        var provider = makeProvider("plain/text", base: base)
        var events: [ChatStreamEvent] = []
        for try await event in AIChatService.streamReply(provider: provider, modelID: "plain/text", messages: [.init(role: "user", content: "hello")]) { events.append(event) }
        check(!events.contains { if case .imageGenerationProgress = $0 { return true }; return false }, "text model has no image activity")
        check(events.contains { if case .text("你好，示例") = $0 { return true }; return false }, "text control survives")

        // Custom modalities are preserved by the real request builder.
        provider = makeProvider("custom-image/text", base: base)
        provider.customBody = [KeyValueField(name: "modalities", value: "[\"text\"]")]
        for try await _ in AIChatService.streamReply(provider: provider, modelID: "custom-image/text", messages: [.init(role: "user", content: "hello")]) {}

        let host = MessageHost(), conversationID = UUID()
        let message = ChatMessage()
        host.activeStreamingMessageIDsByConversation[conversationID] = message.id
        host.messagesByConversation[conversationID] = [message]
        let cancellationStream = AsyncThrowingStream<ChatStreamEvent, Error> { continuation in
            continuation.yield(.imageGenerationProgress("等待图文回复"))
            continuation.finish(throwing: CancellationError())
        }
        do {
            try await host.consume(cancellationStream, conversationID: conversationID, assistantMessage: message, assistant: .init(id: message.id, streamOutput: false))
            fatalError("cancellation must propagate")
        } catch is CancellationError {}
        var cancelled = host.messagesByConversation[conversationID]![0]
        check(cancelled.toolEvents.count == 1, "progress delivered while text buffering disabled")
        NativeImageReplyPresentation.finish(&cancelled, failureDescription: "已停止图片回复")
        check(cancelled.toolEvents[0].status == .failed, "cancellation settles activity")
        check(cancelled.toolEvents[0].resultText == "已停止图片回复", "cancellation wording")

        var textOnly = ChatMessage()
        NativeImageReplyPresentation.update(&textOnly, stage: "等待图文回复")
        NativeImageReplyPresentation.finish(&textOnly, failureDescription: nil)
        check(textOnly.toolEvents.isEmpty, "text answer removes speculative image activity")
        var imageThenTool = ChatMessage()
        imageThenTool.attachments = [.init(id: UUID(), kind: .image, localURL: nil, fileName: "fixture.png", mimeType: "image/png", byteCount: 1, metadata: ["source": NativeImageReplyPresentation.source])]
        NativeImageReplyPresentation.update(&imageThenTool, stage: "图片已生成", completed: true)
        NativeImageReplyPresentation.update(&imageThenTool, stage: "等待图文回复")
        NativeImageReplyPresentation.finish(&imageThenTool, failureDescription: nil)
        check(imageThenTool.toolEvents.count == 1 && imageThenTool.toolEvents[0].status == .complete, "later tool round retains earlier image success")
        check(!ChatStreamEvent.usage(.init(promptTokens: 1903, completionTokens: 7062, totalTokens: 8965)).containsReplyContent, "usage is not reply content")
        check(!ChatStreamEvent.imageGenerationProgress("waiting").containsReplyContent, "progress is not reply content")
        check(!ChatStreamEvent.text(" \n").containsReplyContent, "whitespace is not reply content")
        check(ChatStreamEvent.generatedImage(Data([1]), mimeType: "image/png").deliversImmediately, "images bypass text buffering")

        // Nonstream-shaped final image objects are accepted by the same decoder.
        var decoder = ChatImageStreamDecoder()
        let object: [String: Any] = ["choices": [["message": ["content": NSNull(), "images": [["image_url": ["url": "data:image/webp;base64,AQID"]]]]]]]
        let decoded = try decoder.events(from: object)
        check(decoded.count == 1, "message.images fallback")
        if case .generatedImage(let data, let mime) = decoded[0] {
            check(data == Data([1, 2, 3]) && mime == "image/webp", "data and MIME retained")
        } else { fatalError("image event expected") }
        check(tryNoThrow { try decoder.events(from: object).isEmpty }, "final snapshot deduplicated")
        print("PASS: \(assertions) assertions; streamed image/text/progress cases plus custom controls, cancellation and decoder checks")
    }

    static func tryNoThrow(_ operation: () throws -> Bool) -> Bool { (try? operation()) ?? false }

    static func makeProvider(_ id: String, base: String, responses: Bool = false) -> ProviderConfiguration {
        ProviderConfiguration(id: UUID(), enabled: true, name: "Fixture", type: .openAI, apiKey: "synthetic-key", baseURL: base, chatPath: "/chat/completions", models: [.init(id: id, builtInTools: responses ? [.imageGeneration] : [])], brandIcon: responses ? .openAI : .openRouter, useResponsesAPI: responses)
    }

    static func run(_ scenario: String, base: String, withTools: Bool, streamOutput: Bool, failSave: Bool = false) async throws {
        let modelID = "fixture-image/\(scenario)"
        let provider = makeProvider(modelID, base: base, responses: scenario == "responses")
        let messages = [ChatRequestMessage(role: "user", content: "synthetic image request")]
        let options = ChatRequestOptions(tools: withTools ? [["type": "function", "function": ["name": "fixture", "parameters": ["type": "object"]]]] : nil)
        let stream = withTools
            ? AIChatService.streamReplyWithTools(provider: provider, modelID: modelID, messages: messages, options: options, toolHandler: { _, _, _ in "fixture result" })
            : AIChatService.streamReply(provider: provider, modelID: modelID, messages: messages, options: options)
        let host = MessageHost(), conversationID = UUID(), message = ChatMessage()
        host.activeStreamingMessageIDsByConversation[conversationID] = message.id
        host.messagesByConversation[conversationID] = [message]
        AttachmentStore.failWrites = failSave
        defer { AttachmentStore.failWrites = false }
        var error: Error?
        do {
            try await host.consume(stream, conversationID: conversationID, assistantMessage: message, assistant: .init(id: message.id, streamOutput: streamOutput))
        } catch let caught { error = caught }
        let shouldFail = failSave || ["usage", "corrupt", "malformed", "remote", "error"].contains(scenario)
        let label = "\(scenario) tools=\(withTools) stream=\(streamOutput) saveFailure=\(failSave)"
        check((error != nil) == shouldFail, "error contract \(label): \(String(describing: error))")
        var result = host.messagesByConversation[conversationID]![0]
        NativeImageReplyPresentation.finish(&result, failureDescription: error?.localizedDescription)
        let expectedImages = shouldFail || scenario == "text" ? 0 : (scenario == "multiple" ? 3 : 1)
        check(result.attachments.count == expectedImages, "attachment count \(label)")
        check(!result.toolEvents.contains { $0.status == .running || $0.status == .pending }, "activity settled \(label)")
        if expectedImages > 0 {
            check(result.toolEvents.last?.status == .complete, "image success visible \(label)")
            for attachment in result.attachments {
                let saved = try Data(contentsOf: attachment.localURL!)
                check(saved.count == attachment.byteCount && !saved.isEmpty, "persisted bytes \(label)")
                check(attachment.mimeType == "image/png", "persisted MIME \(label)")
                check(attachment.metadata["source"] == NativeImageReplyPresentation.source, "native attachment identity \(label)")
            }
        }
        if ["text", "mixed"].contains(scenario) {
            check(!(host.rawStreamingTextByMessageID[message.id] ?? "").isEmpty, "text retained \(label)")
        }
        if scenario == "usage" { check(error is AIChatServiceError, "usage-only fails clearly") }
    }
}
