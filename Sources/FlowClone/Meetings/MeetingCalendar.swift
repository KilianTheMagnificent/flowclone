import EventKit
import Foundation

/// Routes to Google (signed in through the browser) or macOS Calendar, remembering the choice.
@MainActor final class MeetingCalendarSources: MeetingCalendarProviding {
    let google: GoogleMeetingCalendar
    let mac: MacMeetingCalendar
    private let defaults: UserDefaults
    private(set) var source: MeetingCalendarSource
    init(google: GoogleMeetingCalendar = GoogleMeetingCalendar(), mac: MacMeetingCalendar = MacMeetingCalendar(),
         defaults: UserDefaults = .standard) {
        self.google = google; self.mac = mac; self.defaults = defaults
        source = MeetingCalendarSource(rawValue: defaults.string(forKey: "meetingCalendarSource") ?? "") ?? .google
    }
    private var active: any MeetingCalendarBackend { source == .google ? google : mac }
    var account: String? { source == .google ? google.auth.email : nil }
    func connect(_ source: MeetingCalendarSource) async throws {
        try await (source == .google ? google as any MeetingCalendarBackend : mac).connect()
        self.source = source
        defaults.set(source.rawValue, forKey: "meetingCalendarSource")
    }
    func disconnect() async {
        if source == .google {
            google.invalidateCaches()
            await google.auth.signOut()
        }
    }
    func calendars() async throws -> [MeetingCalendar] { try await active.calendars() }
    func calendars(forceRefresh: Bool) async throws -> [MeetingCalendar] {
        if source == .google {
            return try await google.calendars(forceRefresh: forceRefresh)
        }
        return try await mac.calendars()
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        try await active.events(calendarIDs: calendarIDs, from: from, to: to)
    }
}

/// Calendars already in macOS Calendar (including accounts added in Internet Accounts).
/// Only selected calendars are queried; no writes.
@MainActor final class MacMeetingCalendar: MeetingCalendarBackend {
    private let store = EKEventStore()
    func connect() async throws {
        guard !suppressHostAccess else { throw MeetingFailure("Calendar permission is disabled in the test session.") }
        log("meeting calendar: requesting access; authorization=\(EKEventStore.authorizationStatus(for: .event).rawValue)")
        do {
            let granted = try await store.requestFullAccessToEvents()
            log("meeting calendar: access result=\(granted); authorization=\(EKEventStore.authorizationStatus(for: .event).rawValue)")
            guard granted else { throw accessFailure() }
        } catch {
            let failure = error as NSError
            log("meeting calendar: connection failed domain=\(failure.domain) code=\(failure.code)")
            throw error
        }
    }
    private func accessFailure() -> MeetingFailure {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .writeOnly:
            return MeetingFailure("Allow FlowClone full access in System Settings → Privacy & Security → Calendars, then reconnect.")
        case .restricted:
            return MeetingFailure("Calendar access is restricted.")
        default:
            return MeetingFailure("Click Connect calendars, then allow full Calendar access in the macOS permission dialog.")
        }
    }
    private func checkAccess() throws {
        guard !suppressHostAccess, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw accessFailure()
        }
    }
    func calendars() async throws -> [MeetingCalendar] {
        try checkAccess()
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map {
            MeetingCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title,
                            primary: $0.calendarIdentifier == defaultID)
        }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }
    func events(calendarIDs: Set<String>, from: Date, to: Date) async throws -> [MeetingEvent] {
        try checkAccess()
        let selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
        return store.events(matching: predicate).compactMap { event in
            Self.makeEvent(
                calendarIdentifier: event.calendar?.calendarIdentifier,
                itemIdentifier: event.calendarItemIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                occurrenceDate: event.occurrenceDate,
                attendees: (event.attendees ?? []).map {
                    (name: $0.name, url: $0.url, isCurrentUser: $0.isCurrentUser,
                     declined: $0.participantStatus == .declined)
                },
                eventURL: event.url,
                location: event.location,
                notes: event.notes,
                isAllDay: event.isAllDay,
                isCancelled: event.status == .canceled)
        }.sorted { $0.start < $1.start }
    }

    static func attendeeIdentifier(name: String?, url: URL?) -> String? {
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        guard let raw = url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let withoutScheme: String
        if raw.lowercased().hasPrefix("mailto:") {
            withoutScheme = String(raw.dropFirst("mailto:".count))
        } else {
            withoutScheme = raw
        }
        let base = withoutScheme.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutScheme
        let decoded = (base.removingPercentEncoding ?? base).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    static func makeEvent(
        calendarIdentifier: String?, itemIdentifier: String, title: String?,
        startDate: Date?, endDate: Date?, occurrenceDate: Date?,
        attendees: [(name: String?, url: URL?, isCurrentUser: Bool, declined: Bool)],
        eventURL: URL?, location: String?, notes: String?,
        isAllDay: Bool, isCancelled: Bool
    ) -> MeetingEvent? {
        guard let calendarID = calendarIdentifier, !calendarID.isEmpty,
              let start = startDate, let end = endDate else { return nil }
        let occurrence = occurrenceDate ?? start
        let id = "\(calendarID)/\(itemIdentifier)/\(occurrence.timeIntervalSince1970)"
        let me = attendees.first(where: \.isCurrentUser)
        let names = attendees.compactMap { attendeeIdentifier(name: $0.name, url: $0.url) }
        return MeetingEvent(
            id: id, calendarID: calendarID,
            title: title ?? "Meeting", start: start, end: end,
            attendees: names,
            joinURL: meetingURL(in: [eventURL?.absoluteString, location, notes].compactMap { $0 }.joined(separator: "\n")),
            allDay: isAllDay, declined: me?.declined ?? false,
            cancelled: isCancelled)
    }
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let conferenceHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]
    static func meetingURL(in text: String) -> URL? {
        guard text.range(of: "https://", options: .caseInsensitive) != nil, let detector = linkDetector else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
            return conferenceHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}
