// The dictation loop: hold → record → release → transcribe → paste.
// One serial queue owns all session state, including overlapping capture of Utterance N+1
// while Utterance N finishes ASR/cleanup/paste in strict FIFO order.
import AVFoundation
import Cocoa
import FluidAudio
import Foundation
import os

/// Cleanup level (PLAN.md Phase 3). Persisted in UserDefaults, set in the Setup window.
enum Mode: String, CaseIterable {
    // PLAN-PROMPT D1: both control surfaces derive their order and labels from `allCases`;
    // the persisted value is the raw string. Polish sat between Clean and Prompt until
    // 2026-09-22 — see `retireLegacySelection`.
    case raw, clean, prompt
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// D10: the modes that defer their paste behind a Foundation Models call. Used at both
    /// exclusion sites (the percentile totals and — via AutoLearn.shouldRecord — the
    /// typed-over-fix record), so "is this an LLM mode" is answered in exactly one place.
    var isLLM: Bool { self == .prompt }

    /// X3/R-5: in-process pin used only by `--selftest`, so every measured run is Clean
    /// whatever the user has saved. Deliberately NOT a UserDefaults write — a test must
    /// never change the mode the app comes back up in. nil on every normal launch.
    private final class OverrideState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Mode?

        func read() -> Mode? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func write(_ newValue: Mode?) {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }
    }

    private static let overrideState = OverrideState()
    static var testOverride: Mode? {
        get { overrideState.read() }
        set { overrideState.write(newValue) }
    }

    static var current: Mode {
        get { testOverride ?? Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .clean }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mode") }
    }

    /// F2/F-5: the ONE way to change mode. Both control surfaces (the Setup popup and the
    /// status-bar menu) go through here, so neither can skip the Prompt prewarm.
    /// Main thread.
    static func set(_ m: Mode) {
        current = m
        log("cleanup mode = \(m.rawValue)")
        if m == .prompt { Prompter.prepare() }   // availability check + prewarm, off-thread
        if m == .clean { RepairReviewer.prepare(prewarm: true) }
    }

    /// Polish was retired on 2026-09-22: on 136 real dictations it matched Clean 79% of the
    /// time while adding ~1 s to release→paste. A saved "polish" selection becomes Clean,
    /// once, so both control surfaces show what actually runs. True when it migrated.
    @discardableResult
    static func retireLegacySelection(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: "mode") == "polish" else { return false }
        defaults.set(Mode.clean.rawValue, forKey: "mode")
        return true
    }
}

/// Semantic source of a pipeline transaction. User-facing/log labels stay derived here so
/// retry, self-test, and repaste cannot accidentally enter learning or latency accounting
/// merely because a string comparison was missed.
enum DictationOrigin: Equatable, Sendable {
    case utterance
    case partialUtterance
    case retry
    case repaste
    case selfTest

    var tag: String {
        switch self {
        case .utterance: return "utterance"
        case .partialUtterance: return "partial utterance"
        case .retry: return "retry"
        case .repaste: return "repaste"
        case .selfTest: return "SELFTEST"
        }
    }

    var acceptsSpokenCorrection: Bool {
        switch self {
        case .utterance, .partialUtterance, .retry: return true
        case .repaste, .selfTest: return false
        }
    }

    var recordsAutoLearn: Bool { acceptsSpokenCorrection }
    var canArmHandsFreeTap: Bool { self == .utterance }
    var allowsRepairReview: Bool { self != .selfTest }
    var contributesLiveLatency: Bool { self == .utterance || self == .partialUtterance }
    var contributesTranscribedWords: Bool {
        self == .utterance || self == .partialUtterance || self == .retry
    }
    var commitsFailedRecovery: Bool { self == .retry }
    var supersedesFailedRecovery: Bool { self == .utterance || self == .partialUtterance }
}

final class Pipeline: @unchecked Sendable {   // state is confined to `queue`
    /// Trailing Parakeet live preview cap (10s = 160,000 samples @ 16kHz) so key-up `.final`
    /// never waits behind a non-preemptible 30s preview pass.
    static let previewWindowSeconds = 10.0
    static let previewMaxSamples = 160_000
    /// Minimum blocking prime duration before an already-released hotkey counts as an early-release abort.
    static let significantPrimeWaitMS = 80.0
    /// Debounce window for `StartCue` and `MediaPause` on multi-modifier-only chords (`Ctrl+Opt`)
    /// so window-snapping chords (`Ctrl+Opt+Left`) cancel silently without pausing music.
    static let chordSideEffectDebounceSeconds: TimeInterval = 0.110

    private static let queueKey = DispatchSpecificKey<Bool>()
    let queue = DispatchQueue(label: "com.andre.flowclone.session")
    private lazy var recorder = Recorder(queue: queue)
    private lazy var hotkey = HotkeyMonitor(queue: queue)
    private let runtime: SpeechRuntime
    private var transcriber: Transcriber { runtime.activeTranscriber }
    private var activeRepairReview: (generation: Int, cancel: RepairReviewer.Cancel)?

    private struct UtteranceContext {
        let generation: Int
        var purpose: CapturePurpose
        var captureMode: Mode
        var resultID = UUID()
        var parentResultID: UUID?
        var resultAlreadyInDraft = false
        var cleanStage: String?
        var audioForHistory: [Float]?
        var resultTargetApp: String?
        var vocabularyCapture: VocabularyCapture?
        var vocabulary: PersonalizationConfiguration?
        var deliveryMetrics: DeliveryMetrics?
        var streamRevision: Int?
        var isSelfTest = false
    }

    private struct PendingFinalization {
        let samples: [Float]
        let generation: Int
        let origin: DictationOrigin
        let releasedAt: DispatchTime
        let mode: Mode
        let targetLease: Paster.TargetLease?
        let maxAttempts: Int
    }

    private var utterances: [Int: UtteranceContext] = [:]
    private var pendingFinalizations: [PendingFinalization] = []
    private var interactiveRuntimeActive = false

    // Side-effect debounce state (confined to `queue`)
    private var mediaPauseEngaged = false
    private var pendingSideEffectsWork: DispatchWorkItem?
    private var pendingSideEffectsGeneration: Int?
    private var startCuePendingAfterRecorderOpen = false
    private var startCuePlayedForCapture = false

    // Internal test seams (unused in production)
    var suppressOverlayForTest = false
    var suppressNotificationsForTest = false
    var suppressPersistenceForTest = false
    var primeOverrideForTest: ((@escaping @Sendable (Bool, Bool) -> Void) -> Void)?
    var beginCaptureOverrideForTest: ((Double, String, @escaping @Sendable (Bool) -> Void) -> Void)?
    var endCaptureOverrideForTest: ((Bool) -> [Float])?
    var updateCapOverrideForTest: ((Double) -> Void)?
    var resolveTargetOverrideForTest: ((Paster.TargetLease?, @escaping @Sendable (PasteTarget?) -> Void) -> Void)?
    var pasteOverrideForTest: ((String, @escaping @Sendable () -> Void) -> Void)?
    var notificationObserverForTest: ((String, String?) -> Void)?
    var startCueHandler: () -> Void = { playStartSound() }
    var processingCueHandler: () -> Void = { playProcessingSound() }
    var mediaPauseBeganHandler: () -> Void = { MediaPause.shared.captureBegan() }
    var mediaPauseEndedHandler: () -> Void = { MediaPause.shared.captureEnded() }
    var armTapObserverForTest: (() -> Void)?

