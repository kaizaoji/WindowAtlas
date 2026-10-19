import XCTest
@testable import WindowAtlas

final class WindowMatchingTests: XCTestCase {
    let frame = CGRect(x: 300, y: 100, width: 800, height: 600)

    func testDuplicateTerminalTitlesUseWindowGeometry() {
        let candidates = [
            WindowDescriptor(title: "Claude", frame: CGRect(x: 10, y: 100, width: 800, height: 600)),
            WindowDescriptor(title: "Claude", frame: frame)
        ]
        XCTAssertEqual(matchingWindowIndex(title: "Claude", appName: "iTerm2", frame: frame, candidates: candidates), 1)
    }

    func testWrongTitleCannotSelectNeighboringWindow() {
        XCTAssertNil(matchingWindowIndex(title: "Codex", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "Claude", frame: frame)]))
    }

    func testUntitledWindowMatchesApplicationFallback() {
        XCTAssertEqual(matchingWindowIndex(title: "Finder", appName: "Finder", frame: frame,
            candidates: [WindowDescriptor(title: "", frame: frame)]), 0)
    }

    func testEmptyTitleCannotMatchArbitraryTitle() {
        XCTAssertNil(matchingWindowIndex(title: "Project A", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "", frame: frame)]))
    }

    func testClosedWindowHasNoMatch() {
        XCTAssertNil(matchingWindowIndex(title: "Codex", appName: "Terminal", frame: frame, candidates: []))
    }

    func testAnimatedTitleCanUseLiveValidatedUniqueGeometry() {
        XCTAssertEqual(matchingWindowIndex(title: "⠴ Codex", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "⠼ Codex", frame: frame)], allowUniqueGeometry: true), 0)
    }

    func testGeometryFallbackCannotSelectNearbyDifferentWindow() {
        XCTAssertNil(matchingWindowIndex(title: "Codex", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "Other task", frame: frame.offsetBy(dx: 100, dy: 0))], allowUniqueGeometry: true))
    }

    func testIdenticalOverlappingWindowsAreNotGuessed() {
        XCTAssertNil(matchingWindowIndex(title: "Codex", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "Codex", frame: frame), WindowDescriptor(title: "Codex", frame: frame)], allowUniqueGeometry: true))
    }

    func testUntitledSheetCanBeLocatedByUniqueGeometry() {
        let parent = CGRect(x: 50, y: 50, width: 1300, height: 850)
        XCTAssertEqual(matchingWindowIndex(title: "Terminal", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "Claude task", frame: parent), WindowDescriptor(title: "", frame: frame)], allowUniqueGeometry: true), 1)
    }
    func testValidatedSheetAllowsSmallSystemBorderDifference() {
        let bordered = frame.insetBy(dx: -3, dy: -3)
        XCTAssertEqual(matchingWindowIndex(title: "Terminal", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "", frame: bordered)], allowUniqueGeometry: true, geometryTolerance: 24), 0)
        XCTAssertNil(matchingWindowIndex(title: "Terminal", appName: "Terminal", frame: frame,
            candidates: [WindowDescriptor(title: "", frame: bordered), WindowDescriptor(title: "", frame: frame)], allowUniqueGeometry: true, geometryTolerance: 24))
    }

    func testCancelNeverSelectsTerminateOrConfirmation() {
        XCTAssertTrue(isSafeCancelTitle("取消"))
        XCTAssertTrue(isSafeCancelTitle("Cancel"))
        for title in ["停止", "终止", "Terminate", "关闭", "确定", "不要取消"] { XCTAssertFalse(isSafeCancelTitle(title)) }
    }
}
