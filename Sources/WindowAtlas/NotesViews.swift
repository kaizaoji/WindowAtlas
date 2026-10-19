import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 项目笔记主界面：目录树、正文编辑与本笔记代码独立于全局命令库。
struct NotesView: View {
    @EnvironmentObject var notes: NotesStore
    @AppStorage("notesSidebarVisible") private var sidebarVisible = true
    @State private var searchRequest = 0
    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }.buttonStyle(AtlasHoverButtonStyle()).help(L("显示或隐藏笔记目录")).accessibilityLabel(L("显示或隐藏笔记目录"))
                Label(L("项目笔记"), systemImage: "doc.text").font(.headline)
                Spacer()
                if geometry.size.width >= 620 {
                    Text(L("项目资料 · 本地保存")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10).background(AtlasStyle.surface)
            Divider()
            NotesBanners()
            HStack(spacing: 0) {
                if sidebarVisible {
                    NoteListColumn(searchRequest: searchRequest).frame(width: geometry.size.width < 900 ? 238 : 280)
                        .background(AtlasStyle.surface)
                    Divider()
                }
                if let note = notes.selected {
                    NoteEditorColumn(note: note)
                } else if let folder = notes.selectedFolder {
                    FolderPane(path: folder)
                } else {
                    ContentUnavailableView {
                        Label(L("整理项目资料，记录工作过程"), systemImage: "doc.text")
                    } description: {
                        Text(L("用目录整理项目说明、代码和图片，也能创建子笔记。这里的代码保留在笔记中，常用命令请单独保存到命令库。"))
                    } actions: {
                        Button(L("新建笔记")) { notes.createNote(in: "") }.buttonStyle(.borderedProminent).disabled(notes.readOnly)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .notesDrop(notes, highlight: false) { "" }
                }
            }
        }
        .background(AtlasStyle.canvas)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WindowAtlas.focusSearch"))) { _ in
            sidebarVisible = true
            DispatchQueue.main.async {
                searchRequest += 1
            }
        }
        .onDisappear { notes.flush() }
    }
}

struct NotesBanners: View {
    @EnvironmentObject var notes: NotesStore
    var body: some View {
        if let error = notes.loadError {
            banner(error, symbol: "exclamationmark.triangle", color: .red, dismiss: nil)
        } else if notes.readOnly {
            banner(NotesLibrary.LibraryError.readOnly.localizedDescription, symbol: "lock", color: .orange, dismiss: nil)
        }
        if let message = notes.message {
            banner(message, symbol: "info.circle", color: .orange) { notes.message = nil }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color, dismiss: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.padding(10).background(color.opacity(0.08))
    }
}

/// 名称输入框（新建目录、重命名）和「移动到…」共用的弹出状态。
struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    var text: String
    let action: (String) -> Void
}

enum MoveSubject: Identifiable {
    case note(String), folder(String)
    var id: String { switch self { case .note(let id): return "note:" + id; case .folder(let path): return "folder:" + path } }
}

struct NoteListColumn: View {
    @EnvironmentObject var notes: NotesStore
    @State private var backupShown = false
    @State private var prompt: NamePrompt?
    @State private var moving: MoveSubject?
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused: Bool
    var searchRequest = 0

