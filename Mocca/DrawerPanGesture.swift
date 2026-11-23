import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Tracks one physical contact from touchdown through release. Later fingers
/// never contribute positions or release velocity to the drawer's motion.
final class DrawerSingleContactPan: UIGestureRecognizer {
    private var primaryTouch: UITouch?
    var onContactBegan: (CGPoint) -> Void = { _ in }
    private(set) var startLocation: CGPoint = .zero
    private(set) var location: CGPoint = .zero
    private(set) var velocity: CGPoint = .zero
    private var samples: [(point: CGPoint, time: TimeInterval)] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if primaryTouch == nil, state == .possible,
           let first = touches.min(by: { $0.timestamp < $1.timestamp }) {
            primaryTouch = first
            startLocation = first.location(in: view)
            location = startLocation
            samples.append((location, first.timestamp))
            onContactBegan(location)
        }
        // Keep UIKit's contact bookkeeping intact. Additional contacts never
        // enter our position/velocity samples or end the primary contact.
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        sample(primaryTouch)
        if state == .possible {
            guard max(abs(location.x - startLocation.x), abs(location.y - startLocation.y)) >= 6 else { return }
            state = .began
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        sample(primaryTouch)
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    private func sample(_ touch: UITouch) {
        location = touch.location(in: view)
        let time = touch.timestamp
        // A small event-driven history smooths release velocity. Holding still
        // expires the old movement on the next event, without running a timer.
        samples.removeAll { time - $0.time > 0.08 }
        samples.append((location, time))
        if samples.count > 8 { samples.removeFirst() }
        if let first = samples.first, time - first.time > 0.001 {
            let dt = time - first.time
            velocity = CGPoint(x: (location.x - first.point.x) / dt,
                               y: (location.y - first.point.y) / dt)
        } else {
            velocity = .zero
        }
    }

    override func reset() {
        super.reset()
        primaryTouch = nil
        samples.removeAll(keepingCapacity: true)
        velocity = .zero
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

struct DrawerPanValue {
    var translation: CGSize
    var predictedEndTranslation: CGSize
    var startLocation: CGPoint
    var startedInDrawer: Bool = false
}

/// The background probe installs one recognizer on its containing view. It
/// observes both drawer surfaces without adding a hit-testing overlay or another
/// hosting controller. Touches outside this root (including modal sheets) never
/// belong to its view hierarchy.
struct DrawerPanGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var startsInDrawer: (CGPoint) -> Bool = { _ in false }
    var allowsTouch: (UITouch) -> Bool = { _ in true }
    var onChanged: (DrawerPanValue) -> Void
    var onEnded: (DrawerPanValue) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> DrawerPanGestureView {
        let view = DrawerPanGestureView()
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: DrawerPanGestureView, context: Context) {
        view.startsInDrawer = startsInDrawer
        view.allowsTouch = allowsTouch
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onCancelled = onCancelled
        view.pan.isEnabled = isEnabled
    }
    static func dismantleUIView(_ view: DrawerPanGestureView, coordinator: ()) {
        view.detach()
    }
}

final class DrawerPanGestureView: UIView, UIGestureRecognizerDelegate {
    var startsInDrawer: (CGPoint) -> Bool = { _ in false }
    var allowsTouch: (UITouch) -> Bool = { _ in true }
    private var startedInDrawer = false
    var onChanged: (DrawerPanValue) -> Void = { _ in }
    var onEnded: (DrawerPanValue) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    let pan = DrawerSingleContactPan()
    private weak var installedView: UIView?
    private var previousMultipleTouchEnabled: Bool?
    private var isTracking = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        pan.onContactBegan = { [weak self] location in
            guard let self else { return }
            // Capture the initial surface before an opening animation can move
            // the panel underneath a stationary contact.
            self.startedInDrawer = self.startsInDrawer(self.convert(location, from: self.pan.view))
        }
        pan.addTarget(self, action: #selector(handlePan(_:)))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToSuperview() { super.didMoveToSuperview(); attachIfNeeded() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachIfNeeded()
        // The hosting controller's responder link can be installed after its
        // children's didMoveToWindow callbacks. Resolve once after mounting.
        if window != nil {
            DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
        }
    }

    private func attachIfNeeded() {
        guard window != nil else { detach(); return }
        // SwiftUI may put a background in a noninteractive wrapper. Walk only
        // when the probe mounts to reach the containing controller's root view,
        // whose descendants include both visible surfaces.
        var responder: UIResponder? = self
        while let candidate = responder, !(candidate is UIViewController) {
            responder = candidate.next
        }
        guard let controller = responder as? UIViewController,
              let host = controller.viewIfLoaded,
              isDescendant(of: host) else { detach(); return }
        guard installedView !== host else { return }
        detach()
        installedView = host
        previousMultipleTouchEnabled = host.isMultipleTouchEnabled
        host.addGestureRecognizer(pan)

    }

    func detach() {
        // Removal can cancel an active pan. Reconcile exactly once even if UIKit
        // does not deliver a target-action callback while tearing down the view.
        installedView?.removeGestureRecognizer(pan)
        previousMultipleTouchEnabled = nil
        installedView = nil
        if isTracking { isTracking = false; onCancelled() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        bounds.contains(touch.location(in: self)) && allowsTouch(touch)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc private func handlePan(_ pan: DrawerSingleContactPan) {
        if pan.state == .began { isTracking = true }
        let start = convert(pan.startLocation, from: pan.view)
        let current = convert(pan.location, from: pan.view)
        let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
        let velocity = pan.velocity
        let value = DrawerPanValue(
            translation: CGSize(width: delta.x, height: delta.y),
            predictedEndTranslation: CGSize(width: delta.x + velocity.x * 0.25,
                                          height: delta.y + velocity.y * 0.25),
            startLocation: start,
            startedInDrawer: startedInDrawer
        )
        switch pan.state {
        case .began, .changed: onChanged(value)
        case .ended:
            guard isTracking else { return }
            isTracking = false
            onEnded(value)
        case .cancelled, .failed:
            guard isTracking else { return }
            isTracking = false
            onCancelled()
        default: break
        }
    }
}
