import ApplicationServices
import XCTest
@testable import FlowCloneCore

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func write(_ newValue: Value) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

final class TargetSafetyTests: XCTestCase {
    func testMissingPhysicalBoundaryAppCompletesAsRefused() {
        let lease = Paster.beginTargetCaptureAtPhysicalEventBoundary(
            app: nil)
        let resolved = expectation(description: "missing boundary app resolves immediately")

        Paster.resolveTargetCapture(lease) { result in
            if case .refused = result { resolved.fulfill() }
        }

        wait(for: [resolved], timeout: 0.1)
    }

    func testBoundaryAppCannotMoveToProgrammaticallyActivatedApp() {
        let appA = PasteTarget.AppIdentity(bundleID: "com.example.A", pid: 101)
        let appB = PasteTarget.AppIdentity(bundleID: "com.example.B", pid: 202)

        XCTAssertTrue(PasteTarget.AppIdentity.matchesBoundary(appA, current: appA))
        XCTAssertFalse(PasteTarget.AppIdentity.matchesBoundary(appA, current: appB),
                       "the worker must not bind whichever app became frontmost later")
        XCTAssertFalse(PasteTarget.AppIdentity.matchesBoundary(appA, current: nil))
    }

    func testSameAppFieldIdentityCannotMoveFromAToB() {
        let anchor: PasteTarget.FieldAnchor<String> = .exact("field-a")

        XCTAssertEqual(
            PasteTarget.identityDecision(anchor: anchor,
                                         observation: .element("field-a")),
            .exactMatch)
        XCTAssertEqual(
            PasteTarget.identityDecision(anchor: anchor,
                                         observation: .element("field-b")),
            .fieldChanged)
    }

    func testSecureBoundaryCannotBeDowngradedByLaterOrdinaryField() {
        let anchor: PasteTarget.FieldAnchor<String> = .secure

        XCTAssertEqual(
            PasteTarget.identityDecision(anchor: anchor,
                                         observation: .element("ordinary-field-b")),
            .secure)
        XCTAssertEqual(
            PasteTarget.identityDecision(anchor: anchor, observation: .unavailable),
            .secure)
    }

    func testAppOnlyFallbackRequiresExplicitAXUnavailability() {
        let anchor: PasteTarget.FieldAnchor<String> = .appOnly

        XCTAssertEqual(PasteTarget.identityDecision(anchor: anchor,
                                                     observation: .unavailable),
                       .appOnlyMatch)
        XCTAssertEqual(PasteTarget.identityDecision(anchor: anchor,
                                                     observation: .timedOut),
                       .unresponsive)
        XCTAssertEqual(PasteTarget.identityDecision(anchor: anchor,
                                                     observation: .element("field")),
                       .fieldChanged)
        XCTAssertTrue(PasteTarget.appOnlyInteractionIsValid(capturedEpoch: 7,
                                                            currentEpoch: 7))
        XCTAssertFalse(PasteTarget.appOnlyInteractionIsValid(capturedEpoch: 7,
                                                             currentEpoch: 8),
                       "AX-blind targets cannot prove focus survived later physical input")
    }

    /// 2026-11-08: Electron/PowerPoint re-renders and terminal output replaced the editor's
    /// AX element or moved its caret mid-dictation, and the strict pin refused the paste.
    func testPasteFollowsAppDrivenEditorChangeOnlyWithoutPhysicalInput() {
        func follows(_ strict: PasteTarget.Validation, exact: Bool = true,
                     epochs: (UInt64, UInt64) = (7, 7)) -> Bool {
            PasteTarget.mayFollowAppDrivenChange(strict, anchorIsExact: exact,
                                                 capturedEpoch: epochs.0, currentEpoch: epochs.1)
        }
        XCTAssertTrue(follows(.fieldChanged), "re-rendered composer, no key or click")
        XCTAssertTrue(follows(.selectionChanged), "caret moved by terminal output")
        XCTAssertTrue(follows(.selectionUnavailable))

        XCTAssertFalse(follows(.fieldChanged, epochs: (7, 8)),
                       "a key or click since the press may have moved focus: still refused")
        XCTAssertFalse(follows(.selectionChanged, epochs: (7, 8)))
        XCTAssertFalse(follows(.fieldChanged, exact: false),
                       "an AX-blind capture has no editor to follow")
        XCTAssertFalse(follows(.appChanged))
        XCTAssertFalse(follows(.secureField))
        XCTAssertFalse(follows(.appUnresponsive))
        XCTAssertFalse(follows(.fieldUnavailable))
        XCTAssertFalse(follows(.valid(nil)), "nothing to follow when strict validation passes")
    }

