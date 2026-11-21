import Foundation
import XCTest
@testable import FlowCloneCore

/// The second look at suspicious sentences (RepairReview.swift, RepairReviewer.swift).
/// Wording is invented; the shapes mirror the owner's dictations the rules leave alone
/// (docs/2026-11-10-model-repairs.md).
final class RepairReviewTests: XCTestCase {
    private func kinds(_ text: String, _ scope: RepairReview.Scope = .full) -> [String] {
        RepairReview.suspects(in: text, scope: scope).map(\.kind.rawValue)
    }

    private func window(_ text: String, _ scope: RepairReview.Scope = .full,
                        file: StaticString = #filePath, line: UInt = #line) -> RepairReview.Window {
        let windows = RepairReview.windows(in: text, scope: scope)
        XCTAssertEqual(windows.count, 1, "windows in: \(text)", file: file, line: line)
        return windows.first ?? RepairReview.Window(lo: 0, hi: 0, text: "", suspects: [])
    }

    /// Gate, model answer, validator and edit in one step.
    private func reviewed(_ text: String, answer: String, _ scope: RepairReview.Scope = .full,
                          file: StaticString = #filePath, line: UInt = #line) -> String {
        let window = window(text, scope, file: file, line: line)
        guard case .delete(let words) = RepairReview.verdict(for: window, in: text, modelOutput: answer, scope: scope) else {
            return text
        }
        return RepairReview.applying(words, to: text)
    }

    // MARK: - The gate

    func testSuspiciousShapesAreFlagged() {
        XCTAssertEqual(kinds("I don't really h like how that turned out."), ["fragment"])
        XCTAssertEqual(kinds("I, Dana, am permanent am a resident."), ["gap"])
        XCTAssertEqual(kinds("Does it yo, does it work now?"), ["restart"])
        XCTAssertEqual(kinds("I want you to reveal review all of the open tickets."), ["similar"])
        XCTAssertEqual(kinds("Cut the fat out. We the maximum is two minutes."), ["odd"])
        XCTAssertEqual(kinds("Let's meet at two, actually three, by the lobby."), ["cue"])
        XCTAssertEqual(kinds("Send it to John. Actually, send it to Sarah."), ["cue"])
        XCTAssertEqual(kinds("Use the blue theme, never mind, keep it grey."), ["cue"])
        XCTAssertEqual(kinds("Put it on the left, no, on the top shelf."), ["restart", "cue"])
    }

    func testOrdinarySentencesAreNotFlagged() {
        for text in [
            "Make the sound fall more in line with the one we play when dictation finishes.",
            "They actually do the work, and we actually have a product.",
            "That is what I mean.",
            "It works as well as the old one and as long as we need.",
            "Day by day it grows more and more.",
            "Pixel for pixel it matches.",
            "Give them the files and then study them.",
            "I think that this thing works through the night.",
            "We need to make that change today.",
            "Select the effort level and press enter.",
            "It started 13.6 s after the start.",
            // A cue with nothing before it to replace answers an earlier message.
            "Sorry, I meant the second screenshot, not the first.",
            "Okay, never mind, I figured it out myself.",
            "Don't touch the old tests, rather just add new ones next to them.",
        ] {
            XCTAssertEqual(kinds(text), [], text)
            XCTAssertTrue(RepairReview.windows(in: text, scope: .full).isEmpty, text)
        }
    }

    func testOnDeviceModelOnlySeesFragmentsAndRestarts() {
        XCTAssertEqual(kinds("I don't really h like how that turned out.", .narrow), ["fragment"])
        XCTAssertEqual(kinds("Does it yo, does it work now?", .narrow), ["restart"])
        XCTAssertEqual(kinds("I, Dana, am permanent am a resident.", .narrow), [])
        XCTAssertEqual(kinds("Let's meet at two, actually three, by the lobby.", .narrow), [])
        XCTAssertEqual(kinds("I want you to reveal review all of the open tickets.", .narrow), [])
        // A dictation cut off mid-word has nothing after the fragment to judge it by.
        XCTAssertEqual(kinds("I want you to start research re", .narrow), [])
        XCTAssertEqual(kinds("I want you to start research re", .full), ["fragment"])
    }

    func testWindowIsTheFlaggedSentence() {
        let text = "The build is green. I don't really h like how that turned out. Ship it anyway."
        let window = window(text)
        XCTAssertEqual(window.text, "I don't really h like how that turned out.")
        XCTAssertEqual(window.suspects.map(\.index), [7])
    }

    func testCueAtASentenceStartBringsThePreviousSentence() {
        let window = window("Ship it. Send it to John. Actually, send it to Sarah. Thanks.")
        XCTAssertEqual(window.text, "Send it to John. Actually, send it to Sarah.")
    }

