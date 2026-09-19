import XCTest

@MainActor
final class WarmProseUITests: XCTestCase {
    private func exercise(rich: Bool, seed: Bool = true) {
        continueAfterFailure = false
        executionTimeAllowance = 240
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        if seed {
            app.launchArguments = ["-previewNavigationStress", "-previewPlainLongEntry",
                                   "-previewPlainLongEntryCount", "16384", "-skipStartupPrompt"]
            if rich { app.launchArguments += ["-previewLongContentEntry", "-previewRichLongEntry"] }
            app.launch()
            let drawer = app.buttons["打开聊天列表"].firstMatch
            XCTAssertTrue(drawer.waitForExistence(timeout: 25)); drawer.tap()
            XCTAssertTrue(app.buttons["导航压力 B"].firstMatch.waitForExistence(timeout: 15))
            app.terminate()
        }
        app.launchArguments = ["-skipStartupPrompt"]
        app.launch()
        defer { app.terminate() }
        let drawer = app.buttons["打开聊天列表"].firstMatch
        let input = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
        let marker = rich ? "长文样式末尾检查标记。" : "纯长文末尾检查标记。"
        let tail = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        var settledFrame: CGRect?
        for index in 0..<3 {
            XCTAssertTrue(drawer.waitForExistence(timeout: 20)); drawer.tap()
            let row = app.buttons["导航压力 A"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                tail.exists && input.exists && tail.frame.maxY > 120 && tail.frame.maxY <= input.frame.minY
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 25), .completed)
            if let settledFrame { XCTAssertEqual(tail.frame, settledFrame) }
            settledFrame = tail.frame
            print("WARM_TAIL rich=\(rich) index=\(index) tail=\(tail.frame) input=\(input.frame)")
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "warm-\(rich ? "rich" : "plain")-\(index)"; image.lifetime = .keepAlways; add(image)
            if index < 2 {
                drawer.tap(); app.buttons["导航压力 B"].firstMatch.tap()
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !tail.exists }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
            }
        }
        // This AX element is a fragment inside a much taller native text view.
        // Press a visible glyph using its measured screen frame explicitly.
        let selectionPoint = CGVector(dx: tail.frame.minX + 12, dy: tail.frame.midY)
        print("SELECTION_POINT \(selectionPoint)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(selectionPoint).press(forDuration: 1.0)
        let selectionImage = XCTAttachment(screenshot: app.screenshot())
        selectionImage.name = "selection-\(rich ? "rich" : "plain")"; selectionImage.lifetime = .keepAlways; add(selectionImage)
        // A single native-menu query avoids repeated full-document AX snapshots.
        // The message action row's own Copy button is not selection evidence.
        let copy = app.menuItems.matching(NSPredicate(
            format: "label IN %@", ["Copy", "拷贝", "复制"]
        )).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 25))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let aboveKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tail.exists && tail.frame.maxY > 120 && tail.frame.maxY <= input.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [aboveKeyboard], timeout: 15), .completed)
        let keyboardImage = XCTAttachment(screenshot: app.screenshot())
        keyboardImage.name = "keyboard-\(rich ? "rich" : "plain")"; keyboardImage.lifetime = .keepAlways; add(keyboardImage)
    }
    func testPlainColdWarmSelectionAndKeyboard() { exercise(rich: false) }
    func testRichColdWarmSelectionAndKeyboard() { exercise(rich: true) }
    func testPersistedRichControl() { exercise(rich: true, seed: false) }
}
