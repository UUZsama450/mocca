// Concatenated with the unchanged full NativeChatTranscript.swift in a simulator host.
@MainActor enum NativeReadingFixtures { static let requestedName: String? = nil }
struct CodeDisclosureLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor private extension NativeChatTranscriptController {
    func sample(_ target: NativeChatScrollTarget, id: UUID) -> [String: Any] {
        let frame = layout.frame(for: id)
        let measured = rowByID[id].map { layout.isMeasured(.init(id: id, revision: $0.revision)) } ?? false
        let cell = collection.visibleCells.compactMap { $0 as? NativeChatCell }.first { $0.configuredKey?.id == id }
        let shownBottom = cell?.layer.presentation().flatMap { layer in
            collection.layer.presentation().map { layer.frame.maxY - $0.bounds.minY }
        }
        return ["shownBottom": shownBottom ?? -99999, "hasPresentation": shownBottom != nil,
                "offset": collection.contentOffset.y,
                "desired": layout.offset(for: target) ?? -99999,
                "bottom": (frame?.maxY ?? 0) - collection.contentOffset.y,
                "measured": measured, "visible": geometry().frames[id] != nil,
                "publication": String(describing: input.publicationID),
                "batch": batchID != nil, "accepted": input.mutationLanding != nil]
    }
}

@MainActor private final class FrameObserver: NSObject {
    var action: () -> Void = {}
    var link: CADisplayLink?
    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() { action() }
}

