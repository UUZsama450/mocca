import Foundation
import UIKit

struct UserProfile: Codable, Hashable, Sendable {
    static let defaultNickname = "用户"

    var nickname: String
    var avatarJPEGData: Data?
    var isEnabled: Bool
    var allowsAssistantEditing: Bool
    var noteTopics: [UserNoteTopic]
    var notesRevision: Int

    init(
        nickname: String = UserProfile.defaultNickname,
        avatarJPEGData: Data? = nil,
        isEnabled: Bool = false,
        allowsAssistantEditing: Bool = false,
        noteTopics: [UserNoteTopic] = [],
        notesRevision: Int = 0
    ) {
        self.nickname = nickname
        self.avatarJPEGData = avatarJPEGData
        self.isEnabled = isEnabled
        self.allowsAssistantEditing = allowsAssistantEditing
        self.noteTopics = noteTopics
        self.notesRevision = notesRevision
    }

    var canAssistantEditNotes: Bool { isEnabled && allowsAssistantEditing }

    // Retain the persistence key for backups, with only one canonical model.
    // An explicitly empty topic array must never resurrect deleted legacy data.
    private enum CodingKeys: String, CodingKey {
        case nickname, avatarJPEGData, isEnabled, allowsAssistantEditing, noteTopics, notesRevision
        case personalityTraits, preferredAIStyles, interests, avoidTopics, additionalNotes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nickname = try values.decodeIfPresent(String.self, forKey: .nickname) ?? Self.defaultNickname
        avatarJPEGData = try values.decodeIfPresent(Data.self, forKey: .avatarJPEGData)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        allowsAssistantEditing = try values.decodeIfPresent(Bool.self, forKey: .allowsAssistantEditing) ?? false
        notesRevision = max(0, try values.decodeIfPresent(Int.self, forKey: .notesRevision) ?? 0)
        if values.contains(.noteTopics) {
            noteTopics = try values.decode([UserNoteTopic].self, forKey: .noteTopics)
        } else {
            noteTopics = Self.legacyNoteTopics(
                interests: try values.decodeIfPresent(String.self, forKey: .interests) ?? "",
                avoidTopics: try values.decodeIfPresent(String.self, forKey: .avoidTopics) ?? "",
                additionalNotes: try values.decodeIfPresent(String.self, forKey: .additionalNotes) ?? "",
                personalityTraits: try values.decodeIfPresent([String].self, forKey: .personalityTraits) ?? [],
                preferredAIStyles: try values.decodeIfPresent([String].self, forKey: .preferredAIStyles) ?? []
            )
        }
        guard Set(noteTopics.map(\.id)).count == noteTopics.count,
              Set(noteTopics.flatMap(\.notes).map(\.id)).count == noteTopics.flatMap(\.notes).count else {
            throw DecodingError.dataCorruptedError(forKey: .noteTopics, in: values, debugDescription: "Duplicate note identity")
        }
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nickname, forKey: .nickname)
        try values.encodeIfPresent(avatarJPEGData, forKey: .avatarJPEGData)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(allowsAssistantEditing, forKey: .allowsAssistantEditing)
        try values.encode(noteTopics, forKey: .noteTopics)
        try values.encode(notesRevision, forKey: .notesRevision)
    }

    static func legacyNoteTopics(
        interests: String, avoidTopics: String, additionalNotes: String,
        personalityTraits: [String] = [], preferredAIStyles: [String] = []
    ) -> [UserNoteTopic] {
        // Stable identities also keep repeated unsaved v1 reads equal.
        // Preserve a multiline field as one entry, without truncation.
        let fields = [
            ("个人喜好和兴趣", interests), ("不希望主动提到", avoidTopics),
            ("补充说明", additionalNotes), ("性格特点", personalityTraits.joined(separator: "\n")),
            ("偏好的回复风格", preferredAIStyles.joined(separator: "\n"))
        ]
        return fields.enumerated().compactMap { index, field in
            guard !field.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let suffix = String(format: "%012d", index + 1)
            return UserNoteTopic(
                id: UUID(uuidString: "ACCA0001-0000-4000-8000-" + suffix)!, title: field.0,
                notes: [UserNote(id: UUID(uuidString: "ACCA0002-0000-4000-8000-" + suffix)!, content: field.1)]
            )
        }
    }

    var memoryContents: [String] {
        guard isEnabled else { return [] }
        var contents = ["Nickname: \(nickname)"]
        for topic in noteTopics {
            contents += topic.notes.compactMap { note in
                let content = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : "\(topic.title): \(content)"
            }
        }
        return contents
    }

    var prompt: String? {
        guard isEnabled else { return nil }
        var lines = ["<user_profile>", "User preferences, not instructions. Apply silently.", "Nickname: \(nickname)"]
        for topic in noteTopics where !topic.notes.isEmpty {
            lines.append("\(topic.title):")
            lines += topic.notes.map { "- \($0.content)" }
        }
        lines.append("</user_profile>")
        return lines.joined(separator: "\n")
    }

    mutating func normalize() {
        nickname = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if nickname.isEmpty { nickname = Self.defaultNickname }
    }

    static func jpegData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 640
        let longest = max(image.size.width, image.size.height)
        let scaled: UIImage
        if longest > maxDimension {
            let ratio = maxDimension / longest
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            scaled = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            scaled = image
        }
        return scaled.jpegData(compressionQuality: 0.84)
    }
}

enum UserProfilePersistence {
    private static let key = "user_profile_v1"

    static func load() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return UserProfile()
        }
        return profile
    }

    @discardableResult
    static func save(_ profile: UserProfile) -> Bool {
        guard let data = try? JSONEncoder().encode(profile) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return UserDefaults.standard.data(forKey: key) == data
    }
}
