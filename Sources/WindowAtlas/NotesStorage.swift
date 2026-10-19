import Foundation

/// 本地笔记主库的文件读写。只处理本机目录，不涉及备份目的地。
///
/// 目录树即磁盘上的真实文件夹，路径一律为相对 notes/ 的相对路径：
/// - 目录：`项目A/子目录`
/// - 笔记：`项目A/部署-1a2b3c4d.md`
/// - 子笔记：放在与父笔记同名（去掉 .md）的文件夹里，如 `项目A/部署-1a2b3c4d/回滚-5e6f7a8b.md`
/// 「容器」指可以放笔记和目录的位置：根（空字符串）、目录、或笔记的子级文件夹。
final class NotesLibrary {
    struct Entry {
        var note: NoteDocument
        var path: String
        var modified: Date?
    }

    struct Scan {
        var entries: [Entry]
        /// 不属于任何笔记子级的普通目录，含空目录。
        var folders: [String]
    }

    enum SaveOutcome {
        case saved(path: String, modified: Date?)
        /// 文件在读取后被其他工具修改：本次内容另存为新笔记，原文件保持外部版本。
        case conflict(copy: NoteDocument, path: String, modified: Date?)
    }

    enum LibraryError: LocalizedError, Equatable {
        case readOnly
        case invalidLocation
        case folderNotEmpty
        case moveIntoItself
        var errorDescription: String? {
            switch self {
            case .readOnly: return L("笔记库正被另一个窗口图鉴实例使用，当前为只读。")
            case .invalidLocation: return L("目标位置不存在或不合法。")
            case .folderNotEmpty: return L("目录中还有笔记，只能删除空目录。可先移走或归档其中的笔记。")
            case .moveIntoItself: return L("不能移动到它自己或它的下级里。")
            }
        }
    }

    let root: URL
    let notesDirectory: URL
    let attachmentsDirectory: URL
    private(set) var readOnly = false
    private var lockDescriptor: Int32 = -1
    private var parsedCache: [String: (modified: Date, note: NoteDocument)] = [:]
    private let fileManager = FileManager.default

