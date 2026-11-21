import Foundation
import XCTest
@testable import FlowCloneCore

final class SmartCleanupTests: XCTestCase {
    private let sampleDictionary = [
        "Claude", "Codex", "Wispr", "FluidAudio", "Parakeet", "FlowClone", "Turnstile", "heapdump"
    ]

    // MARK: - PhoneticMatcher

    func testPhoneticMatcherCatchesDictionarySoundAlikes() {
        let hints1 = PhoneticMatcher.findNearMisses(
            in: "Use the clawed API to check codecs and whisper.",
            vocabulary: sampleDictionary
        )
        XCTAssertTrue(hints1.contains(.init(spoken: "clawed", candidate: "Claude")))
        XCTAssertTrue(hints1.contains(.init(spoken: "codecs", candidate: "Codex")))
        XCTAssertTrue(hints1.contains(.init(spoken: "whisper", candidate: "Wispr")))

        let hints2 = PhoneticMatcher.findNearMisses(
            in: "Check code x and floyd audio in flow clone.",
            vocabulary: sampleDictionary
        )
        XCTAssertTrue(hints2.contains(.init(spoken: "code x", candidate: "Codex")))
        XCTAssertTrue(hints2.contains(.init(spoken: "floyd audio", candidate: "FluidAudio")))
        XCTAssertTrue(hints2.contains(.init(spoken: "flow clone", candidate: "FlowClone")))
    }

    func testPhoneticMatcherSkipsExactMatchesAndOrdinaryUnrelatedText() {
        let exact = PhoneticMatcher.findNearMisses(
            in: "Claude and Codex work great with FluidAudio.",
            vocabulary: sampleDictionary
        )
        XCTAssertTrue(exact.isEmpty)

        let ordinary = PhoneticMatcher.findNearMisses(
            in: "Thanks for the help, I will review the slides tomorrow morning.",
            vocabulary: sampleDictionary
        )
        XCTAssertTrue(ordinary.isEmpty)
    }

    // MARK: - SmartCleanupRouter

    func testRouterKeepsShortCleanPunctuatedDictationsLocalInstant() {
        let route = SmartCleanupRouter.route(.init(
            text: "Looks good, let's ship it tomorrow.",
            dictionaryTerms: sampleDictionary
        ))
        XCTAssertEqual(route, .localInstant(reason: "clean-short"))

        let slash = SmartCleanupRouter.route(.init(
            text: "/compact",
            dictionaryTerms: sampleDictionary
        ))
        XCTAssertEqual(slash, .localInstant(reason: "command-line"))

        let tiny = SmartCleanupRouter.route(.init(
            text: "Sounds good",
            dictionaryTerms: sampleDictionary
        ))
        XCTAssertEqual(tiny, .localInstant(reason: "very-short"))
    }

    func testRouterEscalatesMissingPunctuationQuestionPhoneticAndUnkToHaiku() {
        let missingQ = SmartCleanupRouter.route(.init(
            text: "How is the system running",
            dictionaryTerms: sampleDictionary
        ))
        if case .haiku(let reasons, _) = missingQ {
            XCTAssertTrue(reasons.contains(.missingQuestionMark))
        } else {
            XCTFail("Expected Haiku route for missing question mark, got \(missingQ)")
        }

        let missingDot = SmartCleanupRouter.route(.init(
            text: "I will finish the review after lunch",
            dictionaryTerms: sampleDictionary
        ))
        if case .haiku(let reasons, _) = missingDot {
            XCTAssertTrue(reasons.contains(.missingTerminalPunctuation))
        } else {
            XCTFail("Expected Haiku route for missing terminal punctuation, got \(missingDot)")
        }

        let phonetic = SmartCleanupRouter.route(.init(
            text: "Use the clawed API for this.",
            dictionaryTerms: sampleDictionary
        ))
        if case .haiku(let reasons, let hints) = phonetic {
            XCTAssertTrue(reasons.contains(.phoneticDictionaryHit))
            XCTAssertTrue(hints.contains(.init(spoken: "clawed", candidate: "Claude")))
        } else {
            XCTFail("Expected Haiku route for phonetic hit, got \(phonetic)")
        }

        let unk = SmartCleanupRouter.route(.init(
            text: "Check the & logs.",
            dictionaryTerms: sampleDictionary,
            unknownTokenCount: 1
        ))
        if case .haiku(let reasons, _) = unk {
            XCTAssertTrue(reasons.contains(.unknownASRToken))
        } else {
            XCTFail("Expected Haiku route for unknown ASR token, got \(unk)")
        }
    }

