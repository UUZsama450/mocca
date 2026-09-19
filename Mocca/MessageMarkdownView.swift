import CoreText
import CryptoKit
import Foundation
import SwiftUI
import UIKit
import WebKit

private enum MessageTextLayoutTrace {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains(
        "-diagnoseMessageTextLayout"
    )

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[message-text-layout] %@", message())
    }

    static func rect(_ rect: CGRect) -> String {
        guard !rect.isNull else { return "null" }
        guard !rect.isInfinite else { return "infinite" }
        return String(
            format: "{x=%.1f y=%.1f w=%.1f h=%.1f}",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    static func range(_ range: NSRange) -> String {
        "{\(range.location),\(range.length)}"
    }

    static func objectToken(_ object: AnyObject) -> String {
        String(describing: ObjectIdentifier(object))
    }
}

@MainActor
private final class UnifiedTextMeasurementCache {
    static let shared = UnifiedTextMeasurementCache(capacity: 256)
    static let code = UnifiedTextMeasurementCache(capacity: 128)

    private let capacity: Int
    private var values: [String: CGSize] = [:]
    private var insertionOrder: [String] = []

    private init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: String) -> CGSize? {
        values[key]
    }

    func insert(_ value: CGSize, for key: String) {
        if values[key] == nil {
            insertionOrder.append(key)
        }
        values[key] = value

        while insertionOrder.count > capacity {
            let evictedKey = insertionOrder.removeFirst()
            values.removeValue(forKey: evictedKey)
        }
    }
}

// These caches retain preparation results, never native views or TextKit layout.
// A small FIFO and a text-weight budget bound retention across conversation switches.
@MainActor
private final class SettledMarkdownPreparationCache: NSObject {
    static let shared = SettledMarkdownPreparationCache()

    struct ProseKey: Equatable {
        let signature: String
        let source: String
        let interfaceStyle: UIUserInterfaceStyle
        let contrast: UIAccessibilityContrast
    }

    struct TableKey: Equatable {
        let font: UIFont
        let headerFont: UIFont
        let table: MarkdownTableContent
    }

    private var prose: [(key: ProseKey, text: NSAttributedString, weight: Int)] = []
    private var tables: [(key: TableKey, widths: [CGFloat], weight: Int)] = []
    private let maximumEntries = 4
    private let maximumTextWeight = 131_072

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(removeAll),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    @objc func removeAll() {
        prose.removeAll()
        tables.removeAll()
    }

    func prose(for key: ProseKey, make: () -> NSAttributedString) -> NSAttributedString {
        if let entry = prose.first(where: { $0.key == key }) { return entry.text }
        let text = make()
        let weight = key.source.utf16.count + text.length
        guard weight <= maximumTextWeight else { return text }

        // Rule/citation attachments have mutable, view-specific geometry. Keep
        // those on the existing builder path instead of sharing their instances.
        var containsAttachment = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { containsAttachment = true; stop.pointee = true }
        }
        guard !containsAttachment else { return text }

        // The settled builder relinquishes this result. As required by
        // NSAttributedString, its attribute values are not mutated after
        // publication; each consumer still gets its own UITextView storage.
        let prepared = NSAttributedString(attributedString: text)
        while prose.count >= maximumEntries || prose.reduce(weight, { $0 + $1.weight }) > maximumTextWeight {
            prose.removeFirst()
        }
        prose.append((key, prepared, weight))
        return prepared
    }

    func columnWidths(for key: TableKey, make: () -> [CGFloat]) -> [CGFloat] {
        if let entry = tables.first(where: { $0.key == key }) { return entry.widths }
        let widths = make()
        // Charge empty cells and row containers too; an empty but very large
        // matrix must not bypass the retention budget.
        let weight = key.table.header.reduce(0) { $0 + 16 + $1.utf16.count }
            + key.table.rows.reduce(0) { $0 + 16 + $1.reduce(0) { $0 + 16 + $1.utf16.count } }
        guard weight <= maximumTextWeight else { return widths }
        while tables.count >= maximumEntries || tables.reduce(weight, { $0 + $1.weight }) > maximumTextWeight {
            tables.removeFirst()
        }
        tables.append((key, widths, weight))
        return widths
    }
}

struct MessageCitationSource: Hashable, Identifiable {
    let index: Int
    let providerID: String
    let title: String
    let url: URL

    var id: String {
        "\(index):\(providerID)|\(url.absoluteString)"
    }

    var lookupKey: String {
        "\(index):\(providerID)"
    }

    var faviconKey: String {
        normalizedHost
    }

    var siteName: String {
        let host = normalizedHost
        return host.isEmpty ? (title.isEmpty ? ErrorLocalization.lookup("来源") : title) : host
    }

    private var normalizedHost: String {
        var host = url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    func matches(destination rawDestination: String) -> Bool {
        let destination = (rawDestination.removingPercentEncoding ?? rawDestination)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.caseInsensitiveCompare(lookupKey) == .orderedSame
            || destination.caseInsensitiveCompare(providerID) == .orderedSame {
            return true
        }
        if let numericIndex = Int(destination), numericIndex == index {
            return true
        }
        guard let destinationURL = URL(string: destination) else { return false }
        return Self.normalizedURLString(destinationURL) == Self.normalizedURLString(url)
    }

    static func sources(from toolEvents: [ToolEvent]) -> [MessageCitationSource] {
        var sources: [MessageCitationSource] = []
        var seen = Set<String>()

        for event in toolEvents {
            guard let raw = event.resultText,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else {
                continue
            }

            for item in items {
                let index: Int
                if let value = item["index"] as? NSNumber {
                    index = value.intValue
                } else if let value = item["index"] as? String, let parsed = Int(value) {
                    index = parsed
                } else {
                    continue
                }
                guard let rawURL = item["url"] as? String,
                      let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    continue
                }
                let providerID = (item["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !providerID.isEmpty else { continue }
                let source = MessageCitationSource(
                    index: index,
                    providerID: providerID,
                    title: item["title"] as? String ?? "",
                    url: url
                )
                let dedupeKey = source.lookupKey.lowercased() + "|" + Self.normalizedURLString(url)
                if seen.insert(dedupeKey).inserted {
                    sources.append(source)
                }
            }
        }
        return sources
    }

    static func sourcesByMessageID(
        from messages: [ChatMessage],
        retentionTurns: Int
    ) -> [UUID: [MessageCitationSource]] {
        var retainedSources: [(source: MessageCitationSource, userTurnsAfter: Int)] = []
        var result: [UUID: [MessageCitationSource]] = [:]

        for message in messages {
            if message.role == .user {
                for index in retainedSources.indices {
                    retainedSources[index].userTurnsAfter += 1
                }
                if retentionTurns >= 0 {
                    retainedSources.removeAll { $0.userTurnsAfter > retentionTurns }
                }
                continue
            }
            guard message.role == .assistant else { continue }

            let currentSources = sources(from: message.toolEvents)
            var combined = currentSources + retainedSources.map(\.source)
            var seen = Set<String>()
            combined.removeAll { !seen.insert($0.id.lowercased()).inserted }
            if !combined.isEmpty {
                result[message.id] = combined
            }

            for source in currentSources {
                retainedSources.removeAll {
                    $0.source.id.caseInsensitiveCompare(source.id) == .orderedSame
                }
                retainedSources.append((source, 0))
            }
        }
        return result
    }

    fileprivate static func normalizedURLString(_ url: URL) -> String {
        var value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value.lowercased()
    }
}

@MainActor
private final class CitationFaviconLoader {
    static let shared = CitationFaviconLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = URLCache(
            memoryCapacity: 2_000_000,
            diskCapacity: 8_000_000
        )
        session = URLSession(configuration: configuration)
    }

    func image(for pageURL: URL) async -> UIImage? {
        guard let host = pageURL.host?.lowercased(), !host.isEmpty else { return nil }
        let key = NSString(string: host)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/favicon.ico"
        guard let faviconURL = components.url else { return nil }

        var request = URLRequest(url: faviconURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode),
              data.count <= 1_500_000,
              let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
enum DrawerHorizontalScrollGate {
    private static let scrollViews = NSHashTable<UIScrollView>.weakObjects()

    static func register(_ scrollView: UIScrollView) {
        scrollViews.add(scrollView)
    }

    static func unregister(_ scrollView: UIScrollView) {
        scrollViews.remove(scrollView)
    }

    static var ownsCurrentTouch: Bool {
        scrollViews.allObjects.contains { scrollView in
            let pan = scrollView.panGestureRecognizer
            return scrollView.window != nil
                && scrollView.isScrollEnabled
                && pan.isEnabled
                && pan.numberOfTouches > 0
        }
    }
}

/// Lets the root drawer defer only when the active finger is already owned by
/// a concrete native text selection. This stays imperative so selection-handle
/// movement does not publish SwiftUI state through the transcript.
@MainActor
enum DrawerTextSelectionInteractionGate {
    private static let textViews = NSHashTable<GlyphSelectableTextView>.weakObjects()
    private static let dismissalControllers =
        NSMapTable<UIScrollView, TextSelectionDismissTapController>.weakToStrongObjects()

    fileprivate static func register(_ textView: GlyphSelectableTextView) {
        textViews.add(textView)
        installDismissalControllerIfNeeded(for: textView)
    }

    fileprivate static func unregister(_ textView: GlyphSelectableTextView) {
        textViews.remove(textView)
    }

    static var ownsCurrentTouch: Bool {
        textViews.allObjects.contains { $0.ownsCurrentSelectionTouch }
    }

    fileprivate static func hasActiveSelection(in scrollView: UIScrollView) -> Bool {
        textViews.allObjects.contains { textView in
            textView.window != nil
                && textView.isDescendant(of: scrollView)
                && textView.selectedRange.length > 0
        }
    }

    fileprivate static func dismissSelections(
        outside tapRecognizer: UITapGestureRecognizer,
        in scrollView: UIScrollView
    ) {
        for textView in textViews.allObjects where
            textView.window != nil
                && textView.isDescendant(of: scrollView)
                && textView.selectedRange.length > 0 {
            let point = tapRecognizer.location(in: textView)
            guard !textView.isPointNearSelection(point) else { continue }
            textView.clearSelection()
        }
    }

    private static func installDismissalControllerIfNeeded(
        for textView: GlyphSelectableTextView
    ) {
        guard let scrollView = enclosingScrollView(of: textView),
              dismissalControllers.object(forKey: scrollView) == nil else { return }
        dismissalControllers.setObject(
            TextSelectionDismissTapController(scrollView: scrollView),
            forKey: scrollView
        )
    }

    private static func enclosingScrollView(of textView: UIView) -> UIScrollView? {
        var ancestor = textView.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }
}

/// Observes transcript taps without cancelling UIKit's native text gestures.
/// A tap outside every existing selection clears only the stale selectedRange;
/// taps on selected text or its handles remain fully owned by UITextView.
@MainActor
private final class TextSelectionDismissTapController: NSObject, UIGestureRecognizerDelegate {
    private weak var scrollView: UIScrollView?
    private var tapRecognizer: UITapGestureRecognizer?

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()

        let tapRecognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap(_:))
        )
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delaysTouchesBegan = false
        tapRecognizer.delaysTouchesEnded = false
        tapRecognizer.delegate = self
        scrollView.addGestureRecognizer(tapRecognizer)
        self.tapRecognizer = tapRecognizer
    }

    @objc
    private func handleTap(_ tapRecognizer: UITapGestureRecognizer) {
        guard tapRecognizer.state == .ended, let scrollView else { return }
        DrawerTextSelectionInteractionGate.dismissSelections(
            outside: tapRecognizer,
            in: scrollView
        )
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView else { return false }
        return DrawerTextSelectionInteractionGate.hasActiveSelection(in: scrollView)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

struct DrawerHorizontalScrollProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> DrawerHorizontalScrollProbeView {
        DrawerHorizontalScrollProbeView()
    }

    func updateUIView(_ uiView: DrawerHorizontalScrollProbeView, context: Context) {
        uiView.scheduleResolution()
    }

    static func dismantleUIView(
        _ uiView: DrawerHorizontalScrollProbeView,
        coordinator: ()
    ) {
        uiView.unregisterResolvedScrollView()
    }
}

final class DrawerHorizontalScrollProbeView: UIView {
    weak var resolvedScrollView: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleResolution()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unregisterResolvedScrollView()
        } else {
            scheduleResolution()
        }
    }

    func scheduleResolution() {
        if let resolvedScrollView,
           resolvedScrollView.window != nil,
           window != nil {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.resolveScrollView()
        }
    }

    func unregisterResolvedScrollView() {
        if let resolvedScrollView {
            DrawerHorizontalScrollGate.unregister(resolvedScrollView)
        }
        resolvedScrollView = nil
    }

    private func resolveScrollView() {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                if resolvedScrollView !== scrollView {
                    unregisterResolvedScrollView()
                    resolvedScrollView = scrollView
                    DrawerHorizontalScrollGate.register(scrollView)
                }
                return
            }
            ancestor = current.superview
        }
        unregisterResolvedScrollView()
    }
}

private enum MarkdownReadingRhythm {
    static let layoutSignature = "reading-rhythm-v4-list-spacing"

    // Keep ordinary lines compact while giving semantic Markdown blocks a
    // clearer visual hierarchy. These values are shared by the streaming and
    // completed render paths so completion does not reflow the transcript.
    static let blockStackSpacing: CGFloat = 14
    static let bodyBlockSpacing: CGFloat = 14
    static let headingBlockSpacing: CGFloat = 18
    static let quoteBlockSpacing: CGFloat = 16
    static let listBlockSpacing: CGFloat = 14
    static let compactListItemSpacing: CGFloat = 4
    static let horizontalRuleVerticalSpacing: CGFloat = 18
}

struct MessageMarkdownView: View {
    private enum NativeSelectionRoute {
        case unified
        case mixed
        case legacy
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var fontSize: CGFloat = 17
    var lineSpacing: CGFloat = 4
    var listItemSpacing: CGFloat = MarkdownReadingRhythm.compactListItemSpacing
    var blockSpacingScale: CGFloat = 1
    var isUserMessage = false
    var isStreaming = false
    var rendersMarkdown = true
    var htmlRunnerEnabled = false
    var htmlRunnerAllowCurrentChat = false
    var htmlRunnerConversationID: UUID?
    var autoCollapseCodeBlock = false
    var collapsedCodeLineLimit = 2
    var codeBlockAppearance: CodeBlockAppearance = .system
    var fillsAvailableWidth = true
    var compactMaximumWidth: CGFloat?
    var allowsTextSelection = true
    var prefersUnifiedNativeSelection = false
    var foregroundColor: Color = Color(uiColor: .label)
    var largeHeadingColor: Color?
    var smallHeadingColor: Color?
    var linkColor: Color?
    var selectionTintColor: Color = .accentColor
    var fontName: String?
    var onBlankLongPress: ((CGPoint) -> Void)?
    var versionFlashContext: VersionFlashTextContext?
    var versionFlashSegmentIndex: Int?
    var citationSources: [MessageCitationSource] = []
    var contentMutationContext: MessageContentMutationContext?

    @State private var citationFavicons: [String: UIImage] = [:]

    private var blocks: [MarkdownRenderBlock] {
        isStreaming
            ? MarkdownRenderParser.parse(text)
            : MarkdownRenderCache.blocks(for: text)
    }

    private var resolvedBlockSpacingScale: CGFloat {
        min(max(blockSpacingScale, 0.5), 1.5)
    }

    private var resolvedListItemSpacing: CGFloat {
        min(max(listItemSpacing, 0), 12)
    }

    private var resolvedBlockStackSpacing: CGFloat {
        MarkdownReadingRhythm.blockStackSpacing * resolvedBlockSpacingScale
    }

    private var citationRenderSignature: String {
        citationSources.map(\.id).joined(separator: "|")
            + "#"
            + citationFavicons.keys.sorted().joined(separator: "|")
    }

    private var nativeTextLayoutPhaseID: String {
        isStreaming ? "streaming" : "settled"
    }

    private var resolvedCompactMaximumWidth: CGFloat? {
        compactMaximumWidth
    }

    private var compactProseWidthConfiguration: UserMessageCompactProseConfiguration? {
        guard compactMaximumWidth != nil,
              isUserMessage,
              !isStreaming else {
            return nil
        }
        let prose = compactProseForWidthMeasurement
        if MessageTextLayoutTrace.isEnabled {
            let tickCount = text.reduce(into: 0) { count, character in
                if character == "`" { count += 1 }
            }
            MessageTextLayoutTrace.log(
                "USER_BUBBLE_ROUTE compact=\(prose != nil)"
                    + " utf16=\((text as NSString).length)"
                    + " markdown=\(rendersMarkdown)"
                    + " blocks=\(blocks.count)"
                    + " ticks=\(tickCount)"
            )
        }
        guard let prose else { return nil }
        let uiFont = AppFontStore.uiFont(postScriptName: fontName, size: fontSize)
        return UserMessageCompactProseConfiguration(
            text: prose,
            fontName: uiFont.fontName,
            fontSize: uiFont.pointSize,
            lineSpacing: lineSpacing,
            displayScale: UIScreen.main.scale
        )
    }

    private var compactProseForWidthMeasurement: String? {
        if !rendersMarkdown { return text }

        guard blocks.count == 1,
              case let .text(value) = blocks[0].kind else {
            return nil
        }

        // The simple prose path is rendered with one SwiftUI Text. Structured
        // Markdown keeps the established maximum-width fallback because lists,
        // tables, code, and inline presentation can legitimately need it.
        let inlineMarkdownMarkers = CharacterSet(charactersIn: "*_[]<>")
        guard value.rangeOfCharacter(from: inlineMarkdownMarkers) == nil else {
            return nil
        }
        // One unmatched backtick is commonly used as the closing eye/accent in
        // kaomoji such as `(´▽`)`. It cannot form an inline Markdown code span,
        // so keep treating that message as plain prose. Two or more backticks
        // remain on the established structured-Markdown fallback path.
        guard value.reduce(into: 0, { count, character in
            if character == "`" { count += 1 }
        }) < 2 else {
            return nil
        }
        return value
    }

    var body: some View {
        let renderedBlocks = rendersMarkdown ? blocks : []
        let selectionRoute = nativeSelectionRoute(in: renderedBlocks)
        Group {
            if selectionRoute == .unified {
                UnifiedSelectableProseText(
                    makeAttributedText: {
                        unifiedAttributedText(blocks: renderedBlocks)
                    },
                    renderSignature: "\(text.hashValue)|\(MarkdownReadingRhythm.layoutSignature)|\(fontSize)|\(lineSpacing)|\(resolvedListItemSpacing)|\(resolvedBlockSpacingScale)|\(rendersMarkdown)|\(fontName ?? "system")|\(String(describing: foregroundColor))|\(String(describing: largeHeadingColor))|\(String(describing: smallHeadingColor))|\(String(describing: resolvedLinkColor))|\(citationRenderSignature)",
                    linkColor: UIColor(resolvedLinkColor),
                    selectionTintColor: UIColor(selectionTintColor),
                    widthPolicy: resolvedCompactMaximumWidth.map { .fit(maxWidth: $0) } ?? .fill,
                    allowsSelection: allowsTextSelection && !isStreaming,
                    usesSharedMeasurementCache: !isStreaming,
                    preparationSource: !isStreaming && text.utf16.count >= 2_048 ? text : nil,
                    onBlankLongPress: onBlankLongPress,
                    versionFlashContext: versionFlashContext,
                    versionFlashSegmentIndex: versionFlashSegmentIndex,
                    onOpenURL: { url in openURL(url) }
                )
                // A completed reply must not inherit TextKit geometry from its
                // streaming instance. The stale instance can retain excess
                // height even after revisiting the conversation; replacing
                // only this native text view clears that layout state without
                // changing the message, its Markdown, or the outer row.
                .id(nativeTextLayoutPhaseID)
                .conditionalFillWidth(fillsAvailableWidth && resolvedCompactMaximumWidth == nil)
            } else if selectionRoute == .mixed {
                mixedContent(blocks: renderedBlocks)
                    .messageTextWidthLayout(
                        fillsAvailableWidth: fillsAvailableWidth,
                        compactMaximumWidth: resolvedCompactMaximumWidth,
                        compactProseConfiguration: compactProseWidthConfiguration
                    )
            } else {
                legacyContent(blocks: renderedBlocks)
                    .messageTextWidthLayout(
                        fillsAvailableWidth: fillsAvailableWidth,
                        compactMaximumWidth: resolvedCompactMaximumWidth,
                        compactProseConfiguration: compactProseWidthConfiguration
                    )
            }
        }
        .task(id: citationSources.map(\.id).joined(separator: "|")) {
            await loadCitationFavicons()
        }
    }

