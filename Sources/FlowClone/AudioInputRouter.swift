// App-local Core Audio input selection. Bluetooth headsets can remain macOS's
// default input while their active radio/audio ownership is with another device;
// in that state AVAudioEngine can start normally and deliver only zeroes. FlowClone
// therefore avoids wireless defaults when a physical local input is available.
// This never mutates the user's system-wide input or output selection.
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import IOKit

struct AudioInputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let isAlive: Bool
    let inputChannels: UInt32

    var isUsable: Bool { isAlive && inputChannels > 0 }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isUnknownTransport: Bool { transport == 0 }
    /// Apple's display mic has a physical noise floor, like the built-in mic. A
    /// stale USB graph can still deliver callbacks consisting entirely of zeros.
    /// Other USB interfaces and virtual sources may deliberately gate quiet audio.
    var requiresNonzeroInput: Bool {
        isBuiltIn || isWireless ||
            (transport == kAudioDeviceTransportTypeUSB &&
             uid.hasPrefix("AppleUSBAudioEngine:Apple Inc.:Studio Display"))
    }
    /// The last-resort bucket: routes that can be alive yet own no working audio path.
    /// Continuity Capture in either form is the iPhone — it enumerates ahead of real wired
    /// inputs, is never what "the mic" means, and once blocked engine.start for 22s.
    var isWireless: Bool {
        transport == kAudioDeviceTransportTypeBluetooth ||
        transport == kAudioDeviceTransportTypeBluetoothLE ||
        transport == kAudioDeviceTransportTypeContinuityCaptureWired ||
        transport == kAudioDeviceTransportTypeContinuityCaptureWireless ||
        transport == 0x63636170 // legacy 'ccap' value, deprecated before our macOS 14 floor
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless,
             0x63636170: return "Continuity wireless" // legacy 'ccap'
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default:
            let bytes: [UInt8] = [
                UInt8((transport >> 24) & 0xff), UInt8((transport >> 16) & 0xff),
                UInt8((transport >> 8) & 0xff), UInt8(transport & 0xff)
            ]
            if bytes.allSatisfy({ (32...126).contains($0) }),
               let fourCC = String(bytes: bytes, encoding: .ascii) {
                return fourCC
            }
            return String(format: "0x%08X", transport)
        }
    }
}

enum AudioInputRouter {
    struct Catalog {
        let devices: [AudioInputDevice]
        let defaultID: AudioDeviceID?
        /// Clamshell: with the lid closed macOS keeps the built-in mic enumerated and
        /// alive but it delivers exact zeros, so the router must not try it first.
        var lidClosed = false

        var defaultDevice: AudioInputDevice? {
            guard let defaultID else { return nil }
            return devices.first { $0.id == defaultID }
        }
    }

    struct Binding {
        let device: AudioInputDevice
        let defaultDevice: AudioInputDevice?
        let reason: String
    }

    /// Returns a fresh snapshot. AudioDeviceIDs are deliberately never cached: they
    /// can change as AirPods hand off between the Mac and another Apple device.
    static func catalog() -> Catalog {
        let started = DispatchTime.now()
        let snapshot = Catalog(devices: deviceIDs().compactMap(describe),
                               defaultID: defaultInputDeviceID(),
                               lidClosed: lidClosed())
        let elapsedMS = ms(started, .now())
        if elapsedMS > 100 {
            log(String(format: "DIAG mic device catalog took %.0fms", elapsedMS))
        }
        return snapshot
    }

    static func devices() -> [AudioInputDevice] {
        catalog().devices
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        catalog().defaultDevice
    }

