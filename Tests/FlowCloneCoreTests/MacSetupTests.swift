import FluidAudio
import Network
import ServiceManagement
import XCTest
@testable import FlowCloneCore

final class MacSetupTests: XCTestCase {
    // MARK: Speech model failures

    func testOfflineDownloadIsReportedAsOffline() {
        let error = DownloadError.downloadFailed(path: "x", underlying: URLError(.notConnectedToInternet))
        XCTAssertEqual(SpeechModelProblem.classify(error, freeBytes: 50_000_000_000, needsDownload: true), .offline)
        XCTAssertEqual(SpeechModelProblem.classify(URLError(.networkConnectionLost), freeBytes: nil, needsDownload: true), .offline)
    }

    func testBlockedHostOrSignInPageIsReportedAsUnreachable() {
        let roomy: Int64 = 50_000_000_000
        for error: Error in [
            URLError(.cannotFindHost),
            URLError(.timedOut),
            URLError(.serverCertificateUntrusted),
            DownloadError.htmlErrorResponse(path: "config.json", snippet: "<html>Sign in to Wi-Fi"),
            DownloadError.invalidResponse,
            DownloadError.stalled(path: "x", window: 120),
            DownloadError.downloadFailed(path: "x", underlying: NSError(domain: "x", code: 1)),
        ] {
            XCTAssertEqual(SpeechModelProblem.classify(error, freeBytes: roomy, needsDownload: true),
                           .serverUnreachable, "\(error)")
        }
    }

    func testLowDiskBeatsTheNetworkErrorOnlyWhenADownloadIsNeeded() {
        let error = URLError(.timedOut)
        XCTAssertEqual(SpeechModelProblem.classify(error, freeBytes: 300_000_000, needsDownload: true),
                       .lowDisk(freeBytes: 300_000_000))
        // A model already on disk does not need the space; the real error is reported.
        XCTAssertEqual(SpeechModelProblem.classify(error, freeBytes: 300_000_000, needsDownload: false),
                       .serverUnreachable)
    }

