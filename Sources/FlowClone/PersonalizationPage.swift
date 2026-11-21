import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct PersonalizationPage: View {
    let title: String
    let kinds: [PersonalizationKind]
    private let globalStore: PersonalizationStore
    private let suggestionStore: CorrectionSuggestions
    private let appProfilesStore: AppProfiles

    @State private var selectedSet: UUID?
    @State private var preflight = false
    private var store: PersonalizationStore { selectedSet.map { VocabularySets.shared.store($0) } ?? globalStore }
    @State private var kind: PersonalizationKind
    @State private var snapshot: PersonalizationSnapshot?
    @State private var pendingSuggestions: [CorrectionSuggestions.Item] = []
    @State private var showAppProfiles = false
    @State private var status = ""
    @State private var feedbackKind: FeedbackKind = .information
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var lastUndo: PersonalizationUndoToken?
    @State private var editing: EditTarget?
    @State private var importing: ImportTarget?
    @State private var confirmDelete = false
    @State private var pendingDelete = Set<String>()

    struct EditTarget: Identifiable { let id = UUID(); let entry: PersonalizationEntry?; let fingerprint: Data }
    struct ImportTarget: Identifiable { let id = UUID(); let preview: PersonalizationImportPreview }

    init(
        title: String,
        kinds: [PersonalizationKind],
        store: PersonalizationStore = .shared,
        suggestions: CorrectionSuggestions = AutoLearn.suggestions,
        appProfiles: AppProfiles = .shared
    ) {
        self.title = title
        self.kinds = kinds
        self.globalStore = store
        self.suggestionStore = suggestions
        self.appProfilesStore = appProfiles
        _kind = State(initialValue: kinds.first ?? .dictionary)
    }

    private var showsSuggestionsSection: Bool {
        (kinds.contains(.correction) || kinds.contains(.dictionary)) && !pendingSuggestions.isEmpty
    }

    private var showsAppProfilesControl: Bool {
        kinds.contains(.dictionary) || kinds.contains(.correction)
    }

    private var entries: [PersonalizationEntry] { snapshot?.entries ?? [] }
    private var filtered: [PersonalizationEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? entries : entries.filter {
            $0.primary.localizedCaseInsensitiveContains(q) || ($0.replacement?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
    private var deleteTitle: String {
        if pendingDelete.count == 1, let entry = entries.first(where: { pendingDelete.contains($0.id) }) {
            return "Delete “\(String(entry.primary.prefix(60)))”?"
        }
        return "Delete \(pendingDelete.count) entries?"
    }
    /// The list toolbar (search, count, Add) appears once there is something to search; an
    /// empty list offers its single Add action in the empty state instead.
    private var hasEntries: Bool { snapshot != nil && !entries.isEmpty }
    private var columns: (primary: String, replacement: String?) {
        switch kind {
        case .dictionary: ("Term", nil)
        case .snippet: ("Spoken trigger", "Expansion")
        case .correction: ("Heard as", "Replace with")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title)
            // Row 1: the scope this page edits, with its administration behind "Set options".
            VocabularySetControls(selection: $selectedSet) { listActions }

            if showsAppProfilesControl {
                AppProfilesSection(store: appProfilesStore, isExpanded: $showAppProfiles)
            }

            if showsSuggestionsSection {
                PendingSuggestionsSection(
                    items: pendingSuggestions,
                    onApprove: approveSuggestion,
                    onDismiss: dismissSuggestion
                )
            }

            if kinds.count > 1 {
                ThemedSegmented(options: kinds.map { ($0, $0.label) }, selection: $kind, label: "Entry type")
            }
            if hasEntries {
                HStack(spacing: 12) {
                    SearchField(prompt: "Search \(kind.label.lowercased())", text: $query).frame(maxWidth: 300)
                    Text("\(filtered.count) of \(entries.count)").font(UIStyle.caption).foregroundStyle(Theme.muted)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Button("Add \(kind.singular)") { beginAdd() }.prominent()
                }
            }
            if snapshot == nil {
                EmptyState(symbol: "exclamationmark.circle", title: "Could not read this list",
                           detail: status, actionTitle: "Try again") { reload() }
            } else if filtered.isEmpty {
                EmptyState(symbol: query.isEmpty ? (kind == .snippet ? "scissors" : "book.closed") : "magnifyingglass",
                           title: query.isEmpty ? "No \(kind.label.lowercased()) yet" : "No matching entries",
                           actionTitle: query.isEmpty ? "Add \(kind.singular)" : "Clear search") {
                    if query.isEmpty { beginAdd() } else { query = "" }
                }
            } else {
                entryTable
            }
            if !selection.isEmpty {
                HStack(spacing: 8) {
                    Text("\(selection.count) selected").foregroundStyle(Theme.muted)
                    Button("Edit…") { edit(selection) }.disabled(selection.count != 1)
                    Button("Delete…", role: .destructive) { pendingDelete = selection; confirmDelete = true }
                    Spacer()
                    Button("Deselect") { selection = [] }
                }.font(UIStyle.caption)
            }
            if !status.isEmpty { Feedback(text: status, kind: feedbackKind) }
        }
        .pageColumn()
        .onAppear {
            reloadSuggestions()
            reload(message: status.isEmpty ? nil : status, feedback: feedbackKind)
        }
        .onReceive(NotificationCenter.default.publisher(for: AutoLearn.didChange)) { _ in
            reloadSuggestions()
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: CorrectionSuggestions.didChange)) { _ in
            reloadSuggestions()
        }
        .onChange(of: kind) { _, _ in selection = []; query = ""; reload() }
        .onChange(of: selectedSet) { _, _ in selection = []; query = ""; lastUndo = nil; reload() }
        .sheet(isPresented: $preflight) { VocabularyPreflight(selection: selectedSet) }
        .onChange(of: query) { _, _ in selection = selection.intersection(Set(filtered.map(\.id))) }
        .sheet(item: $editing) { target in
            EntryEditor(kind: kind, existing: target.entry) { draft in
                do {
                    lastUndo = try target.entry.map { try store.update(id: $0.id, to: draft, expected: target.fingerprint) }
                        ?? store.add(draft, expected: target.fingerprint)
                    reload(message: target.entry == nil ? "Saved “\(draft.primary)”" : "Updated “\(draft.primary)”", feedback: .success)
                } catch {
                    reload(message: error.localizedDescription, feedback: .error)
                    throw error
                }
            }
        }
        .sheet(item: $importing) { target in
            ImportReview(preview: target.preview) { replace in
                do {
                    lastUndo = try store.apply(target.preview, replaceConflicts: replace)
                    reload(message: "Imported \(target.preview.addedCount) new entries" + (replace ? "; replaced \(target.preview.conflictCount) conflicts" : ""), feedback: .success)
                } catch {
                    reload(message: error.localizedDescription, feedback: .error)
                    throw error
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Delete \(pendingDelete.count == 1 ? "entry" : "\(pendingDelete.count) entries")", role: .destructive) {
                guard let snapshot else { return }
                mutate { try store.delete(ids: pendingDelete, kind: kind, expected: snapshot.fingerprint) }
                pendingDelete = []
            }
        }
    }

    private var listActions: some View {
        Menu {
            Button("Import from file…", action: importEntries)
            Button("Export JSON…") { exportEntries(csv: false) }
            Button("Export CSV…") { exportEntries(csv: true) }
            Button("Test rules…") { preflight = true }
            if showsAppProfilesControl {
                Button(showAppProfiles ? "Hide app profiles" : "App profiles…") { showAppProfiles.toggle() }
            }
            Button("Undo last change", action: undoLast).disabled(lastUndo == nil)
            Button("Refresh") { reloadSuggestions(); reload() }
        } label: { Image(systemName: "ellipsis") }
            .fixedSize().help("More list actions").accessibilityLabel("More list actions")
    }

    private static let rowInset: CGFloat = 16
    private static let tableTopGap: CGFloat = 10
    private var entryTable: some View {
        let flat = Theme.flatPanels, columns = columns
        return VStack(alignment: .leading, spacing: 0) {
            EntryColumns(split: columns.replacement != nil) {
                Text(columns.primary)
            } trailing: {
                Text(columns.replacement ?? "")
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            .padding(.horizontal, Self.rowInset).padding(.top, 10).padding(.bottom, 7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, Self.rowInset)
            }
            .background(flat ? Theme.panel : Theme.surface)
            .zIndex(1)
            .accessibilityHidden(true)
            Table(filtered, selection: $selection) {
                TableColumn(columns.primary) { entry in
                    EntryColumns(split: columns.replacement != nil) {
                        Text(entry.primary).foregroundStyle(Theme.ink)
                    } trailing: {
                        Text(entry.replacement?.replacingOccurrences(of: "\n", with: " ↵ ") ?? "")
                            .foregroundStyle(Theme.muted)
                    }
                    .font(Theme.writingFont).lineLimit(2)
                    .frame(minHeight: 32)
                    .accessibilityElement(children: .combine)
                }
            }
            .tableColumnHeaders(.hidden)
            .padding(.top, -Self.tableTopGap)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Edit…") { edit(ids) }.disabled(ids.count != 1)
                Button("Delete…", role: .destructive) { pendingDelete = ids; confirmDelete = true }.disabled(ids.isEmpty)
            } primaryAction: { edit($0) }
        }
        .background(flat ? .clear : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(flat ? .clear : Theme.divider))
        .padding(.horizontal, flat ? -Self.rowInset : 0)
    }

    private func reloadSuggestions() {
        pendingSuggestions = suggestionStore.current()
    }

    private func approveSuggestion(_ item: CorrectionSuggestions.Item) {
        do {
            let token = try AutoLearn.approveSuggestion(
                item.id,
                suggestions: suggestionStore,
                store: globalStore
            )
            if let token { lastUndo = token }
            reloadSuggestions()
            reload(message: "Approved “\(item.wrong) → \(item.right)”", feedback: .success)
        } catch {
            reloadSuggestions()
            reload(message: error.localizedDescription, feedback: .error)
        }
    }

    private func dismissSuggestion(_ item: CorrectionSuggestions.Item) {
        _ = AutoLearn.dismissSuggestion(item.id, suggestions: suggestionStore)
        reloadSuggestions()
        status = "Dismissed suggestion for “\(item.wrong)”"
        feedbackKind = .information
    }

    private func reload(message: String? = nil, feedback: FeedbackKind = .information) {
        do {
            snapshot = try store.snapshot(kind)
            let ignored = snapshot?.ignoredLineCount ?? 0
            status = message ?? (ignored > 0 ? "\(ignored) unrecognized lines preserved" : "")
            feedbackKind = message == nil && ignored > 0 ? .warning : feedback
        } catch { snapshot = nil; status = error.localizedDescription; feedbackKind = .error }
        selection = selection.intersection(Set(entries.map(\.id)))
    }
    private func beginAdd() {
        guard let snapshot else { return }
        editing = EditTarget(entry: nil, fingerprint: snapshot.fingerprint)
    }
    private func edit(_ ids: Set<String>) {
        guard let snapshot, ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        editing = EditTarget(entry: entry, fingerprint: snapshot.fingerprint)
    }
    private func mutate(_ operation: () throws -> PersonalizationUndoToken) {
        do { lastUndo = try operation(); reload(message: "Saved", feedback: .success) }
        catch { reload(message: error.localizedDescription, feedback: .error) }
    }
    private func undoLast() {
        guard let token = lastUndo else { return }
        do {
            try store.undo(token); lastUndo = nil
            if kinds.contains(token.kind) { kind = token.kind }
            reload(message: "Undone", feedback: .success)
        } catch { reload(message: error.localizedDescription, feedback: .error) }
    }
    private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .json, .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            let converted = try PersonalizationExchange.importText(data, extension: url.pathExtension.lowercased(), kind: kind)
            importing = ImportTarget(preview: try store.previewImport(converted, kind: kind))
        } catch { reload(message: error.localizedDescription, feedback: .error) }
    }
    private func exportEntries(csv: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "FlowClone-\(kind.rawValue).\(csv ? "csv" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PersonalizationExchange.encode(entries.map(\.draft), csv: csv)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = "Exported \(entries.count) entries."; feedbackKind = .success
        } catch { reload(message: error.localizedDescription, feedback: .error) }
    }
}

