@preconcurrency import ActivityKit
import BackgroundTasks
import Foundation
import Intents
import UIKit
import UserNotifications

struct ExternalImageModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var supportsReferenceImages: Bool? = nil
    var maximumReferenceImages: Int? = nil
}

enum ExternalImageGenerationAPIStyle: Hashable, Sendable {
    case openRouter, openAICompatible, openAIJSON, chatCompletions, gemini
    var modelListPath: String { self == .openRouter ? "images/models" : "models" }
}

extension ProviderConfiguration {
    var externalImageGenerationAPIStyle: ExternalImageGenerationAPIStyle? {
        switch imageGenerationMode {
        case .automatic:
            if isOpenRouter { return .openRouter }
            if isOfficialOpenAI { return .openAIJSON }
            if type == .google { return .gemini }
            return nil
        case .disabled: return nil
        case .openAICompatible: return .openAICompatible
        case .openAIJSON: return .openAIJSON
        case .openRouter: return .openRouter
        case .chatCompletions: return .chatCompletions
        case .gemini: return .gemini
        }
    }
    var supportsExternalImageGeneration: Bool { externalImageGenerationAPIStyle != nil }

    func supportsAutomaticImageGeneration(modelID: String) -> Bool {
        if isOfficialOpenAI && OpenAIRequestPolicy.supportsImageTool(modelID) { return true }
        let model = models.first { $0.id == modelID } ?? ModelConfiguration(id: modelID)
        return model.capabilities.output.contains(.image)
            && (supportsExternalImageGeneration || type == .google || isOpenRouter)
    }
}

struct GeneratedImagePayload: Sendable {
    let data: Data
    let mimeType: String
}

enum ExternalImageGenerationError: LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case unsupportedProvider
    case invalidResponse
    case provider(String)
    case emptyImage
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: ErrorLocalization.lookup("图像生成地址无效")
        case .missingAPIKey: ErrorLocalization.lookup("图像供应商 API Key 为空")
        case .unsupportedProvider: ErrorLocalization.lookup("这个供应商暂不支持图像生成接口")
        case .invalidResponse: ErrorLocalization.lookup("图像服务返回了无法识别的数据")
        case .provider(let message): message
        case .emptyImage: ErrorLocalization.lookup("图像服务没有返回图片")
        case .timedOut(let detail): ErrorLocalization.format("图像生成请求超时（最长等待 300 秒；%@）", [String(describing: detail)])
        }
    }
}

enum ExternalImageGenerationService {
    static func transport(provider: ProviderConfiguration, modelID: String) throws -> ImageGenerationTransport {
        guard let style = provider.externalImageGenerationAPIStyle else { throw ExternalImageGenerationError.unsupportedProvider }
        switch style {
        case .openRouter: return .openRouter
        case .openAICompatible: return .openAIForm
        case .openAIJSON: return .openAIJSON
        case .chatCompletions: return .chatCompletions
        case .gemini:
            let id = modelID.lowercased().replacingOccurrences(of: "models/", with: "")
            if id.hasPrefix("imagen-") { throw ExternalImageGenerationError.provider(ErrorLocalization.lookup("当前 Gemini 生图接口不提供这个 Imagen 模型，请选择可用的 Gemini 图像模型。")) }
            if id.hasPrefix("gemini-nano-banana-") { return .geminiInteractions }
            return .geminiContent
        }
    }

