"""Compare the 5072 earlier-page reading anchor with installed 5071.

Extract the actual 5071 list branches and AppModel paging functions from the
existing structural host. Replace its deliberately full-height viewport with
an 820-point viewport and record real row geometry. This is macOS SwiftUI
evidence, not iPhone inertia, animation, or FPS acceptance.
"""
from pathlib import Path
import ast
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT
OUT = ROOT / "work/verification/history-reading-anchor/final-viewport"
OUT.mkdir(parents=True, exist_ok=True)
original = ast.parse((SOURCE / "CandidateTests/check_history_list_identity.py").read_text())
template = next(ast.literal_eval(n.value) for n in original.body
                if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == "template" for t in n.targets))


def block(source, token):
    start = source.index(token)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


template = template[:template.index("@main private struct Check")]
template = template.replace("private struct ConversationMessageHost: Identifiable {", "private enum ConversationMessageHostID: Hashable { case message(UUID) }\nprivate struct ConversationMessageHost: Identifiable {")
template = template.replace("var id: UUID { message.id }", "var id: ConversationMessageHostID { .message(message.id) }")
template = template.replace("private struct Message: Identifiable { let id: UUID }", r"""
private struct Message: Identifiable { let id: UUID; let index: Int
    var height: CGFloat { [72, 1100, 140, 420, 80, 1750, 220, 100][index % 8] }
}
""")
template = template.replace("(0..<total).map { _ in Message(id: UUID()) }",
                            "(0..<total).map { Message(id: UUID(), index: $0) }")
template = template.replace("static var births:", "static var proxy: ScrollViewProxy?\n    static var positionID: UUID?\n    static var windowFirst: UUID?\n    static var frames: [UUID: CGRect] = [:]\n    static var births:")
template = template.replace("private struct RowIDs:", r"""
private struct RowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
private struct WindowFirst: PreferenceKey {
    static var defaultValue: UUID? { nil }
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) { value = nextValue() ?? value }
}
private struct RowIDs:
""")
template = template.replace("let conversationMessageSpacing: CGFloat = 1", "let conversationMessageSpacing: CGFloat = 18\n    @State private var position = CommandLine.arguments[1].contains(\"targets\") ? ScrollPosition(idType: ConversationMessageHostID.self) : ScrollPosition()")
template = template.replace("let isBoundedConversationEntry = false", 'var isBoundedConversationEntry: Bool { CommandLine.arguments[1].contains("targets") }')
template = template.replace("        ScrollView {\n", "        ScrollViewReader { proxy in\n        ScrollView {\n", 1)
template = template.replace("                // BRANCHES", "                Color.clear.frame(height: 120)\n                // BRANCHES\n                Color.clear.frame(height: 96)")
template = template.replace('        .coordinateSpace(name: "chat-scroll")', '''        .scrollPosition($position, anchor: CommandLine.arguments[1].contains("topanchor") ? .top : nil)
        .coordinateSpace(name: "chat-scroll")
        .onAppear { position.isPositionedByUser = true; Metrics.proxy = proxy }
        .onChange(of: position, initial: true) { _, value in
            if case let .message(id) = value.viewID(type: ConversationMessageHostID.self) { Metrics.positionID = id }
            else { Metrics.positionID = nil }
        }
        .onPreferenceChange(RowFrames.self) { Metrics.frames = $0 }''')
template = template.replace(".onPreferenceChange(RowIDs.self)", ".onPreferenceChange(WindowFirst.self) { Metrics.windowFirst = $0 }\n        .onPreferenceChange(RowIDs.self)")
template = template.replace("Metrics.hasBottomSentinel = $0 != nil }", "Metrics.hasBottomSentinel = $0 != nil }\n        }")
template = template.replace("Row(messageID: host.message.id).frame(height: 4).id(host.message.id)", r"""Row(messageID: host.message.id).frame(height: host.message.height).id(host.message.id)
            .background { GeometryReader { geo in
                Color.clear.preference(key: RowFrames.self,
                    value: [host.message.id: geo.frame(in: .named("chat-scroll"))])
                    .preference(key: WindowFirst.self, value: bottomAnchorID.messageIDs.first)
            }}""")

