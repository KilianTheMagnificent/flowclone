import Cocoa
import XCTest
@testable import FlowCloneCore

final class AXTextContextTests: XCTestCase {
    func testSmallFieldFallbackNeverReadsAnUnboundedValue() {
        let source = "A😀 café finish"
        let range = NSRange(source.range(of: "café")!, in: source)
        let wanted = CFRange(location: range.location, length: range.length)
        XCTAssertEqual(AXClient.readTextRange(wanted, readRange: { _ in nil },
            readCount: { source.utf16.count }, readValue: { source }), "café")
        for count: Int? in [nil, -1, 4_097, Int.max] {
            XCTAssertNil(AXClient.readTextRange(wanted, readRange: { _ in nil }, readCount: { count },
                                               readValue: { XCTFail("Unbounded value read"); return source }))
        }
        XCTAssertNil(AXClient.readTextRange(wanted, readRange: { _ in "wrong length" },
                                            readCount: { source.utf16.count }, readValue: { source + "changed" }))
        XCTAssertNil(AXClient.readTextRange(CFRange(location: Int.max, length: 1),
                                            readRange: { _ in XCTFail(); return nil }, readCount: { nil }, readValue: { nil }))
        XCTAssertNil(AXClient.readTextRange(CFRange(location: 2, length: 1), readRange: { _ in nil },
                                            readCount: { source.utf16.count }, readValue: { source }), "Do not split a surrogate pair")
    }

    func testRangeReadAvoidsWholeFieldFallbackAndEmptyMeansKnownBoundary() {
        XCTAssertEqual(AXClient.readTextRange(CFRange(location: 1, length: 3), readRange: { _ in "abc" },
                                              readCount: { XCTFail(); return nil }, readValue: { XCTFail(); return nil }), "abc")
        XCTAssertEqual(AXClient.readTextRange(CFRange(location: 0, length: 0), readRange: { _ in XCTFail(); return nil },
                                              readCount: { XCTFail(); return nil }, readValue: { XCTFail(); return nil }), "")
    }

    func testInsertionSuffixStartsAfterTheEntireSelectionAndStaysBounded() {
        assertRange(AXTextContext.insertionRangeAfter(selection: CFRange(location: 10, length: 500), total: 900, limit: 128),
                    equals: CFRange(location: 510, length: 128))
        assertRange(AXTextContext.insertionRangeAfter(selection: CFRange(location: 10, length: 500), total: 510, limit: 128),
                    equals: CFRange(location: 510, length: 0))
        XCTAssertNil(AXTextContext.insertionRangeAfter(selection: CFRange(location: 10, length: 0), total: nil, limit: 128))
        XCTAssertNil(AXTextContext.insertionRangeAfter(selection: CFRange(location: Int.max, length: 1), total: Int.max, limit: 128))
        XCTAssertNil(AXTextContext.insertionRangeAfter(selection: CFRange(location: -1, length: 0), total: 20, limit: 128))
    }

    func testCaptureRangesAreBoundedAndMalformedInputsAreClamped() {
        let bounded = AXTextContext.captureRanges(
            selection: CFRange(location: 500, length: 900), total: 2_000,
            visible: CFRange(location: 0, length: 2_000)
        )
        assertRange(bounded.before, equals: CFRange(location: 116, length: 384))
        assertRange(bounded.selected, equals: CFRange(location: 500, length: 256))
        assertRange(bounded.after, equals: CFRange(location: 1_400, length: 384))
        XCTAssertEqual(bounded.visible?.length, 1_024)

        let malformed = AXTextContext.captureRanges(
            selection: CFRange(location: -4, length: -8), total: 20,
            visible: CFRange(location: -2, length: 100)
        )
        assertRange(malformed.before, equals: CFRange(location: 0, length: 0))
        assertRange(malformed.selected, equals: CFRange(location: 0, length: 0))
        assertRange(malformed.visible, equals: CFRange(location: 0, length: 20))
    }

