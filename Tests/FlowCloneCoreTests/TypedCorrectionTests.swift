import Foundation
import XCTest
@testable import FlowCloneCore

final class TypedCorrectionTests: XCTestCase {
    private let pasted = "Meet with Andre tomorrow"
    private let edited = "Meet with André tomorrow"

    private func snapshot(_ text: String, prefix: String = "", selection: Int = 0) -> PasteTarget.LearningSnapshot {
        .init(prefix: prefix, text: text, characterCount: text.utf16.count,
              selectionLength: selection)
    }

    func testSettlesWithoutAnotherDictationAndDoesNotRelearnUnchangedText() throws {
        var session = try XCTUnwrap(TypedCorrectionSession(pasted: pasted, baseline: snapshot(pasted), now: 0))
        XCTAssertEqual(session.sample(snapshot(pasted), enabled: true, now: 1), .waiting)
        XCTAssertEqual(session.sample(snapshot("Meet with Andr tomorrow"), enabled: true, now: 2), .waiting)
        XCTAssertEqual(session.sample(snapshot(edited), enabled: true, now: 3), .waiting)
        XCTAssertEqual(session.sample(snapshot(edited), enabled: true, now: 4), .waiting)
        XCTAssertEqual(session.sample(snapshot(edited), enabled: true, now: 5), .ready(edited))
        XCTAssertEqual(session.sample(snapshot(edited), enabled: true, now: 9), .waiting)
    }

    func testNoLearningWhileSelectionIsActive() throws {
        var session = try XCTUnwrap(TypedCorrectionSession(pasted: pasted, baseline: snapshot(pasted), now: 0))
        XCTAssertEqual(session.sample(snapshot(edited, selection: 5), enabled: true, now: 1), .waiting)
        XCTAssertEqual(session.sample(snapshot(edited, selection: 5), enabled: true, now: 4), .waiting)
        XCTAssertEqual(session.sample(snapshot(edited), enabled: true, now: 5), .ready(edited))
    }

    func testDiscardedOnDisabledExpiredOrLostTarget() throws {
        for sample in [snapshot(edited), nil] {
            var disabled = try XCTUnwrap(TypedCorrectionSession(pasted: pasted, baseline: snapshot(pasted), now: 0))
            XCTAssertEqual(disabled.sample(sample, enabled: false, now: 3), .finished)
            var expired = try XCTUnwrap(TypedCorrectionSession(pasted: pasted, baseline: snapshot(pasted), now: 0))
            XCTAssertEqual(expired.sample(sample, enabled: true, now: 600), .finished)
        }
        var lost = try XCTUnwrap(TypedCorrectionSession(pasted: pasted, baseline: snapshot(pasted), now: 0))
        XCTAssertEqual(lost.sample(nil, enabled: true, now: 1), .finished)
    }

    func testSurroundingTextCannotBecomeACorrection() throws {
        let tail = ". Existing prose."
        let baseline = snapshot(pasted + tail, prefix: "Original prefix ")
        var session = try XCTUnwrap(TypedCorrectionSession(pasted: pasted, baseline: baseline, now: 0))
        XCTAssertEqual(session.sample(snapshot(edited + tail, prefix: baseline.prefix), enabled: true, now: 1), .waiting)
        XCTAssertEqual(session.sample(snapshot(edited + tail, prefix: baseline.prefix), enabled: true, now: 3), .ready(edited))
        XCTAssertEqual(session.sample(snapshot(edited + ". Rewritten prose.", prefix: baseline.prefix), enabled: true, now: 4), .finished)
        XCTAssertEqual(session.sample(snapshot(edited + tail, prefix: "Changed prefix "), enabled: true, now: 5), .finished)
        XCTAssertNil(TypedCorrectionSession(pasted: pasted, baseline: snapshot("Other field"), now: 0))
    }

    func testSpellingVersusSemanticEditsAndWordBoundaries() {
        XCTAssertFalse(AutoLearn.isAutomaticSpelling("like", "live", isKnownWord: { _ in true }))
        XCTAssertTrue(AutoLearn.isAutomaticSpelling("Andre", "André", isKnownWord: { _ in true }))
        XCTAssertTrue(AutoLearn.isAutomaticSpelling("flowclone", "FlowClone", isKnownWord: { _ in true }))
        XCTAssertTrue(AutoLearn.isAutomaticSpelling("Kubernets", "Kubernetes", isKnownWord: { _ in false }))
        XCTAssertTrue(AutoLearn.isAutomaticSpelling("open code", "OpenCode", isKnownWord: { _ in true }))
        let merged = AutoLearn.findCorrections(pasted: "Please use open code tomorrow", field: "Please use OpenCode tomorrow")
        XCTAssertEqual(merged.first?.wrong, "open code")
        XCTAssertEqual(merged.first?.right, "OpenCode")
        let split = AutoLearn.findCorrections(pasted: "Please use Opencode tomorrow", field: "Please use Open Code tomorrow")
        XCTAssertEqual(split.first?.right, "Open Code")
        XCTAssertTrue(AutoLearn.findCorrections(pasted: "Please use this code tomorrow", field: "Please use OpenCode tomorrow").isEmpty)
        XCTAssertTrue(AutoLearn.findCorrections(pasted: "Please use open-code tomorrow", field: "Please use OpenCode tomorrow").isEmpty)
        XCTAssertTrue(AutoLearn.findCorrections(pasted: String(repeating: "Longword ", count: 500), field: "Other text").isEmpty)
        XCTAssertEqual(AutoLearn.findCorrections(pasted: "Please use Cubernetes tomorrow", field: "Please use Kubernetes tomorrow").first?.right, "Kubernetes")
    }

    func testAutomaticSavePersistsReloadsAndUndoesWithoutProductionData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-learning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalizationStore(root: root)
        try Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean(pasted), pasted)
            let saved = try XCTUnwrap(AutoLearn.saveCorrections([(wrong: "Andre", right: "André")], store: store))
            XCTAssertEqual(try PersonalizationStore(root: root).snapshot(.correction).entries.first?.replacement, "André")
            XCTAssertEqual(Cleaner.clean(pasted), edited, "next cleanup must reload without restart")
            XCTAssertNil(try AutoLearn.saveCorrections([(wrong: "Andre", right: "André")], store: store))
            XCTAssertNil(try AutoLearn.saveCorrections([(wrong: "Andre", right: "Andrea")], store: store))
            XCTAssertEqual(Cleaner.clean(pasted), edited, "automatic learning cannot overwrite a rule")
            try store.undo(saved.undo)
            XCTAssertEqual(Cleaner.clean(pasted), pasted)
        }
    }

    func testAmbiguousAndMalformedBatchesDoNotWriteAndManualChangesBlockUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-learning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalizationStore(root: root)
        XCTAssertNil(try AutoLearn.saveCorrections([("Andre", "André"), ("ANDRE", "Andrea")], store: store))
        XCTAssertThrowsError(try AutoLearn.saveCorrections([("bad\ntrigger", "value")], store: store))
        XCTAssertTrue(try store.snapshot(.correction).entries.isEmpty)
        let saved = try XCTUnwrap(AutoLearn.saveCorrections([("Andre", "André")], store: store))
        _ = try store.upsertCorrection(wrong: "Kubernets", right: "Kubernetes")
        XCTAssertThrowsError(try store.undo(saved.undo))
        XCTAssertEqual(try store.snapshot(.correction).entries.count, 2)
    }
}
