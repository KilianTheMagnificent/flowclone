import FluidAudio
import Foundation

/// Explicit synthetic/file replay. No microphone, paste, History, or preference writes.
enum NemotronSelfCheck {
    enum Failure: Error { case missingAudio, unavailable, empty, mismatch, missingTail, cancelledSessionLeaked }

    static func run() async throws {
        guard let path = launchArgValue("--streaming-audio") else { throw Failure.missingAudio }
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        guard samples.count > 3_200, samples.count <= 16_000 * 300 else { throw Failure.missingAudio }
        let transcriber = Transcriber(engine: .nemotron)
        guard await transcriber.ensureLoaded(progress: { log("NEMOTRONCHECK \($0)") }) else { throw Failure.unavailable }
        let batch = await transcriber.transcribe(samples, maxAttempts: 1)
        guard let expected = batch.text, !expected.isEmpty else { throw Failure.empty }
        if let word = launchArgValue("--expect-word"), !expected.lowercased().contains(word.lowercased()) {
            throw Failure.missingTail
        }
        for generation in 1...2 {
            var offset = 0
            var partials = 0
            // Irregular callback sizes and an unsubmitted short tail test real finalization.
            let boundary = samples.count - (generation == 1 ? 913 : 2_171)
            while offset < boundary {
                let end = min(boundary, offset + (offset.isMultiple(of: 2) ? 2_560 : 3_201))
                let update = await transcriber.stream(Array(samples[offset..<end]), offset: offset,
                                                      generation: generation, revision: 1)
                guard let update else { throw Failure.unavailable }
                offset = update.sampleCount
                if !update.text.isEmpty { partials += 1 }
            }
            let releasedAt = DispatchTime.now()
            let final = await transcriber.transcribe(samples, maxAttempts: 1,
                streamGeneration: generation, streamRevision: 1)
            guard final.text == expected, partials > 0 else { throw Failure.mismatch }
            log(String(format: "NEMOTRONCHECK stream=%d partials=%d chars=%d tail_ms=%.1f PASS",
                       generation, partials, expected.count, ms(releasedAt, .now())))
        }
        _ = await transcriber.stream(Array(samples.prefix(6_400)), offset: 0, generation: 3, revision: 1)
        await transcriber.cancelStream(generation: 3)
        let stale = await transcriber.stream([0], offset: 6_400, generation: 3, revision: 1)
        guard stale == nil else { throw Failure.cancelledSessionLeaked }
        let afterCancel = await transcriber.transcribe(samples, maxAttempts: 1,
            streamGeneration: 4, streamRevision: 1)
        guard afterCancel.text == expected else { throw Failure.cancelledSessionLeaked }
        log("NEMOTRONCHECK PASS (batch, streamed tails, repeated sessions, cancellation, expected word)")
    }
}
