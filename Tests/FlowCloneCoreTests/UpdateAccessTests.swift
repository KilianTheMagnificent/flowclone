import Foundation
import XCTest
@testable import FlowCloneCore

final class UpdateAccessTests: XCTestCase {
    func testLegacyAccessIsMigratedOnlyAfterSignatureVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = root.appendingPathComponent("FlowClone.app.old")
        let contents = previous.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: NSDictionary = ["FlowCloneUpdateToken": "non-secret-test-fixture"]
        XCTAssertTrue(plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        var verified = false
        var saved = false
        XCTAssertTrue(UpdateAccess.migrate(previous: previous, verify: { _ in verified = true }, store: {
            XCTAssertTrue(verified)
            XCTAssertEqual($0, "non-secret-test-fixture")
            saved = true
            return true
        }))
        XCTAssertTrue(saved)
        saved = false
        XCTAssertFalse(UpdateAccess.migrate(previous: previous, verify: { _ in
            throw Updater.UpdateError("untrusted fixture")
        }, store: { _ in saved = true; return true }))
        XCTAssertFalse(saved)
        XCTAssertFalse(UpdateAccess.migrate(previous: previous, verify: { _ in }, store: { _ in false }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path), "failure retains the only recovery source")
    }

    func testMissingPredecessorDoesNotAccessKeychain() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(UpdateAccess.migrate(previous: missing, verify: { _ in XCTFail() }, store: { _ in XCTFail(); return false }))
    }
}
