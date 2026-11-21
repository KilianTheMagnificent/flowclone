import Foundation
import XCTest
@testable import FlowCloneCore

final class DictionaryMatchTests: XCTestCase {
    private var root: URL!
    private var store: PersonalizationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PersonalizationStore(root: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    private func writeDictionary(_ terms: [String]) throws {
        try Data((terms.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("dictionary.txt"), options: .atomic)
    }

    private let terms = [
        "FlowClone", "FluidAudio", "Parakeet", "yeah", "Constellation", "Hegemon", "Interface",
        "orrery", "luck-filter", "Anthropic", "Claude", "Accessibility", "Apple Intelligence",
        "Apple Silicon", "transcript", "dictation", "tokenizer", "Kubernetes",
    ]

    /// Stands in for the Mac's spelling dictionary so the cases do not depend on it.
    private let english: Set<String> = [
        "a", "an", "and", "app", "apple", "audio", "claud", "clone", "consultation", "cooper",
        "dictating", "dictations", "filter", "flow", "fluid", "go", "hegemony", "here",
        "intelligence", "interact", "interfaced", "is", "it", "let's", "luck", "model", "of",
        "or", "para", "per", "possibility", "second", "that", "the", "tokens", "transcription",
        "very", "with", "yeah",
    ]

    private func clean(_ text: String) -> String {
        OrdinaryWords.withWords(english.contains) {
            Cleaner.withPersonalizationStore(store) { Cleaner.clean(text) }
        }
    }

    /// Every sentence here was changed by build 2026111201 on the owner's dictations.
    func testOrdinaryWordsAreNotRewrittenIntoDictionaryTerms() throws {
        try writeDictionary(terms)
        for sentence in [
            "Less important than the intelligence of the model.",
            "Tooling should interact with that.",
            "Offer a more extensive consultation package.",
            "Is that a possibility?",
            "Themes that are repetitive or very similar.",
            "A tokens per second indicator.",
            "The last couple of dictations took a long time.",
            "When I'm dictating with headphones in.",
            "The meeting transcription feature works.",
            "It is interfaced using the same font.",
            "Base the design off of Anthropic's app.",
            "Hegemony is the goal.",
        ] {
            XCTAssertEqual(clean(sentence), sentence)
        }
    }

    func testInventedSpellingsAreStillRepaired() throws {
        try writeDictionary(terms)
        for (spoken, wanted) in [
            ("Ask what Anthrop could do.", "Ask what Anthropic could do."),
            ("It runs on Kubernets now.", "It runs on Kubernetes now."),
            ("Use para keet for speech.", "Use Parakeet for speech."),
            ("Compare apple intelligents to it.", "Compare Apple Intelligence to it."),
        ] {
            XCTAssertEqual(clean(spoken), wanted)
        }
    }

    func testExactSpellingsAreRestoredWhateverTheWords() throws {
        try writeDictionary(terms)
        for (spoken, wanted) in [
            ("Open flow clone and fluid audio.", "Open FlowClone and FluidAudio."),
            ("Run luck filter again.", "Run luck-filter again."),
            ("Does it need Apple intelligence?", "Does it need Apple Intelligence?"),
            ("Open the interface.", "Open the Interface."),
            ("Check anthropic's pricing.", "Check Anthropic's pricing."),
        ] {
            XCTAssertEqual(clean(spoken), wanted)
        }
    }

    /// A real word the recognizer capitalized mid-sentence was heard as a name.
    func testRecognizedNameIsRepairedOnlyInsideASentence() throws {
        try writeDictionary(terms)
        XCTAssertEqual(clean("Recreate the Claud app."), "Recreate the Claude app.")
        XCTAssertEqual(clean("Use the Claud's app."), "Use the Claude's app.")
        XCTAssertEqual(clean("Claud is here."), "Claud is here.")
    }

    func testLowercaseTermKeepsTheCapitalThatOpensASentence() throws {
        try writeDictionary(terms)
        XCTAssertEqual(clean("Yeah, let's go. Yeah."), "Yeah, let's go. Yeah.")
        XCTAssertEqual(clean("Go.\nYeah, go."), "Go.\nYeah, go.")
        XCTAssertEqual(clean("It is Yeah here."), "It is yeah here.")
        XCTAssertEqual(clean("Orery is here."), "Orrery is here.")
    }

    /// The shipped path: the Mac's own spelling dictionary decides what a real word is.
    func testSystemDictionaryGuardsTheReportedSentence() throws {
        try writeDictionary(terms)
        Cleaner.withPersonalizationStore(store) {
            let reported = "Less important than the intelligence of the model."
            XCTAssertEqual(Cleaner.clean(reported), reported)
            XCTAssertEqual(Cleaner.clean("Tooling should interact with that."),
                           "Tooling should interact with that.")
            XCTAssertEqual(Cleaner.clean("It runs on Kubernets now."), "It runs on Kubernetes now.")
        }
    }

    /// Audit hook for matcher changes. FLOWCLONE_DICTIONARY_CORPUS names a History-style JSONL
    /// file (one object per line with a "raw" string) and FLOWCLONE_DICTIONARY_FILE a
    /// dictionary.txt. Every substitution is written to `<corpus>.changes.txt` and every
    /// cleaned dictation to `<corpus>.cleaned.txt`, so two builds can be diffed.
    func testDictionaryCorpusAudit() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpus = environment["FLOWCLONE_DICTIONARY_CORPUS"],
              let dictionary = environment["FLOWCLONE_DICTIONARY_FILE"] else {
            throw XCTSkip("set FLOWCLONE_DICTIONARY_CORPUS and FLOWCLONE_DICTIONARY_FILE to audit a corpus")
        }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: dictionary),
            to: root.appendingPathComponent("dictionary.txt")
        )
        let rows = try String(contentsOfFile: corpus, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                return object?["raw"] as? String
            }
        var changes: [String] = []
        var cleaned: [String] = []
        Cleaner.withPersonalizationStore(store) {
            for raw in rows {
                let result = Cleaner.cleanWithChanges(raw)
                changes += result.changes.map { "\($0.original) → \($0.replacement)" }
                cleaned.append(result.text.replacingOccurrences(of: "\n", with: "\\n"))
            }
        }
        try changes.joined(separator: "\n").write(toFile: corpus + ".changes.txt",
                                                  atomically: true, encoding: .utf8)
        try cleaned.joined(separator: "\n").write(toFile: corpus + ".cleaned.txt",
                                                  atomically: true, encoding: .utf8)
    }
}
