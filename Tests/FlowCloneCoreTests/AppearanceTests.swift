import XCTest
import Cocoa
@testable import FlowCloneCore

final class AppearanceTests: XCTestCase {
    @MainActor
    func testSelectionPersistsAndUnknownValuesPreserveClassicFallback() {
        let domain = ScratchDefaults.name("appearance")
        let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        defaults.set("removed-or-future-theme",forKey:AppearanceStore.preferenceKey)
        XCTAssertEqual(AppearanceStore(defaults:defaults).theme,.classic)
        let store=AppearanceStore(defaults:defaults)
        store.select(.softSeal)
        XCTAssertEqual(AppearanceStore(defaults:defaults).theme,.softSeal)
        store.select(.anthropic)
        XCTAssertEqual(AppearanceStore(defaults:defaults).theme,.anthropic)
        store.select(.interface)
        XCTAssertEqual(AppearanceStore(defaults:defaults).theme,.interface)
        XCTAssertEqual(defaults.string(forKey:AppearanceStore.preferenceKey),"interface")
        store.select(.settle)
        XCTAssertEqual(AppearanceStore(defaults:defaults).theme,.settle)
        XCTAssertEqual(defaults.string(forKey:AppearanceStore.preferenceKey),"settle")
    }

    private func luminance(_ rgb:UInt32)->Double {
        let channels=[(rgb>>16)&255,(rgb>>8)&255,rgb&255].map { Double($0)/255 }
        let values=channels.map { $0 <= 0.04045 ? $0/12.92 : pow(($0+0.055)/1.055,2.4) }
        return values[0]*0.2126+values[1]*0.7152+values[2]*0.0722
    }
    private func contrast(_ a:UInt32,_ b:UInt32)->Double { let x=luminance(a),y=luminance(b);return (max(x,y)+0.05)/(min(x,y)+0.05) }

    func testInterfaceAccentReadsAsTextAndItsWaveStandsOutOnThePill() {
        let theme=AppTheme.interface
        for (palette,surface) in [(theme.light,InterfaceColors.surface.light),(theme.dark,InterfaceColors.surface.dark)] {
            // The accent also paints text (the mode switch focus, links, empty-state glyphs).
            for ground in [palette.card,palette.sidebar,surface] {
                XCTAssertGreaterThanOrEqual(contrast(palette.accent,ground),4.5)
            }
        }
        XCTAssertGreaterThanOrEqual(contrast(InterfaceColors.wave.light,InterfaceColors.surface.light),3)
        XCTAssertGreaterThanOrEqual(contrast(InterfaceColors.wave.dark,InterfaceColors.surface.dark),3)
        XCTAssertGreaterThanOrEqual(contrast(InterfaceColors.brandInk.light,InterfaceColors.brand.light),4.5)
        XCTAssertGreaterThanOrEqual(contrast(InterfaceColors.brandInk.dark,InterfaceColors.brand.dark),4.5)
    }

    /// Settle's pill is the app icon: assets/AppIcon.icon fills white/#17171A and inverts in dark.
    func testSettlePillIsTheIconInBothAppearances() {
        XCTAssertEqual(SettleColors.surface.light,0xFFFFFF)
        XCTAssertEqual(SettleColors.surface.dark,0x17171A)
        XCTAssertEqual(SettleColors.line.light,0x17171A)
        XCTAssertGreaterThanOrEqual(contrast(SettleColors.line.light,SettleColors.surface.light),7)
        XCTAssertGreaterThanOrEqual(contrast(SettleColors.line.dark,SettleColors.surface.dark),7)
        XCTAssertEqual(AppTheme.settle.light.ink,SettleColors.line.light)
        XCTAssertEqual(AppTheme.settle.dark.panel,SettleColors.surface.dark)
    }

    /// Classic (Folio) sets display type and dictated words in Iowan Old Style, which ships with
    /// macOS; its search pill's page-tinted fill keeps the placeholder and typed text legible.
    func testClassicBookSerifIsInstalledAndItsSearchFillKeepsTextLegible() {
        for name in ["IowanOldStyle-Roman", "IowanOldStyle-Italic", "IowanOldStyle-Bold"] {
            XCTAssertNotNil(NSFont(name: name, size: 13), "\(name) ships with macOS")
        }
        for (palette, wash) in [(AppTheme.classic.light, FolioColors.wash.light), (AppTheme.classic.dark, FolioColors.wash.dark)] {
            XCTAssertGreaterThanOrEqual(contrast(palette.muted, wash), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(palette.ink, wash), 7)
        }
        XCTAssertEqual(AppTheme.allCases.filter(\.bookSerif), [.classic])
        XCTAssertEqual(AppTheme.allCases.filter(\.pageBleeds), [.classic])
    }

