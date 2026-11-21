import XCTest
@testable import FlowCloneCore

final class TransformPresetsTests: XCTestCase {
    func testSaveTrimsBlanksAndRoundTrips() throws {
        let name = ScratchDefaults.name("transform-presets")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(TransformPresets.load(defaults), [])
        TransformPresets.save(["  Make this concise ", "", "Translate to Spanish"], defaults)
        XCTAssertEqual(TransformPresets.load(defaults), ["Make this concise", "Translate to Spanish"])
    }
}

extension TransformPresetsTests {
    func testLegacyMigrationAndRollbackEditsRetainInstructions() throws {
        let name = ScratchDefaults.name("transform-presets")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["Make this concise", "Keep dates\nand names"], forKey: TransformPresets.key)
        let migrated = TransformPresets.loadNamed(defaults)
        XCTAssertEqual(migrated.map(\.instruction), ["Make this concise", "Keep dates\nand names"])
        var named = migrated
        named[0].name = "Short email"
        TransformPresets.saveNamed(named, defaults)
        XCTAssertEqual(TransformPresets.loadNamed(defaults), named)
        XCTAssertEqual(TransformPresets.load(defaults), named.map(\.instruction))
        defaults.set(["Changed from an older build"], forKey: TransformPresets.key)
        XCTAssertEqual(TransformPresets.loadNamed(defaults).map(\.instruction), ["Changed from an older build"])
    }
    func testDuplicateNamesRetainDistinctInstructionsAndIdentity() throws {
        let name = ScratchDefaults.name("transform-presets")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let presets = [TransformPreset(name: "Email", instruction: "Short"), TransformPreset(name: "Email", instruction: "Friendly")]
        TransformPresets.saveNamed(presets, defaults)
        XCTAssertEqual(TransformPresets.loadNamed(defaults), presets)
    }

    func testActivePresetSelectionPersistsAndClearsWhenDeleted() throws {
        let name = ScratchDefaults.name("transform-active-preset")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertNil(TransformPresets.activePreset(defaults))
        XCTAssertEqual(TransformPresets.activeKind(defaults), .polish)

        let first = TransformPreset(name: "Concise", instruction: "Make this concise.")
        let second = TransformPreset(name: "Bullet points", instruction: "Rewrite as bullets.")
        TransformPresets.saveNamed([first, second], defaults)

        TransformPresets.setActivePresetID(second.id, defaults)
        XCTAssertEqual(TransformPresets.activePreset(defaults), second)
        XCTAssertEqual(TransformPresets.activeKind(defaults), .custom)

        // Deleting the active preset resets activePresetID cleanly back to Polish.
        TransformPresets.saveNamed([first], defaults)
        XCTAssertNil(TransformPresets.activePreset(defaults))
        XCTAssertEqual(TransformPresets.activeKind(defaults), .polish)
    }
}
