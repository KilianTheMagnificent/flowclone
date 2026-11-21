// Text insertion: pasteboard + synthetic Cmd+V, marker-guarded restore.
// (RESEARCH.md §5 — AX-write and per-character typing are documented dead ends.)
// redteam M1: runs on its OWN serial queue — the sleeps must not block the session queue,
// which is the queue that delivers hotkey edges.
import Carbon
import Cocoa
import os

/// Monotonic evidence that physical input capable of changing focus occurred. The event-tap
/// callback does one tiny unfair-lock increment; AX and AppKit work never runs there.
enum FocusInteractionEpoch {
    private static let state = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func snapshot() -> UInt64 { state.withLock { $0 } }

    static func notePhysicalFocusInput() {
        state.withLock { $0 &+= 1 }
    }
}

enum Paster {
    static let marker = NSPasteboard.PasteboardType("com.andre.flowclone.marker")
    // nspasteboard.org opt-out convention — attached ONLY on temporary internal Cmd+V / Cmd+C
    // pasteboard transport writes so clipboard managers skip transient transport payloads, while
    // explicit user-initiated Copy writes remain visible to Universal Clipboard & managers.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// redteam M1: tag on our synthetic Cmd+V / Cmd+C so the hotkey tap can ignore its own events.
    static let sourceTag: Int64 = 0x464C4F57
    /// Delay after Cmd+V before restoring the user's pre-dictation clipboard on `.clipboardConsumed`.
    static let delayedClipboardRestoreDelay: TimeInterval = 0.350

    enum Acknowledgement: Equatable, Sendable {
        case targetConfirmed(PasteTarget.ConfirmedInsertion)
        case clipboardConsumed
    }

    enum Recovery: Equatable, Sendable {
        case transcriptOnClipboard
        case historyOnly
        case clipboardUntouched
    }

    enum DeliveryResult: Sendable {
        case posted(DispatchTime, Acknowledgement, preserved: Bool)
        case ambiguous(DispatchTime, Recovery, String)
        case notPosted(Recovery, String)
        case skippedEmpty
    }

    private static let queue = DispatchQueue(label: "com.andre.flowclone.paste")
    static let settlingDelay: TimeInterval = 0.020
    static let acknowledgementCap: TimeInterval = 1.0

    // MARK: - Keyboard Layout Keycode Resolution (QWERTY, Dvorak, Colemak, AZERTY, etc.)

