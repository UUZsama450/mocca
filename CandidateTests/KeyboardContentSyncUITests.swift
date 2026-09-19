import XCTest

/// Simulator actions are recorded externally so animation is checked between
/// endpoints, without XCTest's idle waiting turning every sample into an end.
@MainActor
final class KeyboardContentSyncUITests: XCTestCase {
    func testRepeatedKeyboardAndBottomBounce() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewKeyboardShortChat"]
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        let input = app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息"
        )).firstMatch
        let tail = app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "第三轮短回复："
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 20))
        XCTAssertTrue(input.exists)
        capture(app, "closed-initial")
        for cycle in 0..<3 {
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertLessThan(input.frame.maxY, app.keyboards.firstMatch.frame.minY)
            XCTAssertLessThan(tail.frame.maxY, input.frame.minY)
            capture(app, "open-\(cycle)")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.25)).tap()
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !app.keyboards.firstMatch.exists },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
            XCTAssertLessThan(tail.frame.maxY, input.frame.minY)
            XCTAssertGreaterThan(input.frame.minY, app.frame.height * 0.7)
            capture(app, "closed-\(cycle)")
            if cycle == 1 {
                // Pull beyond the bottom, then release before the next focus.
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.64))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.30))
                for _ in 0..<3 { start.press(forDuration: 0.03, thenDragTo: end) }
                capture(app, "after-bottom-bounce")
            }
        }
    }

    func testHistoricalReadingPositionSurvivesKeyboard() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-previewNavigationStress"]
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        let drawer = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 20))
        drawer.tap()
        let row = app.buttons["导航压力 A"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let input = app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息"
        )).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.26))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.70))
        for _ in 0..<3 { start.press(forDuration: 0.05, thenDragTo: end) }
        // Assistant fixtures deliberately repeat identical paragraphs. A label
        // query can select an offscreen duplicate after keyboard layout. Use a
        // uniquely numbered user message as the stable reading landmark.
        let landmarks = app.textViews.allElementsBoundByIndex + app.staticTexts.allElementsBoundByIndex
        guard let reading = landmarks.first(where: {
            $0.label.hasPrefix("A 用户消息 ") && $0.frame.minY > 130 && $0.frame.maxY < 430
        }) else {
            XCTFail("A uniquely numbered historical user message must be visible")
            return
        }
        let label = reading.label
        let beforeY = reading.frame.minY
        let sameParagraph = app.descendants(matching: reading.elementType).matching(NSPredicate(format: "label == %@", label))
        XCTAssertEqual(sameParagraph.count, 1, "The reading landmark must be unambiguous")
        capture(app, "history-before")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(sameParagraph.firstMatch.exists)
        XCTAssertEqual(sameParagraph.firstMatch.frame.minY, beforeY, accuracy: 3)
        capture(app, "history-keyboard-open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.25)).tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !app.keyboards.firstMatch.exists }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertEqual(sameParagraph.firstMatch.frame.minY, beforeY, accuracy: 3)
        capture(app, "history-keyboard-closed")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("KEYBOARD_SYNC_STEP \(name) time=\(Date().timeIntervalSince1970)")
    }
}