    func testPriorStalledLeaseCannotDelayNewCapture() {
        let executor = Paster.TargetCaptureExecutor(
            label: "TargetSafetyTests.concurrent", maximumConcurrent: 2)
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let secondResult = LockedBox<String?>(nil)

        executor.submit(acceptedEpoch: 1, currentEpoch: { 1 }, capture: {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 1)
            return "first"
        }, done: { _ in firstDone.signal() })
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)

        executor.submit(acceptedEpoch: 1, currentEpoch: { 1 }, capture: {
            "second"
        }, done: { value in
            secondResult.write(value)
            secondDone.signal()
        })
        let secondFinishedWithoutFirst = secondDone.wait(timeout: .now() + 0.5)
        releaseFirst.signal()
        _ = firstDone.wait(timeout: .now() + 1)

        XCTAssertEqual(secondFinishedWithoutFirst, .success,
                       "a prior stalled AX call must not serialize a new physical action")
        XCTAssertEqual(secondResult.read(), "second")
    }

    func testInteractionEpochChangeDuringCaptureRefusesPostSwitchAnswer() {
        let executor = Paster.TargetCaptureExecutor(
            label: "TargetSafetyTests.epoch-change", maximumConcurrent: 2)
        let epoch = LockedBox<UInt64>(11)
        let captureStarted = DispatchSemaphore(value: 0)
        let continueCapture = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox<String?>("not-completed")

        executor.submit(acceptedEpoch: 11, currentEpoch: { epoch.read() }, capture: {
            captureStarted.signal()
            _ = continueCapture.wait(timeout: .now() + 1)
            return "post-switch-field-b"
        }, done: { value in
            result.write(value)
            done.signal()
        })
        XCTAssertEqual(captureStarted.wait(timeout: .now() + 1), .success)
        epoch.write(12)
        continueCapture.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertNil(result.read(), "the post-input AX answer must be refused")
    }

    func testUnchangedInteractionEpochAcceptsCapture() {
        let executor = Paster.TargetCaptureExecutor(
            label: "TargetSafetyTests.epoch-stable", maximumConcurrent: 1)
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox<String?>(nil)

        executor.submit(acceptedEpoch: 21, currentEpoch: { 21 }, capture: {
            "field-a"
        }, done: { value in
            result.write(value)
            done.signal()
        })
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.read(), "field-a")
    }

    func testTapResetInvalidatesAppOnlyLeaseEpoch() {
        let captured = FocusInteractionEpoch.snapshot()

        HotkeyMonitor.invalidateTargetCapturesForTapReset()

        let current = FocusInteractionEpoch.snapshot()
        XCTAssertNotEqual(current, captured)
        XCTAssertFalse(PasteTarget.appOnlyInteractionIsValid(capturedEpoch: captured,
                                                             currentEpoch: current))
    }

    func testFocusedElementErrorMappingFailsClosed() {
        XCTAssertEqual(AXClient.focusReadDisposition(error: .success, hasElement: true),
                       .element)
        XCTAssertEqual(AXClient.focusReadDisposition(error: .noValue, hasElement: false),
                       .unavailable)
        XCTAssertEqual(AXClient.focusReadDisposition(error: .attributeUnsupported,
                                                      hasElement: false),
                       .unavailable)

        XCTAssertEqual(AXClient.focusReadDisposition(error: .cannotComplete,
                                                      hasElement: false),
                       .unresponsive)
        XCTAssertEqual(AXClient.focusReadDisposition(error: .failure, hasElement: false),
                       .unresponsive)
        XCTAssertEqual(AXClient.focusReadDisposition(error: .success, hasElement: false),
                       .unresponsive,
                       "a malformed success must not become an app-only target")
    }

    func testClipboardPreservationReportsActualRestoreOutcome() {
        let insertion = PasteTarget.ConfirmedInsertion(location: 3, length: 4)
        let confirmed = Paster.Acknowledgement.targetConfirmed(insertion)

        XCTAssertTrue(Paster.reportedClipboardPreservation(
            confirmed, snapshotAvailable: true, restoreSucceeded: true))
        XCTAssertFalse(Paster.reportedClipboardPreservation(
            confirmed, snapshotAvailable: true, restoreSucceeded: false))
        XCTAssertFalse(Paster.reportedClipboardPreservation(
            confirmed, snapshotAvailable: false, restoreSucceeded: true))
        XCTAssertFalse(Paster.reportedClipboardPreservation(
            .clipboardConsumed, snapshotAvailable: true, restoreSucceeded: true),
            "without a scheduled delayed restore, weak acknowledgement reports unpreserved")
        XCTAssertTrue(Paster.reportedClipboardPreservation(
            .clipboardConsumed, snapshotAvailable: true, restoreSucceeded: false,
            delayedRestoreScheduled: true),
            "a weak acknowledgement with a changeCount-guarded delayed restore preserves clipboard")
    }

    func testPasteTargetIsSecureReflectsAnchorAndSecureInputState() {
        defer { AXClient.setSecureInputProviderForTesting(nil) }
        AXClient.setSecureInputProviderForTesting { false }

        let secureAnchor = PasteTarget.secureTargetForTesting()
        let ordinaryAnchor = PasteTarget.appOnlyTargetForTesting()
        XCTAssertTrue(secureAnchor.isSecure, "Sticky .secure anchor must always report isSecure")
        XCTAssertFalse(ordinaryAnchor.isSecure)

        AXClient.setSecureInputProviderForTesting { true }
        XCTAssertTrue(ordinaryAnchor.isSecure, "Global secure event input must immediately mark any target secure")
    }

    func testPipelineRefusesCaptureOnDownWhenSecureInputOrSecureTargetIsActive() {
        defer { AXClient.setSecureInputProviderForTesting(nil) }
        let runtime = SpeechRuntime(chunkDecodeOverride: { _, _ in
            XCTFail("ASR must never run when hotkey .down is refused on a secure field")
            return .failed(attempts: 1)
        })
        let pipeline = Pipeline(runtime: runtime)
        pipeline.suppressOverlayForTest = true
        pipeline.suppressNotificationsForTest = true
        pipeline.suppressPersistenceForTest = true
        pipeline.setReadyForTest(true)

        let primes = LockedBox(0)
        let opens = LockedBox(0)
        let cues = LockedBox(0)
        let notices = LockedBox<[(String, String?)]>([])
        pipeline.primeOverrideForTest = { done in
            primes.write(primes.read() + 1)
            done(true, false)
        }
        pipeline.beginCaptureOverrideForTest = { _, _, done in
            opens.write(opens.read() + 1)
            done(true)
        }
        pipeline.startCueHandler = { cues.write(cues.read() + 1) }
        pipeline.mediaPauseBeganHandler = { cues.write(cues.read() + 1) }
        pipeline.notificationObserverForTest = { msg, copyText in
            notices.write(notices.read() + [(msg, copyText)])
        }

        // 1. AXClient.isSecureInputEnabled() == true refuses immediately on .down.
        AXClient.setSecureInputProviderForTesting { true }
        let firstRefused = expectation(description: "secure input refused on down")
        pipeline.queue.async {
            pipeline.handle(.down("fn"))
            firstRefused.fulfill()
        }
        wait(for: [firstRefused], timeout: 1.0)
        XCTAssertFalse(pipeline.sessionStateForTest.captureActive)
        XCTAssertEqual(primes.read(), 0)
        XCTAssertEqual(opens.read(), 0)
        XCTAssertEqual(cues.read(), 0)

        // 2. PasteTarget .secure password field refuses immediately on .down even when secure event input is false.
        AXClient.setSecureInputProviderForTesting { false }
        pipeline.resolveTargetOverrideForTest = { _, done in
            done(.secureTargetForTesting())
        }
        let secondRefused = expectation(description: "secure PasteTarget refused on down")
        pipeline.queue.async {
            pipeline.handle(.down("fn"))
            secondRefused.fulfill()
        }
        wait(for: [secondRefused], timeout: 1.0)
        XCTAssertFalse(pipeline.sessionStateForTest.captureActive)
        XCTAssertEqual(primes.read(), 0)
        XCTAssertEqual(opens.read(), 0)
        XCTAssertEqual(cues.read(), 0)
        XCTAssertEqual(notices.read().count, 2)
        XCTAssertTrue(notices.read().allSatisfy { $0.1 == nil }, "Secure refusal must never attach copyText")
    }

    @MainActor
    func testPipelineDeliverDiscardsSecretTranscriptBeforeCloudReviewHistoryOrDraft() throws {
        defer { AXClient.setSecureInputProviderForTesting(nil) }
        AXClient.setSecureInputProviderForTesting { false }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("secure-deliver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let savedHistoryURL = History.storeURL
        let savedHistoryDefaults = History.defaults
        let suiteName = ScratchDefaults.name("secure-deliver")
        History.defaults = UserDefaults(suiteName: suiteName)!
        History.storeURL = tempRoot.appendingPathComponent("history.jsonl")
        History.reload()
        let savedModeOverride = Mode.testOverride
        Mode.testOverride = .clean
        let priorDraft = DictationWorkspace.shared.draft
        defer {
            Mode.testOverride = savedModeOverride
            History.flush()
            History.storeURL = savedHistoryURL
            History.defaults.removePersistentDomain(forName: suiteName)
            History.defaults = savedHistoryDefaults
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let roomPad = [Float](repeating: 0.0005, count: 2_400)
        let speech = roomPad + (0..<8_000).map { Float(sin(Double($0) * 0.22)) * 0.25 } + roomPad
        let secureDuringASR = LockedBox(false)

        let runtime = SpeechRuntime(chunkDecodeOverride: { _, _ in
            if secureDuringASR.read() {
                AXClient.setSecureInputProviderForTesting { true }
            }
            // Self-repair phrase that would normally trigger RepairReviewer.review if not blocked first!
            return .success(text: "correct horse battery wait no staple", attempts: 1)
        })
        let pipeline = Pipeline(runtime: runtime)
        pipeline.suppressOverlayForTest = true
        pipeline.suppressNotificationsForTest = true
        pipeline.suppressPersistenceForTest = false
        pipeline.setReadyForTest(true)
        pipeline.startCueHandler = {}
        pipeline.processingCueHandler = {}
        pipeline.mediaPauseBeganHandler = {}
        pipeline.mediaPauseEndedHandler = {}
        pipeline.primeOverrideForTest = { done in pipeline.queue.async { done(true, false) } }
        pipeline.beginCaptureOverrideForTest = { _, _, done in pipeline.queue.async { done(true) } }
        pipeline.endCaptureOverrideForTest = { _ in speech }

        let pasted = LockedBox<[String]>([])
        let notices = LockedBox<[(String, String?)]>([])
        pipeline.pasteOverrideForTest = { text, finish in
            pasted.write(pasted.read() + [text])
            finish()
        }
        // Each case settles when the pipeline announces the refusal, not after a fixed delay.
        let blockedNotice = LockedBox<XCTestExpectation?>(nil)
        pipeline.notificationObserverForTest = { msg, copyText in
            notices.write(notices.read() + [(msg, copyText)])
            if msg.contains("blocked in password and secure fields") { blockedNotice.read()?.fulfill() }
        }
        // After the refusal, let the session queue and then the main queue drain, so anything
        // the delivery had scheduled (History, Draft) has run before the assertions.
        func settle(_ name: String) {
            let settled = expectation(description: name)
            pipeline.queue.async { DispatchQueue.main.async { settled.fulfill() } }
            wait(for: [settled], timeout: 2.0)
        }

        // Case A: User switched into a secure field during speech/ASR (`AXClient.isSecureInputEnabled()` turns true).
        pipeline.resolveTargetOverrideForTest = { _, done in
            done(.appOnlyTargetForTesting())
        }
        secureDuringASR.write(true)

        let blockedA = expectation(description: "delivery A refused")
        blockedA.assertForOverFulfill = false
        blockedNotice.write(blockedA)
        pipeline.queue.async { pipeline.handle(.down("fn")) }
        pipeline.queue.asyncAfter(deadline: .now() + 0.02) { pipeline.handle(.up) }
        wait(for: [blockedA], timeout: 5.0)
        settle("delivery A settled")

        XCTAssertFalse(pipeline.sessionStateForTest.isBusy)
        XCTAssertTrue(pasted.read().isEmpty, "Must never paste into or after secure input")
        XCTAssertTrue(notices.read().allSatisfy { $0.1 == nil }, "Must never expose transcript via HUD copyText")

        // Case B: Target itself reports `.secure` at finalization even after global secure input clears.
        AXClient.setSecureInputProviderForTesting { false }
        secureDuringASR.write(false)
        let allowDown = LockedBox(true)
        pipeline.resolveTargetOverrideForTest = { _, done in
            if allowDown.read() {
                done(.appOnlyTargetForTesting())
            } else {
                done(.secureTargetForTesting())
            }
        }
        let blockedB = expectation(description: "delivery B refused")
        blockedB.assertForOverFulfill = false
        blockedNotice.write(blockedB)
        pipeline.queue.async {
            pipeline.handle(.down("fn"))
            allowDown.write(false)
        }
        pipeline.queue.asyncAfter(deadline: .now() + 0.02) { pipeline.handle(.up) }
        wait(for: [blockedB], timeout: 5.0)
        settle("delivery B settled")
        XCTAssertFalse(pipeline.sessionStateForTest.isBusy)

        History.flush()
        History.reload()
        XCTAssertTrue(History.items.isEmpty, "Secure field transcript/audio must never be committed to History")
        XCTAssertFalse(FileManager.default.fileExists(atPath: History.storeURL.path))
        XCTAssertEqual(DictationWorkspace.shared.draft, priorDraft, "Secure field transcript must never be copied to draft")
        XCTAssertTrue(pasted.read().isEmpty)
        XCTAssertTrue(notices.read().allSatisfy { $0.1 == nil })
    }
}
