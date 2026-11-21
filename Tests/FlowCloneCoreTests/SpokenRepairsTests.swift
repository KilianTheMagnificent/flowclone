import Foundation
import XCTest
@testable import FlowCloneCore

/// Spoken self-repairs (SpokenRepairs.swift). The shapes mirror the owner's real
/// self-corrections (docs/2026-11-09-self-corrections.md) with invented wording. The
/// second half matters as much as the first: every sentence there has the surface shape
/// of a repair and must come back exactly as spoken.
final class SpokenRepairsTests: XCTestCase {
    private func expectRepairs(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (input, expected) in cases {
            XCTAssertEqual(SpokenRepairs.apply(input), expected, "input: \(input)", file: file, line: line)
        }
    }

    private func expectUntouched(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs {
            let result = SpokenRepairs.apply(OriginText(input))
            XCTAssertEqual(result.text.text, input, file: file, line: line)
            XCTAssertTrue(result.rules.isEmpty, "rules fired on: \(input)", file: file, line: line)
        }
    }

    // MARK: - Repairs

    func testBrokenOffFragmentsAreDropped() {
        expectRepairs([
            // the next word completes the fragment
            ("It shows you've c completed the course.", "It shows you've completed the course."),
            ("Please also e email the team.", "Please also email the team."),
            // a later word completes it
            ("We might be able to loc replicate it locally.", "We might be able to replicate it locally."),
            ("Follow the general des best principles of design.", "Follow the general best principles of design."),
            // the speaker restarts on the word before it
            ("It shows the re the true waveform.", "It shows the true waveform."),
            ("They scare you into s into not using it.", "They scare you into not using it."),
            // the restart re-says the lead-in, so the abandoned lead-in goes too
            ("When I drag a p one pane onto another.", "When I drag one pane onto another."),
            ("Come up for a f with a fix for this.", "Come up with a fix for this."),
        ])
    }

    func testDoubledWordsAndRestartedPhrases() {
        expectRepairs([
            ("Are are you working now?", "Are you working now?"),
            ("Get a a bird's eye view.", "Get a bird's eye view."),
            ("I I think I can.", "I think I can."),
            ("I, I think so.", "I think so."),
            ("You you can do that later.", "You can do that later."),
            ("The the the thing broke.", "The thing broke."),
            ("The prep we the prep we were given was thin.", "The prep we were given was thin."),
            ("We should we should ship it today.", "We should ship it today."),
            ("I want to I want to ship it today.", "I want to ship it today."),
            ("Would should they not be running?", "Should they not be running?"),
            ("We could would love to join.", "We would love to join."),
        ])
    }

    func testCueRepairs() {
        expectRepairs([
            // the repair restarts on a word already said
            ("Put this update on dev excuse me on main immediately.", "Put this update on main immediately."),
            ("Track my codex, excuse me, my open code usage.", "Track my open code usage."),
            ("Push it to dev, sorry, to main.", "Push it to main."),
            ("Send it to Bob, I mean, to Rob.", "Send it to Rob."),
            ("Let's meet at the office, I mean at the cafe, around noon.", "Let's meet at the cafe, around noon."),
            ("Put it on the left, no, on the right side.", "Put it on the right side."),
            ("Can we do the call at 2 p.m., I mean at 3 p.m.?", "Can we do the call at 3 p.m.?"),
            // a one- or two-word repair replaces the same number of words
            ("In lieu of that question, or rather statement, what happens next?",
             "In lieu of that statement, what happens next?"),
            ("Over the next 20 years, or actually 10 years, how will it look?",
             "Over the next 10 years, how will it look?"),
            ("It's blue, or rather teal.", "It's teal."),
            ("Send it to Alice, I mean Sarah.", "Send it to Sarah."),
        ])
    }

    func testScratchThatDropsTheSentenceInProgress() {
        expectRepairs([
            ("Use the blue theme for the dashboard. Scratch that, keep the grey theme.", "Keep the grey theme."),
            ("Ship it. Use the blue theme for the header, scratch that, keep it grey.", "Ship it. Keep it grey."),
        ])
        expectUntouched([
            "Okay, scratch that, I was wrong.",          // about an earlier message
            "Scratch that.",
            "Let's scratch that idea for now.",
            "Use the blue theme for the dashboard. Scratch that.",
        ])
    }

    // MARK: - Protections

