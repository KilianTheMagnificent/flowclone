// Hold-to-talk hotkey: bare fn (kc63), Right Cmd/Opt, or Ctrl+Opt, plus the F1 hands-free latch.
// The tap callback does nothing but hop onto the session queue — slow work in the
// callback is what causes the tap timeouts we then have to recover from. Its only
// synchronous work is bounded lock bookkeeping, one main-thread frontmost-app snapshot on
// an accepted press, plus the two swallow decisions which an enqueue cannot make: kc63 /
// configured shortcuts, and Esc while a recording is live. Accessibility work never runs here.
import Cocoa
import os

enum HotkeyEdge: Equatable {
    case down(String)
    case up
    case cancel(String)
    /// F1/F-3: the session that just started is hands-free. Emitted immediately after the
    /// `.down` that latched it, so Pipeline attaches the cap and the cue to a live session
    /// rather than the monitor hiding a second mode inside itself.
    case latched
}

private let hotkeyCallback: CGEventTapCallBack = { _, type, event, info in
    guard let info else { return Unmanaged.passUnretained(event) }
    let m = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
    return m.handleTapEvent(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

final class HotkeyMonitor: @unchecked Sendable {   // state is confined to `queue`
    /// F1: down→up within this is a tap, not a hold. Anything longer is a hold and takes
    /// the unchanged finish-on-release path — the fast path gains nothing by construction.
    private static let tapMaxMS = 350.0
    /// F1: how long an arming tap leaves hands-free one press away.
    private static let armWindow = 0.400

    private let queue: DispatchQueue
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    // All state below is confined to `queue`.
    private var fnHeld = false
    private var comboHeld = false
    private var heldBy: String?
    private var cancelled = false
    /// F1 hands-free. `latched` outlives the press that started it; `swallowHeld` is the
    /// source still physically down from the press that latched or stopped it, whose
    /// release must not read as the end of a hold.
    private var latched = false
    private var swallowHeld: String?
    private var armed = false
    private var armToken = 0
    private var downAtMS = 0.0
    private var lastPressWasTap = false
    /// Created at the physical flagsChanged boundary and consumed by Pipeline with the
    /// accepted `.down` edge on this same queue.
    private var pendingTargetLease: Paster.TargetLease?

    private struct CallbackHotkeyState {
        var fnDown = false
        var comboDown = false
    }
    /// Event-tap-only transition memory. It prevents unrelated modifier changes while
    /// Ctrl+Opt remains held from creating redundant leases.
    private let callbackHotkeyState = OSAllocatedUnfairLock(
        initialState: CallbackHotkeyState())

    /// F1/A-1: mirror of "a capture is live" — the one piece of session state the
    /// event-tap thread reads synchronously. Written only from `queue`, and only by the
    /// Pipeline: key state is not proof a recording exists. A press the Pipeline refuses
    /// (model not loaded, previous dictation still delivering, cold mic prime) leaves the
    /// key held with nothing to discard, and swallowing Esc there made it do nothing.
    private let escapeActive = OSAllocatedUnfairLock(initialState: false)

    /// The tap-vs-hold decision uses an injected monotonic clock. Immutable after init;
    /// production uses DispatchTime and deterministic tests can supply a synthetic clock.
    private let clockMS: @Sendable () -> Double

    /// Called on `queue`.
    var onEdge: ((HotkeyEdge) -> Void)?
    /// Main event-loop callback, with the target lease already bound to this action.
    var onAction: ((FlowAction, Paster.TargetLease?) -> Void)?
    /// Optional handler for `ShortcutAction` bindings (e.g. `.transformSelection`).
    /// Defaults to opening `TransformController.shared.begin(spoken: false, lease:)` on main.
    var onShortcutAction: ((ShortcutAction, Paster.TargetLease?) -> Void)?
    private var shortcutRouter = ShortcutRouter()

    /// True once the tap has actually delivered an event — the only honest proof it works
    /// (a permissionless tap returns a valid port and stays silent, RESEARCH.md §5).
    /// Written by the callback, which runs on the main runloop; read from main.
    var sawEvent = false

    init(queue: DispatchQueue,
         clockMS: @escaping @Sendable () -> Double = {
             Double(DispatchTime.now().uptimeNanoseconds) / 1e6
         }) {
        self.queue = queue
        self.clockMS = clockMS
    }

    var isRunning: Bool { port != nil }

    func start() {
        guard port == nil else { return }
        if handsfreeSession { Handsfree.log("blocked global hotkey event tap"); return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: hotkeyCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("TAP CREATE FAILED — Accessibility not granted (a .listenOnly tap would false-green)")
            return
        }
        port = p
        source = CFMachPortCreateRunLoopSource(nil, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        log("hotkey tap started — hold fn (kc63 swallowed) or Ctrl+Opt")
    }

    func stop() {
        guard let p = port else { return }
        CGEvent.tapEnable(tap: p, enable: false)
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        CFMachPortInvalidate(p)
        port = nil
        source = nil
        log("hotkey tap stopped")
    }

    // MARK: - Callback entry points (event-tap thread; enqueue only)

    /// Returns `true` when the event is swallowed (`nil` from the event tap) and `false`
    /// when it passes through to the frontmost app. `FocusInteractionEpoch` advances ONLY
    /// on unconsumed physical input that passes past both `Escape` and `configuredEvent`.
    @discardableResult
    func handleTapEvent(type: CGEventType, event: CGEvent,
                        bindings: [ShortcutBinding]? = nil) -> Bool {
        // redteam M1: ignore our own synthetic Cmd+V / Cmd+C. It re-enters this same-process
        // session tap. Filter before sawEvent and focus-epoch tracking so synthetic events count as neither.
        if event.getIntegerValueField(.eventSourceUserData) == Paster.sourceTag {
            return false
        }
        sawEvent = true
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            tapDisabled(timeout: type == .tapDisabledByTimeout)
            return true
        case .flagsChanged, .keyDown, .keyUp:
            if !ShortcutStore.shared.recording {
                // F1/A-1: Esc discards a live dictation, and the swallow has to be decided HERE.
                // Swallowed Escape never reaches the frontmost app and must not advance focusEpoch.
                if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
                   escapeShouldSwallow() {
                    escapePressed()
                    return true
                }
                if configuredEvent(type, event, bindings: bindings ?? ShortcutStore.shared.bindings) {
                    return true
                }
            }
        default:
            break
        }
        if type == .keyDown {
            // Fence any target capture spanning unconsumed physical input which may change focus.
            FocusInteractionEpoch.notePhysicalFocusInput()
        } else if (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown),
                  !Overlay.isNonActivatingOverlayMouseEvent(event) {
            FocusInteractionEpoch.notePhysicalFocusInput()
        }
        return false
    }

    /// F1/A-1: the synchronous swallow decision. One uncontended lock-free read, no queue
    /// hop — Esc is consumed only while a held or latched recording is actually running,
    /// so an idle Esc still reaches the frontmost app untouched.
    func escapeShouldSwallow() -> Bool { escapeActive.withLock { $0 } }

    /// Session queue. The Pipeline sets this when a capture actually starts and clears it
    /// on every path that ends or refuses one — see `escapeActive`.
    func setCaptureActive(_ active: Bool) {
        escapeActive.withLock { $0 = active }
    }

    /// Session queue. The lease was created on the event-tap thread; taking it here does no
    /// target work and makes a missing handoff fail closed in Pipeline.
    func takeTargetLease() -> Paster.TargetLease? {
        defer { pendingTargetLease = nil }
        return pendingTargetLease
    }

    fileprivate func configuredEvent(_ type: CGEventType, _ event: CGEvent,
                                     bindings: [ShortcutBinding]) -> Bool {
        let result = shortcutRouter.event(
            type: type,
            key: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            bindings: bindings)
        for slot in result.cancelledSlots {
            cancelSlot(slot)
        }
        if result.chordContaminated, result.cancelledSlots.isEmpty {
            chordContaminated()
        }
        for (slot, down) in result.held {
            if slot == 0 { fnChanged(down: down) } else { modifiersChanged(down) }
        }
        for action in result.actions {
            let lease = Paster.beginTargetCaptureAtPhysicalEventBoundary(app: PasteTarget.AppIdentity.frontmost())
            onAction?(action, lease)
        }
        for shortcutAction in result.shortcutActions {
            let lease = Paster.beginTargetCaptureAtPhysicalEventBoundary(app: PasteTarget.AppIdentity.frontmost())
            if let onShortcutAction {
                onShortcutAction(shortcutAction, lease)
            } else {
                DispatchQueue.main.async {
                    switch shortcutAction {
                    case .transformSelection:
                        TransformController.shared.begin(spoken: false, lease: lease)
                    }
                }
            }
        }
        if type == .keyDown, !result.consumed, result.cancelledSlots.isEmpty {
            sawKeyDown()
        }
        return result.consumed
    }

    private func cancelSlot(_ slot: Int) {
        callbackHotkeyState.withLock { state in
            if slot == 0 { state.fnDown = false } else { state.comboDown = false }
        }
        queue.async {
            if slot == 0 { self.fnHeld = false } else { self.comboHeld = false }
            self.pendingTargetLease = nil
            self.lastPressWasTap = false
            if self.armed {
                self.disarm()
                log("hands-free disarmed — modifier chord")
            }
            if self.heldBy != nil {
                self.heldBy = nil
                self.cancelled = self.fnHeld || self.comboHeld
                self.onEdge?(.cancel("modifier chord"))
            }
        }
    }

    private func chordContaminated() {
        queue.async {
            self.lastPressWasTap = false
            if self.armed {
                self.disarm()
                log("hands-free disarmed — non-dictation chord")
            }
        }
    }

    fileprivate func fnChanged(down: Bool) {
        let began = callbackHotkeyState.withLock { state in
            let began = down && !state.fnDown
            state.fnDown = down
            return began
        }
        // This callback is installed on the main run loop. NSWorkspace is sampled here,
        // before the session hop; synchronous AX remains forbidden and runs elsewhere.
        let boundaryApp = began ? PasteTarget.AppIdentity.frontmost() : nil
        let lease = began ? Paster.beginTargetCaptureAtPhysicalEventBoundary(
            app: boundaryApp) : nil
        queue.async {
            self.fnHeld = down
            if let lease { self.pendingTargetLease = lease }
            self.update()
        }
    }

    fileprivate func modifiersChanged(_ combo: Bool) {
        let began = callbackHotkeyState.withLock { state in
            let began = combo && !state.comboDown
            state.comboDown = combo
            return began
        }
        let boundaryApp = began ? PasteTarget.AppIdentity.frontmost() : nil
        let lease = began ? Paster.beginTargetCaptureAtPhysicalEventBoundary(
            app: boundaryApp) : nil
        queue.async {
            self.comboHeld = combo
            if let lease { self.pendingTargetLease = lease }
            self.update()
        }
    }

    fileprivate func sawKeyDown() {
        queue.async {
            // F1: any other key inside the arm window withdraws the offer.
            if self.armed {
                self.disarm()
                log("hands-free disarmed — another key was pressed")
            }
            self.lastPressWasTap = false
            guard self.heldBy != nil else { return }
            // fn+C etc: the combo is a shortcut, not dictation. Let the key through.
            self.heldBy = nil
            self.cancelled = self.fnHeld || self.comboHeld
            self.onEdge?(.cancel("key pressed while held"))
        }
    }

    func escapePressed() {
        queue.async {
            if self.latched {
                self.latched = false
                self.onEdge?(.cancel("escape"))
            } else if self.heldBy != nil {
                self.heldBy = nil
                self.cancelled = self.fnHeld || self.comboHeld
                self.onEdge?(.cancel("escape"))
            }
            self.lastPressWasTap = false
            self.disarm()
        }
    }

    fileprivate func tapDisabled(timeout: Bool) {
        // Input delivered while the tap was disabled is unknowable. Invalidate every
        // in-flight/app-only lease synchronously before re-enabling instead of assuming no
        // same-app focus change occurred in the blind window.
        Self.invalidateTargetCapturesForTapReset()
        shortcutRouter.reset()
        callbackHotkeyState.withLock {
            $0.fnDown = false
            $0.comboDown = false
        }
        queue.async {
            if let p = self.port { CGEvent.tapEnable(tap: p, enable: true) }
            log("tap re-enabled after \(timeout ? "tapDisabledByTimeout" : "tapDisabledByUserInput")")
            if self.heldBy != nil {
                self.heldBy = nil
                self.fnHeld = false
                self.comboHeld = false
                self.cancelled = true
                self.onEdge?(.cancel("tap disabled"))
                self.update()
            } else if self.latched {
                log("hands-free session kept across the tap reset")
            }
        }
    }

    static func invalidateTargetCapturesForTapReset() {
        FocusInteractionEpoch.notePhysicalFocusInput()
    }

    // MARK: - Hands-free (F1). Session queue — Pipeline calls these from `handle`.

    /// True while a hands-free session is running. Session queue.
    var isLatched: Bool { latched }

    /// The arming tap (F-2, corrected per R-1): called by `Pipeline` only from the
    /// no-speech branch of a finished press.
    func armIfTap() {
        guard lastPressWasTap, !latched, heldBy == nil else { return }
        lastPressWasTap = false
        armed = true
        armToken &+= 1
        let token = armToken
        log("hands-free armed — press again within \(Int(Self.armWindow * 1000))ms to latch")
        queue.asyncAfter(deadline: .now() + Self.armWindow) { [weak self] in
            guard let self, self.armed, self.armToken == token else { return }
            self.armed = false
            log("hands-free arm window expired")
        }
    }

    /// The second tap of a double-tap and the F2 menu item land here. Session queue.
    func startLatched(_ source: String, targetLease: Paster.TargetLease? = nil) {
        guard !latched, heldBy == nil else { return }
        if let targetLease { pendingTargetLease = targetLease }
        disarm()
        latched = true
        lastPressWasTap = false
        log("hands-free latched (\(source)) — press again to finish, Esc to discard")
        onEdge?(.down(source))
        onEdge?(.latched)
    }

    /// Finish a hands-free session: the same `.up` a key release produces. Session queue.
    func stopLatched() {
        guard latched else { return }
        latched = false
        lastPressWasTap = false
        log("hands-free stopped")
        onEdge?(.up)
    }

    /// R-2: any aborted, refused or cancelled session drops all hands-free state.
    func clearHandsFree(_ why: String) {
        lastPressWasTap = false
        guard armed || latched else { return }
        disarm()
        latched = false
        log("hands-free cleared — \(why)")
    }

    private func disarm() {
        armed = false
        armToken &+= 1
    }

    // MARK: - Edge generator (session queue)

    private func update() {
        if cancelled {
            if !fnHeld && !comboHeld { cancelled = false }
            return
        }
        if let s = swallowHeld {
            guard !held(s) else { return }
            swallowHeld = nil
        }
        if let by = heldBy {
            if !held(by) {
                heldBy = nil
                lastPressWasTap = clockMS() - downAtMS <= Self.tapMaxMS
                onEdge?(.up)
            }
        } else if fnHeld {
            press("fn")
        } else if comboHeld {
            press("ctrl+opt")
        }
    }

    private func held(_ source: String) -> Bool { source == "fn" ? fnHeld : comboHeld }

    private func press(_ source: String) {
        if latched {
            pendingTargetLease = nil
            swallowHeld = source
            stopLatched()
            return
        }
        if armed {
            swallowHeld = source
            startLatched(source)
            return
        }
        heldBy = source
        downAtMS = clockMS()
        onEdge?(.down(source))
    }
}
