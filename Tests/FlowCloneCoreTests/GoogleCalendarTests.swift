import XCTest
@testable import FlowCloneCore

private final class FakeGoogle: GoogleHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) -> (Int, Any) = { _ in (500, [:]) }
    var requests: [URLRequest] { lock.withLock { _requests } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}
private final class MemoryStore: GoogleSessionStoring, @unchecked Sendable {
    var session: GoogleSession?
    func load() -> GoogleSession? { session }
    func save(_ session: GoogleSession) -> Bool { self.session = session; return true }
    func clear() { session = nil }
}
private func form(_ request: URLRequest) -> [String: String] {
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    })
}
private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
private func idToken(email: String) -> String {
    let payload = PKCE.base64URL(try! JSONSerialization.data(withJSONObject: ["email": email, "sub": "1"]))
    return "eyJhbGciOiJSUzI1NiJ9.\(payload).signature"
}
private let client = GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com")
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
nonisolated(unsafe) private let calendarPage1: [String: Any] = ["items": [["id": "team@group.calendar.google.com", "summary": "Team"]], "nextPageToken": "p2"]
nonisolated(unsafe) private let calendarPage2: [String: Any] = ["items": [["id": "andre@example.com", "summary": "andre@example.com", "primary": true]]]
/// Shapes the Calendar API returns: a Meet link with no guests, a recurring instance with a Zoom
/// add-on, a declined self and a room, cancelled, all-day, working location, and a lookalike link.
nonisolated(unsafe) private let eventFixtures: [[String: Any]] = [
    ["id": "meet", "summary": "Design review", "status": "confirmed",
     "start": ["dateTime": "2026-11-09T10:00:00-06:00"], "end": ["dateTime": "2026-11-09T10:30:00-06:00"],
     "hangoutLink": "https://meet.google.com/abc-defg-hij"],
    ["id": "weekly_20261109T170000Z", "summary": "Weekly",
     "start": ["dateTime": "2026-11-09T11:00:00-06:00"], "end": ["dateTime": "2026-11-09T11:30:00-06:00"],
     "conferenceData": ["entryPoints": [["entryPointType": "phone", "uri": "tel:+1"] as [String: Any],
                                        ["entryPointType": "video", "uri": "https://us02web.zoom.us/j/123"]]] as [String: Any],
     "attendees": [["email": "andre@example.com", "self": true, "responseStatus": "declined"] as [String: Any],
                   ["email": "maya@example.com"], ["email": "room@resource.calendar.google.com", "resource": true]]],
    ["id": "gone", "status": "cancelled",
     "start": ["dateTime": "2026-11-09T12:00:00Z"], "end": ["dateTime": "2026-11-09T13:00:00Z"]],
    ["id": "holiday", "summary": "Holiday", "start": ["date": "2026-11-11"], "end": ["date": "2026-11-12"]],
    ["id": "home", "eventType": "workingLocation", "start": ["date": "2026-11-09"], "end": ["date": "2026-11-10"]],
    ["id": "lookalike", "summary": "Phish", "location": "https://meet.google.com.evil.example/x",
     "start": ["dateTime": "2026-11-09T14:00:00Z"], "end": ["dateTime": "2026-11-09T15:00:00Z"]],
]

