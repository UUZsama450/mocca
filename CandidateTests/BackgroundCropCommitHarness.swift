// Test-only stand-ins for preference/profile state. Commit function bodies are
// appended verbatim from the shipping entry points by the host preparer.
struct CropPreferences: Equatable {
    var sidebarBackground: String?
    var sidebarBackgroundEnabled = false
}
@MainActor final class CropModel {
    var preferences: CropPreferences
    init(_ reference: String) { preferences = CropPreferences(sidebarBackground: reference) }
}
@MainActor enum AppPreferences {
    static var allowSave = true
    static var saved: CropPreferences?
    static func savePreferences(_ preferences: CropPreferences) -> Bool {
        guard allowSave else { return false }
        saved = preferences
        return true
    }
}
@MainActor enum CropSaveGate {
    static var shouldPause = false
    static var continuation: CheckedContinuation<Void, Never>?
    static func wait() async {
        if shouldPause { await withCheckedContinuation { continuation = $0 } }
    }
    static func release() {
        shouldPause = false
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
@MainActor final class SidebarCommitHarness {
    let model: CropModel
    var pendingSidebarBackgroundCrop: BackgroundCropRequest?
    var pendingSidebarCropVisibilitySequence: UInt64 = 1
    var sidebarBackgroundVisibilitySequence: UInt64 = 1
    init(old: String, image: UIImage) {
        model = CropModel(old)
        pendingSidebarBackgroundCrop = BackgroundCropRequest(image: image)
    }
    // SIDEBAR_COMMIT
}
struct CropProfile {
    var id: UUID
    var background: String?
}
@MainActor final class AssistantCommitHarness {
    var profile: CropProfile
    let originalBackground: String?
    var editorIsActive = true
    var pendingBackgroundCrop: BackgroundCropRequest?
    init(owner: UUID, old: String, image: UIImage) {
        profile = CropProfile(id: owner, background: old)
        originalBackground = old
        pendingBackgroundCrop = BackgroundCropRequest(image: image)
    }
    // ASSISTANT_COMMIT
}
