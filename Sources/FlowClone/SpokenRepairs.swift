// Spoken self-repairs for Clean: the words a speaker abandons mid-sentence are dropped
// before the text is pasted. Deterministic and token-based, so it costs no latency and
// never needs the model.
//
// Measured 2026-11-09 on the owner's 967 saved dictations (54 labelled self-corrections,
// docs/2026-11-09-self-corrections.md): explicit cue phrases are rare. The real shapes are
// broken-off word fragments ("you've c completed"), doubled words ("Are are you"),
// restarted phrases, and a few cues ("on dev excuse me on main", "20 years, or actually
// 10 years"). Apple's on-device model fixed none of the cue cases and damaged other words
// when given whole dictations, so these rules run first and alone on most dictations;
// RepairReview.swift takes a model's second look at the few sentences they flag.
//
// Every rule deletes whole words. The only other edit moves a sentence-initial capital
// onto the first surviving word. Each rule needs structural evidence in the sentence
// itself; a correction that needs understanding ("am permanent am a resident") is
// left exactly as spoken.
import Foundation

enum SpokenRepairs {
    enum Rule: String {
        case fragment, modal, cueRetrace = "cue-retrace", cueSwap = "cue-swap", phrase, doubled, scratch
    }

    struct Result {
        let text: OriginText
        let rules: [Rule]
    }

    static func apply(_ text: String) -> String { apply(OriginText(text)).text.text }

    // MARK: - Word classes

    static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    private static let determiners = words(
        "a an the one this that these those my your our their his her its some any each every")
    /// Words a speaker restarts on. Doubling one of these is not grammatical, unlike
    /// "that that", "had had", "is is", "this this way" or "log in in the morning", except
    /// for the `phraseEnders` below.
    private static let stutter = words("""
        the a an and but if because when i we they she you my your our their are am were be been
        have has should would could must to of with from into onto it what which who where how
        why just also then as than
        """)
    /// A comma between the copies is a hesitation only when the word cannot end a clause:
    /// "to you, you clarify" is two clauses.
    private static let commaOK = words("the a an and but i we they she my your our their if because")
    private static let numbers = words("""
        zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen
        fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy
        eighty ninety hundred thousand million billion
        """)
    /// "on and on and on", "step by step by step", "day after day after day".
    private static let coordinators = words("and or by after over nor")
    private static let modals = words("would should could")
    /// A lone letter between two of these is a pair of names: "a and b and c".
    private static let letterPairs = words("and or of to as than a plus minus times")
    /// Words that introduce a letter used as a name: "for n", "let k", "vitamin d".
    private static let introduces = words("""
        a an the our your my this that of to for with in by from over into at on and or as than
        if when where let is are be equals call set take choose pick plus minus times modulo per
        mod versus vs so then but such both either type vitamin plan option grade class series
        letter section part point step variable version group team phase level tier appendix
        exhibit figure column row drive key press hit note model hepatitis big capital lowercase
        uppercase vector matrix function constant parameter value
        """)
    /// A repair that restarts on one of these re-says the phrase: "on dev excuse me on main".
    private static let anchors = words("""
        the a an my your our their his her its this that these those to on in at for with from
        by of into onto about under over after before
        """)
    /// A one-word repair never replaces one of these.
    private static let light = stutter.union(determiners).union(anchors).union(words("""
        he him her them me us is was do not no yes so here there now too very really all both
        more most much many
        """))

    /// Cues that are corrections wherever they stand mid-sentence.
    private static let strongCues: [[String]] = [
        ["excuse", "me"], ["or", "i", "should", "say"], ["or", "i", "mean"],
        ["or", "rather"], ["or", "actually"], ["or", "sorry"],
    ]
    /// Cues with everyday uses ("by that I mean the settings"): only after a comma.
    /// Bare "actually" is absent on purpose: 28 of the owner's 29 uses replaced nothing.
    private static let weakCues: [[String]] = [
        ["i", "mean"], ["i", "meant"], ["make", "that"], ["no", "wait"], ["wait", "no"],
        ["sorry"], ["no"], ["wait"],
    ]
    private static let retraceOnly: Set<String> = ["no", "wait"]
    /// Words that double legitimately when the first copy ends a phrase: "did I tell you
    /// you were right", "the ones that are are fine", "the tools we have have bugs". Their
    /// doubling is a stutter only where a clause starts: "You you can", "and are are you".
    private static let phraseEnders = words("you it are were have has")
    private static let clauseOpeners = words("and but or so because if when")

