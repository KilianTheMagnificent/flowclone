import AVFoundation
import Cocoa
import Foundation
import XCTest
@testable import FlowCloneCore

private actor MockAXCounter {
    private(set) var reads = 0
    private var bounds: CGRect?

    init(bounds: CGRect? = nil) {
        self.bounds = bounds
    }

    func setBounds(_ newBounds: CGRect?) {
        bounds = newBounds
    }

    func read() -> CGRect? {
        reads += 1
        return bounds
    }
}

@MainActor
private final class MockSystemAudioBackend: SystemAudioSource {
    let backendName: String
    private let shouldFailStart: Bool
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(name: String, shouldFailStart: Bool = false) {
        self.backendName = name
        self.shouldFailStart = shouldFailStart
    }

    func start() async throws {
        startCalls += 1
        if shouldFailStart {
            throw MeetingFailure("\(backendName) unavailable")
        }
    }

    func stop() async throws {
        stopCalls += 1
    }
}

@MainActor
private final class TrackCCalendarStub: MeetingCalendarProviding {
    var source: MeetingCalendarSource = .google
    var account: String?
    var entries: [MeetingEvent] = []

    func connect(_ source: MeetingCalendarSource) async throws {
        self.source = source
        self.account = source == .mac ? "macOS Calendar" : "alex@example.com"
    }

    func disconnect() async {
        account = nil
    }

    func calendars() async throws -> [MeetingCalendar] {
        switch source {
        case .google:
            return [.init(id: "google-primary", title: "Work", account: "Google", primary: true)]
        case .mac:
            return [.init(id: "mac-primary", title: "iCloud", account: "iCloud", primary: true)]
        }
    }

    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        entries.filter { calendarIDs.contains($0.calendarID) && $0.end > from && $0.start < to }
    }
}

@MainActor
private final class TrackCCaptureStub: MeetingCapturing {
    var starts = 0
    var stops = 0
    var systemAudioAllowed = true
    var microphoneShouldChange = false
    var output: (@Sendable (MeetingSegment) -> Void)?
    var segments: [MeetingSegment] = []

    func requestSystemAudio() {}

    func start(
        directory: URL,
        startedAt: Date,
        initialOffsets: [MeetingSource: TimeInterval] = [:],
        segment: @escaping @Sendable (MeetingSegment) -> Void,
        failed: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        starts += 1
        output = segment
    }

    func stop() async throws -> [MeetingSegment] {
        stops += 1
        return segments
    }
}

private actor TrackCTranscriberStub: MeetingTranscribing {
    var fixedTranscript = "We decided to ship the Core Audio process tap on Tuesday. Priya will update the release notes."

    func setTranscript(_ value: String) {
        fixedTranscript = value
    }

    func transcribe(url: URL) async throws -> String {
        fixedTranscript
    }
}

private struct TrackCSummarizerStub: MeetingSummarizing {
    func summarize(_ note: MeetingNote) async -> MeetingSummary {
        MeetingSummary(text: LocalMeetingSummarizer.extractive(note), method: "Extractive test")
    }
}

