// Explicit selected-text transform transaction: capture → preview → accept → optional undo.
// The target is never changed by a model callback. Accept and Undo both revalidate the
// original PID, AX element, UTF-16 range, and exact text immediately before writing.
import Cocoa
import Foundation

@MainActor
private final class TransformPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct SelectedTextTarget: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let range: CFRange
    let original: String
    let usesPasteFallback: Bool
    let fallbackElement: AXUIElement?

    init(element: AXUIElement, pid: pid_t, bundleID: String, range: CFRange, original: String) {
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.range = range
        self.original = original
        self.usesPasteFallback = false
        self.fallbackElement = element
    }

    init(pasteFallback target: PasteTarget, fallbackElement: AXUIElement? = nil, original: String) {
        self.init(pasteFallbackApp: target.app.bundleID, pid: target.app.pid,
                  fallbackElement: fallbackElement, original: original)
    }

    init(pasteFallbackApp bundleID: String, pid: pid_t,
         fallbackElement: AXUIElement? = nil, original: String) {
        self.element = fallbackElement ?? AXUIElementCreateApplication(pid)
        self.pid = pid
        self.bundleID = bundleID
        self.range = CFRange(location: 0, length: 0)
        self.original = original
        self.usesPasteFallback = true
        self.fallbackElement = fallbackElement
    }

    enum CaptureError: Error {
        case noApplication, noElement, secure, noSelection, tooLong
    }

    enum ReplaceResult {
        case verified(CFRange)
        case failed(String)
        case ambiguous(String)
    }

    static func capture() throws -> SelectedTextTarget {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { throw CaptureError.noApplication }
        let pid = app.processIdentifier
        AXTextContext.enableElectronAccessibilityIfNeeded(pid: pid, bundleID: bundleID)
        let element: AXUIElement
        switch AXClient.focusedElement(
            pid: pid, deadline: AXClient.Deadline(total: 0.20, perCall: 0.05)) {
        case .element(let focused): element = focused
        case .secure: throw CaptureError.secure
        // An app that never answered is not a target we can transform via AX alone.
        case .unavailable, .unknownRole, .foreign, .timedOut: throw CaptureError.noElement
        }
        guard let selected = stringAttribute(element, kAXSelectedTextAttribute),
              !selected.isEmpty else {
            throw CaptureError.noSelection
        }
        guard SelectionTransformer.eligible(selected) else { throw CaptureError.tooLong }
        if let range = selectedRange(element), range.length > 0,
           AXClient.isAttributeSettable(element, kAXSelectedTextAttribute as CFString,
                                        deadline: AXClient.Deadline(total: 0.20, perCall: 0.05)) {
            return SelectedTextTarget(element: element, pid: pid, bundleID: bundleID,
                                      range: range, original: selected)
        }
        return SelectedTextTarget(pasteFallbackApp: bundleID, pid: pid,
                                  fallbackElement: element, original: selected)
    }

    func canStartPreview(ourPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        if !usesPasteFallback {
            return revalidateSelection(expected: original, range: range)
        }
        guard !AXClient.isSecureInputEnabled() else { return false }
        let front = PasteTarget.AppIdentity.frontmost()
        let expectedApp = PasteTarget.AppIdentity(bundleID: bundleID, pid: pid)
        guard front == expectedApp || front?.pid == ourPID else { return false }
        if front == expectedApp, let fallbackElement {
            switch AXClient.focusedElement(
                pid: pid, deadline: AXClient.Deadline(total: 0.12, perCall: 0.04)) {
            case .secure, .foreign:
                return false
            case .element(let current):
                return CFEqual(current, fallbackElement)
            case .unavailable, .unknownRole, .timedOut:
                return true
            }
        }
        return true
    }

    func replace(expected: String, at expectedRange: CFRange, with replacement: String)
        -> ReplaceResult {
        let io = SelectionMutationIO(
            selectionMatches: { self.revalidateSelection(expected: $0, range: $1)
                && self.string(in: $1) == $0 },
            selectedTextSettable: {
                AXClient.isAttributeSettable(
                    self.element, kAXSelectedTextAttribute as CFString,
                    deadline: AXClient.Deadline(total: 0.20, perCall: 0.05))
            },
            writeSelectedText: {
                AXClient.setAttribute(
                    self.element, kAXSelectedTextAttribute as CFString,
                    value: $0 as CFTypeRef,
                    deadline: AXClient.Deadline(total: 0.20, perCall: 0.05))
            },
            stringInRange: { self.string(in: $0) },
            selectedRange: { Self.selectedRange(self.element) },
            selectedText: { Self.stringAttribute(self.element, kAXSelectedTextAttribute) }
        )
        return SelectionMutation.replace(expected: expected, at: expectedRange,
                                         with: replacement, io: io)
    }

    func revalidateSelection(expected: String, range expectedRange: CFRange) -> Bool {
        guard revalidateElement(),
              let currentRange = Self.selectedRange(element),
              currentRange.location == expectedRange.location,
              currentRange.length == expectedRange.length,
              let selected = Self.stringAttribute(element, kAXSelectedTextAttribute),
              selected == expected,
              // selectedRange and selectedText are separate cross-process reads. Close the
              // sandwich so an app/focus/security change during either read fails closed.
              revalidateElement() else { return false }
        return true
    }

    func revalidateElement() -> Bool {
        let before = PasteTarget.AppIdentity.frontmost()
        guard before == PasteTarget.AppIdentity(bundleID: bundleID, pid: pid) else { return false }
        let firstElement: AXUIElement?
        let secure: Bool
        switch AXClient.focusedElement(
            pid: pid, deadline: AXClient.Deadline(total: 0.20, perCall: 0.05)) {
        case .element(let focused):
            firstElement = focused
            secure = false
        case .secure:
            firstElement = nil
            secure = true
        case .unavailable, .unknownRole, .foreign, .timedOut:
            firstElement = nil
            secure = false
        }
        guard let firstElement, CFEqual(firstElement, element) else { return false }
        // isSecure performs bounded AX role/subrole/protected-content reads. Re-read focus
        // afterward, then sample the frontmost app last, so a transition during those reads
        // cannot leave a stale true result.
        let finalElement: AXUIElement?
        switch AXClient.focusedElement(
            pid: pid, deadline: AXClient.Deadline(total: 0.20, perCall: 0.05)) {
        case .element(let focused): finalElement = focused
        case .secure, .unavailable, .unknownRole, .foreign, .timedOut: finalElement = nil
        }
        return Self.stableTarget(
            expectedElement: element, expectedPID: pid, expectedBundleID: bundleID,
            before: before, firstElement: firstElement, secure: secure,
            finalElement: finalElement, after: PasteTarget.AppIdentity.frontmost())
    }

    fileprivate static func stableTarget(
        expectedElement: AXUIElement, expectedPID: pid_t, expectedBundleID: String,
        before: PasteTarget.AppIdentity?, firstElement: AXUIElement?, secure: Bool,
        finalElement: AXUIElement?, after: PasteTarget.AppIdentity?
    ) -> Bool {
        let expectedApp = PasteTarget.AppIdentity(bundleID: expectedBundleID, pid: expectedPID)
        guard before == expectedApp, after == expectedApp, !secure,
              let firstElement, let finalElement else { return false }
        return CFEqual(firstElement, expectedElement) && CFEqual(finalElement, expectedElement)
    }

    func select(_ wanted: CFRange) -> Bool {
        guard revalidateElement() else { return false }
        var copy = wanted
        guard let value = AXValueCreate(.cfRange, &copy) else { return false }
        return AXClient.setAttribute(
            element, kAXSelectedTextRangeAttribute as CFString, value: value,
            deadline: AXClient.Deadline(total: 0.20, perCall: 0.05))
    }

    func string(in wanted: CFRange) -> String? {
        var copy = wanted
        guard let value = AXValueCreate(.cfRange, &copy) else { return nil }
        return AXClient.parameterizedAttribute(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            parameter: value,
            deadline: AXClient.Deadline(total: 0.20, perCall: 0.05))
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        AXClient.selectedRange(element, deadline: AXClient.Deadline(total: 0.20, perCall: 0.05))
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        AXClient.stringAttribute(element, name as CFString,
                                 deadline: AXClient.Deadline(total: 0.20, perCall: 0.05))
    }
}

