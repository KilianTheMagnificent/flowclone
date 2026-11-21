// Mic capture. The input starts on demand and stays open for a bounded window after
// recording (instant consecutive dictations, privacy indicator off afterward).
// Capture reads the chosen device directly (`DeviceInputStream`), never through
// AVAudioEngine, whose input follows the system default mic: with a Bluetooth headset as
// that default, it put the headset into call mode while FlowClone sat idle.
// Public methods are called only from the session queue; `append` runs on the tap thread.
// Locks guard state shared between the session queue and tap thread.
import Accelerate
@preconcurrency import AVFoundation
import CoreAudio

/// Lock-protected by `Recorder.lock`. Recovery work carries one of these generations
/// across the device queue instead of rediscovering whichever capture is current later.
struct RecorderCaptureOwnership {
    private(set) var generation = 0
    private(set) var isCapturing = false

    mutating func begin() -> Int {
        generation &+= 1
        isCapturing = false
        return generation
    }

    mutating func activate(_ owner: Int) -> Bool {
        guard owner == generation else { return false }
        isCapturing = true
        return true
    }

    func ownsActiveCapture(_ owner: Int) -> Bool {
        isCapturing && owner == generation
    }

    var activeOwner: Int? { isCapturing ? generation : nil }

    mutating func end() {
        isCapturing = false
        generation &+= 1
    }

    /// An open failure may deactivate only the begin that initiated it. Unlike `end`,
    /// this leaves the token intact for the already-tagged completion on the session queue.
    mutating func cancelOpening(_ owner: Int) -> Bool {
        guard owner == generation else { return false }
        isCapturing = false
        return true
    }

    /// Claims the samples for a route failure and invalidates all remaining work for it.
    mutating func claimFailure(_ owner: Int) -> Bool {
        guard ownsActiveCapture(owner) else { return false }
        isCapturing = false
        generation &+= 1
        return true
    }
}

/// A successful device start does not prove that the route supplies audio. Reopen
/// it once before excluding the device, especially when it is the only local
/// microphone available with the laptop lid closed.
struct RecorderRouteRecovery {
    enum Action: Equatable { case rebuildCurrent, nextDevice }
    private var rebuiltDevices: Set<AudioDeviceID> = []

    mutating func nextAction(for device: AudioDeviceID?) -> Action {
        guard let device else { return .nextDevice }
        return rebuiltDevices.insert(device).inserted ? .rebuildCurrent : .nextDevice
    }
}

