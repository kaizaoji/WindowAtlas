import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一个备份目的地：云盘同步目录、本地磁盘或移动硬盘均可，各自独立开关自动备份。
struct BackupTarget: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var auto = false
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var displayName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// 备份、恢复与导出导入。与 NotesStore 分开，备份进度变化不会触发笔记编辑区重绘。
@MainActor
final class BackupCenter: ObservableObject {
    @Published private(set) var targets: [BackupTarget] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(data, forKey: "notesBackupTargets") }
            scheduleTimer()
        }
    }
    @Published private(set) var reports: [UUID: NotesBackup.Report] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var running: Set<UUID> = []
    @Published var browsingTarget: UUID?
    @Published private(set) var snapshots: [NotesBackup.Snapshot] = []
    @Published private(set) var cloud = CloudLocations.detect()
    @Published private(set) var busyText: String?
    @Published var notice: String?
    @Published private(set) var lastRestoreCopy: URL?

    let notes: NotesStore
    private var timer: Timer?

    init(notes: NotesStore) {
        self.notes = notes
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "notesBackupTargets"), let saved = try? JSONDecoder().decode([BackupTarget].self, from: data) {
            targets = saved
        } else if let legacy = defaults.string(forKey: "notesBackupFolder") {
            // 0.6.0 只有单一备份目录，升级后迁移为第一个目的地并保留自动备份设置。
            targets = [BackupTarget(path: legacy, auto: defaults.bool(forKey: "notesAutoBackup"))]
        }
        browsingTarget = targets.first?.id
        scheduleTimer()
    }

    // MARK: 目的地

    func refreshCloudLocations() { cloud = CloudLocations.detect() }

    func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("添加为备份位置")
        panel.message = String(format: L("可选云盘同步目录（Google Drive、iCloud 云盘）、本地文件夹或移动硬盘。将在其中创建「%@」文件夹。"), String(describing: NotesBackup.folderName))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addTarget(url)
    }

    func addTarget(_ url: URL) {
        guard let library = notes.library else { return }
        if let reason = NotesBackup.validate(destination: url, libraryRoot: library.root) { notice = reason; return }
        let path = url.standardizedFileURL.path
        guard !targets.contains(where: { $0.path == path }) else { notice = L("该位置已在备份列表中。"); return }
        targets.append(BackupTarget(path: path))
        browsingTarget = targets.last?.id
        notice = nil
        refreshSnapshots()
    }

    /// 只从列表移除，不删除目的地里已有的快照。
    func removeTarget(_ id: UUID) {
        targets.removeAll { $0.id == id }
        reports.removeValue(forKey: id)
        errors.removeValue(forKey: id)
        if browsingTarget == id { browsingTarget = targets.first?.id; refreshSnapshots() }
    }

    func setAuto(_ id: UUID, _ value: Bool) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[index].auto = value
    }

    // MARK: 备份

    func backup(_ id: UUID) {
        guard let library = notes.library, let target = targets.first(where: { $0.id == id }), !running.contains(id) else { return }
        guard let content = notes.snapshotItems() else {
            errors[id] = L("备份已停止：笔记尚未保存成功，请解决保存问题后重试。")
            return
        }
        running.insert(id)
        errors.removeValue(forKey: id)
        let attachments = library.attachmentsDirectory, root = library.root, destination = target.url
        Task {
            let result = await Task.detached { () -> Result<NotesBackup.Report, Error> in
                Result { try NotesBackup.run(items: content.items, folders: content.folders, attachmentsDirectory: attachments,
                                             libraryRoot: root, destination: destination) }
            }.value
            running.remove(id)
            switch result {
            case .success(let report): reports[id] = report
            case .failure(let error): errors[id] = String(format: L("备份失败：%@"), String(describing: error.localizedDescription))
            }
            if browsingTarget == id { refreshSnapshots() }
        }
    }

    func backupAll(autoOnly: Bool) {
        for target in targets where !autoOnly || target.auto { backup(target.id) }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard targets.contains(where: \.auto) else { return }
        // 每 10 分钟检查一次；内容与上一份快照一致时备份引擎直接跳过，不产生重复快照。
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backupAll(autoOnly: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshSnapshots() {
        guard let target = targets.first(where: { $0.id == browsingTarget }) else { snapshots = []; return }
        let folder = target.url
        Task {
            let found = await Task.detached { NotesBackup.snapshots(in: folder) }.value
            snapshots = found
        }
    }

    // MARK: 恢复

    func restore(_ snapshot: NotesBackup.Snapshot) {
        let url = snapshot.url
        verifyThenRestore(title: String(format: L("从 %@ 的快照恢复？"), String(describing: snapshot.created.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppPreferences.shared.locale))))) {
            (try NotesBackup.verify(snapshot: url), nil)
        }
    }

    /// 校验在后台进行；确认后才写入本地，写入前自动保存一份恢复前副本，失败自动回滚。
    private func verifyThenRestore(title: String, _ load: @escaping @Sendable () throws -> (VerifiedSnapshot, URL?)) {
        guard let library = notes.library, busyText == nil else { return }
        guard !notes.readOnly else { notice = NotesLibrary.LibraryError.readOnly.localizedDescription; return }
        guard saveBeforeRestore() else { return }
        busyText = L("正在校验备份…")
        notice = nil
        Task {
            let result = await Task.detached { Result { try load() } }.value
            busyText = nil
            switch result {
            case .failure(let error):
                notice = error.localizedDescription
                refreshSnapshots()
            case .success(let (verified, cleanup)):
                defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
                // 后台校验期间仍能编辑，确认展示前和真正覆盖前都要保存最新内容。
                guard saveBeforeRestore() else { return }
                let plan = library.restorePlan(for: verified)
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = String(format: L("将覆盖 %@ 篇同一笔记、新增 %@ 篇；备份中没有的 %@ 篇本地笔记（含敏感笔记）保留不动。\n\n恢复前会自动把当前笔记库复制到本地「恢复前备份」，可随时找回。"), String(describing: plan.overwritten), String(describing: plan.added), String(describing: plan.keptLocal))
                alert.addButton(withTitle: L("恢复"))
                alert.addButton(withTitle: L("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard saveBeforeRestore() else { return }
                do {
                    let report = try library.restore(verified)
                    notes.reload()
                    lastRestoreCopy = report.safetyCopy
                    notice = String(format: L("已恢复：覆盖 %@ 篇，新增 %@ 篇。恢复前的笔记已保存在本地「恢复前备份」。"), String(describing: report.plan.overwritten), String(describing: report.plan.added))
                } catch let failure as RestoreFailure {
                    notes.reload()
                    lastRestoreCopy = failure.safetyCopy
                    notice = failure.localizedDescription
                } catch {
                    // 写入阶段之前失败（准备恢复前副本、路径校验等），本地笔记未被改动。
                    notes.reload()
                    notice = String(format: L("恢复未执行，本地笔记未改动：%@"), String(describing: error.localizedDescription))
                }
            }
        }
    }

    private func saveBeforeRestore() -> Bool {
        guard notes.flush() else {
            notice = L("恢复已停止：笔记尚未保存成功，当前编辑仍保留，请解决保存问题后重试。")
            return false
        }
        return true
    }

    // MARK: 导出与导入（换电脑迁移）

    func exportArchive() {
        guard let library = notes.library, busyText == nil else { return }
        guard let content = notes.snapshotItems() else {
            notice = L("导出已停止：笔记尚未保存成功，请解决保存问题后重试。")
            return
        }
        let sensitiveCount = content.items.filter(\.sensitive).count
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = String(format: L("WindowAtlas 笔记导出 %@.zip"), String(describing: formatter.string(from: Date())))
        panel.message = L("导出全部笔记、目录结构和图片，可在另一台电脑的窗口图鉴中导入。")
        let checkbox = NSButton(checkboxWithTitle: String(format: L("包含标记为敏感的笔记（%@ 篇）"), String(describing: sensitiveCount)), target: nil, action: nil)
        checkbox.state = .off
        checkbox.isEnabled = sensitiveCount > 0
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 36))
        checkbox.frame = NSRect(x: 16, y: 8, width: 340, height: 20)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let includeSensitive = checkbox.state == .on
        busyText = L("正在导出…")
        notice = nil
        let attachments = library.attachmentsDirectory, root = library.root
        Task {
            let result = await Task.detached { () -> Result<NotesBackup.Report, Error> in
                Result { try NotesArchive.export(items: content.items, folders: content.folders, attachmentsDirectory: attachments,
                                                 libraryRoot: root, to: output, includeSensitive: includeSensitive) }
            }.value
            busyText = nil
            switch result {
            case .success(let report):
                let skipped = report.excludedSensitive > 0 ? String(format: L("，未包含 %@ 篇敏感笔记"), String(describing: report.excludedSensitive)) : ""
                notice = String(format: L("已导出 %@ 篇笔记到「%@」%@。"), String(describing: report.noteCount), String(describing: output.lastPathComponent), String(describing: skipped))
                NSWorkspace.shared.activateFileViewerSelecting([output])
            case .failure(let error):
                notice = String(format: L("导出失败：%@"), String(describing: error.localizedDescription))
            }
        }
    }

    func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = L("导入")
        panel.message = String(format: L("选择导出的 .zip 文件，或云盘中的「%@」文件夹 / 其中某个快照。导入按笔记合并，不删除本机已有笔记。"), String(describing: NotesBackup.folderName))
        guard panel.runModal() == .OK, let source = panel.url else { return }
        verifyThenRestore(title: String(format: L("从「%@」导入？"), String(describing: source.lastPathComponent))) {
            let located = try NotesArchive.locateSnapshot(in: source)
            do {
                return (try NotesBackup.verify(snapshot: located.snapshot), located.cleanup)
            } catch {
                if let cleanup = located.cleanup { try? FileManager.default.removeItem(at: cleanup) }
                throw error
            }
        }
    }
}

