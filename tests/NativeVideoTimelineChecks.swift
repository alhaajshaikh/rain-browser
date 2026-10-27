// Compile with NativeVideo.swift and NativeVideoTimeline.swift on macOS.
// These checks exercise real CoreMedia ranges without changing a display layer.
import CoreMedia
import Foundation

protocol EventCallback: AnyObject {
    func sendSuccess(_ response: Any?)
    func sendError(_ response: Any?)
}

struct TimelineUnusedDispatcher {
    func dispatch(type: String, message: [String: Any?]? = nil, callback: EventCallback?) {
        fatalError("Timeline checks must not send browser requests")
    }
}

public final class GeckoSession {
    let dispatcher = TimelineUnusedDispatcher()
    func isOpen() -> Bool { true }
}

@main
struct NativeVideoTimelineChecks {
    static func video(_ overrides: [String: Any] = [:]) -> NativeVideo {
        var payload: [String: Any] = [
            "token": "original", "browsingContextID": "42", "innerWindowID": "99",
            "currentTime": 50.0, "duration": 200.0, "paused": true, "playbackRate": 1.0,
            "isLive": false, "seekableRanges": [],
        ]
        payload.merge(overrides) { _, new in new }
        guard let video = NativeVideo(payload as NSDictionary) else { fatalError("Invalid fixture") }
        return video
    }

    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.002 }
        let clock = CMTime(seconds: 86_400, preferredTimescale: 600)

        let vod = video()
        let timeline = NativeVideoTimeline(vod)
        let range = timeline.playbackTimeRange(at: clock, now: vod.sampledAtUptime)
        expect(timeline.canSeek, "Finite VOD must offer skip controls")
        expect(close(range.duration.seconds, 200), "VOD must expose its actual duration")
        expect(close(range.start.seconds, 86_350), "Host clock must map to the 50-second playhead")
        expect(CMTimeRangeContainsTime(range, time: clock), "Finite ranges must contain the renderer clock")
        let zeroClock = timeline.playbackTimeRange(at: .zero, now: vod.sampledAtUptime)
        expect(close(zeroClock.start.seconds, -50), "A renderer clock at zero must still map media progress")
        expect(CMTimeRangeContainsTime(zeroClock, time: .zero), "Zero renderer time must be inside the range")
        let pausedLater = timeline.playbackTimeRange(at: clock, now: vod.sampledAtUptime + 1)
        expect(close(pausedLater.start.seconds, range.start.seconds), "Paused media progress must remain frozen")

        let playing = video(["paused": false, "playbackRate": 2.0])
        let progressing = NativeVideoTimeline(playing).playbackTimeRange(at: clock, now: playing.sampledAtUptime + 0.75)
        expect(close(progressing.start.seconds, 86_348.5), "Progress must respect playback rate between status replies")
        let stale = NativeVideoTimeline(playing).playbackTimeRange(at: clock, now: playing.sampledAtUptime + 100)
        expect(close(stale.start.seconds, 86_346), "A stalled actor must not invent minutes of playback")

        let dvr = video([
            "duration": NSNull(), "isLive": true, "currentTime": 150.0,
            "seekableRanges": [["start": 140.0, "end": 180.0], ["start": 100.0, "end": 120.0],
                               ["start": -1.0, "end": 50.0], ["start": 190.0, "end": 185.0],
                               ["start": Double.infinity, "end": Double.infinity]],
        ])
        let dvrTimeline = NativeVideoTimeline(dvr)
        let dvrRange = dvrTimeline.playbackTimeRange(at: clock, now: dvr.sampledAtUptime)
        expect(dvr.seekableRanges.count == 2, "Malformed seekable ranges must be discarded")
        expect(dvrTimeline.canSeek, "A live DVR window must support seeking")
        expect(close(dvrRange.duration.seconds, 80), "DVR must expose its current seekable window")
        expect(close(dvrRange.start.seconds, 86_350), "DVR progress must be relative to its nonzero window start")

        let legacy = video(["duration": NSNull(), "seekableStart": 100.0, "seekableEnd": 180.0])
        expect(NativeVideoTimeline(legacy).canSeek, "Legacy range bounds must remain compatible")
        let live = video(["duration": NSNull(), "isLive": true])
        let liveTimeline = NativeVideoTimeline(live)
        expect(!liveTimeline.canSeek, "Live content without DVR must remain linear")
        expect(liveTimeline.playbackTimeRange(at: clock).duration == .positiveInfinity,
               "Only actual unbounded live content should report infinity")
        let unknown = video(["duration": NSNull()])
        expect(!NativeVideoTimeline(unknown).canSeek, "Unknown metadata must not enable skipping")
        expect(!NativeVideoTimeline(unknown).playbackTimeRange(at: clock).isValid,
               "Unknown metadata must not masquerade as live content")
        expect(!timeline.playbackTimeRange(at: .invalid).isValid, "Invalid renderer clocks must be rejected")

        let ended = video(["currentTime": 200.0])
        let endedRange = NativeVideoTimeline(ended).playbackTimeRange(at: clock, now: ended.sampledAtUptime)
        expect(CMTimeRangeContainsTime(endedRange, time: clock), "The last frame must remain inside the range")
        let beforeStart = video(["currentTime": -1.0])
        let beginning = NativeVideoTimeline(beforeStart).playbackTimeRange(at: clock, now: beforeStart.sampledAtUptime)
        expect(CMTimeRangeContainsTime(beginning, time: clock), "A bounded range must clamp a negative playhead")
        print("NativeVideo timeline: \(checks) checks passed")
    }
}
