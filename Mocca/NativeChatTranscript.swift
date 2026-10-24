import SwiftUI
import UIKit
import Combine
import Observation

/// A discrete hosted disclosure can animate its cell size for the lifetime of
/// the existing SwiftUI animation. Ordinary streaming and paging stay atomic.
@MainActor
struct NativeChatRowDisclosureMotion {
    let begin: () -> UUID?
    let end: (UUID) -> Void

    func animate(_ animation: Animation, completion: (() -> Void)? = nil, changes: () -> Void) {
        guard let operation = begin() else {
            if let completion {
                withAnimation(animation, completionCriteria: .removed, changes, completion: completion)
            } else {
                withAnimation(animation, changes)
            }
            return
        }
        var transaction = Transaction(animation: animation)
        transaction.nativeChatDisclosureOperation = operation
        transaction.addAnimationCompletion(criteria: .removed) {
            end(operation)
            completion?()
        }
        withTransaction(transaction, changes)
    }

    /// A measured disclosure animates its own height. Only its button may
    /// acquire reading ownership; automatic stream transitions must retain
    /// the existing follow owner. Keep collection sizing atomic in both cases.
    func beginManualMeasuredDisclosure() {
        if let operation = begin() { end(operation) }
    }

}

private struct NativeChatRowDisclosureMotionKey: EnvironmentKey {
    static let defaultValue: NativeChatRowDisclosureMotion? = nil
}

private struct NativeChatDisclosureOperationKey: TransactionKey {
    static let defaultValue: UUID? = nil
}

private extension Transaction {
    var nativeChatDisclosureOperation: UUID? {
        get { self[NativeChatDisclosureOperationKey.self] }
        set { self[NativeChatDisclosureOperationKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var nativeChatRowDisclosureMotion: NativeChatRowDisclosureMotion? {
        get { self[NativeChatRowDisclosureMotionKey.self] }
        set { self[NativeChatRowDisclosureMotionKey.self] = newValue }
    }
}

/// Structured content can keep its growing bottom edge attached to the
/// viewport in the same self-sizing transaction. Prose retains stream easing.
struct NativeChatStableStreamingBottomKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

struct NativeChatRow {
    let id: UUID
    let revision: AnyHashable
    let content: AnyView
    var isMessage = true
    var sendOrigin: ComposerSendOrigin? = nil
}

private struct NativeChatSendOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var nativeChatSendOffset: CGFloat? {
        get { self[NativeChatSendOffsetKey.self] }
        set { self[NativeChatSendOffsetKey.self] = newValue }
    }
}

struct NativeChatLayoutConfiguration: Equatable {
    var top: CGFloat = 22
    var bottom: CGFloat = 22
    var gap: CGFloat = 30
    var viewportInsets: UIEdgeInsets = .zero
    var minimumIncludesTopInset = true
    var alignShortContentToBottom = false
    // Space between a bottom-pinned message and the composer's upper edge.
    var bottomFollowClearance: CGFloat = 0
}

struct NativeChatDebugWindow {
    let start: Int
    let end: Int
    let total: Int
}

struct NativeChatRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum NativeChatScrollTarget {
    case top
    case bottom
    case row(UUID, UnitPoint)
    case rowBottom(UUID, CGFloat)
    case rowTop(UUID, CGFloat)
}

enum NativeChatScrollTiming: String {
    case easeOut, easeInOut, smooth, system, send, edge

    @MainActor
    fileprivate func animator(duration: TimeInterval) -> UIViewPropertyAnimator? {
        switch self {
        case .system, .send, .edge:
            return nil
        case .easeOut:
            return UIViewPropertyAnimator(duration: duration, curve: .easeOut)
        case .easeInOut:
            return UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
        case .smooth:
            let spring = Spring.smooth(duration: duration, extraBounce: 0)
            let timing = UISpringTimingParameters(
                mass: CGFloat(spring.mass), stiffness: CGFloat(spring.stiffness),
                damping: CGFloat(spring.damping), initialVelocity: .zero)
            return UIViewPropertyAnimator(duration: duration, timingParameters: timing)
        }
    }
}

/// A send trajectory also used by long edge-button navigation. A measured
/// destination can move while cells appear;
/// join the remaining segment at the last presented position AND velocity.
private struct NativeChatSendTrajectory {
    private var origin: CGFloat
    private var destination: CGFloat
    private var initialVelocity: CGFloat = 0
    private var start: TimeInterval
    private var duration: TimeInterval
    private let nominalDuration: TimeInterval
    private var lastTime: TimeInterval
    private var lastPosition: CGFloat
    private var lastVelocity: CGFloat = 0

    init(origin: CGFloat, destination: CGFloat, start: TimeInterval, duration: TimeInterval) {
        self.origin = origin
        self.destination = destination
        self.start = start
        self.duration = duration
        self.nominalDuration = duration
        self.lastTime = start
        self.lastPosition = origin
    }

    mutating func advance(to target: CGFloat, from current: CGFloat, at time: TimeInterval)
        -> (position: CGFloat, velocity: CGFloat, finished: Bool) {
        if target != destination || abs(current - lastPosition) > 0.5 {
            let distance = target - current
            // Preserve velocity when it still points toward the measured end.
            // If layout has moved the end behind us, braking to zero avoids
            // carrying momentum farther away from the now-correct endpoint.
            initialVelocity = lastVelocity * distance > 0 ? lastVelocity : 0
            let remaining = max(0, start + duration - lastTime)
            // A last-frame measurement still gets a short settling segment
            // (80 ms for the ordinary send), using this same display link.
            duration = max(remaining, nominalDuration / 4)
            if initialVelocity != 0 {
                // A cubic with zero ending velocity is monotone for v*T <= 3*d.
                // Shorten its duration rather than clamping the joining speed.
                duration = min(duration, Double(3 * abs(distance / initialVelocity)))
            }
            origin = current
            destination = target
            start = lastTime
        }
        let elapsed = max(0, time - start)
        let t = CGFloat(duration > 0 ? min(1, elapsed / duration) : 1)
        let distance = destination - origin
        let position = origin + distance * t * t * (3 - 2 * t)
            + initialVelocity * CGFloat(duration) * t * (1 - t) * (1 - t)
        let velocity = t < 1 && duration > 0
            ? distance * 6 * t * (1 - t) / CGFloat(duration)
                + initialVelocity * (1 - t) * (1 - 3 * t)
            : 0
        lastTime = time
        lastPosition = position
        lastVelocity = velocity
        return (position, velocity, t == 1)
    }
}

enum NativeChatRowResizeAnchor { case top, bottom, transcriptBottom }

enum NativeChatScrollPhase: Equatable {
    case idle, tracking, interacting, decelerating, animating
}

struct NativeChatScrollGeometry: Equatable {
    let publicationID: AnyHashable
    let sessionID: AnyHashable
    /// The inner message frames, in viewport coordinates; not padded cell frames.
    let frames: [UUID: CGRect]
    let bottomSpacerFrame: CGRect
    let contentSize: CGSize
    let minimumContentHeight: CGFloat
    let contentInsets: UIEdgeInsets
    let contentOffset: CGPoint
    let containerSize: CGSize
    let visibleRect: CGRect
    var rowFrames: [UUID: CGRect] { frames }
    var insets: UIEdgeInsets { contentInsets }
    var viewportSize: CGSize { containerSize }
}

struct NativeChatScrollPhaseChange {
    let oldPhase: NativeChatScrollPhase
    let newPhase: NativeChatScrollPhase
    let geometry: NativeChatScrollGeometry?
}

struct NativeChatViewportMetrics {
    let size: CGSize
    let contentSize: CGSize
    let insets: UIEdgeInsets
    let offset: CGPoint
    var viewportHeight: CGFloat { max(0, size.height - insets.top - insets.bottom) }
    var bottomOffsetY: CGFloat { max(-insets.top, contentSize.height - size.height + insets.bottom) }
    func hasSameLayout(as other: Self) -> Bool {
        size == other.size && contentSize == other.contentSize && insets == other.insets
    }
}

struct NativeChatViewportLayoutChange {
    let scrollView: UIScrollView
    let publicationID: AnyHashable
    let sessionID: AnyHashable
    let previous: NativeChatViewportMetrics
    let current: NativeChatViewportMetrics
    let presentedOffsetBeforeLayout: CGFloat?
}

fileprivate final class NativeChatCollectionView: UICollectionView, TextSelectionAutoscrollHost {
    var onSelectionAutoscrollBegan: (() -> Void)?
    var onSelectionAutoscrollEnded: (() -> Void)?
    private(set) var selectionAutoscrolling = false

    func selectionAutoscrollDidBegin() {
        selectionAutoscrolling = true
        onSelectionAutoscrollBegan?()
    }
    func selectionAutoscrollDidEnd() {
        selectionAutoscrolling = false
        onSelectionAutoscrollEnded?()
    }
    var onViewportLayout: ((NativeChatViewportMetrics, NativeChatViewportMetrics, CGFloat?) -> Void)?
    var onContentLayoutCompleted: (() -> Void)?
    private var lastLayoutMetrics: NativeChatViewportMetrics?
    private var deliveringViewportLayout = false
    private var hasLaidOutViewport = false

    override func action(for layer: CALayer, forKey event: String) -> CAAction? {
        // A first send can mount this zero-sized view inside UIKit's keyboard
        // animation. Its clipping viewport must start at its real size, rather
        // than reveal the rows as bounds/position animate out from zero.
        if !hasLaidOutViewport, layer === self.layer,
           event == "bounds" || event == "position" {
            return NSNull()
        }
        return super.action(for: layer, forKey: event)
    }

    private var metrics: NativeChatViewportMetrics {
        .init(size: bounds.size, contentSize: contentSize, insets: adjustedContentInset, offset: contentOffset)
    }
    var hasPendingAnimatedViewportResize: Bool {
        // UIKit can reintroduce a cell inside super.layoutSubviews(), before
        // onViewportLayout admits the parent keyboard motion. Protect that
        // same transaction without advancing the scroll owner's lifecycle.
        guard hasLaidOutViewport, let previous = lastLayoutMetrics,
              UIView.inheritedAnimationDuration > 0 else { return false }
        let current = metrics
        return current.size.width == previous.size.width
            && abs(current.viewportHeight - previous.viewportHeight) > 0.5
    }
    override func layoutSubviews() {
        defer { onContentLayoutCompleted?() }
        #if DEBUG
        if FullMotionCostProbe.enabled { FullMotionCostProbe.layouts += 1 }
        #endif
        StreamLayoutWorkProbe.hit("collection.layout")
        let previous = lastLayoutMetrics
        let presentedOffset = layer.presentation()?.bounds.origin.y
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0 { hasLaidOutViewport = true }
        let current = metrics
        // Install first: the UIKit-only animation callback can cause another
        // layout. Neither that reentry nor offset-only scrolling is a resize.
        lastLayoutMetrics = current
        guard !deliveringViewportLayout, let previous,
              !current.hasSameLayout(as: previous) else { return }
        deliveringViewportLayout = true
        onViewportLayout?(previous, current, presentedOffset)
        deliveringViewportLayout = false
        lastLayoutMetrics = metrics
    }
}

@MainActor
final class NativeChatScrollDriver {
    let geometryEvents = PassthroughSubject<NativeChatScrollGeometry, Never>()
    // Only the UIKit animation owner receives this synchronous layout event.
    // Business geometry/phase delivery remains deferred outside layout.
    let viewportLayoutEvents = PassthroughSubject<NativeChatViewportLayoutChange, Never>()
    let phaseEvents = PassthroughSubject<NativeChatScrollPhaseChange, Never>()
    let codeLayoutEvents = PassthroughSubject<[UUID: CGRect], Never>()
    private(set) weak var scrollView: UIScrollView?
    private(set) var latestGeometry: NativeChatScrollGeometry?
    private(set) var phase: NativeChatScrollPhase = .idle
    private(set) var positionIsUserOwned = false
    private(set) var initialBottomPositionPending = false
    private var initialPositionAvailable = false
    fileprivate weak var controller: NativeChatTranscriptController?
    fileprivate var target: NativeChatScrollTarget?
    fileprivate var positionCommandID: UUID?
    var followBottomContentChanges = false
    var externalViewportMotion = false {
        didSet { controller?.refreshPhase() }
    }
    var positionIsBottomPinned: Bool { followBottomContentChanges && !externalViewportMotion }
    var isPinnedToBottom: Bool { positionIsBottomPinned }
    var positionHasExplicitTarget: Bool { target != nil }
    var hasActiveScrollCommand: Bool { controller?.hasActiveScrollCommand == true }
    // Navigation owns the measured landing through its outer await/validation.
    // A completed native command alone does not transfer that ownership.
    fileprivate private(set) var bottomLandingValidationID: UUID?
    func beginBottomLandingValidation() -> UUID {
        let id = UUID()
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("-fullMotionDisableLandingHandoff") {
            bottomLandingValidationID = id
        }
        #else
        bottomLandingValidationID = id
        #endif
        #if DEBUG
        FullMotionLandingProbe.record(["stage": "handoffBegin", "id": id.uuidString,
            "held": bottomLandingValidationID == id])
        #endif
        return id
    }
    func endBottomLandingValidation(_ id: UUID) {
        let owns = bottomLandingValidationID == id
        if owns { bottomLandingValidationID = nil }
        #if DEBUG
        FullMotionLandingProbe.record(["stage": "handoffEnd", "id": id.uuidString,
            "owned": owns, "remaining": bottomLandingValidationID?.uuidString ?? ""])
        #endif
    }
    var ownsStreamingViewportMotion: Bool { controller?.ownsStreamingViewportMotion == true }
    #if DEBUG
    func landingProbe() -> [String: Any] { controller?.landingProbe() ?? ["controller": false] }
    #endif
    func currentGeometrySnapshot() -> NativeChatScrollGeometry? {
        controller?.currentGeometrySnapshot()
    }

    func releasePosition(userOwned: Bool = false) {
        initialPositionAvailable = false
        initialBottomPositionPending = false
        target = nil; positionCommandID = nil
        followBottomContentChanges = false
        positionIsUserOwned = userOwned
        controller?.cancelCommand(reason: userOwned ? "userRelease" : "positionReleased")
    }

    /// A disclosure keeps its existing edge through self-sizing. It issues no
    /// scroll command and is released by the same request that acquired it.
    func beginRowResize(requestID: UUID, rowID: UUID, anchor: NativeChatRowResizeAnchor) -> Bool {
        controller?.beginRowResize(requestID: requestID, rowID: rowID, anchor: anchor) ?? false
    }

    func endRowResize(_ requestID: UUID) {
        guard positionCommandID == requestID, !hasActiveScrollCommand else { return }
        releasePosition()
    }

    func armBottomPin() {
        initialPositionAvailable = false
        initialBottomPositionPending = false
        controller?.cancelCommand(reason: "bottomOwnerChanged")
        positionIsUserOwned = false
        positionCommandID = nil
        target = .bottom
        followBottomContentChanges = true
    }

    func pinToBottom() {
        guard !externalViewportMotion else { armBottomPin(); return }
        scroll(to: .bottom, completion: { _ in })
    }

    /// Only the bootstrap owner can consume this readiness acknowledgment.
    /// A later send/navigation command has already cleared the pending bit.
    func finishInitialBottomPositioning(keepBottomPinned: Bool) {
        guard initialBottomPositionPending else { return }
        initialBottomPositionPending = false
        guard positionCommandID == nil else { return }
        followBottomContentChanges = keepBottomPinned
        if keepBottomPinned { target = .bottom }
        else if case .bottom? = target { target = nil }
    }

    fileprivate func beginInitialBottomPositioning(enabled: Bool) -> Bool {
        guard initialPositionAvailable else { return false }
        initialPositionAvailable = false
        initialBottomPositionPending = enabled
        positionIsUserOwned = false
        positionCommandID = nil
        followBottomContentChanges = enabled
        target = enabled ? .bottom : nil
        return true
    }

    fileprivate func beginCommand(_ target: NativeChatScrollTarget, id: UUID) {
        initialPositionAvailable = false
        initialBottomPositionPending = false
        positionIsUserOwned = false
        positionCommandID = id
        self.target = target
        followBottomContentChanges = { if case .bottom = target { return true }; return false }()
    }

    @discardableResult
    func scroll(to target: NativeChatScrollTarget, duration: TimeInterval? = nil,
                timing: NativeChatScrollTiming = .easeOut,
                completion: @escaping (Bool) -> Void = { _ in }) -> UUID {
        let id = UUID()
        initialPositionAvailable = false
        initialBottomPositionPending = false
        guard let controller else { completion(false); return id }
        controller.scroll(to: target, duration: duration, timing: timing, requestID: id, completion: completion)
        return id
    }

    /// The cancellation hop carries its own UUID. It cannot release or cancel a
    /// newer command even if the task is cancelled after its completion raced.
    func scrollAndWait(to target: NativeChatScrollTarget, duration: TimeInterval? = nil,
                       timing: NativeChatScrollTiming = .easeOut) async -> Bool {
        let id = UUID()
        let completed = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                guard !Task.isCancelled, let controller else {
                    continuation.resume(returning: false)
                    return
                }
                initialPositionAvailable = false
                initialBottomPositionPending = false
                controller.scroll(to: target, duration: duration, timing: timing, requestID: id) { success in
                    continuation.resume(returning: success)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelScroll(requestID: id) }
        }
        return completed && !Task.isCancelled
    }

    func cancelScroll(requestID: UUID) {
        controller?.cancelCommand(requestID: requestID, reason: "taskCancelled")
    }

    fileprivate func attach(_ controller: NativeChatTranscriptController) {
        guard self.controller !== controller else { return }
        let previous = self.controller
        self.controller = nil; scrollView = nil
        latestGeometry = nil; phase = .idle
        positionIsUserOwned = false; initialBottomPositionPending = false
        positionCommandID = nil; target = nil
        followBottomContentChanges = false; externalViewportMotion = false
        previous?.cancelCommand(reason: "controllerReplaced")
        self.controller = controller
        scrollView = controller.collection
        initialPositionAvailable = true
    }

    fileprivate func detach(_ controller: NativeChatTranscriptController) {
        guard self.controller === controller else { return }
        self.controller = nil; scrollView = nil
        latestGeometry = nil; target = nil; positionCommandID = nil
        followBottomContentChanges = false; externalViewportMotion = false
        positionIsUserOwned = false; initialBottomPositionPending = false; phase = .idle
        initialPositionAvailable = false
    }

    fileprivate func publish(_ geometry: NativeChatScrollGeometry) {
        latestGeometry = geometry
        geometryEvents.send(geometry)
    }

    fileprivate func publishPhase(_ next: NativeChatScrollPhase, geometry: NativeChatScrollGeometry?) {
        guard next != phase else { return }
        let previous = phase
        phase = next
        phaseEvents.send(.init(oldPhase: previous, newPhase: next, geometry: geometry))
    }
}

/// An explicit edit owns its destination in the structural layout and subsequent
/// self-sizing. A replacement never reveals its top before aligning its bottom.
struct NativeChatMutationLanding {
    let requestID: UUID
    let sourcePublicationID: AnyHashable
    let destinationPublicationID: AnyHashable
    let scrollViewIdentity: ObjectIdentifier
    let removedID: UUID
    let targetID: UUID
    // Deletion targets a surviving row; replacement targets a newly inserted row.
    let isReplacement: Bool
    let target: NativeChatScrollTarget
    var onRejected: @MainActor () -> Void = {}
    let isCurrent: @MainActor () -> Bool
}

struct NativeChatTranscript: UIViewControllerRepresentable {
    var rows: [NativeChatRow]
    var configuration: NativeChatLayoutConfiguration
    var publicationID: AnyHashable
    var sessionID: AnyHashable
    var driver: NativeChatScrollDriver
    var hasEarlier: Bool
    var hasLater: Bool
    var initialBottom = true
    var holdsAutomaticBottomFollow = false
    var streamingTailID: UUID? = nil
    var mutationLanding: NativeChatMutationLanding?
    var composerHeightPresentation: ComposerHeightPresentation?
    var disclosureOperation: UUID?
    var debugWindow: NativeChatDebugWindow? = nil
    var onGeometry: (NativeChatScrollGeometry) -> Void = { _ in }
    var onPhase: (NativeChatScrollPhaseChange) -> Void = { _ in }
    var onCodeLayout: ([UUID: CGRect]) -> Void = { _ in }
    var onAttach: (UIScrollView) -> Void = { _ in }
    var onDetach: (UIScrollView) -> Void = { _ in }
    var onPageEarlier: () -> Bool = { false }
    var onPageLater: () -> Bool = { false }

