import Cocoa
import CoreAudio
import XCTest
import SwiftUI
@testable import FlowCloneCore

final class DictationInputTests: XCTestCase {
    func testSpellingPreservesAnExactIdentifier() throws {
        XCTAssertEqual(try SpellingParser.parse("capital alpha bravo underscore one dot charlie"), "Ab_1.c")
        XCTAssertEqual(try SpellingParser.parse("uppercase x-ray yankee lowercase zulu slash zero"), "XYz/0")
        XCTAssertThrowsError(try SpellingParser.parse("alpha mystery bravo"))
        XCTAssertThrowsError(try SpellingParser.parse("uppercase"))
    }
    func testExactInputCannotEnterCleanupOrLearning() {
        for purpose in [CapturePurpose.editor(.literal), .editor(.spelling), .instruction(1), .practice] {
            XCTAssertFalse(purpose.usesCleanup)
            XCTAssertFalse(purpose.learns)
        }
        XCTAssertTrue(CapturePurpose.editor(.normal).learns)
        XCTAssertFalse(CapturePurpose.draft.learns)
    }
    func testExplicitEditsAndOrdinaryQuotedCommandsStayDistinct() {
        XCTAssertEqual(SpokenEdit.deterministic("Snake case.", original: "Order Number 42"), "order_number_42")
        XCTAssertEqual(SpokenEdit.deterministic("uppercase", original: "café"), "CAFÉ")
        XCTAssertEqual(SpokenEdit.deterministic("replace selection with hello", original: "before"), "hello")
        XCTAssertNil(SpokenEdit.deterministic("She said uppercase is too loud", original: "before"))
    }
}