    private var treeSelection: Binding<String?> {
        Binding(get: {
            notes.selectedFolder.map { "folder:" + $0 } ?? notes.selectedID.map { "note:" + $0 }
        }, set: { value in
            guard let value else { return }
            if value.hasPrefix("folder:") { notes.selectFolder(String(value.dropFirst(7))) }
            else if value.hasPrefix("note:") { notes.select(String(value.dropFirst(5))) }
        })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(L("笔记库")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { backupShown.toggle() } label: { Image(systemName: "externaldrive.badge.icloud") }
                    .buttonStyle(.borderless).help(L("备份、导出与导入"))
                    .popover(isPresented: $backupShown, arrowEdge: .bottom) { NotesBackupSettings() }
                Menu {
                    Button(L("新建笔记")) { notes.createNote() }
                    if let id = notes.selectedID { Button(L("新建子笔记")) { notes.createChildNote(of: id) } }
                    Button(L("新建目录…")) { askFolderName(in: notes.currentContainer) }
                    Divider()
                    Button(L("导入文档…")) { notes.chooseDocumentsToImport() }
                } label: { Label(L("更多"), systemImage: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help(L("笔记与目录操作")).disabled(notes.readOnly)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { createNoteButton; createFolderButton }
                VStack(alignment: .leading, spacing: 6) { createNoteButton; createFolderButton }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(L("新建位置：") + notes.breadcrumb(notes.currentContainer)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
            TextField(L("搜索项目笔记"), text: $notes.query).textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onChange(of: searchRequest) { _, _ in searchFocused = true }
                .onAppear { if searchRequest > 0 { searchFocused = true } }
            Picker("", selection: $notes.filter) {
                ForEach(NoteFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if notes.showsFlatList {
                List(selection: Binding(get: { notes.selectedID }, set: { notes.select($0) })) {
                    ForEach(notes.visibleNotes) { note in
                        NoteRow(note: note, location: notes.breadcrumb(notes.container(ofNote: note.id))).tag(note.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay { if notes.visibleNotes.isEmpty { emptyText(notes.query.isEmpty ? L("暂无笔记") : L("没有匹配的笔记")) } }
                .notesDrop(notes, highlight: false) { notes.currentContainer }
            } else {
                let tree = notes.tree()
                List(selection: treeSelection) {
                    NoteTreeRows(nodes: tree, expanded: $expanded) { treeRow($0) }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                // 新建子笔记或从搜索结果跳转时自动展开上级，保证选中项可见。
                .onChange(of: treeSelection.wrappedValue) { _, selected in
                    if let selected, let path = Self.ancestors(of: selected, in: tree) { expanded.formUnion(path) }
                }
                .onAppear {
                    if let selected = treeSelection.wrappedValue, let path = Self.ancestors(of: selected, in: tree) { expanded.formUnion(path) }
                }
                .overlay { if tree.isEmpty { emptyText(L("暂无笔记，点右上角新建")) } }
                .notesDrop(notes, highlight: false) { "" }
                Text(L("拖动调整层级；可从 Finder 拖入文件或文件夹导入，拖到目录或笔记上即放到其下，拖到空白处放到顶层"))
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 10)
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(L("名称"), text: Binding(get: { prompt?.text ?? "" }, set: { prompt?.text = $0 }))
            Button(L("确定")) { if let prompt { prompt.action(prompt.text) }; prompt = nil }
            Button(L("取消"), role: .cancel) { prompt = nil }
        }
        .sheet(item: $moving) { subject in MoveDestinationSheet(subject: subject) }
    }

    private var createNoteButton: some View {
        Button { notes.createNote() } label: {
            Label(L("新建笔记"), systemImage: "doc.badge.plus").font(.caption.weight(.medium)).fixedSize()
        }.buttonStyle(AtlasHoverButtonStyle(accented: true)).disabled(notes.readOnly)
    }

    private var createFolderButton: some View {
        Button { askFolderName(in: notes.currentContainer) } label: {
            Label(L("新建目录"), systemImage: "folder.badge.plus").font(.caption.weight(.medium)).fixedSize()
        }.buttonStyle(AtlasHoverButtonStyle()).disabled(notes.readOnly)
    }

    static func ancestors(of id: String, in nodes: [NoteTreeNode]) -> [String]? {
        for node in nodes {
            if node.id == id { return [] }
            if let children = node.children, let path = ancestors(of: id, in: children) { return [node.id] + path }
        }
        return nil
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func askFolderName(in container: String) {
        prompt = NamePrompt(title: String(format: L("新建目录（位于 %@）"), String(describing: notes.breadcrumb(container))), text: L("新建目录")) { notes.createFolder(named: $0, in: container) }
    }

    @ViewBuilder
    private func treeRow(_ node: NoteTreeNode) -> some View {
        switch node.kind {
        case .folder(let path):
            HStack(spacing: 7) {
                Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AtlasStyle.accent).frame(width: 18)
                Text(node.title).lineLimit(1)
            }
                .draggable(node.id)
                .notesDrop(notes) { path }
                .contextMenu {
                    Button(L("新建笔记")) { notes.createNote(in: path) }
                    Button(L("新建子目录…")) { askFolderName(in: path) }
                    Button(L("导入文档到此…")) { notes.chooseDocumentsToImport(into: path) }
                    Divider()
                    Button(L("重命名…")) {
                        prompt = NamePrompt(title: L("重命名目录"), text: node.title) { notes.renameFolder(path, to: $0) }
                    }
                    Button(L("移动到…")) { moving = .folder(path) }
                    Divider()
                    Button(L("删除空目录")) { notes.deleteFolder(path) }.disabled(!notes.folderIsEmpty(path))
                }
        case .note(let id):
            let note = notes.notes.first { $0.id == id }
            HStack(spacing: 5) {
                Image(systemName: node.children == nil ? "doc.text" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 18)
                Text(node.title).lineLimit(1).foregroundStyle(note?.archived == true ? .secondary : .primary)
                Spacer(minLength: 2)
                if note?.sensitive == true { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                if note?.favorite == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
            }
            .draggable(node.id)
            .notesDrop(notes) { notes.paths[id].map { NotesLibrary.childrenContainer(ofNote: $0.path) } }
            .contextMenu {
                Button(L("新建子笔记")) { notes.createChildNote(of: id) }
                Button(L("新建同级笔记")) { notes.createNote(in: notes.container(ofNote: id)) }
                if let path = notes.paths[id]?.path {
                    Button(L("在其下新建目录…")) { askFolderName(in: NotesLibrary.childrenContainer(ofNote: path)) }
                }
                Divider()
                Button(L("移动到…")) { moving = .note(id) }
                Button(note?.favorite == true ? L("取消收藏") : L("收藏")) { notes.update(id) { $0.favorite.toggle() } }
                Button(note?.archived == true ? L("取消归档") : L("归档")) { notes.update(id) { $0.archived.toggle() } }
            }
        }
    }
}

extension View {
    /// 笔记区拖放：Finder 文件/文件夹 → 导入到目标容器；树内拖动的节点 → 移动到目标容器。
    /// container 返回 nil 表示该位置不可放置。
    func notesDrop(_ notes: NotesStore, highlight: Bool = true, container: @escaping () -> String?) -> some View {
        modifier(NotesDropTarget(notes: notes, highlight: highlight, container: container))
    }
}

struct NotesDropTarget: ViewModifier {
    let notes: NotesStore
    let highlight: Bool
    let container: () -> String?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(highlight && targeted ? 0.2 : 0)))
            .onDrop(of: [.fileURL, .utf8PlainText, .plainText], isTargeted: $targeted) { providers in
                guard !notes.readOnly, let target = container() else { return false }
                // Finder 拖入优先按文件处理，避免把文件路径文本误当成树内节点。
                let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
                if !files.isEmpty {
                    NotesDropLoader.load(files, as: URL.self) { urls in
                        let local = urls.filter(\.isFileURL).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        if !local.isEmpty { notes.importDocuments(local, into: target) }
                    }
                    return true
                }
                let texts = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
                guard !texts.isEmpty else { return false }
                NotesDropLoader.load(texts, as: NSString.self) { items in notes.moveDragged(items.map { $0 as String }, to: target) }
                return true
            }
    }
}

enum NotesDropLoader {
    /// 并行读取拖放内容，全部完成后回到主线程一次性处理。
    static func load<T: _ObjectiveCBridgeable>(_ providers: [NSItemProvider], as type: T.Type, completion: @escaping @MainActor ([T]) -> Void)
        where T._ObjectiveCType: NSItemProviderReading {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [T] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: type) { value, _ in
                if let value { lock.lock(); results.append(value); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(results) } }
    }

    static func load<T: NSItemProviderReading>(_ providers: [NSItemProvider], as type: T.Type, completion: @escaping @MainActor ([T]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [T] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: type) { value, _ in
                if let value = value as? T { lock.lock(); results.append(value); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(results) } }
    }
}

/// 递归目录树行：展开状态由外部持有，便于自动展开选中项的上级。
struct NoteTreeRows<Row: View>: View {
    let nodes: [NoteTreeNode]
    @Binding var expanded: Set<String>
    let row: (NoteTreeNode) -> Row

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })) {
                    NoteTreeRows(nodes: children, expanded: $expanded, row: row)
                } label: { row(node).tag(node.id) }
            } else {
                row(node).tag(node.id)
            }
        }
    }
}

