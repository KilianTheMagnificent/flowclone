import SwiftUI

/// The start and finish cues. Until these rows existed the only way to silence them was a
/// Terminal `defaults write`, and their loudness was fixed: too loud on a display's speakers
/// at full system volume, and audible to the other side of a call when the speakers are
/// what the call uses.
enum SoundCues {
    static let startKey = "startSound"
    static let processingKey = "processingSound"
    static let volumeKey = "soundCueVolume"
    /// The level the cues always had.
    static let defaultVolume = 0.35
    static let volumeChoices: [(value: Double, title: String)] = [
        (0.15, "Quiet"), (defaultVolume, "Normal"), (0.7, "Loud")
    ]

    static func isEnabled(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// A stored value outside 0…1 (hand-edited) falls back to the default.
    static func volume(in defaults: UserDefaults = .standard) -> Float {
        guard let stored = defaults.object(forKey: volumeKey) as? Double,
              (0...1).contains(stored) else { return Float(defaultVolume) }
        return Float(stored)
    }
}

/// Settings rows for sounds and the recognizer's language. Its own view so it can sit in
/// the Settings page with a one-line hook.
struct SoundAndLanguageSettings: View {
    @AppStorage(SoundCues.startKey) private var startSound = true
    @AppStorage(SoundCues.processingKey) private var processingSound = true
    @AppStorage(SoundCues.volumeKey) private var volume = SoundCues.defaultVolume

    var body: some View {
        SectionCard("Sounds & language") {
            VStack(alignment: .leading, spacing: 18) {
                SettingGroup {
                    Toggle("Play a sound when recording starts", isOn: $startSound)
                        .accessibilityIdentifier("startSound")
                    Toggle("Play a sound when recording stops", isOn: $processingSound)
                        .accessibilityIdentifier("processingSound")
                    SettingCaption("Turn these off if your speakers are part of a call, so the other side does not hear them.")
                }
                if startSound || processingSound {
                    SettingGroup {
                        HStack(spacing: 10) {
                            Text("Sound volume").accessibilityHidden(true)
                            ThemedMenuPicker(label: "Sound volume",
                                             options: SoundCues.volumeChoices,
                                             selection: $volume)
                            .accessibilityIdentifier("soundCueVolume")
                            Button("Play") { playStartSound(force: true) }
                                .accessibilityLabel("Play the start sound")
                        }
                    }
                }
                SettingGroup {
                    Text("Language: English").fontWeight(.medium)
                    SettingCaption(Self.languageCaption(preferredLanguages: Locale.preferredLanguages))
                }
            }
        }
        .onChange(of: startSound) { _, new in log("start sound = \(new)") }
        .onChange(of: processingSound) { _, new in log("processing sound = \(new)") }
        .onChange(of: volume) { _, new in log(String(format: "sound cue volume = %.2f", new)) }
    }

    /// The speech model only knows English. A Mac set to another language gets that said
    /// plainly, since speech in that language comes out as English sound-alikes.
    nonisolated static func languageCaption(preferredLanguages: [String]) -> String {
        let english = preferredLanguages.first.map { $0.lowercased().hasPrefix("en") } ?? true
        return english
            ? "Speech recognition understands English only."
            : "Speech recognition understands English only, whatever language your Mac uses. Speech in other languages comes out as English sound-alikes."
    }
}
