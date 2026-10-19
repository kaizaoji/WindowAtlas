import XCTest
@testable import WindowAtlas

/// 第三方终端会话：进程树筛选、窗口对应，以及 Ghostty / WezTerm / Kitty 接口输出的解析。
final class TerminalSessionsTests: XCTestCase {
    private typealias Entry = TerminalDirectories.ProcessEntry
    private typealias Ref = TerminalSessions.WindowRef

    /// Warp（500）启动了两个会话；Terminal（900）的会话不能算到 Warp 名下。
    private let entries = [
        Entry(pid: 510, ppid: 500, tty: "ttys011", name: "login"),
        Entry(pid: 511, ppid: 510, tty: "ttys011", name: "-zsh"),
        Entry(pid: 512, ppid: 511, tty: "ttys011", name: "claude"),
        Entry(pid: 520, ppid: 500, tty: "ttys004", name: "-zsh"),
        Entry(pid: 910, ppid: 900, tty: "ttys002", name: "login"),
        Entry(pid: 911, ppid: 910, tty: "ttys002", name: "-zsh"),
    ]
    private let directories: [Int32: String] = [511: "/Users/x/dev/alpha", 520: "/Users/x/dev/beta", 911: "/Users/x/other"]

    private func sessions(under pid: pid_t) -> [String: TerminalDirectories.Info] {
        TerminalDirectories.details(entries, under: pid) { [directories] in directories[$0] }
    }

    func testDetailsUnderAppKeepsOnlyItsOwnShells() {
        let warp = sessions(under: 500)
        XCTAssertEqual(Set(warp.keys), ["ttys011", "ttys004"])
        XCTAssertEqual(warp["ttys011"]?.path, "/Users/x/dev/alpha")
        XCTAssertEqual(warp["ttys011"]?.programs, ["claude"])
        XCTAssertEqual(warp["ttys011"]?.shellPID, 511)
        XCTAssertEqual(Set(TerminalDirectories.details(entries) { [directories] in directories[$0] }.keys), ["ttys011", "ttys004", "ttys002"])
    }

    func testDescendantCheckStopsOnCycles() {
        XCTAssertFalse(TerminalDirectories.isDescendant(1, of: 9, parents: [1: 2, 2: 1]))
        XCTAssertTrue(TerminalDirectories.isDescendant(512, of: 500, parents: [512: 511, 511: 510, 510: 500]))
    }

    func testGenericSingleWindowHoldsEverySession() {
        let snapshots = TerminalSessions.generic(sessions: sessions(under: 500), windows: [Ref(id: 77, title: "alpha")])
        XCTAssertEqual(snapshots.map(\.id), ["77"])
        XCTAssertEqual(snapshots[0].tabs.map(\.id), ["tty:ttys004", "tty:ttys011"], "按 TTY 编号排序")
        XCTAssertEqual(snapshots[0].tabs.map(\.title), ["beta", "alpha"], "标题为项目文件夹名")
        XCTAssertEqual(snapshots[0].tabs[1].url, "/Users/x/dev/alpha · claude · ttys011")
    }

