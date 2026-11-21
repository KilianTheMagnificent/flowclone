import Cocoa
import Observation
import SwiftUI

/// Semantic colour roles. Surfaces rise window → sidebar → panel → card in BOTH appearances
/// (lighter is higher), so a card never reads as a hole in its panel; dialogs use `card`.
/// `accent` may be decorative; anything set as text uses `accentText` (≥4.5:1 on every
/// surface and the selection). `fieldStroke` bounds inputs and checkboxes at ≥3:1.
struct ThemePalette: Equatable, Sendable {
    let window, sidebar, panel, card: UInt32
    let field, fieldStroke, divider: UInt32
    let ink, muted: UInt32
    let accent, accentText, primary, onPrimary, selection: UInt32
    let success, danger: UInt32
    /// Pre-2026-09-22 names, kept while pages migrate to the ramp.
    var ground: UInt32 { window }
    var stroke: UInt32 { divider }
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case classic, ceramic, softSeal = "soft-seal", anthropic, interface, settle
    var id: String { rawValue }
    var title: String {
        switch self { case .classic: "Classic"; case .ceramic: "Ceramic"; case .softSeal: "Soft Seal"; case .anthropic: "Anthropic"; case .interface: "Interface"; case .settle: "Settle" }
    }
    var detail: String {
        switch self {
        case .classic: "Warm paper, a book serif, a soft violet, and the original waveform."
        case .ceramic: "Celadon porcelain, kiln red, and five responsive beads."
        case .softSeal: "Warm parchment, soft corners, and a clay seal."
        case .anthropic: "Warm paper, serif type, and a drawn ink waveform."
        case .interface: "Cool graphite panels and one blue, from focus ring to wave."
        case .settle: "The app icon’s white and ink, and one fluid line that settles as you speak."
        }
    }
    var light: ThemePalette {
        switch self {
        // Classic (Folio): warm cream paper, one soft page laid over it, ink-brown type and a
        // soft violet ink for actions and the current row.
        case .classic: .init(window:0xF5F1E8,sidebar:0xF5F1E8,panel:0xFBF9F4,card:0xFFFFFF,field:0xFFFFFF,fieldStroke:0x8C857A,divider:0xE6DFD2,
                             ink:0x2B2620,muted:0x6E665B,accent:0x67589A,accentText:0x67589A,primary:0x67589A,onPrimary:0xFFFFFF,selection:0xECE6F3,success:0x2B7340,danger:0xB3261E)
        case .ceramic: .init(window:0xEDEFEC,sidebar:0xEDEFEC,panel:0xF8F9F7,card:0xFFFFFF,field:0xFFFFFF,fieldStroke:0x8C8F8A,divider:0xDFE2DE,
                             ink:0x2A2724,muted:0x626560,accent:0xA2432B,accentText:0x9A3E27,primary:0xA2432B,onPrimary:0xFFFFFF,selection:0xE9D5C6,success:0x34704A,danger:0xA8322A)
        case .softSeal: .init(window:0xF3E9DB,sidebar:0xF0E4D3,panel:0xF8F1E5,card:0xFFF9EF,field:0xFFF9EF,fieldStroke:0x9A8266,divider:0xE3D4C0,
                              ink:0x352C25,muted:0x6B5E52,accent:0x975B40,accentText:0x7E4630,primary:0x975B40,onPrimary:0xFFF9EF,selection:0xE6CCAE,success:0x546340,danger:0x8A3A2A)
        // Anthropic: the Claude app's classic ivory set (bg-100 page, bg-200 sidebar, bg-000 cards),
        // warm ink, clay kept off text; links and selected icons use the secondary ink.
        case .anthropic: .init(window:0xFAF9F5,sidebar:0xF5F4ED,panel:0xFAF9F5,card:0xFFFFFF,field:0xFFFFFF,fieldStroke:0x8C8A83,divider:0xE4E3DD,
                               ink:0x141413,muted:0x6E6D67,accent:0x141413,accentText:0x3D3D3A,primary:0x141413,onPrimary:0xFAF9F5,selection:0xE3E2DB,success:0x2F7613,danger:0xB53333)
        case .interface: .init(window:0xEEF0F3,sidebar:0xF5F6F8,panel:0xFAFAFB,card:0xFFFFFF,field:0xFFFFFF,fieldStroke:0x8A8F99,divider:0xD9DCE2,
                               ink:0x1F2127,muted:0x575C66,accent:0x2D5BDB,accentText:0x2D5BDB,primary:0x2D5BDB,onPrimary:0xFFFFFF,selection:0xE2E7F1,success:0x1F7A45,danger:0xB4234D)
        // Settle: the icon's white tile and #17171A ink, neutral greys between; ink is the accent.
        case .settle: .init(window:0xF2F2F3,sidebar:0xF2F2F3,panel:0xFAFAFA,card:0xFFFFFF,field:0xFFFFFF,fieldStroke:0x8A8A90,divider:0xE2E2E5,
                            ink:0x17171A,muted:0x5F5F66,accent:0x17171A,accentText:0x17171A,primary:0x17171A,onPrimary:0xFFFFFF,selection:0xE5E5E8,success:0x26703C,danger:0xB3261E)
        }
    }
    var dark: ThemePalette {
        switch self {
        // Night paper: warm charcoal, never black, with the same ink-on-paper contrast.
        case .classic: .init(window:0x1D1B18,sidebar:0x1D1B18,panel:0x24221E,card:0x2B2824,field:0x1F1D1A,fieldStroke:0x857D70,divider:0x36322C,
                             ink:0xEDE7DC,muted:0xA9A194,accent:0xB8ACDF,accentText:0xB8ACDF,primary:0xB8ACDF,onPrimary:0x1D1B18,selection:0x352F45,success:0x7BD08F,danger:0xFF8A80)
        case .ceramic: .init(window:0x1B1C1D,sidebar:0x202123,panel:0x242527,card:0x2E3032,field:0x202123,fieldStroke:0x80838A,divider:0x3A3C3F,
                             ink:0xF2EEE8,muted:0xB1B0AC,accent:0xE0876B,accentText:0xE8957A,primary:0xE0876B,onPrimary:0x2A1610,selection:0x45302A,success:0x86CF98,danger:0xFF8E82)
        case .softSeal: .init(window:0x221915,sidebar:0x271C17,panel:0x2C211B,card:0x372A22,field:0x2E231C,fieldStroke:0x8C765F,divider:0x4A3B30,
                              ink:0xFAEEDB,muted:0xC2AF98,accent:0xE0A380,accentText:0xE6AD8C,primary:0xE0A380,onPrimary:0x2A1A10,selection:0x584030,success:0xA9C08A,danger:0xFF8F7A)
        case .anthropic: .init(window:0x262624,sidebar:0x1F1E1D,panel:0x262624,card:0x30302E,field:0x30302E,fieldStroke:0x85837C,divider:0x3B3A38,
                               ink:0xFAF9F5,muted:0xA5A39B,accent:0xE8E6DC,accentText:0xC2C0B6,primary:0xFAF9F5,onPrimary:0x262624,selection:0x3A3937,success:0x6FB24A,danger:0xFE8181)
        case .interface: .init(window:0x0B0C0E,sidebar:0x131418,panel:0x16171B,card:0x1D1F24,field:0x131418,fieldStroke:0x6A6F7B,divider:0x2E3036,
                               ink:0xE4E5E8,muted:0xA3A7B0,accent:0x7FA6FF,accentText:0x8FB1FF,primary:0x7FA6FF,onPrimary:0x0B1020,selection:0x252936,success:0x72CF8D,danger:0xFF807B)
        // The dark icon: an ink tile (the panel) carrying a white stroke.
        case .settle: .init(window:0x0F0F11,sidebar:0x141416,panel:0x17171A,card:0x202024,field:0x141416,fieldStroke:0x75757D,divider:0x2C2C31,
                            ink:0xF5F5F6,muted:0xA3A3AA,accent:0xF5F5F6,accentText:0xE6E6E9,primary:0xF5F5F6,onPrimary:0x17171A,selection:0x2B2B30,success:0x7ACB8E,danger:0xFF8A80)
        }
    }
    /// Controls (buttons, fields, rows) and the two outer panels.
    var radius: CGFloat { switch self { case .classic, .ceramic, .settle: 12; case .softSeal: 20; case .anthropic: 8; case .interface: 10 } }
    var controlRadius: CGFloat { switch self { case .softSeal: 10; case .anthropic: 8; case .interface: 6; default: 8 } }
    /// Anthropic keeps one flat paper surface: no panel frames, cards only where content is grouped.
    var flatPanels: Bool { self == .anthropic }
    /// Serif for headings and for the user's own words (transcripts, drafts, expansions).
    var serifDisplay: Bool { self == .ceramic || self == .softSeal || self == .anthropic }
    /// Classic leaves the sidebar unframed on the window ground, so only the page is a panel.
    var sidebarOnGround: Bool { self == .classic }
    /// Classic's page runs to the window's right and bottom edges, rounded and ruled only where
    /// it meets the sidebar and the title rail.
    var pageBleeds: Bool { self == .classic }
    /// Pages open with their own title (`PageHeader`) instead of the shell's head band.
    var titlesInPage: Bool { serifDisplay || self == .classic }
    /// Classic sets display type and the user's own words in Iowan Old Style; controls, labels
    /// and settings stay in SF Pro.
    var bookSerif: Bool { self == .classic }
    /// Classic's home is a journal: greeting, totals, then the dictations as ruled entries,
    /// with no capture bar or shortcut hints (dictation starts from the shortcut).
    var journalHome: Bool { self == .classic }
    var activeSize: NSSize {
        switch self { case .classic: NSSize(width:73,height:30); case .ceramic: NSSize(width:38,height:38); case .softSeal: NSSize(width:60,height:32); case .anthropic: NSSize(width:56,height:34); case .interface: NSSize(width:60,height:30); case .settle: NSSize(width:80,height:30) }
    }
    var processingSize: NSSize { self == .classic ? NSSize(width:98,height:30) : activeSize }
    var idleSize: NSSize {
        switch self { case .classic: NSSize(width:40,height:8); case .ceramic: NSSize(width:14,height:14); case .softSeal: NSSize(width:24,height:9); case .anthropic: NSSize(width:22,height:8); case .interface: NSSize(width:22,height:8); case .settle: NSSize(width:24,height:8) }
    }
    /// This theme's display face at `size`, independent of the current theme (the picker sets
    /// each theme's name in its own face). Sans themes return SF Pro.
    func displayFont(_ size: CGFloat, italic: Bool = false, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .anthropic:
            let font = Font.system(size:size, weight:weight, design:.serif)
            return italic ? font.italic() : font
        case .classic:
            let bold = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
            return .custom(bold ? (italic ? "IowanOldStyle-BoldItalic" : "IowanOldStyle-Bold") : (italic ? "IowanOldStyle-Italic" : "IowanOldStyle-Roman"), size:size)
        case .ceramic, .softSeal:
            return .custom(italic ? "Charter-Italic" : "Charter", size:size)
        case .interface, .settle:
            let font = Font.system(size:size, weight:weight)
            return italic ? font.italic() : font
        }
    }
}

