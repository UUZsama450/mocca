import SwiftUI
import UIKit

/// Intercepts only the sheet containing this probe. It never follows a presented
/// child sheet, and restores the previous delegate only while it still owns it.
struct DraftDismissObserver: UIViewControllerRepresentable {
    let hasUnsavedChanges: Bool
    let onAttempt: () -> Void
    var onDismiss: () -> Void = {}

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hasUnsavedChanges = hasUnsavedChanges
        controller.onAttempt = onAttempt
        controller.onDismiss = onDismiss
        controller.installIfPossible()
        // The first update can precede containment in the hosting controller.
        DispatchQueue.main.async { [weak controller] in controller?.installIfPossible() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.uninstall()
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var hasUnsavedChanges = false
        var onAttempt: () -> Void = {}
        var onDismiss: () -> Void = {}
        private weak var observedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private var isDismantled = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIfPossible()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfPossible()
        }

        func installIfPossible() {
            guard !isDismantled else { return }
            var ancestor = parent
            while let controller = ancestor {
                // UIKit forwards presentingViewController through containment.
                // A pushed navigation container can therefore look presented
                // without actually owning the enclosing sheet.
                if let presenter = controller.presentingViewController,
                   presenter.presentedViewController === controller,
                   let presentation = controller.presentationController,
                   presentation.presentedViewController === controller {
                    if observedPresentation !== presentation {
                        restoreDelegate()
                        observedPresentation = presentation
                    }
                    if presentation.delegate !== self {
                        // SwiftUI may replace its delegate while updating this
                        // same sheet. Forward to the new delegate, never a stale one.
                        previousDelegate = presentation.delegate
                        presentation.delegate = self
                    }
                    return
                }
                ancestor = controller.parent
            }
        }

        func uninstall() {
            isDismantled = true
            restoreDelegate()
            onAttempt = {}
            onDismiss = {}
        }

        private func restoreDelegate() {
            if let presentation = observedPresentation, presentation.delegate === self {
                presentation.delegate = previousDelegate
            }
            observedPresentation = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !hasUnsavedChanges
                && (previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if hasUnsavedChanges { onAttempt() }
            previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss()
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}

// A dirty draft recognizes the back swipe before UIKit can pop. Use the
// documented failure relationship for both native recognizers; their delegates,
// enabled state and clean interactive transitions stay owned by UIKit.
struct DraftNavigationGuard: UIViewControllerRepresentable {
    let hasUnsavedChanges: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hasUnsavedChanges = hasUnsavedChanges
        controller.onAttempt = onAttempt
        controller.installIfPossible()
        DispatchQueue.main.async { [weak controller] in controller?.installIfPossible() }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.uninstall()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var hasUnsavedChanges = false {
            didSet { backAttempt.isEnabled = hasUnsavedChanges }
        }
        var onAttempt: () -> Void = {}
        private var isVisible = false
        private lazy var backAttempt = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            installIfPossible()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            uninstall()
        }
        func installIfPossible() {
            guard isVisible, viewIfLoaded?.window != nil,
                  let navigationController, backAttempt.view !== navigationController.view else { return }
            backAttempt.delegate = self
            backAttempt.maximumNumberOfTouches = 1
            backAttempt.isEnabled = hasUnsavedChanges
            navigationController.view.addGestureRecognizer(backAttempt)
            navigationController.interactivePopGestureRecognizer?.require(toFail: backAttempt)
            if #available(iOS 26.0, *) {
                navigationController.interactiveContentPopGestureRecognizer?.require(toFail: backAttempt)
            }
        }
        func uninstall() {
            isVisible = false
            backAttempt.isEnabled = false
            backAttempt.view?.removeGestureRecognizer(backAttempt)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard hasUnsavedChanges, let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.presentedViewController == nil else { return false }
            let velocity = backAttempt.velocity(in: navigationController.view)
            let direction: CGFloat = navigationController.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
            return velocity.x * direction > abs(velocity.y)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Text selection and controls retain their own horizontal gestures.
            var touched = touch.view
            while let current = touched, current !== gestureRecognizer.view {
                if current is UITextView || current is UIControl { return false }
                touched = current.superview
            }
            return true
        }
        @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { onAttempt() }
        }
    }
}
