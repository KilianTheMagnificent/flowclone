@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreAudio
import CoreGraphics
import CoreMedia
import Darwin
import Foundation

@MainActor
protocol SystemAudioSource: AnyObject {
    var backendName: String { get }
    func start() async throws
    func stop() async throws
}

/// Dedicated background serial queue for all blocking Core Audio HAL setup/teardown in meetings
/// so `@MainActor` (and the global `CGEventTap` hotkey) is never stalled by Core Audio IPC.
private enum MeetingHALExecutor {
    static let queue = DispatchQueue(label: "com.andre.flowclone.meeting-hal", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runNonThrowing<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

@available(macOS 14.2, *)
@MainActor
final class CoreAudioProcessTapSystemAudioSource: SystemAudioSource {
    var backendName: String { "coreAudioProcessTap" }

    private final class TapResources: @unchecked Sendable {
        var tapID: AudioObjectID = kAudioObjectUnknown
        var aggregateID: AudioObjectID = kAudioObjectUnknown
        var inputStream: DeviceInputStream?

        func teardown() {
            inputStream?.invalidate()
            inputStream = nil
            if aggregateID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateID)
                aggregateID = kAudioObjectUnknown
            }
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
                tapID = kAudioObjectUnknown
            }
        }
    }

    private let writer: MeetingAudioWriter
    private let onFailure: @Sendable (String, Bool) -> Void
    private let resources = TapResources()

    init(writer: MeetingAudioWriter, failed: @escaping @Sendable (String, Bool) -> Void) {
        self.writer = writer
        self.onFailure = failed
    }

    deinit {
        let resources = self.resources
        MeetingHALExecutor.queue.async {
            resources.teardown()
        }
    }

    func start() async throws {
        let resources = self.resources
        let writer = self.writer
        let failed = self.onFailure
        try await MeetingHALExecutor.run {
            do {
                let excluded = Self.currentProcessAudioObjectID().map { [$0] } ?? []
                let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
                tapDesc.name = "FlowClone Meeting System Audio Tap"
                tapDesc.isPrivate = true
                tapDesc.muteBehavior = .unmuted

                var createdTap: AudioObjectID = kAudioObjectUnknown
                let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &createdTap)
                guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
                    throw MeetingFailure("Core Audio process tap could not be created (OSStatus \(tapStatus)).")
                }
                resources.tapID = createdTap

                let aggregateUID = "com.andre.flowclone.meeting-tap.\(UUID().uuidString)"
                let aggregateDescription: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "FlowClone Meeting System Audio",
                    kAudioAggregateDeviceUIDKey: aggregateUID,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceTapAutoStartKey: true,
                    kAudioAggregateDeviceTapListKey: [[
                        kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true
                    ]]
                ]
                var createdAggregate: AudioObjectID = kAudioObjectUnknown
                let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate)
                guard aggStatus == noErr, createdAggregate != kAudioObjectUnknown else {
                    throw MeetingFailure("Core Audio aggregate tap device could not be created (OSStatus \(aggStatus)).")
                }
                resources.aggregateID = createdAggregate

                let format: AVAudioFormat
                if let deviceFormat = try? DeviceInputStream.inputFormat(of: createdAggregate) {
                    format = deviceFormat
                } else {
                    format = try Self.tapFormat(of: createdTap)
                }
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw MeetingFailure("Core Audio process tap reported an invalid audio format.")
                }

                let stream = try DeviceInputStream(
                    device: createdAggregate,
                    format: format,
                    handler: { buffer, _ in
                        writer.systemPCM(buffer)
                    },
                    onInterrupted: {
                        failed("System audio routing changed. Recording continues automatically.", true)
                    }
                )
                try stream.start()
                resources.inputStream = stream
            } catch {
                resources.teardown()
                throw error
            }
        }
    }

    func stop() async throws {
        let resources = self.resources
        await MeetingHALExecutor.runNonThrowing {
            resources.teardown()
        }
    }

    private nonisolated static func currentProcessAudioObjectID() -> AudioObjectID? {
        var pid = getpid()
        var processObject: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObject
        )
        guard status == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }

    private nonisolated static func tapFormat(of tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description)
        guard status == noErr else {
            throw MeetingFailure("Could not read Core Audio process tap format (OSStatus \(status)).")
        }
        return try DeviceInputStream.captureFormat(for: description)
    }
}

