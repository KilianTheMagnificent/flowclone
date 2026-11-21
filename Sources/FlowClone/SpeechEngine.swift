import Foundation
import FluidAudio

enum SpeechEngine: String, CaseIterable, Sendable {
    case parakeet, nemotron

    // Keep model loading, cache checks and result provenance on the same version.
    static let parakeetModelVersion: AsrModelVersion = .ultra
    static let fluidAudioVersion = "0.17.4"

    static let preferenceKey = "speechRecognitionEngine"
    static var preferred: SpeechEngine {
        get { SpeechEngine(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .parakeet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    // Frozen for this process: changing Settings cannot switch models mid-utterance.
    // The command-line override lets isolated probes use either engine without changing Settings.
    static let active = launchArgValue("--speech-engine").flatMap(SpeechEngine.init(rawValue:)) ?? preferred

    var label: String {
        switch self {
        case .parakeet: "Parakeet Ultra"
        case .nemotron: "Nemotron Streaming"
        }
    }

    var modelID: String {
        switch self {
        case .parakeet: "parakeet-ultra"
        case .nemotron: "nemotron-speech-streaming-en-0.6b-coreml-560ms"
        }
    }

    var historyLabel: String { "\(label) · FluidAudio \(Self.fluidAudioVersion)" }
}
