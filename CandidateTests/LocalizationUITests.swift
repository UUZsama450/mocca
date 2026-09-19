import XCTest
final class LocalizationUITests: XCTestCase {
 private func revealLanguagePicker(_ app: XCUIApplication) {
  for _ in 0..<8 {
   if app.buttons["localization.languagePicker"].isHittable { return }
   app.swipeUp()
  }
  XCTAssertTrue(app.buttons["localization.languagePicker"].isHittable)
 }
 func testProfileAndSponsorEnglish() {
  let app = XCUIApplication()
  app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-resetLanguageForUITest", "-showProfile"]
  app.launch()
  XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 30))
  XCTAssertTrue(app.staticTexts["Custom preferences"].exists)
  XCTAssertFalse(app.staticTexts["自定义偏好"].exists)
  XCTAssertFalse(app.staticTexts["个人喜好和兴趣"].exists)
  let profile = XCTAttachment(screenshot: app.screenshot()); profile.name = "English profile"; profile.lifetime = .keepAlways; add(profile)
  app.terminate()
  app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-resetLanguageForUITest", "-showSponsor"]
  app.launch()
  XCTAssertTrue(app.staticTexts["First tip unlocks 💧 + 🍬 keepsakes"].waitForExistence(timeout: 30))
  XCTAssertTrue(app.staticTexts["First tip unlocks 💧 + 🧋 keepsakes"].exists)
  let sponsor = XCTAttachment(screenshot: app.screenshot()); sponsor.name = "English sponsor"; sponsor.lifetime = .keepAlways; add(sponsor)
  app.terminate()
 }

 func testProviderBalanceHeaderAndRefresh() {
  let app=XCUIApplication()
  app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US","-resetLanguageForUITest","-showProviderBalances"]
  app.launch()
  let balance=app.buttons["provider.balance.00000000-0000-0000-0000-000000000001"]
  XCTAssertTrue(balance.waitForExistence(timeout:30))
  XCTAssertTrue(NSPredicate(format:"value == %@","Balance: 12.34").evaluate(with:balance) || XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","Balance: 12.34"),object:balance)],timeout:10) == .completed)
  XCTAssertFalse(app.buttons["provider.balance.00000000-0000-0000-0000-000000000002"].exists)
  XCTAssertTrue(app.staticTexts["Chat"].firstMatch.exists)
  XCTAssertFalse(app.staticTexts["聊天"].exists)
  balance.tap()
  XCTAssertTrue(balance.waitForExistence(timeout:5))
  let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Provider header balance";shot.lifetime = .keepAlways;add(shot)
  app.terminate()
 }
 func testLiveLanguageSwitchAndPersistence() {
  let app=XCUIApplication()
  app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN","-resetLanguageForUITest"]
  app.launch()
  XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:30))
  let draft=app.textFields["localization.testDraft"]
  app.buttons["localization.seedDraft"].tap()
  XCTAssertEqual(draft.value as? String,"Keep this draft")
  revealLanguagePicker(app)
  app.buttons["localization.languagePicker"].tap()
  app.buttons["English"].tap()
  XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout:5))
  XCTAssertEqual(draft.value as? String,"Keep this draft")
  XCTAssertFalse(app.staticTexts["选择模型"].exists)
  let first=XCTAttachment(screenshot:app.screenshot());first.name="English settings";first.lifetime = .keepAlways;add(first)
  app.terminate()
  app.launchArguments=["-AppleLanguages","(zh-Hans)","-AppleLocale","zh_CN"]
  app.launch()
  XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout:15))
  revealLanguagePicker(app)
  app.buttons["localization.languagePicker"].tap();app.buttons["简体中文"].tap()
  XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:5))
  revealLanguagePicker(app)
  app.buttons["localization.languagePicker"].tap();app.buttons["跟随系统"].tap()
  XCTAssertTrue(app.navigationBars["设置"].exists)
  app.terminate()
  app.launchArguments=["-AppleLanguages","(en)","-AppleLocale","en_US"]
  app.launch()
  XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout:15))
  revealLanguagePicker(app)
  app.buttons["localization.languagePicker"].tap();app.buttons["简体中文"].tap()
  app.terminate();app.launch()
  XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout:15))
  let last=XCTAttachment(screenshot:app.screenshot());last.name="Chinese override on English system";last.lifetime = .keepAlways;add(last)
 }
}
