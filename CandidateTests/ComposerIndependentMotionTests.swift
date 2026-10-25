import XCTest
import SwiftUI
import Observation
@testable import Mocca

@MainActor @Observable private final class IndependentMotionState {
    let model = AppModel()
    let driver = NativeChatScrollDriver()
    var input: (identity: ComposerInputIdentity, height: CGFloat)?
    var shell: CGFloat = 110
    @ObservationIgnored var presentedShell: CGFloat = 0
    var changes: [ComposerInputHeightChange] = []
    let rowIDs: [UUID]
    let allowsMotion: Bool
    init(enabled: Bool, count: Int, allowsMotion: Bool) {
        rowIDs = (0..<count).map { _ in UUID() }
        self.allowsMotion = allowsMotion
        model.preferences.composerHeightAnimationEnabled = enabled
        model.preferences.enterToSendOnMobile = false
        model.draft = ""
    }
}

private struct IndependentMotionRoot: View {
    @Bindable var state: IndependentMotionState
    private var messageClearance: CGFloat {
        min(32, ceil(AppFontStore.uiFont(postScriptName: state.model.preferences.appFontPostScriptName,
                                       size: 18 * CGFloat(state.model.preferences.chatFontScale)).lineHeight))
    }
    var body: some View {
        NativeChatTranscript(rows: state.rowIDs.enumerated().map { index, id in
            NativeChatRow(id: id, revision: 0, content: AnyView(
                Text("Synthetic message \(index)").frame(maxWidth: .infinity).frame(height: 240)
            ))
        }, configuration: .init(top: 20, bottom: ComposerHeightPresentation.bottomClearance(
            for: state.shell, additionalMessageClearance: messageClearance), gap: 10),
            publicationID: 0, sessionID: AnyHashable(state.model.selectedConversationID),
            driver: state.driver, hasEarlier: false, hasLater: false, initialBottom: false)
        .overlay(alignment: .bottom) {
            ComposerView(inputHeight: $state.input, allowsHeightAnimation: state.allowsMotion,
                onInputHeightChange: { change in
                    state.changes.append(change)
                    state.shell += change.delta
                }, onMeasuredHeight: { height in
                    if height > 0, abs(state.shell - height) > 0.5 { state.shell = height }
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.presentedShell = $0 }
        }
        .modifier(ComposerHeightAnimation(identity: state.input?.identity,
            inputHeight: state.input?.height ?? 0, targetInputHeight: state.input?.height ?? 0,
            targetShellHeight: state.shell, additionalMessageClearance: messageClearance))
        .environment(state.model)
    }
}

@MainActor private final class IndependentFrameSampler: NSObject {
    weak var editor: UIView?
    weak var scroll: UIScrollView?
    var samples: [[String: Double]] = []
    var shellHeight: (() -> CGFloat)?
    private var link: CADisplayLink?
    func start(editor: UIView, scroll: UIScrollView) {
        self.editor = editor; self.scroll = scroll
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick() {
        guard let editor, let scroll else { return }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        samples.append(["t": CACurrentMediaTime(), "shell": shellHeight?() ?? 0, "nativeEditor": editor.bounds.height,
                        "offset": scroll.contentOffset.y, "gap": bottom - scroll.contentOffset.y])
    }
    func stop() { link?.invalidate(); link = nil }
}

@MainActor final class ComposerIndependentMotionTests: XCTestCase {
    func nativeEditor(_ view: UIView) -> ComposerInputTextView? {
        if let editor = view as? ComposerInputTextView { return editor }
        return view.subviews.lazy.compactMap { self.nativeEditor($0) }.first
    }
    func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
    func runScenario(enabled: Bool, history: Bool = false,
                     allowsMotion: Bool = true, count: Int = 20, chinese: Bool = false) async throws {
        let state = IndependentMotionState(enabled: enabled, count: count, allowsMotion: allowsMotion)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: IndependentMotionRoot(state: state))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await settle(0.5)
        let editor = try XCTUnwrap(nativeEditor(host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        await settle(0.7)
        let scroll = try XCTUnwrap(state.driver.scrollView)
        if history {
            state.driver.releasePosition(userOwned: true)
            scroll.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        } else {
            state.driver.armBottomPin()
            let bottom = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
        await settle()
        let initial = state.presentedShell
        let offset = scroll.contentOffset.y
        state.changes = []
        let sampler = IndependentFrameSampler()
        sampler.shellHeight = { state.presentedShell }
        sampler.start(editor: editor, scroll: scroll)
        let text = chinese ? "中文候选换行\n第二行测试\n第三行" : "Line one\nLine two\nLine three\nLine four"
        if chinese {
            editor.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            await settle(0.06)
            editor.unmarkText()
        } else {
            editor.insertText(text)
        }
        await settle(0.45)
        sampler.stop()
        XCTAssertTrue(editor.text.contains(chinese ? "中文" : "Line one"))
        XCTAssertNil(editor.markedTextRange)
        let final = state.presentedShell
        XCTAssertGreaterThan(final, initial + 20)
        let interiorEditor = sampler.samples.filter { $0["shell"]! > initial + 1 && $0["shell"]! < final - 1 }
        let shouldAnimate = allowsMotion
        if enabled && shouldAnimate {
            XCTAssertGreaterThan(interiorEditor.count, 1, "Enabled editor still interpolates")
        } else {
            XCTAssertTrue(interiorEditor.isEmpty, "Disabled editor must jump directly to its target")
        }
        XCTAssertEqual(state.changes.isEmpty, !shouldAnimate, "Shared motion respects owner guards")
        if history {
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - offset) < 1 }, "History stays in place throughout")
        } else if shouldAnimate && count > 2 {
            let endOffset = scroll.contentOffset.y
            let middle = sampler.samples.filter { $0["offset"]! > offset + 1 && $0["offset"]! < endOffset - 1 }
            XCTAssertGreaterThan(middle.count, 1, "Messages must interpolate even with editor animation off")
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["gap"]!) < 1 }, "Bottom remains attached to interpolated clearance")
        }
        let data = try JSONSerialization.data(withJSONObject: sampler.samples, options: [.sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "motion-enabled-\(enabled)-history-\(history)-allowed-\(allowsMotion)-chinese-\(chinese)"
        evidence.lifetime = .keepAlways; add(evidence)
        // Exercise the native deletion path too, without changing the draft externally.
        let grown = state.presentedShell
        let grownOffset = scroll.contentOffset.y
        sampler.samples = []; sampler.start(editor: editor, scroll: scroll)
        editor.selectedRange = NSRange(location: 0, length: editor.text.utf16.count)
        editor.insertText("")
        await settle(0.4); sampler.stop()
        XCTAssertEqual(editor.text, "")
        XCTAssertLessThan(state.presentedShell, grown - 20)
        if !enabled || !shouldAnimate {
            let end = state.presentedShell
            XCTAssertTrue(sampler.samples.allSatisfy { $0["shell"]! <= end + 1 || $0["shell"]! >= grown - 1 }, "Shrink also lands immediately")
        }
        if history {
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - offset) < 1 }, "History remains stable while shrinking")
        } else if shouldAnimate && count > 2 {
            let endOffset = scroll.contentOffset.y
            XCTAssertGreaterThan(sampler.samples.filter { $0["offset"]! < grownOffset - 1 && $0["offset"]! > endOffset + 1 }.count, 1,
                                 "Messages also interpolate while the editor shrinks")
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["gap"]!) < 1 })
        }
        let shrink = XCTAttachment(data: try JSONSerialization.data(withJSONObject: sampler.samples, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        shrink.name = (evidence.name ?? "motion") + "-shrink"; shrink.lifetime = .keepAlways; add(shrink)
        editor.resignFirstResponder()
    }
    func testEnabledStillAnimatesBoth() async throws { try await runScenario(enabled: true) }
    func testDisabledEditorKeepsMessageMotion() async throws { try await runScenario(enabled: false) }
    func testDisabledEditorPreservesHistory() async throws { try await runScenario(enabled: false, history: true) }
    func testBusyOwnerStillSuppressesHeightMotion() async throws { try await runScenario(enabled: false, allowsMotion: false) }
    func testShortConversation() async throws { try await runScenario(enabled: false, count: 2) }
    func testChineseCompositionWithEditorAnimationOff() async throws { try await runScenario(enabled: false, chinese: true) }
}