@MainActor
final class ScreenCaptureSystemAudioSource: SystemAudioSource {
    var backendName: String { "screenCaptureKit" }

    private let writer: MeetingAudioWriter
    private var stream: SCStream?

    init(writer: MeetingAudioWriter) {
        self.writer = writer
    }

    func start() async throws {
        // A denied system-audio permission is an error, never a silently microphone-only meeting.
        // macOS refuses at once (no waiting prompt) until the permission is granted in Settings.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CGPreflightScreenCaptureAccess() ? error : MeetingFailure(MacMeetingCapture.permissionMessage)
        }
        guard let display = content.displays.first else {
            throw MeetingFailure("No display is available for system audio capture.")
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let createdStream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: config,
            delegate: writer
        )
        try createdStream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        try await createdStream.startCapture()
        stream = createdStream
    }

    func stop() async throws {
        let active = stream
        stream = nil
        try await active?.stopCapture()
    }
}

/// Suppresses speaker bleed (e.g. Studio Display / built-in speakers) picked up by the microphone
/// across ~0–160 ms of acoustic + buffer delay while preserving near-field speech and double-talk.
struct SpeakerEchoSuppressor: Sendable {
    static let sampleRate = 16_000
    static let frameSamples = 160 // 10 ms at 16 kHz

    /// Maximum speaker-to-mic delay window (seconds) plus scheduling jitter allowance.
    var maxDelaySeconds: Double = 0.165
    var leadJitterSeconds: Double = 0.025
    /// Minimum RMS on the system audio reference to consider remote speakers active.
    var minSystemSpeechRMS: Float = 0.012
    /// Attenuated bleed ratio ceiling (`micRMS <= systemRMS * echoRatioThreshold`).
    var echoRatioThreshold: Float = 0.68
    /// Strong near-field voice energy floor above which microphone audio is never gated.
    var nearFieldFloorRMS: Float = 0.11

    private struct EnvelopeFrame: Sendable {
        var start: Double
        var end: Double
        var rms: Float
    }

    private var systemHistory: [EnvelopeFrame] = []
    private var currentGain: Float = 1.0
    private var holdFramesRemaining = 0
    private var lastReferenceRMS: Float = 0
    private(set) var suppressedFrameCount = 0

    init() {}

    mutating func observeSystem(_ samples: [Float], offset: Double) {
        samples.withUnsafeBufferPointer { buffer in
            observeSystem(samples: buffer, offset: offset)
        }
    }

    mutating func observeSystem(samples: UnsafeBufferPointer<Float>, offset: Double) {
        guard !samples.isEmpty else { return }
        var index = 0
        while index < samples.count {
            let endIdx = min(samples.count, index + Self.frameSamples)
            let count = endIdx - index
            var energy: Float = 0
            for i in index..<endIdx {
                let s = samples[i]
                energy += s * s
            }
            let rms = sqrt(energy / Float(count))
            let start = offset + Double(index) / Double(Self.sampleRate)
            let end = offset + Double(endIdx) / Double(Self.sampleRate)
            systemHistory.append(EnvelopeFrame(start: start, end: end, rms: rms))
            index = endIdx
        }
        let cutoff = (systemHistory.last?.end ?? offset) - 2.0
        if let dropCount = systemHistory.firstIndex(where: { $0.end >= cutoff }), dropCount > 64 {
            systemHistory.removeFirst(dropCount)
        }
    }

    mutating func processMicrophone(_ samples: [Float], offset: Double) -> [Float] {
        var copy = samples
        copy.withUnsafeMutableBufferPointer { buffer in
            processMicrophone(samples: buffer, offset: offset)
        }
        return copy
    }