    private struct KeyboardLayoutCache {
        var vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        var cKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_C)
        var observing = false
        var populated = false
    }

    private static let layoutCache = OSAllocatedUnfairLock(initialState: KeyboardLayoutCache())

    static func refreshKeyboardLayoutCacheIfMainThread() {
        guard Thread.isMainThread else { return }
        let shouldObserve = layoutCache.withLock { state -> Bool in
            if state.observing { return false }
            state.observing = true
            return true
        }
        if shouldObserve {
            NotificationCenter.default.addObserver(
                forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil, queue: .main
            ) { _ in
                updateCachedKeyCodesOnMain()
            }
        }
        updateCachedKeyCodesOnMain()
    }

    private static func updateCachedKeyCodesOnMain() {
        guard Thread.isMainThread else { return }
        let v = resolveFromCurrentInputSource(character: "v", fallback: CGKeyCode(kVK_ANSI_V))
        let c = resolveFromCurrentInputSource(character: "c", fallback: CGKeyCode(kVK_ANSI_C))
        layoutCache.withLock {
            $0.vKeyCode = v
            $0.cKeyCode = c
            $0.populated = true
        }
    }

    private static func resolveFromCurrentInputSource(character: Character,
                                                      fallback: CGKeyCode) -> CGKeyCode {
        if let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() {
            let resolved = virtualKeyCode(for: character, inputSource: current, fallback: UInt16.max)
            if resolved != UInt16.max { return resolved }
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            return virtualKeyCode(for: character, inputSource: ascii, fallback: fallback)
        }
        return fallback
    }

    static func currentVirtualKeyCode(for character: Character, fallback: CGKeyCode) -> CGKeyCode {
        if Thread.isMainThread {
            refreshKeyboardLayoutCacheIfMainThread()
        }
        let lower = String(character).lowercased()
        return layoutCache.withLock { state in
            guard state.populated else { return fallback }
            if lower == "v" { return state.vKeyCode }
            if lower == "c" { return state.cKeyCode }
            return fallback
        }
    }

    static func virtualKeyCode(for character: Character,
                               inputSource: TISInputSource,
                               fallback: CGKeyCode) -> CGKeyCode {
        guard let rawPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let cfData = unsafeBitCast(rawPtr, to: CFData.self)
        let data = cfData as Data
        return virtualKeyCode(for: character, layoutData: data, fallback: fallback)
    }

    /// Resolves the virtual keycode that produces `character` under Command (`cmdKey`) first —
    /// handling Dvorak, Dvorak-QWERTY-⌘, Colemak, AZERTY, BÉPO, and Latin-Cmd layers on non-Latin
    /// layouts — then falls back to the unmodified layer, and finally `fallback`.
    static func virtualKeyCode(for character: Character,
                               layoutData: Data,
                               fallback: CGKeyCode) -> CGKeyCode {
        guard !layoutData.isEmpty else { return fallback }
        let wanted = String(character).lowercased()
        let cmdModifierState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { rawBuffer -> CGKeyCode in
            guard let baseAddress = rawBuffer.baseAddress else { return fallback }
            let layoutPtr = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            let keyboardType = UInt32(LMGetKbdType())
            for modifierState in [cmdModifierState, UInt32(0)] {
                for code in UInt16(0)..<UInt16(128) {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var actualLength: Int = 0
                    let status = UCKeyTranslate(
                        layoutPtr,
                        code,
                        UInt16(kUCKeyActionDown),
                        modifierState,
                        keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &actualLength,
                        &chars
                    )
                    guard status == noErr, actualLength > 0 else { continue }
                    let produced = String(utf16CodeUnits: chars, count: actualLength).lowercased()
                    if produced == wanted {
                        return CGKeyCode(code)
                    }
                }
            }
            return fallback
        }
    }

    // MARK: - Timing & Promise Helpers

    static func acknowledgementDeadline(postedAt: TimeInterval, mainFreeAt: TimeInterval?,
                                        window: TimeInterval,
                                        cap: TimeInterval) -> TimeInterval {
        let limit = postedAt + cap
        guard let mainFreeAt else { return limit }
        return min(limit, max(postedAt, mainFreeAt) + window)
    }

    private final class MainThreadPing: @unchecked Sendable {
        private let lock = NSLock()
        private var answered: TimeInterval?

        init() {
            DispatchQueue.main.async { [self] in
                lock.lock()
                answered = ProcessInfo.processInfo.systemUptime
                lock.unlock()
            }
        }

        var answeredAt: TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            return answered
        }
    }

    private final class PastePromise: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let data: Data
        private let lock = NSLock()
        private let receipt = DispatchSemaphore(value: 0)
        private var armed = false
        private var requestedAfterArm = false

        init(_ text: String) { data = Data(text.utf8) }

        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        var hasPostArmRequest: Bool {
            lock.lock(); defer { lock.unlock() }
            return requestedAfterArm
        }

        func waitForPostArmRequest(timeout: TimeInterval) -> Bool {
            if hasPostArmRequest { return true }
            _ = receipt.wait(timeout: .now() + timeout)
            return hasPostArmRequest
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            item.setData(data, forType: type)
            lock.lock()
            let signal = armed && !requestedAfterArm
            if signal { requestedAfterArm = true }
            lock.unlock()
            if signal { receipt.signal() }
        }
    }

    static func paste(_ text: String, expectedTarget: PasteTarget,
                      settlingDelay: TimeInterval = settlingDelay,
                      keepOnClipboard: Bool = false,
                      done: @escaping @Sendable (DeliveryResult) -> Void) {
        refreshKeyboardLayoutCacheIfMainThread()
        queue.async { done(runTargeted(text, expectedTarget: expectedTarget,
                                      settlingDelay: settlingDelay,
                                      keepOnClipboard: keepOnClipboard)) }
    }

    enum TargetCaptureResult: @unchecked Sendable {
        case captured(PasteTarget)
        case refused
    }

    final class TargetCaptureExecutor: @unchecked Sendable {
        private let queue: DispatchQueue
        private let capacityLock = NSLock()
        private let maximumConcurrent: Int
        private var active = 0

        init(label: String = "com.andre.flowclone.target-capture",
             maximumConcurrent: Int = 4) {
            self.maximumConcurrent = max(1, maximumConcurrent)
            queue = DispatchQueue(label: label, qos: .userInitiated,
                                  attributes: .concurrent)
        }

        func submit<Value: Sendable>(
            acceptedEpoch: UInt64,
            currentEpoch: @escaping @Sendable () -> UInt64,
            capture: @escaping @Sendable () -> Value?,
            done: @escaping @Sendable (Value?) -> Void
        ) {
            capacityLock.lock()
            guard active < maximumConcurrent else {
                capacityLock.unlock()
                done(nil)
                return
            }
            active += 1
            capacityLock.unlock()

            queue.async {
                defer {
                    self.capacityLock.lock()
                    self.active -= 1
                    self.capacityLock.unlock()
                }
                guard currentEpoch() == acceptedEpoch else { done(nil); return }
                guard let value = capture(), currentEpoch() == acceptedEpoch else {
                    done(nil)
                    return
                }
                done(value)
            }
        }
    }

    private static let targetCaptureExecutor = TargetCaptureExecutor()
    private static let targetLeaseTimeoutQueue = DispatchQueue(
        label: "com.andre.flowclone.target-capture-timeout", qos: .userInitiated)

    final class TargetLease: @unchecked Sendable {
        let acceptedEpoch: UInt64
        private let lock = NSLock()
        private var result: TargetCaptureResult?
        private var waiters: [@Sendable (TargetCaptureResult) -> Void] = []

        fileprivate init(acceptedEpoch: UInt64) {
            self.acceptedEpoch = acceptedEpoch
        }

        fileprivate func complete(_ completed: TargetCaptureResult) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = completed
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in pending { waiter(completed) }
        }

        var resolvedTargetIfReady: PasteTarget? {
            lock.lock()
            defer { lock.unlock() }
            if case .captured(let target)? = result { return target }
            return nil
        }

        static func preResolvedForTesting(_ target: PasteTarget?,
                                          acceptedEpoch: UInt64 = 0) -> TargetLease {
            let lease = TargetLease(acceptedEpoch: acceptedEpoch)
            lease.complete(target.map(TargetCaptureResult.captured) ?? .refused)
            return lease
        }

        fileprivate func resolve(_ done: @escaping @Sendable (TargetCaptureResult) -> Void) {
            lock.lock()
            if let result {
                lock.unlock()
                done(result)
                return
            }
            waiters.append(done)
            lock.unlock()
        }
    }

    static func beginTargetCaptureAtPhysicalEventBoundary(
        app: PasteTarget.AppIdentity?
    ) -> TargetLease {
        refreshKeyboardLayoutCacheIfMainThread()
        let acceptedEpoch = FocusInteractionEpoch.snapshot()
        guard let app else {
            return refusedTargetLease(acceptedEpoch: acceptedEpoch)
        }
        return beginTargetCapture(acceptedEpoch: acceptedEpoch, app: app)
    }

    static func beginTargetCaptureAtMenuBoundary() -> TargetLease {
        refreshKeyboardLayoutCacheIfMainThread()
        let acceptedEpoch = FocusInteractionEpoch.snapshot()
        guard Thread.isMainThread, let app = PasteTarget.AppIdentity.frontmost() else {
            return refusedTargetLease(acceptedEpoch: acceptedEpoch)
        }
        return beginTargetCapture(acceptedEpoch: acceptedEpoch, app: app)
    }

    static func beginTargetCapture(for app: PasteTarget.AppIdentity?) -> TargetLease {
        refreshKeyboardLayoutCacheIfMainThread()
        let acceptedEpoch = FocusInteractionEpoch.snapshot()
        guard let app else { return refusedTargetLease(acceptedEpoch: acceptedEpoch) }
        return beginTargetCapture(acceptedEpoch: acceptedEpoch, app: app)
    }

    private static func beginTargetCapture(acceptedEpoch: UInt64,
                                           app: PasteTarget.AppIdentity) -> TargetLease {
        if handsfreeSession {
            Handsfree.log("blocked target capture (AX) of \(app.bundleID)")
            return refusedTargetLease(acceptedEpoch: acceptedEpoch)
        }
        let lease = TargetLease(acceptedEpoch: acceptedEpoch)
        targetLeaseTimeoutQueue.asyncAfter(deadline: .now() + 0.75) {
            lease.complete(.refused)
        }
        targetCaptureExecutor.submit(
            acceptedEpoch: acceptedEpoch,
            currentEpoch: { FocusInteractionEpoch.snapshot() },
            capture: {
                return PasteTarget.capture(for: app,
                                           interactionEpoch: acceptedEpoch)
            },
            done: { target in
                lease.complete(target.map(TargetCaptureResult.captured) ?? .refused)
            })
        return lease
    }

    private static func refusedTargetLease(acceptedEpoch: UInt64) -> TargetLease {
        let lease = TargetLease(acceptedEpoch: acceptedEpoch)
        lease.complete(.refused)
        return lease
    }

    static func resolveTargetCapture(
        _ lease: TargetLease?, done: @escaping @Sendable (TargetCaptureResult) -> Void
    ) {
        guard let lease else { done(.refused); return }
        lease.resolve(done)
    }

    enum TargetDecision {
        case valid(PasteTarget.PasteProbe?)
        case refused(String)
        case unresponsive(String)
        case secure
    }

    static func decision(for validation: PasteTarget.Validation) -> TargetDecision {
        switch validation {
        case .valid(let probe): return .valid(probe)
        case .appChanged: return .refused("target app changed")
        case .fieldChanged: return .refused("target field changed")
        case .selectionChanged: return .refused("target selection changed")
        case .selectionUnavailable: return .refused("target selection was unavailable when captured")
        case .fieldUnavailable: return .refused("target field became unavailable")
        case .appUnresponsive: return .unresponsive("target app is not responding")
        case .secureField: return .secure
        }
    }

    private static func targetDecision(_ target: PasteTarget) -> TargetDecision {
        return decision(for: target.revalidateForPaste())
    }

    /// Maximum extra AX polling window after the target app consumes our armed `PastePromise`,
    /// preventing virtualized/static AX views from stalling for 300 ms post-paste.
    static let postReadAXGraceWindow: TimeInterval = 0.060

    /// Polls for AX paste confirmation, exiting immediately on either `.confirmed` OR
    /// `.valueChanged`, and capping remaining AX polling to `postReadAXGraceWindow` (60 ms)
    /// once `readObserved()` reports that the target app consumed the armed pasteboard item.
    static func waitForPasteEffect(
        hasSelectedRange: Bool = false,
        beforeValue: String? = nil,
        pollConfirmation: () -> PasteTarget.PasteProbe.Confirmation,
        deadline: () -> TimeInterval,
        readObserved: () -> Bool = { false },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> PasteTarget.PasteProbe.Confirmation {
        var confirmation = PasteTarget.PasteProbe.Confirmation.unavailable
        var postReadGraceDeadline: TimeInterval?
        func effectiveDeadline() -> TimeInterval {
            if postReadGraceDeadline == nil, readObserved() {
                postReadGraceDeadline = now() + postReadAXGraceWindow
            }
            if let postReadGraceDeadline {
                return min(deadline(), postReadGraceDeadline)
            }
            return deadline()
        }
        repeat {
            if postReadGraceDeadline == nil, readObserved() {
                postReadGraceDeadline = now() + postReadAXGraceWindow
            }
            confirmation = pollConfirmation()
            switch confirmation {
            case .confirmed, .valueChanged:
                return confirmation
            case .mismatch, .unavailable:
                break
            }
            let remaining = effectiveDeadline() - now()
            if remaining > 0 {
                sleep(min(0.015, remaining))
            }
        } while now() < effectiveDeadline()
        return confirmation
    }

    private static func runTargeted(_ text: String, expectedTarget: PasteTarget,
                                    settlingDelay: TimeInterval,
                                    keepOnClipboard: Bool) -> DeliveryResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skippedEmpty
        }
        let pb = NSPasteboard.general

        if AXClient.isSecureInputEnabled() {
            return .notPosted(.clipboardUntouched, "secure input")
        }
        guard AXIsProcessTrusted() else {
            return .notPosted(writeTranscript(text, to: pb) ? .transcriptOnClipboard
                                                            : .historyOnly,
                              "no accessibility")
        }
        let probe: PasteTarget.PasteProbe?
        switch targetDecision(expectedTarget) {
        case .valid(let current):
            probe = current
        case .secure:
            return .notPosted(.clipboardUntouched, "secure field")
        case .refused(let why):
            guard keepOnClipboard else { return .notPosted(.clipboardUntouched, why) }
            return .notPosted(writeTranscript(text, to: pb) ? .transcriptOnClipboard
                                                            : .historyOnly, why)
        case .unresponsive(let why):
            return .notPosted(writeTranscript(text, to: pb) ? .transcriptOnClipboard
                                                            : .historyOnly, why)
        }
        guard let events = pasteEvents() else {
            return .notPosted(writeTranscript(text, to: pb) ? .transcriptOnClipboard
                                                            : .historyOnly,
                              "could not create paste events")
        }

        let sourceChangeCount = pb.changeCount
        var restorationItems = keepOnClipboard
            ? nil : preservableClipboard(pb, expectedChangeCount: sourceChangeCount)
        let nonce = Data(UUID().uuidString.utf8)
        let provider = PastePromise(text)
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else {
            return .notPosted(.clipboardUntouched, "pasteboard promise unavailable")
        }
        guard item.setData(nonce, forType: marker), markOptOut(item) else {
            return .notPosted(.clipboardUntouched, "pasteboard metadata unavailable")
        }
        if restorationItems != nil,
           let why = sourceClipboardRefusal(pb, expectedChangeCount: sourceChangeCount) {
            log("clipboard will not be preserved — \(why)")
            restorationItems = nil
        }
        if AXClient.isSecureInputEnabled() {
            return .notPosted(.clipboardUntouched, "secure input")
        }
        guard PasteTarget.AppIdentity.matchesBoundary(
            expectedTarget.app, current: PasteTarget.AppIdentity.frontmost()
        ) else {
            guard keepOnClipboard else {
                return .notPosted(.clipboardUntouched, "target app changed")
            }
            return .notPosted(writeTranscript(text, to: pb) ? .transcriptOnClipboard
                                                            : .historyOnly,
                              "target app changed")
        }
        pb.clearContents()
        let clearedChangeCount = pb.changeCount
        guard pb.writeObjects([item]) else {
            let failedChangeCount = pb.changeCount
            var restored = false
            if let restorationItems {
                if ownsPasteboard(pb, nonce: nonce, changeCount: failedChangeCount) {
                    restored = restore(restorationItems, on: pb, nonce: nonce,
                                       changeCount: failedChangeCount)
                } else {
                    restored = restoreCleared(restorationItems, on: pb,
                                              changeCount: clearedChangeCount)
                }
            }
            return .notPosted(restored ? .clipboardUntouched : .historyOnly,
                              restored
                                  ? "pasteboard write failed; prior clipboard restored"
                                  : "pasteboard write failed; prior clipboard changed or could not be restored")
        }
        let ownedChangeCount = pb.changeCount

        Thread.sleep(forTimeInterval: max(0, settlingDelay))
        guard !AXClient.isSecureInputEnabled() else {
            restoreIfPreserved(restorationItems, on: pb, nonce: nonce,
                               changeCount: ownedChangeCount)
            return .notPosted(.historyOnly, "secure input")
        }
        guard ownsPasteboard(pb, nonce: nonce, changeCount: ownedChangeCount) else {
            return .notPosted(.historyOnly, "clipboard changed before paste")
        }
        guard PasteTarget.AppIdentity.matchesBoundary(
            expectedTarget.app, current: PasteTarget.AppIdentity.frontmost()
        ) else {
            if keepOnClipboard {
                return .notPosted(keepTranscript(text, on: pb, nonce: nonce,
                                                 changeCount: ownedChangeCount),
                                  "target app changed")
            }
            restoreIfPreserved(restorationItems, on: pb, nonce: nonce,
                               changeCount: ownedChangeCount)
            return .notPosted(.historyOnly, "target app changed")
        }

        provider.arm()
        for event in events {
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let posted = DispatchTime.now()
        let postedAt = ProcessInfo.processInfo.systemUptime
        let mainThread = MainThreadPing()
        func deadline(_ window: TimeInterval) -> TimeInterval {
            acknowledgementDeadline(postedAt: postedAt, mainFreeAt: mainThread.answeredAt,
                                    window: window, cap: acknowledgementCap)
        }
        var confirmation = PasteTarget.PasteProbe.Confirmation.unavailable
        if let probe, probe.canObservePasteEffectViaAX {
            confirmation = waitForPasteEffect(
                hasSelectedRange: probe.hasSelectedRange,
                beforeValue: probe.beforeValue,
                pollConfirmation: { probe.confirmation(of: text) },
                deadline: { deadline(0.30) },
                readObserved: { provider.hasPostArmRequest }
            )
        } else {
            while !provider.hasPostArmRequest {
                let remaining = deadline(0.25) - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                _ = provider.waitForPostArmRequest(timeout: min(remaining, 0.015))
            }
        }
        if let freeAt = mainThread.answeredAt, freeAt - postedAt > 0.1 {
            log(String(format: "paste: main thread answered %.0fms after Cmd+V — acknowledgement window extended",
                       (freeAt - postedAt) * 1000))
        }
        let readObserved = provider.hasPostArmRequest

        if AXClient.isSecureInputEnabled() {
            return .ambiguous(posted, recovery(pb, nonce: nonce,
                                               changeCount: ownedChangeCount),
                              "secure input engaged during paste")
        }
        guard let acknowledgement = classify(confirmation: confirmation,
                                             readObserved: readObserved) else {
            let why: String
            if case .mismatch = confirmation { why = "target did not contain the exact text" }
            else if readObserved { why = "pasteboard read observed but target insertion was unverified" }
            else { why = "paste was not acknowledged" }
            return .ambiguous(posted, keepOnClipboard
                                  ? keepTranscript(text, on: pb, nonce: nonce,
                                                   changeCount: ownedChangeCount)
                                  : recovery(pb, nonce: nonce, changeCount: ownedChangeCount),
                              why)
        }

        let snapshotAvailable = restorationItems != nil
        let shouldRestoreImmediately = mayRestoreClipboard(acknowledgement,
                                                           preserved: snapshotAvailable)
        var restoreSucceeded = false
        var delayedRestoreScheduled = false
        if shouldRestoreImmediately, let restorationItems {
            restoreSucceeded = restore(restorationItems, on: pb, nonce: nonce,
                                       changeCount: ownedChangeCount)
        } else if mayScheduleDelayedClipboardRestore(acknowledgement,
                                                     preserved: snapshotAvailable,
                                                     keepOnClipboard: keepOnClipboard),
                  let restorationItems {
            // Materialize our item in-place without advancing changeCount so any slow
            // reader in the target app keeps seeing the exact pasteboard generation, then
            // restore the user's pre-dictation clipboard ~350 ms after Cmd+V if untouched.
            _ = keepTranscript(text, on: pb, nonce: nonce, changeCount: ownedChangeCount)
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - postedAt)
            let remainingDelay = max(0.050, delayedClipboardRestoreDelay - elapsed)
            scheduleDelayedClipboardRestore(
                restorationItems, on: pb, nonce: nonce,
                changeCount: ownedChangeCount, delay: remainingDelay)
            delayedRestoreScheduled = true
        }
        if keepOnClipboard {
            _ = keepTranscript(text, on: pb, nonce: nonce, changeCount: ownedChangeCount)
        }
        let preserved = reportedClipboardPreservation(
            acknowledgement, snapshotAvailable: snapshotAvailable,
            restoreSucceeded: restoreSucceeded,
            delayedRestoreScheduled: delayedRestoreScheduled)
        return .posted(posted, acknowledgement, preserved: preserved)
    }

    static func pasteEvents(vKeyCode: CGKeyCode? = nil) -> [CGEvent]? {
        if handsfreeSession, vKeyCode == nil {
            Handsfree.log("blocked synthetic Cmd+V")
            return nil
        }
        let key = vKeyCode ?? currentVirtualKeyCode(for: "v", fallback: CGKeyCode(kVK_ANSI_V))
        return commandChordEvents(keyCode: key)
    }

    static func copyEvents(cKeyCode: CGKeyCode? = nil) -> [CGEvent]? {
        if handsfreeSession, cKeyCode == nil {
            Handsfree.log("blocked synthetic Cmd+C")
            return nil
        }
        let key = cKeyCode ?? currentVirtualKeyCode(for: "c", fallback: CGKeyCode(kVK_ANSI_C))
        return commandChordEvents(keyCode: key)
    }

    private static func commandChordEvents(keyCode: CGKeyCode) -> [CGEvent]? {
        guard let src = CGEventSource(stateID: .privateState) else { return nil }
        let cmd: CGKeyCode = 0x37
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
            (cmd, true, .maskCommand),
            (keyCode, true, .maskCommand),
            (keyCode, false, .maskCommand),
            (cmd, false, []),
        ]
        var out: [CGEvent] = []
        for (key, down, flags) in steps {
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: key,
                                      keyDown: down) else { return nil }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: sourceTag)
            out.append(event)
        }
        return out
    }

    // MARK: - Simulated Cmd+C Selection Capture (Selection Transforms Fallback)

    enum CopyCaptureResult: Equatable, Sendable {
        case captured(String)
        case noSelection
        case tooLong
        case secure
        case unavailable
    }

    /// Captures selected text from an AX-blind / Electron / web app by snapshotting the
    /// clipboard, posting layout-aware `Cmd+C`, reading the copied text, and immediately
    /// restoring the prior pasteboard.
    static func captureSelectionViaCopy(
        for target: PasteTarget,
        acceptedEpoch: UInt64,
        maxLength: Int = SelectionTransformer.inputLimit,
        done: @escaping @Sendable (CopyCaptureResult) -> Void
    ) {
        refreshKeyboardLayoutCacheIfMainThread()
        queue.async {
            if AXClient.isSecureInputEnabled() {
                done(.secure)
                return
            }
            guard AXIsProcessTrusted(), !handsfreeSession else {
                done(.unavailable)
                return
            }
            guard PasteTarget.AppIdentity.frontmost() == target.app,
                  FocusInteractionEpoch.snapshot() == acceptedEpoch else {
                done(.noSelection)
                return
            }
            if case .secure = targetDecision(target) {
                done(.secure)
                return
            }
            guard let events = copyEvents() else {
                done(.unavailable)
                return
            }
            let result = captureSelectionFromPasteboard(
                .general,
                maxLength: maxLength,
                triggerCopy: {
                    for event in events {
                        event.post(tap: .cghidEventTap)
                        Thread.sleep(forTimeInterval: 0.008)
                    }
                },
                waitTimeout: 0.180
            )
            done(result)
        }
    }

    /// Deterministic pasteboard round-trip for simulated Cmd+C capture. Preserves & restores
    /// the prior clipboard whether or not the target wrote a selection, and refuses to clobber
    /// any clipboard that cannot be safely snapshotted (e.g. a foreign password-manager item).
    static func captureSelectionFromPasteboard(
        _ pb: NSPasteboard,
        maxLength: Int = SelectionTransformer.inputLimit,
        triggerCopy: () -> Void,
        waitTimeout: TimeInterval = 0.180,
        pollInterval: TimeInterval = 0.010
    ) -> CopyCaptureResult {
        if AXClient.isSecureInputEnabled() { return .secure }
        let sourceChangeCount = pb.changeCount
        if sourceClipboardRefusal(pb, expectedChangeCount: sourceChangeCount) != nil {
            return .unavailable
        }
        guard case .success(let snap) = snapshot(pb),
              sourceClipboardRefusal(pb, expectedChangeCount: sourceChangeCount) == nil,
              pasteboardItems(from: snap.items) != nil else {
            return .unavailable
        }
        let savedRawSnapshot = snap.items

        let nonce = Data(UUID().uuidString.utf8)
        let sentinel = NSPasteboardItem()
        guard sentinel.setData(nonce, forType: marker), markOptOut(sentinel) else {
            return .unavailable
        }
        pb.clearContents()
        guard pb.writeObjects([sentinel]) else {
            if let rebuilt = pasteboardItems(from: savedRawSnapshot) {
                pb.clearContents()
                if !rebuilt.isEmpty { _ = pb.writeObjects(rebuilt) }
            }
            return .unavailable
        }
        let sentinelChangeCount = pb.changeCount

        triggerCopy()

        let endAt = ProcessInfo.processInfo.systemUptime + max(0, waitTimeout)
        while pb.changeCount == sentinelChangeCount && ProcessInfo.processInfo.systemUptime < endAt {
            if pollInterval > 0 {
                Thread.sleep(forTimeInterval: pollInterval)
            } else {
                break
            }
        }

        let copiedChangeCount = pb.changeCount
        let didCopy = copiedChangeCount != sentinelChangeCount
        let copiedConcealed = didCopy && containsForeignConcealedItem(pb)
        let copiedText = (didCopy && !copiedConcealed) ? pb.string(forType: .string) : nil

        // Always restore the user's prior clipboard snapshot so simulated Cmd+C leaves
        // their pasteboard untouched.
        if let rebuilt = pasteboardItems(from: savedRawSnapshot) {
            pb.clearContents()
            if !rebuilt.isEmpty {
                _ = pb.writeObjects(rebuilt)
            }
        } else if ownsPasteboard(pb, nonce: nonce, changeCount: sentinelChangeCount) {
            pb.clearContents()
        }

        if copiedConcealed { return .secure }
        guard didCopy, let copiedText,
              !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noSelection
        }
        guard copiedText.count <= maxLength else { return .tooLong }
        return .captured(copiedText)
    }

    // MARK: - Clipboard Snapshot & Guarded Restore

    private struct ClipboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static let maxSnapshotItems = 16
    private static let maxSnapshotTypesPerItem = 16
    private static let maxSnapshotTypes = 64
    private static let maxSnapshotBytesPerType = 16 * 1_024 * 1_024
    private static let maxSnapshotBytes = 32 * 1_024 * 1_024

    private enum ClipboardSnapshotFailure: Error, Equatable, CustomStringConvertible {
        case tooManyItems
        case tooManyTypesInItem
        case tooManyTypes
        case typeTooLarge
        case tooManyBytes
        case unreadableType

        var description: String {
            switch self {
            case .tooManyItems: return "too many clipboard items"
            case .tooManyTypesInItem: return "a clipboard item exposes too many representations"
            case .tooManyTypes: return "too many clipboard representations"
            case .typeTooLarge: return "a clipboard representation exceeds the per-type byte budget"
            case .tooManyBytes: return "clipboard contents exceed the total byte budget"
            case .unreadableType: return "a clipboard representation could not be preserved"
            }
        }
    }

    private struct ClipboardSnapshotBudget {
        private var itemCount = 0
        private var typeCount = 0
        private var byteCount = 0

        mutating func beginItem(typeCount newTypes: Int) -> ClipboardSnapshotFailure? {
            itemCount += 1
            guard itemCount <= Paster.maxSnapshotItems else { return .tooManyItems }
            guard newTypes <= Paster.maxSnapshotTypesPerItem else {
                return .tooManyTypesInItem
            }
            typeCount += newTypes
            guard typeCount <= Paster.maxSnapshotTypes else { return .tooManyTypes }
            return nil
        }

        mutating func accept(byteCount newBytes: Int) -> ClipboardSnapshotFailure? {
            guard newBytes <= Paster.maxSnapshotBytesPerType else { return .typeTooLarge }
            guard byteCount <= Paster.maxSnapshotBytes - newBytes else { return .tooManyBytes }
            byteCount += newBytes
            return nil
        }
    }

    static func preservableClipboard(_ pb: NSPasteboard,
                                     expectedChangeCount: Int) -> [NSPasteboardItem]? {
        func refuse(_ why: String) -> [NSPasteboardItem]? {
            log("clipboard will not be preserved — \(why)")
            return nil
        }
        if let why = sourceClipboardRefusal(pb, expectedChangeCount: expectedChangeCount) {
            return refuse(why)
        }
        let saved: ClipboardSnapshot
        switch snapshot(pb) {
        case .success(let value): saved = value
        case .failure(let failure): return refuse(failure.description)
        }
        if let why = sourceClipboardRefusal(pb, expectedChangeCount: expectedChangeCount) {
            return refuse(why)
        }
        guard let items = pasteboardItems(from: saved.items) else {
            return refuse("snapshot could not be reconstructed safely")
        }
        return items
    }

    private static func restoreIfPreserved(_ items: [NSPasteboardItem]?, on pb: NSPasteboard,
                                           nonce: Data, changeCount: Int) {
        guard let items else { return }
        _ = restore(items, on: pb, nonce: nonce, changeCount: changeCount)
    }

    static func scheduleDelayedClipboardRestore(
        _ items: [NSPasteboardItem],
        on pb: NSPasteboard,
        nonce: Data,
        changeCount: Int,
        delay: TimeInterval = delayedClipboardRestoreDelay,
        queue targetQueue: DispatchQueue = queue,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        nonisolated(unsafe) let transferredItems = items
        nonisolated(unsafe) let pasteboard = pb
        targetQueue.asyncAfter(deadline: .now() + max(0, delay)) {
            guard !AXClient.isSecureInputEnabled() else {
                completion?(false)
                return
            }
            let restored = restore(transferredItems, on: pasteboard,
                                   nonce: nonce, changeCount: changeCount)
            completion?(restored)
        }
    }

    private static func snapshot(_ pb: NSPasteboard)
        -> Result<ClipboardSnapshot, ClipboardSnapshotFailure> {
        let items = pb.pasteboardItems ?? []
        var budget = ClipboardSnapshotBudget()
        var snapshotItems: [[NSPasteboard.PasteboardType: Data]] = []
        snapshotItems.reserveCapacity(min(items.count, maxSnapshotItems))
        for item in items {
            if let failure = budget.beginItem(typeCount: item.types.count) {
                return .failure(failure)
            }
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            itemData.reserveCapacity(item.types.count)
            for type in item.types {
                guard let value = item.data(forType: type) else {
                    return .failure(.unreadableType)
                }
                if let failure = budget.accept(byteCount: value.count) {
                    return .failure(failure)
                }
                itemData[type] = value
            }
            snapshotItems.append(itemData)
        }
        return .success(ClipboardSnapshot(items: snapshotItems))
    }

    private static func containsForeignConcealedItem(_ pb: NSPasteboard) -> Bool {
        (pb.pasteboardItems ?? []).contains { item in
            item.types.contains(concealedType) && !item.types.contains(marker)
        }
    }

    private enum SourceClipboardDecision: Equatable {
        case stable
        case changed
        case protected
    }

    private static func sourceClipboardDecision(expectedChangeCount: Int,
                                                currentChangeCount: Int,
                                                containsForeignConcealed: Bool)
        -> SourceClipboardDecision {
        guard currentChangeCount == expectedChangeCount else { return .changed }
        return containsForeignConcealed ? .protected : .stable
    }

    private static func sourceClipboardRefusal(_ pb: NSPasteboard,
                                               expectedChangeCount: Int) -> String? {
        let concealed = containsForeignConcealedItem(pb)
        switch sourceClipboardDecision(expectedChangeCount: expectedChangeCount,
                                       currentChangeCount: pb.changeCount,
                                       containsForeignConcealed: concealed) {
        case .stable: return nil
        case .changed: return "clipboard changed before snapshot"
        case .protected: return "clipboard contains protected content"
        }
    }

    private static func pasteboardItems(
        from snapshot: [[NSPasteboard.PasteboardType: Data]]
    ) -> [NSPasteboardItem]? {
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.count)
        for data in snapshot {
            let item = NSPasteboardItem()
            for (type, value) in data {
                guard item.setData(value, forType: type) else {
                    return nil
                }
            }
            items.append(item)
        }
        return items
    }

    static func restore(_ items: [NSPasteboardItem], on pb: NSPasteboard,
                        nonce: Data, changeCount: Int) -> Bool {
        guard ownsPasteboard(pb, nonce: nonce, changeCount: changeCount) else {
            log("pasteboard changed under us — leaving it alone (clipboard manager?)")
            return false
        }
        pb.clearContents()
        if !items.isEmpty, !pb.writeObjects(items) { return false }
        return true
    }

    private static func restoreCleared(_ items: [NSPasteboardItem], on pb: NSPasteboard,
                                       changeCount: Int) -> Bool {
        guard pb.changeCount == changeCount, (pb.pasteboardItems ?? []).isEmpty else {
            return false
        }
        return items.isEmpty || pb.writeObjects(items)
    }

    private static func recovery(_ pb: NSPasteboard, nonce: Data,
                                 changeCount: Int) -> Recovery {
        ownsPasteboard(pb, nonce: nonce, changeCount: changeCount)
            ? .transcriptOnClipboard : .historyOnly
    }

    static var keepsLastDictation: Bool {
        get { UserDefaults.standard.bool(forKey: "keepDictationOnClipboard") }
        set { UserDefaults.standard.set(newValue, forKey: "keepDictationOnClipboard") }
    }

    static func keepUndelivered(_ text: String) -> Bool {
        guard !AXClient.isSecureInputEnabled() else { return false }
        return writeTranscript(text)
    }

    static func keepTranscript(_ text: String, on pb: NSPasteboard, nonce: Data,
                               changeCount: Int) -> Recovery {
        guard ownsPasteboard(pb, nonce: nonce, changeCount: changeCount) else { return .historyOnly }
        guard pb.string(forType: .string) == text,
              ownsPasteboard(pb, nonce: nonce, changeCount: changeCount) else { return .historyOnly }
        return .transcriptOnClipboard
    }

    /// Immediate synchronous restore is reserved for AX-proven insertions; `.clipboardConsumed`
    /// uses `mayScheduleDelayedClipboardRestore` (~350 ms post-Cmd+V) so the target app finishes
    /// reading the pasteboard before the user's clipboard comes back.
    static func mayRestoreClipboard(_ a: Acknowledgement, preserved: Bool) -> Bool {
        guard preserved else { return false }
        if case .targetConfirmed = a { return true }
        return false
    }

    static func mayScheduleDelayedClipboardRestore(_ a: Acknowledgement,
                                                   preserved: Bool,
                                                   keepOnClipboard: Bool) -> Bool {
        guard preserved, !keepOnClipboard else { return false }
        return a == .clipboardConsumed
    }

    static func reportedClipboardPreservation(_ acknowledgement: Acknowledgement,
                                              snapshotAvailable: Bool,
                                              restoreSucceeded: Bool,
                                              delayedRestoreScheduled: Bool = false) -> Bool {
        if mayRestoreClipboard(acknowledgement, preserved: snapshotAvailable) {
            return restoreSucceeded
        }
        if acknowledgement == .clipboardConsumed, snapshotAvailable, delayedRestoreScheduled {
            return true
        }
        return false
    }

    static func classify(confirmation: PasteTarget.PasteProbe.Confirmation,
                         readObserved: Bool) -> Acknowledgement? {
        switch confirmation {
        case .confirmed(let insertion):
            return .targetConfirmed(insertion)
        case .valueChanged:
            return .clipboardConsumed
        case .unavailable, .mismatch:
            return readObserved ? .clipboardConsumed : nil
        }
    }

    private static func ownsPasteboard(_ pb: NSPasteboard, nonce: Data,
                                       changeCount: Int) -> Bool {
        pb.changeCount == changeCount && pb.data(forType: marker) == nonce
    }

    /// Opt-out markers attached ONLY on temporary internal Cmd+V / Cmd+C pasteboard transport.
    static func markOptOut(_ item: NSPasteboardItem) -> Bool {
        item.setData(Data([1]), forType: transientType)
            && item.setData(Data([1]), forType: concealedType)
    }

    /// Explicit user-initiated Copy (`transient == false`, the default) omits `ConcealedType`
    /// and `TransientType` so Universal Clipboard and clipboard managers work as expected.
    @discardableResult
    static func writeTranscript(_ text: String, to pb: NSPasteboard = .general,
                                transient: Bool = false) -> Bool {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(UUID().uuidString.utf8), forType: marker)
        if transient, !markOptOut(item) { return false }
        pb.clearContents()
        return pb.writeObjects([item])
    }

    /// Deterministic hook for `--pastertest`.
    @discardableResult
    static func selfCheck() -> (checks: Int, failed: Int) {
        var checks = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            checks += 1
            if !ok { failed += 1; log("PASTERTEST FAIL: \(name)") }
        }

        let range = PasteTarget.ConfirmedInsertion(location: 4, length: 7)
        for read in [true, false] {
            check("AX exact range wins (read=\(read))",
                  classify(confirmation: .confirmed(range), readObserved: read)
                  == .targetConfirmed(range))
            check("bounded value change acknowledges paste (read=\(read))",
                  classify(confirmation: .valueChanged, readObserved: read) == .clipboardConsumed)
        }
        check("mismatch without pasteboard read stays ambiguous",
              classify(confirmation: .mismatch, readObserved: false) == nil)
        check("mismatch with observed pasteboard read acknowledges as clipboardConsumed",
              classify(confirmation: .mismatch, readObserved: true) == .clipboardConsumed)
        check("no range and no read is still ambiguous",
              classify(confirmation: .unavailable, readObserved: false) == nil)
        check("no range plus an observed read is a weak acknowledgement",
              classify(confirmation: .unavailable, readObserved: true) == .clipboardConsumed)
        check("a proven insertion may hand the clipboard back immediately",
              mayRestoreClipboard(.targetConfirmed(range), preserved: true))
        check("a weak acknowledgement defers immediate restore to delayed guard",
              !mayRestoreClipboard(.clipboardConsumed, preserved: true)
              && mayScheduleDelayedClipboardRestore(.clipboardConsumed, preserved: true, keepOnClipboard: false))
        check("an unpreserved clipboard must NOT be handed back",
              !mayRestoreClipboard(.targetConfirmed(range), preserved: false)
              && !mayRestoreClipboard(.clipboardConsumed, preserved: false))
        check("an unresponsive target is refused without withholding the transcript",
              { if case .unresponsive = decision(for: .appUnresponsive) { return true }
                return false }())
        check("a secure field is still refused outright",
              { if case .secure = decision(for: .secureField) { return true }
                return false }())
        check("unchanged ordinary clipboard may be snapshotted",
              sourceClipboardDecision(expectedChangeCount: 7, currentChangeCount: 7,
                                      containsForeignConcealed: false) == .stable)
        check("changed source generation refuses snapshot",
              sourceClipboardDecision(expectedChangeCount: 7, currentChangeCount: 8,
                                      containsForeignConcealed: false) == .changed)
        check("foreign concealed source refuses snapshot",
              sourceClipboardDecision(expectedChangeCount: 7, currentChangeCount: 7,
                                      containsForeignConcealed: true) == .protected)

        var ordinaryBudget = ClipboardSnapshotBudget()
        check("ordinary clipboard fits snapshot budgets",
              ordinaryBudget.beginItem(typeCount: 3) == nil &&
              ordinaryBudget.accept(byteCount: 4_096) == nil)
        var itemBudget = ClipboardSnapshotBudget()
        var itemFailure: ClipboardSnapshotFailure?
        for _ in 0...maxSnapshotItems {
            itemFailure = itemBudget.beginItem(typeCount: 1) ?? itemFailure
        }
        check("item-count budget refuses an unbounded snapshot", itemFailure == .tooManyItems)
        var typeBudget = ClipboardSnapshotBudget()
        check("per-item type budget refuses excessive representations",
              typeBudget.beginItem(typeCount: maxSnapshotTypesPerItem + 1)
              == .tooManyTypesInItem)
        var totalTypeBudget = ClipboardSnapshotBudget()
        var totalTypeFailure: ClipboardSnapshotFailure?
        for _ in 0...(maxSnapshotTypes / maxSnapshotTypesPerItem) {
            totalTypeFailure = totalTypeBudget.beginItem(typeCount: maxSnapshotTypesPerItem)
                ?? totalTypeFailure
        }
        check("total type budget refuses excessive representations",
              totalTypeFailure == .tooManyTypes)
        var byteBudget = ClipboardSnapshotBudget()
        _ = byteBudget.beginItem(typeCount: 2)
        check("per-type byte budget refuses an oversized representation",
              byteBudget.accept(byteCount: maxSnapshotBytesPerType + 1) == .typeTooLarge)
        check("aggregate byte budget refuses an oversized clipboard",
              byteBudget.accept(byteCount: maxSnapshotBytesPerType) == nil &&
              byteBudget.accept(byteCount: maxSnapshotBytesPerType) == nil &&
              byteBudget.accept(byteCount: 1) == .tooManyBytes)

        let unarmed = PastePromise("before arm")
        let first = NSPasteboardItem()
        unarmed.pasteboard(nil, item: first, provideDataForType: .string)
        check("unarmed promised text supplied", first.string(forType: .string) == "before arm")
        check("pre-arm read ignored", !unarmed.hasPostArmRequest)

        let armed = PastePromise("after arm")
        let second = NSPasteboardItem()
        armed.arm()
        armed.pasteboard(nil, item: second, provideDataForType: .string)
        check("armed promised text supplied", second.string(forType: .string) == "after arm")
        check("post-arm read observed", armed.waitForPostArmRequest(timeout: 0.05))

        let target = PasteTarget.selfCheck()
        checks += target.checks
        failed += target.failed
        log(failed == 0 ? "PASTERTEST PASS (\(checks) checks)"
                        : "PASTERTEST FAIL (\(failed)/\(checks) checks)")
        return (checks, failed)
    }
}
