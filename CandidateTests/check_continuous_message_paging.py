"""Run extracted production paging functions with deterministic native/event inputs.

No simulator, phone, SwiftUI layout emulation, or performance/FPS claim.
The baseline must reproduce the two progress failures; candidate must pass
admission, fresh-layout handoff, cancellation and native-boundary cases.
"""
from pathlib import Path
import json, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/verification/continuous-history/host'
OUT.mkdir(parents=True, exist_ok=True)
BASE = '45c5b7a'

def block(source, token):
    start = source.index(token)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor]

TYPES = r'''
import Foundation
import CoreGraphics
private struct UnitPoint: Equatable { let x: CGFloat; let y: CGFloat; static let top = Self(x: 0.5,y: 0); static let bottom = Self(x: 0.5,y: 1) }
private struct Transaction { var disablesAnimations = false }
@MainActor private func withTransaction(_ t: Transaction, _ body: () -> Void) { body() }
private struct Insets { var top: CGFloat = 48; var bottom: CGFloat = 34 }
@MainActor private final class NativeScroll {
    var window: Int? = 1
    var isScrollEnabled = true
    var isDragging = false
    let panGestureRecognizer = Pan()

    var contentOffset = CGPoint(x: 0, y: -48)
    var contentSize = CGSize(width: 400, height: 10000)
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    var adjustedContentInset = Insets()
}
@MainActor private final class Pan {
    var point = CGPoint.zero
    func translation(in view: NativeScroll) -> CGPoint { point }
}
@MainActor private final class Box { var scrollView: NativeScroll? = NativeScroll() }
private struct Message { let id: UUID }
@MainActor private final class Model {
    var selectedConversationID = UUID()
    var conversationBottomReturnRequest = 1
    var usesConcreteConversationEntryWindow = false
    var allMessages = (1...100).map { Message(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!) }
    var selectedLogicalTruncateIndex = -1
    var messageWindowStartIndex: Int { start }
    var start = 88, count = 12, earlierLoads = 0, laterLoads = 0
    var boundaryReads = 0
    var messages: [Message] { Array(allMessages[start..<start+count]) }
    var hasEarlierMessages: Bool { start > 0 }
    var hasLaterMessages: Bool { start + count < allMessages.count }
    var messageWindowBoundary: (firstID: UUID?, lastID: UUID?, count: Int) {
        boundaryReads += 1
        return (allMessages[start].id, allMessages[start+count-1].id, count)
    }
    func loadEarlierMessages() -> Bool {
        guard hasEarlierMessages else { return false }
        usesConcreteConversationEntryWindow = false
        let end = start + count
        start = max(0, start - 20); count = min(360, end - start); earlierLoads += 1
        return true
    }
    func loadLaterMessages() -> Bool {
        guard hasLaterMessages else { return false }
        usesConcreteConversationEntryWindow = false
        let end = min(allMessages.count, start + count + 20)
        start = max(0, end - 360); count = end - start; laterLoads += 1
        return true
    }
}
@MainActor private struct ScrollViewProxy {
    var onAnchor: () -> Void = {}
    func scrollTo(_ id: UUID, anchor: UnitPoint) { onAnchor() }
}
private enum ChatBottomTrace { static func shortID(_ id: UUID) -> String { "id" } }
'''
HARNESS = r'''
@MainActor private final class Harness {
    let model = Model()
    let chatScrollViewBox = Box()
    var messageReplacementRequest: UUID?
    var messageReplacementConcreteWindowSessionID: UUID?
    var currentChatViewportSessionID = UUID()
    var hasConcreteNativeUserScrollOwnership = true
    var isVerticalScrollGestureActive = true
    var scrollViewportHeight: CGFloat = 800
    var isPositioningCurrentConversation = false
    var isUserMessageSendPositioning = false
    var isMessageTargetNavigationOwned = false
    var ownsCurrentDoubleEdgeNavigation = false
    var automaticReasoningCollapseOwner: UUID?
    var messageWindowLoadTask: Task<Void, Never>?
    var messageWindowPaging = MessageWindowPagingState()
    var lastMessageWindowLoadAt = Date.distantPast
    var messageReplacementLandingTask: Task<Void, Never>?
    var bottomNavigationCompactWindowConversationID: UUID?
    var currentConversationBottomAnchorID: ConversationBottomAnchorID {
        .init(positionRequest: currentConversationPositionRequest, messageIDs: model.messages.map(\.id))
    }
    var frameAnchorOverride: ConversationBottomAnchorID?
    var frameOverride: [UUID: CGRect]?
    var messageFramesAnchorID: ConversationBottomAnchorID? { frameAnchorOverride ?? currentConversationBottomAnchorID }
    var messageFrames: [UUID: CGRect] {
        frameOverride ?? Dictionary(uniqueKeysWithValues: model.messages.enumerated().map {
            ($0.element.id, CGRect(x: 0, y: $0.offset * 100, width: 400, height: 80))
        })
    }
    var anchorWrites = 0
    var didAnchor: ((Harness) -> Void)?
    var proxy: ScrollViewProxy { .init(onAnchor: { [unowned self] in
        anchorWrites += 1; didAnchor?(self)
    }) }
    var currentConversationPositionRequest: ConversationPositionRequestKey {
        .init(conversationID: model.selectedConversationID, request: model.conversationBottomReturnRequest)
    }
    // ID_PROPERTY
    // STATE_CLASS
    // DIRECTION
    // METHODS
    func conversationMessageHostID(for id: UUID) -> UUID { id }
    func traceScrollCommand(source: String, target: String, animation: String) {}
    func sample(y: CGFloat = 80, window: MessageWindowEdgeID? = nil) -> MessageWindowEdgeFrame {
        .init(windowID: window ?? currentMessageWindowEdgeID,
              frame: CGRect(x: 18, y: y, width: 366, height: 1))
    }
    func emit(_ sample: MessageWindowEdgeFrame? = nil, later: Bool = false) {
        let event = sample ?? self.sample()
        // EMIT
    }
    func absent() { // ABSENT
    }
    func startDirect() { scheduleMessageWindowLoad(direction: .earlier, using: proxy) }
    func near(_ later: Bool = false) {
        guard let native = chatScrollViewBox.scrollView else { return }
        native.contentOffset.y = later
            ? native.contentSize.height - native.bounds.height + native.adjustedContentInset.bottom
            : -native.adjustedContentInset.top
    }
    func away() { chatScrollViewBox.scrollView?.contentOffset.y = 1200 }
    func drain() async {
        var tasks = 0
        while let task = messageWindowLoadTask {
            await task.value; tasks += 1
            precondition(tasks < 20, "Unexpected page cascade")
        }
    }
}
'''
TESTS = r'''
@main struct Checks {
    @MainActor static func main() async {
        var results: [String: Bool] = [:]
        func check(_ name: String, _ result: Bool) { results[name] = (results[name] ?? true) && result }
        // A changed eligible sample lands while the old 140ms task still owns
        // paging. No reverse gesture or extra event arrives after completion.
        do {
            let h = Harness()
            h.didAnchor = { h in
                if h.model.earlierLoads == 1 { h.near(); h.emit(h.sample(y: 81)) }
                else { h.away(); h.emit(h.sample(y: -1200)) }
            }
            h.emit(); await h.drain()
            check("busy edge continues without reverse nudge", h.model.earlierLoads == 2)
        }
        do {
            let h = Harness(); h.near(); h.emit(h.sample(y: 139)); await h.drain()
            check("legal native top beyond old sentinel cutoff", h.model.earlierLoads == 1)
        }
        // CANDIDATE_ONLY
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
'''
CANDIDATE = r'''
        do {
            let h = Harness()
            h.hasConcreteNativeUserScrollOwnership = false
            h.isVerticalScrollGestureActive = false
            h.near(); h.emit(h.sample(y: 139)); await h.drain()
            check("native fallback requires actual user scrolling", h.model.earlierLoads == 0)
        }
        do {
            let h = Harness()
            h.didAnchor = {
                $0.hasConcreteNativeUserScrollOwnership = false
                $0.isVerticalScrollGestureActive = false
                $0.near(); $0.emit()
            }
            h.emit(); await h.drain()
            check("idle relayout cannot cascade pages", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness()
            h.didAnchor = {
                $0.near(); $0.emit()
                $0.hasConcreteNativeUserScrollOwnership = false
                $0.isVerticalScrollGestureActive = false
            }
            h.emit(); await h.drain()
            check("last user edge completes once after release", h.model.earlierLoads == 2)
        }
        do {
            let h = Harness(); h.didAnchor = { $0.near() }; h.emit(); await h.drain()
            check("no fresh layout does not repeat", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness(); let old = h.sample()
            h.didAnchor = { $0.near(); $0.emit(old) }; h.emit(); await h.drain()
            check("old window cannot authorize continuation", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness()
            h.didAnchor = { $0.near(); $0.emit(); $0.absent() }
            h.emit(); await h.drain()
            check("absent latest edge clears handoff", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness()
            h.didAnchor = { $0.near(); $0.emit(); $0.away() }
            h.emit(); await h.drain()
            check("live position wins over earlier edge sample", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness()
            h.didAnchor = { $0.near(); $0.emit(later: true) }
            h.emit(); await h.drain()
            check("opposite edge does not chain or reverse direction", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness(); h.model.start = 0; h.model.count = 40; h.near(true)
            h.didAnchor = { h in
                if h.model.laterLoads == 1 { h.near(true); h.emit(h.sample(y: 790), later: true) }
                else { h.away(); h.emit(h.sample(y: 5000), later: true) }
            }
            h.emit(h.sample(y: 790), later: true); await h.drain()
            check("later pages hand off in same direction", h.model.laterLoads == 2 && h.model.earlierLoads == 0)
        }
        do {
            let h = Harness(); h.model.start = 8; h.model.count = 92
            h.didAnchor = { $0.near(); $0.emit() }; h.emit(); await h.drain()
            check("real history start terminates", h.model.earlierLoads == 1)
        }
        for mutation in 0..<4 {
            let h = Harness(); let window = h.currentMessageWindowEdgeID
            let wrong = MessageWindowEdgeID(
                positionRequest: .init(conversationID: mutation == 0 ? UUID() : window.positionRequest.conversationID,
                                       request: window.positionRequest.request + (mutation == 1 ? 1 : 0)),
                firstMessageID: mutation == 2 ? UUID() : window.firstMessageID,
                lastMessageID: window.lastMessageID,
                messageCount: window.messageCount + (mutation == 3 ? 1 : 0))
            h.emit(h.sample(window: wrong)); await h.drain()
            check("stale identity rejected \(mutation)", h.model.earlierLoads == 0)
        }
        let guards: [(String, (Harness) -> Void)] = [
            ("drawer native lock", { $0.chatScrollViewBox.scrollView?.isScrollEnabled = false }),
            ("detached native view", { $0.chatScrollViewBox.scrollView?.window = nil }),
            ("missing native view", { $0.chatScrollViewBox.scrollView = nil }),
            ("entry positioning", { $0.isPositioningCurrentConversation = true }),
            ("send", { $0.isUserMessageSendPositioning = true }),
            ("message navigation", { $0.isMessageTargetNavigationOwned = true }),
            ("edge navigation", { $0.ownsCurrentDoubleEdgeNavigation = true }),
            ("replacement", { $0.messageReplacementRequest = UUID() }),
            ("replacement landing", { $0.messageReplacementLandingTask = Task {} }),
            ("reasoning collapse", { $0.automaticReasoningCollapseOwner = UUID() }),
            ("empty viewport", { $0.scrollViewportHeight = 0 }),
            ("nonfinite viewport", { $0.scrollViewportHeight = .nan })
        ]
        for (name, inhibit) in guards {
            let h = Harness(); inhibit(h); h.emit(); await h.drain()
            check("admission rejects \(name)", h.model.earlierLoads == 0)
            let moving = Harness()
            moving.didAnchor = { $0.emit(); inhibit($0) }
            moving.emit(); await moving.drain()
            check("handoff respects \(name)", moving.model.earlierLoads == 1)
        }
        do {
            let h = Harness(); h.model.usesConcreteConversationEntryWindow = true
            h.hasConcreteNativeUserScrollOwnership = false; h.isVerticalScrollGestureActive = false
            h.emit(); await h.drain()
            check("bounded entry cannot auto expand", h.model.earlierLoads == 0)
            h.hasConcreteNativeUserScrollOwnership = true
            h.emit(); await h.drain()
            check("real user can expand bounded entry", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness(); h.messageReplacementConcreteWindowSessionID = h.currentChatViewportSessionID
            h.hasConcreteNativeUserScrollOwnership = false; h.isVerticalScrollGestureActive = false
            h.emit(); await h.drain()
            check("bounded deletion cannot auto expand", h.model.earlierLoads == 0)
        }
        do {
            let h = Harness(); h.emit(); h.model.conversationBottomReturnRequest += 1
            await h.drain()
            check("request changes before load cancel work", h.model.earlierLoads == 0)
        }
        do {
            let h = Harness(); h.emit(); h.model.start -= 1; h.model.count += 1
            await h.drain()
            check("window changes before load cancel work", h.model.earlierLoads == 0)
        }
        do {
            let h = Harness()
            h.didAnchor = { $0.emit(); $0.model.selectedConversationID = UUID() }
            h.emit(); await h.drain()
            check("conversation switch prevents continuation", h.model.earlierLoads == 1)
        }
        do {
            let h = Harness(); h.emit()
            let old = h.messageWindowLoadTask!
            while h.anchorWrites == 0 { await Task.yield() }
            old.cancel(); h.messageWindowLoadTask = nil
            h.startDirect()
            let replacementID = h.messageWindowPaging.taskID
            await old.value
            check("cancelled task cannot clear replacement slot",
                  h.messageWindowLoadTask != nil && h.messageWindowPaging.taskID == replacementID)
            await h.drain()
            check("replacement task completes independently", h.model.earlierLoads == 2)
        }
        for top: CGFloat in [0, 48, 59, 62] {
            let h = Harness(); let native = h.chatScrollViewBox.scrollView!
            native.adjustedContentInset.top = top; h.near()
            check("native top accounts for inset \(top)", h.isNearNativeMessageWindowEdge(.earlier))
            native.contentOffset.y += 97
            check("native top excludes outside buffer \(top)", !h.isNearNativeMessageWindowEdge(.earlier))
        }
        do {
            let h = Harness(); let native = h.chatScrollViewBox.scrollView!
            native.contentSize.height = 100; h.near()
            check("short viewport uses clamped native bottom", h.isNearNativeMessageWindowEdge(.later))
            native.contentOffset.y = .nan
            check("nonfinite native offset rejected", !h.isNearNativeMessageWindowEdge(.earlier))
        }
        do {
            let h = Harness()
            let invalid = MessageWindowEdgeFrame(windowID: h.currentMessageWindowEdgeID, frame: .zero)
            h.emit(invalid); await h.drain()
            check("empty measured frame rejected", h.model.earlierLoads == 0)
        }
        do {
            let h = Harness(); let event = h.sample()
            let before = h.model.boundaryReads
            h.chatScrollViewBox.scrollView?.isScrollEnabled = false
            for _ in 0..<10000 { h.emit(event) }
            check("blocked drawer callbacks do not read window projection", h.model.boundaryReads == before)
            check("blocked drawer callbacks schedule no tasks", h.messageWindowLoadTask == nil)
        }
        do {
            let h = Harness(); h.away(); let event = h.sample(y: -1200)
            for _ in 0..<10000 { h.emit(event) }
            check("away from edge schedules no task or paging state", h.messageWindowLoadTask == nil
                  && h.messageWindowPaging.taskID == nil && h.messageWindowPaging.measuredWindowID == nil)
        }
'''