    func makeUIViewController(context: Context) -> NativeChatTranscriptController {
        let controller = NativeChatTranscriptController(input: self)
        #if DEBUG
        controller.debugLifecycle("make")
        #endif
        return controller
    }

    func updateUIViewController(_ controller: NativeChatTranscriptController, context: Context) {
        var next = self
        next.disclosureOperation = context.transaction.nativeChatDisclosureOperation
        if let height = context.environment.composerHeightPresentation,
           AnyHashable(height.identity.conversationID) == sessionID {
            next.composerHeightPresentation = height
            next.configuration.bottom = height.bottomClearance
            next.configuration.bottomFollowClearance = max(0, height.bottomClearance - height.shellHeight)
        }
        controller.update(next)
    }

    static func dismantleUIViewController(_ controller: NativeChatTranscriptController, coordinator: ()) {
        controller.detach()
    }
}

private struct NativeChatHeightIndex {
    var values: [CGFloat] = []
    private var tree: [CGFloat] = [0]
    mutating func reset(_ values: [CGFloat]) {
        self.values = values
        tree = Array(repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() { add(index, value) }
    }
    private mutating func add(_ index: Int, _ delta: CGFloat) {
        var i = index + 1
        while i < tree.count { tree[i] += delta; i += i & -i }
    }
    mutating func replace(_ index: Int, _ value: CGFloat) {
        let delta = value - values[index]
        values[index] = value
        add(index, delta)
    }
    func prefix(_ count: Int) -> CGFloat {
        var i = min(count, values.count), result: CGFloat = 0
        while i > 0 { result += tree[i]; i -= i & -i }
        return result
    }
    var total: CGFloat { prefix(values.count) }
    func index(containing y: CGFloat) -> Int {
        var index = 0, step = 1, accumulated: CGFloat = 0
        while step <= values.count { step <<= 1 }
        while step > 0 {
            let next = index + step
            if next < tree.count && accumulated + tree[next] <= y {
                index = next; accumulated += tree[next]
            }
            step >>= 1
        }
        return min(index, max(0, values.count - 1))
    }
}

private struct NativeChatRowKey: Equatable {
    let id: UUID
    let revision: AnyHashable
}

private struct NativeChatFrameObservation: Equatable {
    let key: NativeChatRowKey
    let publication: AnyHashable
    let frames: [UUID: CGRect]
}

private final class NativeChatAttributes: UICollectionViewLayoutAttributes {
    var key: NativeChatRowKey?
    var measurementHostID: UUID?
    var session: UUID?
    var generation: UInt64 = 0
    override func copy(with zone: NSZone? = nil) -> Any {
        let result = super.copy(with: zone) as! NativeChatAttributes
        result.key = key; result.measurementHostID = measurementHostID
        result.session = session; result.generation = generation
        return result
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NativeChatAttributes else { return false }
        return key == other.key && measurementHostID == other.measurementHostID
            && session == other.session && generation == other.generation
            && super.isEqual(object)
    }
}

private final class NativeChatInvalidation: UICollectionViewLayoutInvalidationContext {
    var rows: [NativeChatRowKey]?
    var configuration: NativeChatLayoutConfiguration?
    var width: CGFloat?
    var viewportHeight: CGFloat?
    var measurement: (key: NativeChatRowKey, height: CGFloat, width: CGFloat, session: UUID, generation: UInt64, hostID: UUID)?
    var preservedID: UUID?
    var consumed = false
    var structural = false
    var bootstrapTarget: NativeChatScrollTarget?
    var mutationTarget: NativeChatScrollTarget?
}

private final class ReadingCollectionLayout: UICollectionViewLayout {
    private struct HeightEntry {
        var height: CGFloat
        var revision: AnyHashable
        var width: CGFloat
        var measured: Bool
        var hostID: UUID
    }
    private struct MeasurementHost {
        weak var cell: NativeChatCell?
        let id: UUID
    }
    private var measurementHosts: [UUID: MeasurementHost] = [:]
    private let session = UUID()
    private(set) var generation: UInt64 = 0
    private(set) var keys: [NativeChatRowKey]
    private(set) var configuration: NativeChatLayoutConfiguration
    private var indexByID: [UUID: Int] = [:]
    private var cache: [UUID: HeightEntry] = [:]
    private var heights = NativeChatHeightIndex()
    private(set) var width: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var batchAnchor: (operation: UUID, id: UUID)?
    #if DEBUG
    private let recordsBatchAdjustments = NativeReadingFixtures.requestedName != nil
    private(set) var batchAdjustments: [[String: Any]] = []
    #endif
    private(set) var applyingChange = false
    var externalViewportMotion: () -> Bool = { false }
    var semanticTarget: () -> NativeChatScrollTarget? = { nil }
    var streamMeasurementAdjustment: (UUID, CGFloat, Bool) -> CGFloat? = { _, _, _ in nil }
    var onInvalidated: () -> Void = {}

