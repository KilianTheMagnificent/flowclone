// A second look at the sentences SpokenRepairs found suspicious but could not settle.
//
// The rules only delete on structural evidence, so a correction that needs understanding
// ("am permanent am a resident", "reveal review all of the tickets") is pasted as
// spoken. This file is the deterministic half of the model pass that handles those:
//
//   1. `windows` flags the suspicious sentences. Nothing else ever reaches a model, so
//      most dictations keep their speed and stay on the Mac.
//   2. A model retypes each flagged sentence (RepairReviewer.swift).
//   3. `verdict` accepts the answer only as a set of deleted words next to a flagged
//      spot. The model picks what to drop; it cannot add, reorder or reword anything.
//   4. `applying` deletes those words from the original text.
//
// Measured 2026-11-10 on the owner's 967 saved dictations: 66 are flagged (6.8%), and the
// flags cover 8 of the 9 clear corrections the rules miss
// (docs/2026-11-10-model-repairs.md).
import Foundation

enum RepairReview {
    enum Suspicion: String, Sendable, CaseIterable {
        /// A short lowercase token that is not a word: "identify f scoped fixes".
        case fragment
        /// The same word either side of one other: "am permanent am", "any in any".
        case gap
        /// Two words said again one or two words later: "Does it yo, does it work".
        case restart
        /// Two words that start alike, side by side: "reveal review".
        case similar
        /// A subject pronoun straight into a determiner: "We the maximum is two minutes".
        case odd
        /// A correction cue: "actually", "I mean", "scratch that".
        case cue

        /// How many words past the suspect its evidence runs.
        fileprivate var span: Int {
            switch self {
            case .fragment: 0
            case .odd: 1
            case .gap, .similar, .cue: 2
            case .restart: 4
            }
        }
    }

    /// What a model is trusted with. Apple's on-device model made wrong deletions on cue
    /// and replacement shapes, so it only sees stray fragments and restarts, and may only
    /// delete the fragment itself.
    enum Scope: Sendable {
        case narrow, full

        fileprivate func cap(_ kind: Suspicion) -> Int? {
            switch (self, kind) {
            case (.narrow, .fragment): 1
            case (.narrow, .restart): 4
            case (.narrow, _): nil
            case (.full, .fragment), (.full, .gap): 4
            case (.full, .restart): 6
            case (.full, .similar): 3
            case (.full, .odd): 2
            case (.full, .cue): 10
            }
        }
    }

    struct Suspect: Sendable, Hashable {
        let index: Int          // word index in the whole text
        let kind: Suspicion
        var cueWords = 0        // for a cue, how many words the cue itself is
    }

    struct Window: Sendable, Equatable {
        let lo: Int             // first and last word index in the whole text
        let hi: Int
        let text: String
        let suspects: [Suspect]
    }

    enum Verdict: Sendable, Equatable {
        case unchanged
        case delete(Set<Int>)   // word indices in the whole text
        case rejected(String)
    }

    // MARK: - Word classes

    private static let words = SpokenRepairs.words
    private static let cues: [[String]] = [
        ["excuse", "me"], ["or", "rather"], ["or", "actually"], ["or", "i", "mean"], ["or", "sorry"],
        ["scratch", "that"], ["strike", "that"], ["never", "mind"], ["no", "wait"], ["wait", "no"],
        ["i", "mean"], ["i", "meant"], ["actually"], ["let", "me", "rephrase"],
        ["let", "me", "start", "over"], ["correction"],
    ]
    /// Everyday words: a cue only with a pause before or after ("they actually do" has none).
    private static let softCues: Set<[String]> = [["actually"], ["i", "mean"], ["i", "meant"], ["correction"]]
    /// Bare "rather" is absent: after a comma it is nearly always "rather than" or "rather just".
    private static let commaCues: [[String]] = [["sorry"], ["no"], ["wait"], ["make", "that"]]
    /// "day by day", "more and more", "pixel for pixel": X Y X that is ordinary English.
    private static let gapMiddles = words("and or by for after over on to than but not vs versus")
    private static let gapSkips = words("to and of for at with by as that")
    /// Words that start alike by accident of English, not because one replaced the other.
    private static let alike = words("""
        them then than that they their there these those this think thing things through though
        thought three where when what which while whenever whether with will would could should
        about above after again project product process problem program provide
        """)
    private static let subjects = words("we i they he she")
    private static let determiners = words("the a an my our")

