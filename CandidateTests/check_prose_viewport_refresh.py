"""Exercise production viewport invalidation after a position-only layout change.

Uses CoreGraphics and a translation-only UIKit hierarchy double. This verifies
coverage/invalidation and traversal, not real UIKit painting or SwiftUI timing.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Mocca/MessageMarkdownView.swift').read_text()

def between(start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]

swift = '''import Foundation
import CoreGraphics
@MainActor class UIView {
    var frame: CGRect
    var bounds: CGRect
    var clipsToBounds = false
    weak var superview: UIView?
    var subviews: [UIView] = []
    var window: UIWindow? { (self as? UIWindow) ?? superview?.window }
    init(_ frame: CGRect = .zero) { self.frame = frame; bounds = CGRect(origin: .zero, size: frame.size) }
    func addSubview(_ view: UIView) { view.superview = self; subviews.append(view) }
    var windowOrigin: CGPoint {
        let parent = superview?.windowOrigin ?? .zero
        return CGPoint(x: parent.x + frame.minX - bounds.minX,
                       y: parent.y + frame.minY - bounds.minY)
    }
    func convert(_ rect: CGRect, from view: UIView) -> CGRect {
        rect.offsetBy(dx: view.windowOrigin.x - windowOrigin.x,
                      dy: view.windowOrigin.y - windowOrigin.y)
    }
}
@MainActor final class UIWindow: UIView {}
struct UIEdgeInsets: Equatable {
    var top: CGFloat = 0; var left: CGFloat = 0; var bottom: CGFloat = 0; var right: CGFloat = 0
}
@MainActor final class UIScrollView: UIView {
    var contentOffset = CGPoint.zero
    var contentSize = CGSize.zero
    var adjustedContentInset = UIEdgeInsets()
}
@MainActor final class LayoutManager {
    var permittedDrawingRect: CGRect?
    var messageTextTraceVisibleRect = CGRect.null
    var messageTextTraceTextBounds = CGRect.null
    var invalidations: [NSRange] = []
    func invalidateDisplay(forCharacterRange range: NSRange) { invalidations.append(range) }
}
struct Insets { var left: CGFloat = 0; var top: CGFloat = 0 }
struct Storage { let length = 100_000 }
@MainActor enum MessageTextLayoutTrace { static var isEnabled = false }
'''
swift += between('@MainActor\nenum MessageTextViewportDrawing', 'private final class GlyphSelectableTextView:')
swift += '''@MainActor private final class GlyphSelectableTextView: UIView {
    private static let viewportOverscan: CGFloat = 720
    let decorationLayoutManager = LayoutManager()
    let textStorage = Storage()
    var textContainerInset = Insets()
    var coveredViewportRect = CGRect.null
    var drawerViewportRefreshKey: DrawerViewportRefreshKey?
    weak var observedOuterScrollView: UIScrollView?
    var redraws: [CGRect] = []
    func setNeedsDisplay(_ rect: CGRect) { redraws.append(rect) }
    func recordMessageTextViewportTrace(reason: String, force: Bool, visibleRect: CGRect, decision: String) {}
'''
swift += between('    func refreshViewportDrawingAfterLayout()', '    private func attachOuterScrollViewObservationIfNeeded()')
swift += between('    private func invalidateViewportDrawingIfNeeded(', '    private func recordMessageTextViewportTrace(')
swift += between('    private func currentClippedVisibleRect()', '    func tuneInitialSelectionLongPress(to duration:')
swift += '''}
@main struct Checks {
    @MainActor static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        let window = UIWindow(CGRect(x: 0, y: 0, width: 360, height: 800))
        let scroll = UIScrollView(window.bounds)
        window.addSubview(scroll)
        let row = UIView(CGRect(x: 0, y: 0, width: 360, height: 10_000))
        scroll.addSubview(row)
        let leading = GlyphSelectableTextView(CGRect(x: 0, y: 0, width: 360, height: 100))
        let following = GlyphSelectableTextView(CGRect(x: 0, y: 4000, width: 360, height: 5000))
        let later = GlyphSelectableTextView(CGRect(x: 0, y: 9500, width: 360, height: 500))
        row.addSubview(leading); row.addSubview(following); row.addSubview(later)
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(leading.redraws.count == 1, "visible leading prose is drawn")
        check(following.redraws.isEmpty && following.decorationLayoutManager.permittedDrawingRect == .null,
              "offscreen following prose is suppressed before collapse")
        let oldBounds = following.bounds, oldScrollBounds = scroll.bounds
        following.frame.origin.y = 250
        check(following.bounds == oldBounds && scroll.bounds == oldScrollBounds,
              "collapse moves prose without changing its size or scrolling")
        check(following.decorationLayoutManager.permittedDrawingRect == .null,
              "without the new landing callback the old suppressed drawing state remains")
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(following.redraws.count == 1 && following.decorationLayoutManager.permittedDrawingRect != .null,
              "landing reveals unchanged prose without requiring a user scroll")
        check(following.coveredViewportRect == CGRect(x: 0, y: 0, width: 360, height: 1270),
              "new coverage retains 720-point overscan instead of drawing the full long reply")
        check(leading.redraws.count == 1 && later.redraws.isEmpty,
              "already covered and still-offscreen prose incur no redraw")
        for _ in 0..<10 { MessageTextViewportDrawing.refreshAfterLayout(in: scroll) }
        check(following.redraws.count == 1, "duplicate layout acknowledgements reuse coverage")
        scroll.bounds.origin.y = 200
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(following.redraws.count == 1, "movement inside existing overscan stays cheap")
        scroll.bounds.origin.y = 1200
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(following.redraws.count == 2 && following.coveredViewportRect.maxY == 2470,
              "an uncovered viewport refreshes normally after further scrolling")
        scroll.bounds.origin.y = 0
        following.frame.origin.y = 4000
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(following.decorationLayoutManager.permittedDrawingRect == .null,
              "expansion can return following prose to the offscreen state")
        following.frame.origin.y = 250
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(following.redraws.count == 3, "a second collapse redraws the newly exposed prose again")
        let outside = GlyphSelectableTextView(window.bounds)
        window.addSubview(outside)
        let internalChild = GlyphSelectableTextView(window.bounds)
        following.addSubview(internalChild)
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(outside.redraws.isEmpty && internalChild.redraws.isEmpty,
              "traversal stays in the chat and stops at each native text surface")
        let detached = GlyphSelectableTextView(window.bounds)
        MessageTextViewportDrawing.refreshAfterLayout(in: detached)
        check(detached.redraws.isEmpty, "detached text is not forced to draw")
        check(following.bounds == oldBounds && following.textStorage.length == 100_000,
              "the refresh preserves full layout height and text")
        check(following.decorationLayoutManager.messageTextTraceVisibleRect == .null
              && following.decorationLayoutManager.messageTextTraceTextBounds == .null,
              "disabled diagnostics do not compute or store trace rectangles")
        let redrawsBeforeTrace = following.redraws.count
        MessageTextLayoutTrace.isEnabled = true
        MessageTextViewportDrawing.refreshAfterLayout(in: scroll)
        check(following.decorationLayoutManager.messageTextTraceVisibleRect != .null
              && following.decorationLayoutManager.messageTextTraceTextBounds == following.bounds
              && following.redraws.count == redrawsBeforeTrace,
              "enabled diagnostics still update rectangles without changing viewport drawing")
        print("PASS \\(count) prose viewport checks (UIKit hierarchy double)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='mocca-prose-viewport-') as directory:
    path = Path(directory)
    (path / 'Checks.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                    str(path / 'Checks.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