    static func listModels(provider: ProviderConfiguration) async throws -> [ExternalImageModel] {
        guard let style = provider.externalImageGenerationAPIStyle else { throw ExternalImageGenerationError.unsupportedProvider }
        var request = URLRequest(url: try endpointURL(provider: provider, path: style.modelListPath))
        request.httpMethod = "GET"
        applyHeaders(provider: provider, modelID: nil, google: style == .gemini, to: &request)
        let (data, response) = try await session(for: provider).data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ExternalImageGenerationError.invalidResponse }
        let rows = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard var id = (row["id"] as? String) ?? (style == .gemini ? row["name"] as? String : nil), !id.isEmpty else { return nil }
            if style == .gemini, id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
            let lower = id.lowercased()
            if style == .gemini, lower.hasPrefix("imagen-") || (!lower.contains("image") && !lower.contains("banana")) { return nil }
            if provider.isOfficialOpenAI, !lower.contains("gpt-image"), !lower.contains("chatgpt-image"), !lower.hasPrefix("dall-e") { return nil }
            let name = ((row["displayName"] as? String) ?? (row["name"] as? String) ?? (row["display_name"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
            var referenceSupport: Bool?
            var maximum: Int?
            if let parameters = row["supported_parameters"] as? [String: Any] {
                referenceSupport = parameters["input_references"] != nil
                maximum = (parameters["input_references"] as? [String: Any])?["max"] as? Int
            } else if let parameters = row["supported_parameters"] as? [String] {
                referenceSupport = parameters.contains("input_references")
            } else if style == .gemini { referenceSupport = !lower.hasPrefix("imagen-") }
            else if lower.contains("gpt-image") || lower.contains("chatgpt-image") { referenceSupport = true; maximum = 16 }
            else if lower == "dall-e-3" { referenceSupport = false }
            return ExternalImageModel(id: id, name: name?.isEmpty == false ? name! : id,
                supportsReferenceImages: referenceSupport, maximumReferenceImages: maximum)
        }
    }

    static func makeRequest(provider: ProviderConfiguration, modelID: String, prompt: String,
                            references: [ImageGenerationReference] = []) throws -> URLRequest {
        try Task.checkCancellation()
        let route = try transport(provider: provider, modelID: modelID)
        if !references.isEmpty && modelID.lowercased() == "dall-e-3" { throw ImageGenerationProtocolError.unsupportedReferences }
        var extras: [String: Any] = [:]
        let modelFields = provider.models.first(where: { $0.id == modelID })?.customBody ?? []
        for field in provider.customBody + modelFields {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            extras[name] = field.value.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? field.value
        }
        let encoded = try ImageGenerationProtocol.encode(transport: route, model: modelID, prompt: prompt,
            references: references, extras: extras,
            chatPath: provider.chatPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/chat/completions" : provider.chatPath)
        var request = URLRequest(url: try endpointURL(provider: provider, path: encoded.path))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        let google = [.geminiContent, .geminiInteractions].contains(route)
        applyHeaders(provider: provider, modelID: modelID, google: google, to: &request)
        request.setValue(encoded.contentType, forHTTPHeaderField: "Content-Type")
        if route == .geminiInteractions { request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision") }
        request.httpBody = encoded.data
        try Task.checkCancellation()
        return request
    }

    static func generate(provider: ProviderConfiguration, modelID: String, prompt: String,
                         references: [ImageGenerationReference] = []) async throws -> [GeneratedImagePayload] {
        let worker = Task.detached(priority: .userInitiated) {
            try makeRequest(provider: provider, modelID: modelID, prompt: prompt, references: references)
        }
        let request = try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session(for: provider).data(for: request) }
        catch let error as URLError where error.code == .timedOut {
            throw ExternalImageGenerationError.timedOut("NSURLErrorDomain \(error.code.rawValue)：\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ExternalImageGenerationError.invalidResponse }
        return try await decodeImages(object, provider: provider)
    }

    static func decodeImages(_ object: [String: Any], provider: ProviderConfiguration) async throws -> [GeneratedImagePayload] {
        var rows = object["data"] as? [[String: Any]] ?? []
        for prediction in object["predictions"] as? [[String: Any]] ?? [] {
            rows.append(["b64_json": prediction["bytesBase64Encoded"] ?? "", "media_type": prediction["mimeType"] ?? "image/png"])
        }
        for candidate in object["candidates"] as? [[String: Any]] ?? [] {
            let content = candidate["content"] as? [String: Any] ?? [:]
            for part in content["parts"] as? [[String: Any]] ?? [] where part["thought"] as? Bool != true {
                if let image = (part["inlineData"] ?? part["inline_data"]) as? [String: Any] {
                    rows.append(["b64_json": image["data"] ?? "", "media_type": image["mimeType"] ?? image["mime_type"] ?? "image/png"])
                }
            }
        }
        var interactionImages = (object["steps"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "image" }
        if interactionImages.isEmpty {
            interactionImages = ((object["outputs"] ?? object["output"]) as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }
        }
        if interactionImages.isEmpty, let image = object["output_image"] as? [String: Any] { interactionImages.append(image) }
        for image in interactionImages {
            rows.append(["b64_json": image["data"] ?? "", "media_type": image["mime_type"] ?? "image/png"])
        }
        for choice in object["choices"] as? [[String: Any]] ?? [] {
            let message = choice["message"] as? [String: Any] ?? [:]
            let images = (message["images"] as? [[String: Any]] ?? []) + (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image_url" }
            for image in images {
                if let url = (image["image_url"] as? [String: Any])?["url"] as? String ?? image["image_url"] as? String ?? image["url"] as? String {
                    rows.append(url.hasPrefix("data:") ? ["b64_json": url] : ["url": url])
                }
            }
        }
        var images: [GeneratedImagePayload] = []
        let format = object["output_format"] as? String
        let fallbackMIME = format == "jpeg" ? "image/jpeg" : (format == "webp" ? "image/webp" : "image/png")
        for row in rows {
            try Task.checkCancellation()
            if let encoded = row["b64_json"] as? String,
               let payload = decodeBase64Image(encoded, fallbackMIMEType: row["media_type"] as? String ?? fallbackMIME) {
                images.append(payload); continue
            }
            if let rawURL = row["url"] as? String, let url = URL(string: rawURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                let (remoteData, response) = try await session(for: provider).data(from: url)
                try Task.checkCancellation()
                try validate(response: response, data: remoteData)
                let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? fallbackMIME
                if !remoteData.isEmpty { images.append(GeneratedImagePayload(data: remoteData, mimeType: ImageGenerationProtocol.detectedMIME(remoteData) ?? mime)) }
            }
        }
        guard !images.isEmpty else {
            if let feedback = object["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                throw ExternalImageGenerationError.provider(ErrorLocalization.format("图像服务没有返回图片（%@）", [reason]))
            }
            throw ExternalImageGenerationError.emptyImage
        }
        return images
    }

    private static func decodeBase64Image(_ encoded: String, fallbackMIMEType: String?) -> GeneratedImagePayload? {
        if encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ",") {
            let header = String(encoded[..<comma])
            guard header.hasSuffix(";base64"), let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])), !data.isEmpty else { return nil }
            let mime = header.dropFirst(5).split(separator: ";").first.map(String.init) ?? "image/png"
            guard mime.hasPrefix("image/") else { return nil }
            return GeneratedImagePayload(data: data, mimeType: ImageGenerationProtocol.detectedMIME(data) ?? mime)
        }
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        return GeneratedImagePayload(data: data, mimeType: ImageGenerationProtocol.detectedMIME(data) ?? fallbackMIMEType ?? "image/png")
    }

    private static func endpointURL(provider: ProviderConfiguration, path: String) throws -> URL {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ExternalImageGenerationError.invalidEndpoint }
        return url
    }

    private static func applyHeaders(provider: ProviderConfiguration, modelID: String?, google: Bool, to request: inout URLRequest) {
        let key = (provider.multiKeyEnabled ? provider.enabledAPIKeys.randomElement()?.key : nil) ?? provider.apiKey
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { request.setValue(google ? normalized : "Bearer " + normalized, forHTTPHeaderField: google ? "x-goog-api-key" : "Authorization") }
        let modelHeaders = modelID.flatMap { id in provider.models.first(where: { $0.id == id })?.customHeaders } ?? []
        for field in provider.customHeaders + modelHeaders {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !["content-type", "content-length"].contains(name.lowercased()) else { continue }
            request.setValue(field.value, forHTTPHeaderField: name)
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ExternalImageGenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? object?["message"] as? String
                ?? ErrorLocalization.format("图像生成失败（HTTP %@）", [String(http.statusCode)])
            throw ExternalImageGenerationError.provider(message)
        }
    }

    private static func session(for provider: ProviderConfiguration) -> URLSession {
        let proxy = provider.proxy.isUsable ? ProxySettings(enabled: true, host: provider.proxy.host, port: provider.proxy.port) : AppPreferences.loadProxySettings()
        guard proxy.isUsable, let port = Int(proxy.port) else { return .shared }
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = ["HTTPEnable": true, "HTTPProxy": proxy.host.trimmingCharacters(in: .whitespacesAndNewlines), "HTTPPort": port,
            "HTTPSEnable": true, "HTTPSProxy": proxy.host.trimmingCharacters(in: .whitespacesAndNewlines), "HTTPSPort": port]
        return URLSession(configuration: config)
    }
}

struct IOSBackgroundGenerationSettings: Codable, Hashable, Sendable {
    var enabled = false
    var taskRecoveryEnabled = false
    var continuedProcessingEnabled = false
    var liveActivityEnabled = false
    var notificationsEnabled = false

