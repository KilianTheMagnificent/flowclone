// Hands-free UI testing for agents: `tools/handsfree-flowclone.sh` starts the debug app
// through `tools/handsfree.mjs` (vendored with `Handsfree.swift` from _AI/Tools/handsfree).
// Unrelated to FlowClone's own hands-free *dictation* (the latched hotkey session).
// In a session no window reaches the screen and the process never activates; the hotkey
// tap, microphone, AX on other apps, synthetic Cmd+V, notifications, sounds, login item,
// updater and model downloads are refused where they start (grep `handsfreeSession`).
import AVFoundation
import Cocoa
import FluidAudio

#if DEBUG
/// True inside an agent's hands-free session. Readable from any thread, unlike the
/// main-actor `Handsfree.enabled`.
let handsfreeSession = ProcessInfo.processInfo.environment["HANDSFREE"] == "1"
    && ProcessInfo.processInfo.environment["HANDSFREE_PROFILE"] != nil

/// True when loaded inside `xctest` / `swift test`. Test processes are not signed as the
/// installed app, so reading the owner's login Keychain items or invoking host permission
/// APIs from unit tests would pop macOS password / privacy dialogs on screen.
let runningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    || ProcessInfo.processInfo.processName == "xctest"
    || ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
    || NSClassFromString("XCTestCase") != nil

/// True whenever this process is an automated test harness (hands-free UI session or unit
/// tests) that must never touch the owner's login Keychain, status bar, or system permission
/// dialogs.
let suppressHostAccess = handsfreeSession || runningUnitTests
#else
let handsfreeSession = false
let runningUnitTests = false
let suppressHostAccess = false
#endif

