#if DEBUG
import AVFoundation
import Foundation

@MainActor private final class MockMeetingCalendar: MeetingCalendarProviding {
    let event: MeetingEvent?
    init(_ event: MeetingEvent? = nil) { self.event = event }
    func connect(_ source: MeetingCalendarSource) async throws {}
    var account: String? { event == nil ? nil : "fixture@example.com" }
    func calendars() async throws -> [MeetingCalendar] {
        guard let account else { throw GoogleCalendarSignInRequired.missing }
        return [.init(id: "mock-google", title: "Mock team calendar", account: account, primary: true)]
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        guard let event else { return [] }
        return calendarIDs.contains(event.calendarID) && event.end > from && event.start < to ? [event] : []
    }
}
@MainActor private final class MockMeetingCapture: MeetingCapturing {
    let files: [URL]
    private var writer: MeetingAudioWriter?
    init(files: [URL]) { self.files = files }
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (_ message: String, _ resumable: Bool) -> Void) async throws {
        let writer = MeetingAudioWriter(directory: directory, startedAt: startedAt, initialOffsets: initialOffsets, segment: segment, failed: failed)
        self.writer = writer
        var elapsed = 0.0
        for (index, url) in files.enumerated() {
            let file = try AVAudioFile(forReading: url)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw MeetingFailure("Fixture buffer unavailable") }
                try file.read(into: buffer)
                elapsed += Double(buffer.frameLength) / buffer.format.sampleRate
                writer.fixture(buffer, source: index % 2 == 0 ? .microphone : .system, at: startedAt.addingTimeInterval(elapsed))
            }
        }
    }
    func stop() async throws -> [MeetingSegment] { defer { writer = nil }; return try writer?.finish() ?? [] }
}

@MainActor enum MeetingMock {
    static var result = "Not started"

    static func showDisconnectedCalendar(in output: URL) {
        let coordinator = MeetingCoordinator(calendar: MockMeetingCalendar(), capture: MockMeetingCapture(files: []),
            transcriber: LocalMeetingTranscriber(), summarizer: LocalMeetingSummarizer(),
            store: MeetingStore(root: output), notify: { _ in })
        coordinator.selectedCalendars = ["mock-google"]
        coordinator.autoStart = true
        coordinator.consentConfirmed = true
        MeetingCoordinator.shared = coordinator
        Task { await coordinator.refresh() }
    }