@MainActor
final class TrackCMeetingsAndUXTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_100_000)

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
    }

    private func sineWave(frequency: Double = 220, amplitude: Float, durationSeconds: Double, sampleRate: Int = 16_000) -> [Float] {
        let count = Int((durationSeconds * Double(sampleRate)).rounded())
        return (0..<count).map { index in
            let phase = 2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)
            return Float(sin(phase)) * amplitude
        }
    }

    private func makePCMBuffer(samples: [Float], sampleRate: Double = 16_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        return buffer
    }

    // MARK: - 1. DockTracker Zero-Idle Polling & Overlay Window Query Throttle

    @MainActor
    func testDockTrackerStaticDockUsesZeroTimersZeroMonitorsAndZeroAXQueries() async {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let permanentBottomVisible = NSRect(x: 0, y: 74, width: 2560, height: 1341)
        let permanentLeftVisible = NSRect(x: 68, y: 0, width: 2492, height: 1415)

        XCTAssertFalse(DockTracker.isAutoHideEnabled(screenFrame: screen, visibleFrame: permanentBottomVisible))
        XCTAssertFalse(DockTracker.isAutoHideEnabled(screenFrame: screen, visibleFrame: permanentLeftVisible))

        let axCounter = MockAXCounter(bounds: CGRect(x: 800, y: 1370, width: 960, height: 60))
        let tracker = DockTracker(observeScreenChanges: false)
        defer { tracker.setEnabled(false) }

        tracker.screenProvider = { [(screen, permanentBottomVisible)] }
        tracker.pointerProvider = { NSPoint(x: 1280, y: 8) } // Even with pointer at very bottom!
        tracker.dockPIDProvider = { 4242 }
        tracker.geometryProvider = { _ in await axCounter.read() }

        tracker.setEnabled(true)
        tracker.handlePointerMoved()
        await tracker.sampleOnceForTesting()

        XCTAssertFalse(tracker.isAutoHideActive)
        XCTAssertFalse(tracker.hasActiveTimer, "Static non-auto-hidden Dock must never arm the 20 Hz timer")
        XCTAssertFalse(tracker.hasMouseMonitors, "Static non-auto-hidden Dock must never install global mouse monitors")
        XCTAssertNil(tracker.frame)
        let axReads = await axCounter.reads
        XCTAssertEqual(axReads, 0, "Static non-auto-hidden Dock must make zero AX IPC calls")
    }

    @MainActor
    func testDockTrackerAutoHideSamplesOnlyOnBottomTransitionAndStopsAfterStabilization() async {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        // Menu bar insets top by 25pt; minY/minX/maxX match full screen -> auto-hide is ON.
        let autoHideVisible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        XCTAssertTrue(DockTracker.isAutoHideEnabled(screenFrame: screen, visibleFrame: autoHideVisible))

        var fakeNow: TimeInterval = 100.0
        var fakePointer = NSPoint(x: 1280, y: 700) // Middle of screen (away from bottom edge)
        let revealedQuartzBounds = CGRect(x: 780, y: 1375, width: 1000, height: 55)
        let axCounter = MockAXCounter(bounds: revealedQuartzBounds)

        let tracker = DockTracker(observeScreenChanges: false)
        defer { tracker.setEnabled(false) }

        tracker.screenProvider = { [(screen, autoHideVisible)] }
        tracker.pointerProvider = { fakePointer }
        tracker.uptimeProvider = { fakeNow }
        tracker.dockPIDProvider = { 4242 }
        tracker.geometryProvider = { _ in await axCounter.read() }

        tracker.setEnabled(true)
        XCTAssertTrue(tracker.hasMouseMonitors)
        XCTAssertFalse(tracker.hasActiveTimer, "Auto-hide Dock must not poll while pointer is away and Dock is hidden")
        let initialReads = await axCounter.reads
        XCTAssertEqual(initialReads, 0)

        // Move pointer into bottom trigger zone -> transition sampling starts.
        fakePointer = NSPoint(x: 1280, y: 12)
        tracker.handlePointerMoved()
        XCTAssertTrue(tracker.hasActiveTimer)

        // Let the initial async sample land and advance time through stabilization (~300 ms).
        try? await Task.sleep(for: .milliseconds(25))
        fakeNow = 100.12
        await tracker.sampleOnceForTesting()
        XCTAssertNotNil(tracker.frame)
        XCTAssertTrue(tracker.hasActiveTimer, "Timer stays active before 300 ms stabilization window completes")

        fakeNow = 100.46
        await tracker.sampleOnceForTesting()
        XCTAssertFalse(tracker.hasActiveTimer, "Timer must stop automatically once Dock height stabilizes for >=300 ms")
        XCTAssertEqual(tracker.frame?.maxY, 65)
    }

    @MainActor
    func testOverlayFrontWindowScreenThrottlesWindowServerQueries() {
        let overlay = Overlay.shared
        let savedProvider = overlay.windowBoundsProvider
        defer {
            overlay.windowBoundsProvider = savedProvider
            overlay.resetFrontWindowThrottleForTesting()
        }

        overlay.resetFrontWindowThrottleForTesting()
        var providerCalls = 0
        overlay.windowBoundsProvider = { _ in
            providerCalls += 1
            return CGRect(x: 100, y: 100, width: 900, height: 600)
        }

        _ = overlay.frontWindowScreen(frontmostPID: 777, now: 10.00)
        _ = overlay.frontWindowScreen(frontmostPID: 777, now: 10.05)
        _ = overlay.frontWindowScreen(frontmostPID: 777, now: 10.15)
        _ = overlay.frontWindowScreen(frontmostPID: 777, now: 10.24)
        XCTAssertEqual(providerCalls, 1, "Rapid partial updates within 250 ms must reuse the cached front window screen")
        XCTAssertEqual(overlay.frontWindowQueryCount, 1)

        // After 250 ms, query refreshes.
        _ = overlay.frontWindowScreen(frontmostPID: 777, now: 10.26)
        XCTAssertEqual(providerCalls, 2)

        // Switching frontmost PID invalidates immediately.
        _ = overlay.frontWindowScreen(frontmostPID: 888, now: 10.30)
        XCTAssertEqual(providerCalls, 3)
    }

    // MARK: - 2. Interactive Non-Activating Pill HUD, Mode Badges, VoiceOver & Recovery Banner

    @MainActor
    func testInteractivePillRemainsNonActivatingAndRoutesClicksBadgesAndAccessibility() {
        let overlay = Overlay.shared
        let savedHandsFree = overlay.onStartHandsFree
        let savedFinish = overlay.onFinishCapture
        let savedCancel = overlay.onCancelCapture
        let savedMeeting = overlay.onStartNewMeeting
        let savedOpen = overlay.onOpenMainWindow
        let savedMode = UserDefaults.standard.object(forKey: "mode")
        let savedIdle = UserDefaults.standard.object(forKey: "idlePill")
        overlay.suppressPresentationForTesting = true
        defer {
            overlay.onStartHandsFree = savedHandsFree
            overlay.onFinishCapture = savedFinish
            overlay.onCancelCapture = savedCancel
            overlay.onStartNewMeeting = savedMeeting
            overlay.onOpenMainWindow = savedOpen
            overlay.setModeBadge(nil)
            overlay.dismissRecoveryNotice()
            overlay.configurePhaseForTesting(listening: false)
            overlay.suppressPresentationForTesting = false
            if let savedMode { UserDefaults.standard.set(savedMode, forKey: "mode") }
            else { UserDefaults.standard.removeObject(forKey: "mode") }
            if let savedIdle { UserDefaults.standard.set(savedIdle, forKey: "idlePill") }
            else { UserDefaults.standard.removeObject(forKey: "idlePill") }
        }

        XCTAssertTrue(overlay.panelIsNonActivating, "Pill NSPanel must remain .nonactivatingPanel and never become key/main")

        var handsFreeStarts = 0
        var finishes = 0
        var cancels = 0
        overlay.onStartHandsFree = { handsFreeStarts += 1 }
        overlay.onFinishCapture = { finishes += 1 }
        overlay.onCancelCapture = { cancels += 1 }

        Overlay.idlePillEnabled = true
        overlay.configurePhaseForTesting(listening: false)
        XCTAssertTrue(overlay.simulatePrimaryClickForTesting())
        XCTAssertEqual(handsFreeStarts, 1, "Left-clicking idle pill starts hands-free dictation")

        overlay.configurePhaseForTesting(listening: true)
        XCTAssertTrue(overlay.simulatePrimaryClickForTesting())
        XCTAssertEqual(finishes, 1, "Left-clicking active listening pill finishes and inserts")
        XCTAssertTrue(overlay.simulatePrimaryClickForTesting(onCancel: true))
        XCTAssertEqual(cancels, 1, "Clicking the hover × button cancels active capture")

        // Context menu while active contains modes, New Meeting, Open FlowClone, Cancel, and Hide Idle Pill.
        let activeMenu = overlay.buildContextMenu()
        let activeTitles = activeMenu.items.map(\.title)
        XCTAssertTrue(activeTitles.contains("Clean"))
        XCTAssertTrue(activeTitles.contains("Prompt"))
        XCTAssertTrue(activeTitles.contains("Literal"))
        XCTAssertTrue(activeTitles.contains("Start New Meeting Note"))
        XCTAssertTrue(activeTitles.contains("Open FlowClone"))
        XCTAssertTrue(activeTitles.contains("Cancel"))
        XCTAssertTrue(activeTitles.contains("Hide Idle Pill"))

        // Mode badge resolution (setting Mode.current directly avoids FoundationModels XPC prewarm in xctest).
        Mode.current = .clean
        overlay.setModeBadge(nil)
        XCTAssertNil(overlay.resolvedModeBadge())
        Mode.current = .prompt
        XCTAssertEqual(overlay.resolvedModeBadge(), .prompt)
        Mode.current = .raw
        XCTAssertEqual(overlay.resolvedModeBadge(), .literal)
        overlay.setModeBadge(.spelling)
        XCTAssertEqual(overlay.resolvedModeBadge(), .spelling)
        overlay.setModeBadge(.draft)
        XCTAssertEqual(overlay.resolvedModeBadge(), .draft)

        // VoiceOver accessibility on PillView & TranscriptView.
        let pillView = PillView(frame: NSRect(x: 0, y: 0, width: 73, height: 30))
        pillView.reset()
        pillView.modeBadge = .prompt
        var pressed = false
        pillView.onAccessibilityPress = { pressed = true; return true }
        XCTAssertTrue(pillView.isAccessibilityElement())
        XCTAssertEqual(pillView.accessibilityRole(), .button)
        XCTAssertEqual(pillView.accessibilityLabel(), "FlowClone dictation pill")
        XCTAssertEqual(pillView.accessibilityValue() as? String, "Listening, Prompt mode")
        XCTAssertTrue(pillView.accessibilityPerformPress())
        XCTAssertTrue(pressed)

        let transcriptView = TranscriptView(frame: .zero)
        transcriptView.text = "Hello world"
        XCTAssertTrue(transcriptView.isAccessibilityElement())
        XCTAssertEqual(transcriptView.accessibilityValue() as? String, "Hello world")
    }

    @MainActor
    func testOverlayRecoveryBannerAndNotifyUserInlinePasteRecovery() async {
        let overlay = Overlay.shared
        overlay.suppressPresentationForTesting = true
        var copiedTexts: [String] = []
        overlay.copyWriterForTesting = { copiedTexts.append($0) }
        defer {
            UserNoticeRouter.testSink = nil
            overlay.dismissRecoveryNotice()
            overlay.copyWriterForTesting = nil
            overlay.suppressPresentationForTesting = false
        }

        overlay.showRecoveryNotice("Couldn't paste — click to copy", copyText: "Recovered transcript text", duration: 10)
        XCTAssertEqual(overlay.activeRecoveryMessage, "Couldn't paste — click to copy")
        XCTAssertEqual(overlay.activeRecoveryCopyText, "Recovered transcript text")

        // Activating the recovery banner copies the text and flips to the confirmation message.
        let copied = overlay.triggerRecoveryCopyForTesting()
        XCTAssertTrue(copied)
        XCTAssertEqual(copiedTexts, ["Recovered transcript text"])
        XCTAssertEqual(overlay.activeRecoveryMessage, "Copied to clipboard — ⌘V to paste")
        XCTAssertNil(overlay.activeRecoveryCopyText)
        overlay.dismissRecoveryNotice()
        XCTAssertNil(overlay.activeRecoveryMessage)

        // Verify notifyUser routes paste-recovery notices with History fallback text.
        XCTAssertTrue(shouldAttachLatestHistoryCopy(toNotice: "Paste could not be confirmed. Text remains in FlowClone History."))
        XCTAssertTrue(shouldAttachLatestHistoryCopy(toNotice: "Couldn't paste (secure field). Text is on your clipboard — press Cmd+V."))
        XCTAssertFalse(shouldAttachLatestHistoryCopy(toNotice: "Your microphone is muted."))

        UserNoticeRouter.lastRoutedNotice = nil
        notifyUser("Couldn't paste — target lost", copyText: "Inline copy payload")
        XCTAssertEqual(UserNoticeRouter.lastRoutedNotice?.body, "Couldn't paste — target lost")
        XCTAssertEqual(UserNoticeRouter.lastRoutedNotice?.copyText, "Inline copy payload")
        UserNoticeRouter.lastRoutedNotice = nil
    }

    // MARK: - 3. Meetings 2.0 (Ad-Hoc, Echo Suppression, Core Audio Tap Fallback, Summaries, Search & Import)

    @MainActor
    func testAdHocNewMeetingStartsWithoutCalendarAutoDerivesTitleAndPreservesUserRename() async throws {
        let calendar = TrackCCalendarStub()
        let capture = TrackCCaptureStub()
        let transcriber = TrackCTranscriberStub()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowClone-AdHoc-\(UUID().uuidString)")
        let suiteName = ScratchDefaults.name("adhoc-meetings")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: capture,
            transcriber: transcriber,
            summarizer: TrackCSummarizerStub(),
            store: MeetingStore(root: root),
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: fixedNow)

        // 1. Spontaneous ad-hoc meeting with zero calendar connection or consent toggle needed,
        //    scoped to that single manually initiated session without persisting global consent:
        let startedFirstID = await coordinator.startAdHocMeeting(now: fixedNow)
        let firstID = try XCTUnwrap(startedFirstID)
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(coordinator.activeID, firstID)
        XCTAssertTrue(coordinator.activeNote?.event.isAdHoc == true)
        XCTAssertEqual(coordinator.activeNote?.event.title, "New Meeting")
        XCTAssertFalse(coordinator.consentConfirmed, "Ad-hoc session must not mutate persistent consentConfirmed")
        XCTAssertFalse(defaults.bool(forKey: "meetingConsent"), "Ad-hoc session must not persist meetingConsent=true")

        let seg = MeetingSegment(audioFile: "system-0.wav", source: .system, offset: 0, duration: 16)
        capture.segments = [seg]
        capture.output?(seg)
        await coordinator.stop()
        await coordinator.settle()

        let autoTitled = try XCTUnwrap(coordinator.notes.first(where: { $0.id == firstID }))
        XCTAssertEqual(autoTitled.phase, .complete)
        XCTAssertNotEqual(autoTitled.event.title, "New Meeting", "Completed ad-hoc meeting should auto-derive a concise title")
        XCTAssertTrue(autoTitled.event.title.localizedCaseInsensitiveContains("Core Audio")
                      || autoTitled.event.title.localizedCaseInsensitiveContains("process tap"))

        // 2. User-renamed ad-hoc meeting must keep the user's chosen title after summarization:
        let startedSecondID = await coordinator.startAdHocMeeting(now: fixedNow.addingTimeInterval(300))
        let secondID = try XCTUnwrap(startedSecondID)
        coordinator.renameMeeting(secondID, title: "Design Sync with Maya")
        capture.segments = [seg]
        capture.output?(seg)
        await coordinator.stop()
        await coordinator.settle()

        let customTitled = try XCTUnwrap(coordinator.notes.first(where: { $0.id == secondID }))
        XCTAssertEqual(customTitled.event.title, "Design Sync with Maya")
        XCTAssertTrue(customTitled.userRenamedTitle)

        // 3. Scheduled calendar meeting remains blocked until consentConfirmed is explicitly turned on:
        let scheduled = MeetingEvent(
            id: "scheduled-after-adhoc",
            calendarID: "primary",
            title: "Scheduled Check-in",
            start: fixedNow.addingTimeInterval(600),
            end: fixedNow.addingTimeInterval(2400),
            attendees: ["Maya", "Alex"],
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        await coordinator.start(scheduled, now: fixedNow.addingTimeInterval(605))
        XCTAssertNil(coordinator.activeID, "Scheduled meetings must still require explicit consentConfirmed")

        // 4. Exported meeting Markdown files are written with 0600 permissions (even over an existing 0644 file):
        let exportURL = root.appendingPathComponent("Exported notes.md")
        try Data("old".utf8).write(to: exportURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exportURL.path)
        try MeetingsPage.writeExportedMarkdown(customTitled.markdown, to: exportURL)
        let perms = try FileManager.default.attributesOfItem(atPath: exportURL.path)[.posixPermissions] as? Int
        XCTAssertEqual((perms ?? 0) & 0o777, 0o600, "Exported meeting Markdown must have 0600 POSIX permissions")
    }

    func testSpeakerEchoSuppressorAttenuatesDelayedSpeakerBleedWhilePreservingNearFieldAndDoubleTalk() throws {
        // Test across 0 ms, 65 ms, and 145 ms Studio Display speaker-to-mic acoustic delays.
        for delayMs in [0.0, 65.0, 145.0] {
            var suppressor = SpeakerEchoSuppressor()
            let systemSpeech = sineWave(frequency: 240, amplitude: 0.25, durationSeconds: 0.5)
            let attenuatedBleed = sineWave(frequency: 240, amplitude: 0.045, durationSeconds: 0.5)

            suppressor.observeSystem(systemSpeech, offset: 1.0)
            let gatedBleed = suppressor.processMicrophone(attenuatedBleed, offset: 1.0 + delayMs / 1000.0)

            let inputRMS = rms(attenuatedBleed)
            // Skip the first 20 ms ramp so steady-state attenuation is measured accurately.
            let steadySlice = Array(gatedBleed.dropFirst(320))
            let outputRMS = rms(steadySlice)
            XCTAssertLessThan(outputRMS, inputRMS * 0.15, "Speaker bleed at \(delayMs)ms delay must be strongly attenuated")
            XCTAssertGreaterThan(suppressor.suppressedFrameCount, 20)
        }

        // Near-field user speech alone (no system audio) passes through untouched.
        do {
            var suppressor = SpeakerEchoSuppressor()
            let userVoice = sineWave(frequency: 180, amplitude: 0.18, durationSeconds: 0.4)
            let processed = suppressor.processMicrophone(userVoice, offset: 5.0)
            XCTAssertEqual(suppressor.suppressedFrameCount, 0)
            XCTAssertGreaterThan(rms(processed), rms(userVoice) * 0.98)
        }

        // Simultaneous double-talk (remote speaker active + strong near-field user voice) is preserved!
        do {
            var suppressor = SpeakerEchoSuppressor()
            let systemSpeech = sineWave(frequency: 240, amplitude: 0.20, durationSeconds: 0.4)
            let doubleTalkMic = sineWave(frequency: 175, amplitude: 0.22, durationSeconds: 0.4)
            suppressor.observeSystem(systemSpeech, offset: 10.0)
            let processed = suppressor.processMicrophone(doubleTalkMic, offset: 10.06)
            XCTAssertEqual(suppressor.suppressedFrameCount, 0, "Strong near-field double-talk must not be gated out")
            XCTAssertGreaterThan(rms(processed), rms(doubleTalkMic) * 0.95)
        }

        // End-to-end MeetingAudioWriter verification with delayed microphone echo fixture.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FlowClone-EchoWriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = MeetingAudioWriter(
            directory: tempDir,
            startedAt: fixedNow,
            segment: { _ in },
            failed: { msg, _ in XCTFail("Unexpected writer failure: \(msg)") }
        )
        let sysBuf = try makePCMBuffer(samples: sineWave(frequency: 260, amplitude: 0.28, durationSeconds: 0.6))
        let micBleedBuf = try makePCMBuffer(samples: sineWave(frequency: 260, amplitude: 0.04, durationSeconds: 0.6))
        writer.fixture(sysBuf, source: .system, at: fixedNow.addingTimeInterval(0.6))
        writer.fixture(micBleedBuf, source: .microphone, at: fixedNow.addingTimeInterval(0.68)) // 80ms speaker delay
        let segments = try writer.finish()

        XCTAssertGreaterThan(writer.debugSuppressedEchoFrames, 20)
        let micSeg = try XCTUnwrap(segments.first(where: { $0.source == .microphone }))
        let micFile = try AVAudioFile(forReading: tempDir.appendingPathComponent(micSeg.audioFile))
        let readBuf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: AVAudioFrameCount(micFile.length)))
        try micFile.read(into: readBuf)
        let channelPtr = try XCTUnwrap(readBuf.floatChannelData?[0])
        let writtenMicSamples = Array(UnsafeBufferPointer(start: channelPtr, count: Int(readBuf.frameLength)))
        XCTAssertLessThan(rms(Array(writtenMicSamples.dropFirst(320))), 0.008)
    }

    @MainActor
    func testSystemAudioSourcePrefersCoreAudioTapAndFallsBackToScreenCaptureKit() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FlowClone-TapFallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = MeetingAudioWriter(directory: tempDir, startedAt: fixedNow, segment: { _ in }, failed: { _, _ in })

        // Case A: Core Audio Process Tap succeeds -> ScreenCaptureKit fallback is never touched.
        do {
            let capture = MacMeetingCapture()
            let primary = MockSystemAudioBackend(name: "coreAudioProcessTap", shouldFailStart: false)
            let fallback = MockSystemAudioBackend(name: "screenCaptureKit", shouldFailStart: false)
            capture.primarySystemAudioFactory = { _, _ in primary }
            capture.fallbackSystemAudioFactory = { _, _ in fallback }

            let chosen = try await capture.startSystemAudioSource(writer: writer, failed: { _, _ in })
            XCTAssertEqual(chosen.backendName, "coreAudioProcessTap")
            XCTAssertEqual(capture.activeSystemAudioBackendName, "coreAudioProcessTap")
            XCTAssertEqual(primary.startCalls, 1)
            XCTAssertEqual(fallback.startCalls, 0)
        }

        // Case B: Core Audio Process Tap fails -> cleanly falls back to ScreenCaptureKit.
        do {
            let capture = MacMeetingCapture()
            let primary = MockSystemAudioBackend(name: "coreAudioProcessTap", shouldFailStart: true)
            let fallback = MockSystemAudioBackend(name: "screenCaptureKit", shouldFailStart: false)
            capture.primarySystemAudioFactory = { _, _ in primary }
            capture.fallbackSystemAudioFactory = { _, _ in fallback }

            let chosen = try await capture.startSystemAudioSource(writer: writer, failed: { _, _ in })
            XCTAssertEqual(chosen.backendName, "screenCaptureKit")
            XCTAssertEqual(capture.activeSystemAudioBackendName, "screenCaptureKit")
            XCTAssertEqual(primary.startCalls, 1)
            XCTAssertEqual(fallback.startCalls, 1)
        }
    }

    @MainActor
    func testPersonalNotesMergedSummaryCheckableActionItemsBackwardsCompatibleDecodeAndSearch() async throws {
        // 1. Backwards-compatible decode of pre-existing MeetingNote JSON lacking completedActionItems / userRenamedTitle.
        let baseNote = MeetingNote(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            event: MeetingEvent(
                id: "evt-1",
                calendarID: "cal-1",
                title: "Q4 Architecture Review",
                start: fixedNow,
                end: fixedNow.addingTimeInterval(3600),
                attendees: ["Dana", "Sam"]
            ),
            startedAt: fixedNow,
            endedAt: fixedNow.addingTimeInterval(1800),
            phase: .complete,
            segments: [
                MeetingSegment(
                    audioFile: "system-0.wav",
                    source: .system,
                    offset: 0,
                    duration: 18,
                    text: "We agreed to migrate the staging cluster next Wednesday. Sam will complete the security review by Monday."
                )
            ],
            personalNotes: "- Budget cap is $25k\n- Need security signoff from Sam"
        )
        let encodedData = try JSONEncoder().encode(baseNote)
        var rawDict = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        rawDict.removeValue(forKey: "completedActionItems")
        rawDict.removeValue(forKey: "userRenamedTitle")
        let strippedLegacyData = try JSONSerialization.data(withJSONObject: rawDict)

        var legacyNote = try JSONDecoder().decode(MeetingRecord.self, from: strippedLegacyData)
        XCTAssertTrue(legacyNote.completedActionItems.isEmpty)
        XCTAssertFalse(legacyNote.userRenamedTitle)

        // 2. Merged human + AI summary incorporates both personalNotes and transcript, plus action items.
        let summaryText = LocalMeetingSummarizer.extractive(MeetingSummaryInput(note: legacyNote))
        XCTAssertTrue(summaryText.contains("Budget cap is $25k"), "Summary must incorporate personal notes")
        XCTAssertTrue(summaryText.contains("migrate the staging cluster"), "Summary must incorporate transcript")
        legacyNote.summary = summaryText
        let actions = MeetingActionItems.extract(from: summaryText)
        XCTAssertFalse(actions.isEmpty, "Action items should be extracted from summary")

        // 3. Coordinator action-item checkbox persistence, markdown export, Apple Calendar connect, and search.
        let calendar = TrackCCalendarStub()
        let capture = TrackCCaptureStub()
        let transcriber = TrackCTranscriberStub()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowClone-Search-\(UUID().uuidString)")
        let suiteName = ScratchDefaults.name("search-meetings")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = MeetingStore(root: root)
        try store.save(legacyNote)

        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: capture,
            transcriber: transcriber,
            summarizer: TrackCSummarizerStub(),
            store: store,
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: fixedNow)

        // Apple Calendar 1-click connect selects primary macOS calendar automatically.
        await coordinator.connect(.mac)
        XCTAssertEqual(coordinator.calendarSource, .mac)
        XCTAssertEqual(coordinator.selectedCalendars, ["mac-primary"])

        let firstAction = try XCTUnwrap(actions.first)
        coordinator.toggleActionItem(legacyNote.id, item: firstAction)
        let updated = try XCTUnwrap(coordinator.notes.first(where: { $0.id == legacyNote.id }))
        XCTAssertTrue(updated.completedActionItems.contains(firstAction))
        XCTAssertTrue(updated.markdown.contains("- [x] \(firstAction)"))

        // Cross-meeting search matches title, attendee, summary, personalNotes, and transcript.
        XCTAssertEqual(coordinator.filteredNotes(matching: "Architecture").map(\.id), [legacyNote.id])
        XCTAssertEqual(coordinator.filteredNotes(matching: "Dana").map(\.id), [legacyNote.id])
        XCTAssertEqual(coordinator.filteredNotes(matching: "$25k").map(\.id), [legacyNote.id])
        XCTAssertEqual(coordinator.filteredNotes(matching: "staging cluster").map(\.id), [legacyNote.id])
        XCTAssertTrue(coordinator.filteredNotes(matching: "nonexistent-keyword-xyz").isEmpty)
    }

    @MainActor
    func testAudioFileImportSlicesTranscribesViaExternalHookAndSummarizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowClone-Import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = ScratchDefaults.name("import-meetings")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            LocalMeetingTranscriber.setExternalTranscriber(nil)
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Create a 3.5-second 16 kHz mono WAV file on disk.
        let wavURL = root.appendingPathComponent("Customer Interview.wav")
        let samples = sineWave(frequency: 300, amplitude: 0.15, durationSeconds: 3.5)
        let pcm = try makePCMBuffer(samples: samples)
        do {
            let wavFile = try AVAudioFile(forWriting: wavURL, settings: pcm.format.settings)
            try wavFile.write(from: pcm)
        }

        LocalMeetingTranscriber.setExternalTranscriber(
            MeetingExternalTranscriber(transcribeSamples: { chunk in
                XCTAssertGreaterThan(chunk.count, 16_000)
                return "Customer requested SSO support. Jordan will send the SAML metadata tomorrow."
            })
        )

        let coordinator = MeetingCoordinator(
            calendar: TrackCCalendarStub(),
            capture: TrackCCaptureStub(),
            transcriber: LocalMeetingTranscriber(),
            summarizer: TrackCSummarizerStub(),
            store: MeetingStore(root: root.appendingPathComponent("Store", isDirectory: true)),
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: fixedNow)

        let rawImportedID = await coordinator.importAudioFile(at: wavURL, now: fixedNow)
        let importedID = try XCTUnwrap(rawImportedID)
        let note = try XCTUnwrap(coordinator.notes.first(where: { $0.id == importedID }))
        XCTAssertEqual(note.phase, .complete)
        XCTAssertTrue(note.event.isImported)
        XCTAssertEqual(note.event.title, "Customer Interview")
        XCTAssertTrue(note.transcript.contains("Customer requested SSO support"))
        XCTAssertTrue(note.summary.contains("SSO support"))
        XCTAssertEqual(note.segments.count, 1)

        let segmentURL = coordinator.store.directory(note.id).appendingPathComponent(note.segments[0].audioFile)
        let attrs = try FileManager.default.attributesOfItem(atPath: segmentURL.path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(perms, 0o600, "Imported meeting audio chunks must be stored with owner-only 0600 permissions")
    }

    // MARK: - 4. Idle Timers, Settings Onboarding/Shortcuts, History Cache, ActionPalette & Launch

    @MainActor
    func testMeetingCoordinatorTimerSleepsWhenIdleAndSpeedsUpOnlyWhenActiveOrImminent() {
        let calendar = TrackCCalendarStub()
        let capture = TrackCCaptureStub()
        let transcriber = TrackCTranscriberStub()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FlowClone-Timer-\(UUID().uuidString)")
        let suiteName = ScratchDefaults.name("timer-meetings")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let coordinator = MeetingCoordinator(
            calendar: calendar,
            capture: capture,
            transcriber: transcriber,
            summarizer: TrackCSummarizerStub(),
            store: MeetingStore(root: root),
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.isUIActiveProvider = { false }
        coordinator.setLaunchedForTesting(true)

        // Disconnected, no selected calendars, UI hidden -> 0 Hz (nil timer).
        coordinator.selectedCalendars = []
        coordinator.connected = false
        coordinator.autoStart = false
        XCTAssertNil(coordinator.desiredTimerInterval(now: fixedNow))

        // Connected calendar, autoStart off, UI hidden -> still 0 Hz (nil timer)!
        coordinator.selectedCalendars = ["google-primary"]
        coordinator.connected = true
        XCTAssertNil(coordinator.desiredTimerInterval(now: fixedNow))

        // UI visible with calendar -> 15s background refresh.
        coordinator.isUIActiveProvider = { true }
        XCTAssertEqual(coordinator.desiredTimerInterval(now: fixedNow), 15)

        // AutoStart + consent with meeting 10 minutes away -> 15s even when UI hidden.
        coordinator.isUIActiveProvider = { false }
        coordinator.autoStart = true
        coordinator.consentConfirmed = true
        coordinator.upcoming = [
            MeetingEvent(
                id: "later",
                calendarID: "google-primary",
                title: "Standup",
                start: fixedNow.addingTimeInterval(600),
                end: fixedNow.addingTimeInterval(1800),
                attendees: ["Maya", "Alex"]
            )
        ]
        XCTAssertEqual(coordinator.desiredTimerInterval(now: fixedNow), 15)

        // Meeting imminent (within 90s) -> 2s precision countdown window.
        coordinator.upcoming = [
            MeetingEvent(
                id: "soon",
                calendarID: "google-primary",
                title: "Standup",
                start: fixedNow.addingTimeInterval(45),
                end: fixedNow.addingTimeInterval(1800),
                attendees: ["Maya", "Alex"]
            )
        ]
        XCTAssertEqual(coordinator.desiredTimerInterval(now: fixedNow), 2)

        // System sleep / session resign -> suspended -> 0 Hz (nil timer).
        coordinator.suspended = true
        XCTAssertNil(coordinator.desiredTimerInterval(now: fixedNow))
    }

    @MainActor
    func testSettingsPermissionPollingSequencingShortcutSlot2ReplacementAndFnWarning() throws {
        // 1. Settings 2s permission poll gating.
        XCTAssertFalse(SettingsPage.shouldPollPermissions(windowOnScreen: false, appActive: true, grantsMissing: true))
        XCTAssertFalse(SettingsPage.shouldPollPermissions(windowOnScreen: true, appActive: false, grantsMissing: false))
        XCTAssertTrue(SettingsPage.shouldPollPermissions(windowOnScreen: true, appActive: true, grantsMissing: false))
        XCTAssertTrue(SettingsPage.shouldPollPermissions(windowOnScreen: true, appActive: false, grantsMissing: true))

        // 2. Sequenced one-by-one onboarding steps.
        XCTAssertEqual(
            SettingsPage.nextPermissionStep(micGranted: false, axGranted: false, inputGranted: false, hotkeyVerified: false),
            .microphone
        )
        XCTAssertEqual(
            SettingsPage.nextPermissionStep(micGranted: true, axGranted: false, inputGranted: false, hotkeyVerified: false),
            .accessibility
        )
        XCTAssertEqual(
            SettingsPage.nextPermissionStep(micGranted: true, axGranted: true, inputGranted: false, hotkeyVerified: false),
            .inputMonitoring
        )
        XCTAssertEqual(
            SettingsPage.nextPermissionStep(micGranted: true, axGranted: true, inputGranted: true, hotkeyVerified: false),
            .verifyHotkey
        )
        XCTAssertEqual(
            SettingsPage.nextPermissionStep(micGranted: true, axGranted: true, inputGranted: true, hotkeyVerified: true),
            .complete
        )

        // 3. Push-to-Talk "Set…" replaces Slot 2 atomically when both slots are full.
        let suiteName = ScratchDefaults.name("shortcuts-slot2")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.bindings.filter { $0.action == .dictate }.count, 2)
        let originalSlot1 = store.bindings[0]
        let originalSlot2 = store.bindings[1]

        let newPTT = ShortcutBinding(
            action: .dictate,
            keyCode: 49, // Space
            modifiers: CGEventFlags.maskAlternate.rawValue,
            keyLabel: "Space"
        )
        try ShortcutSettings.saveBinding(newPTT, in: store)
        let updatedDictate = store.bindings.filter { $0.action == .dictate }
        XCTAssertEqual(updatedDictate.count, 2)
        XCTAssertEqual(updatedDictate[0], originalSlot1, "Slot 1 (fn) must remain intact")
        XCTAssertEqual(updatedDictate[1].id, originalSlot2.id, "Slot 2 must be replaced in place")
        XCTAssertEqual(updatedDictate[1].keyCode, 49)

        // 4. AppleFnUsageType conflict detection.
        let fnBindings = ShortcutBinding.defaults
        XCTAssertNil(SettingsPage.fnKeyConflictDescription(appleFnUsageType: nil, bindings: fnBindings))
        XCTAssertNil(SettingsPage.fnKeyConflictDescription(appleFnUsageType: 0, bindings: fnBindings))
        XCTAssertNotNil(SettingsPage.fnKeyConflictDescription(appleFnUsageType: 1, bindings: fnBindings))
        XCTAssertTrue(SettingsPage.fnKeyConflictDescription(appleFnUsageType: 2, bindings: fnBindings)?.contains("Emoji") == true)
        XCTAssertTrue(SettingsPage.fnKeyConflictDescription(appleFnUsageType: 3, bindings: fnBindings)?.contains("Dictation") == true)
        let nonFnBindings = [newPTT]
        XCTAssertNil(SettingsPage.fnKeyConflictDescription(appleFnUsageType: 2, bindings: nonFnBindings))
    }

    @MainActor
    func testDictationHistorySummarySinglePassCacheActionPaletteAndLSUIElementLaunchPolicy() throws {
        // 1. Single-pass History summary computation.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let dayMinus1 = calendar.date(byAdding: .day, value: -1, to: day0)!
        let dayMinus2 = calendar.date(byAdding: .day, value: -2, to: day0)!

        let items: [History.Item] = [
            .init(date: day0, raw: "one", final: "one two three", seconds: 10, words: 25, targetApp: "com.apple.Notes"),
            .init(date: dayMinus1, raw: "two", final: "four five", seconds: 20, words: 50, targetApp: "com.apple.Notes"),
            .init(date: dayMinus2, raw: "three", final: "six", seconds: 30, words: 75, targetApp: "com.tinyspeck.slackmacgap")
        ]
        let summary = DictationHistorySummaryCache.compute(items: items, seededSeconds: 40, today: day0, calendar: calendar)
        XCTAssertEqual(summary.speakingSeconds, 60)
        XCTAssertEqual(summary.wordsPerMinute, 150)
        XCTAssertEqual(summary.streakDays, 3)
        XCTAssertEqual(summary.topApps.map(\.id), ["com.apple.Notes", "com.tinyspeck.slackmacgap"])
        XCTAssertEqual(summary.topApps.map(\.count), [2, 1])

        // 2. ActionPalette ↑ / ↓ / Return / Escape keyboard navigation.
        var chosen: FlowAction?
        var dismissed = 0
        let palette = ActionPaletteModel(
            onChoose: { chosen = $0 },
            onDismiss: { dismissed += 1 }
        )
        let totalActions = palette.filteredActions.count
        XCTAssertGreaterThan(totalActions, 3)
        XCTAssertEqual(palette.selectedIndex, 0)
        XCTAssertTrue(palette.handleKeyCode(125)) // Down arrow
        XCTAssertEqual(palette.selectedIndex, 1)
        XCTAssertTrue(palette.handleKeyCode(126)) // Up arrow
        XCTAssertEqual(palette.selectedIndex, 0)
        XCTAssertTrue(palette.handleKeyCode(126)) // Wrap around to last item
        XCTAssertEqual(palette.selectedIndex, totalActions - 1)

        palette.query = "Spell"
        XCTAssertEqual(palette.selectedIndex, 0)
        XCTAssertEqual(palette.filteredActions, [.spelling])
        XCTAssertTrue(palette.handleKeyCode(36)) // Return triggers selected action
        XCTAssertEqual(chosen, .spelling)

        XCTAssertTrue(palette.handleKeyCode(53)) // First Escape clears search query
        XCTAssertEqual(palette.query, "")
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(palette.handleKeyCode(53)) // Second Escape dismisses palette
        XCTAssertEqual(dismissed, 1)

        // 3. LSUIElement=true in app/Info.plist + MainWindow activation policy transitions.
        XCTAssertEqual(MainWindow.desiredActivationPolicy(windowVisible: false, windowMiniaturized: false), .accessory)
        XCTAssertEqual(MainWindow.desiredActivationPolicy(windowVisible: true, windowMiniaturized: false), .regular)
        XCTAssertEqual(MainWindow.desiredActivationPolicy(windowVisible: false, windowMiniaturized: true), .regular)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("app/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true, "app/Info.plist must set LSUIElement=true to prevent background/login Dock icon flash")
    }
}
