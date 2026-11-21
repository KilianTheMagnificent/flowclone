import Cocoa
import XCTest
@testable import FlowCloneCore

/// Real pasteboard-server tests on disposable named boards. No general clipboard, AX,
/// keyboard events, windows, or owner application state are used.
final class PasteboardHandoffTests: XCTestCase {
    private final class Promise: NSObject, NSPasteboardItemDataProvider {
        let text: String
        var requests = 0

        init(_ text: String) { self.text = text }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requests += 1
            item.setString(text, forType: type)
        }
    }

    private let text = "Synthetic dictation for an isolated paste test."
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private func seed(_ pb: NSPasteboard, text: String, nonce: Data) throws -> Promise {
        let provider = Promise(text)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(item.setData(nonce, forType: Paster.marker))
        XCTAssertTrue(item.setData(Data([1]), forType: transient))
        XCTAssertTrue(item.setData(Data([1]), forType: concealed))
        pb.clearContents()
        // Fail rather than skip if the pasteboard server is unavailable: this gate must
        // actually exercise native reads, not silently pass inside a restrictive sandbox.
        _ = try XCTUnwrap(pb.writeObjects([item]) ? item : nil,
                         "named pasteboard server is unavailable")
        return provider
    }

    func testPendingPasteSurvivesMaterializationWithoutNewGeneration() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let nonce = Data(UUID().uuidString.utf8)
        let provider = try seed(pb, text: text, nonce: nonce)
        let generation = pb.changeCount
        let pendingReader = try XCTUnwrap(pb.pasteboardItems?.first)
        XCTAssertEqual(provider.requests, 0)

        XCTAssertEqual(Paster.keepTranscript(text, on: pb, nonce: nonce,
                                             changeCount: generation), .transcriptOnClipboard)

        XCTAssertEqual(pb.changeCount, generation,
                       "a browser paste rejects text when the clipboard generation changes")
        XCTAssertEqual(pendingReader.string(forType: .string), text,
                       "a reader captured before cleanup must still retrieve the dictation")
        XCTAssertEqual(pb.string(forType: .string), text)
        XCTAssertEqual(pb.data(forType: Paster.marker), nonce)
        XCTAssertEqual(pb.data(forType: transient), Data([1]))
        XCTAssertEqual(pb.data(forType: concealed), Data([1]))
        XCTAssertEqual(provider.requests, 1, "subsequent readers use concrete cached data")
    }

    func testConsumedTextStaysAvailableToAnInFlightReader() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let nonce = Data(UUID().uuidString.utf8)
        let provider = try seed(pb, text: text, nonce: nonce)
        let generation = pb.changeCount
        let pendingReader = try XCTUnwrap(pb.pasteboardItems?.first)
        XCTAssertEqual(pb.string(forType: .string), text) // weak consumption acknowledgement

        for _ in 0..<2 {
            XCTAssertEqual(Paster.keepTranscript(text, on: pb, nonce: nonce,
                                                 changeCount: generation), .transcriptOnClipboard)
            XCTAssertEqual(pb.changeCount, generation)
            XCTAssertEqual(pendingReader.string(forType: .string), text)
        }
        XCTAssertEqual(provider.requests, 1)
    }

    func testNewCopyWinsEvenWhenItContainsTheSameText() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let nonce = Data(UUID().uuidString.utf8)
        let provider = try seed(pb, text: text, nonce: nonce)
        let generation = pb.changeCount
        pb.clearContents()
        XCTAssertTrue(pb.setString(text, forType: .string))
        let copiedGeneration = pb.changeCount

        XCTAssertEqual(Paster.keepTranscript(text, on: pb, nonce: nonce,
                                             changeCount: generation), .historyOnly)
        XCTAssertEqual(pb.changeCount, copiedGeneration)
        XCTAssertEqual(pb.string(forType: .string), text)
        XCTAssertNil(pb.data(forType: Paster.marker))
        XCTAssertEqual(provider.requests, 0, "do not read a superseded promise")
    }

    func testMarkerMismatchDoesNotReadOrReplaceTheClipboard() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let nonce = Data(UUID().uuidString.utf8)
        let provider = try seed(pb, text: text, nonce: nonce)
        let generation = pb.changeCount

        XCTAssertEqual(Paster.keepTranscript(text, on: pb, nonce: Data("wrong".utf8),
                                             changeCount: generation), .historyOnly)
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.data(forType: Paster.marker), nonce)
        XCTAssertEqual(provider.requests, 0)
    }

    func testUnexpectedPayloadDoesNotClaimOrOverwriteRecoveryText() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let nonce = Data(UUID().uuidString.utf8)
        let provider = try seed(pb, text: "Different text", nonce: nonce)
        let generation = pb.changeCount

        XCTAssertEqual(Paster.keepTranscript(text, on: pb, nonce: nonce,
                                             changeCount: generation), .historyOnly)
        XCTAssertEqual(pb.changeCount, generation)
        XCTAssertEqual(pb.string(forType: .string), "Different text")
        XCTAssertEqual(provider.requests, 1)
    }

    func testExplicitCopyOmitsConcealedAndTransientMarkersWhileInternalTransportMarksThem() throws {
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        XCTAssertTrue(Paster.writeTranscript("Explicit user copy", to: pb))
        XCTAssertEqual(pb.string(forType: .string), "Explicit user copy")
        XCTAssertNil(pb.data(forType: transient), "Explicit Copy must not be marked transient")
        XCTAssertNil(pb.data(forType: concealed), "Explicit Copy must not be marked concealed")

        XCTAssertTrue(Paster.writeTranscript("Internal transport", to: pb, transient: true))
        XCTAssertEqual(pb.data(forType: transient), Data([1]))
        XCTAssertEqual(pb.data(forType: concealed), Data([1]))
    }
}