    init(keys: [NativeChatRowKey], configuration: NativeChatLayoutConfiguration) {
        self.keys = keys; self.configuration = configuration
        super.init()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func beginBatch(_ operation: UUID, preserving anchor: UUID?) {
        batchAnchor = anchor.map { (operation, $0) }
        #if DEBUG
        batchAdjustments.removeAll(keepingCapacity: true)
        #endif
    }
    func endBatch(_ operation: UUID) {
        if batchAnchor?.operation == operation { batchAnchor = nil }
    }
    override class var layoutAttributesClass: AnyClass { NativeChatAttributes.self }
    override class var invalidationContextClass: AnyClass { NativeChatInvalidation.self }
    private var rowsHeight: CGFloat { max(0, heights.total - (keys.isEmpty ? 0 : configuration.gap)) }
    private var naturalHeight: CGFloat { configuration.top + rowsHeight + configuration.bottom }
    // Keep the minimum and viewport in the same layout transaction. An outer
    // SwiftUI geometry update can otherwise shrink content before these bounds.
    var minimumHeight: CGFloat {
        max(0, viewportHeight - configuration.viewportInsets.bottom
            - (configuration.minimumIncludesTopInset ? 0 : configuration.viewportInsets.top))
    }
    private var shortTop: CGFloat {
        configuration.alignShortContentToBottom ? max(0, minimumHeight - naturalHeight) : 0
    }
    var spacerFrame: CGRect {
        CGRect(x: 0, y: configuration.top + shortTop + rowsHeight, width: width, height: configuration.bottom)
    }
    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: max(minimumHeight, naturalHeight))
    }
    private func estimate(_ key: NativeChatRowKey) -> CGFloat { cache[key.id]?.height ?? 240 }
    private func rebuild() {
        indexByID = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element.id, $0.offset) })
        heights.reset(keys.map { estimate($0) + configuration.gap })
    }
    private func hasCurrentHost(_ id: UUID, for key: NativeChatRowKey) -> Bool {
        guard let host = measurementHosts[key.id], host.id == id,
              let cell = host.cell else { return false }
        return cell.measurementHostID == id && cell.configuredKey == key
    }
    func isMeasured(_ key: NativeChatRowKey) -> Bool {
        guard let entry = cache[key.id] else { return false }
        return entry.measured && entry.revision == key.revision
            && abs(entry.width - width) < 0.01 && hasCurrentHost(entry.hostID, for: key)
    }
    func isMeasured(_ key: NativeChatRowKey, by hostID: UUID) -> Bool {
        isMeasured(key) && cache[key.id]?.hostID == hostID && hasCurrentHost(hostID, for: key)
    }
    /// A recreated SwiftUI host may reset local disclosure @State. Keep its old
    /// numeric height only as an estimate until this actual host measures it.
    func bindMeasurementHost(_ cell: NativeChatCell, key: NativeChatRowKey) {
        let id = cell.measurementHostID
        if measurementHosts[key.id]?.id != id {
            if var entry = cache[key.id] { entry.measured = false; cache[key.id] = entry }
        }
        measurementHosts[key.id] = MeasurementHost(cell: cell, id: id)
    }
    func retireMeasurementHost(_ id: UUID, key: NativeChatRowKey) {
        guard measurementHosts[key.id]?.id == id else { return }
        measurementHosts[key.id] = nil
        if var entry = cache[key.id], entry.hostID == id {
            entry.measured = false; cache[key.id] = entry
        }
    }
    override func prepare() {
        super.prepare()
        if width == 0, let collectionView, collectionView.bounds.width > 0 {
            width = collectionView.bounds.width; viewportHeight = collectionView.bounds.height
            rebuild()
        }
    }
    func frame(for id: UUID) -> CGRect? {
        guard let index = indexByID[id], heights.values.indices.contains(index) else { return nil }
        return CGRect(x: 0, y: configuration.top + shortTop + heights.prefix(index), width: width,
                      height: heights.values[index] - configuration.gap)
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard keys.indices.contains(indexPath.item), let frame = frame(for: keys[indexPath.item].id) else { return nil }
        let value = NativeChatAttributes(forCellWith: indexPath)
        value.key = keys[indexPath.item]; value.session = session; value.generation = generation
        value.frame = frame
        return value
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !keys.isEmpty else { return [] }
        var index = heights.index(containing: max(0, rect.minY - configuration.top - shortTop))
        var result: [UICollectionViewLayoutAttributes] = []
        while index < keys.count {
            guard let value = layoutAttributesForItem(at: IndexPath(item: index, section: 0)), value.frame.minY <= rect.maxY else { break }
            if value.frame.intersects(rect) { result.append(value) }
            index += 1
        }
        return result
    }
    func viewportAnchor(surviving: Set<UUID>? = nil) -> UUID? {
        guard !keys.isEmpty, let collectionView else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let bottom = collectionView.bounds.maxY - collectionView.adjustedContentInset.bottom
        var index = heights.index(containing: max(0, top - configuration.top - shortTop))
        if index + 1 < keys.count, let frame = frame(for: keys[index].id), frame.maxY <= top { index += 1 }
        var first: UUID?
        while index < keys.count, let frame = frame(for: keys[index].id), frame.minY < bottom {
            let key = keys[index]
            if frame.maxY > top, surviving?.contains(key.id) ?? true {
                if first == nil { first = key.id }
                if isMeasured(key) { return key.id }
            }
            index += 1
        }
        return first
    }
    func offset(for target: NativeChatScrollTarget, height: CGFloat? = nil, viewport: CGFloat? = nil) -> CGFloat? {
        guard let collectionView else { return nil }
        let insets = collectionView.adjustedContentInset
        let viewport = viewport ?? collectionView.bounds.height
        let minY = -insets.top
        let maxY = max(minY, (height ?? collectionViewContentSize.height) - viewport + insets.bottom)
        switch target {
        case .top: return minY
        case .bottom: return maxY
        case let .rowBottom(id, bottomY):
            guard let frame = frame(for: id), bottomY.isFinite else { return nil }
            return min(maxY, max(minY, frame.maxY - bottomY))
        case let .rowTop(id, topY):
            guard let frame = frame(for: id), topY.isFinite else { return nil }
            return min(maxY, max(minY, frame.minY - topY))
        case let .row(id, anchor):
            guard let frame = frame(for: id) else { return nil }
            let a = min(1, max(0, anchor.y))
            let result = frame.minY + frame.height * a - insets.top - max(0, viewport - insets.top - insets.bottom) * a
            return min(maxY, max(minY, result))
        }
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        width > 0 && (abs(newBounds.width - width) > 0.01 || abs(newBounds.height - viewportHeight) > 0.01)
    }
    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds) as! NativeChatInvalidation
        if abs(newBounds.width - width) > 0.01 { context.width = newBounds.width }
        if abs(newBounds.height - viewportHeight) > 0.01 { context.viewportHeight = newBounds.height }
        context.preservedID = viewportAnchor()
        return context
    }
    private func valid(_ attributes: NativeChatAttributes) -> Bool {
        guard let key = attributes.key, let index = indexByID[key.id] else { return false }
        return attributes.session == session && attributes.generation == generation && keys[index] == key
            && abs(attributes.size.width - width) < 0.01
    }
    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        guard let original = original as? NativeChatAttributes, let preferred = preferred as? NativeChatAttributes,
              valid(original), valid(preferred), preferred.key == original.key, let key = original.key,
              let hostID = preferred.measurementHostID, hasCurrentHost(hostID, for: key),
              preferred.size.height.isFinite, preferred.size.height > 0 else { return false }
        return !isMeasured(key) || abs(estimate(key) - preferred.size.height) > 0.5
    }
    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original) as! NativeChatInvalidation
        guard let original = original as? NativeChatAttributes, let preferred = preferred as? NativeChatAttributes,
              valid(original), valid(preferred), original.key == preferred.key, let key = original.key,
              let hostID = preferred.measurementHostID, hasCurrentHost(hostID, for: key) else { return context }
        context.measurement = (key, preferred.size.height, width, session, generation, hostID)
        context.preservedID = viewportAnchor()
        return context
    }
    override func invalidateLayout(with raw: UICollectionViewLayoutInvalidationContext) {
        #if DEBUG
        let probeStart = ComposerLayoutWorkProbe.beginScope()
        defer { ComposerLayoutWorkProbe.endScope("layout", start: probeStart) }
        #endif
        guard let context = raw as? NativeChatInvalidation else { super.invalidateLayout(with: raw); return }
        let wasApplying = applyingChange; applyingChange = true
        defer { applyingChange = wasApplying }
        let oldHeight = collectionViewContentSize.height
        #if DEBUG
        let oldOffset = collectionView?.contentOffset.y ?? 0
        #endif
        let oldViewport = viewportHeight
        let oldRowOrigin = configuration.top + shortTop
        // UIKit can measure incoming cells before it commits the structural
        // offset adjustment. Keep that batch's surviving anchor through those
        // measurements; choosing from the half-updated viewport can select a
        // newly inserted row and lose part of the same atomic adjustment.
        let anchor = batchAnchor?.id ?? context.preservedID ?? viewportAnchor()
        let oldY = anchor.flatMap { frame(for: $0)?.minY }
        let target = semanticTarget()
        let oldTargetOffset = target.flatMap { offset(for: $0, height: oldHeight, viewport: oldViewport) }
        var changedFrom: Int?
        var changedMetrics = false
        var measuredContentChanged = false
        var needsIndexRebuild = false
        let absoluteTarget = context.bootstrapTarget ?? context.mutationTarget
        let owned = context.rows != nil || context.width != nil || context.viewportHeight != nil
            || context.measurement != nil || context.configuration != nil || absoluteTarget != nil
        if !context.consumed {
            context.consumed = true
            if let rows = context.rows {
                // The controller already compared the ordered row identities.
                // Content revisions keep the same indices and height estimates;
                // their accepted measurements update the existing height tree.
                if context.structural {
                    let surviving = Set(rows.map(\.id))
                    cache = cache.filter { surviving.contains($0.key) }
                    measurementHosts = measurementHosts.filter { surviving.contains($0.key) }
                    generation &+= 1
                    needsIndexRebuild = true
                }
                for key in rows where cache[key.id]?.revision != key.revision {
                    if var entry = cache[key.id] { entry.measured = false; entry.revision = key.revision; cache[key.id] = entry }
                }
                keys = rows; changedFrom = 0
            }
            if let newWidth = context.width, newWidth.isFinite, newWidth > 0, abs(newWidth - width) > 0.01 {
                width = newWidth; generation &+= 1
                cache = cache.mapValues { var value = $0; value.measured = false; return value }
                changedFrom = 0
                needsIndexRebuild = true
            }
            if let configuration = context.configuration, configuration != self.configuration {
                // The height index contains only row estimates plus inter-row
                // gaps. Composer/footer and viewport-only changes affect the
                // outer geometry, not those entries or the ID-to-index map.
                let gapChanged = configuration.gap != self.configuration.gap
                self.configuration = configuration; changedMetrics = true
                if gapChanged { changedFrom = 0 }
                #if DEBUG
                if ComposerLayoutWorkProbe.legacy { changedFrom = 0 }
                #endif
                needsIndexRebuild = needsIndexRebuild || gapChanged
            }
            if needsIndexRebuild { rebuild() }
            if let sample = context.measurement,
               sample.session == session, sample.generation == generation,
               abs(sample.width - width) < 0.01,
               let index = indexByID[sample.key.id], keys[index] == sample.key,
               hasCurrentHost(sample.hostID, for: sample.key),
               sample.height.isFinite, sample.height > 0,
               !isMeasured(sample.key) || abs(estimate(sample.key) - sample.height) > 0.5 {
                cache[sample.key.id] = HeightEntry(height: sample.height, revision: sample.key.revision, width: width, measured: true, hostID: sample.hostID)
                heights.replace(index, sample.height + configuration.gap)
                changedFrom = min(changedFrom ?? index, index)
                measuredContentChanged = true
            }
            if let height = context.viewportHeight, height.isFinite, height > 0 {
                changedMetrics = changedMetrics || abs(height - viewportHeight) > 0.01
                viewportHeight = height
            }
        }
        // Footer/minimum-height changes need new content metrics, but unchanged
        // message frames do not need item invalidation. Short bottom alignment
        // is the exception: a footer, viewport or measurement can move every
        // row, including rows preceding the measured one.
        if configuration.top + shortTop != oldRowOrigin { changedFrom = 0 }
        if changedFrom != nil || changedMetrics || absoluteTarget != nil {
            let newHeight = collectionViewContentSize.height
            var delta: CGFloat = 0
            // The ordinary keyboard owner sees geometry after this layout pass.
            // Never preempt it on a viewport resize, even before its animation
            // flag can be set. Footer/minimum-height-only updates are also its
            // metrics, not message growth. Explicit bootstrap/mutation targets
            // are admitted separately from ordinary viewport changes.
            let mayMove = absoluteTarget != nil
                || (context.viewportHeight == nil && (context.structural || measuredContentChanged))
            if mayMove && (!externalViewportMotion() || context.structural) {
                if let absoluteTarget, let desired = offset(for: absoluteTarget), let collectionView {
                    delta = desired - collectionView.contentOffset.y
                } else if let target, let oldTargetOffset, let next = offset(for: target) {
                    delta = next - oldTargetOffset
                } else {
                    let newY = anchor.flatMap { frame(for: $0)?.minY }
                    delta = (newY ?? oldY ?? 0) - (oldY ?? newY ?? 0)
                }
            }
            if absoluteTarget == nil, !context.structural, context.viewportHeight == nil,
               context.width == nil, !changedMetrics, measuredContentChanged, abs(newHeight - oldHeight) > 0.5,
               case .bottom? = target, let sample = context.measurement,
               let destination = offset(for: .bottom),
               let adjustment = streamMeasurementAdjustment(
                    sample.key.id, destination,
                    measurementHosts[sample.key.id]?.cell?.prefersStableStreamingBottom == true) {
                delta = adjustment
            }
            context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
            context.contentSizeAdjustment = CGSize(width: 0, height: newHeight - oldHeight)
            if let changedFrom, !context.structural {
                context.invalidateItems(at: (changedFrom..<keys.count).map { IndexPath(item: $0, section: 0) })
            }
        } else if owned {
            context.contentOffsetAdjustment = .zero; context.contentSizeAdjustment = .zero
        }
        #if DEBUG
        ComposerLayoutWorkProbe.items(context.invalidatedItemIndexPaths?.count ?? 0)
        if !keys.isEmpty, context.invalidatedItemIndexPaths?.count == keys.count {
            ComposerLayoutWorkProbe.hit("layout.fullItemInvalidation")
        }
        #endif
        super.invalidateLayout(with: context)
        #if DEBUG
        if recordsBatchAdjustments, let batchAnchor, batchAdjustments.count < 48 {
            batchAdjustments.append([
                "operation": batchAnchor.operation.uuidString,
                "anchorID": batchAnchor.id.uuidString,
                "structural": context.structural,
                "measurementID": context.measurement?.key.id.uuidString ?? "",
                "oldAnchorDocumentY": oldY ?? 0,
                "newAnchorDocumentY": frame(for: batchAnchor.id)?.minY ?? 0,
                "oldOffsetY": oldOffset,
                "offsetYAfterInvalidation": collectionView?.contentOffset.y ?? 0,
                "adjustmentY": context.contentOffsetAdjustment.y,
                "oldContentHeight": oldHeight,
                "newContentHeight": collectionViewContentSize.height
            ])
        }
        #endif
        if owned { onInvalidated() }
    }
}

private struct NativeChatTextPlacement: Equatable {
    let key: NativeChatRowKey
    let publication: AnyHashable
    let hostID: UUID
    let cellFrame: CGRect
    let messageFrame: CGRect
}

private final class NativeChatCell: UICollectionViewCell {
    // The transcript applies viewport safe-area clearance through contentInset.
    // A row's intrinsic height must not change as it crosses that viewport edge.
    override var safeAreaInsets: UIEdgeInsets { .zero }

    var isViewportMotionActive: () -> Bool = { false }
    override func action(for layer: CALayer, forKey event: String) -> CAAction? {
        // Reappearing cells can inherit the keyboard's animation and animate
        // their own position/alpha in addition to the collection's scroll.
        // During viewport motion only the parent moves the row; hosted content
        // keeps its own animations, including the user's send animation.
        if layer === self.layer, isViewportMotionActive(),
           event == "position" || event == "bounds" || event == "opacity" {
            return NSNull()
        }
        return super.action(for: layer, forKey: event)
    }

    var sendOffset: CGFloat?
    var didResolveSendOffset = false
    var prefersStableStreamingBottom = false
    var configuredKey: NativeChatRowKey?
    var configuredPublication: AnyHashable?
    var messageLocalFrame: CGRect?
    var textFramePublication: AnyHashable?
    var refreshedTextPlacement: NativeChatTextPlacement?
    private(set) var measurementHostID = UUID()
    private var probeIntrinsicGeneration = 0
    private var probeLastFit: (key: NativeChatRowKey, width: CGFloat, height: CGFloat, intrinsic: Int)?

    var disclosureMotionID: UUID?
    var isDisclosureHostCurrent: () -> Bool = { false }
    var onRetireMeasurementHost: ((UUID, NativeChatRowKey) -> Void)?
    func prepareHost(for key: NativeChatRowKey) {
        guard let previous = configuredKey, previous.id != key.id else { return }
        onRetireMeasurementHost?(measurementHostID, previous)
        disclosureMotionID = nil
        sendOffset = nil
        didResolveSendOffset = false
        measurementHostID = UUID()
        prefersStableStreamingBottom = false
        textFramePublication = nil
        refreshedTextPlacement = nil
    }
    override func prepareForReuse() {
        disclosureMotionID = nil
        sendOffset = nil
        didResolveSendOffset = false
        if let key = configuredKey { onRetireMeasurementHost?(measurementHostID, key) }
        measurementHostID = UUID()
        prefersStableStreamingBottom = false
        configuredKey = nil; configuredPublication = nil; messageLocalFrame = nil
        textFramePublication = nil; refreshedTextPlacement = nil
        super.prepareForReuse()
    }
    override func invalidateIntrinsicContentSize() {
        if StreamLayoutWorkProbe.enabled { probeIntrinsicGeneration += 1; StreamLayoutWorkProbe.hit("cell.intrinsicInvalidation") }
        if disclosureMotionID != nil, isDisclosureHostCurrent() {
            super.invalidateIntrinsicContentSize()
        } else {
            disclosureMotionID = nil
            UIView.performWithoutAnimation { super.invalidateIntrinsicContentSize() }
        }
    }
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        #if DEBUG
        ComposerLayoutWorkProbe.hit("cell.fit")
        #endif
        guard let attributes = attributes as? NativeChatAttributes else { return super.preferredLayoutAttributesFitting(attributes) }
        let result = attributes.copy() as! NativeChatAttributes
        guard configuredKey == attributes.key, attributes.size.width.isFinite, attributes.size.width > 0 else {
            result.key = nil // Do not label a different host's height as this revision.
            return result
        }
        StreamLayoutWorkProbe.hit("cell.fit")
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if StreamLayoutWorkProbe.enabled, let key = configuredKey {
            if let prior = probeLastFit, prior.key == key, prior.width == attributes.size.width {
                StreamLayoutWorkProbe.hit("cell.fit.sameKeyWidth")
                StreamLayoutWorkProbe.hit(abs(prior.height - size.height) <= 0.5
                    ? "cell.fit.sameKeyWidth.sameHeight" : "cell.fit.sameKeyWidth.changedHeight")
                if prior.intrinsic == probeIntrinsicGeneration {
                    StreamLayoutWorkProbe.hit("cell.fit.noIntrinsicInvalidation")
                    if abs(prior.height - size.height) > 0.5 { StreamLayoutWorkProbe.hit("cell.fit.changedHeightWithoutIntrinsicInvalidation") }
                }
            }
            probeLastFit = (key, attributes.size.width, size.height, probeIntrinsicGeneration)
        }
        if size.height.isFinite, size.height > 0 {
            result.size.height = size.height
            result.measurementHostID = measurementHostID
        }
        return result
    }
}