    // MARK: - 1. The gate

    static func suspects(in text: String, scope: Scope) -> [Suspect] {
        suspects(SpokenRepairs.tokenize(Array(text)), scope)
    }

    private static func suspects(_ toks: [SpokenRepairs.Token], _ scope: Scope) -> [Suspect] {
        let n = toks.count
        var found: [Suspect] = []
        func add(_ k: Int, _ kind: Suspicion, cueWords: Int = 0) {
            guard scope.cap(kind) != nil else { return }
            let suspect = Suspect(index: k, kind: kind, cueWords: cueWords)
            if !found.contains(suspect) { found.append(suspect) }
        }
        func sameSentence(_ i: Int, _ j: Int) -> Bool { !toks[i..<j].contains(where: \.endsSentence) }
        func matches(_ k: Int, _ cue: [String]) -> Bool {
            k + cue.count <= n && zip(toks[k..<(k + cue.count)], cue).allSatisfy { $0.low == $1 }
        }

        for k in 0..<n {
            let t = toks[k]
            if t.isAlpha, t.isLower, t.core.count <= 3, !SpokenRepairs.isWord(t.low), t.lead.isEmpty,
               !(k > 0 && toks[k - 1].core.last?.isNumber == true) {
                // A dictation cut off mid-word ("start research re") has nothing after the
                // fragment to judge it by; only the stronger model gets that call.
                if scope == .full || (k + 1 < n && !t.endsSentence) { add(k, .fragment) }
            }
            if t.isAlpha {
                if k + 2 < n, toks[k + 2].low == t.low, toks[k + 1].low != t.low, sameSentence(k, k + 2),
                   !gapMiddles.contains(toks[k + 1].low), !gapSkips.contains(t.low) {
                    add(k, .gap)
                }
                for g in [3, 4] where k + g + 1 < n {
                    let next = toks[k + 1]
                    if toks[k + g].low == t.low, toks[k + g + 1].low == next.low, next.isAlpha,
                       t.low != next.low, sameSentence(k, k + g),
                       !(gapSkips.contains(t.low) && gapSkips.contains(next.low)) {
                        add(k, .restart)
                        break
                    }
                }
            }
            for g in [1, 2] where k + g < n {
                let a = t.low, b = toks[k + g].low
                if a.count >= 4, b.count >= 4, a != b, a.prefix(3) == b.prefix(3), t.isAlpha, toks[k + g].isAlpha,
                   sameSentence(k, k + g), !a.hasPrefix(b), !b.hasPrefix(a),
                   !alike.contains(a), !alike.contains(b) {
                    add(k, .similar)
                }
            }
            if k + 1 < n, subjects.contains(t.low), determiners.contains(toks[k + 1].low), t.trail.isEmpty {
                add(k, .odd)
            }
            // A cue needs something before it to replace: "Sorry, I meant the second one"
            // answers an earlier message.
            guard k > 1 else { continue }
            if let cue = cues.first(where: { matches(k, $0) }) {
                let last = toks[k + cue.count - 1]
                let paused = !toks[k - 1].trail.isEmpty || last.trail == ","
                if (!softCues.contains(cue) || paused), !last.endsSentence { add(k, .cue, cueWords: cue.count) }
            } else if toks[k - 1].trail.hasSuffix(","), let cue = commaCues.first(where: { matches(k, $0) }) {
                add(k, .cue, cueWords: cue.count)
            }
        }
        return found
    }

