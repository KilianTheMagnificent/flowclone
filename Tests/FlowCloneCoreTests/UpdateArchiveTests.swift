import Foundation
import XCTest
@testable import FlowCloneCore

final class UpdateArchiveTests: XCTestCase {
    private struct Item {
        var name: String
        var contents = Data()
        var deflated = false
        /// What the headers say the entry expands to; nil means the truth.
        var declared: Int?
        var mode: UInt32 = 0o100644
        var descriptor = false
        /// Present in the file but missing from the directory.
        var hidden = false
        /// Bytes after the compressed data that the entry still counts as its own.
        var padding = Data()
    }

    private func field(_ value: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// A ZIP built by hand: no subprocess, network, signing, or user files.
    private func archive(_ items: [Item], gapBeforeDirectory: Data = Data()) throws -> Data {
        var file = Data()
        var central = Data()
        var listed = 0
        for item in items {
            let name = Data(item.name.utf8)
            let body = (item.deflated ? try (item.contents as NSData).compressed(using: .zlib) as Data
                                      : item.contents) + item.padding
            let declared = item.declared ?? item.contents.count
            let flags = item.descriptor ? 8 : 0
            let method = item.deflated ? 8 : 0
            let offset = file.count
            file += field(0x04034b50, bytes: 4) + field(20, bytes: 2) + field(flags, bytes: 2)
            file += field(method, bytes: 2) + Data(repeating: 0, count: 8)
            file += field(item.descriptor ? 0 : body.count, bytes: 4) + field(item.descriptor ? 0 : declared, bytes: 4)
            file += field(name.count, bytes: 2) + field(0, bytes: 2) + name + body
            if item.descriptor {
                file += field(0x08074b50, bytes: 4) + field(0, bytes: 4)
                file += field(body.count, bytes: 4) + field(declared, bytes: 4)
            }
            guard !item.hidden else { continue }
            listed += 1
            central += field(0x02014b50, bytes: 4) + field(0x0314, bytes: 2) + field(20, bytes: 2)
            central += field(flags, bytes: 2) + field(method, bytes: 2) + Data(repeating: 0, count: 8)
            central += field(body.count, bytes: 4) + field(declared, bytes: 4)
            central += field(name.count, bytes: 2) + Data(repeating: 0, count: 8)
            central += field(Int(item.mode) << 16, bytes: 4) + field(offset, bytes: 4) + name
        }
        file += gapBeforeDirectory
        var end = field(0x06054b50, bytes: 4) + Data(repeating: 0, count: 4)
        end += field(listed, bytes: 2) + field(listed, bytes: 2)
        end += field(central.count, bytes: 4) + field(file.count, bytes: 4) + field(0, bytes: 2)
        return file + central + end
    }

    private func isAccepted(_ data: Data) throws -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return (try? UpdateArchive.validate(url)) != nil
    }

    private let megabyte = Data(repeating: 0, count: 1_024 * 1_024)

    func testArchiveRejectsTraversalLinksOversizeAndTruncation() throws {
        XCTAssertTrue(try isAccepted(archive([Item(name: "FlowClone.app/Contents/example")])))
        let bad = try [archive([Item(name: "../escape")]), archive([Item(name: "/tmp/escape")]),
                       archive([Item(name: "a\\..\\escape")]), archive([Item(name: "link", mode: 0o120777)]),
                       Data(archive([Item(name: "short")]).dropLast())]
        for data in bad {
            XCTAssertFalse(try isAccepted(data))
        }
    }

    func testArchiveAcceptsStoredAndCompressedFilesWithOrWithoutADescriptor() throws {
        let text = Data("hello".utf8)
        XCTAssertTrue(try isAccepted(archive([
            Item(name: "FlowClone.app/"),
            Item(name: "FlowClone.app/stored", contents: text),
            Item(name: "FlowClone.app/packed", contents: megabyte, deflated: true),
            Item(name: "FlowClone.app/streamed", contents: megabyte, deflated: true, descriptor: true),
        ])))
    }

    func testArchiveThatExpandsToMoreThanItDeclaresIsRejected() throws {
        // 1 MB of zeros packs to about 1 KB; the headers claim 10 bytes.
        for descriptor in [false, true] {
            XCTAssertFalse(try isAccepted(archive([
                Item(name: "FlowClone.app/big", contents: megabyte, deflated: true, declared: 10, descriptor: descriptor),
            ])), "descriptor: \(descriptor)")
        }
        XCTAssertFalse(try isAccepted(archive([Item(name: "FlowClone.app/stored", contents: megabyte, declared: 10)])))
    }

    func testArchiveWhoseDeclaredTotalPassesTheLimitIsRejected() throws {
        XCTAssertFalse(try isAccepted(archive([
            Item(name: "large", contents: megabyte, deflated: true, declared: UpdateArchive.maximumExpandedBytes + 1),
        ])))
    }

    func testEntryMissingFromTheDirectoryIsRejectedWhereverItHides() throws {
        let listed = Item(name: "FlowClone.app/listed", contents: Data("ok".utf8))
        let hidden = Item(name: "FlowClone.app/hidden", contents: megabyte, deflated: true, hidden: true)
        XCTAssertFalse(try isAccepted(archive([hidden, listed])), "before the listed entries")
        XCTAssertFalse(try isAccepted(archive([listed, hidden])), "between the entries and the directory")
        XCTAssertFalse(try isAccepted(archive([listed], gapBeforeDirectory: Data(repeating: 7, count: 64))))
    }

    func testCompressedEntryMustEndExactlyWhereItsDataEnds() throws {
        XCTAssertFalse(try isAccepted(archive([
            Item(name: "FlowClone.app/padded", contents: megabyte, deflated: true, padding: Data(repeating: 0, count: 32)),
        ])))
        var cut = Item(name: "FlowClone.app/cut", deflated: true, declared: megabyte.count)
        cut.padding = Data(try (megabyte as NSData).compressed(using: .zlib).prefix(200))
        XCTAssertFalse(try isAccepted(archive([cut])))
    }

    /// The archives `build.sh` publishes come from ditto; the stricter layout rule must keep accepting them.
    func testArchiveWrittenByDittoIsAccepted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flowclone-archive-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("FlowClone-0.0/FlowClone.app/Contents/MacOS")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try megabyte.write(to: app.appendingPathComponent("FlowClone"))
        try Data("small".utf8).write(to: app.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        try Data().write(to: app.appendingPathComponent("empty"))
        let zip = root.appendingPathComponent("out.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("FlowClone-0.0").path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)
        XCTAssertNoThrow(try UpdateArchive.validate(zip))
    }
}
