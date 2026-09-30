"""Exercise the real probe and its real SwiftUI placement on an iOS simulator.

Synthetic rows; no iPhone, chat archive, touch physics or FPS acceptance.
Usage: /usr/bin/python3 CandidateTests/check_history_probe_lifetime.py SIMULATOR
"""
from pathlib import Path
import hashlib
import json
import platform
import plistlib
import subprocess
import sys
import time

from check_drawer_close_driver_reuse import extract

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/history-probe-lifetime/native"
BASE = "91e9d24"
SIM = sys.argv[1]
BUNDLE = "com.mocca.local.history-probe5073"
OUT.mkdir(parents=True, exist_ok=True)


def declaration(source, name):
    return extract(source, rf"^private (?:final class|class|enum|struct) {name}\b")[0]


def placement(source):
    a = source.index("                                Color.clear", source.index("ScrollViewReader { scrollProxy in"))
    b = source.index("                                let truncateIndex", a)
    top = source[a:b]
    marker = "                            .background(alignment: .topLeading) {"
    a = source.find(marker, b)
    if a < 0:
        return top, ""
    b = source.index("                        }\n                        // Keep the conversation visible", a)
    return top, source[a:b]


TEMPLATE = r'''
import SwiftUI
import UIKit
import Observation

@MainActor private enum Metrics {
    static var makes = 0
    static var dismantles = 0
    static var connectedReleases = 0
    static var resolved = 0
    static var topRequests = 0
    static var delegates = 0
    static var proxy: ScrollViewProxy?
    static var probes: [WeakView] = []
    static var liveProbes: Int { probes.filter { $0.value != nil }.count }
}
@MainActor private final class WeakView {
    weak var value: UIView?
    init(_ value: UIView) { self.value = value }
}
@MainActor private enum ChatBottomTrace {
    static func log(_ value: @autoclosure () -> String) {
        if value().hasPrefix("STATUS_TOP_DELEGATE_INSTALL") { Metrics.delegates += 1 }
    }
}
// PRODUCT
@MainActor @Observable private final class Fixture {
    var conversation = UUID()
    var request = 0
    var shown = true
    var start: Int
    var end: Int
    var spacer: CGFloat = 0
    let ids: [UUID]
    init(_ total: Int) {
        ids = (0..<total).map { _ in UUID() }
        start = max(0, total - 12); end = total
    }
    var anchor: ConversationBottomAnchorID {
        .init(positionRequest: .init(conversationID: conversation, request: request),
              messageIDs: Array(ids[start..<end]))
    }
}
private enum Navigation { case top }
@MainActor private struct Host: View {
    let model: Fixture
    let chatScrollViewBox: WeakChatScrollViewBox
    var topContentSpacerHeight: CGFloat { model.spacer }
    let conversationContentMinimumHeight: CGFloat = 792
    func requestMessageNavigation(_ action: Navigation) { Metrics.topRequests += 1 }
    func advanceMessageReplacementIfReady(using proxy: ScrollViewProxy) { Metrics.resolved += 1 }
    func finishMessageReplacementIfReady() {}
    var body: some View {
        let bottomAnchorID = model.anchor
        Group {
            if model.shown {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            // TOP
                            LazyVStack(spacing: 12) {
                                ForEach(Array(model.start..<model.end), id: \.self) { index in
                                    Text("Synthetic row \(index)")
                                        .frame(maxWidth: .infinity)
                                        .frame(height: CGFloat([72, 420, 140, 1100][index % 4]))
                                        .id(model.ids[index])
                                }
                            }
                            Color.clear.frame(height: 34).id(bottomAnchorID)
                        }
                        .frame(minHeight: conversationContentMinimumHeight, alignment: .top)
                        // STABLE
                    }
                    .safeAreaBar(edge: .top, spacing: 0) { Color.clear.frame(height: 48) }
                    .coordinateSpace(name: "chat-scroll")
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .id(model.conversation)
                    .onAppear { Metrics.proxy = scrollProxy }
                }
            }
        }
    }
}
@MainActor private enum Check {
    static func run() async throws {
        var events: [[String: Any]] = []
        for total in [16, 60, 500] {
            let model = Fixture(total)
            let box = WeakChatScrollViewBox()
            let controller = UIHostingController(rootView: Host(model: model, chatScrollViewBox: box).ignoresSafeArea())
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 874))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            func settle(_ seconds: Double = 0.08) async {
                let end = Date().addingTimeInterval(seconds)
                repeat {
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    try? await Task.sleep(for: .milliseconds(2))
                } while Date() < end
            }
            await settle(0.3)
            guard let original = box.scrollView else { fatalError("Missing initial registration") }
            for earlier in [true, false, true] {
                while earlier ? model.start > 0 : model.end < total {
                    let makes = Metrics.makes, releases = Metrics.connectedReleases
                    let delegateCount = Metrics.delegates
                    let before = [model.start, model.end]
                    let current = box.scrollView
                    if earlier {
                        model.start = max(0, model.start - 20)
                        model.end = min(model.end, model.start + 360)
                    } else {
                        model.end = min(total, model.end + 20)
                        model.start = max(0, model.end - 360)
                    }
                    await Task.yield()
                    let availableAfterYield = box.scrollView === current
                    await settle()
                    events.append(["total": total, "kind": "page", "earlier": earlier,
                        "before": before, "after": [model.start, model.end],
                        "probeMakes": Metrics.makes - makes,
                        "connectedReleases": Metrics.connectedReleases - releases,
                        "delegateInstalls": Metrics.delegates - delegateCount,
                        "availableAfterYield": availableAfterYield,
                        "sameNativeHost": box.scrollView === original,
                        "boundAfterLayout": box.scrollView?.window != nil,
                        "liveProbes": Metrics.liveProbes])
                }
            }
            let beforeLayout = Metrics.makes, beforeRelease = Metrics.connectedReleases
            for n in 0..<10 { model.spacer = CGFloat(n % 2); await settle(0.02) }
            events.append(["total": total, "kind": "ordinary_layout", "probeMakes": Metrics.makes - beforeLayout,
                "connectedReleases": Metrics.connectedReleases - beforeRelease, "sameNativeHost": box.scrollView === original])
            // Keep the revision-scoped top target independently addressable.
            Metrics.proxy!.scrollTo(ConversationTopMaterializationSeedID(anchorID: model.anchor), anchor: .top)
            await settle()
            events.append(["total": total, "kind": "top_target", "reachesTop": abs(original.contentOffset.y + original.adjustedContentInset.top) < 1])
            DrawerNativeScrollGate.update(isDrawerPresented: true, isDrawerGestureActive: false)
            let locked = !original.isScrollEnabled && !original.scrollsToTop
            DrawerNativeScrollGate.update(isDrawerPresented: false, isDrawerGestureActive: false)
            let unlocked = original.isScrollEnabled && original.scrollsToTop
            let calls = Metrics.topRequests
            let allowsDefault = original.delegate?.scrollViewShouldScrollToTop?(original)
            events.append(["total": total, "kind": "native_contracts", "drawerLocked": locked,
                "drawerUnlocked": unlocked, "statusBarRoutedOnce": Metrics.topRequests == calls + 1,
                "defaultStatusBarMoveSuppressed": allowsDefault == false])
            model.conversation = UUID(); model.request += 1
            await settle(0.2)
            let newScroll = box.scrollView
            events.append(["total": total, "kind": "conversation_switch", "newNativeHost": newScroll != nil && newScroll !== original,
                "oldRegistrationReleased": DrawerNativeScrollGate.owner(for: original, role: .chat) == nil,
                "oldDelegateReleased": !(original.delegate is ChatStatusBarScrollDelegateBridge), "liveProbes": Metrics.liveProbes])
            model.shown = false
            await settle(0.15)
            events.append(["total": total, "kind": "leave_page", "boxCleared": box.scrollView == nil,
                "gateReleased": newScroll.map { DrawerNativeScrollGate.owner(for: $0, role: .chat) == nil } ?? false,
                "delegateReleased": !(newScroll?.delegate is ChatStatusBarScrollDelegateBridge), "liveProbes": Metrics.liveProbes])
            model.shown = true
            await settle(0.15)
            events.append(["total": total, "kind": "return_page", "bound": box.scrollView?.window != nil,
                "liveProbes": Metrics.liveProbes])
            model.shown = false; await settle()
            window.isHidden = true; window.rootViewController = nil
            Metrics.proxy = nil; await settle()
        }
        let data = try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
        try data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json"), options: .atomic)
    }
}
@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in do { try await Check.run() } catch { print(error) } }
        return true
    }
}
'''

