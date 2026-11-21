import Foundation
import XCTest
@testable import FlowCloneCore

/// Spoken "slash <command>" for agent apps with temporary homes for custom commands.
final class SlashCommandsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-slash-\(UUID().uuidString)", isDirectory: true)
        for skill in ["skills/codex-review", "skills/merge-worktrees",
                      "skills/synced/bucket-1/docx", "skills/synced/bucket-1/deep-research",
                      "plugin-install/skills/wrangler", "plugin-install/skills/turnstile-spin"] {
            try write("---\nname: x\n---\n", "claude/\(skill)/SKILL.md")
        }
        // A folder without SKILL.md is not a skill.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("claude/skills/synced-notes"),
                                                withIntermediateDirectories: true)
        try write("Ship it.\n", "claude/commands/ship-it.md")
        try write("Simplest fix.\n", "claude/commands/ponytail.md")
        try write("Debt audit.\n", "claude/commands/ponytail-debt.md")
        try write("Plugin command.\n", "claude/plugin-install/commands/deploy.md")
        let install = root.appendingPathComponent("claude/plugin-install").path
        try write(#"{"version":2,"plugins":{"cloudflare@cloudflare":[{"scope":"user","installPath":"\#(install)"}]}}"#,
                  "claude/plugins/installed_plugins.json")
        try write("Draft a PR.\n", "codex/prompts/draft-pr.md")
        try write("prompt = 'check the results'\n", "gemini/commands/project/check/results.toml")
        try write("prompt = 'bar'\n", "gemini/commands/standalone.toml")
        try write("Not a command.\n", "gemini/commands/project/check/discard.md")
        try write("---\nname: verify-layout\n---\n", "gemini/config/skills/verify-layout/SKILL.md")
        try write("---\nname: audit-notes\n---\n", "gemini/skills/audit-notes/SKILL.md")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func withHomes<T>(_ body: () throws -> T) rethrows -> T {
        try SlashCommands.withHomes(.init(claude: root.appendingPathComponent("claude"),
                                          codex: root.appendingPathComponent("codex"),
                                          gemini: root.appendingPathComponent("gemini")), body)
    }

    private func expect(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        withHomes {
            for (input, want) in cases {
                XCTAssertEqual(SlashCommands.recognize(input), want, input, file: file, line: line)
            }
        }
    }

    /// Every built-in command and alias, at line start and in a sentence.
    func testEveryBuiltInCommandIsRecognized() {
        withHomes {
            for name in Set(SlashCommands.builtIn) {
                let spoken = name.replacingOccurrences(of: "-", with: " ")
                XCTAssertEqual(SlashCommands.recognize("Slash \(spoken)."), "/\(name)", name)
                XCTAssertEqual(SlashCommands.recognize("Run slash \(spoken) now."), "Run /\(name) now.", name)
            }
        }
    }

    func testGoogleAndCodexCommandSyntax() {
        expect([
            ("Slash presets.", "/presets"),
            ("Slash config.", "/config"),
            ("Slash question mark.", "/?"),
            ("Slash code search Find the reducer.", "/codesearch Find the reducer"),
            ("Slash MCP. List.", "/mcp list"),
            ("Slash directory, Add My Project.", "/directory add My Project"),
            ("Slash hooks Disable All.", "/hooks disable-all"),
            ("Slash swarm Board.", "/swarm board"),
            ("Slash model. Set. My Model.", "/model set My Model"),
            ("Slash skills Reload.", "/skills reload"),
            ("Slash mcp NorthernService.", "/mcp NorthernService"),
            ("Slash generative U I.", "/generative_ui"),
            ("Slash generative_ui.", "/generative_ui"),
            ("Slash project colon check colon results.", "/project:check:results"),
            ("Slash project:check:results.", "/project:check:results"),
            ("Slash standalone.", "/standalone"),
            ("Slash verify layout.", "/verify-layout"),
            ("Slash audit notes.", "/audit-notes"),
        ])
        XCTAssertTrue(SlashCommands.isCommandLine("/?"))
    }

    func testEveryGoogleSubcommandKeepsItsSpaceAndSpelling() {
        withHomes {
            for (name, subcommands) in GoogleSlashCommands.subcommands {
                for subcommand in subcommands.values {
                    let spoken = subcommand.replacingOccurrences(of: "-", with: " ").uppercased()
                    XCTAssertEqual(SlashCommands.recognize("Slash \(name) \(spoken)."),
                                   "/\(name) \(subcommand)")
                }
            }
        }
    }

    func testNewCommandsUseTheDictationAndAppProfilePath() {
        withHomes {
            let store = PersonalizationStore(root: root.appendingPathComponent("agent-personalization"))
            Cleaner.withPersonalizationStore(store) {
                XCTAssertEqual(Cleaner.clean("Slash compress.", bundleID: "com.google.GeminiMacOS"), "/compress")
                XCTAssertEqual(Cleaner.clean("Slash question mark.", bundleID: "com.google.GeminiMacOS"), "/?")
                XCTAssertEqual(Cleaner.clean("Slash code search.", bundleID: "com.google.antigravity"), "/codesearch")
                XCTAssertEqual(Cleaner.clean("Slash presets.", bundleID: "com.openai.codex"), "/presets")
                XCTAssertEqual(Cleaner.clean("Slash MCP list.", bundleID: "com.superlogical.rex"), "/mcp list")
                XCTAssertEqual(Cleaner.clean("Slash compress.", bundleID: "com.apple.mail"), "Slash compress.")
            }
        }
    }

    func testSpokenCommandLinesAreTypedExactly() {
        expect([
            ("Slash compact.", "/compact"),
            ("Slash code review high.", "/code-review high"),
            ("Slash code-review.", "/code-review"),
            ("Slash, compact, focus on the tests.", "/compact focus on the tests"),
            ("Slash. Model. Opus.", "/model Opus"),
            ("Slash in it.", "/init"),
            ("Slash I.D.E.", "/ide"),
            ("Slash P W D", "/pwd"),
            ("Slash by the way, what does this flag do?", "/btw what does this flag do?"),
            ("Forward slash help", "/help"),
            ("Slash clawed API.", "/claude-api"),
            ("Slash design.", "/design"),
            ("Slash design sync", "/design-sync"),
            ("Slash setup default sandbox", "/setup-default-sandbox"),
            // Parakeet v2 transcripts of synthetic speech (installed model, 2026-10-02).
            ("Slash compact", "/compact"),
            ("Slash code review hi.", "/code-review hi"),
            ("Slash merge work trees.", "/merge-worktrees"),
        ])
    }

    /// Parakeet v2 mishearings from the 2026-10-02 sweep of every command in three
    /// synthetic voices: the closest known name within a few edits.
    func testMisheardCommandsSnapToTheClosestName() {
        expect([
            ("Slash demon.", "/daemon"),
            ("Slash heat dump.", "/heapdump"),
            ("Slash add deer.", "/add-dir"),
            ("Slash approved.", "/approve"),
            ("Slash check on.", "/checkup"),
            ("Slash hell.", "/help"),
            ("Slash loot.", "/loop"),
            ("Slash quid", "/quit"),
            ("Slash clan.", "/plan"),
            ("Slash key bindings held.", "/keybindings-help"),
            ("Slash viewer permission prompts", "/fewer-permission-prompts"),
            ("Slash simplifier.", "/simplify"),
            ("Slash remote envy.", "/remote-env"),
            ("Slash ponytail dead.", "/ponytail-debt"),          // a longer near match beats "ponytail"
            ("Then run slash data vis on this.", "Then run /dataviz on this."),
            ("Then run slash claw API on this.", "Then run /claude-api on this."),
            ("Then run slash term style spin on this.", "Then run /cloudflare:turnstile-spin on this."),
            // Talking about slashes, or a short word mid-sentence, stays prose.
            ("Slash commands are a Claude Code feature.", "Slash commands are a Claude Code feature."),
            ("We need to slash costs and plans.", "We need to slash costs and plans."),
            ("Slash and burn.", "Slash and burn."),
        ])
    }

    func testOwnersSkillsCommandsPluginsAndCodexPrompts() {
        expect([
            ("Slash Codex review.", "/codex-review"),
            ("Slash codecs review.", "/codex-review"),
            ("Slash code x review.", "/codex-review"),
            ("Slash ship it.", "/ship-it"),
            // claude.ai-synced skills are namespaced; a unique short name finds them too.
            ("Slash docx.", "/anthropic-skills:docx"),
            ("Slash anthropic skills docx", "/anthropic-skills:docx"),
            ("Slash deep research.", "/deep-research"),            // the built-in wins
            // Plugin skills and commands.
            ("Slash wrangler.", "/cloudflare:wrangler"),
            ("Slash cloudflare turnstile spin", "/cloudflare:turnstile-spin"),
            ("Slash cloudflare colon deploy", "/cloudflare:deploy"),
            // Codex custom prompts.
            ("Slash prompts draft PR.", "/prompts:draft-pr"),
        ])
    }

    func testArbitraryWordsAtUtteranceStartStayProseUnlessOwnedOrBuiltIn() throws {
        try withHomes {
            // Arbitrary words at utterance start NEVER become slash commands.
            XCTAssertEqual(SlashCommands.recognize("Slash frobnicate."), "Slash frobnicate.")
            XCTAssertEqual(SlashCommands.recognize("Slash prices by 20 percent."), "Slash prices by 20 percent.")
            XCTAssertEqual(SlashCommands.recognize("Slash the budget by half."), "Slash the budget by half.")
            XCTAssertEqual(SlashCommands.recognize("Then slash frobnicate."), "Then slash frobnicate.")
            // Once a custom command exists on disk, it converts cleanly with arguments.
            try write("Preview.\n", "claude/commands/launch-preview.md")
            XCTAssertEqual(SlashCommands.recognize("Slash Launch-Preview staging."), "/launch-preview staging")
        }
    }

    func testProseAppsAndNewlineLineStartProtection() throws {
        let store = PersonalizationStore(root: root.appendingPathComponent("prose-personalization", isDirectory: true))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        withHomes {
            // Common ~180 English command words stay prose in Mail, Messages, Notes, etc.
            for bundleID in ["com.apple.mail", "com.apple.MobileSMS", "com.apple.Notes"] {
                XCTAssertEqual(SlashCommands.apply("Slash status.", bundleID: bundleID), "Slash status.")
                XCTAssertEqual(SlashCommands.apply("Run slash plan now.", bundleID: bundleID), "Run slash plan now.")
                XCTAssertEqual(SlashCommands.apply("mobile slash desktop", bundleID: bundleID), "mobile slash desktop")
                // Explicit custom owned commands still work when spoken deliberately.
                XCTAssertEqual(SlashCommands.apply("Slash ship it.", bundleID: bundleID), "/ship-it")
            }
            // Even in coding/agent contexts, mid-sentence prose alternations do not convert.
            for bundleID in ["com.mitchellh.ghostty", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"] {
                XCTAssertEqual(SlashCommands.apply("mobile slash desktop", bundleID: bundleID), "mobile slash desktop")
                XCTAssertEqual(SlashCommands.apply("Slash prices by 20 percent.", bundleID: bundleID),
                               "Slash prices by 20 percent.")
                XCTAssertEqual(SlashCommands.apply("Slash commit.", bundleID: bundleID), "/commit")
            }
            // lineStart is computed relative to the most recent \n, not string index 0.
            Cleaner.withPersonalizationStore(store) {
                XCTAssertEqual(Cleaner.clean("new line slash commit", bundleID: "com.mitchellh.ghostty"), "\n/commit")
                XCTAssertEqual(Cleaner.clean("First line. New line slash commit.", bundleID: "com.mitchellh.ghostty"),
                               "First line.\n/commit")
            }
        }
    }

    func testCommandsInsideProseKeepTheSpeakersPunctuation() {
        expect([
            ("Then run slash code review.", "Then run /code-review."),
            ("Use slash compact, then slash clear.", "Use /compact, then /clear."),
            ("Ask it to run slash Codex review on the plan.", "Ask it to run /codex-review on the plan."),
            ("Then run slash code review on this branch", "Then run /code-review on this branch"),
        ])
    }

    /// The owner's own Parakeet v2 transcripts (History, 2026-09-08 to 2026-10-06), which the
    /// installed build without this matcher pasted with the word "slash".
    func testOwnersRealDictations() {
        expect([
            ("Slash design", "/design"),
            ("I want you to use slash design.", "I want you to use /design."),
            ("It does not work for slash design. I want you to make sure it works for all of the commands.",
             "It does not work for /design. I want you to make sure it works for all of the commands."),
            ("I want you to use slash design to make it look a little better and show me the options.",
             "I want you to use /design to make it look a little better and show me the options."),
            ("We're still having trouble with me being able to speak commands such as slash design and them actually being written out as the command is.",
             "We're still having trouble with me being able to speak commands such as /design and them actually being written out as the command is."),
            ("so I don't have to go in manually and do slash effort or slash model to select the effort level.",
             "so I don't have to go in manually and do /effort or /model to select the effort level."),
            // "Slash" as a word, or as "and/or", stays prose.
            ("Notice how in this very chat it writes out the word slash rather than the symbol.",
             "Notice how in this very chat it writes out the word slash rather than the symbol."),
            ("Clear out all of the non-terminal chats slash workspaces because they clutter it.",
             "Clear out all of the non-terminal chats slash workspaces because they clutter it."),
            ("Just keep the terminal panes slash workspaces like you did before.",
             "Just keep the terminal panes slash workspaces like you did before."),
            ("A serif and pastel slash paper color avenue.", "A serif and pastel slash paper color avenue."),
        ])
    }

    func testOrdinarySpeechIsUntouched() {
        let unchanged = [
            "We need to slash costs this quarter.",
            "Input slash output.",
            "The slash command is broken.",
            "Read the and/or clause in /usr/bin.",
            "Slashed prices everywhere.",
            "Nothing to convert here.",
        ]
        expect(unchanged.map { ($0, $0) })
        // A folder without SKILL.md names nothing.
        expect([("Run slash synced notes", "Run slash synced notes")])
    }

    func testCommandLinesAndMentions() {
        withHomes {
            XCTAssertTrue(SlashCommands.isCommandLine("/compact"))
            XCTAssertTrue(SlashCommands.isCommandLine("/model opus"))
            XCTAssertTrue(SlashCommands.isCommandLine("/frobnicate"))
            XCTAssertTrue(SlashCommands.isCommandLine("/cloudflare:wrangler"))
            XCTAssertFalse(SlashCommands.isCommandLine("Run /compact"))
            XCTAssertFalse(SlashCommands.isCommandLine("/usr/bin"))
            XCTAssertEqual(SlashCommands.mentions(in: "Run /code-review and /usr/bin, then /ship-it."),
                           ["/code-review", "/ship-it"])
        }
    }

    func testOwnedCommandsAreRescanned() throws {
        try withHomes {
            XCTAssertEqual(SlashCommands.recognize("Run slash nightly build"), "Run slash nightly build")
            try write("Build.\n", "claude/commands/nightly-build.md")
            XCTAssertEqual(SlashCommands.recognize("Run slash nightly build"), "Run /nightly-build")
        }
    }

    func testCleanupInsertionAndRewriteValidationKeepTheCommand() throws {
        let store = PersonalizationStore(root: root.appendingPathComponent("personalization", isDirectory: true))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        withHomes {
            Cleaner.withPersonalizationStore(store) {
                XCTAssertEqual(Cleaner.clean("Um, slash compact."), "/compact")
                XCTAssertEqual(Cleaner.clean("Please, uh, run slash code review."), "Please, run /code-review.")
            }
            // Not capitalized at a sentence start; spaced as its own word after text.
            XCTAssertEqual(InsertionFormatter.format("/compact", context: InsertionContext(before: "", after: nil)),
                           "/compact")
            XCTAssertEqual(InsertionFormatter.format("/compact", context: InsertionContext(before: "please", after: nil)),
                           " /compact")
            // Prompt's rewrite falls back to Clean rather than lose a typed command.
            let input = "Run /code-review on the payment changes before merging."
            XCTAssertEqual(Prompter.reject("Review the payment changes before merging.", input),
                           "changed agent command")
            XCTAssertNil(Prompter.reject(input, input))
        }
    }
}
