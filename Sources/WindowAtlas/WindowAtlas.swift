import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScreenCaptureKit
import ApplicationServices

struct WindowItem: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appID: String
    let appName: String
    let title: String
    let frame: CGRect
    let icon: NSImage?
    var firstSeen = Date()
    var isOnScreen = false
    /// 位于其他桌面空间（Space）的窗口：无法实时预览，点击时先切换到所在桌面。
    var onOtherSpace = false
    var savedKey: String { appID + "|" + title }
    var isTerminal: Bool {
        ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.cmuxterm.app", "dev.warp.Warp-Stable"].contains(appID)
        || appName.localizedCaseInsensitiveContains("terminal") || appName.localizedCaseInsensitiveContains("cmux")
    }
    var isBrowser: Bool {
        ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser"].contains(appID)
    }
}

/// 单个窗口的预览图与内容变化状态。按窗口独立发布：一张缩略图更新只重绘对应卡片，不让整个看板重算。
@MainActor
final class WindowPreview: ObservableObject {
    @Published var image: NSImage?
    @Published var activity: ActivityObservation?
}

/// 后台标签最近一次显示时的画面，只保存在内存。单独发布，更新时只重绘标签卡片。
/// 为控制内存：画面缩小到最宽 480 像素（约 0.6 MB），最多保留 80 张，超出时先丢弃最早存入的。
@MainActor
final class TabSnapshotCache: ObservableObject {
    static let limit = 80
    static let maxWidth = 480
    @Published var images: [String: NSImage] = [:]
    private var order: [String] = []

    func store(_ image: CGImage, for key: String) {
        guard let scaled = Self.downscale(image) else { return }
        images[key] = NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit { images.removeValue(forKey: order.removeFirst()) }
    }

    func retain(_ keys: Set<String>) {
        guard images.keys.contains(where: { !keys.contains($0) }) else { return }
        images = images.filter { keys.contains($0.key) }
        order.removeAll { !keys.contains($0) }
    }

