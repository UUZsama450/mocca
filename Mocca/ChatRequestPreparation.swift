import Foundation

/// Builds provider messages from one send's value snapshot. UI state and stored
/// messages stay with AppModel; attachment IO runs on a cancellable worker.
@MainActor
enum ChatRequestPreparation {
    static func messages(
        from contextMessages: [ChatMessage],
        assistant: AssistantProfile,
        provider: ProviderConfiguration,
        preferences: UserPreferences,
        conversation: Conversation?,
        assistants: [AssistantProfile],
        ocrContext: (provider: ProviderConfiguration, modelID: String)?
    ) async throws -> [ChatRequestMessage] {
        let groupConversation = conversation.flatMap {
            $0.groupAssistantIDs.count >= 2 ? $0 : nil
        }
        // The newest user turn always sends all of its image bytes and does not
        // consume the historical budget. When history resend is enabled, only the
        // newest eligible N historical images are uploaded, unless the user chooses
        // the explicit unlimited option. Collapsed user-image groups stay visible in
        // the transcript but are excluded from either selection.
        let newestUserMessageID = contextMessages.last(where: { $0.role == .user })?.id
        let historicalImageLimit = min(max(preferences.historicalImageResendLimit, 1), 10)
        let eligibleHistoricalImageIDs = contextMessages.flatMap { message -> [UUID] in
            let isNewestUserMessage = message.role == .user && message.id == newestUserMessageID
            guard !isNewestUserMessage, message.historicalImagesCollapsed != true else { return [] }
            return message.attachments.compactMap { attachment in
                attachment.kind == .image ? attachment.id : nil
            }
        }
        let transmittedHistoricalImageIDs: Set<UUID> = {
            guard preferences.resendHistoricalImages else { return [] }
            if preferences.historicalImageResendUnlimited {
                return Set(eligibleHistoricalImageIDs)
            }
            return Set(eligibleHistoricalImageIDs.suffix(historicalImageLimit))
        }()
        let userTurnsAfter = userTurnCountsAfter(contextMessages)
        var messageTime = MessageTimeContext()
        var wireMessages: [ChatRequestMessage] = []
        var lastOriginalUserWireIndex: Int?
        var userMessageTimes: [(index: Int, timestamp: String)] = []
        for (messageIndex, message) in contextMessages.enumerated() {
            try Task.checkCancellation()
            var content = message.text
            let imageAttachments = message.attachments.filter { $0.kind == .image }
            let isNewestUserMessage = message.role == .user && message.id == newestUserMessageID
            let transmittedImageAttachments = isNewestUserMessage
                ? imageAttachments
                : imageAttachments.filter { transmittedHistoricalImageIDs.contains($0.id) }
            let shouldTransmitImages = !transmittedImageAttachments.isEmpty
            let shouldUseOCR = message.role == .user
                && shouldTransmitImages
                && ocrContext != nil
            var didUseOCR = false
            if shouldUseOCR, let ocrContext,
               let ocrText = await OCRService.shared.text(
                    for: transmittedImageAttachments,
                    provider: ocrContext.provider,
                    modelID: ocrContext.modelID,
                    prompt: preferences.ocrPrompt
               ) {
                didUseOCR = true
                let wrappedOCR = """
                The image_file_ocr tag contains a description of an image that the user uploaded to you, not the user's prompt.
                <image_file_ocr>
                \(ocrText.trimmingCharacters(in: .whitespacesAndNewlines))
                </image_file_ocr>

                """
                content = wrappedOCR + content
            }
            let omittedHistoricalImageCount = isNewestUserMessage
                ? 0
                : max(imageAttachments.count - transmittedImageAttachments.count, 0)
            if omittedHistoricalImageCount > 0 {
                let reason: String
                if message.historicalImagesCollapsed == true {
                    reason = "已折叠，本轮不上传"
                } else if !preferences.resendHistoricalImages {
                    reason = "历史图片发送已关闭，本轮不重复上传"
                } else if preferences.historicalImageResendUnlimited {
                    reason = "本轮不重复上传"
                } else {
                    reason = "超出最新 \(historicalImageLimit) 张上限，本轮不重复上传"
                }
                let imageMarker = "[历史图片附件：\(omittedHistoricalImageCount) 张；\(reason)]"
                content = content.isEmpty ? imageMarker : content + "\n\n" + imageMarker
            }
            let preparedAttachments: ChatRequestAttachments.Prepared
            if message.attachments.isEmpty {
                preparedAttachments = .init()
            } else {
                preparedAttachments = try await ChatRequestAttachments.prepare(
                    message.attachments,
                    imageIDs: didUseOCR ? [] : Set(transmittedImageAttachments.map(\.id))
                )
            }
            content += preparedAttachments.text
            let images = preparedAttachments.images
            let wireRole: String
            if message.role == .assistant,
               groupConversation != nil {
                // Provider chat APIs only understand `user` and `assistant`, so turn
                // another member's reply into a clearly-attributed contribution from
                // the group.  Keep this assistant's own past replies as `assistant`.
                if message.groupID == assistant.id.uuidString {
                    wireRole = "assistant"
                } else {
                    let authorName = assistants.first(where: { $0.id.uuidString == message.groupID })?.name
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = (authorName?.isEmpty == false ? authorName! : "Assistant")
                    content = "[\(label)]: \(content)"
                    wireRole = "user"
                }
            } else {
                wireRole = message.role == .assistant ? "assistant" : "user"
            }
            if message.role == .assistant,
               groupConversation == nil || message.groupID == assistant.id.uuidString {
                wireMessages.append(contentsOf: Self.retainedSearchToolMessages(
                    for: message,
                    userTurnsAfter: userTurnsAfter[messageIndex],
                    retentionTurns: preferences.searchToolResultRetentionTurns,
                    providerType: provider.type
                ))
            }
            let messageWireIndex = wireMessages.count
            wireMessages.append(ChatRequestMessage(
                role: wireRole,
                content: content,
                images: images
            ))
            if message.role == .user {
                lastOriginalUserWireIndex = messageWireIndex
                if assistant.messageTimeEnabled,
                   let timestamp = messageTime.timestamp(for: message) {
                    userMessageTimes.append((messageWireIndex, timestamp))
                }
            }
        }
        // 消息模板：应用到最后一条用户消息（{{ role }}/{{ message }}/{{ time }}/{{ date }}）。
        let template = assistant.messageTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty, template != AssistantProfile.defaultMessageTemplate,
           let lastUserIndex = lastOriginalUserWireIndex {
            let original = wireMessages[lastUserIndex]
            wireMessages[lastUserIndex] = ChatRequestMessage(
                role: original.role,
                content: Self.applyMessageTemplate(template, role: "user", message: original.content),
                images: original.images
            )
        }

        // Keep each user's original send time, including when that message
        // becomes history. Apply after the optional template without changing
        // stored/displayed text or mistaking another group member for the user.
        for time in userMessageTimes {
            let original = wireMessages[time.index]
            wireMessages[time.index] = ChatRequestMessage(
                role: original.role,
                content: MessageTimeContext.appending(time.timestamp, to: original.content),
                images: original.images
            )
        }

        try Task.checkCancellation()
        return wireMessages
    }

