import Cocoa
import SwiftUI
import Combine

enum MicrophonePreferences {
    static var preferredUID: String? {
        get { UserDefaults.standard.string(forKey: "preferredMicrophoneUID") }
        set { UserDefaults.standard.set(newValue?.isEmpty == true ? nil : newValue, forKey: "preferredMicrophoneUID") }
    }
    static var keepWarmSeconds: Double { UserDefaults.standard.bool(forKey: "closeMicrophoneImmediately") ? 0 : Recorder.idleKeepWarmSeconds }
}

enum ShortcutRecordingTarget: Identifiable, Equatable {
    case flow(FlowAction)
    case shortcut(ShortcutAction)

    var id: String {
        switch self {
        case .flow(let action): return "flow.\(action.rawValue)"
        case .shortcut(let action): return "shortcut.\(action.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .flow(let action): return action.title
        case .shortcut(let action): return action.title
        }
    }

    var allowsDictationChord: Bool {
        if case .flow(.dictate) = self { return true }
        return false
    }

    func makeBinding(keyCode: UInt16?, modifiers: UInt64, keyLabel: String) -> ShortcutBinding {
        switch self {
        case .flow(let action):
            return ShortcutBinding(action: action, keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel)
        case .shortcut(let action):
            return ShortcutBinding(shortcutAction: action, keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel)
        }
    }
}

struct ShortcutSettings: View {
    @State private var bindings = ShortcutStore.shared.bindings
    @State private var recording: ShortcutRecordingTarget?
    @State private var error = ""
    @Bindable private var workspace = DictationWorkspace.shared
    var body: some View {
        SectionCard("Keyboard shortcuts") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(FlowAction.allCases.enumerated()), id: \.element) { index, action in
                    if index > 0 { Hairline() }
                    HStack(spacing: 8) {
                        Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(bindings.filter { $0.action == action }) { binding in
                            Button("\(binding.title) ×") { change { try ShortcutStore.shared.remove(binding.id) } }
                                .help("Remove \(binding.title)")
                                .accessibilityLabel("Remove \(binding.title) from \(action.title)")
                        }
                        Button("Set…") { recording = .flow(action) }.disabled(workspace.recording || workspace.processing)
                            .accessibilityLabel("Set shortcut for \(action.title)")
                    }
                    .padding(.vertical, 6)
                }
                ForEach(ShortcutAction.allCases) { shortcutAction in
                    Hairline()
                    HStack(spacing: 8) {
                        Text(shortcutAction.title).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(bindings.filter { $0.shortcutAction == shortcutAction }) { binding in
                            Button("\(binding.title) ×") { change { try ShortcutStore.shared.remove(binding.id) } }
                                .help("Remove \(binding.title)")
                                .accessibilityLabel("Remove \(binding.title) from \(shortcutAction.title)")
                        }
                        Button("Set…") { recording = .shortcut(shortcutAction) }.disabled(workspace.recording || workspace.processing)
                            .accessibilityLabel("Set shortcut for \(shortcutAction.title)")
                    }
                    .padding(.vertical, 6)
                }
            }
            Button("Reset shortcuts") { change { try ShortcutStore.shared.reset() } }
                .padding(.top, 4)
            if !error.isEmpty { Feedback(text: error, kind: .error) }
        }.onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in bindings = ShortcutStore.shared.bindings }
        .sheet(item: $recording) { target in
            ShortcutCaptureSheet(target: target) { value in
                do {
                    try Self.saveBinding(value, in: ShortcutStore.shared)
                    bindings = ShortcutStore.shared.bindings
                    recording = nil
                    error = ""
                } catch {
                    self.error = error.localizedDescription
                    recording = nil
                }
            } cancel: { recording = nil }
        }
    }

    /// Saves `value`, replacing Push-to-Talk Slot 2 atomically when both Push-to-Talk slots are already occupied.
    static func saveBinding(_ value: ShortcutBinding, in store: ShortcutStore = .shared) throws {
        var resolved = value
        if value.action == .dictate {
            let existingDictate = store.bindings.filter { $0.action == .dictate }
            if existingDictate.count >= 2, !existingDictate.contains(where: { $0.id == value.id }) {
                let slot2 = existingDictate[1]
                resolved = ShortcutBinding(
                    id: slot2.id,
                    action: .dictate,
                    keyCode: value.keyCode,
                    modifiers: value.modifiers,
                    keyLabel: value.keyLabel
                )
            }
        }
        try store.save(resolved)
    }

    private func change(_ operation: () throws -> Void) {
        do { try operation(); bindings = ShortcutStore.shared.bindings; error = "" }
        catch { self.error = error.localizedDescription }
    }
}

