#!/usr/bin/env python3
"""Execute the 5033 lease/model with real Swift Tasks and controlled UIKit.

The deterministic runner changes only Task.sleep to an injectable suspension.
Cancelled tasks can deliberately resume successfully, exercising the real
Task.isCancelled guard. A second runner retains the original sleep unchanged.
SwiftUI lifecycle delivery, animation, display hardware and haptics are doubles;
this verifies ownership and finite requests, never physical-device frame rate.
"""
import hashlib
import json
from pathlib import Path
import subprocess

from check_drawer_close_driver_reuse import extract, method

ROOT = Path(__file__).resolve().parents[1]
BASE = "e99f9d42c516111705e0aebdd1371d493efba125"
SOURCE = ROOT / "Mocca/BottomToolsSheet.swift"
OUT = ROOT / "work/verification/bottom-tools-transition-refresh-5033"


def body(block):
    return block[block.index("{") + 1:-1]


def declarations(source):
    target = extract(source, r"^@MainActor\nprivate final class BottomToolsRefreshDisplayLinkTarget\b")[0]
    lease, lease_lines = extract(source, r"^@MainActor\nprivate final class BottomToolsTransitionRefreshLease\b")
    model, model_lines = extract(source, r"^@MainActor\n@Observable\nfinal class BottomToolsModel\b")
    prefix = source[source.index("enum BottomToolAction"):source.index("@MainActor")]
    sheet = extract(source, r"^struct BottomToolsSheet: View\b")[0]
    eligibility, eligibility_lines = extract(sheet, r"^    private var allowsTransitionRefresh:")
    action = method(sheet, "handleAction")[0]
    appear = extract(sheet, r"^        \.onAppear\b")[0]
    disappear = extract(sheet, r"^        \.onDisappear\b")[0]
    change = extract(sheet, r"^        \.onChange\(of: allowsTransitionRefresh\)")[0]
    constants = "\n".join(line for line in sheet.splitlines() if "private let " in line and "Detent =" in line)
    fixture = r'''
@MainActor final class SheetFixture {
    let model = BottomToolsModel()
    let appModel = AppDouble()
    var scenePhase = ScenePhase.active
    var isToolsSheetVisible = false
    var isAttachmentHandoffActive = false
    var isMCPSelectionPresented = false
    var isSearchSettingsPresented = false
    var isWorldBookSettingsPresented = false
    var isContextManagementConfirmationPresented = false
    var selectedDetent = PresentationDetent.height(355)
    var actionObservations: [(BottomToolAction, Bool, Bool)] = []
    func onAction(_ action: BottomToolAction) {
        actionObservations.append((action, CADisplayLink.active.isEmpty, model.lastAction == action))
    }
'''
    fixture += constants + "\n" + eligibility.replace("private var", "var", 1) + "\n"
    fixture += method(sheet, "preferredDetent")[0].replace("private func", "func", 1) + "\n"
    fixture += action.replace("private func", "func", 1) + "\n"
    fixture += "func appear() {" + body(appear) + "}\n"
    fixture += "func disappear() {" + body(disappear) + "}\n"
    fixture += "func syncEligibility() { let allowed = allowsTransitionRefresh\n" + body(change).split(" in", 1)[1] + "}\n}\n"
    return prefix + target + "\n" + lease + "\n" + model + "\n" + fixture, {
        "lease_lines": lease_lines, "model_lines": model_lines,
        "lease_sha256": hashlib.sha256(lease.encode()).hexdigest(),
        "model_sha256": hashlib.sha256(model.encode()).hexdigest(),
        "eligibility_sheet_relative_lines": eligibility_lines,
        "extracted": ["complete display-link target", "complete lease", "complete observable model", "eligibility expression", "onAppear", "onDisappear", "eligibility onChange", "handleAction", "preferredDetent"],
    }


