"""Run the actual Foundation model and sidebar predicate against synthetic legacy data.

This is an offline policy check, not an AppModel lifecycle or iPhone UI test.
Only unrelated framework/storage dependencies are stubbed; production declarations
are extracted verbatim so this catches the original nil-owner wildcard.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
store = (root / "Mocca/ConversationStore.swift").read_text()
app = (root / "Mocca/AppModel.swift").read_text()
backup = (root / "Mocca/BackupService.swift").read_text()


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


source = "import Foundation\nimport CryptoKit\n"
source += "enum ConversationStore { static let currentSchemaVersion = 2 }\n"
source += between(store, "struct Conversation:", "struct ChatMessage:")
source += between(store, "struct MigrationMetadata:", "struct ConversationSnapshot:")
source += between(backup, "private func legacyStableUUID", "private struct LegacyResolvedUserContent")
source += between(backup, "private struct LegacyConversation", "private struct LegacyMessage")
source += between(backup, "private func legacyDate", "private struct ZipArchiveWriter")
# Execute the production conversation-conversion block, including its real JSON
# decoder and deterministic ID mapping. Message/attachment conversion is outside
# this lightweight test and is covered by the full application build only.
conversion_start = backup.index(") -> ConversationSnapshot {", backup.index("    func convertToNativeSnapshot("))
conversion_start = backup.index("{", conversion_start) + 1
conversion_end = backup.index("        var byConversation:", conversion_start)
source += "private func importConversations(_ conversations: [LegacyConversation], assistantIDMap: [String: UUID]) -> [Conversation] {\n"
source += backup[conversion_start:conversion_end]
source += "return nativeConversations\n}\n"
source += """
final class SidebarFixture {
    var conversations: [Conversation]
    var currentAssistantID: UUID
    var selectedConversationID = UUID()
    var messagesByConversation: [UUID: [String]] = [:]
    var unsavedDraftConversationIDs = Set<UUID>()
    init(conversations: [Conversation], currentAssistantID: UUID) {
        self.conversations = conversations
        self.currentAssistantID = currentAssistantID
    }
    private func resetMessageWindowToLatest(for id: UUID) {}
    func repair() { repairConversationSelection() }
"""
source += between(app, "    var visibleConversations:", "    var selectedConversationIsGroupChat:")
source += between(app, "    private func repairConversationSelection()", "    private func persistAllRestoredState(")
source += "func restoreLaunchSelection() {\n"
source += between(app, "        let visibleAssistantID = currentAssistantID.uuidString", "        repairSelection()")
source += "}\nfunc bindFreshPlaceholder() {\n"
source += between(app, "        // Only the fresh, unsaved launch placeholder", "        let summaryCursorMigrationApplied =")
source += "}\nfunc recover(_ sortedConversations: [Conversation], messages: [UUID: [String]]) {\n"
source += "let loadedSnapshot = (messagesByConversation: messages, unused: false)\n"
source += between(app, "            let visibleAssistantID = currentAssistantID.uuidString", "            lastPersistedConversationCount =")
source += "}\n"
source += "}\n"
source += r'''
let owner = UUID(), other = UUID(), newAssistant = UUID()
let orphans = (0..<7).map { index in
    Conversation(title: "legacy-\(index)", migrationMetadata: MigrationMetadata(
        source: "old_kelivo", notes: ["oldAssistantID": "deleted-assistant"]))
}
let owned = Conversation(title: "owned", assistantID: owner.uuidString)
let otherChat = Conversation(title: "other", assistantID: other.uuidString)
let group = Conversation(title: "group", assistantID: owner.uuidString,
                         groupAssistantIDs: [owner.uuidString, other.uuidString])
let records = orphans + [owned, otherChat, group]
var failures = 0
func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition { failures += 1 }
}
var fixture = SidebarFixture(conversations: records, currentAssistantID: newAssistant)
check(fixture.visibleConversations.isEmpty, "new assistant has no inherited conversations")
fixture.currentAssistantID = owner
check(fixture.visibleConversations.map(\.id) == [owned.id], "existing assistant sees only owned single chats")
fixture.currentAssistantID = other
check(fixture.visibleConversations.map(\.id) == [otherChat.id], "switching assistants does not transfer orphan ownership")
check(fixture.conversations == records, "visibility checks preserve every stored record")
let encoded = try JSONEncoder().encode(records)
let decoded = try JSONDecoder().decode([Conversation].self, from: encoded)
fixture = SidebarFixture(conversations: decoded, currentAssistantID: newAssistant)
check(fixture.visibleConversations.isEmpty, "saved legacy records remain isolated after decoding")
check(decoded.count == 10 && decoded.filter { $0.assistantID == nil }.count == 7,
      "JSON round trip preserves orphan records and metadata")
let oldOwner = "existing-legacy-owner", oldDeleted = "deleted-legacy-owner"
let legacyJSON: [[String: Any]] = [
    ["id": "legacy-owned", "assistantId": oldOwner, "title": "keep"],
    ["id": "legacy-orphan", "assistantId": oldDeleted, "title": "orphan"],
    ["id": "legacy-group", "assistantId": oldOwner,
     "groupAssistantIds": [oldOwner, oldDeleted], "title": "group"],
    ["id": "legacy-unassigned", "title": "unassigned"]
]
private let legacy = legacyJSON.compactMap(LegacyConversation.init(json:))
let imported = importConversations(legacy, assistantIDMap: [oldOwner: owner])
let repeated = importConversations(legacy, assistantIDMap: [oldOwner: owner])
check(imported[0].assistantID == owner.uuidString, "import preserves a known assistant mapping")
check(imported[1].assistantID != nil && imported[1].assistantID != owner.uuidString,
      "import retains deleted assistant identity without assigning a different owner")
check(imported.map(\.assistantID) == repeated.map(\.assistantID), "repeated imports preserve ownership IDs")
check(imported[2].groupAssistantIDs.count == 2 &&
      imported[2].groupAssistantIDs.contains(imported[1].assistantID ?? ""),
      "missing group member does not turn a group into a single chat")
check(imported[3].assistantID == nil, "truly missing source ownership stays unassigned")
fixture = SidebarFixture(conversations: imported, currentAssistantID: newAssistant)
check(fixture.visibleConversations.isEmpty, "future imports cannot populate a new assistant sidebar")
fixture.currentAssistantID = owner
check(fixture.visibleConversations.map(\.id) == [imported[0].id], "imported normal chats remain visible to their owner")
check(imported[1].migrationMetadata?.notes["oldAssistantID"] == oldDeleted &&
      imported.map(\.title) == ["keep", "orphan", "group", "unassigned"],
      "import retains legacy metadata and conversation content")
fixture = SidebarFixture(conversations: records, currentAssistantID: newAssistant)
fixture.selectedConversationID = orphans[0].id
fixture.messagesByConversation[orphans[0].id] = ["preserve this legacy message"]
fixture.repair()
check(fixture.visibleConversations.contains { $0.id == fixture.selectedConversationID },
      "restoring a stale orphan selection creates or selects an owned chat")
check(Set(records.map(\.id)).isSubset(of: Set(fixture.conversations.map(\.id))) &&
      fixture.messagesByConversation[orphans[0].id] == ["preserve this legacy message"],
      "selection repair preserves all orphan conversations and messages")
let selectedAfterRepair = fixture.selectedConversationID
let countAfterRepair = fixture.conversations.count
fixture.repair()
check(fixture.selectedConversationID == selectedAfterRepair && fixture.conversations.count == countAfterRepair,
      "selection repair is idempotent")
fixture.currentAssistantID = owner
fixture.selectedConversationID = group.id
fixture.repair()
check(fixture.selectedConversationID == group.id, "explicit group selection remains valid")
fixture = SidebarFixture(conversations: records, currentAssistantID: newAssistant)
fixture.selectedConversationID = orphans[0].id
fixture.restoreLaunchSelection()
check(fixture.visibleConversations.contains { $0.id == fixture.selectedConversationID } &&
      Set(records.map(\.id)).isSubset(of: Set(fixture.conversations.map(\.id))),
      "cold launch selects an owned empty chat while retaining historical records")
let fresh = Conversation()
fixture = SidebarFixture(conversations: orphans + [fresh], currentAssistantID: newAssistant)
fixture.unsavedDraftConversationIDs.insert(fresh.id)
fixture.bindFreshPlaceholder()
check(fixture.visibleConversations.map(\.id) == [fresh.id] &&
      fixture.conversations.filter { $0.assistantID == nil }.count == 7,
      "first-launch ownership is assigned only to the newly created placeholder")
fixture.recover(records, messages: [orphans[0].id: ["original content"]])
check(fixture.visibleConversations.contains { $0.id == fixture.selectedConversationID } &&
      Set(records.map(\.id)).isSubset(of: Set(fixture.conversations.map(\.id))) &&
      fixture.messagesByConversation[orphans[0].id] == ["original content"],
      "recovery without an owned chat preserves the restored graph and selects an empty chat")
fixture.currentAssistantID = owner
fixture.recover(records, messages: [owned.id: ["owned content"]])
check(fixture.selectedConversationID == owned.id && fixture.conversations == records,
      "recovery with an owned chat selects it without adding a placeholder")
exit(failures == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(prefix="mocca-ownership-check-") as temp:
    swift = Path(temp) / "main.swift"
    swift.write_text(source)
    executable = Path(temp) / "check"
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(executable)], check=True)
    raise SystemExit(subprocess.run([str(executable)]).returncode)