    static func downscale(_ image: CGImage) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let width = maxWidth, height = max(1, image.height * maxWidth / image.width)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// 底栏的刷新状态单独发布，避免每 6 秒的刷新开始/结束让整个看板重算。
@MainActor
final class RefreshStatus: ObservableObject {
    @Published var refreshing = false
    @Published var lastRefresh: Date?
}

@MainActor
final class WindowStore: ObservableObject {
    @Published var windows: [WindowItem] = []
    private var previews: [CGWindowID: WindowPreview] = [:]
    /// 供排序读取；变化通过 WindowPreview 发布，不经过整个 Store。
    private(set) var activity: [CGWindowID: ActivityObservation] = [:]
    let refreshStatus = RefreshStatus()
    let tabSnapshots = TabSnapshotCache()
    @Published var selection = "all" {
        didSet { if selection != oldValue { query = ""; taskOnly = false; selectedWindowID = nil; selectedTabID = nil; recentlyMovedWindowIDs = [] } }
    }
    @Published var appOrder = UserDefaults.standard.stringArray(forKey: "appOrder") ?? [] {
        didSet { UserDefaults.standard.set(appOrder, forKey: "appOrder") }
    }
    @Published var query = ""
    @Published var searchAll = false
    @Published var terminalStatuses: [CGWindowID: TerminalTaskStatus] = [:]
    @Published var terminalEnabled = Set(UserDefaults.standard.stringArray(forKey: "terminalTaskApps") ?? [])
    @Published var terminalErrors: [String: String] = [:]
    @Published var taskOnly = false
    var terminalFetching = false
    var terminalPreviousCPU: [Int: Double] = [:]
    @Published var folderPreferences: [String: FolderPreferences] = {
        guard let data = UserDefaults.standard.data(forKey: "folderPreferences"),
              let value = try? JSONDecoder().decode([String: FolderPreferences].self, from: data) else { return [:] }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(folderPreferences) { UserDefaults.standard.set(data, forKey: "folderPreferences") } }
    }
    @Published var selectedWindowID: CGWindowID? {
        // 方向键、Esc 或普通单击移动光标到多选之外时，结束多选。
        didSet { if selectedWindowID.map({ !markedWindowIDs.contains($0) }) ?? true, !markedWindowIDs.isEmpty { markedWindowIDs = [] } }
    }
    /// 置顶 / 移到末尾后高亮刚移动的窗口（只显示边框），下一次点击或选择变化时清除。
    @Published var recentlyMovedWindowIDs: Set<CGWindowID> = []
    /// Shift / ⌥ / ⌘ 多选的窗口；为空时以 selectedWindowID 作为单选。
    @Published var markedWindowIDs: Set<CGWindowID> = []
    private var selectionAnchor: CGWindowID?
    @Published var selectedTabID: String?
    @Published var browserTabs: [BrowserTab] = []
    /// 已开启标签读取的浏览器（按 Bundle ID）。旧版只支持 Chrome，开关 chromeTabsEnabled 首次启动时迁移进来。
    @Published var browserTabApps: Set<String> = {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: "browserTabApps") { return Set(saved) }
        return defaults.bool(forKey: "chromeTabsEnabled") ? [TabBrowser.chrome.rawValue] : []
    }() {
        didSet { UserDefaults.standard.set(Array(browserTabApps).sorted(), forKey: "browserTabApps") }
    }
    @Published var browserErrors: [String: String] = [:]
    @Published var browserLoadingApps: Set<String> = []
    var observedTimes = UserDefaults.standard.dictionary(forKey: "observedTimes") as? [String: Double] ?? [:]
    var originalFrames: [CGWindowID: CGRect] = [:]
    var closedTargets: [CGWindowID: (pid: pid_t, element: AXUIElement)] = [:]
    var staleWindowIDs: Set<CGWindowID> = []
    var browserRefreshRequest = BrowserRefreshRequest()
    var lastTabRefresh = Date.distantPast
    var folder: FolderPreferences { folderPreferences[selection] ?? FolderPreferences() }
    var cardWidth: Double {
        get { folder.cardWidth }
        set { var f = folder; f.cardWidth = newValue; folderPreferences[selection] = f }
    }
    var viewMode: FolderViewMode {
        get { folder.mode ?? (showingTabs && filteredTabs.count >= 8 ? .list : .grid) }
        set { var f = folder; f.mode = newValue; folderPreferences[selection] = f }
    }
    var sortMode: FolderSort {
        get { folder.sort }
        set { var f = folder; f.sort = newValue; folderPreferences[selection] = f }
    }
    var showingTabs: Bool {
        guard isTabFolder, !(searchAll && !query.isEmpty) else { return false }
        return currentTabBrowser != nil ? folder.showTabs : folder.aggregateTabs
    }
    var displayCount: Int { showingTabs ? filteredTabs.count : filtered.count }
    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var accessAllowed = AXIsProcessTrusted()
    @Published var errorMessage: String?
    @Published var pinned = false
    @Published var sidebarShown = false
    private var captureWindows: [CGWindowID: SCWindow] = [:]
    private var visibleCounts: [CGWindowID: Int] = [:]
    private var timer: Timer?
    private var capturing = false
    private var captureAgain = false
    private var captureRequest: Task<Void, Never>?
    private var lastCaptured: [CGWindowID: Date] = [:]
    private var refreshingList = false
    private var panel: NSPanel?
    weak var mainWindow: NSWindow?
    /// 正在拖拽排列的窗口（多选时为一组）；只在拖放过程中使用，不需要触发界面刷新。
    var draggingWindowIDs: [CGWindowID] = []

    var apps: [(id: String, name: String, count: Int, icon: NSImage?)] {
        Dictionary(grouping: windows, by: \.appID).map { key, values in
            (id: key, name: values[0].appName, count: values.count, icon: values[0].icon)
        }.sorted {
            let a = appOrder.firstIndex(of: $0.id) ?? Int.max
            let b = appOrder.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
    }

    func moveApp(_ source: String, to target: String) {
        let visible = apps.map(\.id)
        let ordered = reorderedAppIDs(visible, moving: source, to: target)
        appOrder = ordered + appOrder.filter { !visible.contains($0) }
    }


    var filtered: [WindowItem] {
        let items = windows.filter { item in
            let inGroup: Bool
            switch selection {
            case "all": inGroup = true
            case "favorites": inGroup = favorites.contains(item.savedKey)
            case "terminals": inGroup = item.isTerminal
            case "browsers": inGroup = item.isBrowser
            default: inGroup = item.appID == selection
            }
            return matchesTaskFilter(item) && (inGroup || (searchAll && !query.isEmpty)) && (query.isEmpty || (item.title + " " + item.appName).localizedCaseInsensitiveContains(query))
        }
        switch sortMode {
        case .name: return items.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .tasks: return items.sorted {
            let a = taskSortPriority($0), b = taskSortPriority($1)
            return a == b ? $0.id < $1.id : a > b
        }
        case .activity: return items.sorted {
            let a = activity[$0.id]?.lastChange ?? .distantPast, b = activity[$1.id]?.lastChange ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
        case .newest: return items.sorted { $0.firstSeen == $1.firstSeen ? $0.id < $1.id : $0.firstSeen > $1.firstSeen }
        case .oldest: return items.sorted { $0.firstSeen == $1.firstSeen ? $0.id < $1.id : $0.firstSeen < $1.firstSeen }
        case .manual: return applyManualOrder(items, order: folder.manualOrder, id: \.id)
        }
    }

    /// 拖拽排列：把一组窗口移到 target 的位置，当前栏目切换为「手动排列」并记住顺序。
    func moveWindows(_ ids: [CGWindowID], to target: CGWindowID) {
        saveManualOrder(movedWindowOrder(displayed: filtered.map(\.id), stored: folder.manualOrder,
            existing: Set(windows.map(\.id)), moving: ids, to: target))
    }

    /// 置顶或移到末尾。看板保持当前滚动位置（用户要求）；移动带动画并保持高亮，便于看清移动了哪些窗口。
    func moveWindowsToEdge(_ ids: [CGWindowID], top: Bool) {
        let wanted = Set(ids)
        let moving = filtered.map(\.id).filter { wanted.contains($0) }
        guard !moving.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            saveManualOrder(edgeWindowOrder(displayed: filtered.map(\.id), stored: folder.manualOrder,
                existing: Set(windows.map(\.id)), moving: moving, toTop: top))
        }
        // 用独立的「刚移动」高亮标出；不放进多选（否则下次 ⌥ 点选会把它一起带上），
        // 也不改 selectedWindowID（否则键盘导航会把看板滚动到它的新位置）。
        if markedWindowIDs.count <= 1 { markedWindowIDs = [] }
        recentlyMovedWindowIDs = Set(moving)
    }

    private func saveManualOrder(_ next: [CGWindowID]) {
        var preferences = folder
        guard next != preferences.manualOrder || preferences.sort != .manual else { return }
        preferences.manualOrder = next
        preferences.sort = .manual
        folderPreferences[selection] = preferences
    }

    /// 当前选中的窗口，按显示顺序排列。
    var orderedSelection: [CGWindowID] {
        let chosen = markedWindowIDs.isEmpty ? Set(selectedWindowID.map { [$0] } ?? []) : markedWindowIDs
        return filtered.map(\.id).filter { chosen.contains($0) }
    }

    func isWindowSelected(_ id: CGWindowID) -> Bool {
        markedWindowIDs.isEmpty ? selectedWindowID == id : markedWindowIDs.contains(id)
    }

    /// 右键或拖拽的对象：点在已选窗口上时作用于全部选中窗口，否则只作用于这一个。
    func actionTargets(for id: CGWindowID) -> [CGWindowID] {
        let chosen = orderedSelection
        return chosen.contains(id) ? chosen : [id]
    }

    /// 单击：普通单击单选；Shift 连续选择；⌥ 或 ⌘ 逐个加选/取消。
    func click(_ item: WindowItem) {
        recentlyMovedWindowIDs = []
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            let range = rangeSelection(filtered.map(\.id), anchor: selectionAnchor ?? selectedWindowID, target: item.id)
            markedWindowIDs = Set(range)
            selectedWindowID = item.id
        } else if flags.contains(.option) || flags.contains(.command) {
            var marked = markedWindowIDs
            if marked.isEmpty, let current = selectedWindowID { marked.insert(current) }
            if marked.contains(item.id) { marked.remove(item.id) } else { marked.insert(item.id) }
            markedWindowIDs = marked
            selectedWindowID = marked.contains(item.id) ? item.id : marked.first
            selectionAnchor = item.id
        } else {
            markedWindowIDs = []
            selectedWindowID = item.id
            selectionAnchor = item.id
        }
    }

    func clearWindowSelection() { markedWindowIDs = []; selectedWindowID = nil; selectionAnchor = nil; recentlyMovedWindowIDs = [] }

    var heading: String {
        if searchAll && !query.isEmpty { return L("全部应用 · 搜索结果") }
        switch selection {
        case "all": return L("全部窗口")
        case "favorites": return L("已收藏")
        case "terminals": return L("终端工作台")
        case "browsers": return L("浏览器")
        default: return apps.first(where: { $0.id == selection })?.name ?? L("应用窗口")
        }
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
        Task { await refresh() }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessAllowed = AXIsProcessTrustedWithOptions(options)
        if !accessAllowed { openPrivacy("Privacy_Accessibility") }
    }

    func openPrivacy(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() async {
        // @Published 每次赋值都会触发整体重绘，状态不变时不赋值。
        let screen = CGPreflightScreenCaptureAccess(), access = AXIsProcessTrusted()
        if screenAllowed != screen { screenAllowed = screen }
        if accessAllowed != access { accessAllowed = access }
        guard screenAllowed, !refreshingList else { return }
        refreshingList = true
        refreshStatus.refreshing = true
        defer { refreshingList = false; refreshStatus.refreshing = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            staleWindowIDs.formIntersection(Set(content.windows.filter { !$0.isOnScreen }.map(\.windowID)))
            for (id, closed) in closedTargets {
                if !content.windows.contains(where: { $0.windowID == id && $0.owningApplication?.processID == closed.pid }) ||
                    accessibleWindows(pid: closed.pid).contains(where: { CFEqual($0.element, closed.element) }) {
                    closedTargets.removeValue(forKey: id)
                }
            }
            // 不在屏幕上的窗口在后台分类：辅助功能里找不到、也不在其他桌面空间的（已关闭仍驻留、应用内部窗口）不列出；
            // 在其他桌面空间的真实窗口保留并标记，辅助功能只能看到当前桌面的窗口，不能据此判为已关闭。
            let offscreen = content.windows.compactMap { window -> OffscreenWindowFilter.Candidate? in
                guard !window.isOnScreen, window.windowLayer == 0, let pid = window.owningApplication?.processID, pid != ownPID else { return nil }
                return OffscreenWindowFilter.Candidate(id: window.windowID, pid: pid, frame: window.frame)
            }
            let checkAccessibility = accessAllowed
            let (unreachable, otherSpace) = await Task.detached(priority: .utility) { () -> (Set<CGWindowID>, Set<CGWindowID>) in
                let missing = checkAccessibility ? OffscreenWindowFilter.unreachable(offscreen) : []
                let elsewhere = SpaceSupport.windowsOnOtherSpaces(offscreen.map(\.id))
                return (missing.subtracting(elsewhere), elsewhere)
            }.value
            var next: [WindowItem] = []
            var sources: [CGWindowID: SCWindow] = [:]
            for window in content.windows {
                guard closedTargets[window.windowID] == nil, !staleWindowIDs.contains(window.windowID),
                      !unreachable.contains(window.windowID) else { continue }
                guard window.windowLayer == 0, window.frame.width >= 100, window.frame.height >= 70,
                      let app = window.owningApplication, app.processID != ownPID,
                      let running = NSRunningApplication(processIdentifier: app.processID),
                      running.activationPolicy == .regular else { continue }
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Untitled standard windows are still useful; utility overlays are excluded by activation policy/layer.
                var item = WindowItem(id: window.windowID, pid: app.processID, appID: app.bundleIdentifier,
                    appName: app.applicationName, title: title.isEmpty ? app.applicationName : title,
                    frame: window.frame, icon: running.icon)
                item.firstSeen = discoveryDate(appID: app.bundleIdentifier, pid: app.processID, kind: "window", id: String(window.windowID))
                item.isOnScreen = window.isOnScreen
                item.onOtherSpace = otherSpace.contains(window.windowID)
                next.append(item)
                sources[window.windowID] = window
            }
            next.sort { lhs, rhs in
                if lhs.appName == rhs.appName {
                    if lhs.title == rhs.title { return lhs.id < rhs.id }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
            }
            // 窗口列表没有变化时不重新发布，避免每 6 秒整个看板重算一次。
            if !sameWindowList(windows, next) { windows = next }
            Task { await refreshTerminalTasks() }
            captureWindows = sources
            previews = previews.filter { sources[$0.key] != nil }
            activity = activity.filter { sources[$0.key] != nil }
            lastCaptured = lastCaptured.filter { sources[$0.key] != nil }
            refreshStatus.lastRefresh = Date()
            UserDefaults.standard.set(observedTimes, forKey: "observedTimes")
            // 标签读取对浏览器发出大量 Apple 事件：正在看标签页时每次刷新都读，否则每 30 秒读一次（只为更新侧栏数量）。
            if !browserTabApps.isEmpty, showingTabs || Date().timeIntervalSince(lastTabRefresh) >= 30 {
                await refreshBrowserTabs()
            }
            await captureVisible(skippingCapturedWithin: 0)
        } catch {
            errorMessage = L("无法更新窗口预览：%@", error.localizedDescription)
        }
    }

    func markVisible(_ id: CGWindowID, visible: Bool) {
        visibleCounts[id] = max(0, (visibleCounts[id] ?? 0) + (visible ? 1 : -1))
        if visibleCounts[id] == 0 { visibleCounts.removeValue(forKey: id) }
    }

    func preview(_ id: CGWindowID) -> WindowPreview {
        if let existing = previews[id] { return existing }
        let created = WindowPreview()
        previews[id] = created
        return created
    }

    /// 卡片出现、切换栏目或搜索时调用：短暂合并后再截图，滚动过程中不逐张触发。
    func requestCapture() {
        captureRequest?.cancel()
        captureRequest = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.captureVisible()
        }
    }

    /// `skippingCapturedWithin`：刚截过的窗口不重复截图；定时刷新传 0 以更新全部可见预览。
    func captureVisible(skippingCapturedWithin freshness: TimeInterval = 4) async {
        guard !capturing else { captureAgain = true; return }
        capturing = true
        defer { capturing = false }
        var activityChanged = false
        // List rows also register visibility; activity is sampled only while observed.
        let targets = windows.filter { (visibleCounts[$0.id] ?? 0) > 0 }
        for item in targets {
            guard screenAllowed, let source = captureWindows[item.id],
                  mainWindow?.isVisible == true || sidebarShown else { continue }
            // 滚动离开后的窗口不再截图。
            guard (visibleCounts[item.id] ?? 0) > 0 else { continue }
            if freshness > 0, let last = lastCaptured[item.id], Date().timeIntervalSince(last) < freshness { continue }
            let filter = SCContentFilter(desktopIndependentWindow: source)
            let config = SCStreamConfiguration()
            let ratio = max(0.1, min(1, 900 / max(item.frame.width, 1)))
            config.width = max(100, Int(item.frame.width * ratio))
            config.height = max(70, Int(item.frame.height * ratio))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .nominal
            do {
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // 采样与空白检测在后台线程进行，不占用滚动所在的主线程。
                let onScreen = source.isOnScreen
                let (signature, blank) = await Task.detached(priority: .utility) {
                    (onScreen ? activitySignature(cgImage) : nil, isBlankCapture(cgImage))
                }.value
                // Recheck because the window can close while its screenshot is in flight.
                guard captureWindows[item.id] != nil else { continue }
                lastCaptured[item.id] = Date()
                let target = preview(item.id)
                if let signature {
                    var sample = activity[item.id] ?? ActivityObservation()
                    sample.observe(signature, at: Date())
                    activityChanged = activityChanged || sample.lastChange != activity[item.id]?.lastChange
                    activity[item.id] = sample
                    target.activity = sample
                }
                // 其他桌面空间或已隐藏的窗口会返回全透明图；保留上次有效预览，否则显示应用图标占位而不是空白框。
                if !blank {
                    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    target.image = image
                    // 浏览器窗口的画面就是它当前标签的画面，记下来供该标签切到后台后继续显示。
                    if let tab = browserTabs.first(where: { $0.parentWindowID == item.id && $0.active }) {
                        tabSnapshots.store(cgImage, for: tab.previewKey)
                    }
                }
            } catch {
                // Retain the last good image for windows unavailable during a Space transition/minimization.
            }
        }
        // 只有按「最近内容变化」排序时，内容变化才需要整体重排。
        if activityChanged && sortMode == .activity { objectWillChange.send() }
        if captureAgain {
            captureAgain = false
            Task { await captureVisible(skippingCapturedWithin: freshness) }
        }
    }

    func toggleFavorite(_ item: WindowItem) {
        if favorites.contains(item.savedKey) { favorites.remove(item.savedKey) } else { favorites.insert(item.savedKey) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func focus(_ item: WindowItem) {
        selectedWindowID = item.id
        Task { await performWindowAction(item, action: .focus) }
    }

    func togglePin() {
        pinned.toggle()
        mainWindow?.level = pinned ? .floating : .normal
    }

    func showMain() {
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleSidebar() {
        if sidebarShown {
            panel?.orderOut(nil); sidebarShown = false; return
        }
        if panel == nil {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let p = NSPanel(contentRect: CGRect(x: screen.minX + 8, y: screen.minY + 8, width: 280, height: min(screen.height - 16, 850)),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            p.title = L("窗口侧栏")
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.minSize = NSSize(width: 240, height: 300)
            p.contentView = NSHostingView(rootView: LocalizedRootView { CompactSidebar().environmentObject(self) })
            p.delegate = AppDelegate.shared
            panel = p
        }
        sidebarShown = true
        panel?.orderFrontRegardless()
    }

    func updateSidebarTitle() { panel?.title = L("窗口侧栏") }
    func panelClosed() { sidebarShown = false }
}

/// 版本号来自安装包 Info.plist；直接运行调试二进制时没有 Info.plist，显示「开发版」。
enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return L("开发版") }
        let build = info?["CFBundleVersion"] as? String
        return build.map { L("版本 %@（%@）", short, $0) } ?? L("版本 %@", short)
    }
    /// 侧栏底部用的紧凑写法，如 v0.9.2 (33)。
    static var compact: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return L("开发版") }
        return (info?["CFBundleVersion"] as? String).map { "v\(short) (\($0))" } ?? "v\(short)"
    }
}

