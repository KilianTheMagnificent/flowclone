import ApplicationServices
import Cocoa
import CoreAudio
import Foundation

/// A live audio/video call detected directly from macOS Core Audio process state.
struct DetectedMeetingCall: Equatable, Sendable {
    /// Normalized app family identifier (e.g. "us.zoom.xos", "com.google.chrome").
    var key: String
    /// Human-readable app name (e.g. "Zoom", "Chrome", "FaceTime").
    var appName: String
    /// Default title used when no scheduled calendar event matches this call.
    var suggestedTitle: String
    /// Whether this call is running inside a web browser rather than a native conferencing app.
    var isBrowser: Bool
}

/// Snapshot of one Core Audio client process.
struct AudioProcessInfo: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String
    var isRunningInput: Bool
    var isRunningOutput: Bool
}

@MainActor protocol MeetingCallDetecting: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
    func currentCall(hasActiveCalendarEvent: Bool) -> DetectedMeetingCall?
}

/// Pure matching rules turning Core Audio process states and optional browser window titles
/// into a `DetectedMeetingCall`. Separated from Core Audio IPC for deterministic unit tests.
enum LiveMeetingMatcher {
    struct AppDescriptor: Sendable {
        let appName: String
        let suggestedTitle: String
    }

    private static let ignoredBundlePrefixes: [String] = [
        "com.andre.flowclone",
        "com.apple.mediaremoteuiservice",
        "com.apple.siri",
        "com.apple.voicecontrol",
        "com.apple.voicememos",
        "com.apple.dictationim",
        "com.apple.controlcenter",
    ]

    /// Native conferencing / calling apps whose active microphone strongly indicates a live meeting.
    static let dedicatedApps: [String: AppDescriptor] = [
        "us.zoom.xos": .init(appName: "Zoom", suggestedTitle: "Zoom Call"),
        "us.zoom.workplace": .init(appName: "Zoom", suggestedTitle: "Zoom Call"),
        "com.microsoft.teams": .init(appName: "Microsoft Teams", suggestedTitle: "Microsoft Teams Call"),
        "com.microsoft.teams2": .init(appName: "Microsoft Teams", suggestedTitle: "Microsoft Teams Call"),
        "com.tinyspeck.slackmacgap": .init(appName: "Slack", suggestedTitle: "Slack Huddle"),
        "com.apple.avconferenced": .init(appName: "FaceTime", suggestedTitle: "FaceTime Call"),
        "com.apple.facetime": .init(appName: "FaceTime", suggestedTitle: "FaceTime Call"),
        "com.cisco.webexmeetingsapp": .init(appName: "Webex", suggestedTitle: "Webex Meeting"),
        "com.webex.meetingmanager": .init(appName: "Webex", suggestedTitle: "Webex Meeting"),
        "cisco-systems.spark": .init(appName: "Webex", suggestedTitle: "Webex Meeting"),
        "com.hnc.discord": .init(appName: "Discord", suggestedTitle: "Discord Call"),
        "com.hnc.discordcanary": .init(appName: "Discord", suggestedTitle: "Discord Call"),
        "com.hnc.discordptb": .init(appName: "Discord", suggestedTitle: "Discord Call"),
        "net.whatsapp.whatsapp": .init(appName: "WhatsApp", suggestedTitle: "WhatsApp Call"),
        "desktop.whatsapp": .init(appName: "WhatsApp", suggestedTitle: "WhatsApp Call"),
        "com.ringcentral.glip": .init(appName: "RingCentral", suggestedTitle: "RingCentral Call"),
        "com.ringcentral.ringcentral": .init(appName: "RingCentral", suggestedTitle: "RingCentral Call"),
        "com.skype.skype": .init(appName: "Skype", suggestedTitle: "Skype Call"),
        "com.goto.meeting": .init(appName: "GoTo Meeting", suggestedTitle: "GoTo Meeting"),
        "com.logmein.gotomeeting": .init(appName: "GoTo Meeting", suggestedTitle: "GoTo Meeting"),
        "com.bluejeansnet.bluejeans": .init(appName: "BlueJeans", suggestedTitle: "BlueJeans Call"),
        "com.amazon.chime": .init(appName: "Amazon Chime", suggestedTitle: "Chime Call"),
        "com.around.around": .init(appName: "Around", suggestedTitle: "Around Call"),
        "co.tuple.app": .init(appName: "Tuple", suggestedTitle: "Tuple Call"),
        "com.pop.pop.app": .init(appName: "Pop", suggestedTitle: "Pop Call"),
        "com.tandem.tandem": .init(appName: "Tandem", suggestedTitle: "Tandem Call"),
        "com.gather.town": .init(appName: "Gather", suggestedTitle: "Gather Call"),
        "ru.keepcoder.telegram": .init(appName: "Telegram", suggestedTitle: "Telegram Call"),
        "org.whispersystems.signal-desktop": .init(appName: "Signal", suggestedTitle: "Signal Call"),
        "com.viber.osx": .init(appName: "Viber", suggestedTitle: "Viber Call"),
    ]

