import XCTest

/// Uses generated chats on a disposable simulator. The sheet title and its
/// visible actions are required; the drawer's always-mounted 收藏 is not proof.
@MainActor
final class ReactionDismissalUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewKeyboardShortChat", "-skipStartupPrompt"]
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        XCTAssertTrue(reply(app).waitForExistence(timeout: 20))
        return app
    }
    private func reply(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "第三轮短回复：")).firstMatch
    }
    private func openPicker(_ app: XCUIApplication) {
        let text = reply(app)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.width - 28, dy: text.frame.maxY - 7))
            .press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["更多消息操作"].waitForExistence(timeout: 5))
    }
    private func wait(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 8), .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testMoreCenterAndPaddedCornersOpenActualActionsSheet() {
        let app = launch()
        for (name, point) in [("center", CGVector(dx: 0.5, dy: 0.5)), ("top-left", CGVector(dx: 0.12, dy: 0.12)), ("bottom-right", CGVector(dx: 0.88, dy: 0.88))] {
            openPicker(app)
            let more = app.buttons["更多消息操作"]
            XCTAssertGreaterThanOrEqual(more.frame.width, 34)
            XCTAssertGreaterThanOrEqual(more.frame.height, 41)
            more.coordinate(withNormalizedOffset: point).tap()
            let title = app.staticTexts["消息操作"]
            XCTAssertTrue(title.waitForExistence(timeout: 5), name)
            XCTAssertTrue(title.isHittable)
            XCTAssertTrue(app.buttons["复制"].firstMatch.isHittable)
            XCTAssertFalse(app.buttons["更多消息操作"].exists)
            capture(app, "actions-sheet-" + name)
            title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            wait { !title.exists }
        }
    }
    func testDrawerAndConversationRoundTripDoNotRestoreOldPicker() {
        let app = launch()
        let drawer = app.buttons["打开聊天列表"].firstMatch
        let closedX = drawer.frame.minX
        let openX = closedX + min(app.frame.width * 0.78, 390)
        func returnToChat() {
            app.buttons["键盘测试"].firstMatch.tap()
            wait { abs(drawer.frame.minX - closedX) < 0.5 }
            XCTAssertTrue(reply(app).exists)
            XCTAssertFalse(app.buttons["更多消息操作"].exists)
            XCTAssertFalse(app.staticTexts["消息操作"].exists)
        }
        openPicker(app)
        // The picker scrim intentionally consumes outside taps. Use the real
        // horizontal drawer gesture to open while the picker is still visible.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.45)))
        wait { abs(drawer.frame.minX - openX) < 0.5 }
        XCTAssertFalse(app.buttons["更多消息操作"].exists)
        capture(app, "drawer-clears-picker")
        returnToChat()
        openPicker(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        wait { !app.buttons["更多消息操作"].exists }
        app.buttons["新聊天"].firstMatch.tap()
        wait { !app.buttons["更多消息操作"].exists }
        drawer.tap()
        wait { abs(drawer.frame.minX - openX) < 0.5 }
        returnToChat()
        capture(app, "conversation-round-trip-clears-picker")
    }
    func testReactionAndOutsideDismissalStillWork() {
        let app = launch()
        openPicker(app)
        app.buttons["回应 👍"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        wait { !app.buttons["更多消息操作"].exists }
        openPicker(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        wait { !app.buttons["更多消息操作"].exists }
        XCTAssertFalse(app.staticTexts["消息操作"].exists)
        app.buttons["新聊天"].firstMatch.press(forDuration: 0.65)
        XCTAssertTrue(app.buttons["创建群聊"].waitForExistence(timeout: 5))
        capture(app, "long-press-menu-unchanged")
    }
}
