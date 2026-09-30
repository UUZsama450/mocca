import Observation
import XCTest
@testable import Mocca

/// Run only in the dedicated simulator host, with synthetic app data.
@MainActor final class BottomToolsStateTests: XCTestCase {
    private func fixture() -> AppModel {
        let model = AppModel()
        model.assistants = [AssistantProfile(name: "Sync A"), AssistantProfile(name: "Sync B")]
        model.currentAssistantID = model.assistants[0].id
        model.worldBooks = [
            WorldBook(name: "Sync book A", entries: [WorldBookEntry(content: "Synthetic A")]),
            WorldBook(name: "Sync book B", entries: [WorldBookEntry(content: "Synthetic B")])
        ]
        model.instructionInjections = [InstructionInjection(title: "Sync instruction", prompt: "Synthetic instruction")]
        model.activeWorldBookIDsByAssistant = [model.currentAssistantID.uuidString: [model.worldBooks[0].id]]
        model.activeInstructionIDsByAssistant = [model.currentAssistantID.uuidString: [model.instructionInjections[0].id]]
        model.presentBottomTools()
        return model
    }

    func testDetailsOffThenQuickSelectionUsesOneStateWithoutReopening() {
        let model = fixture(), id = model.worldBooks[0].id
        model.bottomTools.route = .worldBook
        XCTAssertTrue(model.bottomToolWorldBooks[0].selected)
        model.setWorldBookActive(id, enabled: false)
        XCTAssertFalse(model.bottomToolWorldBooks[0].selected)
        XCTAssertFalse(model.isWorldBookActive(id))
        XCTAssertFalse(PromptInjectionPersistence.loadActiveWorldBookIDs()[model.currentAssistantID.uuidString]?.contains(id) ?? false)
        model.toggleWorldBookActive(id)
        XCTAssertTrue(model.bottomToolWorldBooks[0].selected)
        XCTAssertTrue(model.isWorldBookActive(id))
        XCTAssertEqual(model.bottomTools.route, .worldBook)
        XCTAssertTrue(model.isBottomToolsPresented)
    }

    func testDetailsRequestsAreIdempotentAndDeletedIDsCannotReturn() {
        let model = fixture(), book = model.worldBooks[0].id, instruction = model.instructionInjections[0].id
        for enabled in [false, false, true, true, false] {
            model.setWorldBookActive(book, enabled: enabled)
            model.setInstructionActive(instruction, enabled: enabled)
            XCTAssertEqual(model.isWorldBookActive(book), enabled)
            XCTAssertEqual(model.isInstructionActive(instruction), enabled)
        }
        model.deleteWorldBook(book)
        model.deleteInstruction(instruction)
        model.setWorldBookActive(book, enabled: true)
        model.setInstructionActive(instruction, enabled: true)
        XCTAssertFalse(model.isWorldBookActive(book))
        XCTAssertFalse(model.isInstructionActive(instruction))
    }

    func testWorldBookEditsInsertionAndDeletionReachOpenMenu() {
        let model = fixture()
        var book = model.worldBooks[0]
        book.name = "Renamed book"
        book.entries.append(WorldBookEntry(content: "Extra synthetic entry"))
        book.enabled = false
        model.upsertWorldBook(book)
        XCTAssertEqual(model.bottomToolWorldBooks[0].name, "Renamed book")
        XCTAssertEqual(model.bottomToolWorldBooks[0].detail, "2 个条目")
        XCTAssertFalse(model.bottomToolWorldBooks[0].enabled)
        XCTAssertTrue(model.bottomToolWorldBooks[0].selected, "Global disable preserves assistant selection")
        XCTAssertEqual(model.bottomToolWorldBooks.filter { $0.enabled && $0.selected }.count, 0)
        book.enabled = true
        book.description = "Updated description"
        model.upsertWorldBook(book)
        XCTAssertEqual(model.bottomToolWorldBooks[0].detail, book.description)
        XCTAssertEqual(model.bottomToolWorldBooks.filter { $0.enabled && $0.selected }.count, 1)
        let added = WorldBook(name: "Added book")
        model.upsertWorldBook(added)
        XCTAssertEqual(model.bottomToolWorldBooks.map(\.id), model.worldBooks.map(\.id))
        model.deleteWorldBook(book.id)
        XCTAssertFalse(model.bottomToolWorldBooks.contains { $0.id == book.id })
        XCTAssertFalse(model.isWorldBookActive(book.id))
    }

