import UIKit

/// The transcript remains the only vertical scroller. Selection owns its
/// position from the first edge scroll until the native selection gesture is released.
@MainActor
protocol TextSelectionAutoscrollHost: AnyObject {
    func selectionAutoscrollDidBegin()
    func selectionAutoscrollDidEnd()
}

@MainActor
protocol TextSelectionAutoscrollDocument: AnyObject {
    var selectionAutoscrollDocumentRect: CGRect { get }
}

@MainActor
final class TextSelectionEdgeAutoscroll: NSObject {
    private weak var scrollView: UIScrollView?
    private let textViews = NSHashTable<UITextView>.weakObjects()
    private weak var selectedView: UITextView?
    private weak var pendingInitialView: UITextView?
    private var selectionAtTouchDown = NSRange(location: 0, length: 0)
    private var initialSelection: NSRange?
    private var anchor = 0
    private var textLength = 0
    private var beganPoint = CGPoint.zero
    private var finger = CGPoint.zero
    private var windowSize = CGSize.zero
    private var confirmedSelectionDrag = false
    private var generation = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var ownsScroll = false
    private var touchObserver: SelectionTouchObserver?
    private(set) var isAutoscrolling = false
    var ownsSelectionDrag: Bool { selectedView != nil && confirmedSelectionDrag }

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init()
        let observer = SelectionTouchObserver(target: nil, action: nil)
        observer.began = { [weak self] point, isSelectionSurface, textView in
            self?.begin(at: point, fromSelectionSurface: isSelectionSurface, initialTextView: textView)
        }
        observer.moved = { [weak self] point in self?.move(to: point) }
        observer.released = { [weak self] in self?.finish() }
        observer.ended = { [weak self] in self?.cancel() }
        touchObserver = observer
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit {
        let observer = touchObserver
        Task { @MainActor in
            if let observer { observer.view?.removeGestureRecognizer(observer) }
        }
    }

    func register(_ textView: UITextView) {
        textViews.add(textView)
        // UIKit can host the selection handles above the transcript's view
        // subtree. Observe their original touch at the window, still admitting
        // only selection gestures in this controller's registered text views.
        if let window = scrollView?.window, let touchObserver, touchObserver.view !== window {
            touchObserver.view?.removeGestureRecognizer(touchObserver)
            window.addGestureRecognizer(touchObserver)
        }
    }
    func unregister(_ textView: UITextView) {
        textViews.remove(textView)
        cancelSelection(in: textView)
        if textViews.allObjects.isEmpty, let touchObserver {
            touchObserver.view?.removeGestureRecognizer(touchObserver)
        }
    }
    func cancelSelection(in textView: UITextView) {
        if selectedView === textView || pendingInitialView === textView { cancel() }
    }

