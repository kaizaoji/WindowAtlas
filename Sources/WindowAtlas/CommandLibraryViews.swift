import AppKit
import SwiftUI

/// 完整命令库与工作台快捷面板共用条目，数据不依赖项目笔记。
struct CommandLibraryView: View {
    @EnvironmentObject var library: CommandLibraryStore
    @State private var query = ""
    @State private var tool = "Codex"
    @State private var archived = false
    @State private var editing: CommandEntry?
    @FocusState private var searchFocused: Bool
    var compact = false
    var openLibrary: (() -> Void)?

    private var categories: [String] {
        let custom = Set(library.entries.map(\.tool)).subtracting(["Codex", "Claude Code"])
        return ["Codex", "Claude Code"] + custom.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var results: [CommandEntry] {
        library.filtered(query: query, tool: tool, includeArchived: archived)
            .filter { $0.archived == archived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(L("快捷命令库"), systemImage: "terminal.fill").font(compact ? .headline : .title2.bold())
                Spacer(minLength: 0)
                if let openLibrary {
                    Button(L("管理"), action: openLibrary).buttonStyle(.borderless)
                } else {
                    Button { editing = CommandEntry(title: "", tool: tool, command: "") } label: {
                        Label(L("新建命令"), systemImage: "plus")
                    }.buttonStyle(AtlasHoverButtonStyle(accented: true)).disabled(library.isReadOnly)
                }
            }
            Text(L("独立保存常用 AI 指令；项目笔记的修改不会影响这里。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = library.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { name in
                        Button { tool = name } label: {
                            HStack(spacing: 6) {
                                Text(name)
                                Text("\(library.entries.filter { $0.tool == name && $0.archived == archived }.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(AtlasHoverButtonStyle(accented: tool == name))
                        .accessibilityAddTraits(tool == name ? .isSelected : [])
                    }
                }.padding(.vertical, 2)
            }
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("搜索 %@ 的指令、用途或案例", tool), text: $query)
                        .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L("清除搜索")).accessibilityLabel(L("清除搜索"))
                    }
                }
                .padding(.horizontal, 13).frame(height: compact ? 40 : 44)
                .background(AtlasStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(searchFocused ? AtlasStyle.accent.opacity(0.7) : AtlasStyle.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                if !compact {
                    Toggle(L("已归档"), isOn: $archived).toggleStyle(.button).controlSize(.regular)
                }
            }
            Text(L("收藏在前 · 常用优先")).font(.caption2).foregroundStyle(.secondary)
            if results.isEmpty {
                // 空状态撑满剩余高度，避免整个面板变矮后被外层居中、上下出现大块空白。
                ContentUnavailableView(L("没有匹配的命令"), systemImage: "terminal", description: Text(L("调整筛选，或新建一条自己的 AI 快捷指令。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { entry in
                            CommandLibraryCard(entry: entry, compact: compact, edit: { editing = entry })
                        }
                    }.padding(.vertical, 2)
                }.frame(maxHeight: .infinity)
            }
            Text(L("复制后粘贴到对应 AI 的输入框，由你执行。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 14 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AtlasStyle.canvas)
        .sheet(item: $editing) { entry in
            CommandEditorSheet(entry: entry) { saved in
                tool = saved.tool.trimmingCharacters(in: .whitespacesAndNewlines)
                archived = saved.archived
                query = ""
            }.environmentObject(library)
        }
        .onChange(of: categories) { _, names in
            if !names.contains(tool) { tool = names.first ?? "Codex" }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WindowAtlas.focusSearch"))) { _ in
            if !compact { searchFocused = true }
        }
    }
}

private struct CommandLibraryCard: View {
    @EnvironmentObject var library: CommandLibraryStore
    let entry: CommandEntry
    let compact: Bool
    let edit: () -> Void
    @State private var expanded = false
    @State private var copied = ""
    @State private var commandHovered = false

    private func copy(_ text: String, label: String) {
        copied = ""
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            copied = L("复制失败，请重试")
            return
        }
        copied = label
        if !library.isReadOnly && !library.recordUse(entry.id) { copied = L("已复制，使用次数未保存") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(entry.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { library.toggleFavorite(entry.id) } label: {
                    Image(systemName: entry.favorite ? "star.fill" : "star").foregroundStyle(entry.favorite ? AtlasStyle.accent : .secondary)
                }.buttonStyle(.borderless).help(entry.favorite ? L("取消收藏") : L("收藏"))
                    .accessibilityLabel(entry.favorite ? L("取消收藏") : L("收藏")).disabled(library.isReadOnly)
                Menu {
                    Button(L("编辑"), action: edit)
                    Button(entry.archived ? L("取消归档") : L("归档")) {
                        if entry.archived { library.restore(entry.id) } else { library.archive(entry.id) }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .help(L("命令操作")).accessibilityLabel(L("命令操作")).disabled(library.isReadOnly)
            }
            if !entry.purpose.isEmpty { Text(entry.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack(alignment: .top, spacing: 8) {
                Button { copy(entry.command, label: L("已复制指令")) } label: {
                    Text(entry.command).font(.system(size: 13, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10).padding(.leading, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("点击命令即可复制"))
                .accessibilityLabel(L("复制指令") + ": " + entry.command)
                .onHover { commandHovered = $0 }
                Button { copy(entry.command, label: L("已复制指令")) } label: {
                    if compact {
                        Image(systemName: "doc.on.doc").frame(width: 18, height: 18)
                    } else {
                        Label(L("复制指令"), systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(AtlasHoverButtonStyle(accented: true))
                .help(L("复制指令")).accessibilityLabel(L("复制指令"))
                .fixedSize().padding(4)
            }
            .background(commandHovered ? AtlasStyle.accent.opacity(0.12) : AtlasStyle.raised,
                        in: RoundedRectangle(cornerRadius: 8))
            if !copied.isEmpty {
                Text(copied).font(.caption).foregroundStyle(AtlasStyle.accent)
            }
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    Text(L("用途说明与案例"))
                    Spacer(minLength: 0)
                    Text(expanded ? L("收起") : L("展开")).foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("用途说明与案例"))
            .accessibilityValue(expanded ? L("已展开") : L("已收起"))
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    detail(L("用途"), text: entry.purpose)
                    detail(L("说明"), text: entry.notes)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("案例")).font(.caption.weight(.semibold))
                            Spacer()
                            if !entry.example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button(L("复制案例")) { copy(entry.example, label: L("已复制案例")) }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                        Text(entry.example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("尚未填写，可在编辑中补充。") : entry.example)
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(AtlasStyle.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let url = entry.sourceURL { Link(L("来源说明"), destination: url).font(.caption) }
                    Text(L("已复制 %d 次", entry.useCount)).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
        }.atlasPanel(padding: 12)
    }

    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("尚未填写，可在编辑中补充。") : text)
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CommandEditorSheet: View {
    @EnvironmentObject var library: CommandLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var entry: CommandEntry
    var onSave: (CommandEntry) -> Void
    @State private var source = ""
    @State private var validation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("编辑快捷命令")).font(.title2.bold())
            Text(L("所属 AI 可自行填写，例如 Codex、Claude Code 或其他工具。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field(L("名称"), text: $entry.title)
                    field(L("所属 AI"), text: $entry.tool)
                    field(L("用途"), text: $entry.purpose)
                    multiline(L("指令"), text: $entry.command, height: 70)
                    multiline(L("案例"), text: $entry.example, height: 90)
                    multiline(L("说明"), text: $entry.notes, height: 80)
                    field(L("官方说明网址（可选）"), text: $source)
                }
            }
            if !validation.isEmpty { Text(validation).font(.caption).foregroundStyle(.red) }
            if let error = library.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("保存")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(library.isReadOnly || entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 500, height: 620).background(AtlasStyle.surface)
            .onAppear { source = entry.sourceURL?.absoluteString ?? ""; library.beginEditing() }
            .onDisappear { library.endEditing() }
            .interactiveDismissDisabled()
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption.weight(.semibold)); TextField(title, text: text).textFieldStyle(.roundedBorder) }
    }
    private func multiline(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            TextEditor(text: text).font(.system(size: 12, design: .monospaced)).frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AtlasStyle.border)).accessibilityLabel(title)
        }
    }
    private func save() {
        validation = ""
        let address = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { entry.sourceURL = nil }
        else if let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { entry.sourceURL = url }
        else { validation = L("请填写有效的 http 或 https 网址。"); return }
        if library.save(entry) { onSave(entry); dismiss() }
    }
}
