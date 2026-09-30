import XCTest

@MainActor final class BottomEntryUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.history-native-reading5075")
    private func geometry() -> [String: Any]? {
        let surface = app.descendants(matching: .any).matching(identifier: "nativeChat.transcript").firstMatch
        guard surface.exists, let value = surface.value as? String,
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func id(_ index: Int, _ version: Int) -> String {
        String(format: "50750000-0000-4000-8%d00-%012d", version, index)
    }
    private func frame(_ index: Int, _ version: Int) -> CGRect? {
        guard let frames = geometry()?["frames"] as? [String: [String: Double]],
              let f = frames[id(index, version)] else { return nil }
        return CGRect(x: f["x"]!, y: f["y"]!, width: f["width"]!, height: f["height"]!)
    }
    private func check(_ name: String, index: Int = 7, version: Int, edge: CGFloat? = nil) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let f = self.frame(index, version), let g = self.geometry(),
                  let viewport = g["viewportHeight"] as? Double else { return false }
            guard f.maxY > 0 && f.minY < viewport - 120 else { return false }
            if let edge { return abs(f.maxY - edge) <= 2 }
            return abs(g["bottomGap"] as? Double ?? 99999) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, name)
        capture(name)
    }
    private func capture(_ name: String) {
        print("INTEGRATION_STAGE \(name)")
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name
        image.lifetime = .keepAlways; add(image)
        if let g = geometry(), let data = try? JSONSerialization.data(withJSONObject: g, options: .prettyPrinted) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    private func button(_ label: String, middle: Bool = false) -> XCUIElement {
        let buttons = app.buttons.matching(identifier: label).allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(buttons.isEmpty, "Missing visible button: \(label)")
        return middle ? buttons.first! : buttons.last!
    }
    private func start() {
        continueAfterFailure = false
        executionTimeAllowance = 300
        app.launchArguments = ["-previewNativeReadingFixture", "versions", "-diagnoseChatBottom",
                               "-skipStartupPrompt", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let later = app.buttons["稍后"]; if later.waitForExistence(timeout: 3) { later.tap() }
        check("initial-short", version: 2)
    }
    func testTailCodeProseDisclosureAndRapidChanges() {
        start(); defer { app.terminate() }
        button("上一版回答").tap(); check("tail-cold-long-code", version: 1)
        button("下一版回答").tap(); check("tail-code-to-prose", version: 2)
        button("上一版回答").tap(); check("tail-warm-long-code", version: 1)
        button("上一版回答").tap(); check("tail-long-to-short-code-direct", version: 0)
        button("下一版回答").tap(); check("tail-short-to-long-code-direct", version: 1)
        button("从底部收起代码").tap(); check("tail-collapsed", version: 1)
        XCTAssertTrue(app.buttons["从底部展开代码"].firstMatch.exists)
        button("下一版回答").tap(); check("tail-collapsed-to-prose", version: 2)
        button("上一版回答").tap(); check("tail-restored-default-expanded", version: 1)
        // Disclosure is display-only and is discarded when its message leaves
        // the selected transcript. Preserve that existing product behavior.
        button("从底部收起代码").tap(); check("tail-collapsed-again", version: 1)
        button("从底部展开代码").tap(); check("tail-expanded", version: 1)
        button("下一版回答").tap(); check("tail-expanded-to-prose", version: 2)
        button("下一版回答").tap(); check("tail-short-code", version: 3)
        button("上一版回答").tap(); check("tail-short-code-to-prose", version: 2)
        button("上一版回答").tap(); check("tail-return-long-code", version: 1)
        // Resolve each replacement's actual button, without explicit geometry
        // waits between taps. A double-tap on the old button is not two distinct
        // version selections: its closure captures one target version.
        button("下一版回答").tap(); button("下一版回答").tap()
        check("tail-successive-to-short-code", version: 3)
        button("上一版回答").tap(); button("上一版回答").tap()
        check("tail-successive-to-long-code", version: 1)
        let before = frame(7, 1)!.maxY
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.35)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.68)))
        XCTAssertGreaterThan((frame(7, 1)?.maxY ?? before) - before, 80)
        capture("tail-user-drag")
    }
    func testCodeHeaderReadingEdge() {
        start(); defer { app.terminate() }
        button("上一版回答").tap(); check("header-setup-long", version: 1)
        button("从底部收起代码").tap(); check("header-setup-collapsed", version: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.35)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.53)))
        // Loading earlier rows can carry the collapsed header below the
        // composer. Put the real button in the reading viewport before tapping.
        let header = app.buttons.matching(identifier: "展开代码").allElementsBoundByIndex.last!
        let shift = header.frame.minY - app.frame.height * 0.60
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.72))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94,
            dy: 0.72 - shift / app.frame.height))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertGreaterThan(geometry()?["bottomGap"] as? Double ?? 0, 2, "Header case must not own exact bottom")
        let edge = button("展开代码").frame.minY
        XCTAssertGreaterThan(edge, 110)
        XCTAssertLessThan(edge, app.frame.height - 200, "Header must be above the composer")
        capture("header-before-expand")
        func checkHeader(_ label: String, _ name: String) {
            let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let b = self.app.buttons.matching(identifier: label).allElementsBoundByIndex.filter { $0.isHittable }.last
                return b.map { abs($0.frame.minY - edge) <= 2 } ?? false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 15), .completed, name)
            capture(name)
        }
        button("展开代码").tap(); checkHeader("收起代码", "header-expanded")
        button("收起代码").tap(); checkHeader("展开代码", "header-collapsed")
        button("展开代码").tap(); button("收起代码").tap()
        checkHeader("展开代码", "header-successive-toggle")
        let before = geometry()?["offsetY"] as? Double ?? 0
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.35)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.43)),
            withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertGreaterThan(abs((geometry()?["offsetY"] as? Double ?? 0) - before), 50)
        capture("header-user-drag")
    }
    func testMiddleCodeVersionsAndDisclosure() {
        start(); defer { app.terminate() }
        for _ in 0..<12 {
            if let f = frame(3, 1), f.maxY > 250, f.maxY < app.frame.height - 180 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.3)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.65)))
        }
        guard let original = frame(3, 1) else { XCTFail("Missing middle reply"); return }
        let edge = original.maxY
        XCTAssertGreaterThan(edge, 250); XCTAssertLessThan(edge, app.frame.height - 180)
        capture("middle-long-before")
        button("上一版回答", middle: true).tap(); check("middle-long-to-short-code-direct", index: 3, version: 0, edge: edge)
        button("下一版回答", middle: true).tap(); check("middle-short-to-long-code-direct", index: 3, version: 1, edge: edge)
        button("下一版回答", middle: true).tap(); check("middle-long-to-prose", index: 3, version: 2, edge: edge)
        button("下一版回答", middle: true).tap(); check("middle-prose-to-short-code", index: 3, version: 3, edge: edge)
        button("上一版回答", middle: true).tap(); check("middle-short-code-to-prose", index: 3, version: 2, edge: edge)
        button("上一版回答", middle: true).tap(); check("middle-prose-to-long-code", index: 3, version: 1, edge: edge)
        button("从底部收起代码", middle: true).tap()
        let expanded = app.buttons["从底部展开代码"].firstMatch
        XCTAssertTrue(expanded.waitForExistence(timeout: 12))
        capture("middle-collapsed")
        let collapsedEdge = frame(3, 1)!.maxY
        button("下一版回答", middle: true).tap(); check("middle-fold-to-prose", index: 3, version: 2, edge: collapsedEdge)
        button("上一版回答", middle: true).tap(); check("middle-restored-expanded", index: 3, version: 1, edge: collapsedEdge)
        button("从底部收起代码", middle: true).tap()
        XCTAssertTrue(app.buttons["从底部展开代码"].firstMatch.waitForExistence(timeout: 12))
        button("从底部展开代码", middle: true).tap()
        XCTAssertTrue(app.buttons["从底部收起代码"].firstMatch.waitForExistence(timeout: 12))
        capture("middle-expanded")
        let expandedEdge = frame(3, 1)!.maxY
        button("下一版回答", middle: true).tap(); check("middle-expand-to-prose", index: 3, version: 2, edge: expandedEdge)
        button("上一版回答", middle: true).tap(); check("middle-final-long", index: 3, version: 1, edge: expandedEdge)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.35)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.68)))
        XCTAssertGreaterThan(abs((frame(3, 1)?.maxY ?? expandedEdge) - expandedEdge), 80)
        capture("middle-user-drag")
    }
}
