import AppKit
import SwiftUI

enum NoteFilter: String, CaseIterable {
    case active, favorites, archived
    var title: String { switch self { case .active: return L("全部"); case .favorites: return L("收藏"); case .archived: return L("归档") } }
}

enum NoteSaveState: Equatable {
    case idle, pending, saved(Date), failed(String)
}

/// 由正文派生、渲染时反复用到的数据；按笔记缓存，避免大量笔记时每次刷新都重新解析。
struct NoteDerived {
    let snippets: [NoteSnippet]
    let subtitle: String
    let secrets: [String]
}

/// 目录树节点。目录和笔记都可以有下级；没有下级的笔记 children 为 nil，不显示展开箭头。
struct NoteTreeNode: Identifiable, Hashable {
    enum Kind: Hashable { case folder(String), note(String) }
    let kind: Kind
    let title: String
    var children: [NoteTreeNode]?
    var id: String {
        switch kind { case .folder(let path): return "folder:" + path; case .note(let id): return "note:" + id }
    }
}

/// 独立于 WindowStore：窗口每 6 秒刷新不会触发笔记重新加载或编辑器重建。
@MainActor
final class NotesStore: ObservableObject {
    /// 不用 @Published：正文输入走静默更新，停顿保存后再统一刷新界面，打字时不重绘列表。
    private(set) var notes: [NoteDocument] = [] {
        willSet { if !silentEdit { objectWillChange.send() } }
    }
    @Published private(set) var folders: [String] = []
    @Published var selectedID: String?
    @Published var selectedFolder: String?
    @Published var query = ""
    @Published var filter: NoteFilter = .active
    @Published var previewing = false
    @Published private(set) var saveState: NoteSaveState = .idle
    @Published var message: String?
    @Published private(set) var loadError: String?
    @Published private(set) var copiedSnippetID: String?

    let library: NotesLibrary?
    weak var activeTextView: NSTextView?
    private var silentEdit = false
    private var silentPending = false
    private var derivedCache: [String: (title: String, body: String, value: NoteDerived)] = [:]
    /// 笔记 ID → 相对路径与读取时的修改时间。
    private(set) var paths: [String: (path: String, modified: Date?)] = [:]
    /// 尚未保存过的新笔记要写入的容器。
    private var pendingContainers: [String: String] = [:]
    private var dirty = Set<String>()
    private var saveTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?

    init(root: URL = NotesLibrary.defaultRoot) {
        do {
            library = try NotesLibrary(root: root)
        } catch {
            library = nil
            loadError = String(format: L("无法打开本地笔记库：%@"), String(describing: error.localizedDescription))
        }
        reload()
    }

    var readOnly: Bool { library?.readOnly ?? true }
    var selected: NoteDocument? { notes.first { $0.id == selectedID } }
    var activeCount: Int { notes.filter { !$0.archived }.count }
    /// 列表是否以平铺方式显示：搜索、收藏、归档时按结果平铺，否则显示目录树。
    var showsFlatList: Bool { !query.isEmpty || filter != .active }

    func container(ofNote id: String) -> String {
        paths[id].map { NotesLibrary.parent(of: $0.path) } ?? pendingContainers[id] ?? ""
    }

    /// 新建笔记或目录的默认位置：选中目录时放在目录里，选中笔记时与它同级。
    var currentContainer: String {
        if let selectedFolder { return selectedFolder }
        if let selectedID { return container(ofNote: selectedID) }
        return ""
    }

    /// 面包屑：把子笔记文件夹显示为父笔记标题，而不是带 ID 的文件夹名。
    func breadcrumb(_ container: String) -> String {
        guard !container.isEmpty else { return L("笔记库") }
        var titleByChildren: [String: String] = [:]
        for note in notes { if let path = paths[note.id]?.path { titleByChildren[NotesLibrary.childrenContainer(ofNote: path)] = note.title } }
        var parts: [String] = []
        var current = ""
        for component in container.split(separator: "/") {
            current = NotesLibrary.join(current, String(component))
            parts.append(titleByChildren[current] ?? String(component))
        }
        return parts.joined(separator: " › ")
    }

