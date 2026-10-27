import Foundation

@main
struct NativeVideoPiPStartPolicyChecks {
    static func main() {
        let firstSurface = NSObject()
        let replacementSurface = NSObject()
        let first = ObjectIdentifier(firstSurface)
        let replacement = ObjectIdentifier(replacementSurface)

        func check(_ decision: NativeVideoPiPStartPolicy.Decision,
                   _ expected: NativeVideoPiPStartPolicy.Decision, _ description: String) {
            precondition(decision == expected, description)
        }

        var loading = NativeVideoPiPStartPolicy(now: 100)
        check(loading.observe(surfaceID: first, frameReady: false, systemPossible: true, now: 100),
              .wait, "System possibility alone cannot start an empty surface")
        check(loading.observe(surfaceID: nil, frameReady: true, systemPossible: true, now: 101),
              .wait, "A detached or ambiguous surface cannot start")
        check(loading.observe(surfaceID: first, frameReady: true, systemPossible: false, now: 102),
              .wait, "A frame cannot bypass system possibility")
        check(loading.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 102.249),
              .wait, "A newly committed frame must settle")
        check(loading.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 102.25),
              .start, "A stable displayed frame and system possibility can start")
        check(loading.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 102.5),
              .wait, "Repeated polls cannot issue duplicate starts")

        var replacing = NativeVideoPiPStartPolicy(now: 0)
        check(replacing.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 0),
              .wait, "First surface observation begins stability interval")
        check(replacing.observe(surfaceID: replacement, frameReady: true, systemPossible: true, now: 0.2),
              .wait, "Rotation or fullscreen surface replacement resets stability")
        check(replacing.observe(surfaceID: replacement, frameReady: true, systemPossible: true, now: 0.3),
              .wait, "Replacement does not inherit previous surface's ready time")
        check(replacing.observe(surfaceID: replacement, frameReady: false, systemPossible: true, now: 0.4),
              .wait, "Losing the first frame resets stability")
        check(replacing.observe(surfaceID: replacement, frameReady: true, systemPossible: true, now: 0.5),
              .wait, "Recovered displayed frame begins a new stability interval")
        check(replacing.observe(surfaceID: replacement, frameReady: true, systemPossible: true, now: 0.75),
              .start, "Recovered replacement surface can eventually start")

        var neverReady = NativeVideoPiPStartPolicy(now: 0)
        precondition(!neverReady.didFailToStart(now: 1), "Cannot retry before requesting a start")
        check(neverReady.observe(surfaceID: first, frameReady: false, systemPossible: true, now: 9.99),
              .wait, "Loading remains bounded by readiness budget")
        check(neverReady.observe(surfaceID: first, frameReady: false, systemPossible: true, now: 10),
              .failure(.readinessTimedOut), "Missing first frame has a distinct readiness failure")
        precondition(!neverReady.didFailToStart(now: 10), "Readiness timeout cannot trigger a fresh-controller retry")

        var lateStart = NativeVideoPiPStartPolicy(now: 0)
        _ = lateStart.observe(surfaceID: first, frameReady: true, systemPossible: false, now: 9.5)
        check(lateStart.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 9.75),
              .start, "Readiness near its deadline is still usable")
        check(lateStart.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 10),
              .wait, "Readiness deadline cannot shorten AVKit's acknowledgement budget")
        check(lateStart.observe(surfaceID: nil, frameReady: false, systemPossible: false, now: 14.749),
              .wait, "A pending start owns its whole acknowledgement budget")
        check(lateStart.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 14.75),
              .failure(.startTimedOut), "Missing start callback has a distinct failure")

        var retry = NativeVideoPiPStartPolicy(now: 0)
        _ = retry.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 0)
        _ = retry.observe(surfaceID: first, frameReady: true, systemPossible: true, now: 0.25)
        precondition(retry.didFailToStart(now: 2), "A confirmed AVKit failure permits one fresh-controller retry")
        precondition(!retry.didFailToStart(now: 2.1), "Duplicate callback cannot grant a second retry")
        check(retry.observe(surfaceID: replacement, frameReady: true, systemPossible: true, now: 11.5),
              .wait, "Retry receives its own bounded readiness budget and resets stability")
        check(retry.observe(surfaceID: replacement, frameReady: true, systemPossible: true, now: 11.75),
              .start, "Retry can use a newly validated surface")
        precondition(!retry.didFailToStart(now: 12), "Second confirmed failure exhausts automatic retries")

        print("NativeVideo PiP start policy: frame readiness, surface replacement, separate deadlines, and bounded retry checks passed")
    }
}
