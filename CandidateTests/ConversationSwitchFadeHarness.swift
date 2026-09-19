import SwiftUI
import UIKit
import Observation

// Apple's reduce-motion environment is read-only. The extractor substitutes
// only that environment key so this host can exercise both values deterministically.
private struct TestReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var testReduceMotion: Bool {
        get { self[TestReduceMotionKey.self] }
        set { self[TestReduceMotionKey.self] = newValue }
    }
}

// Standalone synthetic host. The runner inserts the production modifier above
// this file and observes its output, without instrumenting the shipping app.
@MainActor enum FadeProbe {
    static var start = CACurrentMediaTime()
    static var samples: [[String: Any]] = []
    static var starts: [[String: Any]] = []
    static var renderedKeys: [String] = []
    static var phase = "initial"
    static var onPartialFrame: (() -> Void)?
    static var events: [[String: Any]] = []
    static var bodies = 0
    static var makes = 0
    static var updates = 0
    static var textWrites = 0
    static var dismantles = 0
    static weak var host: UIView?
    static func opacity(_ value: Double, id: UUID) -> Double {
        samples.append(["time": CACurrentMediaTime() - start, "value": value, "phase": phase,
                        "id": id.uuidString])
        if phase == "interrupted", value > 0.35, value < 0.95, let action = onPartialFrame {
            onPartialFrame = nil
            DispatchQueue.main.async(execute: action)
        }
        return value
    }
    static func startOpacity(_ value: Double, current: Double) -> Double {
        starts.append(["phase": phase, "current": current, "chosen": value])
        return value
    }
    static func event(_ name: String) {
        func scroll(in view: UIView) -> UIScrollView? {
            if let view = view as? UIScrollView, view.isScrollEnabled { return view }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        var result: [String: Any] = ["name": name, "time": CACurrentMediaTime() - start,
            "bodies": bodies, "makes": makes, "updates": updates,
            "textWrites": textWrites, "dismantles": dismantles]
        if let host, let view = scroll(in: host) {
            result["offsetY"] = view.contentOffset.y
            result["height"] = view.bounds.height
            result["contentHeight"] = view.contentSize.height
        }
        events.append(result)
    }
    static func finish() {
        event("finish")
        let result: [String: Any] = ["samples": samples, "events": events,
                                    "starts": starts, "renderedKeys": renderedKeys]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fade-report.json")
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("CONVERSATION_FADE_REPORT \(url.path)")
        exit(0)
    }
}

@MainActor @Observable final class FadeModel {
    var conversation = 0
    var revision = 0
    var empty = false
    var reduceMotion = false
    var id: UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", conversation))! }
}

private struct NativeText: UIViewRepresentable {
    let value: String
    func makeUIView(context: Context) -> UITextView {
        FadeProbe.makes += 1
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.font = .systemFont(ofSize: 18)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        FadeProbe.updates += 1
        if view.text != value { view.text = value; FadeProbe.textWrites += 1 }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: ()) { FadeProbe.dismantles += 1 }
}

private struct Transcript: View {
    let conversation: Int
    let revision: Int
    var body: some View {
        let _ = {
            FadeProbe.bodies += 1
            FadeProbe.renderedKeys.append("\(conversation):\(revision)")
        }()
        NativeText(value: "Conversation \(conversation), revision \(revision)\n" + String(repeating: "选字与正文排版保持原样。\n", count: 65))
            .frame(height: conversation.isMultiple(of: 2) ? 1800 : 2400)
    }
}

private struct TestRoot: View {
    let model: FadeModel
    var body: some View {
        let conversationID = model.id
        let conversation = model.conversation
        let revision = model.revision
        let reduceMotion = model.reduceMotion
        VStack {
            Text("Fixed header").frame(height: 50)
            ZStack {
                Color(uiColor: .systemBackground)
                if model.empty {
                    Text("Empty conversation").frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(conversationID)
                } else {
                    ScrollViewReader { _ in
                        ScrollView {
                            Transcript(conversation: conversation, revision: revision)
                        }
                        .defaultScrollAnchor(.bottom)
                        .id(conversationID)
                    }
                    .modifier(ConversationSwitchFadeModifier(conversationID: conversationID))
                }
            }
            TextField("Native composer", text: .constant("草稿"))
                .textFieldStyle(.roundedBorder).frame(height: 50)
        }
        .environment(\.testReduceMotion, reduceMotion)
    }
}

private final class FadeHostingController: UIHostingController<TestRoot> {
    var onReady: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let ready = onReady
        onReady = nil
        DispatchQueue.main.async { ready?() }
    }
}

@main @MainActor final class FadeHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let model = FadeModel()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = FadeHostingController(rootView: TestRoot(model: model))
        controller.onReady = { Task { await self.runScenario() } }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        FadeProbe.host = controller.view
        return true
    }
    private func runScenario() async {
        // Await each completed case; a busy simulator must not coalesce the
        // baseline's future cases before its first frame has appeared.
        await pause(500); FadeProbe.event("initial")
        FadeProbe.phase = "single"; select(1)
        await pause(350); FadeProbe.event("single-finished")
        FadeProbe.phase = "interrupted"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            #if BASELINE
            select(20)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                self.select(21); continuation.resume()
            }
            #else
            FadeProbe.onPartialFrame = {
                self.select(21); continuation.resume()
            }
            select(20)
            #endif
        }
        await pause(350); FadeProbe.event("interrupted-finished")
        FadeProbe.phase = "content"; model.revision += 1
        await pause(350); FadeProbe.event("content-update-finished")
        FadeProbe.phase = "rapid"
        for index in 0..<6 {
            select(index + 2)
            // Include both a later in-flight interruption and immediate bursts.
            await pause(index == 0 ? 90 : 30)
        }
        await pause(350); FadeProbe.event("rapid-finished")
        FadeProbe.phase = "next-single"; select(8)
        await pause(350); FadeProbe.event("next-single-finished")
        FadeProbe.phase = "empty"; model.empty = true; select(9)
        await pause(350)
        FadeProbe.phase = "reentry"; select(10); model.empty = false
        await pause(350); FadeProbe.event("empty-roundtrip-finished")
        FadeProbe.phase = "reduced"; model.reduceMotion = true
        await pause(350)
        select(11)
        await pause(350); FadeProbe.event("reduced-finished")
        FadeProbe.phase = "reduce-off"; model.reduceMotion = false
        await pause(350)
        FadeProbe.phase = "restored"; select(12)
        await pause(350); FadeProbe.event("restored-finished")
        await pause(350); FadeProbe.finish()
    }
    private func select(_ value: Int) {
        // The real drawer's selection transaction also disables implicit motion.
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { model.conversation = value }
    }
    private func pause(_ milliseconds: Int) async {
        try! await Task.sleep(for: .milliseconds(milliseconds))
    }
}
