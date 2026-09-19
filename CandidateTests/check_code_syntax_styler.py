#!/usr/bin/env python3
"""Compile the production color scheduler against Foundation and controlled hosts.

This checks scheduling and attributed-string semantics, not UIKit rendering,
TextKit layout, selection interaction, or physical-device frame performance.
"""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Mocca/CodeSyntaxTextStyler.swift"

PRELUDE = r'''
import Foundation

extension NSAttributedString.Key {
    static let foregroundColor = Self("foregroundColor")
    static let font = Self("font")
    static let paragraphStyle = Self("paragraphStyle")
}

final class UIColor: NSObject, @unchecked Sendable {
    let rgb: UInt32
    init(rgb: UInt32) { self.rgb = rgb }
    convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(rgb: UInt32((red * 255).rounded()) << 16
            | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded()))
    }
    static let label = UIColor(rgb: 0x111111)
    override func isEqual(_ object: Any?) -> Bool { (object as? UIColor)?.rgb == rgb }
    override var hash: Int { Int(rgb) }
}

@MainActor final class RecordedStorage {
    var value: NSMutableAttributedString
    var writes: [(NSAttributedString.Key, NSRange)] = []
    var editingDepth = 0
    init(_ text: String) {
        value = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: UIColor.label, .font: "original-font", .paragraphStyle: "original-paragraph"
        ])
    }
    var string: String { value.string }
    var length: Int { value.length }
    func beginEditing() { editingDepth += 1; value.beginEditing() }
    func endEditing() { editingDepth -= 1; value.endEditing() }
    func addAttribute(_ key: NSAttributedString.Key, value attr: Any, range: NSRange) {
        writes.append((key, range)); value.addAttribute(key, value: attr, range: range)
    }
    func append(_ text: String) {
        value.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: UIColor.label, .font: "original-font", .paragraphStyle: "original-paragraph"
        ]))
    }
    func reset(_ text: String) { value = RecordedStorage(text).value; writes = [] }
    func color(_ index: Int) -> UInt32? {
        (value.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor)?.rgb
    }
}

@MainActor final class UITextView {
    let textStorage: RecordedStorage
    var selectedRange = NSRange(location: 1, length: 1)
    var contentOffset = CGPoint(x: 3, y: 5)
    var contentSize = CGSize(width: 123, height: 456)
    var containerSize = CGSize(width: 789, height: 321)
    var invalidationCount = 0
    init(_ text: String) { textStorage = RecordedStorage(text) }
}

enum CodeSyntaxTheme: Sendable, Hashable { case light, dark }
struct CodeSyntaxColorRun: Sendable, Equatable { let range: NSRange; let rgb: UInt32 }
actor CodeSyntaxHighlighter {
    static let shared = CodeSyntaxHighlighter()
    struct Call: Sendable { let text: String; let language: String; let theme: CodeSyntaxTheme; let streaming: Bool }
    private var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<[CodeSyntaxColorRun], Never>] = [:]
    private var maximumPending = 0
    nonisolated static func normalizedLanguage(_ value: String) -> String {
        let v = value.lowercased(); return v == "js" ? "javascript" : v
    }
    func highlight(text: String, language: String, theme: CodeSyntaxTheme, isStreaming: Bool) async -> [CodeSyntaxColorRun] {
        let id = calls.count
        calls.append(Call(text: text, language: language, theme: theme, streaming: isStreaming))
        return await withCheckedContinuation { continuation in
            pending[id] = continuation; maximumPending = max(maximumPending, pending.count)
        }
    }
    func count() -> Int { calls.count }
    func call(_ id: Int) -> Call { calls[id] }
    func maximum() -> Int { maximumPending }
    func complete(_ id: Int, _ result: [CodeSyntaxColorRun]) {
        pending.removeValue(forKey: id)!.resume(returning: result)
    }
}
'''

