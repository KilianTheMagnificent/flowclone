import Darwin
import Foundation
import NaturalLanguage

/// Fast metadata stamp (`stat(2)` without reading file bytes or hashing) used to key
/// personalization, vocabulary-set, and app-profile caches off disk state.
struct FileStamp: Equatable, Hashable, Sendable {
    let exists: Bool
    let dev: dev_t
    let ino: ino_t
    let size: off_t
    let mtimeSec: Int
    let mtimeNsec: Int

    static let missing = FileStamp(exists: false, dev: 0, ino: 0, size: 0, mtimeSec: 0, mtimeNsec: 0)

    static func capture(_ url: URL) -> FileStamp {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return stat(path, &st) == 0
        }
        guard ok else { return .missing }
        return FileStamp(
            exists: true,
            dev: st.st_dev,
            ino: st.st_ino,
            size: st.st_size,
            mtimeSec: st.st_mtimespec.tv_sec,
            mtimeNsec: st.st_mtimespec.tv_nsec
        )
    }
}

/// Per-app dictation mode override. `.global` defers to the global `Mode.current`.
enum AppDictationMode: String, CaseIterable, Codable, Sendable {
    case global
    case clean
    case prompt
    case literal

    var label: String {
        switch self {
        case .global: return "Default"
        case .clean: return "Clean"
        case .prompt: return "Prompt"
        case .literal: return "Literal"
        }
    }

    func effectiveMode(default defaultMode: Mode) -> Mode {
        switch self {
        case .global: return defaultMode
        case .clean: return .clean
        case .prompt: return .prompt
        case .literal: return .raw
        }
    }
}

/// User-configured per-application dictation preferences persisted in `app-profiles.json`.
struct AppProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var bundleID: String
    var preferredMode: AppDictationMode = .global
    var stripSingleSentencePeriod: Bool = false
    /// `nil` uses the automatic app-category default (enabled in coding/agent apps, prose-safe elsewhere).
    var slashCommandsEnabled: Bool? = nil
    /// `nil` uses the automatic app-category default (enabled in coding/agent apps, off elsewhere).
    var codeFormattingEnabled: Bool? = nil
    var enabled: Bool = true
}

/// Effective per-utterance app behavior after combining any saved `AppProfile` with
/// built-in coding/agent/chat defaults for `bundleID`.
struct ResolvedAppProfile: Equatable, Sendable {
    let bundleID: String?
    let preferredMode: AppDictationMode
    let stripSingleSentencePeriod: Bool
    let slashCommandsEnabled: Bool
    let hasExplicitSlashCommandPreference: Bool
    let codeFormattingEnabled: Bool

    static let unnamedDefault = ResolvedAppProfile(
        bundleID: nil,
        preferredMode: .global,
        stripSingleSentencePeriod: false,
        slashCommandsEnabled: true,
        hasExplicitSlashCommandPreference: false,
        codeFormattingEnabled: false
    )

    func effectiveMode(default defaultMode: Mode) -> Mode {
        preferredMode.effectiveMode(default: defaultMode)
    }

    func formatOutput(_ text: String, raw: String? = nil, before: String? = nil) -> String {
        guard stripSingleSentencePeriod else { return text }
        let explicitPeriod = raw?.range(
            of: #"\binsert\s+(?:period|full\s+stop)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        return AppProfiles.stripSingleSentencePeriod(
            text,
            before: before,
            preserveExplicitPeriod: explicitPeriod
        )
    }
}

final class AppProfiles: @unchecked Sendable {
    static let shared = AppProfiles(root: PersonalizationStore.shared.root)
    static let didChange = Notification.Name("FlowCloneAppProfilesChanged")

    struct Document: Codable, Equatable, Sendable {
        var version = 1
        var profiles: [AppProfile] = []
    }

    let root: URL
    private let lock = NSRecursiveLock()
    private var cachedStamp: FileStamp?
    private var cachedDocument: Document?

    init(root: URL) {
        self.root = root
    }

    var url: URL { root.appendingPathComponent("app-profiles.json") }

    func document() throws -> Document {
        lock.lock()
        defer { lock.unlock() }
        let stamp = FileStamp.capture(url)
        if let cachedDocument, cachedStamp == stamp {
            return cachedDocument
        }
        guard stamp.exists else {
            let empty = Document()
            cachedStamp = stamp
            cachedDocument = empty
            return empty
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw PersonalizationError.tooLarge }
        let decoded = try JSONDecoder().decode(Document.self, from: data)
        guard decoded.version == 1, decoded.profiles.count <= 200,
              Set(decoded.profiles.map(\.id)).count == decoded.profiles.count else {
            throw PersonalizationError.invalid("This app-profile file cannot be read.")
        }
        cachedStamp = stamp
        cachedDocument = decoded
        return decoded
    }

