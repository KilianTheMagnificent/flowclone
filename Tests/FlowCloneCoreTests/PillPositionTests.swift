import Cocoa
import XCTest
@testable import FlowCloneCore

final class PillPositionTests: XCTestCase {
    func testDefaultPillFollowsDockRevealAndReturnsToHiddenEdge() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let visible = NSRect(x: 0, y: 0, width: 2560, height: 1410)
        for (dockTop, expectedBottom) in [(CGFloat(0), CGFloat(12)), (20, 24), (53, 57), (100, 104), (0, 12)] {
            let dock = NSRect(x: 800, y: dockTop - 100, width: 960, height: 100)
            XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: screen, visibleFrame: visible, dockFrame: dock),
                           NSPoint(x: 1280, y: expectedBottom))
        }
        XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: screen, visibleFrame: visible, dockFrame: nil).y, 12)
    }

    func testPermanentDockUsesVisibleFrameWhenGeometryIsUnavailable() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let visible = NSRect(x: 0, y: 90, width: 2560, height: 1320)
        XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: screen, visibleFrame: visible, dockFrame: nil).y, 94)
    }

    func testFloatingBottomDockStillRaisesThePill() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        for gap in [CGFloat(4), 6, 8, 10, 12] {
            let dock = NSRect(x: 800, y: gap, width: 960, height: 53)
            XCTAssertTrue(PillPosition.isBottomDock(dock, on: screen))
            XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: screen, visibleFrame: screen, dockFrame: dock).y,
                           dock.maxY + 4)
        }
    }

    func testRecordedRevealKeepsPillRaisedWhenDockSettles() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        // Live trace: Dock settles at Quartz y=1377 with height=53, leaving
        // a 10pt gap below its AXList. It is still visible at that point.
        for (top, bottom) in [(CGFloat(1440), CGFloat(12)), (1430, 14), (1381, 63),
                              (1377, 67), (1377, 67), (1410, 34), (1440, 12)] {
            let dock = Overlay.appKitRect(fromWindowBounds: NSRect(x: 755, y: top, width: 1050, height: 53),
                                          mainScreenHeight: screen.height)
            XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: screen, visibleFrame: screen, dockFrame: dock).y,
                           bottom, "Dock Quartz top \(top)")
        }
    }

    func testSideDockOtherDisplayAndFullscreenWindowDoNotRaisePill() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        for dock in [NSRect(x: 0, y: 200, width: 70, height: 900),
                     NSRect(x: 2490, y: 200, width: 70, height: 900),
                     NSRect(x: -1800, y: 0, width: 900, height: 70),
                     screen] {
            XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: screen, visibleFrame: screen, dockFrame: dock).y, 12)
        }
        let external = NSRect(x: -2000, y: -300, width: 2000, height: 1200)
        let dock = NSRect(x: -1500, y: -300, width: 1000, height: 80)
        XCTAssertEqual(PillPosition.defaultAnchor(screenFrame: external, visibleFrame: external, dockFrame: dock),
                       NSPoint(x: -1000, y: -216))
    }

    func testSavedPositionSurvivesReloadAndResetRemovesOnlyPosition() {
        let domain = ScratchDefaults.name("pill-position")
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let position = PillPosition(anchor: NSPoint(x: -700, y: 450), displayID: "external",
                                    visibleFrame: NSRect(x: -1200, y: 30, width: 1200, height: 800))
        defaults.set(false, forKey: "idlePill")
        position.save(to: defaults)
        XCTAssertEqual(PillPosition.load(from: UserDefaults(suiteName: domain)!), position)
        PillPosition.reset(in: defaults)
        XCTAssertNil(PillPosition.load(from: defaults))
        XCTAssertEqual(defaults.object(forKey: "idlePill") as? Bool, false)
        defaults.set(Data("{\"displayID\":\"external\",\"x\":3,\"y\":0}".utf8), forKey: PillPosition.preferenceKey)
        XCTAssertNil(PillPosition.load(from: defaults))
    }

    func testPositionFollowsItsDisplayWhenResolutionOrArrangementChanges() {
        let position = PillPosition(anchor: NSPoint(x: -600, y: 430), displayID: "external",
                                    visibleFrame: NSRect(x: -1200, y: 30, width: 1200, height: 800))
        XCTAssertEqual(position.anchor(in: NSRect(x: 2000, y: 100, width: 1600, height: 1000)),
                       NSPoint(x: 2800, y: 600))
    }

    @MainActor
    func testEveryThemeRetainsItsAnchorAcrossPhasesAndTranscriptGrowth() {
        let screen = NSRect(x: -1600, y: -100, width: 1600, height: 1000)
        let anchor = NSPoint(x: -800, y: 300)
        for theme in AppTheme.allCases {
            for size in [theme.idleSize, theme.activeSize, theme.processingSize,
                         NSSize(width: 340, height: 144)] {
                let frame = PillPosition.frame(size: size, anchor: anchor, visibleFrame: screen)
                XCTAssertEqual(frame.midX, anchor.x)
                XCTAssertEqual(frame.minY, anchor.y)
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }

    func testEdgesAndOffscreenAnchorsKeepTheWholeOverlayReachable() {
        let screen = NSRect(x: -1200, y: 40, width: 1200, height: 800)
        for anchor in [NSPoint(x: -4000, y: -1000), NSPoint(x: 2000, y: 2000),
                       NSPoint(x: -1200, y: 840), NSPoint(x: 0, y: 40)] {
            let frame = PillPosition.frame(size: NSSize(width: 340, height: 144),
                                           anchor: anchor, visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame), "\(anchor): \(frame)")
        }
    }

    func testTranscriptAtTopRightAppearsBelowWithoutMovingPill() {
        let screen = NSRect(x: 0, y: 30, width: 1200, height: 800)
        let pillSize = NSSize(width: 73, height: 30)
        let anchor = NSPoint(x: 1160, y: 790)
        let placement = PillPosition.placement(size: NSSize(width: 340, height: 136), pillSize: pillSize,
                                               anchor: anchor, visibleFrame: screen, gap: 8)
        XCTAssertFalse(placement.transcriptAbove)
        XCTAssertTrue(screen.contains(placement.frame))
        XCTAssertEqual(placement.frame.minX + (placement.pillCenterX ?? 0), anchor.x)
        XCTAssertEqual(placement.frame.maxY - pillSize.height, anchor.y)
    }

    func testNormalizedRoundoffDoesNotWalkThePillDownAPixel() {
        let frame = PillPosition.frame(size: NSSize(width: 56, height: 34),
                                       anchor: NSPoint(x: 1420, y: 203.99999999999997),
                                       visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1400))
        XCTAssertEqual(frame.minY, 204)
    }
}
