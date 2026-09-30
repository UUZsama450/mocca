@MainActor private protocol AuditedLayout: AnyObject {
    var native: UICollectionViewLayout { get }
    var keys: [NativeChatRowKey] { get }
    var generation: UInt64 { get }
    var width: CGFloat { get }
    var minimumHeight: CGFloat { get }
    var spacerFrame: CGRect { get }
    var configuration: NativeChatLayoutConfiguration { get }
    var externalViewportMotion: () -> Bool { get set }
    var semanticTarget: () -> NativeChatScrollTarget? { get set }
    func frame(for id: UUID) -> CGRect?
    func offset(for target: NativeChatScrollTarget, height: CGFloat?, viewport: CGFloat?) -> CGFloat?
    func isMeasured(_ key: NativeChatRowKey) -> Bool
    func bindMeasurementHost(_ cell: NativeChatCell, key: NativeChatRowKey)
    func retireMeasurementHost(_ id: UUID, key: NativeChatRowKey)
}
extension BaselineReadingCollectionLayout: AuditedLayout { var native: UICollectionViewLayout { self } }
extension ReadingCollectionLayout: AuditedLayout { var native: UICollectionViewLayout { self } }

@MainActor private final class LayoutHarness: NSObject, UICollectionViewDataSource {
    let layout: any AuditedLayout
    let collection: UICollectionView
    var cells: [UUID: NativeChatCell] = [:]
    var itemCount: Int
    init(_ layout: any AuditedLayout) {
        self.layout = layout
        itemCount = layout.keys.count
        collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 760), collectionViewLayout: layout.native)
        super.init()
        collection.contentInsetAdjustmentBehavior = .never
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "fixture")
        collection.dataSource = self
        collection.reloadData()
        _ = collection.numberOfItems(inSection: 0)
        layout.native.prepare()
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { itemCount }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "fixture", for: indexPath)
    }
    func update(_ keys: [NativeChatRowKey]? = nil, configuration: NativeChatLayoutConfiguration? = nil,
                width: CGFloat? = nil, height: CGFloat? = nil,
                target: NativeChatScrollTarget? = nil) -> NativeChatInvalidation {
        let context = NativeChatInvalidation()
        if let keys {
            context.rows = keys; context.structural = keys.map(\.id) != layout.keys.map(\.id)
            if context.structural {
                itemCount = keys.count
                collection.reloadData()
                _ = collection.numberOfItems(inSection: 0)
            }
        }
        context.configuration = configuration; context.width = width; context.viewportHeight = height
        context.bootstrapTarget = target
        layout.native.invalidateLayout(with: context)
        return context
    }
    func attributes(_ index: Int) -> NativeChatAttributes {
        layout.native.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) as! NativeChatAttributes
    }
    func host(_ index: Int, replace: Bool = false) -> NativeChatCell {
        let key = layout.keys[index]
        let cell = !replace ? cells[key.id] ?? NativeChatCell() : NativeChatCell()
        cell.prepareHost(for: key); cell.configuredKey = key
        cell.onRetireMeasurementHost = { [weak layout] id, key in layout?.retireMeasurementHost(id, key: key) }
        cells[key.id] = cell; layout.bindMeasurementHost(cell, key: key)
        return cell
    }
    func measure(_ index: Int, _ height: CGFloat, original: NativeChatAttributes? = nil,
                 staleHost: UUID? = nil) -> Bool {
        let original = original ?? attributes(index)
        let preferred = original.copy() as! NativeChatAttributes
        preferred.size.height = height
        preferred.measurementHostID = staleHost ?? host(index).measurementHostID
        let admitted = layout.native.shouldInvalidateLayout(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        // Exercise both gates: callers cannot bypass validation with a context.
        let context = layout.native.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        layout.native.invalidateLayout(with: context)
        return admitted
    }
    func invalidSampleLeavesHeightUnchanged(_ index: Int, _ height: CGFloat) -> Bool {
        let original = attributes(index), key = layout.keys[index]
        let before = layout.frame(for: key.id)
        let context = NativeChatInvalidation()
        context.measurement = (key, height, layout.width, original.session!, layout.generation, host(index).measurementHostID)
        layout.native.invalidateLayout(with: context)
        return before == layout.frame(for: key.id)
    }
}

