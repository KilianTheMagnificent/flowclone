import Foundation

/// One physical decode at a time, including a cancelled decode still inside Core ML.
/// Interactive `.final` > `.preview` > `.background` so live dictation preempts queued
/// background Meeting segments and imported audio chunks without failing them.
actor DecodeScheduler {
    enum Priority: Int, Comparable, Sendable {
        case background = 0
        case preview = 1
        case speculation = 2
        case final = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var busy = false
    private var activePriority: Priority?
    private var interactiveActive = false
    private var waiters: [Waiter] = []

    var isBusy: Bool { busy }
    var activeDecodePriority: Priority? { activePriority }
    var isInteractiveActive: Bool { interactiveActive }
    var queuedCount: Int { waiters.count }

    /// Marks whether an interactive dictation capture is active so queued `.background`
    /// segments yield the decoder between chunks instead of starting right before `.preview` or `.final`.
    func setInteractiveActive(_ active: Bool) {
        guard interactiveActive != active else { return }
        interactiveActive = active
        if !active, !busy {
            resumeNextEligibleWaiter()
        }
    }

    func acquire(_ priority: Priority) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }

            // Previews are disposable behind interactive/speculative work: never queue one
            // behind `.final`, `.speculation`, or another `.preview`. When `.background`
            // holds the decoder, allow at most one `.preview` waiter ahead of queued
            // `.background` chunks so live dictation feedback is never starved by imports/meetings.
            if priority == .preview {
                if waiters.contains(where: { $0.priority == .final }) { return false }
                if busy, activePriority != .background { return false }
            }

            if priority == .speculation, waiters.contains(where: { $0.priority == .final }) {
                return false
            }

            if priority == .final {
                // Displace disposable speculative/preview work, but preserve `.background`
                // and any earlier `.final` waiters so Meetings/file imports wait cleanly.
                let displaced = waiters.filter { $0.priority == .preview || $0.priority == .speculation }
                waiters.removeAll { $0.priority == .preview || $0.priority == .speculation }
                displaced.forEach { $0.continuation.resume(returning: false) }
            }

            let mustYieldBackground = priority == .background && interactiveActive
            if !busy, !mustYieldBackground {
                busy = true
                activePriority = priority
                return true
            }

            // At most one queued job of each disposable kind; new snapshots supersede old.
            if priority == .preview || priority == .speculation {
                let displaced = waiters.filter { $0.priority == priority }
                waiters.removeAll { $0.priority == priority }
                displaced.forEach { $0.continuation.resume(returning: false) }
                let disposableQueued = waiters.filter { $0.priority == .preview || $0.priority == .speculation }.count
                guard disposableQueued < 8 else { return false }
            }

            return await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func release() {
        resumeNextEligibleWaiter()
    }

    private func resumeNextEligibleWaiter() {
        let eligibleIndices = waiters.indices.filter { index in
            !(interactiveActive && waiters[index].priority == .background)
        }
        guard let maxRaw = eligibleIndices.map({ waiters[$0].priority.rawValue }).max(),
              let index = eligibleIndices.first(where: { waiters[$0].priority.rawValue == maxRaw }) else {
            busy = false
            activePriority = nil
            return
        }
        let next = waiters.remove(at: index)
        busy = true
        activePriority = next.priority
        next.continuation.resume(returning: true)
    }
}
