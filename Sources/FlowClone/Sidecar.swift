// Local MLX rewrite backend — a DEBUG-only experiment behind explicit local configuration.
// Compiled out of Release builds so external UserDefaults / NSArgumentDomain settings can
// never spawn a child process inheriting FlowClone's TCC grants.
import Darwin
import Foundation

enum Sidecar {
    enum Readiness: Equatable, Sendable {
        case disabled
        case cold
        case warming
        case ready
        case busy
        case failed
    }

    static let terminationGracePeriod: TimeInterval = 1.5

    /// A runtime failure — a request timeout, a protocol error, a child that exited — is
    /// often the child, not the configuration: one respawn per process recovers from it.
    /// A second one is a broken setup, and latching `.failed` keeps a bad model from
    /// respawning per utterance. A configuration failure never gets a budget at all; it is
    /// latched by `failBeforeSpawn` before any child exists.
    static func readinessAfterRuntimeFailure(previousFailures: Int) -> Readiness {
        previousFailures == 0 ? .cold : .failed
    }

    #if DEBUG
    private struct Configuration: Equatable, Sendable {
        let modelPath: String
        let executablePath: String
        let scriptPath: String
    }

    private enum LineResult {
        case message([String: Any])
        case timeout
        case closed
        case invalid
    }

    /// `sidecarModel` remains the explicit opt-in. Missing executable/script configuration
    /// therefore fails closed instead of silently selecting Apple Foundation Models.
    static var isEnabled: Bool { configuredString("sidecarModel") != nil }

    /// Observable without entering the sidecar queue, so callers can fail promptly while its
    /// queue is occupied by the bounded warmup read or by the one active generation.
    static var readiness: Readiness {
        guard isEnabled else { return .disabled }
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.readiness
    }

    static var isReady: Bool { readiness == .ready }

    /// Small diagnostic/test seam that never touches the process queue. It makes cold versus
    /// warming versus failed observable without risking a wait behind model loading.
    static var readinessDescription: String {
        guard isEnabled else { return "disabled" }
        state.lock.lock()
        defer { state.lock.unlock() }
        if state.readiness == .failed, !state.failureReason.isEmpty {
            return "failed (\(state.failureReason))"
        }
        switch state.readiness {
        case .disabled: return "disabled"
        case .cold: return "cold"
        case .warming: return "warming"
        case .ready: return "ready"
        case .busy: return "busy"
        case .failed: return "failed"
        }
    }

    /// Process fields are coordinated across `queue` and `lock` so `shutdown()` can interrupt
    /// and reap an in-flight child even while `queue` is parked inside `poll`.
    final class Controller: @unchecked Sendable {
        fileprivate let queue = DispatchQueue(label: "com.andre.flowclone.sidecar")
        fileprivate let lock = NSLock()
        fileprivate var readiness: Readiness = .cold
        fileprivate var failureReason = ""
        fileprivate var runtimeFailures = 0
        fileprivate var shuttingDown = false
        fileprivate var process: Process?
        fileprivate var toChild: FileHandle?
        fileprivate var fromChild: FileHandle?
        fileprivate var buffer = Data()

        /// Cleanly terminates (escalating to SIGKILL after `gracePeriod` if SIGTERM is ignored)
        /// and reaps any running child process on application exit.
        func shutdown(gracePeriod: TimeInterval = Sidecar.terminationGracePeriod) {
            Sidecar.shutdown(gracePeriod: gracePeriod)
        }
    }

    static let shared = Controller()
    private static var state: Controller { shared }
    private static var q: DispatchQueue { state.queue }
    private static let warmupTimeout: TimeInterval = 180
    private static let maximumLineBytes = 1_048_576

