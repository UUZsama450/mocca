import SwiftUI
import PhotosUI
import Photos
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import CoreLocation
import EventKit
import UserNotifications

private enum PreferencesSheetRoute: String, Identifiable, Hashable {
    case chatFont
    case assistantLineSpacing
    case assistantMarkdownListItemSpacing
    case assistantMarkdownBlockSpacing
    case inputOpacity
    case inputPlaceholder
    case modelEntryStyle
    case imageQuality

    var id: String { rawValue }
}

private enum SettingsSearchDestination: Hashable {
    case userProfile
    case assistantManagement
    case currentAssistant
    case groupChat
    case worldBook
    case quickPhrases
    case instructionInjection
    case defaultModels
    case providers
    case searchServices
    case ocr
    case voice
    case mcp
    case networkProxy
    case appearanceMode
    case preferences
    case theme
    case appFont
    case preferenceSheet(PreferencesSheetRoute)
    case chatSegmentation
    case chatItemDisplay
    case rendering
    case chatBubbles
    case behavior
    case haptics
    case backgroundGeneration
    case permissions
    case backup
    case storage
    case about
    case usage
    case documentation
    case privacy
    case legal
    case sponsor
}

private struct SettingsSearchItem: Identifiable {
    let title: String
    let context: String
    let keywords: String
    let systemImage: String
    let destination: SettingsSearchDestination

    var id: String { "\(context)|\(title)" }

    @MainActor func matches(_ query: String) -> Bool {
        (title + " " + L10n.lookup(title) + " " + context + " " + L10n.lookup(context) + " " + keywords + " " + L10n.lookup(keywords)).localizedCaseInsensitiveContains(query)
    }

    static let catalog: [SettingsSearchItem] = [
        .init(title: "个人资料", context: "便签", keywords: "用户 昵称 头像 便签 喜好 兴趣 偏好 notes profile", systemImage: "person.crop.circle", destination: .userProfile),
        .init(title: "助手", context: "助手与聊天", keywords: "助手管理 头像 记忆 提示词", systemImage: "person.crop.circle", destination: .assistantManagement),
        .init(title: "当前助手图像生成", context: "助手", keywords: "生图 图片 模型", systemImage: "sparkles", destination: .currentAssistant),
        .init(title: "群聊设置", context: "助手与聊天", keywords: "群聊 多助手", systemImage: "bubble.left.and.bubble.right", destination: .groupChat),
        .init(title: "世界书", context: "助手与聊天", keywords: "知识库 lorebook", systemImage: "book", destination: .worldBook),
        .init(title: "快捷短语", context: "助手与聊天", keywords: "短语 快捷回复", systemImage: "bolt", destination: .quickPhrases),
        .init(title: "指令注入", context: "助手与聊天", keywords: "提示词 注入", systemImage: "square.stack.3d.up", destination: .instructionInjection),
        .init(title: "供应商", context: "模型与服务", keywords: "Provider API Key 密钥", systemImage: "shippingbox", destination: .providers),
        .init(title: "默认模型", context: "模型与服务", keywords: "模型 语言模型", systemImage: "heart", destination: .defaultModels),
        .init(title: "图像生成接口", context: "供应商", keywords: "图片 生图 OpenRouter OpenAI", systemImage: "photo.badge.plus", destination: .providers),
        .init(title: "搜索服务", context: "模型与服务", keywords: "联网搜索 web search", systemImage: "globe", destination: .searchServices),
        .init(title: "OCR 图片识别", context: "模型与服务", keywords: "OCR 图片 识别", systemImage: "eye", destination: .ocr),
        .init(title: "语音服务", context: "模型与服务", keywords: "语音 TTS ASR", systemImage: "speaker.wave.2", destination: .voice),
        .init(title: "MCP", context: "模型与服务", keywords: "工具 服务器", systemImage: "terminal", destination: .mcp),
        .init(title: "网络代理", context: "模型与服务", keywords: "代理 Proxy HTTP HTTPS", systemImage: "network", destination: .networkProxy),
        .init(title: "颜色模式", context: "外观与应用", keywords: "浅色 深色 跟随系统", systemImage: "circle.lefthalf.filled", destination: .appearanceMode),
        .init(title: "大文件提醒", context: "偏好设置", keywords: "文件 附件 提醒 60000 100 MB", systemImage: "doc", destination: .preferences),
        .init(title: "偏好设置", context: "外观与应用", keywords: "外观 字体 渲染 交互", systemImage: "display", destination: .preferences),
        .init(title: "主题设置", context: "偏好设置", keywords: "主题 颜色 原生绿色", systemImage: "paintpalette", destination: .theme),
        .init(title: "应用字体", context: "偏好设置", keywords: "字体 font", systemImage: "textformat", destination: .appFont),
        .init(title: "聊天字体大小", context: "偏好设置", keywords: "字号", systemImage: "textformat.size", destination: .preferenceSheet(.chatFont)),
        .init(title: "聊天分段", context: "偏好设置 · 聊天内容", keywords: "回复 分段 流式 段数 上限 气泡 间距 连续 发送 等待", systemImage: "text.bubble", destination: .chatSegmentation),
        .init(title: "消息显示", context: "偏好设置", keywords: "聊天项目 显示 头像 名称 时间 操作", systemImage: "message", destination: .chatItemDisplay),
        .init(title: "排版与渲染", context: "偏好设置", keywords: "Markdown 行距 间距 HTML 代码块", systemImage: "text.alignleft", destination: .rendering),
        .init(title: "助手消息行间距", context: "偏好设置", keywords: "行距", systemImage: "arrow.up.and.down.text.horizontal", destination: .preferenceSheet(.assistantLineSpacing)),
        .init(title: "Markdown 列表间距", context: "偏好设置", keywords: "列表 行距", systemImage: "list.bullet", destination: .preferenceSheet(.assistantMarkdownListItemSpacing)),
        .init(title: "Markdown 块间距", context: "偏好设置", keywords: "段落 标题 留白", systemImage: "text.alignleft", destination: .preferenceSheet(.assistantMarkdownBlockSpacing)),
        .init(title: "输入框伸缩动画", context: "偏好设置 · 输入框", keywords: "输入 动画 换行 光标 高度 animation", systemImage: "arrow.up.and.down", destination: .preferences),
        .init(title: "输入框占位文字", context: "偏好设置", keywords: "输入 placeholder", systemImage: "text.cursor", destination: .preferenceSheet(.inputPlaceholder)),
        .init(title: "模型入口样式", context: "偏好设置 · 输入框", keywords: "模型 名称 气泡 图标 选择", systemImage: "sparkles", destination: .preferenceSheet(.modelEntryStyle)),
        .init(title: "输入框背景透明度", context: "偏好设置", keywords: "输入 透明度 亮 暗", systemImage: "circle.lefthalf.filled", destination: .preferenceSheet(.inputOpacity)),
        .init(title: "图片压缩质量", context: "偏好设置", keywords: "JPEG 图片 质量", systemImage: "photo.on.rectangle", destination: .preferenceSheet(.imageQuality)),
        .init(title: "聊天气泡", context: "偏好设置", keywords: "气泡 样式 颜色 透明度 发送动画 上浮", systemImage: "message.fill", destination: .chatBubbles),
        .init(title: "行为与启动", context: "偏好设置", keywords: "导航 侧栏 回车发送 自动标题", systemImage: "sparkles", destination: .behavior),
        .init(title: "震动反馈", context: "偏好设置", keywords: "触觉 haptic", systemImage: "iphone.radiowaves.left.and.right", destination: .haptics),
        .init(title: "iOS 后台生成", context: "外观与应用", keywords: "后台 生成 通知 实时活动", systemImage: "waveform.path.ecg", destination: .backgroundGeneration),
        .init(title: "权限与系统功能", context: "外观与应用", keywords: "权限 隐私 健康 日历 提醒事项 定位 相机 照片 通知", systemImage: "hand.raised", destination: .permissions),
        .init(title: "数据备份", context: "数据与存储", keywords: "备份 导入 导出 恢复", systemImage: "arrow.triangle.2.circlepath", destination: .backup),
        .init(title: "聊天记录存储", context: "数据与存储", keywords: "存储 空间 聊天记录", systemImage: "internaldrive", destination: .storage),
        .init(title: "关于", context: "关于与支持", keywords: "版本 App", systemImage: "info.circle", destination: .about),
        .init(title: "使用统计", context: "关于与支持", keywords: "统计 Token 消息", systemImage: "chart.bar", destination: .usage),
        .init(title: "使用文档", context: "关于与支持", keywords: "帮助 文档", systemImage: "doc.text", destination: .documentation),
        .init(title: "隐私政策", context: "关于与支持", keywords: "隐私 数据 权限 第三方", systemImage: "hand.raised", destination: .privacy),
        .init(title: "关于与许可", context: "关于与支持", keywords: "关于 Mocca GitHub 仓库 源码 repository source 开源 AGPL 许可", systemImage: "doc.badge.gearshape", destination: .legal),
        .init(title: "赞助", context: "关于与支持", keywords: "支持 捐赠", systemImage: "gift", destination: .sponsor)
    ]
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if normalizedSearchText.isEmpty {
                    Section {
                        NavigationLink(value: SettingsSearchDestination.userProfile) {
                            HStack(spacing: 12) {
                                SponsorWearableAvatar(target: .user, badgeSize: 19) {
                                    UserProfileAvatarView(profile: model.userProfile, size: 64)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.userProfile.nickname)
                                        .font(.title3.weight(.semibold))
                                    Text(L10n.lookup("个人资料"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .accessibilityLabel(L10n.lookup("个人资料"))
                        .accessibilityIdentifier("settings.userProfile")
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                        .listRowBackground(SettingsOverviewRowBackground())
                        .listRowSeparator(.hidden)
                    }
                if showsAssistantAndChatSection {
                    Section {
                    if settingsMatch("助手", keywords: "助手管理 助手头像 图像生成 生图 记忆 提示词") {
                        NavigationLink {
                        AssistantManagementView()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("助手"), systemImage: "person.crop.circle")
                    }
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("群聊设置", keywords: "群聊 多助手") {
                        NavigationLink {
                        GroupChatSettingsPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("群聊设置"), systemImage: "bubble.left.and.bubble.right")
                    }
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("世界书", keywords: "知识库 lorebook") {
                        NavigationLink {
                        WorldBookPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("世界书"), systemImage: "book")
                    }
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("快捷短语", keywords: "短语 快捷回复") {
                        NavigationLink {
                        QuickPhrasePage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("快捷短语"), systemImage: "bolt")
                    }
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("指令注入", keywords: "提示词 注入") {
                        NavigationLink {
                        InstructionInjectionPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("指令注入"), systemImage: "square.stack.3d.up")
                    }
                    .settingsOverviewRowStyle()
                    }
                } header: {
                    SettingsOverviewSectionHeader(L10n.lookup("助手与聊天"))
                }
                }

                if showsModelsAndServicesSection {
                    Section {
                    if settingsMatch("供应商", keywords: "Provider API Key 密钥 图像供应商") {
                        NavigationLink {
                        ProviderSettingsView(context: .navigation)
                    } label: {
                        SettingsOverviewValueRow(
                            title: L10n.lookup("供应商"),
                            systemImage: "shippingbox",
                            value: "\(model.providers.count)",
                            showsChevron: false
                        )
                    }
                    .accessibilityLabel(L10n.lookup("供应商"))
                    .accessibilityValue("\(model.providers.count)")
                    .accessibilityHint(L10n.lookup("打开供应商设置"))
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("默认模型", keywords: "模型 语言模型") {
                        NavigationLink {
                        DefaultModelsOverviewView()
                    } label: {
                        SettingsOverviewValueRow(
                            title: L10n.lookup("默认模型"),
                            systemImage: "heart",
                            value: (model.selectedModelConfiguration?.displayName ?? L10n.lookup("选择模型")),
                            showsChevron: false
                        )
                    }
                    .accessibilityLabel(L10n.lookup("默认模型"))
                    .accessibilityValue((model.selectedModelConfiguration?.displayName ?? L10n.lookup("选择模型")))
                    .accessibilityHint(L10n.lookup("打开默认模型设置"))
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("搜索服务", keywords: "联网搜索 web search") {
                        NavigationLink {
                        SearchServiceSettingsView()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("搜索服务"), systemImage: "globe")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("OCR 图片识别", keywords: "OCR 图片 识别") {
                        NavigationLink {
                        OCRSettingsPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("OCR 图片识别"), systemImage: "eye")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("语音服务", keywords: "语音 TTS ASR") {
                        NavigationLink {
                        VoiceServicesPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("语音服务"), systemImage: "speaker.wave.2")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("MCP", keywords: "工具 服务器") {
                        NavigationLink {
                        MCPSettingsView()
                    } label: {
                        SettingsOverviewRowLabel(title: "MCP", systemImage: "terminal")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("网络代理", keywords: "代理 Proxy HTTP HTTPS") {
                        NavigationLink {
                        NetworkProxyPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("网络代理"), systemImage: "network")
                    }
                    .settingsOverviewRowStyle()
                    }
                } header: {
                    SettingsOverviewSectionHeader(L10n.lookup("模型与服务"))
                }
                }

                if showsAppearanceAndAppSection {
                    Section {
                    AppLanguagePicker(usesSettingsRowStyle: true)
                        .tint(.secondary)
                        .settingsOverviewRowStyle()
                    if settingsMatch("颜色模式", keywords: "浅色 深色 跟随系统") {
                    Picker(selection: appearanceBinding) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(L10n.lookup(mode.title)).tag(mode)
                        }
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("颜色模式"), systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.menu)
                    .tint(.secondary)
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("偏好设置", keywords: "主题 颜色 字体 聊天气泡 气泡动画 上浮 输入框 背景透明度 Liquid Glass 渲染 交互") {
                        NavigationLink {
                        PreferencesPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("偏好设置"), systemImage: "display")
                    }
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("iOS 后台生成", keywords: "后台 生成 通知 实时活动") {
                        NavigationLink {
                        IOSBackgroundGenerationSettingsPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("iOS 后台生成"), systemImage: "waveform.path.ecg")
                    }
                    .settingsOverviewRowStyle()
                    }

                    if settingsMatch("权限与系统功能", keywords: "权限 隐私 健康 日历 提醒事项 定位 相机 照片 通知") {
                        NavigationLink {
                            SystemPermissionsPage()
                        } label: {
                            SettingsOverviewRowLabel(title: L10n.lookup("权限与系统功能"), systemImage: "hand.raised")
                        }
                        .settingsOverviewRowStyle()
                    }
                } header: {
                    SettingsOverviewSectionHeader(L10n.lookup("外观与应用"))
                }
                }

                if showsDataAndStorageSection {
                    Section {
                    if settingsMatch("数据备份", keywords: "备份 导入 导出 恢复") {
                        NavigationLink {
                        BackupPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("数据备份"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("聊天记录存储", keywords: "存储 空间 聊天记录") {
                        NavigationLink {
                        StorageSpacePage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("聊天记录存储"), systemImage: "internaldrive")
                    }
                    .settingsOverviewRowStyle()
                    }
                } header: {
                    SettingsOverviewSectionHeader(L10n.lookup("数据与存储"))
                }
                }

                if showsAboutAndSupportSection {
                    Section {
                    if settingsMatch("关于", keywords: "版本 App") {
                        NavigationLink {
                        AboutPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("关于"), systemImage: "info.circle")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("使用统计", keywords: "统计 Token 消息") {
                        NavigationLink {
                        UsageStatisticsPage()
                    } label: {
                        SettingsOverviewRowLabel(title: L10n.lookup("使用统计"), systemImage: "chart.bar")
                    }
                    .settingsOverviewRowStyle()
                    }
                    if settingsMatch("使用文档", keywords: "帮助 文档") {
                        NavigationLink {
                            MoccaDocumentationPage()
                        } label: {
                            SettingsOverviewRowLabel(title: L10n.lookup("使用文档"), systemImage: "doc.text")
                        }
                        .settingsOverviewRowStyle()
                    }
                    if settingsMatch("隐私政策", keywords: "隐私 数据 权限 第三方") {
                        NavigationLink {
                            MoccaPrivacyPolicyPage()
                        } label: {
                            SettingsOverviewRowLabel(title: L10n.lookup("隐私政策"), systemImage: "hand.raised")
                        }
                        .settingsOverviewRowStyle()
                    }
                    if settingsMatch("关于与许可", keywords: "关于 Mocca GitHub 仓库 源码 repository source 开源 AGPL 许可") {
                        NavigationLink {
                            MoccaLegalNoticesPage()
                        } label: {
                            SettingsOverviewRowLabel(title: L10n.lookup("关于与许可"), systemImage: "doc.badge.gearshape")
                        }
                        .settingsOverviewRowStyle()
                    }
                    if AppBuildConfiguration.sponsorshipEnabled, settingsMatch("赞助", keywords: "支持 捐赠") {
                        NavigationLink {
                            SponsorPage()
                        } label: {
                            SettingsOverviewRowLabel(title: L10n.lookup("赞助"), systemImage: "gift")
                        }
                        .settingsOverviewRowStyle()
                    }
                } header: {
                    SettingsOverviewSectionHeader(L10n.lookup("关于与支持"))
                }
                }
                } else {
                    Section {
                        if matchesLanguageSearch {
                            AppLanguagePicker(usesSettingsRowStyle: true)
                                .settingsOverviewRowStyle()
                        }
                        if searchResults.isEmpty && !matchesLanguageSearch {
                            Label(L10n.lookup("没有找到相关设置"), systemImage: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 58)
                                .settingsOverviewRowStyle()
                        } else {
                            ForEach(searchResults) { item in
                                if item.destination == .appearanceMode {
                                    Picker(selection: appearanceBinding) {
                                        ForEach(AppearanceMode.allCases) { mode in
                                            Text(L10n.lookup(mode.title)).tag(mode)
                                        }
                                    } label: {
                                        SettingsOverviewValueRow(
                                            title: item.title,
                                            systemImage: item.systemImage,
                                            value: L10n.lookup(model.appearanceMode.title),
                                            showsChevron: false
                                        )
                                    }
                                    .pickerStyle(.menu)
                                    .settingsOverviewRowStyle()
                                } else {
                                    NavigationLink(value: item.destination) {
                                        SettingsOverviewValueRow(
                                            title: item.title,
                                            systemImage: item.systemImage,
                                            value: L10n.lookup(item.context),
                                            showsChevron: false
                                        )
                                    }
                                    .settingsOverviewRowStyle()
                                }
                            }
                        }
                    } header: {
                        SettingsOverviewSectionHeader(L10n.lookup("搜索结果"))
                    }
                }
            }
            .settingsGroupedPageStyle()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                floatingSearchBar
            }
            .navigationTitle(L10n.lookup("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
            .navigationDestination(for: SettingsSearchDestination.self) { destination in
                searchDestination(destination)
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchesLanguageSearch: Bool {
        "language 语言 english 简体中文 跟随系统 system".localizedCaseInsensitiveContains(normalizedSearchText)
    }

    private var showsSearchCancelButton: Bool {
        isSearchFocused || !searchText.isEmpty
    }

    private var floatingSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.lookup("搜索设置"), text: $searchText)
                .focused($isSearchFocused)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    isSearchFocused = false
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .contentShape(Capsule())
    }

    private var floatingSearchCancelButton: some View {
        Button {
            searchText = ""
            isSearchFocused = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.lookup("取消搜索"))
        .accessibilityHint(L10n.lookup("清除搜索内容并收起键盘"))
    }

    @ViewBuilder
    private var floatingSearchControls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    floatingSearchField
                        .glassEffect(.regular.interactive(), in: Capsule())

                    if showsSearchCancelButton {
                        floatingSearchCancelButton
                            .glassEffect(.regular.interactive(), in: Circle())
                            .glassEffectTransition(.materialize)
                            .transition(.scale(scale: 0.82).combined(with: .opacity))
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                floatingSearchField
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 5)

                if showsSearchCancelButton {
                    floatingSearchCancelButton
                        .background(.regularMaterial, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.8)
                        }
                        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
            }
        }
    }

    private var floatingSearchBar: some View {
        floatingSearchControls
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .animation(.snappy(duration: 0.20), value: showsSearchCancelButton)
    }

    private var searchResults: [SettingsSearchItem] {
        SettingsSearchItem.catalog.filter {
            (AppBuildConfiguration.sponsorshipEnabled || $0.destination != .sponsor)
                && $0.matches(normalizedSearchText)
        }
    }

    @ViewBuilder
    private func searchDestination(_ destination: SettingsSearchDestination) -> some View {
        switch destination {
        case .userProfile:
            UserProfileView(profile: model.userProfile, onCloseSettings: { dismiss() })
        case .assistantManagement:
            AssistantManagementView()
        case .currentAssistant:
            AssistantEditorView(
                profile: model.currentAssistant,
                presentationContext: .navigation,
                onSave: model.upsertAssistant
            )
        case .groupChat:
            GroupChatSettingsPage()
        case .worldBook:
            WorldBookPage()
        case .quickPhrases:
            QuickPhrasePage()
        case .instructionInjection:
            InstructionInjectionPage()
        case .defaultModels:
            DefaultModelsOverviewView()
        case .providers:
            ProviderSettingsView(context: .navigation)
        case .searchServices:
            SearchServiceSettingsView()
        case .ocr:
            OCRSettingsPage()
        case .voice:
            VoiceServicesPage()
        case .mcp:
            MCPSettingsView()
        case .networkProxy:
            NetworkProxyPage()
        case .appearanceMode:
            EmptyView()
        case .preferences:
            PreferencesPage()
        case .theme:
            ThemePreferencesPage()
        case .appFont:
            AppFontPreferencesPage()
        case .preferenceSheet(let sheet):
            PreferencesPage(initialSheet: sheet)
        case .chatSegmentation:
            ChatSegmentationPreferencesPage()
        case .chatItemDisplay:
            ChatItemDisplayPreferencesPage()
        case .rendering:
            RenderingPreferencesPage()
        case .chatBubbles:
            ChatBubblePreferencesPage()
        case .behavior:
            BehaviorStartupPreferencesPage()
        case .haptics:
            HapticsPreferencesPage()
        case .backgroundGeneration:
            IOSBackgroundGenerationSettingsPage()
        case .permissions:
            SystemPermissionsPage()
        case .backup:
            BackupPage()
        case .storage:
            StorageSpacePage()
        case .about:
            AboutPage()
        case .usage:
            UsageStatisticsPage()
        case .documentation:
            MoccaDocumentationPage()
        case .privacy:
            MoccaPrivacyPolicyPage()
        case .legal:
            MoccaLegalNoticesPage()
        case .sponsor:
            if AppBuildConfiguration.sponsorshipEnabled {
                SponsorPage()
            }
        }
    }

    private var showsAssistantAndChatSection: Bool {
        settingsMatch("助手", keywords: "助手管理 助手头像 图像生成 生图 记忆 提示词")
            || settingsMatch("群聊设置", keywords: "群聊 多助手")
            || settingsMatch("世界书", keywords: "知识库 lorebook")
            || settingsMatch("快捷短语", keywords: "短语 快捷回复")
            || settingsMatch("指令注入", keywords: "提示词 注入")
    }

    private var showsModelsAndServicesSection: Bool {
        settingsMatch("默认模型", keywords: "模型 语言模型")
            || settingsMatch("供应商", keywords: "Provider API Key 密钥 图像供应商")
            || settingsMatch("搜索服务", keywords: "联网搜索 web search")
            || settingsMatch("OCR 图片识别", keywords: "OCR 图片 识别")
            || settingsMatch("语音服务", keywords: "语音 TTS ASR")
            || settingsMatch("MCP", keywords: "工具 服务器")
            || settingsMatch("网络代理", keywords: "代理 Proxy HTTP HTTPS")
    }

    private var showsAppearanceAndAppSection: Bool {
        settingsMatch("颜色模式", keywords: "浅色 深色 跟随系统")
            || settingsMatch("偏好设置", keywords: "主题 颜色 字体 聊天气泡 气泡动画 上浮 输入框 背景透明度 Liquid Glass 渲染 交互")
            || settingsMatch("iOS 后台生成", keywords: "后台 生成 通知 实时活动")
            || settingsMatch("权限与系统功能", keywords: "权限 隐私 健康 日历 提醒事项 定位 相机 照片 通知")
    }

    private var showsDataAndStorageSection: Bool {
        settingsMatch("数据备份", keywords: "备份 导入 导出 恢复")
            || settingsMatch("聊天记录存储", keywords: "存储 空间 聊天记录")
    }

    private var showsAboutAndSupportSection: Bool {
        settingsMatch("关于", keywords: "版本 App")
            || settingsMatch("使用统计", keywords: "统计 Token 消息")
            || settingsMatch("使用文档", keywords: "帮助 文档")
            || settingsMatch("隐私政策", keywords: "隐私 数据 权限 第三方")
            || settingsMatch("关于与许可", keywords: "关于 Mocca GitHub 仓库 源码 repository source 开源 AGPL 许可")
            || (AppBuildConfiguration.sponsorshipEnabled && settingsMatch("赞助", keywords: "支持 捐赠"))
    }

    private func settingsMatch(_ title: String, keywords: String = "") -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return (title + " " + L10n.lookup(title) + " " + keywords + " " + L10n.lookup(keywords)).localizedCaseInsensitiveContains(query)
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { model.appearanceMode },
            set: { model.selectAppearanceMode($0) }
        )
    }

}

private struct IOSBackgroundGenerationSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var notificationsAuthorized = false
    @State private var liveActivitiesEnabled = false
    @State private var backgroundTaskActive = false

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.lookup("iOS 仍可能暂停任务"))
                            .font(.system(size: 16, weight: .semibold))
                        Text(L10n.lookup("这些选项使用 Apple 提供的后台时间、持续处理、通知与实时活动来提升连续性，但系统仍会根据电量和资源决定运行时长。"))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 5)
            }

