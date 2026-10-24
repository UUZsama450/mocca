// Appended only to the simulator test executable. Production files stay intact.
@MainActor enum Probe { static var oldBuilds = 0; static var newBuilds = 0 }
@MainActor private enum ControllerProbe {
    static var configurations: Set<String> = []
    static var duplicates = 0
    static func configured(_ cell: NativeChatCell, _ key: NativeChatRowKey, _ publication: AnyHashable) {
        let value = "\(cell.measurementHostID)|\(key.id)|\(key.revision)|\(publication)"
        if !configurations.insert(value).inserted { duplicates += 1 }
    }
}
@MainActor enum NativeReadingFixtures { static let requestedName: String? = nil }
@MainActor enum MessageTextViewportDrawing {
    // Synthetic Text rows have no product rich-text drawing surface.
    static func refreshAfterLayout(in view: UIView, visibleOnly: Bool) {}
}
@MainActor protocol TextSelectionAutoscrollHost: AnyObject {
    func selectionAutoscrollDidBegin()
    func selectionAutoscrollDidEnd()
}
@MainActor enum DrawerTextSelectionInteractionGate {
    static func cancelAutoscroll(in view: UIView) {}
}
struct CodeDisclosureLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor private extension NativeChatTranscriptController {
    var testedLayout: ReadingCollectionLayout { layout }
}

@MainActor private enum FooterChecks {
    static func run() {
        for count in [0, 1, 4, 120, 360] {
            for aligned in [false, true] {
                let keys = (0..<count).map { _ in NativeChatRowKey(id: UUID(), revision: 0) }
                var config = NativeChatLayoutConfiguration(top: 20, bottom: 110, gap: 10, alignShortContentToBottom: aligned)
                let old = LayoutHarness(BaselineReadingCollectionLayout(keys: keys, configuration: config))
                let new = LayoutHarness(ReadingCollectionLayout(keys: keys, configuration: config))
                for i in keys.indices { _ = old.measure(i, 45); _ = new.measure(i, 45) }
                for step in 0..<80 {
                    let before = keys.map { new.layout.frame(for: $0.id)! }
                    switch step % 8 {
                    case 0, 1, 2, 3: config.bottom = CGFloat(90 + step * 3)
                    case 4: config.top += 7
                    case 5: config.gap += 0.25
                    case 6: config.viewportInsets = UIEdgeInsets(top: 40, left: 0, bottom: 36, right: 0)
                    default: config.minimumIncludesTopInset.toggle()
                    }
                    let oc = old.update(configuration: config), nc = new.update(configuration: config)
                    LayoutChecks.compare("footer count=\(count) aligned=\(aligned) step=\(step)", old, new)
                    LayoutChecks.require(oc.contentSizeAdjustment == nc.contentSizeAdjustment, "footer content size delta")
                    LayoutChecks.require(oc.contentOffsetAdjustment == nc.contentOffsetAdjustment, "footer offset delta")
                    let invalidated = Set(nc.invalidatedItemIndexPaths ?? [])
                    for i in keys.indices where before[i] != new.layout.frame(for: keys[i].id)! {
                        LayoutChecks.require(invalidated.contains(IndexPath(item: i, section: 0)), "every moved row invalidated")
                    }
                    if !aligned && step % 8 < 4 && !ComposerLayoutWorkProbe.legacy {
                        LayoutChecks.require(invalidated.isEmpty, "footer-only has zero invalidated rows")
                    }
                }
                // Viewport / measured-height changes can move ALL short aligned rows.
                for viewport: CGFloat in [900, 430, 760] {
                    let before = keys.map { new.layout.frame(for: $0.id)! }
                    _ = old.update(height: viewport); let context = new.update(height: viewport)
                    LayoutChecks.compare("viewport", old, new)
                    for i in keys.indices where before[i] != new.layout.frame(for: keys[i].id)! {
                        LayoutChecks.require((context.invalidatedItemIndexPaths ?? []).contains(IndexPath(item: i, section: 0)), "viewport moved row invalidated")
                    }
                }
            }
        }
    }
}

