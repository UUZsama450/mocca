import XCTest

/// Runs the actual app on a disposable simulator with generated chat fixtures.
/// These are interaction/geometry checks, not physical-device performance data.
@MainActor
final class LivePanelUITests: XCTestCase {
    private let bundle = "com.uuzsama450.mocca.migration"

    func testNativeEntryAndDrawer() throws { try entryAndDrawer() }
    func testNativeKeyboard() throws { try keyboard() }
    func testNativeEmptyAndGestures() throws { try emptyAndGestures() }

    func testNativeBackgroundDuringPartialDrag() throws {
        // Run with the simulator Home sidecar: XCTest rejects overlapping
        // touch synthesis and XCUIDevice.press(.home) in its own event queue.
        let app = launch(fixture: "-previewKeyboardShortChat")
        for (name, endX, opens) in [("near-chat", 0.28, false), ("near-drawer", 0.68, true)] {
            app.buttons["新聊天"].firstMatch.tap()
            let closedX = drawer(app).frame.minX
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
            print("SCENE_EXPECTED_DRAG_END \(endX)")
            let began = Date()
            print("SCENE_DRAG_BEGIN \(name)")
            Thread.sleep(forTimeInterval: 6) // Sidecar holds the touch across Home and foreground activation.
            print("SCENE_DRAG_RETURN \(name) elapsed=\(Date().timeIntervalSince(began))")
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            let expectedX = closedX + (opens ? min(app.frame.width * 0.78, 390) : 0)
            capture(app, "background-\(name)")
            XCTAssertEqual(drawer(app).frame.minX, expectedX, accuracy: 3)
            print("SCENE_RELEASE_HELD_TOUCH \(name)")
            Thread.sleep(forTimeInterval: 0.8)
            if opens {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)).tap()
                wait { abs(self.drawer(app).frame.minX - closedX) < 3 }
            }
            // A new drag must work on the first attempt after the interruption.
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)))
            wait { self.drawer(app).frame.minX > app.frame.width * 0.65 }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)).tap()
            wait { abs(self.drawer(app).frame.minX - closedX) < 3 }
        }
    }

    func testNativeStableEndpointsSurviveBackground() throws {
        let app = launch(fixture: "-previewKeyboardShortChat")
        let closedX = drawer(app).frame.minX
        for open in [false, true] {
            if open { drawer(app).tap() }
            let stableX = closedX + (open ? min(app.frame.width * 0.78, 390) : 0)
            // The custom display-link spring can still be moving after tap()
            // returns. This test's input must already be a stable endpoint.
            wait { abs(self.drawer(app).frame.minX - stableX) < 0.5 }
            let before = drawer(app).frame.minX
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            // Process foreground state precedes SpringBoard's app zoom. Wait
            // for a measurable UI element, without waiting for our endpoint.
            wait { self.drawer(app).exists && self.drawer(app).frame.minX.isFinite }
            XCTAssertEqual(drawer(app).frame.minX, before, accuracy: 3)
            capture(app, "background-stable-\(open)")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.45)).tap()
        wait { self.drawer(app).frame.minX < 100 }
        composer(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    }

    func testNativePartialAndRepeatedFingerDrags() throws {
        let app = launch(fixture: "-previewKeyboardShortChat")
        app.buttons["新聊天"].firstMatch.tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
        let partial = app.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 0.3)
        wait { self.drawer(app).frame.minX < 100 }
        for cycle in 0..<3 {
            let opened = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: opened, withVelocity: .slow, thenHoldForDuration: 0.1)
            wait { self.drawer(app).frame.minX > app.frame.width * 0.65 }
            capture(app, "finger-open-\(cycle)")
            let closed = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45))
            opened.press(forDuration: 0.05, thenDragTo: closed, withVelocity: .slow, thenHoldForDuration: 0.1)
            wait { self.drawer(app).frame.minX < 100 }
            XCTAssertTrue(composer(app).exists)
            capture(app, "finger-closed-\(cycle)")
        }
    }

    private func launch(fixture: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launchArguments = [fixture]
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 3) { later.tap() }
        XCTAssertTrue(drawer(app).waitForExistence(timeout: 20))
        return app
    }

    private func drawer(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["打开聊天列表"].firstMatch
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label ENDSWITH %@", "给", "发消息"
        )).firstMatch
    }

    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("LIVE_PANEL_GEOMETRY \(name) drawer=\(drawer(app).frame) composer=\(composer(app).frame) app=\(app.frame)")
    }

    private func entryAndDrawer() throws {
        let app = launch(fixture: "-previewNavigationStress")
        for name in ["A", "B", "A"] {
            drawer(app).tap()
            let row = app.buttons["导航压力 \(name)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            capture(app, "native-open-\(name)")
            row.tap() // One tap must reach the exposed drawer through the wrapper.
            wait { self.drawer(app).frame.minX < 100 }
            let conversationText = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@", "\(name) 用户消息 18："
            )).firstMatch
            XCTAssertTrue(conversationText.exists)
            let tail = app.textViews.matching(NSPredicate(
                format: "label BEGINSWITH %@", "这是第 18 段模拟回复"
            )).element(boundBy: 3)
            wait {
                tail.exists && tail.frame.minY >= 110
                    && tail.frame.maxY <= app.frame.height - 130
            }
            capture(app, "native-entry-\(name)")
        }
        // The original live transcript must still scroll after closing.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: end)
        drawer(app).tap()
        app.buttons["导航压力 A"].firstMatch.tap()
        wait { self.drawer(app).frame.minX < 100 }
        capture(app, "native-same-conversation-return")
        // The native shield over the dimmed panel must close on its first tap.
        drawer(app).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        wait { self.drawer(app).frame.minX < 100 }
    }

    private func keyboard() throws {
        let app = launch(fixture: "-previewKeyboardShortChat")
        let tail = app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "第三轮短回复："
        )).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 15))
        composer(app).tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        wait {
            tail.exists && tail.frame.minY >= 110
                && tail.frame.maxY < keyboard.frame.minY - 80
        }
        capture(app, "native-keyboard")
        drawer(app).tap()
        let row = app.buttons["键盘测试"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        wait {
            self.drawer(app).frame.minX < 100 && tail.exists
                && tail.frame.minY >= 110 && tail.frame.maxY < app.frame.height - 130
        }
        capture(app, "native-keyboard-reentry")
    }

    private func emptyAndGestures() throws {
        let app = launch(fixture: "-previewKeyboardShortChat")
        XCTAssertTrue(app.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "第三轮短回复："
        )).firstMatch.waitForExistence(timeout: 15))
        app.buttons["新聊天"].firstMatch.tap()
        XCTAssertTrue(composer(app).exists)
        // Horizontal finger movement must still use Root's existing gesture.
        // Use the empty page so native text-selection arbitration does not own
        // the synthetic starting touch before the horizontal movement begins.
        let closedStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
        let openedEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.45))
        closedStart.press(forDuration: 0.05, thenDragTo: openedEnd)
        XCTAssertTrue(app.buttons["键盘测试"].firstMatch.waitForExistence(timeout: 10))
        let openStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45))
        let closeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
        openStart.press(forDuration: 0.05, thenDragTo: closeEnd)
        wait { self.drawer(app).frame.minX < 100 }
        drawer(app).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        wait { self.drawer(app).frame.minX < 100 }
        XCTAssertTrue(composer(app).exists)
        capture(app, "native-empty")
    }
}
