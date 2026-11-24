import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Validated `owner/repo` identifier for GitHub repositories.
struct GitHubRepoID: Equatable, Hashable, Codable, Sendable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }

    private static let sshPrefix = "git" + "@" + "github.com:"

    /// Accepts `owner/repo`, `https://github.com/owner/repo`, `https://github.com/owner/repo.git`,
    /// `https://github.com/owner/repo/tree/...`, `github.com/owner/repo`, or GitHub SSH clone URLs.
    /// Rejects non-GitHub hosts, traversal segments, query/fragment injection, and invalid names.
    static func parse(_ raw: String) -> GitHubRepoID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 300 else { return nil }

        let remainder: String
        let lower = trimmed.lowercased()
        if lower.hasPrefix(sshPrefix) {
            remainder = String(trimmed.dropFirst(sshPrefix.count))
        } else if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let components = URLComponents(string: trimmed),
                  let host = components.host?.lowercased(),
                  host == "github.com" || host == "www.github.com",
                  components.query == nil,
                  components.fragment == nil else {
                return nil
            }
            remainder = components.path
        } else if lower.hasPrefix("github.com/") {
            remainder = String(trimmed.dropFirst("github.com/".count))
        } else if lower.hasPrefix("www.github.com/") {
            remainder = String(trimmed.dropFirst("www.github.com/".count))
        } else {
            // Bare owner/repo must not contain scheme markers, queries, or fragments.
            guard !trimmed.contains("://"), !trimmed.contains("?"), !trimmed.contains("#"),
                  !trimmed.contains("@"), !trimmed.contains(":") else {
                return nil
            }
            remainder = trimmed
        }

        let cleaned = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        // Only allow bare owner/repo or standard GitHub web URL suffixes (/tree/..., /blob/...).
        if parts.count > 2 {
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("github.com/") || lower.hasPrefix("www.github.com/") else {
                return nil
            }
        }
        let owner = parts[0]
        var repoName = parts[1]
        if repoName.lowercased().hasSuffix(".git"), repoName.count > 4 {
            repoName = String(repoName.dropLast(4))
        }
        guard isValidOwner(owner), isValidRepoName(repoName) else { return nil }
        return GitHubRepoID(owner: owner, name: repoName)
    }

    static func isValidOwner(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 39 else { return false }
        guard value.first != "-", value.last != "-" else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "-"
        }
    }

    static func isValidRepoName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "-" || scalar == "_" || scalar == "."
        }
    }
}

struct GitHubRepositorySummary: Equatable, Identifiable, Codable, Sendable {
    var id: String { fullName }
    let owner: String
    let name: String
    let defaultBranch: String
    let isPrivate: Bool
    let canPush: Bool

    var fullName: String { "\(owner)/\(name)" }
}

/// Non-secret user preferences for automatic GitHub publishing.
/// Stored in UserDefaults; the access token stays exclusively in macOS Keychain.
struct GitHubPublishConfig: Equatable, Codable, Sendable {
    static let defaultsKey = "meetingGitHubPublishConfig"
    static let defaultFolder = "meeting-notes"

    var repository: String = ""
    var branch: String = ""
    var folder: String = GitHubPublishConfig.defaultFolder
    var autoPublish: Bool = false
    var includeTranscript: Bool = true
    var defaultBranchCache: String = ""
    var connectedUsername: String? = nil

