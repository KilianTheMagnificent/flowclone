import XCTest
@testable import FlowCloneCore

final class DictationLatencyTests: XCTestCase {
    func testPreviewSkipsPauseButFinalSpeechRemainsEligible() {
        let speech = Array(repeating: Float(0.05), count: 12_800)
        let paused = speech + Array(repeating: Float(0), count: 3_200)
        XCTAssertTrue(SpeechGate.hasRecentSpeech(speech))
        XCTAssertFalse(SpeechGate.hasRecentSpeech(paused))
        XCTAssertTrue(SpeechGate.containsSpeech(paused),
                      "Preview scheduling must not reject a complete utterance")
        XCTAssertTrue(SpeechGate.hasRecentSpeech(paused + speech.suffix(1_600)))
        XCTAssertFalse(SpeechGate.hasRecentSpeech(Array(repeating: 0, count: 16_000)))
        XCTAssertFalse(SpeechGate.hasRecentSpeech([]))
    }

    func testCompletedContextIsConsumedOnce() {
        let queue = DispatchQueue(label: "test.context.completed")
        let executor = DictationContextCapture.Executor(queue: queue)
        let capture = executor.start { _ in
            DictationContext(continuationPrefix: "Ready context", terms: [])
        }
        queue.sync {}
        XCTAssertEqual(capture.take().continuationPrefix, "Ready context")
        XCTAssertNil(capture.take().continuationPrefix)
    }

    func testStalledContextCannotBlockDeliveryOrLeakIntoNextUtterance() {
        let queue = DispatchQueue(label: "test.context.stalled")
        let executor = DictationContextCapture.Executor(queue: queue)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let capture = executor.start { deadline in
            entered.signal()
            _ = resume.wait(timeout: .now() + 2)
            XCTAssertFalse(deadline.hasTimeRemaining)
            XCTAssertNil(deadline.nextTimeout(), "No new AX read after ASR consumes context")
            return DictationContext(continuationPrefix: "Late first utterance", terms: [])
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        // This returns while the AX stand-in is still blocked: no timing race is needed.
        XCTAssertNil(capture.take().continuationPrefix)
        let skipped = executor.start { _ in
            XCTFail("A stalled worker must not enqueue another context job")
            return .empty
        }
        XCTAssertNil(skipped.take().continuationPrefix)
        resume.signal()
        queue.sync {}
        XCTAssertNil(capture.take().continuationPrefix, "Late completion stays discarded")
        let next = executor.start { _ in
            DictationContext(continuationPrefix: "New utterance", terms: [])
        }
        queue.sync {}
        XCTAssertEqual(next.take().continuationPrefix, "New utterance")
    }

    func testQueueDelayConsumesTheSameOverallContextBudget() {
        let queue = DispatchQueue(label: "test.context.expired")
        let executor = DictationContextCapture.Executor(queue: queue)
        queue.suspend()
        let capture = executor.start { _ in
            XCTFail("Expired work must not begin AX reads with a fresh budget")
            return .empty
        }
        Thread.sleep(forTimeInterval: DictationContextCapture.budget + 0.020)
        queue.resume()
        queue.sync {}
        XCTAssertNil(capture.take().continuationPrefix)
    }

    func testContextFinishingAfterDeadlineIsDiscardedEvenBeforeASRFinishes() {
        let queue = DispatchQueue(label: "test.context.late")
        let executor = DictationContextCapture.Executor(queue: queue)
        let capture = executor.start { _ in
            Thread.sleep(forTimeInterval: DictationContextCapture.budget + 0.020)
            return DictationContext(continuationPrefix: "Expired context", terms: [])
        }
        queue.sync {}
        XCTAssertNil(capture.take().continuationPrefix)
    }

    func testLLMReviewedCleanUtterancesDoNotEnterNonLLMLatencyPercentiles() {
        XCTAssertTrue(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .utterance,
            provenInsertion: true, usedLLM: false))
        XCTAssertTrue(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .partialUtterance,
            provenInsertion: true, usedLLM: false))
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .utterance,
            provenInsertion: true, usedLLM: true),
            "Model-reviewed Clean utterances include an LLM round-trip and must not skew non-LLM p50/p95")
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .prompt, origin: .utterance,
            provenInsertion: true, usedLLM: false))
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .selfTest,
            provenInsertion: true, usedLLM: false))
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .repaste,
            provenInsertion: true, usedLLM: false))
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .retry,
            provenInsertion: true, usedLLM: false))
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .practice, mode: .clean, origin: .utterance,
            provenInsertion: true, usedLLM: false))
        XCTAssertFalse(Pipeline.shouldRecordCleanLatency(
            purpose: .editor(.normal), mode: .clean, origin: .utterance,
            provenInsertion: false, usedLLM: false))
    }
}
