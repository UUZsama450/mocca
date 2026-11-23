import SwiftUI
import UIKit

private struct ReplyBannerNotice {
    let messageID: UUID
    let conversationID: UUID
    let assistantID: UUID
    let assistantName: String
    let preview: String

    @MainActor
    init(message: ChatMessage, assistant: AssistantProfile) {
        messageID = message.id
        conversationID = message.conversationID
        assistantID = assistant.id
        let name = assistant.name.trimmingCharacters(in: .whitespacesAndNewlines)
        assistantName = name.isEmpty || name == AssistantProfile.defaultName ? L10n.lookup("助手") : name
        // Finalization already separated reasoning, tools and control markers.
        // Bound the input before doing any preview formatting on the main thread.
        let excerpt = String(message.text.prefix(256))
        let lines = excerpt.replacingOccurrences(of: #"(?m)^ {0,3}(?:#{1,6}|>|[-*]) +"#, with: "", options: .regularExpression)
        let text = lines.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !text.isEmpty {
            preview = String(text.prefix(100))
        } else if let attachment = message.attachments.first {
            preview = attachment.kind == .image ? L10n.lookup("图片") : L10n.lookup("附件")
        } else {
            preview = L10n.lookup("回复已完成")
        }
    }
}

/// Attached to the existing app window only while a finished reply is on screen.
/// Streaming and transcript layout never observe this presentation state.
@MainActor
final class ReplyBannerPresenter: NSObject, UIGestureRecognizerDelegate {
    weak var window: UIWindow?
    private weak var model: AppModel?
    private var waiting: [ReplyBannerNotice] = []
    private var current: ReplyBannerNotice?
    private var card: UIView?
    private var pull: ReplyBannerPull?
    private var expiry: Task<Void, Never>?
    private var touchDownInWindow = CGPoint.zero
    private var grabbedOffset = CGPoint.zero
    private var legacySpring: UIViewPropertyAnimator?

    init(model: AppModel) {
        self.model = model
    }

    // These presentations already have a SwiftUI-owned way to return to chat.
    private static let browsingSheets: [ReferenceWritableKeyPath<AppModel, Bool>] = [
        \.isAssistantSelectorPresented, \.isSettingsPresented, \.isFavoritesPresented,
        \.isCalendarPresented, \.isProviderSettingsPresented, \.isModelSelectorPresented
    ]

    private func canShow(_ conversationID: UUID, in window: UIWindow, model: AppModel) -> Bool {
        guard window.windowScene?.activationState == .foregroundActive,
              !model.isFirstRunModelSetupPresented, !model.isBottomToolsPresented,
              !model.isErrorPresented, model.pendingToolApproval == nil else { return false }
        let browsing = Self.browsingSheets.contains { model[keyPath: $0] }
        if let modal = window.rootViewController?.presentedViewController {
            guard browsing, modal.presentedViewController == nil, !(modal is UIAlertController) else { return false }
        }
        // Opening the drawer or a settings sheet does not leave this conversation.
        // Admission is checked only on reply completion and when draining the queue.
        return model.selectedConversationID != conversationID
    }

    func receive(_ message: ChatMessage, from assistant: AssistantProfile) {
        guard let model, let window, canShow(message.conversationID, in: window, model: model) else { return }
        let notice = ReplyBannerNotice(message: message, assistant: assistant)
        // Keep the card stable under a finger. A busy group can occupy only one
        // more slot while distinct conversations retain their arrival order.
        if let index = waiting.firstIndex(where: { $0.conversationID == notice.conversationID }) {
            waiting[index] = notice
        } else {
            waiting.append(notice)
        }
        showNext()
    }

    func didOpen(_ conversationID: UUID) {
        waiting.removeAll { $0.conversationID == conversationID }
        guard current?.conversationID == conversationID else { return }
        removeCard()
        showNext()
    }

    func clear() {
        waiting.removeAll()
        removeCard()
    }