/// Interface colours outside the eight palette roles, as (light, dark) pairs.
enum InterfaceColors {
    typealias Pair = (light: UInt32, dark: UInt32)
    /// Composer, stats and pill surface (Interface `--surface`).
    static let surface: Pair = (0xFFFDFA, 0x151619)
    /// Quiet control edge (Interface `--input-border`).
    static let edge: Pair = (0xCEC8BC, 0x34353A)
    /// The speaking waveform: a vivid blue the owner chose over periwinkle for contrast.
    static let wave: Pair = (0x1A6DFF, 0x3D8BFF)
    /// The mark: a graphite tile carrying the blue wave, so the window and pill share one blue.
    static let brand: Pair = (0x1C1D22, 0x30333C)
    static let brandInk: Pair = (0x7EA2FF, 0x8FB1FF)
    static let ok: Pair = (0x206C3F, 0x72CF8D)
    static let failure: Pair = (0xB4234D, 0xFF807B)
}

/// Settle's pill is the app icon at speaking size: a white capsule with an ink line in light,
/// an ink capsule with a white line in dark.
enum SettleColors {
    typealias Pair = InterfaceColors.Pair
    static let surface: Pair = (0xFFFFFF, 0x17171A)
    static let line: Pair = (0x17171A, 0xF5F5F6)
    /// The capsule's edge over a white page or a black desktop.
    static let edge: Pair = (0xC6C6CC, 0x3C3C43)
}

