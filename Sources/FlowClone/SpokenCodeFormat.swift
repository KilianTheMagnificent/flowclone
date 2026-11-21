import Foundation

/// Deterministic spoken identifier & inline-code formatting for coding and agent contexts:
/// - "camel case get user id" -> "getUserId"
/// - "snake case max retry count" -> "max_retry_count"
/// - "pascal case user session store" -> "UserSessionStore"
/// - "kebab case feature flag toggle" -> "feature-flag-toggle"
/// - "screaming snake case api base url" -> "API_BASE_URL"
/// - "backtick handleTap" -> "`handleTap`" (composes with casing cues too)
enum SpokenCodeFormat {
    enum Style: Sendable {
        case camel
        case snake
        case pascal
        case kebab
        case screamingSnake

        func format(_ words: [String]) -> String {
            let parts = words.flatMap(SpokenCodeFormat.splitSubwords).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return "" }
            switch self {
            case .camel:
                let head = parts[0].lowercased()
                let tail = parts.dropFirst().map(SpokenCodeFormat.capitalizedPart)
                return ([head] + tail).joined()
            case .pascal:
                return parts.map(SpokenCodeFormat.capitalizedPart).joined()
            case .snake:
                return parts.map { $0.lowercased() }.joined(separator: "_")
            case .kebab:
                return parts.map { $0.lowercased() }.joined(separator: "-")
            case .screamingSnake:
                return parts.map { $0.uppercased() }.joined(separator: "_")
            }
        }
    }

    private static let maxIdentifierWords = 6

    private static let casingTrigger = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_-])(screaming[ \t]+snake|upper[ \t]+snake|constant|camel|snake|pascal|kebab)[ \t]+case[ \t]*[,.]?[ \t]+"#
    )

    private static let backtickTrigger = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_`-])backtick[ \t]*,?[ \t]+"#
    )

    /// Words that never begin a spoken identifier right after `<style> case`.
    private static let invalidFirstWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "vs", "versus", "so", "then",
        "because", "since", "while", "where", "which", "when", "that", "this",
        "these", "those", "are", "was", "were", "be", "been", "being",
    ]

    /// Words that cannot be a single-word identifier on their own ("Snake case is used…").
    private static let invalidSingleWords: Set<String> = [
        "is", "has", "have", "had", "do", "does", "did", "can", "could",
        "will", "would", "should", "must", "may", "might", "in", "on", "at",
        "to", "for", "of", "by", "with", "from", "as", "into",
    ]

    /// Clause/prose boundaries that stop a multi-word spoken identifier after at least one word.
    private static let hardBoundaryWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then", "because", "since",
        "while", "unless", "until", "where", "which", "when", "that", "this",
        "these", "those", "please", "instead", "rather", "are", "was", "were",
        "will", "would", "should", "could", "must", "cannot", "it", "we", "you",
        "they", "he", "she", "slash", "backtick",
    ]

    private static let prepositions: Set<String> = [
        "in", "into", "from", "with", "without", "for", "at", "on", "by",
        "to", "of", "as", "after", "before", "under", "over", "inside", "outside",
    ]

    private static let proseDeterminersAndCommands: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "our", "your",
        "its", "their", "it", "them", "me", "us", "be", "make", "return", "use",
        "run", "check", "ensure", "avoid", "keep", "true", "false", "nil", "null",
        "camel", "snake", "pascal", "kebab", "screaming", "upper", "constant",
        "backtick", "slash",
    ]

    private static let relationalLeadVerbs: Set<String> = [
        "rename", "renamed", "renaming", "change", "changed", "changing",
        "set", "setting", "move", "moved", "moving", "map", "mapped", "mapping",
        "convert", "converted", "converting", "update", "updated", "updating",
        "pass", "passed", "passing", "send", "sent", "sending", "bind", "bound",
        "assign", "assigned", "replace", "replaced", "replacing",
    ]

    private static let backtickProseNouns: Set<String> = [
        "key", "keys", "character", "characters", "symbol", "symbols", "mark",
        "marks", "quote", "quotes", "syntax", "fence", "fences", "block", "blocks",
        "is", "are", "was", "were", "and", "or", "to",
    ]

    static func apply(_ text: String, bundleID: String?) -> String {
        let profile = AppProfiles.shared.resolve(bundleID: bundleID)
        return apply(text, enabled: profile.codeFormattingEnabled)
    }

    static func apply(_ text: String, enabled: Bool = true) -> String {
        guard enabled, !text.isEmpty else { return text }
        let hasCase = text.range(of: "case", options: .caseInsensitive) != nil
        let hasBacktick = text.range(of: "backtick", options: .caseInsensitive) != nil
        guard hasCase || hasBacktick else { return text }

        var current = text
        var standalone = false

        if hasCase {
            let formatted = applyCasing(current)
            current = formatted.text
            if formatted.standalone { standalone = true }
        }
        if current.range(of: "backtick", options: .caseInsensitive) != nil {
            let wrapped = applyBackticks(current)
            current = wrapped.text
            if wrapped.standalone { standalone = true }
        }
        if standalone {
            while let last = current.last, last == " " || last == "\t" {
                current.removeLast()
            }
            if current.hasSuffix("."), !current.hasSuffix("..") {
                current.removeLast()
            }
        }
        return current
    }

    // MARK: - Casing Pass

    private static func applyCasing(_ text: String) -> (text: String, standalone: Bool) {
        let matches = casingTrigger.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return (text, false) }

        var out = ""
        var cursor = text.startIndex
        var replacedCount = 0
        var firstReplacedAtStart = false
        var lastEndIndex = text.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let styleRange = Range(match.range(at: 1), in: text),
                  fullRange.lowerBound >= cursor else { continue }

            let style = parseStyle(text[styleRange])
            let hasRelationalVerb = containsRelationalVerb(in: text[cursor..<fullRange.lowerBound])
            guard let (words, endIndex) = collectIdentifierWords(
                after: fullRange.upperBound,
                in: text,
                hasRelationalVerb: hasRelationalVerb
            ) else {
                continue
            }
            let formatted = style.format(words)
            guard !formatted.isEmpty else { continue }

            if replacedCount == 0, text[..<fullRange.lowerBound].allSatisfy(\.isWhitespace) {
                firstReplacedAtStart = true
            }
            out.append(contentsOf: text[cursor..<fullRange.lowerBound])
            out.append(formatted)
            cursor = endIndex
            lastEndIndex = endIndex
            replacedCount += 1
        }

        guard replacedCount > 0 else { return (text, false) }
        let trailing = text[cursor...]
        out.append(contentsOf: trailing)
        let standalone = replacedCount == 1
            && firstReplacedAtStart
            && isTrailingTerminatorOnly(text[lastEndIndex...])
        return (out, standalone)
    }

    private static func parseStyle(_ raw: Substring) -> Style {
        let compact = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch compact {
        case "camel": return .camel
        case "snake": return .snake
        case "pascal": return .pascal
        case "kebab": return .kebab
        default: return .screamingSnake
        }
    }

    private static func containsRelationalVerb(in prefix: Substring) -> Bool {
        let lineStart = prefix.lastIndex(where: { $0.isNewline || ".!?;:".contains($0) })
            .map { prefix.index(after: $0) } ?? prefix.startIndex
        let clause = prefix[lineStart...]
        let tokens = clause.split { !($0.isLetter || $0 == "'") }.map { $0.lowercased() }
        return tokens.contains { relationalLeadVerbs.contains($0) }
    }

    private static func collectIdentifierWords(
        after start: String.Index,
        in text: String,
        hasRelationalVerb: Bool
    ) -> ([String], String.Index)? {
        var collected: [(word: String, end: String.Index)] = []
        var idx = start

        while collected.count < maxIdentifierWords, idx < text.endIndex {
            guard isIdentifierChar(text[idx]) else { break }
            let wordEnd = text[idx...].firstIndex(where: { !isIdentifierChar($0) }) ?? text.endIndex
            let token = String(text[idx..<wordEnd])
            let lower = token.lowercased()

            if collected.isEmpty {
                if invalidFirstWords.contains(lower) { return nil }
            } else {
                if hardBoundaryWords.contains(lower) { break }
                if isNextCasingCommand(at: idx, wordEnd: wordEnd, lower: lower, in: text) { break }
                if prepositions.contains(lower) {
                    let nextLower = peekNextWord(after: wordEnd, in: text)?.lowercased()
                    if nextLower == nil { break }
                    if let nextLower, proseDeterminersAndCommands.contains(nextLower) { break }
                    if hasRelationalVerb && (lower == "to" || lower == "in" || lower == "into" || lower == "from") {
                        break
                    }
                    if let nextLower, nextLower.allSatisfy(\.isNumber) { break }
                }
            }

            collected.append((token, wordEnd))

            // Stop at any punctuation or newline; only horizontal spaces join spoken words.
            var spaceEnd = wordEnd
            while spaceEnd < text.endIndex, text[spaceEnd] == " " || text[spaceEnd] == "\t" {
                spaceEnd = text.index(after: spaceEnd)
            }
            guard spaceEnd > wordEnd, spaceEnd < text.endIndex, isIdentifierChar(text[spaceEnd]) else {
                break
            }
            idx = spaceEnd
        }

        guard !collected.isEmpty else { return nil }
        if collected.count == 1, invalidSingleWords.contains(collected[0].word.lowercased()) {
            return nil
        }
        return (collected.map(\.word), collected.last!.end)
    }

    private static func isNextCasingCommand(
        at wordStart: String.Index,
        wordEnd: String.Index,
        lower: String,
        in text: String
    ) -> Bool {
        if ["camel", "snake", "pascal", "kebab", "constant"].contains(lower) {
            return peekNextWord(after: wordEnd, in: text)?.lowercased() == "case"
        }
        if lower == "screaming" || lower == "upper" {
            guard let second = peekNextWordSpan(after: wordEnd, in: text),
                  second.word.lowercased() == "snake" else { return false }
            return peekNextWord(after: second.end, in: text)?.lowercased() == "case"
        }
        let tailRange = NSRange(wordStart..<text.endIndex, in: text)
        if let match = casingTrigger.firstMatch(in: text, range: tailRange),
           match.range.location == tailRange.location {
            return true
        }
        return false
    }

    private static func peekNextWord(after index: String.Index, in text: String) -> String? {
        peekNextWordSpan(after: index, in: text)?.word
    }

    private static func peekNextWordSpan(
        after index: String.Index,
        in text: String
    ) -> (word: String, end: String.Index)? {
        var i = index
        while i < text.endIndex, text[i] == " " || text[i] == "\t" {
            i = text.index(after: i)
        }
        guard i < text.endIndex, isIdentifierChar(text[i]) else { return nil }
        let end = text[i...].firstIndex(where: { !isIdentifierChar($0) }) ?? text.endIndex
        return (String(text[i..<end]), end)
    }

    // MARK: - Backtick Pass

    private static func applyBackticks(_ text: String) -> (text: String, standalone: Bool) {
        let matches = backtickTrigger.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return (text, false) }

        var out = ""
        var cursor = text.startIndex
        var replacedCount = 0
        var firstReplacedAtStart = false
        var lastEndIndex = text.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  fullRange.lowerBound >= cursor else { continue }

            let precedingWord = lastWord(in: text[..<fullRange.lowerBound])?.lowercased()
            let hadArticle = precedingWord == "a" || precedingWord == "an" || precedingWord == "the"

            guard let (symbol, symbolEnd) = scanSymbol(after: fullRange.upperBound, in: text) else {
                continue
            }
            let lowerSymbol = symbol.lowercased()
            if backtickProseNouns.contains(lowerSymbol) {
                continue
            }
            if hadArticle && ["character", "key", "quote", "mark", "symbol"].contains(lowerSymbol) {
                continue
            }

            if replacedCount == 0, text[..<fullRange.lowerBound].allSatisfy(\.isWhitespace) {
                firstReplacedAtStart = true
            }
            out.append(contentsOf: text[cursor..<fullRange.lowerBound])
            out.append("`\(symbol)`")
            cursor = symbolEnd
            lastEndIndex = symbolEnd
            replacedCount += 1
        }

        guard replacedCount > 0 else { return (text, false) }
        out.append(contentsOf: text[cursor...])
        let standalone = replacedCount == 1
            && firstReplacedAtStart
            && isTrailingTerminatorOnly(text[lastEndIndex...])
        return (out, standalone)
    }

    private static func scanSymbol(after start: String.Index, in text: String) -> (String, String.Index)? {
        guard start < text.endIndex else { return nil }
        let first = text[start]
        guard first.isLetter || first.isNumber || "_/@#$".contains(first) else { return nil }

        var end = start
        while end < text.endIndex {
            let c = text[end]
            if c.isLetter || c.isNumber || "_-:/@#$".contains(c) {
                end = text.index(after: end)
                continue
            }
            // Keep internal dots (`Cleaner.swift`, `Self.validated`), never sentence-ending `.`.
            if c == "." {
                let next = text.index(after: end)
                if next < text.endIndex, text[next].isLetter || text[next].isNumber || text[next] == "_" {
                    end = next
                    continue
                }
            }
            // Keep trailing `()` on an explicit call symbol (`handleTap()`).
            if c == "(" {
                let next = text.index(after: end)
                if next < text.endIndex, text[next] == ")" {
                    end = text.index(after: next)
                }
            }
            break
        }
        // Trim trailing `:` if it was sentence punctuation rather than a namespace separator.
        while end > start, text[text.index(before: end)] == ":" {
            end = text.index(before: end)
        }
        guard end > start else { return nil }
        return (String(text[start..<end]), end)
    }

    private static func lastWord(in slice: Substring) -> String? {
        let trimmed = slice.reversed().drop(while: { $0 == " " || $0 == "\t" })
        let letters = trimmed.prefix(while: \.isLetter)
        guard !letters.isEmpty else { return nil }
        return String(letters.reversed())
    }

    private static func isTrailingTerminatorOnly(_ rest: Substring) -> Bool {
        let trimmed = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.isEmpty || trimmed == "."
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-"
    }

    fileprivate static func splitSubwords(_ token: String) -> [String] {
        let pieces = token.split { $0 == "_" || $0 == "-" }
        var out: [String] = []
        for piece in pieces where !piece.isEmpty {
            let chars = Array(piece)
            var start = 0
            for i in 1..<chars.count {
                let prev = chars[i - 1]
                let curr = chars[i]
                let nextLower = (i + 1 < chars.count) ? chars[i + 1].isLowercase : false
                let splitCamel = (prev.isLowercase || prev.isNumber) && curr.isUppercase
                let splitAcronym = prev.isUppercase && curr.isUppercase && nextLower
                if splitCamel || splitAcronym {
                    out.append(String(chars[start..<i]))
                    start = i
                }
            }
            out.append(String(chars[start...]))
        }
        return out
    }

    fileprivate static func capitalizedPart(_ part: String) -> String {
        guard let first = part.first else { return "" }
        return String(first).uppercased() + part.dropFirst().lowercased()
    }
}
