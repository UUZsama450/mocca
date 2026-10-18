import XCTest
@testable import Mocca

@MainActor final class ReplySegmentationTests: XCTestCase {
    private func parts(_ text: String, limit: Int = 0, chunks: Bool = false) -> [String] {
        var scanner = ReplySegmentScanner(maximumSegments: limit)
        if chunks {
            var prefix = ""
            for scalar in text.unicodeScalars { prefix.unicodeScalars.append(scalar); scanner.advance(through: prefix) }
        } else { scanner.advance(through: text) }
        return scanner.segmentation.segments(in: text)
    }

    func testNaturalParagraphsUnicodeLimitsAndChunkIndependence() {
        let paragraphs = ["宝宝回来啦！买什么呀～👨‍👩‍👧‍👦", "e\u{301}和é都要保留。", "第三段。", "第四段。"]
        let text = paragraphs.joined(separator: "\n\n")
        XCTAssertEqual(parts(text), paragraphs)
        XCTAssertEqual(parts(text, chunks: true), paragraphs)
        XCTAssertEqual(parts(text, limit: 2, chunks: true), [paragraphs[0], paragraphs.dropFirst().joined(separator: "\n\n")])
        XCTAssertEqual(parts(text, limit: 1), [text])
        XCTAssertEqual(parts("第一句！第二句？第三句。"), ["第一句！第二句？第三句。"])
        XCTAssertEqual(parts("第一段\r\n\r\n第二段", chunks: true), ["第一段", "第二段"])
        XCTAssertEqual(parts("第一段\n  \n第二段", chunks: true), ["第一段", "第二段"])
    }

    func testStructuredContentAndUnclosedFences() {
        for fence in ["```", "~~~~", "````"] {
            let code = fence + "swift\nlet a = 1\n\nlet b = 2\n" + fence
            XCTAssertEqual(parts("前面\n\n" + code + "\n\n后面", chunks: true), ["前面", code, "后面"])
            let incomplete = fence + "swift\nlet a = 1\n\n还没结束"
            XCTAssertEqual(parts(incomplete, chunks: true), [incomplete])
        }
        let table = "| 名字 | 状态 |\n| --- | --- |\n| 宝宝 | 好 |"
        XCTAssertEqual(parts("前面\n\n" + table + "\n\n后面", chunks: true), ["前面", table, "后面"])
        let list = "- 第一项\n\n- 第二项\n\n  同一项的后续文字"
        XCTAssertEqual(parts("前面\n\n" + list + "\n\n后面", chunks: true), ["前面", list, "后面"])
        let quote = "> 第一句\n\n> 第二句"
        XCTAssertEqual(parts(quote + "\n\n后面"), [quote, "后面"])
    }

    func testNoEmptyBubbleAndClosedPrefixesStayStable() {
        var progress = ReplySegmentProgress(maximumSegments: 0)
        let inputs = ["第一泡", "第一泡\n", "第一泡\n\n", "第一泡\n\n第", "第一泡\n\n第二泡", "第一泡\n\n第二泡\n\n第三泡"]
        for (i, text) in inputs.enumerated() {
            let segmentation = progress.update(text, appendOnly: true)
            let segments = segmentation.segments(in: text)
            XCTAssertEqual(segments.count, i < 3 ? 1 : i < 5 ? 2 : 3)
            XCTAssertTrue(segments.allSatisfy { !$0.isEmpty })
            if i >= 3 { XCTAssertEqual(segments[0], "第一泡") }
        }
        let rewritten = "新的内容\n\n另一段"
        XCTAssertEqual(progress.update(rewritten).segments(in: rewritten), ["新的内容", "另一段"])
    }

