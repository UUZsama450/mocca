import XCTest

@MainActor
final class PlainProseEntryUITests: XCTestCase {
    private func exercise(_ count: Int) {
        continueAfterFailure = false
        executionTimeAllowance = 360
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        defer { app.terminate() }
        for repetition in 0..<3 {
            app.launchArguments = ["-previewNavigationStress", "-previewPlainLongEntry",
                                   "-previewPlainLongEntryCount", String(count), "-skipStartupPrompt"]
            app.launch()
            let drawer = app.buttons["打开聊天列表"].firstMatch
            XCTAssertTrue(drawer.waitForExistence(timeout: 25))
            drawer.tap()
            XCTAssertTrue(app.buttons["导航压力 B"].firstMatch.waitForExistence(timeout: 15))
            app.terminate()

            app.launchArguments = ["-profileColdProseEntry", "-skipStartupPrompt"]
            app.launch()
            XCTAssertTrue(drawer.waitForExistence(timeout: 25))
            drawer.tap()
            let row = app.buttons["导航压力 A"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            NSLog("[cold-prose-lab] phase=case-begin count=%d repetition=%d", count, repetition)
            row.tap()
            let tail = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "纯长文末尾检查标记。")).firstMatch
            let input = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                tail.exists && input.exists && tail.frame.maxY > 120 && tail.frame.maxY <= input.frame.minY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 30), .completed)
            print("PLAIN_ENTRY count=\(count) repetition=\(repetition) tail=\(tail.frame) input=\(input.frame)")
            if repetition == 0 {
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "plain-\(count)-cold"; image.lifetime = .keepAlways; add(image)
            }
            NSLog("[cold-prose-lab] phase=case-end count=%d repetition=%d", count, repetition)
            app.terminate()
        }
    }
    func test16kColdEntry() { exercise(16_384) }
    func test64kColdEntry() { exercise(65_536) }
}
