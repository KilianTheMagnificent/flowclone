import Dispatch
import XCTest
@testable import FlowCloneCore

final class FailedCaptureStoreTests: XCTestCase {
    private let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)

    func testRetainReplacesPreviousCapture() {
        var store = FailedCaptureStore(lifetime: 5)
        let first = store.retain([0.1, 0.2], now: start)
        let second = store.retain([0.3], now: start + 1)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.current, second)
        XCTAssertEqual(store.current?.samples, [0.3])
    }

    func testStaleExpiryCannotClearReplacement() {
        var store = FailedCaptureStore(lifetime: 5)
        let stale = store.retain([0.1], now: start)
        let replacement = store.retain([0.2], now: start + 1)

        XCTAssertFalse(store.expire(
            id: stale.id,
            deadline: stale.deadline,
            now: replacement.deadline
        ))
        XCTAssertEqual(store.current, replacement)
    }

    func testCaptureIsRetainedBeforeDeadline() {
        var store = FailedCaptureStore(lifetime: 5)
        let capture = store.retain([0.1], now: start)
        let beforeDeadline = start + 4

        XCTAssertFalse(store.expire(
            id: capture.id,
            deadline: capture.deadline,
            now: beforeDeadline
        ))
        XCTAssertEqual(store.current, capture)
    }

    func testCaptureClearsAtDeadline() {
        var store = FailedCaptureStore(lifetime: 5)
        let capture = store.retain([0.1], now: start)

        XCTAssertTrue(store.expire(
            id: capture.id,
            deadline: capture.deadline,
            now: capture.deadline
        ))
        XCTAssertNil(store.current)
        XCTAssertFalse(store.clear(), "clearing an empty store is a no-op")
    }
}
