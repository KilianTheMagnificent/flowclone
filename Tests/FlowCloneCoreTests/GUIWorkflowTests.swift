import XCTest
@testable import FlowCloneCore

final class GUIWorkflowTests: XCTestCase {
    func testSnippetEditorRoundTripsActualNewlines() throws {
        let draft = PersonalizationDraft(kind: .snippet, primary: "my reply", replacement: "Hello,\n\nThanks for your help.")
        let validated = try PersonalizationStore.validated(draft)
        XCTAssertEqual(validated.replacement, draft.replacement)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalizationStore(root: root)
        try store.add(validated, expected: store.snapshot(.snippet).fingerprint)
        XCTAssertEqual(try store.snapshot(.snippet).entries.first?.replacement, draft.replacement)
    }
    func testEditorValidationRejectsEmptyAndInvalidForms() {
        // The existing line format reserves backslash-n. Refuse an ambiguous value
        // instead of displaying a literal sequence that silently saves as a newline.
        XCTAssertThrowsError(try PersonalizationStore.validated(.init(kind: .snippet, primary: "example", replacement: "Use \\n literally")))
        for kind in PersonalizationKind.allCases {
            XCTAssertThrowsError(try PersonalizationStore.validated(.init(kind: kind, primary: "", replacement: "")))
        }
        XCTAssertThrowsError(try PersonalizationStore.validated(.init(kind: .correction, primary: "word", replacement: "two\nlines")))
        XCTAssertThrowsError(try PersonalizationStore.validated(.init(kind: .dictionary, primary: "one -> two", replacement: nil)))
    }
    func testImportReviewDescribesEachChangeAndCannotApplyStalePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalizationStore(root: root)
        try store.add(.init(kind: .correction, primary: "flow", replacement: "FlowClone"), expected: store.snapshot(.correction).fingerprint)
        let preview = try store.previewImport(Data("flow -> Flow\nnew -> New\n".utf8), kind: .correction)
        XCTAssertEqual(preview.rows.map(\.outcome), [.conflict, .addition])
        XCTAssertEqual(preview.rows.first?.previous, "FlowClone")
        try store.add(.init(kind: .correction, primary: "other", replacement: "Other"), expected: store.snapshot(.correction).fingerprint)
        XCTAssertThrowsError(try store.apply(preview, replaceConflicts: true)) { XCTAssertEqual($0 as? PersonalizationError, .stale) }
        XCTAssertEqual(try store.snapshot(.correction).entries.first?.replacement, "FlowClone")
    }
}
