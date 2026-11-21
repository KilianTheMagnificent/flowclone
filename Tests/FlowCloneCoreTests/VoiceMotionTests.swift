import XCTest
import Cocoa
@testable import FlowCloneCore

final class VoiceMotionTests: XCTestCase {
    private let themes: [AppTheme] = [.anthropic, .softSeal, .ceramic, .interface]

    private func held(_ level: CGFloat, hz: Double = 60) -> ThemedVoiceMotion {
        var motion = ThemedVoiceMotion()
        for _ in 0..<Int(hz * 2) { motion.advance(input: level, deltaTime: 1 / hz) }
        return motion
    }

    func testEveryThemeDistinguishesSoftNormalAndLoudWithoutEarlySaturation() {
        for theme in themes {
            let levels: [CGFloat] = [0, 0.01, 0.15, 0.4, 0.7, 1]
            let layout = VoiceStrokeLayout.forTheme(theme)
            let centre = layout.count / 2
            let heights = levels.map { held($0).heights(for: theme)[centre] }
            for index in 1..<heights.count { XCTAssertGreaterThan(heights[index], heights[index - 1], "\(theme)") }
            XCTAssertEqual(heights.first!, layout.base, accuracy: 0.001)
            XCTAssertEqual(heights.last!, layout.maximum, accuracy: 0.001)
            // Soft speech must visibly lift the marks, not read as silence.
            XCTAssertGreaterThan(heights[2] - layout.base, 0.3 * (layout.maximum - layout.base), "\(theme) soft")
            // Loud peaks stay near 65% of the container, clear of its edge.
            XCTAssertLessThanOrEqual(layout.maximum, 0.66 * theme.activeSize.height, "\(theme) peak")
        }
    }

    func testSteadyInputIsCentreWeightedLikeAVoice() {
        for theme in themes {
            let layout = VoiceStrokeLayout.forTheme(theme)
            let weights = (0..<layout.count).map { layout.weight(at: $0) }
            for i in weights.indices { XCTAssertEqual(weights[i], weights[layout.count - 1 - i], accuracy: 0.000001) }
            XCTAssertEqual(weights.first!, 0.6, accuracy: 0.001)
            if layout.count % 2 == 1 { XCTAssertEqual(weights[layout.count / 2], 1, accuracy: 0.000001) }
            for i in 1...(layout.count - 1) / 2 { XCTAssertGreaterThan(weights[i], weights[i - 1], "\(theme) rises to the centre") }
        }
        for theme in themes {
            let heights = held(0.56).heights(for: theme)
            for i in heights.indices { XCTAssertEqual(heights[i], heights[heights.count - 1 - i], accuracy: 0.001) }
            XCTAssertEqual(heights.max()!, heights[heights.count / 2], accuracy: 0.001)
            XCTAssertGreaterThan(heights[heights.count / 2], heights[0] + 2, "\(theme) is not a flat comb")
        }
        let five = VoiceStrokeLayout.forTheme(.ceramic)
        for (i, expected) in [0.6, 0.86, 1, 0.86, 0.6].enumerated() { XCTAssertEqual(five.weight(at: i), expected, accuracy: 0.01) }
    }

    func testOnsetsAppearImmediatelyInNewestMarkAndSilenceClearsTheHistory() {
        var motion = ThemedVoiceMotion()
        for _ in 0..<6 { motion.advance(input: 1, deltaTime: 1.0 / 60) }
        for theme in themes {
            let heights = motion.heights(for: theme), layout = VoiceStrokeLayout.forTheme(theme)
            XCTAssertEqual(heights.first!, layout.base, accuracy: 0.001)
            // The newest mark is an envelope edge: it reaches nearly all of its weighted peak at once.
            let newestPeak = layout.height(level: 1, at: layout.count - 1)
            XCTAssertGreaterThan(heights.last!, layout.base + (newestPeak - layout.base) * 0.9)
        }
        for _ in 0..<90 { motion.advance(input: 0, deltaTime: 1.0 / 60) }
        for theme in themes {
            XCTAssertTrue(motion.heights(for: theme).allSatisfy { abs($0 - VoiceStrokeLayout.forTheme(theme).base) < 0.001 })
        }
    }