    /// Boots the configured child once. Safe to call repeatedly. A configuration failure
    /// stays latched for this process; a runtime failure buys exactly one respawn (see
    /// `readinessAfterRuntimeFailure`), so a bad path or broken model still cannot respawn
    /// per utterance.
    static func warm() {
        guard isEnabled else { return }
        state.lock.lock()
        let needsWarmup = !state.shuttingDown && state.readiness == .cold
        state.lock.unlock()
        guard needsWarmup else { return }
        let parsed = configuration()
        guard let config = parsed.value else {
            failBeforeSpawn(parsed.problem)
            return
        }
        state.lock.lock()
        guard !state.shuttingDown, state.readiness == .cold else {
            state.lock.unlock()
            return
        }
        state.readiness = .warming
        state.failureReason = ""
        state.lock.unlock()
        q.async { spawnAndWarm(config) }
    }

    /// One request. Spawning is deliberately absent: a cold/warming/busy child returns nil
    /// before attempting `q.sync`, so model warmup and an existing request can never stall the
    /// caller. FM invokes this from a worker queue and preserves its exactly-once callback.
    static func run(instructions: String, prompt: String, temperature: Double,
                    maxTokens: Int, timeout: TimeInterval) -> (text: String, ms: Double)? {
        guard claimReadyChild() else { return nil }
        return q.sync {
            defer { releaseBusyChild() }
            state.lock.lock()
            let child = state.process
            let toChild = state.toChild
            let isShuttingDown = state.shuttingDown
            state.lock.unlock()
            guard !isShuttingDown, let child, child.isRunning, let toChild else {
                teardown(reason: "child exited before request")
                return nil
            }
            let req: [String: Any] = ["instructions": instructions, "prompt": prompt,
                                      "temperature": temperature, "max_tokens": maxTokens]
            guard let body = try? JSONSerialization.data(withJSONObject: req) else { return nil }
            do {
                try toChild.write(contentsOf: body + Data("\n".utf8))
            } catch {
                log("sidecar write failed: \(error)")
                teardown(reason: "request write failed")
                return nil
            }
            switch readLine(timeout: timeout) {
            case .message(let reply):
                if let err = reply["error"] as? String {
                    log("sidecar error: \(diagnosticErrorSummary(type: "backend", detail: err))")
                    return nil
                }
                guard let text = reply["text"] as? String else {
                    log("sidecar protocol error — response had no text")
                    teardown(reason: "malformed response")
                    return nil
                }
                return (text, reply["ms"] as? Double ?? 0)
            case .timeout:
                log("sidecar TIMEOUT after \(Int(timeout))s — falling back")
                // A late reply would make the next request consume the wrong response, and an
                // ignored SIGTERM would leak a multi-GB MLX child across respawn.
                teardown(reason: "request timed out")
                return nil
            case .closed:
                log("sidecar CLOSED before replying — falling back")
                teardown(reason: "response stream closed")
                return nil
            case .invalid:
                log("sidecar protocol error — invalid or oversized JSON line")
                teardown(reason: "invalid response")
                return nil
            }
        }
    }

    /// Cleanly reaps the sidecar child process on app quit, escalating to SIGKILL if it
    /// ignores SIGTERM past `gracePeriod`. Safe to call even while `q` is blocked in `poll`.
    static func shutdown(gracePeriod: TimeInterval = terminationGracePeriod) {
        state.lock.lock()
        state.shuttingDown = true
        state.readiness = .cold
        state.failureReason = "shutdown"
        let child = state.process
        let stdinHandle = state.toChild
        state.process = nil
        state.toChild = nil
        state.lock.unlock()

        try? stdinHandle?.close()
        if let child {
            _ = terminateAndReap(child, gracePeriod: gracePeriod)
        }

        q.sync {
            state.lock.lock()
            let remainingChild = state.process
            let remainingIn = state.toChild
            let remainingOut = state.fromChild
            state.process = nil
            state.toChild = nil
            state.fromChild = nil
            state.lock.unlock()

            try? remainingIn?.close()
            try? remainingOut?.close()
            if let remainingChild {
                _ = terminateAndReap(remainingChild, gracePeriod: gracePeriod)
            }
            state.buffer.removeAll(keepingCapacity: false)
        }
    }