    static func showGitHubDemo(in output: URL) throws {
        final class DemoGitHubPublisher: MeetingGitHubPublishing, @unchecked Sendable {
            private let lock = NSLock()
            private var token: String? = "demo-token-placeholder"

            func tokenLoadState() -> GitHubTokenLoadState {
                lock.withLock { token.map(GitHubTokenLoadState.found) ?? .missing }
            }
            func saveToken(_ rawToken: String) -> Bool {
                lock.withLock { token = rawToken; return true }
            }
            func clearToken() { lock.withLock { token = nil } }
            func verifyToken(_ token: String) async throws -> String { "demo-user" }
            func listRepositories() async throws -> [GitHubRepositorySummary] {
                [
                    GitHubRepositorySummary(owner: "acme", name: "meeting-notes", defaultBranch: "main", isPrivate: true, canPush: true),
                    GitHubRepositorySummary(owner: "acme", name: "product-wiki", defaultBranch: "main", isPrivate: false, canPush: true),
                ]
            }
            func verifyRepository(_ repo: GitHubRepoID) async throws -> GitHubRepositorySummary {
                GitHubRepositorySummary(owner: repo.owner, name: repo.name, defaultBranch: "main", isPrivate: true, canPush: true)
            }
            func publish(note: MeetingNote, config: GitHubPublishConfig) async throws -> MeetingGitHubPublishResult {
                let repo = config.parsedRepo ?? GitHubRepoID(owner: "acme", name: "meeting-notes")
                let path = MeetingGitHubDocument.candidatePaths(for: note, folder: config.folder).first ?? "meeting-notes/note.md"
                return MeetingGitHubPublishResult(
                    repository: repo.fullName,
                    branch: config.branch,
                    resolvedBranch: config.branch.isEmpty ? "main" : config.branch,
                    path: path,
                    sha: "demo-blob-sha",
                    commitSHA: "demo-commit-sha",
                    htmlURL: URL(string: "https://github.com/\(repo.fullName)/blob/main/\(path)"),
                    contentHash: MeetingGitHubDocument.contentHash(for: note, includeTranscript: config.includeTranscript),
                    publishedAt: Date()
                )
            }
        }

        let defaults = UserDefaults(suiteName: output.appendingPathComponent("github-demo-prefs").path)!
        let publisher = DemoGitHubPublisher()
        let coordinator = MeetingCoordinator(
            calendar: MockMeetingCalendar(),
            capture: MockMeetingCapture(files: []),
            transcriber: LocalMeetingTranscriber(),
            summarizer: LocalMeetingSummarizer(),
            store: MeetingStore(root: output.appendingPathComponent("Meetings")),
            defaults: defaults,
            githubPublisher: publisher,
            notify: { _ in }
        )
        coordinator.load()
        coordinator.githubConfig = GitHubPublishConfig(
            repository: "acme/meeting-notes",
            branch: "",
            folder: "meeting-notes",
            autoPublish: true,
            includeTranscript: true,
            defaultBranchCache: "main",
            connectedUsername: "demo-user"
        )
        coordinator.githubRepos = [
            GitHubRepositorySummary(owner: "acme", name: "meeting-notes", defaultBranch: "main", isPrivate: true, canPush: true),
            GitHubRepositorySummary(owner: "acme", name: "product-wiki", defaultBranch: "main", isPrivate: false, canPush: true),
        ]
        coordinator.githubConnected = true
        coordinator.githubStatus = "Verified acme/meeting-notes (main)."

        let now = Date()
        let event = MeetingEvent(
            id: "demo-github-meeting",
            calendarID: "mock-google",
            title: "Q4 Launch Sync",
            start: now.addingTimeInterval(-1800),
            end: now,
            attendees: ["Alex", "Maya"]
        )
        var note = MeetingNote(
            event: event,
            startedAt: event.start,
            endedAt: event.end,
            phase: .complete,
            segments: [
                MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 15,
                               text: "Let's finalize the rollout checklist and ship on Friday.")
            ],
            personalNotes: "Double-check onboarding guide before launch.",
            summary: "## Overview\nFinalized the Q4 rollout timeline.\n\n## Action Items\n- Maya to publish the launch checklist by Thursday.\n- Alex to review onboarding copy.",
            summaryMethod: "Claude Sonnet 5.5 · from your notes & transcript"
        )
        let path = MeetingGitHubDocument.candidatePaths(for: note, folder: "meeting-notes").first!
        note.githubPublish = MeetingGitHubState(
            status: .published,
            repository: "acme/meeting-notes",
            branch: "",
            resolvedBranch: "main",
            path: path,
            sha: "demo-blob-sha",
            commitSHA: "demo-commit-sha",
            htmlURL: URL(string: "https://github.com/acme/meeting-notes/blob/main/\(path)"),
            publishedAt: now,
            contentHash: MeetingGitHubDocument.contentHash(for: note, includeTranscript: true),
            error: nil
        )
        try coordinator.store.save(note)
        coordinator.notes = [note]
        coordinator.selectedNoteID = note.id
        MeetingCoordinator.shared = coordinator
    }

    static func start(files: [URL], output: URL) throws {
        guard handsfreeSession, !files.isEmpty, !MeetingCoordinator.shared.busy else { throw MeetingFailure("A mock needs a hidden test session and audio files.") }
        guard !result.hasPrefix("Running") else { throw MeetingFailure("Mock already running") }
        let now = Date()
        let event = MeetingEvent(id: UUID().uuidString, calendarID: "mock-google", title: "Pilot launch · mock meeting",
                                 start: now, end: now.addingTimeInterval(300), attendees: ["Alex", "Maya"])
        let defaults = UserDefaults(suiteName: output.appendingPathComponent("mock-preferences").path)!
        let coordinator = MeetingCoordinator(calendar: MockMeetingCalendar(event), capture: MockMeetingCapture(files: files),
            transcriber: LocalMeetingTranscriber(), summarizer: LocalMeetingSummarizer(),
            store: MeetingStore(root: output.appendingPathComponent("Meetings")), defaults: defaults)
        coordinator.load(); coordinator.selectedCalendars = ["mock-google"]; coordinator.autoStart = true; coordinator.consentConfirmed = true
        MeetingCoordinator.shared = coordinator
        result = "Running: calendar → automatic start → audio files → local ASR → summary"
        Task {
            await coordinator.tick(now: now.addingTimeInterval(-1))
            guard coordinator.activeID == nil else { result = "FAIL: started early"; return }
            await coordinator.tick(now: now)
            guard coordinator.countdown != nil else { result = "FAIL: no countdown"; return }
            await coordinator.tick(now: now.addingTimeInterval(10))
            guard let id = coordinator.activeID else { result = "FAIL: \(coordinator.error ?? "did not start")"; return }
            coordinator.updateNotes(id, text: "Mock meeting: keep these personal notes separate from the generated summary.")
            await coordinator.tick(now: event.end)
            await coordinator.settle()
            do {
                let saved = try coordinator.store.load()
                guard let note = saved.first, note.phase == .complete, !note.transcript.isEmpty, !note.summary.isEmpty,
                      Set(note.segments.map(\.source)) == [.microphone, .system] else {
                    result = "FAIL: incomplete saved meeting: \(coordinator.notes.first?.issue ?? coordinator.error ?? "missing output")"; return
                }
                try note.markdown.write(to: output.appendingPathComponent("mock-meeting.md"), atomically: true, encoding: .utf8)
                result = "PASS: \(note.segments.count) audio segments; automatic start/stop; saved transcript and summary. \(note.summaryMethod)"
            } catch { result = "FAIL: \(error.localizedDescription)" }
        }
    }
}
#endif