    var visibleNotes: [NoteDocument] {
        notes.filter { note in
            let inFilter: Bool
            switch filter {
            case .active: inFilter = !note.archived
            case .favorites: inFilter = note.favorite && !note.archived
            case .archived: inFilter = note.archived
            }
            return inFilter && (query.isEmpty || (note.title + "\n" + note.body).localizedCaseInsensitiveContains(query))
        }.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
    }

    /// 目录树：目录在前按名称，笔记在后按标题；已归档笔记只在仍有下级时显示，保证下级不被藏起来。
    func tree() -> [NoteTreeNode] {
        var notesByContainer: [String: [NoteDocument]] = [:]
        for note in notes { notesByContainer[container(ofNote: note.id), default: []].append(note) }
        var foldersByContainer: [String: [String]] = [:]
        for folder in folders { foldersByContainer[NotesLibrary.parent(of: folder), default: []].append(folder) }
        func nodes(in container: String, depth: Int) -> [NoteTreeNode] {
            guard depth < 200 else { return [] }
            let folderNodes = (foldersByContainer[container] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
                NoteTreeNode(kind: .folder($0), title: ($0 as NSString).lastPathComponent, children: nodes(in: $0, depth: depth + 1))
            }
            let sorted = (notesByContainer[container] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let noteNodes = sorted.compactMap { note -> NoteTreeNode? in
                let children = paths[note.id].map { nodes(in: NotesLibrary.childrenContainer(ofNote: $0.path), depth: depth + 1) } ?? []
                guard !note.archived || !children.isEmpty else { return nil }
                return NoteTreeNode(kind: .note(note.id), title: note.title, children: children.isEmpty ? nil : children)
            }
            return folderNodes + noteNodes
        }
        return nodes(in: "", depth: 0)
    }

    func derived(_ note: NoteDocument) -> NoteDerived {
        if let cached = derivedCache[note.id], cached.title == note.title, cached.body == note.body { return cached.value }
        let snippets = NoteSnippets.extract(from: note)
        let firstCode = snippets.first { !$0.code.isEmpty }?.code
        let line = (firstCode ?? note.body).split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let value = NoteDerived(snippets: snippets, subtitle: line.map { String($0.prefix(120)).trimmingCharacters(in: .whitespaces) } ?? "",
                                secrets: SecretScanner.findings(in: note.title + "\n" + note.body))
        derivedCache[note.id] = (note.title, note.body, value)
        return value
    }

    /// 工作台命令面板只列未归档笔记中的代码块。
    func searchSnippets(_ text: String) -> [(note: NoteDocument, snippet: NoteSnippet)] {
        notes.filter { !$0.archived }.sorted { $0.updated > $1.updated }.flatMap { note in
            derived(note).snippets.map { (note: note, snippet: $0) }
        }.filter { pair in
            text.isEmpty || (pair.snippet.label + "\n" + pair.snippet.code + "\n" + pair.note.title).localizedCaseInsensitiveContains(text)
        }
    }

    // MARK: 载入

    func reload() {
        // 失败的保存仍保留在内存中，任何重新载入都不能抹掉待重试的编辑。
        guard dirty.isEmpty else { return }
        guard let library else { return }
        let scan = library.scan()
        notes = scan.entries.map(\.note)
        folders = scan.folders
        paths = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.note.id, (path: $0.path, modified: $0.modified)) })
        derivedCache = derivedCache.filter { paths[$0.key] != nil }
        pendingContainers.removeAll()
        dirty.removeAll()
        if let folder = selectedFolder, !folders.contains(folder) { selectedFolder = nil }
        if selectedFolder == nil, selectedID == nil || selected == nil { selectedID = visibleNotes.first?.id }
    }

    /// 回到前台时合并外部修改；有未保存编辑的笔记保持内存版本，保存时由冲突副本机制保护。
    func reloadExternalChanges() {
        guard let library else { return }
        let scan = library.scan()
        let diskIDs = Set(scan.entries.map(\.note.id))
        var merged = notes.filter { dirty.contains($0.id) || (paths[$0.id] == nil && !diskIDs.contains($0.id)) }
        for entry in scan.entries where !dirty.contains(entry.note.id) {
            merged.append(entry.note)
            paths[entry.note.id] = (entry.path, entry.modified)
        }
        paths = paths.filter { diskIDs.contains($0.key) || dirty.contains($0.key) }
        if folders != scan.folders { folders = scan.folders }
        // 无外部变化时不替换数组，避免回到前台就重绘整个笔记界面。
        if merged.sorted(by: { $0.id < $1.id }) != notes.sorted(by: { $0.id < $1.id }) { notes = merged }
        if selectedFolder == nil, selected == nil { selectedID = visibleNotes.first?.id }
    }

    // MARK: 新建与选择

    func createNote(in container: String? = nil) {
        guard !readOnly else { message = NotesLibrary.LibraryError.readOnly.localizedDescription; return }
        guard flush() else { return }
        let target = container ?? currentContainer
        let now = Date()
        let note = NoteDocument(id: UUID().uuidString, title: L("未命名笔记"), body: L("说明：\n\n```sh\n\n```\n"), created: now, updated: now)
        pendingContainers[note.id] = target
        notes.append(note)
        if filter == .archived { filter = .active }
        query = ""
        selectedFolder = nil
        selectedID = note.id
        markDirty(note.id)
        previewing = false
    }

    func createChildNote(of id: String) {
        guard flush() else { return }
        guard let path = paths[id]?.path else { return }
        createNote(in: NotesLibrary.childrenContainer(ofNote: path))
    }

    func select(_ id: String?) {
        guard id != selectedID || selectedFolder != nil else { return }
        guard flush() else { return }
        selectedFolder = nil
        selectedID = id
    }

    func selectFolder(_ path: String) {
        guard flush() else { return }
        selectedID = nil
        selectedFolder = path
    }

    // MARK: 目录操作（先保存，再改磁盘，最后整体重新载入）

    func createFolder(named name: String, in container: String? = nil) {
        let target = container ?? currentContainer
        perform { library in
            let path = try library.createFolder(named: name, in: target)
            return { self.selectFolder(path) }
        }
    }

    func renameFolder(_ path: String, to name: String) {
        perform { library in
            let renamed = try library.renameFolder(path, to: name)
            return { if self.selectedFolder == path { self.selectedFolder = renamed } }
        }
    }

    func deleteFolder(_ path: String) {
        perform { library in
            try library.deleteEmptyFolder(path)
            return { if self.selectedFolder == path { self.selectedFolder = nil } }
        }
    }

    func moveNote(_ id: String, to container: String) {
        perform { library in
            guard let path = self.paths[id]?.path else { return {} }
            _ = try library.moveNote(path, to: container)
            return {}
        }
    }

    func moveFolder(_ path: String, to container: String) {
        perform { library in
            let moved = try library.moveFolder(path, to: container)
            return { if self.selectedFolder == path { self.selectedFolder = moved } }
        }
    }

    /// 树内拖放：笔记连同其子笔记、目录连同其内容一起移动到目标容器。
    func moveDragged(_ items: [String], to container: String) {
        for item in items {
            if item.hasPrefix("note:") { moveNote(String(item.dropFirst(5)), to: container) }
            else if item.hasPrefix("folder:") { moveFolder(String(item.dropFirst(7)), to: container) }
        }
    }

    /// 目录是否不含任何笔记（含下级），用于决定能否删除。
    func folderIsEmpty(_ path: String) -> Bool {
        !paths.values.contains { $0.path.hasPrefix(path + "/") }
    }

    private func perform(_ action: (NotesLibrary) throws -> () -> Void) {
        guard let library else { return }
        guard !readOnly else { message = NotesLibrary.LibraryError.readOnly.localizedDescription; return }
        guard flush() else { return }
        do {
            let after = try action(library)
            reload()
            after()
        } catch {
            reload()
            message = error.localizedDescription
        }
    }

    // MARK: 编辑与保存

    func update(_ id: String, _ change: (inout NoteDocument) -> Void) {
        guard !readOnly, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        change(&note)
        guard note != notes[index] else { return }
        note.updated = Date()
        notes[index] = note
        markDirty(id)
    }

    /// 编辑器逐字输入的路径：只改内存不刷新界面，停顿约 0.8 秒保存后统一刷新。
    func editBody(_ id: String, _ body: String) {
        guard !readOnly, let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
        silentEdit = true
        notes[index].body = body
        notes[index].updated = Date()
        silentEdit = false
        silentPending = true
        markDirty(id)
    }

    private func markDirty(_ id: String) {
        dirty.insert(id)
        if saveState != .pending { saveState = .pending }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 切换笔记、目录操作、备份和退出前调用，立即写入所有未保存内容。
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        guard !dirty.isEmpty else { return true }
        guard let library else { return false }
        var failure: String?
        var movedChildren = false
        for id in dirty.sorted() {
            guard let note = notes.first(where: { $0.id == id }) else { dirty.remove(id); continue }
            do {
                let previous = paths[id]
                switch try library.save(note, previousPath: previous?.path, expectedModified: previous?.modified,
                                        container: pendingContainers[id] ?? "") {
                case .saved(let path, let modified):
                    // 标题改名会连带移动子笔记文件夹，下级笔记路径需要重新扫描。
                    if let previous, previous.path != path, paths.values.contains(where: {
                        $0.path.hasPrefix(NotesLibrary.childrenContainer(ofNote: previous.path) + "/")
                    }) { movedChildren = true }
                    paths[id] = (path, modified)
                    pendingContainers.removeValue(forKey: id)
                case .conflict(let copy, let path, let modified):
                    // 外部版本保留在原文件；内存中原笔记恢复为磁盘内容，本次编辑出现在副本里。
                    notes.removeAll { $0.id == id }
                    paths.removeValue(forKey: id)
                    notes.append(copy)
                    paths[copy.id] = (path, modified)
                    if selectedID == id { selectedID = copy.id }
                    message = String(format: L("「%@」已被其他程序修改，你的编辑另存为冲突副本。"), String(describing: note.title))
                    reloadExternalChanges()
                }
                dirty.remove(id)
            } catch {
                failure = error.localizedDescription
            }
        }
        saveState = failure.map { .failed(String(format: L("保存失败：%@"), String(describing: $0))) } ?? .saved(Date())
        if movedChildren { reloadExternalChanges() }
        if silentPending { silentPending = false; objectWillChange.send() }
        return dirty.isEmpty
    }

    /// 备份与导出用：当前全部已保存笔记及目录。
    func snapshotItems() -> (items: [NotesBackup.Item], folders: [String])? {
        guard flush() else { return nil }
        let items = notes.compactMap { note -> NotesBackup.Item? in
            guard let path = paths[note.id]?.path else { return nil }
            return NotesBackup.Item(path: path, text: NoteFormat.encode(note), sensitive: note.sensitive)
        }
        return (items, folders)
    }

    func copy(_ snippet: NoteSnippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.code, forType: .string)
        copiedSnippetID = snippet.id
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedSnippetID = nil
        }
    }

    // MARK: 编辑器插入

    func insertIntoEditor(_ text: String, cursorOffset: Int? = nil) {
        guard let textView = activeTextView, !readOnly else { return }
        let range = textView.selectedRange()
        textView.insertText(text, replacementRange: range)
        if let cursorOffset { textView.setSelectedRange(NSRange(location: range.location + cursorOffset, length: 0)) }
        textView.window?.makeFirstResponder(textView)
    }

    func insertFence(language: String) {
        let opening = "\n```\(language)\n"
        insertIntoEditor(opening + "\n```\n", cursorOffset: (opening as NSString).length)
    }

    /// 返回 Markdown 图片链接（按当前笔记层级生成相对前缀）；失败时给出明确提示，不插入任何内容。
    func importImage(_ data: Data) -> String? {
        guard let library else { return nil }
        do {
            let name = try library.importAttachment(data)
            let depth = NotesLibrary.depth(of: selectedID.map(container(ofNote:)) ?? "")
            return "![](\(NoteAttachments.linkPrefix(depth: depth))\(name))"
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= NoteAttachments.maxBytes else {
            message = NoteAttachments.ImportError.tooLarge.localizedDescription; return
        }
        guard let data = try? Data(contentsOf: url) else { message = L("无法读取所选图片。"); return }
        if let link = importImage(data) { insertIntoEditor("\n" + link + "\n") }
    }

    func attachmentImage(link: String) -> NSImage? {
        guard let name = NoteAttachments.validatedName(fromLink: link), let url = library?.attachmentURL(name) else { return nil }
        return NSImage(contentsOf: url)
    }
}