    private enum CodingKeys: String, CodingKey {
        case enabled
        case taskRecoveryEnabled
        case continuedProcessingEnabled
        case liveActivityEnabled
        case notificationsEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        taskRecoveryEnabled = try container.decodeIfPresent(Bool.self, forKey: .taskRecoveryEnabled) ?? false
        continuedProcessingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .continuedProcessingEnabled
        ) ?? false
        liveActivityEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveActivityEnabled) ?? false
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(taskRecoveryEnabled, forKey: .taskRecoveryEnabled)
        try container.encode(continuedProcessingEnabled, forKey: .continuedProcessingEnabled)
        try container.encode(liveActivityEnabled, forKey: .liveActivityEnabled)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
    }
}

enum IOSBackgroundGenerationPersistence {
    private static let key = "ios_background_generation_settings_v1"

    static func load() -> IOSBackgroundGenerationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(IOSBackgroundGenerationSettings.self, from: data)
        else { return IOSBackgroundGenerationSettings() }
        return settings
    }

    static func save(_ settings: IOSBackgroundGenerationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
private protocol ContinuedGenerationLease: AnyObject {
    func recordProgress()
    func complete(success: Bool)
}

@available(iOS 26.0, *)
@MainActor
private final class IOS26ContinuedGenerationLease: ContinuedGenerationLease {
    private static let minimumProgressInterval: TimeInterval = 2

    private let task: BGContinuedProcessingTask
    private var progressUnits: Int64 = 0
    private var lastProgressUptime: TimeInterval?

    init(task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = -1
        task.progress.completedUnitCount = 0
    }

    func recordProgress() {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastProgressUptime,
           now - lastProgressUptime < Self.minimumProgressInterval {
            return
        }
        progressUnits = min(progressUnits + 1, Int64.max - 1)
        task.progress.completedUnitCount = progressUnits
        lastProgressUptime = now
    }

    func complete(success: Bool) {
        task.expirationHandler = nil
        if success {
            let finalUnits = max(progressUnits, 1)
            task.progress.totalUnitCount = finalUnits
            task.progress.completedUnitCount = finalUnits
        }
        task.setTaskCompleted(success: success)
    }
}

/// Captured when this reply starts, independently of the selected conversation.
/// Keep the small image bytes in memory so a later avatar edit or device lock
/// cannot change the sender of a reply that is already being generated.
struct AssistantNotificationSender: Sendable {
    let identifier: String
    let name: String
    let imageData: Data?

    @MainActor
    init(profile: AssistantProfile, accentColor: UIColor) {
        identifier = "mocca-assistant:\(profile.id.uuidString)"
        name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.lookup("助手") : profile.name
        imageData = Self.avatar(profile: profile, accentColor: accentColor).pngData()
    }

    @MainActor
    private static func avatar(profile: AssistantProfile, accentColor: UIColor) -> UIImage {
        let size: CGFloat = 128
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIBezierPath(ovalIn: rect).addClip()
            UIColor.systemBackground.setFill()
            context.fill(rect)
            if let image = AssistantMediaStore.image(for: profile.avatar)
                ?? profile.assetAvatarName.flatMap({ UIImage(named: $0) }),
               image.size.width > 0, image.size.height > 0 {
                let scale = max(size / image.size.width, size / image.size.height)
                let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (size - target.width) / 2, y: (size - target.height) / 2,
                                      width: target.width, height: target.height))
            } else {
                accentColor.withAlphaComponent(profile.emojiAvatar == nil ? 0.12 : 0.11).setFill()
                context.fill(rect)
                if let emoji = profile.emojiAvatar {
                    let text = emoji as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size * 0.5)]
                    let textSize = text.size(withAttributes: attributes)
                    text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                              withAttributes: attributes)
                } else {
                    UIImage(named: "DefaultAssistantAvatar")?
                        .withTintColor(accentColor, renderingMode: .alwaysOriginal)
                        .draw(in: rect.insetBy(dx: size * 0.16, dy: size * 0.16))
                }
            }
        }
    }
}

