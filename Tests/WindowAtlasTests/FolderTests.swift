import XCTest
import AppKit
@testable import WindowAtlas

final class FolderTests: XCTestCase {
    func testFolderSettingsRoundTripWithoutMixingApps() throws {
        let folders = [
            "com.google.Chrome": FolderPreferences(mode: .list, cardWidth: 220, sort: .newest, showTabs: true),
            "com.apple.Terminal": FolderPreferences(mode: .split, cardWidth: 480, sort: .oldest, showTabs: false)
        ]
        let saved = try JSONEncoder().encode(folders)
        XCTAssertEqual(try JSONDecoder().decode([String: FolderPreferences].self, from: saved), folders)
    }

    func testLegacyFolderSettingsWithoutManualOrderStillDecode() throws {
        // 0.9.2（22）及更早版本保存的设置没有 manualOrder，不能因此丢失整份栏目设置。
        let legacy = #"{"all":{"mode":"list","cardWidth":260,"sort":"newest","showTabs":false}}"#
        let decoded = try JSONDecoder().decode([String: FolderPreferences].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded["all"], FolderPreferences(mode: .list, cardWidth: 260, sort: .newest, showTabs: false, manualOrder: []))
        let manual = FolderPreferences(sort: .manual, manualOrder: [3, 1, 2])
        XCTAssertEqual(try JSONDecoder().decode(FolderPreferences.self, from: JSONEncoder().encode(manual)), manual)
    }

    func testManualOrderPutsUnorderedWindowsLastInOriginalOrder() {
        let ids: [CGWindowID] = [10, 20, 30, 40, 50]
        XCTAssertEqual(applyManualOrder(ids, order: [40, 99, 10], id: { $0 }), [40, 10, 20, 30, 50])
        XCTAssertEqual(applyManualOrder(ids, order: [], id: { $0 }), ids)
    }

    func testMovingWindowKeepsHiddenWindowsAndDropsClosedOnes() {
        // 30 因筛选隐藏但仍存在，99 已关闭。
        let next = movedWindowOrder(displayed: [10, 20, 40], stored: [30, 99], existing: [10, 20, 30, 40],
            moving: [40], to: 10)
        XCTAssertEqual(next, [40, 10, 20, 30])
        XCTAssertEqual(movedWindowOrder(displayed: [10, 20], stored: [20, 10], existing: [10, 20], moving: [10], to: 20), [20, 10])
        XCTAssertEqual(movedWindowOrder(displayed: [10, 20], stored: [7], existing: [10, 20], moving: [10], to: 10), [7])
    }

    func testMovingSelectedGroupKeepsItsInternalOrder() {
        let shown: [CGWindowID] = [1, 2, 3, 4, 5, 6]
        let all = Set(shown)
        // 向后拖：组放在目标之后；选中顺序与传入顺序无关，以显示顺序为准。
        XCTAssertEqual(movedWindowOrder(displayed: shown, stored: [], existing: all, moving: [4, 1], to: 5), [2, 3, 5, 1, 4, 6])
        // 向前拖：组放在目标之前。
        XCTAssertEqual(movedWindowOrder(displayed: shown, stored: [], existing: all, moving: [6, 3], to: 2), [1, 3, 6, 2, 4, 5])
        // 拖到组内成员上不改变顺序。
        XCTAssertEqual(movedWindowOrder(displayed: shown, stored: [9], existing: all, moving: [2, 3], to: 3), [9])
    }

    func testMoveToTopAndBottomKeepGroupOrderAndHiddenWindows() {
        let shown: [CGWindowID] = [1, 2, 3, 4]
        XCTAssertEqual(edgeWindowOrder(displayed: shown, stored: [8], existing: [1, 2, 3, 4, 8], moving: [4, 2], toTop: true), [2, 4, 1, 3, 8])
        XCTAssertEqual(edgeWindowOrder(displayed: shown, stored: [], existing: [1, 2, 3, 4], moving: [1, 3], toTop: false), [2, 4, 1, 3])
    }

    func testShiftRangeSelectionWorksInBothDirections() {
        let ids: [CGWindowID] = [10, 20, 30, 40]
        XCTAssertEqual(rangeSelection(ids, anchor: 20, target: 40), [20, 30, 40])
        XCTAssertEqual(rangeSelection(ids, anchor: 40, target: 10), [10, 20, 30, 40])
        XCTAssertEqual(rangeSelection(ids, anchor: nil, target: 30), [30])
        XCTAssertEqual(rangeSelection(ids, anchor: 99, target: 30), [30])
    }

    func testPlacementOnMonitorAbovePrimaryUsesNegativeCoordinates() {
        let usable = CGRect(x: -1400, y: -900, width: 1400, height: 850)
        let current = CGRect(x: 50, y: 50, width: 800, height: 600)
        XCTAssertEqual(placedFrame(.right, current: current, usable: usable), CGRect(x: -700, y: -900, width: 700, height: 850))
        XCTAssertEqual(placedFrame(.bottom, current: current, usable: usable), CGRect(x: -1400, y: -475, width: 1400, height: 425))
    }

    func testCenterClampsOversizedWindowToUsableScreen() {
        let usable = CGRect(x: 100, y: 50, width: 1000, height: 700)
        XCTAssertEqual(placedFrame(.center, current: CGRect(x: 0, y: 0, width: 2000, height: 900), usable: usable), usable)
    }