/// Observe down/up even before UIScrollView starts dragging. This recognizer
/// never prevents, delays or cancels delivery to the pan, selection or controls.
private final class NativeChatTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var down: () -> Void = {}
    var up: () -> Void = {}
    private var active: Set<UITouch> = []
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let first = active.isEmpty; active.formUnion(touches)
        if first { down(); state = .began } else { state = .changed }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        active.subtract(touches)
        if active.isEmpty { up(); state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        active.removeAll(); up(); state = .cancelled
    }
    override func reset() { super.reset(); active.removeAll() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

#if DEBUG
@MainActor
private enum NativeChatLifecycleDiagnostics {
    private static let enabled = NativeReadingFixtures.requestedName != nil
        || ProcessInfo.processInfo.arguments.contains("-nativeChatLifecycleDiagnostics")
    private static var count = 0
    static func emit(_ message: @autoclosure () -> String) {
        guard enabled, count < 160 else { return }
        count += 1
        print("NATIVE_CHAT_LIFECYCLE seq=\(count) " + message())
    }
}
#endif

// UIKit can retain pending SwiftUI transactions after dismantling the controller.
// End this content's lifetime at its root so those transactions cannot rebuild
// the outgoing message subtree while the next conversation is mounting.
@MainActor
@Observable
private final class NativeChatHostedContentLifetime {
    var isActive = true
}

private struct NativeChatHostedContent: View {
    let lifetime: NativeChatHostedContentLifetime
    let content: AnyView

    var body: some View {
        if lifetime.isActive { content }
    }
}

@MainActor
final class NativeChatTranscriptController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    fileprivate let collection: NativeChatCollectionView
    fileprivate var hasActiveScrollCommand: Bool { command != nil }
    private let layout: ReadingCollectionLayout
    private var input: NativeChatTranscript
    private var rows: [NativeChatRow]
    private var rowByID: [UUID: NativeChatRow]
    private var pendingInput: NativeChatTranscript?
    private var batchID: UUID?
    private var visible = false
    private var detached = false
    private let hostedContentLifetime = NativeChatHostedContentLifetime()
    private var bootstrapped = false
    private var attachmentActivated = false
    private var attachmentReady = false
    private var attachmentTask: Task<Void, Never>?
    private var touching = false
    private var userGesture = false
    private var previousOffset: CGFloat = 0
    private var emissionScheduled = false
    private var needsTextCoverageCheck = false
    private var refreshingTextCoverage = false
    private var pendingCodeFrames: [UUID: CGRect] = [:]
    private var scheduledPage: Task<Void, Never>?
    private var requestedPagePublication: AnyHashable?
    private var animator: UIViewPropertyAnimator?
    private var nativeAnimatedCommandID: UUID?
    private var command: (id: UUID, target: NativeChatScrollTarget, completion: (Bool) -> Void, animationFinished: Bool)?
    #if DEBUG
    private var lastBatch: [String: Any]?
    private var sendOriginEvents: [[String: Any]] = []
    private var eventSequence: UInt64 = 0
    private var droppedEventCount = 0
    private var didLogFirstLayout = false

    fileprivate func debugLifecycle(_ event: String, next: NativeChatTranscript? = nil,
                                    detail: String = "") {
        func identity(_ value: AnyObject?) -> String {
            value.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        }
        func window(_ value: NativeChatDebugWindow?) -> String {
            value.map { "\($0.start):\($0.end)/\($0.total)" } ?? "nil"
        }
        NativeChatLifecycleDiagnostics.emit(
            "event=\(event) self=\(identity(self)) driver=\(identity(input.driver))"
                + " owner=\(identity(input.driver.controller)) session=\(input.sessionID)"
                + " debugWindow=\(window(input.debugWindow)) loaded=\(isViewLoaded)"
                + " detached=\(detached) bootstrapped=\(bootstrapped) initialBottom=\(input.initialBottom)"
                + " initialPending=\(input.driver.initialBottomPositionPending)"
                + " followsBottom=\(input.driver.followBottomContentChanges)"
                + " width=\(collection.bounds.width) height=\(collection.bounds.height)"
                + " offsetY=\(collection.contentOffset.y)"
                + " nextDriver=\(identity(next?.driver)) nextOwner=\(identity(next?.driver.controller))"
                + " nextSession=\(next.map { String(describing: $0.sessionID) } ?? "nil")"
                + " nextDebugWindow=\(window(next?.debugWindow)) \(detail)"
        )
    }
    #endif

    init(input: NativeChatTranscript) {
        var initial = input
        // A new controller cannot inherit an edit accepted by an old one.
        initial.mutationLanding = nil
        self.input = initial; rows = input.rows
        rowByID = Dictionary(input.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        layout = ReadingCollectionLayout(keys: input.rows.map { .init(id: $0.id, revision: $0.revision) }, configuration: input.configuration)
        collection = NativeChatCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        layout.externalViewportMotion = { [weak self] in self.map { $0.input.driver.controller !== $0 || $0.input.driver.externalViewportMotion } ?? true }
        layout.semanticTarget = { [weak self] in
            guard let self, self.input.driver.controller === self else { return nil }
            if self.input.driver.externalViewportMotion { return nil }
            if let landing = self.input.mutationLanding,
               landing.isCurrent(),
               landing.destinationPublicationID == self.input.publicationID,
               landing.scrollViewIdentity == ObjectIdentifier(self.collection),
               self.command == nil, !self.touching, !self.userGesture,
               !self.collection.isTracking, !self.collection.isDragging,
               !self.collection.isDecelerating {
                // The accepted structural target also owns its self-sizing
                // measurements until Root acknowledges completion (or takes
                // over deletion). No surviving row may steal the edit's edge.
                return landing.target
            }
            if self.input.driver.followBottomContentChanges {
                // The incoming rows and their send owner arrive together.
                // Do not let a retained idle bottom pin consume estimated
                // append heights before Root's send handoff has run. Explicit
                // commands keep their UUID and their own measured target.
                if self.input.holdsAutomaticBottomFollow,
                   self.input.driver.positionCommandID == nil { return nil }
                return .bottom
            }
            return self.input.driver.target
        }
        layout.streamMeasurementAdjustment = { [weak self] tail, destination, stableBottom in
            self?.prepareStreamMeasurement(tail: tail, destination: destination, stableBottom: stableBottom)
        }
        layout.onInvalidated = { [weak self] in
            self?.needsTextCoverageCheck = true
            self?.scheduleEmission()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; collection.backgroundColor = .clear
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset = input.configuration.viewportInsets
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .interactive
        collection.selfSizingInvalidation = .enabledIncludingConstraints
        if #available(iOS 26.0, *) {
            collection.topEdgeEffect.style = .soft
        }
        collection.dataSource = self; collection.delegate = self
        collection.onContentLayoutCompleted = { [weak self] in
            guard let self, self.needsTextCoverageCheck else { return }
            self.scheduleEmission()
        }
        collection.onViewportLayout = { [weak self] previous, current, presentedOffset in
            guard let self, !self.detached, self.attachmentReady,
                  self.input.driver.controller === self else { return }
            self.input.driver.viewportLayoutEvents.send(.init(
                scrollView: self.collection, publicationID: self.input.publicationID,
                sessionID: self.input.sessionID, previous: previous, current: current,
                presentedOffsetBeforeLayout: presentedOffset))
            self.updateStreamMotion(previous: previous, current: current, presented: presentedOffset)
        }
        collection.register(NativeChatCell.self, forCellWithReuseIdentifier: "native-chat")
        collection.accessibilityIdentifier = "nativeChat.transcript"
        collection.onSelectionAutoscrollBegan = { [weak self] in
            guard let self, !self.detached, self.input.driver.controller === self else { return }
            self.cancelHostedDisclosureMotions()
            self.input.mutationLanding = nil
            self.input.driver.releasePosition(userOwned: true)
            self.refreshPhase()
        }
        collection.onSelectionAutoscrollEnded = { [weak self] in self?.refreshPhase() }
        view.addSubview(collection)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.topAnchor.constraint(equalTo: view.topAnchor), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let touch = NativeChatTouchObserver(target: nil, action: nil)
        touch.down = { [weak self] in
            guard let self, self.input.driver.controller === self else { return }
            self.input.mutationLanding = nil
            self.touching = true
            // A touch cancels an active scroll immediately. A plain tap (such
            // as keyboard dismissal) does not take over the reading position;
            // the actual pan delegate and stream pause retain that ownership.
            if self.command != nil { self.input.driver.releasePosition(userOwned: true) }
            self.refreshPhase()
        }
        touch.up = { [weak self] in self?.touching = false; self?.refreshPhase() }
        collection.addGestureRecognizer(touch)
    }

    private func activateMountedAttachment() {
        // SwiftUI may load a temporary controller only to measure the view.
        // It must never replace the mounted surface's shared driver binding.
        // Activation is one-shot so an outgoing surface cannot reclaim it.
        guard !detached, !attachmentActivated, viewIfLoaded?.window != nil else { return }
        attachmentActivated = true
        #if DEBUG
        debugLifecycle("mounted.beforeAttach")
        #endif
        input.driver.attach(self)
        #if DEBUG
        debugLifecycle("mounted.afterAttach")
        #endif
        attachmentTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, !self.detached,
                  self.input.driver.controller === self else { return }
            #if DEBUG
            FullMotionProbe.shared.tailFrame = { [weak self] in
                guard let self, let tail = self.rows.last(where: \.isMessage) else { return nil }
                return self.layout.frame(for: tail.id)
            }
            if StreamOcclusionProbe.enabled {
                FullMotionProbe.shared.occlusionState = { [weak self] in
                    guard let self, let tail = self.rows.last(where: \.isMessage),
                          let frame = self.layout.frame(for: tail.id) else { return [:] }
                    let scroll = self.collection
                    let shown = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
                    let origin = scroll.convert(scroll.bounds.origin, to: nil)
                    let composer = StreamOcclusionProbe.composerFrame
                    let tailEnd = origin.y + frame.maxY - shown
                    return ["wallTime": Date().timeIntervalSince1970,
                            "composerTop": composer.minY, "composerHeight": composer.height,
                            "viewportTop": origin.y, "tailEndWindow": tailEnd,
                            "tailOverComposer": max(0, tailEnd - composer.minY),
                            "paddingBottom": self.input.configuration.bottom,
                            "bottomTarget": self.layout.offset(for: .bottom) ?? -999,
                            "tailMeasured": self.layout.isMeasured(.init(id: tail.id, revision: tail.revision)),
                            "bottomPinned": self.input.driver.positionIsBottomPinned,
                            "externalMotion": self.input.driver.externalViewportMotion,
                            "commandActive": self.command != nil,
                            "holdsFollow": self.input.holdsAutomaticBottomFollow,
                            "disclosureActive": self.input.disclosureOperation != nil,
                            "pendingDestination": self.pendingStreamDestination ?? -999]
                }
            }
            FullMotionProbe.attach(self.collection)
            #endif
            self.input.onAttach(self.collection)
            self.attachmentReady = true
            self.attachmentTask = nil
            self.scheduleEmission()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        activateMountedAttachment()
        #if DEBUG
        if !didLogFirstLayout {
            didLogFirstLayout = true
            debugLifecycle("firstLayout")
        }
        #endif
        bootstrapMountedPositionIfNeeded()
        scheduleEmission()
    }
    private func bootstrapMountedPositionIfNeeded() {
        if !bootstrapped, attachmentActivated, input.driver.controller === self,
           collection.bounds.width > 0, collection.bounds.height > 0 {
            bootstrapped = true
            // A business command or touch may win ownership before first layout.
            // Bootstrap must not reclaim the position from that newer owner.
            let ownsBootstrap = input.driver.controller === self
                && input.driver.beginInitialBottomPositioning(enabled: input.initialBottom)
            #if DEBUG
            debugLifecycle("bootstrapDecision", detail: "ownsBootstrap=\(ownsBootstrap)")
            #endif
            collection.layoutIfNeeded() // Initial bootstrap only, never paging/content updates.
            if ownsBootstrap {
                let context = NativeChatInvalidation()
                context.bootstrapTarget = input.initialBottom ? .bottom : .top
                layout.invalidateLayout(with: context)
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        activateMountedAttachment()
        bootstrapMountedPositionIfNeeded()
        scheduleEmission()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); visible = false
        DrawerTextSelectionInteractionGate.cancelAutoscroll(in: collection)
        input.mutationLanding = nil
        scheduledPage?.cancel(); scheduledPage = nil
    }
    func detach() {
        #if DEBUG
        debugLifecycle("detach.before")
        #endif
        guard !detached else { return }
        detached = true; visible = false
        DrawerTextSelectionInteractionGate.cancelAutoscroll(in: collection)
        cancelHostedDisclosureMotions()
        collection.onViewportLayout = nil
        collection.onContentLayoutCompleted = nil
        needsTextCoverageCheck = false
        attachmentTask?.cancel(); attachmentTask = nil; attachmentReady = false
        scheduledPage?.cancel(); scheduledPage = nil; pendingInput = nil
        cancelCommand(reason: "detached")
        input.driver.detach(self)
        hostedContentLifetime.isActive = false
        #if DEBUG
        debugLifecycle("detach.after")
        #endif
        let onDetach = input.onDetach, scrollView = collection
        Task { @MainActor in await Task.yield(); onDetach(scrollView) }
    }

    func update(_ next: NativeChatTranscript) {
        #if DEBUG
        let probeStart = ComposerLayoutWorkProbe.beginScope()
        defer { ComposerLayoutWorkProbe.endScope("controller", start: probeStart) }
        #endif
        #if DEBUG
        if input.driver !== next.driver || input.driver.controller !== self
            || next.driver.controller !== self {
            debugLifecycle("update.ownerMismatch", next: next,
                           detail: "driverChanged=\(input.driver !== next.driver)")
        }
        #endif
        guard !detached else { return }
        // A conversation's surface is keyed by its session in RootView. Refuse
        // to apply stale/new-session rows to this outgoing controller.
        guard next.sessionID == input.sessionID else { return }
        let newIDs = next.rows.map(\.id), newSet = Set(newIDs)
        guard newSet.count == newIDs.count else { return }
        if batchID != nil { pendingInput = next; return }
        let oldRows = rows
        let oldIDs = oldRows.map(\.id)
        let oldSet = Set(oldIDs)
        let structural = oldIDs != newIDs
        if structural || next.disclosureOperation != nil {
            stopStreamMotion(reason: "input-owner-change", preserveVisible: false)
        }
        let changed = Set(next.rows.compactMap { row -> UUID? in
            rowByID[row.id]?.revision == row.revision ? nil : row.id
        })
        let contextChanged = next.publicationID != input.publicationID
        let metricsChanged = next.configuration != input.configuration
        var unchangedConfiguration = next.configuration
        unchangedConfiguration.bottom = input.configuration.bottom
        unchangedConfiguration.bottomFollowClearance = input.configuration.bottomFollowClearance
        let followsComposerHeight = next.composerHeightPresentation != nil && metricsChanged
            && unchangedConfiguration == input.configuration
            && !structural && changed.isEmpty && !contextChanged
            && next.streamingTailID == nil && !next.holdsAutomaticBottomFollow
            && command == nil && input.driver.positionCommandID == nil
            && input.driver.positionIsBottomPinned && !input.driver.positionIsUserOwned
            && !input.driver.initialBottomPositionPending && !input.driver.hasActiveScrollCommand
            && !touching && !userGesture && !collection.isTracking
            && !collection.isDragging && !collection.isDecelerating && collection.window != nil
        StreamLayoutWorkProbe.hit(structural || !changed.isEmpty || contextChanged || metricsChanged ? "controller.changedInput" : "controller.unchangedInput")
        let anchor = layout.viewportAnchor(surviving: newSet)
        let mutationLanding = next.mutationLanding.flatMap { landing -> NativeChatMutationLanding? in
            guard structural, landing.isCurrent(), landing.sourcePublicationID == input.publicationID,
                  landing.destinationPublicationID == next.publicationID,
                  landing.scrollViewIdentity == ObjectIdentifier(collection),
                  input.driver === next.driver, input.driver.controller === self,
                  oldSet.contains(landing.removedID), !newSet.contains(landing.removedID),
                  oldSet.contains(landing.targetID) != landing.isReplacement,
                  newSet.contains(landing.targetID),
                  command == nil, !input.driver.externalViewportMotion,
                  !touching, !userGesture, !collection.isTracking,
                  !collection.isDragging, !collection.isDecelerating else { return nil }
            return landing
        }
        let continuingMutationLanding = next.mutationLanding.flatMap { landing -> NativeChatMutationLanding? in
            guard !structural, let accepted = input.mutationLanding,
                  accepted.isCurrent(), landing.isCurrent(),
                  landing.requestID == accepted.requestID,
                  landing.targetID == accepted.targetID,
                  landing.destinationPublicationID == accepted.destinationPublicationID,
                  next.publicationID == accepted.destinationPublicationID,
                  input.driver === next.driver, input.driver.controller === self,
                  !input.driver.externalViewportMotion,
                  command == nil, !touching, !userGesture,
                  !collection.isTracking, !collection.isDragging,
                  !collection.isDecelerating else { return nil }
            return accepted
        }
        if let hint = next.mutationLanding, hint.isReplacement,
           mutationLanding == nil, continuingMutationLanding == nil {
            // A coalesced publication or a new gesture can supersede admission.
            // Keep the model edit, but never strand its outer positioning lease.
            Task { @MainActor in
                if hint.isCurrent() { hint.onRejected() }
            }
        }
        #if DEBUG
        let oldAnchorFrame = anchor.flatMap { layout.frame(for: $0) }
        let oldOffset = collection.contentOffset.y
        #endif
        #if DEBUG
        if structural || !changed.isEmpty || contextChanged || metricsChanged {
            recordEvent("inputWillUpdate", extra: [
                "incomingPublication": String(describing: next.publicationID),
                "incomingRowIDs": next.rows.filter(\.isMessage).map { $0.id.uuidString },
                "structural": structural
            ])
        }
        #endif
        #if DEBUG
        FullMotionProbe.shared.streaming = next.streamingTailID != nil
        FullMotionCostProbe.input(next.streamingTailID)
        #endif
        input = next
        // Never adopt an unvalidated hint from a later update. Removal of the
        // same Root request, publication change, touch or another command ends
        // this ownership without a timer or an independently retained task.
        input.mutationLanding = mutationLanding ?? continuingMutationLanding
        if requestedPagePublication != next.publicationID { requestedPagePublication = nil }
        guard structural || !changed.isEmpty || contextChanged || metricsChanged else { return }
        let context = NativeChatInvalidation()
        // Ordered IDs and revisions have already been checked above. A frame
        // that only changes bottom spacing must not resend the identical keys
        // through the layout's per-row cache reconciliation.
        if structural || !changed.isEmpty || contextChanged {
            context.rows = next.rows.map { .init(id: $0.id, revision: $0.revision) }
        }
        context.configuration = next.configuration
        context.structural = structural; context.preservedID = anchor
        context.mutationTarget = mutationLanding?.target
        let applyData = {
            self.rows = next.rows
            self.rowByID = Dictionary(next.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        }
        if structural {
            let operation = UUID(); batchID = operation
            layout.beginBatch(operation, preserving: anchor)
            // Normal transcript edits preserve common-ID order. A rare reorder
            // is expressed as delete+insert for those rows, with ID-keyed cache.
            let sameOrder = oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains)
            // A surviving row can change height when its role changes from
            // the tail to an earlier message. Install that same revision in
            // the insertion transaction, not in the later batch completion.
            // Match by identity: UIKit's existing index paths still describe
            // the old snapshot until it commits the structural update.
            let survivingCells = sameOrder ? collection.visibleCells.compactMap {
                ($0 as? NativeChatCell).flatMap { cell in
                    cell.configuredKey.map { (cell, $0.id) }
                }
            } : []
            let deletes = oldIDs.enumerated().compactMap { index, id in (!newSet.contains(id) || !sameOrder) ? IndexPath(item: index, section: 0) : nil }
            let inserts = newIDs.enumerated().compactMap { index, id in (!oldSet.contains(id) || !sameOrder) ? IndexPath(item: index, section: 0) : nil }
            UIView.performWithoutAnimation {
                collection.performBatchUpdates {
                    applyData()
                    for (cell, id) in survivingCells {
                        if let row = self.rowByID[id],
                           changed.contains(id) || contextChanged {
                            self.configure(cell, row: row)
                        }
                    }
                    self.collection.deleteItems(at: deletes)
                    self.collection.insertItems(at: inserts)
                    self.layout.invalidateLayout(with: context)
                } completion: { [weak self] _ in
                    guard let self, self.batchID == operation, !self.detached else { return }
                    self.refreshVisibleCells()
                    self.layout.endBatch(operation)
                    self.batchID = nil
                    #if DEBUG
                    var evidence: [String: Any] = ["structural": true, "batchID": operation.uuidString]
                    if let mutationLanding {
                        evidence["mutationLandingRequestID"] = mutationLanding.requestID.uuidString
                        evidence["mutationLandingTargetID"] = mutationLanding.targetID.uuidString
                    }
                    self.recordEvent("inputDidUpdate", extra: evidence)
                    #endif
                    self.scheduleEmission()
                    if let pending = self.pendingInput { self.pendingInput = nil; self.update(pending) }
                }
            }
            #if DEBUG
            lastBatch = ["token": operation.uuidString, "anchorID": anchor?.uuidString ?? "", "oldOffsetY": oldOffset,
                         "coordinates": "layout-host-viewport", "stage": "batch-returned",
                         "tracking": collection.isTracking, "dragging": collection.isDragging, "decelerating": collection.isDecelerating]
            if let oldAnchorFrame { lastBatch?["oldAnchorY"] = oldAnchorFrame.minY - oldOffset }
            if let anchor, let frame = layout.frame(for: anchor) { lastBatch?["newAnchorY"] = frame.minY - collection.contentOffset.y }
            lastBatch?["layoutAdjustments"] = layout.batchAdjustments
            #endif
        } else {
            UIView.performWithoutAnimation {
                applyData()
                layout.invalidateLayout(with: context)
                // Metrics do not change a host's content key or publication.
                // Newly exposed/reused cells are still configured by UIKit's
                // data-source callback using the freshly installed rows.
                var refreshContent = !changed.isEmpty || contextChanged
                #if DEBUG
                refreshContent = refreshContent || ComposerLayoutWorkProbe.legacy
                #endif
                if refreshContent { refreshVisibleCells() }
            }
            #if DEBUG
            recordEvent("inputDidUpdate", extra: ["structural": false])
            #endif
        }
        // Viewport changes belong to the existing keyboard animator, outside
        // the atomic message-update block that disables content animations.
        // Use current input in case a batch completion admitted a newer update.
        if collection.contentInset != input.configuration.viewportInsets {
            collection.contentInset = input.configuration.viewportInsets
        }
        if followsComposerHeight {
            // This is already the shared animation's current frame. Apply it
            // atomically with the footer; a second UIKit animation drifts from
            // the SwiftUI shell when the full page takes longer to render.
            UIView.performWithoutAnimation {
                collection.layoutIfNeeded()
                if let destination = layout.offset(for: .bottom) {
                    collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: destination), animated: false)
                }
            }
        }
        scheduleEmission()
    }

    private func refreshVisibleCells() {
        #if DEBUG
        ComposerLayoutWorkProbe.hit("cell.refreshPass")
        #endif
        for case let cell as NativeChatCell in collection.visibleCells {
            #if DEBUG
            ComposerLayoutWorkProbe.hit("cell.refreshVisit")
            #endif
            guard let index = collection.indexPath(for: cell)?.item, rows.indices.contains(index) else { continue }
            let row = rows[index]
            // A surviving cell may already have been configured inside the
            // batch. Reused/new cells still need their own key and publication.
            if cell.configuredKey != NativeChatRowKey(id: row.id, revision: row.revision) || cell.configuredPublication != input.publicationID {
                configure(cell, row: row)
            }
        }
    }
    private func configure(_ cell: NativeChatCell, row: NativeChatRow) {
        #if DEBUG
        ComposerLayoutWorkProbe.hit("cell.configure")
        #endif
        StreamLayoutWorkProbe.hit("cell.configure")
        cell.isViewportMotionActive = { [weak self] in
            guard let self, !self.detached, self.input.driver.controller === self else { return false }
            return self.input.driver.externalViewportMotion
                || self.input.composerHeightPresentation?.isAnimating == true
                || self.collection.hasPendingAnimatedViewportResize
        }
        let key = NativeChatRowKey(id: row.id, revision: row.revision)
        let publication = input.publicationID
        if cell.configuredKey != key || cell.configuredPublication != publication {
            cell.textFramePublication = nil
            cell.refreshedTextPlacement = nil
            needsTextCoverageCheck = true
            // Keep a model-backed toggle's own revision, but never lend its
            // animation to a later stream update or unrelated publication.
            if cell.disclosureMotionID != input.disclosureOperation {
                cell.disclosureMotionID = nil
            }
        }
        cell.prepareHost(for: key)
        cell.onRetireMeasurementHost = { [weak self] id, oldKey in
            self?.layout.retireMeasurementHost(id, key: oldKey)
        }
        if !cell.didResolveSendOffset, let origin = row.sendOrigin,
           let window = collection.window, origin.windowID == ObjectIdentifier(window),
           let frame = layout.frame(for: row.id) {
            cell.didResolveSendOffset = true
            let shown = collection.layer.presentation()?.bounds.origin.y ?? collection.contentOffset.y
            let top = collection.convert(CGPoint(x: 0, y: frame.minY), to: window).y
                + collection.contentOffset.y - shown
            let offset = origin.bubbleTop - top
            // Detached reading and short transcripts keep their established
            // entrance. Only connect a row already arriving near the composer.
            if offset.isFinite, offset >= 0, offset <= 160 { cell.sendOffset = offset }
        }
        let measurementHostID = cell.measurementHostID
        cell.isDisclosureHostCurrent = { [weak self, weak cell] in
            guard let self, let cell, let currentRow = self.rowByID[row.id] else { return false }
            return !self.detached && self.input.driver.controller === self
                && cell.measurementHostID == measurementHostID
                && cell.configuredPublication == self.input.publicationID
                && cell.configuredKey == NativeChatRowKey(id: row.id, revision: currentRow.revision)
                && !self.collection.isDragging && !self.collection.isDecelerating
                && !self.input.driver.externalViewportMotion && self.command == nil
        }
        if cell.configuredKey != key { cell.messageLocalFrame = nil }
        cell.configuredKey = key; cell.configuredPublication = publication
        layout.bindMeasurementHost(cell, key: key)
        let sendOffset = cell.sendOffset
        cell.contentConfiguration = UIHostingConfiguration {
            NativeChatHostedContent(lifetime: hostedContentLifetime, content: row.content)
                .environment(\.nativeChatSendOffset, sendOffset)
                .environment(\.nativeChatRowDisclosureMotion, NativeChatRowDisclosureMotion(
                    begin: { [weak self, weak cell] in
                        guard let self, let cell, !self.detached,
                              self.input.driver.controller === self,
                              self.input.publicationID == publication,
                              cell.measurementHostID == measurementHostID,
                              cell.configuredKey == key,
                              cell.configuredPublication == self.input.publicationID else { return nil }
                        // A real disclosure tap chooses a reading position.
                        // Let this row grow from that position instead of
                        // having retained bottom-follow pull its header away.
                        // Send/keyboard/explicit commands keep their ownership;
                        // later commands already re-arm the existing driver.
                        if self.input.driver.positionIsBottomPinned,
                           !self.input.holdsAutomaticBottomFollow,
                           !self.input.driver.externalViewportMotion,
                           self.command == nil, !self.collection.isDragging,
                           !self.collection.isDecelerating {
                            self.input.driver.releasePosition(userOwned: true)
                        }
                        let operation = UUID()
                        cell.disclosureMotionID = operation
                        return operation
                    },
                    end: { [weak self, weak cell] operation in
                        guard let cell, cell.measurementHostID == measurementHostID,
                              cell.disclosureMotionID == operation else { return }
                        cell.disclosureMotionID = nil
                        if let self, self.needsTextCoverageCheck { self.scheduleEmission() }
                    }
                ))
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                // The hosting cell can move and resize while SwiftUI inserts
                // native text. Resolve one moving origin for the whole row.
                .geometryGroup()
                // A tail gaining footer space can outgrow the hosting view for
                // one layout pass. Accept its current height and keep the row
                // at the top until self-sizing catches up, instead of centering
                // the larger content above it. Intrinsic measurement stays ideal.
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .coordinateSpace(name: "native-chat-row")
                // The stored outer closure must also be weak; the inner capture
                // list alone would retain this cell and its controller through it.
                .backgroundPreferenceValue(NativeChatRowFramePreferenceKey.self) { [weak self, weak cell] frames in
                    // A context/revision can change while its CGRect stays equal.
                    // Observe the token too, so the new request gets a fresh
                    // child-layout observation without re-keying MessageRow.
                    Color.clear.onChange(of: NativeChatFrameObservation(key: key, publication: publication, frames: frames), initial: true) { [weak self, weak cell] _, observation in
                        guard let self, let cell, cell.configuredKey == observation.key,
                              cell.measurementHostID == measurementHostID,
                              self.input.publicationID == observation.publication,
                              self.rowByID[row.id]?.revision == observation.key.revision,
                              let frame = observation.frames[row.id],
                              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                              frame.width > 0, frame.height > 0 else { return }
                        cell.messageLocalFrame = frame
                        cell.textFramePublication = observation.publication
                        self.needsTextCoverageCheck = true
                        self.scheduleEmission()
                    }
                }
                .onPreferenceChange(NativeChatStableStreamingBottomKey.self) { [weak self, weak cell] stable in
                    guard let self, let cell, !self.detached,
                          self.input.driver.controller === self,
                          cell.measurementHostID == measurementHostID,
                          cell.configuredKey == key,
                          cell.configuredPublication == self.input.publicationID else { return }
                    cell.prefersStableStreamingBottom = stable
                }
                .onPreferenceChange(CodeDisclosureLayoutPreferenceKey.self) { [weak self, weak cell] frames in
                    guard let self, let cell, cell.measurementHostID == measurementHostID,
                          cell.configuredKey == key, self.input.publicationID == publication,
                          self.rowByID[row.id]?.revision == key.revision else { return }
                    self.pendingCodeFrames.merge(frames, uniquingKeysWith: { _, new in new })
                    self.scheduleEmission()
                }
                .id(row.id)
                .ignoresSafeArea()
        }.margins(.all, 0).minSize(width: 0, height: 0)
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "native-chat", for: indexPath) as! NativeChatCell
        if rows.indices.contains(indexPath.item) { configure(cell, row: rows[indexPath.item]) }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? NativeChatCell, rows.indices.contains(indexPath.item) else { return }
        let row = rows[indexPath.item]
        if cell.configuredKey != NativeChatRowKey(id: row.id, revision: row.revision) || cell.configuredPublication != input.publicationID { configure(cell, row: row) }
        needsTextCoverageCheck = true
        scheduleEmission()
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? NativeChatCell)?.disclosureMotionID = nil
    }

    private func phaseNow() -> NativeChatScrollPhase {
        if collection.selectionAutoscrolling { return .interacting }
        if (touching || collection.isTracking) && collection.isDragging { return .interacting }
        if touching || collection.isTracking { return .tracking }
        if collection.isDecelerating { return .decelerating }
        if sendScrollLink != nil || animator != nil || nativeAnimatedCommandID != nil || input.driver.externalViewportMotion { return .animating }
        return .idle
    }
    fileprivate func refreshPhase() { scheduleEmission() }
    private func geometry() -> NativeChatScrollGeometry {
        var frames: [UUID: CGRect] = [:]
        for case let cell as NativeChatCell in collection.visibleCells {
            guard let key = cell.configuredKey, let row = rowByID[key.id], row.isMessage,
                  row.revision == key.revision, layout.isMeasured(key),
                  let local = cell.messageLocalFrame, let expected = layout.frame(for: key.id),
                  abs(cell.frame.minY - expected.minY) <= 0.5,
                  abs(cell.frame.width - expected.width) <= 0.01,
                  abs(cell.frame.height - expected.height) <= 0.5 else { continue }
            let document = cell.contentView.convert(local, to: collection)
            frames[key.id] = document.offsetBy(dx: -collection.contentOffset.x, dy: -collection.contentOffset.y)
        }
        return .init(publicationID: input.publicationID, sessionID: input.sessionID, frames: frames,
                     bottomSpacerFrame: layout.spacerFrame.offsetBy(dx: -collection.contentOffset.x, dy: -collection.contentOffset.y),
                     contentSize: collection.contentSize, minimumContentHeight: layout.minimumHeight,
                     contentInsets: collection.adjustedContentInset,
                     contentOffset: collection.contentOffset, containerSize: collection.bounds.size, visibleRect: collection.bounds)
    }
    /// Offset KVO can precede UIKit moving the cells. Check coverage only after
    /// current host geometry agrees with the accepted layout, including a fresh
    /// SwiftUI frame acknowledgement for this publication. Failed checks wait
    /// for an existing layout/frame/batch event; they never enqueue a retry.
    private func refreshPendingTextCoverage() {
        guard needsTextCoverageCheck, !refreshingTextCoverage,
              !detached, attachmentReady, input.driver.controller === self,
              collection.window != nil, batchID == nil,
              !input.driver.externalViewportMotion, command == nil,
              animator == nil, nativeAnimatedCommandID == nil else { return }
        needsTextCoverageCheck = false
        refreshingTextCoverage = true
        defer { refreshingTextCoverage = false }
        for case let cell as NativeChatCell in collection.visibleCells {
            guard let index = collection.indexPath(for: cell)?.item,
                  rows.indices.contains(index), rows[index].isMessage else { continue }
            let row = rows[index]
            let key = NativeChatRowKey(id: row.id, revision: row.revision)
            guard cell.window === collection.window, !cell.isHidden, cell.alpha > 0,
                  cell.disclosureMotionID == nil,
                  cell.configuredKey == key,
                  cell.configuredPublication == input.publicationID,
                  cell.textFramePublication == input.publicationID,
                  layout.isMeasured(key, by: cell.measurementHostID), let local = cell.messageLocalFrame,
                  let expected = layout.frame(for: key.id),
                  abs(cell.frame.minX - expected.minX) <= 0.01,
                  abs(cell.frame.minY - expected.minY) <= 0.5,
                  abs(cell.frame.width - expected.width) <= 0.01,
                  abs(cell.frame.height - expected.height) <= 0.5 else {
                needsTextCoverageCheck = true
                continue
            }
            // Collection content coordinates deliberately exclude scroll offset:
            // ordinary scrolling is already covered by the text's KVO path.
            let placement = NativeChatTextPlacement(
                key: key, publication: input.publicationID, hostID: cell.measurementHostID,
                cellFrame: cell.convert(cell.bounds, to: collection),
                messageFrame: cell.contentView.convert(local, to: collection))
            guard cell.refreshedTextPlacement != placement else { continue }
            // Consume before calling into UIKit so a reentrant event cannot
            // repeat this placement or have its new pending work erased.
            cell.refreshedTextPlacement = placement
            StreamLayoutWorkProbe.hit("text.coveragePlacementRefresh")
            MessageTextViewportDrawing.refreshAfterLayout(in: cell.contentView, visibleOnly: true)
        }
    }

    #if DEBUG
    fileprivate func landingProbe() -> [String: Any] {
        var cells: [[String: Any]] = []
        for case let cell as NativeChatCell in collection.visibleCells {
            guard let key = cell.configuredKey else { continue }
            let expected = layout.frame(for: key.id)
            cells.append(["id": key.id.uuidString,
                "revisionMatches": rowByID[key.id]?.revision == key.revision,
                "measured": layout.isMeasured(key),
                "local": String(describing: cell.messageLocalFrame),
                "cell": String(describing: cell.frame),
                "expected": String(describing: expected)])
        }
        return ["controller": true, "detached": detached, "attached": attachmentReady,
            "command": command != nil, "touching": touching, "userGesture": userGesture,
            "nativeMotion": nativeStreamMotionActive,
            "pendingDestination": pendingStreamDestination ?? -999,
            "cells": cells, "tail": rows.last(where: \.isMessage)?.id.uuidString ?? ""]
    }
    #endif
    fileprivate func currentGeometrySnapshot() -> NativeChatScrollGeometry? {
        guard isViewLoaded, !detached, attachmentReady,
              input.driver.controller === self else { return nil }
        return geometry()
    }
    private func scheduleEmission() {
        StreamLayoutWorkProbe.hit("geometry.schedule")
        guard !detached, !emissionScheduled else { StreamLayoutWorkProbe.hit("geometry.coalesced"); return }
        emissionScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.emissionScheduled = false
            guard !self.detached, self.attachmentReady, self.isViewLoaded,
                  self.input.driver.controller === self else { return }
            let sampledCommandID = self.command?.id
            let geometry = self.geometry()
            StreamLayoutWorkProbe.hit("geometry.computed")
            if self.input.driver.latestGeometry != geometry {
                StreamLayoutWorkProbe.hit("geometry.published")
                self.input.driver.publish(geometry)
                self.input.onGeometry(geometry)
            }
            let nextPhase = self.phaseNow(), oldPhase = self.input.driver.phase
            if nextPhase != oldPhase {
                self.input.driver.publishPhase(nextPhase, geometry: geometry)
                self.input.onPhase(.init(oldPhase: oldPhase, newPhase: nextPhase, geometry: geometry))
            }
            if !self.pendingCodeFrames.isEmpty {
                let frames = self.pendingCodeFrames; self.pendingCodeFrames = [:]
                self.input.driver.codeLayoutEvents.send(frames); self.input.onCodeLayout(frames)
            }
            self.completeCommandIfReady(geometry, sampledCommandID: sampledCommandID)
            self.refreshPendingTextCoverage()
            #if DEBUG
            if FullMotionCostProbe.enabled, self.input.streamingTailID == nil,
               let last = self.rows.last, let tail = self.rows.last(where: \.isMessage) {
                FullMotionCostProbe.finishIfReady(
                    self.layout.isMeasured(.init(id: last.id, revision: last.revision))
                        && geometry.frames[tail.id] != nil,
                    height: geometry.contentSize.height,
                    gap: geometry.contentSize.height - geometry.containerSize.height
                        + geometry.contentInsets.bottom - geometry.contentOffset.y)
            }
            #endif
            #if DEBUG
            self.updateAccessibility(geometry)
            #endif
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard input.driver.controller === self else { return }
        cancelHostedDisclosureMotions()
        input.driver.releasePosition(userOwned: true)
        userGesture = true; previousOffset = scrollView.contentOffset.y
        refreshPhase()
    }

    private func cancelHostedDisclosureMotions() {
        for case let cell as NativeChatCell in collection.visibleCells {
            cell.disclosureMotionID = nil
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let delta = scrollView.contentOffset.y - previousOffset
        previousOffset = scrollView.contentOffset.y
        scheduleEmission()
        guard input.driver.controller === self, visible, userGesture, !layout.applyingChange, batchID == nil,
              scheduledPage == nil, requestedPagePublication != input.publicationID else { return }
        let direction: CGFloat
        if scrollView.isTracking && (scrollView.panGestureRecognizer.state == .began || scrollView.panGestureRecognizer.state == .changed) {
            direction = -scrollView.panGestureRecognizer.velocity(in: scrollView).y
        } else if scrollView.isDecelerating { direction = delta } else { return }
        let threshold = max(300, scrollView.bounds.height)
        let earlier = direction < 0 && input.hasEarlier && scrollView.contentOffset.y + scrollView.adjustedContentInset.top < threshold
        let later = direction > 0 && input.hasLater && scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.maxY < threshold
        guard earlier || later else { return }
        let publication = input.publicationID
        scheduledPage = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.scheduledPage = nil
            guard self.input.driver.controller === self, self.visible, self.userGesture,
                  self.batchID == nil, self.input.publicationID == publication else { return }
            self.requestedPagePublication = publication
            let loaded = earlier ? self.input.onPageEarlier() : self.input.onPageLater()
            if !loaded { self.requestedPagePublication = nil }
        }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { userGesture = false }
        refreshPhase()
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === collection, nativeStreamMotionActive {
            nativeStreamMotionActive = false
            #if DEBUG
            FullMotionProbe.shared.nativeViewportMotion = false
            FullMotionProbe.event("native-finish", scroll: collection)
            #endif
        }
        guard scrollView === collection, let id = nativeAnimatedCommandID,
              command?.id == id, input.driver.controller === self else { return }
        nativeAnimatedCommandID = nil
        command?.animationFinished = true
        scheduleEmission()
        refreshPhase()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { userGesture = false; refreshPhase() }
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) { scheduleEmission() }

    // Research route: UIKit animates the actual viewport after tail measurement.
    // Measurement and scrolling share one owner. Commit enough of a height
    // change in that same layout pass to keep the tail above the composer;
    // UIKit can animate only the remaining visible clearance.
    private var streamMotionTailID: UUID?
    private var pendingStreamDestination: CGFloat?
    private var nativeStreamMotionActive = false

    private func admitsNativeStreamMotion(tail: UUID) -> Bool {
        guard NativeStreamMotionConfiguration.enabled, !UIAccessibility.isReduceMotionEnabled,
              input.driver.controller === self, !detached, attachmentReady,
              input.streamingTailID == tail || (nativeStreamMotionActive && streamMotionTailID == tail),
              rows.last(where: \.isMessage)?.id == tail,
              input.driver.positionIsBottomPinned, !input.holdsAutomaticBottomFollow,
              !input.hasLater, input.mutationLanding == nil, input.disclosureOperation == nil,
              !input.driver.externalViewportMotion, command == nil, batchID == nil,
              input.driver.bottomLandingValidationID == nil,
              !touching, !userGesture, !collection.isTracking,
              !collection.isDragging, !collection.isDecelerating else { return false }
        return !(collection.layer.animationKeys() ?? []).contains { key in
            guard let motion = collection.layer.animation(forKey: key) as? CAPropertyAnimation else { return false }
            return ["bounds", "bounds.origin", "bounds.origin.y"].contains(motion.keyPath ?? "")
        }
    }

    fileprivate var ownsStreamingViewportMotion: Bool {
        guard nativeStreamMotionActive || pendingStreamDestination != nil,
              let tail = streamMotionTailID else { return false }
        return admitsNativeStreamMotion(tail: tail)
    }

    private var sendScrollLink: CADisplayLink?
    private var sendScrollTrajectory: NativeChatSendTrajectory?

    private func stopSendScroll() {
        sendScrollLink?.invalidate()
        sendScrollLink = nil
        sendScrollTrajectory = nil
    }

    @objc private func advanceSendScroll(_ link: CADisplayLink) {
        guard let command, input.driver.controller === self,
              input.driver.positionCommandID == command.id,
              !detached, attachmentReady, collection.window != nil,
              !input.driver.externalViewportMotion,
              let destination = layout.offset(for: command.target),
              var trajectory = sendScrollTrajectory else {
            stopSendScroll()
            cancelCommand(reason: "sendOwnerChanged")
            return
        }
        let sample = trajectory.advance(to: destination, from: collection.contentOffset.y,
                                        at: CACurrentMediaTime())
        sendScrollTrajectory = trajectory
        collection.setContentOffset(CGPoint(x: collection.contentOffset.x,
            y: sample.position), animated: false)
        guard self.command?.id == command.id, sendScrollLink === link else { return }
        if sample.finished {
            collection.layoutIfNeeded()
            guard self.command?.id == command.id, sendScrollLink === link,
                  let bottom = layout.offset(for: command.target),
                  abs(bottom - collection.contentOffset.y) <= 1 else { return }
            stopSendScroll()
            self.command?.animationFinished = true
            scheduleEmission()
            refreshPhase()
        }
    }

    private func prepareStreamMeasurement(tail: UUID, destination: CGFloat, stableBottom: Bool) -> CGFloat? {
        // The active timeline reads the new bottom on its next frame. Applying
        // another bottom adjustment here would move the viewport twice.
        if sendScrollLink != nil { return 0 }
        #if DEBUG
        if input.driver.bottomLandingValidationID != nil, command == nil,
           input.streamingTailID == tail, input.driver.positionIsBottomPinned {
            FullMotionProbe.event("navigation-handoff-growth", scroll: collection,
                extra: ["destination": destination, "tail": tail.uuidString])
        }
        #endif
        guard destination.isFinite, admitsNativeStreamMotion(tail: tail) else { return nil }
        if stableBottom {
            // Code height changes discretely with each new line. Leaving an
            // eased remainder makes its footer repeatedly fall and catch up.
            // The accepted height and bottom offset commit together instead;
            // all existing gesture, keyboard and explicit-owner guards apply.
            stopStreamMotion(reason: "structured-growth", preserveVisible: false)
            return destination - collection.contentOffset.y
        }
        streamMotionTailID = tail
        pendingStreamDestination = destination
        let clearance = max(0, input.configuration.bottomFollowClearance)
        let current = collection.contentOffset.y
        // A collapse commits its negative adjustment as part of resizing.
        // Growth may lag only inside the existing composer clearance, even
        // when another measurement arrives before the animation finishes.
        let visibleStart = min(destination, max(current, destination - clearance))
        return visibleStart - current
    }

    private func updateStreamMotion(previous: NativeChatViewportMetrics,
                                    current: NativeChatViewportMetrics,
                                    presented: CGFloat?) {
        guard previous.size == current.size, previous.insets == current.insets,
              !input.driver.externalViewportMotion else {
            stopStreamMotion(reason: "viewport", preserveVisible: false)
            return
        }
        guard let destination = pendingStreamDestination else { return }
        pendingStreamDestination = nil
        guard let tail = streamMotionTailID, admitsNativeStreamMotion(tail: tail) else { return }
        let from = collection.contentOffset.y
        guard abs(destination - from) > 0.5 else {
            stopStreamMotion(reason: "measuredAtBottom", preserveVisible: false)
            return
        }
        // Retargeting can synchronously finish the old UIKit scroll. Publish
        // the replacement owner after that callback, not before it can clear it.
        collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: destination), animated: true)
        nativeStreamMotionActive = true
        #if DEBUG
        FullMotionProbe.shared.nativeViewportMotion = true
        FullMotionProbe.event("start", scroll: collection, extra: [
            "from": from, "to": destination, "tail": tail.uuidString,
            "streaming": input.streamingTailID != nil, "route": "native-viewport",
            "external": input.driver.externalViewportMotion, "command": command != nil,
            "holdSend": input.holdsAutomaticBottomFollow])
        #endif
    }

    private func stopStreamMotion(reason: String, preserveVisible: Bool) {
        pendingStreamDestination = nil
        guard nativeStreamMotionActive else { return }
        nativeStreamMotionActive = false
        #if DEBUG
        FullMotionProbe.shared.nativeViewportMotion = false
        #endif
        let before = collection.contentOffset.y
        collection.setContentOffset(collection.contentOffset, animated: false)
        #if DEBUG
        FullMotionProbe.event("stop", scroll: collection, extra: [
            "reason": reason, "before": before, "after": collection.contentOffset.y,
            "external": input.driver.externalViewportMotion,
            "pinned": input.driver.positionIsBottomPinned])
        #endif
    }

    fileprivate func cancelCommand(requestID: UUID? = nil, reason: String = "superseded") {
        // An explicit owner release also cancels the uncommanded mutation
        // handoff. A late cancellation for another UUID must not cancel it.
        if requestID == nil {
            input.mutationLanding = nil
            stopStreamMotion(reason: reason, preserveVisible: !input.driver.externalViewportMotion)
        }
        guard let active = command, requestID == nil || requestID == active.id else { return }
        stopSendScroll()
        input.mutationLanding = nil
        // Remove the completion before stopping UIKit: stopping can synchronously
        // invoke its completion. Only the saved command is resumed, once.
        command = nil
        let currentAnimator = animator; animator = nil
        let stopsNativeAnimation = nativeAnimatedCommandID == active.id
        nativeAnimatedCommandID = nil
        // Clear the command identity before UIKit can deliver a stop callback.
        if stopsNativeAnimation {
            collection.setContentOffset(collection.contentOffset, animated: false)
        }
        if input.driver.controller === self, input.driver.positionCommandID == active.id {
            input.driver.positionCommandID = nil; input.driver.target = nil
            input.driver.followBottomContentChanges = false
        }
        #if DEBUG
        recordEvent("cancel", commandID: active.id, target: active.target,
                    extra: ["reason": reason, "completedSuccessfully": false])
        #endif
        if let currentAnimator, currentAnimator.state == .active {
            currentAnimator.stopAnimation(false); currentAnimator.finishAnimation(at: .current)
            // Finishing at the presentation position changes bounds without
            // invalidating UICollectionView's endpoint-only visible-cell range.
            if input.driver.controller === self, collection.window != nil {
                layout.invalidateLayout()
                collection.layoutIfNeeded()
            }
        }
        active.completion(false)
        refreshPhase()
    }

    fileprivate func beginRowResize(requestID: UUID, rowID: UUID,
                                    anchor: NativeChatRowResizeAnchor) -> Bool {
        guard input.driver.controller === self, !detached, collection.window != nil,
              command == nil, input.driver.positionCommandID == nil,
              !input.driver.externalViewportMotion, !touching, !userGesture,
              !collection.isTracking, !collection.isDragging, !collection.isDecelerating,
              let row = rowByID[rowID], row.isMessage,
              layout.isMeasured(.init(id: rowID, revision: row.revision)),
              let frame = layout.frame(for: rowID) else { return false }
        let target: NativeChatScrollTarget
        switch anchor {
        case .top: target = .rowTop(rowID, frame.minY - collection.contentOffset.y)
        case .bottom: target = .rowBottom(rowID, frame.maxY - collection.contentOffset.y)
        case .transcriptBottom: target = .bottom
        }
        input.driver.beginCommand(target, id: requestID)
        return true
    }

    fileprivate func scroll(to target: NativeChatScrollTarget, duration: TimeInterval?,
                            timing: NativeChatScrollTiming, requestID: UUID,
                            completion: @escaping (Bool) -> Void) {
        cancelCommand(reason: "superseded")
        guard input.driver.controller === self, isViewLoaded, !detached else { completion(false); return }
        if case .bottom = target, input.holdsAutomaticBottomFollow,
           !input.driver.externalViewportMotion,
           timing != .system, timing != .send, let duration, duration > 0,
           let last = rows.last,
           !layout.isMeasured(.init(id: last.id, revision: last.revision)),
           let estimatedY = layout.offset(for: target), estimatedY.isFinite {
            // Size the send's reserved reply before committing the animation.
            // UICollectionView only self-sizes cells in its destination bounds.
            // Both layout passes finish synchronously without presenting that
            // temporary viewport; the animation retains the original origin.
            let origin = collection.contentOffset
            UIView.performWithoutAnimation {
                collection.setContentOffset(CGPoint(x: origin.x, y: estimatedY), animated: false)
                collection.layoutIfNeeded()
                collection.setContentOffset(origin, animated: false)
                collection.layoutIfNeeded()
            }
        }
        guard let y = layout.offset(for: target), y.isFinite else { completion(false); return }
        #if DEBUG
        recordEvent("commandBefore", commandID: requestID, target: target,
                    extra: ["targetOffsetY": y, "duration": duration ?? 0, "timing": timing.rawValue])
        #endif
        input.driver.beginCommand(target, id: requestID)
        command = (requestID, target, completion, false)
        let drivenDuration: TimeInterval? = {
            if timing == .edge, input.streamingTailID == nil,
               !UIAccessibility.isReduceMotionEnabled {
                let viewport = max(1, collection.bounds.height
                    - collection.adjustedContentInset.top - collection.adjustedContentInset.bottom)
                let screens = abs(collection.contentOffset.y - y) / viewport
                // Keep nearby navigation on its existing UIKit trajectory.
                // Add a modest distance allowance without making long edge
                // trips feel like a wait. Keep the same continuous trajectory;
                // newly measured destinations can still need a short settling
                // segment. Streaming keeps its system-scroll/follow handoff.
                if screens > 1.5 {
                    return min(0.6, 0.32 + 0.06 * sqrt(Double(screens - 1.5)))
                }
            }
            if timing == .send, case .bottom = target,
               let duration, duration.isFinite, duration > 0 { return duration }
            return nil
        }()
        if let duration = drivenDuration, abs(collection.contentOffset.y - y) > 0.5 {
            sendScrollTrajectory = NativeChatSendTrajectory(
                origin: collection.contentOffset.y, destination: y,
                start: CACurrentMediaTime(), duration: duration)
            let link = CADisplayLink(target: self, selector: #selector(advanceSendScroll(_:)))
            if (collection.window?.screen.maximumFramesPerSecond ?? 60) >= 120 {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 80, maximum: 120, preferred: 120
                )
            }
            sendScrollLink = link
            link.add(to: .main, forMode: .common)
            refreshPhase()
        } else if timing == .system || timing == .send || timing == .edge,
                  abs(collection.contentOffset.y - y) > 0.5 {
            // UIScrollView updates the logical viewport while moving, allowing
            // UICollectionView to prepare only the cells currently on screen.
            nativeAnimatedCommandID = requestID
            collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: y), animated: true)
            refreshPhase()
        } else if let duration, duration.isFinite, duration > 0,
                  let animator = timing.animator(duration: duration) {
            animator.addAnimations { [weak self] in self?.collection.contentOffset.y = y }
            self.animator = animator
            animator.addCompletion { [weak self] position in
                guard let self, self.command?.id == requestID else { return }
                self.animator = nil
                if position == .end {
                    self.command?.animationFinished = true
                    self.scheduleEmission()
                } else {
                    self.finishCommand(requestID, success: false, reason: "animatorInterrupted")
                }
                self.refreshPhase()
            }
            animator.startAnimation(); refreshPhase()
        } else {
            collection.setContentOffset(CGPoint(x: collection.contentOffset.x, y: y), animated: false)
            command?.animationFinished = true
            scheduleEmission()
        }
    }

    private func finishCommand(_ requestID: UUID, success: Bool, reason: String) {
        guard let active = command, active.id == requestID else { return }
        stopSendScroll()
        command = nil
        if nativeAnimatedCommandID == requestID { nativeAnimatedCommandID = nil }
        if input.driver.controller === self, input.driver.positionCommandID == requestID {
            input.driver.positionCommandID = nil
            if !success {
                input.driver.target = nil; input.driver.followBottomContentChanges = false
            } else {
                switch active.target {
                case .row, .rowBottom, .rowTop: input.driver.target = nil
                case .top, .bottom: break
                }
            }
        }
        #if DEBUG
        recordEvent("commandComplete", commandID: requestID, target: active.target,
                    extra: ["completedSuccessfully": success, "reason": reason])
        #endif
        #if DEBUG
        FullMotionProbe.event("native-command-finish", scroll: collection, extra: [
            "success": success, "reason": reason, "desired": layout.offset(for: active.target) ?? -999,
            "target": String(describing: active.target)])
        #endif
        active.completion(success)
    }

    private func completeCommandIfReady(_ geometry: NativeChatScrollGeometry, sampledCommandID: UUID?) {
        // Geometry callbacks may synchronously start or replace a command.
        // Its completion must use the next publication, not the snapshot from
        // before that callback moved the viewport. The command schedules it.
        guard let command, command.id == sampledCommandID, command.animationFinished else { return }
        guard input.driver.controller === self else {
            finishCommand(command.id, success: false, reason: "ownerChanged")
            return
        }
        guard geometry.publicationID == input.publicationID,
              geometry.sessionID == input.sessionID,
              geometry.contentOffset == collection.contentOffset,
              geometry.contentSize == collection.contentSize,
              geometry.containerSize == collection.bounds.size,
              geometry.contentInsets == collection.adjustedContentInset else { return }
        switch command.target {
        case let .row(id, _), let .rowBottom(id, _), let .rowTop(id, _):
            guard let row = rowByID[id] else {
                finishCommand(command.id, success: false, reason: "targetRemoved")
                return
            }
            guard layout.isMeasured(.init(id: id, revision: row.revision)), geometry.frames[id] != nil else { return }
        case .top, .bottom: break
        }
        if case .bottom = command.target {
            // A temporary estimated bottom is not a completed landing. A real
            // auxiliary footer must also be measured before acknowledging it.
            if let last = rows.last {
                guard layout.isMeasured(.init(id: last.id, revision: last.revision)) else { return }
            }
            if let lastMessage = rows.last(where: \.isMessage) {
                guard geometry.frames[lastMessage.id] != nil else { return }
            }
        }
        guard let desired = layout.offset(for: command.target) else {
            finishCommand(command.id, success: false, reason: "targetUnavailable")
            return
        }
        let atTarget = abs(geometry.contentOffset.y - desired) <= 1
        finishCommand(command.id, success: atTarget, reason: atTarget ? "nativeCompleted" : "targetNotReached")
    }

    #if DEBUG
    /// Fixture-only, bounded stage records. These sample input application, not
    /// the earlier AppModel mutation or the exact physical send-button event.
    private func recordEvent(_ stage: String, commandID: UUID? = nil,
                             target: NativeChatScrollTarget? = nil, extra: [String: Any] = [:]) {
        guard !FullMotionCostProbe.enabled, input.debugWindow != nil, isViewLoaded else { return }
        func rect(_ value: CGRect) -> [String: CGFloat] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        func finite(_ value: CGRect) -> Bool {
            value.minX.isFinite && value.minY.isFinite && value.width.isFinite && value.height.isFinite
        }
        let sample = geometry()
        var windowFrames: [String: [String: CGFloat]] = [:]
        var presentationFrames: [String: [String: CGFloat]] = [:]
        var presentationViewportFrames: [String: [String: CGFloat]] = [:]
        var presentationValid: [String: Bool] = [:]
        var hosts: [String: Any] = [:]
        for case let cell as NativeChatCell in collection.visibleCells {
            guard let key = cell.configuredKey, rowByID[key.id]?.isMessage == true else { continue }
            let id = key.id.uuidString
            let matchesRevision = rowByID[key.id]?.revision == key.revision
            hosts[id] = ["frame": rect(cell.frame.offsetBy(dx: -collection.contentOffset.x, dy: -collection.contentOffset.y)),
                         "revisionMatches": matchesRevision, "measured": layout.isMeasured(key),
                         "hasWindow": cell.window != nil]
            presentationValid[id] = false
            guard let local = cell.messageLocalFrame, let window = cell.window else { continue }
            let model = cell.contentView.convert(local, to: window)
            if finite(model) { windowFrames[id] = rect(model) }
            guard let source = cell.contentView.layer.presentation(),
                  let windowLayer = window.layer.presentation(),
                  let viewportLayer = collection.layer.presentation() else { continue }
            let shown = source.convert(local, to: windowLayer)
            let viewport = source.convert(local, to: viewportLayer)
                .offsetBy(dx: -viewportLayer.bounds.minX, dy: -viewportLayer.bounds.minY)
            guard finite(shown), finite(viewport) else { continue }
            presentationFrames[id] = rect(shown)
            presentationViewportFrames[id] = rect(viewport)
            presentationValid[id] = true
        }
        eventSequence &+= 1
        var event: [String: Any] = [
            "sequence": eventSequence, "stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
            "scrollViewIdentity": String(describing: ObjectIdentifier(collection)),
            "session": String(describing: input.sessionID), "publication": String(describing: input.publicationID),
            "offsetY": sample.contentOffset.y, "contentHeight": sample.contentSize.height,
            "viewportHeight": sample.containerSize.height, "insetTop": sample.contentInsets.top,
            "insetBottom": sample.contentInsets.bottom, "tracking": collection.isTracking,
            "dragging": collection.isDragging, "decelerating": collection.isDecelerating,
            "rowIDs": rows.filter(\.isMessage).map { $0.id.uuidString },
            "frames": Dictionary(uniqueKeysWithValues: sample.frames.map { ($0.key.uuidString, rect($0.value)) }),
            "windowFrames": windowFrames, "presentationFrames": presentationFrames,
            "presentationViewportFrames": presentationViewportFrames,
            "presentationValid": presentationValid, "hostFrames": hosts,
            "frameCoordinates": "inner-message-viewport", "presentationCoordinates": "inner-message-window"
        ]
        if let commandID { event["commandID"] = commandID.uuidString }
        if let target {
            switch target {
            case .top: event["target"] = "top"
            case .bottom: event["target"] = "bottom"
            case let .rowBottom(id, bottomY):
                event["target"] = id.uuidString; event["targetBottomY"] = bottomY
            case let .rowTop(id, topY):
                event["target"] = id.uuidString; event["targetTopY"] = topY
            case let .row(id, anchor):
                event["target"] = id.uuidString; event["targetAnchorY"] = anchor.y
            }
        }
        event.merge(extra, uniquingKeysWith: { _, new in new })
        if ["commandBefore", "commandComplete", "cancel"].contains(stage) {
            FullMotionLandingProbe.record(event)
        }
        sendOriginEvents.append(event)
        if sendOriginEvents.count > 64 {
            droppedEventCount += sendOriginEvents.count - 64
            sendOriginEvents.removeFirst(sendOriginEvents.count - 64)
        }
        scheduleEmission()
    }
    #endif

    #if DEBUG
    private func updateAccessibility(_ geometry: NativeChatScrollGeometry) {
        guard input.debugWindow != nil,
              !FullMotionCostProbe.quiet || FullMotionCostProbe.active == nil else { return }
        func rect(_ frame: CGRect) -> [String: CGFloat] { ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height] }
        let maxY = max(-geometry.contentInsets.top, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom)
        var value: [String: Any] = [
            "offsetY": geometry.contentOffset.y, "contentHeight": geometry.contentSize.height,
            "viewportHeight": geometry.containerSize.height, "adjustedInsetTop": geometry.contentInsets.top,
            "adjustedInsetBottom": geometry.contentInsets.bottom, "bottomGap": maxY - geometry.contentOffset.y,
            "count": rows.count, "generation": layout.generation,
            "visibleIDs": geometry.frames.keys.map(\.uuidString).sorted(),
            "frames": Dictionary(uniqueKeysWithValues: geometry.frames.map { ($0.key.uuidString, rect($0.value)) }),
            "bottomSpacerFrame": rect(geometry.bottomSpacerFrame), "publication": String(describing: geometry.publicationID),
            "session": String(describing: geometry.sessionID), "tracking": collection.isTracking,
            "dragging": collection.isDragging, "decelerating": collection.isDecelerating
        ]
        if let window = input.debugWindow { value["start"] = window.start; value["end"] = window.end; value["total"] = window.total }
        if let lastBatch { value["lastBatch"] = lastBatch }
        value["motion"] = FullMotionProbe.snapshot
        value["streamingTail"] = input.streamingTailID?.uuidString ?? ""
        value["bottomPinned"] = input.driver.positionIsBottomPinned
        value["externalMotion"] = input.driver.externalViewportMotion
        value["activeCommand"] = command != nil
        value["bottomLandingValidationPending"] = input.driver.bottomLandingValidationID != nil
        value["navigationEvents"] = FullMotionLandingProbe.events
        value["sendOriginEvents"] = sendOriginEvents
        value["sendOriginEventsDropped"] = droppedEventCount
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            collection.accessibilityValue = text
        }
    }
    #endif
}

