import Carbon
import Cocoa
import Foundation
import os

/// Shared fail-closed Accessibility transport and secure-field policy. Every operation owns
/// one absolute deadline; individual AX messages receive only the remaining slice so a chain
/// of reads cannot multiply the nominal timeout.
enum AXClient {
    private static let secureInputProvider = OSAllocatedUnfairLock<@Sendable () -> Bool>(
        initialState: { IsSecureEventInputEnabled() }
    )

    static func isSecureInputEnabled() -> Bool {
        secureInputProvider.withLock { $0 }()
    }

    static let secureFieldMessage = "Dictation is blocked in password and secure fields."

    /// The app holding Secure Input, as the window server records it (the responsible app,
    /// so a helper's prompt names its host). nil when Secure Input is off.
    static func secureInputOwnerPID() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              pid > 0 else { return nil }
        return pid
    }

    /// What to tell the user when dictation is refused for Secure Input. A password field in
    /// the app being dictated into is the expected case. But a background app can hold Secure
    /// Input on its own (a password manager's prompt, an app that never released it), and then
    /// every dictation everywhere is refused: name that app, or the user cannot find the cause.
    static func secureInputBlockedMessage(ownerName: String?, ownerIsFrontmost: Bool) -> String {
        guard let ownerName, !ownerName.isEmpty, !ownerIsFrontmost else { return secureFieldMessage }
        return "Dictation is blocked because \(ownerName) has Secure Input turned on, which hides "
            + "typing from other apps. Close its password prompt or quit \(ownerName) to dictate again."
    }

    static func secureBlockedMessage() -> String {
        guard isSecureInputEnabled(), let pid = secureInputOwnerPID(),
              pid != ProcessInfo.processInfo.processIdentifier else { return secureFieldMessage }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return secureInputBlockedMessage(
            ownerName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            ownerIsFrontmost: pid == frontmost)
    }

    static func setSecureInputProviderForTesting(_ provider: (@Sendable () -> Bool)?) {
        secureInputProvider.withLock {
            $0 = provider ?? { IsSecureEventInputEnabled() }
        }
    }

    /// Bounded text only, after the caller validates field identity and security. Always
    /// attempts parameterized `kAXStringForRangeParameterizedAttribute` first (even when
    /// `range.location == 0`) before falling back to a bounded `kAXValueAttribute` slice.
    static func textRange(_ element: AXUIElement, range: CFRange,
                          deadline: Deadline) -> String? {
        readTextRange(range, readRange: { requested in
            var copy = requested
            guard let value = AXValueCreate(.cfRange, &copy) else { return nil }
            return parameterizedAttribute(element, kAXStringForRangeParameterizedAttribute as CFString,
                                          parameter: value, deadline: deadline)
        }, readCount: {
            numberAttribute(element, kAXNumberOfCharactersAttribute as CFString, deadline: deadline)
        }, readValue: {
            stringAttribute(element, kAXValueAttribute as CFString, deadline: deadline)
        })
    }

    static func readTextRange(_ range: CFRange,
                              readRange: (CFRange) -> String?,
                              readCount: () -> Int?, readValue: () -> String?) -> String? {
        guard range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        if range.length == 0 { return "" }
        if let text = readRange(range), text.utf16.count == range.length { return text }
        guard let count = readCount(), (0...4_096).contains(count),
              range.location <= count, range.length <= count - range.location,
              let text = readValue(), text.utf16.count == count,
              let indices = Range(NSRange(location: range.location, length: range.length), in: text)
        else { return nil }
        let result = String(text[indices])
        return result.utf16.count == range.length ? result : nil
    }

    /// Reads the entire field value ONLY when its reported character count is small (<= 4,096).
    static func boundedValue(_ element: AXUIElement, maxCharacters: Int = 4_096,
                             deadline: Deadline) -> String? {
        if let count = numberAttribute(element, kAXNumberOfCharactersAttribute as CFString,
                                       deadline: deadline) {
            guard (0...maxCharacters).contains(count),
                  let text = stringAttribute(element, kAXValueAttribute as CFString,
                                             deadline: deadline),
                  text.utf16.count <= maxCharacters else { return nil }
            return text
        }
        return nil
    }

    enum Metadata<Value> {
        case value(Value)
        case absent
        case failed
        /// Budget expired before or during the IPC call, or `.cannotComplete` arrived at/near
        /// timeout expiry. Distinct from `.failed` because a slow app is not a password field.
        case timedOut
    }

    enum Security: Equatable {
        case ordinary
        case secure
        case unknown
        case timedOut
    }

    enum FocusedElement: @unchecked Sendable {
        case element(AXUIElement)
        /// Confirmed secure input (`IsSecureEventInputEnabled()` or explicit `AXSecureTextField` /
        /// `containsProtectedContent == true`).
        case secure
        /// Element returned, but role/subrole could not be read (`Security.unknown`). Transiently
        /// unreadable, NOT a confirmed password field.
        case unknownRole
        case unavailable
        case foreign
        case timedOut
    }

    /// Pure classification for the focused-element transport.
    enum FocusReadDisposition: Equatable {
        case element
        case unavailable
        case unresponsive
    }

    static func focusReadDisposition(error: AXError, hasElement: Bool) -> FocusReadDisposition {
        if error == .success, hasElement { return .element }
        if error == .noValue || error == .attributeUnsupported { return .unavailable }
        return .unresponsive
    }

    struct Deadline {
        private let expiresAt: TimeInterval
        private let perCall: Float
        private let clock: () -> TimeInterval
        private let isCancelled: () -> Bool

        init(total: TimeInterval = 0.12, perCall: Float = 0.05,
             isCancelled: @escaping () -> Bool = { false },
             clock: @escaping () -> TimeInterval = {
                 ProcessInfo.processInfo.systemUptime
             }) {
            self.clock = clock
            self.isCancelled = isCancelled
            expiresAt = clock() + max(0, total)
            self.perCall = max(0, perCall)
        }

        func now() -> TimeInterval { clock() }

        var hasTimeRemaining: Bool { !isCancelled() && clock() < expiresAt }

        func nextTimeout() -> Float? {
            let remaining = expiresAt - clock()
            guard !isCancelled(), remaining > 0, perCall > 0 else { return nil }
            let timeout = min(perCall, Float(remaining))
            return timeout > 0 ? timeout : nil
        }

        func configureWithTimeout(_ element: AXUIElement) -> Float? {
            guard let timeout = nextTimeout(),
                  AXUIElementSetMessagingTimeout(element, timeout) == .success,
                  hasTimeRemaining else { return nil }
            return timeout
        }

        func configure(_ element: AXUIElement) -> Bool {
            configureWithTimeout(element) != nil
        }
    }

    static func focusedElement(pid: pid_t, deadline: Deadline = Deadline()) -> FocusedElement {
        if isSecureInputEnabled() { return .secure }
        guard pid > 0 else { return .unavailable }
        let app = AXUIElementCreateApplication(pid)
        guard deadline.configure(app) else { return .timedOut }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &raw)
        if !deadline.hasTimeRemaining { return .timedOut }
        let hasElement = raw.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
        switch focusReadDisposition(error: error, hasElement: hasElement) {
        case .unavailable:
            return .unavailable
        case .unresponsive:
            return .timedOut
        case .element:
            break
        }
        guard deadline.hasTimeRemaining, let raw else { return .timedOut }
        let focused = raw as! AXUIElement
        var observedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &observedPID) == .success else {
            return .timedOut
        }
        guard observedPID == pid else { return .foreign }
        guard deadline.hasTimeRemaining else { return .timedOut }
        if isSecureInputEnabled() { return .secure }
        switch securityStatus(focused, deadline: deadline) {
        case .ordinary: return .element(focused)
        case .secure: return .secure
        case .unknown: return .unknownRole
        case .timedOut: return .timedOut
        }
    }

    static func securityStatus(_ element: AXUIElement,
                               deadline: Deadline = Deadline()) -> Security {
        if isSecureInputEnabled() { return .secure }
        let role: Metadata<String> = attribute(element, kAXRoleAttribute as CFString,
                                               required: true, deadline: deadline)
        let subrole: Metadata<String> = attribute(element, kAXSubroleAttribute as CFString,
                                                  required: false, deadline: deadline)
        let protected: Metadata<Bool> = boolAttribute(
            element,
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            required: false,
            deadline: deadline)
        return classify(role: role, subrole: subrole, protectedContent: protected)
    }

    /// An answer the app actually gave still decides — a proven secure role or subrole is
    /// secure however the reads after it ended. `.timedOut` is only returned for the read
    /// that would have decided, so the caller can retry instead of refusing a slow app.
    static func classify(role: Metadata<String>, subrole: Metadata<String>,
                         protectedContent: Metadata<Bool>) -> Security {
        if case .timedOut = role { return .timedOut }
        guard case .value(let roleName) = role else { return .unknown }
        if roleName == "AXSecureTextField" { return .secure }
        switch subrole {
        case .value(let name) where name == (kAXSecureTextFieldSubrole as String):
            return .secure
        case .value, .absent:
            break
        case .timedOut:
            return .timedOut
        case .failed:
            return .unknown
        }
        switch protectedContent {
        case .value(true): return .secure
        case .value(false), .absent: return .ordinary
        case .timedOut: return .timedOut
        case .failed: return .unknown
        }
    }

    static func selectedRange(_ element: AXUIElement,
                              deadline: Deadline = Deadline(total: 0.06)) -> CFRange? {
        guard let range = rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString,
                                         deadline: deadline), range.location >= 0 else { return nil }
        return range
    }

    static func stringAttribute(_ element: AXUIElement, _ name: CFString,
                                deadline: Deadline = Deadline(total: 0.06)) -> String? {
        guard let raw = rawAttribute(element, name, deadline: deadline) else { return nil }
        return raw as? String
    }

    static func elementAttribute(_ element: AXUIElement, _ name: CFString,
                                 deadline: Deadline) -> AXUIElement? {
        guard let raw = rawAttribute(element, name, deadline: deadline),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func numberAttribute(_ element: AXUIElement, _ name: CFString,
                                deadline: Deadline) -> Int? {
        guard let raw = rawAttribute(element, name, deadline: deadline),
              let number = raw as? NSNumber else { return nil }
        return number.intValue
    }

    static func rangeAttribute(_ element: AXUIElement, _ name: CFString,
                               deadline: Deadline) -> CFRange? {
        guard let raw = rawAttribute(element, name, deadline: deadline),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
    }

    static func parameterizedAttribute<T>(_ element: AXUIElement, _ name: CFString,
                                          parameter: CFTypeRef,
                                          deadline: Deadline) -> T? {
        guard deadline.configure(element) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, name, parameter, &raw
        ) == .success, deadline.hasTimeRemaining else { return nil }
        return raw as? T
    }

    static func isAttributeSettable(_ element: AXUIElement, _ name: CFString,
                                    deadline: Deadline) -> Bool {
        guard deadline.configure(element) else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name, &settable) == .success
            && deadline.hasTimeRemaining
            && settable.boolValue
    }

    static func setAttribute(_ element: AXUIElement, _ name: CFString,
                             value: CFTypeRef, deadline: Deadline) -> Bool {
        guard deadline.configure(element) else { return false }
        return AXUIElementSetAttributeValue(element, name, value) == .success
    }

    private static func rawAttribute(_ element: AXUIElement, _ name: CFString,
                                     deadline: Deadline) -> CFTypeRef? {
        guard deadline.configure(element) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &raw) == .success,
              deadline.hasTimeRemaining else { return nil }
        return raw
    }

    /// Pure classification of an attribute IPC reply. Any call that exhausts the deadline —
    /// or returns `.cannotComplete` at/near per-call timeout expiry — is `.timedOut`, never
    /// `.failed`, so a momentarily busy app (>45 ms AX reply) is not mistaken for a password field.
    static func attributeMetadata<T>(
        error: AXError,
        raw: Any?,
        required: Bool,
        hasTimeRemaining: Bool,
        callElapsed: TimeInterval = 0,
        callTimeout: Float? = nil
    ) -> Metadata<T> {
        guard hasTimeRemaining else { return .timedOut }
        if error == .cannotComplete,
           let callTimeout, callTimeout > 0,
           callElapsed >= Double(callTimeout) * 0.75 {
            return .timedOut
        }
        if error == .success, let value = raw as? T { return .value(value) }
        if !required, error == .noValue || error == .attributeUnsupported { return .absent }
        return .failed
    }

    static func attribute<T>(_ element: AXUIElement, _ name: CFString,
                             required: Bool, deadline: Deadline) -> Metadata<T> {
        guard let assignedTimeout = deadline.configureWithTimeout(element) else {
            return deadline.hasTimeRemaining ? .failed : .timedOut
        }
        let started = deadline.now()
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &raw)
        let elapsed = max(0, deadline.now() - started)
        return attributeMetadata(
            error: error,
            raw: raw,
            required: required,
            hasTimeRemaining: deadline.hasTimeRemaining,
            callElapsed: elapsed,
            callTimeout: assignedTimeout
        )
    }

    static func boolAttribute(_ element: AXUIElement, _ name: CFString,
                              required: Bool, deadline: Deadline) -> Metadata<Bool> {
        let raw: Metadata<NSNumber> = attribute(element, name, required: required,
                                                deadline: deadline)
        switch raw {
        case .value(let value): return .value(value.boolValue)
        case .absent: return .absent
        case .failed: return .failed
        case .timedOut: return .timedOut
        }
    }
}

extension AXClient.Metadata: Equatable where Value: Equatable {}
