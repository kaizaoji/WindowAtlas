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
        store.selection = "com.apple.Terminal"
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
}

