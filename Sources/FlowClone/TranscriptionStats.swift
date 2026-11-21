import Foundation

/// Persistent aggregate only: no transcript text or per-dictation records leave memory.
enum TranscriptionStats {
    private static let totalWordsKey = "totalWordsTranscribed"
    private static let totalSecondsKey = "totalSecondsTranscribed"

    static var totalWords: Int {
        totalWords(in: .standard)
    }

    static func totalWords(in defaults: UserDefaults) -> Int {
        max(0, defaults.integer(forKey: totalWordsKey))
    }

    static var totalSeconds: Double {
        totalSeconds(in: .standard)
    }

    static func totalSeconds(in defaults: UserDefaults) -> Double {
        let value = defaults.double(forKey: totalSecondsKey)
        return value.isFinite ? max(0, value) : 0
    }

    static func seedTotalSeconds(atLeast floor: Double, in defaults: UserDefaults = .standard) {
        guard floor.isFinite, floor > 0 else { return }
        if floor > totalSeconds(in: defaults) {
            defaults.set(floor, forKey: totalSecondsKey)
        }
    }

    static func formatSpeakingTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        let total = max(1, Int(seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours == 0 {
            return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
        }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    static func record(_ text: String, seconds: Double = 0, origin: DictationOrigin) {
        record(text, seconds: seconds, origin: origin, defaults: .standard)
    }

    static func record(_ text: String, seconds: Double = 0, origin: DictationOrigin, defaults: UserDefaults) {
        guard origin.contributesTranscribedWords else { return }
        let added = wordCount(in: text)
        guard added > 0 else { return }

        let current = totalWords(in: defaults)
        let next = current > Int.max - added ? Int.max : current + added
        defaults.set(next, forKey: totalWordsKey)

        let addedSeconds = seconds.isFinite ? max(0, seconds) : 0
        let currentSeconds = totalSeconds(in: defaults)
        let nextSeconds = currentSeconds + addedSeconds
        let persistedSeconds: Double
        if addedSeconds > 0, nextSeconds.isFinite {
            defaults.set(nextSeconds, forKey: totalSecondsKey)
            persistedSeconds = nextSeconds
        } else {
            persistedSeconds = currentSeconds
        }
        log(String(format: "transcription stats: +%d words, total=%d, +%.1fs, speaking=%.1fs",
                   added, next, addedSeconds, persistedSeconds))
    }
}
