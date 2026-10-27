import AVFoundation
import UIKit

public extension GeckoSession {
    // Gecko's iOS compositor already feeds decoded frames to these layers,
    // including MSE video. AVKit observes the existing surface without moving
    // it out of Gecko's layer tree or trying to reopen a blob URL.
    func nativeVideoDisplayLayer(for video: NativeVideo,
                                allowsOffscreen: Bool = false) -> AVSampleBufferDisplayLayer? {
        guard let view = engineView, view.window != nil, video.width > 0, video.height > 0 else { return nil }
        let root = view.layer
        var candidates: [(layer: AVSampleBufferDisplayLayer, frame: CGRect)] = []
        func visit(_ layer: CALayer, clip: CGRect?) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            var clip = clip
            if layer.masksToBounds {
                let frame = root.convert(layer.bounds, from: layer)
                clip = clip.map { $0.intersection(frame) } ?? frame
            }
            if let videoLayer = layer as? AVSampleBufferDisplayLayer,
               videoLayer.status != .failed, videoLayer.bounds.width > 1, videoLayer.bounds.height > 1 {
                let frame = root.convert(videoLayer.bounds, from: videoLayer)
                let visible = clip.map { frame.intersection($0) } ?? frame
                if !visible.isNull, !visible.isInfinite, !visible.isEmpty,
                   allowsOffscreen || visible.intersects(root.bounds) {
                    candidates.append((videoLayer, visible))
                }
            }
            for child in layer.sublayers ?? [] { visit(child, clip: clip) }
        }
        visit(root, clip: allowsOffscreen ? nil : root.bounds)

        // SDR inline videos now have native surfaces too. Use the selected
        // actor's top-level viewport geometry to distinguish adjacent videos
        // and ads. More than one plausible surface remains ambiguous.
        let viewport = CGSize(width: video.viewportWidth, height: video.viewportHeight)
        // A hidden owner can coexist with one visible unrelated video. A
        // unique layer and matching aspect ratio alone cannot identify it.
        guard let visibleVideo = NativeVideoSurfaceGeometry.viewportRect(
            video.visibleRect, viewport: viewport, bounds: root.bounds) else { return nil }
        candidates = candidates.filter {
            NativeVideoSurfaceGeometry.matches(
                surface: $0.frame, visibleVideo: visibleVideo, bounds: root.bounds)
        }
        guard candidates.count == 1, let candidate = candidates.first?.layer else { return nil }
        let sourceRatio = video.width / video.height
        let layerRatio = candidate.bounds.width / candidate.bounds.height
        guard abs(layerRatio / sourceRatio - 1) < 0.08 else { return nil }
        return candidate
    }
}