    private func showNext() {
        guard current == nil, let model, let window else { return }
        while !waiting.isEmpty {
            let notice = waiting.removeFirst()
            guard canShow(notice.conversationID, in: window, model: model),
                  let conversation = model.conversation(for: notice.conversationID) else { continue }
            let title = conversation.localizedDisplayTitle
            let pull = ReplyBannerPull()
            let content = ReplyBannerCard(
                name: notice.assistantName,
                title: title,
                preview: notice.preview,
                assistant: model.assistantProfile(id: notice.assistantID.uuidString),
                pull: pull,
                open: { [weak self] in self?.open(notice) },
                dismiss: { [weak self] in self?.dismiss(notice.messageID) }
            )
            .environment(model)
            .environment(\.locale, AppLocalization.shared.locale)
            .appFontEnvironment(model.preferences.appFontPostScriptName)
            let view = UIHostingConfiguration { content }
                .margins(.all, 0)
                .makeContentView()
            view.backgroundColor = .clear
            view.translatesAutoresizingMaskIntoConstraints = false
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panCard(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapCard(_:)))
            tap.require(toFail: pan)
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(tap)
            window.addSubview(view)
            let safe = window.safeAreaLayoutGuide
            let width = view.widthAnchor.constraint(equalToConstant: 356)
            width.priority = .defaultHigh
            let top = view.topAnchor.constraint(equalTo: safe.topAnchor, constant: 64)
            top.priority = .defaultHigh
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
                // A side toolbar can leave the window's top safe inset at zero
                // while the chat still places its own controls below the top edge.
                view.topAnchor.constraint(greaterThanOrEqualTo: window.topAnchor, constant: 88),
                top,
                view.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -28),
                width
            ])
            current = notice
            card = view
            self.pull = pull
            view.layoutIfNeeded()
            view.alpha = 0
            if !UIAccessibility.isReduceMotionEnabled {
                view.transform = CGAffineTransform(translationX: 0, y: -8)
            }
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                view.transform = .identity
                view.alpha = 1
            }
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: [notice.assistantName, title, notice.preview].joined(separator: "，"))
            }
            scheduleExpiry(for: notice.messageID)
            return
        }
    }

    private func scheduleExpiry(for messageID: UUID) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 12 : 5)) }
            catch { return }
            self?.dismiss(messageID)
        }
    }

    @objc private func tapCard(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, tap.view === card, let current else { return }
        open(current)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer.state == .possible, let view = recognizer.view {
            touchDownInWindow = touch.location(in: touch.window)
            pull?.grab(at: touch.location(in: view), in: view.bounds)
            // A finger can catch the card while it is returning to its anchor.
            let visible = (view.layer.presentation() ?? view.layer).affineTransform()
            grabbedOffset = CGPoint(x: visible.tx, y: visible.ty)
        }
        return true
    }

    @objc private func panCard(_ pan: UIPanGestureRecognizer) {
        guard let card, pan.view === card, card.isUserInteractionEnabled, let current else { return }
        // Count travel from touch-down, including movement before UIKit recognizes
        // a pan. Use the window because the card itself follows the finger.
        if pan.state == .began {
            let point = pan.location(in: card.window)
            let initialDelta = CGPoint(x: point.x - touchDownInWindow.x, y: point.y - touchDownInWindow.y)
            pan.setTranslation(initialDelta, in: card.window)
        }
        let delta = pan.translation(in: card.window)
        let offset = CGPoint(x: grabbedOffset.x + delta.x, y: grabbedOffset.y + delta.y)
        switch pan.state {
        case .began:
            expiry?.cancel()
            stopLegacySpring()
            card.layer.removeAnimation(forKey: "transform")
            fallthrough
        case .changed:
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            pull?.drag(by: delta)
            let position = CGAffineTransform(translationX: offset.x, y: offset.y)
            if #available(iOS 18.0, *) {
                UIView.animate(.interactiveSpring) { card.transform = position }
            } else {
                card.transform = position
            }
        case .ended:
            let velocity = pan.velocity(in: card.window)
            // Project using the system's fast scroll deceleration (per millisecond).
            let rate = UIScrollView.DecelerationRate.fast.rawValue
            let coast = rate / (1000 * (1 - rate))
            let projected = CGPoint(x: delta.x + velocity.x * coast, y: delta.y + velocity.y * coast)
            let horizontal = abs(projected.x) > abs(projected.y)
            if (horizontal ? projected.x : projected.y) <= -14 {
                var end = CGPoint(x: grabbedOffset.x + projected.x, y: grabbedOffset.y + projected.y)
                if horizontal {
                    end.x = min(end.x, offset.x - card.bounds.height)
                } else {
                    end.y = min(end.y, offset.y - card.bounds.height)
                }
                dismiss(current.messageID, towards: end, velocity: velocity)
            } else {
                settle(card, at: .zero, velocity: velocity)
                scheduleExpiry(for: current.messageID)
            }
        case .cancelled:
            settle(card, at: .zero, velocity: .zero)
            scheduleExpiry(for: current.messageID)
        default:
            break
        }
    }

    private func settle(_ card: UIView, at offset: CGPoint, velocity: CGPoint) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            card.transform = .identity
            return
        }
        let position = CGAffineTransform(translationX: offset.x, y: offset.y)
        let duration = 0.34
        if #available(iOS 18.0, *) {
            // The spring inherits the velocity of the preceding interactive spring.
            UIView.animate(.spring(duration: duration, bounce: 0)) { card.transform = position }
        } else {
            func unitVelocity(_ speed: CGFloat, over distance: CGFloat) -> CGFloat {
                abs(distance) >= 1 ? min(20, max(-20, speed / distance)) : 0
            }
            let speed = CGVector(dx: unitVelocity(velocity.x, over: offset.x - card.transform.tx),
                                 dy: unitVelocity(velocity.y, over: offset.y - card.transform.ty))
            let spring = UISpringTimingParameters(duration: duration, bounce: 0, initialVelocity: speed)
            let animator = UIViewPropertyAnimator(duration: duration, timingParameters: spring)
            animator.addAnimations { card.transform = position }
            legacySpring = animator
            animator.startAnimation()
        }
    }

    private func stopLegacySpring() {
        if legacySpring?.state == .active { legacySpring?.stopAnimation(true) }
        legacySpring = nil
    }

    private func dismiss(_ messageID: UUID, towards offset: CGPoint? = nil, velocity: CGPoint = .zero) {
        guard current?.messageID == messageID, let card, card.isUserInteractionEnabled else { return }
        expiry?.cancel()
        card.isUserInteractionEnabled = false
        if let offset { settle(card, at: offset, velocity: velocity) }
        let fadeDuration = offset == nil || UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.24
        UIView.animate(withDuration: fadeDuration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            card.alpha = 0
        } completion: { [weak self] _ in
            guard let self, self.current?.messageID == messageID else { return }
            self.removeCard()
            self.showNext()
        }
    }

    private func open(_ notice: ReplyBannerNotice) {
        guard current?.messageID == notice.messageID, card?.isUserInteractionEnabled == true, let model, let window else { return }
        removeCard()
        defer { showNext() }
        guard canShow(notice.conversationID, in: window, model: model),
              model.conversation(for: notice.conversationID) != nil else { return }
        window.endEditing(true)
        if let sheet = Self.browsingSheets.first(where: { model[keyPath: $0] }) {
            model[keyPath: sheet] = false
        }
        // Closing an open drawer can already provide the same selection feedback.
        if !model.isDrawerPresented || !model.preferences.hapticsOnDrawer {
            model.performCardHaptic()
        }
        if !model.selectConversation(notice.conversationID, targeting: notice.messageID, closeDrawer: true) {
            model.selectConversation(notice.conversationID, closeDrawer: true)
        }
    }

    private func removeCard() {
        current = nil
        expiry?.cancel()
        expiry = nil
        stopLegacySpring()
        card?.removeFromSuperview()
        card = nil
        pull = nil
    }
}

