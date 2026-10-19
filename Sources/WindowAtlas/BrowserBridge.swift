import AppKit
import Darwin
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
    /// 终端与 iTerm2 的每个标签（iTerm2 分屏时为每个会话）同样作为「标签页」列出。
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    var name: String {
        switch self {
        case .chrome: return "Google Chrome"; case .edge: return "Microsoft Edge"; case .safari: return "Safari"
        case .terminal: return L("终端"); case .iterm: return "iTerm2"
        }
    }
    var isChromium: Bool { self == .chrome || self == .edge }
    var isTerminal: Bool { self == .terminal || self == .iterm }
    var shortName: String {
        switch self {
        case .chrome: return "Chrome"; case .edge: return "Edge"; case .safari: return "Safari"
        case .terminal: return L("终端"); case .iterm: return "iTerm2"
        }
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
        /// 应用自己显示的原始标题（终端标签的显示标题会改成完整路径），用于和窗口实时标题比对。
        var rawTitle = ""
    }
    struct WindowSnapshot: Sendable {
        let id: String
        let frame: CGRect
        let tabs: [TabSnapshot]
    }

    static func snapshot(pid: pid_t, browser: TabBrowser) async throws -> [WindowSnapshot] {
        try await run {
            if browser.isTerminal { return try readTerminal(pid: pid, browser: browser) }
            return browser.isChromium ? try readSnapshot(pid: pid, browser: browser) : try readSafari(pid: pid)
        }
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

    /// 终端标签：只读标题、TTY 与进程名，不读取终端内容。窗口 ID 即窗口服务器编号，可直接对应缩略图。
    /// 终端：窗口 → 标签（ttab），标题为标签标题（titl），当前标签为 selected（tbsl），id 为「窗口:TTY」。
    /// iTerm2：窗口 → 标签（Trmt）→ 会话（Trms，分屏时多个），标题为会话名（pnam），id 为会话 unique ID（Uniq）。
    private static func readTerminal(pid: pid_t, browser: TabBrowser) throws -> [WindowSnapshot] {
        let (app, errors) = try connection(pid: pid, browser: browser)
        let details = TerminalDirectories.details()
        let directories = details.compactMapValues(\.path)
        let isTerminal = browser == .terminal
        let shells: Set<String> = ["login", "-zsh", "zsh", "-bash", "bash", "sh", "fish", "-fish"]
        return try children(app, "cwin", errors: errors).compactMap { window in
            guard let id = try? text(window, "ID  ", errors: errors) else { errors.error = nil; return nil }
            var tabs: [TabSnapshot] = []
            if isTerminal {
                for tab in try children(window, "ttab", errors: errors) {
                    let tty = optionalText(tab, "ttty", errors: errors)
                    let selected = (tab.property(withCode: code("tbsl")).get() as? NSNumber)?.boolValue ?? false
                    errors.error = nil
                    let programs = ((tab.property(withCode: code("prcs")).get() as? [String]) ?? [])
                        .map { URL(fileURLWithPath: $0).lastPathComponent }.filter { !shells.contains($0) }
                    errors.error = nil
                    let title = optionalText(tab, "titl", errors: errors)
                    let device = tty.replacingOccurrences(of: "/dev/", with: "")
                    let path = directories[device]
                    let detail = ([path ?? ""] + programs + [device]).filter { !$0.isEmpty }.joined(separator: " · ")
                    tabs.append(TabSnapshot(id: id + ":" + tty, title: TerminalDirectories.title(title.isEmpty ? (programs.last ?? "shell") : title, path: path),
                        url: detail, active: selected, rawTitle: title))
                }
            } else {
                let current = (window.property(withCode: code("Wcsn")).get() as? SBObject).map { optionalText($0, "Uniq", errors: errors) } ?? ""
                errors.error = nil
                for tab in try children(window, "Trmt", errors: errors) {
                    for session in (try? children(tab, "Trms", errors: errors)) ?? [] {
                        let unique = optionalText(session, "Uniq", errors: errors)
                        let tty = optionalText(session, "Stty", errors: errors).replacingOccurrences(of: "/dev/", with: "")
                        let path = directories[tty]
                        let name = optionalText(session, "pnam", errors: errors)
                        tabs.append(TabSnapshot(id: unique, title: TerminalDirectories.title(name, path: path),
                            url: ([path ?? ""] + (details[tty]?.programs ?? []) + [tty]).filter { !$0.isEmpty }.joined(separator: " · "),
                            active: !unique.isEmpty && unique == current, rawTitle: name))
                    }
                    errors.error = nil
                }
            }
            return WindowSnapshot(id: id, frame: .zero, tabs: tabs)
        }
    }

    /// 把 Chrome / Edge 的一个标签移到新窗口（页面不重新加载）。按标签 ID 查找：若脚本发到了同名的其他实例，只会找不到而返回 false。
    static func moveTabToNewWindow(_ tab: BrowserTab, browser: TabBrowser) async throws -> Bool {
        guard browser.isChromium, tab.tabID.allSatisfy(\.isNumber) else { return false }
        let source = """
            tell application id "\(browser.rawValue)"
                set targetID to \(tab.tabID)
                repeat with w in windows
                    set windowID to id of w
                    if (id of tabs of w) contains targetID then
                        if (count of tabs of window id windowID) is 1 then return true
                        -- 新建窗口会改变窗口顺序，之后一律用窗口 ID 与标签 ID 定位
                        set newWindow to make new window
                        set newWindowID to id of newWindow
                        set blankTabID to id of tab 1 of window id newWindowID
                        move (tab id targetID of window id windowID) to end of tabs of window id newWindowID
                        close (tab id blankTabID of window id newWindowID)
                        return true
                    end if
                end repeat
            end tell
            return false
            """
        return try await run {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { throw BrowserBridgeError.script(L("%@ 拆分标签失败：%@", browser.name, (error[NSAppleScript.errorMessage] as? String) ?? "")) }
            return result?.booleanValue ?? false
        }
    }

    /// 切换到终端标签：用 AppleScript 按 TTY（终端）或会话 ID（iTerm2）查找，再选中标签并把窗口放到最前。终端标签不提供关闭，避免中断会话。
    static func actTerminal(tab: BrowserTab, browser: TabBrowser) async throws -> Bool {
        let key = browser == .terminal ? String(tab.tabID.split(separator: ":", maxSplits: 1).last ?? "") : tab.tabID
        let safeKey = key.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let source = browser == .terminal ? """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(safeKey)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """ : """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if unique ID of s is "\(safeKey)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        return try await run {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { throw BrowserBridgeError.script(L("%@ 切换标签失败：%@", browser.name, (error[NSAppleScript.errorMessage] as? String) ?? "")) }
            return result?.booleanValue ?? false
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
    /// 可切换「标签页 / 窗口」的栏目：单个浏览器或终端，以及汇总的「全部窗口」「浏览器」「终端」。
    var isTabFolder: Bool { currentTabBrowser != nil || ["all", "browsers", "terminals"].contains(selection) }
    /// 当前栏目涉及的应用；汇总栏目只包含正在运行且有窗口的应用。
    var tabFolderBrowsers: [TabBrowser] {
        if let browser = currentTabBrowser { return [browser] }
        guard isTabFolder else { return [] }
        return TabBrowser.allCases.filter { browser in
            (selection == "all" || (selection == "terminals") == browser.isTerminal)
                && windows.contains { $0.appID == browser.rawValue }
        }
    }
    var tabFolderName: String {
        if let browser = currentTabBrowser { return browser.name }
        switch selection { case "terminals": return L("所有终端"); case "browsers": return L("所有浏览器"); default: return L("浏览器和终端") }
    }
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
        let items = browserTabs.filter { tab in
            included.contains(tab.appID) && searchMatches(query, tab.title, tab.rawTitle, tab.url, tab.location, TabBrowser(rawValue: tab.appID)?.name ?? "")
        }
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

    /// 浏览器栏目默认显示标签页；终端栏目和汇总栏目默认显示窗口（沿用旧版习惯）。
    var tabsDefaultOn: Bool { currentTabBrowser.map { !$0.isTerminal } ?? false }
    func setShowTabs(_ show: Bool) {
        var f = folder
        if tabsDefaultOn { f.showTabs = show } else { f.aggregateTabs = show }
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
                        let parent: CGWindowID?
                        if browser.isTerminal {
                            // 终端窗口 ID 就是窗口服务器编号。
                            parent = UInt32(snapshot.id).flatMap { id in windows.contains { $0.id == id } ? id : nil }
                        } else {
                            let parents = windows.filter { $0.pid == running.processIdentifier && geometryDistance($0.frame, snapshot.frame) <= 8 }
                            parent = parents.count == 1 ? parents[0].id : nil
                        }
                        for (order, value) in snapshot.tabs.enumerated() {
                            var tab = BrowserTab(appID: browser.rawValue, pid: running.processIdentifier, tabID: value.id,
                                browserWindowID: snapshot.id, windowNumber: offset + 1, title: value.title.isEmpty ? L("无标题标签页") : value.title,
                                url: value.url, active: value.active, windowFrame: snapshot.frame, parentWindowID: parent)
                            tab.order = order
                            tab.rawTitle = value.rawTitle.isEmpty ? value.title : value.rawTitle
                            tab.firstSeen = discoveryDate(appID: tab.appID, pid: tab.pid, kind: "tab", id: browser == .safari ? tab.url : tab.tabID)
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

    // MARK: 标签多选与排列

    /// 当前选中的标签，按显示顺序。
    var orderedTabSelection: [BrowserTab] {
        let chosen = markedTabIDs.isEmpty ? Set(selectedTabID.map { [$0] } ?? []) : markedTabIDs
        return filteredTabs.filter { chosen.contains($0.id) }
    }
    func isTabSelected(_ id: String) -> Bool { markedTabIDs.isEmpty ? selectedTabID == id : markedTabIDs.contains(id) }

    /// 单击标签：普通单击单选；Shift 连续选择；⌥ 或 ⌘ 逐个加选/取消。
    func clickTab(_ tab: BrowserTab) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            markedTabIDs = Set(rangeSelection(filteredTabs.map(\.id), anchor: tabSelectionAnchor ?? selectedTabID, target: tab.id))
            selectedTabID = tab.id
        } else if flags.contains(.option) || flags.contains(.command) {
            var marked = markedTabIDs
            if marked.isEmpty, let current = selectedTabID { marked.insert(current) }
            if marked.contains(tab.id) { marked.remove(tab.id) } else { marked.insert(tab.id) }
            markedTabIDs = marked
            selectedTabID = marked.contains(tab.id) ? tab.id : marked.first
            tabSelectionAnchor = tab.id
        } else {
            markedTabIDs = []
            selectedTabID = tab.id
            tabSelectionAnchor = tab.id
        }
    }
    func clearTabSelection() { markedTabIDs = []; selectedTabID = nil; tabSelectionAnchor = nil }

    /// 选中标签所在的窗口（去重，按标签顺序）。
    func parentWindows(of tabs: [BrowserTab]) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        return tabs.compactMap(\.parentWindowID).filter { seen.insert($0).inserted }
    }

    /// 先把 Chrome / Edge 的标签各自拆成独立窗口，再排列。同一窗口里只剩这一个标签时不拆；其他应用的标签排列其所在窗口。
    func splitTabsAndTile(_ tabs: [BrowserTab], layout: TileLayout, displayID: CGDirectDisplayID? = nil, perDisplay: Bool = false) {
        guard tabs.count <= TileLayout.maxWindows else {
            errorMessage = L("一次最多排列 %d 个窗口，请减少选择。", TileLayout.maxWindows); return
        }
        Task {
            var failed = 0
            for tab in tabs {
                guard let browser = TabBrowser(rawValue: tab.appID), browser.isChromium else { continue }
                let alone = browserTabs.filter { $0.appID == tab.appID && $0.browserWindowID == tab.browserWindowID }.count <= 1
                if alone { continue }
                if !((try? await BrowserBridge.moveTabToNewWindow(tab, browser: browser)) ?? false) { failed += 1 }
            }
            // 新窗口出现在窗口列表里需要片刻；刷新窗口和标签，拿到每个标签现在所在的窗口。
            try? await Task.sleep(for: .milliseconds(700))
            await refresh()
            lastTabRefresh = .distantPast
            await refreshBrowserTabs()
            let ids = Set(tabs.map(\.id))
            let current = browserTabs.filter { ids.contains($0.id) }
            let ordered = tabs.compactMap { tab in current.first { $0.id == tab.id } }
            tileWindows(parentWindows(of: ordered), layout: layout, displayID: displayID, perDisplay: perDisplay)
            if failed > 0 { errorMessage = L("有 %d 个标签没能拆成独立窗口，已排列它们所在的窗口。", failed) }
            clearTabSelection()
        }
    }

    func actOnTab(_ tab: BrowserTab, close: Bool = false) {
        selectedTabID = tab.id
        guard let browser = TabBrowser(rawValue: tab.appID),
              NSRunningApplication(processIdentifier: tab.pid)?.bundleIdentifier == tab.appID else {
            browserErrors[tab.appID] = L("浏览器已重新启动，请重新读取标签页。"); return
        }
        if browser.isTerminal {
            guard !close else { return }
            Task {
                do {
                    if !(try await BrowserBridge.actTerminal(tab: tab, browser: browser)) {
                        browserErrors[tab.appID] = L("这个标签页已关闭。正在更新列表。")
                    }
                    await refreshBrowserTabs()
                } catch { browserErrors[tab.appID] = error.localizedDescription }
            }
            return
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

/// 终端标签的工作目录：按 TTY 找到其中的 shell 进程，读取当前目录（只读进程元信息，不读终端内容）。
enum TerminalDirectories {
    private static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "nu"]

    struct Info { var path: String?; var programs: [String] }

    /// TTY（如 ttys023）→ 以 ~ 开头的完整路径。
    static func byTTY() -> [String: String] { details().compactMapValues(\.path) }

    /// TTY → 工作目录与正在运行的非 shell 程序（如 claude、codex、node）。
    static func details() -> [String: Info] {
        let ps = Process(); let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,tty=,comm="]
        ps.standardOutput = pipe; ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()
        var shellsByTTY: [String: (pid: Int32, path: String)] = [:]
        var programs: [String: [String]] = [:]
        let ignored: Set<String> = ["login", "caffeinate", "ps"]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " }).map(String.init)
            guard parts.count == 3, let pid = Int32(parts[0]), parts[1].hasPrefix("ttys") else { continue }
            let name = URL(fileURLWithPath: parts[2]).lastPathComponent
            if !shells.contains(name) {
                if !ignored.contains(name), !(programs[parts[1]] ?? []).contains(name) { programs[parts[1], default: []].append(name) }
                continue
            }
            guard let path = currentDirectory(pid) else { continue }
            // 同一个 TTY 上常有提示符插件派生的辅助 shell（工作目录为 /）。优先取目录不是 / 的、最早启动（编号最小）的交互 shell。
            if let existing = shellsByTTY[parts[1]] {
                let existingRoot = existing.path == "/", candidateRoot = path == "/"
                if candidateRoot && !existingRoot { continue }
                if candidateRoot == existingRoot && existing.pid < pid { continue }
            }
            shellsByTTY[parts[1]] = (pid, abbreviate(path))
        }
        var result: [String: Info] = [:]
        for tty in Set(shellsByTTY.keys).union(programs.keys) {
            result[tty] = Info(path: shellsByTTY[tty]?.path, programs: programs[tty] ?? [])
        }
        return result
    }

    private static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// 终端自己缩写的路径标题（如「..codex/26codex (-zsh)」）换成完整路径；AI 会话等自定义标题保持不变。
    static func title(_ raw: String, path: String?) -> String {
        guard let path else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        var suffix = ""
        var head = trimmed
        if let open = trimmed.range(of: " (", options: .backwards), trimmed.hasSuffix(")") {
            suffix = String(trimmed[open.lowerBound...]); head = String(trimmed[..<open.lowerBound])
        }
        let looksLikePath = head.hasPrefix("..") || head.hasPrefix("~") || head.hasPrefix("/") || head.isEmpty
        return looksLikePath ? path + suffix : trimmed
    }
}

/// 截图时判断窗口当前显示的是哪个标签：用窗口的实时标题（截图那一刻）与各标签的原始标题比对。
/// 只有唯一匹配，或多个匹配中恰好有列表里记录的当前标签时才认定；无法确定就不保存，宁可不存也不记错。
func tabShownInWindow(liveTitle: String, tabs: [BrowserTab]) -> BrowserTab? {
    let live = liveTitle.trimmingCharacters(in: .whitespaces)
    guard !live.isEmpty else { return nil }
    let matches = tabs.filter { tab in
        let raw = (tab.rawTitle.isEmpty ? tab.title : tab.rawTitle).trimmingCharacters(in: .whitespaces)
        // 终端窗口标题常在标签标题前后加目录、进程等（包含标签标题）；浏览器窗口标题可能比标签标题短（被标签标题包含）。
        return !raw.isEmpty && (live == raw || live.contains(raw) || (live.count >= 8 && raw.contains(live)))
    }
    if matches.count == 1 { return matches[0] }
    // 标题包含关系可能命中多个（如「~ (-zsh)」），优先取标题完全相同的唯一一个。
    let exact = matches.filter { ($0.rawTitle.isEmpty ? $0.title : $0.rawTitle).trimmingCharacters(in: .whitespaces) == live }
    if exact.count == 1 { return exact[0] }
    let candidates = exact.isEmpty ? matches : exact
    let active = candidates.filter(\.active)
    return active.count == 1 ? active[0] : nil
}

/// 窗口此刻的标题（窗口服务器实时数据）。
func liveWindowTitle(_ id: CGWindowID) -> String? {
    guard let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
          let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else { return nil }
    return entry[kCGWindowName as String] as? String
}

