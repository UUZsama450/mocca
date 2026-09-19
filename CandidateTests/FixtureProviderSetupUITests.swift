import XCTest

@MainActor
final class FixtureProviderSetupUITests: XCTestCase {
    func testConfigureSyntheticLocalProviderKey() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.uuzsama450.mocca.migration")
        app.launchArguments = ["-skipStartupPrompt"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["稍后"].waitForExistence(timeout: 2) { app.buttons["稍后"].tap() }
        let drawer = app.buttons["打开聊天列表"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 20)); drawer.tap()
        app.buttons["设置"].firstMatch.tap()
        let providers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "供应商")).firstMatch
        for _ in 0..<5 where !providers.isHittable { app.swipeUp() }
        XCTAssertTrue(providers.isHittable); providers.tap()
        let local = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本机测试服务")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10)); local.tap()
        let field = app.secureTextFields["API Key"].firstMatch
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable); field.tap(); field.typeText("fixture-only")
        let save = app.buttons["保存"].firstMatch
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(drawer.waitForExistence(timeout: 20)); drawer.tap()
        app.buttons["设置"].firstMatch.tap()
        for _ in 0..<5 where !providers.isHittable { app.swipeUp() }
        XCTAssertTrue(providers.isHittable); providers.tap()
        XCTAssertTrue(local.waitForExistence(timeout: 10)); local.tap()
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable)
        let savedValue = field.value as? String ?? ""
        XCTAssertFalse(savedValue.isEmpty || savedValue == "API Key", "Synthetic key must survive an app relaunch")
    }
}
