import Foundation
import Observation
import SwiftUI
import UIKit

/// Ordinary edits retain the viewport session; navigation and paging replace it.
struct ChatViewportSessionID: Hashable {
    let conversationID: UUID
    let positionRequest: Int
    let lazyWindowGeneration: UInt64
}

enum MessageContentMutationRegionID: Hashable {
    case wholeMessage
    case messageText(Int)
    case reasoning(UUID)
}

struct MessageContentMutationScope: Hashable {
    let conversationID: UUID
    let messageID: UUID
    let region: MessageContentMutationRegionID
}

enum ChatContentMutationAnchorEdge: String, Hashable {
    case header
    case footer

    func position(in frame: CGRect) -> CGFloat {
        self == .header ? frame.minY : frame.maxY
    }
}

enum CodeBlockPreview {
    /// Preserve the original LF-delimited preview, including CRLF and Unicode,
    /// without allocating an array for every line in the hidden tail.
    static func text(_ source: String, lineLimit: Int) -> String {
        let bytes = source.utf8
        var lines = 0
        for index in bytes.indices where bytes[index] == 10 {
            lines += 1
            if lines == max(1, lineLimit) {
                return String(decoding: bytes[..<index], as: UTF8.self)
            }
        }
        return source
    }
}

private struct CodeDisclosureKey: Hashable {
    let scope: MessageContentMutationScope
    let blockID: Int
}

/// Display-only state survives a lazy-to-concrete host change. It is discarded
/// on conversation switches and never becomes part of the saved transcript.
@MainActor
final class CodeDisclosureStore {
    private var states: [CodeDisclosureKey: CodeBlockDisclosureState] = [:]

    func state(for scope: MessageContentMutationScope, blockID: Int) -> CodeBlockDisclosureState {
        let key = CodeDisclosureKey(scope: scope, blockID: blockID)
        if let state = states[key] { return state }
        let state = CodeBlockDisclosureState()
        states[key] = state
        return state
    }

    func removeAll() { states.removeAll() }

    func retain(messageIDs: Set<UUID>) {
        states = states.filter { messageIDs.contains($0.key.scope.messageID) }
    }
}

@MainActor
@Observable
final class CodeBlockDisclosureState {
    private(set) var manualExpansion: Bool?
    private(set) var pendingExpansion: Bool?
    private(set) var layoutRequestID: UUID?
    private(set) var feedbackGeneration: UInt64 = 0
    @ObservationIgnored private var pendingRequestID: UUID?
    @ObservationIgnored let anchor = ChatContentMutationAnchorHandle()

    func prepare(_ requestID: UUID, expanded: Bool) {
        pendingRequestID = requestID
        pendingExpansion = expanded
        layoutRequestID = nil
    }

    func commit(_ requestID: UUID) {
        guard pendingRequestID == requestID, let pendingExpansion else { return }
        manualExpansion = pendingExpansion
        // A code fold retains its message ID. This token makes its geometry
        // acknowledgement belong to the new disclosure, not the old row frame.
        layoutRequestID = requestID
    }

    func finish(_ requestID: UUID, didLand: Bool = false) {
        guard pendingRequestID == requestID else { return }
        if didLand, layoutRequestID == requestID { feedbackGeneration &+= 1 }
        pendingRequestID = nil
        pendingExpansion = nil
        layoutRequestID = nil
    }

    func setExpanded(_ expanded: Bool) {
        manualExpansion = expanded
        feedbackGeneration &+= 1
    }
}

struct CodeDisclosureChange {
    let scope: MessageContentMutationScope
    let blockID: Int
    let state: CodeBlockDisclosureState
    let expanded: Bool
    let edge: ChatContentMutationAnchorEdge
}

/// The child requests a display change. The shared message-layout handoff owns
/// admission, native release, bounded layout, correction and acknowledgement.
struct MessageContentMutationBridge {
    let conversationID: UUID
    let messageID: UUID
    let state: @MainActor (MessageContentMutationScope, Int) -> CodeBlockDisclosureState
    let request: @MainActor (CodeDisclosureChange) -> Void

    func context(region: MessageContentMutationRegionID) -> MessageContentMutationContext {
        MessageContentMutationContext(
            scope: MessageContentMutationScope(
                conversationID: conversationID, messageID: messageID, region: region
            ),
            state: state,
            request: request
        )
    }
}

struct MessageContentMutationContext {
    let scope: MessageContentMutationScope
    let state: @MainActor (MessageContentMutationScope, Int) -> CodeBlockDisclosureState
    let request: @MainActor (CodeDisclosureChange) -> Void
}

@MainActor
final class ChatContentMutationAnchorHandle {
    private struct Registration {
        weak var view: UIView?
    }

    // Disclosure state survives host replacement. Its native views do not:
    // keep mounted registrations so a speculative or outgoing host cannot
    // overwrite the only reference to a code block that is still displayed.
    private var registrations: [Registration] = []

    fileprivate func register(_ view: UIView) {
        registrations.removeAll { $0.view == nil }
        guard view.window != nil,
              !registrations.contains(where: { $0.view === view }) else { return }
        registrations.append(Registration(view: view))
    }

    fileprivate func unregister(_ view: UIView) {
        registrations.removeAll { $0.view == nil || $0.view === view }
    }

    func frameInWindow(matching scrollView: UIScrollView) -> CGRect? {
        for registration in registrations.reversed() {
            guard let view = registration.view, let window = view.window,
                  scrollView.window === window, view.isDescendant(of: scrollView),
                  !view.isHidden, view.alpha > 0.001 else { continue }
            let frame = view.convert(view.bounds, to: window)
            guard frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { continue }
            return frame
        }
        return nil
    }
}

final class ChatContentMutationAnchorView: UIView {
    private var handle: ChatContentMutationAnchorHandle?

    func bind(to handle: ChatContentMutationAnchorHandle) {
        if self.handle !== handle {
            self.handle?.unregister(self)
            self.handle = handle
        }
        handle.register(self)
    }

    func unbind() {
        handle?.unregister(self)
        handle = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            handle?.unregister(self)
        } else {
            handle?.register(self)
        }
    }
}

/// A weak native anchor costs no per-frame SwiftUI state publication.
struct ChatContentMutationAnchorProbe: UIViewRepresentable {
    let handle: ChatContentMutationAnchorHandle

    func makeUIView(context: Context) -> ChatContentMutationAnchorView {
        let view = ChatContentMutationAnchorView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.bind(to: handle)
        return view
    }

    func updateUIView(_ uiView: ChatContentMutationAnchorView, context: Context) {
        uiView.bind(to: handle)
    }

    static func dismantleUIView(_ uiView: ChatContentMutationAnchorView, coordinator: ()) {
        uiView.unbind()
    }
}

/// Only the one requested code block publishes this preference, and only while
/// its shared handoff is pending. Idle scrolling has no code-frame preferences.
struct CodeDisclosureLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
