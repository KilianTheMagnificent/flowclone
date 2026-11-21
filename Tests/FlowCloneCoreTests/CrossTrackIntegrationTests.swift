import AVFoundation
import Cocoa
import Foundation
import XCTest
@testable import FlowCloneCore

final class CrossTrackIntegrationTests: XCTestCase {
    private var root: URL!
    private var store: PersonalizationStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-cross-track-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = PersonalizationStore(root: root)
    }

    override func tearDownWithError() throws {
        LocalMeetingTranscriber.setExternalTranscriber(nil)
        if let root { try? FileManager.default.removeItem(at: root) }
        store = nil
        root = nil
    }

    func testSeamAMeetingTranscriberSharesSpeechRuntimeWithoutDuplicateModelInstance() async throws {
        let transcriber = LocalMeetingTranscriber()
        let childTypeNames = Mirror(reflecting: transcriber).children.map {
            String(describing: type(of: $0.value))
        }
        XCTAssertFalse(
            childTypeNames.contains(where: { $0.contains("Transcriber") }),
            "LocalMeetingTranscriber must delegate to SpeechRuntime.shared rather than owning a second Transcriber"
        )

        let sampleCount = 16_000 * 45
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            // Leave a quiet valley around 19.5s so silence-snapped windowing is deterministic.
            let second = Double(i) / 16_000.0
            if (19.2...19.8).contains(second) { continue }
            samples[i] = 0.12 * sin(Float(i) * 0.11)
        }

        let runtimeWindows = SpeechRuntime.partitionAudioWindows(samples, sampleRate: 16_000)
        let importerSlices = MeetingAudioImporter.sliceRanges(for: samples)
        XCTAssertEqual(importerSlices.count, runtimeWindows.count)
        for (slice, window) in zip(importerSlices, runtimeWindows) {
            XCTAssertEqual(slice.startSample, window.lowerBound)
            XCTAssertEqual(slice.length, window.count)
        }

        let wavURL = root.appendingPathComponent("sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf in
            pcm.floatChannelData?[0].update(from: buf.baseAddress!, count: samples.count)
        }
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: format.settings)
            try file.write(from: pcm)
        }

        LocalMeetingTranscriber.setExternalTranscriber(
            MeetingExternalTranscriber(transcribeSamples: { window in
                "chunk-\(window.count)"
            })
        )
        let progressBox = LockedProgressBox()
        let chunks = try await transcriber.transcribeAudioFile(at: wavURL) { fraction in
            progressBox.append(fraction)
        }
        XCTAssertEqual(chunks.count, runtimeWindows.count)
        XCTAssertEqual(progressBox.values.last ?? 0, 1.0, accuracy: 0.001)
    }

    func testSeamBAppProfilesCleanerSlashCommandsAndSingleSentencePeriodEndToEnd() throws {
        let profiles = AppProfiles(root: root)
        try profiles.update { doc in
            doc.profiles = [
                AppProfile(
                    bundleID: "com.tinyspeck.slackmacgap",
                    preferredMode: .prompt,
                    stripSingleSentencePeriod: true
                )
            ]
        }

        let slackProfile = profiles.resolve(bundleID: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(slackProfile.effectiveMode(default: .clean), .prompt)
        XCTAssertTrue(slackProfile.stripSingleSentencePeriod)

        let singleFormatted = InsertionFormatter.format(
            "Sounds good to me.",
            context: InsertionContext(before: "", after: ""),
            mode: .clean,
            preserveTerminalPeriod: false,
            stripSingleSentencePeriod: slackProfile.stripSingleSentencePeriod
        )
        XCTAssertEqual(singleFormatted, "Sounds good to me")

        let multiFormatted = InsertionFormatter.format(
            "Sounds good. Let's ship Tuesday.",
            context: InsertionContext(before: "", after: ""),
            mode: .clean,
            preserveTerminalPeriod: false,
            stripSingleSentencePeriod: slackProfile.stripSingleSentencePeriod
        )
        XCTAssertEqual(multiFormatted, "Sounds good. Let's ship Tuesday.")

        let explicitPeriodFormatted = InsertionFormatter.format(
            "Sounds good.",
            context: InsertionContext(before: "", after: ""),
            mode: .clean,
            preserveTerminalPeriod: true,
            stripSingleSentencePeriod: slackProfile.stripSingleSentencePeriod
        )
        XCTAssertEqual(explicitPeriodFormatted, "Sounds good.")

        Cleaner.withPersonalizationStore(store) {
            let cursorStaged = Cleaner.stage(
                "snake case user id",
                configuration: nil,
                bundleID: "com.todesktop.230313mzl4w4u92"
            )
            XCTAssertEqual(cursorStaged.finish().text, "user_id")

            let cursorSlash = Cleaner.stage(
                "slash compact",
                configuration: nil,
                bundleID: "com.todesktop.230313mzl4w4u92"
            )
            XCTAssertEqual(cursorSlash.finish().text, "/compact")

            let mailProse = Cleaner.stage(
                "Slash status.",
                configuration: nil,
                bundleID: "com.apple.mail"
            )
            XCTAssertEqual(mailProse.finish().text, "Slash status.")
        }
    }

    @MainActor
    func testSeamCOverlayMouseClickDoesNotAdvanceFocusInteractionEpoch() throws {
        _ = Overlay.shared.panelIsNonActivating
        let overlayWindow = Overlay.currentWindowNumber
        XCTAssertGreaterThan(overlayWindow, 0)

        let monitor = HotkeyMonitor(queue: DispatchQueue(label: "test.cross-track.overlay-click"))
        guard let source = CGEventSource(stateID: .privateState),
              let overlayClick = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: .zero,
                  mouseButton: .left
              ),
              let externalClick = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: .zero,
                  mouseButton: .left
              ) else {
            XCTFail("Could not construct synthetic CGEvent mouse clicks")
            return
        }

        overlayClick.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: overlayWindow)
        let beforeOverlayClick = FocusInteractionEpoch.snapshot()
        XCTAssertFalse(monitor.handleTapEvent(type: .leftMouseDown, event: overlayClick))
        XCTAssertEqual(
            FocusInteractionEpoch.snapshot(),
            beforeOverlayClick,
            "Clicking FlowClone's non-activating Pill HUD must not fence target focus leases"
        )

        externalClick.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: overlayWindow + 99_999)
        let beforeExternalClick = FocusInteractionEpoch.snapshot()
        XCTAssertFalse(monitor.handleTapEvent(type: .leftMouseDown, event: externalClick))
        XCTAssertEqual(FocusInteractionEpoch.snapshot(), beforeExternalClick &+ 1)
    }

    @MainActor
    func testSeamDShortcutSettingsAndTransformSelectionRouting() throws {
        let suite = ScratchDefaults.name("cross-track-shortcuts")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcutStore = ShortcutStore(defaults: defaults)

        // Default Push-to-Talk has 2 slots; saving a 3rd via ShortcutSettings replaces slot 2 cleanly.
        let rightOptionDictate = ShortcutBinding(
            action: .dictate,
            keyCode: ShortcutBinding.rightOptionKeyCode,
            modifiers: CGEventFlags.maskAlternate.rawValue,
            keyLabel: "Right ⌥"
        )
        try ShortcutSettings.saveBinding(rightOptionDictate, in: shortcutStore)
        let dictateBindings = shortcutStore.bindings.filter { $0.action == .dictate }
        XCTAssertEqual(dictateBindings.count, 2)
        XCTAssertEqual(dictateBindings[1].keyCode, ShortcutBinding.rightOptionKeyCode)
        XCTAssertEqual(dictateBindings[1].title, "Right ⌥")

        // Persist ShortcutAction.transformSelection and dispatch through HotkeyMonitor.
        let transformBinding = ShortcutBinding(
            shortcutAction: .transformSelection,
            keyCode: 17, // ANSI T
            modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue,
            keyLabel: "t"
        )
        try ShortcutSettings.saveBinding(transformBinding, in: shortcutStore)
        XCTAssertEqual(shortcutStore.label(.transformSelection), "⌃⌥T")

        let monitor = HotkeyMonitor(queue: DispatchQueue(label: "test.cross-track.shortcuts"))
        var triggered: [ShortcutAction] = []
        monitor.onShortcutAction = { (action: ShortcutAction, _: Paster.TargetLease?) in
            triggered.append(action)
        }

        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 17, keyDown: true) else {
            XCTFail("Could not construct synthetic keyDown CGEvent")
            return
        }
        keyDown.flags = [.maskControl, .maskAlternate]
        XCTAssertTrue(monitor.handleTapEvent(type: .keyDown, event: keyDown, bindings: shortcutStore.bindings))
        XCTAssertEqual(triggered, [.transformSelection])
    }
}

private final class LockedProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
