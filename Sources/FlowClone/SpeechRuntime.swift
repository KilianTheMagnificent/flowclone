import Accelerate
@preconcurrency import AVFoundation
import Foundation

struct TranscribedFileChunk: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let confidence: Float

    var id: Int { index }
    var offset: TimeInterval { startTime }
    var duration: TimeInterval { max(0, endTime - startTime) }
    var timestamp: String { MeetingNote.timestamp(startTime) }

    init(index: Int, startTime: TimeInterval, endTime: TimeInterval,
         text: String, confidence: Float = 1.0) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
    }
}

enum SpeechRuntimeError: LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case unreadableAudio(String)
    case modelUnavailable
    case transcriptionFailed(chunkIndex: Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Audio file '\(name)' could not be found."
        case .unreadableAudio(let detail):
            return "Could not decode audio file (\(detail))."
        case .modelUnavailable:
            return "The local speech model could not be loaded. Retry when it is available."
        case .transcriptionFailed:
            return "Part of the audio file could not be transcribed."
        }
    }
}

/// Process-wide speech recognition coordinator. Owns a single shared Parakeet `Transcriber`
/// (~630 MB saved vs separate Dictation + Meetings instances), a priority `DecodeScheduler`
/// (`.final` > `.preview` > `.background`), audio file chunk transcription, and an idle
/// weight-unload timer.
actor SpeechRuntime {
    static let defaultIdleUnloadSeconds: TimeInterval = 15 * 60
    static let defaultFileChunkSeconds: TimeInterval = 20.0
    static let targetSampleRate: Double = 16_000.0

    static let shared = SpeechRuntime()

    nonisolated let scheduler: DecodeScheduler
    nonisolated let parakeetTranscriber: Transcriber
    nonisolated let activeTranscriber: Transcriber
    nonisolated let idleUnloadSeconds: TimeInterval

    typealias ChunkDecodeOverride = @Sendable ([Float], DecodeScheduler.Priority) async -> Transcriber.Outcome
    typealias UnloadHook = @Sendable () async -> Bool

    private let chunkDecodeOverride: ChunkDecodeOverride?
    private let unloadHook: UnloadHook?
    private var interactiveSessions = 0
    private var activeOperations = 0
    private var idleGeneration: UInt64 = 0
    private var idleTask: Task<Void, Never>?
    private var residentOverride = false

    init(activeEngine: SpeechEngine = .active,
         idleUnloadSeconds: TimeInterval = SpeechRuntime.defaultIdleUnloadSeconds,
         scheduler: DecodeScheduler = DecodeScheduler(),
         chunkDecodeOverride: ChunkDecodeOverride? = nil,
         unloadHook: UnloadHook? = nil) {
        self.scheduler = scheduler
        self.idleUnloadSeconds = idleUnloadSeconds
        self.chunkDecodeOverride = chunkDecodeOverride
        self.unloadHook = unloadHook

        let parakeet = Transcriber(engine: .parakeet, scheduler: scheduler)
        self.parakeetTranscriber = parakeet
        if activeEngine == .parakeet {
            self.activeTranscriber = parakeet
        } else {
            self.activeTranscriber = Transcriber(engine: activeEngine, scheduler: scheduler)
        }
    }

    deinit {
        idleTask?.cancel()
    }

    // MARK: - Interactive session coordination & idle lifecycle

    func beginInteractiveSession() async {
        interactiveSessions += 1
        idleTask?.cancel()
        idleTask = nil
        await scheduler.setInteractiveActive(true)
        if chunkDecodeOverride == nil,
           !(await activeTranscriber.isReady),
           await activeTranscriber.canReloadOnDemand {
            Task { _ = await self.ensureActiveLoaded(progress: { _ in }) }
        }
    }

    func endInteractiveSession() async {
        interactiveSessions = max(0, interactiveSessions - 1)
        if interactiveSessions == 0 {
            await scheduler.setInteractiveActive(false)
            armIdleTimerIfNeeded()
        }
    }

    func noteActivity() {
        armIdleTimerIfNeeded()
    }

    var isParakeetResident: Bool {
        get async {
            if chunkDecodeOverride != nil { return residentOverride }
            return await parakeetTranscriber.isReady
        }
    }

    func markResidentForTesting(_ resident: Bool) {
        residentOverride = resident
        if resident { armIdleTimerIfNeeded() }
    }

    @discardableResult
    func ensureActiveLoaded(progress: @Sendable @escaping (String) -> Void = { _ in }) async -> Bool {
        beginOperation()
        defer { endOperation() }
        if chunkDecodeOverride != nil {
            residentOverride = true
            progress("ready")
            return true
        }
        return await activeTranscriber.ensureLoaded(progress: progress)
    }

    @discardableResult
    func ensureParakeetLoaded(progress: @Sendable @escaping (String) -> Void = { _ in }) async -> Bool {
        beginOperation()
        defer { endOperation() }
        if chunkDecodeOverride != nil {
            residentOverride = true
            progress("ready")
            return true
        }
        return await parakeetTranscriber.ensureLoaded(progress: progress)
    }

    @discardableResult
    func unloadIdleModelsNow() async -> Bool {
        guard interactiveSessions == 0, activeOperations == 0, !(await scheduler.isBusy) else {
            return false
        }
        if let unloadHook {
            let didUnload = await unloadHook()
            if didUnload { residentOverride = false }
            return didUnload
        }
        if chunkDecodeOverride != nil {
            guard residentOverride else { return false }
            residentOverride = false
            return true
        }
        let unloadedParakeet = await parakeetTranscriber.unloadIfIdle()
        let unloadedActive: Bool
        if activeTranscriber === parakeetTranscriber {
            unloadedActive = false
        } else {
            unloadedActive = await activeTranscriber.unloadIfIdle()
        }
        return unloadedParakeet || unloadedActive
    }

    private func beginOperation() {
        activeOperations += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func endOperation() {
        activeOperations = max(0, activeOperations - 1)
        armIdleTimerIfNeeded()
    }

    private func armIdleTimerIfNeeded() {
        idleTask?.cancel()
        idleTask = nil
        guard idleUnloadSeconds > 0, interactiveSessions == 0, activeOperations == 0 else { return }
        idleGeneration &+= 1
        let generation = idleGeneration
        let delayNanos = UInt64(max(0.001, idleUnloadSeconds) * 1_000_000_000)
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled, let self else { return }
            await self.handleIdleTimerFired(generation: generation)
        }
    }

    private func handleIdleTimerFired(generation: UInt64) async {
        guard generation == idleGeneration,
              interactiveSessions == 0,
              activeOperations == 0 else { return }
        if await scheduler.isBusy {
            armIdleTimerIfNeeded()
            return
        }
        _ = await unloadIdleModelsNow()
    }

    // MARK: - Interactive & Background Transcription

    func transcribeInteractive(
        _ samples: [Float],
        maxAttempts: Int = 2,
        priority: DecodeScheduler.Priority = .final,
        requestID: String? = nil,
        streamGeneration: Int? = nil,
        streamRevision: Int = 0,
        maxPause: Double? = nil
    ) async -> Transcriber.Outcome {
        beginOperation()
        defer { endOperation() }
        if let chunkDecodeOverride {
            if !residentOverride, priority != .preview { residentOverride = true }
            guard await scheduler.acquire(priority) else { return .failed(attempts: 0) }
            let outcome = await chunkDecodeOverride(samples, priority)
            await scheduler.release()
            return outcome
        }
        return await activeTranscriber.transcribe(
            samples,
            maxAttempts: maxAttempts,
            priority: priority,
            requestID: requestID,
            streamGeneration: streamGeneration,
            streamRevision: streamRevision,
            maxPause: maxPause
        )
    }

    func transcribeBackground(
        _ samples: [Float],
        maxAttempts: Int = 2,
        requestID: String? = nil,
        maxPause: Double? = nil
    ) async -> Transcriber.Outcome {
        beginOperation()
        defer { endOperation() }
        if let chunkDecodeOverride {
            residentOverride = true
            guard await scheduler.acquire(.background) else { return .failed(attempts: 0) }
            let outcome = await chunkDecodeOverride(samples, .background)
            await scheduler.release()
            return outcome
        }
        guard await parakeetTranscriber.ensureLoaded(progress: { _ in }) else {
            return .failed(attempts: 0)
        }
        return await parakeetTranscriber.transcribe(
            samples,
            maxAttempts: maxAttempts,
            priority: .background,
            requestID: requestID,
            maxPause: maxPause
        )
    }

    /// Shared `.background` entry point for `LocalMeetingTranscriber` (`Meetings/MeetingIntelligence.swift`),
    /// sharing the single resident Parakeet graph and yielding to live dictation.
    func transcribeMeetingSegment(at url: URL) async throws -> String {
        let samples = try await Self.decodeAudioFileToMono16k(at: url)
        guard SpeechGate.containsSpeech(samples) else { return "" }
        guard await ensureParakeetLoaded(progress: { _ in }) else {
            throw MeetingFailure("The local speech model could not be loaded. Retry when it is available.")
        }
        let outcome = await transcribeBackground(samples, maxAttempts: 2, requestID: "meeting-\(url.lastPathComponent)")
        if let text = outcome.text {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if chunkDecodeOverride == nil, await parakeetTranscriber.lastFailureHeardNoWords {
            return ""
        }
        throw MeetingFailure("This audio segment could not be transcribed. Its audio is saved for retry.")
    }

    // MARK: - Imported Audio / Video File Transcription

    /// Decodes an imported `.m4a`/`.mp3`/`.wav`/`.mp4` file into 16 kHz mono `Float` windows
    /// via `AVAudioFile` + `AVAudioConverter` (falling back to `AVAssetReader` for `.mp4`/video
    /// containers) and transcribes speech windows at `.background` priority with timestamps.
    func transcribeAudioFile(
        at url: URL,
        chunkSeconds: TimeInterval = SpeechRuntime.defaultFileChunkSeconds,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscribedFileChunk] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechRuntimeError.fileNotFound(url.lastPathComponent)
        }
        try Task.checkCancellation()
        let samples = try await Self.decodeAudioFileToMono16k(at: url)
        progress?(0.05)
        return try await transcribeSamples(
            samples,
            chunkSeconds: chunkSeconds,
            progressBase: 0.05,
            progress: progress
        )
    }

    /// Transcribes already-decoded 16 kHz mono `Float` samples in silence-snapped windows at
    /// `.background` priority, avoiding redundant audio file decoding during meeting import.
    func transcribeSamples(
        _ samples: [Float],
        chunkSeconds: TimeInterval = SpeechRuntime.defaultFileChunkSeconds,
        progressBase: Double = 0.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscribedFileChunk] {
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            progress?(1.0)
            return []
        }

        let windows = Self.partitionAudioWindows(samples, sampleRate: Self.targetSampleRate,
                                                 targetWindowSeconds: max(2.0, chunkSeconds))
        guard !windows.isEmpty else {
            progress?(1.0)
            return []
        }

        let speechWindows = windows.filter { range in
            let slice = Array(samples[range])
            return slice.count >= 1_600 && SpeechGate.containsSpeech(slice)
        }
        guard !speechWindows.isEmpty else {
            progress?(1.0)
            return []
        }

        guard await ensureParakeetLoaded(progress: { _ in }) else {
            throw SpeechRuntimeError.modelUnavailable
        }

        let clampedBase = min(max(0.0, progressBase), 0.95)
        let remainingProgress = 1.0 - clampedBase
        var chunks: [TranscribedFileChunk] = []
        chunks.reserveCapacity(speechWindows.count)

        for (offsetIndex, range) in speechWindows.enumerated() {
            try Task.checkCancellation()
            let windowSamples = Array(samples[range])
            let startTime = Double(range.lowerBound) / Self.targetSampleRate
            let endTime = Double(range.upperBound) / Self.targetSampleRate
            let outcome = await transcribeBackground(
                windowSamples,
                maxAttempts: 2,
                requestID: "import-\(offsetIndex)"
            )
            try Task.checkCancellation()
            switch outcome {
            case .success(let rawText, _, let metadata):
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(
                        TranscribedFileChunk(
                            index: chunks.count,
                            startTime: startTime,
                            endTime: endTime,
                            text: trimmed,
                            confidence: metadata?.confidence ?? 1.0
                        )
                    )
                }
            case .failed:
                if chunkDecodeOverride == nil, await parakeetTranscriber.lastFailureHeardNoWords {
                    break
                }
                throw SpeechRuntimeError.transcriptionFailed(chunkIndex: offsetIndex)
            }
            progress?(clampedBase + remainingProgress * Double(offsetIndex + 1) / Double(speechWindows.count))
            await Task.yield()
        }

        return chunks
    }

    // MARK: - Audio Decoding & Windowing (16 kHz Mono Float)

    static func partitionAudioWindows(
        _ samples: [Float],
        sampleRate: Double = targetSampleRate,
        targetWindowSeconds: TimeInterval = defaultFileChunkSeconds
    ) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        let targetSamples = max(Int(sampleRate * 2), Int((sampleRate * targetWindowSeconds).rounded()))
        guard samples.count > targetSamples else {
            return [0..<samples.count]
        }

        let tenthSecond = max(1, Int(sampleRate / 10))
        let searchMargin = min(Int(sampleRate * 2), targetSamples / 4)
        let analysis = SpeechGate.windows(samples, rate: sampleRate)

        var ranges: [Range<Int>] = []
        var cursor = 0
        while cursor < samples.count {
            let remaining = samples.count - cursor
            if remaining <= targetSamples + tenthSecond * 5 {
                ranges.append(cursor..<samples.count)
                break
            }

            let idealEnd = cursor + targetSamples
            var chosenEnd = idealEnd
            if let analysis {
                let minWindow = max((cursor + tenthSecond) / tenthSecond, (idealEnd - searchMargin) / tenthSecond)
                let maxWindow = min(analysis.db.count - 1, (idealEnd + searchMargin) / tenthSecond)
                if minWindow <= maxWindow {
                    let idealWindow = idealEnd / tenthSecond
                    var bestWindow: Int?
                    var bestDistance = Int.max
                    for w in minWindow...maxWindow where analysis.db[w] <= analysis.threshold {
                        let dist = abs(w - idealWindow)
                        if dist < bestDistance {
                            bestDistance = dist
                            bestWindow = w
                        }
                    }
                    if let bestWindow {
                        let candidate = (bestWindow + 1) * tenthSecond
                        if candidate > cursor + tenthSecond * 5, candidate < samples.count {
                            chosenEnd = candidate
                        }
                    }
                }
            }
            ranges.append(cursor..<chosenEnd)
            cursor = chosenEnd
        }
        return ranges
    }

    static func decodeAudioFileToMono16k(at url: URL) async throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechRuntimeError.fileNotFound(url.lastPathComponent)
        }
        do {
            return try decodeViaAVAudioFile(at: url)
        } catch {
            // Containers with video tracks (e.g. `.mp4`/`.mov`) may be rejected by ExtAudioFile;
            // fall back to AVAssetReader on the first audio track.
            if let fallback = try? await decodeViaAVAssetReader(at: url) {
                return fallback
            }
            throw error
        }
    }

    private final class OneShotPCMInput: @unchecked Sendable {
        private let lock = NSLock()
        private let buffer: AVAudioPCMBuffer?
        private let isEndOfStream: Bool
        private var consumed = false

        init(_ buffer: AVAudioPCMBuffer?, isEndOfStream: Bool = false) {
            self.buffer = buffer
            self.isEndOfStream = isEndOfStream
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            if isEndOfStream {
                status.pointee = .endOfStream
                return nil
            }
            guard !consumed, let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
    }

    static func decodeViaAVAudioFile(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechRuntimeError.unreadableAudio(error.localizedDescription)
        }

        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw SpeechRuntimeError.unreadableAudio("invalid audio format")
        }
        guard file.length > 0 else { return [] }

        guard let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat) else {
            throw SpeechRuntimeError.unreadableAudio("unsupported sample rate conversion")
        }

        let readCapacity: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: readCapacity),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoSourceFormat, frameCapacity: readCapacity) else {
            throw SpeechRuntimeError.unreadableAudio("could not allocate decode buffers")
        }

        let ratio = targetSampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(readCapacity) * ratio) + 256
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(outCapacity, 4_096)) else {
            throw SpeechRuntimeError.unreadableAudio("could not allocate output buffer")
        }

        let estimatedSamples = max(0, Int((Double(file.length) * ratio).rounded()))
        var samples: [Float] = []
        samples.reserveCapacity(min(estimatedSamples + 256, 16_000 * 60 * 30))

        while file.framePosition < file.length {
            readBuffer.frameLength = 0
            do {
                try file.read(into: readBuffer, frameCount: readCapacity)
            } catch {
                throw SpeechRuntimeError.unreadableAudio(error.localizedDescription)
            }
            guard readBuffer.frameLength > 0 else { break }

            downmixToMonoFloat(from: readBuffer, into: monoBuffer)
            try appendConverted(monoBuffer, isEndOfStream: false, using: converter,
                                scratch: outBuffer, into: &samples)
        }

        try appendConverted(nil, isEndOfStream: true, using: converter,
                            scratch: outBuffer, into: &samples)
        return samples
    }

    private static func decodeViaAVAssetReader(at url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw SpeechRuntimeError.unreadableAudio("no audio track found")
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SpeechRuntimeError.unreadableAudio("cannot read audio track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SpeechRuntimeError.unreadableAudio(reader.error?.localizedDescription ?? "asset reader failed")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            let floatCount = byteLength / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            var chunk = [Float](repeating: 0, count: floatCount)
            let status = chunk.withUnsafeMutableBytes { rawBuffer in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteLength,
                                           destination: rawBuffer.baseAddress!)
            }
            if status == kCMBlockBufferNoErr {
                samples.append(contentsOf: chunk)
            }
        }
        if reader.status == .failed {
            throw SpeechRuntimeError.unreadableAudio(reader.error?.localizedDescription ?? "asset decode failed")
        }
        return samples
    }

    private static func downmixToMonoFloat(from input: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer) {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        mono.frameLength = input.frameLength
        guard frames > 0, let dst = mono.floatChannelData?[0] else { return }

        if let channelData = input.floatChannelData {
            if channels == 1 {
                memcpy(dst, channelData[0], frames * MemoryLayout<Float>.size)
                return
            }
            memcpy(dst, channelData[0], frames * MemoryLayout<Float>.size)
            for ch in 1..<channels {
                vDSP_vadd(dst, 1, channelData[ch], 1, dst, 1, vDSP_Length(frames))
            }
            var scale = 1.0 / Float(channels)
            vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
            return
        }

        // Fallback if processingFormat was interleaved Float32.
        if let mData = input.audioBufferList.pointee.mBuffers.mData {
            let src = mData.assumingMemoryBound(to: Float.self)
            let inv = 1.0 / Float(max(1, channels))
            for f in 0..<frames {
                var sum: Float = 0
                let base = f * channels
                for ch in 0..<channels { sum += src[base + ch] }
                dst[f] = sum * inv
            }
        }
    }

    private static func appendConverted(
        _ input: AVAudioPCMBuffer?,
        isEndOfStream: Bool,
        using converter: AVAudioConverter,
        scratch: AVAudioPCMBuffer,
        into output: inout [Float]
    ) throws {
        let feeder = OneShotPCMInput(input, isEndOfStream: isEndOfStream)
        while true {
            scratch.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: scratch, error: &error) { _, inputStatus in
                feeder.next(inputStatus)
            }
            if let error {
                throw SpeechRuntimeError.unreadableAudio(error.localizedDescription)
            }
            if scratch.frameLength > 0, let ptr = scratch.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(scratch.frameLength)))
            }
            switch status {
            case .haveData:
                if scratch.frameLength == 0 { return }
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw SpeechRuntimeError.unreadableAudio("resampler failed")
            @unknown default:
                return
            }
        }
    }
}