def preservation(source):
    baseline = subprocess.check_output(["git", "show", BASE + ":Mocca/BottomToolsSheet.swift"], cwd=ROOT, text=True)
    restored = source
    start = restored.index("@MainActor\nprivate final class BottomToolsRefreshDisplayLinkTarget")
    end = restored.index("@MainActor\n@Observable\nfinal class BottomToolsModel", start)
    restored = restored[:start] + restored[end:]
    for name in ["setTransitionRefreshEnabled", "stopTransitionRefresh"]:
        block = method(restored, name)[0]
        restored = restored.replace(block + "\n\n", "", 1)
    eligibility = extract(restored, r"^    private var allowsTransitionRefresh:")[0]
    restored = restored.replace(eligibility + "\n\n", "", 1)
    changed = extract(restored, r"^        \.onChange\(of: allowsTransitionRefresh\)")[0]
    restored = restored.replace(changed + "\n", "", 1)
    additions = [
        "    @ObservationIgnored private let transitionRefresh = BottomToolsTransitionRefreshLease()\n",
        "        transitionRefresh.setEnabled(false)\n",
        "        if self.route != route { transitionRefresh.begin() }\n",
        "        if route != .root { transitionRefresh.begin() }\n",
        "    @Environment(\\.scenePhase) private var scenePhase\n",
        "    @State private var isToolsSheetVisible = false\n",
        "            isToolsSheetVisible = true\n",
        "            model.setTransitionRefreshEnabled(allowsTransitionRefresh)\n",
        "            isToolsSheetVisible = false\n",
        "            model.setTransitionRefreshEnabled(false)\n",
        "        // Stop before presentation callbacks: attachment handoff state is\n",
        "        // published on the next turn, after a native picker can already open.\n",
        "        model.stopTransitionRefresh()\n",
    ]
    for addition in additions:
        assert restored.count(addition) == 1, repr(addition)
        restored = restored.replace(addition, "", 1)
    assert restored == baseline, "5032 differs beyond the explicitly enumerated refresh additions"
    return {"base": BASE, "baseline_sha256": hashlib.sha256(baseline.encode()).hexdigest(),
            "whole_file_equal_after_exact_refresh_removal": True,
            "covers": ["navigationPage and page body", "all detent values and routing", "0.30/0.28/0.26/0.24 animation parameters", "business action contents except pre-callback stop", "all downstream page bodies and callbacks"]}


PRELUDE = r'''
import Foundation
import Observation

struct AssistantProfile: Hashable { let id: UUID; let name: String
    static func makeDefault() -> Self { Self(id: UUID(), name: "fixture") }
}
struct CAFrameRateRange { let minimum: Float; let maximum: Float; let preferred: Float }
@MainActor enum Log { static var events: [String] = [] }
@MainActor final class UIScreen { static let main = UIScreen(); var maximumFramesPerSecond = 120 }
@MainActor final class CADisplayLink: NSObject {
    static var links: [CADisplayLink] = []
    static var active: [CADisplayLink] { links.filter { !$0.invalidated } }
    var target: NSObject?
    let selector: Selector
    var invalidated = false
    var invalidations = 0
    var addCount = 0
    var commonMain = false
    var preferredFrameRateRange = CAFrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    init(target: NSObject, selector: Selector) {
        self.target = target; self.selector = selector
        super.init(); Self.links.append(self)
    }
    func add(to loop: RunLoop, forMode mode: RunLoop.Mode) {
        addCount += 1; commonMain = loop == .main && mode == .common; Log.events.append("link.add")
    }
    func invalidate() { invalidations += 1; invalidated = true; target = nil; Log.events.append("link.invalidate") }
    func fire() { if !invalidated { _ = target?.perform(selector, with: self) } }
}
struct Animation { let duration: Double; static func easeInOut(duration: Double) -> Self { Self(duration: duration) } }
@MainActor func withAnimation(_ animation: Animation, _ action: () -> Void) {
    Log.events.append("animation.\(animation.duration)"); action()
}
@MainActor struct UIImpactFeedbackGenerator {
    enum Style { case light }; init(style: Style) {}
    func impactOccurred() { Log.events.append("haptic") }
}
enum ScenePhase { case active, inactive, background }
enum PresentationDetent: Equatable { case height(Double), fraction(Double) }
@MainActor final class AppDouble {
    var isBottomToolsPresented = true
    var cancellationCount = 0
    func cancelContextManagementConfirmation() { cancellationCount += 1 }
}
struct Row: Codable { let scenario: String; let checks: [String: Bool] }
@MainActor enum Results {
    static var rows: [Row] = []
    static func add(_ scenario: String, _ checks: [String: Bool]) { rows.append(Row(scenario: scenario, checks: checks)) }
    static func write() throws { print(String(data: try JSONEncoder().encode(rows), encoding: .utf8)!) }
}
'''