/// 侧栏底部：隐私说明一行，版本 · 版权与官网链接一行，左边缘对齐、统一次要文字色。
struct SidebarFooterInfo: View {
    private let website = URL(string: "https://windowatlas.kaizaoji.com")
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("预览仅在本机处理"), systemImage: "lock.shield")
                .labelStyle(FooterLabelStyle())
            HStack(spacing: 6) {
                Text(AppVersion.compact + " · © 开造记").monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .help(AppVersion.text + " · © 2026 开造记 kaizaoji")
                Spacer(minLength: 4)
                if let website {
                    Link(destination: website) {
                        HStack(spacing: 2) {
                            Text(L("获取更多"))
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                        }
                    }.foregroundStyle(AtlasStyle.accent).lineLimit(1).fixedSize()
                        .help(website.absoluteString)
                }
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}

/// 图标与文字间距收紧，让带图标的一行与下一行左边缘对齐。
private struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 10)); configuration.title }
    }
}

struct AppIcon: View {
    let image: NSImage?
    var size: CGFloat = 20
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "macwindow") }
        }.frame(width: size, height: size)
    }
}

struct NavigationRow: View {
    let title: String
    let symbol: String
    let count: Int
    var body: some View {
        Label { HStack { Text(title); Spacer(); Text("\(count)").foregroundStyle(.secondary).font(.caption.monospacedDigit()) } }
        icon: { Image(systemName: symbol).frame(width: 20) }
    }
}

