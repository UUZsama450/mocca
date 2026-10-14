import Observation
import SwiftUI
import UIKit

enum BottomToolAction: Hashable, Sendable {
    case camera
    case photos
    case uploadFile
    case saveGroupChat([UUID], editing: Bool)
    case compressContext
    case clearContext
}

enum ContextManagementOperation: Equatable {
    case compress
    case clear
    case restore

    @MainActor var title: String {
        switch self {
        case .compress: L10n.lookup("压缩上下文")
        case .clear: L10n.lookup("清除上下文")
        case .restore: L10n.lookup("恢复上下文")
        }
    }

    @MainActor var confirmationMessage: String {
        switch self {
        case .compress:
            L10n.lookup("将调用模型总结当前有效对话，后续回复使用摘要代替这部分历史消息。原聊天记录会保留。")
        case .clear:
            L10n.lookup("将在当前位置设置上下文分界点，后续回复不再携带此前的聊天消息。聊天记录、助手记忆和已有摘要会保留。")
        case .restore:
            L10n.lookup("后续回复将可再次参考此前的聊天消息。")
        }
    }
}

enum BottomToolsRoute: Hashable {
    case root
    case more
    case instruction
    case worldBook
    case groupChat
    case contextManagement
}

struct InstructionToolItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var group: String
    var selected: Bool
}

struct WorldBookToolItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var detail: String
    var enabled: Bool
    var selected: Bool
}

@MainActor
private final class BottomToolsRefreshDisplayLinkTarget: NSObject {
    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {}
}

/// Diagnostic 5033: request a faster cadence only around internal navigation.
/// This owns no animation values and makes no per-frame SwiftUI state changes.
@MainActor
private final class BottomToolsTransitionRefreshLease {
    private var isEnabled = false
    private var displayLinkTarget: BottomToolsRefreshDisplayLinkTarget?
    private var displayLink: CADisplayLink?
    private var releaseTask: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { stop() }
    }

    func begin() {
        guard isEnabled, UIScreen.main.maximumFramesPerSecond >= 120 else { return }

        let link: CADisplayLink
        if let existing = displayLink {
            link = existing
        } else {
            let target = BottomToolsRefreshDisplayLinkTarget()
            link = CADisplayLink(
                target: target,
                selector: #selector(BottomToolsRefreshDisplayLinkTarget.displayLinkDidFire(_:))
            )
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 80, maximum: 120, preferred: 120
            )
            displayLinkTarget = target
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        releaseTask?.cancel()
        // Covers the existing 0.30/0.28 s transition with a short release margin.
        // The captured link also expires if its owner disappears unexpectedly.
        releaseTask = Task { @MainActor [weak self, link] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            link.invalidate()
            guard let self, self.displayLink === link else { return }
            self.displayLink = nil
            self.displayLinkTarget = nil
            self.releaseTask = nil
        }
    }

    func stop() {
        releaseTask?.cancel()
        releaseTask = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }
}

@MainActor
@Observable
final class BottomToolsModel {
    @ObservationIgnored private let transitionRefresh = BottomToolsTransitionRefreshLease()
    var route: BottomToolsRoute = .root
    var selectedAssistantIDs = Set<UUID>()
    var isEditingGroupChat = false
    var lastAction: BottomToolAction?

    func reset() {
        transitionRefresh.setEnabled(false)
        route = .root
        isEditingGroupChat = false
        lastAction = nil
    }

    func setTransitionRefreshEnabled(_ enabled: Bool) {
        transitionRefresh.setEnabled(enabled)
    }

    func stopTransitionRefresh() {
        transitionRefresh.stop()
    }

    func open(_ route: BottomToolsRoute) {
        haptic()
        if self.route != route { transitionRefresh.begin() }
        withAnimation(.easeInOut(duration: 0.30)) {
            self.route = route
        }
    }

    func back() {
        haptic()
        if route != .root { transitionRefresh.begin() }
        withAnimation(.easeInOut(duration: 0.28)) {
            switch route {
            case .instruction, .contextManagement:
                route = .more
            case .worldBook:
                route = .root
            case .more, .groupChat:
                route = .root
            case .root:
                break
            }
        }
    }