/// 「移动到…」：列出所有可放置的位置（根、目录、笔记的子级），排除自身及下级。
struct MoveDestinationSheet: View {
    @EnvironmentObject var notes: NotesStore
    @Environment(\.dismiss) private var dismiss
    let subject: MoveSubject
    @State private var choice: String?

    private var destinations: [String] {
        var all = Set(notes.folders)
        for value in notes.paths.values { all.insert(NotesLibrary.childrenContainer(ofNote: value.path)) }
        let excluded: String
        switch subject {
        case .folder(let path): excluded = path
        case .note(let id): excluded = notes.paths[id].map { NotesLibrary.childrenContainer(ofNote: $0.path) } ?? ""
        }
        let filtered = all.filter { excluded.isEmpty || ($0 != excluded && !$0.hasPrefix(excluded + "/")) }
        return [""] + filtered.sorted { notes.breadcrumb($0).localizedStandardCompare(notes.breadcrumb($1)) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("移动到")).font(.headline)
            List(destinations, id: \.self, selection: $choice) { container in
                Label(notes.breadcrumb(container), systemImage: container.isEmpty ? "tray.full" : "folder")
                    .padding(.leading, CGFloat(NotesLibrary.depth(of: container)) * 10)
            }.frame(minHeight: 260)
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                Button(L("移动")) {
                    guard let choice else { return }
                    switch subject {
                    case .note(let id): notes.moveNote(id, to: choice)
                    case .folder(let path): notes.moveFolder(path, to: choice)
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(choice == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 420, height: 400)
    }
}

/// 选中目录时的右侧面板：位置、内容数量与目录操作。
struct FolderPane: View {
    @EnvironmentObject var notes: NotesStore
    let path: String
    @State private var prompt: NamePrompt?
    @State private var moving = false

    var body: some View {
        let inside = notes.paths.values.filter { $0.path.hasPrefix(path + "/") }.count
        VStack(alignment: .leading, spacing: 14) {
            Label((path as NSString).lastPathComponent, systemImage: "folder").font(.system(size: 22, weight: .semibold))
            Text(L("位置：") + notes.breadcrumb(NotesLibrary.parent(of: path))).font(.callout).foregroundStyle(.secondary)
            Text(String(format: L("包含 %@ 篇笔记（含下级）"), String(describing: inside))).font(.callout)
            Text(L("可从 Finder 把文件或文件夹拖到这里导入到此目录。")).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 10) {
                Button(L("新建笔记")) { notes.createNote(in: path) }.buttonStyle(.borderedProminent)
                Button(L("新建子目录…")) {
                    prompt = NamePrompt(title: L("新建子目录"), text: L("新建目录")) { notes.createFolder(named: $0, in: path) }
                }
                Button(L("重命名…")) {
                    prompt = NamePrompt(title: L("重命名目录"), text: (path as NSString).lastPathComponent) { notes.renameFolder(path, to: $0) }
                }
                Button(L("导入文档…")) { notes.chooseDocumentsToImport(into: path) }
                Button(L("移动到…")) { moving = true }
                Button(L("删除空目录")) { notes.deleteFolder(path) }.disabled(inside > 0)
            }.disabled(notes.readOnly)
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .notesDrop(notes, highlight: false) { path }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(L("名称"), text: Binding(get: { prompt?.text ?? "" }, set: { prompt?.text = $0 }))
            Button(L("确定")) { if let prompt { prompt.action(prompt.text) }; prompt = nil }
            Button(L("取消"), role: .cancel) { prompt = nil }
        }
        .sheet(isPresented: $moving) { MoveDestinationSheet(subject: .folder(path)) }
    }
}

struct NoteRow: View {
    @EnvironmentObject var notes: NotesStore
    let note: NoteDocument
    var location: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(note.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                if note.sensitive { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help(L("敏感 · 不备份")) }
                if note.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.orange) }
            }
            Text(notes.derived(note).subtitle.isEmpty ? L("空白笔记") : notes.derived(note).subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                if let location { Text(location).lineLimit(1).truncationMode(.head) }
                Text(note.updated, format: .relative(presentation: .named))
                    .help(String(format: L("创建时间：%@\n修改时间：%@"), String(describing: note.created.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(AppPreferences.shared.locale))), String(describing: note.updated.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(AppPreferences.shared.locale)))))
            }.font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 4)
    }
}

