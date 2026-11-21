import Foundation

/// Shared bounded-string similarity primitives used by both persistent and ephemeral
/// vocabulary matching. Keeping one implementation prevents the two correction paths from
/// drifting on inflections or Unicode Character distance.
enum TextSimilarity {
    /// Exact Levenshtein within a caller's cutoff. Rows outside the diagonal band
    /// cannot produce an admissible match; no String-to-Character conversion per term.
    static func boundedEditDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int? {
        guard limit >= 0, abs(a.count - b.count) <= limit else { return nil }
        if a.isEmpty { return b.count <= limit ? b.count : nil }
        if b.isEmpty { return a.count <= limit ? a.count : nil }
        let unreachable = limit + 1
        var row = (0...b.count).map { min($0, unreachable) }
        var next = Array(repeating: unreachable, count: b.count + 1)
        for i in 1...a.count {
            let lower = max(1, i - limit), upper = min(b.count, i + limit)
            guard lower <= upper else { return nil }
            next[lower - 1] = lower == 1 ? min(i, unreachable) : unreachable
            if upper < b.count { next[upper + 1] = unreachable }
            var minimum = unreachable
            for j in lower...upper {
                next[j] = min(next[j - 1] + 1, row[j] + 1,
                              row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                minimum = min(minimum, next[j])
            }
            guard minimum <= limit else { return nil }
            swap(&row, &next)
        }
        return row[b.count] <= limit ? row[b.count] : nil
    }

    static func isInflection(_ a: String, _ b: String) -> Bool {
        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        guard long.count > short.count, long.hasPrefix(short) else { return false }
        return ["s", "es", "ed", "ing"].contains(String(long.dropFirst(short.count)))
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = previous
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

struct ContextTerm: Hashable, Sendable {
    enum Source: Int, Hashable, Sendable {
        case visible = 0
        case nearby = 1
        case filename = 2
        case selected = 3
    }

    let canonical: String
    let spokenForms: [String]
    let source: Source
}

struct DictationContext: Sendable {
    let continuationPrefix: String?
    let terms: [ContextTerm]
    var continuationSuffix: String? = nil
    var continuationSelection: String? = nil

    var insertion: InsertionContext {
        InsertionContext(before: continuationPrefix, after: continuationSuffix, selected: continuationSelection)
    }

    static let empty = DictationContext(continuationPrefix: nil, terms: [])
}

enum ContextVocabulary {
    struct Rewrite: Equatable, Sendable {
        let original: String
        let replacement: String
    }

    struct RewriteResult: Equatable, Sendable {
        let text: String
        let changes: [Rewrite]
    }

    private struct Candidate {
        let canonical: String
        let source: ContextTerm.Source
        let ordinal: Int
    }

    private struct WordSpan {
        let text: String
        let range: Range<String.Index>
    }

    private struct Alias {
        let canonical: String
        let words: [String]
        let source: ContextTerm.Source
    }

    static let maximumTerms = 32
    private static let maximumTermLength = 64
    private static let maximumAliasWords = 6

    private static let tokenRegex = try! NSRegularExpression(
        pattern: "[\\p{L}_][\\p{L}\\p{N}_\\-.]{2,63}"
    )
    private static let wordRegex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+")
    private static let acronymBoundary = try! NSRegularExpression(pattern: "([\\p{Lu}]+)([\\p{Lu}][\\p{Ll}])")
    private static let camelBoundary = try! NSRegularExpression(pattern: "([\\p{Ll}\\p{N}])([\\p{Lu}])")
    private static let digitBoundaryA = try! NSRegularExpression(pattern: "([\\p{L}])([\\p{N}])")
    private static let digitBoundaryB = try! NSRegularExpression(pattern: "([\\p{N}])([\\p{L}])")
    private static let knownAcronyms = [
        "HTTPS", "UUID", "HTTP", "JSON", "URL", "API", "XML", "SQL", "IDE",
        "AX", "UI", "NS", "ID",
    ]

    private static let commonWords: Set<String> = [
        "about", "after", "again", "also", "another", "before", "between", "could",
        "first", "from", "have", "into", "just", "more", "other", "should", "some",
        "string", "that", "their", "there", "these", "this", "through", "using", "value",
        "what", "when", "where", "which", "while", "with", "would", "your",
    ]

    /// Extracts identifier-shaped vocabulary only. Source strings stay stack-local and are
    /// never returned, logged, persisted, or passed to a language model.
    static func extract(
        before: String = "",
        selected: String = "",
        after: String = "",
        visible: String = "",
        filenames: [String] = []
    ) -> [ContextTerm] {
        var candidates: [Candidate] = []
        var ordinal = 0

        func collect(_ raw: String, source: ContextTerm.Source, filename: Bool = false,
                     alreadyScrubbed: Bool = false) {
            let safe = filename || alreadyScrubbed ? raw : scrubCode(raw)
            for token in tokens(in: safe) {
                guard let canonical = sanitize(token, source: source, filename: filename) else { continue }
                candidates.append(Candidate(canonical: canonical, source: source, ordinal: ordinal))
                ordinal += 1
                if filename, let dot = canonical.lastIndex(of: ".") {
                    let stem = String(canonical[..<dot])
                    if let stem = sanitize(stem, source: source, filename: true) {
                        candidates.append(Candidate(canonical: stem, source: source, ordinal: ordinal))
                        ordinal += 1
                    }
                } else if !filename, canonical.contains(".") {
                    for part in canonical.split(separator: ".") {
                        if let sub = sanitize(String(part), source: source, filename: false) {
                            candidates.append(Candidate(canonical: sub, source: source, ordinal: ordinal))
                            ordinal += 1
                        }
                    }
                }
            }
        }

        // Scrub the cursor neighborhood as ONE lexical fragment. Scrubbing selected text by
        // itself loses the quote/comment delimiters around it and can turn a selected secret
        // literal into apparent source code. The scrubber preserves one Character per input
        // Character, so the priority slices remain exact after masking.
        let beforeCap = String(before.suffix(384))
        let selectedCap = String(selected.prefix(256))
        let afterCap = String(after.prefix(384))
        let safeNearby = scrubCode(beforeCap + selectedCap + afterCap)
        let safeBefore = String(safeNearby.prefix(beforeCap.count))
        let afterBefore = safeNearby.dropFirst(beforeCap.count)
        let safeSelected = String(afterBefore.prefix(selectedCap.count))
        let safeAfter = String(afterBefore.dropFirst(selectedCap.count))

        collect(safeSelected, source: .selected, alreadyScrubbed: true)
        for name in filenames.prefix(8) { collect(name, source: .filename, filename: true) }
        collect(safeBefore, source: .nearby, alreadyScrubbed: true)
        collect(safeAfter, source: .nearby, alreadyScrubbed: true)
        collect(String(visible.prefix(1_024)), source: .visible)

        var best: [String: Candidate] = [:]
        for candidate in candidates {
            let key = folded(candidate.canonical)
            guard let old = best[key] else { best[key] = candidate; continue }
            if candidate.source.rawValue > old.source.rawValue
                || (candidate.source == old.source && candidate.ordinal < old.ordinal)
            {
                best[key] = candidate
            }
        }

        let ordered = best.values.sorted {
            if $0.source.rawValue != $1.source.rawValue {
                return $0.source.rawValue > $1.source.rawValue
            }
            return $0.ordinal < $1.ordinal
        }

        var formsByCanonical: [String: [String]] = [:]
        var canonicalByForm: [String: Set<String>] = [:]
        for candidate in ordered {
            let forms = spokenForms(for: candidate.canonical)
            formsByCanonical[candidate.canonical] = forms
            for form in forms {
                canonicalByForm[form, default: []].insert(folded(candidate.canonical))
            }
        }

        var result: [ContextTerm] = []
        for candidate in ordered {
            let forms = (formsByCanonical[candidate.canonical] ?? []).filter {
                canonicalByForm[$0]?.count == 1
            }
            guard !forms.isEmpty else { continue }
            result.append(ContextTerm(
                canonical: candidate.canonical,
                spokenForms: forms,
                source: candidate.source
            ))
            if result.count == maximumTerms { break }
        }
        return result
    }

    /// Applies only whole-word aliases. The fuzzy fallback is intentionally narrow: a unique
    /// one-token candidate at least eight characters long and within 15% edit distance.
    static func rewrite(_ text: String, using terms: [ContextTerm]) -> RewriteResult {
        guard !text.isEmpty, !terms.isEmpty else { return RewriteResult(text: text, changes: []) }
        let spans = words(in: text)
        guard !spans.isEmpty else { return RewriteResult(text: text, changes: []) }

        var aliases: [Alias] = []
        for term in terms {
            for form in term.spokenForms {
                let words = normalizedWords(form)
                guard !words.isEmpty, words.count <= maximumAliasWords else { continue }
                aliases.append(Alias(canonical: term.canonical, words: words, source: term.source))
            }
        }
        aliases.sort {
            if $0.words.count != $1.words.count { return $0.words.count > $1.words.count }
            if $0.source.rawValue != $1.source.rawValue { return $0.source.rawValue > $1.source.rawValue }
            return $0.canonical < $1.canonical
        }

        var output = ""
        output.reserveCapacity(text.count)
        var cursor = text.startIndex
        var index = 0
        var changes: [Rewrite] = []

        while index < spans.count {
            var hit: (alias: Alias, count: Int)?
            for alias in aliases where index + alias.words.count <= spans.count {
                guard exactMatch(alias.words, spans: spans, at: index, in: text) else { continue }
                hit = (alias, alias.words.count)
                break
            }

            if hit == nil, let fuzzy = fuzzyMatch(spans[index].text, aliases: aliases) {
                hit = (fuzzy, 1)
            }

            guard let hit else { index += 1; continue }
            let range = spans[index].range.lowerBound..<spans[index + hit.count - 1].range.upperBound
            let original = String(text[range])
            if original != hit.alias.canonical {
                output.append(contentsOf: text[cursor..<range.lowerBound])
                output.append(contentsOf: hit.alias.canonical)
                cursor = range.upperBound
                changes.append(Rewrite(original: original, replacement: hit.alias.canonical))
            }
            index += hit.count
        }

        guard !changes.isEmpty else { return RewriteResult(text: text, changes: []) }
        output.append(contentsOf: text[cursor...])
        return RewriteResult(text: output, changes: changes)
    }

    private static func exactMatch(_ wanted: [String], spans: [WordSpan], at start: Int,
                                   in text: String) -> Bool {
        for offset in wanted.indices {
            guard folded(spans[start + offset].text) == wanted[offset] else { return false }
            if offset > 0 {
                let separator = text[spans[start + offset - 1].range.upperBound..<spans[start + offset].range.lowerBound]
                guard separator.allSatisfy(\.isWhitespace) else { return false }
            }
        }
        return true
    }

    private static func fuzzyMatch(_ word: String, aliases: [Alias]) -> Alias? {
        let normalized = folded(word)
        guard normalized.count >= 8 else { return nil }
        var candidates: [(Alias, Int)] = []
        var seen = Set<String>()
        for alias in aliases where alias.words.count == 1 {
            let target = alias.words[0]
            guard target.count >= 8, target != normalized,
                  !TextSimilarity.isInflection(normalized, target),
                  seen.insert(folded(alias.canonical)).inserted else { continue }
            let distance = TextSimilarity.editDistance(normalized, target)
            guard Double(distance) / Double(max(normalized.count, target.count)) <= 0.15 else { continue }
            candidates.append((alias, distance))
        }
        candidates.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.source.rawValue != $1.0.source.rawValue {
                return $0.0.source.rawValue > $1.0.source.rawValue
            }
            return $0.0.canonical < $1.0.canonical
        }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1, candidates[1].1 < best.1 + 2 { return nil }
        return best.0
    }

    private static func tokens(in text: String) -> [String] {
        tokenRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func words(in text: String) -> [WordSpan] {
        wordRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return WordSpan(text: String(text[range]), range: range)
        }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        words(in: text).map { folded($0.text) }.filter { !$0.isEmpty }
    }

    private static func sanitize(_ raw: String, source: ContextTerm.Source,
                                 filename: Bool) -> String? {
        let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        guard (3...maximumTermLength).contains(token.count),
              token.rangeOfCharacter(from: .controlCharacters) == nil,
              !looksSecret(token) else { return nil }
        let lower = folded(token)
        guard !commonWords.contains(lower) else { return nil }

        let letters = token.filter(\.isLetter)
        let uppercase = letters.filter(\.isUppercase).count
        let lowercase = letters.filter(\.isLowercase).count
        let hasSeparator = token.contains("_") || token.contains("-") || token.contains(".")
        let hasDigit = token.contains(where: \.isNumber)
        let hasInternalUpper = token.dropFirst().contains(where: \.isUppercase)
        let acronym = uppercase >= 2 && lowercase == 0
        let selectedProper = source == .selected && token.first?.isUppercase == true && token.count >= 5
        guard filename || hasSeparator || hasDigit || hasInternalUpper || acronym || selectedProper else {
            return nil
        }
        return token
    }

    private static func spokenForms(for canonical: String) -> [String] {
        var spaced = canonical.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        func replace(_ regex: NSRegularExpression, _ template: String) {
            spaced = regex.stringByReplacingMatches(
                in: spaced, range: NSRange(spaced.startIndex..., in: spaced), withTemplate: template
            )
        }
        replace(acronymBoundary, "$1 $2")
        replace(camelBoundary, "$1 $2")
        replace(digitBoundaryA, "$1 $2")
        replace(digitBoundaryB, "$1 $2")
        let pieces = spaced.split(whereSeparator: \.isWhitespace).map(String.init)
        let form = pieces.map(folded).joined(separator: " ")
        guard !form.isEmpty else { return [] }
        let acronymForm = pieces.flatMap(expandKnownAcronyms).map(folded).joined(separator: " ")
        return acronymForm == form ? [form] : [form, acronymForm]
    }

    private static func expandKnownAcronyms(_ word: String) -> [String] {
        guard word.count >= 4, word.allSatisfy(\.isUppercase) else { return [word] }
        var remaining = word[...]
        var result: [String] = []
        while !remaining.isEmpty {
            guard let acronym = knownAcronyms.first(where: { remaining.hasPrefix($0) }) else {
                return [word]
            }
            result.append(acronym)
            remaining = remaining.dropFirst(acronym.count)
        }
        return result.count > 1 ? result : [word]
    }

    private static func scrubCode(_ input: String) -> String {
        enum State {
            case normal, single, double, tripleSingle, tripleDouble, backtick
            case lineComment, blockComment, htmlComment
        }
        let characters = Array(input)
        var state = State.normal
        var escaped = false
        var blockDepth = 0
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0

        func starts(_ literal: String) -> Bool {
            let wanted = Array(literal)
            guard index + wanted.count <= characters.count else { return false }
            return Array(characters[index..<(index + wanted.count)]) == wanted
        }
        func appendMasked(_ count: Int) {
            for offset in 0..<count {
                let character = characters[index + offset]
                output.append(character == "\n" || character == "\r" ? character : " ")
            }
            index += count
        }
        func appendMaskedCharacter(_ character: Character) {
            output.append(character == "\n" || character == "\r" ? character : " ")
            index += 1
        }

        while index < characters.count {
            let character = characters[index]
            switch state {
            case .normal:
                if starts("//") {
                    state = .lineComment
                    appendMasked(2)
                } else if starts("--") {
                    state = .lineComment
                    appendMasked(2)
                } else if starts("/*") {
                    state = .blockComment
                    blockDepth = 1
                    appendMasked(2)
                } else if starts("<!--") {
                    state = .htmlComment
                    appendMasked(4)
                } else if starts("\"\"\"") {
                    state = .tripleDouble
                    appendMasked(3)
                } else if starts("'''") {
                    state = .tripleSingle
                    appendMasked(3)
                } else if character == "'" {
                    state = .single
                    escaped = false
                    appendMaskedCharacter(character)
                } else if character == "\"" {
                    state = .double
                    escaped = false
                    appendMaskedCharacter(character)
                } else if character == "`" {
                    state = .backtick
                    escaped = false
                    appendMaskedCharacter(character)
                } else if character == "#" {
                    if starts("#![") {
                        appendMasked(2)
                    } else if starts("#[") {
                        appendMaskedCharacter(character)
                    } else if starts("#!") {
                        state = .lineComment
                        appendMasked(2)
                    } else {
                        let prev: Character? = index > 0 ? characters[index - 1] : nil
                        let next: Character? = (index + 1 < characters.count) ? characters[index + 1] : nil
                        let precededByExpressionEnd = prev.map {
                            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "\"" || $0 == "'" || $0 == ")" || $0 == "]"
                        } ?? false
                        let followedByDirectiveOrPrivateIdent = next.map {
                            $0.isLetter || $0 == "_" || $0 == "$"
                        } ?? false
                        if !precededByExpressionEnd && followedByDirectiveOrPrivateIdent {
                            appendMaskedCharacter(character)
                        } else {
                            state = .lineComment
                            appendMaskedCharacter(character)
                        }
                    }
                } else {
                    output.append(character)
                    index += 1
                }

            case .single, .double:
                let delimiter: Character = state == .single ? "'" : "\""
                if character == "\n" || character == "\r" {
                    state = .normal
                    escaped = false
                } else if character == delimiter, !escaped {
                    state = .normal
                }
                if character == "\\" { escaped.toggle() } else { escaped = false }
                appendMaskedCharacter(character)

            case .tripleSingle:
                if starts("'''") {
                    state = .normal
                    appendMasked(3)
                } else {
                    appendMaskedCharacter(character)
                }

            case .tripleDouble:
                if starts("\"\"\"") {
                    state = .normal
                    appendMasked(3)
                } else {
                    appendMaskedCharacter(character)
                }

            case .backtick:
                if character == "`", !escaped { state = .normal }
                if character == "\\" { escaped.toggle() } else { escaped = false }
                appendMaskedCharacter(character)

            case .lineComment:
                if character == "\n" || character == "\r" { state = .normal }
                appendMaskedCharacter(character)

            case .blockComment:
                if starts("/*") {
                    blockDepth += 1
                    appendMasked(2)
                } else if starts("*/") {
                    blockDepth -= 1
                    if blockDepth == 0 { state = .normal }
                    appendMasked(2)
                } else {
                    appendMaskedCharacter(character)
                }

            case .htmlComment:
                if starts("-->") {
                    state = .normal
                    appendMasked(3)
                } else {
                    appendMaskedCharacter(character)
                }
            }
        }
        return String(output)
    }

    private static func looksSecret(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("sk_")
            || lower.hasPrefix("pk_") || lower.hasPrefix("ghp_")
            || lower.hasPrefix("gho_") || lower.hasPrefix("ghu_")
            || lower.hasPrefix("ghs_") || lower.hasPrefix("ghr_")
            || lower.hasPrefix("github_pat_") || lower.hasPrefix("xox")
            || lower.hasPrefix("aiza") || lower.hasPrefix("ya29")
            || lower.hasPrefix("eyj") || lower.hasPrefix("akia")
            || lower.hasPrefix("asia") { return true }
        if token.contains("@") || lower.hasPrefix("http") || token.contains("/") { return true }
        let hex = token.allSatisfy { $0.isHexDigit || $0 == "-" }
        if hex && token.filter({ $0.isHexDigit }).count >= 16 { return true }
        let digits = token.filter(\.isNumber).count
        let uppercase = token.filter(\.isUppercase).count
        let lowercase = token.filter(\.isLowercase).count
        if token.count >= 16, digits > 0, lowercase == 0, uppercase >= 8 { return true }
        if token.count >= 16, digits * 3 > token.count { return true }
        if token.count >= 20 {
            let kinds = [lowercase > 0, uppercase > 0, digits > 0].filter { $0 }.count
            if kinds >= 3 { return true }
            let hasSeparator = token.contains("_") || token.contains("-") || token.contains(".")
            let hasInternalUpper = token.dropFirst().contains(where: \.isUppercase)
            if digits > 0, !hasSeparator, !hasInternalUpper { return true }
        }
        return false
    }

    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