private struct ShortcutCaptureSheet: View {
    let target: ShortcutRecordingTarget
    let save: (ShortcutBinding) -> Void
    let cancel: () -> Void
    var body: some View {
        SheetFrame(title: "Shortcut for \(target.title)",
                   width: 510) {
            KeyRecorder(target: target, save: save, cancel: cancel).frame(height: 50)
                .background { Text("Waiting for a key…").font(UIStyle.caption).foregroundStyle(Theme.muted) }
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.accent, lineWidth: 2))
            HStack(spacing: 8) {
                Button("Use fn") {
                    save(target.makeBinding(keyCode: ShortcutBinding.fnKeyCode, modifiers: 0, keyLabel: "fn"))
                }
                Button("Use Right ⌘") {
                    save(target.makeBinding(
                        keyCode: ShortcutBinding.rightCommandKeyCode,
                        modifiers: CGEventFlags.maskCommand.rawValue,
                        keyLabel: "Right ⌘"
                    ))
                }
                Button("Use Right ⌥") {
                    save(target.makeBinding(
                        keyCode: ShortcutBinding.rightOptionKeyCode,
                        modifiers: CGEventFlags.maskAlternate.rawValue,
                        keyLabel: "Right ⌥"
                    ))
                }
                if target.allowsDictationChord {
                    Button("Use Control + Option") {
                        save(target.makeBinding(
                            keyCode: nil,
                            modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue,
                            keyLabel: ""
                        ))
                    }
                }
            }
        } footer: {
            Button("Cancel", action: cancel)
        }
        .onAppear { ShortcutStore.shared.recording = true }
        .onDisappear { ShortcutStore.shared.recording = false }
    }
}

private struct KeyRecorder: NSViewRepresentable {
    let target: ShortcutRecordingTarget
    let save: (ShortcutBinding) -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> KeyRecorderView {
        let view = KeyRecorderView(); view.target = target; view.save = save; view.cancel = cancel; return view
    }
    func updateNSView(_ view: KeyRecorderView, context: Context) {}
}
private final class KeyRecorderView: NSView {
    var target: ShortcutRecordingTarget = .flow(.dictate)
    var save: ((ShortcutBinding) -> Void)?
    var cancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?(); return }
        guard !event.isARepeat else { return }
        save?(target.makeBinding(
            keyCode: event.keyCode,
            modifiers: UInt64(event.modifierFlags.rawValue) & ShortcutBinding.modifierMask,
            keyLabel: event.charactersIgnoringModifiers ?? "Key \(event.keyCode)"
        ))
    }
    override func flagsChanged(with event: NSEvent) {
        if event.keyCode == ShortcutBinding.fnKeyCode, event.modifierFlags.contains(.function) {
            save?(target.makeBinding(
                keyCode: ShortcutBinding.fnKeyCode,
                modifiers: UInt64(event.modifierFlags.rawValue) & ShortcutBinding.modifierMask,
                keyLabel: "fn"
            ))
        } else if event.keyCode == ShortcutBinding.rightCommandKeyCode, event.modifierFlags.contains(.command) {
            save?(target.makeBinding(
                keyCode: ShortcutBinding.rightCommandKeyCode,
                modifiers: UInt64(event.modifierFlags.rawValue) & ShortcutBinding.modifierMask,
                keyLabel: "Right ⌘"
            ))
        } else if event.keyCode == ShortcutBinding.rightOptionKeyCode, event.modifierFlags.contains(.option) {
            save?(target.makeBinding(
                keyCode: ShortcutBinding.rightOptionKeyCode,
                modifiers: UInt64(event.modifierFlags.rawValue) & ShortcutBinding.modifierMask,
                keyLabel: "Right ⌥"
            ))
        }
    }
}

