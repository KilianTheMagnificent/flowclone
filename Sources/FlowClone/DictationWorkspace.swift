import Cocoa
import SwiftUI

enum DeliveryState: String, Codable, Sendable {
    case ready, draft, confirmed, unverified, notInserted, learned
    var label: String {
        switch self {
        case .ready: "Text ready"; case .draft: "Saved to draft"; case .confirmed: "Insertion confirmed"
        case .unverified: "Insertion unverified"; case .notInserted: "Not inserted"; case .learned: "Spelling rule saved"
        }
    }
}

@MainActor @Observable
final class DictationWorkspace {
    static let shared = DictationWorkspace()
    var draft = "" { didSet { if draft != oldValue { scheduleSave() } } }
    var status = ""
    var recording = false
    var processing = false
    var modelReady = false
    var microphone = "Not opened yet"
    var level: Float = 0
    var retryAvailable = false
    var captureLabel = "Dictation"
    var shortcutObserved = false
    var practiceText = ""
    var practiceDelivered = false
    var onCapture: (CapturePurpose, Paster.TargetLease?) -> Void = { _, _ in }
    var onStop: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onPaste: (String, Paster.TargetLease?) -> Void = { _, _ in }
    var onPractice: (Bool) -> Void = { _ in }
    var onMicrophonePolicy: () -> Void = {}
    var onRetranscribe: (History.Item) -> Void = { _ in }
    private var recovered: Set<UUID> = []
    private let persistence = DraftPersistence()
    private var saveWork: DispatchWorkItem?
    private var loaded = false
    private let defaults: UserDefaults
    private let url: URL

    init(defaults: UserDefaults = .standard, url: URL? = nil) {
        self.defaults = defaults
        self.url = url ?? PersonalizationStore.shared.root.appendingPathComponent("draft.json")
    }
    var savesDraft: Bool {
        get { defaults.object(forKey: "saveDraft") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "saveDraft")
            if !newValue { saveWork?.cancel(); persistence.remove(url) }
            else { scheduleSave() }
        }
    }
    func load() {
        guard !loaded else { return }; loaded = true
        guard savesDraft, History.isEnabled,
              let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let value = try? JSONDecoder().decode(SavedDraft.self, from: data), value.version == 1 else { return }
        draft = value.text
    }
    func privacyChanged() {
        saveWork?.cancel()
        if !History.isEnabled {
            // An off-period draft must not silently become durable when history returns.
            defaults.set(false, forKey: "saveDraft")
            persistence.remove(url)
        }
    }
    private func scheduleSave() {
        guard loaded else { return }
        saveWork?.cancel()
        guard savesDraft, History.isEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.savesDraft, History.isEnabled else { return }
            self.persistence.save(SavedDraft(text: self.draft), to: self.url)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func flush() {
        saveWork?.cancel()
        if loaded, savesDraft, History.isEnabled { persistence.save(SavedDraft(text: draft), to: url) }
        persistence.flush()
    }
    func recover(_ text: String, id: UUID, state: DeliveryState) {
        guard !text.isEmpty, recovered.insert(id).inserted else { return }
        if recovered.count > 100 { recovered = [id] }
        append(text)
        status = state == .unverified
            ? "Insertion could not be confirmed. Check the original app before inserting again."
            : "Your text is safe in this draft. Copy it or use Insert draft here in the destination app."
    }
    /// How the Draft page presents `status`: a delivery or undo problem is a warning, a copy a success.
    var statusKind: FeedbackKind { Self.feedbackKind(for: status) }
    nonisolated static func feedbackKind(for status: String) -> FeedbackKind {
        let text = status.lowercased()
        if ["could not", "not be confirmed", "unavailable", "not readable", "changed."].contains(where: { text.contains($0) }) { return .warning }
        return text == "draft copied." ? .success : .information
    }
    func append(_ text: String) {
        load()
        if draft.isEmpty { draft = text }
        else { draft += (draft.hasSuffix("\n") ? "" : "\n\n") + text }
    }
    func perform(_ action: FlowAction, lease: Paster.TargetLease? = nil) {
        switch action {
        case .dictate, .handsFree: onCapture(.editor(.normal), lease)
        case .draft: onCapture(.draft, nil)
        case .literal: onCapture(.editor(.literal), lease)
        case .spelling: onCapture(.editor(.spelling), lease)
        case .pasteDraft:
            guard !draft.isEmpty else { status = "The draft is empty."; return }
            onPaste(draft, lease)
        case .copyLast:
            if let text = History.items.first?.final { _ = Paster.writeTranscript(text) }
        case .editSelection: TransformController.shared.begin(spoken: true, lease: lease)
        case .editLast: LastInsertionController.shared.edit()
        case .undoLast: LastInsertionController.shared.undo()
        case .actions: ActionPalette.shared.show(lease: lease)
        }
    }
}