    private func mixedContent(blocks: [MarkdownRenderBlock]) -> some View {
        VStack(alignment: .leading, spacing: resolvedBlockStackSpacing) {
            ForEach(mixedSegments(from: blocks)) { segment in
                switch segment.kind {
                case let .prose(proseBlocks):
                    UnifiedSelectableProseText(
                        makeAttributedText: {
                            UnifiedSelectableProseBuilder.makeAttributedText(
                                blocks: proseBlocks,
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                listItemSpacing: resolvedListItemSpacing,
                                blockSpacingScale: resolvedBlockSpacingScale,
                                textColor: UIColor(foregroundColor),
                                largeHeadingColor: largeHeadingColor.map { UIColor($0) },
                                smallHeadingColor: smallHeadingColor.map { UIColor($0) },
                                fontName: fontName,
                                citationSources: citationSources,
                                citationFavicons: citationFavicons
                            )
                        },
                        renderSignature: "mixed|\(MarkdownReadingRhythm.layoutSignature)|\(segment.id)|\(proseBlocks.hashValue)|\(fontSize)|\(lineSpacing)|\(resolvedListItemSpacing)|\(resolvedBlockSpacingScale)|\(fontName ?? "system")|\(String(describing: foregroundColor))|\(String(describing: largeHeadingColor))|\(String(describing: smallHeadingColor))|\(String(describing: resolvedLinkColor))|\(citationRenderSignature)",
                        linkColor: UIColor(resolvedLinkColor),
                        selectionTintColor: UIColor(selectionTintColor),
                        widthPolicy: resolvedCompactMaximumWidth.map { .fit(maxWidth: $0) } ?? .fill,
                        allowsSelection: allowsTextSelection && !isStreaming,
                        usesSharedMeasurementCache: !isStreaming,
                        preparationSource: nil,
                        onBlankLongPress: onBlankLongPress,
                        versionFlashContext: versionFlashContext,
                        versionFlashSegmentIndex: versionFlashSegmentIndex,
                        onOpenURL: { url in openURL(url) }
                    )
                    .id(nativeTextLayoutPhaseID)
                    .conditionalFillWidth(fillsAvailableWidth && resolvedCompactMaximumWidth == nil)

                case let .code(language, code, isClosed):
                    MarkdownCodeBlock(
                        blockID: segment.id,
                        language: language,
                        code: code,
                        isStreaming: isStreaming && !isClosed,
                        fontSize: max(11, fontSize - 4),
                        htmlRunnerEnabled: htmlRunnerEnabled,
                        htmlRunnerAllowCurrentChat: htmlRunnerAllowCurrentChat,
                        htmlRunnerConversationID: htmlRunnerConversationID,
                        autoCollapse: autoCollapseCodeBlock,
                        collapsedLineLimit: collapsedCodeLineLimit,
                        appearance: codeBlockAppearance,
                        allowsTextSelection: allowsTextSelection && !isStreaming,
                        contentMutationContext: contentMutationContext
                    )

                case let .table(table):
                    MarkdownTableBlock(
                        table: table,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        allowsTextSelection: allowsTextSelection && !isStreaming,
                        fontName: fontName,
                        usesCache: !isStreaming
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func legacyContent(blocks: [MarkdownRenderBlock]) -> some View {
        if rendersMarkdown {
            VStack(alignment: .leading, spacing: resolvedBlockStackSpacing) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case let .text(value):
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownTextBlock(
                                text: value,
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                isUserMessage: isUserMessage,
                                allowsTextSelection: allowsLegacyTextSelection,
                                foregroundColor: foregroundColor,
                                fontName: fontName,
                                usesCache: !isStreaming
                            )
                        }
                    case let .quote(value):
                        MarkdownQuoteBlock(
                            text: value,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing,
                            isUserMessage: isUserMessage,
                            allowsTextSelection: allowsLegacyTextSelection,
                            foregroundColor: foregroundColor,
                            fontName: fontName,
                            usesCache: !isStreaming
                        )
                    case let .heading(level, value):
                        MarkdownHeadingBlock(
                            level: level,
                            text: value,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing,
                            isUserMessage: isUserMessage,
                            allowsTextSelection: allowsLegacyTextSelection,
                            foregroundColor: resolvedHeadingColor(level: level),
                            fontName: fontName,
                            usesCache: !isStreaming
                        )
                    case let .list(entries):
                        MarkdownListBlock(
                            entries: entries,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing,
                            isUserMessage: isUserMessage,
                            allowsTextSelection: allowsLegacyTextSelection,
                            foregroundColor: foregroundColor,
                            fontName: fontName,
                            usesCache: !isStreaming
                        )
                    case .horizontalRule:
                        MarkdownHorizontalRule()
                    case let .code(language, code, isClosed):
                        MarkdownCodeBlock(
                            blockID: block.id,
                            language: language,
                            code: code,
                            isStreaming: isStreaming && !isClosed,
                            fontSize: max(11, fontSize - 4),
                            htmlRunnerEnabled: htmlRunnerEnabled,
                            htmlRunnerAllowCurrentChat: htmlRunnerAllowCurrentChat,
                            htmlRunnerConversationID: htmlRunnerConversationID,
                            autoCollapse: autoCollapseCodeBlock,
                            collapsedLineLimit: collapsedCodeLineLimit,
                            appearance: codeBlockAppearance,
                            allowsTextSelection: allowsLegacyTextSelection,
                            contentMutationContext: contentMutationContext
                        )
                    case let .table(table):
                        MarkdownTableBlock(
                            table: table,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing,
                            allowsTextSelection: allowsTextSelection && !isStreaming,
                            fontName: fontName,
                            usesCache: !isStreaming
                        )
                    }
                }
            }
        } else {
            Text(text)
                .font(
                    AppFontStore.swiftUIFont(
                        postScriptName: fontName,
                        size: fontSize,
                        fixedCustomSize: isUserMessage
                    )
                )
                .lineSpacing(lineSpacing)
                .foregroundStyle(foregroundColor)
                .controlledTextSelection(allowsTextSelection)
        }
    }

    private func unifiedAttributedText(
        blocks: [MarkdownRenderBlock]
    ) -> NSAttributedString {
        let attributedText: NSAttributedString
        if rendersMarkdown {
            attributedText = UnifiedSelectableProseBuilder.makeAttributedText(
                blocks: blocks,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                listItemSpacing: resolvedListItemSpacing,
                blockSpacingScale: resolvedBlockSpacingScale,
                textColor: UIColor(foregroundColor),
                largeHeadingColor: largeHeadingColor.map { UIColor($0) },
                smallHeadingColor: smallHeadingColor.map { UIColor($0) },
                fontName: fontName,
                citationSources: citationSources,
                citationFavicons: citationFavicons
            )
        } else {
            attributedText = UnifiedSelectableProseBuilder.makePlainText(
                text,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                textColor: UIColor(foregroundColor),
                fontName: fontName
            )
        }
        return applyingStreamingTailFade(to: attributedText)
    }

    private func applyingStreamingTailFade(
        to attributedText: NSAttributedString
    ) -> NSAttributedString {
        guard isStreaming,
              !isUserMessage,
              !reduceMotion,
              attributedText.length > 0 else {
            return attributedText
        }

        // ChatGPT-style streaming reveal: the newest rendered characters are
        // faint, then become solid as subsequent display batches move them out
        // of this tail window. Reuse the existing stream publication cadence;
        // no timer, task, scroll writer, or additional view identity is needed.
        let renderedString = attributedText.string
        // Keep the reveal compact and readable when the provider pauses between
        // tokens. A short, brighter tail preserves the soft entrance without
        // leaving a whole phrase looking stalled at very low opacity.
        // The reveal never needs more than eight composed characters. Looking
        // at the first sixteen preserves the exact old count while avoiding a
        // full grapheme traversal for every long streaming revision.
        let boundedCharacterCount = renderedString.prefix(16).count
        let fadeCharacterCount = min(8, max(1, boundedCharacterCount / 2))
        let minimumOpacity = 0.44
        // Both unified builders already produce a fresh mutable string for
        // this render. Reuse it so the reveal does not add another full-text
        // copy to the existing streaming Markdown/TextKit work.
        let mutable = (attributedText as? NSMutableAttributedString)
            ?? NSMutableAttributedString(attributedString: attributedText)
        var tailRanges: [NSRange] = []
        tailRanges.reserveCapacity(fadeCharacterCount)

        renderedString.enumerateSubstrings(
            in: renderedString.startIndex..<renderedString.endIndex,
            options: [.byComposedCharacterSequences, .reverse]
        ) { substring, substringRange, _, stop in
            guard let substring,
                  !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let range = NSRange(substringRange, in: renderedString)
            guard range.location < mutable.length,
                  mutable.attribute(
                    .attachment,
                    at: range.location,
                    effectiveRange: nil
                  ) == nil else {
                return
            }
            tailRanges.append(range)
            if tailRanges.count == fadeCharacterCount {
                stop = true
            }
        }

        tailRanges.reverse()
        let count = max(1, tailRanges.count)
        for (index, range) in tailRanges.enumerated() {
            let progress = Double(index + 1) / Double(count)
            let opacity = minimumOpacity
                + (1 - pow(progress, 1.2)) * (1 - minimumOpacity)
            let baseColor = mutable.attribute(
                .foregroundColor,
                at: range.location,
                effectiveRange: nil
            ) as? UIColor ?? UIColor(foregroundColor)
            mutable.addAttribute(
                .foregroundColor,
                value: baseColor.withAlphaComponent(
                    baseColor.cgColor.alpha * CGFloat(opacity)
                ),
                range: range
            )
        }
        return mutable
    }

    private var resolvedLinkColor: Color {
        linkColor ?? (isUserMessage ? foregroundColor : Color(uiColor: .link))
    }

    private func resolvedHeadingColor(level: Int) -> Color {
        (level <= 2 ? largeHeadingColor : smallHeadingColor) ?? foregroundColor
    }

    private func nativeSelectionRoute(
        in blocks: [MarkdownRenderBlock]
    ) -> NativeSelectionRoute {
        guard prefersUnifiedNativeSelection,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .legacy
        }
        guard rendersMarkdown else { return .unified }
        guard !blocks.isEmpty else { return .legacy }
        let containsMixedContent = blocks.contains { block in
            switch block.kind {
            case .code, .table:
                return true
            case .text, .heading, .list, .quote, .horizontalRule:
                return false
            }
        }
        return containsMixedContent ? .mixed : .unified
    }

    private func mixedSegments(
        from blocks: [MarkdownRenderBlock]
    ) -> [MixedMarkdownSegment] {
        var segments: [MixedMarkdownSegment] = []
        var pendingProse: [MarkdownRenderBlock] = []

        func flushProse() {
            guard let first = pendingProse.first else { return }
            segments.append(
                MixedMarkdownSegment(
                    id: first.id,
                    kind: .prose(pendingProse)
                )
            )
            pendingProse.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            switch block.kind {
            case let .code(language, code, isClosed):
                flushProse()
                segments.append(
                    MixedMarkdownSegment(
                        id: block.id,
                        kind: .code(language: language, code: code, isClosed: isClosed)
                    )
                )

            case let .table(table):
                flushProse()
                segments.append(
                    MixedMarkdownSegment(
                        id: block.id,
                        kind: .table(table)
                    )
                )

            default:
                pendingProse.append(block)
            }
        }
        flushProse()
        return segments
    }

    private var allowsLegacyTextSelection: Bool {
        allowsTextSelection && !(prefersUnifiedNativeSelection && rendersMarkdown)
    }

    @MainActor
    private func loadCitationFavicons() async {
        var loadedFavicons = citationFavicons
        var didLoadNewFavicon = false
        for source in citationSources {
            let key = source.faviconKey
            guard !key.isEmpty, loadedFavicons[key] == nil else { continue }
            guard let image = await CitationFaviconLoader.shared.image(for: source.url) else { continue }
            loadedFavicons[key] = image
            didLoadNewFavicon = true
        }
        if didLoadNewFavicon {
            // Commit all newly available icons together. Updating @State once
            // prevents one full text remeasurement per citation during a
            // conversation switch while keeping the final attributed text
            // identical.
            citationFavicons = loadedFavicons
        }
    }
}

private struct MixedMarkdownSegment: Identifiable {
    enum Kind {
        case prose([MarkdownRenderBlock])
        case code(language: String, code: String, isClosed: Bool)
        case table(MarkdownTableContent)
    }

    let id: Int
    let kind: Kind
}

private extension View {
    @ViewBuilder
    func conditionalFillWidth(_ enabled: Bool) -> some View {
        if enabled {
            frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self
        }
    }

    @ViewBuilder
    func messageTextWidthLayout(
        fillsAvailableWidth: Bool,
        compactMaximumWidth: CGFloat?,
        compactProseConfiguration: UserMessageCompactProseConfiguration? = nil
    ) -> some View {
        if let compactMaximumWidth {
            if let compactProseConfiguration {
                UserMessageCompactProseLayout(
                    maximumWidth: compactMaximumWidth,
                    configuration: compactProseConfiguration
                ) {
                    self
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    self.fixedSize(horizontal: true, vertical: false)
                    self.frame(maxWidth: compactMaximumWidth, alignment: .leading)
                }
            }
        } else if fillsAvailableWidth {
            frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self
        }
    }

    @ViewBuilder
    func controlledTextSelection(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func tableCellActions(_ text: String, enabled: Bool) -> some View {
        if enabled {
            contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label(L10n.lookup("复制这一格"), systemImage: "doc.on.doc")
                }

                ShareLink(item: text) {
                    Label(L10n.lookup("分享这一格"), systemImage: "square.and.arrow.up")
                }
            }
        } else {
            self
        }
    }
}

private struct UserMessageCompactProseConfiguration {
    let text: String
    let fontName: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let displayScale: CGFloat

    var signature: String {
        "\(fontName)|\(fontSize)|\(lineSpacing)|\(displayScale)|\(text)"
    }
}

private struct UserMessageCompactProseLayout: Layout {
    struct Cache {
        var signature = ""
        var availableWidth: CGFloat = -1
        var childWidth: CGFloat = 0
        var measuredSize: CGSize = .zero
        var didLogPlacement = false
    }

    let maximumWidth: CGFloat
    let configuration: UserMessageCompactProseConfiguration

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }

        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let availableWidth = max(1, min(maximumWidth, proposedWidth ?? maximumWidth))
        let signature = "\(configuration.signature)|\(maximumWidth)"
        if cache.signature == signature,
           abs(cache.availableWidth - availableWidth) < 0.001 {
            return cache.measuredSize
        }

        let displayScale = max(1, configuration.displayScale)
        let pixel = 1 / displayScale
        let naturalSize = subview.sizeThatFits(.unspecified)

        let childWidth: CGFloat
        let measuredSize: CGSize
        if naturalSize.width <= availableWidth + pixel {
            childWidth = min(availableWidth, naturalSize.width)
            measuredSize = naturalSize
            if MessageTextLayoutTrace.isEnabled {
                MessageTextLayoutTrace.log(
                    "USER_BUBBLE_LAYOUT branch=natural"
                        + " utf16=\((configuration.text as NSString).length)"
                        + " proposalW=\(Self.number(proposedWidth))"
                        + " availableW=\(Self.number(availableWidth))"
                        + " natural=\(Self.size(naturalSize))"
                        + " selected=\(Self.size(measuredSize))"
                )
            }
        } else {
            let maximumSize = subview.sizeThatFits(
                ProposedViewSize(width: availableWidth, height: nil)
            )
            let candidateWidth = min(
                availableWidth,
                max(pixel, ceil(maximumSize.width / pixel) * pixel)
            )
            let candidateSize = subview.sizeThatFits(
                ProposedViewSize(width: candidateWidth, height: nil)
            )
            let preservesHeight = abs(candidateSize.height - maximumSize.height) <= pixel
            if candidateWidth < availableWidth - pixel, preservesHeight {
                childWidth = candidateWidth
                measuredSize = CGSize(width: candidateWidth, height: candidateSize.height)
            } else {
                childWidth = availableWidth
                measuredSize = CGSize(width: availableWidth, height: maximumSize.height)
            }
            if MessageTextLayoutTrace.isEnabled {
                let selection = childWidth == candidateWidth ? "candidate" : "maximum"
                MessageTextLayoutTrace.log(
                    "USER_BUBBLE_LAYOUT branch=wrapped"
                        + " utf16=\((configuration.text as NSString).length)"
                        + " proposalW=\(Self.number(proposedWidth))"
                        + " availableW=\(Self.number(availableWidth))"
                        + " natural=\(Self.size(naturalSize))"
                        + " maximum=\(Self.size(maximumSize))"
                        + " candidateSource=swiftUIUsedWidth"
                        + " candidateW=\(Self.number(candidateWidth))"
                        + " candidate=\(Self.size(candidateSize))"
                        + " preservesHeight=\(preservesHeight)"
                        + " selection=\(selection)"
                        + " selected=\(Self.size(measuredSize))"
                )
            }
        }

        cache.signature = signature
        cache.availableWidth = availableWidth
        cache.childWidth = childWidth
        cache.measuredSize = measuredSize
        cache.didLogPlacement = false
        return measuredSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard let subview = subviews.first else { return }
        if MessageTextLayoutTrace.isEnabled, !cache.didLogPlacement {
            MessageTextLayoutTrace.log(
                "USER_BUBBLE_PLACE"
                    + " utf16=\((configuration.text as NSString).length)"
                    + " bounds=\(Self.size(bounds.size))"
                    + " childW=\(Self.number(cache.childWidth))"
            )
            cache.didLogPlacement = true
        }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: cache.childWidth, height: nil)
        )
    }

    private static func number(_ value: CGFloat?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.2f", value)
    }

    private static func size(_ value: CGSize) -> String {
        "\(number(value.width))x\(number(value.height))"
    }
}

private enum UnifiedTextWidthPolicy {
    case fill
    case fit(maxWidth: CGFloat)
}

