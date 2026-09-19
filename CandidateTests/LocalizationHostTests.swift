import Foundation
import Observation
import SwiftUI
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func bump() { lock.lock(); defer {lock.unlock()}; stored += 1 }
    var value: Int { lock.lock(); defer {lock.unlock()}; return stored }
}
@main struct LocalizationTests {
    @MainActor static func main() throws {
        let name = "Mocca.Localization.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppLocalization(defaults: defaults, preferredLanguages: ["zh-Hans-CN"])
        precondition(model.selection == .system && model.languageCode == "zh-Hans")
        precondition(AppLanguage.resolve(.system, preferredLanguages: ["fr-FR", "en-US"]) == "en")
        precondition(AppLanguage.resolve(.system, preferredLanguages: ["fr", "zh-TW"]) == "zh-Hans")
        precondition(AppLanguage.resolve(.system, preferredLanguages: ["ja"]) == "en")
        model.select(.english)
        model.refreshSystemLanguage(preferredLanguages: ["zh-Hans"])
        precondition(model.languageCode == "en")
        let restored = AppLocalization(defaults: defaults, preferredLanguages: ["zh-Hans"])
        precondition(restored.selection == .english && restored.languageCode == "en")
        model.select(.system)
        model.refreshSystemLanguage(preferredLanguages: ["zh-Hans"])
        precondition(model.languageCode == "zh-Hans")
        let count=Counter()
        withObservationTracking { _ = model.languageCode } onChange: { count.bump() }
        for _ in 0..<100 { model.refreshSystemLanguage(preferredLanguages: ["zh-Hans"]) }
        precondition(count.value == 0)
        model.refreshSystemLanguage(preferredLanguages: ["en-US"])
        precondition(count.value == 1)
        let savedSelection=AppLocalization.shared.selection
        defer {AppLocalization.shared.select(savedSelection)}
        AppLocalization.shared.select(.english)
        precondition(L10n.lookup("设置") == "Settings")
        precondition(L10n.lookup("等待图文回复") == "Waiting for text and image response")
        precondition(L10n.format("给 %@发消息", ["用户原名"]) == "Message 用户原名")
        precondition(L10n.format("亮 %@%% / 暗 %@%%", ["50", "70"]) == "Light 50% / Dark 70%")
        precondition(L10n.lookup("An unknown key") == "An unknown key")
        let credits = ProviderBalanceResult.credits(remaining: "12.34", total: "20")
        let providerText = ProviderBalanceResult.value("用户自定义余额文字")
        precondition(credits.localizedText == "Remaining 12.34 · Total 20")
        precondition(providerText.localizedText == "用户自定义余额文字")
        precondition(L10n.lookup("自定义偏好") == "Custom preferences")
        precondition(!L10n.lookup("投喂项目还没有从 App Store 载入。").contains("投喂"))
        precondition(L10n.format("首次送 💧＋%@ 纪念装扮", ["🍬"]) == "First tip unlocks 💧 + 🍬 keepsakes")
        AppLocalization.shared.select(.simplifiedChinese)
        precondition(credits.localizedText == "剩余 12.34 · 总额 20")
        precondition(providerText.localizedText == "用户自定义余额文字")
        precondition(L10n.lookup("设置") == "设置")
        precondition(L10n.lookup("等待图文回复") == "等待图文回复")
        precondition(L10n.format("给 %@发消息", ["Alice"]) == "给 Alice发消息")
        print("PASS language choice, system resolution, preference persistence, notification isolation, compiled catalog lookup and interpolation")
    }
}
