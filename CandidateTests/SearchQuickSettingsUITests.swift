import XCTest

@MainActor final class ShortChatUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.history-native-reading5075")
    func shot(_ name: String) throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try app.screenshot().pngRepresentation.write(to: f)
        print("SEARCH_TOOLS_SCREENSHOT \(name) \(f.path)")
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        print("SEARCH_TOOLS_AX \(name)\n\(app.debugDescription)")
    }
    func launch() {
        app.terminate()
        app.launchArguments = ["-skipStartupPrompt", "-previewNativeReadingFixture", "short", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["打开工具菜单"].waitForExistence(timeout: 20))
    }
    func searchSettings() {
        app.buttons["打开工具菜单"].tap()
        let search = app.buttons["联网搜索"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["搜索服务"].waitForExistence(timeout: 5))
    }
    var method: XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "搜索方式")).firstMatch }
    func select(_ name: String) {
        XCTAssertTrue(method.waitForExistence(timeout: 5))
        method.tap()
        let choice = app.buttons[name]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        let selected = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)
        expectation(for: selected, evaluatedWith: method)
        waitForExpectations(timeout: 5)
    }
    func setSearchEnabled(_ enabled: Bool) {
        let toggle = app.switches["联网搜索"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            let control = toggle.switches.firstMatch
            XCTAssertTrue(control.exists, app.debugDescription)
            control.tap()
        }
        expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }
    func testSearchQuickSettingsAndMoreTools() throws {
        continueAfterFailure = false
        launch(); searchSettings()
        let toggle = app.switches["联网搜索"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        setSearchEnabled(true)
        try shot("search-initial")
        select("模型内置搜索")
        try shot("search-native")
        launch(); searchSettings()
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "模型内置搜索", "模型内置搜索").evaluate(with: method), app.debugDescription)
        select("应用搜索服务")
        try shot("search-app")
        setSearchEnabled(false)
        XCTAssertFalse(method.isEnabled)
        setSearchEnabled(true)
        XCTAssertTrue(method.isEnabled)
        select("自动")
        try shot("search-automatic")
        for _ in 0..<6 {
            if app.staticTexts["通用选项"].isHittable { break }
            app.swipeUp()
        }
        let global = app.staticTexts["通用选项"]
        let retention = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "搜索结果上下文")).firstMatch
        XCTAssertTrue(global.isHittable && retention.isHittable, app.debugDescription)
        XCTAssertGreaterThan(retention.frame.midY, global.frame.midY)
        try shot("search-common")
        launch()
        app.buttons["打开工具菜单"].tap()
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "更多工具")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        for title in ["MCP 服务器", "指令注入", "上下文管理"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        }
        XCTAssertFalse(app.buttons["historyReading.open"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "实验阅读")).firstMatch.exists)
        try shot("more-tools-clean")
    }
}