/// The selection write algorithm is separated from Accessibility transport so every
/// fail-closed branch can be tested without granting a test process control of another app.
private struct SelectionMutationIO {
    let selectionMatches: (String, CFRange) -> Bool
    let selectedTextSettable: () -> Bool
    let writeSelectedText: (String) -> Bool
    let stringInRange: (CFRange) -> String?
    let selectedRange: () -> CFRange?
    let selectedText: () -> String?
}

private enum SelectionMutation {
    static func replace(expected: String, at expectedRange: CFRange, with replacement: String,
                        io: SelectionMutationIO) -> SelectedTextTarget.ReplaceResult {
        // An unchanged model result is not a transaction. Besides avoiding a meaningless
        // write, this keeps verification informative: if the selection moved during AX IPC,
        // the unchanged original range must never be mistaken for proof of a write elsewhere.
        guard replacement != expected else { return .failed("the preview is unchanged") }
        guard io.selectionMatches(expected, expectedRange) else {
            return .failed("the target or selected text changed")
        }
        guard io.selectedTextSettable() else { return .failed("the selected text is read-only") }
        // The settable query is cross-process IPC and can give the target time to move its
        // selection. Re-pin the exact app, element, range, and text immediately before the
        // selected-text write so that query cannot open a wrong-selection mutation window.
        guard io.selectionMatches(expected, expectedRange) else {
            return .failed("the target or selected text changed before replacement")
        }
        let inserted = CFRange(location: expectedRange.location, length: replacement.utf16.count)
        let writeReportedSuccess = io.writeSelectedText(replacement)

        // AX is cross-process IPC. A timeout or `.cannotComplete` can arrive after the
        // target applied the write, so a false return is not proof that nothing changed.
        // First prove the original selection is still byte-for-byte intact; otherwise the
        // same exact readback used for an ordinary success decides the outcome.
        if !writeReportedSuccess,
           io.selectionMatches(expected, expectedRange),
           io.stringInRange(expectedRange) == expected {
            return .failed("the target rejected the replacement; the original is unchanged")
        }
        if let observed = io.stringInRange(inserted) {
            guard observed == replacement else {
                // Never select or overwrite a predicted range after a partial/normalized
                // target write. That range can include adjacent user text.
                return .ambiguous("the target returned different text after replacement")
            }
            if replacement.isEmpty {
                // An empty range reads as empty even when a target ignores deletion.
                guard let caret = io.selectedRange(), caret.location == inserted.location,
                      caret.length == 0 else { return .ambiguous("deletion was not confirmed") }
            }
            return .verified(inserted)
        }

        // If range readback is unavailable, rollback is safe only when the target itself
        // still reports the exact replacement selected at the exact inserted range. Write
        // directly through that verified selection; never create a predicted selection.
        if let currentRange = io.selectedRange(),
           currentRange.location == inserted.location,
           currentRange.length == inserted.length,
           io.selectedText() == replacement,
           io.writeSelectedText(expected),
           io.stringInRange(expectedRange) == expected {
            return .failed("replacement readback was unavailable; the original was restored")
        }
        let report = writeReportedSuccess ? "replacement" : "reported-failed replacement"
        return .ambiguous("\(report) could not be verified and no safe rollback was possible")
    }
}

