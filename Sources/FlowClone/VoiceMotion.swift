import Foundation
import CoreGraphics

/// Display-only metering; capture samples and Classic's 150ms meter are unchanged.
struct ResponsiveInputMeter {
    private(set) var floorDB: Float = -50

    mutating func level(rms: Float) -> Float {
        guard rms.isFinite, rms >= 0 else { return 0 }
        let db = 20 * log10(rms + 1e-10)
        if db < floorDB { floorDB = max(-60, db) }
        return min(1, max(0, (db - floorDB - 3) / 38))
    }
}

struct VoiceStrokeLayout {
    let count: Int
    let width, gap, base, maximum: CGFloat
    let history: TimeInterval

    /// Peaks stay near 65% of the container height, so loud speech never touches the edge.
    /// Classic draws Wispr's own bars (`PillView.listeningBar`); its entry only records their geometry.
    static func forTheme(_ theme: AppTheme) -> Self {
        switch theme {
        case .ceramic: .init(count: 5, width: 3.2, gap: 3.2, base: 3.2, maximum: 22, history: 0.28)
        case .softSeal: .init(count: 7, width: 3.4, gap: 2.6, base: 3.4, maximum: 21, history: 0.30)
        case .anthropic: .init(count: 9, width: 1.65, gap: 2.25, base: 2, maximum: 21, history: 0.32)
        case .classic: .init(count: 10, width: 2, gap: 2, base: 2, maximum: 15, history: 0.32)
        case .interface: .init(count: 5, width: 3, gap: 3, base: 4, maximum: 18, history: 0.28)
        // No marks: one line whose loudest peak-to-peak height is `maximum` (see FluidVoiceMotion).
        case .settle: .init(count: 1, width: SettleWave.weight, gap: 0, base: 0, maximum: 2 * SettleWave.peak, history: 0)
        }
    }

    /// Perceptual loudness: soft speech visibly lifts the marks instead of reading as silence.
    static func perceived(_ level: CGFloat) -> CGFloat { pow(ListeningMeter.clamp(level), 0.55) }

    /// Centre-weighted envelope, 1 in the middle and 0.6 at the ends (five marks: about
    /// 0.6, 0.86, 1, 0.86, 0.6), so a steady level reads as a voice rather than a comb.
    func weight(at index: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        let centre = CGFloat(count - 1) / 2
        return 1 - 0.4 * pow(abs(CGFloat(index) - centre) / centre, 1.5)
    }

    /// A mark's height for a smoothed level; silence rests every mark at `base`.
    func height(level: CGFloat, at index: Int) -> CGFloat {
        base + (maximum - base) * weight(at: index) * Self.perceived(level)
    }
}

/// Interface's processing spinner: six dots on a ring, numbered clockwise from twelve
/// o'clock and lit in turn, so it reads as a spinner rather than a drag-handle grid.
enum InterfaceTicker {
    static let count = 6
    /// Dot indices in lighting order.
    static let clockwise = [0, 1, 2, 3, 4, 5]
    static let period: TimeInterval = 1.2
    static let stagger: TimeInterval = 0.2

    /// A dot's centre relative to the spinner's centre, in y-up (AppKit) coordinates.
    static func offset(dot: Int, radius: CGFloat) -> CGPoint {
        let angle = CGFloat.pi / 2 - CGFloat(dot) * 2 * CGFloat.pi / CGFloat(count)
        return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    }

