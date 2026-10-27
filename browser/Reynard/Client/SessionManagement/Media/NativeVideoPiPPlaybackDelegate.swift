// AVKit may query playback state while constructing its content source. Keep
// that state ready before the coordinator can store the resulting controller.

import AVFoundation
import AVKit
import GeckoView

@available(iOS 15.0, *)
final class NativeVideoPiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private weak var layer: AVSampleBufferDisplayLayer?
    var video: NativeVideo
    private let setPlaying: (AVPictureInPictureController, Bool) -> Void
    private let skip: (AVPictureInPictureController, CMTime, @escaping () -> Void) -> Void

    init(layer: AVSampleBufferDisplayLayer, video: NativeVideo,
         setPlaying: @escaping (AVPictureInPictureController, Bool) -> Void,
         skip: @escaping (AVPictureInPictureController, CMTime, @escaping () -> Void) -> Void) {
        self.layer = layer
        self.video = video
        self.setPlaying = setPlaying
        self.skip = skip
        super.init()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        setPlaying(pictureInPictureController, playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard let layer else { return .invalid }
        let timebase: CMTimebase
        if #available(iOS 17.0, *) {
            timebase = layer.sampleBufferRenderer.timebase
        } else {
            timebase = layer.timebase
        }
        return NativeVideoTimeline(video).playbackTimeRange(at: CMTimebaseGetTime(timebase))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        video.paused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        skip(pictureInPictureController, skipInterval, completionHandler)
    }
}
