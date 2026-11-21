import Foundation
import XCTest
@testable import FlowCloneCore

final class PersonalizationStoreSelfCheckTests: XCTestCase {
    func testPersonalizationStoreFixtures() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-personalization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initial = "# keep this comment\nFlowClone\n"
        try Data(initial.utf8).write(to: root.appendingPathComponent("dictionary.txt"))
        let store = PersonalizationStore(root: root)
        let first = try store.snapshot(.dictionary)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.ignoredLineCount, 0)

        let undo = try store.add(PersonalizationDraft(kind: .dictionary,
                                                      primary: "Context Vocabulary",
                                                      replacement: nil),
                                 expected: first.fingerprint)
        let second = try store.snapshot(.dictionary)
        XCTAssertTrue(second.entries.contains { $0.primary == "Context Vocabulary" })
        let bytes = try String(contentsOf: root.appendingPathComponent("dictionary.txt"),
                               encoding: .utf8)
        XCTAssertTrue(bytes.hasPrefix("# keep this comment\nFlowClone\n"))
        try store.undo(undo)
        let restored = try Data(contentsOf: root.appendingPathComponent("dictionary.txt"))
        XCTAssertEqual(restored, Data(initial.utf8))

        let importData = Data("sig -> Andre\\nFlowClone\nsig -> Andre\\nFlowClone\nhello -> world\n".utf8)
        let preview = try store.previewImport(importData, kind: .snippet)
        XCTAssertEqual(preview.addedCount, 2)
        XCTAssertEqual(preview.duplicateCount, 1)
        let importUndo = try store.apply(preview, replaceConflicts: false)
        let snippets = try store.snapshot(.snippet)
        XCTAssertEqual(snippets.entries.count, 2)
        XCTAssertEqual(snippets.entries.first(where: { $0.primary == "sig" })?.replacement,
                       "Andre\nFlowClone")

        let stale = snippets
        _ = try store.add(PersonalizationDraft(kind: .snippet, primary: "new trigger",
                                               replacement: "body"), expected: stale.fingerprint)
        XCTAssertThrowsError(try store.undo(importUndo)) { error in
            XCTAssertEqual(error as? PersonalizationError, .stale)
        }

        XCTAssertThrowsError(
            try store.previewImport(Data("same -> first\nsame -> second\n".utf8),
                                    kind: .correction)
        ) { error in
            XCTAssertEqual(error as? PersonalizationError, .ambiguousImport)
        }

        let correction = try store.upsertCorrection(wrong: "catalist", right: "Catalyst")
        XCTAssertNotNil(correction.undoToken)
        let replaced = try store.upsertCorrection(wrong: "catalist", right: "CatalystType")
        XCTAssertNotNil(replaced.undoToken)
        let unchanged = try store.upsertCorrection(wrong: "CATALIST", right: "CatalystType")
        guard case .unchanged = unchanged else {
            return XCTFail("spoken duplicate changed the correction")
        }

        // Simulate a legacy installation and prove both migration and future writes are
        // private without inspecting any file contents outside this scratch directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: root.path)
        let dictionaryURL = root.appendingPathComponent("dictionary.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: dictionaryURL.path)
        XCTAssertTrue(store.hardenPermissions())
        let rootMode = (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                        as? NSNumber)?.intValue
        let fileMode = (try FileManager.default.attributesOfItem(atPath: dictionaryURL.path)[.posixPermissions]
                        as? NSNumber)?.intValue
        XCTAssertEqual(rootMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }
}
