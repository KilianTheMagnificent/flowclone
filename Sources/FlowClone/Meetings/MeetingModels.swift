import Foundation

struct MeetingEvent: Codable, Equatable, Identifiable, Sendable {
    static let defaultAdHocTitle = "New Meeting"
    static let defaultInPersonTitle = "In-Person Meeting"

    var id: String
    var calendarID: String
    var title: String
    var start: Date
    var end: Date
    var attendees: [String] = []
    var joinURL: URL? = nil
    var allDay = false
    var declined = false
    var cancelled = false

    var isAdHoc: Bool { id.hasPrefix("adhoc/") }
    var isInPerson: Bool { id.hasPrefix("adhoc/in-person/") }
    var isLiveDetected: Bool { id.hasPrefix("adhoc/live/") }
    var isImported: Bool { id.hasPrefix("import/") }
    var isEligible: Bool { !allDay && !declined && !cancelled && end > start }
    /// Recorded without asking: a call link, guests, or a title that says it is a meeting.
    var isAutomaticEligible: Bool { isEligible && (joinURL != nil || !attendees.isEmpty || Self.soundsLikeMeeting(title)) }
    /// For a meeting someone typed into their own calendar, with no call link and no guests.
    /// Classes (lectures, discussion sections, office hours, reviews), errands and focus blocks do
    /// not match; any event can still be switched on by hand.
    private static let meetingRegex = try! NSRegularExpression(
        pattern: #"\b(meeting|mtg|call|sync|stand-?up|1:1|1-1|1on1|one-on-one|interview|kick-?off|check-?in|catch-?up|huddle|zoom|google meet|meet with|webex|debrief|briefing|retro|all-hands|town ?hall|scrum|coffee chat|brainstorm|webinar)\b"#,
        options: [.caseInsensitive])
    static func soundsLikeMeeting(_ title: String) -> Bool {
        meetingRegex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    private static let genericAutoTitles: Set<String> = [
        defaultAdHocTitle.lowercased(),
        defaultInPersonTitle.lowercased(),
        "client meeting",
        "client conversation",
        "live meeting",
        "zoom call",
        "zoom meeting",
        "google meet",
        "microsoft teams",
        "microsoft teams call",
        "slack huddle",
        "facetime call",
        "webex meeting",
        "discord call",
        "tuple call",
        "around call",
        "around meeting",
        "pop call",
        "tandem call",
        "gather call",
        "gather meeting",
        "ringcentral call",
        "ringcentral meeting",
        "chime call",
        "amazon chime",
        "goto meeting",
        "bluejeans call",
        "bluejeans meeting",
        "whatsapp call",
        "skype call",
        "telegram call",
        "signal call",
        "viber call",
        "whereby call",
        "jitsi call",
        "riverside call",
        "daily call",
        "cal video call",
        "browser meeting",
        "browser call",
        "chrome call",
        "safari call",
        "arc call",
        "brave call",
        "edge call",
        "firefox call",
        "opera call",
        "vivaldi call",
        "zen call",
        "orion call",
        "dia call",
        "comet call",
        "atlas call",
        "sigmaos call",
    ]

    static func isGenericAutoTitle(_ title: String) -> Bool {
        genericAutoTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func adHoc(title: String = defaultAdHocTitle, now: Date = Date(),
                      duration: TimeInterval = 3 * 3600) -> MeetingEvent {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingEvent(
            id: "adhoc/\(UUID().uuidString)",
            calendarID: "",
            title: trimmed.isEmpty ? defaultAdHocTitle : trimmed,
            start: now,
            end: now.addingTimeInterval(duration)
        )
    }

    static func inPerson(title: String = defaultInPersonTitle, now: Date = Date(),
                         duration: TimeInterval = 3 * 3600) -> MeetingEvent {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingEvent(
            id: "adhoc/in-person/\(UUID().uuidString)",
            calendarID: "",
            title: trimmed.isEmpty ? defaultInPersonTitle : trimmed,
            start: now,
            end: now.addingTimeInterval(duration)
        )
    }

    static func liveDetected(title: String, now: Date = Date(),
                             duration: TimeInterval = 3 * 3600) -> MeetingEvent {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingEvent(
            id: "adhoc/live/\(UUID().uuidString)",
            calendarID: "",
            title: trimmed.isEmpty ? "Live Meeting" : trimmed,
            start: now,
            end: now.addingTimeInterval(duration)
        )
    }

    static func imported(title: String, now: Date = Date(),
                         duration: TimeInterval = 60) -> MeetingEvent {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingEvent(
            id: "import/\(UUID().uuidString)",
            calendarID: "",
            title: trimmed.isEmpty ? "Imported Recording" : trimmed,
            start: now,
            end: now.addingTimeInterval(max(1, duration))
        )
    }
}

enum MeetingSource: String, Codable, Sendable { case microphone, system }
enum MeetingCaptureMode: String, Codable, Sendable { case call, inPerson = "in-person" }
enum MeetingPhase: String, Codable, Sendable { case recording, processing, complete, interrupted, failed }

struct MeetingSegment: Codable, Equatable, Identifiable, Sendable {
    var id: String { audioFile }
    var audioFile: String
    var source: MeetingSource
    var offset: TimeInterval
    var duration: TimeInterval
    var text: String? = nil
    var error: String? = nil
    var label: String { source == .microphone ? "You · microphone" : "Others · system audio" }
}

typealias MeetingRecord = MeetingNote

struct MeetingNote: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var event: MeetingEvent
    var startedAt: Date
    var endedAt: Date? = nil
    var phase: MeetingPhase = .recording
    var segments: [MeetingSegment] = []
    var personalNotes = ""
    var summary = ""
    var summaryMethod = ""
    var issue: String? = nil
    /// Capture ended for a reason other than the person's choice or the meeting's end (sleep, a
    /// microphone change, a relaunch, a failed start). It continues by itself while the meeting runs.
    var autoResume: Bool? = nil
    /// Checked action-item strings persisted backwards-compatibly in note.json.
    var completedActionItems: Set<String> = []
    /// Tracks whether the user manually edited the meeting title so auto-titling never overwrites it.
    var userRenamedTitle = false
    /// Whether this meeting records call audio (mic + system) or an in-person room conversation (mic only).
    var captureMode: MeetingCaptureMode = .call

    var isInPerson: Bool { captureMode == .inPerson || event.isInPerson }

    init(
        id: UUID = UUID(),
        event: MeetingEvent,
        startedAt: Date,
        endedAt: Date? = nil,
        phase: MeetingPhase = .recording,
        segments: [MeetingSegment] = [],
        personalNotes: String = "",
        summary: String = "",
        summaryMethod: String = "",
        issue: String? = nil,
        autoResume: Bool? = nil,
        completedActionItems: Set<String> = [],
        userRenamedTitle: Bool = false,
        captureMode: MeetingCaptureMode? = nil
    ) {
        self.id = id
        self.event = event
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.phase = phase
        self.segments = segments
        self.personalNotes = personalNotes
        self.summary = summary
        self.summaryMethod = summaryMethod
        self.issue = issue
        self.autoResume = autoResume
        self.completedActionItems = completedActionItems
        self.userRenamedTitle = userRenamedTitle
        self.captureMode = captureMode ?? (event.isInPerson ? .inPerson : .call)
    }

    private enum CodingKeys: String, CodingKey {
        case id, event, startedAt, endedAt, phase, segments
        case personalNotes, summary, summaryMethod, issue, autoResume
        case completedActionItems, userRenamedTitle, captureMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        event = try c.decode(MeetingEvent.self, forKey: .event)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        phase = try c.decode(MeetingPhase.self, forKey: .phase)
        segments = try c.decodeIfPresent([MeetingSegment].self, forKey: .segments) ?? []
        personalNotes = try c.decodeIfPresent(String.self, forKey: .personalNotes) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summaryMethod = try c.decodeIfPresent(String.self, forKey: .summaryMethod) ?? ""
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        autoResume = try c.decodeIfPresent(Bool.self, forKey: .autoResume)
        completedActionItems = try c.decodeIfPresent(Set<String>.self, forKey: .completedActionItems) ?? []
        userRenamedTitle = try c.decodeIfPresent(Bool.self, forKey: .userRenamedTitle) ?? false
        captureMode = try c.decodeIfPresent(MeetingCaptureMode.self, forKey: .captureMode)
            ?? (event.isInPerson ? .inPerson : .call)
    }

    var orderedSegments: [MeetingSegment] {
        var previous = -Double.infinity
        for segment in segments {
            if segment.offset < previous { return segments.sorted { $0.offset < $1.offset } }
            previous = segment.offset
        }
        return segments
    }
    /// Spoken, pending, and errored segments in chronological order, collapsing silent chunks unless
    /// the entire recording is silent.
    var displaySegments: [MeetingSegment] {
        let ordered = orderedSegments
        let active = ordered.filter { $0.text != "" }
        return active.isEmpty ? Array(ordered.prefix(1)) : active
    }
    func segmentLabel(for segment: MeetingSegment) -> String {
        if isInPerson, segment.source == .microphone {
            return "Room · microphone"
        }
        return segment.label
    }
    var transcript: String {
        orderedSegments.compactMap { segment in
            guard let text = segment.text, !text.isEmpty else { return nil }
            return "[\(Self.timestamp(segment.offset))] \(segmentLabel(for: segment)): \(text)"
        }.joined(separator: "\n\n")
    }
    var actionItems: [String] {
        MeetingActionItems.extract(from: summary)
    }
    var markdown: String {
        let renderedSummary = summary.isEmpty
            ? "Summary not generated yet."
            : MeetingActionItems.applyingCheckboxes(to: summary, completed: completedActionItems)
        return "# \(event.title)\n\n\(startedAt.formatted())\n\n## Summary\n\n\(renderedSummary)\n\n\(summaryMethod)\n\n"
            + (issue.map { "Capture / processing notice: \($0)\n\n" } ?? "")
            + "## My notes\n\n\(personalNotes)\n\n## Transcript\n\n\(transcript)\n"
    }
    static func timestamp(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum MeetingActionItems {
    static func extract(from summary: String) -> [String] {
        var items: [String] = []
        var seen = Set<String>()
        var inActionSection = false

        for rawLine in summary.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let heading = headingTitle(from: trimmed) {
                let lower = heading.lowercased()
                inActionSection = lower.contains("action item") || lower == "actions" || lower == "next steps" || lower == "tasks"
                continue
            }
            if let explicitTask = taskBulletText(from: trimmed, requireCheckbox: true) {
                if seen.insert(explicitTask).inserted { items.append(explicitTask) }
                continue
            }
            if inActionSection, let bullet = taskBulletText(from: trimmed, requireCheckbox: false) {
                let lower = bullet.lowercased()
                if lower != "none" && lower != "none stated" && lower != "none stated." && lower != "n/a" {
                    if seen.insert(bullet).inserted { items.append(bullet) }
                }
            }
        }
        return items
    }

    static func applyingCheckboxes(to summary: String, completed: Set<String>) -> String {
        let actionable = Set(extract(from: summary))
        guard !actionable.isEmpty else { return summary }
        return summary.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let text = taskBulletText(from: trimmed, requireCheckbox: false), actionable.contains(text) {
                return "- [\(completed.contains(text) ? "x" : " ")] \(text)"
            }
            return String(rawLine)
        }.joined(separator: "\n")
    }

    private static func headingTitle(from line: String) -> String? {
        if line.hasPrefix("#") {
            let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return stripped.isEmpty ? nil : stripped
        }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            let stripped = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }

    private static func taskBulletText(from line: String, requireCheckbox: Bool) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        let afterBullet = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if afterBullet.hasPrefix("[ ] ") || afterBullet.hasPrefix("[x] ") || afterBullet.hasPrefix("[X] ") {
            let clean = String(afterBullet.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            return clean.isEmpty ? nil : clean
        }
        if requireCheckbox { return nil }
        return afterBullet.isEmpty ? nil : afterBullet
    }
}

struct MeetingCalendar: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var account: String
    var primary = false
}

