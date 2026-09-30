
@main
struct CitationPreparationCheck {
    @MainActor static var comparisons = 0
    @MainActor static var checks = 0

    static func event(_ index: Int, _ id: String, _ url: String, _ title: String) -> ToolEvent {
        let data = try! JSONSerialization.data(withJSONObject: ["items": [
            ["index": index, "id": id, "url": url, "title": title]
        ]], options: [.sortedKeys, .withoutEscapingSlashes])
        return ToolEvent(resultText: String(data: data, encoding: .utf8))
    }

    static func row(_ role: ChatMessage.Role, _ events: [ToolEvent] = []) -> ChatMessage {
        ChatMessage(id: UUID(), role: role, toolEvents: events)
    }

    @MainActor static func require(_ value: Bool, _ name: String) {
        checks += 1
        if !value { fatalError("CHECK FAILED: \(name)") }
    }

    @MainActor static func compare(
        _ name: String, cache: MessageCitationPreparationCache,
        conversation: UUID, rows: [ChatMessage], retention: Int
    ) {
        let expected = MessageCitationSource.sourcesByMessageID(from: rows, retentionTurns: retention)
        let actual = cache.sourcesByMessageID(conversationID: conversation, from: rows, retentionTurns: retention)
        require(actual == expected, name)
        // Compare URL bytes as well: Unicode canonical equality of input JSON
        // must not hide a change in the URL that the existing parser produces.
        for (id, wanted) in expected {
            let got = actual[id] ?? []
            require(got.count == wanted.count, name + " count")
            for (a, b) in zip(got, wanted) {
                require(Array(a.url.absoluteString.utf8) == Array(b.url.absoluteString.utf8), name + " URL bytes")
                require(Array(a.title.utf8) == Array(b.title.utf8), name + " title bytes")
            }
        }
        comparisons += 1
    }

    @MainActor static func checkCorpus(_ name: String, _ rows: [ChatMessage]) {
        let cache = MessageCitationPreparationCache()
        let conversation = UUID()
        for retention in [-3, -1, 0, 1, 3, 20, Int.max] {
            compare(name, cache: cache, conversation: conversation, rows: rows, retention: retention)
            compare(name + " cached", cache: cache, conversation: conversation, rows: rows, retention: retention)
        }
    }