CANDIDATE += r"""
        func readingHarness() -> Harness {
            let h = Harness()
            h.chatScrollViewBox.scrollView!.adjustedContentInset = Insets(top: 0, bottom: 0)
            return h
        }
        do {
            let h = readingHarness(); let ids = h.model.messages.map(\.id)
            h.frameOverride = [ids[0]: CGRect(x:0,y:-110,width:400,height:80),
                ids[1]: CGRect(x:0,y:-12,width:400,height:500),
                ids[2]: CGRect(x:0,y:506,width:400,height:130)]
            let reading = h.captureEarlierWindowReadingAnchor()!
            check("primary visible reading row selected", reading.messageID == ids[1])
            let target = h.resolveEarlierWindowReadingAnchor(reading)!
            check("partial row keeps its offset instead of top alignment", abs(target.anchor.y + 0.04) < 0.00001)
            h.model.selectedLogicalTruncateIndex = h.model.start + 1
            check("divider host excluded from row-only geometry", h.captureEarlierWindowReadingAnchor()?.messageID == ids[2])
            h.model.selectedLogicalTruncateIndex = -1
            h.chatScrollViewBox.scrollView!.isDragging = true
            h.chatScrollViewBox.scrollView!.panGestureRecognizer.point.y = 20
            let dragging = h.captureEarlierWindowReadingAnchor()!
            h.chatScrollViewBox.scrollView!.panGestureRecognizer.point.y = -4
            check("finger motion during handoff is included", abs(h.resolveEarlierWindowReadingAnchor(dragging)!.anchor.y + 0.12) < 0.00001)
            h.chatScrollViewBox.scrollView!.bounds.size.height += 1
            check("viewport resize rejects stale reading target", h.resolveEarlierWindowReadingAnchor(reading) == nil)
            h.chatScrollViewBox.scrollView!.bounds.size.height -= 1
            h.chatScrollViewBox.scrollView = NativeScroll()
            check("replacement scroll view rejects reading target", h.resolveEarlierWindowReadingAnchor(reading) == nil)
        }
        for height: CGFloat in [799.5, 800, 800.5, .nan, .infinity, 0, -10] {
            let h = readingHarness(); let id = h.model.messages[0].id
            h.frameOverride = [id: CGRect(x:0,y:12,width:400,height:height)]
            check("unsafe height uses legacy path \(height)", h.captureEarlierWindowReadingAnchor() == nil)
            h.emit(); await h.drain()
            check("unsafe height still loads with only one command \(height)", h.model.earlierLoads == 1 && h.anchorWrites == 1)
        }
        do {
            let h = readingHarness(); let ids = h.model.messages.map(\.id)
            h.frameOverride = [ids[0]: CGRect(x:0,y:-20,width:400,height:800), ids[1]: CGRect(x:0,y:798,width:400,height:80)]
            check("safe visible neighbour handles equal-height primary", h.captureEarlierWindowReadingAnchor()?.messageID == ids[1])
            let saved = h.currentConversationBottomAnchorID
            h.model.conversationBottomReturnRequest += 1; h.frameAnchorOverride = saved
            check("old frame snapshot rejected", h.captureEarlierWindowReadingAnchor() == nil)
        }
        do {
            let h = readingHarness(); let id = h.model.messages[0].id
            h.frameOverride = [id: CGRect(x:0,y:42,width:400,height:1750)]
            let reading = h.captureEarlierWindowReadingAnchor()!
            check("very tall message has finite relative anchor", h.resolveEarlierWindowReadingAnchor(reading)!.anchor.y.isFinite)
            h.frameOverride = [id: CGRect(x:0,y:10000,width:400,height:800)]
            check("new equal-height measurement cannot emit infinite coordinate", h.resolveEarlierWindowReadingAnchor(reading) == nil)
        }
        do {
            let h = readingHarness(); h.frameOverride = [:]
            h.emit(); await h.drain()
            check("missing row map does not block history", h.model.earlierLoads == 1 && h.anchorWrites == 1)
        }
"""

