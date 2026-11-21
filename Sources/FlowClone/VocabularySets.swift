import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct VocabularySet: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var bundleID: String = ""
    var language: String = ""
    var enabled = true
}

struct PersonalizationConfiguration: Sendable {
    let entries: [PersonalizationDraft]
    let names: [String]
    let bundleID: String?
    let appProfile: ResolvedAppProfile
    let prepared: Cleaner.PreparedConfiguration

    init(
        entries: [PersonalizationDraft],
        names: [String],
        bundleID: String? = nil,
        appProfile: ResolvedAppProfile? = nil,
        prepared: Cleaner.PreparedConfiguration? = nil
    ) {
        self.entries = entries
        self.names = names
        self.bundleID = bundleID
        self.appProfile = appProfile ?? AppProfiles.shared.resolve(bundleID: bundleID)
        self.prepared = prepared ?? Cleaner.PreparedConfiguration(entries)
    }

    func entries(_ kind: PersonalizationKind) -> [PersonalizationDraft] { entries.filter { $0.kind == kind } }
}

final class VocabularySets: @unchecked Sendable {
    static let shared = VocabularySets(root: PersonalizationStore.shared.root, appProfiles: AppProfiles.shared)
    static let didChange = Notification.Name("FlowCloneVocabularySetsChanged")
    struct Document: Codable, Sendable {
        var version = 1
        var sets: [VocabularySet] = []
        var active: UUID?
        var language = "en"
    }

    private struct FileCacheKey: Hashable {
        let rootPath: String
        let kind: PersonalizationKind
    }

    private struct StoreStamp: Hashable {
        let rootPath: String
        let dictionary: FileStamp
        let snippet: FileStamp
        let correction: FileStamp
    }

    private struct PreparedBundle {
        let entries: [PersonalizationDraft]
        let prepared: Cleaner.PreparedConfiguration
    }

    let root: URL
    let appProfiles: AppProfiles
    private let lock = NSRecursiveLock()
    private var cachedDocStamp: FileStamp?
    private var cachedDocument: Document?
    private var fileDraftCache: [FileCacheKey: (stamp: FileStamp, drafts: [PersonalizationDraft])] = [:]
    private var preparedCache: [[StoreStamp]: PreparedBundle] = [:]
    private(set) var compileCount: Int = 0
    private(set) var diskReadCount: Int = 0

    init(root: URL, appProfiles: AppProfiles? = nil) {
        self.root = root
        self.appProfiles = appProfiles ?? AppProfiles(root: root)
    }

    private var url: URL { root.appendingPathComponent("vocabulary-sets.json") }

