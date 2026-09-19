import XCTest

/// Full app checks use generated conversations on a disposable simulator.
/// The separate keyframe harness covers sub-100ms interruptions, since XCTest
/// waits for idle between taps and cannot prove that timing itself.
@MainActor final class ConversationSwitchFadeUITests: XCTestCase {
    private func launchFixtures() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress", "-skipStartupPrompt"]
        app.launch()
        dismissStartup(app)
        let drawer = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 20))
        drawer.tap()
        XCTAssertTrue(app.buttons["导航压力 A"].firstMatch.waitForExistence(timeout: 12))
        app.terminate()
        app.launchArguments = ["-previewKeyboardShortChat", "-skipStartupPrompt"]
        app.launch()
        dismissStartup(app)
        XCTAssertTrue(shortReply(app).waitForExistence(timeout: 20))
        return app
    }
    private func dismissStartup(_ app: XCUIApplication) {
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
    }
    private func shortReply(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "第三轮短回复：")).firstMatch
    }
    private func input(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
    }
    private func wait(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 12), .completed)
    }
    private func select(_ name: String, in app: XCUIApplication) {
        let drawer = app.buttons["打开聊天列表"].firstMatch
        let closedX = drawer.frame.minX
        drawer.tap()
        let row = app.buttons[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        wait { row.isHittable }
        row.tap()
        wait { abs(drawer.frame.minX - closedX) < 0.5 }
        XCTAssertTrue(input(app).isHittable)
        if name == "键盘测试" {
            wait { self.shortReply(app).exists && self.shortReply(app).frame.maxY < self.input(app).frame.minY }
        } else {
            wait {
                app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "这是第 18 段模拟回复"))
                    .allElementsBoundByIndex.contains { view in
                        view.frame.width > 0 && view.frame.minY >= 100 && view.frame.maxY < self.input(app).frame.minY
                    }
            }
        }
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testLongShortEmptyAndSameConversation() {
        let app = launchFixtures()
        for name in ["导航压力 A", "导航压力 B", "键盘测试", "键盘测试"] { select(name, in: app) }
        app.buttons["新聊天"].firstMatch.tap()
        wait { !self.shortReply(app).exists }
        XCTAssertTrue(input(app).isHittable)
        capture(app, "empty-conversation")
        select("键盘测试", in: app)
        capture(app, "short-after-empty")
    }
    func testKeyboardAfterConversationSwitch() {
        let app = launchFixtures()
        select("导航压力 A", in: app)
        select("键盘测试", in: app)
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        wait { self.shortReply(app).frame.maxY < self.input(app).frame.minY }
        XCTAssertLessThan(input(app).frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture(app, "keyboard-after-switch")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.23)).tap()
        wait { !app.keyboards.firstMatch.exists }
        select("导航压力 B", in: app)
        capture(app, "switch-after-keyboard-dismissal")
    }
}
