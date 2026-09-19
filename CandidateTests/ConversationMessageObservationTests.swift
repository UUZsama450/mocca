import XCTest
import Observation
@testable import Mocca

private final class ObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
final class ConversationMessageObservationTests: XCTestCase {
    private func fixture() -> (AppModel, UUID, UUID) {
        let model = AppModel()
        let a = Conversation(title: "A"), b = Conversation(title: "B")
        model.conversations = [a, b]
        model.messagesByConversation = [a.id: [ChatMessage(conversationID: a.id, role: .assistant, text: "A v1", versionGroupID: "answer", version: 1),
            ChatMessage(conversationID: a.id, role: .assistant, text: "A v2", versionGroupID: "answer", version: 2)],
            b.id: [ChatMessage(conversationID: b.id, role: .assistant, text: "B")]]
        model.selectedConversationID = a.id
        _ = model.messages
        return (model, a.id, b.id)
    }

    func testBackgroundEditsDoNotNotifyOrRebuildCurrentTranscript() {
        let (m,a,b) = fixture()
        let expected = m.messages, builds = m.observationTestProjectionBuilds
        let selected = ObservationCount(), background = ObservationCount(), global = ObservationCount()
        for i in 0..<20 {
            withObservationTracking { _ = m.messages } onChange: { selected.increment() }
            withObservationTracking { _ = m.conversationMessageStore[b] } onChange: { background.increment() }
            withObservationTracking { _ = m.messagesByConversation } onChange: { global.increment() }
            m.conversationMessageStore[b]![0].text += " \(i)"
            XCTAssertEqual(m.messages, expected)
            XCTAssertEqual(m.selectedConversationID,a)
        }
        XCTAssertEqual(selected.value,0)
        XCTAssertEqual(background.value,20)
        XCTAssertEqual(global.value,20)
        XCTAssertEqual(m.observationTestProjectionBuilds,builds)
    }

    func testCurrentUpdatesAndVersionsStillInvalidateWarmCache() {
        let (m,a,_) = fixture()
        let initial = m.observationTestProjectionBuilds
        let changed = ObservationCount()
        withObservationTracking { _ = m.messages } onChange: { changed.increment() }
        m.conversationMessageStore[a]![1].text = "new selected answer"
        XCTAssertEqual(changed.value,1)
        XCTAssertEqual(m.messages.last?.text,"new selected answer")
        XCTAssertEqual(m.observationTestProjectionBuilds,initial+1)
        m.conversations[0].versionSelections["answer"] = 1
        XCTAssertEqual(m.messages.last?.text,"A v1")
        XCTAssertEqual(m.observationTestProjectionBuilds,initial+2)
        m.conversations[0].title = "renamed A"
        m.conversations[1].title = "renamed B"
        XCTAssertEqual(m.messages.last?.version,1)
        XCTAssertEqual(m.observationTestProjectionBuilds,initial+2)
    }

    func testSwitchingAndExplicitSnapshotCannotPoisonCurrentCache() {
        let (m,a,b) = fixture()
        let snapshot = m.messagesByConversation
        m.conversationMessageStore[b]![0].text = "latest B"
        m.selectConversation(b,closeDrawer:false)
        XCTAssertEqual(m.messages.last?.text,"latest B")
        XCTAssertEqual(m.observationTestProjection(b,raw:snapshot[b]!).last?.text,"B")
        XCTAssertEqual(m.messages.last?.text,"latest B")
        m.selectConversation(a,closeDrawer:false)
        XCTAssertEqual(m.messages.last?.text,"A v2")
    }

    func testMissingDeletionAndReinsertionKeepObservationIdentity() {
        let (m,_,_) = fixture(); let id=UUID()
        let missing=ObservationCount()
        withObservationTracking { _ = m.conversationMessageStore[id] } onChange: { missing.increment() }
        let message=ChatMessage(conversationID:id,role:.user,text:"first")
        m.conversationMessageStore[id,default:[]].append(message)
        XCTAssertEqual(missing.value,1)
        let firstRevision=m.conversationMessageStore.revision(for:id)
        let deletion=ObservationCount()
        withObservationTracking { _ = m.conversationMessageStore[id] } onChange: { deletion.increment() }
        m.conversationMessageStore[id]=nil
        XCTAssertEqual(deletion.value,1)
        XCTAssertNil(m.conversationMessageStore[id])
        let reinsert=ObservationCount()
        withObservationTracking { _ = m.conversationMessageStore[id] } onChange: { reinsert.increment() }
        m.conversationMessageStore[id]=[message]
        XCTAssertEqual(reinsert.value,1)
        XCTAssertNotEqual(m.conversationMessageStore.revision(for:id),firstRevision)
    }

