import AppKit

enum FolderViewMode: String, Codable, CaseIterable {
    case grid, list, split
    var title: String { switch self { case .grid: return L("缩略图"); case .list: return L("列表"); case .split: return L("列表与预览") } }
    var symbol: String { switch self { case .grid: return "square.grid.2x2"; case .list: return "list.bullet"; case .split: return "rectangle.lefthalf.inset.filled" } }
}

enum FolderSort: String, Codable, CaseIterable {
    case name, newest, oldest, activity, tasks, manual
    var title: String { switch self { case .tasks: return L("任务优先"); case .activity: return L("最近内容变化"); case .name: return L("名称"); case .newest: return L("最近发现优先"); case .oldest: return L("最早发现优先"); case .manual: return L("手动排列") } }
}

struct FolderPreferences: Codable, Equatable {
    var mode: FolderViewMode?
    var cardWidth: Double = 320
    var sort: FolderSort = .name
    var showTabs: Bool = true
    /// 「全部窗口」「浏览器」栏目是否显示所有浏览器的标签页；默认显示窗口。
    var aggregateTabs: Bool = false
    /// 拖拽排列后的窗口顺序（窗口编号）。窗口编号在窗口存在期间不变，重启电脑后会重新分配。
    var manualOrder: [CGWindowID] = []
}

// 放在扩展中以保留成员初始化器；旧版本保存的设置没有新字段，缺失时使用默认值，避免整份栏目设置解码失败。
extension FolderPreferences {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(FolderViewMode.self, forKey: .mode)
        cardWidth = try container.decodeIfPresent(Double.self, forKey: .cardWidth) ?? 320
        sort = (try? container.decodeIfPresent(FolderSort.self, forKey: .sort)) ?? .name
        showTabs = try container.decodeIfPresent(Bool.self, forKey: .showTabs) ?? true
        aggregateTabs = try container.decodeIfPresent(Bool.self, forKey: .aggregateTabs) ?? false
        manualOrder = try container.decodeIfPresent([CGWindowID].self, forKey: .manualOrder) ?? []
    }
}

/// 按手动顺序排列；不在顺序中的窗口（新打开的）保持原有相对顺序排在后面。
func applyManualOrder<Item>(_ items: [Item], order: [CGWindowID], id: (Item) -> CGWindowID) -> [Item] {
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return items.enumerated().sorted { lhs, rhs in
        switch (rank[id(lhs.element)], rank[id(rhs.element)]) {
        case let (a?, b?): return a < b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.offset < rhs.offset
        }
    }.map(\.element)
}

/// 把一组窗口移到 target 的位置，组内保持当前显示的先后次序：向后拖放在目标之后，向前拖放在目标之前。
/// displayed 是当前显示的顺序；因搜索或筛选而隐藏、但仍存在的窗口保留在末尾，已关闭的窗口移除。
func movedWindowOrder(displayed: [CGWindowID], stored: [CGWindowID], existing: Set<CGWindowID>,
                      moving: [CGWindowID], to target: CGWindowID) -> [CGWindowID] {
    let moved = Set(moving)
    let group = displayed.filter { moved.contains($0) }
    guard let first = group.first, !moved.contains(target),
          let from = displayed.firstIndex(of: first), let to = displayed.firstIndex(of: target) else { return stored }
    var result = displayed.filter { !moved.contains($0) }
    let insert = result.firstIndex(of: target)! + (from < to ? 1 : 0)
    result.insert(contentsOf: group, at: insert)
    return result + hiddenWindows(displayed: displayed, stored: stored, existing: existing)
}

/// 置顶（toTop）或移到末尾，组内保持当前显示的先后次序。
func edgeWindowOrder(displayed: [CGWindowID], stored: [CGWindowID], existing: Set<CGWindowID>,
                     moving: [CGWindowID], toTop: Bool) -> [CGWindowID] {
    let moved = Set(moving)
    let group = displayed.filter { moved.contains($0) }
    let rest = displayed.filter { !moved.contains($0) }
    return (toTop ? group + rest : rest + group) + hiddenWindows(displayed: displayed, stored: stored, existing: existing)
}

