import XCTest
@testable import FlowCloneCore

final class TranscriberRetryTests: XCTestCase {
    func testDeterministicRetryFixtures() async {
        enum FixtureError: Error { case failed }
        let ignored: @Sendable (Int, Transcriber.AttemptRejection) -> Void = { _, _ in }

        let meta = Transcriber.Metadata(
            confidence: 0.96,
            audioSeconds: 0.5,
            processingSeconds: 0.018,
            tokens: [.init(text: "ready", start: 0, end: 0.5, confidence: 0.96)]
        )
        let first = await Transcriber.retrying(maxAttempts: 2, onRejected: ignored) { _ in
            ("ready", meta)
        }
        XCTAssertEqual(first, .success(text: "ready", attempts: 1, metadata: meta))

        let recoveredError = await Transcriber.retrying(maxAttempts: 2, onRejected: ignored) { attempt in
            if attempt == 1 { throw FixtureError.failed }
            return ("recovered", nil)
        }
        XCTAssertEqual(recoveredError, .success(text: "recovered", attempts: 2))

        // Parakeet deterministic CoreML (`retryOnEmpty: false` default) must NOT run a
        // second CoreML pass when attempt 1 cleanly returns empty/whitespace non-speech.
        actor Counter {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let emptyCounter = Counter()
        let emptyNonSpeech = await Transcriber.retrying(maxAttempts: 2, onRejected: ignored) { _ in
            _ = await emptyCounter.next()
            return ("  \n", nil)
        }
        let emptyCalls = await emptyCounter.count
        XCTAssertEqual(emptyCalls, 1, "Clean empty Parakeet decode must not trigger a duplicate CoreML pass")
        XCTAssertEqual(emptyNonSpeech, .success(text: "", attempts: 1))

        // Streaming-to-full-audio fallback explicitly opts into `retryOnEmpty: true`.
        let recoveredStreamingEmpty = await Transcriber.retrying(
            maxAttempts: 2,
            retryOnEmpty: true,
            onRejected: ignored
        ) { attempt in
            (attempt == 1 ? "  \n" : "recovered", nil)
        }
        XCTAssertEqual(recoveredStreamingEmpty, .success(text: "recovered", attempts: 2))

        let exhausted = await Transcriber.retrying(maxAttempts: 2, onRejected: ignored) { _ in
            throw FixtureError.failed
        }
        XCTAssertEqual(exhausted, .failed(attempts: 2))
    }

    func testUnknownTokenBecomesAmpersand() {
        XCTAssertEqual(Transcriber.sanitize("Our R<unk>D budget grew 50% this year"),
                       "Our R&D budget grew 50% this year")
        XCTAssertEqual(Transcriber.sanitize("Tom <unk> Jerry"), "Tom & Jerry")
        XCTAssertEqual(Transcriber.sanitize("Nothing to convert here."), "Nothing to convert here.")
    }
}