@MainActor
final class TransformController: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    static let shared = TransformController()

    private enum UndoFinish {
        case success
        case retryable
        case stale
        case ambiguous
    }

    private struct UndoRecord {
        let target: SelectedTextTarget
        let original: String
        let replacement: String
        let range: CFRange
    }

    private var target: SelectedTextTarget?
    private var preview: String?
    private var undoRecord: UndoRecord?
    private var generation = 0
    private var running = false

    private var window: NSPanel?
    private let recipe = NSPopUpButton(frame: .zero, pullsDown: false)
    private let custom = NSTextField(string: "")
    private var customRow: NSStackView?
    private var savedPresets: [TransformPreset] = []
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(labelWithString: "")
    private let originalView = NSTextView()
    private let resultView = NSTextView()
    private let generateButton = NSButton(title: "Generate Preview", target: nil, action: nil)
    private let acceptButton = NSButton(title: "Apply replacement", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let speakButton = NSButton(title: "Speak instruction", target: nil, action: nil)

    private(set) var undoAvailable = false
    var blocksUpdate: Bool { running || window?.isVisible == true }

    func begin(spoken: Bool = false, lease: Paster.TargetLease? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running, !Updater.isInstalling else {
            notifyUser("A Transform preview is still being generated.")
            return
        }
        running = true
        generation += 1
        let g = generation
        let bound = lease ?? Paster.beginTargetCaptureAtMenuBoundary()
        @Sendable func finish(_ captured: Result<SelectedTextTarget, Error>) {
            DispatchQueue.main.async {
                // `running` belongs to this attempt whether or not it is still the current
                // one; leaving it set behind a superseded generation stranded the window.
                self.running = false
                guard g == self.generation else { return }
                switch captured {
                case .success(let target):
                    self.target = target
                    self.preview = nil
                    self.buildIfNeeded()
                    self.reloadPresets()
                    let shouldAutoRun = self.configureActivePresetOnOpen(spoken: spoken)
                    self.originalView.textStorage?.setAttributedString(
                        self.styled(target.original, changed: nil, color: .systemRed))
                    self.resultView.string = ""
                    self.status.stringValue = ""
                    self.updateButtons()
                    SelectionTransformer.prepare(self.selectedKind)
                    self.window?.orderFrontRegardless()
                    if spoken {
                        self.speakInstruction()
                    } else if shouldAutoRun {
                        self.generate()
                    }
                case .failure(SelectedTextTarget.CaptureError.tooLong):
                    notifyUser("Selection is too long (3,000-character limit).")
                case .failure(SelectedTextTarget.CaptureError.secure):
                    notifyUser("Transforms are disabled in secure text fields.")
                case .failure:
                    notifyUser("Select some editable text, then choose Transform selected text again.")
                }
            }
        }
        Paster.resolveTargetCapture(bound) { result in
            guard case .captured(let pasteTarget) = result else {
                finish(.failure(SelectedTextTarget.CaptureError.noSelection))
                return
            }
            switch pasteTarget.lookupSelectedTextTarget() {
            case .captured(let selected):
                finish(.success(selected))
            case .tooLong:
                finish(.failure(SelectedTextTarget.CaptureError.tooLong))
            case .secure:
                finish(.failure(SelectedTextTarget.CaptureError.secure))
            case .emptyConfirmedSelection:
                finish(.failure(SelectedTextTarget.CaptureError.noSelection))
            case .needsCopyFallback(let fallbackElement):
                nonisolated(unsafe) let transferredElement = fallbackElement
                Paster.captureSelectionViaCopy(
                    for: pasteTarget, acceptedEpoch: bound.acceptedEpoch
                ) { copyResult in
                    switch copyResult {
                    case .captured(let copied):
                        finish(.success(SelectedTextTarget(
                            pasteFallback: pasteTarget,
                            fallbackElement: transferredElement,
                            original: copied)))
                    case .tooLong:
                        finish(.failure(SelectedTextTarget.CaptureError.tooLong))
                    case .secure:
                        finish(.failure(SelectedTextTarget.CaptureError.secure))
                    case .noSelection, .unavailable:
                        finish(.failure(SelectedTextTarget.CaptureError.noSelection))
                    }
                }
            }
        }
    }

    @discardableResult
    func configureActivePresetOnOpen(spoken: Bool,
                                     defaults: UserDefaults = .standard) -> Bool {
        buildIfNeeded()
        guard !spoken else { return false }
        if let preset = TransformPresets.activePreset(defaults) {
            recipe.selectItem(withTitle: SelectionTransformKind.custom.rawValue)
            customRow?.isHidden = false
            custom.isEnabled = true
            custom.stringValue = preset.instruction
            return !preset.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let kind = TransformPresets.activeKind(defaults)
        recipe.selectItem(withTitle: kind.rawValue)
        customRow?.isHidden = kind != .custom
        custom.isEnabled = kind == .custom
        if kind == .custom {
            return !custom.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var activeSelectionKindForTesting: SelectionTransformKind { selectedKind }
    var customInstructionForTesting: String { custom.stringValue }

    func beginCaptured(_ target: SelectedTextTarget) {
        guard !running, !Updater.isInstalling else { return }
        generation += 1
        self.target = target; preview = target.original
        buildIfNeeded(); reloadPresets()
        originalView.string = target.original; resultView.string = target.original
        status.stringValue = ""
        updateButtons(); window?.orderFrontRegardless()
    }

    @objc private func speakInstruction() {
        guard target != nil, !running else { return }
        recipe.selectItem(withTitle: SelectionTransformKind.custom.rawValue)
        customRow?.isHidden = false
        custom.isEnabled = true
        status.stringValue = "Speak your edit, then release the hotkey or choose Finish in FlowClone."
        DictationWorkspace.shared.onCapture(.instruction(generation), nil)
    }

    func receiveInstruction(_ instruction: String, generation expected: Int) {
        guard generation == expected, target != nil, window?.isVisible == true else { return }
        custom.stringValue = instruction
        generate()
    }

    func captureStateChanged() { if window != nil { updateButtons() } }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === resultView, !running else { return }
        preview = resultView.string.isEmpty ? nil : resultView.string
        updateButtons()
    }

    func undoLast() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let record = undoRecord, !running, !Updater.isInstalling else { return }
        running = true
        updateButtons()
        // The pre-flight is four Accessibility round-trips against another app. `running`
        // already blocks re-entry, so the main thread does not have to wait for them —
        // the same shape begin() uses. Every outcome lands back on main.
        DispatchQueue.global(qos: .userInitiated).async {
            func stop(_ outcome: UndoFinish, _ message: String) {
                DispatchQueue.main.async { self.finishUndo(outcome, message: message) }
            }
            guard record.target.revalidateElement() else {
                return stop(.retryable,
                            "Undo paused — return to the original app and try again.")
            }
            guard let current = record.target.string(in: record.range) else {
                return stop(.retryable,
                            "Undo paused — FlowClone could not read the transformed text. Try again.")
            }
            guard current == record.replacement else {
                return stop(.stale, "Undo expired because the transformed text changed.")
            }
            guard record.target.select(record.range) else {
                return stop(.retryable,
                            "Undo paused — FlowClone could not select the transformed text. Try again.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = record.target.replace(expected: record.replacement, at: record.range,
                                                       with: record.original)
                    // A failed mutation made no lasting change (or safely rolled itself
                    // back). Keep the undo token unless exact readback proves somebody
                    // changed the transformed text during the attempt — that readback is
                    // two more Accessibility round-trips, so it is answered here rather
                    // than on the thread drawing this window.
                    var changedUnderUs = false
                    if case .failed = result, record.target.revalidateElement(),
                       let current = record.target.string(in: record.range) {
                        changedUnderUs = current != record.replacement
                    }
                    DispatchQueue.main.async {
                        switch result {
                        case .verified:
                            self.finishUndo(.success, message: "Transform undone.")
                        case .failed(let why):
                            if changedUnderUs {
                                self.finishUndo(.stale,
                                                message: "Undo expired because the transformed text changed.")
                            } else {
                                self.finishUndo(.retryable,
                                                message: "Undo paused — \(why). Try again.")
                            }
                        case .ambiguous(let why):
                            self.finishUndo(.ambiguous,
                                            message: "Undo is uncertain — \(why).")
                        }
                    }
                }
            }
        }
    }

    private func finishUndo(_ outcome: UndoFinish, message: String,
                            notify: Bool = true) {
        running = false
        switch outcome {
        case .success, .stale:
            undoRecord = nil
            undoAvailable = false
        case .ambiguous:
            invalidateTransaction(clearUndo: true)
        case .retryable:
            break
        }
        if notify { notifyUser(message) }
        status.stringValue = message
        updateButtons()
    }

    private func buildIfNeeded() {
        guard window == nil else { return }
        recipe.addItems(withTitles: SelectionTransformKind.allCases.map(\.rawValue))
        recipe.target = self
        recipe.action = #selector(recipeChanged)
        custom.placeholderString = "Custom instruction, e.g. Make this concise"
        custom.isEnabled = false
        custom.delegate = self
        presets.target = self
        presets.action = #selector(presetPicked(_:))

        generateButton.target = self
        generateButton.action = #selector(generate)
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        retryButton.target = self
        retryButton.action = #selector(generate)
        undoButton.target = self
        undoButton.action = #selector(undoAction)
        speakButton.target = self
        speakButton.action = #selector(speakInstruction)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let recipeRow = NSStackView(views: [NSTextField(labelWithString: "Transform"), recipe, presets, spacer, generateButton])
        recipeRow.spacing = 10
        let instructionRow = NSStackView(views: [NSTextField(labelWithString: "Instruction"), custom, speakButton])
        instructionRow.spacing = 12
        instructionRow.isHidden = selectedKind != .custom
        customRow = instructionRow
        custom.setContentHuggingPriority(.defaultLow, for: .horizontal)
        custom.setAccessibilityLabel("Custom instruction")
        recipe.setAccessibilityLabel("Transform mode")

        configureTextView(originalView)
        configureTextView(resultView)
        resultView.isEditable = true
        resultView.allowsUndo = true
        resultView.delegate = self
        resultView.isAutomaticQuoteSubstitutionEnabled = false
        resultView.isAutomaticDashSubstitutionEnabled = false
        originalView.setAccessibilityLabel("Original text")
        resultView.setAccessibilityLabel("Preview text")
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        for (title, view) in [("Original", originalView), ("Preview", resultView)] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            let scrollView = scroll(view)
            let pane = NSStackView(views: [label, scrollView])
            pane.orientation = .vertical; pane.alignment = .leading; pane.spacing = 10
            pane.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)
            scrollView.widthAnchor.constraint(equalTo: pane.widthAnchor, constant: -20).isActive = true
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
            split.addArrangedSubview(pane)
        }
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        split.setContentHuggingPriority(.defaultLow, for: .vertical)

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.keyEquivalent = "\u{1b}"
        acceptButton.bezelStyle = .rounded
        acceptButton.bezelColor = NSColor(red: 0.43, green: 0.34, blue: 0.62, alpha: 1)
        acceptButton.keyEquivalent = "\r"
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [undoButton, retryButton, actionSpacer, closeButton, acceptButton])
        actions.spacing = 10
        let stack = NSStackView(views: [recipeRow, instructionRow, split, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        let root = NSView()
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        for row in [recipeRow, instructionRow, split, status, actions] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let window = TransformPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
                                    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        window.title = "FlowClone · Transform preview"
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        window.minSize = NSSize(width: 740, height: 460)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        self.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance),
                                               name: AppearanceStore.didChange, object: nil)
        applyAppearance()
    }

    @objc private func applyAppearance() {
        window?.backgroundColor = Theme.nativeColor(\.ground)
        acceptButton.bezelColor = Theme.nativeColor(\.accent)
        status.textColor = Theme.nativeColor(\.muted)
        for view in [originalView, resultView] {
            view.backgroundColor = Theme.nativeColor(\.card)
            view.textColor = Theme.nativeColor(\.ink)
            let font = view.string.contains("```")
                ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                : Theme.nativeWritingFont(14)
            view.font = font
            if let storage = view.textStorage, storage.length > 0 {
                storage.addAttributes([.font: font, .foregroundColor: Theme.nativeColor(\.ink)],
                                      range: NSRange(location: 0, length: storage.length))
            }
        }
    }

    private func configureTextView(_ view: NSTextView) {
        view.isEditable = false; view.isSelectable = true
        view.font = Theme.nativeWritingFont(14)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
    }

    private func scroll(_ view: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.documentView = view
        return scroll
    }

    @objc private func recipeChanged() {
        if selectedKind != .custom {
            TransformPresets.setActiveKind(selectedKind)
        }
        custom.isEnabled = selectedKind == .custom
        customRow?.isHidden = selectedKind != .custom
        SelectionTransformer.prepare(selectedKind)
        preview = nil
        resultView.string = ""
        status.stringValue = ""
        updateButtons()
    }

    /// Saved Custom instructions from the Transforms page. Re-read on every begin() so an
    /// edit in the window shows up on the next transform without a relaunch.
    private func reloadPresets() {
        let saved = TransformPresets.loadNamed()
        savedPresets = saved
        presets.removeAllItems()
        presets.addItem(withTitle: "Presets")      // pull-down title row
        // addItems(withTitles:) removes an existing item with the same title: two identical
        // saved instructions would collapse, and one saved as "Presets" would delete the
        // title row and invalidate the index guard below. Menu items are added directly
        // instead; AppKit still retargets them to the pull-down's own action.
        for preset in saved {
            let entry = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            entry.toolTip = preset.instruction
            presets.menu?.addItem(entry)
        }
        presets.isHidden = saved.isEmpty
    }

    @objc private func presetPicked(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard savedPresets.indices.contains(index) else { return }
        let picked = savedPresets[index]
        TransformPresets.setActivePresetID(picked.id)
        recipe.selectItem(withTitle: SelectionTransformKind.custom.rawValue)
        recipeChanged()
        custom.stringValue = picked.instruction
        if target != nil, !running {
            generate()
        }
    }

    @objc private func generate() {
        guard let target, !running else { return }
        if selectedKind == .custom,
           custom.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status.stringValue = "Enter a custom instruction first."
            return
        }
        // Blocks re-entry while the selection is re-read off the main thread: that read is
        // bounded but synchronous Accessibility traffic. Nothing else changes until we
        // know the preview is really starting, so a refusal leaves the window as it was.
        running = true
        updateButtons()
        let kind = selectedKind
        let instruction = custom.stringValue
        DispatchQueue.global(qos: .userInitiated).async {
            let stillOurs = target.canStartPreview()
            DispatchQueue.main.async {
                self.running = false
                guard stillOurs else {
                    self.status.stringValue = "Preview stopped because the original app or selection changed."
                    self.updateButtons()
                    return
                }
                self.startPreview(target, kind: kind, instruction: instruction)
            }
        }
    }

    /// Main thread, from `generate()` once the selection has been re-read off it.
    private func startPreview(_ target: SelectedTextTarget, kind: SelectionTransformKind,
                              instruction: String) {
        if kind == .custom, let output = SpokenEdit.deterministic(instruction, original: target.original) {
            preview = output; resultView.string = output
            status.stringValue = "Preview ready."
            updateButtons()
            return
        }
        running = true
        recipe.isEnabled = false
        custom.isEnabled = false
        preview = nil
        generation += 1
        let g = generation
        status.stringValue = "Generating…"
        updateButtons()
        SelectionTransformer.run(kind: kind, input: target.original,
                                 instruction: instruction) { output, took in
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.running = false
                self.recipe.isEnabled = true
                self.custom.isEnabled = self.selectedKind == .custom
                guard let output else {
                    self.status.stringValue = AppleIntelligenceStatus.current.transformFailure
                    self.updateButtons()
                    return
                }
                guard output != target.original else {
                    self.preview = nil
                    self.resultView.textStorage?.setAttributedString(
                        self.styled(output, changed: nil, color: .systemGreen))
                    self.status.stringValue = "No changes needed."
                    self.updateButtons()
                    return
                }
                self.preview = output
                let ranges = TransformDiff.changedRanges(target.original, output)
                self.originalView.textStorage?.setAttributedString(
                    self.styled(target.original, changed: ranges.original, color: .systemRed))
                self.resultView.textStorage?.setAttributedString(
                    self.styled(output, changed: ranges.result, color: .systemGreen))
                self.status.stringValue = String(format: "Preview ready (%.0f ms).", took)
                self.updateButtons()
            }
        }
    }

    @objc private func accept() {
        guard let target, let preview, preview != target.original, !running else { return }
        if target.usesPasteFallback {
            acceptViaPaste(target: target, replacement: preview)
            return
        }
        running = true
        AutoLearn.monitor.stop()
        updateButtons()
        DispatchQueue.global(qos: .userInitiated).async {
            // The pre-flight re-read is Accessibility traffic like the write it guards,
            // and belongs on the same queue — never on the thread drawing this window.
            guard target.revalidateSelection(expected: target.original,
                                             range: target.range) else {
                DispatchQueue.main.async {
                    self.running = false
                    self.status.stringValue = "Accept stopped — the original app or selection changed."
                    self.updateButtons()
                }
                return
            }
            let result = target.replace(expected: target.original, at: target.range, with: preview)
            DispatchQueue.main.async {
                self.running = false
                switch result {
                case .verified(let range):
                    self.undoRecord = UndoRecord(target: target, original: target.original,
                                                 replacement: preview, range: range)
                    self.undoAvailable = true
                    self.status.stringValue = "Applied. Undo remains available until that text changes."
                    self.updateButtons()
                    notifyUser("Transform applied. Use Undo last transform to restore the original.")
                case .failed(let why):
                    self.status.stringValue = "Accept stopped — \(why)."
                    self.updateButtons()
                case .ambiguous(let why):
                    self.invalidateTransaction(clearUndo: true)
                    self.status.stringValue = "Result uncertain — \(why). Copy the original from this window if needed."
                    self.updateButtons()
                    notifyUser("Transform result is uncertain; FlowClone did not enable automatic Undo.")
                }
            }
        }
    }

    private func acceptViaPaste(target: SelectedTextTarget, replacement: String) {
        let expectedApp = PasteTarget.AppIdentity(bundleID: target.bundleID, pid: target.pid)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let initialFrontmost = PasteTarget.AppIdentity.frontmost()
        guard initialFrontmost == expectedApp || initialFrontmost?.pid == ourPID else {
            status.stringValue = "Accept stopped — return to the original app and try again."
            updateButtons()
            return
        }
        running = true
        AutoLearn.monitor.stop()
        updateButtons()

        let wasVisible = window?.isVisible == true
        let neededFocusHandoff = (window?.isKeyWindow == true)
            || (initialFrontmost?.pid == ourPID && expectedApp.pid != ourPID)
        window?.makeFirstResponder(nil)
        if neededFocusHandoff {
            window?.orderOut(nil)
        }
        if initialFrontmost?.pid == ourPID, expectedApp.pid != ourPID {
            _ = NSRunningApplication(processIdentifier: expectedApp.pid)?.activate()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if neededFocusHandoff {
                Thread.sleep(forTimeInterval: 0.060)
            }
            guard !AXClient.isSecureInputEnabled() else {
                DispatchQueue.main.async {
                    if neededFocusHandoff, wasVisible { self.window?.orderFrontRegardless() }
                    self.running = false
                    self.status.stringValue = "Accept stopped — secure text input is active."
                    self.updateButtons()
                }
                return
            }
            guard PasteTarget.AppIdentity.frontmost() == expectedApp else {
                DispatchQueue.main.async {
                    if neededFocusHandoff, wasVisible { self.window?.orderFrontRegardless() }
                    self.running = false
                    self.status.stringValue = "Accept stopped — return to the original app and try again."
                    self.updateButtons()
                }
                return
            }
            if let fallbackElement = target.fallbackElement {
                switch AXClient.focusedElement(
                    pid: target.pid, deadline: AXClient.Deadline(total: 0.12, perCall: 0.04)) {
                case .secure, .foreign:
                    DispatchQueue.main.async {
                        if neededFocusHandoff, wasVisible { self.window?.orderFrontRegardless() }
                        self.running = false
                        self.status.stringValue = "Accept stopped — the target field changed."
                        self.updateButtons()
                    }
                    return
                case .element(let current) where !CFEqual(current, fallbackElement):
                    DispatchQueue.main.async {
                        if neededFocusHandoff, wasVisible { self.window?.orderFrontRegardless() }
                        self.running = false
                        self.status.stringValue = "Accept stopped — the target field changed."
                        self.updateButtons()
                    }
                    return
                case .element, .unavailable, .unknownRole, .timedOut:
                    break
                }
            }
            guard let pasteTarget = PasteTarget.capture(
                for: expectedApp, interactionEpoch: FocusInteractionEpoch.snapshot()
            ) else {
                DispatchQueue.main.async {
                    if neededFocusHandoff, wasVisible { self.window?.orderFrontRegardless() }
                    self.running = false
                    self.status.stringValue = "Accept stopped — the original app changed."
                    self.updateButtons()
                }
                return
            }
            Paster.paste(replacement, expectedTarget: pasteTarget, keepOnClipboard: false) { delivery in
                DispatchQueue.main.async {
                    if neededFocusHandoff, wasVisible { self.window?.orderFrontRegardless() }
                    self.running = false
                    switch delivery {
                    case .posted:
                        self.undoRecord = nil
                        self.undoAvailable = false
                        self.preview = nil
                        self.status.stringValue = "Applied. Use Undo (⌘Z) in the app to restore the original."
                        self.updateButtons()
                        notifyUser("Transform applied.")
                    case .notPosted(let recovery, let why):
                        self.status.stringValue = recovery == .transcriptOnClipboard
                            ? "Accept stopped (\(why)) — transformed text is on the clipboard."
                            : "Accept stopped — \(why)."
                        self.updateButtons()
                    case .ambiguous(_, let recovery, let why):
                        self.invalidateTransaction(clearUndo: true)
                        self.status.stringValue = recovery == .transcriptOnClipboard
                            ? "Result uncertain (\(why)) — transformed text is on the clipboard."
                            : "Result uncertain — \(why). Copy the original from this window if needed."
                        self.updateButtons()
                        notifyUser("Transform result is uncertain; FlowClone did not enable automatic Undo.")
                    case .skippedEmpty:
                        self.status.stringValue = "Accept stopped — preview is empty."
                        self.updateButtons()
                    }
                }
            }
        }
    }

    @objc private func undoAction() { undoLast() }
    @objc private func close() {
        if !running { generation += 1; target = nil; preview = nil }
        if DictationWorkspace.shared.captureLabel == "Edit instruction" {
            DictationWorkspace.shared.onCancel()
        }
        window?.orderOut(nil)
    }

    private var selectedKind: SelectionTransformKind {
        SelectionTransformKind.allCases[max(0, recipe.indexOfSelectedItem)]
    }

    private func updateButtons() {
        let speaking = DictationWorkspace.shared.recording && DictationWorkspace.shared.captureLabel == "Edit instruction"
        speakButton.title = speaking ? "Finish instruction" : "Speak instruction"
        speakButton.isEnabled = !running && target != nil
        resultView.isEditable = !running
        generateButton.isEnabled = target != nil && !running && !speaking
        retryButton.isEnabled = target != nil && !running
        acceptButton.isEnabled = target.map { preview != nil && preview != $0.original } == true
            && !running && !speaking
        undoButton.isEnabled = undoAvailable && !running
        undoButton.isHidden = !undoAvailable
        retryButton.isHidden = preview != nil || resultView.string.isEmpty
        recipe.isEnabled = !running
        custom.isEnabled = !running && selectedKind == .custom
        // Without this the pull-down escapes the lockout that keeps recipeChanged()
        // unreachable mid-preview, and an in-flight run would land a preview built from
        // the previous recipe under the newly picked instruction.
        presets.isEnabled = !running
    }

    /// Ambiguous AX writes are a hard transaction boundary. Keeping an old target,
    /// preview, or undo token alive would let a second click mutate text whose current
    /// contents FlowClone could not prove.
    private func invalidateTransaction(clearUndo: Bool) {
        generation += 1
        target = nil
        preview = nil
        if clearUndo {
            undoRecord = nil
            undoAvailable = false
        }
    }

    private func styled(_ text: String, changed: NSRange?, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let code = text.contains("```")
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: code ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : Theme.nativeWritingFont(14),
            .paragraphStyle: paragraph,
            .foregroundColor: Theme.nativeColor(\.ink),
        ])
        if let changed, changed.length > 0,
           NSMaxRange(changed) <= (text as NSString).length {
            out.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.22), range: changed)
        }
        return out
    }

    #if DEBUG
    /// Isolated GUI fixtures call this without capturing an app or enabling replacement.
    func showDesignPreview(original: String, result: String, customMode: Bool = false, size: NSSize? = nil) {
        buildIfNeeded()
        window?.appearance = NSApp.mainWindow?.effectiveAppearance
        if let size { window?.setContentSize(size) }
        target = nil; preview = nil
        recipe.selectItem(withTitle: customMode ? SelectionTransformKind.custom.rawValue : SelectionTransformKind.polish.rawValue)
        customRow?.isHidden = !customMode
        custom.stringValue = customMode ? "Make this concise and friendly." : ""
        reloadPresets()
        originalView.textStorage?.setAttributedString(styled(original, changed: nil, color: .systemRed))
        resultView.textStorage?.setAttributedString(styled(result, changed: nil, color: .systemGreen))
        status.stringValue = "Synthetic preview · no external text target is attached."
        updateButtons()
        window?.makeKeyAndOrderFront(nil)
    }
    #endif

    /// Deterministic transaction tests. No AX calls, model requests, clipboard access, or
    /// cross-process writes occur here; the fake exposes every observation and mutation.
    @discardableResult static func selfCheck() -> Int {
        let logic = SelectionTransformer.selfCheck()
        var checks = logic.checks
        var failed = logic.failed
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            checks += 1
            if !condition() { failed += 1; log("TRANSFORMTEST FAIL: \(name)") }
        }
        func failedResult(_ result: SelectedTextTarget.ReplaceResult) -> Bool {
            if case .failed = result { return true }
            return false
        }
        func ambiguousResult(_ result: SelectedTextTarget.ReplaceResult) -> Bool {
            if case .ambiguous = result { return true }
            return false
        }

        let stale = FakeSelectionMutation(selectionMatches: false)
        check("stale target refused",
              failedResult(stale.run()) && stale.writes.isEmpty)

        let noOp = FakeSelectionMutation()
        check("unchanged preview never writes",
              failedResult(noOp.run(replacingWith: noOp.expected)) && noOp.writes.isEmpty)

        let readOnly = FakeSelectionMutation(settable: false)
        check("read-only target refused",
              failedResult(readOnly.run()) && readOnly.writes.isEmpty)

        func deletionIO(applies: Bool) -> SelectionMutationIO {
            var deleted = false
            return SelectionMutationIO(
                selectionMatches: { _, _ in !deleted }, selectedTextSettable: { true },
                writeSelectedText: { _ in deleted = applies; return true },
                stringInRange: { range in range.length == 0 ? "" : (deleted ? nil : "old") },
                selectedRange: { CFRange(location: 2, length: deleted ? 0 : 3) },
                selectedText: { deleted ? "" : "old" })
        }
        let deletion = SelectionMutation.replace(expected: "old", at: CFRange(location: 2, length: 3),
                                                 with: "", io: deletionIO(applies: true))
        if case .verified = deletion { check("verified deletion accepts a collapsed caret", true) }
        else { check("verified deletion accepts a collapsed caret", false) }
        check("empty-range read cannot confirm an ignored deletion", ambiguousResult(
            SelectionMutation.replace(expected: "old", at: CFRange(location: 2, length: 3),
                                      with: "", io: deletionIO(applies: false))))

        let movedDuringSettable = FakeSelectionMutation(moveSelectionDuringSettable: true)
        check("selection moved during settable query is refused before write",
              failedResult(movedDuringSettable.run()) && movedDuringSettable.writes.isEmpty)

        let writeFail = FakeSelectionMutation(writeSucceeds: false, writeApplies: false)
        check("reported write failure with unchanged original is safe",
              failedResult(writeFail.run()) && writeFail.writes == [writeFail.replacement])

        let falseButApplied = FakeSelectionMutation(writeSucceeds: false, writeApplies: true)
        let falseButAppliedResult = falseButApplied.run()
        if case .verified(let range) = falseButAppliedResult {
            check("reported write failure with exact replacement readback is verified",
                  range.location == falseButApplied.expectedRange.location
                  && range.length == falseButApplied.replacement.utf16.count
                  && falseButApplied.writes == [falseButApplied.replacement])
        } else {
            check("reported write failure with exact replacement readback is verified", false)
        }

        let falsePartial = FakeSelectionMutation(writeSucceeds: false, writeApplies: true,
                                                 readback: .mismatch)
        check("reported write failure with partial side effect is ambiguous",
              ambiguousResult(falsePartial.run())
              && falsePartial.writes == [falsePartial.replacement])

        let exact = FakeSelectionMutation(readback: .exact)
        let exactResult = exact.run()
        if case .verified(let range) = exactResult {
            check("exact readback verifies once",
                  range.location == exact.expectedRange.location
                  && range.length == exact.replacement.utf16.count
                  && exact.writes == [exact.replacement])
        } else {
            check("exact readback verifies once", false)
        }

        let mismatch = FakeSelectionMutation(readback: .mismatch,
                                             replacementRemainsSelected: true)
        check("mismatched readback never rolls back a predicted range",
              ambiguousResult(mismatch.run()) && mismatch.writes == [mismatch.replacement])

        let nilUnsafe = FakeSelectionMutation(readback: .unavailable,
                                              replacementRemainsSelected: false)
        check("nil readback without exact selection is terminal",
              ambiguousResult(nilUnsafe.run()) && nilUnsafe.writes == [nilUnsafe.replacement])

        let rollback = FakeSelectionMutation(readback: .unavailable,
                                             replacementRemainsSelected: true)
        check("nil readback rolls back only a verified selected replacement",
              failedResult(rollback.run())
              && rollback.writes == [rollback.replacement, rollback.expected])

        let rollbackUnverified = FakeSelectionMutation(readback: .unavailable,
                                                       replacementRemainsSelected: true,
                                                       rollbackReadbackSucceeds: false)
        check("unverified rollback remains ambiguous",
              ambiguousResult(rollbackUnverified.run())
              && rollbackUnverified.writes == [rollbackUnverified.replacement,
                                                rollbackUnverified.expected])

        let controller = TransformController()
        let dummy = SelectedTextTarget(element: AXUIElementCreateSystemWide(), pid: 1,
                                       bundleID: "com.example.Editor",
                                       range: CFRange(location: 2, length: 4), original: "test")
        let sameApp = PasteTarget.AppIdentity(bundleID: dummy.bundleID, pid: dummy.pid)
        check("stable target identity accepts matching closing observation",
              SelectedTextTarget.stableTarget(
                expectedElement: dummy.element, expectedPID: dummy.pid,
                expectedBundleID: dummy.bundleID, before: sameApp,
                firstElement: dummy.element, secure: false,
                finalElement: dummy.element, after: sameApp))
        check("closing app transition is rejected",
              !SelectedTextTarget.stableTarget(
                expectedElement: dummy.element, expectedPID: dummy.pid,
                expectedBundleID: dummy.bundleID, before: sameApp,
                firstElement: dummy.element, secure: false,
                finalElement: dummy.element,
                after: PasteTarget.AppIdentity(bundleID: dummy.bundleID, pid: 2)))
        check("closing focus transition is rejected",
              !SelectedTextTarget.stableTarget(
                expectedElement: dummy.element, expectedPID: dummy.pid,
                expectedBundleID: dummy.bundleID, before: sameApp,
                firstElement: dummy.element, secure: false,
                finalElement: AXUIElementCreateApplication(2), after: sameApp))
        check("closing secure transition is rejected",
              !SelectedTextTarget.stableTarget(
                expectedElement: dummy.element, expectedPID: dummy.pid,
                expectedBundleID: dummy.bundleID, before: sameApp,
                firstElement: dummy.element, secure: true,
                finalElement: dummy.element, after: sameApp))
        controller.target = dummy
        controller.preview = "result"
        controller.undoRecord = UndoRecord(target: dummy, original: "test",
                                           replacement: "result",
                                           range: CFRange(location: 2, length: 6))
        controller.undoAvailable = true
        let oldGeneration = controller.generation
        controller.invalidateTransaction(clearUndo: true)
        check("ambiguity invalidates repeat and undo state",
              controller.target == nil && controller.preview == nil
              && controller.undoRecord == nil && !controller.undoAvailable
              && controller.generation == oldGeneration + 1)

        func undoController() -> TransformController {
            let value = TransformController()
            value.target = dummy
            value.preview = "result"
            value.undoRecord = UndoRecord(target: dummy, original: "test",
                                          replacement: "result",
                                          range: CFRange(location: 2, length: 6))
            value.undoAvailable = true
            value.running = true
            return value
        }

        let retryableUndo = undoController()
        let retryableGeneration = retryableUndo.generation
        retryableUndo.finishUndo(.retryable, message: "retry", notify: false)
        check("retryable undo preserves record and active preview",
              retryableUndo.undoRecord != nil && retryableUndo.undoAvailable
              && retryableUndo.target != nil && retryableUndo.preview == "result"
              && retryableUndo.generation == retryableGeneration && !retryableUndo.running)

        let staleUndo = undoController()
        let staleGeneration = staleUndo.generation
        staleUndo.finishUndo(.stale, message: "stale", notify: false)
        check("stale undo clears only undo state",
              staleUndo.undoRecord == nil && !staleUndo.undoAvailable
              && staleUndo.target != nil && staleUndo.preview == "result"
              && staleUndo.generation == staleGeneration)

        let ambiguousUndo = undoController()
        let ambiguousGeneration = ambiguousUndo.generation
        ambiguousUndo.finishUndo(.ambiguous, message: "ambiguous", notify: false)
        check("ambiguous undo invalidates the transaction",
              ambiguousUndo.undoRecord == nil && !ambiguousUndo.undoAvailable
              && ambiguousUndo.target == nil && ambiguousUndo.preview == nil
              && ambiguousUndo.generation == ambiguousGeneration + 1)

        let successfulUndo = undoController()
        let successfulGeneration = successfulUndo.generation
        successfulUndo.finishUndo(.success, message: "success", notify: false)
        check("successful undo clears only undo state",
              successfulUndo.undoRecord == nil && !successfulUndo.undoAvailable
              && successfulUndo.target != nil && successfulUndo.preview == "result"
              && successfulUndo.generation == successfulGeneration)

        log(failed == 0 ? "TRANSFORMTEST PASS (\(checks) checks)"
                        : "TRANSFORMTEST FAIL (\(failed)/\(checks) checks)")
        return failed
    }
}

