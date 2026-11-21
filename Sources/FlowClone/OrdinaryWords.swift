import AppKit

/// Tells an ordinary English word from a spelling the recognizer made up. The dictionary
/// matcher repairs only the second kind: "Kubernets" is a guess at a name, while
/// "interact" is what the speaker said and must not become "Interface".
enum OrdinaryWords {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var answers: [String: Bool] = [:]
        var override: ((String) -> Bool)?
        var systemAnswers: Bool?
    }

    private static let state = State()
    private static let cacheLimit = 4_096

    static func contains(_ word: String) -> Bool {
        let key = word.lowercased()
        // Digits and symbols mark an identifier, never an ordinary word.
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" }) else {
            return false
        }
        state.lock.lock()
        defer { state.lock.unlock() }
        if let override = state.override { return override(key) }
        if let known = state.answers[key] { return known }
        let known = systemContains(key)
        if state.answers.count >= cacheLimit { state.answers.removeAll(keepingCapacity: true) }
        state.answers[key] = known
        return known
    }

    /// Test seam: a fixed word list instead of the Mac's spelling dictionary.
    @discardableResult
    static func withWords<T>(_ isKnown: @escaping (String) -> Bool,
                             _ body: () throws -> T) rethrows -> T {
        state.lock.lock()
        let previous = state.override
        state.override = isKnown
        state.lock.unlock()
        defer {
            state.lock.lock()
            state.override = previous
            state.lock.unlock()
        }
        return try body()
    }

    /// The system dictionary knows inflections and current vocabulary, which a bundled
    /// list would not. If it cannot answer a trivial question, every word counts as
    /// ordinary: exact dictionary matches still apply and nothing is rewritten on a guess.
    private static func systemContains(_ word: String) -> Bool {
        if state.systemAnswers == nil {
            let answers = isSpelledCorrectly("the") && !isSpelledCorrectly("zxqvkjw")
            state.systemAnswers = answers
            if !answers { log("dictionary: spelling service unavailable; fuzzy matches are off") }
        }
        guard state.systemAnswers == true else { return true }
        return isSpelledCorrectly(word)
    }

    private static func isSpelledCorrectly(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }
}