/// Inline pending `CorrectionSuggestions` banner with 1-click Approve and Dismiss actions.
struct PendingSuggestionsSection: View {
    let items: [CorrectionSuggestions.Item]
    let onApprove: (CorrectionSuggestions.Item) -> Void
    let onDismiss: (CorrectionSuggestions.Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accentText)
                Text("Suggested corrections (\(items.count))").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.wrong).foregroundStyle(Theme.muted)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                            Text(item.right).fontWeight(.medium).foregroundStyle(Theme.ink)
                        }
                        .font(Theme.writingFont)
                        if !item.app.isEmpty {
                            Text("Edited in \(InstalledApp.name(item.app))")
                                .font(UIStyle.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Dismiss") { onDismiss(item) }
                        .accessibilityLabel("Dismiss \(item.wrong) to \(item.right)")
                    Button("Approve") { onApprove(item) }
                        .prominent()
                        .accessibilityLabel("Approve \(item.wrong) to \(item.right)")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.divider))
    }
}

/// Per-application dictation profile controls (`Clean` / `Prompt` / `Literal`, chat period
/// stripping, slash-command recognition, and spoken code formatting).
struct AppProfilesSection: View {
    let store: AppProfiles
    @Binding var isExpanded: Bool
    @State private var doc = AppProfiles.Document()
    @State private var editingProfile: AppProfile?
    @State private var creatingNew = false
    @State private var error = ""

