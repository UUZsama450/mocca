@main
struct ProjectionContentCheck {
    @MainActor static var comparisons = 0
    @MainActor static var assertions = 0
    struct Random {
        var state: UInt64 = 5116
        mutating func next(_ n: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 16) % UInt64(n))
        }
    }
    @MainActor static func require(_ condition: Bool, _ name: String) {
        assertions += 1
        if !condition { fatalError(name) }
    }
    static func fixture(_ count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            ChatMessage(id: UUID(), versionGroupID: i.isMultiple(of: 7) ? "group\(i / 21)" : nil,
                        version: i % 3, createdAt: Date(timeIntervalSince1970: Double(i % 5)), text: "row\(i)")
        }
    }
    @MainActor static func compare(_ name: String, _ old: BaselineProjectionModel, _ new: CandidateProjectionModel,
                                   _ id: UUID, supplied: [ChatMessage]? = nil) {
        let a = old.project(id, supplied: supplied), b = new.project(id, supplied: supplied)
        require(a == b, name)
        for (left, right) in zip(a, b) {
            require(left.key.utf8.elementsEqual(right.key.utf8), name + " key bytes")
        }
        comparisons += 1
    }
    @MainActor static func semantics() {
        let old = BaselineProjectionModel(), new = CandidateProjectionModel()
        let a = UUID(), b = UUID()
        old.conversations[a] = Conversation(id: a); new.conversations[a] = Conversation(id: a)
        old.conversations[b] = Conversation(id: b); new.conversations[b] = Conversation(id: b)
        func install(_ rows: [ChatMessage]?, id: UUID = a) {
            old.conversationMessageStore[id] = rows; new.conversationMessageStore[id] = rows
        }
        compare("missing", old, new, a)
        var rows = fixture(360)
        install(rows); compare("initial", old, new, a)
        let initialBuilds = Probe.candidateBuilds
        for i in 0..<120 {
            let index = i % rows.count
            rows[index].text += "body\(i)"
            rows[index].reasoning += "reason\(i)"
            rows[index].translation = "translation\(i)"
            rows[index].toolResults = ["result\(i)"]
            rows[index].status = "complete"
            rows[index].reactions = ["like"]
            rows[index].role = i.isMultiple(of: 2) ? "user" : "assistant"
            install(rows); compare("content\(i)", old, new, a)
        }
        require(Probe.candidateBuilds == initialBuilds, "content must refresh without regrouping")
        var random = Random()
        for step in 0..<900 {
            if rows.isEmpty { rows = fixture(10) }
            let index = random.next(rows.count)
            switch random.next(12) {
            case 0: rows[index].id = UUID()
            case 1: rows[index].versionGroupID = [nil, "shared", "", "caf\u{00e9}", "cafe\u{0301}"][random.next(5)]
            case 2: rows[index].version = random.next(8) - 4
            case 3: rows[index].createdAt = Date(timeIntervalSince1970: Double(random.next(6)))
            case 4: rows.swapAt(index, random.next(rows.count))
            case 5: rows.remove(at: index)
            case 6: rows.insert(fixture(1)[0], at: index)
            case 7:
                let key = rows[index].versionGroupKey
                let version = random.next(8) - 4
                old.conversations[a]!.versionSelections[key] = version
                new.conversations[a]!.versionSelections[key] = version
            case 8: rows[index].text = "new body \(step)"
            case 9: rows[index].versionGroupID = rows[random.next(rows.count)].id.uuidString
            case 10: rows[index] = rows[random.next(rows.count)]
            default: rows[index].translation = "new translation \(step)"
            }
            install(rows); compare("mutation\(step)", old, new, a)
            compare("warm\(step)", old, new, a)
            if step.isMultiple(of: 19) {
                compare("supplied snapshot", old, new, a, supplied: fixture(5))
                compare("supplied empty", old, new, a, supplied: [])
                compare("live after supplied snapshot", old, new, a)
            }
            if step.isMultiple(of: 37) {
                install(rows, id: b)
                compare("switch B", old, new, b)
                compare("switch A", old, new, a)
            }
        }
        install([]); compare("empty", old, new, a)
        install(nil); compare("deleted", old, new, a)
        install(rows); compare("reinserted", old, new, a)
        rows = [ChatMessage(id: UUID(), versionGroupID: "caf\u{00e9}")]
        install(rows); compare("unicode first", old, new, a)
        rows[0].versionGroupID = "cafe\u{0301}"
        install(rows); compare("unicode equivalent key exact representation", old, new, a)
    }
    @MainActor static func benchmark(_ count: Int, updates: Int, structural: Bool = false) -> [String: Any] {
        let id = UUID(), seed = fixture(count)
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var oldBuilds = 0, newBuilds = 0
        for run in 0..<5 {
            for candidate in (run.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let old = BaselineProjectionModel(), new = CandidateProjectionModel()
                old.conversations[id] = Conversation(id: id); new.conversations[id] = Conversation(id: id)
                var rows = seed
                Probe.baselineBuilds = 0; Probe.candidateBuilds = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for i in 0..<updates {
                    rows[rows.count - 1].text = "stream \(i)"
                    if structural { rows[rows.count - 1].version = i }
                    if candidate {
                        new.conversationMessageStore[id] = rows
                        Probe.checksum &+= new.project(id).count
                    } else {
                        old.conversationMessageStore[id] = rows
                        Probe.checksum &+= old.project(id).count
                    }
                }
                let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if candidate { newTimes.append(duration); newBuilds = Probe.candidateBuilds }
                else { oldTimes.append(duration); oldBuilds = Probe.baselineBuilds }
            }
        }
        let old = oldTimes.sorted()[2], new = newTimes.sorted()[2]
        return ["messages": count, "updates": updates, "structuralEveryUpdate": structural,
                "baselineMedianMs": old, "candidateMedianMs": new, "ratio": new / old,
                "baselineGroupBuilds": oldBuilds, "candidateGroupBuilds": newBuilds,
                "baselineRunsMs": oldTimes, "candidateRunsMs": newTimes]
    }
    @MainActor static func main() throws {
        semantics()
        let benchmarks = [benchmark(12, updates: 120), benchmark(360, updates: 120),
                          benchmark(4000, updates: 120), benchmark(10000, updates: 60),
                          benchmark(360, updates: 120, structural: true)]
        let result: [String: Any] = ["status": "PASS", "comparisons": comparisons, "assertions": assertions,
                                   "benchmarks": benchmarks, "checksum": Probe.checksum]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
