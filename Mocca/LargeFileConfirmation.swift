import SwiftUI

@MainActor @Observable final class LargeFileReminderPreference {
    static let shared = LargeFileReminderPreference(defaults: .standard)
    private static let key = "large_text_reminders_disabled_v1"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var isDisabled: Bool

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isDisabled = defaults.bool(forKey: Self.key)
    }

    func setEnabled(_ enabled: Bool) {
        isDisabled = !enabled
        defaults.set(!enabled, forKey: Self.key)
    }

    func disable() { setEnabled(false) }
}

@MainActor @Observable final class LargeFileConfirmation {
    struct Request: Identifiable {
        let id: UUID
        let names: [String]
        let assistantFile: Bool
        var includesLargeFile = false
    }
    @ObservationIgnored private let preference: LargeFileReminderPreference

    init(preference: LargeFileReminderPreference = .shared) {
        self.preference = preference
    }

    private(set) var current: Request?
    @ObservationIgnored private var waiting: [Request] = []
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var isEnabled: Bool { !preference.isDisabled }

    func confirm(names: [String], assistantFile: Bool = false, includesLargeFile: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !names.isEmpty, !preference.isDisabled else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                continuations[id] = continuation
                let request = Request(id: id, names: names, assistantFile: assistantFile, includesLargeFile: includesLargeFile)
                if current == nil { current = request } else { waiting.append(request) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, accepted: false) }
        }
    }

    func resolve(id: UUID, accepted: Bool, dontRemindAgain: Bool = false) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        if accepted, dontRemindAgain {
            preference.disable()
            let pending = Array(continuations.values)
            continuations.removeAll()
            waiting.removeAll()
            current = nil
            continuation.resume(returning: true)
            for item in pending { item.resume(returning: true) }
            return
        }
        waiting.removeAll { $0.id == id }
        if current?.id == id {
            current = waiting.isEmpty ? nil : waiting.removeFirst()
        }
        continuation.resume(returning: accepted)
    }
}

struct LargeFileConfirmationModifier: ViewModifier {
    let confirmation: LargeFileConfirmation

    func body(content: Content) -> some View {
        let displayed = confirmation.current
        content.sheet(item: Binding(
            get: { displayed },
            set: { value in
                if value == nil, let displayed {
                    confirmation.resolve(id: displayed.id, accepted: false)
                }
            }
        )) { request in
            LargeFileConfirmationSheet(request: request) { accepted, dontRemindAgain in
                confirmation.resolve(id: request.id, accepted: accepted, dontRemindAgain: dontRemindAgain)
            }
        }
    }
}

struct LargeFileConfirmationSheet: View {
    let request: LargeFileConfirmation.Request
    let decide: (Bool, Bool) -> Void
    @State private var dontRemindAgain = false
    @ScaledMetric(relativeTo: .body) private var actionLabelHeight = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.lookup(request.includesLargeFile ? "这份文件有点大" : "这份内容有点长"))
                            .font(.headline)
                        Text(L10n.lookup(request.includesLargeFile ? "超过 60,000 字符或 100 MB · 保留完整文件" : "超过 60,000 字符 · 保留完整内容"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        ForEach(Array(request.names.enumerated()), id: \.offset) { index, name in
                            if index > 0 {
                                Divider().padding(.leading, 52)
                            }
                            Label {
                                Text(name)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(16)
                        }
                    }
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 26))

                    Text(L10n.lookup(request.assistantFile
                        ? "启用后，全文会随这个助手的每次聊天发送，可能增加用量与等待时间。文件过大可能增加内存占用并导致界面卡顿；超出模型容量时请求可能失败。同一份文件确认后不再提醒。"
                        : request.includesLargeFile
                            ? "导入和处理大文件可能需要更多时间与本地空间，增加内存占用并导致界面卡顿。较长文本可能增加模型用量；文件能否被模型读取取决于格式，ZIP 等压缩包不会自动解压读取。"
                            : "全文会发送给你选择的模型，可能增加用量与等待时间。文件过大可能增加内存占用并导致界面卡顿；超出模型容量时请求可能失败。确认后，发送时不再提醒。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)

                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.clear)
            .navigationTitle(L10n.lookup("大文件提醒"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { decide(false, false) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("关闭"))
                }
            }
        }
        .tint(Color(uiColor: .systemBlue))
        .presentationDetents([.height(600), .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var actions: some View {
        VStack(spacing: 16) {
            actionLayout {
                Button { decide(false, false) } label: {
                    actionLabel(L10n.lookup("取消"))
                }
                .buttonStyle(.bordered)
                Button { decide(true, dontRemindAgain) } label: {
                    actionLabel(L10n.lookup(request.includesLargeFile ? "保留文件并继续" : "保留全文并继续"))
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            VStack(spacing: 8) {
                Button { dontRemindAgain.toggle() } label: {
                    Label(L10n.lookup("不再提醒"), systemImage: dontRemindAgain ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(dontRemindAgain ? Color(uiColor: .systemBlue) : .secondary)
                .accessibilityLabel(L10n.lookup("不再提醒"))
                .accessibilityAddTraits(dontRemindAgain ? .isSelected : [])
                Text(L10n.lookup("可在「偏好设置 → 行为与启动」中重新开启"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private func actionLabel(_ title: String) -> some View {
        Text(title)
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: actionLabelHeight)
    }

}