// The signed phone experiment uses the same route as the simulator candidate,
// without launch arguments. Ordinary builds keep their established behavior.
@MainActor enum NativeStreamMotionConfiguration {
    #if STREAM_HEIGHT_PHONE_CANDIDATE
    static let enabled = true
    static let readsCurrentNavigationGeometry = true
    #elseif DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-fullMotionCandidate")
    static let readsCurrentNavigationGeometry = ProcessInfo.processInfo.arguments.contains("-fullMotionFreshNavigation")
    #else
    static let enabled = false
    static let readsCurrentNavigationGeometry = false
    #endif
}

#if DEBUG
// Read-only attribution of the live tail against the actual composer frame.
@MainActor enum StreamOcclusionProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-streamOcclusion")
    static var composerFrame: CGRect = .zero
}

// Isolated simulator diagnostics, absent from the frozen product source.
@MainActor private final class FullMotionProbe: NSObject {
    static let shared = FullMotionProbe()
    static let candidateEnabled = ProcessInfo.processInfo.arguments.contains("-fullMotionCandidate")
    static let hideTopEdge = ProcessInfo.processInfo.arguments.contains("-fullMotionHideTopEdge")
    static var mode: String { candidateEnabled ? "candidate" : "baseline" }
    static var snapshot: [String: Any] {
        ["mode": mode, "hideTopEdge": hideTopEdge, "cpuRuns": FullMotionCostProbe.results, "starts": shared.starts, "stops": shared.stops,
         "samples": shared.samples, "animatedSamples": shared.animatedSamples,
         "maxLag": shared.maxLag, "maxUncoveredTop": shared.maxUncoveredTop,
         "events": Array(shared.events.suffix(50))]
    }
    var tailFrame: (() -> CGRect?)?
    var occlusionState: (() -> [String: Any])?
    var streaming = false
    var nativeViewportMotion = false
    weak var scroll: UIScrollView?
    var link: CADisplayLink?
    var events: [[String: Any]] = []
    var frames: [[String: Any]] = []
    var starts = 0, stops = 0, samples = 0, animatedSamples = 0
    var maxLag = 0.0, maxUncoveredTop = 0.0
    static func attach(_ scroll: UIScrollView) {
        shared.scroll = scroll
        if #available(iOS 26.0, *), hideTopEdge { scroll.topEdgeEffect.isHidden = true }
        guard !FullMotionCostProbe.enabled, shared.link == nil else { return }
        let link = CADisplayLink(target: shared, selector: #selector(tick))
        shared.link = link; link.add(to: .main, forMode: .common)
    }
    static func event(_ name: String, scroll: UIScrollView, extra: [String: Any] = [:]) {
        shared.scroll = scroll
        if name == "start" { shared.starts += 1; FullMotionCostProbe.animations += 1 }
        if name == "stop" { shared.stops += 1 }
        if FullMotionCostProbe.enabled { return }
        var value: [String: Any] = ["event": name, "t": ProcessInfo.processInfo.systemUptime,
            "offset": scroll.contentOffset.y,
            "shown": scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y]
        value.merge(extra, uniquingKeysWith: { _, new in new })
        shared.events.append(value)
        if shared.events.count > 4000 { shared.events.removeFirst(1000) }
    }
    @objc func tick() {
        guard let scroll, scroll.window != nil else { return }
        samples += 1
        let animated = nativeViewportMotion
        let shown = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
        let lag = abs(scroll.contentOffset.y - shown)
        let top = shown + scroll.adjustedContentInset.top
        let cells = (scroll as? UICollectionView)?.visibleCells ?? []
        let first = cells.map(\.frame.minY).min() ?? top
        let hole = max(0, first - top)
        if animated {
            animatedSamples += 1; maxLag = max(maxLag, lag)
            maxUncoveredTop = max(maxUncoveredTop, hole)
        }
        let tail = tailFrame?()
        var frame: [String: Any] = ["streaming": streaming, "tailHeight": tail?.height ?? 0,
            "tailTop": (tail?.minY ?? 0) - shown, "tailBottom": (tail?.maxY ?? 0) - shown,
            "t": ProcessInfo.processInfo.systemUptime, "offset": scroll.contentOffset.y,
            "shown": shown, "height": scroll.contentSize.height, "viewport": scroll.bounds.height,
            "insetBottom": scroll.adjustedContentInset.bottom, "insetTop": scroll.adjustedContentInset.top,
            "animated": animated, "tracking": scroll.isTracking, "dragging": scroll.isDragging,
            "holeTop": hole, "cellCount": cells.count,
            "keys": scroll.layer.animationKeys() ?? []]
        if StreamOcclusionProbe.enabled, let state = occlusionState?() {
            frame.merge(state, uniquingKeysWith: { _, new in new })
        }
        frames.append(frame)
        if frames.count > 20000 { frames.removeFirst(5000) }
        if samples % 60 == 0 { flush() }
    }
    func flush() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-fullMotionRun"), i + 1 < args.count else { return }
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("full-motion-\(args[i + 1]).json")
        let value: [String: Any] = ["summary": Self.snapshot, "events": events, "frames": frames]
        if let data = try? JSONSerialization.data(withJSONObject: value) { try? data.write(to: path, options: .atomic) }
    }
}

