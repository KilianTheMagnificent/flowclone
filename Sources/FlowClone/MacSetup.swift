// What a Mac unlike the owner's needs to be told or allowed to change: whether Apple
// Intelligence is there, where the speech model download stands, opening at login, and
// setups that cannot work (a temporary copy run from Downloads, a microphone blocked by
// the Mac's administrator). Status first, then the one switch.
import AVFoundation
import Cocoa
import FluidAudio
import Network
import ServiceManagement
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence

/// Why Apple's on-device model can or cannot be used here. Prompt mode, text transforms,
/// Built-in Smart corrections and meeting summaries all depend on it.
enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    /// macOS 14 and 15 have no Foundation Models framework.
    case needsNewerMacOS
    case deviceNotEligible
    /// Off in System Settings, or not offered for this Mac's language or region.
    case notEnabled
    /// Turned on, model still downloading.
    case modelNotReady
    case unavailable

    static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return status(of: SystemLanguageModel.default.availability)
        }
        #endif
        return .needsNewerMacOS
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func status(of availability: SystemLanguageModel.Availability) -> AppleIntelligenceStatus {
        guard case .unavailable(let reason) = availability else { return .available }
        switch reason {
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady: return .modelNotReady
        @unknown default: return .unavailable
        }
    }
    #endif

    var isAvailable: Bool { self == .available }

    /// One line: is it there, and if not, why.
    var summary: String {
        switch self {
        case .available: "Apple Intelligence is on."
        case .needsNewerMacOS: "Apple Intelligence needs macOS 26 or newer."
        case .deviceNotEligible: "This Mac does not support Apple Intelligence."
        case .notEnabled: "Apple Intelligence is turned off, or not offered in this Mac’s language or region. Turn it on in System Settings › Apple Intelligence & Siri."
        case .modelNotReady: "Apple Intelligence is still downloading its model. This can take a while after it is turned on."
        case .unavailable: "Apple Intelligence is not available right now."
        }
    }

    /// What FlowClone does instead, so nothing looks broken.
    var consequence: String? {
        guard !isAvailable else { return nil }
        return "Until it is available: Prompt mode and Smart corrections use Claude if you save an API key, otherwise Prompt mode works like Clean and Smart corrections use rules only. Text transforms are off, and meeting notes list key excerpts instead of a written summary."
    }

    /// The Transform window's status line when a preview could not be made.
    var transformFailure: String {
        isAvailable ? "Couldn’t generate a preview." : "Transforms need Apple Intelligence. \(summary)"
    }

    /// Title of the onboarding button that skips the Claude key. With no built-in model
    /// on this Mac, "use built-in model" would promise something that is not there.
    var skipKeyButtonTitle: String {
        switch self {
        case .available, .modelNotReady, .notEnabled: "Use built-in model instead"
        case .needsNewerMacOS, .deviceNotEligible, .unavailable: "Skip, keep everything on this Mac"
        }
    }
}

// MARK: - Speech model download

/// Why the speech model could not be downloaded or loaded, in words a stranger can act on.
enum SpeechModelProblem: Error, Equatable, Sendable {
    case offline
    /// Online, but the model host (Hugging Face) could not be reached or answered with
    /// something else: a Wi-Fi sign-in page, a firewall or network filter, an outage.
    case serverUnreachable
    case lowDisk(freeBytes: Int64)
    case other

    /// Parakeet Ultra is about 630 MB; the rest keeps the Mac from running completely full.
    static let requiredFreeBytes: Int64 = 1_000_000_000

    static func classify(_ error: Error, freeBytes: Int64?, needsDownload: Bool) -> SpeechModelProblem {
        if let problem = error as? SpeechModelProblem { return problem }
        if needsDownload, let freeBytes, freeBytes < requiredFreeBytes { return .lowDisk(freeBytes: freeBytes) }
        return classifyChain(error, freeBytes: freeBytes, depth: 0) ?? .other
    }

    private static func classifyChain(_ error: Error, freeBytes: Int64?, depth: Int) -> SpeechModelProblem? {
        guard depth < 6 else { return nil }
        if let download = error as? DownloadError {
            switch download {
            case .downloadFailed(_, let underlying):
                return classifyChain(underlying, freeBytes: freeBytes, depth: depth + 1) ?? .serverUnreachable
            case .invalidResponse, .rateLimited, .htmlErrorResponse, .invalidArtifact, .stalled:
                return .serverUnreachable
            case .modelNotFound, .networkDisabled, .modelMissing:
                return nil
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                return .offline
            case .cancelled:
                return nil
            default:
                return .serverUnreachable
            }
        }
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
            || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError) {
            return .lowDisk(freeBytes: freeBytes ?? 0)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return classifyChain(underlying, freeBytes: freeBytes, depth: depth + 1)
        }
        return nil
    }

    /// Free space for the volume holding the model cache (in the home folder).
    static func freeDiskBytes(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Network trouble can clear on its own, so FlowClone keeps trying; the rest needs the person.
    var retriesByItself: Bool { self == .offline || self == .serverUnreachable }

    var message: String {
        switch self {
        case .offline:
            return "The speech model could not be downloaded because this Mac is offline. FlowClone tries again when it is back online."
        case .serverUnreachable:
            return "The speech model could not be downloaded from huggingface.co. A Wi-Fi sign-in page, firewall, VPN or network filter may be blocking it. FlowClone tries again every few minutes."
        case .lowDisk(let free):
            let have = ByteCountFormatter.string(fromByteCount: max(0, free), countStyle: .file)
            return "Not enough free disk space for the speech model: it needs about 1 GB and this Mac has \(have) free. Free up space, then choose Retry."
        case .other:
            return "The speech model could not be loaded. If Retry keeps failing, quit and reopen FlowClone."
        }
    }
}

