#!/usr/bin/env python3
"""Execute actual reasoning/group-control actions with the unchanged drawer gate.

Button closures and helper bodies execute; view construction/hit testing, binding
delivery and AppModel storage are controlled. Date() alone maps to a manual clock
to test existing suppression/failsafe boundaries without wall-clock sleeps.
Solo/group labels exercise independent message identities through the shared
ReasoningCard action; they do not simulate different rendered chat layouts.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess

from check_drawer_close_driver_reuse import extract, method

ROOT = Path(__file__).resolve().parents[1]
BASE = "6a4c8efe4bc66593a13a7c1304b65f6d7af7d9bd"
OUT = ROOT / "work/verification/drawer-inline-control-5032"


def body(block):
    return block.split("{", 1)[1]


def make_source(root, composer):
    gate, gate_lines = extract(root, r"^@MainActor\nenum DrawerInlineActionTapGate\b")
    reasoning, reasoning_lines = extract(root, r"^private struct ReasoningCard: View\b")
    group, group_lines = extract(composer, r"^private struct GroupReplyControl: View\b")
    reasoning_button = extract(reasoning, r"^            Button\b")[0]
    group_buttons = [extract(group[match.start():], r"^ +Button\b")[0]
                     for match in re.finditer(r"^ +Button \{", group, re.M)]
    header = next(button for button in group_buttons if "isExpanded.toggle()" in button)
    random = next(button for button in group_buttons if "model.setGroupRandomFirst" in button)
    chip = next((button for button in group_buttons if "action()" in button), None)
    if chip is None:
        # The old code binds this exact callback directly to Button's action:
        # there is no original closure to extract, and no gate in that path.
        assert "Button(action: action) {" in group
        chip_body = "\n        action()\n    }"
    else:
        chip_body = body(chip)
    all_target = extract(group, r'^ +replyChip\(title: "全员"')[0]
    member_target = extract(group, r'^ +replyChip\(title: assistant.name')[0]
    rounds = [extract(group, r'^ +Button\("' + re.escape(title) + r'"\)')[0]
              for title in ["无", "1轮", "2轮", "3轮"]]
    # The wide and standard message layouts instantiate this same component.
    # There is no separate solo/group action implementation to extract.
    assert root.count("ReasoningCard(") == 2
    source = r'''
import Foundation
import SwiftUI
@MainActor enum GateClock { static var now = Date(timeIntervalSince1970: 1000) }
'''
    source += gate.replace("Date()", "GateClock.now") + "\n"
    source += r'''
struct Preferences { var fullyCollapseThinking = false; var autoCollapseThinking = true }
struct Message { let id: UUID; let conversationID: UUID; var isStreaming: Bool }
final class Segment {
    let id = UUID()
    var finishedAt: Date?
    var expanded = true
}
@MainActor final class Model {
    var preferences = Preferences()
    var reasoningSegments: [UUID: Segment] = [:]
    var reasoningEffects: [(UUID, UUID)] = []
    var targetEffects: [(UUID, String?)] = []
    var randomEffects: [(UUID, Bool)] = []
    var roundEffects: [(UUID, Int)] = []
    var targets: [UUID: String] = [:]
    var random: [UUID: Bool] = [:]
    var rounds: [UUID: Int] = [:]
    func toggleReasoningExpanded(messageID: UUID, segmentID: UUID) {
        reasoningEffects.append((messageID, segmentID))
        reasoningSegments[segmentID]!.expanded.toggle()
    }
    func selectGroupReplyTarget(_ target: String?, conversationID: UUID) {
        targetEffects.append((conversationID, target)); targets[conversationID] = target
    }
    func setGroupRandomFirst(_ enabled: Bool, conversationID: UUID) {
        randomEffects.append((conversationID, enabled)); random[conversationID] = enabled
    }
    func setGroupReplyRounds(_ count: Int, conversationID: UUID) {
        roundEffects.append((conversationID, count)); rounds[conversationID] = count
    }
}
enum ChatDisclosureMotion { static let animation = Animation.linear(duration: 0.18) }
@MainActor final class ReasoningFixture {
    let model: Model
    let message: Message
    let segment = Segment()
    var isLocallyCollapsed = false
    var callbacks: [(UUID, UUID, Bool)] = []
    init(_ model: Model, conversationID: UUID, mode: String) {
        self.model = model
        message = Message(id: UUID(), conversationID: conversationID, isStreaming: mode == "streaming")
        segment.finishedAt = mode == "streaming" ? nil : GateClock.now
        model.preferences.fullyCollapseThinking = mode == "local-done"
        model.reasoningSegments[segment.id] = segment
    }
    func onStreamingCollapseChanged(_ messageID: UUID, _ segmentID: UUID, _ collapsed: Bool) {
        callbacks.append((messageID, segmentID, collapsed))
    }
'''
    for name in ["isThinking", "isExpanded"]:
        source += extract(reasoning, r"^    private var " + name + r":")[0].replace("private var", "var", 1) + "\n"
    source += "    func press() {" + body(reasoning_button) + "\n}\n"
    source += r'''
struct Assistant { let id: UUID }
@MainActor final class GroupFixture {
    let model: Model
    let conversationID: UUID
    var isExpanded = false
    var randomFirst: Bool { model.random[conversationID] ?? false }
    let assistant = Assistant(id: UUID())
    init(_ model: Model, conversationID: UUID) { self.model = model; self.conversationID = conversationID }
'''
    source += "    func header() {" + body(header) + "\n"
    source += "    func randomButton() {" + body(random) + "\n"
    source += "    func chip(action: () -> Void) {" + chip_body + "\n"
    source += "    func allTarget() {" + body(all_target) + "\n"
    source += "    func memberTarget() {" + body(member_target) + "\n"
    for count, action in enumerate(rounds):
        source += f"    func rounds{count}() {{" + body(action) + "\n"
    if "private func setReplyRounds(" in group:
        source += method(group, "setReplyRounds")[0].replace("private func", "func", 1) + "\n"
    source += "}\n"
    return source + RUNNER, {"gate_lines": gate_lines, "reasoning_lines": reasoning_lines,
                             "group_lines": group_lines, "gate_sha256": hashlib.sha256(gate.encode()).hexdigest()}


RUNNER = r'''
struct Row: Codable {
    let kind: String
    let mode: String
    let phase: String
    let checks: [String: Bool]
}
@main struct Runner {
    @MainActor static func main() throws {
        var rows: [Row] = []
        func setup(_ phase: String) -> Bool {
            GateClock.now = Date(timeIntervalSince1970: 1000)
            DrawerInlineActionTapGate.reset()
            switch phase {
            case "held": DrawerInlineActionTapGate.beginDrawerDrag(); GateClock.now += 1
            case "release-protected", "release-expired":
                DrawerInlineActionTapGate.beginDrawerDrag(); GateClock.now += 1
                DrawerInlineActionTapGate.endDrawerDrag()
                GateClock.now += phase == "release-protected" ? 0.239 : 0.241
            case "scene-reset": DrawerInlineActionTapGate.beginDrawerDrag(); DrawerInlineActionTapGate.reset()
            default: break
            }
            return phase != "held" && phase != "release-protected"
        }
        let phases = ["normal", "held", "release-protected", "release-expired", "scene-reset"]
        for chat in ["solo", "group"] {
            for mode in ["streaming", "local-done", "persisted-done"] {
                for phase in phases {
                    let allowed = setup(phase)
                    let model = Model()
                    let f = ReasoningFixture(model, conversationID: UUID(), mode: mode)
                    f.press()
                    let firstLocal = f.isLocallyCollapsed
                    let firstPersisted = f.segment.expanded
                    f.press()
                    let expectedCount = allowed ? 2 : 0
                    var checks = [
                        "first_effect_follows_gate": mode == "persisted-done" ? firstPersisted == !allowed : firstLocal == allowed,
                        "repeated_button_has_no_stuck_state": !f.isLocallyCollapsed && f.segment.expanded,
                        "only_expected_owner_mutates": model.reasoningEffects.count == (mode == "persisted-done" ? expectedCount : 0) && f.callbacks.count == (mode == "streaming" ? expectedCount : 0),
                        "reasoning_target_identity": model.reasoningEffects.allSatisfy { $0.0 == f.message.id && $0.1 == f.segment.id } && f.callbacks.allSatisfy { $0.0 == f.message.id && $0.1 == f.segment.id }
                    ]
                    if allowed && mode == "streaming" { checks["streaming_callback_tracks_local_toggle"] = f.callbacks.map { $0.2 } == [true, false] }
                    rows.append(Row(kind: "reasoning-\(chat)", mode: mode, phase: phase, checks: checks))
                }
            }
        }
        for phase in phases {
            for action in ["header", "all", "member", "random", "round0", "round1", "round2", "round3"] {
                let allowed = setup(phase)
                let model = Model()
                let f = GroupFixture(model, conversationID: UUID())
                let other = UUID()
                model.rounds[other] = 99; model.random[other] = true; model.targets[other] = "unchanged"
                var checks: [String: Bool] = [:]
                switch action {
                case "header":
                    f.header(); checks["first_effect_follows_gate"] = f.isExpanded == allowed
                    f.header(); checks["repeat_is_two_normal_toggles"] = !f.isExpanded
                case "all", "member":
                    // Invoke the real shared chip button, with the exact callback
                    // extracted from each real call site; neither bypasses gate.
                    if action == "all" { f.chip { f.allTarget() }; f.chip { f.allTarget() } }
                    else { f.chip { f.memberTarget() }; f.chip { f.memberTarget() } }
                    checks["target_effect_count"] = model.targetEffects.count == (allowed ? 2 : 0)
                    checks["target_value_and_identity"] = model.targetEffects.allSatisfy { $0.0 == f.conversationID && $0.1 == (action == "all" ? nil : f.assistant.id.uuidString) }
                case "random":
                    f.randomButton(); f.randomButton()
                    checks["random_effect_count"] = model.randomEffects.count == (allowed ? 2 : 0)
                    checks["random_values_follow_current_state"] = model.randomEffects.map { $0.1 } == (allowed ? [true, false] : []) && model.randomEffects.allSatisfy { $0.0 == f.conversationID }
                default:
                    let value = Int(action.suffix(1))!
                    for _ in 0..<2 {
                        switch value { case 0: f.rounds0(); case 1: f.rounds1(); case 2: f.rounds2(); default: f.rounds3() }
                    }
                    checks["round_menu_effect_count"] = model.roundEffects.count == (allowed ? 2 : 0)
                    checks["round_menu_value_and_identity"] = model.roundEffects.allSatisfy { $0.0 == f.conversationID && $0.1 == value }
                }
                checks["other_conversation_unchanged"] = model.rounds[other] == 99 && model.random[other] == true && model.targets[other] == "unchanged"
                rows.append(Row(kind: "group-control", mode: action, phase: phase, checks: checks))
            }
        }
        // Preserve the existing four-second failsafe; this change only applies
        // the existing gate to previously unguarded effects.
        GateClock.now = Date(timeIntervalSince1970: 1000); DrawerInlineActionTapGate.reset()
        DrawerInlineActionTapGate.beginDrawerDrag(); GateClock.now += 3.999
        let heldBeforeFailsafe = !DrawerInlineActionTapGate.allowsAction
        GateClock.now += 0.002
        let existingFailsafeReleases = DrawerInlineActionTapGate.allowsAction
        DrawerInlineActionTapGate.endDrawerDrag()
        let releaseStillProtects = !DrawerInlineActionTapGate.allowsAction
        GateClock.now += 0.241
        rows.append(Row(kind: "gate-contract", mode: "existing-boundaries", phase: "clock", checks: [
            "before_four_seconds_blocks": heldBeforeFailsafe,
            "after_four_seconds_keeps_existing_failsafe": existingFailsafeReleases,
            "release_restarts_240ms_suppression": releaseStillProtects && DrawerInlineActionTapGate.allowsAction
        ]))
        print(String(decoding: try JSONEncoder().encode(rows), as: UTF8.self))
    }
}
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    baseline = {name: subprocess.check_output(["git", "show", f"{BASE}:Mocca/{name}.swift"], cwd=ROOT, text=True) for name in ["RootView", "ComposerView"]}
    current = {name: (ROOT / f"Mocca/{name}.swift").read_text() for name in baseline}
    gate_pattern = r"^@MainActor\nenum DrawerInlineActionTapGate\b"
    assert extract(baseline["RootView"], gate_pattern)[0] == extract(current["RootView"], gate_pattern)[0], "Existing gate/failsafe changed outside control protection scope"
    report = {"baseline": BASE, "limits": __doc__, "results": {}}
    for label, inputs in [("5031", baseline), ("candidate", current)]:
        source, provenance = make_source(inputs["RootView"], inputs["ComposerView"])
        provenance["source_sha256"] = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in inputs.items()}
        provenance["harness_sha256"] = hashlib.sha256(source.encode()).hexdigest()
        swift = OUT / f"{label}.swift"
        swift.write_text(source)
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(OUT / label)]
        (OUT / f"{label}-command.json").write_text(json.dumps(command, indent=2) + "\n")
        with (OUT / f"{label}-compile.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=log, check=True)
        result = subprocess.run([str(OUT / label)], capture_output=True, text=True, check=True)
        (OUT / f"{label}-run.log").write_text(result.stdout + result.stderr)
        rows = json.loads(result.stdout)
        failures = [{"kind": row["kind"], "mode": row["mode"], "phase": row["phase"], "checks": [key for key, value in row["checks"].items() if not value]} for row in rows if not all(row["checks"].values())]
        report["results"][label] = {"provenance": provenance, "rows": rows, "failures": failures}
        (OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        expected = {(row["kind"], row["mode"], row["phase"]) for row in rows if row["phase"] in ["held", "release-protected"]} if label == "5031" else set()
        assert {(row["kind"], row["mode"], row["phase"]) for row in failures} == expected, failures
        print(json.dumps({"source": label, "scenarios": len(rows), "assertions": sum(len(row["checks"]) for row in rows), "expected_failures": len(failures), "matched_expectation": True}), flush=True)
    report["passed"] = True
    (OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