struct MicrophoneSettings: View {
    @State private var devices: [AudioInputDevice] = []
    @State private var selected = MicrophonePreferences.preferredUID ?? ""
    @AppStorage("closeMicrophoneImmediately") private var closeImmediately = false
    @AppStorage(MediaPause.defaultsKey) private var pauseMedia = true
    @State private var practice = false
    @Bindable private var workspace = DictationWorkspace.shared
    var body: some View {
        SectionCard("Microphone & setup") {
            VStack(alignment: .leading, spacing: 18) {
                SettingGroup {
                    // A fixed pop-up width, so the row doesn't jump when the device list arrives.
                    HStack(spacing: 10) {
                        Text("Preferred microphone").accessibilityHidden(true)
                        ThemedMenuPicker(label: "Preferred microphone",
                                         options: [("", "Automatic")] + devices.map { ($0.uid, $0.name) }
                                            + (!selected.isEmpty && !devices.contains(where: { $0.uid == selected }) ? [(selected, "Preferred device unavailable")] : []),
                                         selection: $selected, width: 280)
                        .disabled(workspace.recording)
                    }
                    Text("Last opened: \(workspace.microphone)").foregroundStyle(Theme.muted)
                }
                SettingGroup {
                    Toggle("Close microphone immediately after recording", isOn: $closeImmediately)
                        .onChange(of: closeImmediately) { _, _ in workspace.onMicrophonePolicy() }
                }
                SettingGroup {
                    Toggle("Pause media while dictating", isOn: $pauseMedia)
                        .accessibilityIdentifier("pauseMediaWhileDictating")
                        .onChange(of: pauseMedia) { _, new in log("pause media while dictating = \(new)") }
                }
                HStack(spacing: 8) {
                    Button("Refresh microphones") { refresh() }
                    Button("Test dictation setup…") { practice = true }.prominent()
                }
            }
        }.onAppear { refresh() }
        .onChange(of: selected) { _, value in MicrophonePreferences.preferredUID = value }
        .sheet(isPresented: $practice) { DictationPracticePage() }
    }
    private func refresh() {
        Task {
            let available = await Task.detached(priority: .utility) { AudioInputRouter.devices().filter(\.isUsable) }.value
            devices = available
        }
    }
}

struct DictationPracticePage: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var workspace = DictationWorkspace.shared
    var body: some View {
        SheetFrame(title: "Test dictation setup",
                   subtitle: "Hold \(ShortcutStore.shared.label(.dictate)), speak into the field below, then release.",
                   width: 650) {
            HStack {
                Label(workspace.shortcutObserved ? "Shortcut received" : "Waiting for shortcut", systemImage: workspace.shortcutObserved ? "checkmark.circle" : "keyboard")
                Spacer()
                Label(workspace.modelReady ? "Speech model ready" : SpeechModelState.shared.status.shortLabel, systemImage: "waveform")
            }
            ProgressView(value: Double(workspace.level), total: 1).tint(Theme.accent).accessibilityLabel("Microphone input level")
            Text("Microphone: \(workspace.microphone)").foregroundStyle(Theme.muted)
            DraftTextEditor(text: $workspace.practiceText, label: "Practice dictation field").frame(height: 150)
                .accessibilityIdentifier("dictationPracticeField")
                .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.fieldStroke))
            if workspace.practiceDelivered {
                Text("Insertion confirmed.").foregroundStyle(Theme.muted)
            }
        } footer: {
            if workspace.recording {
                Button("Finish") { workspace.onStop() }
                Button("Cancel recording") { workspace.onCancel() }
            }
            Button("Done") { workspace.onCancel(); dismiss() }.keyboardShortcut(.cancelAction).prominent()
        }
        .onAppear { workspace.practiceText = ""; workspace.practiceDelivered = false; workspace.shortcutObserved = false; workspace.onPractice(true) }
        .onDisappear { workspace.onCancel(); workspace.onPractice(false); workspace.practiceText = "" }
    }
}