struct AtlasView: View {
    @EnvironmentObject var store: WindowStore
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var commandLibrary: CommandLibraryStore
    @State private var draggingApp: String?
    @State private var desktopSettingsShown = false
    @State private var commandsShown = false
    var body: some View {
        NavigationSplitView {
            List(selection: $store.selection) {
                Section(L("工作区")) {
                    NavigationRow(title: L("全部窗口"), symbol: "square.grid.2x2", count: store.windows.count).tag("all")
                    NavigationRow(title: L("已收藏"), symbol: "star", count: store.windows.filter { store.favorites.contains($0.savedKey) }.count).tag("favorites")
                    NavigationRow(title: L("终端"), symbol: "terminal", count: store.windows.filter(\.isTerminal).count).tag("terminals")
                    NavigationRow(title: L("浏览器"), symbol: "globe", count: store.windows.filter(\.isBrowser).count).tag("browsers")
                    NavigationRow(title: L("快捷命令库"), symbol: "terminal.fill", count: commandLibrary.entries.filter { !$0.archived }.count).tag("commands")
                    NavigationRow(title: L("项目笔记"), symbol: "doc.text", count: notes.activeCount).tag("notes")
                }
                // 还没有窗口（如未授权）时不显示空的「应用」分组标题。
                if !store.apps.isEmpty {
                Section(L("应用")) {
                    ForEach(store.apps, id: \.id) { app in
                        HStack(spacing: 9) {
                            AppIcon(image: app.icon)
                            Text(app.name).lineLimit(1).layoutPriority(1)
                            Spacer(minLength: 4)
                            HStack(spacing: 3) {
                                // 显示标签数时加图标，与窗口数区分；文字保持很短，避免挤掉应用名。
                                if store.showsTabCount(app.id) { Image(systemName: "square.on.square").font(.system(size: 9)) }
                                Text(store.tabCountLabel(app.id, windowCount: app.count)).font(.caption.monospacedDigit())
                            }.foregroundStyle(.secondary).fixedSize()
                                .help(store.showsTabCount(app.id) ? L("%@ 个标签页", store.tabCountLabel(app.id, windowCount: app.count)) : L("%d 个窗口", app.count))
                        }.contentShape(Rectangle())
                            .onTapGesture { store.selection = app.id }
                            .onDrag { draggingApp = app.id; return NSItemProvider(object: ("windowatlas-app:" + app.id) as NSString) }
                            .onDrop(of: [UTType.text], delegate: ApplicationOrderDrop(target: app.id, dragging: $draggingApp, store: store))
                            .help(L("拖动调整应用顺序"))
                            .contextMenu {
                                if let browser = TabBrowser(rawValue: app.id) {
                                    if store.browserTabApps.contains(app.id) {
                                        Button(L("重新读取标签页")) { Task { await store.refreshBrowserTabs() } }
                                        Button(L("停止读取 %@ 标签页", browser.name)) { store.disableBrowserTabs(browser) }
                                    } else {
                                        Button(L("读取 %@ 标签页", browser.name)) { store.selection = app.id; store.enableBrowserTabs(browser) }
                                    }
                                    Divider()
                                }
                                Button(L("按名称排列应用")) { store.appOrder = [] }
                            }
                            .tag(app.id)
                    }
                }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(AtlasStyle.surface)
            .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 280)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    BrandMark(size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WindowAtlas").font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(L("所有窗口，一个工作台")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 14).padding(.vertical, 14).background(AtlasStyle.surface)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Button { commandsShown.toggle() } label: {
                        HStack {
                            Label(L("快捷命令"), systemImage: "terminal")
                            Spacer()
                            Text("⌘K").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(AtlasHoverButtonStyle())
                    Divider().opacity(0.6)
                    SidebarFooterInfo()
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 14)
                    .background(AtlasStyle.surface)
            }
        } detail: {
            VStack(spacing: 0) {
                // 窗口栏目未授权录屏时显示完整引导页，不再重复顶部提示条。
                let onboarding = !store.screenAllowed && store.selection != "notes" && store.selection != "commands"
                if (!store.screenAllowed || !store.accessAllowed) && !onboarding { PermissionStrip() }
                if let message = store.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.callout)
                        Spacer()
                        Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(Color.orange.opacity(0.08))
                }
                if store.selection == "notes" {
                    NotesView()
                } else if store.selection == "commands" {
                    CommandLibraryView()
                } else {
                // 未授权时标题、搜索和视图切换都无法使用，只显示引导页。
                if store.screenAllowed {
                    WorkspaceHeader()
                    FolderControls()
                }
                if !store.screenAllowed {
                    PermissionOnboarding().frame(maxHeight: .infinity)
                } else if store.showingTabs {
                    ChromeFolderView()
                } else if store.filtered.isEmpty {
                    ContentUnavailableView {
                        Label(store.query.isEmpty ? L("这里还没有窗口") : L("没有匹配的窗口"), systemImage: "macwindow")
                    } description: {
                        Text(store.selection == "favorites" ? L("在窗口卡片上点击星标，加入收藏。") : L("打开应用窗口，或调整搜索与筛选条件。"))
                    } actions: {
                        Button(L("刷新窗口")) { Task { await store.refresh() } }
                    }.frame(maxHeight: .infinity)
                } else {
                    WindowFolderView()
                }
                Divider()
                HStack {
                    Circle().fill(store.screenAllowed ? Color.green : Color.orange).frame(width: 6, height: 6)
                    RefreshStatusText(status: store.refreshStatus)
                    Text(L("时间为首次发现 · 预览仅在本机处理"))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
                }
            }
            .background(AtlasStyle.canvas)
            .toolbar {
                ToolbarItemGroup {
                    AppearanceSettingsMenu()
                    LanguageSettingsMenu()
                    Button { Task { await store.refresh() } } label: { Label(L("刷新"), systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r").help(L("刷新窗口与预览（⌘R）"))
                    Button { store.togglePin() } label: { Label(L("置顶"), systemImage: store.pinned ? "pin.fill" : "pin") }
                        .help(store.pinned ? L("取消看板置顶") : L("保持看板在其他窗口之上"))
                    Button { store.toggleSidebar() } label: { Label(L("侧栏"), systemImage: "sidebar.left") }
                        .help(L("显示或隐藏常驻缩略图侧栏"))
                    Button { desktopSettingsShown.toggle() } label: { Label(L("桌面整理设置"), systemImage: "gearshape") }
                        .help(L("整理 Dock 中的最小化窗口"))
                        .popover(isPresented: $desktopSettingsShown, arrowEdge: .bottom) { DesktopOrganizationSettings() }
                    Button { commandsShown.toggle() } label: { Label(L("快捷命令"), systemImage: "terminal") }
                        .keyboardShortcut("k").help(L("搜索并复制常用命令（⌘K）"))
                }
            }
            .inspector(isPresented: $commandsShown) {
                CommandLibraryView(compact: true, openLibrary: { store.selection = "commands"; commandsShown = false })
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
        }
        .tint(AtlasStyle.accent)
        .onChange(of: store.selection) { _, _ in store.requestCapture() }
        .onChange(of: store.query) { _, _ in store.requestCapture() }
    }
}

struct PermissionStrip: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised").foregroundStyle(.orange)
            Text(L("完成权限设置后即可预览并切换窗口")).font(.callout)
            Spacer()
            if !store.screenAllowed { Button(L("屏幕录制")) { store.requestScreen() } }
            if !store.accessAllowed { Button(L("辅助功能")) { store.requestAccessibility() } }
            Button(L("重新检查")) { Task { await store.refresh() } }
        }.padding(12).background(Color.orange.opacity(0.08))
    }
}

