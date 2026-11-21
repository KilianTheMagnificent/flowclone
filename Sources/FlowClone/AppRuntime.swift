// FlowClone Phase 1 — menu-bar dictation app: hold fn (or Ctrl+Opt) → speak → paste.
import Cocoa
import AVFoundation
import CryptoKit
import Darwin
import IOKit.hid
import ServiceManagement

// MARK: - Launch arguments

/// Value of a `--flag value` launch argument; nil when absent or unpaired. A value that
/// itself looks like a flag is treated as absent, so a typo'd `--sink --runid x` cannot
/// silently arm a guard with the wrong string.
func launchArgValue(_ flag: String) -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    return v.hasPrefix("--") ? nil : v
}

func sanitizedRunID(_ runID: String) -> String {
    runID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
}

/// Backend diagnostics are not guaranteed to be metadata-only: an error description may
/// echo the request that caused it. Keep the stable error kind and shape by default, and
/// reveal the backend-provided detail only under the same explicit transcript opt-in.
func diagnosticErrorSummary(type: String, detail: String,
                            includeDetail: Bool = logTranscriptsEnabled()) -> String {
    includeDetail ? "\(type): \(detail)" : "\(type) (\(detail.count) chars)"
}

/// X3/A-7: `--sink <bundle-id>` pins where a measured run is allowed to paste. Resolved
/// once here — nil on every normal launch, which leaves the paste path exactly as it was.
let pasteSink = launchArgValue("--sink")

// MARK: - Logger

let logURL = logFileURL(home: FileManager.default.homeDirectoryForCurrentUser,
                        temporary: FileManager.default.temporaryDirectory,
                        underTest: NSClassFromString("XCTestCase") != nil
                            || ProcessInfo.processInfo.processName == "xctest")

/// Unit tests log beside their scratch files, never into the owner's log: every
/// `build.sh check` used to append fixture lines ("updater: FAILED retry", "previous app
/// could not be verified") to ~/Library/Logs/FlowClone.log, indistinguishable from the
/// installed app's own failures.
func logFileURL(home: URL, temporary: URL, underTest: Bool) -> URL {
    underTest ? temporary.appendingPathComponent("FlowClone-tests.log")
              : home.appendingPathComponent("Library/Logs/FlowClone.log")
}

private let logQueue = DispatchQueue(label: "com.andre.flowclone.log")
private let maximumLogSize: UInt64 = 5_000_000

enum SecureLogFileError: Error {
    case notRegular(URL)
    case pathChanged(URL)
    case systemCall(String, Int32)
}

/// Opens and rotates logs without ever following the leaf pathname. Validation and chmod
/// happen on the opened descriptor, closing the check-then-open gap that would let an
/// existing `FlowClone.log` symlink redirect transcript metadata into another file.
enum SecureLogFile {
    private static let privatePermissions = mode_t(0o600)

    static func open(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            privatePermissions
        )
        guard descriptor >= 0 else {
            throw SecureLogFileError.systemCall("open", errno)
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SecureLogFileError.systemCall("fstat", code)
        }
        guard isRegular(info) else {
            Darwin.close(descriptor)
            throw SecureLogFileError.notRegular(url)
        }
        guard Darwin.fchmod(descriptor, privatePermissions) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SecureLogFileError.systemCall("fchmod", code)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Rotates only the regular file held by `handle`. The lstat identity check prevents a
    /// stale descriptor from authorizing a different pathname; `rename` itself never follows
    /// either leaf, so even a last-moment replacement cannot mutate a symlink target.
    static func rotateIfNeeded(at url: URL, maximumSize: UInt64,
                               handle: inout FileHandle?) throws {
        guard let current = handle else { return }
        let descriptor = current.fileDescriptor
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            throw SecureLogFileError.systemCall("fstat", errno)
        }
        guard isRegular(opened) else { throw SecureLogFileError.notRegular(url) }
        guard opened.st_size >= 0, UInt64(opened.st_size) > maximumSize else { return }

        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0 else {
            throw SecureLogFileError.systemCall("lstat", errno)
        }
        guard isRegular(pathInfo) else { throw SecureLogFileError.notRegular(url) }
        guard pathInfo.st_dev == opened.st_dev, pathInfo.st_ino == opened.st_ino else {
            throw SecureLogFileError.pathChanged(url)
        }