    // Called by the passive observer, never by a competing selection gesture.
    func begin(at point: CGPoint, fromSelectionSurface: Bool = false, initialTextView: UITextView? = nil) {
        cancel()
        guard fromSelectionSurface, let scrollView, let window = scrollView.window,
              scrollView.isScrollEnabled, !scrollView.isDecelerating else { return }
        for view in textViews.allObjects where view.window === window
            && view.isDescendant(of: scrollView) && view.isSelectable
            && !view.isEditable && view.isFirstResponder && view.selectedRange.length > 0 {
            guard let range = view.selectedTextRange else { continue }
            let local = view.convert(point, from: window)
            // Qualify the native selection endpoint once at touch-down. UIKit
            // may deliver a handle touch to the text view itself; a handle-view
            // protocol check alone does not cover the TextKit 1 path.
            let rects = view.selectionRects(for: range)
            var nearest: (distance: CGFloat, anchor: Int)?
            for rect in rects where rect.containsStart || rect.containsEnd {
                let rtl = rect.writingDirection == .rightToLeft
                if rect.containsStart {
                    let handle = CGPoint(x: rtl ? rect.rect.maxX : rect.rect.minX,
                                         y: rect.rect.minY)
                    let distance = hypot(local.x - handle.x, local.y - handle.y)
                    if distance < 30, distance < (nearest?.distance ?? .infinity) {
                        nearest = (distance, NSMaxRange(view.selectedRange))
                    }
                }
                if rect.containsEnd {
                    let handle = CGPoint(x: rtl ? rect.rect.minX : rect.rect.maxX,
                                         y: rect.rect.maxY)
                    let distance = hypot(local.x - handle.x, local.y - handle.y)
                    if distance < 30, distance < (nearest?.distance ?? .infinity) {
                        nearest = (distance, view.selectedRange.location)
                    }
                }
            }
            guard let nearest else { continue }
            selectedView = view
            anchor = nearest.anchor
            textLength = view.textStorage.length
            beganPoint = point; finger = point; windowSize = window.bounds.size
            NotificationCenter.default.addObserver(self, selector: #selector(storageChanged(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: view.textStorage)
            return
        }
        // The first long press starts before UIKit has created a selection.
        // Keep just this touch as a candidate; an ordinary pan never qualifies.
        guard let view = initialTextView, textViews.contains(view), view.window === window,
              view.isDescendant(of: scrollView), view.isSelectable, !view.isEditable,
              view.bounds.contains(view.convert(point, from: window)) else { return }
        pendingInitialView = view
        selectionAtTouchDown = view.selectedRange
        textLength = view.textStorage.length
        beganPoint = point; finger = point; windowSize = window.bounds.size
        NotificationCenter.default.addObserver(self, selector: #selector(storageChanged(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: view.textStorage)
    }

    func move(to point: CGPoint) {
        guard selectedView != nil || pendingInitialView != nil else { return }
        finger = point
        let expected = generation
        // Let UIKit process this move before inspecting its scroll ownership.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            self.evaluateDrag()
        }
    }

    private func evaluateDrag() {
        if let pendingInitialView {
            guard validSurface(pendingInitialView) else { cancel(); return }
            // Read the public native recognizer after UIKit has processed the
            // move. A newly selected word alone is insufficient: it could have
            // come from a tap, menu command, or another interaction.
            let nativeLongPress = (pendingInitialView.gestureRecognizers ?? [])
                .compactMap { $0 as? UILongPressGestureRecognizer }
                .contains { $0.numberOfTouchesRequired == 1 && $0.numberOfTapsRequired == 0
                    && ($0.state == .began || $0.state == .changed) }
            let range = pendingInitialView.selectedRange
            guard nativeLongPress, pendingInitialView.isFirstResponder, range.length > 0,
                  range != selectionAtTouchDown,
                  let position = pendingInitialView.closestPosition(to: pendingInitialView.convert(beganPoint, from: pendingInitialView.window)) else { return }
            let origin = pendingInitialView.offset(from: pendingInitialView.beginningOfDocument, to: position)
            guard origin >= range.location, origin <= NSMaxRange(range) else { return }
            selectedView = pendingInitialView
            self.pendingInitialView = nil
            initialSelection = range
        }
        guard validView() != nil else { cancel(); return }
        if !confirmedSelectionDrag {
            // Read-only UITextView can defer its public selectedRange until
            // the handle gesture ends. Endpoint hit testing, movement, and the
            // absence of a list pan or text drag establish selection ownership.
            guard hypot(finger.x - beganPoint.x, finger.y - beganPoint.y) >= 6 else { return }
            confirmedSelectionDrag = true
        }
        guard let velocity = currentVelocity(), velocity != 0,
              nextOffset(velocity: velocity, duration: 1.0 / 60) != nil else {
            stopDisplayLink(); return
        }
        guard displayLink == nil else { return }
        let proxy = SelectionDisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(SelectionDisplayLinkTarget.tick(_:)))
        // Follow the display rather than publishing per-frame SwiftUI state.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink = link; lastTimestamp = 0; isAutoscrolling = true
        link.add(to: .main, forMode: .common)
    }

    private func validSurface(_ view: UITextView) -> Bool {
        guard let scrollView, let window = scrollView.window,
              window.isKeyWindow, !window.isHidden, window.bounds.size == windowSize,
              view.window === window, view.isDescendant(of: scrollView),
              view.isSelectable, !view.isEditable, !view.isHidden, view.alpha > 0,
              !view.isTextDragActive, view.textStorage.length == textLength,
              scrollView.isScrollEnabled, !scrollView.isDragging, !scrollView.isDecelerating,
              !scrollView.isZooming, UIApplication.shared.applicationState == .active else { return false }
        return true
    }