struct NoteEditorColumn: View {
    @EnvironmentObject var notes: NotesStore
    let note: NoteDocument
    @State private var moving = false

    private var saveText: (String, Color) {
        if notes.readOnly { return (L("只读"), .orange) }
        switch notes.saveState {
        case .idle: return ("", .secondary)
        case .pending: return (L("正在保存…"), .secondary)
        case .saved(let date): return (L("已保存 ") + date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppPreferences.shared.locale)), .secondary)
        case .failed(let message): return (message, .red)
        }
    }

    private var saveSymbol: String {
        if notes.readOnly { return "lock" }
        switch notes.saveState {
        case .failed: return "exclamationmark.triangle"
        case .pending: return "clock"
        case .saved: return "checkmark.circle"
        case .idle: return "doc"
        }
    }

    @AppStorage("notesCommandsVisible") private var commandsVisible = true
    @State private var commandPopover = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780
            let derived = notes.derived(note)
            VStack(spacing: 0) {
                editorHeader(wide: wide)
                if !note.sensitive && !derived.secrets.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.orange)
                        Text(L("检测到疑似密钥（%@）。是否进入备份由你决定；如不希望备份，可标记为敏感。", derived.secrets.map { L($0) }.joined(separator: ", ")))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Button(L("标记为敏感")) { notes.update(note.id) { $0.sensitive = true } }
                            .controlSize(.small).disabled(notes.readOnly)
                    }.padding(12).background(Color.orange.opacity(0.08))
                }
                Divider()
                if notes.previewing {
                    MarkdownPreview(note: note)
                } else {
                    HStack(spacing: 0) {
                        MarkdownEditor(noteID: note.id, text: note.body, editable: !notes.readOnly)
                            .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                        if wide && commandsVisible {
                            Divider()
                            commandPanel.frame(width: 240).background(AtlasStyle.surface)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: saveSymbol)
                    Text(saveText.0).lineLimit(2).textSelection(.enabled).help(saveText.0)
                    Spacer(minLength: 8)
                    if wide { Text(L("可直接粘贴或拖入图片")).foregroundStyle(.tertiary) }
                }.font(.caption2).foregroundStyle(saveText.1)
                    .padding(.horizontal, 16).padding(.vertical, 8).background(AtlasStyle.surface)
            }.background(AtlasStyle.canvas)
        }
        .sheet(isPresented: $moving) { MoveDestinationSheet(subject: .note(note.id)) }
    }

    private func editorHeader(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(AtlasStyle.accent)
                Text(notes.breadcrumb(notes.container(ofNote: note.id)))
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                if note.sensitive { Image(systemName: "lock.shield.fill").help(L("敏感 · 不备份")) }
                if note.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
            TextField(L("标题"), text: Binding(get: { note.title }, set: { value in notes.update(note.id) { $0.title = value } }))
                .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).disabled(notes.readOnly)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { timestamps }
                VStack(alignment: .leading, spacing: 4) { timestamps }
            }.font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 8) {
                Picker("", selection: $notes.previewing) {
                    Text(L("编辑")).tag(false); Text(L("预览")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 138)
                insertMenu
                Spacer(minLength: 0)
                Button {
                    if wide && !notes.previewing { commandsVisible.toggle() }
                    else { commandPopover.toggle() }
                } label: {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(wide && commandsVisible && !notes.previewing ? AtlasStyle.accent : .secondary)
                }.buttonStyle(AtlasHoverButtonStyle()).help(L("显示或隐藏本笔记代码")).accessibilityLabel(L("显示或隐藏本笔记代码"))
                    .popover(isPresented: $commandPopover) { commandPanel.frame(width: 300, height: 400) }
                noteActions
            }
        }.padding(16).background(AtlasStyle.surface)
    }

    private var insertMenu: some View {
        Menu {
            Button(L("命令块")) { notes.previewing = false; DispatchQueue.main.async { notes.insertFence(language: "sh") } }
            Button(L("代码块")) { notes.previewing = false; DispatchQueue.main.async { notes.insertFence(language: "") } }
            Button(L("图片…")) { notes.previewing = false; DispatchQueue.main.async { notes.chooseImage() } }
            Divider()
            Button(L("子笔记")) { notes.createChildNote(of: note.id) }
        } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).fixedSize().help(L("插入")).accessibilityLabel(L("插入")).disabled(notes.readOnly)
    }

    private var noteActions: some View {
        Menu {
            Button(note.favorite ? L("取消收藏") : L("收藏")) { notes.update(note.id) { $0.favorite.toggle() } }
            Toggle(L("敏感 · 不备份"), isOn: Binding(get: { note.sensitive }, set: { value in notes.update(note.id) { $0.sensitive = value } }))
            Divider()
            Button(L("移动到…")) { moving = true }
            Button(note.archived ? L("取消归档") : L("归档")) { notes.update(note.id) { $0.archived.toggle() } }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().help(L("笔记操作")).accessibilityLabel(L("笔记操作")).disabled(notes.readOnly)
    }

    private var commandPanel: some View {
        let snippets = notes.derived(note).snippets
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "curlybraces").foregroundStyle(AtlasStyle.accent)
                Text(L("本笔记代码 · %@", String(snippets.count))).font(.caption.weight(.semibold))
            }
            if snippets.isEmpty {
                Text(L("本笔记的代码块显示在这里，支持一键复制；不会自动加入命令库。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(spacing: 10) { ForEach(snippets) { SnippetRow(snippet: $0, noteTitle: nil) } }
            }
        }.padding(14)
    }

    @ViewBuilder
    private var timestamps: some View {
        Text(String(format: L("创建时间：%@"), String(describing: note.created.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(AppPreferences.shared.locale)))))
        Text(String(format: L("修改时间：%@"), String(describing: note.updated.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(AppPreferences.shared.locale)))))
    }
}

