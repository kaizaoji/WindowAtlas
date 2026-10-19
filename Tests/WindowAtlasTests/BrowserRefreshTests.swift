import XCTest
@testable import WindowAtlas

final class BrowserRefreshTests: XCTestCase {
    func testStoppingReadRejectsBothLateSuccessAndFailure() throws {
        var requests = BrowserRefreshRequest()
        let requestID = try XCTUnwrap(requests.begin())
        requests.invalidate()
        // 成功与失败路径使用相同校验，停用后不得再次写入标签或错误。
        XCTAssertFalse(requests.isCurrent(requestID))
        XCTAssertFalse(requests.finish(requestID))
        XCTAssertNil(requests.activeID)
    }

    func testRestartCanBeginBeforeOldRequestReturns() throws {
        var requests = BrowserRefreshRequest()
        let oldRequest = try XCTUnwrap(requests.begin())
        requests.invalidate()
        let newRequest = try XCTUnwrap(requests.begin())
        XCTAssertNotEqual(oldRequest, newRequest)
        XCTAssertFalse(requests.isCurrent(oldRequest))
        XCTAssertTrue(requests.isCurrent(newRequest))
        // 旧请求的 defer 不得把新请求的加载状态清掉。
        XCTAssertFalse(requests.finish(oldRequest))
        XCTAssertEqual(requests.activeID, newRequest)
        XCTAssertTrue(requests.finish(newRequest))
        XCTAssertNil(requests.activeID)
    }

    func testOverlappingRefreshIsSuppressedUntilCurrentRequestFinishes() throws {
        var requests = BrowserRefreshRequest()
        let requestID = try XCTUnwrap(requests.begin())
        XCTAssertNil(requests.begin())
        XCTAssertTrue(requests.finish(requestID))
        XCTAssertNotNil(requests.begin())
    }
}
