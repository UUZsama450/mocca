import UIKit
import SwiftUI
import Observation

@MainActor enum FadeTrace {
    static var observation: NSKeyValueObservation?
    static weak var target: CALayer?
    static var isApplying = false
    static var expected: Float = 0
    static var registrations = 0
    static var contentBodies = 0
    static var baseX: CGFloat = 0
    static var positionMismatches: [[String: Any]] = []
    static var ownWrites = 0
    static var externalWrites: [[String: Any]] = []
    static var mismatches: [[String: Any]] = []
    static weak var host: UIView?
    static weak var scrollView: UIScrollView?
    static var scrollRegistrations = 0
    static var deepScrollSteps: [CGFloat] = []
    static var scrollMismatches: [[String: Any]] = []
    static var expectedScrollY: CGFloat?
    static func checkDeepScroll(at time: CFTimeInterval) {
        func findScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                return scroll
            }
            for child in view.subviews {
                if let found = findScroll(in: child) { return found }
            }
            return nil
        }
        guard let host, let scroll = findScroll(in: host) else { return }
        if scrollView !== scroll {
            scrollView = scroll
            scrollRegistrations += 1
        }
        if let expectedScrollY, abs(scroll.contentOffset.y - expectedScrollY) > 0.5 {
            scrollMismatches.append(["time": time, "actual": scroll.contentOffset.y, "expected": expectedScrollY])
        }
        let requestedY: CGFloat? = time > 1.5 && deepScrollSteps.isEmpty ? 1800
            : time > 4.5 && deepScrollSteps.count == 1 ? 2900 : nil
        if let requestedY {
            let y = min(requestedY, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            expectedScrollY = y
            deepScrollSteps.append(y)
        }
    }
    static func begin(target: CALayer, progress: CGFloat) {
        expected = Float(0.35 + 0.65 * progress)
        if self.target !== target {
            registrations += 1
            self.target = target
            #if BASELINE
            baseX = target.frame.minX
            #else
            baseX = target.frame.minX + 24 * (1 - progress)
            #endif
            observation = target.observe(\.opacity, options: [.old, .new]) { layer, change in
                MainActor.assumeIsolated {
                    if isApplying { ownWrites += 1; return }
                    var row: [String: Any] = ["time": CACurrentMediaTime(), "old": change.oldValue ?? -1,
                                             "new": change.newValue ?? -1, "expected": expected]
                    if externalWrites.count < 8 { row["stack"] = Thread.callStackSymbols }
                    externalWrites.append(row)
                }
            }
        }
        isApplying = true
    }
    static func sample(_ progress: CGFloat) {
        guard let target else { return }
        let expected = Float(0.35 + 0.65 * progress)
        let expectedX = baseX - 24 * (1 - progress)
        if abs(target.frame.minX - expectedX) > 0.5 {
            positionMismatches.append(["actual": target.frame.minX, "expected": expectedX])
        }
        if abs(target.opacity - expected) > 0.005 {
            mismatches.append(["time": CACurrentMediaTime(), "actual": target.opacity, "expected": expected])
        }
    }
    static func finish() {
        let result: [String: Any] = ["registrations": registrations, "ownWrites": ownWrites, "contentBodies": contentBodies,
                                    "positionMismatches": positionMismatches,
                                    "scrollRegistrations": scrollRegistrations,
                                    "deepScrollSteps": deepScrollSteps, "scrollMismatches": scrollMismatches,
                                    "externalWrites": externalWrites, "mismatchesAtNextFrame": mismatches]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fade-trace.json")
        try! data.write(to: url)
        print("FADE_TRACE \(url.path) registrations=\(registrations) external=\(externalWrites.count) mismatches=\(mismatches.count)")
        exit(0)
    }
}

@MainActor @Observable final class MotionState: NSObject {
    var progress: CGFloat = 0
    var visualProgress: CGFloat = 0
    fileprivate let settle = DrawerDetachedMainPanelProgress()
    var gestureActive = false
    var titleRevision = 0
    @ObservationIgnored var link: CADisplayLink?
    @ObservationIgnored var startTime: CFTimeInterval = 0
    func start() {
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc func frame(_ link: CADisplayLink) {
        FadeTrace.sample(visualProgress)
        let time = CACurrentMediaTime() - startTime
        FadeTrace.checkDeepScroll(at: time)
        if time > 9 { link.invalidate(); FadeTrace.finish(); return }
        let cycle = time.truncatingRemainder(dividingBy: 0.7) / 0.7
        let next = CGFloat(cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2)
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            visualProgress = next
            if time > 3 && time < 6 {
                settle.begin(at: next)
                progress = 1 // List layout remains at its endpoint during vertical takeover.
            } else {
                settle.clear()
                progress = next
            }
            gestureActive = Int(time / 0.35) % 2 == 0
            titleRevision = ProcessInfo.processInfo.arguments.contains("-stable-content") ? 0 : Int(time / 1.4)
        }
        DrawerTrackedContentLayerMotion.update(next)
    }
}

struct StableDrawer: View, Equatable {
    let titleRevision: Int
    var body: some View {
        let _ = { FadeTrace.contentBodies += 1 }()
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "person.circle.fill"); Text("Synthetic drawer \(titleRevision)") }.font(.title2)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<1000) { index in
                        HStack { Image(systemName: "bubble.left"); Text("Conversation \(index)") }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Image(systemName: "gear"); Text("Settings"); Spacer() }
        }.padding(20)
    }
}

struct HarnessSurface: View {
    let state: MotionState
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                StableDrawer(titleRevision: state.titleRevision).equatable()
                    .scrollDisabled(state.gestureActive)
                    #if BASELINE
                    .modifier(DrawerTrackedContentLayerModifier(progress: state.progress))
                    #else
                    .modifier(DrawerContentMotionModifier(progress: state.progress, settleProgress: state.settle))
                    .overlay {
                        DrawerTrackedContentLayerProbe(progress: state.visualProgress)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    #endif
                    .frame(width: 314, height: geometry.size.height)
                    .background(Color.white)
                Color.gray.opacity(0.2)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(x: 314 * state.visualProgress)
                    .allowsHitTesting(false)
            }
        }.ignoresSafeArea()
    }
}

@main @MainActor final class HarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let state = MotionState()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: HarnessSurface(state: state))
        FadeTrace.host = window.rootViewController?.view
        self.window = window
        window.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.state.start() }
        return true
    }
}
