import SwiftUI
import AppKit

struct FolderControls: View {
    @EnvironmentObject var store: WindowStore
    private func viewControls(compact: Bool = false) -> some View {
        HStack(spacing: 10) {
            // 尺寸滑块与排序放在最左侧：切换排列方式时滑块出现或消失，不会挤动右侧按钮。
            if store.viewMode == .grid && !compact {
                Slider(value: $store.cardWidth, in: 220...560).frame(width: 74)
                    .accessibilityLabel(L("缩略图大小")).help(L("调整当前栏目的缩略图尺寸"))
            }
            Menu {
                Picker(L("排序"), selection: Binding(get: { store.sortMode }, set: { store.sortMode = $0 })) {
                    ForEach(FolderSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).frame(width: 26)
                .help(L("排序") + " · " + store.sortMode.title).accessibilityLabel(L("排序"))
            if store.isTabFolder {
                HStack(spacing: 3) {
                    browserContentButton(showTabs: true)
                    browserContentButton(showTabs: false)
                }.padding(3).background(AtlasStyle.raised, in: RoundedRectangle(cornerRadius: 9))
                if !store.browserEnabled {
                    // 未开启时直接给出入口，在「窗口」视图下也能看到。
                    Button { store.enableBrowserTabs() } label: { Label(L("读取标签页"), systemImage: "arrow.down.doc") }
                        .buttonStyle(.borderedProminent).help(L("读取 %@ 标签页", store.tabFolderName))
                } else {
                    Menu {
                        Button(L("重新读取标签页")) { Task { await store.refreshBrowserTabs() } }
                        if let browser = store.currentTabBrowser {
                            Button(L("停止读取 %@ 标签页", browser.name)) { store.disableBrowserTabs() }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 24).help(L("标签页操作"))
                }
            }
            HStack(spacing: 3) {
                ForEach(FolderViewMode.allCases, id: \.self) { mode in
                    Button { store.viewMode = mode } label: {
                        Image(systemName: mode.symbol).font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 26)
                            .foregroundStyle(store.viewMode == mode ? AtlasStyle.accent : Color.secondary)
                            .background(store.viewMode == mode ? AtlasStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help(mode.title).accessibilityLabel(mode.title)
                        .accessibilityAddTraits(store.viewMode == mode ? .isSelected : [])
                }
            }.padding(3).background(AtlasStyle.raised, in: RoundedRectangle(cornerRadius: 9))
        }.controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }
    private func browserContentButton(showTabs: Bool) -> some View {
        let selected = store.showingTabs == showTabs
        let title = L(showTabs ? "标签页" : "窗口")
        return Button {
            // 明确切换内容时恢复当前栏目范围，避免全局搜索强制显示窗口。
            store.searchAll = false
            store.setShowTabs(showTabs)
        } label: {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 11).frame(height: 26)
                .foregroundStyle(selected ? AtlasStyle.accent : Color.secondary)
                .background(selected ? AtlasStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(L(showTabs ? "查看 %@ 标签页；搜索范围切换为当前栏目" : "查看 %@ 窗口；搜索范围切换为当前栏目", store.tabFolderName))
    }
    private var filterControls: some View {
        HStack(spacing: 8) {
            TerminalTaskControls()
            if !store.query.isEmpty || store.taskOnly || store.searchAll {
                Button {
                    store.query = ""; store.taskOnly = false; store.searchAll = false
                } label: { Image(systemName: "line.3.horizontal.decrease.circle.badge.xmark") }
                    .buttonStyle(.plain).foregroundStyle(AtlasStyle.accent)
                    .help(L("清除筛选")).accessibilityLabel(L("清除筛选"))
            }
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterControls
                Spacer(minLength: 12)
                viewControls()
            }
            VStack(alignment: .leading, spacing: 10) {
                filterControls
                HStack { Spacer(minLength: 0); viewControls(compact: true) }
            }
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }
}

struct ObservedTime: View {
    @Environment(\.locale) private var locale
    let date: Date
    var body: some View {
        Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .help(L("首次被窗口图鉴发现：") + date.formatted(Date.FormatStyle(date: .complete, time: .standard).locale(locale)))
    }
}

struct WindowFolderView: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        Group {
            switch store.viewMode {
            case .grid:
                GeometryReader { geometry in
                    // 筛选与排序每次渲染只算一次。
                    let items = store.filtered
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: min(store.cardWidth, max(1, geometry.size.width - 48))), spacing: 12)], spacing: 12) {
                            ForEach(items) { item in WindowCard(item: item).id(item.id) }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                    }.modifier(ListKeyboardNavigation(ids: items.map(\.id), selection: $store.selectedWindowID,
                        columns: windowGridColumns(width: geometry.size.width, cardWidth: store.cardWidth)) { id in
                        if let item = items.first(where: { $0.id == id }) { store.focus(item) }
                    })
                }
            case .list: WindowListView()
            case .split:
                GeometryReader { geometry in
                    if geometry.size.width >= 740 {
                        HSplitView {
                            WindowListView().frame(minWidth: 360)
                            if let item = store.filtered.first(where: { $0.id == store.selectedWindowID }) ?? store.filtered.first {
                                WindowInspector(item: item).frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                            }
                        }
                    } else {
                        WindowListView()
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { if store.markedWindowIDs.count > 1 { WindowSelectionBar() } }
    }
}

/// 多选时的浮动操作条：置顶、移到末尾、取消选择（Esc）。
struct WindowSelectionBar: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AtlasStyle.accent)
            Text(L("已选 %d 个窗口", store.orderedSelection.count)).font(.callout.weight(.semibold)).monospacedDigit()
            Divider().frame(height: 16)
            Button { store.moveWindowsToEdge(store.orderedSelection, top: true) } label: { Label(L("置顶排列"), systemImage: "arrow.up.to.line") }
            Button { store.moveWindowsToEdge(store.orderedSelection, top: false) } label: { Label(L("移到末尾"), systemImage: "arrow.down.to.line") }
            Divider().frame(height: 16)
            TileLayoutMenu(ids: store.orderedSelection)
            Button(L("取消选择")) { store.clearWindowSelection() }.keyboardShortcut(.cancelAction)
        }.buttonStyle(.borderless).controlSize(.small)
            .fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(AtlasStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AtlasStyle.border))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.bottom, 16)
    }
}

