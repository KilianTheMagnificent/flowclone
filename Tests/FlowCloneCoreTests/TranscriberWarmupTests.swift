import FluidAudio
import XCTest
@testable import FlowCloneCore

final class TranscriberWarmupTests: XCTestCase {
    private actor Calls {
        var counts: [Int] = []
        func append(_ count: Int) { counts.append(count) }
    }

    func testLongDictationUsesOneDecoderWithoutChangingRecognitionRules() {
        let config = Transcriber.recognitionConfig
        let defaults = ASRConfig.default
        XCTAssertEqual(config.parallelChunkConcurrency, 1)
        XCTAssertEqual(config.sampleRate, defaults.sampleRate)
        XCTAssertEqual(config.melChunkContextOverride, defaults.melChunkContextOverride)
        XCTAssertEqual(config.seamGapRepair, defaults.seamGapRepair)
        XCTAssertEqual(config.seamGapRepairMinGapSeconds, defaults.seamGapRepairMinGapSeconds)
        XCTAssertEqual(config.dualDecodeArbitration, defaults.dualDecodeArbitration)
    }

    func testWarmupCompletesSingleAndLongRecordingPaths() async throws {
        let calls = Calls()
        try await Transcriber.warmDecoder { count in await calls.append(count) }
        let counts = await calls.counts
        XCTAssertEqual(counts.count, 2)
        XCTAssertGreaterThanOrEqual(counts[0], ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate))
        XCTAssertLessThanOrEqual(counts[0], ASRConstants.maxModelSamples)
        XCTAssertGreaterThan(counts[1], ASRConstants.maxModelSamples * 2)
    }

    func testFailedLongPathWarmupCannotAdvertiseReadiness() async {
        enum WarmupFailure: Error { case unavailable }
        let calls = Calls()
        do {
            try await Transcriber.warmDecoder { count in
                await calls.append(count)
                if count > ASRConstants.maxModelSamples { throw WarmupFailure.unavailable }
            }
            XCTFail("A failed long-path warmup must propagate to the model-load failure handler")
        } catch is WarmupFailure {
            let counts = await calls.counts
            XCTAssertEqual(counts.count, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