    func testThemedOnsetSpringPopsSyllableAttacksAndTravelsAcrossMarks() {
        var attack = ThemedVoiceMotion()
        for _ in 0..<5 { attack.advance(input: 0.5, deltaTime: 1.0 / 60) }
        let steady = held(0.5)
        for theme in themes {
            let layout = VoiceStrokeLayout.forTheme(theme)
            let last = layout.count - 1
            // Within ~80 ms of a syllable attack, the newest mark crests above its sustained vowel height.
            XCTAssertGreaterThan(attack.heights(for: theme)[last], steady.heights(for: theme)[last], "\(theme) onset crest")
        }
        // As the vowel continues, that onset crest scrolls into the centre marks and then settles cleanly.
        for _ in 0..<8 { attack.advance(input: 0.5, deltaTime: 1.0 / 60) }
        for theme in themes {
            let centre = VoiceStrokeLayout.forTheme(theme).count / 2
            XCTAssertGreaterThan(attack.heights(for: theme)[centre], steady.heights(for: theme)[centre], "\(theme) travelling crest")
        }
        for _ in 0..<60 { attack.advance(input: 0.5, deltaTime: 1.0 / 60) }
        for theme in themes {
            for (a, b) in zip(attack.heights(for: theme), steady.heights(for: theme)) {
                XCTAssertEqual(a, b, accuracy: 0.001, "\(theme) settled")
            }
        }
    }

    func testSteadySoundDoesNotInventPulsesAndFrameRateDoesNotChangeAmplitude() {
        var motion = held(0.56)
        for theme in themes {
            let expected = motion.heights(for: theme)
            let faster = held(0.56, hz: 120).heights(for: theme)
            let slower = held(0.56, hz: 30).heights(for: theme)
            for i in expected.indices {
                XCTAssertEqual(expected[i], faster[i], accuracy: 0.001)
                XCTAssertEqual(expected[i], slower[i], accuracy: 0.001)
            }
            for _ in 0..<120 { motion.advance(input: 0.56, deltaTime: 1.0 / 60) }
            for (a, b) in zip(expected, motion.heights(for: theme)) { XCTAssertEqual(a, b, accuracy: 0.001) }
        }
    }

    func testReducedMotionRetainsQuietAudioAndVolumeOrdering() {
        for theme in themes {
            let silence = held(0).heights(for: theme, reducedMotion: true)
            let quiet = held(0.03).heights(for: theme, reducedMotion: true)
            let normal = held(0.5).heights(for: theme, reducedMotion: true)
            let loud = held(1).heights(for: theme, reducedMotion: true)
            XCTAssertGreaterThan(quiet[0], silence[0])
            XCTAssertGreaterThan(normal[0], quiet[0])
            XCTAssertGreaterThan(loud[0], normal[0])
            // No traveling history: every mark is the static envelope applied to one shared level.
            let layout = VoiceStrokeLayout.forTheme(theme)
            let shared = (normal[0] - layout.base) / layout.weight(at: 0)
            for (i, height) in normal.enumerated() {
                XCTAssertEqual(height, layout.base + shared * layout.weight(at: i), accuracy: 0.001, "\(theme)")
            }
        }
    }

    func testInterfaceTickerLightsItsSixDotsClockwiseAndHoldsStillInReducedMotion() {
        // Six dots on a ring, numbered clockwise from twelve o'clock: a spinner, not a 2 x 3 grip.
        XCTAssertEqual(InterfaceTicker.count, 6)
        XCTAssertEqual(InterfaceTicker.clockwise, [0, 1, 2, 3, 4, 5])
        let top = InterfaceTicker.offset(dot: 0, radius: 5)
        XCTAssertEqual(top.x, 0, accuracy: 0.001)
        XCTAssertEqual(top.y, 5, accuracy: 0.001)
        for (step, dot) in InterfaceTicker.clockwise.enumerated() {
            let p = InterfaceTicker.offset(dot: dot, radius: 5)
            XCTAssertEqual(hypot(p.x, p.y), 5, accuracy: 0.001)
            let next = InterfaceTicker.offset(dot: InterfaceTicker.clockwise[(step + 1) % 6], radius: 5)
            XCTAssertLessThan(p.x * next.y - p.y * next.x, 0, "each next dot sits clockwise (y up)")
        }
        for (step, dot) in InterfaceTicker.clockwise.enumerated() {
            let lit = Double(step) * InterfaceTicker.stagger
            XCTAssertEqual(InterfaceTicker.alpha(dot: dot, elapsed: lit + 0.05, reducedMotion: false), 1, accuracy: 0.001)
            XCTAssertEqual(InterfaceTicker.alpha(dot: dot, elapsed: lit + InterfaceTicker.period * 0.8, reducedMotion: false), 0.25, accuracy: 0.001)
            XCTAssertEqual(InterfaceTicker.alpha(dot: dot, elapsed: lit + InterfaceTicker.period + 0.05, reducedMotion: false), 1, accuracy: 0.001)
        }
        for dot in 0..<6 {
            for elapsed in [0.0, 0.37, 5.1] {
                let alpha = InterfaceTicker.alpha(dot: dot, elapsed: elapsed, reducedMotion: false)
                XCTAssertTrue((0.25...1).contains(alpha))
                XCTAssertEqual(InterfaceTicker.alpha(dot: dot, elapsed: elapsed, reducedMotion: true), 0.8)
            }
        }
    }