    /// Full for the first 30% of a dot's cycle, fading to 25% by 60%, then resting.
    static func alpha(dot: Int, elapsed: TimeInterval, reducedMotion: Bool) -> CGFloat {
        guard !reducedMotion, let step = clockwise.firstIndex(of: dot) else { return 0.8 }
        let local = elapsed - Double(step) * stagger
        let p = (local.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
        if p < 0.3 { return 1 }
        if p < 0.6 { return 1 - 0.75 * (p - 0.3) / 0.3 }
        return 0.25
    }
}

/// Port of the approved browser voice engine: a quick attack, short release, and
/// actual recent sound from left to right. Steady input never invents a pulse;
/// syllable onsets kick a critically damped spring so attacks pop and travel across the marks.
struct ThemedVoiceMotion {
    private struct Sample { let time: TimeInterval; let level: CGFloat }
    static let springOmega: CGFloat = 20
    static let onsetImpulse: CGFloat = 0.18
    static let onsetVelocity: CGFloat = 6.5
    private var time: TimeInterval = 0
    private var history = [Sample(time: -1, level: 0), Sample(time: 0, level: 0)]
    private var reducedTime: TimeInterval = 0
    private var reducedLevel: CGFloat = 0
    private var previousInput: CGFloat = 0
    private(set) var push: CGFloat = 0
    private var pushVelocity: CGFloat = 0
    private(set) var level: CGFloat = 0

    mutating func advance(input: CGFloat, deltaTime: TimeInterval) {
        guard deltaTime.isFinite else { return }
        var remaining = min(0.25, max(0, deltaTime))
        let input = ListeningMeter.clamp(input)
        let onset = max(0, input - previousInput)
        previousInput = input
        if onset > 0 {
            push = min(1, push + onset * Self.onsetImpulse)
            pushVelocity += onset * Self.onsetVelocity
        } else if input < level {
            push *= 0.5
            pushVelocity = 0
        }
        // Substeps preserve the history at low frame rates and in reduced motion.
        while remaining > 0.000001 {
            let dt = min(0.05, remaining)
            remaining -= dt
            time += dt
            let tau = input > level ? 0.032 : 0.105
            level += (input - level) * (1 - exp(-dt / tau))
            if level < 0.001 && input == 0 {
                level = 0
                push = 0
                pushVelocity = 0
            } else if level > 0 && (push > 0 || pushVelocity > 0) {
                let t = CGFloat(dt)
                let decay = exp(-Self.springOmega * t)
                let nextPush = decay * (push + (pushVelocity + Self.springOmega * push) * t)
                let nextVelocity = decay * (pushVelocity - Self.springOmega * (pushVelocity + Self.springOmega * push) * t)
                push = nextPush > 0.0002 ? min(1, nextPush) : 0
                pushVelocity = push > 0 ? nextVelocity : 0
            } else {
                push = 0
                pushVelocity = 0
            }
            history.append(Sample(time: time, level: min(1, level + push)))
            while history.count > 2 && history[1].time < time - 0.65 { history.removeFirst() }
            reducedTime += dt
            if reducedTime >= 0.25 - 0.000001 {
                reducedLevel = level <= 0.015 ? 0 : max(0.2, (level * 5).rounded() / 5)
                reducedTime = 0
            }
        }
    }

    private func ago(_ seconds: TimeInterval) -> CGFloat {
        let target = time - seconds
        if target <= history[0].time { return history[0].level }
        for index in stride(from: history.count - 1, through: 1, by: -1) {
            let a = history[index - 1], b = history[index]
            if target >= a.time {
                return a.level + (b.level - a.level) * min(1, (target - a.time) / (b.time - a.time))
            }
        }
        return 0
    }

