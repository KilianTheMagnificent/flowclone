// Pauses the system's now-playing media while a dictation records and the sound is coming
// out of speakers the microphone can hear, then resumes only what it paused. Headphones,
// AirPods and headsets keep playing: the microphone cannot hear them.
//
// macOS answers MediaRemote's now-playing state only to Apple-signed clients (a FlowClone
// process reads "not playing" while Chrome plays a video), so the state check and the
// pause/play command run together in a one-shot JXA script under /usr/bin/osascript,
// about 40ms. All of it runs on this file's own queue, never on the hotkey path, and any
// failure leaves the media alone: dictation never waits for or depends on it.
import CoreAudio
import Foundation

/// The system default output, read once per accepted press.
struct AudioOutputRoute: Equatable, Sendable {
    let name: String
    let transport: UInt32
    /// The built-in jack reports its headphones through the output data source.
    let dataSource: UInt32?
    /// First output stream's terminal: a Core Audio four-char code or a USB terminal type.
    let terminalType: UInt32?
    let muted: Bool
    let volume: Float32?

    /// Built-in output data source for the headphone jack.
    static let headphoneDataSource: UInt32 = 0x6864_706E   // 'hdpn'
    /// USB Audio Class output terminals worn on the head: headphones, head-mounted display
    /// audio, handset, headset.
    private static let wornUSBTerminals: Set<UInt32> = [0x0302, 0x0303, 0x0401, 0x0402]
    private static let wornNames = ["headphone", "headset", "airpods", "earpods", "earbud", "buds"]

    /// Headphones, earbuds and headsets — what they play stays out of the room.
    /// Bluetooth output counts as worn: AirPods and headsets are the common case, and the
    /// HAL cannot tell a Bluetooth speaker from them.
    var isWorn: Bool {
        if dataSource == Self.headphoneDataSource { return true }
        if let terminalType,
           terminalType == kAudioStreamTerminalTypeHeadphones ||
           terminalType == kAudioStreamTerminalTypeReceiverSpeaker ||
           Self.wornUSBTerminals.contains(terminalType) { return true }
        if transport == kAudioDeviceTransportTypeBluetooth ||
           transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        let lowered = name.lowercased()
        return Self.wornNames.contains { lowered.contains($0) }
    }

    /// Whether a microphone in the room can hear this route. Anything not known to be worn
    /// counts as a speaker: built-in, display, HDMI, AirPlay, USB and aggregate outputs.
    var heardByMicrophone: Bool { !isWorn && !muted && (volume ?? 1) > 0 }

    var summary: String {
        let state = muted ? ", muted" : (volume == 0 ? ", volume 0" : "")
        return "\(name) [\(isWorn ? "worn" : "speaker")\(state)]"
    }
}

final class MediaPause: @unchecked Sendable {   // state is confined to `queue`
    /// What the now-playing script saw, and whether it sent its command.
    struct NowPlaying: Codable, Equatable, Sendable {
        let client: String
        let pid: Int32
        let playing: Bool
        let sent: Bool
    }

    enum Command: Sendable { case pause, resume(NowPlaying) }

    static let shared = MediaPause()
    static let defaultsKey = "pauseMediaWhileDictating"

    /// Settings → Microphone & setup. On by default.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    private let queue = DispatchQueue(label: "com.andre.flowclone.media-pause")
    private let enabled: @Sendable () -> Bool
    private let route: @Sendable () -> AudioOutputRoute?
    private let control: @Sendable (Command) -> NowPlaying?
    /// A quick release-and-press (the hands-free double-tap, a retake) keeps the media
    /// paused instead of letting it blip back on between the two captures.
    private let resumeDelay: Double

    private var capturing = false
    private var paused: NowPlaying?
    private var pendingResume: DispatchWorkItem?

    init(enabled: @escaping @Sendable () -> Bool = { MediaPause.isEnabled },
         route: @escaping @Sendable () -> AudioOutputRoute? = { MediaPause.defaultOutputRoute() },
         control: @escaping @Sendable (Command) -> NowPlaying? = { MediaPause.runNowPlayingScript($0) },
         resumeDelay: Double = 0.8) {
        self.enabled = enabled
        self.route = route
        self.control = control
        self.resumeDelay = resumeDelay
    }

