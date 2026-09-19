import Foundation
import Observation
import SwiftUI

/// Keep familiar Latin letterforms in typography icons without changing UI text.
struct AppSymbolImage: View {
    let systemName: String
    @Environment(\.locale) private var locale

    var body: some View {
        Image(systemName: systemName)
            .environment(\.locale, usesLatinLetterforms ? Locale(identifier: "en") : locale)
    }

    private var usesLatinLetterforms: Bool {
        switch systemName {
        case "textformat", "textformat.size", "text.cursor": true
        default: false
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .system: L10n.lookup("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    static func resolve(_ selection: Self, preferredLanguages: [String]) -> String {
        guard selection == .system else { return selection.rawValue }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
            if code == "en" || code.hasPrefix("en-") { return "en" }
        }
        return "en"
    }
}

/// This observable state changes only for language choices or system-language
/// changes. It is independent of streaming, messages and general preferences.
@MainActor @Observable
final class AppLocalization {
    static let shared = AppLocalization()
    static let preferenceKey = "mocca.interfaceLanguage"
    private(set) var selection: AppLanguage
    private(set) var languageCode: String
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        let selection = AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
        self.selection = selection
        self.languageCode = AppLanguage.resolve(selection, preferredLanguages: preferredLanguages)
    }

    var locale: Locale { Locale(identifier: languageCode) }

    func select(_ selection: AppLanguage) {
        guard self.selection != selection else { return }
        self.selection = selection
        defaults.set(selection.rawValue, forKey: Self.preferenceKey)
        refreshSystemLanguage()
    }

    func refreshSystemLanguage(preferredLanguages: [String] = Locale.preferredLanguages) {
        let resolved = AppLanguage.resolve(selection, preferredLanguages: preferredLanguages)
        if languageCode != resolved { languageCode = resolved }
    }
}

/// Use only for app-owned display strings, never user messages or identifiers.
@MainActor enum L10n {
    private static let bundles: [String: Bundle] = ["zh-Hans", "en"].reduce(into: [:]) { result, code in
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
            result[code] = bundle
        }
    }
    static func format(_ key: String, _ arguments: [String]) -> String {
        String(format: lookup(key), locale: AppLocalization.shared.locale, arguments: arguments.map { $0 as CVarArg })
    }
    static func lookup(_ key: String) -> String {
        let code = AppLocalization.shared.languageCode
        return (bundles[code] ?? .main).localizedString(forKey: key, value: key, table: "Localizable")
    }
}

struct AppLanguagePicker: View {
    var usesSettingsRowStyle = false

    var body: some View {
        Picker(selection: Binding(
            get: { AppLocalization.shared.selection },
            set: { AppLocalization.shared.select($0) }
        )) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.title).tag(language)
            }
        } label: {
            if usesSettingsRowStyle {
                SettingsOverviewRowLabel(title: "语言 / Language", systemImage: "globe")
            } else {
                Label("语言 / Language", systemImage: "globe")
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("localization.languagePicker")
    }
}

// The stored placeholder stays stable for auto-title detection and old backups.
@MainActor extension Conversation {
    var localizedDisplayTitle: String {
        title == Self.defaultTitle ? L10n.lookup(Self.defaultTitle) : title
    }
}

/// Error descriptions can be requested by background work. This resolver uses
/// thread-safe Foundation preferences/resources and does not observe UI state.
enum ErrorLocalization {
    private static let bundles: [String: Bundle] = ["zh-Hans", "en"].reduce(into: [:]) { result, code in
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
            result[code] = bundle
        }
    }
    static func lookup(_ key: String) -> String {
        let selection = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "mocca.interfaceLanguage") ?? "") ?? .system
        let code = AppLanguage.resolve(selection, preferredLanguages: Locale.preferredLanguages)
        return (bundles[code] ?? .main).localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func format(_ key: String, _ arguments: [String]) -> String {
        String(format: lookup(key), arguments: arguments.map { $0 as CVarArg })
    }
}
