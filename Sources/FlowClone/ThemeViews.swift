import Cocoa
import SwiftUI

/// The serif themes' home hero. `compact` (a short window) drops the art tile and subtitle
/// and sets the headline on one 28pt line, so recent dictations stay in view.
struct ThemedDictationWelcome: View {
    var compact = false
    var body: some View {
        // The hero's copy and art are per-theme identity, not tokens.
        let notebook = Theme.current == .anthropic
        HStack(alignment:.center,spacing:28) {
            VStack(alignment:.leading,spacing:compact ? 6 : 10) {
                Text(DictationPage.greeting(fullName:NSFullUserName()))
                    .font(.system(size:11,weight:.medium)).foregroundStyle(Theme.muted)
                headline(notebook: notebook)
                    .accessibilityAddTraits(.isHeader)
            }.frame(maxWidth:.infinity,alignment:.leading)
            if !compact {
                if notebook {
                    NotebookIllustration().frame(width:205,height:180).clipShape(RoundedRectangle(cornerRadius:Theme.radius))
                } else {
                    ThemeMark(theme:Theme.current).frame(width:Theme.current == .softSeal ? 80 : 66,height:66)
                        .padding(30).background(Theme.selection.opacity(0.5),in:tileShape)
                        .accessibilityHidden(true)
                }
            }
        }.padding(.vertical,compact ? 0 : 8).foregroundStyle(Theme.ink)
    }

    @ViewBuilder private func headline(notebook: Bool) -> some View {
        let size: CGFloat = compact ? 28 : notebook ? 43 : Theme.current == .softSeal ? 39 : 35
        if notebook {
            (Text(compact ? "A little room to " : "A little room\nto ").font(Theme.serif(size))
                + Text("think aloud.").font(Theme.serif(size,italic:true)))
                .tracking(compact ? -0.6 : -1.3).lineLimit(compact ? 1 : nil).fixedSize(horizontal:false,vertical:true)
        } else {
            Text("A little room to think.").font(Theme.serif(size))
                .tracking(compact ? -0.5 : -0.8).lineLimit(compact ? 1 : nil).fixedSize(horizontal:false,vertical:true)
        }
    }

    /// Soft Seal's tile takes the seal's diagonal corners; the others use the theme radius.
    private var tileShape: AnyShape {
        Theme.current == .softSeal
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius:26,bottomLeadingRadius:10,bottomTrailingRadius:26,topTrailingRadius:10))
            : AnyShape(RoundedRectangle(cornerRadius:Theme.radius))
    }
}

/// Anthropic's home greeting: FlowClone's own clay ink-wave mark set before a light serif
/// line, centred, as Claude sets its greeting (the mark is FlowClone's, never Claude's spark).
struct ComposerGreeting: View {
    var compact = false
    var body: some View {
        let size: CGFloat = compact ? 26 : 36
        HStack(alignment: .center, spacing: size * 0.4) {
            ThemeMark(theme: .anthropic).frame(width: size * 0.95, height: size * 0.7).accessibilityHidden(true)
            Text(DictationPage.timeGreeting(fullName: NSFullUserName()))
                .font(Theme.serif(size, weight: .light))
                .tracking(-0.4)
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }
}

/// An original illustration in the spirit of Anthropic's editorial art: a flat oat tile,
/// one gestural ink brush stroke (a spoken loop settling into a written line), and an
/// ivory cut-paper sheet with slightly imperfect edges. Two colours plus ink, no outlines.
struct BrushTileIllustration: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 240, y: size.height / 180)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 240, height: 180), cornerRadius: 24),
                     with: .color(Color(nsColor: NSColor(rgb: 0xE3DACC))))
            var paper = Path()
            paper.move(to: CGPoint(x: 118, y: 52)); paper.addLine(to: CGPoint(x: 196, y: 47))
            paper.addLine(to: CGPoint(x: 201, y: 139)); paper.addLine(to: CGPoint(x: 121, y: 146))
            paper.closeSubpath()
            ctx.fill(paper, with: .color(Color(nsColor: NSColor(rgb: 0xFAF9F5))))
            // The brush: a filled ribbon whose width swells and thins, drawn as one stroke.
            let ink = Color(nsColor: NSColor(rgb: 0x141413))
            var loop = Path()
            loop.move(to: CGPoint(x: 38, y: 118))
            loop.addCurve(to: CGPoint(x: 70, y: 58), control1: CGPoint(x: 24, y: 86), control2: CGPoint(x: 44, y: 54))
            loop.addCurve(to: CGPoint(x: 84, y: 104), control1: CGPoint(x: 98, y: 62), control2: CGPoint(x: 100, y: 98))
            loop.addCurve(to: CGPoint(x: 132, y: 88), control1: CGPoint(x: 68, y: 112), control2: CGPoint(x: 104, y: 70))
            ctx.stroke(loop, with: .color(ink), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            for (y, w) in [(82.0, 52.0), (100, 58), (118, 40)] {
                var line = Path()
                line.move(to: CGPoint(x: 134, y: y))
                line.addQuadCurve(to: CGPoint(x: 134 + w, y: y - 2), control: CGPoint(x: 134 + w / 2, y: y + 3))
                ctx.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
        }
        .accessibilityLabel("A spoken loop becoming a written line")
    }
}