@MainActor private enum LayoutChecks {
    static var assertions = 0
    static var comparisons = 0
    static var failures: [String] = []
    static func require(_ ok: Bool, _ name: String) {
        assertions += 1
        if !ok, failures.count < 20 { failures.append(name) }
    }
    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.000_01 }
    static func equal(_ a: CGRect, _ b: CGRect) -> Bool {
        close(a.minX, b.minX) && close(a.minY, b.minY) && close(a.width, b.width) && close(a.height, b.height)
    }
    static func compare(_ name: String, _ a: LayoutHarness, _ b: LayoutHarness) {
        require(a.layout.keys == b.layout.keys, name + " keys")
        require(a.layout.generation == b.layout.generation, name + " generation")
        require(close(a.layout.width, b.layout.width), name + " width")
        require(close(a.collection.contentOffset.y, b.collection.contentOffset.y), name + " actual offset")
        require(close(a.layout.native.collectionViewContentSize.height, b.layout.native.collectionViewContentSize.height), name + " content height")
        require(close(a.layout.minimumHeight, b.layout.minimumHeight), name + " minimum")
        require(equal(a.layout.spacerFrame, b.layout.spacerFrame), name + " spacer")
        for key in a.layout.keys {
            require(equal(a.layout.frame(for: key.id)!, b.layout.frame(for: key.id)!), name + " frame")
            require(a.layout.isMeasured(key) == b.layout.isMeasured(key), name + " measured")
        }
        let rect = CGRect(x: 0, y: 30, width: 390, height: 1000)
        let aa = a.layout.native.layoutAttributesForElements(in: rect) ?? []
        let ba = b.layout.native.layoutAttributesForElements(in: rect) ?? []
        require(aa.map(\.indexPath) == ba.map(\.indexPath), name + " visible indices")
        for (x, y) in zip(aa, ba) { require(equal(x.frame, y.frame), name + " visible frame") }
        require(close(a.layout.offset(for: .bottom, height: nil, viewport: nil)!, b.layout.offset(for: .bottom, height: nil, viewport: nil)!), name + " bottom")
        comparisons += 1
    }
    static func semantics() {
        var keys = (0..<12).map { _ in NativeChatRowKey(id: UUID(), revision: 0) }
        var config = NativeChatLayoutConfiguration()
        let old = LayoutHarness(BaselineReadingCollectionLayout(keys: keys, configuration: config))
        let new = LayoutHarness(ReadingCollectionLayout(keys: keys, configuration: config))
        compare("initial", old, new)
        for i in keys.indices {
            require(old.measure(i, CGFloat(80 + i * 3)), "baseline measurement")
            require(new.measure(i, CGFloat(80 + i * 3)), "candidate measurement")
        }
        compare("measured", old, new)
        let before = Probe.newBuilds
        for step in 1...120 {
            let i = step % keys.count
            let oa = old.attributes(i), na = new.attributes(i)
            keys[i] = NativeChatRowKey(id: keys[i].id, revision: step)
            let oc = old.update(keys), nc = new.update(keys)
            require(oc.contentOffsetAdjustment == nc.contentOffsetAdjustment, "revision adjustment")
            require(!old.measure(i, 500, original: oa) && !new.measure(i, 500, original: na), "stale revision rejected")
            require(old.measure(i, CGFloat(80 + step)) && new.measure(i, CGFloat(80 + step)), "fresh revision measured")
            compare("revision\(step)", old, new)
        }
        require(Probe.newBuilds == before, "content revisions and measurements must reuse height index")
        let oldHost = old.host(0).measurementHostID, newHost = new.host(0).measurementHostID
        _ = old.host(0, replace: true); _ = new.host(0, replace: true)
        require(!old.measure(0, 900, staleHost: oldHost) && !new.measure(0, 900, staleHost: newHost), "retired host rejected")
        compare("host replaced", old, new)
        let oa = old.attributes(1), na = new.attributes(1)
        _ = old.update(width: 480); _ = new.update(width: 480)
        require(!old.measure(1, 900, original: oa) && !new.measure(1, 900, original: na), "old width generation rejected")
        compare("width", old, new)
        for size in [CGFloat.nan, .infinity, 0, -10] {
            require(old.invalidSampleLeavesHeightUnchanged(0, size) && new.invalidSampleLeavesHeightUnchanged(0, size), "invalid heights rejected")
        }
        config.gap = 11.25; config.top = 31.5; config.bottom = 92
        config.alignShortContentToBottom = true
        _ = old.update(configuration: config); _ = new.update(configuration: config)
        compare("configuration", old, new)
        for step in 0..<360 {
            switch step % 9 {
            case 0: keys.insert(NativeChatRowKey(id: UUID(), revision: step), at: 0)
            case 1: if keys.count > 2 { keys.remove(at: keys.count / 2) }
            case 2: keys.reverse()
            case 3: config.gap = CGFloat(step % 7) + 0.5
            case 4: config.bottom = CGFloat(step % 20) + 23
            default: keys[step % keys.count] = NativeChatRowKey(id: keys[step % keys.count].id, revision: step + 500)
            }
            let oc = old.update(keys, configuration: config), nc = new.update(keys, configuration: config)
            require(close(oc.contentOffsetAdjustment.y, nc.contentOffsetAdjustment.y), "mutation offset")
            require(close(oc.contentSizeAdjustment.height, nc.contentSizeAdjustment.height), "mutation size")
            // UIKit may reuse an invalidation context; it must remain idempotent.
            old.layout.native.invalidateLayout(with: oc); new.layout.native.invalidateLayout(with: nc)
            let index = step % keys.count
            let height = CGFloat(60 + step % 100) + 0.375
            require(old.measure(index, height) == new.measure(index, height), "mutation measure admission")
            if step.isMultiple(of: 11) {
                _ = old.update(height: 410); _ = new.update(height: 410)
            } else if step.isMultiple(of: 13) {
                _ = old.update(height: 760); _ = new.update(height: 760)
            }
            compare("mutation\(step)", old, new)
        }
        _ = old.update([], target: .top); _ = new.update([], target: .top)
        compare("empty", old, new)
        _ = old.update(keys); _ = new.update(keys)
        compare("return", old, new)
        old.layout.externalViewportMotion = { true }; new.layout.externalViewportMotion = { true }
        old.layout.semanticTarget = { .bottom }; new.layout.semanticTarget = { .bottom }
        require(old.measure(0, 1234) == new.measure(0, 1234), "keyboard motion admission")
        compare("keyboard motion", old, new)
        for step in 0..<10_000 {
            let index = step % keys.count
            let value = CGFloat(100 + step % 71) + CGFloat(step % 11) * 0.1
            _ = old.measure(index, value); _ = new.measure(index, value)
            if step.isMultiple(of: 100) {
                keys[index] = NativeChatRowKey(id: keys[index].id, revision: step + 1000)
                _ = old.update(keys); _ = new.update(keys)
                compare("long fractional measurement\(step)", old, new)
            }
        }
    }
    static func benchmark(_ count: Int) -> [String: Any] {
        let seed = (0..<count).map { _ in NativeChatRowKey(id: UUID(), revision: 0) }
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var oldBuilds = 0, newBuilds = 0
        for repetition in 0..<5 {
            for candidate in (repetition.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let layout: any AuditedLayout = candidate
                    ? ReadingCollectionLayout(keys: seed, configuration: NativeChatLayoutConfiguration())
                    : BaselineReadingCollectionLayout(keys: seed, configuration: NativeChatLayoutConfiguration())
                let harness = LayoutHarness(layout)
                var rows = seed
                Probe.oldBuilds = 0; Probe.newBuilds = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for i in 1...120 {
                    rows[count - 1] = NativeChatRowKey(id: rows[count - 1].id, revision: i)
                    _ = harness.update(rows)
                    _ = harness.measure(count - 1, CGFloat(80 + i))
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if candidate { newTimes.append(elapsed); newBuilds = Probe.newBuilds }
                else { oldTimes.append(elapsed); oldBuilds = Probe.oldBuilds }
            }
        }
        let old = oldTimes.sorted()[2], new = newTimes.sorted()[2]
        return ["rows": count, "updates": 120, "baselineMedianMs": old, "candidateMedianMs": new,
                "ratio": new / old, "baselineIndexRebuilds": oldBuilds, "candidateIndexRebuilds": newBuilds,
                "baselineRunsMs": oldTimes, "candidateRunsMs": newTimes]
    }
    static func run() -> [String: Any] {
        semantics()
        let benchmarks = [benchmark(12), benchmark(120), benchmark(360)]
        return ["status": failures.isEmpty ? "PASS" : "FAIL", "assertions": assertions,
                "comparisons": comparisons, "failures": failures, "benchmarks": benchmarks]
    }
}

@main final class LayoutApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
        DispatchQueue.main.async {
            let result = LayoutChecks.run()
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try! data.write(to: folder.appendingPathComponent("layout-result.json"), options: .atomic)
            print("LAYOUT_REUSE_RESULT " + String(data: data, encoding: .utf8)!)
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                exit(result["status"] as? String == "PASS" ? 0 : 1)
            }
        }
        return true
    }
}
