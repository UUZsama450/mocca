import XCTest

@MainActor final class BottomEntryUITests: XCTestCase {
    let bundle = "com.mocca.local.history-native-reading5075"
    private func geometry(_ app: XCUIApplication) -> [String: Any]? {
        let surface = app.descendants(matching: .any).matching(identifier: "nativeChat.transcript").firstMatch
        guard surface.exists, let value = surface.value as? String,
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func frame(_ app: XCUIApplication, _ id: String) -> CGRect? {
        guard let frames = geometry(app)?["frames"] as? [String: [String: Double]], let f = frames[id] else { return nil }
        return CGRect(x: f["x"]!, y: f["y"]!, width: f["width"]!, height: f["height"]!)
    }
    private func id(_ index: Int, _ version: Int) -> String {
        String(format: "50750000-0000-4000-8%d00-%012d", version, index)
    }
    private func waitFrame(_ app: XCUIApplication, _ id: String, bottom: Bool, edge: CGFloat? = nil) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let f = self.frame(app, id), let geometry = self.geometry(app),
                  let viewport = geometry["viewportHeight"] as? Double else { return false }
            let visible = f.maxY > 0 && f.minY < viewport - 120
            if bottom { return visible && abs(geometry["bottomGap"] as? Double ?? 99999) <= 2 }
            return visible && (edge == nil || abs(f.maxY - edge!) <= 2)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12), .completed, "Expected measured landing for \(id)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let g = geometry(app), let data = try? JSONSerialization.data(withJSONObject: g, options: .prettyPrinted) {
            let log = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); log.name = name; log.lifetime = .keepAlways; add(log)
        }
    }
    func testTailAndMiddleReplacementRoundTrip() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = ["-previewNativeReadingFixture", "versions", "-diagnoseChatBottom"]
        app.launch()
        let later = app.buttons["稍后"]; if later.waitForExistence(timeout: 3) { later.tap() }
        waitFrame(app, id(7, 1), bottom: true)
        capture(app, "tail-before")
        for i in 0..<3 {
            app.buttons.matching(identifier: "下一版回答").allElementsBoundByIndex.last(where: { $0.isHittable })!.tap()
            waitFrame(app, id(7, 2), bottom: true)
            capture(app, "tail-short-\(i)")
            app.buttons.matching(identifier: "上一版回答").allElementsBoundByIndex.last(where: { $0.isHittable })!.tap()
            waitFrame(app, id(7, 1), bottom: true)
            capture(app, "tail-long-\(i)")
        }
        // Make the following reply short, then scroll to a middle reply's controls.
        app.buttons.matching(identifier: "下一版回答").allElementsBoundByIndex.last(where: { $0.isHittable })!.tap()
        waitFrame(app, id(7, 2), bottom: true)
        for _ in 0..<12 {
            if let f = frame(app, id(3, 1)), f.maxY > 250, f.maxY < app.frame.height - 180 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)))
        }
        guard let middle = frame(app, id(3, 1)) else { XCTFail("Middle reply missing"); return }
        let edge = middle.maxY
        capture(app, "middle-before")
        app.buttons.matching(identifier: "下一版回答").allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        waitFrame(app, id(3, 2), bottom: false, edge: edge)
        capture(app, "middle-short")
        app.buttons.matching(identifier: "上一版回答").allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        waitFrame(app, id(3, 1), bottom: false, edge: edge)
        capture(app, "middle-long")
        // A drag after a version edit remains user-owned and must not snap back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)))
        let moved = frame(app, id(3, 1))?.maxY
        XCTAssertNotNil(moved)
        XCTAssertGreaterThan(abs((moved ?? edge) - edge), 80)
        capture(app, "middle-after-user-drag")
    }
}