    /// Sends SIGTERM, waits up to `gracePeriod` for exit, escalates to SIGKILL if the Python
    /// `mlx-lm` process ignores SIGTERM, and reaps the child via `waitUntilExit()`.
    /// Returns `true` when SIGKILL escalation was required.
    @discardableResult
    static func terminateAndReap(_ child: Process,
                                 gracePeriod: TimeInterval = terminationGracePeriod) -> Bool {
        let pid = child.processIdentifier
        guard pid > 0 else { return false }

        if !child.isRunning {
            child.waitUntilExit()
            return false
        }

        child.terminate()
        let deadline = DispatchTime.now() + max(0, gracePeriod)
        while child.isRunning, DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        var escalated = false
        if child.isRunning {
            escalated = true
            log(String(format: "sidecar ignored SIGTERM for %.1fs — escalating to SIGKILL (pid=%d)",
                       gracePeriod, pid))
            _ = Darwin.kill(pid, SIGKILL)
        }
        child.waitUntilExit()
        return escalated
    }

    static func resetForTesting() {
        shutdown(gracePeriod: 0.1)
        state.lock.lock()
        state.shuttingDown = false
        state.readiness = .cold
        state.failureReason = ""
        state.runtimeFailures = 0
        state.lock.unlock()
    }

    static func installChildForTesting(_ child: Process, stdinPipe: Pipe? = nil, stdoutPipe: Pipe? = nil) {
        q.sync {
            state.lock.lock()
            state.shuttingDown = false
            state.process = child
            state.toChild = stdinPipe?.fileHandleForWriting
            state.fromChild = stdoutPipe?.fileHandleForReading
            state.readiness = .ready
            state.lock.unlock()
        }
    }

