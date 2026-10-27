import Foundation

@main
struct NativeVideoInlineControlsMotionChecks {
    static func main() {
        var motion = NativeVideoInlineControlsMotion()
        precondition(motion.canRefresh(at: 0))
        precondition(motion.delayUntilRefresh(at: 0) == 0)
        let beforeDrag = motion.revision
        motion.activity(at: 10, dragging: true)
        precondition(!motion.canRefresh(at: 100)) // A stationary held drag is still active.
        precondition(motion.delayUntilRefresh(at: 100) == nil)
        precondition(!motion.canApplyGeometry(requestedAt: beforeDrag, now: 100))
        motion.activity(at: 11, dragging: false)
        precondition(!motion.canRefresh(at: 11.34))
        precondition(abs(motion.delayUntilRefresh(at: 11.2)! - 0.15) < 0.0001)
        precondition(motion.canRefresh(at: 11.35))
        let afterLift = motion.revision
        motion.activity(at: 11.4) // Momentum scroll invalidates the post-lift query.
        precondition(!motion.canApplyGeometry(requestedAt: afterLift, now: 12))
        precondition(!motion.canRefresh(at: 11.74))
        precondition(motion.canRefresh(at: 11.75))
        let afterMomentum = motion.revision
        precondition(motion.canApplyGeometry(requestedAt: afterMomentum, now: 11.75))
        motion.activity(at: 12, dragging: true)
        motion.reset() // Selecting a new tab cancels the old drag and response.
        precondition(motion.canRefresh(at: 12))
        precondition(!motion.canApplyGeometry(requestedAt: afterMomentum, now: 12))
        precondition(!motion.canRefresh(at: .infinity))
        precondition(motion.delayUntilRefresh(at: .nan) == nil)
        precondition(!motion.canApplyGeometry(requestedAt: motion.revision, now: .nan))
        motion.setTransitioning(true, at: 20)
        motion.activity(at: 20.1, dragging: false)
        precondition(!motion.canRefresh(at: 30)) // Finger-up cannot end rotation.
        precondition(motion.delayUntilRefresh(at: 30) == nil)
        motion.setTransitioning(false, at: 30)
        precondition(!motion.canRefresh(at: 30.34))
        precondition(motion.canRefresh(at: 30.35))
        motion.setTransitioning(true, at: 40)
        motion.reset()
        precondition(motion.canRefresh(at: 40))
        print("Native video inline controls motion: 22 checks passed")
    }
}