@MainActor
final class UsabilityNativeTests: XCTestCase {
    func testSelectionTransactionsIncludingVerifiedDeletion() {
        XCTAssertEqual(TransformController.selfCheck(), 0)
    }
    func testNativeDraftEditorDeliversEditsAndDisablesSmartSubstitution() {
        _ = NSApplication.shared
        var text = "before"
        let host = NSHostingView(rootView: DraftTextEditor(text: Binding(get: { text }, set: { text = $0 }), label: "Practice dictation field"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        guard let editor = editor(in: host) else { XCTFail("Native editor was not mounted"); return }
        XCTAssertEqual(editor.accessibilityLabel(), "Practice dictation field")
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertTrue(editor.allowsUndo)
        window.makeFirstResponder(editor)
        editor.insertText("order_number_42", replacementRange: NSRange(location: 0, length: 6))
        XCTAssertEqual(text, "order_number_42", "Native insertion must reach the SwiftUI draft binding")
        XCTAssertEqual(editor.string, text)
        window.contentView = nil
    }
}

final class ShortcutRoutingTests: XCTestCase {
    func testReleaseUsesAcceptedBindingAfterSettingsChange() {
        var router = ShortcutRouter()
        let binding = ShortcutBinding(action: .dictate, keyCode: 49, modifiers: CGEventFlags.maskControl.rawValue, keyLabel: "Space")
        let down = router.event(type: .keyDown, key: 49, flags: .maskControl, repeated: false, bindings: [binding])
        XCTAssertTrue(down.consumed); XCTAssertEqual(down.held.count, 1); XCTAssertTrue(down.held[0].1)
        let up = router.event(type: .keyUp, key: 49, flags: [], repeated: false, bindings: [])
        XCTAssertTrue(up.consumed); XCTAssertEqual(up.held.count, 1); XCTAssertFalse(up.held[0].1)
    }
    func testRepeatsAreSwallowedWithoutDispatchingAgain() {
        var router = ShortcutRouter()
        let binding = ShortcutBinding(action: .spelling, keyCode: 1, modifiers: CGEventFlags.maskControl.rawValue, keyLabel: "S")
        XCTAssertEqual(router.event(type: .keyDown, key: 1, flags: .maskControl, repeated: false, bindings: [binding]).actions, [.spelling])
        let repeatEvent = router.event(type: .keyDown, key: 1, flags: .maskControl, repeated: true, bindings: [binding])
        XCTAssertTrue(repeatEvent.consumed); XCTAssertTrue(repeatEvent.actions.isEmpty)
        XCTAssertTrue(router.event(type: .keyUp, key: 1, flags: [], repeated: false, bindings: []).consumed)
    }
    func testArrowFnFlagDoesNotStartRecordingAndUnassignedFnPassesThrough() {
        var router = ShortcutRouter()
        XCTAssertTrue(router.event(type: .keyDown, key: 123, flags: .maskSecondaryFn, repeated: false,
                                   bindings: ShortcutBinding.defaults).held.isEmpty)
        XCTAssertFalse(router.event(type: .flagsChanged, key: 63, flags: .maskSecondaryFn, repeated: false, bindings: []).consumed)
    }
    func testConflictsAndCancellationAreValidated() throws {
        let suite = ScratchDefaults.name("shortcut")
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: preferences)
        XCTAssertThrowsError(try store.save(.init(action: .literal, keyCode: 63, modifiers: 0, keyLabel: "fn")))
        XCTAssertThrowsError(try store.save(.init(action: .literal, keyCode: 53, modifiers: CGEventFlags.maskCommand.rawValue, keyLabel: "Escape")))
        try store.save(.init(action: .literal, keyCode: 1, modifiers: CGEventFlags.maskControl.rawValue, keyLabel: "S"))
        XCTAssertEqual(ShortcutStore(defaults: preferences).bindings.last?.action, .literal)
    }
}

final class VocabularyWorkflowTests: XCTestCase {
    func testScopesRespectAppLanguageDisableAndManualPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-scopes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let sets = VocabularySets(root: root)
        let app = VocabularySet(name: "Code", bundleID: "test.editor", language: "en")
        let manual = VocabularySet(name: "Project")
        try sets.update { $0.sets = [app, manual]; $0.active = manual.id }
        for (id, replacement) in [(nil as UUID?, "Global"), (app.id, "Editor"), (manual.id, "Project")] {
            let store = sets.store(id)
            try store.add(.init(kind: .correction, primary: "token", replacement: replacement), expected: store.snapshot(.correction).fingerprint)
        }
        let frozen = sets.configuration(bundleID: "test.editor")
        XCTAssertEqual(Cleaner.cleanWithChanges("token", configuration: frozen).text, "Project")
        try sets.update { $0.active = nil }
        XCTAssertEqual(Cleaner.cleanWithChanges("token", configuration: sets.configuration(bundleID: "test.editor")).text, "Editor")
        XCTAssertEqual(Cleaner.cleanWithChanges("token", configuration: sets.configuration(bundleID: "other.app")).text, "Global")
        try sets.update { $0.language = "es" }
        XCTAssertEqual(Cleaner.cleanWithChanges("token", configuration: sets.configuration(bundleID: "test.editor")).text, "Global")
        XCTAssertEqual(Cleaner.cleanWithChanges("token", configuration: frozen).text, "Project", "An in-flight recording keeps its rules")
    }
    func testJSONAndCSVImportRoundTripMultilineUnicodeAndConflicts() throws {
        let entries = [PersonalizationDraft(kind: .snippet, primary: "my reply", replacement: "Hello, \"André\"\nThanks!")]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-exchange-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalizationStore(root: root)
        for csv in [false, true] {
            let data = try PersonalizationExchange.encode(entries, csv: csv)
            let text = try PersonalizationExchange.importText(data, extension: csv ? "csv" : "json", kind: .snippet)
            let preview = try store.previewImport(text, kind: .snippet)
            XCTAssertEqual(preview.entries, entries)
        }
        XCTAssertThrowsError(try PersonalizationExchange.csvRows("kind,primary,replacement\nx,\"unfinished"))
    }
    func testPreferredUnavailableMicrophoneFallsBackWithoutChangingAutomaticOrder() {
        let builtIn = AudioInputDevice(id: 1, uid: "builtin", name: "Built in", transport: kAudioDeviceTransportTypeBuiltIn, isAlive: true, inputChannels: 1)
        let usb = AudioInputDevice(id: 2, uid: "usb", name: "USB", transport: kAudioDeviceTransportTypeUSB, isAlive: true, inputChannels: 1)
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: 1, devices: [builtIn, usb], preferredUID: "usb").first, usb)
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: 1, devices: [builtIn, usb], preferredUID: "missing").first, builtIn)
        XCTAssertEqual(AudioInputRouter.orderedCandidates(defaultID: 1, devices: [builtIn, usb], lidClosed: true, preferredUID: "builtin").first, usb)
    }
    func testUndoRequiresUnchangedBoundedDocumentEvidence() {
        let original = PasteTarget.LearningSnapshot(prefix: "before", text: "dictated after", characterCount: 30, selectionLength: 0)
        XCTAssertTrue(LastInsertionController.matches(original, .init(prefix: "before", text: "dictated after", characterCount: 30, selectionLength: 8)))
        XCTAssertFalse(LastInsertionController.matches(original, .init(prefix: "before", text: "dictated after", characterCount: 31, selectionLength: 0)))
        XCTAssertFalse(LastInsertionController.matches(original, .init(prefix: "edited", text: "dictated after", characterCount: 30, selectionLength: 0)))
    }
}

