import Cocoa
import Darwin
import Foundation
import os

enum AXTextContext {
    static let electronAccessibilityKey = "electronAccessibilityEnabled"

    struct Limits: Sendable {
        let before: Int
        let selected: Int
        let after: Int
        let visible: Int
        let continuation: Int
        let budget: TimeInterval
        let callTimeout: Float

        static let `default` = Limits(
            before: 384,
            selected: 256,
            after: 384,
            visible: 1_024,
            continuation: 200,
            budget: 0.100,
            callTimeout: 0.050
        )
    }

    struct CaptureRanges: Sendable {
        let before: CFRange
        let selected: CFRange
        let after: CFRange?
        let visible: CFRange?
    }

    private struct FocusedAccess {
        let element: AXUIElement
        let selection: CFRange
    }

    /// Bounded, non-bridging editor slices for identifier vocabulary extraction.
    struct VocabularyFragments: Equatable {
        let before: String
        let selected: String
        let after: String
        let visible: String
    }

    static let codingBundleIDs: Set<String> = [
        // IDEs & Code Editors
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.visualstudio.code.oss",
        "com.panic.Nova",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.cursor.Cursor",
        "com.exafunction.windsurf",
        "com.google.antigravity",
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        "dev.zed.Zed-Nightly",
        "com.sublimetext.4",
        "com.barebones.bbedit",
        "com.coteditor.CotEditor",
        "fleet.app",
        // Terminals
        "com.superlogical.rex",
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.cmux.app",
        "dev.cmux.app",
        "com.manaflow.cmux",
        // AI Coding & Agent Desktop Apps
        "com.anthropic.claudedesktop",
        "com.openai.chat",
        "com.openai.codex",
        "com.openai.codexdesktop",
        "com.interface.app",
        "ai.interface.app",
        "com.t3.code",
        "gg.t3.code",
        "chat.t3.code",
    ]

    private static let codingBundlePrefixes: [String] = [
        "com.jetbrains.",
        "com.google.android.studio",
        "com.todesktop.",
        "dev.zed.",
        "dev.warp.",
        "com.cursor.",
        "com.openai.codex",
        "com.superlogical.rex",
        "com.cmux.",
        "dev.cmux.",
        "com.manaflow.cmux",
        "com.interface.",
        "ai.interface.",
        "com.t3.",
        "gg.t3.",
        "chat.t3.",
    ]

    private static let codingBundleTokens: Set<String> = [
        "vscode", "vscodium", "cursor", "windsurf", "zed", "xcode",
        "rex", "ghostty", "iterm2", "wezterm", "alacritty", "kitty", "cmux", "nodeterm",
        "claudedesktop", "codex", "codexdesktop", "interface", "t3code",
        "antigravity", "neovide"
    ]

    private static let terminalGridBundleIDs: Set<String> = [
        "com.superlogical.rex",
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.cmux.app",
        "dev.cmux.app",
        "com.manaflow.cmux",
    ]

    private static let terminalGridBundleIDsLower: Set<String> = Set(
        terminalGridBundleIDs.map { $0.lowercased() }
    )

    private static let terminalGridBundlePrefixesLower: [String] = [
        "com.superlogical.rex",
        "dev.warp.",
        "com.cmux.",
        "dev.cmux.",
    ]

    /// Returns `true` for PTY / GPU terminal grid apps (including Rex's `libghostty` surface)
    /// whose AX text attributes read the 2D screen grid rather than the PTY input stream.
    static func usesTerminalGridAX(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if terminalGridBundleIDs.contains(trimmed) { return true }
        let lower = trimmed.lowercased()
        if terminalGridBundleIDsLower.contains(lower) { return true }
        return terminalGridBundlePrefixesLower.contains { lower.hasPrefix($0) }
    }

