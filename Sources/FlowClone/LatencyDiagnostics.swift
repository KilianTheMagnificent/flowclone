import Cocoa
import AVFoundation
import CoreAudio

/// Exercises the real AX lease and shared context budget in an owned scratch editor.
@MainActor
func runContextLatencyDiagnostic() {
    Task { @MainActor in
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FlowClone local context test"
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        let fixture = "FlowClone context fixture. "
        field.string = fixture
        field.setSelectedRange(NSRange(location: fixture.utf16.count, length: 0))
        window.contentView = field
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1.5))
        let lease = Paster.beginTargetCapture(for: PasteTarget.AppIdentity.frontmost())
        let captured = await withCheckedContinuation { continuation in
            Paster.resolveTargetCapture(lease) { continuation.resume(returning: $0) }
        }
        var passed = false
        if case .captured(let target) = captured,
           target.app.pid == ProcessInfo.processInfo.processIdentifier {
            let probe = DictationContextCapture.shared.start { deadline in
                let start = DispatchTime.now()
                let context = target.captureDictationContext(deadline: deadline)
                log(String(format: "CONTEXTLATENCY capture_ms=%.1f prefix_chars=%d",
                           ms(start, .now()), context.continuationPrefix?.count ?? 0))
                return context
            }
            try? await Task.sleep(for: .milliseconds(150))
            passed = probe.take().continuationPrefix == fixture
            // A caret move invalidates the original lease. Optional capture must drop
            // it, and strict validation must still refuse that same target. (The paste
            // gate, `revalidateForPaste`, follows a move made with no physical input.)
            field.setSelectedRange(NSRange(location: 0, length: 0))
            let safe = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let context = target.captureDictationContext()
                    let refused: Bool
                    if case .selectionChanged = target.revalidate() { refused = true }
                    else { refused = false }
                    continuation.resume(returning: context.continuationPrefix == nil
                                        && context.terms.isEmpty && refused)
                }
            }
            passed = passed && safe
            log("CONTEXTLATENCY changed_selection_refused=\(safe)")
        }
        log(passed ? "CONTEXTLATENCY PASS" : "CONTEXTLATENCY FAIL")
        flushLog()
        window.close()
        NSApp.terminate(nil)
    }
}

/// Explicit signed probes only. No transcript/audio persistence and no production startup.
@MainActor
func runPasteLatencyDiagnostic() {
    Task { @MainActor in
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 520, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FlowClone local paste latency test"
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        field.isRichText = false
        window.contentView = field
        // Standalone probes skip the app's normal menu setup. Supply the standard
        // key equivalent so Cmd+V actually invokes paste in this owned scratch field.
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        paste.target = field
        edit.addItem(paste)
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1.5))
        var durations: [Int: [Double]] = [:]
        var failures = 0
        for i in 0..<20 {
            guard window.isVisible else { failures += 1; break }
            let delay = i.isMultiple(of: 2) ? 100 : 20
            field.string = ""
            field.setSelectedRange(NSRange(location: 0, length: 0))
            let expected = "FlowClone latency trial \(i)."
            let lease = Paster.beginTargetCapture(for: PasteTarget.AppIdentity.frontmost())
            let target = await withCheckedContinuation { continuation in
                Paster.resolveTargetCapture(lease) { continuation.resume(returning: $0) }
            }
            guard case .captured(let target) = target,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                failures += 1; log("PASTELATENCY FAIL target changed; no paste attempted"); break
            }
            let start = DispatchTime.now()
            let result = await withCheckedContinuation { continuation in
                Paster.paste(expected, expectedTarget: target, settlingDelay: Double(delay) / 1_000) {
                    continuation.resume(returning: $0)
                }
            }
            let elapsed = ms(start, .now())
            // This owned NSTextView is an independent exact readback even when its AX
            // implementation cannot expose a parameterized range to the paste worker.
            if case .posted = result, field.string == expected {
                durations[delay, default: []].append(elapsed)
                log(String(format: "PASTELATENCY confirmed delay_ms=%d total_ms=%.1f", delay, elapsed))
            } else {
                failures += 1
                switch result {
                case .notPosted(_, let why), .ambiguous(_, _, let why):
                    log("PASTELATENCY FAIL delay_ms=\(delay) reason=\(why) exact_readback=\(field.string == expected)")
                case .posted: log("PASTELATENCY FAIL posted but exact readback differs")
                case .skippedEmpty: log("PASTELATENCY FAIL empty trial")
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for delay in [100, 20] {
            let times = (durations[delay] ?? []).sorted()
            if !times.isEmpty {
                log(String(format: "PASTELATENCY summary delay_ms=%d count=%d median_ms=%.1f",
                           delay, times.count, times[times.count / 2]))
            }
        }
        let passed = failures == 0 && durations[100]?.count == 10 && durations[20]?.count == 10
        log(passed ? "PASTELATENCY PASS" : "PASTELATENCY FAIL")
        flushLog()
        window.close()
        NSApp.terminate(nil)
    }
}

func runRecorderLatencyDiagnostic() {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        log("MICLATENCY FAIL microphone permission unavailable"); return
    }
    RecorderLatencyProbe().start()
}

private final class RecorderLatencyProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.andre.flowclone.mic-latency-test")
    private lazy var recorder = Recorder(queue: queue, idleDelay: 0.2)
    private var trialIndex = 0
    private var failed = false

    func start() {
        queue.async {
            self.recorder.primeAsync { ready, _ in
                guard ready else { self.finish(false); return }
                self.trial()
            }
        }
    }

    private func trial() {
        let start = DispatchTime.now()
        recorder.begin { opened in
            guard opened else { self.finish(false); return }
            log(String(format: "MICLATENCY begin trial=%d open_ms=%.1f", self.trialIndex, ms(start, .now())))
            self.queue.asyncAfter(deadline: .now() + 1) {
                let count = self.recorder.end().count
                self.failed = self.failed || count == 0
                log("MICLATENCY capture trial=\(self.trialIndex) samples=\(count)")
                self.queue.asyncAfter(deadline: .now() + 0.7) {
                    self.recorder.diagnosticState { first in
                        // Include a long paused interval, beyond the normal warm window.
                        let interval = self.trialIndex == 1 ? 31.0 : 3.0
                        self.queue.asyncAfter(deadline: .now() + interval) {
                            self.recorder.diagnosticState { last in
                                let quiet = first.paused && last.paused && !first.running && !last.running
                                    && first.callbacks == last.callbacks
                                let hardware = Self.hardwareRunning(last.device)
                                log("MICLATENCY idle trial=\(self.trialIndex) seconds=\(interval) " +
                                    "paused=\(last.paused) engine_running=\(last.running) " +
                                    "new_callbacks=\(last.callbacks - first.callbacks) hardware_running=\(hardware)")
                                self.failed = self.failed || !quiet || hardware != 0
                                self.trialIndex += 1
                                if self.trialIndex < 3 { self.trial() }
                                else { self.finish(!self.failed) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func hardwareRunning(_ device: AudioDeviceID?) -> Int {
        guard let device else { return -1 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return -1 }
        return Int(value)
    }

    private func finish(_ passed: Bool) {
        recorder.shutdownForDiagnostic()
        log(passed ? "MICLATENCY PASS" : "MICLATENCY FAIL")
        flushLog()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
