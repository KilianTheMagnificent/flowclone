import Foundation

/// The host serializes physical decoder calls, including cancelled calls still in Core ML.
/// Test decoders exercise the same ownership, tail, retry and cancellation paths.
protocol StreamingSpeechDecoder: Sendable {
    func reset() async
    func append(_ samples: [Float]) async throws
    func partial() async -> String
    func finish() async throws -> String
}

actor StreamingSpeechSession {
    struct Update: Sendable {
        let sampleCount: Int
        let text: String
    }

    private let decoder: any StreamingSpeechDecoder
    private let scheduler: DecodeScheduler
    private var generation = -1
    private var revision = 0
    private var finished = false
    private var failed = false
    private var sampleCount = 0
    private var partialText = ""

    init(decoder: any StreamingSpeechDecoder, scheduler: DecodeScheduler = DecodeScheduler()) {
        self.decoder = decoder
        self.scheduler = scheduler
    }

    var schedulerIsBusy: Bool {
        get async { await scheduler.isBusy }
    }

    func update(_ samples: [Float], offset: Int, generation owner: Int, revision audioRevision: Int = 0) async -> Update? {
        guard await scheduler.acquire(.preview) else { return nil }
        let result = await performUpdate(samples, offset: offset, owner: owner, audioRevision: audioRevision)
        await scheduler.release()
        return result
    }

    private func performUpdate(_ samples: [Float], offset: Int, owner: Int, audioRevision: Int) async -> Update? {
        guard !Task.isCancelled, owner >= generation, !(owner == generation && finished) else { return nil }
        if owner != generation || revision != audioRevision {
            generation = owner
            revision = audioRevision
            finished = false
            failed = false
            sampleCount = 0
            partialText = ""
            await decoder.reset()
        }
        guard !failed else { return nil }
        guard offset == sampleCount else {
            failed = true // never skip or duplicate audio; finalization will replay the full capture
            return nil
        }
        do {
            try await decoder.append(samples)
            sampleCount += samples.count
            partialText = await decoder.partial()
            return Update(sampleCount: sampleCount, text: partialText)
        } catch {
            failed = true
            log("NEMOTRON stream failed; final recognition will replay the capture")
            return nil
        }
    }

    func cancel(generation owner: Int) async {
        guard await scheduler.acquire(.final) else { return }
        await performCancel(owner: owner)
        await scheduler.release()
    }

    private func performCancel(owner: Int) async {
        guard owner >= generation else { return }
        generation = owner
        finished = true
        sampleCount = 0
        partialText = ""
        await decoder.reset()
    }

    func transcribe(_ samples: [Float], generation owner: Int?, revision audioRevision: Int = 0, maxAttempts: Int,
                    requestID: String?) async -> Transcriber.Outcome {
        let queuedAt = DispatchTime.now()
        guard await scheduler.acquire(.final) else { return .failed(attempts: 0) }
        let outcome = await performTranscribe(samples, queuedAt: queuedAt, owner: owner,
                                              audioRevision: audioRevision, maxAttempts: maxAttempts,
                                              requestID: requestID)
        await scheduler.release()
        return outcome
    }

    private func performTranscribe(_ samples: [Float], queuedAt: DispatchTime, owner: Int?,
                                   audioRevision: Int, maxAttempts: Int,
                                   requestID: String?) async -> Transcriber.Outcome {
        let startedAt = DispatchTime.now()
        guard !Task.isCancelled else { return .failed(attempts: 0) }
        if let owner, owner < generation || (owner == generation && finished) {
            return .failed(attempts: 0)
        }
        let reuse = owner == generation && revision == audioRevision && !finished && !failed && sampleCount <= samples.count
        let reusedSamples = reuse ? sampleCount : 0
        if let owner { generation = owner }
        finished = true // a delayed feed for this generation must never restart it
        partialText = ""
        let result = await Transcriber.retrying(maxAttempts: maxAttempts, retryOnEmpty: true, onRejected: { attempt, _ in
            log("NEMOTRON final attempt \(attempt) rejected; retrying from complete audio if available")
        }, operation: { attempt in
            let start = attempt == 1 ? reusedSamples : 0
            if start == 0 { await self.decoder.reset() }
            try await self.decoder.append(Array(samples.dropFirst(start)))
            let finishedText = try await self.decoder.finish()
            return (finishedText, nil)
        })
        // finish() clears tokens upstream, but the encoder caches also need an explicit reset.
        await decoder.reset()
        sampleCount = 0
        failed = false
        let elapsed = ms(startedAt, .now())
        log(String(format: "ASR_METRIC priority=2 queue_ms=%.1f decode_ms=%.1f samples=%d path=streaming model=nemotron chunk_ms=560 reused_samples=%d request_id=%@",
                   ms(queuedAt, startedAt), elapsed, samples.count, reusedSamples, requestID ?? "standalone"))
        guard !Task.isCancelled else { return .failed(attempts: 0) }
        if case .success(let text, let attempts, _) = result {
            // This decoder does not supply a calibrated confidence. -1 means unavailable.
            let metadata = Transcriber.Metadata(confidence: -1, audioSeconds: Double(samples.count) / 16_000,
                processingSeconds: elapsed / 1_000, tokens: [], decoderText: text)
            return .success(text: text, attempts: attempts, metadata: metadata)
        }
        return result
    }
}
