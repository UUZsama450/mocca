"""Exercise production preparation caching and table measurement with simulator UIKit.

This is semantic/work-count evidence, not iPhone timing or FPS. The extracted
cache is unchanged; both table variants call real UIFont/NSString measurement.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve()
device = sys.argv[2]
out.mkdir(parents=True, exist_ok=True)
source = (root / 'Mocca/MessageMarkdownView.swift').read_text()
base = subprocess.check_output(['git', 'show', 'a29bf62:Mocca/MessageMarkdownView.swift'], cwd=root, text=True)

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

cache = block(source, 'private final class SettledMarkdownPreparationCache').replace('private final', '@MainActor final', 1)
types = (root / 'Mocca/MarkdownTableSupport.swift').read_text().split('struct MarkdownTableParseResult:')[0]
tables = []
for name, text in [('Baseline', base), ('Candidate', source)]:
    members = '\n'.join(block(text, marker).replace('private ', '') for marker in [
        'private var tableFontSize:', 'private var measuredColumnWidths:', 'private func measuredWidth('])
    members = members.replace('func measuredWidth(_ source: String, font: UIFont) -> CGFloat {',
                              'func measuredWidth(_ source: String, font: UIFont) -> CGFloat {\n calls += 1\n return')
    tables.append(f'''@MainActor final class {name} {{
        var table: MarkdownTableContent
        var fontSize: CGFloat = 18
        var fontName: String? = nil
        var usesCache = true
        var calls = 0
        init(_ table: MarkdownTableContent) {{ self.table = table }}
        {members}
    }}''')

harness = r'''
import UIKit
import Foundation
enum AppFontStore {
    static func uiFont(postScriptName: String?, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        if let name = postScriptName, let font = UIFont(name: name, size: size) { return font }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }
}
@main struct Checks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                FileHandle.standardError.write(Data("FAIL at \(checks): \(message)\n".utf8))
                exit(1)
            }
            checks += 1
        }
        let cache = SettledMarkdownPreparationCache.shared
        typealias Key = SettledMarkdownPreparationCache.ProseKey
        func key(_ source: String, _ signature: String = "style-18", dark: Bool = false) -> Key {
            Key(signature: signature, source: source, interfaceStyle: dark ? .dark : .light, contrast: .normal)
        }
        let content = String(repeating: "中文长正文 é 👨‍👩‍👧‍👦 العربية **bold** link\n", count: 120)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let original = NSMutableAttributedString(string: content, attributes: [
            .font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.label, .paragraphStyle: style
        ])
        original.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 5))
        original.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 18), range: NSRange(location: 6, length: 20))
        var builds = 0
        func build() -> NSAttributedString { builds += 1; return original }
        let cold = cache.prose(for: key(content), make: build)
        let warm = cache.prose(for: key(content), make: build)
        check(builds == 1, "a new consumer reuses the prepared text")
        check(cold.isEqual(to: original) && warm.isEqual(to: original), "all attributes and text preserved")
        var layoutPairs = 0
        for width in [280.0, 356.0, 402.0, 600.0] {
            let oldView = UITextView(), newView = UITextView()
            for view in [oldView, newView] {
                view.isScrollEnabled = false
                view.textContainerInset = .zero
                view.textContainer.lineFragmentPadding = 0
                view.layoutManager.allowsNonContiguousLayout = false
            }
            oldView.attributedText = original
            newView.attributedText = warm
            let proposal = CGSize(width: width, height: .greatestFiniteMagnitude)
            let before = oldView.sizeThatFits(proposal), after = newView.sizeThatFits(proposal)
            check(before == after && before.height > 1_000, "UIKit full height and width unchanged")
            check(newView.textStorage.isEqual(to: oldView.textStorage), "native backing attributes identical")
            newView.selectedRange = NSRange(location: 0, length: 5)
            check(newView.selectedRange == NSRange(location: 0, length: 5), "selection remains available")
            newView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "改")
            check(warm.string == content, "a native text storage cannot mutate the cached string")
            layoutPairs += 1
        }
        let changedStyle = NSMutableParagraphStyle()
        changedStyle.lineSpacing = 30
        original.addAttribute(.paragraphStyle, value: changedStyle, range: NSRange(location: 0, length: original.length))
        check((warm.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing == 4,
              "replacing a producer's attribute preserves the cached value")
        _ = cache.prose(for: key(content, "font-22"), make: build)
        _ = cache.prose(for: key(content, dark: true), make: build)
        _ = cache.prose(for: key(content + "changed"), make: build)
        check(builds == 4, "font, appearance, and exact content invalidate independently")
        cache.removeAll()
        builds = 0
        for index in 0..<5 { _ = cache.prose(for: key("source-\(index)"), make: build) }
        _ = cache.prose(for: key("source-0"), make: build)
        check(builds == 6, "entry limit evicts the oldest prepared text")
        let huge = NSAttributedString(string: String(repeating: "字", count: 140_000))
        builds = 0
        for _ in 0..<2 { _ = cache.prose(for: key("huge")) { builds += 1; return huge } }
        check(builds == 2, "oversized attributed text is not retained")
        let attachmentText = NSMutableAttributedString(attributedString: original)
        attachmentText.append(NSAttributedString(attachment: NSTextAttachment()))
        builds = 0
        for _ in 0..<2 { _ = cache.prose(for: key("attachment")) { builds += 1; return attachmentText } }
        check(builds == 2, "mutable attachments are never shared")
        cache.removeAll()
        builds = 0
        _ = cache.prose(for: key(content), make: build)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        _ = cache.prose(for: key(content), make: build)
        check(builds == 2, "memory pressure releases preparations")

        cache.removeAll()
        builds = 0
        let budgetText = NSAttributedString(string: String(repeating: "字", count: 50_000))
        for name in ["one", "two", "three", "two", "one"] {
            _ = cache.prose(for: key(name)) { builds += 1; return budgetText }
        }
        check(builds == 4, "total weight evicts before reaching four entries")
        _ = cache.prose(for: Key(signature: "style-18", source: "one", interfaceStyle: .light, contrast: .high)) {
            builds += 1; return budgetText
        }
        check(builds == 5, "accessibility contrast invalidates prepared text")

        var tablePairs = 0
        var avoidedMeasurements = 0
        for rowCount in [0, 1, 23, 24, 48, 160] {
            for columns in [1, 3, 7] {
                for saturated in [false, true] {
                    let table = MarkdownTableContent(header: (0..<columns).map { "表头 \($0)" },
                        alignments: Array(repeating: .leading, count: columns),
                        rows: (0..<rowCount).map { row in (0..<columns).map { col in
                            saturated ? String(repeating: "long 中文 ", count: 30) : "\(row)-\(col) 中文 é"
                        } })
                    for fontSize in [14.0, 18.0, 24.0] {
                        cache.removeAll()
                        let old = Baseline(table), new = Candidate(table)
                        old.fontSize = fontSize; new.fontSize = fontSize
                        let expected = old.measuredColumnWidths
                        check(new.measuredColumnWidths == expected, "cold column widths equal")
                        let coldCalls = new.calls
                        check(coldCalls == old.calls, "cold path keeps the same measurement algorithm")
                        check(new.measuredColumnWidths == expected, "warm column widths equal")
                        let allCells = table.header + table.rows.flatMap { $0 }
                        let weight = allCells.map { $0.utf16.count }.reduce(0, +)
                            + 16 * (allCells.count + table.rows.count)
                        if rowCount >= 24 && weight <= 131_072 {
                            check(new.calls == coldCalls, "warm long table does no cell width measurement")
                            avoidedMeasurements += coldCalls
                        }
                        new.usesCache = false
                        _ = new.measuredColumnWidths
                        check(new.calls > coldCalls, "streaming bypasses preparation cache")
                        tablePairs += 1
                    }
                }
            }
        }
        let changed = MarkdownTableContent(header: ["a"], alignments: [.leading], rows: Array(repeating: ["b"], count: 30))
        let test = Candidate(changed)
        _ = test.measuredColumnWidths
        test.table = MarkdownTableContent(header: ["a"], alignments: [.leading], rows: Array(repeating: ["a much wider cell value"], count: 30))
        check(test.measuredColumnWidths == Baseline(test.table).measuredColumnWidths, "editing cell invalidates widths")
        test.fontName = "Courier"
        let otherFont = Baseline(test.table); otherFont.fontName = "Courier"
        let beforeFont = test.calls
        check(test.measuredColumnWidths == otherFont.measuredColumnWidths && test.calls > beforeFont,
              "resolved font changes invalidate column widths")
        let beforeWarning = test.calls
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        _ = test.measuredColumnWidths
        check(test.calls > beforeWarning, "memory pressure releases table widths")
        cache.removeAll()
        let emptyMatrix = MarkdownTableContent(header: Array(repeating: "", count: 30),
            alignments: Array(repeating: .leading, count: 30),
            rows: Array(repeating: Array(repeating: "", count: 30), count: 300))
        let empty = Candidate(emptyMatrix)
        _ = empty.measuredColumnWidths
        let beforeEmptyWarm = empty.calls
        _ = empty.measuredColumnWidths
        check(empty.calls > beforeEmptyWarm, "empty matrices still obey retention weight")
        cache.removeAll()
        let oldestTable = Candidate(changed)
        _ = oldestTable.measuredColumnWidths
        for index in 0..<4 {
            let next = Candidate(MarkdownTableContent(header: ["header-\(index)"], alignments: [.leading], rows: changed.rows))
            _ = next.measuredColumnWidths
        }
        let beforeEviction = oldestTable.calls
        _ = oldestTable.measuredColumnWidths
        check(oldestTable.calls > beforeEviction, "table entry count evicts the oldest key")
        let result: [String: Any] = ["passed": true, "assertions": checks, "uikitLayoutPairs": layoutPairs,
            "tablePairs": tablePairs, "avoidedWarmCellMeasurements": avoidedMeasurements,
            "limitation": "Simulator UIKit semantics and work counts only; no iPhone performance claim"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: data, as: UTF8.self))
    }
}
'''
generated = out / 'Checks.swift'
generated.write_text('import UIKit\n' + types + cache + '\n' + '\n'.join(tables) + '\n' + harness)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
binary = out / 'checks'
command = ['xcrun', 'swiftc', '-swift-version', '6', '-O', '-parse-as-library', '-sdk', sdk,
           '-target', 'x86_64-apple-ios18.0-simulator', '-module-cache-path', str(out / 'ModuleCache'),
           str(generated), '-o', str(binary)]
with (out / 'compile.log').open('w') as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
subprocess.run(['xcrun', 'simctl', 'spawn', device, str(binary), str(out / 'result.json')], check=True)
(out / 'source.json').write_text(json.dumps({'sha256': hashlib.sha256(source.encode()).hexdigest(),
    'baseline_sha256': hashlib.sha256(base.encode()).hexdigest()}, indent=2))
