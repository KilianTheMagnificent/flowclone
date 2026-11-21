import Foundation

/// Conservative, local checks on generated text. These detect specific losses, not
/// semantic equivalence. An uncertain rewrite must return the complete Clean transcript.
enum RewriteFidelity {
    enum Style { case polish, prompt }

    struct ScannedToken: Equatable, Sendable {
        let text: String
        let isSentenceStart: Bool
    }

    static let correctionPattern = #"\b(?:actually|i mean|i meant|scratch that|make that|no wait|wait no|correction|delete that|never mind|nevermind|instead)\b"#

    static func hasCorrection(_ text: String) -> Bool {
        text.range(of: correctionPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "instead of", with: "not")
            .replacingOccurrences(of: "rather than", with: "not")
            .replacingOccurrences(of: "n't", with: " not")
            .replacingOccurrences(of: "cannot", with: "can not")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static let light: Set<String> = [
        "a", "an", "the", "i", "we", "you", "it", "this", "that", "one", "to", "of", "in", "on",
        "at", "and", "or", "but", "so", "is", "are", "was", "be", "been", "do", "does",
        "did", "can", "could", "would", "should", "will", "have", "has", "had", "please",
        "um", "uh", "well", "like", "just", "really", "actually", "mean", "meant", "quote",
        "open", "close", "unquote", "let", "s", "m", "thinking"
    ]

    private static let titleAbbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc"
    ]