struct WindowListView: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        GeometryReader { geometry in
        let showDetails = store.viewMode != .split && geometry.size.width >= 840
        let showTime = geometry.size.width >= 580
        let showStatus = geometry.size.width >= 460
        let items = store.filtered
        VStack(spacing: 0) {
            HStack {
                Text(L("窗口名称")).frame(maxWidth: .infinity, alignment: .leading)
                if showDetails {
                    Text(L("应用")).frame(width: 85, alignment: .leading)
                    Text(L("显示位置")).frame(width: 160, alignment: .leading)
                }
                if showStatus { Text(L("状态")).frame(width: 120, alignment: .leading) }
                if showTime { Text(L("首次发现")).frame(width: 145, alignment: .leading) }
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            AppIcon(image: item.icon, size: 24)
                            Text(item.title).lineLimit(1).help(item.title).frame(maxWidth: .infinity, alignment: .leading)
                            if showDetails {
                                Text(item.appName).lineLimit(1).font(.caption).foregroundStyle(.secondary).frame(width: 85, alignment: .leading)
                                Text(store.locationLabel(item)).lineLimit(1).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                            }
                            if let mark = store.arrangedWindows[item.id] { ArrangedBadge(mark: mark) }
                            if showStatus { ActivityBadge(item: item, compact: true).frame(width: 120, alignment: .leading) }
                            if showTime { ObservedTime(date: item.firstSeen).frame(width: 145, alignment: .leading) }
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                            .background(store.isWindowSelected(item.id) || store.recentlyMovedWindowIDs.contains(item.id) ? Color.accentColor.opacity(0.14) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { store.focus(item) }
                            .onTapGesture { store.click(item) }
                            .id(item.id)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(store.isWindowSelected(item.id) ? .isSelected : [])
                            .windowContextMenu(item: item, store: store)
                            .windowReordering(item: item, store: store)
                            .onAppear { store.markVisible(item.id, visible: true); store.requestCapture() }
                            .onDisappear { store.markVisible(item.id, visible: false) }
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }.modifier(ListKeyboardNavigation(ids: items.map(\.id), selection: $store.selectedWindowID) { id in
            if let item = items.first(where: { $0.id == id }) { store.focus(item) }
        }).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WindowInspector: View {
    @EnvironmentObject var store: WindowStore
    let item: WindowItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    WindowPreviewImage(preview: store.preview(item.id)) { AppIcon(image: item.icon, size: 64).frame(maxWidth: .infinity, minHeight: 180) }
                }.frame(maxWidth: .infinity).background(Color(nsColor: .underPageBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.title).font(.headline).textSelection(.enabled)
                ActivityBadge(item: item)
                Text(item.isTerminal ? L("任务状态根据终端会话和进程判断，与窗口是否显示无关。AI 会话运行中不等于正在生成。") : L("状态根据窗口内容变化判断；无变化不代表任务停止。"))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("应用"), value: item.appName)
                LabeledContent(L("显示位置"), value: store.locationLabel(item))
                LabeledContent(L("尺寸"), value: "\(Int(item.frame.width)) × \(Int(item.frame.height))")
                LabeledContent(L("首次发现")) { ObservedTime(date: item.firstSeen) }
                Button(L("打开原窗口")) { store.focus(item) }.buttonStyle(.borderedProminent)
                Text(L("右键可关闭、最小化或调整显示位置")).font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.windowContextMenu(item: item, store: store)
            .onAppear { store.markVisible(item.id, visible: true); store.requestCapture() }
            .onDisappear { store.markVisible(item.id, visible: false) }
            .id(item.id)
    }
}

/// Chrome / Edge / Safari 栏目的标签页视图（沿用最初只支持 Chrome 时的类型名）。
struct ChromeFolderView: View {
    @EnvironmentObject var store: WindowStore
    private var browserName: String { store.tabFolderName }
    var body: some View {
        VStack(spacing: 0) {
            if let message = store.browserError {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(L("自动化设置")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                    }
                    Button(L("重试")) { store.enableBrowserTabs() }
                }.padding(12).background(Color.orange.opacity(0.08))
            }
            if !store.browserEnabled {
                ContentUnavailableView {
                    Label(L("展开 %@ 的所有标签页", browserName), systemImage: "rectangle.on.rectangle")
                } description: {
                    Text(L("允许自动化访问后，可按名称、网址、所属窗口和首次发现时间管理标签页。标签较多时默认使用列表。"))
                } actions: {
                    Button(L("读取 %@ 标签页", browserName)) { store.enableBrowserTabs() }.buttonStyle(.borderedProminent)
                }
            } else if store.filteredTabs.isEmpty {
                ContentUnavailableView {
                    Label(store.browserLoading ? L("正在读取标签页…") : L("尚未读取到标签页"), systemImage: "globe")
                } description: {
                    Text(store.query.isEmpty ? L("点击重新读取；也可以切到窗口视图查看 %@。", browserName) : L("请调整搜索词。"))
                } actions: {
                    Button(L("重新读取标签页")) { Task { await store.refreshBrowserTabs() } }.disabled(store.browserLoading)
                }
            } else {
                switch store.viewMode {
                case .list: ChromeTabList()
                case .grid:
                    GeometryReader { geometry in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: min(store.cardWidth, max(1, geometry.size.width - 48))), spacing: 12)], spacing: 12) {
                            ForEach(store.filteredTabs) { tab in
                                Button { store.clickTab(tab) } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        TabPreview(tab: tab, cache: store.tabSnapshots)
                                        Divider()
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(tab.title).font(.system(size: 13, weight: .semibold)).lineLimit(2, reservesSpace: true)
                                            Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            HStack { Text(tab.location).font(.caption); Spacer(); ObservedTime(date: tab.firstSeen) }
                                                .foregroundStyle(.secondary)
                                        }.padding(12)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .background(AtlasStyle.surface).clipShape(RoundedRectangle(cornerRadius: AtlasStyle.radius))
                                        .overlay(RoundedRectangle(cornerRadius: AtlasStyle.radius).stroke(AtlasStyle.border))
                                }.buttonStyle(.plain)
                                    // 当前标签的预览来自所属窗口，需让该窗口参与截图。
                                    .onAppear { if let id = tab.parentWindowID { store.markVisible(id, visible: true); store.requestCapture() } }
                                    .onDisappear { if let id = tab.parentWindowID { store.markVisible(id, visible: false) } }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { store.actOnTab(tab) })
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.isTabSelected(tab.id) ? AtlasStyle.accent : .clear, lineWidth: 2))
                                    .overlay(alignment: .topLeading) {
                                        if !store.markedTabIDs.isEmpty && store.isTabSelected(tab.id) {
                                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                                                .symbolRenderingMode(.palette).foregroundStyle(.white, AtlasStyle.accent).padding(9)
                                        }
                                    }
                                    .accessibilityAddTraits(store.isTabSelected(tab.id) ? .isSelected : [])
                                    .id(tab.id).contextMenu { ChromeTabActions(tab: tab) }
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                    }.modifier(ListKeyboardNavigation(ids: store.filteredTabs.map(\.id), selection: $store.selectedTabID,
                        columns: windowGridColumns(width: geometry.size.width, cardWidth: store.cardWidth)) { id in
                        if let tab = store.filteredTabs.first(where: { $0.id == id }) { store.actOnTab(tab) }
                    })
                    }
                case .split:
                    GeometryReader { geometry in
                        if geometry.size.width >= 740 {
                            HSplitView {
                                ChromeTabList().frame(minWidth: 360)
                                if let tab = store.filteredTabs.first(where: { $0.id == store.selectedTabID }) ?? store.filteredTabs.first {
                                    ChromeTabInspector(tab: tab).frame(minWidth: 250, idealWidth: 320, maxWidth: 500)
                                }
                            }
                        } else {
                            ChromeTabList()
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { if store.markedTabIDs.count > 1 { TabSelectionBar() } }
    }
}

