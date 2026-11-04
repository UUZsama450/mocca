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

struct ComposerHeightPresentation: Equatable {
    let identity: ComposerInputIdentity
    let targetShellHeight: CGFloat
    let shellHeight: CGFloat
    var additionalMessageClearance: CGFloat = 0

    var bottomClearance: CGFloat {
        Self.bottomClearance(for: shellHeight, additionalMessageClearance: additionalMessageClearance)
    }
    // Extra visual space must not increase the existing streaming motion lag.
    var bottomFollowClearance: CGFloat { max(0, Self.bottomClearance(for: shellHeight) - shellHeight) }
    var isAnimating: Bool {
        abs(shellHeight - targetShellHeight) > 0.01
    }

    static func bottomClearance(for shellHeight: CGFloat, additionalMessageClearance: CGFloat = 0) -> CGFloat {
        max(110, shellHeight + 12) + additionalMessageClearance
    }
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

/// Only explicit shell controls (such as group reply options) interpolate.
/// Text edits publish their final geometry in a nonanimated transaction.
struct ComposerShellGeometry: AnimatableModifier {
    let identity: ComposerInputIdentity?
    nonisolated var shellHeight: CGFloat
    let targetShellHeight: CGFloat
    let additionalMessageClearance: CGFloat

    nonisolated var animatableData: CGFloat {
        get { shellHeight }
        set { shellHeight = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.composerHeightPresentation, identity.map {
            ComposerHeightPresentation(identity: $0, targetShellHeight: targetShellHeight,
                shellHeight: shellHeight, additionalMessageClearance: additionalMessageClearance)
        })
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
    var onMeasuredHeight: (CGFloat) -> Void = { _ in }
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
        if !view.isApplyingNativeEdit, view.markedTextRange == nil {
            let current = currentText?() ?? text
            if !ComposerPastePolicy.identicalText(view.text ?? "", current) {
                view.applyExternalText(current)
            }
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
        view.placeholder = placeholder
        view.tintColor = selectionColor
        let returnKey: UIReturnKeyType = enterToSend ? .send : .default
        if view.returnKeyType != returnKey { view.returnKeyType = returnKey }
        sendSource?.input = view
        view.onMeasuredHeight = onMeasuredHeight
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
    var onMeasuredHeight: ((CGFloat) -> Void)?
    private var lastMeasuredWidth: CGFloat = 0
    private var lastMeasuredHeight: CGFloat?
    private var pendingHeightMeasurement: CGSize?
    private var heightPublicationRevision = 0
    private var editingHeightPublicationScheduled = false
    private var isUpdatingUnchangedMarkedText = false
    private var keyboardTransitionDeadline: TimeInterval = 0
    private var keyboardScreenFrame: CGRect?
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
    private struct HeightEnvironment: Equatable {
        let width: CGFloat
        let windowBounds: CGRect
        let safeAreaInsets: UIEdgeInsets
        let keyboardFrame: CGRect
    }
    private var lastHeightCheck: (environment: HeightEnvironment, height: CGFloat)?
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
        invalidateTextMeasurement()
        font = newFont
        typingAttributes[.font] = newFont
        placeholderLabel.font = newFont
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        publishMeasuredHeight(deferred: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsImmediateSelectionLayout, !isApplyingNativeEdit {
            needsImmediateSelectionLayout = false
            if isFirstResponder {
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
        if !editingHeightPublicationScheduled, needsHeightCheck {
            publishMeasuredHeight(deferred: true)
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
        // Publish after UIKit finishes the edit, then update the editor and
        // transcript geometry together without scheduling animation frames.
        heightPublicationRevision += 1
        pendingHeightMeasurement = nil
        guard !editingHeightPublicationScheduled else { return }
        editingHeightPublicationScheduled = true
        if nativeEditDepth > 0 { return }
        DispatchQueue.main.async { [weak self] in
            self?.finishEditingHeightPublication()
        }
    }

    private func finishEditingHeightPublication() {
        guard editingHeightPublicationScheduled, !isRetired else { return }
        editingHeightPublicationScheduled = false
        publishMeasuredHeight(deferred: false)
    }

    private func publishMeasuredHeight(deferred: Bool) {
        guard onMeasuredHeight != nil, !isRetired, bounds.width > 0,
              let environment = heightEnvironment(width: bounds.width),
              needsHeightCheck(in: environment) else { return }
        let width = bounds.width
        let measured = composerSize(fitting: width, environment: environment).height
        lastHeightCheck = (environment, measured)
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
        pendingHeightMeasurement = measurement
        heightPublicationRevision += 1
        let revision = heightPublicationRevision
        let publish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !self.isRetired, self.heightPublicationRevision == revision else { return }
            self.pendingHeightMeasurement = nil
            if self.lastMeasuredHeight != measured {
                self.needsImmediateSelectionLayout = true
                self.setNeedsLayout()
            }
            self.lastMeasuredWidth = width
            self.lastMeasuredHeight = measured
            self.onMeasuredHeight?(measured)
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

    private func invalidateTextMeasurement() {
        cachedNaturalSize = nil
        lastHeightCheck = nil
    }

    private func heightEnvironment(width: CGFloat) -> HeightEnvironment? {
        guard let window else { return nil }
        return HeightEnvironment(width: width, windowBounds: window.bounds,
            safeAreaInsets: window.safeAreaInsets,
            keyboardFrame: keyboardScreenFrame.map { window.convert($0, from: nil) }
                ?? window.keyboardLayoutGuide.layoutFrame)
    }

    private var needsHeightCheck: Bool {
        guard let environment = heightEnvironment(width: bounds.width) else { return true }
        return needsHeightCheck(in: environment)
    }

    private func needsHeightCheck(in environment: HeightEnvironment) -> Bool {
        guard let checked = lastHeightCheck,
              checked.height == lastMeasuredHeight else { return true }
        // A height animation changes only this view's bounds.height. Recheck
        // text/font edits, width, safe area, window or keyboard budget changes.
        return checked.environment != environment
    }

    func composerSize(fitting width: CGFloat) -> CGSize {
        composerSize(fitting: width, environment: heightEnvironment(width: width))
    }

    private func composerSize(fitting width: CGFloat, environment: HeightEnvironment?) -> CGSize {
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
        if let environment {
            var bottom = environment.windowBounds.maxY - environment.safeAreaInsets.bottom
            // A freshly-created editor may join an already-open keyboard.
            let keyboard = environment.keyboardFrame
            let overlap = environment.windowBounds.intersection(keyboard)
            if !overlap.isNull, overlap.width >= environment.windowBounds.width * 0.75,
               keyboard.maxY >= environment.windowBounds.maxY - 1 {
                bottom = min(bottom, keyboard.minY)
            }
            let available = max(lineHeight, bottom - environment.windowBounds.minY - environment.safeAreaInsets.top)
            heightBudget = min(heightBudget, available * 0.4)
        }
        let maximumHeight = max(lineHeight, floor((heightBudget + 0.01) / lineHeight) * lineHeight)
        return CGSize(width: width, height: ceil(min(max(natural, lineHeight), maximumHeight)))
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        if isFirstResponder, !isTracking, !isDragging, !isDecelerating,
           selectedRange.length == 0 || isApplyingNativeEdit {
            // Keep edit/caret reveal immediate with the editor geometry.
            // Selection handles do not set the scroll view's tracking/dragging
            // flags; ranged selection must keep UIKit's animated edge scrolling.
            UIView.performWithoutAnimation {
                super.setContentOffset(contentOffset, animated: false)
            }
        } else {
            super.setContentOffset(contentOffset, animated: animated)
        }
    }

    private func performNativeEdit(_ edit: () -> Void) {
        let previousRevision = revision
        nativeEditDepth += 1
        defer {
            nativeEditDepth -= 1
            if nativeEditDepth == 0 {
                if !isUpdatingUnchangedMarkedText || revision != previousRevision {
                    invalidateTextMeasurement()
                }
                applyPendingEditorFont()
                finishEditingHeightPublication()
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

    // Geometry updates may synchronously ask SwiftUI to update this editor
    // between UIKit changing text and delivering didChange. Native input owns
    // that interval; a binding snapshot must never restore text or selection.
    override func deleteBackward() {
        performNativeEdit { super.deleteBackward() }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let previous = isUpdatingUnchangedMarkedText
        let snapshot: NSAttributedString? = markedText.flatMap { value in
            guard !value.isEmpty, let range = markedTextRange,
                  value.utf16.count == offset(from: range.start, to: range.end),
                  ComposerPastePolicy.identicalText(text(in: range) ?? "", value) else { return nil }
            return textStorage.attributedSubstring(from: NSRange(
                location: offset(from: beginningOfDocument, to: range.start),
                length: offset(from: range.start, to: range.end)))
        }
        isUpdatingUnchangedMarkedText = snapshot != nil
        defer { isUpdatingUnchangedMarkedText = previous }
        performNativeEdit {
            super.setMarkedText(markedText, selectedRange: selectedRange)
            // Keep native selection/styling work. Reuse sizing only when the
            // same marked substring also retains every attributed-text value.
            // A font/paragraph/style change must still invalidate measurement.
            if let snapshot {
                let current = markedTextRange.map { range in
                    textStorage.attributedSubstring(from: NSRange(
                        location: offset(from: beginningOfDocument, to: range.start),
                        length: offset(from: range.start, to: range.end)))
                }
                isUpdatingUnchangedMarkedText = current.map { snapshot.isEqual(to: $0) } ?? false
                if !isUpdatingUnchangedMarkedText { invalidateIntrinsicContentSize() }
            }
        }
    }

    // The Chinese keyboard can use attributed marked text instead of the
    // string entry point. Native input owns this entire edit, including UIKit
    // callbacks that may synchronously reconcile the surrounding SwiftUI view.
    override func setAttributedMarkedText(_ markedText: NSAttributedString?, selectedRange: NSRange) {
        performNativeEdit { super.setAttributedMarkedText(markedText, selectedRange: selectedRange) }
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
        let changed = !ComposerPastePolicy.identicalText(observedText, current)
        if changed {
            invalidateTextMeasurement()
            revision &+= 1
            observedText = current
            pendingRequest = nil
        }
        updatePlaceholder()
        if changed || !isUpdatingUnchangedMarkedText { invalidateIntrinsicContentSize() }
    }

    func applyExternalText(_ value: String) {
        guard !isRetired, !isApplyingNativeEdit, markedTextRange == nil else { return }
        let oldSelection = selectedRange
        text = value
        let length = value.utf16.count
        let location = min(oldSelection.location, length)
        selectedRange = NSRange(location: location, length: min(oldSelection.length, length - location))
        observeNativeTextChange()
        publishMeasuredHeight(deferred: true)
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
        invalidateTextMeasurement()
        lastMeasuredHeight = nil
        pendingHeightMeasurement = nil
        lastMeasuredWidth = 0
        heightPublicationRevision += 1
        undoManager?.removeAllActions()
    }

    func retire() {
        isRetired = true
        NotificationCenter.default.removeObserver(self)
        heightPublicationRevision += 1
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