    private var summaryText: String {
        let activeCount = doc.profiles.filter(\.enabled).count
        return activeCount == 0
            ? "Default"
            : "\(activeCount) custom app profile\(activeCount == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("App profiles").foregroundStyle(Theme.muted)
                Text(summaryText).font(UIStyle.caption).foregroundStyle(Theme.muted).lineLimit(1)
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide profiles" : "Configure apps")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(UIStyle.caption.weight(.medium)).foregroundStyle(Theme.accentText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if isExpanded {
                    Button("New app profile…") { creatingNew = true }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if doc.profiles.isEmpty {
                        HStack {
                            Text("No custom app profiles")
                                .font(UIStyle.caption).foregroundStyle(Theme.muted)
                            Spacer(minLength: 8)
                            Button("Add profile…") { creatingNew = true }.prominent()
                        }
                    } else {
                        ForEach(doc.profiles) { profile in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(InstalledApp.name(profile.bundleID)).fontWeight(.medium)
                                    Text(describe(profile)).font(UIStyle.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 0)
                                Button(profile.enabled ? "Disable" : "Enable") {
                                    mutate { d in
                                        if let idx = d.profiles.firstIndex(where: { $0.id == profile.id }) {
                                            d.profiles[idx].enabled.toggle()
                                        }
                                    }
                                }
                                Button("Edit…") { editingProfile = profile }
                                Button("Remove", role: .destructive) {
                                    mutate { d in d.profiles.removeAll { $0.id == profile.id } }
                                }
                            }
                            if profile.id != doc.profiles.last?.id { Hairline() }
                        }
                    }
                    if !error.isEmpty { Feedback(text: error, kind: .error) }
                }
                .padding(Theme.flatPanels ? 0 : 14)
                .padding(.vertical, Theme.flatPanels ? 4 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.flatPanels ? .clear : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.flatPanels ? .clear : Theme.divider))
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: AppProfiles.didChange)) { _ in reload() }
        .sheet(isPresented: $creatingNew) {
            AppProfileEditor(existing: nil) { saved in
                try store.update { d in d.profiles.append(saved) }
                reload()
            }
        }
        .sheet(item: $editingProfile) { target in
            AppProfileEditor(existing: target) { saved in
                try store.update { d in
                    if let idx = d.profiles.firstIndex(where: { $0.id == saved.id }) {
                        d.profiles[idx] = saved
                    }
                }
                reload()
            }
        }
    }

    private func describe(_ profile: AppProfile) -> String {
        var parts = ["Mode: \(profile.preferredMode.label)"]
        if profile.stripSingleSentencePeriod { parts.append("Strip single-sentence period") }
        if let slash = profile.slashCommandsEnabled {
            parts.append(slash ? "Slash commands on" : "Slash commands off")
        }
        if let code = profile.codeFormattingEnabled {
            parts.append(code ? "Code formatting on" : "Code formatting off")
        }
        if !profile.enabled { parts.append("Disabled") }
        return parts.joined(separator: " · ")
    }

    private func mutate(_ body: (inout AppProfiles.Document) -> Void) {
        do { try store.update(body); reload() } catch { self.error = error.localizedDescription }
    }

    private func reload() {
        do { doc = try store.document(); error = "" } catch { self.error = error.localizedDescription }
    }
}

