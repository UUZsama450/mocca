#!/usr/bin/env python3
"""Compile actual restore code with isolated filesystem/defaults/Security adapters.

No Mocca process, app container, live defaults, or real Keychain is accessed.
Swift source extraction keeps the production control flow; only dependency names
are redirected to the fixtures. Model payload types are scalar stand-ins because
the captured rollback closure only stores and reassigns those values.
"""
from pathlib import Path
import hashlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/backup-restore-host"
OUT.mkdir(parents=True, exist_ok=True)
backup = (ROOT / "Mocca/BackupService.swift").read_text()
model = (ROOT / "Mocca/AppModel.swift").read_text()


def extract(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    i = brace + 1
    while depth:
        depth += (source[i] == "{") - (source[i] == "}")
        i += 1
    return source[start:i]


checkpoint = extract(backup, "struct BackupRestoreSettingsCheckpoint {")
checkpoint = checkpoint.replace("UserDefaults.standard", "fixtureDefaults")
for name in ("SecItemCopyMatching", "SecItemUpdate", "SecItemAdd", "SecItemDelete"):
    checkpoint = checkpoint.replace(name + "(", "fixture" + name + "(")

transaction = extract(model, "    func performBackupRestoreTransaction(")
assert transaction.count("BackupRestoreFiles(root: root)") == 1
transaction = transaction.replace("BackupRestoreFiles(root: root)",
                                  "BackupRestoreFiles(root: root, fileManager: fixtureFileManager)")
rollback = extract(model, "    private func makeBackupRestoreModelRollback()")
fields = re.findall(r"let old\w+ = (\w+)\n", rollback)
assert len(fields) >= 25 and len(fields) == len(set(fields))
mock = """
enum ConversationStoreError: Error { case persistenceBlocked, missingApplicationSupport }
final class SaveExecutor {
    var resets = 0
    func resetFailureSynchronously() { resets += 1 }
}
final class ModelFixture {
    var persistenceTask: Task<Void, Never>?
    var interactionPersistenceTask: Task<Void, Never>?
    var conversationPersistenceEpoch: UInt64 = 0
    var conversationStoreSaveExecutor: SaveExecutor? = SaveExecutor()
    var canRestore = true
    var canSave = true
    var blocks = 0
    var stopped = false
    func prepareForBackupRestore() -> Bool { canRestore }
    func stopAllStreaming() { stopped = true }
    func cancelAllMemoryBackgroundWork() {}
    func saveImmediately() -> Bool { canSave }
    func blockConversationPersistence(_ reason: String) { blocks += 1 }
"""
mock += "\n".join(f"    var {name} = {i + 1}" for i, name in enumerate(fields))
mock += "\n    func mutateAll() {\n" + "\n".join(f"        {n} += 1000" for n in fields) + "\n    }\n"
mock += "    var allValues: [Int] { [" + ", ".join(fields) + "] }\n"
mock += transaction + "\n" + rollback + "\n}\n"

commit = extract(model, "    private func persistAllRestoredState(")
support_lookup = "FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first"
assert commit.count(support_lookup) == 1
commit = commit.replace(support_lookup, "Optional(fixtureSupport)")
commit = commit.replace("UserDefaults.standard", "fixtureDefaults")
verify = extract(model, "    private func verifyRestoredDefault<T:")
verify = verify.replace("UserDefaults.standard", "fixtureDefaults")
commit_model = """
final class CommitFixture {
    var assistants = 1
    var appearanceMode = 2
    var preferences = UserPreferences(searchServices: [], voiceServices: [])
    var providers: [ProviderConfiguration] = []
    var selectedModel = 3
    var favoriteModelKeys = 4
    var favoriteProviderIDs = 5
    var currentAssistantID = 6
    var instructionInjections = 7
    var activeInstructionIDsByAssistant = 8
    var worldBooks = 9
    var activeWorldBookIDsByAssistant = 10
    var quickPhrases = 11
    var userProfile = 12
    var calendarPayload = 13.0
    var calendarEvents = 14
    var primaryCommitted = false
    func saveImmediately(allowDestructiveConversationReduction: Bool,
                         allowDestructiveMessageReduction: Bool) -> Bool {
        commitCalls.append("primary")
        guard commitFailure != "primary" else { return false }
        primaryCommitted = true
        return true
    }
    func run() throws {
        try persistAllRestoredState(allowDestructiveConversationReduction: true,
                                   allowDestructiveMessageReduction: true)
    }
""" + verify + "\n" + commit + "\n}\n"

parts = ["import Foundation\nimport Security\n",
         extract(backup, "enum BackupRestoreMode:"),
         extract(backup, "enum BackupServiceError:"),
         extract(backup, "struct BackupImportSummary:"),
         extract(backup, "final class BackupRestoreFiles {"), checkpoint, mock, commit_model,
         (ROOT / "CandidateTests/BackupRestoreTransactionFixtures.swift").read_text()]
source = OUT / "main.swift"
source.write_text("\n\n".join(parts))
manifest = "\n".join(f"{p}: {hashlib.sha256((ROOT / p).read_bytes()).hexdigest()}"
                     for p in ("Mocca/BackupService.swift", "Mocca/AppModel.swift",
                               "Mocca/SettingsViews.swift"))
(OUT / "source-hashes.txt").write_text(manifest + "\n")
with (OUT / "compile.log").open("w") as log:
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(OUT / "host")],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
with (OUT / "results.log").open("w") as log:
    subprocess.run([str(OUT / "host")], stdout=log, stderr=subprocess.STDOUT, check=True)
print((OUT / "results.log").read_text(), end="")
print("Source hashes: " + str(OUT / "source-hashes.txt"))
