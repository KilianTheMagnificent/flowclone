import Cocoa
import os

enum FlowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case dictate, handsFree, draft, pasteDraft, copyLast, editSelection, editLast, undoLast, literal, spelling, actions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictate: "Push to talk"; case .handsFree: "Toggle hands-free"
        case .draft: "Dictate into draft"; case .pasteDraft: "Insert draft here"
        case .copyLast: "Copy last dictation"; case .editSelection: "Speak an edit to selection"
        case .editLast: "Edit last dictation"; case .undoLast: "Undo last dictation"
        case .literal: "Dictate literal text"; case .spelling: "Spell text"; case .actions: "Show all actions"
        }
    }
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case transformSelection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transformSelection: "Transform selected text"
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Sendable, Identifiable {
    static let rightCommandKeyCode: UInt16 = 0x36
    static let rightOptionKeyCode: UInt16 = 0x3D
    static let fnKeyCode: UInt16 = 0x3F
    static let standaloneModifierKeyCodes: Set<UInt16> = [
        rightCommandKeyCode, rightOptionKeyCode, fnKeyCode
    ]

    static func isStandaloneModifierKey(_ keyCode: UInt16?) -> Bool {
        guard let keyCode else { return false }
        return standaloneModifierKeyCodes.contains(keyCode)
    }

    var id = UUID()
    let action: FlowAction?
    let shortcutAction: ShortcutAction?
    /// nil means modifier-only; 63 is physical Fn, 0x36 is Right Command, 0x3D is Right Option.
    let keyCode: UInt16?
    let modifiers: UInt64
    let keyLabel: String

    static let modifierMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue

    init(id: UUID = UUID(), action: FlowAction, keyCode: UInt16?, modifiers: UInt64, keyLabel: String) {
        self.id = id
        self.action = action
        self.shortcutAction = nil
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init(id: UUID = UUID(), shortcutAction: ShortcutAction, keyCode: UInt16?, modifiers: UInt64, keyLabel: String) {
        self.id = id
        self.action = nil
        self.shortcutAction = shortcutAction
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, shortcutAction, keyCode, modifiers, keyLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        action = try container.decodeIfPresent(FlowAction.self, forKey: .action)
        shortcutAction = try container.decodeIfPresent(ShortcutAction.self, forKey: .shortcutAction)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt64.self, forKey: .modifiers)
        keyLabel = try container.decode(String.self, forKey: .keyLabel)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(shortcutAction, forKey: .shortcutAction)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(keyLabel, forKey: .keyLabel)
    }

    var title: String {
        var effectiveModifiers = modifiers
        if keyCode == Self.rightCommandKeyCode {
            effectiveModifiers &= ~CGEventFlags.maskCommand.rawValue
        } else if keyCode == Self.rightOptionKeyCode {
            effectiveModifiers &= ~CGEventFlags.maskAlternate.rawValue
        }
        let flags = CGEventFlags(rawValue: effectiveModifiers)
        let namedKey = keyCode.flatMap { code -> String? in
            switch code {
            case Self.fnKeyCode: return "fn"
            case Self.rightCommandKeyCode: return "Right ⌘"
            case Self.rightOptionKeyCode: return "Right ⌥"
            case 49: return "Space"
            case 36: return "Return"
            case 48: return "Tab"
            case 51: return "Delete"
            case 123: return "←"
            case 124: return "→"
            case 125: return "↓"
            case 126: return "↑"
            default: return Self.functionKeyNames[code]
            }
        } ?? Self.printableLabel(keyLabel, keyCode: keyCode)
        return (flags.contains(.maskControl) ? "⌃" : "")
            + (flags.contains(.maskAlternate) ? "⌥" : "")
            + (flags.contains(.maskShift) ? "⇧" : "")
            + (flags.contains(.maskCommand) ? "⌘" : "")
            + namedKey
    }

    /// Keys whose recorded `charactersIgnoringModifiers` is an AppKit private-use character
    /// (NSF1FunctionKey… U+F704 and up), which renders as an empty box in every font.
    /// Virtual key codes from Carbon's Events.h; they are the same on every layout.
    static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        117: "⌦", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
        76: "Enter", 71: "Clear"
    ]

    /// The recorded character, or "Key N" when it would not show: a dead key on a
    /// non-US layout records nothing, and control or private-use characters draw nothing.
    static func printableLabel(_ label: String, keyCode: UInt16?) -> String {
        let visible = !label.isEmpty && label.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xE000...0xF8FF).contains(scalar.value)
        }
        if visible { return label.uppercased() }
        return keyCode.map { "Key \($0)" } ?? label
    }

    func conflicts(with other: Self) -> Bool {
        keyCode == other.keyCode && normalizedModifiers == other.normalizedModifiers
    }

    var normalizedModifiers: UInt64 {
        switch keyCode {
        case Self.rightCommandKeyCode:
            return modifiers & ~CGEventFlags.maskCommand.rawValue
        case Self.rightOptionKeyCode:
            return modifiers & ~CGEventFlags.maskAlternate.rawValue
        default:
            return modifiers
        }
    }

    fileprivate var sameSingleActionSlot: ((ShortcutBinding) -> Bool)? {
        if let action, action != .dictate {
            return { $0.action == action }
        }
        if let shortcutAction {
            return { $0.shortcutAction == shortcutAction }
        }
        return nil
    }

    static let defaults: [Self] = [
        .init(action: .dictate, keyCode: 63, modifiers: 0, keyLabel: "fn"),
        .init(action: .dictate, keyCode: nil,
              modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue, keyLabel: "")
    ]
}

