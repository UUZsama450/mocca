import Foundation
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

struct ComposerInputIdentity: Hashable, Sendable {
    let conversationID: UUID
    let resetRevision: Int
}

enum ComposerPastePolicy {
    static let longPasteCharacterThreshold = 5_000

    static func shouldOfferAttachment(for text: String) -> Bool {
        text.index(text.startIndex, offsetBy: longPasteCharacterThreshold, limitedBy: text.endIndex) != nil
    }

    static func identicalText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    static func shouldSubmitReturn(
        replacement: String, enterToSend: Bool, isPasting: Bool, isComposing: Bool
    ) -> Bool {
        enterToSend && replacement == "\n" && !isPasting && !isComposing
    }
}

/// Captures an edit intent without changing the draft. UTF-16 ranges match
/// UITextInput; the threshold above deliberately counts Swift Characters.
struct ComposerPasteSnapshot: Sendable {
    let token: UUID
    let identity: ComposerInputIdentity
    let revision: UInt64
    let originalText: String
    let selection: NSRange
    let pastedText: String

    func matches(
        token currentToken: UUID?, identity currentIdentity: ComposerInputIdentity,
        revision currentRevision: UInt64, text currentText: String, selection currentSelection: NSRange
    ) -> Bool {
        guard token == currentToken, identity == currentIdentity, revision == currentRevision,
              selection == currentSelection,
              ComposerPastePolicy.identicalText(originalText, currentText) else { return false }
        let length = originalText.utf16.count
        return selection.location >= 0 && selection.length >= 0
            && selection.location <= length && selection.length <= length - selection.location
    }
}

#if canImport(UIKit)
@MainActor
final class ComposerLongPasteRequest: Identifiable {
    let id: UUID
    let text: String
    let originalText: String
    let identity: ComposerInputIdentity
    fileprivate let snapshot: ComposerPasteSnapshot
    fileprivate let shouldRestoreFocus: Bool
    private weak var host: ComposerInputTextView?
    private var isFinished = false

    fileprivate init(host: ComposerInputTextView, snapshot: ComposerPasteSnapshot) {
        self.host = host
        self.snapshot = snapshot
        id = snapshot.token
        text = snapshot.pastedText
        originalText = snapshot.originalText
        identity = snapshot.identity
        shouldRestoreFocus = host.isFirstResponder
    }

    var isValid: Bool {
        !isFinished && host?.canResolve(self) == true
    }

    @discardableResult
    func insertAsText() -> Bool {
        guard isValid, let host else { return false }
        isFinished = true
        return host.resolve(self, insertText: true)
    }

    @discardableResult
    func finishAsAttachment() -> Bool {
        guard isValid, let host else { return false }
        isFinished = true
        return host.resolve(self, insertText: false)
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        host?.cancel(self)
    }
}

/// One native measurement supplies both the editor and transcript geometry.
struct ComposerInputHeightChange: Equatable, Sendable {
    let identity: ComposerInputIdentity
    let previous: CGFloat
    let target: CGFloat
    var isCompositionEdit = false
    var delta: CGFloat { target - previous }
    static let duration: TimeInterval = 0.18
    static var animation: Animation { .timingCurve(0.25, 0, 0.15, 1, duration: duration) }

    var resolvedAnimation: Animation {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-baselineComposerCompositionMotion") {
            return Self.animation
        }
        #endif
        // Marked text can wrap and then contract as the candidate is committed.
        // Keep velocity across those retargets without introducing bounce.
        // Ordinary typing retains the previously accepted timing curve.
        return isCompositionEdit
            ? .spring(duration: Self.duration, bounce: 0, blendDuration: 0)
            : Self.animation
    }
}

private struct ComposerInputHeightChangeKey: TransactionKey {
    static let defaultValue: ComposerInputHeightChange? = nil
}

extension Transaction {
    var composerInputHeightChange: ComposerInputHeightChange? {
        get { self[ComposerInputHeightChangeKey.self] }
        set { self[ComposerInputHeightChangeKey.self] = newValue }
    }
}

struct ComposerHeightPresentation: Equatable {
    let identity: ComposerInputIdentity
    let inputHeight: CGFloat
    let targetInputHeight: CGFloat
    let targetShellHeight: CGFloat
    var presentedShellHeight: CGFloat? = nil

    var shellHeight: CGFloat { presentedShellHeight ?? (targetShellHeight + inputHeight - targetInputHeight) }
    var bottomClearance: CGFloat { Self.bottomClearance(for: shellHeight) }
    var isAnimating: Bool {
        abs(inputHeight - targetInputHeight) > 0.01 || abs(shellHeight - targetShellHeight) > 0.01
    }