template = template.replace("var compact = false", "var selectedLogicalTruncateIndex: Int { truncateIndex }; var usesConcreteConversationEntryWindow = false; var compact = false")
template = template.replace("static var proxy:", "static var paging: PagingHarness?\n    static var proxy:")
template = template.replace("let bottomNavigationTailClearance: CGFloat = 0", "let bottomNavigationTailClearance: CGFloat = 0")
template = template.replace("private struct RowFrames: PreferenceKey {", "private struct UnusedRowFrames: PreferenceKey {")
template = template.replace(".onPreferenceChange(RowFrames.self) { Metrics.frames = $0 }", ".onPreferenceChange(MessageFramePreferenceKey.self) { value in if let value { Metrics.frames = value.frames; Metrics.windowFirst = value.anchorID.messageIDs.first; Metrics.paging?.accept(value) } }")
start = template.index("        Row(messageID: host.message.id).frame(height:")
end = template.index("\n    // STACKS", start)
template = template[:start] + r'''
        let hasDivider = host.message.index == model.truncateIndex
        let clearance = host.message.id == bottomAnchorID.messageIDs.last ? bottomNavigationTailClearance : 0
        return VStack(spacing: conversationMessageSpacing) {
            if hasDivider { Color.clear.frame(height: 47) }
            Row(messageID: host.message.id).frame(height: host.message.height).id(host.message.id)
                .background { GeometryReader { geo in
                    let frame = geo.frame(in: .named("chat-scroll"))
                    Color.clear.preference(key: MessageFramePreferenceKey.self,
                        value: ConversationMessageFrameSnapshot(anchorID: bottomAnchorID, frames: [host.message.id: frame]))
                }}
                .preference(key: RowIDs.self, value: [host.message.id: 1])
        }.padding(.bottom, clearance)
    }
''' + template[end:]
template = template.replace("[72, 1100, 140, 420, 80, 1750, 220, 100][index % 8]", '(CommandLine.arguments.contains("equal") ? [820, 820.001, 819.99, 1100, 80, 1750, 220, 100] : [72, 1100, 140, 420, 80, 1750, 220, 100])[index % 8]')