private struct SavedDraft: Codable, Sendable { var version = 1; let text: String }
private final class DraftPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flowclone.draft", qos: .utility)
    func save(_ draft: SavedDraft, to url: URL) {
        queue.async {
            do { try PrivateFile.write(JSONEncoder().encode(draft), to: url) }
            catch { log("Draft could not be saved; the in-memory draft remains available.") }
        }
    }
    func remove(_ url: URL) { queue.async { try? FileManager.default.removeItem(at: url) } }
    func flush() { queue.sync {} }
}

struct DraftPage: View {
    @Bindable var workspace = DictationWorkspace.shared
    @State private var clear = false
    @State private var formatting = false
    var body: some View {
        let empty = workspace.draft.isEmpty
        let words = TranscriptionStats.wordCount(in: workspace.draft)
        VStack(alignment: .leading, spacing: 14) {
            PageHeader("Draft")
            // Classic's Draft is just the sheet: dictation into it starts from the shortcut or All actions.
            if !Theme.current.journalHome { CaptureBar(compact: true) }
            if !workspace.status.isEmpty || workspace.retryAvailable {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if !workspace.status.isEmpty {
                        Feedback(text: workspace.status, kind: workspace.statusKind)
                    }
                    Spacer(minLength: 0)
                    if workspace.retryAvailable { Button("Retry failed recording into draft") { workspace.onRetry() } }
                }
            }
            DraftTextEditor(text: $workspace.draft, fill: \.field)
                .frame(minHeight: 140)
                .themedEditor(composer: Theme.current.bookSerif)
                .accessibilityIdentifier("dictationDraft")
            // The editor's footer: length and whether it outlives a quit, then the draft actions.
            HStack(spacing: 12) {
                Text(words == 1 ? "1 word" : "\(words) words").monospacedDigit()
                    .font(UIStyle.caption).foregroundStyle(Theme.muted)
                Toggle("Keep draft between launches", isOn: Binding(get: { workspace.savesDraft }, set: { workspace.savesDraft = $0 }))
                    .disabled(!History.isEnabled).font(UIStyle.caption)
                Spacer(minLength: 8)
                Button("Clear…", role: .destructive) { clear = true }.disabled(empty)
                Button("Format…") { formatting = true }.disabled(empty)
                Button("Copy draft") { if Paster.writeTranscript(workspace.draft) { workspace.status = "Draft copied." } }
                    .disabled(empty)
            }
            if !History.isEnabled {
                Text("Turn on Save dictation history in Settings to keep drafts between launches.")
                    .font(UIStyle.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).proseWidth()
            }
        }.pageColumn().onAppear { workspace.load() }
        .sheet(isPresented: $formatting) { FormatPreview(text: $workspace.draft) }
        .confirmationDialog("Clear this draft?", isPresented: $clear) {
            Button("Clear draft", role: .destructive) { workspace.draft = ""; workspace.status = "Draft cleared." }
        }
    }
}

private struct FormatPreview: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var format = TextFormatter.snake
    @State private var original = ""
    var body: some View {
        SheetFrame(title: "Format draft") {
            ThemedMenuPicker(label: "Format", options: TextFormatter.allCases.map { ($0, $0.rawValue) }, selection: $format)
            ScrollView {
                Text(format.apply(original)).font(Theme.writingFont).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(height: 200)
            .themedEditor()
            if text != original { Feedback(text: "The draft changed. Close this preview and reopen it.", kind: .warning) }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Apply to draft") {
                guard text == original else { return }; text = format.apply(original); dismiss()
            }.prominent().disabled(text != original)
        }
        .onAppear { original = text }
    }
}

struct DraftTextEditor: NSViewRepresentable {
    @Binding var text: String
    var label = "Draft text"
    /// The editor's own fill: the raised surface by default, `\.field` inside a `.themedEditor()` well.
    var fill: KeyPath<ThemePalette, UInt32> = \.card
    var theme: AppTheme = Theme.current
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = Theme.nativeWritingFont(16)
        editor.backgroundColor = Theme.nativeColor(fill)
        editor.textColor = Theme.nativeColor(\.ink)
        editor.insertionPointColor = Theme.nativeColor(\.ink)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.delegate = context.coordinator; editor.string = text
        editor.setAccessibilityLabel(label)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let _ = theme
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text { editor.string = text }
        editor.font = Theme.nativeWritingFont(16)
        editor.backgroundColor = Theme.nativeColor(fill)
        editor.textColor = Theme.nativeColor(\.ink)
        editor.insertionPointColor = Theme.nativeColor(\.ink)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftTextEditor
        init(_ parent: DraftTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}

@MainActor @Observable
final class ActionPaletteModel {
    var query = "" {
        didSet {
            if query != oldValue { selectedIndex = 0 }
        }
    }
    var selectedIndex = 0
    var onChoose: (FlowAction) -> Void
    var onDismiss: () -> Void

