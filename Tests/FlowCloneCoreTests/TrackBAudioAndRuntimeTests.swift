import AVFoundation
import CoreAudio
import XCTest
@testable import FlowCloneCore

final class TrackBAudioAndRuntimeTests: XCTestCase {
    private actor EventLog<Element: Sendable> {
        private var items: [Element] = []
        func append(_ item: Element) { items.append(item) }
        func values() -> [Element] { items }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value
        init(_ initial: Value) { storage = initial }
        func withValue<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - 1. DecodeScheduler Priority & Interactive Yielding

    func testDecodeSchedulerOrdersFinalAbovePreviewAboveBackgroundWithoutDroppingBackground() async {
        let scheduler = DecodeScheduler()
        let order = EventLog<String>()

        let initialAcquired = await scheduler.acquire(.background)
        XCTAssertTrue(initialAcquired)

        let bgTask = Task {
            let ok = await scheduler.acquire(.background)
            if ok {
                await order.append("background-waiter")
                await scheduler.release()
            }
            return ok
        }
        try? await Task.sleep(nanoseconds: 15_000_000)

        let previewTask = Task {
            let ok = await scheduler.acquire(.preview)
            if ok {
                await order.append("preview")
                await scheduler.release()
            }
            return ok
        }
        try? await Task.sleep(nanoseconds: 15_000_000)

        let finalTask = Task {
            let ok = await scheduler.acquire(.final)
            if ok {
                await order.append("final")
                await scheduler.release()
            }
            return ok
        }
        try? await Task.sleep(nanoseconds: 15_000_000)

        // Releasing the active `.background` decode must run `.final` first, drop the
        // superseded `.preview`, and still preserve `.background` in FIFO order afterward.
        await scheduler.release()

        let previewAccepted = await previewTask.value
        let finalAccepted = await finalTask.value
        let bgAccepted = await bgTask.value

        XCTAssertFalse(previewAccepted, "`.final` must displace a queued `.preview`")
        XCTAssertTrue(finalAccepted)
        XCTAssertTrue(bgAccepted, "`.background` meeting/file jobs must yield, never drop")
        let observed = await order.values()
        XCTAssertEqual(observed, ["final", "background-waiter"])
    }

    func testDecodeSchedulerYieldsBackgroundWhileInteractiveSessionIsActive() async {
        let scheduler = DecodeScheduler()
        let events = EventLog<String>()

        await scheduler.setInteractiveActive(true)

        let bgTask = Task {
            let ok = await scheduler.acquire(.background)
            if ok {
                await events.append("background")
                await scheduler.release()
            }
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
        let whileInteractive = await events.values()
        XCTAssertTrue(whileInteractive.isEmpty, "Background segment must yield while live dictation is active")

        let finalOk = await scheduler.acquire(.final)
        XCTAssertTrue(finalOk)
        await events.append("final")
        await scheduler.release()

        await scheduler.setInteractiveActive(false)
        await bgTask.value

        let finalOrder = await events.values()
        XCTAssertEqual(finalOrder, ["final", "background"])
    }

    // MARK: - 2. Unified SpeechRuntime, Idle Unload Timer & File Transcription

    func testSpeechRuntimeSharesSingleParakeetTranscriberAndUnloadsWhenIdle() async {
        let unloadCounter = EventLog<Int>()
        let runtime = SpeechRuntime(
            activeEngine: .parakeet,
            idleUnloadSeconds: 0.06,
            chunkDecodeOverride: { samples, _ in
                .success(text: "decoded-\(samples.count)", attempts: 1)
            },
            unloadHook: {
                await unloadCounter.append(1)
                return true
            }
        )

        XCTAssertTrue(runtime.activeTranscriber === runtime.parakeetTranscriber,
                      "Dictation and Meetings must share one Parakeet Transcriber (~630 MB saved)")

        // While an interactive session is active, the idle timer must NOT unload weights.
        await runtime.markResidentForTesting(true)
        await runtime.beginInteractiveSession()
        try? await Task.sleep(nanoseconds: 95_000_000)
        let unloadsDuringSession = await unloadCounter.values().count
        XCTAssertEqual(unloadsDuringSession, 0)

        // Ending the interactive session arms the idle unload timer; after ~60ms it unloads,
        // and the next interactive transcribe transparently marks the runtime active again.
        await runtime.endInteractiveSession()
        try? await Task.sleep(nanoseconds: 110_000_000)
        let unloadsAfterIdle = await unloadCounter.values().count
        XCTAssertEqual(unloadsAfterIdle, 1)
        let residentAfterIdle = await runtime.isParakeetResident
        XCTAssertFalse(residentAfterIdle)

        let reloaded = await runtime.transcribeInteractive([Float](repeating: 0.2, count: 16_000))
        XCTAssertEqual(reloaded.text, "decoded-16000")
        let residentAfterReload = await runtime.isParakeetResident
        XCTAssertTrue(residentAfterReload)
    }

    func testTranscribeAudioFileResamplesStereoWAVAndM4AAtBackgroundPriorityWithTimestamps() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-trackb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("stereo48k.wav")
        let m4aURL = dir.appendingPathComponent("imported.m4a")
        try Self.writeTestStereoAudioFile(at: wavURL, durationSeconds: 4.5, m4a: false)
        try Self.writeTestStereoAudioFile(at: m4aURL, durationSeconds: 3.2, m4a: true)

        let priorities = EventLog<DecodeScheduler.Priority>()
        let sampleCounts = EventLog<Int>()
        let runtime = SpeechRuntime(
            activeEngine: .parakeet,
            idleUnloadSeconds: 600,
            chunkDecodeOverride: { samples, priority in
                await priorities.append(priority)
                await sampleCounts.append(samples.count)
                let meta = Transcriber.Metadata(
                    confidence: 0.91,
                    audioSeconds: Double(samples.count) / 16_000.0,
                    processingSeconds: 0.01,
                    tokens: [.init(text: "chunk", start: 0, end: 1.0, confidence: 0.91)]
                )
                return .success(text: "segment \(samples.count)", attempts: 1, metadata: meta)
            }
        )

        let wavChunks = try await runtime.transcribeAudioFile(at: wavURL, chunkSeconds: 2.0)
        XCTAssertGreaterThanOrEqual(wavChunks.count, 2)
        XCTAssertEqual(wavChunks.first?.startTime ?? -1, 0, accuracy: 0.01)
        for idx in 1..<wavChunks.count {
            XCTAssertGreaterThanOrEqual(wavChunks[idx].startTime, wavChunks[idx - 1].endTime - 0.01)
            XCTAssertGreaterThan(wavChunks[idx].duration, 0)
        }
        let observedPriorities = await priorities.values()
        XCTAssertTrue(observedPriorities.allSatisfy { $0 == .background },
                      "Imported file transcription must run at `.background` priority")
        let totalMonoSamples = await sampleCounts.values().reduce(0, +)
        XCTAssertEqual(Double(totalMonoSamples), 4.5 * 16_000, accuracy: 800,
                       "48kHz stereo input must convert to 16kHz mono samples without dropping frames")

        let m4aChunks = try await runtime.transcribeAudioFile(at: m4aURL, chunkSeconds: 2.0)
        XCTAssertFalse(m4aChunks.isEmpty, "Compressed `.m4a` files must decode and transcribe cleanly")
        XCTAssertEqual(m4aChunks.first?.confidence ?? 0, 0.91, accuracy: 0.001)
    }

    private static func writeTestStereoAudioFile(at url: URL, durationSeconds: Double, m4a: Bool) throws {
        let rate = 48_000.0
        let totalFrames = AVAudioFrameCount(rate * durationSeconds)
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "TrackBTest", code: 1)
        }
        buffer.frameLength = totalFrames
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for i in 0..<Int(totalFrames) {
            let t = Double(i) / rate
            // Alternate speech-like tone bursts and short quiet pauses so silence-snapped
            // chunking has natural boundaries.
            let inPause = (t > 1.85 && t < 2.15)
            let sample = inPause ? Float(0.0002) : Float(sin(2.0 * .pi * 220.0 * t) * 0.25)
            left[i] = sample
            right[i] = sample * 0.8
        }

