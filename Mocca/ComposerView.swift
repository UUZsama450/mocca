import SwiftUI
import UIKit

/// Read only while the drawer is deciding whether to claim a drag. The native
/// editor keeps its selection gestures, without publishing selection changes
/// through the chat or depending on UIKit's private handle view classes.
@MainActor
enum ComposerTextSelectionInteractionGate {
    private static weak var focusedResponder: UIResponder?

    /// Capture only our concrete editor. Keyboard animation readers must not
    /// inherit the curve of a search field or a text field in a sheet.
    static var focusedComposerInput: ComposerInputTextView? {
        focusedResponder = nil
        defer { focusedResponder = nil }
        UIApplication.shared.sendAction(
            #selector(UIResponder.moccaCaptureComposerSelectionResponder(_:)),
            to: nil, from: nil, for: nil
        )
        guard let input = focusedResponder as? ComposerInputTextView,
              input.isFirstResponder, input.window != nil else { return nil }
        return input
    }

    static var ownsCurrentTouch: Bool {
        focusedResponder = nil
        defer { focusedResponder = nil }
        UIApplication.shared.sendAction(
            #selector(UIResponder.moccaCaptureComposerSelectionResponder(_:)),
            to: nil, from: nil, for: nil
        )
        guard let view = focusedResponder as? UIView,
              view.isFirstResponder, view.window != nil,
              let input = view as? any UITextInput,
              let range = input.selectedTextRange else { return false }

        let geometryView = input.textInputView ?? view
        let rects = (input.selectionRects(for: range).map(\.rect) + [
            input.caretRect(for: range.start),
            input.caretRect(for: range.end)
        ]).filter { !$0.isNull && !$0.isInfinite && !$0.isEmpty }
            .map { $0.insetBy(dx: -24, dy: -24) }
        guard !rects.isEmpty else { return false }

        // Include ancestors because SwiftUI's drawer gesture lives above the
        // editable field, and selection handles can extend beyond its bounds.
        var ancestor: UIView? = geometryView
        while let current = ancestor {
            for recognizer in current.gestureRecognizers ?? [] {
                guard recognizer.isEnabled, recognizer.numberOfTouches > 0 else {
                    continue
                }
                switch recognizer.state {
                case .possible, .began, .changed:
                    break
                default:
                    continue
                }
                for index in 0..<recognizer.numberOfTouches {
                    let point = recognizer.location(ofTouch: index, in: geometryView)
                    if rects.contains(where: { $0.contains(point) }) { return true }
                }
            }
            ancestor = current.superview
        }
        return false
    }

    fileprivate static func capture(_ responder: UIResponder) {
        focusedResponder = responder
    }
}