    /// A capture was accepted. Returns immediately.
    func captureBegan() {
        if handsfreeSession { Handsfree.log("blocked media pause"); return }
        queue.async { [self] in
            capturing = true
            pendingResume?.cancel()
            pendingResume = nil
            guard paused == nil, enabled() else { return }   // still paused from the last capture
            guard let output = route() else { return }
            guard output.heardByMicrophone else {
                log("media pause skipped — output \(output.summary)")
                return
            }
            guard let result = control(.pause) else {
                log("media pause unavailable — now-playing script failed")
                return
            }
            if result.sent {
                paused = result
                log("media paused — \(result.client) on \(output.summary)")
            }
        }
    }

    /// The capture ended, by release, cancel or failure. Returns immediately.
    func captureEnded() {
        queue.async { [self] in
            capturing = false
            guard paused != nil else { return }
            let work = DispatchWorkItem { [self] in resumeIfIdle() }
            pendingResume = work
            queue.asyncAfter(deadline: .now() + resumeDelay, execute: work)
        }
    }

    /// Quit or relaunch: give back anything still paused, without the grace delay.
    func resumeBeforeExit() {
        queue.sync {
            pendingResume?.cancel()
            pendingResume = nil
            capturing = false
            resumeIfIdle()
        }
    }

    private func resumeIfIdle() {
        pendingResume = nil
        guard !capturing, let target = paused else { return }
        paused = nil
        // The script resumes only the same, still-paused player: one the user restarted or
        // replaced while dictating is theirs now.
        let result = control(.resume(target))
        log(result?.sent == true ? "media resumed — \(target.client)"
                                 : "media left as is — \(target.client) changed or the script failed")
    }

    // MARK: - Core Audio

    static func defaultOutputRoute() -> AudioOutputRoute? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device = uint32(system, kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return nil }
        let output = kAudioObjectPropertyScopeOutput
        var nameAddress = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let named = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &name) == noErr
        return AudioOutputRoute(
            name: named ? name?.takeRetainedValue() as String? ?? "Output \(device)" : "Output \(device)",
            transport: uint32(device, kAudioDevicePropertyTransportType) ?? 0,
            dataSource: uint32(device, kAudioDevicePropertyDataSource, scope: output),
            terminalType: firstOutputStream(device).flatMap { uint32($0, kAudioStreamPropertyTerminalType) },
            muted: (uint32(device, kAudioDevicePropertyMute, scope: output) ?? 0) != 0,
            volume: outputVolume(device))
    }

    /// The main volume, or the first channel's when the device has only per-channel controls.
    /// nil when it has neither (HDMI, many interfaces): treated as audible.
    private static func outputVolume(_ device: AudioDeviceID) -> Float32? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                      mScope: kAudioObjectPropertyScopeOutput,
                                                      mElement: element)
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &property, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    private static func firstOutputStream(_ device: AudioDeviceID) -> AudioStreamID? {
        var property = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &streams) == noErr else {
            return nil
        }
        return streams.first
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }

    // MARK: - Now playing (MediaRemote through an Apple-signed host)

    /// Pause only a player that is playing; resume only the same player, still paused.
    /// MediaRemote commands: 0 play, 1 pause (never the toggle, which could start playback).
    static let nowPlayingScript = """
    function run(argv) {
      $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
      const request = $.NSClassFromString("MRNowPlayingRequest");
      const path = request.localNowPlayingPlayerPath;
      const known = !path.isNil() && !path.client.isNil();
      const client = known ? (ObjC.unwrap(path.client.bundleIdentifier) || ObjC.unwrap(path.client.displayName) || "") : "";
      const pid = known ? path.client.processIdentifier : 0;
      const playing = request.localIsPlaying === true;
      const send = (command) => {
        ObjC.bindFunction("MRMediaRemoteSendCommand", ["bool", ["int", "id"]]);
        return $.MRMediaRemoteSendCommand(command, $()) === true;
      };
      let sent = false;
      if (argv[0] === "pause" && playing && client !== "") sent = send(1);
      if (argv[0] === "resume" && !playing && client === argv[1] && String(pid) === argv[2]) sent = send(0);
      return JSON.stringify({client: client, pid: pid, playing: playing, sent: sent});
    }
    """

    static func runNowPlayingScript(_ command: Command, timeout: Double = 2) -> NowPlaying? {
        let arguments: [String]
        switch command {
        case .pause: arguments = ["pause"]
        case .resume(let target): arguments = ["resume", target.client, String(target.pid)]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", nowPlayingScript] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        // A few dozen bytes: the pipe buffer holds them until the process has exited.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(NowPlaying.self, from: data)
    }
}