    func heights(for theme: AppTheme, reducedMotion: Bool = false) -> [CGFloat] {
        let layout = VoiceStrokeLayout.forTheme(theme)
        return (0..<layout.count).map { index in
            let sample = reducedMotion ? reducedLevel : ago(layout.count > 1 ? Double(layout.count - 1 - index) * layout.history / Double(layout.count - 1) : 0)
            return layout.height(level: sample, at: index)
        }
    }
}

/// A biquad (RBJ cookbook) in direct form II transposed, for Settle's display filters.
struct DisplayBiquad {
    let b0, b1, b2, a1, a2: Float
    var z1: Float = 0, z2: Float = 0
    init(lowpass f0: Double, q: Double = 0.707, rate: Double) {
        let w = 2 * Double.pi * f0 / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha, c = cos(w)
        b0 = Float((1 - c) / 2 / a0); b1 = Float((1 - c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }
    init(highpass f0: Double, q: Double = 0.707, rate: Double) {
        let w = 2 * Double.pi * f0 / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha, c = cos(w)
        b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
    }
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        if !(y.isFinite && z1.isFinite && z2.isFinite) { z1 = 0; z2 = 0; return 0 }
        return y
    }
}

/// Settle's input meter, on the tap thread: how far each buffer's voice stands above the room.
/// Speech-band (90 Hz-4 kHz) level against the room's, with the first 12 dB treated as silence,
/// so fans and breath read 0 and speech reads 0.3-1. The room level starts at the quietest of
/// the first five buffers (at most -50 dB), falls to any quieter stretch, and rises only
/// while the input sits near it, never during speech: continuous talking cannot raise it into
/// the voice (it did with a percentile, 2026-10-18). The recorded samples are untouched.
struct VoiceGate {
    static let gateDB: Float = 12
    static let rangeDB: Float = 28
    /// A room that grows louder is followed at this rate, while the input is within `nearDB` of it.
    static let riseDBPerSecond: Float = 3
    static let nearDB: Float = 6
    private var highpass, lowpass: DisplayBiquad
    /// The last five buffer levels; their median ignores a single dip (a filter tail) or click.
    private var recent = [Float](repeating: 0, count: 5), count = 0, head = 0
    private(set) var floorDB: Float = 0
    private let rate: Float

    init(sampleRate: Double = 16_000) {
        rate = Float(sampleRate)
        highpass = DisplayBiquad(highpass: 90, rate: sampleRate)
        lowpass = DisplayBiquad(lowpass: 4_000, rate: sampleRate)
    }

    mutating func loudness(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0, rawPeak: Float = 0
        for raw in samples {
            let x = raw.isFinite ? raw : 0
            rawPeak = max(rawPeak, abs(x))
            let y = lowpass.process(highpass.process(x))
            sum += y * y
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        // Exact digital zeros (a muted or stalled device) say nothing about the room.
        guard rawPeak > 1e-6, rms.isFinite else { return 0 }
        let db = max(-100, 20 * log10(max(rms, 1e-10)))
        recent[head] = db
        head = (head + 1) % recent.count
        count += 1
        let settled = recent.prefix(min(count, recent.count)).sorted()
        if count <= recent.count {
            // Capped, in case the first word started with the press.
            floorDB = min(settled[0], -50)
        } else {
            let median = settled[settled.count / 2]
            if median < floorDB { floorDB = median }
            else if median < floorDB + Self.nearDB { floorDB += Self.riseDBPerSecond * Float(samples.count) / rate }
        }
        return min(1, max(0, (db - floorDB - Self.gateDB) / Self.rangeDB))
    }
}

/// Settle's line: the last 1.5 s of the voice, newest at the left. Its left end is a pen whose
/// height is the voice's loudness right now and whose wave advances only while there is sound
/// (faster when louder); what was said scrolls right and settles into a flat tail, so every
/// syllable stays visible as its own swell and a pause is a flat stretch that does not move.
/// Syllable attacks kick a critically damped onset spring (Dessa-style `push` / `pushVelocity`)
/// so consonant and vowel onsets pop immediately and crest above sustained vowels without jitter.
struct VoiceTrail {
    private struct Mark { let time: TimeInterval; let level: CGFloat; let phase: CGFloat }
    static let span: TimeInterval = 1.5
    /// Wave cycles per second at the pen: a slow roll for soft speech, quicker when loud.
    static let quietRate: CGFloat = 2.6
    static let loudRate: CGFloat = 3.6
    /// Critically damped onset spring (ω₀ = 18 rad/s, peak at ~55 ms, settled within ~220 ms).
    static let springOmega: CGFloat = 18
    static let onsetImpulse: CGFloat = 0.22
    static let onsetVelocity: CGFloat = 7.5
    static let onsetPhaseRate: CGFloat = 1.4
    private var marks: [Mark] = []
    private(set) var clock: TimeInterval = 0
    private var level: CGFloat = 0
    private var previousInput: CGFloat = 0
    private(set) var push: CGFloat = 0
    private var pushVelocity: CGFloat = 0
    private var phase: CGFloat = 0
    private var reducedTime: TimeInterval = 0
    private(set) var reducedLoudness: CGFloat = 0

