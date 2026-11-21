// The main window: a SwiftUI sidebar + page shell hosted in one AppKit window. This is the
// only SwiftUI in the app; the overlay, status menu, and pipeline stay AppKit. Main thread
// only. It never touches pipeline internals: pages go through History, Mode, the stores,
// and the same closures the status menu uses.
import Cocoa
import SwiftUI

@MainActor
final class MainWindow {
    static let shared = MainWindow()

    enum Page: String, CaseIterable, Identifiable, Hashable {
        case dictation, draft, meetings, dictionary, snippets, transforms, settings, help
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .draft: return "Draft"
            case .meetings: return "Meetings"
            case .dictionary: return "Dictionary"
            case .snippets: return "Snippets"
            case .transforms: return "Transforms"
            case .settings: return "Settings"
            case .help: return "Help"
            }
        }

        var icon: String {
            switch self {
            case .dictation: return "mic"
            case .draft: return "square.and.pencil"
            case .meetings: return "text.bubble"
            case .dictionary: return "book.closed"
            case .snippets: return "scissors"
            case .transforms: return "wand.and.stars"
            case .settings: return "gearshape"
            case .help: return "questionmark.circle"
            }
        }

        static let main: [Page] = [.dictation, .draft, .meetings, .dictionary, .snippets, .transforms]
        static let bottom: [Page] = [.settings, .help]
    }

    let model: MainModel
    private var window: NSWindow?
    private var mainMenuInstalled = false

    private init() { model = MainModel(isOnScreen: { MainWindow.shared.isOnScreen }) }

    /// A hands-free test session never puts the window on screen; there, once built, it counts as shown.
    var isVisible: Bool { window.map { $0.isVisible || handsfreeSession } ?? false }
    /// False while closed, minimized, on another Space, or fully covered.
    var isOnScreen: Bool { handsfreeSession ? isVisible : window?.occlusionState.contains(.visible) ?? false }

    func show(_ page: Page? = nil) {
        if window == nil { build() }
        if let page { model.page = page }
        // The Dock icon returns with the window; the policy must be regular before activation
        // or the menu bar keeps showing the previous app.
        setDockIcon(visible: true)
        NSApp.activate(ignoringOtherApps: true)
        // Both Dock clicks and menu actions restore a minimized window, retaining its page.
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        model.refreshIfStale()
    }

    private func build() {
        installMainMenuIfNeeded()
        let host = NSHostingController(rootView: MainView(model: model))
        // Otherwise the hosting controller's `preferredContentSize` shrinks the window to
        // SwiftUI's ideal size the first time it lays out.
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = ProcessInfo.processInfo.arguments.contains("--theme-preview") ? "FlowClone — Theme Preview" : "FlowClone"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 960, height: 620)
        w.setContentSize(NSSize(width: 1120, height: 760))
        w.center()
        w.setFrameAutosaveName("FlowClone.MainWindow")
        w.setFrameUsingName("FlowClone.MainWindow")
        window = w
        // Deferred history changes render once the window is back on screen: reopened,
        // deminiaturized, its Space activated, or uncovered.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshIfStale() }
        }
        // Closing the window leaves dictation, the menu bar item and the pill running, and
        // takes the Dock icon away. A minimized window keeps it: the Dock is how it returns.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.updateDockPresence()
                Updater.windowDidClose()
            }
        }
    }

    /// FlowClone is a Dock app only while its window is open or minimized. Called after the
    /// window closes and once at launch, when a login or background launch shows no window.
    nonisolated static func desiredActivationPolicy(windowVisible: Bool, windowMiniaturized: Bool) -> NSApplication.ActivationPolicy {
        (windowVisible || windowMiniaturized) ? .regular : .accessory
    }

    func updateDockPresence() {
        let visible = window.map { $0.isVisible || $0.isMiniaturized } ?? false
        setDockIcon(visible: visible)
    }

    private func setDockIcon(visible: Bool) {
        let policy = Self.desiredActivationPolicy(windowVisible: visible, windowMiniaturized: false)
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        log("dock icon \(visible ? "shown" : "hidden") — dictation keeps running")
        // An accessory app that stays active would keep keyboard focus with no window, and
        // the next dictation would target FlowClone itself. Hand focus back.
        if !visible, NSApp.isActive { NSApp.deactivate() }
    }

    /// Install the standard app menus even when a login launch has no visible window.
    /// Editing commands follow the first responder. Installed once.
    func installMainMenuIfNeeded() {
        // A regular app may already have AppKit's empty placeholder menu at launch.
        guard !mainMenuInstalled else { return }
        mainMenuInstalled = true
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = mods
            return entry
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }
        // ⌘Q goes through us, not straight to `terminate:`, so the quit is logged and the
        // log flushed the same way the status menu's Quit does it.
        let quit = item("Quit FlowClone", #selector(quitFromMenu), "q")
        quit.target = self
        let settings = item("Settings…", #selector(showSettings), ",")
        settings.target = self
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        let appMenu = submenu("FlowClone", [
            item("About FlowClone", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            NSMenuItem.separator(), settings, NSMenuItem.separator(), servicesItem,
            NSMenuItem.separator(),
            item("Hide FlowClone", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            NSMenuItem.separator(), quit])
        let editMenu = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            NSMenuItem.separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a")])
        let viewMenu = submenu("View", [
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s",
                 [.command, .control])])
        let show = item("Show FlowClone", #selector(showFromMenu), "0")
        show.target = self
        let windowMenu = submenu("Window", [
            show, NSMenuItem.separator(),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w")])
        let root = NSMenu()
        [appMenu, editMenu, viewMenu, windowMenu].forEach { root.addItem($0) }
        NSApp.mainMenu = root
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.servicesMenu = services
    }

    @objc private func showSettings() { show(.settings) }
    @objc private func showFromMenu() { show() }

    @objc private func quitFromMenu() {
        AppTermination.requestUserQuit()
    }
}

@MainActor
@Observable
final class MainModel {
    var page: MainWindow.Page = .dictation
    /// Bumped by History so any view that reads it re-renders.
    var historyVersion = 0
    /// A change arrived while the window was off screen; `refreshIfStale()` applies it.
    @ObservationIgnored private var historyStale = false
    @ObservationIgnored private let isOnScreen: @MainActor () -> Bool

    init(isOnScreen: @escaping @MainActor () -> Bool) {
        self.isOnScreen = isOnScreen
        History.onChange = { [weak self] in
            guard let self else { return }
            // An off-screen window is not re-laid out per dictation: that pass cost 100–470 ms
            // of main thread each time and on 2026-09-21 never returned (docs/TODO.md).
            if self.isOnScreen() { self.historyVersion += 1 } else { self.historyStale = true }
        }
    }

    func refreshIfStale() {
        guard historyStale, isOnScreen() else { return }
        historyStale = false
        historyVersion += 1
    }
}

// MARK: - Shell

struct MainView: View {
    @Bindable var model: MainModel

    var body: some View {
        AppShell(model: model) { detail }
        .frame(minWidth: 960, minHeight: 620)
        // The window gives the titlebar's height to the content, but the sidebar's and
        // detail's own backgrounds stop at the safe area — without this the transparent
        // titlebar shows a grey band across the top. The content keeps its inset.
        .background(Theme.window.ignoresSafeArea())
        .font(UIStyle.body)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .controlSize(.regular)
        .themedButtons()
    }

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .dictation: DictationPage(model: model)
        case .draft: DraftPage()
        case .meetings: MeetingsPage()
        case .dictionary: PersonalizationPage(title: "Dictionary", kinds: [.dictionary, .correction])
        case .snippets: PersonalizationPage(title: "Snippets", kinds: [.snippet])
        case .transforms: TransformsPage()
        case .settings: SettingsPage(model: model)
        case .help: HelpPage()
        }
    }
}

// MARK: - Shared page chrome

struct PageHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing
    init(_ title: String) where Trailing == EmptyView {
        self.title = title
        self.trailing = EmptyView()
    }
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }
    var body: some View {
        // The other sans themes name the page in the shell's head band instead.
        if Theme.titlesInPage {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Theme.pageFont).tracking(Theme.usesSystemType ? -0.3 : 0)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if Trailing.self != EmptyView.self {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A titled block raised on the page's surface (Settings, Transforms, Help). Anthropic's flat
/// page drops the box and separates sections with a hairline under the title instead.
struct SectionCard<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        let flat = Theme.flatPanels
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(Theme.sectionFont).accessibilityAddTraits(.isHeader)
                if flat { Hairline() }
            }
            content
        }
        .padding(.horizontal, flat ? 0 : 18)
        .padding(.vertical, flat ? 6 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(flat ? .clear : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(flat ? .clear : Theme.divider))
    }
}

