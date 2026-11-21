import XCTest
@testable import FlowCloneCore

final class RecorderOwnershipTests: XCTestCase {
    func testEndWhileEngineStartIsBlockedTearsDownTheStaleRoute() {
        var ownership = RecorderCaptureOwnership()
        let owner = ownership.begin()
        XCTAssertTrue(ownership.activate(owner))

        var startCount = 0
        var teardownCount = 0
        let accepted = Recorder.fencedEngineStart(
            isOwned: { ownership.ownsActiveCapture(owner) },
            start: {
                startCount += 1
                // Deterministically models release/cancel returning on the session queue
                // while AVAudioEngine.start is still blocked on the device queue.
                ownership.end()
                return true
            },
            tearDown: { teardownCount += 1 }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(teardownCount, 1,
                       "a route started for the released capture must be stopped")
        XCTAssertNil(ownership.activeOwner)
    }

    func testKnownStaleRecoveryNeverStartsAndCannotDisplaceNewCapture() {
        var ownership = RecorderCaptureOwnership()
        let staleOwner = ownership.begin()
        XCTAssertTrue(ownership.activate(staleOwner))
        ownership.end()
        let currentOwner = ownership.begin()
        XCTAssertTrue(ownership.activate(currentOwner))

        var startCount = 0
        var teardownCount = 0
        let accepted = Recorder.fencedEngineStart(
            isOwned: { ownership.ownsActiveCapture(staleOwner) },
            start: {
                startCount += 1
                return true
            },
            tearDown: { teardownCount += 1 }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(startCount, 0, "a stale recovery must not enter engine.start")
        XCTAssertEqual(teardownCount, 1, "its already-staged route must still be removed")
        XCTAssertEqual(ownership.activeOwner, currentOwner)
    }

    func testQueuedFailureCanClaimOnlyItsExactCaptureOwner() {
        var ownership = RecorderCaptureOwnership()
        let failedOwner = ownership.begin()
        XCTAssertTrue(ownership.activate(failedOwner))

        // The failure handoff is queued, then release and a new capture win the session
        // queue before it runs.
        ownership.end()
        let currentOwner = ownership.begin()
        XCTAssertTrue(ownership.activate(currentOwner))

        var drainCount = 0
        var callbackCount = 0
        if ownership.claimFailure(failedOwner) {
            drainCount += 1
            callbackCount += 1
        }

        XCTAssertEqual(drainCount, 0, "stale failure must not drain the new capture")
        XCTAssertEqual(callbackCount, 0, "stale failure must not notify for the new capture")
        XCTAssertEqual(ownership.activeOwner, currentOwner)

        if ownership.claimFailure(currentOwner) {
            drainCount += 1
            callbackCount += 1
        }
        XCTAssertEqual(drainCount, 1)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertNil(ownership.activeOwner)
    }
}