@MainActor
final class RecoveryHistoryTests: XCTestCase {
    private var root: URL!
    private var oldURL: URL!
    private var oldDefaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flowclone-recovery-\(UUID())")
        oldURL = History.storeURL; oldDefaults = History.defaults
        suite = ScratchDefaults.name("recovery"); History.defaults = UserDefaults(suiteName: suite)!
        History.storeURL = root.appendingPathComponent("history.jsonl")
    }
    override func tearDown() async throws {
        History.flush(); History.storeURL = oldURL
        History.defaults.removePersistentDomain(forName: suite); History.defaults = oldDefaults
        try? FileManager.default.removeItem(at: root)
    }
    func testLegacyRecordsAndDeliveryUpdatesRoundTripWithoutDuplicating() throws {
        let legacy = Data("{\"raw\":\"before\",\"final\":\"after\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(History.Item.self, from: legacy).final, "after")
        let id = UUID()
        History.add(raw: "raw", final: "final", id: id, cleaned: "clean", delivery: .ready)
        History.updateDelivery(id: id, state: .unverified)
        History.add(raw: "raw", final: "final", id: id)
        History.reload()
        XCTAssertEqual(History.items.count, 1); XCTAssertEqual(History.items[0].delivery, .unverified)
        XCTAssertEqual(History.items[0].cleaned, "clean")
    }
    func testDraftRecoveryIsIdempotentAndOptionalPersistenceIsPrivate() throws {
        let url = root.appendingPathComponent("draft.json")
        let workspace = DictationWorkspace(defaults: History.defaults, url: url)
        XCTAssertTrue(workspace.savesDraft, "Draft persistence defaults to enabled when history saving is on")
        workspace.load(); let id = UUID()
        workspace.recover("one result", id: id, state: .unverified)
        workspace.recover("one result", id: id, state: .unverified)
        workspace.flush()
        XCTAssertEqual(workspace.draft, "one result")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        let recovered = DictationWorkspace(defaults: History.defaults, url: url); recovered.load()
        XCTAssertEqual(recovered.draft, "one result")
        workspace.savesDraft = false; workspace.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        workspace.savesDraft = true; workspace.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        History.isEnabled = false; workspace.privacyChanged(); workspace.draft = "private"; workspace.flush()
        History.isEnabled = true; workspace.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertFalse(workspace.savesDraft)
    }
    func testDerivedResultsDontInflateTimingAndAudioDefaultsOff() {
        let parent = UUID()
        History.add(raw: "hello world", final: "hello world", seconds: 2, id: parent, audio: [0, 0.1])
        History.add(raw: "hello world", final: "many more words in this rewrite", seconds: 2, parentID: parent)
        History.flush()
        XCTAssertEqual(History.wordsPerMinute(), 60)
        XCTAssertNil(History.items.last?.audioName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoryAudio.root.path))
    }
    func testHistoryOffResultsCannotBecomeDurableOnUpdate() {
        History.isEnabled = false; let id = UUID()
        History.add(raw: "private", final: "private", id: id)
        XCTAssertFalse(History.canPersistDerived(from: id))
        History.isEnabled = true; History.updateDelivery(id: id, state: .confirmed); History.reload()
        XCTAssertTrue(History.items.isEmpty)
    }
    func testAudioRetentionAndTextDeletionRemoveCompanionFiles() {
        History.defaults.set(true, forKey: "saveHistoryAudio")
        let id = UUID()
        History.add(raw: "hello", final: "hello", id: id, audio: [0, 0.1, -0.1])
        History.flush()
        let name = History.items[0].audioName!
        XCTAssertTrue(FileManager.default.fileExists(atPath: HistoryAudio.url(name)!.path))
        History.isEnabled = false; History.applyRetention(); History.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: HistoryAudio.url(name)!.path), "Turning saving off must not delete earlier audio")
        History.isEnabled = true
        History.remove(id: id); History.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoryAudio.url(name)!.path))
        XCTAssertNil(HistoryAudio.url("../outside.wav"))
    }
}
