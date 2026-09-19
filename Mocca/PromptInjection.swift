import Foundation

struct InstructionInjection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var prompt: String
    var group: String

    init(id: UUID = UUID(), title: String = "", prompt: String = "", group: String = "") {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
    }
}

/// raw value 对齐旧 Kelivo 的 JSON 序列化，方便以后导入。
enum WorldBookInjectionPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case beforeSystemPrompt = "BEFORE_SYSTEM_PROMPT"
    case afterSystemPrompt = "AFTER_SYSTEM_PROMPT"
    case topOfChat = "TOP_OF_CHAT"
    case bottomOfChat = "BOTTOM_OF_CHAT"
    case atDepth = "AT_DEPTH"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beforeSystemPrompt: "系统提示词之前"
        case .afterSystemPrompt: "系统提示词之后"
        case .topOfChat: "对话开头"
        case .bottomOfChat: "对话末尾"
        case .atDepth: "指定深度"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = WorldBookInjectionPosition(rawValue: raw.uppercased()) ?? .afterSystemPrompt
    }
}

enum WorldBookInjectionRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case user = "USER"
    case assistant = "ASSISTANT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: "用户"
        case .assistant: "助手"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = WorldBookInjectionRole(rawValue: raw.uppercased()) ?? .user
    }
}

struct WorldBookEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var priority: Int
    var position: WorldBookInjectionPosition
    var content: String
    var injectDepth: Int
    var role: WorldBookInjectionRole
    var keywords: [String]
    var useRegex: Bool
    var caseSensitive: Bool
    var scanDepth: Int
    var injectionRounds: Int
    var constantActive: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        enabled: Bool = true,
        priority: Int = 0,
        position: WorldBookInjectionPosition = .afterSystemPrompt,
        content: String = "",
        injectDepth: Int = 4,
        role: WorldBookInjectionRole = .user,
        keywords: [String] = [],
        useRegex: Bool = false,
        caseSensitive: Bool = false,
        scanDepth: Int = 4,
        injectionRounds: Int = 0,
        constantActive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.position = position
        self.content = content
        self.injectDepth = injectDepth
        self.role = role
        self.keywords = keywords
        self.useRegex = useRegex
        self.caseSensitive = caseSensitive
        self.scanDepth = scanDepth
        self.injectionRounds = injectionRounds
        self.constantActive = constantActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        position = try container.decodeIfPresent(WorldBookInjectionPosition.self, forKey: .position)
            ?? .afterSystemPrompt
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        injectDepth = try container.decodeIfPresent(Int.self, forKey: .injectDepth) ?? 4
        role = try container.decodeIfPresent(WorldBookInjectionRole.self, forKey: .role) ?? .user
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        scanDepth = try container.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 4
        injectionRounds = try container.decodeIfPresent(Int.self, forKey: .injectionRounds) ?? 0
        constantActive = try container.decodeIfPresent(Bool.self, forKey: .constantActive) ?? false
    }
}

struct WorldBook: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var description: String
    var enabled: Bool
    var entries: [WorldBookEntry]

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        enabled: Bool = true,
        entries: [WorldBookEntry] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.enabled = enabled
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        entries = try container.decodeIfPresent([WorldBookEntry].self, forKey: .entries) ?? []
    }
}

enum PromptInjectionPersistence {
    private static let instructionsKey = "instruction_injections_v1"
    private static let activeInstructionsKey = "instruction_active_ids_by_assistant_v1"
    private static let worldBooksKey = "world_books_v1"
    private static let activeWorldBooksKey = "world_book_active_ids_by_assistant_v1"

    static func loadInstructions() -> [InstructionInjection] {
        decode([InstructionInjection].self, key: instructionsKey) ?? []
    }

    static func saveInstructions(_ items: [InstructionInjection]) {
        encode(items, key: instructionsKey)
    }

    static func loadActiveInstructionIDs() -> [String: Set<UUID>] {
        decode([String: Set<UUID>].self, key: activeInstructionsKey) ?? [:]
    }

    static func saveActiveInstructionIDs(_ map: [String: Set<UUID>]) {
        encode(map, key: activeInstructionsKey)
    }

    static func loadWorldBooks() -> [WorldBook] {
        decode([WorldBook].self, key: worldBooksKey) ?? []
    }

    static func saveWorldBooks(_ books: [WorldBook]) {
        encode(books, key: worldBooksKey)
    }

    static func loadActiveWorldBookIDs() -> [String: Set<UUID>] {
        decode([String: Set<UUID>].self, key: activeWorldBooksKey) ?? [:]
    }

