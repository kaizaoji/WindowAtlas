import AppKit
import XCTest
@testable import WindowAtlas

/// 多浏览器标签页：各栏目只显示自己的标签、侧栏数字、旧 Chrome 开关迁移。
@MainActor
final class BrowserTabsStoreTests: XCTestCase {
    override func tearDown() {
        // WindowStore 写入测试进程自己的偏好域，结束时清掉，避免影响其他测试。
        for key in ["browserTabApps", "chromeTabsEnabled", "folderPreferences"] { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    private func tab(_ appID: String, _ id: String, window: Int = 1, order: Int = 0) -> BrowserTab {
        var value = BrowserTab(appID: appID, pid: 1, tabID: id, browserWindowID: "w\(window)", windowNumber: window,
            title: "T\(id)", url: "https://example.com/\(id)", active: false, windowFrame: .zero, parentWindowID: nil)
        value.order = order
        return value
    }

    func testEachBrowserFolderShowsOnlyItsOwnTabsInBrowserOrder() {
        let store = WindowStore()
        store.browserTabs = [tab(TabBrowser.chrome.rawValue, "c2", order: 1), tab(TabBrowser.edge.rawValue, "e1"),
                             tab(TabBrowser.chrome.rawValue, "c1", order: 0), tab(TabBrowser.safari.rawValue, "s1")]
        store.selection = TabBrowser.chrome.rawValue
        store.sortMode = .manual
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["c1", "c2"])
        store.selection = TabBrowser.safari.rawValue
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["s1"])
        store.selection = "com.apple.finder"
        XCTAssertNil(store.currentTabBrowser)
        XCTAssertFalse(store.showingTabs)
    }

    func testSidebarCountShowsTabsOnlyWhenReadingIsOn() {
        let store = WindowStore()
        store.browserTabApps = [TabBrowser.chrome.rawValue]
        store.browserTabs = [tab(TabBrowser.chrome.rawValue, "c1"), tab(TabBrowser.chrome.rawValue, "c2"), tab(TabBrowser.edge.rawValue, "e1")]
        XCTAssertEqual(store.tabCountLabel(TabBrowser.chrome.rawValue, windowCount: 3), "2")
        XCTAssertTrue(store.showsTabCount(TabBrowser.chrome.rawValue))
        XCTAssertFalse(store.showsTabCount(TabBrowser.edge.rawValue))
        XCTAssertEqual(store.tabCountLabel(TabBrowser.edge.rawValue, windowCount: 4), "4")
        store.browserErrors[TabBrowser.chrome.rawValue] = "denied"
        XCTAssertEqual(store.tabCountLabel(TabBrowser.chrome.rawValue, windowCount: 3), "需重试")
    }

    func testAggregateTabsViewPicksUpTerminalsOpenedLater() {
        let store = WindowStore()
        func window(_ id: CGWindowID, _ appID: String) -> WindowItem {
            WindowItem(id: id, pid: pid_t(id), appID: appID, appName: appID, title: "w", frame: .zero, icon: nil)
        }
        store.windows = [window(1, TabBrowser.terminal.rawValue)]
        store.selection = "terminals"
        store.enableBrowserTabs()
        XCTAssertEqual(store.browserTabApps, [TabBrowser.terminal.rawValue])
        // 之后才打开的终端：看着汇总标签页时自动加入
        store.windows += [window(2, TabBrowser.wezterm.rawValue), window(3, TabBrowser.ghostty.rawValue), window(4, TabBrowser.kitty.rawValue)]
        store.browserErrors[TabBrowser.ghostty.rawValue] = "denied"
        store.tabReadingStopped.insert(TabBrowser.kitty.rawValue)
        store.includeNewTabApps()
        XCTAssertEqual(store.browserTabApps, [TabBrowser.terminal.rawValue, TabBrowser.wezterm.rawValue], "出错或手动停止的不自动加入")
        // 用户主动「重新读取」时一并重试
        store.rereadBrowserTabs()
        XCTAssertTrue(store.browserTabApps.isSuperset(of: [TabBrowser.ghostty.rawValue, TabBrowser.kitty.rawValue]))
        // 只看窗口时不自动加入
        store.browserTabApps = [TabBrowser.terminal.rawValue]
        store.setShowTabs(false)
        store.includeNewTabApps()
        XCTAssertEqual(store.browserTabApps, [TabBrowser.terminal.rawValue])
    }

    func testLegacyChromeSwitchMigratesToBrowserList() {
        UserDefaults.standard.removeObject(forKey: "browserTabApps")
        UserDefaults.standard.set(true, forKey: "chromeTabsEnabled")
        XCTAssertEqual(WindowStore().browserTabApps, [TabBrowser.chrome.rawValue])
        UserDefaults.standard.set([TabBrowser.safari.rawValue], forKey: "browserTabApps")
        XCTAssertEqual(WindowStore().browserTabApps, [TabBrowser.safari.rawValue], "已保存的新设置优先")
    }