enum SpeechModelStatus: Equatable, Sendable {
    case loading
    case downloading(done: Int, total: Int)
    case ready
    case failed(SpeechModelProblem)

    /// The one progress line the transcriber writes, and the only shape `parse` reads back.
    static func downloadingLine(done: Int, total: Int) -> String {
        "downloading model \(done)/\(total) files"
    }

    static func parse(_ line: String) -> SpeechModelStatus? {
        let prefix = "downloading model ", suffix = " files"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let parts = line.dropFirst(prefix.count).dropLast(suffix.count).split(separator: "/")
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]),
              total > 0, done >= 0 else { return nil }
        return .downloading(done: min(done, total), total: total)
    }

    /// Short form for the window's status chip and the capture bar.
    var shortLabel: String {
        switch self {
        case .loading: "Loading speech model…"
        case .downloading(let done, let total): "Downloading speech model (\(done) of \(total) files)…"
        case .ready: "Speech model ready"
        case .failed: "Speech model not available"
        }
    }

    /// A network problem is retried when the Mac goes from offline to online, and on a slow
    /// timer for a blocked host or Wi-Fi sign-in page, which never look offline.
    static func shouldRetry(previous: NWPath.Status?, current: NWPath.Status) -> Bool {
        guard let previous else { return false }   // the monitor's first report is not a change
        return previous != .satisfied && current == .satisfied
    }
}

/// The speech model's state for the window. Pipeline writes it; `retry` is wired to
/// Pipeline's own bounded retry, the same action as the menu's Retry speech model.
@MainActor @Observable
final class SpeechModelState {
    static let shared = SpeechModelState()
    static let networkRetryInterval: TimeInterval = 300

    private(set) var status: SpeechModelStatus = .loading
    @ObservationIgnored var retry: () -> Void = {}
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: NWPath.Status?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    func set(_ new: SpeechModelStatus) {
        // Download progress that arrives after the outcome (a late progress tick) is stale.
        if case .downloading = new, status == .ready { return }
        status = new
        if case .failed(let problem) = new, problem.retriesByItself { watchForNetwork() } else { stopWatching() }
    }

    /// Called with each transcriber progress line, from any thread.
    nonisolated static func report(_ line: String) {
        guard let parsed = SpeechModelStatus.parse(line) else { return }
        DispatchQueue.main.async { shared.set(parsed) }
    }

    private func retryIfStillFailed(_ why: String) {
        guard case .failed = status else { stopWatching(); return }
        log("speech model: retrying after \(why)")
        retry()
    }

    private func watchForNetwork() {
        guard monitor == nil, !handsfreeSession else { return }
        let monitor = NWPathMonitor()
        lastPath = nil
        monitor.pathUpdateHandler = { path in
            let current = path.status
            DispatchQueue.main.async {
                let state = SpeechModelState.shared
                let retry = SpeechModelStatus.shouldRetry(previous: state.lastPath, current: current)
                state.lastPath = current
                if retry { state.retryIfStillFailed("the network came back") }
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        timer = Timer.scheduledTimer(withTimeInterval: Self.networkRetryInterval, repeats: true) { _ in
            MainActor.assumeIsolated { SpeechModelState.shared.retryIfStillFailed("waiting \(Int(Self.networkRetryInterval / 60)) minutes") }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    SpeechModelState.shared.retryIfStillFailed("a wake")
                }
            }
        }
    }

    private func stopWatching() {
        monitor?.cancel(); monitor = nil; lastPath = nil
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}

// MARK: - Open at login

enum LaunchAtLogin {
    static let defaultsKey = "launchAtLogin"

    /// On unless the person turned it off: FlowClone has always opened at login by default.
    static func wanted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }

    enum Step: Equatable {
        case register, unregister, nothing
        /// Turned off in System Settings › General › Login Items. Registering again would
        /// override that choice, so only the person can turn it back on there.
        case needsApproval
        /// A translocated copy lives at a random path that is gone after a restart.
        case notFromTemporaryCopy
    }

    static func step(wanted: Bool, status: SMAppService.Status, translocated: Bool) -> Step {
        switch (wanted, status) {
        case (false, .enabled), (false, .requiresApproval): return .unregister
        case (false, _): return .nothing
        case (true, .enabled): return .nothing
        case (true, .requiresApproval): return .needsApproval
        // .notRegistered and .notFound (before a first registration on this OS).
        case (true, _): return translocated ? .notFromTemporaryCopy : .register
        }
    }

