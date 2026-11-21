import Cocoa
import ApplicationServices

/// Dock's AXList tracks the actual surface, including auto-hide and magnification.
/// On macOS 27 its CGWindow bounds span the whole display, and AXMoved/AXResized
/// notifications are unsupported. Read only geometry, off the UI/audio thread.
private actor DockGeometryReader {
    private var pid: pid_t = 0
    private var list: AXUIElement?

    func read(pid newPID: pid_t) -> CGRect? {
        guard newPID > 0, AXIsProcessTrusted() else { return nil }
        if pid != newPID { pid = newPID; list = nil }
        let deadline = AXClient.Deadline(total: 0.035, perCall: 0.015)
        if list == nil {
            let app = AXUIElementCreateApplication(pid)
            guard deadline.configure(app) else { return nil }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(app, kAXChildrenAttribute as CFString,
                                                  0, 32, &children) == .success else { return nil }
            for child in children as? [AXUIElement] ?? [] {
                guard deadline.configure(child) else { return nil }
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                   role as? String == kAXListRole { list = child; break }
            }
        }
        guard let list, deadline.configure(list) else { return nil }
        var raw: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(list, attributes, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == 2,
              CFGetTypeID(values[0]) == AXValueGetTypeID(),
              CFGetTypeID(values[1]) == AXValueGetTypeID() else {
            self.list = nil
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(values[0] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(values[1] as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// Static non-auto-hidden Docks already inset `NSScreen.visibleFrame`, so they require zero
/// timers, zero mouse monitors, and zero AX IPC. Short-lived 20 Hz transition sampling runs
/// only when Dock auto-hide is enabled and the pointer crosses the bottom reveal/hide zone,
/// stopping as soon as the Dock height stabilizes (~300 ms).
@MainActor
final class DockTracker {
    static let stabilizationDuration: TimeInterval = 0.30
    static let bottomTriggerHeight: CGFloat = 80

    var onChange: ((NSRect?) -> Void)?
    private(set) var frame: NSRect?

    /// Test seams for deterministic verification without mutating system Dock settings.
    var screenProvider: () -> [(frame: NSRect, visibleFrame: NSRect)] = {
        NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
    }
    var pointerProvider: () -> NSPoint = { NSEvent.mouseLocation }
    var uptimeProvider: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var geometryProvider: (@Sendable (pid_t) async -> CGRect?)?
    var dockPIDProvider: () -> pid_t = {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier ?? 0
    }

    private final class TrackerResources: @unchecked Sendable {
        var globalMonitor: Any?
        var localMonitor: Any?
        var monitorsInstalled = false
        var screenObserver: NSObjectProtocol?
        var timer: Timer?

        func removeMonitors() {
            monitorsInstalled = false
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
        }

        func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        func teardown() {
            if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
            screenObserver = nil
            removeMonitors()
            stopTimer()
        }
    }

    private let reader = DockGeometryReader()
    private let resources = TrackerResources()
    private var enabled = false
    private var sampling = false
    private var generation = 0
    private var nextSampleAt: TimeInterval = 0
    private var lastSuccessAt: TimeInterval = 0
    private var lastSampledFrame: NSRect?
    private var hasSampleBaseline = false
    private var lastFrameChangeAt: TimeInterval = 0
    private var wasPointerInTriggerZone = false

    var hasActiveTimer: Bool { resources.timer != nil }
    var hasMouseMonitors: Bool { resources.monitorsInstalled || resources.globalMonitor != nil || resources.localMonitor != nil }

    init(observeScreenChanges: Bool = true) {
        if observeScreenChanges {
            resources.screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reconfigureForScreenParameters() }
            }
        }
    }

    deinit {
        resources.teardown()
    }

    /// True when neither a bottom nor a side permanent Dock insets `visibleFrame`.
    /// Menu bar insets `maxY` only, so `minY`, `minX`, and `maxX` match `screenFrame`
    /// when Dock auto-hide is enabled.
    nonisolated static func hasPermanentDockInset(screenFrame: NSRect, visibleFrame: NSRect) -> Bool {
        (visibleFrame.minY - screenFrame.minY) > 1
            || (visibleFrame.minX - screenFrame.minX) > 1
            || (screenFrame.maxX - visibleFrame.maxX) > 1
    }

    nonisolated static func isAutoHideEnabled(screenFrame: NSRect, visibleFrame: NSRect) -> Bool {
        !hasPermanentDockInset(screenFrame: screenFrame, visibleFrame: visibleFrame)
    }

    nonisolated static func isAutoHideEnabled(screens: [(frame: NSRect, visibleFrame: NSRect)]) -> Bool {
        !screens.isEmpty && !screens.contains {
            hasPermanentDockInset(screenFrame: $0.frame, visibleFrame: $0.visibleFrame)
        }
    }

    var isAutoHideActive: Bool {
        Self.isAutoHideEnabled(screens: screenProvider())
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        if enabled, handsfreeSession, geometryProvider == nil {
            Handsfree.log("blocked Dock tracking (global monitor, AX)")
            return
        }
        self.enabled = enabled
        generation += 1
        sampling = false
        if enabled {
            reconfigureForScreenParameters()
        } else {
            removeMonitors()
            stopTimer()
            wasPointerInTriggerZone = false
        }
    }

    func refresh() {
        guard enabled else { return }
        reconfigureForScreenParameters()
    }

    func reconfigureForScreenParameters() {
        guard enabled else { return }
        guard isAutoHideActive else {
            // Static non-auto-hidden Dock: NSScreen.visibleFrame already gives exact Dock
            // clearance. Run zero timers, zero mouse monitors, and zero AX queries.
            generation += 1
            sampling = false
            removeMonitors()
            stopTimer()
            wasPointerInTriggerZone = false
            updateFrame(nil)
            return
        }
        installMonitorsIfNeeded()
        let inTrigger = pointerNearBottom
        wasPointerInTriggerZone = inTrigger
        if inTrigger || dockVisible {
            beginTransitionSampling()
        } else {
            stopTimer()
        }
    }

    /// Exposed internally so unit tests can drive pointer transitions deterministically.
    func handlePointerMoved() {
        guard enabled else { return }
        guard isAutoHideActive else {
            removeMonitors()
            stopTimer()
            return
        }
        let inTrigger = pointerNearBottom
        let crossedIntoBottom = inTrigger && !wasPointerInTriggerZone
        let crossedOutWhileVisible = !inTrigger && dockVisible && (wasPointerInTriggerZone || resources.timer == nil)
        wasPointerInTriggerZone = inTrigger
        if crossedIntoBottom || crossedOutWhileVisible {
            beginTransitionSampling()
        }
    }

    private func installMonitorsIfNeeded() {
        guard !resources.monitorsInstalled else { return }
        resources.monitorsInstalled = true
        guard !handsfreeSession else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .otherMouseDragged, .mouseEntered]
        resources.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointerMoved() }
        }
        resources.localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointerMoved() }
            return event
        }
    }

    private func removeMonitors() {
        resources.removeMonitors()
    }

    private var pointerNearBottom: Bool {
        let pointer = pointerProvider()
        let screens = screenProvider()
        return screens.contains { screen in
            let activeHeight = max(Self.bottomTriggerHeight, (frame.map { $0.maxY - screen.frame.minY + 24 } ?? 0))
            return screen.frame.contains(pointer) && pointer.y < screen.frame.minY + activeHeight
        }
    }

    private var dockVisible: Bool {
        guard let frame else { return false }
        return screenProvider().contains { PillPosition.isBottomDock(frame, on: $0.frame) }
    }

    private func beginTransitionSampling() {
        let now = uptimeProvider()
        nextSampleAt = 0
        hasSampleBaseline = false
        lastFrameChangeAt = now
        startTimer()
        sample()
    }

    private func startTimer() {
        guard resources.timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        resources.timer = timer
    }

    private func stopTimer() {
        resources.stopTimer()
    }

    /// Executed on each transition tick; also callable from tests to advance sampling.
    func sampleOnceForTesting() async {
        await performSample()
    }

    private func sample() {
        let now = uptimeProvider()
        guard enabled, isAutoHideActive, !sampling, now >= nextSampleAt else { return }
        Task { [weak self] in
            await self?.performSample()
        }
    }

    private func performSample() async {
        let startNow = uptimeProvider()
        guard enabled, isAutoHideActive, !sampling, startNow >= nextSampleAt else { return }
        sampling = true
        let sampleGeneration = generation
        let pid = dockPIDProvider()
        let customReader = geometryProvider
        let bounds: CGRect?
        if let customReader {
            bounds = await customReader(pid)
        } else {
            bounds = await reader.read(pid: pid)
        }
        sampling = false
        guard enabled, sampleGeneration == generation, isAutoHideActive else { return }
        let now = uptimeProvider()
        let screens = screenProvider()
        let resolved: NSRect?
        if let bounds, let main = screens.first {
            lastSuccessAt = now
            let rect = Overlay.appKitRect(fromWindowBounds: bounds, mainScreenHeight: main.frame.height)
            // Hidden bounds may keep changing width as Dock items change. They
            // are all the same placement state and must not trigger pill resizes.
            let visible = screens.contains { PillPosition.isBottomDock(rect, on: $0.frame) }
            resolved = visible ? rect : nil
            updateFrame(resolved)
        } else {
            // A slow/restarting Dock never stalls drawing or causes a request backlog.
            nextSampleAt = now + 1
            if now - lastSuccessAt > 1 { updateFrame(nil) }
            resolved = frame
        }

        if !hasSampleBaseline || !Self.framesSettledEqual(lastSampledFrame, resolved) {
            hasSampleBaseline = true
            lastSampledFrame = resolved
            lastFrameChangeAt = now
        } else if now - lastFrameChangeAt >= Self.stabilizationDuration {
            // Dock height has remained stable for >=300 ms — stop polling immediately.
            stopTimer()
            return
        }

        if !pointerNearBottom && !dockVisible && hasSampleBaseline && now - lastFrameChangeAt >= Self.stabilizationDuration {
            stopTimer()
        }
    }

    nonisolated static func framesSettledEqual(_ lhs: NSRect?, _ rhs: NSRect?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return abs(a.minY - b.minY) <= 0.5 && abs(a.height - b.height) <= 0.5
        default:
            return false
        }
    }

    private func updateFrame(_ frame: NSRect?) {
        guard frame != self.frame else { return }
        self.frame = frame
        onChange?(frame)
    }
}
