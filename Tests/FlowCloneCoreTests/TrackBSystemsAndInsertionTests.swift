import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import XCTest
@testable import FlowCloneCore

final class TrackBSystemsAndInsertionTests: XCTestCase {

    // MARK: - 1. Hotkey Focus-Epoch Ordering & Shortcut Ergonomics

    func testSwallowedEscapeAndConfiguredShortcutsNeverAdvanceFocusEpoch() throws {
        let queue = DispatchQueue(label: "TrackB.hotkey.epoch")
        let monitor = HotkeyMonitor(queue: queue)
        let toggleBinding = ShortcutBinding(
            action: .handsFree,
            keyCode: 49, // Space
            modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue,
            keyLabel: "Space"
        )
        let transformBinding = ShortcutBinding(
            shortcutAction: .transformSelection,
            keyCode: 17, // T
            modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue,
            keyLabel: "t"
        )
        let bindings = ShortcutBinding.defaults + [toggleBinding, transformBinding]
        var firedActions: [FlowAction] = []
        var firedShortcutActions: [ShortcutAction] = []
        monitor.onAction = { action, _ in firedActions.append(action) }
        monitor.onShortcutAction = { action, _ in firedShortcutActions.append(action) }

        let src = try XCTUnwrap(CGEventSource(stateID: .privateState))

        // 1. Swallowed Escape while capture is active must NOT advance FocusInteractionEpoch.
        monitor.setCaptureActive(true)
        let epochBeforeEsc = FocusInteractionEpoch.snapshot()
        let escDown = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true))
        XCTAssertTrue(monitor.handleTapEvent(type: .keyDown, event: escDown, bindings: bindings))
        XCTAssertEqual(FocusInteractionEpoch.snapshot(), epochBeforeEsc,
                       "Swallowed Escape must not advance focusEpoch")

        // 2. Swallowed configured Hands-Free shortcut (Ctrl+Opt+Space) must NOT advance FocusInteractionEpoch.
        monitor.setCaptureActive(false)
        let epochBeforeShortcut = FocusInteractionEpoch.snapshot()
        let spaceDown = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true))
        spaceDown.flags = [.maskControl, .maskAlternate]
        let spaceUp = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false))
        spaceUp.flags = [.maskControl, .maskAlternate]
        XCTAssertTrue(monitor.handleTapEvent(type: .keyDown, event: spaceDown, bindings: bindings))
        XCTAssertTrue(monitor.handleTapEvent(type: .keyUp, event: spaceUp, bindings: bindings))
        XCTAssertEqual(FocusInteractionEpoch.snapshot(), epochBeforeShortcut,
                       "Stopping/toggling dictation via configured shortcut must not advance focusEpoch")
        XCTAssertEqual(firedActions, [.handsFree])

        // 3. Swallowed Transform Selection shortcut (Ctrl+Shift+T) fires ShortcutAction without advancing focusEpoch.
        let tDown = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: 17, keyDown: true))
        tDown.flags = [.maskControl, .maskShift]
        let tUp = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: 17, keyDown: false))
        tUp.flags = [.maskControl, .maskShift]
        XCTAssertTrue(monitor.handleTapEvent(type: .keyDown, event: tDown, bindings: bindings))
        XCTAssertTrue(monitor.handleTapEvent(type: .keyUp, event: tUp, bindings: bindings))
        XCTAssertEqual(FocusInteractionEpoch.snapshot(), epochBeforeShortcut)
        XCTAssertEqual(firedShortcutActions, [.transformSelection])

        // 4. Unconsumed ordinary keyDown DOES advance FocusInteractionEpoch.
        let aDown = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true))
        XCTAssertFalse(monitor.handleTapEvent(type: .keyDown, event: aDown, bindings: bindings))
        XCTAssertEqual(FocusInteractionEpoch.snapshot(), epochBeforeShortcut + 1)

        // Drain async queue work cleanly.
        queue.sync {}
    }

    func testContaminatedModifierChordsWithin360msNeverLatchHandsFree() throws {
        final class Clock: @unchecked Sendable {
            var nowMS = 1_000.0
        }
        let clock = Clock()
        let queue = DispatchQueue(label: "TrackB.hotkey.chords")
        let monitor = HotkeyMonitor(queue: queue, clockMS: { clock.nowMS })
        var edges: [HotkeyEdge] = []
        monitor.onEdge = { edge in
            edges.append(edge)
            if edge == .up {
                monitor.armIfTap()
            }
        }
        let bindings = ShortcutBinding.defaults
        let src = try XCTUnwrap(CGEventSource(stateID: .privateState))

        func sendFlags(_ keyCode: CGKeyCode, _ flags: CGEventFlags) throws {
            let ev = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true))
            ev.type = .flagsChanged
            ev.flags = flags
            _ = monitor.handleTapEvent(type: .flagsChanged, event: ev, bindings: bindings)
            queue.sync {}
        }

        func sendKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) throws {
            let ev = try XCTUnwrap(CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down))
            ev.flags = flags
            _ = monitor.handleTapEvent(type: down ? .keyDown : .keyUp, event: ev, bindings: bindings)
            queue.sync {}
        }

        // Case A: Two Ctrl+Opt+Shift chords within 250 ms must NEVER latch hands-free.
        for cycle in 0..<2 {
            clock.nowMS = 1_000.0 + Double(cycle) * 200.0
            try sendFlags(59, [.maskControl])
            clock.nowMS += 10
            try sendFlags(58, [.maskControl, .maskAlternate])
            clock.nowMS += 15
            try sendFlags(56, [.maskControl, .maskAlternate, .maskShift])
            clock.nowMS += 30
            try sendFlags(56, [.maskControl, .maskAlternate])
            clock.nowMS += 10
            try sendFlags(58, [.maskControl])
            clock.nowMS += 10
            try sendFlags(59, [])
        }
        XCTAssertFalse(edges.contains(.latched),
                       "Ctrl+Opt+Shift x2 within 360 ms must never latch hands-free: \(edges)")

        // Case A2: Shift held FIRST (`Shift+Ctrl+Opt` released Shift-first!) x2 within 250 ms must NEVER trigger or latch!
        edges.removeAll()
        for cycle in 0..<2 {
            clock.nowMS = 2_000.0 + Double(cycle) * 200.0
            try sendFlags(56, [.maskShift])
            clock.nowMS += 10
            try sendFlags(59, [.maskShift, .maskControl])
            clock.nowMS += 10
            try sendFlags(58, [.maskShift, .maskControl, .maskAlternate])
            clock.nowMS += 20
            // Releasing Shift first briefly leaves flags == [.maskControl, .maskAlternate]:
            // `seenModifiersWhileHeld` must block false activation!
            try sendFlags(56, [.maskControl, .maskAlternate])
            clock.nowMS += 10
            try sendFlags(58, [.maskControl])
            clock.nowMS += 10
            try sendFlags(59, [])
        }
        XCTAssertTrue(edges.isEmpty,
                      "Shift+Ctrl+Opt released Shift-first must never trigger dictate or latch: \(edges)")

        // Case B: Two Ctrl+Opt+Arrow chords within 250 ms must NEVER latch hands-free.
        edges.removeAll()
        for cycle in 0..<2 {
            clock.nowMS = 3_000.0 + Double(cycle) * 200.0
            try sendFlags(59, [.maskControl])
            clock.nowMS += 10
            try sendFlags(58, [.maskControl, .maskAlternate])
            clock.nowMS += 20
            try sendKey(124, down: true, flags: [.maskControl, .maskAlternate]) // Right Arrow
            clock.nowMS += 20
            try sendKey(124, down: false, flags: [.maskControl, .maskAlternate])
            clock.nowMS += 10
            try sendFlags(58, [.maskControl])
            clock.nowMS += 10
            try sendFlags(59, [])
        }
        XCTAssertFalse(edges.contains(.latched),
                       "Ctrl+Opt+Arrow x2 within 360 ms must never latch hands-free: \(edges)")

        // Case C: Two clean Ctrl+Opt taps within 250 ms DO latch hands-free!
        edges.removeAll()
        clock.nowMS = 5_000.0
        try sendFlags(59, [.maskControl])
        clock.nowMS += 10
        try sendFlags(58, [.maskControl, .maskAlternate])
        clock.nowMS += 80
        try sendFlags(58, [.maskControl])
        clock.nowMS += 10
        try sendFlags(59, [])

        clock.nowMS += 140
        try sendFlags(59, [.maskControl])
        clock.nowMS += 10
        try sendFlags(58, [.maskControl, .maskAlternate])
        XCTAssertTrue(edges.contains(.latched),
                      "Clean double-tap Ctrl+Opt within 360 ms must latch hands-free: \(edges)")
    }

    func testStandaloneRightCommandAndRightOptionTriggersAndStorePersistence() throws {
        let suiteName = ScratchDefaults.name("trackb-shortcuts")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ShortcutStore(defaults: defaults)
        try store.reset()
        for existing in store.bindings where existing.action == .dictate {
            try store.remove(existing.id)
        }

        let rightCmd = ShortcutBinding(
            action: .dictate,
            keyCode: ShortcutBinding.rightCommandKeyCode, // 0x36
            modifiers: CGEventFlags.maskCommand.rawValue,
            keyLabel: "Right ⌘"
        )
        let rightOpt = ShortcutBinding(
            action: .dictate,
            keyCode: ShortcutBinding.rightOptionKeyCode, // 0x3D
            modifiers: CGEventFlags.maskAlternate.rawValue,
            keyLabel: "Right ⌥"
        )
        let transform = ShortcutBinding(
            shortcutAction: .transformSelection,
            keyCode: 17,
            modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
            keyLabel: "t"
        )
        try store.save(rightCmd)
        try store.save(rightOpt)
        try store.save(transform)

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.label(.dictate), "Right ⌘ or Right ⌥")
        XCTAssertEqual(reloaded.label(.transformSelection), "⇧⌘T")

        var router = ShortcutRouter()
        // Left Command (keyCode 0x37, device flag 0x08) must NOT trigger Right Command (0x36).
        let leftCmdFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        let leftRes = router.event(type: .flagsChanged, key: 0x37, flags: leftCmdFlags,
                                   repeated: false, bindings: reloaded.bindings)
        XCTAssertTrue(leftRes.held.isEmpty)
        _ = router.event(type: .flagsChanged, key: 0x37, flags: [], repeated: false,
                         bindings: reloaded.bindings)

        // Right Command (keyCode 0x36, device flag 0x10) triggers push-to-talk cleanly.
        let rightCmdFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        let downRes = router.event(type: .flagsChanged, key: 0x36, flags: rightCmdFlags,
                                   repeated: false, bindings: reloaded.bindings)
        XCTAssertEqual(downRes.held.count, 1)
        XCTAssertEqual(downRes.held.first?.1, true)

        // Pressing RightCmd+C cancels dictation immediately and marks chord contaminated.
        let cRes = router.event(type: .keyDown, key: 8, flags: rightCmdFlags,
                                repeated: false, bindings: reloaded.bindings)
        XCTAssertEqual(cRes.cancelledSlots.count, 1)
        XCTAssertTrue(cRes.chordContaminated)
    }

    // MARK: - 2. In-Flight AX Timeouts vs Confirmed Secure Input

    func testAXAttributeMetadataReturnsTimedOutWhenDeadlineExpiresOrCannotCompleteHitsTimeout() {
        // Deadline expired after IPC returned: MUST be `.timedOut`, never `.failed`.
        let expiredCannotComplete: AXClient.Metadata<String> = AXClient.attributeMetadata(
            error: .cannotComplete, raw: nil, required: true, hasTimeRemaining: false,
            callElapsed: 0.050, callTimeout: 0.045
        )
        XCTAssertEqual(expiredCannotComplete, .timedOut)

        let expiredSuccess: AXClient.Metadata<String> = AXClient.attributeMetadata(
            error: .success, raw: "AXTextArea", required: true, hasTimeRemaining: false,
            callElapsed: 0.060, callTimeout: 0.045
        )
        XCTAssertEqual(expiredSuccess, .timedOut)

        // Per-call timeout hit while total budget still has time remaining: `.cannotComplete`
        // at >=80% of `callTimeout` is `.timedOut`.
        let perCallTimeout: AXClient.Metadata<String> = AXClient.attributeMetadata(
            error: .cannotComplete, raw: nil, required: true, hasTimeRemaining: true,
            callElapsed: 0.046, callTimeout: 0.050
        )
        XCTAssertEqual(perCallTimeout, .timedOut)

        // Immediate non-timeout `.cannotComplete` (e.g. 2 ms into a 50 ms budget) stays `.failed`.
        let immediateFailure: AXClient.Metadata<String> = AXClient.attributeMetadata(
            error: .cannotComplete, raw: nil, required: true, hasTimeRemaining: true,
            callElapsed: 0.002, callTimeout: 0.050
        )
        XCTAssertEqual(immediateFailure, .failed)
    }

    func testBusyAppTimeoutAndUnknownRoleAreSeparatedFromConfirmedSecureFields() {
        // Transient unreadable role is `.unknown`, NOT `.secure`.
        XCTAssertEqual(
            AXClient.classify(role: .failed, subrole: .absent, protectedContent: .absent),
            .unknown
        )
        XCTAssertEqual(
            AXClient.classify(role: .timedOut, subrole: .absent, protectedContent: .absent),
            .timedOut
        )
        // Explicit secure role / subrole / protectedContent IS `.secure`.
        XCTAssertEqual(
            AXClient.classify(role: .value("AXSecureTextField"), subrole: .absent, protectedContent: .absent),
            .secure
        )
        XCTAssertEqual(
            AXClient.classify(role: .value("AXTextField"),
                              subrole: .value(kAXSecureTextFieldSubrole as String),
                              protectedContent: .absent),
            .secure
        )

        // PasteTarget treats `.timedOut` and `.unknownRole` as `.unresponsive` (allowing retry
        // and clipboard recovery) instead of latching `.secure`.
        let exactAnchor: PasteTarget.FieldAnchor<String> = .exact("editor")
        XCTAssertEqual(
            PasteTarget.identityDecision(anchor: exactAnchor, observation: .timedOut),
            .unresponsive
        )
        XCTAssertEqual(
            PasteTarget.identityDecision(anchor: exactAnchor, observation: .unknownRole),
            .unresponsive
        )
        if case .unresponsive = Paster.decision(for: .appUnresponsive) {
            // Expected: transcript stays recoverable on clipboard rather than dropped as password field.
        } else {
            XCTFail("Expected .unresponsive decision for .appUnresponsive")
        }
        if case .secure = Paster.decision(for: .secureField) {
            // Expected: confirmed secure field still refuses clipboard write.
        } else {
            XCTFail("Expected .secure decision for .secureField")
        }
    }

    // MARK: - 3. Coding Context Past Line ~14, Parameterized Slice & Electron AXManualAccessibility

    func testLocalCodingContextWorksDeepInLargeFileAndSliceTriesParameterizedRangeAtZero() {
        var lines: [String] = []
        for idx in 1...80 {
            lines.append("// ordinary comment on line \(idx) padding offset past 384")
        }
        lines[55] = "func resolveKeyboardLayoutKeyCode(inputSource: TISInputSource) -> CGKeyCode {"
        lines[56] = "    let focusInteractionEpoch = FocusInteractionEpoch.snapshot()"
        lines[57] = "    "
        lines[58] = "    return fallbackVirtualKeyCode"
        lines[59] = "}"
        let document = lines.joined(separator: "\n") as NSString
        let cursorLineRange = document.range(of: "    return fallbackVirtualKeyCode")
        let caretLocation = cursorLineRange.location // Well past UTF-16 offset 384 (~line 58)
        XCTAssertGreaterThan(caretLocation, 1_000)

        let selection = CFRange(location: caretLocation, length: 0)
        let visible = CFRange(location: max(0, caretLocation - 300), length: 600)
        let ranges = AXTextContext.captureRanges(
            selection: selection, total: document.length, visible: visible
        )
        XCTAssertGreaterThan(ranges.before.location, 0)
        XCTAssertGreaterThan(ranges.visible?.location ?? 0, 0)

        let beforeSlice = document.substring(with: NSRange(location: ranges.before.location,
                                                           length: ranges.before.length))
        let afterRange = ranges.after!
        let afterSlice = document.substring(with: NSRange(location: afterRange.location,
                                                          length: afterRange.length))
        let visibleRange = ranges.visible!
        let visibleSlice = document.substring(with: NSRange(location: visibleRange.location,
                                                            length: visibleRange.length))

        let fragments = AXTextContext.vocabularyFragments(
            ranges: ranges,
            fullSelectionLength: 0,
            before: beforeSlice,
            selected: "",
            after: afterSlice,
            visible: visibleSlice
        )
        let terms = ContextVocabulary.extract(
            before: fragments.before,
            selected: fragments.selected,
            after: fragments.after,
            visible: fragments.visible,
            filenames: ["Paster.swift"]
        )
        let canonicals = Set(terms.map(\.canonical))
        XCTAssertTrue(canonicals.contains("focusInteractionEpoch"), "Extracted terms: \(canonicals)")
        XCTAssertTrue(canonicals.contains("resolveKeyboardLayoutKeyCode"), "Extracted terms: \(canonicals)")
        XCTAssertTrue(canonicals.contains("fallbackVirtualKeyCode"), "Extracted terms: \(canonicals)")

        // Verify `slice()` at location == 0 ALWAYS tries parameterized StringForRange first
        // without reading `kAXNumberOfCharactersAttribute` or full-file `kAXValueAttribute`.
        var rangeReadCalls = 0
        let atZero = AXTextContext.slice(
            CFRange(location: 0, length: 24),
            readRange: { requested in
                rangeReadCalls += 1
                XCTAssertEqual(requested.location, 0)
                XCTAssertEqual(requested.length, 24)
                return String(repeating: "x", count: 24)
            },
            readCount: {
                XCTFail("Must not query character count when parameterized range read succeeds")
                return nil
            },
            readValue: {
                XCTFail("Must not read full AXValue on large file when parameterized range read succeeds")
                return nil
            }
        )
        XCTAssertEqual(rangeReadCalls, 1)
        XCTAssertEqual(atZero?.count, 24)
    }

    func testCodingBundleIDsIncludeTerminalsAndAgentToolsAndElectronAccessibilityCachesPerPID() throws {
        let expectedCodingApps = [
            "com.mitchellh.ghostty",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "dev.warp.Warp-Stable",
            "com.github.wez.wezterm",
            "org.alacritty",
            "net.kovidgoyal.kitty",
            "com.cmux.app",
            "com.manaflow.cmux",
            "com.anthropic.claudedesktop",
            "com.openai.chat",
            "com.todesktop.230313mzl4w4u92",
            "com.cursor.Cursor",
            "com.microsoft.VSCode",
            "dev.zed.Zed",
            "com.apple.dt.Xcode",
            "com.openai.codex",
            "com.interface.app",
            "com.t3.code",
            "gg.t3.code"
        ]
        for bundleID in expectedCodingApps {
            XCTAssertTrue(AXTextContext.isCodingApp(bundleID), "Expected coding app: \(bundleID)")
        }

        let suiteName = ScratchDefaults.name("electron-ax")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            AXTextContext.resetElectronAccessibilityCacheForTesting()
        }
        AXTextContext.resetElectronAccessibilityCacheForTesting()

        // Default preference is enabled (`true`).
        XCTAssertTrue(AXTextContext.isElectronAccessibilityEnabled(defaults))

        var setPIDs: [pid_t] = []
        var alive = true
        // First call for Claude Desktop sets AXManualAccessibility.
        XCTAssertTrue(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 42_001,
            bundleID: "com.anthropic.claudedesktop",
            defaults: defaults,
            isProcessAlive: { _ in alive },
            setter: { setPIDs.append($0) }
        ))
        // Second call for the same running PID is cached and does NOT repeat IPC.
        XCTAssertFalse(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 42_001,
            bundleID: "com.anthropic.claudedesktop",
            defaults: defaults,
            isProcessAlive: { _ in alive },
            setter: { setPIDs.append($0) }
        ))
        XCTAssertEqual(setPIDs, [42_001])

        // If the process exited and the PID was later reused by a fresh Electron instance, it sets again.
        alive = false
        XCTAssertTrue(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 42_001,
            bundleID: "com.anthropic.claudedesktop",
            defaults: defaults,
            isProcessAlive: { _ in alive },
            setter: { setPIDs.append($0) }
        ))
        XCTAssertEqual(setPIDs, [42_001, 42_001])
        alive = true

        // Native non-Electron terminal (Terminal.app) does not set AXManualAccessibility.
        XCTAssertFalse(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 42_002,
            bundleID: "com.apple.Terminal",
            defaults: defaults,
            isProcessAlive: { _ in true },
            setter: { setPIDs.append($0) }
        ))
        XCTAssertEqual(setPIDs, [42_001, 42_001])

        // User opt-out (`electronAccessibilityEnabled = false`) disables setting AXManualAccessibility.
        defaults.set(false, forKey: AXTextContext.electronAccessibilityKey)
        XCTAssertFalse(AXTextContext.enableElectronAccessibilityIfNeeded(
            pid: 42_003,
            bundleID: "com.openai.chat",
            defaults: defaults,
            isProcessAlive: { _ in true },
            setter: { setPIDs.append($0) }
        ))
        XCTAssertEqual(setPIDs, [42_001, 42_001])
    }

    // MARK: - 4. Clipboard Preservation in `.clipboardConsumed`, Fast Paste & Non-QWERTY `Cmd+V`

    func testDelayedClipboardRestoreRestoresPreDictationClipboardAndAbortsOnNewUserCopy() throws {
        AXClient.setSecureInputProviderForTesting { false }
        defer { AXClient.setSecureInputProviderForTesting(nil) }

        // 1. Untouched pasteboard after `.clipboardConsumed`: original clipboard is restored!
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.andre.flowclone.test-rich")
        let seedItem = NSPasteboardItem()
        XCTAssertTrue(seedItem.setString("User's original copied snippet", forType: .string))
        XCTAssertTrue(seedItem.setData(Data([0xCA, 0xFE]), forType: customType))
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([seedItem]))
        let saved = try XCTUnwrap(Paster.preservableClipboard(pb, expectedChangeCount: pb.changeCount))

        // Simulate internal transport write for `.clipboardConsumed`.
        let nonce = Data(UUID().uuidString.utf8)
        let transport = NSPasteboardItem()
        XCTAssertTrue(transport.setString("Dictated transcript", forType: .string))
        XCTAssertTrue(transport.setData(nonce, forType: Paster.marker))
        XCTAssertTrue(Paster.markOptOut(transport))
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([transport]))
        let transportGen = pb.changeCount

        let restoredExp = expectation(description: "delayed clipboard restore")
        Paster.scheduleDelayedClipboardRestore(
            saved, on: pb, nonce: nonce, changeCount: transportGen, delay: 0.05
        ) { restored in
            XCTAssertTrue(restored)
            restoredExp.fulfill()
        }
        wait(for: [restoredExp], timeout: 1.0)
        XCTAssertEqual(pb.string(forType: .string), "User's original copied snippet")
        XCTAssertEqual(pb.data(forType: customType), Data([0xCA, 0xFE]))

        // 2. If the user copies something else before the 350 ms timer fires, their new copy wins!
        let pb2 = NSPasteboard.withUniqueName()
        defer { pb2.releaseGlobally() }
        pb2.clearContents()
        XCTAssertTrue(pb2.setString("Old clipboard", forType: .string))
        let saved2 = try XCTUnwrap(Paster.preservableClipboard(pb2, expectedChangeCount: pb2.changeCount))

        let nonce2 = Data(UUID().uuidString.utf8)
        let transport2 = NSPasteboardItem()
        XCTAssertTrue(transport2.setString("Dictated transcript", forType: .string))
        XCTAssertTrue(transport2.setData(nonce2, forType: Paster.marker))
        pb2.clearContents()
        XCTAssertTrue(pb2.writeObjects([transport2]))
        let transportGen2 = pb2.changeCount

        // User copies new content while timer is in flight (`changeCount` advances).
        pb2.clearContents()
        XCTAssertTrue(pb2.setString("Fresh user copy after dictation", forType: .string))

        let abortedExp = expectation(description: "delayed restore aborts on changeCount mismatch")
        Paster.scheduleDelayedClipboardRestore(
            saved2, on: pb2, nonce: nonce2, changeCount: transportGen2, delay: 0.04
        ) { restored in
            XCTAssertFalse(restored)
            abortedExp.fulfill()
        }
        wait(for: [abortedExp], timeout: 1.0)
        XCTAssertEqual(pb2.string(forType: .string), "Fresh user copy after dictation")
    }

    func testWaitForPasteEffectRecognizesValueChangeImmediatelyWithoutSleeping300ms() {
        var polls = 0
        var sleeps = 0
        var clock = 100.0
        let confirmation = Paster.waitForPasteEffect(
            hasSelectedRange: false,
            beforeValue: "initial prompt ",
            pollConfirmation: {
                polls += 1
                return PasteTarget.PasteProbe.detectValueChange(
                    beforeValue: "initial prompt ",
                    currentValue: "initial prompt hello world",
                    expectedText: "hello world"
                )
            },
            deadline: { 100.30 },
            now: { clock },
            sleep: { dt in
                sleeps += 1
                clock += dt
            }
        )
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(sleeps, 0, "Value change must complete immediately without sleeping")
        XCTAssertEqual(
            confirmation,
            .confirmed(PasteTarget.ConfirmedInsertion(location: 15, length: 11))
        )

        // Even when the app reformatted/mutated the value (`.valueChanged`), `selectedRange == nil`
        // with `beforeValue != nil` breaks out on the first poll where `currentValue != beforeValue`.
        var nonExactPolls = 0
        var nonExactSleeps = 0
        let valueChanged = Paster.waitForPasteEffect(
            hasSelectedRange: false,
            beforeValue: "prompt",
            pollConfirmation: {
                nonExactPolls += 1
                return nonExactPolls == 1 ? .unavailable : .valueChanged
            },
            deadline: { 200.30 },
            now: { 200.0 },
            sleep: { _ in nonExactSleeps += 1 }
        )
        XCTAssertEqual(valueChanged, .valueChanged)
        XCTAssertEqual(nonExactPolls, 2)
        XCTAssertEqual(nonExactSleeps, 1)
    }

    func testUCKeyTranslateResolvesVAndCAcrossQWERTYAndDvorakLayouts() throws {
        func findLayout(_ id: String) -> TISInputSource? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
                return nil
            }
            return list.first
        }

        if let us = findLayout("com.apple.keylayout.US") ?? findLayout("com.apple.keylayout.ABC") {
            XCTAssertEqual(Paster.virtualKeyCode(for: "v", inputSource: us, fallback: 99),
                           CGKeyCode(kVK_ANSI_V))
            XCTAssertEqual(Paster.virtualKeyCode(for: "c", inputSource: us, fallback: 99),
                           CGKeyCode(kVK_ANSI_C))
        }

        if let dvorak = findLayout("com.apple.keylayout.Dvorak") {
            let dvorakV = Paster.virtualKeyCode(for: "v", inputSource: dvorak, fallback: 99)
            let dvorakC = Paster.virtualKeyCode(for: "c", inputSource: dvorak, fallback: 99)
            // On Dvorak, ANSI 0x09 ('v' on QWERTY) is '.' (`Cmd+.`!), whereas real 'v' is 0x2F (47)
            // and real 'c' is 0x08 -> 'j' while 'c' is 0x22 (34, ANSI 'i').
            XCTAssertNotEqual(dvorakV, CGKeyCode(kVK_ANSI_V),
                              "Dvorak 'v' must not map to QWERTY keycode 9 (which sends Cmd+.)")
            XCTAssertEqual(dvorakV, CGKeyCode(kVK_ANSI_Period))
            XCTAssertEqual(dvorakC, CGKeyCode(kVK_ANSI_I))
        }

        // Empty layout data safely falls back to ANSI defaults.
        XCTAssertEqual(Paster.virtualKeyCode(for: "v", layoutData: Data(),
                                             fallback: CGKeyCode(kVK_ANSI_V)),
                       CGKeyCode(kVK_ANSI_V))
        XCTAssertEqual(Paster.virtualKeyCode(for: "c", layoutData: Data(),
                                             fallback: CGKeyCode(kVK_ANSI_C)),
                       CGKeyCode(kVK_ANSI_C))
    }

    // MARK: - 5. Selection Transforms Simulated `Cmd+C` Fallback & Active Preset Auto-Run

    func testSimulatedCopyCapturePreservesAndRestoresPriorClipboardAcrossAllOutcomes() throws {
        AXClient.setSecureInputProviderForTesting { false }
        defer { AXClient.setSecureInputProviderForTesting(nil) }

        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let richType = NSPasteboard.PasteboardType("public.rtf")

        func seedPriorClipboard() {
            let prior = NSPasteboardItem()
            XCTAssertTrue(prior.setString("Prior user clipboard", forType: .string))
            XCTAssertTrue(prior.setData(Data("{\\rtf1 prior}".utf8), forType: richType))
            pb.clearContents()
            XCTAssertTrue(pb.writeObjects([prior]))
        }

        // 1. Successful selection capture in Electron/web view restores prior clipboard immediately.
        seedPriorClipboard()
        let captured = Paster.captureSelectionFromPasteboard(
            pb,
            triggerCopy: {
                pb.clearContents()
                _ = pb.setString("Selected Electron paragraph", forType: .string)
            },
            waitTimeout: 0.05,
            pollInterval: 0.005
        )
        XCTAssertEqual(captured, .captured("Selected Electron paragraph"))
        XCTAssertEqual(pb.string(forType: .string), "Prior user clipboard")
        XCTAssertEqual(pb.data(forType: richType), Data("{\\rtf1 prior}".utf8))

        // 2. Empty/no selection restores prior clipboard and returns `.noSelection`.
        seedPriorClipboard()
        let noSel = Paster.captureSelectionFromPasteboard(
            pb,
            triggerCopy: { /* app did not write to pasteboard */ },
            waitTimeout: 0.02,
            pollInterval: 0.005
        )
        XCTAssertEqual(noSel, .noSelection)
        XCTAssertEqual(pb.string(forType: .string), "Prior user clipboard")
        XCTAssertEqual(pb.data(forType: richType), Data("{\\rtf1 prior}".utf8))

        // 3. Oversized selection restores prior clipboard and returns `.tooLong`.
        seedPriorClipboard()
        let oversized = Paster.captureSelectionFromPasteboard(
            pb,
            maxLength: 20,
            triggerCopy: {
                pb.clearContents()
                _ = pb.setString(String(repeating: "x", count: 25), forType: .string)
            },
            waitTimeout: 0.05,
            pollInterval: 0.005
        )
        XCTAssertEqual(oversized, .tooLong)
        XCTAssertEqual(pb.string(forType: .string), "Prior user clipboard")

        // 4. Foreign concealed item (e.g. 1Password password) on clipboard before Cmd+C is NEVER clobbered.
        let secretItem = NSPasteboardItem()
        XCTAssertTrue(secretItem.setString("top-secret-password", forType: .string))
        XCTAssertTrue(secretItem.setData(Data([1]),
                                         forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([secretItem]))
        let secretGen = pb.changeCount
        let refusedProtected = Paster.captureSelectionFromPasteboard(
            pb,
            triggerCopy: { XCTFail("Must not trigger Cmd+C when prior clipboard is concealed") },
            waitTimeout: 0.02,
            pollInterval: 0.005
        )
        XCTAssertEqual(refusedProtected, .unavailable)
        XCTAssertEqual(pb.changeCount, secretGen)
        XCTAssertEqual(pb.string(forType: .string), "top-secret-password")
    }

    @MainActor
    func testActivePresetAutoRunConfigurationAndPasteFallbackTarget() throws {
        let suiteName = ScratchDefaults.name("transform-autorun")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = TransformController()

        // Default with no custom presets auto-runs `.polish`.
        XCTAssertTrue(controller.configureActivePresetOnOpen(spoken: false, defaults: defaults))
        XCTAssertEqual(controller.activeSelectionKindForTesting, .polish)

        // Setting an active custom preset selects `.custom`, populates its instruction, and auto-runs.
        let concise = TransformPreset(name: "Concise email", instruction: "Rewrite as a concise email.")
        TransformPresets.saveNamed([concise], defaults)
        TransformPresets.setActivePresetID(concise.id, defaults)

        XCTAssertTrue(controller.configureActivePresetOnOpen(spoken: false, defaults: defaults))
        XCTAssertEqual(controller.activeSelectionKindForTesting, .custom)
        XCTAssertEqual(controller.customInstructionForTesting, "Rewrite as a concise email.")

        // Spoken mode defers execution until speech completes.
        XCTAssertFalse(controller.configureActivePresetOnOpen(spoken: true, defaults: defaults))

        // Paste-fallback target preserves original text and flags `usesPasteFallback`.
        let fallbackTarget = SelectedTextTarget(
            pasteFallbackApp: "com.anthropic.claudedesktop",
            pid: 999,
            original: "Draft paragraph"
        )
        XCTAssertTrue(fallbackTarget.usesPasteFallback)
        XCTAssertEqual(fallbackTarget.original, "Draft paragraph")
        XCTAssertEqual(fallbackTarget.bundleID, "com.anthropic.claudedesktop")
    }

    // MARK: - 6. Rex / Terminal 2D Grid AX Bypass, Mutation Confirmation & Post-Read Polling Cap

    func testRexAndTerminalGridAppsBypass2DGridAXWhileKeepingCodingAndSlashCommandSupport() {
        let terminalBundles = [
            "com.superlogical.rex",
            "com.superlogical.rex.beta",
            "com.mitchellh.ghostty",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "dev.warp.Warp-Stable",
            "dev.warp.Warp-Preview",
            "dev.warp.Warp-Nightly",
            "com.github.wez.wezterm",
            "org.alacritty",
            "io.alacritty",
            "net.kovidgoyal.kitty",
            "com.cmux.app",
            "dev.cmux.app",
            "com.manaflow.cmux",
            "com.cmux.nightly",
            "dev.cmux.preview",
        ]
        for bundleID in terminalBundles {
            XCTAssertTrue(AXTextContext.usesTerminalGridAX(bundleID),
                          "Expected terminal grid AX bypass for \(bundleID)")
            XCTAssertTrue(AXTextContext.isCodingApp(bundleID),
                          "Expected coding app support for \(bundleID)")
            let probe = PasteTarget.PasteProbe(
                bundleID: bundleID,
                selectionBefore: CFRange(location: 0, length: 0),
                beforeValue: "╭────────────╮"
            )
            XCTAssertFalse(probe.canObserveViaGridSafeAX, bundleID)
            XCTAssertFalse(probe.canObservePasteEffectViaAX,
                           "\(bundleID) must skip 2D terminal grid AX paste polling")
            XCTAssertEqual(probe.confirmation(of: "hello world"), .unavailable, bundleID)
        }

        // Rex gets full coding/agent profile support (slash commands & spoken code formatting).
        XCTAssertTrue(AppProfiles.isCodingApp("com.superlogical.rex"))
        XCTAssertTrue(AppProfiles.isCodingOrAgentApp("com.superlogical.rex"))
        XCTAssertEqual(SlashCommands.apply("Slash compact.", bundleID: "com.superlogical.rex"),
                       "/compact")
        XCTAssertEqual(SpokenCodeFormat.apply("camel case get user id",
                                              bundleID: "com.superlogical.rex"),
                       "getUserId")

        // Non-terminal editors and apps keep grid-safe AX observation enabled.
        let standardEditorBundles = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.anthropic.claudedesktop",
            "com.apple.Notes",
            "com.apple.TextEdit",
        ]
        for bundleID in standardEditorBundles {
            XCTAssertFalse(AXTextContext.usesTerminalGridAX(bundleID), bundleID)
            let probe = PasteTarget.PasteProbe(
                bundleID: bundleID,
                selectionBefore: CFRange(location: 4, length: 0)
            )
            XCTAssertTrue(probe.canObserveViaGridSafeAX, bundleID)
            XCTAssertTrue(probe.canObservePasteEffectViaAX, bundleID)
        }
    }

    func testPasteProbeRangeMutationDetectionAndMismatchClassification() {
        let startRange = CFRange(location: 10, length: 0)

        // 1. Exact text + exact caret transition remains `.confirmed` (enabling AutoLearn).
        XCTAssertEqual(
            PasteTarget.PasteProbe.evaluateRangeConfirmation(
                selectionBefore: startRange,
                selectionAfter: CFRange(location: 15, length: 0),
                observedAtTarget: "hello",
                expectedText: "hello",
                beforeCount: 10,
                currentCount: 15,
                beforeSlice: "",
                currentSlice: "hello",
                replacedText: ""
            ),
            .confirmed(PasteTarget.ConfirmedInsertion(location: 10, length: 5, replacedText: ""))
        )

        // 2. Smart-paste leading space (" hello", caret moved to 16) reports `.valueChanged`.
        XCTAssertEqual(
            PasteTarget.PasteProbe.evaluateRangeConfirmation(
                selectionBefore: startRange,
                selectionAfter: CFRange(location: 16, length: 0),
                observedAtTarget: " hell",
                expectedText: "hello",
                beforeCount: 10,
                currentCount: 16,
                beforeSlice: "",
                currentSlice: " hello"
            ),
            .valueChanged
        )

        // 3. Smart typography ("don't" -> "don’t") or shortened smart ellipsis ("Wait..." -> "Wait…")
        //    with count/slice mutation reports `.valueChanged` even if target range read nil/mismatched.
        XCTAssertEqual(
            PasteTarget.PasteProbe.evaluateRangeConfirmation(
                selectionBefore: startRange,
                selectionAfter: nil,
                observedAtTarget: nil,
                expectedText: "Wait...",
                beforeCount: 10,
                currentCount: 15,
                beforeSlice: "",
                currentSlice: "Wait…"
            ),
            .valueChanged
        )

        // 4. Static caret `(0, 0)` where text at `(0, 5)` changed from `""` to `"hello"` reports `.valueChanged`.
        XCTAssertEqual(
            PasteTarget.PasteProbe.evaluateRangeConfirmation(
                selectionBefore: CFRange(location: 0, length: 0),
                selectionAfter: CFRange(location: 0, length: 0),
                observedAtTarget: "hello",
                expectedText: "hello",
                beforeCount: nil,
                currentCount: nil,
                beforeSlice: "",
                currentSlice: "hello"
            ),
            .valueChanged
        )

        // 5. Unchanged pre-existing identical text at `(0, 5)` with no caret/count/slice change stays `.mismatch`.
        XCTAssertEqual(
            PasteTarget.PasteProbe.evaluateRangeConfirmation(
                selectionBefore: CFRange(location: 0, length: 0),
                selectionAfter: CFRange(location: 0, length: 0),
                observedAtTarget: "hello",
                expectedText: "hello",
                beforeCount: 11,
                currentCount: 11,
                beforeSlice: "hello world",
                currentSlice: "hello world"
            ),
            .mismatch
        )

        // 6. `Paster.classify`: `.mismatch` with `readObserved == true` acknowledges as `.clipboardConsumed`
        //    (no false warning, delayed 350 ms clipboard restore runs, AutoLearn stays off), while
        //    `readObserved == false` remains `nil` (`.ambiguous`).
        XCTAssertNil(Paster.classify(confirmation: .mismatch, readObserved: false))
        XCTAssertEqual(Paster.classify(confirmation: .mismatch, readObserved: true), .clipboardConsumed)
        XCTAssertNil(Paster.classify(confirmation: .unavailable, readObserved: false))
        XCTAssertEqual(Paster.classify(confirmation: .unavailable, readObserved: true), .clipboardConsumed)

        let selfCheckResult = Paster.selfCheck()
        XCTAssertGreaterThan(selfCheckResult.checks, 0)
        XCTAssertEqual(selfCheckResult.failed, 0, "Paster.selfCheck() must pass with 0 failures")
    }

    func testWaitForPasteEffectExitsOnSelectedRangeValueChangedAndCapsPostReadPollingAt60ms() {
        // 1. `.valueChanged` exits immediately even when `hasSelectedRange == true` and `beforeValue == nil`.
        var rangePolls = 0
        var rangeSleeps = 0
        let rangeChanged = Paster.waitForPasteEffect(
            hasSelectedRange: true,
            beforeValue: nil,
            pollConfirmation: {
                rangePolls += 1
                return .valueChanged
            },
            deadline: { 500.30 },
            now: { 500.00 },
            sleep: { _ in rangeSleeps += 1 }
        )
        XCTAssertEqual(rangeChanged, .valueChanged)
        XCTAssertEqual(rangePolls, 1)
        XCTAssertEqual(rangeSleeps, 0)

        // 2. Once `readObserved()` becomes `true`, static/mismatched AX polling is capped at <= 60 ms
        //    instead of stalling for the full 300 ms window.
        var clock = 1_000.000
        var readSeenAt: TimeInterval?
        let mismatchResult = Paster.waitForPasteEffect(
            hasSelectedRange: true,
            beforeValue: nil,
            pollConfirmation: { .mismatch },
            deadline: { 1_000.300 },
            readObserved: {
                if clock >= 1_000.015 {
                    if readSeenAt == nil { readSeenAt = clock }
                    return true
                }
                return false
            },
            now: { clock },
            sleep: { dt in clock += dt }
        )
        XCTAssertEqual(mismatchResult, .mismatch)
        let seenAt = readSeenAt ?? 1_000.015
        let postReadElapsed = clock - seenAt
        XCTAssertLessThanOrEqual(postReadElapsed, 0.061,
                                 "AX polling after readObserved must stop within ~60 ms, got \(postReadElapsed)s")
        XCTAssertLessThan(clock - 1_000.000, 0.100,
                          "Total wait must be far below the 300 ms deadline")

        // 3. If AX updates to `.confirmed` inside the 60 ms post-read grace window, `.confirmed` still wins!
        var graceClock = 2_000.000
        let expectedInsertion = PasteTarget.ConfirmedInsertion(location: 0, length: 5)
        let confirmedInsideGrace = Paster.waitForPasteEffect(
            hasSelectedRange: true,
            beforeValue: nil,
            pollConfirmation: {
                graceClock >= 2_000.030 ? .confirmed(expectedInsertion) : .unavailable
            },
            deadline: { 2_000.300 },
            readObserved: { true },
            now: { graceClock },
            sleep: { dt in graceClock += dt }
        )
        XCTAssertEqual(confirmedInsideGrace, .confirmed(expectedInsertion))
        XCTAssertEqual(graceClock, 2_000.030, accuracy: 0.0001)
    }
}
