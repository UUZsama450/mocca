// Appended to the complete product NativeChatTranscript.swift in an isolated
// simulator app. Only configure/reuse counters are injected into the product copy.
struct CodeDisclosureLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
@MainActor private enum RowConfigurationProbe {
    static var counts: [String: Int] = [:]
    static var reusedHosts = 0
    static var invalidReuseIdentities = 0
    static func reused(old: UUID, new: UUID) {
        reusedHosts += 1
        if old == new { invalidReuseIdentities += 1 }
    }
    static func record(cell: NativeChatCell, key: NativeChatRowKey, publication: AnyHashable) {
        let key = "\(cell.measurementHostID)|\(key.id)|\(key.revision)|\(publication)"
        counts[key, default: 0] += 1
    }
}

@MainActor private extension NativeChatTranscriptController {
    var testedRows: [NativeChatRow] { rows }
    var testedLayout: ReadingCollectionLayout { layout }
    var testedPublication: AnyHashable { input.publicationID }
    var hasUnfinishedTestUpdate: Bool { batchID != nil || pendingInput != nil }
    var hasPendingTestInput: Bool { pendingInput != nil }
}

@main @MainActor final class RowConfigurationApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var cases: [[String: Any]] = []
    var failures: [String] = []
    var checks = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        Task { await run() }
        return true
    }
    func wait() async { try? await Task.sleep(for: .milliseconds(180)) }
    func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    func row(_ n: Int, height: CGFloat = 60, revision: Int = 0, message: Bool = true) -> NativeChatRow {
        let rowID = id(n)
        return NativeChatRow(id: rowID, revision: AnyHashable("\(revision)-\(height)"), content: AnyView(
            Text("Synthetic row \(n) revision \(revision)")
                .frame(maxWidth: .infinity).frame(height: height)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: NativeChatRowFramePreferenceKey.self,
                        value: [rowID: proxy.frame(in: .named("native-chat-row"))])
                })
        ), isMessage: message)
    }
    func expect(_ value: Bool, _ name: String) {
        checks += 1
        if !value { failures.append(name) }
    }
    func exercise(_ scenario: String) async {
        let driver = NativeChatScrollDriver()
        let initialCount = scenario == "host-reuse" ? 100 : 6
        var input = NativeChatTranscript(rows: (1...initialCount).map { row($0) },
            configuration: .init(top: 20, bottom: 20, gap: 0),
            publicationID: AnyHashable(0), sessionID: AnyHashable(scenario), driver: driver,
            hasEarlier: false, hasLater: false)
        if scenario == "host-reuse" { input.initialBottom = false }
        let controller = NativeChatTranscriptController(input: input)
        window!.rootViewController = controller; window!.makeKeyAndVisible()
        await wait()
        controller.collection.layoutIfNeeded()
        expect(scenario == "host-reuse" ? !controller.collection.visibleCells.isEmpty
            : controller.collection.visibleCells.count == 6, scenario + ": initial visible rows")
        RowConfigurationProbe.counts = [:]
        RowConfigurationProbe.reusedHosts = 0
        RowConfigurationProbe.invalidReuseIdentities = 0
        var expected = input.rows
        var heights = Dictionary(uniqueKeysWithValues: (1...initialCount).map { (id($0), CGFloat(60)) })
        let initialHosts = Dictionary(uniqueKeysWithValues: controller.collection.visibleCells.compactMap {
            ($0 as? NativeChatCell).flatMap { cell in cell.configuredKey.map { ($0.id, cell.measurementHostID) } }
        })

        switch scenario {
        case "append-with-tail-height":
            expected[5] = row(6, height: 100, revision: 1); heights[id(6)] = 100
            expected.append(row(7)); heights[id(7)] = 60
        case "prepend-history": expected.insert(row(7), at: 0); heights[id(7)] = 60
        case "delete": expected.remove(at: 2); heights.removeValue(forKey: id(3))
        case "replace-version": expected[2] = row(7, height: 90); heights.removeValue(forKey: id(3)); heights[id(7)] = 90
        case "reorder": expected.reverse()
        case "revision-only", "disclosure-height":
            expected[2] = row(3, height: 160, revision: 1); heights[id(3)] = 160
        case "context-only": break
        case "metrics-only": input.configuration.gap = 9
        case "send-reservation": expected.append(row(7, height: 22, message: false)); heights[id(7)] = 22
        case "queued-updates": expected.insert(row(7), at: 0); heights[id(7)] = 60
        case "insert-while-scrolling":
            expected = (1...30).map { row($0) }; heights = Dictionary(uniqueKeysWithValues: (1...30).map { (id($0), CGFloat(60)) })
        default: break
        }
        input.rows = expected
        if !["revision-only", "metrics-only", "host-reuse"].contains(scenario) { input.publicationID = AnyHashable(1) }
        if scenario == "disclosure-height" { input.disclosureOperation = UUID() }
        controller.update(input)
        if scenario == "queued-updates" {
            expect(controller.hasUnfinishedTestUpdate, scenario + ": first batch is active")
            expected.append(row(8, height: 80)); heights[id(8)] = 80
            input.rows = expected; input.publicationID = AnyHashable(2)
            controller.update(input)
            expect(controller.hasPendingTestInput, scenario + ": second publication is queued")
        }
        if scenario == "insert-while-scrolling" {
            driver.releasePosition(userOwned: true)
            controller.collection.setContentOffset(CGPoint(x: 0, y: 150), animated: true)
            expected.insert(row(31), at: 0); heights[id(31)] = 60
            input.rows = expected; input.publicationID = AnyHashable(2)
            controller.update(input)
            try? await Task.sleep(for: .milliseconds(400))
        }
        await wait()
        controller.collection.layoutIfNeeded()
        if scenario == "host-reuse" {
            // Let UIKit drive the complete reuse lifecycle, including its
            // matching invalidation and layout passes.
            driver.releasePosition(userOwned: true)
            for index in [30, 50, 70, 90] {
                let target = controller.testedLayout.frame(for: id(index))!.minY
                controller.collection.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                controller.collection.layoutIfNeeded()
                await wait()
            }
            controller.collection.setContentOffset(.zero, animated: false)
            controller.collection.layoutIfNeeded()
            await wait()
            expect(RowConfigurationProbe.reusedHosts > 0, scenario + ": UIKit recycled hosts")
            expect(RowConfigurationProbe.invalidReuseIdentities == 0, scenario + ": recycled host identities changed")
        }
        expect(!controller.hasUnfinishedTestUpdate, scenario + ": update completed")
        expect(controller.testedRows.map(\.id) == expected.map(\.id), scenario + ": row order")
        expect(controller.testedPublication == input.publicationID, scenario + ": current publication")
        var visible: [[String: Any]] = []
        for case let cell as NativeChatCell in controller.collection.visibleCells {
            guard let path = controller.collection.indexPath(for: cell), controller.testedRows.indices.contains(path.item) else {
                failures.append(scenario + ": invalid visible cell index"); continue
            }
            let row = controller.testedRows[path.item], key = NativeChatRowKey(id: row.id, revision: row.revision)
            expect(cell.configuredKey == key && cell.configuredPublication == input.publicationID, scenario + ": current cell identity")
            expect(controller.testedLayout.isMeasured(key), scenario + ": current host measured")
            let frame = controller.testedLayout.frame(for: row.id)!
            expect(abs(frame.height - heights[row.id]!) < 1, scenario + ": expected row height")
            expect(cell.messageLocalFrame != nil, scenario + ": current geometry delivered")
            if ["append-with-tail-height", "prepend-history", "delete", "context-only", "revision-only"].contains(scenario),
               let initial = initialHosts[row.id] {
                expect(cell.measurementHostID == initial, scenario + ": surviving host retained")
            }
            visible.append(["id": row.id.uuidString, "height": frame.height, "measured": controller.testedLayout.isMeasured(key)])
        }
        visible.sort { ($0["id"] as! String) < ($1["id"] as! String) }
        let counts = RowConfigurationProbe.counts
        cases.append(["name": scenario, "configurations": counts.values.reduce(0, +),
            "duplicateConfigurations": counts.values.reduce(0) { $0 + max(0, $1 - 1) },
            "maxPerHostRevisionPublication": counts.values.max() ?? 0,
            "reusedHosts": RowConfigurationProbe.reusedHosts,
            "visible": visible, "rows": expected.map { $0.id.uuidString },
            "offset": controller.collection.contentOffset.y])
        controller.detach()
    }
    func run() async {
        for scenario in ["append-with-tail-height", "prepend-history", "delete", "replace-version", "reorder",
                         "revision-only", "context-only", "metrics-only", "disclosure-height", "send-reservation",
                         "queued-updates", "insert-while-scrolling", "host-reuse"] {
            await exercise(scenario)
        }
        let report: [String: Any] = ["status": failures.isEmpty ? "PASS" : "FAIL", "checks": checks,
                                    "cases": cases, "failures": failures]
        let path = URL.documentsDirectory.appendingPathComponent("row-configuration-result.json")
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path) }
        catch { print(error); exit(2) }
        print("ROW_CONFIGURATION_CHECKS=\(checks) failures=\(failures.count)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