TESTS = r'''
struct Failure: Error, CustomStringConvertible { let description: String }
@main struct Run {
    @MainActor static func check(_ result: @autoclosure () -> Bool, _ message: String) throws {
        if !result() { throw Failure(description: message) }
    }
    @MainActor static func spin() async { for _ in 0..<80 { await Task.yield() } }
    @MainActor static func calls(_ n: Int) async throws {
        for _ in 0..<20_000 {
            if await CodeSyntaxHighlighter.shared.count() >= n { return }
            await Task.yield()
        }
        throw Failure(description: "timeout waiting for call count \(n)")
    }
    static func r(_ start: Int, _ length: Int, _ rgb: UInt32 = 0xff0000) -> CodeSyntaxColorRun {
        CodeSyntaxColorRun(range: NSRange(location: start, length: length), rgb: rgb)
    }
    @MainActor static func update(_ s: CodeSyntaxTextStyler, _ v: UITextView, _ text: String,
                                  theme: CodeSyntaxTheme = .light, stream: Bool = true, language: String = "swift") {
        s.update(textView: v, text: text, language: language, theme: theme,
                 isStreaming: stream, baseColor: .label)
    }
    @MainActor static func done(_ id: Int, _ result: [CodeSyntaxColorRun]) async {
        await CodeSyntaxHighlighter.shared.complete(id, result); await spin()
    }
    @MainActor static func invariant(_ v: UITextView, text: String) throws {
        try check(v.textStorage.string.utf16.elementsEqual(text.utf16), "text mutated")
        try check(v.selectedRange == NSRange(location: 1, length: 1), "selection mutated")
        try check(v.contentOffset.x == 3 && v.contentOffset.y == 5, "scroll offset mutated")
        try check(v.contentSize.width == 123 && v.contentSize.height == 456, "content size mutated")
        try check(v.containerSize.width == 789 && v.containerSize.height == 321, "container size mutated")
        try check(v.invalidationCount == 0 && v.textStorage.editingDepth == 0, "layout invalidated or edit unbalanced")
        for i in 0..<v.textStorage.length {
            try check(v.textStorage.value.attribute(.font, at: i, effectiveRange: nil) as? String == "original-font", "font mutated")
            try check(v.textStorage.value.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? String == "original-paragraph", "paragraph mutated")
        }
        try check(v.textStorage.writes.allSatisfy { $0.0 == .foregroundColor }, "non-color attribute write")
    }
    @MainActor static func main() async throws {
        var passed = 0
        // One in flight and only the latest pending source survives.
        do {
            let s = CodeSyntaxTextStyler(), v = UITextView("a")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, "a"); try await calls(i + 1)
            v.textStorage.append("b"); update(s, v, "ab")
            v.textStorage.append("c"); update(s, v, "abc")
            
            await spin()
            let before = await CodeSyntaxHighlighter.shared.count()
            try check(before == i + 1, "more than one active analysis")
            await done(i, [r(0, 1)])
            try await calls(i + 2)
            try check(v.textStorage.writes.isEmpty, "old source result applied")
            let latest = await CodeSyntaxHighlighter.shared.call(i + 1)
            try check(latest.text == "abc", "intermediate request was analyzed")
            await done(i + 1, [r(0, 3)])
            try check(v.textStorage.color(2) == 0xff0000, "latest result not applied")
            try invariant(v, text: "abc")
            update(s, v, "abc"); await spin()
            let after = await CodeSyntaxHighlighter.shared.count()
            try check(after == i + 2, "identical request repeated")
            passed += 1
        }
        // A theme or language change invalidates a suspended old request.
        for changeLanguage in [false, true] {
            let s = CodeSyntaxTextStyler(), v = UITextView("text")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, "text"); try await calls(i + 1)
            update(s, v, "text", theme: changeLanguage ? .light : .dark,
                   language: changeLanguage ? "javascript" : "swift")
            await done(i, [r(0, 4)])
            try await calls(i + 2)
            try check(v.textStorage.writes.isEmpty, "old theme/language result applied")
            await done(i + 1, [r(0, 4, 0x00ff00)])
            try check(v.textStorage.color(0) == 0x00ff00, "new theme/language result missing")
            try invariant(v, text: "text"); passed += 1
        }
        // Cancellation is effective even if the backend ignores task cancellation.
        do {
            let s = CodeSyntaxTextStyler(), v = UITextView("cancel")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, "cancel"); try await calls(i + 1); s.cancel()
            await done(i, [r(0, 6)])
            try check(v.textStorage.writes.isEmpty, "cancelled request wrote colors")
            try invariant(v, text: "cancel"); passed += 1
        }
        // Weak view capture cannot retain a dismantled host.
        do {
            let s = CodeSyntaxTextStyler()
            var v: UITextView? = UITextView("gone")
            weak let weakView = v
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v!, "gone"); try await calls(i + 1); s.cancel(); v = nil
            try check(weakView == nil, "dismantled view retained")
            await done(i, [r(0, 4)]); passed += 1
        }
        // Preserve existing prefix colors while appending, then repaint only changed suffix.
        do {
            let s = CodeSyntaxTextStyler(), v = UITextView("abcdef")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, "abcdef"); try await calls(i + 1)
            let prefix = [r(0, 2), r(4, 2, 0x0000ff)]
            await done(i, prefix); v.textStorage.writes = []
            v.textStorage.append("ghi"); update(s, v, "abcdefghi"); try await calls(i + 2)
            try check(v.textStorage.color(0) == 0xff0000, "append cleared existing colors")
            await done(i + 1, prefix + [r(6, 3, 0x00ff00)])
            try check(v.textStorage.writes.count == 2, "unnecessary color write count")
            try check(v.textStorage.writes.allSatisfy { $0.1 == NSRange(location: 6, length: 3) }, "unchanged prefix repainted")
            try invariant(v, text: "abcdefghi"); passed += 1
            // Empty result restores plain foreground without affecting layout attributes.
            v.textStorage.writes = []
            update(s, v, "abcdefghi", stream: false); try await calls(i + 3)
            await done(i + 2, [])
            try check((0..<9).allSatisfy { v.textStorage.color($0) == UIColor.label.rgb }, "empty result retained old colors")
            try invariant(v, text: "abcdefghi"); passed += 1
        }
        // Same text must be retried on stream completion and on storage/style reset.
        do {
            let s = CodeSyntaxTextStyler(), v = UITextView("same")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, "same"); try await calls(i + 1)
            update(s, v, "same", stream: false)
            await done(i, [r(0, 4)]); try await calls(i + 2)
            try check(v.textStorage.writes.isEmpty, "stream result applied after completion")
            let settled = await CodeSyntaxHighlighter.shared.call(i + 1)
            try check(!settled.streaming, "settled state not submitted")
            await done(i + 1, [r(0, 4)])
            v.textStorage.reset("same"); s.resetColors()
            update(s, v, "same", stream: false); try await calls(i + 3)
            await done(i + 2, [r(0, 4, 0x0000ff)])
            try check(v.textStorage.color(0) == 0x0000ff, "reset failed to recolor same source")
            try invariant(v, text: "same"); passed += 1
        }
        // Collapse/expand replaces text; source generation rejects the old longer result.
        do {
            let s = CodeSyntaxTextStyler(), v = UITextView("long\nlong")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, v.textStorage.string); try await calls(i + 1)
            v.textStorage.reset("long"); s.resetColors(); update(s, v, "long")
            await done(i, [r(0, 9)]); try await calls(i + 2)
            try check(v.textStorage.writes.isEmpty, "expanded result applied after collapse")
            await done(i + 1, [r(0, 4)])
            try invariant(v, text: "long"); passed += 1
        }
        // Swift String's canonical equality must not mix distinct UTF-16 coordinates.
        do {
            let old = "\u{00e9}👨‍👩‍👧‍👦<&\"\n", new = "e\u{0301}👨‍👩‍👧‍👦<&\"\n"
            try check(old == new && old.utf16.count != new.utf16.count, "invalid Unicode fixture")
            let s = CodeSyntaxTextStyler(), v = UITextView(old)
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, old); try await calls(i + 1)
            v.textStorage.reset(new); s.resetColors(); update(s, v, new)
            await done(i, [r(0, old.utf16.count)]); try await calls(i + 2)
            try check(v.textStorage.writes.isEmpty, "canonical-equivalent old source applied")
            await done(i + 1, [r(0, new.utf16.count)])
            try invariant(v, text: new); passed += 1
        }
        // Externally replaced storage and malformed ranges fail without writes.
        do {
            let s = CodeSyntaxTextStyler(), v = UITextView("before")
            let i = await CodeSyntaxHighlighter.shared.count()
            update(s, v, "before"); try await calls(i + 1)
            v.textStorage.reset("after")
            await done(i, [r(0, 6)])
            try check(v.textStorage.writes.isEmpty, "externally replaced storage colored")
            s.resetColors(); update(s, v, "after"); try await calls(i + 2)
            await done(i + 1, [r(0, 99)])
            try check(v.textStorage.writes.isEmpty, "invalid range colored")
            try invariant(v, text: "after"); passed += 1
        }
        let maximum = await CodeSyntaxHighlighter.shared.maximum()
        try check(maximum == 1, "more than one analysis in flight in a host lifecycle")
        print("PASS \(passed) scheduler/foreground-only semantic cases; no UIKit pixel or phone-performance claim")
    }
}
'''

def main():
    source = SOURCE.read_text()
    assert source.startswith("import UIKit\n")
    integration = (ROOT / "Mocca/MessageMarkdownView.swift").read_text()
    for fragment in (
        "coordinator.syntaxColors.cancel()",
        "UIPasteboard.general.string = displayCode",
        "text: visibleCode,",
        "return context.coordinator.measuredSize",
        "isStreaming: !usesSharedMeasurementCache",
    ):
        assert fragment in integration, fragment
    with tempfile.TemporaryDirectory(prefix="mocca-code-syntax-styler-") as folder:
        path = pathlib.Path(folder)
        swift = path / "StylerSemanticTests.swift"
        swift.write_text(PRELUDE + source.removeprefix("import UIKit\n") + TESTS)
        exe = path / "StylerSemanticTests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                        str(swift), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)

if __name__ == "__main__":
    main()
