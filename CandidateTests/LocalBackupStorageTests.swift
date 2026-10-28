import Foundation

private final class RefusingFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

@main @MainActor
struct LocalBackupStorageTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    static func mustFail(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(message) } catch { checks += 1 }
    }
    static func put(_ url: URL, _ text: String = "standalone backup") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func export(_ locations: LocalStorageLocations, _ name: String) -> URL {
        locations.exports.appendingPathComponent("mocca_backup_" + name)
            .appendingPathComponent("mocca_backup_" + name + ".zip")
    }
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("backup-storage-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = temporary.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = LocalStorageLocations(root: root)
        let store = LocalBackupStore(locations: locations)
        let current = locations.support.appendingPathComponent("ConversationStore/conversations_records.sqlite")
        let attachment = locations.support.appendingPathComponent("Attachments/photo.jpg")
        let previous = locations.support.appendingPathComponent("ConversationStore/previous-records/conversations_records.sqlite")
        let unfinished = locations.support.appendingPathComponent("BackupRecovery/restore-interrupted/previous/image.jpg")
        let safety = locations.safetyBackups.appendingPathComponent("before-restore-" + UUID().uuidString + ".zip")
        let oldExport = export(locations, "old")
        let sourceExport = export(locations, "selected")
        let imported = locations.documents.appendingPathComponent("mocca_pending_restore.zip")
        let unrelated = locations.documents.appendingPathComponent("personal.zip")
        for url in [current, attachment, previous, unfinished, safety, oldExport, sourceExport, imported, unrelated] {
            try put(url)
        }
        try put(locations.support.appendingPathComponent("Attachments/.staging/image.jpg"))
        try put(locations.support.appendingPathComponent("Attachments/.pending.zip"))
        let originalLive = try [current, attachment, previous, unfinished, unrelated].map { try Data(contentsOf: $0) }
        check(store.backups().count == 4, "Exactly the four managed ZIPs should be offered")
        check(Set(store.backups().map(\.url)) == Set([safety, oldExport, sourceExport, imported]), "No live or unrelated files offered")

        let buckets = LocalStorageInspector.scan(locations: locations)
        check(buckets.reduce(0) { $0 + $1.fileCount } == 11, "All local files counted once")
        check(buckets.first { $0.kind == .backups }?.fileCount == 4, "Backup storage included")
        check(buckets.first { $0.kind == .chats }?.fileCount == 2, "Internal database fallback remains chat storage")
        check(buckets.first { $0.kind == .other }?.fileCount == 4, "Recovery, unknown documents, and hidden staging counted as other")
        check(buckets.first { $0.kind == .images }?.urls == [attachment], "Hidden staging never offered for attachment deletion")
        let totalBefore = buckets.reduce(0) { $0 + $1.bytes }
        let emptyExport = locations.exports.appendingPathComponent("mocca_backup_empty")
        try FileManager.default.createDirectory(at: emptyExport, withIntermediateDirectories: true)

        // This is the real failure mode when restoring a temporary export:
        // creating a new safety backup must preserve the selected old ZIP.
        store.cleanupPreviousExports(preserving: sourceExport)
        check(!FileManager.default.fileExists(atPath: emptyExport.path), "Retire empty export directories")
        check(!FileManager.default.fileExists(atPath: oldExport.path), "Retire other old exports")
        check(FileManager.default.fileExists(atPath: sourceExport.path), "Keep the restore source readable")
        check(FileManager.default.fileExists(atPath: safety.path), "Export cleanup never removes safety copies")
        check(FileManager.default.fileExists(atPath: imported.path), "Export cleanup never removes old imports")
        check(LocalStorageInspector.scan(locations: locations).reduce(0) { $0 + $1.bytes } < totalBefore, "Statistics fall after deletion")

        let selected = store.backups().first { $0.url == imported }!
        mustFail("Surface deletion errors") { try store.remove(selected, fileManager: RefusingFileManager()) }
        check(FileManager.default.fileExists(atPath: imported.path), "Failed deletion keeps the file listed")
        try store.remove(selected)
        mustFail("Reject a stale, already deleted selection") { try store.remove(selected) }

        let forged = LocalBackupFile(url: current, kind: .safety, bytes: 0, modifiedAt: .distantPast)
        mustFail("Reject forged live-data deletion") { try store.remove(forged) }

        // Replace an allowlisted file with a symlink after a user selects it.
        let oldSafety = store.backups().first { $0.url == safety }!
        try FileManager.default.removeItem(at: safety)
        try FileManager.default.createSymbolicLink(at: safety, withDestinationURL: current)
        check(!store.backups().contains { $0.url == safety }, "Do not list a symlink to live data")
        mustFail("Recheck symlinks at deletion time") { try store.remove(oldSafety) }
        try FileManager.default.removeItem(at: safety)

        // A symlinked export directory must not expose a file outside its path.
        let external = locations.documents.appendingPathComponent("external")
        try put(external.appendingPathComponent("mocca_backup_link.zip"))
        try FileManager.default.createSymbolicLink(at: locations.exports.appendingPathComponent("mocca_backup_link"), withDestinationURL: external)
        check(!store.backups().contains { $0.url.lastPathComponent == "mocca_backup_link.zip" }, "Reject a symlinked parent")

        let stale = store.backups().first { $0.url == sourceExport }!
        try put(sourceExport, String(repeating: "replacement", count: 5000))
        mustFail("Do not delete a changed replacement") { try store.remove(stale) }
        store.cleanupPreviousExports(preserving: nil)
        check(!FileManager.default.fileExists(atPath: sourceExport.path), "Next export can retire an unprotected source")
        let remainingLive = try [current, attachment, previous, unfinished, unrelated].map { try Data(contentsOf: $0) }
        check(originalLive == remainingLive, "Live chats, images, database fallback, recovery, and unrelated files unchanged")

        // A metadata-only scan at roughly the observed phone file count. No ZIP
        // decompression or database reads occur in the production scanner.
        for i in 0..<1445 { try put(locations.support.appendingPathComponent("Attachments/fixture-\(i).jpg"), "image") }
        var milliseconds: [Double] = []
        for _ in 0..<7 {
            let start = ContinuousClock.now
            _ = LocalStorageInspector.scan(locations: locations)
            let elapsed = start.duration(to: .now)
            milliseconds.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        print("PASS: \(checks) safety/storage checks")
        print("Mac synthetic metadata scan, 1445 added files, median ms: \(milliseconds.sorted()[3])")
    }
}
