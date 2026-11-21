import AVFoundation
import XCTest
@testable import FlowCloneCore

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ next: Value) { lock.withLock { value = next } }
    func modify(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class FlakyKeychainStore: GoogleSessionStoring, @unchecked Sendable {
    private let stateBox: LockedBox<GoogleSessionLoadState>
    private let savedBox: LockedBox<GoogleSession?>

    init(initialState: GoogleSessionLoadState, saved: GoogleSession? = nil) {
        self.stateBox = LockedBox(initialState)
        self.savedBox = LockedBox(saved)
    }

    func setLoadState(_ state: GoogleSessionLoadState) { stateBox.set(state) }
    func savedSession() -> GoogleSession? { savedBox.get() }

    func load() -> GoogleSession? {
        if case .found(let session) = stateBox.get() { return session }
        return nil
    }
    func loadState() -> GoogleSessionLoadState { stateBox.get() }
    func save(_ session: GoogleSession) -> Bool {
        savedBox.set(session)
        stateBox.set(.found(session))
        return true
    }
    func clear() {
        savedBox.set(nil)
        stateBox.set(.missing)
    }
}

private final class StubGoogleHTTP: GoogleHTTP, @unchecked Sendable {
    private let handlerBox: LockedBox<@Sendable (URLRequest) -> (Int, Any)>
    init(handler: @escaping @Sendable (URLRequest) -> (Int, Any)) {
        self.handlerBox = LockedBox(handler)
    }
    func setHandler(_ handler: @escaping @Sendable (URLRequest) -> (Int, Any)) {
        handlerBox.set(handler)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = handlerBox.get()(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

@MainActor private final class FakeCallDetector: MeetingCallDetecting {
    var activeCall: DetectedMeetingCall?
    var started = false
    private var onChange: (@MainActor () -> Void)?

    func start(onChange: @escaping @MainActor () -> Void) {
        started = true
        self.onChange = onChange
    }
    func stop() {
        started = false
        onChange = nil
    }
    func currentCall(hasActiveCalendarEvent: Bool) -> DetectedMeetingCall? {
        activeCall
    }
    func emitChange() {
        onChange?()
    }
}

@MainActor private final class UpgradeTestCalendar: MeetingCalendarProviding {
    var source: MeetingCalendarSource = .google
    var account: String? = "andre@example.com"
    var entries: [MeetingEvent] = []
    var nextError: Error?

    func connect(_ source: MeetingCalendarSource) async throws { self.source = source }
    func calendars() async throws -> [MeetingCalendar] {
        if let nextError { throw nextError }
        return [.init(id: "primary", title: "Primary", account: account ?? "Google", primary: true)]
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        if let nextError { throw nextError }
        return entries.filter { calendarIDs.contains($0.calendarID) && $0.end > from && $0.start < to }
    }
}

@MainActor private final class UpgradeTestCapture: MeetingCapturing {
    var starts = 0
    var stops = 0
    var segments: [MeetingSegment] = []
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (String, Bool) -> Void) async throws {
        starts += 1
    }
    func stop() async throws -> [MeetingSegment] {
        stops += 1
        return segments
    }
}

private actor UpgradeTestTranscriber: MeetingTranscribing {
    var transcript = "We reviewed the Q4 launch budget of $42,000 and decided to roll out to 25% of users on November 24."
    func transcribe(url: URL) async throws -> String { transcript }
}

private actor CountingSummarizer: MeetingSummarizing {
    var calls = 0
    var reply = MeetingSummary(
        text: "## Overview\nReviewed Q4 launch budget and rollout.\n\n## Action Items\n- Maya to finalize checklist by Thursday.",
        method: "Claude Sonnet 5.5"
    )
    func setReply(_ next: MeetingSummary) { reply = next }
    func summarize(_ note: MeetingNote) async -> MeetingSummary {
        calls += 1
        return reply
    }
}

@MainActor final class MeetingUpgradesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Claude Sonnet 5.5 Meeting Summarizer

    func testClaudeMeetingSummarizerBuildsSonnet55RequestFiltersThinkingAndExtractsActionItems() async throws {
        let capturedRequests = LockedBox<[URLRequest]>([])
        let summaryMarkdown = """
        ## Overview
        The team finalized the Q4 rollout budget ($42,000) and November 24 launch date.

        ## Key Discussion & Details
        - **Rollout phasing:** Starting at 25% traffic for 48 hours before full release.
        - **Budget cap:** Hard limit of $42,000 for cloud compute.

        ## Decisions
        - Approved 25% canary rollout starting November 24.

        ## Action Items
        - Maya to publish the launch checklist by Thursday at 5 PM.
        - Alex to verify billing alerts before November 24.

        ## Open Questions & Risks
        None stated.
        """
        let claude = ClaudeMeetingSummarizer(
            keyProvider: { "sk-ant-test-key" },
            transport: { request in
                capturedRequests.modify { $0.append(request) }
                let payload: [String: Any] = [
                    "stop_reason": "end_turn",
                    "content": [
                        ["type": "thinking", "thinking": "Internal reasoning that must not appear."],
                        ["type": "text", "text": summaryMarkdown]
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, http)
            }
        )
        let summarizer = LocalMeetingSummarizer(
            claude: claude,
            modelSetting: { .automatic },
            allowOnDevice: false
        )

        let input = MeetingSummaryInput(
            title: "Q4 Launch Sync",
            personalNotes: "Watch the $42k budget cap",
            transcript: "[00:10] You · microphone: Let's cap compute at $42,000 and launch 25% on November 24.",
            attendees: ["Maya", "Alex"],
            startedAt: now,
            durationSeconds: 1800
        )
        let result = await summarizer.summarize(input)

        XCTAssertEqual(result.method, "Claude Sonnet 5.5 · from your notes & transcript")
        XCTAssertTrue(result.text.contains("$42,000"))
        XCTAssertFalse(result.text.contains("Internal reasoning"))

        let req = try XCTUnwrap(capturedRequests.get().first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        let userContent = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? String)
        XCTAssertTrue(userContent.contains("<meeting_context>"))
        XCTAssertTrue(userContent.contains("Title: Q4 Launch Sync"))
        XCTAssertTrue(userContent.contains("Calendar invitees: Maya, Alex"))
        XCTAssertTrue(userContent.contains("<personal_notes>"))
        XCTAssertTrue(userContent.contains("<transcript>"))

        // Action items & title derivation work cleanly on Sonnet 5.5's Markdown structure.
        let actions = MeetingActionItems.extract(from: result.text)
        XCTAssertEqual(actions, [
            "Maya to publish the launch checklist by Thursday at 5 PM.",
            "Alex to verify billing alerts before November 24."
        ])
        let derivedTitle = LocalMeetingSummarizer.deriveTitle(summary: result.text, transcript: input.transcript)
        XCTAssertNotNil(derivedTitle)
        XCTAssertFalse(derivedTitle?.lowercased().contains("overview") ?? true)
    }

    func testClaudeMeetingSummarizerUsesChunkAndSynthesisForUltraLongMeetingsAndFallsBackCleanly() async throws {
        let callCount = LockedBox(0)
        let claude = ClaudeMeetingSummarizer(
            keyProvider: { "sk-ant-test-key" },
            transport: { request in
                let index = { () -> Int in
                    var n = 0
                    callCount.modify { $0 += 1; n = $0 }
                    return n
                }()
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
                let userContent = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? String)
                let replyText = index < 3
                    ? "- Extracted detail from chunk \(index)"
                    : "## Overview\nSynthesized full 3-hour roadmap review.\n\n## Action Items\n- Ship v2."
                if index == 3 {
                    XCTAssertTrue(userContent.contains("<segment_notes>"))
                    XCTAssertTrue(userContent.contains("Part 1 of 2"))
                    XCTAssertTrue(userContent.contains("Part 2 of 2"))
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "stop_reason": "end_turn",
                    "content": [["type": "text", "text": replyText]]
                ])
                let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, http)
            }
        )

        let hugeLine = String(repeating: "Architecture discussion about latency targets and rollout. ", count: 25) + "\n"
        let hugeTranscript = String(repeating: hugeLine, count: 90)  // > 120,000 chars
        XCTAssertGreaterThan(hugeTranscript.count, ClaudeMeetingSummarizer.singlePassCharLimit)

        let summarizer = LocalMeetingSummarizer(claude: claude, modelSetting: { .automatic }, allowOnDevice: false)
        let longResult = await summarizer.summarize(MeetingSummaryInput(personalNotes: "", transcript: hugeTranscript))
        XCTAssertEqual(callCount.get(), 3, "2 chunk extraction calls + 1 synthesis call")
        XCTAssertEqual(longResult.method, "Claude Sonnet 5.5")
        XCTAssertTrue(longResult.text.contains("Synthesized full 3-hour roadmap review"))

        // When user picks Built-in model, Claude must not be called at all.
        callCount.set(0)
        let onDeviceOnly = LocalMeetingSummarizer(claude: claude, modelSetting: { .onDevice }, allowOnDevice: false)
        let fallbackResult = await onDeviceOnly.summarize(
            MeetingSummaryInput(personalNotes: "", transcript: "We decided to ship on Friday.")
        )
        XCTAssertEqual(callCount.get(), 0)
        XCTAssertTrue(fallbackResult.method.contains("Extractive"))

        // When Claude returns an error (e.g. 503), it falls back cleanly without crashing.
        let failingClaude = ClaudeMeetingSummarizer(
            keyProvider: { "sk-ant-test-key" },
            transport: { request in
                let data = try JSONSerialization.data(withJSONObject: ["error": ["type": "overloaded_error"]])
                let http = HTTPURLResponse(url: request.url!, statusCode: 529, httpVersion: nil, headerFields: nil)!
                return (data, http)
            }
        )
        let graceful = LocalMeetingSummarizer(claude: failingClaude, modelSetting: { .automatic }, allowOnDevice: false)
        let gracefulResult = await graceful.summarize(
            MeetingSummaryInput(personalNotes: "", transcript: "We agreed to ship the migration on Monday.")
        )
        XCTAssertTrue(gracefulResult.text.contains("migration"))
        XCTAssertTrue(gracefulResult.method.contains("Extractive"))
    }

    // MARK: - Live Meeting Detection & Zero-Setup Auto-Activation

    func testLiveMeetingMatcherDetectsNativeAppsBrowsersAndIgnoresNoise() {
        let ownPID: pid_t = 4242

        // Noise: FlowClone itself + MediaRemoteUIService + YouTube playback (output only) -> nil.
        let idleNoise = [
            AudioProcessInfo(pid: ownPID, bundleID: "com.andre.flowclone", isRunningInput: true, isRunningOutput: false),
            AudioProcessInfo(pid: 100, bundleID: "com.apple.MediaRemoteUIService", isRunningInput: true, isRunningOutput: false),
            AudioProcessInfo(pid: 200, bundleID: "com.google.Chrome.helper", isRunningInput: false, isRunningOutput: true),
            AudioProcessInfo(pid: 201, bundleID: "com.apple.avconferenced", isRunningInput: false, isRunningOutput: false),
        ]
        XCTAssertNil(LiveMeetingMatcher.detect(processes: idleNoise, ownPID: ownPID))

        // Native app via helper process: Zoom caphost input active.
        let zoomCall = LiveMeetingMatcher.detect(
            processes: idleNoise + [
                AudioProcessInfo(pid: 300, bundleID: "us.zoom.caphost", isRunningInput: true, isRunningOutput: false)
            ],
            ownPID: ownPID
        )
        XCTAssertEqual(zoomCall?.key, "us.zoom.xos")
        XCTAssertEqual(zoomCall?.suggestedTitle, "Zoom Call")
        XCTAssertEqual(zoomCall?.isBrowser, false)

        // Discord Canary helper renderer process.
        let discordCall = LiveMeetingMatcher.detect(
            processes: [
                AudioProcessInfo(pid: 301, bundleID: "com.hnc.DiscordCanary.helper.Renderer", isRunningInput: true, isRunningOutput: true)
            ],
            ownPID: ownPID
        )
        XCTAssertEqual(discordCall?.key, "com.hnc.discordcanary")
        XCTAssertEqual(discordCall?.suggestedTitle, "Discord Call")

        // Browser with Google Meet window title (even if remote speakers are currently muted).
        let chromeMeet = LiveMeetingMatcher.detect(
            processes: [
                AudioProcessInfo(pid: 400, bundleID: "com.google.Chrome.helper", isRunningInput: true, isRunningOutput: false)
            ],
            ownPID: ownPID,
            browserWindowTitles: ["com.google.chrome": ["Meet - abc-defg-hij - Google Chrome"]]
        )
        XCTAssertEqual(chromeMeet?.key, "com.google.chrome")
        XCTAssertEqual(chromeMeet?.suggestedTitle, "Google Meet")
        XCTAssertEqual(chromeMeet?.isBrowser, true)

        // Browser switched to a non-Meet tab while still on a two-way call (input on one helper, output on another).
        let switchedTab = LiveMeetingMatcher.detect(
            processes: [
                AudioProcessInfo(pid: 401, bundleID: "com.google.Chrome.helper", isRunningInput: true, isRunningOutput: false),
                AudioProcessInfo(pid: 402, bundleID: "com.google.Chrome.helper.Renderer", isRunningInput: false, isRunningOutput: true),
            ],
            ownPID: ownPID,
            browserWindowTitles: ["com.google.chrome": ["Pull Request #42 - GitHub"]]
        )
        XCTAssertEqual(switchedTab?.key, "com.google.chrome")
        XCTAssertEqual(switchedTab?.suggestedTitle, "Chrome Call")

        // Browser with active mic only + active calendar event -> detected.
        let calendarBackedBrowser = LiveMeetingMatcher.detect(
            processes: [
                AudioProcessInfo(pid: 403, bundleID: "com.apple.WebKit.GPU", isRunningInput: true, isRunningOutput: false)
            ],
            ownPID: ownPID,
            browserWindowTitles: [:],
            hasActiveCalendarEvent: true
        )
        XCTAssertEqual(calendarBackedBrowser?.key, "com.apple.safari")
        XCTAssertEqual(calendarBackedBrowser?.suggestedTitle, "Safari Call")

        // Browser mic only (e.g. web voice search) without meeting title, output, or calendar event -> ignored.
        let webVoiceSearch = LiveMeetingMatcher.detect(
            processes: [
                AudioProcessInfo(pid: 404, bundleID: "com.google.Chrome.helper", isRunningInput: true, isRunningOutput: false)
            ],
            ownPID: ownPID,
            browserWindowTitles: ["com.google.chrome": ["Google Search"]],
            hasActiveCalendarEvent: false
        )
        XCTAssertNil(webVoiceSearch)
    }

    func testLiveCallAutoActivatesWithZeroSetupAutoStopsAndDerivesTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("live-call-zero-setup"))!
        let calendar = UpgradeTestCalendar()
        calendar.nextError = GoogleCalendarSignInRequired.missing
        let capture = UpgradeTestCapture()
        let asr = UpgradeTestTranscriber()
        let summarizer = CountingSummarizer()
        let detector = FakeCallDetector()

        // Completely fresh defaults: no calendar connected, consentConfirmed == false, autoStart == false.
        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: capture,
            transcriber: asr,
            summarizer: summarizer,
            store: MeetingStore(root: root),
            defaults: defaults,
            callDetector: detector,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.isUIActiveProvider = { false }
        coordinator.setLaunchedForTesting(true)
        coordinator.load(now: now)

        XCTAssertTrue(coordinator.autoDetectCalls, "Live call auto-detection must be on by default with zero setup")
        XCTAssertFalse(coordinator.consentConfirmed)
        XCTAssertFalse(coordinator.autoStart)
        XCTAssertNil(coordinator.desiredTimerInterval(now: now), "Idle detector must not spin a background timer")

        // User joins a Zoom call.
        detector.activeCall = DetectedMeetingCall(key: "us.zoom.xos", appName: "Zoom", suggestedTitle: "Zoom Call", isBrowser: false)
        await coordinator.handleLiveCallChange(now: now)
        XCTAssertEqual(capture.starts, 0, "Should wait 3s confirmation debounce before recording")
        XCTAssertEqual(coordinator.desiredTimerInterval(now: now), 2, "Pending live call speeds timer up to confirm")

        // 2s later: still debouncing.
        await coordinator.tick(now: now.addingTimeInterval(2))
        XCTAssertEqual(capture.starts, 0)

        // 3s later: confirmed -> automatically starts recording with zero setup!
        await coordinator.tick(now: now.addingTimeInterval(3))
        XCTAssertEqual(capture.starts, 1)
        let activeID = try XCTUnwrap(coordinator.activeID)
        XCTAssertEqual(coordinator.activeNote?.event.title, "Zoom Call")

        capture.segments = [.init(audioFile: "system-0.wav", source: .system, offset: 0, duration: 15)]

        // User leaves the Zoom call; waits 15s grace period before stopping & summarizing.
        detector.activeCall = nil
        await coordinator.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(capture.stops, 0)
        await coordinator.tick(now: now.addingTimeInterval(44))
        XCTAssertEqual(capture.stops, 0)
        await coordinator.tick(now: now.addingTimeInterval(45))
        XCTAssertEqual(capture.stops, 1)
        XCTAssertNil(coordinator.activeID)

        await coordinator.settle()
        let saved = try XCTUnwrap(coordinator.notes.first(where: { $0.id == activeID }))
        XCTAssertEqual(saved.phase, .complete)
        XCTAssertEqual(saved.summaryMethod, "Claude Sonnet 5.5")
        XCTAssertNotEqual(saved.event.title, "Zoom Call", "Generic live-call title should upgrade to derived meeting topic")

        // Re-summarize button regenerates summary on demand without re-recording.
        await summarizer.setReply(MeetingSummary(text: "## Overview\nUpdated deep summary.", method: "Claude Sonnet 5.5"))
        await coordinator.resummarize(activeID)
        XCTAssertEqual(coordinator.notes.first(where: { $0.id == activeID })?.summary, "## Overview\nUpdated deep summary.")
    }

    func testLiveCallLinksToScheduledGoogleCalendarEventWithoutDuplicateAndRespectsManualStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("live-call-calendar-link"))!
        let calendar = UpgradeTestCalendar()
        let scheduled = MeetingEvent(
            id: "google/primary/design-sync",
            calendarID: "primary",
            title: "Design Review",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(1800),
            attendees: ["Maya", "Andre"],
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        calendar.entries = [scheduled]
        let capture = UpgradeTestCapture()
        let detector = FakeCallDetector()

        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: capture,
            transcriber: UpgradeTestTranscriber(),
            summarizer: CountingSummarizer(),
            store: MeetingStore(root: root),
            defaults: defaults,
            callDetector: detector,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: now)
        coordinator.selectedCalendars = ["primary"]
        try await coordinator.sync(now: now)

        // User joins Google Meet in Chrome -> links to "Design Review" calendar event (no duplicate!).
        detector.activeCall = DetectedMeetingCall(key: "com.google.chrome", appName: "Chrome", suggestedTitle: "Google Meet", isBrowser: true)
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(4))
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(coordinator.activeNote?.event.id, scheduled.id)
        XCTAssertEqual(coordinator.activeNote?.event.title, "Design Review")
        XCTAssertEqual(coordinator.notes.count, 1)

        // User manually clicks Stop while still in Chrome Meet -> must NOT immediately re-start!
        await coordinator.stop(at: now.addingTimeInterval(20))
        XCTAssertNil(coordinator.activeID)
        await coordinator.tick(now: now.addingTimeInterval(25))
        await coordinator.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(capture.starts, 1, "Manual stop must suppress re-triggering for the same call")

        // Once the user leaves the call and later joins a new call, auto-detection resumes!
        detector.activeCall = nil
        await coordinator.tick(now: now.addingTimeInterval(35))
        detector.activeCall = DetectedMeetingCall(key: "com.google.chrome", appName: "Chrome", suggestedTitle: "Google Meet", isBrowser: true)
        await coordinator.tick(now: now.addingTimeInterval(40))
        await coordinator.tick(now: now.addingTimeInterval(44))
        XCTAssertEqual(capture.starts, 2)
    }

    // MARK: - Google Calendar Never-Disconnect Resilience

    func testGoogleAuthorizerRecoversAfterTemporaryKeychainUnavailabilityWithoutSigningOut() async throws {
        let session = GoogleSession(refreshToken: "refresh-persistent", email: "andre@example.com")
        let store = FlakyKeychainStore(initialState: .unavailable(errSecInteractionNotAllowed), saved: session)
        let http = StubGoogleHTTP { _ in
            (200, ["access_token": "fresh-access-token", "expires_in": 3600])
        }
        let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com")
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store)

        // First attempt while Keychain is locked throws transient failure and does NOT wipe store.
        do {
            _ = try await auth.token(now: now)
            XCTFail("Expected transient keychainUnavailable error")
        } catch let error as GoogleCalendarTransientFailure {
            if case .keychainUnavailable(let status) = error {
                XCTAssertEqual(status, errSecInteractionNotAllowed)
            }
        }
        XCTAssertEqual(store.savedSession(), session, "Transient Keychain lock must never clear the stored refresh token")

        // Keychain unlocks: authorizer did NOT latch nil, so next call succeeds automatically!
        store.setLoadState(.found(session))
        let token = try await auth.token(now: now.addingTimeInterval(5))
        XCTAssertEqual(token, "fresh-access-token")
        XCTAssertEqual(auth.email, "andre@example.com")
        XCTAssertTrue(auth.signedIn)
    }

    func testMeetingCoordinatorKeepsGoogleCalendarConnectedAcrossWakeAndTransientFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("google-cal-resilience"))!
        let calendar = UpgradeTestCalendar()
        calendar.entries = [
            MeetingEvent(
                id: "google/primary/standup",
                calendarID: "primary",
                title: "Daily Standup",
                start: now.addingTimeInterval(600),
                end: now.addingTimeInterval(2400)
            )
        ]

        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: UpgradeTestCapture(),
            transcriber: UpgradeTestTranscriber(),
            summarizer: CountingSummarizer(),
            store: MeetingStore(root: root),
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: now)
        coordinator.selectedCalendars = ["primary"]
        try await coordinator.sync(now: now)
        XCTAssertTrue(coordinator.connected)
        XCTAssertEqual(coordinator.account, "andre@example.com")
        XCTAssertEqual(coordinator.upcoming.count, 1)

        // 1. Keychain temporarily unavailable (even if calendar.account briefly reads nil) -> stays connected & keeps account!
        calendar.account = nil
        calendar.nextError = GoogleCalendarTransientFailure.keychainUnavailable(errSecInteractionNotAllowed)
        await coordinator.tick(now: now.addingTimeInterval(300))
        XCTAssertTrue(coordinator.connected)
        XCTAssertEqual(coordinator.account, "andre@example.com")
        XCTAssertEqual(coordinator.upcoming.count, 1)

        // 2. Transient OAuth token errors (temporarily_unavailable, http_429) -> stays connected!
        calendar.nextError = GoogleTokenFailure(code: "temporarily_unavailable", detail: "Retry later")
        await coordinator.tick(now: now.addingTimeInterval(330))
        XCTAssertTrue(coordinator.connected)
        XCTAssertEqual(coordinator.account, "andre@example.com")

        calendar.nextError = GoogleTokenFailure(code: "http_429", detail: "Rate limit")
        await coordinator.tick(now: now.addingTimeInterval(360))
        XCTAssertTrue(coordinator.connected)

        // 3. After an 8-hour sleep, wake grace window prevents Wi-Fi-reconnecting URLError from disconnecting Google Calendar!
        let afterSleep = now.addingTimeInterval(8 * 3600)
        coordinator.setWakeGraceForTesting(until: afterSleep.addingTimeInterval(60))
        calendar.nextError = URLError(.notConnectedToInternet)
        await coordinator.tick(now: afterSleep)
        XCTAssertTrue(coordinator.connected, "Post-wake network blip must not drop Google Calendar connection")
        XCTAssertEqual(coordinator.account, "andre@example.com")
        XCTAssertEqual(coordinator.upcoming.count, 1)

        // 4. Wi-Fi reconnects -> sync succeeds cleanly and clears error.
        calendar.account = "andre@example.com"
        calendar.nextError = nil
        await coordinator.tick(now: afterSleep.addingTimeInterval(20))
        XCTAssertTrue(coordinator.connected)
        XCTAssertNil(coordinator.error)
    }

    // MARK: - 6. Test-process Keychain isolation (no macOS password prompts during swift test)

    func testUnitTestsNeverTouchRealLoginKeychain() {
        XCTAssertTrue(runningUnitTests, "xctest must detect unit-test execution")
        XCTAssertTrue(suppressHostAccess, "Unit tests must suppress host Keychain and TCC prompts")

        // None of these may hit the owner's real login Keychain or summon an ACL password prompt.
        let googleStore = KeychainGoogleSessionStore()
        XCTAssertEqual(googleStore.loadState(), .missing)
        XCTAssertFalse(googleStore.save(GoogleSession(refreshToken: "rt", email: "test@example.com")))
        googleStore.clear()

        XCTAssertNil(ClaudeKey.current)
        XCTAssertFalse(ClaudeKey.store("sk-ant-api03-test-key-01234567890123456789"))
        XCTAssertNil(UpdateAccess.read())
    }

    func testIdleCalendarSyncUsesFiveMinuteCadenceWhileStartingCachedMeetingOnTime() async throws {
        final class CountingCalendar: MeetingCalendarProviding {
            var source: MeetingCalendarSource = .google
            var account: String? = "andre@example.com"
            var entries: [MeetingEvent] = []
            var calendarFetches = 0
            var eventFetches = 0
            func connect(_ source: MeetingCalendarSource) async throws { self.source = source }
            func calendars() async throws -> [MeetingCalendar] {
                calendarFetches += 1
                return [.init(id: "primary", title: "Primary", account: "andre@example.com", primary: true)]
            }
            func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
                eventFetches += 1
                return entries.filter { calendarIDs.contains($0.calendarID) && $0.end > from && $0.start < to }
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("idle-5min-sync"))!
        let calendar = CountingCalendar()
        calendar.entries = [
            MeetingEvent(
                id: "google/primary/later",
                calendarID: "primary",
                title: "Weekly Review",
                start: now.addingTimeInterval(600),
                end: now.addingTimeInterval(2400),
                attendees: ["Maya", "Andre"]
            )
        ]
        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: UpgradeTestCapture(),
            transcriber: UpgradeTestTranscriber(),
            summarizer: CountingSummarizer(),
            store: MeetingStore(root: root),
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: now)
        coordinator.selectedCalendars = ["primary"]
        coordinator.autoStart = true
        coordinator.consentConfirmed = true

        // Initial tick syncs once.
        await coordinator.tick(now: now)
        XCTAssertEqual(calendar.eventFetches, 1)
        XCTAssertEqual(coordinator.desiredSyncInterval(now: now), 300)

        // Repeated 15s ticks during idle period must NOT trigger network syncs before 5 minutes.
        for delta in [15.0, 30.0, 60.0, 120.0, 240.0, 299.0] {
            await coordinator.tick(now: now.addingTimeInterval(delta))
        }
        XCTAssertEqual(calendar.eventFetches, 1, "Idle ticks under 5 minutes must not poll network")

        // At 5 minutes (300s), idle sync runs once.
        await coordinator.tick(now: now.addingTimeInterval(300))
        XCTAssertEqual(calendar.eventFetches, 2)

        // When meeting becomes imminent (within 120s of start at +600), cadence tightens to 15s.
        XCTAssertEqual(coordinator.desiredSyncInterval(now: now.addingTimeInterval(500)), 15)
        await coordinator.tick(now: now.addingTimeInterval(500))
        XCTAssertEqual(calendar.eventFetches, 3)

        // Scheduled start triggers countdown cleanly from upcoming events.
        await coordinator.tick(now: now.addingTimeInterval(600))
        XCTAssertEqual(coordinator.countdown?.id, "google/primary/later")
    }

    func testImportAudioFileReusesDecodedSamplesAndSurfacesTranscriptionErrorWithoutThirdDecode() async throws {
        actor FailingSampleTranscriber: MeetingTranscribing {
            var transcribeURLCalls = 0
            var transcribeSampleCalls = 0
            func transcribe(url: URL) async throws -> String {
                transcribeURLCalls += 1
                return "should not run"
            }
            func transcribeSamples(
                _ samples: [Float],
                sourceURL: URL,
                progress: (@Sendable (Double) -> Void)?
            ) async throws -> [MeetingImportedChunk] {
                transcribeSampleCalls += 1
                XCTAssertGreaterThan(samples.count, 16_000)
                throw SpeechRuntimeError.modelUnavailable
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-err-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wavURL = root.appendingPathComponent("Interview.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buf.frameLength = 32_000
        for i in 0..<32_000 { buf.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.2 }
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: format.settings)
            try file.write(from: buf)
        }

        let transcriber = FailingSampleTranscriber()
        let coordinator = MeetingCoordinator(
            calendar: UpgradeTestCalendar(),
            capture: UpgradeTestCapture(),
            transcriber: transcriber,
            summarizer: CountingSummarizer(),
            store: MeetingStore(root: root.appendingPathComponent("Store")),
            defaults: UserDefaults(suiteName: ScratchDefaults.name("import-err"))!,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: now)

        let importedID = await coordinator.importAudioFile(at: wavURL, now: now)
        XCTAssertNil(importedID, "Failed transcription must fail cleanly instead of swallowing error")
        XCTAssertNotNil(coordinator.error)
        XCTAssertTrue(coordinator.error?.contains("speech model") ?? false)
        let sampleCalls = await transcriber.transcribeSampleCalls
        let urlCalls = await transcriber.transcribeURLCalls
        XCTAssertEqual(sampleCalls, 1)
        XCTAssertEqual(urlCalls, 0, "Must not fall back into drain() for a third disk decode")
        XCTAssertTrue(coordinator.notes.isEmpty)
    }
}