    func testAllPalettesKeepReadingTextLegibleInBothAppearances() {
        for theme in AppTheme.allCases {
            for palette in [theme.light,theme.dark] {
                for surface in [palette.window,palette.sidebar,palette.panel,palette.card] {
                    XCTAssertGreaterThanOrEqual(contrast(palette.ink,surface),7,"\(theme) primary text")
                    XCTAssertGreaterThanOrEqual(contrast(palette.muted,surface),4.5,"\(theme) supporting text")
                    XCTAssertGreaterThanOrEqual(contrast(palette.accentText,surface),4.5,"\(theme) accent-coloured text")
                    XCTAssertGreaterThanOrEqual(contrast(palette.success,surface),4.5,"\(theme) success text")
                    XCTAssertGreaterThanOrEqual(contrast(palette.danger,surface),4.5,"\(theme) danger text")
                }
                XCTAssertGreaterThanOrEqual(contrast(palette.accentText,palette.selection),4.5,"\(theme) accent text on a selected row")
                XCTAssertGreaterThanOrEqual(contrast(palette.onPrimary,palette.primary),4.5,"\(theme) primary button label")
            }
        }
    }

    /// Review 2026-09-22: cards sank below their panels in dark mode and inputs were drawn
    /// at ~1.3:1. Surfaces now rise window → panel → card in both appearances (a flat theme
    /// may keep panel = window), and input edges meet the 3:1 non-text minimum.
    func testSurfacesRiseAndInputsHaveVisibleEdges() {
        for theme in AppTheme.allCases {
            for (palette,dark) in [(theme.light,false),(theme.dark,true)] {
                let rise = { (lower: UInt32, higher: UInt32) -> Bool in
                    dark ? self.luminance(higher) >= self.luminance(lower) : self.luminance(higher) >= self.luminance(lower) }
                XCTAssertTrue(rise(palette.window,palette.panel),"\(theme) \(dark ? "dark" : "light") panel above window")
                XCTAssertTrue(rise(palette.panel,palette.card),"\(theme) \(dark ? "dark" : "light") card above panel")
                for surface in [palette.field,palette.panel,palette.card] {
                    XCTAssertGreaterThanOrEqual(contrast(palette.fieldStroke,surface),3,"\(theme) input edge")
                }
            }
        }
    }

    @MainActor
    func testClassicAudioPacketsRetainOriginalGainAndSettleAtSilence() {
        let view = PillView()
        view.reduceMotion = false
        view.reset()
        func width() -> CGFloat {
            view.listeningAudioScale
        }
        let quietWidth = width()
        var classic: CGFloat = 0
        // The same 150ms packets as Recorder -> Pipeline -> PillView.push.
        for packet: Float in [0, 0.35, 0.65, 1, 0.8, 0.4, 0] {
            view.push(packet)
            for _ in 0..<9 {
                view.tick()
                classic = floor((0.85 * classic + 0.15 * CGFloat(packet)) * 100) / 100
                XCTAssertEqual(view.smoothedLevel, classic, accuracy: 0.000001)
                XCTAssertEqual(view.listeningAudioScale, max(1, 5 * classic), accuracy: 0.000001)
            }
        }
        view.push(1)
        for _ in 0..<9 { view.tick() }
        XCTAssertGreaterThan(width(), quietWidth * 1.8, "A syllable must visibly expand within one 150ms packet")
        for _ in 0..<60 { view.tick() }
        let sustained = width()
        XCTAssertGreaterThan(sustained, quietWidth * 2.2)
        for _ in 0..<120 {
            view.tick()
            XCTAssertEqual(width(), sustained, "Steady audio must not create a separate timer pulse")
        }
        view.push(0)
        for _ in 0..<18 { view.tick() }
        XCTAssertEqual(width(), quietWidth, accuracy: 0.01, "Classic returns to its minimum gain within 300ms of silence")
        for _ in 0..<120 { view.tick(); XCTAssertEqual(width(), quietWidth) }
        view.reset()
        XCTAssertEqual(view.smoothedLevel, 0)
    }

    @MainActor
    func testClassicListeningBarsKeepWisprGeometry() {
        let center = NSPoint(x: 36.5, y: 15)
        let rest = (0..<PillView.barCount).map { PillView.listeningBar($0, center: center, scale: nil) }
        XCTAssertEqual(rest.count, 10)
        // Ten 2px bars at 2px gaps, 4px inside the 46px cell: a 38px group centred in the pill.
        XCTAssertEqual(rest.first!.rect.minX, center.x - 19, accuracy: 0.000001)
        XCTAssertEqual(rest.last!.rect.maxX, center.x + 19, accuracy: 0.000001)
        for (i, bar) in rest.enumerated() {
            XCTAssertEqual(bar.rect.size, NSSize(width: 2, height: 2))
            XCTAssertEqual(bar.rect.midY, center.y, accuracy: 0.000001)
            XCTAssertEqual(bar.yRadius, 0.5)
            if i > 0 { XCTAssertEqual(bar.rect.minX - rest[i - 1].rect.maxX, 2, accuracy: 0.000001) }
        }
        // Full gain (5) at the pulse crest (1.5): the centre bars reach 2 × 7.5 × the bulge.
        let loud = (0..<PillView.barCount).map { PillView.listeningBar($0, center: center, scale: 7.5).rect.height }
        XCTAssertEqual(loud[4], 15 * (1 - 0.25 / 48), accuracy: 0.000001)
        XCTAssertEqual(loud[0], 15 * (1 - 20.25 / 48), accuracy: 0.000001)
        for i in loud.indices { XCTAssertEqual(loud[i], loud[loud.count - 1 - i], accuracy: 0.000001) }
    }

}
