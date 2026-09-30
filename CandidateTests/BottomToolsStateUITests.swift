import XCTest

@MainActor final class BottomToolsStateUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.history-native-reading5075")

    func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func waitValue(_ element: XCUIElement, _ value: String) {
        expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        waitForExpectations(timeout: 6)
    }

    func setSwitch(_ toggle: XCUIElement, enabled: Bool) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        let value = enabled ? "1" : "0"
        if toggle.value as? String != value {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
        waitValue(toggle, value)
    }

    func openDetails() {
        row("世界书").press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["世界书"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func returnToTools() {
        dismissSettings("世界书")
        XCTAssertTrue(row("拍照").waitForExistence(timeout: 5), app.debugDescription)
    }

    func dismissSettings(_ title: String) {
        // A navigation-bar-sized swipe can merely settle the sheet after a
        // nested editor closes. Drag through the sheet's actual dismissal range.
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
    }

    func screenshot(_ name: String) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try app.screenshot().pngRepresentation.write(to: path)
        print("TOOLS_STATE_SCREENSHOT \(name) \(path.path)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWorldBookDetailsAndQuickListStayInSync() throws {
        continueAfterFailure = false
        app.launchArguments = ["-previewNativeReadingFixture", "short", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["打开工具菜单"].waitForExistence(timeout: 25))
        app.buttons["打开工具菜单"].tap()
        waitValue(row("世界书"), "已启用 1 项")
        openDetails()
        for toggle in app.switches.matching(identifier: "对当前助手启用").allElementsBoundByIndex {
            setSwitch(toggle, enabled: false)
        }
        XCTAssertGreaterThan(app.switches.matching(identifier: "对当前助手启用").count, 0)
        returnToTools()
        waitValue(row("世界书"), "未选择")
        try screenshot("world-books-all-off-returned")

        // Quick selection must enable the actual book, rather than invert an old UI copy.
        row("世界书").tap()
        XCTAssertTrue(row("Sync book A").waitForExistence(timeout: 5))
        row("Sync book A").tap()
        app.buttons["返回"].firstMatch.tap()
        waitValue(row("世界书"), "已启用 1 项")
        openDetails()
        let selected = app.switches.matching(identifier: "对当前助手启用").firstMatch
        waitValue(selected, "1")

        // Save a nested edit while the original tools sheet remains alive.
        row("Sync book A").tap()
        let name = app.textFields["世界书名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "Renamed book")
        setSwitch(app.switches["启用"].firstMatch, enabled: false)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.navigationBars["世界书"].waitForExistence(timeout: 5))
        returnToTools()
        waitValue(row("世界书"), "关闭")
        row("世界书").tap()
        XCTAssertTrue(row("Renamed book").waitForExistence(timeout: 5))
        XCTAssertFalse(row("Sync book A").exists)
        try screenshot("world-books-renamed-disabled")
        app.buttons["返回"].firstMatch.tap()
        openDetails()
        row("Renamed book").tap()
        setSwitch(app.switches["启用"].firstMatch, enabled: true)
        app.buttons["保存"].tap()
        returnToTools()
        waitValue(row("世界书"), "已启用 1 项")

        // The already-live search summary must retain its existing behavior.
        row("联网搜索").press(forDuration: 0.8)
        XCTAssertTrue(app.navigationBars["搜索服务"].waitForExistence(timeout: 5))
        setSwitch(app.switches["联网搜索"].firstMatch, enabled: false)
        dismissSettings("搜索服务")
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", "关闭"), evaluatedWith: row("联网搜索"))
        waitForExpectations(timeout: 5)
        row("联网搜索").tap()
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", "开启"), evaluatedWith: row("联网搜索"))
        waitForExpectations(timeout: 5)
        try screenshot("tools-state-roundtrip-complete")
    }
}