/// 命令片段卡片：主面板右栏与工作台检查器共用，点击整行复制。
struct SnippetRow: View {
    @EnvironmentObject var notes: NotesStore
    let snippet: NoteSnippet
    let noteTitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(snippet.isCommand ? L("命令") : L("代码")).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((snippet.isCommand ? Color.accentColor : Color.purple).opacity(0.15)).clipShape(Capsule())
                Text(snippet.label).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                CopyButton(snippet: snippet).labelStyle(.iconOnly)
            }
            Text(snippet.code.isEmpty ? L("（空）") : snippet.code).font(.system(size: 11, design: .monospaced))
                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                .padding(9).background(AtlasStyle.canvas).clipShape(RoundedRectangle(cornerRadius: 6))
            if let noteTitle { Text(noteTitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .atlasPanel(padding: 10, raised: true)
        .contentShape(Rectangle())
        .onTapGesture { if !snippet.code.isEmpty { notes.copy(snippet) } }
        .help(snippet.code)
    }
}

/// 窗口工作台右侧检查器：不离开当前窗口视图即可搜索、复制所有笔记中的命令。
struct CommandInspector: View {
    @EnvironmentObject var notes: NotesStore
    @State private var text = ""
    let openNotes: () -> Void
    var body: some View {
        let results = notes.searchSnippets(text)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("命令")).font(.headline)
                Spacer()
                Button(L("管理笔记"), action: openNotes).buttonStyle(.borderless).font(.caption)
            }
            TextField(L("搜索命令或说明"), text: $text).textFieldStyle(.roundedBorder)
            if results.isEmpty {
                VStack(spacing: 10) {
                    Text(text.isEmpty ? L("还没有命令。在「命令与笔记」中用代码块记录常用命令。") : L("没有匹配的命令"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if text.isEmpty { Button(L("去记录"), action: openNotes) }
                }.frame(maxWidth: .infinity).padding(.top, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results, id: \.snippet.id) { SnippetRow(snippet: $0.snippet, noteTitle: $0.note.title) }
                    }
                }
            }
            Text(L("点击复制，粘贴到终端由你执行")).font(.caption2).foregroundStyle(.tertiary)
        }.padding(12)
    }
}

