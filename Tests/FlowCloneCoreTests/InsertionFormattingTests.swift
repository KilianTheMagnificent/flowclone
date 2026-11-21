import XCTest
@testable import FlowCloneCore

final class InsertionFormattingTests: XCTestCase {
    func testConsecutiveDictationsUseTheActualSentenceBoundaryInEveryNormalMode() {
        for mode in [Mode.clean, .prompt] {
            XCTAssertEqual(format("The remaining work.", before: "I want to finish", mode: mode), " the remaining work.")
            XCTAssertEqual(format("And send it tomorrow.", before: "I want to finish the remaining work, ", mode: mode),
                           "and send it tomorrow.")
            XCTAssertEqual(format("then send it tomorrow.", before: "The work is finished. ", mode: mode),
                           "Then send it tomorrow.")
        }
    }

    func testSentenceBoundariesIncludeQuotesParagraphsHeadingsAndLists() {
        for before in ["Done. ", "Done! ", "Done? ", "He said “done.” ", "(Done.) ", "Done.\" ",
                       "Previous paragraph\n", "Previous paragraph\n\n", "Previous\r\n", "Text\u{2028}",
                       "TODO: ", "- ", "1. ", "3) ", "• ", "# ", "## ", "- [ ] ", "- [x] ", "> ", "", "(", "Done. ("] {
            XCTAssertEqual(format("the next item.", before: before), "The next item.", before.debugDescription)
        }
        XCTAssertEqual(format("The next part.", before: "First clause; "), "the next part.")
        XCTAssertEqual(format("The next part.", before: "First clause, "), "the next part.")
        XCTAssertEqual(format("The next part.", before: "For example, e.g. "), "the next part.")
    }

    func testNamesPronounsAcronymsAndDictionaryCapitalizationSurvive() {
        for text in ["I agree.", "I'm ready.", "I’ve finished.", "NASA is ready.", "API access works.",
                     "THE WHOLE MESSAGE.", "Monday works.", "Paris was great.", "Andre is ready.",
                     "Will is here.", "Parakeet is fast.", "iPhone works.", "eBay works."] {
            XCTAssertEqual(format(text, before: "I think "), text, text)
        }
        XCTAssertEqual(InsertionFormatter.format("Clean mode works.", context: .init(before: "Use ", after: ""),
                                                protectedTerms: ["Clean"]), "Clean mode works.")
        XCTAssertEqual(InsertionFormatter.format("iPhone", context: .init(before: "", after: "")), "iPhone")
    }

    func testLinguisticFallbackHandlesCommonWordsBeyondTheFunctionWordList() {
        XCTAssertEqual(format("Review the proposal.", before: "We should "), "review the proposal.")
        XCTAssertEqual(format("Send the report.", before: "Please "), "send the report.")
        XCTAssertEqual(format("Additional information.", before: "We need "), "additional information.")
        XCTAssertEqual(format("Improve this feature.", before: "Please "), "improve this feature.")
    }

    func testJoiningBothSidesAvoidsRunTogetherWordsAndDuplicateSpaces() {
        XCTAssertEqual(format("The report.", before: "We need ", after: " today."), "the report")
        XCTAssertEqual(format("The report.", before: "We need ", after: "today."), "the report ")
        XCTAssertEqual(format("the report.", before: "", after: "is complete."), "The report ")
        XCTAssertEqual(format(" The report. ", before: "We need ", after: " today."), "the report")
        XCTAssertEqual(format("The report", before: "We need", after: " today."), " the report")
        XCTAssertEqual(format("Note this", before: "See (", after: ") for details."), "note this")
        XCTAssertEqual(format("known", before: "well-", after: ""), "known")
    }

    func testRightHandPunctuationAndExplicitStops() {
        XCTAssertEqual(format("The report.", before: "Here is ", after: "."), "the report")
        XCTAssertEqual(format("The report.", before: "Here is ", after: ", as requested."), "the report")
        XCTAssertEqual(format("Are you ready?", before: "", after: "?"), "Are you ready")
        XCTAssertEqual(format("Finished!", before: "", after: "Next topic."), "Finished! ")
        XCTAssertEqual(InsertionFormatter.format("The report.", context: .init(before: "We need ", after: "today."),
                                                preserveTerminalPeriod: true), "the report. ")
        for after: String? in [nil, ""] {
            XCTAssertEqual(format("On Tuesday.", before: "The meeting is ", after: after), "on Tuesday.",
                           "Short fragments are not permission to remove a real sentence ending")
        }
        XCTAssertEqual(format("Dr.", before: "Ask ", after: " Smith."), "Dr.")
        XCTAssertEqual(format("3 p.m.", before: "Meet at ", after: " tomorrow."), "3 p.m.")
        XCTAssertEqual(format("Wait...", before: "", after: "."), "Wait...")
    }

    func testSelectionWhitespaceAndInsideWordEditsHaveDifferentBoundaries() {
        let replacingWords = InsertionContext(before: "We need", after: "today.", selected: " the old plan ")
        XCTAssertEqual(InsertionFormatter.format("The new plan.", context: replacingWords), " the new plan ")
        XCTAssertEqual(format("fix", before: "pre", after: "ed"), "fix")
        XCTAssertEqual(format("name", before: "https://example.com/", after: ""), "name")
    }

    func testUnknownContextVerbatimAndNonSpaceDelimitedScriptsRemainSafe() {
        XCTAssertEqual(InsertionFormatter.format("The report.", context: .empty), "The report.")
        XCTAssertEqual(InsertionFormatter.format(" The report. ", context: .init(before: "we need", after: "today"),
                                                mode: .raw), " The report. ")
        XCTAssertEqual(format("世界", before: "你好", after: ""), "世界")
        XCTAssertEqual(format("\n\nNext paragraph.", before: "Previous paragraph"), "\n\nNext paragraph.")
        XCTAssertEqual(format("1. First item\n2. Second item", before: ""), "1. First item\n2. Second item")
        XCTAssertEqual(format("And more.", before: "unknown field"), " and more.")
        // A subsequent failed read never inherits the preceding insertion's snapshot.
        XCTAssertEqual(InsertionFormatter.format("And more.", context: .empty), "And more.")
    }

    private func format(_ text: String, before: String?, after: String? = "", mode: Mode = .clean) -> String {
        InsertionFormatter.format(text, context: InsertionContext(before: before, after: after), mode: mode)
    }
}
