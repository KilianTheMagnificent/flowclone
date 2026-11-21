import AVFoundation
import CoreAudio
import XCTest
@testable import FlowCloneCore

final class DeviceInputStreamTests: XCTestCase {
    private func floatDescription(rate: Double, channels: UInt32,
                                  nonInterleaved: Bool = false) -> AudioStreamBasicDescription {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if nonInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * (nonInterleaved ? 1 : channels)
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: flags, mBytesPerPacket: bytesPerFrame,
                                           mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                           mChannelsPerFrame: channels, mBitsPerChannel: 32,
                                           mReserved: 0)
    }

    private func format(rate: Double = 48_000, channels: UInt32 = 1) throws -> AVAudioFormat {
        try DeviceInputStream.captureFormat(for: floatDescription(rate: rate, channels: channels))
    }

    /// One IO cycle as the HAL hands it over: a single interleaved buffer for stream 0.
    private func cycle(_ samples: [Float], channels: UInt32 = 1, hostTime: UInt64,
                       into coalescer: inout InputCoalescer,
                       deliveries: inout [(samples: [Float], hostTime: UInt64)]) -> Bool {
        var samples = samples
        let accepted = samples.withUnsafeMutableBytes { bytes -> Bool in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: channels, mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress))
            var stamp = AudioTimeStamp()
            stamp.mHostTime = hostTime
            stamp.mFlags = .hostTimeValid
            return coalescer.append(&list, at: stamp) { buffer, time in
                let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
                let pointer = buffer.audioBufferList.pointee.mBuffers.mData!
                    .assumingMemoryBound(to: Float.self)
                deliveries.append((Array(UnsafeBufferPointer(start: pointer, count: count)),
                                   time.hostTime))
            }
        }
        return accepted
    }

    func testMicrophoneStreamFormatsAreAccepted() throws {
        let display = try format()
        XCTAssertEqual(display.sampleRate, 48_000)
        XCTAssertEqual(display.channelCount, 1)
        let airPods = try format(rate: 24_000)
        XCTAssertEqual(airPods.sampleRate, 24_000)
        let stereo = try format(channels: 2)
        XCTAssertTrue(stereo.isInterleaved, "A HAL stream reaches its IO proc as one interleaved buffer")
    }

    func testLayoutsTheIOProcCannotDeliverAreRefused() {
        XCTAssertThrowsError(try DeviceInputStream.captureFormat(
            for: floatDescription(rate: 48_000, channels: 2, nonInterleaved: true)))
        var compressed = floatDescription(rate: 48_000, channels: 1)
        compressed.mFormatID = kAudioFormatMPEG4AAC
        XCTAssertThrowsError(try DeviceInputStream.captureFormat(for: compressed))
        XCTAssertThrowsError(try DeviceInputStream.captureFormat(
            for: floatDescription(rate: 0, channels: 1)))
    }

    func testIOCyclesAreDeliveredInOrderAtTheOldTapCadence() throws {
        var coalescer = InputCoalescer(format: try format())
        XCTAssertEqual(coalescer.deliveryFrames, 1024, "1024 frames ≈ 21ms keeps the level meter responsive")
        var deliveries: [(samples: [Float], hostTime: UInt64)] = []
        let ramp = (0..<2048).map(Float.init)
        for index in 0..<4 {
            XCTAssertTrue(cycle(Array(ramp[(index * 512)..<((index + 1) * 512)]),
                                hostTime: UInt64(1_000 + index), into: &coalescer,
                                deliveries: &deliveries))
        }
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries.flatMap(\.samples), ramp, "Every sample arrives once, in order")
        XCTAssertEqual(deliveries.map(\.hostTime), [1_000, 1_002],
                       "A delivery is stamped with the host time of its first IO cycle")
    }

    func testOversizedCycleFlushesThePartialDeliveryWithoutDelayingItself() throws {
        var coalescer = InputCoalescer(format: try format())
        var deliveries: [(samples: [Float], hostTime: UInt64)] = []
        let head = [Float](repeating: 1, count: 300)
        let large = (0..<4096).map(Float.init)
        XCTAssertTrue(cycle(head, hostTime: 10, into: &coalescer, deliveries: &deliveries))
        XCTAssertTrue(deliveries.isEmpty)
        XCTAssertTrue(cycle(large, hostTime: 20, into: &coalescer, deliveries: &deliveries))
        XCTAssertEqual(deliveries.map(\.samples), [head, large])
        XCTAssertEqual(deliveries.map(\.hostTime), [10, 20])
    }

    func testInterleavedStereoIsCopiedFrameForFrame() throws {
        var coalescer = InputCoalescer(format: try format(channels: 2))
        var deliveries: [(samples: [Float], hostTime: UInt64)] = []
        let frames = (0..<1024).flatMap { [Float($0), -Float($0)] }
        XCTAssertTrue(cycle(frames, channels: 2, hostTime: 5, into: &coalescer,
                            deliveries: &deliveries))
        XCTAssertEqual(deliveries.map(\.samples), [frames])
    }

    func testAChangedChannelLayoutIsRefusedNotMisread() throws {
        var coalescer = InputCoalescer(format: try format())
        var deliveries: [(samples: [Float], hostTime: UInt64)] = []
        XCTAssertFalse(cycle([Float](repeating: 0.5, count: 1024), channels: 2, hostTime: 1,
                             into: &coalescer, deliveries: &deliveries),
                       "A device that changed under the IO proc must interrupt the route")
        XCTAssertTrue(deliveries.isEmpty)
    }

    func testResetDropsAPausedTail() throws {
        var coalescer = InputCoalescer(format: try format())
        var deliveries: [(samples: [Float], hostTime: UInt64)] = []
        XCTAssertTrue(cycle([Float](repeating: 9, count: 512), hostTime: 1, into: &coalescer,
                            deliveries: &deliveries))
        coalescer.reset()
        let fresh = [Float](repeating: 2, count: 1024)
        XCTAssertTrue(cycle(fresh, hostTime: 2, into: &coalescer, deliveries: &deliveries))
        XCTAssertEqual(deliveries.map(\.samples), [fresh],
                       "Keep-warm audio from before a pause must not open the next dictation")
    }

    /// AVAudioEngine re-binds its input to the system default mic whenever a default
    /// device changes, even after `setDeviceID` and while stopped. With a Bluetooth
    /// headset as that default, the headset switches to its call profile and what it
    /// plays changes volume and quality (2026-10-06, AirPods). Capture must stay on
    /// `DeviceInputStream`.
    func testRecorderDoesNotCaptureThroughAVAudioEngine() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlowClone/Recorder.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("AVAudioEngine("))
        XCTAssertFalse(text.contains("inputNode"))
        XCTAssertTrue(text.contains("DeviceInputStream("))
    }
}