    func document() throws -> Document {
        lock.lock(); defer { lock.unlock() }
        let stamp = FileStamp.capture(url)
        if let cachedDocument, cachedDocStamp == stamp {
            return cachedDocument
        }
        guard stamp.exists else {
            let empty = Document()
            cachedDocStamp = stamp
            cachedDocument = empty
            return empty
        }
        diskReadCount += 1
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw PersonalizationError.tooLarge }
        let value = try JSONDecoder().decode(Document.self, from: data)
        guard value.version == 1, value.sets.count <= 100,
              Set(value.sets.map(\.id)).count == value.sets.count else {
            throw PersonalizationError.invalid("This vocabulary-set file cannot be read. Your existing lists are unchanged.")
        }
        cachedDocStamp = stamp
        cachedDocument = value
        return value
    }

    func update(_ body: (inout Document) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var doc = try document(); try body(&doc)
        guard doc.sets.count <= 100 else { throw PersonalizationError.tooMany }
        for set in doc.sets {
            guard !set.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  set.name.count <= 80, set.bundleID.count <= 200, set.language.count <= 20 else {
                throw PersonalizationError.invalid("Give the set a short name and a valid app/language scope.")
            }
        }
        try PrivateFile.write(JSONEncoder().encode(doc), to: url)
        cachedDocStamp = FileStamp.capture(url)
        cachedDocument = doc
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    func store(_ id: UUID?) -> PersonalizationStore {
        guard let id else { return PersonalizationStore(root: root) }
        return PersonalizationStore(root: root.appendingPathComponent("vocabulary-sets").appendingPathComponent(id.uuidString))
    }

    /// Global entries first, automatic sets by increasing specificity, manual set last.
    /// Ties have a stable UUID order. A later matching trigger overrides an earlier one.
    static func matching(_ doc: Document, bundleID: String?, language: String) -> [VocabularySet] {
        let eligible = doc.sets.filter { set in
            set.enabled && (set.language.isEmpty || set.language.lowercased() == language.lowercased())
                && (set.bundleID.isEmpty ? set.id == doc.active : set.bundleID == bundleID)
        }
        return eligible.sorted {
            func priority(_ s: VocabularySet) -> Int {
                (s.id == doc.active ? 4 : 0) + (s.bundleID.isEmpty ? 0 : 1) + (s.language.isEmpty ? 0 : 1)
            }
            return priority($0) == priority($1) ? $0.id.uuidString < $1.id.uuidString : priority($0) < priority($1)
        }
    }

    private func cachedDrafts(store: PersonalizationStore, kind: PersonalizationKind) -> (stamp: FileStamp, drafts: [PersonalizationDraft]) {
        let fileURL = store.root.appendingPathComponent(kind.filename)
        let stamp = FileStamp.capture(fileURL)
        let key = FileCacheKey(rootPath: store.root.standardizedFileURL.path, kind: kind)
        if let hit = fileDraftCache[key], hit.stamp == stamp {
            return hit
        }
        guard stamp.exists else {
            let empty: [PersonalizationDraft] = []
            fileDraftCache[key] = (stamp, empty)
            return (stamp, empty)
        }
        diskReadCount += 1
        let loaded = ((try? store.snapshot(kind).entries) ?? []).map(\.draft)
        fileDraftCache[key] = (stamp, loaded)
        return (stamp, loaded)
    }

    func configuration(bundleID: String?, previewSet: UUID? = nil, preview: Bool = false) -> PersonalizationConfiguration {
        lock.lock(); defer { lock.unlock() }
        let doc = (try? document()) ?? Document()
        let matches = previewSet.flatMap { id in doc.sets.first { $0.id == id } }.map { [$0] }
            ?? (preview ? [] : Self.matching(doc, bundleID: bundleID, language: doc.language))
        let storeIDs: [UUID?] = [nil] + matches.map { Optional($0.id) }
        let stores = storeIDs.map(store)

        var storeStamps: [StoreStamp] = []
        storeStamps.reserveCapacity(stores.count)
        var storeDrafts: [[PersonalizationDraft]] = []
        storeDrafts.reserveCapacity(stores.count)

        for currentStore in stores {
            let dict = cachedDrafts(store: currentStore, kind: .dictionary)
            let snip = cachedDrafts(store: currentStore, kind: .snippet)
            let corr = cachedDrafts(store: currentStore, kind: .correction)
            storeStamps.append(StoreStamp(
                rootPath: currentStore.root.standardizedFileURL.path,
                dictionary: dict.stamp,
                snippet: snip.stamp,
                correction: corr.stamp
            ))
            storeDrafts.append(dict.drafts + snip.drafts + corr.drafts)
        }

        let resolvedProfile = preview ? ResolvedAppProfile.unnamedDefault : appProfiles.resolve(bundleID: bundleID)
        let names = ["Global"] + matches.map(\.name)

        if let cached = preparedCache[storeStamps] {
            return PersonalizationConfiguration(
                entries: cached.entries,
                names: names,
                bundleID: bundleID,
                appProfile: resolvedProfile,
                prepared: cached.prepared
            )
        }

        var entries: [PersonalizationDraft] = []
        var positions: [String: Int] = [:]
        for drafts in storeDrafts {
            for draft in drafts {
                let key = draft.kind.rawValue + ":" + draft.primary.precomposedStringWithCanonicalMapping.lowercased()
                if let index = positions[key] { entries[index] = draft }
                else { positions[key] = entries.count; entries.append(draft) }
            }
        }
        let prepared = Cleaner.PreparedConfiguration(entries)
        compileCount += 1
        if preparedCache.count >= 32 { preparedCache.removeAll(keepingCapacity: true) }
        preparedCache[storeStamps] = PreparedBundle(entries: entries, prepared: prepared)
        return PersonalizationConfiguration(
            entries: entries,
            names: names,
            bundleID: bundleID,
            appProfile: resolvedProfile,
            prepared: prepared
        )
    }
}

/// Resolves the physical-boundary app lease and freezes the rules while recording starts.
/// Neither file reads nor Accessibility run on the hotkey/session queue.
final class VocabularyCapture: @unchecked Sendable {
    let task: Task<PersonalizationConfiguration, Never>
    init(lease: Paster.TargetLease?) {
        task = Task.detached(priority: .userInitiated) {
            let app: String? = await withCheckedContinuation { continuation in
                Paster.resolveTargetCapture(lease) { result in
                    if case .captured(let target) = result { continuation.resume(returning: target.app.bundleID) }
                    else { continuation.resume(returning: nil) }
                }
            }
            return VocabularySets.shared.configuration(bundleID: app)
        }
    }
}