struct WindowCard: View {
    @EnvironmentObject var store: WindowStore
    let item: WindowItem
    @State private var hovered = false
    @State private var placementShown = false
    @State private var closeConfirmShown = false
    private var highlighted: Bool { store.isWindowSelected(item.id) || store.recentlyMovedWindowIDs.contains(item.id) }
    var body: some View {
        VStack(spacing: 0) {
            Button { store.click(item) } label: {
                ZStack {
                    AtlasStyle.canvas
                    WindowPreviewImage(preview: store.preview(item.id), padding: 5) {
                        VStack(spacing: 10) {
                            AppIcon(image: item.icon, size: 44)
                            Text(L("等待窗口预览")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.overlay(alignment: .topTrailing) {
                    HStack(spacing: 6) {
                        ActivityBadge(item: item)
                        // 悬停时才显示，避免满屏关闭按钮；点击后二次确认，防止误关。
                        if hovered || closeConfirmShown {
                            Button { closeConfirmShown = true } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                    .frame(width: 24, height: 24)
                                    .background(AtlasStyle.surface.opacity(0.94), in: Circle())
                                    .overlay(Circle().strokeBorder(AtlasStyle.border))
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(L("关闭窗口")).accessibilityLabel(L("关闭窗口"))
                        }
                    }.padding(9)
                }
                .overlay(alignment: .topLeading) {
                    // 多选时用对勾标出选中的窗口。
                    if !store.markedWindowIDs.isEmpty && store.isWindowSelected(item.id) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, AtlasStyle.accent).padding(9)
                    }
                }
                .aspectRatio(1.65, contentMode: .fit).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { store.focus(item) })
                .accessibilityLabel(L("选择 %@：%@", item.appName, item.title))
                .help(L("单击选中，双击或回车打开窗口；按住 Shift 连续多选，按住 ⌥ 或 ⌘ 逐个多选，拖动可调整位置"))
            Divider()
            HStack(spacing: 9) {
                AppIcon(image: item.icon, size: 25)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2, reservesSpace: true).help(item.title)
                    Text(item.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Button { placementShown.toggle() } label: {
                    Image(systemName: "rectangle.split.3x3").frame(width: 25, height: 25)
                }.buttonStyle(AtlasHoverButtonStyle())
                    .help(L("调整窗口位置")).accessibilityLabel(L("调整窗口位置"))
                    .popover(isPresented: $placementShown, arrowEdge: .bottom) {
                        PlacementPicker(item: item, dismiss: { placementShown = false }).environmentObject(store)
                    }
                Button { store.toggleFavorite(item) } label: {
                    Image(systemName: store.favorites.contains(item.savedKey) ? "star.fill" : "star")
                        .foregroundStyle(store.favorites.contains(item.savedKey) ? Color.orange : Color.secondary)
                }.buttonStyle(AtlasHoverButtonStyle()).help(store.favorites.contains(item.savedKey) ? L("取消收藏") : L("收藏窗口"))
            }.padding(12)
        }
        .background(AtlasStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: AtlasStyle.radius))
        .overlay(RoundedRectangle(cornerRadius: AtlasStyle.radius).stroke(highlighted ? AtlasStyle.accent : hovered ? AtlasStyle.accent.opacity(0.8) : AtlasStyle.border, lineWidth: highlighted ? 2 : 1))
        .accessibilityAddTraits(store.isWindowSelected(item.id) ? .isSelected : [])
        .onHover { hovered = $0 }
        .alert(L("关闭「%@」？", item.title), isPresented: $closeConfirmShown) {
            Button(L("关闭窗口"), role: .destructive) { Task { await store.performWindowAction(item, action: .close) } }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("将关闭 %@ 中的这个窗口；有未保存的内容时，由该应用决定是否提示保存。", item.appName))
        }
        .windowContextMenu(item: item, store: store)
        .windowReordering(item: item, store: store)
        .onAppear { store.markVisible(item.id, visible: true); store.requestCapture() }
        .onDisappear { store.markVisible(item.id, visible: false) }
    }
}

