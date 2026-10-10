import Foundation

@main enum GroupMemberModelTests {
    static func main() throws {
        let providerID = UUID()
        let defaultModel = ModelSelection(providerID: providerID, modelID: "default")
        let alternate = ModelSelection(providerID: providerID, modelID: "alternate")
        let a = AssistantProfile(id: UUID(), chatModel: defaultModel)
        let b = AssistantProfile(id: UUID(), chatModel: nil)
        let outsider = AssistantProfile(id: UUID(), chatModel: defaultModel)
        let group = Conversation(groupAssistantIDs: [a.id.uuidString, b.id.uuidString])
        let otherGroup = Conversation(groupAssistantIDs: group.groupAssistantIDs)
        let single = Conversation(assistantID: a.id.uuidString)
        let model = AppModel()
        model.providers = [ProviderConfiguration(id: providerID, enabled: true, models: [
            ModelConfiguration(id: "default"), ModelConfiguration(id: "alternate")
        ])]
        model.selectedModel = defaultModel
        model.conversations = [group, otherGroup, single]

        precondition(model.selectGroupChatModel(alternate, for: a.id, conversationID: group.id))
        precondition(model.modelContext(for: a, conversationID: group.id)?.selection == alternate)
        precondition(model.modelContext(for: b, conversationID: group.id)?.selection == defaultModel)
        precondition(model.modelContext(for: a, conversationID: otherGroup.id)?.selection == defaultModel)
        precondition(model.modelContext(for: a, conversationID: single.id)?.selection == defaultModel)
        precondition(model.modelContext(for: a)?.selection == defaultModel)
        precondition(a.chatModel == defaultModel && model.selectedModel == defaultModel)

        // The exact Conversation Codable type used by the record store round-trips the override.
        let reloaded = try JSONDecoder().decode([Conversation].self, from: model.persisted!)
        precondition(reloaded[0].groupModelSelections?[a.id.uuidString] == alternate)
        precondition(reloaded[1].groupModelSelections == nil)
        let newData = try JSONEncoder().encode(reloaded[0])
        var legacy = try JSONSerialization.jsonObject(with: newData) as! [String: Any]
        legacy.removeValue(forKey: "groupModelSelections")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyConversation = try JSONDecoder().decode(Conversation.self, from: legacyData)
        precondition(legacyConversation.groupModelSelections == nil)

        precondition(!model.selectGroupChatModel(alternate, for: outsider.id, conversationID: group.id))
        precondition(!model.selectGroupChatModel(alternate, for: a.id, conversationID: single.id))
        precondition(!model.selectGroupChatModel(alternate, for: a.id, conversationID: UUID()))
        let invalid = ModelSelection(providerID: providerID, modelID: "missing")
        precondition(!model.selectGroupChatModel(invalid, for: a.id, conversationID: group.id))
        model.canSave = false
        precondition(!model.selectGroupChatModel(defaultModel, for: a.id, conversationID: group.id))
        precondition(model.groupChatModelSelection(for: a.id, conversationID: group.id) == alternate)
        model.canSave = true
        precondition(model.selectGroupChatModel(nil, for: a.id, conversationID: group.id))
        precondition(model.modelContext(for: a, conversationID: group.id)?.selection == defaultModel)
        precondition(model.conversations[0].groupModelSelections == nil)

        // Stale membership cannot apply an old override after a member leaves.
        model.conversations[0].groupModelSelections = [outsider.id.uuidString: alternate]
        precondition(model.modelContext(for: outsider, conversationID: group.id)?.selection == defaultModel)
        // The originating conversation resolves correctly even when another chat is selected.
        model.conversations[0].groupModelSelections = [a.id.uuidString: alternate]
        model.selectedConversationID = otherGroup.id
        precondition(model.modelContext(for: a, conversationID: group.id)?.selection == alternate)
        print("PASS group isolation, member isolation, persistence, legacy decoding, reset, invalid selection and save rollback")
    }
}
