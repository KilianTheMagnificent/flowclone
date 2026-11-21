import XCTest
import AVFoundation
import Cocoa
import CoreMedia
import Observation
import SwiftUI
@testable import FlowCloneCore

@MainActor private final class TestCalendar: MeetingCalendarProviding {
    var entries: [MeetingEvent] = []
    var denied = false
    var offline = false
    var signInRequired = false
    func connect(_ source: MeetingCalendarSource) async throws { if denied { throw MeetingFailure("Calendar denied") } }
    func calendars() async throws -> [MeetingCalendar] {
        if offline { throw URLError(.notConnectedToInternet) }
        if signInRequired { throw GoogleCalendarSignInRequired.missing }
        if denied { throw MeetingFailure("Calendar denied") }
        return [.init(id: "google", title: "Team", account: "Google", primary: true)]
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        if denied { throw MeetingFailure("Calendar denied") }
        if offline { throw URLError(.notConnectedToInternet) }
        return entries.filter { calendarIDs.contains($0.calendarID) && $0.end > from && $0.start < to }
    }
}
@MainActor private final class TestCapture: MeetingCapturing {
    var starts = 0, stops = 0
    var allowed = true, permissionRequests = 0
    var microphoneShouldChange = false
    var systemAudioAllowed: Bool { allowed }
    func requestSystemAudio() { permissionRequests += 1 }
    var failure: String?
    var output: (@Sendable (MeetingSegment) -> Void)?
    var interrupt: (@Sendable (String, Bool) -> Void)?
    var segments: [MeetingSegment] = []
    var lastInitialOffsets: [MeetingSource: TimeInterval] = [:]
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (String, Bool) -> Void) async throws {
        starts += 1
        lastInitialOffsets = initialOffsets
        if let failure { throw MeetingFailure(failure) }
        output = segment; interrupt = failed
    }
    func stop() async throws -> [MeetingSegment] { stops += 1; return segments }
}
private actor TestTranscriber: MeetingTranscribing {
    var failure = false
    func fail(_ value: Bool) { failure = value }
    func transcribe(url: URL) async throws -> String {
        if failure { throw MeetingFailure("Model unavailable") }
        return "We agreed to launch the pilot on Friday. Maya will send the checklist by Thursday."
    }
}
/// Holds the summary until released, like an on-device model working through a long transcript.
private actor SlowSummarizer: MeetingSummarizing {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func summarize(_ note: MeetingNote) async -> MeetingSummary {
        if !released { await withCheckedContinuation { waiting.append($0) } }
        return MeetingSummary(text: LocalMeetingSummarizer.extractive(note), method: "Test slow")
    }
    func release() { released = true; waiting.forEach { $0.resume() }; waiting = [] }
}
private struct TestSummarizer: MeetingSummarizing {
    func summarize(_ note: MeetingNote) async -> MeetingSummary {
        MeetingSummary(text: LocalMeetingSummarizer.extractive(note), method: "Test extractive")
    }
}

