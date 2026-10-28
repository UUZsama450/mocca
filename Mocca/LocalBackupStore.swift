import Foundation

struct LocalStorageLocations: Sendable {
    let root: URL
    init(root: URL) { self.root = root.resolvingSymlinksInPath().standardizedFileURL }
    var support: URL { root.appendingPathComponent("Library/Application Support", isDirectory: true) }
    var documents: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var exports: URL { temporary.appendingPathComponent("mocca_backups", isDirectory: true) }
    var safetyBackups: URL { support.appendingPathComponent("BackupRecovery/SafetyBackups", isDirectory: true) }

    static var app: Self { Self(root: URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()) }
}

struct LocalBackupFile: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case safety, exported, imported }
    let url: URL
    let kind: Kind
    let bytes: Int64
    let modifiedAt: Date
    var id: URL { url }
}

/// Only standalone ZIP copies are manageable here. Live databases, attachments,
/// and unfinished restore transactions are deliberately outside this allowlist.
struct LocalBackupStore: Sendable {
    let locations: LocalStorageLocations

    init(locations: LocalStorageLocations = .app) { self.locations = locations }

    func backups() -> [LocalBackupFile] {
        var candidates: [(URL, LocalBackupFile.Kind)] = []
        for url in contents(of: locations.safetyBackups) {
            let name = url.deletingPathExtension().lastPathComponent
            if url.pathExtension == "zip", name.hasPrefix("before-restore-"),
               UUID(uuidString: String(name.dropFirst("before-restore-".count))) != nil {
                candidates.append((url, .safety))
            }
        }
        for directory in contents(of: locations.exports) where directory.lastPathComponent.hasPrefix("mocca_backup_") {
            candidates.append((directory.appendingPathComponent(directory.lastPathComponent + ".zip"), .exported))
        }
        candidates.append((locations.documents.appendingPathComponent("mocca_pending_restore.zip"), .imported))
        return candidates.compactMap { url, kind in
            guard let values = regularFileValues(at: url) else { return nil }
            return LocalBackupFile(url: url.standardizedFileURL, kind: kind,
                bytes: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast)
        }.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt
        }
    }

    func remove(_ backup: LocalBackupFile, fileManager: FileManager = .default) throws {
        // Revalidate after the user confirms. A stale selection or a symlink
        // must never turn into deletion of a replacement or a live data file.
        guard backups().contains(backup) else { throw CocoaError(.fileReadNoSuchFile) }
        try fileManager.removeItem(at: backup.url)
        if backup.kind == .exported {
            let directory = backup.url.deletingLastPathComponent()
            if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    /// Creating the pre-restore safety copy must not retire the selected source.
    /// As before, other old temporary exports are retired on the next export.
    func cleanupPreviousExports(preserving sourceURL: URL?) {
        let source = sourceURL?.resolvingSymlinksInPath().standardizedFileURL
        for backup in backups() where backup.kind == .exported {
            guard backup.url.resolvingSymlinksInPath().standardizedFileURL != source else { continue }
            try? remove(backup)
        }
        // Moving a new safety ZIP out of tmp leaves an empty export directory.
        for directory in contents(of: locations.exports) where directory.lastPathComponent.hasPrefix("mocca_backup_") {
            guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL,
                  (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    private func regularFileValues(at url: URL) -> URLResourceValues? {
        let root = locations.root.standardizedFileURL
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return nil }
        let relative = String(path.dropFirst(root.path.count + 1))
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(relative).standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL == expected,
              let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .totalFileAllocatedSizeKey, .contentModificationDateKey
              ]), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return values
    }
}

struct LocalStorageBucket: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case images, files, chats, assistants, legacy, backups, other }
    let kind: Kind
    let bytes: Int64
    let fileCount: Int
    let urls: [URL]
    var id: Kind { kind }
}

enum LocalStorageInspector {
    static func scan(locations: LocalStorageLocations = .app) -> [LocalStorageBucket] {
        let backups = Set(LocalBackupStore(locations: locations).backups().map(\.url))
        let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"])
        let support = locations.support.path + "/"
        var groups: [LocalStorageBucket.Kind: [URL]] = [:]
        var sizes: [LocalStorageBucket.Kind: Int64] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        if let enumerator = FileManager.default.enumerator(at: locations.root,
            includingPropertiesForKeys: Array(keys), options: []) {
            for case let listedURL as URL in enumerator {
                guard let values = try? listedURL.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let url = listedURL.standardizedFileURL
                let isHidden = values.isHidden == true || url.path.dropFirst(locations.root.path.count)
                    .split(separator: "/").contains { $0.hasPrefix(".") }
                let kind: LocalStorageBucket.Kind
                if backups.contains(url) { kind = .backups }
                // Preserve the old attachment browser's hidden-file exclusion
                // while counting staging/metadata files in the read-only total.
                else if isHidden { kind = .other }
                else if url.path.hasPrefix(support + "Attachments/") {
                    kind = imageExtensions.contains(url.pathExtension.lowercased()) ? .images : .files
                } else if url.path.hasPrefix(support + "ConversationStore/") { kind = .chats }
                else if url.path.hasPrefix(support + "AssistantMedia/") { kind = .assistants }
                else if url.path.hasPrefix(support + "LegacyKelivoFiles/") { kind = .legacy }
                else { kind = .other }
                groups[kind, default: []].append(url)
                sizes[kind, default: 0] += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return LocalStorageBucket.Kind.allCases.map {
            LocalStorageBucket(kind: $0, bytes: sizes[$0, default: 0],
                fileCount: groups[$0, default: []].count, urls: groups[$0, default: []])
        }
    }

    static func byteCount(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
}
