// Tests use production files/settings/transaction/rollback implementations.
// Security API entry points are redirected to this in-memory fixture only.
struct ProviderKey: Codable { var key: String; var enabled: Bool }
struct ProviderConfiguration { var id: UUID; var apiKey: String; var apiKeys: [ProviderKey] }
struct SearchConfiguration { var id: UUID; var apiKey: String; var password: String }
struct VoiceConfiguration { var id: UUID; var apiKey: String }
struct UserPreferences { var searchServices: [SearchConfiguration]; var voiceServices: [VoiceConfiguration] }

// Persistence APIs are fault-injection dependencies of the actual production
// persistAllRestoredState body. The calendar write still uses the real filesystem.
var fixtureSupport = URL(fileURLWithPath: "/unused-fixture-path")
var commitFailure: String?
var commitCalls: [String] = []
func stored(_ value: Int, _ key: String) {
    commitCalls.append(key)
    if commitFailure != key { fixtureDefaults.set(try! JSONEncoder().encode(value), forKey: key) }
}
enum AssistantPersistence {
    static func saveAssistants(_ value: Int) -> Bool { commitCalls.append("assistants"); return commitFailure != "assistants" }
    static func saveCurrentAssistantID(_ value: Int) {}
}
enum AppPreferences {
    static func saveAppearanceMode(_ value: Int) {}
    static func savePreferences(_ value: UserPreferences) -> Bool { commitCalls.append("preferences"); return commitFailure != "preferences" }
}
enum ProviderPersistence {
    static func saveProviders(_ value: [ProviderConfiguration]) -> Bool { commitCalls.append("providers"); return commitFailure != "providers" }
    static func saveSelection(_ value: Int) {}
    static func saveFavoriteModelKeys(_ value: Int) {}
    static func saveFavoriteProviderIDs(_ value: Int) {}
}
enum PromptInjectionPersistence {
    static func saveInstructions(_ value: Int) { stored(value, "instruction_injections_v1") }
    static func saveActiveInstructionIDs(_ value: Int) { stored(value, "instruction_active_ids_by_assistant_v1") }
    static func saveWorldBooks(_ value: Int) { stored(value, "world_books_v1") }
    static func saveActiveWorldBookIDs(_ value: Int) { stored(value, "world_book_active_ids_by_assistant_v1") }
}
enum QuickPhrasePersistence { static func save(_ value: Int) { stored(value, "quick_phrases_v1") } }
enum UserProfilePersistence { static func save(_ value: Int) { stored(value, "user_profile_v1") } }
enum UnclassifiedConversationOwnership { static let migrationKey = "fixture.migration" }
enum MoccaCalendarNotificationScheduler { static func reschedule(events: Int) async {} }

let suite = "mocca.backup-host." + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: suite)!
var keychain: [[String: Any]] = []
var securityFailure: String?
func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
    [kSecAttrService as String, kSecAttrAccount as String, kSecAttrAccessGroup as String].allSatisfy {
        query[$0] == nil || item[$0] as? String == query[$0] as? String
    }
}
func fixtureSecItemCopyMatching(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    if securityFailure == "read" { return errSecInteractionNotAllowed }
    let values = keychain.filter { matches($0, query as! [String: Any]) }
    guard !values.isEmpty else { return errSecItemNotFound }
    output?.pointee = values as NSArray
    return errSecSuccess
}
func fixtureSecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    if securityFailure == "update" { return errSecAuthFailed }
    let indices = keychain.indices.filter { matches(keychain[$0], query as! [String: Any]) }
    guard !indices.isEmpty else { return errSecItemNotFound }
    for i in indices { keychain[i].merge(attributes as! [String: Any]) { _, new in new } }
    return errSecSuccess
}
func fixtureSecItemAdd(_ attributes: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    if securityFailure == "add" { return errSecAuthFailed }
    keychain.append(attributes as! [String: Any])
    return errSecSuccess
}
func fixtureSecItemDelete(_ query: CFDictionary) -> OSStatus {
    if securityFailure == "delete" { return errSecAuthFailed }
    let before = keychain.count
    keychain.removeAll { matches($0, query as! [String: Any]) }
    return before == keychain.count ? errSecItemNotFound : errSecSuccess
}
func credential(_ service: String, _ account: String, _ value: String,
                group: String = "fixture.group") -> [String: Any] {
    [kSecAttrService as String: "com.uuzsama450.mocca." + service,
     kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
     kSecAttrAccessGroup as String: group,
     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String]
}

