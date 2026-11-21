import Cocoa
import CoreAudio
import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import FlowCloneCore

final class PureBehaviorTests: XCTestCase {
    func testSharedSimilarityPrimitives() {
        XCTAssertEqual(TextSimilarity.editDistance("kitten", "sitting"), 3)
        XCTAssertTrue(TextSimilarity.isInflection("parakeets", "parakeet"))
        XCTAssertFalse(TextSimilarity.isInflection("parakeet", "parachute"))
        XCTAssertEqual(Cleaner.distance("flowclone", "flowclon"), 1)
    }

    /// Also the parse fixtures of the former `Cleaner.selfCheck()`, verbatim — the command
    /// is pure, so they need no personalization store.
    func testCorrectionCommandRejectsOrdinaryInstruction() {
        let parsed = Cleaner.parseCorrectionCommand("Correct spelling iphone to iPhone")
        XCTAssertEqual(parsed?.wrong, "iphone")
        XCTAssertEqual(parsed?.right, "iPhone")
        expectCorrectionCommand("Correct spelling cooper netties to Kubernetes.",
                                "cooper netties", "Kubernetes")
        XCTAssertNil(Cleaner.parseCorrectionCommand("Correct spelling iPhone to iPhone"))
        XCTAssertNil(Cleaner.parseCorrectionCommand("Correct spelling same to same"))
        // No trigger phrase at all.
        XCTAssertNil(Cleaner.parseCorrectionCommand(
            "Correct the report to reflect the new numbers."
        ))
        // redteam H2: ordinary sentences that begin with the trigger phrase must NOT parse
        // as commands (wrong side too long / stop words) — they'd swallow the whole
        // utterance and write a permanent global rewrite rule.
        XCTAssertNil(Cleaner.parseCorrectionCommand(
            "Correct the spelling of the third paragraph to match the style guide."
        ))
        XCTAssertNil(Cleaner.parseCorrectionCommand(
            "Correct the spelling of names according to the list."
        ))
        XCTAssertNil(Cleaner.parseCorrectionCommand(
            "Correct spelling errors in the doc and send it to Bob."
        ))
        // The same failure, one step subtler: short stop-word-free sides that pass every
        // shape rule and still share almost no spelling.
        XCTAssertNil(Cleaner.parseCorrectionCommand("Correct spelling before sending to Marcus."))
        XCTAssertNil(Cleaner.parseCorrectionCommand("Correct spelling issues prior to review."))
        XCTAssertNil(Cleaner.parseCorrectionCommand(
            "Correct the spelling of Marcus according to HR."
        ))
        // …while a real spelling fix — which by definition barely changes the spelling —
        // still parses, including one dictated with its sentence terminator.
        expectCorrectionCommand("Correct the spelling of flow clone to FlowClone",
                                "flow clone", "FlowClone")
        expectCorrectionCommand("Correct spelling Kubernets to Kubernetes",
                                "Kubernets", "Kubernetes")
        expectCorrectionCommand("Correct spelling iphone to iPhone.", "iphone", "iPhone")
        expectCorrectionCommand("Correct spelling jon to John", "jon", "John")
        expectCorrectionCommand("Correct spelling stripe to Stripe Inc", "stripe", "Stripe Inc")
    }

    private func expectCorrectionCommand(_ text: String, _ wrong: String, _ right: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let parsed = Cleaner.parseCorrectionCommand(text)
        XCTAssertEqual(parsed?.wrong, wrong, file: file, line: line)
        XCTAssertEqual(parsed?.right, right, file: file, line: line)
    }

    func testSanitizeKeepsTheSpeakersOwnQuotationMarks() {
        // The speaker dictated a quoted phrase, so the wrapping quotes are content.
        XCTAssertEqual(FM.sanitize("\"All hands\"", input: "\"All hands\""), "\"All hands\"")
        XCTAssertEqual(FM.sanitize("\"All hands\"", input: "\u{201C}All hands\u{201D}"),
                       "\"All hands\"")
        // Nothing in the input was quoted, so the model wrapped its own answer.
        XCTAssertEqual(FM.sanitize("\"All hands\"", input: "All hands"), "All hands")
    }

