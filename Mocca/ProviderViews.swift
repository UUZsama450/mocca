import Observation
import SwiftUI
import UIKit
import PhotosUI

enum SettingsPageContext {
    case sheet
    case navigation
}

struct ProviderSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editingProvider: ProviderConfiguration?
    let context: SettingsPageContext
    let showsSetupHint: Bool

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    private var setupAccent: Color {
        Color(uiColor: model.themeActionUIColor)
    }

    init(
        context: SettingsPageContext = .sheet,
        showsSetupHint: Bool = false
    ) {
        self.context = context
        self.showsSetupHint = showsSetupHint
    }

    var body: some View {
        Group {
            if context == .sheet {
                NavigationStack {
                    pageContent
                }
            } else {
                pageContent
            }
        }
    }

    private var pageContent: some View {
        List {
            if showsSetupHint {
                Section(L10n.lookup("第一次连接")) {
                    Label {
                        Text(L10n.lookup("选择一个服务商，填写 API Key，再到编辑页底部的“模型”中获取并添加聊天模型。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "1.circle.fill")
                            .foregroundStyle(setupAccent)
                    }
                }
            }

            if !showsSetupHint {
                Section(L10n.lookup("收藏的供应商")) {
                    if favoriteProviders.isEmpty {
                        Label(L10n.lookup("点按服务商右侧的爱心收藏"), systemImage: "heart")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favoriteProviders) { provider in
                            providerRow(provider, showsEnableToggle: false)
                        }
                    }
                }
            }

            Section(L10n.lookup("服务商")) {
                if model.providers.isEmpty {
                    ContentUnavailableView(
                        L10n.lookup("还没有服务商"),
                        systemImage: "server.rack",
                        description: Text(L10n.lookup("添加服务商配置"))
                    )
                } else {
                    ForEach(model.providers) { provider in
                        providerRow(provider, showsEnableToggle: true)
                    }
                    .onDelete(perform: model.deleteProviders)
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("服务商"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if context == .sheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section(L10n.lookup("添加自定义服务商")) {
                        ForEach(ProviderType.allCases) { type in
                            Button {
                                editingProvider = .new(type: type)
                            } label: {
                                ProviderTypeMenuLabel(type: type)
                            }
                        }
                    }
                    Section {
                        Button {
                            model.restoreDefaultProviders()
                        } label: {
                            Label(L10n.lookup("恢复缺失的默认服务商"), systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.lookup("添加服务商"))
            }
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorView(configuration: provider) { saved in
                model.upsertProvider(saved)
            }
        }
    }

    private var favoriteProviders: [ProviderConfiguration] {
        model.providers.filter { model.isFavoriteProvider($0.id) }
    }

    private func providerRow(
        _ provider: ProviderConfiguration,
        showsEnableToggle: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                editingProvider = provider
            } label: {
                HStack(spacing: 12) {
                    ProviderGlyph(provider: provider)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(provider.baseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(provider.models.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                model.toggleFavoriteProvider(provider.id)
            } label: {
                Image(systemName: model.isFavoriteProvider(provider.id) ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.isFavoriteProvider(provider.id) ? Color.red : Color.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isFavoriteProvider(provider.id) ? L10n.lookup("取消收藏") : L10n.lookup("收藏供应商"))

            if showsEnableToggle {
                Toggle(
                    L10n.lookup("启用"),
                    isOn: Binding(
                        get: { provider.enabled },
                        set: { model.setProviderEnabled($0, id: provider.id) }
                    )
                )
                .labelsHidden()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct FirstRunModelSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var isProviderSettingsPresented = false
    @State private var isModelSelectorPresented = false

    let onContinue: () -> Void

    private var onboardingAccent: Color {
        Color(uiColor: model.themeActionUIColor)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    setupSummary
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(
                model.isModelSetupTriggeredBySend
                    ? L10n.lookup("连接聊天模型")
                    : L10n.lookup("欢迎使用 Mocca")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AppLanguagePicker() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.lookup("稍后")) { onContinue() }
                        .foregroundStyle(.primary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomActions
            }
        }
        .onAppear {
            model.recordFirstRunModelSetupPresentation()
        }
        .sheet(isPresented: $isProviderSettingsPresented) {
            ProviderSettingsView(showsSetupHint: true)
        }
        .sheet(isPresented: $isModelSelectorPresented) {
            ModelSelectorView(
                selectedSelection: model.effectiveModelContext?.selection,
                screenTitle: L10n.lookup("聊天模型"),
                chatOnly: true,
                onSelect: { selection in
                    guard let selection else { return }
                    model.selectChatModelForCurrentAssistant(selection)
                    isModelSelectorPresented = false
                }
            )
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(onboardingAccent.opacity(0.13))
                    .frame(width: 94, height: 94)
                Image(systemName: model.hasReadyChatModel ? "checkmark.bubble.fill" : "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(onboardingAccent)
            }

            VStack(spacing: 9) {
                Text(
                    model.hasReadyChatModel
                        ? L10n.lookup("模型已经连接好啦")
                        : (model.isModelSetupTriggeredBySend
                            ? L10n.lookup("发送前还差一步")
                            : L10n.lookup("先连接一个聊天模型"))
                )
                    .font(.system(size: 27, weight: .bold))
                    .multilineTextAlignment(.center)

                Text(
                    model.hasReadyChatModel
                        ? L10n.format("当前使用 %@，现在可以开始聊天。", [String(describing: model.effectiveModelTitle)])
                        : L10n.lookup("Mocca 本身不包含 AI 模型。连接你使用的服务商后，就可以开始聊天。")
                )
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            }
        }
    }

    private var setupSummary: some View {
        VStack(spacing: 0) {
            setupRow(
                icon: "server.rack",
                title: L10n.lookup("选择服务商"),
                detail: L10n.lookup("选择你使用的模型服务商，连接对应的模型服务。")
            )
            Divider().padding(.leading, 52)
            setupRow(
                icon: "key.fill",
                title: L10n.lookup("Key 留在设备上"),
                detail: L10n.lookup("API Key 只保存在这台设备的系统钥匙串中。")
            )
            Divider().padding(.leading, 52)
            setupRow(
                icon: "arrow.up.message.fill",
                title: L10n.lookup("由服务商生成回复"),
                detail: L10n.lookup("聊天内容会发送给你选择的模型服务商。")
            )
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func setupRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(onboardingAccent)
                .frame(width: 38, height: 38)
                .background(onboardingAccent.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private var bottomActions: some View {
        VStack(spacing: 10) {
            Button {
                if model.hasReadyChatModel {
                    onContinue()
                } else {
                    isProviderSettingsPresented = true
                }
            } label: {
                Text(model.hasReadyChatModel ? L10n.lookup("开始聊天") : L10n.lookup("连接模型"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(onboardingAccent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)

            if model.hasReadyChatModel {
                HStack(spacing: 18) {
                    Button(L10n.lookup("更换模型")) {
                        isModelSelectorPresented = true
                    }
                    Button(L10n.lookup("管理服务商")) {
                        isProviderSettingsPresented = true
                    }
                }
                .font(.system(size: 15, weight: .medium))
            } else {
                Text(L10n.lookup("没有模型也可以先浏览 App，稍后再从聊天页连接。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct ProviderTypeMenuLabel: View {
    let type: ProviderType

    var body: some View {
        Label {
            Text(L10n.lookup(type.title))
        } icon: {
            Image(type.brandIcon.assetName)
                .resizable()
                .renderingMode(type.brandIcon.usesTemplateRendering ? .template : .original)
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }
}

/// Intercepts only the sheet containing this probe. It never follows a presented
/// child sheet, and restores the previous delegate only while it still owns it.
private struct ProviderDraftDismissObserver: UIViewControllerRepresentable {
    let hasUnsavedChanges: Bool
    let onAttempt: () -> Void
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hasUnsavedChanges = hasUnsavedChanges
        controller.onAttempt = onAttempt
        controller.onDismiss = onDismiss
        controller.installIfPossible()
        // The first update can precede containment in the hosting controller.
        DispatchQueue.main.async { [weak controller] in controller?.installIfPossible() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.uninstall()
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var hasUnsavedChanges = false
        var onAttempt: () -> Void = {}
        var onDismiss: () -> Void = {}
        private weak var observedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private var isDismantled = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIfPossible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfPossible()
        }

        func installIfPossible() {
            guard !isDismantled else { return }
            var ancestor = parent
            while let controller = ancestor {
                if controller.presentingViewController != nil,
                   let presentation = controller.presentationController,
                   presentation.presentedViewController === controller {
                    if observedPresentation !== presentation {
                        restoreDelegate()
                        observedPresentation = presentation
                    }
                    if presentation.delegate !== self {
                        // SwiftUI may replace its delegate while updating this
                        // same sheet. Forward to the new delegate, never a stale one.
                        previousDelegate = presentation.delegate
                        presentation.delegate = self
                    }
                    return
                }
                ancestor = controller.parent
            }
        }

        func uninstall() {
            isDismantled = true
            restoreDelegate()
            onAttempt = {}
            onDismiss = {}
        }

        private func restoreDelegate() {
            if let presentation = observedPresentation, presentation.delegate === self {
                presentation.delegate = previousDelegate
            }
            observedPresentation = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !hasUnsavedChanges
                && (previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if hasUnsavedChanges { onAttempt() }
            previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss()
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}

private enum ProviderEditorTab: String, CaseIterable, Identifiable {
    case configuration
    case models

    var id: String { rawValue }
    @MainActor var title: String { self == .configuration ? L10n.lookup("配置") : L10n.lookup("模型") }
    var systemImage: String { self == .configuration ? "slider.horizontal.3" : "cube.transparent" }
}

struct ProviderEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: ProviderConfiguration
    @State private var selectedTab: ProviderEditorTab = .configuration
    @State private var didSave = false
    @State private var saveErrorMessage = ""
    @State private var isSaveErrorPresented = false
    @State private var isLeaveConfirmationPresented = false
    @State private var balanceQuery = ProviderBalanceQueryState()

    private let originalConfiguration: ProviderConfiguration
    private let originalAvatar: String?
    let onSave: (ProviderConfiguration) -> Bool

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    init(
        configuration: ProviderConfiguration,
        onSave: @escaping (ProviderConfiguration) -> Bool
    ) {
        _configuration = State(initialValue: configuration)
        originalConfiguration = configuration
        originalAvatar = configuration.customAvatar
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Group {
                switch selectedTab {
                case .configuration:
                    configurationPage
                case .models:
                    ProviderModelsWorkspaceView(configuration: $configuration)
                }
            }
            .navigationTitle(configuration.name.isEmpty ? L10n.lookup("服务商") : configuration.name)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                editorTabBar
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消"), action: requestDismiss)
                        .foregroundStyle(.primary)
                }
                if appModel.providers.contains(where: { $0.id == configuration.id }) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            appModel.toggleFavoriteProvider(configuration.id)
                        } label: {
                            Image(systemName: appModel.isFavoriteProvider(configuration.id) ? "heart.fill" : "heart")
                                .foregroundStyle(appModel.isFavoriteProvider(configuration.id) ? Color.red : Color.secondary)
                        }
                        .accessibilityLabel(appModel.isFavoriteProvider(configuration.id) ? L10n.lookup("取消收藏") : L10n.lookup("收藏供应商"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        save()
                    }
                    .foregroundStyle(.primary)
                    .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .background {
            ProviderDraftDismissObserver(
                hasUnsavedChanges: hasUnsavedChanges,
                onAttempt: requestDismiss,
                onDismiss: cleanUpAvatarIfNeeded
            )
        }
        .onChange(of: configuration.customAvatar) { previous, current in
            if previous != originalAvatar, previous != current {
                AssistantMediaStore.remove(previous)
            }
        }
        .alert(L10n.lookup("保存对供应商的修改？"), isPresented: $isLeaveConfirmationPresented) {
            Button(L10n.lookup("保存并离开"), action: save).disabled(!canSave)
            Button(L10n.lookup("不保存"), role: .destructive, action: discardAndDismiss)
            Button(L10n.lookup("继续编辑"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("配置与模型列表中的修改尚未保存。"))
        }
        .alert(L10n.lookup("无法保存供应商"), isPresented: $isSaveErrorPresented) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
    }

    private var configurationPage: some View {
        Form {
            Section(L10n.lookup("管理")) {
                NavigationLink {
                    ProviderIconPickerView(
                        selection: $configuration.brandIcon,
                        customAvatar: $configuration.customAvatar,
                        providerID: configuration.id,
                        providerName: configuration.name,
                        baseURL: configuration.baseURL
                    )
                } label: {
                    HStack(spacing: 12) {
                        ProviderGlyph(provider: configuration, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.lookup("服务商头像"))
                            Text(iconDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker(L10n.lookup("供应商类型"), selection: $configuration.type) {
                    ForEach(ProviderType.allCases) { type in
                        ProviderTypeMenuLabel(type: type)
                            .tag(type)
                    }
                }
                TextField(L10n.lookup("分组（可选）"), text: $configuration.group)
                Toggle(L10n.lookup("是否启用"), isOn: $configuration.enabled)

                Toggle(L10n.lookup("多 Key 模式"), isOn: $configuration.multiKeyEnabled)
                if configuration.multiKeyEnabled {
                    NavigationLink {
                        ProviderMultiKeyView(apiKeys: $configuration.apiKeys)
                    } label: {
                        LabeledContent(L10n.lookup("管理 API Keys"), value: L10n.format("%@ 个可用", [String(describing: configuration.enabledAPIKeys.count)]))
                    }
                }

                if configuration.type == .openAI {
                    Toggle("Response API (/responses)", isOn: $configuration.useResponsesAPI)
                }

                if configuration.supportsClaudePromptCaching {
                    Toggle("Claude Prompt Caching", isOn: $configuration.claudePromptCachingEnabled)
                    if configuration.claudePromptCachingEnabled {
                        Picker(L10n.lookup("缓存时间"), selection: $configuration.claudePromptCachingTTL) {
                            ForEach(ProviderPromptCacheTTL.allCases) { ttl in
                                Text(L10n.lookup(ttl.title)).tag(ttl)
                            }
                        }
                    }
                }

                Toggle(L10n.lookup("获取账户余额"), isOn: $configuration.balanceEnabled)
                if configuration.balanceEnabled {
                    ProviderBalanceSummaryView(configuration: configuration, query: balanceQuery)
                    NavigationLink(L10n.lookup("余额查询设置")) {
                        ProviderBalanceSettingsView(configuration: $configuration, query: balanceQuery)
                    }
                }

                NavigationLink {
                    ProviderProxySettingsView(proxy: $configuration.proxy)
                } label: {
                    LabeledContent(L10n.lookup("网络代理"), value: configuration.proxy.isUsable ? L10n.lookup("已配置") : L10n.lookup("跟随全局"))
                }
            }

            Section(L10n.lookup("连接")) {
                TextField(L10n.lookup("名称"), text: $configuration.name)
                if !configuration.multiKeyEnabled {
                    SecureField("API Key", text: $configuration.apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("API Base URL", text: $configuration.baseURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if configuration.type == .openAI && !configuration.useResponsesAPI {
                    TextField(L10n.lookup("API 路径"), text: $configuration.chatPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Picker(L10n.lookup("图像生成接口"), selection: $configuration.imageGenerationMode) {
                    ForEach(ProviderImageGenerationMode.allCases) { mode in
                        Text(L10n.lookup(mode.title)).tag(mode)
                    }
                }
            } header: {
                Text(L10n.lookup("图像生成"))
            } footer: {
                Text(L10n.lookup("自动识别已支持的图像接口。其他兼容服务可手动选择接口类型；关闭后不会出现在助手的图像模型列表中。"))
            }

            keyValueSection(
                title: L10n.lookup("自定义 Header"),
                fields: $configuration.customHeaders,
                namePlaceholder: L10n.lookup("Header 名"),
                valuePlaceholder: L10n.lookup("值")
            )

            keyValueSection(
                title: L10n.lookup("自定义 Body"),
                fields: $configuration.customBody,
                namePlaceholder: L10n.lookup("字段名"),
                valuePlaceholder: L10n.lookup("JSON 值")
            )
        }
        .settingsGroupedPageStyle()
    }

    private func keyValueSection(
        title: String,
        fields: Binding<[KeyValueField]>,
        namePlaceholder: String,
        valuePlaceholder: String
    ) -> some View {
        Section {
            ForEach(fields) { $field in
                HStack(spacing: 8) {
                    TextField(namePlaceholder, text: $field.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Divider()
                    TextField(valuePlaceholder, text: $field.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .onDelete { offsets in
                fields.wrappedValue.remove(atOffsets: offsets)
            }
            Button {
                fields.wrappedValue.append(KeyValueField())
            } label: {
                Label(L10n.lookup("添加"), systemImage: "plus")
            }
        } header: {
            Text(title)
        }
    }

    private var editorTabBar: some View {
        HStack(spacing: 8) {
            ForEach(ProviderEditorTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? themeAccent : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selectedTab == tab ? themeAccent.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func save() {
        guard canSave else { return }
        configuration.name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.chatPath = configuration.chatPath.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.group = configuration.group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard onSave(configuration) else {
            saveErrorMessage = L10n.lookup("供应商配置没有安全写入，原头像仍保留。请再试一次。")
            isSaveErrorPresented = true
            return
        }
        didSave = true
        balanceQuery.cancel()
        if originalAvatar != configuration.customAvatar {
            AssistantMediaStore.remove(originalAvatar)
        }
        dismiss()
    }

    private var hasUnsavedChanges: Bool {
        !didSave && configuration != originalConfiguration
    }

    private var canSave: Bool {
        !configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            isLeaveConfirmationPresented = true
        } else {
            discardAndDismiss()
        }
    }

    private func discardAndDismiss() {
        balanceQuery.cancel()
        cleanUpAvatarIfNeeded()
        dismiss()
    }

    private func cleanUpAvatarIfNeeded() {
        guard !didSave, originalAvatar != configuration.customAvatar else { return }
        AssistantMediaStore.remove(configuration.customAvatar)
    }

    private var iconDescription: String {
        if AssistantMediaStore.hasImage(for: configuration.customAvatar) {
            return L10n.lookup("已选择自定义图片")
        }
        if configuration.customAvatar != nil {
            return L10n.lookup("原图片文件缺失，当前使用自动头像")
        }
        if let brandIcon = configuration.brandIcon {
            return L10n.format("已选择：%@", [String(describing: brandIcon.title)])
        }
        if let inferred = configuration.resolvedBrandIcon {
            return L10n.format("自动识别：%@", [String(describing: inferred.title)])
        }
        return L10n.lookup("自动显示名称首字")
    }
}

private struct ProviderIconPickerView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: ProviderBrandIcon?
    @Binding var customAvatar: String?
    let providerID: UUID
    let providerName: String
    let baseURL: String
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage = ""
    @State private var isErrorPresented = false

    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 10)]

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    private var automaticIcon: ProviderBrandIcon? {
        ProviderBrandIcon.inferred(name: providerName, baseURL: baseURL)
    }

    var body: some View {
        List {
            Section(L10n.lookup("自定义图片")) {
                if customAvatar != nil {
                    HStack(spacing: 12) {
                        ProviderCustomAvatar(reference: customAvatar, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.lookup("当前自定义头像"))
                                .foregroundStyle(.primary)
                            Text(
                                AssistantMediaStore.hasImage(for: customAvatar)
                                    ? L10n.lookup("会显示在供应商列表、模型列表和模型选择器中")
                                    : L10n.lookup("原图片文件缺失，其他页面会安全回退到自动头像")
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let photoPickerTitle = L10n.lookup("选择或更换照片")
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(photoPickerTitle, systemImage: "photo.badge.plus")
                }
                if customAvatar != nil {
                    Button(role: .destructive) {
                        customAvatar = nil
                    } label: {
                        Label(L10n.lookup("移除自定义图片"), systemImage: "trash")
                    }
                }
            }

            Section(L10n.lookup("自动识别")) {
                Button {
                    selection = nil
                    customAvatar = nil
                } label: {
                    HStack(spacing: 12) {
                        ProviderBrandMark(
                            icon: automaticIcon,
                            fallbackText: providerName,
                            size: 42
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.lookup("跟随名称和 API 地址"))
                                .foregroundStyle(.primary)
                            Text(automaticIcon.map { L10n.format("当前识别为 %@", [String(describing: $0.title)]) } ?? L10n.lookup("当前使用名称首字"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == nil && customAvatar == nil {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(themeAccent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ProviderBrandIcon.selectableCases) { icon in
                        Button {
                            selection = icon
                            customAvatar = nil
                        } label: {
                            VStack(spacing: 7) {
                                ProviderBrandMark(icon: icon, fallbackText: icon.title, size: 44)
                                Text(L10n.lookup(icon.title))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(selection == icon && customAvatar == nil
                                          ? themeAccent.opacity(0.12)
                                          : Color.primary.opacity(0.035))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(
                                        selection == icon && customAvatar == nil
                                            ? themeAccent.opacity(0.55)
                                            : Color.primary.opacity(0.08),
                                        lineWidth: selection == icon ? 1.2 : 0.6
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup(icon.title))
                        .accessibilityValue(selection == icon && customAvatar == nil ? L10n.lookup("已选择") : "")
                    }
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text(L10n.lookup("品牌图标"))
            } footer: {
                Text(L10n.lookup("图标只用于辨认服务商，不会修改接口类型、地址或模型。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("服务商头像"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photoItem) {
            guard let item = photoItem else { return }
            do {
                let data = try await item.loadTransferable(type: Data.self)
                guard !Task.isCancelled else { return }
                guard let data, let image = UIImage(data: data),
                      let reference = AssistantMediaStore.saveAvatar(image, assistantID: providerID) else {
                    throw AIChatServiceError.invalidResponse
                }
                customAvatar = reference
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = L10n.lookup("无法读取这张图片，请换一张再试。")
                isErrorPresented = true
            }
            photoItem = nil
        }
        .alert(L10n.lookup("无法选择头像"), isPresented: $isErrorPresented) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

private struct ProviderCustomAvatar: View {
    let reference: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = AssistantMediaStore.image(for: reference) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Color.primary.opacity(0.045)))
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

private struct ProviderMultiKeyView: View {
    @Binding var apiKeys: [ProviderAPIKey]

    var body: some View {
        List {
            Section {
                if apiKeys.isEmpty {
                    ContentUnavailableView(
                        L10n.lookup("还没有 API Key"),
                        systemImage: "key",
                        description: Text(L10n.lookup("添加后，每次请求会从已启用的 Key 中随机选择"))
                    )
                }
                ForEach($apiKeys) { $item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField(L10n.lookup("备注名称"), text: $item.name)
                            Toggle(L10n.lookup("启用"), isOn: $item.enabled)
                                .labelsHidden()
                        }
                        SecureField("API Key", text: $item.key)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { apiKeys.remove(atOffsets: $0) }
            } footer: {
                Text(L10n.lookup("请求会在已启用且非空的 Key 中随机选择；Key 会存入系统钥匙串。"))
            }

            Button {
                apiKeys.append(ProviderAPIKey(name: "Key \(apiKeys.count + 1)"))
            } label: {
                Label(L10n.lookup("添加 API Key"), systemImage: "plus")
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("多 Key 模式"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProviderProxySettingsView: View {
    @Binding var proxy: ProviderProxySettings

    var body: some View {
        Form {
            Section {
                Toggle(L10n.lookup("为这个供应商单独使用代理"), isOn: $proxy.enabled)
                TextField(L10n.lookup("代理地址"), text: $proxy.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.lookup("端口"), text: $proxy.port)
                    .keyboardType(.numberPad)
            } footer: {
                Text(L10n.lookup("关闭时跟随偏好设置中的全局代理；打开后仅覆盖这个供应商。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("网络代理"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Only inputs consumed by the balance request participate in invalidation.
/// Secrets stay in memory; this identity is never printed or persisted.
private struct ProviderBalanceQueryKey: Equatable {
    let providerID: UUID
    let type: ProviderType
    let balanceEnabled: Bool
    let baseURL: String
    let apiKey: String
    let multiKeyEnabled: Bool
    let apiKeys: [String]
    let headers: [KeyValueField]
    let path: String
    let resultPath: String
    let proxy: ProviderProxySettings
    let isOpenRouter: Bool

    init(_ provider: ProviderConfiguration) {
        providerID = provider.id
        type = provider.type
        balanceEnabled = provider.balanceEnabled
        baseURL = provider.baseURL
        apiKey = provider.multiKeyEnabled ? "" : provider.apiKey
        multiKeyEnabled = provider.multiKeyEnabled
        apiKeys = provider.multiKeyEnabled ? provider.enabledAPIKeys.map(\.key) : []
        headers = provider.customHeaders
        path = provider.balanceAPIPath
        resultPath = provider.balanceResultPath
        proxy = provider.proxy
        isOpenRouter = provider.isOpenRouter
    }

    @MainActor static func unavailableReason(for provider: ProviderConfiguration) -> String? {
        guard provider.balanceEnabled else { return L10n.lookup("余额查询已关闭") }
        guard provider.hasUsableAPIKey else { return L10n.lookup("填写可用的 API Key 后可查询") }
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return L10n.lookup("填写有效的 API 地址后可查询") }
        return nil
    }
}

@MainActor
@Observable
private final class ProviderBalanceQueryState {
    private(set) var result: ProviderBalanceResult?
    private(set) var errorMessage: String?
    private(set) var isFetching = false
    private var key: ProviderBalanceQueryKey?
    private var visibleSurfaces = Set<UUID>()
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var hasAttemptedCurrentQuery = false
    private let debounce: Duration
    private let timeout: Duration
    private let fetch: @Sendable (ProviderConfiguration) async throws -> ProviderBalanceResult

    init(
        debounce: Duration = .milliseconds(450),
        timeout: Duration = .seconds(15),
        fetch: @escaping @Sendable (ProviderConfiguration) async throws -> ProviderBalanceResult = {
            try await AIChatService.fetchBalance(for: $0)
        }
    ) {
        self.debounce = debounce
        self.timeout = timeout
        self.fetch = fetch
    }

    func matches(_ provider: ProviderConfiguration) -> Bool { key == ProviderBalanceQueryKey(provider) }

    func show(_ surfaceID: UUID, provider: ProviderConfiguration) {
        visibleSurfaces.insert(surfaceID)
        update(surfaceID, provider: provider)
    }

    func update(_ surfaceID: UUID, provider: ProviderConfiguration) {
        guard visibleSurfaces.contains(surfaceID) else { return }
        let nextKey = ProviderBalanceQueryKey(provider)
        if key != nextKey {
            cancel()
            key = nextKey
            result = nil
            errorMessage = nil
            hasAttemptedCurrentQuery = false
        }
        guard ProviderBalanceQueryKey.unavailableReason(for: provider) == nil,
              !hasAttemptedCurrentQuery, task == nil else { return }
        start(provider, delayed: true)
    }

    func hide(_ surfaceID: UUID) {
        visibleSurfaces.remove(surfaceID)
        if visibleSurfaces.isEmpty { cancel() }
    }

    func refresh(_ surfaceID: UUID, provider: ProviderConfiguration) {
        guard visibleSurfaces.contains(surfaceID),
              ProviderBalanceQueryKey.unavailableReason(for: provider) == nil else { return }
        cancel()
        let nextKey = ProviderBalanceQueryKey(provider)
        if key != nextKey { result = nil }
        key = nextKey
        start(provider, delayed: false)
    }

    func cancel() {
        if task != nil { hasAttemptedCurrentQuery = false }
        generation = nil
        task?.cancel()
        task = nil
        isFetching = false
    }

    private func start(_ provider: ProviderConfiguration, delayed: Bool) {
        let requestID = UUID()
        let requestKey = ProviderBalanceQueryKey(provider)
        let fetch = fetch
        let timeout = timeout
        let debounce = debounce
        generation = requestID
        isFetching = true
        errorMessage = nil
        task = Task { [weak self] in
            do {
                if delayed { try await Task.sleep(for: debounce) }
                try Task.checkCancellation()
                let value = try await withThrowingTaskGroup(of: ProviderBalanceResult.self) { group in
                    group.addTask { try await fetch(provider) }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    guard let value = try await group.next() else { throw CancellationError() }
                    return value
                }
                guard !Task.isCancelled, let self,
                      self.generation == requestID, self.key == requestKey,
                      !self.visibleSurfaces.isEmpty else { return }
                self.result = value
                self.complete()
            } catch {
                guard !Task.isCancelled, let self,
                      self.generation == requestID, self.key == requestKey,
                      !self.visibleSurfaces.isEmpty else { return }
                self.errorMessage = (error as? URLError)?.code == .timedOut
                    ? L10n.lookup("查询超时，可稍后刷新")
                    : L10n.lookup("查询失败，请检查余额接口设置后重试")
                self.complete()
            }
        }
    }

    private func complete() {
        generation = nil
        task = nil
        isFetching = false
        hasAttemptedCurrentQuery = true
    }
}

private struct ProviderBalanceSummaryView: View {
    let configuration: ProviderConfiguration
    let query: ProviderBalanceQueryState
    @State private var surfaceID = UUID()

    private var unavailableReason: String? {
        ProviderBalanceQueryKey.unavailableReason(for: configuration)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.lookup("账户余额"))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if query.matches(configuration), query.isFetching {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    query.refresh(surfaceID, provider: configuration)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .disabled(unavailableReason != nil)
                .accessibilityLabel(L10n.lookup("刷新账户余额"))
            }
        }
        .onAppear { query.show(surfaceID, provider: configuration) }
        .onChange(of: ProviderBalanceQueryKey(configuration)) { _, _ in
            query.update(surfaceID, provider: configuration)
        }
        .onDisappear { query.hide(surfaceID) }
    }

    private var summary: String {
        if let unavailableReason { return unavailableReason }
        guard query.matches(configuration) else { return L10n.lookup("等待查询") }
        return query.errorMessage ?? query.result?.localizedText ?? (query.isFetching ? L10n.lookup("正在查询…") : L10n.lookup("等待查询"))
    }
}

private struct ProviderBalanceSettingsView: View {
    @Binding var configuration: ProviderConfiguration
    let query: ProviderBalanceQueryState

    var body: some View {
        Form {
            Section(L10n.lookup("查询接口")) {
                TextField(L10n.lookup("余额 API 路径"), text: $configuration.balanceAPIPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.lookup("结果 JSON 路径"), text: $configuration.balanceResultPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                ProviderBalanceSummaryView(configuration: configuration, query: query)
            } footer: {
                Text(configuration.isOpenRouter
                     ? L10n.lookup("自动读取总额度与已用额度，并计算剩余额度。")
                     : L10n.lookup("JSON 路径示例：data.balance；数组下标也可写成 data.0.amount。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("账户余额"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProviderModelsWorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var configuration: ProviderConfiguration
    @State private var isCatalogPresented = false
    @State private var isAddPresented = false
    @State private var isDeleteAllPresented = false
    @State private var manualModelID = ""
    @State private var editingItem: ModelSelectorItem?

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(configuration.models) { model in
                    modelRow(model)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                configuration.models.removeAll { $0.id == model.id }
                            } label: {
                                Label(L10n.lookup("删除"), systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 9, for: .scrollContent)
            .overlay {
                if configuration.models.isEmpty {
                    ContentUnavailableView(
                        L10n.lookup("还没有模型"),
                        systemImage: "cube.transparent",
                        description: Text(L10n.lookup("点下方“选择模型”从供应商目录添加，或手动输入模型 ID"))
                    )
                }
            }

            modelActionBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $isCatalogPresented) {
            ProviderModelManagerView(
                configuration: configuration,
                models: $configuration.models
            )
            .presentationDetents([.fraction(0.70), .fraction(0.82)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(item: $editingItem) { item in
            ModelConfigurationEditorSheet(item: item) { updated in
                guard let index = configuration.models.firstIndex(where: { $0.id == updated.id }) else { return false }
                configuration.models[index] = updated
                return true
            }
        }
        .alert(L10n.lookup("添加模型"), isPresented: $isAddPresented) {
            TextField(L10n.lookup("模型 ID"), text: $manualModelID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.lookup("取消"), role: .cancel) { manualModelID = "" }
            Button(L10n.lookup("添加")) { addManualModel() }
        } message: {
            Text(L10n.lookup("输入供应商使用的完整模型 ID。"))
        }
        .confirmationDialog(L10n.lookup("删除全部模型？"), isPresented: $isDeleteAllPresented, titleVisibility: .visible) {
            Button(L10n.lookup("删除全部"), role: .destructive) { configuration.models.removeAll() }
            Button(L10n.lookup("取消"), role: .cancel) {}
        }
    }

    private func modelRow(_ model: ModelConfiguration) -> some View {
        Button {
            editingItem = ModelSelectorItem(provider: configuration, model: model)
        } label: {
            HStack(spacing: 12) {
                ProviderGlyph(provider: configuration, size: 42)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.displayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if model.displayName != model.id {
                        Text(model.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ProviderModelCapabilityChips(capabilities: model.capabilities)
                }
                Spacer(minLength: 4)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                configuration.models.removeAll { $0.id == model.id }
            } label: {
                Label(L10n.lookup("删除模型"), systemImage: "trash")
            }
        }
    }

    private var modelActionBar: some View {
        HStack(spacing: 10) {
            actionButton(L10n.lookup("选择模型"), systemImage: "checklist") {
                isCatalogPresented = true
            }
            actionButton(L10n.lookup("手动添加"), systemImage: "plus") {
                isAddPresented = true
            }
            Button(role: .destructive) {
                isDeleteAllPresented = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 48, height: 46)
                    .background(Capsule().fill(Color.red.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .disabled(configuration.models.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(themeAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Capsule().fill(themeAccent.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private func addManualModel() {
        let id = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !configuration.models.contains(where: { $0.id == id }) else {
            manualModelID = ""
            return
        }
        configuration.models.append(ModelConfiguration(id: id))
        manualModelID = ""
    }
}

private struct ModelModalityMarkers: View {
    let capabilities: ModelCapabilities

    var body: some View {
        HStack(spacing: 4) {
            ForEach(capabilities.input, id: \.self) { modality in
                marker(modality)
            }
            Image(systemName: "chevron.right")
            ForEach(capabilities.output, id: \.self) { modality in
                marker(modality)
            }
        }
    }

    @ViewBuilder
    private func marker(_ modality: ModelModality) -> some View {
        switch modality {
        case .text:
            AppSymbolImage(systemName: "textformat")
        case .image:
            Image(systemName: "photo")
        }
    }
}

private struct ProviderModelCapabilityChips: View {
    let capabilities: ModelCapabilities

    var body: some View {
        ProviderCapabilityFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
            chip(L10n.lookup(capabilities.kind.title), systemImage: capabilities.kind == .chat ? "bubble.left" : "number")
            chip {
                ModelModalityMarkers(capabilities: capabilities)
            }
            ForEach(capabilities.abilities, id: \.self) { ability in
                chip(ability.shortTitle, systemImage: ability.systemImage)
            }
        }
    }

    private func chip(_ title: String, systemImage: String) -> some View {
        chip {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 12, height: 12)
                Text(title)
            }
        }
    }

    private func chip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ProviderCapabilityFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var usedHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let spacing = rowWidth == 0 ? 0 : horizontalSpacing
            if rowWidth > 0, rowWidth + spacing + size.width > maximumWidth {
                usedWidth = max(usedWidth, rowWidth)
                usedHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += spacing + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        usedWidth = max(usedWidth, rowWidth)
        usedHeight += rowHeight
        return CGSize(width: min(usedWidth, maximumWidth), height: usedHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedX = x == bounds.minX ? x : x + horizontalSpacing
            if x > bounds.minX, proposedX + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            } else {
                x = proposedX
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ProviderModelCatalogGroup: Identifiable {
    let name: String
    let models: [ModelConfiguration]

    var id: String { name }

    @MainActor var localizedName: String {
        switch name {
        case "嵌入模型", "其他模型": L10n.lookup(name)
        default: name
        }
    }
}

private struct ProviderModelManagerView: View {
    let configuration: ProviderConfiguration
    @Binding var models: [ModelConfiguration]

    @State private var catalog: [ModelConfiguration]
    @State private var query = ""
    @State private var collapsedGroups = Set<String>()
    @State private var isFetchingModels = false
    @State private var hasRequestedModels = false
    @State private var loadMessage: String?
    @FocusState private var isSearchFocused: Bool

    init(configuration: ProviderConfiguration, models: Binding<[ModelConfiguration]>) {
        let initialModels = models.wrappedValue.sorted(by: Self.modelSort)
        self.configuration = configuration
        _models = models
        _catalog = State(initialValue: initialModels)
    }

    private var selectedIDs: Set<String> {
        Set(models.map(\.id))
    }

    private var hasAPIKey: Bool {
        if configuration.multiKeyEnabled {
            return !configuration.enabledAPIKeys.isEmpty
        }
        return !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasBaseURL: Bool {
        !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredCatalog: [ModelConfiguration] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return catalog }
        return catalog.filter { model in
            model.id.lowercased().contains(normalizedQuery)
                || model.displayName.lowercased().contains(normalizedQuery)
        }
    }

    private var groupedCatalog: [ProviderModelCatalogGroup] {
        Dictionary(grouping: filteredCatalog) {
            ProviderModelGrouping.group(for: $0)
        }
            .map { name, groupedModels in
                ProviderModelCatalogGroup(
                    name: name,
                    models: groupedModels.sorted(by: Self.modelSort)
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var allFilteredSelected: Bool {
        !filteredCatalog.isEmpty && filteredCatalog.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchControls
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 9)

            catalogSummary
                .padding(.horizontal, 19)
                .padding(.bottom, 8)

            if let loadMessage {
                loadMessageCard(loadMessage)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredCatalog.isEmpty {
                        emptyCatalogView
                            .padding(.top, 42)
                    } else {
                        ForEach(groupedCatalog) { group in
                            groupHeader(group)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .padding(.bottom, 5)

                            if !collapsedGroups.contains(group.id) {
                                ForEach(group.models) { model in
                                    modelSelectionRow(model)
                                    Divider()
                                        .padding(.leading, 68)
                                        .padding(.trailing, 18)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            await loadModelsOnce()
        }
    }

    private var searchControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.lookup("输入模型名称或 ID 筛选"), text: $query)
                .focused($isSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { isSearchFocused = false }

            Button {
                toggleAllFiltered()
            } label: {
                Image(systemName: allFilteredSelected ? "square" : "checkmark.square")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(filteredCatalog.isEmpty)
            .accessibilityLabel(allFilteredSelected ? L10n.lookup("取消选择当前结果") : L10n.lookup("选择全部当前结果"))

            Button {
                invertFilteredSelection()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(filteredCatalog.isEmpty)
            .accessibilityLabel(L10n.lookup("反选当前结果"))
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
        }
    }

    private var catalogSummary: some View {
        HStack(spacing: 8) {
            Text(L10n.format("模型目录 · 已选 %@ / %@", [String(describing: models.count), String(describing: catalog.count)]))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if isFetchingModels {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.lookup("正在获取最新目录"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.format("%@ 个分类", [String(describing: groupedCatalog.count)]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20)
    }

    private func loadMessageCard(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            if hasBaseURL && hasAPIKey {
                Button(L10n.lookup("重试")) {
                    Task { await fetchModels() }
                }
                .font(.caption.weight(.semibold))
                .disabled(isFetchingModels)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    @ViewBuilder
    private var emptyCatalogView: some View {
        if isFetchingModels {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.lookup("正在获取模型目录"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                L10n.lookup("还没有模型"),
                systemImage: "cube.transparent",
                description: Text(L10n.lookup("请先补全 API 信息，或返回使用“手动添加”"))
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func groupHeader(_ group: ProviderModelCatalogGroup) -> some View {
        let isCollapsed = collapsedGroups.contains(group.id)
        let selectedCount = group.models.filter { selectedIDs.contains($0.id) }.count
        let allSelected = !group.models.isEmpty && selectedCount == group.models.count

        return HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.20)) {
                    if isCollapsed {
                        collapsedGroups.remove(group.id)
                    } else {
                        collapsedGroups.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: 22, height: 22)

                    Text(group.localizedName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(selectedCount)/\(group.models.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("%@，%@ / %@ 已选", [group.localizedName, String(describing: selectedCount), String(describing: group.models.count)]))
            .accessibilityValue(isCollapsed ? L10n.lookup("已折叠") : L10n.lookup("已展开"))

            Button {
                toggle(group)
            } label: {
                Image(systemName: allSelected ? "minus" : "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(allSelected ? L10n.format("取消选择整个 %@ 分类", [group.localizedName]) : L10n.format("选择整个 %@ 分类", [group.localizedName]))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func modelSelectionRow(_ model: ModelConfiguration) -> some View {
        let isSelected = selectedIDs.contains(model.id)

        return Button {
            toggle(model)
        } label: {
            HStack(spacing: 13) {
                ProviderModelCatalogGlyph(model: model, size: 31)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if model.displayName != model.id {
                        Text(model.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    ProviderModelCapabilityChips(capabilities: model.capabilities)
                }

                Spacer(minLength: 5)

                Image(systemName: isSelected ? "minus" : "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.displayName)
        .accessibilityValue(isSelected ? L10n.lookup("已选择") : L10n.lookup("未选择"))
        .accessibilityHint(isSelected ? L10n.lookup("轻点取消选择") : L10n.lookup("轻点选择"))
    }

    private func toggle(_ model: ModelConfiguration) {
        withAnimation(.snappy(duration: 0.18)) {
            if let index = models.firstIndex(where: { $0.id == model.id }) {
                models.remove(at: index)
            } else {
                models.append(model)
            }
        }
    }

    private func toggle(_ group: ProviderModelCatalogGroup) {
        let groupIDs = Set(group.models.map(\.id))
        let allSelected = group.models.allSatisfy { selectedIDs.contains($0.id) }
        withAnimation(.snappy(duration: 0.18)) {
            if allSelected {
                models.removeAll { groupIDs.contains($0.id) }
            } else {
                appendMissing(group.models)
            }
        }
    }

    private func toggleAllFiltered() {
        let filteredIDs = Set(filteredCatalog.map(\.id))
        withAnimation(.snappy(duration: 0.18)) {
            if allFilteredSelected {
                models.removeAll { filteredIDs.contains($0.id) }
            } else {
                appendMissing(filteredCatalog)
            }
        }
    }

    private func invertFilteredSelection() {
        let originallySelected = selectedIDs
        let filteredIDs = Set(filteredCatalog.map(\.id))
        let additions = filteredCatalog.filter { !originallySelected.contains($0.id) }

        withAnimation(.snappy(duration: 0.18)) {
            models.removeAll {
                filteredIDs.contains($0.id) && originallySelected.contains($0.id)
            }
            appendMissing(additions)
        }
    }

    private func appendMissing(_ candidates: [ModelConfiguration]) {
        var existingIDs = Set(models.map(\.id))
        for model in candidates where existingIDs.insert(model.id).inserted {
            models.append(model)
        }
    }

    @MainActor
    private func loadModelsOnce() async {
        guard !hasRequestedModels else { return }
        hasRequestedModels = true
        await fetchModels()
    }

    @MainActor
    private func fetchModels() async {
        guard hasBaseURL else {
            loadMessage = L10n.lookup("请先返回“配置”填写 API 地址；现有已选模型仍可管理。")
            return
        }
        guard hasAPIKey else {
            loadMessage = configuration.multiKeyEnabled
                ? L10n.lookup("请先返回“配置”添加至少一个已启用的 API Key；现有已选模型仍可管理。")
                : L10n.lookup("请先返回“配置”填写 API Key；现有已选模型仍可管理。")
            return
        }

        isFetchingModels = true
        loadMessage = nil
        defer { isFetchingModels = false }

        do {
            let fetched = try await AIChatService.fetchModels(for: configuration)
            mergeCatalog(fetched)
        } catch {
            loadMessage = L10n.format("获取最新目录失败：%@", [String(describing: error.localizedDescription)])
        }
    }

    private func mergeCatalog(_ incoming: [ModelConfiguration]) {
        var merged: [String: ModelConfiguration] = [:]
        for model in catalog {
            merged[model.id] = model
        }
        for fetched in incoming {
            if let existing = merged[fetched.id] {
                merged[fetched.id] = merging(existing: existing, fetched: fetched)
            } else {
                merged[fetched.id] = fetched
            }
        }
        catalog = Array(merged.values).sorted(by: Self.modelSort)
    }

    private func merging(
        existing: ModelConfiguration,
        fetched: ModelConfiguration
    ) -> ModelConfiguration {
        var result = existing
        if existing.displayName == existing.id, fetched.displayName != fetched.id {
            result.displayName = fetched.displayName
        }
        return result
    }

    private static func modelSort(
        _ lhs: ModelConfiguration,
        _ rhs: ModelConfiguration
    ) -> Bool {
        let displayOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if displayOrder != .orderedSame {
            return displayOrder == .orderedAscending
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }
}

private struct ProviderModelCatalogGlyph: View {
    let model: ModelConfiguration
    var size: CGFloat

    var body: some View {
        ProviderBrandMark(
            icon: ProviderBrandIcon.inferred(
                name: "\(model.id) \(model.displayName)",
                baseURL: ""
            ),
            fallbackText: ProviderModelGrouping.group(for: model),
            size: size
        )
        .accessibilityHidden(true)
    }
}

struct ModelSelectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var activeProviderID: UUID?
    @State private var editingModelItem: ModelSelectorItem?
    @State private var pressedModelKey: String?
    @FocusState private var searchFocused: Bool
    let context: SettingsPageContext
    let selectedSelection: ModelSelection?
    let inheritedChoiceTitle: String?
    let screenTitle: String
    let chatOnly: Bool
    let visionOnly: Bool
    let onSelect: ((ModelSelection?) -> Void)?

    init(
        context: SettingsPageContext = .sheet,
        selectedSelection: ModelSelection? = nil,
        inheritedChoiceTitle: String? = nil,
        screenTitle: String = L10n.lookup("默认模型"),
        chatOnly: Bool = false,
        visionOnly: Bool = false,
        onSelect: ((ModelSelection?) -> Void)? = nil
    ) {
        self.context = context
        self.selectedSelection = selectedSelection
        self.inheritedChoiceTitle = inheritedChoiceTitle
        self.screenTitle = screenTitle
        self.chatOnly = chatOnly
        self.visionOnly = visionOnly
        self.onSelect = onSelect
    }

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    private var availableProviders: [ProviderConfiguration] {
        model.providers.filter { $0.enabled && !selectableModels(for: $0).isEmpty }
    }

    private var allItems: [ModelSelectorItem] {
        availableProviders.flatMap { provider in
            selectableModels(for: provider).map { ModelSelectorItem(provider: provider, model: $0) }
        }
    }

    private var currentSelection: ModelSelection? {
        onSelect == nil ? model.selectedModel : selectedSelection
    }

    private var favoriteItems: [ModelSelectorItem] {
        allItems.filter { item in
            model.isFavoriteModel(providerID: item.provider.id, modelID: item.model.id)
        }
    }

    private var filteredFavorites: [ModelSelectorItem] {
        favoriteItems.filter(matches)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if context == .sheet {
                    Capsule()
                        .fill(Color.secondary.opacity(0.38))
                        .frame(width: 50, height: 5)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    HStack {
                        Spacer()

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.primary.opacity(0.055)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("关闭模型选择"))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .padding(.bottom, 4)
                }

                searchField(proxy: proxy)
                    .padding(.horizontal, 18)
                    .padding(.top, context == .navigation ? 12 : 0)
                    .padding(.bottom, 8)

                if availableProviders.isEmpty && inheritedChoiceTitle == nil {
                    ContentUnavailableView(
                        L10n.lookup("还没有可用模型"),
                        systemImage: "cpu",
                        description: Text(L10n.lookup("先在服务商设置中添加或获取模型"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 28)
                } else {
                    modelList(proxy: proxy)

                    if availableProviders.count > 1 {
                        providerTabs(proxy: proxy)
                    }
                }
            }
            .background {
                if context == .navigation {
                    Color(uiColor: .systemGroupedBackground)
                }
            }
        }
        .modifier(ModelSelectorContextModifier(context: context, screenTitle: screenTitle))
        .sheet(item: $editingModelItem) { item in
            ModelConfigurationEditorSheet(item: item)
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Color(uiColor: .systemBackground))
        }
    }

    private func searchField(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.lookup("搜索模型或服务商"), text: $query)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    favoritesOnly.toggle()
                    searchFocused = false
                    if favoritesOnly {
                        withAnimation(.snappy) {
                            proxy.scrollTo("favorites", anchor: .top)
                        }
                    }
                } label: {
                    Image(systemName: favoritesOnly ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(favoritesOnly ? themeAccent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(favoriteItems.isEmpty)
                .opacity(favoriteItems.isEmpty ? 0.38 : 1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(ModelSelectorControlBackground(cornerRadius: 18, accent: themeAccent))
    }

    private func modelList(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let inheritedChoiceTitle {
                    inheritedChoiceCard(title: inheritedChoiceTitle)
                        .id("inherited-choice")
                }

                if !filteredFavorites.isEmpty {
                    sectionHeader(L10n.lookup("收藏"), systemImage: "heart.fill")
                        .id("favorites")
                    ForEach(filteredFavorites, id: \.favoriteID) { item in
                        modelCard(item, showsProvider: true)
                    }
                } else if favoritesOnly {
                    ContentUnavailableView(L10n.lookup("还没有收藏"), systemImage: "heart", description: Text(L10n.lookup("点模型右侧的心形就会收进这里")))
                        .padding(.vertical, 44)
                }

                if !favoritesOnly {
                    ForEach(availableProviders) { provider in
                        let items = filteredItems(for: provider)
                        if !items.isEmpty {
                            providerSectionHeader(provider)
                                .id("provider-\(provider.id.uuidString)")
                            ForEach(items, id: \.providerID) { item in
                                modelCard(item, showsProvider: false)
                            }
                        }
                    }
                }

                if !favoritesOnly && allItems.filter(matches).isEmpty && inheritedChoiceTitle == nil {
                    ContentUnavailableView(L10n.lookup("没有找到模型"), systemImage: "magnifyingglass", description: Text(L10n.lookup("换个关键词试试看")))
                        .padding(.vertical, 44)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, availableProviders.count > 1 ? 12 : 26)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(systemImage == "heart.fill" ? Color.red : themeAccent)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func providerSectionHeader(_ provider: ProviderConfiguration) -> some View {
        HStack(spacing: 8) {
            ProviderGlyph(provider: provider, size: 26)
            Text(provider.name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if provider.balanceEnabled {
                ModelSelectorProviderBalance(configuration: provider)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func modelCard(_ item: ModelSelectorItem, showsProvider: Bool) -> some View {
        let selection = ModelSelection(providerID: item.provider.id, modelID: item.model.id)
        let isSelected = currentSelection == selection
        let isFavorite = model.isFavoriteModel(providerID: item.provider.id, modelID: item.model.id)

        return HStack(spacing: 10) {
            HStack(spacing: 12) {
                modelAvatar(item)
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            ZStack {
                                Circle()
                                    .fill(Color.primary)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                            }
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                            )
                            .offset(x: 2, y: 2)
                        }
                    }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Text(item.model.displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if showsProvider {
                            Text("| \(item.provider.name)")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    modelTags(item)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                select(selection)
            }
            .onLongPressGesture(
                minimumDuration: 0.38,
                maximumDistance: 18,
                pressing: { isPressing in
                    withAnimation(.snappy(duration: 0.18)) {
                        pressedModelKey = isPressing ? item.identity : nil
                    }
                },
                perform: {
                    editingModelItem = item
                }
            )

            Button {
                model.toggleFavoriteModel(providerID: item.provider.id, modelID: item.model.id)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(
                        isFavorite
                            ? Color.red
                            : Color.secondary.opacity(0.58)
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? L10n.lookup("取消收藏模型") : L10n.lookup("收藏模型"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(modelCardBackground(selected: isSelected))
        .scaleEffect(pressedModelKey == item.identity ? 0.985 : 1)
        .animation(.snappy(duration: 0.18), value: pressedModelKey)
    }

    private func inheritedChoiceCard(title: String) -> some View {
        let isSelected = currentSelection == nil

        return Button {
            select(nil)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(themeAccent.opacity(0.11))
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(themeAccent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.lookup("未单独指定时使用此选项"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(modelCardBackground(selected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? L10n.lookup("已选择") : L10n.lookup("未选择"))
    }

    private func select(_ selection: ModelSelection?) {
        if let onSelect {
            onSelect(selection)
        } else if let selection {
            model.selectModel(providerID: selection.providerID, modelID: selection.modelID)
        }
        dismiss()
    }

    private func modelAvatar(_ item: ModelSelectorItem) -> some View {
        ProviderGlyph(provider: item.provider, size: 44)
    }

    private func modelTags(_ item: ModelSelectorItem) -> some View {
        let capabilities = item.model.capabilities
        return HStack(spacing: 6) {
            tag(text: L10n.lookup(capabilities.kind.title), color: themeAccent)
            tagIcons(item, capabilities: capabilities)
            ForEach(capabilities.abilities, id: \.self) { ability in
                abilityTag(ability)
            }
            providerTypeTag(item.provider.type)
        }
        .lineLimit(1)
    }

    private func tag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 0.6))
    }

    private func tagIcons(_ item: ModelSelectorItem, capabilities: ModelCapabilities) -> some View {
        ModelModalityMarkers(capabilities: capabilities)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(themeAccent)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(themeAccent.opacity(0.11)))
        .overlay(Capsule().stroke(themeAccent.opacity(0.18), lineWidth: 0.6))
        .accessibilityLabel(L10n.format("%@ 输入输出模态", [String(describing: item.model.displayName)]))
    }

    private func abilityTag(_ ability: ModelAbility) -> some View {
        Image(systemName: ability.systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(themeAccent)
            .frame(width: 28, height: 24)
            .background(Capsule().fill(themeAccent.opacity(0.11)))
            .overlay(Capsule().stroke(themeAccent.opacity(0.18), lineWidth: 0.6))
            .accessibilityLabel(L10n.lookup(ability.title))
    }

    private func providerTypeTag(_ type: ProviderType) -> some View {
        Image(type.brandIcon.assetName)
            .resizable()
            .renderingMode(type.brandIcon.usesTemplateRendering ? .template : .original)
            .scaledToFit()
            .foregroundStyle(themeAccent)
            .padding(6)
            .frame(width: 28, height: 24)
            .background(Capsule().fill(themeAccent.opacity(0.11)))
            .overlay(Capsule().stroke(themeAccent.opacity(0.18), lineWidth: 0.6))
    }

    private func providerTabs(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableProviders) { provider in
                    Button {
                        query = ""
                        favoritesOnly = false
                        activeProviderID = provider.id
                        searchFocused = false
                        withAnimation(.snappy) {
                            proxy.scrollTo("provider-\(provider.id.uuidString)", anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            providerAvatar(provider)
                            Text(provider.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            ModelSelectorControlBackground(
                                cornerRadius: 22,
                                selected: activeProviderID == provider.id,
                                accent: themeAccent
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private func providerAvatar(_ provider: ProviderConfiguration) -> some View {
        ProviderGlyph(provider: provider, size: 28)
    }

    private func filteredItems(for provider: ProviderConfiguration) -> [ModelSelectorItem] {
        let providerMatches = normalizedQuery.isEmpty
            || provider.name.localizedCaseInsensitiveContains(normalizedQuery)
        let items = selectableModels(for: provider).map { ModelSelectorItem(provider: provider, model: $0) }
        return providerMatches ? items : items.filter(matches)
    }

    private func selectableModels(for provider: ProviderConfiguration) -> [ModelConfiguration] {
        provider.models.filter { configuration in
            if chatOnly && configuration.capabilities.kind != .chat {
                return false
            }
            if visionOnly {
                return configuration.capabilities.kind == .chat
                    && configuration.capabilities.input.contains(.image)
            }
            return true
        }
    }

    private func matches(_ item: ModelSelectorItem) -> Bool {
        normalizedQuery.isEmpty
            || item.model.id.localizedCaseInsensitiveContains(normalizedQuery)
            || item.model.displayName.localizedCaseInsensitiveContains(normalizedQuery)
            || item.provider.name.localizedCaseInsensitiveContains(normalizedQuery)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modelCardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.085) : Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        selected ? Color.primary.opacity(0.48) : Color.primary.opacity(0.055),
                        lineWidth: selected ? 1.35 : 0.7
                    )
            )
    }
}

/// Owns only this provider's visible balance. Neither the selector nor AppModel
/// reads query results, so completions cannot invalidate the model list.
private struct ModelSelectorProviderBalance: View {
    let configuration: ProviderConfiguration
    @State private var query = ProviderBalanceQueryState()
    @State private var surfaceID = UUID()

    private var unavailableReason: String? {
        ProviderBalanceQueryKey.unavailableReason(for: configuration)
    }

    private var balanceText: String {
        guard unavailableReason == nil else { return L10n.lookup("余额不可用") }
        guard query.matches(configuration) else { return L10n.lookup("查询余额…") }
        if query.errorMessage != nil { return L10n.lookup("余额不可用") }
        if let result = query.result {
            // The compact list header needs the amount first; full credit
            // details remain available in the provider's balance summary.
            switch result {
            case .value(let amount), .credits(let amount, _):
                return L10n.format("余额：%@", [amount])
            }
        }
        return L10n.lookup("查询余额…")
    }

    var body: some View {
        Button {
            query.refresh(surfaceID, provider: configuration)
        } label: {
            Text(balanceText)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, minHeight: 32, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil || query.isFetching)
        .accessibilityLabel(L10n.lookup("账户余额"))
        .accessibilityValue(balanceText)
        .accessibilityHint(unavailableReason ?? L10n.lookup("轻点刷新账户余额"))
        .accessibilityIdentifier("provider.balance.\(configuration.id.uuidString)")
        .onAppear { query.show(surfaceID, provider: configuration) }
        .onChange(of: ProviderBalanceQueryKey(configuration)) { _, _ in
            query.update(surfaceID, provider: configuration)
        }
        .onDisappear { query.hide(surfaceID) }
    }
}

private struct ModelSelectorContextModifier: ViewModifier {
    let context: SettingsPageContext
    let screenTitle: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if context == .sheet {
            content
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.hidden)
                .presentationContentInteraction(.scrolls)
        } else {
            content
                .navigationTitle(screenTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ModelSelectorItem: Hashable {
    let provider: ProviderConfiguration
    let model: ModelConfiguration

    var id: String { identity }
    var identity: String { "\(provider.id.uuidString)::\(model.id)" }
    var favoriteID: String { "favorite::\(provider.id.uuidString)::\(model.id)" }
    var providerID: String { "provider::\(provider.id.uuidString)::\(model.id)" }
}

extension ModelSelectorItem: Identifiable {}

private struct ModelConfigurationEditorSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let item: ModelSelectorItem
    let onSave: ((ModelConfiguration) -> Bool)?

    @State private var tab: ModelEditTab = .basic
    @State private var displayName: String
    @State private var capabilities: ModelCapabilities
    @State private var usesAutomaticCapabilities: Bool
    @State private var customHeaders: [KeyValueField]
    @State private var customBody: [KeyValueField]
    @State private var enabledBuiltInTools: Set<ModelBuiltInTool>
    @State private var isLeaveConfirmationPresented = false
    @State private var isSaveErrorPresented = false
    @State private var didSave = false

    init(
        item: ModelSelectorItem,
        onSave: ((ModelConfiguration) -> Bool)? = nil
    ) {
        self.item = item
        self.onSave = onSave
        _displayName = State(initialValue: item.model.displayName)
        _capabilities = State(initialValue: item.model.capabilities)
        _usesAutomaticCapabilities = State(initialValue: item.model.capabilityOverride == nil)
        _customHeaders = State(initialValue: item.model.customHeaders)
        _customBody = State(initialValue: item.model.customBody)
        _enabledBuiltInTools = State(initialValue: Set(item.model.builtInTools))
    }

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    private var themeAction: Color {
        Color(uiColor: appModel.themeActionUIColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.32))
                .frame(width: 48, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            header
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            tabBar
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .basic:
                        basicSettings
                    case .advanced:
                        advancedSettings
                    case .tools:
                        builtInTools
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                confirmButton
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .background(Color(uiColor: .systemBackground))
        .interactiveDismissDisabled(hasUnsavedChanges)
        .background {
            ProviderDraftDismissObserver(hasUnsavedChanges: hasUnsavedChanges, onAttempt: requestDismiss)
        }
        .alert(L10n.lookup("保存模型修改？"), isPresented: $isLeaveConfirmationPresented) {
            Button(L10n.lookup("保存并离开"), action: save)
            Button(L10n.lookup("不保存"), role: .destructive) { dismiss() }
            Button(L10n.lookup("继续编辑"), role: .cancel) {}
        } message: {
            Text(onSave == nil ? L10n.lookup("模型修改尚未保存。") : L10n.lookup("确认后会保留到供应商草稿，最后请保存供应商。"))
        }
        .alert(L10n.lookup("无法保存模型"), isPresented: $isSaveErrorPresented) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("模型配置没有保存成功，请继续编辑或重试。"))
        }
    }

    private var header: some View {
        HStack {
            Button {
                requestDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(L10n.lookup("编辑模型"))
                .font(.system(size: 24, weight: .bold))

            Spacer()

            Button {
                resetToInferredCapabilities()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.lookup("重置模型能力"))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(ModelEditTab.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        tab = item
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tab == item ? themeAction : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(tab == item ? themeAction.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var basicSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel(L10n.lookup("模型 ID"))
            HStack(spacing: 10) {
                Text(item.model.id)
                    .font(.system(size: 20, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = item.model.id
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.lookup("复制模型 ID"))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 68)
            .background(editFieldBackground)

            fieldLabel(L10n.lookup("模型名称"))
            TextField(L10n.lookup("模型名称"), text: $displayName)
                .font(.system(size: 20))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .frame(height: 68)
                .background(editFieldBackground)

            fieldLabel(L10n.lookup("模型类型"))
            segmentedKind

            fieldLabel(L10n.lookup("输入模式"))
            modalityToggles(selection: $capabilities.input)

            fieldLabel(L10n.lookup("输出模式"))
            modalityToggles(selection: $capabilities.output)

            fieldLabel(L10n.lookup("能力"))
            abilityToggles
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            capabilityInferenceSection
            interfaceInformationSection

            keyValueEditor(
                title: L10n.lookup("自定义 Headers"),
                subtitle: L10n.lookup("只用于这个模型；同名字段会覆盖服务商设置。"),
                fields: $customHeaders,
                namePlaceholder: "Header",
                valuePlaceholder: "Value"
            )

            keyValueEditor(
                title: L10n.lookup("自定义 Body"),
                subtitle: L10n.lookup("值支持 JSON、数字、布尔值和普通文本。"),
                fields: $customBody,
                namePlaceholder: L10n.lookup("字段名"),
                valuePlaceholder: L10n.lookup("JSON 或文本")
            )
        }
    }

    private var capabilityInferenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(L10n.lookup("能力识别"))

            VStack(spacing: 0) {
                Toggle(isOn: automaticCapabilitiesBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.lookup("自动推断模型能力"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L10n.lookup("根据模型 ID 自动判断输入、输出及工具能力。"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color(uiColor: appModel.themeSwitchUIColor))
                .padding(.horizontal, 16)
                .frame(minHeight: 72)

                Divider()
                    .padding(.leading, 16)

                Button {
                    resetToInferredCapabilities()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(themeAction)
                            .frame(width: 32, height: 32)
                            .background(themeAction.opacity(0.11), in: Circle())

                        Text(L10n.lookup("按模型 ID 重新推断"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(editFieldBackground)
        }
    }

    private var interfaceInformationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel(L10n.lookup("接口信息"))
                Spacer()
                Text(L10n.lookup("随服务商设置"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 0) {
                infoRow(title: L10n.lookup("服务商"), value: item.provider.name, systemImage: "server.rack")
                Divider().padding(.leading, 58)
                infoRow(title: L10n.lookup("协议"), value: item.provider.type.title, systemImage: item.provider.type.systemImage)
                Divider().padding(.leading, 58)
                infoRow(title: L10n.lookup("API 地址"), value: item.provider.baseURL, systemImage: "link")
            }
            .background(editFieldBackground)
        }
    }

    private var builtInTools: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel(L10n.lookup("模型能力"))
            capabilitySwitch(
                title: ModelAbility.tool.title,
                subtitle: "tool_calls",
                systemImage: ModelAbility.tool.systemImage,
                isOn: abilityBinding(.tool)
            )
            capabilitySwitch(
                title: ModelAbility.reasoning.title,
                subtitle: "reasoning",
                systemImage: ModelAbility.reasoning.systemImage,
                isOn: abilityBinding(.reasoning)
            )

            capabilitySwitch(
                title: L10n.lookup("图片输出能力"),
                subtitle: L10n.lookup("模型能力标记"),
                systemImage: ModelModality.image.systemImage,
                isOn: modalityBinding(.image, in: \.output)
            )

            fieldLabel("OpenAI Responses API")
            Text(supportsOfficialOpenAIResponses
                 ? L10n.lookup("启用后，这个模型会使用 OpenAI 官方 Responses API。")
                 : L10n.lookup("内置工具仅支持 api.openai.com 的 OpenAI 官方接口。"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ModelBuiltInTool.allCases) { tool in
                builtInToolSwitch(tool)
            }
        }
    }

    private func builtInToolSwitch(_ tool: ModelBuiltInTool) -> some View {
        Toggle(isOn: builtInToolBinding(tool)) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.lookup(tool.title))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.lookup(tool.subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Color(uiColor: appModel.themeSwitchUIColor))
        .disabled(!supportsOfficialOpenAIResponses)
        .opacity(supportsOfficialOpenAIResponses ? 1 : 0.5)
        .padding(.horizontal, 16)
        .frame(minHeight: 70)
        .background(editFieldBackground)
    }

    private func keyValueEditor(
        title: String,
        subtitle: String,
        fields: Binding<[KeyValueField]>,
        namePlaceholder: String,
        valuePlaceholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldLabel(title)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            ForEach(fields.wrappedValue) { field in
                let row = binding(for: field.id, in: fields)
                HStack(spacing: 8) {
                    TextField(namePlaceholder, text: row.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minWidth: 104)

                    Divider().frame(height: 28)

                    TextField(valuePlaceholder, text: row.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        fields.wrappedValue.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("删除%@字段", [String(describing: title)]))
                }
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 54)
                .background(editFieldBackground)
            }

            Button {
                fields.wrappedValue.append(KeyValueField())
            } label: {
                Label(L10n.format("添加%@", [String(describing: title.replacingOccurrences(of: "自定义 ", with: ""))]), systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(themeAction)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(themeAction.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .stroke(themeAction.opacity(0.24), lineWidth: 0.7)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func binding(for id: UUID, in fields: Binding<[KeyValueField]>) -> Binding<KeyValueField> {
        Binding(
            get: { fields.wrappedValue.first(where: { $0.id == id }) ?? KeyValueField(id: id) },
            set: { updated in
                guard let index = fields.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                fields.wrappedValue[index] = updated
            }
        )
    }

    private var supportsOfficialOpenAIResponses: Bool {
        guard item.provider.type == .openAI,
              let host = URL(string: item.provider.baseURL)?.host?.lowercased() else { return false }
        return host == "api.openai.com"
    }

    private func builtInToolBinding(_ tool: ModelBuiltInTool) -> Binding<Bool> {
        Binding(
            get: { enabledBuiltInTools.contains(tool) },
            set: { enabled in
                if enabled {
                    enabledBuiltInTools.insert(tool)
                    if !capabilities.abilities.contains(.tool) {
                        capabilities.abilities.append(.tool)
                        usesAutomaticCapabilities = false
                    }
                } else {
                    enabledBuiltInTools.remove(tool)
                }
            }
        )
    }

    private var segmentedKind: some View {
        HStack(spacing: 0) {
            ForEach([ModelKind.chat, .embedding], id: \.self) { kind in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        capabilities.kind = kind
                        usesAutomaticCapabilities = false
                        if kind == .embedding {
                            capabilities.output = [.text]
                            capabilities.abilities = []
                        }
                    }
                } label: {
                    Label(L10n.lookup(kind.title), systemImage: capabilities.kind == kind ? "checkmark" : "")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(capabilities.kind == kind ? themeAccent.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(editFieldBackground)
    }

    private func modalityToggles(selection: Binding<[ModelModality]>) -> some View {
        HStack(spacing: 0) {
            ForEach(ModelModality.allCases, id: \.self) { modality in
                Button {
                    toggleModality(modality, selection: selection)
                } label: {
                    Label {
                        Text(modality.title)
                    } icon: {
                        AppSymbolImage(systemName: contains(selection.wrappedValue, modality) ? "checkmark" : modality.systemImage)
                    }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(contains(selection.wrappedValue, modality) ? themeAccent.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(editFieldBackground)
    }

    private var abilityToggles: some View {
        HStack(spacing: 0) {
            ForEach(ModelAbility.allCases, id: \.self) { ability in
                Button {
                    toggleAbility(ability)
                } label: {
                    Label(ability.shortTitle, systemImage: capabilities.abilities.contains(ability) ? "checkmark" : ability.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(capabilities.abilities.contains(ability) ? themeAccent.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(editFieldBackground)
    }

    private func capabilitySwitch(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Color(uiColor: appModel.themeSwitchUIColor))
        .padding(.horizontal, 16)
        .frame(height: 66)
        .background(editFieldBackground)
    }

    private func infoRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 64, alignment: .leading)
    }

    private var confirmButton: some View {
        Button {
            save()
        } label: {
            Label(L10n.lookup("确认"), systemImage: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(themeAction)
                )
        }
        .buttonStyle(.plain)
    }

    private var editFieldBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.7)
            )
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var automaticCapabilitiesBinding: Binding<Bool> {
        Binding(
            get: { usesAutomaticCapabilities },
            set: { newValue in
                usesAutomaticCapabilities = newValue
                if newValue {
                    capabilities = ModelCapabilityRegistry.infer(id: item.model.id)
                }
            }
        )
    }

    private func abilityBinding(_ ability: ModelAbility) -> Binding<Bool> {
        Binding(
            get: { capabilities.abilities.contains(ability) },
            set: { enabled in
                if enabled {
                    if !capabilities.abilities.contains(ability) {
                        capabilities.abilities.append(ability)
                    }
                } else {
                    capabilities.abilities.removeAll { $0 == ability }
                }
                usesAutomaticCapabilities = false
            }
        )
    }

    private func modalityBinding(_ modality: ModelModality, in keyPath: WritableKeyPath<ModelCapabilities, [ModelModality]>) -> Binding<Bool> {
        Binding(
            get: { capabilities[keyPath: keyPath].contains(modality) },
            set: { enabled in
                if enabled {
                    if !capabilities[keyPath: keyPath].contains(modality) {
                        capabilities[keyPath: keyPath].append(modality)
                    }
                } else if capabilities[keyPath: keyPath].count > 1 {
                    capabilities[keyPath: keyPath].removeAll { $0 == modality }
                }
                usesAutomaticCapabilities = false
            }
        )
    }

    private func toggleModality(_ modality: ModelModality, selection: Binding<[ModelModality]>) {
        withAnimation(.snappy(duration: 0.18)) {
            if selection.wrappedValue.contains(modality) {
                guard selection.wrappedValue.count > 1 else { return }
                selection.wrappedValue.removeAll { $0 == modality }
            } else {
                selection.wrappedValue.append(modality)
            }
            usesAutomaticCapabilities = false
        }
    }

    private func toggleAbility(_ ability: ModelAbility) {
        withAnimation(.snappy(duration: 0.18)) {
            if capabilities.abilities.contains(ability) {
                capabilities.abilities.removeAll { $0 == ability }
            } else {
                capabilities.abilities.append(ability)
            }
            usesAutomaticCapabilities = false
        }
    }

    private func resetToInferredCapabilities() {
        withAnimation(.snappy(duration: 0.22)) {
            capabilities = ModelCapabilityRegistry.infer(id: item.model.id)
            usesAutomaticCapabilities = true
        }
    }

    private func save() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = item.model
        updated.displayName = trimmedName.isEmpty ? item.model.id : trimmedName
        updated.capabilityOverride = usesAutomaticCapabilities ? nil : normalized(capabilities)
        updated.customHeaders = cleaned(customHeaders)
        updated.customBody = cleaned(customBody)
        updated.builtInTools = ModelBuiltInTool.allCases.filter { enabledBuiltInTools.contains($0) }
        if let onSave {
            guard onSave(updated) else {
                isSaveErrorPresented = true
                return
            }
        } else {
            guard var provider = appModel.providers.first(where: { $0.id == item.provider.id }),
                  let index = provider.models.firstIndex(where: { $0.id == updated.id }) else {
                isSaveErrorPresented = true
                return
            }
            provider.models[index] = updated
            guard appModel.upsertProvider(provider) else {
                isSaveErrorPresented = true
                return
            }
        }
        didSave = true
        dismiss()
    }

    private var hasUnsavedChanges: Bool {
        !didSave && (
            displayName != item.model.displayName
                || usesAutomaticCapabilities != (item.model.capabilityOverride == nil)
                || (!usesAutomaticCapabilities && capabilities != item.model.capabilities)
                || customHeaders != item.model.customHeaders
                || customBody != item.model.customBody
                || enabledBuiltInTools != Set(item.model.builtInTools)
        )
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            isLeaveConfirmationPresented = true
        } else {
            dismiss()
        }
    }

    private func cleaned(_ fields: [KeyValueField]) -> [KeyValueField] {
        fields.compactMap { field in
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return KeyValueField(
                id: field.id,
                name: name,
                value: field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func normalized(_ capabilities: ModelCapabilities) -> ModelCapabilities {
        var result = capabilities
        result.input = orderedModalities(result.input)
        result.output = orderedModalities(result.output)
        result.abilities = ModelAbility.allCases.filter { result.abilities.contains($0) }
        if result.input.isEmpty { result.input = [.text] }
        if result.output.isEmpty { result.output = [.text] }
        return result
    }

    private func orderedModalities(_ values: [ModelModality]) -> [ModelModality] {
        ModelModality.allCases.filter { values.contains($0) }
    }

    private func contains(_ values: [ModelModality], _ modality: ModelModality) -> Bool {
        values.contains(modality)
    }
}

private enum ModelEditTab: String, CaseIterable, Identifiable {
    case basic
    case advanced
    case tools

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .basic: L10n.lookup("基本设置")
        case .advanced: L10n.lookup("高级设置")
        case .tools: L10n.lookup("内置工具")
        }
    }
}

private extension ModelModality {
    @MainActor var title: String {
        switch self {
        case .text: L10n.lookup("文本")
        case .image: L10n.lookup("图片")
        }
    }
}

private extension ModelAbility {
    @MainActor var shortTitle: String {
        switch self {
        case .tool: L10n.lookup("工具")
        case .reasoning: L10n.lookup("推理")
        }
    }
}

private struct ModelSelectorControlBackground: View {
    let cornerRadius: CGFloat
    var selected = false
    var accent: Color = .secondary

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            shape
                .fill(selected ? accent.opacity(0.08) : Color.primary.opacity(0.035))
                .glassEffect(
                    selected ? .regular.tint(accent.opacity(0.10)) : .regular,
                    in: shape
                )
        } else {
            shape
                .fill(.thinMaterial)
                .overlay(shape.fill(selected ? accent.opacity(0.12) : Color.clear))
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.6))
        }
    }
}

struct ProviderGlyph: View {
    let provider: ProviderConfiguration
    var size: CGFloat = 36

    var body: some View {
        Group {
            if AssistantMediaStore.hasImage(for: provider.customAvatar) {
                ProviderCustomAvatar(reference: provider.customAvatar, size: size)
            } else {
                ProviderBrandMark(
                    icon: provider.resolvedBrandIcon,
                    fallbackText: provider.name,
                    size: size
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ProviderBrandMark: View {
    let icon: ProviderBrandIcon?
    let fallbackText: String
    let size: CGFloat

    private var initial: String {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.045))
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)

            if let icon {
                brandImage(icon)
                    .scaledToFit()
                    .frame(width: size * 0.68, height: size * 0.68)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func brandImage(_ icon: ProviderBrandIcon) -> some View {
        if icon.usesTemplateRendering {
            Image(icon.assetName)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.primary)
        } else {
            Image(icon.assetName)
                .resizable()
                .renderingMode(.original)
        }
    }
}