    // MARK: - Tokens

    struct Token {
        let start: Int
        let end: Int
        let lead: String
        var core: String
        let trail: String
        let low: String
        var dead = false
        var capitalized = false

        init(_ chars: [Character], _ start: Int, _ end: Int, breakAfter: Bool) {
            self.start = start
            self.end = end
            func wordy(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
            var a = start
            while a < end, !wordy(chars[a]) { a += 1 }
            var b = end
            if a < end { while b > a, !wordy(chars[b - 1]) { b -= 1 } }
            lead = String(chars[start..<a])
            core = String(chars[a..<b])
            // A line break ends the sentence just as a period does.
            trail = String(chars[b..<end]) + (breakAfter ? "\n" : "")
            low = core.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        }

        var plain: Bool { lead.isEmpty && trail.isEmpty }
        /// "p.m.," is an abbreviation before a comma, not a sentence end.
        var endsSentence: Bool { trail.last != "," && trail.contains(where: { ".!?;:\n".contains($0) }) }
        var endsHardSentence: Bool { trail.last != "," && trail.contains(where: { ".!?".contains($0) }) }
        var softComma: Bool { trail == "," || trail == ".," }
        var isAlpha: Bool { !core.isEmpty && core.allSatisfy(\.isLetter) }
        var isLower: Bool { core.contains(where: \.isLowercase) && !core.contains(where: \.isUppercase) }
        var startsUpper: Bool { core.first?.isUppercase == true }
        var startsNumber: Bool { core.first?.isNumber == true }
        var commaOrNothing: Bool { trail.isEmpty || trail == "," }

        /// Takes over a deleted sentence start's capital, unless the lowercase start is
        /// deliberate (iPhone), the same test Cleaner uses after a leading filler.
        mutating func takeCapital() {
            guard let first = core.first, first.isLowercase,
                  !core.dropFirst().contains(where: \.isUppercase) else { return }
            let upper = String(first).uppercased()
            guard upper.count == 1 else { return }
            core = upper + core.dropFirst()
            capitalized = true
        }
    }

