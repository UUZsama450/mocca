"""Exercise the extracted production row background in a hidden macOS SwiftUI host.

This checks notification delivery and NSView identity, not iOS entry/FPS. The
fixture deliberately removes the tail from the aggregate preference receiver.
No simulator, physical device, or application data is used.
"""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "work/verification/entry-reuse-row-measurement"
OUT.mkdir(parents=True, exist_ok=True)


def block(source, token):
    start = source.index(token)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


source = (ROOT / "Mocca/RootView.swift").read_text()
row = block(source, "private func conversationMessageRow(")
modifiers = row[row.index("        .id(message.id)"):].rsplit("}", 1)[0]
types = "\n".join(block(source, "private struct " + name + ":") for name in [
    "ConversationPositionRequestKey", "ConversationBottomAnchorID",
    "ConversationMessageFrameSnapshot", "MessageFramePreferenceKey",
])
measure = block(source, "private func measuredEntryTailAnchorID(")
# Instrument only the fixture's copy; keep production predicates unchanged.
measure = measure.replace("        guard frame.minX", "        Metrics.measureCalls += 1\n        guard frame.minX")
ack = block(source, "private func acknowledgeMeasuredEntryTail(")

template = r'''
import AppKit
import SwiftUI
import Observation

// TYPES

@MainActor private enum Metrics {
    static var births: [UUID: Int] = [:]
    static var deaths: [UUID: Int] = [:]
    static var aggregate: [UUID: CGRect] = [:]
    static var ackEvents = 0
    static var measureCalls = 0
}
@MainActor private enum VersionFlashTrace {
    static func record(_ text: String) { Metrics.ackEvents += 1 }
}
private struct Message: Identifiable { let id: UUID }
@MainActor @Observable private final class Fixture {
    let messages = (0..<8).map { _ in Message(id: UUID()) }
    let conversationID = UUID()
    var request = 1
    var waiting = true
    var enabled = false
    var tailHeight: CGFloat = 80
    var nativeReady: ConversationBottomAnchorID?
    var acknowledged: ConversationBottomAnchorID?
    var anchor: ConversationBottomAnchorID {
        .init(positionRequest: .init(conversationID: conversationID, request: request),
              messageIDs: messages.map(\.id))
    }
}
@MainActor private final class RowNSView: NSView { var messageID = UUID() }
@MainActor private struct Row: NSViewRepresentable {
    let messageID: UUID
    func makeNSView(context: Context) -> RowNSView {
        Metrics.births[messageID, default: 0] += 1
        let view = RowNSView()
        view.messageID = messageID
        return view
    }
    func updateNSView(_ view: RowNSView, context: Context) {}
    static func dismantleNSView(_ view: RowNSView, coordinator: ()) {
        Metrics.deaths[view.messageID, default: 0] += 1
    }
}
@MainActor private struct Host: View {
    let fixture: Fixture
    var currentConversationBottomAnchorID: ConversationBottomAnchorID { fixture.anchor }
    var isBoundedConversationEntry: Bool { fixture.waiting }
    var nativeConversationContentReadyAnchorID: ConversationBottomAnchorID? { fixture.nativeReady }
    var concreteEntryTailAnchorID: ConversationBottomAnchorID? {
        get { fixture.acknowledged }
        nonmutating set { fixture.acknowledged = newValue }
    }
    var activeCodeLayoutRequestID: UUID? { nil }
    var body: some View {
        VStack(spacing: 8) {
            ForEach(fixture.messages) { message in
                row(message, bottomAnchorID: fixture.anchor)
            }
        }
        .coordinateSpace(name: "chat-scroll")
        .transformPreference(MessageFramePreferenceKey.self) { snapshot in
            snapshot?.frames.removeValue(forKey: fixture.messages.last!.id)
        }
        .onPreferenceChange(MessageFramePreferenceKey.self) { snapshot in
            Metrics.aggregate = snapshot?.frames ?? [:]
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func row(_ message: Message, bottomAnchorID: ConversationBottomAnchorID) -> some View {
        let entryTailAnchorID: ConversationBottomAnchorID? =
            fixture.enabled && message.id == bottomAnchorID.messageIDs.last
                && isBoundedConversationEntry
                && nativeConversationContentReadyAnchorID != bottomAnchorID
                ? bottomAnchorID : nil
        return Row(messageID: message.id)
            .frame(height: message.id == bottomAnchorID.messageIDs.last ? fixture.tailHeight : 60)
        // MODIFIERS
    }
    // MEASURE
    // ACK

    func validate(_ frame: CGRect) -> ConversationBottomAnchorID? {
        measuredEntryTailAnchorID(fixture.anchor, frame: frame)
    }
    func deliver(_ anchor: ConversationBottomAnchorID?) {
        acknowledgeMeasuredEntryTail(anchor)
    }
}

@main private struct Checks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let fixture = Fixture()
        let root = Host(fixture: fixture)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            let deadline = Date().addingTimeInterval(0.16)
            repeat {
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            } while Date() < deadline
        }
        var results: [String: Bool] = [:]
        func check(_ label: String, _ value: Bool) { results[label] = value }
        settle()
        let tail = fixture.messages.last!.id
        let initialBirths = Metrics.births
        check("hidden host creates all eight row views", initialBirths.count == 8 && initialBirths.values.allSatisfy { $0 == 1 })
        check("fault injection omits only tail", Metrics.aggregate.count == 7 && Metrics.aggregate[tail] == nil)
        check("control without local notification cannot acknowledge", fixture.acknowledged == nil && Metrics.ackEvents == 0)
        check("inactive rows never call measurement validator", Metrics.measureCalls == 0)

        fixture.enabled = true
        settle()
        check("local notification survives missing aggregate", fixture.acknowledged == fixture.anchor)
        check("acknowledges once per request", Metrics.ackEvents == 1)
        check("mounting observer preserves row instances", Metrics.births == initialBirths && Metrics.deaths.isEmpty)
        check("aggregate still lacks tail after local acknowledgement", Metrics.aggregate.count == 7 && Metrics.aggregate[tail] == nil)
        window.setContentSize(NSSize(width: 430, height: 920))
        settle()
        check("geometry changes do not duplicate acknowledgement", Metrics.ackEvents == 1)

        fixture.nativeReady = fixture.anchor
        fixture.waiting = false
        settle()
        let retiredCalls = Metrics.measureCalls
        window.setContentSize(NSSize(width: 460, height: 950))
        settle()
        check("retired notification performs no validation on resize", Metrics.measureCalls == retiredCalls)
        check("retiring observer preserves row instances", Metrics.births == initialBirths && Metrics.deaths.isEmpty)
        check("retired notification does not acknowledge", Metrics.ackEvents == 1)
        let previous = fixture.anchor
        fixture.request += 1
        fixture.nativeReady = nil
        fixture.acknowledged = nil
        fixture.waiting = true
        settle()
        check("same geometry new request acknowledges", fixture.acknowledged == fixture.anchor && Metrics.ackEvents == 2)
        check("new request preserves message view identity", Metrics.births == initialBirths && Metrics.deaths.isEmpty)

        fixture.acknowledged = nil
        root.deliver(previous)
        check("receiver rejects old request", fixture.acknowledged == nil && Metrics.ackEvents == 2)
        root.deliver(.init(positionRequest: fixture.anchor.positionRequest, messageIDs: [UUID(), tail]))
        check("receiver rejects old window", fixture.acknowledged == nil && Metrics.ackEvents == 2)
        root.deliver(.init(positionRequest: .init(conversationID: UUID(), request: fixture.request), messageIDs: fixture.anchor.messageIDs))
        check("receiver rejects other conversation", fixture.acknowledged == nil && Metrics.ackEvents == 2)
        fixture.waiting = false
        root.deliver(fixture.anchor)
        check("receiver rejects callbacks outside entry", fixture.acknowledged == nil && Metrics.ackEvents == 2)
        settle()

        fixture.request += 1
        fixture.tailHeight = 0
        fixture.waiting = true
        settle()
        check("zero height does not acknowledge", fixture.acknowledged == nil && Metrics.ackEvents == 2)
        fixture.tailHeight = 80
        settle()
        check("zero to valid height delivers acknowledgement", fixture.acknowledged == fixture.anchor && Metrics.ackEvents == 3)
        check("all lifecycle changes preserve row identity", Metrics.births == initialBirths && Metrics.deaths.isEmpty)
        check("zero width invalid", root.validate(CGRect(x: 0, y: 0, width: 0, height: 80)) == nil)
        check("nonfinite coordinate invalid", root.validate(CGRect(x: 0, y: CGFloat.nan, width: 300, height: 80)) == nil)
        check("negative offscreen coordinate valid", root.validate(CGRect(x: 0, y: -700, width: 300, height: 80)) == fixture.anchor)
        check("test never presents its window", !window.isVisible)
        let output: [String: Any] = ["checks": results, "ack_events": Metrics.ackEvents,
                                    "row_births": Metrics.births.values.reduce(0, +),
                                    "row_deaths": Metrics.deaths.values.reduce(0, +),
                                    "scope": "hidden macOS SwiftUI host; not iOS or FPS"]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        if !results.values.allSatisfy({ $0 }) { exit(1) }
    }
}
'''
swift = OUT / "EntryRowMeasurementHost.swift"
swift.write_text(template.replace("// TYPES", types).replace("// MODIFIERS", modifiers)
                .replace("// MEASURE", measure).replace("// ACK", ack))
executable = OUT / "EntryRowMeasurementHost"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                str(swift), "-o", str(executable)], check=True)
run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
(OUT / "host-stderr.log").write_text(run.stderr)
result = json.loads(run.stdout)
(OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n")
checks = result["checks"]
print(json.dumps({"checks": len(checks), "failures": [k for k, v in checks.items() if not v],
                  "ack_events": result["ack_events"], "row_births": result["row_births"],
                  "row_deaths": result["row_deaths"], "scope": result["scope"]}, indent=2))
run.check_returncode()