enum Injected: Error { case failure }
final class FailingFileManager: FileManager, @unchecked Sendable {
    var fail: ((String, URL, URL?) -> Bool)?
    var operations: [String] = []
    override func moveItem(at source: URL, to destination: URL) throws {
        operations.append("move:\(source.lastPathComponent)->\(destination.lastPathComponent)")
        if fail?("move", source, destination) == true { throw Injected.failure }
        try super.moveItem(at: source, to: destination)
    }
    override func copyItem(at source: URL, to destination: URL) throws {
        if fail?("copy", source, destination) == true { throw Injected.failure }
        try super.copyItem(at: source, to: destination)
    }
    override func removeItem(at url: URL) throws {
        if fail?("remove", url, nil) == true { throw Injected.failure }
        try super.removeItem(at: url)
    }
}
var fixtureFileManager = FailingFileManager()
let root = FileManager.default.temporaryDirectory.appendingPathComponent("mocca-backup-host-" + UUID().uuidString)
var assertions = 0
var cases = 0
func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
    assertions += 1
    guard condition() else { fatalError("FAIL: " + reason) }
}
func expectFailure(_ reason: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure: " + reason) } catch { assertions += 1 }
}
func sandbox(_ name: String, _ body: (URL) throws -> Void) throws {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    fixtureFileManager = FailingFileManager()
    fixtureDefaults.removePersistentDomain(forName: suite)
    keychain = []; securityFailure = nil
    try body(url)
    cases += 1
}
func put(_ url: URL, _ value: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
}
func get(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }
func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
func summary(_ count: Int) -> BackupImportSummary {
    BackupImportSummary(importedProviders: 0, importedAssistants: 0, importedConversations: 0,
                        importedMessages: 0, importedFiles: count)
}
defer {
    fixtureDefaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
}