MANUAL_SLEEP = r'''
@MainActor enum ManualSleep {
    struct Waiter { let duration: Duration; let continuation: CheckedContinuation<Void, Error> }
    static var nextID = 0
    static var waiters: [Int: Waiter] = [:]
    static func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            nextID += 1; waiters[nextID] = Waiter(duration: duration, continuation: continuation)
        }
    }
    static func registered(after old: Int) async -> Int {
        for _ in 0..<10000 {
            if nextID > old { return nextID }
            await Task.yield()
        }
        fatalError("Lease task never reached the injected sleep")
    }
    static func resume(_ id: Int, throwing: Bool = false) async {
        guard let waiter = waiters.removeValue(forKey: id) else { fatalError("No waiter \(id)") }
        if throwing { waiter.continuation.resume(throwing: CancellationError()) }
        else { waiter.continuation.resume() }
        for _ in 0..<30 { await Task.yield() }
    }
    static func drain() async {
        for id in waiters.keys.sorted() { await resume(id, throwing: true) }
        Log.events = []
    }
}
'''


DETERMINISTIC = r'''
@main struct Runner {
    @MainActor static func main() async throws {
        // Screen eligibility, no-op navigation, and request order use real model methods.
        for fps in [60, 120] {
            UIScreen.main.maximumFramesPerSecond = fps
            let model = BottomToolsModel(); let oldCount = CADisplayLink.links.count
            model.open(.more)
            Results.add("disabled-\(fps)", ["route_still_changes": model.route == .more, "no_link": CADisplayLink.links.count == oldCount])
            model.setTransitionRefreshEnabled(true); model.open(.more)
            Results.add("same-route-\(fps)", ["no_link": CADisplayLink.links.count == oldCount])
            Log.events = []; let token = ManualSleep.nextID; model.open(.instruction)
            if fps == 120 {
                let id = await ManualSleep.registered(after: token); let link = CADisplayLink.links.last!
                Results.add("enabled-120", ["one_link": CADisplayLink.links.count == oldCount + 1,
                    "common_main_once": link.addCount == 1 && link.commonMain,
                    "request_80_120_120": link.preferredFrameRateRange.minimum == 80 && link.preferredFrameRateRange.maximum == 120 && link.preferredFrameRateRange.preferred == 120,
                    "before_animation": Log.events == ["haptic", "link.add", "animation.0.3"],
                    "finite_450_ms": ManualSleep.waiters[id]!.duration == .milliseconds(450)])
                let before = Log.events; link.fire(); link.fire()
                Results.add("empty-display-callback", ["no_effects": Log.events == before && model.route == .instruction])
                await ManualSleep.resume(id)
                Results.add("deadline", ["invalidated_once": link.invalidations == 1, "target_released": link.target == nil])
            } else { Results.add("enabled-60", ["no_link": CADisplayLink.links.count == oldCount, "route_changes": model.route == .instruction]) }
            model.stopTransitionRefresh(); await ManualSleep.drain()
        }
        let routes: [BottomToolsRoute] = [.root, .more, .instruction, .worldBook, .groupChat, .contextManagement]
        let destinations: [BottomToolsRoute] = [.root, .root, .more, .root, .root, .more]
        for (route, destination) in zip(routes, destinations) {
            let model = BottomToolsModel(); model.route = route; model.setTransitionRefreshEnabled(true)
            let count = CADisplayLink.links.count; let token = ManualSleep.nextID
            Log.events = []; model.back()
            if route != .root { _ = await ManualSleep.registered(after: token) }
            Results.add("back-\(route)", ["destination": model.route == destination,
                "only_effective_route_requests": CADisplayLink.links.count == count + (route == .root ? 0 : 1),
                "unchanged_animation": Log.events.last == "animation.0.28",
                "request_precedes_animation": route == .root || Log.events == ["haptic", "link.add", "animation.0.28"]])
            model.stopTransitionRefresh(); await ManualSleep.drain()
        }
        do {
            let model = BottomToolsModel(); model.setTransitionRefreshEnabled(true)
            var token = ManualSleep.nextID; model.open(.more); let old = await ManualSleep.registered(after: token)
            let link = CADisplayLink.links.last!; let count = CADisplayLink.links.count
            token = ManualSleep.nextID; model.open(.instruction); let middle = await ManualSleep.registered(after: token)
            token = ManualSleep.nextID; model.back(); let current = await ManualSleep.registered(after: token)
            await ManualSleep.resume(old) // Deliberately success, despite genuine Task cancellation.
            await ManualSleep.resume(middle, throwing: true)
            Results.add("rapid-reversal-old-deadlines", ["same_link_reused": CADisplayLink.links.count == count && link.addCount == 1,
                "old_success_and_throw_cannot_release": !link.invalidated, "back_route": model.route == .more])
            await ManualSleep.resume(current)
            Results.add("rapid-reversal-new-deadline", ["releases_once": link.invalidations == 1])
            token = ManualSleep.nextID; model.open(.contextManagement); let next = await ManualSleep.registered(after: token)
            Results.add("after-expiry-new-link", ["new_identity": CADisplayLink.links.last! !== link, "new_active": !CADisplayLink.links.last!.invalidated])
            model.stopTransitionRefresh(); await ManualSleep.resume(next)
        }
        do {
            let model = BottomToolsModel(); model.setTransitionRefreshEnabled(true)
            var token = ManualSleep.nextID; model.open(.more); let old = await ManualSleep.registered(after: token)
            let oldLink = CADisplayLink.links.last!; model.stopTransitionRefresh(); model.stopTransitionRefresh()
            token = ManualSleep.nextID; model.open(.instruction); let current = await ManualSleep.registered(after: token)
            let currentLink = CADisplayLink.links.last!; await ManualSleep.resume(old)
            Results.add("stop-restart-old-callback", ["old_invalidated_once": oldLink.invalidations == 1,
                "new_identity_survives_old_task": currentLink !== oldLink && !currentLink.invalidated])
            model.isEditingGroupChat = true; model.trigger(.camera)
            model.reset(); let resetRoute = model.route; await ManualSleep.resume(current)
            let count = CADisplayLink.links.count; model.open(.more)
            Results.add("reset", ["release_once": currentLink.invalidations == 1,
                "reset_business_state": resetRoute == .root && !model.isEditingGroupChat && model.lastAction == nil,
                "disabled_until_lifecycle": CADisplayLink.links.count == count])
        }
        do {
            var a: BottomToolsModel? = BottomToolsModel(); let b = BottomToolsModel()
            a!.setTransitionRefreshEnabled(true); b.setTransitionRefreshEnabled(true)
            var token = ManualSleep.nextID; a!.open(.more); let aid = await ManualSleep.registered(after: token)
            let alink = CADisplayLink.links.last!; weak var weakA = a
            token = ManualSleep.nextID; b.open(.more); let bid = await ManualSleep.registered(after: token)
            let blink = CADisplayLink.links.last!; a = nil
            Results.add("owner-disappears", ["owner_not_retained": weakA == nil, "independent_links": alink !== blink])
            await ManualSleep.resume(aid)
            Results.add("orphan-bounded-release", ["orphan_released": alink.invalidations == 1,
                "other_owner_untouched": !blink.invalidated])
            b.stopTransitionRefresh(); await ManualSleep.resume(bid)
            Results.add("second-owner-stop", ["one_release": blink.invalidations == 1])
        }
        // Explicitly deliver the extracted lifecycle closures; this is not a UI delivery test.
        let blockers: [(String, (SheetFixture) -> Void)] = [
            ("invisible", { $0.isToolsSheetVisible = false }),
            ("not-presented", { $0.appModel.isBottomToolsPresented = false }),
            ("inactive", { $0.scenePhase = .inactive }), ("background", { $0.scenePhase = .background }),
            ("attachment", { $0.isAttachmentHandoffActive = true }), ("mcp", { $0.isMCPSelectionPresented = true }),
            ("search", { $0.isSearchSettingsPresented = true }), ("world-book", { $0.isWorldBookSettingsPresented = true }),
            ("confirmation", { $0.isContextManagementConfirmationPresented = true })]
        for (name, block) in blockers {
            let f = SheetFixture(); f.appear(); let token = ManualSleep.nextID
            f.model.open(.more); let id = await ManualSleep.registered(after: token); let link = CADisplayLink.links.last!
            block(f); f.syncEligibility(); let count = CADisplayLink.links.count; f.model.open(.instruction)
            await ManualSleep.resume(id)
            Results.add("eligibility-\(name)", ["false": !f.allowsTransitionRefresh, "immediate_stop": link.invalidations == 1,
                "no_new_request": CADisplayLink.links.count == count])
        }
        do {
            let f = SheetFixture(); f.appear(); var token = ManualSleep.nextID
            f.model.open(.more); let first = await ManualSleep.registered(after: token); let link = CADisplayLink.links.last!
            f.disappear(); await ManualSleep.resume(first)
            Results.add("disappear", ["disabled": !f.allowsTransitionRefresh, "stop": link.invalidations == 1,
                "business_cancel_preserved": f.appModel.cancellationCount == 1])
            let count = CADisplayLink.links.count; f.appear()
            Results.add("reappear-does-not-request", ["eligible": f.allowsTransitionRefresh,
                "correct_detent": f.selectedDetent == .height(320), "idle_no_link": CADisplayLink.links.count == count])
            token = ManualSleep.nextID; f.model.open(.contextManagement); let second = await ManualSleep.registered(after: token)
            Results.add("reappear-next-navigation", ["new_link": CADisplayLink.links.count == count + 1])
            f.disappear(); await ManualSleep.resume(second)
        }
        let actions: [BottomToolAction] = [.camera, .photos, .uploadFile, .saveGroupChat([UUID()], editing: false),
            .saveGroupChat([UUID()], editing: true), .compressContext, .clearContext]
        for action in actions {
            let f = SheetFixture(); f.appear(); let token = ManualSleep.nextID
            f.model.open(.more); let id = await ManualSleep.registered(after: token); let link = CADisplayLink.links.last!
            f.handleAction(action); await ManualSleep.resume(id)
            Results.add("action-\(action)", ["stops_before_business_callback": f.actionObservations.count == 1 && f.actionObservations[0].1,
                "trigger_precedes_callback": f.actionObservations[0].2, "identity_preserved": f.actionObservations[0].0 == action,
                "old_task_cannot_repeat_release": link.invalidations == 1])
        }
        Results.add("no-active-link-at-end", ["all_released": CADisplayLink.active.isEmpty, "no_pending_sleep": ManualSleep.waiters.isEmpty])
        try Results.write()
    }
}
'''


