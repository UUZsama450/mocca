import XCTest
import UIKit

@MainActor final class OffBottomTargetUITests: XCTestCase {
    var caseLabel = "setup"
    let app = XCUIApplication(bundleIdentifier: "com.mocca.local.offbottom.target5135")
    var input: XCUIElement { app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息")).firstMatch }
    var list: XCUIElement { app.collectionViews["nativeChat.transcript"].firstMatch }
    func state() -> [String: Any] {
        guard let raw = list.value as? String, let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func number(_ key: String) -> Double { (state()[key] as? NSNumber)?.doubleValue ?? -99999 }
    func wait(_ label: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, label)
    }
    @discardableResult
    func sample(_ label: String, settledBottom: Bool = false) -> [String: Any] {
        var value = state()
        if settledBottom {
            wait("settled bottom sample " + label, timeout: 2) {
                let candidate = self.state()
                guard let gap = candidate["bottomGap"] as? NSNumber, abs(gap.doubleValue) <= 2 else { return false }
                value = candidate
                return true
            }
        }
        value["label"] = caseLabel + "-" + label; value["wall"] = Date().timeIntervalSince1970
        value["keyboard"] = app.keyboards.firstMatch.exists
        value["bottomButton"] = app.buttons["滚动到底部"].firstMatch.exists
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("OFFBOTTOM_SAMPLE " + String(data: data, encoding: .utf8)!)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = caseLabel + "-" + label; attachment.lifetime = .keepAlways; add(attachment)
        return value
    }
    func testSend() throws {
        continueAfterFailure = false; executionTimeAllowance = 600
        print("OFFBOTTOM_TARGET_DRIVER_20261003_V1")
        let data = try Data(contentsOf: URL(string: "http://127.0.0.1:18473/case")!)
        let config = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(config["cases"], "one independently prepared synthetic case per run")
        app.activate()
        XCTAssertTrue(input.waitForExistence(timeout: 30)); XCTAssertTrue(list.waitForExistence(timeout: 15))
        input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        input.typeText("OFFBOTTOM_SEED"); app.buttons["arrow.up"].firstMatch.tap()
        wait("seed complete") { !self.app.buttons["stop.fill"].firstMatch.exists && (self.input.value as? String) == "" }
        wait("seed bottom") { abs(self.number("bottomGap")) <= 2 }
        try exercise(config)
    }
    func exercise(_ config: [String: Any]) throws {
        caseLabel = config["label"] as? String ?? "case"
        let text = config["text"] as! String
        let observeOnly = config["observeOnly"] as? Bool == true
        let bottom = app.buttons["滚动到底部"].firstMatch
        if bottom.exists && bottom.isHittable { bottom.tap() }
        wait("case begins at bottom") { abs(self.number("bottomGap")) <= 2 }
        input.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        input.typeText(text); XCTAssertEqual(input.value as? String, text)
        if config["hidden"] as? Bool == true {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.32)).tap()
            wait("keyboard hidden") { !self.app.keyboards.firstMatch.exists }
        }
        if config["offBottom"] as? Bool == true {
            for _ in 0..<3 {
                if number("bottomGap") > 700 { break }
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.17))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.40))
                start.press(forDuration: 0.1, thenDragTo: end)
                Thread.sleep(forTimeInterval: 1)
            }
            wait("off-bottom and idle") {
                self.number("bottomGap") > 500 && self.state()["decelerating"] as? Bool == false
                    && self.state()["dragging"] as? Bool == false
            }
        } else { wait("starts at bottom") { abs(self.number("bottomGap")) <= 2 } }
        sample("before-send")
        print("OFFBOTTOM_TARGET_TAP_WALL \(Date().timeIntervalSince1970)")
        app.buttons["arrow.up"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        let landed = sample("landed-before-reply", settledBottom: !observeOnly)
        if !observeOnly {
            XCTAssertEqual((landed["bottomGap"] as! NSNumber).doubleValue, 0, accuracy: 2, caseLabel + " must land at true bottom")
        }
        if config["stopEarly"] as? Bool == true {
            XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists)
            app.buttons["stop.fill"].firstMatch.tap()
            wait("stop complete") { !self.app.buttons["stop.fill"].firstMatch.exists }
            Thread.sleep(forTimeInterval: 1); sample("stopped")
            if !observeOnly { XCTAssertEqual(number("bottomGap"), 0, accuracy: 2) }
            return
        }
        let checkpoint = try Data(contentsOf: URL(string: "http://127.0.0.1:18473/stream-checkpoint")!)
        let checkpointState = try JSONSerialization.jsonObject(with: checkpoint) as! [String: Any]
        XCTAssertEqual(checkpointState["paused"] as? Bool, true, "fixture must hold its first burst while the response remains active")
        let growing = sample("during-stream", settledBottom: !observeOnly)
        XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists, "follow must be sampled while generation continues")
        if !observeOnly {
            XCTAssertEqual((growing["bottomGap"] as! NSNumber).doubleValue, 0, accuracy: 2, caseLabel + " must follow growing reply")
        }
        let growthHeight = (growing["contentHeight"] as! NSNumber).doubleValue
        XCTAssertGreaterThan(growthHeight, (landed["contentHeight"] as! NSNumber).doubleValue + 100, "stream must grow before the checkpoint")
        var readingOffset: Double?
        if config["manualDetach"] as? Bool == true {
            XCTAssertTrue(app.buttons["stop.fill"].firstMatch.exists, "manual reading is exercised during generation")
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.20))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.55))
            start.press(forDuration: 0.1, thenDragTo: end)
            wait("manual reading is detached") {
                self.number("bottomGap") > 200 && self.state()["decelerating"] as? Bool == false
                    && self.state()["dragging"] as? Bool == false
            }
            readingOffset = number("offsetY"); sample("manual-reading")
        }
        _ = try Data(contentsOf: URL(string: "http://127.0.0.1:18473/continue-stream")!)
        wait("reply complete", timeout: 40) { !self.app.buttons["stop.fill"].firstMatch.exists }
        Thread.sleep(forTimeInterval: 1)
        sample("completed", settledBottom: readingOffset == nil && !observeOnly)
        XCTAssertGreaterThan(number("contentHeight"), growthHeight + 100, "reply must grow after the stream sample")
        if let readingOffset {
            XCTAssertEqual(number("offsetY"), readingOffset, accuracy: 2, "manual reading must retain ownership")
            XCTAssertGreaterThan(number("bottomGap"), 200)
        } else if !observeOnly { XCTAssertEqual(number("bottomGap"), 0, accuracy: 2, caseLabel + " must finish at bottom") }
        XCTAssertEqual(input.value as? String, "")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }
}