private final class FakeSelectionMutation {
    enum Readback { case exact, mismatch, unavailable }

    let expected = "old text"
    let replacement = "new result"
    let expectedRange = CFRange(location: 7, length: 8)
    var writes: [String] = []

    private let selectionMatches: Bool
    private let settable: Bool
    private let writeSucceeds: Bool
    private let writeApplies: Bool
    private let readback: Readback
    private let replacementRemainsSelected: Bool
    private let rollbackReadbackSucceeds: Bool
    private let moveSelectionDuringSettable: Bool
    private var currentRange: CFRange?
    private var currentText: String?

    init(selectionMatches: Bool = true, settable: Bool = true,
         writeSucceeds: Bool = true, writeApplies: Bool? = nil,
         readback: Readback = .exact,
         replacementRemainsSelected: Bool = false,
         rollbackReadbackSucceeds: Bool = true,
         moveSelectionDuringSettable: Bool = false) {
        self.selectionMatches = selectionMatches
        self.settable = settable
        self.writeSucceeds = writeSucceeds
        self.writeApplies = writeApplies ?? writeSucceeds
        self.readback = readback
        self.replacementRemainsSelected = replacementRemainsSelected
        self.rollbackReadbackSucceeds = rollbackReadbackSucceeds
        self.moveSelectionDuringSettable = moveSelectionDuringSettable
        currentRange = expectedRange
        currentText = expected
    }

