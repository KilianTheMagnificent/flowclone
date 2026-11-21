// Smart Formatting (RESEARCH.md §1): spoken punctuation/quote commands, and Wispr's
// cursor-position awareness — a dictation that continues a half-typed sentence joins it
// instead of starting a new one.
// Pure functions, so SmartFormatTests needs no AX and no mic. The AX read that produces
// `prefix` is a bounded parameterized range read in AXTextContext; everything here runs on
// the session queue like the rest of the cleanup chain.
import Foundation

enum SmartFormat {

    // MARK: - Spoken punctuation

    /// ponytail: bare "quote" is deliberately NOT a command — "a famous quote by…" is far
    /// more common in dictation than someone saying "quote" to open one. Upgrade path if it
    /// ever matters: only honour it utterance-initially or right after a comma.
    /// Quote commands: word-bounded anywhere. Parakeet rarely emits these by accident, and
    /// the self-test relies on a mid-sentence "unquote" closing a dictated quote, so these
    /// are deliberately NOT position-gated (see M7 note below).
    private static let quoteCommands: [(String, String)] = [
        ("(?:open|begin)\\s+quote", "\""),
        ("(?:(?:close|end)\\s+quote|unquote)", "\""),
    ]

    /// redteam M7: "new line"/"new paragraph" are commands only utterance-initially, after a
    /// comma, or after a sentence terminator. Mid-sentence they are the speaker's own words
    /// ("Add a new line to the config file.") and must not be deleted. A terminator has to be
    /// a valid left edge too — the comma-or-boundary rule alone regresses the after-period
    /// self-test ("Wrap up. New paragraph. Next topic").
    private static let breakCommands: [(String, String)] = [
        ("new\\s+paragraph", "\n\n"),
        ("new\\s+line", "\n"),
    ]

    /// F5: the two utterance-final terminators, plus the explicit position-free inserts.
    /// Finals only fire at the end of the utterance ("Are you coming question mark" → "?",
    /// but "The question mark is optional" is the speaker's own words) and absorb the `.`/`,`
    /// the ASR drops on either side of the spoken command.
    /// ponytail (audit A-4): bare "period"/"full stop" are deliberately NOT commands — position
    /// alone can't separate "call me tomorrow period" from "the Jurassic period", the same
    /// false-positive logic that keeps bare "quote" out above. Only the explicit "insert …"
    /// forms convert, and bare "em dash" never does. Edges are bespoke (a `$` anchor, a
    /// lookahead that leaves the following space alone), so these skip compileCmd.
    private static let f5Commands: [(String, String)] = [
        ("[ \\t]*[,.]?[ \\t]*\\bquestion\\s+mark\\b[ \\t]*[,.]?[ \\t]*$", "?"),
        ("[ \\t]*[,.]?[ \\t]*\\bexclamation\\s+(?:point|mark)\\b[ \\t]*[,.]?[ \\t]*$", "!"),
        ("[ \\t]*\\binsert\\s+(?:period|full\\s+stop)\\b[.,]?(?=[ \\t]|$)", "."),
        ("[ \\t]*\\binsert\\s+em\\s+dash\\b[.,]?[ \\t]*", "\u{2014}"),
    ]

    /// Leading eats the comma the ASR puts before the command; the trailing side eats a
    /// comma, or a period only when more text follows it — an utterance-final period after
    /// "unquote" is the speaker's sentence, not ASR punctuation around the command.
    /// `gated` restricts the left edge to start-of-string / comma / sentence terminator.
    private static func compileCmd(_ pat: String, gated: Bool) -> NSRegularExpression {
        let lead = gated ? "(?:^[ \\t]*|[ \\t]*,[ \\t]*|(?<=[.!?])[ \\t]*)" : "[ \\t]*,?[ \\t]*"
        return try! NSRegularExpression(
            pattern: "(?i)\(lead)\\b\(pat)\\b[ \\t]*(?:,|\\.(?=[ \\t]))?[ \\t]*")
    }

    /// F5 runs last: the finals anchor to `$`, so the break commands must already have
    /// consumed any trailing "new line" the ASR put after the spoken terminator.
    private static let compiled: [(NSRegularExpression, String)] =
        quoteCommands.map { (compileCmd($0.0, gated: false), $0.1) }
        + breakCommands.map { (compileCmd($0.0, gated: true), $0.1) }
        + f5Commands.map { (try! NSRegularExpression(pattern: "(?i)" + $0.0), $0.1) }

    /// "he said, open quote, hello" → "he said \"hello". Case-insensitive, word-boundary.
    static func spokenPunctuation(_ text: String) -> String {
        spokenPunctuation(OriginText(text)).text
    }

    /// Cleaner uses this overload so later dictionary substitutions retain their exact raw
    /// encounter positions through removed punctuation commands and quote-space hygiene.
    static func spokenPunctuation(_ input: OriginText) -> OriginText {
        var value = input
        for (rx, out) in compiled {
            value = value.replacingMatches(
                of: rx, withTemplate: NSRegularExpression.escapedTemplate(for: out)
            )
        }
        return quoteHygiene(value)
    }

