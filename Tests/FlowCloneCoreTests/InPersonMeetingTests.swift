import AVFoundation
import XCTest
@testable import FlowCloneCore

@MainActor
private final class InPersonMockCalendar: MeetingCalendarProviding {
    func connect(_ source: MeetingCalendarSource) async throws {}
    func calendars() async throws -> [MeetingCalendar] { [] }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] { [] }
}

@MainActor
private final class InPersonMockCapture: MeetingCapturing {
    var systemAudioAllowed: Bool = false
    private(set) var startedModes: [MeetingCaptureMode] = []
    private var segmentsToReturn: [MeetingSegment] = []

    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        try await start(directory: directory, startedAt: startedAt, initialOffsets: initialOffsets,
                        captureMode: .call, segment: segment, failed: failed)
    }

    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval],
               captureMode: MeetingCaptureMode,
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        startedModes.append(captureMode)
        let seg = MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 5)
        segmentsToReturn = [seg]
        segment(seg)
    }

    func stop() async throws -> [MeetingSegment] {
        segmentsToReturn
    }
}

private actor InPersonMockTranscriber: MeetingTranscribing {
    func transcribe(url: URL) async throws -> String {
        "Thanks for coming in. We want to launch the new client portal by March 15 with a $25,000 budget."
    }
}

private actor InPersonMockSummarizer: MeetingSummarizing {
    private(set) var lastInput: MeetingSummaryInput?
    func summarize(_ note: MeetingNote) async -> MeetingSummary {
        lastInput = MeetingSummaryInput(note: note)
        return MeetingSummary(
            text: "## Overview\nClient kickoff covering the March 15 portal launch and $25,000 budget.\n\n## Action Items\n- Send revised proposal by Friday.",
            method: "Claude Sonnet 5.5"
        )
    }
}

@MainActor
final class InPersonMeetingTests: XCTestCase {
    func testInPersonMeetingStartsMicOnlyWithoutSystemAudioOrCalendarConsent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inperson-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let defaults = UserDefaults(suiteName: ScratchDefaults.name("in-person-meeting"))!
        let capture = InPersonMockCapture()
        capture.systemAudioAllowed = false
        let summarizer = InPersonMockSummarizer()
        let coordinator = MeetingCoordinator(
            calendar: InPersonMockCalendar(),
            capture: capture,
            transcriber: InPersonMockTranscriber(),
            summarizer: summarizer,
            store: MeetingStore(root: dir),
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.consentConfirmed = false
        let now = Date(timeIntervalSince1970: 1_800_100_000)

        let id = await coordinator.startInPersonMeeting(title: "Acme Corp Discovery", now: now)
        let noteID = try XCTUnwrap(id)
        XCTAssertEqual(capture.startedModes, [.inPerson])
        XCTAssertTrue(coordinator.status.contains("in-person (microphone only)"))

        let active = try XCTUnwrap(coordinator.activeNote)
        XCTAssertTrue(active.isInPerson)
        XCTAssertEqual(active.captureMode, .inPerson)
        XCTAssertEqual(active.event.title, "Acme Corp Discovery")
        XCTAssertTrue(active.userRenamedTitle)

        await coordinator.stop(at: now.addingTimeInterval(30))
        await coordinator.settle()

        let finished = try XCTUnwrap(coordinator.notes.first { $0.id == noteID })
        XCTAssertEqual(finished.phase, .complete)
        XCTAssertEqual(finished.event.title, "Acme Corp Discovery", "Custom client title must be preserved")
        XCTAssertTrue(finished.transcript.contains("Room · microphone:"))
        XCTAssertFalse(finished.transcript.contains("You · microphone:"))

        let summaryInput = await summarizer.lastInput
        XCTAssertEqual(summaryInput?.isInPerson, true)
        let context = ClaudeMeetingSummarizer.contextBlock(for: try XCTUnwrap(summaryInput))
        XCTAssertTrue(context.contains("In-person conversation (single room microphone"))

        // Persisted note.json reloads with captureMode == .inPerson intact.
        let reloaded = try MeetingStore(root: dir).load()
        XCTAssertEqual(reloaded.first?.captureMode, .inPerson)
        XCTAssertEqual(reloaded.first?.isInPerson, true)
    }

