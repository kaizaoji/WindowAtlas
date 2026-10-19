import AppKit
import Foundation

/// 第三方终端的会话读取与切换（Terminal、iTerm2 见 BrowserBridge.readTerminal）。
/// 精确层：Ghostty（AppleScript）、WezTerm（wezterm cli）、Kitty（远程控制套接字），可列出每个标签 / 分屏并直接切换；
/// 通用层：其他终端或接口不可用时，按进程树找出该终端启动的 shell，列出每个会话的工作目录与运行程序。
/// 只读进程元信息与终端自己公开的标签信息，不读取终端内容、不执行命令。
enum TerminalSessions {
    /// 截图窗口的编号与标题，用于把终端自己的窗口对应到缩略图窗口。
    struct WindowRef: Sendable, Equatable { let id: CGWindowID; let title: String }

    typealias Snapshot = BrowserBridge.WindowSnapshot
    typealias Tab = BrowserBridge.TabSnapshot

    /// 读取一个终端实例：先试精确层，接口不可用（返回 nil）时退回通用层。
    static func read(pid: pid_t, browser: TabBrowser, windows: [WindowRef]) throws -> [Snapshot] {
        let entries = TerminalDirectories.processes()
        let sessions = TerminalDirectories.details(entries, under: pid)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL
        switch browser {
        case .ghostty: return try readGhostty(sessions: sessions, windows: windows)
        case .wezterm:
            if let bundle, let result = readWezTerm(bundle: bundle, sessions: sessions, windows: windows) { return result }
        case .kitty:
            let ttyByPID = Dictionary(entries.map { ($0.pid, $0.tty) }, uniquingKeysWith: { first, _ in first })
            if let bundle, let socket = kittySocket(pid: pid),
               let result = readKitty(bundle: bundle, socket: socket, sessions: sessions, ttyByPID: ttyByPID, windows: windows) { return result }
        default: break
        }
        return generic(sessions: sessions, windows: windows)
    }

    // MARK: 通用层

    /// 按进程树列出会话。终端没有标签接口，只能按窗口标题把会话归到窗口：
    /// 应用只有一个窗口时全部归入；否则标题里出现该会话路径的才归入（通常是窗口当前显示的标签），其余归到「未对应窗口」。
    static func generic(sessions: [String: TerminalDirectories.Info], windows: [WindowRef]) -> [Snapshot] {
        let ordered = sessions.sorted { ttyNumber($0.key) < ttyNumber($1.key) }
        var groups: [(key: String, tabs: [Tab])] = []
        func append(_ tab: Tab, to key: String) {
            if let index = groups.firstIndex(where: { $0.key == key }) { groups[index].tabs.append(tab) } else { groups.append((key, [tab])) }
        }
        for (tty, info) in ordered {
            let matched = matchWindow(titles: [], path: info.path, windows: windows)
            let window = windows.count == 1 ? windows[0].id : matched
            let title = info.path.map(folderName) ?? info.programs.last ?? tty
            let tab = Tab(id: "tty:" + tty, title: title, url: detail(path: info.path, programs: info.programs, tty: tty),
                          active: matched != nil, rawTitle: title)
            append(tab, to: window.map { String($0) } ?? "unassigned")
        }
        return groups.map { group in
            // 窗口里只有一个会话时它就是当前显示的标签
            let tabs = group.tabs.count == 1
                ? [Tab(id: group.tabs[0].id, title: group.tabs[0].title, url: group.tabs[0].url, active: true, rawTitle: group.tabs[0].rawTitle)]
                : group.tabs
            return Snapshot(id: group.key, frame: .zero, tabs: tabs)
        }
    }

    // MARK: Ghostty（AppleScript：窗口 → 标签 → 终端，带工作目录）

    private static let fieldSeparator = "\u{1F}", recordSeparator = "\u{1E}"

