import Foundation

// A compositor scroll can finish after the finger lifts. Require both a quiet
// interval and geometry requested after the latest movement before showing UI.
struct NativeVideoInlineControlsMotion {
    static let quietInterval: TimeInterval = 0.35
    private(set) var revision: UInt64 = 0
    private(set) var isDragging = false
    private(set) var isTransitioning = false
    private var quietAfter: TimeInterval = 0

    mutating func activity(at now: TimeInterval, dragging: Bool? = nil) {
        if let dragging { isDragging = dragging }
        revision &+= 1
        quietAfter = now + Self.quietInterval
    }

    mutating func reset() {
        revision &+= 1
        isDragging = false
        isTransitioning = false
        quietAfter = 0
    }

    mutating func setTransitioning(_ active: Bool, at now: TimeInterval) {
        isTransitioning = active
        activity(at: now)
    }

    func canRefresh(at now: TimeInterval) -> Bool {
        now.isFinite && !isDragging && !isTransitioning && now >= quietAfter
    }

    func delayUntilRefresh(at now: TimeInterval) -> TimeInterval? {
        guard now.isFinite, !isDragging, !isTransitioning else { return nil }
        return max(0, quietAfter - now)
    }

    func canApplyGeometry(requestedAt revision: UInt64, now: TimeInterval) -> Bool {
        revision == self.revision && canRefresh(at: now)
    }
}
