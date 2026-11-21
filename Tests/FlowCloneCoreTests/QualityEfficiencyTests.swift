import XCTest
import AVFoundation
@testable import FlowCloneCore

final class QualityEfficiencyTests: XCTestCase {
    func testLongCommonEdgesPreserveLCSOrderAndMultiplicity() {
        XCTAssertEqual(RewriteFidelity.retainedInOrder(source: ["a", "a", "b"], output: ["a", "b"]), 2)
        XCTAssertEqual(RewriteFidelity.retainedInOrder(source: ["a", "b", "a"], output: ["a", "a", "b"]), 2)
        XCTAssertEqual(RewriteFidelity.retainedInOrder(source: [], output: ["a"]), 0)
        let head = Array(repeating: "word", count: 2_000)
        XCTAssertEqual(RewriteFidelity.retainedInOrder(source: head + ["keep", "a", "b", "end"],
                                                      output: head + ["keep", "b", "a", "end"]), 2_003)
    }

    func testDictionaryScaleBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FLOWCLONE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FLOWCLONE_BENCHMARK=1 for dictionary benchmark")
        }
        let defaults = ["FlowClone", "FluidAudio", "Parakeet", "Wispr"]
        let words = ["flowclone", "fluidaudo", "parapet", "review", "send", "the", "please",
                     "VocabularyTerm0017", "VocabularyTerm0514", "VocabulryTerm0017"]
        let queries = (0..<100).map { words[$0 % words.count] }
        for size in [4, 2_000] {
            let terms = defaults + (0..<(size - 4)).map { String(format: "VocabularyTerm%04d", $0) }
            let vocabulary = terms.map { (key: $0.lowercased(), term: $0) }
            let index = Cleaner.VocabularyIndex(vocabulary)
            for query in queries { XCTAssertEqual(index.match(query), legacyMatch(query, vocabulary)) }
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for _ in 0..<5 {
                var start = DispatchTime.now()
                let old = queries.map { legacyMatch($0, vocabulary) }
                oldTimes.append(ms(start, .now()))
                start = .now()
                let new = queries.map { index.match($0) }
                newTimes.append(ms(start, .now()))
                XCTAssertEqual(old, new)
            }
            print(String(format: "DICTIONARY_BENCH terms=%d lookups=100 legacy_median_ms=%.3f indexed_median_ms=%.3f",
                         size, oldTimes.sorted()[2], newTimes.sorted()[2]))
        }
    }

    func testAudioTimestampDistinguishesAcquisitionFromCallbackAndPrebuffering() {
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1))
        let timing = Recorder.captureTiming(time: time,
            requestedAt: DispatchTime(uptimeNanoseconds: 1_100_000_000),
            callbackAt: DispatchTime(uptimeNanoseconds: 1_200_000_000))!
        XCTAssertEqual(timing.openToAudioMS, -100, accuracy: 0.001)
        XCTAssertEqual(timing.audioToCallbackMS, 200, accuracy: 0.001)
        XCTAssertNil(Recorder.captureTiming(time: AVAudioTime(sampleTime: 0, atRate: 16_000),
                                            requestedAt: .now(), callbackAt: .now()))
    }

    func testPaddingCannotDiscardASustainedShortWord() {
        for count in [2_400, 3_199, 3_200, 6_400, 16_000] {
            for offset in [0, 80, 160, 319] {
                var audio = Array(repeating: Float(0), count: count)
                audio.replaceSubrange(offset..<(offset + 1_600), with: repeatElement(Float(0.006), count: 1_600))
                XCTAssertTrue(SpeechGate.containsSpeech(audio), "count=\(count) offset=\(offset)")
            }
            XCTAssertFalse(SpeechGate.containsSpeech(Array(repeating: 0, count: count)))
            var click = Array(repeating: Float(0), count: count)
            click.replaceSubrange(799..<1119, with: repeatElement(Float(0.2), count: 320))
            XCTAssertFalse(SpeechGate.containsSpeech(click), "click count=\(count)")
        }
        XCTAssertFalse(SpeechGate.containsSpeech(Array(repeating: 0.001, count: 16_000)),
                       "Background energy below the adaptive threshold must remain gated")
    }

    func testQuietShortCaptureRecoveryDistinguishesDeliberateHoldsFromTaps() {
        let quiet = Array(repeating: Float(0.0002), count: 3_200)
        XCTAssertTrue(SpeechGate.shouldRetainForRetry(quiet, heldSeconds: 0.8))
        XCTAssertFalse(SpeechGate.shouldRetainForRetry(quiet, heldSeconds: 0.2))
        XCTAssertFalse(SpeechGate.shouldRetainForRetry(quiet, heldSeconds: nil))
        XCTAssertFalse(SpeechGate.shouldRetainForRetry(Array(repeating: 0, count: 3_200), heldSeconds: 1))
        XCTAssertTrue(SpeechGate.shouldRetainForRetry(quiet + quiet, heldSeconds: nil))
    }

    func testRepeatedPredicateDoesNotHideNegationOrUncertaintyLoss() {
        let pairs = [
            ("Do not send the invoice until Friday. Send the summary today.",
             "Send the invoice until Friday. Do not send the summary today."),
            ("Maybe send the report tomorrow.", "Send the report tomorrow."),
            ("The server might restart after the update.", "The server will restart after the update."),
            ("Never delete the original file. Delete the temporary file.",
             "Delete the original file. Never delete the temporary file.")
        ]
        for (input, output) in pairs {
            XCTAssertNotNil(Polisher.reject(output, input), input)
            XCTAssertNotNil(Prompter.reject(output, input), input)
            XCTAssertNil(Polisher.reject(input, input), "Unchanged input must survive: \(input)")
        }
        XCTAssertNil(Polisher.reject("Don't send the invoice until Friday. Send the summary today.",
                                    "Do not send the invoice until Friday. Send the summary today."))
        XCTAssertNil(Polisher.reject("Maybe send the report tomorrow.", "Um, maybe send the report tomorrow."))
    }

    func testQuantitiesKeepTheirOrderAndTechnicalTermsKeepTheirSymbols() {
        XCTAssertNotNil(Polisher.reject("Send Alice 50 dollars and Bob 15 dollars.",
                                       "Send Alice 15 dollars and Bob 50 dollars."))
        for (input, output) in [("Use C++ for this module.", "Use C# for this module."),
                                ("Call foo_bar to finish.", "Call foobar to finish."),
                                ("Keep a <= b.", "Keep a >= b.")] {
            XCTAssertNotNil(Polisher.reject(output, input))
            XCTAssertNotNil(Prompter.reject(output, input))
            XCTAssertNil(Polisher.reject(input, input))
        }
        XCTAssertNil(Polisher.reject("Send Alice 15 dollars and Bob 25 dollars.",
                                    "Send Alice fifteen dollars and Bob twenty-five dollars."))
    }

    func testBoundedDistanceMatchesFullDistanceAcrossUnicodeAndCutoffs() {
        var inputs = ["", "a", "ab", "ba", "aaa", "café", "cafe\u{301}", "👩🏽‍💻", "naïve", "Parakeet"]
        for a in ["a", "b", "é"] {
            for b in ["a", "b", "é"] {
                for c in ["a", "b", "é"] { inputs.append(a + b + c) }
            }
        }
        for a in inputs {
            for b in inputs {
                let distance = TextSimilarity.editDistance(a, b)
                for limit in 0...4 {
                    XCTAssertEqual(TextSimilarity.boundedEditDistance(Array(a), Array(b), limit: limit),
                                   distance <= limit ? distance : nil, "\(a) / \(b), limit=\(limit)")
                }
            }
        }
    }

    func testIndexedVocabularyPreservesThePreviousMatchingContract() {
        let terms = ["FlowClone", "FluidAudio", "Parakeet", "Wispr", "CaféParser", "Cafe\u{301}Parser",
                     "ParserOne", "ParserTwo", "Foo Bar", "FOOBAR", "API", "api"]
            + (0..<200).map { "Vocabulary\($0)" }
        let vocabulary = terms.map { (key: $0.lowercased().filter { !$0.isWhitespace }, term: $0) }
        let index = Cleaner.VocabularyIndex(vocabulary)
        var queries = ["parapet", "parakeets", "bite", "wisps", "wisp", "fooBar", "api", "", "👩🏽‍💻"]
        for term in terms { queries += [term, term.lowercased(), String(term.dropFirst()), term + "s", term + "x"] }
        for query in queries {
            XCTAssertEqual(index.match(query), legacyMatch(query, vocabulary), query)
        }
    }

    // Frozen pre-index search serves as a differential oracle, including its deliberate
    // ambiguity and inflection rules. Accuracy-policy changes are separate from indexing.
    private func legacyMatch(_ core: String, _ vocabulary: [(key: String, term: String)]) -> String? {
        let k = core.lowercased()
        var best: (term: String, d: Double)?
        var tied = false
        for (key, term) in vocabulary {
            if key.count < 6 { if key == k { return term }; continue }
            if TextSimilarity.isInflection(k, key) { continue }
            let m = max(k.count, key.count)
            if abs(k.count - key.count) * 4 > m { continue }
            let distance = TextSimilarity.editDistance(k, key)
            if key.count < 8, distance > 1 { continue }
            let d = Double(distance) / Double(m)
            guard d <= 0.25 else { continue }
            if best == nil || d < best!.d { best = (term, d); tied = false }
            else if d == best!.d, term != best!.term { tied = true }
        }
        return tied ? nil : best?.term
    }
}