        let rotated = url.appendingPathExtension("1")
        var rotatedInfo = stat()
        if Darwin.lstat(rotated.path, &rotatedInfo) == 0 {
            guard isRegular(rotatedInfo) else {
                throw SecureLogFileError.notRegular(rotated)
            }
        } else if errno != ENOENT {
            throw SecureLogFileError.systemCall("lstat", errno)
        }

        try current.synchronize()
        guard Darwin.fchmod(descriptor, privatePermissions) == 0 else {
            throw SecureLogFileError.systemCall("fchmod", errno)
        }
        guard Darwin.rename(url.path, rotated.path) == 0 else {
            throw SecureLogFileError.systemCall("rename", errno)
        }
        // The descriptor still names the just-rotated inode. Reassert its final mode after
        // the rename, then replace the queue-owned handle with a fresh private active log.
        guard Darwin.fchmod(descriptor, privatePermissions) == 0 else {
            let code = errno
            try? current.close()
            handle = nil
            throw SecureLogFileError.systemCall("fchmod", code)
        }
        try? current.close()
        handle = nil
        handle = try open(at: url)
    }

    private static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }
}

/// Mutable logger resources are owned by `logQueue`. Keeping them in one Sendable
/// reference makes that ownership explicit and avoids unsynchronized global variables.
private final class LoggerState: @unchecked Sendable {
    let stamp: DateFormatter
    var handle: FileHandle?
    var unsynchronizedWrites = 0

    init() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.stamp = stamp
    }
}

private let loggerState = LoggerState()

/// Opens the one process-long handle. Every call is confined to `logQueue`.
private func openLogHandle() {
    dispatchPrecondition(condition: .onQueue(logQueue))
    guard loggerState.handle == nil else { return }
    loggerState.handle = try? SecureLogFile.open(at: logURL)
}

/// Rotates the active log while preserving the queue-owned handle and private permissions.
private func rotateLogIfNeeded() {
    dispatchPrecondition(condition: .onQueue(logQueue))
    try? SecureLogFile.rotateIfNeeded(at: logURL, maximumSize: maximumLogSize,
                                      handle: &loggerState.handle)
}

/// Cheap at the call site (event-tap safe): timestamp now, format + write off-thread.
func log(_ msg: String) {
    let now = Date()
    logQueue.async {
        let line = "\(loggerState.stamp.string(from: now)) \(msg)\n"
        let data = Data(line.utf8)
        try? FileHandle.standardOutput.write(contentsOf: data)
        openLogHandle()
        try? loggerState.handle?.write(contentsOf: data)
        loggerState.unsynchronizedWrites += 1
        if loggerState.unsynchronizedWrites >= 32 {
            try? loggerState.handle?.synchronize()
            loggerState.unsynchronizedWrites = 0
            rotateLogIfNeeded()
        }
    }
}

/// redteam H1: full transcript/field bodies are logged ONLY when explicitly opted in
/// (`defaults write com.andre.flowclone logTranscripts -bool true`). Absent = off, the
/// opposite of autoLearn's absent = on — content retention must be a conscious choice.
func logTranscriptsEnabled() -> Bool { UserDefaults.standard.bool(forKey: "logTranscripts") }

/// redteam H1: log a content body only under the opt-in, otherwise just its shape.
func logBody(_ label: String, _ body: String) {
    log(logTranscriptsEnabled() ? "\(label): \(body)" : "\(label): \(body.count) chars")
}

/// redteam H1: cap the log at ~5MB (rotate to .log.1) and enforce 0600 on every launch.
/// 0600 is defense-in-depth on top of not writing bodies by default.
func setupLog() {
    logQueue.sync {
        try? loggerState.handle?.close()
        loggerState.handle = nil
        loggerState.unsynchronizedWrites = 0
        openLogHandle()
        rotateLogIfNeeded()
    }
}

/// X3: identifies the binary that is actually running. `test.sh` compares this against
/// `shasum -a 256` of the installed bundle's executable, so a stale or unexpected copy
/// can never false-green a suite. Mapped read: the hash is computed once, at launch.
func executableSHA256Prefix() -> String {
    guard let url = Bundle.main.executableURL,
          let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unknown" }
    return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
}