    private static let electronCodingOrChatBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",
        "com.cursor.Cursor",
        "com.exafunction.windsurf",
        "com.google.antigravity",
        "com.anthropic.claudedesktop",
        "com.openai.chat",
        "com.openai.codex",
        "com.openai.codexdesktop",
        "com.interface.app",
        "ai.interface.app",
        "com.t3.code",
        "gg.t3.code",
        "chat.t3.code",
        "com.cmux.app",
        "dev.cmux.app",
        "com.manaflow.cmux",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.linear",
        "md.obsidian",
    ]

    private static let electronCodingOrChatTokens: Set<String> = [
        "vscode", "vscodium", "cursor", "windsurf", "claudedesktop",
        "codex", "codexdesktop", "interface", "t3code", "antigravity"
    ]

    private enum ElectronPIDState: Sendable {
        case succeeded
        case nonElectron
        case retryAfter(Date)
    }

    static let electronRetryBackoff: TimeInterval = 5.0
    private static let inspectedElectronPIDs = OSAllocatedUnfairLock<[pid_t: ElectronPIDState]>(initialState: [:])

    static func isElectronAccessibilityEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: electronAccessibilityKey) as? Bool ?? true
    }

    static func isElectronCodingOrChatApp(_ bundleID: String, bundleURL: URL? = nil) -> Bool {
        if electronCodingOrChatBundleIDs.contains(bundleID) { return true }
        let lower = bundleID.lowercased()
        if lower.hasPrefix("com.todesktop.")
            || lower.hasPrefix("com.cursor.")
            || lower.hasPrefix("com.openai.codex")
            || lower.hasPrefix("com.interface.")
            || lower.hasPrefix("ai.interface.")
            || lower.hasPrefix("com.t3.")
            || lower.hasPrefix("gg.t3.")
            || lower.hasPrefix("chat.t3.") {
            return true
        }
        let parts = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if parts.contains(where: electronCodingOrChatTokens.contains) {
            return true
        }
        if let bundleURL {
            let electronFramework = bundleURL
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            if FileManager.default.fileExists(atPath: electronFramework.path) {
                return true
            }
        }
        return false
    }

    /// Sets `AXManualAccessibility = true` on running Electron PIDs so Electron constructs its
    /// accessibility tree for cursor context, selection transforms, and paste verification without
    /// repeated IPC once succeeded. If the IPC fails or times out, retries after a short backoff
    /// instead of permanently giving up for the rest of the process lifetime.
    @discardableResult
    static func enableElectronAccessibilityIfNeeded(
        pid: pid_t,
        bundleID: String,
        defaults: UserDefaults = .standard,
        bundleURLProvider: ((pid_t) -> URL?)? = nil,
        isProcessAlive: ((pid_t) -> Bool)? = nil,
        now: () -> Date = Date.init,
        retryBackoff: TimeInterval = electronRetryBackoff,
        axSetter: ((pid_t) -> AXError)? = nil,
        setter: ((pid_t) -> Void)? = nil
    ) -> Bool {
        guard pid > 0, isElectronAccessibilityEnabled(defaults) else { return false }
        let hasCustomSetter = setter != nil || axSetter != nil
        if !hasCustomSetter && handsfreeSession { return false }
        let currentTime = now()
        let aliveCheck = isProcessAlive ?? { candidate in
            kill(candidate, 0) == 0 || errno == EPERM
        }
        let cached = inspectedElectronPIDs.withLock { seen -> (state: ElectronPIDState?, overflow: [pid_t]) in
            (seen[pid], seen.count > 128 ? Array(seen.keys) : [])
        }
        if !cached.overflow.isEmpty {
            let dead = cached.overflow.filter { !aliveCheck($0) }
            if !dead.isEmpty {
                inspectedElectronPIDs.withLock { seen in
                    for deadPID in dead { seen.removeValue(forKey: deadPID) }
                }
            }
        }
        if let cachedState = cached.state {
            let stillAlive = isProcessAlive?(pid) ?? (hasCustomSetter || aliveCheck(pid))
            if stillAlive {
                switch cachedState {
                case .succeeded, .nonElectron:
                    return false
                case .retryAfter(let retryDate):
                    if currentTime < retryDate {
                        return false
                    }
                }
            } else {
                _ = inspectedElectronPIDs.withLock { $0.removeValue(forKey: pid) }
            }
        }

        let resolvedURL = bundleURLProvider?(pid)
            ?? (!hasCustomSetter ? NSRunningApplication(processIdentifier: pid)?.bundleURL : nil)
        let eligible = isElectronCodingOrChatApp(bundleID, bundleURL: resolvedURL)
        guard eligible else {
            inspectedElectronPIDs.withLock { $0[pid] = .nonElectron }
            return false
        }

        let claimed = inspectedElectronPIDs.withLock { seen -> Bool in
            if let existing = seen[pid] {
                switch existing {
                case .succeeded, .nonElectron:
                    return false
                case .retryAfter(let retryDate):
                    if currentTime < retryDate { return false }
                }
            }
            seen[pid] = .retryAfter(currentTime.addingTimeInterval(retryBackoff))
            return true
        }
        guard claimed else { return false }

        let axError: AXError
        if let axSetter {
            axError = axSetter(pid)
        } else if let setter {
            setter(pid)
            axError = .success
        } else {
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(app, 0.050)
            axError = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        if axError == .success {
            inspectedElectronPIDs.withLock { $0[pid] = .succeeded }
            return true
        } else {
            let nextTry = now().addingTimeInterval(retryBackoff)
            inspectedElectronPIDs.withLock { seen in
                if case .succeeded = seen[pid] { return }
                seen[pid] = .retryAfter(nextTry)
            }
            return false
        }
    }

    static func resetElectronAccessibilityCacheForTesting() {
        inspectedElectronPIDs.withLock { $0.removeAll() }
    }

    /// A bounded, best-effort AX snapshot. Continuation is mechanical and always attempted;
    /// the broader IDE vocabulary scan remains an explicit opt-in. Only the bounded suffix
    /// and extracted terms escape this function; editor text, paths, and titles do not.
    static func capture(pid: pid_t, bundleID: String,
                        limits: Limits = .default,
                        deadline sharedDeadline: AXClient.Deadline? = nil) -> DictationContext {
        guard pid > 0, !usesTerminalGridAX(bundleID), frontmostPID() == pid else { return .empty }
        enableElectronAccessibilityIfNeeded(pid: pid, bundleID: bundleID)
        let deadline = sharedDeadline ?? AXClient.Deadline(total: limits.budget,
                                                           perCall: limits.callTimeout)
        guard let access = focusedAccess(pid: pid, deadline: deadline) else { return .empty }
        return capture(access: access, pid: pid, bundleID: bundleID,
                       limits: limits, deadline: deadline)
    }

    /// Identity-bound variant for PasteTarget. It reads the element captured by the target
    /// lease instead of asking the app which field is focused mid-capture.
    static func capture(element: AXUIElement, pid: pid_t, bundleID: String,
                        limits: Limits = .default,
                        deadline sharedDeadline: AXClient.Deadline? = nil) -> DictationContext {
        guard pid > 0, !usesTerminalGridAX(bundleID), frontmostPID() == pid else { return .empty }
        enableElectronAccessibilityIfNeeded(pid: pid, bundleID: bundleID)
        let deadline = sharedDeadline ?? AXClient.Deadline(total: limits.budget,
                                                           perCall: limits.callTimeout)
        guard let access = elementAccess(element, pid: pid, deadline: deadline) else {
            return .empty
        }
        return capture(access: access, pid: pid, bundleID: bundleID,
                       limits: limits, deadline: deadline)
    }

    private static func capture(access: FocusedAccess, pid: pid_t, bundleID: String,
                                limits: Limits,
                                deadline: AXClient.Deadline) -> DictationContext {
        guard !usesTerminalGridAX(bundleID) else { return .empty }
        let vocabularyEnabled = UserDefaults.standard.bool(forKey: "localCodingContext")
            && isCodingApp(bundleID)

        // Read the before-cursor range first: it is both the smallest privacy surface and the
        // latency-critical continuation input. Vocabulary work is strictly lower priority.
        let beforeRange = rangeBeforeCaret(
            access.selection,
            limit: vocabularyEnabled ? limits.before : limits.continuation
        )
        let beforeRead = slice(access.element, beforeRange, deadline: deadline)
        // Empty is known document start; nil is an unreadable field. Keep that distinction.
        let prefix = beforeRead.map { String($0.suffix(limits.continuation)) }
        let total = AXClient.numberAttribute(access.element,
                                             kAXNumberOfCharactersAttribute as CFString,
                                             deadline: deadline)
        let selectedRead = slice(
            access.element,
            CFRange(location: access.selection.location,
                    length: min(access.selection.length, limits.selected)),
            deadline: deadline)
        let selected = access.selection.length <= limits.selected ? selectedRead : nil

        guard vocabularyEnabled else {
            let afterRange = insertionRangeAfter(selection: access.selection, total: total, limit: 128)
            let suffix = afterRange.flatMap { slice(access.element, $0, deadline: deadline) }
            guard frontmostPID() == pid else { return .empty }
            return DictationContext(continuationPrefix: prefix, terms: [], continuationSuffix: suffix,
                                    continuationSelection: selected)
        }

        let visibleRange = AXClient.rangeAttribute(
            access.element, kAXVisibleCharacterRangeAttribute as CFString,
            deadline: deadline)
        let ranges = captureRanges(selection: access.selection, total: total,
                                   visible: visibleRange, limits: limits)
        let afterRead: String?
        let suffix: String?
        if let vocabAfterRange = ranges.after {
            afterRead = slice(access.element, vocabAfterRange, deadline: deadline)
            suffix = afterRead.map { String($0.prefix(128)) }
        } else {
            afterRead = nil
            suffix = insertionRangeAfter(selection: access.selection, total: total, limit: 128)
                .flatMap { slice(access.element, $0, deadline: deadline) }
        }
        let visibleRead = ranges.visible.flatMap {
            slice(access.element, $0, deadline: deadline)
        }
        let filenames = activeFilenames(from: access.element, deadline: deadline)
        let fragments = vocabularyFragments(
            ranges: ranges,
            fullSelectionLength: fullSelectionLength(access.selection, total: total),
            before: beforeRead,
            selected: selectedRead,
            after: afterRead,
            visible: visibleRead
        )

        guard frontmostPID() == pid else { return .empty }
        return DictationContext(
            continuationPrefix: prefix,
            terms: ContextVocabulary.extract(before: fragments.before,
                                             selected: fragments.selected,
                                             after: fragments.after,
                                             visible: fragments.visible,
                                             filenames: filenames),
            continuationSuffix: suffix, continuationSelection: selected
        )
    }

    static func isCodingApp(_ bundleID: String) -> Bool {
        if codingBundleIDs.contains(bundleID) { return true }
        if codingBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        let lower = bundleID.lowercased()
        if codingBundlePrefixes.contains(where: { lower.hasPrefix($0.lowercased()) }) { return true }
        let compact = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
        if compact.contains("t3code") || compact.contains("claudedesktop") { return true }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains(where: codingBundleTokens.contains)
    }

    static func isSecure(role: String?, subrole: String?) -> Bool {
        AXClient.classify(
            role: role.map(AXClient.Metadata.value) ?? .failed,
            subrole: subrole.map(AXClient.Metadata.value) ?? .absent,
            protectedContent: .absent) != .ordinary
    }

    static func securityAllowsText(role: AXClient.Metadata<String>,
                                   subrole: AXClient.Metadata<String>,
                                   protectedContent: AXClient.Metadata<Bool>) -> Bool {
        AXClient.classify(role: role, subrole: subrole,
                          protectedContent: protectedContent) == .ordinary
    }

    private static func focusedAccess(pid: pid_t,
                                      deadline: AXClient.Deadline) -> FocusedAccess? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = AXClient.elementAttribute(
            app, kAXFocusedUIElementAttribute as CFString, deadline: deadline
        ) else { return nil }
        return elementAccess(focused, pid: pid, deadline: deadline)
    }

    private static func elementAccess(_ focused: AXUIElement, pid: pid_t,
                                      deadline: AXClient.Deadline) -> FocusedAccess? {
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success,
              deadline.hasTimeRemaining, focusedPID == pid else {
            return nil
        }
        let role: AXClient.Metadata<String> = AXClient.attribute(
            focused, kAXRoleAttribute as CFString, required: false, deadline: deadline)
        let subrole: AXClient.Metadata<String> = AXClient.attribute(
            focused, kAXSubroleAttribute as CFString, required: false, deadline: deadline)
        let protectedContent = AXClient.boolAttribute(
            focused, NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            required: false, deadline: deadline)
        guard securityAllowsText(role: role, subrole: subrole,
                                 protectedContent: protectedContent),
              let selection = AXClient.rangeAttribute(
                focused, kAXSelectedTextRangeAttribute as CFString, deadline: deadline
              ), selection.location >= 0, selection.length >= 0,
              selection.location <= Int.max - selection.length else { return nil }
        return FocusedAccess(element: focused, selection: selection)
    }

    static func rangeBeforeCaret(_ selection: CFRange, limit: Int) -> CFRange {
        let location = max(0, selection.location)
        let length = min(max(0, limit), location)
        return CFRange(location: location - length, length: length)
    }

    /// Text after a replacement starts at the end of the selection, not at its beginning.
    /// A known empty range means document end; an unknown count must remain unknown.
    static func insertionRangeAfter(selection: CFRange, total: Int?, limit: Int) -> CFRange? {
        guard let total, total >= 0, selection.location >= 0, selection.length >= 0,
              selection.location <= total, selection.length <= total - selection.location else { return nil }
        let end = selection.location + selection.length
        return CFRange(location: end, length: min(max(0, limit), total - end))
    }

    private static func fullSelectionLength(_ selection: CFRange, total: Int?) -> Int {
        let knownTotal = max(0, total ?? max(0, selection.location) + max(0, selection.length))
        let location = min(max(0, selection.location), knownTotal)
        return min(max(0, selection.length), max(0, knownTotal - location))
    }

    /// Accepts bounded slices at any document offset (not just offset 0) while refusing
    /// partial/failed reads or bridging across a truncated selection.
    static func vocabularyFragments(
        ranges: CaptureRanges,
        fullSelectionLength: Int,
        before: String?,
        selected: String?,
        after: String?,
        visible: String?
    ) -> VocabularyFragments {
        func complete(_ value: String?, for range: CFRange?) -> String? {
            guard let range else { return "" }
            guard let value, value.utf16.count == range.length else { return nil }
            return value
        }

        let safeVisible: String
        if let visibleRange = ranges.visible,
           let value = complete(visible, for: visibleRange) {
            safeVisible = value
        } else {
            safeVisible = ""
        }

        guard let safeBefore = complete(before, for: ranges.before) else {
            return VocabularyFragments(before: "", selected: "", after: "",
                                       visible: safeVisible)
        }

        guard let safeSelected = complete(selected, for: ranges.selected) else {
            return VocabularyFragments(before: safeBefore, selected: "", after: "",
                                       visible: safeVisible)
        }

        var safeAfter = ""
        if ranges.selected.length == fullSelectionLength,
           let afterRange = ranges.after,
           let value = complete(after, for: afterRange) {
            safeAfter = value
        }
        return VocabularyFragments(before: safeBefore, selected: safeSelected,
                                   after: safeAfter, visible: safeVisible)
    }

    static func captureRanges(selection: CFRange, total: Int?, visible: CFRange?,
                              limits: Limits = .default) -> CaptureRanges {
        let knownTotal = max(0, total ?? max(0, selection.location) + max(0, selection.length))
        let location = min(max(0, selection.location), knownTotal)
        let selectedLength = min(max(0, selection.length), max(0, knownTotal - location))

        let beforeLength = min(limits.before, location)
        let before = CFRange(location: location - beforeLength, length: beforeLength)
        let selected = CFRange(location: location, length: min(limits.selected, selectedLength))

        let afterStart = min(knownTotal, location + selectedLength)
        let afterLength = min(limits.after, max(0, knownTotal - afterStart))
        let after = total == nil || afterLength == 0
            ? nil
            : CFRange(location: afterStart, length: afterLength)

        var boundedVisible: CFRange?
        if let visible {
            let visibleStart = min(max(0, visible.location), knownTotal)
            let visibleLength = min(max(0, visible.length), max(0, knownTotal - visibleStart))
            if visibleLength > 0 {
                let wanted = min(limits.visible, visibleLength)
                let visibleEnd = visibleStart + visibleLength
                let preferred = min(max(visibleStart, location - wanted / 2), visibleEnd - wanted)
                boundedVisible = CFRange(location: preferred, length: wanted)
            }
        }

        return CaptureRanges(before: before, selected: selected, after: after, visible: boundedVisible)
    }

    private static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func activeFilenames(from focused: AXUIElement,
                                        deadline: AXClient.Deadline) -> [String] {
        guard let window = AXClient.elementAttribute(
            focused, kAXWindowAttribute as CFString, deadline: deadline
        ) else {
            return []
        }
        var names: [String] = []

        let document: AXClient.Metadata<String> = AXClient.attribute(
            window, kAXDocumentAttribute as CFString, required: false, deadline: deadline)
        if case .value(let raw) = document,
           let name = basename(raw) { names.append(name) }
        let filename: AXClient.Metadata<String> = AXClient.attribute(
            window, kAXFilenameAttribute as CFString, required: false, deadline: deadline)
        if case .value(let raw) = filename,
           let name = basename(raw), !names.contains(name) { names.append(name) }
        let title: AXClient.Metadata<String> = AXClient.attribute(
            window, kAXTitleAttribute as CFString, required: false, deadline: deadline)
        if case .value(let title) = title {
            for token in filenameTokens(String(title.prefix(256))) where !names.contains(token) {
                names.append(token)
                if names.count == 8 { break }
            }
        }
        return names
    }

    private static func basename(_ raw: String) -> String? {
        if let url = URL(string: raw), url.isFileURL {
            let name = url.lastPathComponent
            return name.isEmpty ? nil : String(name.suffix(128))
        }
        let name = URL(fileURLWithPath: raw).lastPathComponent
        return name.isEmpty ? nil : String(name.suffix(128))
    }

    private static func filenameTokens(_ title: String) -> [String] {
        let pattern = "[\\p{L}\\p{N}_-]{1,80}\\.[A-Za-z0-9]{1,12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: title, range: NSRange(title.startIndex..., in: title)).compactMap {
            Range($0.range, in: title).map { String(title[$0]) }
        }
    }

    /// Always attempts parameterized `kAXStringForRangeParameterizedAttribute` first (even
    /// when `requested.location == 0`) before falling back to bounded `kAXValueAttribute`,
    /// preventing full-file IPC reads on large source files.
    static func slice(_ element: AXUIElement, _ requested: CFRange,
                      deadline: AXClient.Deadline) -> String? {
        AXClient.textRange(element, range: requested, deadline: deadline)
    }

    static func slice(_ requested: CFRange,
                      readRange: (CFRange) -> String?,
                      readCount: () -> Int?,
                      readValue: () -> String?) -> String? {
        AXClient.readTextRange(requested, readRange: readRange,
                               readCount: readCount, readValue: readValue)
    }
}