private extension UIResponder {
    @objc func moccaCaptureComposerSelectionResponder(_ sender: Any?) {
        ComposerTextSelectionInteractionGate.capture(self)
    }
}

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFocused = false
    @State private var isGroupReplyControlExpanded = false
    @State private var inputResetID = 0
    @State private var longPasteRequest: ComposerLongPasteRequest?
    @State private var isLongPastePresented = false
    @State private var longPasteError: String?
    @State private var convertingPasteID: UUID?
    @State private var pasteConversionTask: Task<Void, Never>?

    private let inputFocusExpansion: CGFloat = 6
    private let controlVisualHeight: CGFloat = 38
    private let leadingControlsVerticalOffset: CGFloat = 3

    private var promptPlaceholder: String {
        let custom = model.preferences.chatInputPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return model.selectedConversationIsGroupChat ? L10n.lookup("给群聊发消息") : L10n.format("给 %@发消息", [String(describing: model.currentAssistant.name)])
    }

    private var composerBackgroundOpacity: Double {
        colorScheme == .dark
            ? model.preferences.chatInputBackgroundOpacityDark
            : model.preferences.chatInputBackgroundOpacityLight
    }

    private var canSend: Bool {
        if model.selectedConversationIsStreaming { return true }
        return convertingPasteID == nil && (
            !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.pendingAttachments.isEmpty
        )
    }

    var body: some View {
        let conversationID = model.selectedConversationID
        let inputRevision = inputResetID
        let draftBinding = Binding(
            get: {
                model.composerDraftText(for: conversationID)
            },
            set: { value in
                // Ignore only callbacks from an input control that was already
                // replaced after a successful send. During a conversation
                // switch, the retiring field still writes to its original
                // conversation instead of contaminating the newly selected one.
                guard inputRevision == inputResetID else { return }
                model.setComposerDraftText(value, for: conversationID)
            }
        )

        VStack(spacing: 8) {
            PendingAttachmentsStrip()

            if model.selectedConversationIsGroupChat,
               let conversationID = model.selectedConversation?.id {
                GroupReplyControl(
                    conversationID: conversationID,
                    isExpanded: $isGroupReplyControlExpanded
                )
            }

            ComposerNativeTextInput(
                text: draftBinding,
                isFocused: Binding(
                    get: { isFocused },
                    set: { focused in
                        guard conversationID == model.selectedConversationID,
                              inputRevision == inputResetID else { return }
                        isFocused = focused
                    }
                ),
                placeholder: promptPlaceholder,
                selectionColor: model.themeTextSelectionUIColor,
                enterToSend: model.preferences.enterToSendOnMobile,
                identity: ComposerInputIdentity(
                    conversationID: conversationID,
                    resetRevision: inputRevision
                ),
                onSubmit: { submitDraft(for: conversationID) },
                onLongPaste: receiveLongPaste
            )
                .id(ComposerInputIdentity(
                    conversationID: conversationID,
                    resetRevision: inputRevision
                ))
                .frame(maxWidth: .infinity, alignment: .leading)
                // Use the shell's existing inset without changing text wrapping.
                .offset(x: 4)
                // Share the existing padding above and below the editor so
                // text and caret sit lower without moving the toolbar.
                .padding(.vertical, inputFocusExpansion / 2)
                .background(
                    Color.clear
                        // Extend only into the existing gap above the controls.
                        // Background geometry does not change editor/shell height.
                        .padding(.bottom, -8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isFocused = true
                        }
                )

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Button {
                        presentBottomToolsAfterDismissingKeyboard()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .medium))
                            .frame(width: controlVisualHeight, height: controlVisualHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("打开工具菜单"))

                    Button {
                        model.isModelSelectorPresented = true
                    } label: {
                        ComposerModelBubbleIcon()
                            .frame(width: 23, height: 23)
                            .scaleEffect(0.84)
                            .frame(width: controlVisualHeight, height: controlVisualHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("选择模型"))
                    .accessibilityValue(model.currentAssistant.name)
                }
                .overlay(alignment: .top) {
                    // Only the strip above the lowered pair focuses the editor.
                    // It stops at their top edges and never crosses a button.
                    Color.clear
                        .frame(height: leadingControlsVerticalOffset)
                        .contentShape(Rectangle())
                        .onTapGesture { isFocused = true }
                        .accessibilityHidden(true)
                        .offset(y: -leadingControlsVerticalOffset)
                }
                .offset(x: -3, y: leadingControlsVerticalOffset)

                // The newly freed toolbar space focuses the editor. This is a
                // sibling of the buttons, so their hit regions stay separate.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: controlVisualHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { isFocused = true }
                    .accessibilityHidden(true)

                if !model.visibleQuickPhrases.isEmpty {
                    Menu {
                        ForEach(model.visibleQuickPhrases) { phrase in
                            Button(phrase.title.isEmpty ? String(phrase.content.prefix(18)) : phrase.title) {
                                model.insertQuickPhrase(phrase)
                            }
                        }
                    } label: {
                        Image(systemName: "bolt")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: controlVisualHeight, height: controlVisualHeight)
                            .background(Color.primary.opacity(0.055), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("快捷短语"))
                }

                Button {
                    if model.selectedConversationIsStreaming {
                        model.stopStreaming()
                    } else {
                        submitDraft(for: conversationID)
                    }
                } label: {
                    Image(systemName: model.selectedConversationIsStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(canSend && colorScheme == .dark ? Color.black : Color.white)
                        .contentTransition(.identity)
                        .frame(width: controlVisualHeight, height: controlVisualHeight)
                        .background(canSend ? Color.primary : Color.secondary)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            ComposerBackgroundSurface(
                shape: RoundedRectangle(cornerRadius: 30, style: .continuous),
                backgroundOpacity: composerBackgroundOpacity,
                usesLiquidGlass: model.preferences.useLiquidGlassComposer
            )
            .modifier(StableComposerGlassGeometryModifier(
                enabled: model.preferences.useLiquidGlassComposer
            ))
        )
        // Keep the shell and its controls in the same render group during a
        // keyboard-driven frame change. Liquid Glass otherwise may settle its
        // background one layout pass later than the input controls.
        .modifier(StableComposerRenderGroupModifier(
            enabled: model.preferences.useLiquidGlassComposer
        ))
        // Resolve keyboard motion once for the whole composer. A replacement
        // editor must enter at the shell's current position, not its endpoint.
        .geometryGroup()
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear {
            model.isComposerFocused = isFocused
        }
        .onDisappear {
            cancelLongPaste()
            isFocused = false
            if model.isComposerFocused {
                model.isComposerFocused = false
            }
        }
        .onChange(of: model.selectedConversationID) { _, _ in
            cancelLongPaste()
        }
        .onChange(of: isFocused) { _, focused in
            model.isComposerFocused = focused
        }
        .alert(L10n.lookup("粘贴的文字较长"), isPresented: $isLongPastePresented, presenting: longPasteRequest) { request in
            Button(L10n.lookup("转为 TXT 附件")) { convertLongPaste(request) }
            Button(L10n.lookup("保留文字")) {
                if canCommitLongPaste(request) {
                    _ = request.insertAsText()
                }
                cancelLongPaste()
            }
            Button(L10n.lookup("取消"), role: .cancel) { cancelLongPaste() }
        } message: { _ in
            Text(longPasteError ?? L10n.lookup("这次粘贴的文字达到 5000 个字符。要转成 TXT 附件吗？也可以继续作为消息文字粘贴。"))
        }
        .onChange(of: isLongPastePresented) { _, presented in
            if !presented, convertingPasteID == nil {
                cancelLongPaste()
            }
        }
        #if DEBUG
        .onChange(of: model.debugFocusComposerRequest) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                isFocused = true
            }
        }
        #endif
    }

    private func submitDraft(for conversationID: UUID) {
        guard model.selectedConversationID == conversationID else { return }
        guard !model.selectedConversationIsStreaming else { return }
        guard convertingPasteID == nil else { return }

        // End the Chinese IME marked-text session before the model captures and
        // clears this conversation's packet. Otherwise the retiring UIKit
        // editor can write its pre-send composition back into SwiftUI.
        UIApplication.shared.sendAction(
            #selector(UITextInput.unmarkText),
            to: nil,
            from: nil,
            for: nil
        )
        let trimmed = model.composerDraftText(for: conversationID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty
            || !model.composerPendingAttachments(for: conversationID).isEmpty
        else { return }

        // Keep the keyboard and composer stationary while the established
        // synchronous send precommit runs. Once it succeeds, resign focus in
        // the same main-thread turn that publishes the user row and its send
        // animation request, so their visible transitions begin together. A
        // failed precommit also leaves the draft and keyboard ready for retry.
        guard model.sendDraft(for: conversationID) else { return }
        cancelLongPaste()
        // Clear declarative focus before UIKit starts dismissing. A pending
        // update of the retiring input must not reacquire first responder
        // while its keyboard is already animating out.
        isFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        // End this input's editing identity after a successful send. The new
        // control starts at one line with no stale selection, undo or paste.
        inputResetID &+= 1
    }

    private func receiveLongPaste(_ request: ComposerLongPasteRequest) {
        guard longPasteRequest == nil, convertingPasteID == nil,
              canCommitLongPaste(request) else {
            request.cancel()
            return
        }
        longPasteRequest = request
        longPasteError = nil
        isLongPastePresented = true
    }

    private func canCommitLongPaste(_ request: ComposerLongPasteRequest) -> Bool {
        request.identity.conversationID == model.selectedConversationID
            && request.identity.resetRevision == inputResetID
            && request.isValid
            && model.composerDraftText(for: request.identity.conversationID).utf16
                .elementsEqual(request.originalText.utf16)
    }

    private func convertLongPaste(_ request: ComposerLongPasteRequest) {
        guard canCommitLongPaste(request), convertingPasteID == nil else {
            cancelLongPaste()
            return
        }
        convertingPasteID = request.id
        isLongPastePresented = false
        longPasteError = nil
        pasteConversionTask = Task { @MainActor in
            do {
                let committed = try await model.addPendingPastedText(
                    request.text, for: request.identity.conversationID,
                    canCommit: {
                        convertingPasteID == request.id && canCommitLongPaste(request)
                    }
                )
                guard convertingPasteID == request.id else { return }
                if committed { _ = request.finishAsAttachment() }
                cancelLongPaste()
            } catch {
                guard convertingPasteID == request.id else { return }
                convertingPasteID = nil
                pasteConversionTask = nil
                guard canCommitLongPaste(request) else {
                    cancelLongPaste()
                    return
                }
                // The original input and immutable paste are still available.
                // The same choice lets the user retry or keep the text instead.
                longPasteError = L10n.format("TXT 保存失败：%@\n原输入未改变，可以重试或选择保留文字。", [String(describing: error.localizedDescription)])
                isLongPastePresented = true
            }
        }
    }

    private func cancelLongPaste() {
        pasteConversionTask?.cancel()
        pasteConversionTask = nil
        longPasteRequest?.cancel()
        longPasteRequest = nil
        convertingPasteID = nil
        longPasteError = nil
        isLongPastePresented = false
    }

    private func presentBottomToolsAfterDismissingKeyboard() {
        // The tools sheet does not replace the composer, so its text field can
        // otherwise remain first responder underneath the sheet. End that
        // local focus ownership before presenting without changing the draft.
        isFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        model.presentBottomTools()
    }
}