    func testVeryLongSentenceIsCutAroundTheFlag() {
        let filler = Array(repeating: "and the next step follows the previous one", count: 12).joined(separator: " ")
        let text = "\(filler) but I don't really h like how that turned out \(filler)."
        let window = window(text)
        XCTAssertLessThanOrEqual(window.hi - window.lo + 1, 41)
        XCTAssertTrue(window.text.contains("really h like"))
    }

    // MARK: - The validator and the edit

    func testModelDeletionNextToAFlagIsApplied() {
        XCTAssertEqual(reviewed("I don't really h like how that turned out.",
                                answer: "I don't really like how that turned out."),
                       "I don't really like how that turned out.")
        XCTAssertEqual(reviewed("I want you to reveal review all of the open tickets.",
                                answer: "I want you to review all of the open tickets."),
                       "I want you to review all of the open tickets.")
        XCTAssertEqual(reviewed("Let's meet at two, actually three, by the lobby.",
                                answer: "Let's meet at three, by the lobby."),
                       "Let's meet at three, by the lobby.")
        XCTAssertEqual(reviewed("Cut the fat out. We the maximum is two minutes.",
                                answer: "The maximum is two minutes."),
                       "Cut the fat out. The maximum is two minutes.")
    }

    func testOfTwoCopiesTheEarlierOneGoes() {
        // "am a resident" matches either "am": the abandoned one is the first.
        XCTAssertEqual(reviewed("I, Dana, am permanent am a resident.", answer: "I, Dana, am a resident."),
                       "I, Dana, am a resident.")
    }

    func testSentenceCapitalMovesToTheNextWord() {
        XCTAssertEqual(reviewed("Does it yo, does it work now?", answer: "Does it work now?"), "Does it work now?")
        XCTAssertEqual(reviewed("Ship it. Send it to John. Actually, send it to Sarah. Thanks.",
                                answer: "Send it to Sarah."),
                       "Ship it. Send it to Sarah. Thanks.")
    }

    func testModelPunctuationAndCapitalsAreIgnored() {
        XCTAssertEqual(reviewed("I don't really h like how that turned out.",
                                answer: "\"i dont really like how that turned out\""),
                       "I don't really like how that turned out.")
    }

    func testAnythingButADeletionIsRejected() {
        let text = "I don't really h like how that turned out."
        let window = window(text)
        func verdict(_ answer: String) -> RepairReview.Verdict {
            RepairReview.verdict(for: window, in: text, modelOutput: answer, scope: .full)
        }
        XCTAssertEqual(verdict(text), .unchanged)
        XCTAssertEqual(verdict("I really dislike how that turned out."), .rejected("not-deletion-only"))
        XCTAssertEqual(verdict("I don't really like how that turned out, sorry."), .rejected("not-deletion-only"))
        XCTAssertEqual(verdict("I don't like really how that turned out."), .rejected("not-deletion-only"))
        XCTAssertEqual(verdict("I don't really h like how that turned."), .rejected("away-from-suspect"))
        XCTAssertEqual(verdict("out."), .rejected("too-much"))
        XCTAssertEqual(verdict("  "), .rejected("empty"))
    }

    func testDeletionLongerThanTheFlagAllowsIsRejected() {
        // An ordinary "rather than" is not flagged at all.
        XCTAssertTrue(RepairReview.windows(
            in: "Open it from the terminal directly, rather than spawning it with the plus button.", scope: .full).isEmpty)
        // A cue allows ten words. Fourteen is a deleted instruction, not a correction.
        let long = "Start here " + Array(repeating: "word", count: 12).joined(separator: " ") + ", actually stop."
        let window = window(long)
        XCTAssertEqual(RepairReview.verdict(for: window, in: long, modelOutput: "Start stop.", scope: .full),
                       .rejected("away-from-suspect"))
        XCTAssertEqual(RepairReview.verdict(for: window, in: long, modelOutput: long, scope: .full), .unchanged)
    }

    func testDroppingOnlyTheCueIsRejected() {
        // Both wordings would survive: "Use the staging database, use production…".
        let text = "Use the staging database, never mind, use production for this run."
        let window = window(text)
        XCTAssertEqual(RepairReview.verdict(for: window, in: text,
                                            modelOutput: "Use the staging database, use production for this run.",
                                            scope: .full),
                       .rejected("away-from-suspect"))
        XCTAssertEqual(reviewed(text, answer: "Use production for this run."), "Use production for this run.")
    }

