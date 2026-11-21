import Cocoa
import Foundation
import SwiftUI
import XCTest
@testable import FlowCloneCore

/// Opt-in, repeatable synthetic costs; these do not measure microphone or paste latency.
@MainActor
final class ReviewPerformanceTests: XCTestCase {
    func testSyntheticCosts() throws {
        guard ProcessInfo.processInfo.environment["FLOWCLONE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FLOWCLONE_BENCHMARK=1 for synthetic performance measurements")
        }
        let input = "Send Alice twenty-five dollars on Friday. Include the complete budget and ask Bob to review all thirty items before Monday."
        var start = DispatchTime.now()
        for _ in 0..<1_000 {
            XCTAssertNil(RewriteFidelity.reject(input, input: input, style: .polish))
        }
        print(String(format: "BENCHMARK fidelity_1000_ms=%.3f", ms(start, .now())))

        let source = OriginText(String(repeating: "um café 👩🏽‍💻 ", count: 2_000))
        let regex = try NSRegularExpression(pattern: "um ")
        start = .now()
        for _ in 0..<10 {
            let result = source.replacingMatches(of: regex, withTemplate: "")
            XCTAssertEqual(result.origins.count, result.text.count)
            XCTAssertFalse(result.text.contains("um "))
        }
        print(String(format: "BENCHMARK unicode_cleanup_10_ms=%.3f", ms(start, .now())))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousURL = History.storeURL
        let previousDefaults = History.defaults
        let suite = ScratchDefaults.name("benchmark")
        History.defaults = UserDefaults(suiteName: suite)!
        History.storeURL = root.appendingPathComponent("history.jsonl")
        defer {
            History.storeURL = previousURL
            History.defaults.removePersistentDomain(forName: suite)
            History.defaults = previousDefaults
            try? FileManager.default.removeItem(at: root)
        }
        let encoder = JSONEncoder()
        var data = Data()
        for i in 0..<History.cap {
            let item = History.Item(date: Date(timeIntervalSince1970: Double(i)), raw: input, final: input)
            data.append(try encoder.encode(item))
            data.append(0x0a)
        }
        try PrivateFile.write(data, to: History.storeURL)
        History.reload()
        XCTAssertEqual(History.items.count, History.cap)
        start = .now()
        for _ in 0..<100 { History.add(raw: input, final: input) }
        let queued = ms(start, .now())
        History.reload() // Also waits for pending writes after persistence moves off main.
        XCTAssertEqual(History.items.count, History.cap)
        print(String(format: "BENCHMARK history_enqueue_100_ms=%.3f history_total_100_ms=%.3f",
                     queued, ms(start, .now())))
    }

    func testMeetingsMenuCosts() async throws {
        guard ProcessInfo.processInfo.environment["FLOWCLONE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FLOWCLONE_BENCHMARK=1 for synthetic performance measurements")
        }
        @MainActor final class BenchCalendar: MeetingCalendarProviding {
            var entries: [MeetingEvent] = []
            func connect(_ source: MeetingCalendarSource) async throws {}
            var account: String? { "bench@example.com" }
            func calendars() async throws -> [MeetingCalendar] {
                [.init(id: "google", title: "Primary", account: "bench@example.com", primary: true),
                 .init(id: "team", title: "Team Syncs", account: "bench@example.com")]
            }
            func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
                entries
            }
        }
        @MainActor final class BenchCapture: MeetingCapturing {
            func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval],
                       segment: @escaping @Sendable (MeetingSegment) -> Void,
                       failed: @escaping @Sendable (String, Bool) -> Void) async throws {}
            func stop() async throws -> [MeetingSegment] { [] }
        }
        actor BenchTranscriber: MeetingTranscribing {
            func transcribe(url: URL) async throws -> String { "" }
        }
        struct BenchSummarizer: MeetingSummarizing {
            func summarize(_ note: MeetingNote) async -> MeetingSummary { .init(text: "", method: "Bench") }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let savedCoordinator = MeetingCoordinator.shared
        let suite = ScratchDefaults.name("meetings-bench")
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            MeetingCoordinator.shared = savedCoordinator
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date()
        let cal = BenchCalendar()
        cal.entries = (0..<25).map { (i: Int) -> MeetingEvent in
            let title = i.isMultiple(of: 2) ? "180DC project team meeting \(i)" : "Weekly roadmap review \(i)"
            let start = now.addingTimeInterval(Double(i + 1) * 3600)
            let end = start.addingTimeInterval(2700)
            let attendees: [String] = i.isMultiple(of: 3) ? ["Alex", "Maya"] : []
            let url: URL? = i.isMultiple(of: 2) ? URL(string: "https://meet.google.com/abc-defg-hij") : nil
            return MeetingEvent(id: "ev-\(i)", calendarID: "google", title: title, start: start, end: end,
                                attendees: attendees, joinURL: url)
        }

        let store = MeetingStore(root: root)
        let summaryLines = (0..<10).flatMap { sec in
            ["## Section \(sec + 1)",
             "- Agreed to launch phase \(sec + 1) by Friday with ten pilot accounts and clear rollback steps.",
             "- Maya will review the onboarding checklist and confirm payment webhook retry metrics before Thursday.",
             "- Open question: whether weekend support rotation starts this week or after the initial pilot cohort.",
             ""]
        }.joined(separator: "\n")

        func makeNote(index: Int, segmentCount: Int) -> MeetingNote {
            let ev = MeetingEvent(id: "past-\(index)", calendarID: "google", title: "Product Architecture Sync #\(index)",
                                  start: now.addingTimeInterval(-Double(index + 1) * 7200),
                                  end: now.addingTimeInterval(-Double(index + 1) * 7200 + 3600),
                                  attendees: ["Alex", "Maya"])
            let segments: [MeetingSegment] = (0..<segmentCount).map { s in
                let source: MeetingSource = s % 2 == 0 ? .system : .microphone
                let offset = Double(s / 2) * 14.0
                let text = s % 2 == 1 && s % 4 == 1
                    ? ""
                    : "We reviewed the latency numbers for segment \(s) and confirmed that scrolling and navigation need to feel instantaneous even on multi-hour transcripts with hundreds of segments."
                return MeetingSegment(audioFile: "\(source.rawValue)-\(Int(offset * 1000))-\(s).wav",
                                      source: source, offset: offset, duration: 14.0, text: text)
            }
            return MeetingNote(event: ev, startedAt: ev.start, endedAt: ev.end, phase: .complete,
                               segments: segments, personalNotes: "Initial personal notes for meeting \(index).",
                               summary: summaryLines, summaryMethod: "On-device AI summary · verify against the transcript")
        }

        let counts = [800, 400, 300, 80, 60, 50, 40, 40, 30, 30, 20, 20]
        for (i, c) in counts.enumerated() {
            try store.save(makeNote(index: i, segmentCount: c))
        }

        // 1. Measure store.load()
        var t0 = DispatchTime.now()
        let coordinator = MeetingCoordinator(calendar: cal, capture: BenchCapture(), transcriber: BenchTranscriber(),
                                             summarizer: BenchSummarizer(), store: store, defaults: defaults,
                                             trace: { _ in }, notify: { _ in })
        coordinator.selectedCalendars = ["google"]
        coordinator.consentConfirmed = true
        coordinator.autoStart = true
        coordinator.load(now: now)
        let loadMs = ms(t0, .now())
        await coordinator.refresh()
        MeetingCoordinator.shared = coordinator

        // 2. Measure Google event parsing (100 events)
        let rawItems: [[String: Any]] = (0..<100).map { i in
            ["id": "g-\(i)", "summary": "Team sync \(i)",
             "start": ["dateTime": "2026-11-13T15:00:00Z"],
             "end": ["dateTime": "2026-11-13T16:00:00Z"],
             "description": "Agenda notes and background context for the team sync meeting.\nJoin here: https://meet.google.com/abc-defg-hij or dial in.",
             "attendees": [["email": "alex@example.com"], ["email": "maya@example.com"]]]
        }
        t0 = .now()
        for item in rawItems { _ = GoogleMeetingCalendar.event(item, calendarID: "google") }
        let parse100Ms = ms(t0, .now())

        // Helper to pump main runloop & layout + draw + count AppKit subviews
        _ = NSApplication.shared
        func pumpAndRender(_ view: NSView) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
        }
        func countSubviews(_ view: NSView) -> (total: Int, classes: [String: Int]) {
            var total = 1
            var classes: [String: Int] = ["\(type(of: view))": 1]
            for sub in view.subviews {
                let c = countSubviews(sub)
                total += c.total
                for (k, v) in c.classes { classes[k, default: 0] += v }
            }
            return (total, classes)
        }

        let size = NSSize(width: 1120, height: 760)
        let model = MainModel(isOnScreen: { true })
        model.page = .dictation
        let host = NSHostingView(rootView: MainView(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        pumpAndRender(host)

        // 3. Enter MeetingsPage with selectedNoteID == nil
        coordinator.selectedNoteID = nil
        t0 = .now()
        model.page = .meetings
        pumpAndRender(host)
        let enterEmptyMs = ms(t0, .now())
        let emptyViews = countSubviews(host)

        // 4. Select 800-segment note (Summary tab)
        let longID = coordinator.notes[0].id
        t0 = .now()
        coordinator.selectedNoteID = longID
        pumpAndRender(host)
        let selectSummaryMs = ms(t0, .now())
        let summaryViews = countSubviews(host)

        // 5. Switch away to Dictation and back to Meetings while 800-segment note is selected
        t0 = .now()
        model.page = .dictation
        pumpAndRender(host)
        let leaveMeetingsMs = ms(t0, .now())

        t0 = .now()
        model.page = .meetings
        pumpAndRender(host)
        let reenterWithLongSelectedMs = ms(t0, .now())

        // 6. Type 10 keystrokes in personalNotes
        t0 = .now()
        for k in 0..<10 {
            coordinator.updateNotes(longID, text: "Updated personal notes \(k) during meeting.")
            host.layoutSubtreeIfNeeded()
        }
        let type10NotesMs = ms(t0, .now())

        // 7. Calendar refresh while MeetingsPage is open on 800-segment note
        t0 = .now()
        await coordinator.refresh()
        pumpAndRender(host)
        let refreshWhileOpenMs = ms(t0, .now())

        // 8. Mount/open Transcript tab on 800-segment note + switch to 400-segment note + refresh
        let transcriptHost = NSHostingView(rootView: MeetingsPage(meetings: coordinator, initialTab: "Transcript")
            .font(UIStyle.body).foregroundStyle(Theme.ink).tint(Theme.accent).themedButtons())
        window.contentView = transcriptHost
        transcriptHost.frame = NSRect(origin: .zero, size: size)
        t0 = .now()
        pumpAndRender(transcriptHost)
        let open800TranscriptMs = ms(t0, .now())
        let transcriptViews = countSubviews(transcriptHost)

        let secondID = coordinator.notes[1].id
        t0 = .now()
        coordinator.selectedNoteID = secondID
        pumpAndRender(transcriptHost)
        let switch400TranscriptMs = ms(t0, .now())

        coordinator.selectedNoteID = longID
        pumpAndRender(transcriptHost)
        t0 = .now()
        await coordinator.refresh()
        pumpAndRender(transcriptHost)
        let refreshWhileTranscriptMs = ms(t0, .now())

        t0 = .now()
        window.contentView = nil
        let teardownTranscriptMs = ms(t0, .now())
        let topEmpty = emptyViews.classes.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
        let topTranscript = transcriptViews.classes.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
        XCTAssertLessThan(emptyViews.total, 60)
        XCTAssertLessThan(summaryViews.total, 70)
        XCTAssertLessThan(transcriptViews.total, 70)
        print(String(format: """
            BENCHMARK_MEETINGS:
              load_12_notes_ms=%.2f
              parse_100_gcal_events_ms=%.2f
              enter_empty_ms=%.2f (subviews=%d [%@])
              select_800seg_summary_ms=%.2f (subviews=%d)
              leave_meetings_ms=%.2f
              reenter_long_selected_ms=%.2f
              type_10_keystrokes_notes_ms=%.2f
              refresh_while_summary_open_ms=%.2f
              open_800seg_transcript_ms=%.2f (subviews=%d [%@])
              switch_400seg_transcript_ms=%.2f
              refresh_while_transcript_open_ms=%.2f
              teardown_800seg_transcript_ms=%.2f
            """,
            loadMs, parse100Ms,
            enterEmptyMs, emptyViews.total, topEmpty,
            selectSummaryMs, summaryViews.total,
            leaveMeetingsMs, reenterWithLongSelectedMs,
            type10NotesMs, refreshWhileOpenMs,
            open800TranscriptMs, transcriptViews.total, topTranscript,
            switch400TranscriptMs, refreshWhileTranscriptMs, teardownTranscriptMs))
    }
}
