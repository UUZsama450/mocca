import Foundation
import Highlighter
#if canImport(UIKit)
import UIKit
private typealias CodeSyntaxNativeColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias CodeSyntaxNativeColor = NSColor
#endif

enum CodeSyntaxTheme: Sendable, Hashable {
    case light
    case dark

    fileprivate var resourceName: String {
        switch self {
        case .light: "xcode"
        case .dark: "atom-one-dark"
        }
    }
}

struct CodeSyntaxColorRun: Sendable, Equatable {
    let range: NSRange
    let rgb: UInt32
}

/// Own the synchronous parser on one actor; no UIKit view or styled text crosses it.
actor CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()

    private static let streamingUTF16Limit = 8 * 1_024
    private static let settledUTF16Limit = 32 * 1_024
    private static let runLimit = 3_000
    private static let cacheEntryLimit = 32
    private static let cacheByteLimit = 2 * 1_024 * 1_024
    private static let cacheRunLimit = 24_000

    private var engine: Highlighter?
    private var attemptedInitialization = false
    private var supportedLanguages: Set<String> = []
    private var activeTheme: CodeSyntaxTheme?
    private var cache: [CacheKey: [CodeSyntaxColorRun]] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cachedBytes = 0
    private var cachedRuns = 0

    private struct CacheKey: Hashable {
        // String equality normalizes Unicode; byte identity keeps NSRange exact.
        let source: Data
        let language: String
        let theme: CodeSyntaxTheme
    }

    nonisolated static func normalizedLanguage(_ language: String) -> String {
        let token = language
            .drop(while: { $0.isWhitespace })
            .prefix(while: { !$0.isWhitespace })
        guard !token.isEmpty, token.utf8.count <= 64 else { return "" }
        let name = token.lowercased()
        switch name {
        case "text", "txt", "plaintext", "plain", "none": return ""
        case "py", "python3": return "python"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "sh", "zsh", "shellscript": return "bash"
        case "console": return "shell"
        case "c++", "cc", "cxx", "h++", "hpp": return "cpp"
        case "c#", "cs": return "csharp"
        case "html", "htm", "xhtml", "svg": return "xml"
        case "objc", "objective-c", "objectivec++": return "objectivec"
        case "md", "mkdown", "mkd": return "markdown"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "golang": return "go"
        case "kt", "kts": return "kotlin"
        case "yml": return "yaml"
        case "ps", "ps1": return "powershell"
        case "docker": return "dockerfile"
        default: return name
        }
    }

    func highlight(
        text: String,
        language: String,
        theme: CodeSyntaxTheme,
        isStreaming: Bool
    ) async -> [CodeSyntaxColorRun] {
        guard !Task.isCancelled, !text.isEmpty else { return [] }
        let language = Self.normalizedLanguage(language)
        guard !language.isEmpty else { return [] }
        let limit = isStreaming ? Self.streamingUTF16Limit : Self.settledUTF16Limit
        let length = text.utf16.prefix(limit + 1).count
        // A long source stays readable in its original colour; never truncate it.
        guard length <= limit, !Task.isCancelled else { return [] }

        let key = isStreaming ? nil : CacheKey(
            source: Data(text.utf8), language: language, theme: theme
        )
        if let key, let runs = cache[key] { return runs }
        guard let engine = initializedEngine(),
              supportedLanguages.contains(language), !Task.isCancelled else { return [] }
        if activeTheme != theme {
            guard engine.setTheme(theme.resourceName) else { return [] }
            activeTheme = theme
        }
        guard !Task.isCancelled,
              let highlighted = engine.highlight(text, as: language, doFastRender: true),
              !Task.isCancelled,
              highlighted.length == length,
              highlighted.string.utf16.elementsEqual(text.utf16) else { return [] }

        var runs: [CodeSyntaxColorRun] = []
        var invalidResult = false
        highlighted.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: length)
        ) { value, range, stop in
            guard !Task.isCancelled,
                  range.location != NSNotFound, range.location <= length,
                  range.length <= length - range.location else {
                invalidResult = true
                stop.pointee = true
                return
            }
            guard range.length > 0,
                  let color = value as? CodeSyntaxNativeColor,
                  let rgb = Self.rgb(color) else { return }
            if let previous = runs.last, previous.rgb == rgb,
               NSMaxRange(previous.range) == range.location {
                runs[runs.count - 1] = CodeSyntaxColorRun(
                    range: NSRange(location: previous.range.location,
                                   length: previous.range.length + range.length),
                    rgb: rgb
                )
            } else {
                guard runs.count < Self.runLimit else {
                    invalidResult = true
                    stop.pointee = true
                    return
                }
                runs.append(CodeSyntaxColorRun(range: range, rgb: rgb))
            }
        }
        guard !invalidResult, !Task.isCancelled else { return [] }
        if let key { insert(runs, for: key) }
        return runs
    }

    private func initializedEngine() -> Highlighter? {
        if let engine { return engine }
        guard !attemptedInitialization else { return nil }
        attemptedInitialization = true
        guard let engine = Highlighter() else { return nil }
        engine.ignoreIllegals = true
        supportedLanguages = Set(engine.supportedLanguages())
        self.engine = engine
        return engine
    }

    private func insert(_ runs: [CodeSyntaxColorRun], for key: CacheKey) {
        let cost = key.source.count + runs.count * MemoryLayout<CodeSyntaxColorRun>.stride
        guard cost <= Self.cacheByteLimit, runs.count <= Self.cacheRunLimit,
              cache[key] == nil else { return }
        // Settled results only. FIFO eviction bounds both source bytes and spans.
        while !cacheOrder.isEmpty,
              cacheOrder.count >= Self.cacheEntryLimit
                || cachedBytes + cost > Self.cacheByteLimit
                || cachedRuns + runs.count > Self.cacheRunLimit {
            let oldest = cacheOrder.removeFirst()
            if let evicted = cache.removeValue(forKey: oldest) {
                cachedBytes -= oldest.source.count
                    + evicted.count * MemoryLayout<CodeSyntaxColorRun>.stride
                cachedRuns -= evicted.count
            }
        }
        cache[key] = runs
        cacheOrder.append(key)
        cachedBytes += cost
        cachedRuns += runs.count
    }

    private static func rgb(_ color: CodeSyntaxNativeColor) -> UInt32? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #if canImport(UIKit)
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #elseif canImport(AppKit)
        guard let color = color.usingColorSpace(.deviceRGB) else { return nil }
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        guard red.isFinite, green.isFinite, blue.isFinite else { return nil }
        func byte(_ value: CGFloat) -> UInt32 {
            UInt32((min(1, max(0, value)) * 255).rounded())
        }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