    private static func spawnAndWarm(_ config: Configuration) {   // on q
        state.lock.lock()
        let cancelledBeforeSpawn = state.shuttingDown
        state.lock.unlock()
        guard !cancelledBeforeSpawn else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.executablePath)
        p.arguments = [config.scriptPath, config.modelPath]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            log("sidecar FAILED to launch: \(error)")
            teardown(reason: "launch failed")
            return
        }
        state.lock.lock()
        if state.shuttingDown {
            state.lock.unlock()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            _ = terminateAndReap(p)
            return
        }
        state.process = p
        state.toChild = stdinPipe.fileHandleForWriting
        state.fromChild = stdoutPipe.fileHandleForReading
        state.lock.unlock()

        let t0 = DispatchTime.now()
        switch readLine(timeout: warmupTimeout) {
        case .message(let hello) where hello["ready"] != nil:
            markReady()
            log(String(format: "sidecar ready — local model loaded in %.1fs",
                       ms(t0, .now()) / 1000))
        case .timeout:
            log("sidecar FAILED — warmup timed out after \(Int(warmupTimeout))s")
            teardown(reason: "warmup timed out")
        case .message:
            log("sidecar FAILED — malformed ready response")
            teardown(reason: "malformed ready response")
        case .closed:
            state.lock.lock()
            let wasShuttingDown = state.shuttingDown
            state.lock.unlock()
            guard !wasShuttingDown else { return }
            log("sidecar FAILED — child closed before ready")
            teardown(reason: "child closed during warmup")
        case .invalid:
            log("sidecar FAILED — invalid or oversized ready response")
            teardown(reason: "invalid ready response")
        }
    }

    /// Reads one newline-terminated JSON object with a monotonic deadline. `poll` gates every
    /// `read`, so neither a silent child nor a partial line can block beyond the caller's
    /// timeout. The serial sidecar queue is the only reader and therefore owns `buffer`.
    private static func readLine(timeout: TimeInterval) -> LineResult {   // on q
        state.lock.lock()
        let fromChild = state.fromChild
        state.lock.unlock()
        guard let fromChild else { return .closed }
        let fd = fromChild.fileDescriptor
        let deadline = DispatchTime.now() + max(0, timeout)
        while true {
            if let result = takeBufferedLine() { return result }
            let now = DispatchTime.now()
            guard now < deadline else { return .timeout }
            let remainingNanos = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            let remainingMillis = max(1, min(Int64(Int32.max),
                Int64((remainingNanos + 999_999) / 1_000_000)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(remainingMillis))
            if result == 0 { return .timeout }
            if result < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 { return .closed }
            guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if count == 0 { return .closed }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .closed
            }
            state.buffer.append(contentsOf: bytes.prefix(Int(count)))
            if state.buffer.count > maximumLineBytes,
               !state.buffer.contains(0x0A) { return .invalid }
        }
    }

    private static func takeBufferedLine() -> LineResult? {       // on q
        guard let newline = state.buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(state.buffer[..<newline])
        state.buffer.removeSubrange(...newline)
        guard line.count <= maximumLineBytes,
              let object = try? JSONSerialization.jsonObject(with: line),
              let message = object as? [String: Any] else { return .invalid }
        return .message(message)
    }

    private static func claimReadyChild() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.shuttingDown, state.readiness == .ready else { return false }
        state.readiness = .busy
        return true
    }

    private static func releaseBusyChild() {
        state.lock.lock()
        if !state.shuttingDown, state.readiness == .busy { state.readiness = .ready }
        state.lock.unlock()
    }

    private static func markReady() {
        state.lock.lock()
        if !state.shuttingDown, state.readiness == .warming { state.readiness = .ready }
        state.lock.unlock()
    }

    private static func failBeforeSpawn(_ reason: String) {
        state.lock.lock()
        let shouldLog = state.readiness == .cold
        if shouldLog {
            state.readiness = .failed
            state.failureReason = reason
        }
        state.lock.unlock()
        if shouldLog { log("sidecar DISABLED — \(reason)") }
    }

    private static func teardown(reason: String) {                // on q
        state.lock.lock()
        let child = state.process
        let toChild = state.toChild
        let fromChild = state.fromChild
        state.process = nil
        state.toChild = nil
        state.fromChild = nil
        state.lock.unlock()

        try? toChild?.close()
        try? fromChild?.close()
        if let child {
            _ = terminateAndReap(child, gracePeriod: terminationGracePeriod)
        }
        state.buffer.removeAll(keepingCapacity: false)

        state.lock.lock()
        if !state.shuttingDown {
            state.readiness = readinessAfterRuntimeFailure(previousFailures: state.runtimeFailures)
            state.runtimeFailures += 1
            state.failureReason = reason
        }
        state.lock.unlock()
    }

    private static func configuration() -> (value: Configuration?, problem: String) {
        guard let model = configuredString("sidecarModel") else {
            return (nil, "sidecarModel is not configured")
        }
        guard let executable = configuredString("sidecarExecutable") else {
            return (nil, "sidecarExecutable must name a prepared local Python executable")
        }
        guard let script = configuredString("sidecarScript") else {
            return (nil, "sidecarScript must name the local sidecar script")
        }
        let manager = FileManager.default
        guard model.hasPrefix("/"), manager.fileExists(atPath: model) else {
            return (nil, "sidecarModel must be an existing absolute local path")
        }
        guard executable.hasPrefix("/"), manager.isExecutableFile(atPath: executable) else {
            return (nil, "sidecarExecutable must be an existing executable absolute path")
        }
        guard script.hasPrefix("/"), manager.fileExists(atPath: script) else {
            return (nil, "sidecarScript must be an existing absolute local path")
        }
        return (Configuration(modelPath: model, executablePath: executable,
                              scriptPath: script), "")
    }

    private static func configuredString(_ key: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }
    #else
    static var isEnabled: Bool { false }
    static var readiness: Readiness { .disabled }
    static var isReady: Bool { false }
    static var readinessDescription: String { "disabled" }

    final class Controller: Sendable {
        func shutdown(gracePeriod: TimeInterval = Sidecar.terminationGracePeriod) {}
    }

    static let shared = Controller()
    static func warm() {}
    static func shutdown(gracePeriod: TimeInterval = terminationGracePeriod) {}
    #endif
}
