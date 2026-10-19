import Foundation

/// 本机云盘同步目录识别。只列出目录，不读取其中的用户文件。
enum CloudLocations {
    struct Location: Identifiable, Equatable {
        let name: String
        let url: URL
        var id: String { url.path }
    }

    struct Detection: Equatable {
        var locations: [Location]
        var iCloudAvailable: Bool
    }

    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Detection {
        let fileManager = FileManager.default
        var locations: [Location] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let iCloudAvailable = fileManager.fileExists(atPath: iCloud.path)
        if iCloudAvailable { locations.append(Location(name: L("iCloud 云盘"), url: iCloud)) }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let providers = ((try? fileManager.contentsOfDirectory(atPath: storage.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for folder in providers {
            let base = storage.appendingPathComponent(folder, isDirectory: true)
            let provider = String(folder.split(separator: "-", maxSplits: 1).first ?? Substring(folder))
            let account = folder.contains("-") ? String(folder.split(separator: "-", maxSplits: 1)[1]) : ""
            // Google Drive 根目录只读，可写的是「我的云端硬盘 / My Drive」。
            let candidates = ["我的云端硬盘", "My Drive"].map { base.appendingPathComponent($0, isDirectory: true) } + [base]
            guard let writable = candidates.first(where: { fileManager.isWritableFile(atPath: $0.path) }) else { continue }
            let label = provider == "GoogleDrive" ? "Google Drive" : provider
            locations.append(Location(name: account.isEmpty ? label : "\(label)（\(account)）", url: writable))
        }
        return Detection(locations: locations, iCloudAvailable: iCloudAvailable)
    }
}

/// 云盘「优化存储」会把文件换成占位符；读取前识别并请求下载，避免误判为损坏。
enum CloudFiles {
    static func placeholderURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        !FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: placeholderURL(url).path)
    }

    static func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

struct VerifiedSnapshot {
    struct NoteFile { let path: String; let note: NoteDocument; let data: Data }
    let name: String
    let notes: [NoteFile]
    var folders: [String] = []
    let attachments: [(name: String, data: Data)]
}

enum RestoreError: LocalizedError, Equatable {
    case notDownloaded(Int)
    case damaged(String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let count): return String(format: L("快照还有 %@ 个文件未下载到本机，已请求云盘下载，请稍后再试。本地笔记未改动。"), String(describing: count))
        case .damaged(let detail): return String(format: L("快照不完整或已损坏（%@），已拒绝恢复。本地笔记未改动。"), String(describing: detail))
        case .unsupportedVersion(let version): return String(format: L("快照格式版本 %@ 高于本应用支持的版本，请先更新窗口图鉴。"), String(describing: version))
        }
    }
}

/// 恢复写入阶段失败：区分是否已确认回滚到恢复前状态，界面据此如实提示。
struct RestoreFailure: LocalizedError {
    let underlying: Error
    let rolledBack: Bool
    let safetyCopy: URL

    var errorDescription: String? {
        rolledBack
            ? String(format: L("恢复失败，已回滚到恢复前状态：%@"), underlying.localizedDescription)
            : String(format: L("恢复失败，且未能确认回滚完成。恢复前的笔记完整保存在「%@」，请先不要继续编辑笔记，按安装说明中的步骤手动复原。原因：%@"), safetyCopy.path, underlying.localizedDescription)
    }
}

/// 逐层拒绝链接，连不存在目标的上级目录也检查，避免读取或写入库外路径。
private enum RestorePaths {
    static func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw RestoreError.damaged(L("无法确认恢复文件标识"))
        }
        return "\(volume):\(inode)"
    }

    static func validate(_ target: URL, beneath root: URL) throws {
        let base = root.standardizedFileURL
        let destination = target.standardizedFileURL
        guard destination.path == base.path || destination.path.hasPrefix(base.path + "/") else {
            throw RestoreError.damaged(L("路径越界"))
        }
        var current = base
        let components = destination.pathComponents.dropFirst(base.pathComponents.count)
        for component in [""] + Array(components) {
            if !component.isEmpty { current.appendPathComponent(component) }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw RestoreError.damaged(L("路径包含符号链接"))
            }
        }
    }
}

