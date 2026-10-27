import Foundation

// Keep visible controls responsive without repeatedly scanning quiet webpages.
// Navigation, media activity, taps and scrolling wake discovery independently.
struct NativeVideoInlineDiscoveryPolicy {
    static let visibleInterval: TimeInterval = 0.6
    static let hiddenInterval: TimeInterval = 2
    private var emptyResponses = 0

    mutating func reset() { emptyResponses = 0 }

    mutating func delayAfterResponse(hasVideo: Bool, controlsVisible: Bool) -> TimeInterval {
        if hasVideo {
            emptyResponses = 0
            return controlsVisible ? Self.visibleInterval : Self.hiddenInterval
        }
        emptyResponses = min(3, emptyResponses + 1)
        return [1.5, 3, 5][emptyResponses - 1]
    }
}
