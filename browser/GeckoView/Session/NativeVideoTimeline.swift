// PiP reports media progress against the renderer's clock. Translate its range
// instead of changing Gecko's DisplayImmediately sample-buffer timing.

import CoreMedia
import Foundation

public struct NativeVideoTimeline {
    private let video: NativeVideo
    private let mediaRange: ClosedRange<Double>?

    public init(_ video: NativeVideo) {
        self.video = video
        if let duration = video.duration, duration > 0 {
            mediaRange = 0...duration
        } else if let first = video.seekableRanges.first,
                  let end = video.seekableRanges.map(\.end).max(), end > first.start {
            // An unbounded stream may still offer a finite sliding DVR window.
            mediaRange = first.start...end
        } else {
            mediaRange = nil
        }
    }

    public var canSeek: Bool { mediaRange != nil }

    public func playbackTimeRange(at rendererTime: CMTime,
                                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CMTimeRange {
        guard rendererTime.isNumeric, rendererTime.seconds.isFinite else { return .invalid }
        guard let mediaRange else {
            return video.isLive ? CMTimeRange(start: rendererTime, duration: .positiveInfinity) : .invalid
        }
        // Descriptors arrive asynchronously. Advance only the short interval
        // between status updates; a stalled actor must not invent long playback.
        let elapsed = now.isFinite ? min(2, max(0, now - video.sampledAtUptime)) : 0
        let rate = !video.paused && video.playbackRate > 0 ? video.playbackRate : 0
        let estimate = video.currentTime + elapsed * rate
        let playhead = min(mediaRange.upperBound, max(mediaRange.lowerBound, estimate))
        let offset = rendererTime.seconds - playhead
        var start = CMTime(seconds: offset + mediaRange.lowerBound, preferredTimescale: 600)
        let duration = CMTime(seconds: mediaRange.upperBound - mediaRange.lowerBound, preferredTimescale: 600)
        guard start.isNumeric, duration.isNumeric, duration > .zero else { return .invalid }
        if start > rendererTime { start = rendererTime }
        var range = CMTimeRange(start: start, duration: duration)
        // CMTimeRange excludes its end. Include the renderer clock at the last
        // frame without claiming that the media itself has a longer duration.
        if rendererTime >= range.end {
            range.duration = CMTimeAdd(CMTimeSubtract(rendererTime, start), CMTime(value: 1, timescale: 600))
        }
        return range
    }
}