// MARK: - Toast

@MainActor
enum UserNoticeRouter {
    /// Captures the latest routed HUD notice in unit tests without popping WindowServer panels.
    static var lastRoutedNotice: (body: String, copyText: String?)?
    static var testSink: (@MainActor (String, String?) -> Void)?
}

func shouldAttachLatestHistoryCopy(toNotice body: String) -> Bool {
    let lower = body.lowercased()
    return lower.contains("couldn't paste")
        || lower.contains("paste could not be confirmed")
        || lower.contains("paste stopped")
        || lower.contains("text is in history")
        || lower.contains("remains in flowclone history")
}

/// User-visible recovery/failure feedback routed to the non-activating Pill HUD banner
/// instead of silent provisional UNUserNotificationCenter alerts.
func notifyUser(_ body: String) {
    notifyUser(body, copyText: nil)
}

func notifyUser(_ body: String, copyText: String?) {
    if handsfreeSession { Handsfree.log("blocked notification: \(body)"); return }
    log("notice: \(body.count) chars")
    let isUnitTest = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.processName == "xctest"
    let deliver: @MainActor () -> Void = {
        let resolvedCopy = copyText
            ?? (shouldAttachLatestHistoryCopy(toNotice: body) ? History.items.first?.final : nil)
        UserNoticeRouter.lastRoutedNotice = (body, resolvedCopy)
        if let sink = UserNoticeRouter.testSink {
            sink(body, resolvedCopy)
            return
        }
        guard !isUnitTest else { return }
        Overlay.shared.showRecoveryNotice(body, copyText: resolvedCopy)
    }
    if Thread.isMainThread {
        MainActor.assumeIsolated { deliver() }
    } else {
        Task { @MainActor in deliver() }
    }
}

// MARK: - Permission status names

func micStatusName() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func hidAccessName() -> String {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied: return "denied"
    default: return "unknown"
    }
}

// MARK: - App

/// Shared launch policy keeps headless diagnostics and login startup from opening the
/// library or stealing an editor's focus. Normal launches use a Dock-visible Mac app.
enum AppLaunchPolicy {
    static let standaloneProbeFlags: Set<String> = [
            "--promptkeepprobe", "--promptdump",
            "--pastertest", "--transformtest", "--recordertest", "--pilltest", "--overlaytest",
            "--overlaystress", "--polishtest", "--prompttest", "--menutest", "--micdiag",
            "--recorderdiag", "--updatetest", "--pastelatencytest", "--miclatencytest",
            "--contextlatencytest", "--learntest", "--insertiontest",
            "--streaming-asr-test",
        ]

    /// DEBUG offscreen renders (ThemePreviewLaunch) never show a window, so no Dock icon either.
    static func isOffscreenRender(_ args: [String]) -> Bool {
        args.contains("--theme-preview")
            && args.contains(where: ["--review-render", "--voice-render", "--theme-render"].contains)
    }

    static func isProbe(_ args: [String]) -> Bool {
        args.contains(where: standaloneProbeFlags.contains)
            || args.contains("--eval-input") || args.contains("--eval-output")
    }

