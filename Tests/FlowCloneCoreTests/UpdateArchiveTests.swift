import Foundation
import XCTest
@testable import FlowCloneCore

final class UpdateArchiveTests: XCTestCase {
    /// Small stored ZIP fixture: no subprocess, network, signing, or user files.
    private func archive(name: String, expanded: UInt32 = 0, mode: UInt32 = 0o100644) -> Data {
        func field(_ value: UInt32, bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        let name = Data(name.utf8)
        let n = UInt32(name.count)
        var local = field(0x04034b50, bytes: 4)
        local += field(20, bytes: 2) + Data(repeating: 0, count: 12)
        local += field(0, bytes: 4) + field(expanded, bytes: 4)
        local += field(n, bytes: 2) + field(0, bytes: 2) + name
        var central = field(0x02014b50, bytes: 4)
        central += field(0x0314, bytes: 2) + field(20, bytes: 2) + Data(repeating: 0, count: 12)
        central += field(0, bytes: 4) + field(expanded, bytes: 4)
        central += field(n, bytes: 2) + Data(repeating: 0, count: 8)
        central += field(mode << 16, bytes: 4) + field(0, bytes: 4) + name
        var end = field(0x06054b50, bytes: 4) + Data(repeating: 0, count: 4)
        end += field(1, bytes: 2) + field(1, bytes: 2)
        end += field(UInt32(central.count), bytes: 4) + field(UInt32(local.count), bytes: 4)
        end += field(0, bytes: 2)
        return local + central + end
    }

    func testArchiveRejectsTraversalLinksOversizeAndTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try archive(name: "FlowClone.app/Contents/example").write(to: url)
        XCTAssertNoThrow(try UpdateArchive.validate(url))
        let bad = [archive(name: "../escape"), archive(name: "/tmp/escape"),
                   archive(name: "a\\..\\escape"), archive(name: "link", mode: 0o120777),
                   archive(name: "large", expanded: UInt32(UpdateArchive.maximumExpandedBytes + 1)),
                   Data(archive(name: "short").dropLast())]
        for data in bad {
            try data.write(to: url)
            XCTAssertThrowsError(try UpdateArchive.validate(url))
        }
    }
}
