@preconcurrency import AVFoundation
import FluidAudio
import Foundation

actor NemotronDecoder: StreamingSpeechDecoder {
    private let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms560)

    func load(progress: @Sendable @escaping (String) -> Void) async throws {
        progress("loading Nemotron Streaming (560 ms)")
        let throttle = ModelProgressThrottle()
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: { value in
            if case .downloading(let done, let total) = value.phase, total > 0, throttle.fire(done) {
                progress("downloading Nemotron model \(done)/\(total) files")
            }
        })
        guard await manager.config.chunkMs == 560 else { throw DecoderError.wrongChunkSize }
        // Warm encoder, recurrent decoder, and final padding without opening a microphone.
        try await append(Array(repeating: 0, count: 9_600))
        _ = try await finish()
        await reset()
    }

    func reset() async { await manager.reset() }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw DecoderError.invalidBuffer }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input in
            if let base = input.baseAddress { channel.update(from: base, count: input.count) }
        }
        _ = try await manager.process(audioBuffer: buffer)
    }

    func partial() async -> String { await manager.getPartialTranscript() }
    func finish() async throws -> String { try await manager.finish() }
    private enum DecoderError: Error { case invalidBuffer, wrongChunkSize }
}
