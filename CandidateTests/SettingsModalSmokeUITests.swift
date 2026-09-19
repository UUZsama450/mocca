import XCTest

@MainActor final class SettingsModalSmokeUITests: XCTestCase {
    private func open() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.mocca.local.settings-modal-5032")
        app.launch()
        XCTAssertTrue(app.buttons["open-provider"].waitForExistence(timeout: 8))
        app.buttons["open-provider"].tap()
        XCTAssertTrue(app.buttons["modify-draft"].waitForExistence(timeout: 5))
        return app
    }
    private func pull(_ app: XCUIApplication, title: String = "服务商") {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let to = from.withOffset(CGVector(dx: 0, dy: 550))
        from.press(forDuration: 0.1, thenDragTo: to)
    }
    private func leaveAlert(_ app: XCUIApplication, child: Bool = false) -> XCUIElement {
        let alert = app.alerts[child ? "保存模型修改？" : "保存对供应商的修改？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        return alert
    }
    private func expectStats(_ app: XCUIApplication, root: Bool, _ expected: String) {
        let text = app.staticTexts[root ? "root-stats" : "editor-stats"]
        let match = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in text.exists && text.label == expected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCleanPullDismisses() {
        let app = open(); pull(app)
        XCTAssertTrue(app.buttons["open-provider"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-provider"].isHittable)
        expectStats(app, root: true, "attempts=0 saves=0 draftCleanup=0 originalCleanup=0 childSaves=0")
        capture(app, "clean-pull-dismissed")
    }
    func testDirtyPullContinueAndDiscard() {
        let app = open(); app.buttons["modify-draft"].tap(); pull(app)
        capture(app, "dirty-pull-alert")
        leaveAlert(app).buttons["继续编辑"].tap()
        XCTAssertEqual(app.staticTexts["draft-name"].label, "Changed")
        expectStats(app, root: false, "attempts=0 saves=0 draftCleanup=0 originalCleanup=0 childSaves=0")
        pull(app); leaveAlert(app).buttons["不保存"].tap()
        expectStats(app, root: true, "attempts=0 saves=0 draftCleanup=1 originalCleanup=0 childSaves=0")
    }
    func testDirtyPullSaveLeaves() {
        let app = open(); app.buttons["modify-draft"].tap(); pull(app)
        leaveAlert(app).buttons["保存并离开"].tap()
        expectStats(app, root: true, "attempts=1 saves=1 draftCleanup=0 originalCleanup=1 childSaves=0")
    }
    func testToolbarSaveLeaves() {
        let app = open(); app.buttons["modify-draft"].tap(); app.buttons["save-editor"].tap()
        expectStats(app, root: true, "attempts=1 saves=1 draftCleanup=0 originalCleanup=1 childSaves=0")
    }
    func testFailedSaveStaysAndCanDiscard() {
        let app = open(); app.buttons["modify-draft"].tap(); app.buttons["fail-save"].tap()
        app.buttons["cancel-editor"].tap(); leaveAlert(app).buttons["保存并离开"].tap()
        let error = app.alerts["无法保存供应商"]
        XCTAssertTrue(error.waitForExistence(timeout: 4)); capture(app, "failed-save-retained")
        error.buttons["好"].tap()
        XCTAssertEqual(app.staticTexts["draft-name"].label, "Changed")
        expectStats(app, root: false, "attempts=1 saves=0 draftCleanup=0 originalCleanup=0 childSaves=0")
        app.buttons["cancel-editor"].tap(); leaveAlert(app).buttons["不保存"].tap()
        expectStats(app, root: true, "attempts=1 saves=0 draftCleanup=1 originalCleanup=0 childSaves=0")
    }
    func testNestedSheetDoesNotCleanParentDraft() {
        let app = open(); app.buttons["modify-draft"].tap()
        app.buttons["open-child"].tap(); XCTAssertTrue(app.buttons["modify-child"].waitForExistence(timeout: 5))
        pull(app, title: "模型")
        XCTAssertTrue(app.buttons["open-child"].waitForExistence(timeout: 5)); XCTAssertFalse(app.alerts.firstMatch.exists)
        expectStats(app, root: false, "attempts=0 saves=0 draftCleanup=0 originalCleanup=0 childSaves=0")
        app.buttons["open-child"].tap(); XCTAssertTrue(app.buttons["modify-child"].waitForExistence(timeout: 5))
        app.buttons["modify-child"].tap(); pull(app, title: "模型")
        leaveAlert(app, child: true).buttons["继续编辑"].tap()
        XCTAssertEqual(app.staticTexts["child-name"].label, "Child changed")
        pull(app, title: "模型"); leaveAlert(app, child: true).buttons["不保存"].tap()
        XCTAssertTrue(app.buttons["open-child"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["draft-name"].label, "Changed")
        expectStats(app, root: false, "attempts=0 saves=0 draftCleanup=0 originalCleanup=0 childSaves=0")
        capture(app, "parent-draft-after-child")
        pull(app); leaveAlert(app).buttons["不保存"].tap()
        expectStats(app, root: true, "attempts=0 saves=0 draftCleanup=1 originalCleanup=0 childSaves=0")
    }
}
