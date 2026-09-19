#!/usr/bin/python3
"""Exercise real pasted-TXT IO and extracted attachment/Codable interfaces.

The normal pass compiles the production Foundation IO helper unchanged. A second
pass adds test-only deterministic barriers/faults after the atomic write and
worker success, exercising the production cancellation cleanup without timing
races. Only the test attachment directory is substituted; no app data is used.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IO = ROOT / "Mocca/PastedTextAttachment.swift"
ATTACHMENTS = ROOT / "Mocca/Attachments.swift"
STORE = ROOT / "Mocca/ConversationStore.swift"


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SUPPORT = r'''
import CryptoKit
import Foundation

enum FixtureStorage {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mocca-pasted-text-\(UUID().uuidString)", isDirectory: true)
}
struct TestFailure: Error { let message: String }
@MainActor enum Check {
    static var count = 0
    static func that(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !condition() { throw TestFailure(message: label) }
    }
    static func error(_ expected: PastedTextAttachmentError, _ action: () async throws -> Void) async throws {
        count += 1
        do { try await action() }
        catch let error as PastedTextAttachmentError {
            guard error == expected else { throw TestFailure(message: "Expected \(expected), got \(error)") }
            return
        }
        throw TestFailure(message: "Expected \(expected)")
    }
    static func cancelled(_ task: Task<PastedTextAttachmentIO.SavedText, any Error>) async throws {
        count += 1
        do { _ = try await task.value }
        catch is CancellationError { return }
        throw TestFailure(message: "Cancellation was not propagated")
    }
}
func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// The two barriers and injected failure are present only in the second host.
final class SaveProbe: @unchecked Sendable {
    enum Mode { case afterWrite, afterSuccess, failAfterWrite }
    static let shared = SaveProbe()
    private let lock = NSLock()
    private var mode: Mode?
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private(set) var ownedURL: URL?
    func arm(_ mode: Mode) {
        lock.lock(); defer { lock.unlock() }
        self.mode = mode
        ownedURL = nil
    }
    func waitUntilReached() { reached.wait() }
    func hit(_ checkpoint: Mode, url: URL) throws {
        lock.lock()
        let selected = mode
        let matches = selected == checkpoint
            || (selected == .failAfterWrite && checkpoint == .afterWrite)
        if matches { mode = nil; ownedURL = url }
        lock.unlock()
        guard matches else { return }
        if selected == .failAfterWrite { throw PastedTextAttachmentError.unableToSave }
        reached.signal()
        release.wait()
    }
}
'''


HARNESS = r'''
@main struct PastedTextHost {
    @MainActor static func main() async throws {
        try FileManager.default.createDirectory(at: FixtureStorage.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: FixtureStorage.root) }
        #if PASTED_TEXT_IO_FAULT_PROBES
        try await faultChecks()
        #else
        try await normalChecks()
        #endif
        print("PASTED_TEXT_ATTACHMENT_HOST=PASS assertions=\(Check.count)")
    }

    @MainActor static func normalChecks() async throws {
        let cases = [
            String(repeating: "a", count: 5_000),
            "HEAD" + String(repeating: "z", count: 59_993) + "TAIL",
            "\u{FEFF}  \r\n" + String(repeating: "👩🏽‍💻 e\u{301} 猫\r\n", count: 90_000) + "尾部\r\n\t  ",
            "  \r\n\t \u{200B}\u{0000}\u{FFFD}  ",
            ""
        ]
        try Check.that(cases[0].count == 5_000 && cases[1].count == 60_001, "threshold fixtures")
        try Check.that(cases[2].utf8.count > 1_048_576 && cases[2].count > 60_000, "large Unicode spans read chunks and old cap")
        var attachments: [MessageAttachment] = []
        for (index, text) in cases.enumerated() {
            let attachment = try await AttachmentStore.savePastedText(text)
            attachments.append(attachment)
            let original = Data(text.utf8)
            try Check.that(attachment.kind == .file && attachment.mimeType == "text/plain", "TXT kind and MIME \(index)")
            try Check.that(attachment.fileName == "粘贴文本.txt", "user-facing name \(index)")
            try Check.that(attachment.localURL?.lastPathComponent == "\(attachment.id.uuidString)_pasted.txt", "unique disk name \(index)")
            try Check.that(attachment.byteCount == Int64(original.count), "UTF-8 byte count \(index)")
            try Check.that(attachment.metadata[AttachmentStore.contentSHA256MetadataKey] == sha(original), "SHA256 \(index)")
            try Check.that(AttachmentStore.isPastedText(attachment), "explicit metadata marker \(index)")
            try Check.that(try Data(contentsOf: attachment.localURL!) == original, "complete atomic disk content \(index)")
            let read = try await AttachmentStore.readPastedTextContent(of: attachment)
            try Check.that(Data(read.utf8) == original, "read preserves exact UTF-8 including tail/BOM/CRLF/whitespace \(index)")
            let encoded = try JSONEncoder().encode(attachment)
            let decoded = try JSONDecoder().decode(MessageAttachment.self, from: encoded)
            try Check.that(decoded == attachment, "actual MessageAttachment Codable metadata and local path \(index)")
            let reread = try await AttachmentStore.readPastedTextContent(of: decoded)
            try Check.that(Data(reread.utf8) == original, "restored attachment sends complete text \(index)")
        }
        let duplicate = try await AttachmentStore.savePastedText(cases[0])
        try Check.that(duplicate.id != attachments[0].id && duplicate.localURL != attachments[0].localURL, "same contents receive independent files")
        try Check.that(duplicate.metadata[AttachmentStore.contentSHA256MetadataKey] == attachments[0].metadata[AttachmentStore.contentSHA256MetadataKey], "same contents stable hash")
        let ordinary = MessageAttachment(kind: .file, localURL: duplicate.localURL, fileName: "粘贴文本.txt", mimeType: "text/plain", byteCount: duplicate.byteCount)
        try Check.that(!AttachmentStore.isPastedText(ordinary), "name alone does not opt ordinary TXT into full-send path")
        try await Check.error(.invalidAttachment) { _ = try await AttachmentStore.readPastedTextContent(of: ordinary) }
        var missingHash = duplicate
        missingHash.metadata[AttachmentStore.contentSHA256MetadataKey] = nil
        try Check.that(AttachmentStore.isPastedText(missingHash), "damaged marked metadata still selects strict path")
        try await Check.error(.invalidAttachment) { _ = try await AttachmentStore.readPastedTextContent(of: missingHash) }
        var missingCount = duplicate
        missingCount.byteCount = nil
        try await Check.error(.invalidAttachment) { _ = try await AttachmentStore.readPastedTextContent(of: missingCount) }
        var wrongType = duplicate
        wrongType.mimeType = "image/jpeg"
        try await Check.error(.invalidAttachment) { _ = try await AttachmentStore.readPastedTextContent(of: wrongType) }
        let missing = try await AttachmentStore.savePastedText("missing file")
        try FileManager.default.removeItem(at: missing.localURL!)
        try await Check.error(.missingFile) { _ = try await AttachmentStore.readPastedTextContent(of: missing) }
        let changed = try await AttachmentStore.savePastedText("abcd")
        try Data("wxyz".utf8).write(to: changed.localURL!, options: .atomic)
        try await Check.error(.contentChanged) { _ = try await AttachmentStore.readPastedTextContent(of: changed) }
        try Check.that(FileManager.default.fileExists(atPath: changed.localURL!.path), "read failures never delete existing files")
        try Data("x".utf8).write(to: changed.localURL!, options: .atomic)
        try await Check.error(.contentChanged) { _ = try await AttachmentStore.readPastedTextContent(of: changed) }
        let invalid = try await AttachmentStore.savePastedText("ab")
        try Data([0xc3, 0x28]).write(to: invalid.localURL!, options: .atomic)
        try await Check.error(.invalidUTF8) { _ = try await AttachmentStore.readPastedTextContent(of: invalid) }
        let link = try await AttachmentStore.savePastedText("symlink")
        try FileManager.default.removeItem(at: link.localURL!)
        try FileManager.default.createSymbolicLink(at: link.localURL!, withDestinationURL: attachments[0].localURL!)
        try await Check.error(.invalidAttachment) { _ = try await AttachmentStore.readPastedTextContent(of: link) }
        let blocked = FixtureStorage.root.appendingPathComponent("existing-blocker.txt")
        try Data("existing sentinel".utf8).write(to: blocked)
        let beforeFailure = try Set(FileManager.default.contentsOfDirectory(atPath: FixtureStorage.root.path))
        try await Check.error(.unableToSave) {
            _ = try await PastedTextAttachmentIO.save("cannot create directory over file", directory: { blocked })
        }
        let afterFailure = try Set(FileManager.default.contentsOfDirectory(atPath: FixtureStorage.root.path))
        try Check.that(beforeFailure == afterFailure, "real IO failure leaves no output or cleanup damage")
        try Check.that(try Data(contentsOf: blocked) == Data("existing sentinel".utf8), "failed save cannot overwrite/delete existing file")
        let offMain = try await PastedTextAttachmentIO.save("worker IO", directory: {
            if Thread.isMainThread { throw TestFailure(message: "directory IO on main thread") }
            return FixtureStorage.root
        })
        try Check.that(FileManager.default.fileExists(atPath: offMain.url.path), "directory and write run on worker")
        print("PASS: unchanged production IO; 5000/60001/large Unicode/raw whitespace exact; Codable; strict metadata; missing/corrupt files and real write failure")
    }

    @MainActor static func faultChecks() async throws {
        let existing = try await AttachmentStore.savePastedText("existing preserved attachment")
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: FixtureStorage.root.path))
        for mode: SaveProbe.Mode in [.afterWrite, .afterSuccess] {
            SaveProbe.shared.arm(mode)
            let task = Task {
                try await PastedTextAttachmentIO.save("new cancelled attachment", directory: { FixtureStorage.root })
            }
            await Task.detached { SaveProbe.shared.waitUntilReached() }.value
            let createdURL = SaveProbe.shared.ownedURL!
            try Check.that(FileManager.default.fileExists(atPath: createdURL.path), "checkpoint has a real completed atomic file")
            task.cancel()
            SaveProbe.shared.release.signal()
            try await Check.cancelled(task)
            try Check.that(!FileManager.default.fileExists(atPath: createdURL.path), "cancelled operation cleans only its own new destination")
            try Check.that(try Set(FileManager.default.contentsOfDirectory(atPath: FixtureStorage.root.path)) == before, "cancel leaves prior attachments intact")
        }
        SaveProbe.shared.arm(.failAfterWrite)
        try await Check.error(.unableToSave) {
            _ = try await PastedTextAttachmentIO.save("new failed attachment", directory: { FixtureStorage.root })
        }
        try Check.that(!FileManager.default.fileExists(atPath: SaveProbe.shared.ownedURL!.path), "post-write failure removes owned output")
        try Check.that(try Set(FileManager.default.contentsOfDirectory(atPath: FixtureStorage.root.path)) == before, "post-write failure preserves every prior file")
        let original = try await AttachmentStore.readPastedTextContent(of: existing)
        try Check.that(original == "existing preserved attachment", "prior attachment still passes integrity verification")
        let cancelledRead = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AttachmentStore.readPastedTextContent(of: existing)
        }
        do {
            _ = try await cancelledRead.value
            throw TestFailure(message: "cancelled read unexpectedly succeeded")
        } catch is CancellationError {}
        try Check.that(FileManager.default.fileExists(atPath: existing.localURL!.path), "cancelled read never deletes input")
        print("PASS: deterministic test-only post-write/post-worker barriers; production cancellation and failure cleanup preserve existing attachments")
    }
}
'''


def main():
    attachments = ATTACHMENTS.read_text()
    store = STORE.read_text()
    io = IO.read_text()
    members = [
        re.search(r"^    (?:private )?static let " + name + r" = .+$", attachments, re.M).group(0)
        for name in ["contentSHA256MetadataKey", "pastedTextMetadataKey", "pastedTextMetadataVersion"]
    ]
    for marker in [
        "    static func resolvePersistedLocalURL(",
        "    static func persistedLocalReference(",
        "    static func savePastedText(",
        "    static func isPastedText(",
        "    static func readPastedTextContent(",
    ]:
        members.append(declaration(attachments, marker))
    attachment_store = """