@MainActor
enum AssistantReplyNotification {
    static func intent(sender: AssistantNotificationSender, conversationID: UUID, body: String) -> INSendMessageIntent {
        let person = INPerson(
            personHandle: INPersonHandle(value: sender.identifier, type: .unknown),
            nameComponents: nil, displayName: sender.name,
            image: sender.imageData.map { INImage(imageData: $0) },
            contactIdentifier: nil, customIdentifier: sender.identifier
        )
        return INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: body,
            speakableGroupName: nil, conversationIdentifier: conversationID.uuidString,
            serviceName: nil, sender: person, attachments: nil
        )
    }

    static func content(sender: AssistantNotificationSender?, title: String, body: String,
                        conversationID: UUID, notificationID: UUID) async -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        guard let sender else { return content }
        let intent = intent(sender: sender, conversationID: conversationID, body: body)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = notificationID.uuidString
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            // Return the system-decorated content directly, without rebuilding
            // it and losing the communication avatar metadata.
            return try content.updating(from: intent)
        } catch {
            // Decoration is optional; it must never suppress the reply alert.
            return content
        }
    }
}

@MainActor
final class IOSBackgroundGenerationManager {
    static let shared = IOSBackgroundGenerationManager()
    static let refreshIdentifier = AppBuildConfiguration.backgroundTaskIdentifierPrefix + ".refresh"
    static let processingIdentifier = AppBuildConfiguration.backgroundTaskIdentifierPrefix + ".processing"
    static let continuedProcessingIdentifierPrefix =
        AppBuildConfiguration.backgroundTaskIdentifierPrefix + ".continued"