struct MeetingFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Google sign-in in the browser (default), or calendars already in macOS Calendar.
enum MeetingCalendarSource: String, Sendable { case google, mac }

/// What the coordinator talks to: one active source at a time.
@MainActor protocol MeetingCalendarProviding: AnyObject {
    var source: MeetingCalendarSource { get }
    /// The signed-in Google address; nil for macOS Calendar.
    var account: String? { get }
    func connect(_ source: MeetingCalendarSource) async throws
    func disconnect() async
    func calendars() async throws -> [MeetingCalendar]
    func calendars(forceRefresh: Bool) async throws -> [MeetingCalendar]
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent]
}
extension MeetingCalendarProviding {
    var source: MeetingCalendarSource { .google }
    var account: String? { nil }
    func disconnect() async {}
    func calendars(forceRefresh: Bool) async throws -> [MeetingCalendar] {
        try await calendars()
    }
}
/// One calendar service (Google Calendar API or EventKit).
@MainActor protocol MeetingCalendarBackend: AnyObject {
    func connect() async throws
    func calendars() async throws -> [MeetingCalendar]
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent]
}
@MainActor protocol MeetingCapturing: AnyObject {
    /// Whether macOS lets FlowClone record system audio (Core Audio Tap or Screen & System Audio Recording).
    var systemAudioAllowed: Bool { get }
    /// Asks macOS; it shows its own alert pointing to System Settings (once per app).
    func requestSystemAudio()
    /// Recording through a microphone known to be silent (the built-in one with the lid closed)
    /// while a working one has appeared since.
    var microphoneShouldChange: Bool { get }
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval],
               captureMode: MeetingCaptureMode,
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws
    func stop() async throws -> [MeetingSegment]
}
extension MeetingCapturing {
    var systemAudioAllowed: Bool { true }
    func requestSystemAudio() {}
    var microphoneShouldChange: Bool { false }
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval],
               captureMode: MeetingCaptureMode,
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        try await start(directory: directory, startedAt: startedAt, initialOffsets: initialOffsets, segment: segment, failed: failed)
    }
    func start(directory: URL, startedAt: Date,
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        try await start(directory: directory, startedAt: startedAt, initialOffsets: [:], captureMode: .call, segment: segment, failed: failed)
    }
}

