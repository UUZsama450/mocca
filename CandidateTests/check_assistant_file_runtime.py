#!/usr/bin/env python3
"""Execute production assistant-file transactions, parsing and stream guards.

AssistantFiles.swift and AssistantFileRuntime.swift are compiled unchanged.
Tool definition/parser snippets and AppModel's stream closure/grants are copied
verbatim into a Foundation host. AppModel storage and persistence are fixtures;
no real UserDefaults, chats, network, iOS app, or device are touched.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "Mocca/AssistantFiles.swift"
RUNTIME = ROOT / "Mocca/AssistantFileRuntime.swift"
PROFILE = ROOT / "Mocca/AssistantModels.swift"
TOOLS = ROOT / "Mocca/ToolCalling.swift"
APP = ROOT / "Mocca/AppModel.swift"


def block(source, marker):
    """Extract one brace-balanced production declaration/closure.

    Relevant declarations contain balanced literal braces; pinning their hashes
    makes the exact extracted code visible in the result.
    """
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SUPPORT = r'''
import Foundation
struct ModelSelection: Codable, Hashable, Sendable {}
struct RecentMemorySettings: Codable, Hashable, Sendable {
    var isEnabled: Bool
    init(isEnabled: Bool = false) { self.isEnabled = isEnabled }
}
struct RecentMemoryState: Codable, Hashable, Sendable {}
struct MigrationMetadata: Codable, Hashable, Sendable {}
enum MoccaCalendarAssistantBridge { static var toolDefinitions: [[String: Any]] { [] } }
struct HarnessFailure: Error { let message: String }
typealias FileExecutor = @Sendable (AssistantFileToolRequest) async -> String

@MainActor enum Check {
    static var count = 0
    static func that(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !condition() { throw HarnessFailure(message: label) }
    }
    static func error(_ expected: AssistantFileError, _ action: () throws -> Void) throws {
        count += 1
        do { try action() }
        catch let error as AssistantFileError {
            guard error == expected else { throw HarnessFailure(message: "Expected \(expected), got \(error)") }
            return
        }
        throw HarnessFailure(message: "Missing expected error \(expected)")
    }
    static func object(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static func ok(_ text: String, _ label: String) throws -> [String: Any] {
        let object = try object(text)
        try that(object["ok"] as? Bool == true, label + ": " + text)
        return object["file"] as! [String: Any]
    }
    static func denied(_ text: String, _ code: String, _ label: String) throws {
        let object = try object(text)
        try that(object["error"] as? String == code, label + ": " + text)
        try that(object["ok"] as? Bool != true, label + " must not claim success")
    }
}

@MainActor enum AssistantPersistence {
    static var shouldFail = false
    static var attempts = 0
    static var stored: [AssistantProfile] = []
    static func reset(_ profiles: [AssistantProfile]) {
        shouldFail = false; attempts = 0; stored = profiles
    }
    static func saveAssistants(_ profiles: [AssistantProfile]) -> Bool {
        attempts += 1
        guard !shouldFail else { return false }
        stored = profiles
        return true
    }
}

struct FixtureConversation: Identifiable { let id: UUID }
@MainActor final class AppModel {
    var assistants: [AssistantProfile]
    var activeStreamingMessageIDsByConversation: [UUID: UUID] = [:]
    var streamingRunIDsByConversation: [UUID: UUID] = [:]
    var conversations: [FixtureConversation] = []
    init(assistants: [AssistantProfile]) {
        self.assistants = assistants
        AssistantPersistence.reset(assistants)
    }
    func file(_ id: UUID, assistantID: UUID) -> AssistantFile {
        assistants.first { $0.id == assistantID }!.files.first { $0.id == id }!
    }
    // PRODUCTION_RUN_METHOD
    func generationExecutor(assistantID: UUID, conversationID: UUID, messageID: UUID) -> FileExecutor {
        let assistantForHandler = assistants.first { $0.id == assistantID }!
        let requestFiles = assistantForHandler.files
        let fileToolRunID = streamingRunIDsByConversation[conversationID]
        let fileToolMessageID = messageID
        // PRODUCTION_SCOPE_GRANTS
        return /* PRODUCTION_STREAM_CLOSURE */
    }
}

@MainActor struct Fixture {
    let model: AppModel
    let aID: UUID
    let bID: UUID
    let fileID: UUID
    let otherFileID: UUID
    let conversationID = UUID()
    let runID = UUID()
    let messageID = UUID()
    init(enabled: Bool = true, writable: Bool = true) {
        let aFile = AssistantFile(fileName: "A.md", content: "A original", isEnabled: enabled, allowsAssistantEditing: writable)
        let bFile = AssistantFile(fileName: "B.md", content: "B private", allowsAssistantEditing: true)
        let a = AssistantProfile(name: "A", temperature: 0.25, systemPrompt: "A persona", files: [aFile])
        let b = AssistantProfile(name: "B", temperature: 0.9, systemPrompt: "B persona", files: [bFile])
        aID = a.id; bID = b.id; fileID = aFile.id; otherFileID = bFile.id
        model = AppModel(assistants: [a, b])
        model.conversations = [FixtureConversation(id: conversationID)]
        model.streamingRunIDsByConversation[conversationID] = runID
        model.activeStreamingMessageIDsByConversation[conversationID] = messageID
    }
    var file: AssistantFile { model.file(fileID, assistantID: aID) }
    func executor() -> FileExecutor {
        model.generationExecutor(assistantID: aID, conversationID: conversationID, messageID: messageID)
    }
}
'''


HARNESS = r'''
@main struct RuntimeHarness {
    @MainActor static func main() async throws {
        // Requests operate on the live assistant subresource, never the captured profile.
        let isolated = Fixture()
        let isolatedExecutor = isolated.executor()
        let originalB = isolated.model.assistants[1]
        isolated.model.assistants[0].systemPrompt = "new persona saved while reply runs"
        var extra = AssistantFile(fileName: "User.md", content: "another local document")
        extra = try isolated.model.saveAssistantFile(assistantID: isolated.aID, file: extra, expectedRevision: nil)
        let firstRead = try Check.ok(await isolatedExecutor(.read(fileID: isolated.fileID)), "live read")
        try Check.that(firstRead["content"] as? String == "A original", "read content")
        _ = try Check.ok(await isolatedExecutor(.edit(fileID: isolated.fileID, expectedRevision: 1, content: "A model edit")), "authorized edit")
        try Check.that(isolated.model.assistants[1] == originalB, "other assistant unchanged")
        try Check.that(isolated.model.assistants[0].systemPrompt == "new persona saved while reply runs", "live settings preserved")
        try Check.that(isolated.model.file(extra.id, assistantID: isolated.aID) == extra, "other file preserved")
        try Check.that(AssistantPersistence.stored == isolated.model.assistants, "publication matches durable candidate")
        try Check.that(!extra.allowsAssistantEditing && extra.revision == 1, "new manual file defaults")
        try Check.denied(await isolatedExecutor(.read(fileID: isolated.otherFileID)), "file_unavailable", "cross-assistant read")
        try Check.denied(await isolatedExecutor(.edit(fileID: isolated.otherFileID, expectedRevision: 1, content: "attack")), "file_unavailable", "cross-assistant edit")
        try Check.that(isolated.model.assistants[1] == originalB, "cross-assistant attempts cannot mutate B")
        print("PASS: live save isolation and cross-assistant access boundaries")

        let readonly = Fixture(writable: false)
        let readonlyExecutor = readonly.executor()
        var granting = readonly.file
        granting.allowsAssistantEditing = true
        let granted = try readonly.model.saveAssistantFile(assistantID: readonly.aID, file: granting, expectedRevision: 1)
        try Check.denied(await readonlyExecutor(.edit(fileID: readonly.fileID, expectedRevision: granted.revision, content: "broadened")), "edit_not_allowed", "mid-request grant cannot expand writable scope")
        let nowReadable = try Check.ok(await readonlyExecutor(.read(fileID: readonly.fileID)), "read after permission update")
        try Check.that(nowReadable["revision"] as? Int == granted.revision, "read reflects latest revision")
        _ = try Check.ok(await readonly.executor()(.edit(fileID: readonly.fileID, expectedRevision: granted.revision, content: "fresh request grant")), "new request sees grant")
        let initiallyDisabled = Fixture(enabled: false, writable: true)
        let disabledExecutor = initiallyDisabled.executor()
        var enabling = initiallyDisabled.file
        enabling.isEnabled = true
        _ = try initiallyDisabled.model.saveAssistantFile(assistantID: initiallyDisabled.aID, file: enabling, expectedRevision: 1)
        try Check.denied(await disabledExecutor(.read(fileID: initiallyDisabled.fileID)), "file_unavailable", "mid-request enable cannot expand readable scope")

        let revoked = Fixture()
        let revokedExecutor = revoked.executor()
        var revokeDraft = revoked.file
        revokeDraft.allowsAssistantEditing = false
        let revokedFile = try revoked.model.saveAssistantFile(assistantID: revoked.aID, file: revokeDraft, expectedRevision: 1)
        try Check.denied(await revokedExecutor(.edit(fileID: revoked.fileID, expectedRevision: revokedFile.revision, content: "late")), "file_update_failed", "live revoke")
        try Check.that(revoked.file.content == "A original", "revoked edit unchanged")
        _ = try Check.ok(await revokedExecutor(.read(fileID: revoked.fileID)), "revocation still allows configured read")
        var disableDraft = revoked.file
        disableDraft.isEnabled = false
        _ = try revoked.model.saveAssistantFile(assistantID: revoked.aID, file: disableDraft, expectedRevision: disableDraft.revision)
        try Check.denied(await revokedExecutor(.read(fileID: revoked.fileID)), "file_unavailable", "live disable denies read")
        try Check.denied(await revokedExecutor(.edit(fileID: revoked.fileID, expectedRevision: revoked.file.revision, content: "late")), "file_unavailable", "live disable denies write")
        let missing = Fixture()
        let missingExecutor = missing.executor()
        try missing.model.removeAssistantFile(assistantID: missing.aID, fileID: missing.fileID, expectedRevision: 1)
        try Check.denied(await missingExecutor(.read(fileID: missing.fileID)), "file_unavailable", "deleted file read")
        try Check.denied(await missingExecutor(.edit(fileID: missing.fileID, expectedRevision: 1, content: "resurrection")), "file_unavailable", "deleted file edit")
        try Check.that(missing.model.assistants[0].files.isEmpty, "deleted file stays deleted")
        missing.model.assistants.removeAll { $0.id == missing.aID }
        try Check.denied(await missingExecutor(.read(fileID: missing.fileID)), "file_unavailable", "deleted assistant read")
        try Check.error(.missingAssistant) {
            _ = try missing.model.saveAssistantFile(assistantID: missing.aID, file: AssistantFile(), expectedRevision: nil)
        }
        print("PASS: request grants cannot expand; live revoke, disable, deletion remain authoritative")

        let concurrent = Fixture()
        let concurrentExecutor = concurrent.executor()
        let captured = concurrent.file
        var userDraft = captured
        userDraft.content = "user saved first"
        let userSaved = try concurrent.model.saveAssistantFile(assistantID: concurrent.aID, file: userDraft, expectedRevision: captured.revision)
        let beforeStale = concurrent.model.assistants
        let beforeStaleAttempts = AssistantPersistence.attempts
        try Check.denied(await concurrentExecutor(.edit(fileID: concurrent.fileID, expectedRevision: 1, content: "stale model")), "file_update_failed", "stale model edit")
        try Check.that(concurrent.model.assistants == beforeStale && AssistantPersistence.attempts == beforeStaleAttempts, "stale model edit never reaches persistence")
        try Check.error(.revisionConflict) {
            _ = try concurrent.model.saveAssistantFile(assistantID: concurrent.aID, file: captured, expectedRevision: captured.revision)
        }
        let readNew = try Check.ok(await concurrentExecutor(.read(fileID: concurrent.fileID)), "reread user revision")
        try Check.that(readNew["revision"] as? Int == userSaved.revision && readNew["content"] as? String == "user saved first", "conflict read returns current state")
        let edited = try Check.ok(await concurrentExecutor(.edit(fileID: concurrent.fileID, expectedRevision: userSaved.revision, content: "model revision 3")), "fresh edit")
        let revision3 = edited["revision"] as! Int
        try Check.denied(await concurrentExecutor(.edit(fileID: concurrent.fileID, expectedRevision: userSaved.revision, content: "second stale edit")), "file_update_failed", "second edit needs latest revision")
        let reread = try Check.ok(await concurrentExecutor(.read(fileID: concurrent.fileID)), "reread model revision")
        try Check.that(reread["revision"] as? Int == revision3, "latest read revision")
        _ = try Check.ok(await concurrentExecutor(.edit(fileID: concurrent.fileID, expectedRevision: revision3, content: "model revision 4")), "second fresh edit")
        try Check.error(.revisionConflict) {
            try concurrent.model.removeAssistantFile(assistantID: concurrent.aID, fileID: concurrent.fileID, expectedRevision: revision3)
        }
        try Check.that(concurrent.file.content == "model revision 4", "stale deletion preserved current content")
        var offDraft = concurrent.file
        offDraft.isEnabled = false; offDraft.allowsAssistantEditing = false
        let off = try concurrent.model.saveAssistantFile(assistantID: concurrent.aID, file: offDraft, expectedRevision: offDraft.revision)
        let undone = try concurrent.model.undoAssistantFile(assistantID: concurrent.aID, fileID: concurrent.fileID, expectedRevision: off.revision)
        try Check.that(undone.content == "model revision 3", "runtime undo restores previous body")
        try Check.that(!undone.isEnabled && !undone.allowsAssistantEditing, "runtime undo cannot revive permissions")
        try Check.that(undone.previousVersion == nil && undone.revision > off.revision, "runtime undo consumed")
        try Check.error(.noPreviousVersion) {
            _ = try concurrent.model.undoAssistantFile(assistantID: concurrent.aID, fileID: concurrent.fileID, expectedRevision: undone.revision)
        }
        print("PASS: concurrent manual/model edits, latest-read revision checks, stale deletion, runtime undo")

        let failed = Fixture()
        let failedExecutor = failed.executor()
        let beforeFailure = failed.model.assistants
        let durableBeforeFailure = AssistantPersistence.stored
        AssistantPersistence.shouldFail = true
        try Check.denied(await failedExecutor(.edit(fileID: failed.fileID, expectedRevision: 1, content: "not saved")), "file_update_failed", "write failure propagated to tool")
        try Check.that(failed.model.assistants == beforeFailure && AssistantPersistence.stored == durableBeforeFailure, "failed save cannot publish")
        try Check.error(.persistenceFailed) {
            _ = try failed.model.saveAssistantFile(assistantID: failed.aID, file: AssistantFile(content: "manual"), expectedRevision: nil)
        }
        try Check.that(failed.model.assistants == beforeFailure, "manual failed save cannot publish")
        try Check.error(.persistenceFailed) {
            try failed.model.appendAssistantFiles(assistantID: failed.aID, files: [AssistantFile(content: "batch1"), AssistantFile(content: "batch2")])
        }
        try Check.that(failed.model.assistants == beforeFailure, "failed import persistence has no partial append")
        AssistantPersistence.shouldFail = false
        let beforeBatchAttempts = AssistantPersistence.attempts
        try Check.error(.fileTooLarge) {
            try failed.model.appendAssistantFiles(assistantID: failed.aID, files: [
                AssistantFile(content: "small"), AssistantFile(content: String(repeating: "a", count: 65_537))
            ])
        }
        try Check.that(failed.model.assistants == beforeFailure && AssistantPersistence.attempts == beforeBatchAttempts, "invalid batch rejected before any write")
        try Check.error(.duplicateID) {
            try failed.model.appendAssistantFiles(assistantID: failed.aID, files: [failed.file])
        }
        let forgedImport = AssistantFile(fileName: "forged.md", content: "new body", isEnabled: false, allowsAssistantEditing: true, revision: 99, lastModifiedBy: .assistant)
        try failed.model.appendAssistantFiles(assistantID: failed.aID, files: [forgedImport])
        let cleanImport = failed.model.file(forgedImport.id, assistantID: failed.aID)
        try Check.that(cleanImport.isEnabled && !cleanImport.allowsAssistantEditing && cleanImport.revision == 1 && cleanImport.lastModifiedBy == .user, "import metadata cannot grant access or forge provenance")
        let total = Fixture()
        let fourLarge = (0..<4).map { AssistantFile(fileName: "\($0).md", content: String(repeating: "a", count: 65_536)) }
        try Check.error(.totalTooLarge) { try total.model.appendAssistantFiles(assistantID: total.aID, files: fourLarge) }
        try Check.that(total.model.assistants[0].files.count == 1 && AssistantPersistence.attempts == 0, "aggregate failure atomic")
        print("PASS: controlled persistence failures, atomic batches, aggregate cap and safe import defaults")

        let parsing = Fixture()
        let parser = ToolCallExecutor.buildFileHandler(assistantFileExecutor: parsing.executor())
        let validRead: [String: Any] = ["file_id": parsing.fileID.uuidString]
        _ = try Check.ok(await parser("read_assistant_file", validRead, nil), "production parser valid read")
        let validEdit: [String: Any] = ["file_id": parsing.fileID.uuidString, "expected_revision": 1, "content": ""]
        _ = try Check.ok(await parser("edit_assistant_file", validEdit, nil), "production parser permits blank content")
        for badRevision: Any in [true, "2", 1.5, NSNull(), 1e30] {
            let args: [String: Any] = ["file_id": parsing.fileID.uuidString, "expected_revision": badRevision, "content": "bad"]
            try Check.denied(await parser("edit_assistant_file", args, nil), "invalid_arguments", "typed revision validation")
        }
        for revision in [0, -1] {
            try Check.denied(await parser("edit_assistant_file", ["file_id": parsing.fileID.uuidString, "expected_revision": revision, "content": "bad"], nil), "invalid_revision", "positive integer revision")
        }
        for badID: Any in ["not-a-uuid", 42, NSNull()] {
            try Check.denied(await parser("read_assistant_file", ["file_id": badID], nil), "invalid_arguments", "UUID validation")
        }
        try Check.denied(await parser("edit_assistant_file", ["file_id": parsing.fileID.uuidString, "expected_revision": 2], nil), "invalid_arguments", "missing full content rejected")
        try Check.denied(await parser("edit_assistant_file", ["file_id": parsing.fileID.uuidString, "expected_revision": 2, "content": 7], nil), "invalid_arguments", "non-string content rejected")
        let unavailableParser = ToolCallExecutor.buildFileHandler(assistantFileExecutor: nil)
        try Check.denied(await unavailableParser("read_assistant_file", validRead, nil), "unavailable", "no executor cannot run")
        let broadening = Fixture(writable: false)
        let limitedParser = ToolCallExecutor.buildFileHandler(assistantFileExecutor: broadening.executor())
        try Check.denied(await limitedParser("edit_assistant_file", [
            "file_id": broadening.fileID.uuidString, "expected_revision": 1, "content": "attack",
            "assistant_id": broadening.bID.uuidString, "allows_assistant_editing": true,
            "writableFileIDs": [broadening.fileID.uuidString]
        ], nil), "edit_not_allowed", "extra arguments cannot broaden scope")
        try Check.denied(await limitedParser("read_assistant_file", ["file_id": broadening.otherFileID.uuidString, "assistant_id": broadening.bID.uuidString], nil), "file_unavailable", "argument cannot redirect assistant")
        try Check.that(broadening.file.content == "A original" && broadening.model.assistants[1].files[0].content == "B private", "argument attacks leave both assistants unchanged")
        print("PASS: actual typed tool parser, integer/UUID checks and argument scope attacks")

        func definitionNames(_ profile: AssistantProfile, supportsTools: Bool = true) -> [String] {
            ToolDefinitionBuilder.buildDefinitions(assistant: profile, supportsTools: supportsTools).compactMap {
                ($0["function"] as? [String: Any])?["name"] as? String
            }
        }
        try Check.that(definitionNames(AssistantProfile(name: "empty")).isEmpty, "no files no tools")
        try Check.that(definitionNames(AssistantProfile(name: "disabled", files: [AssistantFile(isEnabled: false, allowsAssistantEditing: true)])).isEmpty, "disabled file no read/write tools")
        let readOnlyProfile = AssistantProfile(name: "read-only", files: [AssistantFile()])
        try Check.that(definitionNames(readOnlyProfile) == ["read_assistant_file"], "read-only definitions")
        let writeProfile = AssistantProfile(name: "write", files: [AssistantFile(allowsAssistantEditing: true)])
        try Check.that(definitionNames(writeProfile) == ["read_assistant_file", "edit_assistant_file"], "read/write definitions")
        try Check.that(definitionNames(writeProfile, supportsTools: false).isEmpty, "unsupported provider cannot receive tools")
        let allDefinitions = ToolDefinitionBuilder.buildDefinitions(assistant: writeProfile, supportsTools: true)
        for definition in allDefinitions {
            let parameters = (definition["function"] as! [String: Any])["parameters"] as! [String: Any]
            try Check.that(parameters["additionalProperties"] as? Bool == false, "tool schema advertises closed fields")
        }
        print("PASS: actual tool definitions for disabled, read-only, read/write and tool-less models")

        let expiry = Fixture()
        let expiryExecutor = expiry.executor()
        let beforeExpiry = expiry.model.assistants
        expiry.model.streamingRunIDsByConversation[expiry.conversationID] = UUID()
        try Check.denied(await expiryExecutor(.edit(fileID: expiry.fileID, expectedRevision: 1, content: "late run")), "request_expired", "superseded stream")
        expiry.model.streamingRunIDsByConversation[expiry.conversationID] = expiry.runID
        expiry.model.activeStreamingMessageIDsByConversation[expiry.conversationID] = UUID()
        try Check.denied(await expiryExecutor(.edit(fileID: expiry.fileID, expectedRevision: 1, content: "late message")), "request_expired", "superseded message")
        expiry.model.activeStreamingMessageIDsByConversation[expiry.conversationID] = expiry.messageID
        expiry.model.conversations = []
        try Check.denied(await expiryExecutor(.read(fileID: expiry.fileID)), "request_expired", "deleted conversation")
        expiry.model.conversations = [FixtureConversation(id: expiry.conversationID)]
        expiry.model.streamingRunIDsByConversation[expiry.conversationID] = nil
        let absentRunExecutor = expiry.executor()
        expiry.model.streamingRunIDsByConversation[expiry.conversationID] = expiry.runID
        try Check.denied(await absentRunExecutor(.edit(fileID: expiry.fileID, expectedRevision: 1, content: "never granted run")), "request_expired", "missing captured run cannot revive")
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await expiryExecutor(.edit(fileID: expiry.fileID, expectedRevision: 1, content: "cancelled"))
        }
        try Check.denied(await cancelled.value, "request_expired", "cancelled task")
        try Check.that(expiry.model.assistants == beforeExpiry && AssistantPersistence.attempts == 0, "expired operations never persist or publish")
        _ = try Check.ok(await expiryExecutor(.read(fileID: expiry.fileID)), "live gate positive control")
        var releasedModel: AppModel? = expiry.model
        // A separately allocated fixture ensures only the actual weak closure remains.
        releasedModel = AppModel(assistants: expiry.model.assistants)
        releasedModel!.conversations = [FixtureConversation(id: expiry.conversationID)]
        releasedModel!.streamingRunIDsByConversation[expiry.conversationID] = expiry.runID
        releasedModel!.activeStreamingMessageIDsByConversation[expiry.conversationID] = expiry.messageID
        let releasedExecutor = releasedModel!.generationExecutor(assistantID: expiry.aID, conversationID: expiry.conversationID, messageID: expiry.messageID)
        releasedModel = nil
        try Check.denied(await releasedExecutor(.read(fileID: expiry.fileID)), "request_expired", "released model")
        print("PASS: actual stream closure run/message/conversation/cancellation/lifetime gate")
        print("PASS: \(Check.count) executable assistant file runtime assertions")
    }
}
'''


def main():
    tools = TOOLS.read_text()
    app = APP.read_text()
    profile = PROFILE.read_text()
    profile_prefix = profile[:profile.index("    var trimmedSystemPrompt:")].replace("import UIKit\n", "") + "}\n"
    definitions = tools[tools.index("enum ToolDefinitionBuilder {"):tools.index("// MARK: - Tool Call Handler")]
    local_names = block(tools, "enum LocalToolName {")
    search_constants = tools[tools.index("enum SearchToolConstants {"):tools.index("// MARK: - Tool Definition Builder")]
    parser_start = tools.index('            if name == "read_assistant_file" || name == "edit_assistant_file" {')
    parser_end = tools.index("            if name == SearchToolConstants.toolName {", parser_start)
    parser_branch = tools[parser_start:parser_end]
    arguments_start = tools.index("    private struct AssistantFileReadArguments: Decodable {")
    arguments_end = tools.index("    private static func handleMemoryTool(", arguments_start)
    argument_structs = tools[arguments_start:arguments_end]
    tool_error = block(tools, "    static func toolError(error:")
    result_json = block(tools, "func toolResultJSONString(")
    stream_start = app.index("assistantFileExecutor: { [weak self] request in")
    stream_closure = block(app[stream_start:], "{ [weak self] request in")
    grants_start = app.index("            let readableFileIDs = Set(requestFiles.filter")
    grants_end = app.index("            let memoryUpdater:", grants_start)
    grants = app[grants_start:grants_end]
    run_method = block(app, "    private func isCurrentStreamingRun(")
    support = SUPPORT.replace("// PRODUCTION_RUN_METHOD", run_method)
    support = support.replace("// PRODUCTION_SCOPE_GRANTS", grants)
    support = support.replace("/* PRODUCTION_STREAM_CLOSURE */", stream_closure)
    parser = """
