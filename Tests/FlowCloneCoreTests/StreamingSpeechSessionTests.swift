import XCTest
@testable import FlowCloneCore

final class StreamingSpeechSessionTests: XCTestCase {
    private actor Decoder: StreamingSpeechDecoder {
        var audio: [Float] = []
        var completed: [[Float]] = []
        var emptyFinishes: Int
        var failNextAppend: Bool
        var blocked = false
        var started: CheckedContinuation<Void, Never>?
        var unblock: CheckedContinuation<Void, Never>?
        var overlap = false

        init(emptyFinishes: Int = 0, failNextAppend: Bool = false) {
            self.emptyFinishes = emptyFinishes
            self.failNextAppend = failNextAppend
        }
        func reset() { if unblock != nil { overlap = true }; audio = [] }
        func append(_ samples: [Float]) async throws {
            if unblock != nil { overlap = true }
            if blocked {
                await withCheckedContinuation { continuation in
                    unblock = continuation
                    started?.resume(); started = nil
                }
            }
            audio += samples
            if failNextAppend { failNextAppend = false; throw Failure.injected }
        }
        func partial() -> String { audio.map { String(Int($0)) }.joined(separator: " ") }
        func finish() -> String {
            if unblock != nil { overlap = true }
            completed.append(audio)
            if emptyFinishes > 0 { emptyFinishes -= 1; return "" }
            return partial()
        }
        func block() { blocked = true }
        func waitForAppend() async {
            if unblock != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func release() { blocked = false; let waiter = unblock; unblock = nil; waiter?.resume() }
        enum Failure: Error { case injected }
    }

    func testFinalizationUsesEverySampleExactlyOnceIncludingShortTail() async {
        let decoder = Decoder()
        let session = StreamingSpeechSession(decoder: decoder)
        _ = await session.update([1, 2], offset: 0, generation: 1)
        let update = await session.update([3, 4], offset: 2, generation: 1)
        XCTAssertEqual(update?.sampleCount, 4)
        let result = await session.transcribe([1, 2, 3, 4, 5], generation: 1, maxAttempts: 2, requestID: nil)
        XCTAssertEqual(result.text, "1 2 3 4 5")
        let completed = await decoder.completed
        XCTAssertEqual(completed, [[1, 2, 3, 4, 5]])
        let late = await session.update([6], offset: 5, generation: 1)
        XCTAssertNil(late)
    }

    func testCancellationAndNewGenerationNeverInheritOldSpeech() async {
        let session = StreamingSpeechSession(decoder: Decoder())
        _ = await session.update([1, 2], offset: 0, generation: 1)
        await session.cancel(generation: 1)
        _ = await session.update([7], offset: 0, generation: 2)
        let stale = await session.update([3], offset: 2, generation: 1)
        XCTAssertNil(stale)
        await session.cancel(generation: 1)
        let result = await session.transcribe([7, 8], generation: 2, maxAttempts: 2, requestID: nil)
        XCTAssertEqual(result.text, "7 8")
    }

    func testRouteRecoveryReplaysReplacementAudioEvenWhenLengthMatches() async {
        let session = StreamingSpeechSession(decoder: Decoder())
        _ = await session.update([1, 2, 3], offset: 0, generation: 1, revision: 10)
        let result = await session.transcribe([1, 8, 9], generation: 1, revision: 11, maxAttempts: 2, requestID: nil)
        XCTAssertEqual(result.text, "1 8 9")
    }

    func testGapCannotSilentlySkipAudio() async {
        let session = StreamingSpeechSession(decoder: Decoder())
        _ = await session.update([1], offset: 0, generation: 1)
        let gap = await session.update([3], offset: 2, generation: 1)
        XCTAssertNil(gap)
        let result = await session.transcribe([1, 2, 3], generation: 1, maxAttempts: 2, requestID: nil)
        XCTAssertEqual(result.text, "1 2 3")
    }

    func testFailedFeedAndEmptyFinalRetryFromFullRecording() async {
        let decoder = Decoder(emptyFinishes: 1, failNextAppend: true)
        let session = StreamingSpeechSession(decoder: decoder)
        let failed = await session.update([1, 2], offset: 0, generation: 1)
        XCTAssertNil(failed)
        let result = await session.transcribe([1, 2, 3], generation: 1, maxAttempts: 2, requestID: nil)
        XCTAssertEqual(result.text, "1 2 3")
        if case .success(_, let attempts, _) = result { XCTAssertEqual(attempts, 2) }
        else { XCTFail("Expected successful full-recording retry") }
        let completed = await decoder.completed
        XCTAssertEqual(completed, [[1, 2, 3], [1, 2, 3]])
    }

    func testReleaseWaitsForCancelledPhysicalFeed() async {
        let decoder = Decoder()
        let session = StreamingSpeechSession(decoder: decoder)
        await decoder.block()
        let feed = Task { await session.update([1, 2], offset: 0, generation: 1) }
        await decoder.waitForAppend()
        feed.cancel()
        let final = Task { await session.transcribe([1, 2, 3], generation: 1, maxAttempts: 2, requestID: nil) }
        await decoder.release()
        _ = await feed.value
        let result = await final.value
        XCTAssertEqual(result.text, "1 2 3")
        let overlap = await decoder.overlap
        XCTAssertFalse(overlap)
    }

    func testStandaloneReplayResetsBetweenUtterances() async {
        let session = StreamingSpeechSession(decoder: Decoder())
        let first = await session.transcribe([1, 2], generation: nil, maxAttempts: 1, requestID: nil)
        let second = await session.transcribe([8, 9], generation: nil, maxAttempts: 1, requestID: nil)
        XCTAssertEqual(first.text, "1 2")
        XCTAssertEqual(second.text, "8 9")
    }

    func testRecorderStreamsOnlyUnconsumedSamplesAndRestartsOnRevisionChange() {
        let queue = DispatchQueue(label: "flowclone.test.streaming-recorder")
        queue.sync {
            let recorder = Recorder(queue: queue, idleDelay: 0)
            let audio = (0..<32_007).map(Float.init)
            recorder.preloadForTest(audio)
            let initial = recorder.streamingSnapshot(after: 0, revision: nil)!
            XCTAssertEqual(initial.samples, audio)
            for offset in [7, 15_999, 16_000, 16_003, 32_006] {
                let tail = recorder.streamingSnapshot(after: offset, revision: initial.revision)!
                XCTAssertEqual(tail.offset, offset)
                XCTAssertEqual(tail.samples, Array(audio.dropFirst(offset)))
            }
            XCTAssertNil(recorder.streamingSnapshot(after: audio.count, revision: initial.revision))
            let changed = recorder.streamingSnapshot(after: 16_000, revision: initial.revision - 1)!
            XCTAssertEqual(changed.offset, 0)
            XCTAssertEqual(changed.samples, audio)
            XCTAssertEqual(recorder.end(), audio)
            XCTAssertNil(recorder.streamingSnapshot(after: 0, revision: nil))
        }
    }
}
