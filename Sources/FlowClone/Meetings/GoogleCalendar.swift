import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Google sign-in in a browser window: OAuth 2.0 for native apps (RFC 8252) with PKCE and an
/// iOS-type client ID, so no client secret ships in the app. Only read-only Calendar access is
/// requested. The refresh token stays in this Mac's Keychain; nothing is written to Google.
struct GoogleOAuthClient: Equatable, Sendable {
    let clientID: String
    /// Google's redirect for iOS/macOS clients is the reversed client ID as a URL scheme.
    var redirectScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let scopes = "openid email \(calendarScope)"

    /// Info.plist `FlowCloneGoogleClientID`; `defaults write com.andre.flowclone meetingGoogleClientID …`
    /// overrides it so a client can be tried without a rebuild.
    static func configured(info: [String: Any]? = Bundle.main.infoDictionary,
                           defaults: UserDefaults = .standard) -> GoogleOAuthClient? {
        let override = defaults.string(forKey: "meetingGoogleClientID") ?? ""
        let value = (override.isEmpty ? info?["FlowCloneGoogleClientID"] as? String ?? "" : override)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasSuffix(".apps.googleusercontent.com") ? GoogleOAuthClient(clientID: value) : nil
    }
}

enum PKCE {
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

protocol GoogleHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct URLSessionGoogleHTTP: GoogleHTTP {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// What survives a relaunch. The short-lived access token is kept in memory only.
struct GoogleSession: Codable, Equatable, Sendable {
    var refreshToken: String
    var email: String
}

enum GoogleSessionLoadState: Equatable, Sendable {
    case found(GoogleSession)
    case missing
    /// Keychain could not be read right now (e.g., locked at login/wake with `interactionNotAllowed`).
    /// Must NOT be cached as signed-out so the next sync retries automatically once unlocked.
    case unavailable(OSStatus)
}

protocol GoogleSessionStoring: Sendable {
    func load() -> GoogleSession?
    func loadState() -> GoogleSessionLoadState
    func save(_ session: GoogleSession) -> Bool
    func clear()
}
extension GoogleSessionStoring {
    func loadState() -> GoogleSessionLoadState {
        load().map(GoogleSessionLoadState.found) ?? .missing
    }
}

struct KeychainGoogleSessionStore: GoogleSessionStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.andre.flowclone.google-calendar",
         kSecAttrAccount as String: "oauth"]
    }
    func load() -> GoogleSession? {
        if case .found(let session) = loadState() { return session }
        return nil
    }
    func loadState() -> GoogleSessionLoadState {
        // Test processes (hands-free debug builds and xctest) are not signed as the installed
        // app; querying the owner's Keychain item triggers a macOS ACL password dialog even
        // when LAContext.interactionNotAllowed is set.
        guard !suppressHostAccess else { return .missing }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background calendar refreshes must never summon a Keychain dialog.
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let session = try? JSONDecoder().decode(GoogleSession.self, from: data) else {
                return .missing
            }
            return .found(session)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }
    func save(_ session: GoogleSession) -> Bool {
        guard !suppressHostAccess else { return false }
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "FlowClone Google Calendar",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Update atomically first so token rotation never deletes a working refresh token if add fails.
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            return false
        }
        var item = query
        for (k, v) in updateAttributes { item[k] = v }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    func clear() {
        guard !suppressHostAccess else { return }
        SecItemDelete(query as CFDictionary)
    }
}

/// Opens Google's sign-in page in a browser window and returns the redirect URL.
@MainActor final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        guard !suppressHostAccess else { throw MeetingFailure("Google sign-in is disabled in the test session.") }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                if let url { continuation.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: MeetingFailure("Google sign-in was cancelled."))
                } else { continuation.resume(throwing: error ?? MeetingFailure("Google sign-in did not finish.")) }
                Task { @MainActor in self?.session = nil }
            }
            session.presentationContextProvider = self
            // Shares the browser's Google sign-in, so an already signed-in account is one click.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: MeetingFailure("The Google sign-in window could not be opened."))
            }
        }
    }
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }
}