    /// The loudness right now (0 = silence, 1 = loud), including the syllable-onset spring crest.
    var current: CGFloat { min(1, level + push) }

    /// One buffer's gated loudness. A rise lands within two buffers (~40 ms) and kicks the
    /// onset spring; a fall eases over ~60 ms, so the trail reads as one stroke instead of steps.
    mutating func receive(_ loudness: Float) {
        let x = CGFloat(loudness.isFinite ? max(0, min(1, loudness)) : 0)
        let onset = max(0, x - previousInput)
        previousInput = x
        if onset > 0 {
            push = min(1, push + onset * Self.onsetImpulse)
            pushVelocity += onset * Self.onsetVelocity
        } else if x < level {
            push *= 0.5
            pushVelocity = 0
        }
        level += (x - level) * (x >= level ? 0.7 : 0.5)
        if level < 0.03 && x == 0 {
            level = 0
            push = 0
            pushVelocity = 0
        }
        marks.append(Mark(time: clock, level: current, phase: phase))
        while let first = marks.first, first.time < clock - Self.span - 0.2 { marks.removeFirst() }
        if marks.count > 400 { marks.removeFirst(marks.count - 400) }   // a feed with no clock
    }

    mutating func advance(deltaTime: TimeInterval) {
        guard deltaTime.isFinite else { return }
        var remaining = min(0.25, max(0, deltaTime))
        while remaining > 0.000001 {
            let dt = min(0.01, remaining)
            remaining -= dt
            clock += dt
            if level > 0 && (push > 0 || pushVelocity > 0) {
                let t = CGFloat(dt)
                let decay = exp(-Self.springOmega * t)
                let nextPush = decay * (push + (pushVelocity + Self.springOmega * push) * t)
                let nextVelocity = decay * (pushVelocity - Self.springOmega * (pushVelocity + Self.springOmega * push) * t)
                push = nextPush > 0.0005 ? min(1, nextPush) : 0
                pushVelocity = push > 0 ? nextVelocity : 0
            } else {
                push = 0
                pushVelocity = 0
            }
            let active = current
            // The wave slows to a stop as the voice fades, so a dying word never ripples;
            // syllable onsets briefly accelerate the carrier so each attack writes a crisp crest.
            let rate = Self.quietRate + (Self.loudRate - Self.quietRate) * active + Self.onsetPhaseRate * push
            phase += CGFloat(dt) * rate * min(1, active / 0.2)
            reducedTime += dt
            if reducedTime >= 0.25 - 0.000001 {
                reducedLoudness = level <= 0.015 ? 0 : max(0.2, (level * 5).rounded() / 5)
                reducedTime = 0
            }
        }
        if marks.count > 1 { while marks.count > 2 && marks[1].time < clock - Self.span - 0.2 { marks.removeFirst() } }
    }

    /// Loudness and wave phase `age` seconds ago; the pen (age 0) is the live level and phase.
    func sample(ago age: TimeInterval) -> (level: CGFloat, phase: CGFloat) {
        let time = clock - age
        guard let newest = marks.last else { return (0, phase) }
        if time >= newest.time {
            let t = CGFloat((time - newest.time) / max(0.000001, clock - newest.time))
            return (newest.level + (current - newest.level) * t, newest.phase + (phase - newest.phase) * t)
        }
        var index = marks.count - 1
        while index > 0 && marks[index - 1].time > time { index -= 1 }
        guard index > 0 else { return (0, marks[0].phase) }
        let a = marks[index - 1], b = marks[index]
        let t = CGFloat((time - a.time) / max(0.000001, b.time - a.time))
        let eased = t * t * (3 - 2 * t)        // no kinks where buffers meet
        return (a.level + (b.level - a.level) * eased, a.phase + (b.phase - a.phase) * t)
    }
}

/// Settle's speaking indicator: the app icon's stroke written by the voice. See VoiceTrail.
enum SettleWave {
    /// The icon's 52/824 stroke at a 30pt capsule.
    static let weight: CGFloat = 2
    /// Half the loudest peak-to-peak height, clear of the 30pt capsule's edge.
    static let peak: CGFloat = 11
    /// The line's span inside the 80pt capsule.
    static let width: CGFloat = 60