    private static func userTurnCountsAfter(_ messages: [ChatMessage]) -> [Int] {
        var counts = Array(repeating: 0, count: messages.count)
        var userTurns = 0
        for index in messages.indices.reversed() {
            counts[index] = userTurns
            if messages[index].role == .user { userTurns += 1 }
        }
        return counts
    }

    private static func retainedSearchToolMessages(
        for message: ChatMessage,
        userTurnsAfter: Int,
        retentionTurns: Int,
        providerType: ProviderType
    ) -> [ChatRequestMessage] {
        guard message.role == .assistant, !message.toolEvents.isEmpty else { return [] }
        if retentionTurns >= 0 {
            guard userTurnsAfter <= retentionTurns else { return [] }
        }

        let retained = message.toolEvents.enumerated().compactMap { offset, event -> (
            id: String,
            name: String,
            arguments: [String: Any],
            result: String
        )? in
            guard isSearchToolEvent(event.name),
                  let rawResult = event.resultText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawResult.isEmpty else { return nil }
            let rawID = event.providerEventID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackID = "call_\(message.id.uuidString.prefix(8))_\(offset)"
            let arguments: [String: Any]
            if let rawArguments = event.argumentsJSON,
               let data = rawArguments.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                arguments = object
            } else {
                arguments = [:]
            }
            return (rawID.isEmpty ? fallbackID : rawID, event.name, arguments, rawResult)
        }
        guard !retained.isEmpty else { return [] }

