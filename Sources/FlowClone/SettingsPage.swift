import AVFoundation
import Cocoa
import Combine
import IOKit.hid
import SwiftUI

enum OnboardingPermissionStep: Equatable {
    case microphone
    case accessibility
    case inputMonitoring
    case verifyHotkey
    case complete

    var buttonTitle: String {
        switch self {
        case .microphone: "Step 1 of 3 · Allow Microphone"
        case .accessibility: "Step 2 of 3 · Allow Accessibility"
        case .inputMonitoring: "Step 3 of 3 · Allow Input Monitoring"
        case .verifyHotkey: "Test Your Shortcut…"
        case .complete: "Ready to Dictate"
        }
    }

    var instruction: String {
        switch self {
        case .microphone: "First, allow Microphone access so FlowClone can hear your voice."
        case .accessibility: "Next, enable FlowClone under Privacy & Security → Accessibility so words paste into your active app."
        case .inputMonitoring: "Finally, enable FlowClone under Privacy & Security → Input Monitoring so push-to-talk works across apps, then relaunch."
        case .verifyHotkey: "All permissions are granted. Hold fn once or open the practice sheet to verify your shortcut."
        case .complete: "Permissions and shortcut are verified."
        }
    }
}

struct SettingsPage: View {
    @Bindable var model: MainModel
    @State private var tick = 0
    @State private var mode = Mode.current
    @State private var speechEngine = SpeechEngine.preferred
    @State private var livePartial = Overlay.livePartialEnabled
    @State private var keepOnClipboard = Paster.keepsLastDictation
    @State private var codingContext = UserDefaults.standard.bool(forKey: "localCodingContext")
    @State private var autoLearn = UserDefaults.standard.object(forKey: "autoLearn") as? Bool ?? true
    @State private var saveHistory = History.isEnabled
    @State private var smartCorrectionsOn = RepairReviewer.enabled
    @State private var smartCorrections = RepairReviewer.choice
    @State private var claudeKeySaved = ClaudeKey.current != nil
    @State private var claudePromptDismissed = UserDefaults.standard.bool(forKey: ClaudeKey.promptDismissedKey)
    @State private var claudeKeyDraft = ""
    @State private var confirmClear = false
    @State private var updateStatus = Updater.status
    @State private var automaticUpdates = Updater.automaticChecksEnabled()
    @State private var permissionDetails = Permissions.grantsMissing
    @State private var fnConflictWarning: String? = SettingsPage.currentFnConflictWarning()
    @State private var pollEnabled = false
    @State private var showPracticeFromOnboarding = false
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "FlowClone \(info["CFBundleShortVersionString"] as? String ?? "0.3") · Build \(info["CFBundleVersion"] as? String ?? "local")"
    }
    var body: some View {
        let _ = model.historyVersion
        let _ = tick
        let step = Self.currentPermissionStep()
        ScrollViewReader { scroller in
            ScrollView {
                // Ordered for the job people come here to do: repair setup, then input, then
                // how dictation behaves, then privacy; cosmetic and maintenance items last.
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader("Settings")
                    SetupWarnings(tick: tick)
                    if step != .complete {
                        SectionCard("Welcome to FlowClone") {
                            Text(step.instruction)
                                .fixedSize(horizontal: false, vertical: true).proseWidth()
                            HStack(spacing: 8) {
                                Button(step.buttonTitle) {
                                    permissionDetails = true
                                    advanceOnboardingStep(step)
                                    if step != .verifyHotkey {
                                        withAnimation { scroller.scrollTo(Self.permissionsAnchor, anchor: .top) }
                                    }
                                }
                                .prominent()
                                if step == .accessibility || step == .inputMonitoring {
                                    Button("Relaunch FlowClone", action: relaunch)
                                        .disabled(Self.relaunchBlockReason() != nil || Updater.isInstalling)
                                }
                            }
                        }
                    }
                    if !claudeKeySaved, smartCorrectionsOn, smartCorrections == .auto, !claudePromptDismissed {
                        SectionCard("Add your Anthropic API key") {
                            Text("Smart corrections can use Claude to fix mid-sentence false starts. FlowClone doesn’t include an API key — paste your own Anthropic API key below (stored privately in this Mac’s Keychain), or use your Mac’s built-in model instead. With a key, the text of your dictations is sent to Anthropic; without one, nothing you say leaves this Mac.")
                                .fixedSize(horizontal: false, vertical: true).proseWidth()
                            HStack(spacing: 8) {
                                SecureField("Paste your Anthropic API key (sk-ant-…)", text: $claudeKeyDraft)
                                    .frame(maxWidth: 320)
                                    .accessibilityIdentifier("onboardingClaudeApiKey")
                                Button("Save key") {
                                    if ClaudeKey.store(claudeKeyDraft) {
                                        claudeKeySaved = true; claudeKeyDraft = ""; log("Claude API key saved")
                                    }
                                }
                                .prominent()
                                .disabled(ClaudeKey.normalized(claudeKeyDraft) == nil)
                            }
                            HStack(spacing: 8) {
                                Button("Get an Anthropic API key…") {
                                    guard !handsfreeSession else { return }
                                    NSWorkspace.shared.open(ClaudeKey.anthropicConsoleURL)
                                }
                                Button(AppleIntelligenceStatus.current.skipKeyButtonTitle) {
                                    RepairReviewer.setting = .onDevice
                                    smartCorrections = .onDevice
                                    ClaudeKey.dismissSetupPrompt()
                                    claudePromptDismissed = true
                                    log("smart corrections = on-device")
                                    RepairReviewer.prepare(prewarm: Mode.current == .clean)
                                }
                            }
                        }
                    }
                    MicrophoneSettings()
                    ShortcutSettings()
                    if let fnConflictWarning {
                        SectionCard("Globe / fn key tip") {
                            Feedback(text: fnConflictWarning, kind: .warning)
                            Button("Open Keyboard Settings") {
                                guard !handsfreeSession,
                                      let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    dictation
                    SoundAndLanguageSettings()
                    privacy
                    SectionCard("Appearance") { AppearancePicker() }
                    SectionCard("Pill position") {
                        Button("Reset to default position") { Overlay.shared.resetPosition() }
                            .accessibilityIdentifier("resetPillPosition")
                    }
                    permissions.id(Self.permissionsAnchor)
                    MacSetupSettings()
                    updates
                }.pageColumn()
            }
        }
        .onAppear {
            updatePollState()
            refresh()
        }
        .onDisappear { pollEnabled = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updatePollState()
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            updatePollState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            updatePollState()
            if pollEnabled { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in
            fnConflictWarning = Self.currentFnConflictWarning()
        }
        .onReceive(NotificationCenter.default.publisher(for: Updater.didChange)) { _ in
            updateStatus = Updater.status
        }
        .task(id: pollEnabled) {
            guard pollEnabled else { return }
            while !Task.isCancelled && pollEnabled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled && pollEnabled else { break }
                refresh()
                updatePollState()
            }
        }
        .sheet(isPresented: $showPracticeFromOnboarding) { DictationPracticePage() }
        .confirmationDialog(History.isEnabled ? "Clear \(History.items.count) saved dictations?" : "Delete the saved history file?", isPresented: $confirmClear) {
            Button("Delete saved history", role: .destructive) { History.clear() }
        } message: { Text("Your total word count and speaking time are kept.") }
    }

    private static let permissionsAnchor = "settings.permissions"

    private var dictation: some View {
        SectionCard("Dictation") {
            VStack(alignment: .leading, spacing: 18) {
                SettingGroup {
                    // Label beside the control, like the pop-up rows below it.
                    HStack(spacing: 10) {
                        Text("Cleanup mode").accessibilityHidden(true)
                        ThemedSegmented(options: Mode.allCases.map { ($0, $0.label) }, selection: $mode, label: "Cleanup mode")
                            .fixedSize()
                            .onChange(of: mode) { _, new in if new != Mode.current { Mode.set(new) } }
                    }
                    SettingCaption(mode.explanation)
                }
                SettingGroup {
                    HStack(spacing: 10) {
                        Text("Speech recognition").accessibilityHidden(true)
                        ThemedMenuPicker(label: "Speech recognition",
                                         options: SpeechEngine.allCases.map { ($0, $0.label) },
                                         selection: $speechEngine)
                        .accessibilityIdentifier("speechRecognitionEngine")
                        .onChange(of: speechEngine) { _, new in SpeechEngine.preferred = new }
                    }
                    if speechEngine != SpeechEngine.active {
                        SettingCaption("Currently active: \(SpeechEngine.active.label)")
                        Button("Relaunch to apply speech engine", action: relaunch)
                            .disabled(DictationWorkspace.shared.recording || DictationWorkspace.shared.processing || MeetingCoordinator.shared.blocksUpdate)
                            .padding(.top, 4)
                    }
                }
                SettingGroup {
                    Toggle("Smart corrections", isOn: $smartCorrectionsOn)
                        .accessibilityIdentifier("smartCorrections")
                        .onChange(of: smartCorrectionsOn) { _, new in
                            if new != RepairReviewer.enabled {
                                RepairReviewer.enabled = new
                                log("smart corrections = \(RepairReviewer.setting.rawValue)")
                                RepairReviewer.prepare(prewarm: Mode.current == .clean)
                            }
                        }
                    SettingCaption("Fixes punctuation, dictionary sound-alikes, and mid-sentence false starts. Short clean dictations stay instant on your Mac.")
                    if smartCorrectionsOn {
                        HStack(spacing: 10) {
                            Text("Model").accessibilityHidden(true)
                            ThemedMenuPicker(label: "Smart corrections model",
                                             options: [RepairReviewer.Setting.auto, .onDevice].map { ($0, $0.label) },
                                             selection: $smartCorrections)
                            .accessibilityIdentifier("smartCorrectionsModel")
                            .onChange(of: smartCorrections) { _, new in
                                if RepairReviewer.enabled, new != RepairReviewer.setting {
                                    RepairReviewer.setting = new; log("smart corrections = \(new.rawValue)")
                                    RepairReviewer.prepare(prewarm: Mode.current == .clean)
                                }
                            }
                        }
                    }
                    if smartCorrectionsOn, smartCorrections == .auto {
                        SettingCaption(claudeKeySaved
                            ? "Using your Anthropic API key saved in this Mac’s Keychain. Dictations that need more than basic cleanup, Prompt mode dictations, your dictionary words and meeting transcripts are sent to Anthropic. Audio never is. Choose Built-in model to keep dictation on this Mac."
                            : "No Anthropic API key saved yet, so nothing you say leaves this Mac. Paste your own key below to use Claude for Smart corrections, Prompt mode, and detailed meeting notes; the text of those dictations and transcripts is then sent to Anthropic.")
                        HStack(spacing: 8) {
                            SecureField(claudeKeySaved ? "Claude API key saved" : "Paste your Anthropic API key (sk-ant-…)", text: $claudeKeyDraft)
                                .frame(maxWidth: 300)
                                .accessibilityIdentifier("claudeApiKey")
                            Button("Save") {
                                if ClaudeKey.store(claudeKeyDraft) {
                                    claudeKeySaved = true; claudeKeyDraft = ""; log("Claude API key saved")
                                }
                            }
                            .disabled(ClaudeKey.normalized(claudeKeyDraft) == nil)
                            if claudeKeySaved {
                                Button("Remove") {
                                    ClaudeKey.clear()
                                    claudeKeySaved = false
                                    claudePromptDismissed = false
                                    log("Claude API key removed")
                                    RepairReviewer.prepare(prewarm: Mode.current == .clean)
                                }
                            } else {
                                Button("Get key…") {
                                    guard !handsfreeSession else { return }
                                    NSWorkspace.shared.open(ClaudeKey.anthropicConsoleURL)
                                }
                            }
                        }
                    }
                }
                SettingGroup {
                    Toggle("Show live text above the recording pill", isOn: $livePartial)
                        .onChange(of: livePartial) { _, new in
                            if new != Overlay.livePartialEnabled {
                                Overlay.livePartialEnabled = new; log("live partial text = \(new)")
                                if !new { Overlay.shared.clearPartial() }
                            }
                        }
                }
                SettingGroup {
                    Toggle("Keep last dictation on clipboard", isOn: $keepOnClipboard)
                        .accessibilityIdentifier("keepDictationOnClipboard")
                        .onChange(of: keepOnClipboard) { _, new in
                            if new != Paster.keepsLastDictation {
                                Paster.keepsLastDictation = new; log("keep dictation on clipboard = \(new)")
                            }
                        }
                }
                SettingGroup {
                    Toggle("Automatically learn spelling corrections", isOn: $autoLearn)
                        .onChange(of: autoLearn) { _, new in
                            UserDefaults.standard.set(new, forKey: "autoLearn")
                            if !new { AutoLearn.monitor.stop() }
                        }
                }
            }
        }
    }

    private var privacy: some View {
        SectionCard("Privacy & history") {
            VStack(alignment: .leading, spacing: 18) {
                SettingGroup {
                    Toggle("Recognize nearby coding terms", isOn: $codingContext)
                        .onChange(of: codingContext) { _, new in UserDefaults.standard.set(new, forKey: "localCodingContext") }
                }
                Hairline()
                VStack(alignment: .leading, spacing: 12) {
                    let count = History.items.count
                    let fileExists = FileManager.default.fileExists(atPath: History.storeURL.path)
                    SettingGroup {
                        Toggle("Save dictation history", isOn: $saveHistory)
                            .onChange(of: saveHistory) { _, new in
                                History.isEnabled = new
                                DictationWorkspace.shared.privacyChanged()
                            }
                    }
                    if saveHistory {
                        HistoryRetentionSettings()
                    }
                    Button("Clear history…", role: .destructive) { confirmClear = true }.disabled(count == 0 && !fileExists)
                }
            }
        }
    }

    private var permissions: some View {
        let step = Self.currentPermissionStep()
        return SectionCard {
            DisclosureGroup(isExpanded: $permissionDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Permissions.grants) { PermissionRow(grant: $0, tick: tick) }
                    if Permissions.grantsMissing {
                        SettingCaption("Relaunch after granting Accessibility or Input Monitoring.")
                    }
                    HStack(spacing: 8) {
                        if step != .complete {
                            Button(step.buttonTitle) { advanceOnboardingStep(step) }
                                .prominent()
                        }
                        Button("Relaunch FlowClone", action: relaunch)
                            .disabled(Self.relaunchBlockReason() != nil || Updater.isInstalling)
                            .accessibilityIdentifier("relaunchFromPermissions")
                    }
                }.padding(.top, 16)
            } label: {
                HStack {
                    Text("Permissions").font(Theme.sectionFont).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Feedback(text: Permissions.grantsMissing ? "Setup needed" : (Permissions.hotkeyVerified() ? "Ready to dictate" : "Granted · try your hotkey"),
                             kind: Permissions.grantsMissing ? .warning : .success)
                }
            }
        }
    }

    private var updates: some View {
        SectionCard("Updates & diagnostics") {
            Text(version).fontWeight(.medium).textSelection(.enabled)
            if Bundle.main.bundleURL.pathExtension == "app",
               let locationWarning = Updater.installLocationError(bundleURL: Updater.destinationBundleURL()) {
                Feedback(text: locationWarning.description, kind: .warning)
            }
            HStack {
                Text(updateStatus).foregroundStyle(Theme.muted)
                Spacer()
                if Updater.hasStagedUpdate {
                    Button("Install & Relaunch") {
                        Task { await Updater.installNow(); updateStatus = Updater.status }
                    }
                    .prominent()
                    .disabled(Self.relaunchBlockReason() != nil || Updater.isBusy)
                } else {
                    Button(Updater.isChecking ? "Checking…" : "Check for updates") {
                        Task { await Updater.check(userInitiated: true); updateStatus = Updater.status }
                    }
                    .disabled(Updater.isBusy)
                }
            }
            SettingGroup {
                Toggle("Check for updates automatically", isOn: $automaticUpdates)
                    .accessibilityIdentifier("automaticUpdates")
                    .onChange(of: automaticUpdates) { _, new in
                        guard new != Updater.automaticChecksEnabled() else { return }
                        Updater.setAutomaticChecks(new)
                        updateStatus = Updater.status
                    }
                SettingCaption("Updates carry fixes, including security fixes. They are downloaded from FlowClone’s public release page, checked against the developer’s signature, and installed when you are not dictating. With this off, use Check for updates.")
            }
            DisclosureGroup("Diagnostics & maintenance") {
                HStack {
                    Button("Open log") { flushLog(); NSWorkspace.shared.open(logURL) }
                    Button("Relaunch", action: relaunch)
                        .disabled(MeetingCoordinator.shared.blocksUpdate)
                    Button("Quit FlowClone") { AppTermination.requestUserQuit() }
                }.padding(.top, 12)
            }
        }
    }

    static func shouldPollPermissions(windowOnScreen: Bool, appActive: Bool, grantsMissing: Bool) -> Bool {
        windowOnScreen && (appActive || grantsMissing)
    }

    private func updatePollState() {
        pollEnabled = Self.shouldPollPermissions(
            windowOnScreen: MainWindow.shared.isOnScreen,
            appActive: NSApp.isActive,
            grantsMissing: Permissions.grantsMissing
        )
    }

    nonisolated static func nextPermissionStep(
        micGranted: Bool,
        axGranted: Bool,
        inputGranted: Bool,
        hotkeyVerified: Bool
    ) -> OnboardingPermissionStep {
        if !micGranted { return .microphone }
        if !axGranted { return .accessibility }
        if !inputGranted { return .inputMonitoring }
        if !hotkeyVerified { return .verifyHotkey }
        return .complete
    }

    static func currentPermissionStep() -> OnboardingPermissionStep {
        nextPermissionStep(
            micGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            axGranted: AXIsProcessTrusted(),
            inputGranted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            hotkeyVerified: Permissions.hotkeyVerified()
        )
    }

    private func advanceOnboardingStep(_ step: OnboardingPermissionStep) {
        switch step {
        case .microphone:
            guard !handsfreeSession else { Handsfree.log("blocked permission prompt: microphone"); return }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    log("AVCaptureDevice.requestAccess(.audio) -> \(granted)")
                    Task { @MainActor in refresh() }
                }
            } else {
                Permissions.openPane("Privacy_Microphone")
            }
        case .accessibility:
            guard !handsfreeSession else { Handsfree.log("blocked permission prompt: accessibility"); return }
            let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            log("AXIsProcessTrustedWithOptions(prompt:true) -> \(trusted)")
            if !trusted { Permissions.openPane("Privacy_Accessibility") }
            refresh()
        case .inputMonitoring:
            guard !handsfreeSession else { Handsfree.log("blocked permission prompt: inputMonitoring"); return }
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            log("IOHIDRequestAccess(listenEvent) -> \(granted)")
            if !granted { Permissions.openPane("Privacy_ListenEvent") }
            refresh()
        case .verifyHotkey:
            showPracticeFromOnboarding = true
        case .complete:
            break
        }
    }

    nonisolated static func fnKeyConflictDescription(
        appleFnUsageType: Int?,
        bindings: [ShortcutBinding]
    ) -> String? {
        guard bindings.contains(where: { $0.keyCode == 63 && $0.modifiers == 0 }),
              let usage = appleFnUsageType, usage > 0 else {
            return nil
        }
        switch usage {
        case 1:
            return "macOS sets “Press 🌐 key to” → Change Input Source. Set it to “Do Nothing” in System Settings → Keyboard so holding fn doesn’t switch keyboards."
        case 2:
            return "macOS sets “Press 🌐 key to” → Show Emoji & Symbols. Set it to “Do Nothing” in System Settings → Keyboard so tapping fn doesn’t open the emoji picker."
        case 3:
            return "macOS sets “Press 🌐 key to” → Start Dictation. Set it to “Do Nothing” in System Settings → Keyboard so macOS Dictation doesn’t compete with FlowClone."
        default:
            return "macOS assigns a system action to the 🌐 / fn key. Set “Press 🌐 key to” to “Do Nothing” in System Settings → Keyboard for reliable fn push-to-talk."
        }
    }

    nonisolated static func currentFnConflictWarning() -> String? {
        let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return fnKeyConflictDescription(appleFnUsageType: usage, bindings: ShortcutStore.shared.bindings)
    }

    private func refresh() {
        guard MainWindow.shared.isVisible else { return }
        tick += 1
        if AXIsProcessTrusted() { Permissions.onHotkeyRearm() }
        mode = Mode.current; livePartial = Overlay.livePartialEnabled; updateStatus = Updater.status
        keepOnClipboard = Paster.keepsLastDictation   // the menu bar checkbox may have changed it
        smartCorrectionsOn = RepairReviewer.enabled; smartCorrections = RepairReviewer.choice   // likewise
        claudeKeySaved = ClaudeKey.current != nil
        claudePromptDismissed = UserDefaults.standard.bool(forKey: ClaudeKey.promptDismissedKey)
        fnConflictWarning = Self.currentFnConflictWarning()
    }
    static func relaunchBlockReason(
        meetingBlocks: Bool = MeetingCoordinator.shared.blocksUpdate,
        transformBlocks: Bool = TransformController.shared.blocksUpdate
    ) -> String? {
        if meetingBlocks { return "Finish the current meeting before relaunching." }
        if transformBlocks { return "Finish the current dictation before relaunching." }
        return nil
    }
    private func relaunch() {
        Task {
            if let reason = Self.relaunchBlockReason() {
                updateStatus = reason
                return
            }
            if Updater.hasStagedUpdate {
                await Updater.installNow()
                updateStatus = Updater.status
                return
            }
            guard await Updater.reserveForInstall() else {
                updateStatus = "Finish the current dictation before relaunching."
                return
            }
            if let reason = Self.relaunchBlockReason() {
                Updater.releaseInstallReservation()
                updateStatus = reason
                return
            }
            if !Updater.relaunch(Bundle.main.bundleURL) {
                Updater.releaseInstallReservation()
                updateStatus = "Could not relaunch. Quit and reopen FlowClone."
            }
        }
    }
}