// Measurement-only. No display link or periodic file write in this mode.
import Darwin
@MainActor private enum FullMotionCostProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-fullMotionLean")
    static let quiet = ProcessInfo.processInfo.arguments.contains("-fullMotionQuietCost")
    static var inputUpdates = 0, layouts = 0, animations = 0
    static var active: UUID?
    static var awaitingFinalGeometry = false
    static var startCPU = 0.0, started = 0.0
    static var startUpdates = 0, startLayouts = 0, startAnimations = 0
    static var results: [[String: Any]] = []
    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func input(_ tail: UUID?) {
        guard enabled else { return }
        if let tail, active == nil {
            active = tail; awaitingFinalGeometry = false
            StreamLayoutWorkProbe.begin()
            startCPU = cpu(); started = ProcessInfo.processInfo.systemUptime
            startUpdates = inputUpdates; startLayouts = layouts; startAnimations = animations
        }
        inputUpdates += 1
        if tail == nil, active != nil { awaitingFinalGeometry = true }
    }
    static func finishIfReady(_ ready: Bool, height: CGFloat, gap: CGFloat) {
        guard enabled, active != nil, awaitingFinalGeometry, ready else { return }
        let used = cpu() - startCPU
        results.append(["cpuSeconds": used, "elapsed": ProcessInfo.processInfo.systemUptime - started,
            "inputUpdates": inputUpdates - startUpdates, "layouts": layouts - startLayouts,
            "animationStarts": animations - startAnimations, "finalHeight": height, "finalGap": gap,
            "layoutWork": StreamLayoutWorkProbe.finish(),
            "scope": "First streaming input to measured EOF native geometry. App process CPU only; no GPU or power measurement."])
        active = nil; awaitingFinalGeometry = false
        FullMotionProbe.shared.flush()
    }
}