    init(runtime: SpeechRuntime = .shared) {
        self.runtime = runtime
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    static func reviewPolicy(
        mode: Mode, origin: DictationOrigin, commandLine: Bool,
        isBareSnippet: Bool, hadContextRewrite: Bool
    ) -> (shouldReview: Bool, allowCloud: Bool, allowOnDevice: Bool) {
        guard mode == .clean, origin.allowsRepairReview, !commandLine, !isBareSnippet else {
            return (false, false, false)
        }
        return (true, !hadContextRewrite, true)
    }

    /// Whether a Prompt-mode dictation may be sent to Claude. "Built-in model" keeps every
    /// dictation on this Mac (the hotkey-down pre-warm already followed it; the send did
    /// not). Rewrites from on-screen context and expanded private snippets stay local too.
    static func promptCloudAllowed(
        hadContextRewrite: Bool, hasSnippets: Bool,
        setting: RepairReviewer.Setting = RepairReviewer.setting
    ) -> Bool {
        !hadContextRewrite && !hasSnippets && setting != .onDevice
    }

    static func shouldRecordCleanLatency(
        purpose: CapturePurpose, mode: Mode, origin: DictationOrigin,
        provenInsertion: Bool, usedLLM: Bool
    ) -> Bool {
        purpose != .practice && !mode.isLLM && !usedLLM && origin.contributesLiveLatency && provenInsertion
    }

    static func shouldAbortForPrimeWait(
        waitedForPrime: Bool,
        primeWaitMS: Double,
        keyReleased: Bool,
        handsFree: Bool = false
    ) -> Bool {
        guard waitedForPrime, !handsFree else { return false }
        return primeWaitMS > significantPrimeWaitMS && keyReleased
    }

    static func isMultiModifierOnlyChord(
        source: String,
        bindings: [ShortcutBinding] = ShortcutStore.shared.bindings
    ) -> Bool {
        guard source == "ctrl+opt" else { return false }
        let modifierOnly = bindings.filter { $0.action == .dictate && $0.keyCode == nil }
        if modifierOnly.isEmpty {
            return true
        }
        return modifierOnly.contains { binding in
            let flags = binding.modifiers & ShortcutBinding.modifierMask
            return flags.nonzeroBitCount >= 2
        }
    }

    static func shouldDebounceChordSideEffects(
        source: String,
        handsFree: Bool,
        bindings: [ShortcutBinding] = ShortcutStore.shared.bindings
    ) -> Bool {
        guard !handsFree else { return false }
        return isMultiModifierOnlyChord(source: source, bindings: bindings)
    }

    static func isHotkeyPhysicallyHeld(
        source: String,
        bindings: [ShortcutBinding] = ShortcutStore.shared.bindings
    ) -> Bool {
        switch source {
        case "fn":
            return CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
                || CGEventSource.keyState(.combinedSessionState, key: 63)
        case "ctrl+opt":
            let current = CGEventSource.flagsState(.combinedSessionState).rawValue & ShortcutBinding.modifierMask
            let modifierBindings = bindings.filter { $0.action == .dictate && $0.keyCode == nil && $0.modifiers != 0 }
            if modifierBindings.isEmpty {
                let fallback = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
                return (current & fallback) == fallback
            }
            return modifierBindings.contains { (current & $0.modifiers) == $0.modifiers }
        default:
            return true
        }
    }

    /// Menu-bar title, called on the main thread.
    var onStatus: ((String) -> Void)?

    /// F2: main-thread mirror of "a session is in flight", for the status menu — it must
    /// not block on the session queue to read it. Written by the status() hop below.
    private(set) var sessionActive = false
    /// F1: main-thread mirror of "hands-free is running", same hop, same reason — it is
    /// what turns the menu item into "Stop hands-free".
    private(set) var handsFreeActive = false
    /// Main-thread mirror for the menu. The samples themselves never leave the session
    /// queue and are held in memory only.
    private(set) var retryAvailable = false
    /// Main-thread mirror for a model-load failure. This is separate from failed-audio
    /// retry so a transient download/compile failure never disables dictation until relaunch.
    private(set) var modelRetryAvailable = false

    private var ready = false
    private var modelLoadFailed = false
    private var modelLoading = false
    private var modelLoadAttempt = 0
    /// Every capture start and end passes through this property — accepted press, release,
    /// cancel, failed open, input failure — so pausing media here can never miss a resume.
    private var session = PipelineSessionState() {
        didSet {
            if let active = activeRepairReview, !session.owns(active.generation) {
                activeRepairReview = nil
                active.cancel()
            }
            if oldValue.captureActive && !session.captureActive {
                disengageCaptureSideEffects()
            }
        }
    }
    /// The field/security anchor starts when a capture is accepted, not after key-up. AX
    /// work lives on Paster's capture executor; this queue owns only the generation-tagged lease.
    private struct TargetCaptureOwnership {
        let generation: Int
        let lease: Paster.TargetLease?
    }
    private var targetCapture: TargetCaptureOwnership?
    private var totals: [Double] = []
    private var claudeTotals: [Double] = []
    private var overallTotals: [Double] = []
    private var latencyMeasurements = 0
    private static let latencyWindow = 200
    /// What we last pasted, checked for typed-over fixes at the next hotkey-down.
    private var failedCaptures = FailedCaptureStore(lifetime: 10 * 60)
    /// The "your previous clipboard could not be preserved" notice is worth saying once a
    /// run, not on every dictation into a clipboard we cannot snapshot.
    private var warnedClipboardNotPreserved = false
    /// X3/R-6: set only by `selfTest()`. Labels the run so a measured self-test never
    /// enters the live p50/p95 totals or the typed-over-fix record. False in normal use.
    private var selfTesting = false
    private var defaultPurpose: CapturePurpose = .editor(.normal)
    private var pendingPurpose: CapturePurpose?
    private var practiceMode = false

    /// Live partial text in the pill (Overlay.livePartialEnabled). Its own timer and its
    /// own in-flight flag; decodes serialize on the shared DecodeScheduler.
    private var previewTimer: DispatchSourceTimer?
    private var previewBusy = false
    private var previewTask: Task<Void, Never>?
    private var previewTaskOwner: Int?

    private var streamingTimer: DispatchSourceTimer?
    private var streamingTask: Task<Void, Never>?
    private var streamingBusy = false
    private var streamingGeneration: Int?
    private var streamingOffset = 0
    private var streamingRevision: Int?

    /// Call on the main thread.
    func start() {
        hotkey.onEdge = { [weak self] in self?.handle($0) }
        hotkey.onAction = { action, lease in
            DispatchQueue.main.async { DictationWorkspace.shared.perform(action, lease: lease) }
        }
        hotkey.onShortcutAction = { action, lease in
            DispatchQueue.main.async {
                switch action {
                case .transformSelection:
                    TransformController.shared.begin(spoken: false, lease: lease)
                }
            }
        }
        recorder.onDevice = { name in DispatchQueue.main.async { DictationWorkspace.shared.microphone = name } }
        recorder.onOverflow = { [weak self] cap in
            guard let self else { return }
            log("recording hit the \(Int(cap))s cap — auto-stopping")
            self.notify("Reached the \(Int(cap))-second limit — finishing this dictation.")
            // F1: route a hands-free overflow through the monitor so the latch and the
            // session end together; a held press has no latch to clear.
            if self.hotkey.isLatched { self.hotkey.stopLatched() } else { self.finish() }
        }
        recorder.onInputFailure = { [weak self] samples, reason in
            self?.inputFailed(samples, reason: reason)
        }
        recorder.onInputMuted = { [weak self] in
            self?.notify("Your microphone is muted. Unmute it to continue this dictation.")
        }
        recorder.onLevels = { responsive, classic, voice in
            DispatchQueue.main.async {
                if Theme.current != .classic { Overlay.shared.level(responsive, voice: voice) }
                else if let classic { Overlay.shared.level(classic) }
                if let classic { DictationWorkspace.shared.level = classic }
            }
        }
        // Avoid competing diagnostic engines, but prime the production recorder on
        // every normal launch so Bluetooth negotiation never sits on the hotkey path.
        let args = ProcessInfo.processInfo.arguments
        let opensItsOwnEngine = ["--recorderdiag", "--micdiag"]
        if !args.contains(where: opensItsOwnEngine.contains) {
            recorder.primeAsync()
        }
        if AXIsProcessTrusted() {
            hotkey.start()
        } else {
            log("hotkey NOT started — Accessibility not granted (Permissions…, then relaunch)")
        }

        status("FC↓")
        #if DEBUG
        Sidecar.warm()   // no-op unless `sidecarModel` is set
        #endif
        queue.async { self.beginModelLoad(resetAttempts: true) }
    }

    /// Call on the main thread (after a first Accessibility grant).
    func startHotkey() { hotkey.start() }

    /// Main thread only — see HotkeyMonitor.sawEvent.
    var hotkeyVerified: Bool { hotkey.sawEvent }

    /// Test-only helper to mark model ready on `queue` without running startup model download.
    func setReadyForTest(_ isReady: Bool) {
        queue.sync {
            self.ready = isReady
            self.modelLoadFailed = false
            self.modelLoading = false
        }
    }

    var sessionStateForTest: PipelineSessionState {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            return session
        }
        return queue.sync { session }
    }

