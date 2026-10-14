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
    @State private var selectedDetent: PresentationDetent = .height(357)
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
        .primary
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
        case .root: 328
        case .more: 282
        case .instruction, .worldBook: 210
        case .contextManagement: 248
        case .groupChat: 460
        }
        let height = max(180, (contentHeights[route] ?? initialHeight) + 29)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var model: BottomToolsModel
    let onSearchSettings: () -> Void
    let onWorldBookSettings: () -> Void
    let onAction: (BottomToolAction) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    quickAction(.camera, systemName: "camera", title: L10n.lookup("拍照"))
                    quickAction(.photos, systemName: "photo", title: L10n.lookup("照片"))
                    quickAction(.uploadFile, systemName: "paperclip", title: L10n.lookup("上传文件"))
                }
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 10))
                    : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    searchCard
                    worldBookCard
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.lookup("思维链强度"), systemImage: "brain.head.profile")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        if let budget = appModel.currentAssistant.thinkingBudget,
                           budget > 0, !ThinkingBudgetControl.budgets.contains(budget) {
                            Text("\(budget) tokens").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ThinkingBudgetSelector(
                        budget: appModel.currentAssistant.thinkingBudget ?? 0,
                        onCommit: { value in
                            guard value != (appModel.currentAssistant.thinkingBudget ?? 0) else { return }
                            var assistant = appModel.currentAssistant
                            assistant.thinkingBudget = value == 0 ? nil : value
                            appModel.updateAssistant(assistant)
                        }
                    )
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 104 : 48)
                }
                .padding(12)
                .background(ToolsCardBackground())

                Button { model.open(.more) } label: {
                    ToolDetailRowLabel(
                        systemName: "ellipsis.circle", title: L10n.lookup("更多工具"),
                        subtitle: L10n.lookup("MCP · 指令 · 上下文"), showsDisclosure: true
                    )
                }
                .buttonStyle(.plain)
                .background(ToolsCardBackground())
                .accessibilityIdentifier("tools.more")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .toolsContentHeight(.root)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var searchCard: some View {
        featureLabel(systemName: "globe", title: L10n.lookup("联网搜索"),
                     subtitle: searchStatus, isChecked: appModel.currentAssistant.searchEnabled)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .highPriorityGesture(featureGesture(tap: toggleSearch, longPress: {
                appModel.performCardHaptic()
                onSearchSettings()
            }))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L10n.lookup("联网搜索"))
            .accessibilityValue(searchStatus)
            .accessibilityHint(L10n.lookup("轻点切换，长按打开设置"))
            .accessibilityAction { toggleSearch() }
            .accessibilityAction(named: Text(L10n.lookup("打开搜索设置"))) { onSearchSettings() }
            .accessibilityIdentifier("tools.search")
    }

    private var worldBookCard: some View {
        featureLabel(systemName: "book", title: L10n.lookup("世界书"),
                     subtitle: worldBookStatus, isChecked: false, showsDisclosure: true)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .highPriorityGesture(featureGesture(tap: { model.open(.worldBook) }, longPress: {
                appModel.performCardHaptic()
                onWorldBookSettings()
            }))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L10n.lookup("世界书"))
            .accessibilityValue(worldBookStatus)
            .accessibilityHint(L10n.lookup("轻点选择世界书，长按打开设置"))
            .accessibilityAction { model.open(.worldBook) }
            .accessibilityAction(named: Text(L10n.lookup("打开世界书设置"))) { onWorldBookSettings() }
            .accessibilityIdentifier("tools.world")
    }

    private func featureGesture(tap: @escaping () -> Void, longPress: @escaping () -> Void) -> some Gesture {
        LongPressGesture(minimumDuration: 0.42, maximumDistance: 24)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first(true): longPress()
                case .second: tap()
                default: break
                }
            }
    }

    private func featureLabel(systemName: String, title: String, subtitle: String,
                              isChecked: Bool, showsDisclosure: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName).font(.system(size: 20, weight: .regular)).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: showsDisclosure ? "chevron.right" : "checkmark")
                .font(.system(size: showsDisclosure ? 11 : 13, weight: .medium))
                .foregroundStyle(showsDisclosure ? .secondary : .primary)
                .opacity(showsDisclosure || isChecked ? 1 : 0)
        }
        .foregroundStyle(.primary)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity, alignment: .leading)
        .background(ToolsCardBackground())
    }

    private func quickAction(_ action: BottomToolAction, systemName: String, title: String) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 6) {
                Image(systemName: systemName).font(.system(size: 21, weight: .regular))
                Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(ToolsCardBackground())
        }
        .buttonStyle(.plain)
    }

    private var searchStatus: String {
        let state = appModel.currentAssistant.searchEnabled ? L10n.lookup("开启") : L10n.lookup("关闭")
        let turns = appModel.preferences.searchToolResultRetentionTurns
        let retention = turns < 0 ? L10n.lookup("永久保留")
            : turns == 0 ? L10n.lookup("仅当前回复") : L10n.format("保留 %@ 轮", [String(turns)])
        return "\(state) · \(retention)"
    }

    private var worldBookStatus: String {
        let books = appModel.bottomToolWorldBooks
        let count = books.filter { $0.enabled && $0.selected }.count
        if count > 0 { return L10n.format("已启用 %@ 项", [String(count)]) }
        return books.contains { $0.selected } ? L10n.lookup("关闭") : L10n.lookup("未选择")
    }

    private func toggleSearch() {
        var assistant = appModel.currentAssistant
        assistant.searchEnabled.toggle()
        appModel.updateAssistant(assistant)
    }
}