    func testOrdinaryRepetitionIsKept() {
        expectUntouched([
            "I think I can do it.",
            "I want to go to the store.",
            "What it is is a problem.",
            "He said that that was fine.",
            "Do this this way.",
            "Log in in the morning.",
            "On and on and on it goes.",
            "Step by step by step we got there.",
            "I know, I know.",
            "Thank you thank you so much.",
            "She said to you, you clarify the goal.",
            "Is that true, or is that a scam?",
            "I'm not trying to replace the old one, I'm trying to replace the new one.",
            "It was very very good.",
        ])
    }

    func testLettersAndShortWordsAreNotFragments() {
        expectUntouched([
            "We need n numbers and k keys.",
            "Differentiate r with respect to theta.",
            "Take any two points a and b and a third point c.",
            "Compute f using the formula.",
            "Pair them into m more blocks.",
            "It started 13.6 s after the start.",
            "Give me the vitamin d dose.",
            "Giving the box the right height.",
            "Use it if it has it, then stop.",
            "It costs five dollars per person.",
            "Add additional tests.",
            "Open the app and application settings.",
            "Ask the dev team about development.",
            "I want you to start research re",
        ])
    }

    func testCueWordsInOrdinaryUseAreKept() {
        expectUntouched([
            "And by the permissions I mean the settings file.",
            "It's a tool that's actually a toy.",
            "It doesn't actually tell you if you copied anything.",
            "Meet at 3, actually Friday works better.",
            "I was late, sorry, I got stuck in traffic.",
            "To be clear, I mean to say that it works.",
            "The deploy is done. I mean, the whole thing went smoothly.",
            "It's not on the list, I mean it's on the other list.",
            "We don't have a product yet. Or rather, we haven't served anyone.",
            "I'll call him, or rather text.",
            "Tell John, or rather ask.",
            "Use tabs rather than spaces.",
            "Excuse me, can you send the file?",
        ])
    }

    /// Build 2026111001 deleted the speaker's words in all of these: a bare "sorry", "no" or
    /// "wait" after a comma was read as a cue and the restart rule cut back to an earlier
    /// "for" or "to"; "you you" was read as a stutter.
    func testEverydayEmailAndChatPhrasingsAreKept() {
        let reported = [
            "Thanks for the help, sorry for the delay.",
            "Thanks for the update, sorry for the late reply.",
            "Happy to chat on Monday, sorry to miss today.",
            "Good to see you, sorry to bother you again.",
            "Thanks for coming, wait for me outside.",
            "Did I tell you you were right?",
            "I told you you would like it.",
        ]
        expectUntouched(reported)
        for input in reported {
            let cleaned = Cleaner.cleanWithChanges(input)
            XCTAssertEqual(cleaned.text, input)
            XCTAssertTrue(cleaned.repairs.isEmpty, "repairs fired on: \(input)")
        }
        expectUntouched([
            // "…, sorry about/for/to …"
            "Thanks for the reminder, sorry about the confusion.",
            "Thanks for your patience, sorry for the wait.",
            "Thanks for reaching out, sorry for the slow response.",
            "Glad to hear it, sorry to hear about the delay.",
            "Nice to meet you, sorry to cut it short.",
            "Great to hear from you, sorry for the late reply.",
            "Looking forward to it, sorry about the mix-up.",
            "Sorry to keep you waiting, sorry for the trouble.",
            "Thanks for the invite, sorry I can't make it.",
            // "…, no problem / no worries / no to …"
            "Thanks for the feedback, no problem at all.",
            "Happy to help, no problem.",
            "Thanks for letting me know, no worries.",
            "Thanks for the heads up, no worries at all.",
            "Sorry for the late reply, no worries if you're busy.",
            "I said yes to the first offer, no to the second.",
            "Thanks for the offer, no thanks.",
            "Happy to join on Friday, no need to send an invite.",
            // "…, wait until/for …"
            "Thanks for the ride, wait for me at the corner.",
            "Ready for the review, wait for the final draft.",
            "Thanks for waiting, wait until I call you.",
            "Good to go on Monday, wait until Tuesday to send it.",
            // "I meant to …", "make that the …"
            "Good to see you, I meant to write sooner.",
            "Sorry to keep you waiting, I meant to call earlier.",
            "I wanted to go to the party, I meant to tell you.",
            "Fix the bug, make that the priority.",
            "Add a test for it, make that a habit.",
            // words that double grammatically
            "I think that that plan works.",
            "Make sure that that file is saved.",
            "She had had enough by noon.",
            "We had had a long day.",
            "Whatever the answer is is fine.",
            "What the plan is is unclear.",
            "Thank you you guys are the best.",
            "I promise you you won't regret it.",
            "I'll show you you can do it.",
            "The ones that are are fine.",
            "The tools we have have bugs.",
            "Whatever he has has to go.",
        ])
        // The corrections these words were meant for still work when the cue is set off.
        expectRepairs([
            ("Push it to dev, sorry, to main.", "Push it to main."),
            ("Put it on the left, no, on the right side.", "Put it on the right side."),
            ("Leave it for Monday, wait, for Tuesday.", "Leave it for Tuesday."),
            ("Send it to Bob, I mean, to Rob.", "Send it to Rob."),
            ("Are are you working now?", "Are you working now?"),
            ("You you can do that later.", "You can do that later."),
            ("And you you need to sign it.", "And you need to sign it."),
        ])
    }

