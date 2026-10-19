import AppKit
import ScriptingBridge

// 停止读取后让旧响应失效；旧请求完成不能清理后来请求的加载状态。
struct BrowserRefreshRequest {
    private(set) var activeID: UUID?

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let requestID = UUID()
        activeID = requestID
        return requestID
    }

    func isCurrent(_ requestID: UUID) -> Bool { activeID == requestID }
    mutating func invalidate() { activeID = nil }

    @discardableResult
    mutating func finish(_ requestID: UUID) -> Bool {
        guard isCurrent(requestID) else { return false }
        activeID = nil
        return true
    }
}

/// 支持读取标签页的浏览器。Chrome 与 Edge 同为 Chromium，脚本字典一致；Safari 字典不同，标签没有稳定 ID。
enum TabBrowser: String, CaseIterable {
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"
    case safari = "com.apple.Safari"
    var name: String {
        switch self { case .chrome: return "Google Chrome"; case .edge: return "Microsoft Edge"; case .safari: return "Safari" }
    }
    var isChromium: Bool { self != .safari }
    var shortName: String {
        switch self { case .chrome: return "Chrome"; case .edge: return "Edge"; case .safari: return "Safari" }
    }
}

enum BrowserBridgeError: LocalizedError {
    case script(String)
    var errorDescription: String? { if case .script(let message) = self { return message }; return nil }
}

enum BrowserBridge {
    private static let queue = DispatchQueue(label: "WindowAtlas.ChromeAutomation")