extension NotesBackup {
    /// 恢复前完整校验：版本、文件名安全、大小与 SHA-256、附件是否齐全。任何一项不符都不写入本地。
    static func verify(snapshot: URL) throws -> VerifiedSnapshot {
        let manifestURL = snapshot.appendingPathComponent("manifest.json")
        try RestorePaths.validate(manifestURL, beneath: snapshot.deletingLastPathComponent())
        if CloudFiles.isPlaceholder(manifestURL) { CloudFiles.requestDownload(manifestURL); throw RestoreError.notDownloaded(1) }
        guard let record = try? manifest(at: snapshot) else { throw RestoreError.damaged(L("manifest 无法读取")) }
        guard record.version <= manifestVersion else { throw RestoreError.unsupportedVersion(record.version) }
        let sharedAttachments = snapshot.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
        try RestorePaths.validate(sharedAttachments, beneath: snapshot.deletingLastPathComponent())
        guard Set(record.notes.map(\.file)).count == record.notes.count,
              Set(record.attachments.map(\.file)).count == record.attachments.count else {
            throw RestoreError.damaged(L("文件路径重复"))
        }
        var pending = 0
        func load(_ url: URL, expected: Manifest.FileRecord) throws -> Data? {
            try RestorePaths.validate(url, beneath: snapshot.deletingLastPathComponent())
            if CloudFiles.isPlaceholder(url) { CloudFiles.requestDownload(url); pending += 1; return nil }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { throw RestoreError.damaged(String(format: L("缺少 %@"), String(describing: expected.file))) }
            let data = try Data(contentsOf: url)
            guard data.count == expected.size, sha256(data) == expected.sha256 else { throw RestoreError.damaged(String(format: L("%@ 校验不符"), String(describing: expected.file))) }
            return data
        }
        var notes: [VerifiedSnapshot.NoteFile] = []
        for entry in record.notes {
            guard isSafeNotePath(entry.file) else { throw RestoreError.damaged(String(format: L("非法路径 %@"), String(describing: entry.file))) }
            guard let data = try load(snapshot.appendingPathComponent(entry.file), expected: entry) else { continue }
            guard let note = NoteFormat.decode(String(decoding: data, as: UTF8.self)) else { throw RestoreError.damaged(String(format: L("%@ 无法解析"), String(describing: entry.file))) }
            notes.append(.init(path: entry.file, note: note, data: data))
        }
        var attachments: [(name: String, data: Data)] = []
        for entry in record.attachments {
            guard NoteAttachments.isValidName(entry.file) else { throw RestoreError.damaged(String(format: L("非法附件名 %@"), String(describing: entry.file))) }
            guard let data = try load(sharedAttachments.appendingPathComponent(entry.file), expected: entry) else { continue }
            attachments.append((entry.file, data))
        }
        if pending > 0 { throw RestoreError.notDownloaded(pending) }
        let referenced = notes.reduce(into: Set<String>()) { $0.formUnion(NoteAttachments.referencedNames(in: $1.note.body)) }
        guard referenced.isSubset(of: Set(attachments.map(\.name))) else {
            throw RestoreError.damaged(L("正文引用的附件缺失"))
        }
        guard Set(notes.map(\.note.id)).count == notes.count else { throw RestoreError.damaged(L("笔记 ID 重复")) }
        let folders = record.folders ?? []
        guard folders.allSatisfy(NotesLibrary.isSafeRelativePath) else { throw RestoreError.damaged(L("非法目录")) }
        return VerifiedSnapshot(name: snapshot.lastPathComponent, notes: notes, folders: folders, attachments: attachments)
    }

    static func isSafeNotePath(_ path: String) -> Bool {
        path.hasSuffix(".md") && NotesLibrary.isSafeRelativePath(path)
    }
}

extension NotesLibrary {
    struct RestorePlan: Equatable { let overwritten: Int; let added: Int; let keptLocal: Int }
    struct RestoreReport: Equatable { let plan: RestorePlan; let safetyCopy: URL }

    var restoreBackupsDirectory: URL { root.appendingPathComponent("restore-backups", isDirectory: true) }