    // MARK: - Provenance and integration

    func testEveryKeptCharacterKeepsItsRawAnchor() {
        let inputs = [
            "Are are you working on dev excuse me on main, or the re the true branch?",
            "Use the blue theme for the dashboard. Scratch that, keep the grey theme.",
            "When I drag a p one pane onto another.",
        ]
        for input in inputs {
            let source = Array(input)
            let result = SpokenRepairs.apply(OriginText(input))
            XCTAssertFalse(result.rules.isEmpty, input)
            let text = Array(result.text.text)
            XCTAssertEqual(text.count, result.text.origins.count, input)
            XCTAssertEqual(result.text.origins, result.text.origins.sorted(), "anchors stay in order: \(input)")
            for (character, origin) in zip(text, result.text.origins) {
                // The only edit that is not a deletion is a moved sentence capital.
                XCTAssertEqual(String(character).lowercased(), String(source[origin]).lowercased(), input)
            }
        }
    }

    func testCleanAppliesRepairsAndNamesTheRules() {
        // Fillers go first, so "the um the" is a doubled word by the time repairs run.
        let doubled = Cleaner.cleanWithChanges("Make sure that the um the pipeline is fast.")
        XCTAssertEqual(doubled.text, "Make sure that the pipeline is fast.")
        XCTAssertEqual(doubled.repairs, ["doubled"])

        let cue = Cleaner.cleanWithChanges("Put this update on dev excuse me on main immediately.")
        XCTAssertEqual(cue.text, "Put this update on main immediately.")
        XCTAssertEqual(cue.repairs, ["cue-retrace"])

        let plain = Cleaner.cleanWithChanges("Put this update on main immediately.")
        XCTAssertEqual(plain.text, "Put this update on main immediately.")
        XCTAssertTrue(plain.repairs.isEmpty)
    }

    func testParagraphBreaksCrossSentenceCapitalsAndScratchDeadTokens() {
        expectRepairs([
            ("First point.\n\nAre are you ready now?",
             "First point.\n\nAre you ready now?"),
            ("First line.\nUse the blue theme. Scratch that, keep the grey theme.",
             "First line.\nKeep the grey theme."),
            ("First paragraph.\n\nOld sentence here. Scratch that, keep the new one.",
             "First paragraph.\n\nKeep the new one."),
            // A doubled function word right after "Scratch that," leaves a dead token at k+2;
            // takeCapital must skip dead tokens so the surviving sentence still starts uppercase.
            ("Use the blue theme. Scratch that, we we keep the grey theme.",
             "We keep the grey theme."),
            ("3pm works. Use the 3pm slot. Scratch that, let's do 4pm.",
             "3pm works. Let's do 4pm."),
        ])

        for input in [
            "First point.\n\nAre are you ready now?",
            "First paragraph.\n\nOld sentence here. Scratch that, we we keep the new one.",
        ] {
            let source = Array(input)
            let result = SpokenRepairs.apply(OriginText(input))
            let chars = Array(result.text.text)
            XCTAssertEqual(chars.count, result.text.origins.count, input)
            XCTAssertEqual(result.text.origins, result.text.origins.sorted(), input)
            for (ch, origin) in zip(chars, result.text.origins) {
                XCTAssertEqual(String(ch).lowercased(), String(source[origin]).lowercased(), input)
            }
        }
    }

    /// Audit hook for rule changes: point FLOWCLONE_REPAIR_CORPUS at a text file with one
    /// dictation per line and the repaired lines are written next to it as `<file>.out`.
    func testCorpusAudit() throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWCLONE_REPAIR_CORPUS"] else {
            throw XCTSkip("set FLOWCLONE_REPAIR_CORPUS to audit a corpus")
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
        let output = lines.map { SpokenRepairs.apply($0) }.joined(separator: "\n")
        try output.write(toFile: path + ".out", atomically: true, encoding: .utf8)
    }
}
