import XCTest
@testable import WindowAtlas

final class AppPreferencesTests: XCTestCase {
    private var suites: [String] = []

    /// 每个用例独立偏好域，结束后清空并删除对应 plist，不在用户的 ~/Library/Preferences 留下测试文件。
    private func makeDefaults() throws -> UserDefaults {
        let name = "WindowAtlasPreferencesTests-\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDown() {
        for name in suites {
            UserDefaults().removePersistentDomain(forName: name)
            let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        suites.removeAll()
        super.tearDown()
    }

    func testLegacyDefaultsMigrateOnceWithoutOverwriting() throws {
        let defaults = try makeDefaults()
        defaults.set("dark", forKey: "interfaceAppearance")
        let legacy: [String: Any] = ["interfaceAppearance": "light", "appOrder": ["com.apple.Terminal"], "favorites": ["a|b"]]
        XCTAssertEqual(LegacyMigration.migrateDefaults(into: defaults, legacy: legacy), 2)
        XCTAssertEqual(defaults.string(forKey: "interfaceAppearance"), "dark", "新域已有的设置不被旧值覆盖")
        XCTAssertEqual(defaults.stringArray(forKey: "appOrder"), ["com.apple.Terminal"])
        XCTAssertEqual(LegacyMigration.migrateDefaults(into: defaults, legacy: ["chromeTabsEnabled": true]), 0, "只迁移一次")
        XCTAssertNil(defaults.object(forKey: "chromeTabsEnabled"))
    }
    @MainActor
    func testPreferencesPersistWithoutChangingSystemLanguage() throws {
        let defaults = try makeDefaults()
        defaults.set(["fr"], forKey: "AppleLanguages")
        let preferences = AppPreferences(defaults: defaults, beforeLanguageChange: { true })
        preferences.appearance = .dark
        preferences.setLanguage(.english)
        let restored = AppPreferences(defaults: defaults, beforeLanguageChange: { true })
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertEqual(restored.language, .english)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["fr"])
    }

    @MainActor
    func testFailedSavePreventsLanguageChangeAndAllowsRetry() throws {
        let defaults = try makeDefaults()
        var canSave = false
        let preferences = AppPreferences(defaults: defaults, beforeLanguageChange: { canSave })
        preferences.setLanguage(.english)
        XCTAssertEqual(preferences.language, .chinese)
        XCTAssertNil(defaults.string(forKey: "interfaceLanguage"))
        canSave = true
        preferences.setLanguage(.english)
        XCTAssertEqual(preferences.language, .english)
    }

    @MainActor
    func testInvalidPreferencesFallBackToSupportedValues() throws {
        let defaults = try makeDefaults()
        defaults.set("invalid", forKey: "interfaceAppearance")
        defaults.set("invalid", forKey: "interfaceLanguage")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.language, .chinese)
        XCTAssertNil(AppAppearance.system.appearance)
        XCTAssertNotNil(AppAppearance.light.appearance)
        XCTAssertNotNil(AppAppearance.dark.appearance)
    }

    func testTranslationsResolveAndUnknownUserTextIsPreserved() {
        XCTAssertEqual(Localization.string("创建时间：%@", language: .english), "Created: %@")
        XCTAssertEqual(Localization.string("全部窗口", language: .english), "All Windows")
        XCTAssertEqual(Localization.string("全部窗口", language: .chinese), "全部窗口")
        XCTAssertEqual(Localization.string("用户自己的标题", language: .english), "用户自己的标题")
    }

    func testTranslationTablesHaveMatchingKeysAndFormatArguments() throws {
        func table(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let chinese = try table("zh-Hans"), english = try table("en")
        XCTAssertEqual(Set(chinese.keys), Set(english.keys))
        let format = try NSRegularExpression(pattern: "%[@dfisu]|%ld|%lld|%%")
        func arguments(_ value: String) -> [String] {
            let text = value as NSString
            return format.matches(in: value, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
        }
        for (key, translated) in english {
            XCTAssertFalse(translated.isEmpty, key)
            XCTAssertEqual(arguments(key), arguments(translated), key)
        }
    }
}
