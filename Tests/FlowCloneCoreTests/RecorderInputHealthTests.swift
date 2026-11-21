import CoreAudio
import XCTest
@testable import FlowCloneCore

final class RecorderInputHealthTests: XCTestCase {
    private func device(_ id: AudioDeviceID = 1, transport: UInt32,
                        uid: String = "test-device") -> AudioInputDevice {
        AudioInputDevice(id: id, uid: uid, name: "Test input", transport: transport,
                         isAlive: true, inputChannels: 1)
    }

    func testSilentStudioDisplayTriggersRecoveryDespiteSuccessfulCallbacks() {
        let display = device(transport: kAudioDeviceTransportTypeUSB,
                             uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display XDR:fixture:8,9")
        XCTAssertTrue(Recorder.inputIsDead(frames: 33_600, peak: 0,
                                           exactZeroIsFailure: display.requiresNonzeroInput,
                                           inputMuted: false),
                      "The observed 2.1-second all-zero recording must not be treated as healthy")
        let originalDisplay = device(transport: kAudioDeviceTransportTypeUSB,
                                    uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display:fixture:8,9")
        XCTAssertTrue(originalDisplay.requiresNonzeroInput)
    }

    func testQuietPhysicalMicWithANoiseFloorDoesNotRestart() {
        let display = device(transport: kAudioDeviceTransportTypeUSB,
                             uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display XDR:fixture:8,9")
        XCTAssertFalse(Recorder.inputIsDead(frames: 33_600, peak: 1e-5,
                                            exactZeroIsFailure: display.requiresNonzeroInput,
                                            inputMuted: false))
    }

    func testDeliberateMuteKeepsTheSelectedPhysicalMic() {
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth,
                          kAudioDeviceTransportTypeUSB] {
            let input = device(transport: transport,
                               uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display XDR:fixture:8,9")
            XCTAssertFalse(Recorder.inputIsDead(frames: 33_600, peak: 0,
                                                exactZeroIsFailure: input.requiresNonzeroInput,
                                                inputMuted: true))
            XCTAssertTrue(Recorder.inputIsDead(frames: 0, peak: 0,
                                               exactZeroIsFailure: input.requiresNonzeroInput,
                                               inputMuted: true),
                          "Mute cannot explain missing callbacks")
        }
    }

    func testGatedDigitalSourcesRetainTheirSilencePolicy() {
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
                          kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate] {
            let input = device(transport: transport)
            XCTAssertFalse(Recorder.inputIsDead(frames: 33_600, peak: 0,
                                                exactZeroIsFailure: input.requiresNonzeroInput,
                                                inputMuted: false))
            XCTAssertTrue(Recorder.inputIsDead(frames: 0, peak: 0,
                                               exactZeroIsFailure: input.requiresNonzeroInput,
                                               inputMuted: false))
        }
    }

    func testStaleRouteIsRebuiltBeforeItsOnlyMicrophoneIsExcluded() {
        var recovery = RecorderRouteRecovery()
        XCTAssertEqual(recovery.nextAction(for: 90), .rebuildCurrent,
                       "A closed-lid Mac may have only its display mic; retry its fresh graph first")
        XCTAssertEqual(recovery.nextAction(for: 90), .nextDevice,
                       "A genuinely failed device must not be retried indefinitely")
        XCTAssertEqual(recovery.nextAction(for: 95), .rebuildCurrent,
                       "A fallback device gets its own bounded fresh-graph retry")
        XCTAssertEqual(recovery.nextAction(for: 95), .nextDevice)
        recovery = RecorderRouteRecovery()
        XCTAssertEqual(recovery.nextAction(for: 90), .rebuildCurrent,
                       "A later recording must allow recovery after a reconnected device")
    }

    func testWarmRunningInputFastReusePolicySkipsCatalogUntilTopologyOrPreferenceChanges() {
        let usb = device(42, transport: kAudioDeviceTransportTypeUSB, uid: "usb-mic-1")
        XCTAssertTrue(Recorder.canFastReuseWarmInput(
            idlePaused: false, isRunning: true, inputDeviceID: 42,
            activeDevice: usb, topologyDirty: false, preferredUID: nil
        ))
        XCTAssertTrue(Recorder.canFastReuseWarmInput(
            idlePaused: false, isRunning: true, inputDeviceID: 42,
            activeDevice: usb, topologyDirty: false, preferredUID: "usb-mic-1"
        ))
        XCTAssertFalse(Recorder.canFastReuseWarmInput(
            idlePaused: true, isRunning: true, inputDeviceID: 42,
            activeDevice: usb, topologyDirty: false, preferredUID: nil
        ), "Idle-paused hardware must re-verify and restart")
        XCTAssertFalse(Recorder.canFastReuseWarmInput(
            idlePaused: false, isRunning: false, inputDeviceID: 42,
            activeDevice: usb, topologyDirty: false, preferredUID: nil
        ), "Stopped or interrupted stream must not fast-reuse")
        XCTAssertFalse(Recorder.canFastReuseWarmInput(
            idlePaused: false, isRunning: true, inputDeviceID: 42,
            activeDevice: usb, topologyDirty: true, preferredUID: nil
        ), "Hardware topology changes must trigger fresh catalog scan")
        XCTAssertFalse(Recorder.canFastReuseWarmInput(
            idlePaused: false, isRunning: true, inputDeviceID: 42,
            activeDevice: usb, topologyDirty: false, preferredUID: "different-mic"
        ), "Changed user preference must trigger fresh catalog scan")
    }
}