    func testStrongerModelKeepsItsGoodDeletions() {
        // The answer also drops the opening clause, which no flag allows. The fragment goes;
        // the clause stays.
        let text = "Given that the build is green, I don't really h like how that turned out."
        XCTAssertEqual(reviewed(text, answer: "I don't really like how that turned out."),
                       "Given that the build is green, I don't really like how that turned out.")
        let window = window(text, .narrow)
        XCTAssertEqual(RepairReview.verdict(for: window, in: text, modelOutput: "I don't really like how that turned out.",
                                            scope: .narrow),
                       .rejected("away-from-suspect"))
    }

    func testOnDeviceModelMayOnlyDeleteTheFragmentItself() {
        let text = "This is an excellent reference for how I l a genre of sound I like."
        let window = window(text, .narrow)
        XCTAssertEqual(RepairReview.verdict(for: window, in: text,
                                            modelOutput: "This is an excellent reference for a genre of sound I like.",
                                            scope: .narrow),
                       .rejected("away-from-suspect"))
        XCTAssertEqual(reviewed(text, answer: "This is an excellent reference for how I a genre of sound I like.", .narrow),
                       "This is an excellent reference for how I a genre of sound I like.")
        // The stronger model may take the abandoned lead-in with it.
        XCTAssertEqual(reviewed(text, answer: "This is an excellent reference for a genre of sound I like."),
                       "This is an excellent reference for a genre of sound I like.")
    }

    func testEditKeepsSpacingAndLineBreaks() {
        let text = "First line stays.\nI don't really h like how that turned out.\n\nLast line stays."
        XCTAssertEqual(reviewed(text, answer: "I don't really like how that turned out."),
                       "First line stays.\nI don't really like how that turned out.\n\nLast line stays.")
        XCTAssertEqual(RepairReview.applying([], to: text), text)
        XCTAssertEqual(RepairReview.applying([99], to: text), text)
    }

    // MARK: - Orchestration

