import UIKit
import SwiftMath

/// Immutable raster results are shared; each text storage gets its own attachment.
@MainActor
enum MarkdownMathRendering {
    private final class Entry {
        let image: UIImage?
        let darkImage: UIImage?
        let descent: CGFloat
        init(_ image: UIImage?, darkImage: UIImage? = nil, descent: CGFloat = 0) {
            self.image = image; self.darkImage = darkImage; self.descent = descent
        }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private struct RenderStyle {
        let fontSize: CGFloat
        let scale: CGFloat
        let light: UIColor
        let dark: UIColor
        let cachePrefix: String

        init(fontSize: CGFloat, color: UIColor) {
            self.fontSize = min(max(fontSize, 8), 64)
            scale = min(3, max(1, UIGraphicsImageRendererFormat.preferred().scale))
            light = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            dark = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            cachePrefix = "\(scale)|\(self.fontSize)|\(light.cgColor.colorSpace?.name as String? ?? "")|\(light.cgColor.components ?? [])|\(dark.cgColor.colorSpace?.name as String? ?? "")|\(dark.cgColor.components ?? [])|"
        }
    }

    static func replaceTokens(_ tokens: [MarkdownMathSyntax.Token], in text: NSMutableAttributedString,
                              fontSize: CGFloat, color: UIColor) {
        guard !tokens.isEmpty else { return }
        // Locate markers in their source order before mutating the string.
        // Reverse replacements then keep these ranges valid without rescanning
        // the entire (possibly long) message for every formula.
        let source = text.string as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var located: [(index: Int, range: NSRange)] = []
        located.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            let range = source.range(of: token.marker, options: [], range: searchRange)
            guard range.location != NSNotFound else { continue }
            located.append((index, range))
            searchRange = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
        }
        // Resolve appearance and scale once per inline surface, and only if a
        // complete formula actually requests rendering.
        var preparedStyle: RenderStyle?
        for (index, range) in located.reversed() {
            let token = tokens[index]
            let entry: Entry?
            if token.isClosed, index < 64 {
                let style = preparedStyle ?? RenderStyle(fontSize: fontSize, color: color)
                preparedStyle = style
                entry = rendered(token, style: style)
            } else {
                entry = nil
            }
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            let replacement: NSMutableAttributedString
            if let entry, let image = entry.image {
                let attachment = MarkdownMathAttachment(image: image, darkImage: entry.darkImage ?? image,
                                                        descent: entry.descent, source: token.source)
                replacement = NSMutableAttributedString(attachment: attachment)
                replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
                if token.display {
                    let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                        ?? NSMutableParagraphStyle()
                    style.alignment = .center
                    style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 6)
                    style.paragraphSpacing = max(style.paragraphSpacing, 8)
                    replacement.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: 1))
                }
            } else {
                replacement = NSMutableAttributedString(string: token.source, attributes: attributes)
            }
            text.replaceCharacters(in: range, with: replacement)
        }
    }

    private static func rendered(_ token: MarkdownMathSyntax.Token, style: RenderStyle) -> Entry? {
        let latex = token.latex.trimmingCharacters(in: .whitespacesAndNewlines)
        let size = style.fontSize
        let scale = style.scale
        let light = style.light
        let dark = style.dark
        let key = (style.cachePrefix + "\(token.display)|" + latex) as NSString
        if let entry = cache.object(forKey: key) { return entry }
        // Limit recursive TeX and raster allocation before entering the library.
        guard !latex.isEmpty, latex.utf8.count <= 2048 else { return nil }
        // This dependency can silently skip unsupported literal characters.
        // Reject such input as a whole instead of displaying a changed equation.
        if containsUnsupportedLiteral(in: latex) {
            let failed = Entry(nil)
            cache.setObject(failed, forKey: key, cost: latex.utf8.count + 64)
            return failed
        }
        var depth = 0
        var commands = 0
        for byte in latex.utf8 {
            if byte == 123 { depth += 1 }
            if byte == 125 { depth -= 1 }
            if byte == 92 { commands += 1 }
            if depth > 24 || commands > 128 { return nil }
        }
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.fontSize = size
        label.labelMode = token.display ? .display : .text
        label.textColor = .black
        label.textAlignment = .left
        label.latex = latex
        guard label.error == nil else {
            let failed = Entry(nil)
            cache.setObject(failed, forKey: key, cost: latex.utf8.count + 64)
            return failed
        }
        // A temporary label exposes the library's layout without allocating a
        // potentially huge bitmap. It is never inserted into the view hierarchy.
        label.layoutSubviews()
        guard let display = label.displayList else { return nil }
        let padding: CGFloat = 2
        let width = ceil(display.width + padding * 2)
        let contentHeight = max(display.ascent + display.descent, size / 2)
        let height = ceil(contentHeight + padding * 2)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 4096, height <= 2048, width * height * scale * scale <= 1_048_576 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        // Automatic range may produce a gray/alpha bitmap which is expensive
        // to repeatedly composite in TextKit. Use standard RGB for ordinary
        // colors; preserve automatic range for wide-gamut or extended colors.
        if [light.cgColor, dark.cgColor].allSatisfy({ color in
            guard let space = color.colorSpace, !space.isWideGamutRGB,
                  space.model == .rgb || space.model == .monochrome,
                  let components = color.components else { return false }
            return components.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        }) {
            format.preferredRange = .standard
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            context.cgContext.translateBy(x: 0, y: height)
            context.cgContext.scaleBy(x: 1, y: -1)
            // The zero-bounds label centers its display at y = 0. Translate
            // that already prepared display into the bitmap, avoiding a second
            // typesetting pass solely to change the temporary label's bounds.
            context.cgContext.translateBy(x: padding, y: height / 2)
            display.draw(context.cgContext)
        }
        let lightImage = image.withTintColor(light, renderingMode: .alwaysOriginal)
        let darkImage = light.isEqual(dark) ? lightImage : image.withTintColor(dark, renderingMode: .alwaysOriginal)
        let entry = Entry(lightImage, darkImage: darkImage,
                          descent: display.descent + (height - contentHeight) / 2)
        func byteCost(_ image: UIImage) -> Int {
            guard let bitmap = image.cgImage else { return Int(width * height * scale * scale * 8) }
            return bitmap.bytesPerRow * bitmap.height
        }
        let imageCost = byteCost(lightImage) + (darkImage === lightImage ? 0 : byteCost(darkImage))
        cache.setObject(entry, forKey: key, cost: imageCost + latex.utf8.count)
        return entry
    }

    private static func containsUnsupportedLiteral(in latex: String) -> Bool {
        guard latex.utf8.contains(where: { $0 > 127 || $0 == 35 || $0 == 36 || $0 == 37 || $0 == 39 || $0 == 126 }) else { return false }
        var escaped = false
        for character in latex {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character.isWhitespace || "^_{}&".contains(character) { continue }
            // The pinned engine treats a bare apostrophe as a text quote,
            // not TeX's superscript prime. Keep that spelling intact too.
            if character == "'" { return true }
            if MTMathAtomFactory.atom(forCharacter: character) == nil { return true }
        }
        return false
    }

    static func copyableText(_ text: NSAttributedString) -> String? {
        var replacements: [(NSRange, String)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let math = value as? MarkdownMathAttachment { replacements.append((range, math.source)) }
        }
        guard !replacements.isEmpty else { return nil }
        let result = NSMutableAttributedString(attributedString: text)
        for (range, source) in replacements.reversed() { result.replaceCharacters(in: range, with: source) }
        return result.string
    }
}