    func trigger(_ action: BottomToolAction) {
        haptic()
        lastAction = action
    }

    func performSelectionHaptic() {
        haptic()
    }

    func toggleAssistant(_ id: UUID) {
        haptic()
        if selectedAssistantIDs.contains(id) {
            selectedAssistantIDs.remove(id)
        } else {
            selectedAssistantIDs.insert(id)
        }
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

struct BottomToolsSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: BottomToolsModel
    let onInstructionToggle: (UUID) -> Void
    let onWorldBookToggle: (UUID) -> Void
    let onAction: (BottomToolAction) -> Void
    let isAttachmentHandoffActive: Bool

    @State private var isToolsSheetVisible = false
    @State private var contentHeights: [BottomToolsRoute: CGFloat] = [:]
    @State private var selectedDetent: PresentationDetent = .height(355)
    @State private var isMCPSelectionPresented = false
    @State private var isSearchSettingsPresented = false
    @State private var isWorldBookSettingsPresented = false
    @State private var isContextManagementConfirmationPresented = false

    private let detailDetent = PresentationDetent.fraction(0.82)
    private let attachmentHandoffDetent = PresentationDetent.height(1)

    private var themeAction: Color {
        Color(uiColor: appModel.themeActionUIColor)
    }

    private var selectionCheckmarkColor: Color {
        appModel.preferences.themePaletteID == .defaultPalette
            ? Color(uiColor: .systemBlue)
            : Color.primary.opacity(0.72)
    }

    private var allowsTransitionRefresh: Bool {
        isToolsSheetVisible
            && appModel.isBottomToolsPresented
            && scenePhase == .active
            && !isAttachmentHandoffActive
            && !isMCPSelectionPresented
            && !isSearchSettingsPresented
            && !isWorldBookSettingsPresented
            && !isContextManagementConfirmationPresented
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.44))
                .frame(width: 50, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 12)

            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    navigationPage(at: 0, size: proxy.size) {
                        BottomToolsRootView(
                            model: model,
                            onSearchSettings: { isSearchSettingsPresented = true },
                            onWorldBookSettings: { isWorldBookSettingsPresented = true },
                            onAction: handleAction
                        )
                    }