    /// Scans alphanumeric tokens while tracking sentence boundaries across `.`, `?`, `!`,
    /// and `\n` *before* punctuation is stripped so capitalized openers of sentences 2+
    /// (`However`, `Check`, `Please`, `Update`, `Also`) are not mistaken for proper nouns.
    static func tokens(in text: String) -> [ScannedToken] {
        var result: [ScannedToken] = []
        var idx = text.startIndex
        var atSentenceStart = true

        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isLetter || ch.isNumber {
                let start = idx
                var end = text.index(after: idx)
                while end < text.endIndex, text[end].isLetter || text[end].isNumber {
                    end = text.index(after: end)
                }
                let word = String(text[start..<end])
                result.append(ScannedToken(text: word, isSentenceStart: atSentenceStart))

                // If immediately followed by `.` on a title abbreviation ("Dr. Marcus"),
                // consume the dot without marking the next word as a sentence start.
                if end < text.endIndex, text[end] == ".",
                   titleAbbreviations.contains(word.lowercased()) {
                    idx = text.index(after: end)
                    atSentenceStart = false
                } else {
                    idx = end
                    atSentenceStart = false
                }
                continue
            }

            if ch == "." || ch == "?" || ch == "!" || ch.isNewline {
                atSentenceStart = true
            }
            idx = text.index(after: idx)
        }
        return result
    }

    private static func content(_ text: String) -> [String] {
        let withoutDiscourse = text.replacingOccurrences(
            of: #"\b(?:if you can|if possible|no big deal|either way)\b"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        return words(normalizingQuantities(withoutDiscourse)).filter { !light.contains($0) }
    }

    /// LCS preserves order and multiplicity; a repeated word cannot cover a missing clause.
    static func retainedInOrder(source: [String], output: [String]) -> Int {
        var prefix = 0
        while prefix < min(source.count, output.count), source[prefix] == output[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(source.count, output.count) - prefix,
              source[source.count - suffix - 1] == output[output.count - suffix - 1] { suffix += 1 }
        let sourceMiddle = source[prefix..<(source.count - suffix)]
        let outputMiddle = Array(output[prefix..<(output.count - suffix)])
        var row = Array(repeating: 0, count: outputMiddle.count + 1)
        for word in sourceMiddle {
            var diagonal = 0
            for j in outputMiddle.indices {
                let old = row[j + 1]
                row[j + 1] = word == outputMiddle[j] ? diagonal + 1 : max(row[j], old)
                diagonal = old
            }
        }
        return prefix + suffix + row[outputMiddle.count]
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).lowercased() }
    }

    private static let negative: Set<String> = ["not", "never", "without", "neither", "nor", "unless"]
    private static let clauseEnd: Set<Character> = [".", "!", "?", ";", "\n"]
    /// Longer alternatives first so "actually make that" is one cue, not two.
    private static let replacementCue = try! NSRegularExpression(
        pattern: #"\b(?:actually,? make that|actually,? i mean|make that|i mean|i meant|actually|no wait|wait no|correction)\b"#,
        options: .caseInsensitive)
    private static let deletionCue = try! NSRegularExpression(
        pattern: #"\b(?:scratch that|delete that|never ?mind)\b"#, options: .caseInsensitive)

    static func correctedSource(_ input: String, output: String) -> String {
        var s = input
        func counts(_ text: String) -> [String: Int] {
            Dictionary(content(text).map { ($0, 1) }, uniquingKeysWith: +)
        }
        let spoken = counts(input), written = counts(output)
        func dropped(_ reparandum: String, repair: String) -> Bool {
            let lost = Set(content(reparandum)), kept = Set(content(repair))
            if lost.contains(where: negative.contains), !kept.contains(where: negative.contains) { return false }
            let distinctive = lost.subtracting(kept)
            let fewer = distinctive.filter { written[$0, default: 0] < spoken[$0, default: 0] }.count
            return fewer * 2 >= distinctive.count
        }
        func repairStart(after cue: Range<String.Index>) -> String.Index {
            var i = cue.upperBound
            while i < s.endIndex, s[i] == "," || s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
            return i
        }
        for m in deletionCue.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let cue = Range(m.range, in: s) else { continue }
            let before = s[..<cue.lowerBound]
            var clauseStart = before.startIndex
            if let end = before.lastIndex(where: clauseEnd.contains) {
                clauseStart = before[before.index(after: end)...].allSatisfy(\.isWhitespace)
                    ? (before[..<end].lastIndex(where: clauseEnd.contains).map { before.index(after: $0) } ?? before.startIndex)
                    : before.index(after: end)
            }
            s.replaceSubrange(clauseStart..<repairStart(after: cue), with: "")
        }
        for m in replacementCue.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let cue = Range(m.range, in: s) else { continue }
            let start = repairStart(after: cue)
            let repair = s[start...].prefix { !clauseEnd.contains($0) && $0 != "," }
            let n = repair.split(whereSeparator: \.isWhitespace).prefix(6).count
            var reparandum = cue.lowerBound
            for token in s[..<cue.lowerBound].split(whereSeparator: \.isWhitespace).suffix(n).reversed() {
                if let last = token.last, clauseEnd.contains(last), !token.dropLast().contains(".") { break }
                reparandum = token.startIndex
            }
            let from = dropped(String(s[reparandum..<cue.lowerBound]), repair: String(repair)) ? reparandum : cue.lowerBound
            s.replaceSubrange(from..<start, with: "")
        }
        return s
    }

    static let numberMap: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
        "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16",
        "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90",
    ]

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    /// Pronoun and discourse uses of "one" ("which one", "a new one", "one more thing")
    /// must not become the digit `1`.
    private static let pronounOneGuard = try! NSRegularExpression(
        pattern: #"\b(?:(?:which|this|that|another|each|every|either|neither|no|any|some|other|same|new|old|first|second|third|last|next|good|better|best|right|wrong|only|nice|big|small|little|single)\s+(one)\b(?!\s+(?:hundred|thousand|million|billion|point)\b)|(one)\s+(?:more\s+(?:thing|question|ask|note|detail)|by\s+one|on\s+one|at\s+a\s+time|way\s+or\s+another)\b|for\s+(one)(?:\s+thing)?\b)"#,
        options: .caseInsensitive
    )

    private static let groupedThousandsDigits = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])\d{1,3}(?:,\d{3})+(?![\p{L}\p{N}])"#
    )
    private static let articleMagnitude = try! NSRegularExpression(
        pattern: #"(?<!\bof\s)\ba\s+(hundred|thousand|million|billion)\b"#
    )
    private static let compoundTens = try! NSRegularExpression(
        pattern: #"\b(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)[ -](one|two|three|four|five|six|seven|eight|nine)\b"#
    )
    private static let singleNumbers = try! NSRegularExpression(
        pattern: "\\b(?:" + numberWords.keys.sorted().joined(separator: "|") + ")\\b"
    )
    private static let hundredWithRemainder = try! NSRegularExpression(
        pattern: #"\b(\d+)\s+hundred(?:\s+and\s+|\s+)(\d{1,2})\b(?!\s+(?:thousand|million|billion)\b)"#
    )
    private static let plainHundred = try! NSRegularExpression(
        pattern: #"\b(\d+)\s+hundred\b"#
    )
    private static let thousandWithRemainder = try! NSRegularExpression(
        pattern: #"\b(\d+)\s+thousand(?:\s+and\s+|\s+)(\d{1,3})\b(?!\s+(?:thousand|million|billion)\b)"#
    )
    private static let decimalMagnitude = try! NSRegularExpression(
        pattern: #"\b(\d+)\.(\d+)\s+(billion|million|thousand)\b"#
    )
    private static let integerMagnitude = try! NSRegularExpression(
        pattern: #"\b(\d+)\s+(billion|million|thousand)\b"#
    )
    private static let digits = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\d+(?:[.,:]\d+)*"#)

    private static func scaleMultiplier(_ unit: String) -> Int {
        switch unit {
        case "billion": return 1_000_000_000
        case "million": return 1_000_000
        case "thousand": return 1_000
        default: return 1
        }
    }

    static func normalizingQuantities(_ input: String) -> String {
        var normalized = input.lowercased()

        // 1. Strip thousands-grouping commas inside digit literals ("5,000" -> "5000").
        let commaNS = normalized as NSString
        for match in groupedThousandsDigits.matches(in: normalized, range: NSRange(location: 0, length: commaNS.length)).reversed() {
            let clean = commaNS.substring(with: match.range).replacingOccurrences(of: ",", with: "")
            if let range = Range(match.range, in: normalized) {
                normalized.replaceSubrange(range, with: clean)
            }
        }

        // 2. Shield pronoun/discourse "one" before converting number words to digits.
        let pronounSentinel = "xpronounone"
        let guardNS = normalized as NSString
        var protectedOneRanges: [NSRange] = []
        for match in pronounOneGuard.matches(in: normalized, range: NSRange(location: 0, length: guardNS.length)) {
            for group in 1...3 {
                let r = match.range(at: group)
                if r.location != NSNotFound {
                    protectedOneRanges.append(r)
                }
            }
        }
        for r in protectedOneRanges.sorted(by: { $0.location > $1.location }) {
            if let swiftRange = Range(r, in: normalized) {
                normalized.replaceSubrange(swiftRange, with: pronounSentinel)
            }
        }

        // 3. Convert "a hundred" / "a thousand" / "a million" / "a billion" -> "1 <unit>".
        normalized = articleMagnitude.stringByReplacingMatches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized),
            withTemplate: "1 $1"
        )

        // 4. Normalize compound tens ("twenty-five" -> "25") and single number words ("five" -> "5", "one" -> "1").
        let tensNS = normalized as NSString
        for match in compoundTens.matches(in: normalized, range: NSRange(location: 0, length: tensNS.length)).reversed() {
            let first = tensNS.substring(with: match.range(at: 1))
            let second = tensNS.substring(with: match.range(at: 2))
            let sum = numberWords[first]! + numberWords[second]!
            if let range = Range(match.range, in: normalized) {
                normalized.replaceSubrange(range, with: String(sum))
            }
        }
        let spelled = normalized as NSString
        let output = NSMutableString(string: normalized)
        for match in singleNumbers.matches(in: normalized, range: NSRange(location: 0, length: spelled.length)).reversed() {
            if let value = numberWords[spelled.substring(with: match.range)] {
                output.replaceCharacters(in: match.range, with: String(value))
            }
        }
        normalized = output as String

        // 5. Fold magnitude phrases ("5 hundred" -> "500", "5 hundred 20" -> "520",
        //    "1 thousand 500" -> "1500", "50 thousand" -> "50000", "2.5 million" -> "2500000").
        let hRemNS = normalized as NSString
        for match in hundredWithRemainder.matches(in: normalized, range: NSRange(location: 0, length: hRemNS.length)).reversed() {
            if let head = Int(hRemNS.substring(with: match.range(at: 1))),
               let rem = Int(hRemNS.substring(with: match.range(at: 2))),
               let range = Range(match.range, in: normalized) {
                normalized.replaceSubrange(range, with: String(head * 100 + rem))
            }
        }
        let hPlainNS = normalized as NSString
        for match in plainHundred.matches(in: normalized, range: NSRange(location: 0, length: hPlainNS.length)).reversed() {
            if let head = Int(hPlainNS.substring(with: match.range(at: 1))),
               let range = Range(match.range, in: normalized) {
                normalized.replaceSubrange(range, with: String(head * 100))
            }
        }
        let tRemNS = normalized as NSString
        for match in thousandWithRemainder.matches(in: normalized, range: NSRange(location: 0, length: tRemNS.length)).reversed() {
            if let head = Int(tRemNS.substring(with: match.range(at: 1))),
               let rem = Int(tRemNS.substring(with: match.range(at: 2))),
               rem < 1_000,
               let range = Range(match.range, in: normalized) {
                normalized.replaceSubrange(range, with: String(head * 1_000 + rem))
            }
        }
        let decMagNS = normalized as NSString
        for match in decimalMagnitude.matches(in: normalized, range: NSRange(location: 0, length: decMagNS.length)).reversed() {
            let whole = decMagNS.substring(with: match.range(at: 1))
            let frac = decMagNS.substring(with: match.range(at: 2))
            let unit = decMagNS.substring(with: match.range(at: 3))
            if let val = Double("\(whole).\(frac)"),
               let range = Range(match.range, in: normalized) {
                let scaled = Int((val * Double(scaleMultiplier(unit))).rounded())
                normalized.replaceSubrange(range, with: String(scaled))
            }
        }
        let intMagNS = normalized as NSString
        for match in integerMagnitude.matches(in: normalized, range: NSRange(location: 0, length: intMagNS.length)).reversed() {
            if let head = Int(intMagNS.substring(with: match.range(at: 1))),
               let range = Range(match.range, in: normalized) {
                let unit = intMagNS.substring(with: match.range(at: 2))
                normalized.replaceSubrange(range, with: String(head * scaleMultiplier(unit)))
            }
        }

        if normalized.contains(pronounSentinel) {
            normalized = normalized.replacingOccurrences(of: pronounSentinel, with: "one")
        }
        return normalized
    }

    private static func quantities(_ input: String, ordered: Bool = false) -> [String] {
        let values = matches(digits, in: normalizingQuantities(input))
        return ordered ? values : values.sorted()
    }

    private static let technicalTerms = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:[_@&][\p{L}\p{N}]+)+|[\p{L}\p{N}]+(?:\+\+|#)|[<>=!]=|[<>]"#)

    /// True when a token has mixed internal casing (e.g. `FlowClone`, `SQLite`), which
    /// remains an identifier even if it opens a later sentence.
    private static func hasIdentifierCasing(_ token: String) -> Bool {
        token.dropFirst().contains(where: \.isUppercase) && token.contains(where: \.isLowercase)
    }

    static func reject(_ output: String, input: String, style: Style) -> String? {
        let source = correctedSource(input, output: output)
        let src = words(source), got = words(output)
        if src.filter({ negative.contains($0) }).count != got.filter({ negative.contains($0) }).count {
            return "changed negation or exception"
        }
        func scopes(_ text: String) -> [(marker: String, anchors: [String])] {
            text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")).flatMap { clause in
                let tokens = words(normalizingQuantities(clause))
                return tokens.indices.filter { negative.contains(tokens[$0]) }.map { i in
                    (tokens[i], Array(tokens.dropFirst(i + 1).prefix(while: { !negative.contains($0) })
                        .prefix(9).filter { !light.contains($0) }.prefix(3)))
                }
            }
        }
        var availableScopes = scopes(output)
        for scope in scopes(source) {
            guard let match = availableScopes.firstIndex(where: {
                $0.marker == scope.marker
                    && retainedInOrder(source: scope.anchors, output: $0.anchors) == scope.anchors.count
            }) else { return "changed negation scope" }
            availableScopes.remove(at: match)
        }
        let uncertainty: Set<String> = ["maybe", "perhaps", "possibly", "probably", "might"]
        if src.filter({ uncertainty.contains($0) }).sorted() != got.filter({ uncertainty.contains($0) }).sorted() {
            return "changed uncertainty"
        }
        if quantities(source, ordered: style == .polish) != quantities(output, ordered: style == .polish) {
            return "changed quantity"
        }
        var technical = matches(technicalTerms, in: output)
        for term in matches(technicalTerms, in: source) {
            guard let index = technical.firstIndex(of: term) else { return "changed technical term or operator" }
            technical.remove(at: index)
        }
        var commands = SlashCommands.mentions(in: output)
        for command in SlashCommands.mentions(in: source) {
            guard let index = commands.firstIndex(of: command) else { return "changed agent command" }
            commands.remove(at: index)
        }
        // Check surviving unquantified magnitude words and weekday names on quantity-normalized
        // text so valid rewrites like "five hundred" <-> "500" are accepted.
        let units: Set<String> = ["hundred", "thousand", "million", "billion",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let normSrc = words(normalizingQuantities(source))
        let normGot = words(normalizingQuantities(output))
        if normSrc.filter({ units.contains($0) }).sorted() != normGot.filter({ units.contains($0) }).sorted() {
            return "changed spoken quantity or date"
        }

        // Capitalized interior tokens cover dictated names/identifiers without treating
        // Titlecase sentence openers in sentences 2+ ("However", "Check", "Update") as names.
        let scanned = tokens(in: source)
        let names = scanned.filter { token in
            guard token.text.count > 1, token.text.first?.isUppercase == true,
                  !light.contains(token.text.lowercased()) else { return false }
            return !token.isSentenceStart || hasIdentifierCasing(token.text)
        }.map { $0.text.lowercased() }
        if names.contains(where: { !got.contains($0) }) { return "lost name or identifier" }

        let sourceContent = content(source), outputContent = content(output)
        if sourceContent.count >= 4 {
            var available = Dictionary(outputContent.map { ($0, 1) }, uniquingKeysWith: +)
            let unordered = sourceContent.reduce(0) { count, word in
                guard available[word, default: 0] > 0 else { return count }
                available[word, default: 0] -= 1
                return count + 1
            }
            let retained = style == .polish
                ? retainedInOrder(source: sourceContent, output: outputContent) : unordered
            let recall = Double(retained) / Double(sourceContent.count)
            let floor = style == .polish ? (hasCorrection(source) ? 0.55 : 0.8) : 0.4
            if recall < floor { return "lost source wording" }
        }
        let outputWords = Set(outputContent)
        for clause in source.components(separatedBy: CharacterSet(charactersIn: ".!?;\n")) {
            let required = Set(content(clause))
            guard required.count >= 4, !hasCorrection(clause) else { continue }
            if Double(required.intersection(outputWords).count) / Double(required.count) < (style == .polish ? 0.5 : 0.4) {
                return "lost clause"
            }
        }
        return nil
    }
}
