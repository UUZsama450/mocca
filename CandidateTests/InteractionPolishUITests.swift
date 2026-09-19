import XCTest

@MainActor
final class InteractionPolishUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewKeyboardShortChat", "-skipStartupPrompt"]
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        XCTAssertTrue(app.buttons["打开聊天列表"].firstMatch.waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func wait(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 8), .completed)
    }
    func testHapticMasterRetainsAndDisablesChildren() {
        let app = launch()
        let drawer = app.buttons["打开聊天列表"].firstMatch
        let openX = drawer.frame.minX + min(app.frame.width * 0.78, 390)
        drawer.tap()
        wait { abs(drawer.frame.minX - openX) < 0.5 }
        app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
        let preferences = app.buttons["偏好设置"]
        for _ in 0..<5 where !preferences.isHittable { app.swipeUp() }
        XCTAssertTrue(preferences.isHittable); preferences.tap()
        let haptics = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "震动反馈")).firstMatch
        for _ in 0..<5 where !haptics.isHittable { app.swipeUp() }
        XCTAssertTrue(haptics.isHittable); haptics.tap()
        let global = app.switches["全局震动"]
        XCTAssertTrue(global.waitForExistence(timeout: 8))
        if global.value as? String == "0" { global.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        let names = ["开关震动", "侧栏开关震动", "列表项点击震动", "卡片点击震动", "生成时震动"]
        let values = names.map { app.switches[$0].value as? String }
        XCTAssertEqual(names.map { app.switches[$0].isEnabled }, Array(repeating: true, count: 5))
        global.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        wait { names.allSatisfy { !app.switches[$0].isEnabled } }
        XCTAssertEqual(names.map { app.switches[$0].value as? String }, values)
        capture(app, "haptics-master-off")
        global.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        wait { names.allSatisfy { app.switches[$0].isEnabled } }
        XCTAssertEqual(names.map { app.switches[$0].value as? String }, values)
        capture(app, "haptics-restored")
    }
    func testAssistantReactionDismissMoreAndHeaderMenu() {
        let app = launch()
        let reply = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "第三轮短回复：")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        // The production blank-area recognizer lives behind the full assistant row.
        // Use the trailing blank area of its final text line, not selectable glyphs.
        func openPicker() {
            let point = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 28, dy: reply.frame.maxY - 7))
            point.press(forDuration: 0.65)
            XCTAssertTrue(app.buttons["更多消息操作"].waitForExistence(timeout: 5))
        }
        openPicker(); capture(app, "assistant-glass-strip")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        wait { !app.buttons["更多消息操作"].exists }
        openPicker()
        app.buttons["回应 👍"].firstMatch.tap()
        wait { !app.buttons["更多消息操作"].exists }
        openPicker(); app.buttons["更多消息操作"].tap()
        // The drawer also exposes 收藏 while mounted; require the actual sheet.
        XCTAssertTrue(app.staticTexts["消息操作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["消息操作"].isHittable)
        XCTAssertTrue(app.buttons["复制"].firstMatch.isHittable)
        capture(app, "assistant-more-actions")
        app.swipeDown()
        let header = app.buttons["新聊天"].firstMatch
        wait { header.isHittable }
        header.press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["创建群聊"].waitForExistence(timeout: 5))
        capture(app, "new-chat-long-press-unchanged")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap()
        header.tap(); header.tap()
        XCTAssertTrue(app.buttons["打开聊天列表"].firstMatch.exists)
        capture(app, "new-chat-repeated-tap")
    }
}
