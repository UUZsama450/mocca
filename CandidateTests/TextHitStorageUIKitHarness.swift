// Standalone UIKit harness, following ComposerSelectionGateHarness's app pattern.
// The generator inserts actual baseline/candidate methods. This file is not in
// the shipping Xcode target. All text and query coordinates are synthetic.
import UIKit
import Darwin

enum HitMethod: String, CaseIterable { case glyph, visible }

@MainActor
class CountingNativeTextView: UITextView {
    var countGetterReads = false
    var getterReads = 0

    override var attributedText: NSAttributedString! {
        get {
            if countGetterReads { getterReads += 1 }
            return super.attributedText
        }
        set { super.attributedText = newValue }
    }

    init(width: CGFloat) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 280), textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        contentInset = .zero
        textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        container.widthTracksTextView = true
        manager.allowsNonContiguousLayout = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func query(_ method: HitMethod, _ point: CGPoint) -> Bool { fatalError("Use extracted subclass") }
}

// SOURCE_EXTRACTED_PROBE_CLASSES

@main
@MainActor
final class TextHitStorageUIKitHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var rows: [[String: Any]] = []
    private var failures: [String] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { self.run() }
        return true
    }

    private func fixtures() -> [(String, NSAttributedString)] {
        let font = UIFont.systemFont(ofSize: 18)
        func prose(_ value: String) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            return NSAttributedString(string: value, attributes: [.font: font, .paragraphStyle: paragraph])
        }
        func attachment() -> NSAttributedString {
            let item = NSTextAttachment()
            item.bounds = CGRect(x: 0, y: -3, width: 24, height: 20)
            return NSAttributedString(attachment: item)
        }
        let inline = NSMutableAttributedString(attributedString: prose("前文 "))
        inline.append(attachment())
        inline.append(prose(" 后文\n第二行"))
        let linked = NSMutableAttributedString(attributedString: prose("链接 说明文字\n第二行"))
        linked.addAttribute(.link, value: URL(string: "https://example.invalid/synthetic")!,
                            range: NSRange(location: 0, length: 2))
        return [
            ("empty-initial", prose("")),
            ("chinese", prose("普通中文，包含标点与空格。\n第二行文字测试")),
            ("emoji-combining", prose("A👨‍👩‍👧‍👦 🇨🇳 👍🏽 e\u{301} 中文\n👩‍💻结束")),
            ("attachment-only", attachment()),
            ("attachment-inline", inline),
            ("link", linked),
            ("replacement-long", prose(String(repeating: "长内容中文与空格 abc。\n", count: 16))),
            ("replacement-short", prose("短句")),
            ("replacement-empty", prose("")),
            ("replacement-recovered", prose("清空后恢复文字 👩‍💻")),
        ]
    }

    private func initialPoints(width: CGFloat) -> [CGPoint] {
        [-1, 0, 4, 12, width / 2, width - 1, width + 1].flatMap { x in
            [-1, 0, 4, 12, 30, 60, 140, 281].map { y in CGPoint(x: x, y: CGFloat(y)) }
        }
    }

    private func glyphBoundaryPoints(_ view: CountingNativeTextView) -> [CGPoint] {
        view.layoutManager.ensureLayout(for: view.textContainer)
        let count = view.layoutManager.numberOfGlyphs
        let indices = count <= 64 ? Array(0..<count) : [0, count / 4, count / 2, 3 * count / 4, count - 1]
        return indices.flatMap { index -> [CGPoint] in
            let rect = view.layoutManager.boundingRect(forGlyphRange: NSRange(location: index, length: 1),
                                                       in: view.textContainer)
            guard rect.width > 0, rect.height > 0 else { return [] }
            return [CGPoint(x: rect.midX, y: rect.midY),
                    CGPoint(x: rect.minX - 3.75, y: rect.midY),
                    CGPoint(x: rect.minX - 4.25, y: rect.midY),
                    CGPoint(x: rect.minX - 5.25, y: rect.midY),
                    CGPoint(x: rect.maxX + 4.25, y: rect.midY),
                    CGPoint(x: rect.maxX + 5.25, y: rect.midY),
                    CGPoint(x: rect.midX, y: rect.minY - 6.75),
                    CGPoint(x: rect.midX, y: rect.minY - 7.25),
                    CGPoint(x: rect.midX, y: rect.maxY + 7.25)]
        }
    }

    private func compare(_ baseline: CountingNativeTextView, _ candidate: CountingNativeTextView,
                         name: String, method: HitMethod, stage: String, points: [CGPoint]) {
        baseline.getterReads = 0
        candidate.getterReads = 0
        baseline.countGetterReads = true
        candidate.countGetterReads = true
        var mismatches: [[String: Any]] = []
        var hits = 0
        for (index, point) in points.enumerated() {
            // Alternate evaluation order; candidate does not depend on a baseline layout query.
            let old: Bool
            let new: Bool
            if index.isMultiple(of: 2) {
                new = candidate.query(method, point)
                old = baseline.query(method, point)
            } else {
                old = baseline.query(method, point)
                new = candidate.query(method, point)
            }
            if new { hits += 1 }
            if old != new {
                mismatches.append(["x": point.x, "y": point.y, "baseline": old, "candidate": new])
            }
        }
        baseline.countGetterReads = false
        candidate.countGetterReads = false
        let key = "\(Int(baseline.bounds.width))/\(name)/\(method.rawValue)/\(stage)"
        let pass = mismatches.isEmpty && baseline.getterReads >= points.count && candidate.getterReads == 0
        if !pass { failures.append(key) }
        rows.append(["case": key, "passed": pass, "points": points.count, "hits": hits,
                     "baseline_getter_reads": baseline.getterReads, "candidate_getter_reads": candidate.getterReads,
                     "mismatch_count": mismatches.count, "mismatch_examples": Array(mismatches.prefix(12))])
    }

    private func run() {
        let root = window!.rootViewController!.view!
        for width: CGFloat in [88, 240] {
            // Reuse each pair across replacements so stale content/layout cannot hide behind a fresh instance.
            for method in HitMethod.allCases {
                let baseline = BaselineGlyphProbe(width: width)
                let candidate = CandidateGlyphProbe(width: width)
                root.addSubview(baseline)
                root.addSubview(candidate)
                for (name, text) in fixtures() {
                    baseline.attributedText = text
                    candidate.attributedText = text
                    if baseline.textStorage.length != text.length || candidate.textStorage.length != text.length {
                        failures.append("\(name): replacement length")
                    }
                    let fixed = initialPoints(width: width)
                    compare(baseline, candidate, name: name, method: method, stage: "first-query", points: fixed)
                    let boundaries = glyphBoundaryPoints(baseline)
                    // Prepare candidate layout independently, without asking for attributedText.
                    candidate.layoutManager.ensureLayout(for: candidate.textContainer)
                    compare(baseline, candidate, name: name, method: method, stage: "glyph-boundaries", points: fixed + boundaries)
                    compare(baseline, candidate, name: name, method: method, stage: "repeat", points: fixed + boundaries)
                    if text.length == 0 && rows.suffix(3).contains(where: { ($0["hits"] as? Int) != 0 }) {
                        failures.append("\(name): empty text accepted")
                    }
                    if text.length > 0 && (rows.last?["hits"] as? Int) == 0 {
                        failures.append("\(name): no positive native glyph probe")
                    }
                    if baseline.textStorage.string != text.string || candidate.textStorage.string != text.string {
                        failures.append("\(name): query changed text")
                    }
                }
                baseline.removeFromSuperview()
                candidate.removeFromSuperview()
            }
        }
        let report: [String: Any] = [
            "passed": failures.isEmpty, "failures": failures, "batches": rows,
            "batch_count": rows.count,
            "comparison_count": rows.reduce(0) { $0 + ($1["points"] as? Int ?? 0) },
            "scope": "Actual extracted method bodies on real UIKit NSTextStorage/NSLayoutManager/UITextView; synthetic content and direct query points. No physical gesture, selection-handle UI, Markdown drawing, or performance acceptance. Default NSLayoutManager is used because shipping overrides drawing, not these query methods."
        ]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: documents.appendingPathComponent("text-hit-storage-results.json"))
            print("TEXT_HIT_STORAGE \(failures.isEmpty ? "PASS" : "FAIL") batches=\(rows.count) failures=\(failures.count)")
            fflush(nil)
            exit(failures.isEmpty ? 0 : 1)
        } catch {
            print("TEXT_HIT_STORAGE REPORT_ERROR \(error)")
            exit(2)
        }
    }
}