private struct ComposerModelBubbleIcon: View {
    var body: some View {
        ZStack {
            ComposerModelBubbleOutline()
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            HStack(spacing: 4.7) {
                Capsule().frame(width: 2, height: 2.6)
                Capsule().frame(width: 2, height: 2.6)
            }
            .offset(y: -0.8)
        }
        .foregroundStyle(Color.primary)
        .accessibilityHidden(true)
    }
}

private struct ComposerModelBubbleOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7.8, y: 20))
        path.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 9.1, y: 20.7), control2: CGPoint(x: 10.5, y: 21))
        path.addCurve(to: CGPoint(x: 21.5, y: 11.7), control1: CGPoint(x: 17.3, y: 21), control2: CGPoint(x: 21.5, y: 16.9))
        path.addCurve(to: CGPoint(x: 12, y: 2.3), control1: CGPoint(x: 21.5, y: 6.5), control2: CGPoint(x: 17.3, y: 2.3))
        path.addCurve(to: CGPoint(x: 2.5, y: 11.7), control1: CGPoint(x: 6.7, y: 2.3), control2: CGPoint(x: 2.5, y: 6.5))
        path.addCurve(to: CGPoint(x: 3.9, y: 16.7), control1: CGPoint(x: 2.5, y: 13.5), control2: CGPoint(x: 3, y: 15.2))
        path.addLine(to: CGPoint(x: 2.8, y: 20.6))
        path.addQuadCurve(to: CGPoint(x: 3.5, y: 21.3), control: CGPoint(x: 2.5, y: 21.6))
        path.addLine(to: CGPoint(x: 7.8, y: 20))
        path.closeSubpath()
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 24))
    }
}

private struct StableComposerGlassGeometryModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), enabled {
            // The default Liquid Glass transition can add its own geometry
            // motion while the keyboard changes the parent layout. Keep the
            // composer shell on the exact same frame as its controls.
            content.glassEffectTransition(.identity)
        } else {
            content
        }
    }
}

private struct StableComposerRenderGroupModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.compositingGroup()
        } else {
            content
        }
    }
}

private struct GroupReplyControl: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    @Binding var isExpanded: Bool

    private var members: [AssistantProfile] {
        model.selectedConversationAssistantProfiles
    }

    private var selectedTarget: AssistantProfile? {
        model.selectedGroupReplyTarget(for: conversationID)
    }

    private var rounds: Int {
        model.groupReplyRounds(for: conversationID)
    }

    private var randomFirst: Bool {
        model.isGroupRandomFirstEnabled(for: conversationID)
    }

    private var summary: String {
        let target = selectedTarget?.name ?? L10n.lookup("全员")
        let roundText = selectedTarget == nil && rounds > 0 ? L10n.format(" · %@轮", [String(describing: rounds)]) : ""
        let randomText = selectedTarget == nil && randomFirst ? L10n.lookup(" · 随机先手") : ""
        return target + roundText + randomText
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                guard DrawerInlineActionTapGate.allowsAction else { return }
                withAnimation(.snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedTarget == nil ? "bubble.left.and.bubble.right" : "person.crop.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.lookup("让谁回复？"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.primary.opacity(0.045), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        replyChip(title: L10n.lookup("全员"), systemName: "bubble.left.and.bubble.right", selected: selectedTarget == nil) {
                            model.selectGroupReplyTarget(nil, conversationID: conversationID)
                        }

                        ForEach(members) { assistant in
                            replyChip(title: assistant.name, profile: assistant, selected: selectedTarget?.id == assistant.id) {
                                model.selectGroupReplyTarget(assistant.id.uuidString, conversationID: conversationID)
                            }
                        }

                        if selectedTarget == nil && members.count > 1 {
                            Menu {
                                Button(L10n.lookup("无")) { setReplyRounds(0) }
                                Button(L10n.lookup("1轮")) { setReplyRounds(1) }
                                Button(L10n.lookup("2轮")) { setReplyRounds(2) }
                                Button(L10n.lookup("3轮")) { setReplyRounds(3) }
                            } label: {
                                chipLabel(
                                    title: rounds == 0 ? L10n.lookup("互聊：无") : L10n.format("互聊：%@轮", [String(describing: rounds)]),
                                    systemName: "arrow.trianglehead.2.clockwise.rotate.90",
                                    selected: rounds > 0
                                )
                            }
                            .buttonStyle(.plain)

                            Button {
                                guard DrawerInlineActionTapGate.allowsAction else { return }
                                model.setGroupRandomFirst(!randomFirst, conversationID: conversationID)
                            } label: {
                                chipLabel(title: L10n.lookup("随机先手"), systemName: "shuffle", selected: randomFirst)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .background(DrawerHorizontalScrollProbe())
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func replyChip(
        title: String,
        systemName: String? = nil,
        profile: AssistantProfile? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard DrawerInlineActionTapGate.allowsAction else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if let profile {
                    AssistantAvatarView(profile: profile, size: 22)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.055), in: Capsule())
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func setReplyRounds(_ rounds: Int) {
        guard DrawerInlineActionTapGate.allowsAction else { return }
        model.setGroupReplyRounds(rounds, conversationID: conversationID)
    }

    private func chipLabel(title: String, systemName: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.055), in: Capsule())
        .foregroundStyle(selected ? Color.accentColor : .primary)
    }
}