    func testVocabularyFragmentsNeverBridgeTruncatedOrFailedReads() {
        let ranges = AXTextContext.captureRanges(
            selection: CFRange(location: 4, length: 400), total: 500,
            visible: CFRange(location: 100, length: 100)
        )
        let truncated = AXTextContext.vocabularyFragments(
            ranges: ranges, fullSelectionLength: 400,
            before: "let ", selected: String(repeating: "s", count: 256),
            after: String(repeating: "a", count: 96),
            visible: String(repeating: "v", count: 100)
        )
        XCTAssertEqual(truncated.before, "let ")
        XCTAssertEqual(truncated.selected.count, 256)
        XCTAssertTrue(truncated.after.isEmpty)
        XCTAssertEqual(truncated.visible.count, 100)

        let failedSelection = AXTextContext.vocabularyFragments(
            ranges: ranges, fullSelectionLength: 400,
            before: "let ", selected: nil,
            after: String(repeating: "a", count: 96), visible: nil
        )
        XCTAssertEqual(failedSelection.before, "let ")
        XCTAssertTrue(failedSelection.selected.isEmpty)
        XCTAssertTrue(failedSelection.after.isEmpty)
    }

    func testVocabularyFragmentsPreserveContextPastLineFourteenAndRejectMismatchedLengths() {
        let deepRanges = AXTextContext.captureRanges(
            selection: CFRange(location: 500, length: 0), total: 1_000,
            visible: CFRange(location: 100, length: 100)
        )
        let deep = AXTextContext.vocabularyFragments(
            ranges: deepRanges, fullSelectionLength: 0,
            before: String(repeating: "b", count: 384), selected: "",
            after: String(repeating: "a", count: 384),
            visible: String(repeating: "v", count: 100)
        )
        XCTAssertEqual(deep.before.count, 384)
        XCTAssertTrue(deep.selected.isEmpty)
        XCTAssertEqual(deep.after.count, 384)
        XCTAssertEqual(deep.visible.count, 100)

        let mismatched = AXTextContext.vocabularyFragments(
            ranges: deepRanges, fullSelectionLength: 0,
            before: "short", selected: "",
            after: "short", visible: "short"
        )
        XCTAssertTrue(mismatched.before.isEmpty)
        XCTAssertTrue(mismatched.after.isEmpty)
        XCTAssertTrue(mismatched.visible.isEmpty)
    }

    func testContinuationRangeIsBoundedAndClamped() {
        assertRange(
            AXTextContext.rangeBeforeCaret(CFRange(location: 500, length: 0), limit: 200),
            equals: CFRange(location: 300, length: 200)
        )
        assertRange(
            AXTextContext.rangeBeforeCaret(CFRange(location: -2, length: 0), limit: 200),
            equals: CFRange(location: 0, length: 0)
        )
    }

    func testSecureTextPolicyFailsClosed() {
        XCTAssertTrue(AXTextContext.isSecure(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(AXTextContext.isSecure(role: "AXTextField",
                                             subrole: "AXSecureTextField"))
        XCTAssertFalse(AXTextContext.isSecure(role: "AXTextArea", subrole: nil))
        XCTAssertFalse(AXTextContext.securityAllowsText(
            role: .failed, subrole: .absent, protectedContent: .absent))
        XCTAssertFalse(AXTextContext.securityAllowsText(
            role: .value("AXTextArea"), subrole: .failed, protectedContent: .absent))
        XCTAssertTrue(AXTextContext.securityAllowsText(
            role: .value("AXTextArea"), subrole: .absent, protectedContent: .absent))
        XCTAssertFalse(AXTextContext.securityAllowsText(
            role: .value("AXTextArea"), subrole: .absent, protectedContent: .value(true)))
        XCTAssertTrue(AXTextContext.securityAllowsText(
            role: .value("AXTextArea"), subrole: .absent, protectedContent: .value(false)))
        XCTAssertTrue(AXTextContext.securityAllowsText(
            role: .value("AXTextArea"), subrole: .absent, protectedContent: .absent))
        XCTAssertFalse(AXTextContext.securityAllowsText(
            role: .value("AXTextArea"), subrole: .absent, protectedContent: .failed))
        XCTAssertFalse(AXTextContext.securityAllowsText(
            role: .timedOut, subrole: .absent, protectedContent: .absent))
    }

    func testCodingApplicationRecognition() {
        XCTAssertTrue(AXTextContext.isCodingApp("com.apple.dt.Xcode"))
        XCTAssertTrue(AXTextContext.isCodingApp("com.jetbrains.intellij"))
    }

    func testDeadlineCapsShrinksAndExpires() {
        var fakeNow = 10.0
        let deadline = AXClient.Deadline(total: 0.100, perCall: 0.050,
                                         clock: { fakeNow })
        XCTAssertTrue(deadline.hasTimeRemaining)
        XCTAssertEqual(deadline.nextTimeout() ?? 0, 0.050, accuracy: 0.000_1)
        fakeNow = 10.075
        XCTAssertTrue(deadline.hasTimeRemaining)
        XCTAssertEqual(deadline.nextTimeout() ?? 0, 0.025, accuracy: 0.000_1)
        fakeNow = 10.100
        XCTAssertFalse(deadline.hasTimeRemaining)
        XCTAssertNil(deadline.nextTimeout())
    }

    func testAbandonedContextStopsFurtherAXMessagesWithoutChangingPasteBudget() {
        var abandoned = false
        let optional = AXClient.Deadline(total: 0.100, isCancelled: { abandoned },
                                         clock: { 10 })
        let mandatory = AXClient.Deadline(total: 0.120, clock: { 10 })
        XCTAssertNotNil(optional.nextTimeout())
        abandoned = true
        XCTAssertFalse(optional.hasTimeRemaining)
        XCTAssertNil(optional.nextTimeout())
        XCTAssertTrue(mandatory.hasTimeRemaining)
        XCTAssertNotNil(mandatory.nextTimeout())
    }

    func testElectronAXRetriesAfterBackoffOnFailureAndDetectsAnyElectronFrameworkApp() throws {
        let suiteName = ScratchDefaults.name("electron-ax-retry")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            AXTextContext.resetElectronAccessibilityCacheForTesting()
        }
        AXTextContext.resetElectronAccessibilityCacheForTesting()

        // Non-coding app bundle containing Electron Framework.framework is detected automatically.
        let fakeApp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeElectron-\(UUID().uuidString).app", isDirectory: true)
        let frameworkDir = fakeApp.appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworkDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeApp) }
        XCTAssertFalse(AXTextContext.isCodingApp("com.example.noncoding.notes"))
        XCTAssertTrue(AXTextContext.isElectronCodingOrChatApp("com.example.noncoding.notes", bundleURL: fakeApp))