/// 导出 zip 与导入定位。压缩/解压使用系统自带的 /usr/bin/ditto，不引入第三方依赖。
enum NotesArchive {
    enum ArchiveError: LocalizedError {
        case toolFailed(String), unsafeEntry(String), notFound
        var errorDescription: String? {
            switch self {
            case .toolFailed(let detail): return String(format: L("系统压缩工具执行失败（%@）。"), String(describing: detail))
            case .unsafeEntry(let entry): return String(format: L("压缩包包含越界路径「%@」，已拒绝导入。"), String(describing: entry))
            case .notFound: return L("没有找到窗口图鉴的笔记备份（缺少 manifest.json）。")
            }
        }
    }

    /// 复用快照格式：导出包解压后就是一个可校验的「WindowAtlas 笔记备份」目录。
    static func export(items: [NotesBackup.Item], folders: [String], attachmentsDirectory: URL, libraryRoot: URL,
                       to output: URL, includeSensitive: Bool) throws -> NotesBackup.Report {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("windowatlas-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let report = try NotesBackup.run(items: items, folders: folders, attachmentsDirectory: attachmentsDirectory,
                                         libraryRoot: libraryRoot, destination: staging, includeSensitive: includeSensitive)
        let zip = staging.appendingPathComponent("export.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                   staging.appendingPathComponent(NotesBackup.folderName).path, zip.path])
        if fileManager.fileExists(atPath: output.path) { try fileManager.removeItem(at: output) }
        try fileManager.moveItem(at: zip, to: output)
        return report
    }

    /// 返回要校验的快照目录；cleanup 为解压用的临时目录，用完由调用方删除。
    static func locateSnapshot(in source: URL) throws -> (snapshot: URL, cleanup: URL?) {
        if source.pathExtension.lowercased() == "zip" {
            let fileManager = FileManager.default
            // 解压前逐条检查条目路径，拒绝绝对路径与 ..，防止写到临时目录之外。
            let listing = try run("/usr/bin/zipinfo", ["-1", source.path])
            for entry in listing.split(separator: "\n").map(String.init) where !entry.isEmpty {
                if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") || entry.contains("\\") { throw ArchiveError.unsafeEntry(entry) }
            }
            let temp = fileManager.temporaryDirectory.appendingPathComponent("windowatlas-import-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
            do {
                try run("/usr/bin/ditto", ["-x", "-k", source.path, temp.path])
                return (try newestSnapshot(in: temp), temp)
            } catch {
                try? fileManager.removeItem(at: temp)
                throw error
            }
        }
        return (try newestSnapshot(in: source), nil)
    }

    /// 支持三种选择：快照目录本身、「WindowAtlas 笔记备份」目录、或其上一级目录；取最新的快照。
    static func newestSnapshot(in directory: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        let parent = directory.lastPathComponent == NotesBackup.folderName ? directory.deletingLastPathComponent() : directory
        guard let newest = NotesBackup.snapshots(in: parent).first(where: \.available) else { throw ArchiveError.notFound }
        return newest.url
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.toolFailed(detail.isEmpty ? String(format: L("退出码 %@"), String(describing: process.terminationStatus)) : String(detail.prefix(200)))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