/// 备份位置（可多个）、快照恢复与换电脑导出导入。
struct NotesBackupSettings: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var backup: BackupCenter

    private func reportText(_ report: NotesBackup.Report) -> String {
        let time = report.finished.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppPreferences.shared.locale))
        if report.skippedUnchanged { return String(format: L("%@ 内容未变化，未新建快照"), String(describing: time)) }
        var text = String(format: L("%@ 已写入：%@ 篇"), String(describing: time), String(describing: report.noteCount))
        if report.excludedSensitive > 0 { text += String(format: L("，跳过敏感 %@ 篇"), String(describing: report.excludedSensitive)) }
        if !report.removedSnapshots.isEmpty { text += String(format: L("，清理旧快照 %@ 份"), String(describing: report.removedSnapshots.count)) }
        if report.secretWarnings > 0 { text += String(format: L("；%@ 篇未标敏感的笔记含疑似密钥，已按你的选择备份"), String(describing: report.secretWarnings)) }
        if report.missingAttachments > 0 { text += String(format: L("；%@ 个图片缺失未写入"), String(describing: report.missingAttachments)) }
        if !report.quarantinedSnapshots.isEmpty { text += L("；上一份快照已损坏，已标记为 .damaged 保留，并重新写入完整快照") }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L("备份与迁移"), systemImage: "externaldrive.badge.icloud").font(.headline)
                    Spacer()
                    if let busy = backup.busyText { ProgressView().controlSize(.small); Text(busy).font(.caption) }
                }
                if let notice = backup.notice {
                    Text(notice).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }

                Text(L("备份位置")).font(.subheadline.weight(.semibold))
                if backup.targets.isEmpty {
                    Text(L("尚未添加。可同时添加云盘、本地文件夹和移动硬盘。")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(backup.targets) { target in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(target.displayName).font(.callout).lineLimit(1).truncationMode(.middle).help(target.path)
                            Spacer()
                            if backup.running.contains(target.id) { ProgressView().controlSize(.small) }
                            Button(L("立即备份")) { backup.backup(target.id) }.controlSize(.small).disabled(backup.running.contains(target.id))
                            Button { backup.removeTarget(target.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help(L("从列表移除（不删除已有快照）"))
                        }
                        Toggle(L("每 10 分钟自动备份（有变化时）"), isOn: Binding(get: { target.auto }, set: { backup.setAuto(target.id, $0) }))
                            .font(.caption)
                        if let error = backup.errors[target.id] {
                            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        } else if let report = backup.reports[target.id] {
                            Text(reportText(report)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 6) {
                    ForEach(backup.cloud.locations.filter { location in !backup.targets.contains { $0.path == location.url.standardizedFileURL.path } }) { location in
                        Button("＋ " + location.name) { backup.addTarget(location.url) }.controlSize(.small).help(location.url.path)
                    }
                    Button(L("＋ 选择文件夹…")) { backup.chooseTarget() }.controlSize(.small).help(L("本地磁盘、移动硬盘或其他同步目录"))
                }
                if !backup.cloud.iCloudAvailable {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("未检测到 iCloud 云盘。如需使用，请在「系统设置 → Apple 账户 → iCloud」中开启「iCloud 云盘」，再重新打开此面板。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L("打开设置")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") { NSWorkspace.shared.open(url) }
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
                Text(L("云盘位置只表示已写入同步目录，上传何时完成由云盘客户端决定。标记为敏感的笔记不进入备份。每个位置保留最近 20 份快照，更早的每天 1 份，最多 30 天。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Divider()
                Text(L("换电脑迁移")).font(.subheadline.weight(.semibold))
                HStack {
                    Button(L("导出备份文件…")) { backup.exportArchive() }
                    Button(L("导入备份…")) { backup.importArchive() }.disabled(notes.readOnly)
                }.disabled(backup.busyText != nil)
                Text(String(format: L("导出为单个 .zip（含目录结构和图片），导出时可选择是否包含敏感笔记。新电脑上可导入 .zip，或直接选择云盘里的「%@」文件夹。导入按笔记合并，不删除本机已有笔记，导入前自动保存当前笔记库。"), String(describing: NotesBackup.folderName)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Divider()
                HStack {
                    Text(L("快照")).font(.subheadline.weight(.semibold))
                    if backup.targets.count > 1 {
                        Picker("", selection: $backup.browsingTarget) {
                            ForEach(backup.targets) { Text($0.displayName).tag(Optional($0.id)) }
                        }.labelsHidden().frame(maxWidth: 220)
                    }
                    Spacer()
                    Button(L("打开本地笔记库")) { if let url = notes.library?.notesDirectory { NSWorkspace.shared.open(url) } }
                        .buttonStyle(.borderless).font(.caption)
                }
                if backup.snapshots.isEmpty {
                    Text(L("暂无快照")).font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(backup.snapshots.prefix(30)) { snapshot in
                            HStack {
                                Text(snapshot.created.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppPreferences.shared.locale))).font(.callout)
                                Text(snapshot.available ? String(format: L("%@ 篇"), String(describing: snapshot.noteCount)) : L("云端占位，下载中")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("恢复…")) { backup.restore(snapshot) }.buttonStyle(.borderless).font(.caption)
                                    .disabled(!snapshot.available || backup.busyText != nil || notes.readOnly)
                                Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([snapshot.url]) }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
                Text(L("恢复会先校验完整性，确认后按笔记覆盖或新增；备份中没有的本地笔记（含敏感笔记）保留。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let library = notes.library {
                    Button(L("打开恢复前备份")) {
                        try? FileManager.default.createDirectory(at: library.restoreBackupsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(backup.lastRestoreCopy ?? library.restoreBackupsDirectory)
                    }.buttonStyle(.borderless).font(.caption)
                }
            }.padding(18)
        }
        .frame(width: 460, height: 620)
        .onAppear { backup.refreshSnapshots(); backup.refreshCloudLocations() }
        .onChange(of: backup.browsingTarget) { _, _ in backup.refreshSnapshots() }
    }
}
