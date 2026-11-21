import XCTest
@testable import FlowCloneCore

/// The new rules below, plus the fixtures of the former `SmartFormat.selfCheck()` whose
/// launch flag was removed. Those strings are verbatim.
final class SmartFormatTests: XCTestCase {
    func testSpokenPunctuation() {
        let cases: [(String, String)] = [
            ("He said, open quote, hello", "He said \"hello"),               // unclosed stays open
            ("open quote this is fine unquote she said", "\"this is fine\" she said"),
            ("begin quote hello world end quote", "\"hello world\""),
            ("She said, open quote, hello, unquote.", "She said \"hello\"."),
            ("That was a famous quote by Einstein.", "That was a famous quote by Einstein."),
            ("First item, new line, second item", "First item\nsecond item"),
            ("Wrap up. New paragraph. Next topic", "Wrap up.\n\nNext topic"),
            // redteam M7: mid-sentence "new line"/"new paragraph" are the speaker's words.
            ("Add a new line to the config file.", "Add a new line to the config file."),
            ("The new paragraph style is broken.", "The new paragraph style is broken."),
            ("She said \" hello \" again", "She said \"hello\" again"),      // hygiene only
            ("Nothing to convert here.", "Nothing to convert here."),
            // F5: utterance-final terminators, absorbing the ASR's own "." or "," on either side.
            ("Are you coming question mark", "Are you coming?"),
            ("Are you coming question mark.", "Are you coming?"),
            ("Are you coming, question mark.", "Are you coming?"),
            ("That was incredible exclamation point", "That was incredible!"),
            ("Watch out exclamation mark.", "Watch out!"),
            ("The question mark is optional.", "The question mark is optional."),
            // audit A-4: bare "period"/"full stop" are not commands; the "insert …" forms are.
            ("Call me tomorrow period", "Call me tomorrow period"),
            ("We studied the Jurassic period.", "We studied the Jurassic period."),
            ("Send it insert period", "Send it."),
            ("Ship it insert period Then rest.", "Ship it. Then rest."),
            ("Wait insert em dash never mind", "Wait\u{2014}never mind"),
            ("The em dash is my favorite.", "The em dash is my favorite."),
        ]
        for (input, want) in cases {
            XCTAssertEqual(SmartFormat.spokenPunctuation(input), want, input)
        }
    }

    /// F6: a lead-in clause, then markers ascending from one, each introducing ≥2 words.
    func testAutoListFixtures() {
        let cases: [(String, String)] = [
            ("My top goals this week are one finish the report two send the presentation "
             + "three call Sam",
             "My top goals this week are:\n1. Finish the report\n2. Send the presentation\n"
             + "3. Call Sam"),
            ("My top goals this week are 1 finish the report 2 send the presentation 3 call Sam",
             "My top goals this week are:\n1. Finish the report\n2. Send the presentation\n"
             + "3. Call Sam"),
            ("The steps are the following one open the file two edit the config three restart the app",
             "The steps are the following:\n1. Open the file\n2. Edit the config\n3. Restart the app"),
            ("Here are the priorities: one ship the build two write the notes.",
             "Here are the priorities:\n1. Ship the build\n2. Write the notes"),
            // review F-10: no lead-in is never a list, whatever the marker count.
            ("One day I walked two miles then three blocks home",
             "One day I walked two miles then three blocks home"),
            ("The blockers are one of the things we discussed two of them are still open",
             "The blockers are one of the things we discussed two of them are still open"),
            // Address / measurement: the markers introduce nothing, so nothing is rewritten.
            ("My address is one two three Main Street", "My address is one two three Main Street"),
            ("The gap is one to two millimeters wide", "The gap is one to two millimeters wide"),
            ("Nothing to list here.", "Nothing to list here."),
        ]
        for (input, want) in cases {
            XCTAssertEqual(SmartFormat.autoList(input), want, input)
        }
    }

    func testContinuationFixtures() {
        let cases: [(String, String?, String)] = [
            ("The report is done", "I think", " the report is done"),
            ("I think so", "and ", "I think so"),                            // "I" survives
            ("hello there", "Wait", " hello there"),                         // space inserted
            ("The next thing.", "I finished it. ", "The next thing."),       // terminal: no-op
            ("Next up.", "Done.", " Next up."),                              // terminal: space only
            ("on Tuesday.", "The meeting is", " on Tuesday."),               // completed sentence
            ("Hello there.", nil, "Hello there."),                           // no AX context
            // redteam LOW4: colon ends the line (period kept), opener suppresses the space.
            ("Fix the parser.", "TODO:", " Fix the parser."),
            ("note this", "see (", "note this"),
            ("The next line.", "Some text\n", "The next line."),             // newline ends it
            ("API keys are rotated", "we agreed ", "API keys are rotated"),  // acronym
            // Proper nouns / weekdays keep their case and completed-sentence punctuation.
            ("Monday works for me.", "I think", " Monday works for me."),
            ("Paris was great.", "we went to ", "Paris was great."),
            ("Parakeet is fast", "I use ", "Parakeet is fast"),
            ("We should probably move the meeting to next week before it slips.", "I think",
             " we should probably move the meeting to next week before it slips."),
        ]
        for (input, prefix, want) in cases {
            XCTAssertEqual(SmartFormat.continuation(input, prefix: prefix), want, input)
        }
    }


    func testAutoListRequiresThreeMarkersWithoutAnExplicitLeadIn() {
        // A word lead-in plus two ascending markers is ordinary prose far more often than
        // it is a list, and a wrong rewrite mangles the whole utterance.
        XCTAssertEqual(SmartFormat.autoList("The plan is one thing today and two things tomorrow."),
                       "The plan is one thing today and two things tomorrow.")
        // The self-check's own two-marker fixture had exactly that shape and expected a
        // list; the sentence above is why it no longer gets one.
        XCTAssertEqual(SmartFormat.autoList("My top goals this week are one finish the report "
                                            + "two send the presentation"),
                       "My top goals this week are one finish the report "
                       + "two send the presentation")
        XCTAssertEqual(SmartFormat.autoList("My top goals this week are one finish the report "
                                            + "two send the presentation three call Sam"),
                       "My top goals this week are:\n1. Finish the report\n"
                       + "2. Send the presentation\n3. Call Sam")
        // An explicit ":" is the speaker's own list marker, so two items still qualify.
        XCTAssertEqual(SmartFormat.autoList("Items: one green apples two ripe pears"),
                       "Items:\n1. Green apples\n2. Ripe pears")
    }

    func testContinuationKeepsAnAbbreviationsOwnPeriod() {
        XCTAssertEqual(SmartFormat.continuation("Call at 3 p.m.", prefix: "I think"),
                       " Call at 3 p.m.")
        XCTAssertEqual(SmartFormat.continuation("water, snacks, etc.", prefix: "bring"),
                       " water, snacks, etc.")
        XCTAssertEqual(SmartFormat.continuation("we shipped 2.5.", prefix: "I think"),
                       " we shipped 2.5.")
        XCTAssertEqual(SmartFormat.continuation("ask Dr.", prefix: "I'll"), " ask Dr.")
        // A completed sentence keeps its period, regardless of the dictation's length.
        XCTAssertEqual(SmartFormat.continuation("we should go.", prefix: "I think"),
                       " we should go.")
    }
}