    func restorePlan(for snapshot: VerifiedSnapshot) -> RestorePlan {
        let localIDs = Set(loadAll().map(\.note.id))
        let snapshotIDs = Set(snapshot.notes.map(\.note.id))
        return RestorePlan(overwritten: localIDs.intersection(snapshotIDs).count, added: snapshotIDs.subtracting(localIDs).count,
                           keptLocal: localIDs.subtracting(snapshotIDs).count)
    }

    /// 按笔记 ID 合并：快照中的笔记覆盖本地同 ID 笔记或新增；快照里没有的本地笔记（含敏感笔记）保留。
    /// 写入前先把当前 notes 整体复制到 restore-backups，任一步失败自动回滚。
    func restore(_ snapshot: VerifiedSnapshot, now: Date = Date()) throws -> RestoreReport {
        guard !readOnly else { throw LibraryError.readOnly }
        let fileManager = FileManager.default
        let plan = restorePlan(for: snapshot)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        var safety = restoreBackupsDirectory.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: safety.path) {
            safety = restoreBackupsDirectory.appendingPathComponent(formatter.string(from: now) + "-\(suffix)", isDirectory: true); suffix += 1
        }
        let targets = try restoreTargets(for: snapshot)
        try RestorePaths.validate(safety, beneath: root)
        try fileManager.createDirectory(at: safety, withIntermediateDirectories: true)
        try fileManager.copyItem(at: notesDirectory, to: safety.appendingPathComponent("notes", isDirectory: true))

