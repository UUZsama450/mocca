"""Run production navigation cancellation methods and real SwiftUI ScrollPosition.

Lifecycle/gesture delivery and UIScrollView animation are not emulated. Device
interruption acceptance is separate. No app data or provider requests are used.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'Mocca/RootView.swift').read_text()
def between(start, end):
    a = s.index(start)
    return s[a:s.index(end, a)]
source = r"""import Foundation
import SwiftUI
struct ConversationPositionRequestKey: Equatable {
    var conversationID = UUID()
    var request = 1
}
struct ConversationBottomAnchorID: Equatable {
    var positionRequest: ConversationPositionRequestKey
}
enum ChatBottomTrace { static func log(_ value: String) {} }
"""
source += between('private enum MessageNavigationAction:', '// The same conversation')
source += r"""
@MainActor private final class Fixture {
    var currentConversationPositionRequest = ConversationPositionRequestKey()
    var navigationRequest: MessageNavigationRequest?
    var pendingNavigationRequest: MessageNavigationRequest?
    var navigationScrollTask: Task<Void, Never>?
    var pendingNavigationPromotionTask: Task<Void, Never>?
    var navigationAnchorMessageID: UUID? = UUID()
    var lastKnownNearBottom = true
    var lastMeasuredNearBottom = true
    var lastMeasuredAtBottom = true
    var isUserScrollActive = false
    var autoFollowEngaged = true
    var keyboardBottomFollowIntent = true
    var isNativeVerticalScrollMotionArmed = true
    var chatBottomTraceState: String { "" }
    var stopRequests = 0
    var stopObservedDetached = false
    func interruptNativeScrollMotion() {
        stopRequests += 1
        stopObservedDetached = !autoFollowEngaged && isUserScrollActive
            && navigationRequest == nil && pendingNavigationRequest == nil
    }
    func request(_ sequence: Int, _ action: MessageNavigationAction = .bottom) -> MessageNavigationRequest {
        MessageNavigationRequest(sequence: sequence,
            positionRequest: currentConversationPositionRequest, action: action)
    }
"""
source += between('    private func cancelPendingMessageNavigation()',
                  '    private func schedulePendingMessageNavigationPromotion()').replace('private func', 'func')
source += between('    private var currentEdgeNavigationSequence:',
                  '    private var hasCurrentConcreteLatestBottomContent:').replace('private var', 'var')
source += r"""
}
@MainActor private final class NativeFixture {
    var position = ScrollPosition(edge: .bottom)
    var keyboardDismissalFallbackTask: Task<Void, Never>?
    var keyboardDismissalGeometrySuppressionDeadline = Date.now
    var locallyClaimedAutomaticReasoningCollapseOwnerID: Int? = 1
    var shouldPinToBottom = false
    enum Phase { case tracking, interacting, animating, idle, decelerating }
    var edgeNavigationSequence: Int?
    var bottomAnchorID = ConversationBottomAnchorID(positionRequest: ConversationPositionRequestKey())
    var onEdgeNavigationUserTouch: (ConversationBottomAnchorID, Int) -> Bool = { _, _ in false }
    var streamingPauseCalls = 0
    func beginStreamingFollowTouchPauseIfNeeded() { streamingPauseCalls += 1 }
    var chatBottomTracePosition: String { "" }
"""
source += between('    private func releaseInterruptedEdgeNavigationPosition()',
                  '    private func beginStreamingFollowTouchPauseIfNeeded()').replace('private func', 'func')
observer = between('            .onChange(of: edgeNavigationSequence)',
                   '            .onChange(of: sendPositionReleaseID)')
source += observer.replace('.onChange(of: edgeNavigationSequence) { oldSequence, newSequence in',
                          'func sequenceChanged(oldSequence: Int?, newSequence: Int?) {')
phase = between('                if newPhase == .tracking || newPhase == .interacting {',
                '                switch newPhase {')
source += 'func phaseChanged(_ newPhase: Phase) {\n' + phase + '}\n'
source += r"""
}
@main struct Tests {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1; print("PASS \(label)")
        }
        for action in [MessageNavigationAction.bottom, .top, .nextUserMessage] {
            for reason in ["transcriptTap", "userDrag", "drawerPresented"] {
                let f = Fixture()
                f.navigationRequest = f.request(1, action)
                let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
                f.navigationScrollTask = task
                f.cancelMessageNavigationForUserInteraction(reason: reason)
                check(task.isCancelled && f.navigationScrollTask == nil && f.navigationRequest == nil,
                      "\(action) \(reason): cancels worker and request")
                check(!f.autoFollowEngaged && f.isUserScrollActive && !f.keyboardBottomFollowIntent
                    && !f.lastKnownNearBottom && !f.lastMeasuredAtBottom && !f.lastMeasuredNearBottom,
                      "\(action) \(reason): detached with no stale bottom facts")
                check(f.stopRequests == 1 && f.stopObservedDetached && f.navigationAnchorMessageID == nil,
                      "\(action) \(reason): detach precedes native idle callback")
                f.cancelMessageNavigationForUserInteraction(reason: reason)
                check(f.stopRequests == 1, "\(action) \(reason): repeated event is a no-op")
            }
        }
        let pending = Fixture()
        pending.pendingNavigationRequest = pending.request(10)
        let watcher = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        pending.pendingNavigationPromotionTask = watcher
        pending.cancelMessageNavigationForUserInteraction(reason: "drawerPresented")
        check(watcher.isCancelled && pending.pendingNavigationRequest == nil
            && pending.pendingNavigationPromotionTask == nil, "pending request cannot promote after cancellation")
        let f = Fixture()
        f.navigationRequest = f.request(20)
        let anchor = ConversationBottomAnchorID(positionRequest: f.currentConversationPositionRequest)
        check(f.interruptEdgeNavigationForNativeTouch(anchor, sequence: 20), "touch cancels active bottom before drag threshold")
        check(!f.interruptEdgeNavigationForNativeTouch(anchor, sequence: 20), "second phase cannot cancel twice")
        f.navigationRequest = f.request(21, .top)
        check(!f.interruptEdgeNavigationForNativeTouch(anchor, sequence: 20)
            && f.navigationRequest?.sequence == 21, "stale touch cannot cancel a replacement request")
        let oldConversation = ConversationBottomAnchorID(positionRequest: ConversationPositionRequestKey())
        check(!f.interruptEdgeNavigationForNativeTouch(oldConversation, sequence: 21), "old conversation touch is ignored")
        var oldReturn = anchor
        oldReturn.positionRequest.request -= 1
        check(!f.interruptEdgeNavigationForNativeTouch(oldReturn, sequence: 21), "old return generation touch is ignored")
        check(f.interruptEdgeNavigationForNativeTouch(anchor, sequence: 21), "new top request remains independently cancellable")
        f.navigationRequest = f.request(22, .previousUserMessage)
        check(f.currentEdgeNavigationSequence == nil
            && !f.interruptEdgeNavigationForNativeTouch(anchor, sequence: 22), "early native hook leaves adjacent navigation unchanged")
        f.navigationRequest = nil
        f.pendingNavigationRequest = f.request(23)
        check(!f.interruptEdgeNavigationForNativeTouch(anchor, sequence: 23), "pre-existing finger does not discard a queued explicit request")
        let idle = Fixture()
        idle.cancelMessageNavigationForUserInteraction(reason: "userDrag")
        check(idle.autoFollowEngaged && !idle.isUserScrollActive && idle.stopRequests == 0,
              "ordinary scroll with no navigation keeps existing policy")

        let touchOwner = Fixture()
        touchOwner.navigationRequest = touchOwner.request(30)
        let touchNative = NativeFixture()
        touchNative.edgeNavigationSequence = 30
        touchNative.bottomAnchorID = ConversationBottomAnchorID(positionRequest: touchOwner.currentConversationPositionRequest)
        touchNative.onEdgeNavigationUserTouch = touchOwner.interruptEdgeNavigationForNativeTouch
        touchNative.phaseChanged(.animating)
        check(touchOwner.navigationRequest != nil && touchNative.position.edge == .bottom,
              "normal programmatic phase does not interrupt navigation")
        touchNative.phaseChanged(.tracking)
        check(touchOwner.navigationRequest == nil && !touchOwner.autoFollowEngaged
            && touchNative.position.isPositionedByUser, "actual native tracking branch releases both owners")
        touchOwner.navigationRequest = touchOwner.request(31)
        touchNative.position = ScrollPosition(edge: .bottom)
        touchNative.phaseChanged(.interacting)
        check(touchOwner.navigationRequest?.sequence == 31 && touchNative.position.edge == .bottom,
              "stale native phase cannot release a new navigation's position")
        touchNative.edgeNavigationSequence = nil
        touchNative.phaseChanged(.tracking)
        check(touchNative.position.edge == .bottom && touchNative.streamingPauseCalls == 3,
              "ordinary tracking retains the pre-existing streaming pause callback")

        let native = NativeFixture()
        let fallback = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        native.keyboardDismissalFallbackTask = fallback
        native.sequenceChanged(oldSequence: 1, newSequence: nil)
        check(native.position.isPositionedByUser && native.position.edge == nil && native.position.point == nil,
              "real ScrollPosition releases retained bottom on cancellation")
        check(fallback.isCancelled && native.keyboardDismissalFallbackTask == nil
            && native.keyboardDismissalGeometrySuppressionDeadline == .distantPast
            && native.locallyClaimedAutomaticReasoningCollapseOwnerID == nil, "release cancels stale native fallback")
        native.position = ScrollPosition(y: 1234)
        native.releaseInterruptedEdgeNavigationPosition()
        check(native.position.point == nil && native.position.isPositionedByUser, "real ScrollPosition releases a retained point")
        native.position = ScrollPosition(id: "tail-row", anchor: .bottom)
        native.releaseInterruptedEdgeNavigationPosition()
        check(native.position.viewID(type: String.self) == nil && native.position.isPositionedByUser,
              "real ScrollPosition releases a retained row target")
        native.position = ScrollPosition(edge: .bottom)
        native.shouldPinToBottom = true
        native.sequenceChanged(oldSequence: 2, newSequence: nil)
        check(native.position.edge == .bottom && !native.position.isPositionedByUser,
              "successful bottom landing preserves normal follow")
        native.shouldPinToBottom = false
        native.sequenceChanged(oldSequence: 2, newSequence: 3)
        check(native.position.edge == .bottom, "replacement request is not treated as cancellation")
        native.sequenceChanged(oldSequence: nil, newSequence: nil)
        check(native.position.edge == .bottom, "ordinary modifier update does not release position")
        print("PASS \(count) checks; gesture delivery and device visuals remain separate")
    }
}
"""
with tempfile.TemporaryDirectory(prefix='mocca-navigation-interruption-') as tmp:
    path = Path(tmp) / 'check.swift'; path.write_text(source)
    binary = Path(tmp) / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
