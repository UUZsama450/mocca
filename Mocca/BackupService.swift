import Foundation
import CryptoKit
import ImageIO
import Security
import UIKit
import zlib

struct BackupOptions: Codable, Hashable {
    var includeChats: Bool
    var includeFiles: Bool

    init(includeChats: Bool = true, includeFiles: Bool = true) {
        self.includeChats = includeChats
        self.includeFiles = includeFiles
    }
}

enum BackupRestoreMode: String, CaseIterable, Identifiable {
    case overwrite
    case merge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite: "完全覆盖"
        case .merge: "智能合并"
        }
    }

    var description: String {
        switch self {
        case .overwrite: "清空本地同类数据后恢复"
        case .merge: "仅添加不存在的数据（智能去重）"
        }
    }
}

enum BackupOptionsPersistence {
    private static let key = "backup_options_v1"

    static func load() -> BackupOptions {
        guard let data = UserDefaults.standard.data(forKey: key),
              let options = try? JSONDecoder().decode(BackupOptions.self, from: data) else {
            return BackupOptions()
        }
        return options
    }

    static func save(_ options: BackupOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct MoccaBackupManifest: Codable {
    var app: String
    var bundleID: String
    var schema: String
    var schemaVersion: Int
    var exportedAt: Date
    var includeChats: Bool
    var includeFiles: Bool
    var contentSummary: BackupContentSummary?
    var warnings: [String]?
}

struct BackupContentSummary: Codable, Hashable {
    var providers: Int
    var assistants: Int
    var conversations: Int
    var messages: Int
    var referencedAttachments: Int
    var packedFiles: Int
    var mcpServers: Int
}

enum BackupArchiveKind: Hashable {
    case legacyKelivo
    case kelivo2Native
    case moccaNative

    var title: String {
        switch self {
        case .legacyKelivo: "旧版 ZIP 备份"
        case .kelivo2Native: "早期原生备份"
        case .moccaNative: "Mocca 原生备份"
        }
    }
}

struct BackupInspection: Hashable {
    var kind: BackupArchiveKind
    var exportedAt: Date?
    var conversations: Int
    var messages: Int
    var referencedAttachments: Int
    var availableAttachments: Int
    var packedFiles: Int
    var missingAttachmentExamples: [String]
    var warnings: [String]

    var missingAttachments: Int {
        max(0, referencedAttachments - availableAttachments)
    }

    /// Native archives promise an exact attachment graph and must never be
    /// restored after silently dropping broken references. Old Kelivo 1 text
    /// markers can remain visible as text, but require a separate acknowledgement.
    var blocksRestore: Bool {
        kind != .legacyKelivo && missingAttachments > 0
    }

    var requiresMissingImageAcknowledgement: Bool {
        kind == .legacyKelivo && missingAttachments > 0
    }

    var summaryMessage: String {
        var lines = [
            "已识别：\(kind.title)",
            "聊天 \(conversations) 个，消息 \(messages) 条",
            "聊天图片/附件 \(availableAttachments) / \(referencedAttachments) 个可恢复",
            "压缩包内文件 \(packedFiles) 个",
        ]
        if let exportedAt {
            lines.insert(
                "导出时间：\(exportedAt.formatted(date: .numeric, time: .shortened))",
                at: 1
            )
        }
        if missingAttachments > 0 {
            lines.append("缺少 \(missingAttachments) 个聊天图片/附件")
        } else {
            lines.append("完整性检查通过")
        }
        if !missingAttachmentExamples.isEmpty {
            lines.append("例如：" + missingAttachmentExamples.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}

struct MoccaBackupSettings: Codable {
    var schemaVersion: Int
    var exportedAt: Date
    var appearanceMode: AppearanceMode
    var preferences: UserPreferences
    var proxySettings: ProxySettings
    var providers: [ProviderConfiguration]
    var selectedModel: ModelSelection?
    var favoriteModelKeys: Set<String>
    var favoriteProviderIDs: Set<UUID>?
    var assistants: [AssistantProfile]
    var currentAssistantID: UUID
    var instructionInjections: [InstructionInjection]
    var activeInstructionIDsByAssistant: [String: Set<UUID>]
    var worldBooks: [WorldBook]
    var activeWorldBookIDsByAssistant: [String: Set<UUID>]
    var quickPhrases: [QuickPhrase]
    var userProfile: UserProfile
    var calendar: MoccaCalendarPayload?
    var backgroundGenerationSettings: IOSBackgroundGenerationSettings?
    var mcpServers: [MCPServerConfig]?
    var mcpRequestTimeoutSeconds: Int?
    var sponsorEasterEgg: SponsorEasterEggBackupState?
    var firstRunModelSetupWasPresented: Bool?
}

struct BackupCreationResult {
    var url: URL
    var summary: BackupContentSummary
    var warnings: [String]

    var message: String {
        var value = "备份已生成：对话 \(summary.conversations)，消息 \(summary.messages)，附件引用 \(summary.referencedAttachments)，文件 \(summary.packedFiles)"
        if !warnings.isEmpty {
            value += "；注意：" + warnings.joined(separator: "；")
        }
        return value
    }
}

enum BackupServiceError: LocalizedError {
    case missingTemporaryDirectory
    case fileTooLarge(String)
    case invalidBackup(String)
    case unsupportedCompression(String)
    case checksumMismatch(String)
    case conversationStoreUnavailable
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTemporaryDirectory:
            ErrorLocalization.lookup("无法创建临时备份目录")
        case .fileTooLarge(let name):
            ErrorLocalization.format("备份文件过大，当前 ZIP 格式暂不支持超过 4GB 的单个文件：%@", [String(describing: name)])
        case .invalidBackup(let reason):
            ErrorLocalization.format("备份文件无效：%@", [String(describing: reason)])
        case .unsupportedCompression(let path):
            ErrorLocalization.format("暂不支持该 ZIP 压缩方式：%@", [String(describing: path)])
        case .checksumMismatch(let path):
            ErrorLocalization.format("备份文件校验失败：%@", [String(describing: path)])
        case .conversationStoreUnavailable:
            ErrorLocalization.lookup("聊天记录暂时无法读取，已停止恢复，避免覆盖现有数据")
        case .restoreFailed(let reason):
            reason
        }
    }
}

/// One user-requested restore only. Old directories survive until the model's
/// synchronous commit succeeds; this is not a crash-atomic multi-file store.
final class BackupRestoreFiles {
    private struct Directory {
        let destination: URL
        let staged: URL?
        let previous: URL
        var hasPrevious = false
        var installed = false
    }

    let recoveryURL: URL
    private let fileManager: FileManager
    private var directories: [Directory] = []

    init(root: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        recoveryURL = root.appendingPathComponent("BackupRecovery", isDirectory: true)
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
    }

    @discardableResult
    func stage(entries: [String: Data], prefix: String, destination: URL, mode: BackupRestoreMode) throws -> Int {
        let archivePrefix = prefix + "/"
        let matching = entries.filter { $0.key.hasPrefix(archivePrefix) }
        // An empty archived category has always left the local category alone.
        guard !matching.isEmpty else { return 0 }
        let slot = recoveryURL.appendingPathComponent(String(directories.count), isDirectory: true)
        try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
        let staged = slot.appendingPathComponent("incoming", isDirectory: true)
        if mode == .merge, fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: destination, to: staged)
        } else {
            try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        }
        var count = 0
        for (path, data) in matching.sorted(by: { $0.key < $1.key }) {
            let parts = path.dropFirst(archivePrefix.count).split(separator: "/").map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { continue }
            let target = parts.reduce(staged) { $0.appendingPathComponent($1) }
            if mode == .merge, fileManager.fileExists(atPath: target.path) { continue }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            count += 1
        }
        directories.append(Directory(destination: destination, staged: staged,
            previous: slot.appendingPathComponent("previous", isDirectory: true)))
        return count
    }

    /// These directories can also be changed by settings/font/draft restoration.
    func protect(_ destination: URL) throws {
        guard !directories.contains(where: { $0.destination == destination }) else { return }
        let slot = recoveryURL.appendingPathComponent(String(directories.count), isDirectory: true)
        try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
        let previous = slot.appendingPathComponent("previous", isDirectory: true)
        var entry = Directory(destination: destination, staged: nil, previous: previous)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: destination, to: previous)
            entry.hasPrevious = true
        }
        directories.append(entry)
    }

    func install() throws {
        for index in directories.indices {
            guard let staged = directories[index].staged else { continue }
            let destination = directories[index].destination
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: directories[index].previous)
                directories[index].hasPrevious = true
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staged, to: destination)
            directories[index].installed = true
        }
    }

    func rollback(modelWasChanged: Bool) -> [String] {
        var failures: [String] = []
        for entry in directories.reversed() {
            guard entry.staged != nil ? (entry.hasPrevious || entry.installed) : modelWasChanged else { continue }
            do {
                if fileManager.fileExists(atPath: entry.destination.path) {
                    try fileManager.removeItem(at: entry.destination)
                }
                if entry.hasPrevious {
                    try fileManager.moveItem(at: entry.previous, to: entry.destination)
                }
            } catch {
                failures.append("\(entry.destination.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return failures
    }

    func cleanup() throws {
        try fileManager.removeItem(at: recoveryURL)
    }
}

/// Only the defaults and three credential services written by backup restore.
/// Kept separately from the live model so a failed save can restore exact old
/// values, including absent keys, without re-running import/merge semantics.
struct BackupRestoreSettingsCheckpoint {
    private struct Credential: Equatable {
        let data: Data
        let accessibility: String?
        let accessGroup: String?
    }
    private static let keys = [
        "appearance_mode_v1", "network_proxy_v1", "user_preferences_v1",
        "providers_v1", "selected_model_v1", "favorite_model_keys_v1", "favorite_provider_ids_v1",
        "assistant_profiles_v1", "current_assistant_id_v1", "first_run_model_setup_presented_v1",
        "instruction_injections_v1", "instruction_active_ids_by_assistant_v1",
        "world_books_v1", "world_book_active_ids_by_assistant_v1", "quick_phrases_v1", "user_profile_v1",
        "ios_background_generation_settings_v1", "mcp_servers_v1", "mcp_request_timeout_seconds_v1",
        "sponsor.easterEgg.pendingTiers.v1", "sponsor.easterEgg.armedConversationID.v1",
        "sponsor.easterEgg.armedTier.v1", "sponsor.easterEgg.discoveredTiers.v1",
        "sponsor.easterEgg.selectedTier.v1", "sponsor.easterEgg.selectedItem.v2", "sponsor.easterEgg.wearer.v1"
    ]
    private static let services = ["com.uuzsama450.mocca.providers", "com.uuzsama450.mocca.search", "com.uuzsama450.mocca.voice"]
    private let values: [String: Any]
    private let credentials: [String: [String: Credential]]

    init() throws {
        values = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        credentials = try Dictionary(uniqueKeysWithValues: Self.services.map { ($0, try Self.readCredentials(service: $0)) })
    }

    private static func readCredentials(service: String) throws -> [String: Credential] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let entries = result as? [[String: Any]] else {
            throw BackupServiceError.restoreFailed("无法读取恢复前的服务密钥（\(status)），已停止恢复")
        }
        var values: [String: Credential] = [:]
        for entry in entries {
            guard let account = entry[kSecAttrAccount as String] as? String,
                  let data = entry[kSecValueData as String] as? Data,
                  values[account] == nil else {
                throw BackupServiceError.restoreFailed("服务密钥格式无法确认，已停止恢复")
            }
            values[account] = Credential(data: data,
                accessibility: entry[kSecAttrAccessible as String] as? String,
                accessGroup: entry[kSecAttrAccessGroup as String] as? String)
        }
        return values
    }

    static func verifySavedCredentials(providers: [ProviderConfiguration], preferences: UserPreferences) throws {
        let providerValues = try readCredentials(service: services[0])
        let searchValues = try readCredentials(service: services[1])
        let voiceValues = try readCredentials(service: services[2])
        func require(_ value: String, in values: [String: Credential], account: String) throws {
            let expected = value.isEmpty ? nil : Data(value.utf8)
            guard values[account]?.data == expected else {
                throw BackupServiceError.restoreFailed("服务密钥保存校验失败，已停止恢复")
            }
        }
        for provider in providers {
            try require(provider.apiKey, in: providerValues, account: provider.id.uuidString)
            let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider.apiKeys))
            guard let data = providerValues[provider.id.uuidString + ".multi-keys"]?.data,
                  let actual = try? JSONSerialization.jsonObject(with: data),
                  NSDictionary(dictionary: ["value": expected]).isEqual(to: ["value": actual]) else {
                throw BackupServiceError.restoreFailed("服务多密钥保存校验失败，已停止恢复")
            }
        }
        for service in preferences.searchServices {
            try require(service.apiKey, in: searchValues, account: service.id.uuidString + ".apiKey")
            try require(service.password, in: searchValues, account: service.id.uuidString + ".password")
        }
        for service in preferences.voiceServices {
            try require(service.apiKey, in: voiceValues, account: service.id.uuidString)
        }
    }

    func restore() -> [String] {
        var failures: [String] = []
        for key in Self.keys {
            if let value = values[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for service in Self.services {
            do {
                let current = try Self.readCredentials(service: service)
                let previous = credentials[service] ?? [:]
                for account in Set(current.keys).union(previous.keys) {
                    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service, kSecAttrAccount as String: account]
                    if let group = previous[account]?.accessGroup ?? current[account]?.accessGroup {
                        query[kSecAttrAccessGroup as String] = group
                    }
                    let status: OSStatus
                    if let value = previous[account] {
                        var attributes: [String: Any] = [kSecValueData as String: value.data]
                        if let accessibility = value.accessibility { attributes[kSecAttrAccessible as String] = accessibility }
                        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                        if updated == errSecItemNotFound {
                            let insert = query.merging(attributes) { _, new in new }
                            status = SecItemAdd(insert as CFDictionary, nil)
                        } else { status = updated }
                    } else { status = SecItemDelete(query as CFDictionary) }
                    if status != errSecSuccess && !(previous[account] == nil && status == errSecItemNotFound) {
                        failures.append("服务密钥回滚失败（\(status)）")
                    }
                }
                if try Self.readCredentials(service: service) != previous {
                    failures.append("服务密钥回滚校验失败")
                }
            } catch { failures.append(error.localizedDescription) }
        }
        let restored = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        if !NSDictionary(dictionary: values).isEqual(to: restored) { failures.append("设置回滚校验失败") }
        return failures
    }
}

