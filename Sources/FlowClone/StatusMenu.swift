// Status-bar menu (PLAN-PHASE4 F2): a second control surface, so changing mode no longer
// means reopening the main window. Main thread only. It never touches pipeline internals:
// mode goes through Mode.set, everything else through closures the app delegate wires, and
// every item re-reads its state in menuNeedsUpdate so neither surface can go stale.
import Cocoa

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    private static var testImmediateActions = false
    private static let normalSymbol = "waveform"
    private static let learnedSymbol = "checkmark.circle.fill"

    /// Wired by the app delegate.
    var sessionActive: () -> Bool = { false }
    var handsFreeActive: () -> Bool = { false }
    var retryAvailable: () -> Bool = { false }
    var modelRetryAvailable: () -> Bool = { false }
    var learnedUndoAvailable: () -> Bool = { false }
    var transformUndoAvailable: () -> Bool = { false }
    var onToggleHandsFree: () -> Void = {}
    var onRepaste: (String) -> Void = { _ in }
    var onRetry: () -> Void = {}
    var onRetryModel: () -> Void = {}
    var onUndoLearned: () -> Void = {}
    var onTransform: () -> Void = {}
    var onUndoTransform: () -> Void = {}

    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var learnedSignalGeneration = 0
    private var meetingTitle: String?
    private var meetingPending = false
    private var meetingAttention: MeetingAttention?
    private lazy var meetingNotesItem = item("Meeting notes…", #selector(openMeetings))
    private lazy var startInPersonMeetingItem = item("Start In-Person Meeting", #selector(startInPersonMeeting))
    private lazy var startNewMeetingItem = item("Start New Meeting Note", #selector(startNewMeeting))
    private lazy var skipMeetingItem = item("Skip upcoming recording", #selector(skipMeeting))
    private lazy var stopMeetingItem = item("Stop meeting and summarize", #selector(stopMeeting))
    private var modeItems: [NSMenuItem] = []
    private lazy var handsFreeItem = item("Start hands-free", #selector(toggleHandsFree))
    private lazy var repasteItem = item("Paste last dictation", #selector(pasteLast))
    private lazy var retryItem = item("Retry failed recording", #selector(retryRecording))
    private lazy var retryModelItem = item("Retry speech model", #selector(retryModel))
    private lazy var lastLearnedItem: NSMenuItem = {
        let it = NSMenuItem(title: "Last learned correction", action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.isHidden = true
        return it
    }()
    private lazy var undoLearnedItem = item("Undo last learned correction", #selector(undoLearned))
    private lazy var suggestedCorrectionItem = item("Review suggested corrections…", #selector(reviewCorrection))
    private let outputModeItem = NSMenuItem(title: "Last output", action: nil, keyEquivalent: "")
    private lazy var transformItem = item("Transform selected text…", #selector(transformSelection))
    private lazy var undoTransformItem = item("Undo last transform", #selector(undoTransform))
    private lazy var updateItem = item("Check for updates", #selector(checkForUpdates))
    private let updateStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false   // enablement is computed in refresh(), not guessed
        let modes = NSMenu(title: "Cleanup mode")
        modes.autoenablesItems = false
        for (i, m) in Mode.allCases.enumerated() {
            let entry = item(m.label, #selector(pickMode(_:)))
            entry.tag = i; entry.toolTip = m.explanation
            modes.addItem(entry); modeItems.append(entry)
        }
        let modeMenu = NSMenuItem(title: "Cleanup mode", action: nil, keyEquivalent: "")
        modeMenu.submenu = modes
        menu.addItem(item("Open FlowClone…", #selector(openMain)))
        menu.addItem(meetingNotesItem)
        menu.addItem(startInPersonMeetingItem)
        menu.addItem(startNewMeetingItem)
        menu.addItem(stopMeetingItem)
        menu.addItem(skipMeetingItem)
        menu.addItem(modeMenu)
        let actions = NSMenu(title: "Dictation actions")
        for action in FlowAction.allCases where action != .dictate && action != .handsFree {
            let entry = item(action.title, #selector(performAction(_:)))
            entry.representedObject = action.rawValue
            actions.addItem(entry)
        }
        actions.addItem(item("Finish recording", #selector(finishRecording)))
        actions.addItem(item("Cancel recording", #selector(cancelRecording)))
        actions.addItem(item("Open Draft", #selector(openDraft)))
        let actionsItem = NSMenuItem(title: "Dictation actions", action: nil, keyEquivalent: "")
        actionsItem.submenu = actions
        menu.addItem(actionsItem)
        menu.addItem(.separator())
        menu.addItem(handsFreeItem)
        menu.addItem(repasteItem)
        menu.addItem(keepOnClipboardItem)
        menu.addItem(smartCorrectionsItem)
        menu.addItem(transformItem)
        menu.addItem(undoTransformItem)
        menu.addItem(retryItem)
        menu.addItem(retryModelItem)
        menu.addItem(.separator())
        let corrections = NSMenu(title: "Corrections")
        corrections.autoenablesItems = false
        [lastLearnedItem, undoLearnedItem, suggestedCorrectionItem].forEach { corrections.addItem($0) }
        let correctionsItem = NSMenuItem(title: "Corrections", action: nil, keyEquivalent: "")
        correctionsItem.submenu = corrections
        menu.addItem(correctionsItem)
        let display = NSMenu(title: "Display")
        display.autoenablesItems = false
        [livePartialItem, idlePillItem].forEach { display.addItem($0) }
        outputModeItem.isEnabled = false; outputModeItem.isHidden = true
        display.addItem(outputModeItem)
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayItem.submenu = display
        menu.addItem(displayItem)
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        let updates = NSMenu(title: "Updates")
        updates.autoenablesItems = false
        updates.addItem(updateItem)
        updateStatusItem.isEnabled = false
        updates.addItem(updateStatusItem)
        let updatesItem = NSMenuItem(title: "Updates", action: nil, keyEquivalent: "")
        updatesItem.submenu = updates
        menu.addItem(updatesItem)
        menu.addItem(item("Quit FlowClone", #selector(quit)))
        refresh()
    }

    /// Puts the item in the menu bar. Idempotent — `--menutest` calls it too.
    func install() {
        guard statusItem == nil else { return }
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        s.menu = menu
        statusItem = s
        restoreStatusSymbol()
    }

    /// Signal a durable correction without replacing the recording overlay. The menu row
    /// remains inspectable after the brief checkmark, alongside Undo.
    func showLearnedCorrection(_ summary: String) {
        lastLearnedItem.title = Self.learnedRowTitle(summary)
        lastLearnedItem.toolTip = "FlowClone learned correction: \(summary)"
        lastLearnedItem.isHidden = false

        learnedSignalGeneration += 1
        let generation = learnedSignalGeneration
        setStatusSymbol(Self.learnedSymbol,
                        description: "FlowClone learned a correction",
                        tint: .systemGreen,
                        toolTip: "Learned correction: \(summary)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, generation == self.learnedSignalGeneration else { return }
            self.restoreStatusSymbol()
        }
    }

    /// Successful undo means the persisted mapping no longer exists. Remove the durable
    /// row immediately so the menu never claims an undone correction is still learned.
    func clearLearnedCorrection() {
        learnedSignalGeneration += 1
        lastLearnedItem.isHidden = true
        lastLearnedItem.toolTip = nil
        restoreStatusSymbol()
    }

    func showOutputMode(_ effective: String, requested: String) {
        let detail = effective == requested ? "" : " (\(requested.capitalized) fallback)"
        outputModeItem.title = "Last output: \(effective.capitalized)\(detail)"
        outputModeItem.isHidden = false
    }

    /// Keep a pathological multi-correction batch from making the menu wider than the
    /// screen. The full text remains in the item's tooltip and the system notification.
    nonisolated static func learnedRowTitle(_ summary: String) -> String {
        let limit = 88
        let compact = summary.count <= limit ? summary : String(summary.prefix(limit - 1)) + "…"
        return "Last learned: \(compact)"
    }

    func meetingStatus(_ title: String?, pending: Bool = false) {
        meetingTitle = title
        meetingPending = pending
        restoreStatusSymbol()
    }

    /// Automatic recording is on but cannot work until the person acts (sign-in expired,
    /// permission missing). nil clears it.
    func meetingAttention(_ issue: MeetingAttention?) {
        meetingAttention = issue
        meetingNotesItem.title = issue?.menuTitle ?? "Meeting notes…"
        meetingNotesItem.toolTip = issue?.message
        restoreStatusSymbol()
    }

    private func restoreStatusSymbol() {
        if meetingTitle == nil, let issue = meetingAttention {
            setStatusSymbol("waveform.badge.exclamationmark", description: "FlowClone, automatic meeting recording paused",
                            tint: .systemOrange, toolTip: issue.message)
            return
        }
        if let title = meetingTitle {
            setStatusSymbol(meetingPending ? "clock.fill" : "record.circle.fill",
                            description: meetingPending ? "Meeting recording starts soon" : "Meeting recording",
                            tint: meetingPending ? .systemOrange : .systemRed,
                            toolTip: "\(meetingPending ? "Starting soon" : "Recording"): \(title). Open Meeting notes to cancel or stop.")
            return
        }
        setStatusSymbol(Self.normalSymbol, description: "FlowClone", tint: nil,
                        toolTip: "FlowClone")
    }

    private func setStatusSymbol(_ name: String, description: String,
                                 tint: NSColor?, toolTip: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: Self.normalSymbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = tint
        statusItem?.button?.toolTip = toolTip
        statusItem?.button?.title = ""       // never widen the status item with text
    }

    /// Live partial text in the pill. A checkbox, not a mode: it changes what the overlay
    /// shows while recording and nothing about what gets pasted.
    private lazy var livePartialItem: NSMenuItem = {
        let it = item("Show live text in pill", #selector(toggleLivePartial))
        it.state = Overlay.livePartialEnabled ? .on : .off
        return it
    }()

    @objc private func toggleLivePartial(_ sender: NSMenuItem) {
        Overlay.livePartialEnabled.toggle()
        sender.state = Overlay.livePartialEnabled ? .on : .off
        log("live partial text = \(Overlay.livePartialEnabled)")
        if !Overlay.livePartialEnabled { Overlay.shared.clearPartial() }
    }

    /// Same setting as Settings → Dictation. A checkbox beside Paste last dictation, so it can
    /// be flipped while FlowClone runs from the menu bar with its window closed.
    private lazy var keepOnClipboardItem: NSMenuItem = {
        let it = item("Keep last dictation on clipboard", #selector(toggleKeepOnClipboard))
        it.state = Paster.keepsLastDictation ? .on : .off
        return it
    }()

    @objc private func toggleKeepOnClipboard(_ sender: NSMenuItem) {
        Paster.keepsLastDictation.toggle()
        sender.state = Paster.keepsLastDictation ? .on : .off
        log("keep dictation on clipboard = \(Paster.keepsLastDictation)")
    }

    /// Same switch as Settings → Dictation → Smart corrections: the model's second look at
    /// sentences that look like a self-correction. Off keeps the rules and drops the wait.
    private lazy var smartCorrectionsItem: NSMenuItem = {
        let it = item("Smart corrections", #selector(toggleSmartCorrections))
        it.state = RepairReviewer.enabled ? .on : .off
        it.toolTip = "Fixes punctuation, dictionary sound-alikes, and mid-sentence false starts. Short clean dictations stay instant on your Mac."
        return it
    }()

    @objc private func toggleSmartCorrections(_ sender: NSMenuItem) {
        RepairReviewer.enabled.toggle()
        sender.state = RepairReviewer.enabled ? .on : .off
        log("smart corrections = \(RepairReviewer.setting.rawValue)")
        // --menutest fires this item; it must not open a model session.
        if !Self.testImmediateActions { RepairReviewer.prepare(prewarm: Mode.current == .clean) }
    }

    /// Wispr's idle bar between dictations. Display-only, like the live-text checkbox.
    private lazy var idlePillItem: NSMenuItem = {
        let it = item("Show idle pill", #selector(toggleIdlePill))
        it.state = Overlay.idlePillEnabled ? .on : .off
        return it
    }()

    @objc private func toggleIdlePill(_ sender: NSMenuItem) {
        Overlay.idlePillEnabled.toggle()
        sender.state = Overlay.idlePillEnabled ? .on : .off
        log("idle pill = \(Overlay.idlePillEnabled)")
        Overlay.shared.applyIdleSetting()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    // MARK: - State

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let canStartMeeting = !MeetingCoordinator.shared.busy && !MeetingCoordinator.shared.isImporting
        startInPersonMeetingItem.isEnabled = canStartMeeting
        startNewMeetingItem.isEnabled = canStartMeeting
        stopMeetingItem.isHidden = !MeetingCoordinator.shared.busy
        skipMeetingItem.isHidden = MeetingCoordinator.shared.countdown == nil
        let current = Mode.current
        for (i, it) in modeItems.enumerated() { it.state = Mode.allCases[i] == current ? .on : .off }
        // F1: always available to stop a running hands-free session; otherwise only when
        // nothing else is in flight, matching Pipeline.toggleHandsFree's own guard.
        let handsFree = handsFreeActive()
        handsFreeItem.title = handsFree ? "Stop hands-free" : "Start hands-free"
        handsFreeItem.isEnabled = handsFree || !sessionActive()
        // History is main-thread confined, which is where a menu update already runs.
        repasteItem.isEnabled = !History.items.isEmpty && !sessionActive()
        retryItem.isEnabled = retryAvailable() && !sessionActive()
        retryModelItem.isEnabled = modelRetryAvailable() && !sessionActive()
        undoLearnedItem.isEnabled = learnedUndoAvailable() && !sessionActive()
        suggestedCorrectionItem.isEnabled = !AutoLearn.suggestions.current().isEmpty && !sessionActive()
        transformItem.isEnabled = !sessionActive()
        undoTransformItem.isEnabled = transformUndoAvailable() && !sessionActive()
        retryItem.isHidden = !retryAvailable()
        retryModelItem.isHidden = !modelRetryAvailable()
        undoTransformItem.isHidden = !transformUndoAvailable()
        menu.items.first { $0.submenu?.title == "Cleanup mode" }?.title = "Cleanup mode · \(current.label)"
        livePartialItem.state = Overlay.livePartialEnabled ? .on : .off
        keepOnClipboardItem.state = Paster.keepsLastDictation ? .on : .off
        smartCorrectionsItem.state = RepairReviewer.enabled ? .on : .off
        idlePillItem.state = Overlay.idlePillEnabled ? .on : .off
        updateItem.title = Updater.hasStagedUpdate
            ? "Install update & relaunch"
            : (Updater.isChecking ? "Checking for updates…" : "Check for updates")
        updateItem.isEnabled = !Updater.isBusy
        updateStatusItem.title = Updater.status
    }

    // MARK: - Actions

    @objc private func pickMode(_ sender: NSMenuItem) {
        Mode.set(Mode.allCases[sender.tag])
        refresh()
    }

    @objc private func toggleHandsFree() { onToggleHandsFree() }

    @objc private func pasteLast() {
        guard let last = History.items.first else { return }
        let text = last.final
        afterMenuCloses { self.onRepaste(text) }
    }

    @objc private func retryRecording() { afterMenuCloses { self.onRetry() } }
    @objc private func retryModel() { afterMenuCloses { self.onRetryModel() } }
    @objc private func undoLearned() { afterMenuCloses { self.onUndoLearned() } }
    @objc private func reviewCorrection() { afterMenuCloses { AutoLearn.reviewSuggestion() } }
    @objc private func transformSelection() { afterMenuCloses { self.onTransform() } }
    @objc private func undoTransform() { afterMenuCloses { self.onUndoTransform() } }

    private func afterMenuCloses(_ action: @MainActor @Sendable @escaping () -> Void) {
        if Self.testImmediateActions { action() }
        else { DispatchQueue.main.async(execute: action) }
    }

    @objc private func openMeetings() { MainWindow.shared.show(.meetings) }
    @objc private func startInPersonMeeting() {
        afterMenuCloses {
            MainWindow.shared.show(.meetings)
            Task { @MainActor in
                _ = await MeetingCoordinator.shared.startInPersonMeeting()
            }
        }
    }
    @objc private func startNewMeeting() {
        afterMenuCloses {
            MainWindow.shared.show(.meetings)
            Task { @MainActor in
                _ = await MeetingCoordinator.shared.startAdHocMeeting()
            }
        }
    }
    @objc private func skipMeeting() {
        if let event = MeetingCoordinator.shared.countdown { MeetingCoordinator.shared.dismiss(event) }
    }
    @objc private func stopMeeting() { Task { await MeetingCoordinator.shared.stop() } }
    @objc private func openMain() { MainWindow.shared.show(.dictation) }
    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = FlowAction(rawValue: raw) else { return }
        afterMenuCloses { DictationWorkspace.shared.perform(action) }
    }
    @objc private func finishRecording() { DictationWorkspace.shared.onStop() }
    @objc private func cancelRecording() { DictationWorkspace.shared.onCancel() }
    @objc private func openDraft() { MainWindow.shared.show(.draft) }
    @objc private func openSettings() { MainWindow.shared.show(.settings) }
    @objc private func checkForUpdates() {
        Task { @MainActor in
            if Updater.hasStagedUpdate { await Updater.installNow() }
            else { await Updater.check(userInitiated: true) }
        }
    }

    @objc private func quit() {
        AppTermination.requestUserQuit()
    }

    #if DEBUG
    func designMenu() -> NSMenu { refresh(); return menu }
    #endif

    // MARK: - Self-check

    /// `open -a FlowClone --args --menutest`, then read the log. Drives the real menu and
    /// its real actions with the pipeline closures stubbed, so nothing pastes and no
    /// Foundation Models session is opened.
    static func selfCheck() {
        // prepare() still counts, but never opens a session — for BOTH FM profiles, or
        // firing the Prompt menu item here would prewarm a real Foundation Models session.
        Polisher.testInert = true
        Prompter.testInert = true
        let m = StatusMenu.shared
        m.install()
        let savedMode = UserDefaults.standard.string(forKey: "mode")
        let savedActive = m.sessionActive
        let savedHandsFree = m.handsFreeActive
        let savedRetryAvailable = m.retryAvailable
        let savedModelRetryAvailable = m.modelRetryAvailable
        let savedLearnedUndoAvailable = m.learnedUndoAvailable
        let savedTransformUndoAvailable = m.transformUndoAvailable
        let savedToggle = m.onToggleHandsFree
        let savedRepaste = m.onRepaste
        let savedRetry = m.onRetry
        let savedRetryModel = m.onRetryModel
        let savedUndoLearned = m.onUndoLearned
        let savedTransform = m.onTransform
        let savedUndoTransform = m.onUndoTransform
        var active = false, latched = false, canRetry = false, canRetryModel = false
        var canUndoLearned = false
        var canUndoTransform = false, toggled = false, repasted: String?
        var retried = false, modelRetried = false, learnedUndone = false
        var transformed = false, transformUndone = false
        Self.testImmediateActions = true
        m.sessionActive = { active }
        m.handsFreeActive = { latched }
        m.retryAvailable = { canRetry }
        m.modelRetryAvailable = { canRetryModel }
        m.learnedUndoAvailable = { canUndoLearned }
        m.transformUndoAvailable = { canUndoTransform }
        m.onToggleHandsFree = { toggled = true }
        m.onRepaste = { repasted = $0 }
        m.onRetry = { retried = true }
        m.onRetryModel = { modelRetried = true }
        m.onUndoLearned = { learnedUndone = true }
        m.onTransform = { transformed = true }
        m.onUndoTransform = { transformUndone = true }

        var checks = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            checks += 1
            if !ok { failed += 1; log("MENUTEST FAIL: \(name)") }
        }
        func fire(_ it: NSMenuItem) { _ = NSApp.sendAction(it.action!, to: it.target, from: it) }
        func opened() { m.menuNeedsUpdate(m.menu) }   // what AppKit does before it shows

        check("status item button", m.statusItem?.button != nil)
        check("template symbol image", m.statusItem?.button?.image?.isTemplate == true)
        check("status item stays icon-only", m.statusItem?.button?.title.isEmpty == true)

        let titles = m.menu.items.map(\.title)
        check("frequent commands at top", titles.first == "Open FlowClone…" && titles.contains("Transform selected text…"))
        check("native submenus", m.menu.items.compactMap(\.submenu).map(\.title)
              == ["Cleanup mode", "Dictation actions", "Corrections", "Display", "Updates"])
        let dictationActions = m.menu.items.compactMap(\.submenu).first { $0.title == "Dictation actions" }
        check("dictation actions carry the expected action identifiers",
              dictationActions?.items.compactMap { $0.representedObject as? String }
              == ["draft", "pasteDraft", "copyLast", "editSelection", "editLast", "undoLast",
                  "literal", "spelling", "actions"])
        check("word total stays out of the status menu", !titles.contains { $0.localizedCaseInsensitiveContains("word") })
        func flattened(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { entry in [entry] + (entry.submenu.map(flattened) ?? []) }
        }
        // AppKit gives submenu holders its own submenuAction: selector and target.
        // Only leaf commands route to FlowClone; native holders remain AppKit-owned.
        let actionable = flattened(m.menu).filter { $0.action != nil && $0.submenu == nil }
        check("36 actionable items, got \(actionable.count)", actionable.count == 36)
        for it in actionable {
            check("\(it.title) wired", it.target === m && m.responds(to: it.action))
        }
        let saved = Overlay.livePartialEnabled
        defer { Overlay.livePartialEnabled = saved }
        for want in [true, false] {
            Overlay.livePartialEnabled = want
            let fresh = StatusMenu()
            let it = flattened(fresh.menu).first { $0.title == "Show live text in pill" }
            check("live-text check mark follows the setting (\(want))",
                  it?.state == (want ? .on : .off))
        }
        // The clipboard checkbox reads the shared setting on open and flips it both ways.
        let savedKeep = Paster.keepsLastDictation
        defer { Paster.keepsLastDictation = savedKeep }
        for want in [true, false] {
            Paster.keepsLastDictation = want
            opened()
            check("clipboard check mark follows the setting (\(want))",
                  m.keepOnClipboardItem.state == (want ? .on : .off))
            fire(m.keepOnClipboardItem)
            check("clipboard item toggles the setting (\(want) → \(!want))",
                  Paster.keepsLastDictation == !want && m.keepOnClipboardItem.state == (want ? .off : .on))
        }
        // Smart corrections: the check mark follows the setting, the item flips it, and
        // turning it back on restores the model choice. Written through UserDefaults so the
        // item's action is the only thing that runs RepairReviewer.prepare here.
        let savedReview = UserDefaults.standard.string(forKey: RepairReviewer.settingKey)
        let savedChoice = UserDefaults.standard.string(forKey: RepairReviewer.choiceKey)
        defer {
            UserDefaults.standard.set(savedReview, forKey: RepairReviewer.settingKey)
            UserDefaults.standard.set(savedChoice, forKey: RepairReviewer.choiceKey)
        }
        RepairReviewer.setting = .onDevice
        opened()
        check("smart corrections checked while on", m.smartCorrectionsItem.state == .on)
        fire(m.smartCorrectionsItem)
        check("smart corrections item turns it off",
              RepairReviewer.setting == .off && m.smartCorrectionsItem.state == .off)
        fire(m.smartCorrectionsItem)
        check("smart corrections item turns it back on with the same model",
              RepairReviewer.setting == .onDevice && m.smartCorrectionsItem.state == .on)
        let savedIdle = Overlay.idlePillEnabled
        defer { Overlay.idlePillEnabled = savedIdle }
        for want in [true, false] {
            Overlay.idlePillEnabled = want
            let fresh = StatusMenu()
            let it = flattened(fresh.menu).first { $0.title == "Show idle pill" }
            check("idle-pill check mark follows the setting (\(want))",
                  it?.state == (want ? .on : .off))
        }

        // Mode picker: the action sets the mode, the checkmark follows Mode.current, and
        // each LLM mode prewarms ITS OWN profile and only its own (F-5 — the menu must not
        // lose what the Setup popup does; PLAN-PROMPT D3 — one stored session slot, so a
        // mode switch that prewarmed the wrong profile would cost a cold first utterance).
        for want in Mode.allCases {
            let beforeP = Polisher.prepareCount
            let beforeQ = Prompter.prepareCount
            fire(m.modeItems[Mode.allCases.firstIndex(of: want)!])
            opened()
            check("\(want.label) selected", Mode.current == want)
            check("\(want.label) checkmark",
                  m.modeItems.map { $0.state == .on } == Mode.allCases.map { $0 == want })
            check("\(want.label) never prewarms Polish (a Transform-only profile)",
                  Polisher.prepareCount == beforeP)
            check("\(want.label) prompt prewarm",
                  (Prompter.prepareCount > beforeQ) == (want == .prompt))
        }

        // F1: idle → offer to start; a normal session in flight → nothing to do; latched →
        // the item is the only non-keyboard way to stop, so it must stay live.
        opened()
        check("hands-free enabled when idle", m.handsFreeItem.isEnabled)
        check("hands-free reads Start when idle", m.handsFreeItem.title == "Start hands-free")
        active = true
        opened()
        check("hands-free disabled while a session is in flight", !m.handsFreeItem.isEnabled)
        latched = true
        opened()
        check("hands-free enabled while latched", m.handsFreeItem.isEnabled)
        check("hands-free reads Stop while latched", m.handsFreeItem.title == "Stop hands-free")
        active = false
        latched = false
        opened()
        fire(m.handsFreeItem)
        check("hands-free routed to the pipeline", toggled)
        // History persists across launches now, so a real `--menutest` run can start with a
        // non-empty history. No session is active here, so the invariant left to pin is that
        // repaste tracks history emptiness.
        check("repaste tracks an empty history",
              m.repasteItem.isEnabled == !History.items.isEmpty)
        check("retry hidden without failed audio", !m.retryItem.isEnabled && m.retryItem.isHidden)
        check("model retry disabled without load failure", !m.retryModelItem.isEnabled)
        check("learned undo disabled without batch", !m.undoLearnedItem.isEnabled)
        check("transform enabled when idle", m.transformItem.isEnabled)
        check("transform undo disabled without record", !m.undoTransformItem.isEnabled)
        canRetry = true
        canRetryModel = true
        canUndoLearned = true
        canUndoTransform = true
        opened()
        check("recovery actions enabled when available",
              m.retryItem.isEnabled && m.retryModelItem.isEnabled
              && m.undoLearnedItem.isEnabled && m.undoTransformItem.isEnabled)
        active = true
        opened()
        check("retry disabled while a newer capture or delivery is active",
              !m.retryItem.isEnabled && !m.retryModelItem.isEnabled)
        active = false
        canRetry = false
        opened()
        check("retry disabled after retained audio is cleared", !m.retryItem.isEnabled)
        canRetry = true
        opened()
        fire(m.retryItem)
        fire(m.retryModelItem)
        fire(m.undoLearnedItem)
        fire(m.transformItem)
        fire(m.undoTransformItem)
        check("retry routed", retried)
        check("model retry routed", modelRetried)
        check("learned undo routed", learnedUndone)
        check("transform routed", transformed)
        check("transform undo routed", transformUndone)

        // Typed learning finishes while the next recording may already be active. The
        // signal must therefore remain available during an active session and stay icon-only.
        active = true
        m.showLearnedCorrection("Kubernets → Kubernetes")
        check("learned result retained in menu",
              !m.lastLearnedItem.isHidden
              && m.lastLearnedItem.title == "Last learned: Kubernets → Kubernetes")
        check("learned signal stays icon-only while recording",
              m.statusItem?.button?.title.isEmpty == true)
        check("learned signal uses success tint",
              m.statusItem?.button?.contentTintColor == .systemGreen)
        m.clearLearnedCorrection()
        check("successful undo can clear stale learned state",
              m.lastLearnedItem.isHidden
              && m.statusItem?.button?.contentTintColor == nil)
        active = false

        let fixture = "menutest last dictation"
        History.add(raw: "menutest raw", final: fixture, origin: .selfTest)
        DispatchQueue.main.async {
            opened()
            check("repaste enabled with history", m.repasteItem.isEnabled)
            active = true
            opened()
            check("repaste disabled while a session is active", !m.repasteItem.isEnabled)
            active = false
            opened()
            fire(m.repasteItem)
            check("repaste sent the last dictation", repasted == fixture)

            // R-5: a test must never change the mode the app comes back up in.
            if let savedMode { UserDefaults.standard.set(savedMode, forKey: "mode") }
            else { UserDefaults.standard.removeObject(forKey: "mode") }
            m.sessionActive = savedActive
            m.handsFreeActive = savedHandsFree
            m.retryAvailable = savedRetryAvailable
            m.modelRetryAvailable = savedModelRetryAvailable
            m.learnedUndoAvailable = savedLearnedUndoAvailable
            m.transformUndoAvailable = savedTransformUndoAvailable
            m.onToggleHandsFree = savedToggle
            m.onRepaste = savedRepaste
            m.onRetry = savedRetry
            m.onRetryModel = savedRetryModel
            m.onUndoLearned = savedUndoLearned
            m.onTransform = savedTransform
            m.onUndoTransform = savedUndoTransform
            Self.testImmediateActions = false
            Polisher.testInert = false
            Prompter.testInert = false
            opened()
            log(failed == 0 ? "MENUTEST PASS (\(checks) checks)"
                            : "MENUTEST FAIL (\(failed)/\(checks) checks)")
        }
    }
}
