import Foundation
import NaturalLanguage

/// Ephemeral, exact-field context. nil means unknown; "" means a known document edge.
/// Neither side is inserted, persisted, logged, nor sent to the rewrite model.
struct InsertionContext: Equatable, Sendable {
    let before: String?
    let after: String?
    var selected: String? = nil
    static let empty = InsertionContext(before: nil, after: nil)
}

enum InsertionFormatter {
    enum Boundary { case unknown, sentenceStart, continuation }
    private static let closers = "\"'”’)]}"
    private static let titleAbbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "e.g.", "i.e."
    ]
    private static let abbreviationBodies: Set<String> = [
        "etc", "mr", "mrs", "ms", "dr", "prof", "jr", "sr", "vs", "inc", "ltd", "st"
    ]

    /// Shared, lock-guarded `NLTagger` reused across continuation checks so `InsertionFormatter`
    /// never allocates a fresh tagger per utterance and clears `string` immediately on exit.
    private final class CachedTagger: @unchecked Sendable {
        let lock = NSLock()
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        private(set) var invocationCount: Int = 0

        func inspect(sample: String, offset: Int) -> (tag: NLTag?, lemma: String?) {
            lock.lock()
            defer {
                tagger.string = nil
                lock.unlock()
            }
            invocationCount += 1
            tagger.string = sample
            tagger.setLanguage(.english, range: sample.startIndex..<sample.endIndex)
            let index = sample.index(sample.startIndex, offsetBy: offset)
            let tag = tagger.tag(at: index, unit: .word, scheme: .nameTypeOrLexicalClass).0
            let lemma = tagger.tag(at: index, unit: .word, scheme: .lemma).0?.rawValue
            return (tag, lemma)
        }
    }

    private static let cachedTagger = CachedTagger()
    static var taggerInstanceIdentifier: ObjectIdentifier { ObjectIdentifier(cachedTagger.tagger) }

    static func boundary(before: String?) -> Boundary {
        guard let before else { return .unknown }
        let line = before.split(whereSeparator: { $0.isNewline }).last.map(String.init) ?? ""
        if line.range(of: #"^\s*(?:(?:[-*•]|\d+[.)])(?:\s+\[[ xX]\])?|#{1,6}|>)\s+$"#,
                      options: .regularExpression) != nil {
            return .sentenceStart
        }
        var end = before[...]
        // Delimiters inherit the surrounding sentence: Done.” and Done. ( both start
        // another sentence, while See ( continues one. A newline is never stripped.
        while let last = end.last, horizontalSpace(last) || closers.contains(last) || "([{“‘".contains(last) {
            end = end.dropLast()
        }
        guard let last = end.last else { return .sentenceStart }
        if last.isNewline || "!?。！？:".contains(last) { return .sentenceStart }
        if last == "." {
            let token = end.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
            return titleAbbreviations.contains(token) ? .continuation : .sentenceStart
        }
        return .continuation
    }

    static func format(
        _ text: String,
        context: InsertionContext,
        mode: Mode = .clean,
        protectedTerms: [String] = [],
        preserveTerminalPeriod: Bool = false,
        stripSingleSentencePeriod: Bool = false
    ) -> String {
        guard mode != .raw, !text.isEmpty else { return text }
        // A caret inside a token is not a word boundary. Don't invent spaces in a URL,
        // identifier, or a partially selected word. Verbatim/spelling has its own path.
        if let left = context.before?.last, let right = context.after?.first,
           word(left), word(right),
           context.selected?.first?.isWhitespace != true,
           context.selected?.last?.isWhitespace != true { return text }

        var output = text
        if context.before?.last.map(horizontalSpace) == true {
            output.removeFirst(output.prefix(while: horizontalSpace).count)
        }
        if context.after?.first.map(horizontalSpace) == true {
            while let last = output.last, horizontalSpace(last) { output.removeLast() }
        }
        // Explicit line/paragraph breaks and list indentation must survive unchanged.
        if let first = output.first, !first.isWhitespace,
           let range = firstWord(in: output) {
            let token = String(output[range])
            let followedByCodeSeparator = range.upperBound < output.endIndex
                && "_/::".contains(output[range.upperBound])
                || (range.upperBound < output.endIndex && output[range.upperBound] == "."
                    && output.index(after: range.upperBound) < output.endIndex
                    && word(output[output.index(after: range.upperBound)]))

            if !followedByCodeSeparator && !isProtectedOpening(
                output: output,
                firstWordRange: range,
                token: token,
                protectedTerms: protectedTerms
            ) {
                switch boundary(before: context.before) {
                case .continuation:
                    if shouldLowercase(token, in: output, at: range, before: context.before ?? "") {
                        output.replaceSubrange(range, with: token.prefix(1).lowercased() + token.dropFirst())
                    }
                case .sentenceStart:
                    // Preserve deliberate camelCase (iPhone, eBay, identifiers).
                    if token.first?.isLowercase == true, asciiLetters(token),
                       !token.dropFirst().contains(where: \.isUppercase) {
                        output.replaceSubrange(range, with: token.prefix(1).uppercased() + token.dropFirst())
                    }
                case .unknown: break
                }
            }
        }

        if let suffix = context.after, let last = output.last {
            let next = suffix.first
            // Drop only a redundant edge mark, never text outside the insertion.
            if next == last, ".,;:!?".contains(last), !output.hasSuffix(".."), !endsInAbbreviation(output) {
                output.removeLast()
            } else if last == ".", !preserveTerminalPeriod, !output.hasSuffix(".."),
                      !endsInAbbreviation(output) {
                let rest = suffix.drop(while: horizontalSpace)
                if let first = rest.first,
                   ",;:".contains(first) || first.isLowercase {
                    output.removeLast()
                }
            }
        }

        if stripSingleSentencePeriod,
           (context.after == nil || context.after?.allSatisfy(horizontalSpace) == true) {
            output = AppProfiles.stripSingleSentencePeriod(
                output,
                before: context.before,
                preserveExplicitPeriod: preserveTerminalPeriod
            )
        }

        output = leadingSpace(output, before: context.before)
        if let first = context.after?.first, let last = output.last,
           word(first), (word(last) || ".!?)]}\"”’".contains(last)),
           !unspacedScript(first), !unspacedScript(last) {
            output += " "
        }
        return output
    }

    /// Protects deliberate dictionary/identifier openings ("Clean", "Context Vocabulary", "iPhone")
    /// without letting multi-word prose snippets ("ty -> Thank you", "ttyl -> talk to you later")
    /// or compound identifiers ("get_user_id") block case adjustment of ordinary English words.
    private static func isProtectedOpening(
        output: String,
        firstWordRange: Range<String.Index>,
        token: String,
        protectedTerms: [String]
    ) -> Bool {
        guard !protectedTerms.isEmpty else { return false }
        let suffixFromFirstWord = output[firstWordRange.lowerBound...]

        for rawTerm in protectedTerms {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }

            let isSingleAtom = !term.contains(where: { $0.isWhitespace || "_-./:".contains($0) })
            if isSingleAtom {
                // Protect single-word terms with deliberate uppercase ("Clean", "OpenCode", "iPhone").
                // All-lowercase single-word snippets do not block sentence-start capitalization.
                if term == token, term.contains(where: \.isUppercase) {
                    return true
                }
                continue
            }

            // Multi-word or symbol-joined term: first require `output` to actually begin with `term`
            // on a word boundary so "get_user_id" or "Thank you" never blocks unrelated "Get..." / "Thank...".
            guard suffixFromFirstWord.hasPrefix(term) else { continue }
            let afterMatch = suffixFromFirstWord.index(suffixFromFirstWord.startIndex, offsetBy: term.count)
            if afterMatch < suffixFromFirstWord.endIndex, word(suffixFromFirstWord[afterMatch]) {
                continue
            }

            // Symbol-joined identifiers ("get_user_id", "foo-bar") keep their exact case.
            if term.contains(where: { "_-./:".contains($0) }) {
                return true
            }

            // Multi-word phrase: protect multi-word proper names ("Context Vocabulary", "New York")
            // or terms with internal identifier casing ("OpenAI API"), while allowing ordinary
            // prose snippets ("Thank you", "talk to you later") to adapt to sentence boundaries.
            let termWords = term.split(whereSeparator: \.isWhitespace)
            let capitalizedWordCount = termWords.filter { $0.first?.isUppercase == true }.count
            let hasInternalUpper = termWords.contains { $0.dropFirst().contains(where: \.isUppercase) }
            if capitalizedWordCount >= 2 || hasInternalUpper {
                return true
            }
        }
        return false
    }

    static func leadingSpace(_ text: String, before: String?) -> String {
        guard let last = before?.last, let first = text.first,
              !last.isWhitespace, !first.isWhitespace,
              !"([{\"“‘-—/\\@_".contains(last),
              // A spoken agent command ("/compact") is a word of its own after text.
              word(first) || "(\"“‘".contains(first)
                || (first == "/" && text.dropFirst().first.map(word) == true),
              !unspacedScript(last), !unspacedScript(first) else { return text }
        return " " + text
    }

    /// The NER experiment found ambiguous capitalized words (e.g. Will) can be tagged as
    /// verbs. Require both a non-name tag AND a lowercase lemma, and otherwise keep case.
    /// The fast function-word path covers common joins without invoking the tagger.
    private static func shouldLowercase(_ token: String, in text: String, at range: Range<String.Index>,
                                        before: String) -> Bool {
        guard token.first?.isUppercase == true, asciiLetters(token),
              !token.dropFirst().contains(where: \.isUppercase) else { return false }
        let key = token.replacingOccurrences(of: "’", with: "'").lowercased()
        if key == "i" || key.hasPrefix("i'") { return false }
        if SmartFormat.sentenceStarters.contains(key) { return true }
        let prefix = String(before.suffix(200)) + (before.last?.isWhitespace == false ? " " : "")
        let fragment = String(text.prefix(384))
        let sample = prefix + fragment
        let offset = prefix.count + text.distance(from: text.startIndex, to: range.lowerBound)
        guard offset < sample.count else { return false }
        let (tag, lemma) = cachedTagger.inspect(sample: sample, offset: offset)
        // Nouns can be product names even when the tagger knows a lowercase lemma
        // (Parakeet is both a bird and our ASR model). Keep ambiguous nouns capitalized.
        guard let tag, ![NLTag.personalName, .placeName, .organizationName, .noun, .otherWord].contains(tag),
              let lemma,
              lemma.first?.isLowercase == true else { return false }
        return true
    }

    private static func firstWord(in text: String) -> Range<String.Index>? {
        var start = text.startIndex
        while start < text.endIndex, "\"“‘([{".contains(text[start]) { start = text.index(after: start) }
        guard start < text.endIndex, text[start].isLetter else { return nil }
        let end = text[start...].prefix { $0.isLetter || $0 == "'" || $0 == "’" }.endIndex
        return start..<end
    }
    private static func asciiLetters(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII || $0 == "’" }
    }
    private static func horizontalSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }
    private static func word(_ character: Character) -> Bool { character.isLetter || character.isNumber }
    private static func unspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
                || (0x0E00...0x0EFF).contains(scalar.value) || (0x20000...0x3134F).contains(scalar.value)
        }
    }
    private static func endsInAbbreviation(_ text: String) -> Bool {
        guard let token = text.split(whereSeparator: \.isWhitespace).last, token.hasSuffix(".") else { return false }
        let body = token.dropLast()
        return body.contains(".") || abbreviationBodies.contains(body.lowercased())
    }
}
