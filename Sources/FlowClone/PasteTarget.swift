// An accepted-action paste destination. App identity is always enforced; when Accessibility
// exposes the focused editor, the exact element is enforced too. Unsupported Electron/web
// editors deliberately fall back to app-only validation instead of breaking dictation.
import Cocoa

struct PasteTarget: @unchecked Sendable {
    struct ConfirmedInsertion: Equatable, Sendable {
        let location: Int
        let length: Int
        var replacedText: String? = nil
        var range: CFRange { CFRange(location: location, length: length) }
    }

    struct AppIdentity: Equatable, Sendable {
        let bundleID: String
        let pid: pid_t

        static func frontmost() -> AppIdentity? {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier else { return nil }
            return AppIdentity(bundleID: bundleID, pid: app.processIdentifier)
        }

        static func matchesBoundary(_ boundary: AppIdentity,
                                    current: AppIdentity?) -> Bool {
            boundary == current
        }
    }

    struct PasteProbe: @unchecked Sendable {
        enum Confirmation: Equatable {
            case confirmed(ConfirmedInsertion)
            /// Bounded AX observation proved the field mutated from its pre-paste state
            /// without satisfying exact `ConfirmedInsertion` range postconditions.
            case valueChanged
            case mismatch
            case unavailable
        }

        fileprivate let element: AXUIElement
        fileprivate let selectionBefore: CFRange?
        let beforeValue: String?
        let beforeCount: Int?
        let beforeSlice: String?
        let beforeSliceRequestedLength: Int
        let canObserveViaGridSafeAX: Bool
        var replacedText: String? = nil

        init(element: AXUIElement, selectionBefore: CFRange?,
             beforeValue: String? = nil,
             beforeCount: Int? = nil,
             beforeSlice: String? = nil,
             beforeSliceRequestedLength: Int = 16,
             canObserveViaGridSafeAX: Bool = true,
             replacedText: String? = nil) {
            self.element = element
            self.selectionBefore = selectionBefore
            self.beforeValue = beforeValue
            self.beforeCount = beforeCount
            self.beforeSlice = beforeSlice
            self.beforeSliceRequestedLength = beforeSliceRequestedLength
            self.canObserveViaGridSafeAX = canObserveViaGridSafeAX
            self.replacedText = replacedText
        }

        init(bundleID: String,
             element: AXUIElement = AXUIElementCreateSystemWide(),
             selectionBefore: CFRange?,
             beforeValue: String? = nil,
             beforeCount: Int? = nil,
             beforeSlice: String? = nil,
             beforeSliceRequestedLength: Int = 16,
             replacedText: String? = nil) {
            let gridSafe = !AXTextContext.usesTerminalGridAX(bundleID)
            self.init(
                element: element,
                selectionBefore: selectionBefore,
                beforeValue: gridSafe ? beforeValue : nil,
                beforeCount: gridSafe ? beforeCount : nil,
                beforeSlice: gridSafe ? beforeSlice : nil,
                beforeSliceRequestedLength: beforeSliceRequestedLength,
                canObserveViaGridSafeAX: gridSafe,
                replacedText: gridSafe ? replacedText : nil
            )
        }

        var hasSelectedRange: Bool { selectionBefore != nil }
        var canObservePasteEffectViaAX: Bool {
            canObserveViaGridSafeAX && (selectionBefore != nil || beforeValue != nil)
        }

        /// Reads only the range where this paste should have landed (or checks bounded field
        /// mutation when exact caret/slice postconditions do not match). Skips 2D terminal
        /// screen grids (`canObserveViaGridSafeAX == false`) where `AXStringForRange` reads
        /// rendered TUI borders instead of the PTY input stream.
        func confirmation(of text: String) -> Confirmation {
            guard canObserveViaGridSafeAX else { return .unavailable }
            let deadline = AXClient.Deadline(total: 0.08, perCall: 0.04)
            if let selectionBefore {
                let range = CFRange(location: selectionBefore.location, length: text.utf16.count)
                let observed = PasteTarget.boundedText(element, range: range, deadline: deadline)
                let after = AXClient.selectedRange(element, deadline: deadline)
                if Self.postcondition(before: selectionBefore,
                                      after: after,
                                      observed: observed,
                                      text: text) {
                    return .confirmed(ConfirmedInsertion(location: range.location,
                                                         length: range.length,
                                                         replacedText: replacedText))
                }
                let currentCount = beforeCount != nil
                    ? AXClient.numberAttribute(element,
                                               kAXNumberOfCharactersAttribute as CFString,
                                               deadline: deadline)
                    : nil
                let currentSlice = beforeSlice != nil
                    ? Self.probeSlice(element,
                                      at: selectionBefore.location,
                                      maxLength: beforeSliceRequestedLength,
                                      knownCount: currentCount,
                                      deadline: deadline)
                    : nil
                return Self.evaluateRangeConfirmation(
                    selectionBefore: selectionBefore,
                    selectionAfter: after,
                    observedAtTarget: observed,
                    expectedText: text,
                    beforeCount: beforeCount,
                    currentCount: currentCount,
                    beforeSlice: beforeSlice,
                    beforeSliceRequestedLength: beforeSliceRequestedLength,
                    currentSlice: currentSlice,
                    replacedText: replacedText
                )
            }
            if let beforeValue {
                guard let currentValue = AXClient.boundedValue(element, deadline: deadline) else {
                    return .unavailable
                }
                return Self.detectValueChange(beforeValue: beforeValue,
                                              currentValue: currentValue,
                                              expectedText: text)
            }
            return .unavailable
        }