    /// Web browsers that host Google Meet, Zoom web, Teams web, Slack huddles, etc.
    static let browsers: [String: String] = [
        "com.google.chrome": "Chrome",
        "com.google.chrome.beta": "Chrome",
        "com.google.chrome.canary": "Chrome",
        "com.apple.safari": "Safari",
        "com.apple.safaritechnologypreview": "Safari",
        "company.thebrowser.browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.dia.browser": "Dia",
        "com.brave.browser": "Brave",
        "com.brave.browser.beta": "Brave",
        "com.brave.browser.nightly": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.microsoft.edgemac.beta": "Edge",
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "com.operasoftware.opera": "Opera",
        "com.vivaldi.vivaldi": "Vivaldi",
        "com.sigmaos.sigmaos.macos": "SigmaOS",
        "app.zen-browser.zen": "Zen",
        "com.kagi.kagimacos": "Orion",
        "ai.perplexity.comet": "Comet",
        "com.openai.atlas": "Atlas",
    ]

    private static let browserTitlePatterns: [(needle: String, title: String)] = [
        ("meet - ", "Google Meet"),
        ("google meet", "Google Meet"),
        ("zoom meeting", "Zoom Call"),
        ("zoom workplace", "Zoom Call"),
        ("zoom.us", "Zoom Call"),
        ("microsoft teams", "Microsoft Teams Call"),
        ("| teams", "Microsoft Teams Call"),
        ("webex", "Webex Meeting"),
        ("whereby", "Whereby Call"),
        ("jitsi meet", "Jitsi Call"),
        ("riverside", "Riverside Call"),
        ("gather", "Gather Call"),
        ("discord", "Discord Call"),
        ("daily.co", "Daily Call"),
        ("cal video", "Cal Video Call"),
        ("bluejeans", "BlueJeans Call"),
        ("amazon chime", "Chime Call"),
        ("facetime", "FaceTime Call"),
        ("tuple", "Tuple Call"),
        ("huddle", "Slack Huddle"),
    ]

    /// Normalizes Electron/Chromium/WebKit/Zoom helper bundle IDs to their parent app family.
    static func normalizeFamily(_ rawBundleID: String) -> String {
        var id = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return "" }

        if id.hasPrefix("com.apple.webkit.") {
            return "com.apple.safari"
        }
        if id == "us.zoom.caphost" || id == "us.zoom.airhost" || id.hasPrefix("us.zoom.xos.") {
            return "us.zoom.xos"
        }
        if id.hasPrefix("com.microsoft.teams2.") {
            return "com.microsoft.teams2"
        }
        if id.hasPrefix("com.microsoft.teams.") {
            return "com.microsoft.teams"
        }

