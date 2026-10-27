import Foundation

@main
struct NativeVideoPiPContinuationChecks {
    static func main() {
        var lease = NativeVideoPiPContinuation(gracePeriod: 10)
        precondition(!lease.isArmed)
        precondition(lease.observe(available: true, ended: false, now: 1) == .expired)
        lease.arm()
        precondition(lease.isPlaybackReady(readyState: 4, sameTarget: true, advancing: false))
        precondition(lease.observe(available: true, ended: false, now: 1) == .ready)
        precondition(lease.observe(available: true, ended: true, now: 2) == .waiting)
        // A replacement's metadata/current frame does not release background
        // time before that same target is actually observed advancing.
        precondition(!lease.isPlaybackReady(readyState: 1, sameTarget: true, advancing: true))
        precondition(!lease.isPlaybackReady(readyState: 2, sameTarget: false, advancing: true))
        precondition(!lease.isPlaybackReady(readyState: 4, sameTarget: true, advancing: false))
        precondition(lease.isPlaybackReady(readyState: 2, sameTarget: true, advancing: true))
        precondition(lease.observe(available: false, ended: false, now: 8) == .waiting)
        precondition(lease.waitingSince == 2)
        precondition(lease.observe(available: true, ended: false, now: 9) == .ready)
        precondition(lease.waitingSince == nil)
        // A later autoplay item receives its own complete loading grace period.
        precondition(lease.observe(available: false, ended: false, now: 25) == .waiting)
        precondition(lease.observe(available: false, ended: false, now: 34.9) == .waiting)
        precondition(lease.observe(available: false, ended: false, now: 35) == .expired)
        precondition(!lease.isArmed)
        precondition(lease.observe(available: true, ended: false, now: 36) == .expired)
        lease.arm()
        precondition(lease.observe(available: false, ended: false, now: 40) == .waiting)
        lease.disarm()
        precondition(!lease.isPlaybackReady(readyState: 4, sameTarget: true, advancing: true))
        precondition(!lease.isArmed && lease.waitingSince == nil)
        // Closing PiP overrides both late ready events and pending transitions.
        precondition(lease.observe(available: true, ended: false, now: 41) == .expired)
        precondition(lease.observe(available: false, ended: false, now: 42) == .expired)
        lease.arm()
        precondition(lease.observe(available: true, ended: false, now: .infinity) == .expired)
        print("NativeVideo PiP continuation: 24 checks passed")
    }
}