    static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var end = i
            while end < chars.count, !chars[end].isWhitespace { end += 1 }
            var gap = end
            var breakAfter = false
            while gap < chars.count, chars[gap].isWhitespace {
                if chars[gap].isNewline { breakAfter = true }
                gap += 1
            }
            tokens.append(Token(chars, i, end, breakAfter: breakAfter))
            i = end
        }
        return tokens
    }

    static func isWord(_ low: String) -> Bool {
        switch low.count {
        case 1: return low == "a"
        case 2: return shortWords2.contains(low)
        case 3: return shortWords3.contains(low)
        default: return true
        }
    }

    /// Preserves `\n` / `\n\n` paragraph breaks across deleted token runs while keeping exact anchors.
    static func survivingGap(after prevLive: Int, before current: Int,
                             chars: [Character], tokens: [Token]) -> Range<Int> {
        let fallback = tokens[current - 1].end..<tokens[current].start
        guard prevLive < current - 1 else { return fallback }
        var best = fallback
        var bestNewlines = 0
        for m in prevLive..<current {
            let candidate = tokens[m].end..<tokens[m + 1].start
            let newlines = chars[candidate].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            if newlines > bestNewlines {
                best = candidate
                bestNewlines = newlines
            }
        }
        return best
    }

    /// True when deleting `run` leaves the next surviving token at a sentence start that
    /// should receive an initial capital.
    static func transfersSentenceCapital(deleting run: ClosedRange<Int>,
                                         in toks: [Token], chars: [Character]) -> Bool {
        var prevLive = run.lowerBound - 1
        while prevLive >= 0, toks[prevLive].dead { prevLive -= 1 }
        let newlineBeforeNext: Bool = {
            guard prevLive >= 0 else { return false }
            let limit = min(toks.count - 1, run.upperBound + 1)
            guard prevLive < limit else { return false }
            return (prevLive..<limit).contains { m in
                chars[toks[m].end..<toks[m + 1].start].contains("\n")
            }
        }()
        let sentenceStart = prevLive < 0 || toks[prevLive].endsSentence || newlineBeforeNext
        guard sentenceStart else { return false }
        let anySentenceUpper = run.contains { k in
            let atStart = k == run.lowerBound ? sentenceStart : toks[k - 1].endsSentence
            return atStart && toks[k].startsUpper
        }
        if anySentenceUpper { return true }
        if prevLive >= 0, toks[prevLive].endsHardSentence { return true }
        if prevLive < 0, !toks[run.lowerBound].isLower,
           run.dropLast().contains(where: { toks[$0].endsHardSentence }) {
            return true
        }
        return false
    }

    // MARK: - The pass

    static func apply(_ input: OriginText) -> Result {
        let chars = Array(input.text)
        var toks = tokenize(chars)
        let n = toks.count
        guard n >= 2 else { return Result(text: input, rules: []) }
        var rules: [Rule] = []

        /// Deleted words are skipped, so a word that inherits a sentence start knows it.
        func sentenceStart(_ i: Int) -> Bool {
            var j = i - 1
            while j >= 0, toks[j].dead {
                if toks[j].endsSentence { return true }
                j -= 1
            }
            return j < 0 || toks[j].endsSentence
        }
        func live(_ i: Int) -> Bool { i >= 0 && i < n && !toks[i].dead }
        /// Deletes words lo...hi. A sentence-initial capital moves to the next word.
        func kill(_ lo: Int, _ hi: Int, _ rule: Rule) {
            let capital = transfersSentenceCapital(deleting: lo...hi, in: toks, chars: chars)
            for k in lo...hi { toks[k].dead = true }
            var next = hi + 1
            while next < n, toks[next].dead { next += 1 }
            if capital, next < n { toks[next].takeCapital() }
            rules.append(rule)
        }

        // 1. Broken-off word fragments: a short token that is not a word.
        // A dictation that names two letters ("x and y") is talking about letters.
        let letters = Set(toks.filter { $0.core.count == 1 && $0.isLower && $0.low != "a" }.map(\.low))
        let spelling = letters.count >= 2
        for k in 0..<n {
            let t = toks[k]
            guard !t.dead, t.plain, t.isAlpha, t.isLower, t.core.count <= 3, !isWord(t.low) else { continue }
            // "13.6 s after the start" is a unit.
            if k > 0, toks[k - 1].core.last?.isNumber == true { continue }
            let single = t.core.count == 1
            if single, spelling { continue }
            // (a) The speaker completes the word within the next few words.
            var hit: Int?
            var j = k + 1
            while j < min(n, k + 1 + (single ? 3 : 4)) {
                let w = toks[j]
                if w.low.hasPrefix(t.low), w.low.count >= max(3, t.low.count + 2), w.isAlpha {
                    hit = j
                    break
                }
                if w.endsSentence { break }
                j += 1
            }
            if let hit {
                // "for a f with a fix", "a p one pane": the restart re-says the word before
                // the fragment, so the words it replaced go too.
                let leadIn = hit - k - 1
                var lo = k
                if (1...2).contains(leadIn), k - leadIn >= 0 {
                    let before = toks[k - 1].low, restart = toks[hit - 1].low
                    let same = before == restart || (determiners.contains(before) && determiners.contains(restart))
                    if same, toks[(k - leadIn)..<k].allSatisfy({ $0.plain && !$0.dead }) { lo = k - leadIn }
                }
                // A lone letter is usually a name ("n numbers", "f using the formula"). It is
                // a fragment only when the very next word completes it and nothing
                // introduces it, or when the speaker visibly restarted the phrase.
                if single, lo == k,
                   hit != k + 1 || k == 0 || introduces.contains(toks[k - 1].low) || !toks[k - 1].trail.isEmpty {
                    continue
                }
                kill(lo, k, .fragment)
                continue
            }
            // (b) The speaker restarts on the word before it: "into s into".
            if k > 0, k + 1 < n, live(k - 1), toks[k - 1].plain, toks[k - 1].low == toks[k + 1].low,
               stutter.contains(toks[k - 1].low), !(single && letterPairs.contains(toks[k - 1].low)) {
                kill(k, k, .fragment)
            }
        }

        // 2. Two different modals in a row: the second replaces the first.
        for k in 0..<(n - 1) where live(k) && live(k + 1) {
            let a = toks[k], b = toks[k + 1]
            if modals.contains(a.low), modals.contains(b.low), a.low != b.low, a.plain, b.lead.isEmpty {
                kill(k, k, .modal)
            }
        }

        // 3. A cue, then the replacement.
        func matchesCue(_ i: Int, _ cue: [String]) -> Bool {
            guard i + cue.count <= n else { return false }
            for (d, word) in cue.enumerated() {
                let t = toks[i + d]
                if t.dead || t.low != word || !t.lead.isEmpty || !t.commaOrNothing { return false }
            }
            return true
        }
        var i = 1
        while i < n {
            var found: (cue: [String], strong: Bool)?
            if !sentenceStart(i), live(i - 1) {
                if let cue = strongCues.first(where: { matchesCue(i, $0) }) {
                    found = (cue, true)
                } else if toks[i - 1].softComma, let cue = weakCues.first(where: { matchesCue(i, $0) }) {
                    // A bare "sorry", "no" or "wait" is a cue only when set off by commas:
                    // "to dev, sorry, to main". Without the second comma it starts a phrase
                    // of its own: "sorry for the delay", "no to the second", "wait for me".
                    if cue.count > 1 || toks[i].softComma { found = (cue, false) }
                }
            }
            guard let (cue, strong) = found else { i += 1; continue }
            let end = i + cue.count - 1
            let r0 = end + 1
            if r0 >= n || toks[r0].dead || (cue.last == "rather" && toks[r0].low == "than") {
                i += 1
                continue
            }
            // "I meant to write sooner" and "make that the priority" are ordinary phrases,
            // not a cue followed by a restart.
            let intent = (cue.last == "mean" || cue.last == "meant") && toks[end].trail.isEmpty
                && (toks[r0].low == "to" || toks[r0].low == "for")
            let makeThat = cue == ["make", "that"] && determiners.contains(toks[r0].low)
            if intent || makeThat {
                i = end + 1
                continue
            }
            // The repair runs to the next punctuation mark.
            var rEnd = r0
            while rEnd < n - 1, toks[rEnd].trail.isEmpty { rEnd += 1 }
            let bounded = !toks[rEnd].trail.isEmpty || rEnd == n - 1
            let length = rEnd - r0 + 1
            let before = toks[i - 1]
            var done = false
            // (a) The repair restarts on a word already said: delete from there through the
            // cue. Never from a sentence start: "To be clear, I mean to say…" is no repair.
            if anchors.contains(toks[r0].low), before.trail.isEmpty || before.softComma {
                var j = i - 2
                while j >= 0, j > i - 6 {
                    if toks[j].dead || !toks[j].plain { break }
                    if toks[j].low == toks[r0].low {
                        if !sentenceStart(j) {
                            kill(j, end, .cueRetrace)
                            done = true
                        }
                        break
                    }
                    j -= 1
                }
            }
            // (b) A one- or two-word repair replaces the same number of words.
            if !done, bounded, before.commaOrNothing, before.lead.isEmpty {
                let one = toks[r0]
                if length == 1, !retraceOnly.contains(cue.joined(separator: " ")) {
                    // A weak cue only swaps two names: "to Alice, I mean Sarah".
                    if strong || (before.startsUpper && one.startsUpper),
                       before.startsUpper == one.startsUpper, before.startsNumber == one.startsNumber,
                       !light.contains(before.low), !light.contains(one.low),
                       i - 1 > 0, !sentenceStart(i - 1) {
                        kill(i - 1, end, .cueSwap)
                    }
                } else if length == 2, strong, i - 2 >= 0, toks[i - 2].plain, !toks[i - 2].dead,
                          !sentenceStart(i - 2), before.low == toks[rEnd].low, toks[i - 2].low != one.low {
                    // "20 years, or actually 10 years": the shared word frames the swap.
                    kill(i - 2, end, .cueSwap)
                }
            }
            i = end + 1
        }

        // 4. A restarted phrase: "The prep we the prep we were given". The sentence has to
        // go on after the second copy, which "I know, I know." does not.
        for size in [4, 3, 2] {
            var k = 0
            while k + 2 * size < n {
                let a = Array(toks[k..<(k + size)]), b = Array(toks[(k + size)..<(k + 2 * size)])
                let lows = a.map(\.low)
                let restarted = (a + b).allSatisfy { !$0.dead }
                    && lows == b.map(\.low)
                    && Set(lows).count > 1
                    && a.allSatisfy(\.isAlpha)
                    && !lows.contains(where: { numbers.contains($0) || coordinators.contains($0) })
                    && a.dropLast().allSatisfy(\.plain) && b.dropLast().allSatisfy(\.plain)
                    && b[0].lead.isEmpty && a[size - 1].lead.isEmpty
                    && (a[size - 1].trail.isEmpty || (size >= 3 && a[size - 1].trail == ","))
                    && b[size - 1].trail.isEmpty
                    && (size >= 3 || stutter.contains(lows[0]))
                if restarted {
                    kill(k, k + size - 1, .phrase)
                    k += size
                } else {
                    k += 1
                }
            }
        }

        // 5. A doubled function word: "the the", "Are are", "I, I".
        for k in 0..<(n - 1) {
            let a = toks[k]
            guard !a.dead, stutter.contains(a.low), a.lead.isEmpty, a.commaOrNothing else { continue }
            if a.trail == ",", !commaOK.contains(a.low) { continue }
            if phraseEnders.contains(a.low) {
                var p = k - 1
                while p >= 0, toks[p].dead { p -= 1 }
                let opensClause = p < 0 || toks[p].endsSentence || toks[p].softComma
                    || (toks[p].trail.isEmpty && clauseOpeners.contains(toks[p].low))
                if !opensClause { continue }
            }
            var j = k + 1
            while j < n, toks[j].dead { j += 1 }
            if j < n, toks[j].low == a.low, toks[j].lead.isEmpty { kill(k, k, .doubled) }
        }

        // 6. "Scratch that" throws away the sentence in progress. With fewer than three
        // words before it, it is about an earlier message and stays.
        if n >= 3 {
            for k in 1..<(n - 1) {
                guard toks[k].low == "scratch", toks[k + 1].low == "that", !toks[k].dead, toks[k].plain,
                      toks[k + 1].trail == "," || toks[k + 1].trail == ".",
                      !toks[k - 1].trail.isEmpty, k + 2 < n else { continue }
                var lo = k - 1
                while lo > 0, !toks[lo - 1].endsSentence { lo -= 1 }
                guard toks[lo..<k].filter({ !$0.dead }).count >= 3 else { continue }
                var next = k + 2
                while next < n, toks[next].dead { next += 1 }
                guard next < n else { continue }
                for d in lo...(k + 1) { toks[d].dead = true }
                toks[next].takeCapital()
                rules.append(.scratch)
            }
        }

        guard !rules.isEmpty, toks.contains(where: { !$0.dead }) else { return Result(text: input, rules: []) }

        // Rebuild from the surviving words, each with the whitespace that preceded it, so
        // every kept character keeps its raw-transcript anchor.
        var text = String(chars[0..<toks[0].start])
        var origins = Array(input.origins[0..<toks[0].start])
        var prevLive: Int?
        for (index, t) in toks.enumerated() where !t.dead {
            if let prevLive {
                let gap = survivingGap(after: prevLive, before: index, chars: chars, tokens: toks)
                text.append(contentsOf: chars[gap])
                origins.append(contentsOf: input.origins[gap])
            }
            prevLive = index
            if t.capitalized, let capital = t.core.first {
                let at = t.start + t.lead.count
                text.append(contentsOf: chars[t.start..<at])
                text.append(capital)
                text.append(contentsOf: chars[(at + 1)..<t.end])
            } else {
                text.append(contentsOf: chars[t.start..<t.end])
            }
            origins.append(contentsOf: input.origins[t.start..<t.end])
        }
        let tail = toks[n - 1].end..<chars.count
        text.append(contentsOf: chars[tail])
        origins.append(contentsOf: input.origins[tail])
        return Result(text: OriginText(text: text, origins: origins), rules: rules)
    }

    // MARK: - Short words

    // A lowercase token of up to three letters that is in neither list is a fragment
    // candidate. The lists only protect: a word missing here is still never deleted
    // without the structural evidence above. Sources: the public-domain Webster's Second
    // word list, plus short words and abbreviations that occur ten or more times in 18M
    // words of local prose. "re" is left out on purpose ("the re the true waveform").
    private static let shortWords2 = words("""
        ad ah ai al am an as at ax be bp by cd ci cm co cp db de do dp ed eh em et ex fn ft gb gh go
        ha he hi hm ho hr hz id if ii in ip is it js kb kg km la lb ln ls ma mb me mi ml mm mo ms mv
        my no of oh ok on op or os ow ox oz pa pc pi pm pp pr ps pt px py qa qc rb rc rm sh so tb to
        ts tv uh ui um up us uv ux vh vm vs we ya ye yo
        """)

    private static let shortWords3 = words("""
        aal aam aba abb abu aby ace ach act add ade ado ads ady adz aer aes aft aga age ago agy aha
        aho ahu aid ail aim air ait aka ake ako aku ala alb ale alf alk all aln alo alp alt aly ama
        ame ami amp amt amy ana and ani ann ant any apa ape api app apt apx ara arb arc are arg ark
        arm arn art aru arx ary ase ash ask asp asr ass ast ate auh auk aum ava ave avg avo awa awd
        awe awl awn aws aww axe aye ayu azo baa bac bad bae bag bah bal bam ban bap bar bas bat baw
        bay bed bee beg bel ben ber bes bet bey bib bid big bin bis bit biz blo boa bob bod bog bom
        bon boo bop bor bot bow box boy bpc bps bra btn btw bub bud bug bum bun bur bus but buy bye
        cab cad cag cal cam can cap car cat caw cay cdn cee cel ceo cep cfg cfo cha che chi cho cig
        cit cli cly cmd cob cod coe cog col con coo cop cor cos cot cow cox coy coz cpu cro cry css
        csv cta cto cub cud cue cum cup cur cut cwd cwm cyp dab dad dae dag dah dak dal dam dan dao
        dap dar das daw day deb ded dee def deg den dep dev dew dey dha dhu dib did die dig dim din
        dip dir dis dit div diy dmg dns dob doc dod doe dog dom don dop dor dos dot dow dpi dry dub
        dud due dug dum dun duo dup dux dye ean ear eat ebb edh eel eer eft egg ego eke elb eld elf
        elk ell elm els elt eme emu end ens env eon era erd ere erg err ers ess est eta etc eve ewe
        exe eye eyn fad fae fag fam fan faq far fat fax fay fed fee fei fen fet feu few fey fez fib
        fid fie fig fin fip fir fit fix flu fly fmt fob fod foe fog foo fop for fot fou fow fox foy
        fps fra fro fry fub fud fug fum fun fur fut fyi gab gad gag gaj gal gam gan gap gar gas gat
        gau gaw gay gaz gcp ged gee gel gem gen geo ger get gey gez gib gid gie gif gig gim gin gio
        gip git gnu goa gob god gog goi gol gon goo gor gos got goy gpt gpu gra grr gud gue gui gul
        gum gun gup gur gut guy guz gym gyn gyp had hag hah hak ham han hao hap has hat hau haw hay
        hei hem hen hep her het hew hex hey hia hic hid hie him hin hip his hit hmm hob hoc hod hoe
        hog hoi hop hot how hox hoy hub hud hue hug huh hum hup hut hyp iao iba ice ich icy ide idk
        ids ife iff ihi iii ilk ill img imi imp imu ing ink inn int ion ios ipa ire irk irl ism iso
        ist its iva ivy iwa iyo jab jag jam jap jar jaw jay jed jet jib jig job joe jog jot jow joy
        jpg jud jug jut kai kan kat kay kea keb ked kef keg ken kep ket kex key khu kid kil kim kin
        kip kit koa kob koi kon kop kor kos kou kra kyl lab lac lad lag lai lak lam lan lap lar las
        lat law lax lay lea led lee leg lei lek let leu lev lew ley lib lid lie lim lin lip lis lit
        llm loa lob lod lof log lol loo lop lot low lox loy lue lug lum lut lux lye lys mac mad mae
        mag mal man mao map mar mas mat mau maw max may mcp meh mel mem men met mew mho mib mic mid
        mig mil mim min mir mix mob mod mog mon moo mop mor mot mou mow moy mud mug mum mun mux naa
        nab nae nag nah nak nam nan nap nar nat nav naw nay nea neb nee nef nei neo nep net new nib
        nid nig nil nim nip nit nix nlp noa nob nod nog non nor not now noy npm npx nth nub nul num
        nun nut nye oaf oak oam oar oat obe obi obs och ock ocr oda odd ode ods oer oes off oft ohm
        oho oii oil oka oki old olm omg ona one ons ooh ope ops opt ora orb orc ore orf org ort ory
        ose ouf our out ova owd owe owk owl own oxy pac pad pah pal pam pan pap par pat pau paw pax
        pay pdf pea ped pee peg pen pep per pes pet pew phi pho phu pia pic pid pie pig pik pin pip
        pir pit pix pkg ply png pob pod poe poh poi pol pom pon pop pot pow pox poy pre pro pry psi
        pst pts pua pub pud pug pul pun pup pur pus put pya pyr pyx qua quo rab rad rag rah raj ram
        ran rap ras rat raw rax ray rea reb red ree ref reg reh rel rep req res ret rev rex rhe rho
        ria rib rid rie rig rim rio rip rit rix rob roc rod roe rog roi rot row rox rub rud rue rug
        rum run rut rux rye saa sab sac sad sag sah sai saj sal sam san sao sap sar sat saw sax say
        sdk sea sec see seg sen ser set sew sex sey sha she shi sho shy sib sic sie sig sil sim sin
        sip sir sis sit six ski sky sla sly sma sny sob soc sod soe sog soh sok sol son sop sot sou
        sov sow soy spa spy sql src sri ssh ssl ssu std str sty sub sud sue sum sun sup sur suz svg
        swa sye taa tab tad tae tag tai taj tal tam tan tao tap tar tat tau tav taw tax tay tba tbd
        tch tck tcp tea tec ted tee teg ten tew tez tha the tho thy tib tic tid tie tig til tin tip
        tit tji tls tmp toa tod toe tog toi tok tol tom ton too top tor tot tou tow tox toy tra tri
        try tsc tst tsv tsx tts tua tub tue tug tui tum tun tup tur tut tux twa two tye tyg tyt ubi
        udo udp ugh uid uji uke ula ule ull ulu ume ump umu upo ura urd ure urf url urn usb use ush
        ust uta utu uva vag van var vas vat vau vee vei vet vex via vid vie vim vis voe vog vol vow
        vpn vug vum wab wad wae wag wah wan wap war was wat waw wax way wcp web wed wee wem wen wer
        wet wey wha who why wid wig wim win wip wir wis wit wiz wob wod woe wog wok won woo wop wot
        wow woy wro wry wud wun wup wur wut wye wyn xml yad yah yak yam yan yap yar yas yat yaw yay
        yea yed yee yen yeo yep yer yes yet yew yex yez yin yip yis yml yoe yoi yok yom yon yor yot
        you yow yox yoy yuh yus zac zad zag zak zar zat zax zed zee zel zer zig zip zoa zoo zsh
        """)
}
