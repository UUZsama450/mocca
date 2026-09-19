import XCTest

@MainActor
final class DrawerFadeUITests: XCTestCase {
    func testSearchAndSelectionAfterRepeatedDrawerMovement() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress"]
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 3) { app.buttons["稍后"].tap() }
        let drawer = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 20))
        for _ in 0..<3 {
            drawer.tap()
            XCTAssertTrue(app.buttons["搜索聊天"].waitForExistence(timeout: 10))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.45)).tap()
        }
        drawer.tap()
        app.buttons["搜索聊天"].tap()
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("导航压力 B")
        let row = app.buttons["导航压力 B"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in drawer.frame.minX < 100 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 10), .completed)
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "B 用户消息 18：")).firstMatch
        XCTAssertTrue(message.exists)
        drawer.tap()
        XCTAssertTrue(app.buttons["搜索聊天"].waitForExistence(timeout: 10), "Closing clears drawer search mode")
        XCTAssertTrue(app.buttons["导航压力 A"].firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "drawer-after-search-return"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