@MainActor final class GoogleAuthorizer {
    typealias Present = @MainActor (URL, String) async throws -> URL
    private let client: () -> GoogleOAuthClient?
    private let http: any GoogleHTTP
    private let store: any GoogleSessionStoring
    private let present: Present
    private var session: GoogleSession?
    private var loaded = false
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshTask: (id: UUID, task: Task<String, Error>)?
    private var sessionGeneration = 0

    init(client: @escaping () -> GoogleOAuthClient? = { GoogleOAuthClient.configured() },
         http: any GoogleHTTP = URLSessionGoogleHTTP(), store: any GoogleSessionStoring = KeychainGoogleSessionStore(),
         present: Present? = nil) {
        self.client = client; self.http = http; self.store = store
        let browser = BrowserSignIn()
        self.present = present ?? { url, scheme in try await browser.open(url, callbackScheme: scheme) }
    }
    var email: String? { current?.email }
    var signedIn: Bool { current != nil }
    private var current: GoogleSession? {
        if case .found(let session) = loadSessionState() { return session }
        return nil
    }
    private func loadSessionState() -> GoogleSessionLoadState {
        if loaded {
            return session.map(GoogleSessionLoadState.found) ?? .missing
        }
        switch store.loadState() {
        case .found(let found):
            session = found
            loaded = true
            return .found(found)
        case .missing:
            session = nil
            loaded = true
            return .missing
        case .unavailable(let status):
            // Do not latch `loaded = true` so the next refresh succeeds once Keychain unlocks.
            return .unavailable(status)
        }
    }

    static let notConfigured = "Google sign-in needs an OAuth client ID in this build (FlowCloneGoogleClientID). See docs/meeting-notes/google-sign-in.md."