struct GlassSurface<S: Shape>: View {
    let shape: S
    var backgroundOpacity: Double = 0

    var body: some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(Color(uiColor: .systemBackground).opacity(backgroundOpacity))
                .glassEffect(
                    .regular.tint(Color(uiColor: .systemBackground).opacity(backgroundOpacity * 0.18)),
                    in: shape
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color(uiColor: .systemBackground).opacity(backgroundOpacity * 0.32)))
        }
    }
}

private struct ComposerBackgroundSurface<S: Shape>: View {
    let shape: S
    let backgroundOpacity: Double
    let usesLiquidGlass: Bool

    @ViewBuilder
    var body: some View {
        if usesLiquidGlass {
            liquidGlassSurface
        } else {
            classicSurface
        }
    }

    @ViewBuilder
    private var liquidGlassSurface: some View {
        if #available(iOS 26.0, *) {
            // Match the top-bar controls: native Liquid Glass without an
            // extra white fill, white tint, or milky outline layered over it.
            GlassSurface(shape: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        Color(uiColor: .systemBackground).opacity(backgroundOpacity * 0.18)
                    )
                )
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.6))
        }
    }

    private var classicSurface: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.fill(Color(uiColor: .systemBackground).opacity(backgroundOpacity))
            )
            .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.6))
    }
}