    static func showsWindow(arguments: [String], loginItem: Bool) -> Bool {
        !loginItem && !isProbe(arguments) && !arguments.contains("--background")
            && !arguments.contains("--selftest") && !arguments.contains("--sink")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pipeline = Pipeline()
    private var overlayTestTicks = 0
    private var historyMaintenance: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        if args.contains("--theme-preview") {
            ThemePreviewLaunch.run()
            return
        }
        #endif
        // These probes own the exact AppKit/TCC/model subsystem they exercise. Starting the
        // production Pipeline as well would load the 500 MB speech model and prime a recorder
        // for tests that do not use either, or double-load ASR for the explicit ASR probes.
        let standaloneProbe = AppLaunchPolicy.isProbe(args)
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        setupLog()   // redteam H1: rotate + 0600 before the first write
        // X3: the runid marker is written AFTER rotation, or test.sh would scope its
        // assertions to a line that just moved into FlowClone.log.1.
        if let runid = launchArgValue("--runid") {
            log("RUNID \(sanitizedRunID(runid))")
        }
        log("app launched — bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath) exec-sha256=\(executableSHA256Prefix()) build=\(Updater.currentBuild) pid=\(ProcessInfo.processInfo.processIdentifier)")
        logStatus()
        if args.contains("--streaming-asr-test") {
            Task {
                do { try await NemotronSelfCheck.run() }
                catch {
                    log("NEMOTRONCHECK FAIL \(String(describing: error))")
                    flushLog()
                    Darwin.exit(EXIT_FAILURE)
                }
                flushLog()
                NSApp.terminate(nil)
            }
            return
        }
        if args.contains("--eval-input") || args.contains("--eval-output") {
            guard let input = launchArgValue("--eval-input"), let output = launchArgValue("--eval-output") else {
                log("CORPUS FAIL both --eval-input and --eval-output are required")
                flushLog()
                Darwin.exit(EXIT_FAILURE)
            }
            Task {
                do { try await CorpusReplay.run(input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output)) }
                catch {
                    log("CORPUS FAIL \(String(reflecting: type(of: error)))")
                    flushLog()
                    Darwin.exit(EXIT_FAILURE)
                }
                flushLog()
                NSApp.terminate(nil)
            }
            return
        }
        if standaloneProbe {
            log("standalone probe launch — production pipeline/model startup skipped")
        } else {
            _ = PersonalizationStore.shared.hardenPermissions()
            setupLaunchAtLogin()
            pipeline.start()
            _ = History.items   // load history.jsonl now, not inside the first dictation
            Updater.workActive = { [weak self] in
                (self?.pipeline.sessionActive ?? false)
                    || TransformController.shared.blocksUpdate || MeetingCoordinator.shared.blocksUpdate
            }
            Updater.sessionActive = {
                Updater.workActive() || MainWindow.shared.isVisible
            }
            Updater.reserveForInstall = { [weak self] in
                guard let self else { return false }
                return await self.pipeline.reserveForUpdate()
            }
            Updater.releaseInstallReservation = { [weak self] in
                self?.pipeline.releaseUpdateReservation()
            }
            Updater.start()
            if let pasteSink {
                notifyUser("Test paste sink armed (\(pasteSink)) — real pastes are refused until relaunch.")
            }
        }

        // Build the panel now, not on the first hotkey press. A production launch rests as
        // the idle bar when that is on; a standalone probe must not, or a test launch beside
        // the installed app draws a second bar over the owner's pill (2026-09-06 report).
        if standaloneProbe {
            _ = Overlay.shared
        } else {
            Overlay.shared.onStartHandsFree = { [weak self] in self?.pipeline.toggleHandsFree() }
            Overlay.shared.onFinishCapture = { [weak self] in self?.pipeline.stopCapture() }
            Overlay.shared.onCancelCapture = { [weak self] in self?.pipeline.cancelCapture() }
            Overlay.shared.onStartNewMeeting = {
                MainWindow.shared.show(.meetings)
                Task { @MainActor in _ = await MeetingCoordinator.shared.startAdHocMeeting() }
            }
            Overlay.shared.onOpenMainWindow = { MainWindow.shared.show() }
            Overlay.shared.hide()
        }
        Permissions.hotkeyVerified = { [weak self] in self?.pipeline.hotkeyVerified ?? false }
        Permissions.onHotkeyRearm = { [weak self] in self?.pipeline.startHotkey() }