@MainActor @Observable private final class MotionState {
    let identity = ComposerInputIdentity(conversationID: UUID(), resetRevision: 0)
    let driver = NativeChatScrollDriver()
    var height: CGFloat = 40
    var shell: CGFloat { height + 70 }
    var count: Int = 4
    var text = "中文输入测试"
    var focused = false
    var captureNativeHeight = false
    var measuredChanges = 0
    var compositionChanges = 0
    var submitted = 0
    func change(_ target: CGFloat, composition: Bool = false) {
        let change = ComposerInputHeightChange(identity: identity, previous: height, target: target, isCompositionEdit: composition)
        var transaction = Transaction(animation: change.resolvedAnimation)
        transaction.composerInputHeightChange = change
        withTransaction(transaction) { height = target }
    }
    func measure(_ value: CGFloat, edited: Bool, composition: Bool) {
        guard captureNativeHeight, abs(height-value)>0.5 else { return }
        measuredChanges += 1
        if composition { compositionChanges += 1 }
        if edited { change(value, composition: composition) } else { height = value }
    }
}
private struct TestShell: View {
    @Bindable var model: MotionState
    @Environment(\.composerHeightPresentation) var presentation
    var body: some View {
        ComposerNativeTextInput(text: $model.text, isFocused: $model.focused,
            placeholder: "中文输入", selectionColor: .systemBlue, enterToSend: false,
            identity: model.identity, onSubmit: { model.submitted += 1 }, onLongPaste: { _ in },
            onMeasuredHeight: { model.measure($0, edited: $1, composition: $2) })
            .frame(height: presentation?.inputHeight ?? model.height)
            .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(12)
    }
}
private struct MotionRoot: View {
    @Bindable var model: MotionState
    var body: some View {
        NativeChatTranscript(rows: (0..<model.count).map { i in
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i+1))!
            return NativeChatRow(id: id, revision: AnyHashable(0), content: AnyView(
                Text("消息 \(i) / Synthetic message").frame(maxWidth: .infinity).frame(height: 48)
                    .background(i.isMultiple(of: 2) ? Color.blue.opacity(0.1) : Color.green.opacity(0.1))
                    .background(GeometryReader { proxy in Color.clear.preference(key: NativeChatRowFramePreferenceKey.self,
                        value: [id: proxy.frame(in: .named("native-chat-row"))]) })
            ))
        }, configuration: .init(top: 20, bottom: ComposerHeightPresentation.bottomClearance(for: model.shell), gap: 10),
            publicationID: AnyHashable(0), sessionID: AnyHashable(model.identity.conversationID), driver: model.driver,
            hasEarlier: false, hasLater: false, initialBottom: false)
            .overlay(alignment: .bottom) { TestShell(model: model) }
            .modifier(ComposerHeightAnimation(identity: model.identity, inputHeight: model.height,
                targetInputHeight: model.height, targetShellHeight: model.shell))
    }
}

@MainActor private final class FrameSampler: NSObject {
    var link: CADisplayLink?
    var timestamps: [Double] = []
    var offsets: [Double] = []
    var heights: [Double] = []
    var bottomGaps: [Double] = []
    var anchorPositions: [Double] = []
    var anchor: (() -> CGFloat?)?
    weak var scroll: UIScrollView?
    func start(_ scroll: UIScrollView?) {
        self.scroll = scroll; timestamps = []; offsets = []; heights = []; bottomGaps = []; anchorPositions = []
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
    }
    @objc func tick(_ link: CADisplayLink) {
        guard timestamps.count < 600 else { stop(); return }
        timestamps.append(link.timestamp)
        offsets.append(Double(scroll?.layer.presentation()?.bounds.origin.y ?? scroll?.contentOffset.y ?? 0))
        heights.append(Double(scroll?.contentSize.height ?? 0))
        if let scroll {
            let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)
            bottomGaps.append(Double(bottom-scroll.contentOffset.y))
            if let position = anchor?() { anchorPositions.append(Double(position-scroll.contentOffset.y)) }
        }
    }
    func stop() { link?.invalidate(); link = nil }
    var result: [String: Any] {
        let intervals = zip(timestamps.dropFirst(), timestamps).map { ($0-$1)*1000 }
        return ["callbackIntervalsMs": intervals, "offsets": offsets, "contentHeights": heights,
            "bottomGaps": bottomGaps, "anchorPositions": anchorPositions,
            "maxIntervalMs": intervals.max() ?? 0, "sampleCount": timestamps.count]
    }
}