private struct ToolsCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        if colorScheme == .dark {
            return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.58)
        }
        // Match the model picker's unselected cards: a faint tint over the sheet glass.
        return Color.primary.opacity(0.035)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5)
            }
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

/// UIKit owns the touch sequence, including cancellation by the sheet's pan.
/// Scrubbing changes only the local highlight; persistence happens once on lift.
private struct ThinkingBudgetSelector: UIViewRepresentable {
    let budget: Int
    let onCommit: (Int) -> Void

    func makeUIView(context: Context) -> ThinkingBudgetControl { ThinkingBudgetControl() }
    func updateUIView(_ view: ThinkingBudgetControl, context: Context) {
        view.onCommit = onCommit
        let category: UIContentSizeCategory = switch context.environment.dynamicTypeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
        view.configure(budget: budget, contentSize: category)
    }
}

private final class ThinkingBudgetControl: UIControl {
    static let budgets = [0, -1, 1_024, 4_096, 8_192, 16_384]
    private var titles: [String] { ["关闭", "自动", "低", "中", "高", "极高"].map(L10n.lookup) }
    private let highlight = UIView()
    private var labels: [UILabel] = []
    private var committedBudget = 0
    private var contentSize: UIContentSizeCategory = .large
    private var previewIndex: Int?
    private let feedback = UISelectionFeedbackGenerator()
    var onCommit: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.08, alpha: 0.52) : UIColor(white: 0, alpha: 0.035) }
        highlight.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.25, alpha: 1) : UIColor(white: 0, alpha: 0.08) }
        highlight.layer.cornerRadius = 10
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        for _ in Self.budgets {
            let label = UILabel()
            label.textAlignment = .center
            label.numberOfLines = 2
            label.isUserInteractionEnabled = false
            addSubview(label)
            labels.append(label)
        }
        isAccessibilityElement = true
        accessibilityIdentifier = "tools.reasoning"
        accessibilityTraits = .adjustable
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(budget: Int, contentSize: UIContentSizeCategory) {
        committedBudget = budget < 0 ? -1 : budget
        self.contentSize = contentSize
        accessibilityLabel = L10n.lookup("思维链强度")
        for (index, label) in labels.enumerated() {
            label.text = titles[index]
            label.font = UIFontMetrics(forTextStyle: .caption1)
                .scaledFont(for: .systemFont(ofSize: 13, weight: .medium), maximumPointSize: 20,
                            compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSize))
        }
        updateHighlight()
    }

    private var columns: Int { contentSize.isAccessibilityCategory ? 3 : 6 }
    private var rows: Int { 6 / columns }
    private var displayedIndex: Int? { previewIndex ?? Self.budgets.firstIndex(of: committedBudget) }

    private func segmentFrame(_ index: Int) -> CGRect {
        let column = effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? columns - 1 - index % columns : index % columns
        let width = max(0, bounds.width - 8) / CGFloat(columns)
        let height = max(0, bounds.height - 8) / CGFloat(rows)
        return CGRect(x: 4 + CGFloat(column) * width, y: 4 + CGFloat(index / columns) * height,
                      width: width, height: height).insetBy(dx: 1.5, dy: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, label) in labels.enumerated() { label.frame = segmentFrame(index) }
        highlight.isHidden = displayedIndex == nil
        if let index = displayedIndex { highlight.frame = segmentFrame(index) }
    }

    private func index(at point: CGPoint) -> Int {
        let width = max(1, bounds.width - 8) / CGFloat(columns)
        let height = max(1, bounds.height - 8) / CGFloat(rows)
        let visualColumn = min(columns - 1, max(0, Int(floor((point.x - 4) / width))))
        let column = effectiveUserInterfaceLayoutDirection == .rightToLeft ? columns - 1 - visualColumn : visualColumn
        let row = min(rows - 1, max(0, Int(floor((point.y - 4) / height))))
        return row * columns + column
    }

    private func updateHighlight() {
        for (index, label) in labels.enumerated() {
            label.textColor = index == displayedIndex ? .label : .secondaryLabel
        }
        accessibilityValue = displayedIndex.map { titles[$0] } ?? "\(committedBudget) tokens"
        setNeedsLayout()
    }

    private func preview(_ touch: UITouch) {
        let index = index(at: touch.location(in: self))
        if index != previewIndex {
            previewIndex = index
            feedback.selectionChanged()
            updateHighlight()
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        feedback.prepare()
        preview(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        preview(touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { preview(touch) }
        if let index = previewIndex { commit(index) }
        previewIndex = nil
        updateHighlight()
    }

    override func cancelTracking(with event: UIEvent?) {
        previewIndex = nil
        updateHighlight()
    }

    private func commit(_ index: Int) {
        let value = Self.budgets[index]
        guard value != committedBudget else { return }
        committedBudget = value
        onCommit?(value)
    }

    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
    private func adjust(_ offset: Int) {
        commit(min(5, max(0, (Self.budgets.firstIndex(of: committedBudget) ?? 0) + offset)))
        feedback.selectionChanged()
        updateHighlight()
    }
}

private struct MoreToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var model: BottomToolsModel
    let onMCP: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ToolsSheetHeader(title: L10n.lookup("更多工具"), back: model.back, titleWeight: .semibold)

            ScrollView {
                VStack(spacing: 0) {
                    Button(action: onMCP) {
                        ToolDetailRowLabel(
                            systemName: "hammer",
                            title: L10n.lookup("MCP 服务器"),
                            subtitle: appModel.currentAssistantMCPStatusText,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tools.mcp")

                    Divider().padding(.leading, 48)

                    navigationRow(
                        systemName: "square.3.layers.3d",
                        title: L10n.lookup("指令注入"),
                        subtitle: selectionStatus(appModel.bottomToolInstructions.filter(\.selected).count),
                        route: .instruction
                    )
                    Divider().padding(.leading, 48)
                    navigationRow(
                        systemName: "point.3.connected.trianglepath.dotted",
                        title: L10n.lookup("上下文管理"),
                        subtitle: L10n.lookup("压缩或清除当前上下文"),
                        route: .contextManagement
                    )
                }
                .background(ToolsCardBackground())
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
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
            ToolDetailRowLabel(
                systemName: systemName,
                title: title,
                subtitle: subtitle,
                showsDisclosure: true
            )
        }
        .buttonStyle(.plain)
    }

    private func selectionStatus(_ count: Int) -> String {
        count == 0 ? L10n.lookup("未选择") : L10n.format("已启用 %@ 项", [String(describing: count)])
    }
}

private struct ToolDetailRowLabel: View {
    let systemName: String
    let title: String
    let subtitle: String?
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.70))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}

private struct ToolsSheetHeader: View {
    let title: String
    let back: () -> Void
    var titleWeight: Font.Weight = .medium

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
                    .padding(.bottom, 6)
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
                    .padding(.bottom, 6)
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
            .padding(.bottom, 6)
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
            .background(ToolsCardBackground())
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
                    .font(.body.weight(.medium))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
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
        .padding(.vertical, 10)
        .frame(minHeight: subtitle.isEmpty ? 56 : 66)
        .background(
            selected ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
    .buttonStyle(.plain)
}
