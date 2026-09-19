import XCTest
import Observation
@testable import Mocca

private final class LanguageObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor final class LocalizationIsolationTests: XCTestCase {
    func testLanguageChangesLeaveConversationStateAndObservationAlone() {
        let model = AppModel()
        let conversation = Conversation(title: "用户的中文标题")
        model.conversations = [conversation]
        model.messagesByConversation = [conversation.id: [ChatMessage(conversationID: conversation.id, role: .user, text: "用户的中文内容")]]
        model.selectedConversationID = conversation.id
        let expected = model.messages
        let revision = model.conversationMessageStore.revision(for: conversation.id)
        let count = LanguageObservationCount()
        let original = AppLocalization.shared.selection
        defer { AppLocalization.shared.select(original) }
        withObservationTracking {
            _ = model.messages
            _ = model.selectedConversationID
            _ = model.conversations
            _ = model.isDrawerPresented
            _ = model.unreadReplyConversationIDs
        } onChange: { count.increment() }
        for _ in 0..<20 {
            AppLocalization.shared.select(.english)
            XCTAssertEqual(L10n.lookup("设置"), "Settings")
            AppLocalization.shared.select(.simplifiedChinese)
            XCTAssertEqual(L10n.lookup("设置"), "设置")
        }
        XCTAssertEqual(count.value, 0)
        XCTAssertEqual(model.messages, expected)
        XCTAssertEqual(model.conversations[0].title, "用户的中文标题")
        XCTAssertEqual(model.conversationMessageStore.revision(for: conversation.id), revision)
    }

    func testBackgroundMessagesDoNotNotifyCurrentTranscriptOrLanguage() {
        let model = AppModel()
        let a = Conversation(title: "A"), b = Conversation(title: "B")
        model.conversations = [a,b]
        model.selectedConversationID = a.id
        model.messagesByConversation = [a.id: [ChatMessage(conversationID: a.id, role: .assistant, text: "A")], b.id: [ChatMessage(conversationID: b.id, role: .assistant, text: "B", status: .streaming)]]
        let expected = model.messages
        let current = LanguageObservationCount(), language = LanguageObservationCount(), background = LanguageObservationCount()
        for i in 0..<100 {
            withObservationTracking { _ = model.messages } onChange: { current.increment() }
            withObservationTracking { _ = AppLocalization.shared.locale; _ = L10n.lookup("设置") } onChange: { language.increment() }
            withObservationTracking { _ = model.conversationMessageStore[b.id] } onChange: { background.increment() }
            model.conversationMessageStore[b.id]![0].text += " \(i)"
            XCTAssertEqual(model.messages, expected)
        }
        XCTAssertEqual(current.value, 0)
        XCTAssertEqual(language.value, 0)
        XCTAssertEqual(background.value, 100)
    }

    func testSelectingSameLanguageDoesNotInvalidateLocalizedReaders() {
        let original = AppLocalization.shared.selection
        defer { AppLocalization.shared.select(original) }
        AppLocalization.shared.select(.english)
        let count = LanguageObservationCount()
        withObservationTracking { _ = L10n.lookup("设置"); _ = AppLocalization.shared.locale } onChange: { count.increment() }
        for _ in 0..<100 {
            AppLocalization.shared.select(.english)
            AppLocalization.shared.refreshSystemLanguage(preferredLanguages: ["zh-Hans"])
        }
        XCTAssertEqual(count.value,0)
    }
}