    private static func smooth(_ x: CGFloat) -> CGFloat { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

    /// Full height from the pen through most of the trail, settling flat over the oldest quarter.
    static func envelope(_ u: CGFloat) -> CGFloat { smooth((1 - u) / 0.28) }

    /// Line height for a loudness: soft speech still shows; the faintest 5% (a closing gate) is flat.
    static func height(_ level: CGFloat) -> CGFloat { VoiceStrokeLayout.perceived(max(0, level - 0.05) / 0.95) }

    /// The trail's wave at a phase: a main roll with a smaller, faster partner so it reads as
    /// a voice rather than a sine, peaking at 1.
    static func carrier(_ phase: CGFloat) -> CGFloat {
        (sin(2 * .pi * phase) + 0.3 * sin(2 * .pi * 1.62 * phase + 1.3)) / 1.3
    }

    /// The speaking line, centred on `center` in y-up coordinates. Reduced motion shows the
    /// icon's still wave at a stepped height instead of the scrolling trail.
    static func line(center: CGPoint, trail: VoiceTrail, reducedMotion: Bool = false, width: CGFloat = width) -> CGPath {
        if reducedMotion {
            let still = peak * height(trail.reducedLoudness)
            return path(center: center, width: width, steps: 96) { u in
                still * smooth(u / 0.12) * envelope(u) * sin(2 * .pi * u * 2.5)
            }
        }
        return path(center: center, width: width, steps: 180) { u in
            let mark = trail.sample(ago: Double(u) * VoiceTrail.span)
            return peak * height(mark.level) * envelope(u) * carrier(mark.phase)
        }
    }

    /// Processing: one soft crest runs along a flat line and leaves it flat behind it.
    /// Reduced motion holds a small still wave instead.
    static func working(center: CGPoint, elapsed: TimeInterval, reducedMotion: Bool, width: CGFloat = width) -> CGPath {
        func pinned(_ u: CGFloat) -> CGFloat { smooth(u / 0.1) * smooth((1 - u) / 0.1) }
        if reducedMotion {
            return path(center: center, width: width, steps: 96) { u in 2 * pinned(u) * sin(2 * .pi * u * 2.5) }
        }
        let crest = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.3) / 1.3) * 1.5 - 0.25
        return path(center: center, width: width, steps: 96) { u in
            let d = (u - crest) / 0.13
            return 4 * exp(-d * d) * pinned(u) * sin(2 * .pi * (u - crest) * 2.5 + .pi / 2)
        }
    }

    private static func path(center: CGPoint, width: CGFloat, steps: Int, offset: (CGFloat) -> CGFloat) -> CGPath {
        let path = CGMutablePath()
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps)
            let y = offset(u)
            let point = CGPoint(x: center.x - width / 2 + u * width, y: center.y + (y.isFinite ? y : 0))
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// The app icon's stroke, as assets/makeicon.swift draws it: half-waves as (width, amplitude)
/// in the icon's 1024 grid, y up, then a flat line. `small` is the heavier glyph for 32px and below.
enum SettleGlyph {
    struct Shape { let start: CGFloat; let waves: [(CGFloat, CGFloat)]; let end: CGFloat; let stroke: CGFloat }
    static let full = Shape(start: 220, waves: [(100, 180), (100, -150), (100, 110), (100, -70), (100, 35)], end: 804, stroke: 52)
    static let small = Shape(start: 240, waves: [(130, 190), (130, -140), (130, 70)], end: 784, stroke: 84)

