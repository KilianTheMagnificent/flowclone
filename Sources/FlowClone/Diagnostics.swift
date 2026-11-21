// Mic start-latency probe, ported from spikes/micstart.swift so it runs under the
// signed bundle's TCC identity. The fn tap graduated into Hotkey.swift.
import Cocoa
import Accelerate
import AVFoundation

// MARK: - mic start latency

func runMicDiagnostic() {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        log("mic diagnostic ABORTED — microphone permission is \(micStatusName()); run Permissions… first")
        return
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let before = AudioInputRouter.defaultInputDevice()
        let cold = measureMicStart("a")
        Thread.sleep(forTimeInterval: 2)
        let warm = measureMicStart("b")
        let after = AudioInputRouter.defaultInputDevice()
        log(String(format: "mic route-open→first-nonzero-sample: cold-ish %.0fms, warm %.0fms " +
                   "(for true cold: quit, wait 90s, rerun)", cold, warm))
        log("mic diagnostic system default: before=\(before?.name ?? "none") " +
            "after=\(after?.name ?? "none") unchanged=\(before?.uid == after?.uid)")
    }
}

/// Exercises the production Recorder (including conversion and multiple rolling
/// liveness windows) without transcribing or pasting anything.
func runRecorderDiagnostic() {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        log("recorder diagnostic ABORTED — microphone permission is \(micStatusName())")
        return
    }
    let queue = DispatchQueue(label: "com.andre.flowclone.recorder-diagnostic")
    queue.async {
        let diagnosticStarted = DispatchTime.now()
        let recorder = Recorder(queue: queue)
        log(String(format: "recorder diagnostic timing: init %.1fms",
                   ms(diagnosticStarted, .now())))
        let catalogStarted = DispatchTime.now()
        let defaultBefore = AudioInputRouter.defaultInputDevice()
        log(String(format: "recorder diagnostic timing: catalog %.1fms",
                   ms(catalogStarted, .now())))
        recorder.onInputFailure = { samples, reason in
            log("recorder diagnostic FAILED after \(samples.count) samples: \(reason)")
        }
        let primeStarted = DispatchTime.now()
        recorder.primeAsync { primed, _ in
            log(String(format: "recorder diagnostic timing: prime %.1fms",
                       ms(primeStarted, .now())))
            guard primed else {
                log("recorder diagnostic FAILED — route prime failed")
                return
            }
            let beginStarted = DispatchTime.now()
            recorder.begin { opened in
                guard opened else {
                    log("recorder diagnostic FAILED — begin() could not open an input")
                    return
                }
                log(String(format: "recorder diagnostic timing: begin %.1fms",
                           ms(beginStarted, .now())))
                queue.asyncAfter(deadline: .now() + 2.3) {
                    let samples = recorder.end()
                    var peak: Float = 0
                    samples.withUnsafeBufferPointer { buffer in
                        if let base = buffer.baseAddress, !buffer.isEmpty {
                            vDSP_maxmgv(base, 1, &peak, vDSP_Length(buffer.count))
                        }
                    }
                    let defaultAfter = AudioInputRouter.defaultInputDevice()
                    log(String(format: "recorder diagnostic: %.2fs %d samples peak=%.7f " +
                               "system-default-before=%@ after=%@ unchanged=%@",
                               Double(samples.count) / Recorder.sampleRate, samples.count, peak,
                               defaultBefore?.name ?? "none", defaultAfter?.name ?? "none",
                               defaultBefore?.uid == defaultAfter?.uid ? "Y" : "N"))
                }
            }
        }
    }
}

private func measureMicStart(_ label: String) -> Double {
    let t0 = DispatchTime.now()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    guard let binding = AudioInputRouter.bindBestDevice(to: input) else {
        log("mic run \(label): no usable input device")
        return -1
    }
    let fmt = input.inputFormat(forBus: 0)
    let sem = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var firstBufferAt: DispatchTime?
    var firstNonzeroAt: DispatchTime?
    var observedPeak: Float = 0

    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
        var peak: Float = 0
        if buffer.frameLength > 0, let ptr = buffer.floatChannelData?[0] {
            vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(buffer.frameLength))
        }
        let now = DispatchTime.now()
        var signal = false
        stateLock.lock()
        if firstBufferAt == nil { firstBufferAt = now }
        observedPeak = max(observedPeak, peak)
        if firstNonzeroAt == nil, peak > 1e-8 {
            firstNonzeroAt = now
            signal = true
        }
        stateLock.unlock()
        if signal {
            sem.signal()
        }
    }

    do {
        try engine.start()
    } catch {
        log("mic run \(label): engine.start failed: \(error)")
        input.removeTap(onBus: 0)
        return -1
    }
    let waited = sem.wait(timeout: .now() + 5)
    stateLock.lock()
    let t1 = firstNonzeroAt ?? DispatchTime.now()
    let callback = firstBufferAt
    let peak = observedPeak
    stateLock.unlock()
    engine.stop()
    input.removeTap(onBus: 0)

    let ms = Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    let callbackDetail = callback.map {
        String(format: "first-buffer=%.1fms",
               Double($0.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
    } ?? "no buffers"
    let timeout = waited == .success ? "" : "  (TIMEOUT — no nonzero PCM in 5s)"
    log(String(format: "mic run %@: route=%@ [%@] device=%.0fHz %dch  " +
               "route-open→first-nonzero=%.1fms %@ peak=%.7f%@",
               label, binding.device.name, binding.device.transportName,
               fmt.sampleRate, fmt.channelCount, ms, callbackDetail, peak, timeout))
    return ms
}
