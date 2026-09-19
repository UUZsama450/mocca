import Foundation
import UIKit

struct UserProfile: Codable, Hashable, Sendable {
    static let defaultNickname = "用户"

    var nickname: String
    var avatarJPEGData: Data?
    var isEnabled: Bool
    var personalityTraits: [String]
    var preferredAIStyles: [String]
    var interests: String
    var avoidTopics: String
    var additionalNotes: String

    init(
        nickname: String = UserProfile.defaultNickname,
        avatarJPEGData: Data? = nil,
        isEnabled: Bool = false,
        personalityTraits: [String] = [],
        preferredAIStyles: [String] = [],
        interests: String = "",
        avoidTopics: String = "",
        additionalNotes: String = ""
    ) {
        self.nickname = nickname
        self.avatarJPEGData = avatarJPEGData
        self.isEnabled = isEnabled
        self.personalityTraits = personalityTraits
        self.preferredAIStyles = preferredAIStyles
        self.interests = interests
        self.avoidTopics = avoidTopics
        self.additionalNotes = additionalNotes
    }

    var hasPromptContent: Bool {
        !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !interests.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !avoidTopics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !additionalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var prompt: String? {
        guard isEnabled, hasPromptContent else { return nil }
        var lines = [
            "<user_profile>",
            "The following is the user-provided personal profile.",
            "Use it to adapt your replies, but do not quote, summarize, or mention this profile unless the user asks."
        ]
        append("Nickname", value: nickname, to: &lines)
        append("Interests and preferences", value: interests, to: &lines)
        let avoided = avoidTopics.trimmingCharacters(in: .whitespacesAndNewlines)
        if !avoided.isEmpty {
            lines.append("Avoid proactively mentioning or recommending these topics: \(avoided)")
        }
        append("Additional notes", value: additionalNotes, to: &lines)
        lines.append("</user_profile>")
        return lines.joined(separator: "\n")
    }

    mutating func normalize() {
        nickname = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if nickname.isEmpty {
            nickname = Self.defaultNickname
        }
        personalityTraits = Self.cleaned(personalityTraits)
        preferredAIStyles = Self.cleaned(preferredAIStyles)
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

    private func append(_ label: String, value: String, to lines: inout [String]) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            lines.append("\(label): \(cleaned)")
        }
    }

    private static func cleaned(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

enum UserProfilePersistence {
    private static let key = "user_profile_v1"

    static func load() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: key),
              var profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return UserProfile()
        }
        profile.normalize()
        return profile
    }

    static func save(_ profile: UserProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