    mutating func processMicrophone(samples: UnsafeMutableBufferPointer<Float>, offset: Double) {
        guard !samples.isEmpty else { return }
        var index = 0
        while index < samples.count {
            let endIdx = min(samples.count, index + Self.frameSamples)
            let count = endIdx - index
            var energy: Float = 0
            for i in index..<endIdx {
                let s = samples[i]
                energy += s * s
            }
            let micRMS = sqrt(energy / Float(count))
            let frameStart = offset + Double(index) / Double(Self.sampleRate)
            let frameEnd = offset + Double(endIdx) / Double(Self.sampleRate)
            let windowStart = frameStart - maxDelaySeconds
            let windowEnd = frameEnd + leadJitterSeconds

            var peakSystemRMS: Float = 0
            for entry in systemHistory where entry.end >= windowStart && entry.start <= windowEnd {
                if entry.rms > peakSystemRMS { peakSystemRMS = entry.rms }
            }

            let isDirectEcho = peakSystemRMS >= minSystemSpeechRMS
                && micRMS < nearFieldFloorRMS
                && micRMS <= peakSystemRMS * echoRatioThreshold

            let isReverbTail: Bool
            if !isDirectEcho, holdFramesRemaining > 0 {
                isReverbTail = micRMS < nearFieldFloorRMS
                    && micRMS <= max(0.025, lastReferenceRMS * echoRatioThreshold)
            } else {
                isReverbTail = false
            }

            let targetGain: Float
            if isDirectEcho {
                holdFramesRemaining = 3 // 30 ms room tail hangover
                lastReferenceRMS = peakSystemRMS
                suppressedFrameCount += 1
                targetGain = 0.0
            } else if isReverbTail {
                holdFramesRemaining -= 1
                suppressedFrameCount += 1
                targetGain = 0.0
            } else {
                holdFramesRemaining = 0
                targetGain = 1.0
            }

            let alpha: Float = targetGain < currentGain ? 0.12 : 0.05
            for i in index..<endIdx {
                currentGain += (targetGain - currentGain) * alpha
                if currentGain < 0.002 && targetGain == 0 { currentGain = 0 }
                if currentGain > 0.998 && targetGain == 1 { currentGain = 1 }
                samples[i] *= currentGain
            }
            index = endIdx
        }
    }
}

/// Both sources stay separate: remote voices are never assigned an invented speaker name.
/// The microphone is the one dictation uses (`AudioInputRouter`), opened directly: the system
/// default input can be a silent built-in mic (lid closed) and AVAudioEngine follows it.
@MainActor final class MacMeetingCapture: MeetingCapturing {
    typealias SystemAudioFactory = @MainActor (
        MeetingAudioWriter,
        @escaping @Sendable (String, Bool) -> Void
    ) throws -> any SystemAudioSource

    private var microphone: DeviceInputStream?
    private var systemAudio: (any SystemAudioSource)?
    private var writer: MeetingAudioWriter?
    /// Without this an in-person meeting, where nobody touches the Mac, ends at idle sleep.
    private var awake: NSObjectProtocol?
    /// With the lid closed the built-in microphone delivers exact zeros. It is still used when
    /// nothing else exists (the others' voices are recorded), and replaced when a real one appears.
    private var silentBuiltIn = false
    private var betterMicDetected = false
    private var checkingBetterMic = false
    private var coreAudioTapFailed = false

    var primarySystemAudioFactory: SystemAudioFactory?
    var fallbackSystemAudioFactory: SystemAudioFactory?
    private(set) var activeSystemAudioBackendName: String?

    var microphoneShouldChange: Bool {
        guard silentBuiltIn, microphone != nil else { return false }
        if betterMicDetected { return true }
        if !checkingBetterMic {
            checkingBetterMic = true
            Task { @MainActor [weak self] in
                let foundBetter = await MeetingHALExecutor.runNonThrowing {
                    guard let best = AudioInputRouter.preferredDevice() else { return false }
                    return !best.isBuiltIn
                }
                guard let self else { return }
                self.checkingBetterMic = false
                if self.silentBuiltIn, self.microphone != nil {
                    self.betterMicDetected = foundBetter
                }
            }
        }
        return false
    }