    static var isTranslocated: Bool { isTranslocated(Bundle.main.bundlePath) }
    static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    /// What the Settings row says under the switch, or nil when all is as asked.
    static func note(wanted: Bool, status: SMAppService.Status, translocated: Bool) -> String? {
        guard wanted else { return nil }
        if translocated {
            return "FlowClone is running from a temporary copy, so it can’t open at login. Move it to Applications first."
        }
        switch status {
        case .enabled: return nil
        case .requiresApproval:
            return "Turned off in System Settings › General › Login Items. Turn FlowClone on there to open it at login."
        default:
            return "FlowClone could not add itself to Login Items. Add it in System Settings › General › Login Items."
        }
    }
}

// MARK: - Settings views

/// Warnings that belong at the top of Settings on a first run: this setup cannot work.
struct SetupWarnings: View {
    let tick: Int
    var body: some View {
        let _ = tick
        let translocated = LaunchAtLogin.isTranslocated
        let micRestricted = AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
        if translocated || micRestricted {
            SectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    if translocated {
                        Feedback(text: "FlowClone is running from a temporary copy that macOS made because it was opened from Downloads. Permissions, updates and opening at login will not stick. Quit FlowClone, drag FlowClone.app into Applications, and open it from there.",
                                 kind: .warning)
                    }
                    if micRestricted {
                        Feedback(text: "This Mac’s administrator (a device-management profile or Screen Time) blocks microphone access, so FlowClone cannot hear you. Ask them to allow FlowClone to use the microphone.",
                                 kind: .warning)
                    }
                }
            }
            .accessibilityIdentifier("setupWarnings")
        }
    }
}

/// Settings › This Mac: opening at login, menu bar icon, the speech model, and Apple Intelligence.
struct MacSetupSettings: View {
    @Bindable private var model = SpeechModelState.shared
    @State private var openAtLogin = LaunchAtLogin.wanted()
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var showMenuBarIcon = StatusMenu.showMenuBarIcon
    @State private var intelligence = AppleIntelligenceStatus.current

    var body: some View {
        SectionCard("This Mac") {
            VStack(alignment: .leading, spacing: 18) {
                SettingGroup {
                    Toggle("Open FlowClone at login", isOn: $openAtLogin)
                        .accessibilityIdentifier("openAtLogin")
                        .onChange(of: openAtLogin) { _, new in
                            guard new != LaunchAtLogin.wanted() else { return }
                            UserDefaults.standard.set(new, forKey: LaunchAtLogin.defaultsKey)
                            log("open at login = \(new)")
                            setupLaunchAtLogin()
                            loginStatus = SMAppService.mainApp.status
                        }
                    SettingCaption("Keeps the dictation shortcut and scheduled meeting recording working after a restart without opening the window.")
                    if let note = LaunchAtLogin.note(wanted: openAtLogin, status: loginStatus,
                                                      translocated: LaunchAtLogin.isTranslocated) {
                        Feedback(text: note, kind: .warning)
                        if loginStatus == .requiresApproval {
                            Button("Open Login Items Settings") {
                                guard !handsfreeSession else { Handsfree.log("blocked opening Login Items"); return }
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }
                }
                SettingGroup {
                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                        .accessibilityIdentifier("showMenuBarIcon")
                        .onChange(of: showMenuBarIcon) { _, new in
                            guard new != StatusMenu.showMenuBarIcon else { return }
                            StatusMenu.shared.setMenuBarIconVisible(new)
                        }
                    SettingCaption(showMenuBarIcon
                        ? "Shows FlowClone’s waveform icon in the top menu bar."
                        : "FlowClone keeps running in the background. Open it from Spotlight, Applications, or the pill to show this window.")
                }
                SettingGroup {
                    Text("Speech model").fontWeight(.medium)
                    speechModelRow
                }
                SettingGroup {
                    Text("Apple Intelligence").fontWeight(.medium)
                    Feedback(text: intelligence.summary, kind: intelligence.isAvailable ? .success : .information)
                        .accessibilityIdentifier("appleIntelligenceStatus")
                    if let consequence = intelligence.consequence {
                        SettingCaption(consequence)
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder private var speechModelRow: some View {
        switch model.status {
        case .ready:
            Feedback(text: "Downloaded and ready. Speech recognition runs on this Mac.", kind: .success)
        case .loading:
            Feedback(text: "Loading. The first launch downloads about 630 MB.", kind: .information)
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(total))
                .frame(maxWidth: 320)
                .accessibilityLabel("Speech model download")
            SettingCaption("Downloading, \(done) of \(total) files (about 630 MB in all).")
        case .failed(let problem):
            Feedback(text: problem.message, kind: .warning)
                .accessibilityIdentifier("speechModelProblem")
            Button("Retry download") { model.retry() }
                .accessibilityIdentifier("retrySpeechModel")
        }
    }

    private func refresh() {
        loginStatus = SMAppService.mainApp.status
        openAtLogin = LaunchAtLogin.wanted()
        showMenuBarIcon = StatusMenu.showMenuBarIcon
        intelligence = AppleIntelligenceStatus.current
    }
}
