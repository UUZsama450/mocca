import XCTest
import Observation
@testable import Mocca

@MainActor final class GroupChatLookupTests: XCTestCase {
    private func fixture() -> AppModel {
        precondition(Bundle.main.bundleIdentifier == "com.mocca.lab.groupreusehost")
        let model = AppModel()
        model.assistants = (0..<12).map { AssistantProfile(name: "Synthetic member \($0)") }
        model.currentAssistantID = model.assistants[0].id
        return model
    }

    func testWarmReadsReflectProfileEditsAndModelChanges() {
        let model = fixture(), index = 11
        let id = model.assistants[index].id.uuidString
        _ = model.assistantProfile(id: id)
        model.assistants[index].name = "Renamed"
        model.assistants[index].avatar = "🐱"
        model.assistants[index].useAssistantName = true
        model.assistants[index].chatModel = ModelSelection(providerID: UUID(), modelID: "local-model")
        XCTAssertEqual(model.assistantProfile(id: id), model.assistants[index])
        XCTAssertEqual(model.assistantProfile(id: id)?.name, "Renamed")
        XCTAssertEqual(model.assistantProfile(id: id)?.avatar, "🐱")
    }

    func testReorderDuplicateImportDeletionAndRollback() {
        let model = fixture()
        let original = model.assistants
        let id = original.last!.id.uuidString
        _ = model.assistantProfile(id: id)
        model.assistants.reverse()
        XCTAssertEqual(model.assistantProfile(id: id), original.last)
        var duplicate = original.last!; duplicate.name = "First duplicate"
        model.assistants.insert(duplicate, at: 0)
        XCTAssertEqual(model.assistantProfile(id: id)?.name, "First duplicate")
        model.assistants.removeAll { $0.id.uuidString == id }
        XCTAssertNil(model.assistantProfile(id: id))
        model.assistants[0] = original.last! // same-count replacement after a cached miss
        XCTAssertEqual(model.assistantProfile(id: id), original.last)
        model.assistants = []
        XCTAssertNil(model.assistantProfile(id: id))
        model.assistants = original // import/rollback keeps the canonical array authoritative
        XCTAssertEqual(model.assistantProfile(id: id), original.last)
        XCTAssertNil(model.assistantProfile(id: nil))
        XCTAssertNil(model.assistantProfile(id: id.lowercased()))
    }

    func testWarmObservationIncludingMissingMember() {
        let model = fixture()
        let profile = model.assistants.last!
        for mode in 0..<4 {
            model.assistants = [profile]
            let id = mode == 3 ? UUID().uuidString : profile.id.uuidString
            _ = model.assistantProfile(id: id)
            nonisolated(unsafe) var changed = false
            withObservationTracking { _ = model.assistantProfile(id: id) } onChange: { changed = true }
            switch mode {
            case 0: model.assistants[0].name = "Observed name"
            case 1: model.assistants[0].avatar = "🦊"
            case 2: model.assistants.removeAll()
            default: model.assistants.append(AssistantProfile(id: UUID(uuidString: id)!, name: "New member"))
            }
            XCTAssertTrue(changed, "mode \(mode)")
            XCTAssertEqual(model.assistantProfile(id: id), model.assistants.first { $0.id.uuidString == id })
        }
    }

    func testGroupOrderAndSingleChatFallbackRemainCanonical() {
        let model = fixture()
        let a = model.assistants[0], b = model.assistants[1]
        let group = Conversation(title: "Synthetic group", assistantID: a.id.uuidString,
                                 groupAssistantIDs: [b.id.uuidString, a.id.uuidString])
        model.conversations = [group]; model.selectedConversationID = group.id
        XCTAssertEqual(model.selectedConversationAssistantProfiles.map(\.id), [b.id, a.id])
        let message = ChatMessage(conversationID: group.id, role: .assistant, text: "Synthetic")
        XCTAssertEqual(model.displayAssistant(for: message).id, b.id)
        model.assistants.removeAll { $0.id == b.id }
        XCTAssertEqual(model.selectedConversationAssistantProfiles.map(\.id), [a.id])
        XCTAssertEqual(model.displayAssistant(for: message).id, a.id)
        let single = Conversation(title: "Synthetic single", assistantID: a.id.uuidString)
        model.conversations = [single]; model.selectedConversationID = single.id
        XCTAssertEqual(model.selectedConversationAssistantProfiles, [a])
    }
}