    func update(_ body: (inout Document) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var doc = try document()
        try body(&doc)
        guard doc.profiles.count <= 200 else { throw PersonalizationError.tooMany }
        var seenBundles = Set<String>()
        for index in doc.profiles.indices {
            let trimmed = doc.profiles[index].bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else {
                throw PersonalizationError.invalid("Choose an application or enter a valid bundle ID.")
            }
            let normalized = trimmed.lowercased()
            guard seenBundles.insert(normalized).inserted else {
                throw PersonalizationError.conflict
            }
            doc.profiles[index].bundleID = trimmed
        }
        let encoded = try JSONEncoder().encode(doc)
        try PrivateFile.write(encoded, to: url)
        cachedStamp = FileStamp.capture(url)
        cachedDocument = doc
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    func profile(for bundleID: String?) -> AppProfile? {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let doc = (try? document()) ?? Document()
        return doc.profiles.first {
            $0.enabled && $0.bundleID.caseInsensitiveCompare(raw) == .orderedSame
        }
    }

    func resolve(bundleID: String?) -> ResolvedAppProfile {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unnamedDefault
        }
        let codingOrAgent = Self.isCodingOrAgentApp(raw)
        if let configured = profile(for: raw) {
            return ResolvedAppProfile(
                bundleID: raw,
                preferredMode: configured.preferredMode,
                stripSingleSentencePeriod: configured.stripSingleSentencePeriod,
                slashCommandsEnabled: configured.slashCommandsEnabled ?? codingOrAgent,
                hasExplicitSlashCommandPreference: configured.slashCommandsEnabled != nil,
                codeFormattingEnabled: configured.codeFormattingEnabled ?? codingOrAgent
            )
        }
        return ResolvedAppProfile(
            bundleID: raw,
            preferredMode: .global,
            stripSingleSentencePeriod: false,
            slashCommandsEnabled: codingOrAgent,
            hasExplicitSlashCommandPreference: false,
            codeFormattingEnabled: codingOrAgent
        )
    }

    // MARK: - App Classification

    private static let codingBundleIDs: Set<String> = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.vscodium",
        "com.panic.nova",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.codeium.windsurf",
        "dev.zed.zed",
        "dev.zed.zed-preview",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.barebones.bbedit",
        "com.macromates.textmate",
        "com.qvacua.vimr",
        "org.gnu.emacs",
        "com.neovide.neovide",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.superlogical.rex",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "dev.warp.warp-preview",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.cmux.app",
        "dev.cmux.app",
        "com.manaflow.cmux",
        "com.nodeterm.app",
    ]

    private static let agentBundleIDs: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.anthropic.claudedesktop",
        "com.openai.codex",
        "com.openai.codexdesktop",
        "com.openai.chat",
        "com.google.antigravity",
        "com.google.geminimacos",
        "com.superlogical.rex",
    ]

    private static let chatBundleIDs: Set<String> = [
        "com.apple.mobilesms",
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.hnc.discordptb",
        "com.hnc.discordcanary",
        "ru.keepcoder.telegram",
        "org.whispersystems.signal-desktop",
        "net.whatsapp.whatsapp",
        "com.microsoft.teams2",
    ]

    static func isCodingApp(_ bundleID: String?) -> Bool {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        if codingBundleIDs.contains(raw)
            || raw.hasPrefix("com.jetbrains.")
            || raw.hasPrefix("com.google.android.studio")
            || raw.hasPrefix("com.superlogical.rex")
            || raw.hasPrefix("dev.warp.")
            || raw.hasPrefix("com.cmux.")
            || raw.hasPrefix("dev.cmux.") {
            return true
        }
        let tokens = [".xcode", ".vscode", ".cursor", ".windsurf", ".rex", ".ghostty",
                      ".iterm", ".warp", ".zed", ".terminal", ".nodeterm", ".neovim", ".vim"]
        return tokens.contains { raw.contains($0) }
    }

    static func isCodingOrAgentApp(_ bundleID: String?) -> Bool {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        if isCodingApp(raw) || agentBundleIDs.contains(raw) || AXTextContext.isCodingApp(raw) {
            return true
        }
        return raw.contains("claude") || raw.contains("codex") || raw.contains("antigravity")
    }

    static func isChatApp(_ bundleID: String?) -> Bool {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return false }
        if chatBundleIDs.contains(raw) { return true }
        return raw.contains(".slack") || raw.contains(".discord") || raw.contains(".mobilesms")
    }

    // MARK: - Single-Sentence Chat Period Stripping

    private static let dottedAbbreviationSuffix = try! NSRegularExpression(
        pattern: #"(?i)(?:^|\s)(?:(?:[a-z]\.){2,}|(?:etc|vs|inc|ltd|jr|sr|dr|mr|mrs|ms|prof|st|ave|dept|est|approx)\.)\s*$"#
    )

    /// Strips a trailing `.` on single-sentence chat messages while keeping `?`, `!`,
    /// ellipses, dotted abbreviations (`p.m.`, `U.S.`, `etc.`), multi-line text, and
    /// multi-sentence messages intact.
    static func stripSingleSentencePeriod(
        _ text: String,
        before: String? = nil,
        preserveExplicitPeriod: Bool = false
    ) -> String {
        guard !preserveExplicitPeriod, !text.isEmpty else { return text }
        if let before, before.contains(where: { !$0.isWhitespace }) {
            return text
        }
        guard !text.contains(where: \.isNewline) else { return text }
        let trailingSpaces = text.reversed().prefix(while: { $0 == " " || $0 == "\t" }).count
        let coreEnd = text.index(text.endIndex, offsetBy: -trailingSpaces)
        let core = text[..<coreEnd]
        guard core.last == ".", !core.hasSuffix("..") else { return text }

        let coreString = String(core)
        let fullRange = NSRange(coreString.startIndex..., in: coreString)
        if dottedAbbreviationSuffix.firstMatch(in: coreString, range: fullRange) != nil {
            return text
        }

        // Fast check for earlier hard sentence punctuation before invoking NLTokenizer.
        let withoutFinalDot = String(core.dropLast())
        if withoutFinalDot.contains("?") || withoutFinalDot.contains("!") {
            return text
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = coreString
        var sentenceCount = 0
        tokenizer.enumerateTokens(in: coreString.startIndex..<coreString.endIndex) { range, _ in
            if coreString[range].contains(where: { !$0.isWhitespace }) {
                sentenceCount += 1
            }
            return sentenceCount <= 1
        }
        guard sentenceCount == 1 else { return text }
        return withoutFinalDot + String(text[coreEnd...])
    }
}