summaries = {}
for name, source in [("baseline", subprocess.check_output(["git", "show", BASE + ":Mocca/RootView.swift"], cwd=ROOT, text=True)),
                     ("candidate", (ROOT / "Mocca/RootView.swift").read_text())]:
    types = ["ConversationPositionRequestKey", "ConversationBottomAnchorID", "ConversationTopMaterializationSeedID"]
    actors = ["WeakChatScrollViewBox", "DrawerNativeScrollGate", "ChatScrollViewProbe", "ChatScrollViewRegistration", "ChatScrollViewProbeUIView", "ChatStatusBarScrollDelegateBridge"]
    product = "\n".join(declaration(source, x) for x in types)
    product += "\n" + "\n".join("@MainActor\n" + declaration(source, x) for x in actors)
    # Counters only in this extracted test app; production classes are unchanged.
    product = product.replace("        ChatScrollViewProbeUIView(\n", "        Metrics.makes += 1\n        let result = ChatScrollViewProbeUIView(\n", 1)
    product = product.replace("onResolved: onResolved\n        )\n    }", "onResolved: onResolved\n        )\n        Metrics.probes.append(WeakView(result))\n        return result\n    }", 1)
    product = product.replace("        uiView.dismantle()", "        Metrics.dismantles += 1\n        uiView.dismantle()", 1)
    product = product.replace("if box?.registration === self { box?.registration = nil }", "if box?.registration === self { Metrics.connectedReleases += 1; box?.registration = nil }")
    top, stable = placement(source)
    swift = TEMPLATE.replace("// PRODUCT", product).replace("// TOP", top).replace("// STABLE", stable)
    work = OUT / name
    work.mkdir(exist_ok=True)
    (work / "Host.swift").write_text(swift)
    app = work / "ProbeHost.app"
    app.mkdir(exist_ok=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BUNDLE, "CFBundleName": "ProbeHost", "CFBundleExecutable": "ProbeHost",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "26.0", "UIDeviceFamily": [1], "UILaunchScreen": {}}))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-sdk", sdk, "-target", platform.machine() + "-apple-ios26.0-simulator", "-swift-version", "6", "-parse-as-library", str(work / "Host.swift"), "-o", str(app / "ProbeHost")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    subprocess.run(["xcrun", "simctl", "terminate", SIM, BUNDLE], capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", SIM, str(app)], check=True, capture_output=True)
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", SIM, BUNDLE, "data"], text=True).strip())
    result = container / "Documents/results.json"
    result.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "launch", SIM, BUNDLE], check=True, capture_output=True)
    deadline = time.monotonic() + 45
    while not result.exists() and time.monotonic() < deadline:
        time.sleep(0.5)
    events = json.loads(result.read_text())
    (work / "results.json").write_text(json.dumps(events, indent=2) + "\n")
    pages = [e for e in events if e["kind"] == "page"]
    summaries[name] = {"events": len(events), "pages": len(pages), "probeMakesDuringPaging": sum(e["probeMakes"] for e in pages),
        "connectedReleasesDuringPaging": sum(e["connectedReleases"] for e in pages), "missingAfterYield": sum(not e["availableAfterYield"] for e in pages),
        "nativeHostChangedDuringPaging": sum(not e["sameNativeHost"] for e in pages),
        "source_sha256": hashlib.sha256(source.encode()).hexdigest()}
    for event in events:
        for key, value in event.items():
            if isinstance(value, bool) and key not in ("earlier", "availableAfterYield"):
                assert value, (name, event)
        if event["kind"] in ["page", "conversation_switch", "return_page"]:
            assert event["liveProbes"] == 1, (name, event)
        if event["kind"] == "leave_page":
            assert event["liveProbes"] == 0, (name, event)
    print(name, json.dumps(summaries[name]), flush=True)
    subprocess.run(["xcrun", "simctl", "terminate", SIM, BUNDLE], capture_output=True)
(OUT / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
assert summaries["baseline"]["connectedReleasesDuringPaging"] > 0, "Expected control did not reproduce probe release"
assert summaries["candidate"]["connectedReleasesDuringPaging"] == 0
assert summaries["candidate"]["probeMakesDuringPaging"] == 0
assert summaries["candidate"]["missingAfterYield"] == 0
print("PASS: native probe placement A/B and lifecycle contracts")