    func run(replacingWith proposed: String? = nil) -> SelectedTextTarget.ReplaceResult {
        let proposed = proposed ?? replacement
        let io = SelectionMutationIO(
            selectionMatches: { [self] text, range in
                selectionMatches && text == expected
                    && range.location == expectedRange.location
                    && range.length == expectedRange.length
                    && currentText == text
                    && currentRange?.location == range.location
                    && currentRange?.length == range.length
            },
            selectedTextSettable: { [self] in
                if moveSelectionDuringSettable {
                    currentRange = CFRange(location: expectedRange.location + 1,
                                           length: expectedRange.length)
                    currentText = "other text"
                }
                return settable
            },
            writeSelectedText: { [self] text in
                writes.append(text)
                if writeApplies {
                    currentText = text
                    if text == replacement {
                        currentRange = replacementRemainsSelected
                            ? CFRange(location: expectedRange.location, length: replacement.utf16.count)
                            : CFRange(location: expectedRange.location + replacement.utf16.count, length: 0)
                    } else {
                        currentRange = expectedRange
                    }
                }
                return writeSucceeds
            },
            stringInRange: { [self] range in
                if writes.last == expected {
                    return rollbackReadbackSucceeds ? expected : nil
                }
                if !writeApplies,
                   range.location == expectedRange.location,
                   range.length == expectedRange.length {
                    return expected
                }
                switch readback {
                case .exact: return replacement
                case .mismatch: return "partial"
                case .unavailable: return nil
                }
            },
            selectedRange: { [self] in currentRange },
            selectedText: { [self] in currentText }
        )
        return SelectionMutation.replace(expected: expected, at: expectedRange,
                                         with: proposed, io: io)
    }
}
