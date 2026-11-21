import XCTest
@testable import FlowCloneCore

final class OverlayIdleTests: XCTestCase {
    /// Phase policy is independent of WindowServer. Real window/morph/layout assertions
    /// belong to the signed --pilltest integration probe, which requires a display.
    @MainActor
    func testOnlyActivePhasesRequestAnimationTicks() {
        let view = PillView()
        view.reduceMotion = false
        view.reset()
        XCTAssertFalse(view.needsContinuousTicks)
        view.push(0.2)
        XCTAssertTrue(view.needsContinuousTicks)
        view.beginProcessing(slow: false)
        XCTAssertTrue(view.needsContinuousTicks)
        view.beginWarming()
        XCTAssertTrue(view.needsContinuousTicks)
        view.beginReady()
        XCTAssertFalse(view.needsContinuousTicks)
        view.beginFailure()
        XCTAssertFalse(view.needsContinuousTicks)
        view.beginIdle()
        XCTAssertFalse(view.needsContinuousTicks)
    }

    @MainActor
    func testReducedMotionNeverStartsAnAnimationClock() {
        let view = PillView()
        view.reduceMotion = true
        view.reset(); view.push(0.8)
        XCTAssertFalse(view.needsContinuousTicks)
        view.beginProcessing(slow: true)
        XCTAssertFalse(view.needsContinuousTicks)
        view.beginWarming()
        XCTAssertFalse(view.needsContinuousTicks)
        view.reduceMotion = false
        XCTAssertTrue(view.needsContinuousTicks)
    }

    @MainActor
    func testLongPreviewStaysBoundedAndEmptyPreviewCollapses() {
        XCTAssertEqual(TranscriptView.size(for: ""), .zero)
        let long = String(repeating: "Latest words remain visible. ", count: 200)
        XCTAssertGreaterThan(TranscriptView.textHeight(long), TranscriptView.maxHeight)
        XCTAssertEqual(TranscriptView.size(for: long).height, TranscriptView.maxHeight)
    }

    func testIdlePillDefaultsOn() {
        let saved = UserDefaults.standard.object(forKey: "idlePill")
        defer { UserDefaults.standard.set(saved, forKey: "idlePill") }
        UserDefaults.standard.removeObject(forKey: "idlePill")
        XCTAssertTrue(Overlay.idlePillEnabled)
        Overlay.idlePillEnabled = false
        XCTAssertFalse(Overlay.idlePillEnabled)
    }
}