CANDIDATE += r"""
        do {
            let h = readingHarness()
            h.didAnchor = { h in
                for _ in 0..<10000 { h.emit() }
                h.away()
            }
            h.emit(); await h.drain()
            check("reentrant edge callbacks cannot add correction commands", h.model.earlierLoads == 1 && h.anchorWrites == 1)
        }
"""

CANDIDATE += r"""
        for (top, bottom): (CGFloat, CGFloat) in [(48, 0), (48, 34), (0, 34), (0, 0)] {
            let h = readingHarness(); let native = h.chatScrollViewBox.scrollView!
            native.adjustedContentInset = Insets(top: top, bottom: bottom)
            let id = h.model.messages[1].id
            h.frameOverride = [id: CGRect(x: 0, y: 17, width: 400, height: 500)]
            let reading = h.captureEarlierWindowReadingAnchor()!
            let target = h.resolveEarlierWindowReadingAnchor(reading)!
            let resolvedY = top + (800 - top - bottom - 500) * target.anchor.y
            check("adjusted viewport preserves screen position top=\(top) bottom=\(bottom)", abs(resolvedY - 17) < 0.00001)
            native.adjustedContentInset.top += 1
            check("top inset changes reject old reading target top=\(top) bottom=\(bottom)", h.resolveEarlierWindowReadingAnchor(reading) == nil)
            native.adjustedContentInset.top = top; native.adjustedContentInset.bottom += 1
            check("bottom inset changes reject old reading target top=\(top) bottom=\(bottom)", h.resolveEarlierWindowReadingAnchor(reading) == nil)
            native.adjustedContentInset.bottom = bottom
            h.frameOverride = [id: CGRect(x: 0, y: top, width: 400, height: 800 - top - bottom)]
            check("row equal to adjusted viewport uses guarded legacy path top=\(top) bottom=\(bottom)", h.captureEarlierWindowReadingAnchor() == nil)
        }
        for (index, insets) in [Insets(top: .nan, bottom: 0), Insets(top: 0, bottom: .infinity), Insets(top: 800, bottom: 0)].enumerated() {
            let h = readingHarness(); h.chatScrollViewBox.scrollView!.adjustedContentInset = insets
            check("invalid adjusted viewport is rejected \(index)", h.captureEarlierWindowReadingAnchor() == nil)
        }
"""