    private func validView() -> UITextView? {
        guard let view = selectedView, validSurface(view), view.isFirstResponder,
              view.selectedRange.length > 0 else { return nil }
        return view
    }

    private func viewport() -> CGRect? {
        guard let scrollView, let window = scrollView.window else { return nil }
        var rect = scrollView.convert(scrollView.bounds.inset(by: scrollView.adjustedContentInset), to: window)
        rect = rect.intersection(window.bounds.inset(by: window.safeAreaInsets))
        var ancestor = scrollView.superview
        while let view = ancestor, view !== window {
            if view.clipsToBounds { rect = rect.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        let keyboard = window.keyboardLayoutGuide.layoutFrame
        if keyboard.width > rect.width * 0.8, keyboard.minY > rect.minY,
           keyboard.minY < rect.maxY { rect.size.height = keyboard.minY - rect.minY }
        return rect.isNull || rect.height < 90 ? nil : rect
    }

    static func velocity(at point: CGPoint, viewport: CGRect) -> CGFloat {
        guard point.x >= viewport.minX - 30, point.x <= viewport.maxX + 30,
              point.y >= viewport.minY - 80, point.y <= viewport.maxY + 80 else { return 0 }
        let band = min(48, viewport.height / 4)
        let top = (viewport.minY + band - point.y) / band
        let bottom = (point.y - (viewport.maxY - band)) / band
        let proximity = max(top, bottom)
        guard proximity > 0 else { return 0 }
        let speed = 30 + 330 * pow(min(1, proximity), 2)
        return top > bottom ? -speed : speed
    }

    private func currentVelocity() -> CGFloat? {
        guard let viewport = viewport() else { return nil }
        return Self.velocity(at: finger, viewport: viewport)
    }

    private func nextOffset(velocity: CGFloat, duration: CFTimeInterval) -> CGFloat? {
        guard let scrollView, let view = selectedView, let window = view.window,
              let visible = viewport() else { return nil }
        let viewport = scrollView.convert(visible, from: window)
        let document = (view as? TextSelectionAutoscrollDocument)?.selectionAutoscrollDocumentRect
            ?? view.bounds.inset(by: view.textContainerInset)
        let text = view.convert(document, to: scrollView)
        let y = scrollView.contentOffset.y
        let contentMin = -scrollView.adjustedContentInset.top
        let contentMax = max(contentMin, scrollView.contentSize.height - scrollView.bounds.height
                             + scrollView.adjustedContentInset.bottom)
        // Bound each direction to this text region. Never scroll into another
        // message, trigger history paging, or bounce at either document edge.
        let limit = velocity < 0
            ? max(contentMin, text.minY - (viewport.minY - y))
            : min(contentMax, text.maxY - (viewport.maxY - y))
        let proposed = y + velocity * min(max(duration, 0), 1.0 / 30)
        let next = velocity < 0 ? max(proposed, limit) : min(proposed, limit)
        guard velocity < 0 ? next < y - 0.01 : next > y + 0.01 else { return nil }
        return next
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let view = validView(), let scrollView, let window = view.window else { cancel(); return }
        guard let velocity = currentVelocity(), velocity != 0 else { stopDisplayLink(); return }
        let duration = lastTimestamp == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        guard nextOffset(velocity: velocity, duration: duration) != nil else { stopDisplayLink(); return }
        if !ownsScroll {
            ownsScroll = true
            (scrollView as? TextSelectionAutoscrollHost)?.selectionAutoscrollDidBegin()
        }
        // Releasing an in-flight stream animation may adopt its presentation
        // offset. Compute the step again after that ownership handoff.
        guard let y = nextOffset(velocity: velocity, duration: duration) else { stopDisplayLink(); return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
        // A stationary finger receives no new move events while content rolls
        // underneath it. Extend the same selection using public UITextInput
        // positions; UIKit still owns handles, loupe, menu and touch gestures.
        extendSelection(in: view, window: window)
    }

    private func extendSelection(in view: UITextView, window: UIWindow) {
        guard let visible = viewport() else { cancel(); return }
        // closestPosition rounds to a text line. Leave room for that line and
        // its native grabber so the moving handle remains reachable at an edge.
        let selectionMargin = min(40, visible.height / 4)
        let point = CGPoint(x: min(max(finger.x, visible.minX), visible.maxX),
                            y: min(max(finger.y, visible.minY + selectionMargin), visible.maxY - selectionMargin))
        let local = view.convert(point, from: window)
        guard let moving = view.closestPosition(to: local) else { cancel(); return }
        let offset = view.offset(from: view.beginningOfDocument, to: moving)
        if let initialSelection {
            // A first long press expands either side of its native word. Keep
            // that word as the anchor even if the finger reverses direction.
            if offset < initialSelection.location { anchor = NSMaxRange(initialSelection) }
            else if offset > NSMaxRange(initialSelection) { anchor = initialSelection.location }
            else { return }
        }
        guard let fixed = view.position(from: view.beginningOfDocument, offset: anchor) else { cancel(); return }
        let proposed = NSRange(location: min(offset, anchor), length: abs(offset - anchor))
        guard proposed.length > 0, proposed != view.selectedRange else { return }
        let range = offset < anchor ? view.textRange(from: moving, to: fixed) : view.textRange(from: fixed, to: moving)
        if let range { view.selectedTextRange = range }
    }

    private func finish() {
        guard initialSelection != nil, ownsScroll, validView() != nil,
              let velocity = currentVelocity(), velocity != 0 else { cancel(); return }
        stopDisplayLink()
        let expected = generation
        // The initial native long press can commit its own cached range on
        // touch-up, after our last display frame. Remap the final finger once
        // that event finishes, while the same selection and document are valid.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected else { return }
            if let view = self.validView(), let window = view.window {
                self.extendSelection(in: view, window: window)
            }
            self.cancel()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate(); displayLink = nil; lastTimestamp = 0; isAutoscrolling = false
    }

    @objc func cancel() {
        generation &+= 1
        NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
        stopDisplayLink(); selectedView = nil; pendingInitialView = nil; initialSelection = nil
        confirmedSelectionDrag = false
        // Pausing at the center or document boundary does not release the
        // finger's ownership back to streaming follow before touch-up.
        if ownsScroll {
            ownsScroll = false
            (scrollView as? TextSelectionAutoscrollHost)?.selectionAutoscrollDidEnd()
        }
    }

    @objc private func storageChanged(_ notification: Notification) {
        guard let view = selectedView ?? pendingInitialView, notification.object as? NSTextStorage === view.textStorage,
              view.textStorage.editedMask.contains(.editedCharacters) else { return }
        cancel()
    }
}

@MainActor
private final class SelectionDisplayLinkTarget: NSObject {
    weak var owner: TextSelectionEdgeAutoscroll?
    init(owner: TextSelectionEdgeAutoscroll) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.tick(link)
    }
}

/// Observe the original finger without delaying, cancelling or preventing
/// UIKit's text selection, list pan, horizontal code pan, or drawer gestures.
private final class SelectionTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var began: (CGPoint, Bool, UITextView?) -> Void = { _, _, _ in }
    var moved: (CGPoint) -> Void = { _ in }
    var released: () -> Void = {}
    var ended: () -> Void = {}
    private weak var finger: UITouch?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard finger == nil, touches.count == 1, let touch = touches.first else {
            finger = nil; ended()
            state = state == .possible ? .failed : .cancelled
            return
        }
        let isSelectionSurface = sequence(first: touch.view, next: { $0?.superview })
            .contains { $0 is UITextView || $0 is UITextSelectionHandleView }
        let textView = sequence(first: touch.view, next: { $0?.superview })
            .compactMap { $0 as? UITextView }.first
        finger = touch
        began(touch.location(in: view?.window), isSelectionSurface, textView)
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        moved(finger.location(in: view?.window)); state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        self.finger = nil; released(); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        ended(); finger = nil; state = .cancelled
    }
    override func reset() {
        super.reset()
        if finger != nil { ended(); finger = nil }
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