        static func captureMutationBaseline(
            element: AXUIElement,
            selection: CFRange,
            deadline: AXClient.Deadline = AXClient.Deadline(total: 0.05, perCall: 0.025)
        ) -> (count: Int?, slice: String?, requestedLength: Int) {
            let requestedLength = min(64, max(0, max(selection.length, 16)))
            let count = AXClient.numberAttribute(element,
                                                 kAXNumberOfCharactersAttribute as CFString,
                                                 deadline: deadline)
            let slice = probeSlice(element,
                                   at: selection.location,
                                   maxLength: requestedLength,
                                   knownCount: count,
                                   deadline: deadline)
            return (count, slice, requestedLength)
        }

        static func probeSlice(_ element: AXUIElement,
                               at location: Int,
                               maxLength: Int,
                               knownCount: Int?,
                               deadline: AXClient.Deadline) -> String? {
            guard location >= 0, maxLength >= 0 else { return nil }
            if maxLength == 0 { return "" }
            if let knownCount, knownCount >= 0 {
                guard location <= knownCount else { return nil }
                let clampedLength = min(maxLength, knownCount - location)
                if clampedLength == 0 { return "" }
                if let exact = PasteTarget.boundedText(
                    element,
                    range: CFRange(location: location, length: clampedLength),
                    deadline: deadline
                ) {
                    return exact
                }
            }
            var requested = CFRange(location: location, length: maxLength)
            guard let param = AXValueCreate(.cfRange, &requested),
                  let partial: String = AXClient.parameterizedAttribute(
                      element,
                      kAXStringForRangeParameterizedAttribute as CFString,
                      parameter: param,
                      deadline: deadline
                  ),
                  partial.utf16.count <= maxLength else {
                return nil
            }
            return partial
        }

        static func evaluateRangeConfirmation(
            selectionBefore: CFRange,
            selectionAfter: CFRange?,
            observedAtTarget: String?,
            expectedText: String,
            beforeCount: Int?,
            currentCount: Int?,
            beforeSlice: String?,
            beforeSliceRequestedLength: Int = 16,
            currentSlice: String?,
            replacedText: String? = nil
        ) -> Confirmation {
            if postcondition(before: selectionBefore,
                             after: selectionAfter,
                             observed: observedAtTarget,
                             text: expectedText) {
                return .confirmed(ConfirmedInsertion(location: selectionBefore.location,
                                                     length: expectedText.utf16.count,
                                                     replacedText: replacedText))
            }
            if let observedAtTarget, observedAtTarget == expectedText,
               let beforeSlice,
               sliceProvesTargetChanged(beforeSlice: beforeSlice,
                                        requestedLength: beforeSliceRequestedLength,
                                        expectedText: expectedText) {
                return .valueChanged
            }
            if let selectionAfter,
               (selectionAfter.location != selectionBefore.location
                || selectionAfter.length != selectionBefore.length) {
                return .valueChanged
            }
            if let beforeCount, let currentCount, currentCount != beforeCount {
                return .valueChanged
            }
            if let beforeSlice, let currentSlice, currentSlice != beforeSlice {
                return .valueChanged
            }
            return observedAtTarget == nil ? .unavailable : .mismatch
        }

        private static func sliceProvesTargetChanged(
            beforeSlice: String,
            requestedLength: Int,
            expectedText: String
        ) -> Bool {
            let beforeUnits = Array(beforeSlice.utf16)
            let expectedUnits = Array(expectedText.utf16)
            guard !expectedUnits.isEmpty else { return false }
            let cap = max(0, requestedLength)
            if cap > 0, beforeUnits.count < min(cap, expectedUnits.count) {
                return true
            }
            let overlap = min(beforeUnits.count, expectedUnits.count)
            guard overlap > 0 else { return false }
            return Array(beforeUnits.prefix(overlap)) != Array(expectedUnits.prefix(overlap))
        }