final class ShortcutStore: @unchecked Sendable {
    static let shared = ShortcutStore()
    static let didChange = Notification.Name("FlowCloneShortcutsChanged")
    private struct State { var bindings: [ShortcutBinding]; var recording = false }
    private let state: OSAllocatedUnfairLock<State>
    private let defaults: UserDefaults
    private struct Document: Codable { var version = 1; let bindings: [ShortcutBinding] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "shortcutBindings").flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
        let bindings = saved?.version == 1 && Self.valid(saved!.bindings) ? saved!.bindings : ShortcutBinding.defaults
        state = OSAllocatedUnfairLock(initialState: State(bindings: bindings))
    }

    var bindings: [ShortcutBinding] { state.withLock { $0.bindings } }
    var recording: Bool {
        get { state.withLock { $0.recording } }
        set { state.withLock { $0.recording = newValue } }
    }

    func label(_ action: FlowAction) -> String {
        let labels = bindings.filter { $0.action == action }.map(\.title)
        return labels.isEmpty ? "Not assigned" : labels.joined(separator: " or ")
    }

    func label(_ action: ShortcutAction) -> String {
        let labels = bindings.filter { $0.shortcutAction == action }.map(\.title)
        return labels.isEmpty ? "Not assigned" : labels.joined(separator: " or ")
    }

    func bindings(for action: ShortcutAction) -> [ShortcutBinding] {
        bindings.filter { $0.shortcutAction == action }
    }

    func save(_ binding: ShortcutBinding) throws {
        var values = bindings
        guard (binding.action != nil) != (binding.shortcutAction != nil),
              binding.keyCode != 53,
              ShortcutBinding.isStandaloneModifierKey(binding.keyCode) || binding.normalizedModifiers != 0,
              binding.action == .dictate || binding.keyCode != nil else {
            throw PersonalizationError.invalid("Use a modifier with a key, Fn, Right Command, or Right Option. Escape stays available to cancel.")
        }
        guard !values.contains(where: { $0.id != binding.id && $0.conflicts(with: binding) }) else {
            throw PersonalizationError.invalid("That shortcut is already assigned to another action.")
        }
        if binding.action == .dictate, values.filter({ $0.action == .dictate && $0.id != binding.id }).count >= 2 {
            throw PersonalizationError.invalid("Push to talk supports two alternatives. Remove one before adding another.")
        }
        if let matchesSameSlot = binding.sameSingleActionSlot {
            values.removeAll(where: matchesSameSlot)
        }
        values.removeAll { $0.id == binding.id }
        values.append(binding)
        guard Self.valid(values) else {
            throw PersonalizationError.invalid("That key combination cannot be used as a shortcut.")
        }
        try persist(values)
    }

    func remove(_ id: UUID) throws { try persist(bindings.filter { $0.id != id }) }
    func reset() throws { try persist(ShortcutBinding.defaults) }

    private func persist(_ values: [ShortcutBinding]) throws {
        let data = try JSONEncoder().encode(Document(bindings: values))
        defaults.set(data, forKey: "shortcutBindings")
        state.withLock { $0.bindings = values }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    private static func valid(_ bindings: [ShortcutBinding]) -> Bool {
        let maxCount = FlowAction.allCases.count + ShortcutAction.allCases.count + 1
        guard bindings.count <= maxCount,
              Set(bindings.map(\.id)).count == bindings.count,
              bindings.filter({ $0.action == .dictate }).count <= 2 else { return false }
        for (index, binding) in bindings.enumerated() {
            guard (binding.action != nil) != (binding.shortcutAction != nil),
                  binding.modifiers & ~ShortcutBinding.modifierMask == 0,
                  binding.keyCode != 53, binding.keyLabel.count <= 40,
                  ShortcutBinding.isStandaloneModifierKey(binding.keyCode) || binding.normalizedModifiers != 0,
                  binding.action == .dictate || binding.keyCode != nil,
                  binding.keyCode.map({ $0 < 128 && (!(54...62).contains($0) || ShortcutBinding.isStandaloneModifierKey($0)) }) ?? true,
                  !bindings.prefix(index).contains(where: {
                      $0.conflicts(with: binding) || (binding.sameSingleActionSlot?($0) == true)
                  }) else { return false }
        }
        return true
    }
}