enum AttachmentStore {
    static func directory() throws -> URL {
        try FileManager.default.createDirectory(at: FixtureStorage.root, withIntermediateDirectories: true)
        return FixtureStorage.root
    }
""" + "\n\n".join(members) + "\n}\n"
    model = declaration(store, "struct MessageAttachment: Codable,")
    host_code = "\n\n".join([SUPPORT, model, attachment_store, HARNESS])
    after_write = "                try data.write(to: destination.url, options: .atomic)"
    after_success = "                succeeded = true\n                return result"
    assert io.count(after_write) == 1 and io.count(after_success) == 1
    instrumented = io.replace(after_write, after_write + "\n                try SaveProbe.shared.hit(.afterWrite, url: destination.url)")
    instrumented = instrumented.replace(after_success, "                succeeded = true\n                try SaveProbe.shared.hit(.afterSuccess, url: result.url)\n                return result")
    with tempfile.TemporaryDirectory(prefix="mocca-pasted-text-host-") as temp:
        temp_path = Path(temp)
        host = temp_path / "PastedTextAttachmentHost.swift"
        host.write_text(host_code)
        instrumented_path = temp_path / "PastedTextAttachmentProbed.swift"
        instrumented_path.write_text(instrumented)
        for label, source, flags in [
            ("unchanged-production", IO, []),
            ("deterministic-cleanup-faults", instrumented_path, ["-D", "PASTED_TEXT_IO_FAULT_PROBES"]),
        ]:
            binary = temp_path / label
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *flags,
                            str(source), str(host), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=120)
            print(result.stdout, end="")
            if result.returncode:
                print(result.stderr, end="")
                result.check_returncode()
        print(json.dumps({
            "production_io_sha256": hashlib.sha256(IO.read_bytes()).hexdigest(),
            "attachment_interface_sha256": hashlib.sha256("\n\n".join(members).encode()).hexdigest(),
            "message_attachment_codable_sha256": hashlib.sha256(model.encode()).hexdigest(),
            "scope": "real Foundation/CryptoKit filesystem and Codable; second pass only adds deterministic cleanup fault checkpoints; no composer/provider/device/network acceptance"
        }, ensure_ascii=False))


if __name__ == "__main__":
    main()
