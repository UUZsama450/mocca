import XCTest
@MainActor final class DialogOrderUITests: XCTestCase {
    private func open(_ mode: String = "normal") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [mode]; app.launch()
        XCTAssertTrue(app.buttons["Open confirmation"].waitForExistence(timeout: 8))
        return app
    }
    private func alert(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Open confirmation"].tap()
        XCTAssertTrue(app.alerts["保存修改？"].waitForExistence(timeout: 5))
        return app.alerts["保存修改？"]
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot=XCTAttachment(screenshot: app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)
    }
    func testDiscardLastAndKeepEditingPreservesDraft() {
        let app=open();defer{app.terminate()};let a=alert(app)
        XCTAssertLessThan(a.buttons["保存并离开"].frame.midY,a.buttons["继续编辑"].frame.midY)
        XCTAssertLessThan(a.buttons["继续编辑"].frame.midY,a.buttons["不保存"].frame.midY)
        capture(app,"discard-last")
        a.buttons["继续编辑"].tap();XCTAssertEqual(app.staticTexts["outcome"].label,"unchanged")
        alert(app).buttons["不保存"].tap();XCTAssertEqual(app.staticTexts["outcome"].label,"discarded")
    }
    func testSaveCallsSaveAndFailedSaveCanShowError() {
        let app=open();alert(app).buttons["保存并离开"].tap();XCTAssertEqual(app.staticTexts["outcome"].label,"saved");app.terminate()
        let failed=open("failure");defer{failed.terminate()}
        alert(failed).buttons["保存并离开"].tap()
        XCTAssertTrue(failed.alerts["保存失败"].waitForExistence(timeout:5))
        failed.alerts["保存失败"].buttons["好"].tap()
        XCTAssertEqual(failed.staticTexts["outcome"].label,"unchanged")
    }
    func testDisabledAndHiddenSaveRulesRemain() {
        let disabled=open("disabled");let d=alert(disabled);XCTAssertFalse(d.buttons["保存并离开"].isEnabled);d.buttons["继续编辑"].tap();disabled.terminate()
        let hidden=open("hidden");defer{hidden.terminate()};let h=alert(hidden)
        XCTAssertFalse(h.buttons["保存并离开"].exists);XCTAssertTrue(h.buttons["继续编辑"].exists);XCTAssertTrue(h.buttons["不保存"].exists)
        h.buttons["继续编辑"].tap();XCTAssertEqual(hidden.staticTexts["outcome"].label,"unchanged")
    }
    func testMessageSaveLeftAndSendRightHaveCorrectActions() {
        let app=open();defer{app.terminate()};app.buttons["Edit message"].tap()
        XCTAssertTrue(app.buttons["保存并发送"].waitForExistence(timeout:5))
        XCTAssertLessThan(app.buttons["保存"].frame.midX,app.buttons["保存并发送"].frame.midX)
        capture(app,"save-left-send-right")
        app.buttons["保存"].tap();XCTAssertEqual(app.staticTexts["outcome"].label,"saved")
        app.buttons["Edit message"].tap();app.buttons["保存并发送"].tap();XCTAssertEqual(app.staticTexts["outcome"].label,"sent")
    }
    func testSaveOnlyEditorRetainsCancel() {
        let app=open("saveOnly");defer{app.terminate()};app.buttons["Edit message"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["保存并发送"].exists)
        app.buttons["取消"].tap();XCTAssertEqual(app.staticTexts["outcome"].label,"unchanged")
    }
    func testProviderMenuLogosHaveNativeIntrinsicSize() {
        let app=open();defer{app.terminate()}
        XCTAssertEqual(app.staticTexts["size.OpenAI"].label,"OpenAI: 24x24")
        XCTAssertEqual(app.staticTexts["size.Claude"].label,"Claude: 24x24")
        app.buttons["Provider logos"].tap()
        XCTAssertTrue(app.buttons["OpenAI"].waitForExistence(timeout:5));XCTAssertTrue(app.buttons["Claude"].exists)
        capture(app,"native-provider-logos")
    }
    func testProviderPickerOriginalLogoInLightAndDark() {
        for mode in ["normal", "dark"] {
            let app = open(mode)
            XCTAssertTrue(app.buttons["provider-type-picker"].exists)
            capture(app, "provider-picker-" + mode)
            app.buttons["provider-type-picker"].tap()
            XCTAssertTrue(app.buttons["Claude"].waitForExistence(timeout: 5))
            capture(app, "provider-picker-menu-" + mode)
            app.terminate()
        }
    }
}