        static func detectValueChange(beforeValue: String, currentValue: String,
                                      expectedText: String) -> Confirmation {
            guard currentValue != beforeValue else { return .unavailable }
            let beforeUTF16 = Array(beforeValue.utf16)
            let currentUTF16 = Array(currentValue.utf16)
            let expectedUTF16 = Array(expectedText.utf16)
            if !expectedUTF16.isEmpty,
               currentUTF16.count == beforeUTF16.count + expectedUTF16.count {
                var prefix = 0
                while prefix < beforeUTF16.count, beforeUTF16[prefix] == currentUTF16[prefix] {
                    prefix += 1
                }
                let suffixCount = beforeUTF16.count - prefix
                if prefix + expectedUTF16.count + suffixCount == currentUTF16.count {
                    let mid = Array(currentUTF16[prefix..<(prefix + expectedUTF16.count)])
                    let tail = Array(currentUTF16[(prefix + expectedUTF16.count)...])
                    let expectedTail = Array(beforeUTF16[prefix...])
                    if mid == expectedUTF16 && tail == expectedTail {
                        return .confirmed(ConfirmedInsertion(location: prefix,
                                                             length: expectedUTF16.count))
                    }
                }
            }
            return .valueChanged
        }

        static func postcondition(before: CFRange, after: CFRange?, observed: String?,
                                  text: String) -> Bool {
            guard observed == text, let after else { return false }
            return after.location == before.location + text.utf16.count && after.length == 0
        }
    }

    struct LearningSnapshot: Equatable, Sendable {
        let prefix: String
        let text: String
        let characterCount: Int
        let selectionLength: Int
    }

    enum SelectedTextLookupResult {
        case captured(SelectedTextTarget)
        case emptyConfirmedSelection
        case needsCopyFallback(fallbackElement: AXUIElement?)
        case tooLong
        case secure
    }

    var capturedElementIfAny: AXUIElement? {
        if case .exact(let identity) = focus { return identity.element }
        return nil
    }

    /// The field captured at the press was a password field, or macOS secure input is on now.
    /// Deliberately makes no Accessibility calls: it runs on the session queue at the press and
    /// before delivery, where a `revalidate()` round trip would add latency to every dictation.
    /// The live field is still checked by `Paster` right before Cmd+V (`.secure` → not posted).
    var isSecure: Bool {
        focus == .secure || AXClient.isSecureInputEnabled()
    }

    static func secureTargetForTesting(
        app: AppIdentity = AppIdentity(bundleID: "com.example.PasswordApp", pid: 4242),
        interactionEpoch: UInt64 = 0
    ) -> PasteTarget {
        PasteTarget(app: app, focus: .secure, selection: nil, interactionEpoch: interactionEpoch)
    }

    static func appOnlyTargetForTesting(
        app: AppIdentity = AppIdentity(bundleID: "com.example.Editor", pid: 4242),
        interactionEpoch: UInt64 = 0
    ) -> PasteTarget {
        PasteTarget(app: app, focus: .appOnly, selection: nil, interactionEpoch: interactionEpoch)
    }