    static func readGhostty(sessions: [String: TerminalDirectories.Info], windows: [WindowRef]) throws -> [Snapshot] {
        let source = """
            set fs to character id 31
            set rs to character id 30
            set out to ""
            tell application id "\(TabBrowser.ghostty.rawValue)"
                repeat with w in windows
                    set wid to id of w
                    repeat with t in tabs of w
                        set focusedID to ""
                        try
                            set focusedID to id of focused terminal of t
                        end try
                        repeat with x in terminals of t
                            set out to out & wid & fs & (name of t) & fs & (selected of t) & fs & (id of x) & fs & (name of x) & fs & (working directory of x) & fs & focusedID & rs
                        end repeat
                    end repeat
                end repeat
            end tell
            return out
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw scriptError(error, browser: .ghostty) }
        return ghosttySnapshots(result?.stringValue ?? "", sessions: sessions, windows: windows)
    }

    /// 解析 Ghostty 脚本输出（每行：窗口、标签名、标签是否选中、终端 ID、终端名、工作目录、标签内聚焦终端）。
    /// Ghostty 的每个标签都是独立系统窗口，屏幕上只有选中标签那一个；按选中标签名对应缩略图窗口。
    static func ghosttySnapshots(_ output: String, sessions: [String: TerminalDirectories.Info], windows: [WindowRef]) -> [Snapshot] {
        struct Row { let window, tabName: String; let selected: Bool; let id, name, path, focused: String }
        let rows = output.components(separatedBy: recordSeparator).compactMap { line -> Row? in
            let fields = line.components(separatedBy: fieldSeparator)
            guard fields.count == 7, !fields[3].isEmpty else { return nil }
            return Row(window: fields[0], tabName: fields[1], selected: fields[2] == "true", id: fields[3], name: fields[4],
                       path: fields[5], focused: fields[6])
        }
        var order: [String] = []
        for row in rows where !order.contains(row.window) { order.append(row.window) }
        return order.map { group in
            let members = rows.filter { $0.window == group }
            let selectedNames = members.filter(\.selected).map(\.tabName)
            let windowID = matchWindow(titles: selectedNames, path: nil, windows: windows) ?? (windows.count == 1 ? windows[0].id : nil)
            let tabs = members.map { row -> Tab in
                let path = row.path.isEmpty ? nil : TerminalDirectories.abbreviate(row.path)
                let session = uniqueSession(path: path, in: sessions)
                return Tab(id: row.id, title: TerminalDirectories.title(row.name, path: path),
                           url: detail(path: path, programs: session?.info.programs ?? [], tty: session?.tty),
                           active: row.selected && (row.focused.isEmpty || row.focused == row.id), rawTitle: row.name)
            }
            return Snapshot(id: windowID.map { String($0) } ?? "ghostty:" + group, frame: .zero, tabs: tabs)
        }
    }

    // MARK: WezTerm（wezterm cli list）

    static func readWezTerm(bundle: URL, sessions: [String: TerminalDirectories.Info], windows: [WindowRef]) -> [Snapshot]? {
        let tool = bundle.appendingPathComponent("Contents/MacOS/wezterm")
        // --no-auto-start：GUI 没有运行时不要替用户启动新的 WezTerm
        guard let data = runTool(tool, ["cli", "--no-auto-start", "list", "--format", "json"]) else { return nil }
        return weztermSnapshots(data, sessions: sessions, windows: windows)
    }

    static func weztermSnapshots(_ data: Data, sessions: [String: TerminalDirectories.Info], windows: [WindowRef]) -> [Snapshot]? {
        struct Pane: Decodable {
            let window_id: Int, tab_id: Int, pane_id: Int
            let title: String
            let cwd: String?
            let tty_name: String?
            let is_active: Bool?
            let window_title: String?
        }
        guard let panes = try? JSONDecoder().decode([Pane].self, from: data) else { return nil }
        var order: [Int] = []
        for pane in panes where !order.contains(pane.window_id) { order.append(pane.window_id) }
        return order.map { windowKey in
            let members = panes.filter { $0.window_id == windowKey }
            let windowTitle = members.first?.window_title ?? ""
            // 截图窗口标题有时是完整窗口标题（含 用户@主机），有时只是当前分屏标题，两者都参与匹配
            let activeTitles = members.filter { ($0.is_active ?? false) && windowTitle.contains($0.title) }.map(\.title)
            let windowID = matchWindow(titles: [windowTitle] + activeTitles, path: nil, windows: windows) ?? (windows.count == 1 ? windows[0].id : nil)
            let tabs = members.map { pane -> Tab in
                let path = pane.cwd.flatMap(fileURLPath).map(TerminalDirectories.abbreviate)
                let tty = pane.tty_name.map { $0.replacingOccurrences(of: "/dev/", with: "") }
                let programs = tty.flatMap { sessions[$0]?.programs } ?? []
                // 窗口标题跟随当前标签的当前分屏，借此判断哪个标签正在显示
                let active = (pane.is_active ?? false) && !pane.title.isEmpty && windowTitle.contains(pane.title)
                return Tab(id: "pane:\(pane.pane_id)", title: TerminalDirectories.title(pane.title, path: path),
                           url: detail(path: path, programs: programs, tty: tty), active: active, rawTitle: pane.title)
            }
            return Snapshot(id: windowID.map { String($0) } ?? "wezterm:\(windowKey)", frame: .zero, tabs: tabs)
        }
    }

    // MARK: Kitty（远程控制：kitten @ ls）

    /// Kitty 需要用户在 kitty.conf 开启 allow_remote_control 与 listen_on（unix 套接字）才能从外部读取。
    /// 配置了 listen_on 时 Kitty 会在路径后加「-进程号」，也支持 {kitty_pid} 占位。
    static func kittySocket(pid: pid_t) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configs = ["\(home)/.config/kitty/kitty.conf", "\(home)/Library/Preferences/kitty/kitty.conf"]
        for config in configs {
            guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { continue }
            for base in kittyListenPaths(text) {
                let resolved = (base.replacingOccurrences(of: "{kitty_pid}", with: "\(pid)") as NSString).expandingTildeInPath
                for candidate in [resolved + "-\(pid)", resolved] where isSocket(candidate) { return candidate }
            }
        }
        return nil
    }

    /// 从 kitty.conf 中取出 `listen_on unix:路径`（忽略注释与 Linux 专用的抽象套接字 @name）。
    static func kittyListenPaths(_ config: String) -> [String] {
        config.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[0] == "listen_on" else { return nil }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("unix:"), !value.hasPrefix("unix:@") else { return nil }
            return String(value.dropFirst(5))
        }
    }

    static func readKitty(bundle: URL, socket: String, sessions: [String: TerminalDirectories.Info],
                          ttyByPID: [Int32: String], windows: [WindowRef]) -> [Snapshot]? {
        let tool = bundle.appendingPathComponent("Contents/MacOS/kitten")
        guard let data = runTool(tool, ["@", "--to", "unix:" + socket, "ls"]) else { return nil }
        return kittySnapshots(data, sessions: sessions, ttyByPID: ttyByPID, windows: windows)
    }

    /// ttyByPID：进程号 → TTY。Kitty 返回的是它直接启动的进程（通常是 login，不是 shell）。
    static func kittySnapshots(_ data: Data, sessions: [String: TerminalDirectories.Info],
                               ttyByPID: [Int32: String] = [:], windows: [WindowRef]) -> [Snapshot]? {
        struct Process: Decodable { let cmdline: [String]? }
        struct Pane: Decodable {
            let id: Int, title: String, cwd: String?, pid: Int32?
            let is_active: Bool?, is_focused: Bool?
            let foreground_processes: [Process]?
        }
        struct KittyTab: Decodable { let title: String; let is_active: Bool?, is_focused: Bool?; let windows: [Pane] }
        struct OSWindow: Decodable { let id: Int; let platform_window_id: UInt32?; let tabs: [KittyTab] }
        guard let osWindows = try? JSONDecoder().decode([OSWindow].self, from: data) else { return nil }
        let ttyByShell = Dictionary(sessions.compactMap { tty, info in info.shellPID.map { ($0, tty) } }, uniquingKeysWith: { first, _ in first })
        let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "nu", "login"]
        return osWindows.map { osWindow in
            let known = osWindow.platform_window_id.flatMap { id in windows.contains { $0.id == id } ? id : nil }
            let windowID = known ?? (windows.count == 1 ? windows[0].id : nil)
            let tabs = osWindow.tabs.flatMap { tab in
                tab.windows.map { pane -> Tab in
                    let path = pane.cwd.map(TerminalDirectories.abbreviate)
                    let tty = pane.pid.flatMap { ttyByPID[$0] ?? ttyByShell[$0] }
                    let foreground = (pane.foreground_processes ?? []).compactMap { $0.cmdline?.first }
                        .map { URL(fileURLWithPath: $0).lastPathComponent }.filter { !shells.contains($0) }
                    let programs = foreground.isEmpty ? (tty.flatMap { sessions[$0]?.programs } ?? []) : foreground
                    let active = (tab.is_active ?? tab.is_focused ?? false) && (pane.is_active ?? pane.is_focused ?? false)
                    return Tab(id: "kitty:\(pane.id)", title: TerminalDirectories.title(pane.title, path: path),
                               url: detail(path: path, programs: programs, tty: tty), active: active, rawTitle: pane.title)
                }
            }
            return Snapshot(id: windowID.map { String($0) } ?? "kitty:\(osWindow.id)", frame: .zero, tabs: tabs)
        }
    }

    // MARK: 切换

    /// 切到指定会话所在的标签 / 分屏。返回 false 表示会话已不存在；通用层没有标签接口，直接返回 true，由调用方聚焦窗口。
    static func activate(tab: BrowserTab, browser: TabBrowser) async throws -> Bool {
        let bundle = NSRunningApplication(processIdentifier: tab.pid)?.bundleURL
        return try await Task.detached(priority: .userInitiated) {
            switch browser {
            case .ghostty:
                guard tab.tabID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return false }
                let source = """
                    tell application id "\(TabBrowser.ghostty.rawValue)"
                        repeat with x in terminals
                            if id of x is "\(tab.tabID)" then
                                focus x
                                activate
                                return true
                            end if
                        end repeat
                    end tell
                    return false
                    """
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { throw scriptError(error, browser: browser) }
                return result?.booleanValue ?? false
            case .wezterm where tab.tabID.hasPrefix("pane:"):
                guard let bundle, let pane = Int(tab.tabID.dropFirst(5)) else { return true }
                return runTool(bundle.appendingPathComponent("Contents/MacOS/wezterm"),
                               ["cli", "--no-auto-start", "activate-pane", "--pane-id", "\(pane)"]) != nil
            case .kitty where tab.tabID.hasPrefix("kitty:"):
                guard let bundle, let pane = Int(tab.tabID.dropFirst(6)), let socket = kittySocket(pid: tab.pid) else { return true }
                return runTool(bundle.appendingPathComponent("Contents/MacOS/kitten"),
                               ["@", "--to", "unix:" + socket, "focus-window", "--match", "id:\(pane)"]) != nil
            default:
                return true
            }
        }.value
    }

    // MARK: 修改终端标签标题

    /// 把终端标签的标题改成 title（空字符串恢复终端默认标题）。返回 false 表示该终端没有可用接口或标签已不存在。
    static func setTitle(tab: BrowserTab, browser: TabBrowser, title: String) async throws -> Bool {
        let bundle = NSRunningApplication(processIdentifier: tab.pid)?.bundleURL
        let quoted = appleScriptString(title)
        let safeID = tab.tabID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" || $0 == "/" }
        return try await Task.detached(priority: .userInitiated) {
            switch browser {
            case .terminal:
                // 终端标签 ID 为「窗口:TTY」
                let tty = String(safeID.split(separator: ":", maxSplits: 1).last ?? "")
                return try runAppleScript("""
                    tell application id "\(TabBrowser.terminal.rawValue)"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t is "\(tty)" then
                                    set custom title of t to \(quoted)
                                    set title displays custom title of t to \(title.isEmpty ? "false" : "true")
                                    return true
                                end if
                            end repeat
                        end repeat
                    end tell
                    return false
                    """, browser: browser)
            case .iterm:
                return try runAppleScript("""
                    tell application id "\(TabBrowser.iterm.rawValue)"
                        repeat with w in windows
                            repeat with t in tabs of w
                                repeat with s in sessions of t
                                    if unique ID of s is "\(safeID)" then
                                        set name of s to \(quoted)
                                        return true
                                    end if
                                end repeat
                            end repeat
                        end repeat
                    end tell
                    return false
                    """, browser: browser)
            case .ghostty:
                // Ghostty 的标签标题覆盖：set_tab_title:名称，名称为空即恢复
                return try runAppleScript("""
                    tell application id "\(TabBrowser.ghostty.rawValue)"
                        repeat with x in terminals
                            if id of x is "\(safeID)" then
                                return perform action ("set_tab_title:" & \(quoted)) on x
                            end if
                        end repeat
                    end tell
                    return false
                    """, browser: browser)
            case .wezterm where tab.tabID.hasPrefix("pane:"):
                guard let bundle, let pane = Int(tab.tabID.dropFirst(5)) else { return false }
                return runTool(bundle.appendingPathComponent("Contents/MacOS/wezterm"),
                               ["cli", "--no-auto-start", "set-tab-title", "--pane-id", "\(pane)", title]) != nil
            case .kitty where tab.tabID.hasPrefix("kitty:"):
                guard let bundle, let pane = Int(tab.tabID.dropFirst(6)), let socket = kittySocket(pid: tab.pid) else { return false }
                // 不带标题参数时 kitty 恢复默认标题
                return runTool(bundle.appendingPathComponent("Contents/MacOS/kitten"),
                               ["@", "--to", "unix:" + socket, "set-tab-title", "--match", "id:\(pane)"] + (title.isEmpty ? [] : [title])) != nil
            default:
                return false
            }
        }.value
    }

    /// 该标签所在终端是否有修改标签标题的接口（与 setTitle 支持的范围一致）。
    static func canSetTitle(_ tab: BrowserTab) -> Bool {
        switch TabBrowser(rawValue: tab.appID) {
        case .terminal, .iterm, .ghostty: return true
        case .wezterm: return tab.tabID.hasPrefix("pane:")
        case .kitty: return tab.tabID.hasPrefix("kitty:")
        default: return false
        }
    }

    /// 备注名：去掉换行等控制字符，最长 40 个字符。
    static func sanitizedTitle(_ raw: String) -> String {
        let visible = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return String(visible.trimmingCharacters(in: .whitespaces).prefix(40))
    }

    /// 生成 AppleScript 字符串字面量，转义反斜杠与引号，防止名称里的字符改变脚本。
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAppleScript(_ source: String, browser: TabBrowser) throws -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw scriptError(error, browser: browser) }
        return result?.booleanValue ?? false
    }

    // MARK: 工具

    /// 按标题把终端自己的窗口对应到截图窗口：标题完全相同优先，其次标题包含会话路径；只接受唯一结果。
    static func matchWindow(titles: [String], path: String?, windows: [WindowRef]) -> CGWindowID? {
        let names = titles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let exact = windows.filter { window in names.contains(window.title) }
        if exact.count == 1 { return exact[0].id }
        let containing = windows.filter { window in names.contains { window.title.contains($0) } }
        if containing.count == 1 { return containing[0].id }
        guard let path, path != "~", path != "/" else { return nil }
        let full = (path as NSString).expandingTildeInPath
        let byPath = windows.filter { $0.title.contains(path) || $0.title.contains(full) }
        return byPath.count == 1 ? byPath[0].id : nil
    }

    /// 与 Terminal、iTerm2 相同的格式：「工作目录 · 程序… · TTY」，卡片与搜索据此显示路径。
    static func detail(path: String?, programs: [String], tty: String?) -> String {
        ([path ?? ""] + programs + [tty ?? ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 同一终端里只有一个会话位于该目录时，才借用它的 TTY 与运行程序，避免张冠李戴。
    static func uniqueSession(path: String?, in sessions: [String: TerminalDirectories.Info]) -> (tty: String, info: TerminalDirectories.Info)? {
        guard let path else { return nil }
        let matches = sessions.filter { $0.value.path == path }
        return matches.count == 1 ? (matches.first!.key, matches.first!.value) : nil
    }

    static func folderName(_ path: String) -> String { path == "~" || path == "/" ? path : URL(fileURLWithPath: path).lastPathComponent }

    private static func ttyNumber(_ tty: String) -> Int { Int(tty.drop { !$0.isNumber }) ?? Int.max }

    /// file://主机名/路径 → 本地路径（WezTerm 的 cwd 格式）。
    static func fileURLPath(_ value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL else { return value.hasPrefix("/") ? value : nil }
        return url.path.isEmpty ? nil : url.path
    }

    private static func isSocket(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSocket
    }

    private static func scriptError(_ error: NSDictionary, browser: TabBrowser) -> BrowserBridgeError {
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? ""
        return .script(code == -1743
            ? L("请在系统设置 → 隐私与安全性 → 自动化中，允许窗口图鉴控制 %@。", browser.name)
            : L("%@ 读取失败（%d）：%@", browser.name, code, message))
    }

    /// 运行终端自带的命令行工具（参数直接传给进程，不经过 shell）。超时或失败返回 nil，调用方退回通用层。
    static func runTool(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 3) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        // 在另一线程读输出：输出超过管道缓冲时，子进程会卡在写入上而无法结束
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box(), readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        // 正常结束后输出很快读完；若有子进程仍占着管道，最多再等 1 秒
        guard readDone.wait(timeout: .now() + 1) == .success else { return nil }
        return process.terminationStatus == 0 ? box.data : nil
    }
}

@MainActor
extension WindowStore {
    /// 终端标签所在项目的备注名。
    func projectAlias(_ tab: BrowserTab) -> String? { tab.terminalFullPath.flatMap { projectAliases[$0] } }

    /// 保存（或清除）项目备注名，并同步到该项目当前打开的、支持改标题的终端标签。
    func setProjectAlias(_ raw: String, for tab: BrowserTab) {
        guard let path = tab.terminalFullPath else { return }
        let name = TerminalSessions.sanitizedTitle(raw)
        if name.isEmpty { projectAliases.removeValue(forKey: path) } else { projectAliases[path] = name }
        let targets = browserTabs.filter { $0.terminalFullPath == path }
        Task {
            var unsynced = Set<String>()
            for target in targets {
                guard let browser = TabBrowser(rawValue: target.appID) else { continue }
                let done = (try? await TerminalSessions.setTitle(tab: target, browser: browser, title: name)) ?? false
                if !done { unsynced.insert(browser.shortName) }
            }
            if !name.isEmpty && !unsynced.isEmpty {
                errorMessage = L("已保存备注。%@ 无法同步终端标签标题，只在窗口图鉴中显示。", unsynced.sorted().joined(separator: "、"))
            }
            await refreshBrowserTabs()
        }
    }
}
