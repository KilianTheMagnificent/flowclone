import Cocoa
import SwiftUI
import XCTest
@testable import FlowCloneCore

private final class SyncBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ next: Value) { lock.withLock { value = next } }
    func modify<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

private final class InMemoryGitHubTokenStore: GitHubTokenStoring, @unchecked Sendable {
    private let stateBox: SyncBox<GitHubTokenLoadState>

    init(initialState: GitHubTokenLoadState = .missing) {
        self.stateBox = SyncBox(initialState)
    }

    func setState(_ state: GitHubTokenLoadState) { stateBox.set(state) }

    func load() -> String? {
        if case .found(let token) = stateBox.get() { return token }
        return nil
    }

    func loadState() -> GitHubTokenLoadState { stateBox.get() }

    func save(_ token: String) -> Bool {
        guard let normalized = GitHubTokenValidator.normalized(token) else { return false }
        stateBox.set(.found(normalized))
        return true
    }

    func clear() {
        stateBox.set(.missing)
    }
}

private final class StubGitHubHTTP: GitHubHTTP, @unchecked Sendable {
    private let handlerBox: SyncBox<@Sendable (URLRequest) throws -> (Int, Any)>
    private let requestsBox = SyncBox<[URLRequest]>([])

    init(handler: @escaping @Sendable (URLRequest) throws -> (Int, Any)) {
        self.handlerBox = SyncBox(handler)
    }