private func hiddenWindows(displayed: [CGWindowID], stored: [CGWindowID], existing: Set<CGWindowID>) -> [CGWindowID] {
    let shown = Set(displayed)
    return stored.filter { !shown.contains($0) && existing.contains($0) }
}

/// Shift 连续选择：从锚点到目标（含两端）；锚点不在当前列表中时只选目标。
func rangeSelection<ID: Hashable>(_ ids: [ID], anchor: ID?, target: ID) -> [ID] {
    guard let anchor, let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: target) else { return [target] }
    return Array(ids[min(start, end)...max(start, end)])
}

struct BrowserTab: Identifiable {
    let appID: String
    let pid: pid_t
    let tabID: String
    let browserWindowID: String
    let windowNumber: Int
    let title: String
    let url: String
    let active: Bool
    let windowFrame: CGRect
    var parentWindowID: CGWindowID?
    var firstSeen: Date = Date()
    /// 标签在所属窗口中的顺序（从 0 开始），用于按浏览器原顺序排列。
    var order = 0
    /// 应用自己显示的原始标题，用于截图时与窗口实时标题比对；为空时用 title。
    var rawTitle = ""
    var id: String { "\(appID):\(pid):\(tabID)" }
    /// 标签画面缓存的键：Chromium 标签 ID 稳定；Safari 标签 ID 是位置序号，改用网址。
    var previewKey: String { "\(appID):\(pid):" + (appID == TabBrowser.safari.rawValue ? url : tabID) }
    var isTerminalTab: Bool { TabBrowser(rawValue: appID)?.isTerminal ?? false }
    /// 占位显示的来源：网页为域名；终端标签为项目文件夹名。
    var host: String {
        if isTerminalTab {
            let path = url.components(separatedBy: " · ").first ?? url
            return path.hasPrefix("~") || path.hasPrefix("/") ? (URL(fileURLWithPath: path).lastPathComponent) : path
        }
        return URL(string: url)?.host ?? url
    }
    /// 所属浏览器与窗口，如「Chrome · 窗口 1」；汇总栏目中可区分来自哪个浏览器。
    var location: String { (TabBrowser(rawValue: appID)?.shortName ?? appID) + " · " + L("窗口 %d", windowNumber) }
}

enum WindowPlacement: String, CaseIterable {
    case left, right, top, bottom, maximize, center, restore
    case northWest, north, northEast, west, middle, east, southWest, south, southEast

    static let grid: [WindowPlacement] = [.northWest, .north, .northEast, .west, .middle, .east, .southWest, .south, .southEast]
    var gridIndex: Int? { Self.grid.firstIndex(of: self) }
    var title: String {
        switch self {
        case .left: return L("左半屏"); case .right: return L("右半屏")
        case .top: return L("上半屏"); case .bottom: return L("下半屏")
        case .maximize: return L("铺满可用屏幕"); case .center: return L("居中")
        case .restore: return L("还原调整前的位置")
        case .northWest: return L("左上"); case .north: return L("上中"); case .northEast: return L("右上")
        case .west: return L("左中"); case .middle: return L("正中"); case .east: return L("右中")
        case .southWest: return L("左下"); case .south: return L("下中"); case .southEast: return L("右下")
        }
    }
}

