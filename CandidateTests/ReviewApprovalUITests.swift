import XCTest
final class ReviewApprovalUITests: XCTestCase {
    func testIdentityAndRepeatedMCPAndCalendarPresentation() {
        let app=XCUIApplication(bundleIdentifier:"com.mocca.local.review-approval-5047")
        app.launch()
        for label in ["MCP", "日历", "MCP"] {
            app.buttons[label].tap()
            let alert=app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout:5))
            XCTAssertTrue(alert.staticTexts.element(matching:NSPredicate(format:"label CONTAINS %@","Synthetic chat")).exists)
            alert.buttons["允许"].tap()
            XCTAssertTrue(app.staticTexts["approved"].waitForExistence(timeout:5))
        }
        app.buttons["日历"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:5))
        app.alerts.buttons["拒绝"].tap()
        XCTAssertTrue(app.staticTexts["approval_denied"].waitForExistence(timeout:5))
    }
    func testConcurrentKindsHaveExplicitBusyResultAndOriginalAlertStillWorks() {
        let app=XCUIApplication(bundleIdentifier:"com.mocca.local.review-approval-5047")
        app.launch();app.buttons["同时请求"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:5))
        app.alerts.buttons["允许"].tap()
        XCTAssertTrue(app.staticTexts["approved"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["approval_busy"].exists)
    }
    func testCancellationDismissesAlertAndNextRequestRemainsUsable() {
        let app=XCUIApplication(bundleIdentifier:"com.mocca.local.review-approval-5047")
        app.launch();app.buttons["自动取消"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:5))
        let gone=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.alerts.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[gone],timeout:8),.completed)
        XCTAssertTrue(app.staticTexts["request_expired"].exists)
        app.buttons["MCP"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:5))
        app.alerts.buttons["允许"].tap()
        XCTAssertTrue(app.staticTexts["approved"].waitForExistence(timeout:5))
    }

}