enum BackupService {
    private static let currentNativeBackupSchemaVersion = 3

    static func inspectBackup(from sourceURL: URL) throws -> BackupInspection {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let reader = try ZipArchiveReader(data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let manifestData = reader.entries["manifest.json"] else {
            guard let chatsData = reader.entries["chats.json"] else {
                throw BackupServiceError.invalidBackup(
                    "既没有原生备份的 manifest.json，也没有旧版备份的 chats.json"
                )
            }
            let legacy = try LegacyKelivoBackup.decodeChats(from: chatsData)
            let imageInspection = LegacyImageArchiveResolver(entries: reader.entries)
                .inspect(messages: legacy.messages)
            return BackupInspection(
                kind: .legacyKelivo,
                exportedAt: nil,
                conversations: legacy.conversations.count,
                messages: legacy.messages.count,
                referencedAttachments: imageInspection.markers,
                availableAttachments: imageInspection.restorable,
                packedFiles: countPackedFiles(entries: reader.entries),
                missingAttachmentExamples: imageInspection.missingExamples,
                warnings: imageInspection.missing > 0
                    ? ["找不到的旧图片会保留为聊天中的原始 [image:…] 文字，不会假装已经恢复"]
                    : []
            )
        }

        let manifest = try decoder.decode(MoccaBackupManifest.self, from: manifestData)
        let kind: BackupArchiveKind
        switch manifest.schema {
        case "mocca-native-backup":
            kind = .moccaNative
        case "kelivo2-native-backup":
            kind = .kelivo2Native
        default:
            throw BackupServiceError.invalidBackup(
                "当前只支持 Mocca、早期原生格式或兼容的旧版 ZIP 备份"
            )
        }
        guard manifest.schemaVersion <= currentNativeBackupSchemaVersion else {
            throw BackupServiceError.invalidBackup(
                "备份来自更高版本（schema \(manifest.schemaVersion)）"
            )
        }

        if let settingsData = reader.entries["settings.json"] {
            let settings = try decoder.decode(MoccaBackupSettings.self, from: settingsData)
            guard settings.schemaVersion <= currentNativeBackupSchemaVersion else {
                throw BackupServiceError.invalidBackup(
                    "设置备份来自更高版本（schema \(settings.schemaVersion)）"
                )
            }
        }

        let snapshot: ConversationSnapshot?
        if manifest.includeChats {
            guard let chatsData = reader.entries["chats.json"] else {
                throw BackupServiceError.invalidBackup("清单声明包含聊天，但缺少 chats.json")
            }
            snapshot = try ConversationStore.decodeValidatedSnapshot(from: chatsData)
        } else {
            snapshot = nil
        }
        let attachmentAudit = auditArchivedAttachmentFiles(
            in: snapshot,
            entries: reader.entries
        )
        let messages = snapshot?.messagesByConversation.values.reduce(0) {
            $0 + $1.count
        } ?? 0
        var warnings = manifest.warnings ?? []
        if attachmentAudit.missingCount > 0 {
            warnings.append("压缩包不完整，恢复已被锁定；请重新选择或从旧 App 重新导出")
        }
        return BackupInspection(
            kind: kind,
            exportedAt: manifest.exportedAt,
            conversations: snapshot?.conversations.count ?? 0,
            messages: messages,
            referencedAttachments: attachmentAudit.referenceCount,
            availableAttachments: attachmentAudit.referenceCount - attachmentAudit.missingCount,
            packedFiles: countPackedFiles(entries: reader.entries),
            missingAttachmentExamples: attachmentAudit.missingExamples,
            warnings: warnings
        )
    }

    static func createBackup(
        options: BackupOptions,
        model: AppModel,
        allowMissingAttachmentReferences: Bool = false
    ) async throws -> BackupCreationResult {
        if options.includeChats {
            let canExportChats = await MainActor.run {
                model.prepareForBackupRestore()
            }
            guard canExportChats else {
                throw BackupServiceError.conversationStoreUnavailable
            }
        }
        let exportedAt = Date()
        let timestamp = Self.timestamp(for: exportedAt)
        let directory = try createWorkDirectory(timestamp: timestamp)
        let outputURL = directory.appendingPathComponent("mocca_backup_\(timestamp).zip")

        var writer = ZipArchiveWriter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let captured = await MainActor.run {
            MoccaBackupSettings(
                schemaVersion: 3,
                exportedAt: exportedAt,
                appearanceMode: model.appearanceMode,
                preferences: model.preferences,
                proxySettings: AppPreferences.loadProxySettings(),
                providers: model.providers,
                selectedModel: model.selectedModel,
                favoriteModelKeys: model.favoriteModelKeys,
                favoriteProviderIDs: model.favoriteProviderIDs,
                assistants: model.assistants,
                currentAssistantID: model.currentAssistantID,
                instructionInjections: model.instructionInjections,
                activeInstructionIDsByAssistant: model.activeInstructionIDsByAssistant,
                worldBooks: model.worldBooks,
                activeWorldBookIDsByAssistant: model.activeWorldBookIDsByAssistant,
                quickPhrases: model.quickPhrases,
                userProfile: model.userProfile,
                calendar: model.calendarPayload,
                backgroundGenerationSettings: model.backgroundGenerationSettings,
                mcpServers: model.mcpServers,
                mcpRequestTimeoutSeconds: model.mcpRequestTimeoutSeconds,
                sponsorEasterEgg: SponsorEasterEggPersistence.backupState(),
                firstRunModelSetupWasPresented:
                    ProviderPersistence.firstRunModelSetupWasPresented
            )
        }
        let preparedSettings = prepareOptionalMediaForBackup(
            captured,
            includeFiles: options.includeFiles
        )
        let settings = preparedSettings.settings
        var warnings = preparedSettings.warnings
        writer.addFile(path: "settings.json", data: try encoder.encode(settings))

        let snapshot: ConversationSnapshot?
        if options.includeChats {
            let capturedSnapshot = await MainActor.run {
                model.persistableConversationSnapshot()
            }
            let preparedSnapshot: ConversationSnapshot
            if options.includeFiles {
                let prepared = try prepareSnapshotForBackup(
                    capturedSnapshot,
                    allowMissingAttachmentReferences: allowMissingAttachmentReferences
                )
                preparedSnapshot = prepared.snapshot
                warnings.append(contentsOf: prepared.warnings)
            } else {
                preparedSnapshot = capturedSnapshot
            }
            let unresolvedLegacyImageMarkers = preparedSnapshot.messagesByConversation.values
                .flatMap { $0 }
                .filter {
                    $0.migrationMetadata?.source == "old_kelivo"
                        && $0.text.contains("[image:")
                }
                .count
            if unresolvedLegacyImageMarkers > 0 {
                warnings.append(
                    "发现 \(unresolvedLegacyImageMarkers) 条旧版图片路径仍未转成原生附件"
                )
            }
            let snapshotData = try encoder.encode(preparedSnapshot)
            _ = try ConversationStore.decodeValidatedSnapshot(
                from: snapshotData
            )
            writer.addFile(path: "chats.json", data: snapshotData)
            snapshot = preparedSnapshot
        } else {
            snapshot = nil
        }

        var packedFiles = 0
        if options.includeFiles {
            packedFiles += try addDirectoryIfPresent(
                named: "attachments",
                url: applicationSupportDirectory().appendingPathComponent("Attachments", isDirectory: true),
                to: &writer
            )
            packedFiles += try addDirectoryIfPresent(
                named: "assistant_media",
                url: applicationSupportDirectory().appendingPathComponent("AssistantMedia", isDirectory: true),
                to: &writer
            )
            packedFiles += try addDirectoryIfPresent(
                named: "app_fonts",
                url: applicationSupportDirectory().appendingPathComponent("AppFonts", isDirectory: true),
                to: &writer
            )
        }

        let messages = snapshot?.messagesByConversation.values.reduce(0) {
            $0 + $1.count
        } ?? 0
        let referencedAttachments = snapshot?.messagesByConversation.values.reduce(0) {
            $0 + $1.reduce(0) { $0 + $1.attachments.count }
        } ?? 0
        let summary = BackupContentSummary(
            providers: settings.providers.count,
            assistants: settings.assistants.count,
            conversations: snapshot?.conversations.count ?? 0,
            messages: messages,
            referencedAttachments: referencedAttachments,
            packedFiles: packedFiles,
            mcpServers: settings.mcpServers?.count ?? 0
        )
        let manifest = MoccaBackupManifest(
            app: "mocca",
            bundleID: Bundle.main.bundleIdentifier ?? "com.uuzsama450.mocca",
            schema: "mocca-native-backup",
            schemaVersion: 3,
            exportedAt: exportedAt,
            includeChats: options.includeChats,
            includeFiles: options.includeFiles,
            contentSummary: summary,
            warnings: warnings.isEmpty ? nil : warnings
        )
        writer.addFile(path: "manifest.json", data: try encoder.encode(manifest))

        let data = try writer.finalize()
        try data.write(to: outputURL, options: [.atomic])
        return BackupCreationResult(url: outputURL, summary: summary, warnings: warnings)
    }

    static func restoreBackup(
        from sourceURL: URL,
        mode: BackupRestoreMode,
        model: AppModel
    ) async throws -> BackupImportSummary {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let reader = try ZipArchiveReader(data: data)
        let canRestore = await MainActor.run {
            model.prepareForBackupRestore()
        }
        guard canRestore else {
            throw BackupServiceError.conversationStoreUnavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let manifestData = reader.entries["manifest.json"] else {
            return try await restoreLegacyKelivoBackup(reader: reader, mode: mode, model: model)
        }
        let manifest = try decoder.decode(MoccaBackupManifest.self, from: manifestData)
        let supportedSchemas = ["mocca-native-backup", "kelivo2-native-backup"]
        guard supportedSchemas.contains(manifest.schema) else {
            throw BackupServiceError.invalidBackup("当前只支持 Mocca 原生备份或兼容的旧版备份")
        }
        guard manifest.schemaVersion <= currentNativeBackupSchemaVersion else {
            throw BackupServiceError.invalidBackup(
                "备份来自更高版本（schema \(manifest.schemaVersion)）"
            )
        }

        var importWarnings = manifest.warnings ?? []
        let settings: MoccaBackupSettings?
        if let settingsData = reader.entries["settings.json"] {
            let decodedSettings = try decoder.decode(
                MoccaBackupSettings.self,
                from: settingsData
            )
            guard decodedSettings.schemaVersion <= currentNativeBackupSchemaVersion else {
                throw BackupServiceError.invalidBackup(
                    "设置备份来自更高版本（schema \(decodedSettings.schemaVersion)）"
                )
            }
            let prepared = prepareOptionalMediaForRestore(
                decodedSettings,
                manifestIncludesFiles: manifest.includeFiles,
                archiveEntries: reader.entries
            )
            settings = prepared.settings
            importWarnings.append(contentsOf: prepared.warnings)
        } else {
            settings = nil
        }

        let snapshot: ConversationSnapshot?
        if manifest.includeChats {
            guard let chatsData = reader.entries["chats.json"] else {
                throw BackupServiceError.invalidBackup("清单声明包含聊天，但缺少 chats.json")
            }
            let decodedSnapshot = try ConversationStore.decodeValidatedSnapshot(
                from: chatsData
            )
            try validateArchivedAttachmentFiles(
                in: decodedSnapshot,
                entries: reader.entries
            )
            snapshot = decodedSnapshot
        } else {
            snapshot = nil
        }

        let root = try applicationSupportDirectory()
        var summary = try await MainActor.run {
            try model.performBackupRestoreTransaction(root: root, prepareFiles: { files in
                guard manifest.includeFiles else { return 0 }
                var count = 0
                for (prefix, directory) in [("attachments", "Attachments"), ("assistant_media", "AssistantMedia"), ("app_fonts", "AppFonts")] {
                    count += try files.stage(entries: reader.entries, prefix: prefix,
                        destination: root.appendingPathComponent(directory, isDirectory: true), mode: mode)
                }
                return count
            }, restore: { restoredFiles in
                try model.restoreBackup(settings: settings, snapshot: snapshot, mode: mode, restoredFileCount: restoredFiles)
            })
        }
        summary.warnings.append(contentsOf: importWarnings)
        return summary
    }

    static func backupDirectorySizeDescription(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return "未知大小"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// An explicitly requested overwrite already creates one safety ZIP. Move
    /// that ZIP out of temporary export cleanup before touching live state.
    static func preserveSafetyBackup(_ result: BackupCreationResult) throws -> BackupCreationResult {
        let directory = try applicationSupportDirectory()
            .appendingPathComponent("BackupRecovery", isDirectory: true)
            .appendingPathComponent("SafetyBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "before-restore-\(UUID().uuidString).zip"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: result.url, to: destination)
        UserDefaults.standard.set(name, forKey: "backup_last_safety_file_v1")
        var preserved = result
        preserved.url = destination
        return preserved
    }

    static func latestSafetyBackupURL() -> URL? {
        guard let name = UserDefaults.standard.string(forKey: "backup_last_safety_file_v1"),
              name.hasPrefix("before-restore-"), name.hasSuffix(".zip"),
              !name.contains("/"), !name.contains("\\"),
              let root = try? applicationSupportDirectory() else { return nil }
        let url = root.appendingPathComponent("BackupRecovery/SafetyBackups", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private static func createWorkDirectory(timestamp: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mocca_backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try cleanupPreviousBackups(in: root)
        let directory = root.appendingPathComponent("mocca_backup_\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func cleanupPreviousBackups(in root: URL) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix("mocca_backup_") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ConversationStoreError.missingApplicationSupport
        }
        return root
    }

    private static func providerAvatarFileName(_ reference: String?) -> String? {
        guard let reference, reference.hasPrefix("file:") else { return nil }
        let name = String(reference.dropFirst("file:".count))
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != ".",
              name != ".." else {
            return nil
        }
        return name
    }

    private static func prepareOptionalMediaForBackup(
        _ settings: MoccaBackupSettings,
        includeFiles: Bool
    ) -> (settings: MoccaBackupSettings, warnings: [String]) {
        var copy = settings
        var warnings: [String] = []

        for index in copy.providers.indices
            where copy.providers[index].customAvatar != nil {
            let provider = copy.providers[index]
            guard includeFiles,
                  providerAvatarFileName(provider.customAvatar) != nil,
                  AssistantMediaStore.hasImage(for: provider.customAvatar) else {
                copy.providers[index].customAvatar = nil
                warnings.append("服务商“\(provider.name)”的自定义头像缺失，已改用自动头像")
                continue
            }
        }
        for index in copy.assistants.indices {
            if isMissingAssistantMedia(
                copy.assistants[index].avatar,
                includeFiles: includeFiles
            ) {
                copy.assistants[index].avatar = nil
                warnings.append("助手“\(copy.assistants[index].name)”的头像缺失，已改用默认头像")
            }
            if isMissingAssistantMedia(
                copy.assistants[index].background,
                includeFiles: includeFiles
            ) {
                copy.assistants[index].background = nil
                warnings.append("助手“\(copy.assistants[index].name)”的背景缺失，已跳过")
            }
        }
        if isMissingAssistantMedia(
            copy.preferences.sidebarBackground,
            includeFiles: includeFiles
        ) {
            copy.preferences.sidebarBackground = nil
            copy.preferences.sidebarBackgroundEnabled = false
            warnings.append("侧栏背景文件缺失，已关闭该背景")
        }
        if let fileName = copy.preferences.appFontFileName {
            let safeFileName = safeArchiveFileName(fileName)
            let fontURL = try? applicationSupportDirectory()
                .appendingPathComponent("AppFonts", isDirectory: true)
                .appendingPathComponent(safeFileName ?? "")
            let hasFont = includeFiles
                && safeFileName != nil
                && (fontURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            if !hasFont {
                copy.preferences.appFontFileName = nil
                copy.preferences.appFontPostScriptName = nil
                copy.preferences.appFontDisplayName = nil
                warnings.append("自定义字体文件缺失，已改用系统字体")
            }
        }
        return (copy, warnings)
    }

    private static func prepareOptionalMediaForRestore(
        _ settings: MoccaBackupSettings,
        manifestIncludesFiles: Bool,
        archiveEntries: [String: Data]
    ) -> (settings: MoccaBackupSettings, warnings: [String]) {
        var copy = settings
        var warnings: [String] = []

        for index in copy.providers.indices
            where copy.providers[index].customAvatar != nil {
            let provider = copy.providers[index]
            guard restoreArchiveHasAssistantMedia(
                provider.customAvatar,
                manifestIncludesFiles: manifestIncludesFiles,
                archiveEntries: archiveEntries
            ) else {
                copy.providers[index].customAvatar = nil
                warnings.append("服务商“\(provider.name)”的自定义头像缺失，已改用自动头像")
                continue
            }
        }
        for index in copy.assistants.indices {
            if !restoreArchiveHasAssistantMedia(
                copy.assistants[index].avatar,
                manifestIncludesFiles: manifestIncludesFiles,
                archiveEntries: archiveEntries
            ) {
                copy.assistants[index].avatar = nil
                warnings.append("助手“\(copy.assistants[index].name)”的头像缺失，已改用默认头像")
            }
            if !restoreArchiveHasAssistantMedia(
                copy.assistants[index].background,
                manifestIncludesFiles: manifestIncludesFiles,
                archiveEntries: archiveEntries
            ) {
                copy.assistants[index].background = nil
                warnings.append("助手“\(copy.assistants[index].name)”的背景缺失，已跳过")
            }
        }
        if !restoreArchiveHasAssistantMedia(
            copy.preferences.sidebarBackground,
            manifestIncludesFiles: manifestIncludesFiles,
            archiveEntries: archiveEntries
        ) {
            copy.preferences.sidebarBackground = nil
            copy.preferences.sidebarBackgroundEnabled = false
            warnings.append("侧栏背景文件缺失，已关闭该背景")
        }
        if let fileName = copy.preferences.appFontFileName {
            let safeFileName = safeArchiveFileName(fileName)
            let hasFont: Bool
            if manifestIncludesFiles, let safeFileName {
                hasFont = archiveEntries["app_fonts/\(safeFileName)"] != nil
            } else {
                let localURL = try? applicationSupportDirectory()
                    .appendingPathComponent("AppFonts", isDirectory: true)
                    .appendingPathComponent(safeFileName ?? "")
                hasFont = safeFileName != nil && (localURL.map {
                    FileManager.default.fileExists(atPath: $0.path)
                } ?? false)
            }
            if !hasFont {
                copy.preferences.appFontFileName = nil
                copy.preferences.appFontPostScriptName = nil
                copy.preferences.appFontDisplayName = nil
                warnings.append("自定义字体文件缺失，已改用系统字体")
            }
        }
        return (copy, warnings)
    }

    private static func isMissingAssistantMedia(
        _ reference: String?,
        includeFiles: Bool
    ) -> Bool {
        guard reference?.hasPrefix("file:") == true else { return false }
        return !includeFiles || !AssistantMediaStore.hasImage(for: reference)
    }

    private static func restoreArchiveHasAssistantMedia(
        _ reference: String?,
        manifestIncludesFiles: Bool,
        archiveEntries: [String: Data]
    ) -> Bool {
        guard reference?.hasPrefix("file:") == true else { return true }
        guard let name = providerAvatarFileName(reference) else { return false }
        if manifestIncludesFiles {
            guard let data = archiveEntries["assistant_media/\(name)"] else {
                return false
            }
            return UIImage(data: data) != nil
        }
        return AssistantMediaStore.hasImage(for: reference)
    }

    private static func safeArchiveFileName(_ value: String) -> String? {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value != ".",
              value != ".." else {
            return nil
        }
        return value
    }

    private static func prepareSnapshotForBackup(
        _ snapshot: ConversationSnapshot,
        allowMissingAttachmentReferences: Bool
    ) throws -> (snapshot: ConversationSnapshot, warnings: [String]) {
        var preparedSnapshot = snapshot
        var missing: [String] = []
        for conversationID in Array(preparedSnapshot.messagesByConversation.keys) {
            preparedSnapshot.messagesByConversation[conversationID] =
                preparedSnapshot.messagesByConversation[conversationID]?.map { message in
                    var preparedMessage = message
                    preparedMessage.attachments = message.attachments.filter { attachment in
                        guard let reference = AttachmentStore.persistedLocalReference(
                            for: attachment.localURL
                        ) else { return true }
                        guard let url = AttachmentStore.resolvePersistedLocalURL(reference),
                              let values = try? url.resourceValues(
                                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                              ),
                              values.isRegularFile == true,
                              values.isSymbolicLink != true else {
                            missing.append(attachment.fileName ?? reference)
                            return false
                        }
                        return true
                    }
                    return preparedMessage
                }
            }
        guard missing.isEmpty || allowMissingAttachmentReferences else {
            let examples = missing.prefix(3).joined(separator: "、")
            throw BackupServiceError.invalidBackup(
                "有 \(missing.count) 个聊天附件文件缺失（如：\(examples)），已停止导出，避免生成不完整备份文件"
            )
        }
        guard !missing.isEmpty else {
            return (preparedSnapshot, [])
        }
        return (
            preparedSnapshot,
            ["当前数据中有 \(missing.count) 个附件文件已经缺失；安全备份保留了聊天文字与现存文件，并跳过这些空附件引用"]
        )
    }

    private struct ArchivedAttachmentAudit {
        var referenceCount: Int
        var missingCount: Int
        var missingExamples: [String]
    }

    private static func auditArchivedAttachmentFiles(
        in snapshot: ConversationSnapshot?,
        entries: [String: Data]
    ) -> ArchivedAttachmentAudit {
        guard let snapshot else {
            return ArchivedAttachmentAudit(
                referenceCount: 0,
                missingCount: 0,
                missingExamples: []
            )
        }
        var referenceCount = 0
        var missing: [String] = []
        for attachment in snapshot.messagesByConversation.values
            .flatMap({ $0 })
            .flatMap(\.attachments) {
            guard let reference = AttachmentStore.persistedLocalReference(
                for: attachment.localURL
            ) else { continue }
            referenceCount += 1
            guard entries["attachments/\(reference)"] != nil else {
                missing.append(attachment.fileName ?? reference)
                continue
            }
        }
        return ArchivedAttachmentAudit(
            referenceCount: referenceCount,
            missingCount: missing.count,
            missingExamples: Array(missing.prefix(3))
        )
    }

    private static func validateArchivedAttachmentFiles(
        in snapshot: ConversationSnapshot,
        entries: [String: Data]
    ) throws {
        let audit = auditArchivedAttachmentFiles(in: snapshot, entries: entries)
        guard audit.missingCount == 0 else {
            let examples = audit.missingExamples.joined(separator: "、")
            throw BackupServiceError.invalidBackup(
                "备份缺少 \(audit.missingCount) 个聊天附件文件（如：\(examples)）；已停止恢复，请重新选择完整备份"
            )
        }
    }

    private static func countPackedFiles(
        entries: [String: Data]
    ) -> Int {
        let prefixes = [
            "attachments/", "assistant_media/", "app_fonts/",
            "upload/", "images/", "avatars/", "fonts/",
        ]
        return entries.keys.filter { path in
            prefixes.contains { path.hasPrefix($0) }
        }.count
    }

    private static func addDirectoryIfPresent(
        named archiveName: String,
        url directory: URL,
        to writer: inout ZipArchiveWriter
    ) throws -> Int {
        let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonicalDirectory.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        let directoryComponents = canonicalDirectory.pathComponents
        var count = 0
        for case let fileURL as URL in enumerator {
            let canonicalFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
            let values = try canonicalFileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let fileComponents = canonicalFileURL.pathComponents
            guard fileComponents.count > directoryComponents.count,
                  Array(fileComponents.prefix(directoryComponents.count)) == directoryComponents else {
                continue
            }
            let relativeComponents = fileComponents.dropFirst(directoryComponents.count)
            guard relativeComponents.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
            }) else { continue }
            let archivePath = ([archiveName] + Array(relativeComponents)).joined(separator: "/")
            let data = try Data(contentsOf: canonicalFileURL, options: [.mappedIfSafe])
            writer.addFile(path: archivePath, data: data)
            count += 1
        }
        return count
    }

    private static func restoreLegacyKelivoBackup(
        reader: ZipArchiveReader,
        mode: BackupRestoreMode,
        model: AppModel
    ) async throws -> BackupImportSummary {
        guard let chatsData = reader.entries["chats.json"] else {
            throw BackupServiceError.invalidBackup("缺少原生备份的 manifest.json，也没有旧版备份的 chats.json")
        }
        let settings = try reader.entries["settings.json"].map {
            try LegacyKelivoSettingsDecoder.decode(from: $0, archiveEntries: reader.entries)
        }
        let legacy = try LegacyKelivoBackup.decodeChats(from: chatsData)
        let imageResolver = LegacyImageArchiveResolver(entries: reader.entries)
        let converted = legacy.convertToNativeSnapshot(
            assistantIDMap: settings?.assistantIDMap ?? [:],
            providerIDMap: settings?.providerIDMap ?? [:],
            modelIDMap: settings?.modelIDMap ?? [:],
            imageResolver: imageResolver
        )
        let validationEncoder = JSONEncoder()
        validationEncoder.dateEncodingStrategy = .iso8601
        _ = try ConversationStore.decodeValidatedSnapshot(
            from: validationEncoder.encode(converted)
        )

        let root = try applicationSupportDirectory()
        return try await MainActor.run {
            try model.performBackupRestoreTransaction(root: root, prepareFiles: { files in
                var count = 0
                for prefix in ["upload", "images", "avatars", "fonts"] {
                    count += try files.stage(entries: reader.entries, prefix: prefix,
                        destination: root.appendingPathComponent("LegacyKelivoFiles", isDirectory: true)
                            .appendingPathComponent(prefix, isDirectory: true), mode: mode)
                }
                return count
            }, restore: { restoredFiles in
                try model.restoreLegacyKelivoBackup(settings: settings, snapshot: converted, mode: mode, restoredFileCount: restoredFiles)
            })
        }
    }
}

struct BackupImportSummary: Hashable {
    var importedProviders: Int
    var importedAssistants: Int
    var importedConversations: Int
    var importedMessages: Int
    var importedFiles: Int
    var importedWorldBooks: Int
    var importedQuickPhrases: Int
    var refreshedLegacyRecords: Bool
    var warnings: [String]

    init(
        importedProviders: Int,
        importedAssistants: Int,
        importedConversations: Int,
        importedMessages: Int,
        importedFiles: Int,
        importedWorldBooks: Int = 0,
        importedQuickPhrases: Int = 0,
        refreshedLegacyRecords: Bool = false,
        warnings: [String] = []
    ) {
        self.importedProviders = importedProviders
        self.importedAssistants = importedAssistants
        self.importedConversations = importedConversations
        self.importedMessages = importedMessages
        self.importedFiles = importedFiles
        self.importedWorldBooks = importedWorldBooks
        self.importedQuickPhrases = importedQuickPhrases
        self.refreshedLegacyRecords = refreshedLegacyRecords
        self.warnings = warnings
    }

    var message: String {
        let action = refreshedLegacyRecords ? "已刷新/导入" : "已导入"
        var value = "\(action)：供应商 \(importedProviders)，助手 \(importedAssistants)，世界书 \(importedWorldBooks)，快捷短语 \(importedQuickPhrases)，对话 \(importedConversations)，消息 \(importedMessages)，文件 \(importedFiles)"
        if !warnings.isEmpty {
            value += "；注意：" + warnings.joined(separator: "；")
        }
        return value
    }
}

struct LegacyKelivoSettingsImport: Sendable {
    var appearanceMode: AppearanceMode?
    var preferences: UserPreferences?
    var proxySettings: ProxySettings?
    var providers: [ProviderConfiguration]?
    var selectedModel: ModelSelection?
    var favoriteModelKeys: Set<String>?
    var assistants: [AssistantProfile]?
    var currentAssistantID: UUID?
    var instructionInjections: [InstructionInjection]?
    var activeInstructionIDsByAssistant: [String: Set<UUID>]?
    var worldBooks: [WorldBook]?
    var activeWorldBookIDsByAssistant: [String: Set<UUID>]?
    var quickPhrases: [QuickPhrase]?
    var userProfile: UserProfile?
    var legacyAppFontFileName: String?
    var assistantIDMap: [String: UUID]
    var providerIDMap: [String: UUID]
    var modelIDMap: [String: String]
}

private enum LegacyKelivoSettingsDecoder {
    static func decode(
        from data: Data,
        archiveEntries: [String: Data]
    ) throws -> LegacyKelivoSettingsImport {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupServiceError.invalidBackup("旧版备份的 settings.json 不是对象")
        }

        let providerResult = decodeProviders(from: values)
        let assistantResult = decodeAssistants(
            from: values,
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap,
            archiveEntries: archiveEntries
        )
        let instructionResult = decodeInstructions(
            from: values,
            assistantIDMap: assistantResult.idMap
        )
        let worldBookResult = decodeWorldBooks(
            from: values,
            assistantIDMap: assistantResult.idMap
        )

        let selectedModel = decodeModelSelection(
            string(values, "selected_model_v1"),
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
        let favoriteKeys = stringArray(values, "pinned_models_v1").map { key -> String? in
            decodeModelSelection(
                key,
                providerIDMap: providerResult.providerIDMap,
                modelIDMap: providerResult.modelIDMap
            )?.storageKey
        }

        let currentLegacyAssistantID = string(values, "current_assistant_id_v1")
        let currentAssistantID = currentLegacyAssistantID.flatMap { assistantResult.idMap[$0] }

        return LegacyKelivoSettingsImport(
            appearanceMode: decodeAppearanceMode(from: values),
            preferences: decodePreferences(from: values, providerResult: providerResult),
            proxySettings: decodeProxySettings(from: values),
            providers: providerResult.wasPresent ? providerResult.providers : nil,
            selectedModel: selectedModel,
            favoriteModelKeys: value(values, "pinned_models_v1") == nil
                ? nil
                : Set(favoriteKeys.compactMap { $0 }),
            assistants: assistantResult.wasPresent ? assistantResult.assistants : nil,
            currentAssistantID: currentAssistantID,
            instructionInjections: instructionResult.items,
            activeInstructionIDsByAssistant: instructionResult.activeMap,
            worldBooks: worldBookResult.items,
            activeWorldBookIDsByAssistant: worldBookResult.activeMap,
            quickPhrases: decodeQuickPhrases(from: values, assistantIDMap: assistantResult.idMap),
            userProfile: decodeUserProfile(from: values, archiveEntries: archiveEntries),
            legacyAppFontFileName: legacyAppFontFileName(
                from: values,
                archiveEntries: archiveEntries
            ),
            assistantIDMap: assistantResult.idMap,
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
    }

    private static func legacyAppFontFileName(
        from values: [String: Any],
        archiveEntries: [String: Data]
    ) -> String? {
        guard let localPath = string(values, "display_app_font_local_path_v1"),
              !localPath.isEmpty else { return nil }
        let expectedName = URL(fileURLWithPath: localPath).lastPathComponent
        return archiveEntries.keys.first { path in
            path.hasPrefix("fonts/")
                && URL(fileURLWithPath: path).lastPathComponent == expectedName
        }.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private struct ProviderDecodeResult {
        var providers: [ProviderConfiguration]
        var providerIDMap: [String: UUID]
        var modelIDMap: [String: String]
        var wasPresent: Bool
    }

    private static func decodeProviders(from values: [String: Any]) -> ProviderDecodeResult {
        guard let rawProviders = dictionary(values, "provider_configs_v1") else {
            return ProviderDecodeResult(providers: [], providerIDMap: [:], modelIDMap: [:], wasPresent: false)
        }

        var providers: [ProviderConfiguration] = []
        var providerIDMap: [String: UUID] = [:]
        var modelIDMap: [String: String] = [:]
        let preferredOrder = stringArray(values, "providers_order_v1")
        let keys = preferredOrder + rawProviders.keys.filter { !preferredOrder.contains($0) }.sorted()

        for key in keys {
            guard let raw = rawProviders[key] as? [String: Any] else { continue }
            let providerID = legacyStableUUID(namespace: "provider", sourceID: key)
            let rawID = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            providerIDMap[key] = providerID
            if let rawID, !rawID.isEmpty { providerIDMap[rawID] = providerID }
            if let name = raw["name"] as? String, !name.isEmpty { providerIDMap[name] = providerID }

            let type: ProviderType = switch (raw["providerType"] as? String)?.lowercased() {
            case "google": .google
            case "claude": .claude
            default: .openAI
            }
            let overrideMap = raw["modelOverrides"] as? [String: Any] ?? [:]
            let logicalModels = (raw["models"] as? [Any] ?? []).map { String(describing: $0) }
            var models: [ModelConfiguration] = []
            var seenModelIDs = Set<String>()
            for logicalID in logicalModels {
                let details = overrideMap[logicalID] as? [String: Any]
                if (details?["type"] as? String)?.lowercased() == "embedding" { continue }
                let apiID = ((details?["apiModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? logicalID
                let displayName = (details?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                modelIDMap["\(key)::\(logicalID)"] = apiID
                if let rawID, !rawID.isEmpty { modelIDMap["\(rawID)::\(logicalID)"] = apiID }
                guard seenModelIDs.insert(apiID).inserted else { continue }
                models.append(ModelConfiguration(id: apiID, displayName: displayName))
            }

            let legacyAPIKeys: [ProviderAPIKey] = (raw["apiKeys"] as? [Any] ?? []).compactMap { value in
                guard let item = value as? [String: Any] else { return nil }
                return ProviderAPIKey(
                    id: cleanString(item["id"] as? String) ?? UUID().uuidString,
                    name: cleanString(item["name"] as? String) ?? "",
                    key: item["key"] as? String ?? "",
                    enabled: item["isEnabled"] as? Bool ?? true
                )
            }

            providers.append(
                ProviderConfiguration(
                    id: providerID,
                    enabled: raw["enabled"] as? Bool ?? true,
                    name: cleanString(raw["name"] as? String) ?? key,
                    type: type,
                    apiKey: raw["apiKey"] as? String ?? "",
                    baseURL: raw["baseUrl"] as? String ?? type.defaultBaseURL,
                    chatPath: raw["chatPath"] as? String ?? "/chat/completions",
                    models: models,
                    brandIcon: ProviderBrandIcon.fromLegacyAvatar(
                        type: raw["avatarType"] as? String,
                        value: raw["avatarValue"] as? String
                    ),
                    useResponsesAPI: raw["useResponseApi"] as? Bool ?? false,
                    multiKeyEnabled: raw["multiKeyEnabled"] as? Bool ?? false,
                    apiKeys: legacyAPIKeys,
                    claudePromptCachingEnabled: raw["claudePromptCachingEnabled"] as? Bool ?? false,
                    claudePromptCachingTTL: (raw["claudePromptCachingTtl"] as? String) == "1h"
                        ? .oneHour
                        : .fiveMinutes,
                    balanceEnabled: raw["balanceEnabled"] as? Bool ?? false,
                    balanceAPIPath: raw["balanceApiPath"] as? String ?? "/credits",
                    balanceResultPath: raw["balanceResultPath"] as? String ?? "data.total_credits",
                    proxy: ProviderProxySettings(
                        enabled: raw["proxyEnabled"] as? Bool ?? false,
                        host: raw["proxyHost"] as? String ?? "",
                        port: raw["proxyPort"] as? String ?? "8080"
                    )
                )
            )
        }
        return ProviderDecodeResult(
            providers: providers,
            providerIDMap: providerIDMap,
            modelIDMap: modelIDMap,
            wasPresent: true
        )
    }

    private struct AssistantDecodeResult {
        var assistants: [AssistantProfile]
        var idMap: [String: UUID]
        var wasPresent: Bool
    }

    private static func decodeAssistants(
        from values: [String: Any],
        providerIDMap: [String: UUID],
        modelIDMap: [String: String],
        archiveEntries: [String: Data]
    ) -> AssistantDecodeResult {
        guard let rawAssistants = dictionaries(values, "assistants_v1") else {
            return AssistantDecodeResult(assistants: [], idMap: [:], wasPresent: false)
        }
        var idMap: [String: UUID] = [:]
        for raw in rawAssistants {
            guard let oldID = raw["id"] as? String, !oldID.isEmpty else { continue }
            idMap[oldID] = legacyStableUUID(namespace: "assistant", sourceID: oldID)
        }

        var memoriesByAssistant: [String: [AssistantMemory]] = [:]
        for raw in dictionaries(values, "assistant_memories_v1") ?? [] {
            guard let assistantID = raw["assistantId"] as? String else { continue }
            let rawMemoryID = String(describing: raw["id"] ?? UUID().uuidString)
            let content = String(describing: raw["content"] ?? "")
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            memoriesByAssistant[assistantID, default: []].append(
                AssistantMemory(
                    id: legacyStableUUID(namespace: "assistant-memory-\(assistantID)", sourceID: rawMemoryID),
                    content: content
                )
            )
        }

        let assistants = rawAssistants.compactMap { raw -> AssistantProfile? in
            guard let oldID = raw["id"] as? String, let nativeID = idMap[oldID] else { return nil }
            let providerKey = raw["chatModelProvider"] as? String
            let legacyModelID = raw["chatModelId"] as? String
            let chatModel: ModelSelection? = {
                guard let providerKey, let legacyModelID, let providerID = providerIDMap[providerKey] else { return nil }
                return ModelSelection(
                    providerID: providerID,
                    modelID: modelIDMap["\(providerKey)::\(legacyModelID)"] ?? legacyModelID
                )
            }()
            let avatar = importAssistantMedia(
                reference: raw["avatar"] as? String,
                assistantID: nativeID,
                isBackground: false,
                archiveEntries: archiveEntries
            )
            let background = importAssistantMedia(
                reference: raw["background"] as? String,
                assistantID: nativeID,
                isBackground: true,
                archiveEntries: archiveEntries
            )
            let presetMessages = (raw["presetMessages"] as? [Any] ?? []).compactMap { item -> PresetMessage? in
                guard let item = item as? [String: Any] else { return nil }
                let oldPresetID = item["id"] as? String ?? UUID().uuidString
                return PresetMessage(
                    id: legacyStableUUID(namespace: "preset-message-\(oldID)", sourceID: oldPresetID),
                    role: item["role"] as? String ?? "user",
                    content: item["content"] as? String ?? ""
                )
            }
            return AssistantProfile(
                id: nativeID,
                name: cleanString(raw["name"] as? String) ?? "助手",
                avatar: avatar,
                useAssistantAvatar: raw["useAssistantAvatar"] as? Bool ?? false,
                useAssistantName: raw["useAssistantName"] as? Bool ?? false,
                chatModel: chatModel,
                temperature: double(raw["temperature"]),
                topP: double(raw["topP"]),
                contextMessageSize: max(1, int(raw["contextMessageSize"]) ?? AssistantProfile.defaultContextMessageSize),
                limitContextMessages: raw["limitContextMessages"] as? Bool ?? true,
                streamOutput: raw["streamOutput"] as? Bool ?? true,
                thinkingBudget: int(raw["thinkingBudget"]),
                maxTokens: int(raw["maxTokens"]),
                systemPrompt: raw["systemPrompt"] as? String ?? "",
                extraPromptEnabled: raw["extraPromptEnabled"] as? Bool ?? false,
                extraPrompt: raw["extraPrompt"] as? String ?? "",
                messageTemplate: raw["messageTemplate"] as? String ?? AssistantProfile.defaultMessageTemplate,
                presetMessages: presetMessages,
                background: background,
                searchEnabled: raw["searchEnabled"] as? Bool ?? false,
                localToolIDs: Set((raw["localToolIds"] as? [String]) ?? []),
                mcpServerIDs: ((raw["mcpServerIds"] as? [String]) ?? []).compactMap(UUID.init(uuidString:)),
                enableMemory: raw["enableMemory"] as? Bool ?? false,
                enableRecentChatsReference: raw["enableRecentChatsReference"] as? Bool ?? false,
                recentChatsSummaryMessageCount: int(raw["recentChatsSummaryMessageCount"]) ?? 5,
                memories: memoriesByAssistant[oldID] ?? [],
                imageGenerationEnabled: raw["imageGenerationEnabled"] as? Bool ?? false,
                imageGenerationProviderID: cleanString(raw["imageGenerationProvider"] as? String)
                    .flatMap { providerIDMap[$0] },
                imageGenerationModelID: cleanString(raw["imageGenerationModelId"] as? String),
                migrationMetadata: MigrationMetadata(
                    source: "old_kelivo",
                    sourceID: oldID,
                    sourceSchemaVersion: 1,
                    importedAt: .now
                )
            )
        }
        return AssistantDecodeResult(assistants: assistants, idMap: idMap, wasPresent: true)
    }

    private struct ItemDecodeResult<Item> {
        var items: [Item]?
        var activeMap: [String: Set<UUID>]?
    }

    private static func decodeInstructions(
        from values: [String: Any],
        assistantIDMap: [String: UUID]
    ) -> ItemDecodeResult<InstructionInjection> {
        guard let rawItems = dictionaries(values, "instruction_injections_v1") else {
            return ItemDecodeResult(items: nil, activeMap: nil)
        }
        var itemIDMap: [String: UUID] = [:]
        let items = rawItems.compactMap { raw -> InstructionInjection? in
            guard let oldID = raw["id"] as? String else { return nil }
            let id = legacyStableUUID(namespace: "instruction", sourceID: oldID)
            itemIDMap[oldID] = id
            return InstructionInjection(
                id: id,
                title: raw["title"] as? String ?? "",
                prompt: raw["prompt"] as? String ?? "",
                group: raw["group"] as? String ?? ""
            )
        }
        let active = decodeActiveMap(
            dictionary(values, "instruction_injections_active_ids_by_assistant_v1"),
            assistantIDMap: assistantIDMap,
            itemIDMap: itemIDMap
        )
        return ItemDecodeResult(items: items, activeMap: active)
    }

    private static func decodeWorldBooks(
        from values: [String: Any],
        assistantIDMap: [String: UUID]
    ) -> ItemDecodeResult<WorldBook> {
        guard let rawBooks = dictionaries(values, "world_books_v1") else {
            return ItemDecodeResult(items: nil, activeMap: nil)
        }
        var bookIDMap: [String: UUID] = [:]
        let books = rawBooks.compactMap { raw -> WorldBook? in
            guard let oldID = raw["id"] as? String else { return nil }
            let id = legacyStableUUID(namespace: "world-book", sourceID: oldID)
            bookIDMap[oldID] = id
            let entries = (raw["entries"] as? [Any] ?? []).compactMap { value -> WorldBookEntry? in
                guard let entry = value as? [String: Any] else { return nil }
                let oldEntryID = entry["id"] as? String ?? UUID().uuidString
                return WorldBookEntry(
                    id: legacyStableUUID(namespace: "world-book-entry-\(oldID)", sourceID: oldEntryID),
                    name: entry["name"] as? String ?? "",
                    enabled: entry["enabled"] as? Bool ?? true,
                    priority: int(entry["priority"]) ?? 0,
                    position: WorldBookInjectionPosition(
                        rawValue: (entry["position"] as? String ?? "AFTER_SYSTEM_PROMPT").uppercased()
                    ) ?? .afterSystemPrompt,
                    content: entry["content"] as? String ?? "",
                    injectDepth: int(entry["injectDepth"]) ?? 4,
                    role: WorldBookInjectionRole(
                        rawValue: (entry["role"] as? String ?? "USER").uppercased()
                    ) ?? .user,
                    keywords: (entry["keywords"] as? [Any] ?? []).map { String(describing: $0) },
                    useRegex: entry["useRegex"] as? Bool ?? false,
                    caseSensitive: entry["caseSensitive"] as? Bool ?? false,
                    scanDepth: int(entry["scanDepth"]) ?? 4,
                    injectionRounds: int(entry["injectionRounds"]) ?? 0,
                    constantActive: entry["constantActive"] as? Bool ?? false
                )
            }
            return WorldBook(
                id: id,
                name: raw["name"] as? String ?? "",
                description: raw["description"] as? String ?? "",
                enabled: raw["enabled"] as? Bool ?? true,
                entries: entries
            )
        }
        let active = decodeActiveMap(
            dictionary(values, "world_books_active_ids_by_assistant_v1"),
            assistantIDMap: assistantIDMap,
            itemIDMap: bookIDMap
        )
        return ItemDecodeResult(items: books, activeMap: active)
    }

    private static func decodeQuickPhrases(
        from values: [String: Any],
        assistantIDMap: [String: UUID]
    ) -> [QuickPhrase]? {
        guard let rawPhrases = dictionaries(values, "quick_phrases_v1") else { return nil }
        return rawPhrases.compactMap { raw in
            guard let oldID = raw["id"] as? String else { return nil }
            let isGlobal = raw["isGlobal"] as? Bool ?? true
            let oldAssistantID = raw["assistantId"] as? String
            return QuickPhrase(
                id: legacyStableUUID(namespace: "quick-phrase", sourceID: oldID),
                title: raw["title"] as? String ?? "",
                content: raw["content"] as? String ?? "",
                isGlobal: isGlobal,
                assistantID: isGlobal ? nil : oldAssistantID.flatMap { assistantIDMap[$0]?.uuidString }
            )
        }
    }

    private static func decodeUserProfile(
        from values: [String: Any],
        archiveEntries: [String: Data]
    ) -> UserProfile? {
        let keys = [
            "user_name", "avatar_value", "user_profile_enabled_v1", "user_profile_traits_v1",
            "user_profile_ai_styles_v1", "user_profile_interests_v1", "user_profile_avoid_topics_v1",
            "user_profile_custom_notes_v1"
        ]
        guard keys.contains(where: { value(values, $0) != nil }) else { return nil }
        let avatarData: Data? = {
            guard let reference = string(values, "avatar_value"),
                  let imageData = mediaData(reference: reference, preferredPrefixes: ["avatars"], entries: archiveEntries),
                  let image = UIImage(data: imageData) else { return nil }
            return UserProfile.jpegData(from: image)
        }()
        var profile = UserProfile(
            nickname: string(values, "user_name") ?? UserProfile.defaultNickname,
            avatarJPEGData: avatarData,
            isEnabled: bool(values, "user_profile_enabled_v1") ?? false,
            noteTopics: UserProfile.legacyNoteTopics(
                interests: string(values, "user_profile_interests_v1") ?? "",
                avoidTopics: string(values, "user_profile_avoid_topics_v1") ?? "",
                additionalNotes: string(values, "user_profile_custom_notes_v1") ?? "",
                personalityTraits: stringArray(values, "user_profile_traits_v1"),
                preferredAIStyles: stringArray(values, "user_profile_ai_styles_v1")
            )
        )
        profile.normalize()
        return profile
    }

    private static func decodeAppearanceMode(from values: [String: Any]) -> AppearanceMode? {
        guard let raw = string(values, "theme_mode_v1")?.lowercased() else { return nil }
        return AppearanceMode(rawValue: raw) ?? .system
    }

    private static func decodeProxySettings(from values: [String: Any]) -> ProxySettings? {
        let keys = ["global_proxy_enabled_v1", "global_proxy_host_v1", "global_proxy_port_v1"]
        guard keys.contains(where: { value(values, $0) != nil }) else { return nil }
        return ProxySettings(
            enabled: bool(values, "global_proxy_enabled_v1") ?? false,
            host: string(values, "global_proxy_host_v1") ?? "",
            port: string(values, "global_proxy_port_v1") ?? ""
        )
    }

    private static func decodePreferences(
        from values: [String: Any],
        providerResult: ProviderDecodeResult
    ) -> UserPreferences? {
        let supportedKeys = [
            "theme_palette_v1", "custom_theme_color_v1", "display_use_pure_background_v1",
            "display_show_token_stats_v1", "display_auto_scroll_enabled_v1", "display_auto_scroll_idle_seconds_v1",
            "display_chat_font_scale_v1", "display_chat_background_mask_strength_v1",
            "display_app_font_local_path_v1", "display_app_font_local_alias_v1",
            "display_chat_input_background_opacity_light_v1", "display_chat_input_background_opacity_dark_v1",
            "display_chat_input_placeholder_v1", "display_user_image_compression_quality_v1",
            "display_show_user_avatar_v1", "display_show_user_name_v1", "display_show_user_timestamp_v1",
            "display_show_user_message_actions_v1", "ai_message_reactions_enabled_v1",
            "display_show_model_icon_v1", "display_show_model_name_v1", "display_show_model_timestamp_v1",
            "display_show_provider_in_chat_message_v1", "display_enable_user_markdown_v1",
            "display_enable_reasoning_markdown_v1", "display_enable_assistant_markdown_v1",
            "display_html_runner_enabled_v1",
            "display_html_runner_allow_current_chat_v1",
            "display_auto_collapse_code_block_v1", "display_auto_collapse_code_block_lines_v1",
            "display_code_block_appearance_v1",
            "display_auto_collapse_thinking_v1", "display_regenerate_delete_trailing_messages_v1",
            "display_show_regenerate_confirm_dialog_v1", "display_new_chat_on_launch_v1",
            "display_new_chat_on_assistant_switch_v1", "display_new_chat_after_delete_v1",
            "display_enter_to_send_on_mobile_v1", "display_mobile_message_nav_buttons_mode_v1",
            "display_show_chat_list_date_v1", "display_keep_sidebar_open_on_assistant_tap_v1",
            "display_keep_sidebar_open_on_topic_tap_v1", "display_haptics_global_enabled_v1",
            "display_haptics_ios_switch_v1", "display_haptics_on_drawer_v1",
            "display_haptics_on_list_item_tap_v1", "display_haptics_on_card_tap_v1",
            "display_haptics_on_generate_v1", "display_user_chat_bubble_style_v1",
            "display_assistant_chat_bubble_style_v1", "display_thinking_chat_bubble_style_v1",
            "display_user_chat_bubble_color_v1", "display_assistant_chat_bubble_color_v1",
            "display_thinking_chat_bubble_color_v1", "display_user_chat_text_color_v1",
            "display_assistant_chat_text_color_v1", "display_thinking_chat_text_color_v1",
            "display_user_chat_bubble_opacity_v1", "display_assistant_chat_bubble_opacity_v1",
            "display_thinking_chat_bubble_opacity_v1", "display_liquid_glass_bubble_opacity_v1",
            "display_apple_glass_bubble_opacity_v1", "display_thinking_bubble_title_v1",
            "title_model_v1", "summary_model_v1", "suggestion_model_v1", "compress_model_v1",
            "translate_model_v1",
            "group_chat_segmented_reply_v1", "group_chat_segment_regex_v1",
            "group_chat_force_assistant_bubble_v1", "group_chat_bubble_opacity_v1",
            "group_chat_bubble_style_v1", "ocr_enabled_v1", "ocr_model_v1", "ocr_prompt_v1",
            "tts_services_v1", "tts_selected_v1", "tts_auto_play_assistant_replies_v1",
            "tts_text_selection_mode_v1", "tts_speech_rate_v1", "tts_pitch_v1",
            "tts_language_v1"
        ]
        guard supportedKeys.contains(where: { value(values, $0) != nil }) else { return nil }
        var preferences = UserPreferences()
        if let raw = string(values, "theme_palette_v1"), let palette = ThemePaletteID(rawValue: raw) { preferences.themePaletteID = palette }
        if let v = int(values["custom_theme_color_v1"]) { preferences.customThemeColorARGB = v }
        assignBool(values, "display_use_pure_background_v1", to: &preferences.usePureBackground)
        assignBool(values, "display_show_token_stats_v1", to: &preferences.showTokenUsage)
        assignBool(values, "display_auto_scroll_enabled_v1", to: &preferences.autoScrollEnabled)
        if let v = int(values["display_auto_scroll_idle_seconds_v1"]) { preferences.autoScrollIdleSeconds = min(max(v, 2), 64) }
        if let v = double(values["display_chat_font_scale_v1"]) { preferences.chatFontScale = min(max(v, 0.5), 1.5) }
        if let v = double(values["display_chat_background_mask_strength_v1"]) { preferences.chatBackgroundMaskStrength = min(max(v, 0), 2) }
        if let v = double(values["display_chat_input_background_opacity_light_v1"]) { preferences.chatInputBackgroundOpacityLight = min(max(v, 0), 1) }
        if let v = double(values["display_chat_input_background_opacity_dark_v1"]) { preferences.chatInputBackgroundOpacityDark = min(max(v, 0), 1) }
        if let v = string(values, "display_chat_input_placeholder_v1") { preferences.chatInputPlaceholder = v }
        if let v = int(values["display_user_image_compression_quality_v1"]) { preferences.userImageCompressionQuality = min(max(v, 1), 100) }
        assignBool(values, "display_show_user_avatar_v1", to: &preferences.showUserAvatar)
        assignBool(values, "display_show_user_name_v1", to: &preferences.showUserName)
        assignBool(values, "display_show_user_timestamp_v1", to: &preferences.showUserTimestamp)
        assignBool(values, "display_show_user_message_actions_v1", to: &preferences.showUserMessageActions)
        assignBool(values, "ai_message_reactions_enabled_v1", to: &preferences.aiMessageReactionsEnabled)
        assignBool(values, "display_show_model_icon_v1", to: &preferences.showModelIcon)
        assignBool(values, "display_show_model_name_v1", to: &preferences.showModelName)
        assignBool(values, "display_show_model_timestamp_v1", to: &preferences.showModelTimestamp)
        assignBool(values, "display_show_provider_in_chat_message_v1", to: &preferences.showProviderInChatMessage)
        assignBool(values, "display_enable_user_markdown_v1", to: &preferences.enableUserMarkdown)
        assignBool(values, "display_enable_reasoning_markdown_v1", to: &preferences.enableReasoningMarkdown)
        assignBool(values, "display_enable_assistant_markdown_v1", to: &preferences.enableAssistantMarkdown)
        assignBool(values, "display_html_runner_enabled_v1", to: &preferences.htmlRunnerEnabled)
        assignBool(values, "display_html_runner_allow_current_chat_v1", to: &preferences.htmlRunnerAllowCurrentChat)
        assignBool(values, "display_auto_collapse_code_block_v1", to: &preferences.autoCollapseCodeBlock)
        if let v = int(values["display_auto_collapse_code_block_lines_v1"]) { preferences.autoCollapseCodeBlockLines = max(1, v) }
        if let raw = string(values, "display_code_block_appearance_v1"), let appearance = CodeBlockAppearance(rawValue: raw) { preferences.codeBlockAppearance = appearance }
        assignBool(values, "display_auto_collapse_thinking_v1", to: &preferences.autoCollapseThinking)
        assignBool(values, "display_regenerate_delete_trailing_messages_v1", to: &preferences.regenerateDeleteTrailingMessages)
        assignBool(values, "display_show_regenerate_confirm_dialog_v1", to: &preferences.showRegenerateConfirmDialog)
        assignBool(values, "display_new_chat_on_launch_v1", to: &preferences.newChatOnLaunch)
        assignBool(values, "display_new_chat_on_assistant_switch_v1", to: &preferences.newChatOnAssistantSwitch)
        assignBool(values, "display_new_chat_after_delete_v1", to: &preferences.newChatAfterDelete)
        assignBool(values, "display_enter_to_send_on_mobile_v1", to: &preferences.enterToSendOnMobile)
        if let raw = string(values, "display_mobile_message_nav_buttons_mode_v1"), let mode = MobileMessageNavButtonsMode(rawValue: raw) { preferences.mobileMessageNavButtonsMode = mode }
        assignBool(values, "display_show_chat_list_date_v1", to: &preferences.showChatListDate)
        assignBool(values, "display_keep_sidebar_open_on_assistant_tap_v1", to: &preferences.keepSidebarOpenOnAssistantTap)
        assignBool(values, "display_keep_sidebar_open_on_topic_tap_v1", to: &preferences.keepSidebarOpenOnTopicTap)
        assignBool(values, "display_haptics_global_enabled_v1", to: &preferences.hapticsGlobalEnabled)
        assignBool(values, "display_haptics_ios_switch_v1", to: &preferences.hapticsIosSwitch)
        assignBool(values, "display_haptics_on_drawer_v1", to: &preferences.hapticsOnDrawer)
        assignBool(values, "display_haptics_on_list_item_tap_v1", to: &preferences.hapticsOnListItemTap)
        assignBool(values, "display_haptics_on_card_tap_v1", to: &preferences.hapticsOnCardTap)
        assignBool(values, "display_haptics_on_generate_v1", to: &preferences.hapticsOnGenerate)
        assignStyle(values, "display_user_chat_bubble_style_v1", to: &preferences.userChatBubbleStyle)
        assignStyle(values, "display_assistant_chat_bubble_style_v1", to: &preferences.assistantChatBubbleStyle)
        assignStyle(values, "display_thinking_chat_bubble_style_v1", to: &preferences.thinkingChatBubbleStyle)
        if let v = int(values["display_user_chat_bubble_color_v1"]) { preferences.userChatBubbleColorARGB = v }
        if let v = int(values["display_assistant_chat_bubble_color_v1"]) { preferences.assistantChatBubbleColorARGB = v }
        if let v = int(values["display_thinking_chat_bubble_color_v1"]) { preferences.thinkingChatBubbleColorARGB = v }
        if let v = int(values["display_user_chat_text_color_v1"]) { preferences.userChatTextColorARGB = v }
        if let v = int(values["display_assistant_chat_text_color_v1"]) { preferences.assistantChatTextColorARGB = v }
        if let v = int(values["display_thinking_chat_text_color_v1"]) { preferences.thinkingChatTextColorARGB = v }
        if let v = double(values["display_user_chat_bubble_opacity_v1"]) { preferences.userChatBubbleOpacity = min(max(v, 0), 1) }
        if let v = double(values["display_assistant_chat_bubble_opacity_v1"]) { preferences.assistantChatBubbleOpacity = min(max(v, 0), 1) }
        if let v = double(values["display_thinking_chat_bubble_opacity_v1"]) { preferences.thinkingChatBubbleOpacity = min(max(v, 0), 1) }
        if let v = double(values["display_liquid_glass_bubble_opacity_v1"]) { preferences.liquidGlassBubbleOpacity = min(max(v, 0), 1) }
        if let v = double(values["display_apple_glass_bubble_opacity_v1"]) { preferences.appleGlassBubbleOpacity = min(max(v, 0), 1) }
        if let v = string(values, "display_thinking_bubble_title_v1") { preferences.thinkingBubbleTitle = v }
        preferences.titleModelSelection = decodeModelSelection(
            string(values, "title_model_v1"),
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
        preferences.summaryModelSelection = decodeModelSelection(
            string(values, "summary_model_v1"),
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
        preferences.suggestionModelSelection = decodeModelSelection(
            string(values, "suggestion_model_v1"),
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
        preferences.compressionModelSelection = decodeModelSelection(
            string(values, "compress_model_v1"),
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
        preferences.translationModelSelection = decodeModelSelection(
            string(values, "translate_model_v1"),
            providerIDMap: providerResult.providerIDMap,
            modelIDMap: providerResult.modelIDMap
        )
        assignBool(values, "group_chat_segmented_reply_v1", to: &preferences.chatSegmentedReply)
        assignBool(values, "group_chat_force_assistant_bubble_v1", to: &preferences.groupChatForceAssistantBubble)
        if let v = double(values["group_chat_bubble_opacity_v1"]) { preferences.groupChatBubbleOpacity = min(max(v, 0), 1) }
        assignStyle(values, "group_chat_bubble_style_v1", to: &preferences.groupChatBubbleStyle)
        if let ocr = decodeModelSelection(string(values, "ocr_model_v1"), providerIDMap: providerResult.providerIDMap, modelIDMap: providerResult.modelIDMap) {
            preferences.ocrProviderID = ocr.providerID.uuidString
            preferences.ocrModelID = ocr.modelID
            preferences.ocrEnabled = bool(values, "ocr_enabled_v1") ?? false
        }
        if let v = string(values, "ocr_prompt_v1") { preferences.ocrPrompt = v }
        if let services = dictionaries(values, "tts_services_v1") {
            preferences.voiceServices = services.compactMap(
                VoiceServiceConfiguration.fromLegacyDictionary
            )
            if let selectedIndex = int(values["tts_selected_v1"]),
               preferences.voiceServices.indices.contains(selectedIndex) {
                preferences.selectedVoiceServiceID = preferences.voiceServices[selectedIndex].id
            } else {
                preferences.selectedVoiceServiceID = nil
            }
        }
        assignBool(
            values,
            "tts_auto_play_assistant_replies_v1",
            to: &preferences.ttsAutoPlayAssistantReplies
        )
        if let raw = string(values, "tts_text_selection_mode_v1"),
           let mode = VoiceTextSelectionMode(rawValue: raw) {
            preferences.ttsTextSelectionMode = mode
        }
        if let rate = double(values["tts_speech_rate_v1"]) {
            preferences.ttsSpeechRate = min(max(rate, 0.1), 1.0)
        }
        if let pitch = double(values["tts_pitch_v1"]) {
            preferences.ttsPitch = min(max(pitch, 0.5), 2.0)
        }
        if let language = cleanString(string(values, "tts_language_v1")) {
            preferences.ttsLanguage = language
        }
        return preferences
    }

    private static func decodeModelSelection(
        _ raw: String?,
        providerIDMap: [String: UUID],
        modelIDMap: [String: String]
    ) -> ModelSelection? {
        guard let raw, let separator = raw.range(of: "::") else { return nil }
        let providerKey = String(raw[..<separator.lowerBound])
        let legacyModelID = String(raw[separator.upperBound...])
        guard let providerID = providerIDMap[providerKey], !legacyModelID.isEmpty else { return nil }
        return ModelSelection(
            providerID: providerID,
            modelID: modelIDMap["\(providerKey)::\(legacyModelID)"] ?? legacyModelID
        )
    }

    private static func decodeActiveMap(
        _ raw: [String: Any]?,
        assistantIDMap: [String: UUID],
        itemIDMap: [String: UUID]
    ) -> [String: Set<UUID>]? {
        guard let raw else { return nil }
        var result: [String: Set<UUID>] = [:]
        for (legacyAssistantKey, value) in raw {
            let assistantKey: String
            if legacyAssistantKey == "__global__" {
                assistantKey = legacyAssistantKey
            } else if let mapped = assistantIDMap[legacyAssistantKey] {
                assistantKey = mapped.uuidString
            } else {
                continue
            }
            let ids = (value as? [Any] ?? []).compactMap { itemIDMap[String(describing: $0)] }
            result[assistantKey] = Set(ids)
        }
        return result
    }

    private static func importAssistantMedia(
        reference: String?,
        assistantID: UUID,
        isBackground: Bool,
        archiveEntries: [String: Data]
    ) -> String? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else {
            return nil
        }
        if !isBackground,
           !reference.contains("/"),
           !reference.contains("\\"),
           !reference.lowercased().hasPrefix("http"),
           !reference.lowercased().hasPrefix("data:") {
            return reference
        }
        let prefixes = isBackground ? ["images", "upload", "avatars"] : ["avatars", "images"]
        guard let data = mediaData(reference: reference, preferredPrefixes: prefixes, entries: archiveEntries),
              let image = UIImage(data: data) else { return nil }
        return isBackground
            ? AssistantMediaStore.saveBackground(image, assistantID: assistantID)
            : AssistantMediaStore.saveAvatar(image, assistantID: assistantID)
    }

    private static func mediaData(
        reference: String,
        preferredPrefixes: [String],
        entries: [String: Data]
    ) -> Data? {
        if reference.lowercased().hasPrefix("data:image"),
           let comma = reference.firstIndex(of: ",") {
            return Data(base64Encoded: String(reference[reference.index(after: comma)...]))
        }
        let normalized = reference.replacingOccurrences(of: "\\", with: "/")
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent
        guard !fileName.isEmpty else { return nil }
        for prefix in preferredPrefixes {
            if let exact = entries["\(prefix)/\(fileName)"] { return exact }
            if let match = entries.first(where: {
                $0.key.hasPrefix("\(prefix)/") && URL(fileURLWithPath: $0.key).lastPathComponent == fileName
            })?.value { return match }
        }
        return nil
    }

    private static func value(_ values: [String: Any], _ key: String) -> Any? {
        guard let raw = values[key] else { return nil }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            return decoded
        }
        return raw
    }

    private static func dictionaries(_ values: [String: Any], _ key: String) -> [[String: Any]]? {
        guard let raw = value(values, key) else { return nil }
        return (raw as? [Any])?.compactMap { $0 as? [String: Any] }
    }

    private static func dictionary(_ values: [String: Any], _ key: String) -> [String: Any]? {
        value(values, key) as? [String: Any]
    }

    private static func string(_ values: [String: Any], _ key: String) -> String? {
        guard let raw = values[key] else { return nil }
        return raw as? String ?? String(describing: raw)
    }

    private static func stringArray(_ values: [String: Any], _ key: String) -> [String] {
        guard let raw = value(values, key) as? [Any] else { return [] }
        return raw.map { String(describing: $0) }
    }

    private static func bool(_ values: [String: Any], _ key: String) -> Bool? {
        guard let raw = values[key] else { return nil }
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return Bool(String(describing: raw))
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber { return number.intValue }
        return value.flatMap { Int(String(describing: $0)) }
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let number = value as? NSNumber { return number.doubleValue }
        return value.flatMap { Double(String(describing: $0)) }
    }

    private static func assignBool(_ values: [String: Any], _ key: String, to target: inout Bool) {
        if let value = bool(values, key) { target = value }
    }

    private static func assignStyle(_ values: [String: Any], _ key: String, to target: inout ChatBubbleStyle) {
        guard let raw = string(values, key), let style = ChatBubbleStyle(rawValue: raw) else { return }
        target = style
    }

    private static func cleanString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private func legacyStableUUID(namespace: String, sourceID: String) -> UUID {
    let digest = SHA256.hash(data: Data("kelivo2:\(namespace):\(sourceID)".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    return UUID(uuidString: value)!
}

private struct LegacyResolvedUserContent {
    var text: String
    var attachments: [MessageAttachment]
}

private struct LegacyImageInspection {
    var markers = 0
    var restorable = 0
    var missingExamples: [String] = []

    var missing: Int {
        max(0, markers - restorable)
    }
}

/// Old Kelivo persisted user images as `[image:/old/sandbox/path]` inside the
/// message text. The matching bytes live separately in the backup's upload/
/// or images/ directory, so only exact archive matches are eligible here.
private struct LegacyImageArchiveResolver {
    private let imageEntries: [String: Data]

    private static let markerExpression = try! NSRegularExpression(
        pattern: #"\[image:([^\]\r\n]+)\]"#
    )

    init(entries: [String: Data]) {
        imageEntries = entries.filter { path, _ in
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            guard normalized.hasPrefix("upload/") || normalized.hasPrefix("images/") else {
                return false
            }
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            return !components.isEmpty && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
            }
        }
    }

    func inspect(messages: [LegacyMessage]) -> LegacyImageInspection {
        var inspection = LegacyImageInspection()
        for message in messages where message.role == ChatMessage.Role.user.rawValue {
            let content = message.content
            let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
            let matches = Self.markerExpression.matches(in: content, range: fullRange)
            for match in matches {
                guard let pathRange = Range(match.range(at: 1), in: content) else {
                    continue
                }
                inspection.markers += 1
                let rawPath = String(content[pathRange])
                if let archivePath = matchingArchivePath(for: rawPath),
                   let data = imageEntries[archivePath],
                   Self.isValidImage(data) {
                    inspection.restorable += 1
                } else if inspection.missingExamples.count < 3 {
                    let name = (rawPath as NSString).lastPathComponent
                    let example = name.isEmpty ? rawPath : name
                    if !inspection.missingExamples.contains(example) {
                        inspection.missingExamples.append(example)
                    }
                }
            }
        }
        return inspection
    }

    func resolveUserContent(_ content: String, legacyMessageID: String) -> LegacyResolvedUserContent {
        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = Self.markerExpression.matches(in: content, range: fullRange)
        guard !matches.isEmpty else {
            return LegacyResolvedUserContent(text: content, attachments: [])
        }

        var output = ""
        var cursor = content.startIndex
        var attachments: [MessageAttachment] = []

        for (ordinal, match) in matches.enumerated() {
            guard let markerRange = Range(match.range(at: 0), in: content),
                  let pathRange = Range(match.range(at: 1), in: content) else {
                continue
            }

            output.append(contentsOf: content[cursor..<markerRange.lowerBound])
            let rawPath = String(content[pathRange])
            if let archivePath = matchingArchivePath(for: rawPath),
               let data = imageEntries[archivePath],
               let attachment = importedAttachment(
                    data: data,
                    archivePath: archivePath,
                    legacyMessageID: legacyMessageID,
                    ordinal: ordinal
               ) {
                attachments.append(attachment)
            } else {
                output.append(contentsOf: content[markerRange])
            }
            cursor = markerRange.upperBound
        }

        output.append(contentsOf: content[cursor...])
        guard !attachments.isEmpty else {
            return LegacyResolvedUserContent(text: content, attachments: [])
        }
        return LegacyResolvedUserContent(
            text: output.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments
        )
    }

    private func matchingArchivePath(for rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.caseInsensitiveCompare("generated") != .orderedSame else {
            return nil
        }

        let lowercased = path.lowercased()
        guard !lowercased.hasPrefix("http://"),
              !lowercased.hasPrefix("https://"),
              !lowercased.hasPrefix("data:"),
              !lowercased.hasPrefix("blob:") else {
            return nil
        }

        if lowercased.hasPrefix("file://") {
            path.removeFirst("file://".count)
        }
        path = (path.removingPercentEncoding ?? path)
            .replacingOccurrences(of: "\\", with: "/")

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
        }) else {
            return nil
        }

        for index in components.indices {
            guard components[index] == "upload" || components[index] == "images" else { continue }
            let candidate = components[index...].joined(separator: "/")
            if imageEntries[candidate] != nil {
                return candidate
            }
        }
        return nil
    }

    private func importedAttachment(
        data: Data,
        archivePath: String,
        legacyMessageID: String,
        ordinal: Int
    ) -> MessageAttachment? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let storageID = legacyStableUUID(
            namespace: "image-file",
            sourceID: "\(archivePath)|\(digest)"
        )
        let attachmentID = legacyStableUUID(
            namespace: "message-image",
            sourceID: "\(legacyMessageID)|\(ordinal)|\(archivePath)"
        )
        return AttachmentStore.importLegacyImage(
            data: data,
            originalFileName: (archivePath as NSString).lastPathComponent,
            storageID: storageID,
            attachmentID: attachmentID,
            archivePath: archivePath
        )
    }

    private static func isValidImage(_ data: Data) -> Bool {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8,
        ] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options) != nil
    }
}

private struct LegacyKelivoBackup {
    var conversations: [LegacyConversation]
    var messages: [LegacyMessage]

    static func decodeChats(from data: Data) throws -> LegacyKelivoBackup {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw BackupServiceError.invalidBackup("旧版备份的 chats.json 不是对象")
        }
        let conversations = (root["conversations"] as? [[String: Any]] ?? []).compactMap(LegacyConversation.init(json:))
        let messages = (root["messages"] as? [[String: Any]] ?? []).compactMap(LegacyMessage.init(json:))
        return LegacyKelivoBackup(conversations: conversations, messages: messages)
    }

    func convertToNativeSnapshot(
        assistantIDMap: [String: UUID],
        providerIDMap: [String: UUID],
        modelIDMap: [String: String],
        imageResolver: LegacyImageArchiveResolver
    ) -> ConversationSnapshot {
        // Deleted/missing legacy profiles still have an identity. Retain it
        // without recreating a profile or turning their chats into ownerless
        // records. The same mapping is used for conversations and authors.
        func resolveAssistantID(_ sourceID: String) -> String {
            (assistantIDMap[sourceID]
                ?? legacyStableUUID(namespace: "assistant", sourceID: sourceID)).uuidString
        }
        var idMap: [String: UUID] = [:]
        for conversation in conversations {
            idMap[conversation.id] = UUID(uuidString: conversation.id)
                ?? legacyStableUUID(namespace: "conversation", sourceID: conversation.id)
        }

        let nativeConversations = conversations.map { conversation in
            let nativeID = idMap[conversation.id] ?? UUID()
            let mappedAssistantID = conversation.assistantID.map(resolveAssistantID)
            let mappedGroupAssistantIDs = conversation.groupAssistantIDs.map(resolveAssistantID)
            return Conversation(
                id: nativeID,
                title: conversation.title.isEmpty ? Conversation.defaultTitle : conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                isPinned: conversation.isPinned,
                assistantID: mappedAssistantID,
                groupAssistantIDs: mappedGroupAssistantIDs,
                truncateIndex: conversation.truncateIndex,
                versionSelections: conversation.versionSelections,
                summary: conversation.summary,
                lastSummarizedMessageCount: conversation.lastSummarizedMessageCount,
                // Legacy Kelivo stored manual-compression cursors in the raw
                // message-count domain. AppModel performs a one-time,
                // projection-aware migration after import.
                summaryCursorDomainVersion: nil,
                chatSuggestions: conversation.chatSuggestions,
                migrationMetadata: MigrationMetadata(
                    source: "old_kelivo",
                    sourceID: conversation.id,
                    sourceSchemaVersion: 1,
                    importedAt: .now,
                    notes: [
                        "oldAssistantID": conversation.assistantID ?? "",
                        "oldGroupAssistantIDs": conversation.groupAssistantIDs.joined(separator: ",")
                    ].filter { !$0.value.isEmpty }
                )
            )
        }

        var byConversation: [UUID: [ChatMessage]] = [:]
        for message in messages {
            guard let conversationID = idMap[message.conversationID] else { continue }
            let nativeID = UUID(uuidString: message.id)
                ?? legacyStableUUID(namespace: "message", sourceID: message.id)
            var reasoningSegments: [ReasoningSegment] = []
            if let reasoning = message.reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reasoning.isEmpty {
                reasoningSegments.append(
                    ReasoningSegment(
                        text: reasoning,
                        startedAt: message.reasoningStartAt,
                        finishedAt: message.reasoningFinishedAt,
                        metadata: ["source": "old_kelivo_reasoningText"]
                    )
                )
            }
            let role = ChatMessage.Role(rawValue: message.role) ?? .assistant
            let mappedProviderID = message.providerID.flatMap { providerIDMap[$0]?.uuidString }
            let mappedModelID: String? = {
                guard let modelID = message.modelID else { return nil }
                guard let providerID = message.providerID else { return modelID }
                return modelIDMap["\(providerID)::\(modelID)"] ?? modelID
            }()
            let mappedMessageAssistantID = message.assistantID.map(resolveAssistantID)
            let resolvedUserContent: LegacyResolvedUserContent = {
                guard role == .user else {
                    return LegacyResolvedUserContent(text: message.content, attachments: [])
                }
                return imageResolver.resolveUserContent(
                    message.content,
                    legacyMessageID: message.id
                )
            }()
            let native = ChatMessage(
                id: nativeID,
                conversationID: conversationID,
                role: role,
                text: resolvedUserContent.text,
                createdAt: message.timestamp,
                updatedAt: message.timestamp,
                status: message.isStreaming ? .interrupted : .complete,
                reasoningSegments: reasoningSegments,
                attachments: resolvedUserContent.attachments,
                tokenUsage: TokenUsage(
                    promptTokens: message.promptTokens,
                    completionTokens: message.completionTokens,
                    cachedTokens: message.cachedTokens,
                    totalTokens: message.totalTokens,
                    durationMilliseconds: message.durationMilliseconds
                ),
                modelID: mappedModelID,
                providerID: mappedProviderID,
                groupID: mappedMessageAssistantID ?? nativeID.uuidString,
                versionGroupID: message.groupID,
                version: message.version,
                translation: message.translation,
                reactions: MessageReactions(
                    assistantReaction: message.assistantReaction,
                    userReaction: message.userReaction,
                    assistantReactionAuthorID: message.assistantReactionAuthorID.map(resolveAssistantID),
                    bookmarkedAt: message.bookmarkedAt
                ),
                migrationMetadata: MigrationMetadata(
                    source: "old_kelivo",
                    sourceID: message.id,
                    sourceSchemaVersion: 1,
                    importedAt: .now
                )
            )
            byConversation[conversationID, default: []].append(native)
        }

        for conversationID in byConversation.keys {
            byConversation[conversationID]?.sort { $0.createdAt < $1.createdAt }
        }

        // Old Kelivo stores the selected entry as an index into the group's
        // version-sorted array. Native persistence stores the actual version
        // number so selection survives gaps after an older version is deleted.
        let normalizedConversations = nativeConversations.map { conversation in
            var normalized = conversation
            let messages = byConversation[conversation.id] ?? []
            var convertedSelections: [String: Int] = [:]
            for (groupKey, selectedIndex) in conversation.versionSelections {
                let variants = messages
                    .filter { $0.versionGroupKey == groupKey }
                    .sorted { lhs, rhs in
                        if lhs.version != rhs.version { return lhs.version < rhs.version }
                        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                guard !variants.isEmpty else { continue }
                let resolvedIndex = variants.indices.contains(selectedIndex)
                    ? selectedIndex
                    : variants.count - 1
                convertedSelections[groupKey] = variants[resolvedIndex].version
            }
            normalized.versionSelections = convertedSelections
            return normalized
        }

        return ConversationSnapshot(
            conversations: normalizedConversations,
            messagesByConversation: byConversation
        )
    }
}

private struct LegacyConversation {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var assistantID: String?
    var groupAssistantIDs: [String]
    var truncateIndex: Int
    var versionSelections: [String: Int]
    var summary: String?
    var lastSummarizedMessageCount: Int
    var chatSuggestions: [String]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        title = json["title"] as? String ?? Conversation.defaultTitle
        createdAt = Self.date(json["createdAt"]) ?? .now
        updatedAt = Self.date(json["updatedAt"]) ?? createdAt
        isPinned = json["isPinned"] as? Bool ?? false
        assistantID = json["assistantId"] as? String
        groupAssistantIDs = json["groupAssistantIds"] as? [String] ?? []
        truncateIndex = json["truncateIndex"] as? Int ?? -1
        versionSelections = (json["versionSelections"] as? [String: Any] ?? [:]).mapValues {
            ($0 as? NSNumber)?.intValue ?? 0
        }
        summary = json["summary"] as? String
        lastSummarizedMessageCount = json["lastSummarizedMessageCount"] as? Int ?? 0
        chatSuggestions = json["chatSuggestions"] as? [String] ?? []
    }

    private static func date(_ value: Any?) -> Date? {
        legacyDate(value)
    }
}

private struct LegacyMessage {
    var id: String
    var role: String
    var content: String
    var timestamp: Date
    var conversationID: String
    var isStreaming: Bool
    var modelID: String?
    var providerID: String?
    var totalTokens: Int?
    var reasoningText: String?
    var reasoningStartAt: Date?
    var reasoningFinishedAt: Date?
    var translation: String?
    var groupID: String?
    var version: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
    var durationMilliseconds: Int?
    var assistantReaction: String?
    var userReaction: String?
    var assistantID: String?
    var assistantReactionAuthorID: String?
    var bookmarkedAt: Date?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let role = json["role"] as? String,
              let conversationID = json["conversationId"] as? String else {
            return nil
        }
        self.id = id
        self.role = role
        content = json["content"] as? String ?? ""
        timestamp = Self.date(json["timestamp"]) ?? .now
        self.conversationID = conversationID
        isStreaming = json["isStreaming"] as? Bool ?? false
        modelID = json["modelId"] as? String
        providerID = json["providerId"] as? String
        totalTokens = Self.int(json["totalTokens"])
        reasoningText = json["reasoningText"] as? String
        reasoningStartAt = Self.date(json["reasoningStartAt"])
        reasoningFinishedAt = Self.date(json["reasoningFinishedAt"])
        translation = json["translation"] as? String
        groupID = json["groupId"] as? String
        version = Self.int(json["version"]) ?? 0
        promptTokens = Self.int(json["promptTokens"])
        completionTokens = Self.int(json["completionTokens"])
        cachedTokens = Self.int(json["cachedTokens"])
        durationMilliseconds = Self.int(json["durationMs"])
        assistantReaction = json["aiReaction"] as? String
        userReaction = json["userReaction"] as? String
        assistantID = json["assistantId"] as? String
        assistantReactionAuthorID = json["aiReactionAssistantId"] as? String
        bookmarkedAt = Self.date(json["bookmarkedAt"])
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? value as? Int
    }

    private static func date(_ value: Any?) -> Date? {
        legacyDate(value)
    }
}

private func legacyDate(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }
    guard let string = value as? String else { return nil }
    if let raw = Double(string) {
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }
    return LegacyDateParser.shared.date(from: string)
}

private final class LegacyDateParser: @unchecked Sendable {
    static let shared = LegacyDateParser()

    private let lock = NSLock()
    private let fractionalISO8601: ISO8601DateFormatter
    private let ISO8601: ISO8601DateFormatter
    private let localFormatters: [DateFormatter]

    private init() {
        let fractionalISO8601 = ISO8601DateFormatter()
        fractionalISO8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalISO8601 = fractionalISO8601

        ISO8601 = ISO8601DateFormatter()

        localFormatters = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss"
        ].map { format in
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            return formatter
        }
    }

    func date(from rawString: String) -> Date? {
        let string = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let date = fractionalISO8601.date(from: string) ?? ISO8601.date(from: string) {
            return date
        }
        for formatter in localFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}

private struct ZipArchiveWriter {
    private struct Entry {
        var path: String
        var crc32: UInt32
        var size: UInt32
        var offset: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private var data = Data()
    private var entries: [Entry] = []

    mutating func addFile(path: String, data fileData: Data, modifiedAt: Date = Date()) {
        let normalizedPath = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return }
        precondition(fileData.count <= Int(UInt32.max), "ZIP64 is not supported")
        precondition(data.count <= Int(UInt32.max), "ZIP64 is not supported")

        let pathData = Data(normalizedPath.utf8)
        let crc = CRC32.checksum(fileData)
        let offset = UInt32(data.count)
        let (dosDate, dosTime) = Self.dosDateTime(from: modifiedAt)
        let size = UInt32(fileData.count)

        data.appendUInt32(0x04034b50)
        data.appendUInt16(20)
        data.appendUInt16(0x0800)
        data.appendUInt16(0)
        data.appendUInt16(dosTime)
        data.appendUInt16(dosDate)
        data.appendUInt32(crc)
        data.appendUInt32(size)
        data.appendUInt32(size)
        data.appendUInt16(UInt16(pathData.count))
        data.appendUInt16(0)
        data.append(pathData)
        data.append(fileData)

        entries.append(
            Entry(
                path: normalizedPath,
                crc32: crc,
                size: size,
                offset: offset,
                dosTime: dosTime,
                dosDate: dosDate
            )
        )
    }

    mutating func finalize() throws -> Data {
        guard data.count <= Int(UInt32.max) else {
            throw BackupServiceError.fileTooLarge("central directory offset")
        }
        let centralDirectoryOffset = UInt32(data.count)

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            data.appendUInt32(0x02014b50)
            data.appendUInt16(20)
            data.appendUInt16(20)
            data.appendUInt16(0x0800)
            data.appendUInt16(0)
            data.appendUInt16(entry.dosTime)
            data.appendUInt16(entry.dosDate)
            data.appendUInt32(entry.crc32)
            data.appendUInt32(entry.size)
            data.appendUInt32(entry.size)
            data.appendUInt16(UInt16(pathData.count))
            data.appendUInt16(0)
            data.appendUInt16(0)
            data.appendUInt16(0)
            data.appendUInt16(0)
            data.appendUInt32(0)
            data.appendUInt32(entry.offset)
            data.append(pathData)
        }

        guard data.count <= Int(UInt32.max) else {
            throw BackupServiceError.fileTooLarge("central directory")
        }
        let centralDirectorySize = UInt32(data.count) - centralDirectoryOffset
        let count = UInt16(min(entries.count, Int(UInt16.max)))

        data.appendUInt32(0x06054b50)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendUInt16(count)
        data.appendUInt16(count)
        data.appendUInt32(centralDirectorySize)
        data.appendUInt32(centralDirectoryOffset)
        data.appendUInt16(0)

        return data
    }

    private static func dosDateTime(from date: Date) -> (date: UInt16, time: UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max((components.year ?? 1980), 1980)
        let yearBits = (year - 1980) << 9
        let monthBits = (components.month ?? 1) << 5
        let dayBits = components.day ?? 1
        let hourBits = (components.hour ?? 0) << 11
        let minuteBits = (components.minute ?? 0) << 5
        let secondBits = (components.second ?? 0) / 2
        let dosDate = UInt16(yearBits | monthBits | dayBits)
        let dosTime = UInt16(hourBits | minuteBits | secondBits)
        return (dosDate, dosTime)
    }
}

private struct ZipArchiveReader {
    private struct CentralDirectoryEntry {
        var path: String
        var flags: UInt16
        var compression: UInt16
        var crc32: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
    }

    var entries: [String: Data]

    init(data: Data) throws {
        let centralEntries = try Self.readCentralDirectory(in: data)
        var output: [String: Data] = [:]

        for entry in centralEntries {
            guard !entry.path.isEmpty, !entry.path.hasSuffix("/") else { continue }
            guard entry.flags & 0x0001 == 0 else {
                throw BackupServiceError.unsupportedCompression(entry.path)
            }

            let localOffset = Int(entry.localHeaderOffset)
            guard localOffset + 30 <= data.count else {
                throw BackupServiceError.invalidBackup("ZIP 本地文件头越界：\(entry.path)")
            }
            guard try data.readUInt32(at: localOffset) == 0x04034b50 else {
                throw BackupServiceError.invalidBackup("ZIP 本地文件头损坏：\(entry.path)")
            }

            let nameLength = Int(try data.readUInt16(at: localOffset + 26))
            let extraLength = Int(try data.readUInt16(at: localOffset + 28))
            let nameStart = localOffset + 30
            let nameEnd = nameStart + nameLength
            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + Int(entry.compressedSize)
            guard nameEnd <= data.count, dataStart <= data.count, dataEnd <= data.count else {
                throw BackupServiceError.invalidBackup("ZIP 内容长度不正确：\(entry.path)")
            }

            let compressedData = data.subdata(in: dataStart..<dataEnd)
            let fileData: Data
            switch entry.compression {
            case 0:
                fileData = compressedData
            case 8:
                fileData = try Self.inflateRawDeflate(
                    compressedData,
                    expectedSize: Int(entry.uncompressedSize),
                    path: entry.path
                )
            default:
                throw BackupServiceError.unsupportedCompression(entry.path)
            }

            guard fileData.count == Int(entry.uncompressedSize) else {
                throw BackupServiceError.invalidBackup("ZIP 解包大小不一致：\(entry.path)")
            }
            guard CRC32.checksum(fileData) == entry.crc32 else {
                throw BackupServiceError.checksumMismatch(entry.path)
            }
            let normalizedPath = Self.normalizedLegacyExportPath(entry.path)
            guard output[normalizedPath] == nil else {
                throw BackupServiceError.invalidBackup(
                    "ZIP 含有归一化后重复的文件路径：\(normalizedPath)"
                )
            }
            output[normalizedPath] = fileData
        }

        entries = output
    }

    /// Earlier iOS exports could enumerate `/private/var/...` while their
    /// base directory was `/var/...`. The string-based relative-path code then
    /// emitted `attachments//private<filename>` (and the same shape for other
    /// packed directories). Accept only that exact historical shape and map it
    /// back to the intended archive-relative path.
    private static func normalizedLegacyExportPath(_ path: String) -> String {
        let prefixes = [
            "attachments", "assistant_media", "app_fonts",
            "upload", "images", "avatars", "fonts",
        ]
        for prefix in prefixes {
            let legacyPrefix = prefix + "//private"
            guard path.hasPrefix(legacyPrefix) else { continue }
            let suffix = String(path.dropFirst(legacyPrefix.count))
            guard !suffix.isEmpty else { return path }
            return prefix + "/" + suffix
        }
        return path
    }

    private static func readCentralDirectory(in data: Data) throws -> [CentralDirectoryEntry] {
        let endOffset = try findEndOfCentralDirectory(in: data)
        let entryCount = Int(try data.readUInt16(at: endOffset + 10))
        let centralDirectorySize = Int(try data.readUInt32(at: endOffset + 12))
        let centralDirectoryOffset = Int(try data.readUInt32(at: endOffset + 16))

        guard centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw BackupServiceError.invalidBackup("ZIP 中央目录越界")
        }

        var entries: [CentralDirectoryEntry] = []
        var offset = centralDirectoryOffset
        let centralEnd = centralDirectoryOffset + centralDirectorySize

        while offset < centralEnd {
            guard offset + 46 <= data.count else {
                throw BackupServiceError.invalidBackup("ZIP 中央目录不完整")
            }
            guard try data.readUInt32(at: offset) == 0x02014b50 else {
                throw BackupServiceError.invalidBackup("ZIP 中央目录损坏")
            }

            let flags = try data.readUInt16(at: offset + 8)
            let compression = try data.readUInt16(at: offset + 10)
            let crc = try data.readUInt32(at: offset + 16)
            let compressedSize = try data.readUInt32(at: offset + 20)
            let uncompressedSize = try data.readUInt32(at: offset + 24)
            let nameLength = Int(try data.readUInt16(at: offset + 28))
            let extraLength = Int(try data.readUInt16(at: offset + 30))
            let commentLength = Int(try data.readUInt16(at: offset + 32))
            let localHeaderOffset = try data.readUInt32(at: offset + 42)

            guard compressedSize != UInt32.max,
                  uncompressedSize != UInt32.max,
                  localHeaderOffset != UInt32.max else {
                throw BackupServiceError.invalidBackup("暂不支持 ZIP64 备份")
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            let nextOffset = nameEnd + extraLength + commentLength
            guard nameEnd <= data.count, nextOffset <= data.count else {
                throw BackupServiceError.invalidBackup("ZIP 中央目录名称越界")
            }

            let rawNameData = data.subdata(in: nameStart..<nameEnd)
            let rawName = String(data: rawNameData, encoding: .utf8) ?? ""
            entries.append(
                CentralDirectoryEntry(
                    path: safePath(normalizedLegacyExportPath(rawName)),
                    flags: flags,
                    compression: compression,
                    crc32: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
            offset = nextOffset
        }

        guard entries.count == entryCount else {
            throw BackupServiceError.invalidBackup("ZIP 中央目录数量不一致")
        }
        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw BackupServiceError.invalidBackup("ZIP 文件太短")
        }
        let earliest = max(0, data.count - 22 - 65_535)
        var offset = data.count - 22
        while offset >= earliest {
            if (try? data.readUInt32(at: offset)) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }
        throw BackupServiceError.invalidBackup("找不到 ZIP 结束目录")
    }

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int, path: String) throws -> Data {
        if expectedSize == 0 {
            return Data()
        }

        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw BackupServiceError.invalidBackup("无法初始化 Deflate 解压：\(path)")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let bufferCapacity = buffer.count

        let result = compressed.withUnsafeBytes { rawBuffer -> Int32 in
            guard let inputBase = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Z_STREAM_END
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(compressed.count)

            while true {
                let status = buffer.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase
                    stream.avail_out = uInt(bufferCapacity)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = bufferCapacity - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }

                if status == Z_STREAM_END {
                    return status
                }
                if status != Z_OK {
                    return status
                }
                if output.count > expectedSize {
                    return Z_BUF_ERROR
                }
                if produced == 0, stream.avail_in == 0 {
                    return Z_BUF_ERROR
                }
            }
        }

        guard result == Z_STREAM_END else {
            throw BackupServiceError.invalidBackup("Deflate 解压失败：\(path)")
        }
        return output
    }

    private static func safePath(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.joined(separator: "/")
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb88320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }

    func readUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw BackupServiceError.invalidBackup("ZIP 偏移越界")
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw BackupServiceError.invalidBackup("ZIP 偏移越界")
        }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
