import XCTest
import SwiftUI
@testable import Mocca

private actor ImageSearchCallRecorder {
    var flags: [Bool] = []
    func record(_ value: Bool) -> String { flags.append(value); return "{}" }
    func values() -> [Bool] { flags }
}

@MainActor final class SearchToolPromptTests: XCTestCase {
    func testAssistantIdentityDefaultsPreserveExplicitChoices() throws {
        let new = AssistantProfile(name: "Default")
        XCTAssertTrue(new.useAssistantAvatar && new.useAssistantName)
        let missing = try JSONDecoder().decode(AssistantProfile.self, from: Data("{}".utf8))
        XCTAssertTrue(missing.useAssistantAvatar && missing.useAssistantName)
        let explicit = try JSONDecoder().decode(AssistantProfile.self,
            from: Data(#"{"useAssistantAvatar":false,"useAssistantName":false}"#.utf8))
        XCTAssertFalse(explicit.useAssistantAvatar || explicit.useAssistantName)
    }

    func testThemeControlsFollowPaletteAndLegacyColorsSurvive() throws {
        XCTAssertEqual(ThemePaletteID.presets, [.defaultPalette, .latte, .matcha, .berry, .mist])
        XCTAssertEqual(ThemePaletteID.presetsIncludingCurrent(.blue).last, .blue)
        XCTAssertFalse(ThemePaletteID.presetsIncludingCurrent(.custom).contains(.custom))
        let old = try JSONDecoder().decode(ThemePaletteID.self, from: Data("\"smoky_rose\"".utf8))
        XCTAssertEqual(old.lightAccentARGB, 0xff824e6c)
        let model = AppModel()
        for palette in ThemePaletteID.allCases {
            model.preferences.themePaletteID = palette
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                let accent = model.themeAccentUIColor.resolvedColor(with: traits)
                let action = palette == .defaultPalette ? UIColor.systemBlue.resolvedColor(with: traits) : accent
                let toggle = palette == .defaultPalette ? UIColor.systemGreen.resolvedColor(with: traits) : accent
                XCTAssertEqual(model.themeActionUIColor.resolvedColor(with: traits), action)
                XCTAssertEqual(model.themeSwitchUIColor.resolvedColor(with: traits), toggle)
                XCTAssertEqual(model.themeSliderUIColor.resolvedColor(with: traits), action)
                XCTAssertEqual(model.themeTextSelectionUIColor.resolvedColor(with: traits), action)
            }
        }
    }

    func testImageSearchDefaultsOffAndPersistsPerAssistant() throws {
        let old = try JSONDecoder().decode(AssistantProfile.self, from: Data("{}".utf8))
        XCTAssertFalse(old.imageSearchEnabled)
        var first = AssistantProfile(name: "One")
        let second = AssistantProfile(name: "Two")
        first.imageSearchEnabled = true
        let restored = try JSONDecoder().decode([AssistantProfile].self, from: JSONEncoder().encode([first, second]))
        XCTAssertTrue(restored[0].imageSearchEnabled)
        XCTAssertFalse(restored[1].imageSearchEnabled)
        XCTAssertEqual(SearchToolConstants.requestSystemPrompt("custom", imageSearchEnabled: true), "custom")
        XCTAssertTrue(SearchToolConstants.requestSystemPrompt("custom", imageSearchEnabled: false).contains("include_images must be false"))
    }

    func testImageSearchCannotBeEnabledByToolArgumentsWhenDisabled() async {
        for enabled in [false, true] {
            let recorder = ImageSearchCallRecorder()
            let handler = ToolCallExecutor.buildHandler(
                assistant: AssistantProfile(name: "Synthetic", imageSearchEnabled: enabled),
                memoryUpdater: nil, conversationSearcher: nil,
                searchExecutor: { _, images in await recorder.record(images) }
            )
            _ = await handler("search_web", ["query": "找猫图片", "include_images": true], nil)
            _ = await handler("search_web", ["query": "找猫图片"], nil)
            _ = await handler("search_web", ["query": "找猫图片", "include_images": false], nil)
            let flags = await recorder.values()
            XCTAssertEqual(flags, enabled ? [true, true, false] : [false, false, false])
        }
    }

    func testSearchImagesShareExistingHistoricalBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func image(_ index: Int, searched: Bool = false) throws -> MessageAttachment {
            let url = directory.appendingPathComponent("\(index).png")
            try Data([UInt8(index)]).write(to: url)
            var attachment = MessageAttachment(kind: .image, localURL: url, mimeType: "image/png")
            if searched { attachment.metadata["source"] = "web_search_image" }
            return attachment
        }
        let assistant = AssistantProfile(name: "Synthetic", imageSearchEnabled: true)
        let chat = Conversation(assistantID: assistant.id.uuidString)
        let rows = [
            ChatMessage(conversationID: chat.id, role: .user, text: "old", attachments: [try image(1), try image(2)]),
            ChatMessage(conversationID: chat.id, role: .assistant, text: "search", attachments: [try image(3, searched: true), try image(4, searched: true)]),
            ChatMessage(conversationID: chat.id, role: .user, text: "new", attachments: [try image(5)])
        ]
        var provider = ProviderConfiguration.new(type: .openAI)
        provider.models = [ModelConfiguration(id: "search-vision", capabilityOverride: ModelCapabilities(input: [.text, .image]))]
        var preferences = UserPreferences()
        preferences.historicalImageResendLimit = 3
        for enabled in [false, true] {
            preferences.resendHistoricalImages = enabled
            let messages = try await ChatRequestPreparation.messages(from: rows, assistant: assistant,
                provider: provider, preferences: preferences, conversation: chat, assistants: [assistant], ocrContext: nil, modelID: "search-vision")
            XCTAssertEqual(messages[0].images.count, enabled ? 1 : 0)
            XCTAssertEqual(messages[1].images.count, enabled ? 2 : 0)
            XCTAssertEqual(messages[2].images.count, 1)
        }
        XCTAssertEqual(rows[1].attachments.count, 2, "History transmission never deletes displayed results")
    }

