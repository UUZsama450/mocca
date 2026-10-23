import XCTest

@MainActor final class SearchToolPromptUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.mocca.qa.searchprompt")
    var editor: XCUIElement { app.textViews["searchToolPrompt.editor"] }
    var alert: XCUIElement { app.alerts["保存对搜索工具提示词的修改？"] }

    func launch() {
        app.launchArguments = ["-searchPromptUITest", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["Open search settings"].tap()
        XCTAssertTrue(app.navigationBars["搜索服务"].waitForExistence(timeout: 10))
    }

    func openEditor() {
        let entry = app.buttons["searchService.toolPrompt"]
        for _ in 0..<4 {
            if entry.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(entry.isHittable, app.debugDescription)
        entry.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    }

    func append(_ text: String) {
        editor.tap()
        editor.typeText(text)
    }

    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDraftExitSaveDiscardRestoreAndRelaunch() {
        continueAfterFailure = false
        launch()
        shot("search-settings")
        openEditor()
        app.buttons["searchToolPrompt.restoreDefault"].tap()
        app.buttons["searchToolPrompt.save"].tap()
        openEditor()
        let original = editor.value as! String
        XCTAssertTrue(original.contains("[citation](index:id)"))
        shot("search-default-editor")

        append("\nCUSTOM_PROMPT_QA")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Back swipe protects the draft")
        alert.buttons["继续编辑"].tap()
        app.buttons["searchToolPrompt.back"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        shot("search-unsaved-alert")
        alert.buttons["继续编辑"].tap()
        XCTAssertTrue((editor.value as? String)?.contains("CUSTOM_PROMPT_QA") == true)
        app.buttons["searchToolPrompt.back"].tap()
        alert.buttons["保存并离开"].tap()
        XCTAssertTrue(app.navigationBars["搜索服务"].waitForExistence(timeout: 5))
        app.terminate()
        launch()
        openEditor()
        let saved = editor.value as! String
        XCTAssertTrue(saved.contains("CUSTOM_PROMPT_QA"))

        append("\nDISCARD_THIS")
        app.buttons["searchToolPrompt.back"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["不保存"].tap()
        openEditor()
        XCTAssertEqual(editor.value as? String, saved)

        app.buttons["searchToolPrompt.restoreDefault"].tap()
        app.buttons["searchToolPrompt.back"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Restore is an unsaved edit")
        alert.buttons["继续编辑"].tap()
        XCTAssertEqual(editor.value as? String, original)
        // A sheet drag must also offer to preserve the draft.
        app.navigationBars["搜索工具提示词"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        alert.buttons["保存并离开"].tap()
        openEditor()
        XCTAssertEqual(editor.value as? String, original)
        XCTAssertFalse(app.buttons["searchToolPrompt.back"].exists, "Clean draft uses normal navigation")
        app.terminate()
        launch()
        openEditor()
        XCTAssertEqual(editor.value as? String, original)
    }

    func testImageSearchSettingPersists() {
        continueAfterFailure = false
        launch()
        let toggle = app.switches["searchService.imageSearch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "0" {
            let control = toggle.switches.firstMatch
            XCTAssertTrue(control.exists, app.debugDescription)
            control.tap()
        }
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        app.terminate()
        launch()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        shot("image-search-off")
    }

    func testMCPShortcutRetainsAssistantDraft() {
        continueAfterFailure = false
        app.launchArguments = ["-searchPromptUITest", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["Open assistant MCP"].tap()
        let name = app.textFields["qa.assistantName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" changed\n")
        let draft = name.value as? String
        app.buttons["assistant.mcp.manage"].tap()
        XCTAssertTrue(app.navigationBars["MCP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mcp.addServer"].exists)
        app.buttons["mcp.addServer"].tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        app.buttons["assistant.mcp.closeManagement"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, draft)
        shot("assistant-mcp-plus")
    }

    func testThemeChoicesAndDefaultActionTint() {
        continueAfterFailure = false
        app.launchArguments = ["-searchPromptUITest", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["Open themes"].tap()
        let last = app.buttons["theme.palette.mist"]
        for _ in 0..<8 {
            if last.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(last.isHittable, app.debugDescription)
        for id in ["default", "latte", "matcha", "berry", "mist"] {
            XCTAssertTrue(app.buttons["theme.palette.\(id)"].exists, id)
        }
        XCTAssertFalse(app.buttons["theme.palette.doc_theme"].exists)
        shot("mocca-theme-palette")
        app.buttons["theme.palette.default"].tap()
        app.buttons["Close themes"].tap()
        app.buttons["Open assistant actions"].tap()
        XCTAssertTrue(app.buttons["assistantMessageActions.edit"].waitForExistence(timeout: 5))
        shot("default-action-colors")
        app.buttons["assistantMessageActions.edit"].tap()
        XCTAssertTrue(app.buttons["assistantMessageActions.edit"].exists)
        shot("default-action-editing")
    }
}
