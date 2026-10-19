import Foundation
import Combine
import Darwin

struct CommandEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var tool: String
    var command: String
    var purpose = ""
    var example = ""
    var notes = ""
    var sourceURL: URL?
    var favorite = false
    var useCount = 0
    var lastUsed: Date?
    var created = Date()
    var updated = Date()
    var archived = false
}

private struct CommandLibraryDocument: Codable {
    let version: Int
    let entries: [CommandEntry]
}

/// 命令库独立存储；先持久化候选状态，再发布内存变化，避免失败后界面显示虚假成功。
@MainActor
final class CommandLibraryStore: ObservableObject {
    @Published private(set) var entries: [CommandEntry] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReadOnly = false
    @Published private(set) var isEditing = false
    let root: URL
    var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var lastSavedData: Data?
    private var writerLock: CommandLibraryWriterLock?

    init(root: URL? = nil, seeds: [CommandEntry] = []) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowAtlas/Commands", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            acquireWriterLock()
            if try libraryExists() {
                try load()
            } else if !isReadOnly {
                // 仅首次建库写入模板，后续版本不覆盖用户编辑或归档状态。
                guard valid(seeds) else { throw LibraryError.invalidContents }
                try write(seeds)
                entries = seeds
            }
        } catch {
            isReadOnly = true
            errorMessage = L("命令库无法读取，已暂停写入。请保留原文件并检查存储位置。")
        }
    }

    private func acquireWriterLock() {
        do {
            writerLock = try CommandLibraryWriterLock(url: root.appendingPathComponent(".library.lock"))
        } catch {
            isReadOnly = true
            errorMessage = L("命令库暂不可写，可能正由另一实例使用。仍可查看；关闭其他实例后重新打开应用。")
        }
    }

    private func libraryExists() throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: libraryURL.path)
            return true
        } catch {
            let failure = error as NSError
            // 只有明确的不存在才允许建库；权限或其他读取错误不得当成空库。
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return false }
            throw error
        }
    }

    var tools: [String] {
        Array(Set(entries.filter { !$0.archived }.map(\.tool))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func filtered(query: String = "", tool: String? = nil, includeArchived: Bool = false) -> [CommandEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (includeArchived || !entry.archived) && (tool == nil || entry.tool == tool) &&
            (search.isEmpty || [entry.title, entry.tool, entry.purpose, entry.command, entry.example, entry.notes]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { first, second in
            if first.favorite != second.favorite { return first.favorite }
            if first.useCount != second.useCount { return first.useCount > second.useCount }
            if first.lastUsed != second.lastUsed { return (first.lastUsed ?? .distantPast) > (second.lastUsed ?? .distantPast) }
            let titleOrder = first.title.localizedStandardCompare(second.title)
            return titleOrder == .orderedSame ? first.id.uuidString < second.id.uuidString : titleOrder == .orderedAscending
        }
    }

    @discardableResult
    func save(_ entry: CommandEntry) -> Bool {
        var candidate = entry
        candidate.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.tool = entry.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.updated = Date()
        var next = entries
        if let index = next.firstIndex(where: { $0.id == entry.id }) {
            candidate.created = next[index].created
            // 编辑草稿可能打开较久，保留这期间新增的使用计数与收藏状态。
            candidate.useCount = next[index].useCount
            candidate.lastUsed = next[index].lastUsed
            candidate.favorite = next[index].favorite
            candidate.archived = next[index].archived
            next[index] = candidate
        } else {
            next.append(candidate)
        }
        return commit(next)
    }

    @discardableResult
    func toggleFavorite(_ id: UUID) -> Bool { change(id) { $0.favorite.toggle() } }

    @discardableResult
    func recordUse(_ id: UUID) -> Bool {
        change(id) {
            $0.useCount = $0.useCount == Int.max ? Int.max : $0.useCount + 1
            $0.lastUsed = Date()
        }
    }

    @discardableResult
    func archive(_ id: UUID) -> Bool { change(id) { $0.archived = true } }

    @discardableResult
    func restore(_ id: UUID) -> Bool { change(id) { $0.archived = false } }

    func beginEditing() { isEditing = true }
    func endEditing() {
        isEditing = false
        if errorMessage == L("请先保存或取消命令编辑，再切换语言或退出应用。") { errorMessage = nil }
    }

    func canLeaveEditor() -> Bool {
        guard !isEditing else {
            errorMessage = L("请先保存或取消命令编辑，再切换语言或退出应用。")
            return false
        }
        return true
    }

    func dismissError() { errorMessage = nil }

    private func change(_ id: UUID, mutation: (inout CommandEntry) -> Void) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            errorMessage = L("未找到这条命令，请重新选择。")
            return false
        }
        var next = entries
        mutation(&next[index])
        next[index].updated = Date()
        return commit(next)
    }

    private func commit(_ next: [CommandEntry]) -> Bool {
        guard !isReadOnly else {
            errorMessage = L("命令库处于只读保护状态，请检查原文件后重新打开应用。")
            return false
        }
        guard valid(next) else {
            errorMessage = L("请填写标题、工具与命令，来源链接仅支持 http 或 https。")
            return false
        }
        do {
            try ensureUnchanged()
            try write(next)
            entries = next
            errorMessage = nil
            return true
        } catch LibraryError.externalChange {
            isReadOnly = true
            errorMessage = L("命令库文件已被外部修改，已暂停写入。请重新打开应用后再试。")
        } catch {
            errorMessage = L("命令未保存，原内容已保留。请检查磁盘空间和目录权限后重试。")
        }
        return false
    }

    private func valid(_ values: [CommandEntry]) -> Bool {
        Set(values.map(\.id)).count == values.count && values.allSatisfy { entry in
            !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !entry.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.useCount >= 0 &&
            (entry.sourceURL == nil || (["https", "http"].contains(entry.sourceURL?.scheme?.lowercased() ?? "") && entry.sourceURL?.host != nil))
        }
    }

    private func load() throws {
        guard try FileManager.default.attributesOfItem(atPath: libraryURL.path)[.type] as? FileAttributeType == .typeRegular else {
            throw LibraryError.invalidContents
        }
        let content = try Data(contentsOf: libraryURL)
        let document = try JSONDecoder().decode(CommandLibraryDocument.self, from: content)
        guard document.version == 1, valid(document.entries) else { throw LibraryError.invalidContents }
        entries = document.entries
        lastSavedData = content
    }

    private func ensureUnchanged() throws {
        guard try FileManager.default.attributesOfItem(atPath: libraryURL.path)[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: libraryURL) == lastSavedData else { throw LibraryError.externalChange }
    }

    private func write(_ values: [CommandEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let content = try encoder.encode(CommandLibraryDocument(version: 1, entries: values))
        try content.write(to: libraryURL, options: .atomic)
        lastSavedData = content
    }

    private enum LibraryError: Error { case invalidContents, externalChange }
}

/// 锁文件不参与原子替换且不删除，保证各进程锁定同一个 inode。
private final class CommandLibraryWriterLock {
    private let descriptor: Int32

    init(url: URL) throws {
        let handle = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard handle >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(handle)
            throw failure
        }
        descriptor = handle
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