// Bounded simulator-only observation. It never scrolls, lays out, or schedules work.
@MainActor enum FullMotionLandingProbe {
    static var events: [[String: Any]] = []
    static var boundaryUsed = false
    static func boundaryMode() -> String? {
        guard !boundaryUsed else { return nil }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-navigationBoundary"), index + 1 < args.count else { return nil }
        boundaryUsed = true
        return args[index + 1]
    }
    static func record(_ value: [String: Any]) {
        guard ProcessInfo.processInfo.arguments.contains("-fullMotionFreshNavigation"),
              events.count < 100 else { return }
        var event = value
        event["uptime"] = ProcessInfo.processInfo.systemUptime
        events.append(event)
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("full-motion-landing.json"), options: .atomic)
        }
    }
}

#endif

#if DEBUG
/// Opt-in, bounded counters for composer A/B runs. No timer, observation or I/O.
/// Scope times are inclusive main-thread wall time, not process CPU or GPU FPS.
@MainActor enum ComposerLayoutWorkProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-composerLayoutProbe")
    static let legacy = enabled && ProcessInfo.processInfo.arguments.contains("-composerLayoutLegacy")
    private(set) static var counts: [String: Int] = [:]
    private(set) static var milliseconds: [String: Double] = [:]
    private(set) static var maxima: [String: Double] = [:]
    static func reset() {
        counts.removeAll(keepingCapacity: true)
        milliseconds.removeAll(keepingCapacity: true)
        maxima.removeAll(keepingCapacity: true)
    }
    static func hit(_ key: String) {
        guard enabled else { return }
        counts[key, default: 0] += 1
    }
    static func items(_ count: Int) {
        guard enabled else { return }
        counts["layout.invalidatedItems", default: 0] += count
    }
    static func beginScope() -> CFTimeInterval? { enabled ? CACurrentMediaTime() : nil }
    static func endScope(_ key: String, start: CFTimeInterval?) {
        guard let start else { return }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        hit(key)
        milliseconds[key, default: 0] += elapsed
        maxima[key] = max(maxima[key, default: 0], elapsed)
    }
}
#endif

// Local attribution only: enabled explicitly, accumulated during the CPU probe,
// and written once at EOF. Counters never change layout or scrolling policy.
@MainActor enum StreamLayoutWorkProbe {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-streamLayoutWork")
    #else
    static let enabled = false
    #endif
    private static var active = false
    private static var counts: [String: Int] = [:]
    static func begin() {
        guard enabled else { return }
        counts.removeAll(keepingCapacity: true); active = true
    }
    static func hit(_ name: String) {
        guard enabled, active else { return }
        counts[name, default: 0] += 1
    }
    static func finish() -> [String: Int] {
        active = false
        return counts
    }
}
