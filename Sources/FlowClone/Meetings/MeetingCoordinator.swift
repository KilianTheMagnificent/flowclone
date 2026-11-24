import Cocoa
import Observation

enum MeetingAttention: Equatable {
    case googleSignIn(String)
    case recordingUnavailable(String)

    var message: String {
        switch self {
        case .googleSignIn(let message), .recordingUnavailable(let message): message
        }
    }

    var menuTitle: String {
        switch self {
        case .googleSignIn: "Reconnect Google Calendar…"
        case .recordingUnavailable: "Meeting recording needs attention…"
        }
    }
}

@MainActor @Observable final class MeetingCoordinator {
    static var shared = MeetingCoordinator(
        calendar: MeetingCalendarSources(), capture: MacMeetingCapture(),
        transcriber: LocalMeetingTranscriber(), summarizer: LocalMeetingSummarizer(),
        store: MeetingStore(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlowClone/Meetings", isDirectory: true)),
        callDetector: MacLiveMeetingDetector())

    var calendars: [MeetingCalendar] = []
    var upcoming: [MeetingEvent] = []
    var notes: [MeetingNote] = []
    var selectedNoteID: UUID?
    var selectedCalendars: Set<String>
    var autoStart: Bool
    /// Automatically detect and record live calls/meetings (Zoom, Google Meet, Teams, FaceTime, Slack, etc.)
    /// with zero setup required. Enabled by default.
    var autoDetectCalls: Bool
    var summaryModel: MeetingSummaryModel
    var detectedCall: DetectedMeetingCall?
    var consentConfirmed: Bool
    var status = ""
    var error: String?
    var activeID: UUID?
    var isStarting = false
    var isStopping = false
    var isImporting = false
    var searchIndexVersion = 0
    var processing: Set<UUID> = []
    var publishingToGitHub: Set<UUID> = []
    var githubConfig: GitHubPublishConfig
    var githubConnected = false
    var githubConnecting = false
    var githubLoadingRepos = false
    var githubRepos: [GitHubRepositorySummary] = []
    var githubStatus = ""
    var githubError: String?
    var countdown: MeetingEvent?
    var countdownEnd: Date?
    var suspended = false
    var connected = false
    var calendarSource: MeetingCalendarSource = .google
    var account: String?
    var connecting = false
    /// Checked before the first meeting: macOS refuses system audio instantly at start time.
    var systemAudioAllowed = true
    @ObservationIgnored private var askedForSystemAudio = false
    private var dismissed: Set<String>
    /// Events switched on by hand that would not be recorded by themselves.
    private var included: Set<String>
    /// Cached set of event IDs with non-failed or non-empty recordings so Upcoming rows do not
    /// observe `notes` during live transcription or personal-note typing.
    private var recordedEventIDs: Set<String> = []
    private let calendar: any MeetingCalendarProviding
    private let capture: any MeetingCapturing
    private let transcriber: any MeetingTranscribing
    private let summarizer: any MeetingSummarizing
    private let callDetector: (any MeetingCallDetecting)?
    private let githubPublisher: any MeetingGitHubPublishing
    let store: MeetingStore
    private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private(set) var currentTimerInterval: TimeInterval?
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var finalizers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var githubTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var githubRetryAttempts: [UUID: (count: Int, next: Date)] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastSync: Date = .distantPast
    @ObservationIgnored private var lastSuccess: Date = .distantPast
    @ObservationIgnored private var firstTransientFailure: Date?
    @ObservationIgnored private var wakeGraceUntil: Date = .distantPast
    @ObservationIgnored private var syncError: String?
    @ObservationIgnored private var generation = 0
    /// Lifecycle only: times, counts and phases. Never titles, attendees or transcript text.
    private let trace: @MainActor (String) -> Void
    @ObservationIgnored private var lastTrace = ""
    /// Tells the person when automatic recording needs them (sign-in expired, permission missing).
    private let notify: @MainActor (String) -> Void
    @ObservationIgnored private var notified: Set<String> = []
    private(set) var recordingAttention: MeetingAttention?
    @ObservationIgnored private var resumeAttempts: [UUID: (count: Int, next: Date)] = [:]
    @ObservationIgnored private var adHocSessionConsentID: UUID?
    @ObservationIgnored private var pendingLiveCall: (call: DetectedMeetingCall, firstSeen: Date)?
    @ObservationIgnored private var activeLiveCallKey: String?
    @ObservationIgnored private var activeLiveCallNoteID: UUID?
    @ObservationIgnored private var liveCallMissingSince: Date?
    @ObservationIgnored private var suppressedLiveCallKey: String?
    @ObservationIgnored private var overrunID: UUID?
    @ObservationIgnored private var lastMicrophoneCheck: Date = .distantPast
    @ObservationIgnored private var pendingNoteSaves: Set<UUID> = []
    @ObservationIgnored private var noteSaveWork: DispatchWorkItem?
    @ObservationIgnored private var searchBodyCache: [UUID: (revisionKey: Int, bodyLower: String)] = [:]
    @ObservationIgnored private var searchWarmingIDs: Set<UUID> = []
    /// Overrides window visibility in unit tests for deterministic idle-timer verification.
    @ObservationIgnored var isUIActiveProvider: (@MainActor () -> Bool)?
    /// Past the scheduled end, recording continues this long after the last words, up to the limit.
    static let overrunQuiet: TimeInterval = 45, overrunLimit: TimeInterval = 30 * 60
    /// Brief confirmation debounce before auto-recording a newly detected live call.
    static let liveCallConfirmDelay: TimeInterval = 3
    /// Wait this long after a live call drops audio before auto-stopping and summarizing.
    static let liveCallEndGrace: TimeInterval = 15
    /// Keep cached calendar connection across brief post-wake Wi-Fi reconnection blips.
    static let wakeGraceDuration: TimeInterval = 60
    /// Idle network calendar sync cadence (5 min); the lightweight local timer still checks
    /// already-fetched upcoming events so scheduled meetings start on time without 15s polling storms.
    static let idleSyncInterval: TimeInterval = 5 * 60
    /// Fast network sync cadence when recording, counting down, imminent, or recovering from a sync error.
    static let activeSyncInterval: TimeInterval = 15
    /// Lead time before an upcoming automatic meeting when network sync tightens to catch last-minute changes.
    static let imminentSyncLeadTime: TimeInterval = 120

    init(calendar: any MeetingCalendarProviding, capture: any MeetingCapturing,
         transcriber: any MeetingTranscribing, summarizer: any MeetingSummarizing,
         store: MeetingStore, defaults: UserDefaults = .standard,
         callDetector: (any MeetingCallDetecting)? = nil,
         githubPublisher: any MeetingGitHubPublishing = GitHubMeetingPublisher(),
         trace: @escaping @MainActor (String) -> Void = { log($0) },
         notify: @escaping @MainActor (String) -> Void = { notifyUser($0) }) {
        self.calendar = calendar; self.capture = capture; self.transcriber = transcriber
        self.summarizer = summarizer; self.store = store; self.defaults = defaults
        self.callDetector = callDetector; self.githubPublisher = githubPublisher
        self.trace = trace; self.notify = notify
        selectedCalendars = Set(defaults.stringArray(forKey: "meetingCalendarIDs") ?? [])
        autoStart = defaults.bool(forKey: "meetingAutoStart")
        autoDetectCalls = defaults.object(forKey: "meetingAutoDetectCalls") as? Bool ?? true
        summaryModel = defaults.string(forKey: MeetingSummaryModel.settingKey)
            .flatMap(MeetingSummaryModel.init) ?? .automatic
        consentConfirmed = defaults.bool(forKey: "meetingConsent")
        dismissed = Set(defaults.stringArray(forKey: "meetingDismissedEvents") ?? [])
        included = Set(defaults.stringArray(forKey: "meetingIncludedEvents") ?? [])
        if let data = defaults.data(forKey: GitHubPublishConfig.defaultsKey),
           let decoded = try? JSONDecoder().decode(GitHubPublishConfig.self, from: data) {
            githubConfig = decoded
        } else {
            githubConfig = GitHubPublishConfig()
        }
        switch githubPublisher.tokenLoadState() {
        case .found:
            githubConnected = true
        case .missing:
            githubConnected = false
        case .unavailable:
            // Preserve last known connected state if Keychain is momentarily locked at login/wake.
            githubConnected = githubConfig.connectedUsername != nil || githubConfig.isConfigured
        }
        calendarSource = calendar.source; account = calendar.account
    }
    var selectedNote: MeetingNote? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }
    var activeNote: MeetingNote? {
        guard let activeID else { return nil }
        return notes.first { $0.id == activeID }
    }
    var busy: Bool { activeID != nil || isStarting || isStopping }
    var blocksUpdate: Bool { busy || countdown != nil || !processing.isEmpty || !publishingToGitHub.isEmpty || isImporting }
    private var watchesForAutomaticMeetings: Bool {
        autoStart && consentConfirmed && !selectedCalendars.isEmpty
    }

