import Accelerate
import AVFoundation
import CoreAudio
import XCTest
@testable import FlowCloneCore

/// Multi-channel microphones: USB interfaces (mic in input 2, 4/8/18 inputs), aggregate
/// devices. Before the mixer, input 2 of a stereo interface converted to silence and any
/// 3+ channel device was refused outright.
final class InputChannelMixerTests: XCTestCase {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!

    private func description(channels: UInt32, int16: Bool = false,
                             rate: Double = 48_000) -> AudioStreamBasicDescription {
        let bytes = UInt32(int16 ? 2 : 4)
        let flags = (int16 ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat)
            | kAudioFormatFlagIsPacked
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: flags, mBytesPerPacket: bytes * channels,
                                           mFramesPerPacket: 1, mBytesPerFrame: bytes * channels,
                                           mChannelsPerFrame: channels, mBitsPerChannel: bytes * 8,
                                           mReserved: 0)
    }

    /// One interleaved device buffer: a 440 Hz tone of `amplitude` on `active` channels.
    private func buffer(_ format: AVAudioFormat, active: Set<Int>, amplitude: Float = 0.5,
                        frames: Int = 4_800) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        let data = buffer.audioBufferList.pointee.mBuffers.mData!
        for frame in 0..<frames {
            let value = amplitude * sin(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate))
            for channel in 0..<channels {
                let sample = active.contains(channel) ? value : 0
                if format.commonFormat == .pcmFormatInt16 {
                    data.assumingMemoryBound(to: Int16.self)[frame * channels + channel] =
                        Int16(sample * 32_767)
                } else {
                    data.assumingMemoryBound(to: Float.self)[frame * channels + channel] = sample
                }
            }
        }
        return buffer
    }

    /// RMS of the 16 kHz mono signal the recognizer would receive from `input`.
    private func recognizerRMS(_ format: AVAudioFormat, _ inputs: [AVAudioPCMBuffer]) throws -> Float {
        let (converter, initialMixer) = try XCTUnwrap(Recorder.makeConversion(from: format, to: target))
        var mixer = initialMixer
        var samples: [Float] = []
        for input in inputs {
            let source = mixer == nil ? input : try XCTUnwrap(mixer?.mix(input))
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096)!
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return source
            }
            XCTAssertNil(error)
            samples += Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        XCTAssertFalse(samples.isEmpty)
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    private let toneRMS = Float(0.5) / Float(2).squareRoot()

    func testMonoMicrophonesKeepTheDirectConverterPath() throws {
        let mono = try DeviceInputStream.captureFormat(for: description(channels: 1))
        let conversion = try XCTUnwrap(Recorder.makeConversion(from: mono, to: target))
        XCTAssertNil(conversion.1, "A mono microphone must not gain a mixing stage")
        XCTAssertEqual(try recognizerRMS(mono, [buffer(mono, active: [0])]), toneRMS, accuracy: 0.02)
    }

    func testStereoInterfaceWithTheMicrophoneInInputTwoIsHeard() throws {
        let stereo = try DeviceInputStream.captureFormat(for: description(channels: 2))
        XCTAssertEqual(try recognizerRMS(stereo, [buffer(stereo, active: [1])]), toneRMS, accuracy: 0.02,
                       "Input 2 alone must arrive at full level, not as silence")
        XCTAssertEqual(try recognizerRMS(stereo, [buffer(stereo, active: [0])]), toneRMS, accuracy: 0.02)
        XCTAssertEqual(try recognizerRMS(stereo, [buffer(stereo, active: [0, 1])]), toneRMS, accuracy: 0.02,
                       "A stereo microphone keeps its level")
    }

    func testInterfacesWithManyInputsAreAcceptedAndHeard() throws {
        for (channels, active) in [(3, 2), (4, 0), (4, 3), (8, 5), (18, 17)] {
            let format = try DeviceInputStream.captureFormat(for: description(channels: UInt32(channels)))
            XCTAssertEqual(format.channelCount, AVAudioChannelCount(channels))
            XCTAssertEqual(try recognizerRMS(format, [buffer(format, active: [active])]), toneRMS,
                           accuracy: 0.02, "\(channels) inputs, microphone in input \(active + 1)")
        }
    }

    func testIntegerSamplesAreMixedToo() throws {
        let format = try DeviceInputStream.captureFormat(for: description(channels: 2, int16: true))
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(try recognizerRMS(format, [buffer(format, active: [1])]), toneRMS, accuracy: 0.02)
    }

    func testOnlyChannelsNearTheLoudestJoinTheMix() {
        XCTAssertEqual(InputChannelMixer.includedChannels(power: [0, 0]), [0], "Silence reads channel 1")
        XCTAssertEqual(InputChannelMixer.includedChannels(power: [1e-9, 0.1]), [1],
                       "An unused input's noise does not dilute the microphone")
        XCTAssertEqual(InputChannelMixer.includedChannels(power: [0.1, 0.08, 0.001]), [0, 1])
    }

    func testRecorderCapturesFromAFourInputInterface() throws {
        let format = try DeviceInputStream.captureFormat(for: description(channels: 4))
        let queue = DispatchQueue(label: "flowclone.test.multichannel")
        let samples: [Float] = try queue.sync {
            let recorder = Recorder(queue: queue, idleDelay: 30)
            let stream = try XCTUnwrap(recorder.beginSimulatedCaptureForTest(inputFormat: format))
            let input = buffer(format, active: [2], frames: 2_048)
            var abl = input.audioBufferList.pointee
            var stamp = AudioTimeStamp()
            stamp.mHostTime = 1_000
            stamp.mFlags = .hostTimeValid
            stream.handleInput(&abl, at: &stamp)
            return recorder.end(drainTail: true)
        }
        XCTAssertGreaterThan(samples.count, 600)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.4,
                             "Speech in input 3 of a 4-input interface reaches the recognizer")
    }

    func testMeetingRecordsTheMicrophoneOfAnEightInputInterface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = MeetingAudioWriter(directory: root, startedAt: Date(), includeSystemAudio: false,
                                        segment: { _ in }, failed: { message, _ in XCTFail(message) })
        let format = try DeviceInputStream.captureFormat(for: description(channels: 8))
        for _ in 0..<10 { writer.microphone(buffer(format, active: [6])) }
        let segment = try XCTUnwrap(try writer.finish().first { $0.source == .microphone })
        let file = try AVAudioFile(forReading: root.appendingPathComponent(segment.audioFile))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        var rms: Float = 0
        vDSP_rmsqv(pcm.floatChannelData![0], 1, &rms, vDSP_Length(pcm.frameLength))
        XCTAssertEqual(rms, toneRMS, accuracy: 0.05, "Input 7 of 8 is what the meeting recording holds")
    }
}
