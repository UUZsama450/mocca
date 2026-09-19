import XCTest

/// Run against the installed simulator app. Capture scroll-command logs and
/// video externally: reaching the final bottom alone cannot detect a jump.
@MainActor
final class KeyboardModalHandoffUITests: XCTestCase {
    func testOrdinaryDismissal() { run("ordinary") }
    func testToolsPresentation() { run("tools") }
    func testModelPresentation() { run("models") }
    func testShortToolsRoundTrip() { run("tools", short: true, roundTrip: true) }
    func testShortModelRoundTrip() { run("models", short: true, roundTrip: true) }
    func testHistoricalToolsRoundTrip() { run("tools", history: true, roundTrip: true) }
    func testHistoricalModelRoundTrip() { run("models", history: true, roundTrip: true) }
    func testEmptyToolsRoundTrip() { run("tools", short: true, empty: true, roundTrip: true) }
    func testEmptyModelRoundTrip() { run("models", short: true, empty: true, roundTrip: true) }

    private func run(
        _ route: String, short: Bool = false, history: Bool = false,
        empty: Bool = false, roundTrip: Bool = false
    ) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = [short ? "-previewKeyboardShortChat" : "-previewNavigationStress", "-diagnoseChatBottom"]
        app.launch()
        defer { app.terminate() }
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        let tools = app.buttons["打开工具菜单"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 30))
        if empty { app.buttons["新聊天"].firstMatch.tap() }
        let input = app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息"
        )).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        var reading: XCUIElement?
        var readingY: CGFloat = 0
        if history {
            // Enter the seeded conversation through the normal UI, as in the
            // existing historical-keyboard regression. Direct post-mount
            // fixture mutation is a separate baseline layout stress case.
            app.buttons["打开聊天列表"].firstMatch.tap()
            let row = app.buttons["导航压力 A"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.26))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.70))
            for _ in 0..<3 { start.press(forDuration: 0.05, thenDragTo: end) }
            let numberedMessage = NSPredicate(format: "label BEGINSWITH %@", "A 用户消息 ")
            let landmarks = app.textViews.matching(numberedMessage).allElementsBoundByIndex
                + app.staticTexts.matching(numberedMessage).allElementsBoundByIndex
            guard let landmark = landmarks.first(where: { $0.frame.minY > 130 && $0.frame.maxY < 430 }) else {
                XCTFail("A uniquely numbered historical user message must be visible")
                return
            }
            let matches = app.descendants(matching: landmark.elementType).matching(
                NSPredicate(format: "label == %@", landmark.label)
            )
            XCTAssertEqual(matches.count, 1)
            reading = matches.firstMatch
            readingY = landmark.frame.minY
        }
        print("MODAL_AUDIT route=\(route) short=\(short) history=\(history) empty=\(empty) step=beforeFocus uptime=\(ProcessInfo.processInfo.systemUptime)")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        if let reading { XCTAssertEqual(reading.frame.minY, readingY, accuracy: 3) }
        Thread.sleep(forTimeInterval: 1)
        snapshot(app, "\(route)-keyboard-open")
        print("MODAL_AUDIT route=\(route) step=action uptime=\(ProcessInfo.processInfo.systemUptime)")
        if route == "ordinary" {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.25)).tap()
        } else if route == "tools" {
            tools.tap()
            XCTAssertTrue(app.buttons["拍照"].waitForExistence(timeout: 8))
        } else {
            app.buttons["助手"].firstMatch.tap()
            XCTAssertTrue(app.buttons["关闭模型选择"].waitForExistence(timeout: 8))
        }
        wait { !app.keyboards.firstMatch.exists }
        Thread.sleep(forTimeInterval: 2)
        snapshot(app, "\(route)-settled")
        print("MODAL_AUDIT route=\(route) step=settled uptime=\(ProcessInfo.processInfo.systemUptime)")
        guard roundTrip else { return }
        if route == "tools" {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.20)).tap()
            wait { !app.buttons["拍照"].exists }
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        } else {
            app.buttons["关闭模型选择"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        }
        XCTAssertTrue(input.isHittable)
        if let reading { XCTAssertEqual(reading.frame.minY, readingY, accuracy: 3) }
        if short && !empty {
            let tail = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "第三轮短回复：")).firstMatch
            XCTAssertTrue(tail.exists)
            XCTAssertGreaterThan(tail.frame.minY, 100)
            XCTAssertLessThan(tail.frame.maxY, input.frame.minY)
        }
        snapshot(app, "\(route)-returned")
    }

    private func wait(_ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 8), .completed)
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
