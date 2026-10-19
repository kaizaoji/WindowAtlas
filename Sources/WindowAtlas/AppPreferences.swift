import AppKit
import SwiftUI

/// 使用独立语言偏好，避免修改系统 AppleLanguages 或用户笔记内容。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .chinese
    let translated = Localization.string(key, language: language)
    return arguments.isEmpty ? translated : String(format: translated, locale: Locale(identifier: language.rawValue), arguments: arguments)
}

enum Localization {
    // 安装包使用标准 Resources 目录，SwiftPM 的默认访问器只作为开发与测试回退。
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "WindowAtlas_WindowAtlas", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static func string(_ key: String, language: AppLanguage) -> String {
        // SwiftPM 会将本地化目录转为小写；显式指定目录，避免回退到系统语言。
        let bundle = resourceBundle.path(forResource: language.rawValue.lowercased(), ofType: "lproj").flatMap(Bundle.init(path:)) ?? resourceBundle
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String { self == .chinese ? "简体中文" : "English" }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private let defaults: UserDefaults
    private let beforeLanguageChange: () -> Bool
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "interfaceAppearance")
            applyAppearance()
            NotificationCenter.default.post(name: Self.appearanceChanged, object: nil)
        }
    }
    @Published private(set) var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "interfaceLanguage")
            NotificationCenter.default.post(name: Self.languageChanged, object: nil)
        }
    }
    static let appearanceChanged = Notification.Name("WindowAtlasInterfaceAppearanceChanged")
    static let languageChanged = Notification.Name("WindowAtlasInterfaceLanguageChanged")
    var locale: Locale { Locale(identifier: language.rawValue) }

    init(defaults: UserDefaults = .standard, beforeLanguageChange: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.beforeLanguageChange = beforeLanguageChange ?? {
            guard AppDelegate.shared?.commandLibrary.canLeaveEditor() != false else { return false }
            return AppDelegate.shared?.notes.flush() ?? true
        }
        appearance = AppAppearance(rawValue: defaults.string(forKey: "interfaceAppearance") ?? "") ?? .system
        language = AppLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .chinese
    }

    func setLanguage(_ value: AppLanguage) {
        guard value != language else { return }
        // 展示层重建前确认编辑已落盘；失败时保留原界面与光标。
        guard beforeLanguageChange() else { return }
        language = value
    }

    func applyAppearance() { NSApp?.appearance = appearance.appearance }
}

/// 切换语言时重建展示层，实际编辑内容由外部 NotesStore 持有。
struct LocalizedRootView<Content: View>: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .environment(\.locale, preferences.locale)
            .id(preferences.language)
    }
}

struct AppearanceSettingsMenu: View {
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        Menu {
            ForEach(AppAppearance.allCases) { appearance in
                Button {
                    preferences.appearance = appearance
                } label: {
                    if preferences.appearance == appearance {
                        Label(appearance.title, systemImage: "checkmark")
                    } else {
                        Text(appearance.title)
                    }
                }
            }
        } label: {
            Label(preferences.appearance.title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(L("外观"))
        .accessibilityValue(preferences.appearance.title)
        .help(L("切换浅色、深色或跟随系统"))
    }

    private var symbol: String {
        switch preferences.appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

struct LanguageSettingsMenu: View {
    @ObservedObject private var preferences = AppPreferences.shared
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    preferences.setLanguage(language)
                } label: {
                    if preferences.language == language {
                        Label(language.title, systemImage: "checkmark")
                    } else {
                        Text(language.title)
                    }
                }
            }
        } label: {
            Label(preferences.language.title, systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(L("语言"))
        .accessibilityValue(preferences.language.title)
        .help(L("切换界面语言"))
    }
}

struct InterfaceSettingsMenu: View {
    var body: some View {
        HStack(spacing: 8) {
            AppearanceSettingsMenu()
            LanguageSettingsMenu()
        }
    }
}
