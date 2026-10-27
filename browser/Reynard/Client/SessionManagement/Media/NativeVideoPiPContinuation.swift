import Foundation

// This lease exists only after the user starts PiP. Loading or an ended video
// can bridge to its next item without selecting another page or reopening PiP
// after the user closes it. Time uses monotonic system uptime.
struct NativeVideoPiPContinuation {
    enum Decision { case ready, waiting, expired }

    private(set) var isArmed = false
    private(set) var waitingSince: TimeInterval?
    let gracePeriod: TimeInterval

    init(gracePeriod: TimeInterval = 60) {
        self.gracePeriod = gracePeriod
    }

    mutating func arm() {
        isArmed = true
        waitingSince = nil
    }

    mutating func disarm() {
        isArmed = false
        waitingSince = nil
    }

    func isPlaybackReady(readyState: Int, sameTarget: Bool, advancing: Bool) -> Bool {
        // Metadata is insufficient. Once a source/loading gap begins, the
        // successor must be observed playing before its loading lease ends.
        isArmed && readyState >= 2 && sameTarget && (waitingSince == nil || advancing)
    }

    mutating func observe(available: Bool, ended: Bool, now: TimeInterval) -> Decision {
        guard isArmed, now.isFinite else { return .expired }
        if available && !ended {
            waitingSince = nil
            return .ready
        }
        if waitingSince == nil { waitingSince = now }
        guard now - (waitingSince ?? now) < gracePeriod else {
            disarm()
            return .expired
        }
        return .waiting
    }
}