    static func initialOffsets(for segments: [MeetingSegment]) -> [MeetingSource: TimeInterval] {
        var offsets: [MeetingSource: TimeInterval] = [:]
        for segment in segments {
            let end = max(0, segment.offset + max(0, segment.duration))
            offsets[segment.source] = max(offsets[segment.source] ?? 0, end)
        }
        return offsets
    }

    private var isUIActive: Bool {
        if let isUIActiveProvider { return isUIActiveProvider() }
        return MainWindow.shared.isOnScreen && NSApp.isActive
    }

    func setLaunchedForTesting(_ value: Bool = true) {
        launched = value
    }

    func setWakeGraceForTesting(until date: Date) {
        wakeGraceUntil = date
    }

    func setSummaryModel(_ model: MeetingSummaryModel) {
        guard summaryModel != model else { return }
        summaryModel = model
        defaults.set(model.rawValue, forKey: MeetingSummaryModel.settingKey)
        if defaults == .standard {
            MeetingSummaryModel.setting = model
        }
        trace("meeting: summary model = \(model.rawValue)")
    }

    func desiredTimerInterval(now: Date = Date()) -> TimeInterval? {
        guard launched, (!handsfreeSession || isUIActiveProvider != nil), !suspended else { return nil }
        if activeID != nil || countdown != nil || pendingLiveCall != nil || notes.contains(where: { $0.autoResume == true }) {
            return 2
        }
        if autoStart && consentConfirmed && (connected || !selectedCalendars.isEmpty) {
            let imminent = upcoming.contains { event in
                automatic(event) && event.start.timeIntervalSince(now) <= 90 && event.end > now
                    && !alreadyRecorded(event)
            }
            return imminent ? 2 : 15
        }
        if isUIActive && (connected || !selectedCalendars.isEmpty) {
            return 15
        }
        if githubConfig.autoPublish && githubConnected && githubConfig.isConfigured
            && notes.contains(where: { $0.githubPublish?.status == .pendingRetry }) {
            return 15
        }
        return nil
    }

