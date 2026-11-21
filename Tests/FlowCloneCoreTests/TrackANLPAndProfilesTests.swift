import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import FlowCloneCore

final class TrackANLPAndProfilesTests: XCTestCase {
    private var root: URL!
    private var store: PersonalizationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-track-a-c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PersonalizationStore(root: root)
        try write("""
            FlowClone
            FluidAudio
            Context Vocabulary
            Clean

            """, "dictionary.txt")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    private func write(_ text: String, _ filename: String, modifiedAt: Date? = nil) throws {
        let url = root.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    // MARK: - 1. P0 SlashCommands Prose Protection

    func testSlashCommandsProseProtectionAndLineStart() throws {
        let claudeHome = root.appendingPathComponent("claude", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let customCmd = claudeHome.appendingPathComponent("commands/deploy-prod.md")
        try FileManager.default.createDirectory(at: customCmd.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Deploy.\n".utf8).write(to: customCmd)

        SlashCommands.withHomes(.init(claude: claudeHome, codex: codexHome)) {
            let proseBundles = [
                "com.apple.mail",
                "com.apple.MobileSMS",
                "com.apple.Notes",
                "com.google.Chrome",
                "com.microsoft.Word",
            ]
            for bundleID in proseBundles {
                XCTAssertEqual(SlashCommands.apply("mobile slash desktop", bundleID: bundleID),
                               "mobile slash desktop", bundleID)
                XCTAssertEqual(SlashCommands.apply("Slash status.", bundleID: bundleID),
                               "Slash status.", bundleID)
                XCTAssertEqual(SlashCommands.apply("Slash plan for Q3.", bundleID: bundleID),
                               "Slash plan for Q3.", bundleID)
                XCTAssertEqual(SlashCommands.apply("Run slash review on the draft.", bundleID: bundleID),
                               "Run slash review on the draft.", bundleID)
                XCTAssertEqual(SlashCommands.apply("Slash prices by 20 percent.", bundleID: bundleID),
                               "Slash prices by 20 percent.", bundleID)
                // Explicit user-owned custom slash commands still fire when deliberately spoken.
                XCTAssertEqual(SlashCommands.apply("Slash deploy prod.", bundleID: bundleID),
                               "/deploy-prod", bundleID)
            }

            let codingBundles = [
                "com.mitchellh.ghostty",
                "com.todesktop.230313mzl4w4u92",
                "com.apple.dt.Xcode",
            ]
            for bundleID in codingBundles {
                XCTAssertEqual(SlashCommands.apply("mobile slash desktop", bundleID: bundleID),
                               "mobile slash desktop", bundleID)
                XCTAssertEqual(SlashCommands.apply("Slash prices by 20 percent.", bundleID: bundleID),
                               "Slash prices by 20 percent.", bundleID)
                XCTAssertEqual(SlashCommands.apply("Slash compact.", bundleID: bundleID),
                               "/compact", bundleID)
                XCTAssertEqual(SlashCommands.apply("Slash commit.", bundleID: bundleID),
                               "/commit", bundleID)
            }

            Cleaner.withPersonalizationStore(store) {
                XCTAssertEqual(Cleaner.clean("new line slash commit", bundleID: "com.mitchellh.ghostty"),
                               "\n/commit")
                XCTAssertEqual(Cleaner.clean("Summary ready. New line slash review.", bundleID: "com.mitchellh.ghostty"),
                               "Summary ready.\n/review")
                XCTAssertEqual(Cleaner.clean("mobile slash desktop", bundleID: "com.apple.mail"),
                               "mobile slash desktop")
                XCTAssertEqual(Cleaner.clean("Slash prices by 20 percent.", bundleID: "com.mitchellh.ghostty"),
                               "Slash prices by 20 percent.")
            }
        }
    }

    // MARK: - 2. P0 Cleaner, RepairReview & VocabularySets Caching

    func testCleanerMatchesAcrossNewlinesWithoutCrossLinePhraseMerging() {
        Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean("hello\nflowclone"), "hello\nFlowClone")
            XCTAssertEqual(Cleaner.clean("Hello. New line flowclone"), "Hello.\nFlowClone")
            XCTAssertEqual(Cleaner.clean("new line flowclone"), "\nFlowClone")
            XCTAssertEqual(Cleaner.clean("floyd audio\nflowclone"), "FluidAudio\nFlowClone")
            // Multi-word dictionary terms must NOT merge across a newline boundary.
            XCTAssertEqual(Cleaner.clean("The context\nvocabulary stays split."),
                           "The context\nvocabulary stays split.")
        }
    }

    func testFillersPreserveSentenceEndingPunctuationMidUtterance() {
        Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean("Let's ship it um. Tomorrow works"),
                           "Let's ship it. Tomorrow works")
            XCTAssertEqual(Cleaner.clean("Let's ship it, um. Tomorrow works."),
                           "Let's ship it. Tomorrow works.")
            XCTAssertEqual(Cleaner.clean("Does that work uh? Let me know."),
                           "Does that work? Let me know.")
            XCTAssertEqual(Cleaner.clean("Ship it now erm! Right away."),
                           "Ship it now! Right away.")
        }
    }

    func testRepairReviewPreservesTerminalPunctuationWhenDeletingTrailingFragment() throws {
        let cases: [(raw: String, reviewed: String, expected: String)] = [
            ("Start research re.", "Start research.", "Start research."),
            ("Start research, re.", "Start research.", "Start research."),
            ("Is it ready re?", "Is it ready?", "Is it ready?"),
            ("Ship it now re!", "Ship it now!", "Ship it now!"),
        ]
        for item in cases {
            let windows = RepairReview.windows(in: item.raw, scope: .full)
            XCTAssertEqual(windows.count, 1, item.raw)
            let window = try XCTUnwrap(windows.first, item.raw)
            guard case .delete(let words) = RepairReview.verdict(
                for: window,
                in: item.raw,
                modelOutput: item.reviewed,
                scope: .full
            ) else {
                XCTFail("Expected delete verdict for \(item.raw)")
                continue
            }
            XCTAssertEqual(RepairReview.applying(words, to: item.raw), item.expected, item.raw)
        }
    }

    func testSnippetExpansionDoesNotDuplicateTerminalPunctuation() throws {
        try write("""
            thanks -> Thank you.
            ask -> Can you check this?
            cheer -> Awesome!
            hold -> Hold on...

            """, "snippets.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_100))

        Cleaner.withPersonalizationStore(store) {
            XCTAssertEqual(Cleaner.clean("Thanks."), "Thank you.")
            XCTAssertEqual(Cleaner.clean("Say thanks."), "Say Thank you.")
            XCTAssertEqual(Cleaner.clean("Ask."), "Can you check this?")
            XCTAssertEqual(Cleaner.clean("Cheer."), "Awesome!")
            // Intentional ellipsis inside the snippet body stays intact without adding a 4th dot.
            XCTAssertEqual(Cleaner.clean("Hold."), "Hold on...")
        }
    }

    func testVocabularySetsAndCleanerConfigurationCacheByMtimeAcrossAppsAndContextWords() throws {
        let setsRoot = root.appendingPathComponent("sets-root", isDirectory: true)
        let sets = VocabularySets(root: setsRoot)
        let baseStore = sets.store(nil)
        try FileManager.default.createDirectory(at: baseStore.root, withIntermediateDirectories: true)
        try Data("FlowClone\nFluidAudio\n".utf8).write(
            to: baseStore.root.appendingPathComponent(PersonalizationKind.dictionary.filename),
            options: .atomic
        )
        try Data("cooper netties -> Kubernetes\n".utf8).write(
            to: baseStore.root.appendingPathComponent(PersonalizationKind.correction.filename),
            options: .atomic
        )

        let first = sets.configuration(bundleID: "com.apple.mail")
        XCTAssertEqual(sets.compileCount, 1)
        let readsAfterFirst = sets.diskReadCount
        XCTAssertGreaterThan(readsAfterFirst, 0)

        // Switching targetApp MUST NOT re-read files or recompile base regexes when no app-specific set differs.
        let second = sets.configuration(bundleID: "com.todesktop.230313mzl4w4u92")
        let third = sets.configuration(bundleID: "com.apple.MobileSMS")
        XCTAssertEqual(sets.compileCount, 1)
        XCTAssertEqual(sets.diskReadCount, readsAfterFirst)
        XCTAssertEqual(first.appProfile.slashCommandsEnabled, false)
        XCTAssertEqual(second.appProfile.slashCommandsEnabled, true)
        XCTAssertEqual(third.appProfile.slashCommandsEnabled, false)

        // Cleaner.Configuration.prepare also reuses the mtime cache across changing targetApp & contextWords.
        let cfg1 = Cleaner.Configuration.prepare(
            store: baseStore,
            targetApp: "com.apple.mail",
            contextWords: ["ContextAlpha"]
        )
        let cfg2 = Cleaner.Configuration.prepare(
            store: baseStore,
            targetApp: "com.todesktop.230313mzl4w4u92",
            contextWords: ["ContextBeta", "ContextGamma"]
        )
        XCTAssertEqual(cfg1.entries(.dictionary).map(\.primary), ["FlowClone", "FluidAudio"])
        XCTAssertEqual(cfg2.entries(.dictionary).map(\.primary), ["FlowClone", "FluidAudio"])

        // Updating a file's mtime invalidates only the changed store and recompiles once.
        let dictURL = baseStore.root.appendingPathComponent(PersonalizationKind.dictionary.filename)
        try Data("FlowClone\nFluidAudio\nParakeet\n".utf8).write(to: dictURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
            ofItemAtPath: dictURL.path
        )
        let fourth = sets.configuration(bundleID: "com.apple.mail")
        XCTAssertEqual(sets.compileCount, 2)
        XCTAssertTrue(fourth.entries(.dictionary).contains { $0.primary == "Parakeet" })
    }

    // MARK: - 3. P0 ContextVocabulary.scrubCode Directive Fix

    func testContextVocabularyScrubCodePreservesDirectivesAndPrivateFields() {
        let code = """
        #!/usr/bin/env bash
        # Pure shell/prose comment SecretShellToken should be scrubbed
        ## Markdown HeadingToken should be scrubbed
        #if CustomBuildFlag
        let tap = #selector(handleTapGesture)
        #endif
        #[derive(Clone, CustomRustTrait)]
        #![allow(CustomCrateLint)]
        #include <WidgetHeaderBridge.h>
        #define CustomRetryBudget 5
        class Counter {
            #privateCounterField = 0;
            bump() { return this.#privateCounterField; }
        }
        let x = 1#TrailingInlineCommentSecret
        """
        let terms = ContextVocabulary.extract(visible: code)
        let canonicals = Set(terms.map(\.canonical))
        XCTAssertTrue(canonicals.contains("CustomBuildFlag"))
        XCTAssertTrue(canonicals.contains("handleTapGesture"))
        XCTAssertTrue(canonicals.contains("CustomRustTrait"))
        XCTAssertTrue(canonicals.contains("CustomCrateLint"))
        XCTAssertTrue(canonicals.contains("WidgetHeaderBridge"))
        XCTAssertTrue(canonicals.contains("CustomRetryBudget"))
        XCTAssertTrue(canonicals.contains("privateCounterField"))

        XCTAssertFalse(canonicals.contains("SecretShellToken"))
        XCTAssertFalse(canonicals.contains("HeadingToken"))
        XCTAssertFalse(canonicals.contains("TrailingInlineCommentSecret"))
    }

    // MARK: - 4. P0 RewriteFidelity & Prompter Multi-Sentence + Number Fixes

    func testRewriteFidelityMultiSentenceOpenersAndNumerals() {
        // Capitalized ordinary sentence openers in sentences 2+ are NOT treated as proper nouns.
        let multi = """
        We finished the migration today. However, the staging server needs a restart. \
        Please check the logs! Also\nUpdate the dashboard? Check with FlowClone support and Dr. Marcus.
        """
        let rewritten = """
        We completed the migration today, though the staging server needs a restart. \
        Review the logs and refresh the dashboard, then contact FlowClone support and Dr. Marcus.
        """
        XCTAssertNil(Prompter.reject(rewritten, multi))

        // Dropping a real proper noun ("Marcus") or mixedCase identifier ("FlowClone") still rejects.
        let droppedProper = """
        We completed the migration today, though the staging server needs a restart. \
        Review the logs and refresh the dashboard, then contact FlowClone support.
        """
        XCTAssertEqual(Prompter.reject(droppedProper, multi), "lost name or identifier")

        let mixedAtStart = "We shipped it. FlowClone launched fast."
        XCTAssertEqual(Prompter.reject("We shipped it. The app launched fast.", mixedAtStart),
                       "lost name or identifier")

        // "one" <-> "1" and magnitude phrases ("five hundred" <-> "500", "fifty thousand" <-> "50,000").
        XCTAssertNil(Prompter.reject("Wait 1 minute before retrying.", "Wait one minute before retrying."))
        XCTAssertNil(Prompter.reject("Tell me which worked best.", "Tell me which one worked best."))
        XCTAssertNil(Prompter.reject("We processed 500 records.", "We processed five hundred records."))
        XCTAssertNil(Prompter.reject("The limit is 1,500 requests.", "The limit is one thousand five hundred requests."))
        XCTAssertNil(Prompter.reject("Budget is 50,000 dollars.", "Budget is fifty thousand dollars."))
        XCTAssertEqual(Prompter.reject("We processed 600 records.", "We processed five hundred records."),
                       "changed quantity")
    }

    // MARK: - 5. P0 AutoLearn Safety + Visible Pending Suggestions UI

    @MainActor
    func testAutoLearnModuloSpaceCodeGuardAndSuggestionsApprovalWorkflow() throws {
        // Modulo-space pairs ("checkout" <-> "check out", "login" <-> "log in", "setup" <-> "set up")
        // MUST NOT silently auto-save on a single edit.
        let moduloPairs = [
            ("checkout", "check out"),
            ("check out", "checkout"),
            ("login", "log in"),
            ("log in", "login"),
            ("setup", "set up"),
            ("set up", "setup"),
        ]
        for (wrong, right) in moduloPairs {
            XCTAssertFalse(
                AutoLearn.isAutomaticSpelling(wrong, right, bundleID: "com.apple.mail", isKnownWord: { _ in true }),
                "\(wrong) -> \(right)"
            )
        }
        // Multi-word -> mixedCase product names ("open code" -> "OpenCode") still auto-save.
        XCTAssertTrue(AutoLearn.isAutomaticSpelling("open code", "OpenCode", isKnownWord: { _ in true }))

        // Code-like tokens and coding bundle IDs skip single-edit NSSpellChecker auto-saves.
        XCTAssertFalse(AutoLearn.isAutomaticSpelling("usr_id", "user_id",
                                                     bundleID: "com.apple.mail", isKnownWord: { _ in true }))
        XCTAssertFalse(AutoLearn.isAutomaticSpelling("teh", "the",
                                                     bundleID: "com.todesktop.230313mzl4w4u92",
                                                     isKnownWord: { _ in true }))
        XCTAssertFalse(AutoLearn.isAutomaticSpelling("teh", "the",
                                                     bundleID: "com.apple.dt.Xcode",
                                                     isKnownWord: { _ in true }))
        XCTAssertFalse(AutoLearn.activeSpellcheckLanguage().isEmpty)

        // Single-edit modulo-space observation routes to CorrectionSuggestions, then Approve saves it.
        let suggestionsURL = root.appendingPathComponent("pending-suggestions.json")
        let suggestions = CorrectionSuggestions(storageURL: suggestionsURL)
        let pairs1 = AutoLearn.findCorrections(
            pasted: "Please checkout the branch today.",
            field: "Please check out the branch today."
        )
        XCTAssertEqual(pairs1.map { "\($0.wrong)->\($0.right)" }, ["checkout->check out"])
        let saved1 = AutoLearn.learn(
            pairs1,
            app: "Mail",
            bundleID: "com.apple.mail",
            store: store,
            suggestions: suggestions,
            report: false
        )
        XCTAssertNil(saved1)
        XCTAssertEqual(suggestions.current().count, 1)
        XCTAssertEqual(suggestions.current().first?.wrong, "checkout")
        XCTAssertEqual(suggestions.current().first?.right, "check out")

        // Persisted across reload from disk.
        let reloadedSuggestions = CorrectionSuggestions(storageURL: suggestionsURL)
        XCTAssertEqual(reloadedSuggestions.current().count, 1)

        // 1-click Approve adds to PersonalizationStore and clears from pending.
        let item = try XCTUnwrap(suggestions.current().first)
        let token = try AutoLearn.approveSuggestion(item.id, suggestions: suggestions, store: store)
        XCTAssertNotNil(token)
        XCTAssertTrue(suggestions.current().isEmpty)
        let learned = try store.snapshot(.correction).entries
        XCTAssertTrue(learned.contains(where: { $0.primary == "checkout" && $0.replacement == "check out" }))

        // Dismiss removes without saving.
        let pairs2 = AutoLearn.findCorrections(
            pasted: "Finish the login screen today.",
            field: "Finish the log in screen today."
        )
        let saved2 = AutoLearn.learn(
            pairs2,
            app: "Mail",
            bundleID: "com.apple.mail",
            store: store,
            suggestions: suggestions,
            report: false
        )
        XCTAssertNil(saved2)
        let toDismiss = try XCTUnwrap(suggestions.current().first)
        XCTAssertTrue(AutoLearn.dismissSuggestion(toDismiss.id, suggestions: suggestions))
        XCTAssertTrue(suggestions.current().isEmpty)
        let learnedAfterDismiss = try store.snapshot(.correction).entries
        XCTAssertFalse(learnedAfterDismiss.contains(where: { $0.primary == "login" }))

        // PersonalizationPage constructs cleanly with visible suggestions and AppProfiles.
        let profiles = AppProfiles(root: root.appendingPathComponent("ui-profiles", isDirectory: true))
        let hosting = NSHostingView(rootView: PersonalizationPage(
            title: "Dictionary",
            kinds: PersonalizationKind.allCases,
            store: store,
            suggestions: suggestions,
            appProfiles: profiles
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
    }

    // MARK: - 6. P1 InsertionFormatter Cached NLTagger & Opening Word Protection

    func testInsertionFormatterReusesTaggerAndFormatsSnippetsNaturally() {
        let id1 = InsertionFormatter.taggerInstanceIdentifier
        _ = InsertionFormatter.format("She went home.", context: InsertionContext(before: "Why? ", after: nil))
        let id2 = InsertionFormatter.taggerInstanceIdentifier
        XCTAssertEqual(id1, id2)

        // Multi-word prose snippets ("ty -> Thank you", "ttyl -> talk to you later") and split identifiers
        // do NOT block mid-sentence lowercasing or sentence-start capitalization.
        let snippetProtected = ["Thank you", "talk to you later", "get_user_id", "Clean", "Context Vocabulary"]
        XCTAssertEqual(
            InsertionFormatter.format("Thank you.", context: InsertionContext(before: "Sounds great, ", after: nil),
                                      protectedTerms: snippetProtected),
            "thank you."
        )
        XCTAssertEqual(
            InsertionFormatter.format("talk to you later", context: InsertionContext(before: "", after: nil),
                                      protectedTerms: snippetProtected),
            "Talk to you later"
        )
        XCTAssertEqual(
            InsertionFormatter.format("Get ready.", context: InsertionContext(before: "Wait, ", after: nil),
                                      protectedTerms: snippetProtected),
            "get ready."
        )
        // Single-word capitalized dictionary terms ("Clean") and Titlecase proper names ("Context Vocabulary")
        // remain protected mid-sentence.
        XCTAssertEqual(
            InsertionFormatter.format("Clean mode works.", context: InsertionContext(before: "Use ", after: nil),
                                      protectedTerms: snippetProtected),
            "Clean mode works."
        )
        XCTAssertEqual(
            InsertionFormatter.format("Context Vocabulary helps.", context: InsertionContext(before: "Enable ", after: nil),
                                      protectedTerms: snippetProtected),
            "Context Vocabulary helps."
        )
    }

    // MARK: - 7. Track C: AppProfiles, SpokenCodeFormat, Arrow & Dynamic Snippets

    func testAppProfilesModesAndChatPeriodStripping() throws {
        let profiles = AppProfiles(root: root.appendingPathComponent("profiles", isDirectory: true))

        // Built-in defaults recognize chat vs coding vs general prose apps.
        let smsDefault = profiles.resolve(bundleID: "com.apple.MobileSMS")
        XCTAssertFalse(smsDefault.slashCommandsEnabled)
        XCTAssertFalse(smsDefault.codeFormattingEnabled)
        XCTAssertEqual(smsDefault.preferredMode, AppDictationMode.global)

        let cursorDefault = profiles.resolve(bundleID: "com.todesktop.230313mzl4w4u92")
        XCTAssertTrue(cursorDefault.slashCommandsEnabled)
        XCTAssertTrue(cursorDefault.codeFormattingEnabled)

        // Custom per-app profile persists mode, chat period stripping, and toggles.
        try profiles.update { doc in
            doc.profiles.append(AppProfile(
                bundleID: "com.tinyspeck.slackmacgap",
                preferredMode: .clean,
                stripSingleSentencePeriod: true,
                slashCommandsEnabled: false,
                codeFormattingEnabled: false
            ))
        }
        let reloaded = AppProfiles(root: root.appendingPathComponent("profiles", isDirectory: true))
        let slack = reloaded.resolve(bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(slack.effectiveMode(default: .prompt), Mode.clean)
        XCTAssertTrue(slack.stripSingleSentencePeriod)

        // Chat single-sentence period stripping keeps ?/!, multi-sentence periods, abbreviations, and explicit periods.
        XCTAssertEqual(
            InsertionFormatter.format("Sounds good to me.",
                                      context: InsertionContext(before: "", after: nil),
                                      stripSingleSentencePeriod: true),
            "Sounds good to me"
        )
        XCTAssertEqual(
            InsertionFormatter.format("Are we shipping today?",
                                      context: InsertionContext(before: "", after: nil),
                                      stripSingleSentencePeriod: true),
            "Are we shipping today?"
        )
        XCTAssertEqual(
            InsertionFormatter.format("Ship it!",
                                      context: InsertionContext(before: "", after: nil),
                                      stripSingleSentencePeriod: true),
            "Ship it!"
        )
        XCTAssertEqual(
            InsertionFormatter.format("Sounds good. Let's ship at 5.",
                                      context: InsertionContext(before: "", after: nil),
                                      stripSingleSentencePeriod: true),
            "Sounds good. Let's ship at 5."
        )
        XCTAssertEqual(
            InsertionFormatter.format("That works too.",
                                      context: InsertionContext(before: "First sentence. ", after: nil),
                                      stripSingleSentencePeriod: true),
            "That works too."
        )
        XCTAssertEqual(
            AppProfiles.stripSingleSentencePeriod("Done.", preserveExplicitPeriod: true),
            "Done."
        )
    }

    func testSpokenCodeFormattingInCodingContextsOnly() {
        Cleaner.withPersonalizationStore(store) {
            let cursor = "com.todesktop.230313mzl4w4u92"
            let mail = "com.apple.mail"

            XCTAssertEqual(Cleaner.clean("camel case get user id", bundleID: cursor), "getUserId")
            XCTAssertEqual(Cleaner.clean("snake case max retry count", bundleID: cursor), "max_retry_count")
            XCTAssertEqual(Cleaner.clean("pascal case user profile view", bundleID: cursor), "UserProfileView")
            XCTAssertEqual(Cleaner.clean("kebab case feature flag toggle", bundleID: cursor), "feature-flag-toggle")
            XCTAssertEqual(Cleaner.clean("screaming snake case api base url", bundleID: cursor), "API_BASE_URL")
            XCTAssertEqual(Cleaner.clean("backtick handleTap", bundleID: cursor), "`handleTap`")
            XCTAssertEqual(Cleaner.clean("Update backtick camel case handle tap in the view.", bundleID: cursor),
                           "Update `handleTap` in the view.")
            XCTAssertEqual(Cleaner.clean("Rename camel case user id to camel case account id.", bundleID: cursor),
                           "Rename userId to accountId.")

            // Prose apps leave spoken casing phrases untouched.
            XCTAssertEqual(Cleaner.clean("Use snake case in Python.", bundleID: mail),
                           "Use snake case in Python.")
            XCTAssertEqual(Cleaner.clean("camel case get user id", bundleID: mail),
                           "camel case get user id")
        }
    }

    func testCodeSafeArrowSnippetsAndDynamicPlaceholders() throws {
        // Parse on the FIRST " -> " so Swift/TS arrows inside replacement bodies survive round-trip.
        let drafts = [
            PersonalizationDraft(kind: .snippet, primary: "swift fn", replacement: "func handleTap() -> Bool"),
            PersonalizationDraft(kind: .snippet, primary: "ts fn", replacement: "(input: string) -> Promise<void>"),
            PersonalizationDraft(kind: .snippet, primary: "standup header", replacement: "[{{date}} {{time}}] Clip: {{clipboard}}"),
        ]
        for draft in drafts {
            let snap = try store.snapshot(.snippet)
            _ = try store.add(draft, expected: snap.fingerprint)
        }

        let reloaded = PersonalizationStore(root: root)
        let snippets = try reloaded.snapshot(.snippet).entries
        XCTAssertEqual(snippets.first(where: { $0.primary == "swift fn" })?.replacement,
                       "func handleTap() -> Bool")
        XCTAssertEqual(snippets.first(where: { $0.primary == "ts fn" })?.replacement,
                       "(input: string) -> Promise<void>")

        let gmt = TimeZone(secondsFromGMT: 0)!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = gmt
        let fixedDate = utc.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 14, minute: 35))!
        let env = Cleaner.SnippetEnvironment(
            now: { fixedDate },
            timeZone: gmt,
            clipboard: { "PR #42" }
        )

        Cleaner.withPersonalizationStore(reloaded) {
            Cleaner.withSnippetEnvironment(env) {
                XCTAssertEqual(Cleaner.clean("swift fn."), "func handleTap() -> Bool")
                XCTAssertEqual(Cleaner.clean("ts fn."), "(input: string) -> Promise<void>")
                XCTAssertEqual(Cleaner.clean("standup header."), "[2026-11-13 14:35] Clip: PR #42")
            }
        }
    }
}