    func lookupSelectedTextTarget() -> SelectedTextLookupResult {
        if AXClient.isSecureInputEnabled() { return .secure }
        if case .secure = focus { return .secure }
        let validation = revalidateForPaste()
        switch validation {
        case .secureField:
            return .secure
        case .appChanged:
            return .emptyConfirmedSelection
        case .valid(let probe?):
            let deadline = AXClient.Deadline(total: 0.15, perCall: 0.04)
            let settable = AXClient.isAttributeSettable(
                probe.element, kAXSelectedTextAttribute as CFString, deadline: deadline)
            let role = AXClient.stringAttribute(
                probe.element, kAXRoleAttribute as CFString, deadline: deadline)
            if let range = probe.selectionBefore, range.length > 0 {
                let text = (range.length <= SelectionTransformer.inputLimit * 2
                    ? Self.boundedText(probe.element, range: range, deadline: deadline)
                    : nil)
                    ?? AXClient.stringAttribute(
                        probe.element, kAXSelectedTextAttribute as CFString, deadline: deadline)
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard text.count <= SelectionTransformer.inputLimit else { return .tooLong }
                    if settable {
                        let target = SelectedTextTarget(element: probe.element, pid: app.pid,
                                                        bundleID: app.bundleID, range: range,
                                                        original: text)
                        if target.revalidateSelection(expected: text, range: range) {
                            return .captured(target)
                        }
                    }
                    if role != (kAXStaticTextRole as String) {
                        return .captured(SelectedTextTarget(
                            pasteFallback: self, fallbackElement: probe.element, original: text))
                    }
                }
            }
            let selectedAttr = AXClient.stringAttribute(
                probe.element, kAXSelectedTextAttribute as CFString, deadline: deadline)
            if let selectedAttr {
                if !selectedAttr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard selectedAttr.count <= SelectionTransformer.inputLimit else {
                        return .tooLong
                    }
                    return .captured(SelectedTextTarget(
                        pasteFallback: self, fallbackElement: probe.element, original: selectedAttr))
                }
                if let range = probe.selectionBefore, range.length == 0, settable {
                    return .emptyConfirmedSelection
                }
            }
            return .needsCopyFallback(fallbackElement: probe.element)
        case .valid(nil), .appUnresponsive, .selectionUnavailable, .selectionChanged,
             .fieldChanged, .fieldUnavailable:
            return .needsCopyFallback(fallbackElement: capturedElementIfAny)
        }
    }

    func selectedTextTarget() -> SelectedTextTarget? {
        if case .captured(let target) = lookupSelectedTextTarget() {
            return target
        }
        return nil
    }

    func insertedTextTarget(_ insertion: ConfirmedInsertion, text: String) -> SelectedTextTarget? {
        guard case .valid(let probe?) = revalidate(requireCapturedSelection: false),
              let observed = Self.boundedText(probe.element, range: insertion.range,
                  deadline: AXClient.Deadline(total: 0.15, perCall: 0.04)), observed == text else { return nil }
        return SelectedTextTarget(element: probe.element, pid: app.pid, bundleID: app.bundleID,
                                  range: insertion.range, original: text)
    }

    /// Read only the paste, up to 64 UTF-16 units before it and 128 after it.
    func learningSnapshot(at insertion: ConfirmedInsertion,
                          originalCount: Int? = nil) -> LearningSnapshot? {
        let deadline = AXClient.Deadline(total: 0.20, perCall: 0.04)
        guard insertion.location >= 0, (1...3_000).contains(insertion.length),
              case .valid(let probe?) = revalidate(requireCapturedSelection: false, deadline: deadline),
              let total = AXClient.numberAttribute(probe.element,
                  kAXNumberOfCharactersAttribute as CFString, deadline: deadline),
              total >= insertion.location else { return nil }
        let delta = originalCount.map { total - $0 } ?? 0
        guard abs(delta) <= 512 else { return nil }
        let prefixLength = min(64, insertion.location)
        let start = insertion.location - prefixLength
        let length = min(total - start, prefixLength + insertion.length + 128 + delta)
        guard (1...4_096).contains(length), length >= prefixLength,
              let text = Self.boundedText(probe.element, range: CFRange(location: start, length: length),
                                          deadline: deadline),
              let selection = AXClient.selectedRange(probe.element, deadline: deadline),
              case .valid(let after?) = revalidate(requireCapturedSelection: false, deadline: deadline),
              CFEqual(probe.element, after.element), deadline.hasTimeRemaining else { return nil }
        let value = text as NSString
        guard value.length == length else { return nil }
        return LearningSnapshot(prefix: value.substring(to: prefixLength),
                                text: value.substring(from: prefixLength),
                                characterCount: total, selectionLength: selection.length)
    }

    private static func boundedText(_ element: AXUIElement, range: CFRange,
                                    deadline: AXClient.Deadline) -> String? {
        AXClient.textRange(element, range: range, deadline: deadline)
    }

    /// Captures context from the leased target. If an Electron/terminal editor re-rendered its
    /// composer or finished building its `AXManualAccessibility` tree without any physical input
    /// since hotkey-down, context follows the app's current non-secure editor under the same
    /// epoch fence as `revalidateForPaste()`.
    func captureDictationContext(
        deadline: AXClient.Deadline = AXClient.Deadline(total: 0.100, perCall: 0.04)
    ) -> DictationContext {
        guard !AXTextContext.usesTerminalGridAX(app.bundleID),
              deadline.hasTimeRemaining, !AXClient.isSecureInputEnabled() else { return .empty }
        let initial = revalidate(requireCapturedSelection: true, deadline: deadline)
        let resolved: Validation
        if case .valid(let probe) = initial, probe != nil {
            resolved = initial
        } else if FocusInteractionEpoch.snapshot() == interactionEpoch,
                  AppIdentity.frontmost() == app,
                  case .valid(let followed?) = followCurrentEditor(captureBaseline: false,
                                                                   deadline: deadline) {
            resolved = .valid(followed)
        } else {
            resolved = initial
        }
        guard case .valid(let before?) = resolved else { return .empty }
        let context = AXTextContext.capture(element: before.element, pid: app.pid,
                                            bundleID: app.bundleID, deadline: deadline)
        guard deadline.hasTimeRemaining, AppIdentity.frontmost() == app,
              !AXClient.isSecureInputEnabled() else { return .empty }
        return context
    }

    enum Validation {
        case valid(PasteProbe?)
        case appChanged
        case fieldChanged
        case selectionChanged
        case selectionUnavailable
        case fieldUnavailable
        case secureField
        /// The app never answered Accessibility inside its budgets (or returned an unreadable
        /// role without secure input). Refuse synthetic Cmd+V if still unreadable, while keeping
        /// the transcript recoverable on the clipboard rather than dropping it as a password field.
        case appUnresponsive
    }

    /// A pure identity policy shared by live AX validation and deterministic tests.
    enum FieldAnchor<Identity: Equatable>: Equatable {
        case appOnly
        case exact(Identity)
        case secure
        case unresponsive
    }

    enum FieldObservation<Identity: Equatable>: Equatable {
        case element(Identity)
        case secure
        case unknownRole
        case unavailable
        case foreign
        case timedOut
    }

    enum FieldIdentityDecision: Equatable {
        case exactMatch
        case appOnlyMatch
        case fieldChanged
        case fieldUnavailable
        case secure
        case unresponsive
    }

    static func identityDecision<Identity: Equatable>(
        anchor: FieldAnchor<Identity>, observation: FieldObservation<Identity>
    ) -> FieldIdentityDecision {
        switch anchor {
        case .secure:
            // Confirmed security at the accepted capture boundary is sticky.
            return .secure
        case .unresponsive:
            if observation == .secure { return .secure }
            return .unresponsive
        case .appOnly:
            switch observation {
            case .unavailable: return .appOnlyMatch
            case .secure: return .secure
            case .timedOut, .unknownRole: return .unresponsive
            case .element, .foreign: return .fieldChanged
            }
        case .exact(let expected):
            switch observation {
            case .element(let current):
                return expected == current ? .exactMatch : .fieldChanged
            case .secure: return .secure
            case .unavailable: return .fieldUnavailable
            case .foreign: return .fieldChanged
            case .timedOut, .unknownRole: return .unresponsive
            }
        }
    }

    private struct ElementIdentity: @unchecked Sendable, Equatable {
        let element: AXUIElement

        static func == (lhs: ElementIdentity, rhs: ElementIdentity) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }
    }

    private typealias FocusPolicy = FieldAnchor<ElementIdentity>

    let app: AppIdentity
    private let focus: FocusPolicy
    private let selection: CFRange?
    let interactionEpoch: UInt64

    /// Capture against an app identity already sampled at the accepted action.
    static func capture(for app: AppIdentity, interactionEpoch: UInt64) -> PasteTarget? {
        guard AppIdentity.matchesBoundary(app, current: AppIdentity.frontmost()) else {
            return nil
        }
        if AXClient.isSecureInputEnabled() {
            return PasteTarget(app: app, focus: .secure, selection: nil,
                               interactionEpoch: interactionEpoch)
        }
        AXTextContext.enableElectronAccessibilityIfNeeded(pid: app.pid, bundleID: app.bundleID)
        let deadline = AXClient.Deadline(total: 0.20, perCall: 0.05)
        let policy: FocusPolicy
        var capturedSelection: CFRange?
        switch focusedElement(retryingIn: app, deadline: deadline) {
        case .element(let element):
            let selection = AXClient.selectedRange(element, deadline: deadline)
            guard AppIdentity.matchesBoundary(app, current: AppIdentity.frontmost()) else {
                return nil
            }
            switch focusedElement(retryingIn: app, deadline: deadline) {
            case .element(let current) where CFEqual(element, current):
                policy = .exact(ElementIdentity(element: current))
                capturedSelection = selection
            case .secure:
                policy = .secure
            case .timedOut, .unknownRole:
                policy = .unresponsive
            case .element, .unavailable, .foreign:
                return nil
            }
        case .secure: policy = .secure
        case .unavailable: policy = .appOnly
        case .timedOut, .unknownRole: policy = .unresponsive
        case .foreign: return nil
        }
        guard AppIdentity.matchesBoundary(app, current: AppIdentity.frontmost()) else {
            return nil
        }
        return PasteTarget(app: app, focus: policy, selection: capturedSelection,
                           interactionEpoch: interactionEpoch)
    }

    /// Retries once with a fresh budget when an AX read times out or transiently returns an
    /// unreadable role (`Security.unknown`), preventing a >45 ms busy app from being latched
    /// as `.secure`.
    private static func focusedElement(retryingIn app: AppIdentity,
                                       deadline: AXClient.Deadline) -> FocusLookup {
        let first = focusedElement(in: app, deadline: deadline)
        switch first {
        case .timedOut, .unknownRole:
            return focusedElement(in: app,
                                  deadline: AXClient.Deadline(total: 0.15, perCall: 0.05))
        default:
            return first
        }
    }

    func revalidate() -> Validation {
        revalidate(requireCapturedSelection: true)
    }

    /// Strict `revalidate()` first; if the editor re-rendered or moved its caret without any
    /// physical input since hotkey-down — OR if the app was momentarily busy (`.unresponsive`
    /// or `AXManualAccessibility` still initializing under `.appOnly`) at hotkey-down and is now
    /// responsive with zero physical input since — follow the app's verified current editor.
    func revalidateForPaste() -> Validation {
        if AXClient.isSecureInputEnabled() { return .secureField }
        let strict = revalidate(requireCapturedSelection: true, captureBaseline: true)
        let currentEpoch = FocusInteractionEpoch.snapshot()
        let anchorIsExact: Bool = {
            if case .exact = focus { return true }
            return false
        }()
        if Self.mayFollowAppDrivenChange(strict, anchorIsExact: anchorIsExact,
                                         capturedEpoch: interactionEpoch,
                                         currentEpoch: currentEpoch),
           let followed = followCurrentEditor(captureBaseline: true) {
            log("paste target: \(strict) with no key or click since the press — following the app's current editor")
            return followed
        }
        if interactionEpoch == currentEpoch {
            switch focus {
            case .unresponsive:
                if let recovered = recoverFromBusyCapture() {
                    log("paste target: capture timed out on busy app, now verified with no input since press")
                    return recovered
                }
            case .appOnly:
                // When Electron `AXManualAccessibility` finishes building its tree during speech,
                // an `.appOnly` capture sees `.fieldChanged` on the newly exposed editor. With no
                // physical input since hotkey-down, bind that editor cleanly.
                if case .fieldChanged = strict, let followed = followCurrentEditor(captureBaseline: true) {
                    log("paste target: Electron AX tree became observable with no input since press")
                    return followed
                }
            case .exact, .secure:
                break
            }
        }
        return strict
    }

    static func mayFollowAppDrivenChange(_ strict: Validation, anchorIsExact: Bool,
                                         capturedEpoch: UInt64, currentEpoch: UInt64) -> Bool {
        guard anchorIsExact, capturedEpoch == currentEpoch else { return false }
        switch strict {
        case .fieldChanged, .selectionChanged, .selectionUnavailable: return true
        case .valid, .appChanged, .fieldUnavailable, .secureField, .appUnresponsive: return false
        }
    }

    private func recoverFromBusyCapture() -> Validation? {
        guard !AXClient.isSecureInputEnabled(),
              AppIdentity.frontmost() == app,
              Self.appOnlyInteractionIsValid(capturedEpoch: interactionEpoch,
                                             currentEpoch: FocusInteractionEpoch.snapshot())
        else { return nil }
        let deadline = AXClient.Deadline(total: 0.15, perCall: 0.05)
        switch Self.focusedElement(retryingIn: app, deadline: deadline) {
        case .element:
            return followCurrentEditor(captureBaseline: true, deadline: deadline)
        case .unavailable:
            guard AppIdentity.frontmost() == app,
                  Self.appOnlyInteractionIsValid(capturedEpoch: interactionEpoch,
                                                 currentEpoch: FocusInteractionEpoch.snapshot())
            else { return nil }
            return .valid(nil)
        case .secure:
            return .secureField
        case .timedOut, .unknownRole, .foreign:
            return nil
        }
    }

    private func followCurrentEditor(
        captureBaseline: Bool = true,
        deadline: AXClient.Deadline = AXClient.Deadline(total: 0.12, perCall: 0.04)
    ) -> Validation? {
        guard !AXClient.isSecureInputEnabled(),
              AppIdentity.frontmost() == app,
              case .element(let current) = Self.focusedElement(retryingIn: app, deadline: deadline)
        else { return nil }
        let gridSafeAX = !AXTextContext.usesTerminalGridAX(app.bundleID)
        let selection = AXClient.selectedRange(current, deadline: deadline)
        let beforeValue = (gridSafeAX && selection == nil)
            ? AXClient.boundedValue(current, deadline: deadline)
            : nil
        let replacedText: String?
        if !gridSafeAX {
            replacedText = nil
        } else if let selection, selection.length == 0 {
            replacedText = ""
        } else if let selection, selection.length <= 3_000 {
            replacedText = Self.boundedText(current, range: selection, deadline: deadline)
        } else { replacedText = nil }
        let baseline: (count: Int?, slice: String?, requestedLength: Int)
        if gridSafeAX, captureBaseline, let selection {
            baseline = PasteProbe.captureMutationBaseline(element: current, selection: selection)
        } else {
            baseline = (nil, nil, 16)
        }
        guard case .element(let final) = Self.focusedElement(retryingIn: app, deadline: deadline),
              CFEqual(current, final), AppIdentity.frontmost() == app,
              !AXClient.isSecureInputEnabled(),
              Self.appOnlyInteractionIsValid(capturedEpoch: interactionEpoch,
                                             currentEpoch: FocusInteractionEpoch.snapshot())
        else { return nil }
        return .valid(PasteProbe(
            bundleID: app.bundleID,
            element: current,
            selectionBefore: selection,
            beforeValue: beforeValue,
            beforeCount: baseline.count,
            beforeSlice: baseline.slice,
            beforeSliceRequestedLength: baseline.requestedLength,
            replacedText: replacedText
        ))
    }

    private func revalidate(requireCapturedSelection: Bool,
                            captureBaseline: Bool = false,
                            deadline: AXClient.Deadline = AXClient.Deadline(
                                total: 0.12, perCall: 0.04)) -> Validation {
        if AXClient.isSecureInputEnabled() { return .secureField }
        guard AppIdentity.frontmost() == app else { return .appChanged }
        if case .appOnly = focus,
           !Self.appOnlyInteractionIsValid(capturedEpoch: interactionEpoch,
                                           currentEpoch: FocusInteractionEpoch.snapshot()) {
            return .fieldChanged
        }
        let currentFocus = Self.focusedElement(retryingIn: app, deadline: deadline)
        guard AppIdentity.frontmost() == app else { return .appChanged }
        switch Self.identityDecision(anchor: focus,
                                     observation: Self.observation(currentFocus)) {
        case .secure:
            return .secureField
        case .unresponsive:
            return .appUnresponsive
        case .appOnlyMatch:
            return .valid(nil)
        case .fieldChanged:
            return .fieldChanged
        case .fieldUnavailable:
            return .fieldUnavailable
        case .exactMatch:
            guard case .element(let current) = currentFocus else { return .fieldChanged }
            let gridSafeAX = !AXTextContext.usesTerminalGridAX(app.bundleID)
            let currentSelection = AXClient.selectedRange(current, deadline: deadline)
            let replacedText: String?
            if !gridSafeAX {
                replacedText = nil
            } else if requireCapturedSelection, let currentSelection, currentSelection.length == 0 {
                replacedText = ""
            } else if requireCapturedSelection, let currentSelection, currentSelection.length <= 3_000 {
                replacedText = Self.boundedText(current, range: currentSelection, deadline: deadline)
            } else { replacedText = nil }
            guard AppIdentity.frontmost() == app else { return .appChanged }

            let finalFocus = Self.focusedElement(retryingIn: app, deadline: deadline)
            switch Self.identityDecision(anchor: focus,
                                         observation: Self.observation(finalFocus)) {
            case .secure: return .secureField
            case .unresponsive: return .appUnresponsive
            case .fieldUnavailable: return .fieldUnavailable
            case .fieldChanged, .appOnlyMatch: return .fieldChanged
            case .exactMatch: break
            }
            guard AppIdentity.frontmost() == app else { return .appChanged }
            guard let capturedSelection = selection else {
                return .selectionUnavailable
            }
            if requireCapturedSelection,
               !Self.selectionMatches(captured: capturedSelection,
                                      current: currentSelection) {
                return .selectionChanged
            }
            let baseline: (count: Int?, slice: String?, requestedLength: Int)
            if gridSafeAX, requireCapturedSelection, captureBaseline {
                baseline = PasteProbe.captureMutationBaseline(
                    element: current,
                    selection: capturedSelection
                )
            } else {
                baseline = (nil, nil, 16)
            }
            return .valid(PasteProbe(
                bundleID: app.bundleID,
                element: current,
                selectionBefore: capturedSelection,
                beforeCount: baseline.count,
                beforeSlice: baseline.slice,
                beforeSliceRequestedLength: baseline.requestedLength,
                replacedText: replacedText
            ))
        }
    }

    private static func selectionMatches(captured: CFRange?, current: CFRange?) -> Bool {
        guard let captured else { return false }
        guard let current else { return false }
        return captured.location == current.location && captured.length == current.length
    }

    static func appOnlyInteractionIsValid(capturedEpoch: UInt64,
                                          currentEpoch: UInt64) -> Bool {
        capturedEpoch == currentEpoch
    }

    private enum FocusLookup {
        case element(AXUIElement)
        case secure
        case unknownRole
        case unavailable
        case foreign
        case timedOut
    }

    private static func appOnlyValidation(_ current: FocusLookup) -> Validation {
        let anchor: FieldAnchor<ElementIdentity> = .appOnly
        switch identityDecision(anchor: anchor, observation: observation(current)) {
        case .appOnlyMatch: return .valid(nil)
        case .secure: return .secureField
        case .unresponsive: return .appUnresponsive
        case .fieldChanged, .exactMatch: return .fieldChanged
        case .fieldUnavailable: return .fieldUnavailable
        }
    }

    private static func observation(_ lookup: FocusLookup) -> FieldObservation<ElementIdentity> {
        switch lookup {
        case .element(let element): return .element(ElementIdentity(element: element))
        case .secure: return .secure
        case .unknownRole: return .unknownRole
        case .unavailable: return .unavailable
        case .foreign: return .foreign
        case .timedOut: return .timedOut
        }
    }

    private static func focusedElement(in app: AppIdentity,
                                       deadline: AXClient.Deadline) -> FocusLookup {
        switch AXClient.focusedElement(pid: app.pid, deadline: deadline) {
        case .element(let element): return .element(element)
        case .secure: return .secure
        case .unknownRole: return .unknownRole
        case .unavailable: return .unavailable
        case .foreign: return .foreign
        case .timedOut: return .timedOut
        }
    }

    /// Pure, deterministic hook for `--pastertest`.
    @discardableResult
    static func selfCheck() -> (checks: Int, failed: Int) {
        var checks = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            checks += 1
            if !ok { failed += 1; log("PASTETARGETTEST FAIL: \(name)") }
        }
        let a = AppIdentity(bundleID: "com.example.Editor", pid: 101)
        check("identity equals itself", a == a)
        check("different pid rejected",
              a != AppIdentity(bundleID: a.bundleID, pid: a.pid + 1))
        check("different bundle rejected",
              a != AppIdentity(bundleID: "com.example.Other", pid: a.pid))
        let before = CFRange(location: 9, length: 0)
        check("exact text plus caret transition confirms",
              PasteProbe.postcondition(before: before,
                                       after: CFRange(location: 12, length: 0),
                                       observed: "abc", text: "abc"))
        check("pre-existing identical text without caret transition rejected",
              !PasteProbe.postcondition(before: before, after: before,
                                        observed: "abc", text: "abc"))
        check("Rex and terminal 2D grid apps bypass grid AX paste polling",
              !PasteProbe(bundleID: "com.superlogical.rex",
                          selectionBefore: CFRange(location: 0, length: 0)).canObservePasteEffectViaAX
              && PasteProbe(bundleID: "com.apple.dt.Xcode",
                            selectionBefore: CFRange(location: 0, length: 0)).canObservePasteEffectViaAX)
        check("smart-paste leading space / moved caret reports valueChanged",
              PasteProbe.evaluateRangeConfirmation(
                  selectionBefore: before,
                  selectionAfter: CFRange(location: 13, length: 0),
                  observedAtTarget: " ab",
                  expectedText: "abc",
                  beforeCount: 9,
                  currentCount: 13,
                  beforeSlice: "",
                  currentSlice: " abc"
              ) == .valueChanged)
        check("unchanged pre-existing text with unchanged caret/count/slice stays mismatch",
              PasteProbe.evaluateRangeConfirmation(
                  selectionBefore: CFRange(location: 0, length: 0),
                  selectionAfter: CFRange(location: 0, length: 0),
                  observedAtTarget: "abc",
                  expectedText: "abc",
                  beforeCount: 10,
                  currentCount: 10,
                  beforeSlice: "abcdefghij",
                  currentSlice: "abcdefghij"
              ) == .mismatch)
        check("accepted-action selection remains pinned",
              selectionMatches(captured: CFRange(location: 9, length: 0),
                               current: CFRange(location: 9, length: 0)))
        check("moved caret is rejected",
              !selectionMatches(captured: CFRange(location: 9, length: 0),
                                current: CFRange(location: 10, length: 0)))
        check("changed selection length is rejected",
              !selectionMatches(captured: CFRange(location: 9, length: 2),
                                current: CFRange(location: 9, length: 0)))
        check("unreadable current range is rejected when capture was readable",
              !selectionMatches(captured: CFRange(location: 9, length: 0), current: nil))
        check("missing accepted-action range is rejected",
              !selectionMatches(captured: nil, current: CFRange(location: 10, length: 0)))
        func appOnlyAllows(_ lookup: FocusLookup) -> Bool {
            if case .valid(nil) = appOnlyValidation(lookup) { return true }
            return false
        }
        check("app-only fallback remains valid while AX stays unavailable",
              appOnlyAllows(.unavailable))
        check("app-only fallback rejects a newly observable field",
              !appOnlyAllows(.element(AXUIElementCreateSystemWide())))
        check("app-only fallback rejects a foreign focused element",
              !appOnlyAllows(.foreign))
        check("app-only fallback rejects a secure field",
              !appOnlyAllows(.secure))
        check("app-only fallback reports an unresponsive app as such",
              { if case .appUnresponsive = appOnlyValidation(.timedOut) { return true }
                return false }())
        check("unknown role without secure input is treated as unresponsive, not secure",
              { if case .appUnresponsive = appOnlyValidation(.unknownRole) { return true }
                return false }())
        log(failed == 0 ? "PASTETARGETTEST PASS (\(checks) checks)"
                        : "PASTETARGETTEST FAIL (\(failed)/\(checks) checks)")
        return (checks, failed)
    }
}
