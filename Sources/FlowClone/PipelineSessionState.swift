import Foundation

/// Queue-confined lifecycle for active capture and FIFO delivery tails. Supports overlapping
/// capture of Utterance N+1 while Utterance N is still transcribing/cleaning/pasting.
struct PipelineSessionState: Equatable {
    enum Capture: Equatable {
        case idle
        case warming(generation: Int, handsFree: Bool)
        case recording(generation: Int, handsFree: Bool)
    }

    private(set) var generation = 0
    private(set) var capture: Capture = .idle
    /// FIFO queue of generations currently in ASR / cleanup / paste delivery.
    private(set) var deliveringGenerations: [Int] = []
    private var pendingFinishedGeneration: Int?
    /// The microphone open runs off the session queue, so a release can arrive before it
    /// finishes. `openInFlight` tracks whether `Recorder.begin` has been dispatched;
    /// `pendingRelease` records a release that landed while warming so completion honors it
    /// (or a second quick tap during cold open latches hands-free).
    private(set) var openInFlight = false
    private(set) var pendingRelease = false
    /// Uptime of the `.down` that started this capture and, when the release beat the
    /// microphone open, of that release — so a capture that recorded nothing can tell a
    /// hold the speaker spoke into from the quick hands-free arming tap.
    private(set) var pressedAt: DispatchTime?
    private(set) var releasedAt: DispatchTime?
    private(set) var updateReserved = false

    var activeCaptureGeneration: Int? {
        switch capture {
        case .idle: return nil
        case .warming(let owner, _), .recording(let owner, _): return owner
        }
    }

    var deliveringGeneration: Int? { deliveringGenerations.first }

    var captureActive: Bool {
        if case .idle = capture { return false }
        return true
    }

