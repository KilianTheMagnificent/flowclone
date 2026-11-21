import Foundation

/// The only retained text is the confirmed paste and its small local boundary. A changed
/// boundary, lost focus, disabled setting, or expired lease discards the whole session.
struct TypedCorrectionSession {
    static let lifetime: TimeInterval = 600
    static let settleTime: TimeInterval = 2
    let pasted: String
    let baseline: PasteTarget.LearningSnapshot
    let started: TimeInterval
    private var pending: String?
    private var changedAt: TimeInterval = 0
    private var processed: String?

    enum Sample: Equatable { case waiting, finished, ready(String) }

    init?(pasted: String, baseline: PasteTarget.LearningSnapshot, now: TimeInterval) {
        guard !pasted.isEmpty, pasted.utf16.count <= 3_000,
              baseline.text.hasPrefix(pasted) else { return nil }
        self.pasted = pasted
        self.baseline = baseline
        self.started = now
    }

    mutating func sample(_ value: PasteTarget.LearningSnapshot?, enabled: Bool,
                         now: TimeInterval) -> Sample {
        guard enabled, now - started < Self.lifetime,
              let value, value.prefix == baseline.prefix else { return .finished }
        // Preserve the original text after the paste. This prevents edits in surrounding
        // prose from donating words to the correction detector.
        let suffix = String(baseline.text.dropFirst(pasted.count))
        guard value.text.hasSuffix(suffix) else { return .finished }
        let edited = String(value.text.dropLast(suffix.count))
        guard edited != pasted else {
            pending = nil
            return .waiting
        }
        if edited != pending {
            pending = edited
            changedAt = now
            return .waiting
        }
        guard now - changedAt >= Self.settleTime, edited != processed,
              value.selectionLength == 0 else { return .waiting }
        processed = edited
        return .ready(edited)
    }
}

/// A single bounded polling lease, active only after a proven paste. All AX calls run on
/// this utility queue, never on the recording/session queue or the main thread. Polling
/// also supports editors which expose text ranges but omit AX value-change notifications.
final class TypedCorrectionMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "flowclone.typed-corrections", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var session: TypedCorrectionSession?

    private func nextGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == expected
    }

    func stop() {
        let expected = nextGeneration() // Immediately invalidates queued main-thread saves.
        queue.async { if self.isCurrent(expected) { self.clear() } }
    }

    private func clear() {
        timer?.cancel()
        timer = nil
        session = nil
    }

    func start(_ record: AutoLearn.PasteRecord,
               onCorrections: (@MainActor @Sendable ([(wrong: String, right: String)]) -> Void)? = nil) {
        let handler: @MainActor @Sendable ([(wrong: String, right: String)]) -> Void = onCorrections ?? { pairs in
            AutoLearn.learn(pairs, app: "the dictation app", bundleID: record.target.app.bundleID)
        }
        let expected = nextGeneration()
        queue.async { [self] in
            guard self.isCurrent(expected) else { return }
            self.clear()
            guard AutoLearn.enabled, AutoLearn.mayLearn(hadContextRewrite: record.hadContextRewrite),
                  Date().timeIntervalSince(record.date) < TypedCorrectionSession.lifetime,
                  let baseline = record.target.learningSnapshot(at: record.insertion),
                  let session = TypedCorrectionSession(pasted: record.text, baseline: baseline,
                                                       now: ProcessInfo.processInfo.systemUptime)
            else {
                log("auto-learn: monitoring unavailable for this paste")
                return
            }
            self.session = session
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                guard self.isCurrent(expected), AutoLearn.enabled,
                      var current = self.session else { self.clear(); return }
                guard ProcessInfo.processInfo.systemUptime - current.started < TypedCorrectionSession.lifetime
                else { self.clear(); return }
                let value = record.target.learningSnapshot(at: record.insertion,
                                                          originalCount: baseline.characterCount)
                let result = current.sample(value, enabled: AutoLearn.enabled,
                                            now: ProcessInfo.processInfo.systemUptime)
                self.session = current
                switch result {
                case .finished:
                    self.clear()
                case .waiting:
                    break
                case .ready(let edited):
                    let pairs = AutoLearn.findCorrections(pasted: record.text, field: edited)
                    guard !pairs.isEmpty else { return }
                    DispatchQueue.main.async {
                        guard self.isCurrent(expected), AutoLearn.enabled else { return }
                        handler(pairs)
                    }
                }
            }
            self.timer = timer
            timer.resume()
            log("auto-learn: monitoring confirmed paste")
        }
    }
}
