import Foundation

enum DictationInput: String, Codable, CaseIterable, Sendable, Identifiable {
    case normal, literal, spelling
    var id: String { rawValue }
    var title: String {
        switch self { case .normal: "Dictation"; case .literal: "Literal text"; case .spelling: "Spelling" }
    }
    var isVerbatim: Bool { self != .normal }
}

enum CapturePurpose: Equatable, Sendable {
    case editor(DictationInput), draft, practice, instruction(Int)
    var input: DictationInput {
        if case .editor(let input) = self { return input }
        return .normal
    }
    var usesCleanup: Bool {
        switch self { case .instruction, .practice: false; default: !input.isVerbatim }
    }
    var learns: Bool { self == .editor(.normal) }
    var title: String {
        switch self { case .editor(let input): input.title; case .draft: "Draft"; case .practice: "Practice"; case .instruction: "Edit instruction" }
    }
}

/// Character entry is deliberately separate from ordinary ASR cleanup. Unknown words
/// fail rather than guessing a letter, and no continuation formatter touches this output.
enum SpellingParser {
    enum Failure: Error, LocalizedError {
        case unknown(String), empty
        var errorDescription: String? {
            switch self {
            case .unknown(let token): "Could not spell ‘\(token)’. Use letter names or the phonetic alphabet."
            case .empty: "No letters were recognized."
            }
        }
    }
    static let alphabet = ["alpha":"a", "bravo":"b", "charlie":"c", "delta":"d", "echo":"e",
        "foxtrot":"f", "golf":"g", "hotel":"h", "india":"i", "juliet":"j", "juliett":"j",
        "kilo":"k", "lima":"l", "mike":"m", "november":"n", "oscar":"o", "papa":"p",
        "quebec":"q", "romeo":"r", "sierra":"s", "tango":"t", "uniform":"u", "victor":"v",
        "whiskey":"w", "whisky":"w", "xray":"x", "yankee":"y", "zulu":"z",
        "zero":"0", "one":"1", "two":"2", "three":"3", "four":"4", "five":"5", "six":"6",
        "seven":"7", "eight":"8", "nine":"9", "underscore":"_", "dash":"-", "hyphen":"-",
        "dot":".", "period":".", "slash":"/", "backslash":"\\", "colon":":", "space":" ",
        "at":"@", "plus":"+", "equals":"=", "hash":"#"]

    static func parse(_ speech: String) throws -> String {
        let normalized = speech.lowercased().replacingOccurrences(of: "x-ray", with: "xray")
            .replacingOccurrences(of: "x ray", with: "xray")
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace || ",.!?;".contains($0) }).map(String.init)
        var output = "", uppercase = false, upperNext = false
        for token in tokens {
            if ["uppercase", "capitals"].contains(token) { uppercase = true; continue }
            if ["lowercase", "lower"].contains(token) { uppercase = false; continue }
            if ["capital", "capitalize"].contains(token) { upperNext = true; continue }
            let value: String
            if let letter = alphabet[token] { value = letter }
            else if token.count == 1, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { value = token }
            else { throw Failure.unknown(token) }
            output += uppercase || upperNext ? value.uppercased() : value
            upperNext = false
        }
        guard !output.isEmpty else { throw Failure.empty }
        return output
    }
}

enum TextFormatter: String, CaseIterable, Identifiable, Sendable {
    case sentence = "Sentence case", upper = "UPPERCASE", lower = "lowercase"
    case snake = "snake_case", camel = "camelCase", kebab = "kebab-case", bullets = "Bullet list"
    var id: String { rawValue }
    func apply(_ input: String) -> String {
        switch self {
        case .upper: return input.uppercased()
        case .lower: return input.lowercased()
        case .sentence: return input.prefix(1).uppercased() + input.dropFirst()
        case .bullets:
            return input.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "• " + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .snake, .camel, .kebab:
            let words = input.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
            if self == .camel { return (words.first ?? "") + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() }
            return words.joined(separator: self == .snake ? "_" : "-")
        }
    }
}

enum SpokenEdit {
    /// nil means use the existing local Custom transform, always with preview.
    static func deterministic(_ instruction: String, original: String) -> String? {
        let phrase = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = phrase.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let formats: [String: TextFormatter] = ["uppercase": .upper, "make uppercase": .upper,
            "lowercase": .lower, "make lowercase": .lower, "snake case": .snake,
            "camel case": .camel, "kebab case": .kebab, "make a bullet list": .bullets]
        if let formatter = formats[command] { return formatter.apply(original) }
        let prefix = "replace selection with "
        if phrase.lowercased().hasPrefix(prefix) {
            let replacement = String(phrase.dropFirst(prefix.count))
            return replacement.isEmpty ? nil : replacement
        }
        if command.hasPrefix("spell ") { return try? SpellingParser.parse(String(phrase.dropFirst(6))) }
        return nil
    }
}