    func testRouterEscalatesHardSelfCorrectionToSonnetRace() {
        let sentence = "Let's meet at two, actually three, by the lobby."
        let windows = RepairReview.windows(in: sentence, scope: .full)
        let route = SmartCleanupRouter.route(.init(
            text: sentence,
            dictionaryTerms: sampleDictionary,
            repairWindows: windows
        ))
        if case .sonnetRace(let reasons, _) = route {
            XCTAssertTrue(reasons.contains(.hardRepair))
        } else {
            XCTFail("Expected Sonnet race route for hard self-correction, got \(route)")
        }
    }

    func testRouterKeepsMinorSimilarPairOnHaikuAndReusesPreparedPhoneticIndex() {
        let similarSentence = "I want you to reveal review all of the open tickets."
        let similarWindows = RepairReview.windows(in: similarSentence, scope: .full)
        XCTAssertEqual(similarWindows.flatMap(\.suspects).map(\.kind), [.similar])

        let route = SmartCleanupRouter.route(.init(
            text: similarSentence,
            dictionaryTerms: sampleDictionary,
            repairWindows: similarWindows
        ))
        if case .haiku(let reasons, _) = route {
            XCTAssertTrue(reasons.contains(.lightRepair))
        } else {
            XCTFail("Minor .similar pair should stay on fast single-model Haiku, got \(route)")
        }

        // PreparedConfiguration builds a reusable PhoneticMatcher.Index matching direct vocabulary lookup.
        let drafts = sampleDictionary.map { PersonalizationDraft(kind: .dictionary, primary: $0, replacement: nil) }
        let prepared = Cleaner.PreparedConfiguration(drafts)
        let indexedRoute = SmartCleanupRouter.route(.init(
            text: "Use the clawed API to check codecs and floyd audio.",
            phoneticIndex: prepared.phoneticIndex
        ))
        if case .haiku(let reasons, let hints) = indexedRoute {
            XCTAssertTrue(reasons.contains(.phoneticDictionaryHit))
            XCTAssertTrue(hints.contains(.init(spoken: "clawed", candidate: "Claude")))
            XCTAssertTrue(hints.contains(.init(spoken: "codecs", candidate: "Codex")))
            XCTAssertTrue(hints.contains(.init(spoken: "floyd audio", candidate: "FluidAudio")))
        } else {
            XCTFail("Expected Haiku route with cached phonetic index hints, got \(indexedRoute)")
        }
    }

    // MARK: - SmartCleanupValidator

    func testValidatorAcceptsPunctuationHomophonesDictionaryRepairsAndLists() {
        let punct = SmartCleanupValidator.validate(
            original: "How is the system running",
            candidate: "How is the system running?"
        )
        if case .accepted(let out, let summary) = punct {
            XCTAssertEqual(out, "How is the system running?")
            XCTAssertTrue(summary.punctuationOrCaseChanged)
        } else {
            XCTFail("Expected accepted punctuation fix, got \(punct)")
        }

        let dictFix = SmartCleanupValidator.validate(
            original: "Use the clawed API to check codecs and floyd audio.",
            candidate: "Use the Claude API to check Codex and FluidAudio.",
            dictionaryTerms: sampleDictionary
        )
        if case .accepted(let out, _) = dictFix {
            XCTAssertEqual(out, "Use the Claude API to check Codex and FluidAudio.")
        } else {
            XCTFail("Expected accepted dictionary fix, got \(dictFix)")
        }

        let homophone = SmartCleanupValidator.validate(
            original: "Check the doc on the bottom of the screen.",
            candidate: "Check the dock on the bottom of the screen."
        )
        if case .accepted(let out, _) = homophone {
            XCTAssertEqual(out, "Check the dock on the bottom of the screen.")
        } else {
            XCTFail("Expected accepted homophone fix, got \(homophone)")
        }

        let repair = SmartCleanupValidator.validate(
            original: "Let's meet at two, actually three, by the lobby.",
            candidate: "Let's meet at three, by the lobby.",
            allowRepairs: true
        )
        if case .accepted(let out, _) = repair {
            XCTAssertEqual(out, "Let's meet at three, by the lobby.")
        } else {
            XCTFail("Expected accepted repair, got \(repair)")
        }

        let list = SmartCleanupValidator.validate(
            original: "We have three things to do first fix the login bug second update the tests third ship the release",
            candidate: "We have three things to do:\n1. Fix the login bug.\n2. Update the tests.\n3. Ship the release."
        )
        if case .accepted(let out, let summary) = list {
            XCTAssertTrue(out.contains("1. Fix the login bug."))
            XCTAssertTrue(summary.formattingChanged)
        } else {
            XCTFail("Expected accepted ordinal-to-numbered list formatting, got \(list)")
        }
    }

