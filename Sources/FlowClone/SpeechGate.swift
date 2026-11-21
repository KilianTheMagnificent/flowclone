// Energy gate before ASR: a held key with no speech must produce nothing — short
// non-speech recordings are exactly where ASR models invent "yeah"/"okay".
// Pure function over the 16kHz session buffer; costs microseconds per utterance.
// ponytail: energy-only heuristic, no VAD model — Silero via FluidAudio is the
// upgrade path if breathy near-silence ever slips through.
import Accelerate
import Foundation

enum SpeechGate {
    /// Upper bound on the estimated 10th-percentile noise floor (-26 dBFS, raised from
    /// -45 dBFS so -35 dBFS ambient rooms and high-gain USB mics still detect silence
    /// and compact interior pauses properly without treating constant loud speech as noise).
    static let maxNoiseFloorDB: Float = -26
    private static let previewMaxThresholdDB: Float = -26.5

    static func threshold(for db: [Float]) -> Float {
        guard !db.isEmpty else { return -50 }
        return floorAndThreshold(forRawFloor: db.sorted()[db.count / 10]).threshold
    }

    private static func floorAndThreshold(forRawFloor rawFloor: Float) -> (floor: Float, threshold: Float) {
        if rawFloor > maxNoiseFloorDB {
            // ≥90% of windows exceed -26 dBFS: continuous speech/audio with no quiet pause to
            // anchor p10, so cap both floor and threshold at -26 dBFS instead of demanding -14 dBFS.
            return (maxNoiseFloorDB, maxNoiseFloorDB)
        }
        return (rawFloor, max(-50, rawFloor + 12))
    }

    /// 100ms windows. Noise floor = 10th-percentile window (capped at -26dBFS so
    /// constant loud speech is never its own floor while -35dBFS rooms stay gated);
    /// speech = ≥2 windows above max(-50dBFS, floor + 12dB) — one lone window is a key click.
    static func containsSpeech(_ samples: [Float], rate: Double = 16_000) -> Bool {
        analyze(samples, rate: rate).speech
    }

    /// Preview-only gate over a short trailing snapshot. A 200ms pause often precedes
    /// key-up; leave the decoder idle then. Final transcription never uses this gate.
    /// Short 1s active-speech windows have no leading silence to anchor p10, so cap
    /// the preview threshold at -26.5 dBFS while still rejecting -35 dBFS room noise.
    static func hasRecentSpeech(_ samples: [Float]) -> Bool {
        guard let analysis = windows(samples) else { return false }
        let previewThreshold = min(analysis.threshold, previewMaxThresholdDB)
        return analysis.db.suffix(2).contains { $0 > previewThreshold }
    }

    /// 100ms window energies in dBFS and the speech threshold derived from them.
    static func windows(_ samples: [Float], rate: Double = 16_000) -> (db: [Float], threshold: Float)? {
        guard let analysis = windowAnalysis(samples, rate: rate) else { return nil }
        return (analysis.db, analysis.threshold)
    }

    private static func windowAnalysis(_ samples: [Float], rate: Double)
        -> (db: [Float], floor: Float, threshold: Float)? {
        let win = Int(rate / 10)
        guard samples.count >= win * 2 else { return nil }
        var dbs: [Float] = []
        var i = 0
        while i + win <= samples.count {
            var rms: Float = 0
            samples.withUnsafeBufferPointer { p in
                vDSP_rmsqv(p.baseAddress! + i, 1, &rms, vDSP_Length(win))
            }
            dbs.append(20 * log10(rms + 1e-10))
            i += win
        }
        let derived = floorAndThreshold(forRawFloor: dbs.sorted()[dbs.count / 10])
        return (dbs, derived.floor, derived.threshold)
    }

    static func analyze(_ samples: [Float], rate: Double = 16_000) -> (speech: Bool, detail: String) {
        // Short words never filled the old two-window minimum. Require five consecutive
        // 20ms frames of energy so a short click still cannot qualify as speech.
        if samples.count < Int(rate / 5), samples.count >= Int(rate / 10) {
            let sustained = hasSustainedEnergy(samples, rate: rate, minimumRMS: 0.0032)
            return (sustained, sustained ? "short sustained audio" : "short audio without sustained energy")
        }
        guard let analysis = windowAnalysis(samples, rate: rate) else {
            return (false, "audio shorter than 2 windows")
        }
        let dbs = analysis.db
        let floor = analysis.floor
        let threshold = analysis.threshold
        let hot = dbs.lazy.filter { $0 > threshold }.count
        let detail = String(format: "peak %.1fdB floor %.1fdB thr %.1fdB %d/%d windows",
                            dbs.max() ?? -100, floor, threshold, hot, dbs.count)
        // A short word does not become silence when key-up adds padding across the
        // 200ms boundary. Keep the measured adaptive noise threshold and the existing
        // two-window path, but also accept the same sustained 100ms used above. A lone
        // click (including one straddling a frame boundary) cannot fill five frames.
        let sustained = hot < 2 && hasSustainedEnergy(samples, rate: rate,
            minimumRMS: 0.0032, adaptive: true)
        return (hot >= 2 || sustained, detail + (sustained ? " sustained short word" : ""))
    }

    private static func hasSustainedEnergy(_ samples: [Float], rate: Double,
                                            minimumRMS: Float, adaptive: Bool = false) -> Bool {
        let frame = max(1, Int(rate / 50))
        guard samples.count >= frame * 5 else { return false }
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frame)
        for start in stride(from: 0, through: samples.count - frame, by: frame) {
            var rms: Float = 0
            samples.withUnsafeBufferPointer {
                vDSP_rmsqv($0.baseAddress! + start, 1, &rms, vDSP_Length(frame))
            }
            energies.append(rms)
        }
        // Estimate this fallback's floor at its own resolution. With only two coarse
        // windows, a word straddling their boundary otherwise becomes its own noise floor.
        let floor = adaptive ? pow(10, threshold(for: energies.map { 20 * log10($0 + 1e-10) }) / 20) : 0
        let minimum = max(minimumRMS, floor)
        var run = 0
        for rms in energies {
            run = rms > minimum ? run + 1 : 0
            if run >= 5 { return true }
        }
        return false
    }

    /// Retry preserves deliberate low-energy captures without automatically transcribing
    /// silence or treating a quick hands-free tap as a failed dictation.
    static func shouldRetainForRetry(_ samples: [Float], heldSeconds: Double?) -> Bool {
        let deliberate = samples.count >= 6_400 || (heldSeconds ?? 0) >= 0.4
        return samples.count >= 1_600 && deliberate && samples.contains { abs($0) > 0.0001 }
    }
}