    /// Spoken repairs between two values of one closed class ("Thursday, I mean Friday",
    /// "2 p.m., actually 3 p.m.", "March, no wait, April") keep the second value. Zero
    /// latency, every non-Raw mode, and it covers the on-device model's measured blind
    /// spot (2026-09-12: it never applied a weekday correction in any cue form). Open
    /// vocabulary ("Alice, I mean Sarah") is `SpokenRepairs`' job; discourse uses stay.
    /// ponytail: digits only; "two, make that three" is a spelled-number pair the model handles.
    private static let closedClasses = [
        #"(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"#,
        #"(?:january|february|march|april|may|june|july|august|september|october|november|december)"#,
        #"\d+(?:[.,:]\d+)*(?:\s*(?:a\.?m\.?|p\.?m\.?))?"#,
    ]
    private static let repairCue =
        #"(?:actually,? make that|actually,? i mean|or rather|or actually|or i mean|excuse me|make that|i mean|i meant|actually|no wait|wait no|scratch that|correction)"#
    private static let closedClassRepairs: [NSRegularExpression] = closedClasses.map {
        try! NSRegularExpression(pattern: #"(?i)\b"# + $0 + #"[,.]?\s+"# + repairCue + #",?\s+(?="# + $0 + #"\b)"#)
    }

    static func spokenCorrections(_ input: OriginText) -> OriginText {
        spokenRepairs(input).text
    }

    /// The closed-class swaps above, then the abandoned words `SpokenRepairs` can prove
    /// from the sentence itself (fragments, doubled words, restarts, cue repairs). The
    /// rule names come back so the Pipeline can log what fired without logging text.
    static func spokenRepairs(_ input: OriginText) -> SpokenRepairs.Result {
        SpokenRepairs.apply(closedClassRepairs.reduce(input) { $0.replacingMatches(of: $1, withTemplate: "") })
    }

    private static func word(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// No space just inside a quote, one space where a word abuts the outside of one.
    /// Open/close is decided by toggling, so an utterance that ends inside a quote leaves it
    /// open — the user may keep dictating into it.
    /// ponytail: the toggle can't tell a quotation mark from an inch mark (`a 5" pipe`);
    /// Parakeet almost never emits a bare `"`, and the alternative is a real parser.
    private static func quoteHygiene(_ input: OriginText) -> OriginText {
        let s = input.text
        var out = ""
        var origins: [Int] = []
        var open = false
        var i = s.startIndex
        var offset = 0
        while i < s.endIndex {
            guard s[i] == "\"" else {
                out.append(s[i])
                origins.append(input.origins[offset])
                i = s.index(after: i)
                offset += 1
                continue
            }
            let quoteOrigin = input.origins[offset]
            i = s.index(after: i)
            offset += 1
            if open {
                while let l = out.last, l == " " || l == "\t" {
                    out.removeLast()
                    origins.removeLast()
                }
                out.append("\"")
                origins.append(quoteOrigin)
                if i < s.endIndex, word(s[i]) {
                    out.append(" ")
                    origins.append(quoteOrigin)
                }
            } else {
                if let l = out.last, word(l) || ",;:".contains(l) {
                    out.append(" ")
                    origins.append(quoteOrigin)
                }
                out.append("\"")
                origins.append(quoteOrigin)
                while i < s.endIndex, s[i] == " " || s[i] == "\t" {
                    i = s.index(after: i)
                    offset += 1
                }
            }
            open.toggle()
        }
        return OriginText(text: out, origins: origins)
    }

    // MARK: - Auto lists

    private static let ordinalWords = ["one", "two", "three", "four", "five", "six",
                                       "seven", "eight", "nine", "ten"]

    /// F6: "My top goals this week are one finish the report two send the presentation" →
    /// "My top goals this week are:" + a numbered line per item. The highest false-positive
    /// risk in the formatter, so the trigger is narrow (review F-10): a lead-in ending in
    /// "are"/"is"/"following"/":" must sit immediately before marker one, the markers must
    /// ascend from one (spelled or ITN-digit), and each must introduce ≥2 words. No lead-in is
    /// never a list, whatever the marker count.
    /// Ordering: Clean mode only, so the Pipeline calls this after the Prompt branch (the model
    /// does its own shaping) and before `continuation`, which joins the finished shape to cursor.
    /// ponytail: single-line utterances only — the rewrite rejoins tokens on spaces, so an
    /// utterance that already carries a "new line" break is left alone rather than flattened.
    static func autoList(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let toks = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func core(_ t: String) -> String {
            t.lowercased().trimmingCharacters(in: .alphanumerics.inverted)
        }
        func marker(_ t: String, _ n: Int) -> Bool {
            let c = core(t)
            return c == String(n) || (n <= ordinalWords.count && c == ordinalWords[n - 1])
        }
        guard let start = toks.firstIndex(where: { marker($0, 1) }), start > 0 else { return text }
        let colonLeadIn = toks[start - 1].hasSuffix(":")
        guard colonLeadIn
                || ["are", "is", "following"].contains(core(toks[start - 1])) else { return text }
        var marks = [start]
        for i in (start + 1)..<toks.count where marker(toks[i], marks.count + 1) { marks.append(i) }
        // A spoken ":" is the speaker's own list marker, so two items are enough. A word
        // lead-in is not: "The plan is one thing today and two things tomorrow." has the
        // same shape and is a sentence, so an unpunctuated list has to prove itself with a
        // third ascending marker.
        guard marks.count >= (colonLeadIn ? 2 : 3) else { return text }

        var items: [String] = []
        for (k, m) in marks.enumerated() {
            let words = toks[(m + 1)..<(k + 1 < marks.count ? marks[k + 1] : toks.count)]
            // A marker introducing fewer than two words is a number, not a list marker ("one
            // two three Main Street", "one to two millimeters"); "one of the things…" is a
            // quantifier. Either kills the whole rewrite — a half-list is worse than none.
            guard words.count >= 2, core(words.first!) != "of" else { return text }
            var item = words.joined(separator: " ")
            // The utterance's own terminator isn't part of a list line; "?"/"!" are.
            while let l = item.last, l == "." || l == "," { item.removeLast() }
            items.append(sentenceCase(item))
        }
        var head = toks[..<start].joined(separator: " ")
        while let l = head.last, ",;:.".contains(l) { head.removeLast() }
        return ([head + ":"] + items.enumerated().map { "\($0.offset + 1). \($0.element)" })
            .joined(separator: "\n")
    }

    /// Capitalize a list item — but not one that is deliberately lowercase-initial (iPhone),
    /// the same internal-capital test Cleaner uses when a filler ate a sentence's capital.
    private static func sentenceCase(_ s: String) -> String {
        guard let f = s.first, f.isLowercase,
              !s.prefix(while: \.isLetter).dropFirst().contains(where: \.isUppercase)
        else { return s }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: - Continuation

    /// redteam M8: allow-list of ~200 sentence-starting function words. Only a first word we
    /// KNOW is a function word is decapitalized mid-sentence; every proper noun, weekday,
    /// month, name, title and acronym is left alone by default (a deny-list can never
    /// enumerate them). Month names and common first names are deliberately excluded even
    /// where they double as function words. "I*" and acronyms are absent, so both stay.
    static let sentenceStarters: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "each", "every", "either",
        "neither", "some", "any", "no", "all", "both", "few", "many", "most", "several",
        "such", "another", "other",
        "we", "you", "he", "she", "it", "they", "me", "us", "him", "her", "them", "my",
        "your", "his", "its", "our", "their", "mine", "yours", "ours", "theirs", "myself",
        "yourself", "himself", "herself", "itself", "ourselves", "themselves", "who", "whom",
        "whose", "which", "what", "whatever", "whoever", "whichever", "one", "ones", "someone",
        "somebody", "something", "anyone", "anybody", "anything", "everyone", "everybody",
        "everything", "nobody", "nothing", "none",
        "and", "but", "or", "nor", "so", "yet", "because", "although", "though", "while",
        "whereas", "if", "unless", "until", "since", "as", "than", "whether", "once", "when",
        "where", "wherever", "whenever", "before", "after", "however", "therefore", "thus",
        "hence", "meanwhile", "moreover", "furthermore", "otherwise", "instead", "besides",
        "also", "plus",
        "in", "on", "at", "by", "to", "from", "with", "without", "within", "into", "onto",
        "upon", "over", "under", "above", "below", "between", "among", "around", "about",
        "across", "along", "through", "throughout", "toward", "towards", "against", "during",
        "despite", "per", "via", "off", "out", "up", "down",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have",
        "has", "had", "can", "could", "would", "shall", "should", "might", "must", "ought",
        "need", "dare", "let", "lets",
        "here", "there", "then", "now", "well", "still", "just", "only", "even", "too",
        "again", "always", "never", "often", "sometimes", "usually", "perhaps", "maybe",
        "actually", "basically", "essentially", "honestly", "frankly", "clearly", "obviously",
        "surely", "certainly", "yes", "okay", "please", "thanks", "hello", "hi", "hey", "oh",
        "right", "sure", "first", "second", "third", "next", "last", "finally", "overall",
        "anyway", "anyhow", "regardless",
    ]

    /// Compatibility entrypoint for callers that only have a before-cursor snapshot.
    static func continuation(_ text: String, prefix: String?) -> String {
        InsertionFormatter.format(text, context: InsertionContext(before: prefix, after: nil))
    }

    static func leadingSpace(_ text: String, prefix: String?) -> String {
        InsertionFormatter.leadingSpace(text, before: prefix)
    }

    static func midSentence(_ prefix: String?) -> Bool {
        InsertionFormatter.boundary(before: prefix) == .continuation
    }
}