        StatusMenu.shared.sessionActive = { [weak self] in self?.pipeline.sessionActive ?? false }
        StatusMenu.shared.handsFreeActive = { [weak self] in self?.pipeline.handsFreeActive ?? false }
        StatusMenu.shared.retryAvailable = { [weak self] in self?.pipeline.retryAvailable ?? false }
        StatusMenu.shared.modelRetryAvailable = { [weak self] in
            self?.pipeline.modelRetryAvailable ?? false
        }
        StatusMenu.shared.learnedUndoAvailable = { AutoLearn.undoAvailable }
        StatusMenu.shared.transformUndoAvailable = { TransformController.shared.undoAvailable }
        StatusMenu.shared.onToggleHandsFree = { [weak self] in self?.pipeline.toggleHandsFree() }
        StatusMenu.shared.onRepaste = { [weak self] in self?.pipeline.repasteLast($0) }
        StatusMenu.shared.onRetry = { [weak self] in self?.pipeline.retryLastRecording() }
        StatusMenu.shared.onRetryModel = { [weak self] in self?.pipeline.retrySpeechModel() }
        SpeechModelState.shared.retry = { [weak self] in self?.pipeline.retrySpeechModel() }
        StatusMenu.shared.onUndoLearned = { [weak self] in self?.pipeline.undoLastLearnedCorrection() }
        StatusMenu.shared.onTransform = { TransformController.shared.begin() }
        StatusMenu.shared.onUndoTransform = { TransformController.shared.undoLast() }
        StatusMenu.shared.install()
        if !standaloneProbe {
            let workspace = DictationWorkspace.shared
            workspace.load()
            workspace.onCapture = { [weak self] in self?.pipeline.startWorkspaceCapture($0, lease: $1) }
            workspace.onStop = { [weak self] in self?.pipeline.stopCapture() }
            workspace.onCancel = { [weak self] in self?.pipeline.cancelCapture() }
            workspace.onPaste = { [weak self] in self?.pipeline.repasteLast($0, lease: $1, fromDraft: true) }
            workspace.onRetry = { [weak self] in self?.pipeline.retryLastRecording(toDraft: true) }
            workspace.onPractice = { [weak self] in self?.pipeline.setPracticeMode($0) }
            workspace.onMicrophonePolicy = { [weak self] in self?.pipeline.refreshMicrophonePolicy() }
            workspace.onRetranscribe = { [weak self] in self?.pipeline.retranscribeHistory($0) }
            History.applyRetention()
            historyMaintenance = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
                Task { @MainActor in History.applyRetention() }
            }
        }

        if !standaloneProbe, !handsfreeSession { ClaudeKey.importDropFile() }
        if !standaloneProbe { MainWindow.shared.installMainMenuIfNeeded() }
        if args.contains("--onboarding") || (!standaloneProbe && Permissions.grantsMissing) {
            MainWindow.shared.show(.settings)
        } else if AppLaunchPolicy.showsWindow(arguments: args, loginItem: loginItem) {
            if !standaloneProbe, !handsfreeSession, ClaudeKey.needsSetupPrompt() {
                MainWindow.shared.show(.settings)
            } else {
                MainWindow.shared.show()
            }
        }
        if !standaloneProbe { MainWindow.shared.updateDockPresence() }
        if args.contains("--pilldemo") { Overlay.shared.demo() }
        if args.contains("--pilltest") { Overlay.shared.pillSelfCheck() }
        if args.contains("--overlaytest") {
            // 4s so the tester can put the real target app back in front after `open`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.overlayTest() }
        }
        if args.contains("--promptkeepprobe") { pipeline.promptKeepProbe() }
        if let p = launchArgValue("--promptdump") { Prompter.dump(to: p) }
        if args.contains("--overlaystress") { Overlay.shared.stress() }
        if args.contains("--polishtest") { Polisher.selfCheck() }
        if args.contains("--prompttest") { Prompter.selfCheck() }
        if args.contains("--menutest") { StatusMenu.selfCheck() }
        if args.contains("--recordertest") { Recorder.selfCheck() }
        if args.contains("--pastertest") { Paster.selfCheck() }
        if args.contains("--transformtest") { TransformController.selfCheck() }
        if args.contains("--micdiag") { runMicDiagnostic() }
        if args.contains("--recorderdiag") { runRecorderDiagnostic() }
        if args.contains("--pastelatencytest") { runPasteLatencyDiagnostic() }
        if args.contains("--miclatencytest") { runRecorderLatencyDiagnostic() }
        if args.contains("--learntest") { runLearningDiagnostic() }
        if args.contains("--contextlatencytest") { runContextLatencyDiagnostic() }
        if args.contains("--updatetest") { Updater.selfCheck() }
        if args.contains("--insertiontest") { InsertionSelfCheck.run() }
        // R-5: measured runs (--selftest/--sink) never write the saved mode.
        if !standaloneProbe, !args.contains("--selftest"), !args.contains("--sink"),
           Mode.retireLegacySelection() {
            log("cleanup mode: Polish was retired — switched the saved selection to Clean")
        }
        log("cleanup mode = \(Mode.current.rawValue)")
        // audit A-3: the launch prewarm is mode-aware AND suppressed on the LLM suites.
        // FM keeps ONE profile-tagged session slot, so a saved-mode prewarm racing an async
        // suite would make that suite schedule-dependent (it would find a session it did
        // not put there). On those two launches the suite is the sole owner of FM state.
        if !standaloneProbe {
            if Mode.current == .prompt { Prompter.prepare() }
            RepairReviewer.prepare(prewarm: Mode.current == .clean)
        }
        #if DEBUG
        HandsfreeLaunch.start(pipeline: pipeline)
        #endif
        if !standaloneProbe { MeetingCoordinator.shared.launch() }
    }

    /// Opening the app while it runs = "show me the window".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindow.shared.show()
        return false
    }

    /// Closing the library leaves the dictation hotkey and menu available (and removes the
    /// Dock icon, see `MainWindow.updateDockPresence`). Quit is explicit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = MeetingCoordinator.shared
        guard coordinator.blocksUpdate else {
            AppTermination.reset()
            return .terminateNow
        }
        let relaunching = AppTermination.isRelaunching
        let explicitQuit = AppTermination.explicitUserQuit
        AppTermination.reset()
        Task { @MainActor in
            await coordinator.prepareForTermination(relaunching: relaunching, explicitQuit: explicitQuit)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.applicationWillTerminate()
        MediaPause.shared.resumeBeforeExit()
        Sidecar.shared.shutdown()
        DictationWorkspace.shared.flush()
        History.flush()
        closeLog()
    }

    private func logStatus() {
        log("status: mic=\(micStatusName()) accessibility=\(AXIsProcessTrusted()) inputMonitoring=\(hidAccessName())")
    }

    /// Shows both overlay states for 3s and proves the panel never steals focus:
    /// the frontmost bundle id must be identical in all three log lines.
    @objc private func overlayTest() {
        func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil" }
        notifyUser("Overlay test — this is what a paste-failure toast looks like")
        let before = front()
        log("OVERLAYTEST before show: frontmost=\(before)")
        Overlay.shared.recording()
        overlayTestTicks = 0
        Timer.scheduledTimer(timeInterval: 0.05, target: self,
                             selector: #selector(overlayTestTick(_:)), userInfo: nil,
                             repeats: true)   // fake level sweep
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let shown = front()
            log("OVERLAYTEST while shown: frontmost=\(shown)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Overlay.shared.transcribing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    Overlay.shared.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let after = front()
                        log("OVERLAYTEST after hide: frontmost=\(after)")
                        // audit A-5: single terminal aggregate, emitted after all three
                        // reads — the panel must never have taken focus from the target.
                        log(before == shown && shown == after
                            ? "OVERLAYTEST PASS (frontmost unchanged: \(after))"
                            : "OVERLAYTEST FAIL (\(before) → \(shown) → \(after))")
                    }
                }
            }
        }
    }

    @objc private func overlayTestTick(_ timer: Timer) {
        overlayTestTicks += 1
        Overlay.shared.level(Float(overlayTestTicks % 20) / 20)
        if overlayTestTicks >= 40 { timer.invalidate() }
    }

}