                    navigationPage(at: 1, size: proxy.size) { firstLevelView }
                    navigationPage(at: 2, size: proxy.size) { secondLevelView }
                }
                .clipped()
                .animation(.easeInOut(duration: 0.30), value: model.route)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(themeAction)
        .accentColor(themeAction)
        .presentationDetents(presentationDetents, selection: $selectedDetent)
        // Once a system picker covers the tools, the parent sheet rests at the
        // one-point handoff detent. Make only that detent background-interactive
        // so its presentation backdrop is removed before the picker closes;
        // the normal compact/detail sheet keeps the existing modal dimming.
        .presentationBackgroundInteraction(
            .enabled(upThrough: attachmentHandoffDetent)
        )
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
        .allowsHitTesting(!isAttachmentHandoffActive)
        .onAppear {
            isToolsSheetVisible = true
            selectedDetent = preferredDetent(for: model.route)
            model.setTransitionRefreshEnabled(allowsTransitionRefresh)
        }
        .onChange(of: allowsTransitionRefresh) { _, allowed in
            model.setTransitionRefreshEnabled(allowed)
        }
        .onChange(of: isAttachmentHandoffActive) { _, isActive in
            withAnimation(.easeInOut(duration: 0.24)) {
                selectedDetent = isActive
                    ? attachmentHandoffDetent
                    : preferredDetent(for: model.route)
            }
        }
        .onChange(of: model.route) {
            withAnimation(.easeInOut(duration: 0.26)) {
                selectedDetent = preferredDetent(for: model.route)
            }
        }
        .onPreferenceChange(ToolsContentHeightPreference.self) { heights in
            let previous = preferredDetent(for: model.route)
            var updated = contentHeights
            for (route, height) in heights where height.isFinite && height > 0 {
                if abs((updated[route] ?? 0) - height) > 1 { updated[route] = ceil(height) }
            }
            guard updated != contentHeights else { return }
            contentHeights = updated
            // Keep a user's manually expanded sheet expanded. Only its compact
            // resting height follows measured content, including live edits.
            if selectedDetent == previous, !isAttachmentHandoffActive {
                withAnimation(.easeInOut(duration: 0.26)) {
                    selectedDetent = preferredDetent(for: model.route)
                }
            }
        }
        .onChange(of: appModel.selectedConversationID) {
            appModel.cancelContextManagementConfirmation()
        }
        .onChange(of: appModel.pendingContextManagementConfirmation?.id, initial: true) {
            isContextManagementConfirmationPresented = appModel.pendingContextManagementConfirmation != nil
        }
        .onDisappear {
            isToolsSheetVisible = false
            model.setTransitionRefreshEnabled(false)
            appModel.cancelContextManagementConfirmation()
        }
        .alert(
            appModel.pendingContextManagementConfirmation?.operation.title ?? L10n.lookup("上下文管理"),
            // Alert dismissal may update presentation before its button runs.
            // Only the explicit decision or sheet lifecycle consumes the token.
            isPresented: $isContextManagementConfirmationPresented,
            presenting: appModel.pendingContextManagementConfirmation
        ) { confirmation in
            Button(L10n.lookup("取消"), role: .cancel) {
                appModel.resolveContextManagementConfirmation(confirmation, confirmed: false)
            }
            Button(confirmation.operation.title) {
                appModel.resolveContextManagementConfirmation(confirmation, confirmed: true)
            }
        } message: { confirmation in
            Text(confirmation.operation.confirmationMessage)
        }
        .sheet(isPresented: $isMCPSelectionPresented) {
            MCPServerSelectionView(assistantID: appModel.currentAssistantID)
        }
        .sheet(isPresented: $isSearchSettingsPresented) {
            NavigationStack {
                SearchServiceSettingsView()
            }
        }
        .sheet(isPresented: $isWorldBookSettingsPresented) {
            NavigationStack {
                WorldBookPage()
            }
        }
    }

    private var navigationDepth: Int {
        switch model.route {
        case .root: 0
        case .more, .worldBook, .groupChat: 1
        case .instruction, .contextManagement: 2
        }
    }

    private func navigationPage<Content: View>(
        at depth: Int, size: CGSize, @ViewBuilder content: () -> Content
    ) -> some View {
        let position = depth == navigationDepth ? 0 : (depth < navigationDepth ? -1 : 1)
        return content()
            .frame(width: size.width, height: size.height, alignment: .top)
            .offset(x: CGFloat(position) * size.width)
            .opacity(position == 0 ? 1 : (position < 0 ? 0 : 0.35))
            .allowsHitTesting(position == 0)
            .accessibilityHidden(position != 0)
    }

    @ViewBuilder
    private var firstLevelView: some View {
        switch model.route {
        case .root:
            Color.clear
        case .more, .instruction, .contextManagement:
            // Keep the parent in the same structural branch for both children.
            MoreToolsView(
                model: model,
                onMCP: { isMCPSelectionPresented = true }
            )
        case .worldBook:
            WorldBookToolsView(
                model: model,
                selectedMarkColor: selectionCheckmarkColor,
                onToggle: onWorldBookToggle
            )
        case .groupChat:
            GroupChatToolsView(model: model, onAction: handleAction)
        }
    }

    @ViewBuilder
    private var secondLevelView: some View {
        switch model.route {
        case .instruction:
            InstructionToolsView(
                model: model,
                selectedMarkColor: selectionCheckmarkColor,
                onToggle: onInstructionToggle
            )
        case .contextManagement:
            ContextToolsView(model: model, onAction: handleAction)
        default:
            Color.clear
        }
    }

    private func handleAction(_ action: BottomToolAction) {
        // Stop before presentation callbacks: attachment handoff state is
        // published on the next turn, after a native picker can already open.
        model.stopTransitionRefresh()
        model.trigger(action)
        onAction(action)
    }

    private func preferredDetent(for route: BottomToolsRoute) -> PresentationDetent {
        let initialHeight: CGFloat = switch route {
        case .root: 326
        case .more: 238
        case .instruction, .worldBook: 206
        case .contextManagement: 246
        case .groupChat: 460
        }
        let height = max(120, (contentHeights[route] ?? initialHeight) + 29)
        return height > UIScreen.main.bounds.height * 0.70 ? detailDetent : .height(height)
    }

    private var availableDetents: Set<PresentationDetent> {
        // Keep the current detent available for the route-change frame so SwiftUI
        // can animate directly to the next route's preferred height without an
        // invalid-selection jump. Once the selection settles, the obsolete compact
        // height disappears and cannot be dragged to from the new route.
        [preferredDetent(for: model.route), selectedDetent, detailDetent]
    }

    private var presentationDetents: Set<PresentationDetent> {
        guard isAttachmentHandoffActive else { return availableDetents }
        // Keep the current detent available for the handoff frame, then let
        // the selection animate to a one-point resting detent behind the
        // system picker. The parent presenter stays alive, so the picker keeps
        // the direct, fast presentation path without flashing the restored
        // full-height tools sheet when it closes.
        return [attachmentHandoffDetent, selectedDetent]
    }
}