/// 标签多选时的浮动操作条：排列所在窗口，或把 Chrome / Edge 标签拆成独立窗口再排列。
struct TabSelectionBar: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        let tabs = store.orderedTabSelection
        let parents = store.parentWindows(of: tabs)
        let canSplit = tabs.contains { TabBrowser(rawValue: $0.appID)?.isChromium ?? false }
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AtlasStyle.accent)
            Text(L("已选 %d 个标签", tabs.count)).font(.callout.weight(.semibold)).monospacedDigit()
            Text(L("（%d 个窗口）", parents.count)).font(.caption).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            TileLayoutMenu(ids: parents, title: L("排列所在窗口"))
            if canSplit {
                Menu {
                    if tabs.count > TileLayout.maxWindows {
                        Text(L("一次最多排列 %d 个窗口，请减少选择。", TileLayout.maxWindows))
                    } else {
                        ForEach(TileLayout.allCases, id: \.self) { layout in
                            Button { store.splitTabsAndTile(tabs, layout: layout) } label: { Label(layout.title, systemImage: layout.symbol) }
                        }
                        if NSScreen.screens.count > 1 {
                            Menu(L("按各自所在的显示器排列")) {
                                ForEach(TileLayout.allCases, id: \.self) { layout in
                                    Button(layout.title) { store.splitTabsAndTile(tabs, layout: layout, perDisplay: true) }
                                }
                            }
                        }
                    }
                } label: { Label(L("拆成独立窗口再排列"), systemImage: "rectangle.split.2x2") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("Chrome、Edge 的标签各自移到新窗口（页面不刷新）后再排列；终端标签排列所在窗口"))
            }
            Button(L("取消选择")) { store.clearTabSelection() }.keyboardShortcut(.cancelAction)
        }.buttonStyle(.borderless).controlSize(.small)
            .fixedSize()
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(AtlasStyle.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AtlasStyle.border))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.bottom, 16)
    }
}

