#if DEBUG
import Cocoa
import SwiftUI

/// A separate preview process: no hotkeys, recorder, updater, or launch-at-login changes.
/// Theme preferences use a dedicated suite; the installed app is not restarted.
@MainActor
enum ThemePreviewLaunch {
    static func run() {
        if let value=launchArgValue("--theme"),let choice=AppTheme(rawValue:value) {
            AppearanceStore.shared.select(choice)
        }
        if ProcessInfo.processInfo.arguments.contains("--theme-dark") { NSApp.appearance=NSAppearance(named:.darkAqua) }
        if ProcessInfo.processInfo.arguments.contains("--theme-light") { NSApp.appearance=NSAppearance(named:.aqua) }
        if ProcessInfo.processInfo.arguments.contains("--pilltest") {
            let failures = Overlay.shared.pillSelfCheck()
            flushLog()
            print("PILLPREVIEW \(failures == 0 ? "PASS" : "FAIL") (\(failures) failures)")
            exit(failures == 0 ? 0 : 1)
        }
        if let destination = launchArgValue("--voice-render") {
            do { try renderAudioComparison(to: URL(fileURLWithPath: destination, isDirectory: true)) }
            catch { print("VOICERENDER FAIL \(error)"); exit(1) }
            print("VOICERENDER PASS")
            exit(0)
        }
        if let destination = launchArgValue("--review-render") {
            Task { @MainActor in
                do { try await reviewRender(to: URL(fileURLWithPath: destination, isDirectory: true)) }
                catch { print("REVIEWRENDER FAIL \(error)"); exit(1) }
                print("REVIEWRENDER PASS"); exit(0)
            }
            return
        }
        if let destination = launchArgValue("--theme-render") {
            Task { @MainActor in
                do { try await render(to: URL(fileURLWithPath: destination, isDirectory: true)) }
                catch { print("THEMERENDER FAIL \(error)"); exit(1) }
                print("THEMERENDER PASS")
                exit(0)
            }
            return
        }
        if let destination = launchArgValue("--usability-render") {
            Task { @MainActor in
                do { try await renderUsability(to: URL(fileURLWithPath: destination, isDirectory: true)) }
                catch { print("USABILITYRENDER FAIL \(error)"); exit(1) }
                print("USABILITYRENDER PASS"); exit(0)
            }
            return
        }
        if let source = launchArgValue("--history-probe") {
            // Regression probe for the 2026-09-21 freeze: show the Dictations page on a COPY of
            // a history file, insert a row, and check the page re-renders exactly when the
            // window is on screen. `--history-probe-state close|mini` inserts into a closed or
            // minimized window and then reopens it, which must apply the deferred render.
            // A layout that never converges never prints PASS; the caller times out.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("flowclone-history-probe-\(UUID().uuidString).jsonl")
            do { try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: scratch) }
            catch { print("HISTORYPROBE FAIL copy: \(error)"); exit(1) }
            History.storeURL = scratch
            let state = launchArgValue("--history-probe-state") ?? "visible"
            let model = MainWindow.shared.model
            let before = History.items.count
            MainWindow.shared.show(.dictation)
            let window = NSApp.windows.first { $0.title.hasPrefix("FlowClone") }
            window?.orderFrontRegardless()
            Task { @MainActor in
                var failures: [String] = []
                func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
                try? await Task.sleep(for: .milliseconds(800))
                if state == "close" { window?.performClose(nil) } else if state == "mini" { window?.miniaturize(nil) }
                try? await Task.sleep(for: .milliseconds(700))
                let onScreen = MainWindow.shared.isOnScreen
                let version = model.historyVersion
                check(state == "visible" || !onScreen, "\(state) window still counts as on screen")
                History.add(raw: "probe row", final: "Probe row inserted by --history-probe.", seconds: 2, mode: "polish")
                try? await Task.sleep(for: .milliseconds(1500))
                let rendered = model.historyVersion != version
                check(History.items.count == before + 1, "row not added")
                check(rendered == onScreen, "insert rendered=\(rendered) while onScreen=\(onScreen)")
                print("HISTORYPROBE insert state=\(state) onScreen=\(onScreen) rendered=\(rendered)")
                MainWindow.shared.show(.dictation)
                window?.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(1500))
                let back = MainWindow.shared.isOnScreen
                let refreshed = model.historyVersion != version
                // Occlusion is the window server's call (another Space, a covering window), so
                // only a window that reads as on screen must have refreshed.
                check(!back || refreshed, "reopen refreshed=\(refreshed) while onScreen=\(back)")
                print("HISTORYPROBE reopen onScreen=\(back) refreshed=\(refreshed) visible=\(window?.isVisible ?? false) activeSpace=\(window?.isOnActiveSpace ?? false) appActive=\(NSApp.isActive)")
                try? FileManager.default.removeItem(at: scratch)
                print("HISTORYPROBE \(failures.isEmpty ? "PASS" : "FAIL " + failures.joined(separator: "; "))")
                flushLog(); exit(failures.isEmpty ? 0 : 1)
            }
            return
        }
        let page=launchArgValue("--theme-page").flatMap(MainWindow.Page.init(rawValue:)) ?? .settings
        MainWindow.shared.show(page)
        if ProcessInfo.processInfo.arguments.contains("--pill-preview") { Overlay.shared.hide() }
    }

    /// Visual review (tools/review-render.sh): every page, dialog and both appearances per
    /// theme, on synthetic history, vocabulary and presets. Run it only under a throwaway
    /// CFFIXED_USER_HOME: History and the personalization store live in the home folder.
    /// `--review-themes a,b` and `--review-pages dictation,settings` narrow the set.
    private static func reviewRender(to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let samples: [(String, String, String, DeliveryState, Double, Double)] = [
            ("can you move the design review to thursday afternoon and send the agenda beforehand",
             "Can you move the design review to Thursday afternoon and send the agenda beforehand?", "com.apple.mail", .confirmed, 6.1, 0.2),
            ("quick update the onboarding copy is ready for review i left comments on the pricing section",
             "Quick update: the onboarding copy is ready for review. I left comments on the pricing section.", "com.tinyspeck.slackmacgap", .confirmed, 7.4, 0.5),
            ("refactor the parser so it streams tokens instead of buffering the whole file",
             "Refactor the parser so it streams tokens instead of buffering the whole file.", "com.microsoft.VSCode", .unverified, 5.2, 3),
            ("remind me to renew the passport next month", "Remind me to renew the passport next month.", "com.apple.Notes", .notInserted, 2.8, 26),
            ("summarize the three risks we discussed and propose one mitigation for each",
             "Summarize the three risks we discussed and propose one mitigation for each.", "com.google.Chrome", .draft, 5.9, 30),
            ("lunch at noon works for me", "Lunch at noon works for me.", "com.apple.MobileSMS", .confirmed, 1.9, 50),
        ]
        if History.items.isEmpty {
            for (raw, final, app, delivery, seconds, hoursAgo) in samples.reversed() {
                History.add(raw: raw, final: final, seconds: seconds, mode: "clean",
                            date: now.addingTimeInterval(-hoursAgo * 3600), cleaned: final,
                            effectiveMode: "clean", input: "normal", model: SpeechEngine.parakeet.historyLabel,
                            targetApp: app, delivery: delivery)
            }
        }
        DictationWorkspace.shared.draft = "Agenda for Thursday\n\n1. Review the onboarding copy\n2. Decide on pricing tiers\n3. Assign owners for launch tasks"
        DictationWorkspace.shared.modelReady = true
        if UserDefaults.standard.integer(forKey: "totalWordsTranscribed") == 0 {
            UserDefaults.standard.set(1_240, forKey: "totalWordsTranscribed")
        }
        if UserDefaults.standard.double(forKey: "totalSecondsTranscribed") == 0 {
            UserDefaults.standard.set(510.0, forKey: "totalSecondsTranscribed")
        }
        if TransformPresets.loadNamed().isEmpty {
            TransformPresets.saveNamed([TransformPreset(name: "Friendly reply", instruction: "Rewrite as a warm, concise reply."),
                                        TransformPreset(name: "Bullet summary", instruction: "Summarize as three short bullets.")])
        }
        let themeFilter = launchArgValue("--review-themes").map { Set($0.split(separator: ",").map(String.init)) }
        let pageFilter = launchArgValue("--review-pages").map { Set($0.split(separator: ",").map(String.init)) }
        let item = History.items.first { $0.delivery == .unverified } ?? History.items[0]
        for theme in AppTheme.allCases where themeFilter?.contains(theme.rawValue) ?? true {
            AppearanceStore.shared.select(theme)
            for dark in [false, true] {
                let tag = "\(theme.rawValue)-\(dark ? "dark" : "light")"
                func wanted(_ name: String) -> Bool { pageFilter?.contains(name) ?? true }
                func page(_ p: MainWindow.Page, _ size: NSSize, _ name: String) async throws {
                    guard wanted(name) else { return }
                    let model = MainModel(isOnScreen: { true })
                    model.page = p
                    try await save(MainView(model: model), size: size, dark: dark,
                                   to: folder.appendingPathComponent("\(tag)-\(name).png"))
                }
                for p in MainWindow.Page.allCases { try await page(p, NSSize(width: 1120, height: 760), p.rawValue) }
                try await page(.settings, NSSize(width: 1120, height: 2000), "settings-tall")
                try await page(.help, NSSize(width: 1120, height: 1500), "help-tall")
                try await page(.dictation, NSSize(width: 960, height: 620), "dictation-min")
                if wanted("dialogs") {
                    try await save(HistoryDetail(item: item), size: NSSize(width: 730, height: 650), dark: dark,
                                   to: folder.appendingPathComponent("\(tag)-dialog-history.png"))
                    try await save(EntryEditor(kind: .snippet, existing: nil, onSave: { _ in }), size: NSSize(width: 560, height: 420),
                                   dark: dark, to: folder.appendingPathComponent("\(tag)-dialog-entry.png"))
                    try await save(PresetEditor(preset: TransformPreset(name: "Friendly reply", instruction: "Rewrite as a warm, concise reply."),
                                                onSave: { _ in }), size: NSSize(width: 560, height: 420), dark: dark,
                                   to: folder.appendingPathComponent("\(tag)-dialog-preset.png"))
                }
            }
        }
    }

    private static func renderUsability(to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "flowclone-usability-preview-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let draft = DictationWorkspace(defaults: defaults, url: folder.appendingPathComponent("unused-draft.json"))
        draft.draft = "Please send the revised proposal by Friday.\n\norder_number_42"
        draft.status = "Insertion could not be confirmed. Check the original app before inserting again."
        draft.retryAvailable = true; draft.modelReady = true
        let item = History.Item(raw: "um send the revised proposal", final: "Send the revised proposal.",
            seconds: 3, words: 5, mode: "polish", cleaned: "send the revised proposal",
            effectiveMode: "clean", input: "normal", model: SpeechEngine.parakeet.historyLabel,
            targetApp: "com.example.editor", delivery: .unverified)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await save(DraftPage(workspace: draft), size: NSSize(width: 730, height: 650), dark: dark,
                           to: folder.appendingPathComponent("draft-\(suffix).png"))
            try await save(VStack(alignment: .leading) { MicrophoneSettings(); ShortcutSettings() }.padding(24),
                           size: NSSize(width: 800, height: 1100), dark: dark,
                           to: folder.appendingPathComponent("input-settings-\(suffix).png"))
            try await save(HistoryDetail(item: item), size: NSSize(width: 730, height: 650), dark: dark,
                           to: folder.appendingPathComponent("history-\(suffix).png"))
            try await save(VocabularyPreflight(selection: nil), size: NSSize(width: 660, height: 520), dark: dark,
                           to: folder.appendingPathComponent("vocabulary-\(suffix).png"))
        }
    }

    /// Feed identical controlled levels to the actual production PillView.
    /// Offscreen rendering only: no recorder, desktop capture, or foreground windows.
    private static func renderAudioComparison(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for theme in AppTheme.allCases {
            AppearanceStore.shared.select(theme)
            for dark in [false, true] {
                let view = PillView(frame: NSRect(origin: .zero, size: theme.activeSize))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.reduceMotion = false
                view.reset()
                for (label, level, ticks) in [("silence", Float(0), 30), ("soft", 0.15, 60), ("normal", 0.5, 60), ("loud", 1, 60), ("release", 0, 90)] {
                    view.push(level)
                    for _ in 0..<ticks { view.tick(deltaTime: 1.0 / 60) }
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    let file = "\(theme.rawValue)-\(dark ? "dark" : "light")-\(label).png"
                    try data.write(to: folder.appendingPathComponent(file))
                    rows.append(["theme": theme.rawValue, "dark": dark, "phase": label, "input": level,
                                 "smoothed": view.smoothedLevel, "gain": view.listeningAudioScale, "heights": view.voiceHeights(for: theme), "file": file])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("audio-response.json"))
    }

    /// Render production components offscreen; never opens windows or captures the desktop.
    private static func render(to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for theme in AppTheme.allCases {
            AppearanceStore.shared.select(theme)
            for dark in [false, true] {
                for width in [960.0, 1120.0] {
                    let model = MainModel(isOnScreen: { true })
                    model.page = .settings
                    let content = MainView(model: model).environment(\.colorScheme, dark ? .dark : .light)
                    try await save(content, size: NSSize(width: width, height: 760), dark: dark,
                                   to: folder.appendingPathComponent("\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
                let marks = VStack(alignment: .leading, spacing: 24) {
                    if theme == .anthropic { ComposerGreeting() } else if theme.serifDisplay { ThemedDictationWelcome() } else if theme.journalHome { JournalWelcome() } else { CompactWelcome() }
                    Hairline()
                    HStack(spacing: 40) {
                        ForEach(0..<4) { index in
                            let phase: IndicatorPreviewPhase = [.speaking, .processing, .ready, .idle][index]
                            VStack(spacing: 14) {
                                NativeIndicatorPreview(phase: phase, level: 0.5, reducedMotion: true)
                                    .frame(width: phase == .idle ? theme.idleSize.width : phase == .processing ? theme.processingSize.width : theme.activeSize.width,
                                           height: phase == .idle ? theme.idleSize.height : theme.activeSize.height)
                                    .frame(height: 42)
                                Text(phase.label).font(.system(size: 12))
                            }
                        }
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(Theme.ink).background(Theme.ground)
                    .environment(\.colorScheme, dark ? .dark : .light)
                try await save(marks, size: NSSize(width: 740, height: 430), dark: dark,
                               to: folder.appendingPathComponent("\(theme.rawValue)-\(dark ? "dark" : "light")-marks.png"))
            }
        }
    }

    private static func save<V: View>(_ content: V, size: NSSize, dark: Bool, to url: URL) async throws {
        let host = NSHostingView(rootView: content
            .font(UIStyle.body).foregroundStyle(Theme.ink).tint(Theme.accent)
            .background(Theme.ground).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        window.contentView = nil
    }

}
#endif
