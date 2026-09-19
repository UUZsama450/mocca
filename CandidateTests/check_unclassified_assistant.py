"""Production-extracted ownership/lifecycle checks using synthetic records only.

Runs real Conversation/AssistantProfile declarations, assignment and startup
migration, assistant deletion, title filtering and branch construction. UIKit,
memory prompt services and persistence I/O are replaced by deterministic hosts.
The conversation-deletion mutation is extracted up to its persistence boundary;
this does not claim full AppModel, SQLite, ZIP-import or phone UI acceptance.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = (root / 'Mocca/AppModel.swift').read_text()
models = (root / 'Mocca/AssistantModels.swift').read_text()
store = (root / 'Mocca/ConversationStore.swift').read_text()
drawer = (root / 'Mocca/RootView.swift').read_text()
backup = (root / 'Mocca/BackupService.swift').read_text()


def between(source, start, end):
    i = source.index(start)
    return source[i:source.index(end, i)]


# Import assignment must run on the merged profile/chat graph, before selection
# and the shared persistence boundary, for BOTH supported backup formats.
for start, end in [
    ('    func restoreBackup(', '    func restoreLegacyKelivoBackup('),
    ('    func restoreLegacyKelivoBackup(', '    private func restoreLegacySettings('),
]:
    body = between(app, start, end)
    assert body.count('collectUnclassifiedConversations()') == 1
    assert body.index('restoreConversationSnapshot(') < body.index('collectUnclassifiedConversations()')
    assert body.index('collectUnclassifiedConversations()') < body.index('repairConversationSelection()')
    assert body.index('repairConversationSelection()') < body.index('persistAllRestoredState(')
assert app.count('migrateUnclassifiedConversationsIfNeeded()') == 3  # declaration, launch, unlocked reload
persist = between(app, '    private func persistAllRestoredState(', '    private func merged<')
assert persist.index('guard AssistantPersistence.saveAssistants') < persist.index('let didSave = saveImmediately(')
assert 'if didSave {' in persist and 'forKey: UnclassifiedConversationOwnership.migrationKey' in persist

source = r'''
import Foundation
import CryptoKit
enum ConversationStore { static let currentSchemaVersion = 2 }
struct ModelSelection: Codable, Hashable, Sendable { var providerID: UUID; var modelID: String }
struct RecentMemorySettings: Codable, Hashable, Sendable { var isEnabled = false }
struct RecentMemoryState: Codable, Hashable, Sendable {}
enum RecentMemoryTokenEstimator {
    static func estimate(_ text: String) -> Int { text.count }
    static func prefix(_ text: String, maxTokens: Int) -> String { String(text.prefix(max(0, maxTokens))) }
}
enum Probe { static var writes: [String] = [] }
// Isolated in-memory preferences; never use the user's actual preference domain.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value; Probe.writes.append("marker") }
}
'''
source += between(store, 'struct Conversation:', 'struct ChatMessage:')
source += between(store, 'struct MigrationMetadata:', 'struct ConversationSnapshot:')
source += between(models, 'struct PresetMessage:', 'enum AssistantMediaStore')
source += between(backup, 'private func legacyStableUUID', 'private struct LegacyResolvedUserContent')
source += between(backup, 'private struct LegacyConversation', 'private struct LegacyMessage')
source += between(backup, 'private func legacyDate', 'private struct ZipArchiveWriter')
conversion_start = backup.index(') -> ConversationSnapshot {', backup.index('    func convertToNativeSnapshot('))
conversion_start = backup.index('{', conversion_start) + 1
conversion_end = backup.index('        var byConversation:', conversion_start)
source += 'private func importConversations(_ conversations: [LegacyConversation], assistantIDMap: [String: UUID]) -> [Conversation] {\n'
source += backup[conversion_start:conversion_end] + 'return nativeConversations\n}\n'
source += r'''
enum AssistantPersistence {
    static var fails = false
    static var saved: [AssistantProfile] = []
    @discardableResult
    static func saveAssistants(_ value: [AssistantProfile]) -> Bool {
        Probe.writes.append("assistants")
        guard !fails else { return false }
        saved = value; return true
    }
    static func saveCurrentAssistantID(_ id: UUID) {}
}
struct QuickPhrase { var isGlobal: Bool; var assistantID: String? }
struct Preferences { var groupAssistantBubbleColors: [String: Int] = [:]; var newChatAfterDelete = false }
enum AssistantMediaStore { static func remove(_ value: String?) {} }
enum QuickPhrasePersistence { static func save(_ value: [QuickPhrase]) {} }
enum AppPreferences { static func savePreferences(_ value: Preferences) {} }
struct SummaryRun { var task: Task<Void, Never> }
struct CompressionRun { var conversationID: UUID }
final class Host {
    var assistants: [AssistantProfile]
    var conversations: [Conversation]
    var messagesByConversation: [UUID: [Data]] = [:]
    var unsavedDraftConversationIDs = Set<UUID>()
    var currentAssistantID: UUID
    var selectedConversationID: UUID
    var currentAssistant: AssistantProfile { assistants.first { $0.id == currentAssistantID }! }
    var conversationPersistenceIsReady = true
    var failsSave = false
    var savedConversations: [Conversation] = []
    var savedMessages: [UUID: [Data]] = [:]
    var quickPhrases: [QuickPhrase] = []
    var preferences = Preferences()
    var conversationSummaryRuns: [UUID: SummaryRun] = [:]
    var contextCompressionRun: CompressionRun?
    var isCompressingContext = false
    var messageWindowsByConversation: [UUID: Int] = [:]
    var groupReplyTargetByConversation: [UUID: String] = [:]
    var groupReplyRoundsByConversation: [UUID: Int] = [:]
    var groupRandomFirstConversationIDs = Set<UUID>()
    var errors: [String] = []
    init(_ assistants: [AssistantProfile], _ conversations: [Conversation]) {
        self.assistants = assistants; self.conversations = conversations
        currentAssistantID = assistants[0].id
        selectedConversationID = conversations.first?.id ?? UUID()
    }
    func requireConversationPersistence() -> Bool { conversationPersistenceIsReady }
    func presentError(_ message: String) { errors.append(message) }
    func blockConversationPersistence(_ message: String) {
        conversationPersistenceIsReady = false; errors.append(message)
    }
    func presentConversationPersistenceErrorIfForeground() {}
    func stopStreaming(ifConversationID: UUID) {}
    func discardComposerPackets(for ids: Set<UUID>) {}
    func resetMessageWindowToLatest(for id: UUID) {}
    func resortConversations() {}
    @discardableResult
    func saveImmediately(allowDestructiveConversationReduction: Bool = false,
                         allowDestructiveMessageReduction: Bool = false) -> Bool {
        Probe.writes.append("conversations")
        guard !failsSave else { conversationPersistenceIsReady = false; return false }
        savedConversations = conversations.filter { !unsavedDraftConversationIDs.contains($0.id) }
        savedMessages = messagesByConversation
        return true
    }
    func launch() { migrateUnclassifiedConversationsIfNeeded() }
    func collectImport() { collectUnclassifiedConversations() }
'''
source += '@discardableResult\n' + between(app, '    private func collectUnclassifiedConversations()', '    private var conversationPersistenceIsReady:')
source += between(app, '    var visibleConversations:', '    var selectedConversationIsGroupChat:')
source += between(app, '    func deleteAssistant(', '    func selectConversation(')
source += 'func finishImport() -> Bool {\nlet allowDestructiveConversationReduction = false\nlet allowDestructiveMessageReduction = false\n'
source += between(persist, '        guard AssistantPersistence.saveAssistants', '        AppPreferences.saveAppearanceMode(')
source += persist[persist.index('        let didSave = saveImmediately('):]
source += 'func branchShell(_ sourceConversation: Conversation) -> Conversation {\n'
branch = between(app, '    func branchConversation(', '    func createGroupConversation(')
source += between(branch, '        let now = Date()', '        let clonedMessages =')
source += 'return branch\n}\n'
deletion = between(app, '    func deleteConversations(', '    func deleteAllConversations(')
source += deletion[:deletion.index('        let didSave = saveImmediately(')]
source += '_ = affectedAssistantIDs\nsaveImmediately(allowDestructiveConversationReduction: true, allowDestructiveMessageReduction: true)\n}\n}\n'
source += '''
final class DrawerHost {
    var model: Host
    var groupChatMode = false
    var query = ""
    var assistantsExpanded = false
    enum Scope { case title, content }
    var searchScope: Scope = .title
    init(_ model: Host) { self.model = model }
    func matches(_ value: String) -> [Conversation] { query = value; return filteredConversations }
'''
source += between(drawer, '    private var sourceConversations:', '    private var filteredAssistants:')
source += '}\n'
source += r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(name)") }
    print("PASS: \(name)")
}
func encoded<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try! encoder.encode(value)
}
func reset() {
    UserDefaults.standard.values = [:]; AssistantPersistence.fails = false
    AssistantPersistence.saved = []; Probe.writes = []
}
func destinationID(_ host: Host) -> UUID? {
    host.assistants.first {
        $0.migrationMetadata?.source == UnclassifiedConversationOwnership.assistantSource
    }?.id
}
let owner = AssistantProfile(name: "正常助手")
let other = AssistantProfile(name: "另一个助手")
let migrationKey = UnclassifiedConversationOwnership.migrationKey
let legacyMetadata = MigrationMetadata(source: "old_kelivo", sourceID: "legacy-chat",
    sourceSchemaVersion: 1, importedAt: Date(timeIntervalSince1970: 100),
    notes: ["oldAssistantID": "missing-legacy-assistant"])
let orphan = Conversation(title: "蜜蜂为什么会蛰人", createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 2), isPinned: true, truncateIndex: 5,
    versionSelections: ["reply": 2], summary: "原摘要", lastSummarizedMessageCount: 4,
    chatSuggestions: ["原建议"], providerID: "provider", modelID: "model", migrationMetadata: legacyMetadata)
let missingOwner = Conversation(title: "缺失原助手", assistantID: UUID().uuidString)
let owned = Conversation(title: "正常对话", assistantID: owner.id.uuidString)
let group = Conversation(title: "缺失群成员", assistantID: UUID().uuidString,
    groupAssistantIDs: [owner.id.uuidString, UUID().uuidString])
let draft = Conversation()
let original = [orphan, missingOwner, owned, group, draft]
let messageBytes = Data("opaque original message: attachment IDs; version groups; author IDs".utf8)

reset()
let host = Host([owner, other], original)
host.unsavedDraftConversationIDs = [draft.id]
host.messagesByConversation = [orphan.id: [messageBytes], missingOwner.id: [Data([0, 1, 2])]]
let originalMessages = host.messagesByConversation
host.launch()
let destination = destinationID(host)!
check(host.assistants.count == 3, "one ordinary destination assistant is created")
check(host.conversations[0].assistantID == destination.uuidString && host.conversations[1].assistantID == destination.uuidString,
      "nil and dangling single-chat owners are collected")
for i in original.indices {
    var restored = host.conversations[i]; restored.assistantID = original[i].assistantID
    check(encoded(restored) == encoded(original[i]), "all other conversation fields preserved: \(i)")
}
check(Array(host.conversations[2...]) == Array(original[2...]), "owned chats, groups and unsaved drafts stay intact")
check(host.messagesByConversation == originalMessages, "migration does not access or rewrite messages")
check(Probe.writes == ["assistants", "conversations", "marker"], "save order: destination, references, completion marker")
let container = host.assistants.first { $0.id == destination }!
check(container.name == "未分类" && !container.enableMemory && !container.recentMemorySettings.isEnabled,
      "ordinary default assistant has memory disabled")
check(container.systemPrompt.isEmpty && container.chatModel == nil && container.memories.isEmpty,
      "missing original persona and model are not invented")
check(host.currentAssistantID == owner.id, "migration preserves current assistant selection")
host.currentAssistantID = destination
check(Set(host.visibleConversations.map(\.id)) == Set([orphan.id, missingOwner.id]), "title list contains collected chats")
let drawerHost = DrawerHost(host)
check(drawerHost.matches(" 蜜蜂 ").map(\.id) == [orphan.id], "actual drawer title filter finds original title")
let branch = host.branchShell(host.conversations[0])
check(branch.id != orphan.id && branch.assistantID == destination.uuidString, "production branch constructor inherits valid destination")
host.conversations.append(branch)
check(host.visibleConversations.contains { $0.id == branch.id }, "new branch is in the same assistant list")
let once = encoded(host.conversations)
Probe.writes = []; host.launch()
check(Probe.writes.isEmpty && encoded(host.conversations) == once, "subsequent launch skips migration and all migration writes")

let renamedIndex = host.assistants.firstIndex { $0.id == destination }!
host.assistants[renamedIndex].name = "旧聊天合集"
host.assistants[renamedIndex].systemPrompt = "用户自己的设定"
let renamed = host.assistants[renamedIndex]
host.conversations.append(Conversation(title: "新导入的无主聊天"))
host.collectImport()
check(host.assistants.count == 3 && host.assistants[renamedIndex] == renamed,
      "later import reuses fixed identity and preserves renamed assistant settings")
check(host.conversations.last!.assistantID == destination.uuidString, "later import is collected despite completed launch marker")

let encodedProfiles = encoded(host.assistants)
let encodedChats = encoded(host.conversations.filter { !host.unsavedDraftConversationIDs.contains($0.id) })
let reopened = Host(try! JSONDecoder().decode([AssistantProfile].self, from: encodedProfiles),
                    try! JSONDecoder().decode([Conversation].self, from: encodedChats))
reopened.messagesByConversation = originalMessages
reopened.currentAssistantID = destination
reopened.launch()
check(reopened.visibleConversations.contains { $0.id == orphan.id }, "JSON reopen preserves collection and visibility")
reopened.deleteConversations([orphan.id])
reopened.launch()
check(!reopened.conversations.contains { $0.id == orphan.id } && reopened.messagesByConversation[orphan.id] == nil,
      "actual conversation deletion removes target and its messages without resurrection")
check(reopened.assistants.contains { $0.id == destination }, "deleting a conversation retains its assistant")
check(reopened.messagesByConversation[missingOwner.id] == originalMessages[missingOwner.id], "deleting one chat preserves the other messages")
reopened.deleteAssistant(destination)
let afterDeletion = encoded(reopened.conversations)
reopened.launch()
check(!reopened.assistants.contains { $0.id == destination }, "deleted destination is not recreated on restart")
check(!reopened.conversations.contains { $0.assistantID == destination.uuidString }, "assistant deletion removes all its single chats including branches")
check(reopened.messagesByConversation[missingOwner.id] == nil, "assistant deletion removes its message records")
check(reopened.conversations.contains(owned) && reopened.conversations.contains(group), "deletion preserves unrelated chats and groups")
check(encoded(reopened.conversations) == afterDeletion, "restart cannot regenerate deleted conversations")
reopened.collectImport()
check(!reopened.assistants.contains { $0.id == destination }, "import with no new unowned records creates no empty destination")
reopened.conversations.append(orphan)  // Explicitly importing a backup may restore its records.
reopened.collectImport()
let recreatedDestination = destinationID(reopened)!
check(recreatedDestination != destination && reopened.conversations.last!.assistantID == recreatedDestination.uuidString,
      "explicit import creates a fresh identity after deletion, avoiding stale bindings")

reset()
let collision = AssistantProfile(name: "未分类", systemPrompt: "unrelated user assistant")
let collisions = Host([owner, collision], [orphan])
collisions.launch()
check(collisions.assistants.count == 3 && collisions.assistants[1] == collision,
      "same display name never captures an unrelated assistant")

reset()
let noOrphans = Host([owner], [owned, group])
noOrphans.launch()
check(noOrphans.assistants == [owner] && Probe.writes == ["marker"], "no missing owners means no profile or conversation write")
reset()
let blocked = Host([owner], [orphan]); blocked.conversationPersistenceIsReady = false
blocked.launch()
check(Probe.writes.isEmpty && blocked.conversations == [orphan], "blocked store does not migrate or mark completion")
blocked.conversationPersistenceIsReady = true; blocked.launch()
check(blocked.conversations[0].assistantID == destinationID(blocked)?.uuidString, "successful later load can perform the pending migration")

reset()
let profileFailure = Host([owner], [orphan]); AssistantPersistence.fails = true
profileFailure.launch()
check(profileFailure.assistants == [owner] && profileFailure.conversations == [orphan], "profile save failure restores original in-memory graph")
check(!UserDefaults.standard.bool(forKey: migrationKey) && Probe.writes == ["assistants"], "profile save failure cannot write conversations or completion")
AssistantPersistence.fails = false; profileFailure.launch()
check(profileFailure.assistants.count == 2 && profileFailure.savedConversations[0].assistantID == destinationID(profileFailure)?.uuidString,
      "profile save retry creates exactly one durable destination")

reset()
let chatFailure = Host([owner], [orphan]); chatFailure.failsSave = true
chatFailure.launch()
check(chatFailure.conversations == [orphan] && !UserDefaults.standard.bool(forKey: migrationKey),
      "chat save failure preserves old ownership and leaves migration pending")
let interruptedDestination = destinationID(chatFailure)!
check(AssistantPersistence.saved.contains { $0.id == interruptedDestination }, "destination exists before any possible committed reference")
let afterCrash = Host(AssistantPersistence.saved, [orphan]); afterCrash.launch()
check(afterCrash.assistants.count == 2 && afterCrash.conversations[0].assistantID == interruptedDestination.uuidString,
      "restart after interrupted chat save reuses destination without duplication")
UserDefaults.standard.values = [:]  // Crash after data commit but before marker persistence.
let afterCommitCrash = Host(afterCrash.assistants, afterCrash.conversations)
Probe.writes = []; afterCommitCrash.launch()
check(Probe.writes == ["marker"] && afterCommitCrash.assistants.count == 2,
      "restart after data commit only completes marker, without rewriting records")

reset()
private let legacy = [
    ["id": "known", "assistantId": "known-old", "title": "owned"],
    ["id": "missing", "assistantId": "missing-old", "title": "lost profile"],
    ["id": "nil", "title": "no owner"],
    ["id": "group", "assistantId": "known-old", "groupAssistantIds": ["known-old", "missing-old"]]
].compactMap { LegacyConversation(json: $0) }
let imported = importConversations(legacy, assistantIDMap: ["known-old": owner.id])
let importedHost = Host([owner], imported); importedHost.collectImport()
let importedDestination = destinationID(importedHost)!
check(importedHost.conversations[0].assistantID == owner.id.uuidString, "legacy known owner remains mapped to original assistant")
check(importedHost.conversations[1].assistantID == importedDestination.uuidString && importedHost.conversations[2].assistantID == importedDestination.uuidString,
      "actual legacy conversion plus collection handles dangling and absent owners")
check(importedHost.conversations[3] == imported[3], "legacy group membership remains byte-equivalent after collection")
check(importedHost.conversations[1].migrationMetadata?.notes["oldAssistantID"] == "missing-old", "collection preserves original legacy owner metadata")
let repeated = importConversations(legacy, assistantIDMap: ["known-old": owner.id])
check(imported.map(\.id) == repeated.map(\.id), "repeat legacy import retains conversation identities")
check(encoded(importedHost.conversations).count > 0, "collected records remain encodable")
check(importedHost.finishImport() && UserDefaults.standard.bool(forKey: migrationKey),
      "actual import persistence boundary commits destination before migration marker")

reset()
let importProfileFailure = Host([owner], [orphan]); importProfileFailure.collectImport()
AssistantPersistence.fails = true
check(!importProfileFailure.finishImport() && !importProfileFailure.conversationPersistenceIsReady,
      "failed import profile save blocks later conversation writes with unresolved references")
check(Probe.writes == ["assistants"] && !UserDefaults.standard.bool(forKey: migrationKey),
      "failed import cannot mark migration complete or write conversation references")
reset()
let importChatFailure = Host([owner], [orphan]); importChatFailure.collectImport(); importChatFailure.failsSave = true
check(!importChatFailure.finishImport() && !UserDefaults.standard.bool(forKey: migrationKey),
      "failed import conversation commit leaves completion marker unset")
print("RESULT: \(checks) checks passed; integration call-site checks passed")
'''

with tempfile.TemporaryDirectory(prefix='mocca-unclassified-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