        let settings: [String: Any]
        if m4a {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000
            ]
        } else {
            var wavSettings = pcmFormat.settings
            wavSettings[AVLinearPCMIsNonInterleaved] = false
            settings = wavSettings
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: - 3. Deterministic Permit Release & 10s Preview Cap

    private actor SimpleDecoder: StreamingSpeechDecoder {
        var samples: [Float] = []
        func reset() { samples = [] }
        func append(_ chunk: [Float]) async throws { samples += chunk }
        func partial() -> String { "p\(samples.count)" }
        func finish() -> String { "f\(samples.count)" }
    }

    func testStreamingSpeechSessionReleasesSchedulerDeterministicallyBeforeReturning() async {
        let scheduler = DecodeScheduler()
        let session = StreamingSpeechSession(decoder: SimpleDecoder(), scheduler: scheduler)

        for tick in 0..<25 {
            let upd = await session.update([1, 2, 3, 4], offset: tick * 4, generation: 1)
            XCTAssertNotNil(upd)
            let busyAfterUpdate = await session.schedulerIsBusy
            XCTAssertFalse(busyAfterUpdate,
                           "Permit must be deterministically released before `update` returns")
        }

        let finalOutcome = await session.transcribe(
            Array(repeating: 1, count: 100),
            generation: 1,
            maxAttempts: 1,
            requestID: "req-1"
        )
        XCTAssertEqual(finalOutcome.text, "f100")
        let busyAfterTranscribe = await session.schedulerIsBusy
        XCTAssertFalse(busyAfterTranscribe,
                       "Permit must be deterministically released before `transcribe` returns")
    }

    func testParakeetPreviewWindowIsCappedAtTenSeconds() {
        XCTAssertEqual(Pipeline.previewWindowSeconds, 10.0)
        XCTAssertEqual(Pipeline.previewMaxSamples, 160_000)

        let queue = DispatchQueue(label: "flowclone.test.preview-cap")
        queue.sync {
            let recorder = Recorder(queue: queue, idleDelay: 0)
            let fortySeconds = (0..<(40 * 16_000)).map(Float.init)
            recorder.preloadForTest(fortySeconds)
            let previewSlice = recorder.snapshot(lastSeconds: Pipeline.previewWindowSeconds)
            XCTAssertEqual(previewSlice.count, 160_000,
                           "Preview snapshot must cap at trailing 10s (160,000 samples), not 30s")
            XCTAssertEqual(previewSlice.first, Float(30 * 16_000))
            XCTAssertEqual(previewSlice.last, Float(40 * 16_000 - 1))
            _ = recorder.end(drainTail: false)
        }
    }

    // MARK: - 4 & 5. Key-Up Tail Drain, Warm Converter Reset & Lock-Free IOProc Idle Gate

    private func feedInterleaved(_ samples: [Float], hostTime: UInt64, into stream: DeviceInputStream) {
        var copy = samples
        copy.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(raw.count),
                    mData: raw.baseAddress
                )
            )
            var ts = AudioTimeStamp()
            ts.mHostTime = hostTime
            ts.mFlags = .hostTimeValid
            stream.handleInput(&abl, at: &ts)
        }
    }

    func testRecorderEndDrainsCoalescerPendingDeliveryQueueAndResamplerTail() throws {
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let format48k = try DeviceInputStream.captureFormat(for: asbd)

        let queue = DispatchQueue(label: "flowclone.test.tail-drain")
        let drainedSamples: [Float] = queue.sync {
            let recorder = Recorder(queue: queue, idleDelay: 30)
            guard let stream = recorder.beginSimulatedCaptureForTest(inputFormat: format48k) else {
                XCTFail("Expected simulated capture stream")
                return []
            }
            // Cycle 1+2 (1,024 frames @ 48kHz = 21.3ms): low amplitude vowel body (0.05).
            feedInterleaved([Float](repeating: 0.05, count: 512), hostTime: 1_000, into: stream)
            feedInterleaved([Float](repeating: 0.05, count: 512), hostTime: 2_000, into: stream)
            // Cycle 3 (512 frames @ 48kHz = 10.7ms < 1,024 coalescer threshold): high-amplitude
            // final `/s/` consonant (0.75) stranded in `InputCoalescer.pending` at key-up!
            feedInterleaved([Float](repeating: 0.75, count: 512), hostTime: 3_000, into: stream)

            return recorder.end(drainTail: true)
        }

        // 1,536 frames @ 48kHz -> 512 samples @ 16kHz. Without `drainAndGateIdle` +
        // `.endOfStream`, ~180 samples (including the entire 0.75 consonant tail) were lost!
        XCTAssertGreaterThanOrEqual(drainedSamples.count, 508,
                                    "Both `InputCoalescer.pending` and `AVAudioConverter` `.endOfStream` tail must flush")
        let tailPeak = drainedSamples.suffix(160).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(tailPeak, 0.55,
                             "Stranded final consonant frames in `InputCoalescer.pending` must survive `Recorder.end()`")
    }

    func testWarmRestartResetsConverterAndKeepWarmIdleGateBlocksIOProcCallbacks() throws {
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let format48k = try DeviceInputStream.captureFormat(for: asbd)
        let queue = DispatchQueue(label: "flowclone.test.warm-reset")

        queue.sync {
            let recorder = Recorder(queue: queue, idleDelay: 30)
            guard let stream = recorder.beginSimulatedCaptureForTest(inputFormat: format48k) else {
                XCTFail("Expected simulated capture stream")
                return
            }

            // Utterance 1: feed loud +0.9 DC/step audio and cancel (`drainTail: false`) so
            // polyphase FIR history remains loaded inside `AVAudioConverter` before warm restart.
            feedInterleaved([Float](repeating: 0.9, count: 1_024), hostTime: 100, into: stream)
            _ = recorder.end(drainTail: false)
            XCTAssertTrue(stream.isIdlePaused, "Ending capture must engage the lock-free IOProc idle gate")

            // Simulate 200 keep-warm 47Hz IOProc callbacks while idle: all must return in O(1)
            // without queuing onto `deliveryQueue` or retaining samples.
            for cycle in 0..<200 {
                feedInterleaved([Float](repeating: 0.8, count: 512), hostTime: UInt64(1_000 + cycle), into: stream)
            }

            // Utterance 2 (warm restart): `converter?.reset()` + `resumeFromWarmIdle()` must
            // prevent any +0.9 resampler filter bleed and any keep-warm frames from leaking in.
            XCTAssertTrue(recorder.resumeSimulatedCaptureForTest())
            XCTAssertFalse(stream.isIdlePaused)
            feedInterleaved([Float](repeating: 0.0, count: 2_048), hostTime: 5_000, into: stream)
            let secondUtterance = recorder.end(drainTail: true)
            XCTAssertFalse(secondUtterance.isEmpty)
            let maxBleed = secondUtterance.map { abs($0) }.max() ?? 1.0
            XCTAssertEqual(maxBleed, 0.0, accuracy: 1e-7,
                           "Warm `converter?.reset()` must eliminate cross-utterance FIR resampler bleed")
        }
    }

    // MARK: - 6 & 7. SpeechGate -26 dBFS Ceiling & Non-Sealing SampleStorage.samples(in:)

    func testSpeechGateMinus26dBFSCeilingCompactsPausesInNoisyMinus35dBFSRoom() {
        XCTAssertEqual(SpeechGate.maxNoiseFloorDB, -26)

        // Build: 0.6s spoken phrase (-15 dBFS) + 2.4s noisy room pause (-35 dBFS) + 0.6s spoken phrase (-15 dBFS)
        func toneOrRoom(seconds: Double, rmsTarget: Float, seedOffset: UInt64) -> [Float] {
            var state: UInt64 = 98_765 &+ seedOffset
            let amp = rmsTarget * sqrt(3.0) // uniform [-amp, +amp] has RMS = amp / sqrt(3)
            return (0..<Int(16_000 * seconds)).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return (Float(state >> 40) / Float(1 << 24) - 0.5) * 2 * amp
            }
        }

        let room35dBFS = pow(10.0, Float(-35.0) / 20.0)   // ~0.0178 RMS
        let voice15dBFS = pow(10.0, Float(-15.0) / 20.0)  // ~0.1778 RMS

        let pureRoom = toneOrRoom(seconds: 2.0, rmsTarget: room35dBFS, seedOffset: 1)
        XCTAssertFalse(SpeechGate.containsSpeech(pureRoom),
                       "-35 dBFS ambient room / USB mic floor must be recognized as silence")
        XCTAssertFalse(SpeechGate.hasRecentSpeech(Array(pureRoom.suffix(16_000))))

        let utteranceWithNoisyPause =
            toneOrRoom(seconds: 0.6, rmsTarget: voice15dBFS, seedOffset: 2) +
            toneOrRoom(seconds: 2.4, rmsTarget: room35dBFS, seedOffset: 3) +
            toneOrRoom(seconds: 0.6, rmsTarget: voice15dBFS, seedOffset: 4)
        XCTAssertTrue(SpeechGate.containsSpeech(utteranceWithNoisyPause))

        let compacted = PauseCompactor.compact(utteranceWithNoisyPause, maxPause: 0.5)
        XCTAssertGreaterThan(compacted.removedSeconds, 1.5,
                             "2.4s pause at -35 dBFS must be compacted once noise-floor clamp is -26 dBFS")
        XCTAssertEqual(compacted.pausesShortened, 1)
    }

    func testSampleStorageSamplesInRangeCopiesActiveWithoutSealingEvery160msTick() {
        var storage = Recorder.SampleStorage()
        var cursor = 0
        var streamed: [Float] = []

        // 20 ticks of 2,560 samples (160ms @ 16kHz) = 51,200 total samples (3 full 16,000 chunks + 3,200 active)
        for tick in 0..<20 {
            let base = tick * 2_560
            let chunk = (base..<(base + 2_560)).map(Float.init)
            storage.append(chunk)
            let slice = storage.samples(in: cursor..<storage.count)
            XCTAssertEqual(slice, chunk)
            streamed.append(contentsOf: slice)
            cursor = storage.count
        }

        XCTAssertEqual(storage.count, 51_200)
        XCTAssertEqual(storage.sealedChunkCount, 3,
                       "`samples(in:)` must NOT call `sealActive()` on every 160ms streaming tick")
        XCTAssertEqual(storage.activeCount, 3_200)
        XCTAssertEqual(streamed, (0..<51_200).map(Float.init))
        // Cross-boundary slice spanning sealed chunk 2 and `active[0..<3200]`
        XCTAssertEqual(storage.samples(in: 47_500..<49_000), (47_500..<49_000).map(Float.init))
    }

    // MARK: - 8. Pipeline: Prime Wait, Cold Double-Tap, Chord Debounce & Utterance N+1 Overlap

    func testWaitedForPrimeDoesNotFalseAbortFastFormatPrimeOrHeldPress() {
        XCTAssertFalse(Pipeline.shouldAbortForPrimeWait(
            waitedForPrime: true, primeWaitMS: 2.1, keyReleased: true
        ), "A ~2ms `prepareDeviceFormat()` call must never trigger an early-release abort")
        XCTAssertFalse(Pipeline.shouldAbortForPrimeWait(
            waitedForPrime: true, primeWaitMS: 180.0, keyReleased: false
        ), "A slow prime while the user is still holding the hotkey must proceed to recording")
        XCTAssertFalse(Pipeline.shouldAbortForPrimeWait(
            waitedForPrime: true, primeWaitMS: 200.0, keyReleased: true, handsFree: true
        ), "A latched hands-free session must not abort on prime wait")
        XCTAssertTrue(Pipeline.shouldAbortForPrimeWait(
            waitedForPrime: true, primeWaitMS: 120.0, keyReleased: true, handsFree: false
        ), "A genuinely blocked (>80ms) prime where key release is confirmed must require a fresh press")
    }

    func testColdDoubleTapWhileWarmingLatchesHandsFreeInsteadOfDroppingSecondTap() {
        let runtime = SpeechRuntime(chunkDecodeOverride: { _, _ in .success(text: "ok", attempts: 1) })
        let pipeline = Pipeline(runtime: runtime)
        pipeline.suppressOverlayForTest = true
        pipeline.suppressNotificationsForTest = true
        pipeline.suppressPersistenceForTest = true
        pipeline.setReadyForTest(true)
        pipeline.startCueHandler = {}
        pipeline.processingCueHandler = {}
        pipeline.mediaPauseBeganHandler = {}
        pipeline.mediaPauseEndedHandler = {}

        let openCompletionBox = LockedBox<(@Sendable (Bool) -> Void)?>(nil)
        let capUpdates = LockedBox<[Double]>([])
        let armedCount = LockedBox<Int>(0)
        let micOpened = expectation(description: "cold mic open requested")

        pipeline.armTapObserverForTest = {
            armedCount.withValue { $0 += 1 }
        }
        pipeline.primeOverrideForTest = { done in
            pipeline.queue.async { done(true, true) } // fast ~1ms prime (`waitedForPrime == true`!)
        }
        pipeline.beginCaptureOverrideForTest = { cap, _, done in
            capUpdates.withValue { $0.append(cap) }
            openCompletionBox.withValue { $0 = done }
            micOpened.fulfill()
        }
        pipeline.updateCapOverrideForTest = { cap in
            capUpdates.withValue { $0.append(cap) }
        }
        pipeline.endCaptureOverrideForTest = { _ in [] }

        // Tap 1 `.down("fn")` starts cold open; fast prime (`<80ms`) must NOT false-abort!
        pipeline.queue.async { pipeline.handle(.down("fn")) }
        wait(for: [micOpened], timeout: 1.0)
        XCTAssertTrue(pipeline.sessionStateForTest.isWarming)

        // While `AudioDeviceStart` is still blocked in `.warming`, user finishes Tap 1 (`.up`)
        // and immediately double-taps (`.down("fn")` + `.latched`).
        let latchedReady = expectation(description: "cold double-tap latched into hands-free")
        pipeline.queue.async {
            pipeline.handle(.up)
            pipeline.handle(.down("fn"))
            pipeline.handle(.latched)
            latchedReady.fulfill()
        }
        wait(for: [latchedReady], timeout: 1.0)

        XCTAssertEqual(armedCount.value, 1, "Tap 1 `.up` during `isWarming` must arm hands-free")
        XCTAssertTrue(pipeline.sessionStateForTest.isWarming)
        XCTAssertTrue(pipeline.sessionStateForTest.handsFree)
        XCTAssertFalse(pipeline.sessionStateForTest.pendingRelease)
        XCTAssertEqual(capUpdates.value, [Recorder.maxSeconds, Recorder.handsFreeMaxSeconds])

        // Now cold `AudioDeviceStart` completes (~450ms later): session must enter hands-free
        // `.recording` instead of immediately finishing from Tap 1's old `pendingRelease`!
        let recordingStarted = expectation(description: "hands-free recording live")
        openCompletionBox.value?(true)
        pipeline.queue.async { recordingStarted.fulfill() }
        wait(for: [recordingStarted], timeout: 1.0)

        let state = pipeline.sessionStateForTest
        XCTAssertTrue(state.isRecording, "Cold double-tap must transition into active hands-free recording")
        XCTAssertTrue(state.handsFree)

        let cleanedUp = expectation(description: "cleanup")
        pipeline.queue.async {
            pipeline.handle(.cancel("test done"))
            cleanedUp.fulfill()
        }
        wait(for: [cleanedUp], timeout: 1.0)
    }

    func testMultiModifierChordDebouncesStartCueAndMediaPauseOnWindowSnapCancel() {
        let runtime = SpeechRuntime(chunkDecodeOverride: { _, _ in .success(text: "ok", attempts: 1) })
        let pipeline = Pipeline(runtime: runtime)
        pipeline.suppressOverlayForTest = true
        pipeline.suppressNotificationsForTest = true
        pipeline.suppressPersistenceForTest = true
        pipeline.setReadyForTest(true)

        let startCues = LockedBox<Int>(0)
        let mediaPauses = LockedBox<Int>(0)
        let mediaResumes = LockedBox<Int>(0)
        pipeline.startCueHandler = { startCues.withValue { $0 += 1 } }
        pipeline.mediaPauseBeganHandler = { mediaPauses.withValue { $0 += 1 } }
        pipeline.mediaPauseEndedHandler = { mediaResumes.withValue { $0 += 1 } }
        pipeline.primeOverrideForTest = { done in pipeline.queue.async { done(true, false) } }
        pipeline.beginCaptureOverrideForTest = { _, _, done in pipeline.queue.async { done(true) } }
        pipeline.endCaptureOverrideForTest = { _ in [] }

        // 1) `Ctrl+Opt+Left` window snap: `ctrl+opt` opens warm mic in ~1ms, then cancels at 35ms (<110ms).
        let snapCancelled = expectation(description: "ctrl+opt+left cancelled before 110ms")
        pipeline.queue.async {
            pipeline.handle(.down("ctrl+opt"))
        }
        pipeline.queue.asyncAfter(deadline: .now() + 0.035) {
            pipeline.handle(.cancel("key pressed while held"))
            snapCancelled.fulfill()
        }
        wait(for: [snapCancelled], timeout: 1.0)

        // Wait past the 110ms window to confirm cancelled work item never fires.
        let postWindowCheck = expectation(description: "post-debounce verification")
        pipeline.queue.asyncAfter(deadline: .now() + 0.10) { postWindowCheck.fulfill() }
        wait(for: [postWindowCheck], timeout: 1.0)
        XCTAssertEqual(startCues.value, 0, "`Ctrl+Opt+Left` must not play StartCue")
        XCTAssertEqual(mediaPauses.value, 0, "`Ctrl+Opt+Left` must not pause Spotify/Apple Music")
        XCTAssertEqual(mediaResumes.value, 0)

        // 2) Deliberate `Ctrl+Opt` hold (>110ms): both StartCue and MediaPause engage after debounce.
        let heldPastDebounce = expectation(description: "deliberate ctrl+opt hold")
        pipeline.queue.async { pipeline.handle(.down("ctrl+opt")) }
        pipeline.queue.asyncAfter(deadline: .now() + 0.145) {
            pipeline.handle(.cancel("done"))
            heldPastDebounce.fulfill()
        }
        wait(for: [heldPastDebounce], timeout: 1.0)
        XCTAssertEqual(startCues.value, 1)
        XCTAssertEqual(mediaPauses.value, 1)
        XCTAssertEqual(mediaResumes.value, 1)

        // 3) Bare `fn` triggers StartCue and MediaPause immediately without waiting 110ms.
        let fnImmediate = expectation(description: "bare fn immediate")
        pipeline.queue.async { pipeline.handle(.down("fn")) }
        pipeline.queue.asyncAfter(deadline: .now() + 0.025) {
            XCTAssertEqual(startCues.value, 2)
            XCTAssertEqual(mediaPauses.value, 2)
            pipeline.handle(.cancel("done"))
            fnImmediate.fulfill()
        }
        wait(for: [fnImmediate], timeout: 1.0)
    }

    func testBackToBackUtteranceOverlapRecordsDuringTranscriptionAndDeliversFIFO() {
        let previousOverride = Mode.testOverride
        Mode.testOverride = .raw
        defer { Mode.testOverride = previousOverride }

        let roomPad = [Float](repeating: 0.0005, count: 2_400)
        let speech1 = roomPad + (0..<6_400).map { Float(sin(Double($0) * 0.2)) * 0.25 } + roomPad
        let speech2 = roomPad + (0..<8_000).map { Float(sin(Double($0) * 0.25)) * 0.25 } + roomPad

        let runtime = SpeechRuntime(chunkDecodeOverride: { samples, _ in
            try? await Task.sleep(nanoseconds: 40_000_000)
            let text = samples.count == speech1.count ? "First sentence." : "Second sentence."
            return .success(text: text, attempts: 1)
        })
        let pipeline = Pipeline(runtime: runtime)
        pipeline.suppressOverlayForTest = true
        pipeline.suppressNotificationsForTest = true
        pipeline.suppressPersistenceForTest = true
        pipeline.setReadyForTest(true)
        pipeline.startCueHandler = {}
        pipeline.processingCueHandler = {}
        pipeline.mediaPauseBeganHandler = {}
        pipeline.mediaPauseEndedHandler = {}
        pipeline.primeOverrideForTest = { done in pipeline.queue.async { done(true, false) } }
        pipeline.beginCaptureOverrideForTest = { _, _, done in pipeline.queue.async { done(true) } }
        pipeline.resolveTargetOverrideForTest = { _, done in done(nil) }

        let captureIndex = LockedBox<Int>(0)
        pipeline.endCaptureOverrideForTest = { _ in
            let idx = captureIndex.withValue { val -> Int in
                val += 1
                return val
            }
            return idx == 1 ? speech1 : speech2
        }

        let pasted = LockedBox<[String]>([])
        let firstPasteEntered = expectation(description: "Utterance 1 entered ASR/paste")
        let bothDelivered = expectation(description: "Both utterances delivered in FIFO order")
        let releaseFirstPaste = LockedBox<(@Sendable () -> Void)?>(nil)

        pipeline.pasteOverrideForTest = { text, finishPaste in
            pasted.withValue { $0.append(text) }
            if text == "First sentence." {
                releaseFirstPaste.withValue { $0 = finishPaste }
                firstPasteEntered.fulfill()
            } else {
                finishPaste()
                bothDelivered.fulfill()
            }
        }

        // Start & release Utterance 1; wait until Utterance 1 is mid-delivery (`session.transcribing == true`).
        pipeline.queue.async {
            pipeline.handle(.down("fn"))
        }
        pipeline.queue.asyncAfter(deadline: .now() + 0.02) {
            pipeline.handle(.up)
        }
        wait(for: [firstPasteEntered], timeout: 2.0)
        XCTAssertTrue(pipeline.sessionStateForTest.transcribing)

        // While Utterance 1 is still delivering, press & release Utterance 2 (`Utterance N+1` overlap!).
        let u2RecordedAndQueued = expectation(description: "Utterance 2 recorded & queued during Utterance 1 delivery")
        pipeline.queue.async {
            pipeline.handle(.down("fn"))
        }
        pipeline.queue.asyncAfter(deadline: .now() + 0.02) {
            XCTAssertTrue(pipeline.sessionStateForTest.isRecording,
                          "Hotkey `.down` during `session.transcribing` must start recording Utterance N+1 immediately")
            XCTAssertTrue(pipeline.sessionStateForTest.transcribing)
            pipeline.handle(.up)
            u2RecordedAndQueued.fulfill()
        }
        wait(for: [u2RecordedAndQueued], timeout: 1.0)

        // Utterance 2 must NOT paste ahead of Utterance 1 while Utterance 1 is still finishing paste.
        XCTAssertEqual(pasted.value, ["First sentence."])
        XCTAssertEqual(pipeline.sessionStateForTest.deliveringGenerations.count, 2)

        // Complete Utterance 1's paste -> Utterance 2 automatically drains and pastes second!
        releaseFirstPaste.value?()
        wait(for: [bothDelivered], timeout: 2.0)

        XCTAssertEqual(pasted.value, ["First sentence.", "Second sentence."])
        let idleSettled = expectation(description: "pipeline idle")
        pipeline.queue.async { idleSettled.fulfill() }
        wait(for: [idleSettled], timeout: 1.0)
        XCTAssertFalse(pipeline.sessionStateForTest.isBusy)
    }

    // MARK: - 9. Sidecar SIGKILL Escalation & Clean Shutdown

    func testSidecarTerminateAndReapEscalatesToSIGKILLWhenProcessIgnoresSIGTERM() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Child traps and ignores SIGTERM, then sleeps; only SIGKILL escalation can reap it promptly.
        proc.arguments = ["-c", "trap '' TERM; echo ready; sleep 60"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        // Wait until the shell has installed the `trap '' TERM` handler (`echo ready`).
        let readyByte = outPipe.fileHandleForReading.readData(ofLength: 5)
        XCTAssertEqual(String(data: readyByte, encoding: .utf8), "ready")
        XCTAssertTrue(proc.isRunning)

        let t0 = DispatchTime.now()
        Sidecar.terminateAndReap(proc, gracePeriod: 0.12)
        let elapsedMS = ms(t0, .now())

        XCTAssertFalse(proc.isRunning, "Stubborn child process must be killed and reaped")
        XCTAssertLessThan(elapsedMS, 1_500, "SIGKILL escalation must bound teardown latency")

        // Verify `Sidecar.shared.shutdown()` is safe and idempotent when no sidecar is running.
        Sidecar.shared.shutdown()
    }
}