struct AppProfileEditor: View {
    private enum TriState: String, CaseIterable {
        case automatic = "Automatic"
        case enabled = "Enabled"
        case disabled = "Disabled"

        init(_ flag: Bool?) {
            switch flag {
            case nil: self = .automatic
            case true?: self = .enabled
            case false?: self = .disabled
            }
        }

        var boolValue: Bool? {
            switch self {
            case .automatic: return nil
            case .enabled: return true
            case .disabled: return false
            }
        }
    }

    let existing: AppProfile?
    let onSave: (AppProfile) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var bundleID: String
    @State private var preferredMode: AppDictationMode
    @State private var stripSingleSentencePeriod: Bool
    @State private var slashCommands: TriState
    @State private var codeFormatting: TriState
    @State private var saveError = ""

    private static let presets: [(label: String, bundleID: String, chat: Bool)] = [
        ("Messages", "com.apple.MobileSMS", true),
        ("Slack", "com.tinyspeck.slackmacgap", true),
        ("Discord", "com.hnc.Discord", true),
        ("Xcode", "com.apple.dt.Xcode", false),
        ("Cursor", "com.todesktop.230313mzl4w4u92", false),
        ("VS Code", "com.microsoft.VSCode", false),
    ]

    init(existing: AppProfile?, onSave: @escaping (AppProfile) throws -> Void) {
        self.existing = existing
        self.onSave = onSave
        _bundleID = State(initialValue: existing?.bundleID ?? "")
        _preferredMode = State(initialValue: existing?.preferredMode ?? .global)
        _stripSingleSentencePeriod = State(initialValue: existing?.stripSingleSentencePeriod ?? false)
        _slashCommands = State(initialValue: TriState(existing?.slashCommandsEnabled))
        _codeFormatting = State(initialValue: TriState(existing?.codeFormattingEnabled))
    }