private struct BottomToolsRootView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let onSearchSettings: () -> Void
    let onWorldBookSettings: () -> Void
    let onAction: (BottomToolAction) -> Void

    private var themeAccent: Color {
        Color(uiColor: appModel.themeActionUIColor)
    }

    private var reasoningEnabled: Bool {
        (appModel.currentAssistant.thinkingBudget ?? 0) != 0
    }

    private var reasoningStatus: String {
        guard let budget = appModel.currentAssistant.thinkingBudget, budget != 0 else { return L10n.lookup("关闭") }
        switch budget {
        case ..<0: return L10n.lookup("自动")
        case 1_024: return L10n.lookup("低")
        case 4_096: return L10n.lookup("中")
        case 8_192: return L10n.lookup("高")
        case 16_384: return L10n.lookup("极高")
        default: return "\(budget) tokens"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    quickAction(.camera, systemName: "camera", title: L10n.lookup("拍照"))
                    quickAction(.photos, systemName: "photo", title: L10n.lookup("照片"))
                    quickAction(.uploadFile, systemName: "paperclip", title: L10n.lookup("上传文件"))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        Button {
                            appModel.performCardHaptic()
                            onSearchSettings()
                        } label: {
                            CompactToolRowLabel(
                                systemName: "globe", title: L10n.lookup("联网搜索"),
                                subtitle: searchRetentionLabel(appModel.preferences.searchToolResultRetentionTurns),
                                isChecked: appModel.currentAssistant.searchEnabled,
                                showsCheckmark: false, accent: themeAccent
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("联网搜索"))
                        .accessibilityValue(searchStatus)
                        .accessibilityHint(L10n.lookup("打开搜索设置"))
                        .accessibilityIdentifier("tools.search")
                        Toggle(L10n.lookup("联网搜索"), isOn: Binding(
                            get: { appModel.currentAssistant.searchEnabled },
                            set: { enabled in
                                guard enabled != appModel.currentAssistant.searchEnabled else { return }
                                toggleSearch()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .green))
                        .accessibilityIdentifier("tools.search.toggle")
                        .padding(.trailing, 15)
                    }

                    CompactToolRowLabel(
                        systemName: "book",
                        title: L10n.lookup("世界书"),
                        subtitle: worldBookStatus,
                        isChecked: worldBookEnabled,
                        showsCheckmark: false,
                        accent: themeAccent
                    )
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.42, maximumDistance: 24)
                            .exclusively(before: TapGesture())
                            .onEnded { value in
                                switch value {
                                case .first(true):
                                    appModel.performCardHaptic()
                                    onWorldBookSettings()
                                case .second: model.open(.worldBook)
                                default: break
                                }
                            }
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(L10n.lookup("世界书"))
                    .accessibilityValue(worldBookStatus)
                    .accessibilityIdentifier("tools.world")
                    .accessibilityHint(L10n.lookup("轻点选择世界书，长按打开设置"))
                    .accessibilityAction { model.open(.worldBook) }
                    .accessibilityAction(named: Text(L10n.lookup("打开世界书设置"))) {
                        onWorldBookSettings()
                    }

                    Menu {
                        Picker(L10n.lookup("思维链强度"), selection: thinkingBudgetSelection) {
                            Label(L10n.lookup("自动"), systemImage: "wand.and.stars").tag(-1)
                            Label(L10n.lookup("关闭"), systemImage: "pause.circle").tag(0)
                            Label(L10n.lookup("低"), systemImage: "gauge.low").tag(1_024)
                            Label(L10n.lookup("中"), systemImage: "gauge.medium").tag(4_096)
                            Label(L10n.lookup("高"), systemImage: "gauge.high").tag(8_192)
                            Label(L10n.lookup("极高"), systemImage: "bolt.fill").tag(16_384)
                        }
                    } label: {
                        CompactToolRowLabel(
                            systemName: "brain.head.profile",
                            title: L10n.lookup("思维链强度"),
                            subtitle: reasoningStatus,
                            isChecked: reasoningEnabled,
                            showsCheckmark: false,
                            accent: themeAccent
                        )
                    }
                    .buttonStyle(.plain)
                    .menuOrder(.fixed)
                    .accessibilityLabel(L10n.lookup("思维链强度"))
                    .accessibilityValue(reasoningStatus)
                    .accessibilityIdentifier("tools.reasoning")

                    navigationRow(
                        systemName: "ellipsis.circle",
                        title: L10n.lookup("更多工具"),
                        subtitle: L10n.lookup("MCP · 指令 · 上下文"),
                        route: .more
                    )
                    .accessibilityIdentifier("tools.more")
                }
                .padding(.horizontal, 10)
            }
            .toolsContentHeight(.root)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func quickAction(
        _ action: BottomToolAction,
        systemName: String,
        title: String
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 27, weight: .medium))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(ToolQuickActionBackground())
        }
        .buttonStyle(.plain)
    }

    private func navigationRow(
        systemName: String,
        title: String,
        subtitle: String? = nil,
        route: BottomToolsRoute
    ) -> some View {
        Button {
            model.open(route)
        } label: {
            CompactToolRowLabel(
                systemName: systemName,
                title: title,
                subtitle: subtitle,
                showsDisclosure: true,
                disclosureFont: .system(size: 13, weight: .regular),
                accent: themeAccent
            )
        }
        .buttonStyle(.plain)
    }

    private var thinkingBudgetSelection: Binding<Int> {
        Binding(
            get: { appModel.currentAssistant.thinkingBudget ?? 0 },
            set: { value in
                var assistant = appModel.currentAssistant
                assistant.thinkingBudget = value == 0 ? nil : value
                appModel.updateAssistant(assistant)
            }
        )
    }

    private var searchStatus: String {
        let state = appModel.currentAssistant.searchEnabled ? L10n.lookup("开启") : L10n.lookup("关闭")
        return "\(state) · \(searchRetentionLabel(appModel.preferences.searchToolResultRetentionTurns))"
    }

    private var worldBookStatus: String {
        let books = appModel.bottomToolWorldBooks
        let count = books.filter { $0.enabled && $0.selected }.count
        if count > 0 { return L10n.format("已启用 %@ 项", [String(describing: count)]) }
        return books.contains { $0.selected } ? L10n.lookup("关闭") : L10n.lookup("未选择")
    }

    private var worldBookEnabled: Bool {
        appModel.bottomToolWorldBooks.contains { $0.enabled && $0.selected }
    }

    private func searchRetentionLabel(_ value: Int) -> String {
        if value < 0 { return L10n.lookup("永久保留") }
        if value == 0 { return L10n.lookup("仅当前回复") }
        return L10n.format("保留 %@ 轮", [String(describing: value)])
    }

    private func toggleSearch() {
        var assistant = appModel.currentAssistant
        assistant.searchEnabled.toggle()
        appModel.updateAssistant(assistant)
    }
}

