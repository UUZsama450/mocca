import XCTest

@MainActor
final class PerformanceReuseUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.history-native-reading5075")
    var input: XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
    }
    var transcript: XCUIElement { app.descendants(matching: .any)["nativeChat.transcript"].firstMatch }
    func state() -> [String: Any]? {
        guard transcript.exists, let text = transcript.value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func wait(_ name: String, timeout: TimeInterval = 12, _ predicate: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: timeout), .completed, name)
    }
    func launch(_ fixture: String) {
        continueAfterFailure = false
        app.launchArguments = ["-previewNativeReadingFixture", fixture, "-nativeChatLocalHTTPFixture", "-skipStartupPrompt",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 25))
        let expected = fixture == "window500" ? 500 : (fixture == "versions" ? 8 : 2)
        wait("fixture rows and native geometry ready") {
            guard let state = self.state(), state["total"] as? Int == expected else { return false }
            return !(state["visibleIDs"] as? [String] ?? []).isEmpty
        }
    }
    func record(_ name: String) {
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = name; screen.lifetime = .keepAlways; add(screen)
        if let state = state(), let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name + "-geometry"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func dismissKeyboard() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.20)).tap()
        wait("keyboard dismissed") { !self.app.keyboards.firstMatch.exists }
    }
    func testShortKeyboardPreservesVisibleRows() {
        launch("short")
        for i in 0..<2 {
            input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6))
            record("short-open-\(i)")
            dismissKeyboard()
            wait("short rows return") { (self.state()?["visibleIDs"] as? [String])?.count ?? 0 >= 2 }
            record("short-closed-\(i)")
        }
        XCTAssertEqual(state()?["total"] as? Int, 2)
    }
    func testStreamingRepeatedSendAndKeyboard() {
        launch("short")
        app.buttons["新聊天"].firstMatch.tap()
        for turn in 1...2 {
            input.tap(); input.typeText("reuse-turn-\(turn)")
            app.buttons["arrow.up"].firstMatch.tap()
            let marker = "REUSE_REPLY_\(turn)_END"
            let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 35))
            input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 6))
            dismissKeyboard()
            wait("reply follows bottom", timeout: 15) {
                guard let state = self.state(), let gap = state["bottomGap"] as? Double,
                      let ids = state["visibleIDs"] as? [String] else { return false }
                return gap < 3 && !ids.isEmpty
            }
            record("send-\(turn)-closed")
        }
        XCTAssertEqual(state()?["total"] as? Int, 4)
    }
    func testHistoryPagingRetainsLiveLayout() {
        launch("window500")
        // The in-memory fixture bypasses normal entry and initially exposes
        // up to 240 rows. Enter through the real drawer before testing the
        // concrete entry window and its first history page.
        app.buttons["打开聊天列表"].firstMatch.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "实验阅读 fixture · window500")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8)); saved.tap()
        wait("normal entry window ready") {
            guard let state = self.state(), state["total"] as? Int == 500,
                  let start = state["start"] as? Int else { return false }
            return start >= 488 && !(state["visibleIDs"] as? [String] ?? []).isEmpty
        }
        let start = state()?["start"] as? Int ?? 500
        print("HISTORY_INITIAL_START \(start)")
        record("history-initial")
        XCTAssertGreaterThan(start, 0)
        XCTAssertEqual(state()?["total"] as? Int, 500)
        for _ in 0..<12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.76)))
            if let state = state() {
                print("HISTORY_AFTER_DRAG start=\(state["start"] ?? -1) offset=\(state["offsetY"] ?? -1) count=\(state["count"] ?? -1)")
            }
            if let now = state()?["start"] as? Int, now < start { break }
        }
        wait("earlier window loaded") { (self.state()?["start"] as? Int ?? 500) < start }
        XCTAssertFalse((state()?["visibleIDs"] as? [String] ?? []).isEmpty)
        record("history-loaded")
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertEqual(state()?["total"] as? Int, 500)
        XCTAssertFalse((state()?["visibleIDs"] as? [String] ?? []).isEmpty)
        record("history-scroll-back")
    }
    func testVersionSelectionAfterScroll() {
        launch("versions")
        let next = app.buttons["下一版回答"].firstMatch
        for _ in 0..<8 {
            if next.exists && next.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.76)))
        }
        XCTAssertTrue(next.exists && next.isHittable)
        next.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "version selection must not show a persistence failure")
        wait("version 2 owns the visible row") {
            (self.state()?["visibleIDs"] as? [String] ?? []).contains("50750000-0000-4000-8200-000000000003")
        }
        XCTAssertEqual(state()?["total"] as? Int, 8)
        record("version-2")
        app.buttons["上一版回答"].firstMatch.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "version restoration must not show a persistence failure")
        wait("version 1 restored") {
            (self.state()?["visibleIDs"] as? [String] ?? []).contains("50750000-0000-4000-8100-000000000003")
        }
        record("version-1")
    }
}