    /// Read-only HAL checks. A deliberate hardware mute or zero input gain must not
    /// cause recovery to switch away from the user's selected microphone.
    static func inputIsMuted(_ device: AudioInputDevice) -> Bool {
        let scope = kAudioObjectPropertyScopeInput
        if (uint32(device.id, selector: kAudioDevicePropertyMute, scope: scope) ?? 0) != 0 {
            return true
        }
        var property = address(kAudioDevicePropertyVolumeScalar, scope: scope)
        var gain: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device.id, &property, 0, nil, &size, &gain) == noErr
            && gain == 0
    }

    static func preferredDevice(in catalog: Catalog,
                                excluding: Set<AudioDeviceID> = []) -> AudioInputDevice? {
        orderedCandidates(defaultID: catalog.defaultID, devices: catalog.devices,
                          excluding: excluding, lidClosed: catalog.lidClosed,
                          preferredUID: MicrophonePreferences.preferredUID).first
    }

    static func preferredDevice(excluding: Set<AudioDeviceID> = []) -> AudioInputDevice? {
        preferredDevice(in: catalog(), excluding: excluding)
    }

    /// Selects only this AVAudioEngine's input unit. It does not call any Core Audio
    /// default-device setter, so AirPods can keep handling Mac/iPhone playback. Only the
    /// `--micdiag` probe uses it: AVAudioEngine re-binds to the system default whenever a
    /// default changes, so the recorder captures through `DeviceInputStream` instead.
    static func bindBestDevice(to input: AVAudioInputNode,
                               catalog providedCatalog: Catalog? = nil,
                               excluding: Set<AudioDeviceID> = []) -> Binding? {
        let catalog = providedCatalog ?? Self.catalog()
        let candidates = orderedCandidates(defaultID: catalog.defaultID,
                                           devices: catalog.devices,
                                           excluding: excluding,
                                           lidClosed: catalog.lidClosed,
                                           preferredUID: MicrophonePreferences.preferredUID)

        for device in candidates {
            do {
                let bindingStarted = DispatchTime.now()
                if input.auAudioUnit.deviceID != device.id {
                    try input.auAudioUnit.setDeviceID(device.id)
                }
                let bindingMS = ms(bindingStarted, .now())
                if bindingMS > 100 {
                    log(String(format: "DIAG app-local mic binding to %@ took %.0fms",
                               device.name, bindingMS))
                }
                return binding(for: device, in: catalog)
            } catch {
                log("RECORDER: could not bind \(device.name) [\(device.transportName)]: \(error)")
            }
        }
        return nil
    }

    /// Why `device` is the route, relative to the system default. Pure; opens nothing.
    static func binding(for device: AudioInputDevice, in catalog: Catalog) -> Binding {
        let defaultDevice = catalog.defaultDevice
        let reason: String
        if let defaultDevice, defaultDevice.id == device.id {
            reason = "system default"
        } else if let defaultDevice, defaultDevice.isWireless {
            reason = "wireless default bypassed"
        } else if defaultDevice == nil {
            reason = "no usable system default"
        } else {
            reason = "fallback after unavailable input"
        }
        return Binding(device: device, defaultDevice: defaultDevice, reason: reason)
    }

    /// Pure policy seam used by the executable's deterministic recorder self-check.
    static func orderedCandidates(defaultID: AudioDeviceID?, devices: [AudioInputDevice],
                                  excluding: Set<AudioDeviceID> = [],
                                  lidClosed: Bool = false, preferredUID: String? = nil) -> [AudioInputDevice] {
        let usable = devices.filter { $0.isUsable && !excluding.contains($0.id) }
        // A lid-closed built-in mic is alive but silent: ranking it first cost every
        // press the 700ms silence probe plus an engine restart onto the real input.
        let selected = usable.first { $0.id == defaultID && !(lidClosed && $0.isBuiltIn) }
        let builtIn = usable.filter(\.isBuiltIn)
        let local = usable.filter { !$0.isBuiltIn && !$0.isWireless }
        let wireless = usable.filter(\.isWireless)

        var ordered: [AudioInputDevice] = []
        func add(_ candidates: [AudioInputDevice]) {
            for candidate in candidates where !ordered.contains(where: { $0.id == candidate.id }) {
                ordered.append(candidate)
            }
        }
        if let preferredUID, let preferred = usable.first(where: { $0.uid == preferredUID && !(lidClosed && $0.isBuiltIn) }) {
            add([preferred])
        }

        // Honor a selected built-in/wired/USB/virtual input. A wireless selected
        // input is the dangerous case: choose the Mac mic before opening the engine.
        if let selected, !selected.isWireless, !selected.isUnknownTransport { add([selected]) }
        if !lidClosed { add(builtIn) }
        add(local.filter { !$0.isUnknownTransport })
        if let selected, selected.isUnknownTransport { add([selected]) }
        add(local.filter(\.isUnknownTransport))
        if let selected, selected.isWireless { add([selected]) }
        add(wireless)
        if lidClosed { add(builtIn) }
        return ordered
    }

    static func selfCheck() {
        func fixture(_ id: AudioDeviceID, _ transport: UInt32, alive: Bool = true,
                     channels: UInt32 = 1) -> AudioInputDevice {
            AudioInputDevice(id: id, uid: "fixture-\(id)", name: "fixture-\(id)",
                             transport: transport, isAlive: alive, inputChannels: channels)
        }
        let builtIn = fixture(1, kAudioDeviceTransportTypeBuiltIn)
        let bluetooth = fixture(2, kAudioDeviceTransportTypeBluetooth)
        let usb = fixture(3, kAudioDeviceTransportTypeUSB)
        let deadBuiltIn = fixture(4, kAudioDeviceTransportTypeBuiltIn, alive: false)
        let unknown = fixture(5, 0)

        precondition(orderedCandidates(defaultID: bluetooth.id,
                                       devices: [bluetooth, builtIn]).first == builtIn,
                     "Bluetooth default must route to built-in")
        precondition(orderedCandidates(defaultID: usb.id,
                                       devices: [builtIn, usb]).first == usb,
                     "A selected wired input must remain selected")
        precondition(orderedCandidates(defaultID: bluetooth.id,
                                       devices: [bluetooth, deadBuiltIn]).first == bluetooth,
                     "Bluetooth remains a last resort when no local input is usable")
        precondition(orderedCandidates(defaultID: bluetooth.id,
                                       devices: [bluetooth, builtIn],
                                       excluding: [builtIn.id]).first == bluetooth,
                     "A failed built-in route must not block the last-resort route")
        precondition(orderedCandidates(defaultID: unknown.id,
                                       devices: [unknown, builtIn]).first == builtIn,
                     "An unreadable transport must not outrank a known built-in input")
        log("RECORDERCHECK route policy PASS")
    }

    // MARK: - Legacy HAL reads (preserves the package's macOS 14 deployment floor)

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        uint32(system, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    /// The lid sensor (`ioreg -r -k AppleClamshellState`). Unreadable reads as open.
    private static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return value as? Bool ?? false
    }

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        let name = string(id, selector: kAudioObjectPropertyName) ?? "Audio device \(id)"
        let uid = string(id, selector: kAudioDevicePropertyDeviceUID) ?? "device-\(id)"
        let transport = uint32(id, selector: kAudioDevicePropertyTransportType) ?? 0
        let alive = (uint32(id, selector: kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
        let channels = inputChannelCount(id)
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport,
                                isAlive: alive, inputChannels: channels)
    }

    private static func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> UInt32? {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID,
                               selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        // These HAL CFString properties are returned retained; Core Audio's header
        // makes the caller responsible for releasing them.
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration,
                               scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }
}