    func signIn() async throws {
        guard let client = client() else { throw MeetingFailure(Self.notConfigured) }
        let verifier = PKCE.verifier(), state = PKCE.verifier()
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: client.clientID), .init(name: "redirect_uri", value: client.redirectURI),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: GoogleOAuthClient.scopes),
            .init(name: "code_challenge", value: PKCE.challenge(verifier)), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "select_account consent"),
        ]
        let callback = try await present(components.url!, client.redirectScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard item("state") == state else { throw MeetingFailure("Google sign-in returned an unexpected response. Try again.") }
        if let error = item("error") {
            throw MeetingFailure(error == "access_denied" ? "Google sign-in was cancelled." : "Google sign-in failed (\(error)).")
        }
        guard let code = item("code") else { throw MeetingFailure("Google sign-in did not return an authorization code.") }
        let token = try await tokenRequest(client, [
            "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": client.redirectURI,
        ])
        // Google's consent screen lets people untick Calendar; without it nothing can be read.
        guard (token["scope"] as? String ?? "").split(separator: " ").contains(Substring(GoogleOAuthClient.calendarScope)) else {
            throw MeetingFailure("FlowClone needs permission to see your calendar events. Sign in again and keep the Calendar box ticked.")
        }
        guard let refresh = token["refresh_token"] as? String, let access = token["access_token"] as? String else {
            throw MeetingFailure("Google did not grant ongoing access. Sign in again.")
        }
        let email = (token["id_token"] as? String).flatMap(Self.email(fromIDToken:)) ?? "Google account"
        let session = GoogleSession(refreshToken: refresh, email: email)
        guard store.save(session) else { throw MeetingFailure("Your Google sign-in could not be saved to the Keychain.") }
        sessionGeneration += 1
        refreshTask = nil
        self.session = session; loaded = true
        accessToken = access; expiry = Date().addingTimeInterval(Double(token["expires_in"] as? Int ?? 3600))
    }

    func token(now: Date = Date()) async throws -> String {
        if let accessToken, expiry > now.addingTimeInterval(60) { return accessToken }
        if let existing = refreshTask { return try await existing.task.value }
        guard let client = client() else { throw MeetingFailure(Self.notConfigured) }
        let initialSession: GoogleSession
        switch loadSessionState() {
        case .found(let found):
            initialSession = found
        case .missing:
            throw GoogleCalendarSignInRequired.missing
        case .unavailable(let status):
            throw GoogleCalendarTransientFailure.keychainUnavailable(status)
        }
        let generation = sessionGeneration
        let refreshID = UUID()
        let task = Task<String, Error> { @MainActor in
            let token: [String: Any]
            do {
                token = try await self.tokenRequest(client, [
                    "refresh_token": initialSession.refreshToken, "grant_type": "refresh_token",
                ])
            } catch let failure as GoogleTokenFailure where failure.code == "invalid_grant" {
                if self.sessionGeneration == generation { self.forget() }
                throw GoogleCalendarSignInRequired.expired
            }
            guard let access = token["access_token"] as? String else {
                throw MeetingFailure("Google did not return an access token.")
            }
            guard self.sessionGeneration == generation else { return access }
            if let rotated = (token["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rotated.isEmpty, var active = self.session, rotated != active.refreshToken {
                active.refreshToken = rotated
                if self.store.save(active) {
                    self.session = active
                }
            }
            self.accessToken = access
            self.expiry = now.addingTimeInterval(Double(token["expires_in"] as? Int ?? 3600))
            return access
        }
        refreshTask = (refreshID, task)
        defer { if refreshTask?.id == refreshID { refreshTask = nil } }
        return try await task.value
    }
    /// After a 401 the cached token is stale even if its clock says otherwise.
    func expire() { accessToken = nil; expiry = .distantPast; refreshTask = nil }

    func signOut() async {
        if let session = current {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": session.refreshToken])
            _ = try? await http.send(request)  // Best effort; the local copy is removed regardless.
        }
        forget()
    }
    private func forget() { sessionGeneration += 1; store.clear(); session = nil; loaded = true; expire() }

    private func tokenRequest(_ client: GoogleOAuthClient, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields.merging(["client_id": client.clientID]) { a, _ in a })
        let (data, response) = try await http.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleTokenFailure(code: json["error"] as? String ?? "http_\(response.statusCode)",
                                     detail: json["error_description"] as? String)
        }
        return json
    }
    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }
    /// The ID token comes straight from Google's token endpoint over TLS, so its claims are
    /// read without a signature check (Google's guidance for this case).
    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }
}
struct GoogleTokenFailure: LocalizedError, Sendable {
    let code: String
    let detail: String?
    var errorDescription: String? { "Google sign-in failed (\(code))\(detail.map { ": \($0)" } ?? "")." }
}

enum GoogleCalendarTransientFailure: LocalizedError, Sendable {
    case keychainUnavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            "Waiting for macOS Keychain to unlock Google Calendar credentials."
        }
    }
}

enum GoogleCalendarSignInRequired: LocalizedError, Sendable {
    case missing, expired

    var errorDescription: String? {
        switch self {
        case .missing: "Sign in with Google to choose the calendars to watch."
        case .expired: "Google access expired or was removed. Sign in with Google again."
        }
    }
}

/// Reads calendars and events with the Google Calendar API (read-only scope).
@MainActor final class GoogleMeetingCalendar: MeetingCalendarBackend {
    static let calendarListCacheTTL: TimeInterval = 30 * 60
    private static let maxETagCacheEntries = 64

    private struct ETagCacheEntry {
        let etag: String
        let items: [[String: Any]]
    }

    let auth: GoogleAuthorizer
    private let http: any GoogleHTTP
    private let clock: @Sendable () -> Date
    private var cachedCalendars: (account: String, fetchedAt: Date, items: [MeetingCalendar])?
    private var etagCache: [String: ETagCacheEntry] = [:]