        var fakeNow = Date(timeIntervalSince1970: 1_800_000_000)
        var attempts = 0
        var nextResult: AXError = .cannotComplete

        // 1. Timeout/failure must return false and NOT permanently latch as succeeded.
        XCTAssertFalse(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 55_001,
            bundleID: "com.example.noncoding.notes",
            defaults: defaults,
            bundleURLProvider: { _ in fakeApp },
            isProcessAlive: { _ in true },
            now: { fakeNow },
            retryBackoff: 5.0,
            axSetter: { _ in attempts += 1; return nextResult }
        ))
        XCTAssertEqual(attempts, 1)

        // 2. Within the 5s backoff window, does not spam IPC.
        fakeNow = fakeNow.addingTimeInterval(2.0)
        XCTAssertFalse(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 55_001,
            bundleID: "com.example.noncoding.notes",
            defaults: defaults,
            bundleURLProvider: { _ in fakeApp },
            isProcessAlive: { _ in true },
            now: { fakeNow },
            retryBackoff: 5.0,
            axSetter: { _ in attempts += 1; return nextResult }
        ))
        XCTAssertEqual(attempts, 1)

        // 3. After backoff elapses, retries and caches permanently once .success is returned.
        fakeNow = fakeNow.addingTimeInterval(4.0)
        nextResult = .success
        XCTAssertTrue(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 55_001,
            bundleID: "com.example.noncoding.notes",
            defaults: defaults,
            bundleURLProvider: { _ in fakeApp },
            isProcessAlive: { _ in true },
            now: { fakeNow },
            retryBackoff: 5.0,
            axSetter: { _ in attempts += 1; return nextResult }
        ))
        XCTAssertEqual(attempts, 2)

        // 4. Subsequent call after .success stays cached even well past backoff.
        fakeNow = fakeNow.addingTimeInterval(60.0)
        XCTAssertFalse(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 55_001,
            bundleID: "com.example.noncoding.notes",
            defaults: defaults,
            bundleURLProvider: { _ in fakeApp },
            isProcessAlive: { _ in true },
            now: { fakeNow },
            retryBackoff: 5.0,
            axSetter: { _ in attempts += 1; return nextResult }
        ))
        XCTAssertEqual(attempts, 2)
    }

    private func assertRange(_ actual: CFRange?, equals expected: CFRange,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            return XCTFail("expected a range", file: file, line: line)
        }
        XCTAssertEqual(actual.location, expected.location, file: file, line: line)
        XCTAssertEqual(actual.length, expected.length, file: file, line: line)
    }
}
