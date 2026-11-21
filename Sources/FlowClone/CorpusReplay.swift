import Foundation
import FluidAudio
import AVFoundation
import Darwin

/// Opt-in local files only. No microphone, target capture, paste, History or learning.
enum CorpusReplay {
    struct Entry: Decodable {
        let id: String
        let audio: String
        let mode: String
        /// Explicit diagnostic opt-in to inspect ASR hallucinations behind a failed gate.
        let decodeGatedAudio: Bool?
        /// Interior-pause cap in seconds, for A/B runs. Absent = the dictation default
        /// (PauseCompactor.maxPause); 0 = decode the audio exactly as recorded.
        let maxPauseSeconds: Double?
    }
    private static let cleanupQueue = DispatchQueue(label: "com.andre.flowclone.replay.cleanup")
    enum ReplayError: Error { case invalidManifest, outputExists, invalidAudio, modelUnavailable }

    static func run(input: URL, output: URL) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 5_000_000 else {
            throw ReplayError.invalidManifest
        }
        let lines = try String(contentsOf: input, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard !lines.isEmpty, lines.count <= 200 else { throw ReplayError.invalidManifest }
        let entries = try lines.map { try JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
        guard Set(entries.map(\.id)).count == entries.count,
              // "polish" is a retired mode that older manifests still carry; it replays as Clean.
              entries.allSatisfy({ (Mode(rawValue: $0.mode) != nil || $0.mode == "polish") && !$0.id.isEmpty }) else {
            throw ReplayError.invalidManifest
        }
        // Exclusive descriptor: a typo cannot replace a prior result or follow a symlink.
        let fd = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ReplayError.outputExists }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let transcriber = Transcriber()
        guard await transcriber.ensureLoaded(progress: { log("CORPUS model \($0)") }) else {
            throw ReplayError.modelUnavailable
        }
        let executableHash = executableSHA256Prefix()
        for (index, entry) in entries.enumerated() {
            let audioURL = entry.audio.hasPrefix("/") ? URL(fileURLWithPath: entry.audio)
                : input.deletingLastPathComponent().appendingPathComponent(entry.audio)
            let file = try AVAudioFile(forReading: audioURL)
            guard file.processingFormat.sampleRate > 0,
                  Double(file.length) / file.processingFormat.sampleRate <= 300 else { throw ReplayError.invalidAudio }
            let samples = try AudioConverter().resampleAudioFile(audioURL)
            let started = DispatchTime.now()
            let gate = samples.count >= 1_600 && SpeechGate.containsSpeech(samples)
            var outcome = Transcriber.Outcome.failed(attempts: 0)
            if gate || entry.decodeGatedAudio == true {
                let cap = entry.maxPauseSeconds ?? PauseCompactor.maxPause
                outcome = await transcriber.transcribe(samples, maxAttempts: 2,
                                                       maxPause: cap > 0 ? cap : nil)
            }
            let decoded = DispatchTime.now()
            let raw = outcome.text ?? ""
            let cleaned = await withCheckedContinuation { continuation in
                cleanupQueue.async { continuation.resume(returning: Cleaner.clean(raw)) }
            }
            var final = entry.mode == "raw" ? raw : cleaned
            var effective = entry.mode == "raw" ? "raw" : "clean"
            // A legacy "polish" entry replays as Clean, what that selection runs today.
            if entry.mode == "prompt", !cleaned.isEmpty, Prompter.eligible(cleaned), Prompter.ready() {
                let rewritten: String? = await withCheckedContinuation { continuation in
                    Prompter.promptify(cleaned) { text, _ in continuation.resume(returning: text) }
                }
                if let rewritten { final = rewritten; effective = "prompt" }
            }
            if effective == "clean" { final = SmartFormat.autoList(final) }
            var fields: [String: Any] = [
                "id": entry.id, "mode": entry.mode, "effective_mode": effective,
                "raw": raw, "cleaned": cleaned, "final": gate ? final : "", "candidate_final": final,
                "evaluation_path": entry.decodeGatedAudio == true ? "decode_gated_audio" : "gate_then_asr",
                "gate_passed": gate, "audio_seconds": Double(samples.count) / Recorder.sampleRate,
                "asr_ms": ms(started, decoded), "total_ms": ms(started, .now()),
                "fallback": entry.mode != effective, "asr_model": transcriber.engine.modelID,
                "fluidaudio": SpeechEngine.fluidAudioVersion, "exec_sha256": executableHash,
                "os": ProcessInfo.processInfo.operatingSystemVersionString
            ]
            if case .success(_, _, let metadata) = outcome, let metadata {
                fields["decoder_raw"] = metadata.decoderText
                fields["unknown_tokens"] = metadata.unknownTokenCount
                // Token timing shows where punctuation lands relative to pauses.
                fields["tokens"] = metadata.tokens.map {
                    ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any]
                }
            }
            var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            data.append(0x0a)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            log("CORPUS completed \(index + 1)/\(entries.count)")
        }
        log("CORPUS PASS rows=\(entries.count) (text latency only; no paste or microphone)")
    }
}