/// Flush pending log writes (used before opening the log or quitting).
func flushLog() {
    logQueue.sync {
        try? loggerState.handle?.synchronize()
        loggerState.unsynchronizedWrites = 0
    }
}

private func closeLog() {
    logQueue.sync {
        try? loggerState.handle?.synchronize()
        try? loggerState.handle?.close()
        loggerState.handle = nil
        loggerState.unsynchronizedWrites = 0
    }
}

/// Start at login, so the hotkey is armed after a reboot without opening the app.
/// Settings › This Mac › Open FlowClone at login (`launchAtLogin`, on when absent).
/// Registers ONLY from .notRegistered: if the user turns the login item off in System
/// Settings the status becomes .requiresApproval, and re-registering over that would
/// override their choice on every launch. See `LaunchAtLogin.step`.
func setupLaunchAtLogin() {
    if handsfreeSession { Handsfree.log("blocked launch-at-login registration"); return }
    let wanted = LaunchAtLogin.wanted()
    let service = SMAppService.mainApp
    let before = service.status          // read once: register() mutates it mid-switch
    do {
        switch LaunchAtLogin.step(wanted: wanted, status: before, translocated: LaunchAtLogin.isTranslocated) {
        case .needsApproval:
            log("launch at login: needs approval in System Settings › General › Login Items")
        case .nothing:
            log("launch at login: \(wanted ? "on" : "off")")
        case .unregister:
            try service.unregister()
            log("launch at login: unregistered (launchAtLogin = false)")
        case .register:
            // .notRegistered AND .notFound (status 3 before a first successful
            // registration on this OS) — register() is what turns either into .enabled.
            try service.register()
            log("launch at login: registered (status \(before.rawValue) → \(service.status.rawValue))")
        case .notFromTemporaryCopy:
            log("launch at login: not registered — running from an App Translocation copy")
        }
    } catch {
        log("launch at login FAILED: \(error.localizedDescription)")
    }
}

