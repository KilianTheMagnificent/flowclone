import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsPage: View {
    var meetings: MeetingCoordinator
    @State private var tab: String
    @State private var deleting = false
    @State private var dropTargeted = false
    @State private var sidebarWidth: CGFloat = 340
    @State private var dragStartWidth: CGFloat?

    init(meetings: MeetingCoordinator = .shared, initialTab: String = "Summary") {
        self.meetings = meetings
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            MeetingsSidebarPane(meetings: meetings, selectNote: selectNote, importAudio: presentAudioImporter)
                .frame(width: sidebarWidth)
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .contentShape(Rectangle().inset(by: -3))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = dragStartWidth ?? sidebarWidth
                            if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                            sidebarWidth = min(390, max(290, base + value.translation.width))
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
            MeetingDetailPane(meetings: meetings, tab: $tab, requestDelete: { deleting = true })
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleAudioDrop(providers)
        }
        .onAppear { meetings.load() }
        .onDisappear { meetings.flushPendingSaves() }
        .confirmationDialog("Delete this meeting and its saved audio?", isPresented: $deleting) {
            Button("Delete meeting", role: .destructive) {
                if let id = meetings.selectedNoteID { meetings.delete(id) }
            }
        }
    }

    private func selectNote(_ id: UUID, preferredTab: String) {
        meetings.selectedNoteID = id
        if tab != preferredTab { tab = preferredTab }
    }

    private func presentAudioImporter() {
        guard !handsfreeSession else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Meeting Audio"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .mpeg4Audio, .mp3, .wav, .mpeg4Movie
        ]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let id = await meetings.importAudioFile(at: url) {
                    selectNote(id, preferredTab: "Summary")
                }
            }
        }
    }

    private func handleAudioDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let resolvedURL: URL? = {
                if let url = item as? URL { return url }
                if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                if let str = item as? String { return URL(string: str) }
                return nil
            }()
            guard let url = resolvedURL else { return }
            Task { @MainActor in
                if let id = await meetings.importAudioFile(at: url) {
                    selectNote(id, preferredTab: "Summary")
                }
            }
        }
        return true
    }

    nonisolated static func writeExportedMarkdown(_ markdown: String, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: Data(markdown.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

// MARK: - Cached Date Formatting

@MainActor private enum MeetingsDateFormat {
    private static let abbreviatedDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    private static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateTime(_ date: Date) -> String { abbreviatedDateTime.string(from: date) }
    static func time(_ date: Date) -> String { shortTime.string(from: date) }
}

// MARK: - Left Sidebar (Isolated Observation Scopes)

private struct MeetingsSidebarPane: View {
    let meetings: MeetingCoordinator
    let selectNote: (UUID, String) -> Void
    let importAudio: () -> Void
    @State private var inPersonTitle = ""

    private func startInPerson() {
        let title = inPersonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let id = await meetings.startInPersonMeeting(title: title.isEmpty ? MeetingEvent.defaultInPersonTitle : title) {
                inPersonTitle = ""
                selectNote(id, "Transcript")
            }
        }
    }

    private func startCallMeeting() {
        let title = inPersonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let id = await meetings.startAdHocMeeting(title: title.isEmpty ? MeetingEvent.defaultAdHocTitle : title) {
                inPersonTitle = ""
                selectNote(id, "Transcript")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Meetings")
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Client or meeting name (optional)", text: $inPersonTitle)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("inPersonMeetingTitle")
                        .onSubmit {
                            guard !meetings.busy && !meetings.isImporting else { return }
                            startInPerson()
                        }
                    HStack(spacing: 8) {
                        Button(action: startInPerson) {
                            Label("In-Person", systemImage: "person.2.wave.2")
                        }
                        .prominent()
                        .disabled(meetings.busy || meetings.isImporting)
                        .accessibilityIdentifier("inPersonMeetingButton")
                        Button(action: startCallMeeting) {
                            Label("New Meeting", systemImage: "record.circle")
                        }
                        .disabled(meetings.busy || meetings.isImporting)
                        .accessibilityIdentifier("newMeetingButton")
                    }
                    HStack(spacing: 8) {
                        Button("Import Audio…", action: importAudio)
                            .disabled(meetings.isImporting)
                            .accessibilityIdentifier("importMeetingAudioButton")
                        Spacer()
                    }
                    Text("In-Person records room voices using only your microphone — no screen-recording setup needed.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                MeetingsStatusHeader(meetings: meetings, selectNote: selectNote)
                MeetingsCalendarCard(meetings: meetings)
                UpcomingMeetingsCard(meetings: meetings)
                PastNotesCard(meetings: meetings, selectNote: selectNote)
            }
            .padding(22)
        }
    }
}

private struct MeetingsStatusHeader: View {
    let meetings: MeetingCoordinator
    let selectNote: (UUID, String) -> Void

    var body: some View {
        if !meetings.status.isEmpty {
            Text(meetings.status)
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .accessibilityIdentifier("meetingStatus")
        }
        if let error = meetings.error {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
        if let countdown = meetings.countdown {
            SectionCard("Starting soon") {
                Text(countdown.title)
                Button("Skip this meeting") { meetings.dismiss(countdown) }
            }
        }
        if let active = meetings.activeNote {
            SectionCard("Recording") {
                Label(active.event.title, systemImage: "record.circle.fill").foregroundStyle(.red)
                Text(active.isInPerson
                     ? "In-person · microphone only"
                     : (active.event.isAdHoc
                        ? "Microphone + system audio"
                        : "Microphone + system audio · until \(MeetingsDateFormat.time(active.event.end))"))
                    .font(.caption)
                Button("Stop and summarize") { Task { await meetings.stop() } }
                    .disabled(meetings.isStopping)
                    .accessibilityIdentifier("stopMeeting")
                Button("Open live transcript") { selectNote(active.id, "Transcript") }
            }
        }
    }
}

private struct MeetingsCalendarCard: View {
    @Bindable var meetings: MeetingCoordinator

    private var googleSignInTitle: String {
        if meetings.connecting { return "Connecting…" }
        if case .googleSignIn = meetings.recordingAttention { return "Reconnect Google Calendar" }
        return "Sign in with Google"
    }

    var body: some View {
        SectionCard("Calendars") {
            if meetings.calendarSource == .google, let account = meetings.account {
                Label("Signed in as \(account)", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("googleAccount")
                HStack(spacing: 8) {
                    Button("Sign out of Google") { Task { await meetings.disconnect() } }
                    Button("Switch to Apple Calendar") { Task { await meetings.connect(.mac) } }
                        .disabled(meetings.connecting)
                }
            } else if meetings.calendarSource == .mac, meetings.connected {
                Label("Connected to Apple Calendar (macOS)", systemImage: "checkmark.circle.fill")
                    .accessibilityIdentifier("appleCalendarConnected")
                Text("Reads macOS Calendar locally — never expires and requires no OAuth sign-in.")
                    .font(.caption).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Button("Disconnect") { Task { await meetings.disconnect() } }
                    Button("Sign in with Google instead") { Task { await meetings.connect(.google) } }
                        .disabled(meetings.connecting)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button(googleSignInTitle) {
                        Task { await meetings.connect(.google) }
                    }
                    .disabled(meetings.connecting)
                    .accessibilityIdentifier("googleSignIn")
                    Button("Connect Apple Calendar") {
                        Task { await meetings.connect(.mac) }
                    }
                    .disabled(meetings.connecting)
                    .accessibilityIdentifier("appleCalendarConnect")
                    Text("Apple Calendar reads your Mac’s Calendar app directly (including synced Google/iCloud accounts) with zero sign-in expiry.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            ForEach(meetings.calendars) { calendar in
                Toggle(meetings.calendarSource == .google ? calendar.title : "\(calendar.account) · \(calendar.title)", isOn: Binding(get: {
                    meetings.selectedCalendars.contains(calendar.id)
                }, set: { selected in
                    if selected { meetings.selectedCalendars.insert(calendar.id) }
                    else { meetings.selectedCalendars.remove(calendar.id) }
                    meetings.saveSettings(); Task { await meetings.refresh() }
                }))
            }
            if meetings.connected { Button("Refresh calendar") { Task { await meetings.refresh() } } }
            Divider()
            Toggle("Automatically record when I join a call", isOn: $meetings.autoDetectCalls)
                .accessibilityIdentifier("autoDetectCallsToggle")
                .onChange(of: meetings.autoDetectCalls) { _, _ in meetings.saveSettings() }
            Text("Detects live calls in Zoom, Google Meet, Teams, Slack, FaceTime, and browsers with no setup.")
                .font(.caption).foregroundStyle(Theme.muted)
            Toggle("Participants have agreed to transcription", isOn: $meetings.consentConfirmed)
                .onChange(of: meetings.consentConfirmed) { _, _ in meetings.saveSettings() }
            Toggle("Automatically record scheduled meetings", isOn: $meetings.autoStart)
                .disabled(!meetings.consentConfirmed)
                .onChange(of: meetings.autoStart) { _, _ in meetings.saveSettings() }
            if (meetings.autoStart || meetings.autoDetectCalls), !meetings.systemAudioAllowed {
                Label("FlowClone can’t record meeting audio yet", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("systemAudioWarning")
                Text("Turn on FlowClone in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen FlowClone.")
                    .font(.caption).foregroundStyle(Theme.muted)
                Button("Open Privacy Settings") {
                    guard !handsfreeSession else { return }
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text("Summary model").font(.callout).foregroundStyle(Theme.muted)
                ThemedMenuPicker(
                    label: "Summary model",
                    options: MeetingSummaryModel.allCases.map { ($0, $0.label) },
                    selection: Binding(
                        get: { meetings.summaryModel },
                        set: { meetings.setSummaryModel($0) }
                    )
                )
                .accessibilityIdentifier("meetingSummaryModel")
            }
            Text(meetings.summaryModel.caption)
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

private struct UpcomingMeetingsCard: View {
    let meetings: MeetingCoordinator
    @State private var showAll = false
    private static let collapsedLimit = 8

    var body: some View {
        let now = Date()
        let eligible = Array(meetings.upcoming.filter { $0.end > now }.prefix(30))
        let visible = showAll ? eligible : Array(eligible.prefix(Self.collapsedLimit))
        SectionCard("Upcoming") {
            if meetings.upcoming.isEmpty {
                Text("No upcoming meetings").foregroundStyle(Theme.muted)
            }
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(visible) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.title).font(.headline)
                        Text(MeetingsDateFormat.dateTime(event.start)).font(.caption).foregroundStyle(Theme.muted)
                        HStack {
                            Button("Record") { Task { await meetings.start(event) } }
                                .disabled(meetings.busy || !meetings.consentConfirmed || meetings.alreadyRecorded(event))
                            if let url = event.joinURL {
                                Button("Join") {
                                    guard !handsfreeSession else { return }
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        if meetings.autoStart, meetings.consentConfirmed {
                            Toggle("Record automatically", isOn: Binding(
                                get: { meetings.automatic(event) },
                                set: { meetings.setAutomatic(event, $0) }
                            ))
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if eligible.count > Self.collapsedLimit {
                Button(showAll ? "Show fewer upcoming" : "Show all \(eligible.count) upcoming") {
                    showAll.toggle()
                }
                .font(.caption)
            }
        }
    }
}

private struct PastNotesCard: View {
    let meetings: MeetingCoordinator
    let selectNote: (UUID, String) -> Void
    @State private var searchQuery = ""

    var body: some View {
        let selectedID = meetings.selectedNoteID
        let theme = Theme.current
        let visibleNotes = meetings.filteredNotes(matching: searchQuery)
        SectionCard("Past notes") {
            if meetings.notes.isEmpty {
                Text("No meeting notes yet. Drop an audio file here to transcribe.").foregroundStyle(Theme.muted)
            } else {
                SearchField(prompt: "Search meetings…", text: $searchQuery)
                    .accessibilityIdentifier("searchMeetings")
                if visibleNotes.isEmpty {
                    Text("No meetings match “\(searchQuery)”.").font(.caption).foregroundStyle(Theme.muted)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleNotes) { note in
                            PastNoteRow(
                                id: note.id,
                                title: note.event.title,
                                subtitle: "\(MeetingsDateFormat.dateTime(note.startedAt))\(note.isInPerson ? " · In-person" : "") · \(note.phase.rawValue.capitalized)",
                                isSelected: selectedID == note.id,
                                theme: theme,
                                action: { selectNote(note.id, note.phase == .recording ? "Transcript" : "Summary") }
                            )
                            .equatable()
                        }
                    }
                }
            }
        }
    }
}

private struct PastNoteRow: View, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let isSelected: Bool
    let theme: AppTheme
    let action: () -> Void

    nonisolated static func == (lhs: PastNoteRow, rhs: PastNoteRow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.isSelected == rhs.isSelected
            && lhs.theme == rhs.theme
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(isSelected ? Theme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail Pane

private struct MeetingDetailPane: View {
    let meetings: MeetingCoordinator
    @Binding var tab: String
    let requestDelete: () -> Void
    @State private var editingTitleID: UUID?
    @State private var titleDraft = ""

    var body: some View {
        if let note = meetings.selectedNote {
            let actionItems = note.actionItems
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        if editingTitleID == note.id {
                            HStack(spacing: 8) {
                                TextField("Meeting title", text: $titleDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 320)
                                    .onSubmit {
                                        meetings.renameMeeting(note.id, title: titleDraft)
                                        editingTitleID = nil
                                    }
                                Button("Save") {
                                    meetings.renameMeeting(note.id, title: titleDraft)
                                    editingTitleID = nil
                                }
                                Button("Cancel") { editingTitleID = nil }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(note.event.title).font(.title2).fontWeight(.semibold)
                                Button {
                                    titleDraft = note.event.title
                                    editingTitleID = note.id
                                } label: {
                                    Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.muted)
                                }
                                .buttonStyle(.plain)
                                .help("Rename meeting")
                                .accessibilityLabel("Rename meeting")
                            }
                        }
                        Text("\(MeetingsDateFormat.dateTime(note.startedAt))\(note.isInPerson ? " · In-person (microphone only)" : "")").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Export") { export(note) }
                    Button(action: requestDelete) { Image(systemName: "trash") }
                        .accessibilityLabel("Delete meeting")
                        .disabled(meetings.busy || !meetings.processing.isEmpty)
                }
                ThemedSegmented(options: [("Summary", "Summary"), ("Transcript", "Transcript"), ("My notes", "My notes")],
                                selection: $tab, label: "Meeting view")
                if let issue = note.issue {
                    Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                switch tab {
                case "My notes":
                    MeetingPersonalNotesEditor(noteID: note.id, storedText: note.personalNotes, meetings: meetings)
                case "Transcript":
                    if note.segments.isEmpty {
                        Text("Listening…")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        MeetingTranscriptTextView(
                            noteID: note.id,
                            segments: note.displaySegments,
                            isInPerson: note.isInPerson,
                            theme: Theme.current
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if meetings.processing.contains(note.id) {
                                ProgressView("Summarizing…")
                            }
                            if !actionItems.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Action items").font(.headline).foregroundStyle(Theme.ink)
                                    ForEach(actionItems, id: \.self) { item in
                                        let done = note.completedActionItems.contains(item)
                                        Button {
                                            meetings.toggleActionItem(note.id, item: item)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Image(systemName: done ? "checkmark.square.fill" : "square")
                                                    .foregroundStyle(done ? Theme.accent : Theme.muted)
                                                Text(item)
                                                    .strikethrough(done, color: Theme.muted)
                                                    .foregroundStyle(done ? Theme.muted : Theme.ink)
                                                    .multilineTextAlignment(.leading)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 2)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(item)
                                        .accessibilityValue(done ? "Completed" : "Incomplete")
                                    }
                                }
                                .padding(12)
                                .background(Theme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                            }
                            MeetingSummaryView(
                                text: note.summary.isEmpty ? "Summary appears when the meeting ends." : note.summary,
                                theme: Theme.current
                            )
                            .equatable()
                            .accessibilityIdentifier("meetingSummary")
                            if !note.summaryMethod.isEmpty {
                                Text(note.summaryMethod).font(.caption).foregroundStyle(Theme.muted)
                            }
                            if note.phase != .recording {
                                HStack(spacing: 8) {
                                    if !note.event.isImported {
                                        Button("Resume recording") { Task { await meetings.resume(note.id) } }
                                            .disabled(meetings.busy || (!meetings.consentConfirmed && !note.event.isAdHoc) || meetings.processing.contains(note.id))
                                    }
                                    Button("Re-summarize") { Task { await meetings.resummarize(note.id) } }
                                        .disabled(meetings.processing.contains(note.id) || (note.transcript.isEmpty && note.personalNotes.isEmpty))
                                        .accessibilityIdentifier("resummarizeMeeting")
                                    Button("Retry audio and summary") { Task { await meetings.retry(note.id) } }
                                        .disabled(meetings.processing.contains(note.id))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(Theme.muted)
                Text("Select or start a meeting").font(.title3).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func export(_ note: MeetingNote) {
        guard !handsfreeSession else { return }
        meetings.flushPendingSaves()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Meeting notes.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try MeetingsPage.writeExportedMarkdown(note.markdown, to: url) }
            catch { meetings.error = error.localizedDescription }
        }
    }
}

// MARK: - Personal Notes Editor (Local Buffer + Debounced Persistence)

private struct MeetingPersonalNotesEditor: View {
    let noteID: UUID
    let storedText: String
    let meetings: MeetingCoordinator
    @State private var draftText: String

    init(noteID: UUID, storedText: String, meetings: MeetingCoordinator) {
        self.noteID = noteID
        self.storedText = storedText
        self.meetings = meetings
        self._draftText = State(initialValue: storedText)
    }

    var body: some View {
        DraftTextEditor(
            text: Binding(
                get: { draftText },
                set: { updated in
                    draftText = updated
                    meetings.updateNotes(noteID, text: updated)
                }
            ),
            label: "My meeting notes",
            fill: \.field
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedEditor(composer: Theme.current.bookSerif)
        .onChange(of: noteID) { _, _ in draftText = storedText }
        .onChange(of: storedText) { _, updated in
            if updated != draftText { draftText = updated }
        }
        .onDisappear { meetings.flushPendingSaves() }
    }
}

// MARK: - Single-View Safe Markdown Summary

/// Render a deliberately small Markdown subset in one selectable text layout; no HTML, remote images, or active links.
private struct MeetingSummaryView: View, Equatable {
    let text: String
    let theme: AppTheme

    var body: some View {
        Text(Self.attributed(from: text))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    @MainActor private static func attributed(from text: String) -> AttributedString {
        var output = AttributedString()
        var isFirst = true
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let isSubheading = line.hasPrefix("###")
            let isHeading = line.hasPrefix("#") || (line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 && !line.dropFirst(2).dropLast(2).contains("**"))
            if !isFirst {
                output.append(AttributedString(isHeading ? "\n\n" : "\n"))
            }
            isFirst = false
            if isHeading {
                var heading = AttributedString(line.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")))
                heading.font = isSubheading ? .subheadline.weight(.semibold) : .headline
                heading.foregroundColor = Theme.ink
                output.append(heading)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var bullet = AttributedString("•  ")
                bullet.foregroundColor = Theme.accent
                output.append(bullet)
                output.append(inlineFormatted(String(line.dropFirst(2))))
            } else {
                output.append(inlineFormatted(line))
            }
        }
        return output
    }

    /// Parses only balanced `**bold**` spans into styled `AttributedString` runs; never interprets HTML or links.
    @MainActor private static func inlineFormatted(_ text: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let open = text[cursor...].range(of: "**") else {
                var plain = AttributedString(String(text[cursor...]))
                plain.foregroundColor = Theme.ink
                result.append(plain)
                break
            }
            if open.lowerBound > cursor {
                var prefix = AttributedString(String(text[cursor..<open.lowerBound]))
                prefix.foregroundColor = Theme.ink
                result.append(prefix)
            }
            let afterOpen = open.upperBound
            guard afterOpen < text.endIndex,
                  let close = text[afterOpen...].range(of: "**") else {
                var tail = AttributedString(String(text[open.lowerBound...]))
                tail.foregroundColor = Theme.ink
                result.append(tail)
                break
            }
            var bold = AttributedString(String(text[afterOpen..<close.lowerBound]))
            bold.font = .body.weight(.semibold)
            bold.foregroundColor = Theme.ink
            result.append(bold)
            cursor = close.upperBound
        }
        return result
    }
}

// MARK: - Native Non-Contiguous Read-Only Transcript View

/// Hosts all transcript segments in a single non-contiguous AppKit `NSTextView` instead of creating
/// hundreds of per-segment `AppKitTextInteractionView` subviews.
private struct MeetingTranscriptTextView: NSViewRepresentable {
    let noteID: UUID
    let segments: [MeetingSegment]
    let isInPerson: Bool
    let theme: AppTheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("Meeting transcript")
        textView.setAccessibilityIdentifier("meetingTranscript")
        applyIfNeeded(to: scroll, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        applyIfNeeded(to: scroll, coordinator: context.coordinator)
    }

    private func applyIfNeeded(to scroll: NSScrollView, coordinator: Coordinator) {
        guard coordinator.lastNoteID != noteID
                || coordinator.lastSegments != segments
                || coordinator.lastIsInPerson != isInPerson
                || coordinator.lastTheme != theme,
              let textView = scroll.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        let switchedNote = coordinator.lastNoteID != noteID
        let previousOrigin = scroll.contentView.bounds.origin
        coordinator.lastNoteID = noteID
        coordinator.lastSegments = segments
        coordinator.lastIsInPerson = isInPerson
        coordinator.lastTheme = theme

        storage.setAttributedString(Self.buildAttributedTranscript(segments: segments, isInPerson: isInPerson))
        if switchedNote {
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        } else {
            scroll.contentView.scroll(to: previousOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private static func buildAttributedTranscript(segments: [MeetingSegment], isInPerson: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.beginEditing()
        defer { result.endEditing() }
        let headerFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let bodyFont = Theme.nativeWritingFont(14)
        let mutedColor = Theme.nativeColor(\.muted)
        let inkColor = Theme.nativeColor(\.ink)
        let dangerColor = Theme.nativeColor(\.danger)

        let firstHeaderParagraph = NSMutableParagraphStyle()
        firstHeaderParagraph.paragraphSpacing = 4

        let subsequentHeaderParagraph = NSMutableParagraphStyle()
        subsequentHeaderParagraph.paragraphSpacingBefore = 12
        subsequentHeaderParagraph.paragraphSpacing = 4

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 3
        bodyParagraph.paragraphSpacing = 2

        let firstHeaderAttrs: [NSAttributedString.Key: Any] = [
            .font: headerFont, .foregroundColor: mutedColor, .paragraphStyle: firstHeaderParagraph
        ]
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: headerFont, .foregroundColor: mutedColor, .paragraphStyle: subsequentHeaderParagraph
        ]
        let spokenAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: inkColor, .paragraphStyle: bodyParagraph
        ]
        let placeholderAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: mutedColor, .paragraphStyle: bodyParagraph
        ]
        let errorAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: dangerColor, .paragraphStyle: bodyParagraph
        ]

        for (index, segment) in segments.enumerated() {
            let prefix = index == 0 ? "" : "\n"
            let speakerLabel = (isInPerson && segment.source == .microphone) ? "Room · microphone" : segment.label
            let header = "\(prefix)\(MeetingNote.timestamp(segment.offset)) · \(speakerLabel)\n"
            result.append(NSAttributedString(string: header, attributes: index == 0 ? firstHeaderAttrs : headerAttrs))

            let bodyText: String
            let bodyAttrs: [NSAttributedString.Key: Any]
            if let text = segment.text {
                if text.isEmpty {
                    bodyText = "[No speech]"
                    bodyAttrs = placeholderAttrs
                } else {
                    bodyText = text
                    bodyAttrs = spokenAttrs
                }
            } else if let error = segment.error {
                bodyText = error
                bodyAttrs = errorAttrs
            } else {
                bodyText = "Transcribing…"
                bodyAttrs = placeholderAttrs
            }
            result.append(NSAttributedString(string: bodyText, attributes: bodyAttrs))
        }
        return result
    }

    @MainActor final class Coordinator {
        var lastNoteID: UUID?
        var lastSegments: [MeetingSegment] = []
        var lastIsInPerson: Bool?
        var lastTheme: AppTheme?
    }
}