template += r"""
@MainActor private final class NativeScroll {
    let view: NSScrollView
    var window: NSWindow? { view.window }
    var isScrollEnabled = true
    var isDragging = false
    var writes = 0
    let panGestureRecognizer = Pan()
    init(_ view: NSScrollView) { self.view = view }
    var contentOffset: CGPoint { view.contentView.bounds.origin }
    var contentSize: CGSize { view.documentView!.frame.size }
    var bounds: CGRect { CGRect(origin: .zero, size: view.contentView.bounds.size) }
    let adjustedContentInset = Insets()
    func setContentOffset(_ point: CGPoint, animated: Bool) {
        writes += 1
        view.contentView.scroll(to: point); view.reflectScrolledClipView(view.contentView)
    }
}
private struct Insets { let top: CGFloat = 0; let bottom: CGFloat = 0 }
@MainActor private final class Pan { func translation(in view: NativeScroll) -> CGPoint { .zero } }
@MainActor private final class Box { var scrollView: NativeScroll? }
private enum ChatBottomTrace { static func shortID(_ id: UUID) -> String { "id" } }
@MainActor private final class PagingHarness {
    let model: Fixture
    let chatScrollViewBox = Box()
    var snapshot: ConversationMessageFrameSnapshot?
    var messageFrames: [UUID: CGRect] { snapshot?.frames ?? [:] }
    var messageFramesAnchorID: ConversationBottomAnchorID? { snapshot?.anchorID }
    var currentConversationBottomAnchorID: ConversationBottomAnchorID { model.anchor }
    var currentMessageWindowEdgeID: MessageWindowEdgeID { .init(anchorID: model.anchor) }
    var scrollViewportHeight: CGFloat { chatScrollViewBox.scrollView?.bounds.height ?? 0 }
    var canLoadMessageWindow: Bool { true }
    var hasConcreteNativeUserScrollOwnership = true
    var isVerticalScrollGestureActive = false
    var messageWindowLoadTask: Task<Void, Never>?
    var messageWindowPaging = MessageWindowPagingState()
    var lastMessageWindowLoadAt = Date.distantPast
    var bottomNavigationCompactWindowConversationID: UUID?
    init(_ model: Fixture) { self.model = model }
    func conversationMessageHostID(for id: UUID) -> ConversationMessageHostID { .message(id) }
    func traceScrollCommand(source: String, target: String, animation: String) { commands += 1 }
    var commands = 0
    func accept(_ value: ConversationMessageFrameSnapshot) {
        guard value.anchorID == model.anchor else { return }
        snapshot = value
        // RESTORE
    }
    // STATE
    // METHODS
}
@main private struct Check {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var events: [[String: Any]] = []
        for total in [60, 120, 500] {
            Metrics.frames = [:]; Metrics.proxy = nil
            let fixture = Fixture(total); fixture.truncateIndex = total - 12
            let paging = PagingHarness(fixture); Metrics.paging = paging
            let host = NSHostingView(rootView: Host(model: fixture))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 820),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            func settle(_ duration: TimeInterval = 0.12) {
                let deadline = Date().addingTimeInterval(duration)
                repeat {
                    host.needsLayout = true; host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                } while Date() < deadline
            }
            func findScroll(_ view: NSView) -> NSScrollView? {
                if let view = view as? NSScrollView { return view }
                return view.subviews.lazy.compactMap { findScroll($0) }.first
            }
            settle()
            let scroll = findScroll(host)!
            paging.chatScrollViewBox.scrollView = NativeScroll(scroll)
            var page = 0
            for earlier in [true, false, true] {
                while earlier ? fixture.hasEarlierMessages : fixture.hasLaterMessages {
                    let edgeID = earlier ? fixture.messages.first!.id : fixture.messages.last!.id
                    Metrics.proxy!.scrollTo(ConversationMessageHostID.message(edgeID), anchor: earlier ? .top : .bottom)
                    settle()
                    // Small native movement after the exact edge has materialized.
                    let offset = scroll.contentView.bounds.minY + (earlier ? 65 : -65)
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, offset)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: earlier ? -10 : 10, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: wheel) {
                        scroll.scrollWheel(with: event)
                    }
                    settle()
                    let visible = Metrics.frames.filter { $0.value.maxY > 0 && $0.value.minY < 820 }
                    guard !visible.isEmpty else { fatalError("No materialized visible row total=\(total) page=\(page) earlier=\(earlier)") }
                    let readingID = paging.captureEarlierWindowReadingAnchor()?.messageID
                    let before = fixture.window
                    let commands = paging.commands, writes = paging.chatScrollViewBox.scrollView!.writes
                    paging.scheduleMessageWindowLoad(direction: earlier ? .earlier : .later, using: Metrics.proxy!)
                    settle(0.22)
                    // Task.sleep is a minimum delay; host CPU contention can
                    // deliver its continuation later. Bound the test wait on
                    // task completion instead of assuming a 220 ms deadline.
                    let finishDeadline = Date().addingTimeInterval(2)
                    while paging.messageWindowLoadTask != nil && Date() < finishDeadline {
                        settle(0.02)
                    }
                    let deltas = visible.compactMap { id, frame -> Double? in
                        Metrics.frames[id].map { Double($0.minY - frame.minY) }
                    }
                    events.append(["total": total, "page": page, "earlier": earlier,
                        "before": [before.startIndex, before.endIndex],
                        "after": [fixture.window.startIndex, fixture.window.endIndex],
                        "deltas": deltas, "beforeVisible": visible.count, "readingEligible": readingID != nil,
                        "readingRetained": readingID.map { Metrics.frames[$0] != nil } ?? true,
                        "retained": deltas.count, "commands": paging.commands - commands,
                        "nativeWrites": paging.chatScrollViewBox.scrollView!.writes - writes,
                        "taskFinished": paging.messageWindowLoadTask == nil])
                    page += 1; precondition(page < 70)
                }
            }
            window.contentView = nil; Metrics.paging = nil
        }
        print(String(data: try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
"""
source = (SOURCE / "Mocca/RootView.swift").read_text()
model = (SOURCE / "Mocca/AppModel.swift").read_text()
constants = "\n".join(re.search(r"    private static let " + name + r" = \d+", model).group()
    for name in ["messageWindowPageSize", "messageWindowLoadedMax"])