    func testTabSnapshotCacheDownscalesAndKeepsAtMostLimit() {
        let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let cache = TabSnapshotCache()
        for index in 0..<(TabSnapshotCache.limit + 5) { cache.store(image, for: "k\(index)") }
        XCTAssertEqual(cache.images.count, TabSnapshotCache.limit)
        XCTAssertNil(cache.images["k0"], "超出上限时先丢弃最早存入的画面")
        XCTAssertNotNil(cache.images["k\(TabSnapshotCache.limit + 4)"])
        XCTAssertEqual(Int(cache.images["k10"]!.size.width), TabSnapshotCache.maxWidth)
        cache.retain(["k10"])
        XCTAssertEqual(Array(cache.images.keys), ["k10"])
    }

    func testAllWindowsFolderCanShowTabsFromEveryRunningBrowser() {
        let store = WindowStore()
        func window(_ id: CGWindowID, _ appID: String) -> WindowItem {
            WindowItem(id: id, pid: 1, appID: appID, appName: appID, title: "W", frame: .zero, icon: nil)
        }
        store.windows = [window(1, TabBrowser.safari.rawValue), window(2, TabBrowser.chrome.rawValue), window(3, "com.apple.Terminal")]
        store.browserTabs = [tab(TabBrowser.safari.rawValue, "s1"), tab(TabBrowser.chrome.rawValue, "c1"), tab(TabBrowser.edge.rawValue, "e1")]
        store.selection = "all"
        XCTAssertTrue(store.isTabFolder)
        XCTAssertFalse(store.showingTabs, "全部窗口默认显示窗口")
        store.setShowTabs(true)
        XCTAssertTrue(store.showingTabs)
        store.sortMode = .manual
        // Edge 没有窗口不计入；按 Chrome、Safari 顺序分组。
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["c1", "s1"])
        XCTAssertEqual(store.filteredTabs.first?.location, "Chrome · 窗口 1")
        store.selection = TabBrowser.chrome.rawValue
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["c1"])
    }

    func testTerminalFoldersListTabsButDefaultToWindows() {
        let store = WindowStore()
        func window(_ id: CGWindowID, _ appID: String) -> WindowItem {
            WindowItem(id: id, pid: 1, appID: appID, appName: appID, title: "W", frame: .zero, icon: nil)
        }
        store.windows = [window(1, TabBrowser.terminal.rawValue), window(2, TabBrowser.iterm.rawValue), window(3, TabBrowser.chrome.rawValue)]
        store.browserTabs = [tab(TabBrowser.terminal.rawValue, "t1"), tab(TabBrowser.iterm.rawValue, "i1"), tab(TabBrowser.chrome.rawValue, "c1")]
        store.selection = TabBrowser.iterm.rawValue
        XCTAssertTrue(store.isTabFolder)
        XCTAssertFalse(store.showingTabs, "终端栏目默认仍显示窗口")
        store.setShowTabs(true)
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["i1"])
        store.selection = "terminals"
        store.setShowTabs(true)
        store.sortMode = .manual
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["t1", "i1"], "终端汇总栏目只含终端与 iTerm2")
        store.selection = "browsers"
        store.setShowTabs(true)
        XCTAssertEqual(store.filteredTabs.map(\.tabID), ["c1"])
        XCTAssertTrue(store.browserTabs[0].isTerminalTab)
    }

    func testTerminalTabTitleShowsFullPathOnlyForTruncatedPathTitles() {
        let path = "~/Desktop/DeskTop/Ai/codex/26codex"
        XCTAssertEqual(TerminalDirectories.title("..codex/26codex (-zsh)", path: path), path + " (-zsh)")
        XCTAssertEqual(TerminalDirectories.title("~ (-zsh)", path: "~"), "~ (-zsh)")
        XCTAssertEqual(TerminalDirectories.title("✳ 项目记忆文件与上下文 (claude)", path: path), "✳ 项目记忆文件与上下文 (claude)", "AI 会话的自定义标题保持不变")
        XCTAssertEqual(TerminalDirectories.title("..codex/26codex (-zsh)", path: nil), "..codex/26codex (-zsh)")
        XCTAssertEqual(TerminalDirectories.abbreviate(NSHomeDirectory() + "/dev/app"), "~/dev/app")
        func tab(_ url: String) -> BrowserTab {
            BrowserTab(appID: TabBrowser.iterm.rawValue, pid: 1, tabID: "u", browserWindowID: "1", windowNumber: 1,
                title: "t", url: url, active: false, windowFrame: .zero, parentWindowID: nil)
        }
        XCTAssertEqual(tab(path + " · claude · ttys023").host, "26codex", "占位显示项目文件夹名")
        XCTAssertEqual(tab(path + " · claude · ttys023").terminalPath, path)
        XCTAssertEqual(tab(path + " · claude · ttys023").terminalPrograms, "claude")
        XCTAssertNil(tab("codex · ttys010").terminalPath, "读不到目录时不当作路径")
        XCTAssertEqual(tab("codex · ttys010").terminalPrograms, "codex")
        XCTAssertEqual(tab("ttys023").host, "ttys023")
    }

    func testPSLineParsingToleratesColumnPadding() {
        // ps 右对齐编号、按列宽补空格；曾因程序名带前导空格而认不出 shell，导致终端标签路径全部丢失
        let shell = TerminalDirectories.parsePSLine(" 94417 94416 ttys002  -zsh")
        XCTAssertEqual(shell?.pid, 94417)
        XCTAssertEqual(shell?.ppid, 94416)
        XCTAssertEqual(shell?.tty, "ttys002")
        XCTAssertEqual(shell?.name, "-zsh")
        XCTAssertEqual(TerminalDirectories.parsePSLine("23507 23490 ttys000  /Users/x/.cache/gitstatus/gitstatusd-darwin-arm64")?.name, "gitstatusd-darwin-arm64")
        XCTAssertEqual(TerminalDirectories.parsePSLine("  501     1 ttys003  /Applications/Visual Studio Code.app/Contents/MacOS/Electron")?.name, "Electron", "程序路径含空格")
        XCTAssertNil(TerminalDirectories.parsePSLine("  123     1 ??       /usr/sbin/cfprefsd"), "无终端的进程跳过")
    }

    func testSnapshotGoesToTabShownAtCaptureTime() {
        func t(_ id: String, _ raw: String, active: Bool = false) -> BrowserTab {
            var value = BrowserTab(appID: TabBrowser.iterm.rawValue, pid: 1, tabID: id, browserWindowID: "1", windowNumber: 1,
                title: "~/full/" + raw, url: "", active: active, windowFrame: .zero, parentWindowID: 9)
            value.rawTitle = raw
            return value
        }
        let tabs = [t("a", "..codex/26codex (-zsh)", active: true), t("b", "✳ 项目记忆 (claude)"), t("c", "~ (-zsh)"), t("d", "~ (-zsh)")]
        // 列表仍记着 a 为当前标签，但窗口此刻显示的是 b：画面应记给 b。
        XCTAssertEqual(tabShownInWindow(liveTitle: "✳ 项目记忆 (claude)", tabs: tabs)?.tabID, "b")
        // 两个标题相同且都不是记录中的当前标签：无法确定，不保存。
        XCTAssertNil(tabShownInWindow(liveTitle: "~ (-zsh)", tabs: tabs))
        XCTAssertNil(tabShownInWindow(liveTitle: "", tabs: tabs))
        var web = t("w", "GitHub - kaizaoji/WindowAtlas · GitHub"); web.rawTitle = ""
        XCTAssertEqual(tabShownInWindow(liveTitle: "GitHub - kaizaoji/WindowAtlas", tabs: [web, t("x", "Docs")])?.tabID, "w")
    }

    func testWindowsAndTabsShareSearchRules() {
        XCTAssertTrue(searchMatches("", "anything"))
        XCTAssertTrue(searchMatches("26codex claude", "~/dev/26codex", "claude · ttys023"))
        XCTAssertFalse(searchMatches("26codex codex-only", "~/dev/26codex", "claude"))
        XCTAssertTrue(searchMatches("ITERM", "iTerm2"))
    }

    func testTabSelectionAndParentWindowsAreDeduplicatedInOrder() {
        let store = WindowStore()
        func make(_ id: String, parent: CGWindowID, order: Int) -> BrowserTab {
            var value = BrowserTab(appID: TabBrowser.chrome.rawValue, pid: 1, tabID: id, browserWindowID: "w\(parent)", windowNumber: Int(parent),
                title: id, url: "https://e.com/\(id)", active: false, windowFrame: .zero, parentWindowID: parent)
            value.order = order
            return value
        }
        store.browserTabs = [make("a", parent: 7, order: 0), make("b", parent: 7, order: 1), make("c", parent: 9, order: 0)]
        store.selection = TabBrowser.chrome.rawValue
        store.sortMode = .manual
        store.markedTabIDs = Set(store.browserTabs.map(\.id))
        XCTAssertEqual(store.orderedTabSelection.map(\.tabID), ["a", "b", "c"])
        XCTAssertEqual(store.parentWindows(of: store.orderedTabSelection), [7, 9], "同一窗口只排一次")
        store.clearTabSelection()
        XCTAssertTrue(store.orderedTabSelection.isEmpty)
    }
}