            Section {
                Toggle(isOn: mainEnabledBinding) {
                    settingLabel(
                        title: L10n.lookup("后台生成"),
                        subtitle: L10n.lookup("App 离开前台后，使用 iOS 分配的后台时间继续当前回复。"),
                        systemImage: "waveform.path.ecg"
                    )
                }
                if #available(iOS 26.0, *) {
                    Toggle(isOn: continuedProcessingBinding) {
                        settingLabel(
                            title: L10n.lookup("持续后台生成（实验）"),
                            subtitle: L10n.lookup("离开 App 后继续使用网络接收当前回复；系统会显示可取消的任务活动。"),
                            systemImage: "bolt.horizontal.circle"
                        )
                    }
                    .disabled(!model.backgroundGenerationSettings.enabled)
                }
                Toggle(isOn: taskRecoveryBinding) {
                    settingLabel(
                        title: L10n.lookup("后台任务恢复"),
                        subtitle: L10n.lookup("向 iOS 请求后续刷新和联网处理机会。"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(!model.backgroundGenerationSettings.enabled)
                Toggle(isOn: liveActivityBinding) {
                    settingLabel(
                        title: L10n.lookup("实时活动"),
                        subtitle: L10n.lookup("生成时在锁屏和灵动岛显示助手与进度。"),
                        systemImage: "timer"
                    )
                }
                .disabled(!model.backgroundGenerationSettings.enabled)
                Toggle(isOn: notificationBinding) {
                    settingLabel(
                        title: L10n.lookup("任务通知"),
                        subtitle: L10n.lookup("完成或中断时，上方显示助手名称，下方显示助手消息。"),
                        systemImage: "bubble.left"
                    )
                }
                .disabled(!model.backgroundGenerationSettings.enabled)
            }

            Section(L10n.lookup("系统状态")) {
                statusRow(
                    title: L10n.lookup("后台任务"),
                    value: backgroundTaskActive ? L10n.lookup("正在运行") : L10n.lookup("可用"),
                    systemImage: "waveform.path.ecg"
                )
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    statusRow(
                        title: L10n.lookup("通知"),
                        value: notificationsAuthorized ? L10n.lookup("已允许") : L10n.lookup("未允许"),
                        systemImage: "bubble.left",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                statusRow(
                    title: L10n.lookup("实时活动"),
                    value: liveActivitiesEnabled ? L10n.lookup("可用") : L10n.lookup("不可用"),
                    systemImage: "timer"
                )
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("iOS 后台生成"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus() }
        .onChange(of: model.backgroundGenerationSettings.notificationsEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                notificationsAuthorized = await IOSBackgroundGenerationManager.shared
                    .requestNotificationAuthorization()
            }
        }
    }

    private func settingLabel(title: String, subtitle: String, systemImage: String) -> some View {
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

    private func statusRow(
        title: String,
        value: String,
        systemImage: String,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            AppSymbolImage(systemName: systemImage)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var mainEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.backgroundGenerationSettings.enabled },
            set: { enabled in
                model.updateBackgroundGenerationSettings { settings in
                    settings.enabled = enabled
                    if !enabled {
                        settings.taskRecoveryEnabled = false
                        settings.continuedProcessingEnabled = false
                        settings.liveActivityEnabled = false
                        settings.notificationsEnabled = false
                    }
                }
            }
        )
    }

    private var taskRecoveryBinding: Binding<Bool> {
        childBinding(\.taskRecoveryEnabled)
    }

    private var continuedProcessingBinding: Binding<Bool> {
        Binding(
            get: { model.backgroundGenerationSettings.continuedProcessingEnabled },
            set: { enabled in
                model.updateBackgroundGenerationSettings { settings in
                    if enabled {
                        settings.enabled = true
                        settings.liveActivityEnabled = false
                    }
                    settings.continuedProcessingEnabled = enabled
                }
            }
        )
    }

    private var liveActivityBinding: Binding<Bool> {
        Binding(
            get: { model.backgroundGenerationSettings.liveActivityEnabled },
            set: { enabled in
                model.updateBackgroundGenerationSettings { settings in
                    if enabled {
                        settings.enabled = true
                        settings.continuedProcessingEnabled = false
                    }
                    settings.liveActivityEnabled = enabled
                }
            }
        )
    }

    private var notificationBinding: Binding<Bool> {
        childBinding(\.notificationsEnabled)
    }

    private func childBinding(
        _ keyPath: WritableKeyPath<IOSBackgroundGenerationSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.backgroundGenerationSettings[keyPath: keyPath] },
            set: { enabled in
                model.updateBackgroundGenerationSettings { settings in
                    if enabled { settings.enabled = true }
                    settings[keyPath: keyPath] = enabled
                }
            }
        )
    }

    private func refreshStatus() async {
        let status = await IOSBackgroundGenerationManager.shared.systemStatus()
        backgroundTaskActive = status.backgroundTaskActive
        notificationsAuthorized = status.notificationsAuthorized
        liveActivitiesEnabled = status.liveActivitiesEnabled
    }
}

private enum SystemPermissionKind: String, CaseIterable, Identifiable {
    case notifications
    case location
    case camera
    case photos
    case photoSaving
    case calendar
    case reminders

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .notifications: L10n.lookup("通知")
        case .location: L10n.lookup("位置")
        case .camera: L10n.lookup("相机")
        case .photos: L10n.lookup("照片")
        case .photoSaving: L10n.lookup("保存到照片")
        case .calendar: L10n.lookup("系统日历")
        case .reminders: L10n.lookup("提醒事项")
        }
    }

    @MainActor var subtitle: String {
        switch self {
        case .notifications: L10n.lookup("用于任务完成提醒和日历事项提醒。")
        case .location: L10n.lookup("仅在查询本地天气时读取当前位置。")
        case .camera: L10n.lookup("用于拍照并把图片发送给助手。")
        case .photos: L10n.lookup("用于选择头像、背景或要发送的图片；系统照片选择器无需完整访问。")
        case .photoSaving: L10n.lookup("用于把聊天中的图片存储到系统照片。")
        case .calendar: L10n.lookup("助手仅在你明确要求时向 Apple 日历创建事件。")
        case .reminders: L10n.lookup("助手可按你的明确要求查看、创建、编辑、完成或删除系统提醒事项。")
        }
    }

    var systemImage: String {
        switch self {
        case .notifications: "bell"
        case .location: "location"
        case .camera: "camera"
        case .photos: "photo.on.rectangle"
        case .photoSaving: "square.and.arrow.down"
        case .calendar: "calendar"
        case .reminders: "checklist"
        }
    }
}

private enum SystemPermissionAccess: Equatable {
    case notRequested
    case allowed
    case limited
    case denied
    case restricted
    case systemManaged
    case unavailable
    case unknown

    @MainActor var title: String {
        switch self {
        case .notRequested: L10n.lookup("尚未请求")
        case .allowed: L10n.lookup("已允许")
        case .limited: L10n.lookup("部分允许")
        case .denied: L10n.lookup("已拒绝")
        case .restricted: L10n.lookup("受限制")
        case .systemManaged: L10n.lookup("由系统管理")
        case .unavailable: L10n.lookup("不可用")
        case .unknown: L10n.lookup("待确认")
        }
    }

    var color: Color {
        switch self {
        case .allowed: .green
        case .limited, .systemManaged: .orange
        case .denied, .restricted: .red
        case .notRequested, .unknown, .unavailable: .secondary
        }
    }
}

private struct SystemPermissionSnapshot: Equatable {
    let access: SystemPermissionAccess
}

@MainActor
private final class SystemLocationPermissionRequester: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationChanged: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request(authorizationChanged: @escaping () -> Void) {
        self.authorizationChanged = authorizationChanged
        manager.requestWhenInUseAuthorization()
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged?()
    }
}

private struct SystemPermissionsPage: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshots: [SystemPermissionKind: SystemPermissionSnapshot] = [:]
    @State private var requestingPermission: SystemPermissionKind?
    @State private var locationRequester = SystemLocationPermissionRequester()

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.lookup("按需授权"))
                            .font(.system(size: 16, weight: .semibold))
                        Text(L10n.lookup("打开此页面不会自动申请权限。你可以现在处理，也可以等真正使用相关功能时再由 iOS 临时询问。"))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 5)
            }

            Section(L10n.lookup("沟通与设备")) {
                permissionRow(.notifications)
                permissionRow(.location)
                permissionRow(.camera)
                permissionRow(.photos)
                permissionRow(.photoSaving)
            }

            Section {
                permissionRow(.calendar)
                permissionRow(.reminders)
            } header: {
                Text(L10n.lookup("个人数据"))
            } footer: {
                Text(L10n.lookup("“系统日历”和“提醒事项”是 Apple 的系统数据，与 Mocca 自己的共享日历相互独立。"))
            }

            Section {
                Button {
                    openSystemSettings()
                } label: {
                    Label(L10n.lookup("打开 Mocca 系统设置"), systemImage: "gear")
                }
            } footer: {
                Text(L10n.lookup("权限被拒绝后，iOS 通常不会再次弹出申请窗口，需要由你在系统设置中重新开启。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("权限与系统功能"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatuses() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshStatuses() }
        }
    }

    private func permissionRow(_ kind: SystemPermissionKind) -> some View {
        Button {
            handleTap(kind)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 25)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.lookup(kind.title))
                        .foregroundStyle(.primary)
                    Text(L10n.lookup(kind.subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if requestingPermission == kind {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.lookup(snapshot(for: kind).access.title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot(for: kind).access.color)
                        .multilineTextAlignment(.trailing)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(requestingPermission != nil)
        .accessibilityHint(snapshot(for: kind).access == .notRequested ? L10n.lookup("申请权限") : L10n.lookup("打开系统设置"))
    }

    private func snapshot(for kind: SystemPermissionKind) -> SystemPermissionSnapshot {
        snapshots[kind] ?? SystemPermissionSnapshot(access: .unknown)
    }

    private func handleTap(_ kind: SystemPermissionKind) {
        let access = snapshot(for: kind).access
        guard access == .notRequested || access == .unknown else {
            openSystemSettings()
            return
        }

        if kind == .location {
            requestingPermission = kind
            locationRequester.request {
                Task { @MainActor in
                    requestingPermission = nil
                    await refreshStatuses()
                }
            }
            return
        }

        requestingPermission = kind
        Task {
            await request(kind)
            requestingPermission = nil
            await refreshStatuses()
        }
    }

    private func request(_ kind: SystemPermissionKind) async {
        switch kind {
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case .location:
            break
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .photos:
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .photoSaving:
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        case .calendar:
            _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        }
    }

    private func refreshStatuses() async {
        var updated: [SystemPermissionKind: SystemPermissionSnapshot] = [:]

        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        updated[.notifications] = .init(access: notificationAccess(notificationSettings.authorizationStatus))
        updated[.location] = .init(access: locationAccess(locationRequester.authorizationStatus))
        updated[.camera] = .init(access: cameraAccess(AVCaptureDevice.authorizationStatus(for: .video)))
        updated[.photos] = .init(access: photoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)))
        updated[.photoSaving] = .init(access: photoAccess(PHPhotoLibrary.authorizationStatus(for: .addOnly)))
        updated[.calendar] = .init(access: eventAccess(EKEventStore.authorizationStatus(for: .event)))
        updated[.reminders] = .init(access: eventAccess(EKEventStore.authorizationStatus(for: .reminder)))

        snapshots = updated
    }

    private func notificationAccess(_ status: UNAuthorizationStatus) -> SystemPermissionAccess {
        switch status {
        case .notDetermined: .notRequested
        case .denied: .denied
        case .authorized: .allowed
        case .provisional, .ephemeral: .limited
        @unknown default: .unknown
        }
    }

    private func locationAccess(_ status: CLAuthorizationStatus) -> SystemPermissionAccess {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        @unknown default: .unknown
        }
    }

    private func cameraAccess(_ status: AVAuthorizationStatus) -> SystemPermissionAccess {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .allowed
        @unknown default: .unknown
        }
    }

    private func photoAccess(_ status: PHAuthorizationStatus) -> SystemPermissionAccess {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .allowed
        case .limited: .limited
        @unknown default: .unknown
        }
    }

    private func eventAccess(_ status: EKAuthorizationStatus) -> SystemPermissionAccess {
        switch status {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .authorized, .fullAccess: .allowed
        case .writeOnly: .limited
        @unknown default: .unknown
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private enum DefaultModelRole: String, CaseIterable, Identifiable, Equatable {
    case chat
    case title
    case summary
    case compression
    case translation

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .chat: L10n.lookup("聊天模型")
        case .title: L10n.lookup("标题总结模型")
        case .summary: L10n.lookup("摘要模型")
        case .compression: L10n.lookup("压缩模型")
        case .translation: L10n.lookup("翻译模型")
        }
    }

    @MainActor var subtitle: String {
        switch self {
        case .chat:
            L10n.lookup("全局默认的聊天模型；助手没有单独绑定模型时会使用它。")
        case .title:
            L10n.lookup("用于自动生成对话标题，适合选择快速且成本较低的模型。")
        case .summary:
            L10n.lookup("用于自动生成跨聊天摘要与手动整理近期上下文。")
        case .compression:
            L10n.lookup("用于手动压缩对话上下文，适合选择速度较快的模型。")
        case .translation:
            L10n.lookup("用于翻译消息内容，适合选择快速且准确的模型。")
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left"
        case .title: "text.book.closed"
        case .summary: "doc.text"
        case .compression: "archivebox"
        case .translation: "character.book.closed"
        }
    }

    var isSelectable: Bool {
        true
    }

    @MainActor var inheritedChoiceTitle: String? {
        switch self {
        case .chat:
            nil
        case .title, .summary, .translation:
            L10n.lookup("跟随当前对话模型")
        case .compression:
            L10n.lookup("按摘要、标题与对话模型回退")
        }
    }

    @MainActor var inheritedStatusTitle: String {
        inheritedChoiceTitle ?? L10n.lookup("尚未接入")
    }
}

private struct DefaultModelsOverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var activePickerRole: DefaultModelRole?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(DefaultModelRole.allCases) { role in
                    if role.isSelectable {
                        Button {
                            model.performCardHaptic()
                            activePickerRole = role
                        } label: {
                            purposeCard(for: role)
                        }
                        .buttonStyle(.plain)
                    } else {
                        purposeCard(for: role)
                    }
                }

                NavigationLink {
                    OCRSettingsPage()
                } label: {
                    DefaultModelPurposeCard(
                        title: L10n.lookup("OCR 图片识别模型"),
                        subtitle: L10n.lookup("用于识别图片中的文字与画面内容；未单独选择时保持关闭。"),
                        status: ocrStatus,
                        systemImage: "eye",
                        statusProvider: ocrProvider,
                        isAvailable: true,
                        showsChevron: true,
                        accent: Color(uiColor: model.themeAccentUIColor)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.lookup("默认模型"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activePickerRole) { role in
            ModelSelectorView(
                context: .sheet,
                selectedSelection: selection(for: role),
                inheritedChoiceTitle: role.inheritedChoiceTitle,
                screenTitle: role.title,
                chatOnly: true,
                onSelect: { selection in
                    setSelection(selection, for: role)
                }
            )
        }
    }

    private func purposeCard(for role: DefaultModelRole) -> some View {
        DefaultModelPurposeCard(
            title: role.title,
            subtitle: role.subtitle,
            status: status(for: role),
            systemImage: role.systemImage,
            statusProvider: statusProvider(for: role),
            isAvailable: role.isSelectable,
            showsChevron: role.isSelectable,
            accent: Color(uiColor: model.themeAccentUIColor)
        )
    }

    private func selection(for role: DefaultModelRole) -> ModelSelection? {
        switch role {
        case .chat:
            model.selectedModel
        case .title:
            model.preferences.titleModelSelection
        case .summary:
            model.preferences.summaryModelSelection
        case .compression:
            model.preferences.compressionModelSelection
        case .translation:
            model.preferences.translationModelSelection
        }
    }

    private func setSelection(_ selection: ModelSelection?, for role: DefaultModelRole) {
        switch role {
        case .chat:
            guard let selection else { return }
            model.selectModel(providerID: selection.providerID, modelID: selection.modelID)
        case .title:
            model.updatePreferences { $0.titleModelSelection = selection }
        case .summary:
            model.updatePreferences { $0.summaryModelSelection = selection }
        case .compression:
            model.updatePreferences { $0.compressionModelSelection = selection }
        case .translation:
            model.updatePreferences { $0.translationModelSelection = selection }
        }
    }

    private func status(for role: DefaultModelRole) -> String {
        if role == .chat {
            return (model.selectedModelConfiguration?.displayName ?? L10n.lookup("选择模型"))
        }
        guard let selection = selection(for: role) else {
            return role.inheritedStatusTitle
        }
        return explicitModelTitle(selection)
    }

    private func explicitModelTitle(_ selection: ModelSelection) -> String {
        if let context = model.resolvedChatModel(for: selection) {
            return "\(context.model.displayName) · \(context.provider.name)"
        }
        if let provider = model.providers.first(where: { $0.id == selection.providerID }),
           let configuration = provider.models.first(where: {
               $0.id == selection.modelID && $0.capabilities.kind == .chat
           }) {
            return L10n.format("%@ · 已停用，当前回退", [String(describing: configuration.displayName)])
        }
        return L10n.lookup("已选模型失效 · 当前自动回退")
    }

    private func statusProvider(for role: DefaultModelRole) -> ProviderConfiguration? {
        guard role.isSelectable else { return nil }
        if let explicitSelection = selection(for: role) {
            return model.providers.first { $0.id == explicitSelection.providerID }
        }

        switch role {
        case .title, .summary, .translation:
            return currentConversationProvider
        case .compression:
            for fallback in [
                model.preferences.summaryModelSelection,
                model.preferences.titleModelSelection
            ] {
                if let context = model.resolvedChatModel(for: fallback) {
                    return context.provider
                }
            }
            return currentConversationProvider
        case .chat:
            return nil
        }
    }

    private var currentConversationProvider: ProviderConfiguration? {
        model.modelContext(for: model.selectedConversationDisplayAssistant)?.provider
    }

    private var ocrProvider: ProviderConfiguration? {
        guard model.preferences.ocrEnabled,
              let providerID = model.preferences.ocrProviderID,
              let providerUUID = UUID(uuidString: providerID),
              let modelID = model.preferences.ocrModelID,
              let provider = model.providers.first(where: { $0.id == providerUUID && $0.enabled }),
              provider.models.contains(where: { $0.id == modelID }) else {
            return nil
        }
        return provider
    }

    private var ocrStatus: String {
        guard model.preferences.ocrEnabled,
              let providerID = model.preferences.ocrProviderID,
              let providerUUID = UUID(uuidString: providerID),
              let modelID = model.preferences.ocrModelID,
              let provider = model.providers.first(where: { $0.id == providerUUID && $0.enabled }),
              let configuration = provider.models.first(where: { $0.id == modelID }) else {
            return L10n.lookup("未启用")
        }
        return "\(configuration.displayName) · \(provider.name)"
    }
}

private struct DefaultModelPurposeCard: View {
    let title: String
    let subtitle: String
    let status: String
    let systemImage: String
    let statusProvider: ProviderConfiguration?
    let isAvailable: Bool
    let showsChevron: Bool
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.10))
                    AppSymbolImage(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 42, height: 42)

                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                if let statusProvider {
                    ProviderGlyph(provider: statusProvider, size: 24)
                } else {
                    Image(systemName: isAvailable ? "arrow.triangle.branch" : "hammer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isAvailable ? accent : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle().fill(
                                isAvailable
                                    ? accent.opacity(0.10)
                                    : Color.primary.opacity(0.05)
                            )
                        )
                }

                Text(status)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SettingsOverviewSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(L10n.lookup(title))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(0.68))
            .textCase(nil)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SettingsOverviewRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            AppSymbolImage(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            Text(L10n.lookup(title))
                .font(.body.weight(.regular))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

private struct SettingsOverviewValueRow: View {
    let title: String
    let systemImage: String
    let value: String
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            SettingsOverviewRowLabel(title: title, systemImage: systemImage)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct SettingsOverviewRowBackground: View {
    var body: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
    }
}

private struct SettingsSwitchThemeModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let actionTint = Color(uiColor: model.themeActionUIColor)
        let switchTint = Color(uiColor: model.themeSwitchUIColor)
        content
            .tint(actionTint)
            .toggleStyle(SwitchToggleStyle(tint: switchTint))
    }
}

private extension View {
    func settingsOverviewRowStyle() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
            .listRowBackground(SettingsOverviewRowBackground())
            .listRowSeparatorTint(Color.primary.opacity(0.08))
    }
}

extension View {
    func settingsGroupedPageStyle() -> some View {
        listStyle(.insetGrouped)
            .formStyle(.grouped)
            .listSectionSpacing(18)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 12, for: .scrollContent)
            .background(Color(uiColor: .systemGroupedBackground))
            .modifier(SettingsSwitchThemeModifier())
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    var color: Color = .primary

    var body: some View {
        HStack(spacing: 12) {
            AppSymbolImage(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.regular))
                .foregroundStyle(color)
        }
        .contentShape(Rectangle())
    }
}

private struct PreferenceToggle: View {
    @Environment(AppModel.self) private var model

    let title: String
    let systemImage: String
    let keyPath: WritableKeyPath<UserPreferences, Bool>

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { model.preferences[keyPath: keyPath] },
                set: { value in
                    model.performSwitchHaptic()
                    model.updatePreferences { $0[keyPath: keyPath] = value }
                }
            )
        ) {
            SettingsRowLabel(title: title, systemImage: systemImage)
        }
    }
}

private struct PreferenceDetailButton: View {
    let title: String
    let systemImage: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsRowLabel(title: title, systemImage: systemImage)
                Spacer(minLength: 12)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PreferenceNavigationRowLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            AppSymbolImage(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.regular))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

extension Color {
    init?(argb value: Int?) {
        guard let value else { return nil }
        let alpha = Double((value >> 24) & 0xff) / 255.0
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    fileprivate var argbValue: Int {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return 0xff000000
        }
        return (Int((alpha * 255).rounded()) << 24)
            | (Int((red * 255).rounded()) << 16)
            | (Int((green * 255).rounded()) << 8)
            | Int((blue * 255).rounded())
    }
}

