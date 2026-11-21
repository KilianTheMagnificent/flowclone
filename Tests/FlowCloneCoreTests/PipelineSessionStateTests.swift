import XCTest
@testable import FlowCloneCore

final class PipelineSessionStateTests: XCTestCase {
    func testUpdateReservationRequiresIdleAndBlocksNewWorkUntilReleased() {
        var state = PipelineSessionState()
        XCTAssertTrue(state.reserveForUpdate())
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.reserveForUpdate())
        state.releaseUpdateReservation()
        let generation = state.beginCapture()
        XCTAssertFalse(state.reserveForUpdate(), "warming owns the pipeline")
        XCTAssertTrue(state.markRecorderReady(for: generation))
        XCTAssertFalse(state.reserveForUpdate(), "recording owns the pipeline")
        state.finishCapture()
        state.beginCurrentDelivery()
        XCTAssertFalse(state.reserveForUpdate(), "delivery owns the pipeline")
        state.endDelivery(owner: generation)
        XCTAssertTrue(state.reserveForUpdate())
        state.releaseUpdateReservation()
        XCTAssertFalse(state.isBusy)
    }

    func testCaptureMovesFromWarmToRecordToDelivery() {
        var state = PipelineSessionState()
        XCTAssertFalse(state.isBusy)

        let owner = state.beginCapture()
        XCTAssertTrue(state.owns(owner))
        XCTAssertTrue(state.isWarming)
        XCTAssertTrue(state.setHandsFree(true))
        XCTAssertTrue(state.markRecorderReady(for: owner))
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.handsFree)

        XCTAssertTrue(state.finishCapture())
        XCTAssertFalse(state.captureActive)
        state.beginCurrentDelivery()
        XCTAssertTrue(state.isDelivering)
        XCTAssertTrue(state.transcribing)
        state.endDelivery(owner: owner + 1)
        XCTAssertTrue(state.isDelivering, "a stale completion must not clear the owner")
        state.endDelivery(owner: owner)
        XCTAssertFalse(state.isBusy)
    }

    func testCancelInvalidatesWarmOwner() {
        var state = PipelineSessionState()
        let owner = state.beginCapture()
        state.beginCurrentDelivery()

        state.cancelCapture()

        XCTAssertFalse(state.owns(owner))
        XCTAssertFalse(state.captureActive)
        XCTAssertFalse(state.isDelivering)
        XCTAssertFalse(state.markRecorderReady(for: owner))
    }

    func testCancelOnlyEndsARecorderRouteAfterOpenWasRequested() {
        var coldPrime = PipelineSessionState()
        _ = coldPrime.beginCapture()
        XCTAssertFalse(coldPrime.cancelCapture(),
                       "a cold-prime wait has not handed ownership to Recorder")

        var opening = PipelineSessionState()
        let openingOwner = opening.beginCapture()
        XCTAssertTrue(opening.markOpenInFlight(for: openingOwner))
        XCTAssertTrue(opening.cancelCapture(),
                      "an in-flight Recorder.begin must be fenced by Recorder.end")

        var recording = PipelineSessionState()
        let recordingOwner = recording.beginCapture()
        XCTAssertTrue(recording.markRecorderReady(for: recordingOwner))
        XCTAssertTrue(recording.cancelCapture(),
                      "an active recording also owns a Recorder route")
    }

    func testReleaseWhileWarmingSupportsPendingFinishAndColdDoubleTapLatch() {
        var state = PipelineSessionState()
        let owner = state.beginCapture()
        XCTAssertTrue(state.ownsCapture(owner))

        // A quick tap releasing during fast route prime or cold AudioDeviceStart parks
        // `pendingRelease` while warming so Tap 2 can latch hands-free or open completion can finish.
        XCTAssertTrue(state.markPendingRelease())
        XCTAssertTrue(state.pendingRelease)
        XCTAssertTrue(state.resumeWarmingCapture())
        XCTAssertFalse(state.pendingRelease)
        XCTAssertTrue(state.setHandsFree(true))
        XCTAssertTrue(state.handsFree)

        // Single-tap release mid-open stays parked until `markRecorderReady` honors it.
        var singleTap = PipelineSessionState()
        let singleOwner = singleTap.beginCapture()
        XCTAssertTrue(singleTap.markOpenInFlight(for: singleOwner))
        XCTAssertTrue(singleTap.markPendingRelease())
        XCTAssertTrue(singleTap.markRecorderReady(for: singleOwner))
        XCTAssertTrue(singleTap.pendingRelease, "the open's completion is what honors it")
        XCTAssertFalse(singleTap.openInFlight)
        XCTAssertFalse(singleTap.markPendingRelease(),
                       "a release after the open landed takes the ordinary finish path")

        singleTap.cancelCapture()
        XCTAssertFalse(singleTap.pendingRelease)
        XCTAssertFalse(singleTap.markOpenInFlight(for: singleOwner))
    }

    func testUtteranceOverlapKeepsInFlightDeliveryAliveWhileNextCaptureRecordsAndCancels() {
        var state = PipelineSessionState()
        let u1 = state.beginCapture()
        XCTAssertTrue(state.markRecorderReady(for: u1))
        _ = state.finishCapture()
        state.beginDelivery(owner: u1)
        XCTAssertTrue(state.transcribing)
        XCTAssertTrue(state.isActiveDeliveryHead(u1))

        // Utterance N+1 starts recording while Utterance N is still transcribing/pasting.
        let u2 = state.beginCapture()
        XCTAssertTrue(state.owns(u1), "Utterance N delivery must remain owned while N+1 records")
        XCTAssertTrue(state.ownsCapture(u2))
        XCTAssertTrue(state.markRecorderReady(for: u2))
        _ = state.finishCapture()
        state.beginDelivery(owner: u2)
        XCTAssertEqual(state.deliveringGenerations, [u1, u2])
        XCTAssertTrue(state.isActiveDeliveryHead(u1))
        XCTAssertFalse(state.isActiveDeliveryHead(u2))

        // Cancelling a third capture must NOT cancel u1 or u2 in the FIFO delivery queue.
        let u3 = state.beginCapture()
        XCTAssertTrue(state.ownsCapture(u3))
        _ = state.cancelCapture()
        XCTAssertFalse(state.owns(u3))
        XCTAssertEqual(state.deliveringGenerations, [u1, u2])

        state.endDelivery(owner: u1)
        XCTAssertTrue(state.isActiveDeliveryHead(u2))
        state.endDelivery(owner: u2)
        XCTAssertFalse(state.transcribing)
        XCTAssertFalse(state.isBusy)
    }

    func testPressTimeTellsALostHoldFromAnArmingTap() {
        var state = PipelineSessionState()
        let pressed = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        state.beginCapture(at: pressed)

        XCTAssertEqual(state.heldSeconds(now: pressed + .milliseconds(250)) ?? -1,
                       0.25, accuracy: 0.001)
        XCTAssertEqual(state.heldSeconds(now: pressed + .milliseconds(2_400)) ?? -1,
                       2.4, accuracy: 0.001)
        _ = state.finishCapture(at: pressed + .milliseconds(1_500))
        XCTAssertEqual(state.heldSeconds(now: pressed + .seconds(9)) ?? -1,
                       1.5, accuracy: 0.001)

        state.cancelCapture()
        XCTAssertNil(state.heldSeconds(now: pressed), "a cancelled press is not a hold")
        XCTAssertNil(PipelineSessionState().heldSeconds())
    }

    func testASlowMicrophoneOpenDoesNotTurnAnArmingTapIntoAHold() {
        var state = PipelineSessionState()
        let pressed = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let owner = state.beginCapture(at: pressed)
        XCTAssertTrue(state.markOpenInFlight(for: owner))
        XCTAssertTrue(state.markPendingRelease(at: pressed + .milliseconds(200)))
        XCTAssertTrue(state.markRecorderReady(for: owner))

        XCTAssertEqual(state.heldSeconds(now: pressed + .milliseconds(3_200)) ?? -1,
                       0.2, accuracy: 0.001)
        _ = state.finishCapture(at: pressed + .milliseconds(3_200))
        XCTAssertEqual(state.heldSeconds() ?? -1, 0.2, accuracy: 0.001)
    }

    func testPreparedAndStandaloneDeliveryHaveExactOwnership() {
        var state = PipelineSessionState()
        let prepared = state.beginPreparedCapture(handsFree: true)
        XCTAssertTrue(state.isRecording)
        XCTAssertTrue(state.handsFree)
        XCTAssertTrue(state.owns(prepared))

        _ = state.finishCapture()
        let standalone = state.beginStandaloneDelivery()
        XCTAssertNotEqual(standalone, prepared)
        XCTAssertTrue(state.owns(standalone))
        XCTAssertTrue(state.isDelivering)
        XCTAssertFalse(state.captureActive)

        state.endDelivery(owner: prepared)
        XCTAssertTrue(state.isDelivering)
        state.endDelivery(owner: standalone)
        XCTAssertFalse(state.isDelivering)
    }
}