    static func bottomClearance(for shellHeight: CGFloat) -> CGFloat { max(110, shellHeight + 12) }
}

private struct ComposerHeightPresentationKey: EnvironmentKey {
    static let defaultValue: ComposerHeightPresentation? = nil
}

extension EnvironmentValues {
    var composerHeightPresentation: ComposerHeightPresentation? {
        get { self[ComposerHeightPresentationKey.self] }
        set { self[ComposerHeightPresentationKey.self] = newValue }
    }
}

/// Interpolate once for the transcript and, when enabled, the editor.
/// Neither consumer starts another animation toward the final height.
struct ComposerHeightAnimation: AnimatableModifier {
    let identity: ComposerInputIdentity?
    nonisolated var inputHeight: CGFloat
    nonisolated var shellBaseHeight: CGFloat
    let targetInputHeight: CGFloat
    let targetShellHeight: CGFloat

    init(identity: ComposerInputIdentity?, inputHeight: CGFloat, targetInputHeight: CGFloat, targetShellHeight: CGFloat) {
        self.identity = identity
        self.inputHeight = inputHeight
        self.targetInputHeight = targetInputHeight
        self.targetShellHeight = targetShellHeight
        // Typing changes the input component only. Expanding the group controls
        // changes the remaining shell height, using its own existing transaction.
        shellBaseHeight = targetShellHeight - targetInputHeight
    }

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inputHeight, shellBaseHeight) }
        set { inputHeight = newValue.first; shellBaseHeight = newValue.second }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.composerHeightPresentation, identity.map {
                ComposerHeightPresentation(identity: $0, inputHeight: inputHeight,
                    targetInputHeight: targetInputHeight, targetShellHeight: targetShellHeight,
                    presentedShellHeight: shellBaseHeight + inputHeight)
            })
            .transaction { transaction in
                if transaction.composerInputHeightChange != nil {
                    transaction.animation = nil
                }
            }
    }
}

/// A send-time snapshot; never observes keyboard or layout frames.
struct ComposerSendOrigin: Equatable, Sendable {
    let windowID: ObjectIdentifier
    let bubbleTop: CGFloat
}

@MainActor
final class ComposerSendSource {
    weak var input: ComposerInputTextView?

    func snapshot(for identity: ComposerInputIdentity) -> ComposerSendOrigin? {
        guard let input, input.identity == identity, input.permitsSendOriginSnapshot,
              let window = input.window else { return nil }
        // Align the new bubble's text with the visible editor text. The bubble
        // already supplies 12 points of vertical text padding.
        let point = CGPoint(x: input.bounds.minX,
                            y: input.bounds.minY + input.textContainerInset.top - 12)
        let top = input.convert(point, to: window).y
        guard top.isFinite else { return nil }
        return ComposerSendOrigin(windowID: ObjectIdentifier(window), bubbleTop: top)
    }
}