    /// The flagged sentences, in order. A cue that opens a sentence brings the sentence
    /// before it along ("Send it to John. Actually, no, send it to Sarah.").
    static func windows(in text: String, scope: Scope) -> [Window] {
        let chars = Array(text)
        let toks = SpokenRepairs.tokenize(chars)
        let flagged = suspects(toks, scope)
        guard !flagged.isEmpty else { return [] }
        let n = toks.count

        var sentences: [(lo: Int, hi: Int)] = []
        var start = 0
        for k in 0..<n where toks[k].endsSentence || k == n - 1 {
            sentences.append((start, k))
            start = k + 1
        }
        var grouped: [(lo: Int, hi: Int, suspects: [Suspect])] = []
        for suspect in flagged {
            guard let j = sentences.firstIndex(where: { $0.lo <= suspect.index && suspect.index <= $0.hi }) else { continue }
            var lo = sentences[j].lo
            let hi = sentences[j].hi
            if suspect.kind == .cue, suspect.index - lo <= 3, j > 0 { lo = sentences[j - 1].lo }
            if let at = grouped.firstIndex(where: { $0.lo == lo && $0.hi == hi }) {
                grouped[at].suspects.append(suspect)
            } else {
                grouped.append((lo, hi, [suspect]))
            }
        }
        grouped.sort { ($0.lo, $0.hi) < ($1.lo, $1.hi) }

        var merged: [(lo: Int, hi: Int, suspects: [Suspect])] = []
        for group in grouped {
            for piece in boundedGroups(lo: group.lo, hi: group.hi, suspects: group.suspects) {
                if let previous = merged.last, piece.lo <= previous.hi,
                   max(previous.hi, piece.hi) - previous.lo + 1 <= maxWords {
                    merged[merged.count - 1].hi = max(previous.hi, piece.hi)
                    merged[merged.count - 1].suspects += piece.suspects.filter { !previous.suspects.contains($0) }
                } else {
                    merged.append(piece)
                }
            }
        }
        return merged.map { group in
            Window(lo: group.lo, hi: group.hi,
                   text: String(chars[toks[group.lo].start..<toks[group.hi].end]),
                   suspects: group.suspects.sorted { ($0.index, $0.kind.rawValue) < ($1.index, $1.kind.rawValue) })
        }
    }

    static let maxWords = 45

    /// Splits a flagged sentence exceeding `maxWords` into bounded windows around suspect clusters.
    private static func boundedGroups(
        lo: Int, hi: Int, suspects: [Suspect]
    ) -> [(lo: Int, hi: Int, suspects: [Suspect])] {
        let sorted = suspects.sorted { ($0.index, $0.kind.rawValue) < ($1.index, $1.kind.rawValue) }
        guard !sorted.isEmpty else { return [] }
        guard hi - lo + 1 > maxWords else { return [(lo, hi, sorted)] }
        // Keep suspects in one window only while they leave enough room (>= 22 words) for context.
        var clusters: [[Suspect]] = []
        for suspect in sorted {
            if let current = clusters.last, suspect.index - current[0].index <= 22 {
                clusters[clusters.count - 1].append(suspect)
            } else {
                clusters.append([suspect])
            }
        }
        return clusters.map { cluster in
            let first = cluster[0].index, last = cluster[cluster.count - 1].index
            var wLo = max(lo, first - 18)
            var wHi = min(hi, last + 22)
            if wHi - wLo + 1 > maxWords {
                let span = last - first + 1
                let budget = max(0, maxWords - span)
                let before = min(18, budget * 18 / 40)
                let after = budget - before
                wLo = max(lo, first - before)
                wHi = min(hi, last + after)
                if wLo == lo { wHi = min(hi, lo + maxWords - 1) }
                else if wHi == hi { wLo = max(lo, hi - maxWords + 1) }
            }
            return (wLo, wHi, cluster)
        }
    }

    // MARK: - 2. The validator

    private static func bare(_ word: Substring) -> String {
        String(word.lowercased()
            .filter { $0.isLetter || $0.isNumber })
    }