    var body: some View {
        SheetFrame(
            title: existing == nil ? "New app profile" : "Edit app profile",
            width: 520
        ) {
            VStack(alignment: .leading, spacing: 16) {
                LabeledSheetField(label: "Application") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("com.tinyspeck.slackmacgap", text: $bundleID)
                            Button("Choose application…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.applicationBundle]
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url,
                                   let id = Bundle(url: url)?.bundleIdentifier {
                                    bundleID = id
                                    if AppProfiles.isChatApp(id) && existing == nil {
                                        stripSingleSentencePeriod = true
                                    }
                                }
                            }
                        }
                        HStack(spacing: 6) {
                            ForEach(Self.presets, id: \.bundleID) { preset in
                                Button(preset.label) {
                                    bundleID = preset.bundleID
                                    if preset.chat && existing == nil {
                                        stripSingleSentencePeriod = true
                                    }
                                }
                                .font(UIStyle.caption)
                            }
                        }
                    }
                }

                LabeledSheetField(label: "Preferred dictation mode") {
                    Picker("Preferred dictation mode", selection: $preferredMode) {
                        ForEach(AppDictationMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                Toggle(
                    "Strip trailing period on single-sentence messages",
                    isOn: $stripSingleSentencePeriod
                )

                LabeledSheetField(label: "Slash commands") {
                    Picker("Slash commands", selection: $slashCommands) {
                        ForEach(TriState.allCases, id: \.self) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledSheetField(label: "Spoken code formatting") {
                    Picker("Spoken code formatting", selection: $codeFormatting) {
                        ForEach(TriState.allCases, id: \.self) { state in
                            Text(state.rawValue).tag(state)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if !saveError.isEmpty { Feedback(text: saveError, kind: .error) }
            }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save profile") {
                let profile = AppProfile(
                    id: existing?.id ?? UUID(),
                    bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                    preferredMode: preferredMode,
                    stripSingleSentencePeriod: stripSingleSentencePeriod,
                    slashCommandsEnabled: slashCommands.boolValue,
                    codeFormattingEnabled: codeFormatting.boolValue,
                    enabled: existing?.enabled ?? true
                )
                do {
                    try onSave(profile)
                    dismiss()
                } catch {
                    saveError = error.localizedDescription
                }
            }
            .prominent()
            .keyboardShortcut(.defaultAction)
            .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// One or two equal columns: the header and every row share this frame, so they align.
private struct EntryColumns<Leading: View, Trailing: View>: View {
    let split: Bool
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            if split { trailing.frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

/// A labelled dialog field: a medium label over the control and an optional muted hint.
struct LabeledSheetField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).fontWeight(.medium)
            content
            if let hint { Text(hint).font(UIStyle.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct EntryEditor: View {
    let kind: PersonalizationKind
    let existing: PersonalizationEntry?
    let onSave: (PersonalizationDraft) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var primary: String
    @State private var replacement: String
    @State private var saveError = ""
    @FocusState private var firstField: Bool
    init(kind: PersonalizationKind, existing: PersonalizationEntry?, onSave: @escaping (PersonalizationDraft) throws -> Void) {
        self.kind = kind; self.existing = existing; self.onSave = onSave
        _primary = State(initialValue: existing?.primary ?? "")
        _replacement = State(initialValue: existing?.replacement ?? "")
    }
    private var draft: PersonalizationDraft {
        PersonalizationDraft(kind: kind, primary: primary, replacement: kind == .dictionary ? nil : replacement)
    }
    private var validationError: String? {
        do { _ = try PersonalizationStore.validated(draft); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        SheetFrame(title: "\(existing == nil ? "Add" : "Edit") \(kind.singular)", width: 500) {
            VStack(alignment: .leading, spacing: 16) {
                LabeledSheetField(label: kind == .dictionary ? "Term" : (kind == .snippet ? "Spoken trigger" : "Heard as")) {
                    TextField(kind == .dictionary ? "FlowClone" : (kind == .snippet ? "my sign off" : "flow clone"), text: $primary)
                        .focused($firstField)
                }
                if kind == .snippet {
                    LabeledSheetField(
                        label: "Expansion",
                        hint: "Supports {{date}}, {{time}}, and {{clipboard}}."
                    ) {
                        TextEditor(text: $replacement).font(Theme.writingFont).themedEditor().frame(height: 110)
                            .accessibilityLabel("Snippet expansion")
                    }
                } else if kind == .correction {
                    LabeledSheetField(label: "Replace with") { TextField("FlowClone", text: $replacement) }
                }
                if kind == .snippet, !replacement.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Expansion preview").font(UIStyle.caption).foregroundStyle(Theme.muted)
                        ScrollView { Text(replacement).font(Theme.writingFont).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 100)
                    }
                    .padding(12)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.divider))
                }
                if !saveError.isEmpty { Feedback(text: saveError, kind: .error) }
                else if let error = validationError, !primary.isEmpty { Feedback(text: error, kind: .warning) }
            }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save \(kind.singular)") {
                do { try onSave(try PersonalizationStore.validated(draft)); dismiss() }
                catch {
                    saveError = error as? PersonalizationError == .stale
                        ? "This list changed while you were editing. Close this editor and reopen the entry to review the latest version. Your text is still here to copy."
                        : error.localizedDescription
                }
            }
            .prominent().keyboardShortcut(.defaultAction).disabled(validationError != nil)
        }
        .onAppear { firstField = true }
        .onChange(of: primary) { _, _ in saveError = "" }
        .onChange(of: replacement) { _, _ in saveError = "" }
    }
}

struct ImportReview: View {
    let preview: PersonalizationImportPreview
    let onImport: (Bool) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var replace = false
    @State private var error = ""
    var body: some View {
        SheetFrame(title: "Import \(preview.kind.label.lowercased())",
                   subtitle: "\(preview.addedCount) new · \(preview.conflictCount) conflict\(preview.conflictCount == 1 ? "" : "s") · \(preview.duplicateCount) unchanged",
                   width: 570) {
            VStack(alignment: .leading, spacing: 14) {
                if preview.invalidCount > 0 { Feedback(text: "\(preview.invalidCount) invalid line\(preview.invalidCount == 1 ? "" : "s") will be skipped.", kind: .warning) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.rows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.draft.primary).font(Theme.writingFont)
                                    Spacer()
                                    Feedback(text: row.outcome.rawValue, kind: row.outcome == .conflict ? .warning : .information)
                                }
                                if let previous = row.previous, row.outcome == .conflict {
                                    Text("Current: \(previous)").foregroundStyle(Theme.muted)
                                }
                                if let value = row.draft.replacement { Text("Incoming: \(value)").textSelection(.enabled) }
                            }
                            Hairline()
                        }
                    }.padding(14)
                }
                .frame(height: 280)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.divider))
                if preview.conflictCount > 0 { Toggle("Replace \(preview.conflictCount) conflicting entr\(preview.conflictCount == 1 ? "y" : "ies")", isOn: $replace) }
                if !error.isEmpty { Feedback(text: error, kind: .error) }
            }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(replace ? "Import & replace conflicts" : "Import new entries") {
                do { try onImport(replace); dismiss() } catch { self.error = error.localizedDescription }
            }.prominent().keyboardShortcut(.defaultAction)
                .disabled(preview.addedCount == 0 && !(replace && preview.conflictCount > 0))
        }
    }
}