    static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WindowAtlas/Notes", isDirectory: true)
    }

    init(root: URL) throws {
        self.root = root
        notesDirectory = root.appendingPathComponent("notes", isDirectory: true)
        attachmentsDirectory = root.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        // 进程退出时系统自动释放 flock，不会因崩溃留下永久锁。
        lockDescriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        readOnly = lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0
    }

    deinit { if lockDescriptor >= 0 { close(lockDescriptor) } }

    // MARK: 路径工具

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func join(_ container: String, _ name: String) -> String { container.isEmpty ? name : container + "/" + name }

    /// 笔记的子级文件夹：同名去掉 .md。
    static func childrenContainer(ofNote path: String) -> String { String(path.dropLast(3)) }

    static func depth(of container: String) -> Int { container.isEmpty ? 0 : container.split(separator: "/").count }

    /// 相对路径只允许普通名字组成，拒绝 ..、隐藏项、绝对路径与反斜杠，防止越出笔记库。
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 900, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
        }
    }

    func url(_ path: String) -> URL { path.isEmpty ? notesDirectory : notesDirectory.appendingPathComponent(path) }

    private var basePath: String { notesDirectory.resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: 读取

    func loadAll() -> [Entry] { scan().entries }

    func scan() -> Scan {
        let base = basePath
        var notePaths: [(path: String, url: URL)] = []
        var directories: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let enumerator = fileManager.enumerator(at: notesDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: Set(keys))
            // 不跟随符号链接，避免把笔记库外的文件当成笔记。
            if values?.isSymbolicLink == true { if values?.isDirectory == true { enumerator?.skipDescendants() }; continue }
            let full = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            if values?.isDirectory == true { directories.append(relative) }
            else if item.pathExtension.lowercased() == "md" { notePaths.append((relative, item)) }
        }
        notePaths.sort { $0.path < $1.path }
        let noteSet = Set(notePaths.map(\.path))
        var seen = Set<String>()
        var nextCache: [String: (modified: Date, note: NoteDocument)] = [:]
        let entries = notePaths.compactMap { item -> Entry? in
            let modified = modificationDate(item.url)
            // 大量笔记时回到前台只重新读取修改时间变化的文件。
            var note: NoteDocument
            if let modified, let cached = parsedCache[item.path], cached.modified == modified {
                note = cached.note
            } else {
                guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return nil }
                // 无头部时按路径派生稳定 ID，避免每次重新加载时选中项跳动。
                note = NoteFormat.decode(text) ?? NoteDocument(id: Self.derivedID(item.path),
                    title: item.url.deletingPathExtension().lastPathComponent, body: text,
                    created: modified ?? Date(), updated: modified ?? Date())
            }
            if let modified { nextCache[item.path] = (modified, note) }
            // 用户在 Finder 里复制笔记会产生重复 ID；内存中改用派生 ID，编辑保存后写回。
            if seen.contains(note.id) { note.id = Self.derivedID(item.path) }
            seen.insert(note.id)
            return Entry(note: note, path: item.path, modified: modified)
        }
        parsedCache = nextCache
        let folders = directories.filter { !noteSet.contains($0 + ".md") }.sorted()
        return Scan(entries: entries, folders: folders)
    }

    private static func derivedID(_ path: String) -> String {
        "file-" + sha256(Data(path.utf8)).prefix(16)
    }

    // MARK: 保存

    /// 已有笔记保持在原容器；新笔记写入 container。
    func save(_ note: NoteDocument, previousPath: String?, expectedModified: Date?, container: String = "") throws -> SaveOutcome {
        guard !readOnly else { throw LibraryError.readOnly }
        let target = previousPath.map(Self.parent(of:)) ?? container
        guard target.isEmpty || Self.isSafeRelativePath(target) else { throw LibraryError.invalidLocation }
        if let previousPath {
            let previousURL = url(previousPath)
            if fileManager.fileExists(atPath: previousURL.path), modificationDate(previousURL) != expectedModified {
                var copy = note
                copy.id = UUID().uuidString
                copy.title = note.title + "（冲突副本）"
                let path = try write(copy, in: target)
                return .conflict(copy: copy, path: path, modified: modificationDate(url(path)))
            }
        }
        let path = try write(note, in: target)
        if let previousPath, previousPath != path {
            // 标题改名：新文件已原子写入成功后才移除旧文件，中途失败不会丢内容；子笔记文件夹随之改名。
            try? fileManager.removeItem(at: url(previousPath))
            let oldChildren = url(Self.childrenContainer(ofNote: previousPath))
            if fileManager.fileExists(atPath: oldChildren.path) {
                try? fileManager.moveItem(at: oldChildren, to: url(Self.childrenContainer(ofNote: path)))
            }
        }
        return .saved(path: path, modified: modificationDate(url(path)))
    }

    /// 同目录临时文件 + 原子替换，进程中断不会留下半个文件。
    private func write(_ note: NoteDocument, in container: String) throws -> String {
        try fileManager.createDirectory(at: url(container), withIntermediateDirectories: true)
        let path = Self.join(container, NoteFormat.fileName(title: note.title, id: note.id))
        try Data(NoteFormat.encode(note).utf8).write(to: url(path), options: .atomic)
        return path
    }

    // MARK: 目录与移动

    func createFolder(named name: String, in container: String) throws -> String {
        guard !readOnly else { throw LibraryError.readOnly }
        try requireContainer(container)
        let path = availablePath(Self.join(container, NoteFormat.sanitizedName(name, fallback: "新建目录")))
        try fileManager.createDirectory(at: url(path), withIntermediateDirectories: true)
        return path
    }

    func renameFolder(_ path: String, to name: String) throws -> String {
        guard !readOnly else { throw LibraryError.readOnly }
        guard Self.isSafeRelativePath(path), isDirectory(path) else { throw LibraryError.invalidLocation }
        let target = Self.join(Self.parent(of: path), NoteFormat.sanitizedName(name, fallback: "新建目录"))
        guard target != path else { return path }
        let destination = availablePath(target)
        try fileManager.moveItem(at: url(path), to: url(destination))
        return destination
    }

    /// 只删除不含任何笔记的目录（可含空子目录），避免误删内容。
    func deleteEmptyFolder(_ path: String) throws {
        guard !readOnly else { throw LibraryError.readOnly }
        guard Self.isSafeRelativePath(path), isDirectory(path) else { throw LibraryError.invalidLocation }
        guard markdownFiles(under: path).isEmpty else { throw LibraryError.folderNotEmpty }
        try fileManager.removeItem(at: url(path))
    }

    /// 移动笔记（连同其子笔记）到另一个容器，并按新层级修正图片链接。
    func moveNote(_ path: String, to container: String) throws -> String {
        guard !readOnly else { throw LibraryError.readOnly }
        guard Self.isSafeRelativePath(path), fileManager.fileExists(atPath: url(path).path) else { throw LibraryError.invalidLocation }
        let children = Self.childrenContainer(ofNote: path)
        guard container != children, !container.hasPrefix(children + "/") else { throw LibraryError.moveIntoItself }
        try requireContainer(container)
        if Self.parent(of: path) == container { return path }
        let destination = availablePath(Self.join(container, (path as NSString).lastPathComponent))
        try fileManager.moveItem(at: url(path), to: url(destination))
        if isDirectory(children) { try fileManager.moveItem(at: url(children), to: url(Self.childrenContainer(ofNote: destination))) }
        try normalizeLinks(notePaths: [destination] + markdownFiles(under: Self.childrenContainer(ofNote: destination)))
        return destination
    }

    func moveFolder(_ path: String, to container: String) throws -> String {
        guard !readOnly else { throw LibraryError.readOnly }
        guard Self.isSafeRelativePath(path), isDirectory(path) else { throw LibraryError.invalidLocation }
        guard container != path, !container.hasPrefix(path + "/") else { throw LibraryError.moveIntoItself }
        try requireContainer(container)
        if Self.parent(of: path) == container { return path }
        let destination = availablePath(Self.join(container, (path as NSString).lastPathComponent))
        try fileManager.moveItem(at: url(path), to: url(destination))
        try normalizeLinks(notePaths: markdownFiles(under: destination))
        return destination
    }

    /// 目标容器须是根、已存在的目录，或已存在笔记的子级文件夹（不存在时创建）。
    private func requireContainer(_ container: String) throws {
        if container.isEmpty { return }
        guard Self.isSafeRelativePath(container) else { throw LibraryError.invalidLocation }
        if isDirectory(container) { return }
        guard fileManager.fileExists(atPath: url(container + ".md").path) else { throw LibraryError.invalidLocation }
        try fileManager.createDirectory(at: url(container), withIntermediateDirectories: true)
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url(path).path, isDirectory: &directory) && directory.boolValue
    }

    private func availablePath(_ path: String) -> String {
        guard fileManager.fileExists(atPath: url(path).path) else { return path }
        let isNote = path.hasSuffix(".md")
        let stem = isNote ? String(path.dropLast(3)) : path
        var index = 2
        while fileManager.fileExists(atPath: url("\(stem) \(index)" + (isNote ? ".md" : "")).path) { index += 1 }
        return "\(stem) \(index)" + (isNote ? ".md" : "")
    }

    func markdownFiles(under container: String) -> [String] {
        scan().entries.map(\.path).filter { $0.hasPrefix(container + "/") }
    }

    private func normalizeLinks(notePaths: [String]) throws {
        for path in notePaths {
            let fileURL = url(path)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fixed = NoteAttachments.normalizeLinks(in: text, depth: Self.depth(of: Self.parent(of: path)))
            if fixed != text { try Data(fixed.utf8).write(to: fileURL, options: .atomic) }
        }
    }

    // MARK: 附件

    func importAttachment(_ data: Data) throws -> String {
        guard !readOnly else { throw LibraryError.readOnly }
        let prepared = try NoteAttachments.prepare(data)
        let url = attachmentsDirectory.appendingPathComponent(prepared.name)
        let attributes: [FileAttributeKey: Any]?
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            attributes = nil
        }
        if let attributes {
            // 内容地址文件只能是普通文件，避免沿链接写入笔记库之外的位置。
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LibraryError.invalidLocation }
            if (attributes[.size] as? NSNumber)?.intValue == prepared.data.count,
               sha256(try Data(contentsOf: url)) == sha256(prepared.data) {
                return prepared.name
            }
        }
        // 名称来自已验证图片的内容哈希；重新导入时原子修复同名损坏附件。
        try prepared.data.write(to: url, options: .atomic)
        return prepared.name
    }

    func attachmentURL(_ name: String) -> URL? {
        NoteAttachments.isValidName(name) ? attachmentsDirectory.appendingPathComponent(name) : nil
    }

    func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func modificationDate(path: String) -> Date? { modificationDate(url(path)) }
}
