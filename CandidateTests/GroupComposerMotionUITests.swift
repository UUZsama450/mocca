import XCTest

@MainActor final class GroupComposerMotionUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.qa.searchprompt")
    var report: [String: Any] {
        guard let raw = app.staticTexts["groupMotion.report"].value as? String,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
    func wait(_ condition: @escaping () -> Bool) {
        let e = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [e], timeout: 15), .completed)
    }
    func exercise(enabled: Bool, history: Bool) throws {
        continueAfterFailure = false
        app.launchArguments = ["-groupComposerUITest", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
            + (enabled ? ["-editorMotionOn"] : []) + (history ? ["-groupHistory"] : [])
        app.launch()
        wait { self.report["ready"] as? Bool == true }
        let toggle = app.buttons["groupReplyControl.expand"]
        XCTAssertTrue(toggle.exists)
        for event in 1...2 {
            toggle.tap()
            wait { self.report["event"] as? Int == event }
            let r = report
            let frames = try XCTUnwrap(r["frames"] as? [[String: Double]])
            let start = try XCTUnwrap(r["initialShell"] as? Double)
            let end = try XCTUnwrap(r["finalShell"] as? Double)
            XCTAssertEqual(end - start, event == 1 ? 42 : -42, accuracy: 1)
            // onGeometryChange reports the shell's final layout size for this
            // native geometry animation. Its rendered interpolation is checked
            // separately from simulator video, not inferred from this target.
            let before = try XCTUnwrap(r["initialOffset"] as? Double)
            let after = try XCTUnwrap(r["finalOffset"] as? Double)
            if history {
                XCTAssertTrue(frames.allSatisfy { abs($0["offset"]! - before) < 1 }, "History stays still")
            } else {
                XCTAssertEqual(after - before, end - start, accuracy: 1)
                XCTAssertGreaterThan(frames.filter { $0["offset"]! > min(before,after) + 1 && $0["offset"]! < max(before,after) - 1 }.count, 1)
                XCTAssertTrue(frames.allSatisfy { abs($0["gap"]!) < 1 }, "Bottom follows the interpolated footer")
            }
            let a = XCTAttachment(data: try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            a.name = "group-enabled-\(enabled)-history-\(history)-event-\(event)"; a.lifetime = .keepAlways; add(a)
        }
    }
    func testGroupMotionWithEditorOff() throws { try exercise(enabled: false, history: false) }
    func testGroupMotionWithEditorOn() throws { try exercise(enabled: true, history: false) }
    func testGroupHistoryWithEditorOff() throws { try exercise(enabled: false, history: true) }
    func testGroupHistoryWithEditorOn() throws { try exercise(enabled: true, history: true) }
}