    func testRefusalDetectorIgnoresTheSpeakersOwnWords() {
        // The speaker dictated the apology; the model faithfully retyped it.
        XCTAssertNil(Prompter.reject("Tell the team I cannot make the standup tomorrow.",
                                     "tell the team I cannot make the standup tomorrow"))
        XCTAssertNotNil(Prompter.reject("I'm sorry, I can't help with that.", "book the room"))
        XCTAssertNil(FM.refusalPhrase(in: "I cannot make the standup",
                                      input: "tell them I cannot make the standup"))
        XCTAssertEqual(FM.refusalPhrase(in: "I'm sorry, I can't help with that",
                                        input: "book the room"), "i can't")
    }

    func testRefusalDetectorRejectsCollapsedSpeakerOwnedPhraseInBothProfiles() {
        let source = "Tell Mark I cannot help with that because it is wrong."
        let collapsed = "I cannot help with that."
        let faithful = "Tell Mark I cannot help with that because it is wrong."

        XCTAssertEqual(Polisher.reject(collapsed, source), "refusal phrase 'i cannot'")
        XCTAssertEqual(Prompter.reject(collapsed, source), "refusal phrase 'i cannot'")
        XCTAssertNil(Polisher.reject(faithful, source))
        XCTAssertNil(Prompter.reject(faithful, source))
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func testGenerationErrorNamesNeverIncludeContextDebugDescription() {
        let marker = "private-marker-must-not-reach-log"
        let context = LanguageModelSession.GenerationError.Context(debugDescription: marker)
        let refusal = LanguageModelSession.GenerationError.Refusal(transcriptEntries: [])
        let cases: [(LanguageModelSession.GenerationError, String)] = [
            (.exceededContextWindowSize(context), "exceededContextWindowSize"),
            (.assetsUnavailable(context), "assetsUnavailable"),
            (.guardrailViolation(context), "guardrailViolation"),
            (.unsupportedGuide(context), "unsupportedGuide"),
            (.unsupportedLanguageOrLocale(context), "unsupportedLanguageOrLocale"),
            (.decodingFailure(context), "decodingFailure"),
            (.rateLimited(context), "rateLimited"),
            (.concurrentRequests(context), "concurrentRequests"),
            (.refusal(refusal, context), "refusal"),
        ]

        for (error, expected) in cases {
            let name = FM.name(error)
            XCTAssertEqual(name, expected)
            XCTAssertFalse(name.contains(marker))
        }
    }
#endif

    func testOnlyAPermanentSidecarFailureAnnouncesTheCleanFallback() {
        // `.failed` is the only readiness the sidecar cannot leave on its own, and the
        // notification is single-shot per profile — spending it on a child that is still
        // loading would both cry wolf at launch and silence the real crash later.
        XCTAssertTrue(FM.shouldDegrade(for: .failed))
        XCTAssertFalse(FM.shouldDegrade(for: .warming))
        XCTAssertFalse(FM.shouldDegrade(for: .cold))
        XCTAssertFalse(FM.shouldDegrade(for: .busy))
        XCTAssertFalse(FM.shouldDegrade(for: .ready))
        XCTAssertFalse(FM.shouldDegrade(for: .disabled))
    }

    func testSidecarRespawnsOncePerProcessAfterARuntimeFailure() {
        XCTAssertEqual(Sidecar.readinessAfterRuntimeFailure(previousFailures: 0), .cold)
        XCTAssertEqual(Sidecar.readinessAfterRuntimeFailure(previousFailures: 1), .failed)
        XCTAssertEqual(Sidecar.readinessAfterRuntimeFailure(previousFailures: 4), .failed)
    }

    func testLearnedCorrectionConfirmationWording() {
        XCTAssertEqual(
            AutoLearn.correctionSummary([
                (wrong: "Kubernets", right: "Kubernetes"),
                (wrong: "flow clone", right: "FlowClone"),
            ]),
            "Kubernets → Kubernetes, flow clone → FlowClone"
        )
        XCTAssertEqual(
            StatusMenu.learnedRowTitle("Kubernets → Kubernetes"),
            "Last learned: Kubernets → Kubernetes"
        )

        let longSummary = String(repeating: "correction ", count: 20)
        let title = StatusMenu.learnedRowTitle(longSummary)
        XCTAssertTrue(title.hasPrefix("Last learned: "))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title.count, "Last learned: ".count + 88)
    }