struct ChromeTabActions: View {
    @EnvironmentObject var store: WindowStore
    let tab: BrowserTab
    var body: some View {
        Button(L("切换到标签页"), systemImage: "arrow.up.forward.app") { store.actOnTab(tab) }
        if !tab.isTerminalTab {
            Button(L("拷贝网址"), systemImage: "link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tab.url, forType: .string) }
        }
        if let parent = store.windows.first(where: { $0.id == tab.parentWindowID }) {
            Menu(L("所在窗口")) {
                Button(L("切换到窗口")) { store.focus(parent) }
                Menu(L("窗口显示位置")) {
                    ForEach(WindowPlacement.allCases, id: \.self) { placement in
                        Button(placement.title) { Task { await store.performWindowAction(parent, action: .place(placement, nil)) } }
                    }
                }
                Button(L("最小化")) { Task { await store.performWindowAction(parent, action: .minimize) } }
            }
        }
        // 终端标签不提供关闭，避免误中断正在运行的会话。
        if !tab.isTerminalTab {
            Divider()
            Button(L("关闭标签页"), systemImage: "xmark", role: .destructive) { store.actOnTab(tab, close: true) }
        }
    }
}

struct ChromeTabList: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        GeometryReader { geometry in
        let showTime = geometry.size.width >= 580
        VStack(spacing: 0) {
            HStack {
                Text(L("标签页名称 / 网址")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("所属窗口")).frame(width: 100, alignment: .leading)
                if showTime { Text(L("首次发现")).frame(width: 145, alignment: .leading) }
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.filteredTabs) { tab in
                        HStack(spacing: 10) {
                            Image(systemName: "globe").foregroundStyle(tab.active ? Color.accentColor : Color.secondary).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tab.title).lineLimit(1).help(tab.title)
                                Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(tab.url)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tab.location).font(.caption)
                                if tab.active { Text(L("当前标签")).font(.caption2).foregroundStyle(.green) }
                            }.frame(width: 100, alignment: .leading)
                            if showTime { ObservedTime(date: tab.firstSeen).frame(width: 145, alignment: .leading) }
                        }.padding(.horizontal, 16).padding(.vertical, 11)
                            .background(store.isTabSelected(tab.id) ? Color.accentColor.opacity(0.14) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { store.actOnTab(tab) }
                            .onTapGesture { store.clickTab(tab) }
                            .id(tab.id)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(store.isTabSelected(tab.id) ? .isSelected : [])
                            .contextMenu { ChromeTabActions(tab: tab) }
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }.modifier(ListKeyboardNavigation(ids: store.filteredTabs.map(\.id), selection: $store.selectedTabID) { id in
            if let tab = store.filteredTabs.first(where: { $0.id == id }) { store.actOnTab(tab) }
        })
        }
    }
}

