import XCTest

@MainActor
final class SearchFocusScopeUITests: XCTestCase {
    private func input(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
    }
    private func wait(_ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 10), .completed)
    }
    private func seededApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress", "-diagnoseChatBottom", "-skipStartupPrompt"]
        app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launchArguments = ["-diagnoseNavigationStress", "-diagnoseChatBottom", "-skipStartupPrompt"]
        app.launch()
        XCTAssertTrue(input(app).waitForExistence(timeout: 20))
        return app
    }
    private func search(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["搜索聊天"].firstMatch.tap()
        let field = app.textFields["搜索当前助手标题"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        return field
    }
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testChatFocusAfterDrawerClose() {
        for cycle in 0..<3 {
            let app = seededApp()
            app.buttons["打开聊天列表"].firstMatch.tap()
            let row = app.buttons["导航压力 A"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
            let bottom = app.buttons["滚动到底部"].firstMatch
            XCTAssertTrue(bottom.waitForExistence(timeout: 8)); bottom.tap()
            wait {
                app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "这是第 18 段模拟回复")).allElementsBoundByIndex.contains {
                    $0.frame.minY > 100 && $0.frame.maxY < self.input(app).frame.minY
                }
            }
            print("SEARCH_FOCUS_SCOPE=v1 cycle=\(cycle) phase=before-chat-tap frame=\(input(app).frame)")
            input(app).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
            input(app).typeText("9159")
            wait { self.input(app).value as? String == "9159" }
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            print("SEARCH_FOCUS_SCOPE=v1 cycle=\(cycle) chat-input=pass")
            snapshot(app, "chat-input-\(cycle)")
            app.terminate()
        }
    }

    func testSearchExitButtonsReleaseSearchFocus() {
        let app = seededApp(); defer { app.terminate() }
        app.buttons["打开聊天列表"].firstMatch.tap()
        for label in ["关闭搜索", "结束搜索"] {
            let field = search(app)
            field.typeText("9159")
            wait { field.value as? String == "9159" }
            app.buttons[label].firstMatch.tap()
            wait { !app.keyboards.firstMatch.exists && !field.exists }
            XCTAssertTrue(app.buttons["搜索聊天"].firstMatch.exists)
            XCTAssertTrue(app.buttons["导航压力 A"].firstMatch.waitForExistence(timeout: 8))
            print("SEARCH_FOCUS_SCOPE=v1 search-exit=\(label) keyboard-hidden=true query-reset=true")
        }
        snapshot(app, "search-buttons-closed")
    }

    func testSearchConversationSelectionThenChatFocus() {
        let app = seededApp(); defer { app.terminate() }
        app.buttons["打开聊天列表"].firstMatch.tap()
        let field = search(app)
        field.typeText("导航压力")
        let row = app.buttons["导航压力 A"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()
        wait { !field.exists && !app.keyboards.firstMatch.exists }
        input(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        input(app).typeText("9160")
        wait { self.input(app).value as? String == "9160" }
        snapshot(app, "search-selection-chat-input")
        print("SEARCH_FOCUS_SCOPE=v1 search-selection=pass chat-input=pass")
    }
}
