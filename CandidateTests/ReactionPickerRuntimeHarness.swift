@MainActor
private enum Probe {
    static let start = Date()
    static func log(_ text: String) { print("TRACE", Date().timeIntervalSince(start), text, "active", UIApplication.shared.applicationState.rawValue) }
    static var dismissNextAppearance = false
    static var capturedEntrance = false
    static var dismiss: (() -> Void)?
    static var more: (() -> Void)?
    static var dismissals = 0
    static var moreActions = 0
    static var failures: [String] = []
    static var window: UIWindow?
    static func capture(_ name: String) {
        // Snapshot rendering stalls the simulator main thread; enable it only
        // for visual inspection, never for timing-sensitive lifecycle checks.
        guard ProcessInfo.processInfo.arguments.contains("-capture-frames") else { return }
        guard let window else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        try? image.pngData()?.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".png"))
    }
}
@MainActor @Observable private final class Scenario {
    var started = false
    func startIfActive() {
        guard !started, UIApplication.shared.applicationState == .active else { return }
        started = true
        later(0.5) { self.run() }
    }
    var presentation: MessageReactionPickerPresentation?
    let reduceMotion = ProcessInfo.processInfo.arguments.contains("-reduce-motion")
    func show() { Probe.log("show"); presentation = MessageReactionPickerPresentation(messageID: UUID(), globalLocation: CGPoint(x: 201, y: 410)) }
    func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
    func run() {
        later(1) { self.show() }
        later(1.5) { Probe.capture("settled") }
        later(1.7) { Probe.dismiss?() }
        later(1.77) { Probe.capture("dismissal-070ms") }
        later(2.1) { if self.presentation != nil { Probe.failures.append("normal dismissal") }; Probe.dismissNextAppearance = true; self.show() }
        later(2.7) { if Probe.dismissals != 2 { Probe.failures.append("rapid repeated dismissal") }; self.show() }
        later(3.1) { Probe.more?() }
        later(3.5) {
            if Probe.moreActions != 1 || self.presentation != nil { Probe.failures.append("more completion") }
            self.show()
        }
        later(3.8) { Probe.dismiss?() }
        later(3.82) { self.show() }
        later(4.1) { if self.presentation == nil { Probe.failures.append("stale dismissal removed replacement") }; Probe.dismiss?() }
        later(4.6) {
            if self.presentation != nil { Probe.failures.append("final overlay remains") }
            let report: [String: Any] = ["reduceMotion": self.reduceMotion, "dismissals": Probe.dismissals, "moreActions": Probe.moreActions, "failures": Probe.failures]
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("report.json")
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            print(String(data: try! Data(contentsOf: url), encoding: .utf8)!)
            exit(Probe.failures.isEmpty ? 0 : 1)
        }
    }
}
private struct HarnessView: View {
    @State private var scenario = Scenario()
    var body: some View {
        ZStack {
            Color(white: 0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text("表情气泡 · 5028").font(.title.bold())
                ForEach(0..<12) { row in
                    Text("轻轻长按，选一个喜欢的表情。背景的文字应该透过玻璃，仍然看得见轮廓。 \(row)")
                        .font(.system(size: 23)).foregroundStyle(row == 4 ? .orange : .primary)
                }
            }.padding(25)
            if let presentation = scenario.presentation {
                MessageReactionPickerOverlay(presentation: presentation, selectedReaction: nil, onSelect: { _ in }, onMore: {
                    guard scenario.presentation?.id == presentation.id else { return }
                    Probe.moreActions += 1
                }, onDismiss: {
                    guard scenario.presentation?.id == presentation.id else { return }
                    Probe.log("dismiss completion"); Probe.dismissals += 1
                    scenario.presentation = nil
                }).id(presentation.id)
            }
        }
        .onAppear { scenario.startIfActive() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in scenario.startIfActive() }
    }
}
@main private final class HarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: HarnessView())
        window.makeKeyAndVisible(); self.window = window; Probe.window = window
        return true
    }
}