    func testInstructionEditsAndSelectionReachOpenMenu() {
        let model = fixture()
        var instruction = model.instructionInjections[0]
        instruction.title = "Renamed instruction"
        instruction.group = "New group"
        model.upsertInstruction(instruction)
        XCTAssertEqual(model.bottomToolInstructions[0].title, instruction.title)
        XCTAssertEqual(model.bottomToolInstructions[0].group, instruction.group)
        model.setInstructionActive(instruction.id, enabled: false)
        XCTAssertFalse(model.bottomToolInstructions[0].selected)
        model.toggleInstructionActive(instruction.id)
        XCTAssertTrue(model.bottomToolInstructions[0].selected)
        model.upsertInstruction(InstructionInjection(title: "Added"))
        XCTAssertEqual(model.bottomToolInstructions.count, 2)
        model.deleteInstruction(instruction.id)
        XCTAssertFalse(model.bottomToolInstructions.contains { $0.id == instruction.id })
    }

    func testAssistantSwitchAndRestoredMapsDoNotReusePreviousSelection() {
        let model = fixture(), a = model.assistants[0].id, b = model.assistants[1].id
        let first = model.worldBooks[0].id, second = model.worldBooks[1].id
        model.activeWorldBookIDsByAssistant[b.uuidString] = [second]
        model.currentAssistantID = b
        XCTAssertEqual(model.bottomToolWorldBooks.filter(\.selected).map(\.id), [second])
        XCTAssertTrue(model.bottomToolInstructions.allSatisfy { !$0.selected })
        model.setWorldBookActive(second, enabled: false)
        XCTAssertEqual(model.activeWorldBookIDsByAssistant[a.uuidString], [first])
        model.currentAssistantID = a
        XCTAssertEqual(model.bottomToolWorldBooks.filter(\.selected).map(\.id), [first])
        model.activeWorldBookIDsByAssistant = [a.uuidString: [second]]
        XCTAssertEqual(model.bottomToolWorldBooks.filter(\.selected).map(\.id), [second])
    }

    func testObservationTracksNestedSettingsAndAssistantChanges() {
        let model = fixture()
        let booksChanged = expectation(description: "World-book selection observed")
        withObservationTracking { _ = model.bottomToolWorldBooks } onChange: { booksChanged.fulfill() }
        model.setWorldBookActive(model.worldBooks[0].id, enabled: false)
        let instructionsChanged = expectation(description: "Instruction edit observed")
        withObservationTracking { _ = model.bottomToolInstructions } onChange: { instructionsChanged.fulfill() }
        model.deleteInstruction(model.instructionInjections[0].id)
        let assistantChanged = expectation(description: "Assistant ownership observed")
        withObservationTracking { _ = model.bottomToolWorldBooks } onChange: { assistantChanged.fulfill() }
        model.currentAssistantID = model.assistants[1].id
        wait(for: [booksChanged, instructionsChanged, assistantChanged], timeout: 1)
    }

    func testLiveSettingsDoNotResetNavigationOrUnsavedGroupSelection() {
        let model = fixture()
        model.bottomTools.route = .groupChat
        model.bottomTools.isEditingGroupChat = true
        model.bottomTools.selectedAssistantIDs = Set(model.assistants.map(\.id))
        let draft = model.bottomTools.selectedAssistantIDs
        model.setWorldBookActive(model.worldBooks[0].id, enabled: false)
        var assistant = model.currentAssistant
        assistant.name = "Edited assistant"
        assistant.searchEnabled = true
        assistant.thinkingBudget = 8192
        model.updateAssistant(assistant)
        XCTAssertEqual(model.currentAssistant.name, "Edited assistant")
        XCTAssertTrue(model.currentAssistant.searchEnabled)
        XCTAssertEqual(model.currentAssistant.thinkingBudget, 8192)
        XCTAssertEqual(model.bottomTools.route, .groupChat)
        XCTAssertTrue(model.bottomTools.isEditingGroupChat)
        XCTAssertEqual(model.bottomTools.selectedAssistantIDs, draft)
    }

    func testZZSeedSyntheticDataForUIRoundTrip() {
        let model = fixture()
        XCTAssertTrue(AssistantPersistence.saveAssistants(model.assistants))
        AssistantPersistence.saveCurrentAssistantID(model.currentAssistantID)
        PromptInjectionPersistence.saveWorldBooks(model.worldBooks)
        PromptInjectionPersistence.saveActiveWorldBookIDs(model.activeWorldBookIDsByAssistant)
        PromptInjectionPersistence.saveInstructions(model.instructionInjections)
        PromptInjectionPersistence.saveActiveInstructionIDs(model.activeInstructionIDsByAssistant)
    }
}