#if DEBUG
@MainActor
enum HandsfreeLaunch {
    /// First thing in `FlowCloneApplication.run()`, before any window, store or preference.
    static func install() {
        guard Handsfree.enabled, let session = Handsfree.session else { return }
        // The log, History, Dictionary, Draft, Prompter cache and speech model all derive from
        // the home folder, which the driver moves into the session with CFFIXED_USER_HOME.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard home.hasPrefix(session.resolvingSymlinksInPath().path + "/") else {
            Handsfree.log("refusing to start: home \(home) is outside the session; use tools/handsfree-flowclone.sh")
            exit(2)
        }
        Handsfree.install()   // also silences NSSound: start/processing cues, History playback
        adaptAccessibility()
    }

    /// Session-only adjustments for the kit's in-process driver.
    private static func adaptAccessibility() {
        // The kit bridges accessibility titles to String, but SwiftUI `Menu` buttons (History
        // rows, Settings pickers) answer with an attributed string, from NSCell or from SwiftUI's
        // own node: the tree walk then raises and the session stops answering. Hand it plain text.
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        for cls in [NSCell.self, NSClassFromString("SwiftUI.AccessibilityNode")].compactMap({ $0 }) {
            for name in ["accessibilityTitle", "accessibilityLabel"] {
                let selector = NSSelectorFromString(name)
                guard let method = class_getInstanceMethod(cls, selector) else { continue }
                let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
                let plain: @convention(block) (AnyObject) -> AnyObject? = { element in
                    let value = original(element, selector)
                    if let attributed = value as? NSAttributedString { return attributed.string as NSString }
                    return value
                }
                class_replaceMethod(cls, selector, imp_implementationWithBlock(plain), method_getTypeEncoding(method))
            }
        }
        // Pressing a pop-up or menu button would start menu tracking, which holds the main thread
        // (the kit keeps the menu window off screen). The kit presses controls with performClick: and cells
        // with accessibilityPerformPress, and every pop-up click funnels through the cell's
        // performClickWithFrame:inView:; all of them only log here.
        let refuseClick: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in Handsfree.log("blocked pop-up menu") }
        replaceMethod(NSPopUpButton.self, "performClick:", refuseClick)
        let refuseFrame: @convention(block) (AnyObject, NSRect, AnyObject?) -> Void = { _, _, _ in Handsfree.log("blocked pop-up menu") }
        replaceMethod(NSPopUpButtonCell.self, "performClickWithFrame:inView:", refuseFrame)
        let refusePress: @convention(block) (AnyObject) -> Bool = { _ in Handsfree.log("blocked pop-up menu"); return false }
        replaceMethod(NSPopUpButtonCell.self, "accessibilityPerformPress", refusePress)
        // SwiftUI pickers present their menu through a private bridge and track it on the main
        // thread until input arrives, which never does here (the kit keeps the menu window off
        // screen). Their accessibility press is refused; every other SwiftUI press goes through.
        let press = NSSelectorFromString("accessibilityPerformPress")
        if let node = NSClassFromString("SwiftUI.AccessibilityNode"), let method = class_getInstanceMethod(node, press) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Press.self)
            let guarded: @convention(block) (AnyObject) -> Bool = { element in
                let role: NSAccessibility.Role? = element.accessibilityRole?() ?? nil
                guard role != .popUpButton, role != .menuButton else { Handsfree.log("blocked pop-up menu"); return false }
                return original(element, press)
            }
            method_setImplementation(method, imp_implementationWithBlock(guarded))
        }
    }

    /// Replaces the method on `cls` only (an inherited one gains an override there).
    private static func replaceMethod(_ cls: AnyClass, _ name: String, _ block: Any) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// End of `applicationDidFinishLaunching`, once the normal launch has built every surface.
    static func start(pipeline: Pipeline) {
        guard Handsfree.enabled else { return }
        // Settings re-arms the hotkey every refresh; the tap is refused here anyway.
        Permissions.onHotkeyRearm = {}
        for window in NSApp.windows {
            if window.title.isEmpty, "\(type(of: window))" == "Pill" { window.title = "Recording pill" }
            // Pressing the (hidden) status item would pop its menu up on the owner's screen.
            if "\(type(of: window))".contains("StatusBarWindow") { disableControls(in: window.contentView) }
        }
        registerActions(pipeline: pipeline)
        let seeded = AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: SpeechEngine.parakeetModelVersion))
        log("handsfree session ready — speech model \(seeded ? "seeded" : "not seeded (UI only)")")
        Handsfree.start()
    }

    private static func registerActions(pipeline: Pipeline) {
        Handsfree.actions["meeting-mock"] = { payload in
            guard let paths = payload["audio"] as? [String], let output = payload["output"] as? String else {
                throw failure("meeting-mock needs audio paths and an output directory")
            }
            try MeetingMock.start(files: paths.map { URL(fileURLWithPath: $0) }, output: URL(fileURLWithPath: output))
            MainWindow.shared.show(.meetings)
            return MeetingMock.result
        }
        Handsfree.actions["meeting-result"] = { _ in MeetingMock.result }
        Handsfree.actions["meeting-calendar-disconnected"] = { _ in
            guard let profile = Handsfree.profile else { throw failure("test profile unavailable") }
            MeetingMock.showDisconnectedCalendar(in: profile.appendingPathComponent("meeting-disconnected"))
            return "Mock Google Calendar disconnection"
        }
        Handsfree.actions["meeting-github-demo"] = { _ in
            guard let profile = Handsfree.profile else { throw failure("test profile unavailable") }
            try MeetingMock.showGitHubDemo(in: profile.appendingPathComponent("meeting-github-demo"))
            MainWindow.shared.show(.meetings)
            return "Mock GitHub meeting demo"
        }

        Handsfree.actions["page"] = { payload in
            guard let page = (payload["name"] as? String).flatMap(MainWindow.Page.init(rawValue:)) else {
                throw failure("page needs {\"name\": \(MainWindow.Page.allCases.map(\.rawValue).joined(separator: "|"))}")
            }
            MainWindow.shared.show(page)
            return page.rawValue
        }
        // Dictation from a fixture recording instead of the microphone, delivered to Draft.
        Handsfree.actions["dictate"] = { payload in
            guard let path = payload["audio"] as? String else {
                throw failure("dictate needs {\"audio\": \"<wav|aiff|m4a path>\"}, e.g. spikes/say8.wav")
            }
            guard DictationWorkspace.shared.modelReady else {
                throw failure("speech model not ready: start with --with-model, then wait for 'ASR ready' in logs")
            }
            let url = URL(fileURLWithPath: path)
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate > 0,
                  Double(file.length) / file.processingFormat.sampleRate <= 300 else { throw failure("audio over 300 s") }
            let samples = try AudioConverter().resampleAudioFile(url)
            pipeline.handsfreeDictate(samples)
            return ["sink": "draft", "seconds": Double(samples.count) / Recorder.sampleRate] as [String: Any]
        }
        // The recording pill in any phase; shoot it with `--target "Recording pill"`.
        Handsfree.actions["pill"] = { payload in
            let phase = payload["phase"] as? String ?? ""
            let overlay = Overlay.shared
            switch phase {
            case "recording": overlay.recording()
            case "warming": overlay.warming()
            case "transcribing": overlay.transcribing()
            case "polishing": overlay.polishing()
            case "failure": overlay.failure()
            case "ready": overlay.ready()
            case "idle", "hide": overlay.hide()
            default: throw failure("pill needs {\"phase\": recording|warming|transcribing|polishing|failure|ready|idle, \"level\": 0-1}")
            }
            // The live meter skips a panel that is off screen; feed the view as --voice-render does.
            if let level = payload["level"] as? Double, let view = pillView() {
                for _ in 0..<45 { view.push(Float(level)); view.tick(deltaTime: 1.0 / 60) }
            }
            return phase
        }
        // The status menu without opening it: list items, or fire one by title.
        Handsfree.actions["menu"] = { payload in
            guard let menu = Mirror(reflecting: StatusMenu.shared).descendant("menu") as? NSMenu else {
                throw failure("status menu not found")
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let title = payload["press"] as? String else { return describe(menu).components(separatedBy: "\n") }
            guard let (owner, index) = find(title, in: menu) else { throw failure("no status menu item \(title)") }
            guard owner.items[index].isEnabled else { throw failure("\(title) is disabled") }
            owner.performActionForItem(at: index)
            return "pressed \(owner.items[index].title)"
        }
        // The Transform preview with synthetic text: no app is captured and Apply stays off.
        Handsfree.actions["transform"] = { payload in
            TransformController.shared.showDesignPreview(
                original: payload["original"] as? String ?? "please send the revised proposal by friday",
                result: payload["result"] as? String ?? "Please send the revised proposal by Friday.",
                customMode: payload["custom"] as? Bool ?? false)
            return "Transform preview"
        }
        // Lists windows; names untitled app windows (sheets, alerts) so `--target` reaches them.
        Handsfree.actions["windows"] = { _ in
            NSApp.windows.enumerated().map { index, window in
                let kind = "\(type(of: window))"
                if window.title.isEmpty, window.contentView != nil, !kind.contains("StatusBar"), !kind.hasPrefix("TUI") {
                    window.title = "Untitled \(index) \(kind)"
                }
                return "\(window.title) [\(kind)]\(window.isSheet ? " sheet" : "")\(window.isVisible ? " VISIBLE" : "")"
            }
        }
    }

    private static func failure(_ message: String) -> Handsfree.Failure { Handsfree.Failure(description: message) }

    private static func pillView() -> PillView? {
        func search(_ view: NSView?) -> PillView? {
            guard let view else { return nil }
            if let pill = view as? PillView { return pill }
            return view.subviews.lazy.compactMap(search).first
        }
        return NSApp.windows.lazy.compactMap { $0.title == "Recording pill" ? search($0.contentView) : nil }.first
    }

    private static func disableControls(in view: NSView?) {
        guard let view else { return }
        (view as? NSControl)?.isEnabled = false
        view.subviews.forEach(disableControls)
    }

    private static func find(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let submenu = item.submenu, let found = find(title, in: submenu) { return found }
        }
        return nil
    }

    private static func describe(_ menu: NSMenu, depth: Int = 0) -> String {
        menu.items.filter { !$0.isHidden }.map { item in
            let line = String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "---"
                : item.title + (item.isEnabled ? "" : " [disabled]") + (item.state == .on ? " [on]" : ""))
            return item.submenu.map { line + "\n" + describe($0, depth: depth + 1) } ?? line
        }.joined(separator: "\n")
    }
}
#endif