    var parsedRepo: GitHubRepoID? { GitHubRepoID.parse(repository) }
    var isConfigured: Bool { parsedRepo != nil }
    var displayBranch: String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return defaultBranchCache.isEmpty ? "default branch" : defaultBranchCache
    }

    /// Normalizes a relative folder path inside a GitHub repo. Empty string means repository root.
    /// Returns nil when the input contains unsafe path segments (`..`, backslashes, control chars, etc.).
    static func validatedFolder(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard !trimmed.contains("\\"), !trimmed.contains("?"), !trimmed.contains("#") else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if stripped.isEmpty { return "" }
        let segments = stripped.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for segment in segments {
            guard segment != ".", segment != "..", !segment.contains(".."), segment.count <= 120 else {
                return nil
            }
        }
        return segments.joined(separator: "/")
    }

    /// Validates an optional Git branch name. Empty string means "use repository default branch".
    static func validatedBranch(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard trimmed.count <= 200,
              !trimmed.hasPrefix("/"), !trimmed.hasSuffix("/"),
              !trimmed.hasPrefix("-"), !trimmed.hasPrefix("."),
              !trimmed.hasSuffix("."), !trimmed.hasSuffix(".lock"),
              !trimmed.contains(".."), !trimmed.contains("//"), !trimmed.contains("@{") else {
            return nil
        }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil,
              trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else {
            return nil
        }
        return trimmed
    }
}

/// Persisted on each `MeetingNote` so updates reuse the same file path and SHA without creating duplicates.
struct MeetingGitHubState: Equatable, Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case published
        case pendingRetry
        case failed
    }

    var status: Status
    var repository: String
    /// Explicit branch configured when published, or `""` when targeting the repo's default branch.
    var branch: String
    var resolvedBranch: String
    var path: String
    var sha: String?
    var commitSHA: String?
    var htmlURL: URL?
    var publishedAt: Date?
    var contentHash: String?
    var error: String?
}

struct MeetingGitHubPublishResult: Equatable, Sendable {
    let repository: String
    let branch: String
    let resolvedBranch: String
    let path: String
    let sha: String?
    let commitSHA: String?
    let htmlURL: URL?
    let contentHash: String
    let publishedAt: Date
}

struct GitHubPublishFailure: LocalizedError, Equatable, Sendable {
    let message: String
    let statusCode: Int?
    let isTransient: Bool

    var errorDescription: String? { message }

    init(_ message: String, statusCode: Int? = nil, isTransient: Bool = false) {
        self.message = message
        self.statusCode = statusCode
        self.isTransient = isTransient
    }
}

// MARK: - Keychain Token Storage

enum GitHubTokenLoadState: Equatable, Sendable {
    case found(String)
    case missing
    /// Keychain could not be read right now (e.g., locked at wake with `interactionNotAllowed`).
    case unavailable(OSStatus)
}

protocol GitHubTokenStoring: Sendable {
    func load() -> String?
    func loadState() -> GitHubTokenLoadState
    func save(_ token: String) -> Bool
    func clear()
}

extension GitHubTokenStoring {
    func loadState() -> GitHubTokenLoadState {
        load().map(GitHubTokenLoadState.found) ?? .missing
    }
}

enum GitHubTokenValidator {
    static let newTokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new")!

    /// Trims pasted whitespace and surrounding quotes; rejects control chars, spaces, and obviously empty strings.
    static func normalized(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard token.count >= 10, token.count <= 512 else { return nil }
        guard token.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        return token
    }
}

