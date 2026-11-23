import SwiftUI
import UIKit

enum NativeMultilineTextEditorFont: Equatable {
    case body
    case system(size: CGFloat)
    case monospacedBody

    fileprivate func resolve(compatibleWith traits: UITraitCollection) -> UIFont {
        switch self {
        case .body:
            return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        case .system(let size):
            return UIFontMetrics(forTextStyle: .body).scaledFont(
                for: UIFont.systemFont(ofSize: size),
                compatibleWith: traits
            )
        case .monospacedBody:
            return UIFontMetrics(forTextStyle: .body).scaledFont(
                for: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                compatibleWith: traits
            )
        }
    }
}

/// A directly owned UITextView for editable multi-line settings text.
///
/// TextKit 1 is selected explicitly because the iOS 26 TextKit 2 viewport can
/// repeatedly report different content heights while deleting at the end of a
/// long document. UIKit still owns selection, marked text, the caret, menus,
/// scrolling, and keyboard avoidance.
struct NativeMultilineTextEditor: UIViewRepresentable {
    @Binding private var text: String
    @Environment(\.isEnabled) private var isEnabled

    private let editorFont: NativeMultilineTextEditorFont
    private let autocapitalizationType: UITextAutocapitalizationType
    private let autocorrectionType: UITextAutocorrectionType

    init(
        text: Binding<String>,
        font: NativeMultilineTextEditorFont = .body,
        autocapitalizationType: UITextAutocapitalizationType = .sentences,
        autocorrectionType: UITextAutocorrectionType = .default
    ) {
        _text = text
        editorFont = font
        self.autocapitalizationType = autocapitalizationType
        self.autocorrectionType = autocorrectionType
    }

    func makeCoordinator() -> MultilineTextViewBinding {
        MultilineTextViewBinding($text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.backgroundColor = .clear
        // Reapplying textColor can invalidate TextKit's layout and move the viewport.
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configure(textView)
        context.coordinator.attach(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        configure(textView)
        context.coordinator.update($text, in: textView)
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: MultilineTextViewBinding) {
        textView.delegate = nil
    }

    private func configure(_ textView: UITextView) {
        let resolvedFont = editorFont.resolve(compatibleWith: textView.traitCollection)
        if textView.font != resolvedFont {
            textView.font = resolvedFont
        }
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.autocapitalizationType = autocapitalizationType
        textView.autocorrectionType = autocorrectionType
    }
}

/// Synchronizes a SwiftUI draft with one UIKit editor, including marked text and selection.
@MainActor
final class MultilineTextViewBinding: NSObject, UITextViewDelegate {
    private var draft: Binding<String>
    private var isApplyingExternalText = false

    init(_ draft: Binding<String>) {
        self.draft = draft
    }

    func attach(to textView: UITextView) {
        textView.text = draft.wrappedValue
        textView.delegate = self
    }

    func update(_ draft: Binding<String>, in textView: UITextView) {
        self.draft = draft
        // UIKit owns the composing range until the input method commits it.
        guard textView.markedTextRange == nil else { return }
        let text = draft.wrappedValue
        guard textView.text != text else { return }

        let oldSelection = textView.selectedRange
        let oldOffset = textView.contentOffset
        isApplyingExternalText = true
        defer { isApplyingExternalText = false }
        textView.text = text
        textView.selectedRange = Self.clamped(oldSelection, in: text)
        textView.layoutIfNeeded()
        textView.setContentOffset(Self.clamped(oldOffset, in: textView), animated: false)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingExternalText else { return }
        let text = textView.text ?? ""
        guard draft.wrappedValue != text else { return }
        draft.wrappedValue = text
    }

    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let textLength = (text as NSString).length
        let location = min(range.location, textLength)
        return NSRange(location: location, length: min(range.length, textLength - location))
    }

    private static func clamped(_ offset: CGPoint, in textView: UITextView) -> CGPoint {
        let inset = textView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = max(minimumY, textView.contentSize.height - textView.bounds.height + inset.bottom)
        return CGPoint(x: offset.x, y: min(max(offset.y, minimumY), maximumY))
    }
}
