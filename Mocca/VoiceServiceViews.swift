import AVFoundation
import SwiftUI

struct VoiceServicesPage: View {
    @Environment(AppModel.self) private var model
    @State private var editingService: VoiceServiceConfiguration?
    @State private var pendingDeletion: VoiceServiceConfiguration?
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                systemVoiceRow

                ForEach(model.preferences.voiceServices) { service in
                    serviceRow(service)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = service
                            } label: {
                                Label(L10n.lookup("删除"), systemImage: "trash")
                            }
                            Button {
                                editingService = service
                            } label: {
                                Label(L10n.lookup("编辑"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            } header: {
                Text(L10n.lookup("语音引擎"))
            } footer: {
                Text(L10n.lookup("勾选要用于消息朗读、自动朗读和“语音朗读”工具的引擎。网络服务的 API Key 只保存在系统钥匙串。"))
            }

            Section {
                NavigationLink {
                    VoicePlaybackSettingsPage()
                } label: {
                    Label(L10n.lookup("朗读与系统语音设置"), systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text(L10n.lookup("可设置自动朗读、文本范围、系统声音、语速和音调。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("语音服务"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(VoiceServiceKind.allCases) { kind in
                        Button {
                            editingService = .makeDefault(kind: kind)
                        } label: {
                            Text(L10n.lookup(kind.title))
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.lookup("添加语音服务"))
            }
        }
        .overlay(alignment: .top) {
            VoicePlaybackOverlay()
        }
        .sheet(item: $editingService) { service in
            VoiceServiceEditorView(configuration: service)
        }
        .alert(L10n.lookup("删除语音服务"), isPresented: deletionBinding) {
            Button(L10n.lookup("取消"), role: .cancel) {
                pendingDeletion = nil
            }
            Button(L10n.lookup("删除"), role: .destructive) {
                guard let service = pendingDeletion else { return }
                VoiceSecretStore.remove(service)
                model.updatePreferences { preferences in
                    preferences.voiceServices.removeAll { $0.id == service.id }
                    if preferences.selectedVoiceServiceID == service.id {
                        preferences.selectedVoiceServiceID = nil
                    }
                }
                if VoicePlaybackController.shared.serviceTitle == service.resolvedName {
                    DeviceTTSService.stop()
                }
                pendingDeletion = nil
            }
        } message: {
            if let pendingDeletion {
                Text(L10n.format("删除“%@”及其钥匙串密钥？", [String(describing: pendingDeletion.resolvedName)]))
            }
        }
        .alert(L10n.lookup("语音服务"), isPresented: noticeBinding) {
            Button(L10n.lookup("好"), role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var systemVoiceRow: some View {
        HStack(spacing: 12) {
            Button {
                model.updatePreferences { $0.selectedVoiceServiceID = nil }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.and.waveform")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.lookup("系统语音"))
                            .font(.body.weight(.regular))
                        Text(selectedSystemVoiceTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if model.preferences.selectedVoiceServiceID == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(uiColor: model.themeAccentUIColor))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                testSystemVoice()
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 20))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.lookup("测试系统语音"))
        }
        .frame(minHeight: 58)
    }

    private func serviceRow(_ service: VoiceServiceConfiguration) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(
                        service.enabled
                            ? Color(uiColor: model.themeAccentUIColor)
                            : .secondary
                    )
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(service.resolvedName)
                            .font(.body.weight(.regular))
                            .foregroundStyle(.primary)
                        if !service.enabled {
                            Text(L10n.lookup("已停用"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(service.kind.title) · \(service.resolvedModel.isEmpty ? service.resolvedVoice : service.resolvedModel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if model.preferences.selectedVoiceServiceID == service.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(uiColor: model.themeAccentUIColor))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard service.enabled else {
                    notice = L10n.lookup("请先在编辑页启用这个语音服务。")
                    return
                }
                model.updatePreferences { $0.selectedVoiceServiceID = service.id }
            }

            Menu {
                Button {
                    test(service)
                } label: {
                    Label(L10n.lookup("测试"), systemImage: "play")
                }
                Button {
                    editingService = service
                } label: {
                    Label(L10n.lookup("编辑"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDeletion = service
                } label: {
                    Label(L10n.lookup("删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("%@操作", [String(describing: service.resolvedName)]))
        }
        .frame(minHeight: 64)
    }

    private var selectedSystemVoiceTitle: String {
        if let identifier = model.preferences.ttsVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return "\(voice.name) · \(voice.language)"
        }
        if let language = model.preferences.ttsLanguage, !language.isEmpty {
            return L10n.format("跟随系统 · %@", [String(describing: language)])
        }
        return L10n.lookup("跟随系统")
    }

    private func testSystemVoice() {
        var preferences = model.preferences
        preferences.selectedVoiceServiceID = nil
        DeviceTTSService.speak(
            text: L10n.lookup("你好，这是一段系统语音测试。"),
            messageID: nil,
            preferences: preferences
        )
    }

    private func test(_ service: VoiceServiceConfiguration) {
        if let validation = service.validationMessage {
            notice = validation
            return
        }
        var preferences = model.preferences
        if let index = preferences.voiceServices.firstIndex(where: { $0.id == service.id }) {
            preferences.voiceServices[index] = service
        } else {
            preferences.voiceServices.append(service)
        }
        preferences.selectedVoiceServiceID = service.id
        DeviceTTSService.speak(
            text: L10n.lookup("你好，这是一段网络语音服务测试。"),
            messageID: nil,
            preferences: preferences
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }
}

private struct VoiceServiceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VoiceServiceConfiguration
    @State private var notice: String?

    init(configuration: VoiceServiceConfiguration) {
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("服务")) {
                    LabeledContent(L10n.lookup("类型"), value: draft.kind.title)
                    TextField(L10n.lookup("名称"), text: $draft.name)
                    Toggle(L10n.lookup("启用"), isOn: $draft.enabled)
                }

                Section(L10n.lookup("连接")) {
                    SecureField("API Key", text: $draft.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.lookup("服务地址"), text: $draft.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section(L10n.lookup("语音参数")) {
                    if draft.kind != .xAI {
                        TextField(L10n.lookup("模型"), text: $draft.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField(voiceFieldTitle, text: $draft.voice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if draft.kind == .miniMax {
                        TextField(L10n.lookup("情感"), text: $draft.emotion)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.lookup("服务语速"))
                                Spacer()
                                Text(String(format: "%.2fx", draft.speed))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $draft.speed, in: 0.5...2.0, step: 0.05)
                                .tint(Color(uiColor: model.themeSliderUIColor))
                        }
                    }

                    if draft.kind == .qwen || draft.kind == .xAI {
                        TextField(
                            draft.kind == .qwen ? L10n.lookup("语言类型") : L10n.lookup("语言"),
                            text: $draft.language
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    if draft.kind == .elevenLabs {
                        TextField(L10n.lookup("输出格式"), text: $draft.outputFormat)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button {
                        testDraft()
                    } label: {
                        Label(L10n.lookup("测试当前配置"), systemImage: "play.circle")
                    }
                } footer: {
                    Text(L10n.lookup("测试会立即使用当前表单内容，不必先保存。"))
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(model.preferences.voiceServices.contains(where: { $0.id == draft.id }) ? L10n.lookup("编辑语音服务") : L10n.lookup("添加语音服务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        save()
                    }
                        .foregroundStyle(.primary)
                }
            }
            .alert(L10n.lookup("语音服务"), isPresented: noticeBinding) {
                Button(L10n.lookup("好"), role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
        }
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.visible)
        .overlay(alignment: .top) {
            VoicePlaybackOverlay()
        }
    }

    private var voiceFieldTitle: String {
        switch draft.kind {
        case .gemini: "Voice Name"
        case .miniMax, .xAI, .elevenLabs: "Voice ID"
        default: L10n.lookup("语音")
        }
    }

    private func testDraft() {
        if let validation = draft.validationMessage {
            notice = validation
            return
        }
        var preferences = model.preferences
        if let index = preferences.voiceServices.firstIndex(where: { $0.id == draft.id }) {
            preferences.voiceServices[index] = draft
        } else {
            preferences.voiceServices.append(draft)
        }
        preferences.selectedVoiceServiceID = draft.id
        DeviceTTSService.speak(
            text: L10n.lookup("你好，这是一段网络语音服务测试。"),
            messageID: nil,
            preferences: preferences
        )
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.voice = draft.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.language = draft.language.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updatePreferences { preferences in
            if let index = preferences.voiceServices.firstIndex(where: { $0.id == draft.id }) {
                preferences.voiceServices[index] = draft
            } else {
                preferences.voiceServices.append(draft)
            }
            if preferences.selectedVoiceServiceID == nil && draft.enabled {
                preferences.selectedVoiceServiceID = draft.id
            }
        }
        dismiss()
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )
    }
}

struct VoicePlaybackSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: preferenceBinding(\.ttsAutoPlayAssistantReplies)
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.lookup("自动朗读助手回复"))
                        Text(L10n.lookup("助手完成回复后，自动使用当前选中的语音服务朗读。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.lookup("播放"))
            }

            Section {
                ForEach(VoiceTextSelectionMode.allCases) { mode in
                    Button {
                        model.updatePreferences { $0.ttsTextSelectionMode = mode }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.lookup(mode.title))
                                    .foregroundStyle(.primary)
                                Text(L10n.lookup(mode.description))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.preferences.ttsTextSelectionMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: model.themeAccentUIColor))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(L10n.lookup("朗读范围"))
            } footer: {
                Text(L10n.lookup("所选范围没有匹配到内容时，会自动回退为完整消息，避免无声结束。"))
            }

            Section {
                NavigationLink {
                    SystemVoicePickerPage()
                } label: {
                    HStack {
                        Text(L10n.lookup("系统声音"))
                        Spacer()
                        Text(systemVoiceTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.lookup("语速"))
                        Spacer()
                        Text(String(format: "%.2f", model.preferences.ttsSpeechRate))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: preferenceBinding(\.ttsSpeechRate),
                        in: 0.1...1.0,
                        step: 0.05
                    )
                    .tint(Color(uiColor: model.themeSliderUIColor))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.lookup("音调"))
                        Spacer()
                        Text(String(format: "%.2f", model.preferences.ttsPitch))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: preferenceBinding(\.ttsPitch),
                        in: 0.5...2.0,
                        step: 0.05
                    )
                    .tint(Color(uiColor: model.themeSliderUIColor))
                }

                Button {
                    var preferences = model.preferences
                    preferences.selectedVoiceServiceID = nil
                    DeviceTTSService.speak(
                        text: L10n.lookup("你好，这是一段系统语音测试。"),
                        messageID: nil,
                        preferences: preferences
                    )
                } label: {
                    Label(L10n.lookup("测试系统语音"), systemImage: "play.circle")
                }
            } header: {
                Text(L10n.lookup("系统语音"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("朗读设置"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            VoicePlaybackOverlay()
        }
    }

    private var systemVoiceTitle: String {
        if let identifier = model.preferences.ttsVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice.name
        }
        return L10n.lookup("跟随系统")
    }

    private func preferenceBinding<T>(
        _ keyPath: WritableKeyPath<UserPreferences, T>
    ) -> Binding<T> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in
                model.updatePreferences { $0[keyPath: keyPath] = value }
            }
        )
    }
}

private struct SystemVoicePickerPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter {
                query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.language.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                let languageOrder = $0.language.localizedCaseInsensitiveCompare($1.language)
                if languageOrder != .orderedSame {
                    return languageOrder == .orderedAscending
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        List {
            Button {
                model.updatePreferences {
                    $0.ttsVoiceIdentifier = nil
                    $0.ttsLanguage = nil
                }
                dismiss()
            } label: {
                voiceRow(
                    title: L10n.lookup("跟随系统"),
                    subtitle: L10n.lookup("由 iOS 自动选择声音"),
                    selected: model.preferences.ttsVoiceIdentifier == nil
                )
            }
            .buttonStyle(.plain)

            ForEach(voices, id: \.identifier) { voice in
                Button {
                    model.updatePreferences {
                        $0.ttsVoiceIdentifier = voice.identifier
                        $0.ttsLanguage = voice.language
                    }
                    dismiss()
                } label: {
                    voiceRow(
                        title: voice.name,
                        subtitle: "\(voice.language)\(qualitySuffix(voice))",
                        selected: model.preferences.ttsVoiceIdentifier == voice.identifier
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .settingsGroupedPageStyle()
        .searchable(text: $query, prompt: L10n.lookup("搜索声音或语言"))
        .navigationTitle(L10n.lookup("系统声音"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func voiceRow(
        title: String,
        subtitle: String,
        selected: Bool
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(uiColor: model.themeAccentUIColor))
            }
        }
        .contentShape(Rectangle())
    }

    private func qualitySuffix(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
    }
}

@MainActor
struct VoicePlaybackOverlay: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var controller = VoicePlaybackController.shared

    var body: some View {
        if controller.state != .idle {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    statusView
                    Spacer(minLength: 8)
                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("关闭语音播放器"))
                }

                if controller.state == .playing || controller.state == .paused {
                    if controller.canSeek {
                        Slider(
                            value: Binding(
                                get: { controller.progress },
                                set: { controller.seek(to: $0) }
                            ),
                            in: 0...max(controller.duration, 0.1)
                        )
                        .tint(Color(uiColor: model.themeSliderUIColor))
                    }

                    HStack(spacing: 24) {
                        Button {
                            controller.seek(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                        }
                        .disabled(!controller.canSeek)

                        Button {
                            controller.pauseOrResume()
                        } label: {
                            Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Color.primary.opacity(0.08)))
                        }

                        Button {
                            controller.seek(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                        }
                        .disabled(!controller.canSeek)

                        Button {
                            controller.cyclePlaybackRate()
                        } label: {
                            Text(String(format: "%.2gx", controller.playbackRate))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .frame(minWidth: 40)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.serviceTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.lookup("正在生成语音…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.lookup("语音播放失败"))
                    .font(.subheadline.weight(.semibold))
                Text(controller.errorMessage ?? L10n.lookup("未知错误"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.serviceTitle)
                    .font(.subheadline.weight(.semibold))
                Text(controller.isPaused ? L10n.lookup("已暂停") : L10n.lookup("正在朗读"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
