import CoreAudio
import XCTest
@testable import FlowCloneCore

final class MediaPauseTests: XCTestCase {
    private func route(_ name: String = "Test speakers", transport: UInt32 = kAudioDeviceTransportTypeBuiltIn,
                       dataSource: UInt32? = nil, terminal: UInt32? = nil,
                       muted: Bool = false, volume: Float32? = 0.5) -> AudioOutputRoute {
        AudioOutputRoute(name: name, transport: transport, dataSource: dataSource,
                         terminalType: terminal, muted: muted, volume: volume)
    }

    // MARK: - Route

    func testSpeakersTheMicrophoneCanHearArePaused() {
        // Observed on this Mac: built-in 'ispk' with USB speaker terminal 0x301; the Studio
        // Display XDR as a USB device with a 'spkr' terminal.
        XCTAssertTrue(route("MacBook Pro Speakers", dataSource: 0x6973_706B, terminal: 0x0301).heardByMicrophone)
        XCTAssertTrue(route("Studio Display XDR Speakers", transport: kAudioDeviceTransportTypeUSB,
                            terminal: kAudioStreamTerminalTypeSpeaker).heardByMicrophone)
        XCTAssertTrue(route("LG TV", transport: kAudioDeviceTransportTypeHDMI,
                            terminal: kAudioStreamTerminalTypeHDMI, volume: nil).heardByMicrophone)
        XCTAssertTrue(route("Living Room", transport: kAudioDeviceTransportTypeAirPlay).heardByMicrophone)
    }

    func testWornOutputsKeepPlaying() {
        let worn = [
            route("External Headphones", dataSource: AudioOutputRoute.headphoneDataSource),
            route("USB DAC", transport: kAudioDeviceTransportTypeUSB, terminal: kAudioStreamTerminalTypeHeadphones),
            route("Jabra Evolve", transport: kAudioDeviceTransportTypeUSB, terminal: 0x0402),
            route("Andre's AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
            route("Beats", transport: kAudioDeviceTransportTypeBluetoothLE),
            route("AirPods Max", transport: kAudioDeviceTransportTypeAggregate),
        ]
        for output in worn {
            XCTAssertTrue(output.isWorn, output.name)
            XCTAssertFalse(output.heardByMicrophone, output.name)
        }
    }

    func testSilentSpeakersAreLeftAlone() {
        XCTAssertFalse(route(muted: true).heardByMicrophone)
        XCTAssertFalse(route(volume: 0).heardByMicrophone)
    }

    // MARK: - Pause and resume

    private final class FakeMedia: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [String] = []
        var playing = true
        let resumed: XCTestExpectation
        init(resumed: XCTestExpectation) { self.resumed = resumed }
        var commands: [String] { lock.withLock { _commands } }

        func control(_ command: MediaPause.Command) -> MediaPause.NowPlaying? {
            lock.withLock {
                switch command {
                case .pause:
                    _commands.append("pause")
                    return .init(client: "test.fixture.player", pid: 4242, playing: playing, sent: playing)
                case .resume(let target):
                    _commands.append("resume \(target.client)")
                    resumed.fulfill()
                    return .init(client: target.client, pid: target.pid, playing: false, sent: true)
                }
            }
        }
    }

    private func controller(_ media: FakeMedia, output: AudioOutputRoute?, enabled: Bool = true,
                            resumeDelay: Double = 0.05) -> MediaPause {
        MediaPause(enabled: { enabled }, route: { output }, control: { media.control($0) },
                   resumeDelay: resumeDelay)
    }

    func testPausesOnSpeakersAndResumesAfterTheCapture() {
        let media = FakeMedia(resumed: expectation(description: "resumed"))
        let pause = controller(media, output: route())
        pause.captureBegan()
        pause.captureEnded()
        wait(for: [media.resumed], timeout: 2)
        XCTAssertEqual(media.commands, ["pause", "resume test.fixture.player"])
    }

    func testNothingPlayingMeansNothingToResume() {
        let resumed = expectation(description: "resumed")
        resumed.isInverted = true
        let media = FakeMedia(resumed: resumed)
        media.playing = false
        let pause = controller(media, output: route())
        pause.captureBegan()
        pause.captureEnded()
        wait(for: [resumed], timeout: 0.3)
        XCTAssertEqual(media.commands, ["pause"])
    }

    func testHeadphonesAndTheSettingSkipThePause() {
        for (output, enabled) in [(route("AirPods", transport: kAudioDeviceTransportTypeBluetooth), true),
                                  (route(), false), (nil as AudioOutputRoute?, true)] {
            let resumed = expectation(description: "resumed")
            resumed.isInverted = true
            let media = FakeMedia(resumed: resumed)
            let pause = controller(media, output: output, enabled: enabled)
            pause.captureBegan()
            pause.captureEnded()
            wait(for: [resumed], timeout: 0.2)
            XCTAssertEqual(media.commands, [])
        }
    }

    func testAQuickRetakeKeepsTheMediaPausedUntilTheLastCapture() {
        let media = FakeMedia(resumed: expectation(description: "resumed"))
        let pause = controller(media, output: route(), resumeDelay: 0.3)
        pause.captureBegan()
        pause.captureEnded()     // the hands-free arming tap
        pause.captureBegan()     // the second press, inside the grace delay
        pause.captureEnded()
        wait(for: [media.resumed], timeout: 2)
        XCTAssertEqual(media.commands, ["pause", "resume test.fixture.player"])
    }

    func testQuitResumesWithoutWaitingForTheGraceDelay() {
        let media = FakeMedia(resumed: expectation(description: "resumed"))
        let pause = controller(media, output: route(), resumeDelay: 60)
        pause.captureBegan()
        pause.captureEnded()
        pause.resumeBeforeExit()
        wait(for: [media.resumed], timeout: 0)
        XCTAssertEqual(media.commands, ["pause", "resume test.fixture.player"])
    }

    func testTheScriptOnlyEverSendsPlayOrPause() {
        let script = MediaPause.nowPlayingScript
        XCTAssertTrue(script.contains("send(1)") && script.contains("send(0)"))
        XCTAssertFalse(script.contains("send(2)"), "toggle could start playback when nothing was playing")
    }
}
