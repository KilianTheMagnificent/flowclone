import Carbon
import CoreGraphics
import XCTest
@testable import FlowCloneCore

/// Keyboards, sound cues and language on Macs unlike the owner's.
final class KeyboardSoundAndLanguageTests: XCTestCase {
    private let control = CGEventFlags.maskControl.rawValue
    private let option = CGEventFlags.maskAlternate.rawValue

    // MARK: Shortcut labels

    /// AppKit records F5 as U+F708, Forward Delete as U+F728 and keypad Enter as U+0003:
    /// characters no font draws, so Settings showed "⌃" and an empty box.
    func testFunctionAndNavigationKeysHaveReadableLabels() {
        func title(_ code: UInt16, _ recorded: String) -> String {
            ShortcutBinding(action: .copyLast, keyCode: code, modifiers: control, keyLabel: recorded).title
        }
        XCTAssertEqual(title(96, "\u{F708}"), "⌃F5")
        XCTAssertEqual(title(122, "\u{F704}"), "⌃F1")
        XCTAssertEqual(title(90, "\u{F717}"), "⌃F20")
        XCTAssertEqual(title(117, "\u{F728}"), "⌃⌦")
        XCTAssertEqual(title(116, "\u{F72C}"), "⌃Page Up")
        XCTAssertEqual(title(76, "\u{3}"), "⌃Enter")
    }

    /// Layouts label by the character they produce, so an AZERTY "&" or a German "Ö" key
    /// keeps its own label; a dead key that recorded nothing gets its key number.
    func testLayoutCharactersAreKeptAndUnprintableOnesFallBackToTheKeyNumber() {
        XCTAssertEqual(ShortcutBinding(action: .copyLast, keyCode: 18, modifiers: control | option,
                                       keyLabel: "&").title, "⌃⌥&")
        XCTAssertEqual(ShortcutBinding(action: .copyLast, keyCode: 41, modifiers: control,
                                       keyLabel: "ö").title, "⌃Ö")
        XCTAssertEqual(ShortcutBinding(action: .copyLast, keyCode: 10, modifiers: control,
                                       keyLabel: "").title, "⌃Key 10")
        XCTAssertEqual(ShortcutBinding.defaults.map(\.title), ["fn", "⌃⌥"],
                       "The default fn and Control + Option labels are unchanged")
    }

    // MARK: Synthetic Cmd+V / Cmd+C on other layouts

    /// The paste and copy chords are posted by key code. These layouts ship with macOS, so
    /// their data is readable without enabling them. AZERTY, QWERTZ and Colemak keep V and C
    /// where QWERTY has them; Russian and Greek answer through their Command layer.
    func testPasteAndCopyKeysResolveOnShippedLayouts() throws {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
        func layout(_ id: String) -> TISInputSource? {
            sources.first {
                guard let raw = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
                return (Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String) == id
            }
        }
        var checked = 0
        for id in ["com.apple.keylayout.French", "com.apple.keylayout.German",
                   "com.apple.keylayout.Colemak", "com.apple.keylayout.Russian",
                   "com.apple.keylayout.Greek", "com.apple.keylayout.DVORAK-QWERTYCMD"] {
            guard let source = layout(id) else { continue }
            XCTAssertEqual(Paster.virtualKeyCode(for: "v", inputSource: source, fallback: 999), 9, id)
            XCTAssertEqual(Paster.virtualKeyCode(for: "c", inputSource: source, fallback: 999), 8, id)
            checked += 1
        }
        try XCTSkipIf(checked == 0, "No shipped layouts readable on this Mac")
    }

    // MARK: Secure Input

    func testSecureInputHeldByABackgroundAppIsNamed() {
        XCTAssertEqual(AXClient.secureInputBlockedMessage(ownerName: nil, ownerIsFrontmost: false),
                       AXClient.secureFieldMessage)
        XCTAssertEqual(AXClient.secureInputBlockedMessage(ownerName: "Safari", ownerIsFrontmost: true),
                       AXClient.secureFieldMessage,
                       "A password field in the app being dictated into keeps the plain message")
        let background = AXClient.secureInputBlockedMessage(ownerName: "1Password", ownerIsFrontmost: false)
        XCTAssertTrue(background.contains("1Password has Secure Input turned on"), background)
        XCTAssertTrue(background.contains("quit 1Password"), background)
    }

    // MARK: Sound cues

    func testSoundCueSettingsDefaultOnAtTheOriginalVolume() {
        let suite = ScratchDefaults.name("sound-cues")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(SoundCues.isEnabled(SoundCues.startKey, in: defaults))
        XCTAssertTrue(SoundCues.isEnabled(SoundCues.processingKey, in: defaults))
        XCTAssertEqual(SoundCues.volume(in: defaults), 0.35, accuracy: 1e-6)

        defaults.set(false, forKey: SoundCues.startKey)
        XCTAssertFalse(SoundCues.isEnabled(SoundCues.startKey, in: defaults))
        XCTAssertTrue(SoundCues.isEnabled(SoundCues.processingKey, in: defaults))

        defaults.set(0.15, forKey: SoundCues.volumeKey)
        XCTAssertEqual(SoundCues.volume(in: defaults), 0.15, accuracy: 1e-6)
        defaults.set(7.0, forKey: SoundCues.volumeKey)
        XCTAssertEqual(SoundCues.volume(in: defaults), 0.35, accuracy: 1e-6, "Out of range falls back")
        XCTAssertTrue(SoundCues.volumeChoices.contains { $0.value == SoundCues.defaultVolume },
                      "The picker offers the stored default, so it never shows blank")
    }

    // MARK: Language

    func testNonEnglishMacsAreToldTheRecognizerIsEnglishOnly() {
        XCTAssertEqual(SoundAndLanguageSettings.languageCaption(preferredLanguages: ["en-GB"]),
                       "Speech recognition understands English only.")
        let german = SoundAndLanguageSettings.languageCaption(preferredLanguages: ["de-DE", "en-US"])
        XCTAssertTrue(german.contains("whatever language your Mac uses"), german)
    }
}