    private func run(_ text: String, _ scope: RepairReview.Scope = .full, concurrent: Bool = true,
                     answers: [String: String?], after delay: TimeInterval = 0,
                     backstop: [String: String?]? = nil, patience: TimeInterval = 0) -> RepairReviewer.Outcome {
        let windows = RepairReview.windows(in: text, scope: scope)
        let finished = expectation(description: "review finished")
        let box = OutcomeBox()
        var second: RepairReviewer.Ask?
        if let backstop {
            second = { window, done in
                let gate = StubCancel()
                DispatchQueue.global().async {
                    guard !gate.isCancelled else { return }
                    done(backstop[window] ?? nil, "stub-fast")
                }
                return { gate.cancel() }
            }
        }
        RepairReviewer.run(text, windows, scope, .claude, concurrent: concurrent, ask: { window, done in
            let gate = StubCancel()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                guard !gate.isCancelled else { return }
                done(answers[window] ?? nil, "stub")
            }
            return { gate.cancel() }
        }, backstop: second, patience: patience, done: { outcome in
            box.set(outcome)
            finished.fulfill()
        })
        wait(for: [finished], timeout: 5)
        return box.get()!
    }

    private final class StubCancel: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: RepairReviewer.Outcome?
        func set(_ value: RepairReviewer.Outcome) { lock.withLock { outcome = value } }
        func get() -> RepairReviewer.Outcome? { lock.withLock { outcome } }
    }

    func testEveryWindowIsAskedAndTheDeletionsAreCombined() {
        let text = "I don't really h like how that turned out. Ship it. Let's meet at two, actually three, by the lobby."
        for concurrent in [true, false] {
            let outcome = run(text, concurrent: concurrent, answers: [
                "I don't really h like how that turned out.": "I don't really like how that turned out.",
                "Let's meet at two, actually three, by the lobby.": "Let's meet at three, by the lobby.",
            ])
            XCTAssertEqual(outcome.text, "I don't really like how that turned out. Ship it. Let's meet at three, by the lobby.")
            XCTAssertEqual(outcome.windows, 2)
            XCTAssertEqual(outcome.deleted, 3)
            XCTAssertEqual(outcome.notes, ["ok", "ok"])
        }
    }

    func testFailedOrRejectedAnswerLeavesTheTextAlone() {
        let text = "I don't really h like how that turned out. Ship it. Let's meet at two, actually three, by the lobby."
        let outcome = run(text, answers: [
            "I don't really h like how that turned out.": nil,
            "Let's meet at two, actually three, by the lobby.": "Sure! Let's meet at three.",
        ])
        XCTAssertEqual(outcome.text, text)
        XCTAssertEqual(outcome.deleted, 0)
        XCTAssertEqual(outcome.notes, ["failed:stub", "rejected:not-deletion-only"])
        XCTAssertFalse(outcome.summary.contains("lobby"), "the log line carries no words")
    }

    // MARK: - Two models at once

    private let cued = "Let's meet at two, actually three, by the lobby."

    func testPreferredAnswerInTimeWins() {
        let outcome = run(cued, answers: [cued: "Let's meet at three, by the lobby."],
                          backstop: [cued: cued], patience: 2)
        XCTAssertEqual(outcome.text, "Let's meet at three, by the lobby.")
        XCTAssertEqual(outcome.notes, ["ok"])
    }

    func testBackstopIsUsedWhenThePreferredModelIsSlow() {
        let outcome = run(cued, answers: [cued: cued], after: 1.0,
                          backstop: [cued: "Let's meet at three, by the lobby."], patience: 0.1)
        XCTAssertEqual(outcome.text, "Let's meet at three, by the lobby.")
        XCTAssertEqual(outcome.notes, ["ok by backstop"])
        XCTAssertLessThan(outcome.ms, 900)
    }

    func testBackstopIsUsedWhenThePreferredAnswerIsUnusable() {
        let outcome = run(cued, answers: [cued: "Sure, three it is!"],
                          backstop: [cued: "Let's meet at three, by the lobby."], patience: 2)
        XCTAssertEqual(outcome.text, "Let's meet at three, by the lobby.")
        XCTAssertEqual(outcome.notes, ["ok by backstop"])
    }

    func testSlowPreferredAnswerStillWinsWhenTheBackstopFails() {
        let outcome = run(cued, answers: [cued: "Let's meet at three, by the lobby."], after: 0.3,
                          backstop: [cued: nil], patience: 0.05)
        XCTAssertEqual(outcome.text, "Let's meet at three, by the lobby.")
        XCTAssertEqual(outcome.notes, ["ok"])
    }

    func testBothModelsFailingLeavesTheTextAlone() {
        let outcome = run(cued, answers: [cued: nil], backstop: [cued: nil], patience: 0.05)
        XCTAssertEqual(outcome.text, cued)
        XCTAssertEqual(outcome.notes, ["failed:stub"])
    }

    // MARK: - Claude request and response

    func testClaudeRequestCarriesOnlyTheWindow() throws {
        let request = ClaudeRepair.request(window: "Let's meet at two, actually three.", model: ClaudeRepair.fast,
                                           key: "sk-ant-test-key-000000")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key-000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "user-agent"), "dictation-repair/1")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        // The tags are what stop the model answering a dictated instruction.
        XCTAssertEqual(messages, [["role": "user",
                                   "content": "<transcript>\nLet's meet at two, actually three.\n</transcript>"]])
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "output_config", "system", "messages"])
        XCTAssertEqual(ClaudeRepair.preferred, "claude-sonnet-5-5")
    }

    func testClaudeAnswerIsTheTextBlocksOfAFinishedTurn() {
        func answer(_ status: Int, _ json: String) -> (String?, String) {
            ClaudeRepair.answer(status: status, data: Data(json.utf8))
        }
        var result = answer(200, #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":" Meet at three. "}]}"#)
        XCTAssertEqual(result.0, "Meet at three.")
        result = answer(200, #"{"stop_reason":"refusal","content":[]}"#)
        XCTAssertNil(result.0); XCTAssertEqual(result.1, "refusal")
        result = answer(200, #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"Meet at"}]}"#)
        XCTAssertNil(result.0); XCTAssertEqual(result.1, "max_tokens")
        result = answer(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        XCTAssertNil(result.0); XCTAssertEqual(result.1, "authentication_error-401")
        result = answer(529, "upstream")
        XCTAssertNil(result.0); XCTAssertEqual(result.1, "http-529")
        result = answer(200, #"{"stop_reason":"end_turn","content":[]}"#)
        XCTAssertNil(result.0); XCTAssertEqual(result.1, "empty")
    }

    func testSwitchRemembersTheModelChoice() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: RepairReviewer.settingKey), defaults.object(forKey: RepairReviewer.choiceKey))
        defer {
            defaults.set(saved.0, forKey: RepairReviewer.settingKey)
            defaults.set(saved.1, forKey: RepairReviewer.choiceKey)
        }
        defaults.removeObject(forKey: RepairReviewer.settingKey)
        defaults.removeObject(forKey: RepairReviewer.choiceKey)
        XCTAssertTrue(RepairReviewer.enabled, "on by default")
        XCTAssertEqual(RepairReviewer.choice, .auto)

        RepairReviewer.enabled = false
        XCTAssertEqual(RepairReviewer.setting, .off)
        XCTAssertNil(RepairReviewer.backend(), "off means no model is asked")
        XCTAssertEqual(RepairReviewer.choice, .auto, "the choice survives being switched off")
        RepairReviewer.enabled = true
        XCTAssertEqual(RepairReviewer.setting, .auto)

        RepairReviewer.setting = .onDevice
        RepairReviewer.enabled = false
        XCTAssertEqual(RepairReviewer.choice, .onDevice)
        RepairReviewer.enabled = true
        XCTAssertEqual(RepairReviewer.setting, .onDevice, "on again restores On this Mac only")

        // A build before the switch stored "off" with no remembered choice.
        defaults.set("off", forKey: RepairReviewer.settingKey)
        defaults.removeObject(forKey: RepairReviewer.choiceKey)
        RepairReviewer.enabled = true
        XCTAssertEqual(RepairReviewer.setting, .auto)
    }

    func testPastedKeyIsTrimmed() {
        XCTAssertEqual(ClaudeKey.normalized(" sk-ant-api03-abcdefghijklmnop\n"), "sk-ant-api03-abcdefghijklmnop")
        XCTAssertEqual(ClaudeKey.normalized("\"sk-ant-api03-abcdefghijklmnop\""), "sk-ant-api03-abcdefghijklmnop")
        XCTAssertNil(ClaudeKey.normalized("short"))
        XCTAssertNil(ClaudeKey.normalized("not-an-anthropic-key-0123456789012345"))
        XCTAssertNil(ClaudeKey.normalized("sk-ant-api03 abcdefghijklmnop qrstuv"))
        XCTAssertNil(ClaudeKey.normalized(""))
    }

    // MARK: - Live check

    /// Real requests through the shipped request, parser and two-model race. Costs a
    /// fraction of a cent. FLOWCLONE_CLAUDE_KEY_FILE names a file holding an API key.
    func testLiveClaude() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWCLONE_CLAUDE_KEY_FILE"],
              let key = ClaudeKey.normalized(try String(contentsOfFile: path, encoding: .utf8)) else {
            throw XCTSkip("set FLOWCLONE_CLAUDE_KEY_FILE to send live requests")
        }
        let cases = [
            ("Let's meet at two, actually three, by the lobby.", "Let's meet at three, by the lobby."),
            ("I, Dana, am permanent am a resident, so we can file today.", "I, Dana, am a resident, so we can file today."),
            ("Go ahead and merge those and qu fix the tests afterwards.", "Go ahead and merge those and fix the tests afterwards."),
            ("Root out all of the unused files, actually read them, and tell me what they do.",
             "Root out all of the unused files, actually read them, and tell me what they do."),
        ]
        for (text, expected) in cases {
            let windows = RepairReview.windows(in: text, scope: .full)
            XCTAssertEqual(windows.count, 1, text)
            let finished = expectation(description: text)
            let box = OutcomeBox()
            RepairReviewer.run(text, windows, .full, .claude, concurrent: true,
                               ask: { window, done in ClaudeRepair.ask(window, model: ClaudeRepair.preferred, key: key, done: done) },
                               backstop: { window, done in ClaudeRepair.ask(window, model: ClaudeRepair.fast, key: key, done: done) },
                               patience: ClaudeRepair.patience) { outcome in
                box.set(outcome)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 10)
            let outcome = try XCTUnwrap(box.get())
            print("LIVE \(outcome.summary)")
            XCTAssertEqual(outcome.text, expected)
            XCTAssertLessThan(outcome.ms, 3000)
        }
    }

    // MARK: - Corpus audit

    /// Audit hook for gate or validator changes. FLOWCLONE_REVIEW_CORPUS names a JSONL file
    /// with one `{"text": …, "scope": "full"|"narrow", "outputs": [model answer or null per
    /// window]}` per line; `<file>.out` gets the windows and the final text for each.
    func testCorpusAudit() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWCLONE_REVIEW_CORPUS"] else {
            throw XCTSkip("set FLOWCLONE_REVIEW_CORPUS to audit a corpus")
        }
        var lines: [String] = []
        for line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let text = try XCTUnwrap(row["text"] as? String)
            let scope: RepairReview.Scope = row["scope"] as? String == "narrow" ? .narrow : .full
            let outputs = row["outputs"] as? [Any] ?? []
            let windows = RepairReview.windows(in: text, scope: scope)
            var deletions = Set<Int>()
            var notes: [String] = []
            for (index, window) in windows.enumerated() {
                guard index < outputs.count, let output = outputs[index] as? String else { notes.append("none"); continue }
                switch RepairReview.verdict(for: window, in: text, modelOutput: output, scope: scope) {
                case .delete(let words): deletions.formUnion(words); notes.append("ok")
                case .unchanged: notes.append("unchanged")
                case .rejected(let why): notes.append(why)
                }
            }
            let out: [String: Any] = [
                "windows": windows.map { ["lo": $0.lo, "hi": $0.hi, "text": $0.text,
                                          "suspects": $0.suspects.map { [$0.index, $0.kind.rawValue] as [Any] }] as [String: Any] },
                "notes": notes,
                "final": RepairReview.applying(deletions, to: text),
            ]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
        }
        try lines.joined(separator: "\n").write(toFile: path + ".out", atomically: true, encoding: .utf8)
    }

    // MARK: - Privacy boundary, cancellation, whitespace/capitals, window bounds & drop-file

    func testReviewPolicyAndBackendEnforceCodingContextSelfTestAndModeBoundaries() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: RepairReviewer.settingKey), defaults.object(forKey: RepairReviewer.choiceKey))
        defer {
            defaults.set(saved.0, forKey: RepairReviewer.settingKey)
            defaults.set(saved.1, forKey: RepairReviewer.choiceKey)
        }

        RepairReviewer.setting = .auto
        ClaudeKey.withTestKey("sk-ant-test-key-01234567890123456789") {
            let cleanNormal = Pipeline.reviewPolicy(
                mode: .clean, origin: .utterance, commandLine: false,
                isBareSnippet: false, hadContextRewrite: false)
            XCTAssertTrue(cleanNormal.shouldReview)
            XCTAssertTrue(cleanNormal.allowCloud)
            XCTAssertTrue(cleanNormal.allowOnDevice)
            XCTAssertEqual(
                RepairReviewer.backend(allowCloud: cleanNormal.allowCloud, allowOnDevice: cleanNormal.allowOnDevice),
                .claude)

            // When local IDE context vocabulary matched a private identifier, Claude must never be chosen.
            let cleanContext = Pipeline.reviewPolicy(
                mode: .clean, origin: .utterance, commandLine: false,
                isBareSnippet: false, hadContextRewrite: true)
            XCTAssertTrue(cleanContext.shouldReview)
            XCTAssertFalse(cleanContext.allowCloud)
            XCTAssertTrue(cleanContext.allowOnDevice)
            XCTAssertEqual(
                RepairReviewer.backend(allowCloud: cleanContext.allowCloud, allowOnDevice: cleanContext.allowOnDevice),
                .onDevice)

            // `--selftest`, Prompt, Raw, slash commands, and bare snippets never run RepairReviewer.
            XCTAssertFalse(Pipeline.reviewPolicy(
                mode: .clean, origin: .selfTest, commandLine: false,
                isBareSnippet: false, hadContextRewrite: false).shouldReview)
            XCTAssertFalse(Pipeline.reviewPolicy(
                mode: .prompt, origin: .utterance, commandLine: false,
                isBareSnippet: false, hadContextRewrite: false).shouldReview)
            XCTAssertFalse(Pipeline.reviewPolicy(
                mode: .raw, origin: .utterance, commandLine: false,
                isBareSnippet: false, hadContextRewrite: false).shouldReview)
            XCTAssertFalse(Pipeline.reviewPolicy(
                mode: .clean, origin: .utterance, commandLine: true,
                isBareSnippet: false, hadContextRewrite: false).shouldReview)
            XCTAssertFalse(Pipeline.reviewPolicy(
                mode: .clean, origin: .utterance, commandLine: false,
                isBareSnippet: true, hadContextRewrite: false).shouldReview)

            RepairReviewer.setting = .off
            XCTAssertNil(RepairReviewer.backend(allowCloud: true, allowOnDevice: true))
        }
    }

    func testLosingTaskAndSupersededRunAreCancelledImmediately() {
        let windows = RepairReview.windows(in: cued, scope: .full)
        XCTAssertEqual(windows.count, 1)

        // 1. Preferred answers first -> backstop task is cancelled immediately.
        let fastDone = expectation(description: "preferred wins")
        let prefCancel1 = StubCancel(), backCancel1 = StubCancel()
        RepairReviewer.run(
            cued, windows, .full, .claude, concurrent: true,
            ask: { _, done in
                DispatchQueue.global().async { done("Let's meet at three, by the lobby.", "ok") }
                return { prefCancel1.cancel() }
            },
            backstop: { _, _ in { backCancel1.cancel() } },
            patience: 5,
            done: { outcome in
                XCTAssertEqual(outcome.text, "Let's meet at three, by the lobby.")
                fastDone.fulfill()
            })
        wait(for: [fastDone], timeout: 2)
        XCTAssertTrue(backCancel1.isCancelled, "Losing backstop request must be cancelled when preferred settles")
        XCTAssertFalse(prefCancel1.isCancelled)

        // 2. Backstop wins after patience -> slow preferred task is cancelled immediately.
        let backstopDone = expectation(description: "backstop wins")
        let prefCancel2 = StubCancel(), backCancel2 = StubCancel()
        RepairReviewer.run(
            cued, windows, .full, .claude, concurrent: true,
            ask: { _, _ in { prefCancel2.cancel() } },
            backstop: { _, done in
                DispatchQueue.global().async { done("Let's meet at three, by the lobby.", "ok") }
                return { backCancel2.cancel() }
            },
            patience: 0.05,
            done: { outcome in
                XCTAssertEqual(outcome.text, "Let's meet at three, by the lobby.")
                backstopDone.fulfill()
            })
        wait(for: [backstopDone], timeout: 2)
        XCTAssertTrue(prefCancel2.isCancelled, "Losing preferred request must be cancelled when backstop settles")

        // 3. Session supersession cancels all legs and suppresses late completions.
        let prefCancel3 = StubCancel(), backCancel3 = StubCancel()
        let lateBox = OutcomeBox()
        let cancelRun = RepairReviewer.run(
            cued, windows, .full, .claude, concurrent: true,
            ask: { _, done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    if !prefCancel3.isCancelled { done("Let's meet at three, by the lobby.", "ok") }
                }
                return { prefCancel3.cancel() }
            },
            backstop: { _, _ in { backCancel3.cancel() } },
            patience: 5,
            done: { lateBox.set($0) })
        cancelRun()
        XCTAssertTrue(prefCancel3.isCancelled)
        XCTAssertTrue(backCancel3.isCancelled)
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertNil(lateBox.get())

        // 4. ClaudeRepair.ask returns a closure that cancels the underlying URLSessionDataTask.
        final class HangingProtocol: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var onStop: (() -> Void)?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {}
            override func stopLoading() { Self.onStop?() }
        }
        let stopped = expectation(description: "URLSessionDataTask cancelled")
        HangingProtocol.onStop = { stopped.fulfill() }
        defer { HangingProtocol.onStop = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]
        let session = URLSession(configuration: config)
        let cancelHTTP = ClaudeRepair.ask("Let's meet at two, actually three.", model: ClaudeRepair.fast,
                                          key: "sk-ant-test-key-000000", session: session) { _, _ in }
        cancelHTTP()
        wait(for: [stopped], timeout: 2)
    }

    func testApplyingPreservesParagraphBreaksAndCrossSentenceCapitals() {
        XCTAssertEqual(
            reviewed("First point.\n\nActually, no, second point.",
                     answer: "First point. Second point."),
            "First point.\n\nSecond point.")
        XCTAssertEqual(
            reviewed("First line.\nActually, no, second line.",
                     answer: "First line. Second line."),
            "First line.\nSecond line.")
        XCTAssertEqual(
            reviewed("3pm works. Actually, no, let's do 4pm.",
                     answer: "Let's do 4pm."),
            "Let's do 4pm.")
        XCTAssertEqual(
            reviewed("Send it to Bob. Actually, send it to Alice.",
                     answer: "Send it to Alice."),
            "Send it to Alice.")
        XCTAssertEqual(
            RepairReview.applying([2], to: "Meet today. wait tomorrow."),
            "Meet today. Tomorrow.")
    }

    func testMultiFlagLongUnpunctuatedSentenceSplitsIntoBoundedWindows() {
        let filler = (1...55).map { "item\($0)" }.joined(separator: " ")
        let long = "I don't really h like how \(filler) go ahead and qu fix the tests today"
        let windows = RepairReview.windows(in: long, scope: .full)
        XCTAssertGreaterThanOrEqual(windows.count, 2, "Distant flags in a long run-on must split into multiple windows")
        for w in windows {
            XCTAssertLessThanOrEqual(w.hi - w.lo, RepairReview.maxWords, "Window exceeded maxWords: \(w.text)")
        }

        let finished = expectation(description: "long multi-window repair")
        let box = OutcomeBox()
        RepairReviewer.run(
            long, windows, .full, .claude, concurrent: true,
            ask: { window, done in
                let fixed = window
                    .replacingOccurrences(of: "really h like", with: "really like")
                    .replacingOccurrences(of: "and qu fix", with: "and fix")
                done(fixed, "ok")
                return {}
            },
            done: { outcome in
                box.set(outcome)
                finished.fulfill()
            })
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(box.get()?.text, "I don't really like how \(filler) go ahead and fix the tests today")

        // Adjacent flagged sentences whose combined length exceeds 45 words must not merge past maxWords.
        let padA = Array(repeating: "alpha", count: 22).joined(separator: " ")
        let padB = Array(repeating: "bravo", count: 22).joined(separator: " ")
        let adjacent = "I don't really h like \(padA). Let's meet at two, actually three \(padB)."
        let adjacentWindows = RepairReview.windows(in: adjacent, scope: .full)
        XCTAssertEqual(adjacentWindows.count, 2)
        XCTAssertTrue(adjacentWindows.allSatisfy { ($0.hi - $0.lo) <= RepairReview.maxWords })
    }

    func testDropFileImportRefusesSymlinksAndNonRegularFilesAndUnlinksRegularValidKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-dropkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var stored: [String] = []
        let storeKey: (String) -> Bool = { raw in
            guard let normalized = ClaudeKey.normalized(raw) else { return false }
            stored.append(normalized)
            return true
        }

        // 1. Missing file -> .missing
        let missing = root.appendingPathComponent("missing-key")
        XCTAssertEqual(ClaudeKey.importDropFile(at: missing, storeKey: storeKey), .missing)
        XCTAssertTrue(stored.isEmpty)

        // 2. Directory at drop-file path -> .rejectedNonRegular
        let directoryDrop = root.appendingPathComponent("dir-key", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryDrop, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeKey.importDropFile(at: directoryDrop, storeKey: storeKey), .rejectedNonRegular)
        XCTAssertTrue(stored.isEmpty)

        // 3. Symlink pointing to a regular file -> refused via O_NOFOLLOW; target untouched.
        let target = root.appendingPathComponent("real-secret.txt")
        try Data("sk-ant-symlink-secret-0123456789\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink-key")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertEqual(ClaudeKey.importDropFile(at: symlink, storeKey: storeKey), .rejectedNonRegular)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Symlink target must remain untouched")

        // 4. Group/world-readable regular file (0644) -> .rejectedPermissions and left in place.
        let worldReadable = root.appendingPathComponent("world-readable-key")
        try Data("sk-ant-world-readable-01234567890123\n".utf8).write(to: worldReadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: worldReadable.path)
        XCTAssertEqual(ClaudeKey.importDropFile(at: worldReadable, storeKey: storeKey), .rejectedPermissions)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worldReadable.path))

        // 5. Regular 0600 file with invalid content or non-sk-ant prefix -> .invalidKey and kept in place.
        let invalid = root.appendingPathComponent("invalid-key")
        try Data("not-an-anthropic-key-0123456789012345\n".utf8).write(to: invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalid.path)
        XCTAssertEqual(ClaudeKey.importDropFile(at: invalid, storeKey: storeKey), .invalidKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))

        // 6. Regular 0600 file with wrong owner UID -> .rejectedPermissions; existing key -> .skippedExistingKey.
        let valid = root.appendingPathComponent("claude-api-key")
        try Data("  \"sk-ant-valid-drop-0123456789012345\" \n".utf8).write(to: valid)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: valid.path)
        XCTAssertEqual(
            ClaudeKey.importDropFile(at: valid, expectedUID: getuid() &+ 1, storeKey: storeKey),
            .rejectedPermissions
        )
        XCTAssertEqual(
            ClaudeKey.importDropFile(at: valid, hasExistingKey: true, storeKey: storeKey),
            .skippedExistingKey
        )
        XCTAssertTrue(stored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))

        // 7. Regular 0600 file owned by current UID with valid sk-ant- key -> imported and unlinked.
        XCTAssertEqual(ClaudeKey.importDropFile(at: valid, storeKey: storeKey), .imported)
        XCTAssertEqual(stored, ["sk-ant-valid-drop-0123456789012345"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path), "Valid drop file must be unlinked after import")
    }

    func testClaudeSetupPromptAppearsOnlyWhenKeyMissingAndAutoSelectedAndNotDismissed() {
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("claude-prompt"))!
        XCTAssertTrue(ClaudeKey.needsSetupPrompt(defaults: defaults, hasKey: false),
                      "Fresh Mac with no key in Automatic mode must prompt user for their own key")
        XCTAssertFalse(ClaudeKey.needsSetupPrompt(defaults: defaults, hasKey: true),
                       "Mac with a saved key must not prompt")

        defaults.set(RepairReviewer.Setting.onDevice.rawValue, forKey: RepairReviewer.settingKey)
        XCTAssertFalse(ClaudeKey.needsSetupPrompt(defaults: defaults, hasKey: false),
                       "Choosing the built-in model stops the prompt")

        defaults.set(RepairReviewer.Setting.off.rawValue, forKey: RepairReviewer.settingKey)
        XCTAssertFalse(ClaudeKey.needsSetupPrompt(defaults: defaults, hasKey: false),
                       "Turning Smart corrections off stops the prompt")

        defaults.set(RepairReviewer.Setting.auto.rawValue, forKey: RepairReviewer.settingKey)
        XCTAssertTrue(ClaudeKey.needsSetupPrompt(defaults: defaults, hasKey: false))
        ClaudeKey.dismissSetupPrompt(defaults: defaults)
        XCTAssertFalse(ClaudeKey.needsSetupPrompt(defaults: defaults, hasKey: false),
                       "Dismissing the setup card stops repeated prompts")
    }
}