private struct UnifiedSelectableProseText: UIViewRepresentable {
    let makeAttributedText: () -> NSAttributedString
    let renderSignature: String
    let linkColor: UIColor
    let selectionTintColor: UIColor
    let widthPolicy: UnifiedTextWidthPolicy
    let allowsSelection: Bool
    let usesSharedMeasurementCache: Bool
    let preparationSource: String?
    let onBlankLongPress: ((CGPoint) -> Void)?
    let versionFlashContext: VersionFlashTextContext?
    let versionFlashSegmentIndex: Int?
    let onOpenURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let textView = GlyphSelectableTextView()
        textView.usesVisibleGlyphHitTesting = usesCompactBubbleHitTesting
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.tuneInitialSelectionLongPress(
            to: GlyphSelectableTextView.initialSelectionLongPressDuration
        )
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        configureVersionFlashTrace(
            for: textView,
            coordinator: context.coordinator
        )
        if let traceContext = versionFlashContext,
           let hostToken = context.coordinator.versionFlashHostToken {
            VersionFlashTrace.record(
                "TEXT_MAKE"
                    + " host=h\(hostToken)"
                    + " seg=\(versionFlashSegmentIndex.map { String($0) } ?? "nil")"
                    + " \(traceContext.traceSummary)"
            )
        }
        applyOrDeferInitialContent(to: textView, coordinator: context.coordinator)
        prepareCompactLayoutIfNeeded(
            for: textView,
            coordinator: context.coordinator
        )
        if usesCompactBubbleHitTesting {
            let host = CompactSelectableTextHostView(textView: textView)
            host.onBlankLongPress = onBlankLongPress
            return host
        }
        return textView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let textView = selectableTextView(in: uiView) else { return }
        context.coordinator.textView = textView
        textView.usesVisibleGlyphHitTesting = usesCompactBubbleHitTesting
        (uiView as? CompactSelectableTextHostView)?.onBlankLongPress = onBlankLongPress
        configureVersionFlashTrace(
            for: textView,
            coordinator: context.coordinator
        )
        applyOrDeferInitialContent(to: textView, coordinator: context.coordinator)
        prepareCompactLayoutIfNeeded(
            for: textView,
            coordinator: context.coordinator
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIView,
        context: Context
    ) -> CGSize? {
        guard let textView = selectableTextView(in: uiView) else { return nil }
        // A measured size is sufficient for an unattached duplicate host.
        // Real content is installed synchronously before the host is displayed.
        if canDeferInitialContent(in: textView, coordinator: context.coordinator),
           let width = proposal.width, width.isFinite, width > 0 {
            let displayScale = max(1, textView.traitCollection.displayScale)
            let pixelWidth = Int((width * displayScale).rounded())
            let key = "\(renderSignature)|width:\(pixelWidth)|scale:\(displayScale)"
            if let size = UnifiedTextMeasurementCache.shared.value(for: key) {
                return size
            }
        }
        apply(to: textView, coordinator: context.coordinator)
        let width: CGFloat
        switch widthPolicy {
        case .fill:
            guard let proposedWidth = proposal.width,
                  proposedWidth.isFinite,
                  proposedWidth > 0 else { return nil }
            width = max(1, proposedWidth)
        case let .fit(maximumWidth):
            let cap = max(1, maximumWidth)
            width = fittedWidth(
                for: textView,
                cap: cap,
                coordinator: context.coordinator
            )
        }

        return measuredLayoutSize(
            for: textView,
            width: width,
            coordinator: context.coordinator
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        selectableTextView(in: uiView)?.materializeInitialContent = nil
        guard let textView = selectableTextView(in: uiView),
              let traceContext = textView.versionFlashContext,
              let hostToken = textView.versionFlashHostToken else { return }
        VersionFlashTrace.record(
            "TEXT_DISMANTLE"
                + " host=h\(hostToken)"
                + " gen=\(textView.versionFlashGeneration)"
                + " seg=\(textView.versionFlashSegmentIndex.map { String($0) } ?? "nil")"
                + " len=\(textView.versionFlashUTF16Length)"
                + " \(traceContext.traceSummary)"
        )
    }

    private static func selectableTextView(in uiView: UIView) -> GlyphSelectableTextView? {
        if let textView = uiView as? GlyphSelectableTextView {
            return textView
        }
        return (uiView as? CompactSelectableTextHostView)?.textView
    }

    private func selectableTextView(in uiView: UIView) -> GlyphSelectableTextView? {
        Self.selectableTextView(in: uiView)
    }

    private func canDeferInitialContent(in textView: GlyphSelectableTextView, coordinator: Coordinator) -> Bool {
        guard case .fill = widthPolicy else { return false }
        return preparationSource != nil && usesSharedMeasurementCache
            && coordinator.appliedSignature == nil && textView.window == nil
    }

    private func applyOrDeferInitialContent(to textView: GlyphSelectableTextView, coordinator: Coordinator) {
        guard canDeferInitialContent(in: textView, coordinator: coordinator) else {
            apply(to: textView, coordinator: coordinator)
            return
        }
        textView.materializeInitialContent = { view in
            apply(to: view, coordinator: coordinator)
            let width = view.bounds.width
            if width.isFinite, width > 0 {
                // Also resolve view-specific rule attachments at the real width.
                _ = measuredLayoutSize(for: view, width: width, coordinator: coordinator)
            }
        }
    }

    private func configureVersionFlashTrace(
        for textView: GlyphSelectableTextView,
        coordinator: Coordinator
    ) {
        guard VersionFlashTrace.isEnabled else { return }
        guard versionFlashContext != nil || coordinator.versionFlashContext != nil else {
            return
        }
        if coordinator.versionFlashHostToken == nil {
            coordinator.versionFlashHostToken = VersionFlashTrace.allocateHostToken()
        }
        textView.configureVersionFlashTrace(
            hostToken: coordinator.versionFlashHostToken,
            context: versionFlashContext,
            segmentIndex: versionFlashSegmentIndex,
            generation: coordinator.versionFlashGeneration,
            utf16Length: textView.textStorage.length
        )
    }

    private func prepareCompactLayoutIfNeeded(
        for textView: GlyphSelectableTextView,
        coordinator: Coordinator
    ) {
        guard case let .fit(maximumWidth) = widthPolicy else { return }
        let preparationSignature = "\(renderSignature)|fit:\(maximumWidth)"
        guard coordinator.preparedCompactLayoutSignature != preparationSignature else { return }
        let width = fittedWidth(
            for: textView,
            cap: max(1, maximumWidth),
            coordinator: coordinator
        )
        _ = measuredLayoutSize(
            for: textView,
            width: width,
            coordinator: coordinator
        )
        coordinator.preparedCompactLayoutSignature = preparationSignature
    }

    private var usesCompactBubbleHitTesting: Bool {
        switch widthPolicy {
        case .fill:
            return false
        case .fit:
            return true
        }
    }

    private func measuredLayoutSize(
        for textView: GlyphSelectableTextView,
        width: CGFloat,
        coordinator: Coordinator
    ) -> CGSize {
        updateHorizontalRuleAttachments(in: textView, attachments: coordinator.horizontalRuleAttachments, width: width)

        let displayScale = max(1, textView.traitCollection.displayScale)
        let pixelWidth = Int((width * displayScale).rounded())
        let cacheKey = "\(renderSignature)|width:\(pixelWidth)|scale:\(displayScale)"
        if let localSize = coordinator.measuredLayoutSizes[cacheKey] {
            return localSize
        }
        if usesSharedMeasurementCache,
           let sharedSize = UnifiedTextMeasurementCache.shared.value(for: cacheKey) {
            coordinator.measuredLayoutSizes[cacheKey] = sharedSize
            return sharedSize
        }

        // Measure on a detached TextKit stack. The represented UITextView belongs
        // to SwiftUI, so sizeThatFits must not mutate its bounds or force its
        // attached layout/drawing tree through a full-document pass.
        let measurementStartedAt = ProcessInfo.processInfo.systemUptime
        let measurementStorage = NSTextStorage(attributedString: textView.attributedText)
        let measurementLayoutManager = NSLayoutManager()
        measurementLayoutManager.allowsNonContiguousLayout = false
        let measurementContainer = NSTextContainer(size: CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        measurementContainer.lineFragmentPadding = 0
        measurementContainer.lineBreakMode = .byWordWrapping
        measurementContainer.widthTracksTextView = false
        measurementStorage.addLayoutManager(measurementLayoutManager)
        measurementLayoutManager.addTextContainer(measurementContainer)
        measurementLayoutManager.ensureLayout(for: measurementContainer)
        let usedRect = measurementLayoutManager.usedRect(for: measurementContainer)
        // SwiftUI can contract a represented view by one display pixel while
        // reconciling the surrounding stack. Keep that pixel outside TextKit's
        // measured bottom so the final line fragment is not clipped initially.
        let hostLayoutPixel = 1 / displayScale
        let height = max(1, ceil(usedRect.maxY)) + hostLayoutPixel
        let measuredSize = CGSize(width: width, height: height)
        coordinator.measuredLayoutSizes[cacheKey] = measuredSize
        if usesSharedMeasurementCache {
            UnifiedTextMeasurementCache.shared.insert(measuredSize, for: cacheKey)
        }

        if MessageTextLayoutTrace.isEnabled {
            MessageTextLayoutTrace.log(
                "MEASURE signature=\(String(renderSignature.prefix(72)))"
                    + " utf16=\(textView.textStorage.length)"
                    + " width=\(String(format: "%.1f", width))"
                    + " usedMaxY=\(String(format: "%.1f", usedRect.maxY))"
                    + " returnedH=\(String(format: "%.1f", height))"
                    + " elapsedMs=\(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - measurementStartedAt) * 1_000))"
                    + " cache=miss"
            )
        }
        return measuredSize
    }

    private func fittedWidth(
        for textView: UITextView,
        cap: CGFloat,
        coordinator: Coordinator
    ) -> CGFloat {
        if !coordinator.horizontalRuleAttachments.isEmpty {
            return cap
        }
        if coordinator.naturalWidthSignature == renderSignature,
           let naturalWidth = coordinator.naturalTextWidth {
            return min(cap, naturalWidth)
        }

        let measurementWidth = max(4_096, cap)
        let measurementStorage = NSTextStorage(attributedString: textView.attributedText)
        let measurementLayoutManager = NSLayoutManager()
        measurementLayoutManager.allowsNonContiguousLayout = false
        let measurementContainer = NSTextContainer(size: CGSize(
            width: measurementWidth,
            height: CGFloat.greatestFiniteMagnitude
        ))
        measurementContainer.lineFragmentPadding = 0
        measurementContainer.lineBreakMode = .byWordWrapping
        measurementContainer.widthTracksTextView = false
        measurementStorage.addLayoutManager(measurementLayoutManager)
        measurementLayoutManager.addTextContainer(measurementContainer)
        measurementLayoutManager.ensureLayout(for: measurementContainer)
        let usedRect = measurementLayoutManager.usedRect(for: measurementContainer)
        let displayScale = max(1, textView.traitCollection.displayScale)
        let pixel = 1 / displayScale
        let naturalWidth = max(
            pixel,
            ceil(usedRect.maxX * displayScale) / displayScale + pixel
        )
        coordinator.naturalWidthSignature = renderSignature
        coordinator.naturalTextWidth = naturalWidth
        return min(cap, naturalWidth)
    }

    private func horizontalRuleAttachments(in textView: UITextView) -> [HorizontalRuleTextAttachment] {
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        var attachments: [HorizontalRuleTextAttachment] = []
        textView.textStorage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
            if let attachment = value as? HorizontalRuleTextAttachment {
                attachments.append(attachment)
            }
        }
        return attachments
    }

    private func apply(to textView: GlyphSelectableTextView, coordinator: Coordinator) {
        textView.materializeInitialContent = nil
        textView.isSelectable = allowsSelection
        textView.tintColor = selectionTintColor
        coordinator.onOpenURL = onOpenURL
        let signatureChanged = coordinator.appliedSignature != renderSignature
        let attributedText: NSAttributedString?
        if signatureChanged, let preparationSource {
            let traits = textView.traitCollection
            attributedText = SettledMarkdownPreparationCache.shared.prose(
                for: .init(signature: renderSignature, source: preparationSource,
                           interfaceStyle: traits.userInterfaceStyle, contrast: traits.accessibilityContrast),
                make: makeAttributedText
            )
        } else {
            attributedText = signatureChanged ? makeAttributedText() : nil
        }
        if VersionFlashTrace.isEnabled {
            prepareVersionFlashApply(
                to: textView,
                coordinator: coordinator,
                utf16Length: attributedText?.length ?? textView.textStorage.length
            )
        }
        guard let attributedText else { return }
        // Configure links while the first settled long-prose view is empty.
        // Applying link attributes after filling it can lay out the text again.
        let preparesInitialLinkStyle = coordinator.appliedSignature == nil && preparationSource != nil
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        if preparesInitialLinkStyle {
            textView.linkTextAttributes = linkAttributes
        }
        coordinator.appliedSignature = renderSignature
        coordinator.naturalWidthSignature = nil
        coordinator.naturalTextWidth = nil
        coordinator.measuredLayoutSizes.removeAll(keepingCapacity: true)
        textView.attributedText = attributedText
        coordinator.horizontalRuleAttachments = horizontalRuleAttachments(in: textView)
        if !preparesInitialLinkStyle {
            textView.linkTextAttributes = linkAttributes
        }
        textView.contentDidChangeForViewportDrawing()
        if VersionFlashTrace.isEnabled {
            finishVersionFlashApply(
                coordinator: coordinator,
                utf16Length: attributedText.length
            )
        }
    }

    private func prepareVersionFlashApply(
        to textView: GlyphSelectableTextView,
        coordinator: Coordinator,
        utf16Length: Int
    ) {
        let previousContext = coordinator.versionFlashContext
        let previousSegmentIndex = coordinator.versionFlashSegmentIndex
        guard versionFlashContext != nil || previousContext != nil else { return }
        if coordinator.versionFlashHostToken == nil {
            coordinator.versionFlashHostToken = VersionFlashTrace.allocateHostToken()
        }
        let signatureChanged = coordinator.appliedSignature != renderSignature
        let contextChanged = previousContext != versionFlashContext
            || previousSegmentIndex != versionFlashSegmentIndex
        if signatureChanged || contextChanged {
            coordinator.versionFlashGeneration &+= 1
        }
        textView.configureVersionFlashTrace(
            hostToken: coordinator.versionFlashHostToken,
            context: versionFlashContext,
            segmentIndex: versionFlashSegmentIndex,
            generation: coordinator.versionFlashGeneration,
            utf16Length: utf16Length
        )
        guard !signatureChanged else { return }
        if contextChanged, let hostToken = coordinator.versionFlashHostToken {
            VersionFlashTrace.record(
                "TEXT_REBIND"
                    + " host=h\(hostToken)"
                    + " gen=\(coordinator.versionFlashGeneration)"
                    + " oldMsg=\(previousContext.map { VersionFlashTrace.identifierToken($0.messageID) } ?? "nil")"
                    + " oldSeg=\(previousSegmentIndex.map { String($0) } ?? "nil")"
                    + " msg=\(versionFlashContext.map { VersionFlashTrace.identifierToken($0.messageID) } ?? "nil")"
                    + " seg=\(versionFlashSegmentIndex.map { String($0) } ?? "nil")"
                    + " len=\(utf16Length)"
            )
        }
        coordinator.versionFlashContext = versionFlashContext
        coordinator.versionFlashSegmentIndex = versionFlashSegmentIndex
        coordinator.versionFlashAppliedLength = utf16Length
    }

    private func finishVersionFlashApply(
        coordinator: Coordinator,
        utf16Length: Int
    ) {
        let previousContext = coordinator.versionFlashContext
        let previousSegmentIndex = coordinator.versionFlashSegmentIndex
        let previousLength = coordinator.versionFlashAppliedLength
        if let hostToken = coordinator.versionFlashHostToken,
           let traceContext = versionFlashContext ?? previousContext {
            VersionFlashTrace.record(
                "TEXT_APPLY"
                    + " host=h\(hostToken)"
                    + " oldGen=\(max(0, coordinator.versionFlashGeneration - 1))"
                    + " gen=\(coordinator.versionFlashGeneration)"
                    + " oldMsg=\(previousContext.map { VersionFlashTrace.identifierToken($0.messageID) } ?? "nil")"
                    + " oldSeg=\(previousSegmentIndex.map { String($0) } ?? "nil")"
                    + " oldLen=\(previousLength.map { String($0) } ?? "nil")"
                    + " newLen=\(utf16Length)"
                    + " \(traceContext.traceSummary)"
                    + " seg=\(versionFlashSegmentIndex.map { String($0) } ?? "nil")"
            )
        }
        coordinator.versionFlashContext = versionFlashContext
        coordinator.versionFlashSegmentIndex = versionFlashSegmentIndex
        coordinator.versionFlashAppliedLength = utf16Length
    }

    private func updateHorizontalRuleAttachments(
        in textView: UITextView,
        attachments: [HorizontalRuleTextAttachment],
        width: CGFloat
    ) {
        guard !attachments.isEmpty else { return }
        let fullRange = NSRange(location: 0, length: textView.textStorage.length)
        let displayScale = max(1, textView.traitCollection.displayScale)
        let pixel = 1 / displayScale
        let ruleWidth = max(pixel, floor(width * displayScale) / displayScale - pixel)
        var changed = false
        for attachment in attachments {
            let targetBounds = CGRect(x: 0, y: 4, width: ruleWidth, height: 1)
            guard abs(attachment.bounds.width - targetBounds.width) > 0.5
                    || abs(attachment.bounds.origin.y - targetBounds.origin.y) > 0.5
                    || abs(attachment.bounds.height - targetBounds.height) > 0.5 else { continue }
            attachment.bounds = targetBounds
            changed = true
        }
        if changed {
            textView.layoutManager.invalidateLayout(
                forCharacterRange: fullRange,
                actualCharacterRange: nil
            )
            textView.layoutManager.invalidateDisplay(forCharacterRange: fullRange)
            textView.setNeedsDisplay()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var versionFlashHostToken: Int?
        var versionFlashGeneration = 0
        var versionFlashContext: VersionFlashTextContext?
        var versionFlashSegmentIndex: Int?
        var versionFlashAppliedLength: Int?
        var appliedSignature: String?
        var naturalWidthSignature: String?
        var naturalTextWidth: CGFloat?
        var preparedCompactLayoutSignature: String?
        var measuredLayoutSizes: [String: CGSize] = [:]
        // References belong to the currently installed text, even on a size-cache hit.
        var horizontalRuleAttachments: [HorizontalRuleTextAttachment] = []
        weak var textView: GlyphSelectableTextView?
        var onOpenURL: ((URL) -> Void)?

        func textViewDidEndEditing(_ textView: UITextView) {
            (textView as? GlyphSelectableTextView)?.clearSelection(resign: false)
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            onOpenURL?(URL)
            return false
        }

    }
}

private final class CompactSelectableTextHostView: UIView {
    let textView: GlyphSelectableTextView
    private let blankOverlay: SelectableTextBlankOverlayView

    var onBlankLongPress: ((CGPoint) -> Void)? {
        didSet {
            blankOverlay.onLongPress = onBlankLongPress
        }
    }

    init(textView: GlyphSelectableTextView) {
        self.textView = textView
        blankOverlay = SelectableTextBlankOverlayView(textView: textView)
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        addSubview(textView)
        addSubview(blankOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        blankOverlay.frame = bounds
    }
}

private final class SelectableTextBlankOverlayView: UIView, UIGestureRecognizerDelegate {
    weak var textView: GlyphSelectableTextView?
    var onLongPress: ((CGPoint) -> Void)?

    init(textView: GlyphSelectableTextView) {
        self.textView = textView
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false

        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.5
        recognizer.allowableMovement = 10
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard onLongPress != nil,
              super.point(inside: point, with: event),
              let textView else { return false }
        return textView.isBlankReactionPoint(convert(point, to: textView))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onLongPress?(recognizer.location(in: window))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private final class MarkdownDecorationLayoutManager: NSLayoutManager {
    var usesDarkAppearance = false
    var permittedDrawingRect: CGRect?
    var messageTextTraceVisibleRect: CGRect = .null
    var messageTextTraceTextBounds: CGRect = .null
    var versionFlashHostToken: Int?
    var versionFlashContext: VersionFlashTextContext?
    var versionFlashSegmentIndex: Int?
    var versionFlashGeneration = 0
    var versionFlashUTF16Length = 0
    private var lastMessageTextDrawTraceKey: String?

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        let visibleGlyphs = viewportLimitedGlyphRange(glyphsToShow)
        recordMessageTextDrawTrace(
            proposedGlyphs: glyphsToShow,
            visibleGlyphs: visibleGlyphs
        )
        guard visibleGlyphs.length > 0 else { return }
        super.drawGlyphs(forGlyphRange: visibleGlyphs, at: origin)
        if let traceContext = versionFlashContext,
           let hostToken = versionFlashHostToken {
            VersionFlashTrace.recordOnce(
                "textDraw-\(hostToken)-\(versionFlashGeneration)",
                "TEXT_DRAW"
                    + " host=h\(hostToken)"
                    + " gen=\(versionFlashGeneration)"
                    + " seg=\(versionFlashSegmentIndex.map { String($0) } ?? "nil")"
                    + " len=\(versionFlashUTF16Length)"
                    + " glyphStart=\(visibleGlyphs.location)"
                    + " glyphLen=\(visibleGlyphs.length)"
                    + " \(traceContext.traceSummary)"
            )
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        let visibleGlyphs = viewportLimitedGlyphRange(glyphsToShow)
        guard visibleGlyphs.length > 0 else { return }
        guard let context = UIGraphicsGetCurrentContext() else {
            super.drawBackground(forGlyphRange: visibleGlyphs, at: origin)
            return
        }
        context.saveGState()
        drawInlineCodeBackgrounds(forGlyphRange: visibleGlyphs, at: origin)
        drawQuoteBars(forGlyphRange: visibleGlyphs, at: origin)
        context.restoreGState()
        super.drawBackground(forGlyphRange: visibleGlyphs, at: origin)
    }

    private func viewportLimitedGlyphRange(_ proposedRange: NSRange) -> NSRange {
        guard let viewportRect = permittedDrawingRect,
              let textContainer = textContainers.first else {
            return proposedRange
        }
        guard !viewportRect.isNull, !viewportRect.isEmpty else {
            return NSRange(location: proposedRange.location, length: 0)
        }

        let viewportGlyphs = glyphRange(
            forBoundingRect: viewportRect,
            in: textContainer
        )
        return NSIntersectionRange(proposedRange, viewportGlyphs)
    }

    private func recordMessageTextDrawTrace(
        proposedGlyphs: NSRange,
        visibleGlyphs: NSRange
    ) {
        guard MessageTextLayoutTrace.isEnabled else { return }
        let totalGlyphs = numberOfGlyphs
        let tailGlyph = totalGlyphs > 0 ? totalGlyphs - 1 : nil
        let proposedContainsTail = tailGlyph.map {
            NSLocationInRange($0, proposedGlyphs)
        } ?? false
        let visibleContainsTail = tailGlyph.map {
            NSLocationInRange($0, visibleGlyphs)
        } ?? false
        let tailShouldBeVisible = !messageTextTraceVisibleRect.isNull
            && !messageTextTraceTextBounds.isNull
            && messageTextTraceVisibleRect.maxY >= messageTextTraceTextBounds.maxY - 2

        guard tailShouldBeVisible || proposedContainsTail || visibleContainsTail else {
            return
        }

        let permittedRect = permittedDrawingRect ?? .infinite
        let traceKey = [
            MessageTextLayoutTrace.range(proposedGlyphs),
            MessageTextLayoutTrace.range(visibleGlyphs),
            String(totalGlyphs),
            MessageTextLayoutTrace.rect(messageTextTraceVisibleRect),
            MessageTextLayoutTrace.rect(permittedRect),
        ].joined(separator: "|")
        guard traceKey != lastMessageTextDrawTraceKey else { return }
        lastMessageTextDrawTraceKey = traceKey

        MessageTextLayoutTrace.log(
            "DRAW"
                + " lm=\(MessageTextLayoutTrace.objectToken(self))"
                + " totalGlyphs=\(totalGlyphs)"
                + " proposed=\(MessageTextLayoutTrace.range(proposedGlyphs))"
                + " limited=\(MessageTextLayoutTrace.range(visibleGlyphs))"
                + " proposedHasTail=\(proposedContainsTail)"
                + " limitedHasTail=\(visibleContainsTail)"
                + " tailShouldBeVisible=\(tailShouldBeVisible)"
                + " visible=\(MessageTextLayoutTrace.rect(messageTextTraceVisibleRect))"
                + " textBounds=\(MessageTextLayoutTrace.rect(messageTextTraceTextBounds))"
                + " permitted=\(MessageTextLayoutTrace.rect(permittedRect))"
        )
    }

    private func drawQuoteBars(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let textStorage, textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let color = UIColor.secondaryLabel.withAlphaComponent(usesDarkAppearance ? 0.48 : 0.36)

        textStorage.enumerateAttribute(.moccaQuoteBlock, in: fullRange) { value, range, _ in
            guard value is String else { return }
            let glyphRange = self.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0,
                  NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { return }

            let indent = (textStorage.attribute(
                .moccaQuoteIndent,
                at: range.location,
                effectiveRange: nil
            ) as? NSNumber)?.doubleValue ?? 0
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            self.enumerateLineFragments(forGlyphRange: glyphRange) {
                _, usedRect, _, lineGlyphRange, _ in
                guard NSIntersectionRange(glyphRange, lineGlyphRange).length > 0 else { return }
                minY = min(minY, usedRect.minY)
                maxY = max(maxY, usedRect.maxY)
            }
            guard minY.isFinite, maxY.isFinite, maxY > minY else { return }

            let blockRect = CGRect(
                x: origin.x + CGFloat(indent),
                y: origin.y + minY + 2,
                width: 3,
                height: max(3, maxY - minY - 4)
            )
            color.setFill()
            UIBezierPath(roundedRect: blockRect, cornerRadius: 1.5).fill()
        }
    }

    private func drawInlineCodeBackgrounds(
        forGlyphRange glyphsToShow: NSRange,
        at origin: CGPoint
    ) {
        guard let textStorage, textStorage.length > 0,
              let textContainer = textContainers.first else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let fillColor = usesDarkAppearance
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor(red: 241 / 255, green: 243 / 255, blue: 245 / 255, alpha: 1)
        let borderColor = usesDarkAppearance
            ? UIColor(red: 69 / 255, green: 70 / 255, blue: 79 / 255, alpha: 0.22)
            : UIColor(red: 198 / 255, green: 198 / 255, blue: 208 / 255, alpha: 0.22)

        textStorage.enumerateAttribute(.moccaInlineCode, in: fullRange) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphRange = self.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0,
                  NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { return }

            self.enumerateLineFragments(forGlyphRange: glyphRange) {
                _, _, _, lineGlyphRange, _ in
                let segmentRange = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard segmentRange.length > 0 else { return }
                var backgroundRect = self.boundingRect(
                    forGlyphRange: segmentRange,
                    in: textContainer
                )
                guard backgroundRect.width > 0, backgroundRect.height > 0 else { return }
                backgroundRect.origin.x += origin.x
                backgroundRect.origin.y += origin.y
                backgroundRect = backgroundRect.insetBy(dx: -3, dy: -2)

                let path = UIBezierPath(roundedRect: backgroundRect, cornerRadius: 6)
                fillColor.setFill()
                path.fill()
                borderColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }
}

/// A completed content layout can move unchanged prose into view without a
/// scroll or text-size event. Reuse the viewport coverage check once at landing.
@MainActor
enum MessageTextViewportDrawing {
    static func refreshAfterLayout(in view: UIView) {
        if let textView = view as? GlyphSelectableTextView {
            textView.refreshViewportDrawingAfterLayout()
            return
        }
        for subview in view.subviews {
            refreshAfterLayout(in: subview)
        }
    }
}

/// Experimental drawer lease for duplicate viewport notifications only. Native
/// scrolling, content changes and completed layout continue to refresh at once.
@MainActor
enum DrawerViewportRefreshFreeze {
    static let isEnabled = !ProcessInfo.processInfo.arguments.contains(
        "-disableDrawerViewportFreeze"
    )
    private static var dragging = false
    private static var settling = false
    private(set) static var generation: UInt64 = 0
    static var isActive: Bool { isEnabled && (dragging || settling) }
    private static let pending = NSHashTable<GlyphSelectableTextView>.weakObjects()

    static func setDragging(_ value: Bool) {
        let wasActive = isActive
        dragging = value
        finishTransition(from: wasActive)
    }

    static func setSettling(_ value: Bool) {
        let wasActive = isActive
        settling = value
        finishTransition(from: wasActive)
    }

    static func reset() {
        let wasActive = isActive
        dragging = false
        settling = false
        finishTransition(from: wasActive)
    }

    fileprivate static func deferRefresh(_ textView: GlyphSelectableTextView) {
        pending.add(textView)
    }

    fileprivate static func remove(_ textView: GlyphSelectableTextView) {
        pending.remove(textView)
    }

    private static func finishTransition(from wasActive: Bool) {
        guard wasActive != isActive else { return }
        if isActive {
            generation &+= 1
        } else {
            let views = pending.allObjects
            pending.removeAllObjects()
            for view in views { view.resumeDrawerViewportDrawing() }
        }
    }
}

private struct DrawerViewportRefreshKey: Equatable {
    let generation: UInt64
    let window: ObjectIdentifier
    let scrollView: ObjectIdentifier
    let textBounds: CGRect
    let textFrame: CGRect
    let scrollBounds: CGRect
    let contentOffset: CGPoint
    let contentSize: CGSize
    let adjustedContentInset: UIEdgeInsets
}

private final class GlyphSelectableTextView: UITextView {
    static let initialSelectionLongPressDuration: TimeInterval = 0.28
    private static let viewportOverscan: CGFloat = 720

    private var didTuneInitialSelectionLongPress = false
    private let decorationLayoutManager: MarkdownDecorationLayoutManager
    private weak var observedOuterScrollView: UIScrollView?
    private var scrollOffsetObservation: NSKeyValueObservation?
    private var scrollBoundsObservation: NSKeyValueObservation?
    private var coveredViewportRect: CGRect = .null
    private var lastLaidOutSize: CGSize = .zero
    private var lastMessageTextViewportTraceKey: String?
    private var drawerViewportRefreshKey: DrawerViewportRefreshKey?
    var usesVisibleGlyphHitTesting = false
    var materializeInitialContent: ((GlyphSelectableTextView) -> Void)?
    fileprivate var versionFlashHostToken: Int?
    fileprivate var versionFlashContext: VersionFlashTextContext?
    fileprivate var versionFlashSegmentIndex: Int?
    fileprivate var versionFlashGeneration = 0
    fileprivate var versionFlashUTF16Length = 0

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = MarkdownDecorationLayoutManager()
        let textContainer = NSTextContainer(size: .zero)
        decorationLayoutManager = layoutManager
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        super.init(frame: .zero, textContainer: textContainer)
        layoutManager.usesDarkAppearance = traitCollection.userInterfaceStyle == .dark
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachOuterScrollViewObservationIfNeeded()
        if lastLaidOutSize != bounds.size {
            lastLaidOutSize = bounds.size
            coveredViewportRect = .null
            invalidateViewportDrawingIfNeeded(force: true, reason: "layout-size")
        }
        let isDark = traitCollection.userInterfaceStyle == .dark
        guard decorationLayoutManager.usesDarkAppearance != isDark else { return }
        decorationLayoutManager.usesDarkAppearance = isDark
        let fullRange = NSRange(location: 0, length: textStorage.length)
        decorationLayoutManager.invalidateDisplay(forCharacterRange: fullRange)
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, let materialize = materializeInitialContent {
            materializeInitialContent = nil
            materialize(self)
        }
        recordVersionFlashLifecycle(
            "TEXT_WINDOW",
            attached: window != nil
        )
        if window != nil {
            DrawerTextSelectionInteractionGate.register(self)
            tuneInitialSelectionLongPress(to: Self.initialSelectionLongPressDuration)
            attachOuterScrollViewObservationIfNeeded()
            invalidateViewportDrawingIfNeeded(force: true, reason: "window-attach")
        } else {
            DrawerViewportRefreshFreeze.remove(self)
            drawerViewportRefreshKey = nil
            DrawerTextSelectionInteractionGate.unregister(self)
            detachOuterScrollViewObservation()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        attachOuterScrollViewObservationIfNeeded()
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        .zero
    }

    func contentDidChangeForViewportDrawing() {
        coveredViewportRect = .null
        decorationLayoutManager.permittedDrawingRect = .null
        invalidateViewportDrawingIfNeeded(force: true, reason: "content-change")
    }

    func configureVersionFlashTrace(
        hostToken: Int?,
        context: VersionFlashTextContext?,
        segmentIndex: Int?,
        generation: Int,
        utf16Length: Int
    ) {
        guard VersionFlashTrace.isEnabled else { return }
        versionFlashHostToken = hostToken
        versionFlashContext = context
        versionFlashSegmentIndex = segmentIndex
        versionFlashGeneration = generation
        versionFlashUTF16Length = utf16Length
        decorationLayoutManager.versionFlashHostToken = hostToken
        decorationLayoutManager.versionFlashContext = context
        decorationLayoutManager.versionFlashSegmentIndex = segmentIndex
        decorationLayoutManager.versionFlashGeneration = generation
        decorationLayoutManager.versionFlashUTF16Length = utf16Length
    }

    private func recordVersionFlashLifecycle(
        _ event: String,
        attached: Bool
    ) {
        guard let traceContext = versionFlashContext,
              let hostToken = versionFlashHostToken else { return }
        VersionFlashTrace.record(
            "\(event)"
                + " host=h\(hostToken)"
                + " attached=\(attached)"
                + " gen=\(versionFlashGeneration)"
                + " seg=\(versionFlashSegmentIndex.map { String($0) } ?? "nil")"
                + " len=\(versionFlashUTF16Length)"
                + " \(traceContext.traceSummary)"
        )
    }

    func refreshViewportDrawingAfterLayout() {
        invalidateViewportDrawingIfNeeded(force: false, reason: "content-layout")
    }

    func resumeDrawerViewportDrawing() {
        drawerViewportRefreshKey = nil
        invalidateViewportDrawingIfNeeded(force: false, reason: "drawer-resume")
    }

    private func currentDrawerViewportRefreshKey() -> DrawerViewportRefreshKey? {
        guard DrawerViewportRefreshFreeze.isActive,
              let window, let scrollView = observedOuterScrollView else { return nil }
        return DrawerViewportRefreshKey(
            generation: DrawerViewportRefreshFreeze.generation,
            window: ObjectIdentifier(window),
            scrollView: ObjectIdentifier(scrollView),
            textBounds: bounds,
            textFrame: frame,
            scrollBounds: scrollView.bounds,
            contentOffset: scrollView.contentOffset,
            contentSize: scrollView.contentSize,
            adjustedContentInset: scrollView.adjustedContentInset
        )
    }

    private func attachOuterScrollViewObservationIfNeeded() {
        let candidate = sequence(
            first: superview,
            next: { $0?.superview }
        )
        .compactMap { $0 as? UIScrollView }
        .first

        guard observedOuterScrollView !== candidate else { return }
        detachOuterScrollViewObservation()
        observedOuterScrollView = candidate
        guard let candidate else { return }

        scrollOffsetObservation = candidate.observe(
            \.contentOffset,
            options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.invalidateViewportDrawingIfNeeded(
                    force: false,
                    reason: "outer-content-offset"
                )
            }
        }
        scrollBoundsObservation = candidate.observe(
            \.bounds,
            options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.invalidateViewportDrawingIfNeeded(
                    force: false,
                    reason: "outer-bounds"
                )
            }
        }
        invalidateViewportDrawingIfNeeded(force: true, reason: "observer-attach")
    }

    private func detachOuterScrollViewObservation() {
        scrollOffsetObservation?.invalidate()
        scrollOffsetObservation = nil
        scrollBoundsObservation?.invalidate()
        scrollBoundsObservation = nil
        observedOuterScrollView = nil
        coveredViewportRect = .null
        drawerViewportRefreshKey = nil
    }

    private func invalidateViewportDrawingIfNeeded(
        force: Bool,
        reason: String
    ) {
        guard window != nil else {
            recordMessageTextViewportTrace(
                reason: reason,
                force: force,
                visibleRect: .null,
                decision: "skip-no-window"
            )
            return
        }
        let freezeKey = currentDrawerViewportRefreshKey()
        if !force,
           reason == "outer-content-offset" || reason == "outer-bounds",
           let freezeKey, drawerViewportRefreshKey == freezeKey {
            DrawerViewportRefreshFreeze.deferRefresh(self)
            return
        }
        let visibleRect = currentClippedVisibleRect()
        if MessageTextLayoutTrace.isEnabled {
            decorationLayoutManager.messageTextTraceVisibleRect = visibleRect.offsetBy(
                dx: -textContainerInset.left,
                dy: -textContainerInset.top
            )
            decorationLayoutManager.messageTextTraceTextBounds = bounds.offsetBy(
                dx: -textContainerInset.left,
                dy: -textContainerInset.top
            )
        }
        guard !visibleRect.isNull, !visibleRect.isEmpty else {
            drawerViewportRefreshKey = nil
            coveredViewportRect = .null
            decorationLayoutManager.permittedDrawingRect = .null
            recordMessageTextViewportTrace(
                reason: reason,
                force: force,
                visibleRect: visibleRect,
                decision: "clear-empty"
            )
            return
        }
        // Prepare horizontal coverage once before deferring notifications.
        // Closing exposes more of the real text; it must already be drawable.
        let requiredRect = freezeKey != nil
            ? CGRect(x: bounds.minX, y: visibleRect.minY,
                     width: bounds.width, height: visibleRect.height)
            : visibleRect
        drawerViewportRefreshKey = freezeKey
        if freezeKey != nil { DrawerViewportRefreshFreeze.deferRefresh(self) }
        guard force || !coveredViewportRect.contains(requiredRect) else {
            recordMessageTextViewportTrace(
                reason: reason,
                force: force,
                visibleRect: visibleRect,
                decision: "skip-contained"
            )
            return
        }

        let nextCoverage = requiredRect
            .insetBy(dx: 0, dy: -Self.viewportOverscan)
            .intersection(bounds)
        coveredViewportRect = nextCoverage
        decorationLayoutManager.permittedDrawingRect = nextCoverage.offsetBy(
            dx: -textContainerInset.left,
            dy: -textContainerInset.top
        )
        let fullRange = NSRange(location: 0, length: textStorage.length)
        decorationLayoutManager.invalidateDisplay(forCharacterRange: fullRange)
        setNeedsDisplay(nextCoverage)
        recordMessageTextViewportTrace(
            reason: reason,
            force: force,
            visibleRect: visibleRect,
            decision: "invalidate"
        )
    }

    private func recordMessageTextViewportTrace(
        reason: String,
        force: Bool,
        visibleRect: CGRect,
        decision: String
    ) {
        guard MessageTextLayoutTrace.isEnabled else { return }
        let tailShouldBeVisible = !visibleRect.isNull
            && !visibleRect.isEmpty
            && visibleRect.maxY >= bounds.maxY - 2
        guard force || tailShouldBeVisible || decision != "skip-contained" else {
            return
        }

        let outerOffset = observedOuterScrollView?.contentOffset ?? .zero
        let traceKey = [
            reason,
            String(force),
            decision,
            MessageTextLayoutTrace.rect(visibleRect),
            MessageTextLayoutTrace.rect(coveredViewportRect),
            MessageTextLayoutTrace.rect(
                decorationLayoutManager.permittedDrawingRect ?? .infinite
            ),
        ].joined(separator: "|")
        guard traceKey != lastMessageTextViewportTraceKey else { return }
        lastMessageTextViewportTraceKey = traceKey

        MessageTextLayoutTrace.log(
            "VIEWPORT"
                + " view=\(MessageTextLayoutTrace.objectToken(self))"
                + " lm=\(MessageTextLayoutTrace.objectToken(decorationLayoutManager))"
                + " reason=\(reason)"
                + " force=\(force)"
                + " decision=\(decision)"
                + " utf16=\(textStorage.length)"
                + " tailShouldBeVisible=\(tailShouldBeVisible)"
                + " visible=\(MessageTextLayoutTrace.rect(visibleRect))"
                + " bounds=\(MessageTextLayoutTrace.rect(bounds))"
                + " covered=\(MessageTextLayoutTrace.rect(coveredViewportRect))"
                + " permitted=\(MessageTextLayoutTrace.rect(decorationLayoutManager.permittedDrawingRect ?? .infinite))"
                + " outerOffset={x=\(String(format: "%.1f", outerOffset.x))"
                + " y=\(String(format: "%.1f", outerOffset.y))}"
        )
    }

    private func currentClippedVisibleRect() -> CGRect {
        guard let window else { return .null }
        var visibleRect = convert(window.bounds, from: window).intersection(bounds)
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds || view is UIScrollView {
                visibleRect = visibleRect.intersection(
                    convert(view.bounds, from: view)
                )
            }
            ancestor = view.superview
        }
        return visibleRect
    }

    func tuneInitialSelectionLongPress(to duration: TimeInterval) {
        guard !didTuneInitialSelectionLongPress else { return }
        let candidates = (gestureRecognizers ?? [])
            .compactMap { $0 as? UILongPressGestureRecognizer }
            .filter {
                $0.numberOfTouchesRequired == 1
                    && $0.numberOfTapsRequired == 0
                    && (0.45...0.60).contains($0.minimumPressDuration)
            }
        guard candidates.count == 1, let recognizer = candidates.first else { return }
        recognizer.minimumPressDuration = duration
        didTuneInitialSelectionLongPress = true
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        if selectedRange.length > 0, isPointNearSelection(point) {
            return true
        }
        return usesVisibleGlyphHitTesting
            ? isPointNearVisibleGlyph(point)
            : isPointNearGlyph(point)
    }

    func clearSelection(resign: Bool = true) {
        selectedRange = NSRange(location: 0, length: 0)
        if resign {
            resignFirstResponder()
        }
    }

    func isBlankReactionPoint(_ point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if selectedRange.length > 0, isPointNearSelection(point) {
            return false
        }
        return !isPointNearVisibleGlyph(point)
    }

    private func isPointNearGlyph(_ point: CGPoint) -> Bool {
        guard textStorage.length > 0 else { return false }
        layoutManager.ensureLayout(for: textContainer)

        let textPoint = CGPoint(
            x: point.x - textContainerInset.left,
            y: point.y - textContainerInset.top
        )
        guard textPoint.x >= 0,
              textPoint.y >= 0,
              textPoint.x <= textContainer.size.width else { return false }

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: textPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return false }

        var effectiveRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &effectiveRange
        )
        guard lineRect.insetBy(dx: -5, dy: -7).contains(textPoint) else { return false }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        return glyphRect.insetBy(dx: -4, dy: -7).contains(textPoint)
    }

    private func isPointNearVisibleGlyph(_ point: CGPoint) -> Bool {
        guard textStorage.length > 0 else { return false }
        layoutManager.ensureLayout(for: textContainer)

        let textPoint = CGPoint(
            x: point.x - textContainerInset.left,
            y: point.y - textContainerInset.top
        )
        guard textPoint.x >= 0,
              textPoint.y >= 0,
              textPoint.x <= textContainer.size.width else { return false }

        let horizontalTolerance: CGFloat = 5
        let verticalTolerance: CGFloat = 7
        let hitRect = CGRect(
            x: textPoint.x - horizontalTolerance,
            y: textPoint.y - verticalTolerance,
            width: horizontalTolerance * 2,
            height: verticalTolerance * 2
        )
        let candidateRange = layoutManager.glyphRange(
            forBoundingRect: hitRect,
            in: textContainer
        )
        guard candidateRange.length > 0 else { return false }

        let source = textStorage.string as NSString
        let upperBound = min(NSMaxRange(candidateRange), layoutManager.numberOfGlyphs)
        guard candidateRange.location < upperBound else { return false }

        for glyphIndex in candidateRange.location..<upperBound {
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if characterIndex < source.length {
                switch source.character(at: characterIndex) {
                case 0x000A, 0x000D, 0x2028, 0x2029:
                    continue
                default:
                    break
                }
            }

            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            guard glyphRect.width > 0, glyphRect.height > 0 else { continue }
            if glyphRect.insetBy(
                dx: -horizontalTolerance,
                dy: -verticalTolerance
            ).contains(textPoint) {
                return true
            }
        }
        return false
    }

    fileprivate func isPointNearSelection(_ point: CGPoint) -> Bool {
        guard let selectedTextRange else { return false }
        return selectionRects(for: selectedTextRange)
            .map { $0.rect.insetBy(dx: -24, dy: -24) }
            .contains { $0.contains(point) }
    }

    fileprivate var ownsCurrentSelectionTouch: Bool {
        guard window != nil, selectedRange.length > 0 else { return false }

        // The drawer recognizer lives above the UITextView in the UIKit view
        // hierarchy. Reading its live touch location makes this independent of
        // private selection-handle view or recognizer class names.
        var ancestor: UIView? = self
        while let current = ancestor {
            if (current.gestureRecognizers ?? []).contains(where: activeTouchIsNearSelection) {
                return true
            }
            ancestor = current.superview
        }
        return false
    }

    private func activeTouchIsNearSelection(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer.isEnabled, recognizer.numberOfTouches > 0 else { return false }
        switch recognizer.state {
        case .possible, .began, .changed:
            break
        case .ended, .cancelled, .failed:
            return false
        @unknown default:
            return false
        }
        return (0..<recognizer.numberOfTouches).contains { touchIndex in
            isPointNearSelection(recognizer.location(ofTouch: touchIndex, in: self))
        }
    }

}

private final class HorizontalRuleTextAttachment: NSTextAttachment {}

private extension NSAttributedString.Key {
    static let moccaQuoteBlock = NSAttributedString.Key("MoccaQuoteBlock")
    static let moccaQuoteIndent = NSAttributedString.Key("MoccaQuoteIndent")
    static let moccaInlineCode = NSAttributedString.Key("MoccaInlineCode")
}

private struct CitationMarkupToken {
    let marker: String
    let source: MessageCitationSource
}

private enum CitationMarkupResolver {
    private static let expression = try! NSRegularExpression(
        pattern: #"\[(?:citation|source)\]\s*\(([^\s\)]+)\)"#,
        options: [.caseInsensitive]
    )

