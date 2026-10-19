import AppKit
import XCTest
@testable import WindowAtlas

/// 用真实 WindowStore 验证置顶 / 移到末尾 / 多选的完整流程（不依赖界面与屏幕权限）。
@MainActor
final class WindowOrderingStoreTests: XCTestCase {
    private func makeStore(_ ids: [CGWindowID]) -> WindowStore {
        let store = WindowStore()
        store.windows = ids.map { WindowItem(id: $0, pid: 1, appID: "app.\($0)", appName: "App \($0)", title: "W\($0)",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), icon: nil) }
        store.selection = "all"
        store.folderPreferences["all"] = FolderPreferences(sort: .name)
        return store
    }

    override func tearDown() {
        // WindowStore 写入测试进程自己的偏好域，结束时清掉，避免影响下一次测试。
        UserDefaults.standard.removeObject(forKey: "folderPreferences")
        super.tearDown()
    }

    func testMoveSelectionToTopTakesEffectImmediatelyAndIsIdempotent() {
        let store = makeStore([1, 2, 3, 4, 5, 6])
        store.markedWindowIDs = [5, 3]
        store.moveWindowsToEdge(store.orderedSelection, top: true)
        XCTAssertEqual(store.filtered.map(\.id), [3, 5, 1, 2, 4, 6])
        XCTAssertEqual(store.sortMode, .manual)
        store.moveWindowsToEdge(store.orderedSelection, top: true)
        XCTAssertEqual(store.filtered.map(\.id), [3, 5, 1, 2, 4, 6], "重复置顶不应改变顺序")
        store.moveWindowsToEdge(store.actionTargets(for: 2), top: false)
        XCTAssertEqual(store.filtered.map(\.id), [3, 5, 1, 4, 6, 2])
        // 多选中右键另一个未选窗口移动：只移动它并以「刚移动」高亮，原多选保留，选中项不变（选中项变化会让看板滚动）。
        XCTAssertEqual(store.recentlyMovedWindowIDs, [2])
        XCTAssertEqual(store.markedWindowIDs, [3, 5])
        XCTAssertNil(store.selectedWindowID)
    }

    func testSingleMoveDoesNotStartMultiSelection() {
        // 置顶后再 ⌥ 点选时，不能把上次移动的窗口一起带进多选。
        let store = makeStore([1, 2, 3])
        store.moveWindowsToEdge([3], top: true)
        XCTAssertEqual(store.filtered.map(\.id), [3, 1, 2])
        XCTAssertTrue(store.markedWindowIDs.isEmpty)
        XCTAssertEqual(store.recentlyMovedWindowIDs, [3])
        store.clearWindowSelection()
        XCTAssertTrue(store.recentlyMovedWindowIDs.isEmpty)
    }

    func testMultiSelectionStaysSelectedAfterMove() {
        let store = makeStore([1, 2, 3, 4, 5])
        store.markedWindowIDs = [4, 5]
        store.moveWindowsToEdge(store.orderedSelection, top: true)
        XCTAssertEqual(store.markedWindowIDs, [4, 5])
        XCTAssertEqual(store.filtered.map(\.id), [4, 5, 1, 2, 3])
    }

    func testRightClickOnUnselectedWindowOnlyMovesThatWindow() {
        let store = makeStore([1, 2, 3, 4])
        store.markedWindowIDs = [3, 4]
        XCTAssertEqual(store.actionTargets(for: 1), [1])
        XCTAssertEqual(store.actionTargets(for: 4), [3, 4])
    }
}
