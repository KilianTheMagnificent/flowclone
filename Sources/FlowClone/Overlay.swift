// The recording pill. It must NEVER take focus: if it did, the frontmost app would
// change and the synthetic Cmd+V would land in the wrong window (RESEARCH.md §5).
// Hence nonactivating + canBecomeKey/Main = false + orderFrontRegardless only.
// Every method here is main-thread only; callers hop with DispatchQueue.main.async.
//
// State language (matched to Wispr Flow desktop 1.6.326): no text. Listening is the
// live white waveform. Processing flattens that waveform to ten muted marks and adds
// an eight-ray lavender chase spinner. A 60fps clock runs only for animated phases;
// panel visibility and occlusion recovery use a separate low-frequency watchdog.
import Cocoa
import os

enum PillModeBadge: String, CaseIterable, Equatable, Sendable {
    case prompt = "Prompt"
    case literal = "Literal"
    case spelling = "Spelling"
    case draft = "Draft"

    var monogram: String {
        switch self {
        case .prompt: return "P"
        case .literal: return "L"
        case .spelling: return "S"
        case .draft: return "D"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .prompt: return NSColor(srgbRed: 168 / 255, green: 142 / 255, blue: 235 / 255, alpha: 1)
        case .literal: return NSColor(srgbRed: 235 / 255, green: 184 / 255, blue: 92 / 255, alpha: 1)
        case .spelling: return NSColor(srgbRed: 96 / 255, green: 194 / 255, blue: 226 / 255, alpha: 1)
        case .draft: return NSColor(srgbRed: 118 / 255, green: 204 / 255, blue: 156 / 255, alpha: 1)
        }
    }
}

@MainActor
private final class Pill: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PillView: NSView {
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onAccessibilityPress: (() -> Bool)?

