"""Offline tests of shared deletion and reply-version viewport replacement.

Extracts actual Swift functions; mocks view geometry and model APIs. This does
not emulate SwiftUI lazy materialization or establish iPhone visual acceptance.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'Mocca/RootView.swift').read_text()
def between(start, end):
    a = s.index(start)
    return s[a:s.index(end, a)]
source = '''import Foundation
import Observation
import CoreGraphics
struct ConversationBottomAnchorID: Equatable { var messageIDs: [UUID] }
struct BottomFrame { var anchorID: ConversationBottomAnchorID; var frame: CGRect; var layoutRequestID: UUID? = nil }
enum Role { case user, assistant }
struct ChatMessage { let id: UUID; let conversationID: UUID; let role: Role; var version = 0; var versionGroupKey = "g"; var text = ""; var isStreaming = false }
struct Preferences { var autoScrollEnabled = true }
struct Insets { var top: CGFloat = 0; var bottom: CGFloat = 0 }
final class UIScrollView {
    var window: Int? = 1
    var bounds = CGRect(x: 0, y: 0, width: 360, height: 800)
    var contentSize = CGSize(width: 360, height: 1600)
    var contentOffset = CGPoint(x: 0, y: 800)
    var adjustedContentInset = Insets()
    var writes: [CGPoint] = []
    var paintRefreshes = 0
    func setContentOffset(_ value: CGPoint, animated: Bool) { writes.append(value); contentOffset = value }
}
struct Transaction { var disablesAnimations = false }
enum MessageTextViewportDrawing {
    static func refreshAfterLayout(in view: UIScrollView) { view.paintRefreshes += 1 }
}
func withTransaction(_ transaction: Transaction, _ body: () -> Void) { body() }
enum UIView { static func performWithoutAnimation(_ body: () -> Void) { body() } }
enum UnitPoint { case top, bottom }
@MainActor final class ScrollRecorder { var commands: [(AnyHashable, UnitPoint)] = [] }
struct ScrollViewProxy {
    let recorder: ScrollRecorder
    @MainActor func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint) {
        recorder.commands.append((AnyHashable(id), anchor))
    }
}
@MainActor func awaitNextMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
final class WeakBox { var scrollView: UIScrollView? = UIScrollView() }
enum ChatBottomTrace {
    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(5)) }
    static func log(_ line: String) {}
}
@MainActor final class Model {
    let selectedConversationID = UUID()
    var messages: [ChatMessage] = []
    var hasLaterMessages = false
    var streaming = false
    var preferences = Preferences()
    var activeStreamingMessageIDsByConversation: [UUID: UUID] {
        guard streaming, let last = messages.last else { return [:] }
        return [selectedConversationID: last.id]
    }
    func activeStreamingMessageID(for id: UUID) -> UUID? { activeStreamingMessageIDsByConversation[id] }
    var streamDisplaySuspensionLedgersByMessageID: [UUID: StreamingTextDisplaySuspensionLedger] = [:]
    var streamDisplayTasksByMessageID: [UUID: Task<Void, Never>] = [:]
    var streamDisplayBatchCharactersByMessageID: [UUID: Int] = [:]
    var rawStreamingTextByMessageID: [UUID: String] = [:]
    var resumed: [UUID] = []
    var onResume: (() -> Void)?
    func filteredStreamingDisplayText(_ text: String) -> (text: String, codecDuration: TimeInterval, filterInputUTF16: Int?) { (text, 0, nil) }
    func scheduleStreamingTextDisplay(conversationID: UUID, messageID: UUID, targetDisplayText: String, codecDuration: TimeInterval, filterInputUTF16: Int?) {
        resumed.append(messageID); onResume?()
    }
    // PRODUCTION_SUSPENSION_METHOD
    var variantMessages: [ChatMessage] = []
    var versionWrites: [Int] = []
    func versions(for id: UUID) -> [ChatMessage] { variantMessages }
    func selectVersion(_ version: Int, for id: UUID) {
        versionWrites.append(version)
        guard let index = messages.firstIndex(where: { $0.id == id }),
              let replacement = variantMessages.first(where: { $0.version == version && $0.versionGroupKey == messages[index].versionGroupKey }) else { return }
        messages[index] = replacement
    }
    var deletions: [(UUID, Bool)] = []
    func limitMessageWindowForConcreteLayout(around id: UUID) -> Bool { messages.contains { $0.id == id } }
    func isConversationStreaming(_ id: UUID) -> Bool { streaming }
    func deleteMessage(_ id: UUID) { deletions.append((id, false)); messages.removeAll { $0.id == id } }
    func deleteAllMessageVersions(_ id: UUID) { deletions.append((id, true)); messages.removeAll { $0.id == id } }
    func deletionLandingUserMessageID(before id: UUID, in conversationID: UUID) -> UUID? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return messages[..<index].last(where: { $0.role == .user })?.id
    }
}
'''
app_source = (root / 'Mocca/AppModel.swift').read_text()
a = app_source.index('    func setStreamingTextDisplaySuspended(')
b = app_source.index('    /// Drawer suspension', a)
source = source.replace('    // PRODUCTION_SUSPENSION_METHOD', app_source[a:b])
source += (root / 'Mocca/OffscreenStreamingDisplayPolicy.swift').read_text()
code = (root / 'Mocca/ChatContentMutation.swift').read_text()
source += code[code.index('/// Ordinary edits'):code.index('/// The child requests')]
source += """
@MainActor final class ChatContentMutationAnchorHandle {
    var hasFrame = true
    var contentFrame = CGRect(x: 0, y: 850, width: 320, height: 450)
    func frameInWindow(matching scrollView: UIScrollView) -> CGRect? {
        guard hasFrame else { return nil }
        return contentFrame.offsetBy(dx: 0, dy: -scrollView.contentOffset.y)
    }
}
"""
source += between('private enum ConversationMessageHostID', 'private struct ConversationMessageHost:')
source += between('private enum MessageViewportEdit', 'private struct MessageTargetLandingSnapshot')
source += '''
@MainActor private final class Fixture {
    let model = Model()
    let chatScrollViewBox = WeakBox()
    var currentConversationBottomAnchorID: ConversationBottomAnchorID {
        ConversationBottomAnchorID(messageIDs: model.messages.map(\\.id))
    }
    var frames: [UUID: CGRect] = [:]
    let currentChatViewportSessionID = UUID()
    var messageReplacementConcreteWindowSessionID: UUID?
    var bottomGeometryError: CGFloat = 0
    var staleMessageLayout = false
    var staleBottomLayout = false
    var messageFramesLayoutRequestID: UUID? {
        staleMessageLayout ? nil : messageReplacementRequest?.id
    }
    var bottomFrameAvailable = true
    var latestConversationBottomAnchorFrame: BottomFrame? {
        guard bottomFrameAvailable else { return nil }
        // The real preference snapshot survives a temporary native probe gap.
        let contentEnd = chatScrollViewBox.scrollView.map {
            $0.contentSize.height - $0.contentOffset.y
        } ?? 800
        return BottomFrame(anchorID: currentConversationBottomAnchorID,
            frame: CGRect(x: 0, y: contentEnd + bottomGeometryError - 1,
                          width: 360, height: 1),
            layoutRequestID: staleBottomLayout ? nil : messageReplacementRequest?.id)
    }
    var scrollViewportHeight: CGFloat = 800
    var conversationContentMinimumHeight: CGFloat { scrollViewportHeight }
    var composerBottomClearance: CGFloat = 110
    var autoFollowEngaged = true
    var lastKnownNearBottom = true
    var lastMeasuredNearBottom = true
    var lastMeasuredAtBottom = true
    var hasContentMutationCompetingOwner = false
    var hasCurrentConcreteLatestBottomContent = true
    var isCodeDisclosureInProgress: Bool { messageReplacementRequest?.codeDisclosure != nil }
    func clearAutomaticReasoningCollapseAuthorization(reason: String) {}
    func refreshMeasuredBottomStateFromUIKit() -> (isAtBottom: Bool, isNearBottom: Bool) {
        currentUIKitBottomState ?? (false, false)
    }
    func beginFold(_ message: ChatMessage, state: CodeBlockDisclosureState,
                   expanded: Bool, edge: ChatContentMutationAnchorEdge = .footer) {
        beginCodeDisclosure(CodeDisclosureChange(
            scope: MessageContentMutationScope(conversationID: message.conversationID,
                messageID: message.id, region: .wholeMessage),
            blockID: 1, state: state, expanded: expanded, edge: edge))
    }
    func codeGeometry(_ frames: [UUID: CGRect], _ recorder: ScrollRecorder) {
        acknowledgeCodeDisclosureLayout(frames, using: ScrollViewProxy(recorder: recorder))
    }
    var interrupted = false
    var currentUIKitBottomState: (isAtBottom: Bool, isNearBottom: Bool)? = (true, true)
    var chatBottomTraceState = ""
    var messageReplacementRequest: MessageReplacementViewportRequest?
    var messageReplacementLandingTask: Task<Void, Never>?
    func validConcreteMessageFrame(_ id: UUID, anchorID: ConversationBottomAnchorID) -> CGRect? {
        guard anchorID == currentConversationBottomAnchorID else { return nil }
        return frames[id]
    }
    func messageReplacementLandingWasInterrupted(_ view: UIScrollView, expectedScrollViewIdentity: ObjectIdentifier) -> Bool {
        interrupted || ObjectIdentifier(view) != expectedScrollViewIdentity
    }
    func prepareForMessageReplacementLanding() { autoFollowEngaged = false }
    func cancelMessageTargetNavigationForUserInteraction() {}
    func cancelPendingMessageNavigation() {}
    func cancelConversationReturnPositioning() {}
    var navigationScrollTask: Task<Void, Never>?
    var navigationRequest: UUID?

    func add(_ role: Role) -> ChatMessage {
        let message = ChatMessage(id: UUID(), conversationID: model.selectedConversationID, role: role)
        model.messages.append(message)
        return message
    }
    func begin(_ message: ChatMessage, all: Bool = false) {
        deleteMessagePreservingReadingPosition(message, deletesAllVersions: all)
    }
    func beginVersion(_ old: ChatMessage, _ new: ChatMessage) { beginVersionReplacement(from: old, to: new) }
    func desiredVersionMinY(_ request: MessageReplacementViewportRequest) -> CGFloat? {
        messageReplacementDesiredMinY(request)
    }
    func cancel() { cancelMessageReplacementLanding() }
    func commit(_ id: UUID, anchor: ConversationBottomAnchorID, recorder: ScrollRecorder) {
        commitMessageReplacementAfterRelease(id, sourceAnchorID: anchor, using: ScrollViewProxy(recorder: recorder))
    }
    func acknowledgeFrame() { finishMessageReplacementIfReady() }
    func geometryChanged(_ recorder: ScrollRecorder) {
        advanceMessageReplacementIfReady(using: ScrollViewProxy(recorder: recorder))
        finishMessageReplacementIfReady()
    }
    func traceScrollCommand(source: String, target: String, animation: String) {}
    func displayMessages() -> [ChatMessage] { messagesForCodeDisclosureLayout(model.messages) }

'''
source += between('    private func finishMessageReplacementAutoFollow(', '    private func deleteMessagePreservingReadingPosition(')
source += between('    private func conversationMessageHostID(', '    private func beginVersionReplacement(')
source += between('    private func deletionLandingTargetID', '    private func messageReplacementLandingWasInterrupted')
source += between('    private func beginVersionReplacement(', '    private func schedulePendingMessageTargetNavigation(')
source += between('    private func deleteMessagePreservingReadingPosition', '    private func commitMessageReplacementAfterRelease')
source += between('    private func cancelMessageReplacementLanding()', '    private func scheduleUserScrollIdleReset()')
source += between('    private func commitMessageReplacementAfterRelease', '    private func cancelMessageReplacementLanding()')
source += between('    private func applyMessageReplacementLandingCorrection', '    private func finishMessageReplacementAutoFollow')
source += between('    @MainActor\n    private func acknowledgeCodeDisclosureLayout(', '    private func conversationMessageHostID(')
source += '}\n'
source += r'''
@main struct Tests {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); count += 1; print("PASS \(name)")
        }
        let f = Fixture()
        let u = f.add(.user), a = f.add(.assistant), u2 = f.add(.user), a2 = f.add(.assistant)
        f.begin(a)
        check(f.messageReplacementRequest != nil && f.model.deletions.isEmpty,
              "long reply with offscreen predecessor enters release before deletion")
        check(f.messageReplacementRequest?.readingAnchorID == nil,
              "missing real frame is not invented")
        check(f.messageReplacementRequest?.precedingUserID == u.id,
              "offscreen real user ID remains available for landing")
        check(!f.autoFollowEngaged, "old follower yields before data changes")
        f.cancel()
        check(f.model.deletions.count == 1 && f.model.deletions[0].0 == a.id,
              "cancellation before release preserves explicit deletion")
        f.cancel()
        check(f.model.deletions.count == 1, "repeated cancellation does not delete twice")
        f.frames[u2.id] = CGRect(x: 0, y: 180, width: 360, height: 60)
        f.begin(a2, all: true)
        check(f.messageReplacementRequest?.readingAnchorID == u2.id &&
              f.messageReplacementRequest?.readingAnchorMinY == 180,
              "visible preceding user keeps measured reading position")
        f.begin(u)
        check(f.model.deletions.count == 2 && f.model.deletions[1].1,
              "rapid next deletion commits previous all-versions action once")
        check(f.messageReplacementRequest?.message.id == u.id,
              "rapid request replaces only previous viewport ownership")
        f.messageReplacementRequest?.didCommit = true
        f.cancel()
        check(f.model.deletions.count == 2,
              "cancellation after commit cannot repeat model mutation")
        let stream = Fixture(), su = stream.add(.user), sa = stream.add(.assistant)
        stream.model.streaming = true
        stream.begin(sa)
        check(stream.messageReplacementRequest == nil && stream.model.deletions.count == 1,
              "streaming deletion retains existing model stop path")
        stream.interrupted = true; stream.model.streaming = false
        stream.begin(su)
        check(stream.messageReplacementRequest == nil && stream.model.deletions.count == 2,
              "active user motion receives no delayed scroll ownership")
        func drain() async {
            for _ in 0..<8 { await awaitNextMainQueueTurn() }
        }
        let offscreen = Fixture(), recorder = ScrollRecorder()
        let ou = offscreen.add(.user), oa = offscreen.add(.assistant)
        offscreen.begin(oa)
        let oldRequest = offscreen.messageReplacementRequest!
        offscreen.commit(oldRequest.id, anchor: oldRequest.sourceAnchorID, recorder: recorder)
        offscreen.commit(oldRequest.id, anchor: oldRequest.sourceAnchorID, recorder: recorder)
        await drain()
        check(offscreen.model.deletions.count == 1 && recorder.commands.isEmpty,
              "deletion commits but cannot scroll before its bounded row is measured")
        check(offscreen.messageReplacementRequest?.layoutWaitReason == "targetFrameMissing",
              "missing row geometry has an explicit wait reason")
        offscreen.frames[ou.id] = CGRect(x: 0, y: 1000, width: 360, height: 60)
        offscreen.bottomGeometryError = 2000
        offscreen.geometryChanged(recorder)
        check(recorder.commands.isEmpty && offscreen.messageReplacementRequest?.layoutWaitReason == "geometryMismatch",
              "stale bottom geometry cannot authorize a scroll command")
        offscreen.bottomGeometryError = 0
        offscreen.geometryChanged(recorder)
        await drain()
        check(recorder.commands.count == 1 &&
              recorder.commands.first?.0 == AnyHashable(ConversationMessageHostID.message(ou.id)),
              "measured offscreen row uses the direct host after geometry agrees")
        check(recorder.commands.first?.0 != AnyHashable(ou.id),
              "direct lazy host target is distinct from the nested message UUID")
        check(offscreen.messageReplacementRequest != nil,
              "landing is not declared complete without a real visible row")
        offscreen.frames[ou.id] = CGRect(x: 0, y: 740, width: 360, height: 60)
        offscreen.acknowledgeFrame()
        check(offscreen.messageReplacementRequest != nil,
              "row hidden behind composer is not a successful landing")
        check(recorder.commands.first?.1 == .top,
              "offscreen neighbor uses top landing above the composer")
        offscreen.frames[ou.id] = CGRect(x: 0, y: 600, width: 360, height: 60)
        offscreen.bottomGeometryError = 500
        offscreen.acknowledgeFrame()
        check(offscreen.messageReplacementRequest != nil,
              "completion also rejects mismatched row and container geometry")
        offscreen.bottomGeometryError = 0
        offscreen.acknowledgeFrame()
        check(offscreen.messageReplacementRequest == nil && recorder.commands.count == 1,
              "real-row acknowledgement completes without a second writer")
        offscreen.commit(oldRequest.id, anchor: oldRequest.sourceAnchorID, recorder: recorder)
        check(offscreen.model.deletions.count == 1, "completed release callback is inert")
        let waiting = Fixture(), waitingRecorder = ScrollRecorder()
        let wu = waiting.add(.user), wa = waiting.add(.assistant)
        waiting.begin(wa)
        let waitingRequest = waiting.messageReplacementRequest!
        waiting.commit(waitingRequest.id, anchor: waitingRequest.sourceAnchorID, recorder: waitingRecorder)
        await drain()
        waiting.cancel()
        waiting.frames[wu.id] = CGRect(x: 0, y: 1000, width: 360, height: 60)
        waiting.geometryChanged(waitingRecorder)
        check(waiting.model.deletions.count == 1 && waitingRecorder.commands.isEmpty,
              "cancellation while awaiting layout makes later geometry callbacks inert")
        let reconnect = Fixture(), reconnectRecorder = ScrollRecorder()
        let cu = reconnect.add(.user), ca = reconnect.add(.assistant)
        reconnect.begin(ca)
        let reconnectRequest = reconnect.messageReplacementRequest!
        reconnect.commit(reconnectRequest.id, anchor: reconnectRequest.sourceAnchorID, recorder: reconnectRecorder)
        let originalView = reconnect.chatScrollViewBox.scrollView!
        reconnect.chatScrollViewBox.scrollView = nil
        reconnect.frames[cu.id] = CGRect(x: 0, y: 1000, width: 360, height: 60)
        await drain()
        check(reconnect.messageReplacementRequest?.layoutWaitReason == "scrollViewMissing" && reconnectRecorder.commands.isEmpty,
              "temporary probe detachment waits without discarding deletion")
        reconnect.chatScrollViewBox.scrollView = originalView
        reconnect.geometryChanged(reconnectRecorder)
        check(reconnectRecorder.commands.count == 1,
              "probe resolution can advance the same deletion once geometry is ready")
        reconnect.cancel()
        let underflow = Fixture(), underflowRecorder = ScrollRecorder()
        let uu = underflow.add(.user), ua = underflow.add(.assistant)
        underflow.begin(ua)
        let underflowRequest = underflow.messageReplacementRequest!
        underflow.commit(underflowRequest.id, anchor: underflowRequest.sourceAnchorID, recorder: underflowRecorder)
        underflow.chatScrollViewBox.scrollView!.contentSize.height = 800
        underflow.chatScrollViewBox.scrollView!.contentOffset.y = 0
        underflow.bottomGeometryError = -500
        underflow.frames[uu.id] = CGRect(x: 0, y: 100, width: 360, height: 60)
        await drain()
        check(underflowRecorder.commands.count == 1,
              "short transcript accounts for viewport filler after the bottom sentinel")
        let moving = Fixture(), movingRecorder = ScrollRecorder()
        _ = moving.add(.user); let ma = moving.add(.assistant)
        moving.begin(ma)
        let movingRequest = moving.messageReplacementRequest!
        moving.commit(movingRequest.id, anchor: movingRequest.sourceAnchorID, recorder: movingRecorder)
        moving.cancel()
        await drain()
        check(moving.model.deletions.count == 1 && movingRecorder.commands.isEmpty,
              "cancel between model commit and layout prevents all later scrolling")
        let rapid = Fixture(), rapidRecorder = ScrollRecorder()
        let ru = rapid.add(.user), ra = rapid.add(.assistant)
        rapid.begin(ra); let stale = rapid.messageReplacementRequest!
        rapid.begin(ru); let newest = rapid.messageReplacementRequest!.id
        rapid.commit(stale.id, anchor: stale.sourceAnchorID, recorder: rapidRecorder)
        check(rapid.messageReplacementRequest?.id == newest && rapid.model.deletions.count == 1,
              "stale release callback cannot cancel or commit a newer request")
        rapid.cancel()
        let anchored = Fixture(), anchoredRecorder = ScrollRecorder()
        let au = anchored.add(.user), aa = anchored.add(.assistant)
        anchored.frames[au.id] = CGRect(x: 0, y: 200, width: 360, height: 60)
        anchored.begin(aa)
        let anchoredRequest = anchored.messageReplacementRequest!
        anchored.commit(anchoredRequest.id, anchor: anchoredRequest.sourceAnchorID, recorder: anchoredRecorder)
        anchored.frames[au.id] = CGRect(x: 0, y: 300, width: 360, height: 60)
        anchored.chatScrollViewBox.scrollView!.contentOffset.y = 400
        await drain()
        check(anchored.chatScrollViewBox.scrollView!.writes.map(\.y) == [500] &&
              anchoredRecorder.commands.isEmpty,
              "current visible anchor chooses one measured write instead of a proxy command")
        let shrink = Fixture(), shrinkRecorder = ScrollRecorder()
        let hu = shrink.add(.user), ha = shrink.add(.assistant)
        shrink.frames[hu.id] = CGRect(x: 0, y: 200, width: 360, height: 60)
        shrink.begin(ha); let shrinkRequest = shrink.messageReplacementRequest!
        shrink.commit(shrinkRequest.id, anchor: shrinkRequest.sourceAnchorID, recorder: shrinkRecorder)
        shrink.chatScrollViewBox.scrollView!.contentSize.height = 800
        shrink.chatScrollViewBox.scrollView!.contentOffset.y = 9000
        await drain()
        check(shrink.chatScrollViewBox.scrollView!.writes.map(\.y) == [0],
              "large content shrink clamps correction to the current legal range")
        let ids = (0..<12).map { _ in UUID() }
        func target(_ deleted: UUID, _ reading: UUID?, _ user: UUID?, _ surviving: [UUID]) -> UUID? {
            MessageDeletionLandingPolicy.targetID(deletedID: deleted, readingAnchorID: reading,
                precedingUserID: user, sourceIDs: ids, survivingIDs: surviving)
        }
        check(target(ids[5], ids[6], ids[4], ids.filter { $0 != ids[5] }) == ids[6],
              "visible surviving anchor wins over offscreen predecessor")
        check(target(ids[5], nil, ids[4], ids.filter { $0 != ids[5] }) == ids[4],
              "full-screen assistant lands on real predecessor without a frame gate")
        check(target(ids[0], nil, nil, Array(ids.dropFirst())) == ids[1],
              "first user deletion lands on successor")
        check(target(ids[11], nil, nil, Array(ids.dropLast())) == ids[10],
              "last user deletion lands on predecessor")
        check(target(ids[0], nil, nil, []) == nil, "empty transcript issues no target command")
        let replacement = UUID()
        check(target(ids[0], nil, nil, [replacement]) == replacement,
              "single logical row version replacement targets surviving version")
        var exhaustive = 0
        for mask in 0..<4096 {
            let survivors = ids.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element }
            for deleted in ids where !survivors.contains(deleted) {
                let selected = target(deleted, ids[2], ids[4], survivors)
                precondition(selected.map(survivors.contains) ?? survivors.isEmpty)
                exhaustive += 1
            }
        }
        print("PASS \(exhaustive) subset/deletion combinations never target a deleted or absent row")
        do {
        let middle = Fixture()
        middle.currentUIKitBottomState = (false, false)
        let long = middle.add(.assistant)
        var short = ChatMessage(id: UUID(), conversationID: middle.model.selectedConversationID, role: .assistant)
        short.version = 1
        var later = ChatMessage(id: UUID(), conversationID: middle.model.selectedConversationID, role: .assistant)
        later.versionGroupKey = "later"
        middle.model.messages.append(later)
        middle.model.variantMessages = [long, short]
        middle.frames[long.id] = CGRect(x: 0, y: -4400, width: 360, height: 5000)
        middle.beginVersion(long, short)
        let middleRequest = middle.messageReplacementRequest!
        check(middle.model.versionWrites.isEmpty && !middleRequest.keepsExactBottom,
              "middle version owns native release without forcing bottom")
        check(middleRequest.readingAnchorMaxY == 600 && middleRequest.replacementMessage?.id == short.id,
              "middle long-to-short captures the clicked reply edge and new identity")
        let versionRecorder = ScrollRecorder()
        middle.commit(middleRequest.id, anchor: middleRequest.sourceAnchorID, recorder: versionRecorder)
        await awaitNextMainQueueTurn(); await Task.yield()
        check(middle.model.versionWrites == [1] && middle.model.messages[0].id == short.id,
              "version commit selects new reply exactly once")
        check(versionRecorder.commands.isEmpty && middle.chatScrollViewBox.scrollView!.writes.isEmpty,
              "version waits for a concrete new frame before positioning")
        middle.frames[short.id] = CGRect(x: 0, y: 400, width: 360, height: 80)
        middle.geometryChanged(versionRecorder)
        check(middle.chatScrollViewBox.scrollView!.writes.last?.y == 680 && versionRecorder.commands.isEmpty,
              "middle short version uses one native correction to retain footer at 600")
        check(middle.messageReplacementRequest != nil,
              "visible but not-yet-corrected version frame cannot finish early")
        middle.frames[short.id] = CGRect(x: 0, y: 520, width: 360, height: 80)
        middle.geometryChanged(versionRecorder)
        check(middle.messageReplacementRequest == nil,
              "middle version completes after the target edge actually matches")
        middle.beginVersion(short, long)
        let back = middle.messageReplacementRequest!
        middle.commit(back.id, anchor: back.sourceAnchorID, recorder: versionRecorder)
        // Do not reuse the old variant's stale rectangle as its newly rendered frame.
        middle.frames.removeValue(forKey: long.id)
        await awaitNextMainQueueTurn(); await Task.yield()
        middle.chatScrollViewBox.scrollView!.contentSize.height = 8000
        middle.frames[long.id] = CGRect(x: 0, y: 0, width: 360, height: 5000)
        middle.geometryChanged(versionRecorder)
        check(middle.chatScrollViewBox.scrollView!.writes.last?.y == 5080,
              "middle short-to-long preserves the same reading edge")
        middle.frames[long.id] = CGRect(x: 0, y: -4400, width: 360, height: 5000)
        middle.geometryChanged(versionRecorder)
        check(middle.messageReplacementRequest == nil && middle.model.versionWrites == [1, 0],
              "reverse version selection also completes without a second proxy writer")

        let tailVersion = Fixture()
        let tailLong = tailVersion.add(.assistant)
        var tailShort = ChatMessage(id: UUID(), conversationID: tailVersion.model.selectedConversationID, role: .assistant)
        tailShort.version = 1
        tailVersion.model.variantMessages = [tailLong, tailShort]
        tailVersion.frames[tailLong.id] = CGRect(x: 0, y: -4200, width: 360, height: 5000)
        tailVersion.beginVersion(tailLong, tailShort)
        let tailRequest = tailVersion.messageReplacementRequest!
        check(tailRequest.keepsExactBottom, "true-bottom tail version retains exact-bottom policy")
        tailVersion.commit(tailRequest.id, anchor: tailRequest.sourceAnchorID, recorder: versionRecorder)
        await awaitNextMainQueueTurn(); await Task.yield()
        tailVersion.chatScrollViewBox.scrollView!.contentSize.height = 800
        tailVersion.frames[tailShort.id] = CGRect(x: 0, y: -780, width: 360, height: 80)
        tailVersion.geometryChanged(versionRecorder)
        check(tailVersion.chatScrollViewBox.scrollView!.contentOffset.y == 0,
              "tail shortening lands at the new legal bottom, not the old long offset")
        tailVersion.frames[tailShort.id] = CGRect(x: 0, y: 20, width: 360, height: 80)
        tailVersion.geometryChanged(versionRecorder)
        check(tailVersion.messageReplacementRequest == nil, "short underflow tail confirms actual bottom")

        var resized = tailRequest
        resized.landingAnchorID = tailVersion.currentConversationBottomAnchorID
        resized.targetMessageID = tailShort.id
        resized.keepsExactBottom = false
        resized.readingAnchorMaxY = 600
        tailVersion.scrollViewportHeight = 500
        check(tailVersion.desiredVersionMinY(resized) == 310,
              "reading edge adapts to a smaller current viewport instead of retaining an offscreen destination")

        let rapid = Fixture()
        rapid.currentUIKitBottomState = (false, false)
        let ra = rapid.add(.assistant)
        var rb = ChatMessage(id: UUID(), conversationID: rapid.model.selectedConversationID, role: .assistant); rb.version = 1
        var rc = ChatMessage(id: UUID(), conversationID: rapid.model.selectedConversationID, role: .assistant); rc.version = 2
        rapid.model.variantMessages = [ra, rb, rc]
        rapid.frames[ra.id] = CGRect(x: 0, y: 100, width: 360, height: 400)
        rapid.beginVersion(ra, rb)
        let prior = rapid.messageReplacementRequest!
        rapid.beginVersion(ra, rc)
        let current = rapid.messageReplacementRequest!
        check(rapid.model.versionWrites == [1] && current.readingAnchorMaxY == 500,
              "rapid newer tap preserves intent and prior reading edge across an unpublished frame")
        rapid.commit(prior.id, anchor: prior.sourceAnchorID, recorder: versionRecorder)
        check(rapid.messageReplacementRequest?.id == current.id && rapid.model.versionWrites == [1],
              "stale native release cannot consume the newer version request")
        rapid.commit(current.id, anchor: current.sourceAnchorID, recorder: versionRecorder)
        check(rapid.model.versionWrites == [1, 2] && rapid.model.messages.first?.id == rc.id,
              "latest rapid version choice is committed once")
        rapid.cancel(); rapid.frames[rc.id] = CGRect(x: 0, y: 100, width: 360, height: 100)
        rapid.geometryChanged(versionRecorder)
        check(rapid.chatScrollViewBox.scrollView!.writes.isEmpty,
              "user cancellation after version commit blocks every delayed viewport write")
        let beforeInvalid = rapid.model.versionWrites
        var wrongGroup = rb; wrongGroup.versionGroupKey = "other"
        rapid.beginVersion(rc, wrongGroup)
        check(rapid.messageReplacementRequest == nil && rapid.model.versionWrites == beforeInvalid,
              "invalid cross-group replacement creates no viewport or model mutation")
        }

        do {
        // Code disclosure is a display-only edit of the same message identity.
        let fold = Fixture(), fs = CodeBlockDisclosureState()
        let fm = fold.add(.assistant), fr = ScrollRecorder()
        fold.currentUIKitBottomState = (false, false)
        fold.chatScrollViewBox.scrollView!.contentSize.height = 2000
        fold.chatScrollViewBox.scrollView!.contentOffset.y = 500
        fold.frames[fm.id] = CGRect(x: 0, y: 350, width: 320, height: 500)
        fs.setExpanded(true)
        fold.beginFold(fm, state: fs, expanded: false)
        let foldRequest = fold.messageReplacementRequest!
        check(fs.manualExpansion == true && fs.pendingExpansion == false && fs.layoutRequestID == nil,
              "fold waits for native release before changing text height")
        fold.commit(foldRequest.id, anchor: foldRequest.sourceAnchorID, recorder: fr)
        check(fs.manualExpansion == false && fs.layoutRequestID == foldRequest.id,
              "released fold commits display state and new layout token")
        check(fold.model.deletions.isEmpty && fold.model.versionWrites.isEmpty && fold.model.messages.map(\.id) == [fm.id],
              "fold never deletes, replaces or persists a message")
        fold.geometryChanged(fr)
        check(fold.messageReplacementRequest?.didIssueLanding == false && fold.chatScrollViewBox.scrollView!.writes.isEmpty,
              "same-ID old row geometry cannot acknowledge new fold")
        fs.anchor.contentFrame.size.height = 80
        let codeFrame = CGRect(x: 0, y: 350, width: 320, height: 80)
        fold.codeGeometry([UUID(): codeFrame], fr)
        check(fold.messageReplacementRequest?.codeLayoutSize == nil, "stale fold UUID is rejected")
        fold.codeGeometry([foldRequest.id: .zero], fr)
        check(fold.messageReplacementRequest?.codeLayoutSize == nil, "zero code frame is rejected")
        fold.staleMessageLayout = true
        fold.codeGeometry([foldRequest.id: codeFrame], fr)
        check(fold.messageReplacementRequest?.didIssueLanding == false,
              "new code geometry cannot combine with an old message frame")
        fold.staleMessageLayout = false
        fold.staleBottomLayout = true
        fold.geometryChanged(fr)
        check(fold.messageReplacementRequest?.didIssueLanding == false,
              "new code and message geometry cannot combine with an old bottom frame")
        fold.staleBottomLayout = false
        fs.anchor.contentFrame.size.height = 450
        fold.geometryChanged(fr)
        check(fold.messageReplacementRequest?.didIssueLanding == false,
              "new SwiftUI code size cannot acknowledge an old native anchor surface")
        fs.anchor.contentFrame.size.height = 80
        fold.bottomGeometryError = 2001
        fold.codeGeometry([foldRequest.id: codeFrame], fr)
        check(fold.messageReplacementRequest?.didIssueLanding == false,
              "captured 2001-point phantom extent cannot qualify for landing")
        fold.bottomGeometryError = 0
        check(fold.chatScrollViewBox.scrollView!.paintRefreshes == 0,
              "unacknowledged code, row and bottom layouts never refresh prose prematurely")
        fold.geometryChanged(fr)
        fold.acknowledgeFrame()
        fold.acknowledgeFrame()
        check(fold.chatScrollViewBox.scrollView!.paintRefreshes == 1,
              "an acknowledged fold refreshes prose once before releasing its request")
        check(abs(fold.chatScrollViewBox.scrollView!.contentOffset.y - 130) < 0.01,
              "middle footer collapse keeps the tapped code edge")
        check(fold.messageReplacementRequest == nil && fs.layoutRequestID == nil && fs.pendingExpansion == nil,
              "measured landing releases fold preference and ownership")
        check(fr.commands.isEmpty && fold.chatScrollViewBox.scrollView!.writes.count == 1,
              "fold uses one physical correction and no proxy fallback")

        for edge in [ChatContentMutationAnchorEdge.header, .footer] {
            let q = Fixture(), state = CodeBlockDisclosureState(), rec = ScrollRecorder()
            let msg = q.add(.assistant)
            q.currentUIKitBottomState = (false, false)
            q.model.hasLaterMessages = true
            q.chatScrollViewBox.scrollView!.contentSize.height = 2000
            q.chatScrollViewBox.scrollView!.contentOffset.y = 500
            q.frames[msg.id] = CGRect(x: 0, y: 350, width: 320, height: 500)
            state.setExpanded(true)
            q.beginFold(msg, state: state, expanded: false, edge: edge)
            let req = q.messageReplacementRequest!
            check(!req.keepsExactBottom, "historical fold never claims conversation bottom")
            q.commit(req.id, anchor: req.sourceAnchorID, recorder: rec)
            state.anchor.contentFrame.size.height = 80
            q.codeGeometry([req.id: codeFrame], rec); q.acknowledgeFrame()
            let expected: CGFloat = edge == .header ? 500 : 130
            check(abs(q.chatScrollViewBox.scrollView!.contentOffset.y - expected) < 0.01,
                  "history header/footer keeps its selected edge")
            check(q.model.messages.map(\.id) == [msg.id] && q.messageReplacementRequest == nil,
                  "history fold retains canonical row and completes")
            check(q.chatScrollViewBox.scrollView!.paintRefreshes == 1,
                  "header and footer landings both refresh the current prose viewport")
        }

        let bottomFold = Fixture(), bs = CodeBlockDisclosureState(), br = ScrollRecorder()
        let bm = bottomFold.add(.assistant)
        bottomFold.frames[bm.id] = CGRect(x: 0, y: 100, width: 320, height: 600)
        bs.setExpanded(true)
        bottomFold.beginFold(bm, state: bs, expanded: false)
        let bq = bottomFold.messageReplacementRequest!
        check(bq.keepsExactBottom, "actual bottom fold uses shared bottom policy")
        bottomFold.commit(bq.id, anchor: bq.sourceAnchorID, recorder: br)
        bottomFold.chatScrollViewBox.scrollView!.contentSize.height = 1400
        bs.anchor.contentFrame.size.height = 80
        bottomFold.codeGeometry([bq.id: codeFrame], br); bottomFold.acknowledgeFrame()
        check(bottomFold.chatScrollViewBox.scrollView!.contentOffset.y == 600 && bottomFold.messageReplacementRequest == nil,
              "bottom fold lands on legal actual bottom")

        let reverseFold = Fixture(), rs = CodeBlockDisclosureState(), rr = ScrollRecorder()
        let rm = reverseFold.add(.assistant)
        rs.setExpanded(true)
        reverseFold.beginFold(rm, state: rs, expanded: false)
        let firstFold = reverseFold.messageReplacementRequest!
        reverseFold.currentUIKitBottomState = (false, false)
        reverseFold.hasCurrentConcreteLatestBottomContent = false
        reverseFold.beginFold(rm, state: rs, expanded: true)
        let reversedFold = reverseFold.messageReplacementRequest!
        check(reversedFold.id != firstFold.id && reversedFold.keepsExactBottom && reversedFold.sourceWasAutoFollowEngaged,
              "rapid same-block reversal inherits original bottom and follow intent")
        reverseFold.commit(firstFold.id, anchor: firstFold.sourceAnchorID, recorder: rr)
        check(rs.manualExpansion == true && rs.pendingExpansion == true,
              "superseded release cannot commit an old target expansion")
        reverseFold.commit(reversedFold.id, anchor: reversedFold.sourceAnchorID, recorder: rr)
        reverseFold.cancel()
        check(rs.manualExpansion == true && rs.layoutRequestID == nil,
              "rapid reversal retains final explicit display state")

        let cancelFold = Fixture(), cs = CodeBlockDisclosureState(), cr = ScrollRecorder()
        let cm = cancelFold.add(.assistant)
        cs.setExpanded(true)
        cancelFold.beginFold(cm, state: cs, expanded: false)
        let stale = cancelFold.messageReplacementRequest!
        cancelFold.cancel()
        check(cs.manualExpansion == true && cs.pendingExpansion == nil && cs.layoutRequestID == nil,
              "drag before commit cancels display intent without mutating lazy height")
        cancelFold.commit(stale.id, anchor: stale.sourceAnchorID, recorder: cr)
        check(cs.manualExpansion == true && cancelFold.model.deletions.isEmpty,
              "old native release cannot revive a cancelled fold")
        cancelFold.beginFold(cm, state: cs, expanded: false)
        let current = cancelFold.messageReplacementRequest!
        cancelFold.commit(current.id, anchor: current.sourceAnchorID, recorder: cr)
        cancelFold.cancel()
        check(cs.manualExpansion == false && cs.layoutRequestID == nil,
              "drag after commit keeps chosen disclosure and releases ownership")
        cancelFold.codeGeometry([current.id: codeFrame], cr)
        check(cancelFold.messageReplacementRequest == nil && cr.commands.isEmpty,
              "late code geometry after cancellation does not move viewport")

        for reason in 1..<4 {
            let blocked = Fixture(), state = CodeBlockDisclosureState()
            let msg = blocked.add(.assistant)
            state.setExpanded(true)
            if reason == 1 { blocked.hasContentMutationCompetingOwner = true }
            if reason == 2 { blocked.interrupted = true }
            if reason == 3 { state.anchor.hasFrame = false }
            blocked.beginFold(msg, state: state, expanded: false)
            check(blocked.messageReplacementRequest == nil && state.manualExpansion == true,
                  "competing owner, motion and detached anchor reject height mutation")
        }


        do {
        let live = Fixture(), state = CodeBlockDisclosureState(), rec = ScrollRecorder()
        var msg = live.add(.assistant)
        msg.text = "partial code"; msg.isStreaming = true; live.model.messages[0] = msg
        live.model.streaming = true
        live.model.rawStreamingTextByMessageID[msg.id] = "partial code plus received tokens"
        live.frames[msg.id] = CGRect(x: 0, y: 100, width: 320, height: 600)
        state.setExpanded(false)
        let initialFeedback = state.feedbackGeneration
        live.model.onResume = { check(live.autoFollowEngaged, "bottom follow rejoins before buffered text resumes") }
        live.beginFold(msg, state: state, expanded: true)
        let req = live.messageReplacementRequest!
        check(req.keepsExactBottom && req.streamingMessage?.id == msg.id,
              "streaming expansion enters shared bottom handoff")
        check(live.model.streamDisplaySuspensionLedgersByMessageID[msg.id]?.contains(.codeDisclosure(req.id)) == true,
              "fold acquires one token-scoped owner in existing display ledger")
        check(state.manualExpansion == false && state.feedbackGeneration == initialFeedback,
              "admission alone changes neither height nor feedback")
        live.model.messages[0].text = "completion or reasoning/tool update"
        live.model.messages[0].isStreaming = false
        check(live.displayMessages()[0].text == "partial code" && live.displayMessages()[0].isStreaming,
              "completion and non-text model updates cannot change held layout")
        check(live.model.messages[0].text == "completion or reasoning/tool update",
              "holding display never rewinds authoritative model")
        live.commit(req.id, anchor: req.sourceAnchorID, recorder: rec)
        check(state.manualExpansion == true && state.feedbackGeneration == initialFeedback,
              "streaming expansion commits without prematurely animating")
        live.chatScrollViewBox.scrollView!.contentSize.height = 2400
        state.anchor.contentFrame.size.height = 1200
        live.codeGeometry([req.id: CGRect(x: 0, y: 100, width: 320, height: 1200)], rec)
        live.acknowledgeFrame()
        check(live.messageReplacementRequest == nil && live.autoFollowEngaged,
              "streaming fold lands and releases shared position ownership")
        check(live.model.resumed == [msg.id] && live.model.streamDisplaySuspensionLedgersByMessageID[msg.id] == nil,
              "successful handoff resumes the existing text cadence once")
        check(live.displayMessages()[0].text == live.model.messages[0].text && !live.displayMessages()[0].isStreaming,
              "completion becomes visible immediately after handoff")
        check(state.feedbackGeneration == initialFeedback + 1,
              "only acknowledged user disclosure triggers one feedback pulse")
        live.model.messages[0].text += " later batch"
        live.acknowledgeFrame(); state.finish(req.id, didLand: true)
        check(state.feedbackGeneration == initialFeedback + 1 && live.model.resumed.count == 1,
              "later stream batches and stale completion cannot replay feedback or resume")
        check(live.model.rawStreamingTextByMessageID[msg.id] == "partial code plus received tokens",
              "fold suspension preserves the received text buffer")

        for committed in [false, true] {
            let q = Fixture(), st = CodeBlockDisclosureState(), r = ScrollRecorder()
            let m = q.add(.assistant); q.model.streaming = true
            q.model.rawStreamingTextByMessageID[m.id] = "still receiving"
            st.setExpanded(false); let feedback = st.feedbackGeneration
            q.beginFold(m, state: st, expanded: true)
            let pending = q.messageReplacementRequest!
            if committed { q.commit(pending.id, anchor: pending.sourceAnchorID, recorder: r) }
            q.cancel()
            q.commit(pending.id, anchor: pending.sourceAnchorID, recorder: r)
            check(q.model.streamDisplaySuspensionLedgersByMessageID[m.id] == nil && q.model.resumed == [m.id],
                  "interruption before/after commit releases the stream owner once")
            check(!q.autoFollowEngaged && st.feedbackGeneration == feedback,
                  "interruption never reattaches following or replays a completion fade")
        }

        let complete = Fixture(), cs = CodeBlockDisclosureState(), cr = ScrollRecorder()
        let cm = complete.add(.assistant); complete.model.streaming = true
        complete.beginFold(cm, state: cs, expanded: true)
        let cq = complete.messageReplacementRequest!
        complete.model.streaming = false
        complete.model.streamDisplaySuspensionLedgersByMessageID.removeAll()
        complete.model.messages[0].text = "final reply"
        complete.frames[cm.id] = CGRect(x: 0, y: 100, width: 320, height: 600)
        complete.commit(cq.id, anchor: cq.sourceAnchorID, recorder: cr)
        cs.anchor.contentFrame.size.height = 450
        complete.codeGeometry([cq.id: CGRect(x: 0, y: 100, width: 320, height: 450)], cr)
        complete.acknowledgeFrame()
        check(complete.messageReplacementRequest == nil && complete.displayMessages()[0].text == "final reply",
              "provider completion during handoff needs no further streaming event to finish")
        check(complete.model.resumed.isEmpty && complete.model.streamDisplaySuspensionLedgersByMessageID.isEmpty,
              "finishing an ended stream cannot restart a display task")

        let history = Fixture(), hs = CodeBlockDisclosureState()
        let older = history.add(.assistant), tail = history.add(.assistant)
        history.model.streaming = true; history.model.rawStreamingTextByMessageID[tail.id] = "live tail"
        history.beginFold(older, state: hs, expanded: true)
        let hq = history.messageReplacementRequest!
        check(hq.streamingMessage?.id == tail.id && hq.message.id == older.id,
              "folding a completed earlier block holds only the active streaming tail")
        history.model.setStreamingTextDisplaySuspended(conversationID: tail.conversationID, messageID: tail.id, owner: .drawer, suspended: true)
        history.cancel()
        check(history.model.resumed.isEmpty && history.model.streamDisplaySuspensionLedgersByMessageID[tail.id]?.contains(.drawer) == true,
              "ending a fold cannot release the drawer's independent suspension")
        history.model.setStreamingTextDisplaySuspended(conversationID: tail.conversationID, messageID: tail.id, owner: .drawer, suspended: false)
        check(history.model.resumed == [tail.id], "last existing owner resumes normally")

        let rapidStream = Fixture(), rs = CodeBlockDisclosureState()
        let rm = rapidStream.add(.assistant); rapidStream.model.streaming = true
        rapidStream.beginFold(rm, state: rs, expanded: true)
        let old = rapidStream.messageReplacementRequest!
        rapidStream.beginFold(rm, state: rs, expanded: false)
        let newest = rapidStream.messageReplacementRequest!
        rapidStream.model.setStreamingTextDisplaySuspended(conversationID: rm.conversationID, messageID: rm.id, owner: .codeDisclosure(old.id), suspended: false)
        check(rapidStream.model.streamDisplaySuspensionLedgersByMessageID[rm.id]?.contains(.codeDisclosure(newest.id)) == true,
              "a stale fold release cannot resume the next request")
        rapidStream.model.messages.removeAll()
        check(rapidStream.displayMessages().isEmpty, "held display never resurrects a removed message")
        rapidStream.cancel()
        check(rapidStream.model.streamDisplaySuspensionLedgersByMessageID.isEmpty,
              "removed message and changed stream identity still release fold ownership")
        }

        let store = CodeDisclosureStore()
        let scope = MessageContentMutationScope(conversationID: UUID(), messageID: UUID(), region: .messageText(0))
        let one = store.state(for: scope, blockID: 1)
        one.setExpanded(false)
        check(store.state(for: scope, blockID: 1) === one && store.state(for: scope, blockID: 1).manualExpansion == false,
              "same block retains display state across host replacement")
        check(store.state(for: scope, blockID: 2) !== one, "different code blocks remain independent")
        let otherRegion = MessageContentMutationScope(conversationID: scope.conversationID,
            messageID: scope.messageID, region: .reasoning(UUID()))
        check(store.state(for: otherRegion, blockID: 1) !== one, "reasoning/text block namespaces remain distinct")
        store.retain(messageIDs: [])
        check(store.state(for: scope, blockID: 1) !== one, "paging releases state outside the loaded window")
        let oldToken = UUID(), newToken = UUID()
        one.prepare(oldToken, expanded: true); one.prepare(newToken, expanded: false)
        one.commit(oldToken); one.finish(oldToken)
        check(one.pendingExpansion == false && one.layoutRequestID == nil, "old state callback cannot finish a newer request")
        one.commit(newToken); one.finish(newToken)
        check(one.manualExpansion == false && one.pendingExpansion == nil, "latest display intent commits once")
        store.removeAll()
        check(store.state(for: scope, blockID: 1) !== one, "conversation switch releases display state")

        let previewInputs = ["", "a", "a\nb\nc", "a\r\nb\r\nc", "\n\n\n", "蜜蜂🐝\ne\u{301}\n👩‍💻\nlast", String(repeating: "long 🐝 line\n", count: 4000)]
        for text in previewInputs {
            for limit in [1, 2, 3, 16, 32] {
                let expected = text.components(separatedBy: "\n").prefix(limit).joined(separator: "\n")
                check(CodeBlockPreview.text(text, lineLimit: limit) == expected,
                      "bounded preview preserves previous visible text including Unicode and CRLF")
            }
        }
        }
        print("PASS \(count) behavior checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='mocca-deletion-4987-') as d:
    swift = Path(d)/'DeletionTests.swift'; swift.write_text(source)
    exe = Path(d)/'checks'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','6',str(swift),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
