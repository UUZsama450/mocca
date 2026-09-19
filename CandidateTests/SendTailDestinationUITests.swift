import XCTest

@MainActor
final class SendHandoffUITests: XCTestCase {
    private func exercise(_ count: Int, name: String, hidesKeyboard: Bool = false) {
        continueAfterFailure = false
        executionTimeAllowance = 150
        print("HANDOFF_DRIVER_V1")
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress", "-diagnoseChatBottom", "-skipStartupPrompt"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        let input = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        // Persisted fixture, then ordinary cold-load: avoid measuring the
        // preview's wholesale post-mount replacement as a sending behavior.
        app.terminate()
        app.launchArguments = ["-diagnoseNavigationStress", "-diagnoseChatBottom", "-skipStartupPrompt"]
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        app.buttons["打开聊天列表"].firstMatch.tap()
        let row = app.buttons["导航压力 A"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        let bottom = app.buttons["滚动到底部"].firstMatch
        XCTAssertTrue(bottom.waitForExistence(timeout: 8)); bottom.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "这是第 18 段模拟回复"))
                .allElementsBoundByIndex.contains { item in
                    item.frame.minY > 100 && item.frame.maxY < input.frame.minY
                }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        Thread.sleep(forTimeInterval: 1)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        let unit = "这是本机测试发送动画的普通文字，观察长气泡进入聊天后是否分成几段移动。"
        let draft = "发送检查\(name)：" + String(repeating: unit, count: count)
        input.typeText(draft)
        // The pilot UI snapshot identified the actual SF Symbol button as Up.
        if hidesKeyboard {
            // The full navigation rail covers the right edge. Tap the visible
            // transcript gap immediately above the composer, outside text views.
            let point = CGVector(dx: app.frame.width * 0.5, dy: input.frame.minY - 28)
            print("HIDDEN_KEYBOARD_TAP inputFrame=\(input.frame) point=\(point)")
            let beforeHide = XCTAttachment(screenshot: app.screenshot())
            beforeHide.name = "before-hide-keyboard"; beforeHide.lifetime = .keepAlways
            add(beforeHide)
            app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !app.keyboards.firstMatch.exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        }
        let send = app.buttons["Up"].firstMatch
        XCTAssertTrue(send.isHittable && send.isEnabled)
        print("SEND_MOTION_BEGIN name=\(name) chars=\(draft.count) uptime=\(ProcessInfo.processInfo.systemUptime) sendLabel=\(send.label)")
        let pre = XCTAttachment(screenshot: app.screenshot()); pre.name = "before-send"; pre.lifetime = .keepAlways; add(pre)
        send.tap()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(send.waitForExistence(timeout: 12), "Local fixture reply should finish")
        print("SEND_MOTION_END name=\(name) uptime=\(ProcessInfo.processInfo.systemUptime)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name + "-after-send"; attachment.lifetime = .keepAlways
        add(attachment)
        for text in app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "发送检查")).allElementsBoundByIndex {
            print("SEND_USER_TEXT_FRAME \(text.frame)")
        }
        XCTAssertEqual(input.value as? String, "", "Successful send should clear the draft")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
    func testShort() { exercise(0, name: "short") }
    func testMedium() { exercise(7, name: "medium") }
    func testLong() { exercise(12, name: "long") }
    func testVeryLong() { exercise(24, name: "veryLong") }
    func testKeyboardAlreadyHidden() { exercise(12, name: "keyboardHidden", hidesKeyboard: true) }
}