private struct ToolsContentHeightPreference: PreferenceKey {
    static var defaultValue: [BottomToolsRoute: CGFloat] { [:] }
    static func reduce(value: inout [BottomToolsRoute: CGFloat], nextValue: () -> [BottomToolsRoute: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private extension View {
    func toolsContentHeight(_ route: BottomToolsRoute, headerHeight: CGFloat = 0) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: ToolsContentHeightPreference.self,
                                       value: [route: proxy.size.height + headerHeight])
            }
            .allowsHitTesting(false)
        }
    }
}

/// A light web symbol: one meridian ellipse and one equator inside the globe.
private struct ToolsSearchGlobe: Shape {
    func path(in rect: CGRect) -> Path {
        let diameter = min(rect.width, rect.height)
        let globe = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                           width: diameter, height: diameter).insetBy(dx: 0.8, dy: 0.8)
        var path = Path()
        path.addEllipse(in: globe)
        path.addEllipse(in: globe.insetBy(dx: globe.width * 0.28, dy: 0))
        path.move(to: CGPoint(x: globe.minX, y: globe.midY))
        path.addLine(to: CGPoint(x: globe.maxX, y: globe.midY))
        return path
    }
}

private struct MoreToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let onMCP: () -> Void

    private var themeAccent: Color {
        Color(uiColor: appModel.themeAccentUIColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolsSheetHeader(title: L10n.lookup("更多工具"), back: model.back, titleWeight: .semibold)

            ScrollView {
                VStack(spacing: 2) {
                    Button(action: onMCP) {
                        CompactToolRowLabel(
                            systemName: "hammer",
                            title: L10n.lookup("MCP 服务器"),
                            subtitle: appModel.currentAssistantMCPStatusText,
                            isChecked: !appModel.currentAssistant.mcpServerIDs.isEmpty,
                            showsDisclosure: true,
                            accent: themeAccent
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tools.mcp")

                    navigationRow(
                        systemName: "square.3.layers.3d",
                        title: L10n.lookup("指令注入"),
                        subtitle: selectionStatus(appModel.bottomToolInstructions.filter(\.selected).count),
                        route: .instruction
                    )
                    navigationRow(
                        systemName: "point.3.connected.trianglepath.dotted",
                        title: L10n.lookup("上下文管理"),
                        subtitle: L10n.lookup("压缩或清除当前上下文"),
                        route: .contextManagement
                    )
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .toolsContentHeight(.more, headerHeight: 62)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func navigationRow(
        systemName: String,
        title: String,
        subtitle: String,
        route: BottomToolsRoute
    ) -> some View {
        Button {
            model.open(route)
        } label: {
            CompactToolRowLabel(
                systemName: systemName,
                title: title,
                subtitle: subtitle,
                showsDisclosure: true,
                accent: themeAccent
            )
        }
        .buttonStyle(.plain)
    }

    private func selectionStatus(_ count: Int) -> String {
        count == 0 ? L10n.lookup("未选择") : L10n.format("已启用 %@ 项", [String(describing: count)])
    }
}

private struct CompactToolRowLabel: View {
    let systemName: String
    let title: String
    let subtitle: String?
    var isChecked = false
    var showsCheckmark = true
    var showsDisclosure = false
    var showsMenuIndicator = false
    var disclosureFont: Font = .system(size: 17, weight: .semibold)
    let accent: Color

    var body: some View {
        HStack(spacing: 15) {
            Group {
                if systemName == "globe" {
                    ToolsSearchGlobe()
                        .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 22, weight: .medium))
                }
            }
                .foregroundStyle(isChecked ? accent : Color.primary)
                .frame(width: 31)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            if showsMenuIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.70))
            }
            if isChecked && showsCheckmark {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }
            if !showsMenuIndicator && showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(disclosureFont)
                    .foregroundStyle(.secondary.opacity(0.70))
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 56)
        .contentShape(Rectangle())
    }
}