@main @MainActor final class ComposerLayoutProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var cases: [[String: Any]] = []
    var failures: [String] = []
    var checks = 0
    func expect(_ ok: Bool, _ name: String) { checks += 1; if !ok { failures.append(name) } }
    func wait(_ milliseconds: Int = 240) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
        Task { await run() }
        return true
    }
    func editor(in view: UIView) -> ComposerInputTextView? {
        if let editor = view as? ComposerInputTextView { return editor }
        return view.subviews.compactMap { editor(in: $0) }.first
    }
    func scenario(count: Int, history: Bool, chinese: Bool = false) async {
        let model = MotionState(); model.count = count
        let host = UIHostingController(rootView: MotionRoot(model: model))
        window!.rootViewController = host; window!.makeKeyAndVisible()
        await wait(500)
        guard let controller = model.driver.controller else { expect(false, "mounted controller"); return }
        let scroll = controller.collection
        if history {
            model.driver.releasePosition(userOwned: true)
            scroll.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        } else {
            model.driver.armBottomPin()
            scroll.setContentOffset(CGPoint(x: 0, y: controller.testedLayout.offset(for: .bottom) ?? 0), animated: false)
        }
        await wait(300)
        let initialOffset = scroll.contentOffset.y
        let ids = controller.testedLayout.keys.map(\.id)
        let before = ids.map { controller.testedLayout.frame(for: $0)! }
        let sampler = FrameSampler()
        let anchorID = controller.testedLayout.viewportAnchor()
        sampler.anchor = { anchorID.flatMap { controller.testedLayout.frame(for: $0)?.minY } }
        ComposerLayoutWorkProbe.reset()
        ControllerProbe.configurations = []; ControllerProbe.duplicates = 0
        sampler.start(scroll)
        if chinese {
            model.captureNativeHeight = true; model.focused = true
            await wait(400)
            guard let input = editor(in: host.view) else { expect(false, "native editor mounted"); sampler.stop(); return }
            for _ in 0..<4 {
                input.setMarkedText("中文连续输入候选测试测试测试测试测试测试", selectedRange: NSRange(location: 20, length: 0))
                await wait(55)
                input.unmarkText()
                input.insertText("\n")
                await wait(75)
            }
            await wait(350)
            expect(input.markedTextRange == nil, "IME commit cleared marked range")
            expect(input.text.contains("\n"), "Chinese newlines preserved")
            expect(model.submitted == 0, "newline did not send")
            expect(model.measuredChanges > 0, "native editing drove height changes")
            model.focused = false
        } else {
            for height: CGFloat in [80, 120, 60, 40] {
                model.change(height)
                await wait(230)
            }
        }
        sampler.stop()
        let counts = ComposerLayoutWorkProbe.counts
        let times = ComposerLayoutWorkProbe.milliseconds
        let maxima = ComposerLayoutWorkProbe.maxima
        await wait(300)
        let after = ids.map { controller.testedLayout.frame(for: $0)! }
        // Keyboard dismissal can expose an unmeasured row (240pt estimate).
        // Permit only its real 48pt fixture measurement and the exact prefix
        // displacement it causes. Already measured row sizes must stay fixed.
        var prefixDelta: CGFloat = 0
        var newlyMeasuredRows = 0
        for i in ids.indices {
            expect(abs(after[i].minY-before[i].minY-prefixDelta)<0.01, "row position accounts only for accepted measurement")
            expect(after[i].width == before[i].width, "message width unchanged")
            if abs(after[i].height-before[i].height)>0.01 {
                expect(abs(before[i].height-240)<0.01 && abs(after[i].height-48)<0.01, "only estimated rows acquire actual fixture height")
                newlyMeasuredRows += 1
            }
            prefixDelta += after[i].height-before[i].height
        }
        if history { expect(abs(scroll.contentOffset.y-initialOffset)<0.5, "history offset retained") }
        else { expect(abs(scroll.contentOffset.y-(controller.testedLayout.offset(for: .bottom) ?? 0))<1, "bottom follows footer") }
        if !chinese {
            if history {
                expect((sampler.anchorPositions.max() ?? 0)-(sampler.anchorPositions.min() ?? 0)<0.5, "history anchor stable throughout animation")
            } else {
                expect(sampler.bottomGaps.allSatisfy { abs($0)<1 }, "bottom attached throughout animation")
            }
            expect((counts["controller"] ?? 0)>8, "interpolated updates observed")
            expect(ControllerProbe.duplicates == 0, "unchanged hosts not reconfigured")
            if !ComposerLayoutWorkProbe.legacy {
                expect((counts["layout.fullItemInvalidation"] ?? 0)==0, "motion has no full item invalidation")
                expect((counts["cell.refreshPass"] ?? 0)==0, "motion has no visible refresh scan")
            }
        }
        cases.append(["name": "rows\(count)-\(history ? "history" : "bottom")-\(chinese ? "chinese" : "motion")",
            "counts": counts, "duplicateConfigurations": ControllerProbe.duplicates, "inclusiveMainThreadMs": times, "maxScopeMs": maxima,
            "frames": sampler.result, "initialOffset": initialOffset, "finalOffset": scroll.contentOffset.y,
            "nativeHeightChanges": model.measuredChanges, "compositionChanges": model.compositionChanges,
            "newlyMeasuredRows": newlyMeasuredRows])
        controller.detach()
    }
    func run() async {
        LayoutChecks.semantics(); FooterChecks.run()
        for count in [4, 120, 360] { await scenario(count: count, history: false) }
        await scenario(count: 120, history: true)
        await scenario(count: 120, history: false, chinese: true)
        await scenario(count: 120, history: true, chinese: true)
        failures += LayoutChecks.failures
        let report: [String: Any] = ["status": failures.isEmpty ? "PASS" : "FAIL", "checks": checks+LayoutChecks.assertions,
            "failures": failures, "cases": cases]
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: folder.appendingPathComponent("composer-layout-result.json"), options: .atomic)
        print("COMPOSER_LAYOUT_RESULT \(report["status"]!) \(checks+LayoutChecks.assertions)")
        fflush(stdout); exit(failures.isEmpty ? 0 : 1)
    }
}