func placedFrame(_ placement: WindowPlacement, current: CGRect, usable: CGRect) -> CGRect {
    switch placement {
    case .left: return CGRect(x: usable.minX, y: usable.minY, width: usable.width / 2, height: usable.height)
    case .right: return CGRect(x: usable.midX, y: usable.minY, width: usable.width / 2, height: usable.height)
    case .top: return CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: usable.height / 2)
    case .bottom: return CGRect(x: usable.minX, y: usable.midY, width: usable.width, height: usable.height / 2)
    case .maximize: return usable
    case .center:
        let size = CGSize(width: min(current.width, usable.width), height: min(current.height, usable.height))
        return CGRect(x: usable.midX - size.width / 2, y: usable.midY - size.height / 2, width: size.width, height: size.height)
    case .restore: return current
    case .northWest, .north, .northEast, .west, .middle, .east, .southWest, .south, .southEast:
        let index = placement.gridIndex!
        return CGRect(x: usable.minX + CGFloat(index % 3) * usable.width / 3,
            y: usable.minY + CGFloat(index / 3) * usable.height / 3, width: usable.width / 3, height: usable.height / 3)
    }
}

func reorderedAppIDs(_ ids: [String], moving source: String, to target: String) -> [String] {
    guard source != target, let sourceIndex = ids.firstIndex(of: source), let targetIndex = ids.firstIndex(of: target) else { return ids }
    var result = ids
    result.remove(at: sourceIndex)
    result.insert(source, at: targetIndex)
    return result
}

/// 窗口与标签页共用的搜索规则：按空格拆成多个关键词，每个词都要出现在任一字段中（不区分大小写）。
func searchMatches(_ query: String, _ fields: String...) -> Bool {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return true }
    let text = fields.joined(separator: " ")
    return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
}

/// 批量排列选中窗口（最多 9 个）的布局。
enum TileLayout: String, CaseIterable {
    case auto, columns, rows, focusLeft
    static let maxWindows = 9
    var title: String {
        switch self {
        case .auto: return L("自动网格")
        case .columns: return L("左右并排")
        case .rows: return L("上下堆叠")
        case .focusLeft: return L("左侧主窗口")
        }
    }
    var symbol: String {
        switch self {
        case .auto: return "square.grid.3x3"
        case .columns: return "rectangle.split.3x1"
        case .rows: return "rectangle.split.1x2"
        case .focusLeft: return "rectangle.leadinghalf.inset.filled"
        }
    }
}

/// 自动网格的行列数：1 个铺满、2 个左右、3 个三列、4 个 2×2、5～6 个 3×2、7～9 个 3×3。
func autoGrid(_ count: Int) -> (columns: Int, rows: Int) {
    switch count {
    case ...1: return (1, 1)
    case 2: return (2, 1)
    case 3: return (3, 1)
    case 4: return (2, 2)
    case 5...6: return (3, 2)
    default: return (3, 3)
    }
}

/// 计算每个窗口的位置（屏幕坐标，左上角原点），按从左到右、从上到下的顺序；窗口之间留 gap 间距。
func tileFrames(count: Int, layout: TileLayout, usable: CGRect, gap: CGFloat = 8) -> [CGRect] {
    let n = min(max(count, 0), TileLayout.maxWindows)
    guard n > 0 else { return [] }
    func cell(_ area: CGRect, column: Int, row: Int, columns: Int, rows: Int) -> CGRect {
        let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return CGRect(x: area.minX + CGFloat(column) * (width + gap), y: area.minY + CGFloat(row) * (height + gap),
                      width: width, height: height).integral
    }
    switch layout {
    case .auto:
        let grid = autoGrid(n)
        return (0..<n).map { cell(usable, column: $0 % grid.columns, row: $0 / grid.columns, columns: grid.columns, rows: grid.rows) }
    case .columns:
        return (0..<n).map { cell(usable, column: $0, row: 0, columns: n, rows: 1) }
    case .rows:
        return (0..<n).map { cell(usable, column: 0, row: $0, columns: 1, rows: n) }
    case .focusLeft:
        guard n > 1 else { return [usable] }
        let left = cell(usable, column: 0, row: 0, columns: 2, rows: 1)
        let rightArea = cell(usable, column: 1, row: 0, columns: 2, rows: 1)
        return [left] + (0..<(n - 1)).map { cell(rightArea, column: 0, row: $0, columns: 1, rows: n - 1) }
    }
}

