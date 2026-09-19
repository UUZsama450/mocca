import UIKit
import SwiftUI
import Darwin

// EXTRACTED_ROUTING_CLASSES

// Only noninteractive shadow drawing and theme storage are substituted. The
// production contentShape, overlay, clipping and touch modifiers are extracted.
@MainActor @Observable private final class AppModel {
    var themeSurfaceUIColor: UIColor { .white }
}
private struct DrawerPanelShadowLayer: View {
    let cornerRadius: CGFloat
    let progress: CGFloat
    var body: some View { Color.clear }
}

@MainActor private final class HostingBranchProbe: UIView {
    var queries = 0
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        queries += 1
        return super.hitTest(point, with: event)
    }
}

@MainActor private struct Fixture: View {
    var body: some View {
        VStack {
            Text(String(repeating: "Selectable chat text with a link. ", count: 90))
                .textSelection(.enabled)
            Button("Fixture action") {}
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
            .modifier(MainChatPanelChrome(cornerRadius: 44, shadowProgress: 1,
                                         isInteractionBlocked: true, onCloseDrawer: {}))
            .environment(AppModel())
    }
}

@main @MainActor final class DrawerNativeHitRoutingHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var failures: [String] = []
    var checks = 0
    var skippedHostingQueries = 0
    var baselineHostingQueries = 0

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        DispatchQueue.main.async { self.run() }
        return true
    }

    func check(_ result: Bool, _ message: String) {
        checks += 1
        if !result { failures.append(message) }
    }

    func run() {
        let root = window!.rootViewController!
        let wrapper = DrawerLivePanelPassthroughView()
        let oldWrapper = BaselineDrawerLivePanelPassthroughView()
        let probe = HostingBranchProbe()
        let host = UIHostingController(rootView: Fixture())
        root.addChild(host)
        probe.addSubview(host.view)
        host.didMove(toParent: root)
        let shield = DrawerMainPanelTouchShield(frame: .zero)
        wrapper.touchShield = shield
        root.view.addSubview(oldWrapper)
        root.view.addSubview(wrapper)
        wrapper.addSubview(probe)
        wrapper.addSubview(shield)
        var closeCount = 0
        shield.onCloseDrawer = { closeCount += 1 }

        for size in [CGSize(width: 402, height: 874), CGSize(width: 320, height: 700), CGSize(width: 874, height: 402)] {
            wrapper.frame = CGRect(origin: .zero, size: size)
            oldWrapper.frame = wrapper.frame
            probe.transform = .identity
            shield.transform = .identity
            probe.frame = wrapper.bounds
            shield.frame = wrapper.bounds
            host.view.frame = probe.bounds
            host.view.layoutIfNeeded()
            for progress: CGFloat in [0, 0.001, 0.15, 0.5, 0.9, 1, 0.5, 0] {
                let x = min(size.width * 0.78, 390) * progress
                probe.transform = CGAffineTransform(translationX: x, y: 0)
                shield.transform = probe.transform
                for point in [CGPoint(x: -1, y: 100), CGPoint(x: 0, y: 100),
                              CGPoint(x: max(0, x - 1), y: 100), CGPoint(x: x, y: 100),
                              CGPoint(x: x + 1, y: 100), CGPoint(x: size.width - 1, y: 100),
                              CGPoint(x: x + 1, y: 1), CGPoint(x: x + 2, y: 10),
                              CGPoint(x: x + 1, y: size.height - 1),
                              CGPoint(x: size.width + 1, y: 100), CGPoint(x: 200, y: -1),
                              CGPoint(x: 200, y: size.height + 1)] {
                    // The same real UIHostingController subtree is reused for both wrappers.
                    // This checks normal routing identity, not a duplicated fake hit policy.
                    shield.isHidden = true
                    oldWrapper.addSubview(probe)
                    probe.queries = 0
                    let oldHit = oldWrapper.hitTest(point, with: nil)
                    baselineHostingQueries += probe.queries
                    wrapper.insertSubview(probe, belowSubview: shield)
                    let newHit = wrapper.hitTest(point, with: nil)
                    check(oldHit === newHit, "normal route changed size=\(size) p=\(progress) point=\(point)")

                    shield.isHidden = false
                    probe.queries = 0
                    let blockedHit = wrapper.hitTest(point, with: nil)
                    let insidePanel = wrapper.bounds.contains(point)
                        && CGRect(x: x, y: 0, width: size.width, height: size.height).contains(point)
                    check(insidePanel ? blockedHit === shield : blockedHit == nil,
                          "blocked/exposed route size=\(size) p=\(progress) point=\(point)")
                    check((oldHit != nil) == (blockedHit != nil), "baseline chrome coverage differs point=\(point) p=\(progress)")
                    check(probe.queries == 0, "blocked query entered hosting branch")
                    skippedHostingQueries += 1

                    shield.isHidden = true
                    check(wrapper.hitTest(point, with: nil) === oldHit, "first query after unblocking")
                }
            }
        }
        shield.isHidden = false
        for property in ["hidden", "disabled", "transparent"] {
            wrapper.isHidden = property == "hidden"
            wrapper.isUserInteractionEnabled = property != "disabled"
            wrapper.alpha = property == "transparent" ? 0.001 : 1
            check(wrapper.hitTest(CGPoint(x: 250, y: 100), with: nil) == nil, property)
        }
        wrapper.isHidden = false
        wrapper.isUserInteractionEnabled = true
        wrapper.alpha = 1
        check(shield.accessibilityActivate() && closeCount == 1, "accessible close")
        shield.isHidden = true
        check(!shield.accessibilityActivate() && closeCount == 1, "hidden shield cannot close")
        check(baselineHostingQueries > 0, "baseline actually exercised hosting branch")
        let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks,
            "failures": failures, "blocked_query_count": skippedHostingQueries,
            "baseline_hosting_branch_queries": baselineHostingQueries,
            "scope": "Source-extracted UIKit wrappers/shield with the same real SwiftUI host; direct point queries, geometry and restoration. Not injected fingers or phone FPS."]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("routing-results.json")
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("DRAWER_NATIVE_HIT \(failures.isEmpty ? "PASS" : "FAIL") checks=\(checks)")
        fflush(nil)
        exit(failures.isEmpty ? 0 : 1)
    }
}
