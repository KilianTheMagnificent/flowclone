import XCTest
@testable import FlowCloneCore

final class SpeechGateSelfCheckTests: XCTestCase {
    func testDeterministicAudioFixtures() {
        // Deterministic pseudo-noise (LCG) — Float amplitude scales the "loudness".
        func noise(_ seconds: Double, amp: Float) -> [Float] {
            var state: UInt64 = 12345
            return (0..<Int(16_000 * seconds)).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return (Float(state >> 40) / Float(1 << 24) - 0.5) * 2 * amp
            }
        }
        var burst = noise(1.5, amp: 0.0008)                       // room silence…
        burst.replaceSubrange(8000..<16000, with: noise(0.5, amp: 0.15))   // …plus a word
        var click = noise(1.5, amp: 0.0008)
        click.replaceSubrange(3300..<3780, with: noise(0.03, amp: 0.2))    // 30ms transient
        var quiet = noise(1.5, amp: 0.0008)                       // low-gain mic speech
        quiet.replaceSubrange(8000..<16000, with: noise(0.5, amp: 0.008))  // ≈ -47dBFS
        var ambientBurst = noise(1.5, amp: 0.031)                 // -35dBFS ambient room / USB mic
        ambientBurst.replaceSubrange(8000..<16000, with: noise(0.5, amp: 0.22))
        let cases: [(String, [Float], Bool)] = [
            ("pure silence", noise(1.5, amp: 0.0008), false),
            ("-35dBFS ambient silence", noise(1.5, amp: 0.031), false),
            ("-35dBFS ambient speech burst", ambientBurst, true),
            ("speech burst", burst, true),
            ("quiet speech", quiet, true),
            ("constant loud", noise(1.5, amp: 0.12), true),
            ("single click", click, false),
            ("too short", noise(0.05, amp: 0.2), false),
        ]
        for (name, samples, expected) in cases {
            XCTAssertEqual(SpeechGate.containsSpeech(samples), expected, name)
        }
    }
}