candidate = (ROOT / 'Mocca/RootView.swift').read_text()
common_types = '\n'.join(block(candidate, 'private struct '+name+':') for name in [
    'ConversationPositionRequestKey', 'ConversationBottomAnchorID', 'MessageWindowEdgeID', 'MessageWindowEdgeFrame'])
state = block(candidate, 'private final class MessageWindowPagingState {')
state += '\n' + block(candidate, 'private struct MessageWindowReadingAnchor {')
direction = block(candidate, 'private enum MessageWindowLoadDirection:')
identity = block(candidate, 'private var currentMessageWindowEdgeID:')
results = {}
with tempfile.TemporaryDirectory(prefix='mocca-continuous-paging-') as tmp:
    for label, source in [('baseline', subprocess.check_output(['git','show',BASE+':Mocca/RootView.swift'],cwd=ROOT,text=True)), ('candidate',candidate)]:
        methods = '\n'.join(block(source,'private func '+name+'(') for name in ['handleMessageWindowEdge','scheduleMessageWindowLoad'])
        if label == 'candidate':
            methods += '\n' + block(source,'private var canLoadMessageWindow:')
            methods += '\n' + '\n'.join(block(source,'private func '+name+'(') for name in ['hasMoreMessageWindowContent','isNearNativeMessageWindowEdge','finishMessageWindowLoad','captureEarlierWindowReadingAnchor','resolveEarlierWindowReadingAnchor'])
        # Expose extracted private members only to the host assertions; bodies unchanged.
        harness = HARNESS.replace('// ID_PROPERTY',identity).replace('// STATE_CLASS',state).replace('// DIRECTION',direction).replace('// METHODS',methods).replace('private ', '')
        harness = harness.replace('// EMIT', 'handleMessageWindowEdge('+('event' if label=='candidate' else 'event.frame')+', direction: later ? .later : .earlier, using: proxy)')
        harness = harness.replace('// ABSENT', 'handleMessageWindowEdge('+('nil' if label=='candidate' else '.zero')+', direction: .earlier, using: proxy)')
        text = (TYPES+common_types+harness+TESTS.replace('// CANDIDATE_ONLY', CANDIDATE if label=='candidate' else '')).replace('private ', '')
        path=Path(tmp)/f'{label}.swift'; path.write_text(text)
        (OUT/f'{label}-extracted-host.swift').write_text(text)
        exe=Path(tmp)/label
        subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6',str(path),'-o',str(exe)],check=True)
        results[label]=json.loads(subprocess.check_output([str(exe)],text=True,timeout=30))
assert not any(results['baseline'].values()), results['baseline']
assert all(results['candidate'].values()), {k:v for k,v in results['candidate'].items() if not v}
(OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps({k:{'checks':len(v),'failed':sum(not x for x in v.values())} for k,v in results.items()},indent=2))
