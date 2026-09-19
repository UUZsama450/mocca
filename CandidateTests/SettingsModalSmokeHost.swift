import SwiftUI
import UIKit

@MainActor @Observable final class SmokeStats {
    static let shared = SmokeStats()
    var attempts = 0
    var saves = 0
    var draftCleanup = 0
    var originalCleanup = 0
    var queryCancels = 0
    var childSaves = 0
    var failSave = false
    var summary: String { "attempts=\(attempts) saves=\(saves) draftCleanup=\(draftCleanup) originalCleanup=\(originalCleanup) childSaves=\(childSaves)" }
}
struct SmokeConfiguration: Equatable {
    var name = "Original"
    var baseURL = "https://local.invalid"
    var chatPath = "/chat"
    var group = ""
    var customAvatar: String? = "original"
}
@MainActor enum AssistantMediaStore {
    static func remove(_ reference: String?) {
        if reference == "draft" { SmokeStats.shared.draftCleanup += 1 }
        if reference == "original" { SmokeStats.shared.originalCleanup += 1 }
    }
}
@MainActor struct SmokeBalanceQuery {
    func cancel() { SmokeStats.shared.queryCancels += 1 }
}

// EXTRACTED_OBSERVER

@main struct SettingsModalSmokeApp: App {
    var body: some Scene { WindowGroup { SmokeRoot() } }
}
struct SmokeRoot: View {
    @State private var isPresented = false
    private let stats = SmokeStats.shared
    var body: some View {
        VStack(spacing: 20) {
            Button("Open provider") { isPresented = true }.accessibilityIdentifier("open-provider")
            Text(stats.summary).accessibilityIdentifier("root-stats")
        }
        .sheet(isPresented: $isPresented) {
            SmokeEditor { configuration in
                stats.attempts += 1
                guard !stats.failSave else { return false }
                stats.saves += 1
                return true
            }
        }
    }
}
struct SmokeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = SmokeConfiguration()
    @State private var didSave = false
    @State private var saveErrorMessage = ""
    @State private var isSaveErrorPresented = false
    @State private var isLeaveConfirmationPresented = false
    @State private var childPresented = false
    private let originalConfiguration = SmokeConfiguration()
    private let originalAvatar: String? = "original"
    private let balanceQuery = SmokeBalanceQuery()
    private let stats = SmokeStats.shared
    let onSave: (SmokeConfiguration) -> Bool
    var body: some View {
        NavigationStack {
            Form {
                Text(configuration.name).accessibilityIdentifier("draft-name")
                Text(stats.summary).accessibilityIdentifier("editor-stats")
                Button("Modify draft") { configuration.name = "Changed"; configuration.customAvatar = "draft" }.accessibilityIdentifier("modify-draft")
                Button("Fail next save") { stats.failSave = true }.accessibilityIdentifier("fail-save")
                Button("Open child") { childPresented = true }.accessibilityIdentifier("open-child")
                NavigationLink("Push local page") { Text("Local page").navigationTitle("Local page") }
            }
            .navigationTitle("服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: requestDismiss).accessibilityIdentifier("cancel-editor") }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canSave).accessibilityIdentifier("save-editor") }
            }
            .sheet(isPresented: $childPresented) { SmokeChild() }
        }
// EXTRACTED_EDITOR_MODIFIERS_AND_BODY_END
// EXTRACTED_EDITOR_HELPERS
}

// A deliberately small nested-draft stand-in. The production observer is used
// unchanged a second time; persistence and fields remain local fixtures.
struct SmokeChild: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dirty = false
    @State private var leave = false
    var body: some View {
        NavigationStack {
            Form {
                Text(dirty ? "Child changed" : "Child original").accessibilityIdentifier("child-name")
                Button("Modify child") { dirty = true }.accessibilityIdentifier("modify-child")
            }.navigationTitle("模型")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭模型") { requestDismiss() } } }
        }
        .interactiveDismissDisabled(dirty)
        .background { ProviderDraftDismissObserver(hasUnsavedChanges: dirty, onAttempt: requestDismiss) }
        .alert("保存模型修改？", isPresented: $leave) {
            Button("保存并离开") { SmokeStats.shared.childSaves += 1; dismiss() }
            Button("不保存", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }
    private func requestDismiss() { if dirty { leave = true } else { dismiss() } }
}