    func testOutOfSpaceErrorsAreLowDiskWhereverTheyAreWrapped() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertEqual(SpeechModelProblem.classify(wrapped, freeBytes: 2_000_000_000, needsDownload: false),
                       .lowDisk(freeBytes: 2_000_000_000))
        let cocoa = CocoaError(.fileWriteOutOfSpace)
        XCTAssertEqual(SpeechModelProblem.classify(DownloadError.downloadFailed(path: "x", underlying: cocoa),
                                                   freeBytes: nil, needsDownload: true),
                       .lowDisk(freeBytes: 0))
    }

    func testThePreflightErrorKeepsItsOwnReason() {
        XCTAssertEqual(SpeechModelProblem.classify(SpeechModelProblem.lowDisk(freeBytes: 5), freeBytes: 9_000_000_000,
                                                   needsDownload: true),
                       .lowDisk(freeBytes: 5))
        XCTAssertEqual(SpeechModelProblem.classify(CocoaError(.fileNoSuchFile), freeBytes: 9_000_000_000,
                                                   needsDownload: true),
                       .other)
    }

    func testOnlyNetworkProblemsRetryByThemselvesAndEveryMessageSaysWhatToDo() {
        XCTAssertTrue(SpeechModelProblem.offline.retriesByItself)
        XCTAssertTrue(SpeechModelProblem.serverUnreachable.retriesByItself)
        XCTAssertFalse(SpeechModelProblem.lowDisk(freeBytes: 1).retriesByItself)
        XCTAssertFalse(SpeechModelProblem.other.retriesByItself)
        XCTAssertTrue(SpeechModelProblem.lowDisk(freeBytes: 400_000_000).message.contains("1 GB"))
        XCTAssertTrue(SpeechModelProblem.serverUnreachable.message.contains("huggingface.co"))
        XCTAssertTrue(Pipeline.speechModelFailureNotice(.offline).contains("offline"))
    }

    func testDownloadProgressLineRoundTrips() {
        let line = SpeechModelStatus.downloadingLine(done: 3, total: 12)
        XCTAssertEqual(SpeechModelStatus.parse(line), .downloading(done: 3, total: 12))
        XCTAssertNil(SpeechModelStatus.parse("ready"))
        XCTAssertNil(SpeechModelStatus.parse("failed"))
        XCTAssertNil(SpeechModelStatus.parse("downloading model 3/0 files"))
        XCTAssertEqual(SpeechModelStatus.parse("downloading model 14/12 files"), .downloading(done: 12, total: 12))
        XCTAssertEqual(SpeechModelStatus.downloading(done: 3, total: 12).shortLabel,
                       "Downloading speech model (3 of 12 files)…")
    }

    func testANetworkRetryNeedsARealReturnToOnline() {
        XCTAssertFalse(SpeechModelStatus.shouldRetry(previous: nil, current: .satisfied),
                       "the monitor's first report must not retry, or a blocked host loops")
        XCTAssertTrue(SpeechModelStatus.shouldRetry(previous: .unsatisfied, current: .satisfied))
        XCTAssertTrue(SpeechModelStatus.shouldRetry(previous: .requiresConnection, current: .satisfied))
        XCTAssertFalse(SpeechModelStatus.shouldRetry(previous: .satisfied, current: .satisfied))
        XCTAssertFalse(SpeechModelStatus.shouldRetry(previous: .satisfied, current: .unsatisfied))
    }

    @MainActor
    func testLateProgressNeverReplacesReady() {
        let state = SpeechModelState.shared
        let before = state.status
        defer { state.set(before) }
        state.set(.ready)
        state.set(.downloading(done: 1, total: 2))
        XCTAssertEqual(state.status, .ready)
        state.set(.failed(.other))
        XCTAssertEqual(state.status, .failed(.other))
    }

    // MARK: Apple Intelligence

    func testEveryUnavailableReasonExplainsTheFallback() {
        let unavailable: [AppleIntelligenceStatus] = [.needsNewerMacOS, .deviceNotEligible, .notEnabled,
                                                      .modelNotReady, .unavailable]
        for status in unavailable {
            XCTAssertFalse(status.isAvailable)
            XCTAssertNotNil(status.consequence, "\(status)")
            XCTAssertTrue(status.transformFailure.hasPrefix("Transforms need Apple Intelligence."), "\(status)")
        }
        XCTAssertNil(AppleIntelligenceStatus.available.consequence)
        XCTAssertEqual(AppleIntelligenceStatus.available.transformFailure, "Couldn’t generate a preview.")
        XCTAssertTrue(AppleIntelligenceStatus.needsNewerMacOS.summary.contains("macOS 26"))
    }

    func testTheKeySkipButtonOnlyPromisesABuiltInModelWhereOneCanExist() {
        XCTAssertEqual(AppleIntelligenceStatus.available.skipKeyButtonTitle, "Use built-in model instead")
        XCTAssertEqual(AppleIntelligenceStatus.notEnabled.skipKeyButtonTitle, "Use built-in model instead")
        XCTAssertEqual(AppleIntelligenceStatus.needsNewerMacOS.skipKeyButtonTitle, "Skip, keep everything on this Mac")
        XCTAssertEqual(AppleIntelligenceStatus.deviceNotEligible.skipKeyButtonTitle, "Skip, keep everything on this Mac")
    }

    func testCurrentStatusMatchesThisMacOS() {
        if #available(macOS 26.0, *) {
            XCTAssertNotEqual(AppleIntelligenceStatus.current, .needsNewerMacOS)
        } else {
            XCTAssertEqual(AppleIntelligenceStatus.current, .needsNewerMacOS)
        }
    }

    // MARK: Open at login

    func testOpenAtLoginDefaultsOnAndFollowsTheSwitch() {
        let suite = ScratchDefaults.name("launch-at-login")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(LaunchAtLogin.wanted(defaults))
        defaults.set(false, forKey: LaunchAtLogin.defaultsKey)
        XCTAssertFalse(LaunchAtLogin.wanted(defaults))
        defaults.set(true, forKey: LaunchAtLogin.defaultsKey)
        XCTAssertTrue(LaunchAtLogin.wanted(defaults))
    }

    func testLoginItemSteps() {
        XCTAssertEqual(LaunchAtLogin.step(wanted: true, status: .notRegistered, translocated: false), .register)
        XCTAssertEqual(LaunchAtLogin.step(wanted: true, status: .notFound, translocated: false), .register)
        XCTAssertEqual(LaunchAtLogin.step(wanted: true, status: .enabled, translocated: false), .nothing)
        // Turned off in System Settings: never re-registered over the person's choice.
        XCTAssertEqual(LaunchAtLogin.step(wanted: true, status: .requiresApproval, translocated: false), .needsApproval)
        XCTAssertEqual(LaunchAtLogin.step(wanted: false, status: .enabled, translocated: false), .unregister)
        XCTAssertEqual(LaunchAtLogin.step(wanted: false, status: .requiresApproval, translocated: false), .unregister)
        XCTAssertEqual(LaunchAtLogin.step(wanted: false, status: .notRegistered, translocated: false), .nothing)
        // A copy run from Downloads would register a path that is gone after a restart.
        XCTAssertEqual(LaunchAtLogin.step(wanted: true, status: .notRegistered, translocated: true), .notFromTemporaryCopy)
    }

    func testLoginItemNotes() {
        XCTAssertNil(LaunchAtLogin.note(wanted: true, status: .enabled, translocated: false))
        XCTAssertNil(LaunchAtLogin.note(wanted: false, status: .requiresApproval, translocated: false))
        XCTAssertTrue(LaunchAtLogin.note(wanted: true, status: .requiresApproval, translocated: false)!
            .contains("Login Items"))
        XCTAssertTrue(LaunchAtLogin.note(wanted: true, status: .notRegistered, translocated: true)!
            .contains("Applications"))
    }

    func testTranslocationIsRecognisedByPath() {
        XCTAssertTrue(LaunchAtLogin.isTranslocated("/private/var/folders/ab/T/AppTranslocation/1234/d/FlowClone.app"))
        XCTAssertFalse(LaunchAtLogin.isTranslocated("/Applications/FlowClone.app"))
        XCTAssertFalse(LaunchAtLogin.isTranslocated("/Users/someone/Applications/FlowClone.app"))
    }

    // MARK: Menu bar icon

    func testMenuBarIconDefaultsOffAndFollowsTheSwitch() {
        let suite = ScratchDefaults.name("menu-bar-icon")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(StatusMenu.showMenuBarIcon(in: defaults))
        defaults.set(true, forKey: StatusMenu.showMenuBarIconKey)
        XCTAssertTrue(StatusMenu.showMenuBarIcon(in: defaults))
        defaults.set(false, forKey: StatusMenu.showMenuBarIconKey)
        XCTAssertFalse(StatusMenu.showMenuBarIcon(in: defaults))
    }

    @MainActor
    func testInstallingStatusMenuWhileHiddenLeavesNoStatusItem() {
        let suite = ScratchDefaults.name("menu-bar-icon-install")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = StatusMenu(defaults: defaults)
        menu.install()
        XCTAssertFalse(menu.isVisible)
        menu.setMenuBarIconVisible(false)
        XCTAssertFalse(menu.isVisible)
    }
}
