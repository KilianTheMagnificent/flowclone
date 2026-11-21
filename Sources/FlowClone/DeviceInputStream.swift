// Input-only capture from one explicitly chosen Core Audio device.
//
// AVAudioEngine's input node is not pinned by `setDeviceID`: whenever the system default
// input or output changes, the engine re-points its I/O unit at a private aggregate of the
// defaults (`CADefaultDeviceAggregate`), even while it is stopped. When the default input
// is a Bluetooth headset, merely selecting that mic moves the headset from its music
// profile (A2DP) to its call profile (HFP), which changes the sound and volume of whatever
// it is playing. Observed 2026-10-06 with AirPods: FlowClone sat idle, prepared on the
// Studio Display mic, and still held the AirPods in call mode from the moment they
// connected until the next press. A device IOProc touches no device but its own.
@preconcurrency import AVFoundation
import CoreAudio
import Darwin
import Synchronization

@available(macOS 15.0, *)
private final class ModernAtomicBool: Sendable {
    let value: Atomic<Bool>
    init(_ initial: Bool) { value = Atomic(initial) }
}

/// Lock-free boolean safe to read and write on the real-time CoreAudio HAL IOProc thread
/// while targeting macOS 14+. Uses `Synchronization.Atomic` on macOS 15+ and Darwin barrier
/// atomics on macOS 14, never acquiring a mutex or priority-inverting lock.
final class LockFreeBool: @unchecked Sendable {
    private let modern: AnyObject?
    private let legacy: UnsafeMutablePointer<Int32>

    init(_ initial: Bool = false) {
        if #available(macOS 15.0, *) {
            modern = ModernAtomicBool(initial)
        } else {
            modern = nil
        }
        legacy = .allocate(capacity: 1)
        legacy.initialize(to: initial ? 1 : 0)
    }

    deinit {
        legacy.deinitialize(count: 1)
        legacy.deallocate()
    }

    @inline(__always)
    func load() -> Bool {
        if #available(macOS 15.0, *), let box = modern as? ModernAtomicBool {
            return box.value.load(ordering: .acquiring)
        }
        return OSAtomicAdd32Barrier(0, legacy) != 0
    }

    @inline(__always)
    func store(_ newValue: Bool) {
        if #available(macOS 15.0, *), let box = modern as? ModernAtomicBool {
            box.value.store(newValue, ordering: .releasing)
            return
        }
        let target: Int32 = newValue ? 1 : 0
        while true {
            let current = OSAtomicAdd32Barrier(0, legacy)
            if OSAtomicCompareAndSwap32Barrier(current, target, legacy) { return }
        }
    }

    @inline(__always)
    func exchange(_ newValue: Bool) -> Bool {
        if #available(macOS 15.0, *), let box = modern as? ModernAtomicBool {
            return box.value.exchange(newValue, ordering: .acquiringAndReleasing)
        }
        let target: Int32 = newValue ? 1 : 0
        while true {
            let current = OSAtomicAdd32Barrier(0, legacy)
            if OSAtomicCompareAndSwap32Barrier(current, target, legacy) {
                return current != 0
            }
        }
    }
}