struct PermissionRow: View {
    let grant: Permissions.Grant
    let tick: Int
    private var purpose: String {
        switch grant.id {
        case "Microphone": "Captures your voice while dictating."
        case "Accessibility": "Pastes your words into the current text field."
        case "Input Monitoring": "Recognizes fn and the fallback shortcut across apps."
        default: "Hold fn once to verify that the shortcut reaches FlowClone."
        }
    }
    var body: some View {
        let _ = tick
        let ok = grant.check()
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle((ok ? FeedbackKind.success : .warning).color)
            VStack(alignment: .leading, spacing: 4) {
                Text(grant.id).fontWeight(.medium)
                Text(purpose).font(UIStyle.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            if !ok, let pane = grant.pane { Button("Grant access") { Permissions.openPane(pane) } }
            else { Text(ok ? (grant.pane == nil ? "Verified" : "Granted") : "Try shortcut").font(UIStyle.caption).foregroundStyle(Theme.muted) }
        }
    }
}

/// A control with its label and captions, set tight so the section's larger gaps separate
/// one setting from the next. Every row shares the section's left edge.
struct SettingGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 6) { content } }
}

/// Supporting text under a Settings control: caption size, muted, at a readable measure.
struct SettingCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(UIStyle.caption).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true).proseWidth()
    }
}
