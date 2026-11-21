import Foundation
import XCTest
@testable import FlowCloneCore

final class TranscriptionStatsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = ScratchDefaults.name("transcription-stats")
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let defaults, let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        defaults = nil
        suiteName = nil
    }

    func testWordCountingAndOriginPolicyUseInjectedDefaults() {
        XCTAssertEqual(TranscriptionStats.wordCount(in: "Hello, world! It’s 2026."), 4)
        XCTAssertEqual(TranscriptionStats.wordCount(in: "  \n\t  "), 0)
        XCTAssertEqual(TranscriptionStats.totalWords(in: defaults), 0)
        XCTAssertEqual(TranscriptionStats.totalSeconds(in: defaults), 0)

        TranscriptionStats.record("one two three", seconds: 3.5, origin: .utterance, defaults: defaults)
        XCTAssertEqual(TranscriptionStats.totalWords(in: defaults), 3)
        XCTAssertEqual(TranscriptionStats.totalSeconds(in: defaults), 3.5, accuracy: 0.001)
        TranscriptionStats.record("four five", seconds: 2.25, origin: .partialUtterance, defaults: defaults)
        XCTAssertEqual(TranscriptionStats.totalWords(in: defaults), 5)
        XCTAssertEqual(TranscriptionStats.totalSeconds(in: defaults), 5.75, accuracy: 0.001)
        TranscriptionStats.record("six", seconds: 1.25, origin: .retry, defaults: defaults)
        XCTAssertEqual(TranscriptionStats.totalWords(in: defaults), 6)
        XCTAssertEqual(TranscriptionStats.totalSeconds(in: defaults), 7.0, accuracy: 0.001)
        TranscriptionStats.record("not counted", seconds: 10, origin: .repaste, defaults: defaults)
        TranscriptionStats.record("also not counted", seconds: 10, origin: .selfTest, defaults: defaults)

        XCTAssertEqual(TranscriptionStats.totalWords(in: defaults), 6)
        XCTAssertEqual(TranscriptionStats.totalSeconds(in: defaults), 7.0, accuracy: 0.001)
    }

    func testNegativePersistedValueIsClamped() {
        defaults.set(-42, forKey: "totalWordsTranscribed")
        defaults.set(-15.5, forKey: "totalSecondsTranscribed")
        XCTAssertEqual(TranscriptionStats.totalWords(in: defaults), 0)
        XCTAssertEqual(TranscriptionStats.totalSeconds(in: defaults), 0)
    }

    func testFormatSpeakingTime() {
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(0), "0s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(-5), "0s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(.nan), "0s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(0.3), "1s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(42.4), "42s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(59.6), "1m")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(60), "1m")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(85), "1m 25s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(510), "8m 30s")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(3_599.6), "1h")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(3_600), "1h")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(3_660), "1h 1m")
        XCTAssertEqual(TranscriptionStats.formatSpeakingTime(5_040), "1h 24m")
    }
}