    func testInkContoursPreserveAmplitudeAndStaySeparatedAtAllHeights() {
        for weight in [1, InkWaveformGeometry.pillWeight] {
            for height: CGFloat in [2, 3, 5, 10, 16, 26, .nan, .infinity] {
                var previousMaxX: CGFloat = 0
                let expected = height.isFinite ? height : 2
                for index in 0..<9 {
                    let path = InkWaveformGeometry.stroke(index: index, height: height, weight: weight)
                    let bounds = path.boundingBoxOfPath
                    XCTAssertEqual(bounds.height, expected, accuracy: 0.001)
                    XCTAssertEqual(bounds.midY, 16, accuracy: 0.001)
                    XCTAssertGreaterThan(bounds.minX - previousMaxX, 0.5)
                    XCTAssertTrue(CGRect(x: 0, y: 3, width: 54, height: 26).insetBy(dx: -0.001, dy: -0.001).contains(bounds))
                    XCTAssertEqual(path, InkWaveformGeometry.stroke(index: index, height: height, weight: weight))
                    previousMaxX = bounds.maxX
                }
            }
        }
    }

    func testPillInkStrokesAreAtLeastOneAndAHalfPointsAcross() {
        for index in 0..<9 {
            let path = InkWaveformGeometry.stroke(index: index, height: 16, weight: InkWaveformGeometry.pillWeight)
            let bounds = path.boundingBoxOfPath
            // The narrowest row of the stroke body (caps excluded), sampled horizontally.
            var narrowest = CGFloat.greatestFiniteMagnitude
            for row in stride(from: bounds.minY + 4, through: bounds.maxY - 4, by: 1) {
                let inside = stride(from: bounds.minX - 1, through: bounds.maxX + 1, by: 0.02)
                    .filter { path.contains(CGPoint(x: $0, y: row)) }.count
                narrowest = min(narrowest, CGFloat(inside) * 0.02)
            }
            XCTAssertGreaterThanOrEqual(narrowest, 1.5, "stroke \(index)")
        }
    }

    func testCaptureMeterPreservesFirstSyllableAndBroadLoudnessRange() {
        var first = ResponsiveInputMeter()
        XCTAssertGreaterThan(first.level(rms: 0.03), 0, "Do not calibrate the first word away")
        var meter = ResponsiveInputMeter()
        XCTAssertEqual(meter.level(rms: 0), 0)
        let levels: [Float] = [0.002, 0.005, 0.015, 0.05]
        let mapped = levels.map { meter.level(rms: $0) }
        for index in 1..<mapped.count { XCTAssertGreaterThan(mapped[index], mapped[index - 1]) }
        XCTAssertLessThan(mapped.last!, 1)
        XCTAssertEqual(meter.level(rms: .nan), 0)
        XCTAssertEqual(meter.level(rms: .infinity), 0)
        XCTAssertEqual(meter.level(rms: -1), 0)
    }

