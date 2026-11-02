import Foundation
import ImageIO

@MainActor @main struct OpenRouterImagesChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard value() else { fatalError("FAIL: \(label)") }
    }
    struct Reply: Sendable {
        var images: [Data] = []
        var progress = 0
        var text = ""
        var usage: StreamUsage?
    }
    static func collect(_ provider: ProviderConfiguration, _ id: String, tools: Bool = false,
                        messages: [ChatRequestMessage] = [.init(role: "user", content: "a kitten")],
                        options: ChatRequestOptions = ChatRequestOptions()) async throws -> Reply {
        let stream = tools
            ? AIChatService.streamReplyWithTools(provider: provider, modelID: id, messages: messages,
                options: options, toolHandler: { _, _, _ in fatalError("Image model must not execute chat tools") })
            : AIChatService.streamReply(provider: provider, modelID: id, messages: messages, options: options)
        var reply = Reply()
        for try await event in stream {
            switch event {
            case .generatedImage(let data, let mime):
                check(event.deliversImmediately && event.containsReplyContent, "image bypasses buffered text")
                check(mime == "image/png", "MIME preserved")
                check(CGImageSourceCreateWithData(data as CFData, nil) != nil, "image bytes decode")
                let saved = AttachmentStore.saveGeneratedImage(data: data, mimeType: mime)
                check(saved != nil, "production attachment save accepts image")
                check((try? Data(contentsOf: saved!.localURL!)) == data, "saved image bytes retained")
                reply.images.append(data)
            case .imageGenerationProgress:
                check(reply.images.isEmpty, "progress precedes image")
                reply.progress += 1
            case .usage(let usage): reply.usage = usage
            case .text(let value): reply.text += value
            default: break
            }
        }
        return reply
    }
    static func main() async throws {
        let base = "http://127.0.0.1:\(CommandLine.arguments[1])"
        let id = "openai/gpt-image-2"
        func provider(_ models: [ModelConfiguration] = [], scenario: String = "default") -> ProviderConfiguration {
            ProviderConfiguration(id: UUID(), enabled: true, name: "Synthetic OpenRouter", type: .openAI,
                apiKey: "synthetic-key", baseURL: base, chatPath: "/chat/completions", models: models,
                brandIcon: .openRouter, customHeaders: [.init(name: "X-Scenario", value: scenario)])
        }

        let legacy = try JSONDecoder().decode(ModelConfiguration.self, from: Data("{\"id\":\"openai/gpt-image-2\"}".utf8))
        check(legacy.supportedEndpoints == nil, "legacy model configuration decodes")
        let catalog = try await AIChatService.fetchModels(for: provider())
        check(catalog.first { $0.id == id }?.supportedEndpoints == ["/api/v1/images"], "catalog endpoints retained")
        let roundtrip = try JSONDecoder().decode([ModelConfiguration].self, from: JSONEncoder().encode(catalog))
        check(roundtrip == catalog, "protocol metadata survives persistence")
        var customized = legacy
        customized.displayName = "My image model"
        customized.customBody = [.init(name: "quality", value: "low")]
        let merged = CatalogMerge.merging(existing: customized, fetched: catalog.first { $0.id == id }!)
        check(merged.supportedEndpoints == ["/api/v1/images"], "refresh updates endpoint metadata")
        check(merged.displayName == customized.displayName && merged.customBody == customized.customBody, "refresh preserves user edits")

        let imageProvider = provider(catalog)
        let textModel = ModelConfiguration(id: "openai/gpt-5")
        let resolver = TextModelResolver(contexts: [
            id: .init(provider: imageProvider, model: legacy),
            textModel.id: .init(provider: imageProvider, model: textModel)
        ])
        let imageSelection = ModelSelection(providerID: imageProvider.id, modelID: id)
        let textSelection = ModelSelection(providerID: imageProvider.id, modelID: textModel.id)
        check(resolver.firstResolvedChatModel(imageSelection, textSelection)?.model.id == textModel.id,
              "title and summary selection skips image models and falls back to text")
        check(resolver.firstResolvedChatModel(imageSelection) == nil, "no text fallback means no automatic image call")
        do {
            _ = try await AIChatService.generateText(provider: imageProvider, modelID: id,
                prompt: "text-only task must not generate an image")
            fatalError("Text-only tasks must not trigger billed image generation")
        } catch AIChatServiceError.textOutputUnsupported { check(true, "text-only generation rejected locally") }
        let generatedText = try await AIChatService.generateText(provider: provider(scenario: "text"),
            modelID: textModel.id, prompt: "text title")
        check(generatedText == "text reply", "ordinary text generation remains functional")

        for tools in [false, true] {
            for models in [[ModelConfiguration](), [legacy], catalog] {
                var p = provider(models)
                // The separate assistant image switch and global Responses setting
                // cannot redirect a directly selected Images-only model into chat.
                p.imageGenerationMode = .disabled
                p.useResponsesAPI = true
                let reply = try await collect(p, id, tools: tools, options: .init(builtInSearch: true))
                check(reply.images.count == 1 && reply.progress == 1, "GPT Image direct generation")
                check(reply.usage?.totalTokens == 227 && reply.usage?.completionTokens == 196, "image token usage retained")
            }
            let pure = ModelConfiguration(id: "fixture/legacy-pure", capabilityOverride:
                ModelCapabilities(kind: .chat, input: [.text], output: [.image], abilities: []))
            let pureReply = try await collect(provider([pure]), pure.id, tools: tools)
            check(pureReply.progress == 1, "legacy image-only metadata fallback")
            let fromCatalog = try await collect(provider(catalog), "fixture/catalog-image", tools: tools)
            check(fromCatalog.progress == 1, "endpoint metadata takes precedence over text+image capability")

            for chatID in ["fixture/chat-image", "openai/gpt-5-image", "google/gemini-2.5-flash-image"] {
                let reply = try await collect(provider(catalog), chatID, tools: tools)
                check(reply.images.count == 1 && reply.progress == 0, "existing chat images retain their route: \(chatID)")
            }
            let text = try await collect(provider(scenario: "text"), "openai/gpt-5", tools: tools)
            check(text.text == "text reply" && text.images.isEmpty && text.progress == 0, "text-only chat preserved")

            var otherProvider = provider()
            otherProvider.brandIcon = .openAI
            let other = try await collect(otherProvider, id, tools: tools)
            check(other.progress == 0, "other providers are not silently rerouted")

            var responsesProvider = provider([.init(id: "openai/gpt-5", builtInTools: [.imageGeneration])])
            responsesProvider.brandIcon = .openAI
            responsesProvider.useResponsesAPI = true
            let responses = try await collect(responsesProvider, "openai/gpt-5", tools: tools)
            check(responses.images.count == 1 && responses.progress > 0, "Responses built-in image tool preserved")
        }

        var customModel = legacy
        customModel.customHeaders = [.init(name: "X-Image-Test", value: "model-value")]
        customModel.customBody = [.init(name: "quality", value: "low"), .init(name: "n", value: "2")]
        var custom = provider([customModel], scenario: "custom")
        custom.customHeaders.append(.init(name: "X-Image-Test", value: "provider-value"))
        custom.customBody = [.init(name: "quality", value: "high"), .init(name: "provider", value: "{\"only\":[\"openai\"]}"),
            .init(name: "stream", value: "true"), .init(name: "modalities", value: "[\"image\"]"),
            .init(name: "messages", value: "[]"), .init(name: "temperature", value: "0.7"), .init(name: "max_tokens", value: "500")]
        let image = ChatRequestImage(mimeType: "image/png", base64Data: "AQID")
        let second = ChatRequestImage(mimeType: "image/jpeg", base64Data: "BAUG")
        let messages: [ChatRequestMessage] = [
            .init(role: "user", content: "blue kitten", images: [image]),
            .init(role: "assistant", content: "previous description", images: [image]),
            .init(role: "tool", content: "tool output ignored"),
            .init(role: "user", content: "white kitten", images: [second])
        ]
        let customReply = try await collect(custom, id, tools: true, messages: messages, options: .init(systemPrompt: "watercolor"))
        check(customReply.images.count == 2, "multiple images delivered")

        let external = try await ExternalImageGenerationService.generate(provider: provider(), modelID: id, prompt: "external assistant image")
        check(external.count == 1 && external[0].data.count == 68, "separate assistant image service preserved")
        OCRService.shared.clearCache()
        let ocrInput = ChatRequestImage(mimeType: "image/png", base64Data: external[0].data.base64EncodedString())
        do {
            _ = try await OCRService.shared.text(image: ocrInput, provider: imageProvider, modelID: id, prompt: "Read text")
            fatalError("OCR must not generate an image")
        } catch AIChatServiceError.textOutputUnsupported { check(true, "OCR does not generate a paid image") }
        let ordinaryOCR = try await OCRService.shared.text(image: ocrInput, provider: provider(scenario: "text"), modelID: "openai/gpt-5", prompt: "Read text")
        check(ordinaryOCR == "text reply", "ordinary OCR still reads text")

        for scenario in ["quota", "server-error", "empty", "usage-only", "invalid-base64", "empty-base64"] {
            for tools in [false, true] {
                do {
                    _ = try await collect(provider(scenario: scenario), id, tools: tools)
                    fatalError("Expected failure for \(scenario)")
                } catch let error as AIChatServiceError {
                    if scenario == "quota" {
                        if case .httpStatus(403, let detail) = error {
                            check(detail?.contains("fixture key limit") == true, "provider quota error survives")
                        } else { fatalError("Expected HTTP 403") }
                    }
                    check(true, "invalid image response fails: \(scenario)")
                }
            }
        }
        var missingKey = provider()
        missingKey.apiKey = " "
        do {
            _ = try await collect(missingKey, id)
            fatalError("Missing key should fail")
        } catch AIChatServiceError.missingAPIKey { check(true, "missing key rejected") }

        let cancelProvider = provider(scenario: "cancel")
        let task = Task { try await collect(cancelProvider, id) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            let reply = try await task.value
            check(reply.images.isEmpty, "cancelled request publishes no image")
        } catch {
            check(error is CancellationError || (error as? URLError)?.code == .cancelled, "cancellation propagates")
        }
        let replay = try await collect(provider(scenario: "decoded-image"), id)
        check(replay.images.count == 1, "synthetic API image decodes and persists")
        print("PASS: \(checks) assertions; dedicated Images, legacy models, catalog persistence, chat/Responses regressions, errors, cancellation, and attachment saving")
    }
}