// MARK: - Help

/// Help, organized by task: each block says how, then shows a short example. Paragraphs keep
/// a readable measure; keys are drawn as one keycap style.
struct HelpPage: View {
    private var supportFolder: URL { PersonalizationStore.shared.root }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader("Help")
                SectionCard("Dictate into any app") {
                    prose("Hold fn in any text field, speak, then release.")
                    example("Try", ["Let’s meet tomorrow at ten."])
                    prose("Closing this window keeps FlowClone running in the menu bar.")
                }
                SectionCard("Shortcuts") {
                    VStack(alignment: .leading, spacing: 10) {
                        shortcut(.dictate, "Hold to dictate; release to insert. Double-tap for hands-free.")
                        shortcut(.handsFree, "Toggle hands-free; press your dictation shortcut to finish.")
                        shortcut(keys: ["Esc"], "Cancel hands-free recording without pasting.")
                    }
                    prose("Customize shortcuts in Settings → Keyboard shortcuts.")
                }
                SectionCard("Enter exact text") {
                    prose("Literal text inserts raw speech without cleanup or snippets. Spelling converts letter names into exact identifiers.")
                    example("Spell", ["capital alpha bravo underscore one dot charlie"], result: "Ab_1.c")
                    prose("Say uppercase or lowercase for letter runs, and space, dash, slash, colon, or at for symbols.")
                }
                SectionCard("Type agent commands") {
                    prose("Say “slash” before a command name to insert a slash command.")
                    example("Say", ["slash code review high"], result: "/code-review high")
                }
                SectionCard("Edit selected text") {
                    prose("Select text in any app and trigger Speak an edit to selection.")
                    example("Try", ["uppercase", "snake case", "replace selection with hello"])
                }
                SectionCard("Fix or undo the last dictation") {
                    prose("Edit last dictation and Undo last dictation work while the original field and text still match.")
                }
                SectionCard("Modes") {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(mode.label).fontWeight(.medium).frame(width: 64, alignment: .leading)
                            Text(mode.explanation).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .proseWidth()
                    }
                }
                SectionCard("Troubleshooting") {
                    problem("No recording?", "Check Permissions in Settings, then relaunch after granting access.")
                    problem("Text did not paste?", "Choose Paste last dictation from the menu bar, or Retry if audio was saved.")
                    problem("Check or exclamation mark on the pill?", "A check means ready: release and press again. An exclamation mark means recording could not start.")
                }
                DisclosureGroup("Files & logs") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(supportFolder.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") {
                                try? PrivateFile.ensureDirectory(supportFolder)
                                NSWorkspace.shared.activateFileViewerSelecting([supportFolder])
                            }
                            Button("Open log") { flushLog(); NSWorkspace.shared.open(logURL) }
                        }
                    }.padding(.top, 12)
                }
            }.pageColumn()
        }
    }
    private func prose(_ text: String) -> some View {
        Text(text).lineSpacing(2).fixedSize(horizontal: false, vertical: true).proseWidth()
    }
    /// Spoken examples in the writing face, behind a small muted label.
    private func example(_ label: String, _ phrases: [String], result: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(phrases.map { "“\($0)”" }.joined(separator: "   ")).font(Theme.writingFont)
                    .fixedSize(horizontal: false, vertical: true)
                if let result {
                    HStack(spacing: 6) {
                        Text("→").foregroundStyle(Theme.muted)
                        Text(result).font(.system(size: 13, design: .monospaced))
                    }
                }
            }
        }
        .proseWidth()
        .accessibilityElement(children: .combine)
    }
    private func problem(_ question: String, _ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question).fontWeight(.medium)
            Text(answer).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .proseWidth()
    }
    private func shortcut(_ action: FlowAction, _ what: String) -> some View {
        shortcut(keys: ShortcutStore.shared.bindings.filter { $0.action == action }.map(\.title), what)
    }
    private func shortcut(keys: [String], _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 6) {
                if keys.isEmpty { Text("Not assigned").foregroundStyle(Theme.muted) }
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 { Text("or").font(UIStyle.caption).foregroundStyle(Theme.muted) }
                    keycap(key)
                }
            }
            .frame(width: 150, alignment: .leading)
            Text(what).fixedSize(horizontal: false, vertical: true)
        }
        .proseWidth()
        .accessibilityElement(children: .combine)
    }
    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 22)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.fieldStroke.opacity(0.5)))
    }
}