    init(
        onChoose: @escaping (FlowAction) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.onChoose = onChoose
        self.onDismiss = onDismiss
    }

    var filteredActions: [FlowAction] {
        FlowAction.allCases.filter {
            $0 != .actions && $0 != .dictate
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }

    var selectedAction: FlowAction? {
        let current = filteredActions
        guard !current.isEmpty else { return nil }
        let clamped = min(max(0, selectedIndex), current.count - 1)
        return current[clamped]
    }

    @discardableResult
    func handleKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125: // Down arrow
            let count = filteredActions.count
            guard count > 0 else { return true }
            selectedIndex = (min(max(0, selectedIndex), count - 1) + 1) % count
            return true
        case 126: // Up arrow
            let count = filteredActions.count
            guard count > 0 else { return true }
            let clamped = min(max(0, selectedIndex), count - 1)
            selectedIndex = (clamped - 1 + count) % count
            return true
        case 36, 76: // Return / Keypad Enter
            if let action = selectedAction {
                onChoose(action)
            }
            return true
        case 53: // Escape
            if !query.isEmpty {
                query = ""
            } else {
                onDismiss()
            }
            return true
        default:
            return false
        }
    }
}

@MainActor final class ActionPalette {
    static let shared = ActionPalette()
    private var panel: ActionPanel?
    private(set) var model = ActionPaletteModel()

    func show(lease supplied: Paster.TargetLease? = nil) {
        let lease = supplied ?? Paster.beginTargetCaptureAtMenuBoundary()
        if panel == nil {
            let panel = ActionPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "FlowClone actions"; panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.center()
            self.panel = panel
        }
        let paletteModel = ActionPaletteModel(
            onChoose: { [weak self] action in
                self?.panel?.orderOut(nil)
                DictationWorkspace.shared.perform(action, lease: lease)
            },
            onDismiss: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )
        self.model = paletteModel
        panel?.keyHandler = { [weak paletteModel] keyCode in
            paletteModel?.handleKeyCode(keyCode) ?? false
        }
        // The panel's own fill matches the list's surface, so the theme reaches the edges.
        panel?.backgroundColor = Theme.nativeColor(\.card)
        panel?.contentView = NSHostingView(rootView: ActionList(model: paletteModel))
        panel?.makeKeyAndOrderFront(nil)
    }
}

@MainActor private final class ActionPanel: NSPanel {
    var keyHandler: ((UInt16) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           keyHandler?(event.keyCode) == true {
            return
        }
        super.sendEvent(event)
    }
}

struct ActionList: View {
    @Bindable var model: ActionPaletteModel
    @FocusState private var searchFocused: Bool

    init(model: ActionPaletteModel) {
        self.model = model
    }

    init(choose: @escaping (FlowAction) -> Void) {
        self.model = ActionPaletteModel(onChoose: choose)
    }

    var body: some View {
        let actions = model.filteredActions
        let clampedIndex = actions.isEmpty ? 0 : min(max(0, model.selectedIndex), actions.count - 1)
        VStack(alignment: .leading, spacing: 12) {
            SearchField(prompt: "Find an action", text: $model.query)
                .focused($searchFocused)
            if actions.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matching actions", actionTitle: "Clear search") { model.query = "" }
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                                ActionRow(
                                    action: action,
                                    isSelected: index == clampedIndex,
                                    choose: model.onChoose
                                )
                                .id(action)
                            }
                        }
                    }
                    .onChange(of: clampedIndex) { _, newIndex in
                        if actions.indices.contains(newIndex) {
                            scroller.scrollTo(actions[newIndex], anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(20).frame(width: 460, height: 500)
        .background(Theme.surface)
        .font(UIStyle.body).foregroundStyle(Theme.ink).tint(Theme.accent)
        .themedButtons()
        .onAppear { searchFocused = true }
    }
}

/// One action: its name in ink and its shortcut in the muted role (≥4.5:1), with selection + hover wash.
private struct ActionRow: View {
    let action: FlowAction
    var isSelected = false
    let choose: (FlowAction) -> Void
    @State private var hovering = false
    var body: some View {
        let shortcut = ShortcutStore.shared.label(action)
        Button { choose(action) } label: {
            HStack(spacing: 12) {
                Text(action.title).foregroundStyle(isSelected ? Theme.accentText : Theme.ink)
                Spacer(minLength: 8)
                Text(shortcut).font(UIStyle.caption).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32)
            .background(
                isSelected ? Theme.selection : (hovering ? Theme.rowHover : .clear),
                in: RoundedRectangle(cornerRadius: Theme.controlRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(action.title)
        .accessibilityValue(shortcut)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