    func testPolishPromptShapeChecksPass() {
        let result = Polisher.promptCheck()
        XCTAssertGreaterThan(result.checks, 0)
        XCTAssertEqual(result.failed, 0)
    }

    func testPromptContractPreservesIntentAndRejectsExtremeContentLoss() {
        let input = "should we use the existing parser or write a new one, I'm leaning toward reusing it"
        let prompt = Prompter.prompt(input)

        XCTAssertTrue(Prompter.instructions.contains("keep requests as requests"))
        XCTAssertTrue(Prompter.instructions.contains("questions as questions"))
        XCTAssertFalse(Prompter.instructions.contains("State the task directly"))
        XCTAssertTrue(prompt.contains(
            "Preserve every separate point and the role the speaker gave it"
        ))
        XCTAssertTrue(prompt.contains(
            "Preserve uncertainty and preferences without changing what they apply to."
        ))
        XCTAssertTrue(prompt.contains("Apply self-corrections and omit every replaced value."))
        XCTAssertTrue(prompt.hasSuffix("Now rewrite this dictation as a prompt:\n\n" + input))

        let optionalPrompt = Prompter.prompt(
            "put the summary first if you can, no big deal either way"
        )
        XCTAssertTrue(optionalPrompt.contains("explicitly keep it optional"))
        let correctedPrompt = Prompter.prompt("move it to two, actually make that three")
        XCTAssertTrue(correctedPrompt.contains(
            "keep only the replacement and never mention the replaced wording"
        ))

        let longInput = "Investigate why checkout authentication times out for VPN users. "
            + "Update the README with the current setup steps. Move the Node runtime to version "
            + "twenty-two before Friday. Ask Marcus about inaccessible staging credentials. "
            + "Compare Safari failure rates with the session timeout window. Write the "
            + "conclusions in the incident document."
        XCTAssertNotNil(Prompter.reject("Investigate checkout authentication errors.", longInput))
        XCTAssertNotNil(Prompter.reject(
            "Investigate why checkout authentication times out for VPN users and document the failure.",
            longInput
        ))
        XCTAssertNotNil(Prompter.reject(
            "Investigate checkout authentication errors and update the README with current setup steps",
            longInput
        ))
        XCTAssertNil(Prompter.reject(
            "Make me a packing list for the trip.",
            "can you uh make me a packing list for the trip"
        ))

        let optionalInput = "put the summary first if you can, no big deal either way, but include the numbers"
        XCTAssertNotNil(Prompter.reject(
            "Put the summary first and include the numbers.", optionalInput
        ))
        XCTAssertNil(Prompter.reject(
            "If possible, put the summary first; the numbers are required.", optionalInput
        ))

        let correctedInput = "make the meeting email about 2pm, actually 3pm"
        XCTAssertNotNil(Prompter.reject(
            "Change the meeting email from 2pm to 3pm.", correctedInput
        ))
        XCTAssertNotNil(Prompter.reject(
            "Change the meeting email from 2 PM to 3 PM.", correctedInput
        ))
        XCTAssertNil(Prompter.reject("Make the meeting email about 3pm.", correctedInput))
        XCTAssertNil(Prompter.reject(
            "Set retries to 3 and keep the timeout at 2 seconds.",
            "Set retries to 2, actually 3, and keep the timeout at 2 seconds."
        ))
        XCTAssertNotNil(Prompter.reject(
            "Set retries to 2, then 3, and keep the timeout at 2 seconds.",
            "Set retries to 2, actually 3, and keep the timeout at 2 seconds."
        ))
        XCTAssertNil(Prompter.reject(
            "Compare SQLite rather than Postgres.",
            "Actually, compare SQLite rather than Postgres."
        ))
        XCTAssertNil(Prompter.reject(
            "Use SQLite instead of Postgres.",
            "Actually, use SQLite and not Postgres."
        ))
        let uncertainPrompt = Prompter.prompt(
            "Maybe the cache causes the timeout; investigate it."
        )
        XCTAssertFalse(uncertainPrompt.contains("This dictation contains an optional preference"))
        XCTAssertNil(Prompter.reject(
            "Maybe the cache causes the timeout; investigate it.",
            "Maybe the cache causes the timeout; investigate it."
        ))
        XCTAssertNotNil(Prompter.reject(
            "Investigate the VPN timeout. If possible, prioritize the Node update.",
            "Investigate the VPN timeout and update Node before Friday."
        ))
    }

