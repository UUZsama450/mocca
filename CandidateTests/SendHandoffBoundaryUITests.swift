import XCTest

@MainActor
final class SendHandoffBoundaryUITests: XCTestCase {
    private func exercise(_ count: Int, name: String, hidesKeyboard: Bool = false, takesOver: Bool = false) {
        continueAfterFailure = false
        executionTimeAllowance = 150
        print("HANDOFF_BOUNDARY_DRIVER_V2")
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
        // Match the user's simple navigation setting through its real UI.
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
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["到顶部"].exists)
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
        if takesOver {
            Thread.sleep(forTimeInterval: 1)
            print("HANDOFF_READER_TAKEOVER uptime=\(ProcessInfo.processInfo.systemUptime)")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.30))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(app.buttons["回到最新消息"].waitForExistence(timeout: 8))
            Thread.sleep(forTimeInterval: 1)
            let reading = XCTAttachment(screenshot: app.screenshot())
            reading.name = "reader-settled"; reading.lifetime = .keepAlways; add(reading)
            print("HANDOFF_READER_SETTLED uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(send.waitForExistence(timeout: 35), "Local fixture reply should finish")
        Thread.sleep(forTimeInterval: 1)
        if takesOver {
            XCTAssertTrue(app.buttons["回到最新消息"].exists)
            let reading = XCTAttachment(screenshot: app.screenshot())
            reading.name = "reader-completed"; reading.lifetime = .keepAlways; add(reading)
        } else {
            XCTAssertFalse(app.buttons["回到最新消息"].exists, "Completed reply should retain bottom follow")
        }
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
    func testSimpleLongSend() { exercise(12, name: "simpleLong") }
    func testStreamingUserTakeover() { exercise(12, name: "readerTakeover", takesOver: true) }
}
