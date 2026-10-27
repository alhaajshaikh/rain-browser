// Keep AVKit's asynchronous transitions separate from webpage discovery.
// A stopped controller is reusable; a stopping controller is still in use.
struct NativeVideoPiPLifecycle {
    enum Phase { case ready, preparing, starting, active, stopping }

    private(set) var phase: Phase = .ready

    var needsSystemStop: Bool {
        phase == .starting || phase == .active || phase == .stopping
    }

    mutating func prepare() -> Bool {
        guard phase == .ready else { return false }
        phase = .preparing
        return true
    }

    mutating func willStart() {
        guard phase == .preparing else { return }
        phase = .starting
    }

    mutating func didStart() {
        guard phase == .preparing || phase == .starting else { return }
        phase = .active
    }

    mutating func willStop() {
        guard phase != .ready else { return }
        phase = .stopping
    }

    mutating func didStop() { phase = .ready }
}
