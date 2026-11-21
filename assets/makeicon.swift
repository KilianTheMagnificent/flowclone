// Renders the FlowClone app icon, "Settle": one ink stroke that starts as a voice
// wave and calms into a flat line of text.
//  - an .iconset for app/AppIcon.icns, the flat white squircle macOS 14 and 15 show.
//    Every size is drawn natively; 32 px and below use a three-wave glyph with a heavier stroke.
//  - the same stroke, outlined, as the one layer of AppIcon.icon (Icon Composer). Compiled
//    into app/Assets.car it gives macOS 26+ its light, dark, clear and tinted icons.
// Usage, from assets/ (actool needs absolute paths: it resolves relative ones elsewhere):
//   swiftc makeicon.swift -o /tmp/makeicon && /tmp/makeicon /tmp/AppIcon.iconset AppIcon.icon/Assets/settle.svg
//   iconutil -c icns /tmp/AppIcon.iconset -o ../app/AppIcon.icns
//   mkdir -p /tmp/icon && xcrun actool "$PWD/AppIcon.icon" --compile /tmp/icon --platform macosx \
//     --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist /tmp/icon/partial.plist \
//     && cp /tmp/icon/Assets.car ../app/Assets.car
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon.iconset"
let svgOut = args.count > 2 ? args[2] : "AppIcon.icon/Assets/settle.svg"
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// In the 1024 grid, y up: half-waves as (width, amplitude), amplitude > 0 rises.
struct Glyph { let start: CGFloat; let waves: [(CGFloat, CGFloat)]; let end: CGFloat; let stroke: CGFloat }
let full = Glyph(start: 220, waves: [(100, 180), (100, -150), (100, 110), (100, -70), (100, 35)], end: 804, stroke: 52)
let small = Glyph(start: 240, waves: [(130, 190), (130, -140), (130, 70)], end: 784, stroke: 84)
let ink = CGColor(srgbRed: 0x17 / 255.0, green: 0x17 / 255.0, blue: 0x1A / 255.0, alpha: 1)

func centerline(_ g: Glyph) -> CGPath {
    let p = CGMutablePath()
    var x = g.start
    p.move(to: CGPoint(x: x, y: 512))
    for (w, a) in g.waves {
        let c = 512 + a * 4 / 3                  // cubic peak = 3/4 of the control height
        p.addCurve(to: CGPoint(x: x + w, y: 512),
                   control1: CGPoint(x: x + w / 3, y: c), control2: CGPoint(x: x + 2 * w / 3, y: c))
        x += w
    }
    p.addLine(to: CGPoint(x: g.end, y: 512))
    return p
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    let grid = NSAffineTransform()
    grid.scale(by: k)
    grid.concat()

    // ~10% margin per the Apple icon grid; large radius approximates the squircle.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()                      // offset and blur are in pixels, not the grid
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 24 * k
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    // A one-pixel edge keeps the white tile visible on white at Finder sizes.
    tile.lineWidth = 1 / k
    NSColor(white: 0, alpha: 0.1).setStroke()
    tile.stroke()

    let g = px <= 32 ? small : full
    let cg = NSGraphicsContext.current!.cgContext
    cg.addPath(centerline(g))
    cg.setLineWidth(g.stroke)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.setStrokeColor(ink)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}

// Icon Composer fills a layer's shapes, so the stroke ships as its filled outline,
// flipped to SVG's y-down grid. The viewBox maps the 824 tile onto the full-bleed canvas.
var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1024)
let outline = centerline(full).copy(strokingWithWidth: full.stroke, lineCap: .round, lineJoin: .round,
                                    miterLimit: 10, transform: flip)
var d = ""
func n(_ p: CGPoint) -> String { String(format: "%.2f %.2f", p.x, p.y) }
outline.applyWithBlock { e in
    let p = e.pointee.points
    switch e.pointee.type {
    case .moveToPoint: d += "M\(n(p[0]))"
    case .addLineToPoint: d += "L\(n(p[0]))"
    case .addQuadCurveToPoint: d += "Q\(n(p[0])) \(n(p[1]))"
    case .addCurveToPoint: d += "C\(n(p[0])) \(n(p[1])) \(n(p[2]))"
    case .closeSubpath: d += "Z"
    @unknown default: break
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="100 100 824 824">\
<path d="\(d)" fill="#17171A"/></svg>

"""
try! FileManager.default.createDirectory(atPath: (svgOut as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
try! svg.write(toFile: svgOut, atomically: true, encoding: .utf8)
print("wrote \(out) and \(svgOut)")
