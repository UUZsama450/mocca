import PhotosUI
import SwiftUI
import UIKit

struct AssistantAvatarView: View {
    @Environment(AppModel.self) private var model
    let profile: AssistantProfile
    var size: CGFloat = 44

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    var body: some View {
        if let image = AssistantMediaStore.image(for: profile.avatar) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let assetName = profile.assetAvatarName {
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if let emoji = profile.emojiAvatar {
            ZStack {
                Circle().fill(themeAccent.opacity(0.11))
                Text(emoji)
                    .font(.system(size: size * 0.5))
            }
            .frame(width: size, height: size)
        } else {
            ZStack {
                Circle().fill(themeAccent.opacity(0.12))
                Image("DefaultAssistantAvatar")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(themeAccent)
                    .padding(size * 0.16)
            }
            .frame(width: size, height: size)
        }
    }
}

struct AssistantSelectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingAssistant: AssistantProfile?
    @State private var assistantToDelete: AssistantProfile?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.assistants) { assistant in
                        assistantRow(assistant)
                            .deleteDisabled(model.assistants.count <= 1)
                            .listRowBackground(Color.primary.opacity(0.045))
                    }
                    .onMove(perform: model.moveAssistants)
                    .onDelete(perform: deleteAssistants)
                } header: {
                    Text(L10n.lookup("助手列表"))
                        .textCase(nil)
                } footer: {
                    Text(L10n.lookup("点按助手即可切换；进入编辑模式后可以调整顺序或删除。"))
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(18)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .background(Color.clear)
            .environment(\.editMode, $editMode)
            .navigationTitle(L10n.lookup("选择助手"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("关闭助手选择"))
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(editMode == .active ? L10n.lookup("完成") : L10n.lookup("编辑")) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            editMode = editMode == .active ? .inactive : .active
                        }
                    }
                    Button {
                        editingAssistant = AssistantProfile(name: L10n.lookup("新助手"), temperature: 0.6)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.lookup("新建助手"))
                }
            }
        }
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .sheet(item: $editingAssistant) { assistant in
            AssistantEditorView(profile: assistant) { saved in
                model.upsertAssistant(saved)
            }
        }
        .alert(L10n.lookup("删除助手"), isPresented: deleteBinding) {
            Button(L10n.lookup("取消"), role: .cancel) {
                assistantToDelete = nil
            }
            Button(L10n.lookup("删除"), role: .destructive) {
                if let assistantToDelete {
                    model.deleteAssistant(assistantToDelete.id)
                }
                assistantToDelete = nil
            }
        } message: {
            if let assistantToDelete {
                Text(L10n.format("删除助手“%@”？属于它的聊天也会一起删除。", [String(describing: assistantToDelete.name)]))
            }
        }
    }

    private func assistantRow(_ assistant: AssistantProfile) -> some View {
        let isSelected = assistant.id == model.currentAssistantID

        return HStack(spacing: 8) {
            Button {
                if editMode == .active {
                    editingAssistant = assistant
                } else {
                    model.selectAssistant(assistant.id)
                    dismiss()
                }
            } label: {
                AssistantSummaryRow(
                    assistant: assistant,
                    isCurrent: isSelected,
                    accessorySystemImage: isSelected ? "checkmark.circle.fill" : nil
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if editMode != .active {
                Button {
                    editingAssistant = assistant
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 42)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("编辑助手 %@", [String(describing: assistant.name)]))
            }
        }
        .frame(minHeight: 68)
        .contextMenu {
            Button {
                editingAssistant = assistant
            } label: {
                Label(L10n.lookup("编辑"), systemImage: "pencil")
            }

            Button(role: .destructive) {
                assistantToDelete = assistant
            } label: {
                Label(L10n.lookup("删除"), systemImage: "trash")
            }
            .disabled(model.assistants.count <= 1)
        }
    }

    private func deleteAssistants(at offsets: IndexSet) {
        guard let offset = offsets.first,
              model.assistants.indices.contains(offset)
        else { return }
        assistantToDelete = model.assistants[offset]
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { assistantToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    assistantToDelete = nil
                }
            }
        )
    }
}

struct AssistantSummaryRow: View {
    @Environment(AppModel.self) private var model

    let assistant: AssistantProfile
    let isCurrent: Bool
    var accessorySystemImage: String?

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    private var promptPreview: String {
        assistant.trimmedSystemPrompt?
            .components(separatedBy: .newlines).first ?? L10n.lookup("暂无系统提示词")
    }