private struct ToolsSheetHeader: View {
    let title: String
    let back: () -> Void
    var titleWeight: Font.Weight = .bold

    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.lookup("返回"))
            .accessibilityIdentifier("tools.back")

            Spacer()
            Text(title)
                .font(.system(size: 20, weight: titleWeight))
                .lineLimit(1)
            Spacer()
            Color.clear.frame(width: 48, height: 48)
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
    }
}

private struct InstructionToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let selectedMarkColor: Color
    let onToggle: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ToolsSheetHeader(title: L10n.lookup("指令注入"), back: model.back)
            if appModel.bottomToolInstructions.isEmpty {
                Text(L10n.lookup("暂无指令注入卡片"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .toolsContentHeight(.instruction, headerHeight: 62)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appModel.bottomToolInstructions) { item in
                            selectionRow(
                                systemName: "square.3.layers.3d",
                                title: item.title,
                                subtitle: item.group,
                                selected: item.selected,
                                selectedMarkColor: selectedMarkColor
                            ) {
                                model.performSelectionHaptic()
                                onToggle(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .toolsContentHeight(.instruction, headerHeight: 62)
                }
            }
        }
    }
}

private struct WorldBookToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let selectedMarkColor: Color
    let onToggle: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ToolsSheetHeader(title: L10n.lookup("世界书"), back: model.back)
            if appModel.bottomToolWorldBooks.isEmpty {
                Text(L10n.lookup("暂无世界书"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .toolsContentHeight(.worldBook, headerHeight: 62)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appModel.bottomToolWorldBooks) { item in
                            selectionRow(
                                systemName: "book",
                                title: item.name,
                                subtitle: item.detail,
                                selected: item.selected,
                                selectedMarkColor: selectedMarkColor
                            ) {
                                model.performSelectionHaptic()
                                onToggle(item.id)
                            }
                            .disabled(!item.enabled && !item.selected)
                            .opacity(item.enabled || item.selected ? 1 : 0.45)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .toolsContentHeight(.worldBook, headerHeight: 62)
                }
            }
        }
    }
}