struct CompactSidebar: View {
    @EnvironmentObject var store: WindowStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text(L("窗口图鉴")).font(.headline)
                Spacer()
                Button { store.showMain() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(L("打开大缩略图看板"))
                Button { store.toggleSidebar() } label: { Image(systemName: "xmark") }.help(L("隐藏侧栏"))
            }.padding(12)
            TextField(L("搜索窗口"), text: $store.query).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if !store.screenAllowed {
                VStack(spacing: 12) { Text(L("先在主看板开启预览权限")); Button(L("打开看板")) { store.showMain() } }.padding()
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.showingTabs {
                        ForEach(store.filteredTabs) { tab in
                            Button { store.actOnTab(tab) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(tab.title).lineLimit(2)
                                    Text(tab.location + " · " + tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }.buttonStyle(.plain).contextMenu { ChromeTabActions(tab: tab) }
                        }
                    } else {
                    ForEach(store.filtered) { item in
                        Button { store.focus(item) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ZStack {
                                    Color(nsColor: .underPageBackgroundColor)
                                    WindowPreviewImage(preview: store.preview(item.id)) { AppIcon(image: item.icon, size: 32) }
                                }.frame(height: 125).clipShape(RoundedRectangle(cornerRadius: 6))
                                HStack(spacing: 6) {
                                    AppIcon(image: item.icon, size: 16)
                                    Text(item.title).font(.caption).lineLimit(1)
                                    ActivityBadge(item: item, compact: true)
                                }
                            }.padding(9).background(AtlasStyle.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).windowContextMenu(item: item, store: store)
                        .onAppear { store.markVisible(item.id, visible: true); store.requestCapture() }
                        .onDisappear { store.markVisible(item.id, visible: false) }
                    }
                    }
                }.padding(10)
            }
            Divider()
            Text(L("%d 项 · 与主看板同步筛选", store.displayCount)).font(.caption).foregroundStyle(.secondary).padding(8)
        }.frame(minWidth: 240)
            .background(AtlasStyle.canvas).tint(AtlasStyle.accent)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    let store = WindowStore()
    let notes = NotesStore()
    let commandLibrary = CommandLibraryStore(seeds: CommandTemplates.entries, additions: CommandTemplates.additions)
    lazy var backup = BackupCenter(notes: notes)
    private var window: NSWindow!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        AppPreferences.shared.applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: AppPreferences.languageChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: AppPreferences.appearanceChanged, object: nil)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = L("窗口图鉴")
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 520)
        window.setFrameAutosaveName("WindowAtlasMain")
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LocalizedRootView { AtlasView().environmentObject(self.store).environmentObject(self.notes).environmentObject(self.backup).environmentObject(self.commandLibrary) })
        store.mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandAssets.menubarIcon ?? NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: L("窗口图鉴"))
        buildStatusMenu()
        buildMainMenu()
        store.start()
    }

    func buildStatusMenu() {
        let menu = NSMenu()
        let version = NSMenuItem(title: L("窗口图鉴 · ") + AppVersion.text, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let show = NSMenuItem(title: L("打开窗口看板"), action: #selector(showMain), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let sidebar = NSMenuItem(title: L("显示 / 隐藏常驻侧栏"), action: #selector(toggleSidebar), keyEquivalent: "")
        sidebar.target = self; menu.addItem(sidebar)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出窗口图鉴"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func buildMainMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("关于窗口图鉴"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appendPreferenceMenus(to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出窗口图鉴"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; root.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = L("编辑"); let edit = NSMenu(title: L("编辑"))
        // 笔记编辑器依赖响应链的 undo:/redo:，菜单需提供入口才能使用 ⌘Z / ⇧⌘Z。
        edit.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [(L("剪切"), "cut:", "x"), (L("拷贝"), "copy:", "c"), (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.addItem(.separator())
        let search = NSMenuItem(title: L("搜索"), action: #selector(focusSearch), keyEquivalent: "f")
        search.target = self
        edit.addItem(search)
        editItem.submenu = edit; root.addItem(editItem)
        let windowItem = NSMenuItem(); windowItem.title = L("窗口"); let windows = NSMenu(title: L("窗口"))
        let show = NSMenuItem(title: L("打开窗口看板"), action: #selector(showMain), keyEquivalent: "1"); show.target = self
        windows.addItem(show)
        let refresh = NSMenuItem(title: L("刷新预览"), action: #selector(refresh), keyEquivalent: "r"); refresh.target = self
        windows.addItem(refresh)
        let side = NSMenuItem(title: L("显示 / 隐藏侧栏"), action: #selector(toggleSidebar), keyEquivalent: "2"); side.target = self
        windows.addItem(side)
        windowItem.submenu = windows; root.addItem(windowItem)
        NSApp.mainMenu = root
    }

    private func appendPreferenceMenus(to menu: NSMenu) {
        let appearanceMenu = NSMenu(title: L("外观"))
        for appearance in AppAppearance.allCases {
            let item = NSMenuItem(title: appearance.title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appearance.rawValue
            item.state = AppPreferences.shared.appearance == appearance ? .on : .off
            appearanceMenu.addItem(item)
        }
        let appearanceItem = NSMenuItem(title: L("外观"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)
        let languageMenu = NSMenu(title: L("语言"))
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = AppPreferences.shared.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: L("语言"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
    }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let appearance = AppAppearance(rawValue: rawValue) else { return }
        AppPreferences.shared.appearance = appearance
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let language = AppLanguage(rawValue: rawValue) else { return }
        AppPreferences.shared.setLanguage(language)
    }

    @objc private func appearanceChanged() { buildMainMenu() }

    @objc private func languageChanged() {
        window?.title = L("窗口图鉴")
        store.updateSidebarTitle()
        statusItem?.button?.setAccessibilityLabel(L("窗口图鉴"))
        buildStatusMenu()
        buildMainMenu()
    }

    @objc func showMain() { store.showMain() }
    @objc func toggleSidebar() { store.toggleSidebar() }
    @objc func refresh() { Task { await store.refresh() } }
    @objc private func focusSearch() {
        showMain()
        NotificationCenter.default.post(name: Notification.Name("WindowAtlas.focusSearch"), object: nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard commandLibrary.canLeaveEditor() else {
            store.showMain()
            return .terminateCancel
        }
        guard notes.flush() else {
            let alert = NSAlert()
            alert.messageText = L("笔记尚未保存，已取消退出")
            alert.informativeText = L("当前编辑仍保留在工作台中。请检查磁盘空间或笔记目录权限，保存成功后再退出。")
            alert.addButton(withTitle: L("返回工作台"))
            alert.runModal()
            store.showMain()
            return .terminateCancel
        }
        return .terminateNow
    }
    // 用户可能在其他编辑器或 Finder 中修改、复制回笔记文件，回到前台时合并。
    func applicationDidBecomeActive(_ notification: Notification) { notes.reloadExternalChanges() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { store.showMain(); return true }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSPanel { if closing !== window { store.panelClosed() } }
    }
}

@main
struct WindowAtlasMain {
    @MainActor static func main() {
        // 必须先于各 Store 初始化：它们在属性初始化时就读取偏好。
        LegacyMigration.migrateDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// 只观察单个窗口的预览，缩略图更新时只重绘这一处。
struct WindowPreviewImage<Placeholder: View>: View {
    @ObservedObject var preview: WindowPreview
    var padding: CGFloat = 0
    @ViewBuilder var placeholder: () -> Placeholder
    var body: some View {
        if let image = preview.image {
            Image(nsImage: image).resizable().interpolation(.medium).scaledToFit().padding(padding)
        } else {
            placeholder()
        }
    }
}

struct RefreshStatusText: View {
    @ObservedObject var status: RefreshStatus
    var body: some View {
        Text(status.refreshing ? L("正在更新预览…") : L("每 6 秒更新可见预览"))
        Spacer()
        if let date = status.lastRefresh { Text(date, style: .time) }
    }
}

/// 只比较会影响显示的字段；应用图标每次读取可能是新对象，不参与比较。
func sameWindowList(_ lhs: [WindowItem], _ rhs: [WindowItem]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
        a.id == b.id && a.title == b.title && a.frame == b.frame && a.isOnScreen == b.isOnScreen
            && a.firstSeen == b.firstSeen && a.appID == b.appID && a.appName == b.appName && a.pid == b.pid
            && a.onOtherSpace == b.onOtherSpace
    }
}