    struct Random {
        var state: UInt64 = 5116
        mutating func next(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 16) % UInt64(limit))
        }
    }

    @MainActor static func semantics() {
        checkCorpus("empty", [])
        checkCorpus("ignored results", [row(.user, [event(1, "p", "https://example.test/u", "ignored")]), row(.tool), row(.system), row(.assistant)])
        checkCorpus("malformed results", [row(.assistant, [ToolEvent(resultText: nil), ToolEvent(resultText: "not JSON"), ToolEvent(resultText: "{}"), ToolEvent(resultText: "{\"items\":[{\"index\":\"bad\"}]}")])])
        let tricky = [
            row(.assistant, [event(1, "ß", "https://example.test/a", "old"), event(2, "Σ", "https://example.test/s", "sigma")]),
            row(.assistant, [event(1, "ss", "https://example.test/a", "updated"), event(2, "ς", "https://example.test/s", "final sigma")]),
            row(.assistant), row(.user), row(.assistant), row(.user), row(.assistant), row(.system), row(.tool)
        ]
        checkCorpus("casefold order expiry", tricky)
        for seed in 0..<10 {
            var random = Random(state: UInt64(5116 + seed))
            var rows: [ChatMessage] = []
            for i in 0..<120 {
                let role: ChatMessage.Role = [.assistant, .assistant, .user, .system, .tool][random.next(5)]
                var events: [ToolEvent] = []
                for j in 0..<random.next(3) {
                    events.append(event(random.next(4), ["p", "P", "ß", "ss", "Σ", "ς"][random.next(6)],
                                        "https://example.test/" + ["a", "A", "b", "b/"][random.next(4)], "\(seed)-\(i)-\(j)"))
                }
                rows.append(row(role, events))
            }
            checkCorpus("random \(seed)", rows)
        }

        let cache = MessageCitationPreparationCache()
        let a = UUID(), b = UUID()
        var rows = [row(.user), row(.assistant, [event(1, "p", "https://example.test/a", "old")]), row(.user), row(.assistant)]
        compare("initial", cache: cache, conversation: a, rows: rows, retention: 2)
        Probe.reset()
        for step in 0..<120 {
            rows[3].text += "正文\(step)"
            rows[3].reasoning += "思考"
            rows[3].status = step == 119 ? "complete" : "streaming"
            _ = cache.sourcesByMessageID(conversationID: a, from: rows, retentionTurns: 2)
        }
        require(Probe.preparations == 0 && Probe.parseCalls == 0, "unchanged citations perform no preparation during body/reasoning/status updates")
        compare("body changed", cache: cache, conversation: a, rows: rows, retention: 2)
        rows[1].toolEvents[0].name = "renamed tool"
        rows[1].toolEvents[0].status = "failed"
        rows[1].toolEvents.append(ToolEvent(resultText: nil))
        Probe.reset()
        _ = cache.sourcesByMessageID(conversationID: a, from: rows, retentionTurns: 2)
        require(Probe.preparations == 0, "irrelevant tool metadata and nil result do not rebuild")
        compare("tool metadata", cache: cache, conversation: a, rows: rows, retention: 2)
        rows[1].toolEvents[0] = event(1, "p", "https://example.test/a", "new title")
        compare("title refresh", cache: cache, conversation: a, rows: rows, retention: 2)
        rows[1].toolEvents[0] = event(1, "p", "https://example.test/new", "new URL")
        compare("URL refresh", cache: cache, conversation: a, rows: rows, retention: 2)
        rows[1].toolEvents[0] = event(1, "p", "https://example.test/caf\u{00e9}", "caf\u{00e9}")
        compare("composed unicode", cache: cache, conversation: a, rows: rows, retention: 2)
        rows[1].toolEvents[0] = event(1, "p", "https://example.test/cafe\u{0301}", "cafe\u{0301}")
        compare("decomposed unicode refresh", cache: cache, conversation: a, rows: rows, retention: 2)
        compare("conversation replacement", cache: cache, conversation: b, rows: rows, retention: 2)
        compare("retention change", cache: cache, conversation: b, rows: rows, retention: 0)
        rows.swapAt(0, 1)
        compare("reorder", cache: cache, conversation: b, rows: rows, retention: 0)
        rows[0].id = UUID()
        compare("selected version replacement", cache: cache, conversation: b, rows: rows, retention: 0)
        compare("window trim", cache: cache, conversation: b, rows: Array(rows.suffix(2)), retention: 0)
        compare("window return", cache: cache, conversation: b, rows: rows, retention: 0)
        rows.insert(row(.user), at: 1)
        compare("insert user expiry", cache: cache, conversation: b, rows: rows, retention: 0)
        rows[0].role = .user
        compare("role change removes citations", cache: cache, conversation: b, rows: rows, retention: 0)
        rows[0].role = .assistant
        compare("role returns", cache: cache, conversation: b, rows: rows, retention: 0)
        rows[0].toolEvents.removeAll()
        compare("results removed", cache: cache, conversation: b, rows: rows, retention: -1)
        compare("clear window", cache: cache, conversation: b, rows: [], retention: -1)

        var random = Random()
        rows = tricky
        for step in 0..<350 {
            switch random.next(7) {
            case 0: rows.append(row(.user))
            case 1: rows.append(row(.assistant, [event(step, "p\(step)", "https://example.test/\(step)", "title\(step)")]))
            case 2: if !rows.isEmpty { rows.remove(at: random.next(rows.count)) }
            case 3: if rows.count > 1 { rows.swapAt(random.next(rows.count), random.next(rows.count)) }
            case 4: if !rows.isEmpty { rows[random.next(rows.count)].text += "new content" }
            case 5: if !rows.isEmpty { rows[random.next(rows.count)].toolEvents = [event(step, "replace", "https://example.test/replace", "\(step)")] }
            default: if !rows.isEmpty { rows[random.next(rows.count)].role = [.assistant, .user, .tool][random.next(3)] }
            }
            compare("mutation \(step)", cache: cache, conversation: step.isMultiple(of: 5) ? a : b,
                    rows: rows, retention: [-1, 0, 1, 3, 20][random.next(5)])
        }
    }

    @MainActor static func benchmark(name: String, count: Int, searchEvery: Int, iterations: Int, changingResults: Bool = false) -> [String: Any] {
        let conversation = UUID()
        var rows = (0..<count).map { i in
            i.isMultiple(of: 2) ? row(.user) : row(.assistant, searchEvery > 0 && i % searchEvery == 1
                ? (0..<6).map { event($0 + 1, "r\($0)", "https://example.test/\(i)/\($0)", "Search result \(i) \($0)") } : [])
        }
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var oldCalls = 0, newCalls = 0
        var oldParses = 0, newParses = 0
        for repetition in 0..<5 {
            let cache = MessageCitationPreparationCache()
            for candidate in (repetition.isMultiple(of: 2) ? [false, true] : [true, false]) {
                Probe.reset()
                let start = DispatchTime.now().uptimeNanoseconds
                for i in 0..<iterations {
                    rows[rows.count - 1].text = "growing body \(i)"
                    if changingResults {
                        rows[1].toolEvents[0] = event(1, "r0", "https://example.test/updated/\(i)", "Updated result \(i)")
                    }
                    let result = candidate
                        ? cache.sourcesByMessageID(conversationID: conversation, from: rows, retentionTurns: 3)
                        : MessageCitationSource.sourcesByMessageID(from: rows, retentionTurns: 3)
                    Probe.checksum &+= result.count
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if candidate {
                    newTimes.append(ms); newCalls = Probe.preparations; newParses = Probe.parseCalls
                } else {
                    oldTimes.append(ms); oldCalls = Probe.preparations; oldParses = Probe.parseCalls
                }
            }
        }
        let old = oldTimes.sorted()[2], new = newTimes.sorted()[2]
        return ["name": name, "windowMessages": count, "updates": iterations,
                "baselineMedianMs": old, "candidateMedianMs": new, "ratio": new / old, "changingResults": changingResults,
                "baselinePreparations": oldCalls, "candidatePreparations": newCalls,
                "baselineSourceParseCalls": oldParses, "candidateSourceParseCalls": newParses,
                "baselineRunsMs": oldTimes, "candidateRunsMs": newTimes]
    }

    @MainActor static func main() throws {
        semantics()
        let benchmarks = [
            benchmark(name: "ordinary-12", count: 12, searchEvery: 0, iterations: 2000),
            benchmark(name: "ordinary-360", count: 360, searchEvery: 0, iterations: 500),
            benchmark(name: "search-12", count: 12, searchEvery: 4, iterations: 120),
            benchmark(name: "search-120", count: 120, searchEvery: 12, iterations: 120),
            benchmark(name: "search-360", count: 360, searchEvery: 12, iterations: 120),
            benchmark(name: "search-changing-12", count: 12, searchEvery: 4, iterations: 120, changingResults: true),
            benchmark(name: "search-changing-360", count: 360, searchEvery: 12, iterations: 120, changingResults: true)
        ]
        let result: [String: Any] = ["status": "PASS", "comparisons": comparisons, "assertions": checks,
                                   "benchmarks": benchmarks, "checksum": Probe.checksum]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