    /// Reads the model's retyped sentence as a set of deleted words, or rejects it.
    /// The answer must be the window minus whole words, with at least two words left. A
    /// deleted run counts only when it touches a flagged spot and is no longer than that
    /// flag allows; dropping just the cue ("never mind") would keep both wordings, so
    /// that does not count either. The on-device model's answer is rejected outright if
    /// any run fails; the stronger models keep their good runs. Punctuation and capitals
    /// in the answer are ignored: the model chooses words to drop, nothing else.
    static func verdict(for window: Window, in text: String, modelOutput: String, scope: Scope) -> Verdict {
        let toks = SpokenRepairs.tokenize(Array(text))
        guard window.hi < toks.count, window.lo <= window.hi else { return .rejected("stale-window") }
        let source = (window.lo...window.hi).map { bare(Substring(toks[$0].core)) }
        let live = source.indices.filter { !source[$0].isEmpty }
        let output = modelOutput.split(whereSeparator: \.isWhitespace).map(bare).filter { !$0.isEmpty }
        guard !output.isEmpty else { return .rejected("empty") }

        // Right to left, so that of two copies the earlier one is what goes.
        var kept = Set<Int>()
        var p = live.count - 1
        for word in output.reversed() {
            while p >= 0, source[live[p]] != word { p -= 1 }
            guard p >= 0 else { return .rejected("not-deletion-only") }
            kept.insert(live[p])
            p -= 1
        }
        let dead = live.filter { !kept.contains($0) }
        guard !dead.isEmpty else { return .unchanged }
        guard kept.count >= 2 else { return .rejected("too-much") }

        var runs: [[Int]] = []
        for k in dead {
            if let last = runs.last?.last, k == last + 1 { runs[runs.count - 1].append(k) } else { runs.append([k]) }
        }
        var accepted: [Int] = []
        for run in runs {
            let allowed = window.suspects.contains { suspect in
                guard let cap = scope.cap(suspect.kind), run.count <= cap else { return false }
                let at = suspect.index - window.lo
                let reach = scope == .narrow && suspect.kind == .fragment ? 0 : 1
                guard run.last! >= at - reach, run.first! <= at + suspect.kind.span + reach else { return false }
                return !(suspect.kind == .cue && run.first! >= at && run.last! < at + suspect.cueWords)
            }
            if allowed {
                accepted += run
            } else if scope == .narrow {
                return .rejected("away-from-suspect")
            }
        }
        guard !accepted.isEmpty else { return .rejected("away-from-suspect") }
        return .delete(Set(accepted.map { $0 + window.lo }))
    }

    // MARK: - 3. The edit

    /// The text without those words. A sentence-initial capital moves to the next word;
    /// every surviving character is the speaker's own.
    static func applying(_ deletions: Set<Int>, to text: String) -> String {
        let chars = Array(text)
        var toks = SpokenRepairs.tokenize(chars)
        let n = toks.count
        guard !deletions.isEmpty, deletions.allSatisfy({ $0 >= 0 && $0 < n }), deletions.count < n else { return text }
        var runs: [ClosedRange<Int>] = []
        for k in deletions.sorted() {
            if let last = runs.last, k == last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...k
            } else {
                runs.append(k...k)
            }
        }
        var inheritedTail: [Int: String] = [:]
        for run in runs {
            let capital = SpokenRepairs.transfersSentenceCapital(deleting: run, in: toks, chars: chars)
            let lastDeleted = toks[run.upperBound]
            let carriesHardEnd = lastDeleted.endsHardSentence
            let deletedPunctEnd: String = {
                guard carriesHardEnd else { return "" }
                let coreEnd = lastDeleted.start + lastDeleted.lead.count + lastDeleted.core.count
                guard coreEnd < lastDeleted.end else { return "" }
                return String(chars[coreEnd..<lastDeleted.end])
            }()
            for k in run { toks[k].dead = true }
            var next = run.upperBound + 1
            while next < n, toks[next].dead { next += 1 }
            if capital, next < n { toks[next].takeCapital() }
            if !deletedPunctEnd.isEmpty {
                var prev = run.lowerBound - 1
                while prev >= 0, toks[prev].dead { prev -= 1 }
                if prev >= 0, !toks[prev].endsHardSentence {
                    inheritedTail[prev] = deletedPunctEnd
                }
            }
        }
        var out = String(chars[0..<toks[0].start])
        var prevLive: Int?
        for (index, t) in toks.enumerated() where !t.dead {
            if let prevLive {
                let gap = SpokenRepairs.survivingGap(after: prevLive, before: index, chars: chars, tokens: toks)
                out.append(contentsOf: chars[gap])
            }
            prevLive = index
            let tokenEnd: Int
            if inheritedTail[index] != nil {
                var trimEnd = t.end
                while trimEnd > t.start + t.lead.count + t.core.count,
                      ",;:".contains(chars[trimEnd - 1]) {
                    trimEnd -= 1
                }
                tokenEnd = trimEnd
            } else {
                tokenEnd = t.end
            }
            if t.capitalized, let capital = t.core.first {
                let at = t.start + t.lead.count
                out.append(contentsOf: chars[t.start..<at])
                out.append(capital)
                out.append(contentsOf: chars[(at + 1)..<tokenEnd])
            } else {
                out.append(contentsOf: chars[t.start..<tokenEnd])
            }
            if let extraTail = inheritedTail[index] {
                out.append(contentsOf: extraTail)
            }
        }
        out.append(contentsOf: chars[toks[n - 1].end..<chars.count])
        return out
    }
}