        let helperSuffixes = [
            ".helper.renderer",
            ".helper.gpu",
            ".helper.plugin",
            ".helper.alerts",
            ".helper.audio",
            ".helper",
            ".renderer",
            ".gpu",
            ".webcontent",
            ".audio",
        ]
        var stripped = true
        while stripped {
            stripped = false
            for suffix in helperSuffixes where id.hasSuffix(suffix) {
                id = String(id.dropLast(suffix.count))
                stripped = true
            }
        }
        return id
    }

    static func isIgnored(_ bundleID: String) -> Bool {
        let lower = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }
        return ignoredBundlePrefixes.contains { lower == $0 || lower.hasPrefix($0 + ".") }
    }

    static func isMonitoredCandidate(_ bundleID: String) -> Bool {
        guard !isIgnored(bundleID) else { return false }
        let family = normalizeFamily(bundleID)
        return dedicatedApps[family] != nil || browsers[family] != nil
    }

    /// Inspects browser window titles (only called while that browser's mic input is active).
    static func browserMeetingTitle(in windowTitles: [String]) -> String? {
        for rawTitle in windowTitles {
            let lower = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.isEmpty else { continue }
            if let match = browserTitlePatterns.first(where: { lower.contains($0.needle) }) {
                return match.title
            }
        }
        return nil
    }

    /// Evaluates current Core Audio process states into at most one active `DetectedMeetingCall`.
    /// Native conferencing apps take precedence over browsers.
    static func detect(
        processes: [AudioProcessInfo],
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        browserWindowTitles: [String: [String]] = [:],
        hasActiveCalendarEvent: Bool = false
    ) -> DetectedMeetingCall? {
        struct FamilyAudio {
            var input = false
            var output = false
        }

        var byFamily: [String: FamilyAudio] = [:]
        for proc in processes {
            guard proc.pid != ownPID, !isIgnored(proc.bundleID) else { continue }
            let family = normalizeFamily(proc.bundleID)
            guard !family.isEmpty else { continue }
            var agg = byFamily[family] ?? FamilyAudio()
            agg.input = agg.input || proc.isRunningInput
            agg.output = agg.output || proc.isRunningOutput
            byFamily[family] = agg
        }

        // 1. Dedicated native conferencing apps with active microphone input.
        for family in byFamily.keys.sorted() {
            guard let audio = byFamily[family], audio.input,
                  let descriptor = dedicatedApps[family] else { continue }
            return DetectedMeetingCall(
                key: family,
                appName: descriptor.appName,
                suggestedTitle: descriptor.suggestedTitle,
                isBrowser: false
            )
        }

        // 2. Web browsers with active microphone input + meeting signal:
        //    (a) a window title matching a meeting service (e.g. Google Meet, Zoom, Teams), OR
        //    (b) simultaneous browser mic input AND browser audio output (handles switched tabs), OR
        //    (c) active scheduled calendar event while browser mic is open.
        for family in byFamily.keys.sorted() {
            guard let audio = byFamily[family], audio.input,
                  let browserName = browsers[family] else { continue }
            let titles = browserWindowTitles[family] ?? []
            if let matchedTitle = browserMeetingTitle(in: titles) {
                return DetectedMeetingCall(
                    key: family,
                    appName: browserName,
                    suggestedTitle: matchedTitle,
                    isBrowser: true
                )
            }
            if audio.output || hasActiveCalendarEvent {
                return DetectedMeetingCall(
                    key: family,
                    appName: browserName,
                    suggestedTitle: "\(browserName) Call",
                    isBrowser: true
                )
            }
        }

        return nil
    }
}

/// Zero-polling macOS Core Audio live call detector.
/// Subscribes to `kAudioHardwarePropertyProcessObjectList` and per-process
/// `kAudioProcessPropertyIsRunningInput`/`Output` notifications for conferencing apps and browsers.
@MainActor final class MacLiveMeetingDetector: MeetingCallDetecting {
    private final class Engine: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.andre.flowclone.live-meeting-detector", qos: .utility)
        private var started = false
        private var processListBlock: AudioObjectPropertyListenerBlock?
        private var trackedProcessBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
        private var onProcessesChanged: (@Sendable ([AudioProcessInfo]) -> Void)?

