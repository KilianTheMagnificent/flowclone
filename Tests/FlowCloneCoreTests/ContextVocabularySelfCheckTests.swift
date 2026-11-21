import XCTest
@testable import FlowCloneCore

final class ContextVocabularySelfCheckTests: XCTestCase {
    func testExtractionAndRewriteFixtures() {
        let terms = ContextVocabulary.extract(
            before: "let currentSession = ContextVocabulary() // PrivateTokenABC123456789\n",
            selected: "AXUIElement",
            after: "call local_context next",
            visible: "let ignored = \"SecretValueXYZ987654321\"",
            filenames: ["AutoLearn.swift"]
        )
        XCTAssertTrue(terms.contains { $0.canonical == "AXUIElement" })
        XCTAssertTrue(terms.contains { $0.canonical == "local_context" })
        XCTAssertTrue(terms.contains { $0.canonical == "AutoLearn" })
        XCTAssertFalse(terms.contains { $0.canonical.contains("PrivateToken") })
        XCTAssertFalse(terms.contains { $0.canonical.contains("SecretValue") })
        XCTAssertLessThanOrEqual(terms.count, ContextVocabulary.maximumTerms)

        let selectedLiteral = ContextVocabulary.extract(
            before: "let credential = \"",
            selected: "SelectedSecretName",
            after: "\"\nlet SafeIdentifier = build()"
        )
        XCTAssertFalse(selectedLiteral.contains { $0.canonical == "SelectedSecretName" })
        XCTAssertTrue(selectedLiteral.contains { $0.canonical == "SafeIdentifier" })

        let multiline = ContextVocabulary.extract(visible: """
            let sample = \"\"\"
            HiddenMultilineIdentifier
            \"\"\"
            /* outer /* nested */ HiddenNestedComment */
            let VisibleAfterLiterals = value
            """)
        XCTAssertFalse(multiline.contains { $0.canonical == "HiddenMultilineIdentifier" })
        XCTAssertFalse(multiline.contains { $0.canonical == "HiddenNestedComment" })
        XCTAssertTrue(multiline.contains { $0.canonical == "VisibleAfterLiterals" })

        let inlineComments = ContextVocabulary.extract(
            visible: "x=1#BoundarySecretName\nvalue -- SQLSecretName"
        )
        XCTAssertFalse(inlineComments.contains { $0.canonical == "BoundarySecretName" })
        XCTAssertFalse(inlineComments.contains { $0.canonical == "SQLSecretName" })

        let secretShapes = ContextVocabulary.extract(
            selected: "AKIAIOSFODNN7EXAMPLE AbCdEf12_GhIjKl34_MnOp "
                + "sk_liveSecretToken123 gho_exampleCredential123 "
                + "abcdefghijklmnopqrstuv1x"
        )
        XCTAssertTrue(secretShapes.isEmpty)
        XCTAssertTrue(ContextVocabulary.extract(selected: "ContextVocabulary").contains {
            $0.canonical == "ContextVocabulary"
        })

        let exactResult = ContextVocabulary.rewrite("open auto learn and ax ui element", using: terms)
        XCTAssertEqual(exactResult.text, "open AutoLearn and AXUIElement")
        let fuzzyTerms = [ContextTerm(canonical: "ContextVocabulary",
                                      spokenForms: ["contextvocabulary"], source: .selected)]
        XCTAssertEqual(ContextVocabulary.rewrite("contextvocabularx is ready", using: fuzzyTerms).text,
                       "ContextVocabulary is ready")
        XCTAssertEqual(ContextVocabulary.rewrite("value is ready", using: fuzzyTerms).text,
                       "value is ready")
    }
}
