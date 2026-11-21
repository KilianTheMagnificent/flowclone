import XCTest
@testable import FlowCloneCore

final class PauseCompactorTests: XCTestCase {
    private let rate = 16_000

    private func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        // Deterministic room noise around -70 dBFS.
        (0..<Int(seconds * Double(rate))).map { 0.0003 * sin(Float($0) * 1.7) }
    }

    func testLongInteriorPauseIsShortenedAndSpeechIsKept() {
        let input = speech(1) + silence(3) + speech(1)
        let result = PauseCompactor.compact(input)

        XCTAssertEqual(result.pausesShortened, 1)
        XCTAssertEqual(result.removedSeconds, 3 - PauseCompactor.maxPause, accuracy: 0.11)
        XCTAssertEqual(result.samples.count, input.count - Int(result.removedSeconds * Double(rate)))
        XCTAssertEqual(result.samples.filter { abs($0) > 0.1 }.count,
                       input.filter { abs($0) > 0.1 }.count, "no speech sample is removed")
        XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
    }

    func testShortPausesLeadingAndTrailingSilenceAreUntouched() {
        let short = speech(1) + silence(0.6) + speech(1)
        XCTAssertEqual(PauseCompactor.compact(short).samples, short)

        let edges = silence(2) + speech(1) + silence(2)
        XCTAssertEqual(PauseCompactor.compact(edges).samples, edges,
                       "silence before the first word and after the last is not a pause")

        let long = speech(1) + silence(3) + speech(1)
        XCTAssertEqual(PauseCompactor.compact(long, maxPause: 0).samples, long, "0 disables")
    }

    func testSoftWordEndingNextToThePauseIsKept() {
        // A fading consonant below the speech threshold, right after the word.
        let head = speech(1) + speech(0.3, amplitude: 0.002)
        let input = head + silence(3) + speech(1)
        let result = PauseCompactor.compact(input)

        XCTAssertEqual(result.pausesShortened, 1)
        XCTAssertEqual(Array(result.samples.prefix(head.count)), head,
                       "the cut starts after the kept half of the pause, not at the word")
    }

    func testEveryLongPauseInALongDictationIsShortened() {
        var input = speech(1)
        for _ in 0..<4 { input += silence(2.5) + speech(1) }
        let result = PauseCompactor.compact(input)

        XCTAssertEqual(result.pausesShortened, 4)
        XCTAssertEqual(result.samples.filter { abs($0) > 0.1 }.count,
                       input.filter { abs($0) > 0.1 }.count)
    }
}