        func start(onProcessesChanged: @escaping @Sendable ([AudioProcessInfo]) -> Void) {
            queue.async { [weak self] in
                guard let self, !self.started else { return }
                self.started = true
                self.onProcessesChanged = onProcessesChanged

                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyProcessObjectList,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.refreshListenersAndNotify()
                }
                self.processListBlock = block
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    self.queue,
                    block
                )
                self.refreshListenersAndNotify()
            }
        }

        func stop() {
            queue.async { [weak self] in
                guard let self, self.started else { return }
                self.started = false
                if let block = self.processListBlock {
                    var address = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyProcessObjectList,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject),
                        &address,
                        self.queue,
                        block
                    )
                    self.processListBlock = nil
                }
                for (objectID, block) in self.trackedProcessBlocks {
                    self.removeProcessListeners(for: objectID, block: block)
                }
                self.trackedProcessBlocks.removeAll()
                self.onProcessesChanged = nil
            }
        }

        func snapshotNow() -> [AudioProcessInfo] {
            Self.readProcesses().map(\.info)
        }

        private func refreshListenersAndNotify() {
            guard started else { return }
            let entries = Self.readProcesses()
            let candidateIDs = Set(entries.compactMap { entry in
                LiveMeetingMatcher.isMonitoredCandidate(entry.info.bundleID) ? entry.objectID : nil
            })

            // Detach listeners for processes that exited.
            for (objectID, block) in trackedProcessBlocks where !candidateIDs.contains(objectID) {
                removeProcessListeners(for: objectID, block: block)
                trackedProcessBlocks.removeValue(forKey: objectID)
            }

            // Attach listeners for newly seen candidate processes.
            for objectID in candidateIDs where trackedProcessBlocks[objectID] == nil {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.notifyCurrentProcesses()
                }
                addProcessListeners(for: objectID, block: block)
                trackedProcessBlocks[objectID] = block
            }

            onProcessesChanged?(entries.map(\.info))
        }

        private func notifyCurrentProcesses() {
            guard started else { return }
            let infos = Self.readProcesses().map(\.info)
            onProcessesChanged?(infos)
        }

        private func addProcessListeners(for objectID: AudioObjectID, block: @escaping AudioObjectPropertyListenerBlock) {
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var addr = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block)
            }
        }

        private func removeProcessListeners(for objectID: AudioObjectID, block: @escaping AudioObjectPropertyListenerBlock) {
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                var addr = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, block)
            }
        }

        private static func readProcesses() -> [(objectID: AudioObjectID, info: AudioProcessInfo)] {
            var listAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddress,
                0,
                nil,
                &dataSize
            ) == noErr, dataSize > 0 else {
                return []
            }
            let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var objectIDs = [AudioObjectID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddress,
                0,
                nil,
                &dataSize,
                &objectIDs
            ) == noErr else {
                return []
            }

            var results: [(AudioObjectID, AudioProcessInfo)] = []
            results.reserveCapacity(objectIDs.count)
            for objectID in objectIDs {
                guard let pid = readPID(objectID), pid > 0 else { continue }
                let bundleID = readBundleID(objectID) ?? ""
                let input = readUInt32(objectID, selector: kAudioProcessPropertyIsRunningInput) != 0
                let output = readUInt32(objectID, selector: kAudioProcessPropertyIsRunningOutput) != 0
                results.append((objectID, AudioProcessInfo(
                    pid: pid,
                    bundleID: bundleID,
                    isRunningInput: input,
                    isRunningOutput: output
                )))
            }
            return results
        }

        private static func readPID(_ objectID: AudioObjectID) -> pid_t? {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &pid) == noErr else { return nil }
            return pid
        }

        private static func readUInt32(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32 {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return 0 }
            return value
        }

        private static func readBundleID(_ objectID: AudioObjectID) -> String? {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfString: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &cfString) == noErr,
                  let unmanaged = cfString else { return nil }
            return unmanaged.takeRetainedValue() as String
        }
    }

    private struct CandidateState: Equatable {
        var input: Bool
        var output: Bool
    }

    private struct BrowserTarget: Sendable {
        let pid: pid_t
        let family: String
    }

    /// Explicit short AX messaging timeout (250 ms) so a busy browser can never hang for 6 s.
    nonisolated static let browserAXTimeout: Float = 0.25

    private let engine = Engine()
    private let axQueue = DispatchQueue(label: "com.andre.flowclone.live-meeting-ax", qos: .utility)
    private var onChange: (@MainActor () -> Void)?
    private var lastProcesses: [AudioProcessInfo] = []
    private var lastCandidateStates: [String: CandidateState] = [:]
    private var cachedBrowserTitles: [String: [String]] = [:]
    private var lastBrowserTitleRefresh: Date = .distantPast
    private var browserTitleRefreshInFlight = false
    private var browserTitleGeneration: UInt64 = 0
    private var active = false

    func start(onChange: @escaping @MainActor () -> Void) {
        guard !suppressHostAccess else { return }
        self.onChange = onChange
        guard !active else { return }
        active = true
        engine.start { [weak self] processes in
            Task { @MainActor [weak self] in
                self?.handleProcessUpdate(processes)
            }
        }
    }

    func stop() {
        active = false
        onChange = nil
        lastCandidateStates = [:]
        lastProcesses = []
        cachedBrowserTitles = [:]
        lastBrowserTitleRefresh = .distantPast
        browserTitleRefreshInFlight = false
        browserTitleGeneration &+= 1
        engine.stop()
    }

    func currentCall(hasActiveCalendarEvent: Bool) -> DetectedMeetingCall? {
        guard !suppressHostAccess else { return nil }
        guard !lastProcesses.isEmpty else { return nil }
        return evaluate(processes: lastProcesses, hasActiveCalendarEvent: hasActiveCalendarEvent)
    }

    private func activeBrowserFamilies(in processes: [AudioProcessInfo]) -> Set<String> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var families = Set<String>()
        for proc in processes where proc.pid != ownPID && proc.isRunningInput && !LiveMeetingMatcher.isIgnored(proc.bundleID) {
            let family = LiveMeetingMatcher.normalizeFamily(proc.bundleID)
            if LiveMeetingMatcher.browsers[family] != nil {
                families.insert(family)
            }
        }
        return families
    }

    private func handleProcessUpdate(_ processes: [AudioProcessInfo]) {
        guard active else { return }
        lastProcesses = processes
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var states: [String: CandidateState] = [:]
        for proc in processes where proc.pid != ownPID && LiveMeetingMatcher.isMonitoredCandidate(proc.bundleID) {
            let family = LiveMeetingMatcher.normalizeFamily(proc.bundleID)
            var existing = states[family] ?? CandidateState(input: false, output: false)
            existing.input = existing.input || proc.isRunningInput
            existing.output = existing.output || proc.isRunningOutput
            states[family] = existing
        }

        let activeBrowsers = activeBrowserFamilies(in: processes)
        if activeBrowsers.isEmpty {
            cachedBrowserTitles = [:]
            lastBrowserTitleRefresh = .distantPast
            browserTitleGeneration &+= 1
            browserTitleRefreshInFlight = false
        } else {
            refreshBrowserTitlesOffMain(for: activeBrowsers)
        }

        if states != lastCandidateStates {
            lastCandidateStates = states
            onChange?()
        }
    }

    private func evaluate(processes: [AudioProcessInfo], hasActiveCalendarEvent: Bool) -> DetectedMeetingCall? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let activeBrowsers = activeBrowserFamilies(in: processes)
        let windowTitles: [String: [String]]
        if activeBrowsers.isEmpty {
            windowTitles = [:]
        } else {
            if !browserTitleRefreshInFlight, Date().timeIntervalSince(lastBrowserTitleRefresh) >= 2.0 {
                refreshBrowserTitlesOffMain(for: activeBrowsers)
            }
            windowTitles = cachedBrowserTitles.filter { activeBrowsers.contains($0.key) }
        }
        return LiveMeetingMatcher.detect(
            processes: processes,
            ownPID: ownPID,
            browserWindowTitles: windowTitles,
            hasActiveCalendarEvent: hasActiveCalendarEvent
        )
    }

    private func refreshBrowserTitlesOffMain(for families: Set<String>) {
        guard active, !families.isEmpty, !browserTitleRefreshInFlight else { return }
        let targets: [BrowserTarget] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            let family = LiveMeetingMatcher.normalizeFamily(bundleID)
            guard families.contains(family) else { return nil }
            return BrowserTarget(pid: app.processIdentifier, family: family)
        }
        guard !targets.isEmpty else {
            cachedBrowserTitles = [:]
            return
        }
        browserTitleRefreshInFlight = true
        browserTitleGeneration &+= 1
        let generation = browserTitleGeneration
        axQueue.async { [weak self] in
            let titles = Self.readBrowserWindowTitles(for: targets, timeoutSeconds: Self.browserAXTimeout)
            Task { @MainActor [weak self] in
                guard let self, self.active, self.browserTitleGeneration == generation else { return }
                self.browserTitleRefreshInFlight = false
                self.lastBrowserTitleRefresh = Date()
                if self.cachedBrowserTitles != titles {
                    self.cachedBrowserTitles = titles
                    self.onChange?()
                }
            }
        }
    }

    private nonisolated static func readBrowserWindowTitles(
        for targets: [BrowserTarget],
        timeoutSeconds: Float = browserAXTimeout
    ) -> [String: [String]] {
        guard AXIsProcessTrusted() else { return [:] }
        var titlesByFamily: [String: [String]] = [:]
        for target in targets {
            let appElement = AXUIElementCreateApplication(target.pid)
            _ = AXUIElementSetMessagingTimeout(appElement, timeoutSeconds)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }
            var titles: [String] = []
            for window in windows.prefix(12) {
                _ = AXUIElementSetMessagingTimeout(window, timeoutSeconds)
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, !title.isEmpty {
                    titles.append(title)
                }
            }
            if !titles.isEmpty {
                titlesByFamily[target.family, default: []].append(contentsOf: titles)
            }
        }
        return titlesByFamily
    }
}