    func testMetadataRoundTripLegacyDecodeAndInvalidBoundaries() throws {
        let text = "第一泡\n\n第二泡🥳"
        var scanner = ReplySegmentScanner(maximumSegments: 3); scanner.advance(through: text)
        let message = ChatMessage(conversationID: UUID(), role: .assistant, text: text, replySegmentation: scanner.segmentation)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ChatMessage.self, from: encoder.encode(message)), message)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(message)) as? [String: Any])
        json.removeValue(forKey: "replySegmentation")
        XCTAssertNil(try decoder.decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json)).replySegmentation)
        let defaults = try decoder.decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(defaults.chatSegmentedReply)
        XCTAssertEqual(defaults.replySegmentLimit, 5)
        for offsets in [[-1], [1], [9999], [9, 9], [9, 1]] {
            var corrupt = ReplySegmentation(maximumSegments: 0); corrupt.startsUTF8 = offsets
            XCTAssertEqual(corrupt.segments(in: text), [text])
        }
    }

    private func fixture(group: Bool = false) throws -> (AppModel, UUID) {
        precondition(Bundle.main.bundleIdentifier == "com.mocca.lab.replysegments")
        let model = AppModel()
        let second = AssistantProfile(name: "群聊乙")
        if group { model.assistants.append(second) }
        let chat = Conversation(assistantID: model.currentAssistantID.uuidString,
                                groupAssistantIDs: group ? [model.currentAssistantID.uuidString, second.id.uuidString] : [])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try model.reviewInstallStore(ConversationSnapshot(conversations: [chat], messagesByConversation: [chat.id: []]), directory: dir)
        model.preferences.chatSegmentedReply = true
        model.preferences.replySegmentLimit = 2
        model.preferences.ttsAutoPlayAssistantReplies = false
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (model, chat.id)
    }

    func testFrozenSettingsAndLivePublishThenCancellationPersists() throws {
        let (model, chat) = try fixture()
        let reply = try model.streamQAStart(chat)
        defer { model.streamQAClose([reply.id]) }
        XCTAssertEqual(reply.replySegmentation?.maximumSegments, 2)
        model.preferences.chatSegmentedReply = false
        model.preferences.replySegmentLimit = 0
        model.segmentQAPublish("第一泡\n\n第二泡\n\n第三段", for: reply)
        let live = try XCTUnwrap(model.streamQAMessage(reply))
        XCTAssertEqual(live.status, .streaming)
        XCTAssertEqual(live.replySegmentation?.segments(in: live.text), ["第一泡", "第二泡\n\n第三段"])
        let final = try XCTUnwrap(model.streamQAFinish(reply, cancelled: true))
        XCTAssertEqual(final.replySegmentation, live.replySegmentation)
        XCTAssertEqual(final.status, .cancelled)
        let reloaded = try XCTUnwrap(model.reviewReadStore().messagesByConversation[chat]?.last)
        XCTAssertEqual(reloaded.replySegmentation, final.replySegmentation)
        XCTAssertEqual(model.segmentQACursorCount, 0)
    }

    func testHiddenRecoveryDoesNotAdvanceVisibleSegmentsAndFailureKeepsText() throws {
        let (model, chat) = try fixture()
        let reply = try model.streamQAStart(chat, streamOutput: false)
        defer { model.streamQAClose([reply.id]) }
        try model.streamQAReceive(.text("一\n\n二\n\n三"), for: reply, publishesContent: false)
        let saved = try XCTUnwrap(model.streamQASnapshot(reply))
        XCTAssertEqual(saved.replySegmentation?.segments(in: saved.text), ["一", "二\n\n三"])
        XCTAssertEqual(model.streamQAMessage(reply)?.text, "")
        XCTAssertEqual(model.streamQAMessage(reply)?.replySegmentation?.startsUTF8, [])
        XCTAssertEqual(model.streamQASnapshot(reply), saved)
        let failed = try XCTUnwrap(model.streamQAFinish(reply, failure: "Synthetic network failure"))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.replySegmentation, saved.replySegmentation)
        XCTAssertEqual(model.segmentQACursorCount, 0)
    }

    func testDisabledPathsCreateNoScannerAndGroupCannotFallBackToLegacy() throws {
        for group in [false, true] {
            let (model, chat) = try fixture(group: group)
            model.preferences.chatSegmentedReply = false
            let reply = try model.streamQAStart(chat)
            if group { XCTAssertEqual(reply.replySegmentation?.isEnabled, false) }
            else { XCTAssertNil(reply.replySegmentation) }
            model.preferences.chatSegmentedReply = true
            model.segmentQAPublish("一\n\n二", for: reply)
            let saved = try XCTUnwrap(model.streamQASnapshot(reply))
            if group { XCTAssertEqual(saved.replySegmentation?.segments(in: saved.text), ["一\n\n二"]) }
            else { XCTAssertNil(saved.replySegmentation) }
            XCTAssertEqual(model.segmentQACursorCount, 0)
            _ = model.streamQAFinish(reply)
            model.editMessage(reply.id, text: "修改一\n\n修改二")
            if group { XCTAssertEqual(model.streamQAMessage(reply)?.replySegmentation?.isEnabled, false) }
            model.streamQAClose([reply.id])
        }
    }

    func testLegacyGroupPreferenceMigratesToOneSwitchAndDropsRegex() throws {
        for enabled in [false, true] {
            let old: [String: Any] = ["groupChatSegmentedReply": enabled, "groupChatSegmentRegex": "[invalid",
                "groupChatForceAssistantBubble": true, "groupChatBubbleOpacity": 0.35,
                "groupAssistantBubbleColors": ["member": 0xff55aaff]]
            var preferences = try JSONDecoder().decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: old))
            XCTAssertEqual(preferences.chatSegmentedReply, enabled)
            preferences.chatSegmentedReply = !enabled
            let encoded = try JSONEncoder().encode(preferences)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(json["groupChatSegmentRegex"])
            XCTAssertNil(json["groupChatSegmentedReply"])
            let restored = try JSONDecoder().decode(UserPreferences.self, from: encoded)
            XCTAssertEqual(restored.chatSegmentedReply, !enabled)
            XCTAssertTrue(restored.groupChatForceAssistantBubble)
            XCTAssertEqual(restored.groupChatBubbleOpacity, 0.35)
            XCTAssertEqual(restored.groupAssistantBubbleColors["member"], 0xff55aaff)
        }
        let explicitOff = Data(#"{"singleChatSegmentedReply":false,"groupChatSegmentedReply":true}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(UserPreferences.self, from: explicitOff).chatSegmentedReply)
    }

    func testGroupMembersKeepIndependentBoundariesAuthorsAndReactionThroughBackup() async throws {
        let (model, chat) = try fixture(group: true)
        let first = try model.streamQAStart(chat)
        model.segmentQAPublish("甲一句。甲二句！\n\n甲第二段\n\n甲第三段", for: first)
        let live = try XCTUnwrap(model.streamQAMessage(first))
        XCTAssertEqual(live.replySegmentation?.segments(in: live.text), ["甲一句。甲二句！", "甲第二段\n\n甲第三段"])
        let completed = try XCTUnwrap(model.streamQAFinish(first))
        model.setMessageUserReaction(first.id, reaction: "👍")
        let secondAssistant = try XCTUnwrap(model.assistants.last)
        model.preferences.replySegmentLimit = 0
        let second = try model.segmentQAStartMember(secondAssistant, in: chat)
        defer { model.streamQAClose([first.id, second.id]) }
        model.preferences.chatSegmentedReply = false
        model.preferences.replySegmentLimit = 1
        model.segmentQAPublish("乙第一段\n\n乙第二段\n\n乙第三段", for: second)
        let failed = try XCTUnwrap(model.streamQAFinish(second, failure: "synthetic group failure"))
        XCTAssertEqual(failed.replySegmentation?.segments(in: failed.text), ["乙第一段", "乙第二段", "乙第三段"])
        XCTAssertEqual(failed.groupID, secondAssistant.id.uuidString)
        XCTAssertNotEqual(failed.groupID, completed.groupID)
        XCTAssertEqual(model.streamQAMessage(first)?.reactions.userReaction, "👍")
        XCTAssertNil(failed.reactions.userReaction)
        XCTAssertEqual(model.streamQAMessage(first)?.replySegmentation, completed.replySegmentation)
        XCTAssertEqual(model.segmentQACursorCount, 0)
        let backup = try await BackupService.createBackup(options: BackupOptions(includeChats: true, includeFiles: false), model: model)
        defer { try? FileManager.default.removeItem(at: backup.url.deletingLastPathComponent()) }
        let (restored, _) = try fixture(group: true)
        defer { restored.streamQAClose([]) }
        _ = try await BackupService.restoreBackup(from: backup.url, mode: .overwrite, model: restored)
        let rows = try XCTUnwrap(restored.persistableConversationSnapshot().messagesByConversation[chat])
        XCTAssertEqual(rows.map(\.replySegmentation), [completed.replySegmentation, failed.replySegmentation])
        XCTAssertEqual(rows.map(\.groupID), [completed.groupID, failed.groupID])
        XCTAssertEqual(rows.first?.reactions.userReaction, "👍")
        XCTAssertEqual(rows.last?.status, .failed)
        let wire = try await ChatRequestPreparation.messages(from: rows, assistant: secondAssistant,
            provider: model.providers[0], preferences: model.preferences, conversation: model.conversations[0],
            assistants: model.assistants, ocrContext: nil)
        XCTAssertEqual(wire.count, 2)
        XCTAssertTrue(wire[0].content.contains(completed.text))
        XCTAssertEqual(wire[1].content, failed.text)
    }

    func testEditBranchVersionsAndProviderHistoryRetainOneReply() async throws {
        let (model, chat) = try fixture()
        let reply = try model.streamQAStart(chat)
        defer { model.streamQAClose([reply.id]) }
        model.segmentQAPublish("第一泡\n\n第二泡", for: reply)
        let complete = try XCTUnwrap(model.streamQAFinish(reply))
        model.preferences.chatSegmentedReply = false
        model.editMessage(reply.id, text: "修改后第一泡\n\n修改后第二泡\n\n余下正文")
        let edited = try XCTUnwrap(model.streamQAMessage(reply))
        XCTAssertEqual(edited.replySegmentation?.segments(in: edited.text), ["修改后第一泡", "修改后第二泡\n\n余下正文"])
        let wire = try await ChatRequestPreparation.messages(from: [edited], assistant: model.currentAssistant,
            provider: model.providers[0], preferences: model.preferences, conversation: model.conversations[0],
            assistants: model.assistants, ocrContext: nil)
        XCTAssertEqual(wire.count, 1)
        XCTAssertEqual(wire.first?.content, edited.text)
        model.stopStreaming() // Finish the synthetic run, as the real stream Task does.
        model.branchConversation(at: reply.id)
        let branch = try XCTUnwrap(model.persistableConversationSnapshot().messagesByConversation[model.selectedConversationID]?.last)
        XCTAssertEqual(branch.replySegmentation, edited.replySegmentation)
        XCTAssertNotEqual(branch.id, edited.id)
        XCTAssertEqual(complete.replySegmentation?.segments(in: complete.text), ["第一泡", "第二泡"])
    }
    func testVersionsAndNativeBackupRestoreKeepBoundaries() async throws {
        let (model, chat) = try fixture()
        let first = try model.streamQAStart(chat)
        model.segmentQAPublish("旧版本一\n\n旧版本二", for: first)
        let old = try XCTUnwrap(model.streamQAFinish(first))
        model.preferences.replySegmentLimit = 0
        let second = try model.segmentQANewVersion(after: old)
        defer { model.streamQAClose([first.id, second.id]) }
        model.segmentQAPublish("新版本一\n\n新版本二\n\n新版本三", for: second)
        let newer = try XCTUnwrap(model.streamQAFinish(second))
        model.preferences.chatSegmentedReply = false
        model.selectVersion(0, for: second.id)
        XCTAssertEqual(model.versions(for: second.id).map(\.replySegmentation), [old.replySegmentation, newer.replySegmentation])
        let backup = try await BackupService.createBackup(options: BackupOptions(includeChats: true, includeFiles: false), model: model)
        defer { try? FileManager.default.removeItem(at: backup.url.deletingLastPathComponent()) }
        let (restored, _) = try fixture()
        defer { restored.streamQAClose([]) }
        _ = try await BackupService.restoreBackup(from: backup.url, mode: .overwrite, model: restored)
        let rows = try XCTUnwrap(restored.persistableConversationSnapshot().messagesByConversation[chat])
        XCTAssertEqual(rows.map(\.replySegmentation), [old.replySegmentation, newer.replySegmentation])
        XCTAssertEqual(rows.map(\.text), [old.text, newer.text])
        XCTAssertFalse(restored.preferences.chatSegmentedReply)
        XCTAssertEqual(restored.preferences.replySegmentLimit, 0)
    }

}