    static func centerline(_ g: Shape) -> CGPath {
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

    /// The stroked glyph's extent in the grid.
    static func bounds(_ g: Shape) -> CGRect {
        let high = g.waves.map(\.1).max() ?? 0, low = g.waves.map(\.1).min() ?? 0
        return CGRect(x: g.start - g.stroke / 2, y: 512 + low - g.stroke / 2,
                      width: g.end - g.start + g.stroke, height: high - low + g.stroke)
    }
}

/// Exact 45% pen contours from ink-study/ink.mjs, in a 54 x 32 top-down canvas.
/// Fixed gestures and pressure variation avoid per-frame wobble or random jitter.
enum InkWaveformGeometry {
    private static let gestures: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (-0.72, 0.52, 1.10, 0.20), (0.48, -0.65, 0.94, -0.18), (-0.30, 0.74, 1.04, 0.12),
        (0.62, 0.48, 1.14, -0.22), (-0.58, -0.54, 0.97, 0.16), (0.35, 0.80, 1.08, 0.10),
        (-0.48, 0.61, 0.92, -0.14), (0.66, -0.43, 1.12, 0.20), (-0.22, -0.72, 1.02, -0.12)
    ]

    /// The pill's pen: 1.2x the mark's, so every stroke is at least 1.5pt across.
    static let pillWeight: CGFloat = 1.2

    static func stroke(index: Int, height: CGFloat, weight: CGFloat = 1) -> CGPath {
        let h = min(26, max(2, height.isFinite ? height : 2))
        let amount: CGFloat = 0.45
        let (lean, bend, pressure, asymmetry) = gestures[index % gestures.count]
        let x = 11.4 + CGFloat(index) * 3.9, y = (32 - h) / 2, bottom = y + h
        let gesture = amount * (0.16 + 0.84 * min(1, (h - 2) / 12))
        let width = 1.72 * (1 + (pressure - 1) * amount) * weight, cap = min(width * 0.45, h * 0.23)
        let topX = x + lean * gesture, bottomX = x - lean * gesture * 0.55
        let upperX = x + bend * gesture, lowerX = x - bend * gesture * 0.6
        let broad = width * (0.52 + asymmetry * amount), narrow = width * (0.40 - asymmetry * amount * 0.3)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: topX - width * 0.12, y: y))
        path.addCurve(to: CGPoint(x: topX + width * 0.40, y: y + cap),
                      control1: CGPoint(x: topX + width * 0.18, y: y),
                      control2: CGPoint(x: topX + width * 0.45, y: y + cap * 0.4))
        path.addCurve(to: CGPoint(x: bottomX + width * 0.34, y: bottom - cap),
                      control1: CGPoint(x: upperX + broad, y: y + h * 0.27),
                      control2: CGPoint(x: lowerX + narrow, y: y + h * 0.67))
        path.addQuadCurve(to: CGPoint(x: bottomX - width * 0.06, y: bottom),
                         control: CGPoint(x: bottomX + width * 0.28, y: bottom))
        path.addCurve(to: CGPoint(x: bottomX - width * 0.43, y: bottom - cap),
                      control1: CGPoint(x: bottomX - width * 0.25, y: bottom),
                      control2: CGPoint(x: bottomX - width * 0.48, y: bottom - cap * 0.4))
        path.addCurve(to: CGPoint(x: topX - width * 0.36, y: y + cap),
                      control1: CGPoint(x: lowerX - broad * 0.90, y: y + h * 0.69),
                      control2: CGPoint(x: upperX - narrow, y: y + h * 0.25))
        path.addQuadCurve(to: CGPoint(x: topX - width * 0.12, y: y),
                         control: CGPoint(x: topX - width * 0.40, y: y + cap * 0.05))
        path.closeSubpath()
        return path
    }
}