paging = "\n".join(block(model, token) for token in ["var hasEarlierMessages:", "var hasLaterMessages:",
    "func loadEarlierMessages()", "func loadLaterMessages()"])
start = source.index("                                let concreteFavoriteTargetHost =")
end = source.index("                                .padding(.horizontal, 18)", start)
types = "\n".join(block(source, "private struct " + name + ":") for name in [
    "ConversationPositionRequestKey", "ConversationBottomAnchorID", "MessageWindowEdgeID", "MessageWindowEdgeFrame",
    "MessageWindowTopFramePreferenceKey", "MessageWindowBottomFramePreferenceKey", "ConversationMessageFrameSnapshot", "MessageFramePreferenceKey"])
stacks = "\n".join(block(source, "private func " + name + "(") for name in [
    "conversationLazyMessageStack", "conversationCompactBottomMessageStack"])
state = "\n".join(block(source, token) for token in ["private enum MessageWindowLoadDirection:",
    "private final class MessageWindowPagingState {", "private struct MessageWindowReadingAnchor {"])
results = {}
for label in sys.argv[1:] or ["baseline", "candidate"]:
    methodSource = source if label == "candidate" else subprocess.check_output(["git", "show", "6e74c6a:Mocca/RootView.swift"], cwd=SOURCE, text=True)
    methods = "\n".join(block(methodSource, "private func " + name + "(") for name in [
        "scheduleMessageWindowLoad", "finishMessageWindowLoad", "hasMoreMessageWindowContent", "isNearNativeMessageWindowEdge"])
    methods += "\n" + "\n".join(block(source, "private func " + name + "(") for name in ["captureEarlierWindowReadingAnchor", "resolveEarlierWindowReadingAnchor"])
    swift = (template.replace("// TYPES", types).replace("// CONSTANTS", constants).replace("// PAGING", paging)
        .replace("// BRANCHES", source[start:end]).replace("// STACKS", stacks)
        .replace("// STATE", state).replace("// METHODS", methods)
        .replace("// RESTORE", ""))
    # Only expose members to the test runner; extracted function bodies are unmodified.
    swift = swift.replace("private ", "")
    path = OUT / (label + ".swift"); path.write_text(swift)
    exe = OUT / label
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(path), "-o", str(exe)], check=True)
    for pattern in ["mixed", "equal"]:
        run = subprocess.run([str(exe), "wheel", pattern], capture_output=True, text=True, timeout=80)
        (OUT / (label + "-" + pattern + ".stderr")).write_text(run.stderr)
        if run.returncode: raise RuntimeError(run.stderr[-2500:])
        events = json.loads(run.stdout); (OUT / (label + "-" + pattern + ".json")).write_text(json.dumps(events, indent=2))
        summary = {"label": label, "pattern": pattern, "pages": len(events), "maxDelta": max(abs(x) for e in events for x in e["deltas"]),
            "missing": sum(e["retained"] != e["beforeVisible"] for e in events), "maxCommands": max(e["commands"] for e in events),
            "maxNativeWrites": max(e["nativeWrites"] for e in events), "tasksFinished": all(e["taskFinished"] for e in events),
            "eligibleEarlierPages": sum(e["earlier"] and e["readingEligible"] for e in events),
            "fallbackEarlierPages": sum(e["earlier"] and not e["readingEligible"] for e in events),
            "eligibleEarlierMaxDelta": max((abs(x) for e in events if e["earlier"] and e["readingEligible"] for x in e["deltas"]), default=0),
            "eligibleEarlierMissing": sum(e["earlier"] and e["readingEligible"] and (not e["readingRetained"] or e["retained"] != e["beforeVisible"]) for e in events)}
        if label == "candidate":
            assert summary["eligibleEarlierMaxDelta"] <= 0.5 and summary["eligibleEarlierMissing"] == 0, summary
            assert all(e["commands"] == 1 and e["nativeWrites"] == 0 and e["taskFinished"] for e in events), summary
        else:
            assert summary["eligibleEarlierMaxDelta"] > 1, summary
        results[label + "-" + pattern] = summary; print(json.dumps(summary), flush=True)
(OUT / "summary.json").write_text(json.dumps(results, indent=2))