final class DeviceInputStream: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noInputStream
        case interrupted
        case unsupportedFormat(String)
        case coreAudio(String, OSStatus)

        var description: String {
            switch self {
            case .noInputStream: return "device has no input stream"
            case .interrupted: return "device changed since it was opened"
            case .unsupportedFormat(let detail): return "unsupported input format (\(detail))"
            case .coreAudio(let call, let status): return "\(call) failed (OSStatus \(status))"
            }
        }
    }

    let device: AudioDeviceID
    let format: AVAudioFormat

    private let deliveryQueue = DispatchQueue(label: "com.andre.flowclone.mic-input",
                                              qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "com.andre.flowclone.mic-input-listener")
    private let handler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let onInterrupted: @Sendable () -> Void
    /// IO thread only while a hardware IOProc (or simulated async IO thread) is active.
    private var coalescer: InputCoalescer
    private var procID: AudioDeviceIOProcID?
    private let simulatedAsyncIO: Bool
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private let startedFlag = LockFreeBool(false)
    private let interruptedFlag = LockFreeBool(false)
    /// Lock-free gate enabled during the 30s keep-warm idle window so the 47Hz HAL IOProc
    /// returns immediately without allocating buffers or hopping onto `deliveryQueue`.
    private let idleGatedFlag = LockFreeBool(false)
    private let resetCoalescerFlag = LockFreeBool(false)
    private let flushRequestedFlag = LockFreeBool(false)

    /// Running and still bound to the format the converter was built for. A dead device
    /// or a format change clears this; the recorder then rebuilds the route.
    var isRunning: Bool {
        startedFlag.load() && !interruptedFlag.load()
    }

    /// True while the keep-warm idle gate is active and `handleInput` drops frames in O(1).
    var isIdlePaused: Bool {
        idleGatedFlag.load()
    }

    /// `handler` receives about 21ms of audio per call on a serial queue, the cadence the
    /// AVAudioEngine tap had, so level meters stay responsive without per-IO-cycle hops.
    /// `onInterrupted` fires on a private queue when the device dies or changes format.
    init(device: AudioDeviceID, format: AVAudioFormat,
         handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
         onInterrupted: @escaping @Sendable () -> Void) throws {
        self.device = device
        self.format = format
        self.handler = handler
        self.onInterrupted = onInterrupted
        self.simulatedAsyncIO = false
        coalescer = InputCoalescer(format: format)
        var id: AudioDeviceIOProcID?
        // A nil queue runs the block directly on the HAL IO thread; a queue would only be
        // dispatched to synchronously. The block copies and hands off, nothing more.
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil) { [weak self] _, input, inputTime, _, _ in
            self?.handleInput(input, at: inputTime)
        }
        guard status == noErr, let id else { throw Failure.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status) }
        procID = id
        observeDevice()
    }

    /// Deterministic test-only initializer without CoreAudio hardware.
    init(format: AVAudioFormat,
         simulatedAsyncIO: Bool = false,
         handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
         onInterrupted: @escaping @Sendable () -> Void = {}) {
        self.device = AudioObjectID(kAudioObjectUnknown)
        self.format = format
        self.handler = handler
        self.onInterrupted = onInterrupted
        self.simulatedAsyncIO = simulatedAsyncIO
        self.procID = nil
        self.coalescer = InputCoalescer(format: format)
        startedFlag.store(true)
    }

    deinit { invalidate() }

    /// An interrupted input is never restarted: its format, and so the recorder's
    /// converter, may no longer match the device. The recorder opens a fresh one.
    func start() throws {
        guard let procID else { throw Failure.coreAudio("AudioDeviceStart", kAudioHardwareNotRunningError) }
        guard !interruptedFlag.load() else { throw Failure.interrupted }
        coalescer.reset()   // the IO proc is stopped here; a paused tail is not new audio
        resetCoalescerFlag.store(false)
        flushRequestedFlag.store(false)
        idleGatedFlag.store(false)
        let status = AudioDeviceStart(device, procID)
        guard status == noErr else { throw Failure.coreAudio("AudioDeviceStart", status) }
        startedFlag.store(true)
    }

    /// Re-opens audio delivery on a warm keep-warm stream without restarting the HAL device.
    func resumeFromWarmIdle() {
        flushRequestedFlag.store(false)
        if procID == nil && !simulatedAsyncIO {
            coalescer.reset()
            resetCoalescerFlag.store(false)
        } else {
            resetCoalescerFlag.store(true)
        }
        idleGatedFlag.store(false)
    }

    /// Updates the lock-free IOProc idle gate directly (e.g. on cancelled capture).
    func setIdlePaused(_ paused: Bool) {
        if paused {
            flushRequestedFlag.store(false)
            idleGatedFlag.store(true)
        } else {
            resumeFromWarmIdle()
        }
    }

    /// Bounded key-up tail drain (~30–35ms cap): flushes any partial `InputCoalescer.pending`
    /// buffer, engages the lock-free keep-warm idle gate, and drains queued `deliveryQueue`
    /// blocks so trailing consonants (`/s/`, `/t/`, `/d/`) convert before capture ends.
    func drainAndGateIdle(timeout: TimeInterval = 0.032) {
        let totalBudget = max(0.002, timeout)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadlineNanos = startedAt &+ UInt64(totalBudget * 1_000_000_000)

        guard isRunning else {
            flushRequestedFlag.store(false)
            idleGatedFlag.store(true)
            return
        }

        if !idleGatedFlag.load() {
            if procID == nil && !simulatedAsyncIO {
                let handler = handler
                coalescer.flushPending { buffer, start in
                    deliveryQueue.async { handler(buffer, start) }
                }
                idleGatedFlag.store(true)
            } else {
                flushRequestedFlag.store(true)
                let ioWaitLimitNanos = startedAt &+ UInt64(totalBudget * 0.75 * 1_000_000_000)
                while !idleGatedFlag.load(), isRunning,
                      DispatchTime.now().uptimeNanoseconds < ioWaitLimitNanos {
                    usleep(1_500)
                }
                if !idleGatedFlag.load() {
                    idleGatedFlag.store(true)
                    flushRequestedFlag.store(false)
                }
            }
        }

        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let remainingNanos = deadlineNanos > nowNanos
            ? deadlineNanos - nowNanos
            : 8_000_000 // minimum 8ms to drain already-enqueued local conversions
        let drained = DispatchSemaphore(value: 0)
        deliveryQueue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + .nanoseconds(Int(remainingNanos)))
    }

    /// Stops the hardware but keeps the IO proc, so a later `start` skips its creation.
    func pause() {
        flushRequestedFlag.store(false)
        idleGatedFlag.store(true)
        if let procID { AudioDeviceStop(device, procID) }
        startedFlag.store(false)
    }

    func invalidate() {
        flushRequestedFlag.store(false)
        idleGatedFlag.store(true)
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
        listeners.removeAll()
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
        startedFlag.store(false)
    }

    // MARK: - Format

    /// The virtual format of the device's first input stream: what its IO proc receives.
    /// Pure HAL property reads; nothing is opened.
    static func inputFormat(of device: AudioDeviceID) throws -> AVAudioFormat {
        guard let stream = firstInputStream(of: device) else { throw Failure.noInputStream }
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &description)
        guard status == noErr else { throw Failure.coreAudio("read input stream format", status) }
        return try captureFormat(for: description)
    }

    /// A HAL stream reaches its IO proc as one interleaved buffer. Anything else would
    /// need a layout this recorder never needs for a microphone, so it is refused and the
    /// router moves on to the next input. Three or more channels (multi-input USB interfaces,
    /// aggregate devices) need an explicit discrete layout: without one AVAudioFormat
    /// refuses them, and such an interface could never be used.
    static func captureFormat(for description: AudioStreamBasicDescription) throws -> AVAudioFormat {
        var description = description
        let nonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = description.mChannelsPerFrame
        let layout = channels > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
            : nil
        guard description.mFormatID == kAudioFormatLinearPCM,
              description.mSampleRate > 0, channels > 0,
              description.mBytesPerFrame > 0,
              !(nonInterleaved && channels > 1),
              let format = layout.map({ AVAudioFormat(streamDescription: &description, channelLayout: $0) })
                ?? AVAudioFormat(streamDescription: &description) else {
            throw Failure.unsupportedFormat(String(
                format: "id=0x%08X flags=0x%X %.0fHz %uch %u bytes/frame",
                description.mFormatID, description.mFormatFlags, description.mSampleRate,
                description.mChannelsPerFrame, description.mBytesPerFrame))
        }
        return format
    }

    private static func firstInputStream(of device: AudioDeviceID) -> AudioStreamID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else {
            return nil
        }
        return streams.first
    }

    // MARK: - IO thread (real-time HAL callback; strictly lock-free)

    func handleInput(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        guard !idleGatedFlag.load() else { return }
        if resetCoalescerFlag.exchange(false) {
            coalescer.reset()
        }
        let handler = handler
        let accepted = coalescer.append(input, at: time.pointee) { buffer, start in
            deliveryQueue.async { handler(buffer, start) }
        }
        guard accepted else {
            flushRequestedFlag.store(false)
            interruptFromIOThread()
            return
        }
        if flushRequestedFlag.exchange(false) {
            coalescer.flushPending { buffer, start in
                deliveryQueue.async { handler(buffer, start) }
            }
            idleGatedFlag.store(true)
        }
    }

    // MARK: - Device changes

    private func observeDevice() {
        let global = kAudioObjectPropertyScopeGlobal
        addListener(device, kAudioDevicePropertyDeviceIsAlive, global)
        addListener(device, kAudioDevicePropertyNominalSampleRate, global)
        addListener(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        addListener(device, kAudioDevicePropertyDeviceHasChanged, global)
        if let stream = Self.firstInputStream(of: device) {
            addListener(stream, kAudioStreamPropertyVirtualFormat, global)
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceChanged()
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    /// Listener queue. Most notifications leave the route usable; only a dead device or a
    /// different capture format makes the running converter wrong.
    private func deviceChanged() {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let readAlive = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr
        let current = try? Self.inputFormat(of: device)
        guard !readAlive || alive == 0 || current != format else { return }
        interrupt()
    }

    private func interruptFromIOThread() {
        guard !interruptedFlag.exchange(true) else { return }
        let onInterrupted = onInterrupted
        listenerQueue.async { onInterrupted() }
    }

    private func interrupt() {
        guard !interruptedFlag.exchange(true) else { return }
        onInterrupted()
    }
}

/// Copies IO-cycle buffers (typically 512 frames) into ~1024-frame deliveries at 48kHz.
/// Kept apart from the HAL so the copy and cadence are testable without hardware.
struct InputCoalescer {
    let format: AVAudioFormat
    let deliveryFrames: AVAudioFrameCount
    private var pending: AVAudioPCMBuffer?
    private var pendingTime: AVAudioTime?

    init(format: AVAudioFormat) {
        self.format = format
        deliveryFrames = AVAudioFrameCount(max(256, (format.sampleRate * 1024 / 48_000).rounded()))
    }

    var pendingFrameLength: AVAudioFrameCount {
        pending?.frameLength ?? 0
    }

    mutating func reset() {
        pending = nil
        pendingTime = nil
    }

    /// Flushes any sub-`deliveryFrames` tail buffer held at key-up so trailing consonants
    /// are delivered instead of stranded.
    mutating func flushPending(_ deliver: (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        flush(deliver)
    }

    /// Copies one IO cycle and calls `deliver` for each delivery it completes (at most
    /// two, when an oversized cycle cannot join the pending one). Returns false, copying
    /// nothing, when the buffer list no longer matches `format`: the device changed under
    /// the IO proc and the converter built for it is wrong.
    mutating func append(_ input: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp,
                         deliver: (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Bool {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = source.first, let samples = first.mData else { return true }
        guard first.mNumberChannels == format.channelCount else { return false }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0 else { return true }

        if let buffer = pending, Int(buffer.frameLength) + frames > Int(buffer.frameCapacity) {
            flush(deliver)
        }
        if pending == nil {
            let capacity = max(Int(deliveryFrames) * 2, frames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(capacity)) else {
                return true
            }
            pending = buffer
            var stamp = time
            pendingTime = AVAudioTime(audioTimeStamp: &stamp, sampleRate: format.sampleRate)
        }
        guard let buffer = pending,
              let destination = buffer.audioBufferList.pointee.mBuffers.mData else { return true }
        memcpy(destination.advanced(by: Int(buffer.frameLength) * bytesPerFrame), samples,
               frames * bytesPerFrame)
        buffer.frameLength += AVAudioFrameCount(frames)
        if buffer.frameLength >= deliveryFrames { flush(deliver) }
        return true
    }

    private mutating func flush(_ deliver: (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        if let buffer = pending, let time = pendingTime, buffer.frameLength > 0 {
            deliver(buffer, time)
        }
        reset()
    }
}