    private var trackingAreaRef: NSTrackingArea?
    private(set) var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private(set) var isHoveringCancel = false { didSet { if isHoveringCancel != oldValue { needsDisplay = true } } }
    var modeBadge: PillModeBadge? { didSet { if modeBadge != oldValue { needsDisplay = true } } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onDragBegan?(event) }
    override func mouseDragged(with event: NSEvent) { onDragged?(event) }
    override func mouseUp(with event: NSEvent) { onDragEnded?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?(event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCancelHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if !isHovering { isHovering = true }
        updateCancelHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isHoveringCancel = false
    }

    private func updateCancelHover(with event: NSEvent) {
        guard let window else { isHoveringCancel = false; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHoveringCancel = cancelHitRect?.contains(point) ?? false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isHovering, let cancel = cancelHitRect {
            addCursorRect(cancel, cursor: .pointingHand)
        } else {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "FlowClone dictation pill" }
    override func accessibilityValue() -> Any? {
        let base: String
        switch phase {
        case .idle:
            return "Idle"
        case .listening:
            base = pinned ? "Listening hands-free" : "Listening"
        case .warming:
            base = "Starting microphone"
        case .thinking(let slow):
            base = slow ? "Polishing transcript" : "Transcribing"
        case .ready:
            return "Microphone ready"
        case .failure:
            return "Recording failed"
        }
        if let modeBadge {
            return "\(base), \(modeBadge.rawValue) mode"
        }
        return base
    }
    override func accessibilityPerformPress() -> Bool {
        onAccessibilityPress?() ?? false
    }

    static let barCount = 10
    static let activeWaveform = NSColor.white
    static let spinner = NSColor(srgbRed: 163 / 255, green: 148 / 255, blue: 199 / 255, alpha: 1)
    static let border = NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 47 / 255, alpha: 1)
    static let idleAlpha: CGFloat = 0.85
    /// Full capsule height; both session sizes share it.
    static let height: CGFloat = 30
    /// Wispr's resting bar. ponytail: eyeballed, not measured — tune here.
    static let idleSize = NSSize(width: 40, height: 8)

    enum Phase {
        case listening
        case thinking(slow: Bool)
        case warming
        case ready
        case failure
        /// Wispr's resting bar between dictations: the same capsule, small and translucent.
        case idle
    }

    private(set) var phase: Phase = .listening
    /// What was on screen when the capsule started collapsing — it fades out as the bar
    /// shrinks instead of vanishing on the first frame.
    private var outgoing: Phase = .listening
    /// 0 = the resting bar, 1 = the full capsule. Read off the view's CURRENT size, so the
    /// window's frame animation is the only clock the idle morph needs.
    var morph: CGFloat {
        max(0, min(1, (bounds.height - Theme.current.idleSize.height) / (Theme.current.activeSize.height - Theme.current.idleSize.height)))
    }
    /// Only the listening pill carries partial text; the processing pill has its own width.
    var isListening: Bool { if case .listening = phase { return true }; return false }
    var isWarming: Bool { if case .warming = phase { return true }; return false }
    var canShowCancelButton: Bool {
        (isListening || isWarming) && bounds.width >= 52 && morph > 0.85
    }
    var cancelHitRect: NSRect? {
        guard canShowCancelButton else { return nil }
        return NSRect(x: bounds.maxX - 18, y: bounds.midY - 7, width: 14, height: 14)
    }
    /// F1: hands-free is latched. Sticky across phase changes (it outlives the warming →
    /// listening transition), and deliberately not touched by reset().
    var pinned = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { didSet { needsDisplay = true } }
    var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { didSet { needsDisplay = true } }
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { didSet { needsDisplay = true } }

    // New themes keep a short history of unaveraged capture levels. Classic retains
    // its 150ms packets, quantized 85/15 filter, and original gain.
    private var voiceMotion = ThemedVoiceMotion()
    /// Settle's line: the last 1.5 s of the voice.
    private var trail = VoiceTrail()
    private var lastVoiceTick = CACurrentMediaTime()
    func voiceHeights(for theme: AppTheme) -> [CGFloat] { voiceMotion.heights(for: theme, reducedMotion: reduceMotion) }
    var settleTrail: VoiceTrail { trail }
    private var targetLevel: CGFloat = 0
    private(set) var smoothedLevel: CGFloat = 0
    var listeningAudioScale: CGFloat { ListeningMeter.gain(smoothedLevel) }
    private var listeningStartedAt = CACurrentMediaTime()
    private var isAudioActive = false
    private var processingStartedAt: CFTimeInterval?

    var needsContinuousTicks: Bool {
        guard !reduceMotion else { return false }
        switch phase {
        case .listening: return isAudioActive
        case .thinking, .warming: return true
        case .ready, .failure, .idle: return false
        }
    }

    func reset() {
        let now = CACurrentMediaTime()
        phase = .listening
        targetLevel = 0
        smoothedLevel = 0
        voiceMotion = ThemedVoiceMotion()
        trail = VoiceTrail()
        lastVoiceTick = CACurrentMediaTime()
        listeningStartedAt = now
        isAudioActive = false
        processingStartedAt = nil
        needsDisplay = true
    }

    func beginProcessing(slow: Bool) {
        // ASR -> Prompt rewrite is one continuous processing session. Keeping the epoch means
        // the spinner never jumps back to ray zero when the slower pass begins.
        if case .listening = phase { processingStartedAt = CACurrentMediaTime() }
        if processingStartedAt == nil { processingStartedAt = CACurrentMediaTime() }
        targetLevel = 0
        smoothedLevel = 0
        voiceMotion = ThemedVoiceMotion()
        trail = VoiceTrail()
        lastVoiceTick = CACurrentMediaTime()
        isAudioActive = false
        phase = .thinking(slow: slow)
        needsDisplay = true
    }

    func beginFailure() {
        targetLevel = 0
        smoothedLevel = 0
        voiceMotion = ThemedVoiceMotion()
        trail = VoiceTrail()
        lastVoiceTick = CACurrentMediaTime()
        isAudioActive = false
        processingStartedAt = nil
        phase = .failure
        needsDisplay = true
    }

    func beginWarming() {
        targetLevel = 0
        smoothedLevel = 0
        voiceMotion = ThemedVoiceMotion()
        trail = VoiceTrail()
        lastVoiceTick = CACurrentMediaTime()
        isAudioActive = false
        processingStartedAt = CACurrentMediaTime()
        phase = .warming
        needsDisplay = true
    }

    func beginReady() {
        targetLevel = 0
        smoothedLevel = 0
        voiceMotion = ThemedVoiceMotion()
        trail = VoiceTrail()
        lastVoiceTick = CACurrentMediaTime()
        isAudioActive = false
        processingStartedAt = nil
        phase = .ready
        needsDisplay = true
    }

    func beginIdle() {
        if case .idle = phase {} else { outgoing = phase }
        targetLevel = 0
        smoothedLevel = 0
        voiceMotion = ThemedVoiceMotion()
        trail = VoiceTrail()
        lastVoiceTick = CACurrentMediaTime()
        isAudioActive = false
        processingStartedAt = nil
        phase = .idle
        needsDisplay = true
    }

    /// `voice` is the capture's loudness above the room; previews and probes send only `v`.
    func push(_ v: Float, voice: Float? = nil) {
        targetLevel = v.isFinite ? CGFloat(min(max(v, 0), 1)) : 0
        // The first audio packet marks Wispr's mic active. Quiet packets still retain
        // the white minimum-scale traveling wave until capture explicitly ends.
        isAudioActive = true
        if reduceMotion {
            smoothedLevel = targetLevel
            let now = CACurrentMediaTime()
            voiceMotion.advance(input: targetLevel, deltaTime: now - lastVoiceTick)
            trail.advance(deltaTime: now - lastVoiceTick)
            lastVoiceTick = now
        }
        trail.receive(voice ?? v)
        needsDisplay = true
    }

    /// The animation clock drives Wispr's quantized audio smoothing and animated phases.
    func tick(deltaTime: TimeInterval? = nil) {
        guard needsContinuousTicks else { return }
        if case .listening = phase {
            smoothedLevel = ListeningMeter.smooth(current: smoothedLevel, target: targetLevel)
            let now = CACurrentMediaTime()
            voiceMotion.advance(input: targetLevel, deltaTime: deltaTime ?? (now - lastVoiceTick))
            trail.advance(deltaTime: deltaTime ?? (now - lastVoiceTick))
            lastVoiceTick = now
        }
        needsDisplay = true
    }

    /// CSS `ease-in-out` is cubic-bezier(0.42, 0, 0.58, 1). Solve x(t) by
    /// bisection, then return y(t), matching the timing applied between keyframes.
    private func easeInOut(_ x: CGFloat) -> CGFloat {
        var lo: CGFloat = 0
        var hi: CGFloat = 1
        for _ in 0..<10 {
            let t = (lo + hi) / 2
            let mt = 1 - t
            let bx = 3 * mt * mt * t * 0.42 + 3 * mt * t * t * 0.58 + t * t * t
            if bx < x { lo = t } else { hi = t }
        }
        let t = (lo + hi) / 2
        let mt = 1 - t
        return 3 * mt * t * t + t * t * t
    }

    private func waveEnvelope(at phase: CGFloat) -> CGFloat {
        let frames: [(CGFloat, CGFloat)] = [
            (0.0, 1.0), (0.2, 1.2), (0.4, 1.5),
            (0.8, 1.1), (0.9, 1.3), (1.0, 1.0),
        ]
        for i in 0..<(frames.count - 1) {
            let a = frames[i]
            let b = frames[i + 1]
            guard phase <= b.0 else { continue }
            let local = (phase - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * easeInOut(local)
        }
        return 1
    }

    private func drawListeningBars(at time: CFTimeInterval, opacity: CGFloat) {
        guard opacity > 0 else { return }
        let listening: Bool
        if case .listening = phase { listening = true } else { listening = false }
        let active = isAudioActive && listening
        let center = NSPoint(x: bounds.midX, y: bounds.midY)

        Self.activeWaveform.withAlphaComponent((active ? 1 : 0.40) * opacity)
            .setFill()

        for i in 0..<Self.barCount {
            // Wispr's travelling pulse; reduced motion holds every bar at the pulse's base.
            var envelope: CGFloat = 1
            if active && !reduceMotion {
                let delay = i < 5 ? 0.1 * CGFloat(i) : 0.1 * CGFloat(i - Self.barCount)
                let elapsed = CGFloat(time - listeningStartedAt) - delay
                if elapsed >= 0 { envelope = waveEnvelope(at: elapsed.truncatingRemainder(dividingBy: 1)) }
            }
            let bar = Self.listeningBar(i, center: center, scale: active ? listeningAudioScale * envelope : nil)
            NSBezierPath(roundedRect: bar.rect, xRadius: 0.5, yRadius: bar.yRadius).fill()
        }
    }

    /// Wispr's listening bar `i` (desktop 1.6.326). The official bottom-dock cell is 46x18:
    /// 4px inset, ten 2px bars, 2px gaps. With audio a bar is 2px times `scale` (gain 1-5 times
    /// the 1-1.5 pulse) and a centre bulge; `nil` rests it as a 2px dot.
    static func listeningBar(_ i: Int, center: NSPoint, scale: CGFloat?) -> (rect: NSRect, yRadius: CGFloat) {
        let distance = abs(CGFloat(barCount - 1) / 2 - CGFloat(i))
        let s = scale.map { $0 * max(0, 1 - distance * distance / 48) } ?? 1
        return (NSRect(x: center.x - 23 + 4 + CGFloat(i) * 4, y: center.y - s, width: 2, height: 2 * s), 0.5 * s)
    }

    private func drawProcessing(at time: CFTimeInterval, opacity: CGFloat) {
        guard opacity > 0 else { return }

        // Current Wispr desktop geometry: a 46px waveform wrapper (4px inset,
        // ten 2px marks with 2px gaps), 6px row gap, then a 16px spinner.
        let rowWidth: CGFloat = 68
        let rowX = bounds.midX - rowWidth / 2
        let marksX = rowX + 4
        NSColor.white.withAlphaComponent(0.40 * opacity).setFill()
        for i in 0..<10 {
            let r = NSRect(x: marksX + CGFloat(i) * 4,
                           y: bounds.midY - 1, width: 2, height: 2)
            NSBezierPath(roundedRect: r, xRadius: 0.5, yRadius: 0.5).fill()
        }

        let elapsed = max(0, time - (processingStartedAt ?? time))
        let spinnerCenter = NSPoint(x: rowX + 46 + 6 + 8, y: bounds.midY)
        let cycle: CFTimeInterval = 1.1
        for i in 0..<8 {
            // Negative CSS delays become positive elapsed offsets. Rays reset from
            // dim to bright in clockwise order while the ring itself stays fixed.
            let offset = 0.1375 * Double(7 - i)
            let progress = (elapsed + offset).truncatingRemainder(dividingBy: cycle) / cycle
            let rayOpacity = (0.88 + (0.15 - 0.88) * progress) * Double(opacity)
            Self.spinner.withAlphaComponent(CGFloat(rayOpacity)).setFill()

            let angle = CGFloat.pi / 2 - CGFloat(i) * CGFloat.pi / 4
            let rayCenter = NSPoint(x: spinnerCenter.x + 6 * cos(angle),
                                    y: spinnerCenter.y + 6 * sin(angle))
            NSGraphicsContext.current?.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rayCenter.x, yBy: rayCenter.y)
            transform.rotate(byRadians: angle - CGFloat.pi / 2)
            transform.concat()
            NSBezierPath(roundedRect: NSRect(x: -1, y: -2.5, width: 2, height: 5),
                         xRadius: 1, yRadius: 1).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    /// F1: hands-free is running — a small dot pinned to the left of the waveform, in the
    /// spinner's lavender. No new panel and no new phase: the pill is otherwise identical
    /// to a held recording.
    private func drawPinnedDot(opacity: CGFloat) {
        Self.spinner.withAlphaComponent(opacity).setFill()
        let d: CGFloat = 5
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 30 - d / 2, y: bounds.midY - d / 2,
                                    width: d, height: d)).fill()
    }

    private func drawFailure(opacity: CGFloat) {
        // Ceramic and Anthropic draw failure in their palette's danger token (and ready in its
        // success token): the old fixed rust and olive fell below 3:1 on the dark pills.
        let color = Theme.current == .classic ? NSColor(srgbRed:1,green:112/255,blue:102/255,alpha:opacity) : (Theme.current == .softSeal ? NSColor(rgb:0xFFF3DF) : Theme.isInterface ? Theme.adaptive(InterfaceColors.failure) : Theme.nativeColor(\.danger)).withAlphaComponent(opacity)
        color.setFill()
        let stem = NSRect(x: bounds.midX - 1, y: bounds.midY - 1,
                          width: 2, height: 7)
        NSBezierPath(roundedRect: stem, xRadius: 1, yRadius: 1).fill()
        let dot = NSRect(x: bounds.midX - 1, y: bounds.midY - 6,
                         width: 2, height: 2)
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawWarming(at time: CFTimeInterval, opacity: CGFloat) {
        let elapsed = max(0, time - (processingStartedAt ?? time))
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        for i in 0..<8 {
            let offset = 0.1375 * Double(7 - i)
            let progress = (elapsed + offset).truncatingRemainder(dividingBy: 1.1) / 1.1
            let rayOpacity = (0.88 + (0.15 - 0.88) * progress) * Double(opacity)
            Self.spinner.withAlphaComponent(CGFloat(rayOpacity)).setFill()
            let angle = CGFloat.pi / 2 - CGFloat(i) * CGFloat.pi / 4
            let rayCenter = NSPoint(x: center.x + 6 * cos(angle),
                                    y: center.y + 6 * sin(angle))
            NSGraphicsContext.current?.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rayCenter.x, yBy: rayCenter.y)
            transform.rotate(byRadians: angle - CGFloat.pi / 2)
            transform.concat()
            NSBezierPath(roundedRect: NSRect(x: -1, y: -2.5, width: 2, height: 5),
                         xRadius: 1, yRadius: 1).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    private func drawReady(opacity: CGFloat) {
        (Theme.current == .classic ? NSColor(srgbRed:105/255,green:214/255,blue:143/255,alpha:1) : Theme.current == .softSeal ? NSColor(rgb:0xFFF3DF) : Theme.isInterface ? Theme.adaptive(InterfaceColors.ok)
            : Theme.current == .settle ? Theme.adaptive(SettleColors.line) : Theme.nativeColor(\.success)).withAlphaComponent(opacity).setStroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY))
        check.line(to: NSPoint(x: bounds.midX - 1.5, y: bounds.midY - 4))
        check.line(to: NSPoint(x: bounds.midX + 7, y: bounds.midY + 5))
        check.lineWidth = 2.5
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }

    private func themedShape(_ rect: NSRect, theme: AppTheme) -> NSBezierPath {
        if theme == .softSeal {
            let lowerRight = min(rect.height/2,15), lowerLeft = min(rect.height/2,8)
            let k: CGFloat = 0.55228475
            let p=NSBezierPath(), x=rect.minX, y=rect.minY, w=rect.width, h=rect.height
            p.move(to:NSPoint(x:x+lowerLeft,y:y));p.line(to:NSPoint(x:x+w-lowerRight,y:y))
            p.curve(to:NSPoint(x:x+w,y:y+lowerRight),controlPoint1:NSPoint(x:x+w-lowerRight+lowerRight*k,y:y),controlPoint2:NSPoint(x:x+w,y:y+lowerRight-lowerRight*k))
            p.line(to:NSPoint(x:x+w,y:y+h-lowerLeft))
            p.curve(to:NSPoint(x:x+w-lowerLeft,y:y+h),controlPoint1:NSPoint(x:x+w,y:y+h-lowerLeft+lowerLeft*k),controlPoint2:NSPoint(x:x+w-lowerLeft+lowerLeft*k,y:y+h))
            p.line(to:NSPoint(x:x+lowerRight,y:y+h))
            p.curve(to:NSPoint(x:x,y:y+h-lowerRight),controlPoint1:NSPoint(x:x+lowerRight-lowerRight*k,y:y+h),controlPoint2:NSPoint(x:x,y:y+h-lowerRight+lowerRight*k))
            p.line(to:NSPoint(x:x,y:y+lowerLeft))
            p.curve(to:NSPoint(x:x+lowerLeft,y:y),controlPoint1:NSPoint(x:x,y:y+lowerLeft-lowerLeft*k),controlPoint2:NSPoint(x:x+lowerLeft-lowerLeft*k,y:y));p.close()
            return p
        }
        let radius = min(rect.height/2,theme == .interface || theme == .settle ? rect.height/2 : theme == .ceramic ? 11 : 12)
        return NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius)
    }

    private func drawThemed(at time: CFTimeInterval,theme:AppTheme) {
        let shape=themedShape(bounds,theme:theme)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let content:Phase
        if case .idle = phase { content=outgoing } else { content=phase }
        // Soft Seal's states differ by colour, not only by glyph: an olive seal for ready and an
        // oxblood seal for failure (cream marks at 4.9:1 and 7.0:1), returning to clay at rest.
        let sealState: NSColor? = switch content {
        case .ready: NSColor(rgb: 0x5F7045)
        case .failure: NSColor(rgb: 0x8A3A2A)
        default: nil
        }
        let background: NSColor
        switch theme {
        case .softSeal:
            let clay = NSColor(rgb: dark ? 0xA7694D : 0xB77356)
            background = sealState.flatMap { clay.blended(withFraction: morph, of: $0) } ?? clay
        case .ceramic: background = NSColor(rgb: dark ? 0x302C26 : 0xF8F5ED)
        case .interface: background = NSColor(rgb: dark ? InterfaceColors.surface.dark : InterfaceColors.surface.light)
        case .settle: background = NSColor(rgb: dark ? SettleColors.surface.dark : SettleColors.surface.light)
        default: background = NSColor(rgb: dark ? 0x2A2927 : 0xFAF9F5)
        }
        background.setFill();shape.fill()
        let border: NSColor
        if theme == .interface {
            // A quiet edge at rest; a 40% ring of the wave's blue (or the failure red) arrives as the capsule opens.
            let edge = NSColor(rgb: dark ? InterfaceColors.edge.dark : InterfaceColors.edge.light)
            let live: NSColor? = switch content {
            case .listening: background.blended(withFraction: 0.4, of: NSColor(rgb: dark ? InterfaceColors.wave.dark : InterfaceColors.wave.light))
            case .failure: NSColor(rgb: dark ? InterfaceColors.failure.dark : InterfaceColors.failure.light)
            default: nil
            }
            border = live.flatMap { edge.blended(withFraction: morph, of: $0) } ?? edge
        } else if theme == .anthropic {
            border = NSColor(rgb: dark ? 0x4F4D48 : 0xCFCCC1)
        } else if theme == .settle {
            border = NSColor(rgb: dark ? SettleColors.edge.dark : SettleColors.edge.light)
        } else {
            border = NSColor(rgb: dark ? 0x514B40 : 0xC9BFAE)
        }
        if !dark && !increaseContrast && (theme == .ceramic || theme == .anthropic || theme == .settle) {
            // Light porcelain, paper and Settle's white pills would vanish over a white page: a soft contact
            // shade along the inner bottom edge lifts them, under the firmer edge drawn next.
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            let lip = themedShape(bounds.offsetBy(dx: 0, dy: 1), theme: theme)
            lip.lineWidth = 2
            NSColor(srgbRed: 48/255, green: 44/255, blue: 40/255, alpha: 0.14).setStroke(); lip.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if theme != .softSeal || increaseContrast {
            let baseBorder = increaseContrast ? (theme == .softSeal ? NSColor.white : Theme.nativeColor(\.ink)) : border
            let tintedBorder = modeBadge.flatMap { baseBorder.blended(withFraction: 0.48 * morph, of: $0.tintColor) } ?? baseBorder
            tintedBorder.setStroke()
            let outline = themedShape(bounds.insetBy(dx: 0.5, dy: 0.5), theme: theme)
            outline.lineWidth = 1
            outline.stroke()
        } else if let badge = modeBadge, morph > 0.25 {
            badge.tintColor.withAlphaComponent(0.55 * morph).setStroke()
            let rim = themedShape(bounds.insetBy(dx: 0.5, dy: 0.5), theme: theme)
            rim.lineWidth = 1
            rim.stroke()
        } else if dark && sealState != nil {
            // Olive and oxblood are darker than clay: a faint cream rim keeps the seal's edge on dark desktops.
            NSColor(rgb: 0xFFF3DF).withAlphaComponent(0.4 * morph).setStroke()
            let rim = themedShape(bounds.insetBy(dx: 0.5, dy: 0.5), theme: theme)
            rim.lineWidth = 1
            rim.stroke()
        }
        let opacity=morph
        let ink = theme == .anthropic ? Theme.brand : theme == .interface ? NSColor(rgb: dark ? InterfaceColors.wave.dark : InterfaceColors.wave.light)
            : theme == .settle ? NSColor(rgb: dark ? SettleColors.line.dark : SettleColors.line.light)
            : NSColor(rgb: theme == .softSeal ? 0xFFF3DF : dark ? 0xE39B7D : 0xB35738)
        guard opacity > 0.02 else {
            // Interface rests as a plain capsule, like its idle pane chrome.
            if theme == .interface { return }
            ink.setFill()
            if theme == .ceramic { NSBezierPath(ovalIn:NSRect(x:bounds.midX-1.5,y:bounds.midY-1.5,width:3,height:3)).fill() }
            else { NSBezierPath(roundedRect:NSRect(x:bounds.midX-4,y:bounds.midY-1,width:8,height:2),xRadius:1,yRadius:1).fill() }
            return
        }
        NSGraphicsContext.saveGraphicsState();shape.addClip()
        switch content {
        case .listening:
            let heights = voiceHeights(for: theme)
            ink.withAlphaComponent(opacity).setFill()
            if theme == .settle, let context = NSGraphicsContext.current?.cgContext {
                strokeSettle(SettleWave.line(center: CGPoint(x: bounds.midX, y: bounds.midY), trail: trail, reducedMotion: reduceMotion),
                             in: context, color: ink.withAlphaComponent(opacity))
            } else if theme == .anthropic, let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: bounds.midX - 27, y: bounds.midY + 16)
                context.scaleBy(x: 1, y: -1)
                for (index, height) in heights.enumerated() {
                    context.addPath(InkWaveformGeometry.stroke(index: index, height: height, weight: InkWaveformGeometry.pillWeight))
                }
                context.fillPath()
                context.restoreGState()
            } else {
                let layout = VoiceStrokeLayout.forTheme(theme)
                let total = CGFloat(layout.count) * layout.width + CGFloat(layout.count - 1) * layout.gap
                for (index, height) in heights.enumerated() {
                    let rect = NSRect(x: bounds.midX - total / 2 + CGFloat(index) * (layout.width + layout.gap),
                                      y: bounds.midY - height / 2, width: layout.width, height: height)
                    NSBezierPath(roundedRect: rect, xRadius: layout.width / 2, yRadius: layout.width / 2).fill()
                }
            }
            if pinned {
                ink.withAlphaComponent(opacity).setFill()
                // Interface's and Settle's full capsules clip the corner, so their hands-free dot leads the wave.
                NSBezierPath(ovalIn:theme == .interface ? NSRect(x:bounds.midX-22,y:bounds.midY-1.5,width:3,height:3)
                             : theme == .settle ? NSRect(x:bounds.midX-SettleWave.width/2-6.5,y:bounds.midY-1.5,width:3,height:3)
                             : NSRect(x:3.5,y:3.5,width:2.5,height:2.5)).fill()
            }
        case .thinking,.warming:
            let elapsed=reduceMotion ? 0 : time-(processingStartedAt ?? time)
            if theme == .settle, let context = NSGraphicsContext.current?.cgContext {
                strokeSettle(SettleWave.working(center: CGPoint(x: bounds.midX, y: bounds.midY), elapsed: elapsed, reducedMotion: reduceMotion),
                             in: context, color: ink.withAlphaComponent((reduceMotion ? 0.7 : 1) * opacity))
            } else if theme == .interface {
                let dots = Theme.nativeColor(\.ink)
                for dot in 0..<InterfaceTicker.count {
                    dots.withAlphaComponent(InterfaceTicker.alpha(dot:dot,elapsed:elapsed,reducedMotion:reduceMotion)*opacity).setFill()
                    let at = InterfaceTicker.offset(dot:dot,radius:5.5)
                    NSBezierPath(ovalIn:NSRect(x:bounds.midX+at.x-1.5,y:bounds.midY+at.y-1.5,width:3,height:3)).fill()
                }
            } else if theme == .ceramic {
                for i in 0..<16 {
                    let diagonal=Double(i%4+i/4)
                    let glow=reduceMotion ? (i%5 == 0 ? 1.0 : 0.2) : 0.2+0.8*pow(max(0,sin(elapsed*3-diagonal*0.7)),2)
                    ink.withAlphaComponent(glow*Double(opacity)).setFill()
                    NSBezierPath(ovalIn:NSRect(x:bounds.midX+CGFloat(i%4)*5.2-9.3,y:bounds.midY+CGFloat(i/4)*5.2-9.3,width:3,height:3)).fill()
                }
            } else {
                for i in 0..<3 {
                    let alpha=reduceMotion ? 0.7 : 0.35+0.65*(sin(elapsed*4-Double(i)*0.9)+1)/2
                    ink.withAlphaComponent(alpha*Double(opacity)).setFill()
                    NSBezierPath(ovalIn:NSRect(x:bounds.midX+CGFloat(i-1)*7-1.5,y:bounds.midY-1.5,width:3,height:3)).fill()
                }
            }
        case .ready: drawReady(opacity:opacity)
        case .failure: drawFailure(opacity:opacity)
        case .idle: break
        }
        drawModeAndHoverAccessories(opacity: opacity, darkSurface: dark || theme == .softSeal)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func strokeSettle(_ line: CGPath, in context: CGContext, color: NSColor) {
        context.addPath(line)
        context.setLineWidth(SettleWave.weight)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
    }

    private func drawModeAndHoverAccessories(opacity: CGFloat, darkSurface: Bool) {
        if let badge = modeBadge, opacity > 0.45, bounds.width >= 52 {
            let accent = badge.tintColor.withAlphaComponent(0.90 * opacity)
            accent.setFill()
            let indicator = NSRect(x: 6.5, y: bounds.midY - 4.5, width: 2.5, height: 9)
            NSBezierPath(roundedRect: indicator, xRadius: 1.25, yRadius: 1.25).fill()
        }
        guard isHovering, let cancelRect = cancelHitRect else { return }
        let baseFg: NSColor = darkSurface ? .white : Theme.nativeColor(\.ink)
        baseFg.withAlphaComponent(isHoveringCancel ? 0.22 : 0.12).setFill()
        NSBezierPath(ovalIn: cancelRect).fill()
        let xPath = NSBezierPath()
        let inset: CGFloat = 4.2
        xPath.move(to: NSPoint(x: cancelRect.minX + inset, y: cancelRect.minY + inset))
        xPath.line(to: NSPoint(x: cancelRect.maxX - inset, y: cancelRect.maxY - inset))
        xPath.move(to: NSPoint(x: cancelRect.minX + inset, y: cancelRect.maxY - inset))
        xPath.line(to: NSPoint(x: cancelRect.maxX - inset, y: cancelRect.minY + inset))
        xPath.lineWidth = 1.4
        xPath.lineCapStyle = .round
        baseFg.withAlphaComponent(isHoveringCancel ? 0.95 : 0.72).setStroke()
        xPath.stroke()
    }

    override func draw(_ dirty: NSRect) {
        let t = reduceMotion ? 0 : CACurrentMediaTime()
        if Theme.current != .classic { drawThemed(at:t,theme:Theme.current); return }
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)

        // Listening and processing share Wispr's black, outlined pill chrome. The resting
        // bar is the same chrome at idleAlpha; in between, the two blend by size.
        let morph = morph
        let chrome = reduceTransparency ? 1 : Self.idleAlpha + (1 - Self.idleAlpha) * morph
        NSColor.black.withAlphaComponent(chrome).setFill()
        pill.fill()
        // Dark appearance: the open capsule keeps a visible edge (≈#3D3D3D, white at ~24% over
        // the black body) so it does not dissolve into dark apps. Light keeps Wispr's hairline.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let baseOutline = increaseContrast ? NSColor.white
            : dark ? NSColor(white: 0.55, alpha: 1).blended(withFraction: morph, of: NSColor(srgbRed: 0.24, green: 0.24, blue: 0.24, alpha: 1)) ?? NSColor(white: 0.24, alpha: 1)
            : NSColor(white: 0.55 - 0.36 * morph, alpha: 1)
        let outline = modeBadge.flatMap { baseOutline.blended(withFraction: 0.50 * morph, of: $0.tintColor) } ?? baseOutline
        outline.setStroke()
        let borderBounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: borderBounds,
                                  xRadius: borderBounds.height / 2,
                                  yRadius: borderBounds.height / 2)
        border.lineWidth = 1
        border.stroke()
        guard morph > 0 else { return }