/// Event state owns the binding accepted at key-down, even if Settings changes meanwhile.
struct ShortcutRouter {
    struct Result {
        var held: [(Int, Bool)] = []
        var cancelledSlots: [Int] = []
        var chordContaminated = false
        var actions: [FlowAction] = []
        var shortcutActions: [ShortcutAction] = []
        var consumed = false
    }

    private static let leftCommandDeviceMask: UInt64 = 0x08
    private static let rightCommandDeviceMask: UInt64 = 0x10
    private static let commandDeviceMask: UInt64 = leftCommandDeviceMask | rightCommandDeviceMask
    private static let leftOptionDeviceMask: UInt64 = 0x20
    private static let rightOptionDeviceMask: UInt64 = 0x40
    private static let optionDeviceMask: UInt64 = leftOptionDeviceMask | rightOptionDeviceMask

    private var active: [Int: ShortcutBinding] = [:]
    private var actionKeys: Set<UInt16> = []
    /// Tracks all modifiers and non-trigger keys observed since modifiers were last completely up,
    /// preventing non-dictation chords (`Ctrl+Opt+Shift`, `Ctrl+Opt+Arrow`, `RightCmd+C`) from
    /// registering as clean modifier taps or re-triggering as keys are released.
    private var seenModifiersWhileHeld: UInt64 = 0
    private var sawNonTriggerKeyWhileModifiersHeld = false

    mutating func reset() {
        active = [:]
        actionKeys = []
        seenModifiersWhileHeld = 0
        sawNonTriggerKeyWhileModifiersHeld = false
    }

