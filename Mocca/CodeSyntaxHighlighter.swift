import Foundation
import Highlighter
import JavaScriptCore

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

    private static let cacheEntryLimit = 32
    private static let cacheByteLimit = 2 * 1_024 * 1_024
    private static let cacheRunLimit = 24_000

    private var engine: CodeSyntaxRunEngine?
    private var attemptedInitialization = false
    private var supportedLanguages: Set<String> = []
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

        let key = isStreaming ? nil : CacheKey(
            source: Data(text.utf8), language: language, theme: theme
        )
        if let key, let runs = cache[key] {
            return runs
        }
        guard let engine = initializedEngine(),
              supportedLanguages.contains(language), !Task.isCancelled else { return [] }
        guard let runs = engine.highlight(text, language: language, theme: theme),
              !Task.isCancelled else { return [] }
        if let key { insert(runs, for: key) }
        return runs
    }

    private func initializedEngine() -> CodeSyntaxRunEngine? {
        if let engine { return engine }
        guard !attemptedInitialization else { return nil }
        attemptedInitialization = true
        guard let engine = CodeSyntaxRunEngine() else { return nil }
        supportedLanguages = engine.supportedLanguages
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

}

/// Actor-confined adapter for the pinned HighlighterSwift 3.1.0 resources
/// (highlight.js 11.11.1). Read token colors directly, avoiding an HTML round trip
/// and thousands of temporary attributed strings, fonts and paragraph styles.
private final class CodeSyntaxRunEngine {
    private let context: JSContext
    private let render: JSValue
    private let palettes: [CodeSyntaxTheme: [String: UInt32]]
    let supportedLanguages: Set<String>

    init?() {
        // Match the package's resource-bundle locations for apps, frameworks and
        // command-line tests. No path into a development checkout is used.
        let roots = [Bundle.main.resourceURL, Bundle(for: Highlighter.self).resourceURL,
                     Bundle.main.bundleURL]
        guard let bundle = roots.compactMap({ root in
            root.flatMap { Bundle(url: $0.appendingPathComponent("Highlighter_Highlighter.bundle")) }
        }).first,
              let scriptURL = bundle.url(forResource: "highlight.min", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let light = Self.palette(.light, in: bundle),
              let dark = Self.palette(.dark, in: bundle),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        guard context.exception == nil,
              let languages = context.objectForKeyedSubscript("hljs")?
                .invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String] else { return nil }
        context.evaluateScript(Self.adapter)
        guard context.exception == nil,
              let render = context.objectForKeyedSubscript("moccaColorRuns"),
              !render.isUndefined else { return nil }
        self.context = context
        self.render = render
        self.palettes = [.light: light, .dark: dark]
        supportedLanguages = Set(languages)
    }

    func highlight(_ text: String, language: String, theme: CodeSyntaxTheme) -> [CodeSyntaxColorRun]? {
        guard !Task.isCancelled, let palette = palettes[theme] else { return nil }
        context.exception = nil
        // User source is a function argument, never evaluated as JavaScript.
        // Transfer one compact string instead of bridging a JSValue/NSNumber for
        // every coordinate and color in a large block.
        guard let encoded = render.call(withArguments: [text, language, palette])?.toString(),
              context.exception == nil, !Task.isCancelled,
              let values = try? JSONDecoder().decode([Int].self, from: Data(encoded.utf8)),
              values.count.isMultiple(of: 3) else { return nil }
        let length = text.utf16.count
        var runs: [CodeSyntaxColorRun] = []
        runs.reserveCapacity(values.count / 3)
        var end = 0
        for index in stride(from: 0, to: values.count, by: 3) {
            let start = values[index], count = values[index + 1], rgb = values[index + 2]
            guard !Task.isCancelled, start == end, count > 0, start <= length,
                  count <= length - start, (0...0xFFFFFF).contains(rgb) else { return nil }
            runs.append(CodeSyntaxColorRun(range: NSRange(location: start, length: count), rgb: UInt32(rgb)))
            end = start + count
        }
        return end == length ? runs : nil
    }

    private static func palette(_ theme: CodeSyntaxTheme, in bundle: Bundle) -> [String: UInt32]? {
        guard let url = bundle.url(forResource: theme.resourceName, withExtension: "css"),
              let rawCSS = try? String(contentsOf: url, encoding: .utf8),
              let rules = try? NSRegularExpression(pattern: #"([^{}]+)\{([^}]+)\}"#),
              let color = try? NSRegularExpression(pattern: #"(?:^|;)\s*color\s*:\s*#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b"#)
        else { return nil }
        let css = rawCSS.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        let source = css as NSString
        var palette: [String: UInt32] = [:]
        for rule in rules.matches(in: css, range: NSRange(location: 0, length: source.length)) {
            let body = source.substring(with: rule.range(at: 2))
            guard let match = color.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { continue }
            var hex = (body as NSString).substring(with: match.range(at: 1))
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let rgb = UInt32(hex, radix: 16) else { continue }
            for selector in source.substring(with: rule.range(at: 1)).split(separator: ",") {
                let name = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                // Preserve the existing wrapper's first-class scope semantics.
                // Compound selectors and font/background declarations aren't used.
                guard name == ".hljs" || (name.hasPrefix(".hljs-")
                    && name.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })) else { continue }
                palette[String(name.dropFirst())] = rgb
            }
        }
        return palette["hljs"] == nil ? nil : palette
    }

    private static let adapter = #"""
    // Keep the grammar's complete token tree: splitting long sources into lines
    // would break multiline strings/comments and embedded languages.
    const MoccaEmitter = hljs.highlight("", {language: "plaintext"})._emitter.constructor;
    hljs.configure({__emitter: class extends MoccaEmitter { toHTML() { return ""; } }});
    function moccaColorRuns(source, language, palette) {
        const result = hljs.highlight(source, {language: language, ignoreIllegals: true});
        if (result.errorRaised || !result._emitter) return null;
        const colors = [palette.hljs], runs = [];
        let offset = 0, valid = true;
        result._emitter.walk({
            openNode(node) {
                const scope = node.scope || "";
                const key = "hljs-" + scope.split(".")[0];
                colors.push(palette[key] ?? colors[colors.length - 1]);
            },
            closeNode() { colors.pop(); },
            addText(text) {
                if (!text.length) return;
                if (source.slice(offset, offset + text.length) !== text) valid = false;
                const rgb = colors[colors.length - 1];
                if (runs.length && runs[runs.length - 1] === rgb) {
                    runs[runs.length - 2] += text.length;
                } else {
                    runs.push(offset, text.length, rgb);
                }
                offset += text.length; // JavaScript offsets are UTF-16, like NSRange.
            }
        });
        return valid && offset === source.length ? JSON.stringify(runs) : null;
    }
    """#
}
