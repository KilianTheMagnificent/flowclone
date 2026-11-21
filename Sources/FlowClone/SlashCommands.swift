// Spoken agent commands: "slash compact" → "/compact", "slash code review" → "/code-review".
// Claude Code, Codex and Google's agent commands, including user-level custom commands,
// are inserted as typed. Runs last in Cleaner, so every non-Raw mode
// and the live preview share it; Raw, literal and spelling stay verbatim.
import Foundation

enum SlashCommands {
    /// Claude Code 2.1.287: its own command list (the `slash_commands` of
    /// `claude -p --output-format stream-json`) plus the interactive-only commands and
    /// aliases in the binary, read 2026-10-02, plus common git/PR commands (`commit`,
    /// `commit-push-pr`, `pr-comments`, `review-pr`). Internal and test-only commands are left out.
    static let claudeCode: [String] = [
        "add-dir", "advisor", "agents", "allowed-tools", "android", "app", "artifacts",
        "auto-mode-setup", "autocompact", "autofix-pr", "background", "bashes", "batch", "bg",
        "branch", "break-reminder", "breaks", "brief", "btw", "bug", "cd", "checkpoint",
        "checkup", "chrome", "claude-api", "clear", "cloud-plugins", "code-review", "color",
        "commit", "commit-push-pr", "compact", "config", "context", "copy", "cost", "daemon",
        "dataviz", "debug", "deep-research", "design", "design-consent", "design-login",
        "design-revoke", "design-sync", "desktop", "diff", "doctor", "downtime", "effort",
        "exit", "export", "extra-usage", "fast", "feedback", "fewer-permission-prompts",
        "focus", "fork", "goal", "heapdump", "help", "hooks", "ide", "import", "init",
        "insights", "install", "install-github-app", "install-slack-app", "ios", "keybindings",
        "keybindings-help", "list-agents", "login", "logout", "loop", "loops", "marketplace",
        "mcp", "memory", "memory-pause", "mobile", "model", "name", "output-style", "passes",
        "pause-memory", "peers", "permissions", "plan", "plugin", "plugin-authoring", "plugins",
        "powerup", "pr-comments", "privacy-settings", "quit", "radio", "rc", "recap",
        "release-notes", "reload-plugins", "reload-skills", "remote", "remote-control",
        "remote-env", "rename", "restart", "resume", "review-pr", "rewind", "routines", "run",
        "run-skill-generator", "sandbox", "schedule", "scroll-speed", "security-review",
        "session", "settings", "setup-bedrock", "setup-claude", "setup-cowork", "setup-vertex",
        "share", "simplify", "skill-doctor", "skills", "stats", "status", "statusline",
        "stickers", "stop", "subtask", "tasks", "team-onboarding", "teleport", "terminal-setup",
        "theme", "todos", "toggle-memory", "tui", "ultraplan", "ultrareview", "undo", "update",
        "update-config", "upgrade", "usage", "usage-credits", "verify", "version", "voice",
        "web-setup", "wellbeing", "workflow-authoring", "workflows",
    ]

    /// Codex CLI 0.170.0: public `SlashCommand` names and aliases from the installed version's
    /// codex-rs/tui/src/slash_command.rs. Also retains previously supported names and prompts.
    static let codex: [String] = [
        "agents", "app", "approve", "apps", "archive", "btw", "cd", "clean", "clear", "compact",
        "config", "copy", "cwd", "daemon", "daybreak", "debug-config", "delete", "diff", "exit",
        "experimental", "export", "feedback", "fork", "goal", "hooks", "ide", "import", "init",
        "keymap", "logout", "mcp", "memories", "mention", "model", "new", "permissions", "pet",
        "pets", "plan", "plugins", "presets", "ps", "pwd", "quit", "raw", "recap", "rename", "resume",
        "review", "rollout", "setup-default-sandbox", "side", "skills", "status", "statusline",
        "stop", "subagents", "theme", "title", "tui", "usage", "vim", "voice", "warnings",
        "worktree",
    ]