    func testLegacyNoteJSONWithoutCaptureModeDecodesAsCall() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = MeetingEvent.adHoc(title: "Team Sync", now: now)
        let legacyJSON: [String: Any] = [
            "id": UUID().uuidString,
            "event": [
                "id": event.id,
                "calendarID": "",
                "title": "Team Sync",
                "start": now.timeIntervalSinceReferenceDate,
                "end": now.addingTimeInterval(1800).timeIntervalSinceReferenceDate,
                "attendees": [],
                "allDay": false,
                "declined": false,
                "cancelled": false
            ],
            "startedAt": now.timeIntervalSinceReferenceDate,
            "phase": "complete",
            "segments": []
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(MeetingNote.self, from: data)
        XCTAssertEqual(decoded.captureMode, .call)
        XCTAssertFalse(decoded.isInPerson)
    }

    func testInPersonAudioWriterSkipsEchoSuppressionAndOutputsMicOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inperson-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = MeetingAudioWriter(
            directory: dir,
            startedAt: Date(),
            includeSystemAudio: false,
            segment: { _ in },
            failed: { msg, _ in XCTFail("Unexpected audio writer failure: \(msg)") }
        )
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buf.frameLength = 1600
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<1600 { ch[i] = sin(Float(i) * 0.1) * 0.15 }
        }
        writer.fixture(buf, source: .microphone, at: Date())
        let segments = try writer.finish()
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.source, .microphone)
        XCTAssertEqual(writer.debugSuppressedEchoFrames, 0)
    }

    func testMenusExposeStartInPersonMeetingAlongsideStartNewMeetingNote() {
        let statusTitles = StatusMenu.shared.designMenu().items.map(\.title)
        XCTAssertTrue(statusTitles.contains("Start In-Person Meeting"))
        XCTAssertTrue(statusTitles.contains("Start New Meeting Note"))

        let pillTitles = Overlay.shared.buildContextMenu().items.map(\.title)
        XCTAssertTrue(pillTitles.contains("Start In-Person Meeting"))
        XCTAssertTrue(pillTitles.contains("Start New Meeting Note"))
    }

    func testInPersonAutoResumeSurvivesRelaunchWithoutCalendarConsentAndStripsRoomPrefixFromTitle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inperson-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let store = MeetingStore(root: dir)
        let interrupted = MeetingNote(
            event: MeetingEvent.inPerson(now: now),
            startedAt: now,
            phase: .recording,
            captureMode: .inPerson
        )
        try store.save(interrupted)

        let defaults = UserDefaults(suiteName: ScratchDefaults.name("in-person-resume"))!
        let capture = InPersonMockCapture()
        let coordinator = MeetingCoordinator(
            calendar: InPersonMockCalendar(),
            capture: capture,
            transcriber: InPersonMockTranscriber(),
            summarizer: InPersonMockSummarizer(),
            store: store,
            defaults: defaults,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.consentConfirmed = false
        coordinator.load(now: now.addingTimeInterval(15))
        await coordinator.tick(now: now.addingTimeInterval(20))

        XCTAssertEqual(coordinator.activeID, interrupted.id)
        XCTAssertEqual(capture.startedModes, [.inPerson])

        let derived = LocalMeetingSummarizer.deriveTitle(
            summary: "",
            transcript: "[00:00] Room · microphone: Q3 renewal pricing and onboarding timeline."
        )
        XCTAssertEqual(derived, "Q3 renewal pricing and onboarding timeline")
        XCTAssertFalse(derived?.contains("Room") ?? true)
    }
}