    static func prepare(
        _ source: String,
        citationSources: [MessageCitationSource]
    ) -> (markdown: String, tokens: [CitationMarkupToken]) {
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = expression.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return (source, []) }

        var markdown = source
        var tokens: [CitationMarkupToken] = []
        var reservedMarkers = Set<Character>(source)

        for (offset, match) in matches.enumerated().reversed() {
            guard let destinationRange = Range(match.range(at: 1), in: source),
                  let matchRange = Range(match.range(at: 0), in: markdown) else {
                continue
            }
            let destination = String(source[destinationRange])
            let resolvedSource = citationSources.first(where: { $0.matches(destination: destination) })
                ?? placeholderSource(destination: destination, ordinal: offset, sources: citationSources)
                ?? fallbackSource(destination: destination, index: offset + 1)
            guard let resolvedSource else {
                // A model can cite a retained result from an older turn after
                // its source metadata has left the visible message window.
                // Never leak the orphan markup as a blue "citation" link.
                markdown.replaceSubrange(matchRange, with: "")
                continue
            }

            let marker = nextMarker(startingAt: offset, reserved: &reservedMarkers)
            markdown.replaceSubrange(matchRange, with: String(marker))
            tokens.append(CitationMarkupToken(marker: String(marker), source: resolvedSource))
        }
        return (markdown, tokens)
    }