    func testEveryGridCellTilesMonitorWithNegativeOrigin() {
        let usable = CGRect(x: -900, y: -600, width: 900, height: 600)
        let frames = WindowPlacement.grid.map { placedFrame($0, current: .zero, usable: usable) }
        XCTAssertEqual(frames.count, 9)
        XCTAssertEqual(Set(frames.map { "\($0.minX),\($0.minY)" }).count, 9)
        XCTAssertTrue(frames.allSatisfy { usable.contains($0) && $0.width == 300 && $0.height == 200 })
        XCTAssertEqual(frames.last, CGRect(x: -300, y: -200, width: 300, height: 200))
    }

    func testAppReorderingBothDirectionsAndUnknownTarget() {
        XCTAssertEqual(reorderedAppIDs(["a", "b", "c"], moving: "a", to: "c"), ["b", "c", "a"])
        XCTAssertEqual(reorderedAppIDs(["a", "b", "c"], moving: "c", to: "a"), ["c", "a", "b"])
        XCTAssertEqual(reorderedAppIDs(["a", "b"], moving: "c", to: "a"), ["a", "b"])
    }

    func testKeyboardNavigationHandlesBoundariesAndRemovedSelection() {
        XCTAssertNil(adjacentListSelection([Int](), current: nil, forward: true))
        XCTAssertEqual(adjacentListSelection([10, 20, 30], current: nil, forward: true), 10)
        XCTAssertEqual(adjacentListSelection([10, 20, 30], current: nil, forward: false), 30)
        XCTAssertEqual(adjacentListSelection([10, 20, 30], current: 20, forward: true), 30)
        XCTAssertEqual(adjacentListSelection([10, 20, 30], current: 20, forward: false), 10)
        XCTAssertEqual(adjacentListSelection([10, 20, 30], current: 30, forward: true), 30)
        XCTAssertEqual(adjacentListSelection([10, 20, 30], current: 10, forward: false), 10)
        XCTAssertEqual(adjacentListSelection([10, 30], current: 20, forward: true), 10)
    }

    func testMultipleDisplayCoordinateConversionAndPlacement() {
        // 主屏、左屏、上屏和右下屏采用不同尺寸及负坐标。
        let frames = [CGRect(x: 0, y: 0, width: 1728, height: 1117),
                      CGRect(x: -2560, y: -120, width: 2560, height: 1440),
                      CGRect(x: 100, y: 1117, width: 1920, height: 1080),
                      CGRect(x: 1728, y: -900, width: 1600, height: 900)]
        let converted = frames.map { quartzScreenFrame($0, primaryTop: 1117) }
        XCTAssertEqual(converted[0].origin, .zero)
        XCTAssertEqual(converted[1].origin, CGPoint(x: -2560, y: -203))
        XCTAssertEqual(converted[2].origin, CGPoint(x: 100, y: -1080))
        XCTAssertEqual(converted[3].origin, CGPoint(x: 1728, y: 1117))
        for usable in converted {
            for placement in WindowPlacement.grid + [.left, .right, .top, .bottom, .center, .maximize] {
                let result = placedFrame(placement, current: CGRect(x: 20, y: 20, width: 600, height: 400), usable: usable)
                XCTAssertTrue(usable.insetBy(dx: -0.001, dy: -0.001).contains(result))
            }
        }
    }

    func testGridNavigationUsesColumnsAndIncompleteLastRow() {
        let ids = Array(0..<10)
        XCTAssertEqual(adjacentListSelection(ids, current: 2, forward: true, stride: 4), 6)
        XCTAssertEqual(adjacentListSelection(ids, current: 6, forward: true, stride: 4), 9)
        XCTAssertEqual(adjacentListSelection(ids, current: 9, forward: false, stride: 4), 5)
        XCTAssertEqual(adjacentListSelection(ids, current: 1, forward: false, stride: 4), 0)
        XCTAssertEqual(adjacentListSelection(ids, current: 3, forward: true), 4)
        XCTAssertEqual(windowGridColumns(width: 1364, cardWidth: 320), 4)
        XCTAssertEqual(windowGridColumns(width: 1032, cardWidth: 320), 3)
        XCTAssertEqual(windowGridColumns(width: 700, cardWidth: 320), 2)
        XCTAssertEqual(windowGridColumns(width: 200, cardWidth: 320), 1)
        XCTAssertEqual(windowGridColumns(width: 0, cardWidth: 320), 1)
        XCTAssertEqual(windowGridColumns(width: 1364, cardWidth: 560), 2)
    }


    func testAutoGridSizes() {
        XCTAssertEqual([1, 2, 3, 4, 5, 6, 7, 9].map { autoGrid($0).columns * 10 + autoGrid($0).rows }, [11, 21, 31, 22, 32, 32, 33, 33])
    }

    func testTileFramesStayInsideScreenWithoutOverlap() {
        let usable = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        for layout in TileLayout.allCases {
            for count in 1...9 {
                let frames = tileFrames(count: count, layout: layout, usable: usable)
                XCTAssertEqual(frames.count, count, "\(layout) \(count)")
                for (i, a) in frames.enumerated() {
                    XCTAssertTrue(usable.insetBy(dx: -1, dy: -1).contains(a), "\(layout) \(count) 超出屏幕")
                    for b in frames[(i + 1)...] { XCTAssertFalse(a.insetBy(dx: 1, dy: 1).intersects(b), "\(layout) \(count) 重叠") }
                }
            }
        }
        XCTAssertEqual(tileFrames(count: 12, layout: .auto, usable: usable).count, 9, "最多 9 个")
        let focus = tileFrames(count: 3, layout: .focusLeft, usable: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 0)
        XCTAssertEqual(focus, [CGRect(x: 0, y: 0, width: 500, height: 600), CGRect(x: 500, y: 0, width: 500, height: 300), CGRect(x: 500, y: 300, width: 500, height: 300)])
    }
}

