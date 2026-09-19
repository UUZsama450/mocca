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

struct ComposerNativeTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let selectionColor: UIColor
    let enterToSend: Bool
    let identity: ComposerInputIdentity
    let onSubmit: () -> Void
    let onLongPaste: (ComposerLongPasteRequest) -> Void

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
        if !ComposerPastePolicy.identicalText(view.text ?? "", text), view.markedTextRange == nil {
            view.applyExternalText(text)
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
        view.placeholder = placeholder
        view.tintColor = selectionColor
        view.returnKeyType = enterToSend ? .send : .default
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
    var onLongPaste: ((ComposerLongPasteRequest) -> Void)?
    var onFocusRequested: (() -> Void)?
    var placeholder = "" { didSet { updatePlaceholder() } }

    private let placeholderLabel = UILabel()
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: font?.lineHeight ?? 21)
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(font?.lineHeight ?? 21))
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: composerSize(fitting: bounds.width).height)
    }

    func composerSize(fitting width: CGFloat) -> CGSize {
        let lineHeight = font?.lineHeight ?? 21
        let natural = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(min(max(natural, lineHeight), lineHeight * 6)))
    }

    override func insertText(_ text: String) {
        let previous = isHandlingCompositionCommit
        isHandlingCompositionCommit = previous || markedTextRange != nil
        defer { isHandlingCompositionCommit = previous }
        super.insertText(text)
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
        super.insertText(string)
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
            revision &+= 1
            observedText = current
            pendingRequest = nil
        }
        updatePlaceholder()
        invalidateIntrinsicContentSize()
    }

    func applyExternalText(_ value: String) {
        guard !isRetired, markedTextRange == nil else { return }
        let oldSelection = selectedRange
        text = value
        let length = value.utf16.count
        let location = min(oldSelection.location, length)
        selectedRange = NSRange(location: location, length: min(oldSelection.length, length - location))
        observeNativeTextChange()
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
        undoManager?.removeAllActions()
    }

    func retire() {
        isRetired = true
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
