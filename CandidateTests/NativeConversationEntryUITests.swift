import XCTest

@MainActor
final class BottomEntryUITests: XCTestCase {
    func testEntryRoundTripsAndSameConversationReturn() throws {
        try runEntryChecks(seed: true)
    }

    func testExistingFixtureEntry() throws {
        try runEntryChecks(seed: false)
    }

    func testShortReplyReentryAndKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewKeyboardShortChat", "-diagnoseChatBottom"]
        app.launch()
        let tail = app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "第三轮短回复："
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15))
        // Use the actual input field; the preview focus token can precede the
        // newly mounted composer's observer and is not keyboard UI evidence.
        app.textFields.firstMatch.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let visibleAboveKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tail.exists && tail.frame.minY >= 110
                && tail.frame.maxY < keyboard.frame.minY - 80
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleAboveKeyboard], timeout: 8), .completed)
        capture(app, "short-keyboard-visible")

        let drawer = app.buttons["打开聊天列表"].firstMatch
        for _ in 0..<2 {
            drawer.tap()
            app.buttons["导航压力 A"].tap()
            assertTail(app)
            drawer.tap()
            app.buttons["键盘测试"].firstMatch.tap()
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                tail.exists && tail.frame.minY >= 110
                    && tail.frame.maxY <= app.frame.height - 130
            }, object: nil)
            let result = XCTWaiter.wait(for: [visible], timeout: 12)
            capture(app, "short-reentry")
            XCTAssertEqual(result, .completed)
        }
    }

    private func runEntryChecks(seed: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        let drawer = app.buttons["打开聊天列表"].firstMatch
        if seed {
        app.launchArguments = ["-previewNavigationStress"]
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 10) { later.tap() }
        // Fixture generation is asynchronous; first prove its real drawer row.
        XCTAssertTrue(drawer.waitForExistence(timeout: 20))
        drawer.tap()
        XCTAssertTrue(app.buttons["导航压力 A"].waitForExistence(timeout: 10))
        app.terminate()
        }
        app.launchArguments = ["-diagnoseChatBottom", "-diagnoseVersionFlash"]
        app.launch()
        for name in ["A", "B", "A"] {
            XCTAssertTrue(drawer.waitForExistence(timeout: 15))
            drawer.tap()
            let row = app.buttons["导航压力 \(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.tap()
            capture(app, "before-tail-check-\(name)")
            assertTail(app)
            capture(app, "entry-\(name)")
        }
        // Reopening the same mounted conversation still needs explicit return.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
        let tail = lastParagraph(app)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !tail.exists || tail.frame.maxY > app.frame.height - 130
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        drawer.tap()
        app.buttons["导航压力 A"].tap()
        assertTail(app)
        capture(app, "same-conversation-return")
    }

    private func lastParagraph(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "这是第 18 段模拟回复"
        )).element(boundBy: 3)
    }

    private func assertTail(_ app: XCUIApplication) {
        let tail = lastParagraph(app)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard tail.exists else { return false }
            let frame = tail.frame
            return frame.width > 0 && frame.height > 0
                && frame.minY >= 110 && frame.maxY <= app.frame.height - 130
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 12)
        if result != .completed {
            capture(app, "tail-check-failed")
            print(app.debugDescription)
        }
        XCTAssertEqual(result, .completed)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