    static func saveActiveWorldBookIDs(_ map: [String: Set<UUID>]) {
        encode(map, key: activeWorldBooksKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 提示词组装：指令注入 + 世界书，移植自旧 message_builder_service.dart。
enum PromptInjectionEngine {
    struct Result {
        var systemPrompt: String?
        var messages: [ChatRequestMessage]
    }

    static func assemble(
        systemPrompt: String?,
        messages: [ChatRequestMessage],
        instructions: [InstructionInjection],
        books: [WorldBook]
    ) -> Result {
        var system = systemPrompt ?? ""
        var output = messages

        let instructionPrompts = instructions
            .map { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !instructionPrompts.isEmpty {
            let joined = instructionPrompts.joined(separator: "\n\n")
            system = system.isEmpty ? joined : system + "\n\n" + joined
        }

        applyWorldBooks(books, system: &system, messages: &output)

        let cleanedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(systemPrompt: cleanedSystem.isEmpty ? nil : cleanedSystem, messages: output)
    }

    private static func applyWorldBooks(
        _ books: [WorldBook],
        system: inout String,
        messages: inout [ChatRequestMessage]
    ) {
        let activeBooks = books.filter(\.enabled)
        guard !activeBooks.isEmpty else { return }

        func recentMessages(depth rawDepth: Int) -> [(role: String, content: String)] {
            let depth = max(1, rawDepth)
            var collected: [(String, String)] = []
            for message in messages.reversed() {
                guard collected.count < depth else { break }
                guard message.role == "user" || message.role == "assistant" else { continue }
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                collected.append((message.role, content))
            }
            return collected.reversed()
        }

        func matchesKeyword(_ entry: WorldBookEntry, in context: String) -> Bool {
            for raw in entry.keywords {
                let keyword = raw.trimmingCharacters(in: .whitespaces)
                guard !keyword.isEmpty else { continue }
                if entry.useRegex {
                    let options: NSRegularExpression.Options = entry.caseSensitive ? [] : [.caseInsensitive]
                    if let regex = try? NSRegularExpression(pattern: keyword, options: options),
                       regex.firstMatch(
                           in: context,
                           range: NSRange(context.startIndex..., in: context)
                       ) != nil {
                        return true
                    }
                } else if entry.caseSensitive {
                    if context.contains(keyword) { return true }
                } else if context.lowercased().contains(keyword.lowercased()) {
                    return true
                }
            }
            return false
        }

        func isTriggered(_ entry: WorldBookEntry, recent: [(role: String, content: String)]) -> Bool {
            guard entry.enabled else { return false }
            if entry.constantActive { return true }
            guard !entry.keywords.isEmpty else { return false }

            let rounds = min(max(entry.injectionRounds, 0), 200)
            if rounds <= 0 {
                let context = recent.map(\.content).joined(separator: "\n")
                return matchesKeyword(entry, in: context)
            }

            var userTurnsSinceMatch = 0
            for item in recent.reversed() {
                if matchesKeyword(entry, in: item.content) {
                    return userTurnsSinceMatch < rounds
                }
                if item.role == "user" {
                    userTurnsSinceMatch += 1
                }
            }
            return false
        }

        var contextCache: [Int: [(role: String, content: String)]] = [:]
        var triggered: [(entry: WorldBookEntry, seq: Int)] = []
        var seq = 0
        for book in activeBooks {
            for entry in book.entries {
                let depth = min(max(entry.scanDepth <= 0 ? 1 : entry.scanDepth, 1), 200)
                let context: [(role: String, content: String)]
                if let cached = contextCache[depth] {
                    context = cached
                } else {
                    context = recentMessages(depth: depth)
                    contextCache[depth] = context
                }
                if isTriggered(entry, recent: context) {
                    triggered.append((entry, seq))
                }
                seq += 1
            }
        }
        guard !triggered.isEmpty else { return }

        triggered.sort {
            if $0.entry.priority != $1.entry.priority {
                return $0.entry.priority > $1.entry.priority
            }
            return $0.seq < $1.seq
        }

        func joinContents(_ entries: [WorldBookEntry]) -> String {
            entries
                .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        func mergedInjectionMessages(_ entries: [WorldBookEntry]) -> [ChatRequestMessage] {
            var byRole: [WorldBookInjectionRole: [WorldBookEntry]] = [:]
            for entry in entries where !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                byRole[entry.role, default: []].append(entry)
            }
            var result: [ChatRequestMessage] = []
            for role in [WorldBookInjectionRole.user, .assistant] {
                guard let group = byRole[role] else { continue }
                let merged = joinContents(group)
                guard !merged.isEmpty else { continue }
                if role == .assistant {
                    result.append(ChatRequestMessage(role: "assistant", content: merged))
                } else {
                    result.append(ChatRequestMessage(role: "user", content: "<system>\n\(merged)\n</system>"))
                }
            }
            return result
        }

        var byPosition: [WorldBookInjectionPosition: [WorldBookEntry]] = [:]
        for item in triggered {
            byPosition[item.entry.position, default: []].append(item.entry)
        }

        let beforeContent = joinContents(byPosition[.beforeSystemPrompt] ?? [])
        let afterContent = joinContents(byPosition[.afterSystemPrompt] ?? [])
        if !beforeContent.isEmpty || !afterContent.isEmpty {
            var pieces: [String] = []
            if !beforeContent.isEmpty { pieces.append(beforeContent) }
            if !system.isEmpty { pieces.append(system) }
            if !afterContent.isEmpty { pieces.append(afterContent) }
            system = pieces.joined(separator: "\n")
        }

        if let top = byPosition[.topOfChat], !top.isEmpty {
            var insertIndex = messages.firstIndex { $0.role == "user" } ?? messages.count
            insertIndex = min(max(insertIndex, 0), messages.count)
            messages.insert(contentsOf: mergedInjectionMessages(top), at: insertIndex)
        }

        if let bottom = byPosition[.bottomOfChat], !bottom.isEmpty {
            let insertIndex = messages.isEmpty ? 0 : messages.count - 1
            messages.insert(contentsOf: mergedInjectionMessages(bottom), at: insertIndex)
        }

        if let atDepth = byPosition[.atDepth], !atDepth.isEmpty {
            var byDepth: [Int: [WorldBookEntry]] = [:]
            for entry in atDepth {
                let depth = min(max(entry.injectDepth <= 0 ? 1 : entry.injectDepth, 1), 200)
                byDepth[depth, default: []].append(entry)
            }
            // 深度大的先插，避免索引被后续插入挪动。
            for depth in byDepth.keys.sorted(by: >) {
                guard let group = byDepth[depth] else { continue }
                let insertIndex = min(max(messages.count - depth, 0), messages.count)
                messages.insert(contentsOf: mergedInjectionMessages(group), at: insertIndex)
            }
        }
    }
}
