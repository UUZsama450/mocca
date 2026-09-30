import XCTest

@MainActor final class BottomEntryUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.history-native-reading5075")
    var editor: XCUIElement { app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch }
    func state() -> [String: Any]? {
        guard let s = app.descendants(matching: .any).matching(identifier: "nativeChat.transcript").firstMatch.value as? String,
              let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func wait(_ name: String, _ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 20), .completed, name)
    }
    func capture(_ name: String) {
        print("SEND_STAGE \(name) uptime=\(ProcessInfo.processInfo.systemUptime)")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let s = state(), let d = try? JSONSerialization.data(withJSONObject: s, options: .prettyPrinted) {
            let a = XCTAttachment(data: d, uniformTypeIdentifier: "public.json"); a.name = name; a.lifetime = .keepAlways; add(a)
        }
    }
    func exercise(draft: String, hidesKeyboard: Bool, detached: Bool = false, repeatCount: Int = 1) {
        continueAfterFailure = false; executionTimeAllowance = 180
        app.activate(); defer { app.terminate() }
        XCTAssertTrue(editor.waitForExistence(timeout: 25))
        wait("initial bottom") { abs(self.state()?["bottomGap"] as? Double ?? 99999) <= 2 }
        for iteration in 0..<repeatCount {
            print("SEND_ITERATION \(iteration)")
            editor.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
            editor.typeText(draft)
            if hidesKeyboard {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.20)).tap()
                wait("keyboard hidden") { !self.app.keyboards.firstMatch.exists }
                wait("hidden keyboard bottom") { abs(self.state()?["bottomGap"] as? Double ?? 99999) <= 2 }
            }
            if detached {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.3)).press(forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.7)))
                XCTAssertGreaterThan(state()?["bottomGap"] as? Double ?? 0, 100)
            }
            let count = state()?["count"] as? Int ?? 0
            capture("before-send")
            let send = app.buttons["arrow.up"].firstMatch
            XCTAssertTrue(send.isEnabled && send.isHittable)
            send.tap()
            wait("new rows") { (self.state()?["count"] as? Int ?? 0) == count + 2 }
            wait("reply completed") { !self.app.buttons["stop.fill"].firstMatch.exists }
            wait("send ended at bottom") { abs(self.state()?["bottomGap"] as? Double ?? 99999) <= 2 }
            XCTAssertEqual(editor.value as? String, "")
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            capture("after-send")
        }
    }
    func testStreamingCodeResize() {
        continueAfterFailure = false; executionTimeAllowance = 120
        app.activate(); defer { app.terminate() }
        XCTAssertTrue(editor.waitForExistence(timeout: 25))
        editor.tap(); editor.typeText("本机代码展开验收")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.20)).tap()
        wait("keyboard hidden") { !self.app.keyboards.firstMatch.exists }
        app.buttons["arrow.up"].firstMatch.tap()
        func visibleButton(_ label: String) -> XCUIElement? {
            app.buttons.matching(identifier: label).allElementsBoundByIndex.filter { $0.isHittable }.last
        }
        wait("streamed code ready") { visibleButton("从底部收起代码") != nil }
        XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists)
        visibleButton("从底部收起代码")!.tap()
        wait("streaming code collapsed") { visibleButton("从底部展开代码") != nil }
        capture("streaming-code-collapsed")
        visibleButton("从底部展开代码")!.tap()
        wait("streaming code expanded") { visibleButton("从底部收起代码") != nil }
        capture("streaming-code-expanded")
        let readingOffset = state()?["offsetY"] as? Double ?? 0
        wait("stream finished") { !self.app.buttons["stop.fill"].firstMatch.exists }
        let marker = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "DISCLOSURE_STREAM_DONE", "DISCLOSURE_STREAM_DONE")).firstMatch
        XCTAssertTrue(marker.exists, "Buffered stream must rejoin visible content")
        // A real transcript touch intentionally pauses streaming follow. The
        // disclosure must release buffered text without reclaiming that scroll.
        XCTAssertEqual(state()?["offsetY"] as? Double ?? -99999, readingOffset, accuracy: 2)
        XCTAssertGreaterThan(state()?["bottomGap"] as? Double ?? 0, 20)
        capture("streaming-code-complete-reading")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.65)).press(forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.35)),
            withVelocity: .slow, thenHoldForDuration: 0.4)
        wait("manual return to latest") { abs(self.state()?["bottomGap"] as? Double ?? 99999) <= 2 }
        capture("streaming-code-complete-bottom")
    }
    func testHiddenMedium() { exercise(draft: "发送过渡检查：你为什么猜到了我下一步想干什么！这段文字占据几行，键盘已经收起，旧回复不应该先往下掉一下。", hidesKeyboard: true) }
    func testHiddenRepeated() { exercise(draft: "继续发送，检查连续三次发送仍然从当前位置平稳开始。", hidesKeyboard: true, repeatCount: 3) }
    func testHiddenShort() { exercise(draft: "好呀", hidesKeyboard: true) }
    func testKeyboardMedium() { exercise(draft: "发送过渡检查：这是一条键盘打开时发送的多行消息，需要保留原本的收键盘和气泡动画。", hidesKeyboard: false) }
    func testHiddenDetached() { exercise(draft: "发送过渡检查：从上方阅读位置发送，仍应能接续流式跟随。", hidesKeyboard: true, detached: true) }
}
