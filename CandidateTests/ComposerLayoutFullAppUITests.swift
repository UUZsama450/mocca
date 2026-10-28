import XCTest

@MainActor final class ComposerLayoutFullAppUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.lab.streamheight5157")
    var input: XCUIElement {
        app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch
    }
    var transcript: XCUIElement { app.descendants(matching: .any)["nativeChat.transcript"].firstMatch }
    func state() -> [String: Any]? {
        guard let text = transcript.value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func wait(_ label: String, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, label)
    }
    func record(_ label: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = label; shot.lifetime = .keepAlways; add(shot)
        if let value = state(), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            a.name = label + "-geometry"; a.lifetime = .keepAlways; add(a)
        }
    }
    func launch(_ fixture: String) {
        continueAfterFailure = false
        app.launchArguments = ["-previewNativeReadingFixture", fixture, "-skipStartupPrompt", "-fullMotionLean", "-nativeComposerDriver",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(input.waitForExistence(timeout: 30), app.debugDescription)
        wait("native geometry") { !(self.state()?["visibleIDs"] as? [String] ?? []).isEmpty }
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    }
    func exercise(_ fixture: String, history: Bool) {
        launch(fixture)
        if history {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.22))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.43))
            from.press(forDuration: 0.1, thenDragTo: to)
            wait("history released bottom") { (self.state()?["bottomGap"] as? Double ?? 0) > 50 }
        }
        let initial = state()!
        let initialHeight = input.frame.height
        let text = String(repeating: "Composer layout wraps smoothly. ", count: 5)
        input.typeText(text)
        wait("composer grew") { self.input.frame.height > initialHeight + 15 }
        XCTAssertEqual(state()?["total"] as? Int, fixture == "short" ? 2 : 500)
        XCTAssertTrue((input.value as? String ?? "").contains("Composer layout wraps smoothly."))
        if history {
            let oldFrames = initial["frames"] as? [String: [String: Double]] ?? [:]
            let newFrames = state()?["frames"] as? [String: [String: Double]] ?? [:]
            let common = Set(oldFrames.keys).intersection(newFrames.keys)
            XCTAssertFalse(common.isEmpty)
            for id in common { XCTAssertEqual(oldFrames[id]!["y"]!, newFrames[id]!["y"]!, accuracy: 1.0) }
        } else {
            wait("bottom stays attached") { abs(self.state()?["bottomGap"] as? Double ?? 999) < 2 }
        }
        record(fixture + (history ? "-history-grown" : "-bottom-grown"))
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        wait("composer shrank") { self.input.frame.height <= initialHeight + 1 }
        record(fixture + (history ? "-history-shrunk" : "-bottom-shrunk"))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
    func testShortWrapAndShrink() { exercise("short", history: false) }
    func testLongBottomWrapAndShrink() { exercise("window500", history: false) }
    func testLongHistoryWrapAndShrink() { exercise("window500", history: true) }
    func testEmptyConversationWrapAndShrink() {
        launch("short")
        let newChat = app.buttons["新聊天"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        wait("empty conversation") {
            !self.transcript.exists || (self.state()?["total"] as? Int) == 0
        }
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let initialHeight = input.frame.height
        let text = String(repeating: "Empty composer wraps smoothly. ", count: 5)
        input.typeText(text)
        wait("empty composer grew") { self.input.frame.height > initialHeight + 15 }
        record("empty-grown")
        XCTAssertTrue((input.value as? String ?? "").contains("Empty composer wraps smoothly."))
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        wait("empty composer shrank") { self.input.frame.height <= initialHeight + 1 }
        record("empty-shrunk")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }
}