struct MeetingImportedChunk: Equatable, Sendable {
    var offset: TimeInterval
    var duration: TimeInterval
    var text: String
}

protocol MeetingTranscribing: Sendable {
    func transcribe(url: URL) async throws -> String
    func transcribeAudioFile(
        at url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [MeetingImportedChunk]
    func transcribeSamples(
        _ samples: [Float],
        sourceURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [MeetingImportedChunk]
}
extension MeetingTranscribing {
    func transcribeAudioFile(at url: URL) async throws -> [MeetingImportedChunk] {
        try await transcribeAudioFile(at: url, progress: nil)
    }

    func transcribeAudioFile(
        at url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [MeetingImportedChunk] {
        let text = try await transcribe(url: url)
        progress?(1.0)
        return text.isEmpty ? [] : [MeetingImportedChunk(offset: 0, duration: 0, text: text)]
    }

    func transcribeSamples(
        _ samples: [Float],
        sourceURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [MeetingImportedChunk] {
        try await transcribeAudioFile(at: sourceURL, progress: progress)
    }
}

struct MeetingSummaryInput: Equatable, Sendable {
    var title: String
    var personalNotes: String
    var transcript: String
    var attendees: [String]
    var startedAt: Date?
    var durationSeconds: TimeInterval?
    var isInPerson: Bool

    init(
        title: String = "",
        personalNotes: String,
        transcript: String,
        attendees: [String] = [],
        startedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        isInPerson: Bool = false
    ) {
        self.title = title
        self.personalNotes = personalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attendees = attendees
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.isInPerson = isInPerson
    }

    init(note: MeetingNote) {
        let duration: TimeInterval? = {
            if let endedAt = note.endedAt {
                return max(0, endedAt.timeIntervalSince(note.startedAt))
            }
            if let lastEnd = note.segments.map({ $0.offset + $0.duration }).max(), lastEnd > 0 {
                return lastEnd
            }
            return nil
        }()
        self.init(
            title: note.event.title,
            personalNotes: note.personalNotes,
            transcript: note.transcript,
            attendees: note.event.attendees,
            startedAt: note.startedAt,
            durationSeconds: duration,
            isInPerson: note.isInPerson
        )
    }

    var isEmpty: Bool { personalNotes.isEmpty && transcript.isEmpty }
}

struct MeetingSummary: Sendable { var text: String; var method: String }
protocol MeetingSummarizing: Sendable {
    func summarize(_ note: MeetingNote) async -> MeetingSummary
}
