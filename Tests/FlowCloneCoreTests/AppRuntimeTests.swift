import Foundation
import XCTest
@testable import FlowCloneCore

final class AppRuntimeTests: XCTestCase {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("FlowClone-AppRuntimeTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        try body(directory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func testPromptDumpUsesOnlyASafeFinalComponentAndPrivatePermissions() throws {
        try withTemporaryDirectory { base in
            let cache = base.appendingPathComponent("cache", isDirectory: true)
            let fallback = cache.appendingPathComponent("prompt.json").standardizedFileURL

            for requested in ["", ".", "..", "/"] {
                let destination = try Prompter.writePromptDump(
                    "fallback \(requested.debugDescription)",
                    to: requested,
                    cacheDirectory: cache
                )
                XCTAssertEqual(destination, fallback)
            }

            let ignoredPath = base
                .appendingPathComponent("ignored/nested/chosen.json").path
            let destination = try Prompter.writePromptDump(
                "chosen",
                to: ignoredPath,
                cacheDirectory: cache
            )
            XCTAssertEqual(destination.lastPathComponent, "chosen.json")
            XCTAssertEqual(destination.deletingLastPathComponent(),
                           cache.standardizedFileURL)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "chosen")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: base.appendingPathComponent("ignored").path
            ))
            XCTAssertEqual(try permissions(of: cache), 0o700)
            XCTAssertEqual(try permissions(of: destination), 0o600)
        }
    }

    func testPromptDumpRejectsSymlinkedAndNonDirectoryCacheRoots() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let outside = base.appendingPathComponent("outside", isDirectory: true)
            try manager.createDirectory(at: outside, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o755])
            try manager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: outside.path)
            let outsidePermissions = try permissions(of: outside)
            let linkedCache = base.appendingPathComponent("linked-cache", isDirectory: true)
            try manager.createSymbolicLink(at: linkedCache, withDestinationURL: outside)

            XCTAssertThrowsError(try Prompter.writePromptDump(
                "must not escape",
                to: "prompt.json",
                cacheDirectory: linkedCache
            ))
            XCTAssertFalse(manager.fileExists(
                atPath: outside.appendingPathComponent("prompt.json").path
            ))
            XCTAssertEqual(try permissions(of: outside), outsidePermissions)

            let fileCache = base.appendingPathComponent("not-a-directory")
            try "keep me".write(to: fileCache, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try Prompter.writePromptDump(
                "must not replace",
                to: "prompt.json",
                cacheDirectory: fileCache
            ))
            XCTAssertEqual(try String(contentsOf: fileCache, encoding: .utf8), "keep me")
        }
    }

    func testPromptDumpRejectsAnExistingSymlinkDestination() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let cache = base.appendingPathComponent("cache", isDirectory: true)
            try manager.createDirectory(at: cache, withIntermediateDirectories: false)
            let outside = base.appendingPathComponent("outside.json")
            try "untouched".write(to: outside, atomically: true, encoding: .utf8)
            let destination = cache.appendingPathComponent("prompt.json")
            try manager.createSymbolicLink(at: destination, withDestinationURL: outside)

            XCTAssertThrowsError(try Prompter.writePromptDump(
                "must not follow",
                to: destination.path,
                cacheDirectory: cache
            ))
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
            XCTAssertNoThrow(try manager.destinationOfSymbolicLink(atPath: destination.path))
        }
    }

    func testRunIDSanitizerKeepsOnlyASCIILettersDigitsAndHyphens() {
        XCTAssertEqual(sanitizedRunID("run-AZaz-019"), "run-AZaz-019")
        XCTAssertEqual(sanitizedRunID("run\n../é_42!"), "run42")
        XCTAssertEqual(sanitizedRunID("🙂"), "")
    }

    func testBackendDiagnosticDetailRequiresTranscriptOptIn() {
        let hidden = diagnosticErrorSummary(type: "backend", detail: "marker detail",
                                            includeDetail: false)
        XCTAssertEqual(hidden, "backend (13 chars)")
        XCTAssertFalse(hidden.contains("marker detail"))
        XCTAssertEqual(
            diagnosticErrorSummary(type: "backend", detail: "marker detail",
                                   includeDetail: true),
            "backend: marker detail"
        )
    }

    func testSecureLogRefusesSymlinkWithoutTouchingItsTarget() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let target = base.appendingPathComponent("outside.txt")
            try "sentinel\n".write(to: target, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            let originalPermissions = try permissions(of: target)
            let log = base.appendingPathComponent("FlowClone.log")
            try manager.createSymbolicLink(at: log, withDestinationURL: target)

            XCTAssertThrowsError(try SecureLogFile.open(at: log))
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel\n")
            XCTAssertEqual(try permissions(of: target), originalPermissions)
            XCTAssertNoThrow(try manager.destinationOfSymbolicLink(atPath: log.path))
        }
    }

    func testSecureLogRefusesANonRegularPathWithoutChangingIt() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let log = base.appendingPathComponent("FlowClone.log", isDirectory: true)
            try manager.createDirectory(at: log, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o750])
            try manager.setAttributes([.posixPermissions: 0o750], ofItemAtPath: log.path)

            XCTAssertThrowsError(try SecureLogFile.open(at: log))
            var isDirectory: ObjCBool = false
            XCTAssertTrue(manager.fileExists(atPath: log.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(try permissions(of: log), 0o750)
        }
    }

    func testSecureLogAppendsAndEnforcesPrivatePermissions() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let log = base.appendingPathComponent("FlowClone.log")
            try "before\n".write(to: log, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)

            let handle = try SecureLogFile.open(at: log)
            try handle.write(contentsOf: Data("after\n".utf8))
            try handle.synchronize()
            try handle.close()

            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "before\nafter\n")
            XCTAssertEqual(try permissions(of: log), 0o600)
        }
    }

    func testSecureLogRotationKeepsBothFilesPrivate() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let log = base.appendingPathComponent("FlowClone.log")
            let rotated = log.appendingPathExtension("1")
            try "active-marker\n".write(to: log, atomically: true, encoding: .utf8)
            try "old-marker\n".write(to: rotated, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rotated.path)

            var handle: FileHandle? = try SecureLogFile.open(at: log)
            defer { try? handle?.close() }
            try SecureLogFile.rotateIfNeeded(at: log, maximumSize: 4, handle: &handle)
            try handle?.write(contentsOf: Data("new-marker\n".utf8))
            try handle?.synchronize()

            XCTAssertEqual(try String(contentsOf: rotated, encoding: .utf8), "active-marker\n")
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "new-marker\n")
            XCTAssertEqual(try permissions(of: rotated), 0o600)
            XCTAssertEqual(try permissions(of: log), 0o600)
        }
    }

    func testSecureLogRotationRefusesASymlinkedDestination() throws {
        try withTemporaryDirectory { base in
            let manager = FileManager.default
            let log = base.appendingPathComponent("FlowClone.log")
            try "active-marker\n".write(to: log, atomically: true, encoding: .utf8)
            let target = base.appendingPathComponent("outside.txt")
            try "sentinel\n".write(to: target, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            let originalPermissions = try permissions(of: target)
            let rotated = log.appendingPathExtension("1")
            try manager.createSymbolicLink(at: rotated, withDestinationURL: target)

            var handle: FileHandle? = try SecureLogFile.open(at: log)
            defer { try? handle?.close() }
            XCTAssertThrowsError(try SecureLogFile.rotateIfNeeded(
                at: log, maximumSize: 4, handle: &handle
            ))

            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "active-marker\n")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel\n")
            XCTAssertEqual(try permissions(of: target), originalPermissions)
            XCTAssertNoThrow(try manager.destinationOfSymbolicLink(atPath: rotated.path))
        }
    }
}

final class TestLogLocationTests: XCTestCase {
    func testUnitTestsNeverWriteTheOwnersLog() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let temporary = URL(fileURLWithPath: "/private/tmp/scratch")
        XCTAssertEqual(logFileURL(home: home, temporary: temporary, underTest: false).path,
                       "/Users/someone/Library/Logs/FlowClone.log")
        XCTAssertEqual(logFileURL(home: home, temporary: temporary, underTest: true).path,
                       "/private/tmp/scratch/FlowClone-tests.log")
        XCTAssertFalse(logURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Library/Logs").path),
                       "this test process resolved the real log")
    }
}