struct ComposerNativeTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let selectionColor: UIColor
    let enterToSend: Bool
    let identity: ComposerInputIdentity
    let onSubmit: () -> Void
    let onLongPaste: (ComposerLongPasteRequest) -> Void

    var editorFont: UIFont = .systemFont(ofSize: 17)
    var animatesHeightChanges = true
    var onMeasuredHeight: (CGFloat, Bool, Bool) -> Void = { _, _, _ in }
    var currentText: (() -> String)? = nil
    var sendSource: ComposerSendSource? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerInputTextView {
        let view = ComposerInputTextView(identity: identity)
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configure(view, coordinator: context.coordinator)
        view.applyExternalText(text)
        return view
    }

    func updateUIView(_ view: ComposerInputTextView, context: Context) {
        context.coordinator.parent = self
        if view.identity != identity {
            // The caller normally replaces the host with .id(identity). Keep
            // this path safe if SwiftUI reuses it during a reconciliation.
            view.changeIdentity(to: identity)
        }
        configure(view, coordinator: context.coordinator)
        // A local height-state update can run before SwiftUI refreshes the
        // Binding's cached value. Read the owning draft directly when supplied,
        // so layout never writes an older snapshot over a just-typed character.
        let current = currentText?() ?? text
        if !ComposerPastePolicy.identicalText(view.text ?? "", current),
           !view.isApplyingNativeEdit, view.markedTextRange == nil {
            view.applyExternalText(current)
        }
        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: ComposerInputTextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.composerSize(fitting: width)
    }

    static func dismantleUIView(_ view: ComposerInputTextView, coordinator: Coordinator) {
        view.retire()
        view.delegate = nil
        view.pasteDelegate = nil
    }

    private func configure(_ view: ComposerInputTextView, coordinator: Coordinator) {
        view.applyEditorFont(editorFont)
        view.animatesHeightChanges = animatesHeightChanges
        view.placeholder = placeholder
        view.tintColor = selectionColor
        let returnKey: UIReturnKeyType = enterToSend ? .send : .default
        if view.returnKeyType != returnKey { view.returnKeyType = returnKey }
        sendSource?.input = view
        view.onMeasuredHeight = onMeasuredHeight
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-disableComposerHeightMotion") {
            view.onMeasuredHeight = nil
        }
        #endif
        view.onLongPaste = onLongPaste
        view.onFocusRequested = { [weak coordinator] in
            coordinator?.parent.isFocused = true
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: ComposerNativeTextInput

        init(parent: ComposerNativeTextInput) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? ComposerInputTextView, !view.isRetired else { return }
            view.observeNativeTextChange()
            let value = view.text ?? ""
            if !ComposerPastePolicy.identicalText(parent.text, value) { parent.text = value }
            // Publish the draft before any layout callback can reconcile the
            // editor. Otherwise a synchronous parent update can restore the
            // previous binding over the edit that just arrived from UIKit.
            view.publishEditingHeight()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard let view = textView as? ComposerInputTextView, !view.isRetired else { return }
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard let view = textView as? ComposerInputTextView, !view.isRetired else { return }
            if parent.isFocused { parent.isFocused = false }
        }

        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
        ) -> Bool {
            guard let view = textView as? ComposerInputTextView, !view.isRetired else { return false }
            if ComposerPastePolicy.shouldSubmitReturn(
                replacement: text, enterToSend: parent.enterToSend,
                isPasting: view.isInsertingPaste,
                isComposing: view.markedTextRange != nil || view.isHandlingCompositionCommit
            ) {
                parent.onSubmit()
                return false
            }
            return true
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            performPasteOf attributedString: NSAttributedString, to textRange: UITextRange
        ) -> UITextRange {
            guard let view = textPasteConfigurationSupporting as? ComposerInputTextView,
                  !view.isRetired else { return textRange }
            // UIKit still loads and combines short/multiple/rich paste items.
            // A dedicated insertion path identifies even asynchronous newline
            // pastes, which must never trigger the Return-to-send delegate.
            return view.insertSystemPaste(attributedString.string, into: textRange) ?? textRange
        }
    }
}

@MainActor
final class ComposerInputTextView: UITextView {
    private(set) var identity: ComposerInputIdentity
    private(set) var isRetired = false
    private(set) var isInsertingPaste = false
    private(set) var isHandlingCompositionCommit = false
    private var nativeEditDepth = 0
    var isApplyingNativeEdit: Bool { nativeEditDepth > 0 || isInsertingPaste }
    var onLongPaste: ((ComposerLongPasteRequest) -> Void)?
    var onFocusRequested: (() -> Void)?
    var onMeasuredHeight: ((CGFloat, Bool, Bool) -> Void)?
    private var lastMeasuredWidth: CGFloat = 0
    private var lastMeasuredHeight: CGFloat?
    private var pendingHeightMeasurement: CGSize?
    private var heightPublicationRevision = 0
    private var editingHeightPublicationScheduled = false
    private var pendingCompositionHeightEdit = false
    private var nativeEditIncludesComposition = false
    private var keyboardTransitionDeadline: TimeInterval = 0
    private var keyboardScreenFrame: CGRect?
    var animatesHeightChanges = true
    private var needsImmediateSelectionLayout = false
    private weak var selectionDisplay: UITextSelectionDisplayInteraction?

    /// Reuse the existing keyboard deadline. A focused or dismissing editor
    /// keeps the established send entrance; only a settled, unfocused editor
    /// supplies the new composer origin. No extra keyboard observer is needed.
    fileprivate var permitsSendOriginSnapshot: Bool {
        !isRetired && !isFirstResponder && CACurrentMediaTime() >= keyboardTransitionDeadline
    }
    var placeholder = "" {
        didSet {
            if placeholder != oldValue { updatePlaceholder() }
        }
    }