@MainActor @Observable
private final class ReplyBannerPull {
    private(set) var target: CGSize = .zero
    private(set) var grip: UnitPoint = .center
    @ObservationIgnored private var start: CGSize = .zero

    func grab(at point: CGPoint, in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        start = target
        grip = UnitPoint(x: min(1, max(0, (point.x - bounds.minX) / bounds.width)),
                         y: min(1, max(0, (point.y - bounds.minY) / bounds.height)))
    }

    func drag(by delta: CGPoint) {
        target = CGSize(width: start.width + delta.x, height: start.height + delta.y)
    }
}

/// The fingertip updates immediately; only the trailing point is interpolated.
/// Their separation stretches the glass, then vanishes as the spring catches up.
private struct ReplyBannerStretch: GeometryEffect {
    let fingertip: CGSize
    var trailing: CGSize
    let grip: UnitPoint

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(trailing.width, trailing.height) }
        set { trailing = CGSize(width: newValue.first, height: newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = fingertip.width - trailing.width
        let dy = fingertip.height - trailing.height
        let distance = hypot(dx, dy)
        guard distance > 0.01, size.width > 0, size.height > 0 else {
            return ProjectionTransform(CGAffineTransform.identity)
        }
        let x = dx / distance, y = dy / distance
        let extensionLimit = min(42, size.height * 0.7)
        let extensionLength = extensionLimit * tanh(1.25 * distance / extensionLimit)
        // Measure strain relative to the two sides: a 20-point pull is much
        // more visible across a short banner's height than across its width.
        let relativeX = extensionLength * x / size.width
        let relativeY = extensionLength * y / size.height
        let strain = hypot(relativeX, relativeY)
        let axisX = relativeX / strain, axisY = relativeY / strain
        let stretch = 1 + strain
        let squash = max(0.96, 1 / sqrt(stretch))
        let difference = stretch - squash
        let a = squash + difference * axisX * axisX
        let d = squash + difference * axisY * axisY
        let slant = difference * axisX * axisY
        // An off-centre grip brings that side forward first. Limit the vertical
        // tilt of a wide card so both text lines remain on the glass.
        let tilt = (slant * size.height + extensionLength * y * (grip.x - 0.5)) / size.width
        let tiltLimit = size.height * 0.20 / size.width
        let b = min(tiltLimit, max(-tiltLimit, tilt))
        let sideShear = (slant * size.width + extensionLength * x * (grip.y - 0.5)) / size.height
        let c = min(0.28, max(-0.28, sideShear))
        let pivot = CGPoint(x: size.width * (grip.x + (1 + x) / 2) / 2,
                            y: size.height * (grip.y + (1 + y) / 2) / 2)
        return ProjectionTransform(CGAffineTransform(
            a: a, b: b, c: c, d: d,
            tx: pivot.x - a * pivot.x - c * pivot.y,
            ty: pivot.y - b * pivot.x - d * pivot.y
        ))
    }
}

