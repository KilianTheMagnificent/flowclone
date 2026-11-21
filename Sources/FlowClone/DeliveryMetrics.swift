import Foundation

/// Metadata only. Durations use monotonic clocks; posting a key event and confirming
/// insertion are separate measurements, and weak acknowledgements retain their label.
struct DeliveryMetrics: Sendable {
    static let launchID = UUID().uuidString
    static func requestID(generation: Int) -> String { "\(launchID):\(generation)" }
    var id: String { Self.requestID(generation: generation) }
    let generation: Int
    let releasedAt: DispatchTime
    let requestedMode: String
    var effectiveMode: String
    var asrFinished: DispatchTime?
    var rewriteStarted: DispatchTime?
    var rewriteFinished: DispatchTime?
    var repairBackend: String?
    var repairRoute: String?

    func record(outcome: String, postedAt: DispatchTime? = nil, readyAt: DispatchTime = .now()) {
        var fields: [String: Any] = [
            "schema": 1, "id": id, "launch_id": Self.launchID, "generation": generation,
            "requested_mode": requestedMode, "effective_mode": effectiveMode,
            "outcome": outcome, "release_to_ready_ms": ms(releasedAt, readyAt),
            "asr_model": SpeechEngine.active.modelID, "fluidaudio": SpeechEngine.fluidAudioVersion
        ]
        if let postedAt {
            fields["release_to_post_ms"] = ms(releasedAt, postedAt)
            fields["post_to_ready_ms"] = ms(postedAt, readyAt)
        }
        if let asrFinished { fields["release_to_asr_ms"] = ms(releasedAt, asrFinished) }
        if let rewriteStarted, let rewriteFinished {
            fields["rewrite_ms"] = ms(rewriteStarted, rewriteFinished)
        }
        if let repairBackend { fields["repair_backend"] = repairBackend }
        if let repairRoute { fields["repair_route"] = repairRoute }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
           let json = String(data: data, encoding: .utf8) { log("DELIVERY_METRIC " + json) }
    }
}