REAL_SLEEP = r'''
@main struct Runner {
    @MainActor static func main() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        var owner: BottomToolsModel? = BottomToolsModel()
        owner!.setTransitionRefreshEnabled(true); owner!.open(.more)
        let orphan = CADisplayLink.links.last!; weak var weakOwner = owner; owner = nil
        let model = BottomToolsModel(); model.setTransitionRefreshEnabled(true); model.open(.more)
        let link = CADisplayLink.links.last!
        try await Task.sleep(for: .milliseconds(250))
        Results.add("wall-clock-before-expiry", ["both_active": !orphan.invalidated && !link.invalidated,
            "owner_gone": weakOwner == nil])
        model.open(.instruction)
        try await Task.sleep(for: .milliseconds(300))
        Results.add("wall-clock-old-deadline", ["orphan_released": orphan.invalidations == 1,
            "renewed_link_active": !link.invalidated])
        try await Task.sleep(for: .milliseconds(300))
        Results.add("wall-clock-new-deadline", ["renewed_link_released": link.invalidations == 1,
            "target_released": link.target == nil, "finite_host_completion": ProcessInfo.processInfo.systemUptime - start < 3])
        try Results.write()
    }
}
'''


def run(name, source, expected_failure=None):
    path = OUT / (name + ".swift")
    path.write_text(source)
    executable = OUT / name
    command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-O", "-g", str(path), "-o", str(executable)]
    compile_result = subprocess.run(command, text=True, capture_output=True)
    (OUT / (name + "-compile.log")).write_text(compile_result.stdout + compile_result.stderr)
    assert compile_result.returncode == 0, compile_result.stderr
    result = subprocess.run([str(executable)], text=True, capture_output=True, timeout=20)
    (OUT / (name + "-run.log")).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stderr
    rows = json.loads(result.stdout)
    (OUT / (name + "-results.json")).write_text(json.dumps(rows, indent=2) + "\n")
    failures = [(row["scenario"], key) for row in rows for key, passed in row["checks"].items() if not passed]
    if expected_failure:
        assert expected_failure in failures, ("Negative control did not expose the intended defect", failures)
        return {"expected_failure_observed": list(expected_failure), "all_failures": failures}
    assert not failures, failures
    return {"scenarios": len(rows), "assertions": sum(len(row["checks"]) for row in rows), "passed": True}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    original = SOURCE.read_text()
    extracted, metadata = declarations(original)
    assert extracted.count("Task.sleep(for: .milliseconds(450))") == 1
    metadata["preservation"] = preservation(original)
    metadata["source_sha256"] = hashlib.sha256(original.encode()).hexdigest()
    controlled = PRELUDE + MANUAL_SLEEP + extracted.replace("Task.sleep(for: .milliseconds(450))", "ManualSleep.sleep(for: .milliseconds(450))") + DETERMINISTIC
    metadata["deterministic"] = run("deterministic", controlled)
    metadata["original_sleep"] = run("original-sleep", PRELUDE + extracted + REAL_SLEEP)
    # In-memory test-source mutation only; the product is never changed. If a
    # cancelled wait reports success, the real cancellation guard is essential.
    guard = "            guard !Task.isCancelled else { return }\n"
    assert controlled.count(guard) == 1
    metadata["negative_control"] = run("missing-cancellation-guard", controlled.replace(guard, "", 1),
        expected_failure=("rapid-reversal-old-deadlines", "old_success_and_throw_cannot_release"))
    metadata["limitations"] = ["CADisplayLink, UIScreen, haptics and animation are macOS doubles; not a device FPS test.",
        "Extracted lifecycle methods execute through explicit calls; actual SwiftUI delivery/order and presentation covering require UI/device validation.",
        "Deterministic sleep resumes explicitly; genuine Task cancellation and Task.isCancelled execute unchanged.",
        "Original-sleep runtime retains the complete lease/model unchanged and observes host deadlines with broad timing margins."]
    (OUT / "result.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
