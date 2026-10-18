import XCTest

@MainActor final class UserBatchUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.lab.replysegments")
    var input: XCUIElement { app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch }
    var stop: XCUIElement { app.buttons["stop.fill"].firstMatch }
    var pending: XCUIElement { app.buttons["batchSend.now"].firstMatch }
    func wait(_ label: String, timeout: Double = 35, _ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout), .completed, label)
    }
    func launch(_ arguments: [String] = [], batch: Bool = true) {
        continueAfterFailure = false
        app.launchArguments = ["-previewNativeReadingFixture", "short", "-nativeChatLocalHTTPFixture", "-replySegmentsFixture",
            "-skipStartupPrompt", "-first_run_model_setup_presented_v1", "YES", "-mocca.interfaceLanguage", "zh-Hans", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + (batch ? ["-batchSendFixture"] : []) + arguments
        app.launch(); XCTAssertTrue(input.waitForExistence(timeout: 25))
    }
    func send(_ text: String) {
        input.tap(); input.typeText(text)
        let button = app.buttons["arrow.up"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
    }
    func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
    }
    func testTwoMessagesCommitTogetherAfterWait() {
        launch()
        send("BATCH_ONE")
        XCTAssertFalse(stop.exists)
        Thread.sleep(forTimeInterval: 2)
        send("BATCH_TWO")
        let lastSent = Date()
        XCTAssertFalse(stop.exists)
        capture("two-pending")
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(lastSent), 5.5)
        XCTAssertFalse(pending.exists)
        wait("reply completes", timeout: 45) { !self.stop.exists }
        capture("two-complete")
        // Reactions retain their individual message target inside a compact batch.
        let first = app.staticTexts["BATCH_ONE"].firstMatch
        let second = app.staticTexts["BATCH_TWO"].firstMatch
        let compactGap = second.frame.minY - first.frame.maxY
        XCTAssertEqual(compactGap, 12, accuracy: 1)
        first.press(forDuration: 1.1)
        let like = app.buttons["用 👍 回应"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 5)); like.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.55)).tap()
        wait("first bubble reaction has its own space") {
            self.app.staticTexts["👍"].firstMatch.exists
                && second.frame.minY - first.frame.maxY > compactGap + 20
        }
        let reaction = app.staticTexts["👍"].firstMatch
        XCTAssertGreaterThanOrEqual(reaction.frame.minY, first.frame.maxY)
        XCTAssertLessThanOrEqual(reaction.frame.maxY, second.frame.minY)
        capture("two-first-liked")
        first.press(forDuration: 1.1)
        let remove = app.buttons["移除 👍 回应"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.55)).tap()
        wait("removing reaction restores compact batch spacing") {
            !self.app.staticTexts["👍"].firstMatch.exists
                && abs(second.frame.minY - first.frame.maxY - compactGap) < 1
        }
        capture("two-reaction-removed")
    }
    func testPauseRetainsMessagesThenSendNow() {
        launch(); send("PAUSE_ONE")
        app.buttons["batchSend.pause"].tap()
        XCTAssertFalse(stop.waitForExistence(timeout: 8))
        XCTAssertTrue(pending.exists)
        capture("paused")
        pending.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        wait("reply completes", timeout: 45) { !self.stop.exists }
    }
    func testMessageDuringReplyWaitsForNextRequest() {
        launch(); send("BOUNDARY_ONE"); pending.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        send("BOUNDARY_TWO")
        capture("next-batch-pending")
        XCTAssertFalse(pending.isEnabled)
        wait("second batch starts after first reply", timeout: 45) { !self.pending.exists }
        XCTAssertTrue(stop.exists)
        wait("second reply completes", timeout: 45) { !self.stop.exists }
        capture("next-batch-complete")
    }
    func openSegmentationSettings() {
        app.buttons["打开聊天列表"].firstMatch.tap(); app.buttons["设置"].firstMatch.tap()
        let preferences = app.buttons["偏好设置"].firstMatch
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
        for _ in 0..<7 { if preferences.isHittable { break }; app.swipeUp() }
        preferences.tap()
        let segmentation = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "聊天分段")).firstMatch
        for _ in 0..<4 { if segmentation.isHittable { break }; app.swipeUp() }
        capture("segmentation-preferences-entry")
        segmentation.tap()
    }
    func testDelaySliderPersistsAndDrawerArrowsMatch() {
        launch(["-segmentsOff"], batch: false)
        openSegmentationSettings()
        let batch = app.switches["batchUserMessagesEnabled"].firstMatch
        XCTAssertTrue(batch.waitForExistence(timeout: 10))
        XCTAssertEqual(batch.value as? String, "0")
        let slider = app.sliders["batchUserMessageDelay"].firstMatch
        XCTAssertFalse(slider.exists)
        batch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "7 秒")
        for _ in 0..<3 { if slider.isHittable { break }; app.swipeUp() }
        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(slider.value as? String, "3 秒")
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(slider.value as? String, "15 秒")
        capture("delay-15-seconds")
        batch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertFalse(slider.exists)
        batch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(slider.value as? String, "15 秒")
        app.terminate(); launch(["-segmentsOff"], batch: false)
        openSegmentationSettings()
        batch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "15 秒")
        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(slider.value as? String, "3 秒")
        capture("delay-3-seconds-restored")
        closeSegmentationSettings()
        app.buttons["打开聊天列表"].firstMatch.tap()
        let assistant = app.buttons["drawer.assistants.toggle"].firstMatch
        let group = app.buttons["drawer.group.toggle"].firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        capture("drawer-both-collapsed")
        group.tap(); capture("drawer-group-expanded")
        group.tap(); assistant.tap(); capture("drawer-assistant-expanded")
        assistant.tap(); capture("drawer-both-restored")
    }

    func testBatchSettingIsIndependentOfReplySegmentation() {
        launch(); openSegmentationSettings()
        let batch = app.switches["batchUserMessagesEnabled"].firstMatch
        XCTAssertTrue(batch.waitForExistence(timeout: 10))
        for _ in 0..<4 { if batch.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(batch.value as? String, "1")
        batch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(batch.value as? String, "0")
        capture("batch-settings")
        let segmentation = app.switches["replySegmentationEnabled"].firstMatch
        XCTAssertTrue(segmentation.waitForExistence(timeout: 10))
        XCTAssertEqual(segmentation.value as? String, "1")
        capture("segmentation-settings")
    }
    func testCustomBubbleSpacingPersistsAndAppliesToBothSides() {
        launch(); openSegmentationSettings()
        let enabled = app.switches["customChatBubbleSpacingEnabled"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.sliders["chatBubbleSpacing"].exists)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let slider = app.sliders["chatBubbleSpacing"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertEqual(slider.value as? String, "12 点")
        setSpacing(slider, to: 0)
        setSpacing(slider, to: 32)
        app.buttons["chatBubbleSpacing.reset"].tap()
        XCTAssertEqual(slider.value as? String, "12 点")
        slider.adjust(toNormalizedSliderPosition: 0.75)
        // A native thumb gesture can land on an adjacent step. Verify that the
        // actual chosen setting, rather than the approximate gesture, persists.
        let chosenSpacing = CGFloat(Double((slider.value as? String ?? "").split(separator: " ").first ?? "") ?? -1)
        XCTAssertGreaterThan(chosenSpacing, 12)
        XCTAssertLessThan(chosenSpacing, 32)
        capture("spacing-settings-custom")
        // No fixture messages have been sent yet, so relaunching the original
        // fixture does not replace a saved conversation with fewer messages.
        app.terminate(); launch()
        send("BATCH_ONE"); send("BATCH_TWO")
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        wait("custom spacing reply completes", timeout: 45) { !self.stop.exists }
        let first = app.staticTexts["BATCH_ONE"].firstMatch
        let second = app.staticTexts["BATCH_TWO"].firstMatch
        XCTAssertEqual(second.frame.minY - first.frame.maxY, chosenSpacing, accuracy: 1)
        let segments = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@", "replySegment.", "50750000"))
            .allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(segments.count, 3)
        if segments.count == 3 {
            for index in 1..<segments.count {
                // Text-view frames exclude each bubble's 10-point vertical inset.
                XCTAssertEqual(segments[index].frame.minY - segments[index-1].frame.maxY - 20, chosenSpacing, accuracy: 1)
            }
        }
        capture("spacing-custom-complete")
    }
    func testDisabledCustomSpacingRestoresDefaultsAndRetainsValue() {
        launch(["-segmentsPlain"]); openSegmentationSettings()
        let enabled = app.switches["customChatBubbleSpacingEnabled"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertFalse(app.sliders["chatBubbleSpacing"].exists)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let slider = app.sliders["chatBubbleSpacing"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        setSpacing(slider, to: 32)
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        wait("slider hidden when custom spacing is off") { !slider.exists }
        XCTAssertEqual(app.switches["replySegmentationEnabled"].firstMatch.value as? String, "1")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "32 点")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        capture("spacing-disabled-settings")
        app.terminate(); launch(["-segmentsPlain"])
        send("SPACING_OFF_ONE"); send("SPACING_OFF_TWO")
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        wait("default spacing reply completes", timeout: 45) { !self.stop.exists }
        let first = app.staticTexts["SPACING_OFF_ONE"].firstMatch
        let second = app.staticTexts["SPACING_OFF_TWO"].firstMatch
        XCTAssertEqual(second.frame.minY - first.frame.maxY, 12, accuracy: 1)
        let segments = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@", "replySegment.", "50750000"))
            .allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(segments.count, 3)
        if segments.count == 3 {
            for index in 1..<segments.count {
                XCTAssertEqual(segments[index].frame.minY - segments[index-1].frame.maxY, 12, accuracy: 1)
            }
        }
        capture("spacing-disabled-plain-complete")
    }
    func closeSegmentationSettings() {
        app.navigationBars["聊天分段"].buttons.firstMatch.tap()
        app.navigationBars["偏好设置"].buttons.firstMatch.tap()
        app.navigationBars["设置"].buttons["完成"].tap()
        let closeDrawer = app.buttons["关闭聊天列表"].firstMatch
        if closeDrawer.waitForExistence(timeout: 2) && closeDrawer.isHittable { closeDrawer.tap() }
        XCTAssertTrue(input.waitForExistence(timeout: 10))
    }
    func ordinaryGap() -> CGFloat {
        let user = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "[NR5075 short 0 BEGIN]")).firstMatch
        let assistant = app.textViews["replySegment.50750000-0000-4000-8000-000000000001.0"].firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        XCTAssertTrue(assistant.waitForExistence(timeout: 10))
        return assistant.frame.minY - user.frame.maxY
    }
    func testCustomSpacingIsOptInForOrdinaryChat() {
        launch(["-segmentsPlain", "-segmentsOff"], batch: false)
        let originalGap = ordinaryGap()
        capture("ordinary-spacing-baseline")
        openSegmentationSettings()
        let enabled = app.switches["customChatBubbleSpacingEnabled"].firstMatch
        XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertEqual(app.switches["replySegmentationEnabled"].firstMatch.value as? String, "0")
        XCTAssertEqual(app.switches["batchUserMessagesEnabled"].firstMatch.value as? String, "0")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        setSpacing(app.sliders["chatBubbleSpacing"].firstMatch, to: 32)
        closeSegmentationSettings()
        wait("explicit opt-in changes the existing ordinary message gap") {
            abs(self.ordinaryGap() - originalGap - 20) < 1
        }
        capture("ordinary-spacing-custom")
        openSegmentationSettings()
        XCTAssertEqual(enabled.value as? String, "1")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        closeSegmentationSettings()
        wait("switching off restores the cached ordinary layout") {
            abs(self.ordinaryGap() - originalGap) < 1
        }
        capture("ordinary-spacing-restored")
    }
    func setSpacing(_ slider: XCUIElement, to target: Int) {
        slider.adjust(toNormalizedSliderPosition: CGFloat(target) / 32)
        XCTAssertEqual(slider.value as? String, "\(target) 点")
    }
    override func tearDown() { app.terminate() }
}