/// Classic (Folio) colours outside the palette roles, as (light, dark) pairs.
enum FolioColors {
    typealias Pair = InterfaceColors.Pair
    /// The soft fill of the search pill, a tint of the page (muted text stays above 4.5:1).
    static let wash: Pair = (0xF1ECE2, 0x2B2824)
}

@MainActor @Observable
final class AppearanceStore {
    static let preferenceKey = "appearanceTheme"
    static let didChange = Notification.Name("FlowCloneAppearanceDidChange")
    static let shared = AppearanceStore(defaults: ProcessInfo.processInfo.arguments.contains("--theme-preview")
        ? UserDefaults(suiteName: "com.andre.flowclone.theme-preview")! : .standard)
    private let defaults: UserDefaults
    private(set) var theme: AppTheme

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .classic
    }
    func select(_ choice: AppTheme) {
        guard choice != theme else { return }
        theme = choice
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

@MainActor
enum Theme {
    static var current: AppTheme { AppearanceStore.shared.theme }
    static var isEditorial: Bool { current == .anthropic }
    static var isInterface: Bool { current == .interface }
    /// Interface and Settle set everything in SF Pro, and Classic its controls (its display type and
    /// words are `bookSerif`); the others use a serif for display type and for the user's own words.
    static var usesSystemType: Bool { !current.serifDisplay }
    /// A soft page-tinted fill for Classic's search pill.
    static var wash: Color { Color(nsColor: adaptive(FolioColors.wash)) }
    static var flatPanels: Bool { current.flatPanels }
    static var titlesInPage: Bool { current.titlesInPage }
    // The surface ramp, lowest to highest. Dialogs and grouped blocks sit on `surface`.
    static var window: Color { color(\.window) }
    static var sidebar: Color { color(\.sidebar) }
    static var panel: Color { color(\.panel) }
    static var surface: Color { color(\.card) }
    static var field: Color { color(\.field) }
    static var fieldStroke: Color { color(\.fieldStroke, contrast: true) }
    static var divider: Color { color(\.divider, contrast: true) }
    static var ink: Color { color(\.ink) }
    static var muted: Color { color(\.muted) }
    /// Decorative accent (fills, marks, selection rings). Text in the accent uses `accentText`.
    static var accent: Color { color(\.accent) }
    static var accentText: Color { color(\.accentText) }
    static var primary: Color { color(\.primary) }
    static var onPrimary: Color { color(\.onPrimary) }
    static var selection: Color { color(\.selection) }
    static var success: Color { color(\.success) }
    static var danger: Color { color(\.danger) }
    // Pre-ramp names, kept while pages migrate: `ground` is the window, `raised`/`card` the surface.
    static var ground: Color { window }
    static var card: Color { surface }
    static var raised: Color { surface }
    static var stroke: Color { divider }
    static var rowHover: Color { ink.opacity(0.045) }
    /// Anthropic's clay: only the mark, the pill and the record button carry it (Claude keeps
    /// clay off text, selection and focus, which use ink — Anthropic's `accent` is ink).
    static let brand = NSColor(rgb: 0xD97757)
    /// Button geometry: Claude's controls are 32pt with 16pt sides and a #D1CFC5 outline.
    static var buttonHeight: CGFloat { current == .anthropic ? 32 : 28 }
    static var buttonPadding: CGFloat { current == .anthropic ? 16 : 12 }
    static var buttonStroke: Color {
        current == .anthropic ? Color(nsColor: adaptive((0xD1CFC5, 0x4D4C48))) : fieldStroke.opacity(0.55)
    }
    static let olive = NSColor(rgb: 0x698455)
    static let failure = NSColor(rgb: 0xB44E35)
    static var radius: CGFloat { current.radius }
    static var controlRadius: CGFloat { current.controlRadius }
    static var pageFont: Font {
        switch current {
        case .interface: .system(size:22,weight:.semibold)
        case .settle: .system(size:24,weight:.semibold)
        case .classic: serif(36)
        // Claude's serif titles: 24–28pt at weight 500.
        case .anthropic: serif(28, weight:.medium)
        case .softSeal: serif(36)
        case .ceramic: serif(32)
        }
    }
    static var sectionFont: Font {
        switch current {
        case .interface, .settle: .system(size:15,weight:.semibold)
        case .classic: serif(22)
        case .anthropic: serif(20, weight:.medium)
        case .softSeal: serif(25)
        case .ceramic: serif(23)
        }
    }
    /// The user's own words. Anthropic follows Claude's response text: serif 16 on a 24 line.
    static var writingFont: Font {
        switch current {
        case .interface, .settle: .system(size:15)
        case .classic: serif(17)
        case .anthropic: serif(16)
        case .softSeal: serif(19)
        case .ceramic: serif(17)
        }
    }
    static var sheetTitleFont: Font {
        current.bookSerif ? serif(24) : usesSystemType ? .system(size:20,weight:.semibold) : current == .anthropic ? serif(22, weight:.medium) : serif(24)
    }
    /// Ceramic and Soft Seal set Charter. Anthropic uses New York (the system serif), the
    /// closest built-in match to Anthropic Serif and the `ui-serif` fallback Anthropic declares.
    /// Classic sets Iowan Old Style, the book face that ships with macOS.
    static func serif(_ size: CGFloat, italic: Bool = false, weight: Font.Weight = .regular) -> Font {
        current.displayFont(size, italic: italic, weight: weight)
    }
    static func nativeWritingFont(_ size: CGFloat) -> NSFont {
        if current.bookSerif { return NSFont(name:"IowanOldStyle-Roman",size:size+1) ?? .systemFont(ofSize:size) }
        if usesSystemType { return .systemFont(ofSize:size) }
        if current == .anthropic {
            let base = NSFont.systemFont(ofSize:size+1)
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor:$0, size:size+1) } ?? base
        }
        return NSFont(name:"Charter",size:size+1) ?? .systemFont(ofSize:size)
    }
    /// Claude's sidebar is wider and hairline-edged; Classic's unframed list is narrower; the
    /// other themes keep the 240pt panel.
    static var sidebarWidth: CGFloat { current == .anthropic ? 264 : current == .classic ? 220 : 240 }
    static func color(_ key: KeyPath<ThemePalette,UInt32>, contrast: Bool = false) -> Color { Color(nsColor:nativeColor(key,contrast:contrast)) }
    static func nativeColor(_ key: KeyPath<ThemePalette,UInt32>, contrast: Bool = false) -> NSColor {
        adaptive((current.light[keyPath:key], current.dark[keyPath:key]), contrast: contrast)
    }
    static func adaptive(_ pair: InterfaceColors.Pair, contrast: Bool = false) -> NSColor {
        let (light, dark) = pair
        return NSColor(name:nil) { appearance in
            let match = appearance.bestMatch(from:[.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            if contrast && (match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua) { return isDark ? .white : .black }
            return NSColor(rgb:isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed:CGFloat((rgb >> 16) & 255)/255,green:CGFloat((rgb >> 8) & 255)/255,blue:CGFloat(rgb & 255)/255,alpha:alpha)
    }
}

/// Preserve Classic's original quantized audio envelope.
enum ListeningMeter {
    static func clamp(_ level: CGFloat) -> CGFloat { min(1, max(0, level.isFinite ? level : 0)) }
    static func smooth(current: CGFloat, target: CGFloat) -> CGFloat {
        floor((0.85 * clamp(current) + 0.15 * clamp(target)) * 100) / 100
    }
    static func gain(_ level: CGFloat) -> CGFloat { max(1, 5 * clamp(level)) }
}