    private static func placeholderSource(
        destination: String,
        ordinal: Int,
        sources: [MessageCitationSource]
    ) -> MessageCitationSource? {
        guard !sources.isEmpty else { return nil }
        let normalized = destination
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == "citation" || normalized == "source" else { return nil }
        return sources[min(ordinal, sources.count - 1)]
    }

    private static func fallbackSource(
        destination: String,
        index: Int
    ) -> MessageCitationSource? {
        guard let url = URL(string: destination),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return MessageCitationSource(
            index: index,
            providerID: "url-\(index)",
            title: "",
            url: url
        )
    }

    private static func nextMarker(
        startingAt offset: Int,
        reserved: inout Set<Character>
    ) -> Character {
        var scalarValue = UInt32(0xE100 + (offset % 0x0800))
        while let scalar = UnicodeScalar(scalarValue) {
            let candidate = Character(scalar)
            if reserved.insert(candidate).inserted {
                return candidate
            }
            scalarValue += 1
        }
        return "\u{E0FF}"
    }
}

private enum CitationPillRenderer {
    static func attributedString(
        for source: MessageCitationSource,
        favicon: UIImage?
    ) -> NSAttributedString {
        let image = pillImage(source: source, favicon: favicon)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: -4,
            width: image.size.width,
            height: image.size.height
        )
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(
            .link,
            value: source.url,
            range: NSRange(location: 0, length: result.length)
        )
        result.append(NSAttributedString(string: "\u{2009}"))
        return result
    }

    private static func pillImage(
        source: MessageCitationSource,
        favicon: UIImage?
    ) -> UIImage {
        let height: CGFloat = 22
        let iconSize: CGFloat = 14
        let horizontalPadding: CGFloat = 6
        let iconTextSpacing: CGFloat = 4
        let font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        let label = clippedSiteName(source.siteName)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.secondaryLabel
        ]
        let labelWidth = ceil((label as NSString).size(withAttributes: attributes).width)
        let width = horizontalPadding + iconSize + iconTextSpacing + labelWidth + horizontalPadding

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.tertiarySystemFill.setFill()
            UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: CGSize(width: width, height: height)),
                cornerRadius: height / 2
            ).fill()

            let iconRect = CGRect(
                x: horizontalPadding,
                y: (height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            if let favicon {
                context.cgContext.saveGState()
                UIBezierPath(ovalIn: iconRect).addClip()
                favicon.draw(in: iconRect)
                context.cgContext.restoreGState()
            } else if let globe = UIImage(systemName: "globe")?.withTintColor(
                .secondaryLabel,
                renderingMode: .alwaysOriginal
            ) {
                globe.draw(in: iconRect.insetBy(dx: 0.5, dy: 0.5))
            }

            let labelRect = CGRect(
                x: iconRect.maxX + iconTextSpacing,
                y: (height - font.lineHeight) / 2,
                width: labelWidth,
                height: font.lineHeight
            )
            (label as NSString).draw(in: labelRect, withAttributes: attributes)
        }
    }

    private static func clippedSiteName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 22 else { return cleaned.isEmpty ? ErrorLocalization.lookup("来源") : cleaned }
        return String(cleaned.prefix(20)) + "…"
    }
}

private enum UnifiedSelectableProseBuilder {
    private static let horizontalRuleLightImage = solidImage(
        color: UIColor(red: 198 / 255, green: 198 / 255, blue: 208 / 255, alpha: 0.40)
    )
    private static let horizontalRuleDarkImage = solidImage(
        color: UIColor(red: 69 / 255, green: 70 / 255, blue: 79 / 255, alpha: 0.40)
    )

    static func makePlainText(
        _ text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        textColor: UIColor,
        fontName: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: AppFontStore.uiFont(postScriptName: fontName, size: fontSize),
                .foregroundColor: textColor
            ]
        )
        guard result.length > 0 else { return result }
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle(lineSpacing: lineSpacing, paragraphSpacing: 0),
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    static func makeAttributedText(
        blocks: [MarkdownRenderBlock],
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        listItemSpacing: CGFloat,
        blockSpacingScale: CGFloat,
        textColor: UIColor,
        largeHeadingColor: UIColor?,
        smallHeadingColor: UIColor?,
        fontName: String?,
        citationSources: [MessageCitationSource] = [],
        citationFavicons: [String: UIImage] = [:]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = AppFontStore.uiFont(postScriptName: fontName, size: fontSize)
        let resolvedBlockSpacingScale = min(max(blockSpacingScale, 0.5), 1.5)

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: textColor
                        ]
                    )
                )
            }

            switch block.kind {
            case let .text(value):
                result.append(
                    inlineText(
                        value,
                        baseFont: baseFont,
                        fontName: fontName,
                        lineSpacing: lineSpacing,
                        paragraphSpacing: scaledBlockSpacing(
                            MarkdownReadingRhythm.bodyBlockSpacing,
                            scale: resolvedBlockSpacingScale
                        ),
                        textColor: textColor,
                        citationSources: citationSources,
                        citationFavicons: citationFavicons
                    )
                )

            case let .heading(level, value):
                let weight = headingWeight(level: level)
                let headingFont = AppFontStore.uiFont(
                    postScriptName: fontName,
                    size: headingSize(level: level, baseFontSize: fontSize),
                    weight: weight
                )
                result.append(
                    inlineText(
                        value,
                        baseFont: headingFont,
                        fontName: fontName,
                        baseWeight: weight,
                        lineSpacing: lineSpacing,
                        paragraphSpacing: scaledBlockSpacing(
                            MarkdownReadingRhythm.headingBlockSpacing,
                            scale: resolvedBlockSpacingScale
                        ),
                        textColor: (level <= 2 ? largeHeadingColor : smallHeadingColor) ?? textColor,
                        citationSources: citationSources,
                        citationFavicons: citationFavicons
                    )
                )

            case let .list(entries):
                appendList(
                    entries,
                    blockIdentifier: index,
                    to: result,
                    baseFont: baseFont,
                    fontName: fontName,
                    lineSpacing: lineSpacing,
                    listItemSpacing: listItemSpacing,
                    blockSpacingScale: resolvedBlockSpacingScale,
                    textColor: textColor,
                    citationSources: citationSources,
                    citationFavicons: citationFavicons
                )

            case let .quote(value):
                appendQuote(
                    value,
                    identifier: "quote-\(index)",
                    paragraphSpacing: scaledBlockSpacing(
                        MarkdownReadingRhythm.quoteBlockSpacing,
                        scale: resolvedBlockSpacingScale
                    ),
                    to: result,
                    baseFont: baseFont,
                    fontName: fontName,
                    lineSpacing: lineSpacing,
                    textColor: textColor,
                    citationSources: citationSources,
                    citationFavicons: citationFavicons
                )

            case .horizontalRule:
                appendHorizontalRule(
                    to: result,
                    baseFont: baseFont,
                    verticalSpacing: scaledBlockSpacing(
                        MarkdownReadingRhythm.horizontalRuleVerticalSpacing,
                        scale: resolvedBlockSpacingScale
                    )
                )

            case .code, .table:
                break
            }
        }

        return result
    }

    private static func appendList(
        _ entries: [MarkdownListEntry],
        blockIdentifier: Int,
        to result: NSMutableAttributedString,
        baseFont: UIFont,
        fontName: String?,
        lineSpacing: CGFloat,
        listItemSpacing: CGFloat,
        blockSpacingScale: CGFloat,
        textColor: UIColor,
        citationSources: [MessageCitationSource],
        citationFavicons: [String: UIImage]
    ) {
        let markerLeadingPadding: CGFloat = 6
        let unorderedMarkerTrailingPadding: CGFloat = 3
        let orderedMarkerTrailingPadding: CGFloat = 6
        let widestOrderedMarkerWidth = entries.reduce(CGFloat.zero) { width, entry in
            guard entry.isOrdered else { return width }
            let markerWidth = (entry.marker as NSString).size(
                withAttributes: [.font: baseFont]
            ).width
            return max(width, ceil(markerWidth))
        }

        for (index, entry) in entries.enumerated() {
            let measuredMarkerWidth = (entry.marker as NSString).size(
                withAttributes: [.font: baseFont]
            ).width
            let markerWidth = entry.isOrdered
                ? widestOrderedMarkerWidth
                : ceil(measuredMarkerWidth)
            let markerTrailingPadding = entry.isOrdered
                ? orderedMarkerTrailingPadding
                : unorderedMarkerTrailingPadding
            let markerColumnWidth = markerLeadingPadding + markerWidth + markerTrailingPadding

            if index > 0 {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: textColor
                        ]
                    )
                )
            }

            let line = NSMutableAttributedString(
                string: "\(entry.marker)\t",
                attributes: [
                    .font: baseFont,
                    .foregroundColor: textColor
                ]
            )
            line.append(
                inlineText(
                    entry.content,
                    baseFont: baseFont,
                    fontName: fontName,
                    lineSpacing: lineSpacing,
                    paragraphSpacing: 0,
                    textColor: textColor,
                    citationSources: citationSources,
                    citationFavicons: citationFavicons
                )
            )

            let style = paragraphStyle(
                lineSpacing: lineSpacing,
                paragraphSpacing: entry.nestedQuoteLines.isEmpty
                    ? (index == entries.count - 1
                        ? scaledBlockSpacing(MarkdownReadingRhythm.listBlockSpacing, scale: blockSpacingScale)
                        : lineSpacing + listItemSpacing)
                    : 0
            )
            style.firstLineHeadIndent = markerLeadingPadding
            style.headIndent = markerColumnWidth
            style.tabStops = [
                NSTextTab(
                    textAlignment: .left,
                    location: markerColumnWidth,
                    options: [:]
                )
            ]
            style.defaultTabInterval = markerColumnWidth
            line.addAttribute(
                .paragraphStyle,
                value: style,
                range: NSRange(location: 0, length: line.length)
            )
            result.append(line)

            if !entry.nestedQuoteLines.isEmpty {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [
                            .font: baseFont,
                            .foregroundColor: textColor
                        ]
                    )
                )
                appendQuote(
                    entry.nestedQuoteLines.joined(separator: "\n"),
                    identifier: "list-\(blockIdentifier)-\(index)-quote",
                    leadingIndent: markerColumnWidth,
                    paragraphSpacing: index == entries.count - 1
                        ? scaledBlockSpacing(MarkdownReadingRhythm.listBlockSpacing, scale: blockSpacingScale)
                        : lineSpacing + listItemSpacing,
                    to: result,
                    baseFont: baseFont,
                    fontName: fontName,
                    lineSpacing: lineSpacing,
                    textColor: textColor,
                    citationSources: citationSources,
                    citationFavicons: citationFavicons
                )
            }
        }
    }

    private static func appendQuote(
        _ source: String,
        identifier: String,
        leadingIndent: CGFloat = 0,
        paragraphSpacing: CGFloat = MarkdownReadingRhythm.quoteBlockSpacing,
        to result: NSMutableAttributedString,
        baseFont: UIFont,
        fontName: String?,
        lineSpacing: CGFloat,
        textColor: UIColor,
        citationSources: [MessageCitationSource],
        citationFavicons: [String: UIImage]
    ) {
        let quote = inlineText(
            source,
            baseFont: baseFont,
            fontName: fontName,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            textColor: textColor,
            citationSources: citationSources,
            citationFavicons: citationFavicons
        )
        let fullRange = NSRange(location: 0, length: quote.length)
        guard fullRange.length > 0 else { return }
        let style = paragraphStyle(lineSpacing: lineSpacing, paragraphSpacing: 0)
        style.firstLineHeadIndent = leadingIndent + 13
        style.headIndent = leadingIndent + 13
        quote.addAttributes(
            [
                .paragraphStyle: style,
                .moccaQuoteBlock: identifier,
                .moccaQuoteIndent: leadingIndent
            ],
            range: fullRange
        )
        let finalParagraphRange = (quote.string as NSString).paragraphRange(
            for: NSRange(location: max(0, quote.length - 1), length: 0)
        )
        let finalStyle = style.mutableCopy() as! NSMutableParagraphStyle
        finalStyle.paragraphSpacing = max(0, paragraphSpacing - lineSpacing)
        quote.addAttribute(.paragraphStyle, value: finalStyle, range: finalParagraphRange)
        result.append(quote)
    }

    private static func appendHorizontalRule(
        to result: NSMutableAttributedString,
        baseFont: UIFont,
        verticalSpacing: CGFloat
    ) {
        let attachment = HorizontalRuleTextAttachment()
        attachment.image = UITraitCollection.current.userInterfaceStyle == .dark
            ? horizontalRuleDarkImage
            : horizontalRuleLightImage
        attachment.bounds = CGRect(x: 0, y: 4, width: 1, height: 1)
        let rule = NSMutableAttributedString(attachment: attachment)
        let style = paragraphStyle(
            lineSpacing: 0,
            paragraphSpacing: verticalSpacing
        )
        style.paragraphSpacingBefore = verticalSpacing
        rule.addAttributes(
            [
                .font: baseFont,
                .paragraphStyle: style
            ],
            range: NSRange(location: 0, length: rule.length)
        )
        result.append(rule)
    }

    private static func scaledBlockSpacing(_ spacing: CGFloat, scale: CGFloat) -> CGFloat {
        spacing * min(max(scale, 0.5), 1.5)
    }

    private static func solidImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private static func inlineText(
        _ source: String,
        baseFont: UIFont,
        fontName: String?,
        baseWeight: UIFont.Weight = .regular,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        textColor: UIColor,
        citationSources: [MessageCitationSource],
        citationFavicons: [String: UIImage]
    ) -> NSMutableAttributedString {
        let prepared = CitationMarkupResolver.prepare(
            source,
            citationSources: citationSources
        )
        let rendered = NSMutableAttributedString(
            attributedString: NSAttributedString(
                MarkdownRenderCache.attributedText(for: prepared.markdown)
            )
        )

        for token in prepared.tokens {
            let range = (rendered.string as NSString).range(of: token.marker)
            guard range.location != NSNotFound else { continue }
            rendered.replaceCharacters(
                in: range,
                with: CitationPillRenderer.attributedString(
                    for: token.source,
                    favicon: citationFavicons[token.source.faviconKey]
                )
            )
        }
        let fullRange = NSRange(location: 0, length: rendered.length)
        guard fullRange.length > 0 else { return rendered }

        rendered.addAttributes(
            [
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle(
                    lineSpacing: lineSpacing,
                    paragraphSpacing: 0
                )
            ],
            range: fullRange
        )
        if paragraphSpacing > 0 {
            let finalParagraphRange = (rendered.string as NSString).paragraphRange(
                for: NSRange(location: max(0, rendered.length - 1), length: 0)
            )
            rendered.addAttribute(
                .paragraphStyle,
                value: paragraphStyle(
                    lineSpacing: lineSpacing,
                    paragraphSpacing: paragraphSpacing
                ),
                range: finalParagraphRange
            )
        }
        applyBaseFont(baseFont, to: rendered, range: fullRange)
        applySyntheticWeight(
            fontName: fontName,
            resolvedFont: baseFont,
            weight: baseWeight,
            to: rendered,
            range: fullRange
        )
        applyInlinePresentationStyles(
            baseFont,
            to: rendered,
            range: fullRange
        )
        return rendered
    }

    private static func applySyntheticWeight(
        fontName: String?,
        resolvedFont: UIFont,
        weight: UIFont.Weight,
        to text: NSMutableAttributedString,
        range: NSRange
    ) {
        guard let strokeWidth = AppFontStore.syntheticStrokeWidth(
            postScriptName: fontName,
            resolvedFont: resolvedFont,
            weight: weight
        ) else { return }
        text.addAttribute(.strokeWidth, value: strokeWidth, range: range)
    }

    private static func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = max(0, paragraphSpacing - lineSpacing)
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func applyBaseFont(
        _ baseFont: UIFont,
        to text: NSMutableAttributedString,
        range: NSRange
    ) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let existingFont = value as? UIFont else {
                text.addAttribute(.font, value: baseFont, range: subrange)
                return
            }
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(
                existingFont.fontDescriptor.symbolicTraits
            ) ?? baseFont.fontDescriptor
            text.addAttribute(
                .font,
                value: UIFont(descriptor: descriptor, size: baseFont.pointSize),
                range: subrange
            )
        }
    }

    private static func applyInlinePresentationStyles(
        _ baseFont: UIFont,
        to text: NSMutableAttributedString,
        range: NSRange
    ) {
        let intentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        var resolvedCodeRanges: [NSRange] = []
        text.enumerateAttribute(intentKey, in: range) { value, subrange, _ in
            guard let rawValue = inlinePresentationIntentRawValue(value) else { return }

            if rawValue & 4 != 0 {
                let weight: UIFont.Weight = rawValue & 2 != 0 ? .semibold : .regular
                applyInlineCodeStyle(
                    baseFont: baseFont,
                    weight: weight,
                    to: text,
                    range: subrange
                )
                resolvedCodeRanges.append(subrange)
            } else {
                let isBold = rawValue & 2 != 0
                let presentationFont = inlinePresentationFont(
                    baseFont: baseFont,
                    isItalic: rawValue & 1 != 0,
                    isBold: isBold
                )
                text.addAttribute(
                    .font,
                    value: presentationFont,
                    range: subrange
                )
            }

            if rawValue & 32 != 0 {
                text.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: subrange
                )
            }
        }

        // Inline-code intent has already been translated into concrete UIKit
        // attributes. Leaving the semantic intent attached gives TextKit a
        // second chance to reinterpret the run and replace our glyph fonts.
        for codeRange in resolvedCodeRanges {
            text.removeAttribute(intentKey, range: codeRange)
            text.removeAttribute(.strokeWidth, range: codeRange)
        }
    }

    private static func applyInlineCodeStyle(
        baseFont: UIFont,
        weight: UIFont.Weight,
        to text: NSMutableAttributedString,
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        let legacyInlineCodeScale: CGFloat = 13 / 15.7
        let codeSize = baseFont.pointSize * legacyInlineCodeScale
        let monospacedFont = UIFont.monospacedSystemFont(
            ofSize: codeSize,
            weight: weight
        )

        text.addAttribute(.font, value: monospacedFont, range: range)

        // Resolve the actual glyph-bearing font instead of assigning another
        // system descriptor and relying on TextKit to perform a second
        // fallback. This produces PingFang for CJK and Apple Color Emoji for
        // emoji while preserving SF Mono for ASCII code.
        let source = text.string as NSString
        let coreTextBaseFont = monospacedFont as CTFont
        let upperBound = NSMaxRange(range)
        var cursor = range.location
        while cursor < upperBound {
            let composedRange = source.rangeOfComposedCharacterSequence(at: cursor)
            let clippedRange = NSIntersectionRange(composedRange, range)
            if clippedRange.location != NSNotFound,
               clippedRange.length > 0 {
                let fragment = source.substring(with: clippedRange)
                if fragment.unicodeScalars.contains(
                   where: { $0.value > 0x7F }
                ) {
                    let coreTextFragment = fragment as CFString
                    let resolvedFont = CTFontCreateForString(
                        coreTextBaseFont,
                        coreTextFragment,
                        CFRange(
                            location: 0,
                            length: CFStringGetLength(coreTextFragment)
                        )
                    ) as UIFont
                    text.addAttribute(.font, value: resolvedFont, range: clippedRange)
                }
            }

            let nextCursor = NSMaxRange(composedRange)
            guard nextCursor > cursor else { break }
            cursor = nextCursor
        }

        text.addAttribute(
            .moccaInlineCode,
            value: true,
            range: range
        )
    }

    private static func inlinePresentationFont(
        baseFont: UIFont,
        isItalic: Bool,
        isBold: Bool
    ) -> UIFont {
        var descriptor = baseFont.fontDescriptor

        if isBold {
            var traits = descriptor.symbolicTraits
            traits.insert(.traitBold)
            descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        }

        if isItalic {
            if baseFont.fontDescriptor.symbolicTraits.contains(.traitItalic) {
                var traits = descriptor.symbolicTraits
                traits.insert(.traitItalic)
                descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
            } else {
                // CJK system fallbacks and many imported fonts do not provide
                // an italic face. A small synthetic oblique keeps Markdown
                // emphasis visible without changing the surrounding font.
                descriptor = descriptor.withMatrix(
                    CGAffineTransform(a: 1, b: 0, c: 0.20, d: 1, tx: 0, ty: 0)
                )
            }
        }

        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }

    private static func inlinePresentationIntentRawValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }

    private static func headingSize(level: Int, baseFontSize: CGFloat) -> CGFloat {
        let legacyBaseSize: CGFloat
        switch level {
        case 1: legacyBaseSize = 26
        case 2: legacyBaseSize = 22
        case 3: legacyBaseSize = 20
        case 4: legacyBaseSize = 16
        case 5: legacyBaseSize = 15
        default: legacyBaseSize = 14
        }
        return legacyBaseSize * (baseFontSize / 15.7)
    }

    private static func headingWeight(level: Int) -> UIFont.Weight {
        switch level {
        case 1: .bold
        case 2, 3: .semibold
        default: .medium
        }
    }
}

