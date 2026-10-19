import Foundation

/// Bundle ID 从早期内部测试版改为正式的 com.kaizaoji.windowatlas 后，偏好设置域随之变化；首次启动把旧域中的设置复制过来。
/// 旧域名只在构建时由环境变量 LEGACY_DEFAULTS_DOMAIN 写入 Info.plist（WALegacyDefaultsDomain），源码中不出现内部名称；
/// 正式发布版本没有该键，迁移不执行。笔记与命令库位于 Application Support/WindowAtlas，路径不变。
enum LegacyMigration {
    static var legacyDomain: String? { Bundle.main.object(forInfoDictionaryKey: "WALegacyDefaultsDomain") as? String }
    static let doneKey = "migratedFromLegacyBundleID"

    /// 只复制新域中尚不存在的键，不删除旧域（便于回退旧版本），只执行一次。返回复制的键数。
    @discardableResult
    static func migrateDefaults(into defaults: UserDefaults = .standard, legacy: [String: Any]? = nil) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let source = legacy ?? legacyDomain.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        var copied = 0
        for (key, value) in source where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: doneKey)
        return copied
    }
}