        // Content fades with the morph: in as the capsule opens, out as it collapses.
        let content: Phase
        if case .idle = phase { content = outgoing } else { content = phase }
        NSGraphicsContext.current?.saveGraphicsState()
        pill.addClip()
        switch content {
        case .listening:
            drawListeningBars(at: t, opacity: morph)
            if pinned { drawPinnedDot(opacity: morph) }
        case .thinking:
            // Wispr swaps the content immediately; only the outer capsule width
            // morphs over 100ms, so no ghost waveform or spinner fade is introduced.
            drawProcessing(at: t, opacity: morph)
        case .warming:
            drawWarming(at: t, opacity: morph)
        case .ready:
            drawReady(opacity: morph)
        case .failure:
            drawFailure(opacity: morph)
        case .idle:
            break
        }
        drawModeAndHoverAccessories(opacity: morph, darkSurface: true)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// The live transcript, in its own rounded box ABOVE the capsule. Deliberately not
/// inside the pill: drawn there it scrolls across the waveform and covers it.
@MainActor
final class TranscriptView: NSView {
    var text = "" { didSet { if text != oldValue { cachedLayout = nil; needsDisplay = true } } }
    private var cachedLayout: (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)?
    /// Flipped so y grows downward, which makes the overflow offset below read directly.
    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { !text.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Live dictation transcript" }
    override func accessibilityValue() -> Any? { text }

    static let maxWidth: CGFloat = 340
    /// About four readable lines; overflow reserves a small marker above the newest words.
    static let maxHeight: CGFloat = 98
    static let padding: CGFloat = 10
    /// Space between the capsule and the transcript box.
    static let gap: CGFloat = 8
    /// Classic's pill keeps the system face for live text; the window's book serif stays in the window.
    private static var font: NSFont { Theme.current == .classic ? .systemFont(ofSize: 13) : Theme.nativeWritingFont(13) }
    func refreshAppearance() { cachedLayout = nil; needsDisplay = true }

    private static func attributed(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 3
        return NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: Theme.current == .classic ? NSColor.white.withAlphaComponent(0.95) : Theme.nativeColor(\.ink),
            .paragraphStyle: p,
        ])
    }

    /// Wrapped height at the fixed text width, uncapped.
    static func textHeight(_ s: String) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return ceil(attributed(s).boundingRect(
            with: NSSize(width: maxWidth - padding * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// The box's size, capped. Zero when there is nothing to show, which is what collapses
    /// the panel back to a bare capsule.
    static func size(for s: String) -> NSSize {
        guard !s.isEmpty else { return .zero }
        return NSSize(width: maxWidth, height: min(maxHeight, textHeight(s) + padding * 2))
    }

    override func draw(_ dirty: NSRect) {
        guard !text.isEmpty else { return }
        (Theme.current == .classic ? NSColor.black : Theme.nativeColor(\.ground)).setFill()
        let box = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        box.fill()
        (Theme.current == .classic ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.white : PillView.border) : Theme.nativeColor(\.stroke,contrast:true)).setStroke()
        let inner = bounds.insetBy(dx: 0.5, dy: 0.5)
        let stroke = NSBezierPath(roundedRect: inner, xRadius: 12, yRadius: 12)
        stroke.lineWidth = 1
        stroke.stroke()

        // Cache text layout until the partial changes. Draw only complete newest lines;
        // the overflow marker must never sit above a half-clipped line of older speech.
        if cachedLayout == nil {
            let storage = NSTextStorage(attributedString: Self.attributed(text))
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: Self.maxWidth - Self.padding * 2,
                                                         height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container); storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
            cachedLayout = (storage, manager, container)
        }
        guard let layout = cachedLayout else { return }
        let range = layout.manager.glyphRange(for: layout.container)
        let full = layout.manager.usedRect(for: layout.container).height
        let overflowing = full > bounds.height - Self.padding * 2
        let top = overflowing ? Self.padding + 10 : Self.padding
        if overflowing {
            NSAttributedString(string: "···", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: Theme.current == .classic ? NSColor.lightGray : Theme.nativeColor(\.muted)]).draw(at: NSPoint(x: Self.padding, y: 1))
        }
        let available = bounds.height - top - Self.padding
        var firstY: CGFloat = 0
        var visibleRange = range
        if overflowing {
            layout.manager.enumerateLineFragments(forGlyphRange: range) { rect, _, _, glyphs, stop in
                if full - rect.minY <= available {
                    firstY = rect.minY
                    visibleRange = NSRange(location: glyphs.location, length: NSMaxRange(range) - glyphs.location)
                    stop.pointee = true
                }
            }
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: Self.padding, y: top, width: bounds.width - Self.padding * 2, height: available)).addClip()
        layout.manager.drawGlyphs(forGlyphRange: visibleRange, at: NSPoint(x: Self.padding, y: top - firstY))
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// Non-activating inline recovery / status banner displayed above the pill instead of silent
/// provisional Notification Center banners. Clicking copies `copyText` when present.
@MainActor
final class RecoveryBannerView: NSView {
    var message = "" { didSet { if message != oldValue { needsDisplay = true } } }
    var copyText: String? { didSet { if copyText != oldValue { needsDisplay = true } } }
    var onActivate: (() -> Void)?

