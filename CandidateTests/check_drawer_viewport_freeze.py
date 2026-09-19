#!/usr/bin/env python3
"""Execute the extracted viewport invalidation method and drawer phase lease.

UIKit geometry, layout/drawing and callback delivery are controlled receivers;
this does not measure phone performance or prove rendered text coverage.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from check_drawer_close_driver_reuse import extract, strip_viewport_freeze_hooks

ROOT = Path(__file__).resolve().parents[1]
BASE = "7c74a36"
OUT = ROOT / "work/verification/drawer-viewport-freeze"

SWIFT = r'''
import Foundation
import CoreGraphics
struct UIEdgeInsets: Equatable { var top: CGFloat = 0; var left: CGFloat = 0; var bottom: CGFloat = 0; var right: CGFloat = 0 }
@MainActor final class UIScrollView: NSObject {
    var bounds = CGRect(x: 0, y: 0, width: 300, height: 600)
    var contentOffset = CGPoint.zero
    var contentSize = CGSize(width: 300, height: 2000)
    var adjustedContentInset = UIEdgeInsets()
}
@MainActor enum MessageTextLayoutTrace { static let isEnabled = false }
@MainActor final class Layout {
    var messageTextTraceVisibleRect = CGRect.null
    var messageTextTraceTextBounds = CGRect.null
    var permittedDrawingRect = CGRect.null
    var invalidations = 0
    func invalidateDisplay(forCharacterRange: NSRange) { invalidations += 1 }
}
/*LEASE*/
/*KEY*/
@MainActor private final class GlyphSelectableTextView: NSObject {
    static let viewportOverscan: CGFloat = 720
    var window: NSObject? = NSObject()
    var observedOuterScrollView: UIScrollView? = UIScrollView()
    var bounds = CGRect(x: 0, y: 0, width: 300, height: 2000)
    var frame = CGRect(x: 0, y: 0, width: 300, height: 2000)
    var textContainerInset = UIEdgeInsets()
    let textStorage = NSMutableAttributedString(string: "visible text")
    let decorationLayoutManager = Layout()
    var coveredViewportRect = CGRect.null
    var drawerViewportRefreshKey: DrawerViewportRefreshKey?
    var visibleRect = CGRect(x: 0, y: 100, width: 300, height: 300)
    var queries = 0, draws = 0, resumes = 0
    func currentClippedVisibleRect() -> CGRect { queries += 1; return visibleRect }
    func setNeedsDisplay(_ rect: CGRect) { draws += 1 }
    func recordMessageTextViewportTrace(reason: String, force: Bool, visibleRect: CGRect, decision: String) {}
    func notify(_ reason: String = "outer-bounds", force: Bool = false) {
        invalidateViewportDrawingIfNeeded(force: force, reason: reason)
    }
    /*CURRENT_KEY*/
    /*RESUME*/
    /*INVALIDATE*/
}
@main struct Runner {
    @MainActor static func main() throws {
        let experimental = /*EXPERIMENTAL*/ && DrawerViewportRefreshFreeze.isEnabled
        var results: [String: Bool] = [:]
        func begin() { DrawerViewportRefreshFreeze.reset(); DrawerViewportRefreshFreeze.setDragging(true) }
        do {
            begin(); let v = GlyphSelectableTextView(); v.notify()
            let q = v.queries
            for _ in 0..<100 { v.notify() }
            results["duplicate_notifications_deferred"] = v.queries - q == (experimental ? 0 : 100)
            let before = v.queries
            DrawerViewportRefreshFreeze.setSettling(true)
            DrawerViewportRefreshFreeze.setDragging(false)
            results["drag_to_settle_has_no_thaw"] = v.queries == before && DrawerViewportRefreshFreeze.isActive == DrawerViewportRefreshFreeze.isEnabled
            DrawerViewportRefreshFreeze.setDragging(true)
            DrawerViewportRefreshFreeze.setSettling(false)
            results["settle_to_regrab_has_no_thaw"] = v.queries == before
            DrawerViewportRefreshFreeze.setDragging(false)
            results["end_rechecks_once"] = v.queries - before == (experimental ? 1 : 0)
            let ended = v.queries; DrawerViewportRefreshFreeze.reset()
            results["repeated_end_is_idle"] = v.queries == ended
        }
        do {
            begin(); let v = GlyphSelectableTextView()
            v.visibleRect = CGRect(x: 0, y: 100, width: 60, height: 300); v.notify()
            let before = v.queries
            v.visibleRect.size.width = 300; v.notify()
            results["closing_exposes_prepared_full_width"] = v.coveredViewportRect.contains(v.visibleRect)
            results["closing_does_not_requery_duplicate"] = v.queries - before == (experimental ? 0 : 1)
            DrawerViewportRefreshFreeze.reset()
        }
        do {
            begin(); let v = GlyphSelectableTextView(); v.notify()
            let before = v.queries
            v.observedOuterScrollView!.contentOffset.y = 1500
            v.observedOuterScrollView!.bounds.origin.y = 1500
            v.visibleRect.origin.y = 1500; v.notify("outer-content-offset")
            results["real_scroll_draws_new_area_immediately"] = v.queries == before + 1 && v.coveredViewportRect.contains(v.visibleRect)
            var q = v.queries
            v.observedOuterScrollView!.bounds.size.height = 350; v.notify()
            results["viewport_resize_is_immediate"] = v.queries == q + 1
            q = v.queries; v.observedOuterScrollView!.contentSize.height += 400; v.notify()
            results["content_size_change_is_immediate"] = v.queries == q + 1
            q = v.queries; v.observedOuterScrollView!.adjustedContentInset.bottom = 200; v.notify()
            results["inset_change_is_immediate"] = v.queries == q + 1
            q = v.queries; v.observedOuterScrollView = UIScrollView(); v.notify()
            results["new_scroll_host_is_immediate"] = v.queries == q + 1
            q = v.queries; v.frame.origin.y += 900; v.visibleRect.origin.y = 300; v.notify()
            results["text_frame_change_is_immediate"] = v.queries == q + 1 && v.coveredViewportRect.contains(v.visibleRect)
            DrawerViewportRefreshFreeze.reset()
        }
        do {
            begin(); let v = GlyphSelectableTextView(); v.notify(); var q = v.queries
            let draws = v.draws; v.notify("content-change", force: true)
            results["changed_text_forces_display"] = v.queries == q + 1 && v.draws == draws + 1
            q = v.queries; v.visibleRect.origin.y = 1500; v.notify("content-layout")
            results["landing_layout_bypasses_freeze"] = v.queries == q + 1 && v.coveredViewportRect.contains(v.visibleRect)
            q = v.queries; v.bounds.size.width += 50; v.notify("layout-size", force: true)
            results["text_size_change_bypasses_freeze"] = v.queries == q + 1
            DrawerViewportRefreshFreeze.remove(v); v.window = nil
            q = v.queries; DrawerViewportRefreshFreeze.reset()
            results["detached_text_does_not_resume"] = v.queries == q
        }
        do {
            begin(); var v: GlyphSelectableTextView? = GlyphSelectableTextView(); weak var weakView = v
            v!.notify(); v = nil
            results["pending_refresh_does_not_retain_view"] = weakView == nil
            DrawerViewportRefreshFreeze.reset()
        }
        do {
            begin(); let v = GlyphSelectableTextView(); v.visibleRect = .null; v.notify()
            let before = v.queries
            v.visibleRect = CGRect(x: 0, y: 100, width: 300, height: 300); v.notify()
            results["initially_hidden_text_can_become_visible"] = v.queries == before + 1 && v.coveredViewportRect.contains(v.visibleRect)
            DrawerViewportRefreshFreeze.reset(); DrawerViewportRefreshFreeze.setDragging(true)
            let q = v.queries; v.notify()
            results["new_gesture_prepares_again"] = v.queries == q + 1
            DrawerViewportRefreshFreeze.reset()
        }
        print(String(decoding: try JSONEncoder().encode(results), as: UTF8.self))
        if results.values.contains(false) { exit(1) }
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    new = (ROOT / "Mocca/MessageMarkdownView.swift").read_text()
    old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/MessageMarkdownView.swift"], cwd=ROOT, text=True)
    root_old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
    root_new = (ROOT / "Mocca/RootView.swift").read_text()
    assert strip_viewport_freeze_hooks(root_new) == root_old, "Root changes exceed the phase hooks"
    assert root_new.count("DrawerViewportRefreshFreeze.") == 5
    lease, _ = extract(new, r"^@MainActor\nenum DrawerViewportRefreshFreeze\b")
    key, _ = extract(new, r"^private struct DrawerViewportRefreshKey\b")
    getter, _ = extract(new, r"^    private func currentDrawerViewportRefreshKey\b")
    resume, _ = extract(new, r"^    func resumeDrawerViewportDrawing\b")
    cases, sources = [], {}
    for label, source, enabled in [("5018", old, False), ("5019", new, True), ("5019-disabled", new, True)]:
        invalidation, lines = extract(source, r"^    private func invalidateViewportDrawingIfNeeded\b")
        swift = SWIFT.replace("/*LEASE*/", lease).replace("/*KEY*/", key).replace("/*CURRENT_KEY*/", getter).replace("/*RESUME*/", resume).replace("/*INVALIDATE*/", invalidation).replace("/*EXPERIMENTAL*/", str(enabled).lower())
        file = OUT / f"viewport-{label}.swift"; file.write_text(swift)
        with tempfile.TemporaryDirectory(prefix="drawer-viewport-freeze-") as tmp:
            binary = Path(tmp) / "contract"
            compile_result = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(file), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            (OUT / f"viewport-{label}-build.log").write_text(compile_result.stdout + compile_result.stderr)
            if compile_result.returncode: raise SystemExit(compile_result.stderr)
            run = subprocess.run([str(binary)] + (["-disableDrawerViewportFreeze"] if "disabled" in label else []), capture_output=True, text=True, timeout=30)
            (OUT / f"viewport-{label}-run.log").write_text(run.stdout + run.stderr)
            checks = json.loads(run.stdout)
            cases.append({"version": label, "checks": checks, "passed": all(checks.values())})
            sources[label] = {"source_sha256": hashlib.sha256(source.encode()).hexdigest(), "invalidation_lines": lines, "harness_sha256": hashlib.sha256(swift.encode()).hexdigest()}
    result = {"pass": all(c["passed"] for c in cases), "cases": cases, "sources": sources,
              "limits": ["The real invalidation method, phase state and refresh key execute; clipping geometry and drawing are controlled receivers.", "100 notifications are a controlled duplicate workload, not measured real-gesture frequency.", "No rendered text, keyboard animation, frame timing or iPhone acceptance is claimed."]}
    (OUT / "viewport-contract.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"pass": result["pass"], "checks": sum(len(c["checks"]) for c in cases), "failed": [(c["version"], k) for c in cases for k, v in c["checks"].items() if not v]}))
    if not result["pass"]: raise SystemExit(1)


if __name__ == "__main__":
    main()