    func testValidatorRejectsMeaningFlipsHallucinationsAndCommandDrift() {
        let flipCases: [(String, String)] = [
            ("We can ship it today.", "We can't ship it today."),
            ("Do it now please.", "Do it not please."),
            ("Send the file today.", "Sent the file today."),
            ("Pull the branch now.", "Push the branch now."),
            ("Check the budget of $500.", "Check the budget of $600."),
            ("Run /compact on this thread.", "Run compact on this thread."),
            ("How is the system running", "The system is running well and all checks are green!"),
            ("Update the readme.", "Update the readme and deploy the entire backend cluster."),
            ("Check foo_bar <= 10.", "Check foo_bar >= 10."),
            ("Meet on Thursday morning.", "Meet on Tuesday morning."),
            ("Please enable the feature.", "Please unable the feature."),
            ("We will accept the proposal.", "We will except the proposal."),
            ("We need two million units.", "We need two billion units."),
            ("Keep this document public.", "Keep this document publish."),
            ("Check the staging database before deploying.", "Check the database deploying."),
        ]
        for (orig, bad) in flipCases {
            let res = SmartCleanupValidator.validate(original: orig, candidate: bad, dictionaryTerms: sampleDictionary)
            if case .rejected = res {
                // expected
            } else {
                XCTFail("Expected rejection for \(orig) -> \(bad), got \(res)")
            }
        }

        // During repairs, unrelated sentences must still keep their negations and numbers.
        let repairDropNeg = SmartCleanupValidator.validate(
            original: "I really h like that. Do not ship 50 units.",
            candidate: "I really like that. Ship 50 units.",
            allowRepairs: true
        )
        if case .rejected = repairDropNeg {} else {
            XCTFail("Expected rejection when negation is dropped from unrelated sentence, got \(repairDropNeg)")
        }

        let repairDropNum = SmartCleanupValidator.validate(
            original: "I really h like that. Ship 50 units today.",
            candidate: "I really like that. Ship units today.",
            allowRepairs: true
        )
        if case .rejected = repairDropNum {} else {
            XCTFail("Expected rejection when quantity is dropped from unrelated sentence, got \(repairDropNum)")
        }

        // Protected snippet triggers must survive verbatim.
        let brokenTrigger = SmartCleanupValidator.validate(
            original: "Please send my work email today",
            candidate: "Please send my work emails today.",
            protectedTriggers: ["work email"]
        )
        if case .rejected = brokenTrigger {} else {
            XCTFail("Expected rejection when snippet trigger is mutated, got \(brokenTrigger)")
        }
    }

    // MARK: - SmartCleanupPrompt & Runner

    func testStaticSystemExceedsPromptCacheMinimumAndStaysAppIndependent() {
        // Anthropic 5.5 prompt caching requires >= 512 tokens (~380+ words / ~2,100+ chars).
        XCTAssertGreaterThan(SmartCleanupPrompt.staticInstructions.count, 2_200)

        let blocks = SmartCleanupPrompt.systemBlocks(dictionaryTerms: sampleDictionary)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].cacheTTL, "1h")
        XCTAssertEqual(blocks[1].cacheTTL, "1h")

        let msg = SmartCleanupPrompt.userMessage(
            text: "Use the clawed API.",
            appCategory: "coding",
            midSentence: false,
            phoneticHints: [.init(spoken: "clawed", candidate: "Claude")],
            reasons: [.phoneticDictionaryHit]
        )
        XCTAssertTrue(msg.contains("app=coding"))
        XCTAssertTrue(msg.contains("clawed->Claude"))
        XCTAssertTrue(msg.contains("<transcript>"))
    }

    func testSmartCleanupRunnerPrefersSonnetWithinPatienceAndFallsBackToHaikuAfterPatience() {
        let fastDone = expectation(description: "preferred wins")
        RepairReviewer.runSmartCleanup(
            "How is the system running",
            routeLabel: "sonnet-race:missing-question",
            preferredAsk: { done in
                DispatchQueue.global().async { done("How is the system running?", "ok") }
                return {}
            },
            backstopAsk: { _ in {} },
            patience: 2.0
        ) { outcome in
            XCTAssertEqual(outcome.text, "How is the system running?")
            XCTAssertEqual(outcome.backend, .claude)
            XCTAssertTrue(outcome.edited)
            XCTAssertEqual(outcome.notes, ["ok"])
            fastDone.fulfill()
        }
        wait(for: [fastDone], timeout: 2)

        let backstopDone = expectation(description: "backstop wins after patience")
        RepairReviewer.runSmartCleanup(
            "How is the system running",
            routeLabel: "sonnet-race:missing-question",
            preferredAsk: { _ in {} },
            backstopAsk: { done in
                DispatchQueue.global().async { done("How is the system running?", "ok") }
                return {}
            },
            patience: 0.05
        ) { outcome in
            XCTAssertEqual(outcome.text, "How is the system running?")
            XCTAssertEqual(outcome.notes, ["ok by backstop"])
            backstopDone.fulfill()
        }
        wait(for: [backstopDone], timeout: 2)
    }
}
