// Standalone simulator harness. Compile with the exact gate extracted from
// ComposerView.swift; this file is not included in the shipping Xcode target.
import SwiftUI
import UIKit

@MainActor
final class SyntheticTouchRecognizer: UIGestureRecognizer {
    var points: [CGPoint] = []
    override var numberOfTouches: Int { points.count }
    override func location(ofTouch index: Int, in target: UIView?) -> CGPoint {
        view!.convert(points[index], to: target)
    }
    func finishTouch() { state = .ended }
}

@main
@MainActor
final class ComposerSelectionGateHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var results: [[String: Any]] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async { self.run() }
        return true
    }

    private func check(_ name: String, _ passed: Bool) {
        results.append(["name": name, "passed": passed])
    }

    private func exercise(_ view: UIView, name: String, in root: UIView) {
        guard let input = view as? any UITextInput else {
            check(name + " conforms to UITextInput", false)
            return
        }
        check(name + " becomes first responder", view.becomeFirstResponder())
        root.layoutIfNeeded()
        guard let start = input.position(from: input.beginningOfDocument, offset: 2),
              let end = input.position(from: input.beginningOfDocument, offset: 5),
              let range = input.textRange(from: start, to: end) else {
            check(name + " selects native text range", false)
            return
        }
        input.selectedTextRange = range
        root.layoutIfNeeded()
        let geometry = input.textInputView ?? view
        let touch = SyntheticTouchRecognizer()
        root.addGestureRecognizer(touch)
        defer {
            root.removeGestureRecognizer(touch)
            view.resignFirstResponder()
        }
        func place(_ point: CGPoint) { touch.points = [geometry.convert(point, to: root)] }
        let leading = input.caretRect(for: start)
        let trailing = input.caretRect(for: end)
        check(name + " native geometry exists", leading.height > 0 && trailing.height > 0)
        place(CGPoint(x: leading.midX, y: leading.minY - 12))
        check(name + " upper handle owned", ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        place(CGPoint(x: trailing.midX, y: trailing.maxY + 12))
        check(name + " lower handle owned", ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        if let selectedRect = input.selectionRects(for: range).first(where: { !$0.rect.isEmpty })?.rect {
            place(CGPoint(x: selectedRect.midX, y: selectedRect.midY))
            check(name + " selected text owned", ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        } else {
            check(name + " selected text geometry exists", false)
        }
        place(CGPoint(x: trailing.midX, y: trailing.maxY + 100))
        check(name + " chat outside selection available", !ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        input.selectedTextRange = input.textRange(from: end, to: end)
        place(CGPoint(x: trailing.midX, y: trailing.midY))
        check(name + " insertion caret owned", ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        touch.points = []
        check(name + " idle selection does not block drawer", !ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        place(CGPoint(x: trailing.midX, y: trailing.midY))
        touch.isEnabled = false
        check(name + " disabled recognizer ignored", !ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        touch.isEnabled = true
        touch.finishTouch()
        check(name + " ended touch ignored", !ComposerTextSelectionInteractionGate.ownsCurrentTouch)
    }

    private func run() {
        let root = window!.rootViewController!.view!
        check("no focused editor", !ComposerTextSelectionInteractionGate.ownsCurrentTouch)
        let field = UITextField(frame: CGRect(x: 35, y: 130, width: 260, height: 50))
        field.text = "啊啊啊啊啊 Hello Mocca 123"
        root.addSubview(field)
        exercise(field, name: "UITextField", in: root)
        field.removeFromSuperview()

        let text = UITextView(frame: CGRect(x: 35, y: 200, width: 260, height: 140))
        text.font = .systemFont(ofSize: 17)
        text.text = "啊啊啊啊啊 Hello Mocca\n第二行输入文字。"
        root.addSubview(text)
        exercise(text, name: "UITextView", in: root)
        text.removeFromSuperview()
        check("resigned editors do not leave a gate", !ComposerTextSelectionInteractionGate.ownsCurrentTouch)

        let host = UIHostingController(rootView:
            TextField("Message", text: .constant("啊啊啊啊啊 Hello Mocca"), axis: .vertical)
                .font(.system(size: 17)).lineLimit(1...6).frame(width: 260)
        )
        let controller = window!.rootViewController!
        controller.addChild(host)
        host.view.frame = CGRect(x: 35, y: 250, width: 280, height: 120)
        root.addSubview(host.view)
        host.didMove(toParent: controller)
        root.layoutIfNeeded()
        DispatchQueue.main.async {
            @MainActor func nativeEditor(in view: UIView) -> UIView? {
                if view is UITextField || view is UITextView { return view }
                return view.subviews.lazy.compactMap { nativeEditor(in: $0) }.first
            }
            if let editor = nativeEditor(in: host.view) {
                self.exercise(editor, name: "SwiftUI vertical TextField", in: root)
            } else {
                self.check("SwiftUI vertical TextField native editor exists", false)
            }
            self.finish()
        }
    }

    private func finish() {
        let failed = results.filter { ($0["passed"] as? Bool) != true }
        let report: [String: Any] = [
            "passed": failed.isEmpty,
            "checks": results,
            "scope": "Real UIKit input, selection geometry and responder dispatch; synthetic recognizer touch locations. Not a physical drag or performance test."
        ]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selection-gate-results.json")
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("COMPOSER_SELECTION_GATE \(failed.isEmpty ? "PASS" : "FAIL") \(results.count - failed.count)/\(results.count)")
    }
}
