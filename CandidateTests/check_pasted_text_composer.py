#!/usr/bin/env python3
"""Run the production pasted-text composer transaction in a Foundation host.

AppModel's actual mutation and composer-packet accessors are extracted unchanged.
The attachment store is a controllable fixture that writes only synthetic UTF-8
files below work/verification, then suspends before returning a saved attachment.
This exercises post-IO ownership/cancellation races without timers or an app.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Mocca/AppModel.swift"
BASELINE = ROOT / "work/verification/tools-navigation-long-paste/baseline-5012/Mocca/AppModel.swift"
OUT = ROOT / "work/verification/tools-navigation-long-paste/pasted-text-composer-host"


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def request_file_case(source):
    stream = block(source, "    private func runAssistantStream(")
    start = stream.index("                case .file:\n")
    return stream[start:stream.index("                default:\n", start)]


SUPPORT = r'''
import Foundation

struct MessageAttachment: Equatable, Sendable {
    let id: UUID
    let localURL: URL
    let fileName: String
}
struct FixtureConversation { let id: UUID }
struct HarnessFailure: Error { let message: String }
enum FixtureIOError: Error { case failed }

@MainActor enum Check {
    static var count = 0
    static func that(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !condition() { throw HarnessFailure(message: label) }
    }
}

@MainActor enum AttachmentStore {
    static var directory: URL!
    static var saveAttempts = 0
    static var failNextWrite = false
    static var suspendReturns = false
    static var generated: [MessageAttachment] = []
    static var submittedTexts: [String] = []
    static var deleted: [UUID] = []
    static var gates: [UUID: CheckedContinuation<Void, Never>] = [:]
    static var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    static func configure(_ root: URL) throws {
        precondition(gates.isEmpty && waiters.isEmpty)
        directory = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saveAttempts = 0
        failNextWrite = false
        suspendReturns = false
        generated = []
        submittedTexts = []
        deleted = []
    }

    static func seed(_ text: String) throws -> MessageAttachment {
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return MessageAttachment(id: id, localURL: url, fileName: "existing.txt")
    }

    static func savePastedText(_ text: String) async throws -> MessageAttachment {
        saveAttempts += 1
        submittedTexts.append(text)
        if failNextWrite { throw FixtureIOError.failed }
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        let attachment = MessageAttachment(id: id, localURL: url, fileName: "粘贴文本.txt")
        generated.append(attachment)
        let ready = waiters.filter { generated.count >= $0.count }
        waiters.removeAll { generated.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
        if suspendReturns {
            // Deliberately return even when cancelled: exercise AppModel's own
            // post-IO cancellation cleanup, independently of storage cleanup.
            await withCheckedContinuation { gates[id] = $0 }
        }
        return attachment
    }

    static func waitForWrites(_ count: Int) async {
        if generated.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    static func release(_ attachment: MessageAttachment) {
        precondition(gates[attachment.id] != nil, "Expected a suspended write")
        gates.removeValue(forKey: attachment.id)!.resume()
    }

    static func delete(_ attachment: MessageAttachment) {
        deleted.append(attachment.id)
        try! FileManager.default.removeItem(at: attachment.localURL)
    }
}

// PRODUCTION_PACKET

@MainActor final class AppModel {
    var conversations: [FixtureConversation] = []
    var selectedConversationID = UUID()
    private var composerPacketsByConversation: [UUID: ConversationComposerPacket] = [:]

    // PRODUCTION_COMPOSER_METHODS
}

@MainActor struct Fixture {
    let model: AppModel
    let aID = UUID()
    let bID = UUID()
    let aOld: MessageAttachment
    let bOld: MessageAttachment
    let aDraft = "原有草稿 A： \n不要替换 👩🏽‍💻 e\u{301}\n"
    let bDraft = "另一会话草稿 B\r\n"

    init(root: URL, name: String) throws {
        try AttachmentStore.configure(root.appendingPathComponent(name))
        aOld = try AttachmentStore.seed("existing A attachment")
        bOld = try AttachmentStore.seed("existing B attachment")
        model = AppModel()
        model.conversations = [FixtureConversation(id: aID), FixtureConversation(id: bID)]
        model.selectedConversationID = aID
        model.setComposerDraftText(aDraft, for: aID)
        model.setComposerDraftText(bDraft, for: bID)
        model.setComposerPendingAttachments([aOld], for: aID)
        model.setComposerPendingAttachments([bOld], for: bID)
    }

    func assertDraftsUnchanged(_ label: String) throws {
        try Check.that(model.composerDraftText(for: aID) == aDraft, label + ": A text preserved")
        try Check.that(model.composerDraftText(for: bID) == bDraft, label + ": B text preserved")
        try Check.that(model.composerPendingAttachments(for: aID) == [aOld], label + ": A attachments preserved")
        try Check.that(model.composerPendingAttachments(for: bID) == [bOld], label + ": B attachments preserved")
    }

    func assertOldFilesExist(_ label: String) throws {
        try Check.that(try Data(contentsOf: aOld.localURL) == Data("existing A attachment".utf8), label + ": A original file preserved")
        try Check.that(try Data(contentsOf: bOld.localURL) == Data("existing B attachment".utf8), label + ": B original file preserved")
    }

    func assertOnlyGeneratedDeleted(_ generated: MessageAttachment, _ label: String) throws {
        try Check.that(AttachmentStore.deleted == [generated.id], label + ": only this generated file deleted")
        try Check.that(!FileManager.default.fileExists(atPath: generated.localURL.path), label + ": generated file absent")
        try assertOldFilesExist(label)
    }
}
'''


HARNESS = r'''
@main struct PastedTextComposerHarness {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fullText = " \n" + String(repeating: "完整原文 👩🏽‍💻 e\u{301} \r\n", count: 4_097) + "最后一字\n "

        let success = try Fixture(root: root, name: "success")
        let saved = try await success.model.addPendingPastedText(fullText, for: success.aID, canCommit: { true })
        try Check.that(saved, "success returns true")
        try Check.that(AttachmentStore.saveAttempts == 1 && AttachmentStore.generated.count == 1, "one generated attachment")
        let savedAttachment = AttachmentStore.generated[0]
        try Check.that(try Data(contentsOf: savedAttachment.localURL) == Data(fullText.utf8), "entire Unicode/whitespace input is byte-preserved")
        try Check.that(AttachmentStore.submittedTexts == [fullText], "store receives complete original input")
        try Check.that(success.model.composerDraftText(for: success.aID) == success.aDraft, "success preserves existing composer text")
        try Check.that(success.model.composerPendingAttachments(for: success.aID) == [success.aOld, savedAttachment], "success appends after existing attachment")
        try Check.that(success.model.composerDraftText(for: success.bID) == success.bDraft && success.model.composerPendingAttachments(for: success.bID) == [success.bOld], "success leaves other conversation untouched")
        try Check.that(AttachmentStore.deleted.isEmpty, "success performs no cleanup deletion")
        try success.assertOldFilesExist("success")
        print("PASS: success appends complete UTF-8 input and preserves draft/old attachments/other conversation")

        let absent = try Fixture(root: root, name: "no-conversation")
        var absentGateCalls = 0
        let absentResult = try await absent.model.addPendingPastedText(fullText, for: UUID(), canCommit: { absentGateCalls += 1; return true })
        try Check.that(!absentResult && AttachmentStore.saveAttempts == 0, "missing conversation does not write")
        try Check.that(absentGateCalls == 0, "missing conversation short-circuits authorization")
        try absent.assertDraftsUnchanged("missing conversation")
        try absent.assertOldFilesExist("missing conversation")

        let denied = try Fixture(root: root, name: "denied-before-io")
        let deniedResult = try await denied.model.addPendingPastedText(fullText, for: denied.aID, canCommit: { false })
        try Check.that(!deniedResult && AttachmentStore.saveAttempts == 0, "initial denied authorization does not write")
        try denied.assertDraftsUnchanged("initial denial")
        try Check.that(AttachmentStore.generated.isEmpty && AttachmentStore.deleted.isEmpty, "initial denial creates/deletes no files")

        let cancelledBefore = try Fixture(root: root, name: "cancelled-before-io")
        let initiallyCancelledTask = Task { @MainActor in
            try await cancelledBefore.model.addPendingPastedText(fullText, for: cancelledBefore.aID, canCommit: { true })
        }
        initiallyCancelledTask.cancel()
        let cancelledBeforeResult = try await initiallyCancelledTask.value
        try Check.that(!cancelledBeforeResult && AttachmentStore.saveAttempts == 0, "initial cancellation does not write")
        try cancelledBefore.assertDraftsUnchanged("initial cancellation")
        print("PASS: missing conversation, denied authorization and initial cancellation stop before IO")

        let failure = try Fixture(root: root, name: "io-failure")
        AttachmentStore.failNextWrite = true
        do {
            _ = try await failure.model.addPendingPastedText(fullText, for: failure.aID, canCommit: { true })
            throw HarnessFailure(message: "IO error was swallowed")
        } catch FixtureIOError.failed {}
        try Check.that(AttachmentStore.saveAttempts == 1, "IO failure attempted once")
        try Check.that(AttachmentStore.generated.isEmpty && AttachmentStore.deleted.isEmpty, "IO failure has no published or unrelated deleted attachment")
        try failure.assertDraftsUnchanged("IO failure")
        try failure.assertOldFilesExist("IO failure")
        print("PASS: IO error propagates while all composer state stays intact")

        let revoked = try Fixture(root: root, name: "revoked-during-io")
        AttachmentStore.suspendReturns = true
        var allowed = true
        let revokedTask = Task { @MainActor in
            try await revoked.model.addPendingPastedText(fullText, for: revoked.aID, canCommit: { allowed })
        }
        await AttachmentStore.waitForWrites(1)
        let revokedAttachment = AttachmentStore.generated[0]
        allowed = false
        AttachmentStore.release(revokedAttachment)
        let revokedResult = try await revokedTask.value
        try Check.that(!revokedResult, "authorization revoked during IO denies commit")
        try revoked.assertDraftsUnchanged("mid-IO revocation")
        try revoked.assertOnlyGeneratedDeleted(revokedAttachment, "mid-IO revocation")

        let deleted = try Fixture(root: root, name: "deleted-during-io")
        AttachmentStore.suspendReturns = true
        let deletedTask = Task { @MainActor in
            try await deleted.model.addPendingPastedText(fullText, for: deleted.aID, canCommit: { true })
        }
        await AttachmentStore.waitForWrites(1)
        let deletedAttachment = AttachmentStore.generated[0]
        deleted.model.conversations.removeAll { $0.id == deleted.aID }
        deleted.model.setComposerDraftText("", for: deleted.aID)
        deleted.model.setComposerPendingAttachments([], for: deleted.aID)
        AttachmentStore.release(deletedAttachment)
        let deletedResult = try await deletedTask.value
        try Check.that(!deletedResult, "conversation deleted during IO denies commit")
        try Check.that(deleted.model.composerDraftText(for: deleted.aID).isEmpty && deleted.model.composerPendingAttachments(for: deleted.aID).isEmpty, "deleted conversation packet is not recreated")
        try Check.that(deleted.model.composerDraftText(for: deleted.bID) == deleted.bDraft && deleted.model.composerPendingAttachments(for: deleted.bID) == [deleted.bOld], "deletion race does not touch B")
        try deleted.assertOnlyGeneratedDeleted(deletedAttachment, "mid-IO deletion")

        let cancelled = try Fixture(root: root, name: "cancelled-during-io")
        AttachmentStore.suspendReturns = true
        let cancelledTask = Task { @MainActor in
            try await cancelled.model.addPendingPastedText(fullText, for: cancelled.aID, canCommit: { true })
        }
        await AttachmentStore.waitForWrites(1)
        let cancelledAttachment = AttachmentStore.generated[0]
        cancelledTask.cancel()
        AttachmentStore.release(cancelledAttachment)
        let cancelledResult = try await cancelledTask.value
        try Check.that(!cancelledResult, "cancellation while IO returns denies commit")
        try cancelled.assertDraftsUnchanged("mid-IO cancellation")
        try cancelled.assertOnlyGeneratedDeleted(cancelledAttachment, "mid-IO cancellation")
        print("PASS: post-IO revocation, conversation deletion and cancellation delete only their generated file")

        let live = try Fixture(root: root, name: "live-packet-during-io")
        AttachmentStore.suspendReturns = true
        let liveTask = Task { @MainActor in
            try await live.model.addPendingPastedText(fullText, for: live.aID, canCommit: { true })
        }
        await AttachmentStore.waitForWrites(1)
        let liveAttachment = AttachmentStore.generated[0]
        let concurrentlyAdded = try AttachmentStore.seed("added by another composer action")
        live.model.setComposerDraftText("edited while paste IO ran", for: live.aID)
        live.model.setComposerPendingAttachments([live.aOld, concurrentlyAdded], for: live.aID)
        live.model.selectedConversationID = live.bID
        AttachmentStore.release(liveAttachment)
        let liveResult = try await liveTask.value
        try Check.that(liveResult, "live packet still permits commit")
        try Check.that(live.model.composerDraftText(for: live.aID) == "edited while paste IO ran", "post-IO commit preserves newer text")
        try Check.that(live.model.composerPendingAttachments(for: live.aID) == [live.aOld, concurrentlyAdded, liveAttachment], "post-IO append retains concurrently added attachment")
        try Check.that(live.model.composerPendingAttachments(for: live.bID) == [live.bOld] && live.model.composerDraftText(for: live.bID) == live.bDraft, "selection change cannot redirect saved paste")
        try Check.that(AttachmentStore.deleted.isEmpty, "live append has no unrelated cleanup")
        print("PASS: latest packet is read after IO, and selection change cannot redirect a paste")

        let parallel = try Fixture(root: root, name: "two-conversations")
        AttachmentStore.suspendReturns = true
        let textA = "A starts\n" + fullText
        let textB = "B starts\r\n" + fullText
        let taskA = Task { @MainActor in
            try await parallel.model.addPendingPastedText(textA, for: parallel.aID, canCommit: { true })
        }
        await AttachmentStore.waitForWrites(1)
        let attachmentA = AttachmentStore.generated[0]
        let taskB = Task { @MainActor in
            try await parallel.model.addPendingPastedText(textB, for: parallel.bID, canCommit: { true })
        }
        await AttachmentStore.waitForWrites(2)
        let attachmentB = AttachmentStore.generated[1]
        parallel.model.selectedConversationID = parallel.bID
        AttachmentStore.release(attachmentB)
        let resultB = try await taskB.value
        try Check.that(resultB && parallel.model.composerPendingAttachments(for: parallel.bID) == [parallel.bOld, attachmentB], "B may finish first in B packet")
        try Check.that(parallel.model.composerPendingAttachments(for: parallel.aID) == [parallel.aOld], "A remains unchanged until its own IO completes")
        AttachmentStore.release(attachmentA)
        let resultA = try await taskA.value
        try Check.that(resultA && parallel.model.composerPendingAttachments(for: parallel.aID) == [parallel.aOld, attachmentA], "A finishes into A packet even while B selected")
        try Check.that(try Data(contentsOf: attachmentA.localURL) == Data(textA.utf8), "A content belongs to A attachment")
        try Check.that(try Data(contentsOf: attachmentB.localURL) == Data(textB.utf8), "B content belongs to B attachment")
        try Check.that(parallel.model.composerDraftText(for: parallel.aID) == parallel.aDraft && parallel.model.composerDraftText(for: parallel.bID) == parallel.bDraft, "parallel conversions preserve both drafts")
        try Check.that(AttachmentStore.deleted.isEmpty && AttachmentStore.gates.isEmpty && AttachmentStore.waiters.isEmpty, "parallel requests leave no cleanup or pending gate")
        try parallel.assertOldFilesExist("parallel conversion")
        print("PASS: out-of-order completions remain isolated to the requested conversation")
        print("PASS: \(Check.count) production composer transaction assertions")
    }
}
'''


def main():
    source = APP.read_text()
    packet = block(source, "private struct ConversationComposerPacket")
    markers = [
        "    func composerDraftText(for conversationID: UUID)",
        "    func setComposerDraftText(_ text: String, for conversationID: UUID)",
        "    func composerPendingAttachments(",
        "    func setComposerPendingAttachments(",
        "    private func updateComposerPacket(",
        "    func addPendingPastedText(",
    ]
    methods = [block(source, marker) for marker in markers]
    current_case = request_file_case(source)
    baseline_case = request_file_case(BASELINE.read_text())
    marked_start = current_case.index("if AttachmentStore.isPastedText(attachment)")
    regular_start = current_case.index("                    } else if let fileText = AttachmentStore.readTextContent")
    marked_branch = current_case[marked_start:regular_start]
    assert "let fileText = try await AttachmentStore.readPastedTextContent(of: attachment)" in marked_branch
    assert 'content += "\\n\\n[文件: \\(name)]\\n\\(fileText)"' in marked_branch
    assert "try?" not in marked_branch and "catch" not in marked_branch and ".prefix(" not in marked_branch
    current_regular = current_case[regular_start:].replace("} else if", "if", 1)
    baseline_regular = baseline_case[baseline_case.index("                    if let fileText = AttachmentStore.readTextContent"):]
    assert current_regular == baseline_regular, "Ordinary TXT handling changed from 5012 baseline"
    print("PASS: marked pasted TXT uses throwing async full-text read; errors cannot fall through to filename-only fallback", flush=True)
    print("PASS: ordinary TXT read/fallback branch is byte-identical to frozen 5012 baseline", flush=True)

    host = SUPPORT.replace("// PRODUCTION_PACKET", packet).replace("    // PRODUCTION_COMPOSER_METHODS", "\n\n".join(methods)) + HARNESS
    OUT.mkdir(parents=True, exist_ok=True)
    swift = OUT / "PastedTextComposerHost.swift"
    binary = OUT / "pasted-text-composer-host"
    swift.write_text(host)
    compile_result = subprocess.run(
        ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete", str(swift), "-o", str(binary)],
        text=True, capture_output=True, timeout=120,
    )
    (OUT / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise RuntimeError(compile_result.stdout + compile_result.stderr)
    with tempfile.TemporaryDirectory(prefix="synthetic-io-", dir=OUT) as folder:
        result = subprocess.run([str(binary), folder], text=True, capture_output=True, timeout=30)
    (OUT / "run.log").write_text(result.stdout + result.stderr)
    print(result.stdout, end="", flush=True)
    if result.returncode:
        raise RuntimeError(result.stderr or f"Host exited {result.returncode}")
    evidence = {
        "status": "PASS",
        "source": str(APP.relative_to(ROOT)),
        "production_method_sha256": {marker.strip(): hashlib.sha256(method.encode()).hexdigest() for marker, method in zip(markers, methods)},
        "production_packet_sha256": hashlib.sha256(packet.encode()).hexdigest(),
        "marked_file_case_sha256": hashlib.sha256(current_case.encode()).hexdigest(),
        "ordinary_txt_matches_baseline": True,
        "baseline": str(BASELINE.relative_to(ROOT)),
        "host_scope": "Actual AppModel functions; synthetic controllable AttachmentStore and composer state; no app or device interaction",
        "stdout": result.stdout,
    }
    (OUT / "result.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
    print(f"Evidence: {OUT.relative_to(ROOT) / 'result.json'}", flush=True)


if __name__ == "__main__":
    main()