@MainActor final class MeetingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ id: String = "event", start: Double = 0, end: Double = 60) -> MeetingEvent {
        MeetingEvent(id: id, calendarID: "google", title: "Pilot planning", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), attendees: ["Maya", "Alex"])
    }
    private var notices: [String] = []
    private func setup(summarizer: any MeetingSummarizing = TestSummarizer()) -> (MeetingCoordinator, TestCalendar, TestCapture, TestTranscriber, URL) {
        let calendar = TestCalendar(), capture = TestCapture(), asr = TestTranscriber()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (coordinator(calendar, capture, asr, root: root, summarizer: summarizer), calendar, capture, asr, root)
    }
    private func coordinator(_ calendar: TestCalendar, _ capture: TestCapture, _ asr: TestTranscriber, root: URL,
                             summarizer: any MeetingSummarizing = TestSummarizer(),
                             loadAt: Date? = nil) -> MeetingCoordinator {
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("meetings"))!
        let coordinator = MeetingCoordinator(calendar: calendar, capture: capture, transcriber: asr,
            summarizer: summarizer, store: MeetingStore(root: root), defaults: defaults, trace: { _ in },
            notify: { [weak self] in self?.notices.append($0) })
        coordinator.load(now: loadAt ?? now); coordinator.selectedCalendars = ["google"]
        coordinator.autoStart = true; coordinator.consentConfirmed = true
        return coordinator
    }
    /// Work that hops to the recognizer or summarizer finishes within a few scheduler turns.
    private func wait(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func testScheduledMeetingAutomaticallyRecordsTranscribesSummarizesAndPersists() async throws {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 120)]
        await coordinator.tick(now: now.addingTimeInterval(-1))
        XCTAssertEqual(capture.starts, 0)
        await coordinator.tick(now: now)
        XCTAssertEqual(coordinator.countdown?.id, "event")
        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(capture.starts, 1)
        let id = try XCTUnwrap(coordinator.activeID)
        coordinator.updateNotes(id, text: "Keep my private notes unchanged.")
        capture.segments = [.init(audioFile: "system-0.wav", source: .system, offset: 0, duration: 20)]
        capture.output?(capture.segments[0])
        await coordinator.tick(now: now.addingTimeInterval(119))
        XCTAssertEqual(capture.stops, 0)
        await coordinator.tick(now: now.addingTimeInterval(120))
        XCTAssertEqual(capture.stops, 1, "A meeting that has gone quiet stops at its scheduled end")
        XCTAssertNil(coordinator.activeID)
        await coordinator.settle()
        let saved = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(saved.phase, .complete)
        XCTAssertTrue(saved.transcript.contains("Maya will send"))
        XCTAssertTrue(saved.summary.contains("launch the pilot"))
        XCTAssertEqual(saved.personalNotes, "Keep my private notes unchanged.")
        XCTAssertEqual(saved.segments.count, 1, "Tail flush must not duplicate callback segments")
        await coordinator.tick(now: now.addingTimeInterval(121))
        XCTAssertEqual(capture.starts, 1)
    }
    func testBackToBackMeetingStartsOnTimeWhileThePreviousOneIsSummarized() async throws {
        let summarizer = SlowSummarizer()
        let (coordinator, calendar, capture, _, root) = setup(summarizer: summarizer)
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event("first", end: 60), event("second", start: 60, end: 120)]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        let first = try XCTUnwrap(coordinator.activeID)
        capture.segments = [.init(audioFile: "system-0.wav", source: .system, offset: 0, duration: 20)]
        // The scheduler must not wait for the first summary (which may take minutes) before it
        // looks at the next meeting; otherwise a back-to-back meeting starts late or is skipped.
        let ending = Task { await coordinator.tick(now: now.addingTimeInterval(60)) }
        for _ in 0..<200 where coordinator.activeID != nil { await Task.yield() }
        XCTAssertEqual(capture.stops, 1)
        await coordinator.tick(now: now.addingTimeInterval(62))
        XCTAssertEqual(coordinator.countdown?.id, "second", "The next meeting's countdown waited for the previous summary")
        await coordinator.tick(now: now.addingTimeInterval(72))
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(coordinator.activeNote?.event.id, "second")
        XCTAssertEqual(coordinator.notes.first { $0.id == first }?.phase, .processing)
        await summarizer.release()
        await ending.value
        await coordinator.settle()
        XCTAssertEqual(coordinator.notes.first { $0.id == first }?.phase, .complete)
        XCTAssertEqual(coordinator.activeNote?.event.id, "second", "Finishing the first note must not disturb the second recording")
        XCTAssertTrue(coordinator.status.contains("Recording"), "A finished summary must not overwrite the live recording status")
        await coordinator.stop()
    }
    func testBriefNetworkLossKeepsTheCalendarButAccessLossClearsIt() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 300)]
        await coordinator.tick(now: now.addingTimeInterval(-20))
        calendar.offline = true
        await coordinator.tick(now: now)
        XCTAssertEqual(coordinator.countdown?.id, "event", "One failed request must not cancel the meeting")
        XCTAssertNotNil(coordinator.error)
        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(capture.starts, 1)
        await coordinator.stop()
        await coordinator.tick(now: now.addingTimeInterval(400))
        XCTAssertTrue(coordinator.upcoming.isEmpty, "After five minutes offline the calendar is no longer trusted")
        calendar.offline = false
        await coordinator.tick(now: now.addingTimeInterval(420))
        XCTAssertNil(coordinator.error, "A successful sync clears the calendar error")
        XCTAssertFalse(coordinator.upcoming.isEmpty)
        calendar.denied = true
        await coordinator.tick(now: now.addingTimeInterval(720))
        XCTAssertTrue(coordinator.upcoming.isEmpty)
        XCTAssertFalse(coordinator.connected)
    }
    func testSigningInWatchesThePrimaryCalendarAndSigningOutForgetsIt() async {
        let (coordinator, _, _, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.selectedCalendars = []
        await coordinator.connect(.google)
        XCTAssertEqual(coordinator.selectedCalendars, ["google"])
        XCTAssertTrue(coordinator.connected)
        await coordinator.disconnect()
        XCTAssertTrue(coordinator.selectedCalendars.isEmpty)
        XCTAssertTrue(coordinator.calendars.isEmpty)
        XCTAssertFalse(coordinator.connected)
    }
    func testTurningOnAutoRecordAsksForSystemAudioBeforeTheFirstMeeting() async {
        let (coordinator, _, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        capture.allowed = false
        coordinator.autoStart = false; coordinator.saveSettings()
        XCTAssertEqual(capture.permissionRequests, 0, "Nothing is asked until auto-record is on")
        coordinator.autoStart = true; coordinator.saveSettings()
        XCTAssertEqual(capture.permissionRequests, 1)
        XCTAssertFalse(coordinator.systemAudioAllowed, "The Meetings page warns before a meeting fails")
        coordinator.saveSettings()
        XCTAssertEqual(capture.permissionRequests, 1, "macOS is asked once, not on every settings change")
        capture.allowed = true
        await coordinator.tick(now: now)
        XCTAssertTrue(coordinator.systemAudioAllowed)
    }
    func testDeclinedAllDayCancelledPersonalAndNearlyOverEventsDoNotAutoRecord() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var declined = event("declined"); declined.declined = true
        var allDay = event("allDay"); allDay.allDay = true
        var cancelled = event("cancelled"); cancelled.cancelled = true
        var appointment = event("personal"); appointment.attendees = []
        calendar.entries = [declined, allDay, cancelled, appointment, event("nearlyOver", start: -300, end: 15)]
        await coordinator.tick(now: now)
        XCTAssertNil(coordinator.countdown)
        XCTAssertEqual(capture.starts, 0)
    }
    func testAMeetingTypedIntoTheCalendarWithoutLinkOrGuestsIsRecorded() async {
        for title in ["180DC LinkedIn project team meeting", "Weekly sync", "Call with Sam", "1:1 Priya", "Standup", "Kick-off", "Zoom - advisors"] {
            XCTAssertTrue(MeetingEvent.soundsLikeMeeting(title), title)
        }
        for title in ["ACCT 2610 - Principles of Financial Accounting", "MATH 2130 - Calculus III", "MATH 2130 Discussion (Sec 04)", "EnCouncil Calc III Exam 3 review", "SPAN 1010 Class Notes due",
                      "Office hours", "Gym", "Track meet", "Recall quiz", "Lunch", "Syncopation practice"] {
            XCTAssertFalse(MeetingEvent.soundsLikeMeeting(title), title)
        }
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var typed = event("typed", end: 300); typed.attendees = []; typed.title = "180DC LinkedIn project team meeting"
        var lecture = event("lecture", start: 400, end: 900); lecture.attendees = []; lecture.title = "MATH 2130 - Calculus III"
        calendar.entries = [typed, lecture]
        await coordinator.tick(now: now)
        XCTAssertEqual(coordinator.countdown?.id, "typed")
        // The switch beside an upcoming event turns any event on or off, and off can be undone.
        XCTAssertFalse(coordinator.automatic(lecture))
        coordinator.setAutomatic(lecture, true)
        XCTAssertTrue(coordinator.automatic(lecture))
        coordinator.setAutomatic(typed, false)
        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(capture.starts, 0)
        coordinator.setAutomatic(typed, true)
        await coordinator.tick(now: now.addingTimeInterval(12))
        await coordinator.tick(now: now.addingTimeInterval(22))
        XCTAssertEqual(coordinator.activeNote?.event.id, "typed")
        await coordinator.stop()
        await coordinator.tick(now: now.addingTimeInterval(400))
        await coordinator.tick(now: now.addingTimeInterval(410))
        XCTAssertEqual(coordinator.activeNote?.event.id, "lecture")
        await coordinator.stop()
    }
    func testMeetingFoundLateStillRecordsTheRest() async {
        // The Mac was asleep, FlowClone was closed or the network was down when it started.
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event("late", start: -900, end: 900)]
        await coordinator.tick(now: now)
        XCTAssertEqual(coordinator.countdown?.id, "late")
        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(coordinator.activeNote?.event.id, "late")
        // Stop is the person's decision: the rest of that meeting is left alone.
        await coordinator.stop(at: now.addingTimeInterval(20))
        await coordinator.tick(now: now.addingTimeInterval(30))
        await coordinator.tick(now: now.addingTimeInterval(45))
        XCTAssertEqual(capture.starts, 1)
        XCTAssertNil(coordinator.countdown)
    }
    func testOverlappingMeetingsRecordOneWithoutAsking() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        var call = event("call", end: 300); call.joinURL = URL(string: "https://meet.google.com/abc-defg-hij")
        calendar.entries = [event("block", start: -100, end: 600), event("plain", end: 300), call]
        await coordinator.tick(now: now)
        XCTAssertEqual(coordinator.countdown?.id, "call", "Latest start first, then the one with a call link")
        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(coordinator.activeNote?.event.id, "call")
        // When it ends, the longer meeting around it is still running and gets the rest.
        await coordinator.tick(now: now.addingTimeInterval(300))
        XCTAssertEqual(capture.stops, 1)
        await coordinator.tick(now: now.addingTimeInterval(302))
        XCTAssertEqual(coordinator.countdown?.id, "block")
        await coordinator.tick(now: now.addingTimeInterval(312))
        XCTAssertEqual(coordinator.activeNote?.event.id, "block")
        XCTAssertEqual(capture.starts, 2)
        await coordinator.stop()
    }
    func testMeetingRunningOverKeepsRecordingUntilTheTalkingStops() async throws {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event()]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        let id = try XCTUnwrap(coordinator.activeID)
        // Words heard until two seconds before the scheduled end (recording began at +10).
        capture.output?(.init(audioFile: "system-30000.wav", source: .system, offset: 30, duration: 18))
        await wait { coordinator.activeNote?.segments.first?.text != nil }
        await coordinator.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(capture.stops, 0, "People are still talking at the scheduled end")
        XCTAssertTrue(coordinator.status.contains("past its scheduled end"))
        await coordinator.tick(now: now.addingTimeInterval(100))
        XCTAssertEqual(capture.stops, 0)
        await coordinator.tick(now: now.addingTimeInterval(104))
        XCTAssertEqual(capture.stops, 1, "45 seconds without words ends it")
        await coordinator.settle()
        let saved = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertEqual(saved.phase, .complete)
        XCTAssertEqual(saved.endedAt, now.addingTimeInterval(104))
    }
    func testOverrunNeverRunsIntoTheNextMeetingOrPastThirtyMinutes() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event("first"), event("second", start: 60, end: 4000)]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        capture.output?(.init(audioFile: "system-30000.wav", source: .system, offset: 30, duration: 18))
        await wait { coordinator.activeNote?.segments.first?.text != nil }
        await coordinator.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(capture.stops, 1, "The next meeting starts on time")
        await coordinator.tick(now: now.addingTimeInterval(62))
        await coordinator.tick(now: now.addingTimeInterval(72))
        XCTAssertEqual(coordinator.activeNote?.event.id, "second")
        // Still talking 30 minutes past the end: the limit stops it.
        capture.output?(.init(audioFile: "system-5700000.wav", source: .system, offset: 5700, duration: 18))
        await wait { coordinator.activeNote?.segments.first?.text != nil }
        await coordinator.tick(now: now.addingTimeInterval(4000 + 1795))
        XCTAssertEqual(capture.stops, 1)
        await coordinator.tick(now: now.addingTimeInterval(4000 + 1800))
        XCTAssertEqual(capture.stops, 2)
    }
    func testInterruptedRecordingContinuesByItselfUntilThePersonStops() async throws {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 600)]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        let id = try XCTUnwrap(coordinator.activeID)
        capture.segments = [.init(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 10)]
        // A microphone change continues at once, without waiting for a summary or the next tick.
        capture.interrupt?("The microphone changed or was disconnected.", true)
        await wait { capture.starts == 2 }
        XCTAssertEqual(coordinator.activeID, id, "The same note continues")
        XCTAssertEqual(coordinator.notes.first?.phase, .recording)
        XCTAssertTrue(coordinator.processing.isEmpty)
        XCTAssertEqual(coordinator.notes.count, 1)
        XCTAssertNil(coordinator.notes.first?.issue)
        // Sleep is handled the same way.
        await coordinator.stop(reason: "This Mac went to sleep.", at: now.addingTimeInterval(30), resumable: true)
        await coordinator.tick(now: now.addingTimeInterval(40))
        XCTAssertEqual(capture.starts, 3)
        // Stopping system audio from the menu bar, or Stop, is the person's choice.
        capture.interrupt?("You stopped system audio capture from the menu bar.", false)
        await wait { coordinator.activeID == nil && coordinator.processing.isEmpty }
        await coordinator.tick(now: now.addingTimeInterval(50))
        await coordinator.tick(now: now.addingTimeInterval(120))
        XCTAssertEqual(capture.starts, 3)
        XCTAssertEqual(coordinator.notes.first?.phase, .complete)
        XCTAssertEqual(coordinator.notes.first?.segments.count, 1)
    }
    func testAWorkingMicrophoneAppearingMidMeetingReplacesTheSilentOne() async throws {
        // Clamshell with no external microphone: the built-in one records zeros until, say, the
        // display's microphone comes back.
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 600)]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        let id = try XCTUnwrap(coordinator.activeID)
        await coordinator.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(capture.starts, 1)
        capture.microphoneShouldChange = true
        await coordinator.tick(now: now.addingTimeInterval(40))
        capture.microphoneShouldChange = false
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(coordinator.activeID, id)
        XCTAssertEqual(coordinator.notes.count, 1)
        XCTAssertNil(coordinator.notes.first?.issue)
        await coordinator.tick(now: now.addingTimeInterval(60))
        XCTAssertEqual(capture.starts, 2)
        await coordinator.stop()
    }
    func testFailedStartIsRetriedWhileTheMeetingRunsAndToldOnce() async throws {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 600)]; capture.failure = "System audio denied"
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(coordinator.notes.first?.phase, .failed)
        await coordinator.tick(now: now.addingTimeInterval(12))
        XCTAssertEqual(capture.starts, 2)
        await coordinator.tick(now: now.addingTimeInterval(14))
        XCTAssertEqual(capture.starts, 2, "Retries are spaced out")
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(try XCTUnwrap(notices.first).contains("System audio denied"))
        capture.failure = nil  // The permission was granted.
        await coordinator.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(capture.starts, 3)
        XCTAssertNotNil(coordinator.activeID)
        XCTAssertEqual(coordinator.notes.count, 1, "The failed note is reused, not duplicated")
        XCTAssertEqual(coordinator.notes.first?.startedAt, now.addingTimeInterval(30))
        await coordinator.stop()
    }
    func testRelaunchDuringAMeetingContinuesRecording() async throws {
        let (first, calendar, _, asr, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 600)]
        await first.start(calendar.entries[0], now: now)
        let id = try XCTUnwrap(first.activeID)
        // FlowClone quit unexpectedly; a new launch finds the note still marked as recording
        // and resumes live capture at once without blocking behind an intermediate summary.
        let capture = TestCapture()
        let second = coordinator(calendar, capture, asr, root: root, loadAt: now.addingTimeInterval(30))
        XCTAssertTrue(second.processing.isEmpty)
        XCTAssertEqual(second.notes.first?.phase, .interrupted)
        await second.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(second.activeID, id)
        XCTAssertEqual(second.notes.count, 1)
        await second.stop()
        await first.stop()
    }
    func testExpiredSignInIsToldOnceAndANetworkBlipIsNot() async {
        let (coordinator, calendar, _, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.offline = true
        await coordinator.tick(now: now)
        XCTAssertTrue(notices.isEmpty)
        calendar.offline = false; calendar.denied = true
        await coordinator.tick(now: now.addingTimeInterval(16))
        await coordinator.tick(now: now.addingTimeInterval(32))
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("not being recorded"))
        calendar.denied = false
        await coordinator.tick(now: now.addingTimeInterval(48))
        calendar.denied = true
        await coordinator.tick(now: now.addingTimeInterval(348))
        XCTAssertEqual(notices.count, 2, "A new expiry after a working spell is told again")
    }
    func testCalendarDisconnectionOffersReconnectWithoutStartingARecording() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 300)]
        calendar.signInRequired = true
        await coordinator.tick(now: now)
        XCTAssertEqual(coordinator.recordingAttention?.menuTitle, "Reconnect Google Calendar…")
        XCTAssertNil(coordinator.countdown)
        XCTAssertEqual(capture.starts, 0)

        calendar.signInRequired = false
        await coordinator.tick(now: now.addingTimeInterval(16))
        XCTAssertNil(coordinator.recordingAttention)
        XCTAssertNotNil(coordinator.countdown)

        calendar.signInRequired = true
        await coordinator.tick(now: now.addingTimeInterval(32))
        XCTAssertNotNil(coordinator.recordingAttention)
        coordinator.autoStart = false
        coordinator.saveSettings()
        XCTAssertNil(coordinator.recordingAttention)
        XCTAssertNil(coordinator.countdown)
    }
    func testCancelCountdownConsentAndPermissionLoss() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 300)]
        coordinator.consentConfirmed = false
        await coordinator.tick(now: now); XCTAssertNil(coordinator.countdown)
        coordinator.consentConfirmed = true
        await coordinator.tick(now: now); XCTAssertNotNil(coordinator.countdown)
        coordinator.dismiss(calendar.entries[0])
        await coordinator.tick(now: now.addingTimeInterval(11)); XCTAssertEqual(capture.starts, 0)
        calendar.entries = [event("next", start: 320, end: 600)]
        await coordinator.tick(now: now.addingTimeInterval(320)); XCTAssertNotNil(coordinator.countdown)
        calendar.denied = true
        await coordinator.tick(now: now.addingTimeInterval(336)); XCTAssertNil(coordinator.countdown)
        XCTAssertEqual(capture.starts, 0)
    }
    func testDelayedTimerGivesAFreshCountdownInsteadOfStartingUnannounced() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 300)]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(40))
        XCTAssertEqual(capture.starts, 0)
        XCTAssertEqual(coordinator.countdown?.id, "event")
        await coordinator.tick(now: now.addingTimeInterval(50))
        XCTAssertEqual(capture.starts, 1)
        await coordinator.stop()
    }
    func testCaptureFailureIsVisibleAndNeverClaimsRecording() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event()]; capture.failure = "System audio denied"
        await coordinator.start(calendar.entries[0], now: now)
        XCTAssertNil(coordinator.activeID)
        XCTAssertEqual(coordinator.notes.first?.phase, .failed)
        XCTAssertEqual(coordinator.error, "System audio denied")
        capture.failure = nil
        await coordinator.start(calendar.entries[0], now: now)
        XCTAssertNotNil(coordinator.activeID, "A user must be able to retry recording after granting permission")
        await coordinator.stop()
    }
    func testFailedTranscriptionIsPartialAndRetryRecovers() async throws {
        let (coordinator, calendar, capture, asr, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event()]
        await asr.fail(true)
        await coordinator.start(calendar.entries[0], now: now)
        let id = try XCTUnwrap(coordinator.activeID)
        capture.segments = [.init(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 10)]
        await coordinator.stop()
        XCTAssertEqual(coordinator.notes.first?.phase, .failed)
        XCTAssertNotNil(coordinator.notes.first?.segments.first?.error)
        await asr.fail(false)
        await coordinator.retry(id)
        XCTAssertEqual(coordinator.notes.first?.phase, .complete)
        XCTAssertNotNil(coordinator.notes.first?.segments.first?.text)
    }
    func testCalendarCancellationStopsCaptureAndRecurringOccurrenceCanStart() async {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event()]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        calendar.entries = []
        await coordinator.tick(now: now.addingTimeInterval(30))
        XCTAssertNil(coordinator.activeID); XCTAssertEqual(capture.stops, 1)
        calendar.entries = [event("event-occurrence-2", start: 360, end: 600)]
        await coordinator.tick(now: now.addingTimeInterval(360))
        await coordinator.tick(now: now.addingTimeInterval(370))
        XCTAssertEqual(capture.starts, 2)
        await coordinator.stop()
        await coordinator.settle()
        XCTAssertTrue(coordinator.notes.allSatisfy { $0.phase == .complete })
    }
    func testRecoveryFindsAudioNotYetInManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let note = MeetingNote(event: event(), startedAt: now)
        try store.save(note)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for i in 0..<16000 { buffer.floatChannelData![0][i] = 0 }
        do {
            let file = try AVAudioFile(forWriting: store.directory(note.id).appendingPathComponent("system-12000.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        let recovered = try store.recoveredSegments(for: note)
        XCTAssertEqual(recovered.count, 1); XCTAssertEqual(recovered[0].offset, 12)
        XCTAssertEqual(recovered[0].duration, 1, accuracy: 0.001)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory(note.id).appendingPathComponent("note.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    /// A crash leaves the last WAV unclosed: its samples are on disk but its header still says
    /// 0 bytes, so AVAudioFile reads it as empty and the segment used to be dropped.
    func testRecoveryKeepsTheAudioOfAFileNeverClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let note = MeetingNote(event: event(), startedAt: now)
        try store.save(note)
        let directory = store.directory(note.id)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for i in 0..<24000 { buffer.floatChannelData![0][i] = Float(i % 100) / 400 }
        func closedFile(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            do { try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer) }
            return url
        }
        func dataChunk(_ bytes: [UInt8]) -> Int {
            (12..<(bytes.count - 4)).first { bytes[$0..<($0 + 4)].elementsEqual("data".utf8) }!
        }
        func le(_ bytes: [UInt8], _ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }

        // 1.5 s whose header sizes read 0, plus 2 bytes of a frame the crash cut off.
        let unclosed = try closedFile("microphone-5000.wav")
        var bytes = [UInt8](try Data(contentsOf: unclosed))
        let data = dataChunk(bytes)
        // As the crash left them: RIFF covers the header only and the data size is 0.
        for (k, byte) in [UInt8](withUnsafeBytes(of: UInt32(data).littleEndian, Array.init)).enumerated() { bytes[4 + k] = byte }
        for at in (data + 4)..<(data + 8) { bytes[at] = 0 }
        bytes += [0x12, 0x34]
        try Data(bytes).write(to: unclosed)
        XCTAssertEqual(try AVAudioFile(forReading: unclosed).length, 0, "the unclosed file reads as empty before repair")

        // Only a header: a crash right after the file was created.
        let empty = try closedFile("system-9000.wav")
        try Data(bytes.prefix(data + 8)).write(to: empty)

        // Bytes copied while the writer still has the file open, as a crash leaves them.
        let open = root.appendingPathComponent("writer.wav")
        let writer = try AVAudioFile(forWriting: open, settings: format.settings)
        try writer.write(from: buffer)
        let snapshot = directory.appendingPathComponent("system-20000.wav")
        try FileManager.default.copyItem(at: open, to: snapshot)
        let snapshotBytes = [UInt8](try Data(contentsOf: snapshot))
        let snapshotFrames = (snapshotBytes.count - dataChunk(snapshotBytes) - 8) / 4
        withExtendedLifetime(writer) {}
        try FileManager.default.removeItem(at: open)

        let recovered = try store.recoveredSegments(for: note)
        XCTAssertEqual(recovered.map(\.audioFile), ["microphone-5000.wav", "system-20000.wav"])
        guard recovered.count == 2 else { return }
        XCTAssertEqual(recovered[0].offset, 5); XCTAssertEqual(recovered[0].source, .microphone)
        XCTAssertEqual(recovered[0].duration, 1.5, accuracy: 0.0001)
        XCTAssertGreaterThan(snapshotFrames, 0)
        XCTAssertEqual(recovered[1].duration, Double(snapshotFrames) / 16000, accuracy: 0.0001)

        // The repaired file is readable for transcription, sample for sample.
        let repaired = try AVAudioFile(forReading: unclosed)
        XCTAssertEqual(repaired.length, 24000)
        let read = AVAudioPCMBuffer(pcmFormat: repaired.processingFormat, frameCapacity: 4096)!
        var frames = 0
        var last: Float = -1
        while repaired.framePosition < repaired.length {
            try repaired.read(into: read)
            guard read.frameLength > 0 else { break }
            frames += Int(read.frameLength); last = read.floatChannelData![0][Int(read.frameLength) - 1]
        }
        XCTAssertEqual(frames, 24000)
        XCTAssertEqual(last, buffer.floatChannelData![0][23999])
        let header = [UInt8](try Data(contentsOf: unclosed))
        XCTAssertEqual(le(header, data + 4), 24000 * 4)
        XCTAssertEqual(le(header, 4), data + 8 + 24000 * 4 - 8)
        // The header-only file is left exactly as it was, and a second pass changes nothing.
        XCTAssertEqual(try Data(contentsOf: empty).count, data + 8)
        XCTAssertFalse(MeetingStore.repairUnclosedWAV(at: unclosed))
        XCTAssertEqual(try store.recoveredSegments(for: note).map(\.duration), recovered.map(\.duration))
    }
    func testLongSummaryChunkingKeepsBeginningMiddleAndEnd() {
        let transcript = String(repeating: "Important commitment. ", count: 1800) + "FINAL DECISION"
        let parts = LocalMeetingSummarizer.parts(transcript, limit: 6500)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 6500 })
        XCTAssertEqual(parts.joined().replacingOccurrences(of: "\n", with: ""), transcript)
    }
    func testConferenceLinksRejectLookalikeHostsAndNonHTTPS() {
        XCTAssertNil(MacMeetingCalendar.meetingURL(in: "https://meet.google.com.evil.example/test"))
        XCTAssertNil(MacMeetingCalendar.meetingURL(in: "http://zoom.us/test"))
        XCTAssertEqual(MacMeetingCalendar.meetingURL(in: "Join https://meet.google.com/abc-defg-hij")?.host, "meet.google.com")
    }
    func testNativeSystemPCMAndMicrophoneAreConvertedAndFlushedSeparately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = MeetingAudioWriter(directory: root, startedAt: Date(), segment: { _ in }, failed: { message, _ in
            XCTFail(message)
        })
        // ScreenCaptureKit may deliver stereo, non-interleaved Float32 PCM.
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        pcm.frameLength = 48000
        for channel in 0..<2 { for i in 0..<48000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) / 20)) * 0.2 } }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
            formatDescription: format.formatDescription, sampleCount: 48000, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let buffer = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        writer.queue.sync { writer.receiveSystem(buffer) }
        writer.microphone(pcm)
        let segments = try writer.finish()
        XCTAssertEqual(Set(segments.map(\.source)), [.microphone, .system])
        for segment in segments {
            let file = try AVAudioFile(forReading: root.appendingPathComponent(segment.audioFile))
            XCTAssertEqual(file.processingFormat.sampleRate, 16000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            XCTAssertEqual(segment.duration, 1, accuracy: 0.01)
            XCTAssertEqual(Double(file.length) / 16000, segment.duration, accuracy: 0.001)
        }
    }

    func testResumePreservesEarlierTranscriptNotesAndEventIdentity() async throws {
        let (coordinator, calendar, capture, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event()]
        await coordinator.start(calendar.entries[0], now: now)
        let id = try XCTUnwrap(coordinator.activeID)
        coordinator.updateNotes(id, text: "Keep these notes")
        capture.segments = [.init(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 10)]
        await coordinator.stop(at: now.addingTimeInterval(10))
        await coordinator.resume(id, now: now.addingTimeInterval(20))
        XCTAssertEqual(coordinator.activeID, id)
        XCTAssertEqual(coordinator.notes.count, 1)
        capture.segments = [.init(audioFile: "system-20000.wav", source: .system, offset: 20, duration: 10)]
        await coordinator.stop(at: now.addingTimeInterval(30))
        let note = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(note.segments.count, 2)
        XCTAssertEqual(note.personalNotes, "Keep these notes")
        XCTAssertEqual(note.phase, .complete)
        XCTAssertEqual(note.startedAt, now)
        await coordinator.resume(id, now: now.addingTimeInterval(70))
        XCTAssertNil(coordinator.activeID)
        XCTAssertEqual(capture.starts, 2)
    }

    func testBlocksUpdateAndPrepareForTerminationPreserveMeetingStateAndDrainProcessing() async throws {
        // 1. blocksUpdate covers countdown, active recording, and background summarizing.
        let slow = SlowSummarizer()
        let (coordinator, calendar, capture, _, root) = setup(summarizer: slow)
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 600)]
        XCTAssertFalse(coordinator.blocksUpdate)

        await coordinator.tick(now: now)
        XCTAssertNotNil(coordinator.countdown)
        XCTAssertTrue(coordinator.blocksUpdate, "Countdown before auto-start must block auto-update/relaunch")

        await coordinator.tick(now: now.addingTimeInterval(10))
        XCTAssertNotNil(coordinator.activeID)
        XCTAssertTrue(coordinator.blocksUpdate, "Active background recording must block auto-update/relaunch")

        // 2. Relaunch (or unexpected termination) during an automatic meeting preserves autoResume = true.
        capture.segments = [.init(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 12)]
        await coordinator.prepareForTermination(relaunching: true, explicitQuit: false, timeout: 1.0)
        let afterRelaunch = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(afterRelaunch.phase, .interrupted)
        XCTAssertEqual(afterRelaunch.autoResume, true)
        XCTAssertFalse(coordinator.blocksUpdate)

        // Resume and verify unexpected non-user-quit termination on an auto-started meeting also preserves autoResume.
        await coordinator.tick(now: now.addingTimeInterval(20))
        XCTAssertEqual(capture.starts, 2)
        await coordinator.prepareForTermination(relaunching: false, explicitQuit: false, timeout: 1.0)
        let afterUnexpectedExit = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(afterUnexpectedExit.phase, .interrupted)
        XCTAssertEqual(afterUnexpectedExit.autoResume, true)

        // 3. Intentional user Quit stops with resumable = false, summarizes, and drains processing within timeout.
        await coordinator.tick(now: now.addingTimeInterval(30))
        XCTAssertEqual(capture.starts, 3)
        // Release SlowSummarizer shortly after termination begins so prepareForTermination drains cleanly.
        Task {
            try? await Task.sleep(for: .milliseconds(40))
            await slow.release()
        }
        await coordinator.prepareForTermination(relaunching: false, explicitQuit: true, timeout: 2.0)
        let afterQuit = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(afterQuit.phase, .complete)
        XCTAssertNil(afterQuit.autoResume)
        XCTAssertFalse(coordinator.blocksUpdate)
    }

    func testCrashRecoveryResumesLiveCaptureWithoutWaitingForSlowSummaryAndSeedsSegmentOffsets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let liveEvent = event(end: 600)
        var crashed = MeetingNote(event: liveEvent, startedAt: now, autoResume: true)
        crashed.phase = .recording
        try store.save(crashed)

        // Write a real 1.5s microphone WAV on disk as left behind before the crash.
        let directory = store.directory(crashed.id)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
        pcm.frameLength = 24000
        for i in 0..<24000 { pcm.floatChannelData![0][i] = 0.05 }
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("microphone-10000.wav"),
                                       settings: format.settings)
            try file.write(from: pcm)
        }

        // SlowSummarizer never releases unless asked: if load() had queued a summary in `processing`,
        // `resumeInterrupted` would block forever. Instead live capture resumes immediately!
        let slow = SlowSummarizer()
        let calendar = TestCalendar(); calendar.entries = [liveEvent]
        let capture = TestCapture(), asr = TestTranscriber()
        let recovered = coordinator(calendar, capture, asr, root: root, summarizer: slow,
                                    loadAt: now.addingTimeInterval(20))
        XCTAssertTrue(recovered.processing.isEmpty, "Live auto-resumable crash recovery must not block behind summarize")
        XCTAssertEqual(recovered.notes.first?.segments.map(\.audioFile), ["microphone-10000.wav"])

        await recovered.tick(now: now.addingTimeInterval(20))
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(recovered.activeID, crashed.id)
        let seededMicOffset = try XCTUnwrap(capture.lastInitialOffsets[.microphone])
        XCTAssertEqual(seededMicOffset, 11.5, accuracy: 0.01, "Initial offset must start at max(offset + duration)")
        XCTAssertNil(capture.lastInitialOffsets[.system])

        await slow.release()
        await recovered.stop(at: now.addingTimeInterval(40))
        await recovered.settle()
        let saved = try XCTUnwrap(recovered.store.load().first)
        XCTAssertEqual(saved.phase, .complete)
        XCTAssertTrue(saved.transcript.contains("Maya will send"))
    }

    func testMeetingAudioWriterSeedsOffsetsAndNeverOverwritesExistingSegmentFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Pre-populate both microphone-0.wav and the exact seeded start microphone-11500.wav with sentinel bytes
        // to prove MeetingAudioWriter neither starts at 0 nor truncates an existing file at the seeded ms.
        let sentinel0 = Data("EXISTING-SEGMENT-0".utf8)
        let sentinelSeed = Data("EXISTING-SEGMENT-11500".utf8)
        try sentinel0.write(to: root.appendingPathComponent("microphone-0.wav"))
        try sentinelSeed.write(to: root.appendingPathComponent("microphone-11500.wav"))

        let writer = MeetingAudioWriter(
            directory: root,
            startedAt: Date(),
            initialOffsets: [.microphone: 11.5],
            segment: { _ in },
            failed: { message, _ in XCTFail(message) })

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        pcm.frameLength = 16000
        for i in 0..<16000 { pcm.floatChannelData![0][i] = Float(sin(Double(i) / 15)) * 0.2 }
        writer.microphone(pcm)
        let written = try writer.finish()

        XCTAssertEqual(written.count, 1)
        let seg = try XCTUnwrap(written.first)
        XCTAssertNotEqual(seg.audioFile, "microphone-0.wav")
        XCTAssertNotEqual(seg.audioFile, "microphone-11500.wav")
        XCTAssertGreaterThanOrEqual(seg.offset, 11.501)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("microphone-0.wav")), sentinel0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("microphone-11500.wav")), sentinelSeed)
        XCTAssertEqual(try AVAudioFile(forReading: root.appendingPathComponent(seg.audioFile)).length, 16000)
    }

    func testMacMeetingCalendarSkipsNilDatesAndFallsBackToAttendeeMailto() throws {
        // 1. Nil startDate or endDate returns nil cleanly without force-unwrapping.
        XCTAssertNil(MacMeetingCalendar.makeEvent(
            calendarIdentifier: "cal", itemIdentifier: "item-nil-start", title: "Broken",
            startDate: nil, endDate: now.addingTimeInterval(1800), occurrenceDate: nil,
            attendees: [], eventURL: nil, location: nil, notes: nil, isAllDay: false, isCancelled: false))
        XCTAssertNil(MacMeetingCalendar.makeEvent(
            calendarIdentifier: "cal", itemIdentifier: "item-nil-end", title: "Broken",
            startDate: now, endDate: nil, occurrenceDate: nil,
            attendees: [], eventURL: nil, location: nil, notes: nil, isAllDay: false, isCancelled: false))

        // 2. EventKit/CalDAV participants with nil/blank display names fall back to mailto: email
        //    so a 1:1 or group call without a conference URL still qualifies as isAutomaticEligible.
        let mapped = try XCTUnwrap(MacMeetingCalendar.makeEvent(
            calendarIdentifier: "cal", itemIdentifier: "sync-1", title: "CalDAV 1:1",
            startDate: now, endDate: now.addingTimeInterval(1800), occurrenceDate: now,
            attendees: [
                (name: nil, url: URL(string: "mailto:Andre@example.com"), isCurrentUser: true, declined: false),
                (name: "   ", url: URL(string: "MAILTO:guest%2Bops@example.com?subject=hi"), isCurrentUser: false, declined: false),
            ],
            eventURL: nil, location: nil, notes: nil, isAllDay: false, isCancelled: false))
        XCTAssertEqual(mapped.attendees, ["Andre@example.com", "guest+ops@example.com"])
        XCTAssertTrue(mapped.isAutomaticEligible, "Two mailto-only attendees must satisfy automatic meeting eligibility")
    }

    func testActiveRecordingTickDoesNotRewriteNoteWhenEventIsUnchangedButUpdatesOnExtension() async throws {
        let (coordinator, calendar, _, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 120)]
        await coordinator.tick(now: now)
        await coordinator.tick(now: now.addingTimeInterval(10))
        let id = try XCTUnwrap(coordinator.activeID)
        let noteURL = coordinator.store.directory(id).appendingPathComponent("note.json")
        let sentinelDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: noteURL.path)

        // Subsequent 2-second ticks and 15-second syncs with an unchanged event must not rewrite note.json.
        await coordinator.tick(now: now.addingTimeInterval(12))
        await coordinator.tick(now: now.addingTimeInterval(28))
        let mtimeUnchanged = try FileManager.default.attributesOfItem(atPath: noteURL.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeUnchanged, sentinelDate, "Unchanged calendar events must not rewrite note.json on every tick")

        // Extending the meeting in the calendar updates the active note and persists the new end time.
        calendar.entries = [event(end: 300)]
        await coordinator.tick(now: now.addingTimeInterval(45))
        XCTAssertEqual(coordinator.activeNote?.event.end, now.addingTimeInterval(300))
        let reloaded = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(reloaded.event.end, now.addingTimeInterval(300))
        await coordinator.stop(at: now.addingTimeInterval(50))
    }

    func testUnchangedCalendarSyncDoesNotInvalidateObservers() async throws {
        let (coordinator, calendar, _, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event("sync-a", start: 600, end: 1800)]
        try await coordinator.sync(now: now)
        XCTAssertEqual(coordinator.upcoming.count, 1)

        final class Flag: @unchecked Sendable { var value = false }
        let flag = Flag()
        withObservationTracking {
            _ = coordinator.calendars
            _ = coordinator.upcoming
            _ = coordinator.status
            _ = coordinator.connected
        } onChange: {
            flag.value = true
        }

        try await coordinator.sync(now: now.addingTimeInterval(15))
        XCTAssertFalse(flag.value, "Refreshing an unchanged calendar must not invalidate @Observable views")

        calendar.entries.append(event("sync-b", start: 2400, end: 3600))
        try await coordinator.sync(now: now.addingTimeInterval(30))
        XCTAssertTrue(flag.value, "Adding a new upcoming meeting must notify @Observable subscribers")
        XCTAssertEqual(coordinator.upcoming.count, 2)
    }

    func testRapidPersonalNoteEditsCoalesceDiskWritesAndFlushOnLifecycleBoundaries() async throws {
        let (coordinator, calendar, _, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        calendar.entries = [event(end: 300)]
        await coordinator.start(calendar.entries[0], now: now)
        let id = try XCTUnwrap(coordinator.activeID)
        let noteURL = coordinator.store.directory(id).appendingPathComponent("note.json")
        let sentinelDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinelDate], ofItemAtPath: noteURL.path)

        for step in 0..<20 {
            coordinator.updateNotes(id, text: "Keystroke revision \(step)")
        }
        XCTAssertEqual(coordinator.selectedNote?.personalNotes, "Keystroke revision 19")
        let mtimeDuringTyping = try FileManager.default.attributesOfItem(atPath: noteURL.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeDuringTyping, sentinelDate, "Rapid personal-note keystrokes must debounce synchronous disk writes")

        await coordinator.stop(at: now.addingTimeInterval(20))
        await coordinator.settle()
        let saved = try XCTUnwrap(coordinator.store.load().first)
        XCTAssertEqual(saved.personalNotes, "Keystroke revision 19")
        let permissions = try FileManager.default.attributesOfItem(atPath: noteURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDisplaySegmentsOmitsSilentChunksAndLongTranscriptUsesBoundedNativeViews() throws {
        let mixed = MeetingNote(
            event: event(),
            startedAt: now,
            phase: .recording,
            segments: [
                .init(audioFile: "system-24000.wav", source: .system, offset: 24, duration: 12, text: nil, error: "ASR timeout"),
                .init(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 12, text: "Opening remarks."),
                .init(audioFile: "system-12000.wav", source: .system, offset: 12, duration: 12, text: ""),
                .init(audioFile: "microphone-36000.wav", source: .microphone, offset: 36, duration: 12, text: nil, error: nil),
            ]
        )
        XCTAssertEqual(mixed.displaySegments.map(\.offset), [0, 24, 36],
                       "Silent chunks are omitted while spoken, errored, and pending segments stay sorted")

        let allSilent = MeetingNote(
            event: event("silent"),
            startedAt: now,
            phase: .complete,
            segments: [
                .init(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 12, text: ""),
                .init(audioFile: "system-12000.wav", source: .system, offset: 12, duration: 12, text: ""),
            ]
        )
        XCTAssertEqual(allSilent.displaySegments.count, 1,
                       "An entirely silent recording collapses to a single no-speech placeholder")

        // Regression guard: an 800-segment note on the Transcript tab must render in a single native
        // NSTextView rather than creating hundreds of AppKitTextInteractionView subviews.
        _ = NSApplication.shared
        let (coordinator, _, _, _, root) = setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let longSegments: [MeetingSegment] = (0..<800).map { i in
            MeetingSegment(
                audioFile: "seg-\(i).wav",
                source: i.isMultiple(of: 2) ? .system : .microphone,
                offset: Double(i) * 12,
                duration: 12,
                text: i.isMultiple(of: 3) ? "" : "Segment \(i) decision checkpoint"
            )
        }
        let longNote = MeetingNote(event: event("long"), startedAt: now, endedAt: now.addingTimeInterval(9600),
                                   phase: .complete, segments: longSegments, summary: "## Decisions\n- Ship v1")
        try coordinator.store.save(longNote)
        coordinator.notes = [longNote]
        coordinator.selectedNoteID = longNote.id

        let host = NSHostingView(rootView: MeetingsPage(meetings: coordinator, initialTab: "Transcript"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        host.layoutSubtreeIfNeeded()

        func subviewCount(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + subviewCount($1) } }
        func findTextView(_ view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView, tv.accessibilityIdentifier() == "meetingTranscript" { return tv }
            for sub in view.subviews { if let found = findTextView(sub) { return found } }
            return nil
        }

        XCTAssertLessThan(subviewCount(host), 80, "800-segment transcript must not explode AppKit subview count")
        let transcriptView = try XCTUnwrap(findTextView(host))
        XCTAssertTrue(transcriptView.string.contains("Segment 1 decision checkpoint"))
        XCTAssertTrue(transcriptView.string.contains("Segment 799 decision checkpoint"))
        XCTAssertFalse(transcriptView.string.contains("[No speech]"))
        window.contentView = nil
    }

}