try sandbox("stage-overwrite") { root in
    let target = root.appendingPathComponent("Attachments")
    try put(target.appendingPathComponent("old"), "old")
    let files = try BackupRestoreFiles(root: root)
    let count = try files.stage(entries: ["attachments/new": Data("new".utf8)], prefix: "attachments", destination: target, mode: .overwrite)
    check(count == 1 && get(target.appendingPathComponent("old")) == "old", "stage preserves live files")
    try files.install()
    check(get(target.appendingPathComponent("new")) == "new" && !exists(target.appendingPathComponent("old")), "overwrite installs complete category")
    check(files.rollback(modelWasChanged: true).isEmpty, "overwrite rollback succeeds")
    check(get(target.appendingPathComponent("old")) == "old" && !exists(target.appendingPathComponent("new")), "overwrite restores exact old files")
}
try sandbox("merge-empty-nested") { root in
    let target = root.appendingPathComponent("Attachments")
    try put(target.appendingPathComponent("same"), "old")
    let files = try BackupRestoreFiles(root: root)
    let empty = try files.stage(entries: ["other/a": Data()], prefix: "attachments", destination: target, mode: .overwrite)
    check(empty == 0 && get(target.appendingPathComponent("same")) == "old", "empty category keeps old semantics")
    let count = try files.stage(entries: ["attachments/same": Data("different".utf8), "attachments/nested/中🙂": Data("new".utf8)], prefix: "attachments", destination: target, mode: .merge)
    try files.install()
    check(count == 1 && get(target.appendingPathComponent("same")) == "old", "merge keeps collisions and counts only new files")
    check(get(target.appendingPathComponent("nested/中🙂")) == "new", "nested Unicode file restored")
    try files.cleanup()
    check(!exists(files.recoveryURL), "success cleanup removes workspace")
}
try sandbox("stage-failure") { root in
    let target = root.appendingPathComponent("Attachments")
    try put(target.appendingPathComponent("old"), "old")
    let files = try BackupRestoreFiles(root: root)
    expectFailure("a file cannot also be a directory") {
        try files.stage(entries: ["attachments/a": Data(), "attachments/a/b": Data()], prefix: "attachments", destination: target, mode: .overwrite)
    }
    check(get(target.appendingPathComponent("old")) == "old", "staging write failure leaves old category untouched")
    check(files.rollback(modelWasChanged: false).isEmpty, "failed preparation needs no live rollback")
}
for failedMove in 1...4 {
    try sandbox("install-failure-\(failedMove)") { root in
        let files = try BackupRestoreFiles(root: root, fileManager: fixtureFileManager)
        for category in ["Attachments", "AssistantMedia"] {
            let target = root.appendingPathComponent(category)
            try put(target.appendingPathComponent("old"), category)
            try files.stage(entries: [category + "/new": Data("new".utf8)], prefix: category, destination: target, mode: .overwrite)
        }
        var moves = 0
        fixtureFileManager.fail = { operation, _, _ in
            guard operation == "move" else { return false }
            moves += 1
            return moves == failedMove
        }
        expectFailure("install move \(failedMove)") { try files.install() }
        check(files.rollback(modelWasChanged: false).isEmpty, "each install failure rolls back earlier moves")
        for category in ["Attachments", "AssistantMedia"] {
            check(get(root.appendingPathComponent(category + "/old")) == category && !exists(root.appendingPathComponent(category + "/new")), "category restored after move \(failedMove)")
        }
    }
}
try sandbox("protect-model-files") { root in
    let calendar = root.appendingPathComponent("MoccaCalendar")
    let fonts = root.appendingPathComponent("AppFonts")
    try put(calendar.appendingPathComponent("calendar.json"), "old")
    let files = try BackupRestoreFiles(root: root)
    try files.protect(calendar); try files.protect(fonts)
    try put(calendar.appendingPathComponent("calendar.json"), "new")
    try put(fonts.appendingPathComponent("font.ttf"), "new")
    check(files.rollback(modelWasChanged: true).isEmpty, "protected model files rollback")
    check(get(calendar.appendingPathComponent("calendar.json")) == "old" && !exists(fonts), "old and originally absent directories restored")
}
try sandbox("rollback-retains-rescue") { root in
    let target = root.appendingPathComponent("Attachments")
    try put(target.appendingPathComponent("old"), "old")
    let files = try BackupRestoreFiles(root: root, fileManager: fixtureFileManager)
    try files.stage(entries: ["attachments/new": Data()], prefix: "attachments", destination: target, mode: .overwrite)
    try files.install()
    fixtureFileManager.fail = { operation, from, _ in operation == "move" && from.lastPathComponent == "previous" }
    check(!files.rollback(modelWasChanged: true).isEmpty, "rollback failure surfaced")
    check(get(files.recoveryURL.appendingPathComponent("0/previous/old")) == "old", "failed rollback retains old rescue file")
}
try sandbox("settings-exact-rollback") { _ in
    fixtureDefaults.set(Data([1, 2, 3]), forKey: "providers_v1")
    fixtureDefaults.set("untouched", forKey: "outside_restore_scope")
    keychain = [credential("providers", "old", "old secret"), credential("search", "search", "password"), credential("voice", "voice", "voice key")]
    let before = keychain as NSArray
    let checkpoint = try BackupRestoreSettingsCheckpoint()
    fixtureDefaults.set(Data([9]), forKey: "providers_v1")
    fixtureDefaults.set("new", forKey: "selected_model_v1")
    keychain = [credential("providers", "old", "changed"), credential("providers", "new", "new secret")]
    check(checkpoint.restore().isEmpty, "settings rollback accepts successful update/add/delete")
    check(fixtureDefaults.data(forKey: "providers_v1") == Data([1, 2, 3]) && fixtureDefaults.object(forKey: "selected_model_v1") == nil, "defaults restored including absence")
    check(fixtureDefaults.string(forKey: "outside_restore_scope") == "untouched", "unrelated defaults not changed")
    let oldEntries = Set((before as! [[String: Any]]).map { ($0[kSecAttrService as String] as! String) + ($0[kSecAttrAccount as String] as! String) })
    check(Set(keychain.map { ($0[kSecAttrService as String] as! String) + ($0[kSecAttrAccount as String] as! String) }) == oldEntries, "only prior service/account identities remain")
}
for failure in ["read", "update", "add", "delete"] {
    try sandbox("credential-failure-" + failure) { _ in
        keychain = [credential("providers", "old", "old")]
        let checkpoint = try BackupRestoreSettingsCheckpoint()
        switch failure {
        case "add": keychain = []
        case "delete": keychain.append(credential("providers", "new", "new"))
        default: keychain[0][kSecValueData as String] = Data("changed".utf8)
        }
        securityFailure = failure
        check(!checkpoint.restore().isEmpty, "credential \(failure) failure is not swallowed")
    }
}
try sandbox("credential-preflight") { _ in
    securityFailure = "read"
    expectFailure("unreadable Keychain fails preflight") { _ = try BackupRestoreSettingsCheckpoint() }
    securityFailure = nil
    keychain = [credential("providers", "same", "first", group: "groupA"), credential("providers", "same", "second", group: "groupB")]
    expectFailure("duplicate account groups cannot silently overwrite snapshot") { _ = try BackupRestoreSettingsCheckpoint() }
}
try sandbox("credential-commit-check") { _ in
    let provider = ProviderConfiguration(id: UUID(), apiKey: "primary", apiKeys: [ProviderKey(key: "second", enabled: true)])
    let search = SearchConfiguration(id: UUID(), apiKey: "search", password: "password")
    let voice = VoiceConfiguration(id: UUID(), apiKey: "voice")
    let preferences = UserPreferences(searchServices: [search], voiceServices: [voice])
    let keys = String(data: try JSONEncoder().encode(provider.apiKeys), encoding: .utf8)!
    keychain = [credential("providers", provider.id.uuidString, provider.apiKey),
                credential("providers", provider.id.uuidString + ".multi-keys", keys),
                credential("search", search.id.uuidString + ".apiKey", search.apiKey),
                credential("search", search.id.uuidString + ".password", search.password),
                credential("voice", voice.id.uuidString, voice.apiKey)]
    try BackupRestoreSettingsCheckpoint.verifySavedCredentials(providers: [provider], preferences: preferences)
    for index in keychain.indices {
        let old = keychain[index]
        keychain[index][kSecValueData as String] = Data("silent failed write".utf8)
        expectFailure("saved credential \(index) must match") {
            try BackupRestoreSettingsCheckpoint.verifySavedCredentials(providers: [provider], preferences: preferences)
        }
        keychain[index] = old
    }
}
for outcome in ["success", "modelFailure", "rollbackFailure", "cleanupFailureAfterRollback", "cleanupFailureAfterSuccess", "checkpointFailure", "drainFailure"] {
    try sandbox("orchestration-" + outcome) { root in
        let model = ModelFixture()
        let before = model.allValues
        let target = root.appendingPathComponent("Attachments")
        try put(target.appendingPathComponent("old"), "old")
        fixtureDefaults.set("old", forKey: "appearance_mode_v1")
        if outcome == "checkpointFailure" { securityFailure = "read" }
        if outcome == "drainFailure" { model.canSave = false }
        if outcome.contains("cleanupFailure") {
            fixtureFileManager.fail = { op, url, _ in op == "remove" && url.lastPathComponent.hasPrefix("restore-") }
        }
        if outcome == "rollbackFailure" {
            fixtureFileManager.fail = { op, from, _ in op == "move" && from.lastPathComponent == "previous" }
        }
        var modelEntered = false
        do {
            let value = try model.performBackupRestoreTransaction(root: root, prepareFiles: { files in
                try files.stage(entries: ["attachments/new": Data("new".utf8)], prefix: "attachments", destination: target, mode: .overwrite)
            }, restore: { count in
                modelEntered = true
                model.mutateAll()
                fixtureDefaults.set("new", forKey: "appearance_mode_v1")
                if ["modelFailure", "rollbackFailure", "cleanupFailureAfterRollback"].contains(outcome) { throw Injected.failure }
                return summary(count)
            })
            check(outcome == "success" || outcome == "cleanupFailureAfterSuccess", "only committed transaction returns success")
            check(value.importedFiles == 1 && get(target.appendingPathComponent("new")) == "new", "successful transaction keeps new model/files")
            check(value.warnings.isEmpty == (outcome == "success"), "post-commit cleanup failure is a warning")
        } catch {
            check(outcome != "success" && outcome != "cleanupFailureAfterSuccess", "expected transaction failure")
            check(model.allValues == before, "all actual captured model properties rolled back")
            check(fixtureDefaults.string(forKey: "appearance_mode_v1") == "old", "transaction restores settings on model failure")
            if outcome != "rollbackFailure" { check(get(target.appendingPathComponent("old")) == "old", "transaction restores old file") }
            if outcome == "cleanupFailureAfterRollback" { check(error.localizedDescription.contains("临时文件清理失败"), "cleanup error remains reachable") }
            if outcome == "rollbackFailure" { check(error.localizedDescription.contains("恢复文件保留于"), "rescue path remains reachable") }
        }
        check(model.blocks == (outcome == "rollbackFailure" ? 1 : 0), "only incomplete rollback blocks future persistence")
        check(modelEntered == !["checkpointFailure", "drainFailure"].contains(outcome), "preflight failure prevents model mutation")
        check(model.stopped, "network operation stays stopped at restore boundary")
    }
}
for failure in ["assistants", "preferences", "providers", "credentialRead", "instruction_injections_v1", "instruction_active_ids_by_assistant_v1", "world_books_v1", "world_book_active_ids_by_assistant_v1", "quick_phrases_v1", "user_profile_v1", "calendarEncoding", "calendarWrite", "primary", "success"] {
    try sandbox("commit-" + failure) { root in
        fixtureSupport = root
        commitFailure = failure; commitCalls = []
        let model = CommitFixture()
        if failure == "credentialRead" { securityFailure = "read" }
        if failure == "calendarEncoding" { model.calendarPayload = .nan }
        if failure == "calendarWrite" { try put(root.appendingPathComponent("MoccaCalendar"), "blocking file") }
        do {
            try model.run()
            check(failure == "success", "only successful final commit returns")
            check(model.primaryCommitted && commitCalls.last == "primary", "primary store is the final failable dependency")
            check(fixtureDefaults.bool(forKey: UnclassifiedConversationOwnership.migrationKey), "migration marker follows successful primary commit")
        } catch {
            check(failure != "success" && !model.primaryCommitted, "save failure cannot follow a reported primary commit")
            check(!fixtureDefaults.bool(forKey: UnclassifiedConversationOwnership.migrationKey), "failed save does not mark migration complete")
            check(commitCalls.contains("primary") == (failure == "primary"), "all earlier failures stop before touching primary store")
        }
    }
}
print("PASS: \(cases) isolated scenarios, \(assertions) assertions; actual production restore/files/settings/rollback/commit control flow.")
print("LIMIT: model payloads are value stand-ins; Security and UserDefaults use isolated adapters; primary store/notifications/iOS UI are not executed; process interruption is not covered.")