/// An original, code-native ink drawing. The line settles into writing on an open page.
struct NotebookIllustration: View {
    var body: some View {
        let block = Color(nsColor: Theme.brand)
        Canvas { ctx,size in
            ctx.scaleBy(x:size.width/380,y:size.height/320)
            ctx.fill(Path(CGRect(x:0,y:0,width:380,height:320)),with:.color(block))
            var book=Path()
            book.move(to:CGPoint(x:74,y:111));book.addLine(to:CGPoint(x:72,y:209))
            book.addQuadCurve(to:CGPoint(x:166,y:225),control:CGPoint(x:121,y:206))
            book.addQuadCurve(to:CGPoint(x:277,y:194),control:CGPoint(x:211,y:195))
            book.addLine(to:CGPoint(x:265,y:92))
            book.addQuadCurve(to:CGPoint(x:166,y:117),control:CGPoint(x:213,y:87))
            book.addQuadCurve(to:CGPoint(x:74,y:111),control:CGPoint(x:115,y:94))
            ctx.fill(book,with:.color(Color(nsColor:NSColor(rgb:0xFAF9F5))))
            ctx.stroke(book,with:.color(.black.opacity(0.82)),style:StrokeStyle(lineWidth:1.7,lineCap:.round,lineJoin:.round))
            var lines=Path()
            lines.move(to:CGPoint(x:166,y:117));lines.addQuadCurve(to:CGPoint(x:166,y:222),control:CGPoint(x:170,y:172))
            lines.move(to:CGPoint(x:70,y:123));lines.addLines([CGPoint(x:62,y:214),CGPoint(x:167,y:235),CGPoint(x:288,y:205),CGPoint(x:276,y:105)])
            for (x,y,w) in [(186.0,166.0,63.0),(187,181,52),(98,176,43),(99,191,40)] {
                lines.move(to:CGPoint(x:x,y:y));lines.addQuadCurve(to:CGPoint(x:x+w,y:y+(x<150 ? 9 : -10)),control:CGPoint(x:x+w/2,y:y-2))
            }
            lines.move(to:CGPoint(x:54,y:232));lines.addCurve(to:CGPoint(x:302,y:224),control1:CGPoint(x:156,y:230),control2:CGPoint(x:137,y:272))
            ctx.stroke(lines,with:.color(.black.opacity(0.8)),style:StrokeStyle(lineWidth:1.3,lineCap:.round,lineJoin:.round))
            var thought=Path()
            thought.move(to:CGPoint(x:91,y:148))
            thought.addCurve(to:CGPoint(x:113,y:112),control1:CGPoint(x:51,y:93),control2:CGPoint(x:113,y:80))
            thought.addCurve(to:CGPoint(x:97,y:129),control1:CGPoint(x:129,y:146),control2:CGPoint(x:81,y:145))
            thought.addCurve(to:CGPoint(x:128,y:106),control1:CGPoint(x:74,y:79),control2:CGPoint(x:127,y:78))
            thought.addCurve(to:CGPoint(x:105,y:143),control1:CGPoint(x:144,y:150),control2:CGPoint(x:102,y:166))
            thought.addCurve(to:CGPoint(x:132,y:147),control1:CGPoint(x:80,y:112),control2:CGPoint(x:125,y:101))
            thought.addCurve(to:CGPoint(x:157,y:143),control1:CGPoint(x:143,y:174),control2:CGPoint(x:143,y:145))
            thought.addCurve(to:CGPoint(x:244,y:142),control1:CGPoint(x:181,y:170),control2:CGPoint(x:194,y:139))
            ctx.stroke(thought,with:.color(.black.opacity(0.85)),style:StrokeStyle(lineWidth:2,lineCap:.round))
        }.accessibilityLabel("An ink line becomes writing in an open notebook")
    }
}
