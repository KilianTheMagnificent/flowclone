import Foundation

/// Optional context is useful only if it finishes alongside ASR. No async child task
/// or continuation is awaited at delivery; taking an unfinished result abandons it.
final class DictationContextCapture: @unchecked Sendable {
    static let shared = Executor()
    static let budget: TimeInterval = 0.100

    final class Executor: Sendable {
        private let queue: DispatchQueue
        private let permit = DispatchSemaphore(value: 1)

        init(queue: DispatchQueue = DispatchQueue(label: "flowclone.optional-context",
                                                  qos: .userInitiated)) {
            self.queue = queue
        }

        func start(_ capture: @escaping @Sendable (AXClient.Deadline) -> DictationContext)
            -> DictationContextCapture {
            let result = DictationContextCapture()
            // A misbehaving AX server must not accumulate blocked threads/jobs across
            // dictations. If the previous call is still unwinding, omit this snapshot.
            guard permit.wait(timeout: .now()) == .success else { return result }
            let started = ProcessInfo.processInfo.systemUptime
            queue.async {
                defer { self.permit.signal() }
                let remaining = Self.remainingBudget(since: started)
                let deadline = AXClient.Deadline(total: remaining, perCall: 0.04,
                                                  isCancelled: { !result.isOpen })
                guard deadline.hasTimeRemaining else { return }
                let context = capture(deadline)
                result.complete(deadline.hasTimeRemaining ? context : .empty)
            }
            return result
        }

        private static func remainingBudget(since started: TimeInterval) -> TimeInterval {
            max(0, DictationContextCapture.budget
                - (ProcessInfo.processInfo.systemUptime - started))
        }
    }

    private let lock = NSLock()
    private var open = true
    private var context = DictationContext.empty

    fileprivate var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    fileprivate func complete(_ value: DictationContext) {
        lock.lock(); defer { lock.unlock() }
        if open { context = value }
    }

    func take() -> DictationContext {
        lock.lock(); defer { lock.unlock() }
        open = false
        let value = context
        context = .empty
        return value
    }
}
