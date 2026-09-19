#!/usr/bin/env python3
"""Run extracted gate declarations with property-write-recording receivers.

Checks duplicate setters, drift repair and lifecycle state equivalence against
5016. UIKit, SwiftUI observation, scroll geometry and performance are not run.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from check_drawer_close_driver_reuse import extract, replace_probe_regions, strip_viewport_freeze_hooks

ROOT = Path(__file__).resolve().parents[1]
BASE = "8fd39125598c32a5b01d1d491c2030d84fa3a89b"
OUT = ROOT / "work/verification/drawer-scroll-top-idempotence"
PATTERN = r"^@MainActor\nprivate enum DrawerNativeScrollGate\b"

SWIFT = r'''
import Foundation
@MainActor final class ChatScrollViewRegistration {}
@MainActor final class UIScrollView: NSObject {
    var enabledWrites = 0
    var topWrites = 0
    var isScrollEnabled = true { didSet { enabledWrites += 1 } }
    var scrollsToTop = true { didSet { topWrites += 1 } }
    func clearWrites() { enabledWrites = 0; topWrites = 0 }
}
/*GATE*/
struct Result: Codable {
    let presented: Bool
    let gesture: Bool
    let checks: [String: Bool]
    let repeatedRegistrationTopWrites: Int
    let repeatedResetTopWrites: Int
    let driftRepairTopWrites: Int
}
@main struct Runner {
    @MainActor static func main() throws {
        var results: [Result] = []
        for presented in [false, true] {
            for gesture in [false, true] {
                DrawerNativeScrollGate.reset()
                let first = UIScrollView(), second = UIScrollView()
                let firstOwner = ChatScrollViewRegistration(), secondOwner = ChatScrollViewRegistration()
                let expected = !(presented || gesture)
                DrawerNativeScrollGate.update(isDrawerPresented: presented, isDrawerGestureActive: gesture)
                DrawerNativeScrollGate.register(first, role: .chat, owner: firstOwner)
                DrawerNativeScrollGate.register(second, role: .chat, owner: secondOwner)
                var checks = ["late_registration_matches_state": first.isScrollEnabled == expected && first.scrollsToTop == expected && second.isScrollEnabled == expected && second.scrollsToTop == expected]
                first.clearWrites()
                for _ in 0..<100 { DrawerNativeScrollGate.register(first, role: .chat, owner: firstOwner) }
                let repeated = first.topWrites
                checks["repeat_keeps_state"] = first.isScrollEnabled == expected && first.scrollsToTop == expected
                checks["repeat_keeps_enabled_setter_idle"] = first.enabledWrites == 0
                first.isScrollEnabled = !expected; first.scrollsToTop = !expected
                first.clearWrites()
                DrawerNativeScrollGate.register(first, role: .chat, owner: firstOwner)
                let repair = first.topWrites
                checks["registration_repairs_external_drift"] = first.isScrollEnabled == expected && first.scrollsToTop == expected && first.enabledWrites == 1 && repair == 1
                DrawerNativeScrollGate.unregister(first, role: .chat, owner: firstOwner)
                checks["unregister_restores_receiver"] = first.isScrollEnabled && first.scrollsToTop
                checks["other_receiver_keeps_state"] = second.isScrollEnabled == expected && second.scrollsToTop == expected
                first.clearWrites()
                DrawerNativeScrollGate.update(isDrawerPresented: !presented, isDrawerGestureActive: !gesture)
                let nextExpected = !(!presented || !gesture)
                checks["transition_reaches_registered_receiver"] = second.isScrollEnabled == nextExpected && second.scrollsToTop == nextExpected
                checks["unregistered_receiver_is_not_written"] = first.enabledWrites == 0 && first.topWrites == 0
                DrawerNativeScrollGate.reset()
                checks["reset_restores_registered_receiver"] = second.isScrollEnabled && second.scrollsToTop
                second.clearWrites()
                for _ in 0..<100 { DrawerNativeScrollGate.reset() }
                let resetWrites = second.topWrites
                checks["repeat_reset_keeps_state"] = second.isScrollEnabled && second.scrollsToTop && second.enabledWrites == 0
                DrawerNativeScrollGate.unregister(second, role: .chat, owner: secondOwner)
                results.append(Result(presented: presented, gesture: gesture, checks: checks,
                    repeatedRegistrationTopWrites: repeated, repeatedResetTopWrites: resetWrites, driftRepairTopWrites: repair))
            }
        }
        print(String(decoding: try JSONEncoder().encode(results), as: UTF8.self))
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    old = subprocess.check_output(["git", "show", f"{BASE}:Mocca/RootView.swift"], cwd=ROOT, text=True)
    new = (ROOT / "Mocca/RootView.swift").read_text()
    before, _ = extract(old, PATTERN)
    after, _ = extract(new, PATTERN)
    assert strip_viewport_freeze_hooks(replace_probe_regions(old, new).replace(before, after, 1)) == strip_viewport_freeze_hooks(new), "Changes outside the native gate/probe"
    original = "        scrollView.scrollsToTop = !disabled"
    replacement = "        if scrollView.scrollsToTop == disabled {\n            scrollView.scrollsToTop = !disabled\n        }"
    apply_pattern = r"^    private static func applyCurrentState\(to scrollView: UIScrollView"
    old_apply, _ = extract(before, apply_pattern)
    new_apply, _ = extract(after, apply_pattern)
    assert old_apply.replace(original, replacement, 1) == new_apply, "State application exceeds the same-value setter guard"
    current_version = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", (ROOT / "Mocca.xcodeproj/project.pbxproj").read_text()).group(1)
    cases, sources = [], {}
    for version, root in (("5016", old), (current_version, new)):
        gate, lines = extract(root, PATTERN)
        source = SWIFT.replace("/*GATE*/", gate)
        if "owner: ChatScrollViewRegistration" not in gate:
            source = source.replace(", owner: firstOwner", "").replace(", owner: secondOwner", "")
        (OUT / f"gate-{version}.swift").write_text(source)
        with tempfile.TemporaryDirectory(prefix="drawer-top-contract-") as tmp:
            binary = Path(tmp) / "gate"
            build = subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", str(Path(tmp) / "ModuleCache"), str(OUT / f"gate-{version}.swift"), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            (OUT / f"gate-{version}-build.log").write_text(build.stdout + build.stderr)
            if build.returncode:
                raise SystemExit(build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            run.check_returncode()
        for case in json.loads(run.stdout):
            case["version"] = version
            assert all(case["checks"].values()), case
            assert case["repeatedRegistrationTopWrites"] == (100 if version == "5016" else 0), case
            assert case["repeatedResetTopWrites"] == (100 if version == "5016" else 0), case
            assert case["driftRepairTopWrites"] == 1, case
            cases.append(case)
        sources[version] = {"root_sha256": hashlib.sha256(root.encode()).hexdigest(), "gate_lines": lines, "harness_sha256": hashlib.sha256(source.encode()).hexdigest()}
    report = {"baseline": BASE, "sources": sources, "cases": cases, "pass": True,
              "limits": ["Receivers record property setters; real UIKit setter side effects are not measured.", "100 calls are a controlled test workload, not a measured count during one drawer gesture.", "Dummy owner identities exercise gate state only; overlapping probe lifecycle is checked separately by check_chat_scroll_probe_ownership.py.", "No iPhone performance or interaction acceptance is claimed."]}
    (OUT / "gate-contract.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"pass": True, "cases": len(cases), "unchanged_state_checks": sum(len(c["checks"]) for c in cases), "repeat_top_writes_before_after": [100, 0], "drift_repair_writes_before_after": [1, 1]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
