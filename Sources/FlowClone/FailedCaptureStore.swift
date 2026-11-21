import Dispatch
import Foundation

/// Queue-confined, in-memory recovery slot for the most recent failed user recording.
struct FailedCaptureStore {
    struct Capture: Equatable {
        let id: UUID
        let samples: [Float]
        let deadline: DispatchTime
    }

    let lifetime: TimeInterval
    private(set) var current: Capture?

    @discardableResult
    mutating func retain(_ samples: [Float], now: DispatchTime = .now()) -> Capture {
        let capture = Capture(id: UUID(), samples: samples, deadline: now + lifetime)
        current = capture
        return capture
    }

    @discardableResult
    mutating func clear() -> Bool {
        guard current != nil else { return false }
        current = nil
        return true
    }

    @discardableResult
    mutating func expire(id: UUID, deadline: DispatchTime,
                         now: DispatchTime = .now()) -> Bool {
        guard current?.id == id,
              current?.deadline == deadline,
              now.uptimeNanoseconds >= deadline.uptimeNanoseconds else { return false }
        current = nil
        return true
    }
}
