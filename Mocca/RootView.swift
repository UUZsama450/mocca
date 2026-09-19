import Observation
import PhotosUI
import QuartzCore
import SwiftUI
import UIKit

struct VersionFlashTextContext: Hashable, Sendable {
    let conversationID: UUID
    let request: Int
    let messageID: UUID
    let version: Int
    let versionGroupKey: String
    let isTail: Bool

    var traceSummary: String {
        "conv=\(VersionFlashTrace.identifierToken(conversationID))"
            + " req=\(request)"
            + " msg=\(VersionFlashTrace.identifierToken(messageID))"
            + " ver=\(version)"
            + " group=\(VersionFlashTrace.opaqueToken(versionGroupKey))"
            + " tail=\(isTail)"
    }
}

/// A bounded, launch-argument-only trace for the single-frame long/short
/// response switch. The default path performs only a static Boolean check.
/// When enabled, events are buffered in memory and emitted after the sampled
/// window so console I/O cannot contend with the drawer animation itself.
enum VersionFlashTrace {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains(
        "-diagnoseVersionFlash"
    )

    private enum Item: Sendable {
        case event(timestamp: TimeInterval, message: String)
    }

    private final class Session {
        let sequence: Int
        let startedAt: TimeInterval
        let deadline: TimeInterval
        var items: [Item]
        var onceKeys: Set<String>
        var droppedEventCount = 0

        init(
            sequence: Int,
            startedAt: TimeInterval,
            deadline: TimeInterval,
            initialItem: Item
        ) {
            self.sequence = sequence
            self.startedAt = startedAt
            self.deadline = deadline
            var items: [Item] = []
            items.reserveCapacity(VersionFlashTrace.maximumEventCount)
            items.append(initialItem)
            self.items = items
            var onceKeys = Set<String>()
            onceKeys.reserveCapacity(64)
            self.onceKeys = onceKeys
        }
    }

    private struct Snapshot: Sendable {
        let sequence: Int
        let startedAt: TimeInterval
        let reason: String
        let items: [Item]
        let droppedEventCount: Int
    }

    private static let sampleDuration: TimeInterval = 0.9
    private static let maximumEventCount = 160
    private static let outputChunkLimit = 3_000
    private static let lock = NSLock()
    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var nextSequence = 0
    nonisolated(unsafe) private static var nextHostToken = 0
    nonisolated(unsafe) private static var activeSession: Session?
    nonisolated(unsafe) private static var identifierTokens: [UUID: Int] = [:]
    nonisolated(unsafe) private static var opaqueTokens: [String: Int] = [:]
    nonisolated(unsafe) private static var nextIdentifierToken = 0
    nonisolated(unsafe) private static var nextOpaqueToken = 0

    static func begin(oldConversationID: UUID, targetConversationID: UUID) {
        guard isEnabled else { return }
        identityLock.lock()
        identifierTokens.removeAll(keepingCapacity: true)
        opaqueTokens.removeAll(keepingCapacity: true)
        nextIdentifierToken = 0
        nextOpaqueToken = 0
        identityLock.unlock()
        let oldToken = identifierToken(oldConversationID)
        let targetToken = identifierToken(targetConversationID)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let previous = snapshotLocked(reason: "superseded")
        nextSequence &+= 1
        let sequence = nextSequence
        activeSession = Session(
            sequence: sequence,
            startedAt: now,
            deadline: now + sampleDuration,
            initialItem: .event(
                timestamp: now,
                message: "TAP"
                    + " old=\(oldToken)"
                    + " target=\(targetToken)"
            )
        )
        lock.unlock()
        emit(previous)

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + sampleDuration + 0.05
        ) {
            flushIfCurrent(sequence: sequence, reason: "windowComplete")
        }
    }

    static func record(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        lock.lock()
        guard let session = activeSession else {
            lock.unlock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now <= session.deadline else {
            lock.unlock()
            return
        }
        appendLocked(
            .event(timestamp: now, message: message()),
            to: session
        )
        lock.unlock()
    }

    static func recordOnce(
        _ key: @autoclosure () -> String,
        _ message: @autoclosure () -> String
    ) {
        guard isEnabled else { return }
        lock.lock()
        guard let session = activeSession else {
            lock.unlock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now <= session.deadline else {
            lock.unlock()
            return
        }
        let resolvedKey = key()
        guard session.onceKeys.insert(resolvedKey).inserted else {
            lock.unlock()
            return
        }
        appendLocked(
            .event(timestamp: now, message: message()),
            to: session
        )
        lock.unlock()
    }

    static func allocateHostToken() -> Int? {
        guard isEnabled else { return nil }
        identityLock.lock()
        nextHostToken &+= 1
        let token = nextHostToken
        identityLock.unlock()
        return token
    }

    static func identifierToken(_ id: UUID) -> String {
        guard isEnabled else { return "off" }
        identityLock.lock()
        defer { identityLock.unlock() }
        if let token = identifierTokens[id] {
            return "i\(token)"
        }
        nextIdentifierToken &+= 1
        let token = nextIdentifierToken
        identifierTokens[id] = token
        return "i\(token)"
    }

    static func opaqueToken(_ value: String) -> String {
        guard isEnabled else { return "off" }
        identityLock.lock()
        defer { identityLock.unlock() }
        if let token = opaqueTokens[value] {
            return "s\(token)"
        }
        nextOpaqueToken &+= 1
        let token = nextOpaqueToken
        opaqueTokens[value] = token
        return "s\(token)"
    }

    private static func appendLocked(
        _ item: Item,
        to session: Session
    ) {
        guard session.items.count < maximumEventCount else {
            session.droppedEventCount &+= 1
            return
        }
        session.items.append(item)
    }

    private static func flushIfCurrent(sequence: Int, reason: String) {
        guard isEnabled else { return }
        lock.lock()
        let snapshot: Snapshot?
        if activeSession?.sequence == sequence {
            snapshot = snapshotLocked(reason: reason)
        } else {
            snapshot = nil
        }
        lock.unlock()
        emit(snapshot)
    }

    private static func snapshotLocked(reason: String) -> Snapshot? {
        guard let session = activeSession else { return nil }
        activeSession = nil
        return Snapshot(
            sequence: session.sequence,
            startedAt: session.startedAt,
            reason: reason,
            items: session.items,
            droppedEventCount: session.droppedEventCount
        )
    }

    private static func emit(_ snapshot: Snapshot?) {
        guard let snapshot else { return }
        DispatchQueue.global(qos: .utility).async {
            emitSynchronously(snapshot)
        }
    }

    private static func emitSynchronously(_ snapshot: Snapshot) {
        var lines = [
            "session=\(snapshot.sequence)"
                + " reason=\(snapshot.reason)"
                + " events=\(snapshot.items.count)"
                + " dropped=\(snapshot.droppedEventCount)"
        ]
        lines.append(contentsOf: snapshot.items.map { item in
            switch item {
            case let .event(timestamp, message):
                let elapsed = max(0, timestamp - snapshot.startedAt) * 1_000
                return "dt_ms=\(String(format: "%.3f", elapsed)) \(message)"
            }
        })

        var chunks: [String] = []
        var current = ""
        for line in lines {
            let candidate = current.isEmpty ? line : current + "\n" + line
            if candidate.utf8.count > outputChunkLimit, !current.isEmpty {
                chunks.append(current)
                current = line
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        for (index, chunk) in chunks.enumerated() {
            NSLog(
                "[version-flash] part=%d/%d %@",
                index + 1,
                chunks.count,
                chunk
            )
        }
    }
}

private enum RegenerationViewportTransitionFeature {
    static let isEnabled = !ProcessInfo.processInfo.arguments.contains(
        "-disableRegenerationViewportTransition"
    )
}

@MainActor
private enum ChatBottomTrace {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-diagnoseChatBottom")
    private static var eventSequence = 0
    private static var keyboardCycle = 0
    private static var isKeyboardCycleActive = false

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        eventSequence &+= 1
        let uptime = ProcessInfo.processInfo.systemUptime
        NSLog(
            "[chat-bottom] %@",
            "t=\(String(format: "%.6f", uptime))"
                + " seq=\(eventSequence)"
                + " cycle=\(keyboardCycle) "
                + message()
        )
    }

    static func beginKeyboardCycleIfNeeded() {
        guard enabled, !isKeyboardCycleActive else { return }
        keyboardCycle &+= 1
        isKeyboardCycleActive = true
        log("KEYBOARD_CYCLE_BEGIN")
    }

    static func finishKeyboardCycleIfNeeded() {
        guard enabled, isKeyboardCycleActive else { return }
        log("KEYBOARD_CYCLE_END")
        isKeyboardCycleActive = false
    }

    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(5))
    }

    static func remaining(until date: Date?) -> String {
        guard let date else { return "nil" }
        return String(format: "%.3f", date.timeIntervalSinceNow)
    }

    static func remaining(until date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSinceNow)
    }
}

private struct DrawerFrameTraceSample: Sendable {
    let interval: Double
    let expectedInterval: Double
    let headroom: Double
}

private struct DrawerFrameTraceSnapshot: Sendable {
    let sequence: Int
    let reason: String
    let startProgress: Double
    let logicalStartProgress: Double
    let finalProgress: Double?
    let duration: Double
    let maximumFramesPerSecond: Int
    let touchSampleCount: Int
    let samples: [DrawerFrameTraceSample]
}

private enum DrawerFrameTraceFormatter {
    private struct Metrics {
        let intervalCount: Int
        let budgetMedian: Double?
        let intervalMedian: Double?
        let intervalP95: Double?
        let intervalMaximum: Double?
        let ratioP95: Double?
        let lateCount: Int
        let estimatedMissedVSyncs: Int
        let minimumHeadroom: Double?
    }

    static func emit(_ snapshot: DrawerFrameTraceSnapshot) {
        let touchSampleCount = min(max(snapshot.touchSampleCount, 0), snapshot.samples.count)
        let touchMetrics = metrics(for: Array(snapshot.samples.prefix(touchSampleCount)))
        let settleMetrics = metrics(for: Array(snapshot.samples.dropFirst(touchSampleCount)))
        let direction: String
        if let finalProgress = snapshot.finalProgress {
            if finalProgress > snapshot.startProgress + 0.02 {
                direction = "open"
            } else if finalProgress < snapshot.startProgress - 0.02 {
                direction = "close"
            } else {
                direction = "hold"
            }
        } else {
            direction = "unknown"
        }

        let summary = "[drawer-frames]"
            + " session=\(snapshot.sequence)"
            + " reason=\(snapshot.reason)"
            + " direction=\(direction)"
            + " start_progress=\(formatted(snapshot.startProgress))"
            + " logical_start_progress=\(formatted(snapshot.logicalStartProgress))"
            + " takeover_delta=\(formatted(abs(snapshot.startProgress - snapshot.logicalStartProgress)))"
            + " duration_ms=\(formatted(snapshot.duration * 1_000))"
            + " display_max_fps=\(snapshot.maximumFramesPerSecond)"
            + formattedSection("touch", metrics: touchMetrics)
            + formattedSection("settle", metrics: settleMetrics)
        NSLog("%@", summary)
    }

    private static func metrics(for samples: [DrawerFrameTraceSample]) -> Metrics {
        let intervalMilliseconds = samples.map { $0.interval * 1_000 }.sorted()
        let budgetMilliseconds = samples.map { $0.expectedInterval * 1_000 }.sorted()
        let ratios = samples.map { $0.interval / $0.expectedInterval }.sorted()
        let headroomMilliseconds = samples.map { $0.headroom * 1_000 }
        return Metrics(
            intervalCount: samples.count,
            budgetMedian: percentile(budgetMilliseconds, fraction: 0.50),
            intervalMedian: percentile(intervalMilliseconds, fraction: 0.50),
            intervalP95: percentile(intervalMilliseconds, fraction: 0.95),
            intervalMaximum: intervalMilliseconds.last,
            ratioP95: percentile(ratios, fraction: 0.95),
            lateCount: ratios.count { $0 > 1.5 },
            estimatedMissedVSyncs: ratios.reduce(into: 0) { count, ratio in
                count += max(Int(ratio.rounded()) - 1, 0)
            },
            minimumHeadroom: headroomMilliseconds.min()
        )
    }

    private static func formattedSection(_ label: String, metrics: Metrics) -> String {
        " \(label)_intervals=\(metrics.intervalCount)"
            + " \(label)_budget_ms_med=\(formatted(metrics.budgetMedian))"
            + " \(label)_interval_ms_med=\(formatted(metrics.intervalMedian))"
            + " \(label)_interval_ms_p95=\(formatted(metrics.intervalP95))"
            + " \(label)_interval_ms_max=\(formatted(metrics.intervalMaximum))"
            + " \(label)_ratio_p95=\(formatted(metrics.ratioP95))"
            + " \(label)_late=\(metrics.lateCount)"
            + " \(label)_missed_vsync_est=\(metrics.estimatedMissedVSyncs)"
            + " \(label)_min_headroom_ms=\(formatted(metrics.minimumHeadroom))"
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let interpolation = position - Double(lowerIndex)
        return sortedValues[lowerIndex]
            + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * interpolation
    }

    private static func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "nil" }
        return String(format: "%.3f", value)
    }
}

@MainActor
private final class DrawerFrameDisplayLinkTarget: NSObject {
    weak var session: DrawerFrameTraceSession?

    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
        session?.displayLinkDidFire(displayLink)
    }
}

@MainActor
private final class DrawerHighRefreshDisplayLinkTarget: NSObject {
    @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {}
}

/// Keeps one lightweight ProMotion request alive across the owned horizontal
/// drag and its settle animation. Rapid reversals reuse the same display link,
/// avoiding the diagnostic probe's per-session teardown and formatting work.
@MainActor
private enum DrawerHighRefreshLease {
    private static var displayLinkTarget: DrawerHighRefreshDisplayLinkTarget?
    private static var displayLink: CADisplayLink?
    private static var releaseTask: Task<Void, Never>?

    /// Register the refresh request once while leaving it paused. A paused
    /// display link produces no callbacks, so idle CPU and refresh behavior do
    /// not change; the next owned drag only needs to unpause the existing link.
    static func prepare() {
        guard UIScreen.main.maximumFramesPerSecond >= 120 else { return }
        guard displayLink == nil else { return }

        let target = DrawerHighRefreshDisplayLinkTarget()
        let link = CADisplayLink(
            target: target,
            selector: #selector(DrawerHighRefreshDisplayLinkTarget.displayLinkDidFire(_:))
        )
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120
        )
        link.isPaused = true
        displayLinkTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    static func begin() {
        releaseTask?.cancel()
        releaseTask = nil
        prepare()
        guard let displayLink else { return }
        displayLink.isPaused = false

        // SwiftUI can occasionally lose onEnded when the system interrupts a
        // touch sequence. Bound the lease even on that path.
        schedulePause(after: .seconds(8))
    }

    static func releaseAfterSettle() {
        guard let displayLink, !displayLink.isPaused else { return }
        schedulePause(after: .milliseconds(700))
    }

    static func stop() {
        releaseTask?.cancel()
        releaseTask = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

    private static func schedulePause(after duration: Duration) {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            displayLink?.isPaused = true
            releaseTask = nil
        }
    }
}

/// Drives the automatic drawer settle from the display's own cadence. Direct
/// finger tracking already publishes progress near 120 Hz on ProMotion; the
/// equivalent SwiftUI implicit spring was observed swapping surfaces near
/// 60 Hz even while a high-refresh lease was alive.
@MainActor
private final class DrawerSettleDisplayLinkDriver: NSObject {
    private let spring = SwiftUI.Spring(response: 0.34, dampingRatio: 0.92)
    private let settleDuration: TimeInterval = 0.560 * (0.34 / 0.42)
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval?
    private var startProgress: CGFloat = 0
    private var targetProgress: CGFloat = 0
    private var onProgress: ((CGFloat) -> Void)?
    private var onCompletion: (() -> Void)?

    var activeTargetProgress: CGFloat? {
        displayLink == nil ? nil : targetProgress
    }

    func start(
        from startProgress: CGFloat,
        to targetProgress: CGFloat,
        onProgress: @escaping (CGFloat) -> Void,
        onCompletion: @escaping () -> Void
    ) {
        stop()
        self.startProgress = startProgress
        self.targetProgress = targetProgress
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        startedAt = CACurrentMediaTime()

        let link = CADisplayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:))
        )
        if UIScreen.main.maximumFramesPerSecond >= 120 {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 80,
                maximum: 120,
                preferred: 120
            )
        }
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        startedAt = nil
        onProgress = nil
        onCompletion = nil
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        let startTime = startedAt ?? displayLink.timestamp
        let elapsed = max(displayLink.targetTimestamp - startTime, 0)
        guard elapsed < settleDuration else {
            let completion = onCompletion
            onProgress?(targetProgress)
            stop()
            completion?()
            return
        }

        let sampledProgress = startProgress + spring.value(
            target: targetProgress - startProgress,
            initialVelocity: CGFloat.zero,
            time: elapsed
        )
        onProgress?(min(max(sampledProgress, 0), 1))
    }
}

@MainActor
private final class DrawerFrameTraceSession {
    let sequence: Int
    private let startProgress: Double
    private let logicalStartProgress: Double
    private let beganAt: CFTimeInterval
    private let maximumFramesPerSecond: Int
    private let displayLinkTarget: DrawerFrameDisplayLinkTarget
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var previousExpectedInterval: CFTimeInterval?
    private var touchSampleCount: Int?
    private var finalProgress: Double?
    private var samples: [DrawerFrameTraceSample] = []

    init(sequence: Int, startProgress: CGFloat, logicalStartProgress: CGFloat) {
        self.sequence = sequence
        self.startProgress = Double(startProgress)
        self.logicalStartProgress = Double(logicalStartProgress)
        beganAt = CACurrentMediaTime()
        maximumFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        displayLinkTarget = DrawerFrameDisplayLinkTarget()
        samples.reserveCapacity(256)

        displayLinkTarget.session = self
        let displayLink = CADisplayLink(
            target: displayLinkTarget,
            selector: #selector(DrawerFrameDisplayLinkTarget.displayLinkDidFire(_:))
        )
        if maximumFramesPerSecond >= 120 {
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 80,
                maximum: 120,
                preferred: 120
            )
        }
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    func displayLinkDidFire(_ displayLink: CADisplayLink) {
        if let previousTimestamp,
           let previousExpectedInterval,
           previousExpectedInterval > 0 {
            let interval = displayLink.timestamp - previousTimestamp
            if interval > 0 {
                samples.append(
                    DrawerFrameTraceSample(
                        interval: interval,
                        expectedInterval: previousExpectedInterval,
                        headroom: displayLink.targetTimestamp - CACurrentMediaTime()
                    )
                )
            }
        }
        previousTimestamp = displayLink.timestamp
        let nextExpectedInterval = displayLink.targetTimestamp - displayLink.timestamp
        previousExpectedInterval = nextExpectedInterval > 0
            ? nextExpectedInterval
            : displayLink.duration
    }

    func markTouchEnded(finalProgress: CGFloat?) {
        touchSampleCount = samples.count
        self.finalProgress = finalProgress.map(Double.init)
    }

    func stop(reason: String) -> DrawerFrameTraceSnapshot {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget.session = nil
        return DrawerFrameTraceSnapshot(
            sequence: sequence,
            reason: reason,
            startProgress: startProgress,
            logicalStartProgress: logicalStartProgress,
            finalProgress: finalProgress,
            duration: max(CACurrentMediaTime() - beganAt, 0),
            maximumFramesPerSecond: maximumFramesPerSecond,
            touchSampleCount: touchSampleCount ?? samples.count,
            samples: samples
        )
    }
}

@MainActor
private enum DrawerFrameTrace {
    private static let enabled = ProcessInfo.processInfo.arguments.contains("-diagnoseDrawerFrames")
    private static var sequence = 0
    private static var activeSession: DrawerFrameTraceSession?
    private static var timeoutTask: Task<Void, Never>?
    private static var settleCompletionTask: Task<Void, Never>?

    static func begin(startProgress: CGFloat, logicalStartProgress: CGFloat) {
        guard enabled else { return }
        finish(reason: "interrupted")
        sequence &+= 1
        activeSession = DrawerFrameTraceSession(
            sequence: sequence,
            startProgress: startProgress,
            logicalStartProgress: logicalStartProgress
        )
        let expectedSequence = sequence
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  activeSession?.sequence == expectedSequence else { return }
            finish(reason: "timeout")
        }
    }

    static func touchEnded(finalProgress: CGFloat?) {
        guard enabled, let activeSession else { return }
        activeSession.markTouchEnded(finalProgress: finalProgress)
        timeoutTask?.cancel()
        timeoutTask = nil
        settleCompletionTask?.cancel()
        let expectedSequence = activeSession.sequence
        settleCompletionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled,
                  DrawerFrameTrace.activeSession?.sequence == expectedSequence else { return }
            finish(reason: "settle_complete")
        }
    }

    static func rootDidDisappear() {
        finish(reason: "root_disappear")
    }

    static func sceneDidDeactivate() {
        finish(reason: "scene_deactivate")
    }

    private static func finish(reason: String) {
        guard let activeSession else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        settleCompletionTask?.cancel()
        settleCompletionTask = nil
        self.activeSession = nil
        let snapshot = activeSession.stop(reason: reason)
        Task.detached(priority: .utility) {
            DrawerFrameTraceFormatter.emit(snapshot)
        }
    }
}

private struct ConversationPositionRequestKey: Hashable {
    let conversationID: UUID
    let request: Int
}

// ScrollViewProxy targets must change whenever either the return transaction or
// the concrete LazyVStack row set changes. Reusing a conversation-only target
// lets SwiftUI resolve a deleted row's old content height and can leave every
// surviving row outside the viewport.
private struct ConversationBottomAnchorID: Hashable {
    let positionRequest: ConversationPositionRequestKey
    let messageIDs: [UUID]
}

// A revision-scoped target outside LazyVStack. It is reached only before the
// current concrete tail has acknowledged readiness, so an inherited stale
// bottom offset can be replaced by one real lazy viewport without changing the
// message tree or any normal animation path.
private struct ConversationTopMaterializationSeedID: Hashable {
    let anchorID: ConversationBottomAnchorID
}

// Give every message one stable, typed direct-child identity. The type keeps
// proxy targets distinct from the nested MessageRow UUID, while stability keeps
// an old tail from being destroyed and rebuilt when a new message is appended.
// Tail-return revision safety remains in the anchor-scoped task and geometry ack.
private enum ConversationMessageHostID: Hashable {
    case message(UUID)
}

private struct ConversationMessageHost: Identifiable {
    let id: ConversationMessageHostID
    let index: Int
    let message: ChatMessage
    let citationSources: [MessageCitationSource]
    let isSendPresentationReservation: Bool
}

private struct PendingKeyboardViewportPin: Equatable {
    let anchorID: ConversationBottomAnchorID
    let generation: Int
    let preKeyboardBottomOffsetY: CGFloat?
    let allowsViewportTransitionCommit: Bool

    var positionRequest: ConversationPositionRequestKey {
        anchorID.positionRequest
    }
}

// An exact staged send whose concrete user row appeared while the software
// keyboard was still dismissing. The assistant identity is retained after the
// visual gate opens so keyboard dismissal and the final tail can share one
// trajectory without weakening the ordinary send fallback.
private struct KeyboardUnifiedSendHandoff: Equatable {
    let requestID: UUID
    let conversationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
}

private struct ConversationBottomAnchorFrame: Equatable {
    let anchorID: ConversationBottomAnchorID
    let frame: CGRect
    var layoutRequestID: UUID? = nil

    var positionRequest: ConversationPositionRequestKey {
        anchorID.positionRequest
    }
}

// A reasoning finish is identified only by stable transcript identity. In
// particular, message.updatedAt is deliberately absent: ordinary streaming
// batches keep mutating it after the automatic collapse has begun.
private struct AutomaticReasoningCollapseObservation: Equatable {
    let anchorID: ConversationBottomAnchorID
    let tailMessageID: UUID
    let segmentID: UUID
    let finishedAt: Date?
    let messageUpdatedAt: Date
    let isStreaming: Bool
    let autoCollapseEnabled: Bool
    let isExpanded: Bool
    let hasVisibleText: Bool

    static func == (
        lhs: AutomaticReasoningCollapseObservation,
        rhs: AutomaticReasoningCollapseObservation
    ) -> Bool {
        // updatedAt is carried only as finish provenance. Excluding it from
        // equality keeps ordinary streaming batches from invoking this
        // synchronous transition reducer on every body update.
        lhs.anchorID == rhs.anchorID
            && lhs.tailMessageID == rhs.tailMessageID
            && lhs.segmentID == rhs.segmentID
            && lhs.finishedAt == rhs.finishedAt
            && lhs.isStreaming == rhs.isStreaming
            && lhs.autoCollapseEnabled == rhs.autoCollapseEnabled
            && lhs.isExpanded == rhs.isExpanded
            && lhs.hasVisibleText == rhs.hasVisibleText
    }
}

private struct AutomaticReasoningCollapseIdentity: Equatable {
    let anchorID: ConversationBottomAnchorID
    let tailMessageID: UUID
    let segmentID: UUID
    let finishedAt: Date
}

// ReasoningCard owns its temporary streaming disclosure state locally. Mirror
// only the stable transcript key at the scroll root so a manual collapse can
// suppress the automatic-finish reducer without coupling layout to that view.
private struct ManualStreamingReasoningCollapseKey: Equatable {
    let anchorID: ConversationBottomAnchorID
    let tailMessageID: UUID
    let segmentID: UUID
}

// MessageFramePreferenceKey can publish an empty frame table immediately
// before the model's expanded -> collapsed onChange. Keep the last concrete,
// visible expanded tail outside that mutable table so admission still has the
// pre-collapse geometry proven by the previous layout generation.
private struct AutomaticReasoningExpandedCheckpoint: Equatable {
    let anchorID: ConversationBottomAnchorID
    let tailMessageID: UUID
    let segmentID: UUID
    let frameGeneration: UInt64
    let frame: CGRect
    let scrollViewIdentity: ObjectIdentifier
    let contentHeight: CGFloat
    let contentOffsetY: CGFloat
    let minimumOffsetY: CGFloat
    let adjustedContentInsetBottom: CGFloat
}

private struct AutomaticReasoningCollapseAuthorization: Equatable {
    let identity: AutomaticReasoningCollapseIdentity
    let checkpoint: AutomaticReasoningExpandedCheckpoint
}

private struct AutomaticReasoningCollapseGeometryChange {
    let anchorID: ConversationBottomAnchorID
    let previousContentHeight: CGFloat
    let contentHeight: CGFloat
    let previousContainerHeight: CGFloat
    let containerHeight: CGFloat
    let signedDistanceFromBottom: CGFloat
    let previousWasAtBottom: Bool
    let positionWasUserOwned: Bool
}

private struct AutomaticReasoningCollapseOwnerID: Equatable {
    let anchorID: ConversationBottomAnchorID
    let generation: UInt64
}

private struct AutomaticReasoningCollapseRearmRequest: Equatable {
    let ownerID: AutomaticReasoningCollapseOwnerID
    let attempt: UInt8
}

// One owner performs one physical write. Once a newer concrete collapsed tail
// is visible it emits its own typed semantic-bottom rearm and remains alive
// until UIKit subsequently acknowledges exact bottom.
private struct AutomaticReasoningCollapseOwner: Equatable {
    let id: AutomaticReasoningCollapseOwnerID
    let identity: AutomaticReasoningCollapseIdentity
    let checkpoint: AutomaticReasoningExpandedCheckpoint
    let appliedOffsetY: CGFloat
    var didRequestBottomRearm: Bool
    var didAcknowledgeBottomRearm: Bool
    var bottomRearmAttempt: UInt8
}

private enum AutomaticReasoningCollapseGeometryDisposition {
    case unowned
    case pendingCollapseSample
    case consumedUnowned
    case owned(AutomaticReasoningCollapseOwnerID)
}

private struct ConversationMessageFrameSnapshot: Equatable {
    let anchorID: ConversationBottomAnchorID
    var frames: [UUID: CGRect]
    var layoutRequestID: UUID? = nil
}

private struct OffscreenStreamingDisplayCandidate: Equatable {
    let conversationID: UUID
    let messageID: UUID
}

/// Reference-backed so lease bookkeeping never becomes a SwiftUI invalidation
/// source for the long transcript. All mutations originate from main-view
/// callbacks and remain serialized with AppModel's MainActor stream updates.
private final class OffscreenStreamingDisplayState {
    var candidate: OffscreenStreamingDisplayCandidate?
    var didUserDetachFromTail = false
}

private enum MessageNavigationAction: Equatable {
    case top
    case previousUserMessage
    case nextUserMessage
    case message(UUID)
    case bottom
}

private struct MessageNavigationRequest: Equatable {
    let sequence: Int
    let positionRequest: ConversationPositionRequestKey
    let action: MessageNavigationAction
}

// The same conversation can replace its entire historical message window while
// keeping the outer ScrollView alive. Advance this identity only for those
// explicit navigation replacements so the inner lazy stack cannot reuse the
// previous window's realization estimates. Ordinary message/content updates do
// not touch it.
private struct ConversationLazyWindowIdentity: Hashable {
    let conversationID: UUID
    let generation: UInt64
}

// An explicit edge navigation first releases any retained iOS 18 semantic
// `.bottom` position while preserving the visible offset. The source anchor is
// part of the identity so an acknowledgement from an older transcript
// revision can never start a newer window mutation.
private struct EdgeNavigationNativeReleaseID: Equatable {
    let sequence: Int
    let positionRequest: ConversationPositionRequestKey
    let sourceAnchorID: ConversationBottomAnchorID
}

// Ordinary send positioning uses the same release principle, independently
// from the accepted keyboard-unified handoff. The request UUID and the exact
// user-only projection revision form the complete token.
private struct SendPositionNativeReleaseID: Equatable {
    let requestID: UUID
    let sourceAnchorID: ConversationBottomAnchorID
}

// Model edits and code disclosure share release, concrete layout and landing.
// The typed edit prevents a display-only disclosure from entering deletion.
private enum MessageViewportEdit {
    case deletion(ChatMessage, allVersions: Bool)
    case replacement(ChatMessage, with: ChatMessage)
    case codeDisclosure(ChatMessage, change: CodeDisclosureChange, anchorY: CGFloat)

    var message: ChatMessage {
        switch self {
        case .deletion(let message, _), .replacement(let message, _),
             .codeDisclosure(let message, _, _): return message
        }
    }

    var replacementMessage: ChatMessage? {
        if case .replacement(_, let message) = self { return message }
        return nil
    }

    var codeDisclosure: CodeDisclosureChange? {
        if case .codeDisclosure(_, let change, _) = self { return change }
        return nil
    }
}

private struct MessageReplacementViewportRequest {
    let id: UUID
    let edit: MessageViewportEdit
    var message: ChatMessage { edit.message }
    var replacementMessage: ChatMessage? { edit.replacementMessage }
    var codeDisclosure: CodeDisclosureChange? { edit.codeDisclosure }
    let sourceAnchorID: ConversationBottomAnchorID
    let scrollViewIdentity: ObjectIdentifier
    let readingAnchorID: UUID?
    let readingAnchorMinY: CGFloat?
    let precedingUserID: UUID?
    let sourceWasAutoFollowEngaged: Bool
    let sourceWasAtBottom: Bool
    var codeLayoutSize: CGSize?
    // Text cadence can pause, but completion/reasoning/tool updates still land
    // in the model. Hold one display value only for this existing handoff.
    var streamingMessage: ChatMessage?
    var readingAnchorMaxY: CGFloat?
    var keepsExactBottom = false
    var didCommit = false
    var landingAnchorID: ConversationBottomAnchorID?
    var targetMessageID: UUID?
    var didIssueLanding = false
    var layoutWaitReason: String?
}

// Pure selection policy shared by the real deletion path and offline tests.
private enum MessageDeletionLandingPolicy {
    static func targetID(
        deletedID: UUID,
        readingAnchorID: UUID?,
        precedingUserID: UUID?,
        sourceIDs: [UUID],
        survivingIDs: [UUID]
    ) -> UUID? {
        let survivors = Set(survivingIDs)
        if let readingAnchorID, survivors.contains(readingAnchorID) {
            return readingAnchorID
        }
        if let precedingUserID, survivors.contains(precedingUserID) {
            return precedingUserID
        }
        if let index = sourceIDs.firstIndex(of: deletedID) {
            if let next = sourceIDs.dropFirst(index + 1).first(where: survivors.contains) {
                return next
            }
            if let previous = sourceIDs.prefix(index).last(where: survivors.contains) {
                return previous
            }
        }
        return survivingIDs.first
    }
}

private struct MessageTargetLandingSnapshot {
    let scrollViewIdentity: ObjectIdentifier
    let targetFrame: CGRect
    let contentSize: CGSize
    let viewportSize: CGSize
    let contentOffset: CGPoint
    let insetTop: CGFloat
    let insetBottom: CGFloat

    var isFinite: Bool {
        targetFrame.minX.isFinite
            && targetFrame.minY.isFinite
            && targetFrame.width.isFinite
            && targetFrame.height.isFinite
            && contentSize.width.isFinite
            && contentSize.height.isFinite
            && viewportSize.width.isFinite
            && viewportSize.height.isFinite
            && contentOffset.x.isFinite
            && contentOffset.y.isFinite
            && insetTop.isFinite
            && insetBottom.isFinite
    }

    func isStable(comparedTo other: Self, tolerance: CGFloat = 0.75) -> Bool {
        scrollViewIdentity == other.scrollViewIdentity
            && Self.isNear(targetFrame.minX, other.targetFrame.minX, tolerance: tolerance)
            && Self.isNear(targetFrame.minY, other.targetFrame.minY, tolerance: tolerance)
            && Self.isNear(targetFrame.width, other.targetFrame.width, tolerance: tolerance)
            && Self.isNear(targetFrame.height, other.targetFrame.height, tolerance: tolerance)
            && Self.isNear(contentSize.width, other.contentSize.width, tolerance: tolerance)
            && Self.isNear(contentSize.height, other.contentSize.height, tolerance: tolerance)
            && Self.isNear(viewportSize.width, other.viewportSize.width, tolerance: tolerance)
            && Self.isNear(viewportSize.height, other.viewportSize.height, tolerance: tolerance)
            && Self.isNear(contentOffset.x, other.contentOffset.x, tolerance: tolerance)
            && Self.isNear(contentOffset.y, other.contentOffset.y, tolerance: tolerance)
            && Self.isNear(insetTop, other.insetTop, tolerance: tolerance)
            && Self.isNear(insetBottom, other.insetBottom, tolerance: tolerance)
    }

    private static func isNear(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

@MainActor
private final class WeakChatScrollViewBox {
    weak var registration: ChatScrollViewRegistration?

    var scrollView: UIScrollView? { registration?.scrollView }
}

/// Keeps the already-rendered chat viewport above the real scroll view while
/// regeneration resolves its concrete user-row landing. Only a detached UIKit
/// snapshot is animated; the SwiftUI transcript tree and message identities
/// remain untouched.
@MainActor
private final class RegenerationViewportTransitionCoordinator {
    private weak var preparedHostView: UIView?
    private var preparedSnapshotView: UIView?
    private var preparedFrameInHost: CGRect = .zero

    private var activeToken: UUID?
    private var activeRequestID: UUID?
    private var overlayView: UIView?
    private var revealAnimator: UIViewPropertyAnimator?
    private var timeoutTask: Task<Void, Never>?
    private var sequence: UInt64 = 0

    var hasActiveWork: Bool {
        preparedSnapshotView != nil
            || activeToken != nil
            || overlayView != nil
            || revealAnimator != nil
            || timeoutTask != nil
    }

    @discardableResult
    func prepare(from scrollView: UIScrollView?) -> Bool {
        discardPrepared(reason: "replace")
        guard RegenerationViewportTransitionFeature.isEnabled,
              activeToken == nil,
              revealAnimator == nil,
              let scrollView,
              let window = scrollView.window,
              let hostView = scrollView.superview,
              scrollView.bounds.width > 1,
              scrollView.bounds.height > 1,
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              scrollView.panGestureRecognizer.numberOfTouches == 0 else {
            return false
        }
        if #available(iOS 17.4, *), scrollView.isScrollAnimating {
            return false
        }

        let frameInWindow = scrollView.convert(scrollView.bounds, to: window)
        guard frameInWindow.minX.isFinite,
              frameInWindow.minY.isFinite,
              frameInWindow.width.isFinite,
              frameInWindow.height.isFinite,
              frameInWindow.width > 1,
              frameInWindow.height > 1,
              window.bounds.intersection(frameInWindow).width
                >= frameInWindow.width - 1,
              window.bounds.intersection(frameInWindow).height
                >= frameInWindow.height - 1,
              let snapshotView = window.resizableSnapshotView(
                from: frameInWindow,
                afterScreenUpdates: false,
                withCapInsets: .zero
              ) else {
            return false
        }

        let frameInHost = hostView.convert(frameInWindow, from: window)
        guard frameInHost.minX.isFinite,
              frameInHost.minY.isFinite,
              frameInHost.width.isFinite,
              frameInHost.height.isFinite,
              frameInHost.width > 1,
              frameInHost.height > 1 else {
            return false
        }

        snapshotView.isUserInteractionEnabled = false
        snapshotView.accessibilityElementsHidden = true
        preparedHostView = hostView
        preparedSnapshotView = snapshotView
        preparedFrameInHost = frameInHost
        ChatBottomTrace.log(
            "REGENERATION_VIEWPORT_TRANSITION_PREPARED"
                + " width=\(String(format: "%.1f", frameInHost.width))"
                + " height=\(String(format: "%.1f", frameInHost.height))"
        )
        return true
    }

    func activatePrepared() -> UUID? {
        guard RegenerationViewportTransitionFeature.isEnabled,
              activeToken == nil,
              revealAnimator == nil,
              let hostView = preparedHostView,
              hostView.window != nil,
              let snapshotView = preparedSnapshotView,
              preparedFrameInHost.width > 1,
              preparedFrameInHost.height > 1 else {
            discardPrepared(reason: "activationUnavailable")
            return nil
        }

        let container = UIView(frame: preparedFrameInHost)
        container.clipsToBounds = true
        container.isUserInteractionEnabled = true
        container.accessibilityElementsHidden = true
        snapshotView.frame = container.bounds
        snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(snapshotView)
        hostView.addSubview(container)

        preparedHostView = nil
        preparedSnapshotView = nil
        preparedFrameInHost = .zero

        sequence &+= 1
        let token = UUID()
        activeToken = token
        activeRequestID = nil
        overlayView = container
        scheduleTimeout(for: token)
        ChatBottomTrace.log(
            "REGENERATION_VIEWPORT_TRANSITION_ACTIVATED"
                + " token=\(ChatBottomTrace.shortID(token))"
        )
        return token
    }

    /// Covers a favorite-target jump with the current theme surface while the
    /// existing target materialization and landing checks run underneath. This
    /// does not snapshot or mutate the transcript and never starts regeneration.
    @discardableResult
    func activateSolidCover(
        from scrollView: UIScrollView?,
        backgroundColor: UIColor
    ) -> UUID? {
        discardPrepared(reason: "solidCover")
        guard RegenerationViewportTransitionFeature.isEnabled,
              activeToken == nil,
              revealAnimator == nil,
              let scrollView,
              let hostView = scrollView.superview,
              hostView.window != nil,
              scrollView.bounds.width > 1,
              scrollView.bounds.height > 1 else {
            return nil
        }

        let frameInHost = scrollView.convert(scrollView.bounds, to: hostView)
        guard frameInHost.minX.isFinite,
              frameInHost.minY.isFinite,
              frameInHost.width.isFinite,
              frameInHost.height.isFinite,
              frameInHost.width > 1,
              frameInHost.height > 1 else {
            return nil
        }

        let container = UIView(frame: frameInHost)
        container.backgroundColor = backgroundColor
        container.clipsToBounds = true
        container.isUserInteractionEnabled = true
        container.accessibilityElementsHidden = true
        hostView.addSubview(container)

        sequence &+= 1
        let token = UUID()
        activeToken = token
        activeRequestID = nil
        overlayView = container
        scheduleTimeout(for: token)
        ChatBottomTrace.log(
            "FAVORITE_VIEWPORT_TRANSITION_ACTIVATED"
                + " token=\(ChatBottomTrace.shortID(token))"
                + " width=\(String(format: "%.1f", frameInHost.width))"
                + " height=\(String(format: "%.1f", frameInHost.height))"
        )
        return token
    }

    func bind(_ token: UUID, to requestID: UUID) {
        guard activeToken == token,
              overlayView != nil else { return }
        activeRequestID = requestID
        ChatBottomTrace.log(
            "REGENERATION_VIEWPORT_TRANSITION_BOUND"
                + " token=\(ChatBottomTrace.shortID(token))"
                + " request=\(ChatBottomTrace.shortID(requestID))"
        )
    }

    func owns(requestID: UUID) -> Bool {
        activeRequestID == requestID && overlayView != nil
    }

    func reveal(requestID: UUID, reason: String) {
        guard activeRequestID == requestID else { return }
        revealActive(reason: reason)
    }

    func discardPrepared(reason: String) {
        guard preparedSnapshotView != nil else { return }
        preparedHostView = nil
        preparedSnapshotView = nil
        preparedFrameInHost = .zero
        ChatBottomTrace.log(
            "REGENERATION_VIEWPORT_TRANSITION_PREPARED_DROP reason=\(reason)"
        )
    }

    func cancelAll(reason: String) {
        discardPrepared(reason: reason)
        guard overlayView != nil || revealAnimator != nil else { return }
        sequence &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
        revealAnimator?.stopAnimation(true)
        revealAnimator = nil
        overlayView?.removeFromSuperview()
        overlayView = nil
        activeToken = nil
        activeRequestID = nil
        ChatBottomTrace.log(
            "REGENERATION_VIEWPORT_TRANSITION_CANCEL reason=\(reason)"
        )
    }

    private func scheduleTimeout(for token: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.activeToken == token else { return }
            self.revealActive(reason: "timeout")
        }
    }

    private func revealActive(reason: String) {
        guard revealAnimator == nil,
              let overlayView else { return }
        sequence &+= 1
        let revealSequence = sequence
        timeoutTask?.cancel()
        timeoutTask = nil
        activeToken = nil
        activeRequestID = nil

        let reducesMotion = UIAccessibility.isReduceMotionEnabled
        let animator = UIViewPropertyAnimator(
            duration: reducesMotion ? 0.12 : 0.20,
            curve: .easeInOut
        )
        animator.addAnimations {
            overlayView.alpha = 0
            if !reducesMotion {
                overlayView.transform = CGAffineTransform(
                    translationX: 0,
                    y: -10
                )
            }
        }
        animator.addCompletion { [weak self, weak overlayView] _ in
            overlayView?.removeFromSuperview()
            guard let self,
                  self.sequence == revealSequence else { return }
            self.revealAnimator = nil
            self.overlayView = nil
        }
        revealAnimator = animator
        ChatBottomTrace.log(
            "REGENERATION_VIEWPORT_TRANSITION_REVEAL"
                + " reason=\(reason)"
                + " reduceMotion=\(reducesMotion)"
        )
        animator.startAnimation()
    }
}

/// Holds the concrete drawer-list scroll view without making its native state
/// observable by SwiftUI. Horizontal drawer ownership still uses the proven
/// `.scrollDisabled` gate; this coordinator only normalizes a top-edge return
/// that is already in flight when the drawer begins closing.
@MainActor
private final class DrawerListTopReturnCoordinator {
    private(set) weak var scrollView: UIScrollView?
    private weak var registrationOwner: AnyObject?
    private weak var animatingScrollView: UIScrollView?
    private weak var immediatelyLockedScrollView: UIScrollView?
    private var animator: UIViewPropertyAnimator?
    private var animationSequence: UInt64 = 0
    private var isDrawerGestureLockActive = false
    private var isStatusBarScrollToTopEnabled = false

    func register(_ scrollView: UIScrollView, owner: AnyObject) {
        guard self.scrollView !== scrollView
                || registrationOwner !== owner else { return }
        clearRegistration(
            preservingImmediateLock: isDrawerGestureLockActive
        )
        self.scrollView = scrollView
        registrationOwner = owner
        scrollView.scrollsToTop = isStatusBarScrollToTopEnabled
    }

    func unregister(_ scrollView: UIScrollView, owner: AnyObject) {
        guard self.scrollView === scrollView,
              registrationOwner === owner else { return }
        scrollView.scrollsToTop = false
        clearRegistration(
            preservingImmediateLock: isDrawerGestureLockActive
        )
    }

    /// Gives the status-bar action to the visible surface only. This changes
    /// once at the drawer's semantic open/close boundary, never while its
    /// presentation progress animates frame by frame.
    func setStatusBarScrollToTopEnabled(_ isEnabled: Bool) {
        isStatusBarScrollToTopEnabled = isEnabled
        scrollView?.scrollsToTop = isEnabled
    }

    /// Gives both close-gesture surfaces the same soft top-edge return while
    /// immediately preventing the drawer list from drifting vertically under
    /// a horizontal finger. The explicit native lock is an immediate bridge;
    /// SwiftUI's existing `.scrollDisabled` remains the authoritative lock.
    func beginSoftTopReturnIfNeeded() {
        // A rapid second close takes over from the exact presentation left by
        // the first return. Invalidate its completion before sampling so the
        // old animator cannot survive a legal-top early return.
        animationSequence &+= 1
        let sequence = animationSequence
        finishActiveReturn(at: .current)

        guard let scrollView,
              scrollView.window != nil,
              scrollView.bounds.height > 0 else { return }

        let restingOffsetY = -scrollView.adjustedContentInset.top
        let capturedOffset = scrollView.contentOffset
        guard capturedOffset.y < restingOffsetY - 0.5 else { return }

        animatingScrollView = scrollView
        immediatelyLockedScrollView = scrollView

        // `isScrollEnabled = false` can clamp an active rubber-band. Restore
        // the captured presentation synchronously, before this run-loop frame
        // commits, then animate the actual UIScrollView bounds to its top edge.
        scrollView.isScrollEnabled = false
        scrollView.setContentOffset(capturedOffset, animated: false)

        let targetOffset = CGPoint(
            x: capturedOffset.x,
            y: restingOffsetY
        )
        guard !UIAccessibility.isReduceMotionEnabled else {
            scrollView.setContentOffset(targetOffset, animated: false)
            animatingScrollView = nil
            return
        }

        let timing = UISpringTimingParameters(dampingRatio: 1)
        let animator = UIViewPropertyAnimator(
            duration: 0.28,
            timingParameters: timing
        )
        animator.addAnimations { [weak scrollView] in
            scrollView?.contentOffset = targetOffset
        }
        animator.addCompletion { [weak self, weak scrollView] _ in
            guard let self,
                  let scrollView,
                  self.animationSequence == sequence,
                  self.scrollView === scrollView else { return }
            self.animator = nil
            self.animatingScrollView = nil
        }
        self.animator = animator
        animator.startAnimation()
    }

    /// A real list pan always wins over the helper. Finishing at the current
    /// presentation lets UIScrollView continue from exactly what the user saw.
    func nativePanDidBegin(in scrollView: UIScrollView) {
        guard self.scrollView === scrollView,
              animatingScrollView === scrollView else { return }
        animationSequence &+= 1
        finishActiveReturn(at: .current)
    }

    /// A rapid closed -> open reversal has no vertical finger to inherit the
    /// presentation, so finish the old return at its legal top before the
    /// drawer becomes visible again.
    func finishSoftTopReturnForDrawerOpening() {
        guard animator != nil else { return }
        animationSequence &+= 1
        let returningScrollView = animatingScrollView
        finishActiveReturn(at: .end)
        clampToRestingTopIfNeeded(returningScrollView)
    }

    /// Mirrors the authoritative SwiftUI gate without replacing it. If probe
    /// identity changes during an owned horizontal drag, keep the concrete
    /// bridge locked until the existing gate is released.
    func setDrawerGestureLockActive(_ isActive: Bool) {
        isDrawerGestureLockActive = isActive
        if !isActive {
            releaseImmediateInteractionLock()
        }
    }

    func reset() {
        isDrawerGestureLockActive = false
        setStatusBarScrollToTopEnabled(false)
        clearRegistration(preservingImmediateLock: false)
    }

    private func clearRegistration(preservingImmediateLock: Bool) {
        animationSequence &+= 1
        let returningScrollView = animatingScrollView
        finishActiveReturn(at: .end)
        clampToRestingTopIfNeeded(returningScrollView)
        clampToRestingTopIfNeeded(immediatelyLockedScrollView)

        if !preservingImmediateLock {
            releaseImmediateInteractionLock()
        }
        scrollView = nil
        registrationOwner = nil
    }

    /// Releases only the immediate UIKit bridge. SwiftUI applies the same
    /// enabled state through `.scrollDisabled(false)` at gesture end.
    private func releaseImmediateInteractionLock() {
        immediatelyLockedScrollView?.isScrollEnabled = true
        immediatelyLockedScrollView = nil
    }

    private func finishActiveReturn(at position: UIViewAnimatingPosition) {
        guard let animator else {
            animatingScrollView = nil
            return
        }
        self.animator = nil
        animatingScrollView = nil

        if animator.state == .active {
            animator.stopAnimation(false)
        }
        if animator.state == .stopped {
            animator.finishAnimation(at: position)
        } else if animator.state == .inactive {
            animator.stopAnimation(true)
        }
    }

    private func clampToRestingTopIfNeeded(_ scrollView: UIScrollView?) {
        guard let scrollView else { return }
        let restingOffsetY = -scrollView.adjustedContentInset.top
        guard scrollView.contentOffset.y < restingOffsetY - 0.5 else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: restingOffsetY),
            animated: false
        )
    }
}

/// Keeps chat touch arbitration on the concrete UIKit scroll view instead of
/// propagating SwiftUI's `scrollDisabled` environment value through the long
/// transcript. The drawer list keeps its proven SwiftUI gate because disabling
/// its concrete scroll view after gesture recognition didn't reliably cancel
/// diagonal vertical movement on device.
@MainActor
private enum DrawerNativeScrollGate {
    enum Role {
        case chat
    }

    private static let chatScrollViews =
        NSMapTable<UIScrollView, ChatScrollViewRegistration>.weakToWeakObjects()
    private static var isChatDisabled = false

    static func owner(for scrollView: UIScrollView, role: Role) -> ChatScrollViewRegistration? {
        table(for: role).object(forKey: scrollView)
    }

    static func register(_ scrollView: UIScrollView, role: Role, owner: ChatScrollViewRegistration) {
        table(for: role).setObject(owner, forKey: scrollView)
        applyCurrentState(to: scrollView, role: role)
    }

    static func unregister(_ scrollView: UIScrollView, role: Role, owner: ChatScrollViewRegistration) {
        guard self.owner(for: scrollView, role: role) === owner else { return }
        table(for: role).removeObject(forKey: scrollView)
        scrollView.isScrollEnabled = true
        scrollView.scrollsToTop = true
    }

    static func update(isDrawerPresented: Bool, isDrawerGestureActive: Bool) {
        let shouldDisableChat = isDrawerPresented || isDrawerGestureActive

        if isChatDisabled != shouldDisableChat {
            isChatDisabled = shouldDisableChat
            applyCurrentState(to: chatScrollViews, role: .chat)
        }
    }

    static func reset() {
        isChatDisabled = false
        applyCurrentState(to: chatScrollViews, role: .chat)
    }

    private static func table(for role: Role) -> NSMapTable<UIScrollView, ChatScrollViewRegistration> {
        switch role {
        case .chat: chatScrollViews
        }
    }

    private static func applyCurrentState(
        to table: NSMapTable<UIScrollView, ChatScrollViewRegistration>,
        role: Role
    ) {
        for case let scrollView as UIScrollView in table.keyEnumerator().allObjects {
            applyCurrentState(to: scrollView, role: role)
        }
    }

    private static func applyCurrentState(to scrollView: UIScrollView, role: Role) {
        let disabled = switch role {
        case .chat: isChatDisabled
        }
        if scrollView.isScrollEnabled == disabled {
            scrollView.isScrollEnabled = !disabled
        }
        if scrollView.scrollsToTop == disabled {
            scrollView.scrollsToTop = !disabled
        }
    }
}

@MainActor
enum DrawerInlineActionTapGate {
    private static var isDrawerDragActive = false
    private static var suppressActionUntil = Date.distantPast
    private static var activeGestureFailsafe = Date.distantPast

    static func beginDrawerDrag() {
        isDrawerDragActive = true
        activeGestureFailsafe = Date().addingTimeInterval(4)
    }

    static func endDrawerDrag() {
        isDrawerDragActive = false
        suppressActionUntil = Date().addingTimeInterval(0.24)
        activeGestureFailsafe = .distantPast
    }

    static func reset() {
        isDrawerDragActive = false
        suppressActionUntil = .distantPast
        activeGestureFailsafe = .distantPast
    }

    static var allowsAction: Bool {
        let now = Date()
        if isDrawerDragActive {
            if now < activeGestureFailsafe {
                return false
            }
            // Do not leave the actions disabled if iOS interrupts a drag
            // before SwiftUI delivers its normal onEnded callback.
            isDrawerDragActive = false
        }
        return now >= suppressActionUntil
    }
}

/// Mirrors SwiftUI's interpolated drawer value without publishing a new view
/// update on every animation frame. A gesture that interrupts the spring can
/// then take ownership from the value currently on screen instead of from the
/// spring's already-written logical endpoint.
@MainActor
private final class DrawerPresentationProgressTracker {
    private weak var livePanel: (any DrawerLivePanelMotionReceiver)?
    private var latestProgress: CGFloat = 0
    private var hasProgress = false

    func update(_ progress: CGFloat) {
        latestProgress = progress
        hasProgress = true
        livePanel?.applyDrawerProgress(min(max(progress, 0), 1))
    }

    func attach(_ panel: any DrawerLivePanelMotionReceiver) {
        livePanel = panel
        panel.applyDrawerProgress(resolved(fallback: 0))
    }

    func detach(_ panel: any DrawerLivePanelMotionReceiver) {
        if livePanel === panel { livePanel = nil }
    }

    func resolved(fallback: CGFloat) -> CGFloat {
        min(max(hasProgress ? latestProgress : fallback, 0), 1)
    }
}

/// Candidate-only A/B switch. The baseline route stays available at launch;
/// switching hosts during a conversation would discard its local view state.
private enum DrawerLiveUIKitPanelExperiment {
    static let isEnabled = !ProcessInfo.processInfo.arguments.contains(
        "-disableDrawerLiveUIKitPanel"
    )
}

/// Launch-time comparison keeps the same live host and visual hierarchy.
private enum DrawerNativeHitRoutingExperiment {
    static let isEnabled = !ProcessInfo.processInfo.arguments.contains(
        "-disableDrawerNativeHitRouting"
    )
}

@MainActor
private protocol DrawerLivePanelMotionReceiver: AnyObject {
    func applyDrawerProgress(_ progress: CGFloat)
}

/// Geometry and chrome have separate observation consumers. Motion never
/// replaces the hosting controller's root, conversation, or message hierarchy.
@MainActor
@Observable
private final class DrawerLiveMainPanelConfiguration {
    var cornerRadius: CGFloat = 0
    var isInteractionBlocked = false
    var progress: CGFloat = 0
    @ObservationIgnored var onOpenDrawer: () -> Void = {}
    @ObservationIgnored var onCloseDrawer: () -> Void = {}
    @ObservationIgnored var isConversationDrawerClosePending: (UUID) -> Bool = { _ in false }
    @ObservationIgnored var onConversationContentReady: (UUID) -> Void = { _ in }
}

private struct DrawerLiveMainPanelChrome: ViewModifier {
    let configuration: DrawerLiveMainPanelConfiguration

    func body(content: Content) -> some View {
        content.modifier(
            MainChatPanelChrome(
                cornerRadius: configuration.cornerRadius,
                shadowProgress: configuration.progress,
                isInteractionBlocked: configuration.isInteractionBlocked,
                usesNativeTouchRouting: DrawerNativeHitRoutingExperiment.isEnabled,
                onCloseDrawer: { configuration.onCloseDrawer() }
            )
        )
    }
}

private struct DrawerLiveMainPanelContent: View {
    let model: AppModel
    let configuration: DrawerLiveMainPanelConfiguration

    var body: some View {
        // Keep keyboard layout in the same SwiftUI root as the composer and
        // transcript. Relaying its final inset from the outer root loses the
        // system's intermediate keyboard layout even with a SwiftUI transaction.
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let size = CGSize(
                width: proxy.size.width + insets.leading + insets.trailing,
                height: proxy.size.height + insets.top + insets.bottom
            )
            MainChatContainer(
                size: size,
                safeAreaInsets: insets,
                onOpenDrawer: { configuration.onOpenDrawer() },
                isConversationDrawerClosePending: { configuration.isConversationDrawerClosePending($0) },
                onConversationContentReady: { configuration.onConversationContentReady($0) }
            )
            .equatable()
            .modifier(DrawerLiveMainPanelChrome(configuration: configuration))
            .offset(x: -insets.leading, y: -insets.top)
        }
        .environment(model)
        .environment(\.locale, AppLocalization.shared.locale)
        .tint(Color(uiColor: model.themeActionUIColor))
        .accentColor(Color(uiColor: model.themeActionUIColor))
        .toggleStyle(SwitchToggleStyle(tint: Color(uiColor: model.themeSwitchUIColor)))
        .appFontEnvironment(model.preferences.appFontPostScriptName)
    }
}

/// The stationary wrapper must not swallow touches in the exposed drawer.
/// UIKit converts points through the live child's transform for hit testing.
private final class DrawerLivePanelPassthroughView: UIView {
    weak var touchShield: DrawerMainPanelTouchShield?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let touchShield, !touchShield.isHidden {
            guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
                  self.point(inside: point, with: event) else { return nil }
            // While the existing drawer gate owns this surface, the answer
            // depends only on the moved panel's rectangle. Do not enter the
            // hosting view to rebuild chat responders for a blocked touch.
            // A point outside this native child passes to the exposed drawer.
            return touchShield.hitTest(convert(point, to: touchShield), with: event)
        }
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Stable sibling of the live host. Root's existing ancestor drag gesture
/// remains responsible for axis arbitration, interruption and settling.
private final class DrawerMainPanelTouchShield: UIView {
    var onCloseDrawer: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isHidden = true
        isAccessibilityElement = true
        accessibilityLabel = L10n.lookup("关闭聊天列表")
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeDrawer)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closeDrawer(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !isHidden else { return }
        onCloseDrawer()
    }

    override func accessibilityActivate() -> Bool {
        guard !isHidden else { return false }
        onCloseDrawer()
        return true
    }
}

@MainActor
private final class DrawerLiveMainPanelController: UIViewController, DrawerLivePanelMotionReceiver {
    let configuration: DrawerLiveMainPanelConfiguration
    private let host: UIHostingController<DrawerLiveMainPanelContent>
    private let touchShield = DrawerMainPanelTouchShield(frame: .zero)
    private var tracker: DrawerPresentationProgressTracker?
    private var drawerWidth: CGFloat = 0
    private var progress: CGFloat = 0

    init(model: AppModel, configuration: DrawerLiveMainPanelConfiguration) {
        self.configuration = configuration
        host = UIHostingController(rootView: DrawerLiveMainPanelContent(
            model: model,
            configuration: configuration
        ))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let wrapper = DrawerLivePanelPassthroughView()
        wrapper.touchShield = touchShield
        view = wrapper
        view.backgroundColor = .clear
        view.clipsToBounds = false
        addChild(host)
        // This host owns safe-area and keyboard layout for its live content.
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        view.addSubview(host.view)
        host.didMove(toParent: self)
        view.addSubview(touchShield)
        touchShield.onCloseDrawer = { [weak configuration] in
            configuration?.onCloseDrawer()
        }
        updateInteractionRouting()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Never set frame on a transformed view: keep its layout rectangle
        // fixed and move only the complete live surface in the compositor.
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        if host.view.bounds != bounds { host.view.bounds = bounds }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if host.view.center != center { host.view.center = center }
        if touchShield.bounds != bounds { touchShield.bounds = bounds }
        if touchShield.center != center { touchShield.center = center }
        applyDrawerProgress(progress)
    }

    func connect(tracker: DrawerPresentationProgressTracker, drawerWidth: CGFloat) {
        self.drawerWidth = drawerWidth
        if self.tracker !== tracker {
            self.tracker?.detach(self)
            self.tracker = tracker
            tracker.attach(self)
        } else {
            applyDrawerProgress(tracker.resolved(fallback: progress))
        }
    }

    func applyDrawerProgress(_ progress: CGFloat) {
        self.progress = min(max(progress, 0), 1)
        guard isViewLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.view.transform = CGAffineTransform(translationX: drawerWidth * self.progress, y: 0)
        touchShield.transform = host.view.transform
        CATransaction.commit()
        // Only the existing lightweight chrome leaf observes this value.
        if configuration.progress != self.progress { configuration.progress = self.progress }
    }

    func updateInteractionRouting() {
        let hidden = !DrawerNativeHitRoutingExperiment.isEnabled
            || !configuration.isInteractionBlocked
        if touchShield.isHidden != hidden { touchShield.isHidden = hidden }
    }

    func disconnect() {
        tracker?.detach(self)
        tracker = nil
    }
}

private struct DrawerLiveMainPanelHost: UIViewControllerRepresentable {
    let model: AppModel
    let drawerWidth: CGFloat
    let cornerRadius: CGFloat
    let isInteractionBlocked: Bool
    let tracker: DrawerPresentationProgressTracker
    let onOpenDrawer: () -> Void
    let onCloseDrawer: () -> Void
    let isConversationDrawerClosePending: (UUID) -> Bool
    let onConversationContentReady: (UUID) -> Void

    func makeUIViewController(context: Context) -> DrawerLiveMainPanelController {
        let configuration = DrawerLiveMainPanelConfiguration()
        updateConfiguration(configuration)
        let controller = DrawerLiveMainPanelController(model: model, configuration: configuration)
        controller.loadViewIfNeeded()
        controller.connect(tracker: tracker, drawerWidth: drawerWidth)
        return controller
    }

    func updateUIViewController(_ controller: DrawerLiveMainPanelController, context: Context) {
        updateConfiguration(controller.configuration)
        controller.updateInteractionRouting()
        controller.connect(tracker: tracker, drawerWidth: drawerWidth)
    }

    private func updateConfiguration(_ configuration: DrawerLiveMainPanelConfiguration) {
        if configuration.cornerRadius != cornerRadius { configuration.cornerRadius = cornerRadius }
        if configuration.isInteractionBlocked != isInteractionBlocked {
            configuration.isInteractionBlocked = isInteractionBlocked
        }
        configuration.onOpenDrawer = onOpenDrawer
        configuration.onCloseDrawer = onCloseDrawer
        configuration.isConversationDrawerClosePending = isConversationDrawerClosePending
        configuration.onConversationContentReady = onConversationContentReady
    }

    static func dismantleUIViewController(_ controller: DrawerLiveMainPanelController, coordinator: Void) {
        controller.disconnect()
    }
}

private struct DrawerPresentationProgressTrackingModifier: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    let drawerWidth: CGFloat
    let tracker: DrawerPresentationProgressTracker

    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            tracker.update(newValue)
        }
    }

    func body(content: Content) -> some View {
        content.offset(x: drawerWidth * progress)
    }
}

/// A leaf-scoped continuation channel for the main chat panel. Root keeps only
/// this stable reference and never reads `progress` from `body`; observation is
/// established by `DrawerDetachedMainPanelMotionModifier` alone.
@MainActor
@Observable
private final class DrawerDetachedMainPanelProgress {
    private(set) var isActive = false
    private(set) var drivesDrawer = false
    private(set) var progress: CGFloat?

    func begin(at progress: CGFloat, drivesDrawer: Bool = false) {
        isActive = true
        self.drivesDrawer = drivesDrawer
        self.progress = min(max(progress, 0), 1)
    }

    func update(_ progress: CGFloat) {
        guard isActive else { return }
        self.progress = min(max(progress, 0), 1)
    }

    func clear() {
        isActive = false
        drivesDrawer = false
        progress = nil
    }
}

/// Root observes the start/end of finger tracking, while visual leaves observe
/// the changing progress. Keeping the initial value stable avoids invalidating
/// the root's GeometryReader for every sample of an already-owned gesture.
@MainActor
@Observable
private final class DrawerFingerTrackingProgress {
    private(set) var initialProgress: CGFloat?
    private(set) var progress: CGFloat?

    var isActive: Bool { initialProgress != nil }

    func set(_ value: CGFloat?) {
        let clamped = value.map { min(max($0, 0), 1) }
        if progress == nil || clamped == nil {
            if initialProgress != clamped { initialProgress = clamped }
        }
        if progress != clamped { progress = clamped }
    }
}

/// During finger tracking and automatic settle, this leaf reads progress
/// directly. Root therefore stays out of the sample update path while the
/// accepted drawer content, wallpaper, gestures, and hit-testing remain intact.
private struct DrawerLeafProgressConversationDrawer: View {
    let width: CGFloat
    let baseProgress: CGFloat
    let fingerProgress: DrawerFingerTrackingProgress
    let settleProgress: DrawerDetachedMainPanelProgress
    let backgroundTrailingExtension: CGFloat
    let safeAreaInsets: EdgeInsets
    let isDrawerGestureActive: Bool
    let topReturnCoordinator: DrawerListTopReturnCoordinator
    let onRequestClose: () -> Void
    let onRequestCloseAfterConversationReady: (UUID) -> Void

    var body: some View {
        let leafProgress = settleProgress.drivesDrawer
            ? settleProgress.progress
            : nil
        let progress = min(max(leafProgress ?? fingerProgress.progress ?? baseProgress, 0), 1)

        ConversationDrawer(
            width: width,
            progress: progress,
            settleProgress: settleProgress,
            backgroundTrailingExtension: backgroundTrailingExtension,
            safeAreaInsets: safeAreaInsets,
            isDrawerGestureActive: isDrawerGestureActive,
            topReturnCoordinator: topReturnCoordinator,
            onRequestClose: onRequestClose,
            onRequestCloseAfterConversationReady: onRequestCloseAfterConversationReady
        )
    }
}

/// Reads the detached channel only inside the right panel branch. During a
/// vertical drawer-list takeover, the existing spring can therefore finish its
/// exact trajectory here while the left ScrollView remains at a stable model
/// value and continues its native vertical bounce.
private struct DrawerDetachedMainPanelMotionModifier: ViewModifier {
    let baseProgress: CGFloat
    let fingerProgress: DrawerFingerTrackingProgress
    let detachedProgress: DrawerDetachedMainPanelProgress
    let drawerWidth: CGFloat
    let cornerRadius: CGFloat
    let isInteractionBlocked: Bool
    let tracker: DrawerPresentationProgressTracker
    let onCloseDrawer: () -> Void

    func body(content: Content) -> some View {
        let progress = min(max(detachedProgress.progress ?? fingerProgress.progress ?? baseProgress, 0), 1)

        content
            .modifier(
                MainChatPanelChrome(
                    cornerRadius: cornerRadius,
                    shadowProgress: progress,
                    isInteractionBlocked: isInteractionBlocked,
                    onCloseDrawer: onCloseDrawer
                )
            )
            .modifier(
                DrawerPresentationProgressTrackingModifier(
                    progress: progress,
                    drawerWidth: drawerWidth,
                    tracker: tracker
                )
            )
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var drawerFingerProgress = DrawerFingerTrackingProgress()
    // Event handlers keep their existing takeover/release semantics. Only the
    // visual leaves read this changing value while SwiftUI evaluates a body.
    private var drawerDragProgress: CGFloat? {
        get { drawerFingerProgress.progress }
        nonmutating set { drawerFingerProgress.set(newValue) }
    }
    @State private var drawerDragStartProgress: CGFloat = 0
    @State private var drawerDragActivationTranslationX: CGFloat = 0
    @State private var drawerSettleTask: Task<Void, Never>?
    @State private var drawerSettleSequence: UInt64 = 0
    @State private var drawerSettleDriver = DrawerSettleDisplayLinkDriver()
    @State private var drawerGestureLocked: Bool?
    @State private var isDrawerGestureActive = false
    @State private var pendingDrawerCloseConversationID: UUID?
    @State private var drawerPresentationProgressTracker = DrawerPresentationProgressTracker()
    @State private var detachedMainPanelProgress = DrawerDetachedMainPanelProgress()
    @State private var drawerListTopReturnCoordinator = DrawerListTopReturnCoordinator()
    @State private var bottomToolPhotoSelection: [PhotosPickerItem] = []
    @State private var bottomToolAttachmentDestinationConversationID: UUID?
    @State private var didScheduleDrawerTrackedLayerAutoOpen = false
    private let drawerGestureIntentDistance: CGFloat = 18
    private let drawerGestureAxisRatio: CGFloat = 1.75

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            let safeAreaInsets = proxy.safeAreaInsets
            let fullSize = CGSize(
                width: proxy.size.width + safeAreaInsets.leading + safeAreaInsets.trailing,
                height: proxy.size.height + safeAreaInsets.top + safeAreaInsets.bottom
            )
            let drawerWidth = min(fullSize.width * 0.78, 390)
            let settledProgress: CGFloat = model.isDrawerPresented ? 1 : 0
            let drawerProgress = min(max(drawerFingerProgress.initialProgress ?? settledProgress, 0), 1)
            let drawerVisible = drawerFingerProgress.isActive
                || detachedMainPanelProgress.isActive
                || drawerProgress > 0.001
                || model.isDrawerPresented
            // Keep the panel fully rounded for the entire drawer interaction.
            // Scaling the radius with progress exposes a square panel during a
            // fast conversation switch followed immediately by a drawer drag.
            let chatCornerRadius: CGFloat = drawerVisible ? 44 : 0

            ZStack(alignment: .leading) {
                DrawerLeafProgressConversationDrawer(
                    width: drawerWidth,
                    baseProgress: drawerProgress,
                    fingerProgress: drawerFingerProgress,
                    settleProgress: detachedMainPanelProgress,
                    backgroundTrailingExtension: chatCornerRadius,
                    safeAreaInsets: safeAreaInsets,
                    isDrawerGestureActive: isDrawerGestureActive,
                    topReturnCoordinator: drawerListTopReturnCoordinator,
                    onRequestClose: closeDrawerAnimated,
                    onRequestCloseAfterConversationReady: requestDrawerCloseAfterConversationReady
                )
                    .frame(height: fullSize.height)
                    .offset(x: -safeAreaInsets.leading, y: -safeAreaInsets.top)
                    .allowsHitTesting(drawerVisible)
                    .accessibilityHidden(!drawerVisible)
                    .simultaneousGesture(
                        drawerDragGesture(
                            drawerWidth: drawerWidth,
                            baseProgress: drawerProgress,
                            finishesOpeningSettleForVerticalIntent: true
                        )
                    )
                    .zIndex(1)

                Group {
                    if DrawerLiveUIKitPanelExperiment.isEnabled {
                        DrawerLiveMainPanelHost(
                            model: model,
                            drawerWidth: drawerWidth,
                            cornerRadius: chatCornerRadius,
                            isInteractionBlocked: model.isDrawerPresented || isDrawerGestureActive,
                            tracker: drawerPresentationProgressTracker,
                            onOpenDrawer: openDrawerFromButton,
                            onCloseDrawer: closeDrawerAnimated,
                            isConversationDrawerClosePending: isDrawerClosePending,
                            onConversationContentReady: handleConversationContentReady
                        )
                        .frame(width: fullSize.width, height: fullSize.height)
                    } else {
                        MainChatContainer(
                            size: fullSize,
                            safeAreaInsets: safeAreaInsets,
                            onOpenDrawer: openDrawerFromButton,
                            isConversationDrawerClosePending: isDrawerClosePending,
                            onConversationContentReady: handleConversationContentReady
                        )
                            .equatable()
                            // Native scrolling is gated imperatively by
                            // DrawerNativeScrollGate. Avoid sending a transient
                            // scrollDisabled environment change through every message.
                            .modifier(
                                DrawerDetachedMainPanelMotionModifier(
                                    baseProgress: drawerProgress,
                                    fingerProgress: drawerFingerProgress,
                                    detachedProgress: detachedMainPanelProgress,
                                    drawerWidth: drawerWidth,
                                    cornerRadius: chatCornerRadius,
                                    isInteractionBlocked: model.isDrawerPresented || isDrawerGestureActive,
                                    tracker: drawerPresentationProgressTracker,
                                    onCloseDrawer: closeDrawerAnimated
                                )
                            )
                    }
                }
                    .offset(x: -safeAreaInsets.leading, y: -safeAreaInsets.top)
                    .simultaneousGesture(
                        drawerDragGesture(
                            drawerWidth: drawerWidth,
                            baseProgress: drawerProgress,
                            finishesOpeningSettleForVerticalIntent: false
                        )
                    )
                    .zIndex(2)

            }
            .background(
                    Color(uiColor: model.themeSurfaceUIColor)
                    .ignoresSafeArea()
            )
        }
        .tint(Color(uiColor: model.themeActionUIColor))
        .accentColor(Color(uiColor: model.themeActionUIColor))
        .background(Color(uiColor: model.themeSurfaceUIColor).ignoresSafeArea())
        .overlay(alignment: .top) {
            VoicePlaybackOverlay()
                .zIndex(30)
        }
        .sheet(isPresented: $model.isProviderSettingsPresented) {
            ProviderSettingsView()
        }
        .sheet(isPresented: $model.isModelSelectorPresented) {
            ModelSelectorView(
                selectedSelection: model.effectiveModelContext?.selection,
                screenTitle: L10n.lookup("聊天模型"),
                chatOnly: true,
                onSelect: { selection in
                    guard let selection else { return }
                    model.selectChatModelForCurrentAssistant(selection)
                }
            )
        }
        .sheet(isPresented: $model.isAssistantSelectorPresented) {
            AssistantSelectorView()
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView()
        }
        .sheet(isPresented: $model.isUserProfilePresented) {
            UserProfileView()
        }
        .sheet(isPresented: $model.isFavoritesPresented) {
            FavoriteMessagesView()
        }
        .sheet(isPresented: $model.isCalendarPresented) {
            MoccaCalendarView()
        }
        .fullScreenCover(isPresented: $model.isFirstRunModelSetupPresented) {
            FirstRunModelSetupView {
                model.dismissFirstRunModelSetup()
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            model.applyAppearanceMode()
            DrawerHighRefreshLease.prepare()
            detachedMainPanelProgress.clear()
            drawerPresentationProgressTracker.update(model.isDrawerPresented ? 1 : 0)
            model.setDrawerStreamingTextDisplaySuspended(
                model.isDrawerPresented
            )
            syncDrawerNativeScrollGate()
#if targetEnvironment(simulator)
            if !didScheduleDrawerTrackedLayerAutoOpen,
               ProcessInfo.processInfo.arguments.contains(where: {
                   $0 == "-diagnoseDrawerTrackedLayerAutoOpen"
                       || $0 == "-diagnoseDrawerTrackedLayerAutoCycle"
               }) {
                didScheduleDrawerTrackedLayerAutoOpen = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    openDrawerFromButton()
                    if ProcessInfo.processInfo.arguments.contains(
                        "-diagnoseDrawerTrackedLayerAutoCycle"
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            closeDrawerAnimated()
                        }
                    }
                }
            }
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            finishInterruptedDrawerInteraction()
        }
        .onChange(of: model.isDrawerPresented) { _, isPresented in
            if isPresented {
                model.setDrawerStreamingTextDisplaySuspended(true)
            }
            if !isPresented, detachedMainPanelProgress.isActive {
                // The close settle publishes false after its first frame. Keep
                // that driver's spring phase when it already owns the close;
                // only an interrupted or unowned transition needs a rejoin.
                if drawerSettleDriver.activeTargetProgress != 0
                    || isDrawerGestureActive
                    || pendingDrawerCloseConversationID != nil {
                    continueDrawerCloseAfterExternalSemanticChange()
                }
            } else if drawerDragProgress == nil, !detachedMainPanelProgress.isActive {
                drawerPresentationProgressTracker.update(isPresented ? 1 : 0)
            }
            syncDrawerNativeScrollGate()
        }
        .onChange(of: model.selectedConversationID) { _, _ in
            let visualProgress = drawerPresentationProgressTracker.resolved(
                fallback: model.isDrawerPresented ? 1 : 0
            )
            if visualProgress > 0.001 {
                model.setDrawerStreamingTextDisplaySuspended(true)
            }
        }
        .sheet(isPresented: $model.isBottomToolsPresented) {
            BottomToolsPresentationHost(
                toolsModel: model.bottomTools,
                photoSelection: $bottomToolPhotoSelection,
                attachmentDestinationConversationID:
                    $bottomToolAttachmentDestinationConversationID
            )
        }
        .onChange(of: bottomToolPhotoSelection) { _, items in
            consumeBottomToolPhotoSelection(items)
        }
        .alert(L10n.lookup("请求失败"), isPresented: $model.isErrorPresented) {
            Button(L10n.lookup("好"), role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
        .alert(L10n.lookup("文件已存在"), isPresented: Binding(
            get: { model.pendingDuplicateFileDecision != nil },
            set: {
                if !$0, model.pendingDuplicateFileDecision != nil {
                    model.resolveDuplicateFileDecision(useExisting: false)
                }
            }
        )) {
            Button(L10n.lookup("使用现有文件")) {
                model.resolveDuplicateFileDecision(useExisting: true)
            }
            Button(L10n.lookup("再保存一份")) {
                model.resolveDuplicateFileDecision(useExisting: false)
            }
        } message: {
            if let request = model.pendingDuplicateFileDecision {
                Text(L10n.format("Mocca 中已有相同文件“%@”。请选择发送方式。", [String(describing: request.fileName)]))
            }
        }
        .modifier(ToolApprovalAlertModifier(model: model, request: model.pendingToolApproval))
        .onDisappear {
            model.setDrawerStreamingTextDisplaySuspended(false)
            cancelDrawerSettleWork()
            detachedMainPanelProgress.clear()
            drawerListTopReturnCoordinator.reset()
            let semanticEndpoint: CGFloat = model.isDrawerPresented ? 1 : 0
            drawerPresentationProgressTracker.update(semanticEndpoint)
            drawerDragProgress = nil
            DrawerFrameTrace.rootDidDisappear()
            DrawerHighRefreshLease.stop()
            isDrawerGestureActive = false
            DrawerNativeScrollGate.reset()
            DrawerViewportRefreshFreeze.reset()
            DrawerInlineActionTapGate.reset()
            pendingDrawerCloseConversationID = nil
        }
    }

    private func consumeBottomToolPhotoSelection(
        _ items: [PhotosPickerItem]
    ) {
        guard !items.isEmpty else { return }
        let conversationID = bottomToolAttachmentDestinationConversationID
            ?? model.selectedConversationID
        bottomToolPhotoSelection = []
        Task { @MainActor in
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    model.addPendingImage(image, for: conversationID)
                }
            }
            if bottomToolAttachmentDestinationConversationID == conversationID {
                bottomToolAttachmentDestinationConversationID = nil
            }
        }
    }

    private func cancelDrawerSettleWork(releasingViewportFreeze: Bool = true) {
        drawerSettleSequence &+= 1
        drawerSettleTask?.cancel()
        drawerSettleTask = nil
        drawerSettleDriver.stop()
        // A synchronous replacement settle retains this lease until its own
        // completion. Cancellation without a replacement releases it here.
        if releasingViewportFreeze {
            DrawerViewportRefreshFreeze.setSettling(false)
        }
    }

    /// A system interruption can cancel DragGesture without delivering onEnded.
    /// Finish from the last displayed position before the scene is suspended;
    /// a stable endpoint only needs its pending automatic close cancelled.
    private func finishInterruptedDrawerInteraction() {
        // Content can become ready after deactivation even when no gesture or
        // settle is active. Cancel that intent before the stable-state return;
        // the selected conversation and its loading work remain intact.
        pendingDrawerCloseConversationID = nil
        guard isDrawerGestureActive
                || drawerDragProgress != nil
                || detachedMainPanelProgress.isActive
                || drawerSettleDriver.activeTargetProgress != nil else {
            drawerGestureLocked = nil
            drawerDragActivationTranslationX = 0
            return
        }
        let progress = drawerPresentationProgressTracker.resolved(
            fallback: drawerDragProgress
                ?? detachedMainPanelProgress.progress
                ?? (model.isDrawerPresented ? 1 : 0)
        )
        let open = progress == 0.5 ? model.isDrawerPresented : progress > 0.5
        let endpoint: CGFloat = open ? 1 : 0

        // Invalidate delayed semantic commits and stop the display link first,
        // retaining its refresh protection until both visual channels agree.
        cancelDrawerSettleWork(releasingViewportFreeze: false)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            detachedMainPanelProgress.clear()
            drawerDragProgress = nil
            drawerGestureLocked = nil
            drawerDragStartProgress = endpoint
            drawerDragActivationTranslationX = 0
            // Lifecycle reconciliation has no new user action to vibrate for.
            model.isDrawerPresented = open
            drawerPresentationProgressTracker.update(endpoint)
            drawerListTopReturnCoordinator.finishSoftTopReturnForDrawerOpening()
            setDrawerGestureActive(false)
            DrawerViewportRefreshFreeze.setSettling(false)
            model.setDrawerStreamingTextDisplaySuspended(open)
        }
        DrawerInlineActionTapGate.reset()
        DrawerFrameTrace.sceneDidDeactivate()
        DrawerHighRefreshLease.stop()
    }

    @discardableResult
    private func startDrawerSettleProgress(from start: CGFloat, to target: CGFloat) -> UInt64 {
        drawerSettleSequence &+= 1
        let sequence = drawerSettleSequence
        DrawerViewportRefreshFreeze.setSettling(true)
        if max(start, target) > 0.001 {
            model.setDrawerStreamingTextDisplaySuspended(true)
        }
        VersionFlashTrace.record(
            "DRAWER_SETTLE_BEGIN"
                + " seq=\(sequence)"
                + " from=\(String(format: "%.5f", Double(start)))"
                + " to=\(String(format: "%.5f", Double(target)))"
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            detachedMainPanelProgress.begin(
                at: start,
                drivesDrawer: true
            )
            drawerDragProgress = nil
        }
        drawerSettleDriver.start(
            from: start,
            to: target,
            onProgress: { progress in
                guard drawerSettleSequence == sequence else { return }
                if detachedMainPanelProgress.isActive {
                    detachedMainPanelProgress.update(progress)
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        drawerDragProgress = progress
                    }
                }
                drawerPresentationProgressTracker.update(progress)
            },
            onCompletion: {
                guard drawerSettleSequence == sequence else { return }
                let completedDetachedSettle = detachedMainPanelProgress.isActive
                VersionFlashTrace.record(
                    "DRAWER_SETTLE_COMPLETE"
                        + " seq=\(sequence)"
                        + " target=\(String(format: "%.5f", Double(target)))"
                        + " route=\(completedDetachedSettle ? "main-panel" : "root")"
                )
                if completedDetachedSettle {
                    detachedMainPanelProgress.update(target)
                }
                drawerPresentationProgressTracker.update(target)
                DrawerViewportRefreshFreeze.setSettling(false)
                model.setDrawerStreamingTextDisplaySuspended(target > 0.001)
                if completedDetachedSettle {
                    detachedMainPanelProgress.clear()
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        drawerDragProgress = nil
                    }
                }
            }
        )
        return sequence
    }

    private func drawerDragGesture(
        drawerWidth: CGFloat,
        baseProgress: CGFloat,
        finishesOpeningSettleForVerticalIntent: Bool
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard scenePhase == .active else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if drawerGestureLocked == nil {
                    // Native selection owns a touch that is already on its
                    // selected range/handles. Horizontal content likewise owns
                    // a touch that starts inside its real UIScrollView. Keep
                    // the drawer available from every other point in the chat
                    // instead of shrinking it to a screen-edge strip.
                    if (model.isComposerFocused
                        && ComposerTextSelectionInteractionGate.ownsCurrentTouch)
                        || DrawerTextSelectionInteractionGate.ownsCurrentTouch
                        || DrawerHorizontalScrollGate.ownsCurrentTouch {
                        drawerGestureLocked = false
                        setDrawerGestureActive(false)
                        return
                    }
                    guard max(abs(dx), abs(dy)) >= 8 else { return }
                    if abs(dy) > abs(dx) * 1.05 {
                        drawerGestureLocked = false
                        setDrawerGestureActive(false)
                        // Do not let the opening display-link keep reconciling
                        // the drawer while its native list begins a vertical
                        // rubber-band gesture. Preserve the list's own bounce;
                        // only finish the already-authorized opening settle.
                        if finishesOpeningSettleForVerticalIntent {
                            finishDrawerOpeningSettleForVerticalIntentIfNeeded()
                        }
                        return
                    }
                    let isOpeningFromClosed = baseProgress < 0.5
                    guard abs(dx) >= drawerGestureIntentDistance,
                          abs(dx) > abs(dy) * drawerGestureAxisRatio else {
                        return
                    }
                    guard !isOpeningFromClosed || dx > 0 else {
                        drawerGestureLocked = false
                        setDrawerGestureActive(false)
                        return
                    }
                    drawerGestureLocked = true
                    // The finger also takes over an automatic close that is
                    // still waiting for content. Its late readiness callback
                    // must not start a new settle while this touch owns motion.
                    pendingDrawerCloseConversationID = nil
                    model.setDrawerStreamingTextDisplaySuspended(true)
                    drawerDragActivationTranslationX = dx
                    if isOpeningFromClosed {
                        drawerListTopReturnCoordinator
                            .finishSoftTopReturnForDrawerOpening()
                    } else if dx < 0 {
                        drawerListTopReturnCoordinator.beginSoftTopReturnIfNeeded()
                    }
                    setDrawerGestureActive(true)
                    DrawerInlineActionTapGate.beginDrawerDrag()
                    // Freeze an in-flight automatic settle before reading its
                    // latest sampled progress, then let the finger take over
                    // that exact position.
                    cancelDrawerSettleWork()
                    let presentationProgress = drawerPresentationProgressTracker.resolved(
                        fallback: baseProgress
                    )
                    drawerDragStartProgress = presentationProgress
                    adoptDrawerPresentationProgressForRoot(presentationProgress)
                    DrawerHighRefreshLease.begin()
                    DrawerFrameTrace.begin(
                        startProgress: presentationProgress,
                        logicalStartProgress: baseProgress
                    )
                    if isOpeningFromClosed {
                        dismissComposerKeyboardForDrawerOpening()
                    }
                }
                guard drawerGestureLocked == true else { return }
                // The initial translation only establishes horizontal intent.
                // Start visual movement at takeover instead of revealing the
                // accumulated recognition distance in one frame.
                let visualTranslationX = dx - drawerDragActivationTranslationX
                let nextProgress = drawerDragStartProgress
                    + visualTranslationX / max(drawerWidth, 1)
                let clampedProgress = min(max(nextProgress, 0), 1)
                drawerDragProgress = clampedProgress
                drawerPresentationProgressTracker.update(clampedProgress)
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let didOwnDrawerGesture = drawerGestureLocked == true
                defer {
                    if didOwnDrawerGesture {
                        DrawerInlineActionTapGate.endDrawerDrag()
                        DrawerFrameTrace.touchEnded(finalProgress: drawerDragProgress)
                        DrawerHighRefreshLease.releaseAfterSettle()
                    }
                    drawerDragActivationTranslationX = 0
                    drawerGestureLocked = nil
                    setDrawerGestureActive(false)
                }
                guard drawerGestureLocked == true,
                      drawerDragProgress != nil,
                      abs(dx) > max(drawerGestureIntentDistance, abs(dy) * drawerGestureAxisRatio) else {
                    if drawerGestureLocked == true, drawerDragProgress != nil {
                        settleDrawer(open: model.isDrawerPresented)
                    }
                    return
                }
                let currentProgress = min(max(drawerDragProgress ?? drawerDragStartProgress, 0), 1)
                let predictedProgress = min(
                    max(drawerDragStartProgress + value.predictedEndTranslation.width / max(drawerWidth, 1), 0),
                    1
                )
                let meaningfulOpenDrag = dx > 56
                let meaningfulCloseDrag = dx < -44
                let shouldOpen = if drawerDragStartProgress >= 0.5 {
                    if meaningfulCloseDrag {
                        predictedProgress > 0.45
                    } else {
                        currentProgress > 0.44 || predictedProgress > 0.58
                    }
                } else {
                    currentProgress > 0.52 || (meaningfulOpenDrag && predictedProgress > 0.62)
                }
                settleDrawer(open: shouldOpen)
            }
    }

    private func finishDrawerOpeningSettleForVerticalIntentIfNeeded() {
        guard let targetProgress = drawerSettleDriver.activeTargetProgress,
              targetProgress >= 0.5,
              model.isDrawerPresented,
              !detachedMainPanelProgress.isActive else { return }
        let interruptedProgress = drawerPresentationProgressTracker.resolved(
            fallback: drawerDragProgress ?? targetProgress
        )

        // Keep the existing display-link and spring phase alive, but move its
        // remaining output to the right panel's leaf-scoped observation
        // channel. The left drawer immediately becomes a stable fully-open
        // model and can rubber-band vertically without Root progress writes.
        detachedMainPanelProgress.begin(at: interruptedProgress)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drawerDragProgress = nil
        }
        syncDrawerNativeScrollGate()

        VersionFlashTrace.record(
            "DRAWER_SETTLE_VERTICAL_DETACH"
                + " from=\(String(format: "%.5f", Double(interruptedProgress)))"
                + " target=\(String(format: "%.5f", Double(targetProgress)))"
        )
    }

    private func adoptDrawerPresentationProgressForRoot(_ progress: CGFloat) {
        let clampedProgress = min(max(progress, 0), 1)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            detachedMainPanelProgress.clear()
            drawerDragProgress = clampedProgress
        }
        drawerPresentationProgressTracker.update(clampedProgress)
    }

    private func setDrawerGestureActive(_ isActive: Bool) {
        isDrawerGestureActive = isActive
        DrawerViewportRefreshFreeze.setDragging(isActive)
        drawerListTopReturnCoordinator
            .setDrawerGestureLockActive(isActive)
        syncDrawerNativeScrollGate()
    }

    private func syncDrawerNativeScrollGate() {
        DrawerNativeScrollGate.update(
            isDrawerPresented: model.isDrawerPresented,
            isDrawerGestureActive: isDrawerGestureActive
        )
        drawerListTopReturnCoordinator.setStatusBarScrollToTopEnabled(
            model.isDrawerPresented && !isDrawerGestureActive
        )
    }

    private func openDrawerFromButton() {
        guard !model.isDrawerPresented else { return }
        model.setDrawerStreamingTextDisplaySuspended(true)
        pendingDrawerCloseConversationID = nil
        drawerListTopReturnCoordinator
            .finishSoftTopReturnForDrawerOpening()
        dismissComposerKeyboardForDrawerOpening()
        cancelDrawerSettleWork(releasingViewportFreeze: false)
        setDrawerGestureActive(false)
        // The close-side semantic state flips after 9 ms while its visual
        // settle continues. If TopBar is tapped during that tail, reverse from
        // the sampled on-screen position instead of snapping back to zero.
        let currentProgress = min(
            max(
                drawerDragProgress
                    ?? drawerPresentationProgressTracker.resolved(fallback: 0),
                0
            ),
            1
        )
        adoptDrawerPresentationProgressForRoot(currentProgress)
        model.setDrawerPresented(true)
        syncDrawerNativeScrollGate()
        startDrawerSettleProgress(from: currentProgress, to: 1)
    }

    private func closeDrawerAnimated() {
        settleDrawer(open: false)
    }

    private func requestDrawerCloseAfterConversationReady(_ conversationID: UUID) {
        guard model.isDrawerPresented,
              model.selectedConversationID == conversationID else { return }
        pendingDrawerCloseConversationID = conversationID
        VersionFlashTrace.record(
            "DRAWER_CLOSE_ARMED"
                + " conv=\(VersionFlashTrace.identifierToken(conversationID))"
        )
    }

    private func isDrawerClosePending(for conversationID: UUID) -> Bool {
        pendingDrawerCloseConversationID == conversationID
            && model.isDrawerPresented
            && model.selectedConversationID == conversationID
    }

    private func handleConversationContentReady(_ conversationID: UUID) {
        guard pendingDrawerCloseConversationID == conversationID,
              model.isDrawerPresented,
              model.selectedConversationID == conversationID else { return }
        VersionFlashTrace.record(
            "DRAWER_CLOSE_READY"
                + " conv=\(VersionFlashTrace.identifierToken(conversationID))"
        )
        pendingDrawerCloseConversationID = nil
        settleDrawer(open: false)
    }

    private func continueDrawerCloseAfterExternalSemanticChange() {
        // Some AppModel actions (for example branch/group creation) publish the
        // semantic close directly. If that happens while the opening remainder
        // is detached to the right panel, invalidate that exact driver before
        // it can complete at 1 and hand its sampled presentation back to the
        // root-owned close path.
        cancelDrawerSettleWork(releasingViewportFreeze: false)
        pendingDrawerCloseConversationID = nil
        setDrawerGestureActive(false)
        let currentProgress = drawerPresentationProgressTracker.resolved(
            fallback: detachedMainPanelProgress.progress ?? drawerDragProgress ?? 1
        )
        adoptDrawerPresentationProgressForRoot(currentProgress)
        VersionFlashTrace.record(
            "DRAWER_EXTERNAL_CLOSE_REJOIN"
                + " from=\(String(format: "%.5f", Double(currentProgress)))"
        )
        startDrawerSettleProgress(from: currentProgress, to: 0)
    }

    private func settleDrawer(open: Bool) {
        let fallbackProgress = drawerDragProgress ?? (model.isDrawerPresented ? 1 : 0)
        cancelDrawerSettleWork(releasingViewportFreeze: false)
        pendingDrawerCloseConversationID = nil
        let currentProgress = drawerPresentationProgressTracker.resolved(
            fallback: fallbackProgress
        )
        adoptDrawerPresentationProgressForRoot(currentProgress)
        model.setDrawerStreamingTextDisplaySuspended(true)
        if open {
            // Transfer the chat scroll lock to the presented drawer before
            // releasing gesture ownership, avoiding an enable/disable round trip.
            model.setDrawerPresented(true)
            startDrawerSettleProgress(from: currentProgress, to: 1)
            // Acquire the settle lease before releasing the drag lease so
            // pending viewport work does not resume between the two phases.
            setDrawerGestureActive(false)
        } else {
            let sequence = startDrawerSettleProgress(from: currentProgress, to: 0)
            setDrawerGestureActive(false)
            drawerSettleTask = Task { @MainActor in
                // Give the 120 Hz spring one frame to commit before publishing
                // the semantic close. That state change invalidates both the
                // drawer and chat subtrees; keeping it out of the first settle
                // frame avoids stacking their work. A rapid reversal cancels
                // this task before the close is committed.
                try? await Task.sleep(for: .milliseconds(9))
                guard !Task.isCancelled,
                      !isDrawerGestureActive,
                      drawerSettleSequence == sequence else { return }
                model.setDrawerPresented(false)
                VersionFlashTrace.record(
                    "DRAWER_SEMANTIC_CLOSE"
                        + " seq=\(sequence)"
                        + " sampledProgress=\(String(format: "%.5f", Double(drawerDragProgress ?? 0)))"
                        + " semantic=\(model.isDrawerPresented)"
                )
                syncDrawerNativeScrollGate()
                drawerSettleTask = nil
            }
        }
    }

    private func dismissComposerKeyboardForDrawerOpening() {
        model.isComposerFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct MainChatContainer: View, @preconcurrency Equatable {
    @Environment(AppModel.self) private var model
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let onOpenDrawer: () -> Void
    let isConversationDrawerClosePending: (UUID) -> Bool
    let onConversationContentReady: (UUID) -> Void

    static func == (lhs: MainChatContainer, rhs: MainChatContainer) -> Bool {
        lhs.size.width == rhs.size.width
            && lhs.size.height == rhs.size.height
            && lhs.safeAreaInsets.top == rhs.safeAreaInsets.top
            && lhs.safeAreaInsets.bottom == rhs.safeAreaInsets.bottom
            && lhs.safeAreaInsets.leading == rhs.safeAreaInsets.leading
            && lhs.safeAreaInsets.trailing == rhs.safeAreaInsets.trailing
    }

    var body: some View {
        ZStack {
            Color(uiColor: model.themeSurfaceUIColor)

            StableChatViewHost(
                safeAreaInsets: safeAreaInsets,
                onOpenDrawer: onOpenDrawer,
                isConversationDrawerClosePending: isConversationDrawerClosePending,
                onConversationContentReady: onConversationContentReady
            )
            .equatable()
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct MainChatPanelChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    let cornerRadius: CGFloat
    let shadowProgress: CGFloat
    let isInteractionBlocked: Bool
    var usesNativeTouchRouting = false
    let onCloseDrawer: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                // ChatGPT-style light scrim: one flat color layer rather than
                // a live blur/material, so the drawer keeps a cheap render path.
                Color(uiColor: model.themeSurfaceUIColor)
                    .opacity(0.38 * shadowProgress)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onCloseDrawer()
                    }
                    .allowsHitTesting(isInteractionBlocked && !usesNativeTouchRouting)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: cornerRadius,
                    style: .continuous
                )
            )
            .background {
                DrawerPanelShadowLayer(
                    cornerRadius: cornerRadius,
                    progress: shadowProgress
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// Keeps the drawer shadow out of the long transcript's composited alpha tree.
/// Apple recommends an explicit CALayer.shadowPath so Core Animation can draw
/// the known panel outline without first rendering the entire subtree offscreen.
private struct DrawerPanelShadowLayer: UIViewRepresentable {
    let cornerRadius: CGFloat
    let progress: CGFloat

    func makeUIView(context: Context) -> DrawerPanelShadowBackingView {
        let view = DrawerPanelShadowBackingView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: DrawerPanelShadowBackingView, context: Context) {
        uiView.update(cornerRadius: cornerRadius, progress: progress)
    }
}

private final class DrawerPanelShadowBackingView: UIView {
    private var panelCornerRadius: CGFloat = 0
    private var drawerProgress: CGFloat = 0
    private var shadowPathBounds: CGRect = .null
    private var shadowPathCornerRadius: CGFloat = -1
    private var shadowPathLayoutDirection: UIUserInterfaceLayoutDirection?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cornerRadius: CGFloat, progress: CGFloat) {
        let clampedProgress = min(max(progress, 0), 1)
        guard panelCornerRadius != cornerRadius || drawerProgress != clampedProgress else { return }
        let cornerChanged = panelCornerRadius != cornerRadius
        panelCornerRadius = cornerRadius
        drawerProgress = clampedProgress
        applyShadowProperties()
        if cornerChanged {
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyShadowProperties()
    }

    private func applyShadowProperties() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowOpacity = Float(0.18 * drawerProgress)
        // Restore the accepted visual ramp instead of paying the full 26-point
        // blur footprint from the first drag sample, as build 4473 did.
        layer.shadowRadius = 26 * drawerProgress
        layer.shadowOffset = CGSize(width: -8 * drawerProgress, height: 0)
        if bounds.width > 0,
           bounds.height > 0,
           (shadowPathBounds != bounds
                || shadowPathCornerRadius != panelCornerRadius
                || shadowPathLayoutDirection != effectiveUserInterfaceLayoutDirection) {
            let roundedCorners: UIRectCorner = effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? [.topRight, .bottomRight]
                : [.topLeft, .bottomLeft]
            layer.shadowPath = UIBezierPath(
                roundedRect: bounds,
                byRoundingCorners: roundedCorners,
                cornerRadii: CGSize(width: panelCornerRadius, height: panelCornerRadius)
            ).cgPath
            shadowPathBounds = bounds
            shadowPathCornerRadius = panelCornerRadius
            shadowPathLayoutDirection = effectiveUserInterfaceLayoutDirection
        } else if bounds.width <= 0 || bounds.height <= 0 {
            layer.shadowPath = nil
            shadowPathBounds = .null
            shadowPathCornerRadius = -1
            shadowPathLayoutDirection = nil
        }
        CATransaction.commit()
    }
}

private struct BottomToolsPresentationHost: View {
    @Environment(AppModel.self) private var model
    @Bindable var toolsModel: BottomToolsModel
    @State private var isPhotosPickerPresented = false
    @State private var isCameraPresented = false
    @State private var isFileImporterPresented = false
    @State private var isAttachmentHandoffActive = false
    @Binding var photoSelection: [PhotosPickerItem]
    @Binding var attachmentDestinationConversationID: UUID?

    var body: some View {
        BottomToolsSheet(
            model: toolsModel,
            onInstructionToggle: model.toggleInstructionActive,
            onWorldBookToggle: model.toggleWorldBookActive,
            onAction: handleAction,
            isAttachmentHandoffActive: isAttachmentHandoffActive
        )
        // These presenters live inside the already-visible tools sheet. This
        // lets iOS begin presenting immediately instead of waiting for the
        // parent sheet's dismissal animation to finish first.
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: isPhotosPickerPresented) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            // PhotosPicker publishes its selection into RootView-owned state.
            // Remove the parent sheet while the system picker still covers it
            // so the adapted sheet cannot flash back before dismissing.
            dismissBottomTools()
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker(onWillDismiss: dismissBottomTools) { image in
                let conversationID = attachmentDestinationConversationID
                    ?? model.selectedConversationID
                model.addPendingImage(image, for: conversationID)
                attachmentDestinationConversationID = nil
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: { result in
                let conversationID = attachmentDestinationConversationID
                    ?? model.selectedConversationID
                attachmentDestinationConversationID = nil
                if case .success(let urls) = result {
                    model.addPendingFiles(urls, for: conversationID)
                }
                dismissBottomTools()
            },
            // The older overload never calls onCompletion for a user cancel,
            // which left the one-point parent sheet (and its backdrop) alive.
            onCancellation: dismissBottomTools
        )
    }

    private func handleAction(_ action: BottomToolAction) {
        switch action {
        case .camera, .photos, .uploadFile:
            attachmentDestinationConversationID = model.selectedConversationID
            switch action {
            case .camera:
                isCameraPresented = true
            case .photos:
                isPhotosPickerPresented = true
            case .uploadFile:
                isFileImporterPresented = true
            default:
                break
            }
            collapseBottomToolsBehindSystemPicker()
        default:
            model.routeBottomToolAction(action)
        }
    }

    private func dismissBottomTools() {
        model.isBottomToolsPresented = false
    }

    private func collapseBottomToolsBehindSystemPicker() {
        Task { @MainActor in
            // Give the direct picker presenter one run-loop handoff to begin
            // first. Collapsing the still-live parent after that does not add
            // the old sheet-dismissal delay to camera/photos/files.
            await Task.yield()
            isAttachmentHandoffActive = true
        }
    }
}

private struct StableChatViewHost: View, @preconcurrency Equatable {
    let safeAreaInsets: EdgeInsets
    let onOpenDrawer: () -> Void
    let isConversationDrawerClosePending: (UUID) -> Bool
    let onConversationContentReady: (UUID) -> Void

    static func == (lhs: StableChatViewHost, rhs: StableChatViewHost) -> Bool {
        lhs.safeAreaInsets.top == rhs.safeAreaInsets.top
            && lhs.safeAreaInsets.bottom == rhs.safeAreaInsets.bottom
            && lhs.safeAreaInsets.leading == rhs.safeAreaInsets.leading
            && lhs.safeAreaInsets.trailing == rhs.safeAreaInsets.trailing
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            ChatView(
                topSafeAreaInset: safeAreaInsets.top,
                onOpenDrawer: onOpenDrawer,
                isConversationDrawerClosePending: isConversationDrawerClosePending,
                onConversationContentReady: onConversationContentReady
            )
            .padding(.bottom, safeAreaInsets.bottom)
            .padding(.leading, safeAreaInsets.leading)
            .padding(.trailing, safeAreaInsets.trailing)
        } else {
            ChatView(
                topSafeAreaInset: safeAreaInsets.top,
                onOpenDrawer: onOpenDrawer,
                isConversationDrawerClosePending: isConversationDrawerClosePending,
                onConversationContentReady: onConversationContentReady
            )
            .padding(.top, safeAreaInsets.top)
            .padding(.bottom, safeAreaInsets.bottom)
            .padding(.leading, safeAreaInsets.leading)
            .padding(.trailing, safeAreaInsets.trailing)
        }
    }
}

/// Owns the drawer semantic dependency outside `ChatView.body`. The callback
/// still performs the established navigation/keyboard cleanup, but an idle
/// semantic flip no longer makes the long transcript observe the model value.
private struct ChatDrawerPresentationObserver: View {
    @Environment(AppModel.self) private var model
    let onChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.isDrawerPresented) { _, isPresented in
                onChange(isPresented)
            }
    }
}

/// Keeps the drawer-only visibility input in the navigation panel leaf. The
/// rest of `ChatView` continues to own message/navigation state, while a plain
/// drawer open or close updates only this lightweight modifier.
private struct DrawerAwareMessageNavigationPanelVisibility: ViewModifier {
    @Environment(AppModel.self) private var model
    let baseVisible: Bool
    let onHidden: () -> Void

    func body(content: Content) -> some View {
        let isVisible = baseVisible && !model.isDrawerPresented
        content
            .opacity(isVisible ? 1 : 0)
            .offset(x: isVisible ? 0 : 18)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(.smooth(duration: 0.24), value: isVisible)
            .onChange(of: isVisible) { _, isVisible in
                guard !isVisible else { return }
                onHidden()
            }
    }
}

/// The simple navigation control owns its drawer dependency, including the
/// animation value, so a semantic drawer change does not invalidate ChatView.
private struct DrawerAwareQuickReturnToBottom: View {
    @Environment(AppModel.self) private var model
    let baseVisible: Bool
    let bottomPadding: CGFloat
    let onReturnToBottom: () -> Void

    var body: some View {
        let isVisible = baseVisible && !model.isDrawerPresented
        Group {
            if isVisible {
                QuickReturnToBottomButton(action: onReturnToBottom)
                    .padding(.bottom, bottomPadding)
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.86))
                                .combined(with: .offset(y: 8)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.92))
                                .combined(with: .offset(y: 4))
                        )
                    )
            }
        }
        .animation(
            .snappy(duration: 0.22, extraBounce: 0.05),
            value: isVisible
        )
    }
}

/// Changes only the presentation of an existing transcript. The animator owns
/// its frames; conversation readiness, scroll identity and layout stay intact.
private struct ConversationSwitchFadeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversationID: UUID

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: conversationID) { content, opacity in
            content.opacity(reduceMotion ? 1 : opacity)
        } keyframes: { currentOpacity in
            // A new trigger replaces the active animation. Continue an
            // interrupted reveal instead of dimming again on every rapid tap.
            // Initial appearance is already opaque; only ID changes animate.
            MoveKeyframe(reduceMotion ? 1 : (currentOpacity < 1 ? max(0.25, currentOpacity) : 0.25))
            LinearKeyframe(1, duration: reduceMotion ? 0 : 0.10)
        }
    }
}

private struct ChatView: View {
    @Environment(AppModel.self) private var model
    let topSafeAreaInset: CGFloat
    let onOpenDrawer: () -> Void
    let isConversationDrawerClosePending: (UUID) -> Bool
    let onConversationContentReady: (UUID) -> Void
    @State private var userScrollIdleTask: Task<Void, Never>?
    @State private var streamFollowTask: Task<Void, Never>?
    @State private var userMessageSendPositionTask: Task<Void, Never>?
    @State private var activeUserMessageSendPositionRequestID: UUID?
    @State private var activeUserMessageSendPositionTaskID: UUID?
    @State private var conversationReturnTask: Task<Void, Never>?
    @State private var bottomRowMaterializationTask: Task<Void, Never>?
    @State private var pendingBottomRowMaterializationAnchorID: ConversationBottomAnchorID?
    @State private var layoutFollowTask: Task<Void, Never>?
    @State private var navigationHideTask: Task<Void, Never>?
    @State private var navigationScrollTask: Task<Void, Never>?
    @State private var showTransientNavigation = false
    @State private var navigationRequestSequence = 0
    @State private var conversationLazyWindowGeneration: UInt64 = 0
    @State private var navigationRequest: MessageNavigationRequest?
    @State private var pendingNavigationRequest: MessageNavigationRequest?
    // A remote bottom request or an exact-bottom tail-version replacement may
    // replace a large estimated LazyVStack window with AppModel's bounded latest
    // window. Keep that small destination eager after landing so completion never
    // performs an eager-to-lazy tree swap.
    @State private var bottomNavigationCompactWindowConversationID: UUID?
    @State private var messageReplacementConcreteWindowSessionID: ChatViewportSessionID?
    @State private var pendingNavigationPromotionTask: Task<Void, Never>?
    @State private var sendPositionNativeReleaseRequest:
        SendPositionNativeReleaseID?
    @State private var acknowledgedSendPositionNativeRelease:
        SendPositionNativeReleaseID?
    @State private var messageTargetNavigationTask: Task<Void, Never>?
    @State private var messageTargetCoordinatorRequestID: UUID?
    @State private var nativeReleasedMessageTargetRequestID: UUID?
    @State private var landedMessageTargetID: UUID?
    @State private var concreteFavoriteTargetMessageID: UUID?
    @State private var chatScrollViewBox = WeakChatScrollViewBox()
    @State private var regenerationViewportTransitionCoordinator =
        RegenerationViewportTransitionCoordinator()
    @State private var activatedCoveredMessageTargetRequestID: UUID?
    @State private var messageFrames: [UUID: CGRect] = [:]
    @State private var messageFramesAnchorID: ConversationBottomAnchorID?
    @State private var messageFramesLayoutRequestID: UUID?
    @State private var messageFrameGeneration: UInt64 = 0
    @State private var automaticReasoningExpandedCheckpoint:
        AutomaticReasoningExpandedCheckpoint?
    @State private var automaticReasoningCollapseAuthorization:
        AutomaticReasoningCollapseAuthorization?
    @State private var automaticReasoningCollapseAuthorizationGeneration:
        UInt64 = 0
    @State private var automaticReasoningCollapseAuthorizationDeadline:
        Date?
    @State private var automaticReasoningCollapseAuthorizationSampleCount = 0
    @State private var automaticReasoningCollapseAuthorizationWatchdogTask:
        Task<Void, Never>?
    @State private var manualStreamingReasoningCollapseSuppression:
        ManualStreamingReasoningCollapseKey?
    @State private var automaticReasoningCollapseOwnerGeneration: UInt64 = 0
    @State private var automaticReasoningCollapseOwnerLifecycle: UInt64 = 0
    @State private var automaticReasoningCollapseOwner:
        AutomaticReasoningCollapseOwner?
    @State private var automaticReasoningCollapseRearmRequest:
        AutomaticReasoningCollapseRearmRequest?
    @State private var automaticReasoningCollapseOwnerWatchdogTask:
        Task<Void, Never>?
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var scrollViewportFrame: CGRect = .zero
    @State private var lastKnownNearBottom = true
    // Keep the native geometry result separate from the transient "user is
    // dragging" state.  A drag can temporarily suppress auto-follow without
    // changing this measured fact.
    @State private var lastMeasuredNearBottom = true
    @State private var lastMeasuredAtBottom = true
    @State private var navigationAnchorMessageID: UUID?
    @State private var isUserScrollActive = false
    @State private var autoFollowEngaged = true
    @State private var offscreenStreamingDisplayState =
        OffscreenStreamingDisplayState()
    @State private var composerHeight: CGFloat = 110
    @State private var isQuickReturnToBottomVisible = false
    @State private var layoutFollowRequest = 0
    @State private var layoutFollowRequiresNearBottom = true
    @State private var nativeBottomEdgeRearmRequest = 0
    @State private var nativeSendExactBottomHandoffRequest = 0
    @State private var nativeConversationContentReadyAnchorID: ConversationBottomAnchorID?
    @State private var latestConversationBottomAnchorFrame: ConversationBottomAnchorFrame?
    @State private var keyboardViewportPinRequest = 0
    @State private var keyboardViewportPinTask: Task<Void, Never>?
    @State private var pendingKeyboardViewportPin: PendingKeyboardViewportPin?
    @State private var keyboardViewportPinGeneration = 0
    @State private var keyboardNativeSettleTask: Task<Void, Never>?
    @State private var keyboardNativeSettleGeneration = 0
    @State private var keyboardViewportPinAllowsUnfocused = false
    @State private var keyboardBottomFollowIntent = false
    @State private var pendingKeyboardDismissalDeadline: Date?
    @State private var isKeyboardDismissalTransition = false
    @State private var isKeyboardDismissalGeometryRecoveryActive = false
    @State private var keyboardDismissalViewportPinRequest: Int?
    @State private var keyboardDismissalAnimationDuration: TimeInterval?
    @State private var keyboardDismissalTransitionGeneration = 0
    @State private var lastKeyboardAnimationDuration: TimeInterval = 0.383
    @State private var lastKeyboardAnimationCurveRawValue = 7
    @State private var isComposerKeyboardPresented = false
    @State private var keyboardUnifiedSendHandoff: KeyboardUnifiedSendHandoff?
    @State private var keyboardScrollActivityIgnoreUntil = Date.distantPast
    @State private var positioningConversationID: UUID?
    @State private var newConversationFirstMessageID: UUID?
    @State private var newConversationFollowSuppressionID: UUID?
    @State private var scrollDragIsVertical: Bool?
    @State private var isVerticalScrollGestureActive = false
    @State private var isNativeVerticalScrollMotionArmed = false
    @State private var isNativeScrollPhaseActive = false
    @State private var streamingFollowTouchPauseAnchorID:
        ConversationBottomAnchorID?
    @State private var reactionPicker: MessageReactionPickerPresentation?
    @State private var messageSheetPresentation: MessageSheetPresentation?
    @State private var directEditText = ""
    @State private var regenerationConfirmationMessage: ChatMessage?
    @State private var messageWindowLoadTask: Task<Void, Never>?
    @State private var lastMessageWindowLoadAt = Date.distantPast
    @State private var messageReplacementLandingTask: Task<Void, Never>?
    @State private var messageReplacementRequest: MessageReplacementViewportRequest?
    @State private var codeDisclosureStore = CodeDisclosureStore()

    #if DEBUG
    private var isNavigationStressPreview: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-previewNavigationStress")
            || arguments.contains("-diagnoseNavigationStress")
    }

    private func navigationStressLog(_ message: @autoclosure () -> String) {
        guard isNavigationStressPreview else { return }
        NSLog("[navigation-stress] %@", message())
    }
    #endif

    private var chatBottomTraceState: String {
        "conv=\(ChatBottomTrace.shortID(model.selectedConversationID))"
            + " req=\(model.conversationBottomReturnRequest)"
            + " focus=\(model.isComposerFocused)"
            + " user=\(isUserScrollActive)"
            + " gesture=\(isVerticalScrollGestureActive)"
            + " armed=\(isNativeVerticalScrollMotionArmed)"
            + " phaseActive=\(isNativeScrollPhaseActive)"
            + " at=\(lastMeasuredAtBottom)"
            + " near=\(lastMeasuredNearBottom)"
            + " knownNear=\(lastKnownNearBottom)"
            + " auto=\(autoFollowEngaged)"
            + " intent=\(keyboardBottomFollowIntent)"
            + " pending=\(ChatBottomTrace.remaining(until: pendingKeyboardDismissalDeadline))"
            + " transition=\(isKeyboardDismissalTransition)"
            + " dismissalGeometry=\(isKeyboardDismissalGeometryRecoveryActive)"
            + " dismissReq=\(keyboardDismissalViewportPinRequest?.description ?? "nil")"
            + " ignore=\(ChatBottomTrace.remaining(until: keyboardScrollActivityIgnoreUntil))"
            + " keyboardTask=\(keyboardViewportPinTask != nil)"
            + " settleTask=\(keyboardNativeSettleTask != nil)"
            + " streamTask=\(streamFollowTask != nil)"
            + " sendTask=\(userMessageSendPositionTask != nil)"
            + " sendReq=\(model.pendingUserMessageSendPositionRequest.map { ChatBottomTrace.shortID($0.id) } ?? "nil")"
            + " sendGate=\(model.sendPresentationGate.map { ChatBottomTrace.shortID($0.requestID) } ?? "nil")"
            + " unifiedSend=\(keyboardUnifiedSendHandoff.map { ChatBottomTrace.shortID($0.requestID) } ?? "nil")"
            + " keyboardPresented=\(isComposerKeyboardPresented)"
            + " layoutTask=\(layoutFollowTask != nil)"
            + " returnTask=\(conversationReturnTask != nil)"
            + " materializeTask=\(bottomRowMaterializationTask != nil)"
            + " navigationTask=\(navigationScrollTask != nil)"
            + " collapseOwner=\(automaticReasoningCollapseOwner?.id.generation.description ?? "nil")"
            + " collapseLifecycle=\(automaticReasoningCollapseOwnerLifecycle)"
            + " collapseRearm=\(automaticReasoningCollapseRearmRequest?.ownerID.generation.description ?? "nil")"
            + " pendingOpen=\(pendingKeyboardViewportPin?.generation.description ?? "nil")"
            + " edgeReq=\(nativeBottomEdgeRearmRequest)"
            + " sendHandoffReq=\(nativeSendExactBottomHandoffRequest)"
            + " keyboardReq=\(keyboardViewportPinRequest)"
            + " viewportH=\(String(format: "%.1f", scrollViewportHeight))"
            + " viewportMinY=\(String(format: "%.1f", scrollViewportFrame.minY))"
            + " viewportMaxY=\(String(format: "%.1f", scrollViewportFrame.maxY))"
            + " composerH=\(String(format: "%.1f", composerHeight))"
            + chatBottomUIKitTrace
    }

    private var chatBottomUIKitTrace: String {
        guard ChatBottomTrace.enabled else { return "" }
        guard let scrollView = chatScrollViewBox.scrollView else { return " uikit=nil" }
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let bottomOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let distance = bottomOffsetY - scrollView.contentOffset.y
        return " boundsH=\(String(format: "%.1f", scrollView.bounds.height))"
            + " offsetY=\(String(format: "%.1f", scrollView.contentOffset.y))"
            + " contentH=\(String(format: "%.1f", scrollView.contentSize.height))"
            + " insetT=\(String(format: "%.1f", scrollView.adjustedContentInset.top))"
            + " insetB=\(String(format: "%.1f", scrollView.adjustedContentInset.bottom))"
            + " bottomY=\(String(format: "%.1f", bottomOffsetY))"
            + " distance=\(String(format: "%.1f", distance))"
            + " tracking=\(scrollView.isTracking)"
            + " dragging=\(scrollView.isDragging)"
            + " decelerating=\(scrollView.isDecelerating)"
    }

    private func traceScrollCommand(
        source: String,
        target: String,
        animation: String
    ) {
        ChatBottomTrace.log(
            "SCROLL_COMMAND source=\(source) target=\(target) animation=\(animation) "
                + chatBottomTraceState
        )
    }

    private func keyboardNotificationTrace(_ notification: Notification) -> String {
        let userInfo = notification.userInfo
        let beginFrame = userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect ?? .zero
        let endFrame = userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? -1
        let curve = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? -1
        return "beginY=\(String(format: "%.1f", beginFrame.minY))"
            + " endY=\(String(format: "%.1f", endFrame.minY))"
            + " beginH=\(String(format: "%.1f", beginFrame.height))"
            + " endH=\(String(format: "%.1f", endFrame.height))"
            + " duration=\(String(format: "%.3f", duration))"
            + " curve=\(curve)"
    }

    private func userBubbleSendAnimationRequest(
        for message: ChatMessage
    ) -> UserBubbleSendAnimationRequest? {
        guard message.role == .user,
              let request = model.pendingUserBubbleSendAnimation,
              request.conversationID == model.selectedConversationID,
              request.messageID == message.id,
              request.expiresAt > Date()
        else { return nil }
        return request
    }

    private func messageContentMutationBridge(
        for message: ChatMessage
    ) -> MessageContentMutationBridge {
        MessageContentMutationBridge(
            conversationID: message.conversationID,
            messageID: message.id,
            state: { scope, blockID in
                codeDisclosureStore.state(for: scope, blockID: blockID)
            },
            request: { change in beginCodeDisclosure(change) }
        )
    }

    private func conversationMessageRow(
        _ message: ChatMessage,
        citationSources: [MessageCitationSource],
        isGroupConversation: Bool,
        bottomAnchorID: ConversationBottomAnchorID
    ) -> some View {
        let versionFlashContext: VersionFlashTextContext?
        if VersionFlashTrace.isEnabled,
           message.id == bottomAnchorID.messageIDs.last {
            versionFlashContext = VersionFlashTextContext(
                conversationID: bottomAnchorID.positionRequest.conversationID,
                request: bottomAnchorID.positionRequest.request,
                messageID: message.id,
                version: message.version,
                versionGroupKey: message.versionGroupKey,
                isTail: true
            )
        } else {
            versionFlashContext = nil
        }
        return MessageRow(
            message: message,
            citationSources: citationSources,
            isGroupMessage: isGroupConversation,
            versionFlashContext: versionFlashContext,
            allowsTextSelection: true,
            contentMutationBridge: messageContentMutationBridge(for: message),
            userSendAnimationRequest: userBubbleSendAnimationRequest(for: message),
            userSendAnimationEnabled: model.preferences.userBubbleSendAnimationEnabled,
            onUserSendAnimationStarted: { requestID in
                model.consumeUserBubbleSendAnimation(requestID)
            },
            onReaction: { message, location in
                dismissKeyboard()
                model.performCardHaptic()
                reactionPicker = MessageReactionPickerPresentation(
                    messageID: message.id,
                    globalLocation: location
                )
            },
            onUserReaction: { message, reaction in
                let shouldPreserveBottom = model.preferences.autoScrollEnabled
                    && autoFollowEngaged
                    && lastKnownNearBottom
                    && !isUserScrollActive
                model.setMessageUserReaction(message.id, reaction: reaction)
                if shouldPreserveBottom {
                    requestLayoutFollowCorrection(requiresNearBottom: false)
                }
            },
            onMore: { message in
                dismissKeyboard()
                model.performCardHaptic()
                messageSheetPresentation = MessageSheetPresentation(
                    message: message,
                    kind: .actions
                )
            },
            onEdit: { message in
                dismissKeyboard()
                directEditText = message.text
                messageSheetPresentation = MessageSheetPresentation(
                    message: message,
                    kind: .edit
                )
            },
            onRegenerate: { message in
                dismissKeyboard()
                requestRegeneration(for: message)
            },
            onStreamingReasoningCollapseChanged: {
                messageID,
                segmentID,
                isCollapsed in
                updateManualStreamingReasoningCollapse(
                    messageID: messageID,
                    segmentID: segmentID,
                    isCollapsed: isCollapsed
                )
            },
            onSelectVersion: { oldMessage, newMessage in
                beginVersionReplacement(from: oldMessage, to: newMessage)
            }
        )
        .id(message.id)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MessageFramePreferenceKey.self,
                    value: ConversationMessageFrameSnapshot(
                        anchorID: bottomAnchorID,
                        frames: [
                            message.id: proxy.frame(in: .named("chat-scroll"))
                        ],
                        layoutRequestID: activeCodeLayoutRequestID
                    )
                )
            }
        }
    }

    private func conversationMessageHost(
        _ host: ConversationMessageHost,
        isGroupConversation: Bool,
        visibleTruncateIndex: Int,
        bottomAnchorID: ConversationBottomAnchorID,
        bottomNavigationTailClearance: CGFloat = 0
    ) -> some View {
        VStack(spacing: conversationMessageSpacing) {
            if host.index == visibleTruncateIndex {
                ContextClearedDivider()
            }
            conversationMessageRow(
                host.message,
                citationSources: host.citationSources,
                isGroupConversation: isGroupConversation,
                bottomAnchorID: bottomAnchorID
            )
        }
        // For one ordinary bottom-edge request, move the composer's existing
        // clearance into the existing lazy tail target. The matching outer
        // spacer gives up the same height, so total content height and message
        // identity remain unchanged while the one smooth command is active.
        .padding(
            .bottom,
            host.message.id == bottomAnchorID.messageIDs.last
                ? bottomNavigationTailClearance
                : 0
        )
        // Keep the exact pending-assistant row in layout from the first send
        // revision, but do not publish it visually before the existing
        // concrete-user-row gate opens. The canonical row then reuses this
        // host identity, so revealing the spinner adds no second layout height.
        .opacity(host.isSendPresentationReservation ? 0 : 1)
        .allowsHitTesting(!host.isSendPresentationReservation)
        .accessibilityHidden(host.isSendPresentationReservation)
    }

    private func conversationLazyMessageStack(
        _ messageHosts: ArraySlice<ConversationMessageHost>,
        isGroupConversation: Bool,
        visibleTruncateIndex: Int,
        visibleMessageCount: Int,
        identity: ConversationLazyWindowIdentity,
        bottomAnchorID: ConversationBottomAnchorID,
        bottomNavigationTailClearance: CGFloat,
        includesEarlierWindowSentinel: Bool = true,
        includesTailContent: Bool = true
    ) -> some View {
        LazyVStack(spacing: conversationMessageSpacing) {
            if includesEarlierWindowSentinel && model.hasEarlierMessages {
                Color.clear
                    .frame(height: 1)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MessageWindowTopFramePreferenceKey.self,
                                value: proxy.frame(in: .named("chat-scroll"))
                            )
                        }
                    }
            }
            ForEach(messageHosts) { host in
                conversationMessageHost(
                    host,
                    isGroupConversation: isGroupConversation,
                    visibleTruncateIndex: visibleTruncateIndex,
                    bottomAnchorID: bottomAnchorID,
                    bottomNavigationTailClearance:
                        bottomNavigationTailClearance
                )
            }
            if includesTailContent,
               visibleTruncateIndex == visibleMessageCount {
                ContextClearedDivider()
            }
            if includesTailContent && model.hasLaterMessages {
                Color.clear
                    .frame(height: 1)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MessageWindowBottomFramePreferenceKey.self,
                                value: proxy.frame(in: .named("chat-scroll"))
                            )
                        }
                    }
            }
            if includesTailContent && model.isCompressingContext {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.lookup("正在压缩上下文…"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .id(identity)
    }

    private func conversationCompactBottomMessageStack(
        _ messageHosts: ArraySlice<ConversationMessageHost>,
        isGroupConversation: Bool,
        visibleTruncateIndex: Int,
        visibleMessageCount: Int,
        identity: ConversationLazyWindowIdentity,
        bottomAnchorID: ConversationBottomAnchorID,
        bottomNavigationTailClearance: CGFloat
    ) -> some View {
        VStack(spacing: conversationMessageSpacing) {
            if model.hasEarlierMessages {
                Color.clear
                    .frame(height: 1)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MessageWindowTopFramePreferenceKey.self,
                                value: proxy.frame(in: .named("chat-scroll"))
                            )
                        }
                    }
            }
            ForEach(messageHosts) { host in
                conversationMessageHost(
                    host,
                    isGroupConversation: isGroupConversation,
                    visibleTruncateIndex: visibleTruncateIndex,
                    bottomAnchorID: bottomAnchorID,
                    bottomNavigationTailClearance:
                        bottomNavigationTailClearance
                )
            }
            if visibleTruncateIndex == visibleMessageCount {
                ContextClearedDivider()
            }
            if model.hasLaterMessages {
                Color.clear
                    .frame(height: 1)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MessageWindowBottomFramePreferenceKey.self,
                                value: proxy.frame(in: .named("chat-scroll"))
                            )
                        }
                    }
            }
            if model.isCompressingContext {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.lookup("正在压缩上下文…"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .id(identity)
    }

    private func nativeBottomPositionModifier(
        bottomAnchorID: ConversationBottomAnchorID,
        scrollProxy: ScrollViewProxy
    ) -> ChatNativeBottomPositionModifier {
        ChatNativeBottomPositionModifier(
            conversationID: model.selectedConversationID,
            request: model.conversationBottomReturnRequest,
            bottomAnchorID: bottomAnchorID,
            edgeRearmRequest: nativeBottomEdgeRearmRequest,
            sendExactBottomHandoffRequest: nativeSendExactBottomHandoffRequest,
            contentReadyAnchorID: nativeConversationContentReadyAnchorID,
            keyboardRequest: keyboardViewportPinRequest,
            keyboardDismissalRequest: keyboardDismissalViewportPinRequest,
            keyboardAnimationDuration: lastKeyboardAnimationDuration,
            keyboardAnimationCurveRawValue: lastKeyboardAnimationCurveRawValue,
            scrollViewBox: chatScrollViewBox,
            shouldPinToBottom: shouldKeepNativeBottomPosition,
            isOrdinaryConversationReturn: isOrdinaryConversationReturn,
            messageReplacementReleaseID: messageReplacementRequest?.didCommit == false
                ? messageReplacementRequest?.id : nil,
            onMessageReplacementPositionReleased: { anchorID, requestID in
                commitMessageReplacementAfterRelease(
                    requestID, sourceAnchorID: anchorID, using: scrollProxy
                )
            },
            shouldPauseStreamingFollowOnUserTouch:
                shouldPauseStreamingFollowOnNativeTouch,
            automaticReasoningCollapseOwnerID:
                automaticReasoningCollapseOwner?.id,
            automaticReasoningCollapseOwnerLifecycle:
                automaticReasoningCollapseOwnerLifecycle,
            automaticReasoningCollapseRearmRequest:
                automaticReasoningCollapseRearmRequest,
            messageTargetReleaseID:
                selectedMessageTargetNavigationRequest?.id,
            edgeNavigationReleaseID:
                currentEdgeNavigationNativeReleaseID,
            edgeNavigationSequence: currentEdgeNavigationSequence,
            onEdgeNavigationUserTouch: interruptEdgeNavigationForNativeTouch,
            sendPositionReleaseID:
                sendPositionNativeReleaseRequest,
            onBottomStateChanged: updateNativeBottomState,
            onAutomaticReasoningCollapseGeometry:
                reduceAutomaticReasoningCollapseGeometry,
            onAutomaticReasoningCollapseBottomRearmed:
                acknowledgeAutomaticReasoningCollapseBottomRearm,
            onScrollMotionChanged: updateNativeScrollMotionState,
            onScrollPhaseActivityChanged: updateNativeScrollPhaseActivityState,
            onSystemScrollToTopStarted: beginSystemScrollToTop,
            onMessageTargetPositionReleased:
                acknowledgeMessageTargetPositionRelease,
            onEdgeNavigationPositionReleased: { anchorID, releaseID in
                acknowledgeEdgeNavigationPositionRelease(
                    anchorID,
                    releaseID,
                    using: scrollProxy
                )
            },
            onSendPositionReleased: { anchorID, releaseID in
                acknowledgeSendPositionRelease(
                    anchorID,
                    releaseID,
                    using: scrollProxy
                )
            }
        )
    }

    var body: some View {
        @Bindable var model = model
        let visibleMessages = messagesForCodeDisclosureLayout(model.messages)
        // MessageRow reads group-specific layout and appearance several times.
        // Resolve the selected conversation once instead of rescanning per row.
        let isGroupConversation = model.selectedConversationIsGroupChat
        let bottomAnchorID = ConversationBottomAnchorID(
            positionRequest: ConversationPositionRequestKey(
                conversationID: model.selectedConversationID,
                request: model.conversationBottomReturnRequest
            ),
            messageIDs: visibleMessages.map(\.id)
        )
        let conversationLazyWindowIdentity = ConversationLazyWindowIdentity(
            conversationID: model.selectedConversationID,
            generation: conversationLazyWindowGeneration
        )
        let bottomNavigationTailClearance =
            activeBottomNavigationTailClearance(for: bottomAnchorID)
        let sendPresentationNativeReleaseID: UUID? = {
            guard isComposerKeyboardPresented,
                  activeUserMessageSendPositionRequestID == nil,
                  let gate = model.sendPresentationGate,
                  let request = model.pendingUserMessageSendPositionRequest,
                  gate.requestID == request.id,
                  gate.conversationID == model.selectedConversationID,
                  gate.userMessageID == request.messageID,
                  bottomAnchorID.messageIDs.last == request.messageID,
                  messageFramesAnchorID == bottomAnchorID,
                  let frame = messageFrames[request.messageID],
                  frame.width > 0,
                  frame.height > 0,
                  frame.maxY > 0,
                  frame.minY < scrollViewportHeight,
                  let scrollView = chatScrollViewBox.scrollView,
                  scrollView.window != nil,
                  !nativeScrollHasActiveTouch(scrollView),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating,
                  !isNativeScrollAnimating(scrollView) else { return nil }
            return request.id
        }()
        let citationSourcesByMessageID = MessageCitationSource.sourcesByMessageID(
            from: visibleMessages,
            retentionTurns: model.preferences.searchToolResultRetentionTurns
        )
        let messageHosts = visibleMessages.enumerated().map { index, message in
            ConversationMessageHost(
                id: .message(message.id),
                index: index,
                message: message,
                citationSources: citationSourcesByMessageID[message.id] ?? [],
                isSendPresentationReservation: false
            )
        }
        let renderedMessageHosts: [ConversationMessageHost] = {
            guard let gate = model.sendPresentationGate,
                  let reservation = model.sendPresentationAssistantReservation,
                  visibleMessages.last?.id == gate.userMessageID,
                  !visibleMessages.contains(where: {
                      $0.id == reservation.id
                  }) else { return messageHosts }
            return messageHosts + [
                ConversationMessageHost(
                    id: .message(reservation.id),
                    index: visibleMessages.count,
                    message: reservation,
                    citationSources: [],
                    isSendPresentationReservation: true
                )
            ]
        }()
        let usesBottomNavigationCompactWindow =
            bottomNavigationCompactWindowConversationID
                == model.selectedConversationID
                && !model.hasLaterMessages
                // The navigation window starts at twelve rows. Retain eager
                // layout through a handful of subsequent sends, but never let
                // this request-owned mode grow into an unbounded transcript.
                // One hidden send-presentation reservation is also bounded.
                && visibleMessages.count <= 24
                && renderedMessageHosts.count <= 25
        let automaticReasoningCollapseObservation:
            AutomaticReasoningCollapseObservation? = {
                guard let tailMessage = visibleMessages.last,
                      tailMessage.role == .assistant,
                      let lastSegment = tailMessage.reasoningSegments.last else {
                    return nil
                }
                let autoCollapseEnabled = model.preferences.autoCollapseThinking
                let isThinking = lastSegment.finishedAt == nil
                    && tailMessage.isStreaming
                let isExpanded = !model.preferences.fullyCollapseThinking
                    && (isThinking
                        || (!autoCollapseEnabled && lastSegment.finishedAt != nil)
                        || lastSegment.expanded)
                return AutomaticReasoningCollapseObservation(
                    anchorID: bottomAnchorID,
                    tailMessageID: tailMessage.id,
                    segmentID: lastSegment.id,
                    finishedAt: lastSegment.finishedAt,
                    messageUpdatedAt: tailMessage.updatedAt,
                    isStreaming: tailMessage.isStreaming,
                    autoCollapseEnabled: autoCollapseEnabled,
                    isExpanded: isExpanded,
                    hasVisibleText: !tailMessage.text.isEmpty
                )
            }()

        ZStack {
            ChatBackgroundView(profile: model.selectedConversationDisplayAssistant)

            if visibleMessages.isEmpty {
                EmptyConversationView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 108)
                    .padding(.bottom, composerBottomClearance)
                    .contentShape(Rectangle())
                    .onAppear {
                        if reactionPicker != nil { reactionPicker = nil }
                        cancelCodeDisclosure(reason: "emptyConversation")
                        codeDisclosureStore.removeAll()
                        cancelAutomaticReasoningCollapseOwner(
                            reason: "emptyConversation"
                        )
                        let conversationID = model.selectedConversationID
                        // The empty branch replaces the ScrollView branch, so
                        // cancel tasks whose old observers may no longer receive
                        // the composite conversation change.
                        userScrollIdleTask?.cancel()
                        userScrollIdleTask = nil
                        streamFollowTask?.cancel()
                        streamFollowTask = nil
                        let pendingSendBecameOrphaned: Bool
                        if let pendingRequest =
                            model.pendingUserMessageSendPositionRequest,
                           pendingRequest.conversationID == conversationID {
                            pendingSendBecameOrphaned = !model.messages.contains {
                                $0.id == pendingRequest.messageID
                            }
                        } else {
                            pendingSendBecameOrphaned = false
                        }
                        cancelUserMessageSendPositioning(
                            consumingPendingRequest: pendingSendBecameOrphaned
                        )
                        conversationReturnTask?.cancel()
                        conversationReturnTask = nil
                        bottomRowMaterializationTask?.cancel()
                        bottomRowMaterializationTask = nil
                        pendingBottomRowMaterializationAnchorID = nil
                        layoutFollowTask?.cancel()
                        layoutFollowTask = nil
                        keyboardViewportPinTask?.cancel()
                        keyboardViewportPinTask = nil
                        pendingKeyboardViewportPin = nil
                        messageWindowLoadTask?.cancel()
                        messageWindowLoadTask = nil
                        navigationScrollTask?.cancel()
                        navigationScrollTask = nil
                        navigationRequest = nil
                        cancelPendingMessageNavigation()
                        invalidateKeyboardDismissalTransition()
                        keyboardBottomFollowIntent = false
                        isNativeVerticalScrollMotionArmed = false
                        isNativeScrollPhaseActive = false
                        newConversationFirstMessageID = conversationID
                        newConversationFollowSuppressionID = conversationID
                        // There is no transcript to detach from yet. Seed the
                        // follow facts here so they cannot leak from the
                        // previously selected conversation.
                        isUserScrollActive = false
                        autoFollowEngaged = model.preferences.autoScrollEnabled
                        lastKnownNearBottom = true
                        lastMeasuredNearBottom = true
                        lastMeasuredAtBottom = true
                        isQuickReturnToBottomVisible = false
                        model.finishConversationBottomReturn(for: conversationID)
                        onConversationContentReady(conversationID)
                    }
                    .onTapGesture {
                        dismissKeyboard()
                    }
                    // Own the complete empty-conversation lifecycle, including
                    // the initialization and content-ready acknowledgement
                    // above. Empty-to-empty switches otherwise keep the outer
                    // appearance modifier alive and leave drawer close waiting.
                    .id(model.selectedConversationID)
            } else {
                ScrollViewReader { scrollProxy in
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                Color.clear
                                    .frame(height: topContentSpacerHeight)
                                    .id(
                                        ConversationTopMaterializationSeedID(
                                            anchorID: bottomAnchorID
                                        )
                                    )
                                    .background {
                                        ChatScrollViewProbe(
                                            scrollViewBox: chatScrollViewBox,
                                            onStatusBarScrollToTop: {
                                                // Route the exact UIKit status-bar
                                                // request through the already-owned
                                                // double-up navigation lifecycle. It
                                                // loads the real start window first,
                                                // so one tap reaches the conversation
                                                // top instead of only the local window.
                                                requestMessageNavigation(.top)
                                            },
                                            onResolved: {
                                                advanceMessageReplacementIfReady(using: scrollProxy)
                                                finishMessageReplacementIfReady()
                                            }
                                        )
                                            .allowsHitTesting(false)
                                    }
                                    .allowsHitTesting(false)

                                let truncateIndex = model.selectedLogicalTruncateIndex
                                let visibleTruncateIndex = truncateIndex - model.messageWindowStartIndex

                                let concreteFavoriteTargetHost =
                                    renderedMessageHosts.first.flatMap { host in
                                        host.message.id
                                            == concreteFavoriteTargetMessageID
                                            ? host
                                            : nil
                                    }
                                let concreteHeadHost = concreteFavoriteTargetHost
                                    ?? (model.hasEarlierMessages
                                        ? nil
                                        : renderedMessageHosts.first)
                                let concreteHeadIsFavoriteTarget =
                                    concreteFavoriteTargetHost != nil
                                let lazyMessageHosts = concreteHeadHost == nil
                                    ? renderedMessageHosts[...]
                                    : renderedMessageHosts.dropFirst()
                                let hasLazyTranscriptContent = !lazyMessageHosts.isEmpty
                                    || model.hasEarlierMessages
                                    || visibleTruncateIndex == visibleMessages.count
                                    || model.hasLaterMessages
                                    || model.isCompressingContext

                                Group {
                                    if usesBottomNavigationCompactWindow
                                        || model.usesConcreteConversationEntryWindow
                                        || (messageReplacementConcreteWindowSessionID == currentChatViewportSessionID
                                            && visibleMessages.count <= 24
                                            && renderedMessageHosts.count <= 25) {
                                        conversationCompactBottomMessageStack(
                                            renderedMessageHosts[...],
                                            isGroupConversation: isGroupConversation,
                                            visibleTruncateIndex: visibleTruncateIndex,
                                            visibleMessageCount: visibleMessages.count,
                                            identity: conversationLazyWindowIdentity,
                                            bottomAnchorID: bottomAnchorID,
                                            bottomNavigationTailClearance:
                                                bottomNavigationTailClearance
                                        )
                                    } else if let concreteHeadHost {
                                        // A real conversation head and the request-scoped
                                        // favorite target are both concrete top anchors.
                                        // Every surrounding historical row remains lazy.
                                        VStack(spacing: conversationMessageSpacing) {
                                            if concreteHeadIsFavoriteTarget,
                                               model.hasEarlierMessages {
                                                Color.clear
                                                    .frame(height: 1)
                                                    .background {
                                                        GeometryReader { proxy in
                                                            Color.clear.preference(
                                                                key: MessageWindowTopFramePreferenceKey.self,
                                                                value: proxy.frame(in: .named("chat-scroll"))
                                                            )
                                                        }
                                                    }
                                            }

                                            conversationMessageHost(
                                                concreteHeadHost,
                                                isGroupConversation: isGroupConversation,
                                                visibleTruncateIndex: visibleTruncateIndex,
                                                bottomAnchorID: bottomAnchorID,
                                                bottomNavigationTailClearance:
                                                    bottomNavigationTailClearance
                                            )
                                            .id(concreteHeadHost.id)

                                            if hasLazyTranscriptContent {
                                                conversationLazyMessageStack(
                                                    lazyMessageHosts,
                                                    isGroupConversation: isGroupConversation,
                                                    visibleTruncateIndex: visibleTruncateIndex,
                                                    visibleMessageCount: visibleMessages.count,
                                                    identity: conversationLazyWindowIdentity,
                                                    bottomAnchorID: bottomAnchorID,
                                                    bottomNavigationTailClearance:
                                                        bottomNavigationTailClearance,
                                                    includesEarlierWindowSentinel:
                                                        !concreteHeadIsFavoriteTarget
                                                )
                                            }
                                        }
                                    } else {
                                        conversationLazyMessageStack(
                                            lazyMessageHosts,
                                            isGroupConversation: isGroupConversation,
                                            visibleTruncateIndex: visibleTruncateIndex,
                                            visibleMessageCount: visibleMessages.count,
                                            identity: conversationLazyWindowIdentity,
                                            bottomAnchorID: bottomAnchorID,
                                            bottomNavigationTailClearance:
                                                bottomNavigationTailClearance
                                        )
                                    }
                                }
                                .padding(.horizontal, 18)
                                .padding(.top, messageListTopPadding)

                                Color.clear
                                    .frame(
                                        height: composerBottomClearance
                                            - bottomNavigationTailClearance
                                    )
                                    // The native ScrollView survives a
                                    // conversation switch. Give only its bottom
                                    // sentinel a new identity so ScrollViewProxy
                                    // cannot resolve the previous conversation's
                                    // retained anchor/offset.
                                    .id(bottomAnchorID)
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: ConversationBottomAnchorFramePreferenceKey.self,
                                                value: ConversationBottomAnchorFrame(
                                                    anchorID: bottomAnchorID,
                                                    frame: proxy.frame(in: .named("chat-scroll")),
                                                    layoutRequestID: activeCodeLayoutRequestID
                                                )
                                            )
                                        }
                                    }
                            }
                            // Give underflow conversations a concrete viewport-sized
                            // content frame. Their legal top gap is now layout space,
                            // not a virtual scroll offset inherited from a longer chat.
                            // Longer conversations keep their intrinsic height.
                            .frame(
                                minHeight: conversationContentMinimumHeight,
                                alignment: .top
                            )
                        }
                        // Keep the conversation visible while the no-animation
                        // bottom corrections settle. Hiding this ScrollView made
                        // a stale positioning flag look like an empty chat.
                        .modifier(
                            RegisteredChatScrollHeader(
                                topSafeAreaInset: topSafeAreaInset,
                                onOpenDrawer: onOpenDrawer
                            )
                        )
                        .coordinateSpace(name: "chat-scroll")
                        // Measure the concrete ScrollView directly. A background
                        // PreferenceKey can be reduced back to its zero default
                        // while a conversation identity is being replaced,
                        // leaving bottom completion permanently armed.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            let previousHeight = scrollViewportHeight
                            scrollViewportHeight = height
                            guard height > 0, abs(previousHeight - height) > 0.5 else { return }
                            let isKeyboardDismissalViewportExpansion = previousHeight > 100
                                && height > previousHeight + 80
                                && model.isComposerFocused
                                && autoFollowEngaged
                                && !isUserScrollActive
                            if isKeyboardDismissalViewportExpansion {
                                isKeyboardDismissalGeometryRecoveryActive = true
                                ChatBottomTrace.log(
                                    "KEYBOARD_DISMISS_GEOMETRY_OWNERSHIP"
                                        + " oldHeight=\(String(format: "%.1f", previousHeight))"
                                        + " newHeight=\(String(format: "%.1f", height)) "
                                        + chatBottomTraceState
                                )
                            }
                            ChatBottomTrace.log(
                                "VIEWPORT_HEIGHT old=\(String(format: "%.1f", previousHeight))"
                                    + " new=\(String(format: "%.1f", height)) "
                                    + chatBottomTraceState
                            )
                            #if DEBUG
                            navigationStressLog("viewport height \(height)")
                            #endif
                            requestLayoutFollowCorrection()
                        }
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { frame in
                            guard frame != .zero else { return }
                            let previousFrame = scrollViewportFrame
                            guard previousFrame == .zero
                                || abs(previousFrame.maxY - frame.maxY) > 0.5
                                || abs(previousFrame.minY - frame.minY) > 0.5
                                || abs(previousFrame.height - frame.height) > 0.5 else { return }
                            scrollViewportFrame = frame
                            ChatBottomTrace.log(
                                "VIEWPORT_FRAME"
                                    + " oldMinY=\(String(format: "%.1f", previousFrame.minY))"
                                    + " oldMaxY=\(String(format: "%.1f", previousFrame.maxY))"
                                    + " newMinY=\(String(format: "%.1f", frame.minY))"
                                    + " newMaxY=\(String(format: "%.1f", frame.maxY)) "
                                    + chatBottomTraceState
                            )
                            requestLayoutFollowCorrection(requiresNearBottom: false)
                        }
                        // 原生聊天锚定保持稳定；键盘/输入框避让由 overlay 遮挡测量驱动 bottom sentinel。
                        .modifier(
                            ChatScrollAnchorsModifier(
                                alignsShortContentAtBottom: !isFreshConversationFirstMessage
                            )
                        )
                        .modifier(
                            nativeBottomPositionModifier(
                                bottomAnchorID: bottomAnchorID,
                                scrollProxy: scrollProxy
                            )
                        )
                        .id(model.selectedConversationID)
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                clearAutomaticReasoningCollapseAuthorization(
                                    reason: "transcriptTap"
                                )
                                cancelMessageTargetNavigationForUserInteraction()
                                cancelMessageNavigationForUserInteraction(reason: "transcriptTap")
                                // A transcript tap makes the visible geometry the
                                // new reading position for the next adjacent jump.
                                navigationAnchorMessageID = nil
                                dismissKeyboard()
                            }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    if scrollDragIsVertical == nil {
                                        guard max(abs(value.translation.width), abs(value.translation.height)) >= 8 else { return }
                                        scrollDragIsVertical = isVerticalScrollDrag(value)
                                    }
                                    guard scrollDragIsVertical == true else { return }
                                    if !isVerticalScrollGestureActive {
                                        cancelMessageReplacementLanding()
                                        cancelAutomaticReasoningCollapseOwner(
                                            reason: "userDrag"
                                        )
                                        cancelMessageTargetNavigationForUserInteraction()
                                        invalidateVersionReplacement(reason: "userDrag")
                                        ChatBottomTrace.log(
                                            "DRAG_BEGIN willInvalidate=\(pendingKeyboardDismissalDeadline == nil)"
                                                + " willCancelKeyboardTask=\(keyboardViewportPinTask != nil) "
                                                + chatBottomTraceState
                                        )
                                        cancelMessageNavigationForUserInteraction(reason: "userDrag")
                                        navigationAnchorMessageID = nil
                                        cancelUserMessageSendPositioning(consumingPendingRequest: true)
                                    }
                                    isVerticalScrollGestureActive = true
                                    isNativeVerticalScrollMotionArmed = true
                                    if isPositioningCurrentConversation {
                                        cancelConversationReturnPositioning()
                                    }
                                    lastKnownNearBottom = false
                                    updateNavigationVisibility(isScrolling: true)
                                    handleScrollActivity(
                                        isScrolling: true,
                                        isNearBottom: false
                                    )
                                }
                                .onEnded { value in
                                    let didEndVerticalDrag = scrollDragIsVertical == true
                                        || isVerticalScrollDrag(value)
                                    if didEndVerticalDrag {
                                        ChatBottomTrace.log(
                                            "DRAG_END vertical=true dx=\(String(format: "%.1f", value.translation.width))"
                                                + " dy=\(String(format: "%.1f", value.translation.height)) "
                                                + chatBottomTraceState
                                        )
                                    }
                                    // Release SwiftUI's drag ownership before
                                    // promoting a button tap queued during tracking.
                                    scrollDragIsVertical = nil
                                    isVerticalScrollGestureActive = false
                                    schedulePendingMessageNavigationPromotion()
                                    guard didEndVerticalDrag else { return }
                                    updateNavigationVisibility(isScrolling: false)
                                    if #unavailable(iOS 18.0) {
                                        handleScrollActivity(
                                            isScrolling: false,
                                            isNearBottom: lastKnownNearBottom
                                        )
                                    }
                                }
                        )
                    }
                    .onPreferenceChange(CodeDisclosureLayoutPreferenceKey.self) { frames in
                        acknowledgeCodeDisclosureLayout(frames, using: scrollProxy)
                    }
                    .onPreferenceChange(MessageFramePreferenceKey.self) { snapshot in
                        guard let snapshot,
                              snapshot.anchorID == bottomAnchorID else { return }
                        if let requestID = activeCodeLayoutRequestID,
                           snapshot.layoutRequestID != requestID { return }
                        let tailMessageID = snapshot.anchorID.messageIDs.last
                        let previousTailFrame = messageFramesAnchorID == snapshot.anchorID
                            ? tailMessageID.flatMap { messageFrames[$0] }
                            : nil
                        let observedTailFrame = tailMessageID.flatMap {
                            snapshot.frames[$0]
                        }
                        if messageFramesAnchorID != snapshot.anchorID
                            || previousTailFrame != observedTailFrame {
                            messageFrameGeneration &+= 1
                        }
                        if let observation = automaticReasoningCollapseObservation,
                           observation.anchorID == snapshot.anchorID,
                           observation.tailMessageID == tailMessageID,
                           observation.finishedAt == nil,
                           observation.isStreaming,
                           observation.autoCollapseEnabled,
                           observation.isExpanded,
                           !observation.hasVisibleText,
                           manualStreamingReasoningCollapseSuppression
                            != ManualStreamingReasoningCollapseKey(
                                anchorID: observation.anchorID,
                                tailMessageID: observation.tailMessageID,
                                segmentID: observation.segmentID
                            ),
                           let observedTailFrame,
                           observedTailFrame.minX.isFinite,
                           observedTailFrame.minY.isFinite,
                           observedTailFrame.width.isFinite,
                           observedTailFrame.height.isFinite,
                           scrollViewportHeight > 0,
                           observedTailFrame.maxY > 0,
                           observedTailFrame.minY < scrollViewportHeight,
                           let scrollView = chatScrollViewBox.scrollView,
                           scrollView.window != nil,
                           scrollView.bounds.height > 0,
                           scrollView.contentSize.height.isFinite,
                           scrollView.contentOffset.y.isFinite,
                           scrollView.adjustedContentInset.top.isFinite,
                           // Programmatic bottom following may still be in its
                           // native animation phase when the final expanded
                           // reasoning frame becomes concrete. Reject only
                           // real user motion here; otherwise the collapse can
                           // lose its last usable pre-shrink checkpoint.
                           !isVerticalScrollGestureActive,
                           !isNativeVerticalScrollMotionArmed,
                           !nativeScrollHasActiveTouch(scrollView),
                           !scrollView.isTracking,
                           !scrollView.isDragging,
                           !scrollView.isDecelerating,
                           currentUIKitBottomState?.isAtBottom == true {
                            let minimumOffsetY =
                                -scrollView.adjustedContentInset.top
                            automaticReasoningExpandedCheckpoint =
                                AutomaticReasoningExpandedCheckpoint(
                                    anchorID: observation.anchorID,
                                    tailMessageID: observation.tailMessageID,
                                    segmentID: observation.segmentID,
                                    frameGeneration: messageFrameGeneration,
                                    frame: observedTailFrame,
                                    scrollViewIdentity:
                                        ObjectIdentifier(scrollView),
                                    contentHeight:
                                        scrollView.contentSize.height,
                                    contentOffsetY:
                                        scrollView.contentOffset.y,
                                    minimumOffsetY: minimumOffsetY,
                                    adjustedContentInsetBottom:
                                        scrollView.adjustedContentInset.bottom
                                )
                            ChatBottomTrace.log(
                                "REASONING_COLLAPSE_CHECKPOINT"
                                    + " generation=\(messageFrameGeneration)"
                                    + " tail=\(ChatBottomTrace.shortID(observation.tailMessageID))"
                                    + " segment=\(ChatBottomTrace.shortID(observation.segmentID))"
                                    + " minY=\(String(format: "%.1f", observedTailFrame.minY))"
                                    + " maxY=\(String(format: "%.1f", observedTailFrame.maxY))"
                                    + " height=\(String(format: "%.1f", observedTailFrame.height)) "
                                    + " contentH=\(String(format: "%.1f", scrollView.contentSize.height))"
                                    + " offsetY=\(String(format: "%.1f", scrollView.contentOffset.y)) "
                                    + chatBottomTraceState
                            )
                        }
                        messageFramesAnchorID = snapshot.anchorID
                        messageFramesLayoutRequestID = snapshot.layoutRequestID
                        messageFrames = snapshot.frames
                        advanceMessageReplacementIfReady(using: scrollProxy)
                        finishMessageReplacementIfReady()
                        updateOffscreenStreamingDisplayLease()
                        if let request = model.pendingUserMessageSendPositionRequest,
                           keyboardUnifiedSendHandoff?.requestID == request.id {
                            _ = finishKeyboardUnifiedSendHandoffIfReady(request)
                        }
                        if let tailMessageID = bottomAnchorID.messageIDs.last,
                           let tailFrame = snapshot.frames[tailMessageID] {
                            VersionFlashTrace.recordOnce(
                                "tailFrame-\(bottomAnchorID.positionRequest.request)-\(tailMessageID)",
                                "TAIL_FRAME"
                                    + " conv=\(VersionFlashTrace.identifierToken(bottomAnchorID.positionRequest.conversationID))"
                                    + " req=\(bottomAnchorID.positionRequest.request)"
                                    + " msg=\(VersionFlashTrace.identifierToken(tailMessageID))"
                                    + " minY=\(String(format: "%.1f", Double(tailFrame.minY)))"
                                    + " maxY=\(String(format: "%.1f", Double(tailFrame.maxY)))"
                                    + " height=\(String(format: "%.1f", Double(tailFrame.height)))"
                            )
                        }
                        let hadAutomaticCollapseOwner =
                            automaticReasoningCollapseOwner?.id.anchorID
                                == snapshot.anchorID
                        advanceAutomaticReasoningCollapseOwnerIfPossible(
                            anchorID: snapshot.anchorID
                        )
                        if hadAutomaticCollapseOwner
                            || automaticReasoningCollapseOwner?.id.anchorID
                                == snapshot.anchorID {
                            return
                        }
                        guard let bottomSnapshot = latestConversationBottomAnchorFrame,
                              bottomSnapshot.anchorID == bottomAnchorID,
                              let tailMessageID = bottomSnapshot.anchorID.messageIDs.last,
                              messageFrames[tailMessageID] != nil else { return }
                        handleConversationBottomAnchorFrame(bottomSnapshot, using: scrollProxy)
                    }
                    .onPreferenceChange(ConversationBottomAnchorFramePreferenceKey.self) { snapshot in
                        handleConversationBottomAnchorFrame(snapshot, using: scrollProxy)
                        advanceMessageReplacementIfReady(using: scrollProxy)
                        finishMessageReplacementIfReady()
                    }
                    .onPreferenceChange(MessageWindowTopFramePreferenceKey.self) { frame in
                        handleMessageWindowEdge(frame, direction: .earlier, using: scrollProxy)
                    }
                    .onPreferenceChange(MessageWindowBottomFramePreferenceKey.self) { frame in
                        handleMessageWindowEdge(frame, direction: .later, using: scrollProxy)
                    }
                    .onAppear {
                        completeFreshConversationBottomHandoffIfNeeded()
                        if model.pendingMessageTargetNavigationRequest?.conversationID
                            == model.selectedConversationID {
                            schedulePendingMessageTargetNavigation()
                        } else if let request = model.pendingUserMessageSendPositionRequest {
                            scheduleUserMessageSendPositioning(request, using: scrollProxy)
                        } else {
                            scheduleConversationReturn(using: scrollProxy)
                        }
                    }
                    .onDisappear {
                        releaseOffscreenStreamingDisplayLease(
                            reason: "chatDisappear"
                        )
                    }
                    .onChange(of: bottomAnchorID) { previousAnchorID, currentAnchorID in
                        if messageReplacementConcreteWindowSessionID != currentChatViewportSessionID
                            || model.messages.count > 24 {
                            messageReplacementConcreteWindowSessionID = nil
                        }
                        if let deletion = messageReplacementRequest,
                           (deletion.landingAnchorID ?? deletion.sourceAnchorID)
                            != currentAnchorID {
                            cancelMessageReplacementLanding()
                        }
                        codeDisclosureStore.retain(messageIDs: Set(currentAnchorID.messageIDs))
                        if previousAnchorID != currentAnchorID {
                            releaseOffscreenStreamingDisplayLease(
                                reason: "conversationPositionChanged"
                            )
                            cancelAutomaticReasoningCollapseOwner(
                                reason: "anchorChanged"
                            )
                        }
                        if model.messages.count > 24 {
                            model.releaseConcreteConversationEntryWindow()
                            bottomNavigationCompactWindowConversationID = nil
                        }
                        if VersionFlashTrace.isEnabled {
                            let previousTail = previousAnchorID.messageIDs.last
                                .map(VersionFlashTrace.identifierToken)
                                ?? "nil"
                            let currentTail = currentAnchorID.messageIDs.last
                                .map(VersionFlashTrace.identifierToken)
                                ?? "nil"
                            let hostTailMessage = messageHosts.last?.message
                            let hostTailMatchesAnchor = hostTailMessage?.id
                                == currentAnchorID.messageIDs.last
                            let currentTailMessage = hostTailMatchesAnchor
                                ? hostTailMessage
                                : nil
                            VersionFlashTrace.record(
                                "ANCHOR_COMMIT"
                                    + " oldConv=\(VersionFlashTrace.identifierToken(previousAnchorID.positionRequest.conversationID))"
                                    + " oldReq=\(previousAnchorID.positionRequest.request)"
                                    + " oldRows=\(previousAnchorID.messageIDs.count)"
                                    + " oldTail=\(previousTail)"
                                    + " conv=\(VersionFlashTrace.identifierToken(currentAnchorID.positionRequest.conversationID))"
                                    + " req=\(currentAnchorID.positionRequest.request)"
                                    + " rows=\(currentAnchorID.messageIDs.count)"
                                    + " tail=\(currentTail)"
                                    + " hostTail=\(hostTailMessage.map { VersionFlashTrace.identifierToken($0.id) } ?? "nil")"
                                    + " hostTailMatches=\(hostTailMatchesAnchor)"
                                    + " tailVersion=\(currentTailMessage.map { String($0.version) } ?? "nil")"
                                    + " tailGroup=\(currentTailMessage.map { VersionFlashTrace.opaqueToken($0.versionGroupKey) } ?? "nil")"
                            )
                        }
                        if latestConversationBottomAnchorFrame?.anchorID != currentAnchorID {
                            latestConversationBottomAnchorFrame = nil
                        }
                        if nativeConversationContentReadyAnchorID != currentAnchorID {
                            nativeConversationContentReadyAnchorID = nil
                        }
                        if messageFramesAnchorID != currentAnchorID {
                            messageFramesAnchorID = nil
                            messageFrames = [:]
                        }
                        if pendingKeyboardViewportPin?.anchorID != currentAnchorID {
                            pendingKeyboardViewportPin = nil
                            cancelKeyboardNativeSettleWatcher()
                        }
                        if pendingBottomRowMaterializationAnchorID != currentAnchorID {
                            bottomRowMaterializationTask?.cancel()
                            bottomRowMaterializationTask = nil
                            pendingBottomRowMaterializationAnchorID = nil
                        }
                        if activeUserMessageSendPositionRequestID == nil,
                           let request = model.pendingUserMessageSendPositionRequest,
                           request.conversationID == model.selectedConversationID {
                            let releaseBecameStale =
                                sendPositionNativeReleaseRequest?.requestID == request.id
                                && sendPositionNativeReleaseRequest?.sourceAnchorID
                                    != currentAnchorID
                            let acknowledgementBecameStale =
                                acknowledgedSendPositionNativeRelease?.requestID == request.id
                                && acknowledgedSendPositionNativeRelease?.sourceAnchorID
                                    != currentAnchorID
                            if releaseBecameStale || acknowledgementBecameStale {
                                // A fast provider completion can replace the
                                // visible tail during the two-turn native edge
                                // release. Rekey the exact same send request to
                                // the new revision instead of waiting forever
                                // for an acknowledgement that must be dropped.
                                clearSendPositionNativeRelease(for: request.id)
                                scheduleUserMessageSendPositioning(
                                    request,
                                    using: scrollProxy
                                )
                            }
                        }
                    }
                    .onChange(of: navigationRequest) { _, request in
                        guard let request,
                              request.positionRequest == currentConversationPositionRequest else { return }
                        switch request.action {
                        case .top:
                            // The iOS 18 modifier first releases any retained
                            // semantic bottom edge. Its typed acknowledgement
                            // starts the window mutation and proxy animation.
                            break
                        case .previousUserMessage:
                            scrollToAdjacentUserMessage(direction: -1, using: scrollProxy, request: request)
                        case .nextUserMessage:
                            scrollToAdjacentUserMessage(direction: 1, using: scrollProxy, request: request)
                        case let .message(messageID):
                            scrollToMessage(messageID, using: scrollProxy, request: request)
                        case .bottom:
                            break
                        }
                    }
                    .onChange(
                        of: ConversationPositionRequestKey(
                            conversationID: model.selectedConversationID,
                            request: model.conversationBottomReturnRequest
                        )
                    ) { previous, current in
                        ChatBottomTrace.log(
                            "CONVERSATION_CHANGE old=\(ChatBottomTrace.shortID(previous.conversationID))/\(previous.request)"
                                + " new=\(ChatBottomTrace.shortID(current.conversationID))/\(current.request)"
                                + " concreteEntry=\(model.usesConcreteConversationEntryWindow) "
                                + chatBottomTraceState
                        )
                        #if DEBUG
                        navigationStressLog(
                            "position change \(previous.conversationID.uuidString.prefix(5))/\(previous.request) -> "
                                + "\(model.selectedConversation?.title ?? "?") "
                                + "\(current.conversationID.uuidString.prefix(5))/\(current.request) "
                                + "messages=\(model.messages.count) window=\(model.messageWindowStartIndex)..<\(model.messageWindowEndIndex)"
                        )
                        #endif
                        if previous != current {
                            cancelMessageReplacementLanding()
                            bottomNavigationCompactWindowConversationID = nil
                            concreteFavoriteTargetMessageID = nil
                            cancelAutomaticReasoningCollapseOwner(
                                reason: "conversationPositionChanged"
                            )
                            invalidateVersionReplacement(reason: "conversationChange")
                            landedMessageTargetID = nil
                            pendingKeyboardViewportPin = nil
                            cancelKeyboardNativeSettleWatcher()
                            isNativeScrollPhaseActive = false
                            streamingFollowTouchPauseAnchorID = nil
                            let hadActiveNavigation = navigationRequest != nil
                                || navigationScrollTask != nil
                                || pendingNavigationRequest != nil
                            navigationScrollTask?.cancel()
                            navigationScrollTask = nil
                            navigationRequest = nil
                            cancelPendingMessageNavigation()
                            if hadActiveNavigation {
                                isNativeVerticalScrollMotionArmed = false
                                interruptNativeScrollMotion()
                            }
                        }
                        if previous.conversationID != current.conversationID {
                            // A picker belongs to the conversation where it opened.
                            // Clearing its identity also invalidates an in-flight
                            // dismissal completion before it can open an old sheet.
                            if reactionPicker != nil { reactionPicker = nil }
                            regenerationViewportTransitionCoordinator.cancelAll(
                                reason: "conversationChanged"
                            )
                            activatedCoveredMessageTargetRequestID = nil
                            keyboardViewportPinTask?.cancel()
                            keyboardViewportPinTask = nil
                            invalidateKeyboardDismissalTransition()
                            keyboardBottomFollowIntent = false
                            isNativeVerticalScrollMotionArmed = false
                            isNativeScrollPhaseActive = false
                            if newConversationFirstMessageID != current.conversationID {
                                newConversationFirstMessageID = nil
                            }
                            if newConversationFollowSuppressionID != current.conversationID {
                                newConversationFollowSuppressionID = nil
                            }
                            navigationAnchorMessageID = nil
                            messageFramesAnchorID = nil
                            messageFrames = [:]
                            messageWindowLoadTask?.cancel()
                            messageWindowLoadTask = nil
                            lastKnownNearBottom = true
                            lastMeasuredNearBottom = false
                            lastMeasuredAtBottom = false
                            isQuickReturnToBottomVisible = false
                        }
                        // A selection updates both fields in one transaction.
                        // Observe their composite value so the stable chat host
                        // submits exactly one return-to-bottom operation.
                        if model.pendingMessageTargetNavigationRequest?.conversationID
                            == current.conversationID {
                            schedulePendingMessageTargetNavigation()
                        } else if let request = model.pendingUserMessageSendPositionRequest,
                           request.conversationID == current.conversationID {
                            scheduleUserMessageSendPositioning(request, using: scrollProxy)
                        } else {
                            scheduleConversationReturn(using: scrollProxy)
                        }
                    }
                    .onChange(of: model.pendingUserMessageSendPositionRequest) { _, request in
                        guard let request else {
                            keyboardUnifiedSendHandoff = nil
                            cancelUserMessageSendPositioning(consumingPendingRequest: false)
                            return
                        }
                        if keyboardUnifiedSendHandoff?.requestID != request.id {
                            keyboardUnifiedSendHandoff = nil
                        }
                        cancelCodeDisclosure(reason: "sendRequested")
                        cancelAutomaticReasoningCollapseOwner(
                            reason: "sendRequested"
                        )
                        scheduleUserMessageSendPositioning(request, using: scrollProxy)
                    }
                    .onChange(of: sendPresentationNativeReleaseID) { _, requestID in
                        guard let requestID else { return }
                        beginKeyboardUnifiedSendHandoff(requestID: requestID)
                    }
                    .onChange(of: isComposerKeyboardPresented) { wasPresented, isPresented in
                        guard wasPresented,
                              !isPresented,
                              let request = model.pendingUserMessageSendPositionRequest,
                              request.conversationID == model.selectedConversationID else {
                            return
                        }
                        ChatBottomTrace.log(
                            "SEND_LIFECYCLE_RESUME reason=keyboardDidHide"
                                + " request=\(ChatBottomTrace.shortID(request.id)) "
                                + chatBottomTraceState
                        )
                        scheduleUserMessageSendPositioning(request, using: scrollProxy)
                    }
                    .onChange(of: model.pendingMessageTargetNavigationRequest) { _, request in
                        if activatedCoveredMessageTargetRequestID != nil,
                           activatedCoveredMessageTargetRequestID != request?.id {
                            activatedCoveredMessageTargetRequestID = nil
                        }
                        if let concreteFavoriteTargetMessageID,
                           concreteFavoriteTargetMessageID != request?.messageID {
                            self.concreteFavoriteTargetMessageID = nil
                        }
                        if request != nil {
                            cancelCodeDisclosure(reason: "messageTargetRequested")
                            cancelAutomaticReasoningCollapseOwner(
                                reason: "messageTargetRequested"
                            )
                        }
                        guard request?.conversationID == model.selectedConversationID else {
                            messageTargetNavigationTask?.cancel()
                            messageTargetNavigationTask = nil
                            messageTargetCoordinatorRequestID = nil
                            nativeReleasedMessageTargetRequestID = nil
                            return
                        }
                        schedulePendingMessageTargetNavigation()
                    }
                    .onChange(of: model.isFavoritesPresented) { _, isPresented in
                        if !isPresented,
                           model.pendingMessageTargetNavigationRequest?.conversationID
                            == model.selectedConversationID {
                            schedulePendingMessageTargetNavigation()
                        }
                    }
                    .onChange(of: model.preferences.autoScrollEnabled) { _, enabled in
                        if !enabled {
                            cancelAutomaticReasoningCollapseOwner(
                                reason: "autoScrollDisabled"
                            )
                            invalidateVersionReplacement(reason: "autoScrollDisabled")
                            cancelUserMessageSendPositioning(consumingPendingRequest: true)
                            keyboardViewportPinTask?.cancel()
                            keyboardViewportPinTask = nil
                            pendingKeyboardViewportPin = nil
                            invalidateKeyboardDismissalTransition()
                            keyboardBottomFollowIntent = false
                            streamFollowTask?.cancel()
                            streamFollowTask = nil
                            autoFollowEngaged = false
                        } else {
                            autoFollowEngaged = !isMessageTargetNavigationOwned
                                && lastKnownNearBottom
                        }
                    }
                    .onChange(of: layoutFollowRequest) { _, _ in
                        scheduleLayoutFollowCorrection(using: scrollProxy)
                    }
                    .onChange(of: keyboardViewportPinRequest) { _, _ in
                        cancelMessageReplacementLanding()
                        scheduleKeyboardViewportPin(using: scrollProxy)
                    }
                    .onChange(of: visibleMessages.last?.id) { _, _ in
                        completeFreshConversationBottomHandoffIfNeeded()
                    }
                    .onChange(of: automaticReasoningCollapseObservation) {
                        previousObservation,
                        observation in
                        updateAutomaticReasoningCollapseAuthorization(
                            from: previousObservation,
                            to: observation
                        )
                    }
                    .onChange(of: visibleMessages.last?.updatedAt) { _, _ in
                        completeFreshConversationBottomHandoffIfNeeded()
                        if abandonAutomaticReasoningCollapseOwnerForChangedTailIdentityIfNeeded() {
                            return
                        }
                        if #available(iOS 18.0, *),
                           model.selectedConversationIsStreaming,
                           shouldKeepNativeBottomPosition,
                           nativeConversationContentReadyAnchorID
                            == currentConversationBottomAnchorID {
                            // The current native ScrollPosition has acknowledged
                            // this exact row revision, so its geometry correction
                            // exclusively owns ordinary stream growth. Keeping the
                            // proxy task here submits a second disabled bottom jump
                            // for the same display update.
                            streamFollowTask?.cancel()
                            streamFollowTask = nil
                            ChatBottomTrace.log(
                                "STREAM_FOLLOW_SKIP reason=nativeReady "
                                    + chatBottomTraceState
                            )
                        } else {
                            // iOS 17, native-readiness gaps and non-stream tail
                            // updates retain the established proxy fallback.
                            scheduleStreamingFollow(using: scrollProxy)
                        }
                    }
                    .background {
                        ChatDrawerPresentationObserver { isPresented in
                            if isPresented {
                                // Use the existing semantic event, before the idle
                                // cleanup gate; there is no drawer-frame observer.
                                if reactionPicker != nil { reactionPicker = nil }
                                guard hasActiveDrawerOpeningCleanupWork else {
                                    return
                                }
                                cancelCodeDisclosure(reason: "drawerPresented")
                                cancelAutomaticReasoningCollapseOwner(
                                    reason: "drawerPresented"
                                )
                                cancelMessageTargetNavigationForUserInteraction()
                                invalidateVersionReplacement(reason: "drawerPresented")
                                cancelMessageReplacementLanding()
                                cancelUserMessageSendPositioning(consumingPendingRequest: true)
                                pendingKeyboardViewportPin = nil
                                cancelMessageNavigationForUserInteraction(reason: "drawerPresented")
                                navigationAnchorMessageID = nil
                                isNativeVerticalScrollMotionArmed = false
                                isNativeScrollPhaseActive = false
                                // Do not keep relaying out a long TextKit message while
                                // the horizontal drawer transition owns the frame.
                                conversationReturnTask?.cancel()
                                conversationReturnTask = nil
                                bottomRowMaterializationTask?.cancel()
                                bottomRowMaterializationTask = nil
                                pendingBottomRowMaterializationAnchorID = nil
                                layoutFollowTask?.cancel()
                                layoutFollowTask = nil
                                keyboardViewportPinTask?.cancel()
                                keyboardViewportPinTask = nil
                                if hasActiveKeyboardDismissalWork {
                                    invalidateKeyboardDismissalTransition()
                                }
                                keyboardBottomFollowIntent = false
                            } else if model.pendingMessageTargetNavigationRequest?.conversationID
                                == model.selectedConversationID {
                                schedulePendingMessageTargetNavigation()
                            } else if let latestConversationBottomAnchorFrame {
                                // Selection happens while chat scrolling is disabled
                                // behind the drawer. Apply the pending native edge only
                                // after the drawer releases scroll ownership.
                                handleConversationBottomAnchorFrame(
                                    latestConversationBottomAnchorFrame,
                                    using: scrollProxy
                                )
                            }
                        }
                    }
                }
                .modifier(
                    ConversationSwitchFadeModifier(
                        conversationID: model.selectedConversationID
                    )
                )
            }
        }
        .modifier(
            EmptyOrLegacyChatHeader(
                isConversationEmpty: visibleMessages.isEmpty,
                topSafeAreaInset: topSafeAreaInset,
                onOpenDrawer: onOpenDrawer
            )
        )
        .overlay(alignment: .bottom) {
            measuredComposer
        }
        .overlay(alignment: .bottom) {
            DrawerAwareQuickReturnToBottom(
                baseVisible: shouldShowQuickReturnToBottomIgnoringDrawer,
                bottomPadding: composerBottomClearance + 8,
                onReturnToBottom: requestQuickReturnToBottom
            )
        }
        // Keep these controls out of the transcript ScrollView's interaction
        // subtree. A real Button can then receive the first tap while native
        // inertia is still moving, instead of donating that touch only to stop.
        .overlay(alignment: .bottomTrailing) {
            MessageNavigationPanel(
                onTop: { requestMessageNavigation(.top) },
                onPrevious: { requestMessageNavigation(.previousUserMessage) },
                onNext: { requestMessageNavigation(.nextUserMessage) },
                onBottom: { requestMessageNavigation(.bottom) }
            )
            .padding(.trailing, 8)
            .padding(.bottom, composerBottomClearance + 8)
            // Scope the transition to this small leaf. Applying animation to
            // ChatView itself makes drawer-close and conversation-bottom reset
            // join the same transaction, which was 4472's switch regression.
            .modifier(
                DrawerAwareMessageNavigationPanelVisibility(
                    baseVisible: shouldShowNavigationPanelIgnoringDrawer,
                    onHidden: cancelPendingMessageNavigation
                )
            )
        }
        .overlay {
            // Only install the positioning container while a picker is visible.
            if let presentation = reactionPicker,
               let message = model.messages.first(where: { $0.id == presentation.messageID }) {
                MessageReactionPickerOverlay(
                    presentation: presentation,
                    selectedReaction: message.reactions.userReaction,
                    onSelect: { reaction in
                        model.performCardHaptic()
                        let shouldPreserveBottom = model.preferences.autoScrollEnabled
                            && autoFollowEngaged
                            && lastKnownNearBottom
                            && !isUserScrollActive
                        let next = message.reactions.userReaction == reaction ? nil : reaction
                        model.setMessageUserReaction(message.id, reaction: next)
                        if shouldPreserveBottom {
                            requestLayoutFollowCorrection(requiresNearBottom: false)
                        }
                    },
                    onMore: {
                        guard reactionPicker?.id == presentation.id else { return }
                        model.performCardHaptic()
                        messageSheetPresentation = MessageSheetPresentation(
                            message: message,
                            kind: .actions
                        )
                    },
                    onDismiss: {
                        guard reactionPicker?.id == presentation.id else { return }
                        reactionPicker = nil
                    }
                )
                .id(presentation.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardAnimationTiming(from: notification)
            let isOpening = keyboardIsOpening(notification)
            if isOpening {
                isComposerKeyboardPresented = true
                cancelCodeDisclosure(reason: "keyboardWillChangeFrame")
                cancelAutomaticReasoningCollapseOwner(
                    reason: "keyboardWillChangeFrame"
                )
                ChatBottomTrace.beginKeyboardCycleIfNeeded()
            }
            ChatBottomTrace.log(
                "KEYBOARD_CHANGE branch=\(isOpening ? "opening" : "ignored")"
                    + " \(keyboardNotificationTrace(notification)) "
                    + chatBottomTraceState
            )
            guard isOpening else { return }
            requestKeyboardViewportPin(allowsFocusPending: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            isComposerKeyboardPresented = true
            cancelCodeDisclosure(reason: "keyboardWillShow")
            cancelAutomaticReasoningCollapseOwner(reason: "keyboardWillShow")
            updateKeyboardAnimationTiming(from: notification)
            ChatBottomTrace.beginKeyboardCycleIfNeeded()
            ChatBottomTrace.log(
                "KEYBOARD_SHOW \(keyboardNotificationTrace(notification)) "
                    + chatBottomTraceState
            )
            requestKeyboardViewportPin(allowsFocusPending: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
            isComposerKeyboardPresented = true
            ChatBottomTrace.log(
                "KEYBOARD_DID_SHOW \(keyboardNotificationTrace(notification)) "
                    + chatBottomTraceState
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            cancelCodeDisclosure(reason: "keyboardWillHide")
            cancelAutomaticReasoningCollapseOwner(reason: "keyboardWillHide")
            updateKeyboardAnimationTiming(from: notification)
            ChatBottomTrace.log(
                "KEYBOARD_WILL_HIDE \(keyboardNotificationTrace(notification)) "
                    + chatBottomTraceState
            )
            // Opening retries and ordinary layout corrections must not cross
            // into the dismissal. Either can submit a disabled bottom command
            // a few frames after the animated geometry recovery starts.
            if !isKeyboardDismissalTransition,
               keyboardViewportPinTask != nil {
                ChatBottomTrace.log("KEYBOARD_TASK_CANCEL source=willHideOpening " + chatBottomTraceState)
                keyboardViewportPinTask?.cancel()
                keyboardViewportPinTask = nil
            }
            if layoutFollowTask != nil {
                ChatBottomTrace.log("LAYOUT_FOLLOW_CANCEL source=willHide " + chatBottomTraceState)
                layoutFollowTask?.cancel()
                layoutFollowTask = nil
            }
            let pendingOpenWasBottomIntent = pendingKeyboardViewportPin.map {
                $0.anchorID == currentConversationBottomAnchorID
                    && pendingKeyboardViewportPinHasReachedBottom($0)
            } ?? false
            pendingKeyboardViewportPin = nil
            requestKeyboardDismissalViewportPin(
                notification,
                pendingOpenWasBottomIntent: pendingOpenWasBottomIntent
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { notification in
            isComposerKeyboardPresented = false
            ChatBottomTrace.log(
                "KEYBOARD_DID_HIDE \(keyboardNotificationTrace(notification)) "
                    + chatBottomTraceState
            )
            ChatBottomTrace.finishKeyboardCycleIfNeeded()
        }
        .onChange(of: model.isComposerFocused) { _, isFocused in
            cancelCodeDisclosure(reason: "composerFocusChanged")
            cancelAutomaticReasoningCollapseOwner(
                reason: "composerFocusChanged"
            )
            invalidateVersionReplacement(reason: "composerFocusChanged")
            guard isFocused else {
                if pendingKeyboardViewportPin?.anchorID == currentConversationBottomAnchorID {
                    // FocusState can resign before UIKit posts willHide. Preserve
                    // the bottom-bound intent independently, then invalidate the
                    // open token so it can never commit after the keyboard closes.
                    keyboardBottomFollowIntent = pendingKeyboardViewportPin.map {
                        pendingKeyboardViewportPinHasReachedBottom($0)
                    } ?? false
                    pendingKeyboardViewportPin = nil
                    ChatBottomTrace.log(
                        "KEYBOARD_FOCUS_RESIGN_TRANSFER accepted=\(keyboardBottomFollowIntent) "
                            + chatBottomTraceState
                    )
                }
                return
            }
            cancelMessageTargetNavigationForUserInteraction()
            // Consume the revision-scoped pre-transition token from the
            // authoritative focus transition so the first presentation follows.
            requestKeyboardViewportPin()
        }
        .onDisappear {
            cancelCodeDisclosure(reason: "viewDisappeared")
            regenerationViewportTransitionCoordinator.cancelAll(
                reason: "viewDisappeared"
            )
            cancelAutomaticReasoningCollapseOwner(reason: "viewDisappeared")
            invalidateVersionReplacement(reason: "viewDisappeared")
            keyboardUnifiedSendHandoff = nil
            userScrollIdleTask?.cancel()
            streamFollowTask?.cancel()
            if let gate = model.sendPresentationGate {
                model.releaseSendPresentationGate(gate.requestID)
            }
            cancelUserMessageSendPositioning(consumingPendingRequest: false)
            bottomRowMaterializationTask?.cancel()
            bottomRowMaterializationTask = nil
            pendingBottomRowMaterializationAnchorID = nil
            layoutFollowTask?.cancel()
            keyboardViewportPinTask?.cancel()
            pendingKeyboardViewportPin = nil
            cancelKeyboardNativeSettleWatcher()
            isNativeScrollPhaseActive = false
            streamingFollowTouchPauseAnchorID = nil
            navigationScrollTask?.cancel()
            navigationScrollTask = nil
            navigationRequest = nil
            cancelPendingMessageNavigation()
            navigationAnchorMessageID = nil
            messageTargetNavigationTask?.cancel()
            messageTargetNavigationTask = nil
            messageTargetCoordinatorRequestID = nil
            nativeReleasedMessageTargetRequestID = nil
            landedMessageTargetID = nil
            concreteFavoriteTargetMessageID = nil
            isComposerKeyboardPresented = false
            messageWindowLoadTask?.cancel()
            messageWindowLoadTask = nil
            cancelMessageReplacementLanding()
            cancelConversationReturnPositioning()
            navigationHideTask?.cancel()
        }
        .sheet(item: $messageSheetPresentation) { presentation in
            messageSheetContent(presentation)
        }
        .alert(regenerationConfirmationMessage?.role == .user ? L10n.lookup("重新发送") : L10n.lookup("重新生成"), isPresented: Binding(
            get: { regenerationConfirmationMessage != nil },
            set: { isPresented in
                if !isPresented {
                    regenerationViewportTransitionCoordinator.discardPrepared(
                        reason: "confirmationDismissed"
                    )
                    regenerationConfirmationMessage = nil
                }
            }
        )) {
            Button(L10n.lookup("取消"), role: .cancel) {
                regenerationViewportTransitionCoordinator.discardPrepared(
                    reason: "confirmationCancelled"
                )
                regenerationConfirmationMessage = nil
            }
            Button(regenerationConfirmationMessage?.role == .assistant ? L10n.lookup("重新生成") : L10n.lookup("重新发送")) {
                if let message = regenerationConfirmationMessage {
                    beginRegeneration(for: message)
                }
                regenerationConfirmationMessage = nil
            }
        } message: {
            if regenerationConfirmationMessage?.role == .user {
                Text(model.preferences.regenerateDeleteTrailingMessages
                     ? L10n.lookup("会删除这条消息后面的后续消息，然后重新发送。")
                     : L10n.lookup("会重新发送这条消息，后续消息会保留。"))
            } else {
                Text(model.preferences.regenerateDeleteTrailingMessages
                     ? L10n.lookup("会删除这条消息后面的后续消息，然后重新生成。")
                     : L10n.lookup("会基于这条消息重新生成一条新回复，后续消息会保留。"))
            }
        }
    }

    private var shouldShowNavigationPanelIgnoringDrawer: Bool {
        guard !model.messages.isEmpty,
              reactionPicker == nil,
              messageSheetPresentation == nil else { return false }
        return switch model.preferences.mobileMessageNavButtonsMode {
        case .always: true
        case .scroll: showTransientNavigation || pendingNavigationRequest != nil
        case .simple: false
        case .never: false
        }
    }

    private var shouldShowQuickReturnToBottomIgnoringDrawer: Bool {
        guard model.preferences.mobileMessageNavButtonsMode == .simple,
              !model.messages.isEmpty,
              reactionPicker == nil,
              messageSheetPresentation == nil else { return false }
        return model.hasLaterMessages || isQuickReturnToBottomVisible
    }

    private func requestQuickReturnToBottom() {
        // Keep the simple control visible while the existing navigation owner
        // loads a later window and lands. Exact latest-bottom geometry is the
        // only successful dismissal acknowledgement.
        isQuickReturnToBottomVisible = true
        requestMessageNavigation(.bottom)
    }

    @ViewBuilder
    private func messageSheetContent(
        _ presentation: MessageSheetPresentation
    ) -> some View {
        switch presentation.kind {
        case .actions:
            MessageActionsSheet(
                message: presentation.message,
                onDelete: { message, deletesAllVersions in
                    deleteMessagePreservingReadingPosition(
                        message,
                        deletesAllVersions: deletesAllVersions
                    )
                }
            )
        case .edit:
            MessageEditSheet(
                text: $directEditText,
                roleTitle: presentation.message.role == .user
                    ? L10n.lookup("编辑用户消息")
                    : L10n.lookup("编辑助手消息"),
                allowsSaveAndSend: true
            ) { shouldSend in
                model.editMessage(
                    presentation.message.id,
                    text: directEditText,
                    sendAfterSave: shouldSend
                )
            }
        }
    }

    private var hasActiveKeyboardDismissalWork: Bool {
        keyboardNativeSettleTask != nil
            || isKeyboardDismissalTransition
            || isKeyboardDismissalGeometryRecoveryActive
            || keyboardDismissalViewportPinRequest != nil
            || keyboardDismissalAnimationDuration != nil
            || keyboardViewportPinAllowsUnfocused
            || pendingKeyboardDismissalDeadline != nil
            || keyboardScrollActivityIgnoreUntil > Date()
    }

    /// The ordinary keyboard-closed, navigation-idle drawer path has nothing
    /// to cancel. Avoid replaying a long series of nil/false writes at the
    /// semantic handoff; if any real owner exists, the established cleanup
    /// below still runs in full.
    private var hasActiveDrawerOpeningCleanupWork: Bool {
        automaticReasoningCollapseAuthorization != nil
            || automaticReasoningExpandedCheckpoint != nil
            || automaticReasoningCollapseRearmRequest != nil
            || automaticReasoningCollapseOwner != nil
            || regenerationViewportTransitionCoordinator.hasActiveWork
            || landedMessageTargetID != nil
            || concreteFavoriteTargetMessageID != nil
            || messageTargetNavigationTask != nil
            || messageTargetCoordinatorRequestID != nil
            || nativeReleasedMessageTargetRequestID != nil
            || selectedMessageTargetNavigationRequest != nil
            || messageReplacementLandingTask != nil
            || messageReplacementRequest != nil
            || userMessageSendPositionTask != nil
            || activeUserMessageSendPositionRequestID != nil
            || activeUserMessageSendPositionTaskID != nil
            || sendPositionNativeReleaseRequest != nil
            || acknowledgedSendPositionNativeRelease != nil
            || keyboardUnifiedSendHandoff != nil
            || model.pendingUserMessageSendPositionRequest?.conversationID
                == model.selectedConversationID
            || pendingKeyboardViewportPin != nil
            || navigationRequest != nil
            || navigationScrollTask != nil
            || pendingNavigationRequest != nil
            || pendingNavigationPromotionTask != nil
            || navigationAnchorMessageID != nil
            || isNativeVerticalScrollMotionArmed
            || isNativeScrollPhaseActive
            || conversationReturnTask != nil
            || bottomRowMaterializationTask != nil
            || pendingBottomRowMaterializationAnchorID != nil
            || layoutFollowTask != nil
            || keyboardViewportPinTask != nil
            || hasActiveKeyboardDismissalWork
            || keyboardBottomFollowIntent
    }

    private var currentConversationPositionRequest: ConversationPositionRequestKey {
        ConversationPositionRequestKey(
            conversationID: model.selectedConversationID,
            request: model.conversationBottomReturnRequest
        )
    }

    private var currentConversationBottomAnchorID: ConversationBottomAnchorID {
        ConversationBottomAnchorID(
            positionRequest: currentConversationPositionRequest,
            messageIDs: model.messages.map(\.id)
        )
    }

    private var currentChatViewportSessionID: ChatViewportSessionID {
        ChatViewportSessionID(
            conversationID: model.selectedConversationID,
            positionRequest: model.conversationBottomReturnRequest,
            lazyWindowGeneration: conversationLazyWindowGeneration
        )
    }

    private var isCodeDisclosureInProgress: Bool {
        messageReplacementRequest?.codeDisclosure != nil
    }

    private var activeCodeLayoutRequestID: UUID? {
        guard let request = messageReplacementRequest,
              request.didCommit, request.codeDisclosure != nil else { return nil }
        return request.id
    }

    @MainActor
    private func advanceConversationLazyWindowGeneration() {
        cancelCodeDisclosure(reason: "lazyWindowChanged")
        conversationLazyWindowGeneration &+= 1
    }

    private var hasContentMutationCompetingOwner: Bool {
        automaticReasoningCollapseOwner != nil
            || regenerationViewportTransitionCoordinator.hasActiveWork
            || messageReplacementLandingTask != nil
            || messageReplacementRequest != nil
            || userMessageSendPositionTask != nil
            || activeUserMessageSendPositionRequestID != nil
            || activeUserMessageSendPositionTaskID != nil
            || conversationReturnTask != nil
            || bottomRowMaterializationTask != nil
            || pendingBottomRowMaterializationAnchorID != nil
            || navigationRequest != nil
            || navigationScrollTask != nil
            || pendingNavigationRequest != nil
            || pendingNavigationPromotionTask != nil
            || messageTargetNavigationTask != nil
            || isMessageTargetNavigationOwned
            || pendingKeyboardViewportPin != nil
            || keyboardViewportPinTask != nil
            || keyboardNativeSettleTask != nil
            || pendingKeyboardDismissalDeadline != nil
            || isKeyboardDismissalTransition
            || isKeyboardDismissalGeometryRecoveryActive
            || keyboardDismissalViewportPinRequest != nil
            || messageWindowLoadTask != nil
            || model.isDrawerPresented
            || model.isCompressingContext
            || isPositioningCurrentConversation
            || isVerticalScrollGestureActive
            || isNativeVerticalScrollMotionArmed
            || isNativeScrollPhaseActive
    }

    @MainActor
    private func acknowledgeCodeDisclosureLayout(
        _ frames: [UUID: CGRect], using scrollProxy: ScrollViewProxy
    ) {
        guard let request = messageReplacementRequest,
              request.didCommit,
              let change = request.codeDisclosure,
              change.state.layoutRequestID == request.id,
              let frame = frames[request.id],
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        if request.codeLayoutSize != frame.size {
            messageReplacementRequest?.codeLayoutSize = frame.size
        }
        advanceMessageReplacementIfReady(using: scrollProxy)
        finishMessageReplacementIfReady()
    }

    @MainActor
    private func beginCodeDisclosure(_ change: CodeDisclosureChange) {
        let previous = messageReplacementRequest
        cancelCodeDisclosure(reason: "supersededByUserDisclosure")
        guard change.scope.conversationID == model.selectedConversationID,
              let message = model.messages.first(where: { $0.id == change.scope.messageID }),
              !hasContentMutationCompetingOwner,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil, scrollView.bounds.height > 0,
              !messageReplacementLandingWasInterrupted(
                  scrollView, expectedScrollViewIdentity: ObjectIdentifier(scrollView)
              ),
              let frame = change.state.anchor.frameInWindow(matching: scrollView) else {
            ChatBottomTrace.log("CODE_DISCLOSURE_DROP reason=notReady")
            return
        }
        clearAutomaticReasoningCollapseAuthorization(reason: "codeDisclosure")
        let inherited = previous.flatMap { pending -> MessageReplacementViewportRequest? in
            guard let oldChange = pending.codeDisclosure,
                  oldChange.scope == change.scope, oldChange.blockID == change.blockID,
                  pending.scrollViewIdentity == ObjectIdentifier(scrollView),
                  (pending.landingAnchorID ?? pending.sourceAnchorID)
                    == currentConversationBottomAnchorID else { return nil }
            return pending
        }
        let atBottom = inherited?.sourceWasAtBottom
            ?? (refreshMeasuredBottomStateFromUIKit().isAtBottom
                && !model.hasLaterMessages && hasCurrentConcreteLatestBottomContent)
        let sourceEdgeY: CGFloat
        if let inherited, case .codeDisclosure(_, let oldChange, let edgeY) = inherited.edit,
           oldChange.edge == change.edge {
            sourceEdgeY = edgeY
        } else {
            sourceEdgeY = change.edge.position(in: frame)
        }
        var request = MessageReplacementViewportRequest(
            id: UUID(),
            edit: .codeDisclosure(message, change: change, anchorY: sourceEdgeY),
            sourceAnchorID: currentConversationBottomAnchorID,
            scrollViewIdentity: ObjectIdentifier(scrollView),
            readingAnchorID: message.id, readingAnchorMinY: nil, precedingUserID: nil,
            sourceWasAutoFollowEngaged: inherited?.sourceWasAutoFollowEngaged ?? autoFollowEngaged,
            sourceWasAtBottom: atBottom
        )
        request.keepsExactBottom = atBottom
        if let streamingID = model.activeStreamingMessageID(for: message.conversationID) {
            request.streamingMessage = previous?.streamingMessage.flatMap {
                $0.id == streamingID ? $0 : nil
            } ?? model.messages.first { $0.id == streamingID }
        }
        if let streaming = request.streamingMessage {
            model.setStreamingTextDisplaySuspended(
                conversationID: streaming.conversationID, messageID: streaming.id,
                owner: .codeDisclosure(request.id), suspended: true
            )
        }
        prepareForMessageReplacementLanding()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            change.state.prepare(request.id, expanded: change.expanded)
            messageReplacementRequest = request
        }
        ChatBottomTrace.log("CODE_DISCLOSURE_BEGIN request=\(ChatBottomTrace.shortID(request.id))"
            + " message=\(ChatBottomTrace.shortID(message.id)) block=\(change.blockID)"
            + " expanded=\(change.expanded) edge=\(change.edge.rawValue)"
            + " bottom=\(atBottom) " + chatBottomTraceState)
    }

    @MainActor
    private func cancelCodeDisclosure(reason: String) {
        guard isCodeDisclosureInProgress else { return }
        ChatBottomTrace.log("CODE_DISCLOSURE_CANCEL reason=\(reason)")
        cancelMessageReplacementLanding()
    }

    private func messagesForCodeDisclosureLayout(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard let held = messageReplacementRequest?.streamingMessage,
              let index = messages.firstIndex(where: {
                  $0.id == held.id && $0.conversationID == held.conversationID
              }) else { return messages }
        var visible = messages
        visible[index] = held
        return visible
    }

    private func releaseCodeDisclosureDisplay(_ request: MessageReplacementViewportRequest) {
        guard let streaming = request.streamingMessage else { return }
        model.setStreamingTextDisplaySuspended(
            conversationID: streaming.conversationID, messageID: streaming.id,
            owner: .codeDisclosure(request.id), suspended: false
        )
    }

    private func conversationMessageHostID(
        for messageID: UUID
    ) -> ConversationMessageHostID {
        .message(messageID)
    }

    private var isVersionReplacementInProgress: Bool {
        messageReplacementRequest?.replacementMessage != nil
    }

    private func invalidateVersionReplacement(reason: String) {
        guard isVersionReplacementInProgress else { return }
        cancelMessageReplacementLanding()
    }

    private func beginVersionReplacement(from oldMessage: ChatMessage, to newMessage: ChatMessage) {
        guard oldMessage.id != newMessage.id,
              oldMessage.conversationID == model.selectedConversationID,
              newMessage.conversationID == oldMessage.conversationID,
              newMessage.versionGroupKey == oldMessage.versionGroupKey,
              model.versions(for: oldMessage.id).contains(where: { $0.id == newMessage.id }) else { return }
        let previous = messageReplacementRequest
        cancelMessageReplacementLanding()
        cancelMessageTargetNavigationForUserInteraction()
        cancelPendingMessageNavigation()
        navigationScrollTask?.cancel()
        navigationScrollTask = nil
        navigationRequest = nil
        cancelConversationReturnPositioning()
        guard let sourceMessage = model.messages.first(where: { $0.versionGroupKey == oldMessage.versionGroupKey }),
              sourceMessage.id != newMessage.id else { return }
        let sourceAnchorID = currentConversationBottomAnchorID
        guard let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              scrollView.bounds.height > 0 else {
            model.selectVersion(newMessage.version, for: sourceMessage.id)
            return
        }
        let sourceFrame = validConcreteMessageFrame(sourceMessage.id, anchorID: sourceAnchorID)
        let inherited = previous.flatMap { pending in
            pending.replacementMessage != nil
                && pending.message.conversationID == sourceMessage.conversationID
                && pending.message.versionGroupKey == sourceMessage.versionGroupKey
                && pending.scrollViewIdentity == ObjectIdentifier(scrollView)
                ? pending : nil
        }
        let atBottom = inherited?.sourceWasAtBottom ?? (currentUIKitBottomState?.isAtBottom == true)
        let keepBottom = sourceAnchorID.messageIDs.last == sourceMessage.id
            && !model.hasLaterMessages && atBottom
        var request = MessageReplacementViewportRequest(
            id: UUID(), edit: .replacement(sourceMessage, with: newMessage),
            sourceAnchorID: sourceAnchorID, scrollViewIdentity: ObjectIdentifier(scrollView),
            readingAnchorID: newMessage.id, readingAnchorMinY: nil, precedingUserID: nil,
            sourceWasAutoFollowEngaged: inherited?.sourceWasAutoFollowEngaged ?? autoFollowEngaged,
            sourceWasAtBottom: atBottom
        )
        request.keepsExactBottom = keepBottom
        request.readingAnchorMaxY = inherited?.readingAnchorMaxY ?? sourceFrame.map {
            min(max(1, $0.maxY), max(1, scrollViewportHeight - composerBottomClearance))
        }
        prepareForMessageReplacementLanding()
        messageReplacementRequest = request
        ChatBottomTrace.log("VERSION_REPLACEMENT_BEGIN request=\(ChatBottomTrace.shortID(request.id))"
            + " old=\(ChatBottomTrace.shortID(sourceMessage.id)) new=\(ChatBottomTrace.shortID(newMessage.id))"
            + " mode=\(keepBottom ? "bottom" : "reading")"
            + " edgeY=\(request.readingAnchorMaxY.map { String(format: "%.1f", $0) } ?? "nil") "
            + chatBottomTraceState)
    }

    private func schedulePendingMessageTargetNavigation() {
        guard let targetRequest = selectedMessageTargetNavigationRequest else {
            return
        }
        if messageTargetCoordinatorRequestID == targetRequest.id,
           messageTargetNavigationTask != nil {
            return
        }

        // The target row, rather than the bottom edge, owns this selection.
        // Revoke bottom-follow immediately while the favorites sheet and drawer
        // finish releasing their interaction ownership.
        cancelCodeDisclosure(reason: "messageTargetNavigation")
        landedMessageTargetID = nil
        if isCoveredFavoriteTargetRequest(targetRequest) {
            concreteFavoriteTargetMessageID = targetRequest.messageID
            ChatBottomTrace.log(
                "FAVORITE_TARGET_CONCRETE_ARMED"
                    + " request=\(ChatBottomTrace.shortID(targetRequest.id))"
                    + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                    + chatBottomTraceState
            )
        } else {
            concreteFavoriteTargetMessageID = nil
        }
        prepareMessageNavigation(for: .message(targetRequest.messageID))

        messageTargetNavigationTask?.cancel()
        messageTargetCoordinatorRequestID = targetRequest.id
        messageTargetNavigationTask = Task { @MainActor in
            var poll = 0
            var submittedAttempts = 0
            let startedAt = ProcessInfo.processInfo.systemUptime
            defer {
                if messageTargetCoordinatorRequestID == targetRequest.id {
                    messageTargetCoordinatorRequestID = nil
                    messageTargetNavigationTask = nil
                }
            }
            while true {
                if poll == 0 {
                    await awaitNextMainQueueTurn()
                } else {
                    try? await Task.sleep(
                        for: .milliseconds(poll < 240 ? 16 : 50)
                    )
                }
                poll += 1
                guard !Task.isCancelled,
                      model.pendingMessageTargetNavigationRequest == targetRequest else {
                    return
                }
                guard ProcessInfo.processInfo.systemUptime - startedAt < 20 else {
                    ChatBottomTrace.log(
                        "MESSAGE_TARGET_FAIL_CLOSED reason=coordinatorTimeout"
                            + " attempts=\(submittedAttempts)"
                            + " request=\(ChatBottomTrace.shortID(targetRequest.id))"
                            + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                            + chatBottomTraceState
                    )
                    if failOpenCoveredFavoriteTargetNavigation(
                        targetRequest,
                        reason: "coordinatorTimeout"
                    ) {
                        return
                    }
                    return
                }
                guard targetRequest.conversationID == model.selectedConversationID,
                      targetRequest.conversationPositionRequest
                        == model.conversationBottomReturnRequest else {
                    model.consumeMessageTargetNavigationRequest(targetRequest.id)
                    return
                }
                guard !model.isFavoritesPresented,
                      !model.isDrawerPresented,
                      DrawerInlineActionTapGate.allowsAction,
                      model.messages.contains(where: {
                          $0.id == targetRequest.messageID
                      }) else {
                    continue
                }

                if #available(iOS 18.0, *),
                   nativeReleasedMessageTargetRequestID != targetRequest.id {
                    continue
                }
                if isMessageTargetAttemptInFlight(targetRequest) {
                    continue
                }
                guard submittedAttempts < 3 else {
                    ChatBottomTrace.log(
                        "MESSAGE_TARGET_FAIL_CLOSED reason=attemptLimit"
                            + " attempts=\(submittedAttempts)"
                            + " request=\(ChatBottomTrace.shortID(targetRequest.id))"
                            + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                            + chatBottomTraceState
                    )
                    if failOpenCoveredFavoriteTargetNavigation(
                        targetRequest,
                        reason: "attemptLimit"
                    ) {
                        return
                    }
                    return
                }
                submittedAttempts += 1
                ensureCoveredMessageTargetTransition(for: targetRequest)
                requestMessageNavigation(.message(targetRequest.messageID))
            }
        }
    }

    private func ensureCoveredMessageTargetTransition(
        for targetRequest: MessageTargetNavigationRequest
    ) {
        guard targetRequest.usesCoveredViewportTransition,
              targetRequest.regenerationSourceMessageID == nil,
              activatedCoveredMessageTargetRequestID != targetRequest.id,
              !regenerationViewportTransitionCoordinator.owns(
                  requestID: targetRequest.id
              ),
              let token = regenerationViewportTransitionCoordinator
                .activateSolidCover(
                    from: chatScrollViewBox.scrollView,
                    backgroundColor: model.themeSurfaceUIColor
                ) else {
            return
        }
        activatedCoveredMessageTargetRequestID = targetRequest.id
        regenerationViewportTransitionCoordinator.bind(
            token,
            to: targetRequest.id
        )
    }

    private func isCoveredFavoriteTargetRequest(
        _ targetRequest: MessageTargetNavigationRequest
    ) -> Bool {
        targetRequest.usesCoveredViewportTransition
            && targetRequest.regenerationSourceMessageID == nil
    }

    /// A failed covered favorite must become a normal browsable conversation,
    /// never a request-owned partial window that waits for unrelated UI input.
    @discardableResult
    private func failOpenCoveredFavoriteTargetNavigation(
        _ targetRequest: MessageTargetNavigationRequest,
        reason: String
    ) -> Bool {
        guard isCoveredFavoriteTargetRequest(targetRequest) else { return false }

        if let action = navigationRequest?.action,
           case let .message(messageID) = action,
           messageID == targetRequest.messageID {
            navigationScrollTask?.cancel()
            navigationScrollTask = nil
            navigationRequest = nil
        }
        if let action = pendingNavigationRequest?.action,
           case let .message(messageID) = action,
           messageID == targetRequest.messageID {
            cancelPendingMessageNavigation()
        }
        nativeReleasedMessageTargetRequestID = nil
        concreteFavoriteTargetMessageID = nil
        landedMessageTargetID = nil
        model.consumeMessageTargetNavigationRequest(targetRequest.id)
        regenerationViewportTransitionCoordinator.reveal(
            requestID: targetRequest.id,
            reason: "favoriteTargetFailed"
        )
        ChatBottomTrace.log(
            "FAVORITE_TARGET_OWNERSHIP_RELEASED"
                + " outcome=failure"
                + " reason=\(reason)"
                + " request=\(ChatBottomTrace.shortID(targetRequest.id))"
                + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                + chatBottomTraceState
        )
        return true
    }

    private func isMessageTargetAttemptInFlight(
        _ targetRequest: MessageTargetNavigationRequest
    ) -> Bool {
        func matches(_ request: MessageNavigationRequest?) -> Bool {
            guard let request,
                  request.positionRequest.conversationID
                    == targetRequest.conversationID,
                  request.positionRequest.request
                    == targetRequest.conversationPositionRequest,
                  case let .message(messageID) = request.action else {
                return false
            }
            return messageID == targetRequest.messageID
        }
        return matches(navigationRequest) || matches(pendingNavigationRequest)
    }

    private func acknowledgeMessageTargetPositionRelease(
        _ anchorID: ConversationBottomAnchorID,
        _ requestID: UUID
    ) {
        guard let targetRequest = selectedMessageTargetNavigationRequest,
              targetRequest.id == requestID,
              anchorID.positionRequest == currentConversationPositionRequest else {
            return
        }
        nativeReleasedMessageTargetRequestID = requestID
        ChatBottomTrace.log(
            "MESSAGE_TARGET_BOTTOM_POSITION_RELEASED"
                + " request=\(ChatBottomTrace.shortID(requestID))"
                + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                + chatBottomTraceState
        )
    }

    private func acknowledgeEdgeNavigationPositionRelease(
        _ anchorID: ConversationBottomAnchorID,
        _ releaseID: EdgeNavigationNativeReleaseID,
        using scrollProxy: ScrollViewProxy
    ) {
        guard anchorID == releaseID.sourceAnchorID,
              currentConversationBottomAnchorID == releaseID.sourceAnchorID,
              currentConversationPositionRequest == releaseID.positionRequest,
              navigationScrollTask == nil,
              let request = navigationRequest,
              request.sequence == releaseID.sequence,
              request.positionRequest == releaseID.positionRequest else {
            return
        }
        ChatBottomTrace.log(
            "EDGE_NAVIGATION_POSITION_RELEASED"
                + " sequence=\(releaseID.sequence)"
                + " action=\(request.action) "
                + chatBottomTraceState
        )
        switch request.action {
        case .top:
            scrollToTop(using: scrollProxy, request: request)
        case .bottom:
            scrollToBottom(using: scrollProxy, request: request)
        default:
            return
        }
    }

    private func acknowledgeSendPositionRelease(
        _ anchorID: ConversationBottomAnchorID,
        _ releaseID: SendPositionNativeReleaseID,
        using scrollProxy: ScrollViewProxy
    ) {
        guard sendPositionNativeReleaseRequest == releaseID,
              anchorID == releaseID.sourceAnchorID,
              currentConversationBottomAnchorID == releaseID.sourceAnchorID,
              let request = model.pendingUserMessageSendPositionRequest,
              request.id == releaseID.requestID,
              request.conversationID == model.selectedConversationID else {
            return
        }
        acknowledgedSendPositionNativeRelease = releaseID
        ChatBottomTrace.log(
            "SEND_POSITION_NATIVE_RELEASED"
                + " request=\(ChatBottomTrace.shortID(releaseID.requestID)) "
                + chatBottomTraceState
        )
        scheduleUserMessageSendPositioning(request, using: scrollProxy)
    }

    private func cancelMessageTargetNavigationForUserInteraction() {
        regenerationViewportTransitionCoordinator.cancelAll(
            reason: "userInteraction"
        )
        landedMessageTargetID = nil
        concreteFavoriteTargetMessageID = nil
        messageTargetNavigationTask?.cancel()
        messageTargetNavigationTask = nil
        messageTargetCoordinatorRequestID = nil
        nativeReleasedMessageTargetRequestID = nil
        if let action = navigationRequest?.action,
           case .message = action {
            navigationScrollTask?.cancel()
            navigationScrollTask = nil
            navigationRequest = nil
        }
        if let action = pendingNavigationRequest?.action,
           case .message = action {
            cancelPendingMessageNavigation()
        }
        guard let targetRequest = selectedMessageTargetNavigationRequest else {
            return
        }
        model.consumeMessageTargetNavigationRequest(targetRequest.id)
        ChatBottomTrace.log(
            "MESSAGE_TARGET_CANCEL reason=userInteraction"
                + " request=\(ChatBottomTrace.shortID(targetRequest.id))"
                + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                + chatBottomTraceState
        )
    }

    private func requestMessageNavigation(_ action: MessageNavigationAction) {
        cancelMessageReplacementLanding()
        guard !model.isDrawerPresented,
              DrawerInlineActionTapGate.allowsAction else { return }
        let positionRequest = currentConversationPositionRequest
        if action == .bottom {
            // Resume while the live tail is still below the viewport. The
            // established bottom-navigation owner then measures and lands on
            // the caught-up height without competing scroll writes.
            releaseOffscreenStreamingDisplayLease(
                reason: "bottomNavigation"
            )
        }
        if action == .top || action == .bottom {
            let activeIsSameEdge = navigationRequest.map {
                $0.positionRequest == positionRequest && $0.action == action
            } ?? false
            let pendingIsSameEdge = pendingNavigationRequest.map {
                $0.positionRequest == positionRequest && $0.action == action
            } ?? false
            guard !activeIsSameEdge, !pendingIsSameEdge else {
                keepNavigationVisibleBriefly()
                return
            }
        }
        cancelCodeDisclosure(reason: "navigation")
        cancelAutomaticReasoningCollapseOwner(reason: "navigation")
        if case .message = action {
            // The active favorite request owns this anchor until it is measured.
        } else {
            cancelMessageTargetNavigationForUserInteraction()
        }
        invalidateVersionReplacement(reason: "navigation")
        navigationScrollTask?.cancel()
        navigationScrollTask = nil
        navigationRequest = nil
        navigationRequestSequence &+= 1
        let request = MessageNavigationRequest(
            sequence: navigationRequestSequence,
            positionRequest: positionRequest,
            action: action
        )
        if action == .top || action == .bottom {
            // Direct edge navigation owns every writer from acceptance through
            // native semantic-position release and final landing.
            prepareMessageNavigation(for: action)
        }

        let scrollView = chatScrollViewBox.scrollView
        reconcileSwiftUIGestureWithNativeTouchStateIfNeeded(scrollView)
        let navigationTouchIsActive = navigationScrollHasActiveTouch(scrollView)
        let nativeScrollIsDragging = scrollView?.isDragging ?? false
        let nativeScrollIsDecelerating = scrollView?.isDecelerating ?? false
        let nativeScrollIsAnimating = isNativeScrollAnimating(scrollView)
        let shouldArmUserScrollMotion = navigationTouchIsActive
            || nativeScrollIsDragging
            || nativeScrollIsDecelerating
        let mustAwaitNativeIdle = shouldArmUserScrollMotion
            || nativeScrollIsAnimating
        ChatBottomTrace.log(
            "NAVIGATION_REQUEST action=\(action) waitForIdle=\(mustAwaitNativeIdle)"
                + " armUserMotion=\(shouldArmUserScrollMotion)"
                + " tracking=\(scrollView?.isTracking ?? false)"
                + " dragging=\(nativeScrollIsDragging)"
                + " decelerating=\(nativeScrollIsDecelerating)"
                + " animating=\(nativeScrollIsAnimating) "
                + " pan=\(String(describing: scrollView?.panGestureRecognizer.state)) "
                + " touches=\(scrollView?.panGestureRecognizer.numberOfTouches ?? 0) "
                + chatBottomTraceState
        )
        if mustAwaitNativeIdle {
            // Concrete touch ownership and UIKit deceleration belong to the old
            // user motion. Keep only the newest command and publish it after
            // those states remain idle across main-queue turns. Do not gate on
            // SwiftUI's generic phase: it can stay stale at `.animating` after
            // the concrete scroll view has already stopped.
            pendingNavigationPromotionTask?.cancel()
            pendingNavigationPromotionTask = nil
            pendingNavigationRequest = request
            // A concrete user gesture/deceleration owns the existing user-motion
            // lease. A programmatic animation alone must be stopped and awaited,
            // but must not make its idle callback look like the end of a user drag.
            isNativeVerticalScrollMotionArmed = shouldArmUserScrollMotion
            // An accepted command stays visible while the old motion settles;
            // do not let the 1.1-second idle timer discard it.
            updateNavigationVisibility(isScrolling: true)
            schedulePendingMessageNavigationPromotion()
            if !navigationTouchIsActive {
                // A tap during finger-free momentum should stop that momentum on
                // the first tap, but the jump itself is promoted asynchronously.
                interruptNativeScrollMotion()
            }
            return
        }

        cancelPendingMessageNavigation()
        // The idle callback caused by stopping old momentum belongs to the old
        // user motion, not to the new explicit command.
        isNativeVerticalScrollMotionArmed = false
        interruptNativeScrollMotion()
        navigationRequest = request
    }

    private func cancelPendingMessageNavigation() {
        pendingNavigationPromotionTask?.cancel()
        pendingNavigationPromotionTask = nil
        pendingNavigationRequest = nil
    }

    private func cancelMessageNavigationForUserInteraction(reason: String) {
        guard navigationRequest != nil || pendingNavigationRequest != nil
                || navigationScrollTask != nil else { return }
        ChatBottomTrace.log("NAVIGATION_INTERRUPTED reason=\(reason) " + chatBottomTraceState)
        navigationScrollTask?.cancel()
        navigationScrollTask = nil
        navigationRequest = nil
        cancelPendingMessageNavigation()
        navigationAnchorMessageID = nil
        // The cancelled task's defer no longer owns this request. Detach here
        // before stopping UIKit motion, so its idle callback cannot re-arm follow.
        lastKnownNearBottom = false
        lastMeasuredNearBottom = false
        lastMeasuredAtBottom = false
        isUserScrollActive = true
        autoFollowEngaged = false
        keyboardBottomFollowIntent = false
        isNativeVerticalScrollMotionArmed = false
        interruptNativeScrollMotion()
    }

    private func interruptEdgeNavigationForNativeTouch(
        _ anchorID: ConversationBottomAnchorID,
        sequence: Int
    ) -> Bool {
        guard anchorID.positionRequest == currentConversationPositionRequest,
              currentEdgeNavigationSequence == sequence else { return false }
        cancelMessageNavigationForUserInteraction(reason: "nativeTouch")
        return true
    }

    private func schedulePendingMessageNavigationPromotion() {
        guard let request = pendingNavigationRequest else { return }
        pendingNavigationPromotionTask?.cancel()
        pendingNavigationPromotionTask = Task { @MainActor in
            // Start watching at enqueue time, including the iOS 17 window where
            // UIKit is tracking but SwiftUI never recognizes a DragGesture. Poll
            // rapidly at first, then cheaply until the finger is actually released.
            var delay = 0
            var consecutiveConcreteIdlePasses = 0
            var didRequestMomentumStop = false
            var concreteMotionWaitStartedAt: TimeInterval?
            var shouldForcePromotion = false
            while true {
                if delay == 0 {
                    await awaitNextMainQueueTurn()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                // A replacement watcher for the same request may cancel this one.
                // A canceled task must never clear the replacement's state.
                guard !Task.isCancelled else { return }
                guard pendingNavigationRequest == request,
                      navigationRequestSequence == request.sequence,
                      currentConversationPositionRequest == request.positionRequest,
                      !model.isDrawerPresented,
                      DrawerInlineActionTapGate.allowsAction else {
                    if pendingNavigationRequest == request {
                        pendingNavigationRequest = nil
                        pendingNavigationPromotionTask = nil
                    }
                    return
                }
                let scrollView = chatScrollViewBox.scrollView
                reconcileSwiftUIGestureWithNativeTouchStateIfNeeded(scrollView)
                let navigationTouchIsActive = navigationScrollHasActiveTouch(scrollView)
                if navigationTouchIsActive {
                    consecutiveConcreteIdlePasses = 0
                    concreteMotionWaitStartedAt = nil
                    shouldForcePromotion = false
                    // A fresh touch begins a new momentum generation. If that
                    // touch later releases into deceleration, it needs its own
                    // one-shot stop before the remembered command can run.
                    didRequestMomentumStop = false
                    delay = min(max(delay * 2, 8), 80)
                    continue
                }
                let now = ProcessInfo.processInfo.systemUptime
                if concreteMotionWaitStartedAt == nil {
                    concreteMotionWaitStartedAt = now
                }
                let nativeScrollIsDragging = scrollView?.isDragging ?? false
                let nativeScrollIsDecelerating = scrollView?.isDecelerating ?? false
                let nativeScrollIsAnimating = isNativeScrollAnimating(scrollView)
                if (nativeScrollIsDragging
                    || nativeScrollIsDecelerating
                    || nativeScrollIsAnimating),
                   !shouldForcePromotion {
                    consecutiveConcreteIdlePasses = 0
                    if !didRequestMomentumStop {
                        didRequestMomentumStop = true
                        ChatBottomTrace.log(
                            "NAVIGATION_PENDING_INTERRUPT action=\(request.action) "
                                + chatBottomTraceState
                        )
                        interruptNativeScrollMotion()
                    }
                    let waitDuration = now - (concreteMotionWaitStartedAt ?? now)
                    if waitDuration < 1.5 {
                        // Re-enter later so the UIKit stop and any resulting
                        // SwiftUI phase callback can settle first.
                        delay = min(max(delay * 2, 8), 80)
                        continue
                    }
                    // Concrete UIKit flags should clear after the public stop API.
                    // If a system transition leaves them stale, the explicit tap
                    // still wins after one bounded final stop instead of remaining
                    // queued forever.
                    shouldForcePromotion = true
                    ChatBottomTrace.log(
                        "NAVIGATION_PENDING_FORCE_PROMOTE action=\(request.action)"
                            + " dragging=\(nativeScrollIsDragging)"
                            + " decelerating=\(nativeScrollIsDecelerating)"
                            + " animating=\(nativeScrollIsAnimating) "
                            + chatBottomTraceState
                    )
                    interruptNativeScrollMotion()
                }

                // Two real main-queue turns with no concrete touch or motion close
                // the synchronous-stop race without a normal-path fixed delay. A
                // stale generic SwiftUI `.animating` phase cannot deadlock the
                // accepted navigation command.
                consecutiveConcreteIdlePasses += 1
                guard consecutiveConcreteIdlePasses >= 2 else {
                    delay = 0
                    continue
                }

                pendingNavigationRequest = nil
                pendingNavigationPromotionTask = nil
                isNativeVerticalScrollMotionArmed = false
                ChatBottomTrace.log(
                    "NAVIGATION_PENDING_PROMOTE action=\(request.action) "
                        + chatBottomTraceState
                )
                navigationRequest = request
                return
            }
        }
    }

    private func reconcileSwiftUIGestureWithNativeTouchStateIfNeeded(
        _ scrollView: UIScrollView?
    ) {
        guard let scrollView,
              isVerticalScrollGestureActive,
              !nativeScrollHasActiveTouch(scrollView) else { return }
        scrollDragIsVertical = nil
        isVerticalScrollGestureActive = false
        ChatBottomTrace.log(
            "SWIFTUI_DRAG_RECONCILE reason=nativeTouchEnded"
                + " tracking=\(scrollView.isTracking)"
                + " dragging=\(scrollView.isDragging)"
                + " decelerating=\(scrollView.isDecelerating)"
                + " pan=\(String(describing: scrollView.panGestureRecognizer.state))"
                + " touches=\(scrollView.panGestureRecognizer.numberOfTouches) "
                + chatBottomTraceState
        )
    }

    private func navigationScrollHasActiveTouch(_ scrollView: UIScrollView?) -> Bool {
        guard let scrollView else { return isVerticalScrollGestureActive }
        return nativeScrollHasActiveTouch(scrollView)
    }

    private func nativeScrollHasActiveTouch(_ scrollView: UIScrollView?) -> Bool {
        guard let scrollView else { return false }
        if scrollView.isTracking
            || scrollView.panGestureRecognizer.numberOfTouches > 0 {
            return true
        }
        switch scrollView.panGestureRecognizer.state {
        case .began, .changed:
            return true
        default:
            return false
        }
    }

    private func isNativeScrollAnimating(_ scrollView: UIScrollView?) -> Bool {
        guard let scrollView else { return false }
        if #available(iOS 17.4, *) {
            return scrollView.isScrollAnimating
        }
        return false
    }

    private func awaitNextMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func interruptNativeScrollMotion() {
        guard let scrollView = chatScrollViewBox.scrollView else {
            ChatBottomTrace.log(
                "NATIVE_SCROLL_INTERRUPT_DROP reason=noScrollView " + chatBottomTraceState
            )
            return
        }
        guard !nativeScrollHasActiveTouch(scrollView) else {
            ChatBottomTrace.log(
                "NATIVE_SCROLL_INTERRUPT_DROP reason=activeTouch"
                    + " tracking=\(scrollView.isTracking)"
                    + " dragging=\(scrollView.isDragging)"
                    + " decelerating=\(scrollView.isDecelerating)"
                    + " pan=\(String(describing: scrollView.panGestureRecognizer.state)) "
                    + " touches=\(scrollView.panGestureRecognizer.numberOfTouches) "
                    + chatBottomTraceState
            )
            return
        }
        ChatBottomTrace.log(
            "NATIVE_SCROLL_INTERRUPT"
                + " tracking=\(scrollView.isTracking)"
                + " dragging=\(scrollView.isDragging)"
                + " decelerating=\(scrollView.isDecelerating)"
                + " pan=\(String(describing: scrollView.panGestureRecognizer.state)) "
                + " touches=\(scrollView.panGestureRecognizer.numberOfTouches) "
                + chatBottomTraceState
        )
        if #available(iOS 17.4, *) {
            scrollView.stopScrollingAndZooming()
        } else if scrollView.isDecelerating {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
    }

    private var measuredComposer: some View {
        ComposerView()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                updateComposerHeight(height)
            }
    }

    private func updateComposerHeight(_ height: CGFloat) {
        guard height > 0,
              abs(composerHeight - height) > 0.5 else { return }
        let previousHeight = composerHeight
        composerHeight = height
        ChatBottomTrace.log(
            "COMPOSER_HEIGHT old=\(String(format: "%.1f", previousHeight))"
                + " new=\(String(format: "%.1f", height)) "
                + chatBottomTraceState
        )
        requestLayoutFollowCorrection(requiresNearBottom: false)
    }

    private var composerBottomClearance: CGFloat {
        max(110, composerHeight + 12)
    }

    private func activeBottomNavigationTailClearance(
        for anchorID: ConversationBottomAnchorID
    ) -> CGFloat {
        guard let request = navigationRequest,
              request.action == .bottom,
              request.positionRequest == anchorID.positionRequest,
              anchorID == currentConversationBottomAnchorID,
              !model.hasLaterMessages,
              !model.isCompressingContext,
              model.selectedLogicalTruncateIndex != model.messages.count,
              let tailMessage = model.messages.last,
              tailMessage.id == anchorID.messageIDs.last,
              !tailMessage.isStreaming else { return 0 }
        // Leave one concrete point on the existing revision-scoped sentinel;
        // the remainder becomes part of the real lazy target for the complete
        // lifetime of the already-existing navigation request.
        return max(0, composerBottomClearance - 1)
    }

    private var floatingHeaderClearance: CGFloat {
        8 + 50 + 14
    }

    private var topContentSpacerHeight: CGFloat {
        if #available(iOS 26.0, *) {
            let compactEffectHeight = min(topSafeAreaInset, 48)
            return 8 + 50 + max(0, topSafeAreaInset - compactEffectHeight)
        }
        return floatingHeaderClearance
    }

    private var conversationContentMinimumHeight: CGFloat {
        let viewportHeight = max(0, scrollViewportHeight)
        if #available(iOS 26.0, *), isFreshConversationFirstMessage {
            return max(0, viewportHeight - min(topSafeAreaInset, 48))
        }
        return viewportHeight
    }

    private var messageListTopPadding: CGFloat {
        22
    }

    private var conversationMessageSpacing: CGFloat {
        30
    }

    private func requestRegeneration(for message: ChatMessage) {
        cancelCodeDisclosure(reason: "regeneration")
        dismissKeyboard()
        model.performCardHaptic()
        guard !model.isConversationStreaming(message.conversationID) else { return }
        if !model.isComposerFocused,
           !isComposerKeyboardPresented,
           !isKeyboardDismissalTransition {
            regenerationViewportTransitionCoordinator.prepare(
                from: chatScrollViewBox.scrollView
            )
        }
        if model.preferences.showRegenerateConfirmDialog {
            regenerationConfirmationMessage = message
        } else {
            beginRegeneration(for: message)
        }
    }

    private func beginRegeneration(for message: ChatMessage) {
        guard let userMessageID = model.regenerationUserMessageID(
            around: message.id
        ) else {
            regenerationViewportTransitionCoordinator.discardPrepared(
                reason: "missingUserTarget"
            )
            return
        }
        let transitionToken =
            regenerationViewportTransitionCoordinator.activatePrepared()
        guard model.selectConversation(
            message.conversationID,
            targeting: userMessageID,
            regenerationSourceMessageID: message.id,
            closeDrawer: false
        ) else {
            if transitionToken != nil {
                regenerationViewportTransitionCoordinator.cancelAll(
                    reason: "selectionRejected"
                )
            }
            return
        }
        if let transitionToken,
           let targetRequest = model.pendingMessageTargetNavigationRequest,
           targetRequest.conversationID == message.conversationID,
           targetRequest.messageID == userMessageID,
           targetRequest.regenerationSourceMessageID == message.id {
            regenerationViewportTransitionCoordinator.bind(
                transitionToken,
                to: targetRequest.id
            )
        } else if transitionToken != nil {
            regenerationViewportTransitionCoordinator.cancelAll(
                reason: "requestBindingFailed"
            )
        }
    }

    private enum MessageWindowLoadDirection {
        case earlier
        case later
    }

    private var isPositioningCurrentConversation: Bool {
        guard !model.messages.isEmpty else { return false }
        return positioningConversationID == model.selectedConversationID
            || model.conversationBottomReturnTargetID == model.selectedConversationID
    }

    private var isOrdinaryConversationReturn: Bool {
        guard positioningConversationID == model.selectedConversationID
                || model.conversationBottomReturnTargetID == model.selectedConversationID
        else { return false }
        return !model.selectedConversationIsStreaming
            && !model.isComposerFocused
            && !isComposerKeyboardPresented
            && pendingKeyboardViewportPin == nil
            && !hasActiveKeyboardDismissalWork
            && !isVersionReplacementInProgress
    }

    private var isFreshConversationFirstMessage: Bool {
        newConversationFirstMessageID == model.selectedConversationID
    }

    private func isFreshConversationInitialSend(
        _ request: UserMessageSendPositionRequest
    ) -> Bool {
        guard isFreshConversationFirstMessage else { return false }
        return model.messages.first(where: { $0.role == .user })?.id == request.messageID
    }

    private var isFreshConversationFollowSuppressed: Bool {
        newConversationFollowSuppressionID == model.selectedConversationID
    }

    private var isUserMessageSendPositioning: Bool {
        activeUserMessageSendPositionRequestID != nil
            || model.pendingUserMessageSendPositionRequest?.conversationID == model.selectedConversationID
    }

    private var selectedMessageTargetNavigationRequest:
        MessageTargetNavigationRequest? {
        guard let request = model.pendingMessageTargetNavigationRequest,
              request.conversationID == model.selectedConversationID,
              request.conversationPositionRequest
                == model.conversationBottomReturnRequest else {
            return nil
        }
        return request
    }

    private var isMessageTargetNavigationActive: Bool {
        if selectedMessageTargetNavigationRequest != nil {
            return true
        }
        if let pendingNavigationRequest,
           case .message = pendingNavigationRequest.action {
            return true
        }
        if let navigationRequest,
           case .message = navigationRequest.action {
            return true
        }
        return false
    }

    private var isMessageTargetNavigationOwned: Bool {
        isMessageTargetNavigationActive || landedMessageTargetID != nil
    }

    private var ownsCurrentDoubleEdgeNavigation: Bool {
        let positionRequest = currentConversationPositionRequest
        func owns(_ request: MessageNavigationRequest?) -> Bool {
            guard let request,
                  request.positionRequest == positionRequest else { return false }
            return request.action == .top || request.action == .bottom
        }
        return owns(navigationRequest) || owns(pendingNavigationRequest)
    }

    private var currentEdgeNavigationNativeReleaseID:
        EdgeNavigationNativeReleaseID? {
        guard navigationScrollTask == nil,
              let request = navigationRequest,
              request.positionRequest == currentConversationPositionRequest,
              request.action == .top || request.action == .bottom else {
            return nil
        }
        return EdgeNavigationNativeReleaseID(
            sequence: request.sequence,
            positionRequest: request.positionRequest,
            sourceAnchorID: currentConversationBottomAnchorID
        )
    }

    private var currentEdgeNavigationSequence: Int? {
        guard let request = navigationRequest,
              request.positionRequest == currentConversationPositionRequest,
              request.action == .top || request.action == .bottom else { return nil }
        return request.sequence
    }

    private var hasCurrentConcreteLatestBottomContent: Bool {
        let anchorID = currentConversationBottomAnchorID
        return !model.hasLaterMessages
            && nativeConversationContentReadyAnchorID == anchorID
            && hasConcreteTailFrame(for: anchorID)
    }

    private var hasConcreteNativeUserScrollOwnership: Bool {
        guard let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil else { return false }
        return nativeScrollHasActiveTouch(scrollView)
            || scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
    }

    private var shouldKeepNativeBottomPosition: Bool {
        guard messageReplacementRequest == nil else { return false }
        guard !model.messages.isEmpty else { return false }
        guard !hasConcreteNativeUserScrollOwnership else { return false }
        // A historical window's local bottom is not the semantic end of the
        // conversation. Never let it re-arm a retained native `.bottom` edge.
        guard !model.hasLaterMessages else { return false }
        // A newly created conversation intentionally grows from the header.
        // Once it is left and opened again it follows the normal bottom rule.
        if isFreshConversationFollowSuppressed {
            return false
        }
        // Sending owns a concrete-row handoff. Native edge pinning is withheld
        // until that real row and the current concrete tail both acknowledge;
        // otherwise the cheap LazyVStack sentinel can move to an empty offset.
        if isUserMessageSendPositioning {
            return false
        }
        // A favorite owns a concrete message row. Keep the iOS 18 semantic
        // bottom ScrollPosition from re-engaging while that exact target is
        // materialized, animated, and corrected from measured geometry.
        if isMessageTargetNavigationOwned {
            return false
        }
        if ownsCurrentDoubleEdgeNavigation {
            return false
        }
        if isPositioningCurrentConversation {
            return true
        }
        return model.preferences.autoScrollEnabled
            && autoFollowEngaged
            && !isUserScrollActive
    }

    private var shouldPauseStreamingFollowOnNativeTouch: Bool {
        model.selectedConversationIsStreaming
            && model.preferences.autoScrollEnabled
            && autoFollowEngaged
            && !isUserScrollActive
            && !isFreshConversationFollowSuppressed
            && !isUserMessageSendPositioning
            && !isMessageTargetNavigationOwned
            && !ownsCurrentDoubleEdgeNavigation
            && !isPositioningCurrentConversation
            && automaticReasoningCollapseOwner == nil
            && pendingBottomRowMaterializationAnchorID == nil
            && !model.hasLaterMessages
    }

    private func updateManualStreamingReasoningCollapse(
        messageID: UUID,
        segmentID: UUID,
        isCollapsed: Bool
    ) {
        let anchorID = currentConversationBottomAnchorID
        let key = ManualStreamingReasoningCollapseKey(
            anchorID: anchorID,
            tailMessageID: messageID,
            segmentID: segmentID
        )
        guard anchorID.messageIDs.last == messageID,
              model.messages.last?.reasoningSegments.last?.id == segmentID else {
            if !isCollapsed,
               manualStreamingReasoningCollapseSuppression == key {
                manualStreamingReasoningCollapseSuppression = nil
            }
            return
        }

        if isCollapsed {
            manualStreamingReasoningCollapseSuppression = key
            clearAutomaticReasoningCollapseAuthorization(
                reason: "manualStreamingCollapse"
            )
            if automaticReasoningCollapseOwner?.identity.tailMessageID
                    == messageID,
               automaticReasoningCollapseOwner?.identity.segmentID
                    == segmentID {
                cancelAutomaticReasoningCollapseOwner(
                    reason: "manualStreamingCollapse"
                )
            }
        } else if manualStreamingReasoningCollapseSuppression == key {
            manualStreamingReasoningCollapseSuppression = nil
        }
        ChatBottomTrace.log(
            "REASONING_MANUAL_STREAMING_COLLAPSE"
                + " tail=\(ChatBottomTrace.shortID(messageID))"
                + " segment=\(ChatBottomTrace.shortID(segmentID))"
                + " collapsed=\(isCollapsed) "
                + chatBottomTraceState
        )
    }

    private func updateAutomaticReasoningCollapseAuthorization(
        from previous: AutomaticReasoningCollapseObservation?,
        to current: AutomaticReasoningCollapseObservation?
    ) {
        if let suppressed = manualStreamingReasoningCollapseSuppression,
           let current,
           current.anchorID != suppressed.anchorID
            || current.tailMessageID != suppressed.tailMessageID
            || current.segmentID != suppressed.segmentID {
            manualStreamingReasoningCollapseSuppression = nil
        }

        if let owner = automaticReasoningCollapseOwner {
            let stillMatchesOwner = current.map {
                $0.anchorID == owner.identity.anchorID
                    && $0.tailMessageID == owner.identity.tailMessageID
                    && $0.segmentID == owner.identity.segmentID
                    && $0.finishedAt == owner.identity.finishedAt
                    && $0.autoCollapseEnabled
                    && !$0.isExpanded
                    && $0.hasVisibleText
            } ?? false
            if !stillMatchesOwner {
                cancelAutomaticReasoningCollapseOwner(
                    reason: "collapseIdentityChanged"
                )
            }
        }

        let isStableAutomaticFinishTransition: Bool
        if let previous, let current {
            isStableAutomaticFinishTransition =
                previous.anchorID == current.anchorID
                && previous.tailMessageID == current.tailMessageID
                && previous.segmentID == current.segmentID
                && previous.finishedAt == nil
                && current.finishedAt != nil
                && previous.isStreaming
                && previous.autoCollapseEnabled
                && current.autoCollapseEnabled
                && previous.isExpanded
                && !previous.hasVisibleText
                && !current.isExpanded
                && current.hasVisibleText
        } else {
            isStableAutomaticFinishTransition = false
        }

        if automaticReasoningCollapseOwner == nil,
           let checkpoint = automaticReasoningExpandedCheckpoint,
           let authorization = makeAutomaticReasoningCollapseAuthorization(
                for: current,
                checkpoint: checkpoint
           ) {
            let source = isStableAutomaticFinishTransition
                ? "stableTransition"
                : "checkpointRecovery"
            if automaticReasoningCollapseAuthorization != authorization {
                installAutomaticReasoningCollapseAuthorization(
                    authorization,
                    source: source,
                    currentStreaming: current?.isStreaming ?? false
                )
            }
            return
        }

        if isStableAutomaticFinishTransition {
            clearAutomaticReasoningCollapseAuthorization(
                reason: "checkpointUnavailable"
            )
            ChatBottomTrace.log(
                "REASONING_COLLAPSE_AUTHORIZE_REJECT reason=checkpointUnavailable "
                    + chatBottomTraceState
            )
            return
        }

        if let authorization = automaticReasoningCollapseAuthorization {
            let stillMatchesAuthorization =
                makeAutomaticReasoningCollapseAuthorization(
                    for: current,
                    checkpoint: authorization.checkpoint
                ) == authorization
            if !stillMatchesAuthorization {
                clearAutomaticReasoningCollapseAuthorization(
                    reason: "collapseIdentityChanged"
                )
            }
        } else if automaticReasoningCollapseOwner == nil,
                  let checkpoint = automaticReasoningExpandedCheckpoint {
            let stillMatchesExpandedCheckpoint = current.map {
                $0.anchorID == checkpoint.anchorID
                    && $0.tailMessageID == checkpoint.tailMessageID
                    && $0.segmentID == checkpoint.segmentID
                    && $0.finishedAt == nil
                    && $0.isStreaming
                    && $0.autoCollapseEnabled
                    && $0.isExpanded
                    && !$0.hasVisibleText
            } ?? false
            if !stillMatchesExpandedCheckpoint {
                automaticReasoningExpandedCheckpoint = nil
            }
        }
    }

    private func makeAutomaticReasoningCollapseAuthorization(
        for observation: AutomaticReasoningCollapseObservation?,
        checkpoint: AutomaticReasoningExpandedCheckpoint
    ) -> AutomaticReasoningCollapseAuthorization? {
        guard let observation,
              checkpoint.anchorID == observation.anchorID,
              checkpoint.tailMessageID == observation.tailMessageID,
              checkpoint.segmentID == observation.segmentID,
              let finishedAt = observation.finishedAt,
              observation.autoCollapseEnabled,
              !observation.isExpanded,
              observation.hasVisibleText,
              manualStreamingReasoningCollapseSuppression
                != ManualStreamingReasoningCollapseKey(
                    anchorID: observation.anchorID,
                    tailMessageID: observation.tailMessageID,
                    segmentID: observation.segmentID
                ) else {
            return nil
        }
        return AutomaticReasoningCollapseAuthorization(
            identity: AutomaticReasoningCollapseIdentity(
                anchorID: observation.anchorID,
                tailMessageID: observation.tailMessageID,
                segmentID: observation.segmentID,
                finishedAt: finishedAt
            ),
            checkpoint: checkpoint
        )
    }

    private func installAutomaticReasoningCollapseAuthorization(
        _ authorization: AutomaticReasoningCollapseAuthorization,
        source: String,
        currentStreaming: Bool
    ) {
        automaticReasoningCollapseAuthorizationWatchdogTask?.cancel()
        automaticReasoningCollapseAuthorizationGeneration &+= 1
        let generation = automaticReasoningCollapseAuthorizationGeneration
        automaticReasoningCollapseAuthorization = authorization
        automaticReasoningCollapseAuthorizationSampleCount = 0
        automaticReasoningCollapseAuthorizationDeadline =
            Date().addingTimeInterval(0.7)
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_AUTHORIZE"
                + " source=\(source)"
                + " authorizationGeneration=\(generation)"
                + " tail=\(ChatBottomTrace.shortID(authorization.identity.tailMessageID))"
                + " segment=\(ChatBottomTrace.shortID(authorization.identity.segmentID))"
                + " currentStreaming=\(currentStreaming)"
                + " checkpointGeneration=\(authorization.checkpoint.frameGeneration)"
                + " checkpointHeight=\(String(format: "%.1f", authorization.checkpoint.frame.height)) "
                + chatBottomTraceState
        )
        automaticReasoningCollapseAuthorizationWatchdogTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            guard generation == automaticReasoningCollapseAuthorizationGeneration,
                  automaticReasoningCollapseAuthorization == authorization,
                  automaticReasoningCollapseOwner == nil else { return }
            let remainsAtExactBottom = currentUIKitBottomState?.isAtBottom == true
            clearAutomaticReasoningCollapseAuthorization(
                reason: remainsAtExactBottom
                    ? "pendingExpiredAlreadyAtBottom"
                    : "pendingExpiredFailClosed"
            )
            if !remainsAtExactBottom {
                autoFollowEngaged = false
            }
            ChatBottomTrace.log(
                "REASONING_COLLAPSE_PENDING_EXPIRE"
                    + " authorizationGeneration=\(generation)"
                    + " exactBottom=\(remainsAtExactBottom)"
                    + " autoFollow=\(autoFollowEngaged) "
                    + chatBottomTraceState
            )
        }
    }

    private func currentAutomaticReasoningCollapseObservation(
        for anchorID: ConversationBottomAnchorID
    ) -> AutomaticReasoningCollapseObservation? {
        guard currentConversationBottomAnchorID == anchorID,
              let tailMessageID = anchorID.messageIDs.last,
              let tailMessage = model.messages.last,
              tailMessage.id == tailMessageID,
              tailMessage.role == .assistant,
              let lastSegment = tailMessage.reasoningSegments.last else {
            return nil
        }
        let autoCollapseEnabled = model.preferences.autoCollapseThinking
        let isThinking = lastSegment.finishedAt == nil
            && tailMessage.isStreaming
        let isExpanded = !model.preferences.fullyCollapseThinking
            && (isThinking
                || (!autoCollapseEnabled && lastSegment.finishedAt != nil)
                || lastSegment.expanded)
        return AutomaticReasoningCollapseObservation(
            anchorID: anchorID,
            tailMessageID: tailMessage.id,
            segmentID: lastSegment.id,
            finishedAt: lastSegment.finishedAt,
            messageUpdatedAt: tailMessage.updatedAt,
            isStreaming: tailMessage.isStreaming,
            autoCollapseEnabled: autoCollapseEnabled,
            isExpanded: isExpanded,
            hasVisibleText: !tailMessage.text.isEmpty
        )
    }

    private func reduceAutomaticReasoningCollapseGeometry(
        _ change: AutomaticReasoningCollapseGeometryChange,
        claimSemanticOwner: (AutomaticReasoningCollapseOwnerID) -> Void
    ) -> AutomaticReasoningCollapseGeometryDisposition {
        if let owner = automaticReasoningCollapseOwner,
           owner.id.anchorID == change.anchorID {
            return .owned(owner.id)
        }

        let authorization: AutomaticReasoningCollapseAuthorization
        let authorizationSource: String
        if let queuedAuthorization = automaticReasoningCollapseAuthorization {
            authorization = queuedAuthorization
            authorizationSource = "observation"
        } else if let checkpoint = automaticReasoningExpandedCheckpoint,
                  let currentObservation =
                    currentAutomaticReasoningCollapseObservation(
                        for: change.anchorID
                    ),
                  let recoveredAuthorization =
                    makeAutomaticReasoningCollapseAuthorization(
                        for: currentObservation,
                        checkpoint: checkpoint
                    ) {
            authorization = recoveredAuthorization
            authorizationSource = "geometryRecovery"
            installAutomaticReasoningCollapseAuthorization(
                recoveredAuthorization,
                source: authorizationSource,
                currentStreaming: currentObservation.isStreaming
            )
            ChatBottomTrace.log(
                "REASONING_COLLAPSE_AUTHORIZE_RECOVERED"
                    + " source=geometry"
                    + " tail=\(ChatBottomTrace.shortID(recoveredAuthorization.identity.tailMessageID))"
                    + " segment=\(ChatBottomTrace.shortID(recoveredAuthorization.identity.segmentID))"
                    + " currentStreaming=\(currentObservation.isStreaming) "
                    + chatBottomTraceState
            )
        } else {
            return .unowned
        }

        let identity = authorization.identity
        let checkpoint = authorization.checkpoint
        let contentHeightDelta = change.contentHeight
            - change.previousContentHeight
        let cumulativeContentHeightDelta = change.contentHeight
            - checkpoint.contentHeight

        guard identity.anchorID == change.anchorID,
              checkpoint.anchorID == change.anchorID,
              checkpoint.tailMessageID == identity.tailMessageID,
              checkpoint.segmentID == identity.segmentID,
              manualStreamingReasoningCollapseSuppression
                != ManualStreamingReasoningCollapseKey(
                    anchorID: identity.anchorID,
                    tailMessageID: identity.tailMessageID,
                    segmentID: identity.segmentID
              ),
              currentConversationBottomAnchorID == change.anchorID,
              model.preferences.autoScrollEnabled,
              model.preferences.autoCollapseThinking,
              !model.hasLaterMessages,
              let tailMessageID = change.anchorID.messageIDs.last,
              identity.tailMessageID == tailMessageID,
              let tailMessage = model.messages.last,
              tailMessage.id == tailMessageID,
              tailMessage.role == .assistant,
              !tailMessage.text.isEmpty,
              let lastSegment = tailMessage.reasoningSegments.last,
              lastSegment.id == identity.segmentID,
              lastSegment.finishedAt == identity.finishedAt,
              !lastSegment.expanded else {
            return consumeAutomaticReasoningCollapseAuthorization(
                reason: "identity",
                source: authorizationSource,
                contentHeightDelta: contentHeightDelta,
                cumulativeContentHeightDelta: cumulativeContentHeightDelta
            )
        }

        guard shouldKeepNativeBottomPosition,
              autoFollowEngaged,
              !change.positionWasUserOwned,
              !isUserScrollActive,
              !isVerticalScrollGestureActive,
              !isNativeVerticalScrollMotionArmed,
              let scrollView = chatScrollViewBox.scrollView,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating else {
            return consumeAutomaticReasoningCollapseAuthorization(
                reason: "userOwnership",
                source: authorizationSource,
                contentHeightDelta: contentHeightDelta,
                cumulativeContentHeightDelta: cumulativeContentHeightDelta
            )
        }

        guard !isFreshConversationFollowSuppressed,
              !model.isCompressingContext,
              !model.isDrawerPresented,
              !isConversationDrawerClosePending(
                change.anchorID.positionRequest.conversationID
              ),
              !isPositioningCurrentConversation,
              conversationReturnTask == nil,
              pendingBottomRowMaterializationAnchorID == nil,
              bottomRowMaterializationTask == nil,
              !isUserMessageSendPositioning,
              !isVersionReplacementInProgress,
              navigationRequest == nil,
              pendingNavigationRequest == nil,
              navigationScrollTask == nil,
              messageTargetNavigationTask == nil,
              !isMessageTargetNavigationOwned,
              pendingKeyboardViewportPin == nil,
              keyboardViewportPinTask == nil,
              keyboardNativeSettleTask == nil,
              pendingKeyboardDismissalDeadline == nil,
              !isKeyboardDismissalTransition,
              !isKeyboardDismissalGeometryRecoveryActive,
              keyboardDismissalViewportPinRequest == nil,
              messageWindowLoadTask == nil,
              !isCodeDisclosureInProgress else {
            return consumeAutomaticReasoningCollapseAuthorization(
                reason: "competingOwner",
                source: authorizationSource,
                contentHeightDelta: contentHeightDelta,
                cumulativeContentHeightDelta: cumulativeContentHeightDelta
            )
        }

        guard change.previousContentHeight.isFinite,
              change.contentHeight.isFinite,
              change.previousContainerHeight.isFinite,
              change.containerHeight.isFinite,
              change.signedDistanceFromBottom.isFinite,
              abs(change.previousContainerHeight - change.containerHeight) <= 1,
              checkpoint.frame.minX.isFinite,
              checkpoint.frame.minY.isFinite,
              checkpoint.frame.width.isFinite,
              checkpoint.frame.height.isFinite,
              checkpoint.contentHeight.isFinite,
              checkpoint.contentOffsetY.isFinite,
              checkpoint.minimumOffsetY.isFinite,
              checkpoint.adjustedContentInsetBottom.isFinite,
              scrollViewportHeight > 0,
              checkpoint.frame.maxY > 0,
              checkpoint.frame.minY < scrollViewportHeight,
              ObjectIdentifier(scrollView) == checkpoint.scrollViewIdentity,
              scrollView.window != nil,
              scrollView.bounds.height > 0,
              scrollView.contentSize.height.isFinite,
              scrollView.contentOffset.x.isFinite,
              scrollView.contentOffset.y.isFinite,
              abs(
                -scrollView.adjustedContentInset.top
                    - checkpoint.minimumOffsetY
              ) <= 1,
              abs(
                scrollView.adjustedContentInset.bottom
                    - checkpoint.adjustedContentInsetBottom
              ) <= 1 else {
            return consumeAutomaticReasoningCollapseAuthorization(
                reason: "containerGeometry",
                source: authorizationSource,
                contentHeightDelta: contentHeightDelta,
                cumulativeContentHeightDelta: cumulativeContentHeightDelta
            )
        }

        let predictedTailHeight = checkpoint.frame.height
            + cumulativeContentHeightDelta
        let predictedTailMaxY = checkpoint.frame.maxY
            + cumulativeContentHeightDelta
        let currentOffset = scrollView.contentOffset
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let targetOffsetY = max(
            minimumOffsetY,
            change.contentHeight - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let expandedBottomOffsetY = max(
            minimumOffsetY,
            checkpoint.contentHeight - scrollView.bounds.height
                + checkpoint.adjustedContentInsetBottom
        )
        let reconstructedTargetOffsetY = currentOffset.y
            + change.signedDistanceFromBottom
        let currentContentHeight = scrollView.contentSize.height
        let expectedContentHeightLowerBound = min(
            change.contentHeight,
            checkpoint.contentHeight
        ) - 8
        let expectedContentHeightUpperBound = max(
            change.contentHeight,
            checkpoint.contentHeight
        ) + 8

        if currentUIKitBottomState?.isAtBottom == true,
           abs(change.signedDistanceFromBottom) <= 2 {
            clearAutomaticReasoningCollapseAuthorization(
                reason: "collapseSettledAtExactBottom"
            )
            ChatBottomTrace.log(
                "REASONING_COLLAPSE_GEOMETRY disposition=consumedUnowned"
                    + " reason=alreadyAtBottom"
                    + " source=\(authorizationSource) "
                    + chatBottomTraceState
            )
            return .consumedUnowned
        }

        let hasDecisiveCumulativeShrink =
            cumulativeContentHeightDelta < -2
            && change.signedDistanceFromBottom < -2
            && abs(
                cumulativeContentHeightDelta
                    - change.signedDistanceFromBottom
            ) <= 12
        let hasStableCollapsedTarget = predictedTailHeight > 2
            && predictedTailHeight < checkpoint.frame.height - 2
            && predictedTailMaxY <= 0
            && targetOffsetY.isFinite
            && expandedBottomOffsetY.isFinite
            && reconstructedTargetOffsetY.isFinite
            && abs(
                checkpoint.contentOffsetY - expandedBottomOffsetY
            ) <= 3
            && currentContentHeight >= expectedContentHeightLowerBound
            && currentContentHeight <= expectedContentHeightUpperBound
            && currentOffset.y >= targetOffsetY - 2
            && currentOffset.y <= checkpoint.contentOffsetY + 4
            && abs(reconstructedTargetOffsetY - targetOffsetY) <= 8
            && targetOffsetY >= minimumOffsetY
            && targetOffsetY < currentOffset.y - 2

        guard hasDecisiveCumulativeShrink,
              hasStableCollapsedTarget else {
            return retainAutomaticReasoningCollapseAuthorizationForNextSample(
                reason: hasDecisiveCumulativeShrink
                    ? "targetReconstruction"
                    : "collapseDelta",
                source: authorizationSource,
                contentHeightDelta: contentHeightDelta,
                cumulativeContentHeightDelta: cumulativeContentHeightDelta,
                signedDistanceFromBottom: change.signedDistanceFromBottom,
                predictedTailHeight: predictedTailHeight,
                predictedTailMaxY: predictedTailMaxY
            )
        }

        clearAutomaticReasoningCollapseAuthorization(reason: "ownerAdmitted")

        // These tasks are programmatic writers for the same bottom intent.
        // Cancel them only after every user-motion and geometry proof above
        // has passed, immediately before this owner performs its single write.
        let cancelledStreamFollow = streamFollowTask != nil
        let cancelledLayoutFollow = layoutFollowTask != nil
        streamFollowTask?.cancel()
        streamFollowTask = nil
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        automaticReasoningCollapseOwnerGeneration &+= 1
        let ownerID = AutomaticReasoningCollapseOwnerID(
            anchorID: change.anchorID,
            generation: automaticReasoningCollapseOwnerGeneration
        )
        // Every guard and target calculation is complete. Only a definitely
        // consumed decision may release the modifier's persistent edge, and it
        // must do so synchronously before root installs/writes this owner.
        claimSemanticOwner(ownerID)
        automaticReasoningCollapseRearmRequest = nil
        automaticReasoningCollapseOwner = AutomaticReasoningCollapseOwner(
            id: ownerID,
            identity: identity,
            checkpoint: checkpoint,
            appliedOffsetY: targetOffsetY,
            didRequestBottomRearm: false,
            didAcknowledgeBottomRearm: false,
            bottomRearmAttempt: 0
        )
        automaticReasoningCollapseOwnerLifecycle &+= 1
        scheduleAutomaticReasoningCollapseOwnerWatchdog(ownerID: ownerID)

        // Install both local and root ownership before stopping the old native
        // animation. Any synchronous phase/geometry callback caused by the
        // interruption therefore sees the collapse fence.
        if isNativeScrollAnimating(scrollView) {
            interruptNativeScrollMotion()
        }

        let writeOffset = scrollView.contentOffset
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_OWNER_ADMIT"
                + " source=\(authorizationSource)"
                + " generation=\(ownerID.generation)"
                + " tail=\(ChatBottomTrace.shortID(tailMessageID))"
                + " oldContentH=\(String(format: "%.1f", change.previousContentHeight))"
                + " contentH=\(String(format: "%.1f", change.contentHeight))"
                + " delta=\(String(format: "%.1f", change.signedDistanceFromBottom))"
                + " fromY=\(String(format: "%.1f", writeOffset.y))"
                + " targetY=\(String(format: "%.1f", targetOffsetY))"
                + " cancelStream=\(cancelledStreamFollow)"
                + " cancelLayout=\(cancelledLayoutFollow) "
                + chatBottomTraceState
        )
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(
                CGPoint(x: writeOffset.x, y: targetOffsetY),
                animated: false
            )
        }
        return .owned(ownerID)
    }

    private func retainAutomaticReasoningCollapseAuthorizationForNextSample(
        reason: String,
        source: String,
        contentHeightDelta: CGFloat,
        cumulativeContentHeightDelta: CGFloat,
        signedDistanceFromBottom: CGFloat,
        predictedTailHeight: CGFloat,
        predictedTailMaxY: CGFloat
    ) -> AutomaticReasoningCollapseGeometryDisposition {
        automaticReasoningCollapseAuthorizationSampleCount += 1
        let sampleCount = automaticReasoningCollapseAuthorizationSampleCount
        let deadlineExpired = automaticReasoningCollapseAuthorizationDeadline
            .map { Date() >= $0 } ?? true
        guard sampleCount < 12, !deadlineExpired else {
            let remainsAtExactBottom = currentUIKitBottomState?.isAtBottom == true
            clearAutomaticReasoningCollapseAuthorization(
                reason: remainsAtExactBottom
                    ? "pendingBoundAlreadyAtBottom"
                    : "pendingBoundFailClosed"
            )
            if !remainsAtExactBottom {
                autoFollowEngaged = false
            }
            ChatBottomTrace.log(
                "REASONING_COLLAPSE_GEOMETRY disposition=consumedUnowned"
                    + " reason=pendingBound"
                    + " sample=\(sampleCount)"
                    + " exactBottom=\(remainsAtExactBottom)"
                    + " autoFollow=\(autoFollowEngaged) "
                    + chatBottomTraceState
            )
            return .consumedUnowned
        }
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_GEOMETRY disposition=pendingCollapseSample"
                + " reason=\(reason)"
                + " source=\(source)"
                + " sample=\(sampleCount)"
                + " stepDelta=\(String(format: "%.1f", contentHeightDelta))"
                + " cumulativeDelta=\(String(format: "%.1f", cumulativeContentHeightDelta))"
                + " distance=\(String(format: "%.1f", signedDistanceFromBottom))"
                + " predictedHeight=\(String(format: "%.1f", predictedTailHeight))"
                + " predictedMaxY=\(String(format: "%.1f", predictedTailMaxY)) "
                + chatBottomTraceState
        )
        return .pendingCollapseSample
    }

    private func consumeAutomaticReasoningCollapseAuthorization(
        reason: String,
        source: String,
        contentHeightDelta: CGFloat,
        cumulativeContentHeightDelta: CGFloat
    ) -> AutomaticReasoningCollapseGeometryDisposition {
        clearAutomaticReasoningCollapseAuthorization(reason: reason)
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_GEOMETRY disposition=consumedUnowned"
                + " reason=\(reason)"
                + " source=\(source)"
                + " stepDelta=\(String(format: "%.1f", contentHeightDelta))"
                + " cumulativeDelta=\(String(format: "%.1f", cumulativeContentHeightDelta)) "
                + chatBottomTraceState
        )
        return .consumedUnowned
    }

    private func advanceAutomaticReasoningCollapseOwnerIfPossible(
        anchorID: ConversationBottomAnchorID
    ) {
        guard let owner = automaticReasoningCollapseOwner,
              owner.id.anchorID == anchorID,
              currentConversationBottomAnchorID == anchorID,
              anchorID.messageIDs.last == owner.identity.tailMessageID,
              messageFramesAnchorID == anchorID,
              messageFrameGeneration > owner.checkpoint.frameGeneration,
              let tailFrame = messageFrames[owner.identity.tailMessageID],
              tailFrame != owner.checkpoint.frame,
              tailFrame.height < owner.checkpoint.frame.height - 2,
              scrollViewportHeight > 0,
              tailFrame.maxY > 0,
              tailFrame.minY < scrollViewportHeight,
              let scrollView = chatScrollViewBox.scrollView,
              ObjectIdentifier(scrollView)
                == owner.checkpoint.scrollViewIdentity,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !isUserDrivenNativeScrollMotionInFlight else { return }

        if !owner.didRequestBottomRearm {
            requestAutomaticReasoningCollapseBottomRearm(
                ownerID: owner.id,
                reason: "concreteTailReady",
                frameGeneration: messageFrameGeneration,
                tailHeight: tailFrame.height
            )
            return
        }

        guard owner.didAcknowledgeBottomRearm,
              currentUIKitBottomState?.isAtBottom == true else { return }

        automaticReasoningCollapseOwner = nil
        automaticReasoningCollapseRearmRequest = nil
        automaticReasoningCollapseOwnerWatchdogTask?.cancel()
        automaticReasoningCollapseOwnerWatchdogTask = nil
        automaticReasoningCollapseOwnerLifecycle &+= 1
        lastMeasuredAtBottom = true
        lastMeasuredNearBottom = true
        lastKnownNearBottom = true
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_OWNER_COMPLETE"
                + " generation=\(owner.id.generation)"
                + " frameGeneration=\(messageFrameGeneration)"
                + " height=\(String(format: "%.1f", tailFrame.height))"
                + " appliedY=\(String(format: "%.1f", owner.appliedOffsetY)) "
                + chatBottomTraceState
        )
    }

    private func acknowledgeAutomaticReasoningCollapseBottomRearm(
        _ ownerID: AutomaticReasoningCollapseOwnerID
    ) {
        guard var owner = automaticReasoningCollapseOwner,
              owner.id == ownerID,
              automaticReasoningCollapseRearmRequest?.ownerID == ownerID,
              automaticReasoningCollapseRearmRequest?.attempt
                == owner.bottomRearmAttempt,
              owner.didRequestBottomRearm else { return }
        owner.didAcknowledgeBottomRearm = true
        automaticReasoningCollapseOwner = owner
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_OWNER_REARM_ACK"
                + " generation=\(owner.id.generation) "
                + chatBottomTraceState
        )
        advanceAutomaticReasoningCollapseOwnerIfPossible(
            anchorID: owner.id.anchorID
        )
    }

    private func requestAutomaticReasoningCollapseBottomRearm(
        ownerID: AutomaticReasoningCollapseOwnerID,
        reason: String,
        frameGeneration: UInt64? = nil,
        tailHeight: CGFloat? = nil
    ) {
        guard var owner = automaticReasoningCollapseOwner,
              owner.id == ownerID,
              owner.bottomRearmAttempt < 4 else { return }
        owner.didRequestBottomRearm = true
        owner.didAcknowledgeBottomRearm = false
        owner.bottomRearmAttempt &+= 1
        automaticReasoningCollapseOwner = owner
        automaticReasoningCollapseRearmRequest =
            AutomaticReasoningCollapseRearmRequest(
                ownerID: owner.id,
                attempt: owner.bottomRearmAttempt
            )
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_OWNER_REARM_REQUEST"
                + " generation=\(owner.id.generation)"
                + " attempt=\(owner.bottomRearmAttempt)"
                + " reason=\(reason)"
                + (frameGeneration.map { " frameGeneration=\($0)" } ?? "")
                + (tailHeight.map {
                    " height=\(String(format: "%.1f", $0))"
                } ?? "")
                + " " + chatBottomTraceState
        )
    }

    private func scheduleAutomaticReasoningCollapseOwnerWatchdog(
        ownerID: AutomaticReasoningCollapseOwnerID
    ) {
        automaticReasoningCollapseOwnerWatchdogTask?.cancel()
        automaticReasoningCollapseOwnerWatchdogTask = Task { @MainActor in
            let delays = [120, 180, 260, 340]
            for delay in delays {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
                guard let owner = automaticReasoningCollapseOwner,
                      owner.id == ownerID else { return }
                let attemptBeforeAdvance = owner.bottomRearmAttempt
                advanceAutomaticReasoningCollapseOwnerIfPossible(
                    anchorID: ownerID.anchorID
                )
                guard let currentOwner = automaticReasoningCollapseOwner,
                      currentOwner.id == ownerID else { return }
                if currentOwner.bottomRearmAttempt == attemptBeforeAdvance,
                   currentOwner.didRequestBottomRearm {
                    requestAutomaticReasoningCollapseBottomRearm(
                        ownerID: ownerID,
                        reason: currentOwner.didAcknowledgeBottomRearm
                            ? "watchdogBottomPending"
                            : "watchdogAckPending"
                    )
                }
            }
            guard automaticReasoningCollapseOwner?.id == ownerID else { return }
            abandonAutomaticReasoningCollapseOwnerFailClosed(
                ownerID: ownerID,
                reason: "boundedWatchdogExpired"
            )
        }
    }

    private func clearAutomaticReasoningCollapseAuthorization(reason: String) {
        let hadAuthorizationOrCheckpoint =
            automaticReasoningCollapseAuthorization != nil
            || automaticReasoningExpandedCheckpoint != nil
        automaticReasoningCollapseAuthorizationWatchdogTask?.cancel()
        automaticReasoningCollapseAuthorizationWatchdogTask = nil
        automaticReasoningCollapseAuthorizationGeneration &+= 1
        automaticReasoningCollapseAuthorization = nil
        automaticReasoningExpandedCheckpoint = nil
        automaticReasoningCollapseAuthorizationDeadline = nil
        automaticReasoningCollapseAuthorizationSampleCount = 0
        guard hadAuthorizationOrCheckpoint else { return }
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_AUTHORIZATION_CLEAR reason=\(reason) "
                + chatBottomTraceState
        )
    }

    private func abandonAutomaticReasoningCollapseOwnerForChangedTailIdentityIfNeeded()
        -> Bool {
        guard let owner = automaticReasoningCollapseOwner,
              !owner.didAcknowledgeBottomRearm,
              currentConversationBottomAnchorID == owner.id.anchorID else {
            return false
        }
        let stillMatchesStableIdentity: Bool
        if let tailMessage = model.messages.last,
           tailMessage.id == owner.identity.tailMessageID,
           let lastSegment = tailMessage.reasoningSegments.last,
           lastSegment.id == owner.identity.segmentID,
           lastSegment.finishedAt == owner.identity.finishedAt {
            stillMatchesStableIdentity = true
        } else {
            stillMatchesStableIdentity = false
        }
        guard !stillMatchesStableIdentity else { return false }
        abandonAutomaticReasoningCollapseOwnerFailClosed(
            ownerID: owner.id,
            reason: "stableTailIdentityChangedBeforeTailAck"
        )
        return true
    }

    private func abandonAutomaticReasoningCollapseOwnerFailClosed(
        ownerID: AutomaticReasoningCollapseOwnerID,
        reason: String
    ) {
        guard let owner = automaticReasoningCollapseOwner,
              owner.id == ownerID else { return }
        clearAutomaticReasoningCollapseAuthorization(reason: reason)
        automaticReasoningCollapseOwnerWatchdogTask?.cancel()
        automaticReasoningCollapseOwnerWatchdogTask = nil
        automaticReasoningCollapseRearmRequest = nil
        automaticReasoningCollapseOwner = nil
        automaticReasoningCollapseOwnerLifecycle &+= 1
        // The modifier already released persistent edge semantics during the
        // physical claim. Keep that user-owned position and disable ordinary
        // auto-follow so an unusually slow concrete-tail acknowledgement can
        // never turn into a later semantic jump or a blank viewport.
        autoFollowEngaged = false
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_OWNER_ABANDON"
                + " generation=\(owner.id.generation)"
                + " tail=\(ChatBottomTrace.shortID(owner.identity.tailMessageID))"
                + " reason=\(reason) autoFollow=false "
                + chatBottomTraceState
        )
    }

    private func cancelAutomaticReasoningCollapseOwner(reason: String) {
        clearAutomaticReasoningCollapseAuthorization(reason: reason)
        automaticReasoningCollapseOwnerWatchdogTask?.cancel()
        automaticReasoningCollapseOwnerWatchdogTask = nil
        automaticReasoningCollapseRearmRequest = nil
        guard let owner = automaticReasoningCollapseOwner else { return }
        automaticReasoningCollapseOwner = nil
        automaticReasoningCollapseOwnerLifecycle &+= 1
        ChatBottomTrace.log(
            "REASONING_COLLAPSE_OWNER_CANCEL"
                + " generation=\(owner.id.generation)"
                + " tail=\(ChatBottomTrace.shortID(owner.identity.tailMessageID))"
                + " reason=\(reason) "
                + chatBottomTraceState
        )
    }

    private func completeFreshConversationBottomHandoffIfNeeded() {
        guard isFreshConversationFollowSuppressed,
              model.messages.last?.role == .assistant else { return }
        // End only the behavioral suppression. The separate top-start marker
        // remains alive until this conversation is left, so enabling 4458's
        // accepted follow paths cannot replace the ScrollView's initial-anchor
        // branch or erase a user-driven detached state.
        newConversationFollowSuppressionID = nil
    }

    private func updateNativeNearBottom(_ isNearBottom: Bool, isAtBottom: Bool) {
        lastMeasuredNearBottom = isNearBottom
        guard lastKnownNearBottom != isNearBottom else { return }
        lastKnownNearBottom = isNearBottom
        // Let a user-driven drag (and its natural deceleration) finish on its
        // own.  The keyboard-open retry below waits for this measurement when
        // needed; re-engaging native bottom pinning here would snap the last
        // part of the drag and fight the keyboard-dismissal animation.
        if isAtBottom,
           !model.hasLaterMessages,
           !isUserScrollActive,
           !isMessageTargetNavigationOwned,
           !ownsCurrentDoubleEdgeNavigation {
            autoFollowEngaged = model.preferences.autoScrollEnabled
        }
    }

    private var isNativeScrollMotionInFlight: Bool {
        if isNativeScrollPhaseActive || isVerticalScrollGestureActive {
            return true
        }
        guard let scrollView = chatScrollViewBox.scrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    private var isUserDrivenNativeScrollMotionInFlight: Bool {
        if isVerticalScrollGestureActive {
            return true
        }
        if let scrollView = chatScrollViewBox.scrollView,
           scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            return true
        }
        // Do not fall back to SwiftUI's generic active phase here: `.animating`
        // is programmatic and can overlap the tail of an old user-motion lease.
        // The gesture plus concrete UIScrollView flags cover touch and inertia.
        return false
    }

    private func updateNativeBottomState(
        anchorID: ConversationBottomAnchorID,
        isAtBottom: Bool,
        isNearBottom: Bool
    ) {
        guard currentConversationBottomAnchorID == anchorID else { return }
        updateQuickReturnToBottomVisibility(
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
        let positionRequest = anchorID.positionRequest
        if lastMeasuredAtBottom != isAtBottom || lastMeasuredNearBottom != isNearBottom {
            ChatBottomTrace.log(
                "GEOMETRY_EDGE conv=\(ChatBottomTrace.shortID(positionRequest.conversationID))"
                    + " req=\(positionRequest.request)"
                    + " at=\(lastMeasuredAtBottom)->\(isAtBottom)"
                    + " near=\(lastMeasuredNearBottom)->\(isNearBottom) "
                    + chatBottomTraceState
            )
        }
        #if DEBUG
        navigationStressLog(
            "geometry \(model.selectedConversation?.title ?? "?") req=\(positionRequest.request) "
                + "at=\(isAtBottom) near=\(isNearBottom)"
        )
        #endif
        lastMeasuredAtBottom = isAtBottom
        updateNativeNearBottom(isNearBottom, isAtBottom: isAtBottom)
        if !isNearBottom, isUserDrivenNativeScrollMotionInFlight {
            offscreenStreamingDisplayState.didUserDetachFromTail = true
        }
        updateOffscreenStreamingDisplayLease(
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
        advanceAutomaticReasoningCollapseOwnerIfPossible(anchorID: anchorID)
        if isAtBottom,
           !isNativeScrollMotionInFlight {
            if pendingKeyboardDismissalDeadline != nil {
                ChatBottomTrace.log("KEYBOARD_PENDING_GEOMETRY_EXACT mode=hide " + chatBottomTraceState)
                resumePendingKeyboardDismissalViewportPinIfPossible()
            } else if pendingKeyboardViewportPin != nil {
                ChatBottomTrace.log("KEYBOARD_PENDING_GEOMETRY_EXACT mode=open " + chatBottomTraceState)
                consumePendingKeyboardViewportPinIfPossible(isAtBottom: true)
            }
        }
        if let request = model.pendingUserMessageSendPositionRequest,
           keyboardUnifiedSendHandoff?.requestID == request.id {
            _ = finishKeyboardUnifiedSendHandoffIfReady(request)
        }
        finishConversationReturnIfConcreteTailIsAtBottom(anchorID: anchorID)
    }

    private func updateNativeScrollPhaseActivityState(
        anchorID: ConversationBottomAnchorID,
        isActive: Bool,
        isAtBottom: Bool,
        isNearBottom: Bool
    ) {
        guard currentConversationBottomAnchorID == anchorID else { return }
        updateQuickReturnToBottomVisibility(
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
        isNativeScrollPhaseActive = isActive
        ChatBottomTrace.log(
            "NATIVE_PHASE_ACTIVE value=\(isActive) exact=\(isAtBottom) near=\(isNearBottom) "
                + chatBottomTraceState
        )
        guard !isActive else { return }

        // Phase context is the authoritative final sample. Keep it independent
        // from the user-motion `armed` lease so programmatic navigation can
        // settle queued keyboard work too.
        lastMeasuredAtBottom = isAtBottom
        lastMeasuredNearBottom = isNearBottom
        if let request = model.pendingUserMessageSendPositionRequest,
           keyboardUnifiedSendHandoff?.requestID == request.id {
            _ = finishKeyboardUnifiedSendHandoffIfReady(request)
        }
        advanceAutomaticReasoningCollapseOwnerIfPossible(anchorID: anchorID)
        if let pendingKeyboardViewportPin,
           pendingKeyboardViewportPinHasReachedBottom(pendingKeyboardViewportPin) {
            // A keyboard viewport change can make the new geometry look far
            // from bottom before our compensating position request runs. The
            // revision-scoped pre-transition token is the authoritative fact.
            isUserScrollActive = false
            consumePendingKeyboardViewportPinIfPossible(isAtBottom: isAtBottom)
            if self.pendingKeyboardViewportPin != nil {
                scheduleKeyboardNativeSettleWatcher()
            }
            finishConversationReturnIfConcreteTailIsAtBottom(anchorID: anchorID)
            return
        }
        if isAtBottom {
            lastKnownNearBottom = true
            if pendingKeyboardDismissalDeadline != nil {
                resumePendingKeyboardDismissalViewportPinIfPossible()
            } else {
                consumePendingKeyboardViewportPinIfPossible(isAtBottom: true)
            }
        } else if isNearBottom {
            // SwiftUI can publish idle one layout pass before the rubber-band's
            // final exact geometry. Keep the token bounded by the settle watcher;
            // it still cannot commit without a strict exact-bottom sample.
            if pendingKeyboardViewportPin != nil || pendingKeyboardDismissalDeadline != nil {
                scheduleKeyboardNativeSettleWatcher()
            } else if let navigationRequest,
                      navigationRequest.action != .bottom {
                keyboardBottomFollowIntent = false
            }
        } else {
            // The idle phase context is captured before both phase callbacks run.
            // When a keyboard presentation waits for bottom rubber-band motion,
            // the motion callback can consume the authorized token and restore
            // bottom following first. Do not let the second callback immediately
            // revoke that fresh intent with the same pre-pin far geometry.
            let preservesAcceptedKeyboardFollow = model.isComposerFocused
                && keyboardBottomFollowIntent
                && autoFollowEngaged
                && !isUserScrollActive
            if preservesAcceptedKeyboardFollow {
                ChatBottomTrace.log(
                    "KEYBOARD_FOLLOW_PRESERVE reason=staleIdleFar "
                        + chatBottomTraceState
                )
            } else {
                pendingKeyboardViewportPin = nil
                pendingKeyboardDismissalDeadline = nil
                keyboardBottomFollowIntent = false
                cancelKeyboardNativeSettleWatcher()
            }
        }
        finishConversationReturnIfConcreteTailIsAtBottom(anchorID: anchorID)
    }

    private func updateQuickReturnToBottomVisibility(
        isAtBottom: Bool,
        isNearBottom: Bool
    ) {
        let wasVisible = isQuickReturnToBottomVisible
        defer {
            if wasVisible != isQuickReturnToBottomVisible {
                ChatBottomTrace.log(
                    "QUICK_BOTTOM_VISIBLE value=\(isQuickReturnToBottomVisible) "
                        + chatBottomTraceState
                )
            }
        }
        if isAtBottom && !model.hasLaterMessages {
            isQuickReturnToBottomVisible = false
        } else if model.hasLaterMessages || !isNearBottom {
            // Keyboard layout and streaming growth can publish new geometry
            // before bottom-follow motion has landed. That intermediate distance
            // is not a departure while the existing bottom owner still holds it.
            // Native touch, history and navigation revoke this same ownership;
            // an already visible control still waits for exact-bottom geometry.
            if !model.hasLaterMessages,
               shouldKeepNativeBottomPosition {
                ChatBottomTrace.log(
                    "QUICK_BOTTOM_APPEAR_DEFERRED reason=bottomFollowOwner "
                        + chatBottomTraceState
                )
                return
            }
            // The native near-bottom band is the appearance hysteresis. Once
            // visible, the control remains through inertia and navigation;
            // only exact latest-bottom geometry hides it.
            isQuickReturnToBottomVisible = true
        }
    }

    private func beginSystemScrollToTop(
        anchorID: ConversationBottomAnchorID
    ) {
        guard currentConversationBottomAnchorID == anchorID else { return }
        cancelCodeDisclosure(reason: "systemScrollToTop")
        cancelAutomaticReasoningCollapseOwner(reason: "systemScrollToTop")
        ChatBottomTrace.log("SYSTEM_TOP_BEGIN " + chatBottomTraceState)
        // A status-bar tap has no SwiftUI DragGesture phase, so explicitly
        // give it the same reading-position ownership as a real upward drag.
        // The matching idle callback below will finish this bounded lease.
        isNativeVerticalScrollMotionArmed = true
        updateNativeScrollMotionState(
            anchorID: anchorID,
            isScrolling: true,
            isAtBottom: false,
            isNearBottom: false
        )
    }

    private func updateNativeScrollMotionState(
        anchorID: ConversationBottomAnchorID,
        isScrolling: Bool,
        isAtBottom: Bool,
        isNearBottom: Bool
    ) {
        guard currentConversationBottomAnchorID == anchorID else { return }
        if isScrolling, !isNearBottom {
            offscreenStreamingDisplayState.didUserDetachFromTail = true
        }
        updateOffscreenStreamingDisplayLease(
            isScrolling: isScrolling,
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
        if isScrolling {
            cancelMessageReplacementLanding()
            cancelCodeDisclosure(reason: "nativeUserMotion")
            cancelAutomaticReasoningCollapseOwner(reason: "nativeUserMotion")
        }
        if !isScrolling {
            reconcileSwiftUIGestureWithNativeTouchStateIfNeeded(chatScrollViewBox.scrollView)
        }
        if isScrolling,
           !isNativeVerticalScrollMotionArmed,
           streamingFollowTouchPauseAnchorID == nil,
           shouldPauseStreamingFollowOnNativeTouch {
            streamingFollowTouchPauseAnchorID = anchorID
            ChatBottomTrace.log(
                "STREAM_TOUCH_PAUSE_BEGIN exact=\(isAtBottom) near=\(isNearBottom) "
                    + chatBottomTraceState
            )
            // Native tracking starts before SwiftUI's vertical DragGesture
            // reaches its eight-point classification. Reuse the established
            // user-scroll cancellation path so no queued follow survives until
            // touch-up.
            lastKnownNearBottom = false
            handleScrollActivity(
                isScrolling: true,
                isAtBottom: isAtBottom,
                isNearBottom: false
            )
            return
        }
        if !isScrolling,
           streamingFollowTouchPauseAnchorID == anchorID,
           !isNativeVerticalScrollMotionArmed {
            streamingFollowTouchPauseAnchorID = nil
            ChatBottomTrace.log(
                "STREAM_TOUCH_PAUSE_END exact=\(isAtBottom) near=\(isNearBottom) "
                    + chatBottomTraceState
            )
            // Exact bottom is the only safe no-motion re-arm. If stream growth
            // moved the legal bottom while held, the existing off-bottom idle
            // path remains detached instead of submitting a touch-up jump.
            handleScrollActivity(
                isScrolling: false,
                isAtBottom: isAtBottom,
                isNearBottom: isNearBottom
            )
            return
        }
        if isNativeVerticalScrollMotionArmed,
           streamingFollowTouchPauseAnchorID == anchorID {
            // The established drag/deceleration owner takes over once vertical
            // intent is concrete; its ordinary idle path performs final re-arm.
            streamingFollowTouchPauseAnchorID = nil
        }
        if isScrolling,
           isNativeVerticalScrollMotionArmed,
           isMessageTargetNavigationOwned {
            cancelMessageTargetNavigationForUserInteraction()
        }
        let userWasActive = isUserScrollActive
        ChatBottomTrace.log(
            "ROOT_PHASE scrolling=\(isScrolling) exact=\(isAtBottom) near=\(isNearBottom) "
                + chatBottomTraceState
        )
        guard isNativeVerticalScrollMotionArmed else {
            ChatBottomTrace.log(
                "ROOT_PHASE_DROP reason=unarmed scrolling=\(isScrolling) exact=\(isAtBottom) near=\(isNearBottom) "
                    + chatBottomTraceState
            )
            return
        }
        // The finger lifts before native inertia ends. Keep the transient panel
        // available through deceleration, then start its hide delay at true idle.
        updateNavigationVisibility(isScrolling: isScrolling)
        let didFinishUserMotionAtBottom = !isScrolling
            && isAtBottom
        // A DragGesture ends when the finger lifts, before UIScrollView's
        // inertial deceleration or rubber-band return has actually stopped.
        // Let the native scroll phase own this lifetime so auto-follow is
        // restored from the final geometry without changing scroll physics.
        lastMeasuredAtBottom = isAtBottom
        lastMeasuredNearBottom = isNearBottom
        handleViewportScrollActivity(
            isScrolling: isScrolling,
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
        if didFinishUserMotionAtBottom,
           !model.hasLaterMessages,
           !ownsCurrentDoubleEdgeNavigation,
           hasCurrentConcreteLatestBottomContent {
            // Restore edge identity after the native motion is completely
            // finished, while the content is already at the exact bottom.
            // This is early enough for the next keyboard transition but has
            // no position delta and cannot interrupt momentum or a tap stop.
            nativeBottomEdgeRearmRequest &+= 1
            ChatBottomTrace.log(
                "EDGE_REARM_REQUEST value=\(nativeBottomEdgeRearmRequest) exact=\(isAtBottom)"
                    + " userBefore=\(userWasActive) userAfter=\(isUserScrollActive) "
                    + chatBottomTraceState
            )
        }
        guard !isScrolling else { return }
        if !didFinishUserMotionAtBottom {
            let reason = !isAtBottom ? "notExact" : "userInactive"
            ChatBottomTrace.log(
                "ROOT_IDLE_NO_REARM reason=\(reason) exact=\(isAtBottom) near=\(isNearBottom)"
                    + " userBefore=\(userWasActive) userAfter=\(isUserScrollActive) "
                    + chatBottomTraceState
            )
        }
        isNativeVerticalScrollMotionArmed = false
        updateOffscreenStreamingDisplayLease(
            isScrolling: false,
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
        schedulePendingMessageNavigationPromotion()
        if let pendingKeyboardViewportPin,
           pendingKeyboardViewportPinHasReachedBottom(pendingKeyboardViewportPin) {
            isUserScrollActive = false
            consumePendingKeyboardViewportPinIfPossible(isAtBottom: isAtBottom)
            if self.pendingKeyboardViewportPin != nil {
                scheduleKeyboardNativeSettleWatcher()
            }
            return
        }
        if model.isComposerFocused,
           pendingKeyboardViewportPin == nil,
           pendingKeyboardDismissalDeadline == nil {
            keyboardBottomFollowIntent = isAtBottom
        }
        if isAtBottom {
            resumePendingKeyboardDismissalViewportPinIfPossible()
        } else if isNearBottom {
            if pendingKeyboardViewportPin != nil || pendingKeyboardDismissalDeadline != nil {
                scheduleKeyboardNativeSettleWatcher()
            }
        } else {
            pendingKeyboardDismissalDeadline = nil
            pendingKeyboardViewportPin = nil
            keyboardBottomFollowIntent = false
            cancelKeyboardNativeSettleWatcher()
        }
    }

    private func handleConversationBottomAnchorFrame(
        _ snapshot: ConversationBottomAnchorFrame?,
        using scrollProxy: ScrollViewProxy
    ) {
        guard let snapshot,
              snapshot.anchorID == currentConversationBottomAnchorID,
              snapshot.frame != .zero else { return }
        if let requestID = activeCodeLayoutRequestID,
           snapshot.layoutRequestID != requestID { return }
        VersionFlashTrace.recordOnce(
            "sentinel-\(snapshot.positionRequest.conversationID)-\(snapshot.positionRequest.request)",
            "SENTINEL_FRAME"
                + " conv=\(VersionFlashTrace.identifierToken(snapshot.positionRequest.conversationID))"
                + " req=\(snapshot.positionRequest.request)"
                + " rows=\(snapshot.anchorID.messageIDs.count)"
                + " tail=\(snapshot.anchorID.messageIDs.last.map(VersionFlashTrace.identifierToken) ?? "nil")"
                + " minY=\(String(format: "%.1f", Double(snapshot.frame.minY)))"
                + " maxY=\(String(format: "%.1f", Double(snapshot.frame.maxY)))"
                + " height=\(String(format: "%.1f", Double(snapshot.frame.height)))"
                + " drawerSemantic=\(model.isDrawerPresented)"
                + " tailFrame=\(snapshot.anchorID.messageIDs.last.map { messageFrames[$0] != nil } ?? false)"
        )
        latestConversationBottomAnchorFrame = snapshot
        let hadAutomaticCollapseOwner =
            automaticReasoningCollapseOwner?.id.anchorID == snapshot.anchorID
        advanceAutomaticReasoningCollapseOwnerIfPossible(
            anchorID: snapshot.anchorID
        )
        if hadAutomaticCollapseOwner
            || automaticReasoningCollapseOwner?.id.anchorID == snapshot.anchorID {
            ChatBottomTrace.log(
                "REASONING_COLLAPSE_OWNER_DEFER source=bottomAnchor "
                    + chatBottomTraceState
            )
            return
        }
        #if DEBUG
        navigationStressLog(
            "anchor \(model.selectedConversation?.title ?? "?") req=\(snapshot.positionRequest.request) "
                + "min=\(snapshot.frame.minY) max=\(snapshot.frame.maxY) viewport=\(scrollViewportHeight) "
                + "drawer=\(model.isDrawerPresented) positioning=\(isPositioningCurrentConversation)"
        )
        #endif
        let holdsDrawerForConcreteTail =
            shouldHoldDrawerForConcreteConversationTail(
                for: snapshot.anchorID
            )
        if !holdsDrawerForConcreteTail {
            // Preserve the accepted path for every non-closing drawer state,
            // iOS 17, regeneration, navigation, and ordinary content update.
            onConversationContentReady(snapshot.positionRequest.conversationID)
        } else {
            VersionFlashTrace.recordOnce(
                "drawerTailGate-\(snapshot.positionRequest.conversationID)-\(snapshot.positionRequest.request)",
                "DRAWER_TAIL_GATE_WAIT"
                    + " conv=\(VersionFlashTrace.identifierToken(snapshot.positionRequest.conversationID))"
                    + " req=\(snapshot.positionRequest.request)"
                    + " tail=\(snapshot.anchorID.messageIDs.last.map(VersionFlashTrace.identifierToken) ?? "nil")"
            )
        }
        completeFreshConversationBottomHandoffIfNeeded()
        guard !model.isDrawerPresented || holdsDrawerForConcreteTail else {
            return
        }


        // A LazyVStack can lay out its inexpensive bottom sentinel while every
        // real message row remains virtualized. A bottom command submitted at
        // that point produces a valid geometry offset but a completely blank
        // viewport. Materialize the concrete surviving tail row once, then let
        // the native edge position perform the final true-bottom handoff.
        if scheduleBottomRowMaterializationIfNeeded(
            for: snapshot.anchorID,
            using: scrollProxy
        ) {
            return
        }

        if holdsDrawerForConcreteTail,
           !hasConcreteTailFrame(for: snapshot.anchorID) {
            // A precondition can make the bounded materializer ineligible before
            // it owns a lease. Keep the old liveness behavior instead of turning
            // that condition into a drawer deadlock.
            failOpenDrawerForConcreteTailIfCurrent(
                snapshot.anchorID,
                wasHeld: true,
                reason: "ineligibleBeforeLease"
            )
            return
        }

        if pendingBottomRowMaterializationAnchorID == snapshot.anchorID {
            bottomRowMaterializationTask?.cancel()
            bottomRowMaterializationTask = nil
            pendingBottomRowMaterializationAnchorID = nil
        }

        // Regeneration replaces a tall selected reply with a new streaming
        // tail without starting a conversation-return handoff. A LazyVStack
        // can first report either the old offscreen sentinel or a new positive
        // sentinel that is still far below the viewport; neither proves that
        // the new reply row has materialized. Keep native readiness withheld
        // until this exact message revision has both a concrete tail row and a
        // bottom sentinel intersecting the current viewport. The existing
        // one-shot proxy follow performs the recovery; native `.bottom` takes
        // ownership only after those two revision-scoped geometry facts agree.
        if #available(iOS 18.0, *),
           nativeConversationContentReadyAnchorID != snapshot.anchorID,
           shouldKeepNativeBottomPosition,
           !isPositioningCurrentConversation,
           model.isConversationStreaming(snapshot.positionRequest.conversationID),
           pendingBottomRowMaterializationAnchorID == nil,
           let tailMessageID = snapshot.anchorID.messageIDs.last,
           let tailMessage = model.messages.last,
           tailMessage.id == tailMessageID,
           tailMessage.role == .assistant,
           tailMessage.versionGroupID != nil,
           tailMessage.version > 0 {
            let tailFrame = messageFramesAnchorID == snapshot.anchorID
                ? messageFrames[tailMessageID]
                : nil
            let tailIntersectsViewport = scrollViewportHeight > 0
                && (tailFrame.map {
                    $0.maxY > 0 && $0.minY < scrollViewportHeight
                } ?? false)
            let sentinelIntersectsViewport = scrollViewportHeight > 0
                && snapshot.frame.maxY > 0
                && snapshot.frame.minY < scrollViewportHeight

            if !tailIntersectsViewport || !sentinelIntersectsViewport {
                let tailFrameDescription = tailFrame.map {
                    "\(String(format: "%.1f", $0.minY))...\(String(format: "%.1f", $0.maxY))"
                } ?? "nil"
                ChatBottomTrace.log(
                    "STREAM_READY_DEFER reason=tailOrSentinelOutsideViewport"
                        + " tailFrame=\(tailFrameDescription)"
                        + " anchorMinY=\(String(format: "%.1f", snapshot.frame.minY))"
                        + " anchorMaxY=\(String(format: "%.1f", snapshot.frame.maxY))"
                        + " viewport=\(String(format: "%.1f", scrollViewportHeight)) "
                        + chatBottomTraceState
                )
                scheduleConcreteStreamingTailRecovery(
                    anchorID: snapshot.anchorID,
                    tailMessageID: tailMessageID,
                    using: scrollProxy
                )
                return
            }

            // A geometry callback can close the acknowledgement while the
            // coalesced proxy task is still waiting for its executor turn.
            // Cancel that now-redundant writer before native readiness resets
            // the edge, so recovery cannot land a late second bottom command.
            streamFollowTask?.cancel()
            streamFollowTask = nil
            ChatBottomTrace.log(
                "STREAM_READY_ACK reason=concreteTailAndSentinelInViewport"
                    + " tail=\(ChatBottomTrace.shortID(tailMessageID))"
                    + " anchorMaxY=\(String(format: "%.1f", snapshot.frame.maxY))"
                    + " viewport=\(String(format: "%.1f", scrollViewportHeight)) "
                    + chatBottomTraceState
            )
        }

        // A sentinel is only a coordinate. Non-empty readiness additionally
        // requires the exact latest-window tail row to have a valid frame in
        // this same revision; otherwise native `.bottom` can target an empty
        // LazyVStack region.
        guard !model.hasLaterMessages,
              hasConcreteTailFrame(for: snapshot.anchorID) else {
            ChatBottomTrace.log(
                "CONTENT_READY_DEFER reason=concreteLatestTailMissing "
                    + chatBottomTraceState
            )
            return
        }

        if nativeConversationContentReadyAnchorID != snapshot.anchorID {
            VersionFlashTrace.recordOnce(
                "contentReady-\(snapshot.positionRequest.conversationID)-\(snapshot.positionRequest.request)",
                "CONTENT_READY_COMMIT"
                    + " conv=\(VersionFlashTrace.identifierToken(snapshot.positionRequest.conversationID))"
                    + " req=\(snapshot.positionRequest.request)"
                    + " rows=\(snapshot.anchorID.messageIDs.count)"
                    + " tail=\(snapshot.anchorID.messageIDs.last.map(VersionFlashTrace.identifierToken) ?? "nil")"
                    + " tailFrame=\(snapshot.anchorID.messageIDs.last.map { messageFrames[$0] != nil } ?? false)"
            )
            ChatBottomTrace.log(
                "CONTENT_READY_KEY conv=\(ChatBottomTrace.shortID(snapshot.positionRequest.conversationID))"
                    + " req=\(snapshot.positionRequest.request)"
                    + " rows=\(snapshot.anchorID.messageIDs.count)"
                    + " anchorMaxY=\(String(format: "%.1f", snapshot.frame.maxY))"
                    + " viewport=\(String(format: "%.1f", scrollViewportHeight)) "
                    + chatBottomTraceState
            )
            // The current conversation's concrete sentinel has now completed a
            // layout pass. Only now is it safe to replace a retained native
            // ScrollPosition from the previous conversation.
            nativeConversationContentReadyAnchorID = snapshot.anchorID
            if #unavailable(iOS 18.0) {
                // Structural changes can happen while the user is deliberately
                // reading older content. On iOS 17 only an actual conversation
                // return owns a proxy jump; readiness alone must never create one.
                if isPositioningCurrentConversation {
                    scheduleConversationReturn(using: scrollProxy)
                }
            } else if isPositioningCurrentConversation {
                let readyAnchorID = snapshot.anchorID
                Task { @MainActor in
                    // Let the modifier consume the readiness value and perform
                    // its native edge pin before checking the real UIScrollView.
                    await Task.yield()
                    finishConversationReturnIfConcreteTailIsAtBottom(anchorID: readyAnchorID)
                }
            }
        }
        if holdsDrawerForConcreteTail {
            VersionFlashTrace.record(
                "DRAWER_TAIL_GATE_ACK"
                    + " conv=\(VersionFlashTrace.identifierToken(snapshot.positionRequest.conversationID))"
                    + " req=\(snapshot.positionRequest.request)"
                    + " tail=\(snapshot.anchorID.messageIDs.last.map(VersionFlashTrace.identifierToken) ?? "nil")"
            )
            onConversationContentReady(snapshot.positionRequest.conversationID)
        }
        finishConversationReturnIfConcreteTailIsAtBottom(anchorID: snapshot.anchorID)
    }

    private func isCurrentDrawerCoveredConversationReturn(
        _ anchorID: ConversationBottomAnchorID
    ) -> Bool {
        model.isDrawerPresented
            && currentConversationBottomAnchorID == anchorID
            && model.selectedConversationID
                == anchorID.positionRequest.conversationID
            && model.conversationBottomReturnTargetID
                == anchorID.positionRequest.conversationID
            && isConversationDrawerClosePending(
                anchorID.positionRequest.conversationID
            )
            && isPositioningCurrentConversation
    }

    private func shouldHoldDrawerForConcreteConversationTail(
        for anchorID: ConversationBottomAnchorID
    ) -> Bool {
        guard #available(iOS 18.0, *) else { return false }
        return isCurrentDrawerCoveredConversationReturn(anchorID)
    }

    private func allowsBottomRowMaterialization(
        for anchorID: ConversationBottomAnchorID,
        heldDrawerReturn: Bool
    ) -> Bool {
        !model.isDrawerPresented
            || (heldDrawerReturn
                && isCurrentDrawerCoveredConversationReturn(anchorID))
    }

    private func hasConcreteTailFrame(
        for anchorID: ConversationBottomAnchorID
    ) -> Bool {
        guard let tailMessageID = anchorID.messageIDs.last else { return false }
        return validConcreteMessageFrame(
            tailMessageID,
            anchorID: anchorID
        ) != nil
    }

    private func failOpenDrawerForConcreteTailIfCurrent(
        _ anchorID: ConversationBottomAnchorID,
        wasHeld: Bool,
        reason: String
    ) {
        guard wasHeld,
              pendingBottomRowMaterializationAnchorID != anchorID,
              isCurrentDrawerCoveredConversationReturn(anchorID) else { return }
        ChatBottomTrace.log(
            "DRAWER_TAIL_GATE_FAIL_OPEN"
                + " conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                + " req=\(anchorID.positionRequest.request)"
                + " reason=\(reason)"
        )
        VersionFlashTrace.record(
            "DRAWER_TAIL_GATE_FAIL_OPEN"
                + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                + " req=\(anchorID.positionRequest.request)"
                + " reason=\(reason)"
        )
        onConversationContentReady(anchorID.positionRequest.conversationID)
    }

    private func finishConversationReturnIfConcreteTailIsAtBottom(
        anchorID: ConversationBottomAnchorID
    ) {
        guard currentConversationBottomAnchorID == anchorID,
              nativeConversationContentReadyAnchorID == anchorID,
              isPositioningCurrentConversation,
              let tailMessageID = anchorID.messageIDs.last,
              messageFramesAnchorID == anchorID,
              messageFrames[tailMessageID] != nil,
              !isNativeScrollMotionInFlight,
              currentUIKitBottomState?.isAtBottom == true else { return }
        finishConversationReturnPositioning(for: anchorID.positionRequest.conversationID)
    }

    private func scheduleBottomRowMaterializationIfNeeded(
        for anchorID: ConversationBottomAnchorID,
        using scrollProxy: ScrollViewProxy
    ) -> Bool {
        if model.usesConcreteConversationEntryWindow {
            // Every destination row already participates in concrete layout.
            // Its frame preference will re-enter the existing readiness chain;
            // a top seed and delayed tail retries would expose a false location.
            return !hasConcreteTailFrame(for: anchorID)
        }
        guard shouldKeepNativeBottomPosition,
              nativeConversationContentReadyAnchorID != anchorID,
              !model.isComposerFocused,
              !isUserScrollActive,
              navigationRequest == nil,
              pendingKeyboardViewportPin == nil,
              pendingKeyboardDismissalDeadline == nil,
              !model.isConversationStreaming(anchorID.positionRequest.conversationID),
              !model.hasLaterMessages,
              let tailMessageID = anchorID.messageIDs.last,
              messageFramesAnchorID != anchorID
                || messageFrames[tailMessageID] == nil else { return false }

        let tailHostID = conversationMessageHostID(for: tailMessageID)
        let topSeedID = ConversationTopMaterializationSeedID(anchorID: anchorID)

        guard pendingBottomRowMaterializationAnchorID != anchorID else { return true }
        if layoutFollowTask != nil {
            ChatBottomTrace.log(
                "LAYOUT_FOLLOW_CANCEL source=tailMaterialize "
                    + chatBottomTraceState
            )
        }
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        bottomRowMaterializationTask?.cancel()
        pendingBottomRowMaterializationAnchorID = anchorID
        streamFollowTask?.cancel()
        streamFollowTask = nil
        let heldDrawerReturn =
            shouldHoldDrawerForConcreteConversationTail(for: anchorID)
        VersionFlashTrace.record(
            "TAIL_MATERIALIZE_QUEUED"
                + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                + " req=\(anchorID.positionRequest.request)"
                + " rows=\(anchorID.messageIDs.count)"
                + " tail=\(VersionFlashTrace.identifierToken(tailMessageID))"
        )
        ChatBottomTrace.log(
            "TAIL_MATERIALIZE_QUEUED conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                + " req=\(anchorID.positionRequest.request) rows=\(anchorID.messageIDs.count)"
        )
        bottomRowMaterializationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  pendingBottomRowMaterializationAnchorID == anchorID,
                  currentConversationBottomAnchorID == anchorID,
                  nativeConversationContentReadyAnchorID != anchorID,
                  shouldKeepNativeBottomPosition,
                  !model.isComposerFocused,
                  !isUserScrollActive,
                  navigationRequest == nil,
                  pendingKeyboardViewportPin == nil,
                  pendingKeyboardDismissalDeadline == nil,
                  !model.isConversationStreaming(anchorID.positionRequest.conversationID),
                  !model.hasLaterMessages,
                  allowsBottomRowMaterialization(
                    for: anchorID,
                    heldDrawerReturn: heldDrawerReturn
                  ) else {
                // Every external cancellation site synchronously releases this
                // lease. A cancelled old task must never clear or fail-open a
                // newer task that reused the same exact anchor.
                if heldDrawerReturn, Task.isCancelled { return }
                if pendingBottomRowMaterializationAnchorID == anchorID {
                    pendingBottomRowMaterializationAnchorID = nil
                    bottomRowMaterializationTask = nil
                }
                failOpenDrawerForConcreteTailIfCurrent(
                    anchorID,
                    wasHeld: heldDrawerReturn,
                    reason: "initialGuard"
                )
                return
            }
            var seedTransaction = Transaction()
            seedTransaction.disablesAnimations = true
            traceScrollCommand(
                source: "tailMaterialize.seedTop",
                target: "topSeed",
                animation: "disabled"
            )
            withTransaction(seedTransaction) {
                scrollProxy.scrollTo(topSeedID, anchor: .top)
            }
            ChatBottomTrace.log(
                "TAIL_MATERIALIZE_SEED_APPLIED"
                    + " conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                    + " req=\(anchorID.positionRequest.request)"
            )
            VersionFlashTrace.record(
                "TAIL_MATERIALIZE_SEED_APPLIED"
                    + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                    + " req=\(anchorID.positionRequest.request)"
                    + " tail=\(VersionFlashTrace.identifierToken(tailMessageID))"
            )
            try? await Task.sleep(for: .milliseconds(32))

            for (attempt, delay) in [0, 40, 90, 180, 300].enumerated() {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled,
                      pendingBottomRowMaterializationAnchorID == anchorID,
                      currentConversationBottomAnchorID == anchorID,
                      nativeConversationContentReadyAnchorID != anchorID,
                      shouldKeepNativeBottomPosition,
                      !model.isComposerFocused,
                      !isUserScrollActive,
                      navigationRequest == nil,
                      pendingKeyboardViewportPin == nil,
                      pendingKeyboardDismissalDeadline == nil,
                      !model.isConversationStreaming(anchorID.positionRequest.conversationID),
                      !model.hasLaterMessages,
                      allowsBottomRowMaterialization(
                        for: anchorID,
                        heldDrawerReturn: heldDrawerReturn
                      ) else {
                    if heldDrawerReturn, Task.isCancelled { return }
                    if pendingBottomRowMaterializationAnchorID == anchorID {
                        pendingBottomRowMaterializationAnchorID = nil
                        bottomRowMaterializationTask = nil
                    }
                    failOpenDrawerForConcreteTailIfCurrent(
                        anchorID,
                        wasHeld: heldDrawerReturn,
                        reason: "attemptGuard"
                    )
                    return
                }
                if messageFramesAnchorID == anchorID,
                   messageFrames[tailMessageID] != nil {
                    VersionFlashTrace.record(
                        "TAIL_MATERIALIZE_ACKED"
                            + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                            + " req=\(anchorID.positionRequest.request)"
                            + " tail=\(VersionFlashTrace.identifierToken(tailMessageID))"
                            + " afterAttempt=\(attempt)"
                    )
                    ChatBottomTrace.log(
                        "TAIL_MATERIALIZE_ACKED"
                            + " conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                            + " req=\(anchorID.positionRequest.request)"
                            + " tail=\(ChatBottomTrace.shortID(tailMessageID))"
                            + " afterAttempt=\(attempt)"
                    )
                    bottomRowMaterializationTask = nil
                    if heldDrawerReturn,
                       pendingBottomRowMaterializationAnchorID == anchorID {
                        pendingBottomRowMaterializationAnchorID = nil
                    }
                    if let snapshot = latestConversationBottomAnchorFrame,
                       snapshot.anchorID == anchorID {
                        handleConversationBottomAnchorFrame(snapshot, using: scrollProxy)
                    } else {
                        failOpenDrawerForConcreteTailIfCurrent(
                            anchorID,
                            wasHeld: heldDrawerReturn,
                            reason: "ackMissingSnapshot"
                        )
                    }
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "tailMaterialize.attempt\(attempt + 1)",
                    target: "tailHost:\(ChatBottomTrace.shortID(tailMessageID))",
                    animation: "disabled"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(tailHostID, anchor: .bottom)
                }
                ChatBottomTrace.log(
                    "TAIL_MATERIALIZE_APPLIED conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                        + " req=\(anchorID.positionRequest.request)"
                        + " tail=\(ChatBottomTrace.shortID(tailMessageID))"
                        + " attempt=\(attempt + 1)"
                )
                VersionFlashTrace.record(
                    "TAIL_MATERIALIZE_APPLIED"
                        + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                        + " req=\(anchorID.positionRequest.request)"
                        + " tail=\(VersionFlashTrace.identifierToken(tailMessageID))"
                        + " attempt=\(attempt + 1)"
                )
            }
            try? await Task.sleep(for: .milliseconds(120))
            // Cancellation is owned by the synchronous external cleanup that
            // issued it. Do not let an old task touch a same-anchor successor.
            guard !Task.isCancelled else { return }
            guard pendingBottomRowMaterializationAnchorID == anchorID else {
                failOpenDrawerForConcreteTailIfCurrent(
                    anchorID,
                    wasHeld: heldDrawerReturn,
                    reason: "finalGuard"
                )
                return
            }
            bottomRowMaterializationTask = nil
            if messageFramesAnchorID == anchorID,
               messageFrames[tailMessageID] != nil,
               let snapshot = latestConversationBottomAnchorFrame,
               snapshot.anchorID == anchorID {
                VersionFlashTrace.record(
                    "TAIL_MATERIALIZE_ACKED"
                        + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                        + " req=\(anchorID.positionRequest.request)"
                        + " tail=\(VersionFlashTrace.identifierToken(tailMessageID))"
                        + " afterAttempt=5"
                )
                ChatBottomTrace.log(
                    "TAIL_MATERIALIZE_ACKED"
                        + " conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                        + " req=\(anchorID.positionRequest.request)"
                        + " tail=\(ChatBottomTrace.shortID(tailMessageID))"
                        + " afterAttempt=5"
                )
                handleConversationBottomAnchorFrame(snapshot, using: scrollProxy)
                return
            }
            pendingBottomRowMaterializationAnchorID = nil
            let observedFrameIDs = messageFrames.keys
                .map { ChatBottomTrace.shortID($0) }
                .sorted()
                .joined(separator: ",")
            ChatBottomTrace.log(
                "TAIL_MATERIALIZE_RELEASED conv=\(ChatBottomTrace.shortID(anchorID.positionRequest.conversationID))"
                    + " req=\(anchorID.positionRequest.request)"
                    + " reason=noAck"
                    + " frameAnchorMatches=\(messageFramesAnchorID == anchorID)"
                    + " observedFrames=[\(observedFrameIDs)]"
            )
            VersionFlashTrace.record(
                "TAIL_MATERIALIZE_RELEASED"
                    + " conv=\(VersionFlashTrace.identifierToken(anchorID.positionRequest.conversationID))"
                    + " req=\(anchorID.positionRequest.request)"
                    + " tail=\(VersionFlashTrace.identifierToken(tailMessageID))"
                    + " reason=noAck"
                    + " frameAnchorMatches=\(messageFramesAnchorID == anchorID)"
                    + " observedFrameCount=\(messageFrames.count)"
            )
            failOpenDrawerForConcreteTailIfCurrent(
                anchorID,
                wasHeld: heldDrawerReturn,
                reason: "noAck"
            )
        }
        return true
    }

    private func updateNavigationVisibility(isScrolling: Bool) {
        navigationHideTask?.cancel()
        navigationHideTask = nil
        guard model.preferences.mobileMessageNavButtonsMode == .scroll else { return }
        if isScrolling {
            showTransientNavigation = true
            return
        }
        navigationHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            showTransientNavigation = false
        }
    }

    private func keepNavigationVisibleBriefly() {
        guard model.preferences.mobileMessageNavButtonsMode == .scroll else { return }
        showTransientNavigation = true
        updateNavigationVisibility(isScrolling: false)
    }

    private var navigationLandingAnchor: UnitPoint {
        UnitPoint(x: 0.5, y: 0.10)
    }

    private var navigationGuideY: CGFloat {
        min(max(64, scrollViewportHeight * 0.10), 92)
    }

    private func navigationAnimation(
        distance: CGFloat?,
        isEdge: Bool
    ) -> (animation: Animation, duration: TimeInterval) {
        let viewport = max(scrollViewportHeight, 1)
        let fallbackDistance = viewport * (isEdge ? 2.2 : 0.9)
        let screens = min(abs(distance ?? fallbackDistance) / viewport, 4)
        let duration = min(
            isEdge ? 0.38 : 0.32,
            (isEdge ? 0.28 : 0.20)
                + (isEdge ? 0.06 : 0.07) * Double(screens.squareRoot())
        )
        return (.smooth(duration: duration, extraBounce: 0), duration)
    }

    private func prepareMessageNavigation(for action: MessageNavigationAction) {
        if case .message = action {
            // The favorites card already acknowledges the tap immediately.
        } else {
            model.performCardHaptic()
        }
        cancelUserMessageSendPositioning(consumingPendingRequest: true)
        pendingKeyboardViewportPin = nil
        pendingKeyboardDismissalDeadline = nil
        keyboardBottomFollowIntent = false
        cancelKeyboardNativeSettleWatcher()
        invalidateKeyboardDismissalTransition()
        lastKnownNearBottom = false
        lastMeasuredNearBottom = false
        lastMeasuredAtBottom = false
        autoFollowEngaged = false
        isUserScrollActive = false
        isNativeVerticalScrollMotionArmed = false
        cancelConversationReturnPositioning()
        userScrollIdleTask?.cancel()
        streamFollowTask?.cancel()
        layoutFollowTask?.cancel()
        keyboardViewportPinTask?.cancel()
        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = nil
    }

    private func scrollToTop(
        using scrollProxy: ScrollViewProxy,
        request: MessageNavigationRequest
    ) {
        if request.action == .top {
            // A top request replaces the compact latest window. Clear the
            // retained eager owner in the same update that loads the start
            // window so no eager-to-lazy handoff is exposed at the old bottom.
            bottomNavigationCompactWindowConversationID = nil
            navigationAnchorMessageID = nil
            navigationScrollTask = Task { @MainActor in
                defer {
                    if navigationRequest == request {
                        navigationRequest = nil
                        navigationScrollTask = nil
                    }
                }
                guard !hasConcreteNativeUserScrollOwnership else { return }
                if model.hasEarlierMessages {
                    if model.loadStartMessageWindow() {
                        advanceConversationLazyWindowGeneration()
                    }
                }
                await awaitNextMainQueueTurn()
                let hostAnchorID = currentConversationBottomAnchorID
                guard !Task.isCancelled,
                      navigationRequest == request,
                      hostAnchorID.positionRequest == request.positionRequest,
                      !hasConcreteNativeUserScrollOwnership,
                      let firstID = hostAnchorID.messageIDs.first else { return }
                let firstHostID = conversationMessageHostID(for: firstID)
                let animation = navigationAnimation(
                    distance: messageFrames[firstID].map {
                        $0.minY - navigationGuideY
                    },
                    isEdge: true
                )
                traceScrollCommand(
                    source: "navigation.top",
                    target: "messageHost:\(ChatBottomTrace.shortID(firstID))",
                    animation: "smooth"
                )
                withAnimation(animation.animation) {
                    scrollProxy.scrollTo(firstHostID, anchor: .top)
                }
                try? await Task.sleep(
                    for: .seconds(animation.duration + 0.04)
                )
                guard !Task.isCancelled,
                      navigationRequest == request,
                      currentConversationBottomAnchorID == hostAnchorID else {
                    return
                }
                guard hasVisibleConcreteMessageFrame(
                    firstID,
                    anchorID: hostAnchorID
                ) else {
                    await failClosedEdgeNavigation(
                        request,
                        anchorID: hostAnchorID,
                        using: scrollProxy,
                        reason: "topFrameNotReady"
                    )
                    return
                }
                // A successful top navigation is a detached reading position,
                // never a semantic bottom for this historical window.
                lastKnownNearBottom = false
                lastMeasuredNearBottom = false
                lastMeasuredAtBottom = false
                isUserScrollActive = true
                autoFollowEngaged = false
            }
            keepNavigationVisibleBriefly()
            return
        }
        if model.hasEarlierMessages {
            if model.loadStartMessageWindow() {
                advanceConversationLazyWindowGeneration()
            }
        }
        guard let firstID = model.messages.first?.id else { return }
        let hostAnchorID = currentConversationBottomAnchorID
        let hostHasLaterMessages = model.hasLaterMessages
        guard hostAnchorID.positionRequest == request.positionRequest else { return }
        let firstHostID = conversationMessageHostID(
            for: firstID
        )
        let animation = navigationAnimation(
            distance: messageFrames[firstID].map { $0.minY - navigationGuideY },
            isEdge: true
        )
        prepareMessageNavigation(for: request.action)
        navigationAnchorMessageID = nil
        navigationScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == hostAnchorID,
                  model.hasLaterMessages == hostHasLaterMessages else { return }
            traceScrollCommand(
                source: "navigation.top",
                target: "messageHost:\(ChatBottomTrace.shortID(firstID))",
                animation: "smooth"
            )
            withAnimation(animation.animation) {
                scrollProxy.scrollTo(firstHostID, anchor: .top)
            }
            try? await Task.sleep(for: .seconds(animation.duration + 0.02))
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationPositionRequest == request.positionRequest else { return }
            navigationRequest = nil
            navigationScrollTask = nil
        }
        keepNavigationVisibleBriefly()
    }

    private func awaitCompactBottomNavigationPreflight(
        request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID,
        tailMessageID: UUID
    ) async -> Bool {
        var previousSnapshot: MessageTargetLandingSnapshot?
        var consecutiveStablePasses = 0

        // The window contains at most twelve canonical rows, so this is a
        // bounded layout acknowledgement rather than a fixed wait for an
        // unbounded LazyVStack estimate to settle.
        for attempt in 0..<12 {
            if attempt == 0 {
                await awaitNextMainQueueTurn()
            } else {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled,
                  navigationRequest == request,
                  bottomNavigationCompactWindowConversationID
                    == anchorID.positionRequest.conversationID,
                  currentConversationBottomAnchorID == anchorID,
                  !model.hasLaterMessages,
                  let scrollView = chatScrollViewBox.scrollView,
                  scrollView.window != nil,
                  !nativeScrollHasActiveTouch(scrollView),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return false }

            let allRowsConcrete = messageFramesAnchorID == anchorID
                && anchorID.messageIDs.allSatisfy {
                    validConcreteMessageFrame($0, anchorID: anchorID) != nil
                }
            guard allRowsConcrete,
                  let snapshot = messageTargetLandingSnapshot(
                    tailMessageID,
                    anchorID: anchorID,
                    scrollView: scrollView
                  ),
                  latestConversationBottomAnchorFrame?.anchorID == anchorID else {
                previousSnapshot = nil
                consecutiveStablePasses = 0
                continue
            }

            if let previousSnapshot,
               snapshot.isStable(comparedTo: previousSnapshot, tolerance: 1) {
                consecutiveStablePasses += 1
            } else {
                consecutiveStablePasses = 1
            }
            previousSnapshot = snapshot
            guard consecutiveStablePasses >= 2 else { continue }

            ChatBottomTrace.log(
                "EDGE_COMPACT_PREFLIGHT_READY"
                    + " sequence=\(request.sequence)"
                    + " rows=\(anchorID.messageIDs.count)"
                    + " attempt=\(attempt)"
                    + " contentH=\(String(format: "%.1f", snapshot.contentSize.height)) "
                    + chatBottomTraceState
            )
            return true
        }

        ChatBottomTrace.log(
            "EDGE_COMPACT_PREFLIGHT_DROP"
                + " sequence=\(request.sequence)"
                + " reason=unstableConcreteWindow "
                + chatBottomTraceState
        )
        return false
    }

    private func scrollToBottom(
        using scrollProxy: ScrollViewProxy,
        request: MessageNavigationRequest
    ) {
        if request.action == .bottom {
            navigationAnchorMessageID = nil
            navigationScrollTask = Task { @MainActor in
                var didComplete = false
                var landingAnchorID: ConversationBottomAnchorID?
                defer {
                    if !didComplete,
                       let landingAnchorID,
                       navigationRequest == request,
                       currentConversationBottomAnchorID == landingAnchorID {
                        lastKnownNearBottom = false
                        lastMeasuredNearBottom = false
                        lastMeasuredAtBottom = false
                        isUserScrollActive = true
                        autoFollowEngaged = false
                    }
                    if navigationRequest == request {
                        navigationRequest = nil
                        navigationScrollTask = nil
                    }
                }

                guard !hasConcreteNativeUserScrollOwnership else { return }
                let sourceAnchorID = currentConversationBottomAnchorID
                let sourceTailMessageID = sourceAnchorID.messageIDs.last
                let sourceTailIsConcrete = sourceTailMessageID.map {
                    validConcreteMessageFrame(
                        $0,
                        anchorID: sourceAnchorID
                    ) != nil
                } ?? false
                let requiresCompactWindow = model.hasLaterMessages
                    || !sourceTailIsConcrete
                if requiresCompactWindow {
                    let replacedWindow = model.loadLatestBottomNavigationWindow()
                    if replacedWindow {
                        advanceConversationLazyWindowGeneration()
                    }
                    bottomNavigationCompactWindowConversationID =
                        model.selectedConversationID
                    ChatBottomTrace.log(
                        "EDGE_COMPACT_WINDOW_ACTIVATE"
                            + " sequence=\(request.sequence)"
                            + " replaced=\(replacedWindow)"
                            + " sourceRows=\(sourceAnchorID.messageIDs.count) "
                            + chatBottomTraceState
                    )
                }
                await awaitNextMainQueueTurn()
                let bottomAnchorID = currentConversationBottomAnchorID
                landingAnchorID = bottomAnchorID
                guard !Task.isCancelled,
                      navigationRequest == request,
                      bottomAnchorID.positionRequest == request.positionRequest,
                      !model.hasLaterMessages,
                      let tailMessageID = bottomAnchorID.messageIDs.last else {
                    return
                }

                if isConcreteEdgeBottomLanding(
                    request,
                    anchorID: bottomAnchorID,
                    tailMessageID: tailMessageID
                ) {
                    didComplete = true
                    lastKnownNearBottom = true
                    lastMeasuredNearBottom = true
                    lastMeasuredAtBottom = true
                    isUserScrollActive = false
                    autoFollowEngaged = model.preferences.autoScrollEnabled
                    keepNavigationVisibleBriefly()
                    return
                }

                if requiresCompactWindow {
                    guard !hasConcreteNativeUserScrollOwnership else { return }
                    // The latest window is now a bounded eager destination.
                    // Start from its real top seed, then require every canonical
                    // row and the native geometry to agree before animating.
                    var seedTransaction = Transaction()
                    seedTransaction.disablesAnimations = true
                    traceScrollCommand(
                        source: "navigation.bottomCompactSeed",
                        target: "topSeed",
                        animation: "disabled"
                    )
                    withTransaction(seedTransaction) {
                        scrollProxy.scrollTo(
                            ConversationTopMaterializationSeedID(
                                anchorID: bottomAnchorID
                            ),
                            anchor: .top
                        )
                    }
                    await awaitNextMainQueueTurn()
                    guard await awaitCompactBottomNavigationPreflight(
                        request: request,
                        anchorID: bottomAnchorID,
                        tailMessageID: tailMessageID
                    ) else {
                        await failClosedEdgeNavigation(
                            request,
                            anchorID: bottomAnchorID,
                            using: scrollProxy,
                            preserveViewportOnFailure: true,
                            reason: "compactWindowNotReady"
                        )
                        return
                    }
                }

                guard !Task.isCancelled,
                      navigationRequest == request,
                      currentConversationBottomAnchorID == bottomAnchorID else {
                    return
                }
                guard !hasConcreteNativeUserScrollOwnership else { return }
                let tailWasVisible = hasVisibleConcreteTailBottomEdge(
                    tailMessageID,
                    anchorID: bottomAnchorID
                )
                let frameCheckpoint = messageFrameGeneration
                let animation = navigationAnimation(
                    distance: latestConversationBottomAnchorFrame.map {
                        $0.frame.maxY - scrollViewportHeight
                    },
                    isEdge: true
                )
                traceScrollCommand(
                    source: "navigation.bottom",
                    target: "messageHost:\(ChatBottomTrace.shortID(tailMessageID))",
                    animation: "smooth"
                )
                let tailClearance = activeBottomNavigationTailClearance(
                    for: bottomAnchorID
                )
                if tailClearance > 0 {
                    ChatBottomTrace.log(
                        "EDGE_NAVIGATION_COUPLED_TARGET"
                            + " sequence=\(request.sequence)"
                            + " clearance=\(String(format: "%.1f", tailClearance))"
                            + " sentinel=\(String(format: "%.1f", composerBottomClearance - tailClearance)) "
                            + chatBottomTraceState
                    )
                }
                withAnimation(animation.animation) {
                    scrollProxy.scrollTo(
                        conversationMessageHostID(for: tailMessageID),
                        anchor: .bottom
                    )
                }
                try? await Task.sleep(
                    for: .seconds(animation.duration + 0.06)
                )
                guard await awaitEdgeNavigationPhysicalIdle(
                    request,
                    anchorID: bottomAnchorID
                ) else {
                    await failClosedEdgeNavigation(
                        request,
                        anchorID: bottomAnchorID,
                        using: scrollProxy,
                        preserveViewportOnFailure: true,
                        reason: "animationNotSettled"
                    )
                    return
                }
                guard !Task.isCancelled,
                      navigationRequest == request,
                      currentConversationBottomAnchorID == bottomAnchorID else {
                    return
                }
                guard let scrollView = chatScrollViewBox.scrollView,
                      scrollView.window != nil,
                      !nativeScrollHasActiveTouch(scrollView),
                      !scrollView.isTracking,
                      !scrollView.isDragging,
                      !scrollView.isDecelerating else {
                    // UIKit touch ownership can precede SwiftUI's DragGesture
                    // callback. Do not submit the landing correction in that
                    // recognition gap; defer cleanup leaves the reader detached.
                    return
                }
                guard hasVisibleConcreteTailBottomEdge(
                    tailMessageID,
                    anchorID: bottomAnchorID
                ),
                      tailWasVisible
                        || messageFrameGeneration > frameCheckpoint else {
                    await failClosedEdgeNavigation(
                        request,
                        anchorID: bottomAnchorID,
                        using: scrollProxy,
                        preserveViewportOnFailure: true,
                        reason: "tailBottomNotReady"
                    )
                    return
                }

                if !isCurrentNavigationSentinelExact(
                    request.positionRequest,
                    anchorID: bottomAnchorID
                ) {
                    // One landing correction is permitted only after the real
                    // tail bottom is visible in this exact revision.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    traceScrollCommand(
                        source: "navigation.bottomCorrection",
                        target: "bottomSentinel",
                        animation: "disabled"
                    )
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled,
                      navigationRequest == request,
                      currentConversationBottomAnchorID == bottomAnchorID,
                      isConcreteEdgeBottomLanding(
                        request,
                        anchorID: bottomAnchorID,
                        tailMessageID: tailMessageID
                      ) else {
                    await failClosedEdgeNavigation(
                        request,
                        anchorID: bottomAnchorID,
                        using: scrollProxy,
                        preserveViewportOnFailure: true,
                        reason: "landingNotExact"
                    )
                    return
                }
                didComplete = true
                lastKnownNearBottom = true
                lastMeasuredNearBottom = true
                lastMeasuredAtBottom = true
                isUserScrollActive = false
                autoFollowEngaged = model.preferences.autoScrollEnabled
            }
            keepNavigationVisibleBriefly()
            return
        }
        if model.hasLaterMessages {
            if model.loadLatestMessageWindow() {
                advanceConversationLazyWindowGeneration()
            }
        }
        let animation = navigationAnimation(
            distance: latestConversationBottomAnchorFrame.map { $0.frame.maxY - scrollViewportHeight },
            isEdge: true
        )
        prepareMessageNavigation(for: request.action)
        navigationAnchorMessageID = nil
        let bottomAnchorID = currentConversationBottomAnchorID
        guard bottomAnchorID.positionRequest == request.positionRequest else { return }
        let concreteTailMessageID = bottomAnchorID.messageIDs.last
        let hostHasLaterMessages = model.hasLaterMessages
        let concreteTailHostID = concreteTailMessageID.map {
            conversationMessageHostID(for: $0)
        }
        navigationScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == bottomAnchorID,
                  model.hasLaterMessages == hostHasLaterMessages else { return }
            traceScrollCommand(
                source: "navigation.bottom",
                target: concreteTailMessageID.map {
                    "messageHost:\(ChatBottomTrace.shortID($0))"
                } ?? "bottomSentinel",
                animation: "smooth"
            )
            withAnimation(animation.animation) {
                if let concreteTailHostID {
                    scrollProxy.scrollTo(concreteTailHostID, anchor: .bottom)
                } else {
                    scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            try? await Task.sleep(for: .seconds(animation.duration + 0.06))
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationPositionRequest == request.positionRequest else { return }

            // Lazy layout can settle one frame after the animated target. Permit
            // one token-guarded, non-animated correction, never a retry lease.
            if !isNavigationAtExactBottom(request, anchorID: bottomAnchorID) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "navigation.bottomCorrection",
                    target: "bottomSentinel",
                    animation: "disabled"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == bottomAnchorID else { return }
            let reachedExactBottom = isNavigationAtExactBottom(
                request,
                anchorID: bottomAnchorID
            )
            navigationRequest = nil
            navigationScrollTask = nil
            guard reachedExactBottom else {
                // Geometry remains authoritative. Do not fabricate a bottom fact
                // or hand auto-follow an offset that a user may have interrupted.
                return
            }
            lastKnownNearBottom = true
            lastMeasuredNearBottom = true
            lastMeasuredAtBottom = true
            isUserScrollActive = false
            autoFollowEngaged = model.preferences.autoScrollEnabled
        }
        keepNavigationVisibleBriefly()
    }

    private func isNavigationAtExactBottom(
        _ request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) -> Bool {
        guard scrollViewportHeight > 0,
              let snapshot = latestConversationBottomAnchorFrame,
              snapshot.anchorID == anchorID,
              anchorID.positionRequest == request.positionRequest else { return false }
        return abs(snapshot.frame.maxY - scrollViewportHeight) <= 2
    }

    private func validConcreteMessageFrame(
        _ messageID: UUID,
        anchorID: ConversationBottomAnchorID
    ) -> CGRect? {
        guard currentConversationBottomAnchorID == anchorID,
              anchorID.messageIDs.contains(messageID),
              messageFramesAnchorID == anchorID,
              let frame = messageFrames[messageID],
              frame.minX.isFinite,
              frame.minY.isFinite,
              frame.maxY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else { return nil }
        return frame
    }

    private func hasValidConcreteMessageFrames(
        for anchorID: ConversationBottomAnchorID
    ) -> Bool {
        // This synchronous check owns one current snapshot. Rebuilding the
        // message IDs for each row is redundant; every iterated ID already
        // belongs to this anchor. Never retain this snapshot across an await.
        guard currentConversationBottomAnchorID == anchorID,
              messageFramesAnchorID == anchorID else { return false }
        let frames = messageFrames
        return anchorID.messageIDs.allSatisfy { messageID in
            guard let frame = frames[messageID] else { return false }
            return frame.minX.isFinite
                && frame.minY.isFinite
                && frame.maxY.isFinite
                && frame.width.isFinite
                && frame.height.isFinite
                && frame.width > 0
                && frame.height > 0
        }
    }

    private func hasVisibleConcreteMessageFrame(
        _ messageID: UUID,
        anchorID: ConversationBottomAnchorID
    ) -> Bool {
        guard scrollViewportHeight.isFinite,
              scrollViewportHeight > 0,
              let frame = validConcreteMessageFrame(
                messageID,
                anchorID: anchorID
              ) else { return false }
        return frame.maxY > 0 && frame.minY < scrollViewportHeight
    }

    private func hasVisibleConcreteTailBottomEdge(
        _ tailMessageID: UUID,
        anchorID: ConversationBottomAnchorID
    ) -> Bool {
        guard !model.hasLaterMessages,
              anchorID.messageIDs.last == tailMessageID,
              scrollViewportHeight.isFinite,
              scrollViewportHeight > 0,
              let frame = validConcreteMessageFrame(
                tailMessageID,
                anchorID: anchorID
              ) else { return false }
        return frame.maxY > 0 && frame.maxY <= scrollViewportHeight + 2
    }

    private var selectedStreamingDisplayLeaseCandidate:
        OffscreenStreamingDisplayCandidate? {
        let conversationID = model.selectedConversationID
        guard model.selectedConversationIsStreaming,
              let messageID = model.activeStreamingMessageID(
                for: conversationID
              ),
              currentConversationBottomAnchorID.messageIDs.contains(messageID)
        else { return nil }
        return OffscreenStreamingDisplayCandidate(
            conversationID: conversationID,
            messageID: messageID
        )
    }

    private func updateOffscreenStreamingDisplayLease(
        isScrolling explicitIsScrolling: Bool? = nil,
        isAtBottom explicitIsAtBottom: Bool? = nil,
        isNearBottom explicitIsNearBottom: Bool? = nil
    ) {
        guard scrollViewportHeight.isFinite,
              scrollViewportHeight > 0,
              let candidate = selectedStreamingDisplayLeaseCandidate else {
            releaseOffscreenStreamingDisplayLease(reason: "inactiveStream")
            return
        }

        if let leasedCandidate = offscreenStreamingDisplayState.candidate,
           leasedCandidate != candidate {
            releaseOffscreenStreamingDisplayLease(reason: "streamChanged")
        }

        let anchorID = currentConversationBottomAnchorID
        let tailFrame = validConcreteMessageFrame(
            candidate.messageID,
            anchorID: anchorID
        )
        let lazyTailIsBelow = messageFramesAnchorID == anchorID
            && messageFrames[candidate.messageID] == nil
        let isCurrentlySuspended =
            offscreenStreamingDisplayState.candidate == candidate
        let isScrolling = explicitIsScrolling
            ?? isUserDrivenNativeScrollMotionInFlight
        let isAtBottom = explicitIsAtBottom ?? lastMeasuredAtBottom
        let isNearBottom = explicitIsNearBottom ?? lastMeasuredNearBottom
        if !isScrolling, isAtBottom || isNearBottom {
            offscreenStreamingDisplayState.didUserDetachFromTail = false
        }
        let desiredState = OffscreenStreamingDisplayPolicy.desiredState(
            for: OffscreenStreamingDisplayPolicyInput(
                viewportHeight: scrollViewportHeight,
                userDetachedFromTail:
                    offscreenStreamingDisplayState.didUserDetachFromTail,
                isScrolling: isScrolling,
                isAtBottom: isAtBottom,
                isNearBottom: isNearBottom,
                // The live stream grows at the message's bottom edge. Using
                // minY here was the 4950 bug: minY is the top of one giant
                // reply and can be above the viewport while maxY is far below.
                liveTailMaxY: tailFrame?.maxY,
                lazyTailIsBelowViewport: lazyTailIsBelow,
                isCurrentlySuspended: isCurrentlySuspended
            )
        )

        switch desiredState {
        case .inactive:
            releaseOffscreenStreamingDisplayLease(reason: "tailApproaching")

        case .active:
            guard offscreenStreamingDisplayState.candidate != candidate else {
                return
            }
            offscreenStreamingDisplayState.candidate = candidate
            model.setStreamingTextDisplaySuspended(
                conversationID: candidate.conversationID,
                messageID: candidate.messageID,
                owner: .detachedTail,
                suspended: true
            )
            ChatBottomTrace.log(
                "OFFSCREEN_STREAM_LEASE_BEGIN"
                    + " reason=detachedTail"
                    + " conv=\(ChatBottomTrace.shortID(candidate.conversationID))"
                    + " msg=\(ChatBottomTrace.shortID(candidate.messageID))"
                    + " tailMaxY=\(tailFrame.map { String(format: "%.1f", $0.maxY) } ?? "lazy")"
                    + " viewportH=\(String(format: "%.1f", scrollViewportHeight))"
            )
        }
    }

    private func releaseOffscreenStreamingDisplayLease(reason: String) {
        guard let candidate = offscreenStreamingDisplayState.candidate else {
            if selectedStreamingDisplayLeaseCandidate == nil {
                offscreenStreamingDisplayState.didUserDetachFromTail = false
            }
            return
        }
        offscreenStreamingDisplayState.candidate = nil
        offscreenStreamingDisplayState.didUserDetachFromTail = false
        model.setStreamingTextDisplaySuspended(
            conversationID: candidate.conversationID,
            messageID: candidate.messageID,
            owner: .detachedTail,
            suspended: false
        )
        ChatBottomTrace.log(
            "OFFSCREEN_STREAM_LEASE_END"
                + " reason=\(reason)"
                + " prior=detachedTail"
                + " conv=\(ChatBottomTrace.shortID(candidate.conversationID))"
                + " msg=\(ChatBottomTrace.shortID(candidate.messageID))"
        )
    }

    private func isCurrentNavigationSentinelExact(
        _ positionRequest: ConversationPositionRequestKey,
        anchorID: ConversationBottomAnchorID
    ) -> Bool {
        guard currentConversationBottomAnchorID == anchorID,
              anchorID.positionRequest == positionRequest,
              scrollViewportHeight.isFinite,
              scrollViewportHeight > 0,
              let snapshot = latestConversationBottomAnchorFrame,
              snapshot.anchorID == anchorID,
              snapshot.frame.maxY.isFinite else { return false }
        return abs(snapshot.frame.maxY - scrollViewportHeight) <= 2
    }

    private func isConcreteEdgeBottomLanding(
        _ request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID,
        tailMessageID: UUID
    ) -> Bool {
        guard navigationRequest == request,
              hasVisibleConcreteTailBottomEdge(
                tailMessageID,
                anchorID: anchorID
              ),
              isCurrentNavigationSentinelExact(
                request.positionRequest,
                anchorID: anchorID
              ),
              currentUIKitBottomState?.isAtBottom == true,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              !isNativeScrollAnimating(scrollView) else { return false }
        return true
    }

    private func failClosedEdgeNavigation(
        _ request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID,
        using scrollProxy: ScrollViewProxy,
        preserveViewportOnFailure: Bool = false,
        reason: String
    ) async {
        guard navigationRequest == request,
              currentConversationBottomAnchorID == anchorID else { return }
        ChatBottomTrace.log(
            "EDGE_NAVIGATION_DROP reason=\(reason) " + chatBottomTraceState
        )
        lastKnownNearBottom = false
        lastMeasuredNearBottom = false
        lastMeasuredAtBottom = false
        isUserScrollActive = true
        autoFollowEngaged = false
        // A failed smooth command can outlive its nominal duration by a few
        // display turns. Observe only; do not issue another physical scroll
        // write. If a real touch begins, the user owns the viewport. Otherwise
        // keep the animation's settled viewport instead of forcing a top seed.
        for _ in 0..<12 {
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == anchorID,
                  let scrollView = chatScrollViewBox.scrollView,
                  scrollView.window != nil else { return }
            guard !nativeScrollHasActiveTouch(scrollView),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return }
            if !isNativeScrollAnimating(scrollView) {
                break
            }
            await awaitNextMainQueueTurn()
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard !Task.isCancelled,
              navigationRequest == request,
              currentConversationBottomAnchorID == anchorID,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating else { return }
        if preserveViewportOnFailure {
            ChatBottomTrace.log(
                "EDGE_NAVIGATION_PRESERVE_VIEWPORT reason=\(reason) "
                    + chatBottomTraceState
            )
            return
        }
        // Top navigation's established failure fallback is already the user's
        // requested edge. Preserve it; only failed bottom navigation must not
        // convert into a new top command.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        traceScrollCommand(
            source: "navigation.edgeFailClosed",
            target: "topSeed",
            animation: "disabled"
        )
        withTransaction(transaction) {
            scrollProxy.scrollTo(
                ConversationTopMaterializationSeedID(anchorID: anchorID),
                anchor: .top
            )
        }
    }

    private func awaitEdgeNavigationPhysicalIdle(
        _ request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) async -> Bool {
        // SwiftUI's nominal spring duration can end before the underlying
        // UIScrollView reports its real idle phase while LazyVStack finishes
        // measuring. Observe that existing motion only; do not submit another
        // target or change the accepted animation curve.
        for _ in 0..<12 {
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == anchorID,
                  let scrollView = chatScrollViewBox.scrollView,
                  scrollView.window != nil,
                  !nativeScrollHasActiveTouch(scrollView),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return false }
            if !isNativeScrollAnimating(scrollView) {
                return true
            }
            await awaitNextMainQueueTurn()
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard !Task.isCancelled,
              navigationRequest == request,
              currentConversationBottomAnchorID == anchorID,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating else { return false }
        return !isNativeScrollAnimating(scrollView)
    }

    private func handleMessageWindowEdge(
        _ frame: CGRect,
        direction: MessageWindowLoadDirection,
        using scrollProxy: ScrollViewProxy
    ) {
        // A newly bounded deletion or entry window can expose a paging sentinel.
        // Keep it concrete until the reader actually scrolls toward that edge.
        guard messageReplacementRequest == nil,
              (messageReplacementConcreteWindowSessionID != currentChatViewportSessionID
                && !model.usesConcreteConversationEntryWindow)
                || hasConcreteNativeUserScrollOwnership
                || isVerticalScrollGestureActive else { return }
        guard frame != .zero,
              scrollViewportHeight > 0,
              !isPositioningCurrentConversation,
              !isUserMessageSendPositioning,
              !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              automaticReasoningCollapseOwner == nil,
              messageWindowLoadTask == nil else { return }

        let shouldLoad: Bool
        switch direction {
        case .earlier:
            shouldLoad = model.hasEarlierMessages
                && frame.minY <= 96
                && frame.maxY >= -160
        case .later:
            shouldLoad = model.hasLaterMessages
                && frame.maxY >= scrollViewportHeight - 96
                && frame.minY <= scrollViewportHeight + 160
        }
        guard shouldLoad else { return }

        let now = Date()
        guard now.timeIntervalSince(lastMessageWindowLoadAt) >= 0.12 else { return }
        scheduleMessageWindowLoad(direction: direction, using: scrollProxy)
    }

    private func scheduleMessageWindowLoad(
        direction: MessageWindowLoadDirection,
        using scrollProxy: ScrollViewProxy
    ) {
        guard !isUserMessageSendPositioning,
              !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              messageReplacementRequest == nil,
              messageReplacementLandingTask == nil,
              automaticReasoningCollapseOwner == nil else { return }
        let positionRequest = currentConversationPositionRequest
        let anchorID: UUID?
        let anchor: UnitPoint
        switch direction {
        case .earlier:
            anchorID = model.messages.first?.id
            anchor = .top
        case .later:
            anchorID = model.messages.last?.id
            anchor = .bottom
        }

        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = Task { @MainActor in
            lastMessageWindowLoadAt = Date()
            await Task.yield()
            guard !Task.isCancelled,
                  currentConversationPositionRequest == positionRequest,
                  automaticReasoningCollapseOwner == nil,
                  !isUserMessageSendPositioning,
                  !isMessageTargetNavigationOwned,
                  messageReplacementLandingTask == nil,
                  !ownsCurrentDoubleEdgeNavigation else {
                messageWindowLoadTask = nil
                return
            }
            bottomNavigationCompactWindowConversationID = nil
            let loaded = switch direction {
            case .earlier:
                model.loadEarlierMessages()
            case .later:
                model.loadLaterMessages()
            }
            guard loaded else {
                messageWindowLoadTask = nil
                return
            }
            await Task.yield()
            guard !Task.isCancelled,
                  currentConversationPositionRequest == positionRequest,
                  automaticReasoningCollapseOwner == nil,
                  !isUserMessageSendPositioning,
                  !isMessageTargetNavigationOwned,
                  !ownsCurrentDoubleEdgeNavigation else {
                messageWindowLoadTask = nil
                return
            }
            if let anchorID {
                let hostID = conversationMessageHostID(
                    for: anchorID
                )
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "messageWindow.\(String(describing: direction))",
                    target: "messageHost:\(ChatBottomTrace.shortID(anchorID))",
                    animation: "disabled"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(hostID, anchor: anchor)
                }
            }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled,
                  currentConversationPositionRequest == positionRequest,
                  automaticReasoningCollapseOwner == nil,
                  !isUserMessageSendPositioning,
                  !isMessageTargetNavigationOwned else {
                messageWindowLoadTask = nil
                return
            }
            messageWindowLoadTask = nil
        }
    }

    private func scrollToMessage(
        _ messageID: UUID,
        using scrollProxy: ScrollViewProxy,
        request: MessageNavigationRequest
    ) {
        guard let targetRequest = selectedMessageTargetNavigationRequest,
              targetRequest.messageID == messageID,
              targetRequest.conversationPositionRequest
                == request.positionRequest.request,
              model.messages.contains(where: { $0.id == messageID }) else {
            navigationRequest = nil
            navigationScrollTask = nil
            return
        }

        let hostAnchorID = currentConversationBottomAnchorID
        let hostHasEarlierMessages = model.hasEarlierMessages
        let hostHasLaterMessages = model.hasLaterMessages
        guard hostAnchorID.positionRequest == request.positionRequest else {
            navigationRequest = nil
            navigationScrollTask = nil
            return
        }

        let targetHostID = conversationMessageHostID(for: messageID)
        let animation = navigationAnimation(
            distance: messageFrames[messageID].map {
                $0.minY - navigationGuideY
            },
            isEdge: false
        )
        let ownsViewportTransition =
            regenerationViewportTransitionCoordinator.owns(
                requestID: targetRequest.id
            )
        let usesRegenerationViewportTransition =
            targetRequest.regenerationSourceMessageID != nil
            && ownsViewportTransition
        let prefersCoveredViewportTransition =
            targetRequest.usesCoveredViewportTransition
            || usesRegenerationViewportTransition
        let usesCoveredViewportTransition =
            (targetRequest.usesCoveredViewportTransition
                && ownsViewportTransition)
            || usesRegenerationViewportTransition
        prepareMessageNavigation(for: request.action)
        navigationAnchorMessageID = messageID
        navigationScrollTask = Task { @MainActor in
            var didVerifyLanding = false
            defer {
                if navigationRequest == request {
                    navigationRequest = nil
                    navigationScrollTask = nil
                }
            }
            await awaitNextMainQueueTurn()
            await Task.yield()
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == hostAnchorID,
                  model.hasEarlierMessages == hostHasEarlierMessages,
                  model.hasLaterMessages == hostHasLaterMessages,
                  model.messages.contains(where: { $0.id == messageID }) else {
                return
            }

            if prefersCoveredViewportTransition {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "navigation.messageTarget",
                    target: "messageHost:\(ChatBottomTrace.shortID(messageID))",
                    animation: usesRegenerationViewportTransition
                        ? "disabledBehindViewportSnapshot"
                        : usesCoveredViewportTransition
                            ? "disabledBehindViewportCover"
                            : "disabledCoverUnavailable"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(
                        targetHostID,
                        anchor: .top
                    )
                }
                await awaitNextMainQueueTurn()
            } else {
                traceScrollCommand(
                    source: "navigation.messageTarget",
                    target: "messageHost:\(ChatBottomTrace.shortID(messageID))",
                    animation: "smooth"
                )
                withAnimation(animation.animation) {
                    scrollProxy.scrollTo(
                        targetHostID,
                        anchor: .top
                    )
                }
                try? await Task.sleep(
                    for: .seconds(animation.duration + 0.02)
                )
            }
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationPositionRequest == request.positionRequest else {
                return
            }

            didVerifyLanding = await settleMessageTargetLanding(
                messageID,
                request: request,
                anchorID: hostAnchorID
            )
            guard didVerifyLanding,
                  !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationPositionRequest == request.positionRequest,
                  model.pendingMessageTargetNavigationRequest == targetRequest else {
                ChatBottomTrace.log(
                    "MESSAGE_TARGET_LANDING_RETRY"
                        + " message=\(ChatBottomTrace.shortID(messageID)) "
                        + chatBottomTraceState
                )
                return
            }
            let regenerationSourceMessageID =
                targetRequest.regenerationSourceMessageID
            if isCoveredFavoriteTargetRequest(targetRequest) {
                var loadedEarlierWindow = false
                if model.hasEarlierMessages {
                    // The isolated target window deliberately has no estimated
                    // rows above the landing coordinate. Once that coordinate
                    // is verified, prepend one ordinary lazy page behind the
                    // still-active cover and restore the target as the visible
                    // top anchor before releasing navigation ownership. Relying
                    // on the existing top-edge preference here is insufficient:
                    // it already reported this frame while target navigation
                    // owned paging, so ownership release alone does not emit a
                    // second preference change.
                    loadedEarlierWindow = model.loadEarlierMessages()
                    if loadedEarlierWindow {
                        lastMessageWindowLoadAt = Date()
                        await Task.yield()
                        guard !Task.isCancelled,
                              navigationRequest == request,
                              currentConversationPositionRequest
                                == request.positionRequest,
                              model.pendingMessageTargetNavigationRequest
                                == targetRequest,
                              model.messages.contains(where: {
                                  $0.id == messageID
                              }) else {
                            return
                        }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        traceScrollCommand(
                            source: "favoriteTarget.earlierWindowHandoff",
                            target: "messageHost:\(ChatBottomTrace.shortID(messageID))",
                            animation: "disabledBehindViewportCover"
                        )
                        withTransaction(transaction) {
                            scrollProxy.scrollTo(
                                targetHostID,
                                anchor: .top
                            )
                        }
                        await awaitNextMainQueueTurn()
                        try? await Task.sleep(for: .milliseconds(140))
                        guard !Task.isCancelled,
                              navigationRequest == request,
                              currentConversationPositionRequest
                                == request.positionRequest,
                              model.pendingMessageTargetNavigationRequest
                                == targetRequest else {
                            return
                        }
                    }
                }
                concreteFavoriteTargetMessageID = nil
                landedMessageTargetID = nil
                model.consumeMessageTargetNavigationRequest(targetRequest.id)
                ChatBottomTrace.log(
                    "FAVORITE_TARGET_OWNERSHIP_RELEASED"
                        + " outcome=success"
                        + " earlierWindowLoaded=\(loadedEarlierWindow)"
                        + " request=\(ChatBottomTrace.shortID(targetRequest.id))"
                        + " message=\(ChatBottomTrace.shortID(targetRequest.messageID)) "
                        + chatBottomTraceState
                )
            } else {
                landedMessageTargetID = messageID
                model.consumeMessageTargetNavigationRequest(targetRequest.id)
            }
            if let regenerationSourceMessageID {
                model.regenerateResponse(around: regenerationSourceMessageID)
            }
            if usesCoveredViewportTransition {
                await awaitNextMainQueueTurn()
                await Task.yield()
                regenerationViewportTransitionCoordinator.reveal(
                    requestID: targetRequest.id,
                    reason: regenerationSourceMessageID == nil
                        ? "favoriteTargetLanded"
                        : "landedAndRegenerationStarted"
                )
            }
        }
        keepNavigationVisibleBriefly()
    }

    private func isCurrentMessageTargetNavigation(
        _ messageID: UUID,
        request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) -> Bool {
        navigationRequest == request
            && request.action == .message(messageID)
            && currentConversationBottomAnchorID == anchorID
            && model.messages.contains(where: { $0.id == messageID })
    }

    private func messageTargetLandingWasInterrupted(
        _ scrollView: UIScrollView
    ) -> Bool {
        nativeScrollHasActiveTouch(scrollView)
            || scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
            || isVerticalScrollGestureActive
            || isNativeVerticalScrollMotionArmed
            || isUserScrollActive
    }

    private func stableMessageTargetLandingSnapshot(
        _ messageID: UUID,
        request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) async -> MessageTargetLandingSnapshot? {
        var previousSnapshot: MessageTargetLandingSnapshot?
        var consecutiveStablePasses = 0

        for attempt in 0..<75 {
            if attempt == 0 {
                await awaitNextMainQueueTurn()
            } else {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled,
                  isCurrentMessageTargetNavigation(
                      messageID,
                      request: request,
                      anchorID: anchorID
                  ),
                  let scrollView = chatScrollViewBox.scrollView,
                  scrollView.bounds.height > 0 else {
                return nil
            }
            guard !messageTargetLandingWasInterrupted(scrollView) else {
                ChatBottomTrace.log(
                    "MESSAGE_TARGET_CORRECTION_DROP"
                        + " reason=userMotion"
                        + " message=\(ChatBottomTrace.shortID(messageID)) "
                        + chatBottomTraceState
                )
                return nil
            }
            guard let snapshot = messageTargetLandingSnapshot(
                messageID,
                anchorID: anchorID,
                scrollView: scrollView
            ) else {
                previousSnapshot = nil
                consecutiveStablePasses = 0
                continue
            }

            if let previousSnapshot,
               snapshot.isStable(comparedTo: previousSnapshot) {
                consecutiveStablePasses += 1
            } else {
                consecutiveStablePasses = 1
            }
            previousSnapshot = snapshot
            guard consecutiveStablePasses >= 3 else { continue }

            // `UIScrollView.isScrollAnimating` can remain true after a
            // SwiftUI `scrollTo` has visibly stopped while lazy message rows
            // finish materializing. The concrete target frame, content size,
            // viewport and content offset are the authoritative landing facts.
            // Requiring them all to agree across multiple samples keeps a real
            // animation moving, but does not let a stale native flag block the
            // exact-message correction forever.
            if isNativeScrollAnimating(scrollView) {
                ChatBottomTrace.log(
                    "MESSAGE_TARGET_ANIMATION_FLAG_BYPASSED"
                        + " message=\(ChatBottomTrace.shortID(messageID)) "
                        + chatBottomTraceState
                )
            }
            return snapshot
        }

        ChatBottomTrace.log(
            "MESSAGE_TARGET_CORRECTION_DROP"
                + " reason=unstableGeometry"
                + " message=\(ChatBottomTrace.shortID(messageID)) "
                + chatBottomTraceState
        )
        return nil
    }

    private func messageTargetLandingSnapshot(
        _ messageID: UUID,
        anchorID: ConversationBottomAnchorID,
        scrollView: UIScrollView
    ) -> MessageTargetLandingSnapshot? {
        guard messageFramesAnchorID == anchorID,
              let targetFrame = messageFrames[messageID] else {
            return nil
        }
        let snapshot = MessageTargetLandingSnapshot(
            scrollViewIdentity: ObjectIdentifier(scrollView),
            targetFrame: targetFrame,
            contentSize: scrollView.contentSize,
            viewportSize: scrollView.bounds.size,
            contentOffset: scrollView.contentOffset,
            insetTop: scrollView.adjustedContentInset.top,
            insetBottom: scrollView.adjustedContentInset.bottom
        )
        return snapshot.isFinite ? snapshot : nil
    }

    private func settleMessageTargetLanding(
        _ messageID: UUID,
        request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) async -> Bool {
        for _ in 0..<3 {
            guard let landingSnapshot = await stableMessageTargetLandingSnapshot(
                messageID,
                request: request,
                anchorID: anchorID
            ) else {
                continue
            }
            guard let expectation = applyMessageTargetLandingCorrection(
                landingSnapshot,
                messageID: messageID,
                request: request,
                anchorID: anchorID
            ) else {
                continue
            }
            if await confirmMessageTargetLanding(
                messageID,
                expectedMinY: expectation.expectedMinY,
                wasClamped: expectation.wasClamped,
                request: request,
                anchorID: anchorID
            ) {
                return true
            }
        }
        return false
    }

    private func applyMessageTargetLandingCorrection(
        _ snapshot: MessageTargetLandingSnapshot,
        messageID: UUID,
        request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) -> (expectedMinY: CGFloat, wasClamped: Bool)? {
        guard isCurrentMessageTargetNavigation(
            messageID,
            request: request,
            anchorID: anchorID
        ),
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.bounds.height > 0,
              !messageTargetLandingWasInterrupted(scrollView) else {
            return nil
        }
        guard let liveSnapshot = messageTargetLandingSnapshot(
            messageID,
            anchorID: anchorID,
            scrollView: scrollView
        ),
              liveSnapshot.isStable(comparedTo: snapshot) else {
            ChatBottomTrace.log(
                "MESSAGE_TARGET_CORRECTION_DROP"
                    + " reason=geometryChangedBeforeApply"
                    + " message=\(ChatBottomTrace.shortID(messageID)) "
                + chatBottomTraceState
            )
            return nil
        }

        let minimumOffsetY = -liveSnapshot.insetTop
        let maximumOffsetY = max(
            minimumOffsetY,
            liveSnapshot.contentSize.height
                - liveSnapshot.viewportSize.height
                + liveSnapshot.insetBottom
        )
        let requestedOffsetY = liveSnapshot.contentOffset.y
            + liveSnapshot.targetFrame.minY
            - navigationGuideY
        let correctedOffsetY = min(
            max(requestedOffsetY, minimumOffsetY),
            maximumOffsetY
        )
        guard requestedOffsetY.isFinite,
              correctedOffsetY.isFinite else {
            return nil
        }

        let appliedDistance = correctedOffsetY - liveSnapshot.contentOffset.y
        let wasClamped = abs(correctedOffsetY - requestedOffsetY) > 0.75
        let expectedMinY = liveSnapshot.targetFrame.minY - appliedDistance
        ChatBottomTrace.log(
            "MESSAGE_TARGET_CORRECTION"
                + " message=\(ChatBottomTrace.shortID(messageID))"
                + " frameMinY=\(String(format: "%.1f", liveSnapshot.targetFrame.minY))"
                + " guideY=\(String(format: "%.1f", navigationGuideY))"
                + " delta=\(String(format: "%.1f", appliedDistance))"
                + " clamped=\(wasClamped) "
                + chatBottomTraceState
        )
        guard abs(appliedDistance) > 1 else {
            return (expectedMinY, wasClamped)
        }

        traceScrollCommand(
            source: "navigation.messageTargetCorrection",
            target: "messageHost:\(ChatBottomTrace.shortID(messageID))",
            animation: "disabled"
        )
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(
                CGPoint(
                    x: liveSnapshot.contentOffset.x,
                    y: correctedOffsetY
                ),
                animated: false
            )
        }
        return (expectedMinY, wasClamped)
    }

    private func confirmMessageTargetLanding(
        _ messageID: UUID,
        expectedMinY: CGFloat,
        wasClamped: Bool,
        request: MessageNavigationRequest,
        anchorID: ConversationBottomAnchorID
    ) async -> Bool {
        var previousConfirmedSnapshot: MessageTargetLandingSnapshot?
        var consecutiveStablePasses = 0
        for attempt in 0..<45 {
            if attempt == 0 {
                await awaitNextMainQueueTurn()
            } else {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled,
                  isCurrentMessageTargetNavigation(
                      messageID,
                      request: request,
                      anchorID: anchorID
                  ),
                  let scrollView = chatScrollViewBox.scrollView,
                  scrollView.bounds.height > 0 else {
                return false
            }
            guard !messageTargetLandingWasInterrupted(scrollView) else {
                return false
            }
            guard let snapshot = messageTargetLandingSnapshot(
                messageID,
                anchorID: anchorID,
                scrollView: scrollView
            ) else {
                previousConfirmedSnapshot = nil
                consecutiveStablePasses = 0
                continue
            }
            let error = abs(snapshot.targetFrame.minY - expectedMinY)
            let isVisible = snapshot.targetFrame.maxY > 1
                && snapshot.targetFrame.minY < snapshot.viewportSize.height - 1
            guard error <= 2.5, isVisible else {
                previousConfirmedSnapshot = nil
                consecutiveStablePasses = 0
                continue
            }
            if let previousConfirmedSnapshot,
               snapshot.isStable(comparedTo: previousConfirmedSnapshot) {
                consecutiveStablePasses += 1
            } else {
                consecutiveStablePasses = 1
            }
            previousConfirmedSnapshot = snapshot
            guard consecutiveStablePasses >= 3 else { continue }
            ChatBottomTrace.log(
                "MESSAGE_TARGET_LANDING_VERIFIED"
                    + " message=\(ChatBottomTrace.shortID(messageID))"
                    + " minY=\(String(format: "%.1f", snapshot.targetFrame.minY))"
                    + " expected=\(String(format: "%.1f", expectedMinY))"
                    + " error=\(String(format: "%.2f", error))"
                    + " clamped=\(wasClamped) "
                    + " stablePasses=\(consecutiveStablePasses) "
                    + chatBottomTraceState
            )
            return true
        }
        return false
    }

    private func scrollToAdjacentUserMessage(
        direction: Int,
        using scrollProxy: ScrollViewProxy,
        request: MessageNavigationRequest
    ) {
        let indexedUsers = model.messages.enumerated().compactMap { index, message in
            message.role == .user ? (index, message.id) : nil
        }
        guard !indexedUsers.isEmpty else {
            if direction < 0 {
                scrollToTop(using: scrollProxy, request: request)
            } else {
                scrollToBottom(using: scrollProxy, request: request)
            }
            return
        }

        let storedAnchor = navigationAnchorMessageID.flatMap { id in
            model.messages.firstIndex { $0.id == id }
        }
        let geometryTarget: (offset: Int, element: UUID)? = storedAnchor == nil
            ? (direction < 0
                ? indexedUsers.last(where: { entry in
                    guard let frame = messageFrames[entry.1] else { return false }
                    return frame.minY < navigationGuideY - 6
                })
                : indexedUsers.first(where: { entry in
                    guard let frame = messageFrames[entry.1] else { return false }
                    return frame.minY > navigationGuideY + 6
                }))
            : nil
        let visibleIndexes = messageFrames.compactMap { id, frame -> Int? in
            let isVisible = frame.maxY >= 0
                && (scrollViewportHeight <= 0 || frame.minY <= scrollViewportHeight - 110)
            guard isVisible else { return nil }
            return model.messages.firstIndex { $0.id == id }
        }.sorted()
        let referenceIndex = storedAnchor
            ?? (direction < 0 ? visibleIndexes.first : visibleIndexes.last)
            ?? (direction < 0 ? model.messages.count : -1)

        let target = geometryTarget ?? (direction < 0
            ? indexedUsers.last(where: { $0.0 < referenceIndex })
            : indexedUsers.first(where: { $0.0 > referenceIndex }))
        guard let target else {
            navigationAnchorMessageID = nil
            if direction < 0 {
                scrollToTop(using: scrollProxy, request: request)
            } else {
                scrollToBottom(using: scrollProxy, request: request)
            }
            return
        }

        let animation = navigationAnimation(
            distance: messageFrames[target.1].map { $0.minY - navigationGuideY },
            isEdge: false
        )
        let hostAnchorID = currentConversationBottomAnchorID
        let hostHasLaterMessages = model.hasLaterMessages
        guard hostAnchorID.positionRequest == request.positionRequest else { return }
        let targetHostID = conversationMessageHostID(
            for: target.1
        )
        prepareMessageNavigation(for: request.action)
        navigationAnchorMessageID = target.1
        navigationScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationBottomAnchorID == hostAnchorID,
                  model.hasLaterMessages == hostHasLaterMessages else { return }
            guard model.messages.contains(where: { $0.id == target.1 }) else {
                navigationRequest = nil
                navigationScrollTask = nil
                return
            }
            traceScrollCommand(
                source: "navigation.adjacentUser",
                target: "messageHost:\(ChatBottomTrace.shortID(target.1))",
                animation: "smooth"
            )
            withAnimation(animation.animation) {
                scrollProxy.scrollTo(targetHostID, anchor: navigationLandingAnchor)
            }
            try? await Task.sleep(for: .seconds(animation.duration + 0.02))
            guard !Task.isCancelled,
                  navigationRequest == request,
                  currentConversationPositionRequest == request.positionRequest else { return }
            navigationRequest = nil
            navigationScrollTask = nil
        }
        keepNavigationVisibleBriefly()
    }

    private func handleScrollActivity(
        isScrolling: Bool,
        isAtBottom: Bool? = nil,
        isNearBottom: Bool
    ) {
        lastKnownNearBottom = isNearBottom
        if isMessageTargetNavigationOwned {
            autoFollowEngaged = false
            return
        }
        if ownsCurrentDoubleEdgeNavigation {
            autoFollowEngaged = false
            return
        }

        if isScrolling {
            keyboardViewportPinTask?.cancel()
            keyboardViewportPinTask = nil
            // A keyboard dismissal requested during native bottom bounce must
            // survive until the scroll phase reaches its real idle boundary.
            if pendingKeyboardDismissalDeadline == nil,
               pendingKeyboardViewportPin == nil {
                invalidateKeyboardDismissalTransition()
            }
            userScrollIdleTask?.cancel()
            userScrollIdleTask = nil
            streamFollowTask?.cancel()
            streamFollowTask = nil
            conversationReturnTask?.cancel()
            conversationReturnTask = nil
            layoutFollowTask?.cancel()
            layoutFollowTask = nil
            isUserScrollActive = true
            if !isNearBottom {
                autoFollowEngaged = false
            }
            return
        }

        if isAtBottom ?? isNearBottom {
            userScrollIdleTask?.cancel()
            userScrollIdleTask = nil
            isUserScrollActive = false
            autoFollowEngaged = model.preferences.autoScrollEnabled
                && !model.hasLaterMessages
                && hasCurrentConcreteLatestBottomContent
        } else {
            scheduleUserScrollIdleReset()
        }
    }

    private func handleViewportScrollActivity(
        isScrolling: Bool,
        isAtBottom: Bool,
        isNearBottom: Bool
    ) {
        if isMessageTargetNavigationOwned {
            lastKnownNearBottom = isNearBottom
            autoFollowEngaged = false
            return
        }
        if keyboardScrollActivityIgnoreUntil > Date() {
            ChatBottomTrace.log(
                "SCROLL_IGNORE scrolling=\(isScrolling) exact=\(isAtBottom) near=\(isNearBottom)"
                    + " userBefore=\(isUserScrollActive) gesture=\(isVerticalScrollGestureActive)"
                    + " armed=\(isNativeVerticalScrollMotionArmed)"
                    + " remaining=\(ChatBottomTrace.remaining(until: keyboardScrollActivityIgnoreUntil))"
            )
            if isAtBottom,
               !model.hasLaterMessages,
               !ownsCurrentDoubleEdgeNavigation,
               hasCurrentConcreteLatestBottomContent {
                lastKnownNearBottom = true
                autoFollowEngaged = model.preferences.autoScrollEnabled
            } else if model.hasLaterMessages || ownsCurrentDoubleEdgeNavigation {
                autoFollowEngaged = false
            }
            isUserScrollActive = false
            return
        }
        handleScrollActivity(
            isScrolling: isScrolling,
            isAtBottom: isAtBottom,
            isNearBottom: isNearBottom
        )
    }

    private func deletionLandingTargetID(for message: ChatMessage) -> UUID? {
        guard message.role == .assistant else { return nil }
        return model.deletionLandingUserMessageID(
            before: message.id,
            in: message.conversationID
        )
    }

    private func performMessageViewportEdit(_ request: MessageReplacementViewportRequest) {
        switch request.edit {
        case .replacement(let message, let replacement):
            model.selectVersion(replacement.version, for: message.id)
        case .deletion(let message, let allVersions):
            performMessageDeletion(message, deletesAllVersions: allVersions)
        case .codeDisclosure(_, let change, _):
            change.state.commit(request.id)
        }
    }

    private func performMessageDeletion(
        _ message: ChatMessage,
        deletesAllVersions: Bool
    ) {
        if deletesAllVersions {
            model.deleteAllMessageVersions(message.id)
        } else {
            model.deleteMessage(message.id)
        }
    }

    private func messageReplacementLandingWasInterrupted(
        _ scrollView: UIScrollView,
        expectedScrollViewIdentity: ObjectIdentifier
    ) -> Bool {
        ObjectIdentifier(scrollView) != expectedScrollViewIdentity
            || nativeScrollHasActiveTouch(scrollView)
            || scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
            || isNativeScrollAnimating(scrollView)
            || isVerticalScrollGestureActive
            || isNativeVerticalScrollMotionArmed
    }

    private func prepareForMessageReplacementLanding() {
        cancelAutomaticReasoningCollapseOwner(reason: "messageReplacement")
        invalidateVersionReplacement(reason: "messageReplacement")
        streamFollowTask?.cancel()
        streamFollowTask = nil
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = nil
        bottomRowMaterializationTask?.cancel()
        bottomRowMaterializationTask = nil
        pendingBottomRowMaterializationAnchorID = nil
        autoFollowEngaged = false
    }

    private func applyMessageReplacementLandingCorrection(
        targetMessageID: UUID,
        desiredMinY: CGFloat,
        anchorID: ConversationBottomAnchorID,
        expectedScrollViewIdentity: ObjectIdentifier
    ) -> Bool {
        guard currentConversationBottomAnchorID == anchorID,
              let targetFrame = validConcreteMessageFrame(
                targetMessageID,
                anchorID: anchorID
              ),
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              scrollView.bounds.height > 0,
              scrollView.contentOffset.y.isFinite,
              scrollView.contentSize.height.isFinite,
              !messageReplacementLandingWasInterrupted(
                scrollView,
                expectedScrollViewIdentity: expectedScrollViewIdentity
              ) else { return false }

        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let requestedOffsetY = scrollView.contentOffset.y
            + targetFrame.minY
            - desiredMinY
        let correctedOffsetY = min(
            max(requestedOffsetY, minimumOffsetY),
            maximumOffsetY
        )
        guard correctedOffsetY.isFinite else { return false }

        if abs(correctedOffsetY - scrollView.contentOffset.y) > 0.75 {
            traceScrollCommand(
                source: "messageReplacement.correctTarget",
                target: "messageHost:\(ChatBottomTrace.shortID(targetMessageID))",
                animation: "disabled"
            )
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(
                    CGPoint(
                        x: scrollView.contentOffset.x,
                        y: correctedOffsetY
                    ),
                    animated: false
                )
            }
        }
        return true
    }

    private func finishMessageReplacementAutoFollow(
        sourceWasAutoFollowEngaged: Bool,
        sourceWasAtBottom: Bool
    ) {
        let bottomState = refreshMeasuredBottomStateFromUIKit()
        lastKnownNearBottom = bottomState.isNearBottom
        lastMeasuredNearBottom = bottomState.isNearBottom
        lastMeasuredAtBottom = bottomState.isAtBottom
        autoFollowEngaged = sourceWasAutoFollowEngaged
            && sourceWasAtBottom
            && bottomState.isAtBottom
            && model.preferences.autoScrollEnabled
            && !model.hasLaterMessages
            && hasCurrentConcreteLatestBottomContent
    }

    private func deleteMessagePreservingReadingPosition(
        _ message: ChatMessage,
        deletesAllVersions: Bool
    ) {
        cancelMessageReplacementLanding()
        guard message.conversationID == model.selectedConversationID,
              !model.isConversationStreaming(message.conversationID),
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !messageReplacementLandingWasInterrupted(
                  scrollView,
                  expectedScrollViewIdentity: ObjectIdentifier(scrollView)
              ) else {
            performMessageDeletion(message, deletesAllVersions: deletesAllVersions)
            return
        }

        let sourceAnchorID = currentConversationBottomAnchorID
        let precedingUserID = deletionLandingTargetID(for: message)
        // Prefer the old user-row semantics if it is actually visible. Otherwise
        // keep a surviving visible row; a full-screen deleted row needs an ID
        // landing instead of waiting for an offscreen user to produce a frame.
        let visibleIDs = sourceAnchorID.messageIDs.filter { id in
            guard id != message.id,
                  let frame = validConcreteMessageFrame(id, anchorID: sourceAnchorID)
            else { return false }
            return frame.maxY > 0 && frame.minY < max(0, scrollViewportHeight - composerBottomClearance)
        }
        let readingAnchorID = precedingUserID.flatMap {
            visibleIDs.contains($0) ? $0 : nil
        } ?? visibleIDs.first
        let request = MessageReplacementViewportRequest(
            id: UUID(),
            edit: .deletion(message, allVersions: deletesAllVersions),
            sourceAnchorID: sourceAnchorID,
            scrollViewIdentity: ObjectIdentifier(scrollView),
            readingAnchorID: readingAnchorID,
            readingAnchorMinY: readingAnchorID.flatMap {
                validConcreteMessageFrame($0, anchorID: sourceAnchorID)?.minY
            },
            precedingUserID: precedingUserID,
            sourceWasAutoFollowEngaged: autoFollowEngaged,
            sourceWasAtBottom: currentUIKitBottomState?.isAtBottom == true
        )
        prepareForMessageReplacementLanding()
        messageReplacementRequest = request
        ChatBottomTrace.log(
            "MESSAGE_REPLACEMENT_BEGIN request=\(ChatBottomTrace.shortID(request.id))"
                + " deleted=\(ChatBottomTrace.shortID(message.id))"
                + " visibleAnchor=\(readingAnchorID.map(ChatBottomTrace.shortID) ?? "nil") "
                + chatBottomTraceState
        )
    }

    private func commitMessageReplacementAfterRelease(
        _ requestID: UUID,
        sourceAnchorID: ConversationBottomAnchorID,
        using scrollProxy: ScrollViewProxy
    ) {
        guard var request = messageReplacementRequest,
              request.id == requestID,
              !request.didCommit else { return }
        guard sourceAnchorID == request.sourceAnchorID,
              currentConversationBottomAnchorID == sourceAnchorID,
              let scrollView = chatScrollViewBox.scrollView,
              !messageReplacementLandingWasInterrupted(
                  scrollView, expectedScrollViewIdentity: request.scrollViewIdentity
              ) else {
            cancelMessageReplacementLanding()
            return
        }
        // Mark committed before touching the model: a cancellation can discard
        // viewport work, but must never repeat or lose the explicit deletion.
        request.didCommit = true
        messageReplacementRequest = request
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            performMessageViewportEdit(request)
            if let replacement = request.replacementMessage {
                request.targetMessageID = currentConversationBottomAnchorID.messageIDs.contains(replacement.id) ? replacement.id : nil
            } else if request.codeDisclosure != nil {
                request.targetMessageID = request.message.id
            } else {
                request.targetMessageID = MessageDeletionLandingPolicy.targetID(
                deletedID: request.message.id,
                readingAnchorID: request.readingAnchorID,
                precedingUserID: request.precedingUserID,
                sourceIDs: sourceAnchorID.messageIDs,
                survivingIDs: currentConversationBottomAnchorID.messageIDs
                )
            }
            if let targetID = request.targetMessageID,
               model.limitMessageWindowForConcreteLayout(around: targetID) {
                messageReplacementConcreteWindowSessionID = currentChatViewportSessionID
            }
            request.landingAnchorID = currentConversationBottomAnchorID
            messageReplacementRequest = request
        }
        guard request.targetMessageID != nil else {
            request.codeDisclosure?.state.finish(request.id)
            messageReplacementRequest = nil
            releaseCodeDisclosureDisplay(request)
            return
        }
        ChatBottomTrace.log(
            "MESSAGE_REPLACEMENT_WINDOW request=\(ChatBottomTrace.shortID(requestID))"
                + " rows=\(currentConversationBottomAnchorID.messageIDs.count) "
                + chatBottomTraceState
        )
        // One initial opportunity after the view update. Subsequent progress is
        // driven by actual row/bottom geometry callbacks, never by a retry loop.
        messageReplacementLandingTask = Task { @MainActor in
            await awaitNextMainQueueTurn()
            guard !Task.isCancelled,
                  messageReplacementRequest?.id == requestID else { return }
            messageReplacementLandingTask = nil
            advanceMessageReplacementIfReady(using: scrollProxy)
        }
    }

    private func messageReplacementLayoutWaitReason(
        _ request: MessageReplacementViewportRequest
    ) -> String? {
        guard let anchorID = request.landingAnchorID,
              anchorID == currentConversationBottomAnchorID,
              messageReplacementConcreteWindowSessionID == currentChatViewportSessionID else {
            return "windowNotCurrent"
        }
        guard let targetID = request.targetMessageID,
              validConcreteMessageFrame(targetID, anchorID: anchorID) != nil else {
            return "targetFrameMissing"
        }
        if let change = request.codeDisclosure {
            guard let codeSize = request.codeLayoutSize,
                  change.state.layoutRequestID == request.id else { return "codeLayoutPending" }
            guard messageFramesLayoutRequestID == request.id else { return "messageLayoutPending" }
            guard let scrollView = chatScrollViewBox.scrollView,
                  let codeFrame = change.state.anchor.frameInWindow(matching: scrollView),
                  abs(codeFrame.width - codeSize.width) <= 2,
                  abs(codeFrame.height - codeSize.height) <= 2 else {
                return "codeAnchorPending"
            }
        }
        guard let bottom = latestConversationBottomAnchorFrame,
              bottom.anchorID == anchorID else { return "bottomFrameMissing" }
        if request.codeDisclosure != nil, bottom.layoutRequestID != request.id {
            return "bottomLayoutPending"
        }
        guard let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil else { return "scrollViewMissing" }
        guard !messageReplacementLandingWasInterrupted(
            scrollView, expectedScrollViewIdentity: request.scrollViewIdentity
        ) else { return "scrollInterrupted" }
        // The content wrapper fills at least one viewport; its trailing
        // underflow space sits after the intrinsic bottom sentinel.
        let measuredContentEnd = max(
            bottom.frame.maxY + scrollView.contentOffset.y,
            conversationContentMinimumHeight
        )
        guard measuredContentEnd.isFinite, scrollView.contentSize.height.isFinite,
              scrollView.bounds.height > 0 else { return "geometryInvalid" }
        guard abs(measuredContentEnd - scrollView.contentSize.height) <= 2 else {
            return "geometryMismatch"
        }
        return nil
    }

    private func messageReplacementDesiredMinY(_ request: MessageReplacementViewportRequest) -> CGFloat? {
        guard request.replacementMessage != nil || request.codeDisclosure != nil,
              let anchorID = request.landingAnchorID,
              let targetID = request.targetMessageID,
              let frame = validConcreteMessageFrame(targetID, anchorID: anchorID),
              let scrollView = chatScrollViewBox.scrollView else { return nil }
        if request.keepsExactBottom {
            let maximumOffset = max(-scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            return frame.minY + scrollView.contentOffset.y - maximumOffset
        }
        if case .codeDisclosure(_, let change, let sourceEdgeY) = request.edit {
            guard let codeFrame = change.state.anchor.frameInWindow(matching: scrollView) else { return nil }
            return frame.minY + sourceEdgeY - change.edge.position(in: codeFrame)
        }
        return request.readingAnchorMaxY.map {
            min($0, max(1, scrollViewportHeight - composerBottomClearance)) - frame.height
        }
    }

    private func advanceMessageReplacementIfReady(using scrollProxy: ScrollViewProxy) {
        guard let request = messageReplacementRequest,
              request.didCommit, !request.didIssueLanding,
              let anchorID = request.landingAnchorID,
              let targetID = request.targetMessageID else { return }
        if let reason = messageReplacementLayoutWaitReason(request) {
            if messageReplacementRequest?.layoutWaitReason != reason {
                messageReplacementRequest?.layoutWaitReason = reason
                ChatBottomTrace.log(
                    "MESSAGE_REPLACEMENT_WAIT request=\(ChatBottomTrace.shortID(request.id))"
                        + " reason=\(reason) " + chatBottomTraceState
                )
            }
            return
        }
        messageReplacementRequest?.didIssueLanding = true
        messageReplacementLandingTask?.cancel()
        ChatBottomTrace.log(
            "MESSAGE_REPLACEMENT_LAYOUT_READY request=\(ChatBottomTrace.shortID(request.id)) "
                + chatBottomTraceState
        )
        let desiredMinY = messageReplacementDesiredMinY(request)
        if let desiredMinY,
           applyMessageReplacementLandingCorrection(targetMessageID: targetID, desiredMinY: desiredMinY,
                anchorID: anchorID, expectedScrollViewIdentity: request.scrollViewIdentity) {
            // Preserve the requested code/reply edge or the exact bottom.
        } else if request.readingAnchorID == targetID,
           let desiredMinY = request.readingAnchorMinY,
           applyMessageReplacementLandingCorrection(
               targetMessageID: targetID,
               desiredMinY: desiredMinY,
               anchorID: anchorID,
               expectedScrollViewIdentity: request.scrollViewIdentity
           ) {
            // Keep the reader's visible row in the same screen position.
        } else {
            traceScrollCommand(
                source: "messageReplacement.realRow",
                target: "messageHost:\(ChatBottomTrace.shortID(targetID))",
                animation: "disabled"
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(conversationMessageHostID(for: targetID), anchor: .top)
            }
        }
        messageReplacementLandingTask = Task { @MainActor in
            await awaitNextMainQueueTurn()
            guard !Task.isCancelled,
                  messageReplacementRequest?.id == request.id else { return }
            messageReplacementLandingTask = nil
            finishMessageReplacementIfReady()
        }
    }

    private func finishMessageReplacementIfReady() {
        guard let request = messageReplacementRequest,
              request.didCommit, request.didIssueLanding,
              messageReplacementLayoutWaitReason(request) == nil,
              let anchorID = request.landingAnchorID,
              anchorID == currentConversationBottomAnchorID,
              let targetID = request.targetMessageID,
              let frame = validConcreteMessageFrame(targetID, anchorID: anchorID),
              frame.maxY > 0, frame.minY < max(0, scrollViewportHeight - composerBottomClearance),
              let scrollView = chatScrollViewBox.scrollView,
              !messageReplacementLandingWasInterrupted(
                  scrollView, expectedScrollViewIdentity: request.scrollViewIdentity
              ) else { return }
        if let desiredMinY = messageReplacementDesiredMinY(request) {
            let minimumOffset = -scrollView.adjustedContentInset.top
            let maximumOffset = max(minimumOffset,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let expectedOffset = min(max(scrollView.contentOffset.y + frame.minY - desiredMinY,
                minimumOffset), maximumOffset)
            guard expectedOffset.isFinite, abs(scrollView.contentOffset.y - expectedOffset) <= 2 else { return }
        }
        MessageTextViewportDrawing.refreshAfterLayout(in: scrollView)
        request.codeDisclosure?.state.finish(request.id, didLand: true)
        messageReplacementRequest = nil
        messageReplacementLandingTask?.cancel()
        messageReplacementLandingTask = nil
        finishMessageReplacementAutoFollow(
            sourceWasAutoFollowEngaged: request.sourceWasAutoFollowEngaged,
            sourceWasAtBottom: request.sourceWasAtBottom
        )
        // Rejoin bottom following before publishing the buffered stream. The
        // visual feedback does not hold this lease or delay new text.
        releaseCodeDisclosureDisplay(request)
        ChatBottomTrace.log(
            "MESSAGE_REPLACEMENT_LANDED request=\(ChatBottomTrace.shortID(request.id))"
                + " target=\(ChatBottomTrace.shortID(targetID)) mode=realRow "
                + chatBottomTraceState
        )
    }

    private func cancelMessageReplacementLanding() {
        let pending = messageReplacementRequest
        messageReplacementRequest = nil
        messageReplacementLandingTask?.cancel()
        messageReplacementLandingTask = nil
        if let pending {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Persist explicit model edits even if their positioning is
                // interrupted. An uncommitted display-only fold can yield to
                // the user's drag without changing height in the old lazy host.
                if !pending.didCommit, pending.codeDisclosure == nil {
                    performMessageViewportEdit(pending)
                }
                pending.codeDisclosure?.state.finish(pending.id)
            }
            releaseCodeDisclosureDisplay(pending)
        }
    }

    private func scheduleUserScrollIdleReset() {
        userScrollIdleTask?.cancel()
        let delay = model.preferences.autoScrollIdleSeconds
        userScrollIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // iOS 17 has no SwiftUI scroll-geometry callback. Refresh from the
            // concrete UIScrollView before deciding whether the reader really
            // returned to the exact bottom during the idle interval.
            let bottomState = refreshMeasuredBottomStateFromUIKit()
            lastKnownNearBottom = bottomState.isNearBottom
            isUserScrollActive = false
            // 和旧 Kelivo 一致：离开底部后仍保持脱钩，绝不在计时结束时抢滚动。
            autoFollowEngaged = model.preferences.autoScrollEnabled
                && bottomState.isAtBottom
                && !model.hasLaterMessages
                && hasCurrentConcreteLatestBottomContent
        }
    }

    private func cancelUserMessageSendPositioning(
        consumingPendingRequest: Bool
    ) {
        let hadActiveTask = userMessageSendPositionTask != nil
            || activeUserMessageSendPositionRequestID != nil
        userMessageSendPositionTask?.cancel()
        userMessageSendPositionTask = nil
        activeUserMessageSendPositionRequestID = nil
        activeUserMessageSendPositionTaskID = nil
        clearSendPositionNativeRelease()
        keyboardUnifiedSendHandoff = nil
        if consumingPendingRequest,
           let request = model.pendingUserMessageSendPositionRequest,
           request.conversationID == model.selectedConversationID {
            model.consumeUserMessageSendPositionRequest(request.id)
        }
        if hadActiveTask {
            ChatBottomTrace.log(
                "SEND_POSITION_CANCEL consume=\(consumingPendingRequest) "
                    + chatBottomTraceState
            )
        }
    }

    private func clearUserMessageSendPositioningTask(
        for requestID: UUID,
        taskID: UUID
    ) {
        guard activeUserMessageSendPositionRequestID == requestID,
              activeUserMessageSendPositionTaskID == taskID else { return }
        userMessageSendPositionTask = nil
        activeUserMessageSendPositionRequestID = nil
        activeUserMessageSendPositionTaskID = nil
        clearSendPositionNativeRelease(for: requestID)
        if keyboardUnifiedSendHandoff?.requestID == requestID {
            keyboardUnifiedSendHandoff = nil
        }
    }

    private func clearSendPositionNativeRelease(for requestID: UUID? = nil) {
        if requestID == nil
            || sendPositionNativeReleaseRequest?.requestID == requestID {
            sendPositionNativeReleaseRequest = nil
        }
        if requestID == nil
            || acknowledgedSendPositionNativeRelease?.requestID == requestID {
            acknowledgedSendPositionNativeRelease = nil
        }
    }

    private func abandonUserMessageSendPositioningTask(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID
    ) {
        guard activeUserMessageSendPositionRequestID == request.id,
              activeUserMessageSendPositionTaskID == taskID else { return }
        if model.releaseSendPresentationGate(request.id) {
            ChatBottomTrace.log(
                "SEND_PRESENTATION_RELEASE reason=positionTaskAbandoned"
                    + " request=\(ChatBottomTrace.shortID(request.id)) "
                    + chatBottomTraceState
            )
        }
        clearUserMessageSendPositioningTask(for: request.id, taskID: taskID)
        model.consumeUserMessageSendPositionRequest(request.id)
    }

    private func isCurrentUserMessageSendPositionRequest(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID
    ) -> Bool {
        activeUserMessageSendPositionRequestID == request.id
            && activeUserMessageSendPositionTaskID == taskID
            && model.pendingUserMessageSendPositionRequest == request
            && model.selectedConversationID == request.conversationID
            && model.messages.contains(where: { $0.id == request.messageID })
            && !model.isDrawerPresented
    }

    private func beginKeyboardUnifiedSendHandoff(requestID: UUID) {
        guard isComposerKeyboardPresented,
              activeUserMessageSendPositionRequestID == nil,
              let request = model.pendingUserMessageSendPositionRequest,
              request.id == requestID,
              let gate = model.sendPresentationGate,
              gate.requestID == requestID,
              gate.conversationID == request.conversationID,
              gate.userMessageID == request.messageID,
              isSendPresentationUserFrameReady(request),
              let userFrame = validConcreteMessageFrame(
                request.messageID,
                anchorID: currentConversationBottomAnchorID
              ),
              userFrame.maxY > 0,
              userFrame.minY < scrollViewportHeight,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              !isNativeScrollAnimating(scrollView) else { return }

        let handoff = KeyboardUnifiedSendHandoff(
            requestID: requestID,
            conversationID: gate.conversationID,
            userMessageID: gate.userMessageID,
            assistantMessageID: gate.assistantMessageID
        )
        keyboardUnifiedSendHandoff = handoff
        guard model.releaseSendPresentationGate(requestID) else {
            keyboardUnifiedSendHandoff = nil
            return
        }
        ChatBottomTrace.log(
            "SEND_PRESENTATION_RELEASE reason=keyboardUnifiedTrajectory"
                + " request=\(ChatBottomTrace.shortID(requestID))"
                + " user=\(ChatBottomTrace.shortID(handoff.userMessageID))"
                + " assistant=\(ChatBottomTrace.shortID(handoff.assistantMessageID)) "
                + chatBottomTraceState
        )
    }

    private func isSendPresentationUserFrameReady(
        _ request: UserMessageSendPositionRequest
    ) -> Bool {
        guard let gate = model.sendPresentationGate,
              gate.requestID == request.id,
              gate.conversationID == request.conversationID,
              gate.userMessageID == request.messageID else { return false }
        let anchorID = currentConversationBottomAnchorID
        guard anchorID.messageIDs.last == request.messageID,
              !anchorID.messageIDs.contains(gate.assistantMessageID),
              messageFramesAnchorID == anchorID,
              let frame = messageFrames[request.messageID],
              frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0,
              scrollViewportHeight > 0,
              frame.maxY > 0,
              frame.minY < scrollViewportHeight else { return false }
        return true
    }

    private func awaitSendPresentationUserFrame(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID,
        observesInitialPlacement: Bool
    ) async -> Bool {
        // SwiftUI's logical completion can precede the real UIScrollView idle
        // phase of the already-issued 0.32-second placement. Direct
        // keyboard-cleared sends therefore receive the same bounded physical
        // observation budget as the established off-bottom handoff. A
        // keyboard-unified fallback keeps its existing budget. This observer
        // never issues a scroll command; it only waits for physical idle and
        // the exact request/revision row ACK.
        let maximumAttempts = observesInitialPlacement ? 28 : 10
        var previousStableFrame: CGRect?
        var consecutiveStableSamples = 0
        for attempt in 0..<maximumAttempts {
            guard isCurrentUserMessageSendPositionRequest(
                request,
                taskID: taskID
            ) else { return false }
            let anchorID = currentConversationBottomAnchorID
            let currentFrame = validConcreteMessageFrame(
                request.messageID,
                anchorID: anchorID
            )
            let scrollView = chatScrollViewBox.scrollView
            let isPhysicallyIdle = scrollView?.window != nil
                && !nativeScrollHasActiveTouch(scrollView)
                && !(scrollView?.isTracking ?? false)
                && !(scrollView?.isDragging ?? false)
                && !(scrollView?.isDecelerating ?? false)
                && !isNativeScrollAnimating(scrollView)
            if isSendPresentationUserFrameReady(request),
               isPhysicallyIdle,
               let currentFrame {
                if let previousStableFrame,
                   abs(previousStableFrame.minY - currentFrame.minY) <= 1,
                   abs(previousStableFrame.maxY - currentFrame.maxY) <= 1 {
                    consecutiveStableSamples += 1
                } else {
                    consecutiveStableSamples = 1
                }
                previousStableFrame = currentFrame
                if consecutiveStableSamples >= 2 {
                    return true
                }
            } else {
                previousStableFrame = nil
                consecutiveStableSamples = 0
            }
            await awaitNextMainQueueTurn()
            if attempt + 1 < maximumAttempts {
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        return false
    }

    private func isKeyboardUnifiedSendTailReady(
        _ request: UserMessageSendPositionRequest,
        handoff: KeyboardUnifiedSendHandoff
    ) -> Bool {
        guard handoff.requestID == request.id,
              handoff.conversationID == request.conversationID,
              handoff.userMessageID == request.messageID,
              model.pendingUserMessageSendPositionRequest == request,
              model.selectedConversationID == request.conversationID,
              !model.isDrawerPresented else { return false }
        let anchorID = currentConversationBottomAnchorID
        guard !model.hasLaterMessages,
              anchorID.messageIDs.count >= 2,
              Array(anchorID.messageIDs.suffix(2))
                == [handoff.userMessageID, handoff.assistantMessageID],
              messageFramesAnchorID == anchorID,
              let assistantFrame = messageFrames[handoff.assistantMessageID],
              assistantFrame.minY.isFinite,
              assistantFrame.maxY.isFinite,
              assistantFrame.width > 0,
              assistantFrame.height > 0,
              scrollViewportHeight > 0,
              assistantFrame.maxY > 0,
              assistantFrame.minY < scrollViewportHeight,
              assistantFrame.maxY <= scrollViewportHeight + 2,
              isCurrentNavigationSentinelExact(
                anchorID.positionRequest,
                anchorID: anchorID
              ),
              currentUIKitBottomState?.isAtBottom == true,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              !isNativeScrollAnimating(scrollView) else { return false }
        return true
    }

    @discardableResult
    private func finishKeyboardUnifiedSendHandoffIfReady(
        _ request: UserMessageSendPositionRequest
    ) -> Bool {
        guard let handoff = keyboardUnifiedSendHandoff,
              isKeyboardUnifiedSendTailReady(request, handoff: handoff) else {
            return false
        }

        pendingKeyboardViewportPin = nil
        cancelKeyboardNativeSettleWatcher()
        invalidateKeyboardDismissalTransition()
        userScrollIdleTask?.cancel()
        userScrollIdleTask = nil
        streamFollowTask?.cancel()
        streamFollowTask = nil
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        isUserScrollActive = false
        lastKnownNearBottom = true
        lastMeasuredNearBottom = true
        lastMeasuredAtBottom = true
        autoFollowEngaged = model.preferences.autoScrollEnabled
        keyboardBottomFollowIntent = false
        if model.preferences.autoScrollEnabled {
            nativeSendExactBottomHandoffRequest &+= 1
        }
        keyboardUnifiedSendHandoff = nil
        model.consumeUserMessageSendPositionRequest(request.id)
        ChatBottomTrace.log(
            "SEND_POSITION_FINISH exact=true source=keyboardUnifiedTrajectory"
                + " request=\(ChatBottomTrace.shortID(request.id))"
                + " user=\(ChatBottomTrace.shortID(handoff.userMessageID))"
                + " assistant=\(ChatBottomTrace.shortID(handoff.assistantMessageID)) "
                + chatBottomTraceState
        )
        return true
    }

    private func animateInitialSendPlacement(
        to userHostID: ConversationMessageHostID,
        using scrollProxy: ScrollViewProxy
    ) async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(
                .easeOut(duration: 0.32),
                completionCriteria: .logicallyComplete
            ) {
                scrollProxy.scrollTo(
                    userHostID,
                    anchor: UnitPoint(x: 0.5, y: 0.68)
                )
            } completion: {
                continuation.resume()
            }
        }
    }

    private func animateOffBottomSendPlacement<Target: Hashable>(
        to targetID: Target,
        using scrollProxy: ScrollViewProxy,
        anchor: UnitPoint = UnitPoint(x: 0.5, y: 0.68)
    ) async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(
                .easeOut(duration: 0.32),
                completionCriteria: .removed
            ) {
                scrollProxy.scrollTo(
                    targetID,
                    anchor: anchor
                )
            } completion: {
                continuation.resume()
            }
        }
    }

    private func awaitConcreteOffBottomUserLanding(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID
    ) async -> Bool {
        let landingAnchorID = currentConversationBottomAnchorID
        guard landingAnchorID.messageIDs.last == request.messageID else {
            return false
        }
        // ScrollProxy's animation completion can precede UIScrollView's real
        // idle phase. Observe the existing 0.32-second move without issuing a
        // second target; only the concrete user tail at the strict bottom can
        // hand the next growing revision to ordinary native follow.
        for attempt in 0..<28 {
            if isConcreteSendBottomLanding(
                request,
                taskID: taskID,
                anchorID: landingAnchorID,
                tailMessageID: request.messageID
            ) {
                return true
            }
            guard isCurrentUserMessageSendPositionRequest(
                request,
                taskID: taskID
            ), currentConversationBottomAnchorID == landingAnchorID,
               landingAnchorID.messageIDs.last == request.messageID,
               !hasConcreteNativeUserScrollOwnership,
               !isUserDrivenNativeScrollMotionInFlight else {
                return false
            }
            await awaitNextMainQueueTurn()
            if attempt < 27 {
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        return isConcreteSendBottomLanding(
            request,
            taskID: taskID,
            anchorID: landingAnchorID,
            tailMessageID: request.messageID
        )
    }

    private func finishUserMessageSendPositioning(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID,
        reachedExactBottom: Bool,
        landingAnchorID: ConversationBottomAnchorID?,
        tailMessageID: UUID?,
        preauthorizedExactConcreteHandoff: Bool = false
    ) {
        guard activeUserMessageSendPositionRequestID == request.id,
              activeUserMessageSendPositionTaskID == taskID else { return }
        let liveBottomState = currentUIKitBottomState
        let hasUserDrivenMotion = isUserDrivenNativeScrollMotionInFlight
        let hasExactConcreteHandoff: Bool
        let hasShortContentTopHandoff: Bool
        if let landingAnchorID, let tailMessageID {
            hasExactConcreteHandoff = preauthorizedExactConcreteHandoff
                || (reachedExactBottom
                    && isConcreteSendBottomLanding(
                        request,
                        taskID: taskID,
                        anchorID: landingAnchorID,
                        tailMessageID: tailMessageID
                    ))
            hasShortContentTopHandoff = isConcreteShortContentSendLanding(
                request,
                taskID: taskID,
                anchorID: landingAnchorID,
                tailMessageID: tailMessageID,
                liveBottomState: liveBottomState,
                hasUserDrivenMotion: hasUserDrivenMotion
            )
        } else {
            hasExactConcreteHandoff = preauthorizedExactConcreteHandoff
            hasShortContentTopHandoff = false
        }
        let reachedAuthorizedBottom = hasExactConcreteHandoff
            || hasShortContentTopHandoff
        let liveBottomDescription = liveBottomState.map {
            String($0.isAtBottom)
        } ?? "nil"
        ChatBottomTrace.log(
            "SEND_POSITION_FINISH exact=\(reachedAuthorizedBottom)"
                + " taskExact=\(reachedExactBottom)"
                + " uikitExact=\(liveBottomDescription)"
                + " concreteHandoff=\(hasExactConcreteHandoff)"
                + " preauthorizedHandoff=\(preauthorizedExactConcreteHandoff)"
                + " shortContentHandoff=\(hasShortContentTopHandoff)"
                + " userMotion=\(hasUserDrivenMotion)"
                + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                + chatBottomTraceState
        )
        clearUserMessageSendPositioningTask(for: request.id, taskID: taskID)
        model.consumeUserMessageSendPositionRequest(request.id)

        if reachedAuthorizedBottom {
            isUserScrollActive = false
            lastKnownNearBottom = true
            lastMeasuredNearBottom = true
            lastMeasuredAtBottom = hasExactConcreteHandoff
            // The ordinary 4742 path explicitly released ScrollPosition before
            // proxy placement. Do not consume the native re-arm generation
            // here: the ensuing shouldPin transition must rebuild `.bottom`
            // semantics for streaming growth. The keyboard-unified path never
            // releases that position and retains its separate skip token.
            autoFollowEngaged = model.preferences.autoScrollEnabled
            keyboardBottomFollowIntent = model.isComposerFocused
        } else {
            // A concrete message remains visible, but no synthetic bottom fact
            // is invented. The reader can explicitly choose bottom navigation
            // if the bounded handoff was interrupted by layout churn.
            isUserScrollActive = true
            lastKnownNearBottom = liveBottomState?.isNearBottom ?? false
            lastMeasuredNearBottom = liveBottomState?.isNearBottom ?? false
            lastMeasuredAtBottom = liveBottomState?.isAtBottom ?? false
            autoFollowEngaged = false
            keyboardBottomFollowIntent = false
        }
    }

    private func isConcreteSendBottomLanding(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID,
        anchorID: ConversationBottomAnchorID,
        tailMessageID: UUID
    ) -> Bool {
        guard isCurrentUserMessageSendPositionRequest(request, taskID: taskID),
              !model.hasLaterMessages,
              currentConversationBottomAnchorID == anchorID,
              anchorID.messageIDs.last == tailMessageID,
              hasVisibleConcreteTailBottomEdge(
                tailMessageID,
                anchorID: anchorID
              ),
              isCurrentNavigationSentinelExact(
                anchorID.positionRequest,
                anchorID: anchorID
              ),
              currentUIKitBottomState?.isAtBottom == true,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.window != nil,
              !nativeScrollHasActiveTouch(scrollView),
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              !isNativeScrollAnimating(scrollView) else { return false }
        return true
    }

    private func awaitConcreteSendBottomLanding(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID,
        anchorID: ConversationBottomAnchorID,
        tailMessageID: UUID
    ) async -> Bool {
        // A real UIScrollView can publish its idle/exact sample just after the
        // nominal SwiftUI duration. Observe a short bounded settle window with
        // no additional physical write; failure remains detached.
        for attempt in 0..<8 {
            if isConcreteSendBottomLanding(
                request,
                taskID: taskID,
                anchorID: anchorID,
                tailMessageID: tailMessageID
            ) {
                return true
            }
            guard isCurrentUserMessageSendPositionRequest(
                request,
                taskID: taskID
            ), currentConversationBottomAnchorID == anchorID else {
                return false
            }
            await awaitNextMainQueueTurn()
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        return isConcreteSendBottomLanding(
            request,
            taskID: taskID,
            anchorID: anchorID,
            tailMessageID: tailMessageID
        )
    }

    private func isConcreteShortContentSendLanding(
        _ request: UserMessageSendPositionRequest,
        taskID: UUID,
        anchorID: ConversationBottomAnchorID,
        tailMessageID: UUID,
        liveBottomState: (
            isAtBottom: Bool,
            isNearBottom: Bool,
            isAtOrPastBottom: Bool,
            bottomOffsetY: CGFloat,
            contentOffsetY: CGFloat
        )?,
        hasUserDrivenMotion: Bool
    ) -> Bool {
        guard isCurrentUserMessageSendPositionRequest(request, taskID: taskID),
              !model.hasLaterMessages,
              currentConversationBottomAnchorID == anchorID,
              anchorID.messageIDs.last == tailMessageID,
              hasVisibleConcreteMessageFrame(
                tailMessageID,
                anchorID: anchorID
              ),
              let snapshot = latestConversationBottomAnchorFrame,
              snapshot.anchorID == anchorID,
              snapshot.frame.maxY > 0,
              snapshot.frame.minY < scrollViewportHeight else { return false }
        return hasShortContentTopSendHandoff(
            liveBottomState: liveBottomState,
            hasUserDrivenMotion: hasUserDrivenMotion
        )
    }

    private func hasShortContentTopSendHandoff(
        liveBottomState: (
            isAtBottom: Bool,
            isNearBottom: Bool,
            isAtOrPastBottom: Bool,
            bottomOffsetY: CGFloat,
            contentOffsetY: CGFloat
        )?,
        hasUserDrivenMotion: Bool
    ) -> Bool {
        guard !hasUserDrivenMotion,
              let liveBottomState,
              liveBottomState.isNearBottom,
              let scrollView = chatScrollViewBox.scrollView,
              scrollView.bounds.height > 0 else { return false }
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let isWithinNaturalOffsetRange =
            scrollView.contentOffset.y >= minimumOffsetY - 2
                && scrollView.contentOffset.y <= maximumOffsetY + 2
        let contentFitsUnadjustedViewport = scrollView.contentSize.height
            <= scrollView.bounds.height + 2
        // A short transcript can fill SwiftUI's adjusted viewport while still
        // being no taller than the underlying UIScrollView bounds. In that
        // state the top and bottom insets form a small natural offset range;
        // layout churn can leave the programmatic send animation anywhere in
        // that range even though every row remains visible. This is not a
        // detached reading position: authorize only this bounded, near-bottom,
        // no-user-motion handoff so the next growing reply can establish
        // ordinary streaming follow.
        return isWithinNaturalOffsetRange && contentFitsUnadjustedViewport
    }

    private func scheduleUserMessageSendPositioning(
        _ request: UserMessageSendPositionRequest,
        using scrollProxy: ScrollViewProxy
    ) {
        cancelCodeDisclosure(reason: "sendPositioning")
        cancelAutomaticReasoningCollapseOwner(reason: "sendPositioning")
        cancelMessageTargetNavigationForUserInteraction()
        guard model.pendingUserMessageSendPositionRequest == request else { return }
        guard request.conversationID == model.selectedConversationID,
              model.messages.contains(where: { $0.id == request.messageID }) else {
            model.consumeUserMessageSendPositionRequest(request.id)
            return
        }
        // Preserve the accepted first-message behavior: a brand-new empty chat
        // grows from the header and begins ordinary following when its assistant
        // placeholder arrives. The visual first-message marker deliberately
        // outlives the short follow-suppression marker, so key this decision to
        // the concrete first user row rather than placeholder callback order.
        guard !isFreshConversationFollowSuppressed,
              !isFreshConversationInitialSend(request) else {
            ChatBottomTrace.log(
                "SEND_POSITION_DROP reason=freshConversation"
                    + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                    + chatBottomTraceState
            )
            model.consumeUserMessageSendPositionRequest(request.id)
            return
        }
        // The stable chat host can observe the same request from both onAppear
        // and onChange in one render turn. Restarting it would cancel the first
        // task; because both tasks share the request ID, the cancelled task can
        // otherwise clear its replacement and leave the pending request stuck.
        if activeUserMessageSendPositionRequestID == request.id,
           userMessageSendPositionTask != nil {
            ChatBottomTrace.log(
                "SEND_POSITION_SKIP reason=alreadyScheduled"
                    + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                    + chatBottomTraceState
            )
            return
        }

        // A pending send fences future writers, but a proxy task accepted in a
        // prior turn can still be physically moving. Revoke only those older
        // non-keyboard owners before the keyboard-unified wait. The keyboard
        // pin/dismissal task itself remains untouched unless ordinary fallback
        // is actually selected below.
        let hadCompetingProxyOwner = navigationRequest != nil
            || pendingNavigationRequest != nil
            || navigationScrollTask != nil
            || isPositioningCurrentConversation
        navigationScrollTask?.cancel()
        navigationScrollTask = nil
        navigationRequest = nil
        cancelPendingMessageNavigation()
        navigationAnchorMessageID = nil
        streamFollowTask?.cancel()
        streamFollowTask = nil
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        bottomRowMaterializationTask?.cancel()
        bottomRowMaterializationTask = nil
        pendingBottomRowMaterializationAnchorID = nil
        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = nil
        if isPositioningCurrentConversation {
            cancelConversationReturnPositioning()
        }
        if hadCompetingProxyOwner, isNativeScrollMotionInFlight {
            interruptNativeScrollMotion()
        }

        let unifiedHandoff = keyboardUnifiedSendHandoff.flatMap {
            $0.requestID == request.id
                && $0.conversationID == request.conversationID
                && $0.userMessageID == request.messageID
                ? $0
                : nil
        }
        if unifiedHandoff != nil, isComposerKeyboardPresented {
            ChatBottomTrace.log(
                "SEND_LIFECYCLE_WAIT phase=keyboardUnifiedTrajectory"
                    + " request=\(ChatBottomTrace.shortID(request.id))"
                    + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                    + chatBottomTraceState
            )
            return
        }
        if unifiedHandoff != nil,
           finishKeyboardUnifiedSendHandoffIfReady(request) {
            return
        }

        if model.sendPresentationGate?.requestID == request.id,
           isComposerKeyboardPresented {
            ChatBottomTrace.log(
                "SEND_LIFECYCLE_WAIT phase=keyboard"
                    + " request=\(ChatBottomTrace.shortID(request.id))"
                    + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                    + chatBottomTraceState
            )
            return
        }

        // Only the ordinary keyboard-cleared fallback takes new proxy
        // ownership. The keyboard-unified waits above deliberately keep their
        // established dismissal trajectory intact. Before publishing this
        // fallback's native release token, synchronously revoke every older
        // writer; a duplicate observer was already rejected above.
        navigationScrollTask?.cancel()
        navigationScrollTask = nil
        navigationRequest = nil
        cancelPendingMessageNavigation()
        navigationAnchorMessageID = nil
        pendingKeyboardViewportPin = nil
        cancelKeyboardNativeSettleWatcher()
        invalidateKeyboardDismissalTransition()
        keyboardViewportPinTask?.cancel()
        keyboardViewportPinTask = nil
        userScrollIdleTask?.cancel()
        userScrollIdleTask = nil
        streamFollowTask?.cancel()
        streamFollowTask = nil
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        bottomRowMaterializationTask?.cancel()
        bottomRowMaterializationTask = nil
        pendingBottomRowMaterializationAnchorID = nil
        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = nil
        if isPositioningCurrentConversation {
            cancelConversationReturnPositioning()
        }
        if isNativeScrollMotionInFlight {
            interruptNativeScrollMotion()
        }

        let stagedAssistantMessageID = model.sendPresentationGate.flatMap {
            gate in
            gate.requestID == request.id
                && gate.conversationID == request.conversationID
                && gate.userMessageID == request.messageID
                ? gate.assistantMessageID
                : nil
        }
        // A keyboard-unified handoff may already have released the projection
        // gate before it falls back to this ordinary task. Preserve that same
        // canonical assistant identity instead of guessing from a later tail.
        let expectedAssistantMessageID = stagedAssistantMessageID
            ?? unifiedHandoff?.assistantMessageID
        // Only the genuinely detached staged-send path needs physical
        // completion. Near-bottom and keyboard-unified sends retain 4744's
        // accepted timing. Waiting for the exact user-row animation to leave
        // the transaction prevents a logical completion from racing the
        // LazyVStack frame acknowledgement.
        let shouldAwaitOffBottomSendPhysicalCompletion =
            stagedAssistantMessageID != nil
            && !isSendPresentationUserFrameReady(request)
            && !(currentUIKitBottomState?.isNearBottom ?? lastKnownNearBottom)

        let releaseID = SendPositionNativeReleaseID(
            requestID: request.id,
            sourceAnchorID: currentConversationBottomAnchorID
        )
        guard acknowledgedSendPositionNativeRelease == releaseID else {
            if sendPositionNativeReleaseRequest != releaseID {
                sendPositionNativeReleaseRequest = releaseID
                acknowledgedSendPositionNativeRelease = nil
                autoFollowEngaged = false
                ChatBottomTrace.log(
                    "SEND_POSITION_WAIT phase=nativeRelease"
                        + " request=\(ChatBottomTrace.shortID(request.id)) "
                        + chatBottomTraceState
                )
            }
            return
        }
        sendPositionNativeReleaseRequest = nil

        guard !hasConcreteNativeUserScrollOwnership else {
            ChatBottomTrace.log(
                "SEND_POSITION_DROP reason=userNativeMotionBeforeStart"
                    + " request=\(ChatBottomTrace.shortID(request.id)) "
                    + chatBottomTraceState
            )
            clearSendPositionNativeRelease(for: request.id)
            isUserScrollActive = true
            autoFollowEngaged = false
            model.consumeUserMessageSendPositionRequest(request.id)
            return
        }

        userMessageSendPositionTask?.cancel()
        userMessageSendPositionTask = nil
        let taskID = UUID()
        activeUserMessageSendPositionRequestID = request.id
        activeUserMessageSendPositionTaskID = taskID

        pendingKeyboardViewportPin = nil
        cancelKeyboardNativeSettleWatcher()
        invalidateKeyboardDismissalTransition()
        userScrollIdleTask?.cancel()
        userScrollIdleTask = nil
        streamFollowTask?.cancel()
        streamFollowTask = nil
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        keyboardViewportPinTask?.cancel()
        keyboardViewportPinTask = nil
        bottomRowMaterializationTask?.cancel()
        bottomRowMaterializationTask = nil
        pendingBottomRowMaterializationAnchorID = nil
        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = nil
        navigationScrollTask?.cancel()
        navigationScrollTask = nil
        navigationRequest = nil
        cancelPendingMessageNavigation()
        navigationAnchorMessageID = nil
        if isPositioningCurrentConversation {
            cancelConversationReturnPositioning()
        }
        if isNativeScrollMotionInFlight {
            interruptNativeScrollMotion()
        }
        isNativeVerticalScrollMotionArmed = false
        isNativeScrollPhaseActive = false
        isUserScrollActive = true
        autoFollowEngaged = false
        lastKnownNearBottom = false
        lastMeasuredNearBottom = false
        lastMeasuredAtBottom = false
        keyboardBottomFollowIntent = false

        let userHostID = conversationMessageHostID(for: request.messageID)
        ChatBottomTrace.log(
            "SEND_POSITION_SCHEDULE"
                + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                + chatBottomTraceState
        )
        userMessageSendPositionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  isCurrentUserMessageSendPositionRequest(request, taskID: taskID),
                  !hasConcreteNativeUserScrollOwnership else {
                abandonUserMessageSendPositioningTask(request, taskID: taskID)
                return
            }

            let ownsStagedPresentation = stagedAssistantMessageID != nil
                && model.sendPresentationGate?.requestID == request.id
            let usesKeyboardUnifiedTrajectory = unifiedHandoff != nil
                && keyboardUnifiedSendHandoff == unifiedHandoff
            let measuredStagedAnchorID: ConversationBottomAnchorID? = {
                let anchorID = currentConversationBottomAnchorID
                // The staged assistant already reserves a real row. When the
                // entire bounded window is measured, its bottom is a concrete
                // destination before buffered reply text is published. Keep
                // that stable projection through the one send animation.
                guard ownsStagedPresentation,
                      !model.hasLaterMessages,
                      anchorID.messageIDs.count <= 24,
                      anchorID.messageIDs.last == request.messageID,
                      messageFramesAnchorID == anchorID,
                      let assistantID = stagedAssistantMessageID,
                      let userFrame = validConcreteMessageFrame(
                        request.messageID, anchorID: anchorID
                      ),
                      let reservation = messageFrames[assistantID],
                      reservation.minX.isFinite,
                      reservation.minY.isFinite,
                      reservation.maxY.isFinite,
                      reservation.width.isFinite,
                      reservation.height.isFinite,
                      reservation.width > 0,
                      reservation.height > 0,
                      reservation.minY >= userFrame.maxY,
                      let sentinel = latestConversationBottomAnchorFrame,
                      sentinel.anchorID == anchorID,
                      sentinel.frame.minY.isFinite,
                      sentinel.frame.maxY.isFinite,
                      scrollViewportHeight.isFinite,
                      scrollViewportHeight > 0,
                      let bottomState = currentUIKitBottomState,
                      abs(sentinel.frame.minY - reservation.maxY) <= 2,
                      abs(sentinel.frame.height - composerBottomClearance) <= 2,
                      abs(
                        sentinel.frame.maxY - scrollViewportHeight
                            - (bottomState.bottomOffsetY - bottomState.contentOffsetY)
                      ) <= 2,
                      hasValidConcreteMessageFrames(for: anchorID)
                      else { return nil }
                return anchorID
            }()
            let usesOffBottomPhysicalCompletion = ownsStagedPresentation
                && (shouldAwaitOffBottomSendPhysicalCompletion
                    || measuredStagedAnchorID != nil)
            if usesKeyboardUnifiedTrajectory {
                ChatBottomTrace.log(
                    "SEND_INITIAL_PLACEMENT_SKIP reason=keyboardUnifiedTrajectory"
                        + " request=\(ChatBottomTrace.shortID(request.id))"
                        + " message=\(ChatBottomTrace.shortID(request.messageID)) "
                        + chatBottomTraceState
                )
            } else {
                // A fully measured staged window needs one destination. An
                // unmeasured lazy window still reveals its real user row first.
                traceScrollCommand(
                    source: measuredStagedAnchorID != nil
                        ? "sendPosition.stagedBottom"
                        : "sendPosition.userMessage",
                    target: measuredStagedAnchorID != nil
                        ? "stagedBottomSentinel"
                        : "messageHost:\(ChatBottomTrace.shortID(request.messageID))",
                    animation: usesOffBottomPhysicalCompletion
                        ? "easeOut.removed"
                        : "easeOut"
                )
                if let measuredStagedAnchorID {
                    await animateOffBottomSendPlacement(
                        to: measuredStagedAnchorID,
                        using: scrollProxy,
                        anchor: .bottom
                    )
                } else if ownsStagedPresentation {
                    if usesOffBottomPhysicalCompletion {
                        await animateOffBottomSendPlacement(
                            to: userHostID,
                            using: scrollProxy
                        )
                    } else {
                        await animateInitialSendPlacement(
                            to: userHostID,
                            using: scrollProxy
                        )
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.32)) {
                        scrollProxy.scrollTo(
                            userHostID,
                            anchor: UnitPoint(x: 0.5, y: 0.68)
                        )
                    }
                }
            }
            guard !Task.isCancelled,
                  isCurrentUserMessageSendPositionRequest(request, taskID: taskID) else {
                abandonUserMessageSendPositioningTask(request, taskID: taskID)
                return
            }

            if ownsStagedPresentation {
                if usesOffBottomPhysicalCompletion {
                    let reachedExactUserLanding =
                        await awaitConcreteOffBottomUserLanding(
                            request,
                            taskID: taskID
                        )
                    guard reachedExactUserLanding else {
                        ChatBottomTrace.log(
                            "SEND_POSITION_DROP reason=offBottomUserLandingNotExact"
                                + " request=\(ChatBottomTrace.shortID(request.id))"
                                + " user=\(ChatBottomTrace.shortID(request.messageID)) "
                                + chatBottomTraceState
                        )
                        abandonUserMessageSendPositioningTask(
                            request,
                            taskID: taskID
                        )
                        return
                    }
                    guard model.releaseSendPresentationGate(request.id) else {
                        abandonUserMessageSendPositioningTask(
                            request,
                            taskID: taskID
                        )
                        return
                    }
                    ChatBottomTrace.log(
                        "SEND_PRESENTATION_RELEASE reason=offBottomUserLandingExact"
                            + " request=\(ChatBottomTrace.shortID(request.id))"
                            + " user=\(ChatBottomTrace.shortID(request.messageID)) "
                            + chatBottomTraceState
                    )
                    // The first and only animated move is already at the real
                    // user tail. Re-enable follow now; the current assistant
                    // revision must publish a concrete tail before native
                    // content readiness can rebuild persistent `.bottom`.
                    finishUserMessageSendPositioning(
                        request,
                        taskID: taskID,
                        reachedExactBottom: true,
                        landingAnchorID: nil,
                        tailMessageID: nil,
                        preauthorizedExactConcreteHandoff: true
                    )
                    return
                }
                let userFrameReady = await awaitSendPresentationUserFrame(
                    request,
                    taskID: taskID,
                    observesInitialPlacement: !usesKeyboardUnifiedTrajectory
                )
                guard userFrameReady else {
                    ChatBottomTrace.log(
                        "SEND_POSITION_DROP reason=userFrameNotReadyPreserveViewport"
                            + " request=\(ChatBottomTrace.shortID(request.id))"
                            + " user=\(ChatBottomTrace.shortID(request.messageID)) "
                            + chatBottomTraceState
                    )
                    // Failure never submits a second physical target. In
                    // particular, the detached reader is not sent to the
                    // revision's transparent top seed merely because a lazy
                    // frame acknowledgement missed this bounded handoff.
                    abandonUserMessageSendPositioningTask(
                        request,
                        taskID: taskID
                    )
                    return
                }
                if model.releaseSendPresentationGate(request.id) {
                    ChatBottomTrace.log(
                        "SEND_PRESENTATION_RELEASE reason=userFrameReady"
                            + " request=\(ChatBottomTrace.shortID(request.id))"
                            + " user=\(ChatBottomTrace.shortID(request.messageID)) "
                            + chatBottomTraceState
                    )
                }
                // The canonical assistant row may already contain streamed
                // text. Give the new row revision two queued turns before this
                // same send owner asks for its concrete tail. This is bounded
                // observation only; it never submits a retrying scroll writer.
                await awaitNextMainQueueTurn()
                await awaitNextMainQueueTurn()
            }

            guard !Task.isCancelled,
                  isCurrentUserMessageSendPositionRequest(request, taskID: taskID) else {
                abandonUserMessageSendPositioningTask(request, taskID: taskID)
                return
            }
            let landingAnchorID = currentConversationBottomAnchorID
            guard !model.hasLaterMessages else {
                finishUserMessageSendPositioning(
                    request,
                    taskID: taskID,
                    reachedExactBottom: false,
                    landingAnchorID: nil,
                    tailMessageID: nil
                )
                return
            }
            let tailMessageID: UUID
            if let expectedAssistantMessageID {
                let messageIDs = landingAnchorID.messageIDs
                let stagedPairIsCanonical = messageIDs.count >= 2
                    && messageIDs[messageIDs.count - 2] == request.messageID
                    && messageIDs.last == expectedAssistantMessageID
                let assistantWasCanonicallyRemoved =
                    !messageIDs.contains(expectedAssistantMessageID)
                    && messageIDs.last == request.messageID
                guard stagedPairIsCanonical
                        || assistantWasCanonicallyRemoved else {
                    ChatBottomTrace.log(
                        "SEND_POSITION_DROP reason=unexpectedStagedTail"
                            + " request=\(ChatBottomTrace.shortID(request.id))"
                            + " assistant=\(ChatBottomTrace.shortID(expectedAssistantMessageID)) "
                            + chatBottomTraceState
                    )
                    finishUserMessageSendPositioning(
                        request,
                        taskID: taskID,
                        reachedExactBottom: false,
                        landingAnchorID: landingAnchorID,
                        tailMessageID: nil
                    )
                    return
                }
                tailMessageID = stagedPairIsCanonical
                    ? expectedAssistantMessageID
                    : request.messageID
            } else if let currentTailMessageID = landingAnchorID.messageIDs.last {
                tailMessageID = currentTailMessageID
            } else {
                finishUserMessageSendPositioning(
                    request,
                    taskID: taskID,
                    reachedExactBottom: false,
                    landingAnchorID: landingAnchorID,
                    tailMessageID: nil
                )
                return
            }
            let hasMeasuredTailDestination = ownsStagedPresentation && {
                let anchorID = landingAnchorID
                // A bounded, fully measured window can address its final destination
                // even while the assistant is below the viewport. Keep an unmeasured
                // lazy tail on the existing real-row materialization path.
                guard !model.hasLaterMessages,
                      anchorID.messageIDs.count <= 24,
                      anchorID.messageIDs.last == tailMessageID,
                      messageFramesAnchorID == anchorID,
                      let tailFrame = validConcreteMessageFrame(
                        tailMessageID,
                        anchorID: anchorID
                      ),
                      let sentinel = latestConversationBottomAnchorFrame,
                      sentinel.anchorID == anchorID,
                      sentinel.frame.minY.isFinite,
                      sentinel.frame.maxY.isFinite,
                      scrollViewportHeight.isFinite,
                      scrollViewportHeight > 0,
                      let bottomState = currentUIKitBottomState,
                      abs(sentinel.frame.minY - tailFrame.maxY) <= 2,
                      abs(sentinel.frame.height - composerBottomClearance) <= 2,
                      abs(
                        sentinel.frame.maxY - scrollViewportHeight
                            - (bottomState.bottomOffsetY - bottomState.contentOffsetY)
                      ) <= 2 else { return false }
                return hasValidConcreteMessageFrames(for: anchorID)
            }()
            if hasMeasuredTailDestination {
                ChatBottomTrace.log(
                    "SEND_TAIL_DESTINATION source=measuredWindow"
                        + " tail=\(ChatBottomTrace.shortID(tailMessageID)) "
                        + chatBottomTraceState
                )
            }
            if !hasMeasuredTailDestination,
               !hasVisibleConcreteMessageFrame(
                tailMessageID,
                anchorID: landingAnchorID
            ) {
                guard !hasConcreteNativeUserScrollOwnership else {
                    abandonUserMessageSendPositioningTask(
                        request,
                        taskID: taskID
                    )
                    return
                }
                // Exactly one real-tail wake-up is allowed. A failed row ACK
                // ends detached; it never falls through to the cheap sentinel.
                traceScrollCommand(
                    source: "sendPosition.materialize",
                    target: "messageHost:\(ChatBottomTrace.shortID(tailMessageID))",
                    animation: "easeOut"
                )
                withAnimation(.easeOut(duration: 0.16)) {
                    scrollProxy.scrollTo(
                        conversationMessageHostID(for: tailMessageID),
                        anchor: .bottom
                    )
                }
                try? await Task.sleep(for: .milliseconds(190))
            }
            guard !Task.isCancelled,
                  isCurrentUserMessageSendPositionRequest(request, taskID: taskID),
                  currentConversationBottomAnchorID == landingAnchorID,
                  (hasMeasuredTailDestination || hasVisibleConcreteMessageFrame(
                    tailMessageID,
                    anchorID: landingAnchorID
                  )) else {
                finishUserMessageSendPositioning(
                    request,
                    taskID: taskID,
                    reachedExactBottom: false,
                    landingAnchorID: landingAnchorID,
                    tailMessageID: tailMessageID
                )
                return
            }
            guard !hasConcreteNativeUserScrollOwnership else {
                abandonUserMessageSendPositioningTask(
                    request,
                    taskID: taskID
                )
                return
            }
            let duration: TimeInterval = 0.30
            traceScrollCommand(
                source: "sendPosition.bottom",
                target: "bottomSentinel",
                animation: "easeOut"
            )
            withAnimation(.easeOut(duration: duration)) {
                scrollProxy.scrollTo(landingAnchorID, anchor: .bottom)
            }
            try? await Task.sleep(for: .seconds(duration + 0.05))
            let reachedExactBottom = await awaitConcreteSendBottomLanding(
                request,
                taskID: taskID,
                anchorID: landingAnchorID,
                tailMessageID: tailMessageID
            )
            finishUserMessageSendPositioning(
                request,
                taskID: taskID,
                reachedExactBottom: reachedExactBottom,
                landingAnchorID: landingAnchorID,
                tailMessageID: tailMessageID
            )
        }
    }

    private func scheduleStreamingFollow(using scrollProxy: ScrollViewProxy) {
        let bottomAnchorID = currentConversationBottomAnchorID
        guard model.preferences.autoScrollEnabled,
              !isFreshConversationFollowSuppressed,
              !isUserMessageSendPositioning,
              !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              automaticReasoningCollapseOwner == nil,
              !isCodeDisclosureInProgress,
              pendingBottomRowMaterializationAnchorID == nil,
              !model.hasLaterMessages,
              nativeConversationContentReadyAnchorID == bottomAnchorID,
              hasConcreteTailFrame(for: bottomAnchorID),
              autoFollowEngaged,
              !hasConcreteNativeUserScrollOwnership,
              !isUserScrollActive else { return }
        ChatBottomTrace.log("STREAM_FOLLOW_SCHEDULE " + chatBottomTraceState)
        streamFollowTask?.cancel()
        streamFollowTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  currentConversationBottomAnchorID == bottomAnchorID,
                  model.preferences.autoScrollEnabled,
                  !isUserMessageSendPositioning,
                  !isMessageTargetNavigationOwned,
                  !ownsCurrentDoubleEdgeNavigation,
                  automaticReasoningCollapseOwner == nil,
                  !isCodeDisclosureInProgress,
                  pendingBottomRowMaterializationAnchorID == nil,
                  !model.hasLaterMessages,
                  nativeConversationContentReadyAnchorID == bottomAnchorID,
                  hasConcreteTailFrame(for: bottomAnchorID),
                  autoFollowEngaged,
                  !hasConcreteNativeUserScrollOwnership,
                  !isUserScrollActive else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            traceScrollCommand(
                source: "streamFollow",
                target: "bottomSentinel",
                animation: "disabled"
            )
            withTransaction(transaction) {
                scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            ChatBottomTrace.log("STREAM_FOLLOW_COMPLETE " + chatBottomTraceState)
        }
    }

    private func scheduleConcreteStreamingTailRecovery(
        anchorID: ConversationBottomAnchorID,
        tailMessageID: UUID,
        using scrollProxy: ScrollViewProxy
    ) {
        guard currentConversationBottomAnchorID == anchorID,
              anchorID.messageIDs.last == tailMessageID,
              !model.hasLaterMessages,
              model.preferences.autoScrollEnabled,
              !isFreshConversationFollowSuppressed,
              !isUserMessageSendPositioning,
              !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              automaticReasoningCollapseOwner == nil,
              !isCodeDisclosureInProgress,
              pendingBottomRowMaterializationAnchorID == nil,
              autoFollowEngaged,
              !hasConcreteNativeUserScrollOwnership,
              !isUserScrollActive else { return }
        streamFollowTask?.cancel()
        streamFollowTask = Task { @MainActor in
            await awaitNextMainQueueTurn()
            guard !Task.isCancelled,
                  currentConversationBottomAnchorID == anchorID,
                  anchorID.messageIDs.last == tailMessageID,
                  !model.hasLaterMessages,
                  !isUserMessageSendPositioning,
                  !isMessageTargetNavigationOwned,
                  !ownsCurrentDoubleEdgeNavigation,
                  automaticReasoningCollapseOwner == nil,
                  !isCodeDisclosureInProgress,
                  pendingBottomRowMaterializationAnchorID == nil,
                  autoFollowEngaged,
                  !hasConcreteNativeUserScrollOwnership,
                  !isUserScrollActive else { return }
            // Recovery targets the concrete assistant row only. The bottom
            // sentinel remains unauthorized until this exact row publishes a
            // valid frame in handleConversationBottomAnchorFrame.
            traceScrollCommand(
                source: "streamConcreteTailRecovery",
                target: "messageHost:\(ChatBottomTrace.shortID(tailMessageID))",
                animation: "disabled"
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(
                    conversationMessageHostID(for: tailMessageID),
                    anchor: .bottom
                )
            }
        }
    }

    private func requestLayoutFollowCorrection(requiresNearBottom: Bool = true) {
        let bottomAnchorID = currentConversationBottomAnchorID
        guard model.preferences.autoScrollEnabled,
              !isFreshConversationFollowSuppressed,
              !isUserMessageSendPositioning,
              !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              automaticReasoningCollapseOwner == nil,
              !isCodeDisclosureInProgress,
              pendingBottomRowMaterializationAnchorID == nil,
              !model.hasLaterMessages,
              nativeConversationContentReadyAnchorID == bottomAnchorID,
              hasConcreteTailFrame(for: bottomAnchorID),
              !isKeyboardDismissalTransition,
              !isKeyboardDismissalGeometryRecoveryActive,
              autoFollowEngaged,
              !isUserScrollActive else { return }
        if requiresNearBottom && !lastKnownNearBottom {
            return
        }
        layoutFollowRequiresNearBottom = requiresNearBottom
        layoutFollowRequest += 1
        ChatBottomTrace.log(
            "LAYOUT_FOLLOW_REQUEST value=\(layoutFollowRequest)"
                + " requiresNear=\(requiresNearBottom) "
                + chatBottomTraceState
        )
    }

    private func scheduleLayoutFollowCorrection(using scrollProxy: ScrollViewProxy) {
        if #available(iOS 18.0, *),
           shouldKeepNativeBottomPosition,
           nativeConversationContentReadyAnchorID == currentConversationBottomAnchorID {
            layoutFollowTask?.cancel()
            layoutFollowTask = nil
            return
        }
        let requiresNearBottom = layoutFollowRequiresNearBottom
        let bottomAnchorID = currentConversationBottomAnchorID
        guard model.preferences.autoScrollEnabled,
              !isUserMessageSendPositioning,
              !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              automaticReasoningCollapseOwner == nil,
              !isCodeDisclosureInProgress,
              pendingBottomRowMaterializationAnchorID == nil,
              !model.hasLaterMessages,
              nativeConversationContentReadyAnchorID == bottomAnchorID,
              hasConcreteTailFrame(for: bottomAnchorID),
              autoFollowEngaged,
              (!requiresNearBottom || lastKnownNearBottom),
              !hasConcreteNativeUserScrollOwnership,
              !isUserScrollActive else { return }
        if layoutFollowTask != nil {
            ChatBottomTrace.log("LAYOUT_FOLLOW_CANCEL source=reschedule " + chatBottomTraceState)
        }
        layoutFollowTask?.cancel()
        ChatBottomTrace.log(
            "LAYOUT_FOLLOW_SCHEDULE requiresNear=\(requiresNearBottom) "
                + chatBottomTraceState
        )
        layoutFollowTask = Task { @MainActor in
            for delay in [0, 20, 70, 140] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled,
                      currentConversationBottomAnchorID == bottomAnchorID,
                      model.preferences.autoScrollEnabled,
                      !isUserMessageSendPositioning,
                      !isMessageTargetNavigationOwned,
                      !ownsCurrentDoubleEdgeNavigation,
                      automaticReasoningCollapseOwner == nil,
                      !isCodeDisclosureInProgress,
                      pendingBottomRowMaterializationAnchorID == nil,
                      !model.hasLaterMessages,
                      nativeConversationContentReadyAnchorID == bottomAnchorID,
                      hasConcreteTailFrame(for: bottomAnchorID),
                      autoFollowEngaged,
                      (!requiresNearBottom || lastKnownNearBottom),
                      !hasConcreteNativeUserScrollOwnership,
                      !isUserScrollActive else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "layoutFollow.delay\(delay)",
                    target: "bottomSentinel",
                    animation: "disabled"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
            ChatBottomTrace.log("LAYOUT_FOLLOW_COMPLETE " + chatBottomTraceState)
        }
    }

    private func keyboardIsOpening(_ notification: Notification) -> Bool {
        let screenHeight = UIScreen.main.bounds.height
        let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let beginFrame = notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect ?? .zero
        guard endFrame != .zero, endFrame.minY < screenHeight - 1 else { return false }
        return beginFrame == .zero || endFrame.minY < beginFrame.minY - 0.5
    }

    private func updateKeyboardAnimationTiming(from notification: Notification) {
        if let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue,
           duration.isFinite,
           duration >= 0.01 {
            lastKeyboardAnimationDuration = duration
        }
        if let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue {
            lastKeyboardAnimationCurveRawValue = curve
        }
    }

    private func requestKeyboardViewportPin(allowsFocusPending: Bool = false) {
        cancelCodeDisclosure(reason: "keyboardViewportPin")
        cancelAutomaticReasoningCollapseOwner(reason: "keyboardViewportPin")
        let baseIsEligible = model.preferences.autoScrollEnabled
            && !isFreshConversationFollowSuppressed
            && !isUserMessageSendPositioning
            && !isMessageTargetNavigationOwned
            && !ownsCurrentDoubleEdgeNavigation
            && hasCurrentConcreteLatestBottomContent
            && !model.isDrawerPresented
            && !model.messages.isEmpty
        guard baseIsEligible else {
            ChatBottomTrace.log("KEYBOARD_PIN_DROP reason=ineligible " + chatBottomTraceState)
            return
        }

        let currentAnchorID = currentConversationBottomAnchorID
        if pendingKeyboardViewportPin?.anchorID != currentAnchorID {
            pendingKeyboardViewportPin = nil
        }
        let activeNavigationAction = navigationRequest?.action
            ?? pendingNavigationRequest?.action
        if let activeNavigationAction, activeNavigationAction != .bottom {
            pendingKeyboardViewportPin = nil
            cancelKeyboardNativeSettleWatcher()
            ChatBottomTrace.log("KEYBOARD_PIN_DROP reason=nonBottomNavigation " + chatBottomTraceState)
            return
        }

        let liveBottomState = currentUIKitBottomState
        let hasCurrentPending = pendingKeyboardViewportPin?.anchorID == currentAnchorID
        let hasSettledBottomIntent = keyboardBottomFollowIntent
            || liveBottomState?.isAtBottom == true
            || (autoFollowEngaged && !isUserScrollActive && lastMeasuredAtBottom)
        let hasBottomRubberBandIntent = isUserDrivenNativeScrollMotionInFlight
            && isNativeVerticalScrollMotionArmed
            && (liveBottomState?.isAtOrPastBottom == true
                || (liveBottomState == nil && lastMeasuredAtBottom))
        guard hasCurrentPending || hasSettledBottomIntent || hasBottomRubberBandIntent else {
            ChatBottomTrace.log("KEYBOARD_PIN_DROP reason=notBottomIntent " + chatBottomTraceState)
            return
        }

        if !hasCurrentPending {
            keyboardViewportPinGeneration &+= 1
            pendingKeyboardViewportPin = PendingKeyboardViewportPin(
                anchorID: currentAnchorID,
                generation: keyboardViewportPinGeneration,
                preKeyboardBottomOffsetY: liveBottomState?.bottomOffsetY,
                allowsViewportTransitionCommit: hasSettledBottomIntent
            )
        }

        // UIKit posts will-show/change immediately before its frame transition,
        // while the model FocusState can arrive one turn later. Keep this
        // current-revision token instead of dropping the first presentation.
        guard model.isComposerFocused else {
            guard allowsFocusPending else {
                ChatBottomTrace.log("KEYBOARD_PIN_RETAIN reason=awaitFocus " + chatBottomTraceState)
                return
            }
            ChatBottomTrace.log("KEYBOARD_PIN_QUEUED reason=preFocus " + chatBottomTraceState)
            return
        }

        if isUserDrivenNativeScrollMotionInFlight {
            // Preserve bottom-bound rubber-band intent without interrupting the
            // finger or deceleration. Programmatic `.animating` is deliberately
            // excluded; it must not deadlock a keyboard transition.
            keyboardViewportPinTask?.cancel()
            keyboardViewportPinTask = nil
            scheduleKeyboardNativeSettleWatcher()
            ChatBottomTrace.log("KEYBOARD_PIN_QUEUED reason=userMotion " + chatBottomTraceState)
            return
        }

        if let pendingKeyboardViewportPin,
           pendingKeyboardViewportPinHasReachedBottom(pendingKeyboardViewportPin) {
            consumePendingKeyboardViewportPinIfPossible(isAtBottom: liveBottomState?.isAtBottom == true)
            return
        }

        // No current-revision pre-transition authorization was captured. Keep
        // the strict exact-bottom fallback; proximity alone never steals a
        // reading position.
        let bottomState = refreshMeasuredBottomStateFromUIKit()
        guard bottomState.isAtBottom else {
            ChatBottomTrace.log("KEYBOARD_PIN_RETRY reason=notExact " + chatBottomTraceState)
            retryKeyboardViewportPinAfterScrollSettles()
            return
        }
        pendingKeyboardViewportPin = nil
        applyKeyboardViewportPin()
    }

    private func consumePendingKeyboardViewportPinIfPossible(isAtBottom: Bool) {
        guard let pendingKeyboardViewportPin else { return }
        let isCurrent = pendingKeyboardViewportPin.anchorID
            == currentConversationBottomAnchorID
        let navigationActions = [navigationRequest?.action, pendingNavigationRequest?.action]
            .compactMap { $0 }
        let navigationAllowsBottomCommit = navigationActions.allSatisfy { $0 == .bottom }
        let contextIsEligible = isCurrent
            && model.preferences.autoScrollEnabled
            && !isFreshConversationFollowSuppressed
            && !isMessageTargetNavigationOwned
            && !ownsCurrentDoubleEdgeNavigation
            && hasCurrentConcreteLatestBottomContent
            && !model.isDrawerPresented
            && !model.messages.isEmpty
            && navigationAllowsBottomCommit
        guard contextIsEligible else {
            self.pendingKeyboardViewportPin = nil
            cancelKeyboardNativeSettleWatcher()
            ChatBottomTrace.log("KEYBOARD_PENDING_DROP exact=\(isAtBottom) " + chatBottomTraceState)
            return
        }
        guard model.isComposerFocused else {
            ChatBottomTrace.log("KEYBOARD_PENDING_RETAIN reason=awaitFocus " + chatBottomTraceState)
            return
        }
        guard !isVerticalScrollGestureActive else {
            scheduleKeyboardNativeSettleWatcher()
            ChatBottomTrace.log("KEYBOARD_PENDING_RETAIN reason=gesture " + chatBottomTraceState)
            return
        }
        let reachedAuthorizedBottom = isAtBottom
            || pendingKeyboardViewportPinHasReachedBottom(pendingKeyboardViewportPin)
        guard reachedAuthorizedBottom else {
            ChatBottomTrace.log("KEYBOARD_PENDING_RETAIN reason=notExact " + chatBottomTraceState)
            return
        }
        guard !isUserDrivenNativeScrollMotionInFlight else {
            scheduleKeyboardNativeSettleWatcher()
            ChatBottomTrace.log("KEYBOARD_PENDING_RETAIN reason=nativeMotion " + chatBottomTraceState)
            return
        }
        let bottomState = refreshMeasuredBottomStateFromUIKit()
        guard bottomState.isAtBottom || reachedAuthorizedBottom else {
            scheduleKeyboardNativeSettleWatcher()
            ChatBottomTrace.log("KEYBOARD_PENDING_RETAIN reason=uikitNotExact " + chatBottomTraceState)
            return
        }
        self.pendingKeyboardViewportPin = nil
        ChatBottomTrace.log("KEYBOARD_PENDING_CONSUME " + chatBottomTraceState)
        applyKeyboardViewportPin()
    }

    private func applyKeyboardViewportPin() {
        guard !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              hasCurrentConcreteLatestBottomContent else {
            pendingKeyboardViewportPin = nil
            keyboardBottomFollowIntent = false
            cancelKeyboardNativeSettleWatcher()
            ChatBottomTrace.log(
                "KEYBOARD_PIN_DROP reason=messageTarget "
                    + chatBottomTraceState
            )
            return
        }
        ChatBottomTrace.log("KEYBOARD_PIN_BEGIN " + chatBottomTraceState)
        if keyboardViewportPinTask != nil {
            ChatBottomTrace.log("KEYBOARD_TASK_CANCEL source=pinAccept " + chatBottomTraceState)
        }
        pendingKeyboardViewportPin = nil
        cancelKeyboardNativeSettleWatcher()
        keyboardViewportPinTask?.cancel()
        keyboardViewportPinTask = nil
        invalidateKeyboardDismissalTransition()
        keyboardViewportPinAllowsUnfocused = false
        keyboardBottomFollowIntent = true
        keyboardScrollActivityIgnoreUntil = Date().addingTimeInterval(0.45)
        isUserScrollActive = false
        userScrollIdleTask?.cancel()
        userScrollIdleTask = nil
        autoFollowEngaged = true
        lastKnownNearBottom = true
        keyboardDismissalViewportPinRequest = nil
        keyboardViewportPinRequest += 1
        ChatBottomTrace.log("KEYBOARD_PIN_REQUEST value=\(keyboardViewportPinRequest) " + chatBottomTraceState)
    }

    private func retryKeyboardViewportPinAfterScrollSettles() {
        if keyboardViewportPinTask != nil {
            ChatBottomTrace.log("KEYBOARD_TASK_CANCEL source=retryReschedule " + chatBottomTraceState)
        }
        keyboardViewportPinTask?.cancel()
        let conversationID = model.selectedConversationID
        ChatBottomTrace.log(
            "KEYBOARD_PIN_RETRY_SCHEDULE conv=\(ChatBottomTrace.shortID(conversationID)) "
                + chatBottomTraceState
        )
        keyboardViewportPinTask = Task { @MainActor in
            // Scroll geometry settles just after the finger lifts when a user
            // has returned from older content to the bottom.  Wait briefly for
            // that measurement rather than treating the stale `false` as a
            // decision to keep the keyboard from moving the transcript.
            for delay in [0, 20, 70, 140] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled else {
                    ChatBottomTrace.log(
                        "KEYBOARD_PIN_RETRY_CANCELLED delay=\(delay) conv=\(ChatBottomTrace.shortID(conversationID)) "
                            + chatBottomTraceState
                    )
                    return
                }
                let isStillEligible = model.selectedConversationID == conversationID
                    && model.preferences.autoScrollEnabled
                    && model.isComposerFocused
                    && !isFreshConversationFollowSuppressed
                    && !isMessageTargetNavigationOwned
                    && !model.isDrawerPresented
                    && !isVerticalScrollGestureActive
                guard isStillEligible else {
                    ChatBottomTrace.log(
                        "KEYBOARD_PIN_RETRY_ABORT delay=\(delay) conv=\(ChatBottomTrace.shortID(conversationID)) "
                            + chatBottomTraceState
                    )
                    return
                }
                if isUserDrivenNativeScrollMotionInFlight {
                    requestKeyboardViewportPin()
                    return
                }
                guard refreshMeasuredBottomStateFromUIKit().isAtBottom else { continue }
                ChatBottomTrace.log("KEYBOARD_PIN_RETRY_READY delay=\(delay) " + chatBottomTraceState)
                requestKeyboardViewportPin()
                return
            }
            keyboardViewportPinTask = nil
            ChatBottomTrace.log("KEYBOARD_PIN_RETRY_EXHAUSTED " + chatBottomTraceState)
        }
    }

    private func requestKeyboardDismissalViewportPin(
        _ notification: Notification,
        pendingOpenWasBottomIntent: Bool = false
    ) {
        let isEligible = model.preferences.autoScrollEnabled
            && !isFreshConversationFollowSuppressed
            && !isUserMessageSendPositioning
            && !isMessageTargetNavigationOwned
            && !ownsCurrentDoubleEdgeNavigation
            && hasCurrentConcreteLatestBottomContent
            && !model.isDrawerPresented
            && !model.messages.isEmpty
        guard isEligible else {
            ChatBottomTrace.log(
                "KEYBOARD_HIDE branch=drop-ineligible \(keyboardNotificationTrace(notification)) "
                    + chatBottomTraceState
            )
            return
        }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let normalizedDuration = max(0.01, duration)
        let liveBottomState = currentUIKitBottomState
        let retainedBottomFollowIntent = keyboardBottomFollowIntent
            && (liveBottomState.map {
                $0.isAtBottom
                    || (isUserDrivenNativeScrollMotionInFlight && $0.isAtOrPastBottom)
            } ?? (!isUserScrollActive && lastMeasuredAtBottom))
        let wasFollowingBottom = pendingOpenWasBottomIntent
            || retainedBottomFollowIntent
            || (autoFollowEngaged
                && !isUserScrollActive
                && (liveBottomState?.isAtBottom ?? lastMeasuredAtBottom))
        if pendingOpenWasBottomIntent {
            // The keyboard began while a bottom-bound native motion still owned
            // the ScrollView. Convert the queued open into dismissal intent so
            // the transcript can finish with the keyboard after true idle.
            keyboardBottomFollowIntent = true
        }
        ChatBottomTrace.log(
            "KEYBOARD_HIDE_DECIDE following=\(wasFollowingBottom) \(keyboardNotificationTrace(notification)) "
                + chatBottomTraceState
        )
        guard wasFollowingBottom else {
            isKeyboardDismissalGeometryRecoveryActive = false
            ChatBottomTrace.log("KEYBOARD_HIDE branch=drop-notFollowing " + chatBottomTraceState)
            return
        }

        if isUserDrivenNativeScrollMotionInFlight {
            // The keyboard can start hiding while a bottom rubber-band is still
            // decelerating. Preserve the pre-drag bottom intent and resume only
            // if native scrolling really settles back at the exact bottom.
            pendingKeyboardDismissalDeadline = Date().addingTimeInterval(normalizedDuration)
            ChatBottomTrace.log(
                "KEYBOARD_HIDE branch=pending normalized=\(String(format: "%.3f", normalizedDuration)) "
                    + chatBottomTraceState
            )
            scheduleKeyboardNativeSettleWatcher()
            return
        }
        ChatBottomTrace.log(
            "KEYBOARD_HIDE branch=begin normalized=\(String(format: "%.3f", normalizedDuration)) "
                + chatBottomTraceState
        )
        beginKeyboardDismissalViewportPin(duration: normalizedDuration)
    }

    private func beginKeyboardDismissalViewportPin(duration: TimeInterval) {
        cancelCodeDisclosure(reason: "keyboardDismissal")
        cancelAutomaticReasoningCollapseOwner(reason: "keyboardDismissal")
        guard !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              hasCurrentConcreteLatestBottomContent else {
            pendingKeyboardDismissalDeadline = nil
            keyboardBottomFollowIntent = false
            isKeyboardDismissalGeometryRecoveryActive = false
            ChatBottomTrace.log(
                "KEYBOARD_HIDE branch=drop-messageTarget "
                    + chatBottomTraceState
            )
            return
        }
        pendingKeyboardDismissalDeadline = nil
        cancelKeyboardNativeSettleWatcher()
        // This branch is only entered for an authorized bottom-follow intent
        // with no concrete user motion still owning the scroll view.
        isUserScrollActive = false
        userScrollIdleTask?.cancel()
        userScrollIdleTask = nil
        autoFollowEngaged = model.preferences.autoScrollEnabled
        lastKnownNearBottom = true
        keyboardDismissalTransitionGeneration &+= 1
        keyboardViewportPinAllowsUnfocused = true
        keyboardDismissalAnimationDuration = duration
        isKeyboardDismissalTransition = true
        isKeyboardDismissalGeometryRecoveryActive = true
        keyboardScrollActivityIgnoreUntil = Date().addingTimeInterval(duration + 0.1)
        keyboardViewportPinTask?.cancel()
        keyboardViewportPinTask = nil
        ChatBottomTrace.log(
            "KEYBOARD_DISMISS_CANCEL_FOLLOW"
                + " layout=\(layoutFollowTask != nil)"
                + " stream=\(streamFollowTask != nil) "
                + chatBottomTraceState
        )
        layoutFollowTask?.cancel()
        layoutFollowTask = nil
        streamFollowTask?.cancel()
        streamFollowTask = nil
        let dismissalRequest = keyboardViewportPinRequest + 1
        keyboardDismissalViewportPinRequest = dismissalRequest
        keyboardViewportPinRequest = dismissalRequest
        ChatBottomTrace.log(
            "KEYBOARD_DISMISS_BEGIN generation=\(keyboardDismissalTransitionGeneration)"
                + " duration=\(String(format: "%.3f", duration)) "
                + chatBottomTraceState
        )
    }

    private func resumePendingKeyboardDismissalViewportPinIfPossible() {
        guard let deadline = pendingKeyboardDismissalDeadline else { return }
        guard !isMessageTargetNavigationOwned,
              !ownsCurrentDoubleEdgeNavigation,
              hasCurrentConcreteLatestBottomContent else {
            pendingKeyboardDismissalDeadline = nil
            keyboardBottomFollowIntent = false
            isKeyboardDismissalGeometryRecoveryActive = false
            cancelKeyboardNativeSettleWatcher()
            ChatBottomTrace.log(
                "KEYBOARD_PENDING_RESUME_DROP reason=messageTarget "
                    + chatBottomTraceState
            )
            return
        }
        ChatBottomTrace.log(
            "KEYBOARD_PENDING_RESUME_CHECK remaining=\(ChatBottomTrace.remaining(until: deadline)) "
                + chatBottomTraceState
        )
        guard keyboardBottomFollowIntent else {
            pendingKeyboardDismissalDeadline = nil
            isKeyboardDismissalGeometryRecoveryActive = false
            ChatBottomTrace.log("KEYBOARD_PENDING_RESUME_DROP reason=noIntent " + chatBottomTraceState)
            return
        }
        guard !isUserDrivenNativeScrollMotionInFlight else {
            ChatBottomTrace.log("KEYBOARD_PENDING_RESUME_RETAIN reason=nativeMotion " + chatBottomTraceState)
            scheduleKeyboardNativeSettleWatcher()
            return
        }
        guard refreshMeasuredBottomStateFromUIKit().isAtBottom else {
            ChatBottomTrace.log("KEYBOARD_PENDING_RESUME_RETAIN reason=notExact " + chatBottomTraceState)
            scheduleKeyboardNativeSettleWatcher()
            return
        }
        guard !isUserScrollActive else {
            ChatBottomTrace.log("KEYBOARD_PENDING_RESUME_RETAIN reason=userActive " + chatBottomTraceState)
            scheduleKeyboardNativeSettleWatcher()
            return
        }
        guard !model.isDrawerPresented else {
            pendingKeyboardDismissalDeadline = nil
            isKeyboardDismissalGeometryRecoveryActive = false
            ChatBottomTrace.log("KEYBOARD_PENDING_RESUME_DROP reason=drawer " + chatBottomTraceState)
            return
        }
        pendingKeyboardDismissalDeadline = nil
        let remainingDuration = deadline.timeIntervalSinceNow
        guard remainingDuration > 0 else {
            // The keyboard has already finished. Re-arm the native edge without
            // moving content so the next keyboard transition starts correctly.
            nativeBottomEdgeRearmRequest &+= 1
            keyboardBottomFollowIntent = false
            isKeyboardDismissalGeometryRecoveryActive = false
            ChatBottomTrace.log(
                "KEYBOARD_PENDING_EXPIRED_REARM value=\(nativeBottomEdgeRearmRequest) "
                    + chatBottomTraceState
            )
            return
        }
        ChatBottomTrace.log(
            "KEYBOARD_PENDING_RESUME_BEGIN remaining=\(String(format: "%.3f", remainingDuration)) "
                + chatBottomTraceState
        )
        beginKeyboardDismissalViewportPin(duration: remainingDuration)
    }

    private var currentUIKitBottomState: (
        isAtBottom: Bool,
        isNearBottom: Bool,
        isAtOrPastBottom: Bool,
        bottomOffsetY: CGFloat,
        contentOffsetY: CGFloat
    )? {
        guard let scrollView = chatScrollViewBox.scrollView,
              scrollView.bounds.height > 0 else { return nil }
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let bottomOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let signedDistance = bottomOffsetY - scrollView.contentOffset.y
        return (
            isAtBottom: abs(signedDistance) <= 2,
            isNearBottom: signedDistance <= 56,
            isAtOrPastBottom: signedDistance <= 2,
            bottomOffsetY: bottomOffsetY,
            contentOffsetY: scrollView.contentOffset.y
        )
    }

    private func refreshMeasuredBottomStateFromUIKit() -> (isAtBottom: Bool, isNearBottom: Bool) {
        let state = currentUIKitBottomState.map {
            (isAtBottom: $0.isAtBottom, isNearBottom: $0.isNearBottom)
        } ?? (isAtBottom: lastMeasuredAtBottom, isNearBottom: lastMeasuredNearBottom)
        lastMeasuredAtBottom = state.isAtBottom
        lastMeasuredNearBottom = state.isNearBottom
        return state
    }

    private func pendingKeyboardViewportPinHasReachedBottom(
        _ pending: PendingKeyboardViewportPin
    ) -> Bool {
        guard pending.anchorID == currentConversationBottomAnchorID else { return false }
        if let preKeyboardBottomOffsetY = pending.preKeyboardBottomOffsetY,
           let contentOffsetY = currentUIKitBottomState?.contentOffsetY {
            return contentOffsetY >= preKeyboardBottomOffsetY - 2
        }
        return pending.allowsViewportTransitionCommit
            || (currentUIKitBottomState?.isAtBottom ?? lastMeasuredAtBottom)
    }

    private func scheduleKeyboardNativeSettleWatcher() {
        guard pendingKeyboardViewportPin != nil
                || pendingKeyboardDismissalDeadline != nil else { return }
        keyboardNativeSettleGeneration &+= 1
        let generation = keyboardNativeSettleGeneration
        keyboardNativeSettleTask?.cancel()
        keyboardNativeSettleTask = Task { @MainActor in
            // This watcher never submits scroll commands while native motion is
            // active. It only bridges iOS 17 (no phase callback) and the single
            // layout turn where UIKit/SwiftUI publish idle and exact in opposite
            // orders. A strict exact-bottom fact is still required for one commit.
            for frame in 0..<120 {
                if frame == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard !Task.isCancelled,
                      generation == keyboardNativeSettleGeneration else { return }
                let hasPendingOpen = pendingKeyboardViewportPin?.positionRequest
                    == currentConversationPositionRequest
                let hasPendingHide = pendingKeyboardDismissalDeadline != nil
                guard hasPendingOpen || hasPendingHide else {
                    keyboardNativeSettleTask = nil
                    return
                }
                guard model.preferences.autoScrollEnabled,
                      !isMessageTargetNavigationOwned,
                      !ownsCurrentDoubleEdgeNavigation,
                      hasCurrentConcreteLatestBottomContent,
                      !model.isDrawerPresented,
                      !model.messages.isEmpty else {
                    pendingKeyboardViewportPin = nil
                    pendingKeyboardDismissalDeadline = nil
                    keyboardBottomFollowIntent = false
                    isKeyboardDismissalGeometryRecoveryActive = false
                    keyboardNativeSettleTask = nil
                    return
                }
                guard !isUserDrivenNativeScrollMotionInFlight else { continue }

                let bottomState = currentUIKitBottomState
                let isAtBottom = bottomState?.isAtBottom ?? lastMeasuredAtBottom
                let isNearBottom = bottomState?.isNearBottom ?? lastMeasuredNearBottom
                lastMeasuredAtBottom = isAtBottom
                lastMeasuredNearBottom = isNearBottom
                if let pendingKeyboardViewportPin,
                   pendingKeyboardViewportPinHasReachedBottom(pendingKeyboardViewportPin) {
                    isUserScrollActive = false
                    consumePendingKeyboardViewportPinIfPossible(isAtBottom: isAtBottom)
                    if self.pendingKeyboardViewportPin == nil {
                        return
                    }
                    // FocusState can trail the UIKit notification by a turn.
                    // Keep the authorized token alive instead of classifying
                    // the resized viewport as a detached/far reading position.
                    continue
                }
                if isAtBottom {
                    lastKnownNearBottom = true
                    isUserScrollActive = false
                    if hasPendingHide {
                        resumePendingKeyboardDismissalViewportPinIfPossible()
                    } else {
                        consumePendingKeyboardViewportPinIfPossible(isAtBottom: true)
                    }
                    return
                }
                if !isNearBottom {
                    pendingKeyboardViewportPin = nil
                    pendingKeyboardDismissalDeadline = nil
                    keyboardBottomFollowIntent = false
                    isKeyboardDismissalGeometryRecoveryActive = false
                    keyboardNativeSettleTask = nil
                    ChatBottomTrace.log("KEYBOARD_SETTLE_DROP reason=idleFar " + chatBottomTraceState)
                    return
                }
            }
            if generation == keyboardNativeSettleGeneration {
                pendingKeyboardViewportPin = nil
                pendingKeyboardDismissalDeadline = nil
                keyboardBottomFollowIntent = false
                isKeyboardDismissalGeometryRecoveryActive = false
                keyboardNativeSettleTask = nil
                ChatBottomTrace.log("KEYBOARD_SETTLE_WATCH_EXHAUSTED cleared=true " + chatBottomTraceState)
            }
        }
    }

    private func cancelKeyboardNativeSettleWatcher() {
        keyboardNativeSettleGeneration &+= 1
        keyboardNativeSettleTask?.cancel()
        keyboardNativeSettleTask = nil
    }

    private func scheduleKeyboardViewportPin(using scrollProxy: ScrollViewProxy) {
        let allowsUnfocused = keyboardViewportPinAllowsUnfocused
        let dismissalAnimationDuration = keyboardDismissalAnimationDuration
        let dismissalTransitionGeneration = keyboardDismissalTransitionGeneration
        let isEligible = model.preferences.autoScrollEnabled
            && !isUserMessageSendPositioning
            && !isMessageTargetNavigationOwned
            && !ownsCurrentDoubleEdgeNavigation
            && hasCurrentConcreteLatestBottomContent
            && (allowsUnfocused || model.isComposerFocused)
            && autoFollowEngaged
            && !hasConcreteNativeUserScrollOwnership
            && !isUserScrollActive
        guard isEligible else {
            ChatBottomTrace.log(
                "KEYBOARD_SCHEDULE_DROP allowsUnfocused=\(allowsUnfocused)"
                    + " duration=\(dismissalAnimationDuration.map { String(format: "%.3f", $0) } ?? "nil") "
                    + chatBottomTraceState
            )
            return
        }
        ChatBottomTrace.log(
            "KEYBOARD_SCHEDULE mode=\(isKeyboardDismissalTransition ? "dismissal" : "opening")"
                + " allowsUnfocused=\(allowsUnfocused)"
                + " duration=\(dismissalAnimationDuration.map { String(format: "%.3f", $0) } ?? "nil") "
                + chatBottomTraceState
        )
        keyboardViewportPinTask?.cancel()
        keyboardViewportPinTask = nil
        if #available(iOS 18.0, *),
           !isKeyboardDismissalTransition,
           shouldKeepNativeBottomPosition,
           nativeConversationContentReadyAnchorID == currentConversationBottomAnchorID {
            // The ready native position owns keyboard motion. Proxy retries
            // here would replace its intermediate frames with disabled jumps.
            return
        }
        let bottomAnchorID = currentConversationBottomAnchorID
        keyboardViewportPinTask = Task { @MainActor in
            if isKeyboardDismissalTransition,
               let dismissalAnimationDuration {
                // Keep native edge pinning active while the keyboard changes
                // the viewport. Its measured geometry now moves the transcript
                // frame-for-frame with the keyboard instead of asking a UIKit
                // animation block to animate a SwiftUI ScrollViewProxy command.
                // At the keyboard's reported completion time, make one final
                // no-animation correction for any fractional settling error.
                try? await Task.sleep(for: .seconds(dismissalAnimationDuration))
                guard !Task.isCancelled,
                      dismissalTransitionGeneration == keyboardDismissalTransitionGeneration,
                      currentConversationBottomAnchorID == bottomAnchorID,
                      !isUserMessageSendPositioning,
                      !isMessageTargetNavigationOwned,
                      !ownsCurrentDoubleEdgeNavigation,
                      hasCurrentConcreteLatestBottomContent,
                      !model.isDrawerPresented,
                      autoFollowEngaged,
                      !hasConcreteNativeUserScrollOwnership,
                      !isUserScrollActive else { return }
                let liveBottomState = currentUIKitBottomState
                if let liveBottomState, liveBottomState.isAtBottom {
                    let signedDistance = liveBottomState.bottomOffsetY
                        - liveBottomState.contentOffsetY
                    ChatBottomTrace.log(
                        "KEYBOARD_FINAL_CORRECTION_SKIP reason=alreadyExact"
                            + " generation=\(dismissalTransitionGeneration)"
                            + " distance=\(String(format: "%.2f", signedDistance)) "
                            + chatBottomTraceState
                    )
                } else if #unavailable(iOS 18.0) {
                    ChatBottomTrace.log(
                        "KEYBOARD_FINAL_CORRECTION generation=\(dismissalTransitionGeneration) "
                            + chatBottomTraceState
                    )
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    traceScrollCommand(
                        source: "keyboard.dismissFinal.generation\(dismissalTransitionGeneration)",
                        target: "bottomSentinel",
                        animation: "disabled"
                    )
                    withTransaction(transaction) {
                        scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
                guard dismissalTransitionGeneration == keyboardDismissalTransitionGeneration else { return }
                isKeyboardDismissalTransition = false
                keyboardDismissalAnimationDuration = nil
                keyboardViewportPinAllowsUnfocused = false
                keyboardBottomFollowIntent = false
                isKeyboardDismissalGeometryRecoveryActive = false
                keyboardDismissalViewportPinRequest = nil
                keyboardViewportPinTask = nil
                return
            }
            for delay in [0, 20, 70, 140, 260, 420] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled,
                      currentConversationBottomAnchorID == bottomAnchorID,
                      model.preferences.autoScrollEnabled,
                      !isUserMessageSendPositioning,
                      !isMessageTargetNavigationOwned,
                      !ownsCurrentDoubleEdgeNavigation,
                      hasCurrentConcreteLatestBottomContent,
                      (allowsUnfocused || model.isComposerFocused),
                      (!allowsUnfocused || !model.isDrawerPresented),
                      autoFollowEngaged,
                      !hasConcreteNativeUserScrollOwnership,
                      !isUserScrollActive else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "keyboard.openRetry.delay\(delay)",
                    target: "bottomSentinel",
                    animation: "disabled"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private func invalidateKeyboardDismissalTransition() {
        cancelKeyboardNativeSettleWatcher()
        keyboardDismissalTransitionGeneration &+= 1
        isKeyboardDismissalTransition = false
        isKeyboardDismissalGeometryRecoveryActive = false
        keyboardDismissalViewportPinRequest = nil
        keyboardDismissalAnimationDuration = nil
        keyboardViewportPinAllowsUnfocused = false
        pendingKeyboardDismissalDeadline = nil
        keyboardScrollActivityIgnoreUntil = .distantPast
    }

    private func scheduleConversationReturn(using scrollProxy: ScrollViewProxy) {
        cancelCodeDisclosure(reason: "conversationReturn")
        cancelAutomaticReasoningCollapseOwner(reason: "conversationReturn")
        bottomNavigationCompactWindowConversationID = nil
        guard !isMessageTargetNavigationOwned else {
            ChatBottomTrace.log(
                "CONVERSATION_RETURN_DROP reason=messageTarget "
                    + chatBottomTraceState
            )
            return
        }
        ChatBottomTrace.log(
            "CONVERSATION_RETURN_SCHEDULE"
                + " cancelStream=\(streamFollowTask != nil)"
                + " cancelReturn=\(conversationReturnTask != nil)"
                + " cancelLayout=\(layoutFollowTask != nil)"
                + " cancelKeyboard=\(keyboardViewportPinTask != nil) "
                + chatBottomTraceState
        )
        pendingKeyboardViewportPin = nil
        cancelKeyboardNativeSettleWatcher()
        userScrollIdleTask?.cancel()
        streamFollowTask?.cancel()
        conversationReturnTask?.cancel()
        layoutFollowTask?.cancel()
        keyboardViewportPinTask?.cancel()
        messageWindowLoadTask?.cancel()
        messageWindowLoadTask = nil
        if model.hasLaterMessages {
            model.loadLatestMessageWindow()
        }
        let conversationID = model.selectedConversationID
        let bottomAnchorID = currentConversationBottomAnchorID
        // The new sentinel can publish before this composite selection callback.
        // Preserve a concrete-tail handshake that already belongs to this exact
        // conversation/request/row revision; only obsolete work is cancelled.
        if pendingBottomRowMaterializationAnchorID != bottomAnchorID {
            bottomRowMaterializationTask?.cancel()
            bottomRowMaterializationTask = nil
            pendingBottomRowMaterializationAnchorID = nil
        }
        #if DEBUG
        navigationStressLog(
            "schedule return \(model.selectedConversation?.title ?? "?") "
                + "\(conversationID.uuidString.prefix(5)) req=\(model.conversationBottomReturnRequest) "
                + "messages=\(model.messages.count) drawer=\(model.isDrawerPresented)"
        )
        #endif
        guard !model.messages.isEmpty else {
            finishConversationReturnPositioning(for: conversationID)
            return
        }
        guard !isFreshConversationFollowSuppressed else {
            finishConversationReturnPositioning(for: conversationID)
            return
        }
        isUserScrollActive = false
        autoFollowEngaged = model.preferences.autoScrollEnabled
        lastKnownNearBottom = true
        positioningConversationID = conversationID

        conversationReturnTask = Task { @MainActor in
            if #available(iOS 18.0, *) {
                // Native ScrollPosition owns iOS 18+ conversation returns. Its
                // reset is triggered by the laid-out conversation sentinel. If
                // that preference edge arrived just before this return was armed,
                // replay the cached current-revision snapshot once.
                await Task.yield()
                guard !Task.isCancelled,
                      currentConversationBottomAnchorID == bottomAnchorID,
                      !isUserScrollActive,
                      !model.isDrawerPresented else { return }
                if let snapshot = latestConversationBottomAnchorFrame,
                   snapshot.anchorID == bottomAnchorID {
                    ChatBottomTrace.log("CONVERSATION_RETURN_REPLAY_SNAPSHOT " + chatBottomTraceState)
                    handleConversationBottomAnchorFrame(snapshot, using: scrollProxy)
                }
                return
            }

            @MainActor
            func jumpToBottomNoAnimation() {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                traceScrollCommand(
                    source: "conversationReturn.iOS17",
                    target: "bottomSentinel",
                    animation: "disabled"
                )
                withTransaction(transaction) {
                    scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }

            await Task.yield()
            guard !Task.isCancelled,
                  currentConversationBottomAnchorID == bottomAnchorID,
                  nativeConversationContentReadyAnchorID == bottomAnchorID,
                  !isUserScrollActive,
                  !model.isDrawerPresented else { return }
            jumpToBottomNoAnimation()
            // A proxy command is only a request. Finish positioning after the
            // concrete tail and UIKit both acknowledge the true bottom, so the
            // iOS 17 fallback cannot cancel materialization one turn too early.
            for delay in [0, 20, 70, 140] {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled,
                      currentConversationBottomAnchorID == bottomAnchorID,
                      nativeConversationContentReadyAnchorID == bottomAnchorID,
                      !isUserScrollActive,
                      !model.isDrawerPresented else { return }
                finishConversationReturnIfConcreteTailIsAtBottom(anchorID: bottomAnchorID)
                if !isPositioningCurrentConversation { return }
            }
        }
    }

    private func finishConversationReturnPositioning(for conversationID: UUID) {
        guard model.selectedConversationID == conversationID else { return }
        ChatBottomTrace.log("CONVERSATION_RETURN_FINISH " + chatBottomTraceState)
        #if DEBUG
        navigationStressLog(
            "finish return \(model.selectedConversation?.title ?? "?") "
                + "\(conversationID.uuidString.prefix(5)) req=\(model.conversationBottomReturnRequest)"
        )
        #endif
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if positioningConversationID == conversationID {
                positioningConversationID = nil
            }
            model.finishConversationBottomReturn(for: conversationID)
        }
        conversationReturnTask?.cancel()
        conversationReturnTask = nil
        bottomRowMaterializationTask?.cancel()
        bottomRowMaterializationTask = nil
        pendingBottomRowMaterializationAnchorID = nil
    }

    private func cancelConversationReturnPositioning() {
        ChatBottomTrace.log("CONVERSATION_RETURN_CANCEL " + chatBottomTraceState)
        conversationReturnTask?.cancel()
        conversationReturnTask = nil
        bottomRowMaterializationTask?.cancel()
        bottomRowMaterializationTask = nil
        pendingBottomRowMaterializationAnchorID = nil
        if let positioningConversationID {
            model.finishConversationBottomReturn(for: positioningConversationID)
        }
        if let targetID = model.conversationBottomReturnTargetID {
            model.finishConversationBottomReturn(for: targetID)
        }
        positioningConversationID = nil
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct ChatHeader: View {
    @Environment(AppModel.self) private var model
    let onOpenDrawer: () -> Void
    var showsNewChatButton = true

    var body: some View {
        HStack(spacing: 10) {
            DrawerMenuButton(action: onOpenDrawer)
            .accessibilityLabel(L10n.lookup("打开聊天列表"))

            if model.preferences.showChatHeaderAssistantPill {
                CalendarPill()
            }

            Spacer(minLength: 8)

            if showsNewChatButton {
                NewChatHeaderButton()
            } else {
                Color.clear
                    .frame(width: 50, height: 50)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct DrawerMenuButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .frame(width: 21, height: 3)
                Capsule()
                    .frame(width: 13, height: 3)
            }
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(GlassSurface(shape: Circle()))
            // Keep the proven generous tap target while making only the
            // visible glass control less dominant over the transcript.
            .frame(width: 50, height: 50)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct ChatHeaderInteractionLayer: View {
    @Environment(AppModel.self) private var model
    let onOpenDrawer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenDrawer) {
                Color.clear
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel(L10n.lookup("打开聊天列表"))

            if model.preferences.showChatHeaderAssistantPill {
                CalendarPill(interactionOnly: true)
            }

            Spacer(minLength: 8)

            NewChatHeaderButton()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct RegisteredChatScrollHeader: ViewModifier {
    let topSafeAreaInset: CGFloat
    let onOpenDrawer: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: min(topSafeAreaInset, 48))
                        .overlay(alignment: .top) {
                            ChatHeader(
                                onOpenDrawer: onOpenDrawer,
                                showsNewChatButton: false
                            )
                                .padding(.top, topSafeAreaInset)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .overlay(alignment: .top) {
                    ChatHeaderInteractionLayer(onOpenDrawer: onOpenDrawer)
                        .padding(.top, topSafeAreaInset)
                }
        } else {
            content
        }
    }
}

private struct EmptyOrLegacyChatHeader: ViewModifier {
    let isConversationEmpty: Bool
    let topSafeAreaInset: CGFloat
    let onOpenDrawer: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isConversationEmpty {
                content.overlay(alignment: .top) {
                    ChatHeader(onOpenDrawer: onOpenDrawer)
                        .padding(.top, topSafeAreaInset)
                }
            } else {
                content
            }
        } else {
            content.overlay(alignment: .top) {
                ChatHeader(onOpenDrawer: onOpenDrawer)
            }
        }
    }
}

private struct NewChatHeaderButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: "plus.bubble")
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
            .foregroundStyle(Color.primary)
            .background(GlassSurface(shape: Circle()))
            .contentShape(.contextMenuPreview, Circle())
            // Preserve the accepted 50pt interaction source and its position;
            // only the rendered circle and symbol become smaller.
            .frame(width: 50, height: 50)
            .contentShape(.interaction, Circle())
            .onTapGesture(perform: primaryAction)
            .contextMenu {
                Button(L10n.lookup("新聊天"), systemImage: "plus.bubble") {
                    openNewConversation()
                }
                Button(L10n.lookup("创建群聊"), systemImage: "person.2.badge.plus") {
                    model.openNewGroupChatCreator()
                }
                if model.selectedConversationIsGroupChat {
                    Button(L10n.lookup("编辑群聊成员"), systemImage: "person.2") {
                        model.openGroupChatEditor()
                    }
                }
            }
            .accessibilityLabel(model.selectedConversationIsGroupChat ? L10n.lookup("创建群聊") : L10n.lookup("新聊天"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { primaryAction() }
    }

    private func primaryAction() {
        if model.selectedConversationIsGroupChat {
            model.openNewGroupChatCreator()
        } else {
            let previousConversationID = model.selectedConversationID
            openNewConversation()
            // Only an effective header tap gets feedback. Reusing another
            // empty chat counts; staying in this empty chat does not. Keep
            // the shared long-press menu action unchanged.
            if model.selectedConversationID != previousConversationID {
                model.performHaptic(.soft)
            }
        }
    }

    private func openNewConversation() {
        model.createConversation()
        SponsorEasterEggPersistence.armNextNewChat(for: model.selectedConversationID)
    }

}

private func isVerticalScrollDrag(_ value: DragGesture.Value) -> Bool {
    abs(value.translation.height) > abs(value.translation.width) * 1.2
}

private struct MessageFramePreferenceKey: PreferenceKey {
    static let defaultValue: ConversationMessageFrameSnapshot? = nil

    static func reduce(
        value: inout ConversationMessageFrameSnapshot?,
        nextValue: () -> ConversationMessageFrameSnapshot?
    ) {
        guard let next = nextValue() else { return }
        guard value?.anchorID == next.anchorID,
              value?.layoutRequestID == next.layoutRequestID else {
            value = next
            return
        }
        var merged = value ?? next
        merged.frames.merge(next.frames, uniquingKeysWith: { _, new in new })
        value = merged
    }
}

private struct ConversationBottomAnchorFramePreferenceKey: PreferenceKey {
    static let defaultValue: ConversationBottomAnchorFrame? = nil

    static func reduce(
        value: inout ConversationBottomAnchorFrame?,
        nextValue: () -> ConversationBottomAnchorFrame?
    ) {
        value = nextValue() ?? value
    }
}

private struct MessageWindowTopFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct MessageWindowBottomFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ChatScrollViewProbe: UIViewRepresentable {
    let scrollViewBox: WeakChatScrollViewBox
    let onStatusBarScrollToTop: () -> Void
    let onResolved: () -> Void

    func makeUIView(context: Context) -> ChatScrollViewProbeUIView {
        ChatScrollViewProbeUIView(
            scrollViewBox: scrollViewBox,
            onStatusBarScrollToTop: onStatusBarScrollToTop,
            onResolved: onResolved
        )
    }

    func updateUIView(_ uiView: ChatScrollViewProbeUIView, context: Context) {
        uiView.update(
            scrollViewBox: scrollViewBox,
            onStatusBarScrollToTop: onStatusBarScrollToTop,
            onResolved: onResolved
        )
    }

    static func dismantleUIView(_ uiView: ChatScrollViewProbeUIView, coordinator: ()) {
        uiView.dismantle()
    }
}

/// Owns the box, native gate and delegate as one registration. A new probe can
/// replace an older registration without briefly releasing the shared host.
@MainActor
private final class ChatScrollViewRegistration {
    private static var nextOrder: UInt64 = 0
    private let order: UInt64
    private(set) weak var scrollView: UIScrollView?
    private weak var box: WeakChatScrollViewBox?
    let delegateBridge = ChatStatusBarScrollDelegateBridge()
    var onStatusBarScrollToTop: () -> Void = {}
    var onRelease: () -> Void = {}

    init() {
        Self.nextOrder &+= 1
        order = Self.nextOrder
        delegateBridge.onRequest = { [weak self] in
            guard let self, let scrollView = self.scrollView,
                  self.box?.registration === self,
                  DrawerNativeScrollGate.owner(for: scrollView, role: .chat) === self else { return }
            self.onStatusBarScrollToTop()
        }
    }

    func canAttach(to scrollView: UIScrollView, box: WeakChatScrollViewBox) -> Bool {
        canReplace(box.registration)
            && canReplace(DrawerNativeScrollGate.owner(for: scrollView, role: .chat))
    }

    private func canReplace(_ previous: ChatScrollViewRegistration?) -> Bool {
        guard let previous else { return true }
        return previous === self || previous.order < order
    }

    @discardableResult
    func attach(to scrollView: UIScrollView, box: WeakChatScrollViewBox) -> Bool {
        guard canAttach(to: scrollView, box: box) else { return false }
        let previousBoxOwner = box.registration
        let previousHostOwner = DrawerNativeScrollGate.owner(for: scrollView, role: .chat)
        if self.scrollView !== scrollView {
            release()
        } else if self.box !== box, self.box?.registration === self {
            self.box?.registration = nil
        }
        self.scrollView = scrollView
        self.box = box
        box.registration = self
        DrawerNativeScrollGate.register(scrollView, role: .chat, owner: self)
        // Adopt the real delegate before the previous registration releases
        // its bridge. Its owner-checked cleanup cannot unlock this new binding.
        delegateBridge.installIfNeeded(on: scrollView)
        if previousBoxOwner !== self { previousBoxOwner?.release() }
        if previousHostOwner !== self, previousHostOwner !== previousBoxOwner {
            previousHostOwner?.release()
        }
        return true
    }

    func release() {
        onRelease()
        if box?.registration === self { box?.registration = nil }
        if let scrollView {
            DrawerNativeScrollGate.unregister(scrollView, role: .chat, owner: self)
        }
        delegateBridge.uninstall()
        scrollView = nil
        box = nil
    }
}

private final class ChatScrollViewProbeUIView: UIView {
    private var scrollViewBox: WeakChatScrollViewBox
    private var onResolved: () -> Void
    private let registration = ChatScrollViewRegistration()
    private var resolutionGeneration: UInt64 = 0
    private var resolutionScheduled = false
    private var isDismantled = false

    init(
        scrollViewBox: WeakChatScrollViewBox,
        onStatusBarScrollToTop: @escaping () -> Void,
        onResolved: @escaping () -> Void
    ) {
        self.scrollViewBox = scrollViewBox
        self.onResolved = onResolved
        super.init(frame: .zero)
        registration.onStatusBarScrollToTop = onStatusBarScrollToTop
        registration.onRelease = { [weak self] in self?.invalidateResolution() }
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleResolution()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            registration.release()
        } else {
            scheduleResolution()
        }
    }

    func update(
        scrollViewBox: WeakChatScrollViewBox,
        onStatusBarScrollToTop: @escaping () -> Void,
        onResolved: @escaping () -> Void
    ) {
        guard !isDismantled else { return }
        if self.scrollViewBox !== scrollViewBox { invalidateResolution() }
        self.scrollViewBox = scrollViewBox
        self.onResolved = onResolved
        registration.onStatusBarScrollToTop = onStatusBarScrollToTop
        scheduleResolution()
    }

    func dismantle() {
        isDismantled = true
        registration.release()
    }

    private func invalidateResolution() {
        resolutionGeneration &+= 1
        resolutionScheduled = false
    }

    func scheduleResolution() {
        guard !isDismantled else { return }
        guard window != nil else {
            registration.release()
            return
        }
        if let scrollView = nearestAncestorScrollView() {
            guard registration.canAttach(to: scrollView, box: scrollViewBox) else {
                registration.release()
                return
            }
            if registration.scrollView === scrollView,
               scrollViewBox.registration === registration {
                registration.attach(to: scrollView, box: scrollViewBox)
                return
            }
        } else if registration.scrollView != nil {
            registration.release()
        }
        guard !resolutionScheduled else { return }
        resolutionScheduled = true
        let generation = resolutionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isDismantled,
                  self.resolutionGeneration == generation else { return }
            self.resolutionScheduled = false
            self.resolveScrollView()
        }
    }

    private func resolveScrollView() {
        guard !isDismantled else { return }
        guard window != nil, let scrollView = nearestAncestorScrollView(),
              registration.attach(to: scrollView, box: scrollViewBox) else {
            registration.release()
            return
        }
        onResolved()
    }

    private func nearestAncestorScrollView() -> UIScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }
}

/// Adds one exact status-bar request hook to SwiftUI's real chat scroll view
/// without replacing any of its other delegate behavior. UIKit keeps this
/// delegate weak; the probe view owns the bridge and restores the original
/// delegate when its scroll-view identity changes or the probe is dismantled.
private final class ChatStatusBarScrollDelegateBridge: NSObject, UIScrollViewDelegate {
    weak var scrollView: UIScrollView?
    // NSObject's selector forwarding hooks are imported as nonisolated even
    // though UIScrollView invokes its delegate on the main thread. Keep only
    // this weak Objective-C forwarding reference nonisolated so Swift 6 does
    // not invent a cross-actor hop inside synchronous message forwarding.
    nonisolated(unsafe) weak var forwardedDelegate: UIScrollViewDelegate?
    var onRequest: () -> Void = {}

    func installIfNeeded(on scrollView: UIScrollView) {
        if self.scrollView === scrollView,
           scrollView.delegate === self {
            return
        }

        uninstall()
        self.scrollView = scrollView
        if let previousBridge = scrollView.delegate
            as? ChatStatusBarScrollDelegateBridge {
            // A SwiftUI identity replacement can mount the new probe before
            // dismantling the old one. Adopt the real delegate directly so a
            // temporary bridge-to-bridge chain cannot lose it when the old
            // probe is released.
            forwardedDelegate = previousBridge.forwardedDelegate
            previousBridge.scrollView = nil
            previousBridge.forwardedDelegate = nil
        } else {
            forwardedDelegate = scrollView.delegate
        }
        scrollView.delegate = self
        ChatBottomTrace.log(
            "STATUS_TOP_DELEGATE_INSTALL"
                + " scroll=\(ObjectIdentifier(scrollView))"
                + " forwarded=\(String(describing: forwardedDelegate.map(ObjectIdentifier.init)))"
        )
    }

    func uninstall() {
        guard let scrollView else {
            forwardedDelegate = nil
            return
        }
        if scrollView.delegate === self {
            scrollView.delegate = forwardedDelegate
        }
        self.scrollView = nil
        forwardedDelegate = nil
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        let restingTopY = -scrollView.adjustedContentInset.top
        ChatBottomTrace.log(
            "STATUS_TOP_DELEGATE_REQUEST"
                + " offsetY=\(String(format: "%.2f", scrollView.contentOffset.y))"
                + " topY=\(String(format: "%.2f", restingTopY))"
        )
        onRequest()
        // The established top-navigation owner performs the real start-window
        // load and animation. Suppress UIKit's simultaneous local-window move.
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(scrollViewShouldScrollToTop(_:)) {
            return true
        }
        return super.responds(to: aSelector)
            || (forwardedDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector != #selector(scrollViewShouldScrollToTop(_:)),
           let forwardedDelegate,
           forwardedDelegate.responds(to: aSelector) {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

private struct MessageNavigationPanel: View {
    let onTop: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onBottom: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            navigationButton("chevron.up.2", label: L10n.lookup("滚动到顶部"), action: onTop)
            navigationButton("chevron.up", label: L10n.lookup("上一条用户消息"), action: onPrevious)
            navigationButton("chevron.down", label: L10n.lookup("下一条用户消息"), action: onNext)
            navigationButton("chevron.down.2", label: L10n.lookup("滚动到底部"), action: onBottom)
        }
    }

    private func navigationButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        MessageNavigationButton(
            systemName: systemName,
            label: label,
            action: action
        )
    }
}

private struct MessageNavigationButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        ZStack {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(.primary.opacity(0.10), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.08), radius: 7, y: 3)
                .accessibilityHidden(true)

            // A native control above the transcript receives the first touch
            // even while the underlying UIScrollView is decelerating. The
            // action still enters requestMessageNavigation(), which owns the
            // existing tracking guard, inertia stop, and request tokens.
            MessageNavigationTapSurface(
                accessibilityLabel: label,
                action: action,
                onHighlightChanged: { highlighted in
                    isPressed = highlighted
                }
            )
            .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .scaleEffect(isPressed ? 0.92 : 1)
        .opacity(isPressed ? 0.72 : 1)
        .animation(
            .snappy(duration: 0.16, extraBounce: 0.04),
            value: isPressed
        )
    }
}

private struct QuickReturnToBottomButton: View {
    let action: () -> Void
    @State private var isPressed = false

    private var arrow: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
    }

    var body: some View {
        ZStack {
            if #available(iOS 26.0, *) {
                arrow.glassEffect(.regular, in: Circle())
            } else {
                arrow.background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }

            MessageNavigationTapSurface(
                accessibilityLabel: L10n.lookup("回到最新消息"),
                action: action,
                onHighlightChanged: { highlighted in
                    isPressed = highlighted
                }
            )
            .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .scaleEffect(isPressed ? 0.92 : 1)
        .opacity(isPressed ? 0.72 : 1)
        .animation(
            .snappy(duration: 0.16, extraBounce: 0.04),
            value: isPressed
        )
    }
}

private struct MessageNavigationTapSurface: UIViewRepresentable {
    let accessibilityLabel: String
    let action: () -> Void
    let onHighlightChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, onHighlightChanged: onHighlightChanged)
    }

    func makeUIView(context: Context) -> MessageNavigationUIControl {
        let control = MessageNavigationUIControl()
        control.backgroundColor = .clear
        control.isOpaque = false
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityLabel = accessibilityLabel
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.activate),
            for: .touchUpInside
        )
        control.onHighlightChanged = { highlighted in
            context.coordinator.highlightChanged(highlighted)
        }
        control.onAccessibilityActivate = {
            context.coordinator.activate()
        }
        return control
    }

    func updateUIView(_ uiView: MessageNavigationUIControl, context: Context) {
        context.coordinator.action = action
        context.coordinator.onHighlightChanged = onHighlightChanged
        uiView.accessibilityLabel = accessibilityLabel
    }

    static func dismantleUIView(_ uiView: MessageNavigationUIControl, coordinator: Coordinator) {
        uiView.removeTarget(
            coordinator,
            action: #selector(Coordinator.activate),
            for: .touchUpInside
        )
        uiView.onHighlightChanged = nil
        uiView.onAccessibilityActivate = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        var onHighlightChanged: (Bool) -> Void

        init(
            action: @escaping () -> Void,
            onHighlightChanged: @escaping (Bool) -> Void
        ) {
            self.action = action
            self.onHighlightChanged = onHighlightChanged
        }

        @objc func activate() {
            action()
        }

        func highlightChanged(_ highlighted: Bool) {
            onHighlightChanged(highlighted)
        }
    }
}

private final class MessageNavigationUIControl: UIControl {
    var onHighlightChanged: ((Bool) -> Void)?
    var onAccessibilityActivate: (() -> Void)?

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            onHighlightChanged?(isHighlighted)
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event), !bounds.isEmpty else { return false }
        let radius = min(bounds.width, bounds.height) / 2
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        return dx * dx + dy * dy <= radius * radius
    }

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate?()
        return true
    }
}

private struct ChatScrollAnchorsModifier: ViewModifier {
    let alignsShortContentAtBottom: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if alignsShortContentAtBottom {
                content
                    // Existing conversations reopen at their real bottom.
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.top, for: .alignment)
            } else {
                content
                    // The first prompt in a brand-new chat starts below the
                    // header rather than floating in a bottom-aligned gap.
                    .defaultScrollAnchor(.top, for: .initialOffset)
                    .defaultScrollAnchor(.top, for: .alignment)
            }
        } else {
            content.defaultScrollAnchor(alignsShortContentAtBottom ? .bottom : .top)
        }
    }
}

private struct ChatNativeBottomPositionModifier: ViewModifier {
    let conversationID: UUID
    let request: Int
    let bottomAnchorID: ConversationBottomAnchorID
    let edgeRearmRequest: Int
    let sendExactBottomHandoffRequest: Int
    let contentReadyAnchorID: ConversationBottomAnchorID?
    let keyboardRequest: Int
    let keyboardDismissalRequest: Int?
    let keyboardAnimationDuration: TimeInterval
    let keyboardAnimationCurveRawValue: Int
    let scrollViewBox: WeakChatScrollViewBox
    let shouldPinToBottom: Bool
    let isOrdinaryConversationReturn: Bool
    let messageReplacementReleaseID: UUID?
    let onMessageReplacementPositionReleased: (ConversationBottomAnchorID, UUID) -> Void
    let shouldPauseStreamingFollowOnUserTouch: Bool
    let automaticReasoningCollapseOwnerID:
        AutomaticReasoningCollapseOwnerID?
    let automaticReasoningCollapseOwnerLifecycle: UInt64
    let automaticReasoningCollapseRearmRequest:
        AutomaticReasoningCollapseRearmRequest?
    let messageTargetReleaseID: UUID?
    let edgeNavigationReleaseID: EdgeNavigationNativeReleaseID?
    let edgeNavigationSequence: Int?
    let onEdgeNavigationUserTouch: (ConversationBottomAnchorID, Int) -> Bool
    let sendPositionReleaseID: SendPositionNativeReleaseID?
    let onBottomStateChanged: (ConversationBottomAnchorID, Bool, Bool) -> Void
    let onAutomaticReasoningCollapseGeometry:
        (
            AutomaticReasoningCollapseGeometryChange,
            (AutomaticReasoningCollapseOwnerID) -> Void
        )
            -> AutomaticReasoningCollapseGeometryDisposition
    let onAutomaticReasoningCollapseBottomRearmed:
        (AutomaticReasoningCollapseOwnerID) -> Void
    let onScrollMotionChanged: (ConversationBottomAnchorID, Bool, Bool, Bool) -> Void
    let onScrollPhaseActivityChanged: (ConversationBottomAnchorID, Bool, Bool, Bool) -> Void
    let onSystemScrollToTopStarted: (ConversationBottomAnchorID) -> Void
    let onMessageTargetPositionReleased: (ConversationBottomAnchorID, UUID) -> Void
    let onEdgeNavigationPositionReleased:
        (ConversationBottomAnchorID, EdgeNavigationNativeReleaseID) -> Void
    let onSendPositionReleased:
        (ConversationBottomAnchorID, SendPositionNativeReleaseID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(
                IOS18ChatNativeBottomPositionModifier(
                    conversationID: conversationID,
                    request: request,
                    bottomAnchorID: bottomAnchorID,
                    edgeRearmRequest: edgeRearmRequest,
                    sendExactBottomHandoffRequest: sendExactBottomHandoffRequest,
                    contentReadyAnchorID: contentReadyAnchorID,
                    keyboardRequest: keyboardRequest,
                    keyboardDismissalRequest: keyboardDismissalRequest,
                    keyboardAnimationDuration: keyboardAnimationDuration,
                    keyboardAnimationCurveRawValue: keyboardAnimationCurveRawValue,
                    scrollViewBox: scrollViewBox,
                    shouldPinToBottom: shouldPinToBottom,
                    isOrdinaryConversationReturn: isOrdinaryConversationReturn,
                    messageReplacementReleaseID: messageReplacementReleaseID,
                    onMessageReplacementPositionReleased: onMessageReplacementPositionReleased,
                    shouldPauseStreamingFollowOnUserTouch:
                        shouldPauseStreamingFollowOnUserTouch,
                    automaticReasoningCollapseOwnerID:
                        automaticReasoningCollapseOwnerID,
                    automaticReasoningCollapseOwnerLifecycle:
                        automaticReasoningCollapseOwnerLifecycle,
                    automaticReasoningCollapseRearmRequest:
                        automaticReasoningCollapseRearmRequest,
                    messageTargetReleaseID: messageTargetReleaseID,
                    edgeNavigationReleaseID: edgeNavigationReleaseID,
                    edgeNavigationSequence: edgeNavigationSequence,
                    onEdgeNavigationUserTouch: onEdgeNavigationUserTouch,
                    sendPositionReleaseID: sendPositionReleaseID,
                    onBottomStateChanged: onBottomStateChanged,
                    onAutomaticReasoningCollapseGeometry:
                        onAutomaticReasoningCollapseGeometry,
                    onAutomaticReasoningCollapseBottomRearmed:
                        onAutomaticReasoningCollapseBottomRearmed,
                    onScrollMotionChanged: onScrollMotionChanged,
                    onScrollPhaseActivityChanged: onScrollPhaseActivityChanged,
                    onSystemScrollToTopStarted: onSystemScrollToTopStarted,
                    onMessageTargetPositionReleased:
                        onMessageTargetPositionReleased,
                    onEdgeNavigationPositionReleased:
                        onEdgeNavigationPositionReleased,
                    onSendPositionReleased: onSendPositionReleased
                )
            )
        } else {
            content
                .task(id: messageReplacementReleaseID) {
                    guard let requestID = messageReplacementReleaseID else { return }
                    onMessageReplacementPositionReleased(bottomAnchorID, requestID)
                }
                .onAppear {
                    if let messageTargetReleaseID {
                        onMessageTargetPositionReleased(
                            bottomAnchorID,
                            messageTargetReleaseID
                        )
                    }
                    if let edgeNavigationReleaseID {
                        onEdgeNavigationPositionReleased(
                            bottomAnchorID,
                            edgeNavigationReleaseID
                        )
                    }
                    if let sendPositionReleaseID {
                        onSendPositionReleased(
                            bottomAnchorID,
                            sendPositionReleaseID
                        )
                    }
                }
                .onChange(of: messageTargetReleaseID) { _, requestID in
                    if let requestID {
                        onMessageTargetPositionReleased(
                            bottomAnchorID,
                            requestID
                        )
                    }
                }
                .onChange(of: edgeNavigationReleaseID) { _, releaseID in
                    if let releaseID {
                        onEdgeNavigationPositionReleased(
                            bottomAnchorID,
                            releaseID
                        )
                    }
                }
                .onChange(of: sendPositionReleaseID) { _, releaseID in
                    if let releaseID {
                        onSendPositionReleased(
                            bottomAnchorID,
                            releaseID
                        )
                    }
                }
        }
    }
}

@available(iOS 18.0, *)
private struct IOS18ChatScrollGeometrySnapshot: Equatable {
    let anchorID: ConversationBottomAnchorID
    let contentHeight: CGFloat
    let bottomBoundaryY: CGFloat
    let containerHeight: CGFloat
    let signedDistanceFromBottom: CGFloat
    let bottomOffsetY: CGFloat
    let isAtBottom: Bool
    let isNearBottom: Bool

    static func == (
        lhs: IOS18ChatScrollGeometrySnapshot,
        rhs: IOS18ChatScrollGeometrySnapshot
    ) -> Bool {
        // Preserve clean 4708's action trigger surface. contentHeight and
        // bottomOffsetY are payloads used only after one of the original six
        // observed fields changes; they must not create additional callbacks.
        lhs.anchorID == rhs.anchorID
            && lhs.bottomBoundaryY == rhs.bottomBoundaryY
            && lhs.containerHeight == rhs.containerHeight
            && lhs.signedDistanceFromBottom == rhs.signedDistanceFromBottom
            && lhs.isAtBottom == rhs.isAtBottom
            && lhs.isNearBottom == rhs.isNearBottom
    }
}

@available(iOS 18.0, *)
private struct IOS18ChatNativeBottomPositionModifier: ViewModifier {
    let conversationID: UUID
    let request: Int
    let bottomAnchorID: ConversationBottomAnchorID
    let edgeRearmRequest: Int
    let sendExactBottomHandoffRequest: Int
    let contentReadyAnchorID: ConversationBottomAnchorID?
    let keyboardRequest: Int
    let keyboardDismissalRequest: Int?
    let keyboardAnimationDuration: TimeInterval
    let keyboardAnimationCurveRawValue: Int
    let scrollViewBox: WeakChatScrollViewBox
    let shouldPinToBottom: Bool
    let isOrdinaryConversationReturn: Bool
    let messageReplacementReleaseID: UUID?
    let onMessageReplacementPositionReleased: (ConversationBottomAnchorID, UUID) -> Void
    let shouldPauseStreamingFollowOnUserTouch: Bool
    let automaticReasoningCollapseOwnerID:
        AutomaticReasoningCollapseOwnerID?
    let automaticReasoningCollapseOwnerLifecycle: UInt64
    let automaticReasoningCollapseRearmRequest:
        AutomaticReasoningCollapseRearmRequest?
    let messageTargetReleaseID: UUID?
    let edgeNavigationReleaseID: EdgeNavigationNativeReleaseID?
    let edgeNavigationSequence: Int?
    let onEdgeNavigationUserTouch: (ConversationBottomAnchorID, Int) -> Bool
    let sendPositionReleaseID: SendPositionNativeReleaseID?
    let onBottomStateChanged: (ConversationBottomAnchorID, Bool, Bool) -> Void
    let onAutomaticReasoningCollapseGeometry:
        (
            AutomaticReasoningCollapseGeometryChange,
            (AutomaticReasoningCollapseOwnerID) -> Void
        )
            -> AutomaticReasoningCollapseGeometryDisposition
    let onAutomaticReasoningCollapseBottomRearmed:
        (AutomaticReasoningCollapseOwnerID) -> Void
    let onScrollMotionChanged: (ConversationBottomAnchorID, Bool, Bool, Bool) -> Void
    let onScrollPhaseActivityChanged: (ConversationBottomAnchorID, Bool, Bool, Bool) -> Void
    let onSystemScrollToTopStarted: (ConversationBottomAnchorID) -> Void
    let onMessageTargetPositionReleased: (ConversationBottomAnchorID, UUID) -> Void
    let onEdgeNavigationPositionReleased:
        (ConversationBottomAnchorID, EdgeNavigationNativeReleaseID) -> Void
    let onSendPositionReleased:
        (ConversationBottomAnchorID, SendPositionNativeReleaseID) -> Void
    // Start unpositioned so a newly created LazyVStack gets one real layout
    // pass before an edge command is submitted. Initializing directly at the
    // bottom can make SwiftUI resolve only the zero-cost sentinel and leave
    // every lazy message row outside the realized viewport after a switch.
    @State private var position = ScrollPosition()
    // The modifier is scoped to one conversation surface. Later return requests
    // and message revisions must retain the baseline's explicit positioning.
    @State private var initialBottomAnchorID: ConversationBottomAnchorID?
    // Distance is read by scroll-phase and keyboard callbacks, not rendering.
    // Keep samples current without publishing every change as view state.
    @MainActor
    private final class BottomDistanceMeasurement {
        var signedDistanceFromBottom = CGFloat.infinity
    }
    @State private var bottomDistanceMeasurement = BottomDistanceMeasurement()
    @State private var consumedSendExactBottomHandoffRequest = 0
    @State private var keyboardViewportAnimationDeadline = Date.distantPast
    @State private var keyboardViewportCompletionTask: Task<Void, Never>?
    @State private var releasedMessageTargetRequestID: UUID?
    @State private var messageTargetReleaseAckTask: Task<Void, Never>?
    @State private var releasedEdgeNavigationID: EdgeNavigationNativeReleaseID?
    @State private var edgeNavigationReleaseAckTask: Task<Void, Never>?
    @State private var releasedSendPositionID: SendPositionNativeReleaseID?
    @State private var sendPositionReleaseAckTask: Task<Void, Never>?
    @State private var isSystemScrollToTopAnimation = false
    @State private var ownsStreamingFollowTouchPause = false
    @State private var locallyClaimedAutomaticReasoningCollapseOwnerID:
        AutomaticReasoningCollapseOwnerID?

    // Root state is a value-propagation turn behind the synchronous geometry
    // callback. The local latch closes that gap; the monotonic lifecycle value
    // clears it even when root admits and releases quickly enough for its
    // external optional owner to coalesce nil -> nil.
    private var hasAutomaticReasoningCollapseClaim: Bool {
        if automaticReasoningCollapseOwnerID?.anchorID == bottomAnchorID {
            return true
        }
        if locallyClaimedAutomaticReasoningCollapseOwnerID?.anchorID
            == bottomAnchorID {
            return true
        }
        return false
    }

    private var chatBottomTracePosition: String {
        let pointY = position.point.map { String(format: "%.1f", $0.y) } ?? "nil"
        return "conv=\(ChatBottomTrace.shortID(conversationID)) req=\(request)"
            + " positionUser=\(position.isPositionedByUser)"
            + " positionEdge=\(String(describing: position.edge))"
            + " pointY=\(pointY)"
            + " shouldPin=\(shouldPinToBottom)"
            + " ready=\(contentReadyAnchorID == bottomAnchorID)"
            + " collapseClaim=\(hasAutomaticReasoningCollapseClaim)"
            + " collapseLifecycle=\(automaticReasoningCollapseOwnerLifecycle)"
            + " edgeReq=\(edgeRearmRequest)"
            + " sendHandoffReq=\(sendExactBottomHandoffRequest)"
            + " keyboardReq=\(keyboardRequest)"
    }

    func body(content: Content) -> some View {
        let positionedContent = content.scrollPosition($position)
            .task(id: messageReplacementReleaseID) { @MainActor in
                guard let requestID = messageReplacementReleaseID else { return }
                let sourceAnchorID = bottomAnchorID
                cancelKeyboardViewportMotion()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    position.isPositionedByUser = true
                }
                // Commit the released position before changing the transcript.
                // This is a lifecycle handoff, not a timed geometry retry.
                await awaitNextMainQueueTurn()
                guard !Task.isCancelled else { return }
                ChatBottomTrace.log(
                    "MESSAGE_REPLACEMENT_NATIVE_RELEASE request=\(ChatBottomTrace.shortID(requestID)) "
                        + chatBottomTracePosition
                )
                onMessageReplacementPositionReleased(sourceAnchorID, requestID)
            }
        let lifecycleObservedContent = addLifecycleObservers(
            to: positionedContent
        )
        let geometryObservedContent = addGeometryObserver(
            to: lifecycleObservedContent
        )
        return addScrollPhaseObserver(to: geometryObservedContent)
    }

    private func addLifecycleObservers<ObservedContent: View>(
        to content: ObservedContent
    ) -> some View {
        content
            .onAppear {
                ChatBottomTrace.log("MOD_APPEAR " + chatBottomTracePosition)
                if initialBottomAnchorID == nil {
                    initialBottomAnchorID = bottomAnchorID
                }
                // The request counter is owned by ChatView while this modifier
                // is recreated per conversation. Establish the current value
                // as this instance's baseline so an older conversation's
                // unified-send token cannot be mistaken for a new handoff.
                consumedSendExactBottomHandoffRequest =
                    sendExactBottomHandoffRequest
                if let messageTargetReleaseID {
                    releaseBottomPosition(for: messageTargetReleaseID)
                }
                if let edgeNavigationReleaseID {
                    releaseBottomPosition(for: edgeNavigationReleaseID)
                }
                if let sendPositionReleaseID {
                    releaseBottomPosition(for: sendPositionReleaseID)
                }
                guard shouldPinToBottom,
                      contentReadyAnchorID == bottomAnchorID,
                      !hasAutomaticReasoningCollapseClaim else { return }
                guard !canReuseInitialBottomOffset() else { return }
                ChatBottomTrace.log("READY_PIN source=appear before " + chatBottomTracePosition)
                pinToBottom(source: "readyAppear")
                ChatBottomTrace.log("READY_PIN source=appear after " + chatBottomTracePosition)
            }
            .onDisappear {
                cancelKeyboardViewportMotion()
                messageTargetReleaseAckTask?.cancel()
                messageTargetReleaseAckTask = nil
                edgeNavigationReleaseAckTask?.cancel()
                edgeNavigationReleaseAckTask = nil
                sendPositionReleaseAckTask?.cancel()
                sendPositionReleaseAckTask = nil
                releasedEdgeNavigationID = nil
                releasedSendPositionID = nil
                keyboardViewportAnimationDeadline = .distantPast
                locallyClaimedAutomaticReasoningCollapseOwnerID = nil
            }
            .onChange(of: bottomAnchorID) { _, _ in
                cancelKeyboardViewportMotion()
                locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                ownsStreamingFollowTouchPause = false
            }
            .onChange(of: automaticReasoningCollapseOwnerID) { oldOwnerID, newOwnerID in
                if newOwnerID?.anchorID == bottomAnchorID {
                    locallyClaimedAutomaticReasoningCollapseOwnerID = newOwnerID
                } else if oldOwnerID?.anchorID == bottomAnchorID {
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                }
            }
            .onChange(of: automaticReasoningCollapseOwnerLifecycle) { _, _ in
                if automaticReasoningCollapseOwnerID?.anchorID == bottomAnchorID {
                    locallyClaimedAutomaticReasoningCollapseOwnerID =
                        automaticReasoningCollapseOwnerID
                } else {
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                }
            }
            .onChange(of: shouldPinToBottom) { _, shouldPin in
                ChatBottomTrace.log("SHOULD_PIN_CHANGE value=\(shouldPin) " + chatBottomTracePosition)
                if !shouldPin {
                    cancelKeyboardViewportMotion()
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                }
                let hasNewExactSendHandoff =
                    consumedSendExactBottomHandoffRequest
                        != sendExactBottomHandoffRequest
                if hasNewExactSendHandoff {
                    // Consume the generation even when readiness arrives in the
                    // next callback. Otherwise a later ordinary send can mistake
                    // this old unified handoff for its own semantic re-arm.
                    consumedSendExactBottomHandoffRequest =
                        sendExactBottomHandoffRequest
                }
                guard shouldPin,
                      contentReadyAnchorID == bottomAnchorID,
                      !hasAutomaticReasoningCollapseClaim else { return }
                if hasNewExactSendHandoff {
                    // This generation is emitted only after the concrete send
                    // tail and the underlying UIScrollView are both strictly
                    // exact with no touch or inertia. SwiftUI's geometry can
                    // lag that native fact by one frame, so it must not veto
                    // the already-authorized handoff and add a visible reset.
                    ChatBottomTrace.log(
                        "SHOULD_PIN_SKIP reason=exactSendHandoff "
                            + chatBottomTracePosition
                    )
                    return
                }
                guard !canReuseInitialBottomOffset() else { return }
                pinToBottom(source: "shouldPinChange")
                ChatBottomTrace.log("SHOULD_PIN_APPLIED " + chatBottomTracePosition)
            }
            .onChange(of: messageTargetReleaseID) { _, requestID in
                locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                guard let requestID else {
                    messageTargetReleaseAckTask?.cancel()
                    messageTargetReleaseAckTask = nil
                    releasedMessageTargetRequestID = nil
                    return
                }
                releaseBottomPosition(for: requestID)
            }
            .onChange(of: edgeNavigationReleaseID) { _, releaseID in
                guard let releaseID else {
                    edgeNavigationReleaseAckTask?.cancel()
                    edgeNavigationReleaseAckTask = nil
                    releasedEdgeNavigationID = nil
                    return
                }
                releaseBottomPosition(for: releaseID)
            }
            .onChange(of: edgeNavigationSequence) { oldSequence, newSequence in
                // A drawer/tap cancellation can finish without a native touch
                // phase. Drop the stored target as ownership ends. A successful
                // bottom landing keeps its existing follow handoff.
                guard oldSequence != nil, newSequence == nil,
                      !shouldPinToBottom else { return }
                releaseInterruptedEdgeNavigationPosition()
            }
            .onChange(of: sendPositionReleaseID) { _, releaseID in
                guard let releaseID else {
                    sendPositionReleaseAckTask?.cancel()
                    sendPositionReleaseAckTask = nil
                    releasedSendPositionID = nil
                    return
                }
                releaseBottomPosition(for: releaseID)
            }
            .onChange(of: automaticReasoningCollapseRearmRequest) {
                _,
                rearmRequest in
                guard let rearmRequest else { return }
                guard rearmRequest.ownerID.anchorID == bottomAnchorID,
                      automaticReasoningCollapseOwnerID
                        == rearmRequest.ownerID,
                      shouldPinToBottom,
                      contentReadyAnchorID == bottomAnchorID else {
                    ChatBottomTrace.log(
                        "REASONING_COLLAPSE_REARM_IGNORED"
                            + " generation=\(rearmRequest.ownerID.generation)"
                            + " attempt=\(rearmRequest.attempt) "
                            + chatBottomTracePosition
                    )
                    return
                }
                resetToBottom(source: "automaticReasoningCollapseRearm")
                onAutomaticReasoningCollapseBottomRearmed(
                    rearmRequest.ownerID
                )
                ChatBottomTrace.log(
                    "REASONING_COLLAPSE_REARM_APPLIED"
                        + " generation=\(rearmRequest.ownerID.generation)"
                        + " attempt=\(rearmRequest.attempt) "
                        + chatBottomTracePosition
                )
            }
            .onChange(of: edgeRearmRequest) { oldRequest, newRequest in
                ChatBottomTrace.log(
                    "EDGE_REARM_OBSERVED old=\(oldRequest) new=\(newRequest) before "
                        + chatBottomTracePosition
                )
                guard shouldPinToBottom,
                      contentReadyAnchorID == bottomAnchorID,
                      !hasAutomaticReasoningCollapseClaim else {
                    ChatBottomTrace.log("EDGE_REARM_REJECTED " + chatBottomTracePosition)
                    return
                }
                // User motion has already settled at the exact bottom, so
                // replacing the position restores persistent edge semantics
                // without moving the content or changing scroll physics.
                resetToBottom(source: "edgeRearm")
                ChatBottomTrace.log("EDGE_REARM_APPLIED after " + chatBottomTracePosition)
            }
            .onChange(of: contentReadyAnchorID) { _, readyAnchorID in
                if ChatBottomTrace.enabled {
                    let readyDescription = readyAnchorID.map {
                        "conv=\(ChatBottomTrace.shortID($0.positionRequest.conversationID))"
                            + "/\($0.positionRequest.request) rows=\($0.messageIDs.count)"
                    } ?? "nil"
                    ChatBottomTrace.log(
                        "CONTENT_READY_CHANGE value=\(readyDescription) before "
                            + chatBottomTracePosition
                    )
                }
                guard shouldPinToBottom,
                      readyAnchorID == bottomAnchorID,
                      !hasAutomaticReasoningCollapseClaim else {
                    ChatBottomTrace.log("READY_PIN_REJECTED " + chatBottomTracePosition)
                    return
                }
                guard !canReuseInitialBottomOffset() else { return }
                // Readiness is the exact conversation/request value reported by
                // its laid-out sentinel and concrete tail. Replace the semantic
                // position identity for this row revision so a large content
                // shrink cannot retain the deleted tail's absolute offset.
                ChatBottomTrace.log("READY_PIN source=contentReady before " + chatBottomTracePosition)
                resetToBottom(source: "contentReady")
                ChatBottomTrace.log("READY_PIN source=contentReady after " + chatBottomTracePosition)
            }
            .onChange(of: keyboardRequest) { oldRequest, newRequest in
                locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                ChatBottomTrace.log(
                    "KEYBOARD_RESET_OBSERVED old=\(oldRequest) new=\(newRequest) before "
                        + chatBottomTracePosition
                )
                guard shouldPinToBottom,
                      contentReadyAnchorID == bottomAnchorID else {
                    ChatBottomTrace.log("KEYBOARD_RESET_REJECTED " + chatBottomTracePosition)
                    return
                }
                guard keyboardDismissalRequest != newRequest else {
                    // The viewport-expansion geometry callback owns the visible
                    // keyboard-dismissal motion. Replacing its animated edge
                    // with a disabled reset here would snap straight to the
                    // final offset before the keyboard has moved.
                    ChatBottomTrace.log(
                        "KEYBOARD_RESET_DEFERRED reason=dismissalAnimation "
                            + chatBottomTracePosition
                    )
                    return
                }
                guard Date() >= keyboardViewportAnimationDeadline,
                      position.isPositionedByUser || position.edge != .bottom else {
                    // An already armed edge includes a running viewport
                    // animation. Replacing it here would cancel that motion.
                    return
                }
                // Recreate edge identity only for a keyboard transition.
                // Ordinary drag/deceleration/tap interactions keep their
                // user-positioned ScrollPosition and native physical feel.
                resetToBottom(source: "keyboardRequest")
                ChatBottomTrace.log("KEYBOARD_RESET_APPLIED after " + chatBottomTracePosition)
            }
    }

    private func addGeometryObserver<ObservedContent: View>(
        to content: ObservedContent
    ) -> some View {
        content
            .onScrollGeometryChange(for: IOS18ChatScrollGeometrySnapshot.self) { geometry in
                let bottomBoundaryY = geometry.contentSize.height + geometry.contentInsets.bottom
                let signedDistanceFromBottom = bottomBoundaryY - geometry.visibleRect.maxY
                return IOS18ChatScrollGeometrySnapshot(
                    anchorID: bottomAnchorID,
                    contentHeight: geometry.contentSize.height,
                    bottomBoundaryY: bottomBoundaryY,
                    containerHeight: geometry.containerSize.height,
                    signedDistanceFromBottom: signedDistanceFromBottom,
                    bottomOffsetY: geometry.contentOffset.y + signedDistanceFromBottom,
                    isAtBottom: abs(signedDistanceFromBottom) <= 2,
                    isNearBottom: signedDistanceFromBottom <= 56
                )
            } action: { previousSnapshot, snapshot in
                bottomDistanceMeasurement.signedDistanceFromBottom = snapshot.signedDistanceFromBottom
                onBottomStateChanged(
                    snapshot.anchorID,
                    snapshot.isAtBottom,
                    snapshot.isNearBottom
                )
                guard shouldPinToBottom,
                      contentReadyAnchorID == bottomAnchorID,
                      !isSystemScrollToTopAnimation else { return }
                if hasAutomaticReasoningCollapseClaim {
                    ChatBottomTrace.log(
                        "GEOMETRY_CORRECTION_DEFERRED reason=automaticReasoningCollapseOwner"
                            + " distance=\(String(format: "%.2f", snapshot.signedDistanceFromBottom)) "
                            + chatBottomTracePosition
                    )
                    return
                }

                let positionWasUserOwned = position.isPositionedByUser
                let contentHeightDelta = snapshot.contentHeight
                    - previousSnapshot.contentHeight
                let geometryDisposition =
                    onAutomaticReasoningCollapseGeometry(
                        AutomaticReasoningCollapseGeometryChange(
                            anchorID: snapshot.anchorID,
                            previousContentHeight:
                                previousSnapshot.contentHeight,
                            contentHeight: snapshot.contentHeight,
                            previousContainerHeight:
                                previousSnapshot.containerHeight,
                            containerHeight: snapshot.containerHeight,
                            signedDistanceFromBottom:
                                snapshot.signedDistanceFromBottom,
                            previousWasAtBottom:
                                previousSnapshot.isAtBottom,
                            positionWasUserOwned: positionWasUserOwned
                        )
                    ) { ownerID in
                        // Root calls this closure only after every admission
                        // guard and target calculation succeeds. Establish the
                        // local claim and release persistent `.bottom` before
                        // root installs the owner and writes UIKit once.
                        locallyClaimedAutomaticReasoningCollapseOwnerID = ownerID
                        position.isPositionedByUser = true
                        ChatBottomTrace.log(
                            "REASONING_COLLAPSE_LOCAL_CLAIM"
                                + " generation=\(ownerID.generation)"
                                + " oldContentH=\(String(format: "%.1f", previousSnapshot.contentHeight))"
                                + " contentH=\(String(format: "%.1f", snapshot.contentHeight))"
                                + " delta=\(String(format: "%.1f", contentHeightDelta)) "
                                + chatBottomTracePosition
                        )
                    }
                switch geometryDisposition {
                case let .owned(ownerID):
                    locallyClaimedAutomaticReasoningCollapseOwnerID = ownerID
                    cancelKeyboardViewportMotion()
                    ChatBottomTrace.log(
                        "GEOMETRY_CORRECTION_CLAIMED reason=automaticReasoningCollapse"
                            + " generation=\(ownerID.generation)"
                            + " distance=\(String(format: "%.2f", snapshot.signedDistanceFromBottom)) "
                            + chatBottomTracePosition
                    )
                    return
                case .pendingCollapseSample:
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                    ChatBottomTrace.log(
                        "GEOMETRY_CORRECTION_DEFERRED reason=reasoningCollapsePendingSample "
                            + chatBottomTracePosition
                    )
                    return
                case .consumedUnowned:
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                    // A recognized collapse decision must not submit a second
                    // semantic-bottom command in the same geometry pass.
                    ChatBottomTrace.log(
                        "GEOMETRY_CORRECTION_DEFERRED reason=reasoningCollapseAuthorizationConsumed "
                            + chatBottomTracePosition
                    )
                    return
                case .unowned:
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                }

                guard !positionWasUserOwned || Date() < keyboardViewportAnimationDeadline else {
                    ChatBottomTrace.log(
                        "GEOMETRY_CORRECTION_DEFERRED reason=userOwnedPosition "
                            + chatBottomTracePosition
                    )
                    return
                }
                let isKeyboardViewportChange = previousSnapshot.anchorID == snapshot.anchorID
                    && previousSnapshot.containerHeight > 100
                    && abs(snapshot.containerHeight - previousSnapshot.containerHeight) > 80
                if isKeyboardViewportChange {
                    animateBottomForKeyboardViewportChange(
                        bottomOffsetY: snapshot.bottomOffsetY,
                        previousOffsetY: previousSnapshot.bottomOffsetY
                            - previousSnapshot.signedDistanceFromBottom
                    )
                    return
                }
                guard !snapshot.isAtBottom else { return }
                if Date() < keyboardViewportAnimationDeadline {
                    // Content size and keyboard insets can commit separately.
                    // The active keyboard motion owns both geometry changes;
                    // retarget it instead of leaving a native clamp visible
                    // until the completion's semantic-bottom handoff.
                    animateBottomForKeyboardViewportChange(
                        bottomOffsetY: snapshot.bottomOffsetY,
                        isRetargeting: true
                    )
                    return
                }
                // LazyVStack/TextKit can settle over several layout passes.
                // React to the measured geometry instead of guessing a delay.
                pinToBottom(source: "geometryCorrection")
            }
    }

    private func addScrollPhaseObserver<ObservedContent: View>(
        to content: ObservedContent
    ) -> some View {
        content
            .onScrollPhaseChange { oldPhase, newPhase, context in
                let geometry = context.geometry
                let bottomBoundaryY = geometry.contentSize.height + geometry.contentInsets.bottom
                let signedDistanceFromBottom = bottomBoundaryY - geometry.visibleRect.maxY
                let isAtBottom = abs(signedDistanceFromBottom) <= 2
                let isNearBottom = signedDistanceFromBottom <= 56
                ChatBottomTrace.log(
                    "PHASE old=\(String(describing: oldPhase)) new=\(String(describing: newPhase))"
                        + " distance=\(String(format: "%.2f", signedDistanceFromBottom))"
                        + " boundaryY=\(String(format: "%.1f", bottomBoundaryY))"
                        + " visibleMaxY=\(String(format: "%.1f", geometry.visibleRect.maxY))"
                        + " containerH=\(String(format: "%.1f", geometry.containerSize.height))"
                        + " exact=\(isAtBottom) near=\(isNearBottom) "
                        + chatBottomTracePosition
                )
                if newPhase == .tracking || newPhase == .interacting {
                    if let sequence = edgeNavigationSequence,
                       onEdgeNavigationUserTouch(bottomAnchorID, sequence) {
                        // Tracking starts before the SwiftUI drag threshold:
                        // simply holding the transcript already cancels the jump.
                        releaseInterruptedEdgeNavigationPosition()
                    }
                    beginStreamingFollowTouchPauseIfNeeded()
                }
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    // A new user-owned motion after the recovery command must
                    // win over the delayed safety correction.
                    locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                    cancelKeyboardViewportMotion()
                    onScrollPhaseActivityChanged(
                        bottomAnchorID,
                        true,
                        isAtBottom,
                        isNearBottom
                    )
                    onScrollMotionChanged(bottomAnchorID, true, isAtBottom, isNearBottom)
                case .idle:
                    onScrollMotionChanged(bottomAnchorID, false, isAtBottom, isNearBottom)
                    ownsStreamingFollowTouchPause = false
                    onScrollPhaseActivityChanged(
                        bottomAnchorID,
                        false,
                        isAtBottom,
                        isNearBottom
                    )
                    if isSystemScrollToTopAnimation {
                        isSystemScrollToTopAnimation = false
                        ChatBottomTrace.log(
                            "SYSTEM_TOP_END distance=\(String(format: "%.2f", signedDistanceFromBottom)) "
                                + chatBottomTracePosition
                        )
                    }
                case .animating:
                    // A status-bar tap is reported as a system animation rather
                    // than tracking/interacting. Only infer that gesture while
                    // no collapse claim exists: the owner's own UIKit offset
                    // write can also report idle -> animating. Vertical drags
                    // remain explicit preemptors through the phases above.
                    let startsFromPinnedBottom = isAtBottom
                        || abs(bottomDistanceMeasurement.signedDistanceFromBottom) <= 2
                        || position.edge == .bottom
                    let beginsSystemScrollToTop = oldPhase == .idle
                        && shouldPinToBottom
                        && contentReadyAnchorID == bottomAnchorID
                        && !hasAutomaticReasoningCollapseClaim
                        && startsFromPinnedBottom
                        && Date() >= keyboardViewportAnimationDeadline
                    if beginsSystemScrollToTop {
                        locallyClaimedAutomaticReasoningCollapseOwnerID = nil
                        isSystemScrollToTopAnimation = true
                        // Apple defines this write as releasing any stored edge
                        // or point while preserving a user-positioned scroll.
                        position.isPositionedByUser = true
                        ChatBottomTrace.log(
                            "SYSTEM_TOP_RELEASE distance=\(String(format: "%.2f", signedDistanceFromBottom)) "
                                + chatBottomTracePosition
                        )
                        onSystemScrollToTopStarted(bottomAnchorID)
                    }
                    onScrollPhaseActivityChanged(
                        bottomAnchorID,
                        true,
                        isAtBottom,
                        isNearBottom
                    )
                }
            }
    }

    private func releaseInterruptedEdgeNavigationPosition() {
        cancelKeyboardViewportMotion()
        locallyClaimedAutomaticReasoningCollapseOwnerID = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.isPositionedByUser = true
        }
        ChatBottomTrace.log("EDGE_INTERRUPTION_NATIVE_RELEASE " + chatBottomTracePosition)
    }

    private func beginStreamingFollowTouchPauseIfNeeded() {
        guard shouldPauseStreamingFollowOnUserTouch,
              !ownsStreamingFollowTouchPause else { return }
        ownsStreamingFollowTouchPause = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Clear the retained `.bottom` edge without changing the visible
            // offset. Otherwise touch-up can reactivate that old edge and pull
            // the transcript across content that arrived during the hold.
            position.isPositionedByUser = true
        }
        ChatBottomTrace.log(
            "SCROLL_POSITION_RELEASE source=streamTouchPause "
                + chatBottomTracePosition
        )
    }

    private func releaseBottomPosition(for requestID: UUID) {
        guard releasedMessageTargetRequestID != requestID else {
            scheduleMessageTargetReleaseAcknowledgement(for: requestID)
            return
        }
        cancelKeyboardViewportMotion()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = ScrollPosition()
        }
        releasedMessageTargetRequestID = requestID
        ChatBottomTrace.log(
            "SCROLL_POSITION_RELEASE source=messageTarget"
                + " request=\(ChatBottomTrace.shortID(requestID)) "
                + chatBottomTracePosition
        )
        scheduleMessageTargetReleaseAcknowledgement(for: requestID)
    }

    private func releaseBottomPosition(
        for releaseID: EdgeNavigationNativeReleaseID
    ) {
        guard releaseID.sourceAnchorID == bottomAnchorID else { return }
        guard releasedEdgeNavigationID != releaseID else {
            scheduleEdgeNavigationReleaseAcknowledgement(for: releaseID)
            return
        }
        cancelKeyboardViewportMotion()
        locallyClaimedAutomaticReasoningCollapseOwnerID = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Preserve the currently visible offset while clearing any stored
            // edge/point semantics before the proxy mutates a message window.
            position.isPositionedByUser = true
        }
        releasedEdgeNavigationID = releaseID
        ChatBottomTrace.log(
            "SCROLL_POSITION_RELEASE source=edgeNavigation"
                + " sequence=\(releaseID.sequence) "
                + chatBottomTracePosition
        )
        scheduleEdgeNavigationReleaseAcknowledgement(for: releaseID)
    }

    private func releaseBottomPosition(
        for releaseID: SendPositionNativeReleaseID
    ) {
        guard releaseID.sourceAnchorID == bottomAnchorID else { return }
        guard releasedSendPositionID != releaseID else {
            scheduleSendPositionReleaseAcknowledgement(for: releaseID)
            return
        }
        cancelKeyboardViewportMotion()
        locallyClaimedAutomaticReasoningCollapseOwnerID = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.isPositionedByUser = true
        }
        releasedSendPositionID = releaseID
        ChatBottomTrace.log(
            "SCROLL_POSITION_RELEASE source=sendPosition"
                + " request=\(ChatBottomTrace.shortID(releaseID.requestID)) "
                + chatBottomTracePosition
        )
        scheduleSendPositionReleaseAcknowledgement(for: releaseID)
    }

    private func scheduleMessageTargetReleaseAcknowledgement(
        for requestID: UUID
    ) {
        messageTargetReleaseAckTask?.cancel()
        let releasedAnchorID = bottomAnchorID
        messageTargetReleaseAckTask = Task { @MainActor in
            await awaitNextMainQueueTurn()
            await awaitNextMainQueueTurn()
            guard !Task.isCancelled,
                  releasedMessageTargetRequestID == requestID,
                  messageTargetReleaseID == requestID,
                  bottomAnchorID == releasedAnchorID else {
                return
            }
            onMessageTargetPositionReleased(releasedAnchorID, requestID)
            if releasedMessageTargetRequestID == requestID {
                messageTargetReleaseAckTask = nil
            }
        }
    }

    private func scheduleEdgeNavigationReleaseAcknowledgement(
        for releaseID: EdgeNavigationNativeReleaseID
    ) {
        edgeNavigationReleaseAckTask?.cancel()
        let releasedAnchorID = bottomAnchorID
        edgeNavigationReleaseAckTask = Task { @MainActor in
            await awaitNextMainQueueTurn()
            await awaitNextMainQueueTurn()
            guard !Task.isCancelled,
                  releasedEdgeNavigationID == releaseID,
                  edgeNavigationReleaseID == releaseID,
                  bottomAnchorID == releasedAnchorID,
                  releasedAnchorID == releaseID.sourceAnchorID else {
                return
            }
            onEdgeNavigationPositionReleased(releasedAnchorID, releaseID)
            if releasedEdgeNavigationID == releaseID {
                edgeNavigationReleaseAckTask = nil
            }
        }
    }

    private func scheduleSendPositionReleaseAcknowledgement(
        for releaseID: SendPositionNativeReleaseID
    ) {
        sendPositionReleaseAckTask?.cancel()
        let releasedAnchorID = bottomAnchorID
        sendPositionReleaseAckTask = Task { @MainActor in
            await awaitNextMainQueueTurn()
            await awaitNextMainQueueTurn()
            guard !Task.isCancelled,
                  releasedSendPositionID == releaseID,
                  sendPositionReleaseID == releaseID,
                  bottomAnchorID == releasedAnchorID,
                  releasedAnchorID == releaseID.sourceAnchorID else {
                return
            }
            onSendPositionReleased(releasedAnchorID, releaseID)
            if releasedSendPositionID == releaseID {
                sendPositionReleaseAckTask = nil
            }
        }
    }

    private func awaitNextMainQueueTurn() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func canReuseInitialBottomOffset() -> Bool {
        // Readiness may be delivered before onAppear. Capture the same first
        // anchor there as well, without deferring or scheduling another write.
        if initialBottomAnchorID == nil {
            initialBottomAnchorID = bottomAnchorID
        }
        guard isOrdinaryConversationReturn,
              initialBottomAnchorID == bottomAnchorID,
              !position.isPositionedByUser,
              position.edge == nil,
              position.point == nil,
              abs(bottomDistanceMeasurement.signedDistanceFromBottom) <= 2
        else { return false }
        // InitialOffset has already placed this revision exactly at bottom.
        // Avoid replacing that natural layout with a second edge declaration.
        // All baseline geometry correction and tail recovery remain eligible.
        ChatBottomTrace.log("INITIAL_BOTTOM_REUSE " + chatBottomTracePosition)
        return true
    }

    private func pinToBottom(source: String) {
        ChatBottomTrace.log(
            "SCROLL_COMMAND source=native.\(source)"
                + " target=edge.bottom animation=disabled before "
                + chatBottomTracePosition
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(edge: .bottom)
        }
        ChatBottomTrace.log(
            "SCROLL_COMMAND source=native.\(source)"
                + " target=edge.bottom animation=disabled after "
                + chatBottomTracePosition
        )
    }

    private func animateBottomForKeyboardViewportChange(
        bottomOffsetY: CGFloat,
        previousOffsetY: CGFloat? = nil,
        isRetargeting: Bool = false
    ) {
        guard let scrollView = scrollViewBox.scrollView,
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating else { return }
        let wasAnimating = Date() < keyboardViewportAnimationDeadline
        let presentedOffsetY = scrollView.layer.presentation()?.bounds.origin.y
        // A semantic edge or content-size clamp can already have changed the
        // model offset. Start from the visible position, not that interim
        // model value; the previous geometry is the settled initial position.
        let startOffsetY = wasAnimating
            ? (presentedOffsetY ?? scrollView.contentOffset.y)
            : (previousOffsetY ?? presentedOffsetY ?? scrollView.contentOffset.y)
        guard abs(startOffsetY - bottomOffsetY) > 0.5
                || abs(scrollView.contentOffset.y - bottomOffsetY) > 0.5 else {
            return
        }
        let duration: TimeInterval
        if isRetargeting, wasAnimating {
            duration = max(0.01, keyboardViewportAnimationDeadline.timeIntervalSinceNow - 0.06)
        } else {
            duration = max(0.01, keyboardAnimationDuration)
            keyboardViewportAnimationDeadline = Date().addingTimeInterval(duration + 0.06)
        }
        // Release semantic edge layout while UIKit owns this transition.
        position.isPositionedByUser = true
        let start = CGPoint(x: scrollView.contentOffset.x, y: startOffsetY)
        let target = CGPoint(x: start.x, y: bottomOffsetY)
        let options = UIView.AnimationOptions(
            rawValue: UInt(max(0, keyboardAnimationCurveRawValue)) << 16
        ).union([.beginFromCurrentState, .allowUserInteraction, .overrideInheritedDuration])
        ChatBottomTrace.log(
            "SCROLL_COMMAND source=native.keyboardViewportAnimation"
                + " retarget=\(isRetargeting)"
                + " startY=\(String(format: "%.2f", startOffsetY))"
                + " targetY=\(String(format: "%.2f", bottomOffsetY))"
                + " nativeOffsetY=\(String(format: "%.2f", scrollView.contentOffset.y))"
                + " nativeBottomY=\(String(format: "%.2f", max(-scrollView.adjustedContentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)))"
                + " duration=\(String(format: "%.3f", duration)) "
                + chatBottomTracePosition
        )
        removeContentOffsetAnimations(from: scrollView)
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(start, animated: false)
        }
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            scrollView.setContentOffset(target, animated: false)
        }
        scheduleKeyboardViewportCompletion(after: duration)
    }

    private func removeContentOffsetAnimations(from scrollView: UIScrollView) {
        // UIKit can add multiple additive animations for the same property
        // (bounds.origin, bounds.origin-2, ...). Replacing only the first one
        // leaves another delta applied on top of the new keyboard motion.
        for key in scrollView.layer.animationKeys() ?? [] {
            guard let animation = scrollView.layer.animation(forKey: key) as? CAPropertyAnimation,
                  animation.keyPath == "bounds.origin" else { continue }
            scrollView.layer.removeAnimation(forKey: key)
        }
    }

    private func cancelKeyboardViewportMotion() {
        keyboardViewportCompletionTask?.cancel()
        keyboardViewportCompletionTask = nil
        if Date() < keyboardViewportAnimationDeadline,
           let scrollView = scrollViewBox.scrollView {
            let presentedOffset = scrollView.layer.presentation()?.bounds.origin
                ?? scrollView.contentOffset
            removeContentOffsetAnimations(from: scrollView)
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(presentedOffset, animated: false)
            }
        }
        keyboardViewportAnimationDeadline = .distantPast
    }

    private func scheduleKeyboardViewportCompletion(after duration: TimeInterval) {
        keyboardViewportCompletionTask?.cancel()
        keyboardViewportCompletionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.08))
            guard !Task.isCancelled else { return }
            keyboardViewportAnimationDeadline = .distantPast
            guard shouldPinToBottom,
                  contentReadyAnchorID == bottomAnchorID,
                  !hasAutomaticReasoningCollapseClaim else {
                ChatBottomTrace.log(
                    "KEYBOARD_VIEWPORT_COMPLETION branch=drop-ineligible"
                        + " collapseClaim=\(hasAutomaticReasoningCollapseClaim) "
                        + chatBottomTracePosition
                )
                keyboardViewportCompletionTask = nil
                return
            }
            ChatBottomTrace.log(
                "KEYBOARD_VIEWPORT_COMPLETION"
                    + " distance=\(String(format: "%.2f", bottomDistanceMeasurement.signedDistanceFromBottom)) "
                    + chatBottomTracePosition
            )
            resetToBottom(source: "keyboardViewportCompletion")
            keyboardViewportCompletionTask = nil
        }
    }

    private func resetToBottom(source: String) {
        ChatBottomTrace.log(
            "SCROLL_COMMAND source=nativeReset.\(source)"
                + " target=edge.bottom animation=disabled before "
                + chatBottomTracePosition
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = ScrollPosition(edge: .bottom)
        }
        ChatBottomTrace.log(
            "SCROLL_COMMAND source=nativeReset.\(source)"
                + " target=edge.bottom animation=disabled after "
                + chatBottomTracePosition
        )
    }
}

private struct CalendarPill: View {
    @Environment(AppModel.self) private var model
    let interactionOnly: Bool

    init(interactionOnly: Bool = false) {
        self.interactionOnly = interactionOnly
    }

    private var displayName: String {
        model.selectedConversationIsGroupChat ? L10n.lookup("群聊") : model.currentAssistant.name
    }

    var body: some View {
        HStack(spacing: 6) {
            SponsorWearableAvatar(target: .assistant, badgeSize: 13) {
                AssistantAvatarView(
                    profile: model.selectedConversationDisplayAssistant,
                    size: 22
                )
            }

            Text(displayName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .opacity(interactionOnly ? 0 : 1)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background {
            if !interactionOnly {
                GlassSurface(shape: Capsule())
            }
        }
        // The visible pill is compact, while the transparent iOS 26
        // interaction twin keeps the original comfortable 50pt height.
        .frame(height: 50)
        .contentShape(Capsule())
        .gesture(
            LongPressGesture(minimumDuration: 0.42, maximumDistance: 18)
                .exclusively(before: TapGesture())
                .onEnded { value in
                    switch value {
                    case .first(true):
                        model.performCardHaptic()
                        model.isCalendarPresented = true
                    case .second:
                        model.performCardHaptic()
                        model.isAssistantSelectorPresented = true
                    default:
                        break
                    }
                }
        )
        .accessibilityLabel(L10n.format("当前助手：%@", [String(describing: displayName)]))
        .accessibilityHint(L10n.lookup("轻点选择助手，长按打开共享日历"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            model.performCardHaptic()
            model.isAssistantSelectorPresented = true
        }
        .accessibilityAction(named: Text(L10n.lookup("打开共享日历"))) {
            model.performCardHaptic()
            model.isCalendarPresented = true
        }
    }
}

private struct EmptyConversationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @State private var armedSponsorTier: SponsorTier?
    @State private var wornAssistantItem: SponsorWardrobeItem?
    @State private var sponsorDropEvents: [SponsorEasterEggDropEvent] = []
    @State private var sponsorEggTapCount = 0
    @State private var sponsorEggShakePhase: CGFloat = 0

    private var setupAccent: Color {
        Color(uiColor: model.themeActionUIColor)
    }

    var body: some View {
        Group {
            if model.hasReadyChatModel {
                VStack(spacing: 16) {
                    ZStack(alignment: .topTrailing) {
                        AssistantAvatarView(
                            profile: model.selectedConversationDisplayAssistant,
                            size: 68
                        )

                        if let armedSponsorTier {
                            Button {
                                tapSponsorEasterEgg()
                            } label: {
                                SponsorAvatarBadgeIcon(
                                    item: SponsorWardrobeItem(tier: armedSponsorTier),
                                    size: 28
                                )
                                .padding(6)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .modifier(
                                SponsorEasterEggShakeEffect(
                                    amount: reduceMotion ? 0 : 4.5,
                                    phase: sponsorEggShakePhase
                                )
                            )
                            .accessibilityLabel(
                                L10n.format("%@彩蛋", [String(describing: armedSponsorTier.chatBadgeName)])
                            )
                            .accessibilityHint(L10n.lookup("前两次会摇晃，第三次会掉下来"))
                        }

                        if armedSponsorTier == nil, let wornAssistantItem {
                            Button {
                                dropWornSponsorEasterEgg(wornAssistantItem)
                            } label: {
                                SponsorAvatarBadgeIcon(
                                    item: wornAssistantItem,
                                    size: 28
                                )
                                .padding(6)
                                .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .accessibilityLabel(L10n.format("点一下%@彩蛋", [L10n.lookup(wornAssistantItem.name)]))
                            .accessibilityHint(L10n.lookup("会掉下同款小彩蛋"))
                        }

                        ForEach(sponsorDropEvents) { event in
                            SponsorEasterEggDropView(event: event)
                                .id(event.id)
                        }
                    }

                    Text(model.selectedConversationIsGroupChat ? L10n.lookup("和大家聊点什么") : L10n.format("和 %@聊点什么", [String(describing: model.currentAssistant.name)]))
                        .font(.system(size: 22, weight: .semibold))

                    if model.selectedConversationIsGroupChat {
                        Text(model.selectedConversationAssistantNames)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(setupAccent)
                        .frame(width: 72, height: 72)
                        .background(setupAccent.opacity(0.11), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(setupAccent.opacity(0.18), lineWidth: 0.8)
                        }

                    VStack(spacing: 7) {
                        Text(L10n.lookup("还没有连接聊天模型"))
                            .font(.system(size: 22, weight: .semibold))
                        Text(L10n.lookup("添加服务商的 API Key 和模型后，就可以开始聊天。"))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        model.performCardHaptic()
                        model.isProviderSettingsPresented = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(L10n.lookup("连接模型"))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(setupAccent, in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                        }
                        .shadow(color: setupAccent.opacity(0.18), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: model.selectedConversationID) {
            refreshSponsorEasterEgg()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sponsorEasterEggDidChange)) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                refreshSponsorEasterEgg()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func refreshSponsorEasterEgg() {
        let nextArmedTier = SponsorEasterEggPersistence.armedTier(
            for: model.selectedConversationID
        )
        if nextArmedTier != armedSponsorTier {
            sponsorEggTapCount = 0
            sponsorEggShakePhase = 0
        }
        armedSponsorTier = nextArmedTier
        wornAssistantItem = SponsorEasterEggPersistence.wornWardrobeItem(
            for: .assistant
        )
    }

    private func tapSponsorEasterEgg() {
        guard armedSponsorTier != nil else { return }
        model.performCardHaptic()

        if sponsorEggTapCount < 2 {
            sponsorEggTapCount += 1
            withAnimation(.linear(duration: 0.38)) {
                sponsorEggShakePhase += 1
            }
        } else {
            sponsorEggTapCount = 0
            dropSponsorEasterEgg()
        }
    }

    private func dropSponsorEasterEgg() {
        guard let tier = SponsorEasterEggPersistence.consumeArmedEgg(
            for: model.selectedConversationID
        ) else { return }

        let event = SponsorEasterEggDropEvent(
            item: SponsorWardrobeItem(tier: tier),
            particleCount: 1
        )
        appendSponsorDropEvent(event)
        refreshSponsorEasterEgg()
    }

    private func dropWornSponsorEasterEgg(_ item: SponsorWardrobeItem) {
        model.performCardHaptic()
        appendSponsorDropEvent(
            SponsorEasterEggDropEvent(item: item, particleCount: 4)
        )
    }

    private func appendSponsorDropEvent(_ event: SponsorEasterEggDropEvent) {
        sponsorDropEvents.append(event)
        if sponsorDropEvents.count > 3 {
            sponsorDropEvents.removeFirst(sponsorDropEvents.count - 3)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.15))
            sponsorDropEvents.removeAll { $0.id == event.id }
        }
    }
}

private struct SponsorEasterEggShakeEffect: GeometryEffect {
    let amount: CGFloat
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(phase * .pi * 6)
        return ProjectionTransform(
            CGAffineTransform(translationX: translation, y: 0)
        )
    }
}

private struct SponsorEasterEggDropEvent: Identifiable {
    let id = UUID()
    let item: SponsorWardrobeItem
    let particleCount: Int
}

private struct SponsorEasterEggDropView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let event: SponsorEasterEggDropEvent
    @State private var dropped = false

    var body: some View {
        ZStack {
            ForEach(0..<max(1, event.particleCount), id: \.self) { index in
                Text(event.item.emoji)
                    .font(.system(size: index.isMultiple(of: 2) ? 21 : 18))
                    .frame(width: 30, height: 30)
                    .offset(
                        x: dropped
                            ? CGFloat((index % 3) - 1) * 18 - 7
                            : 7,
                        y: dropped
                            ? (reduceMotion ? 20 : 78 + CGFloat(index % 2) * 22)
                            : -7
                    )
                    .rotationEffect(
                        .degrees(
                            dropped && !reduceMotion
                                ? Double((index - 1) * 28)
                                : 0
                        )
                    )
                    .scaleEffect(dropped ? 0.62 : 1)
                    .opacity(dropped ? 0 : 1)
                    .animation(
                        .easeIn(duration: reduceMotion ? 0.32 : 0.82)
                            .delay(Double(index) * 0.045),
                        value: dropped
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            dropped = true
        }
    }
}

private struct MessageBlankLongPressSurface: UIViewRepresentable {
    let onLongPress: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        recognizer.minimumPressDuration = 0.5
        recognizer.allowableMovement = 10
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onLongPress = onLongPress
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLongPress: (CGPoint) -> Void

        init(onLongPress: @escaping (CGPoint) -> Void) {
            self.onLongPress = onLongPress
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  DrawerInlineActionTapGate.allowsAction else {
                return
            }
            onLongPress(recognizer.location(in: recognizer.view?.window))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct UserBubbleSendAnimationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented: Bool
    @State private var didStart = false

    let style: UserBubbleSendAnimationStyle
    let request: UserBubbleSendAnimationRequest?
    let isEnabled: Bool
    let onStarted: (UUID) -> Void

    init(
        style: UserBubbleSendAnimationStyle,
        request: UserBubbleSendAnimationRequest?,
        isEnabled: Bool,
        onStarted: @escaping (UUID) -> Void
    ) {
        self.style = style
        self.request = request
        self.isEnabled = isEnabled
        self.onStarted = onStarted
        _isPresented = State(
            initialValue: request?.style != style || !isEnabled
        )
    }

    private var matchingRequest: UserBubbleSendAnimationRequest? {
        request?.style == style ? request : nil
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if matchingRequest != nil || didStart {
            let transform = initialTransform(for: style)
            let showsEntranceStart = !isPresented
                && matchingRequest != nil
                && isEnabled
                && !reduceMotion
            content
                .scaleEffect(
                    showsEntranceStart ? transform.scale : 1,
                    anchor: .bottomTrailing
                )
                .opacity(showsEntranceStart ? transform.opacity : 1)
                .offset(
                    x: showsEntranceStart ? transform.offset.width : 0,
                    y: showsEntranceStart ? transform.offset.height : 0
                )
                .onAppear {
                    startIfNeeded()
                }
                .onChange(of: isEnabled) { _, enabled in
                    guard !enabled else { return }
                    revealWithoutAnimation()
                    if let request = matchingRequest {
                        onStarted(request.id)
                    }
                }
        } else {
            content
        }
    }

    private func startIfNeeded() {
        guard !didStart else { return }
        guard let request = matchingRequest else {
            revealWithoutAnimation()
            return
        }
        didStart = true

        guard isEnabled, !reduceMotion else {
            revealWithoutAnimation()
            onStarted(request.id)
            return
        }

        withAnimation(animation(for: style)) {
            isPresented = true
        }
        onStarted(request.id)
    }

    private func revealWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
        }
    }

    private func initialTransform(
        for style: UserBubbleSendAnimationStyle
    ) -> (scale: CGFloat, opacity: Double, offset: CGSize) {
        switch style {
        case .softPop:
            (0.86, 0.34, CGSize(width: 8, height: 10))
        case .floatUp:
            (1, 0.90, CGSize(width: 0, height: 46))
        case .lively:
            (1, 1, .zero)
        }
    }

    private func animation(for style: UserBubbleSendAnimationStyle) -> Animation {
        switch style {
        case .softPop:
            .spring(response: 0.36, dampingFraction: 0.72, blendDuration: 0.06)
        case .floatUp:
            .spring(response: 0.40, dampingFraction: 0.90, blendDuration: 0.04)
        case .lively:
            .snappy(duration: 0.32, extraBounce: 0.10)
        }
    }
}

private struct UserBubbleFloatUpPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct UserBubbleFloatUpFadeAnimationEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var userBubbleFloatUpPresented: Bool {
        get { self[UserBubbleFloatUpPresentedKey.self] }
        set { self[UserBubbleFloatUpPresentedKey.self] = newValue }
    }

    var userBubbleFloatUpFadeAnimationEnabled: Bool {
        get { self[UserBubbleFloatUpFadeAnimationEnabledKey.self] }
        set { self[UserBubbleFloatUpFadeAnimationEnabledKey.self] = newValue }
    }
}

private struct UserBubbleFloatUpBubbleFadeModifier: ViewModifier {
    @Environment(\.userBubbleFloatUpPresented) private var isPresented
    @Environment(\.userBubbleFloatUpFadeAnimationEnabled) private var isAnimationEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0.78)
            .animation(
                isAnimationEnabled ? .easeOut(duration: 0.14) : nil,
                value: isPresented
            )
    }
}

private struct UserBubbleFloatUpSendAnimationModifier: ViewModifier {
    private struct TaskKey: Hashable {
        let requestID: UUID?
        let isEnabled: Bool
        let reduceMotion: Bool
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented: Bool
    @State private var latchedRequestID: UUID?

    let isEnabled: Bool
    let onStarted: (UUID) -> Void

    init(
        request: UserBubbleSendAnimationRequest?,
        isEnabled: Bool,
        onStarted: @escaping (UUID) -> Void
    ) {
        let requestID: UUID? = request?.style == .floatUp ? request?.id : nil
        self.isEnabled = isEnabled
        self.onStarted = onStarted
        _isPresented = State(initialValue: requestID == nil || !isEnabled)
        _latchedRequestID = State(initialValue: requestID)
    }

    private var effectivePresented: Bool {
        isPresented || !isEnabled || reduceMotion
    }

    private var taskKey: TaskKey {
        TaskKey(
            requestID: latchedRequestID,
            isEnabled: isEnabled,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.userBubbleFloatUpPresented, effectivePresented)
            .environment(
                \.userBubbleFloatUpFadeAnimationEnabled,
                isEnabled && !reduceMotion
            )
            .offset(y: effectivePresented ? 0 : 18)
            .task(id: taskKey) {
                await startIfNeeded()
            }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled, let requestID = latchedRequestID else { return }
                revealAndConsume(requestID)
            }
            .onChange(of: reduceMotion) { _, shouldReduce in
                guard shouldReduce, let requestID = latchedRequestID else { return }
                revealAndConsume(requestID)
            }
            .onDisappear {
                guard let requestID = latchedRequestID else { return }
                // LazyVStack may temporarily remove the newly inserted row
                // before the delayed launch task presents it. Consuming the
                // request while `isPresented` is still false leaves preserved
                // local state permanently translucent when the row returns.
                // Fail open visually before clearing the one-shot request.
                revealAndConsume(requestID)
            }
    }

    @MainActor
    private func startIfNeeded() async {
        guard let requestID = latchedRequestID, !isPresented else { return }
        guard isEnabled, !reduceMotion else {
            revealAndConsume(requestID)
            return
        }

        do {
            // Let the offset first state reach a separate display turn before
            // starting the movement, so insertion work cannot swallow frame 1.
            try await Task.sleep(for: .milliseconds(18))
        } catch {
            return
        }
        guard !Task.isCancelled, isEnabled, !reduceMotion else { return }

        withAnimation(.smooth(duration: 0.26)) {
            isPresented = true
        }

        do {
            // Keep the request latched until the local animation has finished;
            // consuming it synchronously used to refresh the chat on frame 1.
            try await Task.sleep(for: .milliseconds(280))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        consume(requestID)
    }

    @MainActor
    private func revealAndConsume(_ requestID: UUID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
        }
        consume(requestID)
    }

    @MainActor
    private func consume(_ requestID: UUID) {
        guard latchedRequestID == requestID else { return }
        latchedRequestID = nil
        onStarted(requestID)
    }
}

private struct UserBubbleLivelyPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct UserBubbleLivelyFadeAnimationEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var userBubbleLivelyPresented: Bool {
        get { self[UserBubbleLivelyPresentedKey.self] }
        set { self[UserBubbleLivelyPresentedKey.self] = newValue }
    }

    var userBubbleLivelyFadeAnimationEnabled: Bool {
        get { self[UserBubbleLivelyFadeAnimationEnabledKey.self] }
        set { self[UserBubbleLivelyFadeAnimationEnabledKey.self] = newValue }
    }
}

private struct UserBubbleLivelyBubbleFadeModifier: ViewModifier {
    @Environment(\.userBubbleLivelyPresented) private var isPresented
    @Environment(\.userBubbleLivelyFadeAnimationEnabled) private var isAnimationEnabled

    func body(content: Content) -> some View {
        content
            .opacity(isPresented ? 1 : 0.46)
            .animation(
                isAnimationEnabled ? .easeOut(duration: 0.12) : nil,
                value: isPresented
            )
    }
}

private struct UserBubbleLivelySendAnimationModifier: ViewModifier {
    private struct TaskKey: Hashable {
        let requestID: UUID?
        let isEnabled: Bool
        let reduceMotion: Bool
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented: Bool
    @State private var latchedRequestID: UUID?

    let isEnabled: Bool
    let onStarted: (UUID) -> Void

    init(
        request: UserBubbleSendAnimationRequest?,
        isEnabled: Bool,
        onStarted: @escaping (UUID) -> Void
    ) {
        let requestID: UUID? = request?.style == .lively ? request?.id : nil
        self.isEnabled = isEnabled
        self.onStarted = onStarted
        _isPresented = State(initialValue: requestID == nil || !isEnabled)
        _latchedRequestID = State(initialValue: requestID)
    }

    private var effectivePresented: Bool {
        isPresented || !isEnabled || reduceMotion
    }

    private var taskKey: TaskKey {
        TaskKey(
            requestID: latchedRequestID,
            isEnabled: isEnabled,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .environment(\.userBubbleLivelyPresented, effectivePresented)
            .environment(
                \.userBubbleLivelyFadeAnimationEnabled,
                isEnabled && !reduceMotion
            )
            .scaleEffect(
                x: effectivePresented ? 1 : 0.78,
                y: effectivePresented ? 1 : 0.86,
                anchor: .bottomTrailing
            )
            .offset(
                x: effectivePresented ? 0 : 12,
                y: effectivePresented ? 0 : 16
            )
            .task(id: taskKey) {
                await startIfNeeded()
            }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled, let requestID = latchedRequestID else { return }
                revealAndConsume(requestID)
            }
            .onChange(of: reduceMotion) { _, shouldReduce in
                guard shouldReduce, let requestID = latchedRequestID else { return }
                revealAndConsume(requestID)
            }
            .onDisappear {
                guard let requestID = latchedRequestID else { return }
                // Match Float Up's fail-open lifetime: a lazy-row removal must
                // never preserve the compact/translucent pre-animation state.
                revealAndConsume(requestID)
            }
    }

    @MainActor
    private func startIfNeeded() async {
        guard let requestID = latchedRequestID, !isPresented else { return }
        guard isEnabled, !reduceMotion else {
            revealAndConsume(requestID)
            return
        }

        do {
            // Commit the compact origin for one display turn so insertion and
            // send-position work cannot swallow the first visible frame.
            try await Task.sleep(for: .milliseconds(16))
        } catch {
            return
        }
        guard !Task.isCancelled, isEnabled, !reduceMotion else { return }

        withAnimation(.snappy(duration: 0.32, extraBounce: 0.10)) {
            isPresented = true
        }

        do {
            // Keep the request latched through the spring's perceptual end.
            try await Task.sleep(for: .milliseconds(360))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        consume(requestID)
    }

    @MainActor
    private func revealAndConsume(_ requestID: UUID) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = true
        }
        consume(requestID)
    }

    @MainActor
    private func consume(_ requestID: UUID) {
        guard latchedRequestID == requestID else { return }
        latchedRequestID = nil
        onStarted(requestID)
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var assistantEditorProfile: AssistantProfile? = nil
    @State private var assistantAttachmentsExpanded = false
    let message: ChatMessage
    let citationSources: [MessageCitationSource]
    let isGroupMessage: Bool
    let versionFlashContext: VersionFlashTextContext?
    var allowsTextSelection = true
    let contentMutationBridge: MessageContentMutationBridge
    let userSendAnimationRequest: UserBubbleSendAnimationRequest?
    let userSendAnimationEnabled: Bool
    let onUserSendAnimationStarted: (UUID) -> Void
    let onReaction: (ChatMessage, CGPoint) -> Void
    let onUserReaction: (ChatMessage, String?) -> Void
    let onMore: (ChatMessage) -> Void
    let onEdit: (ChatMessage) -> Void
    let onRegenerate: (ChatMessage) -> Void
    let onStreamingReasoningCollapseChanged: (UUID, UUID, Bool) -> Void
    let onSelectVersion: (ChatMessage, ChatMessage) -> Void

    private var createdTimeText: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private var hasUserMetadata: Bool {
        model.preferences.showUserName || model.preferences.showUserTimestamp
    }

    private var hasAssistantMetadata: Bool {
        model.preferences.showModelName
            || model.preferences.showModelTimestamp
            || model.preferences.showProviderInChatMessage
    }

    private var userMessageTextMaxWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.64, 270)
    }

    private var assistantUsesWideTextLayout: Bool {
        (isGroupMessage && !model.preferences.groupChatForceAssistantBubble)
            || (assistantBubbleStyle == .defaultStyle && assistantBubbleOpacity <= 0.14)
    }

    private var assistantAttachments: (searchImages: [MessageAttachment], other: [MessageAttachment]) {
        message.attachments.reduce(into: (searchImages: [], other: [])) { result, attachment in
            if attachment.kind == .image && attachment.metadata["source"] == "web_search_image" {
                result.searchImages.append(attachment)
            } else {
                result.other.append(attachment)
            }
        }
    }

    var body: some View {
        let messageFontSize = 18 * CGFloat(model.preferences.chatFontScale)
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: model.preferences.showUserAvatar ? 24 : 54)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .trailing, spacing: 6) {
                        if hasUserMetadata {
                            HStack(spacing: 6) {
                                if model.preferences.showUserName {
                                    Text(model.userProfile.nickname)
                                }
                                if model.preferences.showUserTimestamp {
                                    Text(createdTimeText)
                                }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        }
                        if !message.attachments.isEmpty {
                            MessageAttachmentsView(
                                attachments: message.attachments,
                                collapsesImages: true,
                                collapsedImagesAreExcludedFromHistory: true,
                                scrollsMultipleImagesHorizontally: true,
                                imagesExpanded: Binding(
                                    get: { message.historicalImagesCollapsed != true },
                                    set: { expanded in
                                        model.setHistoricalImagesCollapsed(
                                            !expanded,
                                            for: message.id
                                        )
                                    }
                                )
                            )
                            .modifier(userNativeContextMenu)
                        }
                        if !message.text.isEmpty {
                            userMessageBubble(
                                text: message.text,
                                messageFontSize: messageFontSize,
                                isStreaming: message.isStreaming
                            )
                        }
                    }
                    .modifier(UserBubbleFloatUpBubbleFadeModifier())
                    .modifier(UserBubbleLivelyBubbleFadeModifier())
                    .modifier(
                        UserBubbleSendAnimationModifier(
                            style: .softPop,
                            request: userSendAnimationRequest,
                            isEnabled: userSendAnimationEnabled,
                            onStarted: onUserSendAnimationStarted
                        )
                    )
                    .modifier(
                        UserBubbleLivelySendAnimationModifier(
                            request: userSendAnimationRequest,
                            isEnabled: userSendAnimationEnabled,
                            onStarted: onUserSendAnimationStarted
                        )
                    )
                    if model.preferences.showUserAvatar {
                        UserProfileAvatarView(profile: model.userProfile, size: 30)
                    }
                }
                .modifier(
                    UserBubbleFloatUpSendAnimationModifier(
                        request: userSendAnimationRequest,
                        isEnabled: userSendAnimationEnabled,
                        onStarted: onUserSendAnimationStarted
                    )
                )
            } else {
                let assistant = model.displayAssistant(for: message)
                let attachments = assistantAttachments
                if assistantUsesWideTextLayout {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.preferences.showModelIcon || hasAssistantMetadata {
                            HStack(spacing: 10) {
                                if model.preferences.showModelIcon {
                                    assistantSettingsButton(for: assistant)
                                }

                                if hasAssistantMetadata {
                                    HStack(spacing: 6) {
                                        if model.preferences.showModelName {
                                            Text(assistant.useAssistantName ? assistant.name : model.modelTitle(for: assistant))
                                                .fontWeight(.semibold)
                                        }
                                        if model.preferences.showProviderInChatMessage,
                                           let providerTitle = model.providerTitle(for: message) {
                                            Text(providerTitle)
                                        }
                                        if model.preferences.showModelTimestamp {
                                            Text(createdTimeText)
                                        }
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        ForEach(message.reasoningSegments) { segment in
                            ReasoningCard(
                                message: message,
                                segment: segment,
                                allowsTextSelection: allowsTextSelection,
                                startsCollapsed:
                                    model.preferences.fullyCollapseThinking,
                                onStreamingCollapseChanged:
                                    onStreamingReasoningCollapseChanged
                            )
                        }
                        if !message.toolEvents.isEmpty {
                            ToolEventsCard(toolEvents: message.toolEvents)
                        }
                        if !attachments.other.isEmpty {
                            MessageAttachmentsView(
                                attachments: attachments.other,
                                alignment: .leading,
                                collapsesImages: true,
                                imagesExpanded: $assistantAttachmentsExpanded
                            )
                        }
                        if message.text.isEmpty && message.isStreaming && message.reasoningSegments.isEmpty && message.toolEvents.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color(uiColor: .secondaryLabel))
                        } else if !message.text.isEmpty || !message.isStreaming {
                            ForEach(Array(assistantTextSegments.enumerated()), id: \.offset) { segmentIndex, text in
                                MessageMarkdownView(
                                    text: text,
                                    fontSize: messageFontSize,
                                    lineSpacing: CGFloat(model.preferences.assistantMessageLineSpacing),
                                    listItemSpacing: CGFloat(model.preferences.assistantMarkdownListItemSpacing),
                                    blockSpacingScale: CGFloat(model.preferences.assistantMarkdownBlockSpacingScale),
                                    isStreaming: message.isStreaming,
                                    rendersMarkdown: model.preferences.enableAssistantMarkdown,
                                    htmlRunnerEnabled: model.preferences.htmlRunnerEnabled,
                                    htmlRunnerAllowCurrentChat: model.preferences.htmlRunnerAllowCurrentChat,
                                    htmlRunnerConversationID: message.conversationID,
                                    autoCollapseCodeBlock: model.preferences.autoCollapseCodeBlock,
                                    collapsedCodeLineLimit: model.preferences.autoCollapseCodeBlockLines,
                                    codeBlockAppearance: model.preferences.codeBlockAppearance,
                                    allowsTextSelection: allowsTextSelection,
                                    prefersUnifiedNativeSelection: true,
                                    foregroundColor: chatTextColor(for: .assistant) ?? Color(uiColor: .label),
                                    largeHeadingColor: Color(argb: model.preferences.assistantLargeHeadingColorARGB),
                                    smallHeadingColor: Color(argb: model.preferences.assistantSmallHeadingColorARGB),
                                    selectionTintColor: Color(uiColor: model.themeTextSelectionUIColor),
                                    fontName: model.preferences.appFontPostScriptName,
                                    versionFlashContext: versionFlashContext,
                                    versionFlashSegmentIndex: segmentIndex,
                                    citationSources: citationSources,
                                    contentMutationContext: contentMutationBridge.context(
                                        region: .messageText(segmentIndex)
                                    )
                                )
                                .foregroundStyle(chatTextColor(for: .assistant) ?? Color.primary)
                                .padding(.vertical, 2)
                            }
                        }
                        if !attachments.searchImages.isEmpty {
                            MessageAttachmentsView(
                                attachments: attachments.searchImages,
                                alignment: .leading
                            )
                            .padding(.top, 2)
                        }
                        if model.preferences.showTokenUsage, !message.isStreaming,
                           let usage = message.tokenUsage, let summary = TokenUsageFormatter.summary(usage) {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                } else {
                    if model.preferences.showModelIcon {
                        assistantSettingsButton(for: assistant)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        if hasAssistantMetadata {
                            HStack(spacing: 6) {
                                if model.preferences.showModelName {
                                    Text(assistant.useAssistantName ? assistant.name : model.modelTitle(for: assistant))
                                        .fontWeight(.semibold)
                                }
                                if model.preferences.showProviderInChatMessage,
                                   let providerTitle = model.providerTitle(for: message) {
                                    Text(providerTitle)
                                }
                                if model.preferences.showModelTimestamp {
                                    Text(createdTimeText)
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        }
                        ForEach(message.reasoningSegments) { segment in
                            ReasoningCard(
                                message: message,
                                segment: segment,
                                allowsTextSelection: allowsTextSelection,
                                startsCollapsed:
                                    model.preferences.fullyCollapseThinking,
                                onStreamingCollapseChanged:
                                    onStreamingReasoningCollapseChanged
                            )
                        }
                        if !message.toolEvents.isEmpty {
                            ToolEventsCard(toolEvents: message.toolEvents)
                        }
                        if !attachments.other.isEmpty {
                            MessageAttachmentsView(
                                attachments: attachments.other,
                                alignment: .leading,
                                collapsesImages: true,
                                imagesExpanded: $assistantAttachmentsExpanded
                            )
                        }
                        if message.text.isEmpty && message.isStreaming && message.reasoningSegments.isEmpty && message.toolEvents.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color(uiColor: .secondaryLabel))
                        } else if !message.text.isEmpty || !message.isStreaming {
                            ForEach(Array(assistantTextSegments.enumerated()), id: \.offset) { segmentIndex, text in
                                MessageMarkdownView(
                                    text: text,
                                    fontSize: messageFontSize,
                                    lineSpacing: CGFloat(model.preferences.assistantMessageLineSpacing),
                                    listItemSpacing: CGFloat(model.preferences.assistantMarkdownListItemSpacing),
                                    blockSpacingScale: CGFloat(model.preferences.assistantMarkdownBlockSpacingScale),
                                    isStreaming: message.isStreaming,
                                    rendersMarkdown: model.preferences.enableAssistantMarkdown,
                                    htmlRunnerEnabled: model.preferences.htmlRunnerEnabled,
                                    htmlRunnerAllowCurrentChat: model.preferences.htmlRunnerAllowCurrentChat,
                                    htmlRunnerConversationID: message.conversationID,
                                    autoCollapseCodeBlock: model.preferences.autoCollapseCodeBlock,
                                    collapsedCodeLineLimit: model.preferences.autoCollapseCodeBlockLines,
                                    codeBlockAppearance: model.preferences.codeBlockAppearance,
                                    allowsTextSelection: allowsTextSelection,
                                    prefersUnifiedNativeSelection: true,
                                    foregroundColor: chatTextColor(for: .assistant) ?? Color(uiColor: .label),
                                    largeHeadingColor: Color(argb: model.preferences.assistantLargeHeadingColorARGB),
                                    smallHeadingColor: Color(argb: model.preferences.assistantSmallHeadingColorARGB),
                                    selectionTintColor: Color(uiColor: model.themeTextSelectionUIColor),
                                    fontName: model.preferences.appFontPostScriptName,
                                    versionFlashContext: versionFlashContext,
                                    versionFlashSegmentIndex: segmentIndex,
                                    citationSources: citationSources,
                                    contentMutationContext: contentMutationBridge.context(
                                        region: .messageText(segmentIndex)
                                    )
                                )
                                .foregroundStyle(chatTextColor(for: .assistant) ?? Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    ChatBubbleSurface(
                                        style: assistantBubbleStyle,
                                        baseColor: assistantBubbleColor,
                                        opacity: assistantBubbleOpacity,
                                        liquidGlassOpacity: model.preferences.liquidGlassBubbleOpacity,
                                        appleGlassOpacity: model.preferences.appleGlassBubbleOpacity,
                                        cornerRadius: 17
                                    )
                                    .allowsHitTesting(false)
                                )
                            }
                        }
                        if !attachments.searchImages.isEmpty {
                            MessageAttachmentsView(
                                attachments: attachments.searchImages,
                                alignment: .leading
                            )
                            .padding(.top, 2)
                        }
                        if model.preferences.showTokenUsage, !message.isStreaming,
                           let usage = message.tokenUsage, let summary = TokenUsageFormatter.summary(usage) {
                            Text(summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 18)
                }
            }
            }
            .frame(maxWidth: .infinity)

            if hasVisibleReaction {
                HStack(spacing: 0) {
                    if message.role == .user { Spacer(minLength: 0) }
                    MessageReactionChips(message: message)
                        .fixedSize(horizontal: true, vertical: true)
                    if message.role != .user { Spacer(minLength: 0) }
                }
                .padding(.leading, reactionLeadingInset)
                .padding(.trailing, reactionTrailingInset)
                .padding(.top, 6)
                .zIndex(1)
            }

            if shouldShowInlineActions {
                HStack(spacing: 6) {
                    if message.role == .user { Spacer(minLength: 40) }
                    MessageInlineActionsBar(
                        message: message,
                        onReaction: onReaction,
                        onMore: onMore,
                        onEdit: onEdit,
                        onRegenerate: onRegenerate,
                        onSelectVersion: onSelectVersion
                    )
                    if message.role != .user {
                        Spacer(minLength: max(0, 40 - assistantContentLeadingInset))
                    }
                }
                .padding(
                    .leading,
                    message.role == .assistant ? assistantContentLeadingInset : 0
                )
                .padding(.top, hasVisibleReaction ? 8 : 6)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            if message.role == .assistant,
               !message.isStreaming,
               model.preferences.assistantBlankLongPressReactionEnabled {
                MessageBlankLongPressSurface { location in
                    guard DrawerInlineActionTapGate.allowsAction else { return }
                    onReaction(message, location)
                }
            }
        }
        .sheet(item: $assistantEditorProfile) { assistant in
            AssistantEditorView(profile: assistant) { saved in
                model.upsertAssistant(saved)
            }
        }
    }

    private func assistantSettingsButton(for assistant: AssistantProfile) -> some View {
        Button {
            guard DrawerInlineActionTapGate.allowsAction else { return }
            model.performCardHaptic()
            assistantEditorProfile = assistant
        } label: {
            Group {
                if assistant.useAssistantAvatar {
                    AssistantAvatarView(profile: assistant, size: 30)
                } else {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.10))
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 30, height: 30)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("打开%@的设定", [String(describing: assistant.name)]))
        .accessibilityHint(L10n.lookup("编辑当前消息所属的助手"))
    }

    private var shouldShowInlineActions: Bool {
        guard !message.isStreaming else { return false }
        switch message.role {
        case .assistant:
            let hasConfiguredAction = model.preferences.assistantMessageActionOrder.contains {
                !model.preferences.hiddenAssistantMessageActions.contains($0)
            }
            let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasNonTextContent = !message.reasoningSegments.isEmpty
                || !message.toolEvents.isEmpty || !message.attachments.isEmpty
            let isTerminalInterruption: Bool
            switch message.status {
            case .cancelled, .interrupted, .failed:
                isTerminalInterruption = true
            case .complete, .streaming:
                isTerminalInterruption = false
            }
            // Version navigation remains useful even if regeneration was stopped
            // before visible text arrived. Terminal empty replies also keep their
            // configured actions. Completed reasoning/tool/image-only replies also
            // need a way to regenerate or delete; text-only actions disable themselves.
            // Resolve local eligibility first so ordinary completed rows do not
            // observe the entire message store just to show their action bar.
            return (hasConfiguredAction && (hasText || hasNonTextContent || isTerminalInterruption))
                || model.hasMultipleVersions(for: message)
        case .user:
            return false
        default:
            return false
        }
    }

    private var hasVisibleReaction: Bool {
        message.reactions.userReaction != nil
            || (model.preferences.aiMessageReactionsEnabled && message.reactions.assistantReaction != nil)
    }

    private var reactionLeadingInset: CGFloat {
        guard message.role != .user else { return 0 }
        return assistantContentLeadingInset + 8
    }

    private var assistantContentLeadingInset: CGFloat {
        !assistantUsesWideTextLayout && model.preferences.showModelIcon ? 40 : 0
    }

    private var reactionTrailingInset: CGFloat {
        guard message.role == .user else { return 0 }
        return model.preferences.showUserAvatar ? 40 : 0
    }

    private var userNativeContextMenu: UserMessageNativeContextMenuModifier {
        UserMessageNativeContextMenuModifier(
            message: message,
            onSelectReaction: { reaction in
                onUserReaction(message, reaction)
            },
            onRegenerate: {
                onRegenerate(message)
            },
            onEdit: {
                onEdit(message)
            },
            onMore: {
                onMore(message)
            }
        )
    }

    @ViewBuilder
    private func userMessageBubble(
        text: String,
        messageFontSize: CGFloat,
        isStreaming: Bool
    ) -> some View {
        let previewTextColor = chatTextColor(for: .user) ?? Color(uiColor: .label)
        let previewShape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        let markdown = MessageMarkdownView(
            text: text,
            fontSize: messageFontSize,
            lineSpacing: 4,
            isUserMessage: true,
            isStreaming: isStreaming,
            rendersMarkdown: model.preferences.enableUserMarkdown,
            htmlRunnerEnabled: model.preferences.htmlRunnerEnabled,
            htmlRunnerAllowCurrentChat: model.preferences.htmlRunnerAllowCurrentChat,
            htmlRunnerConversationID: message.conversationID,
            autoCollapseCodeBlock: model.preferences.autoCollapseCodeBlock,
            collapsedCodeLineLimit: model.preferences.autoCollapseCodeBlockLines,
            codeBlockAppearance: model.preferences.codeBlockAppearance,
            fillsAvailableWidth: false,
            compactMaximumWidth: userMessageTextMaxWidth,
            // User-message long press now belongs to one bubble context menu,
            // so this path no longer needs TextKit's native range selection.
            // Keep compact bubbles on SwiftUI's single-pass text layout: the
            // TextKit fit-width host can expose a provisional first frame.
            allowsTextSelection: false,
            prefersUnifiedNativeSelection: false,
            foregroundColor: chatTextColor(for: .user) ?? Color(uiColor: .label),
            linkColor: chatTextColor(for: .user) ?? Color(uiColor: .label),
            fontName: model.preferences.appFontPostScriptName,
            onBlankLongPress: nil,
            contentMutationContext: contentMutationBridge.context(
                region: .messageText(0)
            )
        )
        .foregroundStyle(chatTextColor(for: .user) ?? Color.primary)
        markdown
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(userBubbleSurface)
            .contentShape(.interaction, previewShape)
            .contentShape(.contextMenuPreview, previewShape)
            .contextMenu {
                UserMessageNativeContextMenuItems(
                    message: message,
                    onSelectReaction: { reaction in
                        onUserReaction(message, reaction)
                    },
                    onRegenerate: {
                        onRegenerate(message)
                    },
                    onEdit: {
                        onEdit(message)
                    },
                    onMore: {
                        onMore(message)
                    }
                )
            } preview: {
                userMessageContextMenuPreview(
                    text: text,
                    messageFontSize: messageFontSize,
                    foregroundColor: previewTextColor
                )
            }
            .menuOrder(.fixed)
    }

    private func userMessageContextMenuPreview(
        text: String,
        messageFontSize: CGFloat,
        foregroundColor: Color
    ) -> some View {
        // Real-device samples split 5/5 on hard line breaks: previews for
        // messages containing a newline exposed the system's white preview
        // host, while naturally wrapped single-paragraph messages did not.
        // Keep this A/B limited to preview layout; the message and copied text
        // remain byte-for-byte unchanged.
        let singleLinePreviewText = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return Text(verbatim: singleLinePreviewText)
            .font(
                AppFontStore.swiftUIFont(
                    postScriptName: model.preferences.appFontPostScriptName,
                    size: messageFontSize
                )
            )
            .lineSpacing(4)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(foregroundColor)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: userMessageTextMaxWidth, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(userBubbleSurface)
            .environment(\.colorScheme, colorScheme)
    }

    private var userBubbleSurface: some View {
        ChatBubbleSurface(
            style: model.preferences.userChatBubbleStyle,
            baseColor: chatBubbleColor(for: .user),
            opacity: model.preferences.userChatBubbleOpacity,
            liquidGlassOpacity: model.preferences.liquidGlassBubbleOpacity,
            appleGlassOpacity: model.preferences.appleGlassBubbleOpacity,
            cornerRadius: 19
        )
    }

    private enum BubbleRole {
        case user
        case assistant
    }

    private func chatBubbleColor(for role: BubbleRole) -> Color {
        switch role {
        case .user:
            return Color(argb: model.preferences.userChatBubbleColorARGB)
                ?? Color(uiColor: model.themeUserBubbleUIColor)
        case .assistant:
            return Color(argb: model.preferences.assistantChatBubbleColorARGB)
                ?? Color(uiColor: .tertiarySystemBackground)
        }
    }

    private func chatTextColor(for role: BubbleRole) -> Color? {
        switch role {
        case .user:
            return Color(argb: model.preferences.userChatTextColorARGB)
        case .assistant:
            return Color(argb: model.preferences.assistantChatTextColorARGB)
        }
    }

    private var assistantTextSegments: [String] {
        guard isGroupMessage,
              model.preferences.groupChatSegmentedReply,
              !message.isStreaming else {
            return [message.text]
        }
        return GroupReplySegmenter.segments(
            in: message.text,
            pattern: model.preferences.groupChatSegmentRegex
        )
    }

    private var groupAssistantColor: Color? {
        guard isGroupMessage, let assistantID = message.groupID else { return nil }
        return Color(argb: model.preferences.groupAssistantBubbleColors[assistantID])
    }

    private var usesGroupBubbleAppearance: Bool {
        isGroupMessage && model.preferences.groupChatForceAssistantBubble
    }

    private var assistantBubbleStyle: ChatBubbleStyle {
        if isGroupMessage {
            return usesGroupBubbleAppearance
                ? model.preferences.groupChatBubbleStyle
                : .plain
        }
        return model.preferences.assistantChatBubbleStyle
    }

    private var assistantBubbleColor: Color {
        if usesGroupBubbleAppearance {
            return groupAssistantColor
                ?? (colorScheme == .dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color(red: 0.93, green: 0.93, blue: 0.94))
        }
        return chatBubbleColor(for: .assistant)
    }

    private var assistantBubbleOpacity: Double {
        if isGroupMessage {
            return usesGroupBubbleAppearance
                ? model.preferences.groupChatBubbleOpacity
                : 0
        }
        return model.preferences.assistantChatBubbleOpacity
    }
}

private struct MessageReactionPickerPresentation: Identifiable {
    let id = UUID()
    let messageID: UUID
    let globalLocation: CGPoint
}

private struct MessageSheetPresentation: Identifiable {
    enum Kind {
        case actions
        case edit
    }

    let id = UUID()
    let message: ChatMessage
    let kind: Kind
}

/// Created only while a picker is visible. Animation state belongs to this
/// small overlay, so showing or dismissing it never animates ChatView's state.
private struct MessageReactionPickerOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isDismissing = false

    let presentation: MessageReactionPickerPresentation
    let selectedReaction: String?
    let onSelect: (String) -> Void
    let onMore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let localX = presentation.globalLocation.x - frame.minX
            let localY = presentation.globalLocation.y - frame.minY
            let pickerWidth = min(350, max(280, proxy.size.width - 24))
            let pickerX = min(max(localX, pickerWidth / 2 + 12), proxy.size.width - pickerWidth / 2 - 12)
            let proposedAbove = localY - 48
            let pickerY = proposedAbove > 86 ? proposedAbove : min(proxy.size.height - 86, localY + 58)

            ZStack {
                Color.black.opacity(isVisible ? 0.06 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                MessageReactionPickerBar(
                    selectedReaction: selectedReaction,
                    onSelect: { reaction in
                        guard !isDismissing else { return }
                        onSelect(reaction)
                        dismiss()
                    },
                    onMore: { dismiss(after: onMore) }
                )
                .frame(width: pickerWidth, height: 58)
                .scaleEffect(reduceMotion || isVisible ? 1 : (isDismissing ? 0.96 : 0.82))
                .opacity(isVisible ? 1 : 0)
                .offset(y: reduceMotion || isVisible ? 0 : 6)
                .position(x: pickerX, y: pickerY)
                .allowsHitTesting(!isDismissing)
            }
            .zIndex(20)
        }
        .onAppear {
            let animation: Animation = reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.30, dampingFraction: 0.78)
            withAnimation(animation) { isVisible = true }
        }
    }

    private func dismiss(after action: @escaping () -> Void = {}) {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(.easeOut(duration: 0.14), completionCriteria: .logicallyComplete) {
            isVisible = false
        } completion: {
            action()
            onDismiss()
        }
    }
}

private struct MessageReactionPickerBar: View {
    private static let reactions = MessageReactionOptions.all

    let selectedReaction: String?
    let onSelect: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            buttons
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            buttons
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.14), radius: 18, y: 7)
        }
    }

    private var buttons: some View {
        HStack(spacing: 3) {
            ForEach(Self.reactions, id: \.self) { reaction in
                Button {
                    onSelect(reaction)
                } label: {
                    Text(reaction)
                        .font(.system(size: selectedReaction == reaction ? 23 : 21))
                        .frame(width: 35, height: 42)
                        .contentShape(Rectangle())
                        .background(
                            selectedReaction == reaction
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("回应 %@", [String(describing: reaction)]))
            }

            Divider()
                .frame(height: 26)
                .padding(.horizontal, 2)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 35, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.lookup("更多消息操作"))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
    }
}

private enum MessageReactionOptions {
    static let all = ["❤️", "👍", "🤣", "🥰", "🥹", "🫂", "🎉"]
}

private struct UserMessageNativeContextMenuModifier: ViewModifier {
    let message: ChatMessage
    let onSelectReaction: (String?) -> Void
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    let onMore: () -> Void

    func body(content: Content) -> some View {
        let previewShape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        content
            .contentShape(.interaction, previewShape)
            .contentShape(.contextMenuPreview, previewShape)
            .contextMenu {
                UserMessageNativeContextMenuItems(
                    message: message,
                    onSelectReaction: onSelectReaction,
                    onRegenerate: onRegenerate,
                    onEdit: onEdit,
                    onMore: onMore
                )
            }
            .menuOrder(.fixed)
    }
}

private struct UserMessageNativeContextMenuItems: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let onSelectReaction: (String?) -> Void
    let onRegenerate: () -> Void
    let onEdit: () -> Void
    let onMore: () -> Void

    private var textForActions: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isConversationStreaming: Bool {
        model.isConversationStreaming(message.conversationID)
    }

    private var liveMessage: ChatMessage {
        model.messages.first(where: { $0.id == message.id }) ?? message
    }

    private var selectedReaction: String? {
        liveMessage.reactions.userReaction
    }

    private var isBookmarked: Bool {
        liveMessage.reactions.bookmarkedAt != nil
    }

    var body: some View {
        Section(message.createdAt.formatted(date: .abbreviated, time: .shortened)) {
            ControlGroup {
                ForEach(MessageReactionOptions.all, id: \.self) { reaction in
                    Button {
                        onSelectReaction(selectedReaction == reaction ? nil : reaction)
                    } label: {
                        Text(reaction)
                    }
                    .accessibilityLabel(
                        selectedReaction == reaction
                            ? L10n.format("移除 %@ 回应", [String(describing: reaction)])
                            : L10n.format("用 %@ 回应", [String(describing: reaction)])
                    )
                }
            }
            .controlGroupStyle(.palette)
            .controlSize(.small)
        }

        Divider()

        Button(L10n.lookup("复制"), systemImage: "doc.on.doc") {
            UIPasteboard.general.string = textForActions
        }
        .disabled(textForActions.isEmpty)

        Button(L10n.lookup("重新发送"), systemImage: "arrow.clockwise", action: onRegenerate)
            .disabled(isConversationStreaming)

        Button(L10n.lookup("编辑"), systemImage: "pencil", action: onEdit)
            .disabled(isConversationStreaming)

        Button(L10n.lookup("更多"), systemImage: isBookmarked ? "bookmark.fill" : "ellipsis", action: onMore)
    }
}

private struct MessageReactionChips: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 6) {
            if model.preferences.aiMessageReactionsEnabled,
               let reaction = message.reactions.assistantReaction {
                reactionChip(reaction) {
                    AssistantAvatarView(profile: model.assistantReactionAuthor(for: message), size: 20)
                }
            }
            if let reaction = message.reactions.userReaction {
                reactionChip(reaction) {
                    UserProfileAvatarView(profile: model.userProfile, size: 20)
                }
            }
        }
    }

    private func reactionChip<Avatar: View>(
        _ reaction: String,
        @ViewBuilder avatar: () -> Avatar
    ) -> some View {
        HStack(spacing: 5) {
            avatar()
            Text(reaction)
                .font(.system(size: 16))
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.84), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.7))
    }
}

private struct MessageInlineActionsBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let onReaction: (ChatMessage, CGPoint) -> Void
    let onMore: (ChatMessage) -> Void
    let onEdit: (ChatMessage) -> Void
    let onRegenerate: (ChatMessage) -> Void
    let onSelectVersion: (ChatMessage, ChatMessage) -> Void
    @State private var isSpeaking = false

    private var textForActions: String {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBookmarked: Bool {
        model.messages.first(where: { $0.id == message.id })?.reactions.bookmarkedAt != nil
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white.opacity(0.78) : .black.opacity(0.72)
    }

    private var visibleAssistantActions: [AssistantMessageInlineAction] {
        model.preferences.assistantMessageActionOrder.filter {
            !model.preferences.hiddenAssistantMessageActions.contains($0)
        }
    }

    private var responseVersions: [ChatMessage] {
        guard message.role == .assistant else { return [] }
        return model.versions(for: message.id, in: message.conversationID)
    }

    var body: some View {
        let responseVersions = self.responseVersions
        let selectedResponseVersionIndex = responseVersions.firstIndex(where: { $0.id == message.id })
        HStack(spacing: 6) {
            if message.role == .assistant {
                ForEach(visibleAssistantActions) { action in
                    assistantAction(action)
                }
            } else {
                actionButton(
                    systemName: "doc.on.doc",
                    label: L10n.lookup("复制"),
                    disabled: textForActions.isEmpty
                ) {
                    UIPasteboard.general.string = textForActions
                }

                actionButton(
                    systemName: "arrow.clockwise",
                    label: L10n.lookup("重新发送"),
                    disabled: model.isConversationStreaming(message.conversationID)
                ) {
                    onRegenerate(message)
                }

                actionButton(
                    systemName: "pencil",
                    label: L10n.lookup("编辑"),
                    disabled: model.isConversationStreaming(message.conversationID)
                ) {
                    onEdit(message)
                }

                actionButton(
                    systemName: "ellipsis",
                    label: L10n.lookup("更多"),
                    color: isBookmarked ? Color.accentColor : nil
                ) {
                    onMore(message)
                }
            }

            if responseVersions.count > 1,
               let selectedResponseVersionIndex {
                responseVersionSelector(
                    selectedIndex: selectedResponseVersionIndex,
                    count: responseVersions.count
                )
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .onAppear {
            isSpeaking = DeviceTTSService.isSpeaking(messageID: message.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceTTSPlaybackDidChange)) { _ in
            isSpeaking = DeviceTTSService.isSpeaking(messageID: message.id)
        }
    }

    @ViewBuilder
    private func assistantAction(_ action: AssistantMessageInlineAction) -> some View {
        switch action {
        case .copy:
            actionButton(
                systemName: action.systemImage,
                label: L10n.lookup(action.title),
                disabled: textForActions.isEmpty
            ) {
                UIPasteboard.general.string = textForActions
            }
        case .regenerate:
            actionButton(
                systemName: action.systemImage,
                label: L10n.lookup(action.title),
                disabled: model.isConversationStreaming(message.conversationID)
            ) {
                onRegenerate(message)
            }
        case .reaction:
            GeometryReader { proxy in
                actionButton(
                    systemName: action.systemImage,
                    label: L10n.lookup(action.title),
                    color: message.reactions.userReaction == nil ? nil : Color.accentColor
                ) {
                    let frame = proxy.frame(in: .global)
                    onReaction(message, CGPoint(x: frame.midX, y: frame.minY))
                }
            }
            .frame(width: 28, height: 28)
        case .speech:
            actionButton(
                systemName: isSpeaking ? "stop.circle" : action.systemImage,
                label: isSpeaking ? L10n.lookup("停止朗读") : action.title,
                color: isSpeaking ? Color.green : nil,
                disabled: textForActions.isEmpty
            ) {
                DeviceTTSService.toggle(text: textForActions, messageID: message.id)
            }
        case .translate:
            actionButton(
                systemName: action.systemImage,
                label: L10n.lookup(action.title),
                disabled: textForActions.isEmpty
            ) {
                model.translateMessage(message.id)
            }
        case .branch:
            actionButton(
                systemName: action.systemImage,
                label: L10n.lookup(action.title),
                disabled: model.isConversationStreaming(message.conversationID)
            ) {
                model.branchConversation(at: message.id)
            }
        case .edit:
            actionButton(
                systemName: action.systemImage,
                label: L10n.lookup(action.title),
                disabled: message.isStreaming || model.isConversationStreaming(message.conversationID)
            ) {
                onEdit(message)
            }
        case .more:
            actionButton(
                systemName: action.systemImage,
                label: L10n.lookup(action.title),
                color: isBookmarked ? Color.accentColor : nil
            ) {
                onMore(message)
            }
        }
    }

    private func responseVersionSelector(
        selectedIndex: Int,
        count: Int
    ) -> some View {
        HStack(spacing: 2) {
            versionButton(
                systemName: "chevron.left",
                label: L10n.lookup("上一版回答"),
                disabled: selectedIndex == 0
            ) {
                let responseVersions = self.responseVersions
                guard responseVersions.indices.contains(selectedIndex - 1) else { return }
                onSelectVersion(message, responseVersions[selectedIndex - 1])
            }

            Text("\(selectedIndex + 1)/\(count)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(foregroundColor)
                .monospacedDigit()
                .frame(minWidth: 34)

            versionButton(
                systemName: "chevron.right",
                label: L10n.lookup("下一版回答"),
                disabled: selectedIndex + 1 >= count
            ) {
                let responseVersions = self.responseVersions
                guard responseVersions.indices.contains(selectedIndex + 1) else { return }
                onSelectVersion(message, responseVersions[selectedIndex + 1])
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .contain)
    }

    private func versionButton(
        systemName: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard DrawerInlineActionTapGate.allowsAction else { return }
            model.performCardHaptic()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.28 : 1)
        .accessibilityLabel(label)
    }

    private func actionButton(
        systemName: String,
        label: String,
        color: Color? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard DrawerInlineActionTapGate.allowsAction else { return }
            model.performCardHaptic()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color ?? foregroundColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

private struct MessageActionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let onDelete: (ChatMessage, Bool) -> Void

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isSharing = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isDeleteAllVersionsConfirmationPresented = false
    @State private var isRegenerateConfirmationPresented = false

    private var isBookmarked: Bool {
        model.messages.first(where: { $0.id == message.id })?.reactions.bookmarkedAt != nil
    }

    private var visibleMoreActions: [AssistantMessageMoreActionItem] {
        guard message.role != .assistant else {
            return model.preferences.assistantMessageMoreActionItems.filter { item in
                switch item {
                case .standard(let action):
                    !model.preferences.hiddenAssistantMessageMoreActions.contains(action)
                case .deleteAllVersions:
                    model.preferences.showDeleteAllMessageVersionsAction
                        && responseVersionCount > 1
                }
            }
        }

        var actions: [AssistantMessageMoreActionItem] = []
        if model.preferences.aiMessageReactionsEnabled || isBookmarked {
            actions.append(.standard(.bookmark))
        }
        actions.append(contentsOf: [.standard(.copy), .standard(.share)])
        if message.role == .user {
            actions.append(
                contentsOf: [
                    .standard(.translate),
                    .standard(.branch),
                    .standard(.regenerate)
                ]
            )
        } else {
            actions.append(.standard(.edit))
        }
        actions.append(.standard(.delete))
        return actions
    }

    private var responseVersionCount: Int {
        guard message.role == .assistant else { return 1 }
        return max(model.versions(for: message.id).count, 1)
    }

    private var deleteActionTitle: String {
        responseVersionCount > 1 ? L10n.lookup("删除当前版本") : L10n.lookup("删除")
    }

    private var preferredSheetHeight: CGFloat {
        let rowCount = visibleMoreActions.count
        let rowContentHeight = CGFloat(rowCount) * 50
            + CGFloat(max(rowCount - 1, 0)) * 4
        let measuredContentHeight = rowCount == 0
            ? 220
            : rowContentHeight + 92
        let screenLimit = UIScreen.main.bounds.height * 0.72
        return min(max(measuredContentHeight, 220), screenLimit)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.30))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 12)

            Text(L10n.lookup("消息操作"))
                .font(.system(size: 17, weight: .semibold))
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 4) {
                    if visibleMoreActions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 26))
                            Text(L10n.lookup("没有已启用的菜单操作"))
                                .font(.system(size: 15, weight: .medium))
                            Text(L10n.lookup("可以在“消息操作按钮”设置中重新开启"))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                    } else {
                        ForEach(visibleMoreActions) { action in
                            moreActionRow(action)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
        }
        .presentationDetents([.height(preferredSheetHeight), .large])
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $isEditing) {
            MessageEditSheet(
                text: $editText,
                roleTitle: message.role == .user ? L10n.lookup("编辑用户消息") : L10n.lookup("编辑助手消息"),
                allowsSaveAndSend: message.role == .user || message.role == .assistant
            ) { shouldSend in
                model.editMessage(message.id, text: editText, sendAfterSave: shouldSend)
                isEditing = false
                dismiss()
            }
        }
        .sheet(isPresented: $isSharing) {
            ActivityShareSheet(items: [message.text])
                .ignoresSafeArea()
        }
        .alert(L10n.lookup("删除消息"), isPresented: $isDeleteConfirmationPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(deleteActionTitle, role: .destructive) {
                onDelete(message, false)
                dismiss()
            }
        } message: {
            Text(
                responseVersionCount > 1
                    ? L10n.lookup("只删除当前显示的这个回复版本，其他版本会保留。")
                    : L10n.lookup("删除这条消息？")
            )
        }
        .alert(L10n.lookup("完全删除所有版本"), isPresented: $isDeleteAllVersionsConfirmationPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(L10n.lookup("完全删除"), role: .destructive) {
                onDelete(message, true)
                dismiss()
            }
        } message: {
            Text(L10n.format("将永久删除这条回答的全部 %@ 个版本。前面的用户消息与其他消息会保留，此操作无法撤销。", [String(describing: responseVersionCount)]))
        }
        .alert(message.role == .user ? L10n.lookup("重新发送") : L10n.lookup("重新生成"), isPresented: $isRegenerateConfirmationPresented) {
            Button(L10n.lookup("取消"), role: .cancel) {}
            Button(message.role == .assistant ? L10n.lookup("重新生成") : L10n.lookup("重新发送")) {
                model.regenerateResponse(around: message.id)
                dismiss()
            }
        } message: {
            if message.role == .user {
                Text(model.preferences.regenerateDeleteTrailingMessages
                     ? L10n.lookup("会删除这条消息后面的后续消息，然后重新发送。")
                     : L10n.lookup("会重新发送这条消息，后续消息会保留。"))
            } else {
                Text(model.preferences.regenerateDeleteTrailingMessages
                     ? L10n.lookup("会删除这条消息后面的后续消息，然后重新生成。")
                     : L10n.lookup("会基于这条消息重新生成一条新回复，后续消息会保留。"))
            }
        }
    }

    @ViewBuilder
    private func moreActionRow(_ item: AssistantMessageMoreActionItem) -> some View {
        switch item {
        case .deleteAllVersions:
            actionRow(item.title, systemName: item.systemImage, role: .destructive) {
                isDeleteAllVersionsConfirmationPresented = true
            }
        case .standard(let action):
        switch action {
        case .bookmark:
            actionRow(
                isBookmarked ? L10n.lookup("取消收藏") : action.title,
                systemName: isBookmarked ? "bookmark.slash" : action.systemImage
            ) {
                model.toggleMessageBookmark(message.id)
                dismiss()
            }
        case .copy:
            actionRow(L10n.lookup(action.title), systemName: action.systemImage, disabled: message.text.isEmpty) {
                UIPasteboard.general.string = message.text
                dismiss()
            }
        case .share:
            actionRow(L10n.lookup(action.title), systemName: action.systemImage, disabled: message.text.isEmpty) {
                isSharing = true
            }
        case .translate:
            actionRow(L10n.lookup(action.title), systemName: action.systemImage, disabled: message.text.isEmpty) {
                model.translateMessage(message.id)
                dismiss()
            }
        case .branch:
            actionRow(
                L10n.lookup(action.title),
                systemName: action.systemImage,
                disabled: model.isConversationStreaming(message.conversationID)
            ) {
                model.branchConversation(at: message.id)
                dismiss()
            }
        case .edit:
            actionRow(
                L10n.lookup(action.title),
                systemName: action.systemImage,
                disabled: message.isStreaming || model.isConversationStreaming(message.conversationID)
            ) {
                editText = message.text
                isEditing = true
            }
        case .regenerate:
            actionRow(
                message.role == .assistant ? L10n.lookup(action.title) : L10n.lookup("重新发送"),
                systemName: action.systemImage,
                disabled: model.isConversationStreaming(message.conversationID)
            ) {
                if model.preferences.showRegenerateConfirmDialog {
                    isRegenerateConfirmationPresented = true
                } else {
                    model.regenerateResponse(around: message.id)
                    dismiss()
                }
            }
        case .delete:
            actionRow(deleteActionTitle, systemName: action.systemImage, role: .destructive) {
                isDeleteConfirmationPresented = true
            }
        }
        }
    }

    private func actionRow(
        _ title: String,
        systemName: String,
        role: ButtonRole? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            model.performCardHaptic()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private enum GroupReplySegmenter {
    private static let punctuationOnlyPattern = #"^[\s。！？，、；：…·．｡､﹗﹖!?,.;:~～—–\-]+$"#

    static func segments(in text: String, pattern: String) -> [String] {
        let customPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !customPattern.isEmpty else { return automaticSegments(in: text) }
        guard let expression = try? NSRegularExpression(pattern: customPattern) else {
            return automaticSegments(in: text)
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range).compactMap { match -> String? in
            guard let stringRange = Range(match.range, in: text) else { return nil }
            let value = text[stringRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard matches.count > 1 else { return [text.trimmingCharacters(in: .whitespacesAndNewlines)] }

        let compactOriginal = text.filter { !$0.isWhitespace }
        let compactMatches = matches.joined().filter { !$0.isWhitespace }
        if !compactOriginal.isEmpty,
           Double(compactMatches.count) < Double(compactOriginal.count) * 0.6 {
            return automaticSegments(in: text)
        }
        let kept = dropPunctuationOnly(matches)
        return kept.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : kept
    }

    private static func automaticSegments(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [text] }
        if trimmed.contains("```") || trimmed.contains("\n|") || trimmed.contains("\n#") {
            return [trimmed]
        }

        let enders = CharacterSet(charactersIn: "。！？!?\n")
        var chunks: [String] = []
        var current = ""
        for character in trimmed {
            current.append(character)
            let scalars = character.unicodeScalars
            if scalars.contains(where: { enders.contains($0) }) {
                let chunk = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty { chunks.append(chunk) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        let kept = dropPunctuationOnly(chunks)
        return kept.isEmpty ? [trimmed] : kept
    }

    private static func dropPunctuationOnly(_ values: [String]) -> [String] {
        let expression = try? NSRegularExpression(pattern: punctuationOnlyPattern)
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let expression else { return trimmed }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            return expression.firstMatch(in: trimmed, range: range) == nil ? trimmed : nil
        }
    }
}

private struct ChatBackgroundView: View {
    @Environment(AppModel.self) private var model
    let profile: AssistantProfile

    var body: some View {
        let strength = model.preferences.chatBackgroundMaskStrength
        let topOpacity = min(max(0.20 * strength, 0.0), 1.0)
        let bottomOpacity = min(max(0.50 * strength, 0.0), 1.0)
        GeometryReader { proxy in
            let viewportSize = proxy.size
            ZStack {
                Color(uiColor: model.themeSurfaceUIColor)
                if let image = AssistantMediaStore.image(for: profile.background) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: viewportSize.width, height: viewportSize.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.04))
                    LinearGradient(
                        colors: [
                            Color(uiColor: model.themeSurfaceUIColor).opacity(topOpacity),
                            Color(uiColor: model.themeSurfaceUIColor).opacity(bottomOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: viewportSize.width, height: viewportSize.height)
                }
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
        }
        .ignoresSafeArea()
    }
}

@MainActor enum TokenUsageFormatter {
    static func summary(_ usage: TokenUsage) -> String? {
        var parts: [String] = []
        if let prompt = usage.promptTokens { parts.append("↑\(prompt)") }
        if let completion = usage.completionTokens { parts.append("↓\(completion)") }
        let total = usage.totalTokens ?? {
            guard usage.promptTokens != nil || usage.completionTokens != nil else { return nil }
            return (usage.promptTokens ?? 0) + (usage.completionTokens ?? 0)
        }()
        guard !parts.isEmpty || total != nil else { return nil }
        if let total { parts.append(L10n.format("共 %@ tokens", [String(describing: total)])) }
        return parts.joined(separator: " · ")
    }
}

private struct ChatBubbleSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    let style: ChatBubbleStyle
    let baseColor: Color
    let opacity: Double
    let liquidGlassOpacity: Double
    let appleGlassOpacity: Double
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var effectiveOpacity: Double {
        opacity == 0 ? 0 : max(opacity, 0.04)
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .plain:
            Color.clear
        case .defaultStyle:
            shape
                .fill(baseColor.opacity(max(effectiveOpacity, 0.08)))
        case .liquidGlass:
            crystalGlassSurface
        case .appleGlass:
            systemLiquidGlassSurface
        case .frosted:
            ZStack {
                shape.fill(.thinMaterial)
                shape.fill(baseColor.opacity(effectiveOpacity))
            }
        case .solid:
            shape
                .fill(baseColor.opacity(max(effectiveOpacity, 0.72)))
        case .aurora:
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            baseColor.opacity(max(effectiveOpacity, 0.18)),
                            Color.accentColor.opacity(max(effectiveOpacity * 0.75, 0.10)),
                            Color.purple.opacity(max(effectiveOpacity * 0.55, 0.08))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .outline:
            ZStack {
                shape.fill(baseColor.opacity(effectiveOpacity * 0.35))
                shape.stroke(baseColor.opacity(max(effectiveOpacity, 0.45)), lineWidth: 1.1)
            }
        case .glossy:
            ZStack {
                shape
                    .fill(baseColor.opacity(max(effectiveOpacity, 0.16)))
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(shape)
                    }
                shape.stroke(.white.opacity(0.16), lineWidth: 0.7)
            }
        }
    }

    /// The hand-built glass from old Kelivo. On iOS the material already gives
    /// the silhouette enough separation, so keep the edge softly tinted
    /// instead of stacking a bright white rim and halo on top of it.
    private var crystalGlassSurface: some View {
        let clarity = min(max(liquidGlassOpacity, 0), 1)
        let isDark = colorScheme == .dark
        let surfaceAlpha = interpolate(
            from: isDark ? 0.075 : 0.105,
            to: isDark ? 0.014 : 0.010,
            by: clarity
        )
        let tintAlpha = effectiveOpacity * interpolate(
            from: isDark ? 0.18 : 0.16,
            to: 0.035,
            by: clarity
        )
        let topHighlightAlpha = interpolate(
            from: isDark ? 0.09 : 0.18,
            to: isDark ? 0.05 : 0.10,
            by: clarity
        )
        let lowerShadowAlpha = interpolate(
            from: isDark ? 0.10 : 0.035,
            to: isDark ? 0.035 : 0.010,
            by: clarity
        )
        let lowerShadowRadius = interpolate(from: 12, to: 8, by: clarity)

        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.white.opacity(surfaceAlpha))
            shape.fill(baseColor.opacity(tintAlpha))
            shape.fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(topHighlightAlpha), location: 0),
                        .init(
                            color: .white.opacity(interpolate(
                                from: isDark ? 0.018 : 0.036,
                                to: isDark ? 0.004 : 0.010,
                                by: clarity
                            )),
                            location: 0.34
                        ),
                        .init(
                            color: .white.opacity(interpolate(
                                from: isDark ? 0.010 : 0.024,
                                to: isDark ? 0.002 : 0.006,
                                by: clarity
                            )),
                            location: 0.72
                        ),
                        .init(color: .white.opacity(isDark ? 0.002 : 0.004), location: 1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.fill(
                EllipticalGradient(
                    gradient: Gradient(stops: [
                        .init(
                            color: .white.opacity(interpolate(
                                from: isDark ? 0.12 : 0.22,
                                to: isDark ? 0.05 : 0.085,
                                by: clarity
                            )),
                            location: 0
                        ),
                        .init(
                            color: .white.opacity(interpolate(
                                from: isDark ? 0.020 : 0.040,
                                to: isDark ? 0.004 : 0.010,
                                by: clarity
                            )),
                            location: 0.38
                        ),
                        .init(color: .clear, location: 1)
                    ]),
                    center: UnitPoint(x: 0.06, y: 0.04),
                    startRadiusFraction: 0,
                    endRadiusFraction: 1.15
                )
            )
            shape.fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(
                            color: .white.opacity(interpolate(
                                from: isDark ? 0.035 : 0.075,
                                to: isDark ? 0.010 : 0.020,
                                by: clarity
                            )),
                            location: 0
                        ),
                        .init(color: .clear, location: 0.50),
                        .init(color: .white.opacity(isDark ? 0.002 : 0), location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    baseColor.opacity(isDark ? 0.08 : 0.055),
                    lineWidth: 0.5
                )
        }
        .shadow(
            color: Color.black.opacity(lowerShadowAlpha),
            radius: lowerShadowRadius,
            x: 0,
            y: 4
        )
    }

    @ViewBuilder
    private var systemLiquidGlassSurface: some View {
        if #available(iOS 26.0, *) {
            let requestedTint = min(max(max(appleGlassOpacity, effectiveOpacity), 0), 1)
            let tintColor: Color? = requestedTint == 0
                ? nil
                : baseColor.opacity(requestedTint * 0.45)
            shape
                .fill(baseColor.opacity(effectiveOpacity * 0.08))
                .glassEffect(
                    .regular.tint(tintColor),
                    in: shape
                )
                // Streaming changes the bubble's bounds frequently. Keep the
                // same surface instead of asking glass to morph between sizes.
                .glassEffectTransition(.identity)
        } else {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(baseColor.opacity(max(appleGlassOpacity, effectiveOpacity)))
                shape.stroke(.white.opacity(0.18), lineWidth: 0.7)
            }
        }
    }

    private func interpolate(from start: Double, to end: Double, by amount: Double) -> Double {
        start + ((end - start) * amount)
    }
}

private struct ContextClearedDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.7)
            Text(L10n.lookup("上下文已清除"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.7)
        }
        .padding(.vertical, 2)
    }
}

private enum ChatDisclosureMotion {
    static let animation = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
    static var transition: AnyTransition { .opacity }
}

private struct ReasoningCard: View {
    @Environment(AppModel.self) private var model
    @State private var isLocallyCollapsed: Bool
    let message: ChatMessage
    let segment: ReasoningSegment
    var allowsTextSelection = true
    let onStreamingCollapseChanged: (UUID, UUID, Bool) -> Void

    init(
        message: ChatMessage,
        segment: ReasoningSegment,
        allowsTextSelection: Bool = true,
        startsCollapsed: Bool,
        onStreamingCollapseChanged: @escaping (UUID, UUID, Bool) -> Void
    ) {
        self.message = message
        self.segment = segment
        self.allowsTextSelection = allowsTextSelection
        self.onStreamingCollapseChanged = onStreamingCollapseChanged
        _isLocallyCollapsed = State(initialValue: startsCollapsed)
    }

    private var isThinking: Bool {
        segment.finishedAt == nil && message.isStreaming
    }

    private var isExpanded: Bool {
        if model.preferences.fullyCollapseThinking || isThinking {
            return !isLocallyCollapsed
        }
        return (!model.preferences.autoCollapseThinking && segment.finishedAt != nil) || segment.expanded
    }

    private var durationText: String? {
        guard let start = segment.startedAt, let end = segment.finishedAt else { return nil }
        let seconds = max(1, Int(end.timeIntervalSince(start).rounded()))
        return L10n.format("%@ 秒", [String(describing: seconds)])
    }

    private var plainDurationText: String? {
        guard let start = segment.startedAt, let end = segment.finishedAt else { return nil }
        let seconds = max(1, Int(end.timeIntervalSince(start).rounded()))
        return "\(seconds)s"
    }

    private var usesPlainStyle: Bool {
        model.preferences.thinkingChatBubbleStyle == .plain
    }

    private var activeThinkingTitle: String {
        let configuredTitle = model.preferences.thinkingBubbleTitle
        return configuredTitle.isEmpty ? L10n.lookup("思考中…") : configuredTitle
    }

    private var plainHeaderTitle: String {
        guard !isThinking else { return activeThinkingTitle }
        let baseTitle = L10n.lookup("思考了")
        guard let plainDurationText else { return baseTitle }
        return "\(baseTitle) \(plainDurationText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesPlainStyle ? 12 : 9) {
            Button {
                guard DrawerInlineActionTapGate.allowsAction else { return }
                if model.preferences.fullyCollapseThinking || isThinking {
                    let nextCollapsed = !isLocallyCollapsed
                    withAnimation(ChatDisclosureMotion.animation) {
                        isLocallyCollapsed = nextCollapsed
                    }
                    if isThinking {
                        onStreamingCollapseChanged(
                            message.id,
                            segment.id,
                            nextCollapsed
                        )
                    }
                } else {
                    withAnimation(ChatDisclosureMotion.animation) {
                        model.toggleReasoningExpanded(messageID: message.id, segmentID: segment.id)
                    }
                }
            } label: {
                if usesPlainStyle {
                    HStack(spacing: 5) {
                        Text(plainHeaderTitle)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.secondary)
                        if isThinking {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Color(uiColor: .secondaryLabel))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(isThinking ? activeThinkingTitle : L10n.lookup("思考过程"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        if isThinking {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Color(uiColor: .secondaryLabel))
                        } else if let durationText {
                            Text(durationText)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)

            if isExpanded && !segment.text.isEmpty {
                MessageMarkdownView(
                    text: segment.text,
                    fontSize: 14,
                    lineSpacing: 3,
                    isStreaming: isThinking,
                    rendersMarkdown: model.preferences.enableReasoningMarkdown,
                    htmlRunnerEnabled: model.preferences.htmlRunnerEnabled,
                    htmlRunnerAllowCurrentChat: model.preferences.htmlRunnerAllowCurrentChat,
                    htmlRunnerConversationID: message.conversationID,
                    autoCollapseCodeBlock: model.preferences.autoCollapseCodeBlock,
                    collapsedCodeLineLimit: model.preferences.autoCollapseCodeBlockLines,
                    codeBlockAppearance: model.preferences.codeBlockAppearance,
                    allowsTextSelection: allowsTextSelection,
                    prefersUnifiedNativeSelection: true,
                    foregroundColor: thinkingTextColor ?? (usesPlainStyle ? Color.primary : Color.secondary),
                    selectionTintColor: Color(uiColor: model.themeTextSelectionUIColor),
                    fontName: model.preferences.appFontPostScriptName
                )
                .foregroundStyle(thinkingTextColor ?? (usesPlainStyle ? Color.primary : Color.secondary))
                .transition(ChatDisclosureMotion.transition)
            }
        }
        .padding(
            usesPlainStyle
                ? EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
                : EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !usesPlainStyle {
                ChatBubbleSurface(
                    style: model.preferences.thinkingChatBubbleStyle,
                    baseColor: thinkingBubbleColor,
                    opacity: model.preferences.thinkingChatBubbleOpacity,
                    liquidGlassOpacity: model.preferences.liquidGlassBubbleOpacity,
                    appleGlassOpacity: model.preferences.appleGlassBubbleOpacity,
                    cornerRadius: 14
                )
            }
        }
        .animation(ChatDisclosureMotion.animation, value: isExpanded)
    }

    private var thinkingBubbleColor: Color {
        Color(argb: model.preferences.thinkingChatBubbleColorARGB)
            ?? Color.primary.opacity(0.04)
    }

    private var thinkingTextColor: Color? {
        Color(argb: model.preferences.thinkingChatTextColorARGB)
    }
}

private func isWebSearchToolEvent(_ event: ToolEvent) -> Bool {
    let normalizedName = event.name
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    return normalizedName == "search_web"
        || normalizedName == "web_search"
        || normalizedName == "web_search_preview"
        || normalizedName == "builtin_search"
        || normalizedName.hasPrefix("web_search_")
}

private struct ToolEventParsedResult {
    let object: [String: Any]?
    let previewRaw: String?
    let previewValue: Any?

    init(event: ToolEvent) {
        guard let raw = event.resultText else {
            object = nil
            previewRaw = nil
            previewValue = nil
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Self.parse(raw)
        object = value as? [String: Any]
        previewRaw = trimmed.isEmpty ? nil : trimmed
        // Previews historically trim broader whitespace than JSON accepts.
        // Retry only that failure case; error detection still uses the raw object.
        previewValue = value ?? (trimmed != raw && !trimmed.isEmpty ? Self.parse(trimmed) : nil)
    }

    private static func parse(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func hasError(for event: ToolEvent) -> Bool {
        event.status == .failed || object?["error"] != nil
    }
}

private struct ToolEventResultPresentation: Identifiable {
    let event: ToolEvent
    let result: ToolEventParsedResult

    var id: UUID { event.id }

    init(event: ToolEvent) {
        self.event = event
        result = ToolEventParsedResult(event: event)
    }
}

@MainActor private enum ToolEventDetailFormatter {
    static func preview(for event: ToolEvent, result: ToolEventParsedResult) -> String? {
        guard let raw = result.previewRaw else { return nil }
        guard let value = result.previewValue else {
            return readablePlainText(raw)
        }

        if let object = value as? [String: Any], object["error"] != nil {
            let message = scalarText(object["message"])
                ?? scalarText(object["error"])
                ?? L10n.lookup("工具执行失败")
            return clipped(L10n.format("失败：%@", [String(describing: message)]))
        }

        let name = event.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let object = value as? [String: Any] {
            switch name {
            case "search_conversations":
                if let results = object["results"] as? [Any] {
                    return L10n.format("找到 %@ 项结果", [String(describing: results.count)])
                }
            case "get_local_weather":
                return weatherSummary(object) ?? L10n.lookup("天气查询已完成")
            case "get_time_info":
                let date = scalarText(object["date"])
                let time = scalarText(object["time"])
                let timezone = scalarText(object["timezone"])
                let dateTime = [date, time].compactMap { $0 }.joined(separator: " ")
                return [dateTime.isEmpty ? nil : dateTime, timezone]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            case "calculate":
                if let result = scalarText(object["result"]) {
                    return L10n.format("计算结果：%@", [String(describing: result)])
                }
            case "manage_reminders":
                if let items = object["items"] as? [Any] {
                    return L10n.format("找到 %@ 个提醒事项", [String(describing: items.count)])
                }
                if let reminder = object["reminder"] as? [String: Any],
                   let title = scalarText(reminder["title"]) {
                    let action = scalarText(object["action"])
                    let prefix: String
                    switch action {
                    case "created": prefix = L10n.lookup("已创建")
                    case "updated": prefix = L10n.lookup("已更新")
                    case "completed": prefix = L10n.lookup("已完成")
                    case "reopened": prefix = L10n.lookup("已重新打开")
                    default: prefix = L10n.lookup("已处理")
                    }
                    return "\(prefix)：\(title)"
                }
                if scalarText(object["action"]) == "deleted",
                   let title = scalarText(object["title"]) {
                    return L10n.format("已删除：%@", [String(describing: title)])
                }
            default:
                break
            }

            if let items = object["items"] as? [Any] {
                return L10n.format("找到 %@ 项结果", [String(describing: items.count)])
            }
            for key in ["summary", "message", "result", "text", "title"] {
                if let text = scalarText(object[key]), !text.isEmpty {
                    return clipped(text)
                }
            }
            if (object["success"] as? Bool) == true {
                return L10n.lookup("操作已完成")
            }
            return L10n.format("工具已完成，返回 %@ 项信息", [String(describing: object.count)])
        }
        if let values = value as? [Any] {
            return L10n.format("工具已完成，返回 %@ 项结果", [String(describing: values.count)])
        }
        return scalarText(value).map(clipped)
    }

    private static func weatherSummary(_ object: [String: Any]) -> String? {
        guard let current = object["current"] as? [String: Any] else { return nil }
        let code = (current["weather_code"] as? NSNumber)?.intValue
        var currentParts: [String] = []
        if let condition = localizedWeatherCondition(
            code: code,
            fallback: scalarText(current["condition"])
        ) {
            currentParts.append(condition)
        }
        if let temperature = measurement(current["temperature_c"], unit: "°C") {
            currentParts.append(temperature)
        }
        if let apparent = measurement(current["apparent_temperature_c"], unit: "°C") {
            currentParts.append(L10n.format("体感 %@", [String(describing: apparent)]))
        }
        if let humidity = measurement(current["relative_humidity_percent"], unit: "%") {
            currentParts.append(L10n.format("湿度 %@", [String(describing: humidity)]))
        }
        if let wind = measurement(current["wind_speed_kmh"], unit: " km/h") {
            currentParts.append(L10n.format("风速 %@", [String(describing: wind)]))
        }

        var lines: [String] = []
        if !currentParts.isEmpty {
            lines.append(L10n.lookup("当前：") + currentParts.joined(separator: " · "))
        }
        if let first = (object["forecast"] as? [[String: Any]])?.first {
            var forecastParts: [String] = []
            if let low = measurement(first["temperature_min_c"], unit: "°C"),
               let high = measurement(first["temperature_max_c"], unit: "°C") {
                forecastParts.append("\(low)～\(high)")
            }
            if let rain = measurement(
                first["precipitation_probability_max_percent"],
                unit: "%"
            ) {
                forecastParts.append(L10n.format("最高降雨概率 %@", [String(describing: rain)]))
            }
            if !forecastParts.isEmpty {
                lines.append(L10n.lookup("今天：") + forecastParts.joined(separator: " · "))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func localizedWeatherCondition(code: Int?, fallback: String?) -> String? {
        switch code {
        case 0: return L10n.lookup("晴")
        case 1: return L10n.lookup("大致晴朗")
        case 2: return L10n.lookup("局部多云")
        case 3: return L10n.lookup("阴")
        case 45, 48: return L10n.lookup("有雾")
        case 51, 53, 55, 56, 57: return L10n.lookup("毛毛雨")
        case 61, 63, 65, 66, 67: return L10n.lookup("有雨")
        case 71, 73, 75, 77, 85, 86: return L10n.lookup("有雪")
        case 80, 81, 82: return L10n.lookup("阵雨")
        case 95, 96, 99: return L10n.lookup("雷雨")
        default: return fallback
        }
    }

    private static func measurement(_ value: Any?, unit: String) -> String? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        let text = abs(double.rounded() - double) < 0.05
            ? String(Int(double.rounded()))
            : String(format: "%.1f", double)
        return text + unit
    }

    private static func scalarText(_ value: Any?) -> String? {
        if let string = value as? String {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func readablePlainText(_ raw: String) -> String {
        switch raw.lowercased() {
        case "deleted": return L10n.lookup("已删除")
        case "success", "completed": return L10n.lookup("操作已完成")
        default: return clipped(raw)
        }
    }

    private static func clipped(_ text: String) -> String {
        text.count > 240 ? String(text.prefix(240)) + "…" : text
    }
}

private struct ToolEventPresentationGroup: Identifiable {
    let events: [ToolEvent]

    var id: UUID {
        events[0].id
    }

    var isGroupedWebSearch: Bool {
        events.count > 1 && events.allSatisfy(isWebSearchToolEvent)
    }

    static func make(from toolEvents: [ToolEvent]) -> [ToolEventPresentationGroup] {
        var groups: [ToolEventPresentationGroup] = []
        var adjacentWebSearchEvents: [ToolEvent] = []

        func flushWebSearchEvents() {
            guard !adjacentWebSearchEvents.isEmpty else { return }
            groups.append(ToolEventPresentationGroup(events: adjacentWebSearchEvents))
            adjacentWebSearchEvents.removeAll(keepingCapacity: true)
        }

        for event in toolEvents {
            if isWebSearchToolEvent(event) {
                adjacentWebSearchEvents.append(event)
            } else {
                flushWebSearchEvents()
                groups.append(ToolEventPresentationGroup(events: [event]))
            }
        }
        flushWebSearchEvents()
        return groups
    }
}

private struct ToolEventsCard: View {
    let toolEvents: [ToolEvent]

    private var presentationGroups: [ToolEventPresentationGroup] {
        ToolEventPresentationGroup.make(from: toolEvents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(presentationGroups) { group in
                if group.isGroupedWebSearch {
                    WebSearchToolEventGroupRow(events: group.events)
                } else if let event = group.events.first {
                    ToolEventRow(event: event)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WebSearchToolEventGroupSummary {
    let eventCount: Int
    let runningCount: Int
    let failureCount: Int
    let webResultCount: Int

    init(presentations: [ToolEventResultPresentation]) {
        eventCount = presentations.count
        var runningCount = 0
        var failureCount = 0
        var webResultCount = 0
        for presentation in presentations {
            let event = presentation.event
            let result = presentation.result
            if event.status == .pending || event.status == .running {
                runningCount += 1
            }
            if result.hasError(for: event) {
                failureCount += 1
            }
            guard let items = result.object?["items"] as? [[String: Any]] else { continue }
            webResultCount += items.count {
                guard let rawURL = $0["url"] as? String else { return false }
                return URL(string: rawURL) != nil
            }
        }
        self.runningCount = runningCount
        self.failureCount = failureCount
        self.webResultCount = webResultCount
    }

    @MainActor var expandedSummary: String? {
        var parts: [String] = []
        if webResultCount > 0 {
            parts.append(L10n.format("返回 %@ 个网页结果", [String(describing: webResultCount)]))
        }
        if failureCount > 0 {
            parts.append(L10n.format("%@ 次失败", [String(describing: failureCount)]))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor var accessibilityStatus: String {
        var parts = [L10n.format("%@ 次搜索", [String(describing: eventCount)])]
        if webResultCount > 0 {
            parts.append(L10n.format("%@ 个网页结果", [String(describing: webResultCount)]))
        }
        if runningCount > 0 {
            parts.append(L10n.format("%@ 次进行中", [String(describing: runningCount)]))
        }
        if failureCount > 0 {
            parts.append(L10n.format("%@ 次失败", [String(describing: failureCount)]))
        }
        return parts.joined(separator: "，")
    }
}

private struct WebSearchToolEventGroupRow: View {
    let events: [ToolEvent]
    @State private var isExpanded = false

    var body: some View {
        let presentations = events.map { ToolEventResultPresentation(event: $0) }
        let summary = WebSearchToolEventGroupSummary(presentations: presentations)
        let headerColor: Color = summary.failureCount == events.count && summary.runningCount == 0
            ? .red : .secondary
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(ChatDisclosureMotion.animation) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 20)
                    Text(L10n.format("浏览多个网站 · %@ 次搜索", [String(describing: events.count)]))
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(2)
                    if summary.runningCount > 0 {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .foregroundStyle(headerColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("浏览多个网站，%@", [String(describing: summary.accessibilityStatus)]))
            .accessibilityHint(L10n.format("轻点%@每次搜索", [isExpanded ? L10n.lookup("收起") : L10n.lookup("展开")]))

            if isExpanded {
                if let expandedSummary = summary.expandedSummary {
                    Text(expandedSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(summary.failureCount > 0 ? Color.red : Color.secondary)
                        .padding(.leading, 28)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(presentations) { presentation in
                        ToolEventRow(
                            event: presentation.event,
                            usesGroupedWebSearchLabel: true,
                            parsedResult: presentation.result
                        )
                    }
                }
                .padding(.leading, 8)
                .transition(ChatDisclosureMotion.transition)
            }
        }
        .animation(ChatDisclosureMotion.animation, value: isExpanded)
    }
}

private struct ToolEventRow: View {
    let event: ToolEvent
    var usesGroupedWebSearchLabel = false
    var parsedResult: ToolEventParsedResult? = nil
    @State private var isExpanded = false

    private var normalizedName: String {
        event.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var arguments: [String: Any] {
        guard let raw = event.argumentsJSON,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func argumentText(_ keys: String...) -> String? {
        let arguments = self.arguments
        for key in keys {
            if let value = arguments[key] as? String {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private var activityText: String {
        if isWebSearch {
            if let query = argumentText("query", "q", "search_query", "prompt") {
                if usesGroupedWebSearchLabel {
                    return L10n.format("查找 %@", [String(describing: query)])
                }
                return L10n.format("浏览多个网站查找 %@", [String(describing: query)])
            }
            return usesGroupedWebSearchLabel ? L10n.lookup("网页搜索") : L10n.lookup("浏览多个网站")
        }

        switch normalizedName {
        case "create_memory": return L10n.lookup("创建了记忆")
        case "edit_memory": return L10n.lookup("更新了记忆")
        case "delete_memory": return L10n.lookup("删除了记忆")
        case "read_assistant_file": return L10n.lookup("读取助手文件")
        case "edit_assistant_file": return L10n.lookup("编辑助手文件")
        case "get_time_info": return L10n.lookup("查询了时间")
        case "clipboard_tool": return L10n.lookup("使用了剪贴板")
        case "calculate": return L10n.lookup("进行了计算")
        case "search_conversations":
            if let query = argumentText("query", "q", "text") {
                return L10n.format("搜索对话查找 %@", [String(describing: query)])
            }
            return L10n.lookup("搜索了对话")
        case "text_to_speech": return L10n.lookup("生成了语音")
        case "get_local_weather":
            if let location = argumentText("location", "city") {
                return L10n.format("查询了 %@ 天气", [String(describing: location)])
            }
            return L10n.lookup("查询了天气")
        case "create_calendar_event": return L10n.lookup("创建了日历事件")
        case "manage_reminders":
            switch argumentText("action")?.lowercased() {
            case "list": return L10n.lookup("查看了提醒事项")
            case "create": return L10n.lookup("创建了提醒事项")
            case "update": return L10n.lookup("更新了提醒事项")
            case "complete": return L10n.lookup("更改了提醒事项状态")
            case "delete": return L10n.lookup("删除了提醒事项")
            default: return L10n.lookup("使用了提醒事项")
            }
        case "list_mocca_calendar_events": return L10n.lookup("查看了共享日历")
        case "create_mocca_calendar_event": return L10n.lookup("添加了共享日历事项")
        case "update_mocca_calendar_event": return L10n.lookup("更新了共享日历事项")
        case "delete_mocca_calendar_event": return L10n.lookup("删除了共享日历事项")
        case "生成图片":
            switch event.status {
            case .pending, .running:
                return event.metadata["source"] == NativeImageReplyPresentation.source
                    ? L10n.lookup(event.resultText ?? "等待图片回复") : L10n.lookup("正在生成图片")
            case .complete: return L10n.lookup("生成了图片")
            case .failed:
                if event.resultText == "已停止图片回复" {
                    return L10n.lookup("已停止图片回复")
                }
                return event.resultText ?? L10n.lookup("图片生成失败")
            }
        default: return event.name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var isWebSearch: Bool {
        isWebSearchToolEvent(event)
    }

    private var semanticIcon: String {
        if isWebSearch { return "globe" }
        switch normalizedName {
        case "create_memory", "edit_memory", "delete_memory":
            return "brain.head.profile"
        case "read_assistant_file", "edit_assistant_file":
            return "doc.text"
        case "get_time_info":
            return "clock"
        case "clipboard_tool":
            return "doc.on.clipboard"
        case "calculate":
            return "function"
        case "search_conversations":
            return "magnifyingglass"
        case "text_to_speech":
            return "waveform"
        case "get_local_weather":
            return "cloud.sun"
        case "create_calendar_event",
             "list_mocca_calendar_events",
             "create_mocca_calendar_event",
             "update_mocca_calendar_event",
             "delete_mocca_calendar_event":
            return "calendar"
        case "manage_reminders":
            return "checklist"
        case "生成图片":
            return "photo"
        default:
            return "gearshape.2"
        }
    }

    private func accessibilityStatus(hasError: Bool) -> String {
        if hasError {
            return L10n.lookup("失败")
        }
        switch event.status {
        case .pending, .running: return L10n.lookup("进行中")
        case .complete: return L10n.lookup("已完成")
        case .failed: return L10n.lookup("失败")
        }
    }

    var body: some View {
        let result = parsedResult ?? ToolEventParsedResult(event: event)
        let detailPreview = ToolEventDetailFormatter.preview(for: event, result: result)
        let hasDetails = detailPreview != nil
        let activityText = self.activityText
        let hasError = result.hasError(for: event)
        let statusColor: Color = hasError ? .red : .secondary
        let accessibilityStatus = self.accessibilityStatus(hasError: hasError)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard hasDetails else { return }
                withAnimation(ChatDisclosureMotion.animation) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: semanticIcon)
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 20)
                    Text(activityText)
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(2)
                    if event.status == .running || event.status == .pending {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(statusColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(activityText)，\(accessibilityStatus)")
            .accessibilityHint(hasDetails ? L10n.format("轻点%@工具结果", [isExpanded ? L10n.lookup("收起") : L10n.lookup("展开")]) : "")

            if isExpanded, let detailPreview {
                Text(detailPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                    .lineLimit(5)
                    .padding(.leading, 28)
                    .transition(ChatDisclosureMotion.transition)
            }
        }
        .animation(ChatDisclosureMotion.animation, value: isExpanded)
    }
}

private struct MessageEditSheet: View {
    @Binding var text: String
    let roleTitle: String
    let allowsSaveAndSend: Bool
    let onSave: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(size: 17))
                .focused($isFocused)
                .padding(14)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(16)
                .navigationTitle(roleTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if allowsSaveAndSend {
                            Button(L10n.lookup("保存并发送")) {
                                onSave(true)
                                dismiss()
                            }
                            .disabled(!canSave)
                        } else {
                            Button(L10n.lookup("取消")) {
                                dismiss()
                            }
                                .foregroundStyle(.primary)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.lookup("保存")) {
                            onSave(false)
                            dismiss()
                        }
                            .foregroundStyle(.primary)
                        .disabled(!canSave)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class DrawerTapGate {
    var suppressedUntil = Date.distantPast
}

/// Resolves only the nearest UIScrollView ancestor of the zero-sized probe
/// embedded in the drawer list. This structurally excludes the chat transcript
/// and every unrelated scroll view without scanning the window hierarchy.
private struct DrawerListScrollViewProbe: UIViewRepresentable {
    let topReturnCoordinator: DrawerListTopReturnCoordinator

    func makeUIView(context: Context) -> DrawerListScrollViewProbeUIView {
        DrawerListScrollViewProbeUIView(
            topReturnCoordinator: topReturnCoordinator
        )
    }

    func updateUIView(
        _ uiView: DrawerListScrollViewProbeUIView,
        context: Context
    ) {
        uiView.update(topReturnCoordinator: topReturnCoordinator)
        uiView.scheduleResolution()
    }

    static func dismantleUIView(
        _ uiView: DrawerListScrollViewProbeUIView,
        coordinator: ()
    ) {
        uiView.detach()
    }
}

@MainActor
private final class DrawerListScrollViewProbeUIView: UIView {
    private var topReturnCoordinator: DrawerListTopReturnCoordinator
    private weak var resolvedScrollView: UIScrollView?
    private var resolutionScheduled = false
    private var resolutionGeneration: UInt64 = 0

    init(topReturnCoordinator: DrawerListTopReturnCoordinator) {
        self.topReturnCoordinator = topReturnCoordinator
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleResolution()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detach()
        } else {
            scheduleResolution()
        }
    }

    func update(topReturnCoordinator: DrawerListTopReturnCoordinator) {
        guard self.topReturnCoordinator !== topReturnCoordinator else { return }
        detach()
        self.topReturnCoordinator = topReturnCoordinator
    }

    func scheduleResolution() {
        guard window != nil else { return }
        if let nearestScrollView = nearestAncestorScrollView() {
            attach(to: nearestScrollView)
            return
        }
        if resolvedScrollView != nil {
            detach()
        }
        guard !resolutionScheduled else { return }
        resolutionScheduled = true
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.resolutionGeneration == generation else { return }
            self.resolutionScheduled = false
            guard self.window != nil else { return }
            self.resolveScrollView()
        }
    }

    func detach() {
        resolutionGeneration &+= 1
        resolutionScheduled = false
        if let resolvedScrollView {
            resolvedScrollView.panGestureRecognizer.removeTarget(
                self,
                action: #selector(scrollViewPanStateDidChange(_:))
            )
            topReturnCoordinator.unregister(
                resolvedScrollView,
                owner: self
            )
        }
        resolvedScrollView = nil
    }

    private func resolveScrollView() {
        guard window != nil,
              let scrollView = nearestAncestorScrollView() else { return }
        attach(to: scrollView)
    }

    private func nearestAncestorScrollView() -> UIScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    private func attach(to scrollView: UIScrollView) {
        guard resolvedScrollView !== scrollView else {
            topReturnCoordinator.register(scrollView, owner: self)
            return
        }
        detach()
        resolvedScrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(
            self,
            action: #selector(scrollViewPanStateDidChange(_:))
        )
        topReturnCoordinator.register(scrollView, owner: self)
    }

    @objc
    private func scrollViewPanStateDidChange(
        _ recognizer: UIPanGestureRecognizer
    ) {
        guard recognizer.state == .began,
              let resolvedScrollView,
              recognizer === resolvedScrollView.panGestureRecognizer else {
            return
        }
        topReturnCoordinator.nativePanDidBegin(in: resolvedScrollView)
    }
}

private struct SidebarBackgroundLoadRequest: Hashable {
    let isEnabled: Bool
    let reference: String?
}

private struct SidebarBackgroundView: View, @preconcurrency Equatable {
    @Environment(AppModel.self) private var model
    @State private var backgroundImage: UIImage?
    let referenceWidth: CGFloat

    /// Drawer progress changes in the parent on every animation frame, but the
    /// fixed background's own input does not. Environment observation and the
    /// image-loading state still invalidate this view when their values change.
    static func == (lhs: SidebarBackgroundView, rhs: SidebarBackgroundView) -> Bool {
        lhs.referenceWidth == rhs.referenceWidth
    }

    var body: some View {
        let surface = Color(uiColor: model.themeSurfaceUIColor)
        let loadRequest = SidebarBackgroundLoadRequest(
            isEnabled: model.preferences.sidebarBackgroundEnabled,
            reference: model.preferences.sidebarBackground
        )
        let backgroundOpacity = UserPreferences.clamp(
            model.preferences.sidebarBackgroundOpacity,
            min: 0.0,
            max: 1.0
        )
        let maskFraction = 1 - backgroundOpacity
        let topOpacity = 0.40 * maskFraction
        let bottomOpacity = maskFraction

        GeometryReader { proxy in
            let size = proxy.size
            let resolvedReferenceWidth = min(max(referenceWidth, 1), size.width)
            ZStack(alignment: .topLeading) {
                surface
                if loadRequest.isEnabled, let backgroundImage {
                    let sourceWidth = max(backgroundImage.size.width, 1)
                    let sourceHeight = max(backgroundImage.size.height, 1)
                    let imageScale = max(
                        resolvedReferenceWidth / sourceWidth,
                        size.height / sourceHeight
                    )
                    let renderedWidth = sourceWidth * imageScale
                    let renderedHeight = sourceHeight * imageScale

                    Image(uiImage: backgroundImage)
                        .resizable()
                        .frame(width: renderedWidth, height: renderedHeight)
                        .offset(
                            x: (resolvedReferenceWidth - renderedWidth) / 2,
                            y: (size.height - renderedHeight) / 2
                        )
                    Color.black.opacity(0.04)
                        .frame(width: size.width, height: size.height)
                    LinearGradient(
                        colors: [
                            surface.opacity(topOpacity),
                            surface.opacity(bottomOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: loadRequest) {
            guard loadRequest.isEnabled else {
                backgroundImage = nil
                return
            }
            backgroundImage = AssistantMediaStore.image(
                for: loadRequest.reference
            )
        }
    }
}

private struct ConversationDrawer: View {
    let width: CGFloat
    let progress: CGFloat
    let settleProgress: DrawerDetachedMainPanelProgress
    let backgroundTrailingExtension: CGFloat
    let safeAreaInsets: EdgeInsets
    let isDrawerGestureActive: Bool
    let topReturnCoordinator: DrawerListTopReturnCoordinator
    let onRequestClose: () -> Void
    let onRequestCloseAfterConversationReady: (UUID) -> Void

    var body: some View {
        let contentProgress = min(max(progress, 0), 1)

        ConversationDrawerContent(
            width: width,
            safeAreaInsets: safeAreaInsets,
            topReturnCoordinator: topReturnCoordinator,
            onRequestClose: onRequestClose,
            onRequestCloseAfterConversationReady: onRequestCloseAfterConversationReady
        )
        .equatable()
        // Keep the gesture-only environment gate outside the stable drawer
        // content. This preserves the proven on-device vertical lock without
        // sending the transient value through the long chat transcript.
        .scrollDisabled(isDrawerGestureActive)
        .modifier(
            DrawerContentMotionModifier(
                progress: contentProgress,
                settleProgress: settleProgress
            )
        )
        // Keep the drawer surface fixed while only the contents fade and
        // translate during a drag. A custom image therefore never becomes a
        // second per-frame motion layer.
        .background(alignment: .leading) {
            SidebarBackgroundView(
                referenceWidth: width + backgroundTrailingExtension
            )
                .equatable()
                .frame(width: width + backgroundTrailingExtension)
        }
    }
}

/// One content-only group keeps fade/parallax out of the list's layout.
/// SwiftUI owns both effects, so a later content commit cannot restore the
/// old marker opacity over an imperative CALayer write.
private struct DrawerContentMotionModifier: ViewModifier {
    let progress: CGFloat
    let settleProgress: DrawerDetachedMainPanelProgress

    func body(content: Content) -> some View {
        // A vertical-list takeover may keep the list's model at its endpoint
        // while the existing spring finishes. Follow that remaining visual
        // phase here, without sending it back through the list's layout.
        let visualProgress = min(max(settleProgress.progress ?? progress, 0), 1)
        content
            .compositingGroup()
            .visualEffect { effect, _ in
                effect
                    .opacity(0.35 + 0.65 * visualProgress)
                    .offset(x: -24 * (1 - visualProgress))
            }
    }
}

/// Observes the semantic close in a zero-sized leaf so opening the drawer does
/// not invalidate the conversation list and repeat its full filtering,
/// date-grouping, and sorting work at the settle handoff.
private struct DrawerSearchCloseObserver: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.isDrawerPresented) { _, isPresented in
                if !isPresented {
                    onClose()
                }
            }
    }
}

/// A process-lifetime A/B switch. The diagnostic branch removes only the
/// visible conversation-title Text surface while retaining the exact row,
/// identity, hit target, selection background, unread dot, and menus.
private enum DrawerTitleSurfaceDiagnostic {
    static let hidesConversationTitles = ProcessInfo.processInfo.arguments.contains(
        "-diagnoseDrawerTitleSurfaceHidden"
    )
}

private enum DrawerConversationListMode: Hashable {
    case oneToOne
    case group
}

/// Gives the ordinary and group lists different native scroll identities.
/// On iOS 18 and later, each identity also retains its own exact user position
/// while the other mode is not visible. The iOS 17 fallback still prevents the
/// two data sets from inheriting the same UIScrollView content offset.
private struct DrawerConversationListPositionOwner<Content: View>: View {
    let mode: DrawerConversationListMode
    let content: Content

    init(
        mode: DrawerConversationListMode,
        @ViewBuilder content: () -> Content
    ) {
        self.mode = mode
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *) {
            IOS18DrawerConversationListPositionOwner(
                mode: mode,
                content: content
            )
        } else {
            content.id(mode)
        }
    }
}

@available(iOS 18.0, *)
private struct IOS18DrawerConversationListPositionOwner<Content: View>: View {
    let mode: DrawerConversationListMode
    let content: Content
    @State private var oneToOnePosition = ScrollPosition(edge: .top)
    @State private var groupPosition = ScrollPosition(edge: .top)

    @ViewBuilder
    var body: some View {
        switch mode {
        case .oneToOne:
            content
                .id(mode)
                .scrollPosition($oneToOnePosition)
        case .group:
            content
                .id(mode)
                .scrollPosition($groupPosition)
        }
    }
}

private struct ConversationDrawerContent: View, @preconcurrency Equatable {
    private enum DrawerSearchScope: Equatable {
        case title
        case content

        @MainActor var label: String {
            switch self {
            case .title: return L10n.lookup("标题")
            case .content: return L10n.lookup("内容")
            }
        }

        var systemImage: String {
            switch self {
            case .title: return "textformat"
            case .content: return "text.alignleft"
            }
        }
    }

    private struct ContentSearchRequest: Equatable {
        let query: String
        let isActive: Bool
        let groupChatMode: Bool
    }

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var searchScope: DrawerSearchScope = .title
    @State private var isSearchModeActive = false
    @State private var contentSearchResults: [ConversationContentSearchResult] = []
    @State private var contentSearchResultQuery = ""
    @State private var isContentSearchRunning = false
    @FocusState private var isSearchFocused: Bool
    @State private var assistantsExpanded = false
    @State private var groupChatMode = false
    @State private var conversationToRename: Conversation?
    @State private var renameTitle = ""
    @State private var conversationToDelete: Conversation?
    // This reference intentionally is not observable. Extending the tap gate
    // during every drag sample must not invalidate the heavy drawer subtree.
    @State private var drawerTapGate = DrawerTapGate()
    let width: CGFloat
    let safeAreaInsets: EdgeInsets
    let topReturnCoordinator: DrawerListTopReturnCoordinator
    let onRequestClose: () -> Void
    let onRequestCloseAfterConversationReady: (UUID) -> Void

    static func == (lhs: ConversationDrawerContent, rhs: ConversationDrawerContent) -> Bool {
        lhs.width == rhs.width
            && lhs.safeAreaInsets.top == rhs.safeAreaInsets.top
            && lhs.safeAreaInsets.bottom == rhs.safeAreaInsets.bottom
            && lhs.safeAreaInsets.leading == rhs.safeAreaInsets.leading
            && lhs.safeAreaInsets.trailing == rhs.safeAreaInsets.trailing
            && lhs.topReturnCoordinator === rhs.topReturnCoordinator
    }

    private var sourceConversations: [Conversation] {
        if groupChatMode {
            return model.conversations.filter { $0.groupAssistantIDs.count >= 2 }
        }
        return model.visibleConversations
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isContentSearchActive: Bool {
        !assistantsExpanded && searchScope == .content && !normalizedQuery.isEmpty
    }

    private var filteredConversations: [Conversation] {
        let normalizedQuery = self.normalizedQuery
        guard searchScope == .title, !normalizedQuery.isEmpty else {
            return sourceConversations
        }
        return sourceConversations.filter {
            $0.title.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var filteredAssistants: [AssistantProfile] {
        let normalizedQuery = self.normalizedQuery
        guard assistantsExpanded, !normalizedQuery.isEmpty else { return model.assistants }
        return model.assistants.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var contentSearchRequest: ContentSearchRequest {
        ContentSearchRequest(
            query: normalizedQuery,
            isActive: isSearchModeActive
                && isContentSearchActive,
            groupChatMode: groupChatMode
        )
    }

    private var visibleContentSearchResults: [ConversationContentSearchResult] {
        guard contentSearchResultQuery == normalizedQuery else { return [] }
        return contentSearchResults
    }

    private var isWaitingForContentSearch: Bool {
        isContentSearchActive
            && (isContentSearchRunning || contentSearchResultQuery != normalizedQuery)
    }

    private func conversationDateGroups(for conversations: [Conversation]) -> [ConversationDateGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: conversations) {
            calendar.startOfDay(for: $0.updatedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            ConversationDateGroup(
                day: day,
                conversations: (grouped[day] ?? []).sorted {
                    if $0.updatedAt == $1.updatedAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.updatedAt > $1.updatedAt
                }
            )
        }
    }

    var body: some View {
        let selectedConversationID = model.selectedConversationID
        let visibleContentSearchResults = self.visibleContentSearchResults
        let isWaitingForContentSearch = self.isWaitingForContentSearch

        VStack(spacing: 0) {
            HStack {
                Text("Mocca")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    guard !isDrawerTapSuppressed else { return }
                    model.performListItemHaptic()
                    if isSearchModeActive {
                        endDrawerSearch()
                    } else {
                        beginDrawerSearch()
                    }
                } label: {
                    Group {
                        if isSearchModeActive {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20, weight: .regular))
                        }
                    }
                        .frame(width: 40, height: 40)
                        .background {
                            GlassSurface(shape: Circle(), backgroundOpacity: 0.08)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isSearchModeActive
                        ? L10n.lookup("关闭搜索")
                        : (groupChatMode ? L10n.lookup("搜索群聊") : L10n.lookup("搜索聊天"))
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, safeAreaInsets.top + 10)
            .padding(.bottom, 14)

            if isSearchModeActive {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.secondary)
                    TextField(searchPlaceholder, text: $query)
                        .font(.system(size: 16))
                        .textInputAutocapitalization(.never)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            isSearchFocused = false
                        }
                        .layoutPriority(1)
                    if !assistantsExpanded {
                        Button {
                            toggleSearchScope()
                        } label: {
                            Group {
                                if searchScope == .title {
                                    Text("Aa")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                } else {
                                    Image(systemName: searchScope.systemImage)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 30)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("切换搜索范围"))
                        .accessibilityValue(searchScope.label)
                    }
                    if !normalizedQuery.isEmpty {
                        Button {
                            endDrawerSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("结束搜索"))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(Color.primary.opacity(0.065), lineWidth: 0.6)
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button {
                guard !isDrawerTapSuppressed else { return }
                model.performListItemHaptic()
                withAnimation(.easeOut(duration: 0.26)) {
                    assistantsExpanded.toggle()
                    if assistantsExpanded {
                        groupChatMode = false
                        searchScope = .title
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    AssistantAvatarView(profile: model.currentAssistant, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.currentAssistant.name)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        Text(L10n.lookup("当前助手"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(assistantsExpanded ? 180 : 0))
                        .animation(.easeOut(duration: 0.26), value: assistantsExpanded)
                }
                .padding(.horizontal, 12)
                .frame(height: 58)
                .background(
                    assistantsExpanded
                        ? Color.primary.opacity(0.045)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 5)

            if assistantsExpanded {
                VStack(spacing: 5) {
                    ForEach(filteredAssistants) { assistant in
                        assistantRow(assistant)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                .transition(.opacity)
            }

            Button {
                guard !isDrawerTapSuppressed else { return }
                model.performListItemHaptic()
                withAnimation(.easeOut(duration: 0.24)) {
                    assistantsExpanded = false
                    groupChatMode.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .frame(width: 36, height: 36)
                    Text(L10n.lookup("群聊"))
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(groupChatMode ? 90 : 0))
                        .animation(.easeOut(duration: 0.24), value: groupChatMode)
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(
                    groupChatMode
                        ? Color.primary.opacity(0.045)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)

            ZStack(alignment: .bottom) {
                DrawerConversationListPositionOwner(
                    mode: groupChatMode ? .group : .oneToOne
                ) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                    let filteredConversations = isContentSearchActive ? [] : self.filteredConversations
                    if isContentSearchActive {
                        if isWaitingForContentSearch {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.lookup("正在搜索…"))
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 38)
                        } else if visibleContentSearchResults.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Text(emptyListText)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 38)
                        } else {
                            Text(L10n.lookup("内容搜索结果"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(visibleContentSearchResults) { result in
                                contentSearchResultRow(
                                    result,
                                    isSelected: selectedConversationID == result.conversation.id
                                )
                            }
                        }
                    } else if filteredConversations.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: groupChatMode ? "bubble.left.and.bubble.right" : "text.bubble")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Text(emptyListText)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 38)
                    } else if model.preferences.showChatListDate {
                        ForEach(conversationDateGroups(for: filteredConversations)) { group in
                            Text(dateLabel(for: group.day))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            ForEach(group.conversations) { conversation in
                                conversationRow(
                                    conversation,
                                    isSelected: selectedConversationID == conversation.id
                                )
                            }
                        }
                    } else {
                        Text(groupChatMode ? L10n.lookup("群聊") : L10n.lookup("最近"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                        ForEach(filteredConversations) { conversation in
                            conversationRow(
                                conversation,
                                isSelected: selectedConversationID == conversation.id
                            )
                        }
                    }
                        }
                        .padding(.horizontal, 12)
                        // Start the resting section title exactly below the
                        // fixed 24 pt fade while keeping the gap minimal.
                        .padding(.top, 24)
                        // Keep the final topic fully reachable above the floating
                        // capsule while allowing the list to remain visible behind
                        // and below it, like ChatGPT's iPhone sidebar.
                        .padding(.bottom, safeAreaInsets.bottom + 90)
                        .background(alignment: .topLeading) {
                            DrawerListScrollViewProbe(
                                topReturnCoordinator: topReturnCoordinator
                            )
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(DrawerTopScrollEdgeEffectModifier())
                }
                // The Group Chat button keeps its own chevron/background motion,
                // but replacing a scroll identity must not cross-fade two lists.
                .animation(nil, value: groupChatMode)

                HStack(spacing: 0) {
                    Button {
                        guard !isDrawerTapSuppressed else { return }
                        model.performListItemHaptic()
                        model.isUserProfilePresented = true
                    } label: {
                        SponsorWearableAvatar(target: .user, badgeSize: 19) {
                            UserProfileAvatarView(profile: model.userProfile, size: 44)
                        }
                            .shadow(
                                color: Color.black.opacity(0.16),
                                radius: 10,
                                x: 0,
                                y: 4
                            )
                            .frame(width: 52, height: 52)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.lookup("用户资料"))

                    Spacer(minLength: 12)

                    HStack(spacing: 2) {
                        Button {
                            guard !isDrawerTapSuppressed else { return }
                            model.performListItemHaptic()
                            model.isFavoritesPresented = true
                        } label: {
                            Image(systemName: "bookmark")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 42, height: 42)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("收藏"))

                        Button {
                            guard !isDrawerTapSuppressed else { return }
                            model.performListItemHaptic()
                            model.isSettingsPresented = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 42, height: 42)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("设置"))
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 52)
                    .background {
                        GlassSurface(
                            shape: Capsule(),
                            backgroundOpacity: 0.10
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, safeAreaInsets.bottom + 8)
                .zIndex(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // The drawer intentionally stays mounted for smooth dragging. Reset
        // local search state on every real close so reopening starts as the
        // normal conversation list instead of restoring a hidden keyboard or
        // stale search result screen.
        .background {
            DrawerSearchCloseObserver(onClose: endDrawerSearch)
        }
        .task(id: contentSearchRequest) {
            await refreshContentSearch(for: contentSearchRequest)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if abs(value.translation.width) > 8 || abs(value.translation.height) > 8 {
                        suppressDrawerTaps(for: 0.20)
                    }
                }
                .onEnded { _ in
                    suppressDrawerTaps(for: 0.28)
                }
        )
        .alert(L10n.lookup("重命名聊天"), isPresented: renameBinding) {
            TextField(L10n.lookup("聊天标题"), text: $renameTitle)
            Button(L10n.lookup("取消"), role: .cancel) {
                conversationToRename = nil
                renameTitle = ""
            }
            Button(L10n.lookup("保存")) {
                if let conversationToRename {
                    model.renameConversation(conversationToRename.id, title: renameTitle)
                }
                conversationToRename = nil
                renameTitle = ""
            }
        }
        .alert(L10n.lookup("删除聊天"), isPresented: deleteBinding) {
            Button(L10n.lookup("取消"), role: .cancel) {
                conversationToDelete = nil
            }
            Button(L10n.lookup("删除"), role: .destructive) {
                if let conversationToDelete {
                    model.deleteConversation(conversationToDelete.id)
                }
                conversationToDelete = nil
            }
        } message: {
            if let conversationToDelete {
                Text(L10n.format("删除“%@”及其中的消息？", [String(describing: conversationToDelete.title)]))
            }
        }
    }

    private var searchPlaceholder: String {
        if assistantsExpanded { return L10n.lookup("搜索助手") }
        if searchScope == .content {
            return groupChatMode ? L10n.lookup("搜索群聊内容") : L10n.lookup("搜索全部聊天内容")
        }
        if groupChatMode { return L10n.lookup("搜索群聊标题") }
        return L10n.lookup("搜索当前助手标题")
    }

    private var emptyListText: String {
        if !normalizedQuery.isEmpty {
            if isContentSearchActive {
                return groupChatMode ? L10n.lookup("没有匹配的群聊内容") : L10n.lookup("没有匹配的聊天内容")
            }
            return groupChatMode ? L10n.lookup("没有匹配的群聊") : L10n.lookup("没有匹配的聊天")
        }
        return groupChatMode ? L10n.lookup("还没有群聊") : L10n.lookup("还没有聊天")
    }

    private func beginDrawerSearch() {
        query = ""
        searchScope = .title
        withAnimation(.easeOut(duration: 0.18)) {
            assistantsExpanded = false
            isSearchModeActive = true
        }
        Task { @MainActor in
            await Task.yield()
            guard isSearchModeActive, model.isDrawerPresented else { return }
            isSearchFocused = true
        }
    }

    private func toggleSearchScope() {
        guard !isDrawerTapSuppressed else { return }
        model.performListItemHaptic()
        withAnimation(.easeOut(duration: 0.16)) {
            searchScope = searchScope == .title ? .content : .title
            // Match old Kelivo's mode switch semantics: results from one
            // scope never silently become results from the other one.
            query = ""
        }
    }

    private func endDrawerSearch() {
        query = ""
        searchScope = .title
        // A deferred drawer close may arrive after the chat editor has focus.
        // Release only the search field through its own FocusState.
        isSearchFocused = false
        withAnimation(.easeOut(duration: 0.16)) {
            isSearchModeActive = false
        }
    }

    /// Content search intentionally has no idle index, timer, or display-link.
    /// The task exists only while the drawer is open in non-empty content mode;
    /// SwiftUI cancels the previous request as soon as any request field changes.
    private func refreshContentSearch(for request: ContentSearchRequest) async {
        guard request.isActive else {
            if !contentSearchResults.isEmpty { contentSearchResults = [] }
            if !contentSearchResultQuery.isEmpty { contentSearchResultQuery = "" }
            if isContentSearchRunning { isContentSearchRunning = false }
            return
        }

        contentSearchResults = []
        contentSearchResultQuery = ""
        isContentSearchRunning = true

        do {
            try await Task.sleep(for: .milliseconds(180))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        // Preserve the old Kelivo boundary: ordinary content search spans all
        // assistants, while group chats remain in their dedicated drawer mode.
        let conversations = model.conversations
            .filter { conversation in
                request.groupChatMode
                    ? conversation.groupAssistantIDs.count >= 2
                    : conversation.groupAssistantIDs.count < 2
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        let assistantsByID = Dictionary(uniqueKeysWithValues: model.assistants.map {
            ($0.id.uuidString, $0)
        })
        let availableAssistantIDs = Set(assistantsByID.keys)
        let userAvatar = SearchResultAvatarDescriptor.user(
            name: model.userProfile.nickname,
            imageSource: SearchResultAvatarImageSource.userJPEG(model.userProfile.avatarJPEGData)
        )

        var results: [ConversationContentSearchResult] = []
        results.reserveCapacity(min(conversations.count, 32))

        for (conversationIndex, conversation) in conversations.enumerated() {
            guard !Task.isCancelled else { return }
            if let message = await firstContentSearchMatch(
                in: conversation.id,
                query: request.query
            ) {
                let snippet = contentSearchSnippet(
                    for: message.text,
                    query: request.query
                )
                let authorID = SearchResultAuthorResolver.assistantID(
                    messageAuthorID: message.groupID,
                    messageID: message.id.uuidString,
                    conversationAssistantID: conversation.assistantID,
                    isGroupChat: conversation.groupAssistantIDs.count >= 2,
                    availableAssistantIDs: availableAssistantIDs
                )
                let author = authorID.flatMap { assistantsByID[$0] }
                results.append(
                    ConversationContentSearchResult(
                        conversation: conversation,
                        message: message,
                        avatar: message.role == .user ? userAvatar : .assistant(
                            name: author?.name, avatar: author?.avatar
                        ),
                        snippetSegments: contentSearchSnippetSegments(
                            for: snippet,
                            query: request.query
                        )
                    )
                )
            }

            // Let keyboard, drawer, and cancellation work run between chats.
            if conversationIndex.isMultiple(of: 2) {
                await Task.yield()
            }
        }

        guard !Task.isCancelled, contentSearchRequest == request else { return }
        contentSearchResults = results
        contentSearchResultQuery = request.query
        isContentSearchRunning = false
    }

    private func firstContentSearchMatch(
        in conversationID: UUID,
        query: String
    ) async -> ChatMessage? {
        let messages = model.searchableMessages(for: conversationID)
        for (messageIndex, message) in messages.enumerated() {
            guard !Task.isCancelled else { return nil }
            if message.text.localizedCaseInsensitiveContains(query) {
                return message
            }
            if messageIndex % 12 == 11 {
                await Task.yield()
            }
        }
        return nil
    }

    private var isDrawerTapSuppressed: Bool {
        Date() < drawerTapGate.suppressedUntil
    }

    private func suppressDrawerTaps(for seconds: TimeInterval) {
        drawerTapGate.suppressedUntil = Date().addingTimeInterval(seconds)
    }

    private func assistantRow(_ assistant: AssistantProfile) -> some View {
        Button {
            guard !isDrawerTapSuppressed else { return }
            model.performListItemHaptic()
            let shouldClose = !model.preferences.keepSidebarOpenOnAssistantTap
            withAnimation(.easeOut(duration: 0.22)) {
                assistantsExpanded = false
            }
            let previousConversationID = model.selectedConversationID
            model.selectAssistant(assistant.id, closeDrawer: false)
            if shouldClose {
                let selectedConversationID = model.selectedConversationID
                if selectedConversationID == previousConversationID {
                    onRequestClose()
                } else {
                    onRequestCloseAfterConversationReady(selectedConversationID)
                }
            }
        } label: {
            HStack(spacing: 12) {
                AssistantAvatarView(profile: assistant, size: 34)
                Text(assistant.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if assistant.id == model.currentAssistantID {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                assistant.id == model.currentAssistantID
                    ? Color.primary.opacity(0.055)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.isSettingsPresented = true
            } label: {
                Label(L10n.lookup("管理助手"), systemImage: "slider.horizontal.3")
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { conversationToRename != nil },
            set: { isPresented in
                if !isPresented {
                    conversationToRename = nil
                    renameTitle = ""
                }
            }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { conversationToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    conversationToDelete = nil
                }
            }
        )
    }

    private func beginRename(_ conversation: Conversation) {
        conversationToRename = conversation
        renameTitle = conversation.title
    }

    private func dateLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L10n.lookup("今天") }
        if calendar.isDateInYesterday(day) { return L10n.lookup("昨天") }
        let format: Date.FormatStyle = calendar.component(.year, from: day) == calendar.component(.year, from: .now)
            ? .dateTime.month().day()
            : .dateTime.year().month().day()
        return day.formatted(format)
    }

    private func contentSearchResultRow(
        _ result: ConversationContentSearchResult,
        isSelected: Bool
    ) -> some View {
        Button {
            selectContentSearchResultFromDrawer(result)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                SearchResultAvatar(descriptor: result.avatar)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if result.conversation.groupAssistantIDs.count >= 2 {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(result.conversation.localizedDisplayTitle)
                            .font(.system(
                                size: 17 * CGFloat(model.preferences.chatFontScale),
                                weight: isSelected ? .semibold : .medium
                            ))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        DrawerUnreadReplyIndicator(
                            conversationID: result.conversation.id,
                            isSelected: isSelected
                        )
                    }

                    highlightedContentSnippet(for: result)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? Color.primary.opacity(0.055)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("\(result.message.id.uuidString)-\(isSelected)")
    }

    private func contentSearchSnippet(for text: String, query: String) -> String {
        let compactText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let matchRange = compactText.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return String(compactText.prefix(120))
        }

        let start = compactText.index(
            matchRange.lowerBound,
            offsetBy: -36,
            limitedBy: compactText.startIndex
        ) ?? compactText.startIndex
        let end = compactText.index(
            matchRange.upperBound,
            offsetBy: 96,
            limitedBy: compactText.endIndex
        ) ?? compactText.endIndex
        let prefix = start > compactText.startIndex ? "…" : ""
        let suffix = end < compactText.endIndex ? "…" : ""
        return prefix + String(compactText[start..<end]) + suffix
    }

    private func contentSearchSnippetSegments(
        for snippet: String,
        query: String
    ) -> [ConversationContentSearchSnippetSegment] {
        guard !query.isEmpty else {
            return [ConversationContentSearchSnippetSegment(text: snippet, isMatch: false)]
        }

        var segments: [ConversationContentSearchSnippetSegment] = []
        var cursor = snippet.startIndex
        while cursor < snippet.endIndex,
              let match = snippet.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: cursor..<snippet.endIndex
              ) {
            if cursor < match.lowerBound {
                segments.append(
                    ConversationContentSearchSnippetSegment(
                        text: String(snippet[cursor..<match.lowerBound]),
                        isMatch: false
                    )
                )
            }
            segments.append(
                ConversationContentSearchSnippetSegment(
                    text: String(snippet[match]),
                    isMatch: true
                )
            )
            cursor = match.upperBound
        }
        if cursor < snippet.endIndex {
            segments.append(
                ConversationContentSearchSnippetSegment(
                    text: String(snippet[cursor..<snippet.endIndex]),
                    isMatch: false
                )
            )
        }
        return segments.isEmpty
            ? [ConversationContentSearchSnippetSegment(text: snippet, isMatch: false)]
            : segments
    }

    private func highlightedContentSnippet(
        for result: ConversationContentSearchResult
    ) -> Text {
        result.snippetSegments.reduce(Text("")) { partial, segment in
            partial + Text(segment.text)
                .foregroundColor(segment.isMatch ? .accentColor : .secondary)
                .fontWeight(segment.isMatch ? .semibold : .regular)
        }
    }

    private func selectConversationFromDrawer(_ conversation: Conversation) {
        guard !isDrawerTapSuppressed else { return }
        model.performListItemHaptic()
        let shouldClose = !model.preferences.keepSidebarOpenOnTopicTap
        let previousConversationID = model.selectedConversationID
        let isSwitchingConversation = previousConversationID != conversation.id
        if shouldClose, isSwitchingConversation {
            VersionFlashTrace.begin(
                oldConversationID: previousConversationID,
                targetConversationID: conversation.id
            )
        }
        selectConversationWithoutAnimation(conversation.id, closeDrawer: false)
        // A row can become obsolete if the backing collection is replaced
        // while the drawer stays mounted. Never turn a rejected stale-ID
        // selection into a misleading drawer close.
        guard model.selectedConversationID == conversation.id else { return }
        VersionFlashTrace.record(
            "SELECTION_COMMIT"
                + " conv=\(VersionFlashTrace.identifierToken(conversation.id))"
                + " req=\(model.conversationBottomReturnRequest)"
        )
        if shouldClose {
            if isSwitchingConversation {
                onRequestCloseAfterConversationReady(conversation.id)
            } else {
                onRequestClose()
            }
        }
    }

    private func selectContentSearchResultFromDrawer(
        _ result: ConversationContentSearchResult
    ) {
        guard !isDrawerTapSuppressed else { return }
        model.performListItemHaptic()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        let didSelect = withTransaction(transaction) {
            model.selectConversation(
                result.conversation.id,
                targeting: result.message.id,
                usesCoveredViewportTransition: true,
                closeDrawer: false
            )
        }
        guard didSelect else { return }

        // Exact-message navigation waits for the drawer to release interaction
        // ownership. Close immediately, as favorites do, rather than waiting for
        // the ordinary conversation-bottom readiness handshake.
        onRequestClose()
    }

    private func conversationRow(
        _ conversation: Conversation,
        isSelected: Bool
    ) -> some View {
        Button {
            selectConversationFromDrawer(conversation)
        } label: {
            HStack(spacing: 8) {
                if conversation.groupAssistantIDs.count >= 2 {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if DrawerTitleSurfaceDiagnostic.hidesConversationTitles {
                    Color.clear
                        .frame(width: 1, height: 22)
                        .accessibilityLabel(conversation.title)
                } else {
                    Text(conversation.localizedDisplayTitle)
                        .font(.system(
                            size: 18 * CGFloat(model.preferences.chatFontScale),
                            weight: isSelected ? .medium : .regular
                        ))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                DrawerUnreadReplyIndicator(
                    conversationID: conversation.id,
                    isSelected: isSelected
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                isSelected
                    ? Color.primary.opacity(0.055)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The drawer stays mounted while the main conversation switches.
        // Recreate only the two rows whose selection bit changed so a lazy
        // row cannot retain the previous selection indicator/background node.
        .id(
            ConversationDrawerRowIdentity(
                conversationID: conversation.id,
                isSelected: isSelected,
                title: conversation.title
            )
        )
        .contextMenu {
            Button {
                beginRename(conversation)
            } label: {
                Label(L10n.lookup("重命名"), systemImage: "pencil")
            }

            Button {
                model.regenerateConversationTitle(conversation.id)
            } label: {
                Label(L10n.lookup("重新生成标题"), systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                conversationToDelete = conversation
            } label: {
                Label(L10n.lookup("删除"), systemImage: "trash")
            }
        }
    }

    private func selectConversationWithoutAnimation(_ id: UUID, closeDrawer: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.selectConversation(id, closeDrawer: closeDrawer)
        }
    }
}

private struct ConversationDateGroup: Identifiable {
    let day: Date
    let conversations: [Conversation]
    var id: Date { day }
}

private struct ConversationContentSearchResult: Identifiable {
    let conversation: Conversation
    let message: ChatMessage
    let avatar: SearchResultAvatarDescriptor
    let snippetSegments: [ConversationContentSearchSnippetSegment]
    var id: UUID { message.id }
}

private struct ConversationContentSearchSnippetSegment {
    let text: String
    let isMatch: Bool
}

private struct DrawerTopScrollEdgeEffectModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                // The drawer list has a local clipped viewport rather than a
                // screen safe-area edge, so the native scroll-edge style has
                // no underlap region here. Fade only the rendered viewport;
                // this does not inset content or observe scrolling.
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [Color.white.opacity(0), Color.white],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 24)

                        Rectangle().fill(Color.white)
                    }
                }
        } else {
            content
        }
    }
}

/// Observe reply completion at the dot, outside list filtering/grouping and
/// row identity. Other dots can re-evaluate when the shared unread set changes;
/// the containing list and titles do not need that dependency.
private struct DrawerUnreadReplyIndicator: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    let isSelected: Bool

    var body: some View {
        if !isSelected && model.unreadReplyConversationIDs.contains(conversationID) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
        }
    }
}

private struct ConversationDrawerRowIdentity: Hashable {
    let conversationID: UUID
    let isSelected: Bool
    // A renamed conversation must get a fresh lazy-row render node. Without
    // the title in this identity, the persisted value can change while the
    // drawer keeps displaying its cached label until the app is relaunched.
    let title: String
}

private struct FavoriteMessagesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [FavoriteMessageItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allItems = model.conversations.flatMap { conversation in
            (model.conversationMessageStore[conversation.id] ?? []).compactMap { message -> FavoriteMessageItem? in
                guard message.reactions.bookmarkedAt != nil else { return nil }
                return FavoriteMessageItem(conversation: conversation, message: message)
            }
        }
        let filtered = normalizedQuery.isEmpty
            ? allItems
            : allItems.filter {
                $0.conversation.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || $0.message.text.localizedCaseInsensitiveContains(normalizedQuery)
            }
        return filtered.sorted {
            ($0.message.reactions.bookmarkedAt ?? $0.message.createdAt) > ($1.message.reactions.bookmarkedAt ?? $1.message.createdAt)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.lookup("搜索收藏"), text: $query)
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.lookup("清除搜索"))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)

                if items.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? L10n.lookup("还没有收藏") : L10n.lookup("没有匹配的收藏"),
                        systemImage: "bookmark",
                        description: Text(query.isEmpty ? L10n.lookup("长按消息选择收藏后，会出现在这里。") : L10n.lookup("换个关键词再试试。"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { item in
                            FavoriteMessageCard(item: item) {
                                model.performListItemHaptic()
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                let didSelect = withTransaction(transaction) {
                                    model.selectConversation(
                                        item.conversation.id,
                                        targeting: item.message.id,
                                        usesCoveredViewportTransition: true,
                                        closeDrawer: false
                                    )
                                }
                                guard didSelect else { return }
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    model.setDrawerPresented(false)
                                }
                                dismiss()
                            } onRemove: {
                                model.performCardHaptic()
                                model.toggleMessageBookmark(item.message.id)
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(uiColor: model.themeSurfaceUIColor).ignoresSafeArea())
            .navigationTitle(L10n.lookup("收藏"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.lookup("完成")) {
                        dismiss()
                    }
                        .foregroundStyle(.primary)
                }
            }
        }
        .tint(Color(uiColor: model.themeActionUIColor))
    }
}

private struct FavoriteMessageItem: Identifiable {
    let conversation: Conversation
    let message: ChatMessage

    var id: UUID { message.id }
}

private struct FavoriteMessageCard: View {
    @Environment(AppModel.self) private var model
    let item: FavoriteMessageItem
    let onOpen: () -> Void
    let onRemove: () -> Void

    private var timestampText: String {
        let date = item.message.reactions.bookmarkedAt ?? item.message.createdAt
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private var assistant: AssistantProfile {
        model.assistantProfile(id: item.message.groupID)
            ?? model.assistantProfile(id: item.conversation.assistantID)
            ?? item.conversation.groupAssistantIDs.lazy
                .compactMap { model.assistantProfile(id: $0) }
                .first
            ?? model.currentAssistant
    }

    private var themeActionColor: Color {
        Color(uiColor: model.themeActionUIColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AssistantAvatarView(profile: assistant, size: 24)
                Text(item.conversation.localizedDisplayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(timestampText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button(action: onRemove) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(themeActionColor)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.lookup("取消收藏"))
            }

            Text(item.message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 14))
                .lineSpacing(2)
                .foregroundStyle(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