private struct MarkdownTextBlock: View {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let isUserMessage: Bool
    let allowsTextSelection: Bool
    var foregroundColor: Color = .primary
    var fontName: String?
    var usesCache = true

    private var attributedText: AttributedString {
        usesCache
            ? MarkdownRenderCache.attributedText(for: text)
            : MarkdownRenderCache.makeAttributedText(for: text)
    }

    var body: some View {
        Text(attributedText)
            .font(
                AppFontStore.swiftUIFont(
                    postScriptName: fontName,
                    size: fontSize,
                    fixedCustomSize: isUserMessage
                )
            )
            .lineSpacing(lineSpacing)
            .foregroundStyle(foregroundColor)
            .tint(isUserMessage ? .primary : .accentColor)
            .controlledTextSelection(allowsTextSelection)
    }
}

private struct MarkdownHeadingBlock: View {
    let level: Int
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let isUserMessage: Bool
    let allowsTextSelection: Bool
    let foregroundColor: Color
    let fontName: String?
    let usesCache: Bool

    private var headingSize: CGFloat {
        let legacyBaseSize: CGFloat
        switch level {
        case 1: legacyBaseSize = 26
        case 2: legacyBaseSize = 22
        case 3: legacyBaseSize = 20
        case 4: legacyBaseSize = 16
        case 5: legacyBaseSize = 15
        default: legacyBaseSize = 14
        }
        return legacyBaseSize * (fontSize / 15.7)
    }

    private var attributedText: AttributedString {
        usesCache
            ? MarkdownRenderCache.attributedText(for: text)
            : MarkdownRenderCache.makeAttributedText(for: text)
    }

    private var headingWeight: Font.Weight {
        switch level {
        case 1: .bold
        case 2, 3: .semibold
        default: .medium
        }
    }

    var body: some View {
        Text(attributedText)
            .font(
                AppFontStore.swiftUIFont(
                    postScriptName: fontName,
                    size: headingSize,
                    weight: headingWeight,
                    fixedCustomSize: isUserMessage
                )
            )
            .lineSpacing(lineSpacing)
            .foregroundStyle(foregroundColor)
            .tint(isUserMessage ? .primary : .accentColor)
            .controlledTextSelection(allowsTextSelection)
            .padding(.vertical, 2)
    }
}

private struct MarkdownListBlock: View {
    let entries: [MarkdownListEntry]
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let isUserMessage: Bool
    let allowsTextSelection: Bool
    let foregroundColor: Color
    let fontName: String?
    let usesCache: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(entry.marker)
                        .font(
                            AppFontStore.swiftUIFont(
                                postScriptName: fontName,
                                size: fontSize,
                                fixedCustomSize: isUserMessage
                            )
                        )
                        .foregroundStyle(foregroundColor)
                        .frame(minWidth: entry.isOrdered ? 23 : 12, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownTextBlock(
                            text: entry.content,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing,
                            isUserMessage: isUserMessage,
                            allowsTextSelection: allowsTextSelection,
                            foregroundColor: foregroundColor,
                            fontName: fontName,
                            usesCache: usesCache
                        )
                        if !entry.nestedQuoteLines.isEmpty {
                            MarkdownQuoteBlock(
                                text: entry.nestedQuoteLines.joined(separator: "\n"),
                                fontSize: fontSize,
                                lineSpacing: lineSpacing,
                                isUserMessage: isUserMessage,
                                allowsTextSelection: allowsTextSelection,
                                foregroundColor: foregroundColor,
                                fontName: fontName,
                                usesCache: usesCache
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct MarkdownQuoteBlock: View {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let isUserMessage: Bool
    let allowsTextSelection: Bool
    let foregroundColor: Color
    let fontName: String?
    let usesCache: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.36))
                .frame(width: 3)
                .padding(.vertical, 2)

            MarkdownTextBlock(
                text: text,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                isUserMessage: isUserMessage,
                allowsTextSelection: allowsTextSelection,
                foregroundColor: foregroundColor,
                fontName: fontName,
                usesCache: usesCache
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownHorizontalRule: View {
    var body: some View {
        Rectangle()
            .fill(
                Color(
                    uiColor: UIColor { traits in
                        if traits.userInterfaceStyle == .dark {
                            return UIColor(
                                red: 69 / 255,
                                green: 70 / 255,
                                blue: 79 / 255,
                                alpha: 0.40
                            )
                        }
                        return UIColor(
                            red: 198 / 255,
                            green: 198 / 255,
                            blue: 208 / 255,
                            alpha: 0.40
                        )
                    }
                )
            )
            .frame(height: 1)
            .padding(.vertical, MarkdownReadingRhythm.horizontalRuleVerticalSpacing)
    }
}

private struct MarkdownTableBlock: View {
    let table: MarkdownTableContent
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let allowsTextSelection: Bool
    let fontName: String?
    let usesCache: Bool

    private static let headerBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1)
            : UIColor(white: 0.94, alpha: 1)
    }

    private static let evenRowBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1)
            : UIColor(white: 1.00, alpha: 1)
    }

    private static let oddRowBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.14, alpha: 1)
            : UIColor(red: 250 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1)
    }

    private static let separator = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.30, alpha: 1)
            : UIColor(white: 0.84, alpha: 1)
    }

    private var tableFontSize: CGFloat {
        min(max(fontSize - 1.5, 13), 18)
    }

    private var measuredColumnWidths: [CGFloat] {
        let horizontalPadding: CGFloat = 28
        let maximumColumnWidth: CGFloat = 260
        let baseFont = AppFontStore.uiFont(
            postScriptName: fontName,
            size: tableFontSize
        )
        let headerFont = AppFontStore.uiFont(
            postScriptName: fontName,
            size: tableFontSize,
            weight: .semibold
        )
        let measure = { [self] in
            table.header.indices.map { columnIndex in
                var widest = measuredWidth(table.header[columnIndex], font: headerFont)
                for row in table.rows where columnIndex < row.count {
                    // Later cells cannot widen a column already at the display cap.
                    if ceil(widest) + horizontalPadding >= maximumColumnWidth { break }
                    widest = max(widest, measuredWidth(row[columnIndex], font: baseFont))
                }
                return min(max(ceil(widest) + horizontalPadding, 96), maximumColumnWidth)
            }
        }
        guard usesCache, table.rows.count >= 24 else { return measure() }
        return SettledMarkdownPreparationCache.shared.columnWidths(
            for: .init(font: baseFont, headerFont: headerFont, table: table), make: measure
        )
    }

    var body: some View {
        let columnWidths = measuredColumnWidths
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 0.5, verticalSpacing: 0.5) {
                GridRow(alignment: .top) {
                    ForEach(Array(table.header.indices), id: \.self) { columnIndex in
                        cell(
                            table.header[columnIndex],
                            columnIndex: columnIndex,
                            columnWidth: columnWidths[columnIndex],
                            rowIndex: nil,
                            isHeader: true
                        )
                    }
                }
                .font(
                    AppFontStore.swiftUIFont(
                        postScriptName: fontName,
                        size: tableFontSize,
                        weight: .semibold
                    )
                )

                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow(alignment: .top) {
                        ForEach(Array(table.header.indices), id: \.self) { columnIndex in
                            cell(
                                columnIndex < row.count ? row[columnIndex] : "",
                                columnIndex: columnIndex,
                                columnWidth: columnWidths[columnIndex],
                                rowIndex: rowIndex,
                                isHeader: false
                            )
                        }
                    }
                }
            }
            // All cells share these text settings. Apply them once to the
            // table, with only the header row overriding the font weight.
            .font(AppFontStore.swiftUIFont(postScriptName: fontName, size: tableFontSize))
            .lineSpacing(lineSpacing)
            .lineLimit(nil)
            .foregroundStyle(Color(uiColor: .label))
            .tint(Color(uiColor: .link))
            // Keep flexible cells at their natural row heights on the non-scrolling axis.
            .fixedSize(horizontal: false, vertical: true)
            .padding(0.5)
            .background(Color(uiColor: Self.separator))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(uiColor: Self.separator), lineWidth: 0.5)
            }
            .background(DrawerHorizontalScrollProbe())
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.lookup("Markdown 表格"))
    }

    private func cell(
        _ source: String,
        columnIndex: Int,
        columnWidth: CGFloat,
        rowIndex: Int?,
        isHeader: Bool
    ) -> some View {
        let attributedText = usesCache
            ? MarkdownRenderCache.attributedText(for: source)
            : MarkdownRenderCache.makeAttributedText(for: source)
        let alignment = table.alignments[columnIndex]
        let contentWidth = max(56, columnWidth - 24)

        return Text(attributedText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(textAlignment(for: alignment))
            // A table cell is the visible interaction unit. Keep its menu tied
            // to the complete source text instead of presenting a selection
            // menu without a visible selection range.
            .tableCellActions(source, enabled: allowsTextSelection)
            .frame(width: contentWidth, alignment: viewAlignment(for: alignment))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxHeight: .infinity, alignment: viewAlignment(for: alignment))
            .background(cellBackground(rowIndex: rowIndex, isHeader: isHeader))
    }

    private func measuredWidth(_ source: String, font: UIFont) -> CGFloat {
        (source as NSString).boundingRect(
            with: CGSize(width: 10_000, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).width
    }

    private func viewAlignment(for alignment: MarkdownTableColumnAlignment) -> Alignment {
        switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func textAlignment(for alignment: MarkdownTableColumnAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func cellBackground(rowIndex: Int?, isHeader: Bool) -> Color {
        if isHeader {
            return Color(uiColor: Self.headerBackground)
        }
        return Color(
            uiColor: (rowIndex ?? 0).isMultiple(of: 2)
                ? Self.evenRowBackground
                : Self.oddRowBackground
        )
    }
}

private struct MarkdownCodeBlockPalette {
    let headerBackground: UIColor
    let bodyBackground: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let separator: UIColor

    init(appearance: CodeBlockAppearance) {
        switch appearance {
        case .system:
            headerBackground = .tertiarySystemBackground
            bodyBackground = .secondarySystemBackground
            primaryText = .label
            secondaryText = .secondaryLabel
            separator = .separator
        case .light:
            headerBackground = UIColor(white: 0.96, alpha: 1)
            bodyBackground = .white
            primaryText = UIColor(white: 0.08, alpha: 1)
            secondaryText = UIColor(white: 0.38, alpha: 1)
            separator = UIColor(white: 0.82, alpha: 1)
        case .dark:
            headerBackground = UIColor(white: 0.14, alpha: 1)
            bodyBackground = UIColor(white: 0.07, alpha: 1)
            primaryText = UIColor(white: 0.94, alpha: 1)
            secondaryText = UIColor(white: 0.68, alpha: 1)
            separator = UIColor(white: 0.28, alpha: 1)
        }
    }
}

private struct MarkdownCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme
    let blockID: Int
    let language: String
    let code: String
    let isStreaming: Bool
    let fontSize: CGFloat
    let htmlRunnerEnabled: Bool
    let htmlRunnerAllowCurrentChat: Bool
    let htmlRunnerConversationID: UUID?
    let autoCollapse: Bool
    let collapsedLineLimit: Int
    let appearance: CodeBlockAppearance
    let allowsTextSelection: Bool
    let contentMutationContext: MessageContentMutationContext?

    @State private var didCopy = false
    @State private var standaloneDisclosureState = CodeBlockDisclosureState()
    @State private var isHTMLPreviewPresented = false

    private var disclosureState: CodeBlockDisclosureState {
        guard let contentMutationContext else { return standaloneDisclosureState }
        return contentMutationContext.state(contentMutationContext.scope, blockID)
    }

    private var displayLanguage: String {
        let cleaned = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "plaintext" : cleaned
    }

    private var displayCode: String {
        code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    private var isRunnableHTML: Bool {
        guard htmlRunnerEnabled, !isStreaming else { return false }
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "html" || normalized == "htm"
    }

    private var collapsedLineCount: Int {
        max(1, collapsedLineLimit)
    }

    private var exceedsCollapsedLineCount: Bool {
        displayCode.split(separator: "\n", maxSplits: collapsedLineCount, omittingEmptySubsequences: false).count > collapsedLineCount
    }

    private var isEffectivelyExpanded: Bool {
        if let manualExpansion = disclosureState.manualExpansion {
            return manualExpansion
        }
        guard autoCollapse else { return true }
        return !exceedsCollapsedLineCount
    }

    private var visibleCode: String {
        let source = displayCode.isEmpty && isStreaming ? " " : displayCode
        guard !isEffectivelyExpanded else { return source }
        return CodeBlockPreview.text(source, lineLimit: collapsedLineCount)
    }

    private var palette: MarkdownCodeBlockPalette {
        MarkdownCodeBlockPalette(appearance: appearance)
    }

    private var syntaxTheme: CodeSyntaxTheme {
        switch appearance {
        case .light: .light
        case .dark: .dark
        case .system: colorScheme == .dark ? .dark : .light
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    toggleDisclosure(from: .header)
                } label: {
                    HStack(spacing: 4) {
                        Text(displayLanguage)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(Color(uiColor: palette.secondaryText))

                        if !isEffectivelyExpanded {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color(uiColor: palette.secondaryText).opacity(0.56))
                                .transition(.opacity)
                        }

                        if isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Color(uiColor: palette.secondaryText))
                                .padding(.leading, 2)
                        }

                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .contentShape(Rectangle())
                    .modifier(CodeDisclosureFeedback(generation: disclosureState.feedbackGeneration))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEffectivelyExpanded ? L10n.lookup("收起代码") : L10n.lookup("展开代码"))

                if isRunnableHTML {
                    Button {
                        isHTMLPreviewPresented = true
                    } label: {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(uiColor: palette.primaryText))
                    .accessibilityLabel(L10n.lookup("运行 HTML 预览"))
                }

                Button {
                    UIPasteboard.general.string = displayCode
                    withAnimation(.snappy(duration: 0.18)) {
                        didCopy = true
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation(.snappy(duration: 0.18)) {
                            didCopy = false
                        }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(uiColor: palette.primaryText))
                .accessibilityLabel(didCopy ? L10n.lookup("已复制代码") : L10n.lookup("复制代码"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 42)
            .background(Color(uiColor: palette.headerBackground))

            ScrollView(.horizontal, showsIndicators: true) {
                NativeSelectableCodeText(
                    text: visibleCode,
                    language: language,
                    syntaxTheme: syntaxTheme,
                    fontSize: fontSize,
                    lineSpacing: 3,
                    textColor: palette.primaryText,
                    allowsSelection: allowsTextSelection,
                    usesSharedMeasurementCache: !isStreaming
                )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(DrawerHorizontalScrollProbe())
            }
            .background(Color(uiColor: palette.bodyBackground))
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .modifier(CodeDisclosureFeedback(generation: disclosureState.feedbackGeneration))

            if exceedsCollapsedLineCount {
                Rectangle()
                    .fill(Color(uiColor: palette.separator))
                    .frame(height: 0.5)

                Button {
                    toggleDisclosure(from: .footer)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isEffectivelyExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                        Text(isEffectivelyExpanded ? L10n.lookup("收起代码") : L10n.lookup("展开代码"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color(uiColor: palette.secondaryText))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                    .modifier(CodeDisclosureFeedback(generation: disclosureState.feedbackGeneration))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEffectivelyExpanded ? L10n.lookup("从底部收起代码") : L10n.lookup("从底部展开代码"))
            }
        }
        .background {
            Color(uiColor: palette.bodyBackground)
            if contentMutationContext != nil,
               exceedsCollapsedLineCount {
                ChatContentMutationAnchorProbe(handle: disclosureState.anchor)
                if let requestID = disclosureState.layoutRequestID {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CodeDisclosureLayoutPreferenceKey.self,
                            value: [requestID: proxy.frame(in: .named("chat-scroll"))]
                        )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: palette.separator), lineWidth: 0.7)
        }
        .fullScreenCover(isPresented: $isHTMLPreviewPresented) {
            HTMLPreviewPage(
                html: displayCode,
                currentChatBridgeEnabled: htmlRunnerAllowCurrentChat,
                conversationID: htmlRunnerConversationID
            )
        }
    }

    @MainActor
    private func toggleDisclosure(from edge: ChatContentMutationAnchorEdge) {
        let state = disclosureState
        let targetExpanded = !(state.pendingExpansion ?? isEffectivelyExpanded)
        if exceedsCollapsedLineCount, let contentMutationContext {
            contentMutationContext.request(CodeDisclosureChange(
                scope: contentMutationContext.scope,
                blockID: blockID,
                state: state,
                expanded: targetExpanded,
                edge: edge
            ))
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.setExpanded(targetExpanded) }
        }
    }
}

/// A completed user disclosure pulses only opacity. Layout and stream batches
/// do not animate, and the existing text view is never duplicated for a fade.
private struct CodeDisclosureFeedback: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let generation: UInt64

    func body(content: Content) -> some View {
        content.phaseAnimator([1.0, 0.72, 1.0], trigger: generation) { content, opacity in
            content.opacity(reduceMotion ? 1 : opacity)
        } animation: { opacity in
            opacity == 1 && !reduceMotion ? .easeOut(duration: 0.14) : .linear(duration: 0)
        }
    }
}

