// Appended only to the isolated QA app's entry point.
import Observation

@MainActor @Observable private final class GroupMotionFixtureState {
    let model = AppModel()
    let driver = NativeChatScrollDriver()
    let rows = (0..<20).map { _ in UUID() }
    var input: (identity: ComposerInputIdentity, height: CGFloat)?
    var shell: CGFloat = 110
    @ObservationIgnored var presentedShell: CGFloat = 0
    var report = "{}"
    let history = ProcessInfo.processInfo.arguments.contains("-groupHistory")
    var event = 0
    @ObservationIgnored var capture: GroupMotionFrameCapture?
    init() {
        let members = [AssistantProfile(name: "QA One"), AssistantProfile(name: "QA Two")]
        model.assistants += members
        let conversation = Conversation(title: "Group motion QA", groupAssistantIDs: members.map { $0.id.uuidString })
        model.conversations.append(conversation)
        model.selectedConversationID = conversation.id
        model.preferences.composerHeightAnimationEnabled = ProcessInfo.processInfo.arguments.contains("-editorMotionOn")
        model.preferences.enterToSendOnMobile = false
        model.draft = ""
    }
    func shellChanged(_ delta: CGFloat) {
        event += 1
        report = "{}"
        capture?.stop()
        let capture = GroupMotionFrameCapture()
        self.capture = capture
        capture.start(state: self, event: event, delta: delta)
        shell += delta
    }
    func prepare() async {
        for _ in 0..<100 {
            if driver.scrollView != nil && input != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard let scroll = driver.scrollView else { return }
        if history {
            driver.releasePosition(userOwned: true)
            scroll.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        } else {
            driver.armBottomPin()
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        }
        report = "{\"ready\":true}"
    }
}
@MainActor private final class GroupMotionFrameCapture: NSObject {
    weak var state: GroupMotionFixtureState?
    var event = 0
    var delta: CGFloat = 0
    var initialShell: CGFloat = 0
    var initialOffset: CGFloat = 0
    var frames: [[String: Double]] = []
    var link: CADisplayLink?
    func start(state: GroupMotionFixtureState, event: Int, delta: CGFloat) {
        self.state = state; self.event = event; self.delta = delta
        initialShell = state.presentedShell
        initialOffset = state.driver.scrollView?.contentOffset.y ?? 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link; link.add(to: .main, forMode: .common)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            self?.finish()
        }
    }
    @objc func tick() {
        guard let state, let scroll = state.driver.scrollView else { return }
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        frames.append(["t": CACurrentMediaTime(), "shell": state.presentedShell,
                       "offset": scroll.contentOffset.y, "gap": bottom - scroll.contentOffset.y])
    }
    func stop() { link?.invalidate(); link = nil }
    func finish() {
        guard link != nil else { return }
        stop()
        guard let state, state.event == event else { return }
        let value: [String: Any] = ["event": event, "delta": delta, "initialShell": initialShell,
            "finalShell": state.presentedShell, "initialOffset": initialOffset,
            "finalOffset": state.driver.scrollView?.contentOffset.y ?? 0, "frames": frames]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { state.report = json }
    }
}
private struct GroupComposerTestRoot: View {
    @State private var state = GroupMotionFixtureState()
    var body: some View {
        NativeChatTranscript(rows: state.rows.enumerated().map { index, id in
            NativeChatRow(id: id, revision: 0, content: AnyView(
                Text("Group message \(index)").frame(maxWidth: .infinity).frame(height: 240)
            ))
        }, configuration: .init(top: 20, bottom: ComposerHeightPresentation.bottomClearance(for: state.shell), gap: 10),
            publicationID: 0, sessionID: AnyHashable(state.model.selectedConversationID), driver: state.driver,
            hasEarlier: false, hasLater: false, initialBottom: false)
        .overlay(alignment: .bottom) {
            ComposerView(inputHeight: .init(get: { state.input }, set: { state.input = $0 }),
                onInputHeightChange: { state.shell += $0 },
                onShellHeightChange: state.shellChanged,
                onMeasuredHeight: { height in
                    if height > 0, abs(state.shell - height) > 0.5 { state.shell = height }
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.presentedShell = $0 }
        }
        .modifier(ComposerShellGeometry(identity: state.input?.identity,
            shellHeight: state.shell, targetShellHeight: state.shell, additionalMessageClearance: 0))
        .overlay(alignment: .top) {
            Text("Motion report").accessibilityIdentifier("groupMotion.report").accessibilityValue(state.report)
        }
        .environment(state.model)
        .task { await state.prepare() }
    }
}