    static let maxWidth: CGFloat = 340
    static let paddingH: CGFloat = 12
    static let paddingV: CGFloat = 8
    static let gap: CGFloat = 8

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onActivate?() }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if !message.isEmpty {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func isAccessibilityElement() -> Bool { !message.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { copyText != nil ? .button : .staticText }
    override func accessibilityLabel() -> String? { "FlowClone recovery notice" }
    override func accessibilityValue() -> Any? { message }
    override func accessibilityPerformPress() -> Bool {
        guard !message.isEmpty else { return false }
        onActivate?()
        return true
    }

    private static var font: NSFont { .systemFont(ofSize: 12, weight: .medium) }

    private static func attributed(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        return NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: Theme.current == .classic ? NSColor.white.withAlphaComponent(0.95) : Theme.nativeColor(\.ink),
            .paragraphStyle: p,
        ])
    }

    static func size(for message: String, hasCopy: Bool) -> NSSize {
        guard !message.isEmpty else { return .zero }
        let badgeAllowance: CGFloat = hasCopy ? 58 : 0
        let availableWidth = maxWidth - paddingH * 2 - badgeAllowance
        let rect = attributed(message).boundingRect(
            with: NSSize(width: availableWidth, height: 80),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = min(maxWidth, max(190, ceil(rect.width) + paddingH * 2 + badgeAllowance + 6))
        let height = min(72, max(32, ceil(rect.height) + paddingV * 2))
        return NSSize(width: width, height: height)
    }

    override func draw(_ dirty: NSRect) {
        guard !message.isEmpty else { return }
        (Theme.current == .classic ? NSColor.black.withAlphaComponent(0.94) : Theme.nativeColor(\.ground)).setFill()
        let box = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        box.fill()
        let strokeColor: NSColor = Theme.current == .classic
            ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .white : PillView.border)
            : Theme.nativeColor(\.stroke, contrast: true)
        strokeColor.setStroke()
        let inner = bounds.insetBy(dx: 0.5, dy: 0.5)
        let stroke = NSBezierPath(roundedRect: inner, xRadius: 11, yRadius: 11)
        stroke.lineWidth = 1
        stroke.stroke()

        let hasCopy = copyText != nil
        let badgeAllowance: CGFloat = hasCopy ? 56 : 0
        let textRect = NSRect(
            x: Self.paddingH,
            y: Self.paddingV - 1,
            width: max(40, bounds.width - Self.paddingH * 2 - badgeAllowance),
            height: max(14, bounds.height - Self.paddingV * 2 + 2)
        )
        Self.attributed(message).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if hasCopy {
            let pillRect = NSRect(x: bounds.maxX - Self.paddingH - 48, y: bounds.midY - 10, width: 48, height: 20)
            let accent = Theme.current == .classic
                ? NSColor.white.withAlphaComponent(0.16)
                : Theme.nativeColor(\.accent).withAlphaComponent(0.16)
            accent.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()
            let label = NSAttributedString(string: "Copy", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Theme.current == .classic ? NSColor.white : Theme.nativeColor(\.ink),
            ])
            let ls = label.size()
            label.draw(at: NSPoint(x: pillRect.midX - ls.width / 2, y: pillRect.midY - ls.height / 2))
        }
    }
}

@MainActor
private final class PillMenuTarget: NSObject {
    var onSelectMode: ((Mode) -> Void)?
    var onStartInPersonMeeting: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHideIdlePill: (() -> Void)?

    @objc func selectClean() { onSelectMode?(.clean) }
    @objc func selectPrompt() { onSelectMode?(.prompt) }
    @objc func selectLiteral() { onSelectMode?(.raw) }
    @objc func startInPersonMeeting() { onStartInPersonMeeting?() }
    @objc func startMeeting() { onStartMeeting?() }
    @objc func openApp() { onOpenApp?() }
    @objc func cancelCapture() { onCancel?() }
    @objc func hideIdlePill() { onHideIdlePill?() }
}

/// Stacks the transcript above the capsule. `targetFrame` pins the panel's BOTTOM edge, so
/// the capsule at y=0 stays exactly where it was while extra height grows upward.
@MainActor
final class OverlayContent: NSView {
    let pill = PillView()
    let transcript = TranscriptView()
    let recovery = RecoveryBannerView()
    var pillSize = NSSize(width: 73, height: 30) { didSet { needsLayout = true } }
    var pillCenterX: CGFloat? { didSet { if pillCenterX != oldValue { needsLayout = true } } }
    var transcriptAbove = true { didSet { if transcriptAbove != oldValue { needsLayout = true } } }

    init() {
        super.init(frame: .zero)
        addSubview(transcript)
        addSubview(recovery)
        addSubview(pill)
        recovery.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        // Without a transcript or recovery banner the panel IS the capsule, so the capsule
        // tracks the panel's CURRENT size and an animated resize morphs it.
        let hasTranscript = !transcript.text.isEmpty
        let hasRecovery = !recovery.message.isEmpty
        let bare = !hasTranscript && !hasRecovery
        let pw = bare ? bounds.width : pillSize.width
        let ph = bare ? bounds.height : pillSize.height
        let centerX = bare ? bounds.midX : (pillCenterX ?? bounds.midX)
        let frame = NSRect(x: min(max(0, centerX - pw / 2), max(0, bounds.width - pw)).rounded(),
                           y: bare || transcriptAbove ? 0 : bounds.height - ph, width: pw, height: ph)
        if pill.frame != frame {
            pill.frame = frame
            pill.needsDisplay = true
        }
        let recoverySize = RecoveryBannerView.size(for: recovery.message, hasCopy: recovery.copyText != nil)
        recovery.isHidden = !hasRecovery
        if !hasRecovery {
            recovery.frame = .zero
            let h = max(0, bounds.height - pillSize.height - TranscriptView.gap)
            let w = min(bounds.width, TranscriptView.maxWidth)
            transcript.frame = NSRect(x: ((bounds.width - w) / 2).rounded(),
                                      y: transcriptAbove ? pillSize.height + TranscriptView.gap : 0, width: w, height: h)
        } else {
            let transcriptSize = TranscriptView.size(for: transcript.text)
            let rw = min(bounds.width, recoverySize.width)
            let tw = min(bounds.width, TranscriptView.maxWidth)
            if transcriptAbove {
                var cursorY = pillSize.height + TranscriptView.gap
                if hasTranscript {
                    transcript.frame = NSRect(x: ((bounds.width - tw) / 2).rounded(), y: cursorY, width: tw, height: transcriptSize.height)
                    cursorY += transcriptSize.height + RecoveryBannerView.gap
                } else {
                    transcript.frame = .zero
                }
                recovery.frame = NSRect(x: ((bounds.width - rw) / 2).rounded(), y: cursorY, width: rw, height: recoverySize.height)
            } else {
                var cursorY: CGFloat = 0
                recovery.frame = NSRect(x: ((bounds.width - rw) / 2).rounded(), y: cursorY, width: rw, height: recoverySize.height)
                cursorY += recoverySize.height + RecoveryBannerView.gap
                if hasTranscript {
                    transcript.frame = NSRect(x: ((bounds.width - tw) / 2).rounded(), y: cursorY, width: tw, height: transcriptSize.height)
                } else {
                    transcript.frame = .zero
                }
            }
        }
    }
}

@MainActor
final class Overlay {
    static let shared = Overlay()
    static let frontWindowQueryMinInterval: CFTimeInterval = 0.25
    static let defaultRecoveryDuration: TimeInterval = 3.5
    private nonisolated static let publishedWindowNumber = OSAllocatedUnfairLock(initialState: Int64(0))
    nonisolated static var currentWindowNumber: Int64 { publishedWindowNumber.withLock { $0 } }

    /// Returns true when a global mouse event landed on FlowClone's own `.nonactivatingPanel`
    /// Pill HUD, which never activates FlowClone or alters focus in the target application.
    nonisolated static func isNonActivatingOverlayMouseEvent(_ event: CGEvent) -> Bool {
        let targetWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        guard targetWindow > 0 else { return false }
        return targetWindow == publishedWindowNumber.withLock { $0 }
    }

    /// Interactive Pill HUD hooks (wired by AppRuntime and available to Pipeline / Integrator).
    var onStartHandsFree: (() -> Void)?
    var onFinishCapture: (() -> Void)?
    var onCancelCapture: (() -> Void)?
    var onStartNewMeeting: (() -> Void)?
    var onOpenMainWindow: (() -> Void)?

    /// Window bounds query seam & throttle metrics for frontWindowScreen().
    var windowBoundsProvider: ((pid_t) -> CGRect?)?
    private(set) var frontWindowQueryCount = 0
    private var cachedFrontWindowScreen: (at: CFTimeInterval, pid: pid_t, screen: NSScreen?)?

    private let menuTarget = PillMenuTarget()
    private var explicitModeBadge: PillModeBadge?
    private var recoveryTimer: Timer?