    nonisolated static let permissionMessage = "FlowClone needs permission to record system audio. Turn on FlowClone in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen FlowClone."

    var systemAudioAllowed: Bool {
        if handsfreeSession { return true }
        if #available(macOS 14.2, *), !coreAudioTapFailed {
            return true
        }
        return CGPreflightScreenCaptureAccess()
    }

    func requestSystemAudio() {
        guard !suppressHostAccess else { return }
        if #available(macOS 14.2, *), !coreAudioTapFailed {
            // Core Audio Process Tap uses NSAudioCaptureUsageDescription at capture time
            // without triggering ScreenCaptureKit's Screen Recording permission dialog.
            return
        }
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
    }

    /// Testable system-audio startup helper: tries Core Audio Process Tap first and falls back
    /// cleanly to ScreenCaptureKit if tap creation or startup fails.
    func startSystemAudioSource(
        writer: MeetingAudioWriter,
        failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void
    ) async throws -> any SystemAudioSource {
        let makePrimary: SystemAudioFactory? = primarySystemAudioFactory ?? {
            if #available(macOS 14.2, *) {
                return { writer, failed in CoreAudioProcessTapSystemAudioSource(writer: writer, failed: failed) }
            }
            return nil
        }()
        let makeFallback: SystemAudioFactory = fallbackSystemAudioFactory ?? { writer, _ in
            ScreenCaptureSystemAudioSource(writer: writer)
        }

        if let makePrimary {
            do {
                let primary = try makePrimary(writer, failed)
                try await primary.start()
                coreAudioTapFailed = false
                activeSystemAudioBackendName = primary.backendName
                log("meeting: system audio started via \(primary.backendName)")
                return primary
            } catch {
                coreAudioTapFailed = true
                log("meeting: primary system audio tap unavailable (\(error.localizedDescription)); falling back to ScreenCaptureKit")
            }
        }

        let fallback = try makeFallback(writer, failed)
        try await fallback.start()
        activeSystemAudioBackendName = fallback.backendName
        log("meeting: system audio started via \(fallback.backendName)")
        return fallback
    }

    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        try await start(directory: directory, startedAt: startedAt, initialOffsets: initialOffsets,
                        captureMode: .call, segment: segment, failed: failed)
    }

    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
               captureMode: MeetingCaptureMode,
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        guard !suppressHostAccess else { throw MeetingFailure("Live audio capture is disabled in the test session.") }
        guard microphone == nil, systemAudio == nil else { throw MeetingFailure("A meeting is already recording.") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw MeetingFailure("Microphone access is required to capture audio.")
        }
        let includeSystem = captureMode == .call
        let writer = MeetingAudioWriter(
            directory: directory,
            startedAt: startedAt,
            initialOffsets: initialOffsets,
            includeSystemAudio: includeSystem,
            segment: segment,
            failed: failed
        )

        struct PreparedMic: Sendable {
            let device: AudioInputDevice
            let silentBuiltIn: Bool
            let stream: DeviceInputStream
        }

        let prepared: PreparedMic = try await MeetingHALExecutor.run {
            let catalog = AudioInputRouter.catalog()
            guard let device = AudioInputRouter.preferredDevice(in: catalog) else {
                throw MeetingFailure("No working microphone was found.")
            }
            let silent = device.isBuiltIn && catalog.lidClosed
            if silent, !includeSystem {
                throw MeetingFailure("Open your MacBook lid or connect a microphone to record an in-person meeting.")
            }
            let format = try DeviceInputStream.inputFormat(of: device.id)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MeetingFailure("The microphone has no usable audio format.")
            }
            let stream = try DeviceInputStream(device: device.id, format: format, handler: { buffer, _ in
                writer.microphone(buffer)
            }, onInterrupted: {
                failed("The microphone changed or was disconnected. Recording continues with the next working microphone.", true)
            })
            return PreparedMic(device: device, silentBuiltIn: silent, stream: stream)
        }

        silentBuiltIn = prepared.silentBuiltIn
        betterMicDetected = false
        checkingBetterMic = false
        let device = prepared.device
        let microphone = prepared.stream
        self.writer = writer
        self.microphone = microphone
        log("meeting: microphone \(device.name) [\(device.transportName)]\(silentBuiltIn ? " (lid closed: silent until another microphone appears)" : "")\(includeSystem ? "" : " [in-person mic only]")")
        do {
            if includeSystem {
                let startedSystem = try await startSystemAudioSource(writer: writer, failed: failed)
                self.systemAudio = startedSystem
            } else {
                activeSystemAudioBackendName = nil
            }
            try await MeetingHALExecutor.run {
                try microphone.start()
            }
            awake = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: includeSystem ? "Recording a meeting" : "Recording an in-person meeting"
            )
        } catch {
            _ = try? await stop()
            throw error
        }
    }

    func stop() async throws -> [MeetingSegment] {
        let microphone = self.microphone, systemAudio = self.systemAudio, writer = self.writer
        self.microphone = nil; self.systemAudio = nil; self.writer = nil
        silentBuiltIn = false
        betterMicDetected = false
        checkingBetterMic = false
        activeSystemAudioBackendName = nil
        if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
        if let microphone {
            await MeetingHALExecutor.runNonThrowing {
                microphone.invalidate()
            }
        }
        var stopError: Error?
        do { try await systemAudio?.stop() } catch { stopError = error }
        let result: [MeetingSegment]
        if let writer {
            result = try await MeetingHALExecutor.run { try writer.finish() }
        } else {
            result = []
        }
        if let stopError { throw stopError }
        return result
    }
}