private struct ReplyBannerMaterial: View {
    let pull: ReplyBannerPull
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    @ViewBuilder private var material: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            Color.clear.glassEffect(.regular.tint(Color(uiColor: .systemBackground).opacity(0.45)), in: shape)
        } else {
            shape.fill(Color(uiColor: .secondarySystemBackground))
                .overlay { shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
        }
    }

    var body: some View {
        if reduceMotion {
            material
        } else {
            let target = pull.target
            material
                .modifier(ReplyBannerStretch(fingertip: target, trailing: target, grip: pull.grip).ignoredByLayout())
                .animation(.spring(duration: 0.46, bounce: 0.25), value: target)
        }
    }
}

private struct ReplyBannerCard: View {
    let name: String
    let title: String
    let preview: String
    let assistant: AssistantProfile?
    let pull: ReplyBannerPull
    let open: () -> Void
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        HStack(spacing: 10) {
            if let assistant {
                AssistantAvatarView(profile: assistant, size: 30)
            } else {
                Image(systemName: "bubble.left.fill").frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: name).font(.subheadline.weight(.semibold))
                    Circle().fill(.tertiary).frame(width: 3, height: 3)
                    Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(verbatim: preview)
                    .font(.subheadline)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(shape)
        .background { ReplyBannerMaterial(pull: pull).allowsHitTesting(false) }
        // Touches use the mutually exclusive UIKit recognizers on the host.
        .accessibilityRepresentation {
            Button(action: open) {
                Text(verbatim: [name, title, preview].joined(separator: "，"))
            }
            .accessibilityHint(Text(L10n.lookup("打开这条回复所在的聊天")))
            .accessibilityAction(named: Text(L10n.lookup("关闭"))) { dismiss() }
            .accessibilityIdentifier("replyBanner.open")
        }
    }
}
