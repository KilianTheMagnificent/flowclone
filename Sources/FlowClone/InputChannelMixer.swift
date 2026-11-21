// Reduces a multi-channel microphone stream to the one mono signal the recognizer takes.
//
// AVAudioConverter alone does not do this usefully: from a stereo input it keeps only the
// first channel (with or without `downmix`, a voice on input 2 arrives at half level or
// not at all), and from a discrete 3+ channel input it produces silence. So a USB audio
// interface with the microphone in input 2, or any 4-, 8- or 18-input interface, recorded
// nothing. Measured 2026-11-21 with AVAudioConverter on macOS 27.3.
//
// Each delivery averages the channels that carry signal: those within 12 dB of the loudest
// (power smoothed over a few deliveries). An unused input's noise does not dilute the
// microphone, and a stereo microphone keeps its level.
import Accelerate
import AVFoundation

struct InputChannelMixer {
    enum SampleKind { case float32, int16, int32 }

    let sourceFormat: AVAudioFormat
    let monoFormat: AVAudioFormat
    private let kind: SampleKind
    private var smoothedPower: [Float]
    private var primed = false
    private var scratch: [Float] = []
    private var output: AVAudioPCMBuffer?

    /// A channel joins the mix when its power is within 12 dB of the loudest channel's.
    static let inclusionPowerRatio: Float = 0.0625
    /// Weight kept from earlier deliveries (~21 ms each): about a 40 ms time constant.
    static let smoothing: Float = 0.6

    /// nil for mono input (nothing to mix) and for sample layouts it cannot read.
    init?(sourceFormat: AVAudioFormat) {
        guard sourceFormat.channelCount > 1, sourceFormat.isInterleaved,
              let kind = Self.sampleKind(sourceFormat),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sourceFormat.sampleRate,
                                       channels: 1, interleaved: false) else { return nil }
        self.sourceFormat = sourceFormat
        self.monoFormat = mono
        self.kind = kind
        smoothedPower = [Float](repeating: 0, count: Int(sourceFormat.channelCount))
    }

    static func sampleKind(_ format: AVAudioFormat) -> SampleKind? {
        switch format.commonFormat {
        case .pcmFormatFloat32: return .float32
        case .pcmFormatInt16: return .int16
        case .pcmFormatInt32: return .int32
        default: return nil
        }
    }

    /// A new capture on a warm route starts from no channel history.
    mutating func reset() {
        primed = false
        for index in smoothedPower.indices { smoothedPower[index] = 0 }
    }

    /// Which channels the next mix uses, given each channel's smoothed power.
    static func includedChannels(power: [Float]) -> [Int] {
        guard let loudest = power.max(), loudest > 0 else { return [0] }
        let threshold = loudest * inclusionPowerRatio
        return power.indices.filter { power[$0] >= threshold }
    }

    /// The mono buffer for one interleaved delivery. The returned buffer is reused by the
    /// next call; the converter consumes it before that.
    mutating func mix(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(input.frameLength)
        let channels = Int(sourceFormat.channelCount)
        guard frames > 0, input.format.channelCount == sourceFormat.channelCount,
              let raw = input.audioBufferList.pointee.mBuffers.mData else { return nil }
        if output == nil || Int(output!.frameCapacity) < frames {
            output = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                      frameCapacity: AVAudioFrameCount(max(frames, 2048)))
        }
        guard let output, let destination = output.floatChannelData?[0] else { return nil }
        let count = frames * channels
        if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
        // Borrowed out of `self` so the closure below may update the channel history.
        var work: [Float] = []
        swap(&work, &scratch)
        defer { swap(&work, &scratch) }

        return work.withUnsafeMutableBufferPointer { scratchBuffer -> AVAudioPCMBuffer? in
            guard let scratchBase = scratchBuffer.baseAddress else { return nil }
            let samples: UnsafePointer<Float>
            switch kind {
            case .float32:
                samples = UnsafePointer(raw.assumingMemoryBound(to: Float.self))
            case .int16:
                vDSP_vflt16(raw.assumingMemoryBound(to: Int16.self), 1, scratchBase, 1, vDSP_Length(count))
                var scale = Float(1.0 / 32_768.0)
                vDSP_vsmul(scratchBase, 1, &scale, scratchBase, 1, vDSP_Length(count))
                samples = UnsafePointer(scratchBase)
            case .int32:
                vDSP_vflt32(raw.assumingMemoryBound(to: Int32.self), 1, scratchBase, 1, vDSP_Length(count))
                var scale = Float(1.0 / 2_147_483_648.0)
                vDSP_vsmul(scratchBase, 1, &scale, scratchBase, 1, vDSP_Length(count))
                samples = UnsafePointer(scratchBase)
            }

            for channel in 0..<channels {
                var power: Float = 0
                vDSP_measqv(samples + channel, vDSP_Stride(channels), &power, vDSP_Length(frames))
                smoothedPower[channel] = primed
                    ? smoothedPower[channel] * Self.smoothing + power * (1 - Self.smoothing)
                    : power
            }
            primed = true

            let included = Self.includedChannels(power: smoothedPower)
            vDSP_vclr(destination, 1, vDSP_Length(frames))
            for channel in included {
                vDSP_vadd(samples + channel, vDSP_Stride(channels), destination, 1,
                          destination, 1, vDSP_Length(frames))
            }
            var share = 1 / Float(included.count)
            vDSP_vsmul(destination, 1, &share, destination, 1, vDSP_Length(frames))
            output.frameLength = AVAudioFrameCount(frames)
            return output
        }
    }
}
