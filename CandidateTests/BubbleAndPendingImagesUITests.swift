import XCTest
import UIKit

@MainActor final class ShortChatUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.history-native-reading5075")
    let original = "[NR5075 short 0 BEGIN]\n\n短聊天：检查独立阅读入口。\n\n[NR5075 0 END]"
    func screenshot(_ label: String) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(label + ".png")
        try app.screenshot().pngRepresentation.write(to: path)
        print("PREVIEW_SCREENSHOT \(label) \(path.path)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
        print("PREVIEW_AX \(label)\n\(app.debugDescription)")
    }
    func bubble() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "NR5075 short 0 BEGIN")).firstMatch
    }
    func openMenu(_ label: String) throws {
        let target = bubble()
        XCTAssertTrue(target.waitForExistence(timeout: 20), app.debugDescription)
        try screenshot(label + "-before")
        target.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["编辑"].exists)
        XCTAssertTrue(app.buttons["重新发送"].exists)
        XCTAssertTrue(app.buttons["更多"].exists)
        try screenshot(label + "-menu")
    }
    func testFullBubblePreview() throws {
        continueAfterFailure = false
        app.activate()
        try openMenu("multiline")
        try XCTUnwrap(app.buttons.matching(identifier: "复制").allElementsBoundByIndex.first { $0.frame.width > 150 && $0.isHittable }).tap()
        XCTAssertTrue(bubble().waitForExistence(timeout: 5))
        try screenshot("multiline-dismissed")
        try openMenu("repeat")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.7)).tap()
        XCTAssertTrue(bubble().waitForExistence(timeout: 5))
    }


    func testPendingImagePreview() throws {
        continueAfterFailure = false
        app.terminate()
        app.launchArguments = ["-skipStartupPrompt", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let draftField = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "给 ")).firstMatch
        XCTAssertTrue(draftField.waitForExistence(timeout: 15))
        draftField.tap()
        draftField.typeText("preview draft")
        app.buttons["打开工具菜单"].tap()
        app.buttons["照片"].tap()
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15))
        for index in [0, 1] {
            let frame = photos.element(boundBy: index).frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        }
        app.buttons["完成"].tap()
        let thumbnails = app.buttons.matching(identifier: "预览图片")
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(thumbnails.count, 2)
        let selectedName = try XCTUnwrap(thumbnails.element(boundBy: 1).value as? String)
        try screenshot("pending-two")
        thumbnails.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 / 2"].exists)
        let selectedImage = app.images.matching(identifier: selectedName).firstMatch
        XCTAssertTrue(selectedImage.waitForExistence(timeout: 10))
        let fittedWidth = selectedImage.frame.width
        try screenshot("preview-second")
        selectedImage.doubleTap()
        let enlargedWidth = selectedImage.frame.width
        XCTAssertGreaterThan(enlargedWidth, fittedWidth * 1.3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForNonExistence(timeout: 4))
        XCTAssertEqual(selectedImage.frame.width, enlargedWidth, accuracy: 2)
        try screenshot("preview-zoom-controls-hidden")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 4))
        XCTAssertEqual(selectedImage.frame.width, enlargedWidth, accuracy: 2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertEqual(selectedImage.frame.width, fittedWidth, accuracy: 2)
        selectedImage.swipeRight()
        XCTAssertTrue(app.staticTexts["1 / 2"].waitForExistence(timeout: 5))
        try screenshot("preview-first")
        app.buttons["关闭图片"].tap()
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnails.count, 2)
        let composer = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "给 ")).firstMatch
        XCTAssertEqual(composer.value as? String, "preview draft")
        app.buttons.matching(identifier: "移除附件").element(boundBy: 1).tap()
        XCTAssertEqual(thumbnails.count, 1)
        thumbnails.firstMatch.tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(thumbnails.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["关闭图片"].exists)
        XCTAssertEqual(composer.value as? String, "preview draft")
        XCTAssertEqual(thumbnails.count, 1)
        try screenshot("pending-after-dismiss")
    }
    func testBubbleDismiss() throws {
        continueAfterFailure = false
        app.activate()
        try openMenu("bubble")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.7)).tap()
        XCTAssertTrue(bubble().waitForExistence(timeout: 5))
        try openMenu("bubble-repeat")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.7)).tap()
        XCTAssertTrue(bubble().exists)
    }
}