    private static func standaloneKeyIsDown(_ keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case ShortcutBinding.fnKeyCode:
            return flags.contains(.maskSecondaryFn)
        case ShortcutBinding.rightCommandKeyCode:
            let raw = flags.rawValue
            if (raw & commandDeviceMask) != 0 {
                return (raw & rightCommandDeviceMask) != 0
            }
            return flags.contains(.maskCommand)
        case ShortcutBinding.rightOptionKeyCode:
            let raw = flags.rawValue
            if (raw & optionDeviceMask) != 0 {
                return (raw & rightOptionDeviceMask) != 0
            }
            return flags.contains(.maskAlternate)
        default:
            return false
        }
    }

    private static func allowedChordMask(for binding: ShortcutBinding) -> UInt64 {
        switch binding.keyCode {
        case nil:
            return binding.modifiers
        case ShortcutBinding.fnKeyCode:
            return binding.normalizedModifiers | CGEventFlags.maskSecondaryFn.rawValue
        case ShortcutBinding.rightCommandKeyCode:
            return binding.normalizedModifiers | CGEventFlags.maskCommand.rawValue
        case ShortcutBinding.rightOptionKeyCode:
            return binding.normalizedModifiers | CGEventFlags.maskAlternate.rawValue
        default:
            return binding.modifiers
        }
    }

    private static func isChordOrStandaloneModifier(_ binding: ShortcutBinding) -> Bool {
        binding.keyCode == nil || ShortcutBinding.isStandaloneModifierKey(binding.keyCode)
    }

    mutating func event(type: CGEventType, key: UInt16, flags: CGEventFlags,
                        repeated: Bool, bindings: [ShortcutBinding]) -> Result {
        var result = Result()
        let modifiers = flags.rawValue & ShortcutBinding.modifierMask
        let fnFlag: UInt64 = flags.contains(.maskSecondaryFn) ? CGEventFlags.maskSecondaryFn.rawValue : 0
        let currentAllModifiers = modifiers | fnFlag

        if type == .flagsChanged {
            seenModifiersWhileHeld |= currentAllModifiers
        }
        defer {
            if type == .flagsChanged, currentAllModifiers == 0 {
                seenModifiersWhileHeld = 0
                sawNonTriggerKeyWhileModifiersHeld = false
            }
        }

        func isDown(_ binding: ShortcutBinding) -> Bool {
            if let code = binding.keyCode, ShortcutBinding.isStandaloneModifierKey(code) {
                return Self.standaloneKeyIsDown(code, flags: flags)
                    && (modifiers & ~Self.inherentModifierMask(for: code)) == binding.normalizedModifiers
            }
            if binding.keyCode == nil { return modifiers == binding.modifiers && fnFlag == 0 }
            return type != .keyUp
        }

        // First settle active holds on flagsChanged / keyUp (and contaminate modifier-only /
        // standalone-modifier holds if an extra modifier was added).
        for (slot, binding) in active.sorted(by: { $0.key < $1.key }) {
            if Self.isChordOrStandaloneModifier(binding) {
                if type == .flagsChanged {
                    let allowed = Self.allowedChordMask(for: binding)
                    let extraModifierAdded = (seenModifiersWhileHeld & ~allowed) != 0
                    if extraModifierAdded || sawNonTriggerKeyWhileModifiersHeld {
                        active.removeValue(forKey: slot)
                        result.cancelledSlots.append(slot)
                        result.chordContaminated = true
                    } else if let code = binding.keyCode {
                        if key == code && !Self.standaloneKeyIsDown(code, flags: flags) {
                            active.removeValue(forKey: slot)
                            result.held.append((slot, false))
                            if code == ShortcutBinding.fnKeyCode { result.consumed = true }
                        }
                    } else if !isDown(binding) {
                        active.removeValue(forKey: slot)
                        result.held.append((slot, false))
                    }
                }
            } else if type == .keyUp, key == binding.keyCode {
                active.removeValue(forKey: slot)
                result.held.append((slot, false))
                result.consumed = true
            }
        }

        if type == .keyUp, actionKeys.remove(key) != nil { result.consumed = true }
        if type == .flagsChanged, ShortcutBinding.isStandaloneModifierKey(key),
           !Self.standaloneKeyIsDown(key, flags: flags), actionKeys.remove(key) != nil {
            if key == ShortcutBinding.fnKeyCode { result.consumed = true }
        }

        if repeated {
            result.consumed = result.consumed
                || actionKeys.contains(key)
                || active.values.contains { $0.keyCode == key }
            return result
        }

        var matchedAnyBinding = false
        for binding in bindings {
            let matches: Bool
            if let code = binding.keyCode, ShortcutBinding.isStandaloneModifierKey(code) {
                let allowed = Self.allowedChordMask(for: binding)
                let uncontaminated = (seenModifiersWhileHeld & ~allowed) == 0
                    && !sawNonTriggerKeyWhileModifiersHeld
                matches = type == .flagsChanged && key == code && isDown(binding) && uncontaminated
            } else if let code = binding.keyCode {
                matches = type == .keyDown && key == code && modifiers == binding.modifiers
            } else {
                let allowed = Self.allowedChordMask(for: binding)
                let uncontaminated = (seenModifiersWhileHeld & ~allowed) == 0
                    && !sawNonTriggerKeyWhileModifiersHeld
                matches = type == .flagsChanged && isDown(binding) && uncontaminated
            }
            guard matches else { continue }
            matchedAnyBinding = true
            if binding.action == .dictate {
                if !active.values.contains(where: { $0.id == binding.id }),
                   let slot = (0..<2).first(where: { active[$0] == nil }) {
                    active[slot] = binding
                    result.held.append((slot, true))
                }
                if binding.keyCode == ShortcutBinding.fnKeyCode || (binding.keyCode != nil && !ShortcutBinding.isStandaloneModifierKey(binding.keyCode)) {
                    result.consumed = true
                }
            } else if type == .keyDown || (type == .flagsChanged && ShortcutBinding.isStandaloneModifierKey(key)) {
                if let code = binding.keyCode, actionKeys.insert(code).inserted {
                    if let action = binding.action { result.actions.append(action) }
                    if let shortcutAction = binding.shortcutAction { result.shortcutActions.append(shortcutAction) }
                }
                if binding.keyCode == ShortcutBinding.fnKeyCode || !ShortcutBinding.isStandaloneModifierKey(binding.keyCode) {
                    result.consumed = true
                }
            }
        }

        if type == .keyDown, !matchedAnyBinding {
            // Any non-trigger key pressed while modifiers are down contaminates modifier-only
            // and standalone-modifier chords so e.g. Ctrl+Opt+Arrow or RightCmd+C cancels
            // immediately and never arms double-tap hands-free.
            if currentAllModifiers != 0 || !active.isEmpty {
                sawNonTriggerKeyWhileModifiersHeld = true
            }
            for (slot, binding) in active.sorted(by: { $0.key < $1.key })
                where Self.isChordOrStandaloneModifier(binding) {
                active.removeValue(forKey: slot)
                result.cancelledSlots.append(slot)
                result.chordContaminated = true
            }
        } else if type == .flagsChanged, !matchedAnyBinding, currentAllModifiers != 0 {
            let couldProgressTowardDictateChord = bindings.contains { binding in
                guard binding.action == .dictate, Self.isChordOrStandaloneModifier(binding) else { return false }
                let allowed = Self.allowedChordMask(for: binding)
                return (seenModifiersWhileHeld & ~allowed) == 0 && !sawNonTriggerKeyWhileModifiersHeld
            }
            if !couldProgressTowardDictateChord {
                result.chordContaminated = true
            }
        }

        return result
    }

    private static func inherentModifierMask(for keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case ShortcutBinding.rightCommandKeyCode:
            return CGEventFlags.maskCommand.rawValue
        case ShortcutBinding.rightOptionKeyCode:
            return CGEventFlags.maskAlternate.rawValue
        default:
            return 0
        }
    }
}