    func testBulkReplacementOnlyInvalidatesChangedKeysAndSnapshotIsIndependent() {
        let (m,a,b)=fixture(); let prior=m.messagesByConversation
        let ca=ObservationCount(),cb=ObservationCount(),all=ObservationCount()
        withObservationTracking { _=m.conversationMessageStore[a] } onChange:{ca.increment()}
        withObservationTracking { _=m.conversationMessageStore[b] } onChange:{cb.increment()}
        withObservationTracking { _=m.messagesByConversation } onChange:{all.increment()}
        var next=prior; next[b]![0].text="restored B"
        m.messagesByConversation=next
        XCTAssertEqual(ca.value,0);XCTAssertEqual(cb.value,1);XCTAssertEqual(all.value,1)
        XCTAssertEqual(prior[b]![0].text,"B")
        m.conversationMessageStore[b]![0].text="further edit"
        XCTAssertEqual(next[b]![0].text,"restored B")
        m.messagesByConversation=prior
        XCTAssertEqual(m.messagesByConversation,prior)
        let noOp=ObservationCount()
        withObservationTracking { _=m.messagesByConversation } onChange:{noOp.increment()}
        m.messagesByConversation=prior
        XCTAssertEqual(noOp.value,0)
    }

    func testActualBackupRollbackRestoresValueSnapshotAndNotifications() {
        let (m,a,b)=fixture(); let prior=m.messagesByConversation
        let rollback=m.observationTestRollback()
        m.conversationMessageStore[a]![1].text="changed A"
        m.conversationMessageStore[b]=nil
        m.conversations=[]
        let notice=ObservationCount()
        withObservationTracking { _=m.conversationMessageStore[b] } onChange:{notice.increment()}
        rollback()
        XCTAssertEqual(notice.value,1)
        XCTAssertEqual(m.messagesByConversation,prior)
        XCTAssertEqual(m.messages.last?.text,"A v2")
    }

    func testSnapshotPersistenceRoundTripAndBookmarksStayLive() throws {
        let (m,_,b)=fixture()
        let bookmarks=ObservationCount()
        withObservationTracking {
            _=m.conversations.flatMap { m.conversationMessageStore[$0.id] ?? [] }.filter { $0.reactions.bookmarkedAt != nil }
        } onChange:{bookmarks.increment()}
        m.conversationMessageStore[b]![0].reactions.bookmarkedAt=Date(timeIntervalSince1970:123)
        XCTAssertEqual(bookmarks.value,1)
        let snapshot=m.persistableConversationSnapshot()
        let decoded=try JSONDecoder().decode(ConversationSnapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.messagesByConversation,m.messagesByConversation)
        XCTAssertEqual(decoded.conversations,m.conversations)
    }

    func testBackgroundTextReasoningToolsAndCompletionKeepCanonicalResults() throws {
        let (m,_,b)=fixture(); let expected=m.messages
        let id=m.observationTestStartStream(in:b)
        let notice=ObservationCount()
        withObservationTracking {_=m.messages} onChange:{notice.increment()}
        m.observationTestPublish(in:b,message:id,text:"partial answer")
        try m.observationTestAppend(.reasoning("thinking"),in:b,message:id)
        try m.observationTestAppend(.toolCalls([ToolCallInfo(id:"call",name:"fixture",arguments:[:])]),in:b,message:id)
        try m.observationTestAppend(.toolResults([ToolResultInfo(id:"call",name:"fixture",arguments:[:],content:"tool result")]),in:b,message:id)
        XCTAssertEqual(m.conversationMessageStore[b]?.last?.toolEvents.first?.resultText,"tool result")
        try m.observationTestAppend(.imageGenerationProgress("rendering"),in:b,message:id)
        XCTAssertEqual(notice.value,0)
        XCTAssertEqual(m.messages,expected)
        XCTAssertEqual(m.conversationMessageStore[b]?.last?.reasoningSegments.last?.text,"thinking")
        let completed=m.observationTestFinish(in:b,raw:"complete answer",cancelled:false)
        XCTAssertEqual(completed?.text,"complete answer")
        XCTAssertEqual(completed?.status,.complete)
        m.selectConversation(b,closeDrawer:false)
        XCTAssertEqual(m.messages.last?.text,"complete answer")
        let second=m.observationTestStartStream(in:b)
        m.observationTestPublish(in:b,message:second,text:"partial")
        let stopped=m.observationTestFinish(in:b,raw:"partial remaining",cancelled:true)
        XCTAssertEqual(stopped?.text,"partial remaining")
        XCTAssertEqual(stopped?.status,.cancelled)
    }
}
