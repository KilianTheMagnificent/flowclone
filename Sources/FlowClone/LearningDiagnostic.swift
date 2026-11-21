import Cocoa

/// Signed, explicitly invoked scratch-editor probe. Uses the real paste lease, AX reader,
/// monitor, spelling filter, store, and Cleaner, but never writes production corrections.
@MainActor
func runLearningDiagnostic() {
    Task { @MainActor in
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-learn-probe-\(UUID())")
        let store = PersonalizationStore(root: root)
        let monitor = TypedCorrectionMonitor()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 620, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FlowClone correction test — preparing"
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 16, y: 16, width: 588, height: 188))
        field.font = .systemFont(ofSize: 20)
        field.isRichText = false
        field.isAutomaticSpellingCorrectionEnabled = false
        window.contentView?.addSubview(field)
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        paste.target = field
        edit.addItem(paste); editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            monitor.stop()
            window.close()
            try? FileManager.default.removeItem(at: root)
            flushLog()
            NSApp.terminate(nil)
        }
        try? await Task.sleep(for: .seconds(1.5))

        @MainActor func pasteIntoScratch(_ text: String) async -> (PasteTarget, PasteTarget.ConfirmedInsertion)? {
            guard window.isVisible,
                  PasteTarget.AppIdentity.frontmost()?.pid == ProcessInfo.processInfo.processIdentifier else { return nil }
            let lease = Paster.beginTargetCapture(for: PasteTarget.AppIdentity.frontmost())
            let capture = await withCheckedContinuation { continuation in
                Paster.resolveTargetCapture(lease) { continuation.resume(returning: $0) }
            }
            guard case .captured(let target) = capture,
                  target.app.pid == ProcessInfo.processInfo.processIdentifier else { return nil }
            let result = await withCheckedContinuation { continuation in
                Paster.paste(text, expectedTarget: target) { continuation.resume(returning: $0) }
            }
            guard case .posted(_, .targetConfirmed(let insertion), _) = result else { return nil }
            return (target, insertion)
        }

        let original = "Please use Kubernets tomorrow."
        let corrected = "Please use Kubernetes tomorrow."
        guard let (target, insertion) = await pasteIntoScratch(original) else {
            log("LEARNTEST FAIL initial paste not confirmed"); return
        }
        var saved: AutoLearn.SavedBatch?
        monitor.start(.init(target: target, insertion: insertion, text: original, date: Date(), hadContextRewrite: false)) { pairs in
            saved = AutoLearn.learn(pairs, app: "owned scratch editor", store: store, report: false)
        }
        // Give the monitor its baseline before editing; no next recording is invoked.
        try? await Task.sleep(for: .seconds(1.5))
        let range = (original as NSString).range(of: "Kubernets")
        field.setSelectedRange(range)
        let manual = ProcessInfo.processInfo.arguments.contains("--learnmanual")
        window.title = "Correction test — type Kubernetes over the selected word"
        log("LEARNTEST ready manual=\(manual)")
        if !manual { field.insertText("Kubernetes", replacementRange: range) }
        for _ in 0..<(manual ? 180 : 20) {
            try? await Task.sleep(for: .seconds(1))
            if saved != nil || !window.isVisible { break }
        }
        guard let saved else { log("LEARNTEST FAIL no automatic save"); return }
        monitor.stop()
        do {
            let disk = try PersonalizationStore(root: root).snapshot(.correction)
            guard disk.entries.count == 1, disk.entries.first?.replacement == "Kubernetes" else {
                log("LEARNTEST FAIL persistence"); return
            }
            let next = Cleaner.withPersonalizationStore(store) { Cleaner.clean(original) }
            guard next == corrected else { log("LEARNTEST FAIL next cleanup"); return }
            field.string = ""
            field.setSelectedRange(NSRange(location: 0, length: 0))
            guard await pasteIntoScratch(next) != nil, field.string == corrected else {
                log("LEARNTEST FAIL next paste"); return
            }
            try store.undo(saved.undo)
            let undone = Cleaner.withPersonalizationStore(store) { Cleaner.clean(original) }
            guard undone == original, try store.snapshot(.correction).entries.isEmpty else {
                log("LEARNTEST FAIL undo"); return
            }
            log("LEARNTEST PASS confirmed paste, \(manual ? "keyboard" : "native editor") edit, automatic save, disk reload, next cleanup/paste, undo; isolated store")
        } catch { log("LEARNTEST FAIL store operation") }
    }
}
