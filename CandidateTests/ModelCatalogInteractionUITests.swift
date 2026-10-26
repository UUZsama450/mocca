import XCTest

@MainActor final class ModelCatalogInteractionUITests: XCTestCase {
    private func open(medium: Bool = false, arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = (medium ? ["-medium"] : []) + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Claude Sonnet 4.5"].waitForExistence(timeout: 8))
        return app
    }
    private func selected(_ count: Int, in app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts["count"].label, "Selected \(count)")
    }
    func testNameChipsAndWhitespaceDoNotToggle() {
        let app = open(); defer { app.terminate() }
        let button = app.buttons["Claude Sonnet 4.5"]
        XCTAssertEqual(button.frame.width, 44, accuracy: 1)
        XCTAssertEqual(button.frame.height, 44, accuracy: 1)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Keep the blank-area tap outside iOS standard button-edge touch tolerance.
        for x: CGFloat in [28, 120, button.frame.minX - 32] {
            origin.withOffset(CGVector(dx: x, dy: button.frame.midY)).tap()
            selected(0, in: app)
        }
        app.staticTexts["Claude Sonnet 4.5"].firstMatch.tap(); selected(0, in: app)
    }
    func testOnlyPlusAndMinusToggleOnce() {
        let app = open(medium: true); defer { app.terminate() }
        let button = app.buttons["Claude Sonnet 4.5"]
        button.tap(); selected(1, in: app)
        XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 1")
        XCTAssertEqual(button.value as? String, "已选择")
        app.staticTexts["Claude Sonnet 4.5"].firstMatch.tap(); selected(1, in: app)
        button.tap(); selected(0, in: app)
        XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 2")
        XCTAssertEqual(button.value as? String, "未选择")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
    }
    func testScrollStartingInNameDoesNotToggle() {
        let app = open(); defer { app.terminate() }
        let scroll = app.scrollViews.firstMatch
        let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.8))
        from.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.2)))
        selected(0, in: app)
        XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 0")
        XCTAssertFalse(app.buttons["Claude Sonnet 4.5"].isHittable)
        scroll.swipeDown(); selected(0, in: app)
    }
    func testScrollStartingOnPlusCancelsButton() {
        let app = open(); defer { app.terminate() }
        let button = app.buttons["Catalog 004"]
        XCTAssertTrue(button.isHittable)
        let from = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -180)))
        selected(0, in: app)
        XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 0")
    }
    func testSearchCombinesWordsAndIgnoresSeparatorsWithoutSelecting() {
        let app = open(); defer { app.terminate() }
        let field = app.textFields["输入模型名称或 ID 筛选"]
        field.tap(); field.typeText("sonnet claude")
        XCTAssertTrue(app.buttons["Claude Sonnet 4.5"].exists)
        XCTAssertFalse(app.buttons["GPT-4o"].exists)
        selected(0, in: app)
        // Clearing uses the fixture's explicit clear button, independent of OS edit menus.
        app.buttons["Clear search"].tap()
        field.tap(); field.typeText("gpt4o")
        XCTAssertTrue(app.buttons["GPT-4o"].exists)
        XCTAssertFalse(app.buttons["Claude Sonnet 4.5"].exists)
        app.buttons["GPT-4o"].tap(); selected(1, in: app)
    }

    func testRestingFingerThenScrollDoesNotSelectOrVibrate() {
        let app = open(); defer { app.terminate() }
        let button = app.buttons["Catalog 004"]
        let from = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.8, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -220)))
        selected(0, in: app)
        XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 0")
        XCTAssertFalse(app.buttons["Claude Sonnet 4.5"].isHittable, "The scroll must still move")
    }
    func testRestThenReleaseAndRestThenSmallMoveDoNotSelect() {
        let app = open(); defer { app.terminate() }
        let button = app.buttons["Claude Sonnet 4.5"]
        button.press(forDuration: 0.8); selected(0, in: app)
        let from = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.8, thenDragTo: from.withOffset(CGVector(dx: 3, dy: 3)))
        selected(0, in: app); XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 0")
        button.tap(); selected(1, in: app); XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 1")
        button.tap(); selected(0, in: app); XCTAssertEqual(app.staticTexts["haptics"].label, "Haptics 2")
    }

    func testInvertTextButtonOnlyChangesFilteredModels() {
        let app = open(arguments: ["-compact"]); defer { app.terminate() }
        app.buttons["GPT-4o"].tap(); selected(1, in: app)
        let field = app.textFields["输入模型名称或 ID 筛选"]
        field.tap(); field.typeText("sonnet")
        let invert = app.buttons["反选当前结果"]
        XCTAssertTrue(invert.isHittable)
        XCTAssertGreaterThanOrEqual(invert.frame.width, 44)
        XCTAssertGreaterThanOrEqual(invert.frame.height, 44)
        XCTAssertLessThan(field.frame.maxX, invert.frame.minX)
        invert.tap(); selected(2, in: app)
        invert.tap(); selected(1, in: app)
        app.buttons["Clear search"].tap()
        XCTAssertEqual(app.buttons["GPT-4o"].value as? String, "已选择")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "compact-invert-text"; shot.lifetime = .keepAlways; add(shot)
    }

    func testEnglishInvertButtonFitsCompactSearchBar() {
        let app = open(arguments: ["-compact", "-english"]); defer { app.terminate() }
        let invert = app.buttons["反选当前结果"]
        XCTAssertTrue(invert.isHittable)
        XCTAssertLessThan(invert.frame.width, 80)
        XCTAssertLessThan(app.textFields.firstMatch.frame.maxX, invert.frame.minX)
        invert.tap(); selected(184, in: app)
        invert.tap(); selected(0, in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "compact-invert-english"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLongNameAndIDWrapWithinTwoLinesAndKeepIndependentButton() {
        let app = open(arguments: ["-compact"]); defer { app.terminate() }
        let field = app.textFields["输入模型名称或 ID 筛选"]
        field.tap(); field.typeText("terminus")
        let name = app.staticTexts["DeepSeek: DeepSeek V3.1 Terminus"]
        let identifier = app.staticTexts["deepseek/deepseek-v3.1-terminus"]
        let button = app.buttons["DeepSeek: DeepSeek V3.1 Terminus"]
        XCTAssertGreaterThan(name.frame.height, 24)
        XCTAssertLessThan(name.frame.height, 45)
        XCTAssertGreaterThan(identifier.frame.height, 20)
        XCTAssertLessThan(identifier.frame.height, 36)
        XCTAssertLessThan(name.frame.maxX, button.frame.minX)
        XCTAssertLessThan(identifier.frame.maxX, button.frame.minX)
        XCTAssertEqual(button.frame.width, 44, accuracy: 1)
        name.tap(); selected(0, in: app)
        button.tap(); selected(1, in: app)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "compact-two-line-model"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Clear search"].tap(); field.tap(); field.typeText("long variant")
        let extreme = app.staticTexts["Long Variant Preview With Extended Provider Details And Release Suffix"]
        XCTAssertLessThan(extreme.frame.height, 45)
        let extremeShot = XCTAttachment(screenshot: app.screenshot()); extremeShot.name = "compact-extreme-model"; extremeShot.lifetime = .keepAlways; add(extremeShot)
    }
}
