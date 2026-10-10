"""Compile the production resolver/mutator and Conversation Codable in a Foundation host.

External provider/storage boundaries are fixtures. The host never opens app data.
"""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / "work/group-members-5177/model-tests"
out.mkdir(parents=True, exist_ok=True)

def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{": depth += 1
        if source[end] == "}": depth -= 1
        end += 1
    return source[start:end]

model = (root / "Mocca/AppModel.swift").read_text()
store = (root / "Mocca/ConversationStore.swift").read_text()
provider = (root / "Mocca/ProviderModels.swift").read_text()
types = [declaration(store, "struct Conversation:"), declaration(store, "struct MigrationMetadata:"),
         declaration(provider, "struct ModelSelection:")]
methods = [declaration(model, marker) for marker in [
    "internal func resolvedChatModel(", "func modelContext(",
    "func groupChatModelSelection(", "func selectGroupChatModel("
]]
fixture = '''
import Foundation
enum ConversationStore { static let currentSchemaVersion = 1 }
struct AssistantProfile { let id: UUID; var chatModel: ModelSelection? }
struct ModelConfiguration {
    let id: String
    struct Capabilities { enum Kind { case chat }; let kind = Kind.chat }
    let capabilities = Capabilities()
}
struct ProviderConfiguration { let id: UUID; var enabled: Bool; var models: [ModelConfiguration] }
struct ResolvedChatModelContext {
    let selection: ModelSelection; let provider: ProviderConfiguration; let model: ModelConfiguration
}
final class AppModel {
    var providers: [ProviderConfiguration] = []
    var conversations: [Conversation] = []
    var selectedModel: ModelSelection?
    var selectedConversationID = UUID()
    var canSave = true
    var persisted: Data?
    func requireConversationPersistence() -> Bool { true }
    func saveImmediately() -> Bool {
        guard canSave else { return false }
        persisted = try! JSONEncoder().encode(conversations)
        return true
    }
'''
source = "import Foundation\n" + "\n".join(types) + fixture + "\n".join(methods) + "\n}"
(out / "Production.swift").write_text(source)
subprocess.run(["xcrun", "swiftc", str(out / "Production.swift"), str(root / "CandidateTests/GroupMemberModelTests.swift"), "-o", str(out / "tests")], check=True)
result = subprocess.check_output([str(out / "tests")], text=True)
(out / "result.txt").write_text(result)
# Verify every reply entry point supplies its originating conversation, not current UI state.
for marker, required in [
    ("func sendDraft(", "hasReadyChatModel(for: replyAssistant, conversationID: conversationID)"),
    ("func regenerateResponse(", "activeProviderContext(for: replyAssistant, conversationID: location.conversationID)"),
    ("func continueResponse(", "activeProviderContext(for: replyAssistant, conversationID: location.conversationID)"),
    ("private func startGroupAssistantStreams(", "activeProviderContext(for: assistant, conversationID: conversationID)")
]:
    assert required in declaration(model, marker), marker
(out / "provenance.json").write_text(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [root / "Mocca/AppModel.swift", root / "Mocca/ConversationStore.swift", root / "Mocca/ProviderModels.swift"]}, indent=2))
print(result.strip())
print("PASS conversation identity at send, regenerate, continue and group-turn call sites")