@MainActor final class GoogleCalendarTests: XCTestCase {
    func testPKCEMatchesRFC7636AndRedirectIsTheReversedClientID() {
        XCTAssertEqual(PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(client.redirectURI, "com.googleusercontent.apps.123-abc:/oauth2redirect")
        let defaults = UserDefaults(suiteName: ScratchDefaults.name("google-client"))!
        XCTAssertNil(GoogleOAuthClient.configured(info: ["FlowCloneGoogleClientID": ""], defaults: defaults))
        XCTAssertNil(GoogleOAuthClient.configured(info: ["FlowCloneGoogleClientID": "not-a-client"], defaults: defaults))
        XCTAssertEqual(GoogleOAuthClient.configured(info: ["FlowCloneGoogleClientID": client.clientID], defaults: defaults), client)
        defaults.set("999-z.apps.googleusercontent.com", forKey: "meetingGoogleClientID")
        XCTAssertEqual(GoogleOAuthClient.configured(info: ["FlowCloneGoogleClientID": client.clientID], defaults: defaults)?.clientID,
                       "999-z.apps.googleusercontent.com")
    }

    func testBrowserSignInExchangesTheCodeWithPKCEAndKeepsOnlyTheRefreshToken() async throws {
        let http = FakeGoogle(), store = MemoryStore()
        var opened: URL?
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store, present: { url, scheme in
            opened = url
            XCTAssertEqual(scheme, "com.googleusercontent.apps.123-abc")
            return URL(string: "\(scheme):/oauth2redirect?state=\(query(url)["state"]!)&code=4%2Fcode&scope=x")!
        })
        http.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            return (200, ["access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3599, "token_type": "Bearer",
                          "scope": "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/calendar.readonly",
                          "id_token": idToken(email: "andre@example.com")])
        }
        try await auth.signIn()
        let sent = try XCTUnwrap(opened.map(query))
        XCTAssertEqual(sent["client_id"], client.clientID)
        XCTAssertEqual(sent["redirect_uri"], client.redirectURI)
        XCTAssertEqual(sent["code_challenge_method"], "S256")
        XCTAssertTrue(sent["scope"]!.contains("calendar.readonly"))
        XCTAssertFalse(sent["scope"]!.contains("calendar.events"), "Read-only: nothing is ever written to Google")
        let exchange = form(try XCTUnwrap(http.requests.first))
        XCTAssertEqual(exchange["code"], "4/code")
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(PKCE.challenge(try XCTUnwrap(exchange["code_verifier"])), sent["code_challenge"])
        XCTAssertNil(exchange["client_secret"], "No secret ships in the app")
        XCTAssertEqual(store.session, GoogleSession(refreshToken: "refresh-1", email: "andre@example.com"))
        XCTAssertEqual(auth.email, "andre@example.com")
        let token = try await auth.token()
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(http.requests.count, 1, "A fresh access token is reused, not refreshed")
    }

    func testSignInRejectsForgedStateCancellationAndUntickedCalendarPermission() async {
        let http = FakeGoogle(), store = MemoryStore()
        final class Reply { var make: (URL) -> String = { _ in "state=wrong&code=c" } }
        let reply = Reply()
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store, present: { url, scheme in
            URL(string: "\(scheme):/oauth2redirect?\(reply.make(url))")!
        })
        await XCTAssertThrowsAsync(try await auth.signIn(), contains: "unexpected response")
        reply.make = { "state=\(query($0)["state"]!)&error=access_denied" }
        await XCTAssertThrowsAsync(try await auth.signIn(), contains: "cancelled")
        reply.make = { "state=\(query($0)["state"]!)&code=c" }
        http.handler = { _ in (200, ["access_token": "a", "refresh_token": "r", "scope": "openid email"]) }
        await XCTAssertThrowsAsync(try await auth.signIn(), contains: "Calendar box ticked")
        XCTAssertNil(store.session)
        let unconfigured = GoogleAuthorizer(client: { nil }, http: http, store: store, present: { _, _ in XCTFail("no browser"); return URL(string: "x:/")! })
        await XCTAssertThrowsAsync(try await unconfigured.signIn(), contains: "OAuth client ID")
    }

    func testExpiredAccessRefreshesAndRevokedAccessSignsOut() async throws {
        let http = FakeGoogle(), store = MemoryStore()
        store.session = GoogleSession(refreshToken: "refresh-1", email: "andre@example.com")
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store, present: { _, _ in XCTFail("no browser"); return URL(string: "x:/")! })
        http.handler = { request in
            let fields = form(request)
            XCTAssertEqual(fields["grant_type"], "refresh_token")
            XCTAssertEqual(fields["refresh_token"], "refresh-1")
            return (200, ["access_token": "access-2", "expires_in": 3599])
        }
        let refreshed = try await auth.token()
        XCTAssertEqual(refreshed, "access-2")
        http.handler = { _ in (400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."]) }
        auth.expire()
        await XCTAssertThrowsAsync(try await auth.token(), contains: "Sign in with Google again")
        XCTAssertNil(store.session)
        XCTAssertNil(auth.email)
    }

    func testCalendarAPIMapsRealGoogleEventShapes() async throws {
        let http = FakeGoogle(), store = MemoryStore()
        store.session = GoogleSession(refreshToken: "refresh-1", email: "andre@example.com")
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store, present: { _, _ in URL(string: "x:/")! })
        let calendar = GoogleMeetingCalendar(auth: auth, http: http)
        let state = OnceFlag()
        http.handler = { request in
            let url = request.url!
            if url.host == "oauth2.googleapis.com" { return (200, ["access_token": "access", "expires_in": 3599]) }
            if state.first() { return (401, ["error": ["message": "Invalid Credentials"]]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            if url.path == "/calendar/v3/users/me/calendarList" {
                return (200, query(url)["pageToken"] == nil ? calendarPage1 : calendarPage2)
            }
            XCTAssertEqual(url.path, "/calendar/v3/calendars/andre@example.com/events")
            XCTAssertTrue(url.absoluteString.contains("andre%40example.com"), "Calendar IDs are escaped in the path")
            XCTAssertEqual(query(url)["singleEvents"], "true")
            return (200, ["items": eventFixtures])
        }
        let calendars = try await calendar.calendars()
        XCTAssertEqual(calendars.map(\.id), ["andre@example.com", "team@group.calendar.google.com"], "Primary first, all pages read")
        XCTAssertEqual(calendars.first?.primary, true)
        let events = try await calendar.events(calendarIDs: ["andre@example.com"], from: Date(), to: Date().addingTimeInterval(86400))
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id.components(separatedBy: "/").last!, $0) })
        XCTAssertNil(byID["home"], "Working-location blocks are not meetings")
        let meet = try XCTUnwrap(byID["meet"])
        XCTAssertEqual(meet.joinURL?.host, "meet.google.com")
        XCTAssertTrue(meet.isAutomaticEligible, "A Meet link alone (no guests) qualifies")
        XCTAssertEqual(meet.end.timeIntervalSince(meet.start), 1800)
        XCTAssertEqual(meet.id, "google/andre@example.com/meet")
        let weekly = try XCTUnwrap(byID["weekly_20261109T170000Z"])
        XCTAssertEqual(weekly.joinURL?.host, "us02web.zoom.us")
        XCTAssertEqual(weekly.attendees, ["andre@example.com", "maya@example.com"], "Rooms are not people")
        XCTAssertTrue(weekly.declined)
        XCTAssertFalse(weekly.isEligible)
        XCTAssertTrue(try XCTUnwrap(byID["gone"]).cancelled)
        XCTAssertTrue(try XCTUnwrap(byID["holiday"]).allDay)
        XCTAssertNil(try XCTUnwrap(byID["lookalike"]).joinURL)
        XCTAssertFalse(try XCTUnwrap(byID["lookalike"]).isAutomaticEligible)
    }

    func testTokenRefreshPersistsRotatedRefreshTokenAndCoalescesConcurrentRequests() async throws {
        final class SlowRefreshHTTP: GoogleHTTP, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            var refreshCalls: Int { lock.withLock { calls } }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let n = lock.withLock { () -> Int in calls += 1; return calls }
                let fields = form(request)
                try await Task.sleep(for: .milliseconds(35))
                let body: [String: Any]
                if n == 1 {
                    XCTAssertEqual(fields["refresh_token"], "refresh-initial")
                    body = ["access_token": "access-coalesced", "refresh_token": "refresh-rotated", "expires_in": 3599]
                } else {
                    XCTAssertEqual(fields["refresh_token"], "refresh-rotated")
                    body = ["access_token": "access-after-rotation", "expires_in": 3599]
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (try JSONSerialization.data(withJSONObject: body), response)
            }
        }

        let http = SlowRefreshHTTP(), store = MemoryStore()
        store.session = GoogleSession(refreshToken: "refresh-initial", email: "andre@example.com")
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store,
                                    present: { _, _ in XCTFail("no browser"); return URL(string: "x:/")! })

        async let t1 = auth.token()
        async let t2 = auth.token()
        async let t3 = auth.token()
        async let t4 = auth.token()
        async let t5 = auth.token()
        let tokens = try await [t1, t2, t3, t4, t5]
        XCTAssertEqual(tokens, Array(repeating: "access-coalesced", count: 5))
        XCTAssertEqual(http.refreshCalls, 1, "Concurrent callers share one in-flight refresh request")
        XCTAssertEqual(store.session?.refreshToken, "refresh-rotated")
        XCTAssertEqual(store.session?.email, "andre@example.com")

        auth.expire()
        let second = try await auth.token()
        XCTAssertEqual(second, "access-after-rotation")
        XCTAssertEqual(http.refreshCalls, 2)
        XCTAssertEqual(store.session?.refreshToken, "refresh-rotated")
    }

    func testCalendarListCachesForThirtyMinutesAndUsesETagNotModified() async throws {
        final class ETagGoogleHTTP: GoogleHTTP, @unchecked Sendable {
            private let lock = NSLock()
            private var _requests: [URLRequest] = []
            var requests: [URLRequest] { lock.withLock { _requests } }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lock.withLock { _requests.append(request) }
                let url = request.url!
                if url.host == "oauth2.googleapis.com" {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (try JSONSerialization.data(withJSONObject: ["access_token": "tok", "expires_in": 3599]), resp)
                }
                if url.path == "/calendar/v3/users/me/calendarList" {
                    if request.value(forHTTPHeaderField: "If-None-Match") == "\"cal-etag-1\"" {
                        let resp = HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: ["ETag": "\"cal-etag-1\""])!
                        return (Data(), resp)
                    }
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"cal-etag-1\""])!
                    let body: [String: Any] = ["items": [["id": "andre@example.com", "summary": "Primary", "primary": true]]]
                    return (try JSONSerialization.data(withJSONObject: body), resp)
                }
                if request.value(forHTTPHeaderField: "If-None-Match") == "\"evt-etag-1\"" {
                    let resp = HTTPURLResponse(url: url, statusCode: 304, httpVersion: nil, headerFields: ["ETag": "\"evt-etag-1\""])!
                    return (Data(), resp)
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"evt-etag-1\""])!
                return (try JSONSerialization.data(withJSONObject: ["items": eventFixtures]), resp)
            }
        }

        final class ClockBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSince1970: 1_800_000_000)
            func now() -> Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
        }

        let http = ETagGoogleHTTP(), store = MemoryStore(), clock = ClockBox()
        store.session = GoogleSession(refreshToken: "refresh-1", email: "andre@example.com")
        let auth = GoogleAuthorizer(client: { client }, http: http, store: store, present: { _, _ in URL(string: "x:/")! })
        let calendar = GoogleMeetingCalendar(auth: auth, http: http, clock: { clock.now() })

        // First call hits network; second call within 30 minutes hits in-memory TTL cache (0 extra requests).
        let cals1 = try await calendar.calendars()
        XCTAssertEqual(cals1.map(\.id), ["andre@example.com"])
        let calListReqs1 = http.requests.filter { $0.url?.path == "/calendar/v3/users/me/calendarList" }
        XCTAssertEqual(calListReqs1.count, 1)

        clock.advance(10 * 60)
        let cals2 = try await calendar.calendars()
        XCTAssertEqual(cals2, cals1)
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/calendar/v3/users/me/calendarList" }.count, 1)

        // After 30-min TTL expiry, sends If-None-Match and reuses cached items on 304 Not Modified.
        clock.advance(25 * 60)
        let cals3 = try await calendar.calendars()
        XCTAssertEqual(cals3, cals1)
        let calListReqs2 = http.requests.filter { $0.url?.path == "/calendar/v3/users/me/calendarList" }
        XCTAssertEqual(calListReqs2.count, 2)
        XCTAssertEqual(calListReqs2.last?.value(forHTTPHeaderField: "If-None-Match"), "\"cal-etag-1\"")

        // Events within same 30-minute quantized window send If-None-Match and reuse items on 304.
        let t0 = clock.now()
        let ev1 = try await calendar.events(calendarIDs: ["andre@example.com"], from: t0, to: t0.addingTimeInterval(7 * 86400))
        let ev2 = try await calendar.events(calendarIDs: ["andre@example.com"], from: t0.addingTimeInterval(60), to: t0.addingTimeInterval(7 * 86400 + 60))
        XCTAssertEqual(ev1, ev2)
        let evtReqs = http.requests.filter { $0.url?.path == "/calendar/v3/calendars/andre@example.com/events" }
        XCTAssertEqual(evtReqs.count, 2)
        XCTAssertNil(evtReqs[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(evtReqs[1].value(forHTTPHeaderField: "If-None-Match"), "\"evt-etag-1\"")
    }
}

@MainActor func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, contains text: String,
                                     file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error containing \(text)", file: file, line: line) }
    catch { XCTAssertTrue(error.localizedDescription.contains(text), "\(error.localizedDescription)", file: file, line: line) }
}