private struct NativeSelectableCodeText: UIViewRepresentable {
    let text: String
    let language: String
    let syntaxTheme: CodeSyntaxTheme
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let textColor: UIColor
    let allowsSelection: Bool
    let usesSharedMeasurementCache: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(frame: .zero, textContainer: nil)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.widthTracksTextView = false
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        textView.clipsToBounds = true
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        apply(to: textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        apply(to: textView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.syntaxColors.cancel()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: UITextView,
        context: Context
    ) -> CGSize? {
        apply(to: textView, coordinator: context.coordinator)
        return context.coordinator.measuredSize
    }

    private func apply(to textView: UITextView, coordinator: Coordinator) {
        textView.isSelectable = allowsSelection
        let displayScale = max(1, textView.traitCollection.displayScale)
        let hasSameStyle = coordinator.fontSize == fontSize
            && coordinator.lineSpacing == lineSpacing
            && coordinator.displayScale == displayScale
            && coordinator.textColor?.isEqual(textColor) == true
        let hasSameContent = hasSameStyle
            && coordinator.text.map { (text as NSString).isEqual(to: $0) } == true
        defer {
            coordinator.syntaxColors.update(
                textView: textView, text: text, language: language,
                theme: syntaxTheme, isStreaming: !usesSharedMeasurementCache,
                baseColor: textColor
            )
        }
        let measurementStyleSignature = "\(fontSize)|\(lineSpacing)|\(displayScale)"
        if hasSameContent {
            if usesSharedMeasurementCache,
               !coordinator.usesSharedMeasurementCache {
                let cacheKey = codeMeasurementKey(
                    for: text,
                    styleSignature: measurementStyleSignature
                )
                if UnifiedTextMeasurementCache.code.value(for: cacheKey) == nil {
                    UnifiedTextMeasurementCache.code.insert(coordinator.measuredSize, for: cacheKey)
                }
            }
            coordinator.usesSharedMeasurementCache = usesSharedMeasurementCache
            return
        }

        let renderMeasurementKey = usesSharedMeasurementCache
            ? codeMeasurementKey(for: text, styleSignature: measurementStyleSignature)
            : nil
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let measuredSize = measuredCodeSize(
            for: attributedText,
            cacheKey: renderMeasurementKey,
            displayScale: displayScale
        )
        let appendFrom = coordinator.text.flatMap { previous -> Int? in
            guard hasSameStyle,
                  coordinator.syntaxColors.matches(language: language, theme: syntaxTheme),
                  (text as NSString).range(of: previous, options: [.anchored, .literal]).location == 0,
                  (textView.textStorage.string as NSString).isEqual(to: previous) else { return nil }
            return (previous as NSString).length
        }
        coordinator.text = text
        coordinator.fontSize = fontSize
        coordinator.lineSpacing = lineSpacing
        coordinator.displayScale = displayScale
        coordinator.textColor = textColor
        coordinator.usesSharedMeasurementCache = usesSharedMeasurementCache
        coordinator.measuredSize = measuredSize
        textView.textContainer.size = CGSize(
            width: measuredSize.width,
            height: .greatestFiniteMagnitude
        )
        if let appendFrom {
            // Keep already displayed colors while the next streaming batch is
            // analyzed. Only the new suffix starts in the ordinary text color.
            textView.textStorage.append(NSAttributedString(
                string: (text as NSString).substring(from: appendFrom), attributes: attributes
            ))
        } else {
            coordinator.syntaxColors.resetColors()
            textView.attributedText = attributedText
        }
        textView.invalidateIntrinsicContentSize()
    }

    private func measuredCodeSize(
        for attributedText: @autoclosure () -> NSAttributedString,
        cacheKey: String?,
        displayScale: CGFloat
    ) -> CGSize {
        if let cacheKey,
           let cachedSize = UnifiedTextMeasurementCache.code.value(for: cacheKey) {
            return cachedSize
        }
        let bounds = attributedText().boundingRect(
            with: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let pixel = 1 / displayScale
        let measuredSize = CGSize(
            width: max(pixel, ceil(bounds.width * displayScale) / displayScale + pixel),
            height: max(pixel, ceil(bounds.height * displayScale) / displayScale + pixel)
        )
        if let cacheKey {
            UnifiedTextMeasurementCache.code.insert(measuredSize, for: cacheKey)
        }
        return measuredSize
    }

    private func codeMeasurementKey(
        for text: String,
        styleSignature: String
    ) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return "\(Data(digest).base64EncodedString())|\(text.utf16.count)|\(styleSignature)"
    }

    @MainActor
    final class Coordinator {
        let syntaxColors = CodeSyntaxTextStyler()
        var text: String?
        var fontSize: CGFloat?
        var lineSpacing: CGFloat?
        var displayScale: CGFloat?
        var textColor: UIColor?
        var usesSharedMeasurementCache = false
        var measuredSize = CGSize(width: 1, height: 1)
    }
}

private enum HTMLCurrentChatAuthorization {
    case undetermined
    case granted
    case denied
}

private struct HTMLBridgeRequest {
    let id: Int
    let method: String
}

@MainActor
private final class HTMLPreviewBridge: ObservableObject {
    weak var webView: WKWebView?

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    func resolve(requestID: Int, result: Any) {
        send(["id": requestID, "result": result])
    }

    func reject(requestID: Int, error: String) {
        send(["id": requestID, "error": error])
    }

    private func send(_ payload: [String: Any]) {
        guard let webView,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        webView.evaluateJavaScript("window.__moccaResolve(\(json));", completionHandler: nil)
    }
}

private struct HTMLPreviewPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let html: String
    let currentChatBridgeEnabled: Bool
    let conversationID: UUID?

    @StateObject private var bridge = HTMLPreviewBridge()
    @State private var reloadID = UUID()
    @State private var currentChatAuthorization: HTMLCurrentChatAuthorization = .undetermined
    @State private var pendingCurrentChatRequestIDs: [Int] = []
    @State private var isShowingCurrentChatPermission = false

    var body: some View {
        NavigationStack {
            HTMLPreviewWebView(
                html: html,
                reloadID: reloadID,
                currentChatBridgeEnabled: currentChatBridgeEnabled,
                bridge: bridge,
                onBridgeRequest: handleBridgeRequest
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(L10n.lookup("HTML 预览"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.lookup("关闭 HTML 预览"))
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if currentChatBridgeEnabled {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.lookup("聊天权限预览已限制外部资源加载"))
                    }

                    Button {
                        reloadID = UUID()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L10n.lookup("重新运行 HTML"))
                }
            }
        }
        .tint(Color(uiColor: model.themeActionUIColor))
        .alert(L10n.lookup("允许这个网页读取当前聊天？"), isPresented: $isShowingCurrentChatPermission) {
            Button(L10n.lookup("仅本次允许")) {
                currentChatAuthorization = .granted
                resolvePendingCurrentChatRequests()
            }
            Button(L10n.lookup("不允许"), role: .cancel) {
                currentChatAuthorization = .denied
                rejectPendingCurrentChatRequests()
            }
        } message: {
            Text(L10n.lookup("将提供最近最多 80 条用户与助手正文，每条最多 1200 字；不会提供思考链、工具数据、附件或密钥。已限制外部资源加载，但并非完全断网，请仅对你信任的网页授权。"))
        }
    }

    private func handleBridgeRequest(_ request: HTMLBridgeRequest) {
        guard request.method == "getCurrentChat" else {
            bridge.reject(requestID: request.id, error: L10n.lookup("不支持的 Mocca 桥接方法。"))
            return
        }
        guard currentChatBridgeEnabled else {
            bridge.reject(requestID: request.id, error: L10n.lookup("当前聊天读取权限未开启。"))
            return
        }
        guard conversationID != nil else {
            bridge.reject(requestID: request.id, error: L10n.lookup("找不到当前聊天。"))
            return
        }

        switch currentChatAuthorization {
        case .granted:
            resolveCurrentChatRequest(request.id)
        case .denied:
            bridge.reject(requestID: request.id, error: L10n.lookup("本次预览未获得当前聊天读取权限。"))
        case .undetermined:
            if !pendingCurrentChatRequestIDs.contains(request.id) {
                pendingCurrentChatRequestIDs.append(request.id)
            }
            isShowingCurrentChatPermission = true
        }
    }

    private func resolvePendingCurrentChatRequests() {
        let requestIDs = pendingCurrentChatRequestIDs
        pendingCurrentChatRequestIDs.removeAll()
        for requestID in requestIDs {
            resolveCurrentChatRequest(requestID)
        }
    }

    private func rejectPendingCurrentChatRequests() {
        let requestIDs = pendingCurrentChatRequestIDs
        pendingCurrentChatRequestIDs.removeAll()
        for requestID in requestIDs {
            bridge.reject(requestID: requestID, error: L10n.lookup("用户拒绝了当前聊天读取请求。"))
        }
    }

    private func resolveCurrentChatRequest(_ requestID: Int) {
        guard let conversationID else {
            bridge.reject(requestID: requestID, error: L10n.lookup("找不到当前聊天。"))
            return
        }
        let payload = model.searchableMessages(for: conversationID)
            .suffix(80)
            .map { message in
                [
                    "role": message.role.rawValue,
                    "content": limitedText(message.text, maxCharacters: 1_200),
                    "timestamp": message.createdAt.ISO8601Format()
                ]
            }
        bridge.resolve(requestID: requestID, result: Array(payload))
    }

    private func limitedText(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "…"
    }
}

private struct HTMLPreviewWebView: UIViewRepresentable {
    private static let bridgeHandlerName = "MoccaBridge"

