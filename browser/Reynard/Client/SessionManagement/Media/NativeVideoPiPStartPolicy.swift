// Keep readiness and AVKit's start acknowledgement on separate clocks. A
// controller can become possible before Gecko has committed a displayed frame.

import Foundation

struct NativeVideoPiPStartPolicy {
    enum Failure: Equatable {
        case readinessTimedOut
        case startTimedOut
    }

    enum Decision: Equatable {
        case wait
        case start
        case failure(Failure)
    }

    private let readinessTimeout: TimeInterval
    private let startTimeout: TimeInterval
    private let stableInterval: TimeInterval
    private var readinessDeadline: TimeInterval
    private var startingAt: TimeInterval?
    private var readySurface: ObjectIdentifier?
    private var readySince: TimeInterval?
    private var retries = 0

    init(now: TimeInterval, readinessTimeout: TimeInterval = 10,
         startTimeout: TimeInterval = 5, stableInterval: TimeInterval = 0.25) {
        self.readinessTimeout = readinessTimeout
        self.startTimeout = startTimeout
        self.stableInterval = stableInterval
        readinessDeadline = now + readinessTimeout
    }

    mutating func observe(surfaceID: ObjectIdentifier?, frameReady: Bool,
                          systemPossible: Bool, now: TimeInterval) -> Decision {
        if let startingAt {
            // Do not issue another start while AVKit is acknowledging the
            // first one, even if possibility or frame readiness changes.
            return now - startingAt >= startTimeout ? .failure(.startTimedOut) : .wait
        }
        guard now < readinessDeadline else { return .failure(.readinessTimedOut) }
        guard let surfaceID, frameReady else {
            readySurface = nil
            readySince = nil
            return .wait
        }
        if readySurface != surfaceID {
            readySurface = surfaceID
            readySince = now
        }
        guard systemPossible, let readySince, now - readySince >= stableInterval else { return .wait }
        startingAt = now
        return .start
    }

    mutating func didFailToStart(now: TimeInterval) -> Bool {
        // A timeout or an unready surface is not evidence that AVKit has
        // finished a start transition. Retry only its explicit failure callback.
        guard startingAt != nil, retries == 0 else { return false }
        retries += 1
        startingAt = nil
        readySurface = nil
        readySince = nil
        readinessDeadline = now + readinessTimeout
        return true
    }
}