    static let builtIn = claudeCode + codex + GoogleSlashCommands.gemini + GoogleSlashCommands.antigravity

    /// Spoken forms that don't join into the name ("slash by the way" → "/btw").
    private static let aliases = ["bytheway": "btw", "adddirectory": "add-dir", "innit": "init",
                                  "remoteenvironment": "remote-env", "questionmark": "?"]

    /// ASR spellings of the two product names. Tried alongside the literal words, which
    /// win a tie, so a real name keeps priority ("slash cloud plugins" stays cloud-plugins).
    private static let homophones = ["clawed": "claude", "cloud": "claude", "claud": "claude",
                                     "clod": "claude", "claw": "claude", "clawd": "claude",
                                     "codecs": "codex", "codec": "codex"]

    /// "init" is often heard as "in it", "ide" as "I D E", and a plugin skill carries its
    /// plugin's words too; the longest run of words that joins to a known name wins.
    private static let maxWords = 8

    /// "slash"/"forward slash" as its own word, with the comma or period the ASR may put
    /// after it. Accept "slash?" as SmartFormat's output for "slash question mark".
    /// A path or "and/or" already typed as "/" never matches.
    private static let spokenSlash = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}/])(?:forward[ \t]+)?slash(?:[ \t]*[,.]?[ \t]+|(?=\?))"#)
    private static let typedCommand = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}/])/(\?|[\p{L}\p{N}][\p{L}\p{N}_:-]*)"#)
    private static let commandLineStart = try! NSRegularExpression(
        pattern: #"^[ \t]*/(?:\?|[\p{L}][\p{L}\p{N}_:-]*)(?:[ \t][^\r\n]*)?$"#)

    /// Verbs and introducers that precede a spoken command mid-sentence ("run slash compact",
    /// "use slash design", "commands such as slash design"), whereas noun/adjective pairs
    /// ("mobile slash desktop", "start slash stop", "ios slash android") stay prose.
    private static let commandIntroducers: Set<String> = [
        "run", "running", "ran", "use", "using", "used", "do", "doing", "did",
        "try", "trying", "tried", "type", "typing", "typed", "call", "calling",
        "invoke", "invoking", "execute", "executing", "enter", "entering",
        "send", "sending", "pass", "passing", "say", "saying", "said",
        "with", "for", "via", "as", "like", "then", "after", "before",
        "when", "while", "if",
    ]

    private enum ResolutionContext {
        case commandCapable
        case proseCustomOnly
        case disabled
    }

    /// Backwards-compatible entry point (defaults to command-capable context when no app is specified).
    static func recognize(_ text: String) -> String {
        apply(text)
    }

    static func apply(_ text: String, profile: ResolvedAppProfile) -> String {
        if profile.bundleID == nil {
            return apply(text, bundleID: nil, isCommandContext: profile.slashCommandsEnabled)
        }
        if profile.hasExplicitSlashCommandPreference && !profile.slashCommandsEnabled {
            return text
        }
        return apply(text, bundleID: profile.bundleID, isCommandContext: profile.slashCommandsEnabled)
    }

    /// App-aware slash-command recognition.
    /// - In coding/agent apps (or when `isCommandContext == true`), allowlisted built-in and
    ///   custom commands convert, while arbitrary words ("Slash prices by 20 percent.") and
    ///   prose alternations ("mobile slash desktop") stay prose.
    /// - In non-coding/non-agent prose apps (Mail, Messages, Notes, Docs, etc.), the
    ///   built-in English words never convert; only explicit custom commands convert.
    static func apply(
        _ text: String,
        bundleID: String? = nil,
        isCommandContext: Bool? = nil
    ) -> String {
        guard text.range(of: "slash", options: .caseInsensitive) != nil else { return text }
        let context = resolveContext(bundleID: bundleID, isCommandContext: isCommandContext)
        guard context != .disabled else { return text }

        let loaded = table()
        let activeNames: [String: String]
        let allowFuzzy: Bool
        switch context {
        case .commandCapable:
            activeNames = loaded.names
            allowFuzzy = true
        case .proseCustomOnly:
            activeNames = loaded.ownedNames
            allowFuzzy = false
        case .disabled:
            return text
        }
        guard !activeNames.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        var activeCommandLineFloor: String.Index?
        var matchedCommandLines: Set<String.Index> = []
        var commandLineRanges: [String.Index] = []

        for match in spokenSlash.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let spoken = Range(match.range, in: text), spoken.lowerBound >= cursor else { continue }
            let lineFloor = text[..<spoken.lowerBound].lastIndex(where: \.isNewline)
                .map { text.index(after: $0) } ?? text.startIndex
            let lineStart = text[lineFloor..<spoken.lowerBound].allSatisfy { $0 == " " || $0 == "\t" }
            let matchedEarlierOnLine = matchedCommandLines.contains(lineFloor)

            guard let (name, end) = command(
                after: spoken.upperBound,
                in: text,
                activeNames,
                lineStart: lineStart,
                allowFuzzy: allowFuzzy
            ) else { continue }

            if !lineStart, !allowsMidSentenceCommand(
                name: name,
                beforeSlash: text[lineFloor..<spoken.lowerBound],
                matchedEarlierOnLine: matchedEarlierOnLine
            ) {
                continue
            }

            if activeCommandLineFloor != nil, activeCommandLineFloor != lineFloor {
                activeCommandLineFloor = nil
            }

            let suffix = lineStart && allowFuzzy ? subcommand(of: name, after: end, in: text) : nil
            // /commands takes only documented subcommands. "Slash commands are useful"
            // is a sentence about commands, even at the start of a dictation.
            if lineStart, name == "commands", suffix == nil,
               text[end...].prefix(while: { !$0.isNewline }).contains(where: wordCharacter) {
                continue
            }
            output.append(contentsOf: text[cursor..<spoken.lowerBound])
            output.append("/" + name)
            if let (subcommand, _) = suffix { output.append(" " + subcommand) }
            cursor = suffix?.1 ?? end
            matchedCommandLines.insert(lineFloor)

            // A command line is typed, not a sentence: the ASR's "," or "." right after the
            // command goes. Inside prose ("Then run /code-review.") punctuation is the speaker's.
            if lineStart {
                activeCommandLineFloor = lineFloor
                commandLineRanges.append(lineFloor)
                if cursor < text.endIndex, ",.".contains(text[cursor]) {
                    let next = text.index(after: cursor)
                    if next == text.endIndex || text[next] == " " || text[next] == "\t" || text[next].isNewline {
                        cursor = next
                    }
                }
            }
        }

        guard cursor > text.startIndex else { return text }
        output.append(contentsOf: text[cursor...])

        if !commandLineRanges.isEmpty {
            output = stripCommandLineTrailingPeriods(output)
        }
        return output
    }

    private static func resolveContext(bundleID: String?, isCommandContext: Bool?) -> ResolutionContext {
        if let isCommandContext {
            return isCommandContext ? .commandCapable : .proseCustomOnly
        }
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .commandCapable
        }
        let profile = AppProfiles.shared.resolve(bundleID: raw)
        if profile.hasExplicitSlashCommandPreference && !profile.slashCommandsEnabled {
            return .disabled
        }
        return profile.slashCommandsEnabled ? .commandCapable : .proseCustomOnly
    }

    private static func allowsMidSentenceCommand(
        name: String,
        beforeSlash: Substring,
        matchedEarlierOnLine: Bool
    ) -> Bool {
        // Explicit hyphenated/namespaced commands ("code-review", "cloudflare:wrangler") are
        // unambiguous agent command names rather than single English words like "desktop".
        if name.contains(":") || name.contains("-") {
            let prev = previousWord(in: beforeSlash)?.lowercased()
            // Still block obvious prose alternations when neither word introduces a command.
            if let prev, !commandIntroducers.contains(prev), prev != "or", prev != "and",
               name == "remote-env" || name == "release-notes" {
                return false
            }
            return true
        }
        let trimmed = beforeSlash.reversed().drop(while: { $0 == " " || $0 == "\t" })
        guard let lastChar = trimmed.first else { return true }
        if "(:;\"'".contains(lastChar) {
            return true
        }
        guard let word = previousWord(in: beforeSlash)?.lowercased() else {
            return false
        }
        if commandIntroducers.contains(word) {
            return true
        }
        if matchedEarlierOnLine && (word == "or" || word == "and") {
            return true
        }
        return false
    }

    private static func previousWord(in slice: Substring) -> String? {
        var idx = slice.endIndex
        while idx > slice.startIndex {
            let prev = slice.index(before: idx)
            if slice[prev] == " " || slice[prev] == "\t" || slice[prev] == "," {
                idx = prev
            } else {
                break
            }
        }
        let end = idx
        while idx > slice.startIndex {
            let prev = slice.index(before: idx)
            if slice[prev].isLetter || slice[prev].isNumber || slice[prev] == "'" || slice[prev] == "-" {
                idx = prev
            } else {
                break
            }
        }
        guard idx < end else { return nil }
        return String(slice[idx..<end])
    }

    /// Strips a trailing ASR sentence period on lines that began with a typed `/command`,
    /// without disturbing prose lines before or after `\n`.
    private static func stripCommandLineTrailingPeriods(_ text: String) -> String {
        guard text.contains("/") else { return text }
        var lines: [String] = []
        var start = text.startIndex
        while start <= text.endIndex {
            let newline = text[start...].firstIndex(of: "\n")
            let segmentEnd = newline ?? text.endIndex
            var line = String(text[start..<segmentEnd])
            let hadCR = line.last == "\r"
            if hadCR { line.removeLast() }

            if isCommandLine(line) {
                while let last = line.last, last == " " || last == "\t" {
                    line.removeLast()
                }
                if line.hasSuffix("."), !line.hasSuffix("..") {
                    line.removeLast()
                }
            }
            if hadCR { line.append("\r") }
            lines.append(line)
            guard let newline else { break }
            start = text.index(after: newline)
        }
        return lines.joined(separator: "\n")
    }

    /// True when the text is one typed command line, which Prompt must not rewrite.
    static func isCommandLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard trimmed.first == "/", !trimmed.contains(where: \.isNewline) else { return false }
        return commandLineStart.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// Known commands typed in the text, in order. A rewrite must keep every one.
    static func mentions(in text: String) -> [String] {
        guard text.contains("/") else { return [] }
        let known = table().known
        return typedCommand.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text), known.contains(String(text[range])) else { return nil }
            return "/" + text[range]
        }
    }

    private static func wordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func subcommand(of name: String, after end: String.Index,
                                   in text: String) -> (String, String.Index)? {
        guard let names = GoogleSlashCommands.subcommands[name], end < text.endIndex else { return nil }
        var start = end
        if ",.".contains(text[start]) { start = text.index(after: start) }
        guard start < text.endIndex, " \t".contains(text[start]) else { return nil }
        while start < text.endIndex, " \t".contains(text[start]) { start = text.index(after: start) }
        return command(after: start, in: text, names, lineStart: true, allowFuzzy: false)
    }

    /// The command the next words name. Exact joins win; otherwise the closest known name
    /// within a few edits, because the recognizer hears "/daemon" as "demon" and "/heapdump"
    /// as "heat dump". Each edit costs two characters of matched span, so a longer, nearly
    /// exact name beats a shorter exact one ("sandbox migrate the next" → sandbox-migrate-to-next).
    /// Mid-sentence, only names of six or more letters are fuzzy: "slash costs" stays prose.
    private static func command(
        after start: String.Index,
        in text: String,
        _ names: [String: String],
        lineStart: Bool,
        allowFuzzy: Bool
    ) -> (String, String.Index)? {
        if start < text.endIndex, text[start] == "?", names["questionmark"] == "?" {
            return ("?", text.index(after: start))
        }
        var words: [(word: String, end: String.Index)] = []
        var i = start
        while words.count < maxWords {
            let end = text[i...].firstIndex { !wordCharacter($0) } ?? text.endIndex
            guard end > i else { break }
            words.append((text[i..<end].lowercased(), end))
            // Spaces or name separators; dots also split a token such as "I.D.E".
            var next = end
            while next < text.endIndex, " \t-_:".contains(text[next]) { next = text.index(after: next) }
            if next == end, next < text.endIndex, text[next] == "." {
                next = text.index(after: next)
            }
            guard next > end, next < text.endIndex, wordCharacter(text[next]) else { break }
            i = next
        }
        guard !words.isEmpty else { return nil }

        var best: (name: String, end: String.Index, score: Int, length: Int)?
        for count in stride(from: words.count, to: 0, by: -1) {
            // "slash cloudflare colon wrangler" names the plugin explicitly.
            let spoken = words.prefix(count).map(\.word).filter { $0 != "colon" }
            guard !spoken.isEmpty else { continue }
            for joined in [spoken.joined(), spoken.map { homophones[$0] ?? $0 }.joined()] {
                let end = words[count - 1].end
                let exact = names[joined]
                // An exact command plus an exact subcommand outranks a fuzzy match
                // for the combined words (such as "IDE install" → "install").
                if lineStart, allowFuzzy, let exact, subcommand(of: exact, after: end, in: text) != nil {
                    return (exact, end)
                }
                guard let (name, edits) = exact.map({ ($0, 0) })
                        ?? (allowFuzzy ? nearest(joined, in: names, minimumLength: lineStart ? 4 : 6) : nil) else {
                    continue
                }
                let score = joined.count - 2 * edits
                if best == nil || score > best!.score || (score == best!.score && joined.count > best!.length) {
                    best = (name, end, score, joined.count)
                }
            }
        }
        return best.map { ($0.name, $0.end) }
    }

    /// The closest name within one edit up to five letters, two up to nine, three beyond.
    /// A tie goes to the name of the same length: the recognizer swaps sounds more than it
    /// adds them ("clan" → plan, not clean). Plural English nouns ("costs" vs "cost",
    /// "plans" vs "plan") are excluded so "Slash costs by 20%" stays prose.
    private static func nearest(_ spoken: String, in names: [String: String],
                                minimumLength: Int) -> (String, Int)? {
        var best: (key: String, edits: Int)?
        for key in names.keys where key.count >= minimumLength {
            if spoken == key + "s" || spoken == key + "es" { continue }
            let longest = max(key.count, spoken.count)
            let allowed = longest <= 5 ? 1 : longest <= 9 ? 2 : 3
            guard abs(key.count - spoken.count) <= allowed else { continue }
            let edits = Cleaner.distance(spoken, key)
            guard edits <= allowed else { continue }
            if let current = best {
                let sameLength = key.count == spoken.count, currentSame = current.key.count == spoken.count
                guard edits < current.edits || (edits == current.edits
                    && (sameLength && !currentSame || sameLength == currentSame && key < current.key)) else { continue }
            }
            best = (key, edits)
        }
        return best.flatMap { best in names[best.key].map { ($0, best.edits) } }
    }

    // MARK: - Names

    private struct Table {
        let names: [String: String]       // spoken key → built-in or custom command
        let ownedNames: [String: String]  // spoken key → custom user-owned command only
        let known: Set<String>
    }

    private static func key(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Where the owner's own commands live. Rescanned at most every 30 seconds, and only
    /// when an utterance says "slash".
    struct Homes: Sendable {
        var claude: URL
        var codex: URL
        var gemini: URL? = nil
        static let user = Homes(
            claude: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
            codex: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
            gemini: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini"))
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var homes = Homes.user
        var maxAge: TimeInterval = 30
        var loaded = Date.distantPast
        var table: Table?
    }
    private static let state = State()

    /// Test seam: read the owner's commands from these homes and rescan on every call.
    static func withHomes<T>(_ homes: Homes, _ body: () throws -> T) rethrows -> T {
        func use(_ next: Homes, _ maxAge: TimeInterval) -> (Homes, TimeInterval) {
            state.lock.withLock {
                defer { state.homes = next; state.maxAge = maxAge; state.table = nil }
                return (state.homes, state.maxAge)
            }
        }
        let previous = use(homes, 0)
        defer { _ = use(previous.0, previous.1) }
        return try body()
    }

    private static func validCommands(_ list: [String]) -> [String] {
        list.filter {
            $0.range(of: #"^(?:\?|[A-Za-z0-9][A-Za-z0-9_-]*(?::[A-Za-z0-9][A-Za-z0-9_-]*)*)$"#,
                     options: .regularExpression) != nil
        }
    }

    private static func buildNameMap(_ commands: [String], includeAliases: Bool) -> [String: String] {
        var names: [String: String] = [:]
        for command in commands where names[key(command)] == nil {
            names[key(command)] = command
        }
        if includeAliases {
            for (spoken, command) in aliases where names[spoken] == nil {
                names[spoken] = command
            }
        }
        let short = Dictionary(grouping: commands.filter { $0.contains(":") }) {
            key(String($0.split(separator: ":").last ?? ""))
        }
        for (spoken, full) in short where full.count == 1 && names[spoken] == nil {
            names[spoken] = full[0]
        }
        return names
    }

    private static func table() -> Table {
        state.lock.withLock {
            if let table = state.table, Date().timeIntervalSince(state.loaded) < state.maxAge { return table }
            let customCommands = validCommands(owned(state.homes))
            let allCommands = validCommands(builtIn) + customCommands
            let names = buildNameMap(allCommands, includeAliases: true)
            let ownedNames = buildNameMap(customCommands, includeAliases: false)
            let table = Table(names: names, ownedNames: ownedNames, known: Set(allCommands))
            state.loaded = Date()
            state.table = table
            return table
        }
    }

    /// Skills (`<name>/SKILL.md`) and commands (`<name>.md`) the owner installed: personal,
    /// claude.ai-synced (`anthropic-skills:`), plugin (`<plugin>:`), and Codex custom prompts.
    private static func owned(_ homes: Homes) -> [String] {
        let fm = FileManager.default
        func entries(_ directory: URL) -> [String] { (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] }
        func skills(_ directory: URL) -> [String] {
            entries(directory).filter {
                fm.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("SKILL.md").path)
            }
        }
        func markdown(_ directory: URL) -> [String] {
            entries(directory).filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
        }
        let claude = homes.claude
        var names = skills(claude.appendingPathComponent("skills")) + markdown(claude.appendingPathComponent("commands"))
        let synced = claude.appendingPathComponent("skills/synced")
        for bucket in entries(synced) where !bucket.hasPrefix(".") {
            names += skills(synced.appendingPathComponent(bucket)).map { "anthropic-skills:" + $0 }
        }
        let manifest = claude.appendingPathComponent("plugins/installed_plugins.json")
        if let data = try? Data(contentsOf: manifest),
           let plugins = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["plugins"] as? [String: Any] {
            for (id, installs) in plugins {
                guard let plugin = id.split(separator: "@").first else { continue }
                for case let install as [String: Any] in installs as? [Any] ?? [] {
                    guard let path = install["installPath"] as? String else { continue }
                    let root = URL(fileURLWithPath: path)
                    names += (skills(root.appendingPathComponent("skills")) + markdown(root.appendingPathComponent("commands")))
                        .map { "\(plugin):\($0)" }
                }
            }
        }
        names += markdown(homes.codex.appendingPathComponent("prompts")).map { "prompts:" + $0 }
        if let gemini = homes.gemini { names += GoogleSlashCommands.owned(in: gemini) }
        return names
    }
}