    let html: String
    let reloadID: UUID
    let currentChatBridgeEnabled: Bool
    let bridge: HTMLPreviewBridge
    let onBridgeRequest: (HTMLBridgeRequest) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onBridgeRequest: onBridgeRequest,
            currentChatBridgeEnabled: currentChatBridgeEnabled
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if currentChatBridgeEnabled {
            configuration.userContentController.add(
                context.coordinator,
                name: Self.bridgeHandlerName
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        bridge.attach(to: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onBridgeRequest = onBridgeRequest
        context.coordinator.currentChatBridgeEnabled = currentChatBridgeEnabled
        bridge.attach(to: webView)
        let signature = reloadID.uuidString
        guard context.coordinator.lastLoadSignature != signature else { return }
        context.coordinator.lastLoadSignature = signature
        context.coordinator.load(
            Self.sandboxedDocument(from: html, currentChatBridgeEnabled: currentChatBridgeEnabled),
            in: webView,
            signature: signature
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.lastLoadSignature = ""
        coordinator.privateNetworkIsolationReady = false
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: bridgeHandlerName
        )
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastLoadSignature = ""
        var onBridgeRequest: (HTMLBridgeRequest) -> Void
        var currentChatBridgeEnabled: Bool
        var privateNetworkIsolationReady = false

        func load(_ document: String, in webView: WKWebView, signature: String) {
            privateNetworkIsolationReady = false
            webView.stopLoading()
            guard currentChatBridgeEnabled else {
                webView.loadHTMLString(document, baseURL: nil)
                return
            }

            // Install the resource boundary before any untrusted HTML can execute.
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "MoccaPrivatePreviewNetworkV1",
                encodedContentRuleList: HTMLPreviewWebView.privateNetworkRules
            ) { [weak self, weak webView] rules, _ in
                guard let self, let webView,
                      self.lastLoadSignature == signature else { return }
                guard let rules else {
                    webView.loadHTMLString(L10n.lookup("<p>无法启用外部资源限制，请关闭预览后重试。</p>"), baseURL: nil)
                    return
                }
                webView.configuration.userContentController.removeAllContentRuleLists()
                webView.configuration.userContentController.add(rules)
                self.privateNetworkIsolationReady = true
                webView.loadHTMLString(document, baseURL: nil)
            }
        }

        init(
            onBridgeRequest: @escaping (HTMLBridgeRequest) -> Void,
            currentChatBridgeEnabled: Bool
        ) {
            self.onBridgeRequest = onBridgeRequest
            self.currentChatBridgeEnabled = currentChatBridgeEnabled
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard currentChatBridgeEnabled, privateNetworkIsolationReady,
                  message.frameInfo.isMainFrame,
                  message.name == HTMLPreviewWebView.bridgeHandlerName,
                  let raw = message.body as? String,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue,
                  let method = object["method"] as? String else {
                return
            }
            onBridgeRequest(HTMLBridgeRequest(id: id, method: method))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(currentChatBridgeEnabled ? .cancel : .allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if currentChatBridgeEnabled {
                // loadHTMLString and fragment links stay on about:blank. A data/blob
                // document could replace the protected page; those URLs remain usable
                // as images/media through the resource rules, not as navigation.
                let isPreviewDocument = url.absoluteString == "about:blank"
                    || url.absoluteString.hasPrefix("about:blank#")
                    // WebKit can percent-encode the fragment separator here.
                    || url.absoluteString.hasPrefix("about:blank%23")
                decisionHandler(isPreviewDocument && navigationAction.targetFrame?.isMainFrame == true
                    ? .allow : .cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated,
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame?.isMainFrame == true,
               scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                return
            }

            if ["about", "data", "blob", "file", "http", "https"].contains(scheme) || scheme.isEmpty {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    private static let privateNetworkRules = """
    [
      {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}
    ]
    """

    private static let standardContentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com https://cdn.tailwindcss.com; style-src 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com https://fonts.googleapis.com; font-src data: https://fonts.gstatic.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; img-src data: blob: https:; media-src data: blob: https:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    private static let privateContentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; font-src data:; img-src data: blob:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    private static let currentChatBridgeScript = """
    <script>
    (function(){
      const pending = new Map();
      let sequence = 1;
      window.__moccaResolve = function(message) {
        const item = pending.get(message.id);
        if (!item) return;
        pending.delete(message.id);
        if (message.error) item.reject(new Error(message.error));
        else item.resolve(message.result);
      };
      function call(method) {
        const id = sequence++;
        return new Promise(function(resolve, reject) {
          pending.set(id, { resolve: resolve, reject: reject });
          window.webkit.messageHandlers.MoccaBridge.postMessage(JSON.stringify({
            id: id,
            method: method
          }));
        });
      }
      Object.defineProperty(window, 'mocca', {
        value: Object.freeze({
          getCurrentChat: function(){ return call('getCurrentChat'); }
        }),
        writable: false,
        configurable: false
      });
    })();
    </script>
    """

    private static func injectedHead(currentChatBridgeEnabled: Bool) -> String {
        let policy = currentChatBridgeEnabled
            ? privateContentSecurityPolicy
            : standardContentSecurityPolicy
        let bridgeScript = currentChatBridgeEnabled ? currentChatBridgeScript : ""
        return """
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>
          :root { color-scheme: light dark; }
          html, body { min-height: 100%; margin: 0; }
          body { overflow-wrap: anywhere; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
          img, video, canvas, svg { max-width: 100%; }
        </style>
        \(bridgeScript)
        """
    }

    private static func sandboxedDocument(
        from source: String,
        currentChatBridgeEnabled: Bool
    ) -> String {
        // Let WebKit parse the original document. A trusted prefix reaches the
        // parser before source comments, scripts or resources can swallow the CSP.
        return """
        <!doctype html>
        \(injectedHead(currentChatBridgeEnabled: currentChatBridgeEnabled))
        \(source)
        """
    }
}

private struct MarkdownRenderBlock: Identifiable, Hashable {
    enum Kind: Hashable {
        case text(String)
        case quote(String)
        case heading(level: Int, text: String)
        case list([MarkdownListEntry])
        case horizontalRule
        case code(language: String, code: String, isClosed: Bool)
        case table(MarkdownTableContent)
    }

    let id: Int
    let kind: Kind
}

private struct MarkdownListEntry: Hashable {
    let marker: String
    var content: String
    let isOrdered: Bool
    var nestedQuoteLines: [String] = []
}

private enum MarkdownRenderCache {
    nonisolated(unsafe) private static let blockCache: NSCache<NSString, MarkdownBlockCacheEntry> = {
        let cache = NSCache<NSString, MarkdownBlockCacheEntry>()
        cache.countLimit = 1_000
        cache.totalCostLimit = 16_000_000
        return cache
    }()

    nonisolated(unsafe) private static let attributedCache: NSCache<NSString, MarkdownAttributedCacheEntry> = {
        let cache = NSCache<NSString, MarkdownAttributedCacheEntry>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 24_000_000
        return cache
    }()

    static func blocks(for source: String) -> [MarkdownRenderBlock] {
        guard !source.isEmpty else { return [] }
        let key = NSString(string: source)
        if let cached = blockCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = MarkdownRenderParser.parse(source)
        blockCache.setObject(
            MarkdownBlockCacheEntry(blocks: parsed),
            forKey: key,
            cost: max(1, source.utf16.count + parsed.count * 24)
        )
        return parsed
    }

    static func attributedText(for source: String) -> AttributedString {
        let key = NSString(string: source)
        if let cached = attributedCache.object(forKey: key) {
            return cached.text
        }
        let parsed = makeAttributedText(for: source)
        attributedCache.setObject(
            MarkdownAttributedCacheEntry(text: parsed),
            forKey: key,
            cost: max(1, source.utf16.count)
        )
        return parsed
    }

    static func makeAttributedText(for source: String) -> AttributedString {
        do {
            let compatibleSource = sourceProtectingLiteralKaomojiDelimiters(source)
            var parsed = try AttributedString(
                markdown: compatibleSource.markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            if let marker = compatibleSource.insertedMarker {
                while let index = parsed.characters.firstIndex(of: marker) {
                    parsed.characters.remove(at: index)
                }
            }
            return parsed
        } catch {
            return AttributedString(source)
        }
    }

    private static func sourceProtectingLiteralKaomojiDelimiters(
        _ source: String
    ) -> (markdown: String, insertedMarker: Character?) {
        // These repairs only act on asterisks and backticks. Preserve the
        // original source without allocating repair buffers when neither occurs.
        guard source.utf8.contains(where: { $0 == 0x2A || $0 == 0x60 }) else {
            return (source, nil)
        }
        // CommonMark does not treat `中文**“强调”**` or `中文**"强调"**` as
        // strong emphasis: the opening delimiter is between a word character
        // and opening punctuation. Models emit both forms frequently. Insert a
        // private-use parsing marker after that opener, then remove it from the
        // attributed result so display, selection, and copied text stay exact.
        let markerCandidates: [Character] = ["\u{F0000}", "\u{F0001}", "\u{F0002}"]
        guard let marker = markerCandidates.first(where: { !source.contains($0) }) else {
            let protectedSource = source.components(separatedBy: "\n")
                .map(protectLiteralDelimitersOnLine)
                .joined(separator: "\n")
            return (protectedSource, nil)
        }

        var didInsertMarker = false
        let lineRepairedMarkdown = source.components(separatedBy: "\n")
            .map { line in
                let protectedLine = protectLiteralDelimitersOnLine(line)
                let repaired = repairCJKStrongEmphasis(
                    in: protectedLine,
                    marker: marker
                )
                didInsertMarker = didInsertMarker || repaired.didInsertMarker
                return repaired.markdown
            }
            .joined(separator: "\n")
        let closerRepaired = repairStrongEmphasisClosers(
            in: lineRepairedMarkdown,
            marker: marker
        )
        didInsertMarker = didInsertMarker || closerRepaired.didInsertMarker
        return (
            closerRepaired.markdown,
            didInsertMarker ? marker : nil
        )
    }

    private static func protectLiteralDelimitersOnLine(_ line: String) -> String {
        let characters = Array(line)
        var backtickRunsByLength: [Int: [Int]] = [:]
        var index = 0

        while index < characters.count {
            guard characters[index] == "`", !isEscaped(characters, at: index) else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index] == "`" {
                index += 1
            }
            backtickRunsByLength[index - start, default: []].append(start)
        }

        var literalBacktickRunStarts = Set<Int>()
        for starts in backtickRunsByLength.values where starts.count.isMultiple(of: 2) == false {
            if let unmatchedStart = starts.last {
                literalBacktickRunStarts.insert(unmatchedStart)
            }
        }

        var backtickProtected = ""
        for (offset, character) in characters.enumerated() {
            if literalBacktickRunStarts.contains(offset) {
                backtickProtected.append("\\")
            }
            backtickProtected.append(character)
        }

        return protectKaomojiStars(in: backtickProtected)
    }

    private static func protectKaomojiStars(in line: String) -> String {
        let characters = Array(line)
        guard characters.count >= 4 else { return line }
        var literalStarOffsets = Set<Int>()
        var open = 0

        while open + 3 < characters.count {
            guard characters[open] == "(",
                  characters[open + 1] == "*",
                  characters[open + 2] != "*" else {
                open += 1
                continue
            }

            var close = open + 3
            while close + 1 < characters.count {
                if characters[close] == "*",
                   characters[close - 1] != "*",
                   characters[close + 1] == ")" {
                    let interior = characters[(open + 2)..<close]
                    if interior.contains(where: containsKaomojiSymbol) {
                        literalStarOffsets.insert(open + 1)
                        literalStarOffsets.insert(close)
                    }
                    open = close + 2
                    break
                }
                close += 1
            }
            if close + 1 >= characters.count {
                open += 1
            }
        }

        guard !literalStarOffsets.isEmpty else { return line }
        var result = ""
        for (offset, character) in characters.enumerated() {
            if literalStarOffsets.contains(offset), !isEscaped(characters, at: offset) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func repairCJKStrongEmphasis(
        in line: String,
        marker: Character
    ) -> (markdown: String, didInsertMarker: Bool) {
        let characters = Array(line)
        guard characters.count >= 7 else { return (line, false) }

        var insertionOffsets = Set<Int>()
        var codeDelimiterLength: Int?
        var index = 0

        while index < characters.count {
            if characters[index] == "`", !isEscaped(characters, at: index) {
                let start = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }
                let runLength = index - start
                if codeDelimiterLength == runLength {
                    codeDelimiterLength = nil
                } else if codeDelimiterLength == nil {
                    codeDelimiterLength = runLength
                }
                continue
            }

            guard codeDelimiterLength == nil,
                  index > 0,
                  index + 2 < characters.count,
                  characters[index] == "*",
                  characters[index + 1] == "*",
                  characters[index - 1] != "*",
                  characters[index + 2] != "*",
                  !isEscaped(characters, at: index),
                  !isMarkdownWhitespace(characters[index - 1]),
                  !isMarkdownPunctuation(characters[index - 1]),
                  isSupportedStrongOpeningPunctuation(characters[index + 2]),
                  hasClosingStrongDelimiter(in: characters, after: index + 2) else {
                index += 1
                continue
            }

            insertionOffsets.insert(index + 2)
            index += 2
        }

        guard !insertionOffsets.isEmpty else { return (line, false) }
        var result = ""
        for (offset, character) in characters.enumerated() {
            if insertionOffsets.contains(offset) {
                result.append(marker)
            }
            result.append(character)
        }
        return (result, true)
    }

    private static func hasClosingStrongDelimiter(
        in characters: [Character],
        after start: Int
    ) -> Bool {
        guard start + 1 < characters.count else { return false }
        var index = start
        var codeDelimiterLength: Int?

        while index + 1 < characters.count {
            if characters[index] == "`", !isEscaped(characters, at: index) {
                let runStart = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }
                let runLength = index - runStart
                if codeDelimiterLength == runLength {
                    codeDelimiterLength = nil
                } else if codeDelimiterLength == nil {
                    codeDelimiterLength = runLength
                }
                continue
            }

            if codeDelimiterLength == nil,
               characters[index] == "*",
               characters[index + 1] == "*",
               characters[index - 1] != "*",
               (index + 2 == characters.count || characters[index + 2] != "*"),
               !isEscaped(characters, at: index),
               !isMarkdownWhitespace(characters[index - 1]) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func repairStrongEmphasisClosers(
        in source: String,
        marker: Character
    ) -> (markdown: String, didInsertMarker: Bool) {
        let characters = Array(source)
        guard characters.count >= 7 else { return (source, false) }

        var insertionOffsets = Set<Int>()
        var unmatchedStrongOpeners: [Int] = []
        var codeDelimiterLength: Int?
        var index = 0

        while index + 1 < characters.count {
            if characters[index] == "`", !isEscaped(characters, at: index) {
                let start = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }
                let runLength = index - start
                if codeDelimiterLength == runLength {
                    codeDelimiterLength = nil
                } else if codeDelimiterLength == nil {
                    codeDelimiterLength = runLength
                }
                continue
            }

            guard codeDelimiterLength == nil,
                  characters[index] == "*",
                  characters[index + 1] == "*",
                  (index == 0 || characters[index - 1] != "*"),
                  (index + 2 == characters.count || characters[index + 2] != "*"),
                  !isEscaped(characters, at: index) else {
                index += 1
                continue
            }

            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 2 < characters.count ? characters[index + 2] : nil
            let canOpen = strongDelimiterCanOpen(previous: previous, next: next)
            let canClose = strongDelimiterCanClose(previous: previous, next: next)

            if canClose, !unmatchedStrongOpeners.isEmpty {
                unmatchedStrongOpeners.removeLast()
            } else if canOpen,
                      (
                        isLineLeadingDelimiter(in: characters, at: index)
                            || isCJKPunctuationCloserBoundary(previous: previous, next: next)
                      ),
                      let opener = unmatchedStrongOpeners.last,
                      hasNonWhitespaceContent(
                        in: characters,
                        between: opener + 2,
                        and: index,
                        excluding: marker
                      ) {
                // Models sometimes put a closing `**` at the beginning of the
                // next line, or after CJK closing punctuation immediately
                // before an emoji/suffix. CommonMark sees that run as another
                // opener. A temporary marker supplies the missing
                // right-flanking boundary; it is removed after parsing.
                insertionOffsets.insert(index)
                unmatchedStrongOpeners.removeLast()
            } else if canOpen {
                unmatchedStrongOpeners.append(index)
            }
            index += 2
        }

        guard !insertionOffsets.isEmpty else { return (source, false) }
        var result = ""
        for (offset, character) in characters.enumerated() {
            if insertionOffsets.contains(offset) {
                result.append(marker)
            }
            result.append(character)
        }
        return (result, true)
    }

    private static func strongDelimiterCanOpen(
        previous: Character?,
        next: Character?
    ) -> Bool {
        let previousIsWhitespace = previous.map(isMarkdownWhitespace) ?? true
        let nextIsWhitespace = next.map(isMarkdownWhitespace) ?? true
        let previousIsPunctuation = previous.map(isMarkdownPunctuation) ?? false
        let nextIsPunctuation = next.map(isMarkdownPunctuation) ?? false
        return !nextIsWhitespace
            && (!nextIsPunctuation || previousIsWhitespace || previousIsPunctuation)
    }

    private static func strongDelimiterCanClose(
        previous: Character?,
        next: Character?
    ) -> Bool {
        let previousIsWhitespace = previous.map(isMarkdownWhitespace) ?? true
        let nextIsWhitespace = next.map(isMarkdownWhitespace) ?? true
        let previousIsPunctuation = previous.map(isMarkdownPunctuation) ?? false
        let nextIsPunctuation = next.map(isMarkdownPunctuation) ?? false
        return !previousIsWhitespace
            && (!previousIsPunctuation || nextIsWhitespace || nextIsPunctuation)
    }

    private static func isLineLeadingDelimiter(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard index > 0 else { return false }
        var cursor = index - 1
        while true {
            let character = characters[cursor]
            if character == "\n" || character == "\r" {
                return true
            }
            if character != " " && character != "\t" {
                return false
            }
            guard cursor > 0 else { return false }
            cursor -= 1
        }
    }

    private static func isCJKPunctuationCloserBoundary(
        previous: Character?,
        next: Character?
    ) -> Bool {
        guard let previous,
              let next,
              isCJKClosingPunctuation(previous),
              !isMarkdownWhitespace(next),
              !isMarkdownPunctuation(next) else { return false }
        return true
    }

    private static func hasNonWhitespaceContent(
        in characters: [Character],
        between start: Int,
        and end: Int,
        excluding marker: Character
    ) -> Bool {
        guard start < end else { return false }
        return characters[start..<end].contains { character in
            character != marker && !isMarkdownWhitespace(character)
        }
    }

    private static func isSupportedStrongOpeningPunctuation(
        _ character: Character
    ) -> Bool {
        switch character {
        case "\"", "“", "‘", "「", "『", "（", "《", "〈", "【", "〔", "〖", "〘", "〚":
            return true
        default:
            return false
        }
    }

    private static func isCJKClosingPunctuation(_ character: Character) -> Bool {
        switch character {
        case "”", "’", "」", "』", "）", "》", "〉", "】", "〕", "〗", "〙", "〛",
             "。", "！", "？", "；", "：", "，", "、":
            return true
        default:
            return false
        }
    }

    private static func isMarkdownWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    private static func isMarkdownPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }

    private static func containsKaomojiSymbol(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.symbols.contains($0) }
    }

    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        var slashCount = 0
        var cursor = index - 1
        while characters[cursor] == "\\" {
            slashCount += 1
            guard cursor > 0 else { break }
            cursor -= 1
        }
        return !slashCount.isMultiple(of: 2)
    }
}

private final class MarkdownBlockCacheEntry {
    let blocks: [MarkdownRenderBlock]

    init(blocks: [MarkdownRenderBlock]) {
        self.blocks = blocks
    }
}

private final class MarkdownAttributedCacheEntry {
    let text: AttributedString

    init(text: AttributedString) {
        self.text = text
    }
}

private enum MarkdownRenderParser {
    static func parse(_ source: String) -> [MarkdownRenderBlock] {
        guard !source.isEmpty else { return [] }

        var blocks: [MarkdownRenderBlock] = []
        var textLines: [String] = []
        var quoteLines: [String] = []
        var listEntries: [MarkdownListEntry] = []
        var codeLines: [String] = []
        var fenceMarker: Character?
        var fenceLength = 0
        var fenceLanguage = ""
        var reopenStrongAfterList = false
        var pendingReusableStrongOpenerLineIndex: Int?
        var pendingStrongCloserLineIndex: Int?

        func appendTextBlock() {
            guard !textLines.isEmpty else { return }
            let text = trimOuterBlankLines(textLines.joined(separator: "\n"))
            if !text.isEmpty {
                blocks.append(MarkdownRenderBlock(id: blocks.count, kind: .text(text)))
            }
            textLines.removeAll(keepingCapacity: true)
        }

        func appendQuoteBlock() {
            guard !quoteLines.isEmpty else { return }
            let text = trimOuterBlankLines(quoteLines.joined(separator: "\n"))
            if !text.isEmpty {
                blocks.append(MarkdownRenderBlock(id: blocks.count, kind: .quote(text)))
            }
            quoteLines.removeAll(keepingCapacity: true)
        }

        func appendListBlock() {
            guard !listEntries.isEmpty else { return }
            blocks.append(MarkdownRenderBlock(id: blocks.count, kind: .list(listEntries)))
            listEntries.removeAll(keepingCapacity: true)
        }

        func appendHorizontalRule() {
            blocks.append(MarkdownRenderBlock(id: blocks.count, kind: .horizontalRule))
        }

        func appendCodeBlock(isClosed: Bool) {
            let code = codeLines.joined(separator: "\n")
            blocks.append(
                MarkdownRenderBlock(
                    id: blocks.count,
                    kind: .code(language: fenceLanguage, code: code, isClosed: isClosed)
                )
            )
            codeLines.removeAll(keepingCapacity: true)
            fenceMarker = nil
            fenceLength = 0
            fenceLanguage = ""
        }

        let sourceLines = source.components(separatedBy: "\n")
        var sourceLineIndex = 0
        while sourceLineIndex < sourceLines.count {
            var line = sourceLines[sourceLineIndex]
            defer { sourceLineIndex += 1 }

            if let marker = fenceMarker {
                if isClosingFence(line, marker: marker, minimumLength: fenceLength) {
                    appendCodeBlock(isClosed: true)
                } else {
                    codeLines.append(line)
                }
                continue
            }

            // Some models start a strong-emphasis span in a list item and put
            // its closing `**` in following prose. Inline emphasis cannot span
            // those separately rendered blocks, so close and reopen it at the
            // boundary while preserving the original list/prose layout.
            if !listEntries.isEmpty,
               hasUnclosedStrongDelimiter(listEntries[listEntries.count - 1].content),
               let repair = strongContinuationRepairBeforeNextBlock(
                    startingAt: sourceLineIndex,
                    in: sourceLines
               ) {
                listEntries[listEntries.count - 1].content += "**"
                reopenStrongAfterList = true
                pendingReusableStrongOpenerLineIndex = repair.reusableOpenerLineIndex
                pendingStrongCloserLineIndex = repair.closerLineIndex
            }
            if pendingStrongCloserLineIndex == sourceLineIndex {
                line = movingWhitespaceAfterLastStrongDelimiter(in: line)
                pendingStrongCloserLineIndex = nil
            }
            if reopenStrongAfterList,
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if pendingReusableStrongOpenerLineIndex != sourceLineIndex {
                    line = insertingStrongOpenerAfterLeadingWhitespace(in: line)
                }
                pendingReusableStrongOpenerLineIndex = nil
                reopenStrongAfterList = false
            }

            if let opening = openingFence(in: line) {
                appendTextBlock()
                appendQuoteBlock()
                appendListBlock()
                fenceMarker = opening.marker
                fenceLength = opening.length
                fenceLanguage = opening.language
                continue
            }

            if let parsedTable = MarkdownTableParser.parse(
                startingAt: sourceLineIndex,
                in: sourceLines
            ) {
                appendTextBlock()
                appendQuoteBlock()
                appendListBlock()
                blocks.append(
                    MarkdownRenderBlock(
                        id: blocks.count,
                        kind: .table(parsedTable.table)
                    )
                )
                sourceLineIndex = parsedTable.nextLineIndex - 1
                continue
            }

            if isHorizontalRule(line) {
                appendTextBlock()
                appendQuoteBlock()
                appendListBlock()
                appendHorizontalRule()
                continue
            }

            if let heading = headingContent(in: line) {
                appendTextBlock()
                appendQuoteBlock()
                appendListBlock()
                blocks.append(
                    MarkdownRenderBlock(
                        id: blocks.count,
                        kind: .heading(level: heading.level, text: heading.text)
                    )
                )
                continue
            }

            if !listEntries.isEmpty,
               let nestedQuoteLine = nestedListBlockquoteContent(in: line) {
                listEntries[listEntries.count - 1].nestedQuoteLines.append(nestedQuoteLine)
                continue
            }

            if let quoteLine = blockquoteContent(in: line) {
                appendTextBlock()
                appendListBlock()
                quoteLines.append(quoteLine)
                continue
            }

            if let listEntry = listEntry(in: line) {
                appendTextBlock()
                appendQuoteBlock()
                listEntries.append(listEntry)
                continue
            }

            appendQuoteBlock()
            appendListBlock()
            textLines.append(line)
        }

        if fenceMarker != nil {
            appendCodeBlock(isClosed: false)
        } else {
            appendQuoteBlock()
            appendListBlock()
            appendTextBlock()
        }

        if blocks.isEmpty {
            blocks.append(MarkdownRenderBlock(id: 0, kind: .text(source)))
        }
        return blocks
    }

    private static func openingFence(in line: String) -> (marker: Character, length: Int, language: String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }

        var length = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == first {
            length += 1
            index = trimmed.index(after: index)
        }
        guard length >= 3 else { return nil }

        let language = String(trimmed[index...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (first, length, language)
    }

    private static func isClosingFence(
        _ line: String,
        marker: Character,
        minimumLength: Int
    ) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        var length = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == marker {
            length += 1
            index = trimmed.index(after: index)
        }
        guard length >= minimumLength else { return false }
        let rest = trimmed[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty
    }

    private static func blockquoteContent(in line: String) -> String? {
        let leadingTrimmed = line.drop { $0 == " " || $0 == "\t" }
        guard leadingTrimmed.first == ">" else { return nil }
        var index = leadingTrimmed.index(after: leadingTrimmed.startIndex)
        if index < leadingTrimmed.endIndex,
           leadingTrimmed[index] == " " || leadingTrimmed[index] == "\t" {
            index = leadingTrimmed.index(after: index)
        }
        return String(leadingTrimmed[index...])
    }

    private static func nestedListBlockquoteContent(in line: String) -> String? {
        var indentation = 0
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == " " {
                indentation += 1
            } else if line[index] == "\t" {
                indentation += 4
            } else {
                break
            }
            index = line.index(after: index)
        }
        guard indentation >= 2,
              index < line.endIndex,
              line[index] == ">" else { return nil }
        index = line.index(after: index)
        if index < line.endIndex,
           line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    private static func headingContent(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }
        guard level > 0,
              index < trimmed.endIndex,
              trimmed[index] == " " || trimmed[index] == "\t" else { return nil }
        while index < trimmed.endIndex, trimmed[index] == " " || trimmed[index] == "\t" {
            index = trimmed.index(after: index)
        }
        var content = String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        content = content.replacingOccurrences(
            of: #"\s+#+\s*$"#,
            with: "",
            options: .regularExpression
        )
        guard !content.isEmpty else { return nil }
        return (level, content)
    }

    private static func listEntry(in line: String) -> MarkdownListEntry? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard !trimmed.isEmpty else { return nil }

        if let marker = trimmed.first, marker == "-" || marker == "+" || marker == "*" {
            let contentStart = trimmed.index(after: trimmed.startIndex)
            guard contentStart < trimmed.endIndex,
                  trimmed[contentStart] == " " || trimmed[contentStart] == "\t" else { return nil }
            let content = String(trimmed[contentStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return MarkdownListEntry(marker: "•", content: content, isOrdered: false)
        }

        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber {
            index = trimmed.index(after: index)
        }
        guard index > trimmed.startIndex,
              index < trimmed.endIndex,
              trimmed[index] == "." || trimmed[index] == ")" else { return nil }
        let number = String(trimmed[..<index])
        index = trimmed.index(after: index)
        guard index < trimmed.endIndex,
              trimmed[index] == " " || trimmed[index] == "\t" else { return nil }
        let content = String(trimmed[index...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return MarkdownListEntry(marker: "\(number).", content: content, isOrdered: true)
    }

    private struct StrongContinuationRepair {
        let reusableOpenerLineIndex: Int?
        let closerLineIndex: Int
    }

    private static func strongContinuationRepairBeforeNextBlock(
        startingAt startIndex: Int,
        in lines: [String]
    ) -> StrongContinuationRepair? {
        guard lines.indices.contains(startIndex) else { return nil }
        let upperBound = min(lines.count, startIndex + 16)
        var continuationDelimiterCount = 0
        var reusableOpenerLineIndex: Int?
        var firstContentSeen = false
        for index in startIndex..<upperBound {
            let line = lines[index]
            if MarkdownTableParser.parse(startingAt: index, in: lines) != nil {
                return nil
            }
            if isStrongContinuationBoundary(line) {
                return nil
            }
            var delimiterOffsets = strongDelimiterOffsets(in: line)
            if !firstContentSeen,
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                firstContentSeen = true
                if reusableLeadingStrongOpenerOffset(
                    in: line,
                    offsets: delimiterOffsets
                ) != nil {
                    reusableOpenerLineIndex = index
                    delimiterOffsets.removeFirst()
                }
            }
            continuationDelimiterCount += delimiterOffsets.count
            // The list entry already owns an odd delimiter count. Only an odd
            // continuation count actually balances it; a self-contained
            // `**bold**` paragraph must not be pulled into the list item.
            if !continuationDelimiterCount.isMultiple(of: 2) {
                return StrongContinuationRepair(
                    reusableOpenerLineIndex: reusableOpenerLineIndex,
                    closerLineIndex: index
                )
            }
            if continuationDelimiterCount > 0 {
                return nil
            }
        }
        return nil
    }

    private static func reusableLeadingStrongOpenerOffset(
        in line: String,
        offsets: [Int]
    ) -> Int? {
        // A self-contained `**bold**` line must keep the existing even-count
        // protection. Only reuse a single exact opener on the first prose line.
        guard offsets.count == 1 else { return nil }
        let characters = Array(line)
        let leadingWhitespaceCount = characters.prefix {
            $0 == " " || $0 == "\t"
        }.count
        let contentOffset = leadingWhitespaceCount + 2
        guard offsets[0] == leadingWhitespaceCount,
              contentOffset < characters.count,
              !characters[contentOffset].unicodeScalars.allSatisfy(
                CharacterSet.whitespacesAndNewlines.contains
              ) else { return nil }
        return leadingWhitespaceCount
    }

    private static func insertingStrongOpenerAfterLeadingWhitespace(in line: String) -> String {
        let characters = Array(line)
        let insertionOffset = characters.prefix {
            $0 == " " || $0 == "\t"
        }.count
        if insertionOffset + 1 < characters.count,
           characters[insertionOffset] == "*",
           characters[insertionOffset + 1] == "*" {
            return line
        }
        return String(characters[..<insertionOffset])
            + "**"
            + String(characters[insertionOffset...])
    }

    private static func movingWhitespaceAfterLastStrongDelimiter(in line: String) -> String {
        let characters = Array(line)
        guard let delimiterOffset = strongDelimiterOffsets(in: line).last else { return line }
        var whitespaceStart = delimiterOffset
        while whitespaceStart > 0 {
            let previous = characters[whitespaceStart - 1]
            guard previous == " " || previous == "\t" else { break }
            whitespaceStart -= 1
        }
        guard whitespaceStart < delimiterOffset else { return line }
        let leading = String(characters[..<whitespaceStart])
        let whitespace = String(characters[whitespaceStart..<delimiterOffset])
        let trailingStart = delimiterOffset + 2
        let trailing = trailingStart < characters.count
            ? String(characters[trailingStart...])
            : ""
        return leading + "**" + whitespace + trailing
    }

    private static func isStrongContinuationBoundary(_ line: String) -> Bool {
        openingFence(in: line) != nil
            || headingContent(in: line) != nil
            || blockquoteContent(in: line) != nil
            || listEntry(in: line) != nil
            || isHorizontalRule(line)
    }

    private static func hasUnclosedStrongDelimiter(_ source: String) -> Bool {
        var count = 0
        scanStrongDelimiters(in: source) { count += 1 }
        return !count.isMultiple(of: 2)
    }

    private static func scanStrongDelimiters(
        in source: String,
        onDelimiter: () -> Void
    ) {
        for _ in strongDelimiterOffsets(in: source) {
            onDelimiter()
        }
    }

    private static func strongDelimiterOffsets(in source: String) -> [Int] {
        let characters = Array(source)
        var offsets: [Int] = []
        var codeDelimiterLength: Int?
        var index = 0
        while index < characters.count {
            if characters[index] == "`", !isEscaped(characters, at: index) {
                let start = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }
                let runLength = index - start
                if codeDelimiterLength == runLength {
                    codeDelimiterLength = nil
                } else if codeDelimiterLength == nil {
                    codeDelimiterLength = runLength
                }
                continue
            }
            if codeDelimiterLength == nil,
               index + 1 < characters.count,
               characters[index] == "*",
               characters[index + 1] == "*",
               (index == 0 || characters[index - 1] != "*"),
               (index + 2 == characters.count || characters[index + 2] != "*"),
               !isEscaped(characters, at: index) {
                offsets.append(index)
                index += 2
                continue
            }
            index += 1
        }
        return offsets
    }

    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        var slashCount = 0
        var cursor = index - 1
        while characters[cursor] == "\\" {
            slashCount += 1
            guard cursor > 0 else { break }
            cursor -= 1
        }
        return !slashCount.isMultiple(of: 2)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "⸻" { return true }
        guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        var markerCount = 0
        for character in trimmed {
            if character == marker {
                markerCount += 1
            } else if character == " " || character == "\t" {
                continue
            } else {
                return false
            }
        }
        return markerCount >= 3
    }

    private static func trimOuterBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
