import Foundation

@main
struct NativeVideoInlineDiscoveryPolicyChecks {
    static func main() {
        var policy = NativeVideoInlineDiscoveryPolicy()
        precondition(policy.delayAfterResponse(hasVideo: false, controlsVisible: false) == 1.5)
        precondition(policy.delayAfterResponse(hasVideo: false, controlsVisible: false) == 3)
        precondition(policy.delayAfterResponse(hasVideo: false, controlsVisible: false) == 5)
        for _ in 0..<100 {
            precondition(policy.delayAfterResponse(hasVideo: false, controlsVisible: false) == 5)
        }
        // A newly discovered video resets the empty-page backoff.
        precondition(policy.delayAfterResponse(hasVideo: true, controlsVisible: false) == 2)
        precondition(policy.delayAfterResponse(hasVideo: false, controlsVisible: false) == 1.5)
        precondition(policy.delayAfterResponse(hasVideo: true, controlsVisible: true) == 0.6)
        policy.reset()
        precondition(policy.delayAfterResponse(hasVideo: false, controlsVisible: false) == 1.5)
        policy.reset()
        var time: TimeInterval = 0
        var queries = 0
        while time < 60 {
            queries += 1
            time += policy.delayAfterResponse(hasVideo: false, controlsVisible: false)
        }
        precondition(queries == 14)
        print("Native video discovery policy: idle-page query budget 100→14 per simulated minute; visible/hidden/backoff/reset checks passed")
    }
}