    var body: some View {
        HStack(spacing: 12) {
            AssistantAvatarView(profile: assistant, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(assistant.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isCurrent {
                        Text(L10n.lookup("当前"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(themeAccent.opacity(0.12)))
                    }
                }
                Text(promptPreview)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let accessorySystemImage {
                Image(systemName: accessorySystemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        accessorySystemImage == "checkmark.circle.fill"
                            ? themeAccent
                            : Color.secondary.opacity(0.55)
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

enum AssistantEditorPresentationContext: Equatable {
    case sheet
    case navigation
}

private enum AssistantEditorTab: String, CaseIterable, Identifiable {
    case basic
    case prompt
    case files
    case memory
    case quickPhrases
    case tools
    case mcp
    case calendar

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .basic: L10n.lookup("基础设置")
        case .prompt: L10n.lookup("提示词")
        case .files: L10n.lookup("文件")
        case .memory: L10n.lookup("记忆")
        case .tools: L10n.lookup("工具")
        case .mcp: "MCP"
        case .calendar: L10n.lookup("日历")
        case .quickPhrases: L10n.lookup("快捷短语")
        }
    }
}

private enum AssistantBasicDetail: String, Identifiable {
    case temperature
    case topP
    case context
    case thinking
    case maxTokens

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .temperature: L10n.lookup("温度")
        case .topP: "Top P"
        case .context: L10n.lookup("上下文消息数量")
        case .thinking: L10n.lookup("思考预算")
        case .maxTokens: L10n.lookup("最大 Token 数")
        }
    }
}

struct AssistantEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile: AssistantProfile
    @State private var avatarText: String
    @State private var temperatureEnabled: Bool
    @State private var temperatureValue: Double
    @State private var topPEnabled: Bool
    @State private var topPValue: Double
    @State private var thinkingEnabled: Bool
    @State private var thinkingBudgetValue: Int
    @State private var maxTokensEnabled: Bool
    @State private var maxTokensValue: Int
    @State private var avatarSelection: PhotosPickerItem?
    @State private var backgroundSelection: PhotosPickerItem?
    @State private var backgroundSelectionTask: Task<Void, Never>?
    @State private var backgroundSelectionSequence: UInt64 = 0
    @State private var pendingBackgroundCrop: BackgroundCropRequest?
    @State private var showBackgroundImportError = false
    @State private var didSave = false
    @State private var editorIsActive = true
    @State private var selectedTab: AssistantEditorTab = .basic
    @State private var activeBasicDetail: AssistantBasicDetail?
    @State private var isChatModelSelectorPresented = false
    @State private var isImageModelSelectorPresented = false
    @State private var persistedProfileBaseline: AssistantProfile
    @State private var unsavedChangesAlertPresented = false

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    private let originalProfile: AssistantProfile
    private let originalAvatar: String?
    private let originalBackground: String?
    private let presentationContext: AssistantEditorPresentationContext
    let onSave: (AssistantProfile) -> Void

    init(
        profile: AssistantProfile,
        presentationContext: AssistantEditorPresentationContext = .sheet,
        onSave: @escaping (AssistantProfile) -> Void
    ) {
        _profile = State(initialValue: profile)
        _avatarText = State(initialValue: profile.emojiAvatar ?? "")
        _temperatureEnabled = State(initialValue: profile.temperature != nil)
        _temperatureValue = State(initialValue: profile.temperature ?? 0.6)
        _topPEnabled = State(initialValue: profile.topP != nil)
        _topPValue = State(initialValue: profile.topP ?? 0.9)
        let budget = profile.thinkingBudget ?? 0
        _thinkingEnabled = State(initialValue: budget != 0)
        _thinkingBudgetValue = State(initialValue: profile.thinkingBudget == nil ? 4096 : budget)
        _maxTokensEnabled = State(initialValue: (profile.maxTokens ?? 0) > 0)
        _maxTokensValue = State(initialValue: profile.maxTokens ?? 4096)
        _persistedProfileBaseline = State(initialValue: profile)
        originalProfile = profile
        originalAvatar = profile.avatar
        originalBackground = profile.background
        self.presentationContext = presentationContext
        self.onSave = onSave
    }

    var body: some View {
        Group {
            if presentationContext == .sheet {
                NavigationStack {
                    editorContent
                }
            } else {
                editorContent
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            tabBar
            selectedTabContent
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.lookup("助手") : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(presentationContext == .navigation)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: requestDismissal) {
                    if presentationContext == .sheet {
                        Text(L10n.lookup("取消"))
                    } else {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(presentationContext == .sheet ? L10n.lookup("取消") : L10n.lookup("返回"))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    HStack(spacing: 5) {
                        if hasUnsavedChanges {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        }
                        Text(L10n.lookup("保存"))
                    }
                }
                    .foregroundStyle(.primary)
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(item: $activeBasicDetail) { detail in
            AssistantBasicDetailSheet(
                detail: detail,
                temperatureEnabled: $temperatureEnabled,
                temperatureValue: $temperatureValue,
                topPEnabled: $topPEnabled,
                topPValue: $topPValue,
                limitContextMessages: $profile.limitContextMessages,
                contextMessageSize: $profile.contextMessageSize,
                thinkingEnabled: $thinkingEnabled,
                thinkingBudgetValue: $thinkingBudgetValue,
                maxTokensEnabled: $maxTokensEnabled,
                maxTokensValue: $maxTokensValue
            )
        }
        .sheet(isPresented: $isChatModelSelectorPresented) {
            ModelSelectorView(
                context: .sheet,
                selectedSelection: profile.chatModel,
                inheritedChoiceTitle: L10n.lookup("跟随全局默认模型"),
                screenTitle: L10n.lookup("聊天模型"),
                chatOnly: true,
                onSelect: { selection in
                    profile.chatModel = selection
                }
            )
        }
        .sheet(isPresented: $isImageModelSelectorPresented) {
            AssistantImageGenerationPicker(
                selectedProviderID: profile.imageGenerationProviderID,
                selectedModelID: profile.imageGenerationModelID
            ) { providerID, modelID in
                profile.imageGenerationProviderID = providerID
                profile.imageGenerationModelID = modelID
                profile.imageGenerationEnabled = providerID != nil
                    && !(modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }
        .sheet(item: $pendingBackgroundCrop) { request in
            BackgroundImageCropEditor(image: request.image, destination: .assistant(profile.id)) { image in
                await saveCroppedBackground(image, requestID: request.id)
            }
        }
        .alert(L10n.lookup("无法读取图片"), isPresented: $showBackgroundImportError) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("请选择其他图片或重试，原背景保持不变。"))
        }
        .onChange(of: avatarSelection) { _, item in
            guard let item else { return }
            avatarSelection = nil
            Task { @MainActor in
                guard let data = try? await item.loadTransferable(type: Data.self),
                      editorIsActive,
                      let image = UIImage(data: data),
                      let reference = AssistantMediaStore.saveAvatar(image, assistantID: profile.id)
                else { return }
                if profile.avatar != originalAvatar {
                    AssistantMediaStore.remove(profile.avatar)
                }
                profile.avatar = reference
                avatarText = ""
            }
        }
        .onChange(of: backgroundSelection) { _, item in
            guard let item else { return }
            backgroundSelection = nil
            cancelPendingBackgroundSelection()
            let sequence = backgroundSelectionSequence
            backgroundSelectionTask = Task { @MainActor in
                defer {
                    if sequence == backgroundSelectionSequence { backgroundSelectionTask = nil }
                }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = await BackgroundCropImageIO.prepare(data) else {
                    if !Task.isCancelled, editorIsActive, sequence == backgroundSelectionSequence {
                        showBackgroundImportError = true
                    }
                    return
                }
                guard !Task.isCancelled, editorIsActive,
                      sequence == backgroundSelectionSequence else { return }
                pendingBackgroundCrop = BackgroundCropRequest(image: image)
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .alert(L10n.lookup("有修改尚未保存"), isPresented: $unsavedChangesAlertPresented) {
            if !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(L10n.lookup("保存")) { save() }
            }
            Button(L10n.lookup("不保存"), role: .destructive) { discardChangesAndDismiss() }
        } message: {
            Text(L10n.lookup("提示词、记忆设置、工具开关或其他修改还没有保存。要先保存再离开吗？"))
        }
        .onAppear { editorIsActive = true }
        .onDisappear {
            editorIsActive = false
            cancelPendingBackgroundSelection()
            if !didSave {
                cleanupTemporaryMedia()
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AssistantEditorTab.allCases) { tab in
                    Button {
                        model.performCardHaptic()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(L10n.lookup(tab.title))
                            .font(.system(size: 15, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundStyle(selectedTab == tab ? themeAccent : .secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? themeAccent.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 9)
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.45)
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .basic:
            basicSettings
        case .prompt:
            AssistantPromptSettingsView(profile: $profile)
        case .files:
            if model.assistants.contains(where: { $0.id == profile.id }) {
                AssistantFilesSettingsView(assistantID: profile.id)
            } else {
                ContentUnavailableView(
                    L10n.lookup("先保存助手"),
                    systemImage: "doc.text",
                    description: Text(L10n.lookup("保存新助手后，再次打开即可添加它的 Markdown 文件。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        case .memory:
            AssistantMemorySettingsView(
                profile: $profile,
                onPersistedProfileChange: synchronizePersistedMemoryState
            )
        case .tools:
            AssistantLocalToolsView(profile: $profile)
        case .mcp:
            AssistantMCPServersView(profile: $profile)
        case .calendar:
            AssistantCalendarPage()
        case .quickPhrases:
            if model.assistants.contains(where: { $0.id == profile.id }) {
                AssistantQuickPhraseManagementView(assistantID: profile.id)
            } else {
                ContentUnavailableView(
                    L10n.lookup("先保存助手"),
                    systemImage: "bolt",
                    description: Text(L10n.lookup("保存新助手后，再次打开即可添加它的专用快捷短语。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
    }

    private var basicSettings: some View {
        let actionColor = Color(uiColor: model.themeActionUIColor)
        return Form {
            Section(L10n.lookup("基本信息")) {
                HStack(spacing: 16) {
                    AssistantAvatarView(profile: previewProfile, size: 72)
                    VStack(spacing: 10) {
                        TextField(L10n.lookup("助手名称"), text: $profile.name)
                            .font(.system(size: 18, weight: .medium))
                        TextField(L10n.lookup("头像（填一个 emoji）"), text: $avatarText)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)

                let avatarPickerTitle = L10n.lookup("选择头像图片")
                PhotosPicker(selection: $avatarSelection, matching: .images) {
                    AssistantEditorIconLabel(
                        title: avatarPickerTitle,
                        systemImage: "photo",
                        color: actionColor
                    )
                }
                if profile.avatar != nil || !avatarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(role: .destructive) {
                        if profile.avatar != originalAvatar {
                            AssistantMediaStore.remove(profile.avatar)
                        }
                        profile.avatar = nil
                        avatarText = ""
                    } label: {
                        AssistantEditorIconLabel(title: L10n.lookup("清除头像"), systemImage: "trash")
                    }
                }
            }

            Section(L10n.lookup("模型与生成")) {
                Button {
                    isChatModelSelectorPresented = true
                } label: {
                    AssistantEditorValueRow(
                        title: L10n.lookup("聊天模型"),
                        value: chatModelSummary,
                        systemImage: "bubble.left"
                    )
                }
                .buttonStyle(.plain)

                detailButton(
                    .temperature,
                    title: L10n.lookup("温度"),
                    value: temperatureEnabled ? String(format: "%.2f", temperatureValue) : L10n.lookup("已关闭（使用默认）"),
                    systemImage: "thermometer.medium"
                )
                detailButton(
                    .topP,
                    title: "Top P",
                    value: topPEnabled ? String(format: "%.2f", topPValue) : L10n.lookup("已关闭（使用默认）"),
                    systemImage: "wand.and.stars"
                )
                detailButton(
                    .context,
                    title: L10n.lookup("上下文消息数量"),
                    value: profile.limitContextMessages ? L10n.format("%@ 条", [String(describing: profile.contextMessageSize)]) : L10n.lookup("已关闭（无限制）"),
                    systemImage: "bubble.left.and.text.bubble.right"
                )
                detailButton(
                    .thinking,
                    title: L10n.lookup("思考预算"),
                    value: thinkingSummary,
                    systemImage: "brain.head.profile"
                )
                detailButton(
                    .maxTokens,
                    title: L10n.lookup("最大 Token 数"),
                    value: maxTokensEnabled ? "\(maxTokensValue)" : L10n.lookup("已关闭（使用默认）"),
                    systemImage: "number"
                )
            }

            Section(L10n.lookup("显示与输出")) {
                Toggle(isOn: $profile.useAssistantAvatar) {
                    AssistantEditorIconLabel(title: L10n.lookup("使用助手头像"), systemImage: "person.crop.circle")
                }
                Toggle(isOn: $profile.useAssistantName) {
                    AssistantEditorIconLabel(title: L10n.lookup("使用助手名字"), systemImage: "textformat")
                }
                Toggle(isOn: $profile.streamOutput) {
                    AssistantEditorIconLabel(title: L10n.lookup("流式输出"), systemImage: "bolt")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { profile.imageGenerationEnabled },
                    set: { enabled in
                        let isConfigured = profile.imageGenerationProviderID != nil
                            && profile.imageGenerationModelID?
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        if enabled, !isConfigured {
                            isImageModelSelectorPresented = true
                        }
                        profile.imageGenerationEnabled = enabled && isConfigured
                    }
                )) {
                    AssistantEditorIconLabel(title: L10n.lookup("图像生成"), systemImage: "photo.badge.plus")
                }
                Button {
                    isImageModelSelectorPresented = true
                } label: {
                    AssistantEditorValueRow(
                        title: L10n.lookup("图像生成模型"),
                        value: imageGenerationModelSummary,
                        systemImage: "sparkles"
                    )
                }
                .buttonStyle(.plain)
            } header: {
                Text(L10n.lookup("图像生成"))
            } footer: {
                Text(L10n.lookup("开启后，助手会调用单独选择的图像供应商与模型；图片会直接显示在助手消息里。"))
            }

            Section {
                let backgroundReference = profile.background
                let hasBackground = backgroundReference != nil
                if let image = AssistantMediaStore.image(for: backgroundReference) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                let backgroundPickerTitle = hasBackground ? L10n.lookup("更换背景图片") : L10n.lookup("选择背景图片")
                PhotosPicker(selection: $backgroundSelection, matching: .images) {
                    AssistantEditorIconLabel(
                        title: backgroundPickerTitle,
                        systemImage: "photo.on.rectangle",
                        color: actionColor
                    )
                }
                if backgroundSelectionTask != nil {
                    ProgressView(L10n.lookup("正在读取图片…"))
                }
                if hasBackground {
                    Button(role: .destructive) {
                        cancelPendingBackgroundSelection()
                        if profile.background != originalBackground {
                            AssistantMediaStore.remove(profile.background)
                        }
                        profile.background = nil
                    } label: {
                        AssistantEditorIconLabel(title: L10n.lookup("清除背景图片"), systemImage: "trash")
                    }
                }
            } header: {
                Text(L10n.lookup("聊天背景"))
            } footer: {
                Text(L10n.lookup("只在这个助手的聊天页面显示，并覆盖默认纯色背景。"))
            }
        }
        .settingsGroupedPageStyle()
    }

    private func detailButton(
        _ detail: AssistantBasicDetail,
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        Button {
            activeBasicDetail = detail
        } label: {
            AssistantEditorValueRow(title: title, value: value, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private var previewProfile: AssistantProfile {
        var preview = profile
        let avatar = avatarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !avatar.isEmpty {
            preview.avatar = avatar
        }
        return preview
    }

    private var thinkingSummary: String {
        guard thinkingEnabled else { return L10n.lookup("已关闭") }
        return thinkingBudgetValue < 0 ? L10n.lookup("自动") : "\(thinkingBudgetValue) tokens"
    }

    private var chatModelSummary: String {
        guard let selection = profile.chatModel else {
            return L10n.lookup("跟随全局默认模型")
        }
        guard let provider = model.providers.first(where: {
            $0.id == selection.providerID && $0.enabled
        }), let configuration = provider.models.first(where: {
            $0.id == selection.modelID
        }) else {
            return L10n.format("模型不可用，实际跟随 %@", [String(describing: (model.selectedModelConfiguration?.displayName ?? L10n.lookup("选择模型")))])
        }
        return "\(provider.name) · \(configuration.displayName)"
    }

    private var imageGenerationModelSummary: String {
        guard let providerID = profile.imageGenerationProviderID,
              let modelID = profile.imageGenerationModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else { return L10n.lookup("选择模型") }
        let providerName = model.providers.first(where: { $0.id == providerID })?.name ?? L10n.lookup("供应商")
        return "\(providerName) · \(modelID)"
    }

    private var hasUnsavedChanges: Bool {
        var draft = profile
        let cleanedAvatar = avatarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedAvatar.isEmpty {
            draft.avatar = cleanedAvatar
        }
        draft.temperature = temperatureEnabled ? temperatureValue : nil
        draft.topP = topPEnabled ? topPValue : nil
        draft.thinkingBudget = thinkingEnabled
            ? thinkingBudgetValue
            : (originalProfile.thinkingBudget == 0 && thinkingBudgetValue == 0 ? 0 : nil)
        draft.maxTokens = maxTokensEnabled
            ? maxTokensValue
            : (originalProfile.maxTokens == 0 && maxTokensValue == 0 ? 0 : nil)
        return draft != persistedProfileBaseline
    }

    private func synchronizePersistedMemoryState(
        _ persisted: AssistantProfile
    ) {
        profile.enableMemory = persisted.enableMemory
        profile.memories = persisted.memories
        profile.recentContextSummaryInstruction =
            persisted.recentContextSummaryInstruction
        persistedProfileBaseline.enableMemory = persisted.enableMemory
        persistedProfileBaseline.memories = persisted.memories
        persistedProfileBaseline.recentContextSummaryInstruction =
            persisted.recentContextSummaryInstruction
    }

    private func cancelPendingBackgroundSelection() {
        backgroundSelectionSequence &+= 1
        backgroundSelectionTask?.cancel()
        backgroundSelectionTask = nil
        pendingBackgroundCrop = nil
    }

    private func saveCroppedBackground(_ image: UIImage, requestID: UUID) async -> Bool {
        guard editorIsActive, pendingBackgroundCrop?.id == requestID else { return false }
        let ownerID = profile.id
        guard let reference = await BackgroundCropImageIO.save(image, destination: .assistant(ownerID)) else { return false }
        guard editorIsActive, profile.id == ownerID, pendingBackgroundCrop?.id == requestID else {
            AssistantMediaStore.remove(reference)
            return false
        }
        if profile.background != originalBackground { AssistantMediaStore.remove(profile.background) }
        profile.background = reference
        return true
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAvatar = avatarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedAvatar.isEmpty {
            if profile.avatar != originalAvatar {
                AssistantMediaStore.remove(profile.avatar)
            }
            profile.avatar = cleanedAvatar
        }
        profile.temperature = temperatureEnabled ? temperatureValue : nil
        profile.topP = topPEnabled ? topPValue : nil
        profile.thinkingBudget = thinkingEnabled
            ? thinkingBudgetValue
            : (originalProfile.thinkingBudget == 0 && thinkingBudgetValue == 0 ? 0 : nil)
        profile.maxTokens = maxTokensEnabled
            ? maxTokensValue
            : (originalProfile.maxTokens == 0 && maxTokensValue == 0 ? 0 : nil)
        profile.schemaVersion = AssistantProfile.currentSchemaVersion
        if profile.background != originalBackground {
            AssistantMediaStore.remove(originalBackground)
        }
        if profile.avatar != originalAvatar {
            AssistantMediaStore.remove(originalAvatar)
        }
        didSave = true
        onSave(profile)
        dismiss()
    }

    private func requestDismissal() {
        guard hasUnsavedChanges else {
            discardChangesAndDismiss()
            return
        }
        unsavedChangesAlertPresented = true
    }

    private func discardChangesAndDismiss() {
        cleanupTemporaryMedia()
        didSave = true
        dismiss()
    }

    private func cleanupTemporaryMedia() {
        if profile.avatar != originalAvatar {
            AssistantMediaStore.remove(profile.avatar)
        }
        if profile.background != originalBackground {
            AssistantMediaStore.remove(profile.background)
        }
    }
}

private struct AssistantCalendarEditorRoute: Identifiable {
    let id = UUID()
    let event: MoccaCalendarEvent?
    let date: Date
}

private struct AssistantCalendarPage: View {
    @Environment(AppModel.self) private var model
    @State private var fullCalendarPresented = false
    @State private var editorRoute: AssistantCalendarEditorRoute?
    @State private var restoreConfirmationPresented = false

    private var accent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: assistantAccessBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        AssistantEditorIconLabel(
                            title: L10n.lookup("允许助手使用共享日历"),
                            systemImage: "calendar.badge.clock"
                        )
                        Text(model.calendarSettings.assistantAccessEnabled ? L10n.lookup("已开启") : L10n.lookup("默认关闭"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.lookup("助手访问"))
            } footer: {
                Text(model.calendarSettings.assistantAccessEnabled
                     ? L10n.lookup("助手可以读取临近事项，并在你明确要求后增删改日历；写入操作仍会显示确认。此开关目前对全部助手生效。")
                     : L10n.lookup("关闭时不会向模型发送日历提示词、工具或日历内容，手动使用共享日历不受影响。"))
            }

            Section(L10n.lookup("共享日历")) {
                Button {
                    fullCalendarPresented = true
                } label: {
                    AssistantEditorValueRow(
                        title: L10n.lookup("打开完整日历"),
                        value: L10n.format("%@ 项", [String(describing: model.calendarEvents.count)]),
                        systemImage: "calendar"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    editorRoute = AssistantCalendarEditorRoute(
                        event: nil,
                        date: Calendar.current.startOfDay(for: .now)
                    )
                } label: {
                    AssistantEditorIconLabel(
                        title: L10n.lookup("添加日历事项"),
                        systemImage: "calendar.badge.plus"
                    )
                }
                .buttonStyle(.plain)
            }

            Section {
                if upcomingOccurrences.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.lookup("暂时没有临近事项"))
                                .fontWeight(.medium)
                            Text(L10n.lookup("添加后会在这里显示最近 5 项"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(upcomingOccurrences) { occurrence in
                        Button {
                            editorRoute = AssistantCalendarEditorRoute(
                                event: occurrence.event,
                                date: occurrence.date
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: occurrence.event.kind.systemImage)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(accent)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(occurrence.event.title)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(Self.dateText(occurrence.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(L10n.lookup("即将到来"))
            } footer: {
                if !upcomingOccurrences.isEmpty {
                    Text(L10n.lookup("这里显示未来一年内最近的 5 项；完整月份和更远事项可在共享日历中查看。"))
                }
            }

            Section {
                HStack(spacing: 12) {
                    AssistantEditorIconLabel(title: L10n.lookup("默认节日"), systemImage: "sparkles")
                    Spacer(minLength: 8)
                    Text(L10n.format("%@ 个", [String(describing: builtInFestivalCount)]))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                Button(L10n.lookup("恢复缺少的默认节日")) {
                    restoreConfirmationPresented = true
                }
            } footer: {
                Text(L10n.lookup("恢复只补回缺少的默认节日，不会覆盖你编辑过的事项。"))
            }
        }
        .settingsGroupedPageStyle()
        .sheet(isPresented: $fullCalendarPresented) {
            MoccaCalendarView()
                .environment(model)
        }
        .sheet(item: $editorRoute) { route in
            MoccaCalendarEventEditorView(event: route.event, selectedDate: route.date)
                .environment(model)
        }
        .alert(L10n.lookup("恢复默认节日？"), isPresented: $restoreConfirmationPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("恢复")) { model.restoreDefaultCalendarFestivals() }
        } message: {
            Text(L10n.lookup("只补回被删除的默认节日，你编辑过的内容会保留。"))
        }
    }

    private var assistantAccessBinding: Binding<Bool> {
        Binding(
            get: { model.calendarSettings.assistantAccessEnabled },
            set: { enabled in
                model.updateCalendarSettings { $0.assistantAccessEnabled = enabled }
                model.performSwitchHaptic()
            }
        )
    }

    private var upcomingOccurrences: [MoccaCalendarOccurrence] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        return MoccaCalendarEngine.occurrences(
            of: model.calendarEvents.filter { $0.kind != .todo || !$0.isCompleted },
            in: DateInterval(start: start, end: end),
            calendar: calendar
        )
        .sorted { $0.date < $1.date }
        .prefix(5)
        .map { $0 }
    }

    private var builtInFestivalCount: Int {
        model.calendarEvents.filter(\.isBuiltIn).count
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = AppLocalization.shared.locale
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.component(.year, from: date)
            == Calendar.current.component(.year, from: .now)
            ? L10n.lookup("M月d日 EEEE")
            : L10n.lookup("yyyy年M月d日 EEEE")
        return formatter.string(from: date)
    }
}

private struct AssistantEditorIconLabel: View {
    let title: String
    let systemImage: String
    var color: Color = .primary

    var body: some View {
        HStack(spacing: 12) {
            AppSymbolImage(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 30)
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
        .contentShape(Rectangle())
    }
}

private struct AssistantEditorValueRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            AssistantEditorIconLabel(title: title, systemImage: systemImage)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct AssistantBasicDetailSheet: View {
    @Environment(AppModel.self) private var appModel
    let detail: AssistantBasicDetail
    @Binding var temperatureEnabled: Bool
    @Binding var temperatureValue: Double
    @Binding var topPEnabled: Bool
    @Binding var topPValue: Double
    @Binding var limitContextMessages: Bool
    @Binding var contextMessageSize: Int
    @Binding var thinkingEnabled: Bool
    @Binding var thinkingBudgetValue: Int
    @Binding var maxTokensEnabled: Bool
    @Binding var maxTokensValue: Int

    @State private var customInputText = ""
    @State private var isCustomInputPresented = false

    private static let thinkingBudgetStops = [1024, 2048, 4096, 8192, 16_384, 32_768]
    private static let maxTokenStops = [256, 512, 1024, 2048, 4096, 8192, 16_384, 32_768, 65_536, 131_072]

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    private var themeAction: Color {
        Color(uiColor: appModel.themeActionUIColor)
    }

    private var themeSwitch: Color {
        Color(uiColor: appModel.themeSwitchUIColor)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 48, height: 5)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 16) {
                    Text(detail.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .tint(themeSwitch)
                        .accessibilityLabel(toggleTitle)
                }

                if isEnabled {
                    parameterControl
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(disabledMessage)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                }

                Text(detailDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .animation(.easeInOut(duration: 0.18), value: isEnabled)
        }
        .tint(themeAction)
        .alert(customInputTitle, isPresented: $isCustomInputPresented) {
            TextField(customInputPlaceholder, text: $customInputText)
                .keyboardType(customInputKeyboardType)
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("保存")) {
                applyCustomInput()
            }
            .disabled(!isCustomInputValid)
        } message: {
            Text(customInputHelp)
        }
        .presentationDetents([.height(preferredHeight), .medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemBackground))
        .presentationContentInteraction(.scrolls)
    }

    private var isEnabled: Bool {
        switch detail {
        case .temperature: temperatureEnabled
        case .topP: topPEnabled
        case .context: limitContextMessages
        case .thinking: thinkingEnabled
        case .maxTokens: maxTokensEnabled
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                switch detail {
                case .temperature:
                    temperatureEnabled = newValue
                    if newValue { temperatureValue = min(max(temperatureValue, 0), 2) }
                case .topP:
                    topPEnabled = newValue
                    if newValue { topPValue = min(max(topPValue, 0), 1) }
                case .context:
                    limitContextMessages = newValue
                    if newValue { contextMessageSize = min(max(contextMessageSize, 1), 1024) }
                case .thinking:
                    thinkingEnabled = newValue
                    if newValue, thinkingBudgetValue == 0 { thinkingBudgetValue = 4096 }
                case .maxTokens:
                    maxTokensEnabled = newValue
                    if newValue, maxTokensValue <= 0 { maxTokensValue = 4096 }
                }
            }
        )
    }

    @ViewBuilder
    private var parameterControl: some View {
        switch detail {
        case .temperature:
            AssistantParameterSlider(
                value: temperatureSliderBinding,
                range: 0...2,
                step: 0.05,
                valueText: String(format: "%.2f", temperatureValue),
                marks: [
                    .init(value: 0, label: "0"),
                    .init(value: 0.5, label: "0.5"),
                    .init(value: 1, label: "1"),
                    .init(value: 1.5, label: "1.5"),
                    .init(value: 2, label: "2")
                ],
                onValueTap: beginCustomInput
            )
        case .topP:
            AssistantParameterSlider(
                value: topPSliderBinding,
                range: 0...1,
                step: 0.05,
                valueText: String(format: "%.2f", topPValue),
                marks: [
                    .init(value: 0, label: "0"),
                    .init(value: 0.25, label: "0.25"),
                    .init(value: 0.5, label: "0.5"),
                    .init(value: 0.75, label: "0.75"),
                    .init(value: 1, label: "1")
                ],
                onValueTap: beginCustomInput
            )
        case .context:
            AssistantParameterSlider(
                value: contextSliderBinding,
                range: 1...1024,
                step: 1,
                valueText: "\(contextMessageSize)",
                marks: [
                    .init(value: 1, label: "1"),
                    .init(value: 64, label: "64"),
                    .init(value: 128, label: "128"),
                    .init(value: 256, label: "256"),
                    .init(value: 512, label: "512"),
                    .init(value: 1024, label: "1024")
                ],
                onValueTap: beginCustomInput
            )
        case .thinking:
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.lookup("思考预算模式"), selection: thinkingModeBinding) {
                    ForEach(AssistantThinkingBudgetMode.allCases) { mode in
                        Text(L10n.lookup(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if thinkingModeBinding.wrappedValue == .automatic {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(themeAccent)
                        Text(L10n.lookup("由模型或服务商自动处理"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(themeAccent.opacity(0.09))
                    )
                } else {
                    AssistantParameterSlider(
                        value: thinkingSliderBinding,
                        range: 0...Double(Self.thinkingBudgetStops.count - 1),
                        step: 1,
                        valueText: formatInteger(thinkingBudgetValue),
                        marks: Self.thinkingBudgetStops.enumerated().map {
                            AssistantParameterSliderMark(value: Double($0.offset), label: compactTokenLabel($0.element))
                        },
                        onValueTap: beginCustomInput
                    )
                }
            }
        case .maxTokens:
            AssistantParameterSlider(
                value: maxTokensSliderBinding,
                range: 0...Double(Self.maxTokenStops.count - 1),
                step: 1,
                valueText: formatInteger(maxTokensValue),
                marks: [
                    .init(value: 0, label: "256"),
                    .init(value: 2, label: "1K"),
                    .init(value: 4, label: "4K"),
                    .init(value: 6, label: "16K"),
                    .init(value: 8, label: "64K"),
                    .init(value: 9, label: "131K")
                ],
                onValueTap: beginCustomInput
            )
        }
    }

    private var temperatureSliderBinding: Binding<Double> {
        Binding(
            get: { min(max(temperatureValue, 0), 2) },
            set: { temperatureValue = min(max($0, 0), 2) }
        )
    }

    private var topPSliderBinding: Binding<Double> {
        Binding(
            get: { min(max(topPValue, 0), 1) },
            set: { topPValue = min(max($0, 0), 1) }
        )
    }

    private var contextSliderBinding: Binding<Double> {
        Binding(
            get: { Double(min(max(contextMessageSize, 1), 1024)) },
            set: { contextMessageSize = min(max(Int($0.rounded()), 1), 1024) }
        )
    }

    private var thinkingModeBinding: Binding<AssistantThinkingBudgetMode> {
        Binding(
            get: { thinkingBudgetValue < 0 ? .automatic : .custom },
            set: { mode in
                switch mode {
                case .automatic:
                    thinkingBudgetValue = -1
                case .custom:
                    if thinkingBudgetValue < 1024 { thinkingBudgetValue = 4096 }
                }
            }
        )
    }

    private var thinkingSliderBinding: Binding<Double> {
        presetIndexBinding(
            value: $thinkingBudgetValue,
            stops: Self.thinkingBudgetStops,
            minimumCustomValue: 1024
        )
    }

    private var maxTokensSliderBinding: Binding<Double> {
        presetIndexBinding(
            value: $maxTokensValue,
            stops: Self.maxTokenStops,
            minimumCustomValue: 1
        )
    }

    private func presetIndexBinding(
        value: Binding<Int>,
        stops: [Int],
        minimumCustomValue: Int
    ) -> Binding<Double> {
        Binding(
            get: { Double(nearestStopIndex(to: max(minimumCustomValue, value.wrappedValue), in: stops)) },
            set: { rawIndex in
                let index = min(max(Int(rawIndex.rounded()), 0), stops.count - 1)
                value.wrappedValue = stops[index]
            }
        )
    }

    private func nearestStopIndex(to value: Int, in stops: [Int]) -> Int {
        stops.enumerated().min {
            abs($0.element - value) < abs($1.element - value)
        }?.offset ?? 0
    }

    private func beginCustomInput() {
        switch detail {
        case .temperature:
            customInputText = String(temperatureValue)
        case .topP:
            customInputText = String(topPValue)
        case .context:
            customInputText = "\(contextMessageSize)"
        case .thinking:
            customInputText = "\(thinkingBudgetValue < 1024 ? 4096 : thinkingBudgetValue)"
        case .maxTokens:
            customInputText = "\(maxTokensValue)"
        }
        isCustomInputPresented = true
    }

    private func applyCustomInput() {
        let cleaned = customInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch detail {
        case .temperature:
            if let value = Double(cleaned), value.isFinite, (0...2).contains(value) {
                temperatureValue = value
            }
        case .topP:
            if let value = Double(cleaned), value.isFinite, (0...1).contains(value) {
                topPValue = value
            }
        case .context:
            if let value = Int(cleaned), (1...1024).contains(value) {
                contextMessageSize = value
            }
        case .thinking:
            if let value = Int(cleaned), value >= 1024 {
                thinkingBudgetValue = value
            }
        case .maxTokens:
            if let value = Int(cleaned), value > 0 {
                maxTokensValue = value
            }
        }
    }

    private var isCustomInputValid: Bool {
        let cleaned = customInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch detail {
        case .temperature:
            guard let value = Double(cleaned), value.isFinite else { return false }
            return (0...2).contains(value)
        case .topP:
            guard let value = Double(cleaned), value.isFinite else { return false }
            return (0...1).contains(value)
        case .context:
            guard let value = Int(cleaned) else { return false }
            return (1...1024).contains(value)
        case .thinking:
            return (Int(cleaned) ?? 0) >= 1024
        case .maxTokens:
            return (Int(cleaned) ?? 0) > 0
        }
    }

    private var toggleTitle: String {
        switch detail {
        case .temperature: L10n.lookup("自定义温度")
        case .topP: L10n.lookup("自定义 Top P")
        case .context: L10n.lookup("限制上下文消息数量")
        case .thinking: L10n.lookup("开启思考")
        case .maxTokens: L10n.lookup("限制最大 Token 数")
        }
    }

    private var disabledMessage: String {
        switch detail {
        case .temperature, .topP: L10n.lookup("使用服务商或模型默认值")
        case .context: L10n.lookup("不按消息条数截断")
        case .thinking: L10n.lookup("不显式开启模型思考")
        case .maxTokens: L10n.lookup("由服务商决定输出上限")
        }
    }

    @MainActor private var detailDescription: String {
        switch detail {
        case .temperature:
            L10n.lookup("控制输出随机性；数值越高，回答通常越多样。")
        case .topP:
            L10n.lookup("控制 nucleus sampling；关闭时使用服务商或模型默认值。")
        case .context:
            L10n.lookup("多少条历史消息会作为上下文发送给模型；超过数量时只保留最近 N 条。")
        case .thinking:
            L10n.lookup("并非所有模型都支持思考预算；自动会交给支持动态预算的模型决定，其他服务商可能使用兼容默认值。")
        case .maxTokens:
            L10n.lookup("限制单次回答的最大输出 Token 数；点按右侧数值可以输入任意正整数。")
        }
    }

    private var customInputTitle: String { L10n.format("自定义%@", [String(describing: detail.title)]) }

    private var customInputPlaceholder: String {
        switch detail {
        case .temperature, .topP: L10n.lookup("输入数值")
        case .context, .thinking, .maxTokens: L10n.lookup("输入整数")
        }
    }

    private var customInputHelp: String {
        switch detail {
        case .temperature: L10n.lookup("请输入 0 到 2 之间的数值。")
        case .topP: L10n.lookup("请输入 0 到 1 之间的数值。")
        case .context: L10n.lookup("请输入 1 到 1024 之间的整数。")
        case .thinking: L10n.lookup("请输入不小于 1024 的整数；自动模式请在上一页选择。")
        case .maxTokens: L10n.lookup("请输入任意正整数。")
        }
    }

    private var customInputKeyboardType: UIKeyboardType {
        switch detail {
        case .temperature, .topP: .decimalPad
        case .context, .thinking, .maxTokens: .numberPad
        }
    }

    private var preferredHeight: CGFloat {
        switch detail {
        case .thinking: 390
        case .context, .maxTokens: 350
        case .temperature, .topP: 330
        }
    }

    private func formatInteger(_ value: Int) -> String {
        value.formatted()
    }

    private func compactTokenLabel(_ value: Int) -> String {
        guard value >= 1024 else { return "\(value)" }
        return "\(value / 1024)K"
    }
}

private enum AssistantThinkingBudgetMode: String, CaseIterable, Identifiable {
    case automatic
    case custom

    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .automatic: L10n.lookup("自动")
        case .custom: L10n.lookup("自定义")
        }
    }
}

private struct AssistantParameterSliderMark: Identifiable {
    let value: Double
    let label: String

    var id: String { "\(value)-\(label)" }
}

private struct AssistantParameterSlider: View {
    @Environment(AppModel.self) private var appModel
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    let marks: [AssistantParameterSliderMark]
    let onValueTap: () -> Void

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .controlSize(.large)
                    .tint(Color(uiColor: appModel.themeSliderUIColor))

                Button(action: onValueTap) {
                    Text(valueText)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 70, minHeight: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(themeAccent.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(themeAccent.opacity(0.22), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.lookup("自定义当前值"))
                .accessibilityValue(valueText)
            }

            GeometryReader { proxy in
                let span = max(range.upperBound - range.lowerBound, Double.leastNonzeroMagnitude)
                ZStack {
                    ForEach(marks) { mark in
                        let fraction = min(max((mark.value - range.lowerBound) / span, 0), 1)
                        let x = min(max(proxy.size.width * fraction, 13), proxy.size.width - 13)
                        Text(L10n.lookup(mark.label))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .position(x: x, y: 10)
                    }
                }
            }
            .frame(height: 22)
            .padding(.trailing, 82)
        }
    }
}

struct AssistantMCPServersView: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: AssistantProfile

    private var selectableServers: [MCPServerConfig] {
        model.mcpServers.filter { $0.enabled && !$0.tools.isEmpty }
    }

    var body: some View {
        List {
            Section {
                if selectableServers.isEmpty {
                    ContentUnavailableView(L10n.lookup("没有可用 MCP 服务器"), systemImage: "terminal", description: Text(L10n.lookup("先在设置的 MCP 页面添加并同步工具")))
                } else {
                    Button(L10n.lookup("全选")) {
                        profile.mcpServerIDs = selectableServers.map(\.id)
                    }
                    Button(L10n.lookup("清空"), role: .destructive) {
                        profile.mcpServerIDs = []
                    }
                }
            }

            Section(L10n.lookup("服务器")) {
                ForEach(selectableServers) { server in
                    let selected = profile.mcpServerIDs.contains(server.id)
                    Toggle(isOn: Binding(
                        get: { selected },
                        set: { newValue in
                            if newValue {
                                if !profile.mcpServerIDs.contains(server.id) {
                                    profile.mcpServerIDs.append(server.id)
                                }
                            } else {
                                profile.mcpServerIDs.removeAll { $0 == server.id }
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.normalizedName)
                            Text(L10n.format("%@/%@ 个工具", [String(describing: server.tools.filter(\.enabled).count), String(describing: server.tools.count)]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
    }
}

private struct AssistantPromptSettingsView: View {
    @Binding var profile: AssistantProfile
    @State private var isSystemPromptEditorPresented = false

    var body: some View {
        Form {
            Section {
                NativeMultilineTextEditor(
                    text: $profile.systemPrompt,
                    font: .system(size: 16)
                )
                    .frame(height: 210)

                Button {
                    isSystemPromptEditorPresented = true
                } label: {
                    Label(L10n.lookup("展开编辑"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } header: {
                Text(L10n.lookup("系统提示词"))
            } footer: {
                Text(L10n.lookup("每次对话都会作为 system prompt 发送给模型。"))
            }

            Section {
                Toggle(L10n.lookup("启用额外提示词"), isOn: $profile.extraPromptEnabled)
                NativeMultilineTextEditor(
                    text: $profile.extraPrompt,
                    font: .system(size: 16)
                )
                    .frame(minHeight: 120)
                    .disabled(!profile.extraPromptEnabled)
                    .opacity(profile.extraPromptEnabled ? 1 : 0.55)
            } header: {
                Text(L10n.lookup("额外提示词"))
            } footer: {
                Text(L10n.lookup("启用后追加在系统提示词末尾，适合临时风格或额外约束。"))
            }

            Section {
                TextField("{{ message }}", text: $profile.messageTemplate)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.lookup("消息模板"))
            } footer: {
                Text(L10n.lookup("支持 {{ message }}、{{ role }}、{{ date }}、{{ time }}。"))
            }

            Section {
                ForEach($profile.presetMessages) { $preset in
                    VStack(alignment: .leading, spacing: 7) {
                        Picker(L10n.lookup("身份"), selection: $preset.role) {
                            Text(L10n.lookup("用户")).tag("user")
                            Text(L10n.lookup("助手")).tag("assistant")
                        }
                        .pickerStyle(.segmented)
                        TextField(L10n.lookup("消息内容"), text: $preset.content, axis: .vertical)
                            .lineLimit(1...6)
                    }
                    .padding(.vertical, 3)
                }
                .onDelete { profile.presetMessages.remove(atOffsets: $0) }
                Button(L10n.lookup("添加预设消息"), systemImage: "plus") {
                    profile.presetMessages.append(PresetMessage())
                }
            } header: {
                Text(L10n.lookup("预设消息"))
            } footer: {
                Text(L10n.lookup("按顺序插在每次请求的对话最前面。"))
            }
        }
        .settingsGroupedPageStyle()
        .sheet(isPresented: $isSystemPromptEditorPresented) {
            ExpandedTextEditorSheet(
                title: L10n.lookup("系统提示词"),
                initialText: profile.systemPrompt,
                note: L10n.lookup("每次对话都会作为 system prompt 发送给模型。")
            ) { text in
                profile.systemPrompt = text
                return true
            }
        }
    }
}

private struct ExpandedTextEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var unsavedChangesAlertPresented = false
    private let originalText: String
    let title: String
    let note: String
    let confirmationTitle: String
    let onSave: (String) -> Bool

    init(
        title: String,
        initialText: String,
        note: String,
        confirmationTitle: String = L10n.lookup("完成"),
        onSave: @escaping (String) -> Bool
    ) {
        self.title = title
        self.note = note
        self.confirmationTitle = confirmationTitle
        originalText = initialText
        _draft = State(initialValue: initialText)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                NativeMultilineTextEditor(
                    text: $draft,
                    font: .system(size: 17)
                )
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(note)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.format("%@ 字", [String(describing: draft.count)]))
                        .fixedSize()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { requestDismissal() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmationTitle) {
                        saveAndDismiss()
                    }
                        .foregroundStyle(.primary)
                }
            }
        }
        .interactiveDismissDisabled(draft != originalText)
        .alert(L10n.lookup("这段文字还没有完成"), isPresented: $unsavedChangesAlertPresented) {
            Button(L10n.lookup("保存")) { saveAndDismiss() }
            Button(L10n.lookup("不保留修改"), role: .destructive) { dismiss() }
        } message: {
            Text(L10n.format("返回后，刚刚输入但尚未点“%@”的内容会丢失。", [String(describing: confirmationTitle)]))
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private func requestDismissal() {
        if draft == originalText {
            dismiss()
        } else {
            unsavedChangesAlertPresented = true
        }
    }

    private func saveAndDismiss() {
        if onSave(draft) {
            dismiss()
        }
    }
}

private struct AssistantMemorySettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: AssistantProfile
    let onPersistedProfileChange: (AssistantProfile) -> Void
    @State private var editingMemory: AssistantMemory?
    @State private var isRecentContextSummaryPresented = false

    private var isPersistedAssistant: Bool {
        model.assistants.contains { $0.id == profile.id }
    }

    private var liveRecentMemoryState: RecentMemoryState {
        isPersistedAssistant
            ? model.recentMemoryState(for: profile.id)
            : profile.recentMemoryState
    }

    private var resolvedRecentContextSummaryInstruction: String {
        let custom = profile.recentContextSummaryInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty
            ? AppModel.defaultRecentContextSummaryInstruction
            : custom
    }

    private var recentMemoryStatusTitle: String {
        guard profile.recentMemorySettings.isEnabled else { return L10n.lookup("已关闭") }
        if liveRecentMemoryState.pendingLegacySnapshot != nil {
            return L10n.lookup("旧版快照待确认")
        }
        if RecentMemoryOrganizerContract.requiresFullRegeneration(
            liveRecentMemoryState
        ) {
            return L10n.lookup("需要重新整理")
        }
        if liveRecentMemoryState.lastError?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false {
            return L10n.lookup("整理失败")
        }
        if liveRecentMemoryState.needsDeferredRegeneration {
            return liveRecentMemoryState.isDeferredRegenerationAcknowledged
                ? L10n.lookup("已确认")
                : L10n.lookup("待整理")
        }
        if liveRecentMemoryState.content
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveRecentMemoryState.updatedAt == nil
                ? L10n.lookup("等待首次整理")
                : L10n.lookup("暂无独立近期事实")
        }
        return L10n.lookup("已更新")
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $profile.enableMemory) {
                    AssistantEditorIconLabel(
                        title: L10n.lookup("启用长期记忆"),
                        systemImage: "brain.head.profile"
                    )
                }
            } footer: {
                Text(L10n.lookup("长期记忆用于保存称呼、偏好、长期项目等稳定信息；关闭不会删除已经保存的内容。"))
            }

            Section {
                NavigationLink {
                    AssistantRecentMemorySettingsView(profile: $profile)
                } label: {
                    HStack(spacing: 12) {
                        AssistantEditorIconLabel(
                            title: L10n.lookup("近期记忆"),
                            systemImage: "clock.arrow.circlepath"
                        )
                        Spacer(minLength: 8)
                        Text(recentMemoryStatusTitle)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                }
            } header: {
                Text(L10n.lookup("跨聊天连续性"))
            } footer: {
                Text(L10n.lookup("自动整理同一助手最近的聊天，形成会持续更新的近期背景；它与长期记忆分开保存。"))
            }

            Section {
                Button {
                    isRecentContextSummaryPresented = true
                } label: {
                    Label(L10n.lookup("从所选聊天创建长期记忆"), systemImage: "sparkles")
                }
                .disabled(
                    !isPersistedAssistant
                        || model.recentContextSummaryConversations(for: profile.id).isEmpty
                )
            } header: {
                Text(L10n.lookup("手动整理"))
            } footer: {
                if !isPersistedAssistant {
                    Text(L10n.lookup("请先保存这个助手，再从它的聊天中创建长期记忆。"))
                } else {
                    Text(L10n.lookup("这是一次性的手动快照：选择聊天、生成总结，再立即保存为一条长期记忆；不会替代会自动更新的近期记忆。"))
                }
            }

            Section {
                Button {
                    editingMemory = AssistantMemory()
                } label: {
                    Label(L10n.lookup("添加长期记忆"), systemImage: "plus")
                }

                if profile.memories.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.lookup("暂无长期记忆"))
                                .foregroundStyle(.primary)
                            Text(L10n.lookup("可以添加称呼、偏好、长期项目或需要持续记住的背景"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                } else {
                    ForEach(profile.memories) { memory in
                        Button {
                            editingMemory = memory
                        } label: {
                            Text(memory.content)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteMemories)
                }
            } header: {
                Text(L10n.lookup("长期记忆"))
            } footer: {
                if isPersistedAssistant {
                    Text(L10n.lookup("添加、编辑或删除后会立即保存，不需要再点页面右上角的“保存”。"))
                } else {
                    Text(L10n.lookup("新助手首次创建前，这里的内容会随页面右上角“保存”一起写入。"))
                }
            }
        }
        .settingsGroupedPageStyle()
        .sheet(item: $editingMemory) { memory in
            AssistantMemoryEditor(memory: memory, onSave: saveMemory)
        }
        .sheet(isPresented: $isRecentContextSummaryPresented) {
            AssistantRecentContextSummarySheet(
                assistantID: profile.id,
                initialInstruction: resolvedRecentContextSummaryInstruction,
                onInstructionSave: saveRecentContextSummaryInstruction,
                onSave: { content in
                    saveMemory(AssistantMemory(content: content))
                }
            )
        }
    }

    private func saveMemory(_ memory: AssistantMemory) -> Bool {
        guard isPersistedAssistant else {
            if let index = profile.memories.firstIndex(where: {
                $0.id == memory.id
            }) {
                profile.memories[index] = memory
            } else {
                profile.memories.append(memory)
            }
            profile.enableMemory = true
            return true
        }

        guard let persisted = model.upsertLongTermMemory(
            assistantID: profile.id,
            memory: memory
        ) else {
            model.presentError(L10n.lookup("长期记忆保存失败，请稍后重试。"))
            return false
        }
        applyPersistedMemoryState(persisted)
        return true
    }

    private func deleteMemories(at offsets: IndexSet) {
        let memoryIDs = Set(offsets.compactMap { offset in
            profile.memories.indices.contains(offset)
                ? profile.memories[offset].id
                : nil
        })
        guard !memoryIDs.isEmpty else { return }

        guard isPersistedAssistant else {
            profile.memories.remove(atOffsets: offsets)
            return
        }
        guard let persisted = model.deleteLongTermMemories(
            assistantID: profile.id,
            memoryIDs: memoryIDs
        ) else {
            model.presentError(L10n.lookup("长期记忆删除失败，请稍后重试。"))
            return
        }
        applyPersistedMemoryState(persisted)
    }

    private func saveRecentContextSummaryInstruction(
        _ instruction: String
    ) -> Bool {
        guard let persisted = model.saveRecentContextSummaryInstruction(
            assistantID: profile.id,
            instruction: instruction
        ) else {
            model.presentError(L10n.lookup("总结要求保存失败，请稍后重试。"))
            return false
        }
        applyPersistedMemoryState(persisted)
        return true
    }

    private func applyPersistedMemoryState(_ persisted: AssistantProfile) {
        profile.enableMemory = persisted.enableMemory
        profile.memories = persisted.memories
        profile.recentContextSummaryInstruction =
            persisted.recentContextSummaryInstruction
        onPersistedProfileChange(persisted)
    }
}

private struct AssistantRecentMemorySettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var profile: AssistantProfile

    @State private var isModelSelectorPresented = false
    @State private var isInstructionEditorPresented = false
    @State private var isContentEditorPresented = false
    @State private var isTokenBudgetExpanded = false
    @State private var isSourcesExpanded = false
    @State private var isClearConfirmationPresented = false
    @State private var isPendingStatusActionsPresented = false
    @State private var isCustomConversationLimitPresented = false
    @State private var customConversationLimitText = ""
    @State private var isCustomRecentDayCountPresented = false
    @State private var customRecentDayCountText = ""
    @State private var actionNotice: String?
    @State private var actionNoticeIsError = false

    private static let standardConversationLimits = [10, 20, 30, 50, 100]
    private static let standardRecentDayCounts = [3, 5, 10, 15, 30]
    private static let summaryMessageCounts = [2, 3, 5, 8, 10, 20]

    private var settings: RecentMemorySettings {
        profile.recentMemorySettings
    }

    private var isPersistedAssistant: Bool {
        model.assistants.contains { $0.id == profile.id }
    }

    private var hasUnsavedRecentMemorySettings: Bool {
        guard let persistedProfile = model.assistants.first(where: { $0.id == profile.id }) else {
            return false
        }
        return persistedProfile.recentMemorySettings != profile.recentMemorySettings
            || persistedProfile.recentChatsSummaryMessageCount
                != profile.recentChatsSummaryMessageCount
    }

    private var liveState: RecentMemoryState {
        isPersistedAssistant
            ? model.recentMemoryState(for: profile.id)
            : profile.recentMemoryState
    }

    private var isRefreshing: Bool {
        isPersistedAssistant && model.isRecentMemoryRefreshing(for: profile.id)
    }

    private var canRefresh: Bool {
        isPersistedAssistant && settings.isEnabled && !isRefreshing
    }

    private var candidateConversationOptions: [Int] {
        let current = settings.candidateConversationLimit
        guard !Self.standardConversationLimits.contains(current) else {
            return Self.standardConversationLimits
        }
        return (Self.standardConversationLimits + [current]).sorted()
    }

    private var customConversationLimitValue: Int? {
        guard let value = Int(customConversationLimitText),
              (5...100).contains(value) else { return nil }
        return value
    }

    private var candidateRecentDayOptions: [Int] {
        let current = settings.candidateRecentDayCount
        guard !Self.standardRecentDayCounts.contains(current) else {
            return Self.standardRecentDayCounts
        }
        return (Self.standardRecentDayCounts + [current]).sorted()
    }

    private var customRecentDayCountValue: Int? {
        guard let value = Int(customRecentDayCountText),
              (1...30).contains(value) else { return nil }
        return value
    }

    private var longTermCandidates: [RecentMemoryEntry] {
        guard !RecentMemoryOrganizerContract.requiresFullRegeneration(liveState) else {
            return []
        }
        return activeMemoryEntries.filter(\.isLongTermCandidate)
    }

    private var activeMemoryEntries: [RecentMemoryEntry] {
        liveState.entries.filter {
            $0.expiresAt.map { $0 > Date.now } ?? true
        }
    }

    private var activeMemoryContent: String {
        guard !liveState.entries.isEmpty else { return liveState.content }
        return RecentMemoryContentMaterializer.materialize(
            entries: activeMemoryEntries,
            maxTokens: settings.memoryTokenLimit
        )
    }

    private var pendingLegacySnapshot: String? {
        guard let text = liveState.pendingLegacySnapshot?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: recentMemoryEnabledBinding) {
                    recentMemorySettingLabel(
                        title: L10n.lookup("启用近期记忆"),
                        subtitle: L10n.lookup("自动整理同一助手最近的聊天，并在新聊天中作为近期背景使用。"),
                        systemImage: "clock.arrow.circlepath"
                    )
                }

                if hasUnsavedRecentMemorySettings {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.lookup("近期记忆设置尚未保存"))
                                .font(.system(size: 15, weight: .medium))
                            Text(L10n.lookup("“立即整理”会使用本页当前设置；返回助手编辑页点右上角“保存”后，自动整理设置才会长期生效。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 3)
                }
            } footer: {
                Text(L10n.lookup("关闭只会停止自动整理与聊天注入；已经生成的近期记忆和已有长期记忆都会保留。"))
            }

            Section {
                recentMemoryStatusCard
            }

            Section {
                NavigationLink {
                    RecentMemoryGuideView()
                } label: {
                    AssistantEditorIconLabel(
                        title: L10n.lookup("近期记忆如何工作"),
                        systemImage: "info.circle"
                    )
                }
            }

            if let actionNotice {
                Section {
                    Label(actionNotice, systemImage: actionNoticeIsError
                          ? "exclamationmark.circle.fill"
                          : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(actionNoticeIsError ? Color.red : Color.secondary)
                }
            }

            if let pendingLegacySnapshot {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            L10n.lookup("这段文字来自旧版，无法可靠判断是你手写的，还是旧整理模型生成的。"),
                            systemImage: "shield.lefthalf.filled"
                        )
                        .font(.system(size: 15, weight: .medium))
                        Text(pendingLegacySnapshot)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)

                    Button {
                        confirmPendingLegacySnapshot()
                    } label: {
                        Label(L10n.lookup("确认保留为当前近期记忆"), systemImage: "checkmark.shield")
                    }
                    .disabled(!isPersistedAssistant || isRefreshing)

                    Button(role: .destructive) {
                        discardPendingLegacySnapshot()
                    } label: {
                        Label(L10n.lookup("丢弃旧版快照"), systemImage: "trash")
                    }
                    .disabled(!isPersistedAssistant || isRefreshing)
                } header: {
                    Text(L10n.lookup("旧版快照待确认"))
                } footer: {
                    Text(L10n.lookup("确认后会成为你亲自授权的文本记忆；丢弃只移除这份隔离副本。两种操作都不会改动聊天记录或长期记忆。"))
                }
            }

            Section {
                Picker(L10n.lookup("整理频率"), selection: cadenceBinding) {
                    ForEach(RecentMemoryCadence.allCases) { cadence in
                        Text(L10n.lookup(cadence.title)).tag(cadence)
                    }
                }
                .pickerStyle(.menu)

                Picker(L10n.lookup("来源范围"), selection: sourceSelectionModeBinding) {
                    ForEach(RecentMemorySourceSelectionMode.allCases) { mode in
                        Text(L10n.lookup(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch settings.sourceSelectionMode {
                case .conversationCount:
                    Picker(L10n.lookup("候选聊天"), selection: candidateConversationLimitBinding) {
                        ForEach(candidateConversationOptions, id: \.self) { count in
                            if Self.standardConversationLimits.contains(count) {
                                Text(L10n.format("最近 %@ 个", [String(describing: count)])).tag(count)
                            } else {
                                Text(L10n.format("自定义 · %@ 个", [String(describing: count)])).tag(count)
                            }
                        }
                    }
                    .pickerStyle(.menu)

                    Button {
                        customConversationLimitText =
                            "\(settings.candidateConversationLimit)"
                        isCustomConversationLimitPresented = true
                    } label: {
                        AssistantEditorValueRow(
                            title: L10n.lookup("自定义候选数量"),
                            value: "5–100",
                            systemImage: "number"
                        )
                    }
                    .buttonStyle(.plain)
                case .recentDays:
                    Picker(L10n.lookup("最近天数"), selection: candidateRecentDayCountBinding) {
                        ForEach(candidateRecentDayOptions, id: \.self) { days in
                            if Self.standardRecentDayCounts.contains(days) {
                                Text(L10n.format("最近 %@ 天", [String(describing: days)])).tag(days)
                            } else {
                                Text(L10n.format("自定义 · %@ 天", [String(describing: days)])).tag(days)
                            }
                        }
                    }
                    .pickerStyle(.menu)

                    Button {
                        customRecentDayCountText =
                            "\(settings.candidateRecentDayCount)"
                        isCustomRecentDayCountPresented = true
                    } label: {
                        AssistantEditorValueRow(
                            title: L10n.lookup("自定义天数"),
                            value: L10n.lookup("1–30 天"),
                            systemImage: "calendar.badge.clock"
                        )
                    }
                    .buttonStyle(.plain)
                }

                Toggle(isOn: automaticConversationSummaryBinding) {
                    recentMemorySettingLabel(
                        title: L10n.lookup("自动维护窗口摘要"),
                        subtitle: L10n.lookup("可选功能，会额外调用模型；默认关闭。"),
                        systemImage: "text.document"
                    )
                }

                if settings.isAutomaticConversationSummaryEnabled {
                    Picker(
                        L10n.lookup("窗口摘要频率"),
                        selection: $profile.recentChatsSummaryMessageCount
                    ) {
                        ForEach(Self.summaryMessageCounts, id: \.self) { count in
                            Text(L10n.format("每 %@ 条消息", [String(describing: count)])).tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle(isOn: pauseBinding) {
                    recentMemorySettingLabel(
                        title: L10n.lookup("暂停自动整理"),
                        subtitle: L10n.lookup("保留并继续使用当前近期记忆；仍可手动整理。"),
                        systemImage: "pause.circle"
                    )
                }

                Button {
                    isModelSelectorPresented = true
                } label: {
                    AssistantEditorValueRow(
                        title: L10n.lookup("整理模型"),
                        value: organizerModelTitle,
                        systemImage: "cpu"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    isInstructionEditorPresented = true
                } label: {
                    AssistantEditorValueRow(
                        title: L10n.lookup("自定义要求"),
                        value: compactPreview(settings.customInstruction, empty: L10n.lookup("使用默认要求")),
                        systemImage: "text.alignleft"
                    )
                }
                .buttonStyle(.plain)
            } header: {
                Text(L10n.lookup("自动整理"))
            } footer: {
                Text(L10n.lookup("更改这些设置不会立即调用模型；新设置会在下次手动整理或原定自动时间生效。"))
            }
            .disabled(!settings.isEnabled)

            Section {
                Picker(L10n.lookup("预算方案"), selection: budgetPresetBinding) {
                    ForEach(RecentMemoryBudgetPreset.allCases) { preset in
                        Text(L10n.lookup(preset.title)).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                DisclosureGroup(L10n.lookup("Token 上限"), isExpanded: $isTokenBudgetExpanded) {
                    tokenStepper(
                        title: L10n.lookup("单个聊天证据／摘要"),
                        value: settings.conversationSummaryTokenLimit,
                        binding: tokenBinding(
                            \.conversationSummaryTokenLimit,
                            range: 100...800
                        ),
                        range: 100...800,
                        step: 100
                    )
                    tokenStepper(
                        title: L10n.lookup("近期记忆"),
                        value: settings.memoryTokenLimit,
                        binding: tokenBinding(
                            \.memoryTokenLimit,
                            range: 300...6_000
                        ),
                        range: 300...6_000,
                        step: 100
                    )
                    tokenStepper(
                        title: L10n.lookup("整理输入"),
                        value: settings.organizerInputTokenLimit,
                        binding: tokenBinding(
                            \.organizerInputTokenLimit,
                            range: 2_000...96_000
                        ),
                        range: 2_000...96_000,
                        step: 1_000
                    )
                    tokenStepper(
                        title: L10n.lookup("稳定背景去重参考"),
                        value: settings.retrievedHistoryTokenLimit,
                        binding: tokenBinding(
                            \.retrievedHistoryTokenLimit,
                            range: 0...8_000
                        ),
                        range: 0...8_000,
                        step: 100
                    )
                }
            } header: {
                Text(L10n.lookup("Token 预算"))
            } footer: {
                Text(L10n.lookup("“整理输入”越高，一次能读取的完整聊天证据越多；长期记忆会独立完整注入，不占近期记忆上限。"))
            }
            .disabled(!settings.isEnabled)

            Section {
                if activeMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                RecentMemoryOrganizerContract
                                    .requiresFullRegeneration(liveState)
                                    ? L10n.lookup("需要重新整理")
                                    : liveState.needsDeferredRegeneration
                                    ? L10n.lookup("近期记忆待整理")
                                    : liveState.updatedAt == nil
                                    ? L10n.lookup("还没有近期记忆")
                                    : L10n.lookup("当前没有独立的近期事实")
                            )
                                .foregroundStyle(.primary)
                            Text(
                                !isPersistedAssistant
                                    ? L10n.lookup("先保存助手，再进行首次整理。")
                                    : RecentMemoryOrganizerContract
                                        .requiresFullRegeneration(liveState)
                                        ? L10n.lookup("完成重新整理前，旧内容不会发送给聊天模型。")
                                    : liveState.needsDeferredRegeneration
                                        ? deferredRegenerationDescription
                                    : liveState.updatedAt == nil
                                        ? L10n.lookup("开启功能后点“立即整理”，或等待自动整理。")
                                        : L10n.lookup("已经完成过整理；重复、已移入长期记忆或无关内容不会占用近期记忆。")
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "text.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                } else {
                    Button {
                        isContentEditorPresented = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(L10n.lookup("查看与编辑"), systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(compactPreview(activeMemoryContent, empty: L10n.lookup("暂无内容")))
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        promoteWholeSnapshot()
                    } label: {
                        Label(L10n.lookup("将整份快照移入长期记忆"), systemImage: "pin")
                    }
                    .disabled(
                        !isPersistedAssistant
                            || RecentMemoryOrganizerContract
                                .requiresFullRegeneration(liveState)
                    )
                }

                if !liveState.sources.isEmpty {
                    DisclosureGroup(
                        L10n.format("来源会话（%@）", [String(describing: liveState.sources.count)]),
                        isExpanded: $isSourcesExpanded
                    ) {
                        ForEach(liveState.sources) { source in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.title.isEmpty ? L10n.lookup("未命名聊天") : source.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                Text(source.updatedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                Text(L10n.lookup("当前记忆"))
            } footer: {
                if !isPersistedAssistant {
                    Text(L10n.lookup("新助手的生成与保存操作会在首次保存助手后开放。"))
                }
            }

            if !liveState.changeLog.isEmpty {
                Section(L10n.lookup("本次变化")) {
                    ForEach(Array(liveState.changeLog.enumerated()), id: \.offset) { _, change in
                        Label(change, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14))
                    }
                }
            }

            if !longTermCandidates.isEmpty {
                Section {
                    ForEach(longTermCandidates) { entry in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(entry.content)
                                .font(.system(size: 15))
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)

                            DisclosureGroup(L10n.lookup("查看完整内容")) {
                                Text(entry.content)
                                    .font(.system(size: 15))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 4)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Text(L10n.lookup(entry.category.title))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    promoteEntry(entry)
                                } label: {
                                    Label(L10n.lookup("移入长期"), systemImage: "pin")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .disabled(!isPersistedAssistant)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text(L10n.lookup("长期记忆候选"))
                } footer: {
                    Text(L10n.lookup("只有你点按移入后，候选才会进入长期记忆，并从近期记忆移除。"))
                }
            }

            Section {
                Button {
                    refresh(forceFull: false)
                } label: {
                    Label(
                        liveState.needsDeferredRegeneration
                            ? L10n.lookup("立即完成待整理")
                            : L10n.lookup("立即增量整理"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!canRefresh)

                Button {
                    refresh(forceFull: true)
                } label: {
                    Label(L10n.lookup("强制重新生成"), systemImage: "sparkles")
                }
                .disabled(!canRefresh)

                Button {
                    undoLastUpdate()
                } label: {
                    Label(L10n.lookup("撤销上一版"), systemImage: "arrow.uturn.backward")
                }
                .disabled(
                    !isPersistedAssistant
                        || liveState.previousVersion == nil
                        || isRefreshing
                        || RecentMemoryOrganizerContract
                            .requiresFullRegeneration(liveState)
                )

                NavigationLink {
                    AssistantRecentMemoryExclusionsView(
                        assistantID: profile.id,
                        excludedConversationIDs: excludedConversationIDsBinding
                    )
                } label: {
                    HStack {
                        Label(L10n.lookup("排除聊天"), systemImage: "minus.circle")
                        Spacer()
                        if !settings.excludedConversationIDs.isEmpty {
                            Text("\(settings.excludedConversationIDs.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!settings.isEnabled)

                Button(role: .destructive) {
                    isClearConfirmationPresented = true
                } label: {
                    Label(L10n.lookup("清除近期记忆"), systemImage: "trash")
                }
                .disabled(
                    !isPersistedAssistant
                        || liveState.content.isEmpty
                            && liveState.entries.isEmpty
                            && liveState.sources.isEmpty
                )
            } header: {
                Text(L10n.lookup("管理"))
            } footer: {
                Text(L10n.lookup("编辑、删除、重新生成、从旧消息继续、切换回答版本，或更改长期记忆时，只会先在本机安全标记为待整理，不会立刻调用模型；可以手动完成待整理，或等待原定自动整理时间。普通增量整理只处理有变化的来源；强制重新生成会重新读取候选范围。清除后仍可撤销一次。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("近期记忆"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isModelSelectorPresented) {
            ModelSelectorView(
                context: .sheet,
                selectedSelection: settings.organizerModel,
                inheritedChoiceTitle: L10n.lookup("跟随摘要、助手与全局模型"),
                screenTitle: L10n.lookup("近期记忆整理模型"),
                chatOnly: true,
                onSelect: { selection in
                    updateSettings { $0.organizerModel = selection }
                }
            )
        }
        .sheet(isPresented: $isInstructionEditorPresented) {
            ExpandedTextEditorSheet(
                title: L10n.lookup("近期记忆整理要求"),
                initialText: settings.customInstruction,
                note: L10n.lookup("留空会使用安全的默认整理规则；这段内容不会改动助手系统提示词。")
            ) { text in
                updateSettings { $0.customInstruction = text }
                return true
            }
        }
        .sheet(isPresented: $isContentEditorPresented) {
            ExpandedTextEditorSheet(
                title: L10n.lookup("编辑近期记忆"),
                initialText: activeMemoryContent,
                note: L10n.lookup("保存会完整保留文字并建立一个可撤销的上一版；发送给聊天时才按近期记忆 Token 上限取用。")
            ) { text in
                guard model.updateRecentMemoryContent(
                    assistantID: profile.id,
                    content: text,
                    settingsOverride: settings
                ) else {
                    setNotice(L10n.lookup("近期记忆保存失败，请稍后重试。"), isError: true)
                    return false
                }
                setNotice(L10n.lookup("近期记忆已保存。"))
                return true
            }
        }
        .alert(L10n.lookup("自定义候选聊天数"), isPresented: $isCustomConversationLimitPresented) {
            TextField("5–100", text: $customConversationLimitText)
                .keyboardType(.numberPad)
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("保存")) {
                guard let value = customConversationLimitValue else { return }
                updateSettings { $0.candidateConversationLimit = value }
            }
            .disabled(customConversationLimitValue == nil)
        } message: {
            Text(L10n.lookup("每次整理最多读取 5 到 100 个最近聊天。"))
        }
        .alert(L10n.lookup("自定义最近天数"), isPresented: $isCustomRecentDayCountPresented) {
            TextField("1–30", text: $customRecentDayCountText)
                .keyboardType(.numberPad)
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("保存")) {
                guard let value = customRecentDayCountValue else { return }
                updateSettings { $0.candidateRecentDayCount = value }
            }
            .disabled(customRecentDayCountValue == nil)
        } message: {
            Text(L10n.lookup("每次整理会读取最近 1 到 30 天内有活动的全部候选聊天。"))
        }
        .confirmationDialog(
            L10n.lookup("清除近期记忆？"),
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.lookup("清除近期记忆"), role: .destructive) {
                clearRecentMemory()
            }
            Button(L10n.lookup("取消"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("近期记忆内容、来源和候选会被清空；长期记忆不会受影响，并且可以撤销一次。"))
        }
        .confirmationDialog(
            L10n.lookup("近期记忆待整理"),
            isPresented: $isPendingStatusActionsPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.lookup("我知道了，收起本次提醒")) {
                acknowledgeDeferredRegeneration()
            }
            Button(L10n.lookup("立即整理")) {
                refresh(forceFull: false)
            }
            Button(L10n.lookup("取消"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("收起只改变这次提醒的显示，不会把整理标记为已完成；现有记忆和原定自动时间都保持不变，下次内容或设置变化时会再次提醒。"))
        }
    }

    private var recentMemoryStatusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if canAcknowledgeDeferredRegeneration {
                    Button {
                        isPendingStatusActionsPresented = true
                    } label: {
                        statusBadge
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("近期记忆待整理"))
                    .accessibilityHint(L10n.lookup("显示待整理选项"))
                } else {
                    statusBadge
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 17, weight: .semibold))
                    Text(statusDescription)
                        .font(.system(size: 13))
                        .foregroundStyle(liveState.lastError == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    statusMetric(
                        title: L10n.lookup("上次更新"),
                        value: dateText(liveState.updatedAt)
                    )
                    statusMetric(
                        title: L10n.lookup("下次整理"),
                        value: nextRefreshText
                    )
                    statusMetric(
                        title: L10n.lookup("来源"),
                        value: L10n.format("%@ 个聊天", [String(describing: liveState.sources.count)])
                    )
                    statusMetric(
                        title: L10n.lookup("当前大小"),
                        value: L10n.format("约 %@ token", [String(describing: formatToken(RecentMemoryTokenEstimator.estimate(activeMemoryContent)))])
                    )
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    statusMetric(
                        title: L10n.lookup("上次更新"),
                        value: dateText(liveState.updatedAt)
                    )
                    statusMetric(
                        title: L10n.lookup("下次整理"),
                        value: nextRefreshText
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    statusMetric(
                        title: L10n.lookup("来源"),
                        value: L10n.format("%@ 个聊天", [String(describing: liveState.sources.count)])
                    )
                    statusMetric(
                        title: L10n.lookup("当前大小"),
                        value: L10n.format("约 %@ token", [String(describing: formatToken(RecentMemoryTokenEstimator.estimate(activeMemoryContent)))])
                    )
                }
            }

            Button {
                refresh(forceFull: false)
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isRefreshing ? L10n.lookup("正在整理…") : L10n.lookup("立即整理"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(!canRefresh)
        }
        .padding(.vertical, 5)
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(statusTint.opacity(0.12))
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(statusTint)
            } else {
                Image(systemName: statusSystemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
        }
        .frame(width: 42, height: 42)
        .contentShape(Circle())
    }

    private var canAcknowledgeDeferredRegeneration: Bool {
        isPersistedAssistant
            && settings.isEnabled
            && !isRefreshing
            && pendingLegacySnapshot == nil
            && liveState.lastError?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false
            && !RecentMemoryOrganizerContract.requiresFullRegeneration(liveState)
            && liveState.needsDeferredRegeneration
            && !liveState.isDeferredRegenerationAcknowledged
    }

    private var statusTitle: String {
        if !settings.isEnabled { return L10n.lookup("近期记忆已关闭") }
        if isRefreshing { return L10n.lookup("正在整理") }
        if pendingLegacySnapshot != nil { return L10n.lookup("旧版快照待确认") }
        if liveState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return L10n.lookup("上次整理失败")
        }
        if RecentMemoryOrganizerContract.requiresFullRegeneration(liveState) {
            return L10n.lookup("需要重新整理")
        }
        if liveState.needsDeferredRegeneration {
            return liveState.isDeferredRegenerationAcknowledged
                ? L10n.lookup("本次提醒已收起")
                : L10n.lookup("近期记忆待整理")
        }
        if settings.isPaused { return L10n.lookup("自动整理已暂停") }
        if activeMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveState.updatedAt == nil
                ? L10n.lookup("等待首次整理")
                : L10n.lookup("暂无独立近期事实")
        }
        return L10n.lookup("近期记忆已更新")
    }

    private var statusDescription: String {
        if !isPersistedAssistant {
            return L10n.lookup("请先保存这个助手，再开始整理近期记忆。")
        }
        if !settings.isEnabled {
            return L10n.lookup("内容仍保留，不会发送给聊天，也不会自动更新。")
        }
        if isRefreshing {
            return L10n.lookup("正在读取有变化的用户消息证据，并整理成一份近期背景。")
        }
        if pendingLegacySnapshot != nil {
            return L10n.lookup("隔离副本不会发送给聊天；你可以确认保留，或丢弃后继续使用新整理结果。")
        }
        if let error = liveState.lastError?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        if RecentMemoryOrganizerContract.requiresFullRegeneration(liveState) {
            if settings.isPaused {
                return L10n.lookup("旧内容已暂停注入；可以手动整理，或恢复自动整理后再更新。")
            }
            if settings.cadence == .manual {
                return L10n.lookup("稳定背景或设置已有变化；完成手动整理前，旧内容不会发给聊天模型。")
            }
            return L10n.lookup("旧内容已暂停注入，Mocca 会按当前设置重新整理。")
        }
        if liveState.needsDeferredRegeneration {
            return liveState.isDeferredRegenerationAcknowledged
                ? L10n.lookup("现有记忆继续使用，并仍会按原定时间整理；下次发生变化时会再次提醒。")
                : deferredRegenerationDescription
        }
        if settings.isPaused {
            return L10n.lookup("现有内容仍会作为近期背景使用，也可以随时手动整理。")
        }
        if activeMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveState.updatedAt == nil
                ? L10n.lookup("首次整理会筛掉寒暄、重复内容和工具日志。")
                : L10n.lookup("已经整理完成；目前没有需要单独保留的近期事实。")
        }
        return L10n.lookup("会在设定的时间点继续吸收有变化的聊天。")
    }

    private var deferredRegenerationDescription: String {
        if settings.isPaused {
            return L10n.lookup("设置已保存并完成本地安全处理，不会立即联网；可以手动整理，或恢复自动整理后等待正常时间。")
        }
        if settings.cadence == .manual {
            return L10n.lookup("设置已保存并完成本地安全处理，不会立即联网；点击“立即整理”时应用新设置。")
        }
        return L10n.lookup("设置已保存并完成本地安全处理，不会立即联网；可以手动整理，或等待原定自动整理时间。")
    }

    private var statusSystemImage: String {
        if !settings.isEnabled { return "power" }
        if pendingLegacySnapshot != nil { return "shield.lefthalf.filled" }
        if liveState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "exclamationmark.triangle.fill"
        }
        if RecentMemoryOrganizerContract.requiresFullRegeneration(liveState) {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        if liveState.needsDeferredRegeneration {
            return liveState.isDeferredRegenerationAcknowledged
                ? "checkmark.circle.fill"
                : "clock.badge.exclamationmark"
        }
        if settings.isPaused { return "pause.circle.fill" }
        if activeMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveState.updatedAt == nil ? "clock" : "checkmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if !settings.isEnabled { return .secondary }
        if pendingLegacySnapshot != nil { return .orange }
        if liveState.lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .red
        }
        if RecentMemoryOrganizerContract.requiresFullRegeneration(liveState) {
            return .orange
        }
        if liveState.needsDeferredRegeneration {
            return liveState.isDeferredRegenerationAcknowledged ? .green : .orange
        }
        if settings.isPaused { return .orange }
        if activeMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return liveState.updatedAt == nil
                ? Color(uiColor: model.themeAccentUIColor)
                : .green
        }
        return .green
    }

    private var nextRefreshText: String {
        if !settings.isEnabled { return L10n.lookup("已关闭") }
        if settings.isPaused { return L10n.lookup("已暂停") }
        switch settings.cadence {
        case .afterConversation:
            return L10n.lookup("聊天结束后")
        case .manual:
            return L10n.lookup("仅手动")
        case .daily, .threeDays, .weekly:
            if let nextRefreshAt = liveState.nextRefreshAt {
                return dateText(nextRefreshAt)
            }
            return settings.cadence.title
        }
    }

    private var organizerModelTitle: String {
        if let selection = settings.organizerModel,
           let context = model.resolvedChatModel(for: selection) {
            return "\(context.provider.name) · \(context.model.displayName)"
        }
        if let selection = model.preferences.summaryModelSelection,
           let context = model.resolvedChatModel(for: selection) {
            return L10n.format("摘要默认 · %@", [String(describing: context.model.displayName)])
        }
        return L10n.lookup("自动回退")
    }

    private var recentMemoryEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled },
            set: { enabled in
                updateSettings { $0.isEnabled = enabled }
                profile.enableRecentChatsReference = enabled
                if !enabled {
                    model.cancelRecentMemoryRefresh(assistantID: profile.id)
                }
            }
        )
    }

    private var cadenceBinding: Binding<RecentMemoryCadence> {
        settingsBinding(\.cadence)
    }

    private var automaticConversationSummaryBinding: Binding<Bool> {
        settingsBinding(\.isAutomaticConversationSummaryEnabled)
    }

    private var sourceSelectionModeBinding:
        Binding<RecentMemorySourceSelectionMode> {
        settingsBinding(\.sourceSelectionMode)
    }

    private var candidateConversationLimitBinding: Binding<Int> {
        settingsBinding(\.candidateConversationLimit)
    }

    private var candidateRecentDayCountBinding: Binding<Int> {
        settingsBinding(\.candidateRecentDayCount)
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { settings.isPaused },
            set: { paused in
                updateSettings { $0.isPaused = paused }
                if paused {
                    model.cancelRecentMemoryRefresh(assistantID: profile.id)
                }
            }
        )
    }

    private var budgetPresetBinding: Binding<RecentMemoryBudgetPreset> {
        Binding(
            get: { settings.budgetPreset },
            set: { preset in
                updateSettings { $0.applyPreset(preset) }
            }
        )
    }

    private var excludedConversationIDsBinding: Binding<Set<UUID>> {
        settingsBinding(\.excludedConversationIDs)
    }

    private func settingsBinding<Value>(
        _ keyPath: WritableKeyPath<RecentMemorySettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updateSettings { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func tokenBinding(
        _ keyPath: WritableKeyPath<RecentMemorySettings, Int>,
        range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updateSettings {
                    $0[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
                    $0.budgetPreset = .custom
                }
            }
        )
    }

    private func updateSettings(_ update: (inout RecentMemorySettings) -> Void) {
        var updated = profile.recentMemorySettings
        update(&updated)
        profile.recentMemorySettings = updated
        profile.enableRecentChatsReference = updated.isEnabled
    }

    private func recentMemorySettingLabel(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            AppSymbolImage(systemName: systemImage)
                .frame(width: 24)
        }
        .padding(.vertical, 3)
    }

    private func tokenStepper(
        title: String,
        value: Int,
        binding: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        Stepper(value: binding, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(formatToken(value))
                    .font(.system(size: 14, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh(forceFull: Bool) {
        guard canRefresh else { return }
        actionNotice = nil
        model.requestRecentMemoryRefresh(
            assistantID: profile.id,
            forceFull: forceFull,
            settingsOverride: settings
        )
    }

    private func acknowledgeDeferredRegeneration() {
        guard model.acknowledgeRecentMemoryDeferredRegeneration(
            assistantID: profile.id
        ) else {
            setNotice(L10n.lookup("本次待整理提醒未能收起，请稍后重试。"), isError: true)
            return
        }
        setNotice(L10n.lookup("已收起本次提醒；原定整理时间保持不变。"))
    }

    private func clearRecentMemory() {
        guard model.clearRecentMemory(
            assistantID: profile.id
        ) else {
            setNotice(L10n.lookup("近期记忆清除失败，请稍后重试。"), isError: true)
            return
        }
        setNotice(L10n.lookup("近期记忆已清除；可以撤销一次。"))
    }

    private func confirmPendingLegacySnapshot() {
        guard model.confirmPendingLegacyRecentMemorySnapshot(
            assistantID: profile.id
        ) else {
            setNotice(L10n.lookup("旧版快照确认失败，原文仍安全保留。"), isError: true)
            return
        }
        setNotice(L10n.lookup("已按你的确认保留这份文字。"))
    }

    private func discardPendingLegacySnapshot() {
        guard model.discardPendingLegacyRecentMemorySnapshot(
            assistantID: profile.id
        ) else {
            setNotice(L10n.lookup("旧版快照未能安全丢弃，请稍后重试。"), isError: true)
            return
        }
        setNotice(L10n.lookup("旧版隔离快照已丢弃。"))
        if RecentMemoryOrganizerContract.requiresFullRegeneration(liveState),
           settings.isEnabled {
            refresh(forceFull: true)
        }
    }

    private func undoLastUpdate() {
        guard model.undoRecentMemoryUpdate(
            assistantID: profile.id
        ) else {
            setNotice(L10n.lookup("没有可撤销的近期记忆版本。"), isError: true)
            return
        }
        setNotice(L10n.lookup("已恢复上一版近期记忆。"))
    }

    private func promoteEntry(_ entry: RecentMemoryEntry) {
        let cleaned = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let persistedMemory = model.promoteRecentMemoryEntry(
            assistantID: profile.id,
            entryID: entry.id
        ) else {
            setNotice(L10n.lookup("长期记忆保存失败，请稍后重试。"), isError: true)
            return
        }

        if let index = profile.memories.firstIndex(where: {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == cleaned
        }) {
            profile.memories[index] = persistedMemory
        } else {
            profile.memories.append(persistedMemory)
        }
        profile.enableMemory = true
        setNotice(L10n.lookup("已将这条候选移入长期记忆，并从近期记忆移除。"))
    }

    private func promoteWholeSnapshot() {
        let cleaned = activeMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let snapshot = L10n.format("## 近期记忆快照\n%@", [String(describing: cleaned)])
        let alreadySavedInDraft = profile.memories.contains {
            $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot
        }
        let alreadySavedInModel = model.assistants
            .first(where: { $0.id == profile.id })?
            .memories
            .contains {
                $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot
            } == true

        guard let persistedMemory =
                model.promoteRecentMemoryContent(assistantID: profile.id) else {
            setNotice(L10n.lookup("长期记忆保存失败，请稍后重试。"), isError: true)
            return
        }
        if let index = profile.memories.firstIndex(where: {
            let content = $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return content == cleaned || content == snapshot
        }) {
            profile.memories[index] = persistedMemory
        } else {
            profile.memories.append(persistedMemory)
        }
        profile.enableMemory = true
        setNotice(alreadySavedInDraft || alreadySavedInModel
                  ? L10n.lookup("这份快照已在长期记忆中，并已从近期记忆移除。")
                  : L10n.lookup("已将整份快照移入长期记忆，并从近期记忆清除。"))
    }

    private func setNotice(_ message: String, isError: Bool = false) {
        actionNotice = message
        actionNoticeIsError = isError
    }

    private func compactPreview(_ text: String, empty emptyValue: String) -> String {
        let compact = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !compact.isEmpty else { return emptyValue }
        return String(compact.prefix(140))
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return L10n.lookup("尚未") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatToken(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

private struct RecentMemoryGuideView: View {
    var body: some View {
        Form {
            Section(L10n.lookup("自动整理")) {
                Text(L10n.lookup("来源范围可以按最近聊天数量，也可以按最近活动时间回溯 1–30 天。按天模式会纳入时间窗口内全部符合的聊天，不再额外限制聊天数量。"))
                Text(L10n.lookup("保存频率、来源范围、整理模型、自定义要求或预算时不会立即调用整理模型；新设置会在你手动整理或原定自动时间生效。"))
                Text(L10n.lookup("编辑、删除、重新生成、从旧消息继续或切换回答版本，只会取消可能仍在读取旧正文的整理，并标记为“待整理”；不会提前开始新的模型调用。"))
                Text(L10n.lookup("更改整理频率会从保存时重新计算下次时间。“自动维护窗口摘要”默认关闭；开启后，达到所选消息数会额外调用模型更新该窗口摘要。"))
            }

            Section(L10n.lookup("Token 预算")) {
                Text(L10n.lookup("“均衡”适合大多数聊天；手动调整任意一项后会切换为“自定义”。“近期记忆”只限制近期记忆块，已启用的长期记忆会独立完整注入，不占用该上限。"))
                Text(L10n.lookup("“整理输入”限制一次整理请求最多装入多少来源证据。调高后更不容易在来源很多或聊天很长时截断，但不会突破“单个聊天证据／摘要”上限，也不会增加最终近期记忆的输出上限。可选的窗口摘要输出同样受单个聊天上限保护。"))
                Text(L10n.lookup("第一遍只读取你亲自发送的消息证据，不读取助手回复、会话摘要、长期记忆、用户资料、指令注入或世界书；因此助手对隐藏提示的复述也不能成为近期记忆来源。"))
            }

            Section(L10n.lookup("稳定背景去重")) {
                Text(L10n.lookup("第二遍才会把已启用的稳定内容作为不可信的只读参考，而且只能返回要删除的条目编号，不能生成、改写或回传正文。"))
                Text(L10n.lookup("设为 0 会跳过可选的语义去重，但本机仍会完成精确重复过滤。"))
            }

            Section(L10n.lookup("状态提醒")) {
                Text(L10n.lookup("收起“待整理”提醒只表示你已经看过这次提示，不会把整理标记为完成，也不会改变现有记忆或原定自动时间。下一次内容或设置变化后，提醒会自动回来。"))
                Text(L10n.lookup("整理失败、旧版快照待确认和必须重新整理等安全状态不能收起。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("近期记忆说明"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AssistantRecentMemoryExclusionsView: View {
    @Environment(AppModel.self) private var model
    let assistantID: UUID
    @Binding var excludedConversationIDs: Set<UUID>

    private var conversations: [Conversation] {
        model.recentContextSummaryConversations(for: assistantID)
    }

    var body: some View {
        List {
            if conversations.isEmpty {
                ContentUnavailableView(
                    L10n.lookup("还没有可选聊天"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(L10n.lookup("这个助手有聊天内容后，可以在这里排除不想用于整理的窗口。"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(conversations) { conversation in
                        Toggle(isOn: exclusionBinding(for: conversation.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title.isEmpty ? L10n.lookup("未命名聊天") : conversation.title)
                                    .lineLimit(1)
                                Text(conversation.updatedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    Text(L10n.lookup("不参与近期记忆"))
                } footer: {
                    Text(L10n.lookup("打开开关的聊天不会参与后续自动或手动整理；已有快照不会立刻删除，下一次整理时会更新。"))
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("排除聊天"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func exclusionBinding(for conversationID: UUID) -> Binding<Bool> {
        Binding(
            get: { excludedConversationIDs.contains(conversationID) },
            set: { isExcluded in
                if isExcluded {
                    excludedConversationIDs.insert(conversationID)
                } else {
                    excludedConversationIDs.remove(conversationID)
                }
            }
        )
    }
}

private struct AssistantMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var memory: AssistantMemory
    @State private var unsavedChangesAlertPresented = false
    private let originalContent: String
    let onSave: (AssistantMemory) -> Bool

    init(memory: AssistantMemory, onSave: @escaping (AssistantMemory) -> Bool) {
        _memory = State(initialValue: memory)
        originalContent = memory.content
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack {
                NativeMultilineTextEditor(
                    text: $memory.content,
                    font: .system(size: 17)
                )
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .padding(16)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L10n.lookup("记忆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { requestDismissal() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) { saveAndDismiss() }
                        .foregroundStyle(.primary)
                    .disabled(memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(memory.content != originalContent)
        .alert(L10n.lookup("记忆尚未保存"), isPresented: $unsavedChangesAlertPresented) {
            if !memory.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(L10n.lookup("保存")) { saveAndDismiss() }
            }
            Button(L10n.lookup("不保留修改"), role: .destructive) { dismiss() }
        } message: {
            Text(L10n.lookup("返回后，刚刚修改的记忆内容会丢失。"))
        }
    }

    private func requestDismissal() {
        if memory.content == originalContent {
            dismiss()
        } else {
            unsavedChangesAlertPresented = true
        }
    }

    private func saveAndDismiss() {
        memory.content = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
        memory.updatedAt = .now
        if onSave(memory) {
            dismiss()
        }
    }
}

private struct AssistantRecentContextSummarySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let assistantID: UUID
    let onInstructionSave: (String) -> Bool
    let onSave: (String) -> Bool

    @State private var selectedConversationIDs = Set<UUID>()
    @State private var modelSelection: ModelSelection?
    @State private var instruction: String
    @State private var output = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var isModelSelectorPresented = false
    @State private var isInstructionEditorPresented = false
    @State private var isOutputEditorPresented = false

    init(
        assistantID: UUID,
        initialInstruction: String,
        onInstructionSave: @escaping (String) -> Bool,
        onSave: @escaping (String) -> Bool
    ) {
        self.assistantID = assistantID
        self.onInstructionSave = onInstructionSave
        self.onSave = onSave
        _instruction = State(initialValue: initialInstruction)
    }

    private var conversations: [Conversation] {
        appModel.recentContextSummaryConversations(for: assistantID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("总结设置")) {
                    Button {
                        isModelSelectorPresented = true
                    } label: {
                        AssistantEditorValueRow(
                            title: L10n.lookup("总结模型"),
                            value: summaryModelTitle,
                            systemImage: "doc.text"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        isInstructionEditorPresented = true
                    } label: {
                        AssistantEditorValueRow(
                            title: L10n.lookup("总结要求"),
                            value: compactPreview(instruction, empty: L10n.lookup("未填写")),
                            systemImage: "text.alignleft"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !output.isEmpty {
                    Section {
                        Button {
                            isOutputEditorPresented = true
                        } label: {
                            AssistantEditorValueRow(
                                title: L10n.lookup("保存前编辑"),
                                value: compactPreview(output, empty: L10n.lookup("未生成")),
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text(L10n.lookup("总结结果"))
                    } footer: {
                        Text(L10n.lookup("点按右上角“保存”后会立即作为一条独立的长期记忆加入这个助手；不会覆盖会自动更新的近期记忆。"))
                    }
                }

                Section {
                    Button {
                        if selectedConversationIDs.count == conversations.count {
                            selectedConversationIDs.removeAll()
                        } else {
                            selectedConversationIDs = Set(conversations.map(\.id))
                        }
                    } label: {
                        HStack {
                            Label(L10n.lookup("选择会话"), systemImage: "checklist")
                            Spacer()
                            Text("\(selectedConversationIDs.count)/\(conversations.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(conversations) { conversation in
                        Button {
                            if selectedConversationIDs.contains(conversation.id) {
                                selectedConversationIDs.remove(conversation.id)
                            } else {
                                selectedConversationIDs.insert(conversation.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedConversationIDs.contains(conversation.id)
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundStyle(selectedConversationIDs.contains(conversation.id)
                                                     ? Color.accentColor
                                                     : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.localizedDisplayTitle)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(L10n.lookup("近期会话"))
                } footer: {
                    Text(L10n.lookup("只会读取这个助手的所选聊天；不会把其他助手或群聊混进来。"))
                }
            }
            .settingsGroupedPageStyle()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                summaryActionDock
            }
            .navigationTitle(L10n.lookup("创建长期记忆"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
                        if onSave(L10n.format("## 近期聊天上下文\n生成于 %@\n\n%@", [String(describing: stamp), String(describing: cleaned)])) {
                            dismiss()
                        } else {
                            errorMessage = L10n.lookup("长期记忆保存失败，请稍后重试。")
                        }
                    }
                    .disabled(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(L10n.lookup("保存为长期记忆"))
                }
            }
            .task {
                if selectedConversationIDs.isEmpty {
                    selectedConversationIDs = Set(conversations.prefix(5).map(\.id))
                }
            }
            .sheet(isPresented: $isModelSelectorPresented) {
                ModelSelectorView(
                    context: .sheet,
                    selectedSelection: modelSelection,
                    inheritedChoiceTitle: L10n.lookup("跟随摘要、助手与全局模型"),
                    screenTitle: L10n.lookup("总结模型"),
                    chatOnly: true,
                    onSelect: { modelSelection = $0 }
                )
            }
            .sheet(isPresented: $isInstructionEditorPresented) {
                ExpandedTextEditorSheet(
                    title: L10n.lookup("总结要求"),
                    initialText: instruction,
                    note: L10n.lookup("保存后会作为这个助手的默认总结要求；不会改动助手的系统提示词。"),
                    confirmationTitle: L10n.lookup("保存")
                ) { text in
                    let cleaned = text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    guard onInstructionSave(cleaned) else { return false }
                    instruction = cleaned.isEmpty
                        ? AppModel.defaultRecentContextSummaryInstruction
                        : cleaned
                    return true
                }
            }
            .sheet(isPresented: $isOutputEditorPresented) {
                ExpandedTextEditorSheet(
                    title: L10n.lookup("保存前编辑"),
                    initialText: output,
                    note: L10n.lookup("完成后可用右上角“保存”立即加入这个助手。")
                ) { text in
                    output = text
                    return true
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private var summaryActionDock: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                generate()
            } label: {
                HStack(spacing: 9) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isGenerating ? L10n.lookup("正在总结…") : L10n.lookup("生成总结"))
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(isGenerating || selectedConversationIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var summaryModelTitle: String {
        if let selection = modelSelection,
           let context = appModel.resolvedChatModel(for: selection) {
            return "\(context.provider.name) · \(context.model.displayName)"
        }
        if let selection = appModel.preferences.summaryModelSelection,
           let context = appModel.resolvedChatModel(for: selection) {
            return L10n.format("摘要默认 · %@", [String(describing: context.model.displayName)])
        }
        return L10n.lookup("自动回退")
    }

    private func compactPreview(_ text: String, empty emptyValue: String) -> String {
        let compact = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !compact.isEmpty else { return emptyValue }
        return String(compact.prefix(80))
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                output = try await appModel.generateRecentContextSummary(
                    assistantID: assistantID,
                    conversationIDs: selectedConversationIDs,
                    modelSelection: modelSelection,
                    instruction: instruction
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AssistantImageGenerationPicker: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var providerID: UUID?
    @State private var modelID: String
    @State private var models: [ExternalImageModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    let onSave: (UUID?, String?) -> Void

    init(
        selectedProviderID: UUID?,
        selectedModelID: String?,
        onSave: @escaping (UUID?, String?) -> Void
    ) {
        _providerID = State(initialValue: selectedProviderID)
        _modelID = State(initialValue: selectedModelID ?? "")
        self.onSave = onSave
    }

    private var providers: [ProviderConfiguration] {
        appModel.providers.filter { $0.enabled && $0.supportsExternalImageGeneration }
    }

    private var selectedProvider: ProviderConfiguration? {
        providers.first { $0.id == providerID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if providers.isEmpty {
                    ContentUnavailableView(
                        L10n.lookup("还没有可用的图像供应商"),
                        systemImage: "shippingbox",
                        description: Text(L10n.lookup("请先在供应商设置里启用图像生成接口，并填写对应 API Key。"))
                    )
                } else {
                    Form {
                        Section(L10n.lookup("供应商")) {
                            Picker(L10n.lookup("供应商"), selection: $providerID) {
                                ForEach(providers) { provider in
                                    Text(provider.name).tag(Optional(provider.id))
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Section {
                            TextField(L10n.lookup("例如 openai/gpt-image-1"), text: $modelID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if isLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text(L10n.lookup("正在读取图像模型…"))
                                        .foregroundStyle(.secondary)
                                }
                            } else if models.isEmpty {
                                Text(errorMessage ?? L10n.lookup("没有读取到模型，可以直接输入模型 ID。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(models) { imageModel in
                                    Button {
                                        modelID = imageModel.id
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(imageModel.name)
                                                    .foregroundStyle(.primary)
                                                if imageModel.name != imageModel.id {
                                                    Text(imageModel.id)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            if modelID == imageModel.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text(L10n.lookup("图像模型"))
                        } footer: {
                            Text(L10n.lookup("接口格式由供应商设置决定；模型列表不可用时也可以手动填写模型 ID。"))
                        }
                    }
                    .settingsGroupedPageStyle()
                }
            }
            .navigationTitle(L10n.lookup("图像生成"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        let cleaned = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(providerID, cleaned.isEmpty ? nil : cleaned)
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                    .disabled(providerID == nil || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                if providerID == nil || !providers.contains(where: { $0.id == providerID }) {
                    providerID = providers.first?.id
                }
            }
            .task(id: providerID) {
                await loadModels()
            }
            .onChange(of: providerID) { oldValue, newValue in
                if oldValue != nil, oldValue != newValue {
                    modelID = ""
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private func loadModels() async {
        models = []
        errorMessage = nil
        guard let selectedProvider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await ExternalImageGenerationService.listModels(provider: selectedProvider)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AssistantQuickPhraseManagementView: View {
    @Environment(AppModel.self) private var model
    let assistantID: UUID
    @State private var editingPhrase: QuickPhrase?

    private var phrases: [QuickPhrase] {
        model.quickPhrases.filter {
            !$0.isGlobal && $0.assistantID == assistantID.uuidString
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    editingPhrase = QuickPhrase(
                        isGlobal: false,
                        assistantID: assistantID.uuidString
                    )
                } label: {
                    Label(L10n.lookup("添加快捷短语"), systemImage: "plus")
                }
            } footer: {
                Text(L10n.lookup("这里添加的短语只会出现在这个助手的输入框菜单里，并会立即保存。"))
            }

            Section(L10n.lookup("助手快捷短语")) {
                if phrases.isEmpty {
                    ContentUnavailableView(
                        L10n.lookup("暂无快捷短语"),
                        systemImage: "bolt",
                        description: Text(L10n.lookup("点击上方按钮添加常用输入内容"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(phrases) { phrase in
                        Button {
                            editingPhrase = phrase
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(phrase.title.isEmpty ? L10n.lookup("未命名短语") : phrase.title)
                                    .foregroundStyle(.primary)
                                Text(phrase.content)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { index in
                            phrases.indices.contains(index) ? phrases[index].id : nil
                        }
                        for id in ids {
                            model.deleteQuickPhrase(id)
                        }
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
        .sheet(item: $editingPhrase) { phrase in
            AssistantQuickPhraseEditor(phrase: phrase) { saved in
                model.upsertQuickPhrase(saved)
            }
        }
    }
}

private struct AssistantQuickPhraseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phrase: QuickPhrase
    let onSave: (QuickPhrase) -> Void

    init(phrase: QuickPhrase, onSave: @escaping (QuickPhrase) -> Void) {
        _phrase = State(initialValue: phrase)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("标题")) {
                    TextField(L10n.lookup("短语名称"), text: $phrase.title)
                }
                Section(L10n.lookup("内容")) {
                    NativeMultilineTextEditor(text: $phrase.content)
                        .frame(minHeight: 150)
                }
            }
            .navigationTitle(L10n.lookup("快捷短语"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        phrase.isGlobal = false
                        onSave(phrase)
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                    .disabled(phrase.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Local Tools Page

struct AssistantLocalToolsView: View {
    @Binding var profile: AssistantProfile

    private struct ToolInfo: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
    }

    private var tools: [ToolInfo] {
        [
            ToolInfo(id: LocalToolName.timeInfo, title: L10n.lookup("获取时间"), subtitle: L10n.lookup("获取当前设备的本地日期和时间"), icon: "clock"),
            ToolInfo(id: LocalToolName.clipboard, title: L10n.lookup("剪贴板"), subtitle: L10n.lookup("读取或写入设备剪贴板的纯文本"), icon: "doc.on.clipboard"),
            ToolInfo(id: LocalToolName.textToSpeech, title: L10n.lookup("语音朗读"), subtitle: L10n.lookup("使用当前语音服务朗读助手指定的文本"), icon: "speaker.wave.2"),
            ToolInfo(id: LocalToolName.calculate, title: L10n.lookup("计算器"), subtitle: L10n.lookup("计算数学表达式"), icon: "function"),
            ToolInfo(id: LocalToolName.searchConversations, title: L10n.lookup("搜索对话"), subtitle: L10n.lookup("搜索此助手名下其他单聊的正文片段，不含群聊或未归属聊天"), icon: "magnifyingglass"),
            ToolInfo(id: LocalToolName.weather, title: L10n.lookup("天气"), subtitle: L10n.lookup("使用当前位置查询 Open-Meteo 天气"), icon: "sun.max"),
            ToolInfo(id: LocalToolName.createCalendarEvent, title: L10n.lookup("创建日历事件"), subtitle: L10n.lookup("添加事件到设备默认日历"), icon: "calendar.badge.plus"),
            ToolInfo(id: LocalToolName.reminders, title: L10n.lookup("系统提醒事项"), subtitle: L10n.lookup("按你的要求查看、创建、编辑、完成或删除 Apple 提醒事项"), icon: "checklist"),
        ]
    }

    var body: some View {
        List {
            Section {
                Toggle(L10n.lookup("联网搜索"), isOn: $profile.searchEnabled)
                Picker(L10n.lookup("搜索方式"), selection: $profile.searchMode) {
                    ForEach(AssistantSearchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!profile.searchEnabled)
            } footer: {
                Text(profile.searchMode.explanation)
            }

            Section(L10n.lookup("本地工具")) {
                ForEach(tools) { tool in
                    let isEnabled = profile.localToolIDs.contains(tool.id)
                    Toggle(isOn: Binding(
                        get: { isEnabled },
                        set: { newValue in
                            if newValue {
                                profile.localToolIDs.insert(tool.id)
                            } else {
                                profile.localToolIDs.remove(tool.id)
                            }
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.lookup(tool.title))
                                    .font(.body)
                                Text(L10n.lookup(tool.subtitle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: tool.icon)
                                .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                        }
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
    }
}