final class MarkdownMathAttachment: NSTextAttachment {
    let source: String
    private let descent: CGFloat
    private let naturalSize: CGSize
    private let lightImage: UIImage
    private let darkImage: UIImage

    @MainActor init(image: UIImage, darkImage: UIImage, descent: CGFloat, source: String) {
        self.source = source
        self.descent = descent
        naturalSize = image.size
        lightImage = image
        self.darkImage = darkImage
        super.init(data: nil, ofType: nil)
        self.image = lightImage
        bounds = CGRect(x: 0, y: -descent, width: image.size.width, height: image.size.height)
        accessibilityLabel = source
    }
    required init?(coder: NSCoder) { nil }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        UITraitCollection.current.userInterfaceStyle == .dark ? darkImage : lightImage
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        // Fit an oversized expression to the full paragraph width, never the
        // remainder of the current line; TextKit can move it to the next line.
        let containerWidth = textContainer?.size.width ?? naturalSize.width
        let style = textContainer?.layoutManager?.textStorage?.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle
        let available = max(1, containerWidth - (textContainer?.lineFragmentPadding ?? 0) * 2 - (style?.headIndent ?? 0))
        let scale = min(1, available / naturalSize.width)
        return CGRect(x: 0, y: -descent * scale, width: naturalSize.width * scale, height: naturalSize.height * scale)
    }
}