/// Every packet is written to disk. Only the current <= 20.3 s file is open per source.
/// The serial queue owns conversion, echo suppression, files, callbacks and the terminal state.
final class MeetingAudioWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.andre.flowclone.meeting-audio")
    private let directory: URL
    private let startedAt: Date
    private let includeSystemAudio: Bool
    private let onSegment: @Sendable (MeetingSegment) -> Void
    private let onFailure: @Sendable (String, Bool) -> Void
    private let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private struct Track { var file: AVAudioFile; var offset: Double; var count = 0 }
    private var tracks: [MeetingSource: Track] = [:]
    private var converters: [MeetingSource: AVAudioConverter] = [:]
    private var mixers: [MeetingSource: InputChannelMixer] = [:]
    private var outputScratch: [MeetingSource: AVAudioPCMBuffer] = [:]
    private var systemInputScratch: AVAudioPCMBuffer?
    private let copyPoolLock = NSLock()
    private var copyPool: [AVAudioPCMBuffer] = []
    private static let maxPooledCopyBuffers = 8
    private var nextOffsets: [MeetingSource: Double] = [:]
    private var echoSuppressor = SpeakerEchoSuppressor()
    private var closed = false
    private var failed = false
    private var finished: [MeetingSegment] = []

    init(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
         includeSystemAudio: Bool = true,
         segment: @escaping @Sendable (MeetingSegment) -> Void,
         failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) {
        self.directory = directory; self.startedAt = startedAt
        self.includeSystemAudio = includeSystemAudio
        self.nextOffsets = initialOffsets.mapValues { max(0, $0) }
        onSegment = segment; onFailure = failed
    }

    func microphone(_ input: AVAudioPCMBuffer) {
        enqueueCopy(input, source: .microphone)
    }

    func systemPCM(_ input: AVAudioPCMBuffer) {
        enqueueCopy(input, source: .system)
    }

    private func checkoutCopyBuffer(format: AVAudioFormat, minFrames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        copyPoolLock.lock()
        if let idx = copyPool.firstIndex(where: { $0.format == format && $0.frameCapacity >= minFrames }) {
            let buffer = copyPool.remove(at: idx)
            copyPoolLock.unlock()
            return buffer
        }
        copyPoolLock.unlock()
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(minFrames, 1024))
    }

    private func recycleCopyBuffer(_ buffer: AVAudioPCMBuffer) {
        copyPoolLock.lock()
        if copyPool.count < Self.maxPooledCopyBuffers {
            copyPool.append(buffer)
        }
        copyPoolLock.unlock()
    }

    private func enqueueCopy(_ input: AVAudioPCMBuffer, source: MeetingSource) {
        guard input.frameLength > 0,
              let copy = checkoutCopyBuffer(format: input.format, minFrames: input.frameLength) else { return }
        copy.frameLength = input.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (a, b) in zip(sourceBuffers, destBuffers) {
            if let src = a.mData, let dst = b.mData { memcpy(dst, src, Int(a.mDataByteSize)) }
        }
        let time = Date()
        queue.async {
            defer { self.recycleCopyBuffer(copy) }
            self.receive(copy, source: source, at: time)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        receiveSystem(sampleBuffer)
    }

    /// Queue-confined; shared by the native delegate and PCM-format acceptance tests.
    func receiveSystem(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let desc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }
        let pcm: AVAudioPCMBuffer
        if let existing = systemInputScratch, existing.format == format, existing.frameCapacity >= frameCount {
            pcm = existing
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 2048)) else { return }
            systemInputScratch = created
            pcm = created
        }
        pcm.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        guard status == noErr else { report("System audio could not be decoded (\(status))."); return }
        receive(pcm, source: .system, at: Date())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        // Stopping the capture from the macOS menu bar is the person's choice; it is not resumed.
        let chosen = (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == SCStreamError.userStopped.rawValue
        queue.async {
            self.report(chosen ? "You stopped system audio capture from the menu bar." : "System audio stopped: \(message)", resumable: !chosen)
        }
    }

    private func report(_ message: String, resumable: Bool = true) {
        guard !closed, !failed else { return }
        failed = true; onFailure(message, resumable)
    }

    private func scratchOutputBuffer(for source: MeetingSource, minCapacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let existing = outputScratch[source], existing.frameCapacity >= minCapacity {
            existing.frameLength = 0
            return existing
        }
        guard let created = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(minCapacity, 4096)) else {
            return nil
        }
        outputScratch[source] = created
        return created
    }

    private func receive(_ deviceInput: AVAudioPCMBuffer, source: MeetingSource, at time: Date) {
        guard !closed, !failed, deviceInput.frameLength > 0 else { return }
        do {
            let input = try monoInput(deviceInput, source: source)
            if converters[source]?.inputFormat != input.format {
                try flushConverter(source)
                converters[source] = AVAudioConverter(from: input.format, to: target)
            }
            let neededCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
            guard let converter = converters[source],
                  let output = scratchOutputBuffer(for: source, minCapacity: neededCapacity) else {
                throw MeetingFailure("Audio format conversion is unavailable.")
            }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            if let error { throw error }
            let offset = max(0, time.timeIntervalSince(startedAt) - Double(input.frameLength) / input.format.sampleRate)
            try append(output, source: source, offset: offset)
        } catch { report("Audio could not be saved: \(error.localizedDescription)") }
    }

    private static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private func append(_ output: AVAudioPCMBuffer, source: MeetingSource, offset: Double) throws {
        guard output.frameLength > 0 else { return }
        let effectiveOffset: Double
        if let track = tracks[source] {
            effectiveOffset = track.offset + Double(track.count) / 16000
        } else {
            let requestedOffset = max(nextOffsets[source] ?? 0, offset)
            var startMs = max(0, Int(requestedOffset * 1000))
            while Self.itemExists(at: directory.appendingPathComponent("\(source.rawValue)-\(startMs).wav")) {
                startMs += 1
            }
            let actualOffset = max(requestedOffset, Double(startMs) / 1000)
            let filename = "\(source.rawValue)-\(startMs).wav"
            let url = directory.appendingPathComponent(filename)
            let file = try AVAudioFile(forWriting: url, settings: target.settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            tracks[source] = Track(file: file, offset: actualOffset)
            effectiveOffset = actualOffset
        }
        if includeSystemAudio, let channel = output.floatChannelData?[0] {
            let frameCount = Int(output.frameLength)
            switch source {
            case .system:
                echoSuppressor.observeSystem(samples: UnsafeBufferPointer(start: channel, count: frameCount), offset: effectiveOffset)
            case .microphone:
                echoSuppressor.processMicrophone(samples: UnsafeMutableBufferPointer(start: channel, count: frameCount), offset: effectiveOffset)
            }
        }
        guard var track = tracks[source] else { return }
        try track.file.write(from: output)
        track.count += Int(output.frameLength)
        tracks[source] = track
        nextOffsets[source] = track.offset + Double(track.count) / 16000
        // Prefer a speech pause after 12 seconds; cap at 20 seconds under continuous speech.
        let tail = min(Int(output.frameLength), 1600)
        let quiet = output.floatChannelData.map { channels in
            let start = Int(output.frameLength) - tail
            return (start..<Int(output.frameLength)).allSatisfy { abs(channels[0][$0]) < 0.008 }
        } ?? false
        if track.count >= 20 * 16000 || (track.count >= 12 * 16000 && quiet) { finishTrack(source) }
    }

    /// A multi-channel microphone (USB interface, aggregate device) mixed to mono first:
    /// the converter alone keeps only channel 1 of a stereo input and turns 3+ discrete
    /// channels into silence (see `InputChannelMixer`).
    private func monoInput(_ input: AVAudioPCMBuffer, source: MeetingSource) throws -> AVAudioPCMBuffer {
        guard input.format.channelCount > 1 else { return input }
        if mixers[source]?.sourceFormat != input.format {
            mixers[source] = InputChannelMixer(sourceFormat: input.format)
        }
        if mixers[source] == nil, input.format.channelCount == 2 { return input }
        guard let mixed = mixers[source]?.mix(input) else {
            throw MeetingFailure("This microphone's audio format cannot be recorded.")
        }
        return mixed
    }

    private func flushConverter(_ source: MeetingSource) throws {
        guard let converter = converters.removeValue(forKey: source) else { return }
        guard let tail = scratchOutputBuffer(for: source, minCapacity: 4096) else { return }
        // Resamplers buffer a tail. Explicit EOF preserves the last phonemes on Stop.
        for _ in 0..<16 {
            tail.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: tail, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream; return nil
            }
            if let error { throw error }
            try append(tail, source: source, offset: nextOffsets[source] ?? 0)
            if status == .endOfStream || tail.frameLength == 0 { return }
        }
        throw MeetingFailure("Audio converter did not finish flushing.")
    }

    private func finishTrack(_ source: MeetingSource) {
        // Release AVAudioFile (and finalize its WAV header) before exposing the file to ASR.
        let segment: MeetingSegment? = {
            guard let track = tracks.removeValue(forKey: source), track.count > 0 else { return nil }
            return MeetingSegment(audioFile: track.file.url.lastPathComponent, source: source, offset: track.offset,
                                  duration: Double(track.count) / 16000)
        }()
        guard let segment else { return }
        finished.append(segment)
        onSegment(segment)
    }

    #if DEBUG
    /// Synthetic file input enters the same conversion, echo suppression, segmentation and persistence path.
    func fixture(_ buffer: AVAudioPCMBuffer, source: MeetingSource, at time: Date) {
        queue.sync { receive(buffer, source: source, at: time) }
    }
    var debugSuppressedEchoFrames: Int {
        queue.sync { echoSuppressor.suppressedFrameCount }
    }
    #endif

    func finish() throws -> [MeetingSegment] {
        try queue.sync {
            guard !closed else { return finished }
            defer { closed = true; finishTrack(.microphone); finishTrack(.system) }
            try flushConverter(.system); try flushConverter(.microphone)
            finishTrack(.system); finishTrack(.microphone)
            return finished
        }
    }
}