    func testContextVocabularyRewritesExactAndUniqueFuzzyForms() {
        let terms = [ContextTerm(canonical: "ContextVocabulary",
                                 spokenForms: ["context vocabulary", "contextvocabulary"],
                                 source: .selected)]
        XCTAssertEqual(ContextVocabulary.rewrite("Open context vocabulary now", using: terms).text,
                       "Open ContextVocabulary now")
        XCTAssertEqual(ContextVocabulary.rewrite("contextvocabulari", using: terms).text,
                       "ContextVocabulary")
    }

    func testContinuationFormatting() {
        XCTAssertEqual(SmartFormat.continuation("This works.", prefix: "I think"),
                       " this works.")
        XCTAssertEqual(SmartFormat.continuation("Next step.", prefix: "Done. "),
                       "Next step.")
    }

    func testAXSecurityPolicyFailsClosed() {
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"), subrole: .absent,
                              protectedContent: .absent),
            .ordinary
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXSecureTextField"), subrole: .absent,
                              protectedContent: .absent),
            .secure
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"),
                              subrole: .value("AXSecureTextField"),
                              protectedContent: .absent),
            .secure
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"), subrole: .absent,
                              protectedContent: .value(true)),
            .secure
        )
        XCTAssertEqual(
            AXClient.classify(role: .failed, subrole: .absent,
                              protectedContent: .absent),
            .unknown
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"), subrole: .failed,
                              protectedContent: .absent),
            .unknown
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"), subrole: .absent,
                              protectedContent: .failed),
            .unknown
        )
    }

    /// An exhausted AX budget is a slow app, not a password field. Reading it as `.unknown`
    /// made every read that ran out of time refuse the paste with "secure field".
    func testExhaustedAXBudgetIsNotASecureField() {
        XCTAssertEqual(
            AXClient.classify(role: .timedOut, subrole: .absent, protectedContent: .absent),
            .timedOut
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"), subrole: .timedOut,
                              protectedContent: .absent),
            .timedOut
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"), subrole: .absent,
                              protectedContent: .timedOut),
            .timedOut
        )
        // A role the app DID answer with still decides: a proven secure field is secure
        // however the reads after it ended.
        XCTAssertEqual(
            AXClient.classify(role: .value("AXSecureTextField"), subrole: .timedOut,
                              protectedContent: .timedOut),
            .secure
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"),
                              subrole: .value(kAXSecureTextFieldSubrole as String),
                              protectedContent: .timedOut),
            .secure
        )
    }

    /// A target that never answered Accessibility is refused like the no-accessibility
    /// branch — the transcript stays on the clipboard, one Cmd+V away. Every other
    /// refusal leaves the user's clipboard untouched.
    func testUnresponsiveTargetKeepsTheTranscriptReachable() {
        guard case .unresponsive(let why) = Paster.decision(for: .appUnresponsive) else {
            return XCTFail("an unresponsive app must not be refused like a secure field")
        }
        XCTAssertEqual(why, "target app is not responding")
        guard case .secure = Paster.decision(for: .secureField) else {
            return XCTFail("a secure field still fails closed")
        }
        guard case .refused = Paster.decision(for: .fieldChanged) else {
            return XCTFail("a changed field is still an ordinary refusal")
        }
        guard case .valid(nil) = Paster.decision(for: .valid(nil)) else {
            return XCTFail("an app-only target is still valid")
        }
    }

    /// 2026-10-06: the processing cue blocked the main thread ~430 ms waking the Studio
    /// Display speakers, so Interface's read of the pasted text was answered after the
    /// 250 ms window and pastes that landed warned "Paste could not be confirmed". The
    /// window now starts when FlowClone's main thread could answer, bounded by the cap.
    func testPasteAcknowledgementWindowWaitsForAStalledMainThread() {
        let posted = 100.0, window = 0.25, cap = Paster.acknowledgementCap
        func deadline(_ mainFreeAt: Double?) -> Double {
            Paster.acknowledgementDeadline(postedAt: posted, mainFreeAt: mainFreeAt,
                                           window: window, cap: cap)
        }
        XCTAssertEqual(deadline(posted), posted + window, accuracy: 1e-9,
                       "a free main thread keeps the original window")
        XCTAssertEqual(deadline(posted + 0.43), posted + 0.43 + window, accuracy: 1e-9,
                       "a stalled main thread defers the window until it can answer")
        XCTAssertEqual(deadline(nil), posted + cap, accuracy: 1e-9,
                       "still stalled: keep waiting, but only up to the cap")
        XCTAssertEqual(deadline(posted + 0.9), posted + cap, accuracy: 1e-9,
                       "the cap bounds a late answer too")
        XCTAssertLessThanOrEqual(cap, 1.0, "a stall must never hold the hotkey for long")
    }

    /// Polish was retired as a dictation mode: the picker offers Raw, Clean and Prompt, a
    /// saved "polish" selection migrates to Clean exactly once, and nothing else moves.
    func testRetiredPolishSelectionMigratesToClean() {
        XCTAssertEqual(Mode.allCases, [.raw, .clean, .prompt])
        XCTAssertNil(Mode(rawValue: "polish"))
        XCTAssertEqual(Mode.allCases.filter(\.isLLM), [.prompt])
        let suite = ScratchDefaults.name("mode-migration")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("polish", forKey: "mode")
        XCTAssertTrue(Mode.retireLegacySelection(defaults))
        XCTAssertEqual(defaults.string(forKey: "mode"), "clean")
        XCTAssertFalse(Mode.retireLegacySelection(defaults), "migrates once")
        for kept in ["raw", "clean", "prompt"] {
            defaults.set(kept, forKey: "mode")
            XCTAssertFalse(Mode.retireLegacySelection(defaults))
            XCTAssertEqual(defaults.string(forKey: "mode"), kept)
        }
        defaults.removeObject(forKey: "mode")
        XCTAssertFalse(Mode.retireLegacySelection(defaults), "no saved selection stays unset")
        XCTAssertNil(defaults.string(forKey: "mode"))
    }

    /// "Keep last dictation on clipboard" is opt-in and both surfaces (Settings and the menu
    /// bar checkbox) share one stored switch that turns off as reliably as it turns on.
    func testKeepLastDictationOnClipboardIsOptInAndTogglesBothWays() {
        let key = "keepDictationOnClipboard"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Paster.keepsLastDictation, "off until the user turns it on")
        Paster.keepsLastDictation = true
        XCTAssertTrue(Paster.keepsLastDictation)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        Paster.keepsLastDictation.toggle()
        XCTAssertFalse(Paster.keepsLastDictation)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    /// commit fcac149, extended: only a PROVEN insertion may hand the user's clipboard
    /// back, and only when there was a clipboard we could capture. Preservation is a
    /// separate fact from the acknowledgement — a paste whose prior clipboard could not be
    /// snapshotted is still a proven paste, and must keep reaching AutoLearn and the
    /// percentiles.
    func testOnlyAProvenInsertionRestoresTheClipboard() {
        let insertion = PasteTarget.ConfirmedInsertion(location: 4, length: 7)
        XCTAssertTrue(Paster.mayRestoreClipboard(.targetConfirmed(insertion), preserved: true))
        XCTAssertFalse(Paster.mayRestoreClipboard(.clipboardConsumed, preserved: true))
        XCTAssertFalse(Paster.mayRestoreClipboard(.targetConfirmed(insertion), preserved: false))
        XCTAssertFalse(Paster.mayRestoreClipboard(.clipboardConsumed, preserved: false))
    }

    /// The pill belongs to the screen the user is typing on. Window bounds arrive in
    /// CoreGraphics' top-left-origin space and must be flipped before any NSScreen frame
    /// can be compared with them.
    func testPillFollowsTheScreenHoldingMostOfTheWindow() {
        let main = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let right = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)

        // A window at the top of the main display in CG coordinates is at the TOP of it
        // in AppKit coordinates too — the flip is about the main display's height.
        XCTAssertEqual(
            Overlay.appKitRect(fromWindowBounds: CGRect(x: 10, y: 0, width: 400, height: 300),
                               mainScreenHeight: main.height),
            CGRect(x: 10, y: 600, width: 400, height: 300))
        XCTAssertEqual(
            Overlay.appKitRect(fromWindowBounds: CGRect(x: 1_500, y: 100, width: 800, height: 600),
                               mainScreenHeight: main.height),
            CGRect(x: 1_500, y: 200, width: 800, height: 600))

        XCTAssertEqual(Overlay.screenIndex(holdingMostOf: CGRect(x: 100, y: 100,
                                                                width: 200, height: 200),
                                           in: [main, right]), 0)
        XCTAssertEqual(Overlay.screenIndex(holdingMostOf: CGRect(x: 1_500, y: 100,
                                                                width: 200, height: 200),
                                           in: [main, right]), 1)
        // Straddling: the screen holding MORE of the window wins, not the first one hit.
        XCTAssertEqual(Overlay.screenIndex(holdingMostOf: CGRect(x: 1_340, y: 100,
                                                                width: 400, height: 200),
                                           in: [main, right]), 1)
        XCTAssertEqual(Overlay.screenIndex(holdingMostOf: CGRect(x: 1_240, y: 100,
                                                                width: 400, height: 200),
                                           in: [main, right]), 0)
        // A window on a display that has since been unplugged selects nothing.
        XCTAssertNil(Overlay.screenIndex(holdingMostOf: CGRect(x: -900, y: 100,
                                                              width: 200, height: 200),
                                         in: [main, right]))
        // A zero-area window is not evidence of a screen.
        XCTAssertNil(Overlay.screenIndex(holdingMostOf: CGRect(x: 100, y: 100,
                                                              width: 0, height: 200),
                                         in: [main, right]))
    }

    func testClamshellDemotesBuiltInMicrophone() {
        func device(_ id: AudioDeviceID, _ transport: UInt32) -> AudioInputDevice {
            AudioInputDevice(id: id, uid: "uid-\(id)", name: "device-\(id)", transport: transport,
                             isAlive: true, inputChannels: 1)
        }
        let builtIn = device(1, kAudioDeviceTransportTypeBuiltIn)
        let usb = device(2, kAudioDeviceTransportTypeUSB)
        let bluetooth = device(3, kAudioDeviceTransportTypeBluetooth)
        let devices = [bluetooth, builtIn, usb]

        // Lid open: an unselected built-in mic still outranks other wired inputs.
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: bluetooth.id,
                                                          devices: devices).first, builtIn)
        // Lid closed: macOS keeps the built-in mic alive but it delivers exact zeros, so
        // it must go last — after wireless — even when it is the selected default.
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: bluetooth.id,
                                                          devices: devices, lidClosed: true),
                       [usb, bluetooth, builtIn])
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: builtIn.id,
                                                          devices: devices, lidClosed: true),
                       [usb, bluetooth, builtIn])
    }

    func testTrailingSnapshotReturnsOnlyTheRecentWindow() {
        let recorder = Recorder(queue: DispatchQueue(label: "test.recorder"))
        let total = Int(Recorder.sampleRate * 5)
        recorder.preloadForTest((0..<total).map(Float.init))
        let full = recorder.snapshot()
        XCTAssertEqual(full.count, total)

        // The live pill only needs the newest words. A 2s window must not hand the
        // decoder the whole five-second utterance again.
        let window = recorder.snapshot(lastSeconds: 2)
        XCTAssertGreaterThanOrEqual(window.count, Int(Recorder.sampleRate * 2))
        XCTAssertLessThan(window.count, total)
        XCTAssertEqual(window, Array(full.suffix(window.count)))
        // A window longer than the capture is the whole capture.
        XCTAssertEqual(recorder.snapshot(lastSeconds: 30), full)
    }

    func testMicrophoneUsesOnlyABoundedWarmWindow() {
        XCTAssertEqual(Recorder.idleKeepWarmSeconds, 30)
        XCTAssertTrue(Recorder.idleKeepWarmSeconds.isFinite,
                      "no route may keep the microphone open indefinitely")
    }

    func testEscapeSwallowFollowsTheCaptureNotTheKeyState() {
        let queue = DispatchQueue(label: "test.session")
        let monitor = HotkeyMonitor(queue: queue, clockMS: { 0 })
        XCTAssertFalse(monitor.escapeShouldSwallow())

        // A latch is not proof a recording exists — the Pipeline can refuse the press.
        queue.sync { monitor.startLatched("test") }
        XCTAssertTrue(queue.sync { monitor.isLatched })
        XCTAssertFalse(monitor.escapeShouldSwallow(),
                       "key state alone must no longer swallow Esc")

        queue.sync { monitor.setCaptureActive(true) }
        XCTAssertTrue(monitor.escapeShouldSwallow())
        queue.sync { monitor.stopLatched() }
        XCTAssertTrue(monitor.escapeShouldSwallow(),
                      "only the Pipeline may clear the mirror it owns")
        queue.sync { monitor.setCaptureActive(false) }
        XCTAssertFalse(monitor.escapeShouldSwallow())
    }

    func testContinuityCaptureIsLastResort() {
        func device(_ id: AudioDeviceID, _ transport: UInt32) -> AudioInputDevice {
            AudioInputDevice(id: id, uid: "uid-\(id)", name: "device-\(id)", transport: transport,
                             isAlive: true, inputChannels: 1)
        }
        let builtIn = device(1, kAudioDeviceTransportTypeBuiltIn)
        let usb = device(2, kAudioDeviceTransportTypeUSB)
        let phone = device(3, kAudioDeviceTransportTypeContinuityCaptureWired)

        // The iPhone enumerates first and is not what "the mic" means; a real wired
        // input must outrank it, even when the phone is the selected default.
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: nil,
                                                          devices: [phone, usb, builtIn]),
                       [builtIn, usb, phone])
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: phone.id,
                                                          devices: [phone, usb]),
                       [usb, phone])
        // Lid closed: still ahead of the silent built-in mic, still behind the wired input.
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: nil,
                                                          devices: [phone, usb, builtIn],
                                                          lidClosed: true),
                       [usb, phone, builtIn])
    }
}