enum PersonalizationExchange {
    struct Document: Codable { var version = 1; let entries: [PersonalizationDraft] }
    static func encode(_ entries: [PersonalizationDraft], csv: Bool) throws -> Data {
        if !csv {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(Document(entries: entries))
        }
        func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return Data((["kind,primary,replacement"] + entries.map {
            [field($0.kind.rawValue), field($0.primary), field($0.replacement ?? "")].joined(separator: ",")
        }).joined(separator: "\r\n").utf8)
    }
    static func importText(_ data: Data, extension ext: String, kind: PersonalizationKind) throws -> Data {
        guard data.count <= 1_048_576 else { throw PersonalizationError.tooLarge }
        if ext != "json" && ext != "csv" { return data }
        let entries: [PersonalizationDraft]
        if ext == "json" {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw PersonalizationError.invalid("Unsupported export version.") }
            entries = document.entries
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw PersonalizationError.notUTF8 }
            let rows = try csvRows(text)
            guard rows.first == ["kind", "primary", "replacement"] else {
                throw PersonalizationError.invalid("CSV columns must be kind,primary,replacement.")
            }
            entries = try rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map {
                guard $0.count == 3, let kind = PersonalizationKind(rawValue: $0[0]) else {
                    throw PersonalizationError.invalid("Invalid CSV row.")
                }
                return PersonalizationDraft(kind: kind, primary: $0[1], replacement: kind == .dictionary ? nil : $0[2])
            }
        }
        let validated = try entries.filter { $0.kind == kind }.map(PersonalizationStore.validated)
        let lines = validated.map { entry in
            entry.kind == .dictionary ? entry.primary
                : entry.primary + " -> " + (entry.replacement ?? "").replacingOccurrences(of: "\n", with: "\\n")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    static func csvRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if !quoted && c == "," { row.append(field); field = "" }
            else if !quoted && (c == "\n" || c == "\r") { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw PersonalizationError.invalid("Unclosed CSV quote.") }
        if !row.isEmpty || !field.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

extension VocabularySets {
    /// "English" for "en"; the code itself when the system has no name for it.
    static func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Any language" }
        return Locale.current.localizedString(forLanguageCode: trimmed) ?? trimmed
    }
}

