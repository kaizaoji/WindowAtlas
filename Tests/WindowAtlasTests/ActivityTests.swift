import AppKit
import XCTest
@testable import WindowAtlas

final class ActivityTests: XCTestCase {
    func testFirstSampleDoesNotClaimRunning() {
        var sample = ActivityObservation()
        let now = Date()
        sample.observe([UInt8](repeating: 0, count: 1000), at: now)
        XCTAssertEqual(sample.label(at: now), "观察中 · 暂无变化")
        XCTAssertNil(sample.lastChange)
    }
    func testContinuousFiveMinuteObservationAndExpiredSample() {
        var sample = ActivityObservation()
        let now = Date()
        for seconds in stride(from: 0, through: 300, by: 6) {
            sample.observe([0, 0], at: now.addingTimeInterval(Double(seconds)))
        }
        XCTAssertEqual(sample.label(at: now.addingTimeInterval(300)), "长时无变化")
        XCTAssertEqual(sample.label(at: now.addingTimeInterval(340)), "未在观察")
        sample.observe([0, 0], at: now.addingTimeInterval(350))
        XCTAssertEqual(sample.label(at: now.addingTimeInterval(350)), "观察中 · 暂无变化")
    }
    func testChangesAndSmallCursorNoise() {
        var sample = ActivityObservation()
        let now = Date()
        let blank = [UInt8](repeating: 0, count: 1000)
        sample.observe(blank, at: now)
        var cursor = blank; cursor[0] = 255
        sample.observe(cursor, at: now.addingTimeInterval(6))
        XCTAssertNil(sample.lastChange)
        sample.observe([UInt8](repeating: 100, count: 1000), at: now.addingTimeInterval(12))
        XCTAssertEqual(sample.label(at: now.addingTimeInterval(12)), "近期变化")
    }

    func testBlankCaptureDetection() {
        func image(alpha: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            return context.makeImage()!
        }
        XCTAssertTrue(isBlankCapture(image(alpha: 0)))
        // 纯黑但不透明的终端窗口是真实内容，不能当成空白丢弃。
        XCTAssertFalse(isBlankCapture(image(alpha: 1)))
    }

    func testSameWindowListIgnoresIconButDetectsChanges() {
        let base = WindowItem(id: 1, pid: 10, appID: "com.apple.Terminal", appName: "终端", title: "a",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), icon: nil)
        let renamed = WindowItem(id: 1, pid: 10, appID: "com.apple.Terminal", appName: "终端", title: "b",
            frame: base.frame, icon: NSImage())
        var withIcon = WindowItem(id: 1, pid: 10, appID: "com.apple.Terminal", appName: "终端", title: "a",
            frame: base.frame, icon: NSImage())
        withIcon.firstSeen = base.firstSeen
        XCTAssertTrue(sameWindowList([base], [withIcon]))
        XCTAssertFalse(sameWindowList([base], [renamed]))
        var moved = withIcon
        moved.isOnScreen = true
        XCTAssertFalse(sameWindowList([base], [moved]))
        XCTAssertFalse(sameWindowList([base], []))
    }
}
