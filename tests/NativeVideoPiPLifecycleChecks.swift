@main
struct NativeVideoPiPLifecycleChecks {
    static func main() {
        var lifecycle = NativeVideoPiPLifecycle()
        precondition(lifecycle.prepare())
        precondition(!lifecycle.prepare()) // Repeated taps cannot create a second controller start.
        precondition(!lifecycle.needsSystemStop) // Readiness wait has not started AVKit.
        lifecycle.willStart()
        precondition(lifecycle.needsSystemStop)
        lifecycle.didStart()
        precondition(lifecycle.phase == .active && !lifecycle.prepare())
        lifecycle.willStop()
        precondition(lifecycle.phase == .stopping && !lifecycle.prepare())
        lifecycle.didStart() // A late start callback cannot reopen a stopping presentation.
        precondition(lifecycle.phase == .stopping)
        lifecycle.didStop()
        precondition(!lifecycle.needsSystemStop && lifecycle.prepare())

        // Cancelling readiness and failed system starts both permit a retry.
        lifecycle.didStop()
        precondition(lifecycle.prepare())
        lifecycle.willStart()
        lifecycle.didStop()
        precondition(lifecycle.prepare())

        // The same long-lived controller may complete many open/close cycles.
        for _ in 0..<100 {
            lifecycle.willStart()
            lifecycle.didStart()
            lifecycle.willStop()
            precondition(!lifecycle.prepare())
            lifecycle.didStop()
            precondition(lifecycle.prepare())
        }
        print("NativeVideo PiP lifecycle: repeated-start, late-callback, retry, and 100 restart cycles passed")
    }
}