struct ChromeTabInspector: View {
    @EnvironmentObject var store: WindowStore
    let tab: BrowserTab
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "globe").font(.system(size: 44)).foregroundStyle(Color.accentColor).padding(.vertical, 20)
                Text(tab.title).font(.headline).textSelection(.enabled)
                Text(tab.url).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent(L("所属窗口"), value: tab.location)
                LabeledContent(L("状态"), value: tab.active ? L("所在窗口的当前标签") : L("后台标签"))
                LabeledContent(L("首次发现")) { ObservedTime(date: tab.firstSeen) }
                Button(L("打开此标签页")) { store.actOnTab(tab) }.buttonStyle(.borderedProminent)
                if let id = tab.parentWindowID { ParentWindowPreviewSection(preview: store.preview(id)) }
            }.padding(20)
        }.contextMenu { ChromeTabActions(tab: tab) }
            .onAppear { if let id = tab.parentWindowID { store.markVisible(id, visible: true); store.requestCapture() } }
            .onDisappear { if let id = tab.parentWindowID { store.markVisible(id, visible: false) } }
            .id(tab.id)
    }
}

/// 标签页所在窗口的预览说明；预览图到达前不显示这一段。
struct ParentWindowPreviewSection: View {
    @ObservedObject var preview: WindowPreview
    var body: some View {
        if let image = preview.image {
            Divider()
            Text(L("所在窗口预览")).font(.caption).foregroundStyle(.secondary)
            Image(nsImage: image).resizable().scaledToFit()
            Text(L("预览为窗口当前内容；后台标签不会自动切换以抓取截图。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 标签卡片的预览：当前标签显示所属窗口的实时画面；后台标签显示最近一次的画面（标注「上次查看」）；
/// 从未显示过的后台标签显示网站域名占位。浏览器不绘制后台标签，无法在不切换标签的情况下截取。
struct TabPreview: View {
    @EnvironmentObject var store: WindowStore
    let tab: BrowserTab
    @ObservedObject var cache: TabSnapshotCache
    var body: some View {
        let cached = cache.images[tab.previewKey]
        ZStack {
            AtlasStyle.canvas
            if tab.active, let parent = tab.parentWindowID {
                WindowPreviewImage(preview: store.preview(parent), padding: 5) { snapshotOrPlaceholder(cached) }
            } else {
                snapshotOrPlaceholder(cached)
            }
        }
        .aspectRatio(1.65, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if tab.active || cached != nil {
                Text(tab.active ? L("当前标签") : L("上次查看"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tab.active ? Color.green : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(AtlasStyle.surface.opacity(0.94), in: Capsule())
                    .padding(9)
            }
        }
        .clipped()
    }

    @ViewBuilder private func snapshotOrPlaceholder(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.medium).scaledToFit().padding(5)
                .opacity(tab.active ? 1 : 0.85)
        } else {
            VStack(spacing: 8) {
                Image(systemName: tab.isTerminalTab ? "terminal" : "globe").font(.system(size: 30)).foregroundStyle(AtlasStyle.accent.opacity(0.8))
                Text(tab.host).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 12)
                Text(L("切到此标签后显示预览")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// 「排列窗口」菜单：选择布局与显示器，一键把选中的窗口（最多 9 个）铺开。
struct TileLayoutMenu: View {
    @EnvironmentObject var store: WindowStore
    let ids: [CGWindowID]
    var title = L("排列窗口")
    var body: some View {
        let tooMany = ids.count > TileLayout.maxWindows
        Menu {
            if tooMany {
                Text(L("一次最多排列 %d 个窗口，请减少选择。", TileLayout.maxWindows))
            } else {
                Section(L("排在第一个窗口所在的显示器")) {
                    ForEach(TileLayout.allCases, id: \.self) { layout in
                        Button { store.tileWindows(ids, layout: layout) } label: { Label(layout.title, systemImage: layout.symbol) }
                    }
                }
                if NSScreen.screens.count > 1 {
                    Menu(L("按各自所在的显示器排列")) {
                        ForEach(TileLayout.allCases, id: \.self) { layout in
                            Button(layout.title) { store.tileWindows(ids, layout: layout, perDisplay: true) }
                        }
                    }
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                        Menu(L("排到显示器 %d · %@", index + 1, screen.localizedName)) {
                            ForEach(TileLayout.allCases, id: \.self) { layout in
                                Button(layout.title) { store.tileWindows(ids, layout: layout, displayID: screen.atlasDisplayID) }
                            }
                        }
                    }
                }
            }
        } label: { Label(title, systemImage: "square.grid.3x3") }
            .menuStyle(.borderlessButton).fixedSize()
            .help(tooMany ? L("一次最多排列 %d 个窗口，请减少选择。", TileLayout.maxWindows) : L("把选中的窗口一键铺到屏幕上"))
    }
}

