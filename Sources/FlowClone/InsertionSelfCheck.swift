import Cocoa

/// Native acceptance: the real leased AX field -> formatter -> clipboard/Cmd-V -> readback.
/// Only disposable, visibly labelled controls are touched; normal dictation is never started.
@MainActor
enum InsertionSelfCheck {
    private struct Fixture {
        let name: String
        let before: String
        var selected = ""
        var after = ""
        let utterances: [String]
        let expected: String
        var field = false
    }

    static func run() {
        Task { @MainActor in
            // Standalone diagnostics intentionally skip the production menu. Provide the
            // standard responder-chain Paste command so Cmd-V reaches these scratch fields.
            let priorMenu = NSApp.mainMenu
            let menu = NSMenu()
            let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            edit.submenu = NSMenu(title: "Edit")
            edit.submenu?.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
            menu.addItem(edit)
            NSApp.mainMenu = menu
            defer { NSApp.mainMenu = priorMenu }
            let window = NSWindow(contentRect: NSRect(x: 200, y: 250, width: 700, height: 280),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "FlowClone insertion test — disposable text"
            window.isReleasedWhenClosed = false
            let editor = NSTextView(frame: NSRect(x: 20, y: 70, width: 660, height: 180))
            editor.isRichText = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 660, height: 30))
            window.contentView?.addSubview(editor)
            window.contentView?.addSubview(field)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            let fixtures: [Fixture] = [
                .init(name: "two-dictations-one-sentence", before: "", utterances: ["I think", "The report is ready."],
                      expected: "I think the report is ready."),
                .init(name: "two-dictations-new-sentence", before: "", utterances: ["The report is ready.", "then send it."],
                      expected: "The report is ready. Then send it."),
                .init(name: "middle-of-sentence", before: "We need ", after: "today.", utterances: ["The report."],
                      expected: "We need the report today."),
                .init(name: "replace-selection-and-spaces", before: "We need", selected: " the old plan ", after: "today.",
                      utterances: ["The new plan."], expected: "We need the new plan today."),
                .init(name: "quoted-sentence-ending", before: "She said “done.” ", utterances: ["the next task."],
                      expected: "She said “done.” The next task."),
                .init(name: "new-paragraph", before: "Paragraph one.\n\n", utterances: ["the next paragraph."],
                      expected: "Paragraph one.\n\nThe next paragraph."),
                .init(name: "existing-punctuation", before: "Here is ", after: ".", utterances: ["The report."],
                      expected: "Here is the report."),
                .init(name: "unicode-range", before: "😀 We need ", after: "today.", utterances: ["The report."],
                      expected: "😀 We need the report today."),
                .init(name: "native-text-field", before: "I think ", utterances: ["The report is ready."],
                      expected: "I think the report is ready.", field: true),
            ]
            var passed = 0
            var failed = 0
            for fixture in fixtures {
                let initial = fixture.before + fixture.selected + fixture.after
                if fixture.field {
                    field.stringValue = initial
                    window.makeFirstResponder(field)
                    (window.fieldEditor(true, for: field) as? NSTextView)?.setSelectedRange(
                        NSRange(location: fixture.before.utf16.count, length: fixture.selected.utf16.count))
                } else {
                    editor.string = initial
                    window.makeFirstResponder(editor)
                    editor.setSelectedRange(NSRange(location: fixture.before.utf16.count,
                                                    length: fixture.selected.utf16.count))
                }
                try? await Task.sleep(for: .milliseconds(100))
                var ok = true
                for text in fixture.utterances {
                    guard let identity = PasteTarget.AppIdentity.frontmost(),
                          identity.pid == ProcessInfo.processInfo.processIdentifier else { ok = false; break }
                    let target = await Task.detached {
                        PasteTarget.capture(for: identity, interactionEpoch: FocusInteractionEpoch.snapshot())
                    }.value
                    guard let target else { ok = false; break }
                    let start = ProcessInfo.processInfo.systemUptime
                    let context = await Task.detached { target.captureDictationContext() }.value
                    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    log(String(format: "INSERTIONTEST context %@ before=%d after=%d ms=%.1f", fixture.name,
                               context.continuationPrefix?.utf16.count ?? -1,
                               context.continuationSuffix?.utf16.count ?? -1, elapsed))
                    guard context.continuationPrefix != nil else { ok = false; break }
                    let output = InsertionFormatter.format(text, context: context.insertion)
                    let result = await withCheckedContinuation { continuation in
                        Paster.paste(output, expectedTarget: target) { continuation.resume(returning: $0) }
                    }
                    switch result {
                    case .posted(_, .targetConfirmed, _): break
                    case .posted: log("INSERTIONTEST unverified delivery: \(fixture.name)"); ok = false
                    case .ambiguous(_, _, let why), .notPosted(_, let why):
                        log("INSERTIONTEST delivery refused \(fixture.name): \(why)"); ok = false
                    case .skippedEmpty: ok = false
                    }
                    if !ok { break }
                }
                let actual = fixture.field ? field.stringValue : editor.string
                ok = ok && actual == fixture.expected
                log("INSERTIONTEST \(ok ? "ok" : "FAIL"): \(fixture.name)")
                if ok { passed += 1 } else { failed += 1 }
            }
            log(failed == 0 ? "INSERTIONTEST PASS (\(passed) native cases)" : "INSERTIONTEST FAIL (\(failed)/\(fixtures.count))")
            flushLog()
        }
    }
}