private struct MoccaDocumentationPage: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.lookup("欢迎使用 Mocca"), systemImage: "cup.and.saucer.fill")
                        .font(.headline)
                    Text(L10n.lookup("Mocca 是一款由你自行选择模型与服务商的原生 iOS AI 客户端。聊天默认保存在设备上，发送请求时才会把完成回答所需的内容交给你选择的服务。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(L10n.lookup("首次配置")) {
                MoccaDocumentationRow(
                    number: 1,
                    title: L10n.lookup("添加服务商"),
                    detail: L10n.lookup("前往“设置 → 供应商”，选择预设或添加兼容服务，填写自己的 API Key。密钥保存在 Apple 钥匙串中。")
                )
                MoccaDocumentationRow(
                    number: 2,
                    title: L10n.lookup("选择对话模型"),
                    detail: L10n.lookup("在“设置 → 默认模型”选择聊天模型；标题、摘要、压缩和翻译模型可以单独设置或跟随当前对话。")
                )
                MoccaDocumentationRow(
                    number: 3,
                    title: L10n.lookup("开始聊天"),
                    detail: L10n.lookup("回到聊天页新建对话，输入内容后发送。没有可用模型时，Mocca 会提示你先完成配置。")
                )
            }

            Section(L10n.lookup("聊天与内容")) {
                MoccaDocumentationFeature(
                    icon: "paperclip",
                    title: L10n.lookup("图片与文件"),
                    detail: L10n.lookup("通过输入框附件入口选择照片、相机或文件。附件是否能被理解取决于所选模型的能力。")
                )
                MoccaDocumentationFeature(
                    icon: "bubble.left.and.bubble.right",
                    title: L10n.lookup("群聊"),
                    detail: L10n.lookup("群聊可以组合多个助手。分段回复、外观和自动标题可在群聊设置中调整。")
                )
                MoccaDocumentationFeature(
                    icon: "text.book.closed",
                    title: L10n.lookup("记忆、世界书与指令"),
                    detail: L10n.lookup("这些内容会参与提示词组合。加入个人或敏感信息前，请确认你信任将要接收请求的模型服务商。")
                )
                MoccaDocumentationFeature(
                    icon: "doc.richtext",
                    title: L10n.lookup("Markdown 与代码"),
                    detail: L10n.lookup("助手回复支持常见 Markdown、代码块、表格、复制和选择。复杂内容会按手机宽度滚动或换行。")
                )
            }

            Section(L10n.lookup("联网服务与系统工具")) {
                MoccaDocumentationFeature(
                    icon: "globe",
                    title: L10n.lookup("网页搜索"),
                    detail: L10n.lookup("搜索词会发送给你启用的搜索服务，搜索结果可能继续交给当前 AI 服务商生成回答。")
                )
                MoccaDocumentationFeature(
                    icon: "terminal",
                    title: L10n.lookup("MCP 与自定义工具"),
                    detail: L10n.lookup("只连接你信任的服务器。工具可能读取或修改远端数据，执行前请检查服务器地址与权限。")
                )
                MoccaDocumentationFeature(
                    icon: "hand.raised",
                    title: L10n.lookup("照片、相机、位置、日历与提醒事项"),
                    detail: L10n.lookup("权限页只显示状态；Mocca 会在你实际使用对应能力时请求系统授权。工具结果可能发送给当前 AI 服务商。")
                )
                MoccaDocumentationFeature(
                    icon: "speaker.wave.2",
                    title: L10n.lookup("语音服务"),
                    detail: L10n.lookup("语音或文本会发送给你配置的语音服务。当前版本不采集麦克风录音。")
                )
            }

            Section(L10n.lookup("后台生成")) {
                Text(L10n.lookup("Mocca 可以使用通知、实时活动和 iOS 后台任务展示生成进度，但 iOS 会根据电量、温度、内存和网络情况暂停后台工作。重要回复请保持 App 在前台，或稍后回到对话确认最终结果。"))
                    .font(.subheadline)
            }

            Section(L10n.lookup("数据、备份与迁移")) {
                MoccaDocumentationFeature(
                    icon: "internaldrive",
                    title: L10n.lookup("本地存储"),
                    detail: L10n.lookup("聊天、附件和偏好默认保存在设备上。删除 App 可能同时删除这些本地数据。")
                )
                MoccaDocumentationFeature(
                    icon: "arrow.triangle.2.circlepath",
                    title: L10n.lookup("导出与恢复"),
                    detail: L10n.lookup("在“设置 → 数据备份”导出 Mocca 备份。导入前会展示内容与风险；请把重要备份保存在设备之外。")
                )
                MoccaDocumentationFeature(
                    icon: "lock.shield",
                    title: L10n.lookup("保护密钥与备份"),
                    detail: L10n.lookup("不要把 API Key、聊天备份或含个人信息的截图发布到公开 Issue、群聊或网盘分享链接。")
                )
            }

            if AppBuildConfiguration.sponsorshipEnabled {
                Section(L10n.lookup("赞助与纪念装扮")) {
                    Text(L10n.lookup("赞助完全自愿，不影响聊天功能，也不会自动续费。每个档位可以重复投喂；首次购买该档位会解锁对应的纪念装扮，重复购买不会增加新装扮。"))
                        .font(.subheadline)
                    Text(L10n.lookup("购买由 Apple App Store 处理。重复购买不会增加新的装扮副本。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.lookup("常见问题")) {
                MoccaDocumentationFeature(
                    icon: "exclamationmark.triangle",
                    title: L10n.lookup("无法发送或服务报错"),
                    detail: L10n.lookup("检查 API Key、模型名称、账户余额、服务地址和网络代理，再使用服务商页面的连接测试。")
                )
                MoccaDocumentationFeature(
                    icon: "arrow.clockwise",
                    title: L10n.lookup("后台回来没有继续"),
                    detail: L10n.lookup("这是 iOS 后台限制或服务连接中断的常见结果。重新打开对话，必要时再次发送或重新生成。")
                )
                MoccaDocumentationFeature(
                    icon: "shippingbox",
                    title: L10n.lookup("购买项目暂不可用"),
                    detail: L10n.lookup("确认设备已登录 App Store，并稍后重试。")
                )
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("使用文档"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MoccaDocumentationRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MoccaDocumentationFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 3)
    }
}

private struct MoccaPrivacyPolicyPage: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.lookup("Mocca 隐私政策"))
                        .font(.headline)
                    Text(L10n.lookup("生效日期：2026 年 8 月 31 日"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.lookup("Mocca 是由用户自行配置服务商的客户端。聊天和设置默认保存在设备上；只有在你主动使用相应功能时，完成请求所需的数据才会发送给你选择的服务。"))
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }

            Section(L10n.lookup("设备上的数据")) {
                MoccaPrivacyBullet(L10n.lookup("聊天、消息、群聊、记忆、助手与提示词"))
                MoccaPrivacyBullet(L10n.lookup("你选择的图片、文件、头像、背景、字体和本地备份"))
                MoccaPrivacyBullet(L10n.lookup("模型、搜索、语音、界面和工具偏好"))
                MoccaPrivacyBullet(L10n.lookup("API Key 与访问凭据保存在 Apple 钥匙串中"))
                Text(L10n.lookup("Mocca 当前不提供自建账号、云同步、广告或第三方行为分析 SDK。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.lookup("可能发送给第三方的数据")) {
                MoccaPrivacyBullet(L10n.lookup("聊天提示词、必要上下文、附件和工具结果会发送给当前 AI 服务商"))
                MoccaPrivacyBullet(L10n.lookup("搜索词会发送给搜索服务，搜索结果可能继续发送给 AI 服务商"))
                MoccaPrivacyBullet(L10n.lookup("语音功能所需的文本或音频会发送给你配置的语音服务"))
                MoccaPrivacyBullet(L10n.lookup("远程图片、网页、字体和自定义服务器会收到正常网络请求信息"))
                Text(L10n.lookup("第三方如何保留和使用数据，取决于对应服务商的政策与账号设置。请只连接你信任的服务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.lookup("系统权限")) {
                Text(L10n.lookup("Mocca 仅在你实际调用对应功能时申请照片、相机、位置、日历、提醒事项或通知权限。位置可能用于天气请求；日历和提醒事项内容及工具结果可能交给当前 AI 服务商完成回答。你可以随时在 iOS 设置中撤回授权。"))
                    .font(.subheadline)
            }

            Section(L10n.lookup("购买")) {
                Text(L10n.lookup("赞助交易由 Apple StoreKit 与 App Store 处理。Mocca 读取经 Apple 验证的交易记录，用于显示投喂统计和对应的纪念装扮。Mocca 不接收完整付款卡信息。"))
                    .font(.subheadline)
            }

            Section(L10n.lookup("保留、导出与删除")) {
                Text(L10n.lookup("本地数据会保留到你在 App 内删除、恢复其他备份、清除应用数据或卸载 App。你导出的备份由你选择保存位置并负责保管。删除本地数据不会自动删除第三方服务商已经收到的数据；如需删除，请同时使用对应服务商提供的隐私工具。"))
                    .font(.subheadline)
            }

            Section(L10n.lookup("安全与选择")) {
                Text(L10n.lookup("请避免在不受信任的设备或网络中填写 API Key，也不要公开聊天备份。你可以通过停用服务、删除凭据、撤回系统权限或删除本地内容停止后续处理。普通隐私问题可通过 App Store 产品页中的“App 支持”联系开发者。"))
                    .font(.subheadline)
            }

            Section(L10n.lookup("政策更新")) {
                Text(L10n.lookup("功能、服务商或数据流发生变化时，本政策会更新。App 内会保留当前版本的核心说明，App Store 隐私标签与公开隐私政策也应与实际版本保持一致。"))
                    .font(.subheadline)
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("隐私政策"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MoccaPrivacyBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "circle.fill")
            .font(.subheadline)
            .symbolRenderingMode(.hierarchical)
    }
}

private struct MoccaLegalNoticesPage: View {
    var body: some View {
        List {
            Section("Mocca") {
                Text(L10n.lookup("Mocca 是一款为 iPhone 打造的原生 AI 聊天客户端。你可以连接自己的模型服务，创建助手，进行单人对话或多助手群聊。"))
                    .font(.subheadline)
            }

            Section(L10n.lookup("了解 Mocca")) {
                Link(destination: URL(string: "https://uuzsama450.github.io/mocca-website/")!) {
                    Label(L10n.lookup("Mocca 网站"), systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/UUZsama450/mocca")!) {
                    Label(L10n.lookup("GitHub 仓库"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://uuzsama450.github.io/mocca-website/support.html")!) {
                    Label(L10n.lookup("帮助与支持"), systemImage: "questionmark.circle")
                }
            }

            Section(L10n.lookup("代码许可证")) {
                Text(L10n.lookup("Mocca 源码采用 GNU Affero General Public License v3.0。许可证允许在遵守相应来源、修改说明和对应源码义务的前提下使用、研究、修改与再分发。"))
                    .font(.subheadline)
                Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                    Label(L10n.lookup("查看 GNU AGPL v3.0"), systemImage: "doc.text")
                }
            }

            Section(L10n.lookup("第三方名称与素材")) {
                Text(L10n.lookup("Apple、各 AI 服务商、搜索服务与其他第三方的名称、图标和商标归各自权利人所有。应用内出现它们只用于标识用户可自行配置的兼容服务，不代表合作或背书。"))
                    .font(.subheadline)
            }

            Section {
                Text(L10n.lookup("本软件按现状提供，不附带适销性、特定用途适用性或不侵权的保证；完整条款以 GNU AGPL v3.0 正文为准。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("关于与许可"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GroupChatSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var colorAssistant: AssistantProfile?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: preferenceBinding(\.groupChatAutoGenerateTitle)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.lookup("自动生成群聊标题"))
                        Text(L10n.lookup("回复完成后，为仍使用成员占位标题的群聊生成简短标题。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.lookup("这是群聊独立开关；不会影响普通聊天，也不会覆盖手动修改过的标题。"))
            }

            Section {
                Toggle(isOn: preferenceBinding(\.groupChatForceAssistantBubble)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.lookup("群聊显示气泡"))
                        Text(L10n.lookup("在群聊中给每条助手消息加上气泡，分段回复才像一条条独立消息。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.lookup("气泡透明度"))
                        Spacer()
                        Text("\(Int((model.preferences.groupChatBubbleOpacity * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(L10n.lookup("调低可让彩色气泡更柔和，文字更易读。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { model.preferences.groupChatBubbleOpacity },
                            set: { value in
                                model.updatePreferences {
                                    $0.groupChatBubbleOpacity = UserPreferences.clamp(value, min: 0, max: 1)
                                }
                            }
                        ),
                        in: 0...1,
                        step: 0.05
                    )
                    .tint(Color(uiColor: model.themeSliderUIColor))
                }

                Picker(selection: Binding(
                    get: { model.preferences.groupChatBubbleStyle },
                    set: { value in
                        model.performListItemHaptic()
                        model.updatePreferences { $0.groupChatBubbleStyle = value }
                    }
                )) {
                    ForEach(ChatBubbleStyle.bubbleCases) { style in
                        Text(L10n.lookup(style.title)).tag(style)
                    }
                } label: {
                    Text(L10n.lookup("气泡样式"))
                }
                .pickerStyle(.menu)
            }

            Section {
                ForEach(model.assistants) { assistant in
                    Button {
                        model.performListItemHaptic()
                        colorAssistant = assistant
                    } label: {
                        HStack(spacing: 12) {
                            AssistantAvatarView(profile: assistant, size: 34)
                            Text(assistant.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Circle()
                                .fill(assistantBubbleColor(for: assistant) ?? Color(uiColor: .tertiarySystemBackground))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Circle().stroke(.secondary.opacity(0.25), lineWidth: 0.7)
                                }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(L10n.lookup("助手气泡颜色"))
            } footer: {
                Text(L10n.lookup("给每个助手单独配一个气泡颜色，一眼看出谁在说话。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("群聊设置"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $colorAssistant) { assistant in
            GroupAssistantColorSheet(assistant: assistant)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<UserPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in
                model.performSwitchHaptic()
                model.updatePreferences { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func assistantBubbleColor(for assistant: AssistantProfile) -> Color? {
        Color(argb: model.preferences.groupAssistantBubbleColors[assistant.id.uuidString])
    }
}

private struct GroupAssistantColorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let assistant: AssistantProfile

    private let presetARGBs: [Int] = [
        0xffff8fbc, 0xffff6b9d, 0xff7c5cff, 0xff4d7cfe, 0xff16a085,
        0xff22c55e, 0xfff59e0b, 0xffef4444, 0xff06b6d4, 0xff64748b
    ]

    private var selectedARGB: Int? {
        model.preferences.groupAssistantBubbleColors[assistant.id.uuidString]
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AssistantAvatarView(profile: assistant, size: 42)
                    Text(assistant.name)
                        .font(.headline)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), spacing: 16) {
                    colorButton(argb: model.preferences.themePaletteID == .custom
                                ? model.preferences.customThemeColorARGB
                                : model.preferences.themePaletteID.lightAccentARGB)
                    ForEach(presetARGBs, id: \.self) { argb in
                        colorButton(argb: argb)
                    }
                }

                Button {
                    setColor(nil)
                } label: {
                    Label(L10n.lookup("使用默认颜色"), systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.lookup("助手气泡颜色"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func colorButton(argb: Int) -> some View {
        Button {
            setColor(argb)
        } label: {
            Circle()
                .fill(Color(argb: argb) ?? .accentColor)
                .frame(width: 44, height: 44)
                .overlay {
                    if selectedARGB == argb {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
                .overlay {
                    Circle().stroke(.secondary.opacity(0.25), lineWidth: 0.8)
                }
        }
        .buttonStyle(.plain)
    }

    private func setColor(_ argb: Int?) {
        model.performCardHaptic()
        model.updatePreferences { preferences in
            if let argb {
                preferences.groupAssistantBubbleColors[assistant.id.uuidString] = argb
            } else {
                preferences.groupAssistantBubbleColors.removeValue(forKey: assistant.id.uuidString)
            }
        }
    }
}

private struct OCRModelChoice: Identifiable, Hashable {
    let providerID: UUID
    let providerName: String
    let modelID: String
    let modelName: String

    var id: String { "\(providerID.uuidString)::\(modelID)" }
}

private struct OCRSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var isModelPickerPresented = false

    private var selectedChoice: OCRModelChoice? {
        guard let providerID = model.preferences.ocrProviderID,
              let uuid = UUID(uuidString: providerID),
              let provider = model.providers.first(where: { $0.id == uuid }),
              let modelID = model.preferences.ocrModelID,
              let configuration = provider.models.first(where: { $0.id == modelID }) else {
            return nil
        }
        return OCRModelChoice(
            providerID: provider.id,
            providerName: provider.name,
            modelID: configuration.id,
            modelName: configuration.displayName
        )
    }

    private var canEnableOCR: Bool {
        guard let selectedChoice,
              let provider = model.providers.first(where: { $0.id == selectedChoice.providerID && $0.enabled }),
              let configuration = provider.models.first(where: { $0.id == selectedChoice.modelID }) else {
            return false
        }
        return configuration.capabilities.input.contains(.image)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.preferences.ocrEnabled && canEnableOCR },
                    set: { value in
                        model.performSwitchHaptic()
                        // canEnableOCR reads preferences; resolve it before the inout mutation.
                        let shouldEnableOCR = value && canEnableOCR
                        model.updatePreferences { $0.ocrEnabled = shouldEnableOCR }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.lookup("启用 OCR"))
                        Text(L10n.lookup("发送图片时先由独立视觉模型识别文字与画面，再把结果交给当前聊天模型。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!canEnableOCR)

                Button {
                    model.performListItemHaptic()
                    isModelPickerPresented = true
                } label: {
                    HStack {
                        SettingsRowLabel(title: L10n.lookup("OCR 模型"), systemImage: "eye")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(selectedChoice?.modelName ?? L10n.lookup("未设置"))
                                .foregroundStyle(selectedChoice == nil ? Color.secondary : Color.primary)
                                .lineLimit(1)
                            if let providerName = selectedChoice?.providerName {
                                Text(providerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if selectedChoice != nil {
                    Button(L10n.lookup("清除 OCR 模型"), role: .destructive) {
                        model.updatePreferences {
                            $0.ocrEnabled = false
                            $0.ocrProviderID = nil
                            $0.ocrModelID = nil
                        }
                    }
                }
            } footer: {
                Text(L10n.lookup("仅显示具备图片输入能力的聊天模型。OCR 默认关闭；没有配置模型时无法开启。"))
            }

            Section(L10n.lookup("识别提示词")) {
                NavigationLink {
                    OCRPromptEditorPage(initialPrompt: model.preferences.ocrPrompt) { prompt in
                        model.updatePreferences {
                            let cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            $0.ocrPrompt = cleaned.isEmpty ? UserPreferences.defaultOCRPrompt : cleaned
                        }
                    }
                } label: {
                    SettingsRowLabel(title: L10n.lookup("编辑提示词"), systemImage: "text.alignleft")
                }

                Button(L10n.lookup("恢复默认提示词")) {
                    model.performCardHaptic()
                    model.updatePreferences { $0.ocrPrompt = UserPreferences.defaultOCRPrompt }
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("OCR 图片识别"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isModelPickerPresented) {
            ModelSelectorView(
                context: .sheet,
                selectedSelection: selectedChoice.map {
                    ModelSelection(providerID: $0.providerID, modelID: $0.modelID)
                },
                screenTitle: L10n.lookup("选择 OCR 模型"),
                chatOnly: true,
                visionOnly: true,
                onSelect: { selection in
                    guard let selection else { return }
                    model.updatePreferences {
                        $0.ocrProviderID = selection.providerID.uuidString
                        $0.ocrModelID = selection.modelID
                    }
                    isModelPickerPresented = false
                }
            )
        }
    }
}

private struct OCRPromptEditorPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    let onSave: (String) -> Void

    init(initialPrompt: String, onSave: @escaping (String) -> Void) {
        _draft = State(initialValue: initialPrompt)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 12) {
            NativeMultilineTextEditor(
                text: $draft,
                font: .monospacedBody
            )
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Button(L10n.lookup("恢复默认")) { draft = UserPreferences.defaultOCRPrompt }
                    .foregroundStyle(Color(uiColor: model.themeActionUIColor))
                Spacer()
                Button(L10n.lookup("保存")) {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(uiColor: model.themeActionUIColor))
            }
        }
        .padding()
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(L10n.lookup("OCR 提示词"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalStorageBucket: Identifiable {
    enum Kind: String { case images, files, chats, assistants, legacy }
    let kind: Kind
    let bytes: Int64
    let fileCount: Int
    let urls: [URL]
    var id: Kind { kind }

    @MainActor var title: String {
        switch kind {
        case .images: L10n.lookup("图片")
        case .files: L10n.lookup("文件")
        case .chats: L10n.lookup("聊天记录")
        case .assistants: L10n.lookup("助手")
        case .legacy: L10n.lookup("旧版导入文件")
        }
    }

    var icon: String {
        switch kind {
        case .images: "photo"
        case .files: "paperclip"
        case .chats: "bubble.left.and.bubble.right"
        case .assistants: "person.crop.circle"
        case .legacy: "archivebox"
        }
    }
}

private enum LocalStorageInspector {
    static func scan() -> [LocalStorageBucket] {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let attachmentFiles = files(in: root.appendingPathComponent("Attachments", isDirectory: true))
        let imageExtensions = Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"])
        let images = attachmentFiles.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        let regularFiles = attachmentFiles.filter { !imageExtensions.contains($0.pathExtension.lowercased()) }
        let chats = files(in: root.appendingPathComponent("ConversationStore", isDirectory: true))
        let assistants = files(in: root.appendingPathComponent("AssistantMedia", isDirectory: true))
        let legacy = files(in: root.appendingPathComponent("LegacyKelivoFiles", isDirectory: true))
        return [
            bucket(.images, images), bucket(.files, regularFiles), bucket(.chats, chats),
            bucket(.assistants, assistants), bucket(.legacy, legacy)
        ]
    }

    static func byteCount(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private static func bucket(_ kind: LocalStorageBucket.Kind, _ urls: [URL]) -> LocalStorageBucket {
        LocalStorageBucket(kind: kind, bytes: urls.reduce(0) { $0 + byteCount(of: $1) }, fileCount: urls.count, urls: urls)
    }

    private static func files(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
    }
}

private struct StorageSpacePage: View {
    @Environment(AppModel.self) private var model
    @State private var buckets: [LocalStorageBucket] = []
    @State private var isLoading = true
    @State private var confirmsDeleteAllChats = false

    private var totalBytes: Int64 { buckets.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        List {
            usageSection
            detailSection
            chatManagementSection
            safeCleanupSection
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("存储空间"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { refresh() }
        .alert(L10n.lookup("删除全部聊天记录？"), isPresented: $confirmsDeleteAllChats) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("全部删除"), role: .destructive) {
                model.deleteAllConversations()
                refresh()
            }
        } message: {
            Text(L10n.format("将删除当前全部 %@ 个聊天窗口和其中的消息。助手、世界书与设置会保留。", [String(describing: model.conversations.count)]))
        }
    }

    private var usageSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.lookup("已用空间")).font(.caption).foregroundStyle(.secondary)
                    Text(byteString(totalBytes)).font(.title2.bold()).monospacedDigit()
                }
                Spacer()
                if isLoading { ProgressView() }
            }
            .padding(.vertical, 5)
        }
    }

    private var detailSection: some View {
        Section(L10n.lookup("明细")) {
            ForEach(buckets) { bucket in
                storageDestination(for: bucket)
            }
        }
    }

    @ViewBuilder
    private func storageDestination(for bucket: LocalStorageBucket) -> some View {
        if bucket.kind == .chats {
            NavigationLink {
                StoredConversationsPage { refresh() }
            } label: {
                storageRow(bucket)
            }
        } else if bucket.kind == .images || bucket.kind == .files || bucket.kind == .legacy {
            NavigationLink {
                StoredFilesPage(bucket: bucket) { refresh() }
            } label: {
                storageRow(bucket)
            }
        } else {
            storageRow(bucket)
        }
    }

    private var chatManagementSection: some View {
        Section {
            NavigationLink {
                StoredConversationsPage { refresh() }
            } label: {
                Label(L10n.lookup("批量选择聊天窗口"), systemImage: "checklist")
            }
            Button(role: .destructive) {
                confirmsDeleteAllChats = true
            } label: {
                Label(L10n.lookup("一键删除全部会话"), systemImage: "trash")
            }
            .disabled(model.conversations.isEmpty)
        } header: {
            Text(L10n.lookup("聊天记录管理"))
        } footer: {
            Text(L10n.lookup("删除聊天窗口不会删除助手、世界书或供应商设置；操作无法撤销。"))
        }
    }

    private var safeCleanupSection: some View {
        Section(L10n.lookup("可安全清理")) {
            Button {
                OCRService.shared.clearCache()
                model.performCardHaptic()
            } label: {
                Label(L10n.lookup("清理 OCR 内存缓存"), systemImage: "eye.slash")
            }
            Text(L10n.lookup("OCR 缓存只在本次运行中保存，清理不会影响聊天记录或附件。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func storageRow(_ bucket: LocalStorageBucket) -> some View {
        HStack(spacing: 12) {
            Image(systemName: bucket.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.lookup(bucket.title))
                Text(L10n.format("%@ 个文件", [String(describing: bucket.fileCount)]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(byteString(bucket.bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func refresh() {
        isLoading = true
        buckets = LocalStorageInspector.scan()
        isLoading = false
    }
}

private struct StoredConversationsPage: View {
    @Environment(AppModel.self) private var model
    let onChanged: () -> Void
    @State private var selection = Set<UUID>()
    @State private var confirmsDeleteSelection = false
    @State private var confirmsDeleteAll = false

    var body: some View {
        List {
            if model.conversations.isEmpty {
                ContentUnavailableView(L10n.lookup("暂无聊天记录"), systemImage: "bubble.left.and.bubble.right")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(model.conversations) { conversation in
                    Button {
                        if selection.contains(conversation.id) {
                            selection.remove(conversation.id)
                        } else {
                            selection.insert(conversation.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(conversation.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title.isEmpty ? L10n.lookup(Conversation.defaultTitle) : conversation.localizedDisplayTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(L10n.format("%@ 条", [String(describing: model.conversationMessageStore[conversation.id]?.count ?? 0)]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("聊天记录"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selection.count == model.conversations.count && !model.conversations.isEmpty ? L10n.lookup("取消全选") : L10n.lookup("全选")) {
                    selection = selection.count == model.conversations.count
                        ? []
                        : Set(model.conversations.map(\.id))
                }
                .disabled(model.conversations.isEmpty)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button(L10n.lookup("删除全部"), role: .destructive) {
                    confirmsDeleteAll = true
                }
                .disabled(model.conversations.isEmpty)
                Spacer()
                Button(L10n.format("删除 %@ 项", [String(describing: selection.count)]), role: .destructive) {
                    confirmsDeleteSelection = true
                }
                .disabled(selection.isEmpty)
            }
        }
        .alert(L10n.lookup("删除所选聊天？"), isPresented: $confirmsDeleteSelection) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("删除"), role: .destructive) {
                model.deleteConversations(selection)
                selection.removeAll()
                onChanged()
            }
        } message: {
            Text(L10n.format("将删除所选 %@ 个聊天窗口及其中的全部消息。", [String(describing: selection.count)]))
        }
        .alert(L10n.lookup("删除全部聊天？"), isPresented: $confirmsDeleteAll) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("全部删除"), role: .destructive) {
                model.deleteAllConversations()
                selection.removeAll()
                onChanged()
            }
        } message: {
            Text(L10n.format("将删除全部 %@ 个聊天窗口及其中的全部消息。", [String(describing: model.conversations.count)]))
        }
    }
}

private struct StoredFilesPage: View {
    @Environment(\.dismiss) private var dismiss
    let bucket: LocalStorageBucket
    let onChanged: () -> Void
    @State private var files: [URL]
    @State private var selection = Set<URL>()
    @State private var confirmsDelete = false

    init(bucket: LocalStorageBucket, onChanged: @escaping () -> Void) {
        self.bucket = bucket
        self.onChanged = onChanged
        _files = State(initialValue: bucket.urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    var body: some View {
        List(files, id: \.self) { url in
            Button {
                if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
            } label: {
                HStack(spacing: 12) {
                    if bucket.kind == .images, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "doc").frame(width: 44, height: 44).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).lineLimit(1)
                        Text(byteString(LocalStorageInspector.byteCount(of: url))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: selection.contains(url) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(url) ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .settingsGroupedPageStyle()
        .overlay { if files.isEmpty { ContentUnavailableView(L10n.lookup("暂无内容"), systemImage: "tray") } }
        .navigationTitle(bucket.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(selection.count == files.count && !files.isEmpty ? L10n.lookup("清空选择") : L10n.lookup("全选")) {
                    selection = selection.count == files.count ? [] : Set(files)
                }
                Spacer()
                Button(L10n.format("删除 %@ 项", [String(describing: selection.count)]), role: .destructive) { confirmsDelete = true }
                    .disabled(selection.isEmpty)
            }
        }
        .alert(L10n.lookup("确认删除"), isPresented: $confirmsDelete) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("删除"), role: .destructive) { deleteSelection() }
        } message: {
            Text(L10n.lookup("删除后，聊天记录中的对应附件可能无法再打开。"))
        }
    }

    private func deleteSelection() {
        for url in selection { try? FileManager.default.removeItem(at: url) }
        files.removeAll { selection.contains($0) }
        selection.removeAll()
        onChanged()
    }
}

private enum StatsRange: String, CaseIterable, Identifiable {
    case all = "全部"
    case last30 = "最近 30 天"
    case previousMonth = "上个月"
    case previousQuarter = "上个季度"
    case custom = "自定义"
    var id: String { rawValue }
}

private struct ChatHeatmapDay: Identifiable {
    let date: Date
    let count: Int
    let isFuture: Bool

    var id: Date { date }
}

private struct ChatHeatmapWeek: Identifiable {
    let startDate: Date
    let days: [ChatHeatmapDay]

    var id: Date { startDate }
}

private struct ChatActivityHeatmap: View {
    @Environment(\.locale) private var locale
    let weeks: [ChatHeatmapWeek]
    let accentColor: Color

    @State private var selectedDate: Date?

    private let cellSize: CGFloat = 18
    private let cellSpacing: CGFloat = 4
    private let weekdayLabelWidth: CGFloat = 22

    private var days: [ChatHeatmapDay] {
        weeks.flatMap(\.days).filter { !$0.isFuture }
    }

    private var selectedDay: ChatHeatmapDay? {
        guard let selectedDate else { return nil }
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
    }

    private var activeDayCount: Int {
        days.reduce(into: 0) { result, day in
            if day.count > 0 { result += 1 }
        }
    }

    private var totalMessageCount: Int {
        days.reduce(0) { $0 + $1.count }
    }

    private var maximumCount: Int {
        max(days.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            activitySummary
            monthLabels
            heatmapGrid
            legend
        }
        .padding(.vertical, 6)
    }

    private var activitySummary: some View {
        HStack(spacing: 10) {
            if let selectedDay {
                Text(selectedDay.date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale)))
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(L10n.format("%@ 条消息", [String(describing: selectedDay.count.formatted())]))
                    .monospacedDigit()
            } else {
                Text(L10n.format("活跃 %@ 天", [String(describing: activeDayCount)]))
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(L10n.format("%@ 条消息", [String(describing: totalMessageCount.formatted())]))
                    .monospacedDigit()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var monthLabels: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Color.clear
                .frame(width: weekdayLabelWidth, height: 13)

            HStack(alignment: .bottom, spacing: cellSpacing) {
                ForEach(weeks.indices, id: \.self) { index in
                    Text(monthLabel(forWeekAt: index))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: cellSize, height: 13, alignment: .leading)
                }
            }
        }
    }

    private var heatmapGrid: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: cellSpacing) {
                ForEach(0..<7, id: \.self) { weekdayIndex in
                    Text(weekdayLabel(at: weekdayIndex))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: weekdayLabelWidth, height: cellSize)
                }
            }

            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(weeks) { week in
                    VStack(spacing: cellSpacing) {
                        ForEach(week.days) { day in
                            heatmapCell(day)
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(L10n.lookup("少"))
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(legendColor(for: level))
                    .frame(width: 12, height: 12)
            }
            Text(L10n.lookup("多"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.lookup("消息数量由少到多"))
    }

    private func heatmapCell(_ day: ChatHeatmapDay) -> some View {
        let isSelected = selectedDay.map {
            Calendar.current.isDate($0.date, inSameDayAs: day.date)
        } ?? false
        let isToday = Calendar.current.isDateInToday(day.date)

        return Button {
            selectedDate = day.date
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(cellColor(for: day))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color.primary.opacity(0.76)
                                : (isToday ? accentColor.opacity(0.90) : .clear),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
                .frame(width: cellSize, height: cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(day.isFuture)
        .accessibilityHidden(day.isFuture)
        .accessibilityLabel(day.date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale)))
        .accessibilityValue(L10n.format("%@ 条消息", [String(describing: day.count)]))
    }

    private func monthLabel(forWeekAt index: Int) -> String {
        guard weeks.indices.contains(index) else { return "" }
        let calendar = Calendar.current
        let week = weeks[index]
        let firstOfMonth = week.days.first(where: {
            calendar.component(.day, from: $0.date) == 1
        })
        if index == 0 {
            return (firstOfMonth?.date ?? week.startDate)
                .formatted(.dateTime.month(.abbreviated).locale(locale))
        }
        guard let firstOfMonth else {
            return ""
        }
        return firstOfMonth.date.formatted(.dateTime.month(.abbreviated).locale(locale))
    }

    private func weekdayLabel(at index: Int) -> String {
        switch index {
        case 0: L10n.lookup("一")
        case 2: L10n.lookup("三")
        case 4: L10n.lookup("五")
        default: ""
        }
    }

    private func cellColor(for day: ChatHeatmapDay) -> Color {
        guard !day.isFuture else { return .clear }
        guard day.count > 0 else { return Color.secondary.opacity(0.10) }
        return accentColor.opacity(levelOpacity(heatLevel(for: day.count)))
    }

    private func legendColor(for level: Int) -> Color {
        guard level > 0 else { return Color.secondary.opacity(0.10) }
        return accentColor.opacity(levelOpacity(level))
    }

    private func heatLevel(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        let normalized = log1p(Double(count)) / log1p(Double(maximumCount))
        return min(max(Int(ceil(normalized * 4)), 1), 4)
    }

    private func levelOpacity(_ level: Int) -> Double {
        switch level {
        case 1: 0.24
        case 2: 0.46
        case 3: 0.70
        default: 1.0
        }
    }
}

private struct UsageStatisticsPage: View {
    @Environment(AppModel.self) private var model
    @State private var range: StatsRange = .all
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now
    @State private var customEnd = Date.now

    private var filteredMessages: [ChatMessage] {
        model.messagesByConversation.values.flatMap { $0 }.filter { contains($0.createdAt) }
    }

    private var filteredConversations: [Conversation] { model.conversations.filter { contains($0.createdAt) } }
    private var promptTokens: Int { filteredMessages.reduce(0) { $0 + ($1.tokenUsage?.promptTokens ?? 0) } }
    private var completionTokens: Int { filteredMessages.reduce(0) { $0 + ($1.tokenUsage?.completionTokens ?? 0) } }
    private var cachedTokens: Int { filteredMessages.reduce(0) { $0 + ($1.tokenUsage?.cachedTokens ?? 0) } }

    var body: some View {
        List {
            Section {
                Picker(L10n.lookup("时间范围"), selection: $range) {
                    ForEach(StatsRange.allCases) { Text(L10n.lookup($0.rawValue)).tag($0) }
                }
                if range == .custom {
                    DatePicker(L10n.lookup("开始"), selection: $customStart, displayedComponents: .date)
                    DatePicker(L10n.lookup("结束"), selection: $customEnd, in: customStart..., displayedComponents: .date)
                }
            }

            Section(L10n.lookup("总览")) {
                statsRow(L10n.lookup("总对话数"), value: filteredConversations.count, icon: "bubble.left.and.bubble.right")
                statsRow(L10n.lookup("总消息数"), value: filteredMessages.count, icon: "message")
                statsRow(L10n.lookup("输入 Tokens"), value: promptTokens, icon: "arrow.up")
                statsRow(L10n.lookup("输出 Tokens"), value: completionTokens, icon: "arrow.down")
                statsRow(L10n.lookup("缓存 Tokens"), value: cachedTokens, icon: "bolt.horizontal")
                statsRow(L10n.lookup("应用启动次数"), value: UserDefaults.standard.integer(forKey: "app_launch_count_v1"), icon: "power")
            }

            Section(L10n.lookup("聊天热力图（最近 12 周）")) {
                ChatActivityHeatmap(
                    weeks: heatmapWeeks,
                    accentColor: Color(uiColor: model.themeActionUIColor)
                )
            }

            rankingSection(L10n.lookup("模型使用率"), values: modelRanking)
            rankingSection(L10n.lookup("助手使用率"), values: assistantRanking)
            rankingSection(L10n.lookup("话题内容量"), values: topicRanking)
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("统计"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statsRow(_ title: String, value: Int, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func rankingSection(_ title: String, values: [(String, Int)]) -> some View {
        Section(title) {
            if values.isEmpty {
                Text(L10n.lookup("暂无统计数据")).foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.prefix(10).enumerated()), id: \.offset) { index, item in
                    HStack {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                        Text(item.0).lineLimit(1)
                        Spacer()
                        Text(item.1.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private var modelRanking: [(String, Int)] {
        sortedCounts(filteredMessages.filter { $0.role == .assistant }.compactMap(\.modelID))
    }

    private var assistantRanking: [(String, Int)] {
        let names = Dictionary(uniqueKeysWithValues: model.assistants.map { ($0.id.uuidString, $0.name) })
        let ids = filteredMessages.filter { $0.role == .assistant }.compactMap(\.groupID)
        return sortedCounts(ids).map { (names[$0.0] ?? AssistantProfile.defaultName, $0.1) }
    }

    private var topicRanking: [(String, Int)] {
        filteredConversations.map { conversation in
            (conversation.title, model.conversationMessageStore[conversation.id, default: []].filter { contains($0.createdAt) }.count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    private var heatmapWeeks: [ChatHeatmapWeek] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: .now)
        let weekdayOffset = (
            calendar.component(.weekday, from: today)
                - calendar.firstWeekday
                + 7
        ) % 7
        guard let currentWeekStart = calendar.date(
            byAdding: .day,
            value: -weekdayOffset,
            to: today
        ), let firstWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -11,
            to: currentWeekStart
        ) else {
            return []
        }

        let counts = Dictionary(grouping: filteredMessages) {
            calendar.startOfDay(for: $0.createdAt)
        }.mapValues(\.count)

        return (0..<12).compactMap { weekOffset in
            guard let weekStart = calendar.date(
                byAdding: .weekOfYear,
                value: weekOffset,
                to: firstWeekStart
            ) else {
                return nil
            }
            let days = (0..<7).compactMap { dayOffset -> ChatHeatmapDay? in
                guard let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: weekStart
                ) else {
                    return nil
                }
                return ChatHeatmapDay(
                    date: date,
                    count: counts[date, default: 0],
                    isFuture: date > today
                )
            }
            return ChatHeatmapWeek(startDate: weekStart, days: days)
        }
    }

    private func sortedCounts(_ values: [String]) -> [(String, Int)] {
        Dictionary(grouping: values, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    private func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: .now)
        let bounds: (Date?, Date?) = {
            switch range {
            case .all: return (nil, nil)
            case .last30: return (calendar.date(byAdding: .day, value: -29, to: today), today)
            case .previousMonth:
                let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
                let end = calendar.date(byAdding: .day, value: -1, to: thisMonth)!
                return (calendar.date(from: calendar.dateComponents([.year, .month], from: end)), end)
            case .previousQuarter:
                let components = calendar.dateComponents([.year, .month], from: today)
                let month = components.month ?? 1
                let quarterStartMonth = ((month - 1) / 3) * 3 + 1
                let thisQuarter = calendar.date(from: DateComponents(year: components.year, month: quarterStartMonth, day: 1))!
                let end = calendar.date(byAdding: .day, value: -1, to: thisQuarter)!
                return (calendar.date(byAdding: .month, value: -2, to: calendar.date(from: calendar.dateComponents([.year, .month], from: end))!), end)
            case .custom: return (calendar.startOfDay(for: customStart), calendar.startOfDay(for: customEnd))
            }
        }()
        if let start = bounds.0, day < start { return false }
        if let end = bounds.1, day > end { return false }
        return true
    }
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct AssistantManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var editingAssistant: AssistantProfile?
    @State private var selectedAssistantIDs: Set<UUID> = []
    @State private var pendingDeletionIDs: Set<UUID> = []
    @State private var isDeleteErrorPresented = false
    @State private var editMode: EditMode = .inactive

    private var canDeleteSelection: Bool {
        !selectedAssistantIDs.isEmpty && selectedAssistantIDs.count < model.assistants.count
    }

    var body: some View {
        List {
            Section {
                ForEach(model.assistants) { assistant in
                    Button {
                        if editMode == .active {
                            if !selectedAssistantIDs.insert(assistant.id).inserted {
                                selectedAssistantIDs.remove(assistant.id)
                            }
                        } else {
                            editingAssistant = assistant
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if editMode == .active {
                                Image(systemName: selectedAssistantIDs.contains(assistant.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(selectedAssistantIDs.contains(assistant.id) ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            AssistantSummaryRow(
                                assistant: assistant,
                                isCurrent: assistant.id == model.currentAssistantID,
                                accessorySystemImage: editMode == .active ? nil : "chevron.right"
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(editMode == .active
                        ? L10n.lookup(selectedAssistantIDs.contains(assistant.id) ? "已选择" : "未选择") : "")
                    .accessibilityIdentifier("assistantManagement.row.\(assistant.id.uuidString)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if editMode != .active && model.assistants.count > 1 {
                            Button { pendingDeletionIDs = [assistant.id] } label: {
                                Label(L10n.lookup("删除"), systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
                .onMove(perform: model.moveAssistants)
            } header: {
                Text(L10n.lookup("助手列表")).textCase(nil)
            } footer: {
                Text(L10n.lookup("点按进入编辑；点击右上角“编辑”可以多选删除或调整顺序。至少保留一个助手。"))
            }
        }
        .settingsGroupedPageStyle()
        .environment(\.editMode, $editMode)
        .navigationTitle(L10n.lookup("助手"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active {
                HStack(spacing: 12) {
                    Text(selectedAssistantIDs.count == model.assistants.count
                        ? L10n.lookup("至少保留一个助手")
                        : L10n.format("已选择 %@ 个助手", [String(selectedAssistantIDs.count)]))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L10n.format("删除所选（%@）", [String(selectedAssistantIDs.count)]), role: .destructive) {
                        pendingDeletionIDs = selectedAssistantIDs
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canDeleteSelection)
                    .accessibilityIdentifier("assistantManagement.deleteSelected")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(editMode == .active ? L10n.lookup("完成") : L10n.lookup("编辑")) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedAssistantIDs = []
                        editMode = editMode == .active ? .inactive : .active
                    }
                }
                .accessibilityIdentifier("assistantManagement.edit")
                Button {
                    editingAssistant = AssistantProfile(name: L10n.lookup("新助手"), temperature: 0.6)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.lookup("新建助手"))
            }
        }
        .onChange(of: model.assistants.map(\.id)) { _, ids in
            selectedAssistantIDs.formIntersection(ids)
        }
        .navigationDestination(item: $editingAssistant) { assistant in
            AssistantEditorView(profile: assistant, presentationContext: .navigation) { saved in
                model.upsertAssistant(saved)
            }
        }
        .alert(L10n.lookup("删除助手"), isPresented: Binding(
            get: { !pendingDeletionIDs.isEmpty },
            set: { if !$0 { pendingDeletionIDs = [] } }
        )) {
            Button(L10n.lookup("取消"), role: .cancel) { pendingDeletionIDs = [] }
            Button(L10n.lookup("删除"), role: .destructive) {
                let ids = pendingDeletionIDs
                pendingDeletionIDs = []
                if model.deleteAssistants(ids) {
                    selectedAssistantIDs.subtract(ids)
                } else {
                    isDeleteErrorPresented = true
                }
            }
        } message: {
            Text(L10n.format("删除所选的 %@ 个助手及其单聊？相关群聊会移除这些成员，不足两人的群聊也会删除。", [String(pendingDeletionIDs.count)]))
        }
        .alert(L10n.lookup("无法删除助手"), isPresented: $isDeleteErrorPresented) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("请保留至少一个助手，并在聊天数据加载完成后重试。"))
        }
    }
}

/// Settings explanations share native positioning, dismissal and animation.
/// Its state stays local so opening a bubble does not rebuild the whole form.
struct SettingsInfoButton<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isPresented = false
    @State private var presenter = SettingsInfoPopoverAnchor<AnyView>.Coordinator()
    let title: String
    let identifier: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button {
            model.performListItemHaptic()
            presenter.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("%@说明", [title]))
        .accessibilityHint(L10n.lookup("显示或隐藏说明气泡"))
        .accessibilityValue(isPresented ? L10n.lookup("已展开") : L10n.lookup("已收起"))
        .accessibilityIdentifier(identifier)
        .background {
            SettingsInfoPopoverAnchor<AnyView>(
                presenter: presenter,
                isPresented: $isPresented,
                identifier: identifier,
                colorScheme: colorScheme,
                maximumHeight: verticalSizeClass == .compact ? 220 : 420
            ) {
                AnyView(explanation
                    .textCase(nil)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.colorScheme, colorScheme)
                    .accessibilityAction(.escape) { [weak presenter] in presenter?.dismiss() }
                )
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
    }
}

/// A Form section header can keep invalidating SwiftUI's popover presentation
/// preferences on iOS 27. Present from a stable UIKit anchor instead, with an
/// independent content host and a size chosen once before the native animation.
/// No presentation/background preference or measured size flows into the Form.
private struct SettingsInfoPopoverAnchor<Content: View>: UIViewRepresentable {
    let presenter: Coordinator
    @Binding var isPresented: Bool
    let identifier: String
    let colorScheme: ColorScheme
    let maximumHeight: CGFloat
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { presenter }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.configure(self, anchor: view)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.invalidate(anchor: view)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        private var configuration: SettingsInfoPopoverAnchor?
        private weak var anchor: UIView?
        private var presented: SettingsInfoHostingController?
        private var isDismissing = false
        private var reopenAfterDismissal = false

        func configure(_ configuration: SettingsInfoPopoverAnchor, anchor: UIView) {
            self.configuration = configuration
            self.anchor = anchor
        }

        func toggle() {
            // The action consults UIKit, not the cached accessibility state.
            // Even if every dismissal notification is missed, the next tap
            // opens a fresh popover rather than toggling a stale Bool off.
            guard !isDismissing else {
                reopenAfterDismissal = true
                return
            }
            if let presented, isVisible(presented) {
                dismiss()
            } else {
                show()
            }
        }

        private func isVisible(_ controller: UIViewController) -> Bool {
            guard controller.presentingViewController?.presentedViewController === controller,
                  let view = controller.viewIfLoaded, view.window != nil,
                  !view.bounds.isEmpty, !controller.isBeingDismissed else { return false }
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0.01 { return false }
                ancestor = current.superview
            }
            return true
        }

        func dismiss() { dismiss(reopen: false) }

        private func dismiss(reopen: Bool) {
            reopenAfterDismissal = reopen
            guard !isDismissing else { return }
            guard let presented else {
                configuration?.isPresented = false
                return
            }
            isDismissing = true
            presented.dismiss(animated: true) { [weak self, weak presented] in
                guard let self else { return }
                if let presented { self.finishDismissal(of: presented) }
                let reopen = self.reopenAfterDismissal
                self.reopenAfterDismissal = false
                if reopen, self.presented == nil { self.show() }
            }
        }

        private func show() {
            guard let configuration, let anchor, let window = anchor.window else { return }
            if let stale = presented {
                if stale.presentingViewController?.presentedViewController === stale {
                    dismiss(reopen: true)
                    return
                }
                finishDismissal(of: stale)
            }
            var responder: UIResponder? = anchor
            while responder != nil, !(responder is UIViewController) {
                responder = responder?.next
            }
            guard let presenter = responder as? UIViewController,
                  presenter.presentedViewController == nil else {
                configuration.isPresented = false
                return
            }

            let width = min(320, max(1, window.bounds.width - window.safeAreaInsets.left - window.safeAreaInsets.right - 32))
            let limit = min(configuration.maximumHeight,
                            max(1, window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom - 32))
            let content = configuration.content().frame(width: width)
            let host = SettingsInfoHostingController(rootView: AnyView(content))
            host.onDismissal = { [weak self] controller in
                self?.finishDismissal(of: controller)
            }
            host.overrideUserInterfaceStyle = configuration.colorScheme == .dark ? .dark : .light
            host.sizingOptions = []
            let naturalHeight = ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            let height = min(max(1, naturalHeight), limit)
            // Let the scroll viewport follow UIKit's actual bounds, including
            // a smaller placement after rotation. Short copy remains still.
            host.rootView = AnyView(
                ScrollView { content }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: width)
                    .accessibilityIdentifier(configuration.identifier + ".popover")
            )
            host.view.backgroundColor = .clear
            host.preferredContentSize = CGSize(width: width, height: height)
            host.modalPresentationStyle = .popover
            guard let popover = host.popoverPresentationController else { return }
            popover.delegate = self
            popover.sourceView = anchor
            popover.sourceRect = .null
            popover.permittedArrowDirections = [.up, .down]
            if #available(iOS 26.1, *) {
                popover.backgroundEffect = UIBlurEffect(style: .regular)
            }
            presented = host
            presenter.present(host, animated: true)
            configuration.isPresented = true
        }

        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishDismissal(of: presentationController.presentedViewController)
        }

        private func finishDismissal(of controller: UIViewController) {
            // Both the delegate and lifecycle completion may report the same
            // dismissal. An older callback must not clear a newer popover.
            guard controller === presented else { return }
            presented = nil
            isDismissing = false
            configuration?.isPresented = false
        }

        func invalidate(anchor view: UIView) {
            // List headers can replace their backing UIView while keeping the
            // button alive. Teardown of an old anchor must not clear the new one.
            guard anchor === view else { return }
            configuration = nil
            anchor = nil
            reopenAfterDismissal = false
            presented?.dismiss(animated: false)
            presented = nil
            isDismissing = false
        }
    }
}

private final class SettingsInfoHostingController: UIHostingController<AnyView> {
    var onDismissal: ((UIViewController) -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The presentation delegate only covers interactive dismissals. A
        // presenter/system-driven dismissal must also clear the SwiftUI state,
        // otherwise the next tap merely toggles an invisible popover off.
        if isBeingDismissed || presentingViewController == nil {
            onDismissal?(self)
        }
    }
}

struct SettingsInfoText: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var largeFilePreference = LargeFileReminderPreference.shared
    @State private var activeSheet: PreferencesSheetRoute?

    fileprivate init(initialSheet: PreferencesSheetRoute? = nil) {
        _activeSheet = State(initialValue: initialSheet)
    }

    private var showsChatInputBackgroundOpacity: Bool {
        if #available(iOS 26.0, *) {
            return !model.preferences.useLiquidGlassComposer
        }
        return true
    }

    private var historicalImageResendLimitText: String {
        if model.preferences.historicalImageResendUnlimited {
            return L10n.lookup("无上限")
        }
        let limit = min(max(model.preferences.historicalImageResendLimit, 1), 10)
        return L10n.format("最新 %@ 张", [String(describing: limit)])
    }

    private var historicalImageResendSliderBinding: Binding<Double> {
        Binding(
            get: {
                if model.preferences.historicalImageResendUnlimited {
                    return 11
                }
                return Double(min(max(model.preferences.historicalImageResendLimit, 1), 10))
            },
            set: { value in
                let selection = min(max(Int(value.rounded()), 1), 11)
                let previousSelection = model.preferences.historicalImageResendUnlimited
                    ? 11
                    : min(max(model.preferences.historicalImageResendLimit, 1), 10)
                guard selection != previousSelection else { return }

                model.performListItemHaptic()
                model.updatePreferences { preferences in
                    if selection == 11 {
                        preferences.historicalImageResendUnlimited = true
                    } else {
                        preferences.historicalImageResendUnlimited = false
                        preferences.historicalImageResendLimit = selection
                    }
                }
            }
        )
    }

    var body: some View {
        Form {
            Section(L10n.lookup("外观与阅读")) {
                NavigationLink {
                    ThemePreferencesPage()
                } label: {
                    SettingsRowLabel(title: L10n.lookup("主题设置"), systemImage: "paintpalette")
                }

                NavigationLink {
                    AppFontPreferencesPage()
                } label: {
                    HStack(spacing: 12) {
                        SettingsRowLabel(title: L10n.lookup("应用字体"), systemImage: "textformat")
                        Spacer(minLength: 8)
                        Text(model.preferences.appFontDisplayName ?? L10n.lookup("系统默认"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                PreferenceDetailButton(
                    title: L10n.lookup("聊天字体大小"),
                    systemImage: "textformat.size",
                    detail: "\(Int((model.preferences.chatFontScale * 100).rounded()))%"
                ) {
                    activeSheet = .chatFont
                }

                NavigationLink {
                    ChatBubblePreferencesPage()
                } label: {
                    SettingsRowLabel(title: L10n.lookup("聊天气泡"), systemImage: "message.fill")
                }
            }

            Section(L10n.lookup("聊天内容")) {
                NavigationLink {
                    ChatSegmentationPreferencesPage()
                } label: {
                    PreferenceNavigationRowLabel(
                        title: L10n.lookup("聊天分段"),
                        subtitle: L10n.lookup("回复分段、气泡间距与连续发送"),
                        systemImage: "text.bubble"
                    )
                }

                NavigationLink {
                    ChatItemDisplayPreferencesPage()
                } label: {
                    PreferenceNavigationRowLabel(
                        title: L10n.lookup("消息显示"),
                        subtitle: L10n.lookup("头像、名称、时间与消息操作"),
                        systemImage: "message"
                    )
                }

                NavigationLink {
                    RenderingPreferencesPage()
                } label: {
                    PreferenceNavigationRowLabel(
                        title: L10n.lookup("排版与渲染"),
                        subtitle: L10n.lookup("Markdown、间距、代码块与网页"),
                        systemImage: "text.alignleft"
                    )
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { !largeFilePreference.isDisabled },
                    set: { largeFilePreference.setEnabled($0) }
                )) {
                    SettingsRowLabel(title: L10n.lookup("大文件提醒"), systemImage: "doc")
                }
            } footer: {
                Text(L10n.lookup("添加文本超过 60,000 字符或大小超过 100 MB 的文件时提醒。"))
            }

            Section {
                PreferenceDetailButton(
                    title: L10n.lookup("模型入口样式"),
                    systemImage: "sparkles",
                    detail: model.preferences.composerModelEntryStyle.title
                ) {
                    activeSheet = .modelEntryStyle
                }

                PreferenceDetailButton(
                    title: L10n.lookup("输入框占位文字"),
                    systemImage: "text.cursor",
                    detail: model.preferences.chatInputPlaceholder.isEmpty
                        ? L10n.lookup("默认")
                        : model.preferences.chatInputPlaceholder
                ) {
                    activeSheet = .inputPlaceholder
                }

                Toggle(
                    isOn: Binding(
                        get: { model.preferences.composerHeightAnimationEnabled },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences { $0.composerHeightAnimationEnabled = value }
                        }
                    )
                ) {
                    SettingsRowLabel(title: L10n.lookup("输入框伸缩动画"), systemImage: "arrow.up.and.down")
                }
                .accessibilityIdentifier("composerHeightAnimationEnabled")

                Text(L10n.lookup("开启时，输入区域随换行平滑伸缩；关闭后直接到位。手动滚动和光标闪烁不受影响。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    isOn: Binding(
                        get: { model.preferences.useLiquidGlassComposer },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences { $0.useLiquidGlassComposer = value }
                        }
                    )
                ) {
                    SettingsRowLabel(
                        title: L10n.lookup("Liquid Glass 输入框"),
                        systemImage: "circle.hexagongrid.fill"
                    )
                }

                if showsChatInputBackgroundOpacity {
                    PreferenceDetailButton(
                        title: L10n.lookup("输入框背景透明度"),
                        systemImage: "circle.lefthalf.filled",
                        detail: L10n.format("亮 %@%% / 暗 %@%%", [String(describing: Int((model.preferences.chatInputBackgroundOpacityLight * 100).rounded())), String(describing: Int((model.preferences.chatInputBackgroundOpacityDark * 100).rounded()))])
                    ) {
                        activeSheet = .inputOpacity
                    }
                }
            } header: {
                Text(L10n.lookup("输入框"))
            } footer: {
                Text(L10n.lookup("在 iOS 26 开启 Liquid Glass 后，输入框外观由系统玻璃接管，因此普通背景透明度设置会隐藏。"))
            }

            Section {
                PreferenceDetailButton(
                    title: L10n.lookup("图片压缩质量"),
                    systemImage: "photo.on.rectangle",
                    detail: model.preferences.userImageCompressionQuality >= 100
                        ? "JPEG 100%"
                        : "\(model.preferences.userImageCompressionQuality)%"
                ) {
                    activeSheet = .imageQuality
                }

                Toggle(
                    isOn: Binding(
                        get: { model.preferences.resendHistoricalImages },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences { $0.resendHistoricalImages = value }
                        }
                    )
                ) {
                    SettingsRowLabel(
                        title: L10n.lookup("持续发送历史图片"),
                        systemImage: "photo.on.rectangle.angled"
                    )
                }

                if model.preferences.resendHistoricalImages {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            SettingsRowLabel(
                                title: L10n.lookup("每轮历史图片上限"),
                                systemImage: "photo.stack"
                            )

                            Spacer(minLength: 12)

                            Text(historicalImageResendLimitText)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: historicalImageResendSliderBinding,
                            in: 1...11,
                            step: 1
                        ) {
                            Text(L10n.lookup("每轮历史图片上限"))
                        } minimumValueLabel: {
                            Text("1")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("∞")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .tint(Color(uiColor: model.themeSliderUIColor))
                        .accessibilityValue(historicalImageResendLimitText)
                        .accessibilityHint(L10n.lookup("最右端为无上限"))
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                HStack(spacing: 5) {
                    Text(L10n.lookup("图片与上下文"))

                    SettingsInfoButton(title: L10n.lookup("图片与上下文"), identifier: "preferences.imageContextInfo") {
                        SettingsInfoText(
                            title: L10n.lookup("图片压缩"),
                            text: L10n.lookup("百分比表示新图片保存时的 JPEG 质量，不是尺寸比例；最长边会限制为 2048 像素。")
                        )
                        SettingsInfoText(
                            title: L10n.lookup("历史图片"),
                            text: L10n.lookup("关闭时只发送本轮新选图片；开启后可用滑杆选择当前上下文中最新 1–10 张，最右端“无上限”会发送其中全部未折叠历史图片。本轮新图不占上限，折叠后的旧图不再重发。")
                        )
                    }
                }
            } footer: {
                Text(L10n.lookup("压缩质量只影响新加入的图片；历史图片选项只影响后续请求。选择“无上限”可能增加请求耗时与模型用量。"))
            }

            Section(L10n.lookup("使用体验")) {
                NavigationLink {
                    BehaviorStartupPreferencesPage()
                } label: {
                    PreferenceNavigationRowLabel(
                        title: L10n.lookup("行为与启动"),
                        subtitle: L10n.lookup("思考、重新生成、导航、侧栏与新聊天"),
                        systemImage: "sparkles"
                    )
                }

                NavigationLink {
                    HapticsPreferencesPage()
                } label: {
                    PreferenceNavigationRowLabel(
                        title: L10n.lookup("震动反馈"),
                        subtitle: L10n.lookup("全局与各个操作场景的触觉"),
                        systemImage: "iphone.radiowaves.left.and.right"
                    )
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("偏好设置"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .chatFont:
                PreferenceSliderSheet(
                    title: L10n.lookup("聊天字体大小"),
                    subtitle: L10n.lookup("调整消息正文和代码块字号。"),
                    range: 0.5...1.5,
                    step: 0.05,
                    value: Binding(
                        get: { model.preferences.chatFontScale },
                        set: { value in model.updatePreferences { $0.chatFontScale = UserPreferences.clamp(value, min: 0.5, max: 1.5) } }
                    ),
                    valueText: { "\(Int(($0 * 100).rounded()))%" },
                    leadingText: "50%",
                    trailingText: "150%"
                )
            case .assistantLineSpacing:
                PreferenceSliderSheet(
                    title: L10n.lookup("助手消息行间距"),
                    subtitle: L10n.lookup("调整同一段文字换行后的松紧。数值越大，段落越舒展。"),
                    range: 2.0...10.0,
                    step: 0.5,
                    value: Binding(
                        get: { model.preferences.assistantMessageLineSpacing },
                        set: { value in
                            model.updatePreferences {
                                $0.assistantMessageLineSpacing = UserPreferences.clamp(value, min: 2.0, max: 10.0)
                            }
                        }
                    ),
                    valueText: { String(format: "%.1f pt", $0) },
                    leadingText: L10n.lookup("紧凑 2.0"),
                    trailingText: L10n.lookup("宽松 10.0")
                )
            case .assistantMarkdownBlockSpacing:
                PreferenceSliderSheet(
                    title: L10n.lookup("Markdown 块间距"),
                    subtitle: L10n.lookup("统一调整段落、标题、列表、引用和分隔线之间的留白；不会改变同一段里的行距。"),
                    range: 0.5...1.5,
                    step: 0.05,
                    value: Binding(
                        get: { model.preferences.assistantMarkdownBlockSpacingScale },
                        set: { value in
                            model.updatePreferences {
                                $0.assistantMarkdownBlockSpacingScale = UserPreferences.clamp(value, min: 0.5, max: 1.5)
                            }
                        }
                    ),
                    valueText: { "\(Int(($0 * 100).rounded()))%" },
                    leadingText: L10n.lookup("紧凑 50%"),
                    trailingText: L10n.lookup("宽松 150%")
                )
            case .assistantMarkdownListItemSpacing:
                PreferenceSliderSheet(
                    title: L10n.lookup("Markdown 列表项间距"),
                    subtitle: L10n.lookup("只调整相邻圆点或编号条目之间的额外留白；不会改变条目内部的换行行距，也不会改变列表与其他段落的距离。"),
                    range: 0.0...12.0,
                    step: 0.5,
                    value: Binding(
                        get: { model.preferences.assistantMarkdownListItemSpacing },
                        set: { value in
                            model.updatePreferences {
                                $0.assistantMarkdownListItemSpacing = UserPreferences.clamp(value, min: 0.0, max: 12.0)
                            }
                        }
                    ),
                    valueText: { String(format: "%.1f pt", $0) },
                    leadingText: L10n.lookup("紧凑 0.0"),
                    trailingText: L10n.lookup("宽松 12.0")
                )
            case .inputOpacity:
                ChatInputOpacitySheet()
            case .inputPlaceholder:
                ChatInputPlaceholderSheet(currentValue: model.preferences.chatInputPlaceholder)
            case .modelEntryStyle:
                ComposerModelEntryStyleSheet()
            case .imageQuality:
                PreferenceSliderSheet(
                    title: L10n.lookup("图片压缩质量"),
                    subtitle: L10n.lookup("影响从相册或相机加入待发送区时保存的 JPEG 质量；百分比不是尺寸比例，新图片最长边会限制为 2048 像素。"),
                    range: 1.0...100.0,
                    step: 1,
                    value: Binding(
                        get: { Double(model.preferences.userImageCompressionQuality) },
                        set: { value in model.updatePreferences { $0.userImageCompressionQuality = min(max(Int(value.rounded()), 1), 100) } }
                    ),
                    valueText: { $0 >= 100 ? "JPEG 100%" : "\(Int($0.rounded()))%" },
                    leadingText: "1%",
                    trailingText: "100%"
                )
            }
        }
    }
}

private struct ComposerModelEntryStyleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ComposerModelEntryStyle.allCases) { style in
                        Button {
                            model.performListItemHaptic()
                            model.updatePreferences { $0.composerModelEntryStyle = style }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: style == .name ? "sparkles" : "bubble.left")
                                    .frame(width: 24)
                                Text(style.title)
                                Spacer()
                                if model.preferences.composerModelEntryStyle == style {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color(uiColor: model.themeAccentUIColor))
                                }
                            }
                            .foregroundStyle(.primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.preferences.composerModelEntryStyle == style ? .isSelected : [])
                    }
                } footer: {
                    Text(L10n.lookup("默认显示模型名称，长名称会在末尾省略。两种样式都打开同一个模型选择面板。"))
                }
            }
            .navigationTitle(L10n.lookup("模型入口样式"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct AppFontPreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var isImporterPresented = false
    @State private var showsFontActions = false
    @State private var showsGoogleFonts = false
    @State private var errorMessage = ""
    @State private var showsError = false

    private var fontTypes: [UTType] {
        let types = ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }

    var body: some View {
        Form {
            Section(L10n.lookup("当前字体")) {
                LabeledContent(L10n.lookup("应用字体"), value: model.preferences.appFontDisplayName ?? L10n.lookup("系统默认"))

                Text("Mocca")
                    .font(
                        AppFontStore.swiftUIFont(
                            postScriptName: model.preferences.appFontPostScriptName,
                            size: 18
                        )
                    )
                    .padding(.vertical, 6)
            }

            Section {
                Button {
                    showsFontActions = true
                } label: {
                    Label {
                        Text(L10n.lookup("选择或更换字体"))
                    } icon: {
                        AppSymbolImage(systemName: "textformat")
                    }
                }
            } footer: {
                Text(L10n.lookup("可以选择本地 TTF、OTF、TTC，或从 Google Fonts 获取。字体会立即应用并保存在本机；恢复默认藏在选择菜单内，避免误触。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("应用字体"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            L10n.lookup("选择字体来源"),
            isPresented: $showsFontActions,
            titleVisibility: .visible
        ) {
            Button(L10n.lookup("选择本地文件")) {
                isImporterPresented = true
            }
            Button(L10n.lookup("从 Google Fonts 获取")) {
                showsGoogleFonts = true
            }
            if model.preferences.appFontFileName != nil {
                Button(L10n.lookup("恢复系统默认字体"), role: .destructive) {
                    restoreSystemFont()
                }
            }
            Button(L10n.lookup("取消"), role: .cancel) {}
        }
        .navigationDestination(isPresented: $showsGoogleFonts) {
            GoogleFontsPickerPage()
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: fontTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let sourceURL = try result.get().first else { return }
                let oldFileName = model.preferences.appFontFileName
                let selection = try AppFontStore.importFont(from: sourceURL)
                model.updatePreferences { preferences in
                    preferences.appFontFileName = selection.fileName
                    preferences.appFontPostScriptName = selection.postScriptName
                    preferences.appFontDisplayName = selection.displayName
                }
                if oldFileName != selection.fileName {
                    AppFontStore.deleteStoredFont(fileName: oldFileName)
                }
            } catch {
                errorMessage = error.localizedDescription
                showsError = true
            }
        }
        .alert(L10n.lookup("字体导入失败"), isPresented: $showsError) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func restoreSystemFont() {
        let oldFileName = model.preferences.appFontFileName
        model.performListItemHaptic()
        model.updatePreferences { preferences in
            preferences.appFontFileName = nil
            preferences.appFontPostScriptName = nil
            preferences.appFontDisplayName = nil
        }
        AppFontStore.deleteStoredFont(fileName: oldFileName)
    }
}

private struct GoogleFontsPickerPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var installingFamily: String?
    @State private var errorMessage = ""
    @State private var showsError = false

    private var filteredFonts: [GoogleFontCatalogEntry] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return GoogleFontsCatalog.all }
        return GoogleFontsCatalog.all.filter {
            $0.family.localizedCaseInsensitiveContains(cleaned)
        }
    }

    var body: some View {
        List(filteredFonts) { entry in
            Button {
                install(entry)
            } label: {
                GoogleFontPreviewRow(
                    entry: entry,
                    isInstalling: installingFamily == entry.family,
                    isSelected: model.preferences.appFontDisplayName == entry.family
                )
            }
            .buttonStyle(.plain)
            .disabled(installingFamily != nil)
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: L10n.lookup("输入以过滤字体…"))
        .navigationTitle("Google Fonts")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if filteredFonts.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .alert(L10n.lookup("字体获取失败"), isPresented: $showsError) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func install(_ entry: GoogleFontCatalogEntry) {
        guard installingFamily == nil else { return }
        installingFamily = entry.family
        Task {
            do {
                let selection = try await AppFontStore.installGoogleFont(entry)
                let oldFileName = model.preferences.appFontFileName
                model.updatePreferences { preferences in
                    preferences.appFontFileName = selection.fileName
                    preferences.appFontPostScriptName = selection.postScriptName
                    preferences.appFontDisplayName = entry.family
                }
                if oldFileName != selection.fileName {
                    AppFontStore.deleteStoredFont(fileName: oldFileName)
                }
                installingFamily = nil
                dismiss()
            } catch is CancellationError {
                installingFamily = nil
            } catch {
                installingFamily = nil
                errorMessage = error.localizedDescription
                showsError = true
            }
        }
    }
}

private struct GoogleFontPreviewRow: View {
    let entry: GoogleFontCatalogEntry
    let isInstalling: Bool
    let isSelected: Bool
    @State private var previewPostScriptName: String?
    @State private var isLoadingPreview = false

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.family)
                .font(previewFont(size: 17))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else if isLoadingPreview {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text(L10n.lookup("Aa字"))
                    .font(previewFont(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 7)
        .task(id: entry.id) {
            guard entry.expectedLength <= 1_000_000 else { return }
            isLoadingPreview = true
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                try Task.checkCancellation()
                let selection = try await AppFontStore.previewGoogleFont(entry)
                try Task.checkCancellation()
                previewPostScriptName = selection.postScriptName
            } catch {
                // A preview failure never blocks selecting and downloading the font.
            }
            isLoadingPreview = false
        }
    }

    private func previewFont(size: CGFloat) -> Font {
        guard let previewPostScriptName else { return .system(size: size) }
        return .custom(previewPostScriptName, size: size)
    }
}

private struct ThemePreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var sidebarBackgroundSelection: PhotosPickerItem?
    @State private var sidebarBackgroundSelectionTask: Task<Void, Never>?
    @State private var sidebarBackgroundSelectionSequence: UInt64 = 0
    @State private var sidebarBackgroundVisibilitySequence: UInt64 = 0
    @State private var pendingSidebarBackgroundCrop: BackgroundCropRequest?
    @State private var pendingSidebarCropVisibilitySequence: UInt64 = 0
    @State private var showSidebarBackgroundImportError = false

    private var themeAccent: Color {
        Color(uiColor: model.themeAccentUIColor)
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(argb: model.preferences.customThemeColorARGB) ?? .pink },
            set: { color in
                model.updatePreferences {
                    $0.customThemeColorARGB = color.argbValue
                    $0.themePaletteID = .custom
                }
            }
        )
    }

    var body: some View {
        let actionColor = Color(uiColor: model.themeActionUIColor)
        let sidebarBackgroundReference = model.preferences.sidebarBackground
        let sidebarBackgroundImage = AssistantMediaStore.image(
            for: sidebarBackgroundReference
        )
        let hasSidebarBackgroundReference = sidebarBackgroundReference != nil
        let hasSidebarBackground = sidebarBackgroundImage != nil
        let sidebarBackgroundOpacity = UserPreferences.clamp(
            model.preferences.sidebarBackgroundOpacity,
            min: 0.0,
            max: 1.0
        )
        let chatBackgroundMaskFraction = UserPreferences.clamp(
            model.preferences.chatBackgroundMaskStrength / 2,
            min: 0.0,
            max: 1.0
        )
        let sidebarBackgroundMaskStrength = 1 - sidebarBackgroundOpacity
        let sidebarMaskTopOpacity = 0.40 * sidebarBackgroundMaskStrength
        let sidebarMaskBottomOpacity = sidebarBackgroundMaskStrength
        let sidebarSurface = Color(uiColor: model.themeSurfaceUIColor)

        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.preferences.usePureBackground },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences { $0.usePureBackground = value }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        SettingsRowLabel(title: L10n.lookup("使用纯色背景"), systemImage: "square.fill")
                        Text(L10n.lookup("浅色模式使用纯白，深色模式使用纯黑。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.lookup("聊天背景遮罩强度"))
                        Spacer()
                        Text("\(Int((chatBackgroundMaskFraction * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: {
                                UserPreferences.clamp(
                                    model.preferences.chatBackgroundMaskStrength / 2,
                                    min: 0.0,
                                    max: 1.0
                                )
                            },
                            set: { value in
                                let maskFraction = UserPreferences.clamp(
                                    value,
                                    min: 0.0,
                                    max: 1.0
                                )
                                model.updatePreferences {
                                    $0.chatBackgroundMaskStrength = maskFraction * 2
                                }
                            }
                        ),
                        in: 0...1,
                        step: 0.05
                    )
                    .tint(Color(uiColor: model.themeSliderUIColor))
                }

                if hasSidebarBackground {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.lookup("侧栏背景遮罩强度"))
                            Spacer()
                            Text("\(Int((sidebarBackgroundMaskStrength * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: {
                                    1 - UserPreferences.clamp(
                                        model.preferences.sidebarBackgroundOpacity,
                                        min: 0.0,
                                        max: 1.0
                                    )
                                },
                                set: { value in
                                    let maskStrength = UserPreferences.clamp(
                                        value,
                                        min: 0.0,
                                        max: 1.0
                                    )
                                    model.updatePreferences {
                                        $0.sidebarBackgroundOpacity = 1 - maskStrength
                                    }
                                }
                            ),
                            in: 0...1,
                            step: 0.05
                        )
                        .tint(Color(uiColor: model.themeSliderUIColor))
                    }
                }
            } header: {
                Text(L10n.lookup("背景遮罩"))
            } footer: {
                if hasSidebarBackground {
                    Text(L10n.lookup("两项都使用 0–100% 刻度并分别保存；向右增强遮罩、让图片更淡。"))
                } else {
                    Text(L10n.lookup("聊天遮罩使用 0–100% 刻度；选择侧栏背景后可单独调节侧栏遮罩。"))
                }
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: {
                            model.preferences.sidebarBackgroundEnabled
                                && hasSidebarBackground
                        },
                        set: { value in
                            sidebarBackgroundVisibilitySequence &+= 1
                            model.performSwitchHaptic()
                            model.updatePreferences {
                                $0.sidebarBackgroundEnabled = value
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        SettingsRowLabel(
                            title: L10n.lookup("显示侧栏背景"),
                            systemImage: "sidebar.left"
                        )
                        Text(L10n.lookup("只控制侧栏，不影响聊天背景。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!hasSidebarBackground)

                if let sidebarBackgroundImage {
                    ZStack {
                        sidebarSurface
                        Image(uiImage: sidebarBackgroundImage)
                            .resizable()
                            .scaledToFill()
                            .overlay(Color.black.opacity(0.04))
                        LinearGradient(
                            colors: [
                                sidebarSurface.opacity(sidebarMaskTopOpacity),
                                sidebarSurface.opacity(sidebarMaskBottomOpacity)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 16,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 16,
                            style: .continuous
                        )
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                    }
                }

                let sidebarBackgroundPickerTitle = hasSidebarBackground
                    ? L10n.lookup("更换侧栏背景")
                    : L10n.lookup("选择侧栏背景")
                PhotosPicker(
                    selection: $sidebarBackgroundSelection,
                    matching: .images
                ) {
                    SettingsRowLabel(
                        title: sidebarBackgroundPickerTitle,
                        systemImage: "photo.on.rectangle",
                        color: actionColor
                    )
                }

                if sidebarBackgroundSelectionTask != nil {
                    ProgressView(L10n.lookup("正在读取图片…"))
                }

                if hasSidebarBackgroundReference {
                    Button(role: .destructive) {
                        clearSidebarBackground()
                    } label: {
                        SettingsRowLabel(
                            title: L10n.lookup("清除侧栏背景"),
                            systemImage: "trash"
                        )
                    }
                }
            } header: {
                Text(L10n.lookup("侧栏背景"))
            } footer: {
                if hasSidebarBackgroundReference && !hasSidebarBackground {
                    Text(L10n.lookup("当前图片文件不可用，可以清除后重新选择。"))
                } else {
                    Text(L10n.lookup("选择图片后会自动打开；关闭开关会保留图片，重新打开即可继续使用。"))
                }
            }

            Section(L10n.lookup("颜色主题")) {
                HStack(spacing: 10) {
                    Button {
                        model.performListItemHaptic()
                        model.updatePreferences { $0.themePaletteID = .custom }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "eyedropper")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(themeAccent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.lookup("自定义"))
                                    .foregroundStyle(.primary)
                                Text(hex(model.preferences.customThemeColorARGB))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.preferences.themePaletteID == .custom {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(themeAccent)
                            }
                        }
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    ColorPicker(L10n.lookup("自定义颜色"), selection: customColorBinding, supportsOpacity: false)
                        .labelsHidden()
                        .accessibilityLabel(L10n.lookup("调整自定义颜色"))
                }

                ForEach(ThemePaletteID.allCases.filter { $0 != .custom }) { palette in
                    Button {
                        model.performListItemHaptic()
                        model.updatePreferences { $0.themePaletteID = palette }
                    } label: {
                        HStack(spacing: 14) {
                            ThemePaletteSwatch(palette: palette)
                            Text(L10n.lookup(palette.title))
                                .foregroundStyle(.primary)
                            Spacer()
                            if model.preferences.themePaletteID == palette {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(themeAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("主题设置"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingSidebarBackgroundCrop) { request in
            BackgroundImageCropEditor(image: request.image, destination: .sidebar) { image in
                await saveCroppedSidebarBackground(image, requestID: request.id)
            }
        }
        .alert(L10n.lookup("无法读取图片"), isPresented: $showSidebarBackgroundImportError) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("请选择其他图片或重试，原背景保持不变。"))
        }
        .onChange(of: sidebarBackgroundSelection) { _, item in
            guard let item else { return }
            sidebarBackgroundSelection = nil
            cancelPendingSidebarBackgroundSelection()
            let sequence = sidebarBackgroundSelectionSequence
            sidebarBackgroundVisibilitySequence &+= 1
            let visibilitySequence = sidebarBackgroundVisibilitySequence
            sidebarBackgroundSelectionTask = Task { @MainActor in
                defer {
                    if sequence == sidebarBackgroundSelectionSequence { sidebarBackgroundSelectionTask = nil }
                }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = await BackgroundCropImageIO.prepare(data) else {
                    if !Task.isCancelled, sequence == sidebarBackgroundSelectionSequence {
                        showSidebarBackgroundImportError = true
                    }
                    return
                }
                guard !Task.isCancelled, sequence == sidebarBackgroundSelectionSequence else { return }
                pendingSidebarCropVisibilitySequence = visibilitySequence
                pendingSidebarBackgroundCrop = BackgroundCropRequest(image: image)
            }
        }
        .onDisappear {
            cancelPendingSidebarBackgroundSelection()
        }
    }

    private func saveCroppedSidebarBackground(_ image: UIImage, requestID: UUID) async -> Bool {
        guard pendingSidebarBackgroundCrop?.id == requestID else { return false }
        let visibilitySequence = pendingSidebarCropVisibilitySequence
        guard let reference = await BackgroundCropImageIO.save(image, destination: .sidebar) else { return false }
        guard pendingSidebarBackgroundCrop?.id == requestID else {
            AssistantMediaStore.remove(reference)
            return false
        }
        let previousReference = model.preferences.sidebarBackground
        var updatedPreferences = model.preferences
        updatedPreferences.sidebarBackground = reference
        if visibilitySequence == sidebarBackgroundVisibilitySequence {
            updatedPreferences.sidebarBackgroundEnabled = true
        }
        guard AppPreferences.savePreferences(updatedPreferences) else {
            AssistantMediaStore.remove(reference)
            return false
        }
        model.preferences = updatedPreferences
        if previousReference != reference { AssistantMediaStore.remove(previousReference) }
        return true
    }

    private func clearSidebarBackground() {
        cancelPendingSidebarBackgroundSelection()
        sidebarBackgroundVisibilitySequence &+= 1
        let previousReference = model.preferences.sidebarBackground
        var updatedPreferences = model.preferences
        updatedPreferences.sidebarBackgroundEnabled = false
        updatedPreferences.sidebarBackground = nil
        guard AppPreferences.savePreferences(updatedPreferences) else { return }
        model.preferences = updatedPreferences
        AssistantMediaStore.remove(previousReference)
    }

    private func cancelPendingSidebarBackgroundSelection() {
        sidebarBackgroundSelectionSequence &+= 1
        sidebarBackgroundSelectionTask?.cancel()
        sidebarBackgroundSelectionTask = nil
        pendingSidebarBackgroundCrop = nil
    }

    private func hex(_ argb: Int) -> String {
        String(format: "#%06X", argb & 0x00ff_ffff)
    }
}

private struct ChatItemDisplayPreferencesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.preferences.showChatHeaderAssistantPill },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences {
                                $0.showChatHeaderAssistantPill = value
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        SettingsRowLabel(
                            title: L10n.lookup("显示顶部助手按钮"),
                            systemImage: "person.crop.circle"
                        )
                        Text(L10n.lookup("关闭后，聊天顶部不再显示助手头像与名称。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.lookup("顶部栏"))
            } footer: {
                Text(L10n.lookup("日历仍可从助手编辑页顶部的“日历”入口打开；选择助手不受影响。"))
            }

            Section(L10n.lookup("用户消息")) {
                PreferenceToggle(title: L10n.lookup("显示用户头像"), systemImage: "person.crop.circle", keyPath: \.showUserAvatar)
                PreferenceToggle(title: L10n.lookup("显示用户名称"), systemImage: "person.text.rectangle", keyPath: \.showUserName)
                PreferenceToggle(title: L10n.lookup("显示用户时间"), systemImage: "clock", keyPath: \.showUserTimestamp)
                LabeledContent {
                    Text(L10n.lookup("长按气泡"))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsRowLabel(title: L10n.lookup("用户消息操作"), systemImage: "hand.tap")
                }
            }

            Section(L10n.lookup("助手消息")) {
                NavigationLink {
                    AssistantMessageActionsPreferencesPage()
                } label: {
                    SettingsRowLabel(title: L10n.lookup("消息操作按钮"), systemImage: "slider.horizontal.3")
                }
                Toggle(
                    isOn: Binding(
                        get: { model.preferences.assistantBlankLongPressReactionEnabled },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences {
                                $0.assistantBlankLongPressReactionEnabled = value
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        SettingsRowLabel(title: L10n.lookup("空白处长按回应"), systemImage: "hand.tap")
                        Text(L10n.lookup("长按助手消息的空白区域打开表情回应；关闭后仍可使用消息下方的回应按钮。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                PreferenceToggle(title: L10n.lookup("AI 消息反应"), systemImage: "heart", keyPath: \.aiMessageReactionsEnabled)
                PreferenceToggle(title: L10n.lookup("显示模型图标"), systemImage: "sparkles", keyPath: \.showModelIcon)
                PreferenceToggle(title: L10n.lookup("显示模型名称"), systemImage: "message", keyPath: \.showModelName)
                PreferenceToggle(title: L10n.lookup("显示模型时间"), systemImage: "clock", keyPath: \.showModelTimestamp)
                PreferenceToggle(title: L10n.lookup("在消息中显示供应商"), systemImage: "globe", keyPath: \.showProviderInChatMessage)
                PreferenceToggle(title: L10n.lookup("显示 Token 用量"), systemImage: "number", keyPath: \.showTokenUsage)
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("消息显示"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AssistantMessageActionsPreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Form {
            Section {
                ForEach(model.preferences.assistantMessageActionOrder) { action in
                    Toggle(isOn: visibilityBinding(for: action)) {
                        SettingsRowLabel(title: L10n.lookup(action.title), systemImage: action.systemImage)
                    }
                }
                .onMove(perform: moveActions)
            } header: {
                Text(L10n.lookup("回答下方按钮"))
            } footer: {
                Text(L10n.lookup("保持 4479 的默认排列；关闭的动作不会显示在助手回答下方。“更多”按钮也可以像其他按钮一样移动或隐藏。"))
            }

            Section {
                ForEach(model.preferences.assistantMessageMoreActionItems) { item in
                    Toggle(isOn: moreVisibilityBinding(for: item)) {
                        SettingsRowLabel(title: L10n.lookup(item.title), systemImage: item.systemImage)
                    }
                }
                .onMove(perform: moveMoreActions)
            } header: {
                Text(L10n.lookup("“更多”菜单"))
            } footer: {
                Text(L10n.lookup("这里单独控制点开助手回答“更多”后出现的项目及顺序。“完全删除”只会在同一回答存在多个版本时出现。用户消息操作请长按用户气泡的空白处打开；回复版本选择器只会在产生多个回复时自动出现，不属于可配置操作。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("助手消息操作"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.lookup("按钮与顺序"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(editMode == .active ? L10n.lookup("拖动右侧把手调整排列") : L10n.lookup("选择显示项目；需要排序时点编辑"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button(editMode == .active ? L10n.lookup("完成") : L10n.lookup("编辑")) {
                        model.performListItemHaptic()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            editMode = editMode == .active ? .inactive : .active
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityHint(editMode == .active ? L10n.lookup("结束按钮排序") : L10n.lookup("显示拖动排序把手"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider()
                    .opacity(0.55)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .environment(\.editMode, $editMode)
    }

    private func visibilityBinding(for action: AssistantMessageInlineAction) -> Binding<Bool> {
        Binding(
            get: {
                !model.preferences.hiddenAssistantMessageActions.contains(action)
            },
            set: { isVisible in
                model.performSwitchHaptic()
                model.updatePreferences { preferences in
                    if isVisible {
                        preferences.hiddenAssistantMessageActions.remove(action)
                    } else {
                        preferences.hiddenAssistantMessageActions.insert(action)
                    }
                }
            }
        )
    }

    private func moveActions(from offsets: IndexSet, to destination: Int) {
        model.performListItemHaptic()
        model.updatePreferences { preferences in
            preferences.assistantMessageActionOrder.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    private func moreVisibilityBinding(
        for item: AssistantMessageMoreActionItem
    ) -> Binding<Bool> {
        Binding(
            get: {
                switch item {
                case .standard(let action):
                    !model.preferences.hiddenAssistantMessageMoreActions.contains(action)
                case .deleteAllVersions:
                    model.preferences.showDeleteAllMessageVersionsAction
                }
            },
            set: { isVisible in
                model.performSwitchHaptic()
                model.updatePreferences { preferences in
                    switch item {
                    case .standard(let action):
                        if isVisible {
                            preferences.hiddenAssistantMessageMoreActions.remove(action)
                        } else {
                            preferences.hiddenAssistantMessageMoreActions.insert(action)
                        }
                    case .deleteAllVersions:
                        preferences.showDeleteAllMessageVersionsAction = isVisible
                    }
                }
            }
        )
    }

    private func moveMoreActions(from offsets: IndexSet, to destination: Int) {
        model.performListItemHaptic()
        var items = model.preferences.assistantMessageMoreActionItems
        items.move(fromOffsets: offsets, toOffset: destination)
        model.updatePreferences { preferences in
            preferences.assistantMessageMoreActionOrder = items.compactMap { item in
                guard case .standard(let action) = item else { return nil }
                return action
            }
            preferences.deleteAllMessageVersionsActionIndex =
                items.firstIndex(of: .deleteAllVersions)
                    ?? preferences.assistantMessageMoreActionOrder.count
        }
    }
}

private struct RenderingPreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var activeSpacingSheet: PreferencesSheetRoute?

    var body: some View {
        Form {
            Section(L10n.lookup("阅读排版")) {
                PreferenceDetailButton(
                    title: L10n.lookup("助手消息行间距"),
                    systemImage: "arrow.up.and.down.text.horizontal",
                    detail: String(format: "%.1f pt", model.preferences.assistantMessageLineSpacing)
                ) {
                    activeSpacingSheet = .assistantLineSpacing
                }

                PreferenceDetailButton(
                    title: L10n.lookup("Markdown 列表间距"),
                    systemImage: "list.bullet",
                    detail: String(format: "%.1f pt", model.preferences.assistantMarkdownListItemSpacing)
                ) {
                    activeSpacingSheet = .assistantMarkdownListItemSpacing
                }

                PreferenceDetailButton(
                    title: L10n.lookup("Markdown 块间距"),
                    systemImage: "text.alignleft",
                    detail: "\(Int((model.preferences.assistantMarkdownBlockSpacingScale * 100).rounded()))%"
                ) {
                    activeSpacingSheet = .assistantMarkdownBlockSpacing
                }
            }

            Section("Markdown") {
                PreferenceToggle(title: L10n.lookup("用户消息 Markdown"), systemImage: "text.alignleft", keyPath: \.enableUserMarkdown)
                PreferenceToggle(title: L10n.lookup("思考内容 Markdown"), systemImage: "brain.head.profile", keyPath: \.enableReasoningMarkdown)
                PreferenceToggle(title: L10n.lookup("助手消息 Markdown"), systemImage: "message", keyPath: \.enableAssistantMarkdown)
            }

            Section {
                Picker(
                    selection: Binding(
                        get: { model.preferences.codeBlockAppearance },
                        set: { appearance in
                            model.updatePreferences {
                                $0.codeBlockAppearance = appearance
                            }
                        }
                    )
                ) {
                    ForEach(CodeBlockAppearance.allCases) { appearance in
                        Text(L10n.lookup(appearance.title)).tag(appearance)
                    }
                } label: {
                    SettingsRowLabel(title: L10n.lookup("代码框颜色"), systemImage: "circle.lefthalf.filled")
                }

                PreferenceToggle(title: L10n.lookup("运行 HTML 小网页"), systemImage: "play.rectangle", keyPath: \.htmlRunnerEnabled)
                if model.preferences.htmlRunnerEnabled {
                    PreferenceToggle(title: L10n.lookup("允许读取当前聊天"), systemImage: "message", keyPath: \.htmlRunnerAllowCurrentChat)
                }
                PreferenceToggle(title: L10n.lookup("自动折叠代码块"), systemImage: "chevron.up.chevron.down", keyPath: \.autoCollapseCodeBlock)
                if model.preferences.autoCollapseCodeBlock {
                    Stepper(
                        value: Binding(
                            get: { model.preferences.autoCollapseCodeBlockLines },
                            set: { value in
                                model.updatePreferences {
                                    $0.autoCollapseCodeBlockLines = min(max(value, 1), 999)
                                }
                            }
                        ),
                        in: 1...999
                    ) {
                        HStack {
                            SettingsRowLabel(title: L10n.lookup("折叠后显示行数"), systemImage: "list.number")
                            Spacer()
                            Text(L10n.format("%@ 行", [String(describing: model.preferences.autoCollapseCodeBlockLines)]))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    RenderingPreferencesGuideView()
                } label: {
                    SettingsRowLabel(
                        title: L10n.lookup("渲染与网页权限说明"),
                        systemImage: "info.circle"
                    )
                }
            } header: {
                Text(L10n.lookup("代码块"))
            } footer: {
                Text(L10n.lookup("代码框颜色只改变代码区域的显示；网页读取聊天仍会逐次请求授权。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("排版与渲染"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSpacingSheet) { sheet in
            switch sheet {
            case .assistantLineSpacing:
                PreferenceSliderSheet(
                    title: L10n.lookup("助手消息行间距"),
                    subtitle: L10n.lookup("调整同一段文字换行后的松紧。数值越大，段落越舒展。"),
                    range: 2.0...10.0,
                    step: 0.5,
                    value: Binding(
                        get: { model.preferences.assistantMessageLineSpacing },
                        set: { value in
                            model.updatePreferences {
                                $0.assistantMessageLineSpacing = UserPreferences.clamp(value, min: 2.0, max: 10.0)
                            }
                        }
                    ),
                    valueText: { String(format: "%.1f pt", $0) },
                    leadingText: L10n.lookup("紧凑 2.0"),
                    trailingText: L10n.lookup("宽松 10.0")
                )
            case .assistantMarkdownListItemSpacing:
                PreferenceSliderSheet(
                    title: L10n.lookup("Markdown 列表项间距"),
                    subtitle: L10n.lookup("只调整相邻圆点或编号条目之间的额外留白；不会改变条目内部的换行行距，也不会改变列表与其他段落的距离。"),
                    range: 0.0...12.0,
                    step: 0.5,
                    value: Binding(
                        get: { model.preferences.assistantMarkdownListItemSpacing },
                        set: { value in
                            model.updatePreferences {
                                $0.assistantMarkdownListItemSpacing = UserPreferences.clamp(value, min: 0.0, max: 12.0)
                            }
                        }
                    ),
                    valueText: { String(format: "%.1f pt", $0) },
                    leadingText: L10n.lookup("紧凑 0.0"),
                    trailingText: L10n.lookup("宽松 12.0")
                )
            case .assistantMarkdownBlockSpacing:
                PreferenceSliderSheet(
                    title: L10n.lookup("Markdown 块间距"),
                    subtitle: L10n.lookup("统一调整段落、标题、列表、引用和分隔线之间的留白；不会改变同一段里的行距。"),
                    range: 0.5...1.5,
                    step: 0.05,
                    value: Binding(
                        get: { model.preferences.assistantMarkdownBlockSpacingScale },
                        set: { value in
                            model.updatePreferences {
                                $0.assistantMarkdownBlockSpacingScale = UserPreferences.clamp(value, min: 0.5, max: 1.5)
                            }
                        }
                    ),
                    valueText: { "\(Int(($0 * 100).rounded()))%" },
                    leadingText: L10n.lookup("紧凑 50%"),
                    trailingText: L10n.lookup("宽松 150%")
                )
            default:
                EmptyView()
            }
        }
    }
}

private struct RenderingPreferencesGuideView: View {
    var body: some View {
        Form {
            Section("Markdown") {
                Text(L10n.lookup("关闭某一类 Markdown 后，只会把对应消息按纯文本显示，不会修改已经保存的消息内容。"))
            }

            Section(L10n.lookup("HTML 小网页")) {
                Text(L10n.lookup("允许读取当前聊天后，网页调用 mocca.getCurrentChat() 时仍会逐页请求“仅本次允许”。"))
                Text(L10n.lookup("获得聊天读取权限的预览会切断外部网络，避免聊天内容同时发送到外部站点。"))
            }

            Section(L10n.lookup("代码块折叠")) {
                Text(L10n.lookup("自动折叠只影响已经闭合的长代码块；未闭合或较短的代码块继续完整显示。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("渲染与网页权限"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BehaviorStartupPreferencesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                PreferenceToggle(title: L10n.lookup("默认完全折叠思考链"), systemImage: "brain.head.profile", keyPath: \.fullyCollapseThinking)
                PreferenceToggle(title: L10n.lookup("自动折叠思考过程"), systemImage: "chevron.down", keyPath: \.autoCollapseThinking)
                    .disabled(model.preferences.fullyCollapseThinking)
                PreferenceToggle(title: L10n.lookup("重新生成时删除后续消息"), systemImage: "trash", keyPath: \.regenerateDeleteTrailingMessages)
                PreferenceToggle(title: L10n.lookup("显示重新生成确认弹窗"), systemImage: "exclamationmark.bubble", keyPath: \.showRegenerateConfirmDialog)
            } header: {
                Text(L10n.lookup("思考与重新生成"))
            } footer: {
                Text(L10n.lookup("打开后，每段思考从生成开始默认折叠，只显示标题与耗时；仍可点击标题随时展开或收起，生成中手动展开后不会在结束时突然折回。关闭后可使用“自动折叠思考过程”控制完成后的折叠。"))
            }

            Section {
                Picker(selection: Binding(
                    get: { model.preferences.mobileMessageNavButtonsMode },
                    set: { value in
                        model.performListItemHaptic()
                        model.updatePreferences { $0.mobileMessageNavButtonsMode = value }
                    }
                )) {
                    ForEach(MobileMessageNavButtonsMode.allCases) { mode in
                        Text(L10n.lookup(mode.title)).tag(mode)
                    }
                } label: {
                    SettingsRowLabel(title: L10n.lookup("消息导航按钮"), systemImage: "chevron.up.chevron.down")
                }

                PreferenceToggle(title: L10n.lookup("会话列表显示日期"), systemImage: "calendar", keyPath: \.showChatListDate)
                PreferenceToggle(title: L10n.lookup("点击助手后保持侧栏打开"), systemImage: "sidebar.left", keyPath: \.keepSidebarOpenOnAssistantTap)
                PreferenceToggle(title: L10n.lookup("点击话题后保持侧栏打开"), systemImage: "list.bullet.rectangle", keyPath: \.keepSidebarOpenOnTopicTap)
            } header: {
                Text(L10n.lookup("导航与侧栏"))
            } footer: {
                Text(L10n.lookup("“始终显示”和“滚动时显示”使用包含到顶部、上一条用户消息、下一条用户消息和到底部的完整导航面板；“简单”只在离开最新底部后显示一个回到底部箭头，真正到底后自动消失。"))
            }

            Section {
                PreferenceToggle(title: L10n.lookup("启动时新建聊天"), systemImage: "plus.bubble", keyPath: \.newChatOnLaunch)
                PreferenceToggle(title: L10n.lookup("切换助手时新建聊天"), systemImage: "shuffle", keyPath: \.newChatOnAssistantSwitch)
                PreferenceToggle(title: L10n.lookup("删除聊天后新建聊天"), systemImage: "trash.circle", keyPath: \.newChatAfterDelete)
                PreferenceToggle(title: L10n.lookup("移动端回车发送"), systemImage: "return", keyPath: \.enterToSendOnMobile)
                PreferenceToggle(title: L10n.lookup("自动生成标题"), systemImage: "text.badge.star", keyPath: \.autoGenerateTitle)
            } header: {
                Text(L10n.lookup("聊天行为"))
            } footer: {
                Text(L10n.lookup("启动新建聊天会复用已有空白会话；重新生成默认保留后续消息。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("行为与启动"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HapticsPreferencesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                PreferenceToggle(title: L10n.lookup("全局震动"), systemImage: "iphone.radiowaves.left.and.right", keyPath: \.hapticsGlobalEnabled)
                Group {
                    PreferenceToggle(title: L10n.lookup("开关震动"), systemImage: "switch.2", keyPath: \.hapticsIosSwitch)
                    PreferenceToggle(title: L10n.lookup("侧栏开关震动"), systemImage: "sidebar.left", keyPath: \.hapticsOnDrawer)
                    PreferenceToggle(title: L10n.lookup("列表项点击震动"), systemImage: "list.bullet", keyPath: \.hapticsOnListItemTap)
                    PreferenceToggle(title: L10n.lookup("卡片点击震动"), systemImage: "rectangle.stack", keyPath: \.hapticsOnCardTap)
                    PreferenceToggle(title: L10n.lookup("生成时震动"), systemImage: "sparkles", keyPath: \.hapticsOnGenerate)
                }
                .disabled(!model.preferences.hapticsGlobalEnabled)
            } footer: {
                Text(L10n.lookup("关闭全局震动后，下方选项暂不可调整，原有设置会保留；重新开启后继续生效。"))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("震动反馈"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ChatBubbleTarget: String, CaseIterable, Identifiable {
    case user
    case assistant
    case thinking

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .user: L10n.lookup("用户气泡")
        case .assistant: L10n.lookup("助手气泡")
        case .thinking: L10n.lookup("思考气泡")
        }
    }

    var icon: String {
        switch self {
        case .user: "person"
        case .assistant: "sparkles"
        case .thinking: "brain.head.profile"
        }
    }
}

private enum ChatBubbleColorKind: String, Identifiable {
    case bubble
    case text
    case largeHeading
    case smallHeading

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .bubble: L10n.lookup("气泡颜色")
        case .text: L10n.lookup("文字颜色")
        case .largeHeading: L10n.lookup("大标题颜色")
        case .smallHeading: L10n.lookup("小标题颜色")
        }
    }

    var systemImage: String {
        switch self {
        case .bubble: "paintpalette"
        case .text: "textformat"
        case .largeHeading, .smallHeading: "textformat.size"
        }
    }
}

private struct ChatBubbleColorSelection: Identifiable {
    let target: ChatBubbleTarget
    let kind: ChatBubbleColorKind

    var id: String { "\(target.rawValue)-\(kind.rawValue)" }
}

private struct ThemePaletteSwatch: View {
    let palette: ThemePaletteID

    var body: some View {
        Circle()
            .fill(swatchStyle)
            .frame(width: 25, height: 25)
            .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.6))
    }

    private var swatchStyle: AnyShapeStyle {
        if palette == .defaultPalette {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(argb: 0xfff7f8fa) ?? .white,
                        Color(argb: 0xffe1e4e9) ?? .secondary,
                        Color(argb: palette.lightAccentARGB) ?? .secondary
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(Color(argb: palette.lightAccentARGB) ?? .accentColor)
    }
}

private struct ChatSegmentationPreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var bubbleSpacing = UserPreferences.defaultChatBubbleSpacing
    @State private var isAdjustingBubbleSpacing = false
    @State private var batchSendDelay = Double(UserPreferences.defaultBatchUserMessageDelaySeconds)
    @State private var isAdjustingBatchSendDelay = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.preferences.chatSegmentedReply },
                    set: { value in
                        model.performSwitchHaptic()
                        model.updatePreferences { $0.chatSegmentedReply = value }
                    }
                )) {
                    Text(L10n.lookup("聊天分段"))
                }
                .accessibilityIdentifier("replySegmentationEnabled")

                if model.preferences.chatSegmentedReply {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.lookup("最多分段数"))
                            Spacer()
                            Text(model.preferences.replySegmentLimit == 0
                                 ? L10n.lookup("不限") : "\(model.preferences.replySegmentLimit)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { model.preferences.replySegmentLimit == 0
                                ? 21 : Double(min(model.preferences.replySegmentLimit, 20)) },
                            set: { value in
                                let step = Int(value.rounded())
                                model.updatePreferences { $0.replySegmentLimit = step == 21 ? 0 : step }
                            }
                        ), in: 1...21, step: 1)
                        .tint(Color(uiColor: model.themeSliderUIColor))
                        .accessibilityLabel(L10n.lookup("最多分段数"))
                        .accessibilityValue(model.preferences.replySegmentLimit == 0
                                            ? L10n.lookup("不限") : "\(model.preferences.replySegmentLimit)")
                        .accessibilityIdentifier("replySegmentationLimit")
                        HStack {
                            Text("1")
                            Spacer()
                            Text(L10n.lookup("不限"))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(L10n.lookup("达到段数上限后，后续内容并入最后一段。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.lookup("按自然段逐步展示助手回复，支持普通聊天和群聊。无气泡时显示为文字块，已保存的分段不受设置变更影响。"))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.preferences.customChatBubbleSpacingEnabled },
                    set: { value in
                        model.performSwitchHaptic()
                        model.updatePreferences { $0.customChatBubbleSpacingEnabled = value }
                    }
                )) {
                    Text(L10n.lookup("自定义气泡间距"))
                }
                .accessibilityIdentifier("customChatBubbleSpacingEnabled")

                if model.preferences.customChatBubbleSpacingEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.lookup("气泡间距"))
                            Spacer()
                            Text(L10n.format("%@ 点", [String(Int(bubbleSpacing))]))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { bubbleSpacing },
                            set: { value in
                                bubbleSpacing = value.rounded()
                                // Accessibility adjustments need not begin a drag.
                                if !isAdjustingBubbleSpacing { saveBubbleSpacing() }
                            }
                        ), in: 0...32, step: 1, onEditingChanged: { editing in
                            isAdjustingBubbleSpacing = editing
                            if !editing { saveBubbleSpacing() }
                        })
                        .tint(Color(uiColor: model.themeSliderUIColor))
                        .accessibilityLabel(L10n.lookup("气泡间距"))
                        .accessibilityValue(L10n.format("%@ 点", [String(Int(bubbleSpacing))]))
                        .accessibilityIdentifier("chatBubbleSpacing")
                        HStack {
                            Text(L10n.lookup("紧凑"))
                            Spacer()
                            Button(L10n.lookup("恢复默认间距")) {
                                bubbleSpacing = UserPreferences.defaultChatBubbleSpacing
                                saveBubbleSpacing()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color(uiColor: model.themeSliderUIColor))
                            .accessibilityIdentifier("chatBubbleSpacing.reset")
                            Spacer()
                            Text(L10n.lookup("宽松"))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.lookup("开启后，可调整消息与分段内容之间的垂直间距。关闭后使用默认间距，并保留自定义数值。"))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.preferences.batchUserMessages },
                    set: { value in
                        model.performSwitchHaptic()
                        model.updatePreferences { $0.batchUserMessages = value }
                    }
                )) {
                    Text(L10n.lookup("连续发送"))
                }
                .accessibilityIdentifier("batchUserMessagesEnabled")

                if model.preferences.batchUserMessages {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.lookup("等待时间"))
                            Spacer()
                            Text(L10n.format("%@ 秒", [String(Int(batchSendDelay))]))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { batchSendDelay },
                            set: { value in
                                batchSendDelay = value.rounded()
                                if !isAdjustingBatchSendDelay { saveBatchSendDelay() }
                            }
                        ), in: 3...15, step: 1, onEditingChanged: { editing in
                            isAdjustingBatchSendDelay = editing
                            if !editing { saveBatchSendDelay() }
                        })
                        .tint(Color(uiColor: model.themeSliderUIColor))
                        .accessibilityLabel(L10n.lookup("等待时间"))
                        .accessibilityValue(L10n.format("%@ 秒", [String(Int(batchSendDelay))]))
                        .accessibilityIdentifier("batchUserMessageDelay")
                        HStack {
                            Text(L10n.format("%@ 秒", ["3"]))
                            Spacer()
                            Text(L10n.format("%@ 秒", ["15"]))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L10n.format("普通聊天中，连续消息在最后一次发送 %@ 秒后统一提交。回复期间新增的消息归入下一批；切换聊天、进入后台或停止生成时暂停提交，并保留待发送消息。", [String(Int(batchSendDelay))]))
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("聊天分段"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            bubbleSpacing = model.preferences.chatBubbleSpacing
            batchSendDelay = Double(model.preferences.batchUserMessageDelaySeconds)
        }
        .onDisappear {
            saveBubbleSpacing()
            saveBatchSendDelay()
        }
    }

    private func saveBubbleSpacing() {
        guard model.preferences.chatBubbleSpacing != bubbleSpacing else { return }
        // Updating the shared preference invalidates transcript layout. Keep
        // thumb tracking local and publish the finished adjustment once.
        model.updatePreferences { $0.chatBubbleSpacing = bubbleSpacing }
    }

    private func saveBatchSendDelay() {
        let seconds = min(15, max(3, Int(batchSendDelay)))
        guard model.preferences.batchUserMessageDelaySeconds != seconds else { return }
        model.updatePreferences { $0.batchUserMessageDelaySeconds = seconds }
    }

}

private struct ChatBubblePreferencesPage: View {
    @Environment(AppModel.self) private var model
    @State private var activeColorEditor: ChatBubbleColorSelection?

    private var usesCrystalGlass: Bool {
        model.preferences.userChatBubbleStyle == .liquidGlass
            || model.preferences.assistantChatBubbleStyle == .liquidGlass
            || model.preferences.thinkingChatBubbleStyle == .liquidGlass
    }

    private var usesSystemLiquidGlass: Bool {
        model.preferences.userChatBubbleStyle == .appleGlass
            || model.preferences.assistantChatBubbleStyle == .appleGlass
            || model.preferences.thinkingChatBubbleStyle == .appleGlass
    }

    var body: some View {
        Form {
            ForEach(ChatBubbleTarget.allCases) { target in
                ChatBubbleRoleSection(target: target) { target, kind in
                    activeColorEditor = ChatBubbleColorSelection(
                        target: target,
                        kind: kind
                    )
                }
            }

            if usesCrystalGlass || usesSystemLiquidGlass {
                Section {
                    if usesCrystalGlass {
                        opacitySlider(
                            title: L10n.lookup("水晶玻璃清透度"),
                            value: Binding(
                                get: { model.preferences.liquidGlassBubbleOpacity },
                                set: { value in model.updatePreferences { $0.liquidGlassBubbleOpacity = UserPreferences.clamp(value, min: 0, max: 1) } }
                            )
                        )
                    }
                    if usesSystemLiquidGlass {
                        opacitySlider(
                            title: L10n.lookup("Liquid Glass 染色"),
                            value: Binding(
                                get: { model.preferences.appleGlassBubbleOpacity },
                                set: { value in model.updatePreferences { $0.appleGlassBubbleOpacity = UserPreferences.clamp(value, min: 0, max: 1) } }
                            )
                        )
                    }
                } header: {
                    Text(L10n.lookup("玻璃效果"))
                } footer: {
                    Text(glassEffectDescription)
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("聊天气泡"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeColorEditor) { selection in
            OptionalColorEditorSheet(selection: selection)
        }
    }

    private var glassEffectDescription: String {
        switch (usesCrystalGlass, usesSystemLiquidGlass) {
        case (true, true):
            L10n.lookup("水晶玻璃的数值控制清透与高光；Liquid Glass 的透明、折射和对比度由系统适配，这里只调整颜色染入程度。")
        case (true, false):
            L10n.lookup("数值越高，水晶玻璃越清透；细白光圈和左上高光会随之变得更轻。")
        case (false, true):
            L10n.lookup("Liquid Glass 的透明、折射和对比度由系统适配；这里仅调整颜色染入程度。")
        case (false, false):
            ""
        }
    }

    private func opacitySlider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsRowLabel(title: title, systemImage: "layers")
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.01)
                .tint(Color(uiColor: model.themeSliderUIColor))
        }
    }
}

private struct ChatBubbleRoleSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatBubbleTarget
    let onEditColor: (ChatBubbleTarget, ChatBubbleColorKind) -> Void

    var body: some View {
        Section(target.title) {
            Picker(selection: styleBinding) {
                ForEach(availableStyles) { style in
                    Text(styleTitle(for: style)).tag(style)
                }
            } label: {
                SettingsRowLabel(title: L10n.lookup("气泡样式"), systemImage: target.icon)
            }
            .pickerStyle(.menu)

            if target == .user {
                Toggle(
                    isOn: Binding(
                        get: { model.preferences.userBubbleSendAnimationEnabled },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences { $0.userBubbleSendAnimationEnabled = value }
                        }
                    )
                ) {
                    SettingsRowLabel(title: L10n.lookup("发送动画"), systemImage: "sparkles")
                }

                Picker(
                    selection: Binding(
                        get: { model.preferences.userBubbleSendAnimationStyle },
                        set: { value in
                            model.performSwitchHaptic()
                            model.updatePreferences { $0.userBubbleSendAnimationStyle = value }
                        }
                    )
                ) {
                    ForEach(UserBubbleSendAnimationStyle.allCases) { style in
                        Text(L10n.lookup(style.title)).tag(style)
                    }
                } label: {
                    SettingsRowLabel(title: L10n.lookup("动画效果"), systemImage: "wand.and.stars")
                }
                .pickerStyle(.menu)
                .disabled(!model.preferences.userBubbleSendAnimationEnabled)

                Text(L10n.lookup("只影响之后新发送的用户消息；历史消息与助手消息不会播放。“软弹”和“灵动”只动气泡，“上浮”会让气泡和用户头像一起移动。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if target == .thinking {
                TextField(L10n.lookup("思考中…"), text: thinkingTitleBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text(L10n.lookup("这里只自定义助手正在思考时显示的文字；思考结束后会恢复为普通的思考标题。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if styleBinding.wrappedValue == .plain {
                    Text(L10n.lookup("“默认”会直接显示思考标题与正文，不添加气泡背景；标题、文字颜色、Markdown 和折叠设置仍然生效。切换回其他样式时，原有气泡颜色与透明度会继续使用。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            colorEditorRow(
                kind: .bubble,
                value: bubbleColorBinding,
                fallback: fallbackBubbleColor
            )

            colorEditorRow(
                kind: .text,
                value: textColorBinding,
                fallback: Color(uiColor: .label)
            )

            if target == .assistant {
                colorEditorRow(
                    kind: .largeHeading,
                    value: assistantLargeHeadingColorBinding,
                    fallback: assistantHeadingFallbackColor
                )

                colorEditorRow(
                    kind: .smallHeading,
                    value: assistantSmallHeadingColorBinding,
                    fallback: assistantHeadingFallbackColor
                )

                Text(L10n.lookup("大标题对应 H1–H2，小标题对应 H3–H6；默认均跟随助手文字颜色。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SettingsRowLabel(title: L10n.lookup("气泡透明度"), systemImage: "circle.lefthalf.filled")
                    Spacer()
                    Text("\(Int((opacityBinding.wrappedValue * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: opacityBinding, in: 0...1, step: 0.01)
                    .tint(Color(uiColor: model.themeSliderUIColor))
            }
        }
    }

    private var availableStyles: [ChatBubbleStyle] {
        target == .thinking
            ? [.plain] + ChatBubbleStyle.bubbleCases
            : ChatBubbleStyle.bubbleCases
    }

    private func styleTitle(for style: ChatBubbleStyle) -> String {
        guard target == .thinking else { return style.title }
        return switch style {
        case .plain: L10n.lookup("默认")
        case .defaultStyle: L10n.lookup("柔和气泡")
        default: style.title
        }
    }

    private var styleBinding: Binding<ChatBubbleStyle> {
        Binding(
            get: {
                switch target {
                case .user: model.preferences.userChatBubbleStyle
                case .assistant: model.preferences.assistantChatBubbleStyle
                case .thinking: model.preferences.thinkingChatBubbleStyle
                }
            },
            set: { value in
                model.performListItemHaptic()
                model.updatePreferences {
                    switch target {
                    case .user: $0.userChatBubbleStyle = value
                    case .assistant: $0.assistantChatBubbleStyle = value
                    case .thinking: $0.thinkingChatBubbleStyle = value
                    }
                }
            }
        )
    }

    private var thinkingTitleBinding: Binding<String> {
        Binding(
            get: {
                let title = model.preferences.thinkingBubbleTitle
                return title.isEmpty ? L10n.lookup("思考中…") : title
            },
            set: { value in
                model.updatePreferences {
                    let cleaned = UserPreferences.cleanedThinkingTitle(value)
                    $0.thinkingBubbleTitle = cleaned == L10n.lookup("思考中…") ? "" : cleaned
                }
            }
        )
    }

    private var bubbleColorBinding: Binding<Int?> {
        Binding(
            get: {
                switch target {
                case .user: model.preferences.userChatBubbleColorARGB
                case .assistant: model.preferences.assistantChatBubbleColorARGB
                case .thinking: model.preferences.thinkingChatBubbleColorARGB
                }
            },
            set: { value in
                model.updatePreferences {
                    switch target {
                    case .user: $0.userChatBubbleColorARGB = value
                    case .assistant: $0.assistantChatBubbleColorARGB = value
                    case .thinking: $0.thinkingChatBubbleColorARGB = value
                    }
                }
            }
        )
    }

    private var textColorBinding: Binding<Int?> {
        Binding(
            get: {
                switch target {
                case .user: model.preferences.userChatTextColorARGB
                case .assistant: model.preferences.assistantChatTextColorARGB
                case .thinking: model.preferences.thinkingChatTextColorARGB
                }
            },
            set: { value in
                model.updatePreferences {
                    switch target {
                    case .user: $0.userChatTextColorARGB = value
                    case .assistant: $0.assistantChatTextColorARGB = value
                    case .thinking: $0.thinkingChatTextColorARGB = value
                    }
                }
            }
        )
    }

    private var assistantLargeHeadingColorBinding: Binding<Int?> {
        Binding(
            get: { model.preferences.assistantLargeHeadingColorARGB },
            set: { value in
                model.updatePreferences { $0.assistantLargeHeadingColorARGB = value }
            }
        )
    }

    private var assistantSmallHeadingColorBinding: Binding<Int?> {
        Binding(
            get: { model.preferences.assistantSmallHeadingColorARGB },
            set: { value in
                model.updatePreferences { $0.assistantSmallHeadingColorARGB = value }
            }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: {
                switch target {
                case .user: model.preferences.userChatBubbleOpacity
                case .assistant: model.preferences.assistantChatBubbleOpacity
                case .thinking: model.preferences.thinkingChatBubbleOpacity
                }
            },
            set: { value in
                model.updatePreferences {
                    let next = UserPreferences.clamp(value, min: 0, max: 1)
                    switch target {
                    case .user: $0.userChatBubbleOpacity = next
                    case .assistant: $0.assistantChatBubbleOpacity = next
                    case .thinking: $0.thinkingChatBubbleOpacity = next
                    }
                }
            }
        )
    }

    private var fallbackBubbleColor: Color {
        switch target {
        case .user: Color(uiColor: model.themeUserBubbleUIColor)
        case .assistant, .thinking: Color(uiColor: .tertiarySystemBackground)
        }
    }

    private var assistantHeadingFallbackColor: Color {
        Color(argb: model.preferences.assistantChatTextColorARGB)
            ?? Color(uiColor: .label)
    }

    private func colorEditorRow(
        kind: ChatBubbleColorKind,
        value: Binding<Int?>,
        fallback: Color
    ) -> some View {
        Button {
            model.performListItemHaptic()
            onEditColor(target, kind)
        } label: {
            HStack(spacing: 12) {
                SettingsRowLabel(title: L10n.lookup(kind.title), systemImage: kind.systemImage)
                Spacer(minLength: 12)
                if value.wrappedValue == nil {
                    Text(L10n.lookup("默认"))
                        .foregroundStyle(.secondary)
                }
                Circle()
                    .fill(Color(argb: value.wrappedValue) ?? fallback)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct OptionalColorEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: ChatBubbleColorSelection

    private var value: Binding<Int?> {
        Binding(
            get: {
                switch selection.kind {
                case .bubble:
                    switch selection.target {
                    case .user: model.preferences.userChatBubbleColorARGB
                    case .assistant: model.preferences.assistantChatBubbleColorARGB
                    case .thinking: model.preferences.thinkingChatBubbleColorARGB
                    }
                case .text:
                    switch selection.target {
                    case .user: model.preferences.userChatTextColorARGB
                    case .assistant: model.preferences.assistantChatTextColorARGB
                    case .thinking: model.preferences.thinkingChatTextColorARGB
                    }
                case .largeHeading:
                    model.preferences.assistantLargeHeadingColorARGB
                case .smallHeading:
                    model.preferences.assistantSmallHeadingColorARGB
                }
            },
            set: { newValue in
                model.updatePreferences { preferences in
                    switch selection.kind {
                    case .bubble:
                        switch selection.target {
                        case .user: preferences.userChatBubbleColorARGB = newValue
                        case .assistant: preferences.assistantChatBubbleColorARGB = newValue
                        case .thinking: preferences.thinkingChatBubbleColorARGB = newValue
                        }
                    case .text:
                        switch selection.target {
                        case .user: preferences.userChatTextColorARGB = newValue
                        case .assistant: preferences.assistantChatTextColorARGB = newValue
                        case .thinking: preferences.thinkingChatTextColorARGB = newValue
                        }
                    case .largeHeading:
                        preferences.assistantLargeHeadingColorARGB = newValue
                    case .smallHeading:
                        preferences.assistantSmallHeadingColorARGB = newValue
                    }
                }
            }
        )
    }

    private var fallback: Color {
        switch selection.kind {
        case .bubble:
            switch selection.target {
            case .user: Color(uiColor: model.themeUserBubbleUIColor)
            case .assistant, .thinking: Color(uiColor: .tertiarySystemBackground)
            }
        case .text:
            Color(uiColor: .label)
        case .largeHeading, .smallHeading:
            Color(argb: model.preferences.assistantChatTextColorARGB)
                ?? Color(uiColor: .label)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ColorPicker(
                        selection: Binding(
                            get: { Color(argb: value.wrappedValue) ?? fallback },
                            set: { color in value.wrappedValue = color.argbValue }
                        ),
                        supportsOpacity: true
                    ) {
                        SettingsRowLabel(
                            title: L10n.format("选择%@", [String(describing: selection.kind.title)]),
                            systemImage: selection.kind.systemImage
                        )
                    }
                } footer: {
                    Text(value.wrappedValue == nil ? L10n.format("当前正在使用默认%@。", [String(describing: selection.kind.title)]) : L10n.lookup("修改会立即应用；需要恢复时，可使用下面的独立选项。"))
                }

                if value.wrappedValue != nil {
                    Section {
                        Button(L10n.format("恢复默认%@", [String(describing: selection.kind.title)]), role: .destructive) {
                            model.performListItemHaptic()
                            value.wrappedValue = nil
                            dismiss()
                        }
                    }
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(selection.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("完成")) { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PreferenceSliderSheet: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double
    let valueText: (Double) -> String
    let leadingText: String
    let trailingText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                Text(valueText(value))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Slider(value: $value, in: range, step: step)
                .tint(Color(uiColor: model.themeSliderUIColor))

            HStack {
                Text(leadingText)
                Spacer()
                Text(trailingText)
            }
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }
}

private struct ChatInputOpacitySheet: View {
    @Environment(AppModel.self) private var model

    private var lightBinding: Binding<Double> {
        Binding(
            get: { model.preferences.chatInputBackgroundOpacityLight },
            set: { value in
                model.updatePreferences {
                    $0.chatInputBackgroundOpacityLight = UserPreferences.clamp(value, min: 0.0, max: 1.0)
                }
            }
        )
    }

    private var darkBinding: Binding<Double> {
        Binding(
            get: { model.preferences.chatInputBackgroundOpacityDark },
            set: { value in
                model.updatePreferences {
                    $0.chatInputBackgroundOpacityDark = UserPreferences.clamp(value, min: 0.0, max: 1.0)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L10n.lookup("输入框背景透明度"))
                .font(.system(size: 19, weight: .semibold))

            opacitySlider(title: L10n.lookup("浅色模式"), value: lightBinding)
            opacitySlider(title: L10n.lookup("深色模式"), value: darkBinding)

            Text(L10n.lookup("分别控制浅色和深色模式下 Composer 浮层的背景强度。"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
    }

    private func opacitySlider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Slider(value: value, in: 0...1, step: 0.05)
                .tint(Color(uiColor: model.themeSliderUIColor))

            HStack {
                Text("0%")
                Spacer()
                Text("100%")
            }
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }
}

private struct ChatInputPlaceholderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(currentValue: String) {
        _draft = State(initialValue: currentValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.lookup("默认占位文字"), text: $draft, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: draft) { _, value in
                            let cleaned = UserPreferences.cleanedPlaceholder(value)
                            if cleaned != value {
                                draft = cleaned
                            }
                        }
                } footer: {
                    Text(L10n.lookup("留空时使用当前助手或群聊的默认发送提示；最多 40 个字符。"))
                }

                Section {
                    Button(L10n.lookup("恢复默认")) {
                        draft = ""
                        saveAndDismiss()
                    }
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(L10n.lookup("输入框占位文字"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        saveAndDismiss()
                    }
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveAndDismiss() {
        model.updatePreferences {
            $0.chatInputPlaceholder = UserPreferences.cleanedPlaceholder(draft)
        }
        dismiss()
    }
}

struct NetworkProxyPage: View {
    @State private var settings = AppPreferences.loadProxySettings()

    var body: some View {
        Form {
            Section {
                Toggle(L10n.lookup("启用代理"), isOn: $settings.enabled)
            } footer: {
                Text(L10n.lookup("对所有供应商的模型请求生效（HTTP/HTTPS）"))
            }

            if settings.enabled {
                Section(L10n.lookup("服务器")) {
                    TextField(L10n.lookup("主机（如 127.0.0.1）"), text: $settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField(L10n.lookup("端口（如 7890）"), text: $settings.port)
                        .keyboardType(.numberPad)
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("网络代理"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, newValue in
            AppPreferences.saveProxySettings(newValue)
        }
    }
}

// MARK: - Backup Settings

private struct BackupShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
private enum BackupImportActivity {
    case checking
    case safetyBackup
    case restoring

    var title: String {
        switch self {
        case .checking: L10n.lookup("正在检查备份…")
        case .safetyBackup: L10n.lookup("正在备份当前数据…")
        case .restoring: L10n.lookup("正在导入备份…")
        }
    }

    var detail: String {
        switch self {
        case .checking: L10n.lookup("正在读取 ZIP 并检查备份内容。")
        case .safetyBackup: L10n.lookup("覆盖导入前，先为当前数据保留一份安全备份。")
        case .restoring: L10n.lookup("正在恢复备份中的数据，完成后会显示导入结果。")
        }
    }
}

private struct BackupPage: View {
    @Environment(AppModel.self) private var model
    @State private var options = BackupOptionsPersistence.load()
    @State private var isExporting = false
    @State private var lastBackupURL: URL? = BackupService.latestSafetyBackupURL()
    @State private var shareItem: BackupShareItem?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var importActivity: BackupImportActivity?
    @State private var pendingImportURL: URL?
    @State private var backupInspection: BackupInspection?
    @State private var isInspectionAlertPresented = false
    @State private var isImportModeDialogPresented = false
    @State private var isFileImporterPresented = false

    private var isImportBusy: Bool { importActivity != nil }

    var body: some View {
        List {
            Section {
                Toggle(isOn: includeChatsBinding) {
                    SettingsRowLabel(title: L10n.lookup("聊天记录"), systemImage: "message")
                }
                Toggle(isOn: includeFilesBinding) {
                    SettingsRowLabel(title: L10n.lookup("文件"), systemImage: "doc")
                }
            } header: {
                Text(L10n.lookup("备份管理"))
            } footer: {
                Text(L10n.lookup("导出时可选择是否包含聊天记录和附件、头像、背景文件。"))
            }

            Section {
                Button {
                    selectBackup()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "shippingbox.and.arrow.backward")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(importActivityTitle(defaultTitle: L10n.lookup("导入备份")))
                                .foregroundStyle(.primary)
                            Text(L10n.lookup("从兼容的 ZIP 备份导入助手、设置、世界书和聊天"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isImportBusy { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExporting || isImportBusy)

                Button {
                    exportBackup()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(isExporting ? L10n.lookup("正在导出...") : L10n.lookup("导出为文件"))
                                .foregroundStyle(.primary)
                            Text(L10n.lookup("打包 APP 数据为 ZIP 备份文件"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isExporting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExporting || isImportBusy)

                Button {
                    selectBackup()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(importActivityTitle(defaultTitle: L10n.lookup("Mocca 备份恢复")))
                                .foregroundStyle(.primary)
                            Text(L10n.lookup("恢复由当前原生版导出的 ZIP 备份"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isImportBusy {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExporting || isImportBusy)

                if let lastBackupURL {
                    Button {
                        shareItem = BackupShareItem(url: lastBackupURL)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.green)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.lookup("分享/保存最近备份"))
                                    .foregroundStyle(.primary)
                                Text("\(lastBackupURL.lastPathComponent) · \(BackupService.backupDirectorySizeDescription(lastBackupURL))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                Text(L10n.lookup("本机备份"))
            } footer: {
                Text(L10n.lookup("选择 ZIP 后会自动识别备份格式，并核对聊天与附件数量；完整性检查通过后，才会让你选择导入方式。系统相册、通知等权限需要在新 App 中重新允许。备份可能包含聊天与 API 密钥，请妥善保管。"))
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .settingsGroupedPageStyle()
        .disabled(isImportBusy)
        .accessibilityHidden(isImportBusy)
        .overlay {
            if let importActivity {
                ZStack {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text(importActivity.title)
                            .font(.headline)
                        Text(importActivity.detail)
                        Text(L10n.lookup("大备份可能需要较长时间，请保持 App 打开并耐心等待。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: 340)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .padding(24)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle(L10n.lookup("备份与还原"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isImportBusy)
        .interactiveDismissDisabled(isImportBusy)
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(items: [item.url])
        }
        .alert(
            L10n.lookup("备份体检"),
            isPresented: $isInspectionAlertPresented
        ) {
            if let inspection = backupInspection, !inspection.blocksRestore {
                Button(
                    inspection.requiresMissingImageAcknowledgement
                        ? L10n.lookup("我知道，仍然继续")
                        : L10n.lookup("继续"),
                    role: inspection.requiresMissingImageAcknowledgement ? .destructive : nil
                ) {
                    DispatchQueue.main.async {
                        isImportModeDialogPresented = true
                    }
                }
            }
            Button(L10n.lookup("取消"), role: .cancel) {}
        } message: {
            Text(inspectionAlertMessage)
        }
        .confirmationDialog(
            L10n.lookup("选择导入模式"),
            isPresented: $isImportModeDialogPresented,
            titleVisibility: .visible
        ) {
            ForEach(BackupRestoreMode.allCases) { mode in
                Button(L10n.lookup(mode.title), role: mode == .overwrite ? .destructive : nil) {
                    guard let url = pendingImportURL else { return }
                    importBackup(from: url, mode: mode)
                }
            }
            Button(L10n.lookup("取消"), role: .cancel) {}
        } message: {
            Text(L10n.lookup("完全覆盖会先自动备份当前 Mocca，再替换同类数据；智能合并只添加不存在的数据。"))
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "zip") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                inspectBackup(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var includeChatsBinding: Binding<Bool> {
        Binding(
            get: { options.includeChats },
            set: { newValue in
                options.includeChats = newValue
                BackupOptionsPersistence.save(options)
            }
        )
    }

    private var includeFilesBinding: Binding<Bool> {
        Binding(
            get: { options.includeFiles },
            set: { newValue in
                options.includeFiles = newValue
                BackupOptionsPersistence.save(options)
            }
        )
    }

    private var inspectionAlertMessage: String {
        guard let inspection = backupInspection else {
            return L10n.lookup("没有可显示的备份信息")
        }
        var message = inspection.summaryMessage
        if inspection.blocksRestore {
            message += L10n.lookup("\n\n这个原生备份不完整，已锁定恢复。请重新选择完整 ZIP，或回到旧 App 重新导出。")
        } else if inspection.requiresMissingImageAcknowledgement {
            message += L10n.lookup("\n\n这是旧版 ZIP 备份。继续后，能找到的图片会恢复；找不到的图片会保留原始文字标记。")
        }
        if !inspection.warnings.isEmpty {
            message += "\n\n" + inspection.warnings.joined(separator: "\n")
        }
        return message
    }

    private func importActivityTitle(defaultTitle: String) -> String {
        importActivity?.title ?? defaultTitle
    }

    private func selectBackup() {
        statusMessage = nil
        errorMessage = nil
        pendingImportURL = nil
        backupInspection = nil
        isFileImporterPresented = true
    }

    private func inspectBackup(from url: URL) {
        importActivity = .checking
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let inspection = try await Task.detached(priority: .userInitiated) {
                    try BackupService.inspectBackup(from: url)
                }.value
                await MainActor.run {
                    pendingImportURL = url
                    backupInspection = inspection
                    importActivity = nil
                    isInspectionAlertPresented = true
                }
            } catch {
                await MainActor.run {
                    pendingImportURL = nil
                    backupInspection = nil
                    errorMessage = error.localizedDescription
                    importActivity = nil
                }
            }
        }
    }

    private func exportBackup() {
        isExporting = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let result = try await BackupService.createBackup(options: options, model: model)
                await MainActor.run {
                    lastBackupURL = result.url
                    statusMessage = result.message
                    shareItem = BackupShareItem(url: result.url)
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    private func importBackup(from url: URL, mode: BackupRestoreMode) {
        importActivity = mode == .overwrite ? .safetyBackup : .restoring
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let safetyBackup: BackupCreationResult?
                if mode == .overwrite {
                    let created = try await BackupService.createBackup(
                        options: BackupOptions(includeChats: true, includeFiles: true),
                        model: model,
                        allowMissingAttachmentReferences: true
                    )
                    let preserved = try BackupService.preserveSafetyBackup(created)
                    safetyBackup = preserved
                    await MainActor.run {
                        lastBackupURL = preserved.url
                        statusMessage = L10n.lookup("导入前安全备份已保留，可通过“分享/保存最近备份”保存到设备之外")
                        importActivity = .restoring
                    }
                } else {
                    safetyBackup = nil
                }
                let summary = try await BackupService.restoreBackup(from: url, mode: mode, model: model)
                await MainActor.run {
                    if let safetyBackup {
                        lastBackupURL = safetyBackup.url
                        statusMessage = summary.message + L10n.lookup("；导入前安全备份已保留")
                        if !safetyBackup.warnings.isEmpty {
                            statusMessage? += "（" + safetyBackup.warnings.joined(separator: "；") + "）"
                        }
                    } else {
                        statusMessage = summary.message
                    }
                    pendingImportURL = nil
                    backupInspection = nil
                    importActivity = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    importActivity = nil
                }
            }
        }
    }

}

private struct AboutPage: View {
    private var aboutAppIconImage: UIImage? {
        guard let iconURL = Bundle.main.url(
            forResource: "AboutAppIcon",
            withExtension: "png"
        ) else {
            return nil
        }
        return UIImage(contentsOfFile: iconURL.path)
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Group {
                        if let aboutAppIconImage {
                            Image(uiImage: aboutAppIconImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image("AssistantAvatar")
                                .resizable()
                                .scaledToFill()
                        }
                    }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Mocca")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(L10n.lookup("原生 SwiftUI AI 客户端"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            Section {
                HStack {
                    Text(L10n.lookup("版本"))
                    Spacer()
                    Text(version)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.lookup("帮助与政策")) {
                NavigationLink {
                    MoccaDocumentationPage()
                } label: {
                    Label(L10n.lookup("使用文档"), systemImage: "doc.text")
                }
                NavigationLink {
                    MoccaPrivacyPolicyPage()
                } label: {
                    Label(L10n.lookup("隐私政策"), systemImage: "hand.raised")
                }
                NavigationLink {
                    MoccaLegalNoticesPage()
                } label: {
                    Label(L10n.lookup("关于与许可"), systemImage: "doc.badge.gearshape")
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("关于"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Search Service Settings

struct SearchServiceSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var services: [SearchServiceConfiguration] = []
    @State private var editorPresentation: SearchServiceEditorPresentation?
    @State private var pendingDeletion: SearchServiceConfiguration?
    @State private var connectionStates: [UUID: SearchServiceConnectionState] = [:]
    @State private var testNotice: SearchServiceTestNotice?

    private let retentionOptions = [-1, 0, 1, 2, 3, 5, 10]

    var body: some View {
        lifecycleContent
    }

    private var lifecycleContent: some View {
        dialogContent
            .task {
                reloadServices()
            }
            .onChange(of: model.preferences.searchServices) { _, _ in
                reloadServices()
            }
            .onChange(of: model.preferences) { _, _ in
                AppPreferences.savePreferences(model.preferences)
            }
    }

    private var dialogContent: some View {
        navigationContent
            .confirmationDialog(
                L10n.lookup("删除搜索服务？"),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { service in
                Button(L10n.format("删除 %@", [String(describing: service.resolvedName)]), role: .destructive) {
                    delete(service)
                }
                Button(L10n.lookup("取消"), role: .cancel) {}
            } message: { service in
                Text(L10n.format("将移除 %@ 的配置与本机保存的密钥。", [String(describing: service.resolvedName)]))
            }
            .alert(item: $testNotice) { notice in
                Alert(
                    title: Text(notice.succeeded ? L10n.lookup("连接成功") : L10n.lookup("连接失败")),
                    message: Text(notice.message),
                    dismissButton: .default(Text(L10n.lookup("好")))
                )
            }
    }

    private var navigationContent: some View {
        searchServiceList
            .settingsGroupedPageStyle()
            .navigationTitle(L10n.lookup("搜索服务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentNewServiceEditor()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.lookup("添加搜索服务"))
                }
            }
            .sheet(item: $editorPresentation) { presentation in
                SearchServiceEditorView(
                    configuration: presentation.configuration,
                    isNew: presentation.isNew
                ) { saved in
                    save(saved, isNew: presentation.isNew)
                }
            }
    }

    private var searchServiceList: some View {
        @Bindable var model = model
        return List {
            Section {
                Toggle(L10n.lookup("联网搜索"), isOn: searchEnabledBinding)

                Picker(L10n.lookup("搜索方式"), selection: searchModeBinding) {
                    ForEach(AssistantSearchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!model.currentAssistant.searchEnabled)
            } header: {
                Text(L10n.lookup("当前助手"))
            } footer: {
                Text(model.currentAssistant.searchMode.explanation)
            }

            Section {
                if services.isEmpty {
                    Button {
                        presentNewServiceEditor()
                    } label: {
                        Label(L10n.lookup("添加搜索服务"), systemImage: "plus.circle")
                    }
                } else {
                    ForEach(services, id: \.id) { service in
                        searchServiceEntry(service)
                    }
                }
            } header: {
                Text(L10n.lookup("搜索提供商"))
            } footer: {
                Text(L10n.lookup("这些提供商用于应用搜索服务，配置由所有助手共用。模型内置搜索由模型服务商提供。"))
            }

            Section {
                Picker(L10n.lookup("搜索结果上下文"), selection: searchRetentionBinding) {
                    ForEach(retentionOptions, id: \.self) { value in
                        Text(searchRetentionLabel(value)).tag(value)
                    }
                }

                Stepper(
                    L10n.format("搜索结果数量：%@", [String(describing: model.preferences.searchResultCount)]),
                    value: $model.preferences.searchResultCount,
                    in: 1...20
                )

                Stepper(
                    L10n.format("超时时间：%@ 秒", [String(describing: model.preferences.searchTimeoutSeconds)]),
                    value: $model.preferences.searchTimeoutSeconds,
                    in: 1...30
                )
            } header: {
                Text(L10n.lookup("通用选项"))
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.lookup("完整搜索结果会保留到指定的后续用户轮数；例如 3 轮会在第 4 个后续用户回合开始前移除。仅当前回复不会在下一轮重放搜索结果。"))
                    Text(L10n.lookup("结果数量和超时会应用于当前选中的第三方搜索服务。"))
                }
            }
        }
    }

    private var searchEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.currentAssistant.searchEnabled },
            set: { value in
                var assistant = model.currentAssistant
                guard assistant.searchEnabled != value else { return }
                model.performSwitchHaptic()
                assistant.searchEnabled = value
                model.updateAssistant(assistant)
            }
        )
    }

    private var searchRetentionBinding: Binding<Int> {
        Binding(
            get: { model.preferences.searchToolResultRetentionTurns },
            set: { value in
                model.updatePreferences {
                    $0.searchToolResultRetentionTurns = min(max(value, -1), 20)
                }
            }
        )
    }

    private var searchModeBinding: Binding<AssistantSearchMode> {
        Binding(
            get: { model.currentAssistant.searchMode },
            set: { value in
                var assistant = model.currentAssistant
                guard assistant.searchMode != value else { return }
                model.performSwitchHaptic()
                assistant.searchMode = value
                model.updateAssistant(assistant)
            }
        )
    }

    private func searchRetentionLabel(_ value: Int) -> String {
        if value < 0 { return L10n.lookup("永久保留") }
        if value == 0 { return L10n.lookup("仅当前回复") }
        return L10n.format("%@ 轮", [String(describing: value)])
    }

    private func searchServiceEntry(_ service: SearchServiceConfiguration) -> some View {
        searchServiceRow(service)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDeletion = service
                } label: {
                    Label(L10n.lookup("删除"), systemImage: "trash")
                }
                .disabled(services.count <= 1)

                Button {
                    presentEditor(for: service)
                } label: {
                    Label(L10n.lookup("编辑"), systemImage: "pencil")
                }
                .tint(.blue)
            }
            .contextMenu {
                Button {
                    select(service)
                } label: {
                    Label(L10n.lookup("设为当前服务"), systemImage: "checkmark.circle")
                }

                Button {
                    testConnection(service)
                } label: {
                    Label(L10n.lookup("连接测试"), systemImage: "network")
                }
                .disabled(connectionStates[service.id] == .testing)

                Button {
                    presentEditor(for: service)
                } label: {
                    Label(L10n.lookup("编辑"), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    pendingDeletion = service
                } label: {
                    Label(L10n.lookup("删除"), systemImage: "trash")
                }
                .disabled(services.count <= 1)
            }
    }

    @ViewBuilder
    private func searchServiceRow(_ service: SearchServiceConfiguration) -> some View {
        let isSelected = model.preferences.selectedSearchServiceID == service.id
        HStack(spacing: 12) {
            Button {
                select(service)
            } label: {
                HStack(spacing: 12) {
                    searchServiceBrandMark(for: service.kind, isSelected: isSelected)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.resolvedName)
                            .foregroundStyle(.primary)
                        Text(L10n.lookup(service.kind.title))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    connectionBadge(for: service)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel(L10n.lookup("当前服务"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                testConnection(service)
            } label: {
                Image(systemName: "network")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(connectionStates[service.id] == .testing)
            .accessibilityLabel(L10n.format("测试 %@ 的连接", [String(describing: service.resolvedName)]))

            Button {
                presentEditor(for: service)
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.format("编辑 %@", [String(describing: service.resolvedName)]))
        }
    }

    @ViewBuilder
    private func searchServiceBrandMark(
        for kind: SearchServiceKind,
        isSelected: Bool
    ) -> some View {
        if let assetName = kind.brandAssetName {
            Image(assetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .padding(2)
                .accessibilityHidden(true)
        } else {
            Image(systemName: searchServiceIcon(for: kind))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func connectionBadge(for service: SearchServiceConfiguration) -> some View {
        switch connectionStates[service.id] ?? .idle {
        case .idle:
            EmptyView()
        case .testing:
            Label(L10n.lookup("测试中"), systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        case .connected:
            Label(L10n.lookup("已连接"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label(L10n.lookup("失败"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
    }

    private func reloadServices() {
        let hydrated = SearchSecretStore.hydrate(model.preferences.searchServices)
        services = hydrated
        if let first = hydrated.first,
           !hydrated.contains(where: { $0.id == model.preferences.selectedSearchServiceID }) {
            model.preferences.selectedSearchServiceID = first.id
        }
    }

    private func presentNewServiceEditor() {
        let configuration = SearchServiceConfiguration(
            id: UUID(),
            kind: .duckDuckGo,
            name: "",
            endpoint: SearchServiceKind.duckDuckGo.defaultEndpoint,
            apiKey: "",
            username: "",
            password: "",
            options: [:]
        )
        editorPresentation = SearchServiceEditorPresentation(configuration: configuration, isNew: true)
    }

    private func presentEditor(for service: SearchServiceConfiguration) {
        editorPresentation = SearchServiceEditorPresentation(configuration: service, isNew: false)
    }

    private func select(_ service: SearchServiceConfiguration) {
        model.preferences.selectedSearchServiceID = service.id
    }

    private func save(_ configuration: SearchServiceConfiguration, isNew: Bool) -> Bool {
        var updated = services
        if let index = updated.firstIndex(where: { $0.id == configuration.id }) {
            updated[index] = configuration
        } else if isNew {
            updated.append(configuration)
        }
        guard commit(updated) else { return false }
        if updated.count == 1 {
            model.preferences.selectedSearchServiceID = configuration.id
        }
        return true
    }

    private func delete(_ service: SearchServiceConfiguration) {
        guard services.count > 1 else { return }
        let updated = services.filter { $0.id != service.id }
        guard commit(updated) else {
            testNotice = SearchServiceTestNotice(
                succeeded: false,
                message: L10n.lookup("搜索服务配置无法写入钥匙串，请稍后重试。")
            )
            return
        }
        SearchSecretStore.remove(service)
        if model.preferences.selectedSearchServiceID == service.id, let first = updated.first {
            model.preferences.selectedSearchServiceID = first.id
        }
        connectionStates[service.id] = nil
        pendingDeletion = nil
    }

    private func commit(_ updated: [SearchServiceConfiguration]) -> Bool {
        var candidatePreferences = model.preferences
        candidatePreferences.searchServices = updated
        if !updated.contains(where: { $0.id == candidatePreferences.selectedSearchServiceID }) {
            candidatePreferences.selectedSearchServiceID = updated.first?.id
        }
        guard AppPreferences.savePreferences(candidatePreferences) else { return false }
        services = updated
        model.preferences.searchServices = updated
        model.preferences.selectedSearchServiceID = candidatePreferences.selectedSearchServiceID
        return true
    }

    private func testConnection(_ service: SearchServiceConfiguration) {
        guard connectionStates[service.id] != .testing else { return }
        if let error = SearchServiceExecutor.configurationError(service) {
            connectionStates[service.id] = .failed
            testNotice = SearchServiceTestNotice(succeeded: false, message: error)
            return
        }

        connectionStates[service.id] = .testing
        let common = SearchCommonOptions(
            resultCount: 1,
            timeoutSeconds: model.preferences.searchTimeoutSeconds
        )
        Task {
            let response = await SearchServiceExecutor.search(
                query: "connectivity test",
                configuration: service,
                common: common
            )
            let error = searchServiceResponseError(response)
            await MainActor.run {
                if let error {
                    connectionStates[service.id] = .failed
                    testNotice = SearchServiceTestNotice(succeeded: false, message: error)
                } else {
                    connectionStates[service.id] = .connected
                    testNotice = SearchServiceTestNotice(
                        succeeded: true,
                        message: L10n.format("%@ 可以正常请求。", [String(describing: service.resolvedName)])
                    )
                }
            }
        }
    }
}

private struct SearchServiceEditorPresentation: Identifiable {
    let id = UUID()
    let configuration: SearchServiceConfiguration
    let isNew: Bool
}

private enum SearchServiceConnectionState: Equatable {
    case idle
    case testing
    case connected
    case failed
}

private struct SearchServiceTestNotice: Identifiable {
    let id = UUID()
    let succeeded: Bool
    let message: String
}

private struct SearchServiceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchServiceConfiguration
    @State private var testState: SearchServiceConnectionState = .idle
    @State private var testMessage: String?
    @State private var isProviderPickerPresented = false

    let isNew: Bool
    let onSave: (SearchServiceConfiguration) -> Bool

    init(
        configuration: SearchServiceConfiguration,
        isNew: Bool,
        onSave: @escaping (SearchServiceConfiguration) -> Bool
    ) {
        _draft = State(initialValue: configuration)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.lookup("服务类型")) {
                    Button {
                        isProviderPickerPresented = true
                    } label: {
                        HStack(spacing: 12) {
                            Text(L10n.lookup("提供商"))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            SearchServiceKindMark(kind: draft.kind)
                                .frame(width: 22, height: 22)
                            Text(L10n.lookup(draft.kind.title))
                                .foregroundStyle(.secondary)
                            if isNew {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isNew)
                    .accessibilityIdentifier("searchService.chooseProvider")

                    Text(L10n.lookup(draft.kind.description))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(L10n.lookup("自定义名称（可选）"), text: $draft.name)
                }

                if draft.kind.requiresEndpoint || !draft.kind.defaultEndpoint.isEmpty {
                    Section {
                        TextField(draft.kind.defaultEndpoint, text: $draft.endpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text(L10n.lookup("服务地址"))
                    } footer: {
                        if !draft.kind.defaultEndpoint.isEmpty {
                            Text(L10n.format("留空时使用默认地址：%@", [String(describing: draft.kind.defaultEndpoint)]))
                        }
                    }
                }

                if draft.kind.requiresAPIKey {
                    Section(L10n.lookup("凭据")) {
                        SecureField("API Key", text: $draft.apiKey)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                providerSpecificFields

                Section {
                    Button {
                        testDraftConnection()
                    } label: {
                        HStack {
                            Label(L10n.lookup("连接测试"), systemImage: testStateIcon)
                            Spacer()
                            if testState == .connected {
                                Text(L10n.lookup("成功"))
                                    .foregroundStyle(.green)
                            } else if testState == .failed {
                                Text(L10n.lookup("失败"))
                                    .foregroundStyle(.red)
                            } else if testState == .testing {
                                Text(L10n.lookup("测试中"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(testState == .testing)
                } footer: {
                    if let testMessage {
                        Text(testMessage)
                            .foregroundStyle(testState == .failed ? Color.red : Color.secondary)
                    } else if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .settingsGroupedPageStyle()
            .navigationTitle(isNew ? L10n.lookup("添加搜索服务") : L10n.lookup("编辑搜索服务"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isProviderPickerPresented) {
                SearchServiceKindPicker(selection: $draft.kind)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(isNew ? L10n.lookup("添加搜索服务") : L10n.lookup("编辑搜索服务"))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.lookup("取消")) { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.lookup("保存")) {
                        if onSave(normalizedDraft) {
                            dismiss()
                        } else {
                            testState = .failed
                            testMessage = L10n.lookup("搜索服务配置无法写入钥匙串，请稍后重试。")
                        }
                    }
                        .foregroundStyle(.primary)
                    .disabled(validationMessage != nil)
                }
            }
            .onChange(of: draft.kind) { oldKind, newKind in
                if draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || draft.endpoint == oldKind.defaultEndpoint {
                    draft.endpoint = newKind.defaultEndpoint
                }
                testState = .idle
                testMessage = nil
            }
        }
    }

    @ViewBuilder
    private var providerSpecificFields: some View {
        switch kindKey {
        case let key where key.contains("duck"):
            Section("DuckDuckGo") {
                TextField(L10n.lookup("区域，例如 us-en"), text: optionBinding("region", defaultValue: "us-en"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

        case let key where key.contains("sear"):
            Section(L10n.lookup("SearXNG 选项")) {
                TextField(L10n.lookup("搜索引擎，例如 google,duckduckgo"), text: optionBinding("engines"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.lookup("语言，例如 en-US"), text: optionBinding("language"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.lookup("用户名（可选）"), text: $draft.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.lookup("密码（可选）"), text: $draft.password)
                    .textContentType(.password)
            }

        case let key where key.contains("serper"):
            Section(L10n.lookup("Serper 选项")) {
                TextField(L10n.lookup("国家，例如 cn"), text: optionBinding("gl"))
                    .textInputAutocapitalization(.never)
                TextField(L10n.lookup("语言，例如 zh-cn"), text: optionBinding("hl"))
                    .textInputAutocapitalization(.never)
                TextField(L10n.lookup("时间筛选，例如 qdr:d"), text: optionBinding("tbs"))
                    .textInputAutocapitalization(.never)
                TextField(L10n.lookup("页码，默认 1"), text: optionBinding("page", defaultValue: "1"))
                    .keyboardType(.numberPad)
            }

        case let key where key.contains("grok"):
            Section(L10n.lookup("Grok 选项")) {
                TextField(L10n.lookup("模型"), text: optionBinding("model", defaultValue: "grok-4.3"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(
                    L10n.lookup("系统提示词"),
                    text: optionBinding(
                        "systemPrompt",
                        defaultValue: "You are a helpful search assistant. Search the web to find accurate and up-to-date information for the user's query. Provide a comprehensive answer with citations."
                    ),
                    axis: .vertical
                )
                .lineLimit(3...7)
            }

        case let key where key.contains("querit"):
            Section(L10n.lookup("Querit 筛选")) {
                TextField(L10n.lookup("包含站点（逗号或换行分隔）"), text: optionBinding("sitesInclude"), axis: .vertical)
                    .lineLimit(1...3)
                TextField(L10n.lookup("排除站点（逗号或换行分隔）"), text: optionBinding("sitesExclude"), axis: .vertical)
                    .lineLimit(1...3)
                TextField(L10n.lookup("时间范围，例如 d7"), text: optionBinding("timeRange"))
                TextField(L10n.lookup("国家（逗号或换行分隔）"), text: optionBinding("countries"), axis: .vertical)
                    .lineLimit(1...3)
                TextField(L10n.lookup("语言（逗号或换行分隔）"), text: optionBinding("languages"), axis: .vertical)
                    .lineLimit(1...3)
            }

        default:
            EmptyView()
        }
    }

    private var kindKey: String {
        String(describing: draft.kind)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private var normalizedDraft: SearchServiceConfiguration {
        var result = draft
        result.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String: String] = draft.options.reduce(into: [:]) { output, pair in
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                output[pair.key] = value
            }
        }
        if kindKey.contains("duck"), options["region"] == nil {
            options["region"] = "us-en"
        }
        if kindKey.contains("serper"), options["page"] == nil {
            options["page"] = "1"
        }
        if kindKey.contains("grok") {
            options["model"] = options["model"] ?? "grok-4.3"
            options["systemPrompt"] = options["systemPrompt"]
                ?? "You are a helpful search assistant. Search the web to find accurate and up-to-date information for the user's query. Provide a comprehensive answer with citations."
        }
        result.options = options
        return result
    }

    private var validationMessage: String? {
        SearchServiceExecutor.configurationError(normalizedDraft)
    }

    private var testStateIcon: String {
        switch testState {
        case .idle: "network"
        case .testing: "hourglass"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func optionBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { draft.options[key] ?? defaultValue },
            set: { value in
                var options = draft.options
                options[key] = value
                draft.options = options
            }
        )
    }

    private func testDraftConnection() {
        let configuration = normalizedDraft
        if let error = SearchServiceExecutor.configurationError(configuration) {
            testState = .failed
            testMessage = error
            return
        }

        testState = .testing
        testMessage = nil
        Task {
            let response = await SearchServiceExecutor.search(
                query: "connectivity test",
                configuration: configuration,
                common: SearchCommonOptions(
                    resultCount: 1,
                    timeoutSeconds: model.preferences.searchTimeoutSeconds
                )
            )
            let error = searchServiceResponseError(response)
            await MainActor.run {
                if let error {
                    testState = .failed
                    testMessage = error
                } else {
                    testState = .connected
                    testMessage = L10n.lookup("连接正常。")
                }
            }
        }
    }
}

private struct SearchServiceKindMark: View {
    let kind: SearchServiceKind

    var body: some View {
        Group {
            if let asset = kind.brandAssetName {
                Image(asset)
                    .resizable()
                    .renderingMode([SearchServiceKind.linkup, .ollama, .grok].contains(kind) ? .template : .original)
                    .scaledToFit()
                    .padding(2)
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: searchServiceIcon(for: kind))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SearchServiceKindPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: SearchServiceKind
    @State private var query = ""

    private var groups: [(title: String, kinds: [SearchServiceKind])] {
        [
            ("无需 API Key", [.duckDuckGo, .bingLocal]),
            ("需要 API Key", SearchServiceKind.allCases.filter(\.requiresAPIKey)),
            ("自建服务", [.searxng])
        ]
    }

    private func matches(_ kind: SearchServiceKind) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || [kind.title, L10n.lookup(kind.title), kind.rawValue,
                               kind.description, L10n.lookup(kind.description)]
            .contains { $0.localizedStandardContains(text) }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                let kinds = group.kinds.filter(matches)
                if !kinds.isEmpty {
                    Section {
                        ForEach(kinds) { kind in
                            Button {
                                selection = kind
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    SearchServiceKindMark(kind: kind)
                                        .frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(L10n.lookup(kind.title))
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text(L10n.lookup(kind.description))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 8)
                                    if selection == kind {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                            .accessibilityLabel(L10n.lookup("当前服务"))
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("searchService.provider.\(kind.rawValue)")
                            .accessibilityAddTraits(selection == kind ? .isSelected : [])
                        }
                    } header: {
                        HStack {
                            Text(L10n.lookup(group.title))
                            Spacer()
                            Text(String(kinds.count))
                        }
                    }
                }
            }
        }
        .settingsGroupedPageStyle()
        .navigationTitle(L10n.lookup("选择搜索服务"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L10n.lookup("搜索名称或用途"))
        .overlay {
            if !SearchServiceKind.allCases.contains(where: matches) {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private func searchServiceIcon(for kind: SearchServiceKind) -> String {
    let key = String(describing: kind).lowercased()
    if key.contains("bing") { return "magnifyingglass" }
    if key.contains("duck") { return "bird" }
    if key.contains("sear") { return "server.rack" }
    if key.contains("grok") { return "xmark" }
    if key.contains("ollama") { return "desktopcomputer" }
    if key.contains("querit") { return "line.3.horizontal.decrease.circle" }
    return "globe"
}

@MainActor private func searchServiceResponseError(_ response: String) -> String? {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return L10n.lookup("服务返回了空响应。") }
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
    else {
        return nil
    }
    if let error = dictionary["error"] as? String, !error.isEmpty {
        return error
    }
    return nil
}