    func testGenericMultipleWindowsMatchByPathInTitle() {
        let windows = [Ref(id: 1, title: "x@mac: /Users/x/dev/alpha"), Ref(id: 2, title: "Warp")]
        let snapshots = TerminalSessions.generic(sessions: sessions(under: 500), windows: windows)
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.tabs.map(\.id)) })
        XCTAssertEqual(byID["1"], ["tty:ttys011"])
        XCTAssertEqual(byID["unassigned"], ["tty:ttys004"], "标题里看不出的会话不猜窗口")
        XCTAssertTrue(snapshots.first { $0.id == "1" }?.tabs[0].active ?? false)
    }

    func testMatchWindowRequiresUniqueResult() {
        let windows = [Ref(id: 1, title: "~/dev/alpha"), Ref(id: 2, title: "~/dev/alpha-old")]
        XCTAssertEqual(TerminalSessions.matchWindow(titles: ["~/dev/alpha"], path: nil, windows: windows), 1, "完全相同优先")
        XCTAssertNil(TerminalSessions.matchWindow(titles: [], path: "~/dev/alpha", windows: windows), "路径包含命中两个窗口时不猜")
        XCTAssertNil(TerminalSessions.matchWindow(titles: [], path: "~", windows: windows), "主目录太宽泛，不按路径匹配")
    }

    func testGhosttyOutputGroupsTabsUnderVisibleWindow() {
        let fs = "\u{1F}", rs = "\u{1E}"
        let home = NSHomeDirectory()
        let output = [
            ["tab-group-1", "x@mac:~", "false", "AAA-1", "x@mac:~", home, "AAA-1"],
            ["tab-group-1", "x@mac:~/Projects", "true", "BBB-2", "x@mac:~/Projects", home + "/Projects", "BBB-2"],
            ["tab-group-1", "x@mac:~/Projects", "true", "CCC-3", "split", home + "/Projects/app", "BBB-2"],
        ].map { $0.joined(separator: fs) }.joined(separator: rs) + rs
        let windows = [Ref(id: 40, title: "x@mac:~/Projects"), Ref(id: 41, title: "other")]
        let snapshots = TerminalSessions.ghosttySnapshots(output, sessions: [:], windows: windows)
        XCTAssertEqual(snapshots.map(\.id), ["40"], "按选中标签名对应屏幕上的窗口")
        XCTAssertEqual(snapshots[0].tabs.map(\.id), ["AAA-1", "BBB-2", "CCC-3"])
        XCTAssertEqual(snapshots[0].tabs.map(\.active), [false, true, false], "选中标签里获得焦点的分屏才是当前")
        XCTAssertEqual(snapshots[0].tabs[1].url, "~/Projects")
    }

    func testWezTermJSON() throws {
        let json = """
        [{"window_id":0,"tab_id":0,"pane_id":3,"title":"~/Projects","cwd":"file://mac.local/Users/x/Projects","tty_name":"/dev/ttys007","is_active":true,"window_title":"~/Projects"},
         {"window_id":0,"tab_id":1,"pane_id":4,"title":"vim","cwd":"file://mac.local/Users/x/My%20Notes","tty_name":"/dev/ttys008","is_active":true,"window_title":"~/Projects"}]
        """
        let sessions = ["ttys008": TerminalDirectories.Info(path: "/Users/x/My Notes", programs: ["vim"])]
        let snapshots = try XCTUnwrap(TerminalSessions.weztermSnapshots(Data(json.utf8), sessions: sessions,
            windows: [Ref(id: 9, title: "~/Projects"), Ref(id: 10, title: "x")]))
        XCTAssertEqual(snapshots.map(\.id), ["9"])
        XCTAssertEqual(snapshots[0].tabs.map(\.id), ["pane:3", "pane:4"])
        XCTAssertEqual(snapshots[0].tabs.map(\.active), [true, false], "窗口标题对应的标签才是当前显示的")
        XCTAssertEqual(snapshots[0].tabs[1].url, "/Users/x/My Notes · vim · ttys008", "路径解码空格")
        let shortTitles = try XCTUnwrap(TerminalSessions.weztermSnapshots(Data(json.replacingOccurrences(of: "\"window_title\":\"~/Projects\"", with: "\"window_title\":\"x@mac:~/Projects\"").utf8),
            sessions: [:], windows: [Ref(id: 9, title: "~/Projects"), Ref(id: 10, title: "~")]))
        XCTAssertEqual(shortTitles.map(\.id), ["9"], "截图窗口标题只有当前分屏标题时也能对应")
        XCTAssertNil(TerminalSessions.weztermSnapshots(Data("not json".utf8), sessions: [:], windows: []), "接口输出异常时退回通用层")
    }

    func testKittyJSONUsesPlatformWindowID() throws {
        let json = """
        [{"id":1,"platform_window_id":128499,"tabs":[
          {"title":"a","is_active":false,"windows":[{"id":1,"title":"~","cwd":"/Users/x/home","pid":700,"is_active":true,"foreground_processes":[{"cmdline":["-zsh"]}]}]},
          {"title":"b","is_active":true,"windows":[{"id":2,"title":"claude","cwd":"/Users/x/dev/alpha","pid":701,"is_active":true,"foreground_processes":[{"cmdline":["/usr/local/bin/claude","--resume"]}]}]}]}]
        """
        let sessions = ["ttys020": TerminalDirectories.Info(path: "/Users/x/dev/alpha", programs: ["claude"], shellPID: 701)]
        let snapshots = try XCTUnwrap(TerminalSessions.kittySnapshots(Data(json.utf8), sessions: sessions,
            windows: [Ref(id: 128499, title: "claude"), Ref(id: 5, title: "x")]))
        XCTAssertEqual(snapshots.map(\.id), ["128499"])
        XCTAssertEqual(snapshots[0].tabs.map(\.id), ["kitty:1", "kitty:2"])
        XCTAssertEqual(snapshots[0].tabs.map(\.active), [false, true])
        XCTAssertEqual(snapshots[0].tabs[1].url, "/Users/x/dev/alpha · claude · ttys020")
        XCTAssertEqual(snapshots[0].tabs[0].url, "/Users/x/home", "shell 本身不算运行程序")
        let viaLogin = try XCTUnwrap(TerminalSessions.kittySnapshots(Data(json.utf8), sessions: [:], ttyByPID: [700: "ttys030"], windows: []))
        XCTAssertEqual(viaLogin[0].tabs[0].url, "/Users/x/home · ttys030", "Kitty 返回 login 进程号时按进程号查 TTY")
        XCTAssertEqual(viaLogin[0].id, "kitty:1", "没有对应窗口时不借用其他窗口")
    }

    func testKittyListenOnParsing() {
        let config = """
        # listen_on unix:/tmp/commented
        allow_remote_control socket-only
        listen_on   unix:/tmp/kitty-{kitty_pid}
        listen_on unix:@abstract
        """
        XCTAssertEqual(TerminalSessions.kittyListenPaths(config), ["/tmp/kitty-{kitty_pid}"])
    }

    func testTaskSnapshotsKeepOnlyWindowedSessionsWithTTY() {
        let snapshots = [
            BrowserBridge.WindowSnapshot(id: "77", frame: .zero, tabs: [
                .init(id: "tty:ttys011", title: "alpha", url: "/Users/x/dev/alpha · claude · ttys011", active: true),
                .init(id: "AAA", title: "beta", url: "/Users/x/dev/beta", active: false)]),
            BrowserBridge.WindowSnapshot(id: "unassigned", frame: .zero, tabs: [
                .init(id: "tty:ttys004", title: "gamma", url: "/Users/x/gamma · ttys004", active: false)]),
        ]
        let tasks = TerminalTaskBridge.taskSnapshots(from: snapshots)
        XCTAssertEqual(tasks.map(\.id), [77], "对不上窗口的会话不计入任何窗口")
        XCTAssertEqual(tasks[0].sessions.map(\.tty), ["ttys011", ""], "没有 TTY 的会话保留为未知，避免误报空闲")
        let processes = [TerminalProcess(pid: 1, group: 1, foreground: 1, tty: "s011", state: "S", command: "claude", cpu: 1)]
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: tasks[0].sessions[0], processes: processes, previousCPU: [:]).0, .agent)
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: tasks[0].sessions[1], processes: processes, previousCPU: [:]).0, .unknown)
    }

    func testPromptHelperDoesNotCountAsTask() {
        // 空闲 shell（前台进程组为 shell）+ powerlevel10k 的 gitstatusd：应判为空闲，而不是「命令运行中」
        let session = TerminalSessionSnapshot(id: "s", tty: "ttys012", busy: nil, processing: nil, processes: [])
        let processes = [
            TerminalProcess(pid: 10, group: 10, foreground: 10, tty: "s012", state: "Ss+", command: "-zsh", cpu: 0.2),
            TerminalProcess(pid: 20, group: 15, foreground: 10, tty: "s012", state: "S", command: "/Users/x/.cache/gitstatus/gitstatusd-darwin-arm64", cpu: 0.1),
        ]
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session, processes: processes, previousCPU: [:]).0, .idle)
        let running = processes + [TerminalProcess(pid: 30, group: 30, foreground: 30, tty: "s012", state: "S+", command: "sleep", cpu: 0)]
        XCTAssertEqual(TerminalTaskEvaluator.evaluate(session: session, processes: running, previousCPU: [:]).0, .command)
    }

    func testAliasTitleIsSanitizedAndEscaped() {
        XCTAssertEqual(TerminalSessions.sanitizedTitle("  窗口图鉴\n后台\t "), "窗口图鉴后台", "去掉换行与控制字符")
        XCTAssertEqual(TerminalSessions.sanitizedTitle(String(repeating: "长", count: 60)).count, 40)
        // 名称里的引号与反斜杠不能提前结束 AppleScript 字符串
        XCTAssertEqual(TerminalSessions.appleScriptString(#"a"b\c"#), #""a\"b\\c""#)
    }

    @MainActor
    func testProjectAliasFollowsFullPath() {
        let store = WindowStore()
        let saved = store.projectAliases
        defer { store.projectAliases = saved }
        let home = NSHomeDirectory()
        store.projectAliases = [home + "/dev/alpha": "阿尔法"]
        func tab(_ appID: String, _ url: String) -> BrowserTab {
            BrowserTab(appID: appID, pid: 1, tabID: "t", browserWindowID: "1", windowNumber: 1,
                title: "t", url: url, active: false, windowFrame: .zero, parentWindowID: nil)
        }
        XCTAssertEqual(store.projectAlias(tab(TabBrowser.warp.rawValue, "~/dev/alpha · claude · ttys001")), "阿尔法", "~ 路径展开后匹配")
        XCTAssertEqual(store.projectAlias(tab(TabBrowser.kitty.rawValue, home + "/dev/alpha")), "阿尔法", "不同终端共用同一项目名")
        XCTAssertNil(store.projectAlias(tab(TabBrowser.kitty.rawValue, "~/dev/alpha/sub")), "子目录不继承")
        XCTAssertNil(store.projectAlias(tab(TabBrowser.chrome.rawValue, "https://example.com")), "网页标签没有项目名")
    }

    func testThirdPartyTerminalsCountAsTerminals() {
        for browser in [TabBrowser.ghostty, .wezterm, .kitty, .warp, .alacritty, .hyper, .tabby, .rio, .cmux] {
            XCTAssertTrue(browser.isTerminal, browser.rawValue)
            XCTAssertFalse(browser.isScriptableTerminal, browser.rawValue)
        }
        XCTAssertFalse(TabBrowser.safari.isTerminal)
        XCTAssertTrue(TabBrowser.iterm.isScriptableTerminal)
    }
}