    func setHandler(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Any)) {
        handlerBox.set(handler)
    }

    var requests: [URLRequest] { requestsBox.get() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestsBox.modify { $0.append(request) }
        let (status, body) = try handlerBox.get()(request)
        let data: Data
        if let raw = body as? Data {
            data = raw
        } else {
            data = try JSONSerialization.data(withJSONObject: body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@MainActor private final class GitHubTestCalendar: MeetingCalendarProviding {
    var source: MeetingCalendarSource = .google
    var account: String? = "alex@example.com"
    func connect(_ source: MeetingCalendarSource) async throws {}
    func calendars() async throws -> [MeetingCalendar] {
        [.init(id: "primary", title: "Work", account: account ?? "Google", primary: true)]
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] { [] }
}

@MainActor private final class GitHubTestCapture: MeetingCapturing {
    var segments: [MeetingSegment] = []
    func start(directory: URL, startedAt: Date, initialOffsets: [MeetingSource: TimeInterval] = [:],
               segment: @escaping @Sendable (MeetingSegment) -> Void,
               failed: @escaping @Sendable (String, Bool) -> Void) async throws {}
    func stop() async throws -> [MeetingSegment] { segments }
}

private actor GitHubTestTranscriber: MeetingTranscribing {
    var shouldFail = false
    var text = "We agreed to ship the Q4 launch checklist on Friday."
    func setShouldFail(_ value: Bool) { shouldFail = value }
    func transcribe(url: URL) async throws -> String {
        if shouldFail { throw MeetingFailure("ASR failed") }
        return text
    }
}

private actor GitHubTestSummarizer: MeetingSummarizing {
    var version = 0
    func summarize(_ note: MeetingNote) async -> MeetingSummary {
        version += 1
        return MeetingSummary(
            text: "## Overview\nSummary revision \(version) for \(note.event.title).\n\n## Action Items\n- Maya to finalize launch checklist.",
            method: "Test summarizer"
        )
    }
}

@MainActor
final class MeetingGitHubPublishTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_795_528_800) // 2026-11-24T14:00:00Z
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let sampleToken = "unit-test-token-alpha-12345"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-github-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeDefaults() -> UserDefaults {
        let suite = ScratchDefaults.name("github")
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeSampleNote(
        id: UUID = UUID(),
        title: String = "Q4 Launch Sync",
        summary: String = "## Overview\nReviewed rollout.\n\n## Action Items\n- Maya to publish checklist.\n- Alex to test alerts.",
        personalNotes: String = "Confirm pricing table.",
        transcript: String = "[00:05] You · microphone: Let's ship on Friday.",
        completedActionItems: Set<String> = [],
        githubPublish: MeetingGitHubState? = nil
    ) -> MeetingNote {
        let event = MeetingEvent(
            id: "event-\(id.uuidString)",
            calendarID: "primary",
            title: title,
            start: fixedDate,
            end: fixedDate.addingTimeInterval(1800),
            attendees: ["Alex", "Maya"]
        )
        return MeetingNote(
            id: id,
            event: event,
            startedAt: fixedDate,
            endedAt: fixedDate.addingTimeInterval(1800),
            phase: .complete,
            segments: [
                MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 5, duration: 10, text: "Let's ship on Friday.")
            ],
            personalNotes: personalNotes,
            summary: summary,
            summaryMethod: "Claude Sonnet 5.5 · from your notes & transcript",
            completedActionItems: completedActionItems,
            githubPublish: githubPublish
        )
    }

    // MARK: - Repo, Folder, Branch & Token Validation

    func testRepoIDParsingSupportsShorthandHTTPSAndSSHAndRejectsUnsafeInputs() {
        XCTAssertEqual(GitHubRepoID.parse("acme/meeting-notes"), GitHubRepoID(owner: "acme", name: "meeting-notes"))
        XCTAssertEqual(GitHubRepoID.parse("  acme/notes.wiki  "), GitHubRepoID(owner: "acme", name: "notes.wiki"))
        XCTAssertEqual(GitHubRepoID.parse("https://github.com/acme/meeting-notes"), GitHubRepoID(owner: "acme", name: "meeting-notes"))
        XCTAssertEqual(GitHubRepoID.parse("https://github.com/acme/meeting-notes/"), GitHubRepoID(owner: "acme", name: "meeting-notes"))
        XCTAssertEqual(GitHubRepoID.parse("https://github.com/acme/meeting-notes.git"), GitHubRepoID(owner: "acme", name: "meeting-notes"))
        XCTAssertEqual(GitHubRepoID.parse("https://github.com/acme/meeting-notes/tree/main/notes"), GitHubRepoID(owner: "acme", name: "meeting-notes"))
        XCTAssertEqual(GitHubRepoID.parse("github.com/acme/meeting-notes"), GitHubRepoID(owner: "acme", name: "meeting-notes"))
        let sshRemote = ["git", "github.com:acme/meeting-notes.git"].joined(separator: "@")
        XCTAssertEqual(GitHubRepoID.parse(sshRemote), GitHubRepoID(owner: "acme", name: "meeting-notes"))

        XCTAssertNil(GitHubRepoID.parse(""))
        XCTAssertNil(GitHubRepoID.parse("acme"))
        XCTAssertNil(GitHubRepoID.parse("acme/"))
        XCTAssertNil(GitHubRepoID.parse("/notes"))
        XCTAssertNil(GitHubRepoID.parse("../secret"))
        XCTAssertNil(GitHubRepoID.parse("acme/.."))
        XCTAssertNil(GitHubRepoID.parse("-bad/notes"))
        XCTAssertNil(GitHubRepoID.parse("bad-/notes"))
        XCTAssertNil(GitHubRepoID.parse("https://evil.example.com/acme/notes"))
        XCTAssertNil(GitHubRepoID.parse("https://github.com/acme/notes?token=1"))
        XCTAssertNil(GitHubRepoID.parse("acme/notes/extra"))
        XCTAssertNil(GitHubRepoID.parse("acme/notes with space"))
    }

    func testFolderAndBranchValidationRejectsTraversalAndInvalidGitRefs() {
        XCTAssertEqual(GitHubPublishConfig.validatedFolder(""), "")
        XCTAssertEqual(GitHubPublishConfig.validatedFolder("   /  "), "")
        XCTAssertEqual(GitHubPublishConfig.validatedFolder("/meeting-notes/"), "meeting-notes")
        XCTAssertEqual(GitHubPublishConfig.validatedFolder("docs//meetings/2026/"), "docs/meetings/2026")
        XCTAssertNil(GitHubPublishConfig.validatedFolder("../outside"))
        XCTAssertNil(GitHubPublishConfig.validatedFolder("notes/../secret"))
        XCTAssertNil(GitHubPublishConfig.validatedFolder("notes\\sub"))
        XCTAssertNil(GitHubPublishConfig.validatedFolder("notes?x=1"))

        XCTAssertEqual(GitHubPublishConfig.validatedBranch(""), "")
        XCTAssertEqual(GitHubPublishConfig.validatedBranch("  main  "), "main")
        XCTAssertEqual(GitHubPublishConfig.validatedBranch("notes/weekly"), "notes/weekly")
        XCTAssertNil(GitHubPublishConfig.validatedBranch("bad..branch"))
        XCTAssertNil(GitHubPublishConfig.validatedBranch("/leading"))
        XCTAssertNil(GitHubPublishConfig.validatedBranch("trailing/"))
        XCTAssertNil(GitHubPublishConfig.validatedBranch("has space"))
        XCTAssertNil(GitHubPublishConfig.validatedBranch("branch.lock"))
        XCTAssertNil(GitHubPublishConfig.validatedBranch("bad@{1}"))
    }

    func testTokenValidatorTrimsQuotesAndRejectsControlCharacters() {
        XCTAssertEqual(GitHubTokenValidator.normalized("  \"\(sampleToken)\"\n"), sampleToken)
        XCTAssertNil(GitHubTokenValidator.normalized("short"))
        XCTAssertNil(GitHubTokenValidator.normalized("token with spaces inside"))
        XCTAssertNil(GitHubTokenValidator.normalized("token\nwith-newline"))
    }

    // MARK: - Markdown Formatting & Path Generation

    func testDocumentFormattingIncludesYAMLFrontmatterCheckboxesAndOptionalTranscript() {
        let note = makeSampleNote(
            title: "Q4 \"Launch\": Sync & Review",
            completedActionItems: ["Maya to publish checklist."]
        )

        let withTranscript = MeetingGitHubDocument.markdown(for: note, includeTranscript: true, timeZone: utc)
        XCTAssertTrue(withTranscript.hasPrefix("---\n"))
        XCTAssertTrue(withTranscript.contains("title: \"Q4 \\\"Launch\\\": Sync & Review\""))
        XCTAssertTrue(withTranscript.contains("type: \"call\""))
        XCTAssertTrue(withTranscript.contains("  - \"Alex\""))
        XCTAssertTrue(withTranscript.contains("- [x] Maya to publish checklist."))
        XCTAssertTrue(withTranscript.contains("- [ ] Alex to test alerts."))
        XCTAssertTrue(withTranscript.contains("## My notes\n\nConfirm pricing table."))
        XCTAssertTrue(withTranscript.contains("## Transcript\n\n[00:05] You · microphone: Let's ship on Friday."))

        let withoutTranscript = MeetingGitHubDocument.markdown(for: note, includeTranscript: false, timeZone: utc)
        XCTAssertFalse(withoutTranscript.contains("## Transcript"))
        XCTAssertTrue(withoutTranscript.contains("## Summary"))
        XCTAssertTrue(withoutTranscript.contains("## My notes"))
        XCTAssertNotEqual(
            MeetingGitHubDocument.contentHash(for: withTranscript),
            MeetingGitHubDocument.contentHash(for: withoutTranscript)
        )
    }

    func testCandidatePathsBuildSlugAndDisambiguationFallbacks() {
        let id = UUID(uuidString: "12345678-1111-2222-3333-444444444444")!
        let note = makeSampleNote(id: id, title: "Café / Q4 Planning!!")
        let paths = MeetingGitHubDocument.candidatePaths(for: note, folder: "team/notes", timeZone: utc)
        XCTAssertEqual(paths, [
            "team/notes/2026-11-24-cafe-q4-planning.md",
            "team/notes/2026-11-24-cafe-q4-planning-1400.md",
            "team/notes/2026-11-24-cafe-q4-planning-1400-12345678.md",
        ])

        let rootPaths = MeetingGitHubDocument.candidatePaths(for: makeSampleNote(title: "!!!"), folder: "", timeZone: utc)
        XCTAssertEqual(rootPaths.first, "2026-11-24-meeting.md")
    }

    // MARK: - GitHub API Client

    func testPublisherCreatesFileOnEmptyRepoHandlesCollisionAndUpdatesWithConflictRetry() async throws {
        let store = InMemoryGitHubTokenStore(initialState: .found(sampleToken))
        let remoteFiles = SyncBox<[String: (sha: String, content: String)]>([:])
        let injectConflictOnce = SyncBox(false)

        let expectedToken = sampleToken
        let clockDate = fixedDate
        let http = StubGitHubHTTP { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
            let pathPrefix = "/repos/acme/meeting-notes/contents/"
            let rawPath = request.url!.path
            XCTAssertTrue(rawPath.hasPrefix(pathPrefix))
            let filePath = String(rawPath.dropFirst(pathPrefix.count))

            if request.httpMethod == "GET" {
                if let existing = remoteFiles.get()[filePath] {
                    return (200, ["sha": existing.sha, "path": filePath])
                }
                return (404, ["message": "Not Found"])
            }
            if request.httpMethod == "PUT" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
                if injectConflictOnce.get() {
                    injectConflictOnce.set(false)
                    // Simulate an external edit on GitHub changing the blob SHA.
                    remoteFiles.modify { $0[filePath] = (sha: "sha-external-edit", content: "external") }
                    return (409, ["message": "does not match"])
                }
                let sentSHA = body["sha"] as? String
                if let existing = remoteFiles.get()[filePath], existing.sha != sentSHA {
                    return (409, ["message": "sha mismatch"])
                }
                let base64 = try XCTUnwrap(body["content"] as? String)
                let decoded = String(data: try XCTUnwrap(Data(base64Encoded: base64)), encoding: .utf8)!
                let nextSHA = "sha-\(remoteFiles.get().count + 1)-\(decoded.count)"
                remoteFiles.modify { $0[filePath] = (sha: nextSHA, content: decoded) }
                return (sentSHA == nil ? 201 : 200, [
                    "content": [
                        "path": filePath,
                        "sha": nextSHA,
                        "html_url": "https://github.com/acme/meeting-notes/blob/main/\(filePath)",
                    ],
                    "commit": ["sha": "commit-\(nextSHA)"],
                ])
            }
            return (404, ["message": "Unexpected"])
        }

        let publisher = GitHubMeetingPublisher(http: http, tokenStore: store, clock: { clockDate }, timeZone: utc)
        let config = GitHubPublishConfig(
            repository: "acme/meeting-notes",
            branch: "",
            folder: "meeting-notes",
            autoPublish: true,
            includeTranscript: true,
            defaultBranchCache: "main"
        )

        // 1. First note creates 2026-11-24-q4-launch-sync.md (with no `branch` field so empty repos work).
        var firstNote = makeSampleNote(title: "Q4 Launch Sync")
        let firstResult = try await publisher.publish(note: firstNote, config: config)
        XCTAssertEqual(firstResult.path, "meeting-notes/2026-11-24-q4-launch-sync.md")
        XCTAssertEqual(firstResult.htmlURL?.absoluteString, "https://github.com/acme/meeting-notes/blob/main/meeting-notes/2026-11-24-q4-launch-sync.md")
        let firstPut = try XCTUnwrap(http.requests.first { $0.httpMethod == "PUT" })
        let firstPutBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(firstPut.httpBody)) as? [String: Any])
        XCTAssertNil(firstPutBody["branch"], "Default branch should be omitted on PUT so empty repos initialize cleanly")
        XCTAssertNil(firstPutBody["sha"])

        // 2. A second, distinct note with the same title on the same day must NOT overwrite the first file.
        let secondNote = makeSampleNote(title: "Q4 Launch Sync")
        let secondResult = try await publisher.publish(note: secondNote, config: config)
        XCTAssertEqual(secondResult.path, "meeting-notes/2026-11-24-q4-launch-sync-1400.md")
        XCTAssertEqual(remoteFiles.get().count, 2)

        // 3. Updating the first note reuses its path and recovers automatically from a 409 SHA conflict.
        firstNote.githubPublish = MeetingGitHubState(
            status: .published,
            repository: firstResult.repository,
            branch: firstResult.branch,
            resolvedBranch: firstResult.resolvedBranch,
            path: firstResult.path,
            sha: firstResult.sha,
            commitSHA: firstResult.commitSHA,
            htmlURL: firstResult.htmlURL,
            publishedAt: firstResult.publishedAt,
            contentHash: firstResult.contentHash,
            error: nil
        )
        firstNote.personalNotes = "Updated note text after conflict."
        injectConflictOnce.set(true)

        let updatedResult = try await publisher.publish(note: firstNote, config: config)
        XCTAssertEqual(updatedResult.path, firstResult.path)
        XCTAssertTrue(remoteFiles.get()[firstResult.path]?.content.contains("Updated note text after conflict.") == true)
    }

    func testPublisherFiltersPushableReposAndClassifiesErrors() async throws {
        let store = InMemoryGitHubTokenStore(initialState: .found(sampleToken))
        let http = StubGitHubHTTP { request in
            switch request.url?.path {
            case "/user":
                return (200, ["login": "octocat"])
            case "/user/repos":
                return (200, [
                    ["name": "notes", "owner": ["login": "acme"], "default_branch": "main", "private": true, "permissions": ["push": true]],
                    ["name": "readonly", "owner": ["login": "acme"], "default_branch": "main", "private": false, "permissions": ["push": false]],
                ])
            case "/repos/acme/readonly":
                return (200, ["name": "readonly", "owner": ["login": "acme"], "default_branch": "main", "private": false, "permissions": ["push": false]])
            case "/repos/acme/missing":
                return (404, ["message": "Not Found"])
            default:
                return (503, ["message": "Service Unavailable"])
            }
        }
        let clockDate = fixedDate
        let publisher = GitHubMeetingPublisher(http: http, tokenStore: store, clock: { clockDate }, timeZone: utc)

        let username = try await publisher.verifyToken(sampleToken)
        XCTAssertEqual(username, "octocat")

        let repos = try await publisher.listRepositories()
        XCTAssertEqual(repos.map(\.fullName), ["acme/notes"])

        do {
            _ = try await publisher.verifyRepository(GitHubRepoID(owner: "acme", name: "readonly"))
            XCTFail("Expected read-only repo to fail verification")
        } catch let failure as GitHubPublishFailure {
            XCTAssertFalse(failure.isTransient)
            XCTAssertEqual(failure.statusCode, 403)
        }

        do {
            _ = try await publisher.verifyRepository(GitHubRepoID(owner: "acme", name: "missing"))
            XCTFail("Expected 404 repo to fail verification")
        } catch let failure as GitHubPublishFailure {
            XCTAssertFalse(failure.isTransient)
            XCTAssertEqual(failure.statusCode, 404)
        }

        do {
            _ = try await publisher.verifyRepository(GitHubRepoID(owner: "acme", name: "outage"))
            XCTFail("Expected 503 outage to fail verification")
        } catch let failure as GitHubPublishFailure {
            XCTAssertTrue(failure.isTransient)
            XCTAssertEqual(failure.statusCode, 503)
        }

        // Untrusted URLs are rejected.
        XCTAssertNil(GitHubMeetingPublisher.validatedGitHubWebURL("javascript:alert(1)"))
        XCTAssertNil(GitHubMeetingPublisher.validatedGitHubWebURL("https://evil.example.com/acme/notes"))
        XCTAssertNotNil(GitHubMeetingPublisher.validatedGitHubWebURL("https://github.com/acme/notes/blob/main/a.md"))
        XCTAssertEqual(GitHubMeetingPublisher.encodedContentsPath("team notes/2026 file.md"), "team%20notes/2026%20file.md")
    }

    // MARK: - MeetingCoordinator End-to-End Automatic Publishing

    func testCoordinatorAutomaticallyPublishesFinishedMeetingAndUpdatesOnResummarizeAndEdits() async throws {
        let dir = try makeTempDir()
        let defaults = makeDefaults()
        let store = InMemoryGitHubTokenStore(initialState: .missing)
        let uploadedPaths = SyncBox<[(path: String, sha: String?, content: String)]>([])

        let http = StubGitHubHTTP { request in
            let path = request.url!.path
            if path == "/user" {
                return (200, ["login": "founder"])
            }
            if path == "/user/repos" {
                return (200, [
                    ["name": "company-notes", "owner": ["login": "founder"], "default_branch": "main", "private": true, "permissions": ["push": true]]
                ])
            }
            if path == "/repos/founder/company-notes" {
                return (200, ["name": "company-notes", "owner": ["login": "founder"], "default_branch": "main", "private": true, "permissions": ["push": true]])
            }
            if path.hasPrefix("/repos/founder/company-notes/contents/") {
                let rel = String(path.dropFirst("/repos/founder/company-notes/contents/".count))
                if request.httpMethod == "GET" {
                    return (404, ["message": "Not Found"])
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
                let decoded = String(data: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["content"] as? String))), encoding: .utf8)!
                let sentSHA = body["sha"] as? String
                let count = uploadedPaths.modify { list -> Int in
                    list.append((rel, sentSHA, decoded))
                    return list.count
                }
                return (sentSHA == nil ? 201 : 200, [
                    "content": [
                        "path": rel,
                        "sha": "blob-sha-\(count)",
                        "html_url": "https://github.com/founder/company-notes/blob/main/\(rel)",
                    ],
                    "commit": ["sha": "commit-\(count)"],
                ])
            }
            return (404, ["message": "Not Found"])
        }

        let clockDate = fixedDate
        let publisher = GitHubMeetingPublisher(http: http, tokenStore: store, clock: { clockDate }, timeZone: utc)
        let capture = GitHubTestCapture()
        let transcriber = GitHubTestTranscriber()
        let summarizer = GitHubTestSummarizer()
        let coordinator = MeetingCoordinator(
            calendar: GitHubTestCalendar(),
            capture: capture,
            transcriber: transcriber,
            summarizer: summarizer,
            store: MeetingStore(root: dir),
            defaults: defaults,
            githubPublisher: publisher,
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.load(now: fixedDate)

        // Connecting with a single-repo token automatically selects that repository.
        await coordinator.connectGitHub(token: sampleToken)
        XCTAssertTrue(coordinator.githubConnected)
        XCTAssertEqual(coordinator.githubConfig.connectedUsername, "founder")
        XCTAssertEqual(coordinator.githubConfig.repository, "founder/company-notes")

        // Turn on automatic publishing.
        coordinator.githubConfig.autoPublish = true
        coordinator.saveGitHubConfig()

        // Record & finish a meeting: it should summarize and automatically push to GitHub.
        let startedID = await coordinator.startInPersonMeeting(title: "Product Roadmap", now: fixedDate)
        let id = try XCTUnwrap(startedID)
        capture.segments = [
            MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 12)
        ]
        await coordinator.stop(at: fixedDate.addingTimeInterval(600))
        await coordinator.settle()

        let publishedNote = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertEqual(publishedNote.phase, .complete)
        XCTAssertEqual(publishedNote.githubPublish?.status, .published)
        XCTAssertEqual(publishedNote.githubPublish?.repository, "founder/company-notes")
        XCTAssertEqual(publishedNote.githubPublish?.path, "meeting-notes/2026-11-24-product-roadmap.md")
        XCTAssertEqual(publishedNote.githubPublish?.sha, "blob-sha-1")
        XCTAssertFalse(coordinator.hasUnsyncedGitHubChanges(for: publishedNote))
        XCTAssertEqual(uploadedPaths.get().count, 1)
        XCTAssertNil(uploadedPaths.get()[0].sha)

        // Persisted to note.json across reload.
        let reloaded = try coordinator.store.load()
        XCTAssertEqual(reloaded.first?.githubPublish?.path, "meeting-notes/2026-11-24-product-roadmap.md")

        // Re-summarizing with auto-publish ON updates the SAME file using its SHA.
        await coordinator.resummarize(id)
        await coordinator.settle()
        XCTAssertEqual(uploadedPaths.get().count, 2)
        XCTAssertEqual(uploadedPaths.get()[1].path, "meeting-notes/2026-11-24-product-roadmap.md")
        XCTAssertEqual(uploadedPaths.get()[1].sha, "blob-sha-1")
        XCTAssertTrue(uploadedPaths.get()[1].content.contains("Summary revision 2"))

        // Toggling an action item marks unsynced changes; manual push updates in place with checkboxes.
        coordinator.toggleActionItem(id, item: "Maya to finalize launch checklist.")
        coordinator.flushPendingSaves()
        let edited = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertTrue(coordinator.hasUnsyncedGitHubChanges(for: edited))

        await coordinator.publishNoteToGitHub(id)
        XCTAssertEqual(uploadedPaths.get().count, 3)
        XCTAssertEqual(uploadedPaths.get()[2].sha, "blob-sha-2")
        XCTAssertTrue(uploadedPaths.get()[2].content.contains("- [x] Maya to finalize launch checklist."))
        let synced = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertFalse(coordinator.hasUnsyncedGitHubChanges(for: synced))

        // Disconnect clears token and turns off auto-publish.
        coordinator.disconnectGitHub()
        XCTAssertFalse(coordinator.githubConnected)
        XCTAssertFalse(coordinator.githubConfig.autoPublish)
        XCTAssertNil(store.load())
    }

    func testCoordinatorQueuesTransientFailureAndRetriesAutomaticallyOnTick() async throws {
        let dir = try makeTempDir()
        let defaults = makeDefaults()
        let store = InMemoryGitHubTokenStore(initialState: .found(sampleToken))
        let failNetwork = SyncBox(true)
        let putCount = SyncBox(0)

        let http = StubGitHubHTTP { request in
            if request.httpMethod == "GET" {
                if failNetwork.get() { throw URLError(.notConnectedToInternet) }
                return (404, ["message": "Not Found"])
            }
            putCount.modify { $0 += 1 }
            return (201, [
                "content": [
                    "path": "meeting-notes/2026-11-24-offline-sync.md",
                    "sha": "sha-recovered",
                    "html_url": "https://github.com/acme/notes/blob/main/meeting-notes/2026-11-24-offline-sync.md",
                ],
                "commit": ["sha": "commit-recovered"],
            ])
        }

        let clockDate = fixedDate
        let publisher = GitHubMeetingPublisher(http: http, tokenStore: store, clock: { clockDate }, timeZone: utc)
        let capture = GitHubTestCapture()
        let notifications = SyncBox<[String]>([])
        let coordinator = MeetingCoordinator(
            calendar: GitHubTestCalendar(),
            capture: capture,
            transcriber: GitHubTestTranscriber(),
            summarizer: GitHubTestSummarizer(),
            store: MeetingStore(root: dir),
            defaults: defaults,
            githubPublisher: publisher,
            trace: { _ in },
            notify: { msg in notifications.modify { $0.append(msg) } }
        )
        coordinator.setLaunchedForTesting(true)
        coordinator.isUIActiveProvider = { false }
        coordinator.load(now: fixedDate)
        coordinator.githubConfig = GitHubPublishConfig(
            repository: "acme/notes",
            folder: "meeting-notes",
            autoPublish: true,
            defaultBranchCache: "main"
        )
        coordinator.saveGitHubConfig()

        let startedOfflineID = await coordinator.startInPersonMeeting(title: "Offline Sync", now: fixedDate)
        let id = try XCTUnwrap(startedOfflineID)
        capture.segments = [MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 8)]
        await coordinator.stop(at: fixedDate.addingTimeInterval(300))
        await coordinator.settle()

        // First attempt failed offline -> marked pendingRetry, no scary permanent notification, idle timer armed.
        let pending = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertEqual(pending.githubPublish?.status, .pendingRetry)
        XCTAssertEqual(coordinator.desiredTimerInterval(now: fixedDate), 15)
        XCTAssertTrue(notifications.get().isEmpty)
        XCTAssertEqual(putCount.get(), 0)

        // Network returns; after backoff elapses, tick retries and publishes automatically.
        failNetwork.set(false)
        await coordinator.tick(now: Date().addingTimeInterval(120))
        await coordinator.settle()

        let recovered = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertEqual(recovered.githubPublish?.status, .published)
        XCTAssertEqual(recovered.githubPublish?.sha, "sha-recovered")
        XCTAssertEqual(putCount.get(), 1)
    }

    func testCoordinatorDoesNotAutoPublishWhenDisabledOrOnFailedNoteAndNotifiesOnPermanentError() async throws {
        let dir = try makeTempDir()
        let defaults = makeDefaults()
        let store = InMemoryGitHubTokenStore(initialState: .found(sampleToken))
        let notifications = SyncBox<[String]>([])
        let requestCount = SyncBox(0)

        let http = StubGitHubHTTP { _ in
            requestCount.modify { $0 += 1 }
            return (403, ["message": "Resource not accessible by personal access token"])
        }
        let clockDate = fixedDate
        let publisher = GitHubMeetingPublisher(http: http, tokenStore: store, clock: { clockDate }, timeZone: utc)
        let capture = GitHubTestCapture()
        let transcriber = GitHubTestTranscriber()
        let coordinator = MeetingCoordinator(
            calendar: GitHubTestCalendar(),
            capture: capture,
            transcriber: transcriber,
            summarizer: GitHubTestSummarizer(),
            store: MeetingStore(root: dir),
            defaults: defaults,
            githubPublisher: publisher,
            trace: { _ in },
            notify: { msg in notifications.modify { $0.append(msg) } }
        )
        coordinator.load(now: fixedDate)
        coordinator.githubConfig = GitHubPublishConfig(repository: "acme/notes", autoPublish: false)

        // 1. Auto-publish OFF -> nothing sent.
        _ = await coordinator.startInPersonMeeting(title: "Private Chat", now: fixedDate)
        capture.segments = [MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 5)]
        await coordinator.stop(at: fixedDate.addingTimeInterval(120))
        await coordinator.settle()
        XCTAssertEqual(requestCount.get(), 0)

        // 2. Auto-publish ON + permanent 403 -> marked .failed, user notified once, not retried.
        coordinator.githubConfig.autoPublish = true
        let startedPermID = await coordinator.startInPersonMeeting(title: "Permission Check", now: fixedDate.addingTimeInterval(200))
        let id = try XCTUnwrap(startedPermID)
        capture.segments = [MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 5)]
        await coordinator.stop(at: fixedDate.addingTimeInterval(320))
        await coordinator.settle()

        let failed = try XCTUnwrap(coordinator.notes.first { $0.id == id })
        XCTAssertEqual(failed.githubPublish?.status, .failed)
        XCTAssertEqual(notifications.get().count, 1)
        let beforeTick = requestCount.get()
        await coordinator.tick(now: Date().addingTimeInterval(600))
        await coordinator.settle()
        XCTAssertEqual(requestCount.get(), beforeTick, "Permanent 403 must not loop automatic retries")

        // 3. Failed transcription note is not auto-published.
        await transcriber.setShouldFail(true)
        let startedPartialID = await coordinator.startInPersonMeeting(title: "Broken Audio", now: fixedDate.addingTimeInterval(400))
        let partialID = try XCTUnwrap(startedPartialID)
        capture.segments = [MeetingSegment(audioFile: "microphone-0.wav", source: .microphone, offset: 0, duration: 5)]
        await coordinator.stop(at: fixedDate.addingTimeInterval(460))
        await coordinator.settle()
        let partialNote = try XCTUnwrap(coordinator.notes.first { $0.id == partialID })
        XCTAssertEqual(partialNote.phase, .failed)
        XCTAssertNil(partialNote.githubPublish)
        XCTAssertEqual(requestCount.get(), beforeTick)
    }

    func testMeetingNoteDecodesLegacyJSONWithoutGitHubFieldAndRendersMeetingsPage() throws {
        // Legacy note.json with no githubPublish key must still decode cleanly.
        let note = makeSampleNote(githubPublish: nil)
        let raw = try JSONEncoder().encode(note)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        dict.removeValue(forKey: "githubPublish")
        let legacyData = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(MeetingNote.self, from: legacyData)
        XCTAssertNil(decoded.githubPublish)
        XCTAssertEqual(decoded.event.title, note.event.title)

        // MeetingsPage renders smoothly with a published note selected.
        let dir = try makeTempDir()
        let coordinator = MeetingCoordinator(
            calendar: GitHubTestCalendar(),
            capture: GitHubTestCapture(),
            transcriber: GitHubTestTranscriber(),
            summarizer: GitHubTestSummarizer(),
            store: MeetingStore(root: dir),
            defaults: makeDefaults(),
            githubPublisher: GitHubMeetingPublisher(tokenStore: InMemoryGitHubTokenStore(initialState: .found(sampleToken))),
            trace: { _ in },
            notify: { _ in }
        )
        coordinator.githubConfig = GitHubPublishConfig(repository: "acme/notes", autoPublish: true, connectedUsername: "octocat")
        var published = makeSampleNote()
        published.githubPublish = MeetingGitHubState(
            status: .published,
            repository: "acme/notes",
            branch: "",
            resolvedBranch: "main",
            path: "meeting-notes/2026-11-24-q4-launch-sync.md",
            sha: "abc",
            commitSHA: "def",
            htmlURL: URL(string: "https://github.com/acme/notes/blob/main/meeting-notes/2026-11-24-q4-launch-sync.md"),
            publishedAt: fixedDate,
            contentHash: "old-hash",
            error: nil
        )
        coordinator.notes = [published]
        coordinator.selectedNoteID = published.id

        let host = NSHostingView(rootView: MeetingsPage(meetings: coordinator))
        host.frame = NSRect(x: 0, y: 0, width: 1080, height: 720)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(coordinator.hasUnsyncedGitHubChanges(for: published))
    }
}