/// The set a personalization page edits, as one labelled scope control. Activation and the
/// dictation language live behind "Set options" so the list stays the first thing you see.
struct VocabularySetControls<Trailing: View>: View {
    @Binding var selection: UUID?
    @ViewBuilder var trailing: Trailing
    @State private var doc = VocabularySets.Document()
    @State private var editing = false
    @State private var showOptions = false
    @State private var name = ""
    @State private var app = ""
    @State private var language = ""
    @State private var dictationLanguage = ""
    @State private var error = ""
    @State private var editingID: UUID?
    private var selectedSet: VocabularySet? { selection.flatMap { id in doc.sets.first { $0.id == id } } }
    /// What the selected scope affects, in words.
    private var summary: String {
        guard let set = selectedSet else { return "Applies to every dictation" }
        var parts = [set.bundleID.isEmpty ? (doc.active == set.id ? "Manual · in use" : "Manual · not in use")
                                          : "Only in \(InstalledApp.name(set.bundleID))"]
        if !set.language.isEmpty { parts.append("\(VocabularySets.languageName(set.language)) only") }
        if !set.enabled { parts.append("Disabled") }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Vocabulary").foregroundStyle(Theme.muted)
                Menu {
                    Picker("Edit entries in", selection: $selection) {
                        Text("Global").tag(nil as UUID?)
                        ForEach(doc.sets) { Text($0.name).tag(Optional($0.id)) }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("New set…") { beginEdit(nil) }
                    if let set = selectedSet { Button("Edit “\(set.name)”…") { beginEdit(set) } }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedSet?.name ?? "Global")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .fixedSize()
                .accessibilityLabel("Vocabulary set")
                .accessibilityValue(selectedSet?.name ?? "Global")
                Text(summary).font(UIStyle.caption).foregroundStyle(Theme.muted).lineLimit(1)
                Button { showOptions.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Set options")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showOptions ? 180 : 0))
                    }
                    .font(UIStyle.caption.weight(.medium)).foregroundStyle(Theme.accentText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showOptions ? "Hide set options" : "Show set options")
                Spacer(minLength: 0)
                trailing
            }
            if showOptions { options }
            if !error.isEmpty { Feedback(text: error, kind: .error) }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: VocabularySets.didChange)) { _ in reload() }
        .sheet(isPresented: $editing) { editor }
    }
    /// Activation and the dictation language: set administration, out of the list's way.
    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Dictation language")
                TextField("en", text: $dictationLanguage).frame(width: 64)
                    .accessibilityLabel("Dictation language code")
                    .onSubmit(saveLanguage)
                Text(VocabularySets.languageName(dictationLanguage)).foregroundStyle(Theme.muted)
                Button("Set language", action: saveLanguage)
                    .disabled(dictationLanguage.trimmingCharacters(in: .whitespaces) == doc.language)
            }
            if let set = selectedSet {
                Hairline()
                HStack(spacing: 8) {
                    Button("Edit “\(set.name)”…") { beginEdit(set) }
                    Button(set.enabled ? "Disable" : "Enable") { change { d in
                        if let i = d.sets.firstIndex(where: { $0.id == set.id }) { d.sets[i].enabled.toggle() }
                    } }
                    if set.bundleID.isEmpty {
                        Button(doc.active == set.id ? "Deactivate" : "Use this set") {
                            change { $0.active = $0.active == set.id ? nil : set.id }
                        }
                    }
                }
            } else if let activeName = doc.sets.first(where: { $0.id == doc.active })?.name {
                Hairline()
                Text("Manual set in use: \(activeName)")
            }
        }
        .padding(Theme.flatPanels ? 0 : 14)
        .padding(.vertical, Theme.flatPanels ? 4 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.flatPanels ? .clear : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.flatPanels ? .clear : Theme.divider))
    }
    private var editor: some View {
        SheetFrame(title: editingID == nil ? "New vocabulary set" : "Edit vocabulary set", width: 490) {
            VStack(alignment: .leading, spacing: 16) {
                LabeledSheetField(label: "Name") { TextField("Project names", text: $name) }
                LabeledSheetField(label: "App") {
                    HStack(spacing: 8) {
                        TextField("App bundle ID (blank for manual)", text: $app)
                        Button("Choose application…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { app = Bundle(url: url)?.bundleIdentifier ?? "" }
                        }
                    }
                }
                LabeledSheetField(label: "Language") {
                    HStack(spacing: 8) {
                        TextField("en", text: $language).frame(width: 90).accessibilityLabel("Language code")
                        Text(VocabularySets.languageName(language)).foregroundStyle(Theme.muted)
                    }
                }
                if !error.isEmpty { Feedback(text: error, kind: .error) }
            }
        } footer: {
            Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let set = VocabularySet(id: editingID ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    bundleID: app.trimmingCharacters(in: .whitespaces), language: language.trimmingCharacters(in: .whitespaces).lowercased())
                do { try VocabularySets.shared.update { doc in
                    if let index = doc.sets.firstIndex(where: { $0.id == set.id }) {
                        var updated = set; updated.enabled = doc.sets[index].enabled; doc.sets[index] = updated
                    } else { doc.sets.append(set) }
                }; selection = set.id; editing = false; reload() }
                catch { self.error = error.localizedDescription }
            }
            .prominent().keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    private func beginEdit(_ set: VocabularySet?) {
        editingID = set?.id; name = set?.name ?? ""; app = set?.bundleID ?? ""; language = set?.language ?? ""
        editing = true
    }
    private func saveLanguage() {
        let value = dictationLanguage.trimmingCharacters(in: .whitespaces)
        change { $0.language = value }
    }
    private func change(_ body: (inout VocabularySets.Document) -> Void) {
        do { try VocabularySets.shared.update(body); reload() } catch { self.error = error.localizedDescription }
    }
    private func reload() {
        do { doc = try VocabularySets.shared.document(); dictationLanguage = doc.language; error = "" }
        catch { self.error = error.localizedDescription }
    }
}

struct VocabularyPreflight: View {
    let selection: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var output = ""
    @State private var changes: [String] = []
    @State private var hasRun = false
    var body: some View {
        SheetFrame(title: "Test these rules", width: 600) {
            VStack(alignment: .leading, spacing: 14) {
                LabeledSheetField(label: "Sample transcript") {
                    // The AppKit editor keeps smart quotes and dashes off, so the sample is tested as typed.
                    DraftTextEditor(text: $input, label: "Sample transcript").frame(height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.fieldStroke))
                }
                LabeledSheetField(label: "Result") {
                    ScrollView {
                        Text(output.isEmpty ? " " : output).font(Theme.writingFont).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(height: 110)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.divider))
                }
                if hasRun {
                    Text(changes.isEmpty ? "No rules matched." : changes.joined(separator: "\n"))
                        .font(UIStyle.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
        } footer: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Run test") {
                let configuration = VocabularySets.shared.configuration(bundleID: nil, previewSet: selection, preview: true)
                let result = Cleaner.cleanWithChanges(input, configuration: configuration)
                output = result.text
                changes = result.changes.map { "\($0.original) → \($0.replacement)" }
                    + result.expandedSnippets.map { "Expanded snippet: \($0)" }
                hasRun = true
            }.prominent()
        }
    }
}