    @MainActor
    func testProductionPillUsesTheApprovedMotionAndResetsBetweenSessions() {
        let view = PillView()
        view.reduceMotion = false
        view.reset()
        var reference = ThemedVoiceMotion()
        for packet: Float in [0, 0.15, 0.5, 1, 0.4, 0] {
            view.push(packet)
            for _ in 0..<4 {
                view.tick(deltaTime: 1.0 / 60)
                reference.advance(input: CGFloat(packet), deltaTime: 1.0 / 60)
                for theme in themes + [.settle] { XCTAssertEqual(view.voiceHeights(for: theme), reference.heights(for: theme)) }
            }
        }
        view.beginProcessing(slow: false)
        view.reset()
        for theme in themes + [.settle] {
            XCTAssertTrue(view.voiceHeights(for: theme).allSatisfy { $0 == VoiceStrokeLayout.forTheme(theme).base })
        }
    }

    // MARK: - Settle's fluid line

    private func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint { result.append(element.pointee.points[0]) }
        }
        return result
    }

    // A capture-shaped feed: 21 ms buffers at 16 kHz.
    private func feed(_ gate: inout VoiceGate, seconds: Double, from start: Double = 0,
                      _ signal: (Double) -> Float) -> [Float] {
        (0..<Int(seconds * 16_000 / 341)).map { buffer in
            let samples = (0..<341).map { n in signal(start + Double(buffer * 341 + n) / 16_000) }
            return samples.withUnsafeBufferPointer { gate.loudness($0) }
        }
    }

    /// Deterministic room noise at about `db` dBFS.
    private func room(_ db: Double) -> (Double) -> Float {
        { t in Float(pow(10, db / 20) * 1.7 * sin(t * 12_345.678 + sin(t * 3_210.9) * 40)) }
    }

    /// A voiced vowel: 150 Hz with falling harmonics, at about `db` dBFS.
    private func vowel(_ db: Double, hz: Double = 150) -> (Double) -> Float {
        { t in Float(pow(10, db / 20) * 1.6 * (sin(2 * .pi * hz * t) + 0.5 * sin(4 * .pi * hz * t) + 0.25 * sin(6 * .pi * hz * t))) }
    }

    /// Plays buffer loudnesses into a trail as capture does: one every 21.3 ms, drawn at 60 fps.
    private func play(_ trail: inout VoiceTrail, _ loudness: [Float]) {
        let buffer = 341.0 / 16_000
        var due = trail.clock
        for value in loudness {
            due += buffer
            while trail.clock + 1.0 / 60 <= due { trail.advance(deltaTime: 1.0 / 60) }
            trail.advance(deltaTime: due - trail.clock)
            trail.receive(value)
        }
    }

    private func settleLine(_ trail: VoiceTrail, reduced: Bool = false) -> [CGPoint] {
        points(SettleWave.line(center: .zero, trail: trail, reducedMotion: reduced))
    }

    private func peak(_ line: [CGPoint]) -> CGFloat { line.map { abs($0.y) }.max() ?? 0 }

    /// The largest swing in the part of the line that holds audio from `ages` seconds ago.
    private func swing(_ line: [CGPoint], ages: ClosedRange<Double>) -> CGFloat {
        let left = line.first!.x, width = line.last!.x - left
        return line.filter { ages.contains(Double(($0.x - left) / width) * VoiceTrail.span) }.map { abs($0.y) }.max() ?? 0
    }

    func testSettleGateKeepsTheRoomFlatAndLetsSpeechThrough() {
        var gate = VoiceGate()
        // A room whose noise swells by 8 dB never opens the gate.
        let swell = feed(&gate, seconds: 1.5) { t in self.room(-62 + 8 * (0.5 + 0.5 * sin(t * 4)))(t) }
        XCTAssertTrue(swell.allSatisfy { $0 == 0 }, "room noise moved the line")
        // Normal speech stands well clear of it, and loud speech fills the range.
        let normal = feed(&gate, seconds: 0.3, from: 1.5, vowel(-34)).last!
        let loud = feed(&gate, seconds: 0.3, from: 1.8, vowel(-18)).last!
        XCTAssertGreaterThan(normal, 0.3)
        XCTAssertLessThan(normal, loud)
        XCTAssertGreaterThan(loud, 0.85)
        XCTAssertEqual(feed(&gate, seconds: 0.5, from: 2.1, room(-58)).last!, 0)
        // Digital zeros (a muted device) and a filter tail don't drag the floor down.
        _ = feed(&gate, seconds: 0.5, from: 2.6) { _ in 0 }
        XCTAssertEqual(feed(&gate, seconds: 0.5, from: 3.1, room(-56)).last!, 0)
        // Corrupt samples never poison it.
        let poisoned = feed(&gate, seconds: 0.1, from: 3.6) { t in t < 3.65 ? .nan : .infinity }
        XCTAssertTrue(poisoned.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(feed(&gate, seconds: 0.3, from: 3.7, vowel(-26)).last!, 0.3)
        XCTAssertEqual([Float]().withUnsafeBufferPointer { gate.loudness($0) }, 0)
    }

    /// 2026-10-18: continuous dictation raised a percentile floor into the voice and the line
    /// went flat while the owner talked. Five seconds of unbroken speech must keep reading as voice.
    func testSettleGateStaysOpenThroughContinuousSpeech() {
        var gate = VoiceGate()
        _ = feed(&gate, seconds: 0.3, room(-62))
        // Syllables of 200 ms at -26 dB with 60 ms dips to -40 dB (reverb and soft consonants), no pauses.
        let speech = feed(&gate, seconds: 5, from: 0.3) { t in
            let syllable = (t - 0.3).truncatingRemainder(dividingBy: 0.26) < 0.2
            return self.vowel(syllable ? -26 : -40)(t) + self.room(-62)(t)
        }
        let lastSecond = speech.suffix(47)
        XCTAssertGreaterThan(lastSecond.reduce(0, +) / Float(lastSecond.count), 0.4)
        XCTAssertGreaterThan(lastSecond.max()!, 0.6)
        XCTAssertLessThan(gate.floorDB, -55, "the room estimate rose into the voice")
        // Talking from the very first buffer still reads as voice.
        var eager = VoiceGate()
        let early = feed(&eager, seconds: 2) { t in self.vowel(-28)(t) + self.room(-62)(t) }
        XCTAssertGreaterThan(early.suffix(20).min()!, 0.4)
        // A room that gets louder mid-dictation is followed, so it doesn't read as voice for long.
        _ = feed(&gate, seconds: 4, from: 5.3, room(-50))
        XCTAssertEqual(feed(&gate, seconds: 0.5, from: 9.3, room(-50)).last!, 0)
    }

    func testSettlePenAnswersTheVoiceAtOnceAndSilenceIsStill() {
        var trail = VoiceTrail()
        play(&trail, [Float](repeating: 0, count: 40))
        XCTAssertEqual(peak(settleLine(trail)), 0)
        let still = settleLine(trail)
        trail.advance(deltaTime: 0.5)
        XCTAssertEqual(settleLine(trail), still, "nothing moves on a timer")
        // A word: the pen is near full height within two buffers (~43 ms).
        play(&trail, [0.9, 0.9])
        XCTAssertGreaterThan(trail.current, 0.8)
        play(&trail, [Float](repeating: 0.9, count: 10))
        XCTAssertGreaterThan(swing(settleLine(trail), ages: 0...0.15), 7)
        // The wave advances only with sound: in a pause the pen's phase holds.
        play(&trail, [Float](repeating: 0, count: 6))
        let paused = trail.sample(ago: 0).phase
        trail.advance(deltaTime: 0.3)
        XCTAssertEqual(trail.sample(ago: 0).phase, paused)
        XCTAssertEqual(trail.current, 0)
    }

    func testSettleTrailScrollsTheWordRightAndLetsItSettle() {
        var trail = VoiceTrail()
        play(&trail, [Float](repeating: 0, count: 30) + [Float](repeating: 0.8, count: 12) + [Float](repeating: 0, count: 20))
        // ~0.43 s after the 0.26 s word ended, it sits 0.43-0.69 s back; the pen and the rest are flat.
        let line = settleLine(trail)
        XCTAssertGreaterThan(swing(line, ages: 0.45...0.65), 5)
        XCTAssertLessThan(swing(line, ages: 0...0.3), 0.01)
        XCTAssertLessThan(swing(line, ages: 0.8...1.5), 0.01)
        // It keeps moving right with time, then settles flat and leaves.
        play(&trail, [Float](repeating: 0, count: 20))
        XCTAssertGreaterThan(swing(settleLine(trail), ages: 0.9...1.1), 2)
        XCTAssertLessThan(swing(settleLine(trail), ages: 0...0.7), 0.01)
        play(&trail, [Float](repeating: 0, count: 50))
        XCTAssertEqual(peak(settleLine(trail)), 0)
    }

    func testSettleTrailHeightFollowsLoudnessWithHeadroom() {
        func height(_ level: Float) -> CGFloat {
            var trail = VoiceTrail()
            play(&trail, [Float](repeating: level, count: 80))
            return peak(settleLine(trail))
        }
        let soft = height(0.25), normal = height(0.6), loud = height(1)
        XCTAssertGreaterThan(soft, 3)
        XCTAssertGreaterThan(normal, soft)
        XCTAssertGreaterThan(loud, normal)
        XCTAssertLessThanOrEqual(2 * loud + SettleWave.weight, 0.8 * AppTheme.settle.activeSize.height)
        // Louder speech also writes a denser wave.
        func cycles(_ level: Float) -> CGFloat {
            var trail = VoiceTrail()
            play(&trail, [Float](repeating: level, count: 80))
            return trail.sample(ago: 0).phase - trail.sample(ago: 1).phase
        }
        XCTAssertGreaterThan(cycles(1), 1.2 * cycles(0.25))
        XCTAssertEqual(settleLine(VoiceTrail()).last!.y, 0)
    }

    func testSettleTrailIsSmoothAndFrameRateIndependent() {
        var a = VoiceTrail(), b = VoiceTrail()
        let word = [Float](repeating: 0, count: 10) + (0..<40).map { Float(0.5 + 0.4 * sin(Double($0) / 3)) }
        play(&a, word)
        // The same audio drawn at 30 fps gives the same trail.
        let buffer = 341.0 / 16_000
        var due = 0.0
        for value in word {
            due += buffer
            while b.clock + 1.0 / 30 <= due { b.advance(deltaTime: 1.0 / 30) }
            b.advance(deltaTime: due - b.clock)
            b.receive(value)
        }
        for (p, q) in zip(settleLine(a), settleLine(b)) { XCTAssertEqual(p.y, q.y, accuracy: 0.05) }
        // One frame later the written trail has only slid right by one frame's scroll: no jumps.
        let before = settleLine(a)
        a.advance(deltaTime: 1.0 / 60)
        let after = settleLine(a)
        let shift = SettleWave.width / CGFloat(VoiceTrail.span) / 60
        func y(_ line: [CGPoint], at x: CGFloat) -> CGFloat {
            let i = max(0, min(line.count - 2, line.firstIndex { $0.x >= x }.map { $0 - 1 } ?? line.count - 2))
            let t = (x - line[i].x) / (line[i + 1].x - line[i].x)
            return line[i].y + (line[i + 1].y - line[i].y) * t
        }
        for point in after where point.x > after[0].x + 8 && point.x < after.last!.x - 20 {
            // The settling tail fades as it scrolls, so compare before its envelope applies.
            XCTAssertEqual(point.y, y(before, at: point.x - shift), accuracy: 0.3)
        }
    }

    func testSettlePreviewAndReducedMotion() {
        // Previews push the plain level, which the trail writes like a voice.
        var preview = VoiceTrail()
        play(&preview, [Float](repeating: 0.6, count: 60))
        XCTAssertGreaterThan(peak(settleLine(preview)), 4)
        // Reduced motion: the icon's still wave at a stepped height, the same frame to frame.
        var trail = VoiceTrail()
        play(&trail, [Float](repeating: 0.7, count: 30))
        let a = settleLine(trail, reduced: true)
        play(&trail, [Float](repeating: 0.7, count: 3))
        XCTAssertEqual(settleLine(trail, reduced: true), a)
        XCTAssertGreaterThan(peak(a), 2)
        var quiet = VoiceTrail()
        play(&quiet, [Float](repeating: 0, count: 30))
        XCTAssertEqual(peak(settleLine(quiet, reduced: true)), 0)
    }

    func testSettleEnvelopeLeavesThePenFreeAndSettlesTheTail() {
        XCTAssertEqual(SettleWave.envelope(0), 1)
        XCTAssertEqual(SettleWave.envelope(0.7), 1)
        XCTAssertEqual(SettleWave.envelope(1), 0)
        for u in stride(from: 0.72, to: 1.0, by: 0.02) {
            XCTAssertLessThanOrEqual(SettleWave.envelope(CGFloat(u) + 0.02), SettleWave.envelope(CGFloat(u)))
        }
        XCTAssertLessThanOrEqual(stride(from: 0.0, through: 20, by: 0.01).map { abs(SettleWave.carrier(CGFloat($0))) }.max()!, 1.0001)
    }

    func testSettleWorkingLineRunsOneCrestRightAndHoldsStillInReducedMotion() {
        func line(_ elapsed: TimeInterval, reduced: Bool = false) -> [CGPoint] {
            points(SettleWave.working(center: .zero, elapsed: elapsed, reducedMotion: reduced))
        }
        func crestX(_ elapsed: TimeInterval) -> CGFloat { line(elapsed).max { $0.y < $1.y }!.x }
        XCTAssertLessThan(crestX(0.35), crestX(0.55))
        XCTAssertLessThan(crestX(0.55), crestX(0.75))
        XCTAssertEqual(line(0.5, reduced: true), line(3.1, reduced: true))
        for l in [line(0.4), line(0.4, reduced: true)] {
            XCTAssertEqual(l.first!.y, 0, accuracy: 0.001)
            XCTAssertEqual(l.last!.y, 0, accuracy: 0.001)
            XCTAssertLessThanOrEqual(peak(l), 4.001)
        }
    }

    /// The marks draw the icon's own stroke: keep SettleGlyph in step with assets/makeicon.swift.
    func testSettleGlyphMatchesTheIconSource() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/makeicon.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        func literal(_ name: String, _ g: SettleGlyph.Shape) -> String {
            let n = { (v: CGFloat) in String(Int(v)) }
            return "let \(name) = Glyph(start: \(n(g.start)), waves: [\(g.waves.map { "(\(n($0.0)), \(n($0.1)))" }.joined(separator: ", "))], end: \(n(g.end)), stroke: \(n(g.stroke)))"
        }
        XCTAssertTrue(text.contains(literal("full", SettleGlyph.full)))
        XCTAssertTrue(text.contains(literal("small", SettleGlyph.small)))
    }

    func testSettleOnsetSpringPopsSyllableAttacksAndSettlesOnSustainedVowels() {
        var trail = VoiceTrail()
        play(&trail, [0, 0, 0.5])
        let firstBuffer = trail.current
        XCTAssertGreaterThan(trail.push, 0.08, "Syllable attack should kick the onset spring immediately")
        XCTAssertGreaterThan(firstBuffer, 0.42, "First buffer should pop well above pure 0.7 smoothing (0.35)")

        // Within the next two buffers (~40-65 ms), the critically damped spring crests above the sustained 0.5 vowel.
        play(&trail, [0.5, 0.5])
        let crest = trail.current
        XCTAssertGreaterThan(crest, 0.58, "Onset spring should crest clearly above the sustained vowel level")

        // Over a sustained vowel (~300 ms), the spring decays smoothly back to the steady-state level without ringing.
        play(&trail, [Float](repeating: 0.5, count: 16))
        XCTAssertEqual(trail.current, 0.5, accuracy: 0.01)
        XCTAssertLessThan(trail.push, 0.01)

        // A brief inter-syllable dip followed by a fresh syllable re-triggers the spring and accelerates the carrier.
        let phaseBeforeDip = trail.sample(ago: 0).phase
        play(&trail, [0.15, 0.15, 0.55, 0.55])
        XCTAssertGreaterThan(trail.push, 0.1)
        XCTAssertGreaterThan(trail.current, 0.62)

        var steadyDrone = VoiceTrail()
        play(&steadyDrone, [Float](repeating: 0.5, count: 21))
        let droneStart = steadyDrone.sample(ago: 0).phase
        play(&steadyDrone, [Float](repeating: 0.35, count: 4))
        XCTAssertGreaterThan(trail.sample(ago: 0).phase - phaseBeforeDip, steadyDrone.sample(ago: 0).phase - droneStart)

        // Even the loudest step attack stays within the capsule headroom cap.
        var loudAttack = VoiceTrail()
        play(&loudAttack, [0, 1, 1, 1])
        XCTAssertEqual(loudAttack.current, 1.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(peak(settleLine(loudAttack)), SettleWave.peak + 0.001)
    }
}
