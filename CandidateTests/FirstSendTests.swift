import XCTest
@testable import Mocca

@MainActor final class FirstSendTests: XCTestCase {
    func testFullModelSendAndStreamingWork() throws {
        for chatCount in [1, 120, 600] {
            let model = AppModel()
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            var chats: [Conversation] = []
            var messages: [UUID: [ChatMessage]] = [:]
            let body = String(repeating: "synthetic history, no personal data. ", count: 120)
            for n in 0..<chatCount {
                let chat = Conversation(title: "Fixture \(n)", createdAt: date, updatedAt: date,
                                        assistantID: model.currentAssistantID.uuidString)
                chats.append(chat)
                messages[chat.id] = (0..<(n == 0 ? 4 : 40)).map { i in
                    ChatMessage(conversationID: chat.id, role: i.isMultiple(of: 2) ? .user : .assistant,
                                text: "\(i) \(body)", createdAt: date, updatedAt: date)
                }
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { model.firstSendCloseSyntheticStore() }
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            try model.reviewInstallStore(ConversationSnapshot(conversations: chats, messagesByConversation: messages), directory: dir)
            let id = chats[0].id
            model.selectedConversationID = id
            var durations: [[String: Any]] = []
            for turn in 0..<3 {
                model.firstSendResetPresentation()
                model.setComposerDraftText("local test \(turn)", for: id)
                var start = CFAbsoluteTimeGetCurrent()
                XCTAssertTrue(model.sendDraft(for: id))
                let send = (CFAbsoluteTimeGetCurrent() - start) * 1000
                XCTAssertEqual(model.composerDraftText(for: id), "")
                var chunks: [Double] = []
                for _ in 0..<4 {
                    start = CFAbsoluteTimeGetCurrent()
                    XCTAssertTrue(model.firstSendSaveStreaming(id, finish: false))
                    chunks.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
                start = CFAbsoluteTimeGetCurrent()
                XCTAssertTrue(model.firstSendSaveStreaming(id, finish: true))
                durations.append(["send_ms": send, "send_stages_ms": model.firstSendLastStages, "stream_save_ms": chunks,
                                  "finish_save_ms": (CFAbsoluteTimeGetCurrent() - start) * 1000])
            }
            let loaded = try model.reviewReadStore()
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let durableExpected = try decoder.decode(ConversationSnapshot.self, from: encoder.encode(model.persistableConversationSnapshot()))
            XCTAssertTrue(loaded.messagesByConversation == durableExpected.messagesByConversation)
            let data = try JSONSerialization.data(withJSONObject: ["chat_count": chatCount, "turns": durations], options: [.sortedKeys])
            print("FIRST_SEND_MODEL_RESULT " + String(decoding: data, as: UTF8.self))
        }
    }
}