struct KeychainGitHubTokenStore: GitHubTokenStoring {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.andre.flowclone.github",
            kSecAttrAccount as String: "access-token",
        ]
    }

    func load() -> String? {
        if case .found(let token) = loadState() { return token }
        return nil
    }

    func loadState() -> GitHubTokenLoadState {
        // Test processes and hands-free debug builds are signed differently from the installed app;
        // reading the owner's Keychain item would pop a macOS ACL dialog.
        guard !suppressHostAccess else { return .missing }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8),
                  let normalized = GitHubTokenValidator.normalized(token) else {
                return .missing
            }
            return .found(normalized)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    func save(_ rawToken: String) -> Bool {
        guard !suppressHostAccess, let token = GitHubTokenValidator.normalized(rawToken) else { return false }
        let updateAttributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrLabel as String: "FlowClone GitHub Meeting Notes",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Update atomically first so replacing a token never deletes a working one if add fails.
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }
        var item = query
        for (k, v) in updateAttributes { item[k] = v }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func clear() {
        guard !suppressHostAccess else { return }
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Markdown & Filename Formatting

enum MeetingGitHubDocument {
    static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var slug = ""
        var previousHyphen = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                slug.unicodeScalars.append(scalar)
                previousHyphen = false
            } else if !previousHyphen, !slug.isEmpty {
                slug.append("-")
                previousHyphen = true
            }
            if slug.count >= 60 { break }
        }
        let cleaned = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "meeting" : cleaned
    }

    static func candidatePaths(
        for note: MeetingNote,
        folder: String,
        timeZone: TimeZone = .current
    ) -> [String] {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = dateFormatter.string(from: note.startedAt)

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HHmm"
        let timeSuffix = timeFormatter.string(from: note.startedAt)

        let titleSlug = slug(for: note.event.title)
        let shortID = String(note.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let baseNames = [
            "\(datePrefix)-\(titleSlug).md",
            "\(datePrefix)-\(titleSlug)-\(timeSuffix).md",
            "\(datePrefix)-\(titleSlug)-\(timeSuffix)-\(shortID).md",
        ]
        let cleanFolder = GitHubPublishConfig.validatedFolder(folder) ?? ""
        if cleanFolder.isEmpty { return baseNames }
        return baseNames.map { "\(cleanFolder)/\($0)" }
    }

    /// Renders a clean GitHub-flavored Markdown file with safe YAML frontmatter and task checkboxes.
    static func markdown(
        for note: MeetingNote,
        includeTranscript: Bool = true,
        timeZone: TimeZone = .current
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime]

        let readableDate = DateFormatter()
        readableDate.calendar = Calendar(identifier: .gregorian)
        readableDate.locale = Locale(identifier: "en_US_POSIX")
        readableDate.timeZone = timeZone
        readableDate.dateStyle = .medium
        readableDate.timeStyle = .short

        var lines: [String] = ["---"]
        lines.append("title: \(yamlString(note.event.title))")
        lines.append("date: \(yamlString(iso.string(from: note.startedAt)))")
        if let endedAt = note.endedAt, endedAt >= note.startedAt {
            let minutes = max(1, Int((endedAt.timeIntervalSince(note.startedAt) / 60).rounded()))
            lines.append("duration_minutes: \(minutes)")
        }
        lines.append("type: \(yamlString(note.isInPerson ? "in-person" : "call"))")
        if !note.event.attendees.isEmpty {
            lines.append("attendees:")
            for attendee in note.event.attendees {
                lines.append("  - \(yamlString(attendee))")
            }
        }
        lines.append("source: \"FlowClone\"")
        lines.append("---")
        lines.append("")
        lines.append("# \(note.event.title)")
        lines.append("")
        lines.append("**Date:** \(readableDate.string(from: note.startedAt))")
        if !note.event.attendees.isEmpty {
            lines.append("**Attendees:** \(note.event.attendees.joined(separator: ", "))")
        }
        if note.isInPerson {
            lines.append("**Format:** In-person")
        }
        lines.append("")

        if let issue = note.issue?.trimmingCharacters(in: .whitespacesAndNewlines), !issue.isEmpty {
            lines.append("> **Notice:** \(issue)")
            lines.append("")
        }

        lines.append("## Summary")
        lines.append("")
        let renderedSummary = note.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Summary not generated yet."
            : MeetingActionItems.applyingCheckboxes(to: note.summary, completed: note.completedActionItems)
        lines.append(renderedSummary)
        let method = note.summaryMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        if !method.isEmpty {
            lines.append("")
            lines.append("*\(method)*")
        }

        let personal = note.personalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personal.isEmpty {
            lines.append("")
            lines.append("## My notes")
            lines.append("")
            lines.append(personal)
        }

        if includeTranscript {
            let transcript = note.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                lines.append("")
                lines.append("## Transcript")
                lines.append("")
                lines.append(transcript)
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func contentHash(for markdown: String) -> String {
        let digest = SHA256.hash(data: Data(markdown.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Time-zone-independent content digest so traveling across time zones does not falsely
    /// mark already-published meeting notes as having unsaved edits.
    static func contentHash(for note: MeetingNote, includeTranscript: Bool) -> String {
        let canonical = markdown(
            for: note,
            includeTranscript: includeTranscript,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        return contentHash(for: canonical)
    }

    static func commitMessage(for note: MeetingNote, updating: Bool) -> String {
        let singleLine = note.event.title
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = singleLine.isEmpty ? "Meeting" : String(singleLine.prefix(80))
        return updating ? "Update meeting note: \(safeTitle)" : "Add meeting note: \(safeTitle)"
    }

    /// Quotes a string safely for YAML 1.2 double-quoted scalars.
    private static func yamlString(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.count + 4)
        escaped.append("\"")
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped.append(" ")
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped.append("\"")
        return escaped
    }
}

// MARK: - HTTP Transport & GitHub REST Client

protocol GitHubHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Refuses redirects away from `api.github.com` so the Bearer token can never leak to another host.
private final class GitHubRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, GitHubMeetingPublisher.isTrustedAPIURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

final class URLSessionGitHubHTTP: GitHubHTTP, Sendable {
    private let session: URLSession
    private let redirectBlocker = GitHubRedirectBlocker()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, GitHubMeetingPublisher.isTrustedAPIURL(url) else {
            throw GitHubPublishFailure("Refused a non-GitHub API request.", isTransient: false)
        }
        let (data, response) = try await session.data(for: request, delegate: redirectBlocker)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

protocol MeetingGitHubPublishing: Sendable {
    func tokenLoadState() -> GitHubTokenLoadState
    func saveToken(_ rawToken: String) -> Bool
    func clearToken()
    func verifyToken(_ token: String) async throws -> String
    func listRepositories() async throws -> [GitHubRepositorySummary]
    func verifyRepository(_ repo: GitHubRepoID) async throws -> GitHubRepositorySummary
    func publish(note: MeetingNote, config: GitHubPublishConfig) async throws -> MeetingGitHubPublishResult
}

final class GitHubMeetingPublisher: MeetingGitHubPublishing, Sendable {
    private let http: any GitHubHTTP
    private let tokenStore: any GitHubTokenStoring
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    init(
        http: any GitHubHTTP = URLSessionGitHubHTTP(),
        tokenStore: any GitHubTokenStoring = KeychainGitHubTokenStore(),
        clock: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = .current
    ) {
        self.http = http
        self.tokenStore = tokenStore
        self.clock = clock
        self.timeZone = timeZone
    }

    func tokenLoadState() -> GitHubTokenLoadState {
        tokenStore.loadState()
    }

    func saveToken(_ rawToken: String) -> Bool {
        tokenStore.save(rawToken)
    }

    func clearToken() {
        tokenStore.clear()
    }

    func verifyToken(_ rawToken: String) async throws -> String {
        guard let token = GitHubTokenValidator.normalized(rawToken) else {
            throw GitHubPublishFailure("Paste a valid GitHub access token first.")
        }
        let request = try makeRequest(method: "GET", path: "/user", token: token)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data, context: .auth)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let login = json?["login"] as? String, !login.isEmpty else {
            throw GitHubPublishFailure("GitHub did not return your account name. Try again.")
        }
        return login
    }

    func listRepositories() async throws -> [GitHubRepositorySummary] {
        let token = try requireStoredToken()
        let request = try makeRequest(
            method: "GET",
            path: "/user/repos",
            queryItems: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "pushed"),
                URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
            ],
            token: token
        )
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data, context: .auth)
        }
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return list.compactMap(Self.parseRepositorySummary).filter(\.canPush)
    }

    func verifyRepository(_ repo: GitHubRepoID) async throws -> GitHubRepositorySummary {
        let token = try requireStoredToken()
        let summary = try await fetchRepository(repo, token: token)
        guard summary.canPush else {
            throw GitHubPublishFailure(
                "This token only has read access to \(repo.fullName). Give it Contents: Read and write permission on GitHub.",
                statusCode: 403
            )
        }
        return summary
    }

    func publish(note: MeetingNote, config: GitHubPublishConfig) async throws -> MeetingGitHubPublishResult {
        guard let repo = GitHubRepoID.parse(config.repository) else {
            throw GitHubPublishFailure("Choose a valid GitHub repository (for example, your-name/meeting-notes).")
        }
        guard let folder = GitHubPublishConfig.validatedFolder(config.folder) else {
            throw GitHubPublishFailure("The folder path contains unsupported characters. Use simple folder names like meeting-notes.")
        }
        guard let explicitBranch = GitHubPublishConfig.validatedBranch(config.branch) else {
            throw GitHubPublishFailure("The branch name isn’t valid. Leave it blank to use the repository’s default branch.")
        }
        let token = try requireStoredToken()
        let markdown = MeetingGitHubDocument.markdown(
            for: note,
            includeTranscript: config.includeTranscript,
            timeZone: timeZone
        )
        let contentHash = MeetingGitHubDocument.contentHash(
            for: note,
            includeTranscript: config.includeTranscript
        )

        let existingMatchesTarget: Bool = {
            guard let existing = note.githubPublish else { return false }
            return existing.repository.caseInsensitiveCompare(repo.fullName) == .orderedSame
                && existing.branch == explicitBranch
                && !existing.path.isEmpty
        }()

        let targetPath: String
        var existingSHA: String?
        let isUpdating: Bool

        if existingMatchesTarget, let existing = note.githubPublish {
            targetPath = existing.path
            if let sha = existing.sha, !sha.isEmpty {
                existingSHA = sha
                isUpdating = true
            } else {
                existingSHA = try await fetchFileSHA(repo: repo, path: targetPath, branch: explicitBranch, token: token)
                isUpdating = existingSHA != nil
            }
        } else {
            let candidates = MeetingGitHubDocument.candidatePaths(for: note, folder: folder, timeZone: timeZone)
            var chosen = candidates.last!
            var foundSHA: String? = nil
            for candidate in candidates {
                let probe = try await fetchFileSHA(repo: repo, path: candidate, branch: explicitBranch, token: token)
                if probe == nil {
                    chosen = candidate
                    foundSHA = nil
                    break
                }
                if candidate == candidates.last {
                    chosen = candidate
                    foundSHA = probe
                }
            }
            targetPath = chosen
            existingSHA = foundSHA
            isUpdating = foundSHA != nil
        }

        let putResult: (Data, HTTPURLResponse)
        do {
            putResult = try await putFile(
                repo: repo,
                path: targetPath,
                branch: explicitBranch,
                markdown: markdown,
                message: MeetingGitHubDocument.commitMessage(for: note, updating: isUpdating),
                sha: existingSHA,
                token: token
            )
        } catch let failure as GitHubPublishFailure where failure.statusCode == 409 && existingMatchesTarget {
            // The file changed on GitHub since our last push: refresh its latest SHA once and retry.
            let latestSHA = try await fetchFileSHA(repo: repo, path: targetPath, branch: explicitBranch, token: token)
            putResult = try await putFile(
                repo: repo,
                path: targetPath,
                branch: explicitBranch,
                markdown: markdown,
                message: MeetingGitHubDocument.commitMessage(for: note, updating: latestSHA != nil),
                sha: latestSHA,
                token: token
            )
        }

        let (data, _) = putResult
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let contentObj = json["content"] as? [String: Any]
        let commitObj = json["commit"] as? [String: Any]

        let savedPath = (contentObj?["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? targetPath
        let savedSHA = contentObj?["sha"] as? String
        let commitSHA = commitObj?["sha"] as? String
        let htmlURL = (contentObj?["html_url"] as? String).flatMap(Self.validatedGitHubWebURL)
        let resolvedBranch = explicitBranch.isEmpty
            ? (config.defaultBranchCache.isEmpty ? "main" : config.defaultBranchCache)
            : explicitBranch

        return MeetingGitHubPublishResult(
            repository: repo.fullName,
            branch: explicitBranch,
            resolvedBranch: resolvedBranch,
            path: savedPath,
            sha: savedSHA,
            commitSHA: commitSHA,
            htmlURL: htmlURL,
            contentHash: contentHash,
            publishedAt: clock()
        )
    }

    // MARK: - Private API Helpers

    private func requireStoredToken() throws -> String {
        switch tokenStore.loadState() {
        case .found(let token):
            return token
        case .missing:
            throw GitHubPublishFailure("Connect your GitHub account first in Meetings → GitHub.")
        case .unavailable:
            throw GitHubPublishFailure(
                "Waiting for macOS Keychain to unlock your GitHub token.",
                isTransient: true
            )
        }
    }

    private func fetchRepository(_ repo: GitHubRepoID, token: String) async throws -> GitHubRepositorySummary {
        let request = try makeRequest(method: "GET", path: "/repos/\(repo.owner)/\(repo.name)", token: token)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data, context: .repository(repo.fullName, branch: nil))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = Self.parseRepositorySummary(object) else {
            throw GitHubPublishFailure("GitHub returned unexpected details for \(repo.fullName).")
        }
        return summary
    }

    /// Returns the blob SHA if the file exists on GitHub, or `nil` when 404 (not found / empty repo).
    private func fetchFileSHA(
        repo: GitHubRepoID,
        path: String,
        branch: String,
        token: String
    ) async throws -> String? {
        let encodedPath = Self.encodedContentsPath(path)
        let query: [URLQueryItem] = branch.isEmpty ? [] : [URLQueryItem(name: "ref", value: branch)]
        let request = try makeRequest(
            method: "GET",
            percentEncodedPath: "/repos/\(repo.owner)/\(repo.name)/contents/\(encodedPath)",
            queryItems: query,
            token: token
        )
        let (data, response) = try await perform(request)
        if response.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(
                status: response.statusCode,
                data: data,
                context: .repository(repo.fullName, branch: branch.isEmpty ? nil : branch)
            )
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // If a directory exists at this path, GitHub returns a JSON array; treat as occupied with a placeholder.
        if json == nil { return "directory" }
        return json?["sha"] as? String ?? "existing"
    }

    private func putFile(
        repo: GitHubRepoID,
        path: String,
        branch: String,
        markdown: String,
        message: String,
        sha: String?,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        let encodedPath = Self.encodedContentsPath(path)
        var body: [String: Any] = [
            "message": message,
            "content": Data(markdown.utf8).base64EncodedString(),
        ]
        if !branch.isEmpty {
            body["branch"] = branch
        }
        if let sha, !sha.isEmpty {
            body["sha"] = sha
        }
        var request = try makeRequest(
            method: "PUT",
            percentEncodedPath: "/repos/\(repo.owner)/\(repo.name)/contents/\(encodedPath)",
            token: token
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapError(
                status: response.statusCode,
                data: data,
                context: .write(repo.fullName, branch: branch.isEmpty ? nil : branch)
            )
        }
        return (data, response)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(request)
        } catch let failure as GitHubPublishFailure {
            throw failure
        } catch {
            if Self.isTransientNetworkError(error) {
                throw GitHubPublishFailure(
                    "Couldn’t reach GitHub right now. FlowClone will try again when you’re back online.",
                    isTransient: true
                )
            }
            throw GitHubPublishFailure("GitHub request failed: \(error.localizedDescription)")
        }
    }

    private func makeRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        token: String
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return try finalizeRequest(method: method, components: components, token: token)
    }

    private func makeRequest(
        method: String,
        percentEncodedPath: String,
        queryItems: [URLQueryItem] = [],
        token: String
    ) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.percentEncodedPath = percentEncodedPath
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return try finalizeRequest(method: method, components: components, token: token)
    }

    private func finalizeRequest(method: String, components: URLComponents, token: String) throws -> URLRequest {
        guard let url = components.url, Self.isTrustedAPIURL(url) else {
            throw GitHubPublishFailure("Could not build a valid GitHub API request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FlowClone-MeetingNotes", forHTTPHeaderField: "User-Agent")
        return request
    }

    private enum ErrorContext {
        case auth
        case repository(String, branch: String?)
        case write(String, branch: String?)
    }

    private static func mapError(status: Int, data: Data, context: ErrorContext) -> GitHubPublishFailure {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let apiMessage = (json?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = apiMessage.lowercased()

        if status == 401 {
            return GitHubPublishFailure(
                "GitHub rejected this token. Reconnect with a fresh token in Meetings → GitHub.",
                statusCode: 401
            )
        }
        if status == 429 || status >= 500 || status == 408 {
            return GitHubPublishFailure(
                "GitHub is temporarily busy (error \(status)). FlowClone will retry automatically.",
                statusCode: status,
                isTransient: true
            )
        }
        if status == 403 {
            if lower.contains("rate limit") {
                return GitHubPublishFailure(
                    "GitHub rate limit reached. FlowClone will try again shortly.",
                    statusCode: 403,
                    isTransient: true
                )
            }
            switch context {
            case .auth:
                return GitHubPublishFailure(
                    "GitHub denied access with this token. Check that it has repository access.",
                    statusCode: 403
                )
            case .repository(let repo, _), .write(let repo, _):
                return GitHubPublishFailure(
                    "GitHub didn’t allow writing to \(repo). Make sure your token has Contents: Read and write permission (and the branch isn’t protected).",
                    statusCode: 403
                )
            }
        }
        if status == 404 {
            switch context {
            case .auth:
                return GitHubPublishFailure("GitHub couldn’t find that account or endpoint.", statusCode: 404)
            case .repository(let repo, let branch), .write(let repo, let branch):
                if let branch, !branch.isEmpty {
                    return GitHubPublishFailure(
                        "Could not find \(repo) or branch “\(branch)”. Check the repository name, branch, and token access.",
                        statusCode: 404
                    )
                }
                return GitHubPublishFailure(
                    "Could not find \(repo), or this token doesn’t have access to it.",
                    statusCode: 404
                )
            }
        }
        if status == 409 {
            return GitHubPublishFailure(
                "This file was updated on GitHub at the same time. Click Retry to sync again.",
                statusCode: 409,
                isTransient: true
            )
        }
        if status == 422 {
            switch context {
            case .write(let repo, let branch):
                let branchHint = branch.map { " on branch “\($0)”" } ?? ""
                return GitHubPublishFailure(
                    "GitHub couldn’t save the note to \(repo)\(branchHint). Check if the branch is protected or has rules blocking direct commits.",
                    statusCode: 422
                )
            default:
                return GitHubPublishFailure("GitHub rejected the request (422).", statusCode: 422)
            }
        }
        return GitHubPublishFailure("GitHub returned an error (\(status)).", statusCode: status)
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            || nsError.domain == NSPOSIXErrorDomain
            || nsError.domain == (kCFErrorDomainCFNetwork as String)
    }

    static func parseRepositorySummary(_ item: [String: Any]) -> GitHubRepositorySummary? {
        guard let name = item["name"] as? String,
              let ownerObj = item["owner"] as? [String: Any],
              let owner = ownerObj["login"] as? String,
              GitHubRepoID.isValidOwner(owner),
              GitHubRepoID.isValidRepoName(name) else {
            return nil
        }
        let defaultBranch = (item["default_branch"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "main"
        let isPrivate = item["private"] as? Bool ?? false
        let permissions = item["permissions"] as? [String: Any]
        let canPush = permissions?["push"] as? Bool ?? true
        return GitHubRepositorySummary(
            owner: owner,
            name: name,
            defaultBranch: defaultBranch,
            isPrivate: isPrivate,
            canPush: canPush
        )
    }

    static func encodedContentsPath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    static func isTrustedAPIURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.github.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
    }

    static func validatedGitHubWebURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com",
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}