/// Soft cue that the microphone is live (hold the key, speak): the finish "Pop" a major
/// third up (`app/StartCue.aiff`, bundled by build.sh; NSSound searches the bundle first).
/// Settings > Sounds & language turns it off (`startSound`) and sets the volume; `force`
/// is that page's Play button, which plays it even while switched off.
func playStartSound(force: Bool = false) { playCue("StartCue", key: SoundCues.startKey, force: force) }

/// Soft cue that processing has started (key released, transcription running).
/// Settings > Sounds & language turns it off (`processingSound`).
func playProcessingSound() { playCue("Pop", key: SoundCues.processingKey) }

/// Cues play on their own queue, never the main thread. Starting an idle output device
/// blocks inside Core Audio's AudioDeviceStart (~430 ms on the Studio Display speakers),
/// and the main thread is what answers a target app's read of the text being pasted:
/// cueing there held every such paste back past its acknowledgement window, so pastes
/// that landed were reported as "Paste could not be confirmed" (2026-10-06).
private let cueQueue = DispatchQueue(label: "com.andre.flowclone.cue", qos: .userInitiated)

/// Playing cues, owned by `cueQueue`; holding them keeps each alive until it finishes
/// (a released player stops mid-cue).
private final class CuePlayers: @unchecked Sendable {
    var playing: [String: AVAudioPlayer] = [:]
}

private let cuePlayers = CuePlayers()

/// Where `NSSound(named:)` found these cues: the app bundle first, then system sounds.
private func cueURL(_ name: String) -> URL? {
    if let bundled = Bundle.main.url(forResource: name, withExtension: "aiff") { return bundled }
    let system = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    return FileManager.default.fileExists(atPath: system.path) ? system : nil
}

private func playCue(_ name: String, key: String, force: Bool = false) {
    guard force || SoundCues.isEnabled(key) else { return }
    if handsfreeSession { Handsfree.log("blocked sound"); return }
    let volume = SoundCues.volume()
    cueQueue.async {
        // A fresh player per cue follows the current default output device.
        guard let url = cueURL(name), let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = volume
        cuePlayers.playing[name] = player
        player.play()
    }
}

public enum FlowCloneApplication {
    /// `NSApplication.delegate` is weak. Keep the process-lifetime owner of Pipeline and
    /// every UI callback strongly referenced for as long as the application is running.
    @MainActor private static var appDelegate: AppDelegate?

    @MainActor
    public static func run() {
        #if DEBUG
        HandsfreeLaunch.install()   // no-op unless an agent's hands-free session (HANDSFREE=1)
        #endif
        let delegate = AppDelegate()
        appDelegate = delegate
        NSApplication.shared.delegate = delegate
        // Start in .accessory (matching LSUIElement=true) so login, background, and probe
        // launches never flash a Dock icon. MainWindow.show() switches to .regular only when
        // a window is actually put on screen, and updateDockPresence() returns to .accessory
        // when closed.
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }
}
