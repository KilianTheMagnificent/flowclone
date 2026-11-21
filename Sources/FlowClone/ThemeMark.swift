import Cocoa
import SwiftUI

/// Each theme's small brand mark: the sidebar rail, the theme picker and the welcome tile.
struct ThemeMark: View {
    let theme: AppTheme
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let color = Color(nsColor: theme == .softSeal ? NSColor(rgb:0xFFF3DF) : theme == .anthropic ? Theme.brand : NSColor(rgb:0xC96442))
        // The mark's own theme, not the current one: the picker shows every theme's mark side by side.
        let accent = Color(nsColor: NSColor(rgb: scheme == .dark ? theme.dark.accent : theme.light.accent))
        Canvas { context, size in
            let center = CGPoint(x:size.width/2,y:size.height/2)
            switch theme {
            case .classic:
                // The original waveform, in Classic's violet.
                let bar = size.width/8, pitch = size.width/5
                for (i,share) in [0.25,0.6,0.9,0.6,0.25].enumerated() {
                    let h = size.height*share
                    context.fill(Path(roundedRect:CGRect(x:center.x+CGFloat(i-2)*pitch-bar/2,y:(size.height-h)/2,width:bar,height:h),cornerRadius:bar/2),with:.color(accent))
                }
            case .ceramic:
                // Five kiln-red beads in a row, swelling at the centre like the pill's voice.
                let side = min(size.width,size.height), bead = side*0.16, pitch = side*0.205
                for (i,swell) in [1.0,1.6,2.3,1.6,1.0].enumerated() {
                    let h = bead*swell
                    context.fill(Path(roundedRect:CGRect(x:center.x+CGFloat(i-2)*pitch-bead/2,y:center.y-h/2,width:bead,height:h),cornerRadius:bead/2),with:.color(accent))
                }
            case .softSeal:
                // The seal's diagonal corners: large top-left and bottom-right, small elsewhere.
                let side = min(size.width,size.height), large = side*0.39, small = side*0.15
                let seal = UnevenRoundedRectangle(cornerRadii:.init(topLeading:large,bottomLeading:small,bottomTrailing:large,topTrailing:small),style:.continuous)
                context.fill(seal.path(in:CGRect(origin:.zero,size:size)),with:.color(Color(nsColor:NSColor(rgb:scheme == .dark ? 0xA7694D : 0xB77356))))
                let bar = max(1.5,size.height*0.07)
                for i in 0..<3 {
                    let h = size.height*(i == 1 ? 0.6 : 0.36)
                    context.fill(Path(roundedRect:CGRect(x:center.x+CGFloat(i-1)*bar*2.8-bar/2,y:center.y-h/2,width:bar,height:h),cornerRadius:bar/2),with:.color(color))
                }
            case .anthropic:
                // FlowClone's own ink waveform, shared with the speaking indicator.
                let scale = min(size.width / 40, size.height / 30)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -27, y: -16)
                // Small marks (the 18pt rail) thicken each stroke so it stays ink, not hatching.
                let outline = max(0, 1.3 / scale - 1.7) / 2
                for (index, height) in [7.0, 13, 20, 12, 25, 18, 10, 16, 6].enumerated() {
                    let stroke = Path(InkWaveformGeometry.stroke(index: index, height: height))
                    context.fill(stroke, with: .color(color))
                    if outline > 0 { context.stroke(stroke, with: .color(color), style: StrokeStyle(lineWidth: outline * 2, lineJoin: .round)) }
                }
            case .interface:
                // A graphite tile carrying the five-bar wave in Interface's blue.
                context.fill(Path(roundedRect:CGRect(origin:.zero,size:size),cornerRadius:size.width*0.22),with:.color(Color(nsColor:Theme.adaptive(InterfaceColors.brand))))
                let bar = size.width*0.1, gap = size.width*0.06, total = bar*5+gap*4
                for (i,share) in [0.3,0.55,0.78,0.55,0.3].enumerated() {
                    let h = size.height*share
                    context.fill(Path(roundedRect:CGRect(x:(size.width-total)/2+CGFloat(i)*(bar+gap),y:(size.height-h)/2,width:bar,height:h),cornerRadius:bar/2),
                                 with:.color(Color(nsColor:Theme.adaptive(InterfaceColors.brandInk))))
                }
            case .settle:
                // The app icon's stroke in ink; the rail and picker sizes use its heavier small glyph.
                let glyph = min(size.width, size.height) < 32 ? SettleGlyph.small : SettleGlyph.full
                let box = SettleGlyph.bounds(glyph), scale = min(size.width / box.width, size.height / box.height)
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: scale, y: -scale)
                context.translateBy(x: -box.midX, y: -box.midY)
                context.stroke(Path(SettleGlyph.centerline(glyph)), with: .color(accent),
                               style: StrokeStyle(lineWidth: glyph.stroke, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}
