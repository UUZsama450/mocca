import XCTest

@MainActor
final class LongContentEntryUITests: XCTestCase {
    func testLongProseAndTableColdAndWarmEntry() {
        continueAfterFailure = false
        executionTimeAllowance = 240
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress", "-previewLongContentEntry", "-previewInitialLinkStyle", "-skipStartupPrompt"]
        app.launch()
        defer { app.terminate() }
        let drawer = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 25))
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        let longText = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "长正文回归：")).firstMatch
        XCTAssertTrue(longText.waitForExistence(timeout: 25), "fixture generation must finish before relaunch")
        app.terminate()
        app.launchArguments = ["-skipStartupPrompt"]
        app.launch()
        let input = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
        // TextKit exposes paragraphs as separate accessibility text elements.
        // The offscreen title's AX frame is not the complete document frame.
        let proseTail = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "正文末尾检查标记。")).firstMatch
        for (index, name) in ["B", "A", "B", "A"].enumerated() {
            XCTAssertTrue(drawer.waitForExistence(timeout: 20))
            drawer.tap()
            let row = app.buttons["导航压力 \(name)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
            let target = name == "A" ? proseTail : app.staticTexts["表格末行 95"].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 20))
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                target.exists && input.exists && target.frame.maxY > 120
                    && target.frame.maxY <= input.frame.minY
                    && (name == "A" || target.frame.minY >= 100)
            }, object: nil)
            let result = XCTWaiter.wait(for: [visible], timeout: 20)
            print("ENTRY_TAIL \(name) target=\(target.frame) input=\(input.frame)")
            XCTAssertEqual(result, .completed,
                           "real tail should be visible above the composer after entry")
            if name == "A" {
                XCTAssertTrue(proseTail.label.contains("正文末尾检查标记。"))
                XCTAssertTrue(proseTail.label.contains("示例链接"))
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "long-entry-\(index)-\(name)"; shot.lifetime = .keepAlways; add(shot)
        }
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(proseTail.exists)
        let keyboardShot = XCTAttachment(screenshot: app.screenshot())
        keyboardShot.name = "long-prose-keyboard"; keyboardShot.lifetime = .keepAlways; add(keyboardShot)
    }
}