    private let placeholderLabel = UILabel()
    private var pendingEditorFont: UIFont?
    private var cachedNaturalSize: CGSize?
    #if COMPOSER_INPUT_MEASUREMENT_PROBE
    private(set) var composerSizeRequests = 0
    private(set) var textMeasurementCount = 0
    #endif
    private var revision: UInt64 = 0
    private var observedText = ""
    private var pendingRequest: ComposerLongPasteRequest?

    init(identity: ComposerInputIdentity) {
        self.identity = identity
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        font = .systemFont(ofSize: 17)
        textColor = .label
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = true
        alwaysBounceVertical = false
        showsVerticalScrollIndicator = true
        autocapitalizationType = .sentences
        autocorrectionType = .default
        allowsEditingTextAttributes = false
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.lineBreakMode = .byTruncatingTail
        addSubview(placeholderLabel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyEditorFont(_ newFont: UIFont) {
        pendingEditorFont = font == newFont ? nil : newFont
        applyPendingEditorFont()
    }

    private func applyPendingEditorFont() {
        // Preserve the input method's marked text until its native edit ends.
        guard let newFont = pendingEditorFont, markedTextRange == nil,
              !isApplyingNativeEdit, !isRetired else { return }
        pendingEditorFont = nil
        cachedNaturalSize = nil
        font = newFont
        typingAttributes[.font] = newFont
        placeholderLabel.font = newFont
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        publishMeasuredHeight(fromEdit: false, deferred: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsImmediateSelectionLayout, !isApplyingNativeEdit {
            needsImmediateSelectionLayout = false
            if !animatesHeightChanges, isFirstResponder {
                if selectionDisplay == nil {
                    selectionDisplay = interactions.compactMap { $0 as? UITextSelectionDisplayInteraction }.first
                }
                // A nonanimated height change must not display the previous
                // line's cursor for one frame. Keep UIKit's normal idle blink.
                UIView.performWithoutAnimation {
                    selectionDisplay?.layoutManagedSubviews()
                    selectionDisplay?.cursorView.resetBlinkAnimation()
                }
            }
        }
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: font?.lineHeight ?? 21)
        if !editingHeightPublicationScheduled {
            publishMeasuredHeight(fromEdit: false, deferred: true)
        }
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        keyboardTransitionDeadline = CACurrentMediaTime() + max(0, duration)
        keyboardScreenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func publishEditingHeight() {
        guard onMeasuredHeight != nil else { return }
        pendingCompositionHeightEdit = pendingCompositionHeightEdit
            || markedTextRange != nil || isHandlingCompositionCommit || nativeEditIncludesComposition
        // Publish after UIKit finishes the edit, then drive the editor and
        // shell from the same existing height animation.
        heightPublicationRevision += 1
        pendingHeightMeasurement = nil
        guard !editingHeightPublicationScheduled else { return }
        editingHeightPublicationScheduled = true
        if !animatesHeightChanges, nativeEditDepth > 0 { return }
        DispatchQueue.main.async { [weak self] in
            self?.finishEditingHeightPublication()
        }
    }

    private func finishEditingHeightPublication() {
        guard editingHeightPublicationScheduled, !isRetired else { return }
        editingHeightPublicationScheduled = false
        let compositionEdit = pendingCompositionHeightEdit
        pendingCompositionHeightEdit = false
        publishMeasuredHeight(
            fromEdit: isFirstResponder && CACurrentMediaTime() >= keyboardTransitionDeadline,
            deferred: false,
            compositionEdit: compositionEdit
        )
    }

    private func publishMeasuredHeight(fromEdit: Bool, deferred: Bool, compositionEdit: Bool = false) {
        guard onMeasuredHeight != nil, !isRetired, window != nil, bounds.width > 0 else { return }
        let width = bounds.width
        let measured = composerSize(fitting: width).height
        let sameWidth = abs(lastMeasuredWidth - width) <= 0.5
        guard !sameWidth || lastMeasuredHeight != measured else {
            if pendingHeightMeasurement != nil {
                heightPublicationRevision += 1
                pendingHeightMeasurement = nil
            }
            return
        }
        let measurement = CGSize(width: width, height: measured)
        if deferred, pendingHeightMeasurement == measurement { return }
        let animate = fromEdit && sameWidth && lastMeasuredHeight != nil
        pendingHeightMeasurement = measurement
        heightPublicationRevision += 1
        let revision = heightPublicationRevision
        let publish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !self.isRetired, self.heightPublicationRevision == revision else { return }
            self.pendingHeightMeasurement = nil
            self.lastMeasuredWidth = width
            self.lastMeasuredHeight = measured
            self.onMeasuredHeight?(measured, animate, animate && compositionEdit)
        }
        // Layout/external draft reconciliation must not write SwiftUI state
        // during a view update. A newer real edit supersedes this publication.
        if deferred { DispatchQueue.main.async(execute: publish) } else { publish() }
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(font?.lineHeight ?? 21))
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: composerSize(fitting: bounds.width).height)
    }