typealias ToolCallHandler = @Sendable (String, [String: Any], String?) async -> String
enum ToolCallExecutor {
    static func buildFileHandler(assistantFileExecutor: FileExecutor?) -> ToolCallHandler {
        { @Sendable name, args, toolCallId in
""" + parser_branch + """
            return toolError(error: "unknown_tool", message: "Not part of this file harness", tool: name)
        }
    }
""" + argument_structs + tool_error + "\n}\n"
    pieces = {
        "profile_prefix": profile_prefix,
        "definition_builder": definitions,
        "parser_branch": parser_branch,
        "argument_structs": argument_structs,
        "request_scope_grants": grants,
        "stream_executor_closure": stream_closure,
        "run_identity_method": run_method,
    }
    with tempfile.TemporaryDirectory(prefix="mocca-file-runtime-host-") as temp:
        temp_path = Path(temp)
        host = temp_path / "AssistantFileRuntimeHost.swift"
        host.write_text("\n\n".join([support, profile_prefix, result_json, local_names, search_constants, definitions, parser, HARNESS]))
        binary = temp_path / "assistant-file-runtime-host"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            str(SERVICE), str(RUNTIME), str(host), "-o", str(binary)
        ], check=True)
        result = subprocess.run([str(binary)], text=True, capture_output=True)
        print(result.stdout, end="")
        if result.returncode:
            print(result.stderr, end="")
            result.check_returncode()
        print(json.dumps({
            "production_files": {
                str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in [SERVICE, RUNTIME]
            },
            "production_excerpts": {name: hashlib.sha256(text.encode()).hexdigest() for name, text in pieces.items()},
            "scope": "actual backend CRUD/tool parser/definitions/stream closure; fixture persistence and AppModel storage; no UI/device/network proof"
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