    // Address the selected running instance, never LaunchServices' ambiguous bundle ID.
    static func code(_ value: String) -> UInt32 { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { autoreleasepool {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            } }
        }
    }

    struct TabSnapshot: Sendable {
        let id: String, title: String, url: String
        let active: Bool
    }
    struct WindowSnapshot: Sendable {
        let id: String
        let frame: CGRect
        let tabs: [TabSnapshot]
    }

    static func snapshot(pid: pid_t, browser: TabBrowser) async throws -> [WindowSnapshot] {
        try await run { browser.isChromium ? try readSnapshot(pid: pid, browser: browser) : try readSafari(pid: pid) }
    }

    private final class EventErrors: NSObject, SBApplicationDelegate {
        let browser: TabBrowser
        var error: Error?
        init(browser: TabBrowser) { self.browser = browser }
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            self.error = error
            return nil
        }
        func check() throws {
            if let error {
                let code = (error as NSError).code
                throw BrowserBridgeError.script(code == -1743
                    ? L("请在系统设置 → 隐私与安全性 → 自动化中，允许窗口图鉴控制 %@。", browser.name)
                    : L("%@ 读取失败（%d）：%@", browser.name, code, error.localizedDescription))
            }
        }
    }

    private static func connection(pid: pid_t, browser: TabBrowser) throws -> (SBApplication, EventErrors) {
        guard let app = SBApplication(processIdentifier: pid) else { throw BrowserBridgeError.script(L("%@ 进程已经退出。", browser.name)) }
        let errors = EventErrors(browser: browser); app.delegate = errors; app.timeout = 12 * 60
        return (app, errors)
    }

    private static func children(_ object: SBObject, _ kind: String, errors: EventErrors) throws -> [SBObject] {
        let values = object.elementArray(withCode: code(kind)).get() as? [SBObject] ?? []
        try errors.check()
        return values
    }

    private static func text(_ object: SBObject, _ key: String, errors: EventErrors) throws -> String {
        let value = object.property(withCode: code(key)).get()
        try errors.check()
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        throw BrowserBridgeError.script(L("%@ 标签属性不完整，请重新读取。", errors.browser.name))
    }

    /// 读取可能为空的文本属性（如 Safari 新标签页没有网址）；出错时清除错误并返回空字符串。
    private static func optionalText(_ object: SBObject, _ key: String, errors: EventErrors) -> String {
        let value = object.property(withCode: code(key)).get()
        if errors.error != nil { errors.error = nil; return "" }
        return (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
    }

    private static func bounds(_ window: SBObject, errors: EventErrors) throws -> CGRect {
        let raw = window.property(withCode: code("pbnd")).get()
        try errors.check()
        if let values = raw as? [NSNumber], values.count == 4 {
            return CGRect(x: values[0].doubleValue, y: values[1].doubleValue,
                width: values[2].doubleValue - values[0].doubleValue, height: values[3].doubleValue - values[1].doubleValue)
        } else if let rect = raw as? NSValue {
            return rect.rectValue
        } else if let descriptor = raw as? NSAppleEventDescriptor, descriptor.data.count == 8 {
            let bytes = Array(descriptor.data)
            let v = stride(from: 0, to: 8, by: 2).map { CGFloat(Int16(bitPattern: (UInt16(bytes[$0]) << 8) | UInt16(bytes[$0 + 1]))) }
            return CGRect(x: v[1], y: v[0], width: v[3] - v[1], height: v[2] - v[0])
        }
        throw BrowserBridgeError.script(L("无法读取 %@ 窗口位置。", errors.browser.name))
    }

    /// Safari：窗口 → 标签（bTab），标签有名称（pnam）、网址（pURL）、序号（pidx），窗口当前标签为 cTab。
    /// 标签没有稳定 ID，用「窗口 ID:序号」标识，操作时再按网址与标题核对。偏好设置等无标签的窗口跳过。
    private static func readSafari(pid: pid_t) throws -> [WindowSnapshot] {
        let (app, errors) = try connection(pid: pid, browser: .safari)
        return try children(app, "cwin", errors: errors).compactMap { window in
            guard let id = try? text(window, "ID  ", errors: errors), let frame = try? bounds(window, errors: errors) else {
                errors.error = nil; return nil
            }
            let tabs = (try? children(window, "bTab", errors: errors)) ?? []
            if errors.error != nil { errors.error = nil; return nil }
            guard !tabs.isEmpty else { return nil }
            let current = (window.property(withCode: code("cTab")).get() as? SBObject)?.property(withCode: code("pidx")).get() as? NSNumber
            errors.error = nil
            let snapshots = tabs.enumerated().map { index, tab in
                TabSnapshot(id: "\(id):\(index + 1)", title: optionalText(tab, "pnam", errors: errors),
                    url: optionalText(tab, "pURL", errors: errors), active: index + 1 == current?.intValue)
            }
            return WindowSnapshot(id: id, frame: frame, tabs: snapshots)
        }
    }

    private static func readSnapshot(pid: pid_t, browser: TabBrowser) throws -> [WindowSnapshot] {
        let (app, errors) = try connection(pid: pid, browser: browser)
        return try children(app, "cwin", errors: errors).map { window in
            let id = try text(window, "ID  ", errors: errors)
            let frame = try bounds(window, errors: errors)
            let active = window.property(withCode: code("acTI")).get() as? NSNumber
            try errors.check()
            let tabs = try children(window, "CrTb", errors: errors).enumerated().map { index, tab in
                try TabSnapshot(id: text(tab, "ID  ", errors: errors), title: text(tab, "pnam", errors: errors),
                    url: text(tab, "URL ", errors: errors), active: index + 1 == active?.intValue)
            }
            return WindowSnapshot(id: id, frame: frame, tabs: tabs)
        }
    }

    /// 切换到或关闭标签页。Chromium 按稳定 ID 重新查找（标签可能已移动）；Safari 按「窗口 ID:序号」定位并核对网址与标题，
    /// 序号已变化时在全部窗口中按网址与标题查找。
    static func act(tab: BrowserTab, browser: TabBrowser, close: Bool) async throws -> Bool {
        let tabID = tab.tabID, url = tab.url, title = tab.title, pid = tab.pid
        return try await run {
            let (app, errors) = try connection(pid: pid, browser: browser)
            let tabCode = browser.isChromium ? "CrTb" : "bTab"
            // Safari 第一轮按原位置（窗口 ID:序号）且网址一致定位；位置已变化时第二轮按网址与标题查找。
            func matches(_ window: SBObject, _ index: Int, _ object: SBObject, exactPosition: Bool) throws -> Bool {
                if browser.isChromium { return try text(object, "ID  ", errors: errors) == tabID }
                guard optionalText(object, "pURL", errors: errors) == url else { return false }
                if exactPosition {
                    let windowID = (try? text(window, "ID  ", errors: errors)) ?? ""
                    errors.error = nil
                    return tabID == "\(windowID):\(index + 1)"
                }
                return title == L("无标题标签页") || optionalText(object, "pnam", errors: errors) == title
            }
            let windows = try children(app, "cwin", errors: errors)
            for exactPosition in browser.isChromium ? [true] : [true, false] {
            for window in windows {
                let tabs = (try? children(window, tabCode, errors: errors)) ?? []
                errors.error = nil
                for (index, object) in tabs.enumerated() where try matches(window, index, object, exactPosition: exactPosition) {
                    if close {
                        guard object.responds(to: NSSelectorFromString("close")) else {
                            throw BrowserBridgeError.script(L("%@ 未提供标签关闭操作。", browser.name))
                        }
                        _ = object.perform(NSSelectorFromString("close"))
                    } else {
                        if browser.isChromium {
                            window.property(withCode: code("acTI")).setTo(NSNumber(value: index + 1))
                        } else {
                            window.property(withCode: code("cTab")).setTo(object)
                        }
                        try errors.check()
                        window.property(withCode: code("pmnd")).setTo(NSNumber(value: false))
                        try errors.check()
                        window.property(withCode: code("pidx")).setTo(NSNumber(value: 1))
                    }
                    try errors.check()
                    return true
                }
            }
            }
            return false
        }
    }
}