    struct SystemStatus: Sendable {
        let backgroundTaskActive: Bool
        let notificationsAuthorized: Bool
        let liveActivitiesEnabled: Bool
    }

    private struct Run {
        let assistantName: String
        let notificationSender: AssistantNotificationSender?
        let conversationID: UUID
        let detail: String
        var activityID: String?
        var completionWriter: PendingGenerationCompletionJournal.Writer?
        var journaledMessage: ChatMessage?
        var committedMessage: ChatMessage?
        var continuedProcessingIdentifier: String?
        var continuedGenerationLease: (any ContinuedGenerationLease)?
    }

    private var runs: [UUID: Run] = [:]
    private var pendingNotificationCount = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var checkpointProgress: (() -> Void)?

    private init() {}

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: .main) { task in
            task.setTaskCompleted(success: true)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingIdentifier, using: .main) { task in
            task.setTaskCompleted(success: true)
        }
    }

    func start(runID: UUID, assistant: AssistantProfile, accentColor: UIColor, conversationID: UUID) {
        let settings = IOSBackgroundGenerationPersistence.load()
        guard runs[runID] == nil else { return }
        var run = Run(
            assistantName: assistant.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L10n.lookup("助手")
                : assistant.name,
            notificationSender: settings.enabled && settings.notificationsEnabled
                ? AssistantNotificationSender(profile: assistant, accentColor: accentColor) : nil,
            conversationID: conversationID,
            detail: L10n.lookup("正在生成回复…"),
            activityID: nil,
            completionWriter: nil,
            journaledMessage: nil,
            committedMessage: nil,
            continuedProcessingIdentifier: nil,
            continuedGenerationLease: nil
        )
        do {
            run.completionWriter = try PendingGenerationCompletionJournal.makeDeferredWriter(
                runID: runID,
                conversationID: conversationID
            )
        } catch {
            NSLog(
                "[background-generation] pending journal open failed: %@",
                error.localizedDescription
            )
        }
        runs[runID] = run
        // Recovery records protect foreground streams too. Optional background
        // execution, live activities and notifications retain their own gate.
        guard settings.enabled else { return }
        beginBackgroundTaskIfNeeded()
        if settings.taskRecoveryEnabled { scheduleBackgroundTasks() }
        if settings.liveActivityEnabled { startLiveActivity(runID: runID) }
        if #available(iOS 26.0, *), settings.continuedProcessingEnabled {
            requestContinuedProcessing(runID: runID)
        }
    }

    func recordProgress(runID: UUID) {
        runs[runID]?.continuedGenerationLease?.recordProgress()
    }

    func stageCheckpointWithoutBlockingMain(runID: UUID, message: ChatMessage) async -> Bool {
        guard let run = runs[runID], message.id == runID,
              message.conversationID == run.conversationID,
              let writer = run.completionWriter else { return false }
        let result = await withCheckedContinuation { continuation in
            writer.enqueueCheckpoint(message) { continuation.resume(returning: $0) }
        }
        guard var current = runs[runID], current.completionWriter === writer else { return false }
        switch result {
        case .success:
            // Completion may have passed this suspended caller. Never replace
            // its durable terminal evidence with an older progress snapshot.
            if current.journaledMessage == nil
                || (current.journaledMessage?.status == .streaming
                    && (message.streamingRevision ?? 0) > (current.journaledMessage?.streamingRevision ?? 0)) {
                current.journaledMessage = message
                runs[runID] = current
            }
            return true
        case .failure(let error):
            NSLog("[generation-journal] checkpoint failed: %@", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func stageCompletedMessage(runID: UUID, message: ChatMessage) -> Bool {
        guard var run = runs[runID],
              message.id == runID,
              message.conversationID == run.conversationID else {
            return false
        }
        guard let writer = run.completionWriter else {
            return false
        }
        do {
            try writer.persistCompletedMessage(message)
            run.journaledMessage = message
            runs[runID] = run
            return true
        } catch {
            NSLog(
                "[background-generation] pending journal completion failed: %@",
                error.localizedDescription
            )
            return false
        }
    }

    func stageCompletedMessageWithoutBlockingMain(runID: UUID, message: ChatMessage) async -> Bool {
        guard let run = runs[runID], message.id == runID,
              message.conversationID == run.conversationID,
              let writer = run.completionWriter else { return false }
        let result = await withCheckedContinuation { continuation in
            writer.enqueueCompletedMessage(message) { result in
                continuation.resume(returning: result)
            }
        }
        // Cancellation/deletion may retire the run while its write completes.
        // Never restore an old Run value over newer activity/commit state.
        guard var current = runs[runID], current.completionWriter === writer else { return false }
        switch result {
        case .success:
            current.journaledMessage = message
            runs[runID] = current
            return true
        case .failure(let error):
            NSLog("[background-generation] pending journal completion failed: %@", error.localizedDescription)
            return false
        }
    }

    func markConversationStoreCommitted(runID: UUID, message: ChatMessage) {
        guard var run = runs[runID],
              message.id == runID,
              message.conversationID == run.conversationID else {
            return
        }
        run.committedMessage = message
        runs[runID] = run
    }

    func finish(
        runID: UUID,
        completedMessage: ChatMessage,
        notificationMessage: String
    ) {
        guard let run = runs.removeValue(forKey: runID) else { return }
        let settings = IOSBackgroundGenerationPersistence.load()
        let body = run.activityID != nil || (settings.enabled && settings.notificationsEnabled)
            ? Self.notificationText(notificationMessage, limit: 120) : ""
        let storeContainsFinalMessage =
            run.committedMessage == completedMessage
        let completionIsDurable =
            storeContainsFinalMessage
            || run.journaledMessage == completedMessage
        finalizePersistenceArtifacts(
            for: run,
            storeContainsFinalMessage: storeContainsFinalMessage
        )
        if completionIsDurable {
            finishLiveActivity(run: run, detail: body.isEmpty ? L10n.lookup("回复已完成") : body)
            if settings.enabled, settings.notificationsEnabled, !body.isEmpty {
                sendNotification(run: run, body: body)
            }
        } else {
            let warning = L10n.lookup("回复已生成，但尚未安全保存，请解锁后返回 App")
            finishLiveActivity(run: run, detail: warning)
            if settings.enabled, settings.notificationsEnabled {
                sendNotification(run: run, body: warning)
            }
        }
        completeContinuedProcessing(for: run, success: completionIsDurable)
        endBackgroundTaskIfIdle()
    }

    func fail(runID: UUID, partialMessage: String) {
        guard let run = runs.removeValue(forKey: runID) else { return }
        let settings = IOSBackgroundGenerationPersistence.load()
        let body = run.activityID != nil || (settings.enabled && settings.notificationsEnabled)
            ? Self.notificationText(partialMessage, limit: 120) : ""
        let completionIsDurable =
            run.journaledMessage.map { $0.status != .streaming } == true
            || run.committedMessage != nil
        finalizePersistenceArtifacts(
            for: run,
            storeContainsFinalMessage:
                run.committedMessage != nil
                && (
                    run.journaledMessage == nil
                    || run.journaledMessage == run.committedMessage
                )
        )
        if completionIsDurable {
            finishLiveActivity(run: run, detail: body.isEmpty ? L10n.lookup("回复已中断") : body)
            if settings.enabled, settings.notificationsEnabled {
                sendNotification(
                    run: run,
                    body: body.isEmpty ? L10n.lookup("回复已中断") : body
                )
            }
        } else {
            let warning = L10n.lookup("回复已中断，且未能安全保存，请解锁后返回 App")
            finishLiveActivity(run: run, detail: warning)
            if settings.enabled, settings.notificationsEnabled {
                sendNotification(run: run, body: warning)
            }
        }
        completeContinuedProcessing(for: run, success: false)
        endBackgroundTaskIfIdle()
    }

    func cancel(runID: UUID) {
        guard let run = runs.removeValue(forKey: runID) else { return }
        finalizePersistenceArtifacts(
            for: run,
            storeContainsFinalMessage: run.committedMessage != nil
                && run.committedMessage == run.journaledMessage
        )
        finishLiveActivity(run: run, detail: L10n.lookup("已停止生成"))
        completeContinuedProcessing(for: run, success: false)
        endBackgroundTaskIfIdle()
    }

    func abandonForStoreRecovery(runID: UUID) {
        guard let run = runs.removeValue(forKey: runID) else { return }
        run.completionWriter?.closeKeepingFile()
        finishLiveActivity(run: run, detail: L10n.lookup("回复已中断"))
        completeContinuedProcessing(for: run, success: false)
        endBackgroundTaskIfIdle()
    }

    func requestNotificationAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func systemStatus() async -> SystemStatus {
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        let notificationAuthorized = notificationSettings.authorizationStatus == .authorized
            || notificationSettings.authorizationStatus == .provisional
        let liveEnabled: Bool
        if #available(iOS 16.1, *) {
            liveEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        } else {
            liveEnabled = false
        }
        return SystemStatus(
            backgroundTaskActive: backgroundTask != .invalid,
            notificationsAuthorized: notificationAuthorized,
            liveActivitiesEnabled: liveEnabled
        )
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MoccaGeneration") { [weak self] in
            Task { @MainActor in
                self?.expireBackgroundTask()
            }
        }
    }

    private func expireBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        if !runs.isEmpty { checkpointProgress?() }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func endBackgroundTaskIfIdle() {
        guard runs.isEmpty, pendingNotificationCount == 0 else { return }
        expireBackgroundTask()
    }

    @available(iOS 26.0, *)
    private func requestContinuedProcessing(runID: UUID) {
        guard var run = runs[runID] else { return }
        let identifier = "\(Self.continuedProcessingIdentifierPrefix).\(runID.uuidString.lowercased())"
        run.continuedProcessingIdentifier = identifier
        runs[runID] = run

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated {
                guard let self else {
                    continuedTask.setTaskCompleted(success: false)
                    return
                }
                self.attachContinuedProcessingTask(
                    continuedTask,
                    runID: runID,
                    identifier: identifier
                )
            }
        }
        guard registered else {
            clearContinuedProcessingRequest(runID: runID, identifier: identifier)
            NSLog("[background-generation] continued task registration rejected: %@", identifier)
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: run.assistantName,
            subtitle: L10n.lookup("正在生成回复…")
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            clearContinuedProcessingRequest(runID: runID, identifier: identifier)
            NSLog(
                "[background-generation] continued task submission failed: %@",
                error.localizedDescription
            )
        }
    }

    @available(iOS 26.0, *)
    private func attachContinuedProcessingTask(
        _ task: BGContinuedProcessingTask,
        runID: UUID,
        identifier: String
    ) {
        guard var run = runs[runID],
              run.continuedProcessingIdentifier == identifier else {
            task.setTaskCompleted(success: true)
            return
        }
        let lease = IOS26ContinuedGenerationLease(task: task)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.continuedProcessingExpired(
                    runID: runID,
                    identifier: identifier
                )
            }
        }
        run.continuedGenerationLease = lease
        runs[runID] = run
        lease.recordProgress()
    }

    private func continuedProcessingExpired(runID: UUID, identifier: String) {
        guard var run = runs[runID],
              run.continuedProcessingIdentifier == identifier else { return }
        checkpointProgress?()
        run.continuedGenerationLease?.complete(success: false)
        run.continuedGenerationLease = nil
        run.continuedProcessingIdentifier = nil
        runs[runID] = run
        NSLog("[background-generation] continued task expired: %@", identifier)
    }

    private func clearContinuedProcessingRequest(runID: UUID, identifier: String) {
        guard var run = runs[runID],
              run.continuedProcessingIdentifier == identifier else { return }
        run.continuedProcessingIdentifier = nil
        run.continuedGenerationLease = nil
        runs[runID] = run
    }

    private func completeContinuedProcessing(for run: Run, success: Bool) {
        if let lease = run.continuedGenerationLease {
            lease.complete(success: success)
        } else if let identifier = run.continuedProcessingIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    private func finalizePersistenceArtifacts(
        for run: Run,
        storeContainsFinalMessage: Bool
    ) {
        guard let writer = run.completionWriter else { return }

        if storeContainsFinalMessage || !writer.containsRecoveryMessage {
            writer.closeAndRemoveFile()
        } else {
            // The journal contains a newer completion than the main
            // ConversationStore. Keep it encrypted on disk for unlock recovery.
            writer.closeKeepingFile()
        }
    }

    private func scheduleBackgroundTasks() {
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    private func sendNotification(run: Run, body: String) {
        let sender = run.notificationSender
        let title = run.assistantName
        let conversationID = run.conversationID
        let notificationID = UUID()
        pendingNotificationCount += 1
        beginBackgroundTaskIfNeeded()
        Task {
            defer {
                pendingNotificationCount -= 1
                endBackgroundTaskIfIdle()
            }
            let content = await AssistantReplyNotification.content(
                sender: sender, title: title, body: body,
                conversationID: conversationID, notificationID: notificationID
            )
            let request = UNNotificationRequest(identifier: notificationID.uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                NSLog("[background-generation] notification delivery failed: %@", error.localizedDescription)
            }
        }
    }

    private func startLiveActivity(runID: UUID) {
        guard #available(iOS 16.1, *),
              ActivityAuthorizationInfo().areActivitiesEnabled,
              var run = runs[runID] else { return }
        let state = MoccaGenerationActivityAttributes.ContentState(
            assistantName: run.assistantName,
            detail: run.detail,
            startedAt: .now,
            isFinished: false,
            languageCode: AppLocalization.shared.languageCode
        )
        do {
            let activity = try Activity.request(
                attributes: MoccaGenerationActivityAttributes(conversationID: run.conversationID.uuidString),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            run.activityID = activity.id
            runs[runID] = run
        } catch {
            // Live Activity is an optional continuity surface; the reply keeps running.
        }
    }

    private func finishLiveActivity(run: Run, detail: String) {
        guard #available(iOS 16.1, *), let activityID = run.activityID else { return }
        guard let activity = Activity<MoccaGenerationActivityAttributes>.activities.first(where: { $0.id == activityID })
        else { return }
        let state = MoccaGenerationActivityAttributes.ContentState(
            assistantName: run.assistantName,
            detail: detail,
            startedAt: activity.content.state.startedAt,
            isFinished: true,
            languageCode: AppLocalization.shared.languageCode
        )
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 60)),
                dismissalPolicy: .after(Date(timeIntervalSinceNow: 45))
            )
        }
    }

    private static func notificationText(_ text: String, limit: Int) -> String {
        var cleaned = ExternalImageGenerationCodec.parse(text).displayText
        cleaned = SearchImageSelectionCodec.stripForDisplay(cleaned)
        cleaned = cleaned.replacingOccurrences(of: #"[`*_>#~-]+"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(limit))
    }
}

final class MoccaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Retire only explicitly named files from past diagnostic builds.
        // No touch hooks, timers, observers, or new persistent cleanup marker.
        DispatchQueue.global(qos: .utility).async {
            _ = RetiredDiagnosticCleanup.run(container: URL(fileURLWithPath: NSHomeDirectory()), defaults: .standard)
        }
        IOSBackgroundGenerationManager.shared.registerBackgroundTasks()
        return true
    }
}