    func updateTimerSchedule(now: Date = Date()) {
        let wanted = desiredTimerInterval(now: now)
        guard wanted != currentTimerInterval else { return }
        timer?.invalidate()
        timer = nil
        currentTimerInterval = wanted
        guard let wanted else { return }
        let newTimer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // Meeting deadlines must continue while a menu or drag tracks the run loop.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func updateLiveCallMonitoring() {
        guard let callDetector else { return }
        if launched && autoDetectCalls && !suspended {
            callDetector.start { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleLiveCallChange()
                }
            }
        } else {
            callDetector.stop()
            pendingLiveCall = nil
            detectedCall = nil
            liveCallMissingSince = nil
        }
    }

    func launch() {
        load()
        guard !suppressHostAccess, !launched else { return }
        launched = true
        let tokenState = githubPublisher.tokenLoadState()
        let tokenStatus: String = switch tokenState {
        case .found: "found"
        case .missing: "missing"
        case .unavailable(let status): "unavailable(\(status))"
        }
        if tokenStatus != "missing" || githubConfig.isConfigured {
            trace("meeting github: startup token=\(tokenStatus) configured=\(githubConfig.isConfigured) auto=\(githubConfig.autoPublish)")
        }
        updateLiveCallMonitoring()
        updateTimerSchedule()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.suspended = true; self.cancelCountdown()
                    self.pendingLiveCall = nil; self.liveCallMissingSince = nil
                    self.updateLiveCallMonitoring()
                    self.updateTimerSchedule()
                    await self.stop(reason: "Recording paused for system sleep or session switch.", resumable: true)
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.suspended = false
                    self.lastSync = .distantPast
                    self.wakeGraceUntil = Date().addingTimeInterval(Self.wakeGraceDuration)
                    self.updateLiveCallMonitoring()
                    self.updateTimerSchedule()
                    await self.tick()
                }
            })
        }
        let appCenter = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didChangeOcclusionStateNotification
        ] {
            observers.append(appCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateTimerSchedule() }
            })
        }
        Task { await tick() }
    }
    func load(now: Date = Date()) {
        guard !loaded else { return }
        do {
            notes = try store.load()
            loaded = true
            for index in notes.indices where notes[index].phase == .recording || notes[index].phase == .processing || notes[index].phase == .interrupted {
                let wasInterrupted = notes[index].phase == .interrupted
                // FlowClone quit or crashed mid-recording: continue once the saved audio is recovered.
                if notes[index].phase == .recording { notes[index].autoResume = true }
                notes[index].phase = .interrupted
                notes[index].endedAt = notes[index].endedAt ?? now
                if !wasInterrupted {
                    notes[index].issue = "Recording was interrupted. Saved audio is being recovered."
                }
                if let segments = try? store.recoveredSegments(for: notes[index]) {
                    notes[index].segments = segments.map { segment in
                        var copy = segment
                        if copy.text == nil { copy.error = nil }
                        return copy
                    }
                }
                try? store.save(notes[index])
            }
            refreshRecordedEventIDs()
            var toFinalize: [UUID] = []
            var needsDrain = false
            for note in notes where note.phase == .interrupted {
                if note.autoResume == true, note.event.isEligible, note.event.end.timeIntervalSince(now) > 20,
                   !dismissed.contains(note.event.id) {
                    if note.segments.contains(where: { $0.text == nil && $0.error == nil }) { needsDrain = true }
                } else {
                    toFinalize.append(note.id)
                }
            }
            if needsDrain { drain() }
            for id in toFinalize { Task { await retry(id) } }
        } catch { self.error = "Meeting storage could not be read: \(error.localizedDescription)" }
    }
    func saveSettings() {
        systemAudioAllowed = capture.systemAudioAllowed
        if autoStart, consentConfirmed, !systemAudioAllowed, !askedForSystemAudio {
            askedForSystemAudio = true
            trace("meeting: system audio permission missing; asked macOS")
            capture.requestSystemAudio()
        }
        defaults.set(Array(selectedCalendars), forKey: "meetingCalendarIDs")
        defaults.set(autoStart, forKey: "meetingAutoStart")
        defaults.set(autoDetectCalls, forKey: "meetingAutoDetectCalls")
        defaults.set(consentConfirmed, forKey: "meetingConsent")
        if !autoDetectCalls {
            pendingLiveCall = nil
            detectedCall = nil
            suppressedLiveCallKey = nil
        }
        updateLiveCallMonitoring()
        if !autoStart || !consentConfirmed { cancelCountdown() }
        if !watchesForAutomaticMeetings { updateAttention(nil) }
        let sessionConsentedActive = activeID != nil && (activeID == adHocSessionConsentID || activeID == activeLiveCallNoteID)
        if !consentConfirmed, busy, !sessionConsentedActive {
            Task { await stop(reason: "Participant consent was turned off.") }
        }
        lastSync = .distantPast
        updateTimerSchedule()
    }
    func connect(_ source: MeetingCalendarSource = .google) async {
        guard !connecting else { return }
        connecting = true; defer { connecting = false }
        let previous = calendar.source
        do {
            try await calendar.connect(source)
            calendarSource = calendar.source; account = calendar.account
            // Calendar IDs belong to one source; start the selection over when it changes.
            if source != previous { selectedCalendars = [] }
            calendars = try await calendar.calendars()
            if selectedCalendars.isEmpty, let primary = calendars.first(where: \.primary) { selectedCalendars = [primary.id] }
            saveSettings()
            try await sync(now: Date()); error = nil
            updateTimerSchedule()
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() async {
        let wasMac = calendarSource == .mac
        await calendar.disconnect()
        account = calendar.account
        calendars = []; upcoming = []; connected = false; selectedCalendars = []
        saveSettings(); cancelCountdown()
        updateTimerSchedule()
        error = nil
        status = wasMac
            ? "Disconnected from macOS Calendar."
            : "Signed out of Google. Sign in to watch your calendars again."
    }
    func desiredSyncInterval(now: Date = Date()) -> TimeInterval {
        if activeID != nil || countdown != nil || syncError != nil || !connected {
            return Self.activeSyncInterval
        }
        let hasImminent = upcoming.contains { event in
            automatic(event)
                && event.start.timeIntervalSince(now) <= Self.imminentSyncLeadTime
                && event.end > now
                && !alreadyRecorded(event)
        }
        return hasImminent ? Self.activeSyncInterval : Self.idleSyncInterval
    }

    func sync(now: Date, forceRefresh: Bool = false) async throws {
        let fetchedCalendars = try await calendar.calendars(forceRefresh: forceRefresh)
        let fetchedUpcoming = try await calendar.events(calendarIDs: selectedCalendars, from: now.addingTimeInterval(-300), to: now.addingTimeInterval(7 * 86400))
            .filter(\.isEligible)
        let nextAccount = calendar.account
        let nextSystemAudio = capture.systemAudioAllowed
        if calendars != fetchedCalendars { calendars = fetchedCalendars }
        if upcoming != fetchedUpcoming { upcoming = fetchedUpcoming }
        if account != nextAccount { account = nextAccount }
        if systemAudioAllowed != nextSystemAudio { systemAudioAllowed = nextSystemAudio }
        if !connected { connected = true }
        lastSync = now; lastSuccess = now; firstTransientFailure = nil
        notified = notified.filter { !$0.hasPrefix("Meetings are not being recorded") }
        updateAttention(nextSystemAudio ? nil : .recordingUnavailable(
            "FlowClone can’t record meeting audio yet. Open Meeting notes to allow it."
        ))
        // Clear only a calendar error; a capture error stays until the person sees it.
        if error != nil, error == syncError { error = nil }
        syncError = nil
        traceOnce("meeting calendar: \(selectedCalendars.count) selected, \(upcoming.count) upcoming, \(upcoming.filter(automatic).count) auto-eligible; next auto start \(upcoming.first { automatic($0) && $0.start > now }.map { Self.clock($0.start) } ?? "none")")
        let choosePrompt = calendarSource == .mac ? "Choose the macOS calendars to watch." : "Choose the Google calendars to watch."
        let nextStatus = selectedCalendars.isEmpty ? choosePrompt : "Calendar connected · \(upcoming.count) upcoming meetings"
        if status != nextStatus { status = nextStatus }
    }
    func refresh() async {
        do {
            try await sync(now: Date(), forceRefresh: true)
            if error != nil { error = nil }
        } catch { syncFailed(error, now: Date()) }
    }
    /// A brief network loss or post-wake reconnection keeps the last calendar intact, so a countdown,
    /// recording, or Google Calendar connection is not dropped over a transient failure.
    /// Genuine sign-in revocation or permission problems clear it at once.
    private func syncFailed(_ error: Error, now: Date) {
        traceOnce("meeting calendar: sync failed: \(error.localizedDescription)")
        let description = error.localizedDescription
        if self.error != description { self.error = description }
        syncError = description
        lastSync = now  // Retry on the normal cadence, not on every 2-second tick.
        let passing = Self.passing(error)
        let latestAccount = calendar.account
        // Never wipe a known signed-in account label during a transient Keychain/network hiccup.
        if let latestAccount, account != latestAccount {
            account = latestAccount
        } else if !passing, account != latestAccount {
            account = latestAccount
        }
        if passing {
            if firstTransientFailure == nil { firstTransientFailure = now }
        } else {
            firstTransientFailure = nil
        }
        let failureStarted = firstTransientFailure ?? lastSuccess
        let withinGrace = (connected && now.timeIntervalSince(failureStarted) < 300) || now < wakeGraceUntil
        if passing, withinGrace { return }
        if connected { connected = false }
        if !upcoming.isEmpty { upcoming = [] }
        cancelCountdown()
        // Not a network blip: without the calendar nothing is recorded until the person acts.
        if !passing, watchesForAutomaticMeetings {
            let message = "Meetings are not being recorded: \(description) Open FlowClone → Meetings."
            notifyOnce(message)
            updateAttention(error is GoogleCalendarSignInRequired
                ? .googleSignIn(message)
                : .recordingUnavailable(message))
        }
    }
    /// A warning in the menu bar while automatic recording cannot work until the person acts.
    private func updateAttention(_ issue: MeetingAttention?) {
        let issue = watchesForAutomaticMeetings ? issue : nil
        guard issue != recordingAttention else { return }
        recordingAttention = issue
        if !suppressHostAccess { StatusMenu.shared.meetingAttention(issue) }
    }
    /// Network loss, brief Keychain lock at wake, and Google's own outages pass by themselves;
    /// sign-in revocation and permission problems do not.
    private static func passing(_ error: Error) -> Bool {
        if error is URLError || error is GoogleCalendarTransientFailure { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain
            || nsError.domain == NSPOSIXErrorDomain
            || nsError.domain == (kCFErrorDomainCFNetwork as String) {
            return true
        }
        if let api = error as? GoogleAPIFailure {
            return api.status >= 500 || api.status == 429 || api.status == 408
        }
        if let token = error as? GoogleTokenFailure {
            return token.code.hasPrefix("http_5")
                || token.code == "http_429"
                || token.code == "http_408"
                || token.code == "temporarily_unavailable"
                || token.code == "server_error"
                || token.code == "rate_limit_exceeded"
        }
        return false
    }
    private func notifyOnce(_ message: String) {
        guard notified.insert(message).inserted else { return }
        notify(message)
    }
    /// Called immediately by `callDetector` when a conferencing app or browser opens/closes audio.
    func handleLiveCallChange(now: Date = Date()) async {
        load(now: now)
        guard !suspended else { return }
        await evaluateLiveCall(now: now)
        updateTimerSchedule(now: now)
    }
    /// Matches a currently running or imminent (±15 min) scheduled calendar event so a live-detected
    /// call reuses the calendar title/attendees instead of creating a duplicate ad-hoc entry.
    private func matchingCalendarEventForLiveCall(now: Date) -> MeetingEvent? {
        guard connected else { return nil }
        return upcoming.filter { event in
            event.isEligible
                && !dismissed.contains(event.id)
                && event.start <= now.addingTimeInterval(15 * 60)
                && event.end > now.addingTimeInterval(-5 * 60)
                && (!alreadyRecorded(event) || activeNote?.event.id == event.id)
        }.min { a, b in
            let aStarted = a.start <= now
            let bStarted = b.start <= now
            if aStarted != bStarted { return aStarted }
            if (a.joinURL != nil) != (b.joinURL != nil) { return a.joinURL != nil }
            let aDist = abs(a.start.timeIntervalSince(now))
            let bDist = abs(b.start.timeIntervalSince(now))
            if aDist != bDist { return aDist < bDist }
            return a.id < b.id
        }
    }
    /// Evaluates live call detection state: auto-starts after a brief 3s confirmation debounce
    /// (with zero setup required) and auto-stops & summarizes 15s after the call ends.
    private func evaluateLiveCall(now: Date) async {
        guard autoDetectCalls, let callDetector, !suspended else {
            pendingLiveCall = nil
            liveCallMissingSince = nil
            if detectedCall != nil { detectedCall = nil }
            return
        }
        let matchedCalendar = matchingCalendarEventForLiveCall(now: now)
        let current = callDetector.currentCall(hasActiveCalendarEvent: matchedCalendar != nil)
        if detectedCall != current { detectedCall = current }

        if let active = activeNote {
            pendingLiveCall = nil
            guard activeLiveCallNoteID == active.id else { return }
            if current != nil {
                liveCallMissingSince = nil
                return
            }
            if liveCallMissingSince == nil {
                liveCallMissingSince = now
                return
            }
            if let missingSince = liveCallMissingSince,
               now.timeIntervalSince(missingSince) >= Self.liveCallEndGrace {
                liveCallMissingSince = nil
                activeLiveCallKey = nil
                activeLiveCallNoteID = nil
                trace("meeting: live call ended; stopping and summarizing")
                if let id = await endCapture(reason: nil, at: now) {
                    finalizeLater(id)
                }
            }
            return
        }

        activeLiveCallKey = nil
        activeLiveCallNoteID = nil
        liveCallMissingSince = nil

        guard let current else {
            pendingLiveCall = nil
            suppressedLiveCallKey = nil
            return
        }
        if suppressedLiveCallKey == current.key {
            return
        }
        guard !isStarting, !isStopping else { return }

        if let pending = pendingLiveCall, pending.call.key == current.key {
            if now.timeIntervalSince(pending.firstSeen) < Self.liveCallConfirmDelay {
                pendingLiveCall = (current, pending.firstSeen)
                return
            }
        } else {
            pendingLiveCall = (current, now)
            trace("meeting: detected live call (\(current.appName)); confirming in \(Int(Self.liveCallConfirmDelay))s")
            return
        }

        pendingLiveCall = nil
        let targetEvent: MeetingEvent
        if let matchedCalendar, !alreadyRecorded(matchedCalendar) {
            targetEvent = matchedCalendar
        } else {
            targetEvent = MeetingEvent.liveDetected(title: current.suggestedTitle, now: now)
        }
        await start(targetEvent, now: now, adHocSessionConsent: true, liveCallKey: current.key)
    }
    func tick(now: Date = Date()) async {
        guard !ticking, !suspended else { return }
        ticking = true; defer { ticking = false; updateTimerSchedule(now: now) }
        if now.timeIntervalSince(lastSync) >= desiredSyncInterval(now: now) || now < lastSync {
            do { try await sync(now: now) }
            catch { syncFailed(error, now: now) }
        }
        await evaluateLiveCall(now: now)
        retryPendingGitHubPublishes(now: now)
        if let active = activeNote {
            // Calendar edits can extend the current occurrence; missing/cancelled events stop capture.
            if connected, let updated = upcoming.first(where: { $0.id == active.event.id }), updated != active.event {
                mutate(active.id) { $0.event = updated }
            }
            let end = activeNote?.event.end ?? active.event.end
            // The summary runs on its own so a back-to-back meeting is not held up by it.
            if now >= end || now.timeIntervalSince(active.startedAt) >= 3 * 3600 {
                if stillTalking(activeNote ?? active, end: end, now: now) {
                    if overrunID != active.id {
                        overrunID = active.id
                        trace("meeting: still talking at the scheduled end; recording continues")
                        status = "Recording \(active.event.title) · running past its scheduled end"
                    }
                    return
                }
                if let id = await endCapture(reason: nil, at: now) { finalizeLater(id) }
                return
            }
            if connected, !upcoming.contains(where: { $0.id == active.event.id }), !active.event.calendarID.isEmpty,
               let id = await endCapture(reason: "The event was removed, cancelled, or its calendar was deselected.", at: now) {
                finalizeLater(id)
                return
            }
            if now.timeIntervalSince(lastMicrophoneCheck) >= 10 || now < lastMicrophoneCheck {
                lastMicrophoneCheck = now
                if capture.microphoneShouldChange {
                    trace("meeting: a working microphone appeared; switching to it")
                    if let id = await endCapture(reason: "Switching to a microphone that became available.", at: now, resumable: true) {
                        _ = await resumeInterrupted(now: now)
                        if activeID != id { finalizeLater(id) }
                    }
                }
            }
            return
        }
        guard !isStarting, !isStopping else { cancelCountdown(); return }
        if !consentConfirmed {
            cancelCountdown()
            for note in notes where note.autoResume == true && !note.event.isAdHoc {
                let wasInterrupted = note.phase == .interrupted
                mutate(note.id) { $0.autoResume = nil }; resumeAttempts[note.id] = nil
                if wasInterrupted { finalizeLater(note.id) }
            }
        }
        if await resumeInterrupted(now: now) { return }
        guard consentConfirmed else { return }
        guard let event = due(now) else { cancelCountdown(); return }
        if countdown?.id != event.id {
            countdown = event; countdownEnd = now.addingTimeInterval(10)
            trace("meeting: countdown for the meeting scheduled \(Self.clock(event.start))–\(Self.clock(event.end))")
            if !suppressHostAccess { StatusMenu.shared.meetingStatus(event.title, pending: true) }
            status = "Starting \(event.title) in 10 seconds. Cancel to skip this meeting."
            return
        }
        if let end = countdownEnd, now >= end {
            // A delayed timer (sleep, clock jump, busy run loop) gives a fresh 10 seconds to skip
            // the meeting rather than starting capture unannounced.
            guard now.timeIntervalSince(end) < 15 else {
                countdownEnd = now.addingTimeInterval(10); trace("meeting: countdown fired late; restarted"); return
            }
            cancelCountdown(); await start(event, now: now)
        }
    }
    /// The meeting to record now: started, still running, not skipped and not recorded yet, however
    /// late FlowClone finds it (the Mac was asleep, FlowClone was closed, the network was down).
    /// Of several at once: the one that started last, then one with a call link, then the shorter.
    private func due(_ now: Date) -> MeetingEvent? {
        guard autoStart, consentConfirmed, connected else { return nil }
        return upcoming.filter { event in
            automatic(event) && event.start <= now && event.end.timeIntervalSince(now) > 20
            && !notes.contains(where: { $0.event.id == event.id })
        }.min { a, b in
            if a.start != b.start { return a.start > b.start }
            if (a.joinURL != nil) != (b.joinURL != nil) { return a.joinURL != nil }
            if a.end != b.end { return a.end < b.end }
            return a.id < b.id
        }
    }
    /// Meetings run over. Past the scheduled end, recording continues while someone was heard in
    /// the last 45 seconds, for at most 30 minutes, and never into another scheduled meeting.
    private func stillTalking(_ note: MeetingNote, end: Date, now: Date) -> Bool {
        guard now.timeIntervalSince(end) < Self.overrunLimit, now.timeIntervalSince(note.startedAt) < 3 * 3600,
              due(now) == nil else { return false }
        return note.segments.contains { segment in
            now.timeIntervalSince(note.startedAt.addingTimeInterval(segment.offset + segment.duration)) < Self.overrunQuiet
            // Not transcribed yet counts as speech until the recognizer says otherwise.
            && (segment.text.map { !$0.isEmpty } ?? (segment.error == nil))
        }
    }
    /// A recording cut short by sleep, a microphone change, a relaunch or a failed start continues
    /// by itself while its meeting is still running. Stop, Skip and Delete end that.
    private func resumeInterrupted(now: Date) async -> Bool {
        guard let note = notes.first(where: { $0.autoResume == true }) else { return false }
        let listed = upcoming.first(where: { $0.id == note.event.id })
        let event = listed ?? note.event
        let attempts = resumeAttempts[note.id]
        let gone = connected && listed == nil && !event.calendarID.isEmpty
        guard event.isEligible, !gone, event.end.timeIntervalSince(now) > 20, !dismissed.contains(event.id),
              (attempts?.count ?? 0) < 12 else {
            let wasInterrupted = notes.first(where: { $0.id == note.id })?.phase == .interrupted
            mutate(note.id) { $0.autoResume = nil }; resumeAttempts[note.id] = nil
            if wasInterrupted { finalizeLater(note.id) }
            return false
        }
        guard !processing.contains(note.id), now >= (attempts?.next ?? .distantPast) else { return false }
        let count = (attempts?.count ?? 0) + 1
        resumeAttempts[note.id] = (count, now.addingTimeInterval(min(60, 5 * pow(2, Double(count)))))
        trace("meeting: continuing the interrupted recording (attempt \(count))")
        await start(event, now: now, resuming: note.id, adHocSessionConsent: event.isAdHoc, captureMode: note.captureMode)
        if activeID == note.id { resumeAttempts[note.id] = nil }
        return true
    }
    /// Whether this event is recorded without asking once automatic recording is on.
    func automatic(_ event: MeetingEvent) -> Bool {
        selectedCalendars.contains(event.calendarID) && !dismissed.contains(event.id)
            && (event.isAutomaticEligible || (event.isEligible && included.contains(event.id)))
    }
    /// The switch beside each upcoming event: off skips it, on records it even when it does not
    /// look like a meeting.
    func setAutomatic(_ event: MeetingEvent, _ on: Bool) {
        if on {
            dismissed.remove(event.id)
            defaults.set((defaults.stringArray(forKey: "meetingDismissedEvents") ?? []).filter { $0 != event.id }, forKey: "meetingDismissedEvents")
            if !event.isAutomaticEligible { included.insert(event.id) }
        } else {
            included.remove(event.id)
            dismiss(event)
        }
        var history = (defaults.stringArray(forKey: "meetingIncludedEvents") ?? []).filter { included.contains($0) }
        history += included.subtracting(history).sorted()
        defaults.set(Array(history.suffix(1000)), forKey: "meetingIncludedEvents")
        included = Set(history.suffix(1000))
    }
    func cancelCountdown() {
        let wasCounting = countdown != nil
        if countdown != nil { countdown = nil }
        if countdownEnd != nil { countdownEnd = nil }
        if wasCounting, activeID == nil, !suppressHostAccess { StatusMenu.shared.meetingStatus(nil) }
    }
    func dismiss(_ event: MeetingEvent) {
        dismissed.insert(event.id)
        // Bounded persistent suppression survives relaunch. Recently seen events stay last.
        var history = defaults.stringArray(forKey: "meetingDismissedEvents") ?? []
        history.removeAll { $0 == event.id }; history.append(event.id)
        defaults.set(Array(history.suffix(1000)), forKey: "meetingDismissedEvents")
        cancelCountdown(); status = "Skipped \(event.title)."
    }
    func alreadyRecorded(_ event: MeetingEvent) -> Bool {
        recordedEventIDs.contains(event.id)
    }
    private func refreshRecordedEventIDs() {
        var updated = Set<String>()
        updated.reserveCapacity(notes.count)
        for note in notes where note.phase != .failed || !note.segments.isEmpty {
            updated.insert(note.event.id)
        }
        if recordedEventIDs != updated { recordedEventIDs = updated }
    }
    func resume(_ id: UUID, now: Date = Date()) async {
        guard let note = notes.first(where: { $0.id == id }), !processing.contains(id) else { return }
        let event = upcoming.first(where: { $0.id == note.event.id }) ?? note.event
        guard event.end > now else { error = "This meeting has ended. Extend its calendar event and refresh before resuming."; return }
        await start(event, now: now, resuming: id, adHocSessionConsent: event.isAdHoc, captureMode: note.captureMode)
    }
    @discardableResult
    func startAdHocMeeting(title: String = MeetingEvent.defaultAdHocTitle, now: Date = Date()) async -> UUID? {
        load(now: now)
        guard !busy, !isImporting else { return activeID }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = !trimmed.isEmpty && trimmed != MeetingEvent.defaultAdHocTitle
        let event = MeetingEvent.adHoc(title: trimmed.isEmpty ? MeetingEvent.defaultAdHocTitle : trimmed, now: now)
        await start(event, now: now, adHocSessionConsent: true, captureMode: .call)
        if customTitle, let id = activeID {
            mutate(id) { $0.userRenamedTitle = true }
        }
        return activeID
    }
    @discardableResult
    func startInPersonMeeting(title: String = MeetingEvent.defaultInPersonTitle, now: Date = Date()) async -> UUID? {
        load(now: now)
        guard !busy, !isImporting else { return activeID }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = !trimmed.isEmpty && trimmed != MeetingEvent.defaultInPersonTitle
        let event = MeetingEvent.inPerson(title: trimmed.isEmpty ? MeetingEvent.defaultInPersonTitle : trimmed, now: now)
        await start(event, now: now, adHocSessionConsent: true, captureMode: .inPerson)
        if customTitle, let id = activeID {
            mutate(id) { $0.userRenamedTitle = true }
        }
        return activeID
    }
    func start(_ event: MeetingEvent, now: Date = Date(), resuming id: UUID? = nil,
               adHocSessionConsent: Bool = false, liveCallKey: String? = nil,
               captureMode: MeetingCaptureMode? = nil) async {
        flushPendingSaves()
        let isLiveSession = liveCallKey != nil || (id != nil && id == activeLiveCallNoteID)
        let sessionConsented = consentConfirmed
            || isLiveSession
            || (adHocSessionConsent && event.isAdHoc)
            || (id != nil && id == adHocSessionConsentID && event.isAdHoc)
        guard loaded, !busy, sessionConsented, event.isEligible else { return }
        var previous = id.flatMap { id in notes.first { $0.id == id && $0.event.id == event.id && !processing.contains(id) } }
        guard id == nil || previous != nil else { return }
        // A start that failed left an empty note; recording the meeting again fills that one.
        if previous == nil {
            previous = notes.first { $0.event.id == event.id && $0.phase == .failed && $0.segments.isEmpty && !processing.contains($0.id) }
        }
        guard previous != nil || !alreadyRecorded(event) else { return }
        let resolvedCaptureMode: MeetingCaptureMode = captureMode
            ?? previous?.captureMode
            ?? (event.isInPerson ? .inPerson : .call)
        isStarting = true; cancelCountdown(); error = nil; generation += 1
        let token = generation
        var startingNote = previous ?? MeetingNote(event: event, startedAt: now, captureMode: resolvedCaptureMode)
        startingNote.event = event; startingNote.phase = .recording; startingNote.endedAt = nil
        startingNote.issue = nil; startingNote.autoResume = nil; startingNote.captureMode = resolvedCaptureMode
        if startingNote.segments.isEmpty { startingNote.startedAt = now }
        let note = startingNote
        if adHocSessionConsent && event.isAdHoc {
            adHocSessionConsentID = note.id
        }
        if let liveCallKey {
            activeLiveCallKey = liveCallKey
            activeLiveCallNoteID = note.id
            liveCallMissingSince = nil
        }
        do {
            try store.save(note)
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
            else { notes.insert(note, at: 0) }
            refreshRecordedEventIDs()
            selectedNoteID = note.id; activeID = note.id
            updateTimerSchedule(now: now)
            try await capture.start(directory: store.directory(note.id), startedAt: note.startedAt,
                                    initialOffsets: Self.initialOffsets(for: note.segments),
                                    captureMode: resolvedCaptureMode, segment: { [weak self] segment in
                Task { @MainActor in self?.received(segment, id: note.id) }
            }, failed: { [weak self] message, resumable in
                Task { @MainActor in
                    guard let self, self.activeID == note.id else { return }
                    await self.interrupted(reason: message, resumable: resumable)
                }
            })
            isStarting = false
            if token != generation || suspended { await stop(reason: "Recording start was cancelled.", resumable: suspended); return }
            if !suppressHostAccess { StatusMenu.shared.meetingStatus(event.title) }
            status = resolvedCaptureMode == .inPerson
                ? "Recording \(event.title) · in-person (microphone only)"
                : "Recording \(event.title) · microphone + system audio"
            trace("meeting: recording started \(Int(now.timeIntervalSince(event.start)))s after the scheduled start\(previous == nil ? "" : " (resumed)")\(liveCallKey == nil ? "" : " (live call)")\(resolvedCaptureMode == .inPerson ? " (in-person)" : "")")
        } catch {
            _ = try? await capture.stop()
            // Tried again by itself while the meeting runs (say, once a permission is granted).
            // A failed continuation leaves what was already recorded and summarized as it was.
            let kept = [previous].compactMap { $0 }.first { !$0.segments.isEmpty }
            mutate(note.id) {
                $0.phase = kept?.phase ?? .failed; $0.issue = error.localizedDescription
                $0.endedAt = kept?.endedAt ?? Date()
                $0.autoResume = (kept != nil || (!event.isAdHoc && liveCallKey == nil)) ? true : nil
            }
            if activeLiveCallNoteID == note.id {
                if let liveCallKey { suppressedLiveCallKey = liveCallKey }
                activeLiveCallKey = nil
                activeLiveCallNoteID = nil
                liveCallMissingSince = nil
            }
            activeID = nil; isStarting = false; self.error = error.localizedDescription
            updateTimerSchedule(now: now)
            trace("meeting: recording failed to start: \(error.localizedDescription)")
            notifyOnce("FlowClone could not record \(event.title): \(error.localizedDescription)")
        }
    }
    private func received(_ segment: MeetingSegment, id: UUID) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == id }),
              !notes[noteIndex].segments.contains(where: { $0.id == segment.id }) else { return }
        mutate(id) { note in
            if let last = note.segments.last, segment.offset < last.offset,
               let insertAt = note.segments.firstIndex(where: { $0.offset > segment.offset }) {
                note.segments.insert(segment, at: insertAt)
            } else {
                note.segments.append(segment)
            }
        }
        drain()
    }
    private func drain() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while let note = self.notes.first(where: { $0.segments.contains(where: { $0.text == nil && $0.error == nil }) }),
                  let segment = note.segments.first(where: { $0.text == nil && $0.error == nil }) {
                do {
                    let text = try await self.transcriber.transcribe(url: self.store.directory(note.id).appendingPathComponent(segment.audioFile))
                    self.mutate(note.id) { note in
                        if let index = note.segments.firstIndex(where: { $0.id == segment.id }) { note.segments[index].text = text }
                    }
                } catch {
                    self.mutate(note.id) { note in
                        if let index = note.segments.firstIndex(where: { $0.id == segment.id }) { note.segments[index].error = error.localizedDescription }
                    }
                }
            }
            self.worker = nil
        }
    }
    /// `resumable`: capture ended without the person asking (sleep, a device change), so it
    /// continues by itself while the meeting is still running.
    func stop(reason: String? = nil, at endTime: Date = Date(), resumable: Bool = false) async {
        flushPendingSaves()
        if !resumable, let key = activeLiveCallKey {
            suppressedLiveCallKey = key
        }
        if let id = await endCapture(reason: reason, at: endTime, resumable: resumable) { await finalize(id) }
    }
    /// Capture broke off by itself (a microphone change). The recording continues at once when
    /// it can, so only a few seconds are lost; otherwise what was recorded is summarized.
    private func interrupted(reason: String, resumable: Bool) async {
        guard let id = await endCapture(reason: reason, at: Date(), resumable: resumable) else { return }
        if resumable, !suspended { _ = await resumeInterrupted(now: Date()) }
        if activeID != id { await finalize(id) }
    }
    /// Stops capture and keeps every saved segment. Returns the note to summarize.
    private func endCapture(reason: String?, at endTime: Date, resumable: Bool = false) async -> UUID? {
        flushPendingSaves()
        if isStarting { generation += 1; return nil }
        guard let id = activeID, !isStopping else { return nil }
        isStopping = true
        if overrunID == id { overrunID = nil }
        if !resumable, adHocSessionConsentID == id { adHocSessionConsentID = nil }
        if !resumable, activeLiveCallNoteID == id {
            activeLiveCallKey = nil
            activeLiveCallNoteID = nil
            liveCallMissingSince = nil
        }
        mutate(id) {
            $0.endedAt = max(endTime, $0.startedAt); $0.phase = .processing; if let reason { $0.issue = reason }
            $0.autoResume = resumable ? true : nil
        }
        do {
            for segment in try await capture.stop() { received(segment, id: id) }
        } catch {
            mutate(id) { $0.issue = "Stopping capture failed: \(error.localizedDescription). Saved audio is retained." }
            if let note = notes.first(where: { $0.id == id }), let recovered = try? store.recoveredSegments(for: note) {
                for segment in recovered { received(segment, id: id) }
            }
        }
        activeID = nil; isStopping = false
        updateTimerSchedule(now: endTime)
        if !suppressHostAccess { StatusMenu.shared.meetingStatus(nil) }
        trace("meeting: capture stopped (\(reason ?? "scheduled end or Stop")); \(notes.first { $0.id == id }?.segments.count ?? 0) audio segments")
        return id
    }
    private func finalize(_ id: UUID) async {
        guard processing.insert(id).inserted else { return }
        let task = Task { [weak self] in
            await self?.summarize(id)
            self?.finalizers[id] = nil
        }
        finalizers[id] = task
        await task.value
    }
    /// Claims the note at once so a resume or retry cannot slip in before the summary starts.
    private func finalizeLater(_ id: UUID) {
        guard processing.insert(id).inserted else { return }
        finalizers[id] = Task { [weak self] in
            await self?.summarize(id)
            self?.finalizers[id] = nil
        }
    }
    /// Waits for summaries and GitHub uploads started by the scheduler (tests, quit draining, and the hands-free mock).
    func settle(timeout: TimeInterval? = nil) async {
        flushPendingSaves()
        guard let timeout else {
            while let task = finalizers.values.first ?? githubTasks.values.first {
                await task.value
            }
            flushPendingSaves()
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while (!finalizers.isEmpty || !processing.isEmpty || !githubTasks.isEmpty || !publishingToGitHub.isEmpty), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        flushPendingSaves()
    }
    /// Stops active capture and drains in-flight summaries up to `timeout` before app exit.
    /// Relaunches and unexpected terminations during an automatic meeting keep `autoResume` set.
    func prepareForTermination(relaunching: Bool, explicitQuit: Bool, timeout: TimeInterval = 10) async {
        flushPendingSaves()
        cancelCountdown()
        let deadline = Date().addingTimeInterval(timeout)
        if isStarting {
            generation += 1
            while isStarting, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        if let active = activeNote {
            let shouldResume = relaunching || (!explicitQuit && autoStart && automatic(active.event))
            let reason: String? = relaunching
                ? "FlowClone restarted; recording will continue automatically."
                : (shouldResume ? "FlowClone closed during the recording; saved audio will continue automatically." : nil)
            if let id = await endCapture(reason: reason, at: Date(), resumable: shouldResume) {
                if shouldResume {
                    mutate(id) { $0.phase = .interrupted }
                } else {
                    finalizeLater(id)
                }
            }
        }
        await settle(timeout: max(0, deadline.timeIntervalSinceNow))
    }
    private func summarize(_ id: UUID) async {
        defer { processing.remove(id) }
        drain(); await worker?.value
        guard let note = notes.first(where: { $0.id == id }) else { return }
        let result = await summarizer.summarize(note)
        guard activeID != id else { return }  // Recording again; the summary is written when it ends.
        mutate(id) {
            $0.summary = result.text; $0.summaryMethod = result.method
            if $0.event.isAdHoc, !$0.userRenamedTitle,
               MeetingEvent.isGenericAutoTitle($0.event.title),
               let derived = LocalMeetingSummarizer.deriveTitle(
                   summary: result.text,
                   transcript: note.transcript,
                   personalNotes: note.personalNotes
               ) {
                $0.event.title = derived
            }
            if $0.segments.contains(where: { $0.error != nil }) {
                $0.phase = .failed; $0.issue = "Some audio could not be transcribed. This summary is partial. Retry saved audio."
            } else {
                $0.phase = .complete
                if $0.issue?.hasPrefix("Some audio could not be transcribed.") == true { $0.issue = nil }
            }
        }
        searchBodyCache[id] = nil
        if let saved = notes.first(where: { $0.id == id }) {
            trace("meeting: saved phase=\(saved.phase.rawValue) segments=\(saved.segments.count) transcript=\(saved.transcript.split(separator: " ").count) words summary=\(saved.summary.split(separator: " ").count) words (\(saved.summaryMethod))")
            if shouldAutoPublishToGitHub(saved) {
                publishToGitHubLater(id, automatic: true)
            }
        }
        if error == nil, activeID == nil, countdown == nil, !isStarting { status = "Meeting saved." }
    }
    /// Regenerates the summary for an existing meeting note using the currently configured model
    /// (e.g., Claude Sonnet 5.5) without re-transcribing saved audio.
    func resummarize(_ id: UUID) async {
        flushPendingSaves()
        guard activeID != id, !processing.contains(id), notes.contains(where: { $0.id == id }) else { return }
        await finalize(id)
    }
    func retry(_ id: UUID) async {
        flushPendingSaves()
        guard activeID != id, !processing.contains(id) else { return }
        do {
            if let note = notes.first(where: { $0.id == id }) {
                let segments = try store.recoveredSegments(for: note)
                mutate(id) { note in
                    note.segments = segments.map { segment in var copy = segment; copy.error = nil; return copy }
                    note.phase = .processing
                }
            }
            await finalize(id)
        } catch { self.error = error.localizedDescription }
    }
    func updateNotes(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].personalNotes != text else { return }
        notes[index].personalNotes = text
        scheduleNoteSave(id)
    }
    func renameMeeting(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].event.title != trimmed || !notes[index].userRenamedTitle else { return }
        notes[index].event.title = trimmed
        notes[index].userRenamedTitle = true
        scheduleNoteSave(id)
    }
    func toggleActionItem(_ id: UUID, item: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[index].completedActionItems.contains(item) {
            notes[index].completedActionItems.remove(item)
        } else {
            notes[index].completedActionItems.insert(item)
        }
        scheduleNoteSave(id)
    }
    @discardableResult
    func importAudioFile(at url: URL, now: Date = Date()) async -> UUID? {
        load(now: now)
        flushPendingSaves()
        guard !isImporting else { return nil }
        guard MeetingAudioImporter.isSupported(url) else {
            error = "Unsupported audio format (.\(url.pathExtension)). Choose an .m4a, .mp3, .wav, or .mp4 file."
            return nil
        }
        isImporting = true
        error = nil
        status = "Importing \(url.lastPathComponent)…"
        defer { isImporting = false }
        do {
            let samples = try await MeetingAudioImporter.load16kMonoSamples(from: url)
            let duration = max(1, Double(samples.count) / 16_000)
            let cleanedBaseName = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let event = MeetingEvent.imported(
                title: cleanedBaseName.isEmpty ? "Imported Recording" : cleanedBaseName,
                now: now,
                duration: duration
            )
            var note = MeetingNote(
                event: event,
                startedAt: now,
                endedAt: now.addingTimeInterval(duration),
                phase: .processing,
                userRenamedTitle: !cleanedBaseName.isEmpty
            )
            let chunks = try await transcriber.transcribeSamples(
                samples,
                sourceURL: url,
                progress: { [weak self] fraction in
                    let pct = min(100, max(0, Int((fraction * 100).rounded())))
                    Task { @MainActor in
                        guard let self, self.isImporting else { return }
                        self.status = "Transcribing \(url.lastPathComponent) (\(pct)%)…"
                    }
                }
            )
            let directory = store.directory(note.id)
            var segments = try await Task.detached(priority: .userInitiated) {
                try MeetingAudioImporter.writeSegments(samples: samples, into: directory)
            }.value
            for index in segments.indices {
                let segOffset = segments[index].offset
                if let matched = chunks.first(where: { abs($0.offset - segOffset) < 0.05 }) {
                    segments[index].text = matched.text
                } else {
                    segments[index].text = ""
                }
            }
            note.segments = segments
            try store.save(note)
            notes.insert(note, at: 0)
            refreshRecordedEventIDs()
            selectedNoteID = note.id
            await finalize(note.id)
            return note.id
        } catch {
            self.status = ""
            self.error = error.localizedDescription
            return nil
        }
    }
    func filteredNotes(matching query: String) -> [MeetingNote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }
        let _ = searchIndexVersion
        let terms = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return notes }

        return notes.filter { note in
            let headerHaystack = (
                note.event.title + "\n"
                + note.event.attendees.joined(separator: " ") + "\n"
                + note.summary + "\n"
                + note.personalNotes
            ).lowercased()
            if terms.allSatisfy({ headerHaystack.contains($0) }) {
                return true
            }
            let revision = Self.searchRevision(for: note)
            if let cached = searchBodyCache[note.id], cached.revisionKey == revision {
                let combined = headerHaystack + "\n" + cached.bodyLower
                return terms.allSatisfy { combined.contains($0) }
            }
            if note.segments.count <= 80 {
                let bodyLower = Self.joinedSegmentTextLowercased(note.segments)
                searchBodyCache[note.id] = (revision, bodyLower)
                let combined = headerHaystack + "\n" + bodyLower
                return terms.allSatisfy { combined.contains($0) }
            }
            warmSearchBodyCache(for: note, revision: revision)
            return false
        }
    }
    private static func searchRevision(for note: MeetingNote) -> Int {
        var hasher = Hasher()
        hasher.combine(note.segments.count)
        hasher.combine(note.segments.last?.text?.count ?? -1)
        hasher.combine(note.segments.first?.text?.count ?? -1)
        return hasher.finalize()
    }
    nonisolated private static func joinedSegmentTextLowercased(_ segments: [MeetingSegment]) -> String {
        var result = ""
        for segment in segments {
            guard let text = segment.text, !text.isEmpty else { continue }
            if !result.isEmpty { result.append("\n") }
            result.append(text.lowercased())
        }
        return result
    }
    private func warmSearchBodyCache(for note: MeetingNote, revision: Int) {
        guard searchWarmingIDs.insert(note.id).inserted else { return }
        let id = note.id
        let segments = note.segments
        Task.detached(priority: .utility) { [weak self] in
            let lowered = Self.joinedSegmentTextLowercased(segments)
            await MainActor.run {
                guard let self else { return }
                self.searchWarmingIDs.remove(id)
                self.searchBodyCache[id] = (revision, lowered)
                self.searchIndexVersion += 1
            }
        }
    }
    private func scheduleNoteSave(_ id: UUID) {
        pendingNoteSaves.insert(id)
        noteSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPendingSaves() }
        }
        noteSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func flushPendingSaves() {
        noteSaveWork?.cancel()
        noteSaveWork = nil
        guard !pendingNoteSaves.isEmpty else { return }
        let ids = pendingNoteSaves
        pendingNoteSaves.removeAll()
        for id in ids {
            guard let index = notes.firstIndex(where: { $0.id == id }) else { continue }
            persistNote(at: index)
        }
    }
    func delete(_ id: UUID) {
        guard activeID != id, !processing.contains(id), !publishingToGitHub.contains(id), worker == nil else { return }
        githubTasks[id]?.cancel()
        githubTasks[id] = nil
        githubRetryAttempts[id] = nil
        pendingNoteSaves.remove(id)
        searchBodyCache[id] = nil
        searchWarmingIDs.remove(id)
        do {
            if let note = notes.first(where: { $0.id == id }) { dismiss(note.event) }
            try store.remove(id); notes.removeAll { $0.id == id }
            refreshRecordedEventIDs()
            if selectedNoteID == id { selectedNoteID = nil }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - GitHub Publishing

    /// Maximum automatic retry attempts when GitHub is temporarily unreachable.
    static let maxGitHubAutoRetries = 6

    func saveGitHubConfig() {
        if let cleanFolder = GitHubPublishConfig.validatedFolder(githubConfig.folder) {
            githubConfig.folder = cleanFolder
        }
        if let cleanBranch = GitHubPublishConfig.validatedBranch(githubConfig.branch) {
            githubConfig.branch = cleanBranch
        }
        if let encoded = try? JSONEncoder().encode(githubConfig) {
            defaults.set(encoded, forKey: GitHubPublishConfig.defaultsKey)
        }
        updateTimerSchedule()
    }

    func refreshGitHubConnectionState() {
        switch githubPublisher.tokenLoadState() {
        case .found:
            githubConnected = true
        case .missing:
            githubConnected = false
        case .unavailable:
            break
        }
    }

    func connectGitHub(token rawToken: String) async {
        guard !githubConnecting else { return }
        guard let normalized = GitHubTokenValidator.normalized(rawToken) else {
            githubError = "Paste a valid GitHub personal access token."
            return
        }
        githubConnecting = true
        githubError = nil
        githubStatus = "Checking GitHub token…"
        defer { githubConnecting = false }
        do {
            let username = try await githubPublisher.verifyToken(normalized)
            guard githubPublisher.saveToken(normalized) else {
                githubError = "Your GitHub token could not be saved to this Mac’s Keychain."
                githubStatus = ""
                return
            }
            githubConnected = true
            githubConfig.connectedUsername = username
            saveGitHubConfig()
            trace("meeting github: connected")
            githubStatus = "Connected as @\(username)."
            await refreshGitHubRepositories()
            if githubConfig.repository.isEmpty, githubRepos.count == 1, let onlyRepo = githubRepos.first {
                githubConfig.repository = onlyRepo.fullName
                githubConfig.defaultBranchCache = onlyRepo.defaultBranch
                saveGitHubConfig()
                githubStatus = "Ready to publish to \(onlyRepo.fullName) (\(onlyRepo.defaultBranch))."
            } else if let existingRepo = githubConfig.parsedRepo {
                if let verified = try? await githubPublisher.verifyRepository(existingRepo) {
                    githubConfig.repository = verified.fullName
                    githubConfig.defaultBranchCache = verified.defaultBranch
                    saveGitHubConfig()
                    githubStatus = "Ready to publish to \(verified.fullName) (\(githubConfig.displayBranch))."
                }
            }
        } catch {
            githubError = error.localizedDescription
            githubStatus = ""
        }
    }

    func disconnectGitHub() {
        githubPublisher.clearToken()
        githubConnected = false
        githubRepos = []
        githubRetryAttempts.removeAll()
        githubConfig.connectedUsername = nil
        githubConfig.autoPublish = false
        saveGitHubConfig()
        githubError = nil
        githubStatus = "Disconnected from GitHub."
        trace("meeting github: disconnected")
    }

    func refreshGitHubRepositories() async {
        guard githubConnected, !githubLoadingRepos else { return }
        githubLoadingRepos = true
        defer { githubLoadingRepos = false }
        do {
            let repos = try await githubPublisher.listRepositories()
            githubRepos = repos
            if let current = githubConfig.parsedRepo,
               let match = repos.first(where: { $0.fullName.caseInsensitiveCompare(current.fullName) == .orderedSame }) {
                githubConfig.defaultBranchCache = match.defaultBranch
                saveGitHubConfig()
            }
        } catch let failure as GitHubPublishFailure {
            // Single-repo fine-grained tokens may still work with a typed owner/repo even if /user/repos fails.
            if failure.statusCode == 401 {
                githubError = failure.localizedDescription
            }
            trace("meeting github: repo list failed (status=\(failure.statusCode ?? 0))")
        } catch {
            trace("meeting github: repo list failed")
        }
    }

    @discardableResult
    func configureGitHubRepository(_ rawRepo: String, branch: String? = nil, folder: String? = nil) async -> Bool {
        githubError = nil
        guard let repo = GitHubRepoID.parse(rawRepo) else {
            githubError = "Enter a GitHub repository like owner/repo or paste its github.com URL."
            return false
        }
        let nextFolder: String
        if let folder {
            guard let validated = GitHubPublishConfig.validatedFolder(folder) else {
                githubError = "Folder path can’t contain “..”, backslashes, or special URL characters."
                return false
            }
            nextFolder = validated
        } else {
            nextFolder = githubConfig.folder
        }
        let nextBranch: String
        if let branch {
            guard let validated = GitHubPublishConfig.validatedBranch(branch) else {
                githubError = "Branch name isn’t valid. Leave it blank to use the repository’s default branch."
                return false
            }
            nextBranch = validated
        } else {
            nextBranch = githubConfig.branch
        }
        githubConnecting = true
        githubStatus = "Checking access to \(repo.fullName)…"
        defer { githubConnecting = false }
        do {
            let verified = try await githubPublisher.verifyRepository(repo)
            githubConfig.repository = verified.fullName
            githubConfig.defaultBranchCache = verified.defaultBranch
            githubConfig.folder = nextFolder
            githubConfig.branch = nextBranch
            saveGitHubConfig()
            if !githubRepos.contains(where: { $0.fullName.caseInsensitiveCompare(verified.fullName) == .orderedSame }) {
                githubRepos.insert(verified, at: 0)
            }
            githubStatus = "Verified \(verified.fullName) (\(githubConfig.displayBranch))."
            trace("meeting github: verified repository")
            return true
        } catch {
            githubError = error.localizedDescription
            githubStatus = ""
            return false
        }
    }

    func hasUnsyncedGitHubChanges(for note: MeetingNote) -> Bool {
        guard let state = note.githubPublish, state.status == .published else { return false }
        if let target = githubConfig.parsedRepo,
           state.repository.caseInsensitiveCompare(target.fullName) != .orderedSame {
            return true
        }
        let cleanBranch = GitHubPublishConfig.validatedBranch(githubConfig.branch) ?? ""
        if state.branch != cleanBranch {
            return true
        }
        guard let publishedHash = state.contentHash else { return true }
        return MeetingGitHubDocument.contentHash(
            for: note,
            includeTranscript: githubConfig.includeTranscript
        ) != publishedHash
    }

    private func shouldAutoPublishToGitHub(_ note: MeetingNote) -> Bool {
        guard githubConfig.autoPublish, githubConnected, githubConfig.isConfigured else { return false }
        guard note.phase == .complete else { return false }
        let hasContent = !note.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.personalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return false }
        if let existing = note.githubPublish, existing.status == .published {
            return hasUnsyncedGitHubChanges(for: note)
        }
        return true
    }

    private func publishToGitHubLater(_ id: UUID, automatic: Bool, now: Date = Date()) {
        guard publishingToGitHub.insert(id).inserted else { return }
        githubTasks[id] = Task { [weak self] in
            await self?.runGitHubPublish(id, automatic: automatic, now: now)
            self?.githubTasks[id] = nil
        }
    }

    /// Manually publishes (or updates) a meeting note to the configured GitHub repository.
    func publishNoteToGitHub(_ id: UUID) async {
        flushPendingSaves()
        guard notes.contains(where: { $0.id == id }), !processing.contains(id) else { return }
        if let inFlight = githubTasks[id] {
            await inFlight.value
            return
        }
        guard publishingToGitHub.insert(id).inserted else { return }
        let task = Task { [weak self] in
            await self?.runGitHubPublish(id, automatic: false)
            self?.githubTasks[id] = nil
        }
        githubTasks[id] = task
        await task.value
    }

    private func runGitHubPublish(_ id: UUID, automatic: Bool, now: Date = Date()) async {
        defer {
            publishingToGitHub.remove(id)
            updateTimerSchedule()
        }
        flushPendingSaves()
        guard let note = notes.first(where: { $0.id == id }) else { return }
        let config = githubConfig
        guard githubConnected, config.isConfigured else {
            if !automatic {
                githubError = "Connect GitHub and choose a repository first in Meetings → GitHub."
            }
            return
        }
        githubError = nil
        do {
            let result = try await githubPublisher.publish(note: note, config: config)
            githubRetryAttempts[id] = nil
            mutate(id) { target in
                target.githubPublish = MeetingGitHubState(
                    status: .published,
                    repository: result.repository,
                    branch: result.branch,
                    resolvedBranch: result.resolvedBranch,
                    path: result.path,
                    sha: result.sha,
                    commitSHA: result.commitSHA,
                    htmlURL: result.htmlURL,
                    publishedAt: result.publishedAt,
                    contentHash: result.contentHash,
                    error: nil
                )
            }
            githubStatus = "Published to \(result.repository)."
            trace("meeting github: published note (automatic=\(automatic))")
        } catch let failure as GitHubPublishFailure {
            handleGitHubPublishFailure(id: id, failure: failure, config: config, automatic: automatic, now: now)
        } catch {
            let wrapped = GitHubPublishFailure(error.localizedDescription, isTransient: false)
            handleGitHubPublishFailure(id: id, failure: wrapped, config: config, automatic: automatic, now: now)
        }
    }

    private func handleGitHubPublishFailure(
        id: UUID,
        failure: GitHubPublishFailure,
        config: GitHubPublishConfig,
        automatic: Bool,
        now: Date
    ) {
        let attempts = (githubRetryAttempts[id]?.count ?? 0) + 1
        let canAutoRetry = automatic && failure.isTransient && attempts < Self.maxGitHubAutoRetries
        if canAutoRetry {
            let delay = min(600.0, 30.0 * pow(2.0, Double(attempts - 1)))
            githubRetryAttempts[id] = (attempts, now.addingTimeInterval(delay))
        } else {
            githubRetryAttempts[id] = nil
        }

        let targetRepo = config.parsedRepo?.fullName ?? config.repository
        let explicitBranch = GitHubPublishConfig.validatedBranch(config.branch) ?? ""
        mutate(id) { target in
            let prior = target.githubPublish
            let sameTarget = prior.map {
                $0.repository.caseInsensitiveCompare(targetRepo) == .orderedSame && $0.branch == explicitBranch
            } ?? false
            target.githubPublish = MeetingGitHubState(
                status: canAutoRetry ? .pendingRetry : .failed,
                repository: sameTarget ? (prior?.repository ?? targetRepo) : targetRepo,
                branch: sameTarget ? (prior?.branch ?? explicitBranch) : explicitBranch,
                resolvedBranch: sameTarget ? (prior?.resolvedBranch ?? config.displayBranch) : config.displayBranch,
                path: sameTarget ? (prior?.path ?? "") : "",
                sha: sameTarget ? prior?.sha : nil,
                commitSHA: sameTarget ? prior?.commitSHA : nil,
                htmlURL: sameTarget ? prior?.htmlURL : nil,
                publishedAt: sameTarget ? prior?.publishedAt : nil,
                contentHash: sameTarget ? prior?.contentHash : nil,
                error: failure.localizedDescription
            )
        }
        githubError = failure.localizedDescription
        trace("meeting github: publish failed (automatic=\(automatic) transient=\(failure.isTransient) status=\(failure.statusCode ?? 0))")
        if automatic, !canAutoRetry {
            notifyOnce("Could not publish meeting note to GitHub: \(failure.localizedDescription)")
        }
    }

    private func retryPendingGitHubPublishes(now: Date) {
        guard githubConfig.autoPublish, githubConnected, githubConfig.isConfigured else { return }
        for note in notes where note.githubPublish?.status == .pendingRetry {
            guard !publishingToGitHub.contains(note.id), !processing.contains(note.id) else { continue }
            if let attempt = githubRetryAttempts[note.id], now < attempt.next {
                continue
            }
            publishToGitHubLater(note.id, automatic: true, now: now)
        }
    }
    private func traceOnce(_ message: String) {
        guard message != lastTrace else { return }
        lastTrace = message; trace(message)
    }
    private static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
    private func persistNote(at index: Int) {
        let id = notes[index].id
        pendingNoteSaves.remove(id)
        do { try store.save(notes[index]) }
        catch {
            notes[index].phase = .failed
            notes[index].issue = "Storage failed. Some recent changes may not have been saved."
            refreshRecordedEventIDs()
            self.error = "Meeting could not be saved: \(error.localizedDescription)"
            if activeID == id, !isStopping { Task { await self.stop(reason: "Storage failed; capture was stopped.") } }
        }
    }
    private func mutate(_ id: UUID, _ body: (inout MeetingNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let before = notes[index]
        var updated = before
        body(&updated)
        guard updated != before else {
            if pendingNoteSaves.contains(id) { persistNote(at: index) }
            return
        }
        notes[index] = updated
        refreshRecordedEventIDs()
        persistNote(at: index)
    }
}