    /// Atomically fence new captures/deliveries on the queue that accepts them. The
    /// main-thread status mirror alone cannot close the check-to-restart race.
    func reserveForUpdate() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.session.reserveForUpdate()) }
        }
    }

    func releaseUpdateReservation() {
        queue.async { self.session.releaseUpdateReservation() }
    }

    /// The failure banner says why, so "Retry" is not the only thing a person can try.
    static func speechModelFailureNotice(_ problem: SpeechModelProblem) -> String {
        "\(problem.message) Retry is in Settings › This Mac and in the menu bar menu."
    }

    /// Menu action after automatic retries are exhausted.
    func retrySpeechModel() {
        queue.async {
            guard !self.modelLoading, !self.ready else { return }
            self.beginModelLoad(resetAttempts: true)
        }
    }

    /// Session queue. Startup gets three bounded attempts; the menu starts a fresh bounded
    /// sequence. `SpeechRuntime.ensureActiveLoaded` shares the single Parakeet graph across
    /// Dictation and Meetings.
    private func beginModelLoad(resetAttempts: Bool = false) {
        guard !modelLoading, !ready else { return }
        if resetAttempts { modelLoadAttempt = 0 }
        modelLoadAttempt += 1
        let attempt = modelLoadAttempt
        modelLoading = true
        modelLoadFailed = false
        publishModelRetryAvailability()
        status("FC↓")
        if attempt == 1 { DispatchQueue.main.async { SpeechModelState.shared.set(.loading) } }
        Task {
            let ok = await self.runtime.ensureActiveLoaded { log("ASR \($0)"); SpeechModelState.report($0) }
            let state = await self.transcriber.state
            let problem = await self.transcriber.lastLoadProblem ?? .other
            self.queue.async {
                self.modelLoading = false
                self.ready = ok
                if ok {
                    self.modelLoadFailed = false
                    self.modelLoadAttempt = 0
                    self.publishModelRetryAvailability()
                    DispatchQueue.main.async { SpeechModelState.shared.set(.ready) }
                    self.status("FC")
                    if ProcessInfo.processInfo.arguments.contains("--selftest") {
                        log("SELFTEST: starting in 3s — focus the target window now")
                        self.queue.asyncAfter(deadline: .now() + 3) { self.selfTest() }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--longaudioprobe") {
                        log("SELFTEST: long-audio probe starting in 3s — focus the target window now")
                        self.queue.asyncAfter(deadline: .now() + 3) {
                            self.selfTest(repeats: 24, latched: true)
                        }
                    }
                    return
                }

                if attempt < 3 {
                    let delay = pow(2.0, Double(attempt - 1))
                    log("ASR load attempt \(attempt)/3 failed (\(state)); retrying in \(Int(delay))s")
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.beginModelLoad()
                    }
                } else {
                    self.modelLoadFailed = true
                    self.publishModelRetryAvailability()
                    DispatchQueue.main.async { SpeechModelState.shared.set(.failed(problem)) }
                    self.status("FC!")
                    self.notify(Self.speechModelFailureNotice(problem))
                }
            }
        }
    }

    // MARK: - Interactive runtime lease & chord side-effect debounce

    private func beginInteractiveActivityIfNeeded() {
        guard !interactiveRuntimeActive else { return }
        interactiveRuntimeActive = true
        let runtime = runtime
        Task { await runtime.beginInteractiveSession() }
    }

    private func endInteractiveActivityIfIdle() {
        guard interactiveRuntimeActive, !session.captureActive, !session.isDelivering else { return }
        interactiveRuntimeActive = false
        let runtime = runtime
        Task { await runtime.endInteractiveSession() }
    }

    private func cancelPendingSideEffectsDebounce() {
        pendingSideEffectsWork?.cancel()
        pendingSideEffectsWork = nil
        pendingSideEffectsGeneration = nil
        startCuePendingAfterRecorderOpen = false
    }

    private func disengageCaptureSideEffects() {
        cancelPendingSideEffectsDebounce()
        startCuePlayedForCapture = false
        if mediaPauseEngaged {
            mediaPauseEngaged = false
            if !selfTesting {
                mediaPauseEndedHandler()
            }
        }
    }

    private func scheduleOrEngageSideEffects(for generation: Int, source: String, handsFree: Bool) {
        cancelPendingSideEffectsDebounce()
        startCuePlayedForCapture = false
        guard !selfTesting else { return }

        if Self.shouldDebounceChordSideEffects(source: source, handsFree: handsFree) {
            pendingSideEffectsGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.pendingSideEffectsGeneration == generation,
                      self.session.ownsCapture(generation),
                      !self.session.pendingRelease else {
                    self.pendingSideEffectsWork = nil
                    self.pendingSideEffectsGeneration = nil
                    return
                }
                self.pendingSideEffectsWork = nil
                self.pendingSideEffectsGeneration = nil
                if !self.mediaPauseEngaged, !self.selfTesting {
                    self.mediaPauseEngaged = true
                    self.mediaPauseBeganHandler()
                }
                if self.session.isRecording,
                   self.startCuePendingAfterRecorderOpen,
                   !self.startCuePlayedForCapture {
                    self.startCuePendingAfterRecorderOpen = false
                    self.startCuePlayedForCapture = true
                    self.startCueHandler()
                }
            }
            pendingSideEffectsWork = work
            queue.asyncAfter(deadline: .now() + Self.chordSideEffectDebounceSeconds, execute: work)
        } else {
            if !mediaPauseEngaged {
                mediaPauseEngaged = true
                mediaPauseBeganHandler()
            }
        }
    }

    private func flushDebouncedSideEffectsNow(for generation: Int) {
        guard pendingSideEffectsGeneration == generation else { return }
        pendingSideEffectsWork?.cancel()
        pendingSideEffectsWork = nil
        pendingSideEffectsGeneration = nil
        if !mediaPauseEngaged, !selfTesting {
            mediaPauseEngaged = true
            mediaPauseBeganHandler()
        }
        if session.isRecording, startCuePendingAfterRecorderOpen, !startCuePlayedForCapture {
            startCuePendingAfterRecorderOpen = false
            startCuePlayedForCapture = true
            startCueHandler()
        }
    }

    private func triggerStartCueOnRecorderOpen(for generation: Int) {
        guard !startCuePlayedForCapture else { return }
        if pendingSideEffectsGeneration == generation, pendingSideEffectsWork != nil {
            startCuePendingAfterRecorderOpen = true
            return
        }
        startCuePlayedForCapture = true
        startCueHandler()
    }

    private func notify(_ message: String, copyText: String? = nil) {
        notificationObserverForTest?(message, copyText)
        guard !suppressNotificationsForTest else { return }
        notifyUser(message, copyText: copyText)
    }

    private func shouldRefuseSecureCaptureSynchronously(lease: Paster.TargetLease?) -> Bool {
        if AXClient.isSecureInputEnabled() { return true }
        if lease?.resolvedTargetIfReady?.isSecure == true { return true }
        if let resolveTargetOverrideForTest {
            let probed = OSAllocatedUnfairLock<PasteTarget?>(initialState: nil)
            resolveTargetOverrideForTest(lease) { target in
                probed.withLock { $0 = target }
            }
            if probed.withLock({ $0 })?.isSecure == true { return true }
        }
        return false
    }

    private func refuseSecureCapture(source: String) {
        pendingPurpose = nil
        hotkey.setCaptureActive(false)
        if session.isWarming {
            let warmingGen = session.activeCaptureGeneration
            let recorderMayOwnRoute = session.cancelCapture()
            if let warmingGen { utterances.removeValue(forKey: warmingGen) }
            targetCapture = nil
            if recorderMayOwnRoute { _ = endRecorderCapture(drainTail: false) }
            resetLiveDecoding()
            endInteractiveActivityIfIdle()
        }
        hotkey.clearHandsFree("a password or secure field is focused")
        status(session.isDelivering ? "FC…" : "FC")
        if !session.isDelivering {
            overlay {
                $0.setModeBadge(nil)
                $0.hide()
            }
        }
        log("hotkey \(source) refused — password or secure input field is active")
        notify(AXClient.secureBlockedMessage())
    }

    private func abortSecureCaptureIfOwned(generation: Int, source: String) {
        guard session.ownsCapture(generation) else { return }
        hotkey.setCaptureActive(false)
        hotkey.clearHandsFree("a password or secure field is focused")
        let recorderMayOwnRoute = session.cancelCapture()
        utterances.removeValue(forKey: generation)
        targetCapture = nil
        if recorderMayOwnRoute { _ = endRecorderCapture(drainTail: false) }
        resetLiveDecoding()
        endInteractiveActivityIfIdle()
        if session.isDelivering {
            status("FC…")
            overlay { $0.transcribing() }
        } else {
            status("FC")
            overlay {
                $0.setModeBadge(nil)
                $0.hide()
            }
        }
        log("session aborted (\(source)) — PasteTarget detected a password or secure field")
        notify(AXClient.secureBlockedMessage())
    }

    private func watchTargetLeaseForSecureField(_ lease: Paster.TargetLease?, generation: Int, source: String) {
        guard let lease else { return }
        Paster.resolveTargetCapture(lease) { [weak self] result in
            guard let self, case .captured(let captured) = result, captured.isSecure else { return }
            self.queue.async {
                self.abortSecureCaptureIfOwned(generation: generation, source: source)
            }
        }
    }

    // MARK: - Menu actions (F2)

    /// F1: the same latched session the double-tap starts, minus the keyboard. The monitor
    /// owns the latch, so both routes drive one state machine. Enqueued like every other
    /// transition, so this inherits the generation/single-flight discipline.
    func toggleHandsFree() {
        // This method is the menu-click boundary. Start the target lease before the session
        // hop; if the click is a stop/refusal the bounded lease is simply unused.
        let lease = Paster.beginTargetCaptureAtMenuBoundary()
        queue.async {
            if self.hotkey.isLatched {
                self.hotkey.stopLatched()
                return
            }
            guard !self.session.captureActive, !self.session.updateReserved else {
                log("hands-free ignored — a capture is already active")
                return
            }
            guard self.ready else {
                let state = self.modelLoadFailed ? "failed to load" : "not ready yet"
                log("hands-free ignored — ASR model \(state)")
                self.notify(self.modelLoadFailed
                    ? "The speech model failed to load. Use Retry speech model in the FlowClone menu."
                    : "FlowClone is still loading its speech model. Try again in a moment.")
                return
            }
            self.hotkey.startLatched("menu", targetLease: lease)
        }
    }

    func startWorkspaceCapture(_ purpose: CapturePurpose, lease: Paster.TargetLease?) {
        let target = lease ?? Paster.beginTargetCaptureAtMenuBoundary()
        queue.async {
            if self.hotkey.isLatched { self.hotkey.stopLatched(); return }
            guard !self.session.captureActive, !self.session.updateReserved, self.ready else {
                self.notify("Finish the current recording and wait for the speech model to be ready.")
                return
            }
            self.pendingPurpose = purpose
            self.hotkey.startLatched("action", targetLease: target)
        }
    }

    func stopCapture() { queue.async { if self.hotkey.isLatched { self.hotkey.stopLatched() } else { self.finish() } } }
    func cancelCapture() { hotkey.escapePressed() }
    func setPracticeMode(_ enabled: Bool) { queue.async { self.practiceMode = enabled } }
    func refreshMicrophonePolicy() { queue.async { self.recorder.refreshIdlePolicy() } }

    @MainActor func retranscribeHistory(_ item: History.Item) {
        guard let name = item.audioName, let url = HistoryAudio.url(name), History.canPersistDerived(from: item.id) else { return }
        queue.async {
            guard self.ready, !self.session.isBusy else {
                self.notify("Wait for the current dictation and speech model, then try again."); return
            }
            self.beginInteractiveActivityIfNeeded()
            let g = self.session.beginStandaloneDelivery()
            var ctx = UtteranceContext(generation: g, purpose: .draft, captureMode: .clean)
            ctx.parentResultID = item.id
            ctx.vocabularyCapture = VocabularyCapture(lease: nil)
            self.utterances[g] = ctx
            self.defaultPurpose = .draft
            self.status("FC…")
            Task {
                do {
                    let file = try AVAudioFile(forReading: url)
                    guard file.processingFormat.sampleRate > 0,
                          Double(file.length) / file.processingFormat.sampleRate <= 300 else { throw CocoaError(.fileReadCorruptFile) }
                    let samples = try AudioConverter().resampleAudioFile(url)
                    self.queue.async {
                        guard self.session.owns(g) else { return }
                        self.transcribeAndDeliver(samples, generation: g, origin: .repaste,
                            releasedAt: .now(), mode: .clean, target: nil, maxAttempts: 1)
                    }
                } catch {
                    self.queue.async {
                        if self.session.owns(g) {
                            self.endUI(for: g)
                            self.notify("The saved recording could not be read.")
                        }
                    }
                }
            }
        }
    }

    /// F2 menu: re-paste the most recent dictation through the same insert path a live
    /// utterance takes, so the frontmost-app guard, the `--sink` pin and the paste queue
    /// all apply unchanged. `text` is read from History by the caller — the main thread
    /// owns it — and the menu item is disabled while a session is in flight.
    func repasteLast(_ text: String, lease suppliedLease: Paster.TargetLease? = nil, fromDraft: Bool = false) {
        // Called on main after the status menu closes: begin binding immediately at the
        // accepted click. The bounded synchronous AX calls run only on the capture executor.
        let lease = suppliedLease ?? Paster.beginTargetCaptureAtMenuBoundary()
        queue.async { [self] in
            guard !self.session.isBusy else {
                log("repaste ignored — a session is in flight")
                return
            }
            self.beginInteractiveActivityIfNeeded()
            let g = self.session.beginStandaloneDelivery()
            let mode = Mode.current
            var ctx = UtteranceContext(generation: g, purpose: .editor(.literal), captureMode: mode)
            ctx.resultAlreadyInDraft = fromDraft
            self.utterances[g] = ctx
            self.defaultPurpose = .editor(.literal)
            let released = DispatchTime.now()
            self.status("FC…")
            self.resolveTarget(lease) { [weak self] target in
                guard let self else { return }
                self.queue.async {
                    guard self.session.owns(g) else { return }
                    self.insert(text, generation: g, .repaste, target, mode, 0, 0, released,
                                hadContextRewrite: false)
                }
            }
        }
    }

    /// Retries the one failed capture without touching disk. A click is one decoder
    /// attempt; the original live path already spent its automatic second attempt.
    func retryLastRecording(toDraft: Bool = false) {
        let lease = Paster.beginTargetCaptureAtMenuBoundary()
        queue.async { [self] in
            guard !self.session.isBusy else {
                log("audio retry ignored — a session is in flight")
                return
            }
            guard let capture = self.failedCaptures.current,
                  DispatchTime.now().uptimeNanoseconds
                    < capture.deadline.uptimeNanoseconds else {
                self.clearFailedCapture("expired before retry")
                return
            }
            self.beginInteractiveActivityIfNeeded()
            let g = self.session.beginStandaloneDelivery()
            let mode = Mode.current
            let chosenPurpose: CapturePurpose = toDraft ? .draft : .editor(.normal)
            var ctx = UtteranceContext(generation: g, purpose: chosenPurpose, captureMode: mode)
            ctx.vocabularyCapture = VocabularyCapture(lease: lease)
            self.utterances[g] = ctx
            self.defaultPurpose = chosenPurpose
            self.status("FC…")
            self.overlay { $0.transcribing() }
            self.resolveTarget(lease) { [weak self] target in
                guard let self else { return }
                self.queue.async {
                    guard self.session.owns(g) else { return }
                    self.transcribeAndDeliver(capture.samples, generation: g, origin: .retry,
                                              releasedAt: .now(), mode: mode, target: target,
                                              maxAttempts: 1)
                }
            }
        }
    }

    func undoLastLearnedCorrection() {
        AutoLearn.monitor.stop()
        queue.async {
            let undone = AutoLearn.undoLastLearnedBatch()
            if undone {
                Task { @MainActor in
                    StatusMenu.shared.clearLearnedCorrection()
                    NotificationCenter.default.post(name: AutoLearn.didChange, object: nil)
                }
            }
            self.notify(undone ? "Last learned correction undone."
                               : "Could not undo — the corrections changed afterward.")
        }
    }

    /// Fire-and-forget: the overlay never blocks the paste path.
    private func overlay(_ change: @MainActor @Sendable @escaping (Overlay) -> Void) {
        guard !suppressOverlayForTest else { return }
        let enqueued = DispatchTime.now()
        DispatchQueue.main.async {
            let waited = ms(enqueued, .now())
            if waited > 100 { log(String(format: "DIAG overlay hop was blocked %.0fms", waited)) }
            change(Overlay.shared)
        }
    }

    // MARK: - Session state machine (session queue)

    func handle(_ edge: HotkeyEdge) {
        switch edge {
        case .down(let src):
            // Created on the event-tap flagsChanged boundary, before this session-queue hop.
            // Take it even when refusing the press so no later action can inherit it.
            let lease = hotkey.takeTargetLease()
            guard !session.updateReserved else {
                hotkey.clearHandsFree("an update is installing")
                return
            }
            if shouldRefuseSecureCaptureSynchronously(lease: lease) {
                refuseSecureCapture(source: src)
                return
            }
            // Cold double-tap hands-free: if Tap 1 released while cold `AudioDeviceStart`
            // (~450ms) is still warming and Tap 2 `.down` arrives, resume the already-warming
            // capture instead of dropping Tap 2 at `guard !session.captureActive`.
            if session.isWarming, session.pendingRelease, session.resumeWarmingCapture() {
                if let g = session.activeCaptureGeneration {
                    if let lease {
                        targetCapture = TargetCaptureOwnership(generation: g, lease: lease)
                        watchTargetLeaseForSecureField(lease, generation: g, source: src)
                    }
                    hotkey.setCaptureActive(true)
                    scheduleOrEngageSideEffects(for: g, source: src, handsFree: session.handsFree)
                }
                return
            }
            guard !session.captureActive else { return }
            guard ready else {
                let why = modelLoadFailed ? "the speech model failed to load"
                                          : "the speech model is not loaded yet"
                log("hotkey \(src) ignored — \(why)")
                hotkey.clearHandsFree(why)
                if modelLoadFailed {
                    notify("Use Retry speech model in the FlowClone menu.")
                }
                return
            }
            if session.transcribing {
                log("hotkey \(src) accepted during active transcription (generations=\(session.deliveringGenerations))")
            }
            beginInteractiveActivityIfNeeded()
            resetLiveDecoding()
            let chosenPurpose = pendingPurpose ?? (practiceMode ? .practice : .editor(.normal))
            pendingPurpose = nil
            defaultPurpose = chosenPurpose
            let chosenMode: Mode = chosenPurpose.usesCleanup ? Mode.current : .raw
            if practiceMode { DispatchQueue.main.async { DictationWorkspace.shared.shortcutObserved = true } }
            let g = session.beginCapture()
            var ctx = UtteranceContext(generation: g, purpose: chosenPurpose, captureMode: chosenMode)
            if chosenPurpose.usesCleanup {
                let cloudDictationAllowed = (chosenMode == .clean && RepairReviewer.backend() == .claude)
                    || (chosenMode == .prompt && RepairReviewer.setting != .onDevice)
                if cloudDictationAllowed {
                    AnthropicClient.prewarmIfConfigured()
                }
                let vocabCapture = VocabularyCapture(lease: lease)
                ctx.vocabularyCapture = vocabCapture
                Task {
                    let configuration = await vocabCapture.task.value
                    self.queue.async {
                        guard self.session.owns(g) else { return }
                        self.utterances[g]?.vocabulary = configuration
                        if self.session.ownsCapture(g), chosenPurpose == .editor(.normal) {
                            let badge: PillModeBadge? = switch configuration.appProfile.preferredMode {
                            case .global, .clean: nil
                            case .prompt: .prompt
                            case .literal: .literal
                            }
                            self.overlay { $0.setModeBadge(badge) }
                        }
                    }
                }
            }
            utterances[g] = ctx
            targetCapture = TargetCaptureOwnership(generation: g, lease: lease)
            watchTargetLeaseForSecureField(lease, generation: g, source: src)
            scheduleOrEngageSideEffects(for: g, source: src, handsFree: session.handsFree)
            // A-1: the Pipeline owns the Esc-swallow mirror, so it arms only for a press
            // that was actually accepted — every refusal above left it untouched.
            hotkey.setCaptureActive(true)
            status("FC…")
            overlay { $0.warming() }
            let primeRequestedAt = DispatchTime.now()
            primeMicrophoneRoute { [weak self] primed, waited in
                self?.inputReady(primed, waitedForPrime: waited,
                                 primeRequestedAt: primeRequestedAt,
                                 generation: g, source: src)
            }
        case .up:
            if session.isWarming {
                let warmingGen = session.activeCaptureGeneration
                let warmingPurpose = warmingGen.flatMap { utterances[$0]?.purpose } ?? defaultPurpose
                let warmingSelfTest = warmingGen.flatMap { utterances[$0]?.isSelfTest } ?? selfTesting
                if session.markPendingRelease() {
                    cancelPendingSideEffectsDebounce()
                    hotkey.setCaptureActive(false)
                    // Arm hands-free immediately so a second quick tap during cold
                    // `AudioDeviceStart` (~450ms) latches instead of being dropped.
                    if !warmingSelfTest, warmingPurpose == .editor(.normal) {
                        hotkey.armIfTap()
                        armTapObserverForTest?()
                    }
                    return
                }
                if let warmingGen { utterances.removeValue(forKey: warmingGen) }
                session.cancelCapture()
                endInteractiveActivityIfIdle()
                targetCapture = nil
                hotkey.setCaptureActive(false)
                hotkey.clearHandsFree("the microphone route was still warming")
                status(session.isDelivering ? "FC…" : "FC!")
                if !session.isDelivering { overlay { $0.failure() } }
                log("session aborted — hotkey released while microphone route was warming")
                notify("The microphone was still warming up. Hold the hotkey and try again.")
                return
            }
            finish()
        case .latched:
            // F-3: the monitor latched the press that just started (or resumed) this session;
            // the 300s cap and the pinned cue attach here.
            guard session.captureActive else {
                hotkey.clearHandsFree("there was no session to latch")
                return
            }
            _ = session.setHandsFree(true)
            updateRecorderCap(seconds: Recorder.handsFreeMaxSeconds)
            if let g = session.activeCaptureGeneration {
                flushDebouncedSideEffectsNow(for: g)
            }
            status(session.isWarming ? "FC…" : "FC●")
            overlay { $0.handsFree(true) }
        case .cancel(let why):
            hotkey.setCaptureActive(false)
            guard session.captureActive else { hotkey.clearHandsFree(why); return }
            let cancelledGen = session.activeCaptureGeneration
            let recorderMayOwnRoute = session.cancelCapture()
            if let cancelledGen { utterances.removeValue(forKey: cancelledGen) }
            targetCapture = nil
            if recorderMayOwnRoute { _ = endRecorderCapture(drainTail: false) }
            resetLiveDecoding()
            endInteractiveActivityIfIdle()
            if session.isDelivering {
                status("FC…")
                overlay { $0.transcribing() }
            } else {
                status("FC")
                overlay {
                    $0.setModeBadge(nil)
                    $0.hide()
                }
            }
            log("session cancelled — \(why)")
        }
    }

    private func primeMicrophoneRoute(_ completion: @escaping @Sendable (Bool, Bool) -> Void) {
        if let primeOverrideForTest {
            primeOverrideForTest(completion)
        } else {
            recorder.primeAsync(completion)
        }
    }

    private func beginRecorderCapture(capSeconds: Double, requestID: String,
                                      completion: @escaping @Sendable (Bool) -> Void) {
        if let beginCaptureOverrideForTest {
            beginCaptureOverrideForTest(capSeconds, requestID, completion)
        } else {
            recorder.begin(capSeconds: capSeconds, requestID: requestID, completion: completion)
        }
    }

    private func endRecorderCapture(drainTail: Bool = true) -> [Float] {
        if let endCaptureOverrideForTest {
            return endCaptureOverrideForTest(drainTail)
        }
        return recorder.end(drainTail: drainTail)
    }

    private func updateRecorderCap(seconds: Double) {
        if let updateCapOverrideForTest {
            updateCapOverrideForTest(seconds)
        } else {
            recorder.updateCap(seconds: seconds)
        }
    }

    private func resolveTarget(_ lease: Paster.TargetLease?,
                               completion: @escaping @Sendable (PasteTarget?) -> Void) {
        if let resolveTargetOverrideForTest {
            resolveTargetOverrideForTest(lease, completion)
            return
        }
        Paster.resolveTargetCapture(lease) { result in
            switch result {
            case .captured(let captured): completion(captured)
            case .refused: completion(nil)
            }
        }
    }

    private func inputReady(_ primed: Bool, waitedForPrime: Bool,
                            primeRequestedAt: DispatchTime,
                            generation: Int, source: String) {
        guard session.ownsCapture(generation), session.isWarming else { return }
        let primeWaitMS = ms(primeRequestedAt, .now())
        let keyReleased = session.pendingRelease
            || (hotkey.isRunning && !Self.isHotkeyPhysicallyHeld(source: source))
        if Self.shouldAbortForPrimeWait(
            waitedForPrime: waitedForPrime,
            primeWaitMS: primeWaitMS,
            keyReleased: keyReleased,
            handsFree: session.handsFree
        ) {
            utterances.removeValue(forKey: generation)
            session.cancelCapture()
            endInteractiveActivityIfIdle()
            targetCapture = nil
            hotkey.setCaptureActive(false)
            hotkey.clearHandsFree("the microphone route had to warm up first")
            if primed {
                status(session.isDelivering ? "FC…" : "FC")
                if !session.isDelivering { overlay { $0.ready() } }
                log(String(format: "mic route is ready after %.0fms prime — hotkey already released, requiring fresh press",
                           primeWaitMS))
                notify("Microphone is ready. Release the hotkey, then hold it again to dictate.")
            } else {
                status(session.isDelivering ? "FC…" : "FC!")
                if !session.isDelivering { overlay { $0.failure() } }
                log("session aborted — microphone route could not be prepared")
                notify("FlowClone couldn't prepare a microphone. Check the input device and try again.")
            }
            return
        }
        if !primed {
            log("mic route prime did not find a ready device — trying full recorder fallback")
        }
        session.markOpenInFlight(for: generation)
        beginRecorderCapture(
            capSeconds: session.handsFree ? Recorder.handsFreeMaxSeconds : Recorder.maxSeconds,
            requestID: DeliveryMetrics.requestID(generation: generation)
        ) { [weak self] opened in
            self?.inputOpened(opened, generation: generation, source: source)
        }
    }

    /// Session queue, from `Recorder.begin`'s completion.
    private func inputOpened(_ opened: Bool, generation: Int, source: String) {
        guard session.ownsCapture(generation) else {
            if !session.openInFlight && !session.isRecording {
                _ = endRecorderCapture(drainTail: false)
            }
            return
        }
        guard opened else {
            utterances.removeValue(forKey: generation)
            session.cancelCapture()
            endInteractiveActivityIfIdle()
            targetCapture = nil
            hotkey.setCaptureActive(false)
            hotkey.clearHandsFree("the microphone could not be opened")
            log("session aborted — mic unavailable")
            status(session.isDelivering ? "FC…" : "FC!")
            if !session.isDelivering { overlay { $0.failure() } }
            notify("FlowClone couldn't open a microphone. Try again after checking the input device.")
            return
        }
        guard session.markRecorderReady(for: generation) else {
            hotkey.setCaptureActive(false)
            _ = endRecorderCapture(drainTail: false)
            return
        }
        if let pressed = session.pressedAt {
            log(String(format: "CAPTURE_METRIC generation=%d press_to_ready_ms=%.1f",
                       generation, ms(pressed, .now())))
        }
        if session.pendingRelease {
            // The hotkey was already released and not latched by a second tap.
            finish()
            return
        }
        let handsFree = session.handsFree
        triggerStartCueOnRecorderOpen(for: generation)
        status("FC●")
        overlay { $0.recording() }
        startLiveDecoding()
        log(handsFree
            ? "session start (\(source), hands-free — \(Int(Recorder.handsFreeMaxSeconds))s cap)"
            : "session start (\(source))")

        // Stop the preceding paste's edit lease without waiting for an AX round-trip.
        AutoLearn.monitor.stop()
    }

    // MARK: - Live decoding

    /// Nemotron streaming and the pill's live text for the running session. Session queue.
    private func startLiveDecoding() {
        resetLiveDecoding()
        guard !selfTesting else { return }
        startStreaming()
        startPreview()
    }

    /// Called when a session begins or dies, so no decode outlives the audio it came from.
    private func resetLiveDecoding() {
        stopPreview()
        stopStreaming(discard: true)
    }

    /// Nemotron recognition runs whether or not the visual preview is enabled. Only one
    /// feed is outstanding; release waits for that physical call, then feeds the exact tail.
    private func startStreaming() {
        guard transcriber.engine == .nemotron,
              let generation = session.activeCaptureGeneration else { return }
        streamingGeneration = generation
        streamingOffset = 0
        streamingRevision = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.16, repeating: 0.16, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.feedStreaming() }
        timer.resume()
        streamingTimer = timer
    }

    private func stopStreaming(discard: Bool = false) {
        streamingTimer?.cancel()
        streamingTimer = nil
        streamingTask?.cancel()
        streamingTask = nil
        streamingBusy = false
        if discard, let generation = streamingGeneration {
            let transcriber = transcriber
            Task { await transcriber.cancelStream(generation: generation) }
            streamingGeneration = nil
            streamingOffset = 0
            streamingRevision = nil
        }
    }

    private func feedStreaming() {
        guard session.isRecording, !streamingBusy, ready,
              let generation = streamingGeneration, session.ownsCapture(generation),
              !session.deliveringGenerations.contains(where: { $0 < generation }),
              let slice = recorder.streamingSnapshot(after: streamingOffset, revision: streamingRevision) else { return }
        streamingBusy = true
        let transcriber = transcriber
        streamingTask = Task {
            let update = await transcriber.stream(slice.samples, offset: slice.offset,
                generation: generation, revision: slice.revision)
            let cancelled = Task.isCancelled
            self.queue.async {
                guard self.session.ownsCapture(generation), self.session.isRecording,
                      self.streamingGeneration == generation, !cancelled else { return }
                self.streamingTask = nil
                self.streamingBusy = false
                guard let update else { return }
                self.streamingOffset = update.sampleCount
                self.streamingRevision = slice.revision
                guard Overlay.livePartialEnabled, !update.text.isEmpty,
                      !AXClient.isSecureInputEnabled() else { return }
                let ctx = self.utterances[generation]
                let usesCleanup = (ctx?.purpose ?? self.defaultPurpose).usesCleanup
                let vocab = ctx?.vocabulary
                let profile = vocab?.appProfile ?? .unnamedDefault
                let previewMode = usesCleanup ? profile.effectiveMode(default: ctx?.captureMode ?? Mode.current) : .raw
                let shown = previewMode != .raw
                    ? Cleaner.cleanWithChanges(update.text, configuration: vocab, bundleID: vocab?.bundleID).text
                    : update.text
                self.overlay { $0.partial(shown) }
            }
        }
    }

    /// Live partial text. Runs in EVERY mode — Clean and Raw have no rewrite to overlap but
    /// they still have a pill — and only while the setting is on.
    private func startPreview() {
        stopPreview()
        guard transcriber.engine == .parakeet, Overlay.livePartialEnabled else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.preview() }
        t.resume()
        previewTimer = t
    }

    /// Stops the preview and clears the pill. Called at release, so a decode cannot queue
    /// ahead of the release ASR and a stale transcript cannot outlive its recording.
    private func stopPreview() {
        previewTimer?.cancel()
        previewTimer = nil
        previewTask?.cancel()
        previewTask = nil
        previewTaskOwner = nil
        previewBusy = false
        overlay { $0.clearPartial() }
    }

    private func preview() {
        guard session.isRecording, !previewBusy, ready, Overlay.livePartialEnabled,
              !session.isDelivering,
              let g = session.activeCaptureGeneration,
              SpeechGate.hasRecentSpeech(recorder.snapshot(lastSeconds: 1)) else { return }
        // Cap live Parakeet `.preview` window to the trailing 10s (`160_000` samples) so
        // key-up `.final` never stalls behind a non-preemptible 30s preview pass.
        let snapshot = recorder.snapshot(lastSeconds: Self.previewWindowSeconds)
        let audio = snapshot.count > Self.previewMaxSamples
            ? Array(snapshot.suffix(Self.previewMaxSamples))
            : snapshot
        guard audio.count > 8_000 else { return }          // 0.5s — less says nothing yet
        previewBusy = true
        previewTaskOwner = g
        let runtime = runtime
        previewTask = Task {
            let outcome = await runtime.transcribeInteractive(audio, maxAttempts: 1, priority: .preview)
            let cancelled = Task.isCancelled
            self.queue.async {
                guard self.previewTaskOwner == g, self.session.ownsCapture(g) else { return }
                self.previewTask = nil
                self.previewTaskOwner = nil
                self.previewBusy = false
                guard self.session.isRecording, !cancelled,
                      !AXClient.isSecureInputEnabled(),
                      case .success(let text, _, _) = outcome, !text.isEmpty else { return }
                let ctx = self.utterances[g]
                let usesCleanup = (ctx?.purpose ?? self.defaultPurpose).usesCleanup
                let vocab = ctx?.vocabulary
                let profile = vocab?.appProfile ?? .unnamedDefault
                let previewMode = usesCleanup ? profile.effectiveMode(default: ctx?.captureMode ?? Mode.current) : .raw
                let shown = previewMode != .raw
                    ? Cleaner.cleanWithChanges(text, configuration: vocab, bundleID: vocab?.bundleID).text
                    : text
                self.overlay { $0.partial(shown) }
            }
        }
    }

    private func finish() {
        guard session.isRecording, let generation = session.activeCaptureGeneration else { return }
        hotkey.setCaptureActive(false)
        let released = DispatchTime.now()
        let targetLease = takeTargetCapture(for: generation)
        let held = session.heldSeconds(now: released)
        let wasHandsFree = session.finishCapture(at: released)
        stopPreview()
        stopStreaming()
        let samples = endRecorderCapture(drainTail: true)
        utterances[generation]?.streamRevision = recorder.endedStreamRevision
        let isSelfTestRun = utterances[generation]?.isSelfTest ?? selfTesting
        process(samples, generation: generation, releasedAt: released, heldSeconds: held,
                origin: isSelfTestRun ? .selfTest : .utterance,
                targetLease: targetLease, wasHandsFree: wasHandsFree)
    }

    private func inputFailed(_ samples: [Float], reason: String) {
        guard session.isRecording, let generation = session.activeCaptureGeneration else { return }
        hotkey.setCaptureActive(false)
        let targetLease = takeTargetCapture(for: generation)
        let held = session.heldSeconds()
        let wasHandsFree = session.finishCapture()
        stopPreview()
        stopStreaming()
        hotkey.clearHandsFree(reason)      // a latch can never outlive its capture
        let seconds = Double(samples.count) / Recorder.sampleRate
        if samples.count > 1_600, SpeechGate.analyze(samples).speech {
            log(String(format: "microphone route failed after %.1fs (%@) — processing captured prefix",
                       seconds, reason))
            notify("Microphone disconnected — FlowClone is using the audio captured before it stopped.")
            process(samples, generation: generation, releasedAt: .now(), heldSeconds: held,
                    origin: .partialUtterance, targetLease: targetLease,
                    wasHandsFree: wasHandsFree)
            return
        }
        utterances.removeValue(forKey: generation)
        session.cancelCapture()
        stopStreaming(discard: true)
        endInteractiveActivityIfIdle()
        status(session.isDelivering ? "FC…" : "FC!")
        if !session.isDelivering { overlay { $0.failure() } }
        log("session aborted — microphone delivered no usable audio after fallback (\(reason))")
        notify("The microphone stopped sending audio and FlowClone couldn't recover. Try the hotkey again.")
    }

    /// Shared by the live path and the self-test. Supports queueing Utterance N+1 behind an
    /// active Utterance N in `session.deliveringGenerations` so back-to-back dictations
    /// finalize and paste in strict FIFO order.
    private func process(_ samples: [Float], generation g: Int, releasedAt: DispatchTime,
                         heldSeconds: Double?, origin: DictationOrigin,
                         targetLease: Paster.TargetLease?, wasHandsFree: Bool) {
        let tag = origin.tag
        let ctx = utterances[g]
        let currentPurpose = ctx?.purpose ?? defaultPurpose
        if wasHandsFree { overlay { $0.handsFree(false) } }
        let seconds = Double(samples.count) / Recorder.sampleRate
        guard samples.count >= 1600 else {          // < 0.1s of audio
            stopStreaming(discard: true)
            DeliveryMetrics(generation: g, releasedAt: releasedAt,
                            requestedMode: Mode.current.rawValue, effectiveMode: "none").record(outcome: "capture_too_short")
            log("\(tag): nothing recorded (\(samples.count) samples) — discarded")
            if origin.canArmHandsFreeTap, currentPurpose == .editor(.normal) {
                hotkey.armIfTap()
                armTapObserverForTest?()
            }
            if let held = heldSeconds, held > 1.0 {
                notify("Nothing was recorded — the microphone took too long to open. Try again.")
            }
            utterances.removeValue(forKey: g)
            session.endDelivery(owner: g)
            endInteractiveActivityIfIdle()
            if session.isDelivering {
                status("FC…")
                overlay { $0.transcribing() }
            } else {
                status("FC")
                overlay {
                    $0.setModeBadge(nil)
                    $0.hide()
                }
            }
            return
        }
        let gate = SpeechGate.analyze(samples)
        guard gate.speech else {
            stopStreaming(discard: true)
            DeliveryMetrics(generation: g, releasedAt: releasedAt,
                            requestedMode: Mode.current.rawValue, effectiveMode: "none").record(outcome: "speech_gated")
            log(String(format: "%@: no speech detected (%.1fs, %@)", tag, seconds, gate.detail))
            if SpeechGate.shouldRetainForRetry(samples, heldSeconds: heldSeconds),
               retainFailedCapture(samples, for: origin, purpose: currentPurpose) {
                notify("No speech detected. If you spoke, use Retry failed recording in the FlowClone menu.")
            }
            if origin.canArmHandsFreeTap, currentPurpose == .editor(.normal) {
                hotkey.armIfTap()
                armTapObserverForTest?()
            }
            utterances.removeValue(forKey: g)
            session.endDelivery(owner: g)
            endInteractiveActivityIfIdle()
            if session.isDelivering {
                status("FC…")
                overlay { $0.transcribing() }
            } else {
                status("FC")
                overlay {
                    $0.setModeBadge(nil)
                    $0.hide()
                }
            }
            return
        }

        let mode = ctx?.captureMode ?? (currentPurpose.usesCleanup ? Mode.current : .raw)
        session.beginDelivery(owner: g)
        processingCueHandler()
        if !session.captureActive {
            status("FC…")
            overlay { $0.transcribing() }
        }

        let item = PendingFinalization(
            samples: samples,
            generation: g,
            origin: origin,
            releasedAt: releasedAt,
            mode: mode,
            targetLease: targetLease,
            maxAttempts: 2
        )
        if session.isActiveDeliveryHead(g) {
            startFinalization(item)
        } else {
            log("\(tag): queued generation \(g) behind in-flight delivery \(session.deliveringGenerations)")
            pendingFinalizations.append(item)
        }
    }

    private func startFinalization(_ item: PendingFinalization) {
        let g = item.generation
        let tag = item.origin.tag
        guard session.ownsDelivery(g) else { return }
        if !session.captureActive {
            status("FC…")
            overlay { $0.transcribing() }
        }
        resolveTarget(item.targetLease) { [weak self] target in
            guard let self else { return }
            self.queue.async {
                guard self.session.ownsDelivery(g) else {
                    log("\(tag): target binding dropped (delivery \(g) no longer active)")
                    return
                }
                self.transcribeAndDeliver(item.samples, generation: g, origin: item.origin,
                                          releasedAt: item.releasedAt, mode: item.mode,
                                          target: target, maxAttempts: item.maxAttempts)
            }
        }
    }

    private func drainPendingFinalizations() {
        pendingFinalizations.removeAll { !session.ownsDelivery($0.generation) }
        guard let next = pendingFinalizations.first,
              session.isActiveDeliveryHead(next.generation) else { return }
        pendingFinalizations.removeFirst()
        startFinalization(next)
    }

    private func takeTargetCapture(for generation: Int) -> Paster.TargetLease? {
        guard let ownership = targetCapture,
              ownership.generation == generation else { return nil }
        targetCapture = nil
        return ownership.lease
    }

    private func transcribeAndDeliver(_ samples: [Float], generation g: Int,
                                      origin: DictationOrigin,
                                      releasedAt: DispatchTime, mode: Mode,
                                      target: PasteTarget?, maxAttempts: Int) {
        let tag = origin.tag
        let currentPurpose = utterances[g]?.purpose ?? defaultPurpose
        let parentID = utterances[g]?.parentResultID
        utterances[g]?.resultTargetApp = target?.app.bundleID
        utterances[g]?.audioForHistory = currentPurpose == .practice || parentID != nil ? nil : samples
        let ruleCapture = utterances[g]?.vocabularyCapture
        let seconds = Double(samples.count) / Recorder.sampleRate
        utterances[g]?.deliveryMetrics = DeliveryMetrics(
            generation: g,
            releasedAt: releasedAt,
            requestedMode: mode.rawValue,
            effectiveMode: mode == .raw ? "raw" : "clean"
        )
        let requestID = DeliveryMetrics.requestID(generation: g)
        let streamGeneration = origin == .utterance ? g : nil
        let streamRevision = utterances[g]?.streamRevision ?? recorder.endedStreamRevision
        let runtime = runtime
        Task {
            let configuration = await ruleCapture?.task.value
            let contextCapture = DictationContextCapture.shared.start { deadline in
                target?.captureDictationContext(deadline: deadline) ?? .empty
            }
            let t0 = DispatchTime.now()
            let outcome = await runtime.transcribeInteractive(
                samples,
                maxAttempts: maxAttempts,
                priority: .final,
                requestID: requestID,
                streamGeneration: streamGeneration,
                streamRevision: streamRevision,
                maxPause: PauseCompactor.maxPause
            )
            let asrFinished = DispatchTime.now()
            let asrMs = ms(t0, .now())
            let context = contextCapture.take()
            self.queue.async {
                guard self.session.ownsDelivery(g) else {
                    log("\(tag): stale ASR result dropped (delivery \(g) cancelled)")
                    return
                }
                self.utterances[g]?.deliveryMetrics?.asrFinished = asrFinished
                if let configuration {
                    self.utterances[g]?.vocabulary = configuration
                }
                log("\(tag): local context \(context.terms.count) term(s), prefix \(context.continuationPrefix?.count ?? 0) chars")
                switch outcome {
                case .success(let text, _, let metadata):
                    if let metadata {
                        log(String(format: "ASR_RESULT generation=%d confidence=%.3f tokens=%d model_ms=%.1f unknown_tokens=%d request_id=%@",
                                   g, metadata.confidence, metadata.tokens.count, metadata.processingSeconds * 1000,
                                   metadata.unknownTokenCount, requestID))
                    }
                    self.deliver(text, g, origin, seconds, asrMs, releasedAt, mode,
                                 target, context, unknownTokenCount: metadata?.unknownTokenCount ?? 0)
                case .failed:
                    self.utterances[g]?.audioForHistory = nil
                    self.utterances[g]?.deliveryMetrics?.record(outcome: "asr_failed")
                    let retained = self.retainFailedCapture(samples, for: origin, purpose: currentPurpose)
                    self.utterances.removeValue(forKey: g)
                    self.session.endDelivery(owner: g)
                    self.drainPendingFinalizations()
                    self.endInteractiveActivityIfIdle()
                    if self.session.isRecording {
                        self.status("FC●")
                    } else if self.session.isWarming || self.session.isDelivering {
                        self.status("FC…")
                    } else {
                        self.status("FC!")
                        self.overlay { $0.failure() }
                    }
                    log(String(format: "%@: transcription failed (audio %.1fs, %.0fms)",
                               tag, seconds, asrMs))
                    if retained {
                        self.notify("Transcription failed twice. Use Retry failed recording in the FlowClone menu.")
                    } else if origin.commitsFailedRecovery {
                        self.notify("Retry failed. The recording remains available for another try.")
                    } else {
                        self.notify("Transcription failed. No user recording was replaced.")
                    }
                }
            }
        }
    }

    private func deliver(_ text: String?, _ g: Int, _ origin: DictationOrigin,
                         _ seconds: Double,
                         _ asrMs: Double, _ releasedAt: DispatchTime, _ requestedMode: Mode,
                         _ target: PasteTarget?, _ context: DictationContext,
                         unknownTokenCount: Int = 0) {
        let tag = origin.tag
        guard session.ownsDelivery(g) else { log("\(tag): stale result dropped (delivery \(g) ended)"); return }
        if target?.isSecure == true || AXClient.isSecureInputEnabled() {
            utterances[g]?.audioForHistory = nil
            utterances[g]?.cleanStage = nil
            utterances[g]?.deliveryMetrics?.record(outcome: "secure_field_blocked")
            log("\(tag): blocked delivery into password or secure field — transcript and audio discarded")
            notify(AXClient.secureBlockedMessage())
            endUI(for: g)
            return
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            utterances[g]?.deliveryMetrics?.record(outcome: "empty_transcript")
            log(String(format: "%@: empty transcript (audio %.1fs, transcribe %.0fms)", tag, seconds, asrMs))
            endUI(for: g)
            return
        }
        let currentPurpose = utterances[g]?.purpose ?? defaultPurpose
        let currentVocab = utterances[g]?.vocabulary
        let bundleID = target?.app.bundleID ?? currentVocab?.bundleID
        let profile: ResolvedAppProfile = if let currentVocab, currentVocab.bundleID != nil {
            currentVocab.appProfile
        } else {
            AppProfiles.shared.resolve(bundleID: bundleID)
        }
        let mode: Mode = (currentPurpose.usesCleanup && Mode.testOverride == nil && origin != .selfTest)
            ? profile.effectiveMode(default: requestedMode)
            : requestedMode
        if mode != requestedMode {
            utterances[g]?.deliveryMetrics?.effectiveMode = mode == .raw ? "raw" : "clean"
        }
        if case .instruction(let instructionGeneration) = currentPurpose {
            DispatchQueue.main.async { TransformController.shared.receiveInstruction(text, generation: instructionGeneration) }
            endUI(for: g)
            return
        }
        if currentPurpose.input.isVerbatim || currentPurpose == .practice {
            do {
                let output = currentPurpose.input == .spelling ? try SpellingParser.parse(text) : text
                if currentPurpose != .practice {
                    commitHistory(for: g, raw: text, final: output, origin: origin, seconds: seconds, mode: .raw)
                    if !suppressPersistenceForTest {
                        TranscriptionStats.record(text, seconds: seconds, origin: origin)
                    }
                }
                insert(output, generation: g, origin, target, .raw, seconds, asrMs, releasedAt, hadContextRewrite: false)
            } catch {
                commitHistory(for: g, raw: text, final: text, origin: origin, seconds: seconds, mode: .raw)
                recoverResult(for: g, text, state: .notInserted)
                notify("Spelling was not recognized. The original transcript is in Draft.")
                endUI(for: g)
            }
            return
        }
        if !suppressPersistenceForTest {
            TranscriptionStats.record(text, seconds: seconds, origin: origin)
        }
        logBody("\(tag) transcript", text)   // redteam H1: shape by default
        if currentPurpose.learns, origin.acceptsSpokenCorrection, let c = Cleaner.parseCorrectionCommand(text) {
            do {
                let result = try PersonalizationStore.shared.upsertCorrection(
                    wrong: c.wrong, right: c.right)
                switch result {
                case .added(let token):
                    AutoLearn.rememberUndo(token)
                    logBody("learned correction added", "\(c.wrong) -> \(c.right)")
                    notify("Learned a spelling correction. Open the FlowClone menu to review or undo.")
                    Task { @MainActor in
                        StatusMenu.shared.showLearnedCorrection("\(c.wrong) → \(c.right)")
                    }
                case .replaced(let token):
                    AutoLearn.rememberUndo(token)
                    logBody("learned correction replaced", "\(c.wrong) -> \(c.right)")
                    notify("Updated a spelling correction. Open the FlowClone menu to review or undo.")
                    Task { @MainActor in
                        StatusMenu.shared.showLearnedCorrection("\(c.wrong) → \(c.right)")
                    }
                case .unchanged:
                    logBody("spoken correction already present", "\(c.wrong) -> \(c.right)")
                    notify("That correction is already learned.")
                }
                commitHistory(for: g, raw: text, final: text, origin: origin, seconds: seconds, mode: mode)
                let id = utterances[g]?.resultID ?? UUID()
                DispatchQueue.main.async { History.updateDelivery(id: id, state: .learned) }
            } catch {
                commitHistory(for: g, raw: text, final: text, origin: origin, seconds: seconds, mode: mode)
                recoverResult(for: g, text, state: .notInserted)
                log("spoken correction was not saved: \(error)")
                notify("Could not save that correction. The command remains in FlowClone History.")
            }
            utterances[g]?.deliveryMetrics?.record(outcome: "correction_command_history")
            endUI(for: g)
            return
        }

        let contextual = mode == .raw
            ? ContextVocabulary.RewriteResult(text: text, changes: [])
            : ContextVocabulary.rewrite(text, using: context.terms)
        if !contextual.changes.isEmpty {
            log("\(tag): applied \(contextual.changes.count) local context match(es)")
        }
        let hadContextRewrite = !contextual.changes.isEmpty
        let staged = mode == .raw ? nil : Cleaner.stage(contextual.text, configuration: currentVocab, bundleID: bundleID)
        if let staged, !staged.repairs.isEmpty {
            log("\(tag): spoken self-repair applied (\(staged.repairs.joined(separator: ", ")))")
        }
        if let staged, !staged.changes.isEmpty {
            log("\(tag): applied \(staged.changes.count) dictionary match(es)")
        }
        let preSnippetClean = mode == .raw ? text : (staged?.preSnippetText ?? "")
        if preSnippetClean.isEmpty, !(staged?.hasSnippets ?? false) {
            utterances[g]?.deliveryMetrics?.record(outcome: "empty_after_cleanup")
            log("\(tag): nothing left after cleanup — not pasting")
            endUI(for: g)
            return
        }

        let preReviewClean = mode == .raw ? text : (staged?.preReviewText ?? preSnippetClean)
        let preCommandLine = mode != .raw && SlashCommands.isCommandLine(preReviewClean)
        let dictionaryTerms: [String] = currentVocab?.entries
            .filter { $0.kind == .dictionary }
            .map(\.primary) ?? []
        let learnedCorrections: [(wrong: String, right: String)] = currentVocab?.entries
            .compactMap { entry -> (String, String)? in
                guard entry.kind == .correction, let right = entry.replacement else { return nil }
                return (entry.primary, right)
            } ?? []
        if mode == .prompt, !preCommandLine, let staged {
            let promptCleaned = staged.finish().text
            if promptCleaned.isEmpty {
                utterances[g]?.deliveryMetrics?.record(outcome: "empty_after_cleanup")
                log("\(tag): nothing left after cleanup — not pasting")
                endUI(for: g)
                return
            }
            if !SlashCommands.isCommandLine(promptCleaned) {
                // Keep private expanded snippet bodies (including {{clipboard}}) strictly on-device.
                let allowPromptCloud = Self.promptCloudAllowed(hadContextRewrite: hadContextRewrite,
                                                               hasSnippets: staged.hasSnippets)
                if !Prompter.eligible(promptCleaned, allowCloud: allowPromptCloud) {
                    log("prompt: input too long (\(promptCleaned.count) chars) — using Clean")
                } else if Prompter.ready(allowCloud: allowPromptCloud) {
                    utterances[g]?.cleanStage = promptCleaned
                    if promptCleaned != text { logBody("\(tag) cleaned", promptCleaned) }
                    promptRewrite(promptCleaned, raw: text, g, tag, seconds, asrMs, releasedAt, mode,
                                  target, context, hadContextRewrite,
                                  allowCloud: allowPromptCloud, dictionaryTerms: dictionaryTerms,
                                  origin: origin)
                    return
                }
            }
        }
        let finishClean: @Sendable (String?, Bool) -> Void = { reviewedPreSnippet, hadModelEdit in
            let cleaned = mode == .raw
                ? text
                : (staged?.finish(reviewedPreSnippet).text ?? "")
            self.utterances[g]?.cleanStage = cleaned
            if cleaned != text { logBody("\(tag) cleaned", cleaned) }
            guard !cleaned.isEmpty else {
                self.utterances[g]?.deliveryMetrics?.record(outcome: "empty_after_cleanup")
                log("\(tag): nothing left after cleanup — not pasting")
                self.endUI(for: g)
                return
            }
            let commandLine = mode != .raw && SlashCommands.isCommandLine(cleaned)
            let listed = mode == .raw || commandLine ? cleaned : SmartFormat.autoList(cleaned)
            let final = self.formatInsertion(listed, generation: g, raw: text, mode: mode, target: target, context: context)
            if final != cleaned { logBody("\(tag) continuation", final) }
            self.commitHistory(for: g, raw: text, final: final, origin: origin, seconds: seconds, mode: mode)
            self.insert(final, generation: g, origin, target, mode, seconds, asrMs, releasedAt,
                        hadContextRewrite: hadContextRewrite, hadModelEdit: hadModelEdit)
        }

        let policy = Self.reviewPolicy(
            mode: mode, origin: origin, commandLine: preCommandLine,
            isBareSnippet: staged?.isBareSnippet ?? false, hadContextRewrite: hadContextRewrite)
        if policy.shouldReview {
            activeRepairReview?.cancel()
            activeRepairReview = nil
            let appCategory: String = if bundleID.map(AppProfiles.isCodingOrAgentApp) == true {
                "coding"
            } else if profile.stripSingleSentencePeriod {
                "chat"
            } else {
                "prose"
            }
            let midSentence = InsertionFormatter.boundary(before: context.insertion.before) == .continuation
            let smartContext = RepairReviewer.SmartContext(
                dictionaryTerms: dictionaryTerms,
                corrections: learnedCorrections,
                contextTerms: [],
                phoneticIndex: currentVocab?.prepared.phoneticIndex,
                protectedTriggers: staged?.snippetTriggers ?? [],
                appCategory: appCategory,
                midSentence: midSentence,
                stripSingleSentencePeriod: profile.stripSingleSentencePeriod,
                unknownTokenCount: unknownTokenCount
            )
            if let cancel = RepairReviewer.smartReview(
                preReviewClean, context: smartContext,
                allowCloud: policy.allowCloud, allowOnDevice: policy.allowOnDevice,
                done: { outcome in
                    self.queue.async {
                        if self.activeRepairReview?.generation == g { self.activeRepairReview = nil }
                        guard self.session.ownsDelivery(g) else {
                            log("\(tag): repair review dropped (delivery \(g) ended)")
                            return
                        }
                        self.utterances[g]?.deliveryMetrics?.rewriteFinished = .now()
                        self.utterances[g]?.deliveryMetrics?.repairBackend = outcome.backend.rawValue
                        self.utterances[g]?.deliveryMetrics?.repairRoute = outcome.routeLabel
                        log("\(tag): \(outcome.summary)")
                        if outcome.text != preReviewClean { logBody("\(tag) reviewed", outcome.text) }
                        finishClean(outcome.edited ? outcome.text : nil, outcome.edited)
                    }
                }) {
                activeRepairReview = (g, cancel)
                if !session.captureActive {
                    status("FC~")
                    overlay { $0.polishing() }
                }
                utterances[g]?.deliveryMetrics?.rewriteStarted = .now()
                return
            }
        }
        finishClean(nil, false)
    }

    private func promptRewrite(_ fallback: String, raw: String, _ g: Int, _ tag: String,
                               _ seconds: Double, _ asrMs: Double, _ releasedAt: DispatchTime,
                               _ mode: Mode, _ target: PasteTarget?, _ context: DictationContext,
                               _ hadContextRewrite: Bool, allowCloud: Bool = true,
                               dictionaryTerms: [String] = [], origin: DictationOrigin) {
        if !session.captureActive {
            status("FC~")
            overlay { $0.polishing() }
        }
        utterances[g]?.deliveryMetrics?.rewriteStarted = .now()
        activeRepairReview?.cancel()
        let cancelPrompt = Prompter.promptify(fallback, allowCloud: allowCloud, dictionaryTerms: dictionaryTerms) { outcome in
            self.queue.async {
                if self.activeRepairReview?.generation == g { self.activeRepairReview = nil }
                guard self.session.ownsDelivery(g) else {
                    log(String(format: "%@: prompt dropped after %.0fms (delivery %d ended)", tag, outcome.ms, g))
                    return
                }
                let out = outcome.text
                let final = self.formatInsertion(out ?? fallback, generation: g, raw: raw, mode: mode, target: target, context: context)
                self.utterances[g]?.deliveryMetrics?.rewriteFinished = .now()
                self.utterances[g]?.deliveryMetrics?.repairBackend = outcome.backend.rawValue
                self.utterances[g]?.deliveryMetrics?.effectiveMode = out == nil ? "clean" : "prompt"
                let shown = logTranscriptsEnabled() ? final : "\(final.count) chars"
                log(String(format: "%@ prompt %@ (%@) %.0fms: %@", tag,
                           out == nil ? "FELL BACK to clean" : "ok", outcome.backend.rawValue, outcome.ms, shown))
                self.commitHistory(for: g, raw: raw, final: final, origin: origin, seconds: seconds, mode: mode)
                self.insert(final, generation: g, origin, target, mode, seconds, asrMs, releasedAt,
                            hadContextRewrite: hadContextRewrite, hadModelEdit: out != nil)
            }
        }
        activeRepairReview = (g, cancelPrompt)
    }

    private func formatInsertion(_ text: String, generation g: Int, raw: String, mode: Mode,
                                 target: PasteTarget?, context: DictationContext) -> String {
        let vocab = utterances[g]?.vocabulary
        let bundleID = target?.app.bundleID ?? vocab?.bundleID
        let profile: ResolvedAppProfile = if let vocab, vocab.bundleID != nil {
            vocab.appProfile
        } else {
            AppProfiles.shared.resolve(bundleID: bundleID)
        }
        let protected = context.terms.map(\.canonical) + (vocab?.entries.flatMap { entry in
            entry.kind == .dictionary ? [entry.primary] : entry.replacement.map { [$0] } ?? []
        } ?? [])
        let explicitPeriod = raw.range(of: #"\binsert\s+(?:period|full\s+stop)\b"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
        return InsertionFormatter.format(text, context: context.insertion, mode: mode,
                                         protectedTerms: protected, preserveTerminalPeriod: explicitPeriod,
                                         stripSingleSentencePeriod: profile.stripSingleSentencePeriod)
    }

    private func insert(_ text: String, generation g: Int, _ origin: DictationOrigin,
                        _ target: PasteTarget?, _ mode: Mode,
                        _ seconds: Double, _ asrMs: Double, _ releasedAt: DispatchTime,
                        hadContextRewrite: Bool, hadModelEdit: Bool = false) {
        let tag = origin.tag
        let ctx = utterances[g]
        let currentPurpose = ctx?.purpose ?? defaultPurpose
        let metrics = ctx?.deliveryMetrics
        let id = ctx?.resultID ?? UUID()
        let isSelfTestRun = ctx?.isSelfTest ?? selfTesting

        if target?.isSecure == true || AXClient.isSecureInputEnabled() {
            utterances[g]?.audioForHistory = nil
            metrics?.record(outcome: "secure_field_blocked")
            log("\(tag): paste blocked — password or secure field is active")
            notify(AXClient.secureBlockedMessage())
            endUI(for: g)
            return
        }

        if let pasteOverrideForTest {
            pasteOverrideForTest(text) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.endUI(for: g)
                }
            }
            return
        }

        if currentPurpose == .draft {
            metrics?.record(outcome: "draft")
            DispatchQueue.main.async {
                DictationWorkspace.shared.recover(text, id: id, state: .draft)
                DictationWorkspace.shared.status = "Dictation added to your draft."
                History.updateDelivery(id: id, state: .draft)
            }
            endUI(for: g)
            return
        }
        if currentPurpose == .practice, target?.app.bundleID != Bundle.main.bundleIdentifier {
            notify("Click the practice field in FlowClone before pressing your shortcut.")
            endUI(for: g)
            return
        }
        let keepOnClipboard = Paster.keepsLastDictation && currentPurpose != .practice && !isSelfTestRun
        guard let target else {
            recoverResult(for: g, text, state: .notInserted)
            metrics?.record(outcome: "no_target")
            if keepOnClipboard, Paster.keepUndelivered(text) {
                log("\(tag): paste target could not be captured — not pasting, transcript on clipboard")
                notify("Couldn't paste — FlowClone could not bind the original target. Text is on your clipboard — press Cmd+V.", copyText: text)
            } else {
                log("\(tag): paste target could not be captured — not pasting, clipboard untouched")
                notify("Text is in history — FlowClone could not bind the original target", copyText: text)
            }
            endUI(for: g)
            return
        }
        if let pasteSink, target.app.bundleID != pasteSink {
            metrics?.record(outcome: "wrong_test_sink")
            log("\(tag): paste refused — sink \(pasteSink) is not target (\(target.app.bundleID))")
            endUI(for: g)
            return
        }
        AutoLearn.monitor.stop()
        DispatchQueue.main.async { LastInsertionController.shared.invalidate() }
        Paster.paste(text, expectedTarget: target, keepOnClipboard: keepOnClipboard) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .posted(let at, let acknowledgement, let preserved):
                    let total = ms(releasedAt, at)
                    let delivery: String
                    let provenInsertion: Bool
                    switch acknowledgement {
                    case .targetConfirmed(let insertion):
                        delivery = "confirmed"
                        provenInsertion = true
                        DispatchQueue.main.async {
                            History.updateDelivery(id: id, state: .confirmed,
                                effectiveMode: currentPurpose.input.isVerbatim ? currentPurpose.input.rawValue : metrics?.effectiveMode)
                            if currentPurpose == .practice { DictationWorkspace.shared.practiceDelivered = true }
                            else { LastInsertionController.shared.record(id: id, target: target, insertion: insertion, text: text) }
                        }
                    case .clipboardConsumed:
                        delivery = "consumed"
                        provenInsertion = false
                        self.recoverResult(for: g, text, state: .unverified)
                    }
                    metrics?.record(outcome: delivery, postedAt: at)
                    let effective = metrics?.effectiveMode ?? mode.rawValue
                    if origin != .repaste {
                        Task { @MainActor in StatusMenu.shared.showOutputMode(effective, requested: mode.rawValue) }
                    }
                    if !preserved, !keepOnClipboard, !self.warnedClipboardNotPreserved {
                        self.warnedClipboardNotPreserved = true
                        self.notify("Pasted. Your previous clipboard could not be preserved.")
                    }
                    log(String(format: "%@ timings: audio %.2fs, transcribe %.0fms, release→paste %.0fms mode=%@ delivery=%@%@",
                               tag, seconds, asrMs, total, mode.rawValue, delivery,
                               keepOnClipboard ? " (kept on clipboard)"
                                   : preserved ? "" : " (prior clipboard not preserved)"))
                    if case .targetConfirmed(let insertion) = acknowledgement,
                       currentPurpose.learns, AutoLearn.shouldRecord(origin: origin, mode: mode) {
                        AutoLearn.monitor.start(AutoLearn.PasteRecord(
                            target: target, insertion: insertion, text: text, date: Date(),
                            hadContextRewrite: hadContextRewrite, hadModelEdit: hadModelEdit)) { pairs in
                            AutoLearn.learn(
                                pairs,
                                app: target.app.bundleID,
                                bundleID: target.app.bundleID,
                                allowAutomaticSave: !hadModelEdit
                            )
                        }
                    }
                    let usedLLM = metrics?.rewriteStarted != nil
                    if Self.shouldRecordCleanLatency(
                        purpose: currentPurpose, mode: mode, origin: origin,
                        provenInsertion: provenInsertion, usedLLM: usedLLM
                    ) {
                        self.totals.append(total)
                        if self.totals.count > Self.latencyWindow {
                            self.totals.removeFirst(self.totals.count - Self.latencyWindow)
                        }
                    }
                    if currentPurpose != .practice, !mode.isLLM, origin.contributesLiveLatency, provenInsertion {
                        self.latencyMeasurements += 1
                        self.overallTotals.append(total)
                        if self.overallTotals.count > Self.latencyWindow {
                            self.overallTotals.removeFirst(self.overallTotals.count - Self.latencyWindow)
                        }
                        if usedLLM {
                            self.claudeTotals.append(total)
                            if self.claudeTotals.count > Self.latencyWindow {
                                self.claudeTotals.removeFirst(self.claudeTotals.count - Self.latencyWindow)
                            }
                        }
                        if self.latencyMeasurements % 10 == 0 { self.logPercentiles() }
                    }
                case .ambiguous(let at, let recovery, let why):
                    self.recoverResult(for: g, text, state: .unverified)
                    metrics?.record(outcome: "ambiguous", postedAt: at)
                    log("\(tag): paste outcome ambiguous (\(why)); recovery=\(recovery)")
                    switch recovery {
                    case .transcriptOnClipboard:
                        self.notify("Paste could not be confirmed. Text is on your clipboard and in History.", copyText: text)
                    case .historyOnly:
                        self.notify("Paste could not be confirmed. Text remains in FlowClone History.", copyText: text)
                    case .clipboardUntouched:
                        self.notify("Paste stopped before insertion. Text remains in FlowClone History.", copyText: text)
                    }
                case .notPosted(let recovery, let why):
                    if why == "secure input" || why == "secure field" {
                        self.utterances[g]?.audioForHistory = nil
                        metrics?.record(outcome: "secure_field_blocked")
                        log("\(tag): NOT pasted (\(why)); discarded without recovery")
                        self.notify(AXClient.secureBlockedMessage())
                        break
                    }
                    self.recoverResult(for: g, text, state: .notInserted)
                    metrics?.record(outcome: "not_posted")
                    log("\(tag): NOT pasted (\(why)); recovery=\(recovery)")
                    switch recovery {
                    case .transcriptOnClipboard:
                        self.notify("Couldn't paste (\(why)). Text is on your clipboard — press Cmd+V.", copyText: text)
                    case .historyOnly, .clipboardUntouched:
                        self.notify("Couldn't paste (\(why)). Text remains in FlowClone History.", copyText: text)
                    }
                case .skippedEmpty:
                    metrics?.record(outcome: "empty")
                    log("\(tag): paste skipped — whitespace only")
                }
                self.endUI(for: g)
            }
        }
    }

    private func endUI(for generation: Int) {
        utterances.removeValue(forKey: generation)
        if activeRepairReview?.generation == generation {
            activeRepairReview = nil
        }
        session.endDelivery(owner: generation)
        drainPendingFinalizations()
        endInteractiveActivityIfIdle()
        if session.isRecording {
            status("FC●")
        } else if session.isWarming {
            status("FC…")
        } else if session.isDelivering {
            status("FC…")
            overlay { $0.transcribing() }
        } else {
            status("FC")
            overlay {
                $0.setModeBadge(nil)
                $0.hide()
            }
        }
    }

    private func commitHistory(for g: Int, raw: String, final: String, origin: DictationOrigin,
                               seconds: Double, mode: Mode) {
        guard !suppressPersistenceForTest else { return }
        guard let ctx = utterances[g], ctx.purpose != .practice else { return }
        let id = ctx.resultID
        let cleaned = ctx.cleanStage
        let input = ctx.purpose.input.rawValue
        let parentID = ctx.parentResultID
        let audio = ctx.audioForHistory
        let app = ctx.resultTargetApp
        let model = transcriber.engine.historyLabel
        let effective = ctx.purpose.input.isVerbatim ? input : ctx.deliveryMetrics?.effectiveMode ?? mode.rawValue
        DispatchQueue.main.async {
            let savedOrigin = parentID.map { History.canPersistDerived(from: $0) ? DictationOrigin.utterance : .selfTest } ?? origin
            History.add(raw: raw, final: final, origin: savedOrigin, seconds: seconds,
                        mode: mode.rawValue, id: id, cleaned: cleaned, effectiveMode: effective,
                        input: input, model: model, targetApp: app, delivery: .ready,
                        parentID: parentID, audio: audio)
        }
        finalizeFailedRecovery(for: origin, reason: "new transcript committed to History")
    }

    private func recoverResult(for g: Int, _ text: String, state: DeliveryState) {
        guard !suppressPersistenceForTest else { return }
        let ctx = utterances[g]
        let currentPurpose = ctx?.purpose ?? defaultPurpose
        guard currentPurpose != .practice else { return }
        let id = ctx?.resultID ?? UUID()
        let alreadyInDraft = ctx?.resultAlreadyInDraft ?? false
        DispatchQueue.main.async {
            History.updateDelivery(id: id, state: state)
            if alreadyInDraft {
                DictationWorkspace.shared.status = "Insertion could not be confirmed. Your draft is unchanged; check the destination before inserting again."
            } else { DictationWorkspace.shared.recover(text, id: id, state: state) }
        }
    }

    private func setFailedCapture(_ samples: [Float]) {
        let capture = failedCaptures.retain(samples)
        publishRetryAvailability()
        let id = capture.id
        let deadline = capture.deadline
        queue.asyncAfter(deadline: deadline) { [weak self] in
            self?.expireFailedCapture(id: id, deadline: deadline, now: .now())
        }
    }

    @discardableResult
    private func retainFailedCapture(_ samples: [Float], for origin: DictationOrigin,
                                     purpose: CapturePurpose) -> Bool {
        guard purpose != .practice else { return false }
        if case .instruction = purpose { return false }
        guard origin.supersedesFailedRecovery else { return false }
        setFailedCapture(samples)
        return true
    }

    private func finalizeFailedRecovery(for origin: DictationOrigin, reason: String) {
        guard origin.commitsFailedRecovery || origin.supersedesFailedRecovery else { return }
        clearFailedCapture(reason)
    }

    private func expireFailedCapture(id: UUID, deadline: DispatchTime,
                                     now: DispatchTime) {
        guard failedCaptures.expire(id: id, deadline: deadline, now: now) else { return }
        log("failed recording cleared — 10-minute retention expired")
        publishRetryAvailability()
    }

    private func clearFailedCapture(_ reason: String) {
        guard failedCaptures.clear() else { return }
        log("failed recording cleared — \(reason)")
        publishRetryAvailability()
    }

    private func publishRetryAvailability() {
        let available = failedCaptures.current != nil
        DispatchQueue.main.async { self.retryAvailable = available; DictationWorkspace.shared.retryAvailable = available }
    }

    private func publishModelRetryAvailability() {
        let available = modelLoadFailed && !modelLoading && !ready
        DispatchQueue.main.async { self.modelRetryAvailable = available }
    }

    private func logPercentiles() {
        func summarize(_ values: [Double]) -> String {
            let s = values.sorted()
            guard !s.isEmpty else { return "n=0" }
            func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(p * Double(s.count)))] }
            return String(format: "n=%d p50 %.0fms p95 %.0fms", s.count, pct(0.5), pct(0.95))
        }
        guard !overallTotals.isEmpty else { return }
        var parts = ["local: \(summarize(totals))"]
        if !claudeTotals.isEmpty {
            parts.append("smart-model: \(summarize(claudeTotals))")
            parts.append("overall: \(summarize(overallTotals))")
        }
        log("latency (release→paste) " + parts.joined(separator: " | "))
    }

    /// Session queue → main. F2: `sessionActive` rides the same hop, read here because
    /// this is the queue that owns the three flags.
    private func status(_ t: String) {
        let busy = session.captureActive || session.isDelivering
        let latched = session.handsFree
        let recording = session.captureActive, processing = session.isDelivering, ready = ready
        let activePurpose = session.activeCaptureGeneration.flatMap { utterances[$0]?.purpose }
            ?? session.deliveringGeneration.flatMap { utterances[$0]?.purpose }
            ?? defaultPurpose
        let label = activePurpose.title
        DispatchQueue.main.async {
            self.sessionActive = busy
            self.handsFreeActive = latched
            let workspace = DictationWorkspace.shared
            workspace.recording = recording; workspace.processing = processing
            workspace.modelReady = ready; workspace.captureLabel = label
            TransformController.shared.captureStateChanged()
            self.onStatus?(t)
        }
    }

    // MARK: - Self-test

    /// Prompt-mode retention probe (Prompter.keepProbe).
    func promptKeepProbe() {
        Task { await Prompter.keepProbe() }
    }

    /// End-to-end hook: canned WAV → Transcriber → Paster, no mic involved.
    func selfTest(repeats: Int = 1, latched: Bool = false) {
        queue.async {
            guard let url = Bundle.main.url(forResource: "say8", withExtension: "wav") else {
                log("SELFTEST: say8.wav missing from the app bundle")
                return
            }
            guard let fixture = try? AudioConverter().resampleAudioFile(url) else {
                log("SELFTEST: could not decode \(url.path)")
                return
            }
            let samples = repeats > 1
                ? (0..<repeats).flatMap { _ in fixture }
                : fixture
            Mode.testOverride = .clean
            self.selfTesting = true
            self.beginInteractiveActivityIfNeeded()
            self.recorder.preloadForTest(samples)
            let g = self.session.beginPreparedCapture(handsFree: latched)
            var ctx = UtteranceContext(generation: g, purpose: .editor(.normal), captureMode: .clean)
            ctx.isSelfTest = true
            self.utterances[g] = ctx
            self.targetCapture = TargetCaptureOwnership(
                generation: g,
                lease: Paster.beginTargetCapture(for: PasteTarget.AppIdentity.frontmost()))
            self.handle(.up)
        }
    }

    #if DEBUG
    /// Hands-free UI testing (HandsfreeLaunch `dictate`): the self-test's release span with a
    /// fixture recording, delivered to Draft as "Dictate into draft" is. No hotkey, microphone,
    /// target capture or paste.
    func handsfreeDictate(_ samples: [Float]) {
        queue.async {
            guard self.ready, !self.session.isBusy else { log("handsfree dictate refused — model not ready or session busy"); return }
            self.beginInteractiveActivityIfNeeded()
            self.defaultPurpose = .draft
            self.pendingPurpose = nil
            let chosenMode: Mode = CapturePurpose.draft.usesCleanup ? Mode.current : .raw
            self.recorder.preloadForTest(samples)
            let g = self.session.beginPreparedCapture(handsFree: false)
            var ctx = UtteranceContext(generation: g, purpose: .draft, captureMode: chosenMode)
            ctx.vocabularyCapture = VocabularyCapture(lease: nil)
            self.utterances[g] = ctx
            self.handle(.up)
        }
    }
    #endif
}

func ms(_ a: DispatchTime, _ b: DispatchTime) -> Double {
    Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1e6
}
