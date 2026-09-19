import XCTest

/// Uses synthetic chats and selects .simple through the real settings UI.
/// Video and visibility logs cover the animation between XCTest's idle checks.
@MainActor
final class SimpleArrowKeyboardUITests: XCTestCase {
    private func open() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress", "-diagnoseChatBottom", "-skipStartupPrompt"]
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        app.buttons["打开聊天列表"].firstMatch.tap()
        app.buttons["设置"].firstMatch.tap()
        let preferences = app.buttons["偏好设置"].firstMatch
        for _ in 0..<5 where !preferences.isHittable { app.swipeUp() }
        XCTAssertTrue(preferences.isHittable); preferences.tap()
        let behavior = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "行为与启动")).firstMatch
        for _ in 0..<5 where !behavior.isHittable { app.swipeUp() }
        XCTAssertTrue(behavior.isHittable); behavior.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "消息导航按钮")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["简单"].firstMatch.tap()
        XCTAssertTrue(picker.label.contains("简单"))
        app.navigationBars["行为与启动"].buttons.firstMatch.tap()
        app.navigationBars["偏好设置"].buttons.firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
        let row = app.buttons["导航压力 A"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(input(app).waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["到顶部"].exists, "Full navigation must not replace simple mode")
        return app
    }

    private func input(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息"
        )).firstMatch
    }
    private func arrow(_ app: XCUIApplication) -> XCUIElement { app.buttons["回到最新消息"].firstMatch }
    private func wait(_ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 10), .completed)
    }
    private func mark(_ name: String) {
        print("SIMPLE_ARROW_STEP name=\(name) uptime=\(ProcessInfo.processInfo.systemUptime)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func dismissKeyboard(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.25)).tap()
        wait { !app.keyboards.firstMatch.exists }
    }
    private func readHistory(_ app: XCUIApplication, drags: Int = 3) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.26))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.60))
        for _ in 0..<drags { start.press(forDuration: 0.05, thenDragTo: end) }
        XCTAssertTrue(arrow(app).waitForExistence(timeout: 8))
        XCTAssertTrue(arrow(app).isHittable)
    }

    func testBottomKeyboardCycles() {
        let app = open(); defer { app.terminate() }
        XCTAssertFalse(arrow(app).exists)
        mark("bottomCyclesBegin")
        for cycle in 0..<3 {
            mark("open-\(cycle)")
            input(app).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
            XCTAssertFalse(arrow(app).exists)
            mark("close-\(cycle)")
            dismissKeyboard(app)
            XCTAssertFalse(arrow(app).exists)
        }
        mark("bottomCyclesEnd")
        capture(app, "bottom-after-three-cycles")
    }

    func testHistoryKeyboardAndReturn() {
        let app = open(); defer { app.terminate() }
        readHistory(app)
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "A 用户消息 ")
        var reading: XCUIElement?
        // A fixed number of drags can stop between two long assistant rows.
        // Establish a fully visible numbered user row before measuring it.
        for attempt in 0..<6 {
            let landmarks = app.textViews.matching(predicate).allElementsBoundByIndex
                + app.staticTexts.matching(predicate).allElementsBoundByIndex
            reading = landmarks.first(where: { $0.frame.minY > 130 && $0.frame.maxY < 430 })
            if reading != nil { break }
            if attempt < 5 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.48))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        guard let landmark = reading else {
            XCTFail("Unique history landmark required"); return
        }
        let same = app.descendants(matching: landmark.elementType).matching(NSPredicate(format: "label == %@", landmark.label))
        XCTAssertEqual(same.count, 1)
        let beforeY = landmark.frame.minY
        mark("history-open")
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(arrow(app).exists)
        XCTAssertEqual(same.firstMatch.frame.minY, beforeY, accuracy: 3)
        dismissKeyboard(app)
        XCTAssertTrue(arrow(app).isHittable)
        XCTAssertEqual(same.firstMatch.frame.minY, beforeY, accuracy: 3)
        mark("history-return")
        arrow(app).tap()
        wait { !self.arrow(app).exists }
        capture(app, "history-return-landed")
    }

    func testUserDragWithKeyboard() {
        let app = open(); defer { app.terminate() }
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        mark("user-takes-over")
        readHistory(app, drags: 2)
        capture(app, "arrow-after-user-takeover")
        arrow(app).tap()
        wait { !self.arrow(app).exists }
    }

    func testToolsAndModelRoundTrips() {
        let app = open(); defer { app.terminate() }
        mark("modalBegin")
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        app.buttons["打开工具菜单"].firstMatch.tap()
        XCTAssertTrue(app.buttons["拍照"].waitForExistence(timeout: 8))
        wait { !app.keyboards.firstMatch.exists }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.20)).tap()
        wait { !app.buttons["拍照"].exists }
        XCTAssertFalse(arrow(app).exists)
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        app.buttons["助手"].firstMatch.tap()
        XCTAssertTrue(app.buttons["关闭模型选择"].waitForExistence(timeout: 8))
        wait { !app.keyboards.firstMatch.exists }
        app.buttons["关闭模型选择"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(arrow(app).exists)
        mark("modalEnd")
        capture(app, "model-returned")
    }

    func testEmptyChatKeyboard() {
        let app = open(); defer { app.terminate() }
        app.buttons["新聊天"].firstMatch.tap()
        XCTAssertTrue(input(app).exists)
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(arrow(app).exists)
        dismissKeyboard(app)
        XCTAssertFalse(arrow(app).exists)
        XCTAssertTrue(input(app).isHittable)
    }
}
