import Foundation
import XCTest

final class ScratchDefaultsTests: XCTestCase {
    func testSuitesLiveInTheTempDirectoryAndStillRoundTrip() throws {
        let name = ScratchDefaults.name("contract")
        XCTAssertTrue(name.hasPrefix(FileManager.default.temporaryDirectory.path), "\(name) must not be a bare domain")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("kept", forKey: "probe")
        XCTAssertEqual(try XCTUnwrap(UserDefaults(suiteName: name)).string(forKey: "probe"), "kept")
    }

    /// A named suite leaves an empty plist in ~/Library/Preferences that nothing can remove in time
    /// (see ScratchDefaults), so a test file that builds a suite must take its name from there.
    func testEveryTestFileThatBuildsASuiteNamesItThroughScratchDefaults() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !$0.lastPathComponent.hasPrefix("ScratchDefaults") }
        XCTAssertFalse(sources.isEmpty)
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("UserDefaults(suiteName:") else { continue }
            XCTAssertTrue(text.contains("ScratchDefaults.name("),
                          "\(file.lastPathComponent) builds a UserDefaults suite without ScratchDefaults.name(…)")
            XCTAssertNil(text.range(of: #"UserDefaults\(suiteName:\s*""#, options: .regularExpression),
                         "\(file.lastPathComponent) passes a string literal to UserDefaults(suiteName:)")
        }
    }
}
