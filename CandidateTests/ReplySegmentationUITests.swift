import XCTest

@MainActor final class ReplySegmentationUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.lab.replysegments")
    var input: XCUIElement { app.textViews.matching(NSPredicate(format:"label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch }
    func wait(_ label: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in condition() },object:nil)],timeout:timeout),.completed,label)
    }
    func capture(_ name: String) {
        let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)
        let dump=XCTAttachment(string:app.debugDescription);dump.name=name+"-tree";dump.lifetime = .keepAlways;add(dump)
    }
    func launch(_ args: [String] = []) {
        continueAfterFailure=false
        app.launchArguments=["-previewNativeReadingFixture","short","-nativeChatLocalHTTPFixture","-replySegmentsFixture",
          "-skipStartupPrompt","-first_run_model_setup_presented_v1","YES","-mocca.interfaceLanguage","zh-Hans",
          "-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"] + args
        app.launch();XCTAssertTrue(input.waitForExistence(timeout:25))
    }
    var segmentIDs: Set<String> {
        Set(app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@", "replySegment.", "50750000")).allElementsBoundByIndex.map(\.identifier))
    }
    func sendAndCheck(_ name: String, count: Int) {
        input.tap();input.typeText("segmentation "+name)
        let send=app.buttons["arrow.up"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout:5));send.tap()
        XCTAssertTrue(app.buttons["stop.fill"].firstMatch.waitForExistence(timeout:15))
        if count>1 {
            wait("Two segments appear while generation is still running") { self.segmentIDs.count >= 2 }
            XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists)
            capture(name+"-streaming")
        }
        wait("Generation completes",timeout:45) { !self.app.buttons["stop.fill"].firstMatch.exists }
        wait("Expected final segment count") { self.segmentIDs.count == count }
        capture(name+"-complete")
    }
    func testGlassCappedStreaming() { launch();sendAndCheck("glass-capped",count:3) }
    func testPlainUnlimitedStreaming() { launch(["-segmentsPlain","-segmentsUnlimited"]);sendAndCheck("plain-unlimited",count:4) }
    func testDisabledUsesOneBlock() { launch(["-segmentsOff"]);sendAndCheck("disabled",count:1) }
    func checkGroup(_ name: String, plain: Bool = false, enabled: Bool = true) {
        launch(["-groupSegmentsFixture"] + (plain ? ["-segmentsPlain"] : []) + (enabled ? [] : ["-segmentsOff"]))
        let oldIDs = Set(app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "replySegment.", "50750000")).allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(oldIDs.count, enabled ? 2 : 1)
        input.tap(); input.typeText("GROUP_SEGMENTS")
        app.buttons["arrow.up"].firstMatch.tap()
        XCTAssertTrue(app.buttons["stop.fill"].firstMatch.waitForExistence(timeout: 15))
        if enabled {
            wait("first group member segments while streaming") { self.segmentIDs.count >= 2 }
            XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists)
            capture(name + "-first-streaming")
            wait("second group member has its own segments", timeout: 60) {
                Set(self.segmentIDs.compactMap { $0.split(separator: ".").dropFirst().first }).count == 2
                    && self.segmentIDs.count >= 5
            }
            XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists)
            capture(name + "-second-streaming")
        }
        wait("both group replies complete", timeout: 80) { !self.app.buttons["stop.fill"].firstMatch.exists }
        XCTAssertEqual(segmentIDs.count, enabled ? 6 : 2)
        XCTAssertEqual(Set(segmentIDs.compactMap { $0.split(separator: ".").dropFirst().first }).count, 2)
        capture(name + "-complete")
    }
    func testGroupCappedStreamingKeepsMemberBubbles() { checkGroup("group-bubbles") }
    func testGroupAppearanceControlsWithoutLegacyRegex() {
        // Inspect the settings page in a fresh navigation fixture, separately
        // from the group-stream fixture, whose synthetic history can be rebuilt.
        launch()
        app.buttons["打开聊天列表"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.7)
        app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        capture("group-settings-entry")
        let groupSettings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "群聊设置")).firstMatch
        for _ in 0..<5 { if groupSettings.isHittable { break }; app.swipeUp() }
        groupSettings.tap()
        XCTAssertTrue(app.navigationBars["群聊设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "群聊显示气泡")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["气泡透明度"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["分段正则表达式"].exists)
        XCTAssertFalse(app.switches["replySegmentationEnabled"].exists)
        capture("group-appearance-settings")
    }
    func testGroupPlainStreamingUsesSharedSegmentation() { checkGroup("group-plain", plain: true) }
    func testGroupDisabledKeepsOneBlockPerMember() { checkGroup("group-disabled", enabled: false) }
    func testSettingsSwitchAndLimit() {
        launch(["-segmentsOff"])
        app.buttons["打开聊天列表"].firstMatch.tap()
        app.buttons["设置"].firstMatch.tap()
        let preferences=app.buttons["偏好设置"].firstMatch
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:10))
        for _ in 0..<7 { if preferences.isHittable { break };app.swipeUp() }
        XCTAssertTrue(preferences.isHittable);preferences.tap()
        let segmentation=app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "聊天分段")).firstMatch
        for _ in 0..<4 { if segmentation.isHittable { break };app.swipeUp() }
        XCTAssertTrue(segmentation.isHittable);segmentation.tap()
        let toggle=app.switches["replySegmentationEnabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout:10));XCTAssertEqual(toggle.value as? String,"0");toggle.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap()
        wait("Switch enabled") { toggle.value as? String == "1" }
        let slider=app.sliders["replySegmentationLimit"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout:5));slider.adjust(toNormalizedSliderPosition:1)
        XCTAssertEqual(slider.value as? String,"不限")
        capture("settings-enabled-unlimited")
        toggle.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap();XCTAssertFalse(slider.exists)
    }
    override func tearDown() { app.terminate() }
}