    func composerSize(fitting width: CGFloat) -> CGSize {
        #if COMPOSER_INPUT_MEASUREMENT_PROBE
        composerSizeRequests += 1
        #endif
        let lineHeight = font?.lineHeight ?? 21
        let natural: CGFloat
        if let cachedNaturalSize, cachedNaturalSize.width == width {
            natural = cachedNaturalSize.height
        } else {
            natural = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            cachedNaturalSize = CGSize(width: width, height: natural)
            #if COMPOSER_INPUT_MEASUREMENT_PROBE
            textMeasurementCount += 1
            #endif
        }
        // Grow naturally up to five lines, while leaving room for the chat
        // above the keyboard. Round the available budget down to whole lines.
        var heightBudget = lineHeight * 5
        if let window {
            var bottom = window.bounds.maxY - window.safeAreaInsets.bottom
            // A freshly-created editor may join an already-open keyboard.
            let keyboard = keyboardScreenFrame.map { window.convert($0, from: nil) }
                ?? window.keyboardLayoutGuide.layoutFrame
            let overlap = window.bounds.intersection(keyboard)
            if !overlap.isNull, overlap.width >= window.bounds.width * 0.75,
               keyboard.maxY >= window.bounds.maxY - 1 {
                bottom = min(bottom, keyboard.minY)
            }
            let available = max(lineHeight, bottom - window.bounds.minY - window.safeAreaInsets.top)
            heightBudget = min(heightBudget, available * 0.4)
        }
        let maximumHeight = max(lineHeight, floor((heightBudget + 0.01) / lineHeight) * lineHeight)
        return CGSize(width: width, height: ceil(min(max(natural, lineHeight), maximumHeight)))
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if !animatesHeightChanges, isFirstResponder, !isTracking, !isDragging, !isDecelerating {
            // With motion disabled, automatic caret reveal lands immediately.
            // Manual dragging and deceleration keep UIKit's normal behavior.
            UIView.performWithoutAnimation {
                super.setContentOffset(contentOffset, animated: false)
            }
        } else {
            super.setContentOffset(contentOffset, animated: animated)
        }
    }

    private func performNativeEdit(_ edit: () -> Void) {
        let previousComposition = nativeEditIncludesComposition
        nativeEditIncludesComposition = previousComposition || markedTextRange != nil
        nativeEditDepth += 1
        defer {
            nativeEditIncludesComposition = previousComposition
            nativeEditDepth -= 1
            if nativeEditDepth == 0 {
                cachedNaturalSize = nil
                applyPendingEditorFont()
                if !animatesHeightChanges {
                    needsImmediateSelectionLayout = true
                    finishEditingHeightPublication()
                    setNeedsLayout()
                }
            }
        }
        edit()
    }

    override func insertText(_ text: String) {
        let previous = isHandlingCompositionCommit
        isHandlingCompositionCommit = previous || markedTextRange != nil
        defer { isHandlingCompositionCommit = previous }
        performNativeEdit { super.insertText(text) }
    }

    // Animated geometry may synchronously ask SwiftUI to update this editor
    // between UIKit changing text and delivering didChange. Native input owns
    // that interval; a binding snapshot must never restore text or selection.
    override func deleteBackward() {
        performNativeEdit { super.deleteBackward() }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        performNativeEdit { super.setMarkedText(markedText, selectedRange: selectedRange) }
    }

    override func unmarkText() {
        performNativeEdit { super.unmarkText() }
    }

    override func replace(_ range: UITextRange, withText text: String) {
        performNativeEdit { super.replace(range, withText: text) }
    }

    override func paste(_ sender: Any?) {
        guard !isRetired, pendingRequest == nil else { return }
        let board = UIPasteboard.general
        // A single textual representation is captured exactly once. If UIKit
        // needs to combine items or decode rich-only content, leave that work
        // to its ordinary paste pipeline rather than dropping unknown payloads.
        if board.numberOfItems == 1, let pastedText = board.string,
           ComposerPastePolicy.shouldOfferAttachment(for: pastedText), let onLongPaste {
            if markedTextRange != nil { unmarkText() }
            observeNativeTextChange()
            let snapshot = ComposerPasteSnapshot(
                token: UUID(), identity: identity, revision: revision,
                originalText: text ?? "", selection: selectedRange, pastedText: pastedText
            )
            let request = ComposerLongPasteRequest(host: self, snapshot: snapshot)
            pendingRequest = request
            onLongPaste(request)
            return
        }
        // Also covers the synchronous path on OS versions that insert before
        // invoking the paste delegate. The delegate covers async providers.
        isInsertingPaste = true
        defer { isInsertingPaste = false }
        super.paste(sender)
    }