    var isWarming: Bool {
        if case .warming = capture { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = capture { return true }
        return false
    }

    var handsFree: Bool {
        switch capture {
        case .idle: return false
        case .warming(_, let value), .recording(_, let value): return value
        }
    }

    var isDelivering: Bool { !deliveringGenerations.isEmpty }
    var transcribing: Bool { isDelivering }
    var isBusy: Bool { captureActive || isDelivering || updateReserved }

    mutating func reserveForUpdate() -> Bool {
        guard !isBusy else { return false }
        updateReserved = true
        return true
    }

    mutating func releaseUpdateReservation() { updateReserved = false }

    @discardableResult
    mutating func beginCapture(at pressedAt: DispatchTime = .now()) -> Int {
        generation += 1
        pendingFinishedGeneration = nil
        capture = .warming(generation: generation, handsFree: false)
        openInFlight = false
        pendingRelease = false
        self.pressedAt = pressedAt
        releasedAt = nil
        return generation
    }

    /// The microphone open has been dispatched for this generation.
    @discardableResult
    mutating func markOpenInFlight(for expectedGeneration: Int) -> Bool {
        guard case .warming(let owner, _) = capture,
              owner == expectedGeneration,
              owner == generation else { return false }
        openInFlight = true
        return true
    }

    /// Parks a release that arrived while warming (either during fast route prime or
    /// `AudioDeviceStart`), allowing both short-tap completion and cold double-tap latching.
    @discardableResult
    mutating func markPendingRelease(at releasedAt: DispatchTime = .now()) -> Bool {
        guard isWarming else { return false }
        pendingRelease = true
        self.releasedAt = releasedAt
        return true
    }

    /// Resumes an already-warming capture when Tap 2 `.down` arrives before cold open finishes.
    @discardableResult
    mutating func resumeWarmingCapture(at pressedAt: DispatchTime = .now()) -> Bool {
        guard isWarming, pendingRelease else { return false }
        pendingRelease = false
        self.pressedAt = pressedAt
        releasedAt = nil
        return true
    }

    /// How long the hotkey was down. The press is the gesture, so a quick tap that then
    /// waited out a slow microphone open still reads as a tap. nil when no press owns this
    /// session (the bundled-audio probe, a repaste, a cancelled press).
    func heldSeconds(now: DispatchTime = .now()) -> Double? {
        guard let pressedAt else { return nil }
        return ms(pressedAt, releasedAt ?? now) / 1000
    }

    /// Used by the deterministic bundled-audio smoke probe after it preloads Recorder.
    @discardableResult
    mutating func beginPreparedCapture(handsFree: Bool) -> Int {
        let next = beginCapture()
        capture = .recording(generation: next, handsFree: handsFree)
        return next
    }

    @discardableResult
    mutating func markRecorderReady(for expectedGeneration: Int) -> Bool {
        guard case .warming(let owner, let handsFree) = capture,
              owner == expectedGeneration,
              owner == generation else { return false }
        capture = .recording(generation: owner, handsFree: handsFree)
        openInFlight = false
        return true
    }

    @discardableResult
    mutating func setHandsFree(_ enabled: Bool) -> Bool {
        switch capture {
        case .idle:
            return false
        case .warming(let owner, _):
            capture = .warming(generation: owner, handsFree: enabled)
        case .recording(let owner, _):
            capture = .recording(generation: owner, handsFree: enabled)
        }
        if enabled {
            pendingRelease = false
            releasedAt = nil
        }
        return true
    }

    /// Ends capture but leaves the generation intact so that generation can own delivery.
    /// A release already parked mid-open is the true one and is never overwritten here —
    /// on that path this runs at the open's completion, not at the key-up.
    @discardableResult
    mutating func finishCapture(at releasedAt: DispatchTime = .now()) -> Bool {
        let wasHandsFree = handsFree
        pendingFinishedGeneration = activeCaptureGeneration
        capture = .idle
        openInFlight = false
        pendingRelease = false
        if self.releasedAt == nil { self.releasedAt = releasedAt }
        return wasHandsFree
    }

    /// Cancels only the active (or just-finished) capture without aborting an earlier
    /// utterance already in `deliveringGenerations`. The return value tells Pipeline whether
    /// Recorder may already own (or be opening) a route.
    @discardableResult
    mutating func cancelCapture() -> Bool {
        let recorderMayOwnRoute = openInFlight || isRecording
        let cancelledOwner = activeCaptureGeneration ?? pendingFinishedGeneration
        capture = .idle
        pendingFinishedGeneration = nil
        if let cancelledOwner {
            deliveringGenerations.removeAll { $0 == cancelledOwner }
        }
        generation += 1
        openInFlight = false
        pendingRelease = false
        pressedAt = nil
        releasedAt = nil
        return recorderMayOwnRoute
    }

    /// Starts repaste/retry work without a microphone capture.
    @discardableResult
    mutating func beginStandaloneDelivery() -> Int {
        generation += 1
        capture = .idle
        pendingFinishedGeneration = nil
        deliveringGenerations.append(generation)
        openInFlight = false
        pendingRelease = false
        pressedAt = nil
        releasedAt = nil
        return generation
    }

    mutating func beginDelivery(owner: Int) {
        if pendingFinishedGeneration == owner {
            pendingFinishedGeneration = nil
        }
        if !deliveringGenerations.contains(owner) {
            deliveringGenerations.append(owner)
        }
    }

    mutating func beginCurrentDelivery() {
        let target = pendingFinishedGeneration ?? activeCaptureGeneration ?? generation
        beginDelivery(owner: target)
    }

    func isActiveDeliveryHead(_ owner: Int) -> Bool {
        deliveringGenerations.first == owner
    }

    mutating func endDelivery(owner: Int) {
        deliveringGenerations.removeAll { $0 == owner }
        if pendingFinishedGeneration == owner {
            pendingFinishedGeneration = nil
        }
    }

    func ownsCapture(_ owner: Int) -> Bool {
        activeCaptureGeneration == owner
    }

    func ownsDelivery(_ owner: Int) -> Bool {
        deliveringGenerations.contains(owner)
    }

    func owns(_ owner: Int) -> Bool {
        ownsCapture(owner) || ownsDelivery(owner) || pendingFinishedGeneration == owner
    }
}