    var activeRecoveryMessage: String? {
        content.recovery.message.isEmpty ? nil : content.recovery.message
    }
    var activeRecoveryCopyText: String? {
        content.recovery.copyText
    }
    /// Live partial text in the pill. Default ON; the status menu toggles it.
    /// `defaults write com.andre.flowclone livePartialText -bool false` also works.
    nonisolated static var livePartialEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "livePartialText") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "livePartialText") }
    }

    /// Wispr's idle bar: a small translucent capsule that stays at the chosen position
    /// between dictations. Default ON; the status menu toggles it.
    /// `defaults write com.andre.flowclone idlePill -bool false` also works.
    nonisolated static var idlePillEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "idlePill") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "idlePill") }
    }

    private static var recordingSize: NSSize { Theme.current.activeSize }
    private static var processingSize: NSSize { Theme.current.processingSize }
    private static var idleSize: NSSize { Theme.current.idleSize }
    /// In-session width changes keep Wispr's 100ms; the open/collapse at the idle boundary
    /// covers far more ground and reads as a jump at that speed.
    private static let idleMorphDuration = 0.18

    /// var, not let: the strand recovery in reconcile() discards a panel whose
    /// server-side state is corrupt and continues the session on a fresh one.
    private var panel: Pill
    private let content = OverlayContent()
    private var view: PillView { content.pill }
    private let positionDefaults: UserDefaults
    private var savedPosition: PillPosition?
    private var dragStart: (mouse: NSPoint, anchor: NSPoint)?
    private var dragAnchor: NSPoint?
    private let dockTracker = DockTracker()
    private var dockFrame: NSRect?
    private var suppressDockTracking = false
    // Read the live screen pointer: queued window-relative events become stale as
    // this panel moves. The in-process probe substitutes a controlled pointer.
    private var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// The capsule's own size. The PANEL is this plus whatever the transcript needs.
    private var pillSize = Overlay.recordingSize
    /// Where the panel is heading. An animated resize is judged against THIS, not the live
    /// frame: a reverse requested before the outbound animation has moved (press, then
    /// cancel within a frame) read the live frame as "already there", skipped, and let the
    /// outbound animation park the idle bar at full size.
    private var intendedFrame = NSRect.zero
    /// Drives animated resizes at 60Hz. Not the window animator: two animator resizes started
    /// in one run-loop turn coalesced into a no-op with no ticks, leaving the capsule view out
    /// of step with the panel, and its deferred start made the morph impossible to sample.
    /// This ticks every frame and is superseded by a generation bump.
    private var resizeDriver: Timer?
    private var resizeGen = 0
    private var animationTimer: Timer?
    private var watchdogTimer: Timer?
    private var fadeGen = 0
    /// What we INTEND to be on screen. The window server can disagree — a Space switch or
    /// a full-screen transition can order a floating panel out from under us, and a session
    /// already in progress has no other trigger to re-show it. Reconciled by the watchdog.
    private var showing = false
    private var loggedEviction = false
    private var presentedAt = CACurrentMediaTime()
    private var loggedAlphaStuck = false
    private var loggedOcclusion = false
    private var occlusionRecoveryAttempts = 0
    private var lastOcclusionRecoveryAt: CFTimeInterval = 0
    /// One panel rebuild per present(): a pill that is GENUINELY covered (screen locked,
    /// a real higher-level overlay) must not churn window identities forever.
    private var rebuiltPanelThisSession = false
    /// Held while the pill is intended-visible. Without it App Nap coalesces this
    /// windowless accessory's timers — measured 0.84s of drift in one stress run —
    /// which stalls the fade-in animation and the 60fps clock: the pill sits ordered-in
    /// at alpha 0 (the 2026-08-03 21:16 recurrence). userInitiated (idle-sleep-allowing:
    /// a leaked assertion must never pin the Mac awake) lifts nap; latencyCritical lifts
    /// timer coalescing for the live audio session.
    private var activity: NSObjectProtocol?

    private init() {
        positionDefaults = ProcessInfo.processInfo.arguments.contains("--theme-preview")
            ? UserDefaults(suiteName: "com.andre.flowclone.theme-preview")! : .standard
        savedPosition = PillPosition.load(from: positionDefaults)
        panel = Self.makePanel()
        panel.contentView = content
        view.toolTip = "Click to dictate or finish. Right-click for options. Drag to move."
        view.onDragBegan = { [weak self] in self?.beginDrag($0) }
        view.onDragged = { [weak self] in self?.drag($0) }
        view.onDragEnded = { [weak self] in self?.endDrag($0) }
        view.onContextMenu = { [weak self] _ in self?.buildContextMenu() }
        view.onAccessibilityPress = { [weak self] in self?.handlePrimaryPillAction() ?? false }
        content.recovery.onActivate = { [weak self] in self?.handleRecoveryBannerActivated() }
        menuTarget.onSelectMode = { [weak self] mode in
            Mode.set(mode)
            self?.refreshModeBadge()
        }
        menuTarget.onStartInPersonMeeting = {
            MainWindow.shared.show(.meetings)
            Task { _ = await MeetingCoordinator.shared.startInPersonMeeting() }
        }
        menuTarget.onStartMeeting = { [weak self] in
            if let handler = self?.onStartNewMeeting {
                handler()
            } else {
                MainWindow.shared.show(.meetings)
                Task { _ = await MeetingCoordinator.shared.startAdHocMeeting() }
            }
        }
        menuTarget.onOpenApp = { [weak self] in
            if let handler = self?.onOpenMainWindow {
                handler()
            } else {
                MainWindow.shared.show()
            }
        }
        menuTarget.onCancel = { [weak self] in self?.onCancelCapture?() }
        menuTarget.onHideIdlePill = { [weak self] in
            Self.idlePillEnabled = false
            self?.applyIdleSetting()
        }
        dockTracker.onChange = { [weak self] in self?.dockPositionChanged($0) }
        NotificationCenter.default.addObserver(forName:AppearanceStore.didChange,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.applyTheme() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.view.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                self.view.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                self.content.transcript.needsDisplay = true
                self.content.recovery.needsDisplay = true
                if self.view.reduceMotion {
                    self.resizeDriver?.invalidate(); self.resizeDriver = nil
                    self.panel.setFrame(self.intendedFrame, display: true)
                }
                self.updateAnimationClock()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cachedFrontWindowScreen = nil
                self?.place()
                self?.updateDockTracking()
                self?.dockTracker.refresh()
            }
        }
    }

    /// Every window-server-facing setting in one place, because the strand recovery in
    /// reconcile() must be able to recreate the panel EXACTLY as first built.
    private static func makePanel() -> Pill {
        let panel = Pill(contentRect: NSRect(origin: .zero, size: recordingSize),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // This is a system-wide overlay, not a palette for FlowClone's own windows.
        // `floating` sits below the Dock and other apps' full-screen surfaces; on macOS
        // 27 that left the panel ordered-in with alpha 1 yet fully occluded. Apple's
        // cross-app overlay recipe uses screenSaver + canJoinAllApplications.
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
        ]
        panel.ignoresMouseEvents = false
        panel.isMovable = false                 // only the capsule's explicit drag handler moves it
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear            // the rounded rect itself is opaque
        // Discarded panels are dropped, never close()d; keep ARC the sole owner.
        panel.isReleasedWhenClosed = false
        let windowNumber = Int64(panel.windowNumber)
        publishedWindowNumber.withLock { $0 = windowNumber }
        return panel
    }

    /// Restyle the existing panel without resetting capture, focus, or phase epochs.
    private func applyTheme() {
        switch view.phase {
        case .idle: pillSize = Self.idleSize
        case .thinking: pillSize = Self.processingSize
        default: pillSize = Self.recordingSize
        }
        content.pillSize = pillSize
        content.transcript.refreshAppearance()
        view.needsDisplay = true
        resize(to:panelSize(pill:pillSize),animated:false)
        updateAnimationClock()
    }

    func setModeBadge(_ badge: PillModeBadge?) {
        explicitModeBadge = badge
        refreshModeBadge()
    }

    func resolvedModeBadge() -> PillModeBadge? {
        if let explicitModeBadge { return explicitModeBadge }
        switch DictationWorkspace.shared.captureLabel {
        case "Draft":
            return .draft
        case "Spelling":
            return .spelling
        case "Literal text":
            return .literal
        default:
            switch Mode.current {
            case .prompt: return .prompt
            case .raw: return .literal
            case .clean: return nil
            }
        }
    }

    func refreshModeBadge() {
        if case .idle = view.phase {
            view.modeBadge = nil
        } else {
            view.modeBadge = resolvedModeBadge()
        }
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "FlowClone Pill")
        menu.autoenablesItems = false

        let modeHeader = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)

        let currentMode = Mode.current
        let cleanItem = NSMenuItem(title: "Clean", action: #selector(PillMenuTarget.selectClean), keyEquivalent: "")
        cleanItem.target = menuTarget
        cleanItem.state = currentMode == .clean ? .on : .off
        menu.addItem(cleanItem)

        let promptItem = NSMenuItem(title: "Prompt", action: #selector(PillMenuTarget.selectPrompt), keyEquivalent: "")
        promptItem.target = menuTarget
        promptItem.state = currentMode == .prompt ? .on : .off
        menu.addItem(promptItem)

        let literalItem = NSMenuItem(title: "Literal", action: #selector(PillMenuTarget.selectLiteral), keyEquivalent: "")
        literalItem.target = menuTarget
        literalItem.state = currentMode == .raw ? .on : .off
        menu.addItem(literalItem)

        menu.addItem(.separator())

        let canStartMeeting = !MeetingCoordinator.shared.busy && !MeetingCoordinator.shared.isImporting
        let inPersonItem = NSMenuItem(title: "Start In-Person Meeting", action: #selector(PillMenuTarget.startInPersonMeeting), keyEquivalent: "")
        inPersonItem.target = menuTarget
        inPersonItem.isEnabled = canStartMeeting
        menu.addItem(inPersonItem)

        let meetingItem = NSMenuItem(title: "Start New Meeting Note", action: #selector(PillMenuTarget.startMeeting), keyEquivalent: "")
        meetingItem.target = menuTarget
        meetingItem.isEnabled = canStartMeeting
        menu.addItem(meetingItem)

        let openItem = NSMenuItem(title: "Open FlowClone", action: #selector(PillMenuTarget.openApp), keyEquivalent: "")
        openItem.target = menuTarget
        menu.addItem(openItem)

        if showing {
            let cancelItem = NSMenuItem(title: "Cancel", action: #selector(PillMenuTarget.cancelCapture), keyEquivalent: "")
            cancelItem.target = menuTarget
            menu.addItem(cancelItem)
        }

        menu.addItem(.separator())

        let hideItem = NSMenuItem(title: "Hide Idle Pill", action: #selector(PillMenuTarget.hideIdlePill), keyEquivalent: "")
        hideItem.target = menuTarget
        hideItem.isEnabled = Self.idlePillEnabled
        menu.addItem(hideItem)

        return menu
    }

    var suppressPresentationForTesting = false
    var copyWriterForTesting: ((String) -> Void)?

    /// Shows a non-activating 3.5s banner above the pill (for paste recovery or dictation
    /// errors) without ever stealing keyboard focus from the user's target application.
    func showRecoveryNotice(_ message: String, copyText: String? = nil,
                            duration: TimeInterval = Overlay.defaultRecoveryDuration) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        content.recovery.message = trimmed
        content.recovery.copyText = copyText
        content.recovery.isHidden = false
        content.needsLayout = true

        if !suppressPresentationForTesting {
            if !showing {
                let baseSize = Self.idlePillEnabled ? Self.idleSize : NSSize(width: 40, height: 8)
                pillSize = baseSize
                content.pillSize = baseSize
                view.beginIdle()
                resize(to: panelSize(pill: baseSize), animated: false)
                place()
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            } else {
                resize(to: panelSize(pill: pillSize), animated: true)
            }
        }

        let timer = Timer(timeInterval: max(0.2, duration), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissRecoveryNotice()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recoveryTimer = timer
    }

    func dismissRecoveryNotice() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        guard !content.recovery.message.isEmpty || content.recovery.copyText != nil else { return }
        content.recovery.message = ""
        content.recovery.copyText = nil
        content.recovery.isHidden = true
        content.needsLayout = true
        guard !suppressPresentationForTesting else { return }
        if showing {
            resize(to: panelSize(pill: pillSize), animated: true)
        } else {
            hide()
        }
    }

    var panelIsNonActivating: Bool {
        panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain
    }

    func configurePhaseForTesting(listening: Bool) {
        showing = listening
        if listening {
            view.frame = NSRect(origin: .zero, size: Self.recordingSize)
            view.reset()
            view.modeBadge = resolvedModeBadge()
        } else {
            view.frame = NSRect(origin: .zero, size: Self.idleSize)
            view.beginIdle()
            view.modeBadge = nil
        }
    }

    @discardableResult
    func simulatePrimaryClickForTesting(onCancel: Bool = false) -> Bool {
        if onCancel, view.cancelHitRect != nil {
            onCancelCapture?()
            return onCancelCapture != nil
        }
        return handlePrimaryPillAction()
    }

    @discardableResult
    func triggerRecoveryCopyForTesting() -> Bool {
        handleRecoveryBannerActivated()
    }

    @discardableResult
    private func handleRecoveryBannerActivated() -> Bool {
        if let copyText = content.recovery.copyText, !copyText.isEmpty {
            if let copyWriterForTesting {
                copyWriterForTesting(copyText)
            } else {
                _ = Paster.writeTranscript(copyText)
            }
            showRecoveryNotice("Copied to clipboard — ⌘V to paste", copyText: nil, duration: 1.8)
            return true
        }
        dismissRecoveryNotice()
        return false
    }

    @discardableResult
    private func handlePrimaryPillAction() -> Bool {
        switch view.phase {
        case .idle:
            onStartHandsFree?()
            return onStartHandsFree != nil
        case .listening:
            onFinishCapture?()
            return onFinishCapture != nil
        default:
            return false
        }
    }

    func recording() {
        if !content.recovery.message.isEmpty {
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            content.recovery.message = ""
            content.recovery.copyText = nil
            content.recovery.isHidden = true
        }
        view.reset()
        view.modeBadge = resolvedModeBadge()
        present(size: Self.recordingSize)
    }

    func warming() {
        if !content.recovery.message.isEmpty {
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            content.recovery.message = ""
            content.recovery.copyText = nil
            content.recovery.isHidden = true
        }
        view.beginWarming()
        view.modeBadge = resolvedModeBadge()
        present(size: Self.recordingSize)
    }

    func transcribing() {
        view.beginProcessing(slow: false)
        present(size: Self.processingSize)
    }

    /// A Prompt rewrite continues the same processing chase without restarting its phase.
    func polishing() {
        view.beginProcessing(slow: true)
        present(size: Self.processingSize)
    }

    /// Brief, focus-safe visible feedback when the mic could not be opened or repaired.
    func failure() {
        view.beginFailure()
        present(size: Self.recordingSize)
        let generation = fadeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, generation == self.fadeGen else { return }
            if case .failure = self.view.phase { self.hide() }
        }
    }

    /// The route finished warming, but the press that began before it was ready
    /// cannot safely be treated as captured. Green check = release and press again.
    func ready() {
        view.beginReady()
        present(size: Self.recordingSize)
        let generation = fadeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, generation == self.fadeGen else { return }
            if case .ready = self.view.phase { self.hide() }
        }
    }

    /// F1: pinned hands-free cue on the listening pill, for a session that outlives the
    /// press that started it. Cleared unconditionally by hide(), so it cannot stick.
    func handsFree(_ on: Bool) {
        view.pinned = on
        view.needsDisplay = true
    }

    /// 0…1, already throttled by the Recorder; the animation timer does the redrawing.
    /// Live partial transcript while recording. Main thread. A no-op when the setting is
    /// off, so the decode side can stay ignorant of it. Widening only happens while the
    /// pill is actually listening — a partial arriving after release must not resize the
    /// processing pill out from under the thinking animation.
    func partial(_ text: String) {
        let shown = Self.livePartialEnabled ? text : ""
        guard view.isListening, content.transcript.text != shown else { return }
        content.transcript.text = shown
        resize(to: panelSize(pill: pillSize), animated: true)
    }

    /// Clears any partial text and returns the pill to its wordless width. Called at every
    /// session end, so a stale transcript can never outlive its recording.
    func clearPartial() {
        guard !content.transcript.text.isEmpty else { return }
        content.transcript.text = ""
        resize(to: panelSize(pill: pillSize), animated: false)
    }

    /// Capture selects the meter without changing the underlying recording pipeline.
    func capturedLevel(_ v: Float, responsive: Bool) {
        guard responsive == (Theme.current != .classic) else { return }
        level(v)
    }

    func level(_ v: Float, voice: Float? = nil) {
        guard panel.isVisible else { return }
        if case .listening = view.phase {
            view.push(v, voice: voice)
            updateAnimationClock()
        }
    }

    /// The session is over. Collapses into the idle bar when that is on, else leaves the
    /// screen. Also what launch calls, so the bar is there before the first press.
    func hide() {
        view.pinned = false
        explicitModeBadge = nil
        view.modeBadge = nil
        if Self.idlePillEnabled || !content.recovery.message.isEmpty { idle() } else { dismiss() }
    }

    /// The setting flipped in the menu. Only touches a resting pill — never a live session.
    func applyIdleSetting() {
        guard !showing else { return }
        hide()
    }

    /// Clear the saved anchor and restore the original bottom-center placement immediately.
    func resetPosition() {
        resizeGen += 1
        resizeDriver?.invalidate()
        resizeDriver = nil
        intendedFrame = panel.frame
        dragStart = nil
        dragAnchor = nil
        savedPosition = nil
        PillPosition.reset(in: positionDefaults)
        place()
        updateDockTracking()
    }

    private func beginDrag(_ event: NSEvent) {
        resizeGen += 1
        resizeDriver?.invalidate()
        resizeDriver = nil
        // Start at the rendered position, even when a press interrupts an idle morph.
        content.layoutSubtreeIfNeeded()
        let anchor = panel.convertPoint(toScreen: NSPoint(x: view.frame.midX, y: view.frame.minY))
        dragStart = (pointerLocation(), anchor)
        dragAnchor = anchor
        intendedFrame = panel.frame
        updateDockTracking()
    }

    private func drag(_ event: NSEvent) {
        guard let start = dragStart else { return }
        let mouse = pointerLocation()
        dragAnchor = NSPoint(x: start.anchor.x + mouse.x - start.mouse.x,
                             y: start.anchor.y + mouse.y - start.mouse.y)
        place()
    }

    private func endDrag(_ event: NSEvent) {
        guard let start = dragStart else { return }
        let mouse = pointerLocation()
        let moved = hypot(mouse.x - start.mouse.x, mouse.y - start.mouse.y) >= 2
        if moved {
            drag(event)
            content.layoutSubtreeIfNeeded()
            let anchor = panel.convertPoint(toScreen: NSPoint(x: view.frame.midX, y: view.frame.minY))
            if let screen = screen(containing: anchor) {
                let position = PillPosition(anchor: anchor, displayID: PillPosition.displayID(for: screen),
                                            visibleFrame: screen.visibleFrame)
                savedPosition = position
                position.save(to: positionDefaults)
            }
        }
        dragStart = nil
        dragAnchor = nil
        place()
        updateDockTracking()
        if !moved {
            let pointInPill = view.convert(event.locationInWindow, from: nil)
            if let cancelRect = view.cancelHitRect, cancelRect.contains(pointInPill) {
                onCancelCapture?()
            } else {
                _ = handlePrimaryPillAction()
            }
        }
    }

    /// Shrinks the capsule into Wispr's resting bar (an animated morph, not a fade). Rest is
    /// display-only: the App Nap lift, the 60fps clock and the watchdog all go — if the
    /// window server drops the bar, the next present() brings it back.
    private func idle() {
        view.beginIdle()
        present(size: Self.idleSize)
        showing = false
        stopClocks()
        endActivity()
    }

    private func dismiss() {
        showing = false
        dockTracker.setEnabled(false)
        fadeGen += 1
        stopAnimationClock()
        let g = fadeGen
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = view.reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, g == self.fadeGen, !self.showing else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.stopClocks()
                self.endActivity()
            }
        })
    }

    private func endActivity() {
        guard let a = activity else { return }
        ProcessInfo.processInfo.endActivity(a)
        activity = nil
    }

    /// Panel size for a capsule size plus the transcript and/or recovery banner currently
    /// showing. Extra height goes upward because targetFrame pins the bottom edge.
    private func panelSize(pill: NSSize) -> NSSize {
        let t = TranscriptView.size(for: content.transcript.text)
        let r = RecoveryBannerView.size(for: content.recovery.message, hasCopy: content.recovery.copyText != nil)
        guard t.height > 0 || r.height > 0 else { return pill }
        var extraHeight: CGFloat = 0
        if t.height > 0 { extraHeight += TranscriptView.gap + t.height }
        if r.height > 0 { extraHeight += RecoveryBannerView.gap + r.height }
        return NSSize(width: max(pill.width, max(t.width, r.width)),
                      height: pill.height + extraHeight)
    }

    private func present(size: NSSize) {
        let duration = (pillSize == Self.idleSize || size == Self.idleSize)
            ? Self.idleMorphDuration : 0.10
        pillSize = size
        content.pillSize = size
        showing = true
        loggedEviction = false
        loggedAlphaStuck = false
        loggedOcclusion = false
        occlusionRecoveryAttempts = 0
        lastOcclusionRecoveryAt = 0
        rebuiltPanelThisSession = false
        presentedAt = CACurrentMediaTime()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "dictation session")
        }
        fadeGen += 1
        if !panel.isVisible {
            resize(to: panelSize(pill: size), animated: false)
            place()
            panel.alphaValue = 0
            panel.orderFrontRegardless()   // NOT makeKeyAndOrderFront — that activates the app
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = view.reduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            resize(to: panelSize(pill: size), animated: true, duration: duration)
            // A NEW animator animation supersedes any in-flight fade-out; a direct
            // alphaValue set does NOT — that race left the pill invisible whenever a
            // press landed within the 0.15s of a previous hide.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = view.reduceMotion ? 0 : 0.05
                panel.animator().alphaValue = 1
            }
        }
        updateAnimationClock()
        startWatchdog()
        updateDockTracking()
    }

    /// Re-assert the intended state on a low-frequency watchdog. This recovers a pill that the
    /// window server ordered out mid-session (Space switch, full-screen transition) — the
    /// case the presentation code could not see, and the one class of "it didn't appear"
    /// that show-once logic can never fix.
    private func reconcile() {
        guard showing, dragStart == nil else { return }
        if !panel.isVisible {
            if !loggedEviction {
                loggedEviction = true
                log("overlay: panel was ordered out mid-session — restoring")
            }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        // Alpha is intended state too. Both fades finish in ≤0.12s; well after that, an
        // intended-visible pill must be opaque. A stalled animator leaves visible=Y with
        // alpha=0 — the 21:16 recurrence: ordered in, correct frame, nothing on screen.
        if CACurrentMediaTime() - presentedAt > 0.5, panel.alphaValue < 0.9 {
            if !loggedAlphaStuck {
                loggedAlphaStuck = true
                log(String(format: "overlay: pill alpha stuck at %.2f mid-session — forcing opaque", panel.alphaValue))
            }
            panel.alphaValue = 1
        }
        // Fourth/fifth "didn't appear" reports: every app-side signal (isVisible, alpha,
        // frame) was green while WindowServer reported the panel fully occluded. Merely
        // ordering an already-visible window to the front was a no-op. Cycle it through
        // orderOut on the next run-loop turn so WindowServer reattaches it to the active
        // Space/app set. The screenSaver level above prevents a higher-level Dock or
        // full-screen surface from immediately covering it again.
        let now = CACurrentMediaTime()
        if now - presentedAt > 0.5,
           !panel.occlusionState.contains(.visible),
           occlusionRecoveryAttempts < 3,
           now - lastOcclusionRecoveryAt > 0.25 {
            occlusionRecoveryAttempts += 1
            lastOcclusionRecoveryAt = now
            if !loggedOcclusion {
                loggedOcclusion = true
                log("overlay: pill not composited (occlusion) — reattaching")
            } else {
                log("overlay: pill still occluded — reattaching (attempt \(occlusionRecoveryAttempts)/3)")
            }
            let g = fadeGen
            panel.orderOut(nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.showing, self.fadeGen == g else { return }
                self.place()
                self.panel.alphaValue = 1
                self.panel.orderFrontRegardless()
            }
        }
        // Sixth report (2026-08-11 onward): reattach exhausted and the panel STILL not
        // composited. WindowServer had stranded the panel's Space membership — whole
        // sessions at visible=Y alpha=1.00 level=1000 yet occl=N activeSpace=N, across
        // days — and every recovery above reuses the same server-side window, so the
        // strand survived full orderOut/orderFront cycles. Abandon the corrupt window
        // instead of nursing it: a NEW panel gets a new window number and fresh Space
        // membership, bound to the ACTIVE Space when first ordered in.
        if now - presentedAt > 0.5,
           !panel.occlusionState.contains(.visible),
           occlusionRecoveryAttempts >= 3,
           !rebuiltPanelThisSession,
           now - lastOcclusionRecoveryAt > 0.25 {
            rebuiltPanelThisSession = true
            log("overlay: reattach exhausted — rebuilding stranded panel (new window server identity)")
            let size = panel.frame.size
            let old = panel
            old.orderOut(nil)
            let fresh = Self.makePanel()
            fresh.contentView = content          // detaches the view from the old panel
            panel = fresh
            resize(to: size, animated: false) // re-derives position from the screen
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    /// Single authority for size AND position: derive the target from the saved anchor or screen,
    /// never from the panel's own frame. Centering on `panel.frame.midX` while a resize
    /// animation was in flight read an intermediate value, so the pill walked a pixel left
    /// on every state change and never got re-centred while it stayed visible.
    private func resize(to size: NSSize, animated: Bool, duration: Double = 0.10) {
        guard let placement = targetPlacement(size) else { return }
        let target = placement.frame
        content.pillCenterX = placement.pillCenterX
        content.transcriptAbove = placement.transcriptAbove
        let animated = animated && !view.reduceMotion && dragStart == nil
        let reference = animated ? intendedFrame : panel.frame
        guard abs(reference.width - target.width) > 0.1
                || abs(reference.height - target.height) > 0.1
                || abs(reference.minX - target.minX) > 0.5
                || abs(reference.minY - target.minY) > 0.5 else { return }
        intendedFrame = target
        resizeDriver?.invalidate()
        resizeDriver = nil
        guard animated else {
            panel.setFrame(target, display: true)
            return
        }
        let from = panel.frame
        let start = CACurrentMediaTime()
        resizeGen += 1
        let gen = resizeGen
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stepResize(gen: gen, from: from, to: target, start: start, duration: duration)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeDriver = timer
    }

    private func stepResize(gen: Int, from: NSRect, to target: NSRect,
                            start: CFTimeInterval, duration: Double) {
        guard gen == resizeGen else { return }        // superseded; its timer is already dead
        let p = min(1, (CACurrentMediaTime() - start) / duration)
        let e = 1 - pow(1 - p, 3)                     // ease-out: quick start, soft landing
        panel.setFrame(NSRect(x: from.minX + (target.minX - from.minX) * e,
                              y: from.minY + (target.minY - from.minY) * e,
                              width: from.width + (target.width - from.width) * e,
                              height: from.height + (target.height - from.height) * e),
                       display: true)
        if p >= 1 {
            resizeDriver?.invalidate()
            resizeDriver = nil
        }
    }

    private func updateAnimationClock() {
        guard showing, view.needsContinuousTicks else {
            stopAnimationClock()
            return
        }
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationClock() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func startWatchdog() {
        guard showing, watchdogTimer == nil else { return }
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopClocks() {
        stopAnimationClock()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// DIAG stress: replays the real show/hide sequence at the gaps a fast user produces
    /// (hide → next recording) and asserts the pill is actually on screen while
    /// "recording". Catches presentation races without needing a human at the keyboard.
    /// `open -a FlowClone --args --overlaystress`
    func stress() {
        let gaps: [Double] = [0, 0.02, 0.05, 0.10, 0.14, 0.16, 0.20, 0.30]
        var failures = 0
        var step = 0.0
        for (i, gap) in gaps.enumerated() {
            // transcribing → hide (what the end of a real utterance does)
            DispatchQueue.main.asyncAfter(deadline: .now() + step) { self.transcribing() }
            DispatchQueue.main.asyncAfter(deadline: .now() + step + 0.05) { self.hide() }
            // …then a new session `gap` after the hide began
            let showAt = step + 0.05 + gap
            DispatchQueue.main.asyncAfter(deadline: .now() + showAt) { self.recording() }
            // check 0.25s later: the fade-out (0.15s) must have lost to the new present
            DispatchQueue.main.asyncAfter(deadline: .now() + showAt + 0.25) {
                let ok = self.panel.isVisible && self.panel.alphaValue > 0.9
                if !ok {
                    failures += 1
                    log(String(format: "OVERLAYSTRESS FAIL gap=%.0fms visible=%@ alpha=%.2f",
                               gap * 1000, self.panel.isVisible ? "Y" : "N", self.panel.alphaValue))
                }
                if i == gaps.count - 1 {
                    self.hide()
                    // audit A-5: a sub-result, not the terminal marker — three more
                    // subchecks are still queued below. The aggregate is emitted last.
                    log(failures == 0 ? "OVERLAYSTRESS gaps PASS (\(gaps.count) gaps)"
                                      : "OVERLAYSTRESS gaps: \(failures)/\(gaps.count) FAILURES")
                }
            }
            step = showAt + 0.40
        }
        // Eviction case: something outside us takes the panel off screen mid-session
        // (what a Space switch / full-screen transition does to a floating panel).
        // The pill must come back on its own — a session in progress has no other
        // trigger to re-show it.
        let evictAt = step + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + evictAt) {
            self.recording()
            self.panel.orderOut(nil)          // simulate the eviction
            // Chained from HERE, like the alpha-stuck check below: the resting bar holds no
            // activity assertion, so App Nap lands this block ~0.2s late, and a wall-clock
            // check would leave the 0.2s watchdog only ~70ms.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                let ok = self.panel.isVisible && self.panel.alphaValue > 0.9
                if !ok { failures += 1 }
                log(ok ? "OVERLAYSTRESS eviction PASS (pill recovered)"
                       : String(format: "OVERLAYSTRESS eviction FAIL visible=%@ alpha=%.2f",
                                self.panel.isVisible ? "Y" : "N", self.panel.alphaValue))
                self.hide()
            }
        }
        // Stalled fade-in: the panel is ordered in but the animator never delivers
        // alpha=1 (the 2026-08-03 21:16 recurrence — visible=Y, correct frame, yet
        // nothing on screen). The watchdog must reconcile alpha, not just ordering.
        let stuckAt = evictAt + 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + stuckAt) { self.recording() }
        DispatchQueue.main.asyncAfter(deadline: .now() + stuckAt + 0.6) {
            self.panel.alphaValue = 0     // simulate the stalled animation's end state
            // Check is chained from HERE, not wall-clock: App Nap coalescing once fused
            // the zeroing and a wall-clock check into one burst, giving the watchdog
            // zero frames to act — that was a test artifact, not a watchdog failure.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let ok = self.panel.isVisible && self.panel.alphaValue > 0.9
                if !ok { failures += 1 }
                log(ok ? "OVERLAYSTRESS alpha-stuck PASS (watchdog forced opaque)"
                       : String(format: "OVERLAYSTRESS alpha-stuck FAIL visible=%@ alpha=%.2f",
                                self.panel.isVisible ? "Y" : "N", self.panel.alphaValue))
                self.hide()
            }
        }
        // Real compositing case: a status-level surface covering the pill defeats
        // `orderFrontRegardless()` while the pill is only at `.floating`, even though
        // isVisible and alpha both look healthy. A system overlay at `.screenSaver`
        // must remain visible above it. This caught the blind spot in the older stress
        // assertions, which never inspected WindowServer occlusion.
        let occlusionAt = stuckAt + 1.8
        // audit A-5: the last subcheck owns the single terminal aggregate.
        let total = gaps.count + 4
        func aggregate() {
            log(failures == 0 ? "OVERLAYSTRESS PASS (\(gaps.count) gaps + 4 subchecks)"
                              : "OVERLAYSTRESS: \(failures)/\(total) FAILURES")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + occlusionAt) {
            guard let frame = self.targetFrame(Self.recordingSize) else {
                log("OVERLAYSTRESS occlusion FAIL (no target screen)")
                failures += 1
                return
            }
            let blocker = Pill(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered, defer: false)
            blocker.level = .statusBar
            blocker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            blocker.ignoresMouseEvents = true
            blocker.isOpaque = true
            blocker.backgroundColor = .black
            blocker.orderFrontRegardless()
            self.recording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                let behavior = self.panel.collectionBehavior
                let configured = self.panel.level == .screenSaver
                    && behavior.contains(.canJoinAllApplications)
                let composited = self.panel.isVisible && self.panel.alphaValue > 0.9
                    && self.panel.occlusionState.contains(.visible)
                if !(configured && composited) { failures += 1 }
                log(configured && composited
                    ? "OVERLAYSTRESS occlusion PASS (panel above status-level blocker)"
                    : String(format: "OVERLAYSTRESS occlusion FAIL configured=%@ visible=%@ alpha=%.2f occl=%@",
                             configured ? "Y" : "N", self.panel.isVisible ? "Y" : "N",
                             self.panel.alphaValue,
                             self.panel.occlusionState.contains(.visible) ? "Y" : "N"))
                self.hide()
                blocker.orderOut(nil)
            }
        }
        // Strand case (sixth report): WindowServer pins the panel to a non-active Space
        // and no amount of reattaching the SAME window fixes it. Simulated by covering
        // the pill with an opaque blocker ABOVE .screenSaver: the three reattach
        // attempts must exhaust, the ladder's last rung must abandon the window (new
        // window number), and the fresh panel must composite once uncovered.
        let strandAt = occlusionAt + 1.7
        DispatchQueue.main.asyncAfter(deadline: .now() + strandAt) {
            guard let frame = self.targetFrame(Self.recordingSize) else {
                log("OVERLAYSTRESS strand FAIL (no target screen)")
                failures += 1
                aggregate()
                return
            }
            let blocker = Pill(contentRect: frame.insetBy(dx: -20, dy: -20),
                               styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered, defer: false)
            blocker.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            blocker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            blocker.ignoresMouseEvents = true
            blocker.isOpaque = true
            blocker.backgroundColor = .black
            blocker.orderFrontRegardless()
            let stranded = self.panel.windowNumber
            self.recording()
            // 0.5s occlusion grace + three reattaches ~0.25s apart + the rebuild rung
            // all fire before ~1.5s. The rebuilt panel is still covered here — the
            // occlusion is real — so only the identity change is asserted, then the
            // blocker lifts and WindowServer must composite the fresh panel unaided.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                let rebuilt = self.panel.windowNumber != stranded
                blocker.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    let composited = self.panel.isVisible && self.panel.alphaValue > 0.9
                        && self.panel.occlusionState.contains(.visible)
                    if !(rebuilt && composited) { failures += 1 }
                    log(rebuilt && composited
                        ? "OVERLAYSTRESS strand PASS (stranded panel rebuilt, composited once uncovered)"
                        : String(format: "OVERLAYSTRESS strand FAIL rebuilt=%@ visible=%@ alpha=%.2f occl=%@",
                                 rebuilt ? "Y" : "N", self.panel.isVisible ? "Y" : "N",
                                 self.panel.alphaValue,
                                 self.panel.occlusionState.contains(.visible) ? "Y" : "N"))
                    self.hide()
                    aggregate()
                }
            }
        }
    }

    /// Default placement follows the revealed Dock and rests near the hidden edge.
    /// `open -a FlowClone --args --pilltest`, then read the log. Main thread, no mic.
    ///
    /// Pins the layout contract the owner asked for on 2026-08-28: the transcript sits
    /// ABOVE the capsule and grows UPWARD. Asserted on the pure size math and the container
    /// layout rather than the live panel frame, because the panel resize is animated and its
    /// frame lags the call.
    /// Returns the failure count so the hermetic suite can run the same checks.
    @discardableResult
    func pillSelfCheck() -> Int {
        log("PILLTEST theme=\(Theme.current.rawValue)")
        let savedMotion = view.reduceMotion
        let originalPointerLocation = pointerLocation
        let previousPosition = savedPosition
        let previousPositionData = positionDefaults.object(forKey: PillPosition.preferenceKey)
        suppressDockTracking = true
        dockTracker.setEnabled(false)
        dismissRecoveryNotice()
        resetPosition()
        defer {
            view.reduceMotion = savedMotion
            pointerLocation = originalPointerLocation
            savedPosition = previousPosition
            positionDefaults.set(previousPositionData, forKey: PillPosition.preferenceKey)
            suppressDockTracking = false
            dockFrame = dockTracker.frame
            place()
            updateDockTracking()
        }
        // Exercise both paths without changing the user's accessibility preference.
        view.reduceMotion = true
        view.beginProcessing(slow: false)
        let reducedIsStatic = !view.needsContinuousTicks
        view.reduceMotion = false
        var checks = 0, failed = 0
        func check(_ name: String, _ ok: @autoclosure () -> Bool) {
            checks += 1
            if !ok() { failed += 1; log("PILLTEST FAIL: \(name)") }
        }
        check("reduced motion stops continuous drawing", reducedIsStatic)
        let short = "okay so the first thing is"
        let long = String(repeating: "a much longer transcript that has to wrap several times ", count: 12)

        content.transcript.text = ""
        let bare = panelSize(pill: Self.recordingSize)
        check("no transcript leaves the capsule size untouched", bare == Self.recordingSize)

        content.transcript.text = short
        let small = panelSize(pill: Self.recordingSize)
        check("a transcript makes the panel taller", small.height > bare.height)
        check("the capsule's own height is unchanged",
              small.height - TranscriptView.size(for: short).height - TranscriptView.gap
                  == Self.recordingSize.height)

        content.transcript.text = long
        let big = panelSize(pill: Self.recordingSize)
        check("more text grows it further", big.height > small.height)
        check("growth is capped",
              big.height == TranscriptView.maxHeight + TranscriptView.gap + Self.recordingSize.height)

        // THE property: the bottom edge does not move, so the extra height goes UP.
        if let a = targetFrame(bare), let b = targetFrame(small), let c = targetFrame(big) {
            check("the panel's bottom edge never moves", a.minY == b.minY && b.minY == c.minY)
            check("the panel grows upward", c.maxY > b.maxY && b.maxY > a.maxY)
        } else {
            checks += 1; failed += 1; log("PILLTEST FAIL: no target screen")
        }

        // Container layout: capsule pinned to the bottom, transcript stacked above it.
        content.pillSize = Self.recordingSize
        content.frame = NSRect(origin: .zero, size: big)
        content.layoutSubtreeIfNeeded()
        check("the capsule sits at the bottom of the panel", content.pill.frame.minY == 0)
        check("the capsule keeps its own size", content.pill.frame.size == Self.recordingSize)
        check("the transcript sits ABOVE the capsule",
              content.transcript.frame.minY == Self.recordingSize.height + TranscriptView.gap)
        check("the transcript never overlaps the capsule",
              content.transcript.frame.minY >= content.pill.frame.maxY)
        check("the capsule stays horizontally centred",
              abs(content.pill.frame.midX - content.frame.midX) < 1)

        content.transcript.text = ""
        check("clearing collapses back to the capsule",
              panelSize(pill: Self.recordingSize) == Self.recordingSize)

        // Idle morph: with no transcript the capsule tracks the panel's live size, so a
        // frame animation morphs it; morph reads 0 at the bar, 1 at full height.
        content.pillSize = Self.recordingSize
        content.frame = NSRect(origin: .zero, size: Self.idleSize)
        content.layoutSubtreeIfNeeded()
        check("a bare capsule tracks the panel size", content.pill.frame.size == Self.idleSize)
        check("morph is 0 at the bar", view.morph == 0)
        content.frame = NSRect(origin: .zero, size: NSSize(
            width: (Self.idleSize.width + Self.recordingSize.width) / 2,
            height: (Self.idleSize.height + Self.recordingSize.height) / 2))
        content.layoutSubtreeIfNeeded()
        check("morph is fractional mid-resize", view.morph > 0.4 && view.morph < 0.6)
        content.frame = NSRect(origin: .zero, size: Self.recordingSize)
        content.layoutSubtreeIfNeeded()
        check("morph is 1 at full height", view.morph == 1)

        // The setting is the only gate on any of this reaching the screen.
        let saved = Self.livePartialEnabled
        Self.livePartialEnabled = false
        partial("this must not appear")
        check("the setting suppresses the transcript", content.transcript.text.isEmpty)
        Self.livePartialEnabled = saved

        view.beginReady()
        check("the ready phase is static", !view.needsContinuousTicks)
        view.beginProcessing(slow: false)
        check("the processing phase requests animation ticks", view.needsContinuousTicks)
        view.reset()
        check("listening is static before audio arrives", !view.needsContinuousTicks)
        view.push(0.2)
        check("live listening requests animation ticks", view.needsContinuousTicks)
        view.beginFailure()
        check("the failure phase is static", !view.needsContinuousTicks)
        view.reset()

        // Idle bar: hide() rests on screen when the setting is on, leaves when it is off,
        // and never keeps the session machinery (clocks, App Nap lift) alive while resting.
        let savedIdle = Self.idlePillEnabled
        Self.idlePillEnabled = true
        recording()
        hide()
        check("idle keeps the panel on screen", panel.isVisible && showing == false)
        check("idle uses the small bar size", pillSize == Self.idleSize)
        if case .idle = view.phase { check("idle phase", true) } else { check("idle phase", false) }
        check("idle is static", !view.needsContinuousTicks)
        check("idle holds no clocks", animationTimer == nil && watchdogTimer == nil)
        check("idle holds no App Nap assertion", activity == nil)
        check("idle clears the hands-free dot", !view.pinned)
        recording()
        check("a press leaves idle", showing && view.isListening)
        Self.idlePillEnabled = false
        hide()
        check("hide with the setting off leaves the screen", !showing)
        if case .idle = view.phase { check("no idle phase when off", false) } else { check("no idle phase when off", true) }
        // The morph is real only if the capsule passes through intermediate sizes while the
        // window animates. Spin the run loop and sample the live frame. The layout checks
        // above sized the content view by hand; give it back to the panel first.
        content.frame = NSRect(origin: .zero, size: panel.frame.size)
        Self.idlePillEnabled = true
        hide()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        // Spinning the run loop by hand skips the display pass that runs layout().
        content.layoutSubtreeIfNeeded()
        check("resting at the bar before the morph (panel \(panel.frame.size) content \(content.frame.size) pill \(content.pill.frame.size) intended \(intendedFrame.size) transcript '\(content.transcript.text)')",
              content.pill.frame.size == Self.idleSize)
        var heights = Set<CGFloat>()
        recording()
        let deadline = Date(timeIntervalSinceNow: 0.35)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.008))
            heights.insert(content.pill.frame.height)
        }
        let between = heights.filter { $0 > Self.idleSize.height && $0 < Self.recordingSize.height }
        check("the capsule passes through intermediate heights (saw \(between.count))", between.count >= 3)
        content.layoutSubtreeIfNeeded()
        check("the capsule reaches full height", content.pill.frame.size == Self.recordingSize)
        // …and back: the collapse must morph too, not snap.
        heights.removeAll()
        hide()
        let collapseDeadline = Date(timeIntervalSinceNow: 0.35)
        while Date() < collapseDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.008))
            heights.insert(content.pill.frame.height)
        }
        let shrinking = heights.filter { $0 > Self.idleSize.height && $0 < Self.recordingSize.height }
        check("the capsule collapses through intermediate heights (saw \(shrinking.count))", shrinking.count >= 3)
        content.layoutSubtreeIfNeeded()
        check("the capsule ends at the bar", content.pill.frame.size == Self.idleSize)

        // Deliver real AppKit mouse events through the window, including its inactive
        // first click. No microphone, global event injection, or Accessibility grant.
        view.reduceMotion = true
        let frontBeforeDrag = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            guard let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point),
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
            return event
        }
        let start = NSPoint(x: panel.frame.midX, y: panel.frame.minY + Self.idleSize.height / 2)
        let destination = NSPoint(x: start.x + 140, y: start.y + 180)
        let events = [(mouseEvent(.leftMouseDown, at: start), start),
                      (mouseEvent(.leftMouseDragged, at: destination), destination),
                      (mouseEvent(.leftMouseUp, at: destination), destination)]
        for (event, point) in events {
            pointerLocation = { point }
            if let event { NSApp.sendEvent(event) }
        }
        pointerLocation = originalPointerLocation
        check("mouse drag moves the idle pill", abs(panel.frame.midX - destination.x) < 1
              && abs(panel.frame.minY - (destination.y - Self.idleSize.height / 2)) < 1)
        check("drag saves a position that reloads", savedPosition != nil
              && PillPosition.load(from: positionDefaults) == savedPosition)
        let draggedAnchor = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        recording()
        partial("The pill stays where you put it.")
        check("recording and live text retain the dragged position",
              abs(panel.frame.midX - draggedAnchor.x) < 1 && abs(panel.frame.minY - draggedAnchor.y) < 1)
        clearPartial()
        transcribing()
        hide()
        check("processing and idle retain the dragged position",
              abs(panel.frame.midX - draggedAnchor.x) < 1 && abs(panel.frame.minY - draggedAnchor.y) < 1)
        check("drag never takes keyboard focus", !panel.isKeyWindow && !panel.isMainWindow
              && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBeforeDrag)
        resetPosition()
        check("reset forgets the saved position", savedPosition == nil && PillPosition.load(from: positionDefaults) == nil)
        check("reset returns immediately to default", targetFrame(Self.idleSize) == panel.frame)
        // Exercise the same callback used by the live Dock reader, on the actual panel.
        // Controlled bounds avoid changing Dock preferences or global pointer/focus.
        dockPositionChanged(nil)
        let restingFrame = panel.frame
        if let screen = screen(containing: NSPoint(x: restingFrame.midX, y: restingFrame.minY)) {
            let dock = NSRect(x: screen.frame.midX - 300, y: screen.frame.minY + 10,
                              width: 600, height: 53)
            dockPositionChanged(dock.offsetBy(dx: 0, dy: -40))
            dockPositionChanged(dock)
            check("settled floating Dock keeps idle pill raised with 4pt clearance",
                  panel.frame.minY == max(restingFrame.minY, dock.maxY + 4))
            recording()
            partial("The transcript follows the pill above the Dock.")
            check("active pill and transcript retain Dock clearance", panel.frame.minY >= dock.maxY + 4)
            clearPartial()
            hide()
            dockPositionChanged(nil)
            check("hiding Dock restores the lower idle position", panel.frame == restingFrame)
            let custom = PillPosition(anchor: NSPoint(x: restingFrame.midX, y: restingFrame.minY + 180),
                                      displayID: PillPosition.displayID(for: screen), visibleFrame: screen.visibleFrame)
            savedPosition = custom
            place()
            let customFrame = panel.frame
            dockPositionChanged(dock)
            check("Dock reveal preserves custom placement", panel.frame == customFrame)
            dockPositionChanged(nil)
            resetPosition()
        } else {
            check("Dock movement probe has a display", false)
        }
        Self.idlePillEnabled = savedIdle
        hide()

        log(failed == 0 ? "PILLTEST PASS (\(checks) checks)"
                        : "PILLTEST FAIL (\(failed)/\(checks) checks)")
        return failed
    }

    /// `open -a FlowClone --args --pilldemo` — shows the recording pill and grows a
    /// transcript above it, so the layout can be SEEN rather than assumed. No mic, no ASR.
    func demo() {
        let words = """
        okay so I want the transcript to appear above the pill instead of scrolling \
        across it, growing upward as I keep talking, and the waveform underneath should \
        stay completely visible the whole time no matter how much text piles up above it
        """.split(separator: " ").map(String.init)
        recording()
        for i in 1...words.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) {
                self.partial(words.prefix(i).joined(separator: " "))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(words.count) + 12) {
            self.clearPartial()
            self.hide()
            log("PILLDEMO done")
        }
    }

    private func targetFrame(_ size: NSSize) -> NSRect? { targetPlacement(size)?.frame }

    private func targetPlacement(_ size: NSSize) -> PillPosition.Placement? {
        if let anchor = dragAnchor, let screen = screen(containing: anchor) {
            return PillPosition.placement(size: size, pillSize: pillSize, anchor: anchor,
                                          visibleFrame: screen.visibleFrame, gap: TranscriptView.gap)
        }
        if let position = savedPosition,
           let screen = NSScreen.screens.first(where: { PillPosition.displayID(for: $0) == position.displayID }) {
            return PillPosition.placement(size: size, pillSize: pillSize, anchor: position.anchor(in: screen.visibleFrame),
                                          visibleFrame: screen.visibleFrame, gap: TranscriptView.gap)
        }
        // A disconnected display falls back safely without erasing its saved position.
        let mouse = NSEvent.mouseLocation
        let screen = frontWindowScreen()
            ?? NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        let f = screen.visibleFrame
        let anchor = PillPosition.defaultAnchor(screenFrame: screen.frame, visibleFrame: f, dockFrame: dockFrame)
        return PillPosition.placement(size: size, pillSize: pillSize, anchor: anchor,
                                      visibleFrame: f, gap: TranscriptView.gap)
    }

    private var hasCustomPosition: Bool {
        guard let savedPosition else { return false }
        return NSScreen.screens.contains { PillPosition.displayID(for: $0) == savedPosition.displayID }
    }

    private func updateDockTracking() {
        dockTracker.setEnabled(!suppressDockTracking && panel.isVisible && dragStart == nil && !hasCustomPosition)
    }

    private func dockPositionChanged(_ frame: NSRect?) {
        dockFrame = frame
        guard panel.isVisible, dragStart == nil, !hasCustomPosition else { return }
        resize(to: panelSize(pill: pillSize), animated: true, duration: 0.08)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min {
                func distance(to screen: NSScreen) -> CGFloat {
                    let f = screen.frame
                    return hypot(point.x - min(max(point.x, f.minX), f.maxX),
                                 point.y - min(max(point.y, f.minY), f.maxY))
                }
                return distance(to: $0) < distance(to: $1)
            }
    }

    func resetFrontWindowThrottleForTesting() {
        cachedFrontWindowScreen = nil
        frontWindowQueryCount = 0
    }

    /// The pill belongs on the screen the user is dictating INTO, which is where the
    /// frontmost app's front window is — not where the mouse was left. Window bounds come
    /// back without Screen Recording permission (only window names are withheld). Throttled
    /// to ~250ms so streaming partial-transcript resizes do not hammer WindowServer IPC.
    func frontWindowScreen(frontmostPID: pid_t? = nil, now: CFTimeInterval = CACurrentMediaTime()) -> NSScreen? {
        guard let pid = frontmostPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        if let cached = cachedFrontWindowScreen,
           cached.pid == pid,
           now - cached.at < Self.frontWindowQueryMinInterval,
           cached.screen == nil || NSScreen.screens.contains(where: { $0 === cached.screen }) {
            return cached.screen
        }
        frontWindowQueryCount += 1

        let bounds: CGRect?
        if let customProvider = windowBoundsProvider {
            bounds = customProvider(pid)
        } else if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            // Front-to-back order, so the first ordinary (layer 0) window of that app is the
            // one the user is looking at.
            bounds = windows.lazy.compactMap({ window -> CGRect? in
                guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                      window[kCGWindowLayer as String] as? Int == 0,
                      let raw = window[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: raw) else { return nil }
                return rect
            }).first
        } else {
            bounds = nil
        }

        guard let bounds, let main = NSScreen.screens.first else {
            cachedFrontWindowScreen = (now, pid, nil)
            return nil
        }
        let frames = NSScreen.screens.map(\.frame)
        guard let index = Self.screenIndex(
            holdingMostOf: Self.appKitRect(fromWindowBounds: bounds,
                                           mainScreenHeight: main.frame.height),
            in: frames) else {
            cachedFrontWindowScreen = (now, pid, nil)
            return nil
        }
        let resolved = NSScreen.screens[index]
        cachedFrontWindowScreen = (now, pid, resolved)
        return resolved
    }

    /// CGWindowList reports top-left-origin coordinates measured down from the main
    /// display; NSScreen.frame is bottom-left-origin. Pure so the flip can be pinned.
    nonisolated static func appKitRect(fromWindowBounds bounds: CGRect,
                                       mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.origin.x, y: mainScreenHeight - bounds.maxY,
               width: bounds.width, height: bounds.height)
    }

    /// The screen holding most of `rect`, or nil when it touches none of them (a display
    /// unplugged since the window was placed). Ties keep the earlier screen, which is the
    /// order NSScreen reports — main display first.
    nonisolated static func screenIndex(holdingMostOf rect: CGRect,
                                        in frames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0, area > (best?.area ?? 0) else { continue }
            best = (index, area)
        }
        return best?.index
    }

    /// Display added/removed/rearranged — re-derive at the intended size. Never
    /// `panel.frame.size`: mid-animation that is an interpolated value, and adopting it
    /// would make the animation's current frame the new intended one.
    private func place() { resize(to: panelSize(pill: pillSize), animated: false) }
}
