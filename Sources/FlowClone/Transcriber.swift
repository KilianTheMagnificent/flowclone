// Parakeet Ultra via FluidAudio. Managed through SpeechRuntime with priority scheduling
// and idle weight unloading when inactive.
import FluidAudio
import Foundation

/// Dedupes repeated progress percentages across the downloader's threads.
final class ModelProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func fire(_ v: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v != last else { return false }
        last = v
        return true
    }
}

actor Transcriber {
    nonisolated let engine: SpeechEngine
    nonisolated let scheduler: DecodeScheduler
    private var streaming: StreamingSpeechSession?
    private var onActivity: (@Sendable () -> Void)?

    init(engine: SpeechEngine = .active,
         scheduler: DecodeScheduler = DecodeScheduler(),
         onActivity: (@Sendable () -> Void)? = nil) {
        self.engine = engine
        self.scheduler = scheduler
        self.onActivity = onActivity
    }

    func setActivityHandler(_ handler: (@Sendable () -> Void)?) {
        onActivity = handler
    }

    var schedulerIsBusy: Bool {
        get async { await scheduler.isBusy }
    }

    func stream(_ samples: [Float], offset: Int, generation: Int, revision: Int) async -> StreamingSpeechSession.Update? {
        onActivity?()
        if !isReady, everLoaded {
            Task { _ = await self.ensureLoaded(progress: { _ in }) }
            return nil
        }
        return await streaming?.update(samples, offset: offset, generation: generation, revision: revision)
    }

    func cancelStream(generation: Int) async { await streaming?.cancel(generation: generation) }

    // FluidAudio's default fans a long recording out to four managers sharing the
    // same Core ML models. The outer DecodeScheduler cannot serialize those inner
    // predictions. Keep the existing chunking/merging, but reuse one warm manager.
    static let recognitionConfig = ASRConfig(parallelChunkConcurrency: 1)

    // Warm both entry paths before advertising readiness. A one-second decode only
    // exercises the single-window path; longer recordings enter ChunkProcessor.
    static let warmupSampleCounts = [
        ASRConstants.sampleRate,
        ASRConstants.maxModelSamples * 2 + ASRConstants.sampleRate
    ]

    static func warmDecoder(
        operation: @Sendable (Int) async throws -> Void
    ) async throws {
        for count in warmupSampleCounts {
            try Task.checkCancellation()
            try await operation(count)
        }
    }

    struct Metadata: Equatable, Sendable {
        struct Token: Equatable, Sendable {
            let text: String
            let start: Double
            let end: Double
            let confidence: Float
        }
        let confidence: Float
        let audioSeconds: Double
        let processingSeconds: Double
        let tokens: [Token]
        var decoderText: String? = nil

        var unknownTokenCount: Int { (decoderText?.components(separatedBy: "<unk>").count ?? 1) - 1 }
    }

    enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    enum Outcome: Equatable, Sendable {
        case success(text: String, attempts: Int, metadata: Metadata? = nil)
        case failed(attempts: Int)

        var text: String? {
            if case .success(let text, _, _) = self { return text }
            return nil
        }
    }

    enum AttemptRejection: Sendable {
        case empty
        case error(Error)
    }

    private var manager: AsrManager?
    private var decoderLayers = 2
    private var loading = false
    private var everLoaded = false
    private var lastLoadError: String?
    /// Why the last load failed, for the Settings page and the failure notice.
    private(set) var lastLoadProblem: SpeechModelProblem?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []

    var isReady: Bool { manager != nil || streaming != nil }
    var canReloadOnDemand: Bool { everLoaded }
    var state: LoadState {
        if isReady { return .ready }
        if loading { return .loading }
        if let lastLoadError { return .failed(lastLoadError) }
        return .idle
    }

    /// Downloads (first run, ~630MB from HuggingFace) + loads + warms the model.
    /// `progress` is called with a short status string suitable for the log.
    func load(progress: @Sendable @escaping (String) -> Void) async {
        _ = await ensureLoaded(progress: progress)
    }

    /// Single-flight model load. Actor reentrancy means another caller can enter while the
    /// first download/load is suspended; those callers wait on the same attempt instead of
    /// starting a second model load. A failed attempt is retryable on the next call.
    @discardableResult
    func ensureLoaded(progress: @Sendable @escaping (String) -> Void) async -> Bool {
        onActivity?()
        if isReady { return true }
        if loading {
            return await withCheckedContinuation { loadWaiters.append($0) }
        }
        loading = true
        lastLoadError = nil
        lastLoadProblem = nil
        let t0 = Date()
        let loaded: Bool
        var needsDownload = false
        do {
            // Hands-free sessions never download; tools/handsfree-flowclone.sh --with-model seeds Parakeet.
            if handsfreeSession, engine == .nemotron || !AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: SpeechEngine.parakeetModelVersion)) {
                Handsfree.log("blocked speech model download"); throw CocoaError(.fileNoSuchFile)
            }
            if engine == .nemotron {
                let decoder = NemotronDecoder()
                try await decoder.load(progress: progress)
                streaming = StreamingSpeechSession(decoder: decoder, scheduler: scheduler)
                log(String(format: "ASR ready — load+warmup %.2fs (%@)", Date().timeIntervalSince(t0), engine.modelID))
            } else {
                let throttle = ModelProgressThrottle()
                // FluidAudio does not look at free space: a download onto a nearly full disk
                // fills it to zero and then fails. Say so before starting instead.
                needsDownload = !AsrModels.modelsExist(
                    at: AsrModels.defaultCacheDirectory(for: SpeechEngine.parakeetModelVersion))
                if needsDownload, let free = SpeechModelProblem.freeDiskBytes(),
                   free < SpeechModelProblem.requiredFreeBytes {
                    throw SpeechModelProblem.lowDisk(freeBytes: free)
                }
                let models = try await AsrModels.downloadAndLoad(version: SpeechEngine.parakeetModelVersion) { p in
                    // Only the download phase is worth reporting; the cached path fires
                    // listing/compiling ticks with empty payloads on every launch.
                    guard case .downloading(let done, let total) = p.phase, total > 0 else { return }
                    if throttle.fire(done) { progress(SpeechModelStatus.downloadingLine(done: done, total: total)) }
                }
                let m = AsrManager(config: Self.recognitionConfig)
                try await m.loadModels(models)
                decoderLayers = await m.decoderLayerCount
                let loadSeconds = Date().timeIntervalSince(t0)

                // Synthetic silence only: no microphone capture or retained user audio.
                let w0 = Date()
                try await Self.warmDecoder { count in
                    _ = try await self.run(m, Array(repeating: 0, count: count))
                }
                manager = m
                log(String(format: "ASR ready — load %.2fs, warmup %.0fms (%@; FluidAudio %@; single+chunked; parallel_chunks=1)",
                           loadSeconds, Date().timeIntervalSince(w0) * 1000,
                           engine.modelID, SpeechEngine.fluidAudioVersion))
            }
            everLoaded = true
            progress("ready")
            loaded = true
        } catch {
            log("ASR LOAD FAILED: \(error)")
            progress("failed")
            lastLoadError = String(describing: error)
            lastLoadProblem = SpeechModelProblem.classify(error, freeBytes: SpeechModelProblem.freeDiskBytes(),
                                                          needsDownload: needsDownload)
            loaded = false
        }
        loading = false
        let waiters = loadWaiters
        loadWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(returning: loaded) }
        return loaded
    }

    /// Releases resident CoreML / ANE weights when idle. A subsequent `ensureLoaded` or
    /// non-preview `transcribe` transparently reloads from local disk cache.
    @discardableResult
    func unloadIfIdle() async -> Bool {
        guard isReady, !loading else { return false }
        guard !(await scheduler.isBusy), !(await scheduler.isInteractiveActive) else { return false }
        guard await scheduler.acquire(.background) else { return false }
        let unloaded: Bool
        if isReady, !loading, !(await scheduler.isInteractiveActive) {
            manager = nil
            streaming = nil
            log("ASR idle — unloaded \(engine.modelID) weights until next transcription")
            unloaded = true
        } else {
            unloaded = false
        }
        await scheduler.release()
        return unloaded
    }

    /// Returns the transcript, or nil if the model is not loaded / transcription threw.
    /// Kept for source compatibility while Pipeline adopts the richer Outcome overload.
    func transcribe(_ samples: [Float], priority: DecodeScheduler.Priority = .final,
                    requestID: String? = nil) async -> String? {
        await transcribe(samples, maxAttempts: 1, priority: priority, requestID: requestID).text
    }

    /// A live capture should use maxAttempts=2 (initial decode plus one automatic retry on
    /// thrown engine errors). A user-invoked Retry should use maxAttempts=1. Every attempt
    /// gets a fresh decoder state through run(); no audio is persisted here. `maxPause`
    /// shortens interior silences before a Parakeet decode (see PauseCompactor); nil decodes as recorded.
    func transcribe(_ samples: [Float], maxAttempts: Int,
                    priority: DecodeScheduler.Priority = .final, requestID: String? = nil,
                    streamGeneration: Int? = nil, streamRevision: Int = 0,
                    maxPause: Double? = nil) async -> Outcome {
        onActivity?()
        if !isReady, everLoaded {
            if priority == .preview {
                Task { _ = await self.ensureLoaded(progress: { _ in }) }
                return .failed(attempts: 0)
            }
            guard await ensureLoaded(progress: { _ in }) else { return .failed(attempts: 0) }
        }
        if engine == .nemotron {
            guard let streaming else { return .failed(attempts: 0) }
            return await streaming.transcribe(samples, generation: streamGeneration, revision: streamRevision,
                                               maxAttempts: maxAttempts, requestID: requestID)
        }
        let compacted = maxPause.map { PauseCompactor.compact(samples, maxPause: $0) }
        let input = compacted?.samples ?? samples
        if let compacted, let maxPause, compacted.pausesShortened > 0 {
            log(String(format: "ASR pauses: shortened %d interior pause(s) to %.1fs, %.1fs removed",
                       compacted.pausesShortened, maxPause, compacted.removedSeconds))
        }
        let queuedAt = DispatchTime.now()
        guard await scheduler.acquire(priority) else { return .failed(attempts: 0) }
        let outcome = await decodeParakeet(input, rawSampleCount: samples.count,
                                           maxAttempts: maxAttempts, priority: priority,
                                           queuedAt: queuedAt, requestID: requestID)
        await scheduler.release()
        return outcome
    }

    private func decodeParakeet(_ input: [Float], rawSampleCount: Int, maxAttempts: Int,
                                priority: DecodeScheduler.Priority, queuedAt: DispatchTime,
                                requestID: String?) async -> Outcome {
        let startedAt = DispatchTime.now()
        guard !Task.isCancelled else { return .failed(attempts: 0) }
        guard let m = manager else {
            log("ASR not ready — dropping \(rawSampleCount) samples")
            return .failed(attempts: 0)
        }
        let limit = max(1, maxAttempts)
        let outcome = await Self.retrying(maxAttempts: limit, retryOnEmpty: false, onRejected: { attempt, rejection in
            switch rejection {
            case .empty:
                log("ASR attempt \(attempt)/\(limit) returned empty text")
            case .error(let error):
                log("ASR attempt \(attempt)/\(limit) ERROR: \(error)")
            }
        }, operation: { _ in
            let (text, metadata) = try await self.run(m, input)
            return (text, metadata)
        })
        switch outcome {
        case .success(let text, let attempts, _) where text.isEmpty:
            log("ASR attempt \(attempts)/\(limit) returned empty text (non-speech)")
        case .success(_, let attempts, _) where attempts > 1:
            log("ASR recovered on attempt \(attempts)/\(limit)")
        case .failed(let attempts):
            log("ASR failed after \(attempts) attempt\(attempts == 1 ? "" : "s")")
        default:
            break
        }
        log(String(format: "ASR_METRIC priority=%d queue_ms=%.1f decode_ms=%.1f samples=%d path=%@ parallel_chunks=%d request_id=%@",
                   priority.rawValue, ms(queuedAt, startedAt), ms(startedAt, .now()), input.count,
                   input.count > ASRConstants.maxModelSamples ? "chunked" : "single",
                   Self.recognitionConfig.parallelChunkConcurrency, requestID ?? "standalone"))
        if Task.isCancelled { return .failed(attempts: 0) }
        return outcome
    }

    /// Kept for source compatibility with legacy callers; empty non-speech now returns
    /// `.success(text: "", ...)` directly without mutating shared actor metadata.
    var lastFailureHeardNoWords: Bool { false }

    /// Each utterance is independent, so it gets a fresh decoder state and returns its
    /// sanitized text and metadata directly without cross-suspension state mutation.
    private func run(_ m: AsrManager, _ samples: [Float]) async throws -> (text: String, metadata: Metadata) {
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await m.transcribe(samples, decoderState: &state)
        let metadata = Metadata(confidence: result.confidence, audioSeconds: result.duration,
                                processingSeconds: result.processingTime,
                                tokens: (result.tokenTimings ?? []).map {
            Metadata.Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        }, decoderText: result.text)
        return (Self.sanitize(result.text), metadata)
    }

    /// Parakeet's vocabulary has no `&` (nor @ # * _ + = " ;), so an "and" it would write as
    /// `&` (R&D, AT&T) comes out as its unknown token, and FluidAudio passes the literal
    /// `<unk>` through — a friend's paste read `R<unk>D`. Measured 2026-09-06 (CorpusReplay,
    /// synthesized speech): `<unk>` appeared only in that position; spoken symbol names came
    /// back as words and `$20`/`50%` are emitted natively.
    /// ponytail: `<unk>` → "&" unconditionally; if "@"/"#" ever surface, decide by neighbours.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<unk>", with: "&")
    }

    /// Retries only on thrown engine/CoreML errors by default (`retryOnEmpty: false`),
    /// avoiding a second deterministic CoreML pass when Parakeet cleanly returns `""`.
    static func retrying(
        maxAttempts: Int,
        retryOnEmpty: Bool = false,
        onRejected: @Sendable (Int, AttemptRejection) -> Void,
        operation: @Sendable (Int) async throws -> (text: String, metadata: Metadata?)
    ) async -> Outcome {
        let limit = max(1, maxAttempts)
        for attempt in 1...limit {
            if Task.isCancelled { return .failed(attempts: attempt - 1) }
            do {
                let (text, metadata) = try await operation(attempt)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if retryOnEmpty {
                        onRejected(attempt, .empty)
                        continue
                    }
                    return .success(text: "", attempts: attempt, metadata: metadata)
                }
                return .success(text: text, attempts: attempt, metadata: metadata)
            } catch {
                onRejected(attempt, .error(error))
            }
        }
        return .failed(attempts: limit)
    }
}