        let local = loadAll()
        let fileByID = Dictionary(local.map { ($0.note.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        do {
            for folder in targets.folders {
                try fileManager.createDirectory(at: url(folder), withIntermediateDirectories: true)
            }
            for (file, target) in targets.notes {
                try RestorePaths.validate(url(target), beneath: root)
                try fileManager.createDirectory(at: url(Self.parent(of: target)), withIntermediateDirectories: true)
                try file.data.write(to: url(target), options: .atomic)
            }
            // 所有目标写好才移除同 ID 的旧路径，避免路径交换时删除刚恢复的笔记。
            let writtenPaths = Set(targets.notes.map { $0.1 })
            // 文件标识区分真实旧文件与大小写/Unicode 路径别名，避免删掉刚写好的目标。
            let writtenFiles = Set(try targets.notes.map { try RestorePaths.fileIdentity(url($0.1)) })
            for (file, target) in targets.notes {
                if let old = fileByID[file.note.id], old != target, !writtenPaths.contains(old),
                   fileManager.fileExists(atPath: url(old).path) {
                    try RestorePaths.validate(url(old), beneath: root)
                    if writtenFiles.contains(try RestorePaths.fileIdentity(url(old))) { continue }
                    try fileManager.removeItem(at: url(old))
                }
            }
            for attachment in snapshot.attachments {
                let url = attachmentsDirectory.appendingPathComponent(attachment.name)
                try RestorePaths.validate(url, beneath: root)
                // 本地同名附件可能已损坏：文件名即内容哈希，不一致时用快照中的正确内容修复。
                if (try? Data(contentsOf: url)).map(sha256) != sha256(attachment.data) {
                    try attachment.data.write(to: url, options: .atomic)
                }
            }
        } catch {
            throw RestoreFailure(underlying: error, rolledBack: rollback(from: safety), safetyCopy: safety)
        }
        pruneRestoreBackups(keep: 10)
        return RestoreReport(plan: plan, safetyCopy: safety)
    }

    private func restoreTargets(for snapshot: VerifiedSnapshot) throws -> (notes: [(VerifiedSnapshot.NoteFile, String)], folders: [String]) {
        try RestorePaths.validate(notesDirectory, beneath: root)
        try RestorePaths.validate(attachmentsDirectory, beneath: root)
        guard Set(snapshot.notes.map(\.path)).count == snapshot.notes.count,
              Set(snapshot.notes.map(\.note.id)).count == snapshot.notes.count else {
            throw RestoreError.damaged(L("笔记路径或 ID 重复"))
        }
        // macOS 常用大小写不敏感卷；同批尚未落盘的名字也按规范化键预留。
        func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        var owners = loadAll().reduce(into: [String: Set<String>]()) { result, entry in
            result[pathKey(entry.path), default: []].insert(entry.note.id)
        }
        var containers: [String: String] = [:]
        var targets: [(VerifiedSnapshot.NoteFile, String)] = []
        func mapped(_ path: String) -> String {
            guard let prefix = containers.keys.filter({ path == $0 || path.hasPrefix($0 + "/") })
                .max(by: { $0.count < $1.count }) else { return path }
            return containers[prefix]! + String(path.dropFirst(prefix.count))
        }
        for file in snapshot.notes.sorted(by: { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }) {
            guard NotesBackup.isSafeNotePath(file.path) else { throw RestoreError.damaged(L("非法笔记路径")) }
            let proposed = mapped(file.path)
            var target = proposed
            var suffix = 1
            // 同 ID 才允许覆盖；未知文件、目录与已分配目标也必须保留。
            func occupied(_ candidate: String) -> Bool {
                if let existingOwners = owners[pathKey(candidate)] { return existingOwners.contains { $0 != file.note.id } }
                return FileManager.default.fileExists(atPath: url(candidate).path)
                    || FileManager.default.fileExists(atPath: url(Self.childrenContainer(ofNote: candidate)).path)
            }
            while occupied(target) {
                target = String(proposed.dropLast(3)) + "-恢复" + (suffix == 1 ? "" : "-\(suffix)") + ".md"
                suffix += 1
            }
            try RestorePaths.validate(url(target), beneath: root)
            let originalContainer = Self.childrenContainer(ofNote: file.path)
            let targetContainer = Self.childrenContainer(ofNote: target)
            containers[originalContainer] = targetContainer
            owners[pathKey(target), default: []].insert(file.note.id)
            targets.append((file, target))
        }
        let folders = try snapshot.folders.map { folder -> String in
            guard Self.isSafeRelativePath(folder) else { throw RestoreError.damaged(L("非法目录")) }
            let target = mapped(folder)
            try RestorePaths.validate(url(target), beneath: root)
            return target
        }
        for attachment in snapshot.attachments {
            guard NoteAttachments.isValidName(attachment.name) else { throw RestoreError.damaged(L("非法附件名")) }
            try RestorePaths.validate(attachmentsDirectory.appendingPathComponent(attachment.name), beneath: root)
        }
        return (targets, folders)
    }

    /// 用恢复前副本整体替换 notes 目录内容（含子目录）；附件只增不删或按哈希修复，无需回滚。
    /// 返回 true 仅当每一步都成功，且回滚后的内容与恢复前副本逐文件一致。
    private func rollback(from safety: URL) -> Bool {
        let fileManager = FileManager.default
        let saved = safety.appendingPathComponent("notes", isDirectory: true)
        var succeeded = true
        do {
            for name in try fileManager.contentsOfDirectory(atPath: notesDirectory.path) {
                do { try fileManager.removeItem(at: notesDirectory.appendingPathComponent(name)) } catch { succeeded = false }
            }
            for name in try fileManager.contentsOfDirectory(atPath: saved.path) {
                do { try fileManager.copyItem(at: saved.appendingPathComponent(name), to: notesDirectory.appendingPathComponent(name)) } catch { succeeded = false }
            }
        } catch {
            succeeded = false
        }
        guard succeeded, let current = Self.contentDigest(notesDirectory), let expected = Self.contentDigest(saved) else { return false }
        return current == expected
    }

    /// 目录内所有普通文件的相对路径 → SHA-256；任一文件无法读取时返回 nil。
    static func contentDigest(_ directory: URL) -> [String: String]? {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        var result: [String: String] = [:]
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: item) else { return nil }
            let full = item.resolvingSymlinksInPath().standardizedFileURL.path
            result[String(full.dropFirst(base.count + 1))] = sha256(data)
        }
        return result
    }

    private func pruneRestoreBackups(keep: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: restoreBackupsDirectory.path)) ?? [])
            .filter { NotesBackup.snapshotDate($0) != nil }.sorted(by: >)
        for name in names.dropFirst(keep) { try? FileManager.default.removeItem(at: restoreBackupsDirectory.appendingPathComponent(name)) }
    }
}
