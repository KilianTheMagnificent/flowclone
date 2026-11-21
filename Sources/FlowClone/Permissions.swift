// The three TCC grants plus the hotkey proof, shared by the Settings page and the launch
// check. The hotkey row only greens on an observed event (tap creation alone false-greens,
// RESEARCH.md §5). Main thread only. Never test with `tccutil reset`.
import AVFoundation
import Cocoa
import IOKit.hid

@MainActor
enum Permissions {
    struct Grant: Identifiable {
        let id: String                       // display name
        let check: @MainActor () -> Bool
        let pane: String?                    // Privacy pane anchor; nil = nothing to open
    }

    /// Wired by the app delegate to the event tap's "saw a real event" flag.
    static var hotkeyVerified: () -> Bool = { false }
    /// Wired by the app delegate; idempotently starts the tap once AX is granted.
    static var onHotkeyRearm: () -> Void = {}

    static let grants: [Grant] = [
        Grant(id: "Microphone",
              check: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
              pane: "Privacy_Microphone"),
        Grant(id: "Accessibility",
              check: { AXIsProcessTrusted() },
              pane: "Privacy_Accessibility"),
        Grant(id: "Input Monitoring",
              check: { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted },
              pane: "Privacy_ListenEvent"),
        Grant(id: "Hotkey verified",
              check: { hotkeyVerified() },
              pane: nil),
    ]

    /// True when any of the three grants is missing (the hotkey row is not a grant).
    static var grantsMissing: Bool { !grants.prefix(3).allSatisfy { $0.check() } }

    nonisolated static func settingsURL(pane: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    static func openPane(_ pane: String) {
        guard let url = settingsURL(pane: pane) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fire the actual TCC prompts (first run); the rows then track the grants live.
    static func requestAll() {
        if suppressHostAccess {
            if handsfreeSession { Handsfree.log("blocked permission prompts") }
            return
        }
        log("--- requesting permissions ---")
        AVCaptureDevice.requestAccess(for: .audio) { log("AVCaptureDevice.requestAccess(.audio) -> \($0)") }
        // The public AX constant is imported as mutable shared state. Its documented raw
        // key avoids crossing that unsafe global while preserving the exact API contract.
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("AXIsProcessTrustedWithOptions(prompt:true) -> \(trusted)")
        log("IOHIDRequestAccess(listenEvent) -> \(IOHIDRequestAccess(kIOHIDRequestTypeListenEvent))")
    }
}
