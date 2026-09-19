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

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        configure(textView)
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        configure(textView)

        guard textView.text != text else { return }

        // Never replace storage while an input method owns marked text. The
        // delegate has already synchronised the current composition to SwiftUI.
        guard textView.markedTextRange == nil else { return }

        let oldSelection = textView.selectedRange
        let oldOffset = textView.contentOffset
        context.coordinator.isApplyingExternalText = true
        textView.text = text
        textView.selectedRange = Self.clamped(oldSelection, in: text)
        textView.layoutIfNeeded()
        textView.setContentOffset(Self.clamped(oldOffset, in: textView), animated: false)
        context.coordinator.isApplyingExternalText = false
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        textView.delegate = nil
    }

    private func configure(_ textView: UITextView) {
        let resolvedFont = editorFont.resolve(compatibleWith: textView.traitCollection)
        if textView.font != resolvedFont {
            textView.font = resolvedFont
        }
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.autocapitalizationType = autocapitalizationType
        textView.autocorrectionType = autocorrectionType
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeMultilineTextEditor
        var isApplyingExternalText = false

        init(parent: NativeMultilineTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            let updatedText = textView.text ?? ""
            guard parent.text != updatedText else { return }
            parent.text = updatedText
        }
    }
}