@main @MainActor final class HarnessApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var results: [[String: Any]] = []
    var failures: [String] = []
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        Task { await run() }
        return true
    }
    func wait(_ seconds: Double = 0.3) async { try? await Task.sleep(for: .seconds(seconds)) }
    func row(_ id: UUID, height: CGFloat) -> NativeChatRow {
        NativeChatRow(id: id, revision: AnyHashable(height), content: AnyView(
            VStack { Text("START \(id.uuidString.prefix(4))"); Spacer(); Text("END") }
                .frame(height: height).frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .background(GeometryReader { p in
                    Color.clear.preference(key: NativeChatRowFramePreferenceKey.self,
                        value: [id: p.frame(in: .named("native-chat-row"))])
                })
        ))
    }
    func check(_ name: String, oldHeight: CGFloat, newHeight: CGFloat, tail: Bool, exactBottom: Bool) async {
        let driver = NativeChatScrollDriver()
        let previous = UUID(), oldID = UUID(), newID = UUID(), after = UUID()
        var rows = [row(previous, height: 1700), row(oldID, height: oldHeight)]
        if !tail { rows.append(row(after, height: 1600)) }
        var input = NativeChatTranscript(rows: rows,
            configuration: NativeChatLayoutConfiguration(top: 90, bottom: 140),
            publicationID: AnyHashable(0), sessionID: AnyHashable(name), driver: driver,
            hasEarlier: false, hasLater: false)
        let controller = NativeChatTranscriptController(input: input)
        window?.rootViewController = controller; window?.makeKeyAndVisible()
        await wait()
        let edge: CGFloat = tail ? (window!.bounds.height - 140) : 560
        let oldTarget: NativeChatScrollTarget = exactBottom ? .bottom : .rowBottom(oldID, edge)
        _ = await driver.scrollAndWait(to: oldTarget, duration: 0)
        await wait()
        let target: NativeChatScrollTarget = exactBottom ? .bottom : .rowBottom(newID, edge)
        var current = true
        input.mutationLanding = NativeChatMutationLanding(requestID: UUID(), sourcePublicationID: AnyHashable(0),
            destinationPublicationID: AnyHashable(1), scrollViewIdentity: ObjectIdentifier(driver.scrollView!),
            removedID: oldID, targetID: newID, isReplacement: true, target: target, isCurrent: { current })
        rows[1] = row(newID, height: newHeight); input.rows = rows; input.publicationID = AnyHashable(1)
        var samples: [[String: Any]] = []
        let observer = FrameObserver()
        observer.action = { samples.append(controller.sample(target, id: newID)) }
        observer.start(); controller.update(input)
        await wait(0.6); observer.stop()
        let final = controller.sample(target, id: newID)
        let invalid = samples.filter {
            ($0["publication"] as? String) == "1" && (
                abs(($0["offset"] as! CGFloat) - ($0["desired"] as! CGFloat)) > 2
                || (($0["hasPresentation"] as! Bool) && abs(($0["shownBottom"] as! CGFloat) - ($0["bottom"] as! CGFloat)) > 2))
        }
        if invalid.count > 0 { failures.append(name + " intermediate frames: \(invalid.count)") }
        if !(final["visible"] as! Bool) { failures.append(name + " target invisible") }
        if abs((final["offset"] as! CGFloat) - (final["desired"] as! CGFloat)) > 2 { failures.append(name + " wrong final offset") }
        results.append(["name":name,"oldHeight":oldHeight,"newHeight":newHeight,"samples":samples,"final":final])
        current = false
        controller.detach()
    }
    func checkAdmission(_ mode: String) async {
        let driver = NativeChatScrollDriver()
        let before = UUID(), oldID = UUID(), first = UUID(), second = UUID(), after = UUID()
        var rows = [row(before, height: 1700), row(oldID, height: 2200), row(after, height: 1500)]
        var input = NativeChatTranscript(rows: rows, configuration: .init(top: 90, bottom: 140),
            publicationID: AnyHashable(0), sessionID: AnyHashable(mode), driver: driver,
            hasEarlier: false, hasLater: false)
        let controller = NativeChatTranscriptController(input: input)
        window?.rootViewController = controller; window?.makeKeyAndVisible()
        await wait()
        _ = await driver.scrollAndWait(to: .rowBottom(oldID, 560), duration: 0)
        await wait()
        driver.releasePosition()
        var firstCurrent = true
        var rejected = 0
        let deletion = mode == "deletion"
        let target: NativeChatScrollTarget = deletion ? .row(after, .top) : .rowBottom(first, 560)
        input.mutationLanding = NativeChatMutationLanding(requestID: UUID(),
            sourcePublicationID: AnyHashable(mode == "stalePublication" ? -1 : 0),
            destinationPublicationID: AnyHashable(1), scrollViewIdentity: ObjectIdentifier(driver.scrollView!),
            removedID: oldID, targetID: deletion ? after : first, isReplacement: !deletion, target: target,
            onRejected: { rejected += 1; firstCurrent = false }, isCurrent: { firstCurrent })
        if deletion { rows.remove(at: 1) } else { rows[1] = row(first, height: 140) }
        input.rows = rows; input.publicationID = AnyHashable(1)
        if mode == "viewportOwner" { driver.externalViewportMotion = true }
        controller.update(input)
        if mode == "rapid" {
            firstCurrent = false
            rows[1] = row(second, height: 3500)
            input.rows = rows; input.publicationID = AnyHashable(2)
            input.mutationLanding = NativeChatMutationLanding(requestID: UUID(), sourcePublicationID: AnyHashable(1),
                destinationPublicationID: AnyHashable(2), scrollViewIdentity: ObjectIdentifier(driver.scrollView!),
                removedID: first, targetID: second, isReplacement: true, target: .rowBottom(second, 560),
                isCurrent: { true })
            controller.update(input)
        }
        await wait(0.6)
        if mode == "release" {
            driver.releasePosition(userOwned: true)
            controller.update(input)
            await wait()
        }
        let finalTarget: NativeChatScrollTarget = mode == "rapid" ? .rowBottom(second, 560) : target
        let finalID = mode == "rapid" ? second : (deletion ? after : first)
        let shouldReject = ["stalePublication", "viewportOwner", "release"].contains(mode)
        // A busy/new simulator can still be executing the queued batch at
        // 0.6 seconds. Wait for a concrete endpoint with a deadline; do not
        // mistake an unfinished transaction for its final geometry.
        let readinessStart = Date()
        var readinessSamples: [[String: Any]] = []
        while !shouldReject && Date().timeIntervalSince(readinessStart) < 5 {
            let sample = controller.sample(finalTarget, id: finalID)
            readinessSamples.append(sample)
            if !(sample["batch"] as! Bool) && (sample["measured"] as! Bool) && (sample["visible"] as! Bool) { break }
            await wait(0.016)
        }
        let final = controller.sample(finalTarget, id: finalID)
        if shouldReject {
            if rejected != 1 || (final["accepted"] as! Bool) { failures.append(mode + " failed to relinquish rejected edit") }
        } else if abs((final["offset"] as! CGFloat) - (final["desired"] as! CGFloat)) > 2 || !(final["visible"] as! Bool) {
            failures.append(mode + " wrong destination")
        }
        results.append(["name":mode, "rejected":rejected,"final":final,
                        "readinessSeconds": Date().timeIntervalSince(readinessStart), "readinessSamples": readinessSamples])
        controller.detach()
    }
    func checkResize(_ name: String, oldHeight: CGFloat, newHeight: CGFloat,
                     anchor: NativeChatRowResizeAnchor, release: Bool = false) async {
        let driver = NativeChatScrollDriver(), before = UUID(), id = UUID(), after = UUID()
        let tail = anchor == .transcriptBottom
        var rows = [row(before, height: 1700), row(id, height: oldHeight)]
        if !tail { rows.append(row(after, height: 1600)) }
        var input = NativeChatTranscript(rows: rows, configuration: .init(top: 90, bottom: 140),
            publicationID: AnyHashable(0), sessionID: AnyHashable(name), driver: driver,
            hasEarlier: false, hasLater: false)
        let controller = NativeChatTranscriptController(input: input)
        window?.rootViewController = controller; window?.makeKeyAndVisible()
        await wait()
        let initial: NativeChatScrollTarget = tail ? .bottom
            : anchor == .top ? .rowTop(id, 120) : .rowBottom(id, 560)
        _ = await driver.scrollAndWait(to: initial, duration: 0)
        await wait(); driver.releasePosition()
        let request = UUID()
        guard driver.beginRowResize(requestID: request, rowID: id, anchor: anchor),
              let target = driver.target else { failures.append(name + " admission failed"); controller.detach(); return }
        if release { driver.releasePosition(userOwned: true) }
        var samples: [[String: Any]] = []
        let observer = FrameObserver(); observer.action = { samples.append(controller.sample(target, id: id)) }
        observer.start()
        rows[1] = row(id, height: newHeight); input.rows = rows; input.publicationID = AnyHashable(1)
        controller.update(input); await wait(0.6); observer.stop()
        let final = controller.sample(target, id: id)
        if !release {
            let invalid = samples.filter { abs(($0["offset"] as! CGFloat) - ($0["desired"] as! CGFloat)) > 2 }
            if !invalid.isEmpty { failures.append(name + " intermediate frames: \(invalid.count)") }
            if !(final["visible"] as! Bool) { failures.append(name + " target invisible") }
        } else if driver.positionHasExplicitTarget { failures.append(name + " target survived user release") }
        driver.endRowResize(request)
        if driver.positionHasExplicitTarget { failures.append(name + " resize target not released") }
        // An old disclosure completion must not erase a newer explicit owner.
        driver.armBottomPin(); driver.endRowResize(request)
        if !driver.positionIsBottomPinned { failures.append(name + " stale completion stole new owner") }
        results.append(["name": name, "samples": samples, "final": final])
        controller.detach()
    }
    func run() async {
        for (old, new) in [(3200.0, 140.0), (140.0, 4100.0), (2500.0, 3800.0), (140.0, 250.0)] {
            await check("tail-\(old)-\(new)", oldHeight: old, newHeight: new, tail: true, exactBottom: true)
            await check("middle-\(old)-\(new)", oldHeight: old, newHeight: new, tail: false, exactBottom: false)
            await check("tail-reading-\(old)-\(new)", oldHeight: old, newHeight: new, tail: true, exactBottom: false)
        }
        for mode in ["deletion", "stalePublication", "viewportOwner", "rapid", "release"] {
            await checkAdmission(mode)
        }
        for anchor in [NativeChatRowResizeAnchor.top, .bottom, .transcriptBottom] {
            await checkResize("resize-\(anchor)-collapse", oldHeight: 3200, newHeight: 140, anchor: anchor)
            await checkResize("resize-\(anchor)-expand", oldHeight: 140, newHeight: 4100, anchor: anchor)
        }
        await checkResize("resize-user-release", oldHeight: 3200, newHeight: 140, anchor: .bottom, release: true)
        let output: [String: Any] = ["status": failures.isEmpty ? "PASS" : "FAIL", "failures":failures,"cases":results]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("native-version-result.json")
        try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        exit(failures.isEmpty ? 0 : 1)
    }
}
