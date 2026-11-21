import Foundation
import XCTest
@testable import FlowCloneCore

/// The fixtures of the former `Cleaner.selfCheck()`, whose launch flag was removed. The
/// strings are verbatim; the private dictionary/correction/snippet override seams it used
/// are replaced by one real PersonalizationStore holding the same content.
final class CleanerTests: XCTestCase {
    private var root: URL!
    private var store: PersonalizationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-cleaner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PersonalizationStore(root: root)
        // The shipped dictionary seed, plus the terms the provenance and tie cases need.
        try write("""
            FlowClone
            FluidAudio
            Parakeet
            Wispr
            Quote
            NewLine
            Context Vocabulary
            ContextA
            ContextB

            """, "dictionary.txt")
        // File order is rule order: "cooper netties" before "C#" is what the ordering case
        // below asserts, and alpha/beta prove replacements never cascade.
        try write("""
            cooper netties -> Kubernetes
            C# -> C-sharp
            andre -> Andre
            alpha -> beta
            beta -> Gamma
            remove me -> um

            """, "corrections.txt")
        try write("""
            ttyl -> talk to you later
            flow clone -> FlowClone 1.0
            asr note -> floyd audio ticket
            sig -> Andre\\nFlowClone

            """, "snippets.txt")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    private func write(_ text: String, _ filename: String, modifiedAt: Date? = nil) throws {
        let url = root.appendingPathComponent(filename)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt],
                                                  ofItemAtPath: url.path)
        }
    }

    private func expectClean(_ cases: [(String, String)],
                             file: StaticString = #filePath, line: UInt = #line) {
        Cleaner.withPersonalizationStore(store) {
            for (input, want) in cases {
                XCTAssertEqual(Cleaner.clean(input), want, input, file: file, line: line)
            }
        }
    }

    func testFillerFilter() {
        expectClean([
            ("Um, this is a test.", "This is a test."),
            ("This is, um, a test.", "This is, a test."),
            ("So uh yeah, remove the, uhm, menu bar.", "So yeah, remove the, menu bar."),
            ("Uh-huh, sounds good.", "Uh-huh, sounds good."),
            ("The word umbrella stays.", "The word umbrella stays."),
            ("Worth it, um.", "Worth it."),
            ("Um.", ""),
            ("No fillers here.", "No fillers here."),
            // redteam LOW3: orphan space before non-comma punctuation is collapsed, the
            // stray comma is dropped, and a lowercase-initial proper noun keeps its case.
            ("What is it, uh?", "What is it?"),
            ("Um, iPhone sales are up.", "iPhone sales are up."),
            ("Let's ship it um. Tomorrow works", "Let's ship it. Tomorrow works"),
            ("Is it ready uh? Yes it is.", "Is it ready? Yes it is."),
        ])
    }

    func testClosedClassSpokenCorrections() {
        expectClean([
            ("Let's meet on Thursday, I mean Friday.", "Let's meet on Friday."),
            ("Let's meet on Thursday I mean Friday.", "Let's meet on Friday."),
            ("Ship it in March, no wait, April.", "Ship it in April."),
            ("The call is at 2 p.m., actually 3 p.m.", "The call is at 3 p.m."),
            ("Let's do the call at 2 actually make that 3.", "Let's do the call at 3."),
            ("Order 12, scratch that, 15 units.", "Order 15 units."),
            // an open-vocabulary name swap is SpokenRepairs' job; discourse uses stay
            ("Send it to Alice, I mean Sarah.", "Send it to Sarah."),
            ("Let's meet on Thursday, or rather Friday.", "Let's meet on Friday."),
            ("It doesn't actually tell you if you copied anything.", "It doesn't actually tell you if you copied anything."),
            ("The deploy is done. I mean, the whole thing went smoothly.", "The deploy is done. I mean, the whole thing went smoothly."),
            // mixed classes are not a repair pair
            ("Meet at 3, actually Friday works better.", "Meet at 3, actually Friday works better.")
        ])
    }

    func testDictionaryCorrection() {
        expectClean([
            ("We pinned fluid audio to 0.15.5.", "We pinned FluidAudio to 0.15.5."),
            ("Floyd audio is the ASR library.", "FluidAudio is the ASR library."),
            ("The para keet model.", "The Parakeet model."),
            ("Ship it with flowclone, please.", "Ship it with FlowClone, please."),
            ("The context vocabulary is local.", "The Context Vocabulary is local."),
            ("I switched from whisper to Parakeet.", "I switched from whisper to Parakeet."),
            ("Um, fluidaudio loads at launch.", "FluidAudio loads at launch."),
            ("open quote fluid audio unquote", "\"FluidAudio\""),   // quotes convert before fuzzy
            // redteam H3: shipped-seed collisions that must NOT fire — inflections and
            // short-word near-misses of the seed terms stay as ordinary English.
            ("The parakeets are loud outside.", "The parakeets are loud outside."),
            ("Wisps of smoke rose.", "Wisps of smoke rose."),
            ("flowclones everywhere", "flowclones everywhere"),
            ("Use ContextC here.", "Use ContextC here."),       // equal fuzzy tie is refused
        ])
    }

    func testLearnedCorrections() {
        expectClean([
            ("We deploy on cooper netties tomorrow.", "We deploy on Kubernetes tomorrow."),
            ("COOPER NETTIES is case insensitive.", "Kubernetes is case insensitive."),
            ("The word scooper stays.", "The word scooper stays."),
            // redteam LOW5: a left side with a non-word edge ("C#") must still fire.
            ("I write C# daily.", "I write C-sharp daily."),
        ])
    }

    func testSnippetExpansion() {
        expectClean([
            ("Cool, ttyl then.", "Cool, talk to you later then."),
            ("Ttyl.", "talk to you later"),                 // trigger + terminator = expansion
            ("TTYL now.", "talk to you later now."),
            ("Say ttyl, then ttyl again.", "Say talk to you later, then talk to you later again."),
            ("The ttyls are gone.", "The ttyls are gone."),  // no partial-word fire
            // review F-6: the trigger collides with a dictionary term — the fuzzy bigram
            // would turn "flow clone" into "FlowClone" and the snippet would never fire.
            ("Open flow clone now.", "Open FlowClone 1.0 now."),
            // …and the expansion body holds a near-dictionary word ("floyd audio") that the
            // fuzzy pass DOES rewrite outside the snippet, proving the body is shielded.
            ("Floyd audio: asr note please.", "FluidAudio: floyd audio ticket please."),
            ("Sig.", "Andre\nFlowClone"),                   // literal \n decodes on load
        ])
    }

    /// Provenance is asserted independently from final text: this is what prevents a future
    /// implementation from reporting fillers, punctuation or snippet expansion merely
    /// because raw != final. Ordering spans the learned and fuzzy passes.
    func testChangeProvenance() {
        let cases: [(name: String, input: String, text: String, changes: [String])] = [
            ("single/case dictionary", "Ship flowclone now.", "Ship FlowClone now.",
             ["flowclone->FlowClone[dictionary]"]),
            ("fuzzy bigram", "Use floyd audio today.", "Use FluidAudio today.",
             ["floyd audio->FluidAudio[dictionary]"]),
            ("mixed source order", "floyd audio meets cooper netties in flowclone.",
             "FluidAudio meets Kubernetes in FlowClone.",
             ["floyd audio->FluidAudio[dictionary]",
              "cooper netties->Kubernetes[learnedCorrection]",
              "flowclone->FlowClone[dictionary]"]),
            ("mixed order after fillers", "Um, uh, erm, uhm, cooper netties then floyd audio.",
             "Kubernetes then FluidAudio.",
             ["cooper netties->Kubernetes[learnedCorrection]",
              "floyd audio->FluidAudio[dictionary]"]),
            ("mixed reverse order after fillers", "Um, uh, floyd audio then cooper netties.",
             "FluidAudio then Kubernetes.",
             ["Floyd audio->FluidAudio[dictionary]",
              "cooper netties->Kubernetes[learnedCorrection]"]),
            ("mixed order after spoken punctuation",
             "open quote cooper netties then floyd audio unquote",
             "\"Kubernetes then FluidAudio\"",
             ["cooper netties->Kubernetes[learnedCorrection]",
              "floyd audio->FluidAudio[dictionary]"]),
            // The first "quote" survives; the identical second one belongs to the removed
            // spoken command. Raw anchors, not text alignment, must select the first.
            ("repeated word around spoken command", "say quote cooper netties open quote",
             "say Quote Kubernetes \"",
             ["quote->Quote[dictionary]", "cooper netties->Kubernetes[learnedCorrection]"]),
            ("repeated command plus removed learned result",
             "Say new line, remove me. New line", "Say NewLine.\n",
             ["new line->NewLine[dictionary]", "remove me->um[learnedCorrection]"]),
            // corrections.txt lists cooper netties before C#, opposite their text order here.
            ("learned rule order", "C# then cooper netties.", "C-sharp then Kubernetes.",
             ["C#->C-sharp[learnedCorrection]",
              "cooper netties->Kubernetes[learnedCorrection]"]),
            ("repeat metadata", "flowclone then flowclone.", "FlowClone then FlowClone.",
             ["flowclone->FlowClone[dictionary]", "flowclone->FlowClone[dictionary]"]),
            ("learned exact no-op", "Andre and andre.", "Andre and Andre.",
             ["andre->Andre[learnedCorrection]"]),
            ("learned actual casing", "Use COOPER NETTIES.", "Use Kubernetes.",
             ["COOPER NETTIES->Kubernetes[learnedCorrection]"]),
            ("learned rules do not cascade", "alpha is ready.", "beta is ready.",
             ["alpha->beta[learnedCorrection]"]),
            ("unchanged rejected and filler", "Um, FlowClone and parakeets.",
             "FlowClone and parakeets.", []),
            ("snippet body shield", "Floyd audio: asr note please.",
             "FluidAudio: floyd audio ticket please.",
             ["Floyd audio->FluidAudio[dictionary]"]),
            ("whole snippet shield", "asr note", "floyd audio ticket", []),
            ("dictionary-colliding snippet", "Open flow clone now.", "Open FlowClone 1.0 now.", []),
            ("exact multiword dictionary", "Use context vocabulary here.",
             "Use Context Vocabulary here.",
             ["context vocabulary->Context Vocabulary[dictionary]"]),
        ]
        Cleaner.withPersonalizationStore(store) {
            for item in cases {
                let got = Cleaner.cleanWithChanges(item.input)
                XCTAssertEqual(got.text, item.text, item.name)
                XCTAssertEqual(got.changes.map { "\($0.original)->\($0.replacement)[\($0.source)]" },
                               item.changes, item.name)
            }
        }
    }

    /// A trigger over the 60-character limit must be dropped at load, not scanned for on
    /// every utterance — so the long one is invisible to clean() while its file-mate loads.
    func testOversizedSnippetTriggerIsDroppedAtLoad() throws {
        let long = String(repeating: "a", count: 61)
        try write("\(long) -> expanded\nkept -> yes\n", "snippets.txt")

        Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean(long + "."), long + ".")
            XCTAssertEqual(Cleaner.clean("kept."), "yes")
        }
    }

    /// A stale config cache fails silently, so prove the mtime check notices an edit.
    /// (dictionary.txt has its own reload test in PersonalizationAndCleanerTests.)
    func testFillerAndSnippetFilesReloadWhenEdited() throws {
        try Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean("Zzsentinel stays."), "Zzsentinel stays.")
            XCTAssertEqual(Cleaner.clean("Say zzz."), "Say zzz.")
            // An explicit later mtime: the caches key on it, and two writes in the same test
            // can otherwise land close enough together to look unedited.
            try write("zzsentinel\n", "fillers.txt",
                      modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
            try write("zzz -> the expansion\n", "snippets.txt",
                      modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(Cleaner.clean("Zzsentinel stays."), "Stays.")
            XCTAssertEqual(Cleaner.clean("Say zzz."), "Say the expansion.")
        }
    }

    /// Snippet bodies can hold addresses, tokens or words that look like self-repairs, so
    /// `Cleaner.stage` must keep triggers unexpanded while `RepairReviewer` runs and splice
    /// surviving expansions only in `finish(_:)`.
    func testStagedCleanupDefersSnippetExpansionUntilAfterRepairReview() throws {
        let secretHome = "742 Evergreen Terrace, wait no, Suite 900"
        let secretWork = "sk-live-secret-token-999999"
        try write("""
            home addr -> \(secretHome)
            work key -> \(secretWork)
            flow clone -> FlowClone 1.0
            """, "snippets.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))

        Cleaner.withPersonalizationStore(store) {
            let input = "Send floyd audio to home addr, actually to work key."
            let staged = Cleaner.stage(input)
            XCTAssertFalse(staged.preSnippetText.contains(secretHome))
            XCTAssertFalse(staged.preSnippetText.contains(secretWork))
            XCTAssertEqual(staged.preSnippetText, "Send FluidAudio to home addr, actually to work key.")
            XCTAssertEqual(staged.changes.map { "\($0.original)->\($0.replacement)" }, ["floyd audio->FluidAudio"])
            XCTAssertTrue(staged.hasSnippets)
            XCTAssertFalse(staged.isBareSnippet)

            let windows = RepairReview.windows(in: staged.preSnippetText, scope: .full)
            XCTAssertEqual(windows.count, 1)
            XCTAssertFalse(windows[0].text.contains(secretHome))
            XCTAssertFalse(windows[0].text.contains(secretWork))

            final class TextBox: @unchecked Sendable {
                var value = ""
            }
            let box = TextBox()
            let finished = expectation(description: "review")
            RepairReviewer.run(
                staged.preSnippetText, windows, .full, .claude, concurrent: false,
                ask: { window, done in
                    XCTAssertFalse(window.contains(secretHome))
                    XCTAssertFalse(window.contains(secretWork))
                    done("Send FluidAudio to work key.", "ok")
                    return {}
                },
                done: { outcome in
                    box.value = outcome.text
                    finished.fulfill()
                })
            wait(for: [finished], timeout: 2)

            let final = staged.finish(box.value)
            XCTAssertEqual(final.text, "Send FluidAudio to \(secretWork).")
            XCTAssertEqual(final.expandedSnippets, ["work key"])

            // Without model edits, finish() produces the exact cleanWithChanges output,
            // including repair-like phrases inside snippet bodies left untouched.
            let untouched = Cleaner.stage("Ship to home addr.").finish()
            XCTAssertEqual(untouched.text, "Ship to \(secretHome).")
            XCTAssertEqual(untouched.text, Cleaner.cleanWithChanges("Ship to home addr.").text)

            // A bare snippet trigger stays marked so Pipeline skips RepairReviewer completely.
            let bare = Cleaner.stage("flow clone.")
            XCTAssertTrue(bare.isBareSnippet)
            XCTAssertEqual(bare.finish().text, "FlowClone 1.0")
        }
    }
}
