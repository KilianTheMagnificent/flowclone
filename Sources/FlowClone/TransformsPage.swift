import Cocoa
import SwiftUI

struct TransformPreset: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var instruction: String
}

/// Keep the legacy string array current too, so a local rollback retains edited instructions.
enum TransformPresets {
    static let key = "transformPresets"
    static let namedKey = "namedTransformPresets.v1"
    static let activePresetIDKey = "activeTransformPresetID.v1"
    static let activeKindKey = "activeTransformKind.v1"

    static func load(_ defaults: UserDefaults = .standard) -> [String] { defaults.stringArray(forKey: key) ?? [] }
    static func loadNamed(_ defaults: UserDefaults = .standard) -> [TransformPreset] {
        let legacy = load(defaults)
        if let data = defaults.data(forKey: namedKey),
           let named = try? JSONDecoder().decode([TransformPreset].self, from: data),
           named.map(\.instruction) == legacy { return named }
        return legacy.map { TransformPreset(name: suggestedName($0), instruction: $0) }
    }
    static func suggestedName(_ instruction: String) -> String {
        let line = instruction.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Custom preset"
        return String(line.prefix(42)) + (line.count > 42 ? "…" : "")
    }
    static func save(_ presets: [String], _ defaults: UserDefaults = .standard) {
        saveNamed(presets.map { TransformPreset(name: suggestedName($0), instruction: $0) }, defaults)
    }
    static func saveNamed(_ presets: [TransformPreset], _ defaults: UserDefaults = .standard) {
        let cleaned = presets.compactMap { preset -> TransformPreset? in
            let instruction = preset.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return TransformPreset(id: preset.id, name: name.isEmpty ? suggestedName(instruction) : name, instruction: instruction)
        }
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        defaults.set(data, forKey: namedKey)
        defaults.set(cleaned.map(\.instruction), forKey: key)
        if let raw = defaults.string(forKey: activePresetIDKey),
           let currentID = UUID(uuidString: raw),
           !cleaned.contains(where: { $0.id == currentID }) {
            setActivePresetID(nil, defaults)
        }
    }

    static func activePresetID(_ defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: activePresetIDKey),
              let id = UUID(uuidString: raw),
              loadNamed(defaults).contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    static func setActivePresetID(_ id: UUID?, _ defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(id.uuidString, forKey: activePresetIDKey)
            defaults.set(SelectionTransformKind.custom.rawValue, forKey: activeKindKey)
        } else {
            defaults.removeObject(forKey: activePresetIDKey)
            if defaults.string(forKey: activeKindKey) == SelectionTransformKind.custom.rawValue {
                defaults.set(SelectionTransformKind.polish.rawValue, forKey: activeKindKey)
            }
        }
    }

    static func activePreset(_ defaults: UserDefaults = .standard) -> TransformPreset? {
        guard let id = activePresetID(defaults) else { return nil }
        return loadNamed(defaults).first(where: { $0.id == id })
    }

    static func activeKind(_ defaults: UserDefaults = .standard) -> SelectionTransformKind {
        if activePreset(defaults) != nil { return .custom }
        if let raw = defaults.string(forKey: activeKindKey),
           let kind = SelectionTransformKind(rawValue: raw),
           kind != .custom {
            return kind
        }
        return .polish
    }

    static func setActiveKind(_ kind: SelectionTransformKind, _ defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: activeKindKey)
        if kind != .custom {
            defaults.removeObject(forKey: activePresetIDKey)
        }
    }
}

struct TransformsPage: View {
    @State private var presets = TransformPresets.loadNamed()
    @State private var activePresetID = TransformPresets.activePresetID()
    @State private var editing: TransformPreset?
    @State private var deleting: TransformPreset?
    @State private var undoAvailable = TransformController.shared.undoAvailable
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if undoAvailable || !presets.isEmpty {
                    PageHeader("Transforms") {
                        if undoAvailable {
                            Button("Undo last transform") {
                                TransformController.shared.undoLast()
                                undoAvailable = TransformController.shared.undoAvailable
                            }
                        }
                        if !presets.isEmpty {
                            Button("New preset…") { editing = TransformPreset(name: "", instruction: "") }.prominent()
                        }
                    }
                } else {
                    PageHeader("Transforms")
                }
                if presets.isEmpty {
                    EmptyState(symbol: "wand.and.stars", title: "No presets yet",
                               actionTitle: "New preset…") { editing = TransformPreset(name: "", instruction: "") }
                } else {
                    presetList
                }
            }.pageColumn()
        }
        .onAppear {
            presets = TransformPresets.loadNamed()
            activePresetID = TransformPresets.activePresetID()
            undoAvailable = TransformController.shared.undoAvailable
        }
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset) { edited in
                if let index = presets.firstIndex(where: { $0.id == edited.id }) { presets[index] = edited }
                else { presets.append(edited) }
                TransformPresets.saveNamed(presets)
                activePresetID = TransformPresets.activePresetID()
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "preset")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete preset", role: .destructive) {
                presets.removeAll { $0.id == deleting?.id }
                TransformPresets.saveNamed(presets)
                activePresetID = TransformPresets.activePresetID()
                deleting = nil
            }
        }
    }
    /// Presets share the instruction card's surface: one raised block of divided rows, or
    /// hairline-divided rows on Anthropic's flat page.
    private var presetList: some View {
        let flat = Theme.flatPanels
        return VStack(alignment: .leading, spacing: 0) {
            if flat { Hairline() }
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                let isActive = activePresetID == preset.id
                if index > 0 { Hairline().padding(.leading, flat ? 0 : 18) }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(preset.name).font(UIStyle.body.weight(.semibold))
                            if isActive {
                                Text("Active")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accentText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(preset.instruction).font(Theme.writingFont).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    .proseWidth()
                    Spacer(minLength: 12)
                    Button(isActive ? "Clear active" : "Set active") {
                        let next: UUID? = isActive ? nil : preset.id
                        TransformPresets.setActivePresetID(next)
                        activePresetID = next
                    }
                    Button("Edit") { editing = preset }
                    Button { deleting = preset } label: { Image(systemName: "trash") }
                        .help("Delete \(preset.name)").accessibilityLabel("Delete \(preset.name)")
                }
                .padding(.horizontal, flat ? 0 : 18).padding(.vertical, 8)
                .frame(minHeight: 56)
            }
            if flat { Hairline() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flat ? .clear : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(flat ? .clear : Theme.divider))
    }
}

struct PresetEditor: View {
    @State var preset: TransformPreset
    let onSave: (TransformPreset) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SheetFrame(title: "Custom preset", width: 500) {
            VStack(alignment: .leading, spacing: 16) {
                LabeledSheetField(label: "Name") { TextField("Concise email", text: $preset.name) }
                LabeledSheetField(label: "Instruction") {
                    TextEditor(text: $preset.instruction).font(Theme.writingFont).themedEditor().frame(height: 130)
                        .accessibilityLabel("Preset instruction")
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save preset") { onSave(preset); dismiss() }.prominent()
                .keyboardShortcut(.defaultAction)
                .disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preset.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