    fileprivate func canResolve(_ request: ComposerLongPasteRequest) -> Bool {
        !isRetired && request.snapshot.matches(
            token: pendingRequest?.id, identity: identity, revision: revision, text: text ?? "",
            selection: selectedRange
        )
    }

    fileprivate func resolve(_ request: ComposerLongPasteRequest, insertText: Bool) -> Bool {
        guard canResolve(request) else { return false }
        pendingRequest = nil
        if insertText {
            insertPastedText(request.text)
            restoreFocusIfNeeded(request)
        }
        return true
    }

    fileprivate func cancel(_ request: ComposerLongPasteRequest) {
        guard pendingRequest?.id == request.id else { return }
        pendingRequest = nil
    }

    fileprivate func insertSystemPaste(_ string: String, into range: UITextRange) -> UITextRange? {
        guard !isRetired, pendingRequest == nil else { return nil }
        let startOffset = offset(from: beginningOfDocument, to: range.start)
        selectedTextRange = range
        insertPastedText(string)
        guard let start = position(from: beginningOfDocument, offset: startOffset),
              let end = position(from: start, offset: string.utf16.count) else { return nil }
        return textRange(from: start, to: end)
    }

    private func insertPastedText(_ string: String) {
        let previous = isInsertingPaste
        isInsertingPaste = true
        defer { isInsertingPaste = previous }
        let manager = undoManager
        manager?.beginUndoGrouping()
        // Native insertText replaces the selected range and owns the undo edit;
        // assigning .text here would lose the native selection/undo operation.
        performNativeEdit { super.insertText(string) }
        manager?.endUndoGrouping()
        manager?.setActionName("粘贴")
        observeNativeTextChange()
        // UIKit may already have delivered this delegate; equality checks make
        // this explicit publication idempotent for programmatic insertions.
        delegate?.textViewDidChange?(self)
    }

    func observeNativeTextChange() {
        let current = text ?? ""
        if !ComposerPastePolicy.identicalText(observedText, current) {
            cachedNaturalSize = nil
            revision &+= 1
            observedText = current
            pendingRequest = nil
        }
        updatePlaceholder()
        invalidateIntrinsicContentSize()
    }

    func applyExternalText(_ value: String) {
        guard !isRetired, !isApplyingNativeEdit, markedTextRange == nil else { return }
        let oldSelection = selectedRange
        text = value
        let length = value.utf16.count
        let location = min(oldSelection.location, length)
        selectedRange = NSRange(location: location, length: min(oldSelection.length, length - location))
        observeNativeTextChange()
        publishMeasuredHeight(fromEdit: false, deferred: true)
    }

    func changeIdentity(to identity: ComposerInputIdentity) {
        pendingRequest = nil
        revision &+= 1
        let previousDelegate = delegate
        delegate = nil
        if markedTextRange != nil { unmarkText() }
        text = ""
        observedText = ""
        delegate = previousDelegate
        self.identity = identity
        cachedNaturalSize = nil
        lastMeasuredHeight = nil
        pendingHeightMeasurement = nil
        pendingCompositionHeightEdit = false
        lastMeasuredWidth = 0
        heightPublicationRevision += 1
        undoManager?.removeAllActions()
    }

    func retire() {
        isRetired = true
        NotificationCenter.default.removeObserver(self)
        heightPublicationRevision += 1
        pendingCompositionHeightEdit = false
        onMeasuredHeight = nil
        pendingRequest = nil
        onLongPaste = nil
        onFocusRequested = nil
        undoManager?.removeAllActions()
    }

    private func updatePlaceholder() {
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !(text ?? "").isEmpty
        accessibilityLabel = placeholder
    }

    private func restoreFocusIfNeeded(_ request: ComposerLongPasteRequest) {
        guard request.shouldRestoreFocus else { return }
        let expectedIdentity = request.identity
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isRetired, self.identity == expectedIdentity, self.window != nil else { return }
            self.onFocusRequested?()
            self.becomeFirstResponder()
        }
    }
}
#endif
