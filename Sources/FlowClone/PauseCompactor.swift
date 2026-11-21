// Long silences inside a dictation are thinking time, not punctuation. Parakeet treats a
// multi-second silence as a sentence end even mid-clause ("So I was thinking we could.
// Maybe try a different library."). Shortening every interior silence to `maxPause`
// before decoding leaves the model a normal pause and its own grammar to punctuate with.
//
// Measured 2026-11-08 (work/pause-eval, two macOS voices, 12 mid-clause + 4 real sentence
// breaks): mid-clause pauses of 2.0 / 3.5 s put a period inside the clause in 4/24 and 6/24
// decodes; capped at 0.4, 0.6 or 0.8 s, 0/24 and 0/24. Real sentence breaks kept their
// period in every case, and word errors fell (0.40% → 0.23%).
//
// Pure function over the 16 kHz session buffer, reusing SpeechGate's 100 ms windows and
// noise-relative threshold. Only silence BETWEEN speech is shortened; leading and trailing
// silence, and anything above the threshold, is never removed.
import Foundation

enum PauseCompactor {
    /// Silence kept at each interior pause, split evenly across both sides of the cut so
    /// a soft word ending or onset adjacent to speech is never trimmed.
    static let maxPause: Double = 0.8
    /// 5 ms linear blend across each splice; both sides are below the speech threshold.
    private static let crossfadeSamples = 80

    struct Result: Equatable {
        let samples: [Float]
        let pausesShortened: Int
        let removedSeconds: Double
    }

    static func compact(_ samples: [Float], rate: Double = 16_000,
                        maxPause: Double = maxPause) -> Result {
        let unchanged = Result(samples: samples, pausesShortened: 0, removedSeconds: 0)
        guard maxPause > 0, let analysis = SpeechGate.windows(samples, rate: rate) else {
            return unchanged
        }
        let window = Int(rate / 10)
        let keep = max(2, Int((maxPause * 10).rounded()))
        let quiet = analysis.db.map { $0 <= analysis.threshold }
        var cuts: [Range<Int>] = []
        var i = 0
        while i < quiet.count {
            guard quiet[i] else { i += 1; continue }
            var j = i
            while j < quiet.count, quiet[j] { j += 1 }
            // Interior only: an analysed speech window on both sides of the run.
            if i > 0, j < quiet.count, j - i > keep {
                let head = keep / 2
                cuts.append((i + head) * window ..< (j - (keep - head)) * window)
            }
            i = j
        }
        guard !cuts.isEmpty else { return unchanged }

        let removed = cuts.reduce(0) { $0 + $1.count }
        var out: [Float] = []
        out.reserveCapacity(samples.count - removed)
        var cursor = 0
        for cut in cuts {
            out.append(contentsOf: samples[cursor..<cut.lowerBound])
            // Blend the end of the kept head into the samples that precede the kept tail.
            let fade = min(crossfadeSamples, cut.count, out.count)
            for k in 0..<fade {
                let t = Float(k + 1) / Float(fade + 1)
                let index = out.count - fade + k
                out[index] = out[index] * (1 - t) + samples[cut.upperBound - fade + k] * t
            }
            cursor = cut.upperBound
        }
        out.append(contentsOf: samples[cursor...])
        return Result(samples: out, pausesShortened: cuts.count,
                      removedSeconds: Double(removed) / rate)
    }
}