final class Recorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let maxSeconds = 60.0
    /// Raised 3s → 30s on 2026-09-06: a cold open of the Studio Display USB mic costs ~450ms
    /// per press, so back-to-back dictations pay it every time and the start cue lands late.
    /// Warm presses go live in ~6ms. Cost: the mic indicator stays lit for 30s after a dictation.
    static let idleKeepWarmSeconds = 30.0
    /// F1: a latched hands-free session gets a longer leash — same overflow contract,
    /// just further out. Chosen per session by `begin(capSeconds:)`, never persisted.
    static let handsFreeMaxSeconds = 300.0
    /// Bounded key-up drain budget so `InputCoalescer.pending`, `deliveryQueue`, and
    /// `AVAudioConverter` resampler tail frames flush before `captureOwnership.end()`.
    static let tailDrainTimeout: TimeInterval = 0.032

    /// Completed chunks are immutable. A live snapshot only shares their references and
    /// copies trailing slices directly from `active` on streaming/preview ticks, so the next
    /// audio callback never has to copy the whole growing utterance or fragment chunks.
    struct SampleStorage {
        static let chunkCapacity = 16_000

        private var sealed: [[Float]] = []
        private var active: [Float] = []
        private(set) var count = 0

        var sealedChunkCount: Int { sealed.count }
        var activeCount: Int { active.count }

        init() {
            active.reserveCapacity(Self.chunkCapacity)
        }

        mutating func clear() {
            sealed.removeAll(keepingCapacity: true)
            active = []
            active.reserveCapacity(Self.chunkCapacity)
            count = 0
        }

        mutating func append(_ values: UnsafeBufferPointer<Float>) {
            var offset = 0
            while offset < values.count {
                let available = Self.chunkCapacity - active.count
                let amount = min(available, values.count - offset)
                active.append(contentsOf: UnsafeBufferPointer(
                    start: values.baseAddress?.advanced(by: offset), count: amount
                ))
                count += amount
                offset += amount
                if active.count == Self.chunkCapacity { sealActive() }
            }
        }

        mutating func append(_ values: [Float]) {
            values.withUnsafeBufferPointer { append($0) }
        }

        /// Copies `range` across `sealed` chunks and `active[0..<activeCount]` without
        /// calling `sealActive()`, so 160ms Nemotron streaming ticks and 1s preview ticks
        /// never fragment `sealed` into sub-capacity arrays.
        func samples(in range: Range<Int>) -> [Float] {
            let lower = max(0, min(range.lowerBound, count))
            let upper = max(lower, min(range.upperBound, count))
            let needed = upper - lower
            guard needed > 0 else { return [] }

            var result: [Float] = []
            result.reserveCapacity(needed)

            var chunkStart = 0
            for chunk in sealed {
                let chunkEnd = chunkStart + chunk.count
                if chunkEnd > lower, chunkStart < upper {
                    let s = max(0, lower - chunkStart)
                    let e = min(chunk.count, upper - chunkStart)
                    if s < e {
                        result.append(contentsOf: chunk[s..<e])
                    }
                }
                chunkStart = chunkEnd
                if chunkStart >= upper {
                    return result
                }
            }

            let activeCount = active.count
            if activeCount > 0, chunkStart < upper {
                let s = max(0, lower - chunkStart)
                let e = min(activeCount, upper - chunkStart)
                if s < e {
                    result.append(contentsOf: active[s..<e])
                }
            }
            return result
        }

        /// Returns immutable chunks while retaining ownership for continued capture.
        /// Only the outer array is shared; future COW copies references, not PCM data.
        mutating func snapshotChunks() -> ([[Float]], Int) {
            sealActive()
            return (sealed, count)
        }

        /// The trailing `lastSamples`, rounded up to whole sealed chunks. Snapping to a
        /// chunk boundary keeps this a share of the same immutable references rather than
        /// a fresh copy of a window into the growing utterance.
        mutating func snapshotChunks(lastSamples: Int) -> ([[Float]], Int) {
            sealActive()
            guard lastSamples < count else { return (sealed, count) }
            var kept = 0
            var first = sealed.count
            while first > 0, kept < lastSamples {
                first -= 1
                kept += sealed[first].count
            }
            return (Array(sealed[first...]), kept)
        }

        /// Moves ownership out of the recorder. This intentionally replaces both arrays
        /// so a finished hands-free session cannot retain its multi-minute capacity.
        mutating func takeChunks() -> ([[Float]], Int) {
            sealActive()
            let result = (sealed, count)
            sealed = []
            active = []
            active.reserveCapacity(Self.chunkCapacity)
            count = 0
            return result
        }

        mutating func replace(with values: [Float]) {
            clear()
            append(values)
        }

        /// Removes only the failed route's tail while retaining immutable prefix chunks.
        mutating func truncate(to requestedCount: Int) {
            let targetCount = max(0, min(requestedCount, count))
            guard targetCount < count else { return }

            var remaining = targetCount
            var kept: [[Float]] = []
            kept.reserveCapacity(min(sealed.count, targetCount / Self.chunkCapacity + 1))
            var newActive: [Float] = []

            for chunk in sealed {
                if remaining >= chunk.count {
                    kept.append(chunk)
                    remaining -= chunk.count
                } else {
                    if remaining > 0 { newActive = Array(chunk.prefix(remaining)) }
                    remaining = 0
                    break
                }
            }
            if remaining > 0 {
                newActive = Array(active.prefix(remaining))
            }

            sealed = kept
            active = newActive
            if active.count == Self.chunkCapacity { sealActive() }
            if active.capacity < Self.chunkCapacity {
                active.reserveCapacity(Self.chunkCapacity)
            }
            count = targetCount
        }

        static func flatten(_ chunks: [[Float]], count: Int) -> [Float] {
            guard count > 0 else { return [] }
            var result: [Float] = []
            result.reserveCapacity(count)
            for chunk in chunks { result.append(contentsOf: chunk) }
            return result
        }

        private mutating func sealActive() {
            guard !active.isEmpty else { return }
            sealed.append(active)
            active = []
            active.reserveCapacity(Self.chunkCapacity)
        }
    }

    /// AVAudioConverter may invoke its input block more than once. Keep the one-shot feed
    /// decision behind a lock instead of mutating a captured local from a Sendable callback.
    private final class ConverterInput: @unchecked Sendable {
        private let lock = NSLock()
        private let buffer: AVAudioPCMBuffer
        private var consumed = false

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard !consumed else {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
    }

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate, channels: 1, interleaved: false)!
    /// Device queue. The one open input, from creation until `teardown`.
    private var input: DeviceInputStream?
    /// Fences change notifications from an input that has since been replaced.
    private var inputRevision = 0
    private let queue: DispatchQueue
    private let idleDelay: TimeInterval?
    /// Owns EVERY HAL mutation: catalog reads, format reads, converter creation, IO proc
    /// create/destroy, start/stop. None of those is bounded — a device start once blocked
    /// 22s on a Continuity route — and the
    /// session queue behind them is the one that delivers the next hotkey edge.
    private let deviceQueue = DispatchQueue(label: "com.andre.flowclone.mic-device",
                                            qos: .userInitiated)
    private let primeLock = NSLock()
    private var primeInProgress = false
    private var primeReady = false
    private var primeWaiters: [@Sendable (Bool, Bool) -> Void] = []

    // Session queue: the watchdog and idle timers, which schedule work but touch no device.
    private var idleStop: DispatchWorkItem?
    private var healthWork: DispatchWorkItem?
    private var configurationWork: DispatchWorkItem?
    private var healthEpoch = 0

    // Device queue: everything that describes the route the input is bound to.
    private var idlePaused = false
    private var activeDevice: AudioInputDevice?
    private var failedDeviceIDs: Set<AudioDeviceID> = []
    private var healthRecoveryCount = 0
    private var healthRecoveryLimit = 1
    private var routeRestartCount = 0
    private var routeRestartLimit = 4
    private var inputMuteReported = false
    private var routeRecovery = RecorderRouteRecovery()
    private var awaitingRecoveredSignal = false
    private let routeTopologyDirty = LockFreeBool(false)
    private let topologyListenerQueue = DispatchQueue(label: "com.andre.flowclone.mic-topology", qos: .utility)
    private var topologyListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    /// Set with `converter` for a multi-channel input; guarded by `lock`.
    private var channelMixer: InputChannelMixer?
    private var outBuf: AVAudioPCMBuffer?
    private var activeStream: DeviceInputStream?
    private var sampleStorage = SampleStorage()
    private var tapCallbacks: UInt64 = 0
    private var captureRequestedAt: DispatchTime?
    private var captureRequestID: String?
    private var captureOwnership = RecorderCaptureOwnership()
    private var overflowed = false
    private var capSamples = Int(sampleRate * maxSeconds)
    private var routeGeneration = 0
    private var routeSampleStart = 0
    private var routeFrames = 0
    private var routePeak: Float = 0
    /// Lock-protected copy of `activeDevice?.isWireless` for the session-queue idle timer.
    private var routeIsWireless = false
    /// Called on the session queue when a recording hits its length cap, with that cap
    /// in seconds — 60 for a held press, 300 for a hands-free session (F1).
    var onOverflow: (@Sendable (Double) -> Void)?

    /// Called on the session queue if a running input delivers no signal and no
    /// alternate device can recover the capture.
    var onInputFailure: (@Sendable ([Float], String) -> Void)?

    /// Called once per muted interval so the UI can explain valid zeroed samples.
    var onInputMuted: (@Sendable () -> Void)?

    var onDevice: (@Sendable (String) -> Void)?
    /// One callback per buffer: responsive level, an optional 150ms Classic average and the
    /// voice's loudness above the room (Settle). The UI chooses without enqueuing two main-thread updates.
    var onLevels: (@Sendable (_ responsive: Float, _ classic: Float?, _ voice: Float) -> Void)?
    private var responsiveMeter = ResponsiveInputMeter()
    /// Display-only; guarded by `lock` with the converter it follows.
    private var voiceGate = VoiceGate(sampleRate: Recorder.sampleRate)
    private let levelLock = NSLock()
    private var levelFloorDB: Float = 0             // per session; adapts down to -60dB
    private var levelTotal: Float = 0
    private var levelSamples = 0
    private var levelWindowStartedAt = DispatchTime.now()

    init(queue: DispatchQueue, idleDelay: TimeInterval? = nil) {
        self.queue = queue
        self.idleDelay = idleDelay
    }

    deinit {
        removeTopologyListeners()
    }

    private func installTopologyListenersIfNeeded() {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        guard topologyListeners.isEmpty, !handsfreeSession else { return }
        let dirtyFlag = routeTopologyDirty
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                dirtyFlag.store(true)
            }
            if AudioObjectAddPropertyListenerBlock(systemObject, &address, topologyListenerQueue, block) == noErr {
                topologyListeners.append((address, block))
            }
        }
    }

    private func removeTopologyListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for (address, block) in topologyListeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(systemObject, &mutableAddress, topologyListenerQueue, block)
        }
        topologyListeners.removeAll()
    }

    private var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureOwnership.isCapturing
    }

    private func ownsActiveCapture(_ owner: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureOwnership.ownsActiveCapture(owner)
    }

    /// The staged route is already installed when this runs. The precheck prevents a
    /// known-stale recovery from entering a blocking device start; the postcheck catches
    /// release/cancel while that call is blocked and tears down the route it just started.
    static func fencedEngineStart(isOwned: () -> Bool,
                                  start: () -> Bool,
                                  tearDown: () -> Void) -> Bool {
        guard isOwned() else {
            tearDown()
            return false
        }
        let started = start()
        guard started, isOwned() else {
            tearDown()
            return false
        }
        return true
    }

    // MARK: - Session queue

    /// Settles the route a press will open, away from the hotkey state-machine queue.
    /// Completions are serialized back onto that queue. Nothing is opened or started.
    /// Completion receives `(ready, waitedForPrime)`. A real dictation that had to
    /// wait must require a fresh press: audio spoken during that wait was not captured.
    func primeAsync(_ completion: (@Sendable (Bool, Bool) -> Void)? = nil) {
        primeLock.lock()
        if primeReady {
            primeLock.unlock()
            if let completion { queue.async { completion(true, false) } }
            return
        }
        if let completion { primeWaiters.append(completion) }
        guard !primeInProgress else {
            primeLock.unlock()
            return
        }
        primeInProgress = true
        primeLock.unlock()

        deviceQueue.async { [weak self] in
            guard let self else { return }
            let ok = self.primeHardware()
            self.primeLock.lock()
            self.primeReady = ok
            self.primeInProgress = false
            let waiters = self.primeWaiters
            self.primeWaiters.removeAll()
            self.primeLock.unlock()
            for waiter in waiters {
                self.queue.async { waiter(ok, true) }
            }
        }
    }

    private func primeHardware() -> Bool {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        if handsfreeSession { Handsfree.log("blocked microphone prime"); return false }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return false
        }
        let started = DispatchTime.now()
        let catalog = AudioInputRouter.catalog()
        var excluded: Set<AudioDeviceID> = []
        while let device = AudioInputRouter.preferredDevice(in: catalog, excluding: excluded) {
            // A Bluetooth mic is not even read ahead of a press: touching a headset's input
            // can switch it to its call profile and change what it is playing.
            if device.isWireless {
                log("mic route primed — \(device.name) [\(device.transportName)] " +
                    "stays closed until a press needs it")
                return true
            }
            do {
                let fmt = try DeviceInputStream.inputFormat(of: device.id)
                log(String(format: "mic route primed — %@ [%@] %.0fHz %dch in %.0fms",
                           device.name, device.transportName,
                           fmt.sampleRate, fmt.channelCount, ms(started, .now())))
                return true
            } catch {
                log("mic route prime rejected \(device.name) — \(error)")
                excluded.insert(device.id)
            }
        }
        log("mic route prime skipped — no usable input")
        return false
    }

    private func markPrimeReady() {
        primeLock.lock()
        primeReady = true
        primeLock.unlock()
    }

    /// Opens the mic for one utterance. `capSeconds` is the per-session overflow cap
    /// (F1: 60s held, 300s hands-free) — in-process only, so a test that injects a short
    /// cap can never leave the shipping app short-capped (R-3).
    ///
    /// Only the cheap bookkeeping runs here; the unbounded HAL open runs on the
    /// device queue and `completion(opened)` comes back on the session queue, which stays
    /// free to deliver the release or the Esc that arrives during it.
    func begin(capSeconds: Double = maxSeconds, requestID: String? = nil,
               completion: @escaping @Sendable (Bool) -> Void) {
        idleStop?.cancel()
        healthWork?.cancel()
        healthEpoch &+= 1
        levelLock.lock()
        responsiveMeter = ResponsiveInputMeter()
        levelFloorDB = 0        // per session: one quiet buffer must not pin the waveform
        levelTotal = 0
        levelSamples = 0
        levelWindowStartedAt = .now()
        levelLock.unlock()
        lock.lock()
        sampleStorage.clear()
        voiceGate = VoiceGate(sampleRate: Self.sampleRate)
        captureRequestedAt = .now()
        captureRequestID = requestID
        capSamples = Int(Self.sampleRate * capSeconds)
        overflowed = false
        let generation = captureOwnership.begin()
        lock.unlock()

        deviceQueue.async { [weak self] in
            guard let self else { return }
            let opened = self.openInput(generation)
            self.queue.async { completion(opened) }
        }
    }

    /// Pure policy helper: warm running input can skip a full HAL catalog + IOKit lid scan when
    /// it is still running, not idle-paused, hardware topology hasn't changed, and the user's
    /// preferred microphone hasn't changed away from it.
    static func canFastReuseWarmInput(
        idlePaused: Bool,
        isRunning: Bool,
        inputDeviceID: AudioDeviceID?,
        activeDevice: AudioInputDevice?,
        topologyDirty: Bool,
        preferredUID: String?
    ) -> Bool {
        guard !idlePaused,
              isRunning,
              let inputDeviceID,
              let activeDevice,
              activeDevice.id == inputDeviceID,
              !topologyDirty else {
            return false
        }
        if let preferredUID, preferredUID != activeDevice.uid {
            return false
        }
        return true
    }

    /// Device queue: the whole open for one `begin`. Short-circuits when a healthy warm input
    /// is already running (avoiding Core Audio catalog + IOKit lid sensor scans on back-to-back
    /// dictations), and falls back to full route resolution whenever paused, cold, or changed.
    private func openInput(_ generation: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        if handsfreeSession { Handsfree.log("blocked microphone capture"); return false }
        defer { if let activeDevice { onDevice?(activeDevice.name) } }
        failedDeviceIDs.removeAll()
        routeRecovery = RecorderRouteRecovery()
        awaitingRecoveredSignal = false
        healthRecoveryCount = 0
        routeRestartCount = 0
        inputMuteReported = false

        if let input,
           Self.canFastReuseWarmInput(
               idlePaused: idlePaused,
               isRunning: input.isRunning,
               inputDeviceID: input.device,
               activeDevice: activeDevice,
               topologyDirty: routeTopologyDirty.load(),
               preferredUID: MicrophonePreferences.preferredUID
           ) {
            healthRecoveryLimit = max(2, healthRecoveryLimit)
            routeRestartLimit = max(4, routeRestartLimit)
            guard beginCapturing(generation) else { return false }
            resetConverterForWarmStart()
            input.resumeFromWarmIdle()
            armHealthWatchdog(resetHealthForWarmRoute())
            return true
        }

        let catalog = AudioInputRouter.catalog()
        routeTopologyDirty.store(false)
        let usableDeviceCount = catalog.devices.filter(\.isUsable).count
        healthRecoveryLimit = max(2, usableDeviceCount * 2)
        routeRestartLimit = max(4, usableDeviceCount * 2)

        if idlePaused {
            let preferred = AudioInputRouter.preferredDevice(in: catalog)
            if let input, let preferred, preferred.id == input.device,
               preferred.uid == activeDevice?.uid {
                guard beginCapturing(generation) else { return false }
                resetConverterForWarmStart()
                idlePaused = false
                let began = DispatchTime.now()
                let resumed = Self.fencedEngineStart(
                    isOwned: { self.ownsActiveCapture(generation) },
                    start: {
                        do { try input.start(); return true }
                        catch { log("mic resume failed (\(error)) — rebuilding route"); return false }
                    },
                    tearDown: { self.teardown() })
                if resumed {
                    armHealthWatchdog(resetHealthForWarmRoute())
                    log(String(format: "MIC_START_METRIC kind=resume start_ms=%.1f", ms(began, .now())))
                    return true
                }
            } else {
                teardown()
            }
        }
        if let input, input.isRunning {
            let preferred = AudioInputRouter.preferredDevice(in: catalog)
            if preferred == nil || preferred?.id == input.device {
                guard beginCapturing(generation) else { return false }
                resetConverterForWarmStart()
                input.resumeFromWarmIdle()
                armHealthWatchdog(resetHealthForWarmRoute())
                return true
            }
            log("mic route changed while warm — rebinding before capture")
            teardown()
        }
        if startEngine(catalog: catalog, captureOwner: generation, activating: true) { return true }
        lock.lock()
        _ = captureOwnership.cancelOpening(generation)
        lock.unlock()
        return false
    }

    /// The converter from a device's capture format to 16 kHz mono, and for a multi-channel
    /// input the mixer that feeds it (see `InputChannelMixer`: the converter alone keeps
    /// only the first channel, or none at all from 3+ discrete channels). nil when the
    /// format cannot be turned into a usable mono signal.
    static func makeConversion(from format: AVAudioFormat,
                               to target: AVAudioFormat) -> (AVAudioConverter, InputChannelMixer?)? {
        guard format.channelCount > 1 else {
            return AVAudioConverter(from: format, to: target).map { ($0, nil) }
        }
        if let mixer = InputChannelMixer(sourceFormat: format),
           let converter = AVAudioConverter(from: mixer.monoFormat, to: target) {
            return (converter, mixer)
        }
        // A stereo layout the mixer cannot read keeps the converter's own first-channel path.
        guard format.channelCount == 2 else { return nil }
        return AVAudioConverter(from: format, to: target).map { ($0, nil) }
    }

    private func resetConverterForWarmStart() {
        lock.lock()
        converter?.reset()
        channelMixer?.reset()
        outBuf = nil
        lock.unlock()
    }

    /// Updates the overflow cap of an in-flight or warming capture (e.g. cold double-tap latch).
    func updateCap(seconds: Double) {
        lock.lock()
        capSamples = Int(Self.sampleRate * seconds)
        lock.unlock()
    }

    /// Device queue: start accepting tap audio, unless a newer `begin` or an `end` has
    /// already superseded this open — that capture is over and must not be resurrected.
    @discardableResult
    private func beginCapturing(_ generation: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        lock.lock()
        let activated = captureOwnership.activate(generation)
        lock.unlock()
        return activated
    }

    /// Device queue → session queue: the watchdog timer belongs to the session queue.
    /// A route that has since been torn down or a capture that has ended arms nothing.
    private func armHealthWatchdog(_ route: Int) {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.captureOwnership.isCapturing && route == self.routeGeneration
            self.lock.unlock()
            guard current else { return }
            self.scheduleHealthWatchdog(route)
        }
    }

    /// X3/R-6: test-only. Seeds the capture buffer with decoded fixture audio so
    /// `--selftest` can enter at the `.up` edge and traverse the real
    /// finish → end → process → transcribe → clean → paste span. No engine, no tap, no
    /// mic — and nothing on the live path ever calls it.
    func preloadForTest(_ preloaded: [Float]) {
        lock.lock()
        sampleStorage.replace(with: preloaded)
        routeFrames = 0
        overflowed = false
        let owner = captureOwnership.begin()
        _ = captureOwnership.activate(owner)
        lock.unlock()
    }

    /// Test-only: binds a headless `DeviceInputStream` and real `AVAudioConverter` so unit
    /// tests can verify key-up consonant tail drain and warm converter resets without hardware.
    @discardableResult
    func beginSimulatedCaptureForTest(
        inputFormat: AVAudioFormat,
        simulatedAsyncIO: Bool = false
    ) -> DeviceInputStream? {
        guard let (conv, mixer) = Self.makeConversion(from: inputFormat, to: target) else { return nil }
        conv.reset()
        lock.lock()
        sampleStorage.clear()
        overflowed = false
        capSamples = Int(Self.sampleRate * Self.maxSeconds)
        converter = conv
        channelMixer = mixer
        outBuf = nil
        routeGeneration &+= 1
        let generation = routeGeneration
        routeSampleStart = 0
        routeFrames = 0
        routePeak = 0
        let owner = captureOwnership.begin()
        _ = captureOwnership.activate(owner)
        lock.unlock()

        let stream = DeviceInputStream(
            format: inputFormat,
            simulatedAsyncIO: simulatedAsyncIO,
            handler: { [weak self] buf, time in
                self?.append(buf, time: time, generation: generation)
            }
        )
        lock.lock()
        activeStream = stream
        lock.unlock()
        return stream
    }

    /// Test-only: exercises the warm keep-warm restart path (`converter?.reset()` + `resumeFromWarmIdle()`).
    @discardableResult
    func resumeSimulatedCaptureForTest() -> Bool {
        lock.lock()
        guard let stream = activeStream, stream.isRunning else {
            lock.unlock()
            return false
        }
        sampleStorage.clear()
        overflowed = false
        converter?.reset()
        channelMixer?.reset()
        outBuf = nil
        routeSampleStart = 0
        routeFrames = 0
        routePeak = 0
        let owner = captureOwnership.begin()
        let activated = captureOwnership.activate(owner)
        lock.unlock()
        guard activated else { return false }
        stream.resumeFromWarmIdle()
        return true
    }

    /// The audio captured so far, WITHOUT ending the capture. Empty unless a capture is
    /// running, so a snapshot can never resurrect the previous utterance's audio.
    func snapshot() -> [Float] {
        lock.lock()
        guard captureOwnership.isCapturing else {
            lock.unlock()
            return []
        }
        let values = sampleStorage.samples(in: 0..<sampleStorage.count)
        lock.unlock()
        return values
    }

    /// The trailing window of that same audio, for the live partial preview. The pill only
    /// ever shows the newest words, so decoding the whole utterance once a second made a
    /// long dictation pay for its own length on every tick.
    func snapshot(lastSeconds: Double) -> [Float] {
        lock.lock()
        guard captureOwnership.isCapturing else {
            lock.unlock()
            return []
        }
        let total = sampleStorage.count
        guard total > 0 else {
            lock.unlock()
            return []
        }
        let window = max(0, Int(Self.sampleRate * lastSeconds))
        let start = max(0, total - window)
        let values = sampleStorage.samples(in: start..<total)
        lock.unlock()
        return values
    }

    struct StreamingSlice: Sendable {
        let samples: [Float]
        let offset: Int
        let revision: Int
    }

    /// Copies only the new trailing slice without sealing `active`. A route recovery may
    /// replace a recorded tail; its new revision forces streaming recognition to restart
    /// from the retained audio.
    func streamingSnapshot(after offset: Int, revision previousRevision: Int?) -> StreamingSlice? {
        lock.lock()
        guard captureOwnership.isCapturing else { lock.unlock(); return nil }
        let revision = routeGeneration
        let start = previousRevision == revision && offset <= sampleStorage.count ? max(0, offset) : 0
        let endIndex = sampleStorage.count
        guard endIndex > start else { lock.unlock(); return nil }
        let values = sampleStorage.samples(in: start..<endIndex)
        lock.unlock()
        return StreamingSlice(samples: values, offset: start, revision: revision)
    }

    private(set) var endedStreamRevision = 0 // written by end() on the session queue

    /// Stops capturing and returns the utterance. Performs a bounded ~32ms tail drain on
    /// normal key-up (`drainTail == true`) so `InputCoalescer.pending`, queued `deliveryQueue`
    /// buffers, and `AVAudioConverter` resampler filter frames are preserved instead of
    /// clipping final `/s/`, `/t/`, `/d/` consonants.
    func end(drainTail: Bool = true) -> [Float] {
        healthWork?.cancel()
        healthWork = nil
        healthEpoch &+= 1

        lock.lock()
        let wasCapturing = captureOwnership.isCapturing
        let stream = activeStream
        lock.unlock()

        if wasCapturing {
            if drainTail {
                stream?.drainAndGateIdle(timeout: Self.tailDrainTimeout)
            } else {
                stream?.setIdlePaused(true)
            }
        } else {
            stream?.setIdlePaused(true)
        }

        lock.lock()
        if drainTail, captureOwnership.isCapturing, routeFrames > 0, let conv = converter {
            flushConverterTailLocked(conv)
        } else if drainTail {
            converter?.reset()
        }
        captureOwnership.end()
        endedStreamRevision = routeGeneration
        let (chunks, count) = sampleStorage.takeChunks()
        lock.unlock()
        let out = SampleStorage.flatten(chunks, count: count)
        scheduleIdleStop()
        return out
    }

    private func flushConverterTailLocked(_ conv: AVAudioConverter) {
        let tailCapacity: AVAudioFrameCount = 512
        guard let tailOut = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: tailCapacity) else {
            conv.reset()
            return
        }
        for _ in 0..<4 {
            tailOut.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: tailOut, error: &err) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if err != nil { break }
            if tailOut.frameLength > 0, let ptr = tailOut.floatChannelData?[0] {
                sampleStorage.append(UnsafeBufferPointer(start: ptr, count: Int(tailOut.frameLength)))
                routeFrames += Int(tailOut.frameLength)
            }
            if status == .endOfStream || tailOut.frameLength == 0 {
                break
            }
        }
        conv.reset()
    }

    func refreshIdlePolicy() {
        guard !isCapturing else { return }
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        lock.lock()
        let owner = captureOwnership.generation
        let wireless = routeIsWireless
        lock.unlock()
        let delay = wireless ? 0 : idleDelay ?? MicrophonePreferences.keepWarmSeconds
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.isCapturing else { return }
            self.deviceQueue.async {
                // A `begin` may have raced in behind this hop; it owns the input now.
                self.lock.lock()
                let stillIdle = !self.captureOwnership.isCapturing
                    && self.captureOwnership.generation == owner
                self.lock.unlock()
                guard stillIdle, let input = self.input else { return }
                if self.activeDevice?.isWireless == true {
                    self.teardown()
                    log("mic idle — wireless input released")
                    return
                }
                input.pause()
                self.idlePaused = true
                log("mic idle \(Int(delay))s — hardware paused, prepared=true")
            }
        }
        idleStop = w
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Every open and recovery carries the exact capture owner. A cold `begin` activates
    /// that owner here; recovery callers must arrive with the same owner still active.
    private func startEngine(catalog providedCatalog: AudioInputRouter.Catalog? = nil,
                             captureOwner: Int,
                             activating: Bool = false) -> Bool {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        guard activating ? beginCapturing(captureOwner)
                         : ownsActiveCapture(captureOwner) else { return false }
        let catalog = providedCatalog ?? AudioInputRouter.catalog()
        while true {
            guard ownsActiveCapture(captureOwner) else { return false }
            guard let device = AudioInputRouter.preferredDevice(in: catalog,
                                                                excluding: failedDeviceIDs) else {
                break
            }
            let binding = AudioInputRouter.binding(for: device, in: catalog)
            activeDevice = device
            let formatStarted = DispatchTime.now()
            let fmt: AVAudioFormat
            do {
                fmt = try DeviceInputStream.inputFormat(of: device.id)
            } catch {
                log("RECORDER: \(device.name) [\(device.transportName)] has no usable input: \(error)")
                failedDeviceIDs.insert(device.id)
                continue
            }
            let formatMS = ms(formatStarted, .now())
            if formatMS > 100 {
                log(String(format: "DIAG input format read took %.0fms", formatMS))
            }
            guard let (conv, mixer) = Self.makeConversion(from: fmt, to: target) else {
                log("RECORDER: no converter from \(device.name) \(fmt) to 16kHz mono")
                failedDeviceIDs.insert(device.id)
                continue
            }
            conv.reset()
            lock.lock()
            let ownsCapture = captureOwnership.ownsActiveCapture(captureOwner)
            if ownsCapture {
                converter = conv
                channelMixer = mixer
                outBuf = nil
                routeGeneration &+= 1
                routeSampleStart = sampleStorage.count
                routeFrames = 0
                routePeak = 0
                routeIsWireless = device.isWireless
            }
            let generation = routeGeneration
            inputRevision &+= 1
            let revision = inputRevision
            lock.unlock()
            guard ownsCapture else {
                teardown()
                return false
            }

            let openStarted = DispatchTime.now()
            lock.lock()
            activeStream = nil
            lock.unlock()
            input?.invalidate()
            input = nil
            let stream: DeviceInputStream
            do {
                stream = try DeviceInputStream(
                    device: device.id, format: fmt,
                    handler: { [weak self] buf, time in
                        self?.append(buf, time: time, generation: generation)
                    },
                    onInterrupted: { [weak self] in
                        guard let self else { return }
                        self.queue.async { self.scheduleReconfigure(inputRevision: revision) }
                    })
            } catch {
                log("RECORDER: could not open \(device.name) [\(device.transportName)]: \(error)")
                failedDeviceIDs.insert(device.id)
                continue
            }
            input = stream
            lock.lock()
            activeStream = stream
            lock.unlock()
            let openedAt = DispatchTime.now()
            var startError: Error?
            let started = Self.fencedEngineStart(
                isOwned: { self.ownsActiveCapture(captureOwner) },
                start: {
                    do {
                        try stream.start()
                        return true
                    } catch {
                        startError = error
                        return false
                    }
                },
                tearDown: { self.teardown() }
            )
            guard started else {
                if let startError {
                    log("RECORDER: device start failed on \(device.name): \(startError)")
                }
                failedDeviceIDs.insert(device.id)
                guard ownsActiveCapture(captureOwner) else { return false }
                continue
            }
            let startMS = ms(openStarted, .now())
            installTopologyListenersIfNeeded()
            routeTopologyDirty.store(false)
            log(String(format: "MIC_START_METRIC kind=cold prepare_ms=%.1f start_ms=%.1f",
                       ms(openStarted, openedAt), ms(openedAt, .now())))
            if startMS > 100 {
                log(String(format: "DIAG mic device open/start took %.0fms", startMS))
            }
            markPrimeReady()

            if let defaultDevice = binding.defaultDevice, defaultDevice.id != device.id {
                log("mic route: default=\(defaultDevice.name) [\(defaultDevice.transportName)] -> " +
                    "capture=\(device.name) [\(device.transportName)] (app-local; system route unchanged)")
            } else {
                log("mic route: capture=\(device.name) [\(device.transportName)] (\(binding.reason))")
            }
            log(String(format: "mic input started — %@ [%@] %.0fHz %dch",
                       device.name, device.transportName, fmt.sampleRate, fmt.channelCount))
            armHealthWatchdog(generation)
            return true
        }
        activeDevice = nil
        log("RECORDER: no usable input device remains")
        return false
    }

    struct DiagnosticState: Sendable {
        let running: Bool
        let paused: Bool
        let callbacks: UInt64
        let device: AudioDeviceID?
    }

    /// Metadata only; device access stays serialized with actual open/pause operations.
    func diagnosticState(_ done: @escaping @Sendable (DiagnosticState) -> Void) {
        deviceQueue.async {
            self.lock.lock()
            let callbacks = self.tapCallbacks
            self.lock.unlock()
            let state = DiagnosticState(running: self.input?.isRunning ?? false, paused: self.idlePaused,
                                        callbacks: callbacks, device: self.activeDevice?.id)
            self.queue.async { done(state) }
        }
    }

    func shutdownForDiagnostic() {
        idleStop?.cancel()
        deviceQueue.async { self.teardown() }
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        lock.lock()
        routeGeneration &+= 1       // any callback already in flight becomes stale
        converter = nil
        channelMixer = nil
        outBuf = nil
        activeStream = nil
        routeIsWireless = false
        lock.unlock()
        input?.invalidate()
        input = nil
        idlePaused = false
        activeDevice = nil
    }

    /// Drops the open input after a proven failure or a device change, so the next open
    /// creates a fresh IO proc. Healthy warm and paused starts keep their fast path.
    private func releaseInput() {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        teardown()
        lock.lock()
        inputRevision &+= 1
        lock.unlock()
        primeLock.lock()
        primeReady = false
        primeLock.unlock()
        log("mic input released — the next open starts a fresh device stream")
    }

    /// The open device died or changed format: release it and, mid-capture, reopen the
    /// preferred route. A system default change never lands here; it does not touch an
    /// input bound to its own device, and every press resolves the route afresh.
    private func reconfigure() {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        lock.lock()
        let captureOwner = captureOwnership.activeOwner
        lock.unlock()
        guard input != nil else { return }
        log("mic input changed — rebuilding route (capturing=\(captureOwner != nil))")
        releaseInput()
        // `end()` may have invalidated the snapshot while teardown ran. Idle capture is
        // intentionally left stopped; the next begin resolves the route from scratch.
        guard let captureOwner else {
            // Settle the replacement route while idle; nothing is opened.
            queue.async { [weak self] in self?.primeAsync() }
            return
        }
        guard ownsActiveCapture(captureOwner) else { return }
        routeRestartCount += 1
        guard routeRestartCount <= routeRestartLimit else {
            failCapture("input route kept changing and exceeded the restart budget",
                        owner: captureOwner)
            return
        }
        guard startEngine(captureOwner: captureOwner) else {
            guard ownsActiveCapture(captureOwner) else { return }
            failCapture("configuration changed and no input could be reopened",
                        owner: captureOwner)
            return
        }
        // This is deliberately in addition to the fence around the device start: it binds
        // the whole recovery result to the owner before any success-side work continues.
        guard ownsActiveCapture(captureOwner) else { teardown(); return }
    }

    /// Device notifications arrive in bursts during Bluetooth handoffs.
    /// Coalescing them avoids repeatedly tearing down the replacement route.
    private func scheduleReconfigure(inputRevision revision: Int) {
        lock.lock()
        let current = revision == inputRevision
        lock.unlock()
        // An old input's late notification must not cancel the new input's pending
        // configuration work before the device-queue revision check can reject it.
        guard current else { return }
        configurationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deviceQueue.async {
                self.lock.lock()
                let stillCurrent = revision == self.inputRevision
                self.lock.unlock()
                guard stillCurrent else { return }
                self.reconfigure()
            }
        }
        configurationWork = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Input liveness

    private static let digitalSilenceEpsilon: Float = 1e-8
    private static let healthDeadline = 0.70

    /// `true` means the route is not merely quiet: it has supplied no PCM or only
    /// numerical zero. Physical microphones always have a noise floor above 1e-8.
    static func inputIsDead(frames: Int, peak: Float,
                            exactZeroIsFailure: Bool, inputMuted: Bool) -> Bool {
        frames == 0 || (!inputMuted && exactZeroIsFailure && peak <= digitalSilenceEpsilon)
    }

    private func resetHealthForWarmRoute() -> Int {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        lock.lock()
        routeSampleStart = sampleStorage.count
        routeFrames = 0
        routePeak = 0
        let generation = routeGeneration
        lock.unlock()
        return generation
    }

    /// Session queue: the timer and its epoch live here, but everything the deadline then
    /// inspects or repairs belongs to the route, so the check itself runs on the device
    /// queue. A check that outlives its route is dropped there by `routeGeneration`.
    private func scheduleHealthWatchdog(_ generation: Int) {
        healthWork?.cancel()
        healthEpoch &+= 1
        let epoch = healthEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self, epoch == self.healthEpoch else { return }
            self.deviceQueue.async { self.checkInputHealth(generation) }
        }
        healthWork = work
        queue.asyncAfter(deadline: .now() + Self.healthDeadline, execute: work)
    }

    private func checkInputHealth(_ generation: Int) {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        let inputMuted = AVAudioApplication.shared.isInputMuted ||
            activeDevice.map(AudioInputRouter.inputIsMuted) == true
        let exactZeroIsFailure = activeDevice?.requiresNonzeroInput == true
        lock.lock()
        guard let captureOwner = captureOwnership.activeOwner,
              generation == routeGeneration else {
            lock.unlock()
            return
        }
        let frames = routeFrames
        let peak = routePeak
        let sampleStart = routeSampleStart
        // Known physical mics, including the Studio Display, must supply a noise
        // floor unless explicitly muted. Other digital sources may gate to zero.
        let dead = Self.inputIsDead(frames: frames, peak: peak,
                                    exactZeroIsFailure: exactZeroIsFailure,
                                    inputMuted: inputMuted)
        if !dead {
            // Start a fresh window so a route that becomes digitally silent later
            // is caught too; a startup-only check would miss mid-session handoffs.
            routeSampleStart = sampleStorage.count
            routeFrames = 0
            routePeak = 0
            lock.unlock()
            if awaitingRecoveredSignal, peak > Self.digitalSilenceEpsilon {
                awaitingRecoveredSignal = false
                log("mic input recovered — nonzero audio verified on \(activeDevice?.name ?? "input")")
            }
            if inputMuted, !inputMuteReported {
                inputMuteReported = true
                log("mic input is muted by the system/accessory — keeping the selected route")
                queue.async { self.onInputMuted?() }
            } else if !inputMuted, inputMuteReported {
                inputMuteReported = false
                log("mic input unmuted — capture resumed")
            }
            armHealthWatchdog(generation)
            return
        }

        // Atomically invalidate the tap generation before releasing the lock. A
        // first real speech buffer can no longer race the zero snapshot and then be
        // deleted as though it belonged to the silent segment.
        routeGeneration &+= 1
        converter = nil
        channelMixer = nil
        outBuf = nil
        if sampleStorage.count > sampleStart {
            sampleStorage.truncate(to: sampleStart)
        }
        lock.unlock()

        let failed = activeDevice
        let detail = frames == 0 ? "no audio callbacks" : "\(frames) frames of digital silence"
        log("RECORDER: \(failed?.name ?? "input") delivered \(detail) for " +
            "\(Int(Self.healthDeadline * 1000))ms")

        // The segment was atomically proven zero and removed above. Samples captured
        // before a mid-session route failure remain intact.
        let recoveryAction = routeRecovery.nextAction(for: failed?.id)
        if recoveryAction == .nextDevice, let failed { failedDeviceIDs.insert(failed.id) }
        releaseInput()
        healthRecoveryCount += 1
        routeRestartCount += 1
        if healthRecoveryCount < healthRecoveryLimit,
           routeRestartCount <= routeRestartLimit {
            guard ownsActiveCapture(captureOwner) else { return }
            if startEngine(captureOwner: captureOwner) {
                guard ownsActiveCapture(captureOwner) else { teardown(); return }
                awaitingRecoveredSignal = true
                if let activeDevice { onDevice?(activeDevice.name) }
                log("mic input reopened on \(activeDevice?.name ?? "alternate device") — awaiting signal")
                return
            }
        }
        guard ownsActiveCapture(captureOwner) else { return }
        failCapture("input stayed digitally silent after automatic route recovery",
                    owner: captureOwner)
    }

    /// The input teardown belongs to the device queue, but the sample handover and the
    /// callback must run on the session queue: `end()` takes the same storage there, and
    /// two concurrent takes would let a release racing a dying route find an already
    /// emptied buffer — the speech preserved here, then reported as "nothing recorded".
    /// Serialized, exactly one of the two takes the samples and delivers them.
    private func failCapture(_ reason: String, owner: Int) {
        dispatchPrecondition(condition: .onQueue(deviceQueue))
        teardown()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.captureOwnership.claimFailure(owner) else {
                self.lock.unlock()
                return
            }
            let (chunks, count) = self.sampleStorage.takeChunks()
            self.lock.unlock()
            let preserved = SampleStorage.flatten(chunks, count: count)
            log("RECORDER: capture failed — \(reason)")
            self.onInputFailure?(preserved, reason)
        }
    }

    static func selfCheck() {
        AudioInputRouter.selfCheck()
        precondition(inputIsDead(frames: 0, peak: 0, exactZeroIsFailure: false,
                                 inputMuted: false),
                     "No callbacks must be unhealthy")
        precondition(inputIsDead(frames: 16_000, peak: 0, exactZeroIsFailure: true,
                                 inputMuted: false),
                     "Exact-zero PCM from a physical/wireless mic must be unhealthy")
        precondition(!inputIsDead(frames: 16_000, peak: 0, exactZeroIsFailure: false,
                                  inputMuted: false),
                     "A callback-producing digital source may intentionally gate silence")
        precondition(!inputIsDead(frames: 1_024, peak: 1e-5, exactZeroIsFailure: true,
                                  inputMuted: false),
                     "A tiny physical-mic noise floor must be healthy")
        precondition(!inputIsDead(frames: 16_000, peak: 0, exactZeroIsFailure: true,
                                  inputMuted: true),
                     "System/accessory mute must not blacklist a healthy route")
        precondition(inputIsDead(frames: 0, peak: 0, exactZeroIsFailure: true,
                                 inputMuted: true),
                     "Mute zeroes samples but cannot explain missing callbacks")
        var storage = SampleStorage()
        let fixture = (0..<(SampleStorage.chunkCapacity + 7)).map(Float.init)
        storage.append(fixture)
        let (firstChunks, firstCount) = storage.snapshotChunks()
        storage.append([99, 100])
        let firstSnapshot = SampleStorage.flatten(firstChunks, count: firstCount)
        precondition(firstSnapshot == fixture,
                     "A later audio append must not mutate an existing live snapshot")
        storage.truncate(to: 5)
        let (finalChunks, finalCount) = storage.takeChunks()
        precondition(SampleStorage.flatten(finalChunks, count: finalCount) == Array(fixture.prefix(5)),
                     "Route-tail truncation must preserve the exact prior PCM prefix")
        precondition(storage.count == 0,
                     "Ending capture must move PCM out and reset retained sample count")
        log("RECORDERCHECK signal liveness PASS")
    }

    // MARK: - Tap thread

    private func append(_ input: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
        let callbackAt = DispatchTime.now()
        guard input.frameLength > 0,
              let (rms, voice) = convert(input, time: time, callbackAt: callbackAt, generation: generation) else { return }
        let now = DispatchTime.now()
        // Current Wispr desktop metering: RMS dB, an adaptive noise floor that can
        // descend to -60dB, a 20dB visual range, then a 150ms mean sent to the UI.
        let db = 20 * log10(rms + 1e-10)
        levelLock.lock()
        let responsiveLevel = responsiveMeter.level(rms: rms)
        if db < levelFloorDB { levelFloorDB = max(-60, db) }
        let normalized = min(1, max(0, (db - levelFloorDB) / 20))
        levelTotal += normalized
        levelSamples += 1
        guard ms(levelWindowStartedAt, now) >= 150 else {
            levelLock.unlock()
            onLevels?(responsiveLevel, nil, voice)
            return
        }
        let level = levelTotal / Float(levelSamples)
        levelTotal = 0
        levelSamples = 0
        levelWindowStartedAt = now
        levelLock.unlock()
        onLevels?(responsiveLevel, level, voice)
    }

    /// Converts one device buffer into the utterance and returns its RMS level and gated voice loudness.
    private func convert(_ input: AVAudioPCMBuffer, time: AVAudioTime,
                         callbackAt: DispatchTime, generation: Int) -> (Float, Float)? {
        lock.lock()
        defer { lock.unlock() }
        tapCallbacks &+= 1
        guard captureOwnership.isCapturing,
              generation == routeGeneration,
              let conv = converter else { return nil }

        let needed = AVAudioFrameCount(Double(input.frameLength) * Self.sampleRate / input.format.sampleRate) + 16
        if outBuf == nil || outBuf!.frameCapacity < needed {
            outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(needed, 2048))
        }
        guard let out = outBuf else { return nil }
        let source: AVAudioPCMBuffer
        if channelMixer != nil {
            guard let mixed = channelMixer?.mix(input) else { return nil }
            source = mixed
        } else {
            source = input
        }

        var err: NSError?
        let feed = ConverterInput(source)
        conv.convert(to: out, error: &err) { _, status in
            feed.next(status)
        }
        if let err { log("RECORDER: convert error \(err)"); return nil }
        guard out.frameLength > 0, let ptr = out.floatChannelData?[0] else { return nil }
        if sampleStorage.count == 0, let requested = captureRequestedAt {
            let firstSample = DispatchTime.now()
            let requestID = captureRequestID ?? "standalone"
            let timing = Self.captureTiming(time: time, requestedAt: requested, callbackAt: callbackAt)
            queue.async {
                log(String(format: "CAPTURE_METRIC route_generation=%d open_to_first_sample_ms=%.1f request_id=%@",
                           generation, ms(requested, firstSample), requestID))
                if let timing {
                    log(String(format: "FIRST_AUDIO_METRIC request_id=%@ open_to_audio_start_ms=%.1f audio_to_callback_ms=%.1f",
                               requestID, timing.openToAudioMS, timing.audioToCallbackMS))
                }
            }
        }
        sampleStorage.append(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
        routeFrames += Int(out.frameLength)
        var peak: Float = 0
        vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(out.frameLength))
        routePeak = max(routePeak, peak)

        if !overflowed, sampleStorage.count >= capSamples {
            overflowed = true
            let cap = Double(capSamples) / Self.sampleRate
            queue.async { self.onOverflow?(cap) }
        }
        var rms: Float = 0
        vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(out.frameLength))
        return (rms, voiceGate.loudness(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength))))
    }

    /// Tap acquisition time and callback arrival are different milestones. A negative
    /// start offset is valid prebuffered audio, not a duration to silently clamp to zero.
    static func captureTiming(time: AVAudioTime, requestedAt: DispatchTime, callbackAt: DispatchTime)
        -> (openToAudioMS: Double, audioToCallbackMS: Double)? {
        guard time.isHostTimeValid else { return nil }
        let audioSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        return ((audioSeconds - Double(requestedAt.uptimeNanoseconds) / 1e9) * 1000,
                (Double(callbackAt.uptimeNanoseconds) / 1e9 - audioSeconds) * 1000)
    }
}