@MainActor
extension WindowStore {
    /// 当前栏目对应的单个浏览器（Chrome / Edge / Safari 栏目）。
    var currentTabBrowser: TabBrowser? { TabBrowser(rawValue: selection) }
    /// 可切换「标签页 / 窗口」的栏目：单个浏览器，以及汇总所有浏览器的「全部窗口」「浏览器」。
    var isTabFolder: Bool { currentTabBrowser != nil || selection == "all" || selection == "browsers" }
    /// 当前栏目涉及的浏览器；汇总栏目只包含正在运行且有窗口的浏览器。
    var tabFolderBrowsers: [TabBrowser] {
        if let browser = currentTabBrowser { return [browser] }
        guard isTabFolder else { return [] }
        return TabBrowser.allCases.filter { browser in windows.contains { $0.appID == browser.rawValue } }
    }
    var tabFolderName: String { currentTabBrowser?.name ?? L("所有浏览器") }
    var browserEnabled: Bool { tabFolderBrowsers.contains { browserTabApps.contains($0.rawValue) } }
    var browserLoading: Bool { tabFolderBrowsers.contains { browserLoadingApps.contains($0.rawValue) } }
    var browserError: String? {
        let messages = tabFolderBrowsers.compactMap { browserErrors[$0.rawValue] }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// 侧栏数字：已读取的浏览器显示标签数，否则显示窗口数。
    func tabCountLabel(_ appID: String, windowCount: Int) -> String {
        guard browserTabApps.contains(appID) else { return "\(windowCount)" }
        if browserLoadingApps.contains(appID) && !browserTabs.contains(where: { $0.appID == appID }) { return L("读取中…") }
        if browserErrors[appID] != nil { return L("需重试") }
        return "\(browserTabs.filter { $0.appID == appID }.count)"
    }

    /// 侧栏是否在显示标签数（用于加标签图标，与窗口数区分）。
    func showsTabCount(_ appID: String) -> Bool {
        browserTabApps.contains(appID) && browserErrors[appID] == nil && browserTabs.contains { $0.appID == appID }
    }

    var filteredTabs: [BrowserTab] {
        let included = Set(tabFolderBrowsers.map(\.rawValue))
        let items = browserTabs.filter { included.contains($0.appID) && (query.isEmpty || ($0.title + " " + $0.url + " " + $0.location).localizedCaseInsensitiveContains(query)) }
        // 汇总栏目先按浏览器分组（Chrome、Edge、Safari），再按窗口与标签原顺序。
        let rank = Dictionary(uniqueKeysWithValues: TabBrowser.allCases.enumerated().map { ($1.rawValue, $0) })
        func grouped(_ a: BrowserTab, _ b: BrowserTab, then: (BrowserTab, BrowserTab) -> Bool) -> Bool {
            if a.appID != b.appID { return (rank[a.appID] ?? 9) < (rank[b.appID] ?? 9) }
            if a.pid != b.pid { return a.pid < b.pid }
            if a.windowNumber != b.windowNumber { return a.windowNumber < b.windowNumber }
            return then(a, b)
        }
        switch sortMode {
        case .name: return items.sorted { grouped($0, $1) { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        case .tasks, .manual: return items.sorted { grouped($0, $1) { $0.order < $1.order } }
        case .activity: return items.sorted {
            let a = $0.parentWindowID.flatMap { activity[$0]?.lastChange } ?? .distantPast
            let b = $1.parentWindowID.flatMap { activity[$0]?.lastChange } ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
        case .newest: return items.sorted { $0.firstSeen == $1.firstSeen ? $0.id < $1.id : $0.firstSeen > $1.firstSeen }
        case .oldest: return items.sorted { $0.firstSeen == $1.firstSeen ? $0.id < $1.id : $0.firstSeen < $1.firstSeen }
        }
    }

    func discoveryDate(appID: String, pid: pid_t, kind: String, id: String) -> Date {
        let launch = NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 ?? Double(pid)
        let key = "\(appID):\(launch):\(kind):\(id)"
        if let value = observedTimes[key] { return Date(timeIntervalSince1970: value) }
        let date = Date(); observedTimes[key] = date.timeIntervalSince1970; return date
    }

    func setShowTabs(_ show: Bool) {
        var f = folder
        if currentTabBrowser != nil { f.showTabs = show } else { f.aggregateTabs = show }
        folderPreferences[selection] = f
    }

    /// 开始读取指定（默认当前栏目）浏览器的标签页并切到标签页视图；首次会出现系统「自动化」授权提示。
    func enableBrowserTabs(_ target: TabBrowser? = nil) {
        // 汇总栏目一次开启所有正在运行的浏览器（每个浏览器首次各有一次系统授权提示）。
        let browsers = target.map { [$0] } ?? tabFolderBrowsers
        guard !browsers.isEmpty else { return }
        for browser in browsers {
            browserTabApps.insert(browser.rawValue)
            browserErrors.removeValue(forKey: browser.rawValue)
        }
        if target == nil || selection == target?.rawValue { setShowTabs(true) }
        Task { await refreshBrowserTabs() }
    }

    func disableBrowserTabs(_ target: TabBrowser? = nil) {
        guard let browser = target ?? currentTabBrowser else { return }
        browserTabApps.remove(browser.rawValue)
        browserLoadingApps.remove(browser.rawValue)
        browserErrors.removeValue(forKey: browser.rawValue)
        browserTabs.removeAll { $0.appID == browser.rawValue }
        tabSnapshots.retain(Set(browserTabs.map(\.previewKey)))
    }

    func refreshBrowserTabs() async {
        guard !browserTabApps.isEmpty, let requestID = browserRefreshRequest.begin() else { return }
        defer {
            if browserRefreshRequest.finish(requestID) { browserLoadingApps = [] }
        }
        // 各浏览器独立读取：一个浏览器未授权或出错，不影响其他浏览器的标签。
        var next = browserTabs.filter { browserTabApps.contains($0.appID) }
        for browser in TabBrowser.allCases where browserTabApps.contains(browser.rawValue) {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: browser.rawValue).filter { app in
                windows.contains { $0.pid == app.processIdentifier && $0.appID == browser.rawValue }
            }
            guard !instances.isEmpty else {
                next.removeAll { $0.appID == browser.rawValue }; browserErrors.removeValue(forKey: browser.rawValue); continue
            }
            browserLoadingApps.insert(browser.rawValue)
            do {
                var tabs: [BrowserTab] = []
                for running in instances {
                    let snapshots = try await BrowserBridge.snapshot(pid: running.processIdentifier, browser: browser)
                    guard browserRefreshRequest.isCurrent(requestID), browserTabApps.contains(browser.rawValue), !running.isTerminated else { return }
                    for (offset, snapshot) in snapshots.enumerated() {
                        let parents = windows.filter { $0.pid == running.processIdentifier && geometryDistance($0.frame, snapshot.frame) <= 8 }
                        let parent = parents.count == 1 ? parents[0].id : nil
                        for (order, value) in snapshot.tabs.enumerated() {
                            var tab = BrowserTab(appID: browser.rawValue, pid: running.processIdentifier, tabID: value.id,
                                browserWindowID: snapshot.id, windowNumber: offset + 1, title: value.title.isEmpty ? L("无标题标签页") : value.title,
                                url: value.url, active: value.active, windowFrame: snapshot.frame, parentWindowID: parent)
                            tab.order = order
                            tab.firstSeen = discoveryDate(appID: tab.appID, pid: tab.pid, kind: "tab", id: browser.isChromium ? tab.tabID : tab.url)
                            tabs.append(tab)
                        }
                    }
                }
                next.removeAll { $0.appID == browser.rawValue }
                next.append(contentsOf: tabs)
                browserErrors[browser.rawValue] = tabs.isEmpty ? L("%@ 未返回标签页。可重新读取，或切到窗口视图查看。", browser.name) : nil
            } catch {
                guard browserRefreshRequest.isCurrent(requestID) else { return }
                browserErrors[browser.rawValue] = error.localizedDescription
                // 授权被拒或读取失败时停止该浏览器的自动读取，避免每 6 秒重复弹出授权或报错；由用户手动重试。
                browserTabApps.remove(browser.rawValue)
                next.removeAll { $0.appID == browser.rawValue }
            }
            browserLoadingApps.remove(browser.rawValue)
        }
        guard browserRefreshRequest.isCurrent(requestID) else { return }
        browserTabs = next
        lastTabRefresh = Date()
        // 已关闭标签的画面不再保留。
        tabSnapshots.retain(Set(next.map(\.previewKey)))
        UserDefaults.standard.set(observedTimes, forKey: "observedTimes")
    }

    func actOnTab(_ tab: BrowserTab, close: Bool = false) {
        selectedTabID = tab.id
        guard let browser = TabBrowser(rawValue: tab.appID),
              NSRunningApplication(processIdentifier: tab.pid)?.bundleIdentifier == tab.appID else {
            browserErrors[tab.appID] = L("浏览器已重新启动，请重新读取标签页。"); return
        }
        Task {
            do {
                guard try await BrowserBridge.act(tab: tab, browser: browser, close: close) else {
                    browserErrors[tab.appID] = L("这个标签页已关闭。正在更新列表。"); await refreshBrowserTabs(); return
                }
                if !close { NSRunningApplication(processIdentifier: tab.pid)?.activate(options: []) }
                if close { browserTabs.removeAll { $0.id == tab.id } }
                await refreshBrowserTabs()
            } catch { browserErrors[tab.appID] = error.localizedDescription }
        }
    }
}
