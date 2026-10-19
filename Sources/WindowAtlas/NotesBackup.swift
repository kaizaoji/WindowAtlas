import Foundation

/// 单向快照备份到用户选择的目录（云盘同步目录或任意目录）。只写本应用自己的子目录。
enum NotesBackup {
    static let folderName = "WindowAtlas 笔记备份"
    static let keepRecent = 20
    static let keepDailyDays = 30

    struct Item {
        /// 相对笔记库 notes/ 的路径，可含多级目录。
        let path: String
        let text: String
        let sensitive: Bool
    }

    /// v2 起记录目录树与空目录；v1 为扁平笔记，仍可校验恢复。
    static let manifestVersion = 2

    struct Manifest: Codable {
        struct FileRecord: Codable, Equatable { let file: String; let size: Int; let sha256: String }
        let version: Int
        let created: Date
        let digest: String
        let notes: [FileRecord]
        let attachments: [FileRecord]
        var folders: [String]? = nil
    }

    struct Report: Equatable {
        var snapshotName: String?
        var skippedUnchanged = false
        var noteCount = 0
        var excludedSensitive = 0
        var secretWarnings = 0
        var removedSnapshots: [String] = []
        var missingAttachments = 0
        /// 内容未变但最新快照已损坏：改名标记为 .damaged（保留不删、不计入保留策略）并重建完整快照。
        var quarantinedSnapshots: [String] = []
        var finished = Date()
    }

    struct Snapshot: Identifiable, Equatable {
        let name: String
        let url: URL
        let created: Date
        let noteCount: Int
        /// false 表示云盘只在本机保留了占位文件（如 iCloud 优化存储），已请求下载。
        var available = true
        var id: String { name }
    }

    enum BackupError: LocalizedError {
        case invalidDestination(String)
        case incompleteAttachments(Int)
        var errorDescription: String? {
            switch self {
            case .invalidDestination(let reason): return reason
            case .incompleteAttachments(let count): return String(format: L("备份未完成：%@ 个引用图片缺失或损坏，请修复图片后重试。"), String(describing: count))
            }
        }
    }

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    static func snapshotDate(_ name: String) -> Date? {
        // 同一秒内的第二份快照带「-2」后缀，日期部分固定 17 个字符。
        name.count >= 17 ? nameFormatter.date(from: String(name.prefix(17))) : nil
    }

