import Foundation
import XCTest
@testable import FlowCloneCore

final class PersonalizationAndCleanerTests: XCTestCase {
    private var root: URL!
    private var store: PersonalizationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PersonalizationStore(root: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    private func write(_ text: String, _ filename: String, modifiedAt: Date? = nil) throws {
        let url = root.appendingPathComponent(filename)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt],
                                                  ofItemAtPath: url.path)
        }
    }

    func testCleanerConsumesCanonicalPersonalizationSnapshots() throws {
        try write("FlowClone\nFluidAudio\n", "dictionary.txt")
        try write("ttyl -> talk to you later\nsig -> Andre\\nFlowClone\n", "snippets.txt")
        try write("cooper netties -> Kubernetes\n", "corrections.txt")
        try write("actually\n", "fillers.txt")

        Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean("Actually, cooper netties uses fluid audio."),
                           "Kubernetes uses FluidAudio.")
            XCTAssertEqual(Cleaner.clean("Ttyl."), "talk to you later")
            XCTAssertEqual(Cleaner.clean("Sig."), "Andre\nFlowClone")
        }
    }

    func testCleanerReloadsSnapshotWhenDictionaryMtimeChanges() throws {
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        try write("FlowClone\n", "dictionary.txt", modifiedAt: firstDate)

        try Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean("Use fluid audio."), "Use fluid audio.")
            try write("FlowClone\nFluidAudio\n", "dictionary.txt",
                      modifiedAt: firstDate.addingTimeInterval(10))
            XCTAssertEqual(Cleaner.clean("Use fluid audio."), "Use FluidAudio.")
        }
    }

    func testCorrectionAppendPreservesExistingLineWithoutTrailingNewline() throws {
        try write("Kubernets -> Kubernetes", "corrections.txt")

        let result = try store.upsertCorrection(wrong: "catalist", right: "Catalyst")
        guard case .added = result else {
            return XCTFail("expected a newly added correction")
        }

        let bytes = try String(contentsOf: root.appendingPathComponent("corrections.txt"),
                               encoding: .utf8)
        XCTAssertEqual(bytes, "Kubernets -> Kubernetes\ncatalist -> Catalyst\n")
        let snapshot = try store.snapshot(.correction)
        XCTAssertEqual(snapshot.entries.map(\.primary), ["Kubernets", "catalist"])
    }

    func testStaleFingerprintRefusesMutation() throws {
        try write("FlowClone\n", "dictionary.txt")
        let snapshot = try store.snapshot(.dictionary)
        try write("FlowClone\nFluidAudio\n", "dictionary.txt")

        XCTAssertThrowsError(
            try store.add(PersonalizationDraft(kind: .dictionary,
                                               primary: "Parakeet", replacement: nil),
                          expected: snapshot.fingerprint)
        ) { error in
            XCTAssertEqual(error as? PersonalizationError, .stale)
        }
    }
}
