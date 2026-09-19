import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct MoccaGenerationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var assistantName: String
        var detail: String
        var startedAt: Date
        var isFinished: Bool
        var languageCode: String? = nil
    }

    let conversationID: String
}