    init(
        auth: GoogleAuthorizer = GoogleAuthorizer(),
        http: any GoogleHTTP = URLSessionGoogleHTTP(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.auth = auth; self.http = http; self.clock = clock
    }
    func invalidateCaches() {
        cachedCalendars = nil
        etagCache.removeAll()
    }
    func connect() async throws {
        invalidateCaches()
        try await auth.signIn()
        log("meeting calendar: Google sign-in completed")
    }
    func calendars() async throws -> [MeetingCalendar] {
        try await calendars(forceRefresh: false)
    }
    func calendars(forceRefresh: Bool) async throws -> [MeetingCalendar] {
        let now = clock()
        let account = auth.email ?? "Google"
        if !forceRefresh,
           auth.signedIn,
           let cached = cachedCalendars,
           cached.account == account,
           now.timeIntervalSince(cached.fetchedAt) < Self.calendarListCacheTTL,
           now >= cached.fetchedAt {
            return cached.items
        }
        let items = try await pages("users/me/calendarList", ["minAccessRole": "reader"])
        let mapped: [MeetingCalendar] = items.compactMap { item in
            guard let id = item["id"] as? String, item["deleted"] as? Bool != true else { return nil }
            let title = item["summaryOverride"] as? String ?? item["summary"] as? String ?? id
            return MeetingCalendar(id: id, title: title, account: account, primary: item["primary"] as? Bool == true)
        }.sorted { ($0.primary ? 0 : 1, $0.title) < ($1.primary ? 0 : 1, $1.title) }
        cachedCalendars = (account: account, fetchedAt: now, items: mapped)
        return mapped
    }
    private static let isoFormatter = ISO8601DateFormatter()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let allDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private static let calendarIDAllowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))

    /// Quantizes event-list bounds onto 30-minute boundaries covering `[from, to]` so consecutive
    /// syncs produce identical query URLs and can hit Google Calendar's `If-None-Match` / `304 Not Modified`.
    private static func quantizedBounds(from: Date, to: Date) -> (Date, Date) {
        let quantum: TimeInterval = 30 * 60
        let start = Date(timeIntervalSince1970: floor(from.timeIntervalSince1970 / quantum) * quantum)
        let end = Date(timeIntervalSince1970: ceil(to.timeIntervalSince1970 / quantum) * quantum)
        return (start, max(end, start.addingTimeInterval(quantum)))
    }

    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        let (queryFrom, queryTo) = Self.quantizedBounds(from: from, to: to)
        let minTime = Self.isoFormatter.string(from: queryFrom)
        let maxTime = Self.isoFormatter.string(from: queryTo)
        var events: [MeetingEvent] = []
        for id in calendarIDs.sorted() {
            let path = "calendars/\(id.addingPercentEncoding(withAllowedCharacters: Self.calendarIDAllowed) ?? id)/events"
            do {
                let items = try await pages(path, ["timeMin": minTime, "timeMax": maxTime,
                                                   "singleEvents": "true", "orderBy": "startTime"])
                events += items.compactMap { Self.event($0, calendarID: id) }
            } catch let failure as GoogleAPIFailure where failure.status == 404 {
                continue  // Unsubscribed since it was selected; the others still count.
            }
        }
        return events.sorted { $0.start < $1.start }
    }

    static func event(_ item: [String: Any], calendarID: String) -> MeetingEvent? {
        // Working location, out-of-office and focus blocks are not meetings.
        if let type = item["eventType"] as? String, !["default", "fromGmail"].contains(type) { return nil }
        guard let id = item["id"] as? String,
              let (start, allDay) = time(item["start"]), let (end, _) = time(item["end"]) else { return nil }
        let attendees = (item["attendees"] as? [[String: Any]] ?? []).filter { $0["resource"] as? Bool != true }
        let me = attendees.first { $0["self"] as? Bool == true }
        let video = ((item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? [])
            .filter { $0["entryPointType"] as? String == "video" }.compactMap { $0["uri"] as? String }
        let text = ([item["hangoutLink"] as? String] + video + [item["location"] as? String, item["description"] as? String])
            .compactMap { $0 }.joined(separator: "\n")
        return MeetingEvent(id: "google/\(calendarID)/\(id)", calendarID: calendarID,
                            title: item["summary"] as? String ?? "Meeting", start: start, end: end,
                            attendees: attendees.compactMap { $0["displayName"] as? String ?? $0["email"] as? String },
                            joinURL: MacMeetingCalendar.meetingURL(in: text), allDay: allDay,
                            declined: me?["responseStatus"] as? String == "declined",
                            cancelled: item["status"] as? String == "cancelled")
    }
    private static func time(_ value: Any?) -> (Date, Bool)? {
        guard let value = value as? [String: Any] else { return nil }
        if let text = value["dateTime"] as? String {
            if let date = isoFormatter.date(from: text) ?? isoFractionalFormatter.date(from: text) {
                return (date, false)
            }
            return nil
        }
        if let text = value["date"] as? String {
            allDayFormatter.timeZone = .current
            return allDayFormatter.date(from: text).map { ($0, true) }
        }
        return nil
    }

    private enum PageResponse {
        case notModified
        case modified(json: [String: Any], etag: String?)
    }

    private static func etagCacheKey(path: String, query: [String: String]) -> String {
        let sortedQuery = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(path)?\(sortedQuery)"
    }

    private func pages(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
        let baseParameters = query.merging(["maxResults": "250"]) { a, _ in a }
        let cacheKey = Self.etagCacheKey(path: path, query: baseParameters)
        let cachedEntry = etagCache[cacheKey]

        var items: [[String: Any]] = [], pageToken: String?
        var firstPageETag: String?
        var pageCount = 0
        repeat {
            var parameters = baseParameters
            if let pageToken { parameters["pageToken"] = pageToken }
            let ifNoneMatch = (pageToken == nil) ? cachedEntry?.etag : nil
            switch try await get(path, parameters, ifNoneMatch: ifNoneMatch) {
            case .notModified:
                if let cachedEntry {
                    return cachedEntry.items
                }
                // Defensive fallback if 304 arrived without a matching local entry.
                let fresh = try await get(path, parameters, ifNoneMatch: nil)
                guard case .modified(let page, let etag) = fresh else { return [] }
                items += page["items"] as? [[String: Any]] ?? []
                pageToken = page["nextPageToken"] as? String
                if pageCount == 0 { firstPageETag = etag }
            case .modified(let page, let etag):
                items += page["items"] as? [[String: Any]] ?? []
                pageToken = page["nextPageToken"] as? String
                if pageCount == 0 { firstPageETag = etag }
            }
            pageCount += 1
        } while pageToken != nil && items.count < 5000

        if pageCount == 1, let etag = firstPageETag, !etag.isEmpty {
            if etagCache.count >= Self.maxETagCacheEntries, etagCache[cacheKey] == nil {
                etagCache.removeAll(keepingCapacity: true)
            }
            etagCache[cacheKey] = ETagCacheEntry(etag: etag, items: items)
        } else {
            etagCache.removeValue(forKey: cacheKey)
        }
        return items
    }
    private func get(_ path: String, _ query: [String: String], ifNoneMatch: String? = nil, retried: Bool = false) async throws -> PageResponse {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        components.percentEncodedPath = "/calendar/v3/\(path)"
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await http.send(request)
        if response.statusCode == 304 {
            return .notModified
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if response.statusCode == 401, !retried { auth.expire(); return try await get(path, query, ifNoneMatch: ifNoneMatch, retried: true) }
        guard (200..<300).contains(response.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            if response.statusCode == 403, message?.localizedCaseInsensitiveContains("insufficient") == true {
                throw MeetingFailure("FlowClone needs permission to see your calendar events. Sign out, sign in again and keep the Calendar box ticked.")
            }
            throw GoogleAPIFailure(status: response.statusCode, message: message)
        }
        let etag = response.value(forHTTPHeaderField: "ETag") ?? (json["etag"] as? String)
        return .modified(json: json, etag: etag)
    }
}
struct GoogleAPIFailure: LocalizedError, Sendable {
    let status: Int
    let message: String?
    var errorDescription: String? { "Google Calendar returned an error (\(status))\(message.map { ": \($0)" } ?? "")." }
}
