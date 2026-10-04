import XCTest

@MainActor final class DrawerNativeHitRoutingUITests: XCTestCase {
    func testNativeInteractions() throws { try interactions() }
    func testNativeTextDrags() throws { try textDrags() }

    private func textDrags() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress"]
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        let menu = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        let closedX = menu.frame.minX
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.45))
        for cycle in 0..<3 {
            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            wait { menu.frame.minX > app.frame.width * 0.65 }
            if cycle == 0 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "text-open-native-routing"; shot.lifetime = .keepAlways; add(shot)
            }
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            wait { abs(menu.frame.minX - closedX) < 3 }
            print("ROUTING_UI text-drag-cycle=\(cycle) routing=native")
        }
        menu.tap()
        wait { menu.frame.minX > app.frame.width * 0.65 }
        app.buttons["导航压力 B"].firstMatch.tap()
        wait { abs(menu.frame.minX - closedX) < 3 }
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "B 用户消息 18：")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "text-switched-native-routing"; shot.lifetime = .keepAlways; add(shot)
    }

    private func wait(_ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 12), .completed)
    }

    private func interactions() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewKeyboardShortChat"]
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 3) { app.buttons["稍后"].tap() }
        let menu = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        let closedX = menu.frame.minX
        let tail = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "第三轮短回复：")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15))
        let composer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch

        for cycle in 0..<3 {
            menu.tap()
            wait { menu.frame.minX > app.frame.width * 0.65 }
            // Exposed left list still owns taps: one tap switches/closes.
            app.buttons["键盘测试"].firstMatch.tap()
            wait { abs(menu.frame.minX - closedX) < 3 }
            XCTAssertTrue(tail.exists)
            menu.tap()
            wait { menu.frame.minX > app.frame.width * 0.65 }
            // Native shield must close on the first actual injected tap.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.45)).tap()
            wait { abs(menu.frame.minX - closedX) < 3 }
            print("ROUTING_UI text-cycle=\(cycle) routing=native")
        }

        // First composer touch after closing must still reach the real editor.
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 12))
        composer.typeText("routing check")
        XCTAssertTrue(String(describing: composer.value).contains("routing check"))
        menu.tap()
        wait { menu.frame.minX > app.frame.width * 0.65 }
        app.buttons["键盘测试"].firstMatch.tap()
        wait { abs(menu.frame.minX - closedX) < 3 }

        // An empty page checks that changing the hit route preserves existing
        // ancestor horizontal gestures independently of rich-text arbitration.
        app.buttons["新聊天"].firstMatch.tap()
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.45))
        for cycle in 0..<3 {
            left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            wait { menu.frame.minX > app.frame.width * 0.65 }
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            wait { abs(menu.frame.minX - closedX) < 3 }
            XCTAssertTrue(composer.exists)
            print("ROUTING_UI empty-drag-cycle=\(cycle) routing=native")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "routing-native-final"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