        switch providerType {
        case .openAI:
            let calls: [[String: Any]] = retained.map { item in
                let argumentsJSON: String
                if let data = try? JSONSerialization.data(
                    withJSONObject: item.arguments,
                    options: [.sortedKeys]
                ), let encoded = String(data: data, encoding: .utf8) {
                    argumentsJSON = encoded
                } else {
                    argumentsJSON = "{}"
                }
                return [
                    "id": item.id,
                    "type": "function",
                    "function": ["name": item.name, "arguments": argumentsJSON]
                ] as [String: Any]
            }
            var messages = [ChatRequestMessage(
                role: "assistant",
                content: "",
                toolCallsJSON: calls
            )]
            messages.append(contentsOf: retained.map { item in
                ChatRequestMessage(role: "tool", content: item.result, toolCallID: item.id)
            })
            return messages

        case .claude:
            let calls: [[String: Any]] = retained.map { item in
                [
                    "type": "tool_use",
                    "id": item.id,
                    "name": item.name,
                    "input": item.arguments
                ] as [String: Any]
            }
            let results: [[String: Any]] = retained.map { item in
                [
                    "type": "tool_result",
                    "tool_use_id": item.id,
                    "content": item.result
                ] as [String: Any]
            }
            return [
                ChatRequestMessage(role: "assistant", content: "", contentBlocks: calls),
                ChatRequestMessage(role: "user", content: "", contentBlocks: results)
            ]

        case .google:
            return [
                ChatRequestMessage(
                    role: "assistant",
                    content: "",
                    functionCalls: retained.map { ($0.name, $0.arguments) }
                ),
                ChatRequestMessage(
                    role: "tool",
                    content: "",
                    functionResponses: retained.map { ($0.name, $0.result) }
                )
            ]
        }
    }

    private static func isSearchToolEvent(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == SearchToolConstants.toolName
            || name == LocalToolName.searchConversations
            || name == "builtin_search"
            || name == "web_search"
            || name == "web_search_preview"
            || name.hasPrefix("web_search_")
    }

    private static func applyMessageTemplate(_ template: String, role: String, message: String) -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let vars = [
            "role": role,
            "message": message,
            "time": timeFormatter.string(from: now),
            "date": dateFormatter.string(from: now)
        ]
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*(\w+)\s*\}\}"#) else { return message }
        var result = ""
        var lastIndex = template.startIndex
        let nsTemplate = template as NSString
        for match in regex.matches(in: template, range: NSRange(location: 0, length: nsTemplate.length)) {
            guard let range = Range(match.range, in: template),
                  let keyRange = Range(match.range(at: 1), in: template) else { continue }
            result += template[lastIndex..<range.lowerBound]
            let key = String(template[keyRange])
            result += vars[key] ?? String(template[range])
            lastIndex = range.upperBound
        }
        result += template[lastIndex...]
        return result
    }

}

/// One worker per message preserves attachment order and the existing failure
/// policy: ordinary missing files are omitted/labelled; pasted text is verified
/// in full and fails the request if it cannot be read intact.
enum ChatRequestAttachments {
    struct Prepared: Sendable {
        var text = ""
        var images: [ChatRequestImage] = []
    }

    static func prepare(
        _ attachments: [MessageAttachment], imageIDs: Set<UUID>
    ) async throws -> Prepared {
        try Task.checkCancellation()
        guard !attachments.isEmpty else { return Prepared() }
        let worker = Task.detached(priority: .userInitiated) {
            var result = Prepared()
            for attachment in attachments {
                try Task.checkCancellation()
                switch attachment.kind {
                case .image:
                    if imageIDs.contains(attachment.id),
                       let url = attachment.localURL,
                       let data = try? Data(contentsOf: url) {
                        try Task.checkCancellation()
                        result.images.append(ChatRequestImage(
                            mimeType: attachment.mimeType ?? "image/jpeg",
                            base64Data: data.base64EncodedString()
                        ))
                    }
                case .file:
                    let name = attachment.fileName ?? "未命名"
                    if AttachmentStore.isPastedText(attachment) {
                        let text = try await AttachmentStore.readPastedTextContent(of: attachment)
                        result.text += "\n\n[文件: \(name)]\n\(text)"
                    } else if let text = AttachmentStore.readTextContent(of: attachment) {
                        result.text += "\n\n[文件: \(name)]\n\(text)"
                    } else {
                        result.text += "\n\n[附件文件: \(name)]"
                    }
                default:
                    break
                }
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Mutable formatters are owned by one request, never shared across tasks.
struct MessageTimeContext {
    private var formatters: [Int: DateFormatter] = [:]
    mutating func timestamp(for message: ChatMessage) -> String? {
        guard let offset = message.sentTimeZoneOffsetSeconds,
              let timeZone = TimeZone(secondsFromGMT: offset) else { return nil }
        let formatter: DateFormatter
        if let cached = formatters[offset] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatters[offset] = formatter
        }
        return formatter.string(from: message.createdAt)
    }

    static func appending(_ timestamp: String, to content: String) -> String {
        content + (content.isEmpty ? "" : "\n\n") + "[\(timestamp)]"
    }
}
