import XCTest
import SwiftUI
import Observation
@testable import Mocca

private struct HeightTarget {
    let previous: CGFloat
    let target: CGFloat
    var delta: CGFloat { target - previous }
}

@MainActor @Observable private final class IndependentMotionState {
    let model = AppModel()
    let driver = NativeChatScrollDriver()
    var input: (identity: ComposerInputIdentity, height: CGFloat)?
    var shell: CGFloat = 110
    @ObservationIgnored var presentedShell: CGFloat = 0
    var changes: [HeightTarget] = []
    let rowIDs: [UUID]
    init(enabled: Bool, count: Int) {
        rowIDs = (0..<count).map { _ in UUID() }
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
            ComposerView(inputHeight: .init(get: { state.input }, set: { state.input = $0 }),
                onInputHeightChange: { change in
                    state.changes.append(HeightTarget(previous: (state.input?.height ?? 0) - change, target: state.input?.height ?? 0))
                    state.shell += change
                }, onMeasuredHeight: { height in
                    if height > 0, abs(state.shell - height) > 0.5 { state.shell = height }
                })
                .environment(\.composerHeightPresentation, nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.presentedShell = $0 }
        }
        .modifier(ComposerShellGeometry(identity: state.input?.identity,
            shellHeight: state.shell, targetShellHeight: state.shell, additionalMessageClearance: messageClearance))
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
                     count: Int = 20, chinese: Bool = false) async throws {
        let state = IndependentMotionState(enabled: enabled, count: count)
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
        XCTAssertTrue(interiorEditor.isEmpty, "Editor must reach the target directly for either legacy preference")
        XCTAssertFalse(state.changes.isEmpty)
        if history {
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - offset) < 1 })
        } else {
            let endOffset = scroll.contentOffset.y
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - offset) < 1 || abs($0["offset"]! - endOffset) < 1 }, "Transcript must reach the target directly")
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["gap"]!) < 1 })
        }
        let data = try JSONSerialization.data(withJSONObject: sampler.samples, options: [.sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "motion-enabled-\(enabled)-history-\(history)-chinese-\(chinese)"
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
        let end = state.presentedShell
        XCTAssertTrue(sampler.samples.allSatisfy { $0["shell"]! <= end + 1 || $0["shell"]! >= grown - 1 }, "Shrink also lands immediately")
        if history {
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - offset) < 1 })
        } else {
            let endOffset = scroll.contentOffset.y
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - grownOffset) < 1 || abs($0["offset"]! - endOffset) < 1 })
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["gap"]!) < 1 })
        }
        let shrink = XCTAttachment(data: try JSONSerialization.data(withJSONObject: sampler.samples, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        shrink.name = (evidence.name ?? "motion") + "-shrink"; shrink.lifetime = .keepAlways; add(shrink)
        editor.resignFirstResponder()
    }
    func testLegacyEnabledIsImmediate() async throws { try await runScenario(enabled: true) }
    func testLegacyDisabledIsImmediate() async throws { try await runScenario(enabled: false) }
    func testDisabledEditorPreservesHistory() async throws { try await runScenario(enabled: false, history: true) }
    func testSingleShortMessage() async throws { try await runScenario(enabled: false, count: 1) }
    func testShortConversation() async throws { try await runScenario(enabled: false, count: 2) }
    func testChineseCompositionWithEditorAnimationOff() async throws { try await runScenario(enabled: false, chinese: true) }

    private func markedBoundary(history: Bool) async throws {
        let state = IndependentMotionState(enabled: false, count: 20)
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
        editor.insertText("我想静静啊啊啊大大的个人")
        await settle(0.3)
        let initial = editor.composerSize(fitting: editor.bounds.width).height
        var shorter = "", longer = ""
        for length in 1...80 {
            let value = String(String(repeating: "aajebskxkdsx", count: 8).prefix(length))
            editor.setMarkedText(value, selectedRange: NSRange(location: length, length: 0))
            await settle(0.03)
            if editor.composerSize(fitting: editor.bounds.width).height > initial {
                longer = value
                break
            }
            shorter = value
        }
        XCTAssertFalse(shorter.isEmpty)
        XCTAssertFalse(longer.isEmpty)
        editor.setMarkedText(shorter, selectedRange: NSRange(location: shorter.utf16.count, length: 0))
        await settle(0.4)
        let scroll = try XCTUnwrap(state.driver.scrollView)
        if history {
            state.driver.releasePosition(userOwned: true)
            scroll.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        } else {
            state.driver.armBottomPin()
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        }
        await settle()
        let offset = scroll.contentOffset.y
        state.changes = []
        let sampler = IndependentFrameSampler()
        sampler.start(editor: editor, scroll: scroll)
        for index in 0..<20 {
            let value = index.isMultiple(of: 2) ? longer : shorter
            editor.setMarkedText(value, selectedRange: NSRange(location: value.utf16.count, length: 0))
            await settle(0.07)
            XCTAssertNotNil(editor.markedTextRange)
            XCTAssertEqual(editor.text, "我想静静啊啊啊大大的个人" + value)
            XCTAssertEqual(editor.bounds.height, try XCTUnwrap(state.input?.height), accuracy: 0.5)
        }
        await settle(0.4)
        sampler.stop()
        XCTAssertEqual(state.changes.count, 20, "Every native height target remains immediate")
        let heights = Set(state.changes.map(\.target))
        XCTAssertEqual(heights.count, 2)
        XCTAssertTrue(sampler.samples.allSatisfy { sample in
            heights.contains { abs($0 - sample["nativeEditor"]!) < 0.5 }
        }, "Disabled editor must never interpolate between line heights")
        if history {
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["offset"]! - offset) < 1 })
        } else {
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["gap"]!) < 1 }, "Retargeted messages stay attached")
        }
        // Several native callbacks can arrive before the next SwiftUI body.
        // Each height delta must use the preceding edit's live target.
        let previousTarget = try XCTUnwrap(state.input?.height)
        let previousShell = state.shell
        state.changes = []
        for value in [longer, shorter, longer] {
            editor.setMarkedText(value, selectedRange: NSRange(location: value.utf16.count, length: 0))
        }
        let actualTarget = editor.composerSize(fitting: editor.bounds.width).height
        XCTAssertEqual(state.changes.count, 3)
        XCTAssertEqual(try XCTUnwrap(state.input?.height), actualTarget, accuracy: 0.5)
        XCTAssertEqual(state.shell, previousShell + actualTarget - previousTarget, accuracy: 0.5)
        for pair in zip(state.changes, state.changes.dropFirst()) {
            XCTAssertEqual(pair.0.target, pair.1.previous, accuracy: 0.5)
        }
        await settle(0.4)
        for enabled in [true, false] {
            state.model.preferences.composerHeightAnimationEnabled = enabled
            await settle(0.1)
            XCTAssertTrue(nativeEditor(host.view) === editor, "Changing the environment keeps native editor identity")
            XCTAssertTrue(editor.isFirstResponder)
            XCTAssertNotNil(editor.markedTextRange)
        }
        editor.resignFirstResponder()
    }
    func testRepeatedPinyinWrapWithEditorAnimationOff() async throws { try await markedBoundary(history: false) }
    func testRepeatedPinyinWrapPreservesHistory() async throws { try await markedBoundary(history: true) }

    private func mixedTextSingleGrowth(enabled: Bool) async throws {
        let state = IndependentMotionState(enabled: enabled, count: 20)
        state.model.preferences.enterToSendOnMobile = false
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
        let prefix = "好奇捏(´▽｀)宝宝…肿瘤科 "
        editor.insertText(prefix)
        await settle()
        let initial = editor.composerSize(fitting: editor.bounds.width).height
        var shorter = "", longer = ""
        for length in 1...80 {
            let value = String(String(repeating: "yeyouzijidedaa", count: 8).prefix(length))
            editor.setMarkedText(value, selectedRange: NSRange(location: value.utf16.count, length: 0))
            await settle(0.03)
            if editor.composerSize(fitting: editor.bounds.width).height > initial {
                longer = value; break
            }
            shorter = value
        }
        XCTAssertFalse(longer.isEmpty)
        editor.setMarkedText(shorter, selectedRange: NSRange(location: shorter.utf16.count, length: 0))
        await settle(0.5)
        let scroll = try XCTUnwrap(state.driver.scrollView)
        state.driver.armBottomPin()
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
        await settle()
        for returnKey in [false, true] {
            if returnKey { editor.unmarkText(); await settle() }
            let oldInput = try XCTUnwrap(state.input?.height)
            let oldShell = state.shell
            state.changes = []
            let sampler = IndependentFrameSampler()
            sampler.shellHeight = { state.presentedShell }
            sampler.start(editor: editor, scroll: scroll)
            if returnKey { editor.insertText("\n") }
            else { editor.setMarkedText(longer, selectedRange: NSRange(location: longer.utf16.count, length: 0)) }
            await settle(0.55)
            sampler.stop()
            XCTAssertEqual(state.changes.count, 1, "One wrap or Return must publish one height target")
            let change = try XCTUnwrap(state.changes.first)
            XCTAssertEqual(change.previous, oldInput, accuracy: 0.5)
            XCTAssertGreaterThan(change.delta, 15)
            XCTAssertEqual(state.shell, oldShell + change.delta, accuracy: 0.5,
                           "The measured shell must not add a second growth")
            XCTAssertEqual(editor.text, prefix + longer + (returnKey ? "\n" : ""))
            XCTAssertEqual(editor.markedTextRange != nil, !returnKey)
            XCTAssertTrue(editor.isFirstResponder)
            XCTAssertTrue(nativeEditor(host.view) === editor)
            XCTAssertTrue(sampler.samples.allSatisfy { abs($0["gap"]!) < 1 })
            for pair in zip(sampler.samples, sampler.samples.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1["offset"]! + 0.5, pair.0["offset"]!,
                                            "A single growth must not reverse the transcript")
            }
        }
        editor.resignFirstResponder()
    }

    func testMixedTextWithLegacyPreferenceEnabled() async throws { try await mixedTextSingleGrowth(enabled: true) }
    func testMixedTextWrapAndReturnWithImmediateEditor() async throws { try await mixedTextSingleGrowth(enabled: false) }
}