private struct GroupChatToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let onAction: (BottomToolAction) -> Void

    private var selectedAvailableAssistantIDs: [UUID] {
        appModel.assistants.compactMap {
            model.selectedAssistantIDs.contains($0.id) ? $0.id : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolsSheetHeader(title: L10n.lookup("选择助手"), back: model.back)
            Text(L10n.lookup("请为群聊选择至少两个助手"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(appModel.assistants) { assistant in
                        let selected = model.selectedAssistantIDs.contains(assistant.id)
                        Button {
                            model.toggleAssistant(assistant.id)
                        } label: {
                            HStack(spacing: 12) {
                                AssistantAvatarView(profile: assistant, size: 38)
                                Text(assistant.name)
                                    .font(.system(size: 17, weight: .medium))
                                Spacer()
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 23, weight: .medium))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 62)
                            .background(
                                selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .toolsContentHeight(.groupChat, headerHeight: 166)
            }

            Button {
                onAction(.saveGroupChat(selectedAvailableAssistantIDs, editing: model.isEditingGroupChat))
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(selectedAvailableAssistantIDs.count >= 2 ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        selectedAvailableAssistantIDs.count >= 2
                            ? Color.accentColor
                            : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedAvailableAssistantIDs.count < 2)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var buttonTitle: String {
        guard selectedAvailableAssistantIDs.count >= 2 else { return L10n.lookup("请至少选择两个助手") }
        return model.isEditingGroupChat ? L10n.lookup("更新群聊") : L10n.lookup("创建群聊")
    }
}

private struct ContextToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let onAction: (BottomToolAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ToolsSheetHeader(title: L10n.lookup("上下文管理"), back: model.back)
            VStack(spacing: 12) {
                contextRow(
                    systemName: "shippingbox",
                    title: L10n.lookup("压缩上下文"),
                    detail: L10n.lookup("总结当前聊天，减少后续上下文"),
                    action: { onAction(.compressContext) }
                )
                contextRow(
                    systemName: appModel.clearContextOperation == .restore ? "arrow.uturn.backward" : "eraser",
                    title: appModel.clearContextOperation.title,
                    detail: appModel.clearContextOperation == .restore ? L10n.lookup("重新使用此前的聊天消息") : L10n.lookup("标记上下文分界点"),
                    action: { onAction(.clearContext) }
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .toolsContentHeight(.contextManagement, headerHeight: 62)
            Spacer()
        }
    }

    private func contextRow(
        systemName: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 23, weight: .medium))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.65))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 80)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private func selectionRow(
    systemName: String,
    title: String,
    subtitle: String,
    selected: Bool,
    selectedMarkColor: Color,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 13) {
            Image(systemName: systemName)
                .font(.system(size: 21, weight: .medium))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selectedMarkColor)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: subtitle.isEmpty ? 56 : 66)
        .background(
            selected ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
    .buttonStyle(.plain)
}

private struct ToolQuickActionBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.primary.opacity(0.045))
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(Color.primary.opacity(0.055))
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.6))
        }
    }
}