    /// 备份根目录与本地主库不能互相包含，否则会递归备份或把备份写进主库。
    static func validate(destination: URL, libraryRoot: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return L("备份目录不存在或已断开，请重新选择。")
        }
        guard FileManager.default.isWritableFile(atPath: destination.path) else { return L("备份目录不可写，请检查权限或空间。") }
        let backup = destination.appendingPathComponent(folderName).resolvingSymlinksInPath().standardizedFileURL.path
        let library = libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if backup == library || backup.hasPrefix(library + "/") || library.hasPrefix(backup + "/") {
            return L("备份目录不能放在笔记库内，也不能包含笔记库。")
        }
        return nil
    }

    static func digest(notes: [Manifest.FileRecord], attachments: [Manifest.FileRecord], folders: [String] = []) -> String {
        let lines = (notes.map { "n:\($0.file):\($0.sha256)" } + attachments.map { "a:\($0.file)" } + folders.map { "d:\($0)" }).sorted()
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    /// includeSensitive 只用于用户主动导出迁移包；定时/手动备份始终排除敏感笔记。
    static func run(items: [Item], folders: [String] = [], attachmentsDirectory: URL, libraryRoot: URL, destination: URL,
                    includeSensitive: Bool = false, now: Date = Date()) throws -> Report {
        if let reason = validate(destination: destination, libraryRoot: libraryRoot) { throw BackupError.invalidDestination(reason) }
        let fileManager = FileManager.default
        let root = destination.appendingPathComponent(folderName, isDirectory: true)
        let sharedAttachments = root.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: sharedAttachments, withIntermediateDirectories: true)

        var report = Report(finished: now)
        let included = items.filter { (includeSensitive || !$0.sensitive) && NotesLibrary.isSafeRelativePath($0.path) }
        let safeFolders = folders.filter(NotesLibrary.isSafeRelativePath).sorted()
        report.excludedSensitive = items.count - included.count
        report.secretWarnings = included.filter { !SecretScanner.findings(in: $0.text).isEmpty }.count
        report.noteCount = included.count

        let noteRecords = included.map { item -> Manifest.FileRecord in
            let data = Data(item.text.utf8)
            return .init(file: item.path, size: data.count, sha256: sha256(data))
        }
        // 只备份非敏感笔记引用的附件；仅被敏感笔记引用的图片不出现在备份中。
        let referenced = included.reduce(into: Set<String>()) { $0.formUnion(NoteAttachments.referencedNames(in: $1.text)) }
        var attachmentRecords: [Manifest.FileRecord] = []
        for name in referenced.sorted() {
            guard let data = try? Data(contentsOf: attachmentsDirectory.appendingPathComponent(name)),
                  sha256(data) + "." + (name.split(separator: ".").last.map(String.init) ?? "") == name else {
                report.missingAttachments += 1; continue
            }
            let target = sharedAttachments.appendingPathComponent(name)
            let checksum = sha256(data)
            // 共享附件可能被同步冲突或磁盘损坏改写，同大小不能代表内容完整。
            if (try? Data(contentsOf: target)).map(sha256) != checksum {
                try data.write(to: target, options: .atomic)
            }
            attachmentRecords.append(.init(file: name, size: data.count, sha256: checksum))
        }
        // 缺图片时不发布快照，也不执行保留清理，避免用不完整备份替代可恢复版本。
        guard report.missingAttachments == 0 else { throw BackupError.incompleteAttachments(report.missingAttachments) }

        let currentDigest = digest(notes: noteRecords, attachments: attachmentRecords, folders: safeFolders)
        let existing = snapshots(in: destination)
        if let latest = existing.first, (try? manifest(at: latest.url))?.digest == currentDigest {
            // 摘要相同不代表快照仍可恢复：逐个文件核验后才允许跳过。
            if latestSnapshotIsUsable(latest.url) {
                report.skippedUnchanged = true
                report.removedSnapshots = try applyRetention(root: root, now: now)
                return report
            }
            report.quarantinedSnapshots.append(try quarantine(latest, in: root))
        }

        var name = nameFormatter.string(from: now)
        var suffix = 2
        while fileManager.fileExists(atPath: root.appendingPathComponent(name).path) { name = nameFormatter.string(from: now) + "-\(suffix)"; suffix += 1 }
        let partial = root.appendingPathComponent(".\(name).partial", isDirectory: true)
        try? fileManager.removeItem(at: partial)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        for folder in safeFolders {
            try fileManager.createDirectory(at: partial.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        for item in included {
            let target = partial.appendingPathComponent(item.path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(item.text.utf8).write(to: target, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let record = Manifest(version: manifestVersion, created: now, digest: currentDigest, notes: noteRecords,
                              attachments: attachmentRecords, folders: safeFolders)
        // manifest 最后写入，随后整体改名为正式快照；中断只会留下可识别的 partial 目录。
        try encoder.encode(record).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
        try fileManager.moveItem(at: partial, to: root.appendingPathComponent(name, isDirectory: true))
        report.snapshotName = name
        report.removedSnapshots = try applyRetention(root: root, now: now)
        return report
    }

    /// 云端占位文件无法当场核验，但写入时已校验，不视为损坏；其余校验失败均视为不可用。
    private static func latestSnapshotIsUsable(_ snapshot: URL) -> Bool {
        do {
            _ = try verify(snapshot: snapshot)
            return true
        } catch RestoreError.notDownloaded {
            return true
        } catch {
            return false
        }
    }

    /// 只改名、不删除：用户仍可在 Finder 中查看，名称不再符合快照格式，因此不会被列出或参与保留清理。
    private static func quarantine(_ snapshot: Snapshot, in root: URL) throws -> String {
        var target = root.appendingPathComponent(".\(snapshot.name).damaged", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = root.appendingPathComponent(".\(snapshot.name).damaged-\(suffix)", isDirectory: true); suffix += 1
        }
        try FileManager.default.moveItem(at: snapshot.url, to: target)
        return snapshot.name
    }

    static func manifest(at snapshot: URL) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: snapshot.appendingPathComponent("manifest.json")))
    }

    /// 只认名称合规且 manifest 可解析的目录，最新在前。
    static func snapshots(in destination: URL) -> [Snapshot] {
        let root = destination.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> Snapshot? in
            guard let date = snapshotDate(name) else { return nil }
            let url = root.appendingPathComponent(name, isDirectory: true)
            if let manifest = try? manifest(at: url) {
                return Snapshot(name: name, url: url, created: date, noteCount: manifest.notes.count)
            }
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard CloudFiles.isPlaceholder(manifestURL) else { return nil }
            CloudFiles.requestDownload(manifestURL)
            return Snapshot(name: name, url: url, created: date, noteCount: 0, available: false)
        }.sorted { $0.name > $1.name }
    }

    /// 保留最近 keepRecent 份；更早的每天只留最后一份，超过 keepDailyDays 天的全部移除。
    static func expiredSnapshots(_ names: [String], now: Date, calendar: Calendar = .current) -> [String] {
        let ordered = names.filter { snapshotDate($0) != nil }.sorted(by: >)
        guard ordered.count > keepRecent else { return [] }
        let cutoff = calendar.date(byAdding: .day, value: -keepDailyDays, to: now) ?? now
        var keptDays = Set<String>()
        var expired: [String] = []
        for name in ordered.dropFirst(keepRecent) {
            let day = String(name.prefix(10))
            if let date = snapshotDate(name), date >= cutoff, !keptDays.contains(day) { keptDays.insert(day) }
            else { expired.append(name) }
        }
        return expired
    }

    private static func applyRetention(root: URL, now: Date) throws -> [String] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        // 清理本应用此前中断留下、超过一小时的 partial 目录。
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            let url = root.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 3600 { try? fileManager.removeItem(at: url) }
        }
        let valid = names.filter { name in
            snapshotDate(name) != nil && (try? manifest(at: root.appendingPathComponent(name))) != nil
        }
        let expired = expiredSnapshots(valid, now: now)
        for name in expired { try fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true)) }
        return expired
    }
}