    func testOldPreferencesFollowBundledDefault() throws {
        let old = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.searchToolPrompt, "")
        XCTAssertEqual(old.effectiveSearchToolPrompt, SearchToolConstants.systemPrompt)
        XCTAssertTrue(old.effectiveSearchToolPrompt.contains("[citation](index:id)"))
        XCTAssertTrue(old.effectiveSearchToolPrompt.contains("<ks-image>"))
    }

    func testCustomPromptSurvivesPreferencesAndBackupEncoding() throws {
        let custom = "先搜索官方文档。🥳\n保留 citation 格式。\nSecond paragraph."
        let preferences = UserPreferences(searchToolPrompt: " \n" + custom + "\n ")
        let restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.searchToolPrompt, custom)
        XCTAssertEqual(restored.effectiveSearchToolPrompt, custom)
        XCTAssertFalse(restored.effectiveSearchToolPrompt.contains("## search_web"))
        let backup = try JSONEncoder().encode(["preferences": preferences])
        let restoredBackup = try JSONDecoder().decode([String: UserPreferences].self, from: backup)
        XCTAssertEqual(restoredBackup["preferences"]?.searchToolPrompt, custom)
    }

    func testRestoreAndBlankFollowBundledDefaultAfterReload() throws {
        for draft in ["", " \n\t ", SearchToolConstants.systemPrompt] {
            var preferences = UserPreferences(searchToolPrompt: "custom")
            preferences.searchToolPrompt = SearchToolConstants.normalizedCustomPrompt(draft)
            let restored = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(restored.searchToolPrompt, "")
            XCTAssertEqual(restored.effectiveSearchToolPrompt, SearchToolConstants.systemPrompt)
        }
    }

    func testSavingDoesNotChangeSearchProviderOrOtherOptions() throws {
        var preferences = UserPreferences(searchResultCount: 7, searchTimeoutSeconds: 9,
                                          searchToolResultRetentionTurns: 3)
        let service = preferences.searchServices.first
        preferences.searchToolPrompt = "优先参考原始资料。"
        XCTAssertTrue(AppPreferences.savePreferences(preferences))
        let restored = AppPreferences.loadPreferences()
        XCTAssertEqual(restored.searchToolPrompt, "优先参考原始资料。")
        XCTAssertEqual(restored.searchResultCount, 7)
        XCTAssertEqual(restored.searchTimeoutSeconds, 9)
        XCTAssertEqual(restored.searchToolResultRetentionTurns, 3)
        XCTAssertEqual(restored.searchServices.first?.id, service?.id)
        XCTAssertEqual(restored.selectedSearchServiceID, preferences.selectedSearchServiceID)
    }

    func testSearchSettingsAndEditorSnapshots() async throws {
        let model = AppModel()
        model.preferences.searchToolPrompt = ""
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        func capture<V: View>(_ view: V, _ name: String) async {
            window.rootViewController = UIHostingController(rootView: view.environment(model))
            window.makeKeyAndVisible()
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        AppLocalization.shared.select(.simplifiedChinese)
        await capture(NavigationStack { SearchServiceSettingsView() }, "search-settings")
        await capture(NavigationStack {
            SearchToolPromptEditorPage(initialPrompt: model.preferences.effectiveSearchToolPrompt) { _ in }
        }, "search-prompt-editor")
        window.isHidden = true
    }
}
