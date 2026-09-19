import XCTest

@MainActor
final class EntrySnapshotComparisonUITests: XCTestCase {
    private func compare(seed: Bool) {
        continueAfterFailure = false
        executionTimeAllowance = 160
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = seed
            ? ["-previewNavigationStress", "-previewLongContentEntry", "-previewInitialLinkStyle", "-skipStartupPrompt"]
            : ["-skipStartupPrompt"]
        app.launch()
        defer { app.terminate() }
        let drawer = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 25))
        if seed {
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "长正文回归：")).firstMatch.waitForExistence(timeout: 25))
            app.terminate(); app.launchArguments = ["-skipStartupPrompt"]; app.launch()
        }
        let input = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
        for (index, name) in ["B", "A", "B", "A"].enumerated() {
            XCTAssertTrue(drawer.waitForExistence(timeout: 20)); drawer.tap()
            let row = app.buttons["导航压力 \(name)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
            let target = name == "A"
                ? app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "正文末尾检查标记。")).firstMatch
                : app.staticTexts["表格末行 95"].firstMatch
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                target.exists && input.exists && target.frame.maxY > 120 && target.frame.maxY <= input.frame.minY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 20), .completed)
            if name == "A" { XCTAssertTrue(target.label.contains("示例链接")) }
            print("COMPARISON_TAIL \(index) \(name) target=\(target.frame) input=\(input.frame)")
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "comparison-\(index)-\(name)"; image.lifetime = .keepAlways; add(image)
        }
    }
    func testCandidateSeedLinkedProseSnapshots() { compare(seed: true) }
    func testPersistedLinkedProseSnapshots() { compare(seed: false) }
}
